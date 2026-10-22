# SPDX-License-Identifier: MIT
"""claude-code-sandbox: enroll checkouts into compositions of nix-declared
Claude Code sandbox modules.

A sandbox module says what one kind of tooling needs inside the sandbox:
its executables, domains, sockets and writable paths. A checkout chooses
the set of modules its work needs. Enrollment composes them into one
fragment, writes it into the checkout's co-owned
``.claude/settings.local.json`` (three-way merge; Claude Code's own keys
are never touched), and records the chosen set and what was applied in
the sidecar ``.claude/claude-code-sandbox.json``. Claude Code live-reloads
settings files, so changes generally apply to running sessions; removing
an ``env`` variable is the documented exception (next launch).
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .compose import check_known, compose, module_names
from .files import (
    ToolError,
    find_repo_root,
    read_json,
    read_sidecar,
    settings_path,
    update_json,
    write_sidecar,
    write_text_atomic,
)
from .merge import adhoc_additions, merge
from .registry import MaskedStore, load_part, load_registry
from .report import checkout_state, describe, describe_text, require_enrolled

_SKIP_DIRS = {".git", "node_modules", ".direnv", ".cache", "result"}


def _root_or_die(directory: Path) -> Path:
    root = find_repo_root(directory)
    if root is None:
        raise ToolError(f"{directory} is not inside a git repository")
    return root


ROOT_ENV_VAR = "CLAUDE_CODE_SANDBOX_ROOT"


def _fragment_for(root: Path, modules: list[str] | None) -> dict[str, Any]:
    """The fragment a checkout bound to ``modules`` should carry. An
    abandoned checkout (``modules`` is None) carries nothing.

    The fragment's env names this checkout's enrolled root, so it
    reaches sandboxed commands (settings env is the only channel that
    does: hooks can't inject env, CLAUDE_PROJECT_DIR is hook-only, and
    the module parts are generated without knowing the checkout). The
    ssh wrapper reads it to locate the credentials dir independent of
    cwd. Making it part of the applied fragment keeps the merge
    authoritative for the key (it lives in base and new), so no
    ad-hoc-addition noise."""
    if modules is None:
        return {}
    return compose(load_registry(), modules, {ROOT_ENV_VAR: str(root)})


def _describe(modules: list[str] | None) -> str:
    if modules is None:
        return "abandoned"
    return f"modules [{', '.join(modules)}]" if modules else "modules [] (base only)"


def _apply(root: Path, modules: list[str] | None, base: dict[str, Any], quiet: bool) -> None:
    """Write the fragment for ``modules`` into the checkout's settings and
    record the binding. A module the checkout now chooses loses any
    recorded refusal, because choosing it is the user's newer answer."""
    sidecar = read_sidecar(root)
    declined = {
        name: refusal
        for name, refusal in (sidecar["declined"] if sidecar else {}).items()
        if name not in (modules or [])
    }
    fragment = _fragment_for(root, modules)
    reports = []

    def transform(current: dict[str, Any]) -> dict[str, Any] | None:
        merged, report = merge(current, base, fragment)
        reports.append(report)
        return merged

    changed = update_json(settings_path(root), transform)
    write_sidecar(root, modules, fragment, declined)
    if quiet:
        return
    state = "updated" if changed else "already current"
    print(f"{root}: {_describe(modules)} {state}")
    if reports and reports[-1].has_findings():
        r = reports[-1]
        for path, value, new in r.overridden_scalars:
            print(f"  overrode drifted {path}: {value!r} -> {new!r}")
        for path, value in r.preserved_drift:
            print(f"  preserved local value at dropped key {path}: {value!r}")
        for path, extras in r.adhoc_entries:
            print(f"  kept {len(extras)} ad-hoc entr{'y' if len(extras) == 1 else 'ies'} in {path}")


def _legacy_message(root: Path, profile: str) -> str:
    return (
        f"{root}: bound to profile '{profile}', which no longer exists; "
        "enroll it with sandbox modules (claude-code-sandbox list shows them)"
    )


def _status_line(root: Path) -> tuple[str, bool]:
    """One status line for a checkout; second element = needs attention."""
    sidecar = read_sidecar(root)
    settings = read_json(settings_path(root))
    if sidecar is None:
        if "sandbox" in settings or "env" in settings:
            return (f"{root}: unmanaged (sandbox/env keys present, no sidecar)", True)
        return (f"{root}: not enrolled", False)
    if sidecar["legacy_profile"] is not None:
        return (_legacy_message(root, sidecar["legacy_profile"]), True)
    modules = sidecar["modules"]
    applied = sidecar["applied"]
    # From inside a masked-store sandbox the registry and parts (HM
    # symlinks into /nix/store) are unreadable; the sidecar and settings
    # still are, so enrollment and integrity remain reportable. Only
    # freshness needs the parts.
    stale: bool | None
    try:
        fragment = _fragment_for(root, modules)
    except MaskedStore:
        stale = None
    except ToolError as e:
        return (f"{root}: {_describe(modules)} DANGLING ({e})", True)
    else:
        # The sidecar stores what _apply wrote (root env included), and
        # _fragment_for adds the same root env, so equal means current.
        stale = fragment != applied
    # Replay the applied blob: if re-merging it changes anything, a
    # foreign writer dropped tool-owned keys (clobbering is removals, so
    # neither staleness nor ad-hoc detection would see it).
    replayed, _ = merge(settings, applied, applied)
    clobbered = replayed != settings
    adhoc = adhoc_additions(settings, applied)
    bits = [_describe(modules)]
    if clobbered:
        bits.append("CLOBBERED: applied keys missing from settings (sync restores)")
    elif stale is None:
        bits.append("applied (freshness unknown here: store masked, parts unreadable)")
    else:
        bits.append("STALE (sync to update)" if stale else "current")
    if adhoc:
        entries = sum(len(x) for _, x in adhoc)
        paths = ", ".join(p for p, _ in adhoc)
        bits.append(f"{entries} local addition(s) in {paths}")
    if sidecar["declined"]:
        bits.append(f"declined [{', '.join(sorted(sidecar['declined']))}]")
    return (f"{root}: " + ", ".join(bits), bool(stale) or clobbered)


def _iter_enrolled(roots: list[Path]) -> list[Path]:
    found: list[Path] = []
    for top in roots:
        if not top.is_dir():
            continue
        for dirpath, dirnames, _filenames in os.walk(top):
            dirnames[:] = [d for d in dirnames if d not in _SKIP_DIRS]
            here = Path(dirpath)
            if (here / ".claude" / "claude-code-sandbox.json").is_file() or (
                here / ".claude" / "settings.local.json"
            ).is_file():
                found.append(here)
                dirnames[:] = []  # do not descend into nested checkouts
    return found


def _chosen_modules(root: Path) -> tuple[dict[str, Any], list[str]]:
    """The sidecar and chosen modules of a checkout enrolled with
    modules, the binding that add and drop edit."""
    sidecar = read_sidecar(root)
    if sidecar is None:
        raise ToolError(f"{root} is not enrolled (use enroll)")
    if sidecar["legacy_profile"] is not None:
        raise ToolError(_legacy_message(root, sidecar["legacy_profile"]))
    if sidecar["modules"] is None:
        raise ToolError(f"{root} is abandoned (use enroll to choose modules again)")
    return sidecar, sidecar["modules"]


def cmd_enroll(args: argparse.Namespace) -> int:
    root = _root_or_die(Path(args.directory))
    modules = sorted(set(args.modules))
    check_known(load_registry(), modules)
    sidecar = read_sidecar(root)
    base = sidecar["applied"] if sidecar else {}
    _apply(root, modules, base, args.quiet)
    return 0


def cmd_add(args: argparse.Namespace) -> int:
    root = _root_or_die(Path(args.directory))
    sidecar, current = _chosen_modules(root)
    check_known(load_registry(), args.modules)
    _apply(root, sorted(set(current) | set(args.modules)), sidecar["applied"], args.quiet)
    return 0


def cmd_drop(args: argparse.Namespace) -> int:
    root = _root_or_die(Path(args.directory))
    sidecar, current = _chosen_modules(root)
    absent = sorted(set(args.modules) - set(current))
    if absent:
        raise ToolError(f"{root} has not chosen {', '.join(absent)} ({_describe(current)})")
    _apply(root, sorted(set(current) - set(args.modules)), sidecar["applied"], args.quiet)
    return 0


def cmd_abandon(args: argparse.Namespace) -> int:
    root = _root_or_die(Path(args.directory))
    sidecar = read_sidecar(root)
    base = sidecar["applied"] if sidecar else {}
    _apply(root, None, base, args.quiet)
    if not args.quiet:
        print(
            "note: a live session keeps env vars from the old modules until "
            "its next launch (documented removal behavior)"
        )
    return 0


def cmd_sync(args: argparse.Namespace) -> int:
    root = _root_or_die(Path(args.directory))
    sidecar = read_sidecar(root)
    if sidecar is None:
        raise ToolError(f"{root} is not enrolled (use enroll)")
    if sidecar["legacy_profile"] is not None:
        raise ToolError(_legacy_message(root, sidecar["legacy_profile"]))
    _apply(root, sidecar["modules"], sidecar["applied"], args.quiet)
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    root = _root_or_die(Path(args.directory))
    line, attention = _status_line(root)
    print(line)
    return 2 if attention else 0


def cmd_scan(args: argparse.Namespace) -> int:
    top = Path(args.directory).expanduser()
    if not top.is_dir():
        raise ToolError(f"{top} is not a directory")
    attention = False
    found = False
    for root in _iter_enrolled([top]):
        found = True
        line, needs = _status_line(root)
        print(line)
        attention = attention or needs
    if not found:
        print(f"{top}: no checkouts with .claude state found")
    return 2 if attention else 0


def refusal_text(name: str, refusal: dict[str, Any]) -> str:
    text = f"Declined for this checkout at {refusal.get('at', 'an unknown time')}"
    if refusal.get("reason"):
        text += f": {refusal['reason']}"
    return text + f". `claude-code-sandbox undecline {name}` withdraws the refusal."


def cmd_show(args: argparse.Namespace) -> int:
    registry = load_registry()
    root = find_repo_root(Path(args.directory))
    state = checkout_state(root, registry) if root is not None else None
    for i, name in enumerate(args.modules):
        if i:
            print()
        print(describe_text(describe(registry, name, state)))
        refusal = (state or {}).get("declined", {}).get(name)
        if refusal:
            print(refusal_text(name, refusal))
    return 0


def enable_modules(root: Path, names: list[str]) -> list[str]:
    """Add ``names`` to the checkout's chosen set and apply it; returns
    the new chosen set."""
    sidecar, current = _chosen_modules(root)
    check_known(load_registry(), names)
    chosen = sorted(set(current) | set(names))
    _apply(root, chosen, sidecar["applied"], quiet=True)
    return chosen


def decline_modules(root: Path, names: list[str], reason: str | None) -> None:
    """Record the user's refusal of ``names`` for this checkout. An
    enabled module cannot be declined; the user drops it first."""
    registry = load_registry()
    check_known(registry, names)
    state = checkout_state(root, registry)
    require_enrolled(state)
    on = sorted(name for name in names if name in state["enabled"])
    if on:
        raise ToolError(f"{', '.join(on)} enabled in {root}; drop before declining")
    sidecar = read_sidecar(root)
    assert sidecar is not None
    at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    declined = dict(sidecar["declined"])
    for name in names:
        declined[name] = {"at": at, **({"reason": reason} if reason else {})}
    write_sidecar(root, sidecar["modules"], sidecar["applied"], declined)


def cmd_decline(args: argparse.Namespace) -> int:
    root = _root_or_die(Path(args.directory))
    decline_modules(root, args.modules, args.reason)
    if not args.quiet:
        print(f"{root}: declined [{', '.join(sorted(set(args.modules)))}]")
    return 0


def cmd_undecline(args: argparse.Namespace) -> int:
    root = _root_or_die(Path(args.directory))
    sidecar = read_sidecar(root)
    if sidecar is None:
        raise ToolError(f"{root} is not enrolled (use enroll)")
    absent = sorted(set(args.modules) - set(sidecar["declined"]))
    if absent:
        raise ToolError(f"{root} has not declined {', '.join(absent)}")
    declined = {k: v for k, v in sidecar["declined"].items() if k not in args.modules}
    write_sidecar(root, sidecar["modules"], sidecar["applied"], declined)
    if not args.quiet:
        print(f"{root}: withdrew the refusal of [{', '.join(sorted(set(args.modules)))}]")
    return 0


def cmd_mcp(args: argparse.Namespace) -> int:
    from .mcp import serve

    return serve()


def cmd_list(args: argparse.Namespace) -> int:
    registry = load_registry()
    always = set(registry.get("baseModules") or [])
    for name in module_names(registry):
        part = load_part(registry["modules"][name], f"module '{name}'")
        notes = []
        if name in always:
            notes.append("in every enrollment")
        if part.get("requires"):
            notes.append(f"requires {', '.join(part['requires'])}")
        if not part.get("masked", True):
            notes.append("unmasks the store")
        line = name + (f" ({'; '.join(notes)})" if notes else "")
        if part.get("description"):
            line += f": {part['description']}"
        print(line)
    return 0


def _git_dir(root: Path) -> Path | None:
    """The checkout's own git directory (a worktree's private one for
    linked worktrees). None when git cannot tell us."""
    try:
        out = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "--absolute-git-dir"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    return Path(out) if out else None


SCRATCH_SUBDIR = Path(".claude") / "claude-code-sandbox" / "jobs"
CREDS_SUBDIR = Path(".claude") / "claude-code-sandbox" / "creds"


def creds_dir(root: Path) -> Path:
    """The checkout's credentials dir: user-owned (written unsandboxed),
    inside the sandbox's default read/write scope, git-excluded alongside
    the job scratch. Its absolute path is knowable at enroll time, so
    fragment env / farm wrappers can name it literally."""
    return root / CREDS_SUBDIR


def provision_creds(root: Path) -> list[str]:
    """Materialize the registry's credential files as user-owned copies
    under the checkout's creds dir, so sandboxed tools whose config
    ownership checks reject the store-symlinked originals can read them.

    Runs from the unsandboxed session-start hook, so the invoking user
    owns the copies (inside the sandbox's user namespace, the store's
    root owner maps to nobody). A registry entry with a null source is
    created as an empty 0600 file, a drop point for a runtime
    provisioner to fill with a delegated credential. Returns the target
    filenames written. Best-effort per entry; a missing source is
    skipped (nothing to copy)."""
    try:
        registry = load_registry()
    except MaskedStore:
        return []
    creds = registry.get("credentials") or {}
    if not creds:
        return []
    out = creds_dir(root)
    written: list[str] = []
    for entry in creds.values():
        target = entry.get("target")
        if not target:
            continue
        dest = out / target
        source = entry.get("source")
        if source is None:
            # Drop point for a provisioner: ensure an empty owned file
            # exists, but never clobber content a provisioner has placed.
            if not dest.exists():
                write_text_atomic(dest, "")
                written.append(target)
            continue
        try:
            content = Path(source).expanduser().read_text(encoding="utf-8")
        except (FileNotFoundError, IsADirectoryError, PermissionError, OSError):
            continue  # an absent or unreadable source has nothing to materialize
        write_text_atomic(dest, content)
        written.append(target)
    return written


def _ensure_excluded(root: Path) -> None:
    """Keep the scratch tree out of `git status` via the per-clone
    exclude file (never the repository's own .gitignore)."""
    git_dir = _git_dir(root)
    if git_dir is None:
        return
    exclude = git_dir / "info" / "exclude"
    line = f"/{SCRATCH_SUBDIR.parent.as_posix()}/"
    try:
        existing = exclude.read_text(encoding="utf-8") if exclude.exists() else ""
        if line in existing.splitlines():
            return
        exclude.parent.mkdir(parents=True, exist_ok=True)
        with exclude.open("a", encoding="utf-8") as fh:
            if existing and not existing.endswith("\n"):
                fh.write("\n")
            fh.write(line + "\n")
    except OSError:
        return


def redirect_job_tmp(root: Path) -> str | None:
    """Make $CLAUDE_JOB_DIR/tmp writable from sandboxed commands.

    Background jobs are told to use $CLAUDE_JOB_DIR/tmp for scratch, but
    it lives under ~/.claude, which the sandbox keeps write-protected
    regardless of grants, and no static allowWrite can name a per-job
    path. The job's tmp becomes a symlink into the checkout's working
    tree, under .claude/claude-code-sandbox/jobs/<id>/tmp: a plain
    directory entry the sandbox resolves into space the checkout
    already owns, so nothing is granted and the isolation unit stays
    the checkout, which is the sandbox's own unit (every session in a
    checkout can already write its working tree). Per worktree by
    construction, alive as long as the checkout, excluded from git
    status via the per-clone exclude file. Sandboxed commands cannot
    remove the link (the job dir is read-only to them); job cleanup
    removes the link, not the target, so targets whose job is gone are
    pruned here. Returns the target when a redirect was made, else None.
    """
    job_dir = os.environ.get("CLAUDE_JOB_DIR")
    if not job_dir:
        return None
    jobs_root = Path(job_dir).parent
    scratch_root = root / SCRATCH_SUBDIR
    if scratch_root.is_dir():
        for orphan in scratch_root.iterdir():
            if orphan.is_dir() and not (jobs_root / orphan.name).exists():
                shutil.rmtree(orphan, ignore_errors=True)
    tmp = Path(job_dir) / "tmp"
    if tmp.is_symlink() or not tmp.is_dir():
        return None
    target = scratch_root / Path(job_dir).name / "tmp"
    target.mkdir(parents=True, exist_ok=True)
    for child in tmp.iterdir():
        shutil.move(str(child), str(target / child.name))
    tmp.rmdir()
    tmp.symlink_to(target)
    _ensure_excluded(root)
    return str(target)


def cmd_hook_session_start(args: argparse.Namespace) -> int:
    """Advisory SessionStart hook: report and self-heal staleness, and
    redirect the job scratch dir. Always exits 0, because the sandbox
    design must stay correct without hooks."""
    try:
        root = find_repo_root(Path.cwd())
        if root is None:
            return 0
        sidecar = read_sidecar(root)
        if sidecar is None:
            return 0
        target = redirect_job_tmp(root)
        if target:
            print(
                "claude-code-sandbox: $CLAUDE_JOB_DIR/tmp now points into this "
                f"checkout ({target}) so sandboxed commands can write there"
            )
        creds = provision_creds(root)
        if creds:
            print(
                "claude-code-sandbox: provisioned owned credential copies "
                f"({', '.join(sorted(creds))}) so sandboxed tools can read them"
            )
        line, attention = _status_line(root)
        if attention and sidecar["legacy_profile"] is not None:
            # The checkout keeps the fragment it last applied; choosing
            # its modules is the user's act, so the hook only reports.
            print(f"claude-code-sandbox: {line}")
        elif attention:
            try:
                _apply(root, sidecar["modules"], sidecar["applied"], quiet=True)
                print(
                    f"claude-code-sandbox: {line}; synced now, and settings "
                    "live-reload, so the current session should pick this up"
                )
            except ToolError as e:
                print(f"claude-code-sandbox: {line}; sync failed: {e}")
    except Exception as e:  # noqa: BLE001 (advisory surface: never block a session)
        print(f"claude-code-sandbox: hook error (advisory): {e}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="claude-code-sandbox",
        description="Enroll checkouts into compositions of nix-declared Claude Code sandbox modules",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    def add(name: str, fn: Any, checkout: bool = True, **kwargs: Any) -> argparse.ArgumentParser:
        p = sub.add_parser(name, **kwargs)
        p.set_defaults(fn=fn)
        if checkout:
            p.add_argument(
                "-C",
                dest="directory",
                default=".",
                metavar="DIR",
                help="act on the checkout containing DIR (default: the current directory)",
            )
        return p

    p = add("enroll", cmd_enroll, help="bind this checkout to exactly the given modules")
    p.add_argument("modules", nargs="*", metavar="MODULE")
    p.add_argument("--quiet", action="store_true")

    p = add("add", cmd_add, help="add modules to this checkout's set")
    p.add_argument("modules", nargs="+", metavar="MODULE")
    p.add_argument("--quiet", action="store_true")

    p = add("drop", cmd_drop, help="remove modules from this checkout's set")
    p.add_argument("modules", nargs="+", metavar="MODULE")
    p.add_argument("--quiet", action="store_true")

    p = add("abandon", cmd_abandon, help="remove the sandbox fragment and keep the checkout managed")
    p.add_argument("--quiet", action="store_true")

    p = add("sync", cmd_sync, help="re-apply this checkout's modules")
    p.add_argument("--quiet", action="store_true")

    add("status", cmd_status, help="report this checkout's binding")

    add("list", cmd_list, checkout=False, help="list the declared sandbox modules")

    p = add("show", cmd_show, help="show what modules allow and their status in this checkout")
    p.add_argument("modules", nargs="+", metavar="MODULE")

    p = add("decline", cmd_decline, help="record that this checkout should not get these modules")
    p.add_argument("modules", nargs="+", metavar="MODULE")
    p.add_argument("--reason", help="shown to agents that ask for the module")
    p.add_argument("--quiet", action="store_true")

    p = add("undecline", cmd_undecline, help="withdraw a recorded refusal")
    p.add_argument("modules", nargs="+", metavar="MODULE")
    p.add_argument("--quiet", action="store_true")

    add("mcp", cmd_mcp, checkout=False, help="serve the agent tools over MCP on stdio")

    p = add(
        "scan",
        cmd_scan,
        checkout=False,
        help="walk the given directory and report every checkout under it",
    )
    p.add_argument("directory")

    add("hook-session-start", cmd_hook_session_start, checkout=False, help=argparse.SUPPRESS)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.fn(args)
    except ToolError as e:
        print(f"claude-code-sandbox: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
