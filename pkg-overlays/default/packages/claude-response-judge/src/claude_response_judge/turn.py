# SPDX-License-Identifier: MIT
"""claude-turn-text: print the text of the turn a final assistant message ends.

The final message arrives on stdin, as the Stop hook payload's last_assistant_message.
`--transcript` names the session transcript. A turn is everything since the last entry that
started one (a prompt the user typed, or a task notification), and its assistant text falls into one message per stretch between tool calls, of which
the Stop payload carries only the last. This program prints the earlier messages, each headed
EARLIER, then the final message headed FINAL. When the transcript already ends with the final
message, that copy is dropped, so the final message appears once whether or not the CLI has
written it to the transcript before the hook runs.

A turn longer than `--max-chars` is cut to its trailing `--max-chars` characters, behind a
marker, so the newest text is the text judged. A transcript that cannot be read prints the
final message alone, unheaded.

With `--progress-state FILE` (the mid-turn mode of the PostToolUse hook) nothing is read from
stdin. The program prints the messages of the current turn that FILE does not list yet, each
headed PROGRESS, and writes the digests of all the turn's messages to FILE. It prints nothing
when there is no new message, when the transcript cannot be read, or when FILE cannot be
written.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any

from .cli import transcript_entries, turn_input

EARLIER = "[earlier message of this turn]"
FINAL = "[final message]"
CUT = "[start of the turn cut]"
PROGRESS = "[message written in this turn since the last tic-check note]"


def earlier_messages(entries: list[dict[str, Any]]) -> list[str]:
    """The assistant messages since the last turn input (a typed prompt or a task
    notification), oldest first: the text blocks of
    the assistant entries, split wherever a tool call comes between them."""
    start = 0
    for i, entry in enumerate(entries):
        if turn_input(entry):
            start = i + 1
    messages, current = [], []
    for entry in entries[start:]:
        if entry.get("type") != "assistant" or entry.get("isSidechain"):
            continue
        content = entry.get("message", {}).get("content")
        if isinstance(content, str):
            content = [{"type": "text", "text": content}]
        for block in content if isinstance(content, list) else []:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "text" and block.get("text", "").strip():
                current.append(block["text"].strip())
            elif block.get("type") == "tool_use" and current:
                messages.append("\n\n".join(current))
                current = []
    if current:
        messages.append("\n\n".join(current))
    return messages


def turn_text(final: str, entries: list[dict[str, Any]], max_chars: int) -> str:
    final = final.strip()
    earlier = earlier_messages(entries)
    if earlier and earlier[-1] == final:
        earlier.pop()
    text = "\n\n".join([*(f"{EARLIER}\n{m}" for m in earlier), f"{FINAL}\n{final}"])
    if len(text) > max_chars:
        # The marker counts toward max_chars, so the client, which cuts a longer text at its
        # end, receives the turn whole.
        keep = max(0, max_chars - len(CUT) - 1)
        text = f"{CUT}\n" + text[len(text) - keep :]
    return text


def digest(message: str) -> str:
    return hashlib.sha256(message.encode()).hexdigest()


def progress_text(entries: list[dict[str, Any]], seen: set[str], max_chars: int) -> tuple[str, list[str]]:
    """The messages of the current turn whose digests are not in SEEN, each headed, cut to
    their trailing max_chars like a turn; and the digests of all the turn's messages, which
    become SEEN for the next call. A message the turn repeats word for word counts once."""
    messages = earlier_messages(entries)
    digests = [digest(m) for m in messages]
    new = [m for m, d in zip(messages, digests) if d not in seen]
    text = "\n\n".join(f"{PROGRESS}\n{m}" for m in new)
    if len(text) > max_chars:
        keep = max(0, max_chars - len(CUT) - 1)
        text = f"{CUT}\n" + text[len(text) - keep :]
    return text, digests


def progress_main(args: argparse.Namespace) -> int:
    try:
        seen = set(json.loads(args.progress_state.read_text()))
    except (OSError, ValueError, TypeError):
        seen = set()
    try:
        entries = transcript_entries(args.transcript)
    except OSError:
        return 0
    text, digests = progress_text(entries, seen, args.max_chars)
    try:
        args.progress_state.parent.mkdir(parents=True, exist_ok=True)
        args.progress_state.write_text(json.dumps(digests))
    except OSError:
        # Without the state the same text would be judged again at every tool call.
        return 0
    if text:
        print(text)
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="claude-turn-text", description=__doc__.split("\n")[0])
    p.add_argument("--transcript", type=Path, required=True, help="the session transcript")
    p.add_argument("--max-chars", type=int, default=40000, help="longest text to print")
    p.add_argument(
        "--progress-state",
        type=Path,
        default=None,
        help="progress mode: print only this turn's messages not judged yet, tracked in this file",
    )
    args = p.parse_args(argv)
    if args.progress_state:
        return progress_main(args)
    final = sys.stdin.read()
    try:
        entries = transcript_entries(args.transcript)
    except OSError:
        print(final.strip())
        return 0
    print(turn_text(final, entries, args.max_chars))
    return 0


if __name__ == "__main__":
    sys.exit(main())
