# SPDX-License-Identifier: MIT
"""Compile enrollment grants for Codex's native sandbox.

Codex, like Claude Code, constructs the command sandbox itself. Its
bubblewrap wrapper inserts Landlock into the *final* command, after the
native helper has finished mounting filesystems and routing its proxy.
"""

from __future__ import annotations

import json
import os
import grp
import pwd
import shlex
import tomllib
from pathlib import Path
from typing import Any

from .files import ToolError, write_text_atomic

POLICY_ENV = "AGENT_SANDBOX_CODEX_POLICY"


def check_native_config(root: Path, env: dict[str, str]) -> None:
    """Legacy sandbox settings override named profiles, even at lower
    precedence. Never launch with a silently inactive enrollment."""
    home = Path(env.get("CODEX_HOME") or str(Path(env.get("HOME", str(Path.home()))) / ".codex"))
    paths = [Path("/etc/codex/config.toml"), home / "config.toml"]
    paths.extend(p / ".codex/config.toml" for p in [root, *root.parents])

    def legacy(value: Any) -> bool:
        return isinstance(value, dict) and (
            any(k in value for k in ("sandbox_mode", "sandbox_workspace_write"))
            or any(legacy(v) for v in value.values())
        )

    for path in paths:
        if path.is_file() and legacy(tomllib.loads(path.read_text())):
            raise ToolError(f"{path} selects legacy sandbox settings, which override Codex's native "
                            "permission profile; remove sandbox_mode/sandbox_workspace_write before launching")


def git_write_paths(root: Path, filesystem: dict[str, Any]) -> list[str]:
    """Reopen Git metadata only within the enrollment's existing grants.

    Worktrees and submodules use a .git pointer and may share a common
    directory. A pointer must never turn enrollment into an external
    filesystem grant. Explicit read/write guards remain authoritative.
    """
    entry = root / ".git"
    guarded = [Path(p).resolve() for key in ("denyWrite", "denyRead")
               for p in filesystem.get(key) or []]
    if any(entry.resolve().is_relative_to(base) for base in guarded):
        return []
    targets = [entry]
    metadata = entry
    if entry.is_file():
        pointer = entry.read_text().strip()
        if pointer.startswith("gitdir:"):
            metadata = (root / pointer[len("gitdir:"):].strip()).resolve()
            targets.append(metadata)
            common = metadata / "commondir"
            if common.is_file():
                targets.append((metadata / common.read_text().strip()).resolve())
    writable = [Path(p).resolve() for p in filesystem.get("allowWrite") or []]
    return [str(p) for p in targets
            if any(p.resolve().is_relative_to(base) for base in writable)
            and not any(p.resolve().is_relative_to(base) for base in guarded)]


def configuration(settings: dict[str, Any], root: Path, scratch: Path,
                  *, git_write: bool = False) -> dict[str, Any]:
    """Map srt-shaped grants to a native permission profile, refusing
    grants whose meaning Codex cannot preserve."""
    fs = settings["filesystem"]
    paths: dict[str, Any] = {":root": "read", ":slash_tmp": "read"}
    for key, access in (("denyRead", "deny"), ("allowRead", "read"),
                        ("allowWrite", "write"), ("denyWrite", "read")):
        for path in fs.get(key) or []:
            if any(c in path for c in "*?["):
                raise ToolError(f"Codex native sandbox cannot preserve this {key} glob: {path}")
            paths[path] = access
    if git_write:
        paths.update(dict.fromkeys(git_write_paths(root, fs), "write"))
    # Runtime policy and wrappers must stay immutable even if a module
    # grants a broader directory, such as /run/user/UID.
    paths[str(scratch.parent)] = "read"
    paths[str(scratch)] = "write"
    net = settings["network"]
    domains = {}
    for key, access in (("allowedDomains", "allow"), ("deniedDomains", "deny")):
        for host in net.get(key) or []:
            if ":" in host:
                raise ToolError(f"Codex native domain rules cannot preserve port-scoped hosts: {host}")
            domains[host] = access
    network: dict[str, Any] = {
        "enabled": bool(net.get("allowedDomains")),
        "domains": domains,
        "unix_sockets": {p: "allow" for p in net.get("allowUnixSockets") or []},
        # Native seccomp's socket switch is all-or-nothing. Landlock,
        # inserted after that stage, enforces the actual pathname list.
        "dangerously_allow_all_unix_sockets": True,
    }
    return {
        "default_permissions": "agent-sandbox",
        "approval_policy": "on-request",
        "features": {"network_proxy": True, "shell_snapshot": False},
        "allow_login_shell": False,
        "permissions": {"agent-sandbox": {
            "extends": ":workspace", "filesystem": paths, "network": network,
        }},
    }


def _toml(value: Any) -> str:
    if isinstance(value, dict):
        return "{" + ",".join(f"{json.dumps(k)}={_toml(v)}" for k, v in value.items()) + "}"
    return json.dumps(value)


def config_args(config: dict[str, Any]) -> list[str]:
    args = []
    for key, value in config.items():
        args += ["-c", f"{key}={_toml(value)}"]
    return args


def prepare_native(settings: dict[str, Any], root: Path, scratch: Path,
                   base: dict[str, Any], env: dict[str, str],
                   *, git_write: bool = False) -> list[str]:
    """Write this launch's policy and bwrap entry point, and return its
    native config overrides. The same file configures codex-acp's child."""
    check_native_config(root, env)
    config = configuration(settings, root, scratch, git_write=git_write)
    config["shell_environment_policy"] = {"set": {
        **{k: v for k, v in env.items() if k.startswith("AGENT_SANDBOX_")},
        "PATH": env["PATH"], "SHELL": base["shell"], "SANDBOX_RUNTIME": "1",
        "TMPDIR": str(scratch), "TMPPREFIX": str(scratch / "zsh"),
    }}
    # Unlike a whole-agent sandbox, the native boundary begins at each
    # tool command. Do not apply the socket shell to the trusted parent.
    env["SHELL"] = base["shell"]
    policy = {
        "config": config, "bwrap": base["bwrap"], "landlock": base["landlock"],
        "path": env["PATH"],
        # An explicit open grant stays open. Otherwise even the empty
        # list means no external sockets, not unrestricted access.
        "sockets": None if settings["network"].get("allowAllUnixSockets")
            and not env.get("AGENT_SANDBOX_UNIX_SOCKETS")
            else (settings["network"].get("allowUnixSockets") or []),
    }
    policy_file = scratch.parent / "codex.json"
    # Homed/userdb identities may not occur in /etc/passwd. Resolve the
    # launching identity outside the socket boundary, rather than grant
    # commands access to the host's user-management daemon.
    user = pwd.getpwuid(os.getuid())
    group = grp.getgrgid(os.getgid())
    identity_files = []
    for name, record in (
        ("passwd", f"{user.pw_name}:x:{user.pw_uid}:{user.pw_gid}:{user.pw_gecos}:{user.pw_dir}:{user.pw_shell}"),
        ("group", f"{group.gr_name}:x:{group.gr_gid}:"),
    ):
        source = Path("/etc") / name
        lines = source.read_text().splitlines()
        if not any(line.split(":")[2:3] == record.split(":")[2:3] for line in lines):
            lines.append(record)
        target = scratch.parent / name
        write_text_atomic(target, "\n".join(lines) + "\n")
        identity_files += ["--ro-bind", str(target), str(source)]
    policy["identity_binds"] = identity_files
    env[POLICY_ENV] = str(policy_file)
    config["shell_environment_policy"]["set"][POLICY_ENV] = str(policy_file)
    bin_dir = scratch.parent / "bin"
    bin_dir.mkdir(exist_ok=True)
    bwrap = bin_dir / "bwrap"
    write_text_atomic(bwrap, f"#!{base['shell']}\nexec {shlex.quote(base['cli'])} codex-bwrap --policy "
                      f"{shlex.quote(str(policy_file))} -- \"$@\"\n")
    bwrap.chmod(0o500)
    # Both the sandbox helper's launcher and the command environment
    # must find this wrapper ahead of any bundled or system bubblewrap.
    env["PATH"] = str(bin_dir) + ":" + env["PATH"]
    config["shell_environment_policy"]["set"]["PATH"] = env["PATH"]
    write_text_atomic(policy_file, json.dumps(policy, indent=2) + "\n")
    return config_args(config)


def bwrap_command(args: list[str], policy: dict[str, Any]) -> list[str]:
    """Insert socket confinement after native mounts and seccomp setup.
    Preserve the helper's argv0, fd arguments, and chosen user shell."""
    if args in (["--help"], ["--version"]):
        return [policy["bwrap"], *args]
    try:
        outer = args.index("--")
        stage = args.index("--apply-seccomp-then-exec", outer + 1)
        inner = args.index("--", stage + 1)
    except ValueError as e:
        raise ToolError("unrecognized Codex native bubblewrap launch; refusing to omit confinement") from e
    sockets = policy.get("sockets")
    prefix = []
    if sockets is not None:
        prefix = [policy["landlock"], "--restrict-sockets", "--socket-fallback", "closed"]
        for path in sockets:
            prefix += ["--allow", path]
        prefix += ["--"]
    # A command must not create another namespace and detach native
    # read-only guards. Landlock also blocks mount operations when used.
    return [policy["bwrap"], "--disable-userns", *args[:outer],
            *(policy.get("identity_binds") or []), *args[outer:inner + 1], *prefix, *args[inner + 1:]]


def exec_native(command: list[str]) -> None:
    if not command:
        raise ToolError("codex-exec needs a command")
    path = os.environ.get(POLICY_ENV)
    if not path:
        raise ToolError("codex-exec needs the native policy from agent-sandbox run")
    policy = json.loads(Path(path).read_text())
    os.execvpe(command[0], [command[0], *config_args(policy["config"]), *command[1:]], os.environ)
