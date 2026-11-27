# SPDX-License-Identifier: MIT
"""Rules for the srt step of the bash chain.

An agent with backend ``srt`` (OpenCode) runs outside the sandbox, with
``SHELL`` set to the bash chain. The chain's first step, the srt step,
starts srt around each shell command. It reads its rules from a file
that this module writes at enroll and sync time, beside the binding:
``.agent-sandbox/shell-<agent>.json``, write-guarded like the binding.
The file holds

- ``settings``: srt settings for the checkout's modules, ``baseModules``
  and the modules the registry lists for the agent, with domains in the
  forms srt accepts (``run.srt_file_settings``);
- ``allowAll``: whether the composed domains grant every host (``*``),
  which srt has no pattern for; the srt step then answers srt's ask
  callback with ``true`` for hosts no list decides;
- ``env``: the composed environment (``PATH``, ``SHELL``, the socket and
  device lists, the scratch ``TMPDIR``) for the command;
- ``shell``: the shell srt runs inside the sandbox, the
  socket-restriction step when the modules grant unix sockets;
- ``scratch``: the command's temporary directory, under
  ``$XDG_RUNTIME_DIR``, which the srt step creates when it is missing.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

from .compose import compose
from .files import sandbox_dir, write_text_atomic
from .registry import load_part
from .run import ROOT_ENV_VAR, runtime_dir, srt_file_settings, srt_settings


def rules_path(root: Path, agent_name: str) -> Path:
    return sandbox_dir(root) / f"shell-{agent_name}.json"


def scratch_dir(root: Path, agent_name: str) -> Path:
    digest = hashlib.sha256(str(root).encode()).hexdigest()[:16]
    return runtime_dir() / f"shell-{agent_name}-{digest}" / "tmp"


def shell_rules(root: Path, modules: list[str], registry: dict[str, Any], agent_name: str) -> dict[str, Any]:
    """The rules of ``agent_name``'s shell commands in the checkout
    ``root`` enrolled with ``modules``."""
    agent = registry["agents"][agent_name]
    base = load_part(registry.get("base"), "the base part")
    fragment = compose(registry, [*modules, *(agent.get("modules") or [])], {ROOT_ENV_VAR: str(root)})
    scratch = scratch_dir(root, agent_name)

    env = {**fragment.get("env", {}), **(agent.get("env") or {})}
    # srt sets the sandbox's TMPDIR from CLAUDE_CODE_TMPDIR, and to
    # /tmp/claude, shared by every sandbox, without it.
    env["TMPDIR"] = env["CLAUDE_CODE_TMPDIR"] = str(scratch)
    # zsh uses TMPPREFIX for heredocs rather than deriving it from TMPDIR.
    env["TMPPREFIX"] = str(scratch / "zsh")

    settings = srt_settings(fragment, root, registry.get("guards") or [], scratch, base.get("bwrap"))
    settings, allow_all = srt_file_settings(settings)
    return {
        "settings": settings,
        "allowAll": allow_all,
        "env": env,
        "shell": env.get("SHELL") or base["shell"],
        "scratch": str(scratch),
    }


def sync_shell_rules(root: Path, modules: list[str] | None, registry: dict[str, Any]) -> None:
    """Write, or remove when ``modules`` is None, the shell rules of every
    agent with backend ``srt``."""
    for name, agent in (registry.get("agents") or {}).items():
        if agent.get("backend", "srt") != "srt":
            continue
        path = rules_path(root, name)
        if modules is None:
            path.unlink(missing_ok=True)
            continue
        rules = shell_rules(root, modules, registry, name)
        # srt can grant only a path that exists, and inside the sandbox the
        # parent of a missing directory is read-only, so a command could not
        # create a granted state directory on first use. The srt step
        # creates the ones still missing when it starts srt.
        for granted in rules["settings"]["filesystem"]["allowWrite"]:
            if granted == rules["scratch"]:
                continue
            try:
                Path(granted).mkdir(parents=True, exist_ok=True)
            except OSError:
                pass
        write_text_atomic(path, json.dumps(rules, indent=2) + "\n")
