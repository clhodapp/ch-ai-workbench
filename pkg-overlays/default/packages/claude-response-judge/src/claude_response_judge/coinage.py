# SPDX-License-Identifier: MIT
"""claude-coinage-check: find names the assistant coined from generic words, and ask the
decision model which of them a reader could not decode.

A coinage is a "the <word>" or "the <word> <word>" phrase that names something from the
work ("the judge" for a decision-model client, "the ladder" for a scale) where neither the
words nor shared vocabulary say what it is. Once the user starts repeating one, it spreads
into memory, docs and other sessions, so the check fires at the phrase's second use.

A phrase is a candidate when all of these hold:
- the assistant has used it at least twice in this session, the text being checked
  included;
- the user has never typed its word, in any inflection, in any session (for a two-word
  phrase: never typed the two words together in this session);
- at most RARE_SESSIONS sessions that started before this one show it in assistant text;
- it is not an adjective, a plural, a verb after "the X", or the first word of one
  two-word phrase that carries most of its uses.
The other sessions come from the claude-session-index cache (an update is started in the
background when it is behind); the current transcript is read from its tail only.

Each candidate is one `name-opacity` score question for the first endpoint that answers. A
score at or above `pushBackAbove` (`writePushBackAbove` with `--write`) is a block, at or
above `reportAbove` a report. A phrase is judged once per session: its answer is kept in
$XDG_RUNTIME_DIR/claude-tic-check/coinage/<session id>.json, and a judged phrase is not
asked about again. With `--write`, a kept phrase that has not blocked yet blocks when its
kept score reaches `writePushBackAbove`. Without XDG_RUNTIME_DIR nothing is kept.

Without `--write`, the text checked is the current turn: the assistant messages since the
user's last typed prompt, and the final message from stdin (as with claude-turn-text). With
`--write`, stdin is text being written somewhere durable (memory, a doc, a commit or PR),
and that write counts as one use.

usage: claude-coinage-check --config JUDGE.json --transcript PATH [--write]

stdout holds one JSON object, and the exit status is 0:
  {"endpoint": NAME or null,
   "candidates": [{"phrase": "the X", "score": EXPECTED_LEVEL, "action": "block"|"report"|"none",
                   "sentence": FIRST_SENTENCE_USING_IT, "real_name": BACKTICKED_NAME or null}]}
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any

from . import sessions
from .cli import TRANSCRIPT_TAIL, USER_MESSAGES, cut, first_answer, transcript_entries, typed_prompt, user_wrote
from .turn import earlier_messages

DEFAULT_INSTRUCTIONS = (
    "How much does a programmer who did not follow the conversation have to guess to know "
    "what the phrase named in the state refers to?"
)
DEFAULT_LEVELS = [
    "Nothing: an ordinary word, a standard technical term, or a reference to something just named.",
    'Little: a name for something from this work whose words say what it is ("the edit hook", "the stored verdict").',
    'Everything: a name for something from this work built from a generic word or a metaphor ("the judge", "the ladder", "the latch").',
]

RARE_SESSIONS = 2
MAX_CANDIDATES = 4
SENTENCES = 6
NAMES = 80

# The second word must end at a word boundary that no apostrophe follows, so a contraction
# ("the judge doesn't") does not make "doesn" part of a name.
PHRASE = re.compile(r"\bthe ([a-z][a-z-]{2,})(?: ([a-z][a-z-]{2,})\b(?!['’]))?")
TICK = re.compile(r"`([^`\n]{2,60})`")
SENTENCE_END = re.compile(r"(?<=[.!?:;])\s+|\n+")
# Words after "the" that describe or count rather than name.
ADJECTIVES = set(
    """
    same other only most more less very such each both all any few many much own first second
    third last next new old whole rest entire actual real full right wrong best worst main
    one two three four five six seven eight nine ten
    """.split()
)
# Words that end a noun phrase, so "the X Y" with Y among them is "the X".
FUNCTION_WORDS = set(
    """
    and or but of to in on at by for with from as is are was were be been being has have had
    that this which who what when where why how not no it its than then so if into onto over
    under about after before between through during without within can could will would should
    may might must does did do also only just still now again too very yet there here
    myself itself yourself themselves each every all both either neither
    """.split()
)
# Verbs that follow a subject "the X" often enough to make "the X Y" a sentence, not a name.
VERBS = set(
    """
    use uses get gets run runs make makes take takes give gives keep keeps need needs say says
    show shows work works fail fails pass passes read reads write writes return returns behave
    behaves replace replaces stay stays come comes go goes ask asks hold holds see sees find finds
    """.split()
)


def stem(word: str) -> str:
    """A crude stem, so "judge", "judged" and "judging" match: one common suffix off, then a
    trailing e."""
    for suffix in ("ing", "ed", "es", "s"):
        if word.endswith(suffix) and len(word) - len(suffix) >= 3:
            word = word[: -len(suffix)]
            break
    return word[:-1] if word.endswith("e") else word


def sentences(text: str) -> list[str]:
    return [s.strip() for s in SENTENCE_END.split(sessions.prose(text)) if s.strip()]


def occurrences(text: str) -> list[tuple[str, str]]:
    """Each (phrase, sentence) in the prose of TEXT, repeats counted: "X" for every
    "the X", and "X Y" when Y can continue a noun phrase."""
    found = []
    for sentence in sentences(text):
        for m in PHRASE.finditer(sentence.lower()):
            first, second = m.group(1), m.group(2)
            if first in ADJECTIVES or first in FUNCTION_WORDS:
                continue
            found.append((first, sentence))
            if second and second not in FUNCTION_WORDS and second not in VERBS and not second.endswith("ed"):
                found.append((f"{first} {second}", sentence))
    return found


def split_turn(entries: list[dict[str, Any]]) -> tuple[list[str], list[str], list[str]]:
    """From transcript ENTRIES, oldest first: the assistant texts before the current turn,
    the user's typed prompts, and the prompts whose words are the user's own (accepted
    prompt suggestions left out, since their words come from the conversation)."""
    start = 0
    for i, entry in enumerate(entries):
        if typed_prompt(entry):
            start = i
    before, typed, written = [], [], []
    for i, entry in enumerate(entries):
        text = typed_prompt(entry)
        if text:
            typed.append(text)
            if user_wrote(entry):
                written.append(text)
            continue
        if i < start:
            text = sessions.assistant_text(entry)
            if text:
                before.append(text)
    return before, typed, written


def user_stems(data: dict[str, Any], typed: list[str]) -> set[str]:
    """Stems of every word the user has typed, from the sessions in the index and from the
    tail of this transcript, which may be ahead of the index."""
    out = set()
    for entry in data["sessions"].values():
        out.update(stem(w) for w in entry.get("user_words", []))
    for text in typed:
        out.update(stem(w) for w in sessions.words(text))
    return out


def candidates(
    checked: str,
    before: list[str],
    typed: list[str],
    data: dict[str, Any],
    transcript: Path,
    long_session: bool,
) -> list[dict[str, Any]]:
    """The phrases of CHECKED that pass the candidate rules, the rarest first."""
    in_text = occurrences(checked)
    if not in_text:
        return []
    uses = Counter(p for p, _ in in_text)
    for text in before:
        uses.update(p for p, _ in occurrences(text))
    # A tail that starts mid-session misses early uses. The index entry for this session
    # covers them, so a phrase it holds counts as used once before.
    indexed = set(data["sessions"].get(str(transcript), {}).get("assistant_phrases", [])) if long_session else set()
    known = user_stems(data, typed)
    typed_lower = " ".join(typed).lower()
    rarity = Counter()
    for entry in sessions.earlier(data, transcript):
        rarity.update(set(entry.get("assistant_phrases", [])))
    extensions: dict[str, Counter] = {}
    for p, _ in in_text:
        if " " in p:
            extensions.setdefault(p.split()[0], Counter())[p] += 1

    found, seen = [], set()
    for phrase, sentence in in_text:
        if phrase in seen:
            continue
        seen.add(phrase)
        total = uses[phrase] + (1 if phrase in indexed and uses[phrase] < 2 else 0)
        if total < 2 or rarity[phrase] > RARE_SESSIONS:
            continue
        if " " in phrase:
            if phrase in typed_lower:
                continue
        else:
            if stem(phrase) in known:
                continue
            if phrase.endswith("s") and not phrase.endswith("ss"):
                continue
            # "the stored" in "the stored verdict": the two-word phrase is the name.
            top = max(extensions.get(phrase, Counter()).values(), default=0)
            if top >= 2 and 2 * top >= uses[phrase]:
                continue
        found.append({"phrase": phrase, "sentence": sentence, "uses": total, "rarity": rarity[phrase]})
    found.sort(key=lambda c: (c["rarity"], -c["uses"]))
    return found


def backticked_names(texts: list[str]) -> list[str]:
    """Backticked names in TEXTS, newest last, each once."""
    names: dict[str, None] = {}
    for text in texts:
        for name in TICK.findall(text):
            names.pop(name, None)
            names[name] = None
    return list(names)


def real_name(phrase: str, names: list[str]) -> str | None:
    """The newest backticked name that contains the first five letters of the phrase's last
    word: the identifier the coinage may stand for."""
    head = re.escape(phrase.split()[-1][:5])
    for name in reversed(names):
        if re.search(r"(^|[-_./ ])" + head, name.lower()):
            return name
    return None


def state_for(phrase: str, texts: list[str], names: list[str], typed: list[str]) -> dict[str, Any]:
    pattern = re.compile(r"\bthe " + re.escape(phrase) + r"\b", re.IGNORECASE)
    used = [s for t in texts for s in sentences(t) if pattern.search(s)]
    return {
        "phrase": f"the {phrase}",
        "sentences where the assistant used it, oldest first": [s[:300] for s in used[-SENTENCES:]],
        "backticked names the assistant used so far": names[-NAMES:],
        "the user's latest messages to the assistant, oldest first (context)": [cut(t, 1500) for t in typed[-USER_MESSAGES:]],
    }


def state_file(transcript: Path) -> Path | None:
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if not runtime:
        return None
    return Path(runtime) / "claude-tic-check" / "coinage" / f"{transcript.stem}.json"


def read_judged(path: Path | None) -> dict[str, Any]:
    if path is None:
        return {}
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def write_judged(path: Path | None, judged: dict[str, Any]) -> None:
    if path is None:
        return
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(judged))
        tmp.replace(path)
    except OSError:
        pass


def check(
    config: dict[str, Any],
    transcript: Path,
    stdin_text: str,
    write: bool,
    index: Path | None = None,
    projects: Path | None = None,
    max_candidates: int = MAX_CANDIDATES,
) -> dict[str, Any]:
    result: dict[str, Any] = {"endpoint": None, "candidates": []}
    try:
        sessions.update_detached(projects, index)
    except OSError:
        pass
    try:
        entries = transcript_entries(transcript)
        long_session = transcript.stat().st_size > TRANSCRIPT_TAIL
    except OSError:
        return result
    before, typed, written = split_turn(entries)
    if write:
        # Everything in the tail is earlier text, the current turn included.
        before = [t for t in (sessions.assistant_text(e) for e in entries) if t]
        checked = stdin_text
    else:
        turn = earlier_messages(entries)
        final = stdin_text.strip()
        if final and (not turn or turn[-1] != final):
            turn.append(final)
        checked = "\n\n".join(turn)
    data = sessions.load(index)
    path = state_file(transcript)
    judged = read_judged(path)
    section = config.get("coinage", {})
    block_at = float(section.get("writePushBackAbove" if write else "pushBackAbove", 1.4))
    report_at = float(section.get("reportAbove", 1.0))
    found = candidates(checked, before, written, data, transcript, long_session)
    texts = [*before, checked]
    names = backticked_names(texts)
    if write:
        # A write blocks at a lower score than a reply, so a phrase the session judged
        # earlier without blocking blocks now if its kept score reaches the write level.
        for cand in found:
            kept = judged.get(cand["phrase"])
            if kept and kept.get("action") != "block" and float(kept.get("score", 0)) >= block_at:
                result["candidates"].append(
                    {
                        "phrase": f"the {cand['phrase']}",
                        "score": kept["score"],
                        "action": "block",
                        "sentence": cand["sentence"][:300],
                        "real_name": real_name(cand["phrase"], names),
                    }
                )
                judged[cand["phrase"]] = {**kept, "action": "block"}
    found = [c for c in found if c["phrase"] not in judged]
    if not found:
        if result["candidates"]:
            write_judged(path, judged)
        return result
    question = {
        "name-opacity": {
            "type": "score",
            "instructions": section.get("instructions", DEFAULT_INSTRUCTIONS),
            "criteria": section.get("levels", DEFAULT_LEVELS),
        }
    }
    for cand in found[:max_candidates]:
        answers, endpoint = first_answer(config, question, state_for(cand["phrase"], texts, names, typed))
        if answers is None:
            # No endpoint answered, and asking for the next candidate would repeat the same
            # refusals or timeouts.
            break
        try:
            score = float(answers["name-opacity"]["score"])
        except (KeyError, TypeError, ValueError):
            continue
        action = "block" if score >= block_at else "report" if score >= report_at else "none"
        result["endpoint"] = endpoint
        result["candidates"].append(
            {
                "phrase": f"the {cand['phrase']}",
                "score": round(score, 3),
                "action": action,
                "sentence": cand["sentence"][:300],
                "real_name": real_name(cand["phrase"], names),
            }
        )
        judged[cand["phrase"]] = {"score": round(score, 3), "action": action}
    if result["candidates"]:
        write_judged(path, judged)
    return result


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="claude-coinage-check", description=__doc__.split("\n")[0])
    p.add_argument("--config", required=True, type=Path, help="the judge config (JSON)")
    p.add_argument("--transcript", required=True, type=Path, help="the session transcript")
    p.add_argument("--write", action="store_true", help="stdin is text being written to a durable place")
    p.add_argument("--index", type=Path, default=None, help="the session index file (default: the claude-session-index cache)")
    p.add_argument("--projects", type=Path, default=None, help="the transcripts directory the index covers")
    p.add_argument("--max-candidates", type=int, default=MAX_CANDIDATES, help="most phrases judged per call")
    args = p.parse_args(argv)
    try:
        config = json.loads(args.config.read_text())
        result = check(config, args.transcript, sys.stdin.read(), args.write, args.index, args.projects, args.max_candidates)
    except (OSError, ValueError, KeyError, TypeError) as err:
        print(f"claude-coinage-check: {err}", file=sys.stderr)
        result = {"endpoint": None, "candidates": []}
    json.dump(result, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
