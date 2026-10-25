# SPDX-License-Identifier: MIT
"""What a checkout has enabled, and what a module would allow.

The CLI's ``show`` and the agent tools (mcp.py) both describe sandbox
modules from here, so a person reading the terminal and an agent reading
a tool result see the same account of each grant.

A module is *enabled* in a checkout when the checkout chose it, when it
is one of the registry's ``baseModules``, or when an enabled module
requires it. A module is *declined* when the user answered a request for
it with a refusal; the sidecar keeps that answer until the user enables
the module or withdraws the refusal with ``undecline``.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from .compose import check_known, module_names
from .files import ToolError, read_sidecar
from .registry import load_part


def enabled_by(registry: dict[str, Any], chosen: list[str]) -> dict[str, str]:
    """Every enabled module, with the reason it is enabled: ``chosen``,
    ``base``, or ``required by NAME``. A module enabled for several
    reasons reports the first in that order."""
    reasons: dict[str, str] = {}
    pending: list[tuple[str, str]] = [(name, "chosen") for name in chosen]
    pending += [(name, "base") for name in registry.get("baseModules") or []]
    check_known(registry, [name for name, _ in pending])
    while pending:
        name, why = pending.pop(0)
        if name in reasons:
            continue
        reasons[name] = why
        part = load_part(registry["modules"][name], f"module '{name}'")
        requires = part.get("requires") or []
        check_known(registry, requires)
        pending += [(req, f"required by {name}") for req in requires]
    return reasons


def checkout_state(root: Path, registry: dict[str, Any] | None) -> dict[str, Any]:
    """The checkout's binding: ``enrollment`` is one of ``not enrolled``,
    ``abandoned``, ``legacy profile`` or ``enrolled``. An enrolled
    checkout also reports ``chosen``, ``expires`` (each module chosen for
    a limited time, to its deadline) and, given the registry,
    ``enabled`` (name to reason)."""
    sidecar = read_sidecar(root)
    state: dict[str, Any] = {"checkout": str(root)}
    if sidecar is None:
        state["enrollment"] = "not enrolled"
        state["declined"] = {}
        return state
    state["declined"] = sidecar["declined"]
    if sidecar["legacy_profile"] is not None:
        state["enrollment"] = "legacy profile"
        state["profile"] = sidecar["legacy_profile"]
        return state
    if sidecar["modules"] is None:
        state["enrollment"] = "abandoned"
        return state
    state["enrollment"] = "enrolled"
    state["chosen"] = sidecar["modules"]
    state["expires"] = {
        name: at.astimezone().isoformat(timespec="minutes") for name, at in sorted(sidecar["expires"].items())
    }
    if registry is not None:
        state["enabled"] = enabled_by(registry, sidecar["modules"])
    return state


_GRANTS = (
    "allowedDomains",
    "deniedDomains",
    "allowUnixSockets",
    "allowAllUnixSockets",
    "allowWrite",
    "extraAllowRead",
    "excludedCommands",
    "trustedExecutables",
    "env",
    "settings",
)


def describe(registry: dict[str, Any], name: str, state: dict[str, Any] | None = None) -> dict[str, Any]:
    """What module ``name`` puts into a checkout's sandbox. Given the
    checkout's state, also its status there and the modules its
    ``requires`` would enable along with it."""
    check_known(registry, [name])
    part = load_part(registry["modules"][name], f"module '{name}'")
    out: dict[str, Any] = {
        "name": name,
        "description": part.get("description") or "",
        "requires": part.get("requires") or [],
        "base": name in (registry.get("baseModules") or []),
        "unmasksStore": not part.get("masked", True),
        "packages": part.get("packages"),
        "commands": part.get("commands"),
    }
    for key in _GRANTS:
        if part.get(key) is not None:
            out[key] = part[key]
    if state is not None:
        out["status"] = module_status(name, state)
        enabled = state.get("enabled") or {}
        if name not in enabled:
            out["alsoEnables"] = sorted(
                other for other in enabled_by(registry, [name]) if other != name and other not in enabled
            )
    return out


def module_status(name: str, state: dict[str, Any]) -> str:
    enabled = state.get("enabled") or {}
    if name in enabled:
        why = enabled[name]
        if why != "chosen":
            return f"enabled ({why})"
        until = state.get("expires", {}).get(name)
        return f"enabled until {until}" if until else "enabled"
    if name in state.get("declined", {}):
        return "declined"
    return "available"


def overview(registry: dict[str, Any], state: dict[str, Any] | None) -> list[dict[str, Any]]:
    """One entry per declared module: name, description, requires, and
    with a checkout state, its status there."""
    rows = []
    for name in module_names(registry):
        part = load_part(registry["modules"][name], f"module '{name}'")
        row: dict[str, Any] = {
            "name": name,
            "description": part.get("description") or "",
            "requires": part.get("requires") or [],
            "unmasksStore": not part.get("masked", True),
        }
        if state is not None:
            row["status"] = module_status(name, state)
        rows.append(row)
    return rows


def describe_text(info: dict[str, Any]) -> str:
    """``describe`` as lines a person reads before deciding."""
    lines = [f"{info['name']}: {info['description']}" if info["description"] else info["name"]]
    if info.get("status"):
        lines.append(f"Status in this checkout: {info['status']}")
    if info["commands"]:
        lines.append("Commands put on PATH: " + ", ".join(info["commands"]))
    if info["packages"]:
        lines.append("From packages: " + ", ".join(info["packages"]))
    if info["unmasksStore"]:
        lines.append(
            "Unmasks the whole Nix store: every installed program becomes readable "
            "and runnable inside the sandbox, for every module of the checkout."
        )
    if info.get("allowedDomains"):
        lines.append("Network domains reachable: " + ", ".join(info["allowedDomains"]))
    if info.get("deniedDomains"):
        lines.append("Network domains denied: " + ", ".join(info["deniedDomains"]))
    if info.get("allowAllUnixSockets"):
        lines.append("Unix sockets: every socket on the host is reachable.")
    elif info.get("allowUnixSockets"):
        lines.append("Unix sockets reachable: " + ", ".join(info["allowUnixSockets"]))
    if info.get("allowWrite"):
        lines.append("Writable beyond the checkout: " + ", ".join(info["allowWrite"]))
    if info.get("extraAllowRead"):
        lines.append("Readable in addition: " + ", ".join(info["extraAllowRead"]))
    if info.get("excludedCommands"):
        lines.append("Runs OUTSIDE the sandbox: " + ", ".join(info["excludedCommands"]))
    for trusted in info.get("trustedExecutables") or []:
        where = trusted.get("workingDirectory") or "the working directory of the caller"
        line = (
            f"Trusted executable {trusted['name']}: runs "
            + " ".join([trusted["program"], *trusted.get("args", [])])
            + f" OUTSIDE the sandbox, in {where}, with the arguments and stdin of the caller"
        )
        if trusted.get("passEnv"):
            line += " and the variables " + ", ".join(trusted["passEnv"])
        if trusted.get("description"):
            line += f" ({trusted['description']})"
        lines.append(line)
    if info.get("env"):
        lines.append(
            "Environment: " + ", ".join(f"{key}={value}" for key, value in sorted(info["env"].items()))
        )
    if info.get("settings"):
        lines.append("Extra Claude Code settings: " + ", ".join(sorted(info["settings"])))
    if info["requires"]:
        lines.append("Requires: " + ", ".join(info["requires"]))
    if info.get("alsoEnables"):
        lines.append("Enabling it also enables: " + ", ".join(info["alsoEnables"]))
    if info["base"]:
        lines.append("It is in every enrollment (baseModules).")
    return "\n".join(lines)


def require_enrolled(state: dict[str, Any]) -> list[str]:
    """The chosen modules of a checkout enrolled with modules; otherwise
    an error naming what the user would have to do first."""
    enrollment = state["enrollment"]
    root = state["checkout"]
    if enrollment == "not enrolled":
        raise ToolError(
            f"{root} is not enrolled in the sandbox; enrolling is the user's act "
            "(claude-code-sandbox enroll MODULE...)"
        )
    if enrollment == "abandoned":
        raise ToolError(f"{root} is abandoned; the user re-enrolls it with claude-code-sandbox enroll")
    if enrollment == "legacy profile":
        raise ToolError(
            f"{root} is bound to the retired profile '{state['profile']}'; the user "
            "re-enrolls it with sandbox modules first"
        )
    return state["chosen"]
