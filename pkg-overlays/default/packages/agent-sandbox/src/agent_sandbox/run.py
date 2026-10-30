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
- An MCP server the agent starts runs inside the sandbox with it, unlike
  the MCP servers of Claude Code. When the registry names the Emacs MCP
  bridge (``emacsMcp``), this process serves it from outside on a socket
  of the run, which the sandbox may reach (``EmacsMcpServer``). This
  process therefore stays the parent of the sandbox for the whole run.

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
import socket
import subprocess
import sys
import termios
import threading
import tty
from pathlib import Path
from typing import Any

from .compose import SOCKETS_ENV_VAR, compose
from .files import ToolError, find_repo_root, migrate_checkout, migrate_state, read_sidecar, write_text_atomic
from .registry import load_part, load_registry

ROOT_ENV_VAR = "AGENT_SANDBOX_ROOT"
EMACS_MCP_ENV_VAR = "AGENT_SANDBOX_EMACS_MCP"


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
    # srt refuses a settings file whose network table lacks either domain
    # list.
    network: dict[str, Any] = {
        "allowedDomains": list(net.get("allowedDomains") or []),
        "deniedDomains": list(net.get("deniedDomains") or []),
    }
    for key in ("allowUnixSockets", "allowAllUnixSockets"):
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
) -> tuple[list[str], dict[str, str], "EmacsMcpServer | None"] | None:
    """The argv and environment that run ``command`` for ``agent_name`` in
    the checkout containing ``directory``, with the Emacs MCP server this
    run serves when the registry names one, or None when that checkout is
    not enrolled with modules."""
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
    # srt sets the sandbox's TMPDIR from CLAUDE_CODE_TMPDIR, and to
    # /tmp/claude, shared by every sandbox, without it.
    env["TMPDIR"] = env["CLAUDE_CODE_TMPDIR"] = str(scratch)

    # The Emacs MCP server, served from outside the sandbox on a socket of
    # this run (see EmacsMcpServer).
    server = None
    emacs_mcp = registry.get("emacsMcp")
    if emacs_mcp:
        socket_path = run_dir / "emacs-mcp.sock"
        grant_socket(fragment, str(socket_path))
        env.update(fragment["env"])
        env[EMACS_MCP_ENV_VAR] = str(socket_path)
        server = EmacsMcpServer(socket_path, emacs_mcp, root, dict(os.environ))

    settings = srt_settings(fragment, root, registry.get("guards") or [], scratch, base.get("bwrap"))
    # srt can grant only a path that exists, and inside the sandbox the
    # parent of a missing directory is read-only, so an agent could not
    # create its own state directory on first use.
    for path in settings["filesystem"]["allowWrite"]:
        Path(path).mkdir(parents=True, exist_ok=True)
    settings_file = run_dir / "srt.json"
    write_text_atomic(settings_file, json.dumps(settings, indent=2) + "\n")

    from .cli import provision_creds

    provision_creds(root)
    argv = [srt, "--settings", str(settings_file), "--", *sandboxed_command(command, agent, env, base, terminal)]
    return argv, env, server


def grant_socket(fragment: dict[str, Any], path: str) -> None:
    """Let the sandbox reach the unix socket ``path`` and nothing more:
    the socket joins the composed allowlist, which the socket shell
    enforces, unless a chosen module already allows every socket."""
    net = fragment.setdefault("sandbox", {}).setdefault("network", {})
    env = fragment.setdefault("env", {})
    open_already = net.get("allowAllUnixSockets") and not env.get(SOCKETS_ENV_VAR)
    net["allowUnixSockets"] = [*(net.get("allowUnixSockets") or []), path]
    if open_already:
        return
    net["allowAllUnixSockets"] = True
    listed = [entry for entry in env.get(SOCKETS_ENV_VAR, "").split("\n") if entry]
    env[SOCKETS_ENV_VAR] = "\n".join([*listed, path])


class EmacsMcpServer:
    """The Emacs MCP server for an agent inside the sandbox.

    The bridge `emacs-mcp-stdio` reaches Emacs through the daemon's
    socket, and a process holding that socket can evaluate any Lisp, so
    the sandbox never gets it. Instead this process, outside the sandbox,
    listens on a socket of the run and starts the bridge for each
    connection, with the checkout root as its working directory: the
    MCP server confines writes to the project of that directory, so the
    agent cannot choose a wider one. Inside the sandbox the bridge
    command only relays its stdio to this socket (it finds the socket in
    ``AGENT_SANDBOX_EMACS_MCP``), so the agent can speak MCP and nothing
    else."""

    def __init__(self, path: Path, command: list[str], cwd: Path, env: dict[str, str]) -> None:
        self.path = path
        self.command = command
        self.cwd = cwd
        self.env = env
        self.children: list[subprocess.Popen[bytes]] = []
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        if path.exists():
            path.unlink()
        self.sock.bind(str(path))
        os.chmod(path, 0o600)
        self.sock.listen(8)
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self) -> None:
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            with conn:
                self.children.append(
                    subprocess.Popen(
                        self.command,
                        cwd=self.cwd,
                        env=self.env,
                        stdin=conn.fileno(),
                        stdout=conn.fileno(),
                        stderr=subprocess.DEVNULL,
                        start_new_session=True,
                    )
                )

    def close(self) -> None:
        self.sock.close()
        try:
            self.path.unlink()
        except FileNotFoundError:
            pass
        for child in self.children:
            if child.poll() is None:
                child.terminate()


def supervise(argv: list[str], env: dict[str, str]) -> int:
    """Run ``argv`` as a child, forwarding the signals that end a session,
    and return its exit status the way a shell reports it."""
    child = subprocess.Popen(argv, env=env)
    forward = (signal.SIGHUP, signal.SIGINT, signal.SIGQUIT, signal.SIGTERM)
    previous = {sig: signal.signal(sig, lambda sig, _frame: child.send_signal(sig)) for sig in forward}
    try:
        status = child.wait()
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    return 128 - status if status < 0 else status


def run(agent_name: str, command: list[str], directory: Path) -> int:
    if not command:
        raise ToolError("run needs a command after --")
    terminal = sys.stdin.isatty() and sys.stdout.isatty()
    prepared = prepare(agent_name, command, directory, terminal)
    if prepared is None:
        os.execvp(command[0], command)
    argv, env, server = prepared
    # This process stays the parent of the sandbox, because it serves the
    # Emacs MCP server for the agent inside.
    try:
        if terminal:
            return relay(argv, env)
        return supervise(argv, env)
    finally:
        if server is not None:
            server.close()
