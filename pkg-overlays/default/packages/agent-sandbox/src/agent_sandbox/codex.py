# SPDX-License-Identifier: MIT
"""Compile enrollment grants for Codex's native sandbox.

Codex, like Claude Code, constructs the command sandbox itself. Its
bubblewrap wrapper inserts Landlock into the *final* command, after the
native helper has finished mounting filesystems and routing its proxy.
"""

from __future__ import annotations

import json
import hashlib
import os
import grp
import pwd
import shlex
import subprocess
import tomllib
from pathlib import Path
from typing import Any

from .files import ToolError, ensure_excluded, update_json, write_text_atomic

POLICY_ENV = "AGENT_SANDBOX_CODEX_POLICY"
PROJECT_SIDECAR = ".agent-sandbox/codex-config.json"


def permission_profile_id(project: Path) -> str:
    """A profile name identifies one clone, including in a shared daemon."""
    digest = hashlib.sha256(os.fsencode(project.resolve())).hexdigest()[:16]
    return f"agent-sandbox-{digest}"


def _selected_profile(config: dict[str, Any]) -> dict[str, Any]:
    return config["permissions"][config["default_permissions"]]


def _write_native_wrapper(wrapper: Path, policy_file: Path, base: dict[str, Any]) -> None:
    write_text_atomic(wrapper, f"#!{base['shell']}\nexec {shlex.quote(base['cli'])} codex-bwrap --policy "
                      f"{shlex.quote(str(policy_file))} -- \"$@\"\n")
    wrapper.chmod(0o500)


def refresh_runtime_command_environment(root: Path, config: dict[str, Any], base: dict[str, Any]) -> None:
    """Refresh a clone's command routing at the trusted sandbox boundary.

    Codex may retain a turn's old shell environment. The bwrap entry point
    is invoked for each new command, so it can enforce the declared PATH
    even for those sessions. This does not replace filesystem/network grants.
    """
    from .run import runtime_dir

    command_env = config["shell_environment_policy"]["set"]
    if "PATH" not in command_env:
        return
    directory = runtime_dir()
    if not directory.exists():
        return
    new_fs = _selected_profile(config)["filesystem"]
    for entry in directory.iterdir():
        policy_file = entry / "codex.json"
        if (not entry.name.startswith("run-") or entry.is_symlink()
                or not policy_file.is_file() or policy_file.is_symlink()):
            continue
        if entry.stat().st_uid != os.getuid() or entry.stat().st_mode & 0o077:
            continue
        accepted = False

        def refresh(value: dict[str, Any]) -> dict[str, Any] | None:
            nonlocal accepted
            old_config = value.get("config") or {}
            owner = old_config.get("shell_environment_policy", {}).get("set", {}).get("AGENT_SANDBOX_ROOT")
            if owner != str(root):
                return value
            old_fs = _selected_profile(old_config)["filesystem"]
            if old_fs.get("/nix/store") == "deny":
                # Environment refresh must not outrun an immutable store mask.
                if new_fs.get("/nix/store") != "deny" or any(
                    access == "read" and path.startswith("/nix/store/")
                    and old_fs.get(path) not in ("read", "write")
                    for path, access in new_fs.items()
                ):
                    return value
            accepted = True
            updated = {**value, "command_env": dict(command_env),
                       "landlock": base.get("landlock", value.get("landlock"))}
            # Native seccomp opens Unix sockets as a class; Landlock is
            # the per-path enforcement boundary. Sync the explicit clone's
            # IPC grants, preserving transient launch sockets. Track the
            # last synced set so dropping a module also revokes its socket.
            if updated.get("sockets") is not None:
                old_static = _selected_profile(old_config).get("network", {}).get("unix_sockets", {})
                previous = value.get("synced_socket_grants", list(old_static))
                granted = _selected_profile(config).get("network", {}).get("unix_sockets", {})
                selected = sorted(p for p, access in granted.items() if access == "allow")
                updated["sockets"] = sorted((set(updated["sockets"]) - set(previous)) | set(selected))
                updated["synced_socket_grants"] = selected
            return updated

        update_json(policy_file, refresh)
        if accepted:
            wrapper = entry / "bin/bwrap"
            if wrapper.parent.is_dir() and not wrapper.parent.is_symlink() and not wrapper.is_symlink():
                _write_native_wrapper(wrapper, policy_file, base)


def apply_project_config(root: Path, config: dict[str, Any], base: dict[str, Any]) -> None:
    """Persist only enrollment, never a launch's environment or helper paths."""
    merger = base.get("configMerger")
    if not merger:
        raise ToolError("the sandbox registry needs configMerger; activate the updated home configuration")
    if config:
        # Native missing-file guards need their parent directory to exist.
        # Inherited worktrees have no Claude settings file of their own.
        (root / ".claude").mkdir(exist_ok=True)
    result = subprocess.run(
        [merger, "apply", "--format", "toml", "--target", str(root / ".codex/config.toml"),
         "--fragment", "/dev/stdin", "--sidecar", str(root / PROJECT_SIDECAR),
         "--name", "agent-sandbox-codex"],
        input=json.dumps(config), text=True, capture_output=True,
    )
    if result.returncode:
        raise ToolError(f"cannot apply composed Codex enrollment: {result.stderr.strip()}")
    # The enrollment is per clone, like Claude Code's settings.local.json.
    ensure_excluded(root, "/.codex/config.toml")


def inheriting_worktrees(root: Path) -> list[Path]:
    """Enumerate only back-registered Git worktrees inheriting this binding.
    Explicit local enrollments and local abandonment are authoritative.
    """
    from .run import native_enrollment_root
    from .files import read_sidecar

    metadata_root = root / ".git/worktrees"
    if not metadata_root.is_dir():
        return []
    result = []
    for metadata in sorted(metadata_root.iterdir()):
        if not metadata.is_dir() or metadata.is_symlink():
            continue
        try:
            gitfile = Path((metadata / "gitdir").read_text().strip())
            linked = gitfile.parent.resolve()
            pointer = gitfile.read_text().strip()
            if gitfile.name != ".git" or not pointer.startswith("gitdir:"):
                continue
            if (linked / pointer.removeprefix("gitdir:").strip()).resolve() != metadata.resolve():
                continue
            if read_sidecar(linked) is None and native_enrollment_root(linked) == root:
                result.append(linked)
        except (OSError, ValueError, ToolError):
            continue
    return result


def sync_enrollment(root: Path, modules: list[str] | None, registry: dict[str, Any],
                    *, project_root: Path | None = None) -> None:
    """Enrollment changes update both agents from the same module selection."""
    from .compose import compose, resolve
    from .registry import load_part
    from .run import runtime_dir, srt_settings

    agents = registry.get("agents") or {}
    agent = next((value for name, value in agents.items()
                  if name in ("codex", "codex-acp") and value.get("backend") == "codex"), None)
    if agent is None:
        return
    base = load_part(registry.get("base"), "the base part")
    project_root = project_root or root
    inherited = inheriting_worktrees(root) if project_root == root else []
    if modules is None:
        if (project_root / PROJECT_SIDECAR).exists():
            apply_project_config(project_root, {}, base)
        for linked in inherited:
            sync_enrollment(root, modules, registry, project_root=linked)
        return
    chosen = [*modules, *(agent.get("modules") or [])]
    fragment = compose(registry, chosen, {"AGENT_SANDBOX_ROOT": str(root)})
    # configuration() uses only the stable runtime parent and :tmpdir.
    # No scratch directory, socket, bridge, or credential is created here.
    scratch = runtime_dir() / "run-enrollment/tmp"
    settings = srt_settings(fragment, root, registry.get("guards") or [], scratch, base.get("bwrap"),
                            project_root=project_root)
    git_write = any(part.get("allowGit", False) for part in resolve(registry, chosen).values())
    check_native_config(root, dict(os.environ))
    config = configuration(settings, root, scratch, git_write=git_write, project_root=project_root,
                           command_path=fragment["env"]["PATH"], module_env=fragment["env"])
    apply_project_config(project_root, config, base)
    refresh_runtime_command_environment(root, config, base)
    for linked in inherited:
        sync_enrollment(root, modules, registry, project_root=linked)


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
                  *, git_write: bool = False, project_root: Path | None = None,
                  command_path: str | None = None, module_env: dict[str, str] | None = None) -> dict[str, Any]:
    """Map srt-shaped grants to a native permission profile, refusing
    grants whose meaning Codex cannot preserve."""
    fs = settings["filesystem"]
    project_root = project_root or root
    paths: dict[str, Any] = {":root": "read", ":slash_tmp": "read", ":tmpdir": "write"}
    for key, access in (("denyRead", "deny"), ("allowRead", "read"),
                        ("allowWrite", "write"), ("denyWrite", "read")):
        for path in fs.get(key) or []:
            if key == "allowWrite" and path == str(scratch):
                continue  # :tmpdir grants scratch without making the profile launch-specific.
            if any(c in path for c in "*?["):
                raise ToolError(f"Codex native sandbox cannot preserve this {key} glob: {path}")
            paths[path] = access
    if git_write:
        paths.update(dict.fromkeys(git_write_paths(root, fs), "write"))
        if project_root != root:
            paths.update(dict.fromkeys(git_write_paths(project_root, fs), "write"))
    # Runtime policy and wrappers must stay immutable even if a module
    # grants a broader directory, such as /run/user/UID.
    paths[str(scratch.parent.parent)] = "read"
    paths[str(root / PROJECT_SIDECAR)] = "read"
    paths[str(root / ".codex/config.toml")] = "read"
    paths[str(project_root / PROJECT_SIDECAR)] = "read"
    paths[str(project_root / ".codex/config.toml")] = "read"
    net = settings["network"]
    domains = {}
    for key, access in (("allowedDomains", "allow"), ("deniedDomains", "deny")):
        for host in net.get(key) or []:
            if ":" in host:
                raise ToolError(f"Codex native domain rules cannot preserve port-scoped hosts: {host}")
            domains[host] = access
    network: dict[str, Any] = {
        "enabled": bool(net.get("allowedDomains")) or bool(net.get("allowLocalBinding")),
        "domains": domains,
        # The per-launch Emacs bridge belongs in Landlock's runtime policy,
        # not the named profile. Native Unix sockets are already open below;
        # Landlock enforces the full composed pathname list after mounts.
        "unix_sockets": {p: "allow" for p in net.get("allowUnixSockets") or []
                         if not Path(p).is_relative_to(scratch.parent)},
        # Native seccomp's socket switch is all-or-nothing. Landlock,
        # inserted after that stage, enforces the actual pathname list.
        "dangerously_allow_all_unix_sockets": True,
    }
    if "allowLocalBinding" in net:
        # Codex also uses this to exempt local test traffic from its HTTP
        # proxy. Without it, Python sends localhost requests to the host
        # proxy, which correctly rejects private-network destinations.
        network["allow_local_binding"] = net["allowLocalBinding"]
    # The three-way TOML merger drops empty tables. Use the same canonical
    # representation for CLI overrides and the persisted enrollment.
    for key in ("domains", "unix_sockets"):
        if not network[key]:
            del network[key]
    stable_env = {"SANDBOX_RUNTIME": "1", "AGENT_SANDBOX_ROOT": str(root)}
    for key in ("LD_PRELOAD", "AGENT_SANDBOX_UDEV_SOCKET"):
        if key in (module_env or {}):
            stable_env[key] = module_env[key]
    if command_path is not None:
        stable_env["PATH"] = command_path
    profile_id = permission_profile_id(project_root)
    return {
        "default_permissions": profile_id,
        "approval_policy": "on-request",
        "features": {"network_proxy": True, "shell_snapshot": False},
        "allow_login_shell": False,
        "shell_environment_policy": {"set": stable_env},
        "permissions": {profile_id: {
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
                   *, git_write: bool = False, project_root: Path | None = None,
                   module_env: dict[str, str] | None = None) -> list[str]:
    """Write this launch's policy and bwrap entry point, and return its
    native config overrides. The same file configures codex-acp's child."""
    project_root = project_root or root
    check_native_config(project_root, env)
    config = configuration(settings, root, scratch, git_write=git_write, project_root=project_root,
                           command_path=env["PATH"], module_env=module_env)
    # Resume and new-chat configuration must resolve the same enrollment as
    # launch. Persist before adding transient command-environment overrides.
    apply_project_config(project_root, config, base)
    refresh_runtime_command_environment(root, config, base)
    command_env = dict(config["shell_environment_policy"]["set"])
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
        "command_env": command_env,
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
    _write_native_wrapper(bwrap, policy_file, base)
    # Both the sandbox helper's launcher and the command environment
    # must find this wrapper ahead of any bundled or system bubblewrap.
    env["PATH"] = str(bin_dir) + ":" + env["PATH"]
    config["shell_environment_policy"]["set"]["PATH"] = env["PATH"]
    write_text_atomic(policy_file, json.dumps(policy, indent=2) + "\n")
    return config_args(config)


def _managed_manifest_owner(cwd: Path) -> str | None:
    """Find the nearest managed enrollment from nested command directories.
    This shortcut only retains an existing policy; it never grants new IPC.
    Stop at an independent real binding without a managed manifest.
    """
    for candidate in (cwd, *cwd.parents):
        try:
            managed = json.loads((candidate / PROJECT_SIDECAR).read_text())
            owner = managed.get("applied", {}).get("shell_environment_policy", {}).get("set", {}).get("AGENT_SANDBOX_ROOT")
            if owner and managed.get("target") == str(candidate / ".codex/config.toml"):
                return owner
        except (OSError, ValueError, TypeError):
            pass
        try:
            if (candidate / ".agent-sandbox/binding.json").read_bytes().strip() not in (b"", b"{}"):
                return None
        except OSError:
            pass
    return None


def socket_boundary_command(args: list[str], landlock: str, env: dict[str, str],
                            *, cwd: Path | None = None, guarded: bool | None = None) -> tuple[list[str], dict[str, str]]:
    """Select moved-thread IPC grants after native filesystem mounts.
    This entry point is also used by older immutable native launchers.
    Read-only file mounts, not chmod bits, establish enrollment authority.
    """
    from .run import native_enrollment_root
    from .files import read_sidecar

    cwd = cwd or Path.cwd()
    # Native guards synthesize empty files for absent local bindings in
    # inherited worktrees. A managed manifest naming the existing owner
    # needs no rebinding, so retain the already-enforced IPC policy before
    # attempting to interpret that synthetic binding as an enrollment.
    if _managed_manifest_owner(cwd) == env.get("AGENT_SANDBOX_ROOT") and env.get("AGENT_SANDBOX_ROOT"):
        return [landlock, *args], env
    root = native_enrollment_root(cwd)
    if str(root) == env.get("AGENT_SANDBOX_ROOT"):
        return [landlock, *args], env
    binding = read_sidecar(root)
    if binding is None:
        return [landlock, *args], env
    manifest = root / PROJECT_SIDECAR
    guard_paths = [manifest, root / ".agent-sandbox/binding.json"]
    if guarded is None:
        guarded = (os.access(root, os.W_OK)
                   and not (os.statvfs(root).f_flag & os.ST_RDONLY)
                   and all(os.statvfs(p).f_flag & os.ST_RDONLY for p in guard_paths))
    if not guarded or binding["modules"] is None:
        raise ToolError("moved socket boundary lacks a writable workspace and native read-only enrollment mounts")
    managed = json.loads(manifest.read_text())
    config = managed.get("applied") or {}
    selected_env = config.get("shell_environment_policy", {}).get("set", {})
    if managed.get("target") != str(root / ".codex/config.toml") or selected_env.get("AGENT_SANDBOX_ROOT") != str(root):
        raise ToolError("moved socket boundary enrollment target mismatch")
    try:
        command = args[args.index("--") + 1:]
    except ValueError as error:
        raise ToolError("socket boundary needs a command separator") from error
    sockets = _selected_profile(config).get("network", {}).get("unix_sockets", {})
    prefix = [landlock, "--restrict-sockets", "--socket-fallback", "closed"]
    for path, access in sorted(sockets.items()):
        if access == "allow":
            prefix += ["--allow", path]
    updated_env = {**env, **selected_env}
    return [*prefix, "--", *command], updated_env


def policy_for_command(args: list[str], policy: dict[str, Any]) -> dict[str, Any]:
    """A moved/forked thread may retain its old launch helper. Resolve
    IPC grants from the actual command's enrolled root, never by widening
    the old clone's shared helper. Require native read-only guards before
    reading the new enrollment; an agent-created nested manifest is not
    authority to grant a host socket. Native filesystem/IP policy remains
    in the untouched argv and continues to enforce the turn's permissions.
    """
    from .run import native_enrollment_root
    from .files import read_sidecar

    try:
        cwd_flag = "--command-cwd" if "--command-cwd" in args else "--sandbox-policy-cwd"
        cwd = Path(args[args.index(cwd_flag) + 1]).resolve()
    except (ValueError, IndexError):
        return policy
    old_env = policy.get("command_env") or policy.get("config", {}).get("shell_environment_policy", {}).get("set", {})
    if _managed_manifest_owner(cwd) == old_env.get("AGENT_SANDBOX_ROOT") and old_env.get("AGENT_SANDBOX_ROOT"):
        return policy
    root = native_enrollment_root(cwd)
    if str(root) == old_env.get("AGENT_SANDBOX_ROOT"):
        return policy
    binding = read_sidecar(root)
    if binding is None:
        # A command may legitimately run in /tmp while retaining the
        # thread's workspace policy. Prefer that enrolled policy cwd.
        try:
            root = native_enrollment_root(Path(args[args.index("--sandbox-policy-cwd") + 1]).resolve())
            binding = read_sidecar(root)
        except (ValueError, IndexError):
            return policy
        if str(root) == old_env.get("AGENT_SANDBOX_ROOT") or binding is None:
            return policy
    if binding["modules"] is None:
        raise ToolError("moved native command has no active enrollment")
    manifest = root / PROJECT_SIDECAR
    try:
        native = json.loads(args[args.index("--permission-profile") + 1])
        entries = native["file_system"]["entries"]
    except (ValueError, IndexError, KeyError, TypeError) as error:
        raise ToolError("cannot verify native guards for moved enrollment") from error
    for guard in (manifest, root / ".agent-sandbox/binding.json"):
        accesses = [e.get("access") for e in entries
                    if isinstance(e.get("path"), dict) and e["path"].get("path") == str(guard)]
        if "read" not in accesses or "write" in accesses:
            raise ToolError("moved enrollment lacks native read-only guards")
    managed = json.loads(manifest.read_text())
    config = managed.get("applied") or {}
    env = config.get("shell_environment_policy", {}).get("set", {})
    if managed.get("target") != str(root / ".codex/config.toml") or env.get("AGENT_SANDBOX_ROOT") != str(root):
        raise ToolError("moved enrollment target does not match its guarded root")
    sockets = _selected_profile(config).get("network", {}).get("unix_sockets", {})
    return {**policy, "command_env": dict(env), "path": env["PATH"],
            "sockets": sorted(p for p, access in sockets.items() if access == "allow")}


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
    environment = []
    for key, value in sorted((policy.get("command_env") or {}).items()):
        if key not in ("PATH", "SANDBOX_RUNTIME", "AGENT_SANDBOX_ROOT", "LD_PRELOAD", "AGENT_SANDBOX_UDEV_SOCKET") or not isinstance(value, str):
            raise ToolError("unsupported command environment in native policy")
        if key not in ("LD_PRELOAD", "AGENT_SANDBOX_UDEV_SOCKET"):
            environment += ["--setenv", key, value]
    if sockets is not None:
        prefix = [policy["landlock"], "--restrict-sockets", "--socket-fallback", "closed"]
        for path in sockets:
            prefix += ["--allow", path]
        prefix += ["--"]
    bridge_env = policy.get("command_env") or {}
    preload = bridge_env.get("LD_PRELOAD")
    udev_socket = bridge_env.get("AGENT_SANDBOX_UDEV_SOCKET")
    if preload or udev_socket:
        if not preload or not udev_socket or not Path(preload).is_absolute():
            raise ToolError("incomplete udev monitor environment")
        if sockets is not None and udev_socket not in sockets:
            raise ToolError("udev monitor broker is not in the socket allowlist")
        bridge_exec = str(Path(preload).parent.parent / "bin/udev-monitor-exec")
        prefix += [bridge_exec, preload, udev_socket, "--"]
    # A command must not create another namespace and detach native
    # read-only guards. Landlock also blocks mount operations when used.
    return [policy["bwrap"], "--disable-userns", *args[:outer],
            *(policy.get("identity_binds") or []), *environment,
            *args[outer:inner + 1], *prefix, *args[inner + 1:]]


def exec_native(command: list[str]) -> None:
    if not command:
        raise ToolError("codex-exec needs a command")
    path = os.environ.get(POLICY_ENV)
    if not path:
        raise ToolError("codex-exec needs the native policy from agent-sandbox run")
    policy = json.loads(Path(path).read_text())
    os.execvpe(command[0], [command[0], *config_args(policy["config"]), *command[1:]], os.environ)
