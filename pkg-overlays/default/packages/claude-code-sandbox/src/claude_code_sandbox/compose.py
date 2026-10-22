# SPDX-License-Identifier: MIT
"""Composition: the set of sandbox modules a checkout chose, turned into
one settings fragment.

The home-manager module compiles every declared sandbox module into a
*part* (its own bin farm, the closure of that farm, and the grants it
declares) and the always-present runtime into the *base* part. Nix cannot
know which combinations checkouts will choose, so the combination happens
here, at enroll and sync time, by union:

- Modules are resolved from the checkout's chosen names plus the
  registry's ``baseModules``, following each module's ``requires``.
- Every list grant (read and write paths, domains, excluded commands, unix
  sockets) is the union of the modules' lists. ``null`` in every module
  leaves the key out of the fragment; a list in any module puts it in.
- The store stays masked only when every module is masked: one module
  that needs ``nix`` unmasks it for the whole checkout.
- ``PATH`` is the ssh wrapper, then the module farms in name order, then
  the base farm and the sandbox runtime tools. Two modules that put the
  same command on PATH resolve to the module whose name sorts first.
- Environment variables and settings passthrough merge; two modules that
  set the same variable or settings scalar to different values are an
  error, reported at enroll time.

A unix-socket allowlist is enforced by the base part's socket shell, a
Landlock wrapper that reads the allowlist from ``SOCKETS_ENV_VAR`` in the
settings env. That env is write-guarded at both the sandbox and
permission layers, and Landlock restrictions only narrow once applied, so
a command cannot widen the allowlist for itself or its children.
"""

from __future__ import annotations

import json
from typing import Any

from .files import ToolError
from .registry import load_part

SOCKETS_ENV_VAR = "CLAUDE_CODE_SANDBOX_UNIX_SOCKETS"
FRAGMENT_LIMIT = 100_000

_LIST_GRANTS = (
    "extraAllowRead",
    "allowWrite",
    "allowedDomains",
    "deniedDomains",
    "excludedCommands",
    "allowUnixSockets",
)


def module_names(registry: dict[str, Any]) -> list[str]:
    return sorted((registry.get("modules") or {}).keys())


def check_known(registry: dict[str, Any], names: list[str]) -> None:
    known = registry.get("modules") or {}
    unknown = sorted(n for n in names if n not in known)
    if unknown:
        raise ToolError(
            f"unknown sandbox module(s) {', '.join(unknown)} "
            f"(declared: {', '.join(sorted(known)) or 'none at all'})"
        )


def resolve(registry: dict[str, Any], chosen: list[str]) -> dict[str, dict[str, Any]]:
    """The chosen modules plus ``baseModules``, closed over ``requires``.
    Returns the loaded parts keyed by module name."""
    pending = list(registry.get("baseModules") or []) + list(chosen)
    check_known(registry, pending)
    parts: dict[str, dict[str, Any]] = {}
    while pending:
        name = pending.pop()
        if name in parts:
            continue
        part = load_part(registry["modules"][name], f"module '{name}'")
        parts[name] = part
        requires = part.get("requires") or []
        check_known(registry, requires)
        pending.extend(requires)
    return parts


def _union(values: list[list[Any] | None]) -> list[Any] | None:
    """Concatenate the lists in order, dropping repeated entries. Entries
    are compared by their JSON text, so settings lists of objects merge
    like lists of strings."""
    present = [v for v in values if v is not None]
    if not present:
        return None
    out: list[Any] = []
    seen: set[str] = set()
    for value in present:
        for entry in value:
            key = json.dumps(entry, sort_keys=True)
            if key not in seen:
                seen.add(key)
                out.append(entry)
    return out


def _merge_settings(dst: dict[str, Any], src: dict[str, Any], owner: str, where: str = "") -> None:
    for key, value in src.items():
        path = f"{where}.{key}" if where else key
        if key not in dst:
            dst[key] = value
        elif isinstance(value, dict) and isinstance(dst[key], dict):
            _merge_settings(dst[key], value, owner, path)
        elif isinstance(value, list) and isinstance(dst[key], list):
            dst[key] = _union([dst[key], value])
        elif dst[key] != value:
            raise ToolError(
                f"module '{owner}' sets settings key {path} to {value!r}, "
                f"which another chosen module sets to {dst[key]!r}"
            )


def compose(
    registry: dict[str, Any], chosen: list[str], checkout_env: dict[str, str] | None = None
) -> dict[str, Any]:
    """The settings fragment for a checkout that chose ``chosen``.
    ``checkout_env`` carries the variables only the caller knows (the
    checkout root); they go into the fragment before its size is
    checked, so the checked fragment is the one applied."""
    base = load_part(registry.get("base"), "the base part")
    parts = resolve(registry, chosen)
    names = sorted(parts)
    ordered = [parts[n] for n in names]

    grants = {key: _union([p.get(key) for p in ordered]) for key in _LIST_GRANTS}

    masked = all(p["masked"] for p in ordered)
    fs: dict[str, Any] = {}
    if masked:
        closure = _union([base["closure"], *(p.get("closure") or [] for p in ordered)])
        fs["denyRead"] = ["/nix/store"]
        fs["allowRead"] = sorted(closure or []) + (grants["extraAllowRead"] or [])
    elif grants["extraAllowRead"] is not None:
        fs["allowRead"] = grants["extraAllowRead"]
    if grants["allowWrite"] is not None:
        fs["allowWrite"] = grants["allowWrite"]

    # An explicit allow-all in any module wins and gets no narrowing; a
    # non-empty allowlist otherwise opens upstream's all-or-nothing Linux
    # filter and narrows it again through the socket shell.
    allow_all_values = [p.get("allowAllUnixSockets") for p in ordered]
    sockets = grants["allowUnixSockets"]
    narrows = True not in allow_all_values and bool(sockets)
    if True in allow_all_values or narrows:
        allow_all: bool | None = True
    elif False in allow_all_values:
        allow_all = False
    else:
        allow_all = None

    env: dict[str, str] = {
        "PATH": ":".join(
            base["pathFirst"]
            + [entry for p in ordered for entry in p.get("path") or []]
            + base["pathLast"]
        ),
        "SHELL": base["socketShell"] if narrows else base["shell"],
    }
    if narrows:
        env[SOCKETS_ENV_VAR] = "\n".join(sockets or [])
    for name, part in zip(names, ordered):
        for key, value in (part.get("env") or {}).items():
            if key in env and env[key] != value:
                raise ToolError(
                    f"module '{name}' sets env {key}={value!r}, which another "
                    f"chosen module (or the runtime) sets to {env[key]!r}"
                )
            env[key] = value
    # The home-manager module rejects a part whose env names one of
    # these, so they cannot collide with a module's variables.
    env.update(checkout_env or {})

    sandbox: dict[str, Any] = {
        "enabled": True,
        "failIfUnavailable": True,
        "allowUnsandboxedCommands": False,
    }
    if fs:
        sandbox["filesystem"] = fs
    net: dict[str, Any] = {}
    for key in ("allowedDomains", "deniedDomains"):
        if grants[key] is not None:
            net[key] = grants[key]
    if sockets is not None:
        net["allowUnixSockets"] = sockets
    if allow_all is not None:
        net["allowAllUnixSockets"] = allow_all
    if net:
        sandbox["network"] = net
    if grants["excludedCommands"] is not None:
        sandbox["excludedCommands"] = grants["excludedCommands"]
    fragment: dict[str, Any] = {"sandbox": sandbox, "env": env}

    # The parts' passthrough settings cannot touch the keys generated
    # above: the home-manager module rejects such a part at build time.
    extra: dict[str, Any] = {}
    for name, part in zip(names, ordered):
        _merge_settings(extra, part.get("settings") or {}, name)
    _merge_settings(fragment, extra, "passthrough")

    size = len(json.dumps(fragment, indent=2))
    if size > FRAGMENT_LIMIT:
        raise ToolError(
            f"the fragment for modules {', '.join(names) or '(base only)'} is "
            f"{size} bytes (> {FRAGMENT_LIMIT}): the sandbox rules are passed "
            "through the exec environment and hit E2BIG around 128KB; choose "
            "fewer modules or trim their toolsets"
        )
    return fragment
