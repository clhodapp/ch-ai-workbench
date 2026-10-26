# SPDX-License-Identifier: MIT
"""claude-session-index: a cached vocabulary of the user's Claude Code sessions.

Some checks judge a message against what the user knows: the words they have typed in any
session, the words and "the <word>" phrases the assistant has shown them. This module keeps
that vocabulary per session transcript in one JSON file under $XDG_CACHE_HOME/claude-tic-check/,
so a hook reads it instead of parsing the transcripts.

A transcript is JSON lines and only grows, so each entry records the byte offset it has been
read to, and an update parses only the lines appended since. The first update of a large
transcript parses it once in full; after that an update costs the new lines. Each entry also
records the time of the session's first line, so a check can restrict itself to sessions that
started before the one being judged.

usage: claude-session-index update [--projects DIR] [--index FILE]
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

from .cli import REMINDER, user_wrote

VERSION = 1
WORD = re.compile(r"[a-z0-9][a-z0-9_.-]*[a-z0-9]|[a-z0-9]")
PHRASE = re.compile(r"\bthe ([a-z][a-z-]{2,})(?: ([a-z][a-z-]{2,}))?\b")
FENCE = re.compile(r"```.*?```", re.DOTALL)
SPAN = re.compile(r"`[^`\n]*`")


def default_index() -> Path:
    cache = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(cache) / "claude-tic-check" / "session-index.json"


def default_projects() -> Path:
    return Path.home() / ".claude" / "projects"


def prose(text: str) -> str:
    """Assistant text as the user reads it as prose: code blocks and inline code removed."""
    return SPAN.sub(" ", FENCE.sub(" ", REMINDER.sub(" ", text)))


def words(text: str) -> set[str]:
    return set(WORD.findall(text.lower()))


def phrases(text: str) -> set[str]:
    """The "the <word>" and "the <word> <word>" phrases of a text, lowercased, without "the"."""
    found = set()
    for m in PHRASE.finditer(text.lower()):
        found.add(m.group(1))
        if m.group(2):
            found.add(f"{m.group(1)} {m.group(2)}")
    return found


def assistant_text(entry: dict[str, Any]) -> str | None:
    if entry.get("type") != "assistant" or entry.get("isSidechain"):
        return None
    content = entry.get("message", {}).get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text") or None
    return None


def empty_entry() -> dict[str, Any]:
    return {"offset": 0, "started": None, "user_words": [], "assistant_words": [], "assistant_phrases": []}


def read_appended(path: Path, entry: dict[str, Any]) -> dict[str, Any]:
    """ENTRY brought up to the end of PATH, parsing only whole lines after its offset."""
    user_words, assistant_words, assistant_phrases = (
        set(entry["user_words"]),
        set(entry["assistant_words"]),
        set(entry["assistant_phrases"]),
    )
    started = entry["started"]
    with path.open("rb") as f:
        f.seek(entry["offset"])
        data = f.read()
    end = data.rfind(b"\n") + 1
    for raw in data[:end].splitlines():
        # Most lines are tool calls and results; skip them before paying for json.loads.
        if b'"type":"assistant"' not in raw and b'"type":"user"' not in raw:
            continue
        try:
            e = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(e, dict) or e.get("isSidechain"):
            continue
        if started is None and isinstance(e.get("timestamp"), str):
            started = e["timestamp"]
        text = assistant_text(e)
        if text:
            p = prose(text)
            assistant_words |= words(p)
            assistant_phrases |= phrases(p)
            continue
        written = user_wrote(e)
        if written:
            user_words |= words(written)
    return {
        "offset": entry["offset"] + end,
        "started": started,
        "user_words": sorted(user_words),
        "assistant_words": sorted(assistant_words),
        "assistant_phrases": sorted(assistant_phrases),
    }


def transcripts(projects: Path) -> list[Path]:
    return sorted(p for p in projects.glob("*/*.jsonl") if p.is_file())


def load(index: Path | None = None) -> dict[str, Any]:
    try:
        data = json.loads((index or default_index()).read_text())
    except (OSError, ValueError):
        return {"version": VERSION, "sessions": {}}
    if data.get("version") != VERSION:
        return {"version": VERSION, "sessions": {}}
    return data


def stale(data: dict[str, Any], projects: Path | None = None) -> list[Path]:
    """The transcripts with lines the index has not read."""
    out = []
    for path in transcripts(projects or default_projects()):
        entry = data["sessions"].get(str(path))
        try:
            size = path.stat().st_size
        except OSError:
            continue
        if entry is None or entry["offset"] < size:
            out.append(path)
    return out


def update(projects: Path | None = None, index: Path | None = None) -> int:
    """Bring the index up to date under a lock, and write it back. Returns the number of
    transcripts read; another update holding the lock makes this one return 0 at once."""
    index = index or default_index()
    index.parent.mkdir(parents=True, exist_ok=True)
    with open(index.with_suffix(".lock"), "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return 0
        data = load(index)
        todo = stale(data, projects)
        for path in todo:
            entry = data["sessions"].get(str(path), empty_entry())
            data["sessions"][str(path)] = read_appended(path, entry)
        tmp = index.with_suffix(".tmp")
        tmp.write_text(json.dumps(data))
        tmp.replace(index)
        return len(todo)


def update_detached(projects: Path | None = None, index: Path | None = None) -> None:
    """Start an update in a detached process when the index is behind, and return at once."""
    if not stale(load(index), projects):
        return
    args = [sys.executable, "-m", "claude_response_judge.sessions", "update"]
    if projects:
        args += ["--projects", str(projects)]
    if index:
        args += ["--index", str(index)]
    subprocess.Popen(
        args,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        env=dict(os.environ, PYTHONPATH=os.pathsep.join(sys.path)),
    )


def earlier(data: dict[str, Any], current: Path) -> list[dict[str, Any]]:
    """The indexed sessions other than CURRENT that started before it (all others when its
    start is unknown)."""
    current_start = data["sessions"].get(str(current), {}).get("started")
    return [
        e
        for p, e in data["sessions"].items()
        if p != str(current) and e.get("started") and (current_start is None or e["started"] < current_start)
    ]


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="claude-session-index", description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    u = sub.add_parser("update", help="read the lines appended to each transcript since the last update")
    u.add_argument("--projects", type=Path, default=None)
    u.add_argument("--index", type=Path, default=None)
    args = p.parse_args(argv)
    if args.cmd == "update":
        print(f"{update(args.projects, args.index)} transcripts read", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
