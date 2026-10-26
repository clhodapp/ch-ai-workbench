# SPDX-License-Identifier: MIT
"""claude-turn-load: score how much a final message asks the reader to take in at once.

The final message arrives on stdin; `--density` is the judge's information-density score of
the turn (its expected level, 0 sparse to 3 packed), and `--transcript` the session
transcript, read for the input that opened the turn. The score is

    ln(prose words + 1) + density - 0.25 * ln(words of the opening prompt + 8)

so each density level multiplies the words a message may spend by e, and a longer request
earns a longer answer. Prose words leave out code blocks, inline code, and the `result:` and
`needs input:` lines a background job ends with. A turn opened by a task notification, not by
the user, has an opening prompt of 0 words.

On stdout: {"score", "words", "ask_words"}.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path

from .cli import transcript_entries, turn_input, typed_prompt

FENCE = re.compile(r"```.*?```", re.DOTALL)
SPAN = re.compile(r"`[^`\n]*`")
TRAILER = re.compile(r"^(result|needs input|failed):.*$", re.MULTILINE)


def prose_words(text: str) -> int:
    return len(TRAILER.sub(" ", SPAN.sub("x", FENCE.sub(" ", text))).split())


def ask_words(entries: list[dict]) -> int:
    """Words of the input that opened the current turn: the last turn input, counted when the
    user typed it and 0 when a task notification opened the turn."""
    for entry in reversed(entries):
        if turn_input(entry):
            typed = typed_prompt(entry)
            return len(typed.split()) if typed else 0
    return 0


def load_score(words: int, density: float, ask: int) -> float:
    return math.log(words + 1) + density - 0.25 * math.log(ask + 8)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="claude-turn-load", description=__doc__.split("\n")[0])
    p.add_argument("--density", type=float, required=True, help="the information-density score")
    p.add_argument("--transcript", type=Path, default=None, help="the session transcript")
    args = p.parse_args(argv)
    words = prose_words(sys.stdin.read())
    try:
        ask = ask_words(transcript_entries(args.transcript)) if args.transcript else 0
    except OSError:
        ask = 0
    json.dump({"score": round(load_score(words, args.density, ask), 3), "words": words, "ask_words": ask}, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
