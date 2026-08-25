# SPDX-License-Identifier: LGPL-3.0-or-later
"""claude-code-sandbox: enroll checkouts into nix-declared Claude Code
sandbox profiles.

Enrollment writes the profile's settings fragment into the checkout's
co-owned ``.claude/settings.local.json`` (three-way merge; Claude Code's
own keys are never touched) and records what was applied in the sidecar
``.claude/claude-code-sandbox.json``. Claude Code live-reloads settings
files, so changes generally apply to running sessions; removing an ``env``
variable is the documented exception (next launch).
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

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
from .registry import MaskedStore, load_fragment, load_registry

NONE_PROFILE = "none"
_SKIP_DIRS = {".git", "node_modules", ".direnv", ".cache", "result"}


def _root_or_die(directory: Path) -> Path:
    root = find_repo_root(directory)
    if root is None:
        raise ToolError(f"{directory} is not inside a git repository")
    return root


ROOT_ENV_VAR = "CLAUDE_CODE_SANDBOX_ROOT"


def _with_root_env(fragment: dict[str, Any], root: Path) -> dict[str, Any]:
    """Add this checkout's enrolled root to the fragment's env, so it
    reaches sandboxed commands (settings env is the only channel that
    does — hooks can't inject env, CLAUDE_PROJECT_DIR is hook-only, and
    the fragment is generated per-profile without knowing the checkout).
    The farm's ssh wrapper reads it to locate the credentials dir
    independent of cwd. Skips the empty/`none` fragment so it stays
    deliberately nothing. Making it part of the applied fragment keeps
    the merge authoritative for the key (it lives in base∪new), so no
    ad-hoc-addition noise."""
    if not fragment:
        return fragment
    out = dict(fragment)
    out["env"] = {**out.get("env", {}), ROOT_ENV_VAR: str(root)}
    return out


def _apply(root: Path, profile: str, base: dict[str, Any], quiet: bool) -> None:
    registry = load_registry()
    fragment = _with_root_env(load_fragment(registry, profile), root)
    reports = []

    def transform(current: dict[str, Any]) -> dict[str, Any] | None:
        merged, report = merge(current, base, fragment)
        reports.append(report)
        return merged

    changed = update_json(settings_path(root), transform)
    write_sidecar(root, profile, fragment)
    if quiet:
        return
    state = "updated" if changed else "already current"
    print(f"{root}: profile '{profile}' {state}")
    if reports and reports[-1].has_findings():
        r = reports[-1]
        for path, value, new in r.overridden_scalars:
            print(f"  overrode drifted {path}: {value!r} -> {new!r}")
        for path, value in r.preserved_drift:
            print(f"  preserved local value at dropped key {path}: {value!r}")
        for path, extras in r.adhoc_entries:
            print(f"  kept {len(extras)} ad-hoc entr{'y' if len(extras) == 1 else 'ies'} in {path}")


def _status_line(root: Path) -> tuple[str, bool]:
    """One status line for a checkout; second element = needs attention."""
    sidecar = read_sidecar(root)
    settings = read_json(settings_path(root))
    if sidecar is None:
        if "sandbox" in settings or "env" in settings:
            return (f"{root}: unmanaged (sandbox/env keys present, no sidecar)", True)
        return (f"{root}: not enrolled", False)
    profile = sidecar["profile"]
    applied = sidecar["applied"]
    # From inside a masked-store sandbox the registry and fragments (HM
    # symlinks into /nix/store) are unreadable; the sidecar and settings
    # still are, so enrollment and integrity remain reportable — only
    # freshness needs the fragment.
    stale: bool | None
    try:
        registry = load_registry()
        fragment = _with_root_env(load_fragment(registry, profile), root)
    except MaskedStore:
        stale = None
    except ToolError as e:
        return (f"{root}: profile '{profile}' DANGLING ({e})", True)
    else:
        # Compare against the augmented fragment: the sidecar stores what
        # _apply wrote (root env included), so the fresh fragment must be
        # augmented the same way or staleness would fire on every check.
        stale = fragment != applied
    # Replay the applied blob: if re-merging it changes anything, a
    # foreign writer dropped tool-owned keys (clobbering is removals, so
    # neither staleness nor ad-hoc detection would see it).
    replayed, _ = merge(settings, applied, applied)
    clobbered = replayed != settings
    adhoc = adhoc_additions(settings, applied)
    bits = [f"profile '{profile}'"]
    if clobbered:
        bits.append("CLOBBERED: applied keys missing from settings (sync restores)")
    elif stale is None:
        bits.append("applied (freshness unknown here: store masked, fragment unreadable)")
    else:
        bits.append("STALE (sync to update)" if stale else "current")
    if adhoc:
        entries = sum(len(x) for _, x in adhoc)
        paths = ", ".join(p for p, _ in adhoc)
        bits.append(f"{entries} local addition(s) in {paths}")
    return (f"{root}: " + ", ".join(bits), stale or clobbered)


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


def cmd_enroll(args: argparse.Namespace) -> int:
    root = _root_or_die(Path(args.directory))
    sidecar = read_sidecar(root)
    base = sidecar["applied"] if sidecar else {}
    _apply(root, args.profile, base, args.quiet)
    return 0


def cmd_retarget(args: argparse.Namespace) -> int:
    root = _root_or_die(Path(args.directory))
    sidecar = read_sidecar(root)
    if sidecar is None:
        raise ToolError(f"{root} is not enrolled (use enroll)")
    _apply(root, args.profile, sidecar["applied"], args.quiet)
    if args.profile == NONE_PROFILE and not args.quiet:
        print(
            "note: a live session keeps env vars from the old profile until "
            "its next launch (documented removal behavior)"
        )
    return 0


def cmd_sync(args: argparse.Namespace) -> int:
    root = _root_or_die(Path(args.directory))
    sidecar = read_sidecar(root)
    if sidecar is None:
        raise ToolError(f"{root} is not enrolled (use enroll)")
    _apply(root, sidecar["profile"], sidecar["applied"], args.quiet)
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

    Runs from the unsandboxed session-start hook, so copies are owned by
    the invoking user (not store root → nobody). A registry entry with a
    null source is created as an empty 0600 file — a drop point for a
    runtime provisioner to fill with a delegated credential. Returns the
    target filenames written. Best-effort per entry; a missing source is
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
            continue  # source absent/unreadable — nothing to materialize
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
    the checkout — the sandbox's own (every session in a checkout can
    already write its working tree). Per worktree by construction,
    alive as long as the checkout, excluded from git status via the
    per-clone exclude file. Sandboxed commands cannot remove the link
    (the job dir is read-only to them); job cleanup removes the link,
    not the target, so targets whose job is gone are pruned here.
    Returns the target when a redirect was made, else None.
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
    redirect the job scratch dir. Always exits 0 — the sandbox design
    must stay correct without hooks."""
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
        if attention:
            try:
                _apply(root, sidecar["profile"], sidecar["applied"], quiet=True)
                print(
                    f"claude-code-sandbox: {line} — synced now; settings "
                    "live-reload, so current session should pick this up"
                )
            except ToolError as e:
                print(f"claude-code-sandbox: {line} — sync failed: {e}")
    except Exception as e:  # noqa: BLE001 — advisory surface, never block a session
        print(f"claude-code-sandbox: hook error (advisory): {e}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="claude-code-sandbox",
        description="Enroll checkouts into nix-declared Claude Code sandbox profiles",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    def add(name: str, fn: Any, **kwargs: Any) -> argparse.ArgumentParser:
        p = sub.add_parser(name, **kwargs)
        p.set_defaults(fn=fn)
        return p

    p = add("enroll", cmd_enroll, help="bind this checkout to a profile")
    p.add_argument("--profile", default="default")
    p.add_argument("directory", nargs="?", default=".")
    p.add_argument("--quiet", action="store_true")

    p = add("retarget", cmd_retarget, help="rebind this checkout to a different profile")
    p.add_argument("profile")
    p.add_argument("directory", nargs="?", default=".")
    p.add_argument("--quiet", action="store_true")

    p = add("abandon", cmd_retarget, help="bind to the reserved empty profile 'none'")
    p.set_defaults(profile=NONE_PROFILE)
    p.add_argument("directory", nargs="?", default=".")
    p.add_argument("--quiet", action="store_true")

    p = add("sync", cmd_sync, help="re-apply the bound profile to this checkout")
    p.add_argument("directory", nargs="?", default=".")
    p.add_argument("--quiet", action="store_true")

    p = add("status", cmd_status, help="report this checkout's binding")
    p.add_argument("directory", nargs="?", default=".")

    p = add("scan", cmd_scan, help="walk the given directory and report every checkout under it")
    p.add_argument("directory")

    add("hook-session-start", cmd_hook_session_start, help=argparse.SUPPRESS)

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
