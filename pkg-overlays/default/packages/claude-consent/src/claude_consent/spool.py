# SPDX-License-Identifier: MIT
"""The consent spool: files under ``$XDG_RUNTIME_DIR/claude-consent``.

The spool is the whole protocol.  A hook (through ``claude-consent
ask``) writes a pending record; an answerer (Emacs, ``claude-consent
answer``, ``claude-consent watch``) writes an answer file; whichever
process waits on the record picks the answer up.  Nothing here talks to
the Claude Code CLI or to Emacs: both sides read and write these files,
so either can restart without losing anything.

Layout::

    territory/<agent>.json   dispatch-time grants (written by claude-queue)
    handlers/<name>.json     attached answerers: {name, pid}; live iff pid is
    pending/<id>.json        open prompts
    answers/<id>.json        {id, value, text?}; picked up by the waiter
    log/<id>.log             output of an async re-entry

A pending record carries ``mode``, which names who waits on it and
therefore when it is stale:

``blocking``
    the hook process itself polls (``pid`` is the hook); stale once
    that pid is gone.
``waiter``
    a detached ``claude-consent wait`` process polls and re-enters the
    hook with the answer (``pid`` is the waiter); stale once it is gone.
``stored``
    nobody waits: no answerer was attached, so the hook returned at
    once and the answer, when written, is kept until a later ``ask``
    with the same session and key consumes it; stale at its deadline.
"""

from __future__ import annotations

import hashlib
import json
import os
import secrets
import time
from pathlib import Path
from typing import Any

SUBDIRS = ("territory", "pending", "answers", "handlers", "log")


class SpoolError(Exception):
    """A condition the command line reports and exits 1 on."""


def spool_dir(explicit: str | None = None) -> Path:
    """The spool root: EXPLICIT, else under the runtime dir."""
    if explicit:
        return Path(explicit)
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if not runtime:
        raise SpoolError("XDG_RUNTIME_DIR is unset; there is no consent spool")
    return Path(runtime) / "claude-consent"


def ensure_layout(spool: Path) -> Path:
    """Create the spool owner-only with every subdirectory; return it."""
    spool.mkdir(parents=True, exist_ok=True)
    os.chmod(spool, 0o700)
    for sub in SUBDIRS:
        (spool / sub).mkdir(exist_ok=True)
    return spool


def read_json(path: Path) -> dict[str, Any] | None:
    """Parse PATH as a JSON object, or None on any failure."""
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def write_json(path: Path, obj: dict[str, Any]) -> None:
    """Write OBJ to PATH atomically (temp file, then rename).

    Every reader polls, so a half-written file must never be visible
    under its final name."""
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(obj, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, path)


def unlink_quietly(path: Path) -> None:
    try:
        path.unlink()
    except OSError:
        pass


def pid_alive(pid: Any) -> bool:
    return isinstance(pid, int) and Path(f"/proc/{pid}").is_dir()


def agent_id(session: str) -> str:
    """The CLI's agent id: the leading 8 hex digits of the session UUID."""
    return session[:8]


def new_id(session: str, pid: int) -> str:
    """A fresh request id, prefixed by the session's agent id so a
    token given to the user names the session it belongs to."""
    return f"{agent_id(session)}-{int(time.time())}-{pid}-{secrets.token_hex(2)}"


def default_key(session: str, prompt: dict[str, Any], payload: dict[str, Any] | None) -> str:
    """Identity of a prompt for stored-answer lookup: the session, the
    question, and the tool call it is about."""
    material = [
        agent_id(session),
        prompt.get("title"),
        prompt.get("detail"),
        [option.get("value") for option in prompt.get("options", [])],
        (payload or {}).get("tool_name"),
        (payload or {}).get("tool_input"),
    ]
    digest = hashlib.sha256(json.dumps(material, sort_keys=True, ensure_ascii=False).encode("utf-8"))
    return digest.hexdigest()[:32]


def pending_path(spool: Path, request_id: str) -> Path:
    return spool / "pending" / f"{request_id}.json"


def answer_path(spool: Path, request_id: str) -> Path:
    return spool / "answers" / f"{request_id}.json"


def log_path(spool: Path, request_id: str) -> Path:
    return spool / "log" / f"{request_id}.log"


def record_stale(record: dict[str, Any], now: float | None = None) -> bool:
    """Whether nothing can still consume RECORD (see the module doc)."""
    now = time.time() if now is None else now
    mode = record.get("mode", "blocking")
    if mode == "stored":
        deadline = record.get("deadline")
        return isinstance(deadline, (int, float)) and deadline <= now
    return not pid_alive(record.get("pid"))


def pending_records(spool: Path, prune: bool = True) -> list[dict[str, Any]]:
    """Open prompts, oldest first.  With PRUNE, stale records and any
    answer they never consumed are deleted on read; unparseable files
    are skipped either way."""
    directory = spool / "pending"
    if not directory.is_dir():
        return []
    records = []
    for path in directory.glob("*.json"):
        record = read_json(path)
        if record is None:
            continue
        if prune and record_stale(record):
            unlink_quietly(path)
            request_id = record.get("id")
            if isinstance(request_id, str):
                unlink_quietly(answer_path(spool, request_id))
            continue
        records.append(record)
    records.sort(key=lambda record: record.get("created", 0))
    return records


def live_handlers(spool: Path) -> list[dict[str, Any]]:
    """Attached answerers whose process is alive; dead ones are pruned."""
    directory = spool / "handlers"
    if not directory.is_dir():
        return []
    handlers = []
    for path in directory.glob("*.json"):
        handler = read_json(path)
        if handler is None:
            continue
        if not pid_alive(handler.get("pid")):
            unlink_quietly(path)
            continue
        handlers.append(handler)
    handlers.sort(key=lambda handler: str(handler.get("name", "")))
    return handlers


def register_handler(spool: Path, name: str, pid: int) -> Path:
    path = spool / "handlers" / f"{name}.json"
    write_json(path, {"name": name, "pid": pid, "created": int(time.time())})
    return path


def remove_handler(spool: Path, name: str) -> None:
    unlink_quietly(spool / "handlers" / f"{name}.json")


def read_answer(spool: Path, request_id: str) -> dict[str, Any] | None:
    """The answer for REQUEST_ID once it is complete, else None.

    A file without a ``value`` is a partial write or garbage; the
    caller keeps polling (a partial write resolves, garbage times out)."""
    answer = read_json(answer_path(spool, request_id))
    if answer is None or "value" not in answer:
        return None
    return answer


def stored_answer(spool: Path, session: str, key: str) -> tuple[dict[str, Any], dict[str, Any]] | None:
    """A stored-mode record for this SESSION and KEY that has an
    answer, with that answer; None when there is none."""
    for record in pending_records(spool):
        if record.get("mode") != "stored" or record.get("key") != key:
            continue
        if agent_id(str(record.get("session_id", ""))) != agent_id(session):
            continue
        request_id = record.get("id")
        if not isinstance(request_id, str):
            continue
        answer = read_answer(spool, request_id)
        if answer is not None:
            return record, answer
    return None


def discard(spool: Path, request_id: str) -> None:
    """Remove a request and its answer, whether or not either exists."""
    unlink_quietly(pending_path(spool, request_id))
    unlink_quietly(answer_path(spool, request_id))


def option_keys(options: list[dict[str, Any]]) -> list[str]:
    """One distinct key character per option: the first character of
    the value when free, else the lowest free digit.  Emacs and the
    terminal derive the same keys from the same record."""
    keys: list[str] = []
    for option in options:
        value = str(option.get("value", ""))
        candidate = value[:1].lower()
        if not candidate or candidate in keys or not candidate.isalnum():
            for digit in "123456789":
                if digit not in keys:
                    candidate = digit
                    break
        keys.append(candidate)
    return keys
