# SPDX-License-Identifier: MIT
"""Running a whole agent (Codex, OpenCode) inside the checkout's sandbox.

Claude Code applies the composed rules itself, to each Bash command. Codex
and OpenCode have no such hook, so ``agent-sandbox run AGENT -- COMMAND``
runs the whole agent process under sandbox-runtime (``srt``), the sandbox
Claude Code's own rules are written for. The rules come from the same
composition: the checkout's chosen modules, ``baseModules``, and the
modules the registry lists for AGENT (its package, state directories and
API hosts). What differs from the Claude Code fragment:

- srt reads its rules from a settings file rather than from
  ``.claude/settings.local.json``. The file is written for each run under
  ``$XDG_RUNTIME_DIR/agent-sandbox``, where nothing in the sandbox can
  write.
- srt grants no write access that is not listed, so the checkout root and
  a per-run scratch directory (the agent's ``TMPDIR``) are added to
  ``allowWrite``. The registry's
  write guards (the checkout's settings files and sidecar, the index of
  expiring checkouts) go to ``denyWrite``.
- A unix-socket allowlist is enforced by starting the agent itself through
  the socket shell, so the agent process is narrowed and not only the
  commands it runs.
- srt starts bubblewrap with ``--new-session``, which leaves the agent
  without a controlling terminal, so a terminal UI never hears of a
  window resize. When stdin is a terminal, the agent therefore runs on a
  pseudo-terminal this process owns outside the sandbox: inside,
  ``setsid -c`` makes it the agent's controlling terminal, and this
  process relays bytes and copies each resize of the real terminal onto
  it. Text the agent pushes into its terminal's input reaches only that
  pseudo-terminal.

A checkout that is not enrolled with modules runs the command unchanged:
enrolling is the user's act, and an agent outside every checkout keeps its
own behaviour.
"""

from __future__ import annotations

import fcntl
import json
import os
import select
import signal
import sys
import termios
import tty
from pathlib import Path
from typing import Any

from .compose import SOCKETS_ENV_VAR, compose
from .files import ToolError, find_repo_root, migrate_checkout, migrate_state, read_sidecar, write_text_atomic
from .registry import load_part, load_registry

ROOT_ENV_VAR = "AGENT_SANDBOX_ROOT"


def runtime_dir() -> Path:
    base = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    return Path(base) / "agent-sandbox"


def srt_settings(
    fragment: dict[str, Any], root: Path, guards: list[str], scratch: Path, bwrap: str | None
) -> dict[str, Any]:
    """The srt settings for a composed fragment, in the checkout ``root``.
    ``guards`` are write-guarded paths, relative ones taken from ``root``."""
    sandbox = fragment.get("sandbox") or {}
    fs = sandbox.get("filesystem") or {}
    net = sandbox.get("network") or {}
    filesystem: dict[str, Any] = {
        "denyRead": list(fs.get("denyRead") or []),
        "allowRead": list(fs.get("allowRead") or []),
        "allowWrite": [str(root), str(scratch), *(fs.get("allowWrite") or [])],
        "denyWrite": [g if g.startswith("/") else str(root / g) for g in guards],
    }
    network: dict[str, Any] = {"allowedDomains": list(net.get("allowedDomains") or [])}
    for key in ("deniedDomains", "allowUnixSockets", "allowAllUnixSockets"):
        if key in net:
            network[key] = net[key]
    settings: dict[str, Any] = {"filesystem": filesystem, "network": network}
    if bwrap:
        settings["bwrapPath"] = bwrap
    return settings


def sandboxed_command(
    command: list[str],
    agent: dict[str, Any],
    env: dict[str, str],
    base: dict[str, Any],
    terminal: bool,
) -> list[str]:
    """The command srt runs: the agent's command with the agent's extra
    arguments after its program, started through the socket shell when the
    checkout narrows unix sockets, and through ``setsid -c`` on a
    terminal."""
    cmd = [command[0], *(agent.get("args") or []), *command[1:]]
    if env.get(SOCKETS_ENV_VAR):
        cmd = [base["socketShell"], "-c", 'exec "$0" "$@"', *cmd]
    if terminal:
        cmd = [base["setsid"], "-w", "-c", *cmd]
    return cmd


def _copy_winsize(src: int, dst: int) -> None:
    try:
        size = fcntl.ioctl(src, termios.TIOCGWINSZ, b"\0" * 8)
        fcntl.ioctl(dst, termios.TIOCSWINSZ, size)
    except OSError:
        pass


def relay(argv: list[str], env: dict[str, str]) -> int:
    """Run ``argv`` on a new pseudo-terminal, relaying it to this process's
    terminal, and return its exit status the way a shell reports it."""
    master, slave = os.openpty()
    _copy_winsize(sys.stdin.fileno(), master)
    pid = os.fork()
    if pid == 0:
        os.close(master)
        for fd in (0, 1, 2):
            os.dup2(slave, fd)
        if slave > 2:
            os.close(slave)
        try:
            os.execve(argv[0], argv, env)
        finally:
            os._exit(127)
    os.close(slave)
    stdin = sys.stdin.fileno()
    saved = termios.tcgetattr(stdin)
    signal.signal(signal.SIGWINCH, lambda *_: _copy_winsize(stdin, master))
    tty.setraw(stdin)
    try:
        while True:
            try:
                ready, _, _ = select.select([stdin, master], [], [])
            except InterruptedError:
                continue
            if master in ready:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    break
                if not data:
                    break
                os.write(sys.stdout.fileno(), data)
            if stdin in ready:
                data = os.read(stdin, 65536)
                if not data:
                    break
                os.write(master, data)
    finally:
        termios.tcsetattr(stdin, termios.TCSADRAIN, saved)
        signal.signal(signal.SIGWINCH, signal.SIG_DFL)
        os.close(master)
    _, status = os.waitpid(pid, 0)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return os.WEXITSTATUS(status)


def _prune_scratch(directory: Path) -> None:
    """Remove the directories of runs whose process is gone."""
    if not directory.is_dir():
        return
    for entry in directory.iterdir():
        if not entry.name.startswith("run-"):
            continue
        try:
            os.kill(int(entry.name[4:]), 0)
            continue
        except (ValueError, ProcessLookupError):
            pass
        except PermissionError:
            continue
        for path in sorted(entry.rglob("*"), reverse=True):
            if path.is_dir() and not path.is_symlink():
                path.rmdir()
            else:
                path.unlink()
        entry.rmdir()


def prepare(
    agent_name: str, command: list[str], directory: Path, terminal: bool
) -> tuple[list[str], dict[str, str]] | None:
    """The argv and environment that run ``command`` for ``agent_name`` in
    the checkout containing ``directory``, or None when that checkout is not
    enrolled with modules."""
    root = find_repo_root(directory)
    if root is None:
        return None
    migrate_state()
    migrate_checkout(root)
    sidecar = read_sidecar(root)
    if sidecar is None or sidecar["modules"] is None:
        return None
    from .cli import due_modules, expire_due

    if due_modules(sidecar):
        expire_due(root)
        sidecar = read_sidecar(root)
        if sidecar is None or sidecar["modules"] is None:
            return None

    registry = load_registry()
    agents = registry.get("agents") or {}
    if agent_name not in agents:
        raise ToolError(
            f"the registry declares no agent '{agent_name}' "
            f"(declared: {', '.join(sorted(agents)) or 'none'})"
        )
    agent = agents[agent_name]
    srt = registry.get("srt")
    if not srt:
        raise ToolError("the registry names no srt: set runtime.sandboxRuntimePackage and switch")
    base = load_part(registry.get("base"), "the base part")

    fragment = compose(
        registry,
        [*sidecar["modules"], *(agent.get("modules") or [])],
        {ROOT_ENV_VAR: str(root)},
    )
    env = {**os.environ, **fragment.get("env", {}), **(agent.get("env") or {})}

    # The run's directory holds its srt settings and its scratch; only the
    # scratch is writable inside the sandbox.
    runs = runtime_dir()
    _prune_scratch(runs)
    run_dir = runs / f"run-{os.getpid()}"
    scratch = run_dir / "tmp"
    scratch.mkdir(parents=True, exist_ok=True)
    os.chmod(run_dir, 0o700)
    env["TMPDIR"] = str(scratch)

    settings = srt_settings(fragment, root, registry.get("guards") or [], scratch, base.get("bwrap"))
    settings_file = run_dir / "srt.json"
    write_text_atomic(settings_file, json.dumps(settings, indent=2) + "\n")

    from .cli import provision_creds

    provision_creds(root)
    argv = [srt, "--settings", str(settings_file), "--", *sandboxed_command(command, agent, env, base, terminal)]
    return argv, env


def run(agent_name: str, command: list[str], directory: Path) -> int:
    if not command:
        raise ToolError("run needs a command after --")
    terminal = sys.stdin.isatty() and sys.stdout.isatty()
    prepared = prepare(agent_name, command, directory, terminal)
    if prepared is None:
        os.execvp(command[0], command)
    argv, env = prepared
    if terminal:
        return relay(argv, env)
    os.execve(argv[0], argv, env)
    return 127
