# SPDX-License-Identifier: MIT
"""claude-reference-check: find the references in a reply that point at things the user was not shown.

A reply assumes too much when it refers back to something its reader never saw: tool output,
an edit the assistant made, another Claude session, a subagent, or a name coined out of sight.
Whether a name is new says little on its own, because replies introduce names all the time
and most come with a gloss or are handed over as a command or path to use. So this program
looks for two narrower things in the final message of a turn (read from stdin):

- definite references: "the/its/their <modifiers> <head>" where the head is a work word
  (session, agent, report, notes, step, rule, proxy...), and neither the phrase nor an
  antecedent in the same message appears in what the user was shown. These are flagged as is.
- tool-only names: identifiers, paths and quoted names that occur in tool input or output of
  this session, but in no text the user was shown and in no word of the user's world lexicon.
  The lexicon is the session index (claude-session-index): the words the user typed and the
  assistant prose they were shown in sessions that started earlier. Each tool-only name goes
  to the judge with two yes/no questions, "can the reader tell what it refers to" and "is it
  used as if already known"; the name is flagged when P(not resolvable) times P(presupposed)
  reaches `flagAbove`.

What the user was shown is read from the transcript's tail only (cli.transcript_entries): the
typed prompts and the assistant text of the session, without the final message itself and
without earlier messages of the same turn that are drafts of it. The program also starts a
detached index update, so the next run sees the sessions this one found behind.

usage: claude-reference-check --config JUDGE.json --transcript PATH [--index FILE] [--projects DIR]

The config's `references` section holds the two judge questions (`resolvable`, `presupposed`),
`flagAbove` and `blockAtFlags`; the module constants below are the defaults. When no endpoint
answers, only the definite references are flagged. stdout holds one JSON object:
  {"endpoint": NAME or null,
   "flags": [{"reference": TEXT, "sentence": TEXT, "source": "definite" | "tool-only", "p": P or null}, ...],
   "block": BOOL}
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
from .cli import REMINDER, first_answer, transcript_entries, typed_prompt

READER = (
    "The reader is the person who typed user_messages. They saw the assistant's replies and their own messages, "
    "but never saw tool output, file edits the assistant made, other Claude sessions or subagents."
)
RESOLVABLE = {
    "type": "noul",
    "instructions": READER
    + " reader_saw holds everything they were shown that mentions the candidate (or 'nothing'). "
    "Reading the sentence, can they tell what the candidate refers to, either from this message itself or from reader_saw?",
    "criteria": {
        "true": "The reader can tell what it refers to: the message defines or describes it, reader_saw shows it, "
        "or it is common knowledge for a programmer.",
        "false": "The reader cannot tell what it refers to: it points at something they were not shown and the message "
        "does not explain it.",
    },
}
PRESUPPOSED = {
    "type": "noul",
    "instructions": "Does the sentence use the candidate as if the reader already knows which thing it is (a 'the X', "
    "'its X' or 'their X' pointing back to something), rather than introducing it, defining it, or handing it over as "
    "a command, path, citation or new name to use?",
    "criteria": {
        "true": "It is used as already known, pointing back at a specific thing.",
        "false": "It is introduced, defined, or handed over for the reader to use.",
    },
}
FLAG_ABOVE = 0.44
BLOCK_AT_FLAGS = 2
# Each judged name costs one request (about 0.3 s on a local server); a message with more
# tool-only names than this has its first ones judged.
MAX_JUDGED = 8
MAX_TEXT = 20000
USER_MESSAGES = 3

# Turns that start with these are the harness speaking, not the user typing.
NOT_TYPED = ("<task-notification", "<command-", "<local-command", "[Request interrupted", "This session is being continued")

FENCE = re.compile(r"```.*?```", re.DOTALL)
CODE = re.compile(r"`([^`\n]{1,120})`")
PATH = re.compile(r"(?<![\w/])((?:~|\.{1,2})?/?[\w.@+-]+(?:/[\w.@+-]+)+/?)")
NUM = re.compile(r"(?:(?:PR|pull request|issue|#)\s*#?(\d{1,6}))", re.I)
HASH = re.compile(r"\b([0-9a-f]{7,40})\b")
IDENT = re.compile(r"\b([A-Za-z][\w]*(?:[_.-][\w]+)+|[a-z]+[A-Z]\w*|[A-Za-z]+\d+[\w]*)\b")
PROPER = re.compile(r"(?<![.!?:]\s)(?<!^)\b([A-Z][a-z]+[A-Z]\w*|[A-Z]{2,}[\w-]*|[A-Z][a-z]+(?:\s[A-Z][a-z]+)+)\b")
QUOTE = re.compile(r'"([^"\n]{3,60})"')
NUMBERLIKE = re.compile(r"[\d.,:%x×-]+|v?\d[\w.]*")
WEB = re.compile(r"(https?:|www\.|[\w-]+\.(com|org|de|io|re|za))")

# Words that name a kind of thing: a name next to one of them says what it is.
TYPE_NOUNS = (
    r"(?:file|files|option|options|script|module|modules|command|commands|check|checks|branch|driver|package|packages"
    r"|tool|tools|unit|service|function|variable|header|sensor|sensors|test|tests|flag|key|keys|attribute|field|setting"
    r"|directory|repo|repository|job|workflow|step|rule|entry|daemon|library|chip|format|state|mode|error|server|session"
    r"|commit|pull request|PR|binary|wrapper|hook|plugin|skill|integration|class|layer|curve|value|database|store"
    r"|socket|cache|path|config|configuration)"
)
# Heads of definite references that point at work: a reader resolves "the recording proxy"
# only if they saw it.
HEADS = (
    r"(?:session|agent|subagent|report|notes?|step|rule|fix|check|test|proxy|diagnostic|question|wrappers?|guard|walk"
    r"|script|run|job|hook|findings?|proposal|idea|approach|workaround|pattern|plan|change|design|decision|layout|list"
    r"|command|entry)"
)
DEFINITE = re.compile(r"\b(the|their|its|that|those|these)\s+((?:[A-Za-z0-9/_-]+ ){0,3}?)(" + HEADS + r")\b", re.I)
# Heads specific enough to flag with no modifier ("the diagnostic", "the agent").
BARE_HEADS = {"diagnostic", "agent", "subagent", "proxy", "walk", "notes", "report", "wrappers"}
GENERIC_MODS = set(
    "same other new first second last next whole full current old previous earlier existing real actual one two three "
    "only main local remote following above below final open".split()
)
TOKEN = re.compile(r"[a-z0-9_]{3,}")


class Seen:
    """What the user was shown before the final message, what this session's tools saw, and
    the user's world lexicon from earlier sessions."""

    def __init__(self, entries: list[dict[str, Any]], final: str, index: dict[str, Any], transcript: Path):
        shown: list[tuple[str, str]] = []
        tool: list[str] = []
        final_tokens = tokens(final)
        turn_start = max((i for i, e in enumerate(entries) if typed_prompt(e)), default=-1)
        for i, entry in enumerate(entries):
            typed = typed_prompt(entry)
            if typed:
                if not typed.startswith(NOT_TYPED):
                    shown.append(("user", typed))
                continue
            content = entry.get("message", {}).get("content")
            if isinstance(content, str):
                content = [{"type": "text", "text": content}]
            if not isinstance(content, list):
                continue
            for block in content:
                if not isinstance(block, dict):
                    continue
                kind = block.get("type")
                if kind == "tool_use":
                    tool.append(json.dumps(block.get("input", {})))
                elif kind == "tool_result":
                    out = block.get("content")
                    if isinstance(out, list):
                        out = "\n".join(b.get("text", "") for b in out if isinstance(b, dict))
                    tool.append(str(out or ""))
                elif kind == "text" and entry.get("type") == "assistant" and not entry.get("isMeta"):
                    text = block.get("text", "").strip()
                    if not text or text.startswith("tic-check") or text == final:
                        continue
                    if i > turn_start:
                        # An earlier message of this turn that shares most of its words with the
                        # final message is a draft of it, not something the user saw first.
                        t = tokens(text)
                        if t and len(t & final_tokens) / len(t | final_tokens) > 0.5:
                            continue
                    shown.append(("assistant", REMINDER.sub("", text)))
        self.shown = shown
        self.text = "\n".join(t for _, t in shown).lower()
        self.tool = "\n".join(tool).lower()
        self.user_messages = [t[:1500] for k, t in shown if k == "user"][-USER_MESSAGES:]
        world_words: set[str] = set()
        world_phrases: set[str] = set()
        for e in sessions.earlier(index, transcript):
            world_words.update(e.get("user_words", ()))
            world_words.update(e.get("assistant_words", ()))
            world_phrases.update(e.get("assistant_phrases", ()))
        self.world_words = world_words
        self.world_phrases = world_phrases

    def in_world(self, name: str) -> bool:
        ws = sessions.words(name)
        return bool(ws) and ws <= self.world_words


def tokens(text: str) -> set[str]:
    return set(TOKEN.findall(text.lower()))


def candidates(text: str) -> dict[str, tuple[str, str]]:
    """The name-like strings of a message, lowercased, each with its first spelling and its
    kind (code span, number, hash, path, identifier, proper noun, quoted phrase)."""
    out: dict[str, tuple[str, str]] = {}

    def add(s: str, kind: str) -> None:
        n = s.strip().strip(".,;:()[]{}").lower()
        if len(n) >= 2 and n not in out:
            out[n] = (s, kind)

    t = FENCE.sub(" ", text)
    for m in CODE.finditer(t):
        add(m.group(1), "code")
    for m in NUM.finditer(t):
        add("#" + m.group(1), "num")
    for m in HASH.finditer(t):
        if re.search(r"\d", m.group(1)) and re.search(r"[a-f]", m.group(1)):
            add(m.group(1), "hash")
    plain = CODE.sub(" ", t)
    for m in PATH.finditer(plain):
        if not m.group(1).startswith("http") and "//" not in m.group(1):
            add(m.group(1), "path")
    for m in IDENT.finditer(plain):
        add(m.group(1), "ident")
    for m in PROPER.finditer(plain):
        add(m.group(1), "proper")
    for m in QUOTE.finditer(plain):
        add(m.group(1), "quote")
    return out


def glossed(text: str, surface: str) -> bool:
    """Whether the message says what SURFACE is where it first uses it: a parenthesis, an
    apposition, "X is a ...", or a kind word next to it ("the X driver", "the module X")."""
    i = text.lower().find(surface.lower())
    if i < 0:
        return False
    after = text[i + len(surface) : i + len(surface) + 60].lstrip("`")
    before = text[max(0, i - 40) : i]
    if re.match(r"\s*\((?![\w./-]*:\d)[^)]{3,}\)", after):
        return True
    if re.match(r"\s*(,\s*(which|a|an|the|i\.e\.|meaning)\b|\s+(is|are)\s+(a|an|the)\b|\s+(means|stands for)\b|\s*:\s+[a-z])", after):
        return True
    if re.match(r"\s*" + TYPE_NOUNS + r"\b", after, re.I):
        return True
    return bool(re.search(r"\b(called|named|the|a|an|its|new)\s+" + TYPE_NOUNS + r"\s*[`\"]?\s*$", before, re.I))


def handed_over(text: str, surface: str, kind: str) -> bool:
    """Names the reader is given rather than asked to know: quoted output, commit hashes,
    file:line citations, English hyphenated compounds, commands to run, parts of URLs."""
    if kind in ("quote", "hash"):
        return True
    if re.search(r":\d+(-\d+)?$", surface):
        return True
    if kind == "ident" and re.fullmatch(r"[a-z]+(-[a-z]+)+", surface):
        return True
    i = text.find(surface)
    before = text[max(0, i - 30) : i].lower()
    if " " in surface and re.search(r"\b(run|running|with|type|use|paste the output of)\s+`?$", before):
        return True
    return bool(re.search(r"(https?://|github\.com/)\S*$", before))


def tool_only_names(final: str, seen: Seen) -> list[str]:
    out = []
    for n, (s, kind) in candidates(final).items():
        if NUMBERLIKE.fullmatch(n) or (kind == "path" and WEB.match(n)):
            continue
        if n in seen.text or seen.in_world(n) or n not in seen.tool:
            continue
        if handed_over(final, s, kind) or glossed(final, s):
            continue
        out.append(s)
    return out


def definite_references(final: str, seen: Seen) -> list[str]:
    out = []
    low = final.lower()
    recent = seen.text[-20000:]
    for m in DEFINITE.finditer(final):
        head = m.group(3).lower()
        content = [w for w in m.group(2).lower().split() if w not in GENERIC_MODS]
        if not content and m.group(1).lower() not in ("their", "its") and head not in BARE_HEADS:
            continue
        phrase = " ".join(content + [head])
        if content and (re.search(re.escape(phrase).replace(r"\ ", r"\W+"), seen.text) or phrase in seen.world_phrases):
            continue
        # A bare "the agent" is anchored by recent text only; the words occur everywhere in a long session.
        if not content and re.search(r"\b" + re.escape(m.group(0).lower()) + r"\b", recent):
            continue
        earlier = low[: m.start()]
        if content and any(re.search(r"\b" + re.escape(w) + r"\b", earlier) for w in content):
            continue
        if not content and re.search(r"\b" + head + r"\b", earlier):
            continue
        if re.match(r"\s*(\(|,\s*(which|a|an|the)\b|:\s)", final[m.end() : m.end() + 60]):
            continue
        out.append(m.group(0))
    return out


def sentence(text: str, ref: str) -> str:
    i = text.lower().find(ref.lower())
    if i < 0:
        return ref
    start = max(text.rfind(". ", 0, i), text.rfind("\n", 0, i), text.rfind("? ", 0, i), text.rfind("! ", 0, i))
    ends = [x for x in (text.find(". ", i + len(ref)), text.find("\n", i + len(ref))) if x >= 0]
    return text[start + 1 : (min(ends) if ends else len(text)) + 1].strip()[:600]


STOPWORDS = set("the its their that those these a an of to in on for and or with this".split())


def reader_saw(seen: Seen, ref: str) -> list[str]:
    """Up to three excerpts of what the user was shown that mention REF, newest first: the
    whole name, then its words together, then its longer words one by one."""
    words = [w for w in re.findall(r"[a-z0-9_./-]+", ref.lower().strip("`")) if w not in STOPWORDS]
    keys = [ref.lower().strip("`")] + ([" ".join(words)] if len(words) > 1 else []) + [w for w in words if len(w) > 3]
    found: list[str] = []
    for key in keys:
        for kind, text in reversed(seen.shown):
            i = text.lower().find(key)
            if i < 0:
                continue
            excerpt = f"[{kind}] " + text[max(0, i - 150) : i + 150].replace("\n", " ")
            if excerpt not in found:
                found.append(excerpt)
            if len(found) == 3:
                return found
        if found:
            return found
    return ["nothing"]


def check(config: dict[str, Any], final: str, entries: list[dict[str, Any]], index: dict[str, Any], transcript: Path) -> dict[str, Any]:
    settings = config.get("references", {})
    flag_above = settings.get("flagAbove", FLAG_ABOVE)
    block_at = settings.get("blockAtFlags", BLOCK_AT_FLAGS)
    questions = {
        "reference-resolvable": settings.get("resolvable", RESOLVABLE),
        "reference-presupposed": settings.get("presupposed", PRESUPPOSED),
    }
    seen = Seen(entries, final.strip(), index, transcript)
    flags = [
        {"reference": r, "sentence": sentence(final, r), "source": "definite", "p": None}
        for r in definite_references(final, seen)
    ]
    endpoint = None
    text = final if len(final) <= MAX_TEXT else final[:MAX_TEXT] + "\n[text cut here]"
    for name in tool_only_names(final, seen)[: settings.get("maxCandidates", MAX_JUDGED)]:
        state = {
            "text": text,
            "candidate": name,
            "sentence": sentence(final, name),
            "reader_saw": reader_saw(seen, name),
            "user_messages": seen.user_messages,
        }
        answers, endpoint = first_answer(config, questions, state)
        if answers is None:
            # No endpoint answers: the remaining names go unjudged, and only definite
            # references are flagged.
            endpoint = None
            flags = [f for f in flags if f["source"] == "definite"]
            break
        p = (1 - float(answers["reference-resolvable"]["noul"])) * float(answers["reference-presupposed"]["noul"])
        if p >= flag_above:
            flags.append({"reference": name, "sentence": state["sentence"], "source": "tool-only", "p": round(p, 3)})
    return {"endpoint": endpoint, "flags": flags, "block": len(flags) >= block_at}


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="claude-reference-check", description=__doc__.split("\n")[0])
    p.add_argument("--config", required=True, type=Path, help="the judge config (JSON)")
    p.add_argument("--transcript", required=True, type=Path, help="the session transcript")
    p.add_argument("--index", type=Path, default=None, help="the session index (default: under $XDG_CACHE_HOME)")
    p.add_argument("--projects", type=Path, default=None, help="the transcripts directory the index covers")
    args = p.parse_args(argv)
    final = sys.stdin.read()
    result: dict[str, Any] = {"endpoint": None, "flags": [], "block": False}
    try:
        config = json.loads(args.config.read_text())
        try:
            sessions.update_detached(args.projects, args.index)
        except OSError as err:
            print(f"claude-reference-check: index update: {err}", file=sys.stderr)
        try:
            entries = transcript_entries(args.transcript)
        except OSError as err:
            print(f"claude-reference-check: transcript: {err}", file=sys.stderr)
            entries = []
        result = check(config, final, entries, sessions.load(args.index), args.transcript)
    except Exception as err:  # noqa: BLE001 - a hook must never fail on this check
        print(f"claude-reference-check: {type(err).__name__}: {err}", file=sys.stderr)
    json.dump(result, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
