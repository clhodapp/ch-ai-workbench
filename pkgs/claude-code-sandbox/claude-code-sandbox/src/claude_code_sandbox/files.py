# SPDX-License-Identifier: LGPL-3.0-or-later
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
import tempfile
from collections.abc import Callable
from pathlib import Path
from typing import Any

SETTINGS_NAME = "settings.local.json"
SIDECAR_NAME = "claude-code-sandbox.json"


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


def sidecar_path(root: Path) -> Path:
    return claude_dir(root) / SIDECAR_NAME


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
    sidecar = sidecar_path(root)
    if not sidecar.exists():
        return None
    value = read_json(sidecar)
    if "profile" not in value or not isinstance(value.get("applied"), dict):
        raise ToolError(f"{sidecar} is malformed (expected profile + applied)")
    return value


def write_sidecar(root: Path, profile: str, applied: dict[str, Any]) -> None:
    write_json_atomic(sidecar_path(root), {"profile": profile, "applied": applied})
