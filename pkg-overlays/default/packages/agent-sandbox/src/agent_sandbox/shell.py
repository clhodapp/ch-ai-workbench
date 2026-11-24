# SPDX-License-Identifier: MIT
"""Rules for the srt step of the bash chain.

An agent without a sandbox of its kind (OpenCode) runs outside the
sandbox, with ``SHELL`` set to the bash chain. The chain's first step,
the srt step, starts srt around each shell command. It is a Node program
that drives srt through its library, so it reads its rules from a file
rather than composing them: ``shell-rules AGENT`` composes the checkout's
modules, ``baseModules`` and the modules the registry lists for AGENT,
and writes

- ``settings``: srt settings, as ``run.srt_settings`` writes them for a
  whole agent, with domains in the forms srt accepts
  (``run.srt_file_settings``);
- ``allowAll``: whether the composed domains grant every host (``*``),
  which srt has no pattern for; the srt step then answers srt's ask
  callback with ``true`` for hosts no list decides;
- ``env``: the composed environment (``PATH``, ``SHELL``, the socket and
  device lists, the scratch ``TMPDIR``) for the command;
- ``shell``: the shell srt runs inside the sandbox, the
  socket-restriction step when the modules grant unix sockets;
- ``stamp``: the registry file and sidecar the rules came from, which
  the srt step compares before each command to decide whether to run
  ``shell-rules`` again.

The file lives under ``$XDG_RUNTIME_DIR/agent-sandbox/shell/``, which no
sandbox may write, one directory per checkout, beside that checkout's
scratch directory. A directory that is not an enrolled checkout gets no
file, and the srt step runs the command without a sandbox, as
``agent-sandbox run`` does there.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
from typing import Any

from .compose import compose
from .files import find_repo_root, migrate_checkout, migrate_state, read_sidecar, sidecar_path, write_text_atomic
from .registry import config_dir, load_part, load_registry
from .run import ROOT_ENV_VAR, runtime_dir, srt_file_settings, srt_settings


def rules_dir(root: Path) -> Path:
    digest = hashlib.sha256(str(root).encode()).hexdigest()[:16]
    return runtime_dir() / "shell" / digest


def stamp(root: Path) -> dict[str, Any]:
    """What the rules of ``root`` were composed from: the registry file
    the home-manager generation links, and the checkout's sidecar."""
    registry = config_dir() / "registry.json"
    sidecar = sidecar_path(root)
    return {
        "registry": os.path.realpath(registry),
        "sidecar": sidecar.stat().st_mtime_ns if sidecar.exists() else None,
    }


def write_shell_rules(agent_name: str, directory: Path) -> Path | None:
    """Write the rules of the checkout containing ``directory`` for the
    shell commands of ``agent_name``, and return their path; None when the
    directory is not in a checkout enrolled with modules."""
    root = find_repo_root(directory)
    if root is None:
        return None
    migrate_state()
    migrate_checkout(root)
    sidecar = read_sidecar(root)
    if sidecar is None or sidecar["modules"] is None:
        return None
    from .cli import due_modules, expire_due, provision_creds

    if due_modules(sidecar):
        expire_due(root)
        sidecar = read_sidecar(root)
        if sidecar is None or sidecar["modules"] is None:
            return None

    registry = load_registry()
    agents = registry.get("agents") or {}
    if agent_name not in agents:
        from .files import ToolError

        raise ToolError(
            f"the registry declares no agent '{agent_name}' "
            f"(declared: {', '.join(sorted(agents)) or 'none'})"
        )
    agent = agents[agent_name]
    base = load_part(registry.get("base"), "the base part")
    modules = [*sidecar["modules"], *(agent.get("modules") or [])]
    fragment = compose(registry, modules, {ROOT_ENV_VAR: str(root)})

    directory_ = rules_dir(root)
    scratch = directory_ / "tmp"
    scratch.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(directory_, 0o700)

    env = {**fragment.get("env", {}), **(agent.get("env") or {})}
    env["TMPDIR"] = env["CLAUDE_CODE_TMPDIR"] = str(scratch)
    env["TMPPREFIX"] = str(scratch / "zsh")

    settings = srt_settings(fragment, root, registry.get("guards") or [], scratch, base.get("bwrap"))
    for path in settings["filesystem"]["allowWrite"]:
        Path(path).mkdir(parents=True, exist_ok=True)
    settings, allow_all = srt_file_settings(settings)
    provision_creds(root)

    rules = {
        "root": str(root),
        "settings": settings,
        "allowAll": allow_all,
        "env": env,
        "shell": env.get("SHELL") or base["shell"],
        "stamp": stamp(root),
    }
    path = directory_ / "rules.json"
    write_text_atomic(path, json.dumps(rules, indent=2) + "\n")
    return path
