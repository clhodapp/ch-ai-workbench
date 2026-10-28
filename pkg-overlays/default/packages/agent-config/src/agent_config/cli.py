# SPDX-License-Identifier: MIT
"""agent-config: converge declared settings into an agent's own config file.

    agent-config apply --format json|toml --target FILE \\
        --fragment FRAGMENT.json --sidecar SIDECAR.json [--name NAME] [--dry-run]

The fragment is JSON whatever the target's format, because Nix renders
it with ``builtins.toJSON``. The sidecar records the target and the
fragment applied, and is the merge base of the next run. A sidecar that
names a different target is ignored, so moving a target starts over
rather than removing entries from the wrong file.

The target is replaced through a temporary file in its own directory and
a rename, keeping its mode (0600 for a new file). An agent may write the
file while this runs, so the file's identity is checked again before the
rename and the merge retried when it changed. A target that is a symlink
(a file Home Manager used to link from the store) is replaced by a
regular file holding the merged content.
"""

from __future__ import annotations

import argparse
import json
import os
import stat
import sys
import tempfile
from pathlib import Path
from typing import Any

import tomlkit

from .merge import merge


class ToolError(Exception):
    """An error the CLI prints without a traceback."""


def _identity(path: Path) -> tuple[int, int, int] | None:
    try:
        st = path.lstat()
    except FileNotFoundError:
        return None
    return (st.st_ino, st.st_mtime_ns, st.st_size)


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return ""


def _parse(text: str, fmt: str, path: Path) -> Any:
    if not text.strip():
        return {} if fmt == "json" else tomlkit.document()
    if fmt == "json":
        try:
            value = json.loads(text)
        except json.JSONDecodeError as e:
            raise ToolError(f"{path} is not valid JSON ({e}); fix or remove it") from e
        if not isinstance(value, dict):
            raise ToolError(f"{path} does not hold a JSON object")
        return value
    try:
        return tomlkit.parse(text)
    except tomlkit.exceptions.ParseError as e:
        raise ToolError(f"{path} is not valid TOML ({e}); fix or remove it") from e


def _render(document: Any, fmt: str) -> str:
    if fmt == "json":
        return json.dumps(document, indent=2) + "\n"
    return tomlkit.dumps(document)


def _nulls(value: Any, path: str = "") -> list[str]:
    if value is None:
        return [path or "(the fragment)"]
    if isinstance(value, dict):
        return [p for k, v in value.items() for p in _nulls(v, f"{path}.{k}" if path else k)]
    if isinstance(value, list):
        return [p for i, v in enumerate(value) for p in _nulls(v, f"{path}[{i}]")]
    return []


def _read_json_file(path: Path, what: str) -> dict[str, Any]:
    text = _read_text(path)
    if not text.strip():
        return {}
    try:
        value = json.loads(text)
    except json.JSONDecodeError as e:
        raise ToolError(f"{what} {path} is not valid JSON ({e})") from e
    if not isinstance(value, dict):
        raise ToolError(f"{what} {path} does not hold a JSON object")
    return value


def _write_atomic(path: Path, text: str, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
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


def apply(
    fmt: str,
    target: Path,
    fragment: dict[str, Any],
    sidecar: Path,
    name: str,
    dry_run: bool = False,
    retries: int = 5,
) -> tuple[str, list[str]]:
    """Merge ``fragment`` into ``target``. Returns the merged text and the
    report lines."""
    if fmt == "toml":
        nulls = _nulls(fragment)
        if nulls:
            raise ToolError(f"TOML has no null; the fragment sets {', '.join(nulls)} to null")
    recorded = _read_json_file(sidecar, "sidecar")
    base = recorded.get("applied") if recorded.get("target") == str(target) else {}
    if not isinstance(base, dict):
        base = {}
    for _ in range(retries):
        before = _identity(target)
        text = _read_text(target)
        document = _parse(text, fmt, target)
        report = merge(document, base, fragment)
        merged = _render(document, fmt)
        if dry_run:
            return merged, report.lines(name)
        if merged != text or (before is not None and target.is_symlink()):
            if _identity(target) != before:
                continue
            try:
                mode = stat.S_IMODE(target.stat().st_mode) | stat.S_IWUSR
                if target.is_symlink():
                    mode = 0o600
            except FileNotFoundError:
                mode = 0o600
            _write_atomic(target, merged, mode)
        _write_atomic(
            sidecar,
            json.dumps({"target": str(target), "applied": fragment}, indent=2) + "\n",
            0o600,
        )
        return merged, report.lines(name)
    raise ToolError(f"{target} kept changing while it was merged (an agent writing it?); giving up")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="agent-config",
        description="Converge declared settings into a config file an agent also writes.",
    )
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("apply", help="merge a fragment into a target file")
    p.add_argument("--format", choices=["json", "toml"], required=True)
    p.add_argument("--target", type=Path, required=True)
    p.add_argument("--fragment", type=Path, required=True)
    p.add_argument("--sidecar", type=Path, required=True)
    p.add_argument("--name", default="agent-config", help="the label of report lines")
    p.add_argument("--dry-run", action="store_true", help="print the merged file, write nothing")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        fragment = _read_json_file(args.fragment, "fragment")
        merged, lines = apply(
            args.format, args.target, fragment, args.sidecar, args.name, args.dry_run
        )
    except ToolError as e:
        print(f"agent-config: {e}", file=sys.stderr)
        return 1
    for line in lines:
        print(line, file=sys.stderr)
    if args.dry_run:
        sys.stdout.write(merged)
    return 0


if __name__ == "__main__":
    sys.exit(main())
