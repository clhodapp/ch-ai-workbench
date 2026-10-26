# SPDX-License-Identifier: MIT
"""claude-familiarity-check: find what a write leans on that only the conversation or the task showed.

Text written to a file or a pull request is read by someone who never saw the conversation it
came out of. It may lean on the ecosystem and on the codebase, but not on what only the chat or
the work showed: a review, a plan item, an earlier draft, tool output, a name coined during
the work. Asked about a whole text, the judge scores how hard the subject is. So this program
finds candidates first and asks about each one:

- phrases about the work ("a phrasing review", "the next PR", "item 4", "29 of 29"), first;
- name-like strings (code spans, paths, identifiers, proper nouns, quoted phrases), found the
  way claude-reference-check finds them.

A candidate that also appears in the text the write replaces is already in the file, so it is
left out. Each remaining candidate, up to MAX_CANDIDATES, gets two questions in one request:
`familiarity`, a score on the ladder general programming < the ecosystem < this codebase <
this conversation or task, and `described`, a noul asking whether the text itself says briefly
what the candidate is. A brief description exonerates a candidate. A candidate whose
probability of the last level reaches `pushBackAbove`, and whose `described` probability is
below `describedBelow`, is a block; one that reaches `reportAbove` is a report.

usage: claude-familiarity-check --config JUDGE.json --kind prose|message [--replaced FILE] [--transcript PATH]

The config's `familiarity` section holds the two questions (`familiarity`, `described`) and the
thresholds; the module constants below are the defaults. stdout holds one JSON object:
  {"endpoint": NAME or null,
   "candidates": [{"candidate": TEXT, "chat": P, "described": P, "action": "block" | "report" | "none"}, ...]}
and the program exits 0 whatever happens, so a hook never fails on it.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

from . import references
from .cli import first_answer, user_messages

WORK = re.compile(
    r"\b(?:(?:item|section|step) \d+|\d+ of \d+"
    r"|(?:a|an|the|its|their|this|that|these|those|next|earlier|previous)\s+"
    r"(?:(?!(?:is|are|was|were|has|have)\b)[\w-]+\s+){0,2}?"
    r"(?:review|reviews|items?|section|PR|pull request|session|subagent|agent|run|pass|draft|plan|design|"
    r"notes?|proposal|decision|correction|feedback|discussion|findings?|request|ask|task|wave|slice|phase))\b",
    re.IGNORECASE,
)
# Trailers and the attribution line every commit and pull request carries.
SKIP = {"co-authored-by", "anthropic.com", "claude.com", "com/claude-code", "claude-code", "claude code", "noreply@anthropic.com"}
MAX_CANDIDATES = 8
PUSH_BACK_ABOVE = 0.7
REPORT_ABOVE = 0.4
DESCRIBED_BELOW = 0.8
KINDS = {"prose": "a prose file", "message": "a commit message, pull request text, or review"}

DEFAULT_QUESTIONS = {
    "familiarity": {
        "type": "score",
        "instructions": (
            "The assistant wrote the text into a file or a pull request. What must a reader already know to "
            "tell what the candidate in the state refers to, if the text did not explain it?"
        ),
        "criteria": [
            "Nothing beyond general programming.",
            "The ecosystem: the tools, languages and libraries it works with (Nix flakes, home-manager, GitHub), not this repository.",
            "This codebase: the repository's own modules, files, options and conventions.",
            "This conversation or task: only the chat or the work showed it, such as a name coined during the work, an earlier draft, tool output, a review, a plan, or a decision made in the chat.",
        ],
    },
    "described": {
        "type": "noul",
        "instructions": (
            "Does the text itself say briefly what the candidate is, so that a reader who never saw the "
            "conversation or the work can tell what it refers to?"
        ),
        "criteria": {
            "true": "The text says what it is, in a clause, a gloss, or the sentence around it.",
            "false": "The text uses it without saying what it is.",
        },
    },
}


def candidates(text: str, replaced: str) -> list[str]:
    """The candidates of TEXT in the order they are asked about, without those in REPLACED."""
    prose = references.FENCE.sub(" ", text)
    # Phrases about the work first: they are the likeliest to need the conversation.
    found = [m.group(0) for m in WORK.finditer(prose)]
    found += [surface for low, (surface, _kind) in references.candidates(text).items() if not low.startswith("#")]
    old = replaced.lower()
    seen: set[str] = set()
    out = []
    for cand in found:
        low = cand.lower()
        if low in seen or low in SKIP or (old and low in old):
            continue
        seen.add(low)
        out.append(cand)
    return out


def check(
    config: dict[str, Any],
    text: str,
    kind: str,
    replaced: str,
    conversation: list[str],
    max_candidates: int = MAX_CANDIDATES,
) -> dict[str, Any]:
    result: dict[str, Any] = {"endpoint": None, "candidates": []}
    found = candidates(text, replaced)
    if not found:
        return result
    section = config.get("familiarity", {})
    questions = {
        "familiarity": section.get("familiarity", DEFAULT_QUESTIONS["familiarity"]),
        "described": section.get("described", DEFAULT_QUESTIONS["described"]),
    }
    block_at = float(section.get("pushBackAbove", PUSH_BACK_ABOVE))
    report_at = float(section.get("reportAbove", REPORT_ABOVE))
    described_below = float(section.get("describedBelow", DESCRIBED_BELOW))
    last = str(len(questions["familiarity"]["criteria"]) - 1)
    for cand in found[:max_candidates]:
        state = {
            "kind": KINDS.get(kind, kind),
            "text": text[:6000],
            "the user's latest messages (context)": conversation,
            "candidate": cand,
        }
        answers, endpoint = first_answer(config, questions, state)
        if answers is None:
            # No endpoint answered, and asking about the next candidate would repeat the same
            # refusals or timeouts.
            break
        try:
            chat = float(answers["familiarity"]["probabilities"][last])
            described = float(answers["described"]["noul"])
        except (KeyError, TypeError, ValueError):
            continue
        if described >= described_below:
            action = "none"
        else:
            action = "block" if chat >= block_at else "report" if chat >= report_at else "none"
        result["endpoint"] = endpoint
        result["candidates"].append(
            {"candidate": cand[:200], "chat": round(chat, 3), "described": round(described, 3), "action": action}
        )
    return result


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="claude-familiarity-check", description=__doc__.split("\n")[0])
    p.add_argument("--config", required=True, type=Path, help="the judge config (JSON)")
    p.add_argument("--kind", required=True, choices=sorted(KINDS), help="what the text is")
    p.add_argument("--replaced", type=Path, default=None, help="a file holding the text the write replaces")
    p.add_argument("--transcript", type=Path, default=None, help="the session transcript, for the user's latest messages")
    p.add_argument("--max-candidates", type=int, default=MAX_CANDIDATES, help="the most candidates to ask about")
    args = p.parse_args(argv)
    result: dict[str, Any] = {"endpoint": None, "candidates": []}
    try:
        config = json.loads(args.config.read_text())
        replaced = args.replaced.read_text() if args.replaced else ""
        conversation = user_messages(args.transcript) if args.transcript else []
        result = check(config, sys.stdin.read(), args.kind, replaced, conversation, args.max_candidates)
    except (OSError, ValueError):
        pass
    json.dump(result, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
