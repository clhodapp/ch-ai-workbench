# SPDX-License-Identifier: MIT
"""claude-turn-text: print the text of the turn a final assistant message ends.

The final message arrives on stdin, as the Stop hook payload's last_assistant_message.
`--transcript` names the session transcript. A turn is everything since the user's last typed
prompt, and its assistant text falls into one message per stretch between tool calls, of which
the Stop payload carries only the last. This program prints the earlier messages, each headed
EARLIER, then the final message headed FINAL. When the transcript already ends with the final
message, that copy is dropped, so the final message appears once whether or not the CLI has
written it to the transcript before the hook runs.

The final message is always printed whole. Earlier messages are added newest first while the
whole text stays within `--max-chars`, and a marker replaces the ones left out. A transcript
that cannot be read prints the final message alone, unheaded.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

from .cli import transcript_entries, typed_prompt

EARLIER = "[earlier message of this turn]"
FINAL = "[final message]"
LEFT_OUT = "[older messages of this turn left out]"


def earlier_messages(entries: list[dict[str, Any]]) -> list[str]:
    """The assistant messages since the last typed prompt, oldest first: the text blocks of
    the assistant entries, split wherever a tool call comes between them."""
    start = 0
    for i, entry in enumerate(entries):
        if typed_prompt(entry):
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
    if not earlier:
        return f"{FINAL}\n{final}"
    budget = max_chars - len(FINAL) - len(final) - 2
    kept: list[str] = []
    for message in reversed(earlier):
        piece = f"{EARLIER}\n{message}"
        if len(piece) + 2 > budget:
            break
        kept.insert(0, piece)
        budget -= len(piece) + 2
    if len(kept) < len(earlier):
        kept.insert(0, LEFT_OUT)
    return "\n\n".join([*kept, f"{FINAL}\n{final}"])


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="claude-turn-text", description=__doc__.split("\n")[0])
    p.add_argument("--transcript", type=Path, required=True, help="the session transcript")
    p.add_argument("--max-chars", type=int, default=40000, help="longest text to print")
    args = p.parse_args(argv)
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
