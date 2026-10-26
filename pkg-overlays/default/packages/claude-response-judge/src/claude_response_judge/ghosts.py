# SPDX-License-Identifier: MIT
"""claude-ghost-check: find the sentences of a write that argue with ghosts.

A sentence argues with ghosts when it is in a file because of an earlier version of the file or
because of the conversation, not because a new reader needs it: it says what is not done, not
set, unchanged, or no longer true, in contrast to the text the write replaces or to something
the user corrected, or it tells the story of the change or the correction. Asked about a whole
write, the judge gives one such sentence in a long text a middling probability. So this program
finds candidate sentences first and asks the judge about each one.

A sentence of the new text (stdin) is a candidate when it
- narrates a correction or the history of the text (NARRATION: "I had", "was wrong", "the
  user's correction", "before 2026-10-24", "settled"), or
- states an absence, a negation, or a non-change (NEGATION) and shares a content word with
  the user's latest messages, where a correction the sentence answers would be.

Each candidate is one noul question for the first endpoint that answers, on a state holding
the replaced text, the new text, the user's latest messages and the sentence, so the judge
can see the earlier version the sentence may answer. A probability at
or above `pushBackAbove` is a block, at or above `reportAbove` a report.

usage: claude-ghost-check --config JUDGE.json [--transcript PATH] [--replaced FILE]

The config's `ghosts` section holds the question (`instructions`, `criteria`), `pushBackAbove`
and `reportAbove`; the module constants below are the defaults. stdout holds one JSON object:
  {"endpoint": NAME or null,
   "sentences": [{"sentence": TEXT, "source": "narration" | "negation", "p": P, "action": "block" | "report" | "none"}, ...]}
and the program exits 0 whatever happens, so a hook never fails on it.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

from . import sessions
from .cli import first_answer, user_messages

NEGATION = re.compile(
    r"\b(not|no|nothing|none|never|no longer|anymore|any more|unchanged|untouched|without|"
    r"instead|rather than|only|still|removed|dropped|gone|neither|nor)\b|n't\b",
    re.IGNORECASE,
)
NARRATION = re.compile(
    r"\b(correction|corrected|I had|I chose|was wrong|were wrong|"
    r"the user (?:questioned|said|corrected|pushed)|after (?:two|the|a) corrections?|settled|"
    r"do not raise|wording removed|no longer equates|before \d{4}-\d\d-\d\d|original note|"
    r"my (?:earlier|first|own))\b",
    re.IGNORECASE,
)
WORD = re.compile(r"[A-Za-z][A-Za-z_-]{3,}")
STOP = set(
    """
    this that with from into have their there which when where what these those other them they
    each such than then only also more most some does done made make uses used using will would
    should could about after before because while being been were here every the and for are
    """.split()
)
SENTENCE = re.compile(r"(?<=[.!?;])\s+|\n+")
MAX_CANDIDATES = 8

DEFAULT_INSTRUCTIONS = (
    "The assistant is writing a file. The state gives the text the write replaces, the new text, "
    "the user's latest messages, and one sentence of the new text. Would a writer who never saw "
    "the replaced text or the conversation, writing for a reader who sees only the result, write "
    "this sentence? Answer true when the sentence is there because of the old version or the "
    "conversation: it says what is not done, not set, not published, unchanged, or no longer true, "
    "in contrast to the replaced text or to something the user corrected; or it tells the story "
    "of the change or the correction itself."
)
DEFAULT_CRITERIA = {
    "true": "The sentence answers the replaced text or the conversation: a new reader would not miss it, and only someone who saw the earlier version would think to say it.",
    "false": "The sentence tells a new reader what the thing is, what it does, or a limit they need to know, whatever the earlier version said.",
}


def words(text: str) -> set[str]:
    return {w.lower() for w in WORD.findall(text)} - STOP


def candidates(new: str, conversation: list[str]) -> list[dict[str, str]]:
    """The candidate sentences of NEW, in order."""
    said = words("\n".join(conversation))
    found = []
    # Code blocks are not sentences; inline code stays, since a name in backticks is often the
    # word a sentence shares with the replaced text.
    for sentence in SENTENCE.split(sessions.FENCE.sub(" ", new)):
        sentence = sentence.strip()
        if not sentence:
            continue
        if NARRATION.search(sentence):
            found.append({"sentence": sentence, "source": "narration"})
        elif NEGATION.search(sentence) and words(sentence) & said:
            found.append({"sentence": sentence, "source": "negation"})
    return found


def check(
    config: dict[str, Any],
    new: str,
    replaced: str,
    conversation: list[str],
    max_candidates: int = MAX_CANDIDATES,
) -> dict[str, Any]:
    result: dict[str, Any] = {"endpoint": None, "sentences": []}
    found = candidates(new, conversation)
    if not found:
        return result
    section = config.get("ghosts", {})
    question = {
        "ghost-sentence": {
            "type": "noul",
            "instructions": section.get("instructions", DEFAULT_INSTRUCTIONS),
            "criteria": section.get("criteria", DEFAULT_CRITERIA),
        }
    }
    block_at = float(section.get("pushBackAbove", 0.6))
    report_at = float(section.get("reportAbove", 0.4))
    for cand in found[:max_candidates]:
        state = {
            "replaced text": replaced[:3000],
            "new text": new[:6000],
            "the user's latest messages (context)": conversation,
            "the sentence": cand["sentence"],
        }
        answers, endpoint = first_answer(config, question, state)
        if answers is None:
            # No endpoint answered, and asking about the next sentence would repeat the same
            # refusals or timeouts.
            break
        try:
            p = float(answers["ghost-sentence"]["noul"])
        except (KeyError, TypeError, ValueError):
            continue
        result["endpoint"] = endpoint
        result["sentences"].append(
            {
                "sentence": cand["sentence"][:300],
                "source": cand["source"],
                "p": round(p, 3),
                "action": "block" if p >= block_at else "report" if p >= report_at else "none",
            }
        )
    return result


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="claude-ghost-check", description=__doc__.split("\n")[0])
    p.add_argument("--config", required=True, type=Path, help="the judge config (JSON)")
    p.add_argument("--transcript", type=Path, default=None, help="the session transcript, for the user's latest messages")
    p.add_argument("--replaced", type=Path, default=None, help="a file holding the text the write replaces")
    p.add_argument("--max-candidates", type=int, default=MAX_CANDIDATES, help="the most sentences to ask about")
    args = p.parse_args(argv)
    result: dict[str, Any] = {"endpoint": None, "sentences": []}
    try:
        config = json.loads(args.config.read_text())
        replaced = args.replaced.read_text() if args.replaced else ""
        conversation = user_messages(args.transcript) if args.transcript else []
        result = check(config, sys.stdin.read(), replaced, conversation, args.max_candidates)
    except (OSError, ValueError):
        pass
    json.dump(result, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
