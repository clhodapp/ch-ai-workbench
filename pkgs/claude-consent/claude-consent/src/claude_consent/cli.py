# SPDX-License-Identifier: MIT
"""claude-consent: the prompt API for Claude Code hooks.

A hook that needs the user's answer runs ``claude-consent ask``.  The
question goes into the spool (spool.py) where any attached answerer
sees it: the Emacs side (claude-consent.el) renders a menu, and
``claude-consent watch`` does the same in a terminal.  The hook gets
the answer back as JSON on stdout and acts on it.

Three shapes of ask, chosen by the hook:

* Blocking (the default): ``ask`` waits for the answer or the
  deadline.  This is how a PreToolUse hook gates a call.
* Async (``--async -- CMD ARGS``): ``ask`` returns at once
  and leaves a detached waiter that re-runs CMD with the original hook
  payload plus a ``consent_answer`` field on stdin once the answer
  lands.  For hooks whose event cannot wait, or that act on the answer
  later (open a pull request, say).
* Fallback (``--fallback VALUE``): when no answerer is attached, skip
  the spool and report VALUE.  A PreToolUse hook passes ``--fallback
  ask`` so a plain allow/deny question becomes the CLI's own prompt.

With no answerer attached and no fallback, the question is stored
and ``ask`` reports ``pending`` with a token: the user answers in a
terminal with ``claude-consent answer TOKEN``, and the next ``ask``
with the same session and key consumes the stored answer.  The token
starts with the session's agent id, so it names the session it belongs
to.

Outcomes are always JSON on stdout with exit 0; exit 1 with a message
on stderr is reserved for usage errors and a missing spool.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from . import spool as sp

POLL_SECONDS = 0.5
# A detached waiter is spawned before its record is written; it allows
# this long for the record to appear.
WAITER_GRACE_SECONDS = 5
REENTRY_ENV = "CLAUDE_CONSENT_REENTRY"


def _emit(obj: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def _instructions(request_id: str, mode: str) -> str:
    base = f"No answerer is attached to the consent spool. In a terminal run: claude-consent answer {request_id}"
    if mode == "stored":
        return (
            base
            + " -- then re-issue the identical call; the stored answer is consumed once. "
            + "Keep `claude-consent watch` running in a terminal to answer prompts as they arrive."
        )
    return base + " -- the hook re-runs with the answer."


# --- prompt construction -------------------------------------------------


def _parse_option(text: str) -> dict[str, Any]:
    value, sep, label = text.partition("=")
    value = value.strip()
    if not value:
        raise sp.SpoolError(f"--option needs a value: {text!r}")
    return {"value": value, "label": label.strip() if sep else value}


def build_prompt(args: argparse.Namespace) -> dict[str, Any]:
    options = [_parse_option(text) for text in args.option or []]
    values = [option["value"] for option in options]
    if len(set(values)) != len(values):
        raise sp.SpoolError("duplicate --option values")
    for text in args.option_text or []:
        value, sep, question = text.partition("=")
        if not sep or value.strip() not in values:
            raise sp.SpoolError(f"--option-text names no option: {text!r}")
        for option in options:
            if option["value"] == value.strip():
                option["text"] = question.strip() or "Text"
    if not options and args.free_text is None:
        raise sp.SpoolError("a prompt needs at least one --option, or --free-text")
    prompt: dict[str, Any] = {"title": args.title, "detail": args.detail or "", "options": options}
    if args.free_text is not None:
        prompt["free_text"] = args.free_text or "Answer"
    return prompt


def _read_payload(args: argparse.Namespace) -> dict[str, Any] | None:
    if not args.payload_stdin:
        return None
    try:
        payload = json.load(sys.stdin)
    except ValueError as err:
        raise sp.SpoolError(f"stdin is not a JSON hook payload: {err}") from err
    if not isinstance(payload, dict):
        raise sp.SpoolError("stdin is not a JSON object")
    return payload


def _hook_context(payload: dict[str, Any] | None) -> dict[str, Any]:
    if payload is None:
        return {}
    return {
        field: payload[field]
        for field in ("hook_event_name", "tool_name", "tool_input", "tool_use_id", "cwd")
        if field in payload
    }


def _base_record(
    request_id: str,
    session: str,
    key: str,
    prompt: dict[str, Any],
    payload: dict[str, Any] | None,
    deadline: float,
    extra: dict[str, Any],
) -> dict[str, Any]:
    record = {
        "id": request_id,
        "key": key,
        "session_id": session,
        "created": int(time.time()),
        "deadline": int(deadline),
        "prompt": prompt,
        "hook": _hook_context(payload),
    }
    record.update(extra)
    return record


# --- ask ------------------------------------------------------------------


def _wait_for_answer(spool: Path, request_id: str, deadline: float) -> dict[str, Any] | None:
    while time.time() < deadline:
        answer = sp.read_answer(spool, request_id)
        if answer is not None:
            return answer
        time.sleep(POLL_SECONDS)
    return None


def _answered(answer: dict[str, Any]) -> dict[str, Any]:
    result = {"status": "answered", "value": answer.get("value")}
    if answer.get("text"):
        result["text"] = answer["text"]
    return result


def spawn_waiter(spool: Path, request_id: str) -> subprocess.Popen[bytes]:
    """Start the detached process that re-enters the hook on answer.

    A new session with every standard stream on /dev/null, so neither
    the CLI's hook runner nor a hook timeout reaches it."""
    env = dict(os.environ)
    env["PYTHONPATH"] = os.pathsep.join(path for path in sys.path if path)
    return subprocess.Popen(
        [sys.executable, "-m", "claude_consent.cli", "--spool", str(spool), "wait", request_id],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        close_fds=True,
        env=env,
    )


def cmd_ask(args: argparse.Namespace) -> int:
    spool = sp.ensure_layout(sp.spool_dir(args.spool))
    payload = _read_payload(args)
    session = args.session or (payload or {}).get("session_id")
    if not session:
        raise sp.SpoolError("--session is required (or a payload carrying session_id)")
    prompt = build_prompt(args)
    if args.async_ and not args.reenter:
        raise sp.SpoolError("--async needs the re-entry command after --: ask [options] -- CMD ARGS...")
    if args.reenter and not args.async_:
        raise sp.SpoolError("a re-entry command is only meaningful with --async")
    extra: dict[str, Any] = {}
    if args.extra:
        try:
            extra = json.loads(args.extra)
        except ValueError as err:
            raise sp.SpoolError(f"--extra is not JSON: {err}") from err
        if not isinstance(extra, dict):
            raise sp.SpoolError("--extra must be a JSON object")
    key = args.key or sp.default_key(session, prompt, payload)

    # An answer the user already gave in a terminal to this same
    # question (previous ask returned pending): consume it.
    found = sp.stored_answer(spool, session, key)
    if found is not None:
        record, answer = found
        sp.discard(spool, record["id"])
        _emit(_answered(answer))
        return 0

    handlers = sp.live_handlers(spool)
    deadline = time.time() + args.deadline
    request_id = sp.new_id(session, os.getpid())

    if args.async_:
        waiter = spawn_waiter(spool, request_id)
        record = _base_record(request_id, session, key, prompt, payload, deadline, extra)
        record.update(
            {
                "mode": "waiter",
                "pid": waiter.pid,
                "reenter": {"argv": args.reenter, "cwd": os.getcwd()},
                "payload": payload,
            }
        )
        sp.write_json(sp.pending_path(spool, request_id), record)
        result = {"status": "pending", "id": request_id, "mode": "waiter"}
        if not handlers:
            result["instructions"] = _instructions(request_id, "waiter")
        _emit(result)
        return 0

    if not handlers:
        if args.fallback is not None:
            _emit({"status": "fallback", "value": args.fallback})
            return 0
        record = _base_record(request_id, session, key, prompt, payload, deadline, extra)
        record.update({"mode": "stored", "pid": None})
        sp.write_json(sp.pending_path(spool, request_id), record)
        _emit(
            {
                "status": "pending",
                "id": request_id,
                "mode": "stored",
                "instructions": _instructions(request_id, "stored"),
            }
        )
        return 0

    record = _base_record(request_id, session, key, prompt, payload, deadline, extra)
    record.update({"mode": "blocking", "pid": os.getpid()})
    sp.write_json(sp.pending_path(spool, request_id), record)
    try:
        answer = _wait_for_answer(spool, request_id, deadline)
    finally:
        sp.discard(spool, request_id)
    if answer is None:
        _emit({"status": "timeout", "id": request_id, "deadline": args.deadline})
    else:
        _emit(_answered(answer))
    return 0


# --- wait (the detached re-entry waiter) ---------------------------------


def reenter(spool: Path, record: dict[str, Any], answer: dict[str, Any] | None) -> int:
    """Run the record's re-entry command with the answer on stdin."""
    reentry = record.get("reenter") or {}
    argv = reentry.get("argv")
    if not argv:
        return 1
    request_id = record["id"]
    payload = dict(record.get("payload") or {})
    consent = {"id": request_id, "status": "answered" if answer else "timeout"}
    if answer:
        consent["value"] = answer.get("value")
        if answer.get("text"):
            consent["text"] = answer["text"]
    payload["consent_answer"] = consent
    env = dict(os.environ)
    env[REENTRY_ENV] = request_id
    cwd = reentry.get("cwd")
    if not (isinstance(cwd, str) and Path(cwd).is_dir()):
        cwd = None
    with open(sp.log_path(spool, request_id), "w", encoding="utf-8") as log:
        completed = subprocess.run(
            argv,
            input=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            stdout=log,
            stderr=subprocess.STDOUT,
            env=env,
            cwd=cwd,
            check=False,
        )
    return completed.returncode


def cmd_wait(args: argparse.Namespace) -> int:
    spool = sp.spool_dir(args.spool)
    path = sp.pending_path(spool, args.id)
    grace = time.time() + WAITER_GRACE_SECONDS
    record = sp.read_json(path)
    while record is None and time.time() < grace:
        time.sleep(0.1)
        record = sp.read_json(path)
    if record is None:
        return 1
    deadline = record.get("deadline")
    if not isinstance(deadline, (int, float)):
        deadline = time.time() + 300
    try:
        answer = _wait_for_answer(spool, args.id, deadline)
        return reenter(spool, record, answer)
    finally:
        sp.discard(spool, args.id)


# --- listing and answering -----------------------------------------------


def _select(records: list[dict[str, Any]], token: str) -> list[dict[str, Any]]:
    """The records TOKEN names: exactly one when it is a request id,
    else every record of the session it is a prefix of."""
    exact = [record for record in records if record.get("id") == token]
    if exact:
        return exact
    return [record for record in records if str(record.get("session_id", "")).startswith(token)]


def _remaining(record: dict[str, Any]) -> str:
    left = max(0, int(record.get("deadline", 0) - time.time()))
    if left == 0:
        return "expired"
    if left < 60:
        return f"{left}s"
    return f"{left // 60}m{left % 60:02d}s"


def _describe(record: dict[str, Any]) -> str:
    prompt = record.get("prompt") or {}
    hook = record.get("hook") or {}
    lines = [
        f"{record.get('id')}  [{record.get('mode')}, {_remaining(record)} left]",
        f"  session {record.get('session_id')}",
    ]
    if hook.get("tool_name"):
        lines.append(f"  tool    {hook['tool_name']}")
    lines.append(f"  {prompt.get('title', '?')}")
    detail = str(prompt.get("detail") or "").rstrip()
    if detail:
        lines.extend("    " + line for line in detail.splitlines())
    return "\n".join(lines)


def cmd_list(args: argparse.Namespace) -> int:
    spool = sp.spool_dir(args.spool)
    records = sp.pending_records(spool)
    if args.json:
        _emit({"pending": records, "handlers": sp.live_handlers(spool)})
        return 0
    if not records:
        print("no pending prompts")
    for record in records:
        print(_describe(record))
    return 0


def cmd_handlers(args: argparse.Namespace) -> int:
    spool = sp.spool_dir(args.spool)
    handlers = sp.live_handlers(spool)
    if args.json:
        _emit({"handlers": handlers})
        return 0
    if not handlers:
        print("no answerer attached (stored mode: answer with `claude-consent answer TOKEN`)")
    for handler in handlers:
        print(f"{handler.get('name')}  pid {handler.get('pid')}")
    return 0


def _validate_answer(record: dict[str, Any], value: str, text: str | None) -> dict[str, Any]:
    prompt = record.get("prompt") or {}
    options = prompt.get("options") or []
    values = [option.get("value") for option in options]
    if value not in values and not (prompt.get("free_text") and value == "text"):
        raise sp.SpoolError(f"{value!r} is not an option of {record.get('id')}: {', '.join(map(str, values))}")
    answer: dict[str, Any] = {"id": record["id"], "value": value, "answered": int(time.time())}
    if text:
        answer["text"] = text
    return answer


def deliver(spool: Path, record: dict[str, Any], value: str, text: str | None) -> None:
    answer = _validate_answer(record, value, text)
    sp.write_json(sp.answer_path(spool, record["id"]), answer)


def ask_in_terminal(record: dict[str, Any]) -> tuple[str, str | None] | None:
    """Present RECORD on the terminal; return (value, text), or None
    when the user skips it (empty input)."""
    prompt = record.get("prompt") or {}
    options = prompt.get("options") or []
    keys = sp.option_keys(options)
    print()
    print(_describe(record))
    for key, option in zip(keys, options):
        print(f"  [{key}] {option.get('label', option.get('value'))}")
    if prompt.get("free_text"):
        print(f"  [t] {prompt['free_text']} (free text)")
    choice = input("answer (empty skips): ").strip().lower()
    if not choice:
        return None
    if prompt.get("free_text") and choice == "t":
        return "text", input(f"{prompt['free_text']}: ")
    for key, option in zip(keys, options):
        if choice in (key, str(option.get("value", "")).lower()):
            text = None
            if option.get("text"):
                text = input(f"{option['text']}: ")
            return str(option["value"]), text
    print(f"no such option: {choice}")
    return ask_in_terminal(record)


def cmd_answer(args: argparse.Namespace) -> int:
    spool = sp.spool_dir(args.spool)
    records = _select(sp.pending_records(spool), args.token)
    records = [record for record in records if sp.read_answer(spool, str(record.get("id"))) is None]
    if not records:
        raise sp.SpoolError(f"no unanswered prompt matches {args.token}")
    if args.value is not None:
        if len(records) > 1:
            raise sp.SpoolError(
                f"{args.token} matches {len(records)} prompts; give the full id: "
                + ", ".join(str(record.get("id")) for record in records)
            )
        deliver(spool, records[0], args.value, args.text)
        print(f"answered {records[0]['id']}: {args.value}")
        return 0
    if not sys.stdin.isatty():
        raise sp.SpoolError("no --value given and stdin is not a terminal")
    for record in records:
        choice = ask_in_terminal(record)
        if choice is None:
            print(f"skipped {record['id']}")
            continue
        deliver(spool, record, *choice)
        print(f"answered {record['id']}: {choice[0]}")
    return 0


def cmd_watch(args: argparse.Namespace) -> int:
    """Attach this terminal as an answerer until interrupted."""
    spool = sp.ensure_layout(sp.spool_dir(args.spool))
    if not sys.stdin.isatty():
        raise sp.SpoolError("watch needs a terminal")
    name = f"terminal-{os.getpid()}"
    sp.register_handler(spool, name, os.getpid())
    print(f"claude-consent: attached as {name}; waiting for prompts (Ctrl-C detaches)")
    skipped: set[str] = set()
    try:
        while True:
            for record in sp.pending_records(spool):
                request_id = str(record.get("id"))
                if request_id in skipped or sp.read_answer(spool, request_id) is not None:
                    continue
                choice = ask_in_terminal(record)
                if choice is None:
                    skipped.add(request_id)
                    continue
                deliver(spool, record, *choice)
                print(f"answered {request_id}: {choice[0]}")
            time.sleep(POLL_SECONDS)
    except KeyboardInterrupt:
        print()
        return 0
    finally:
        sp.remove_handler(spool, name)


# --- entry point ----------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="claude-consent", description=__doc__.split("\n\n")[0])
    parser.add_argument("--spool", help="spool directory (default: $XDG_RUNTIME_DIR/claude-consent)")
    sub = parser.add_subparsers(dest="command", required=True)

    ask = sub.add_parser("ask", help="raise a question for the user and report the answer (hooks)")
    ask.add_argument("--session", help="session id; defaults to the payload's session_id")
    ask.add_argument("--title", required=True, help="one line naming the question")
    ask.add_argument("--detail", help="free text shown under the title")
    ask.add_argument("--option", action="append", metavar="VALUE[=LABEL]", help="a choice (repeatable)")
    ask.add_argument(
        "--option-text",
        action="append",
        metavar="VALUE=PROMPT",
        help="collect free text with that choice, asked with PROMPT",
    )
    ask.add_argument(
        "--free-text",
        nargs="?",
        const="Answer",
        metavar="PROMPT",
        help="accept a free-text answer (value 'text', the text in 'text')",
    )
    ask.add_argument("--key", help="identity for stored-answer lookup (default: hash of the question)")
    ask.add_argument("--deadline", type=int, default=300, help="seconds to wait (default 300)")
    ask.add_argument(
        "--fallback",
        metavar="VALUE",
        help="with no answerer attached, report this option instead of storing the question",
    )
    ask.add_argument("--payload-stdin", action="store_true", help="read the hook payload from stdin")
    ask.add_argument("--extra", metavar="JSON", help="object merged into the pending record")
    ask.add_argument("--async", dest="async_", action="store_true", help="return at once; re-enter on answer")
    ask.add_argument(
        "reenter",
        nargs=argparse.REMAINDER,
        metavar="-- CMD ARGS",
        help="with --async: the command re-run with the answer on stdin",
    )
    ask.set_defaults(func=cmd_ask)

    wait = sub.add_parser("wait", help="internal: the detached re-entry waiter")
    wait.add_argument("id")
    wait.set_defaults(func=cmd_wait)

    listing = sub.add_parser("list", help="show pending prompts")
    listing.add_argument("--json", action="store_true")
    listing.set_defaults(func=cmd_list)

    handlers = sub.add_parser("handlers", help="show attached answerers")
    handlers.add_argument("--json", action="store_true")
    handlers.set_defaults(func=cmd_handlers)

    answer = sub.add_parser("answer", help="answer a prompt: by id, or every prompt of a session")
    answer.add_argument("token", help="a prompt id, or a session id prefix (its agent id) for all of that session's prompts")
    answer.add_argument("--value", help="the option value (omit for a terminal menu)")
    answer.add_argument("--text", help="free text attached to the answer")
    answer.set_defaults(func=cmd_answer)

    watch = sub.add_parser("watch", help="attach this terminal as an answerer")
    watch.set_defaults(func=cmd_watch)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    # argparse.REMAINDER keeps a leading "--"; drop it.
    if getattr(args, "reenter", None) and args.reenter[0] == "--":
        args.reenter = args.reenter[1:]
    try:
        return args.func(args)
    except sp.SpoolError as err:
        print(f"claude-consent: {err}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
