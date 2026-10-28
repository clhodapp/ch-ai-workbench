# SPDX-License-Identifier: MIT
"""File plumbing: repo discovery, atomic JSON IO, sidecar, registry.

The settings file is written the same way Claude Code writes it (temp file
in the same directory, mode 0600, atomic rename) with optimistic
concurrency: a live session may save a permission rule mid-update, so the
file's identity is re-checked before the rename and the update retried on
change.
"""

from __future__ import annotations

import json
import os
import shutil
import tempfile
from collections.abc import Callable
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

SETTINGS_NAME = "settings.local.json"
SANDBOX_DIR_NAME = ".agent-sandbox"
SIDECAR_NAME = "binding.json"
EXPIRING_NAME = "expiring.json"

# Where checkouts and the user's state kept these before the tool was
# renamed from claude-code-sandbox. Only the migration reads them.
OLD_SIDECAR_NAME = "claude-code-sandbox.json"
OLD_DIR_NAME = "claude-code-sandbox"

# How long a module chosen for a limited time stays chosen.
DURATIONS = {"day": timedelta(days=1), "week": timedelta(weeks=1)}


class ToolError(Exception):
    """Operator-facing error; the CLI prints it without a traceback."""


def find_repo_root(start: Path) -> Path | None:
    """Walk up from ``start`` to the nearest directory containing a
    ``.git`` entry (directory or worktree file)."""
    current = start.resolve()
    for candidate in [current, *current.parents]:
        if (candidate / ".git").exists():
            return candidate
    return None


def claude_dir(root: Path) -> Path:
    return root / ".claude"


def settings_path(root: Path) -> Path:
    return claude_dir(root) / SETTINGS_NAME


def sandbox_dir(root: Path) -> Path:
    """The checkout's own directory for this tool: the binding, the
    credentials and the job scratch."""
    return root / SANDBOX_DIR_NAME


def sidecar_path(root: Path) -> Path:
    return sandbox_dir(root) / SIDECAR_NAME


def old_sidecar_path(root: Path) -> Path:
    return claude_dir(root) / OLD_SIDECAR_NAME


def _state_base() -> Path:
    xdg = os.environ.get("XDG_STATE_HOME")
    return Path(xdg) if xdg else Path.home() / ".local" / "state"


def state_dir() -> Path:
    override = os.environ.get("AGENT_SANDBOX_STATE")
    if override:
        return Path(override)
    return _state_base() / "agent-sandbox"


def migrate_checkout(root: Path) -> bool:
    """Move a checkout bound under the tool's old name to the new layout.

    When ``.claude/claude-code-sandbox.json`` exists and
    ``.agent-sandbox/binding.json`` does not, the sidecar moves to the
    new place and the old credentials directory is removed (it is
    regenerated). The old jobs directory stays, because live jobs' tmp
    symlinks point into it; the scratch pruner empties it, and the old
    directory goes when it is empty. A checkout that has the new binding
    is left alone. Returns True when the sidecar moved."""
    old = old_sidecar_path(root)
    new = sidecar_path(root)
    old_dir = claude_dir(root) / OLD_DIR_NAME
    moved = False
    try:
        if old.is_file() and not new.exists():
            new.parent.mkdir(parents=True, exist_ok=True)
            os.replace(old, new)
            moved = True
            shutil.rmtree(old_dir / "creds", ignore_errors=True)
        if moved or not old.exists():
            remove_if_empty(old_dir)
    except OSError:
        return False
    return moved


def remove_if_empty(directory: Path) -> None:
    """Remove ``directory`` when nothing is in it."""
    try:
        directory.rmdir()
    except OSError:
        pass


def migrate_state() -> bool:
    """Move the user's index of expiring checkouts from the old state
    directory to the new one. An ``AGENT_SANDBOX_STATE`` override names
    a directory chosen by the caller, so it migrates nothing."""
    if os.environ.get("AGENT_SANDBOX_STATE"):
        return False
    old_dir = _state_base() / OLD_DIR_NAME
    old = old_dir / EXPIRING_NAME
    new = expiring_path()
    try:
        if not old.is_file() or new.exists():
            return False
        new.parent.mkdir(parents=True, exist_ok=True)
        os.replace(old, new)
    except OSError:
        return False
    remove_if_empty(old_dir)
    return True


def expiring_path() -> Path:
    """The user's index of checkouts that chose a module for a limited
    time. The deadlines live in each checkout's sidecar; the index only
    tells the expiry run which checkouts to read."""
    return state_dir() / EXPIRING_NAME


def read_json(path: Path) -> dict[str, Any]:
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return {}
    except (IsADirectoryError, PermissionError, OSError):
        # A settings path can be substituted by the worktree/bg-isolation
        # harness — e.g. bound to a character device, not a regular file,
        # which may deny reads. There is no JSON content to merge in that
        # case; treat it as absent rather than crash. A genuine regular
        # file with a real read error still raises.
        if path.is_file():
            raise
        return {}
    if not raw.strip():
        # Empty content (e.g. reading through /dev/null) is not valid
        # JSON but carries nothing to merge; treat it as absent.
        return {}
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as e:
        raise ToolError(f"{path} is not valid JSON: {e}") from e
    if not isinstance(value, dict):
        raise ToolError(f"{path} does not contain a JSON object")
    return value


def _stat_identity(path: Path) -> tuple[int, int] | None:
    try:
        st = path.stat()
    except FileNotFoundError:
        return None
    return (st.st_mtime_ns, st.st_size)


def write_json_atomic(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(value, f, indent=2)
            f.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def write_text_atomic(path: Path, text: str, mode: int = 0o600) -> None:
    """Write ``text`` to ``path`` via same-dir temp + rename, mode 0600 by
    default — the owned-copy primitive for the credential broker. Same
    discipline as write_json_atomic; the caller owns the content."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def update_json(
    path: Path,
    fn: Callable[[dict[str, Any]], dict[str, Any] | None],
    retries: int = 3,
) -> bool:
    """Read-modify-write with optimistic concurrency.

    ``fn`` maps the current content to the next content, or returns None to
    signal no change. Returns True when a write happened.
    """
    for _ in range(retries):
        before = _stat_identity(path)
        current = read_json(path)
        result = fn(current)
        if result is None or result == current:
            return False
        if _stat_identity(path) != before:
            continue  # concurrent writer; re-read and retry
        write_json_atomic(path, result)
        return True
    raise ToolError(
        f"{path} kept changing underneath the update (a live session writing?); giving up"
    )


def read_sidecar(root: Path) -> dict[str, Any] | None:
    """The checkout's binding, normalized to ``modules`` (the sorted
    chosen names, or None when abandoned), ``applied`` (the fragment this
    tool last wrote), ``expires``, ``declined`` and ``legacy_profile``.

    ``expires`` maps each module the checkout chose for a limited time to
    the time it stops being chosen (timezone-aware). A chosen module
    absent from it is chosen until someone drops it.

    ``declined`` maps each module the user refused for this checkout to
    the refusal: ``at`` (an ISO 8601 time) and an optional ``reason``.
    The sidecar is write-guarded from sandboxed commands and file tools,
    so an agent cannot erase a refusal.

    A sidecar written before sandbox modules existed names a ``profile``
    instead. The reserved empty profile ``none`` is the abandoned state,
    so it reads as such. Any other profile has no module equivalent: it
    reads with ``legacy_profile`` set, and the checkout keeps its applied
    fragment (the merge base for re-enrollment) until someone enrolls it
    with modules."""
    sidecar = sidecar_path(root)
    if not sidecar.exists():
        return None
    value = read_json(sidecar)
    applied = value.get("applied")
    if not isinstance(applied, dict):
        raise ToolError(f"{sidecar} is malformed (expected an applied object)")
    declined = value.get("declined", {})
    if not (isinstance(declined, dict) and all(isinstance(v, dict) for v in declined.values())):
        raise ToolError(f"{sidecar} is malformed (declined must map module names to objects)")
    try:
        expires = {name: datetime.fromisoformat(at) for name, at in value.get("expires", {}).items()}
    except (AttributeError, TypeError, ValueError) as e:
        raise ToolError(f"{sidecar} is malformed (expires must map module names to ISO 8601 times)") from e
    if any(at.tzinfo is None for at in expires.values()):
        raise ToolError(f"{sidecar} is malformed (expires times need a timezone)")
    if "modules" in value:
        modules = value["modules"]
        if modules is not None and not (
            isinstance(modules, list) and all(isinstance(m, str) for m in modules)
        ):
            raise ToolError(f"{sidecar} is malformed (modules must be a list of names or null)")
        return {
            "modules": modules,
            "applied": applied,
            "expires": expires,
            "declined": declined,
            "legacy_profile": None,
        }
    profile = value.get("profile")
    if not isinstance(profile, str):
        raise ToolError(f"{sidecar} is malformed (expected modules + applied)")
    legacy = None if profile == "none" else profile
    return {"modules": None, "applied": applied, "expires": {}, "declined": declined, "legacy_profile": legacy}


def write_sidecar(
    root: Path,
    modules: list[str] | None,
    applied: dict[str, Any],
    declined: dict[str, Any] | None = None,
    expires: dict[str, datetime] | None = None,
) -> None:
    """Record the binding. ``expires`` keeps only modules in ``modules``,
    and the user's index of expiring checkouts follows it."""
    value: dict[str, Any] = {"modules": modules, "applied": applied}
    kept = {name: at for name, at in (expires or {}).items() if name in (modules or [])}
    if kept:
        value["expires"] = {name: at.isoformat(timespec="seconds") for name, at in sorted(kept.items())}
    if declined:
        value["declined"] = dict(sorted(declined.items()))
    write_json_atomic(sidecar_path(root), value)
    index_expiring(root, bool(kept))


def index_expiring(root: Path, expiring: bool) -> None:
    """Add ``root`` to the user's index of expiring checkouts, or remove
    it."""
    key = str(root)

    def transform(current: dict[str, Any]) -> dict[str, Any]:
        roots = set(current.get("checkouts") or [])
        if expiring:
            roots.add(key)
        else:
            roots.discard(key)
        return {"checkouts": sorted(roots)}

    path = expiring_path()
    if not expiring and not path.exists():
        return
    update_json(path, transform)


def expiring_checkouts() -> list[Path]:
    return [Path(root) for root in read_json(expiring_path()).get("checkouts") or []]
