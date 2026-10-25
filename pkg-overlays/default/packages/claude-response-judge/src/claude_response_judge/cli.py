# SPDX-License-Identifier: MIT
"""claude-response-judge: ask a decision model how likely each listed problem is in a text.

The text arrives on stdin. The config file (JSON, rendered by the claude-code module from
ch-ai-workbench.claude-code.judge) names the endpoints and the dimensions; `--kind` says
whether the text is a reply, prose for a file, or code, and only the dimensions whose
`targets` list that kind are asked. `--replaced` names a file holding the text an edit
replaces, and `--transcript` the session transcript, whose last few user messages are sent
as context; both go beside the new text. Each dimension is one yes/no question of the System
One API (`POST /v1/systemone`, the API of Base Labs'
decision models elephant-1 and mammoth-1). A noul dimension is a yes/no question, and the
model's answer is the probability that the problem is present in the text. A score dimension
lists ordered levels, and the model's answer is a probability for each level.

Endpoints are tried in the config's order, and the first one that answers wins. A local
decision-server that is not running refuses the connection at once, so the next endpoint
(Baseten's cloud) is tried with almost no delay. An endpoint with an `apiKeyFile` sends the
file's contents as `Authorization: Api-Key <key>`, Baseten's scheme; an endpoint whose key
file cannot be read is skipped. When no endpoint answers, the program prints the reasons on
stderr and exits with status 1, and the hooks fall back to the regex table alone.

On success stdout holds one JSON object:
  {"endpoint": NAME, "model": MODEL,
   "answers": {NOUL_DIMENSION: PROBABILITY, ...},
   "scores": {SCORE_DIMENSION: {"score": EXPECTED_LEVEL_INDEX, "levels": COUNT,
                                "level": MOST_LIKELY_LEVEL, "p": ITS_PROBABILITY}, ...}}
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from collections.abc import Sequence
from pathlib import Path
from typing import Any

FENCE = re.compile(r"^[ \t]*```.*?^[ \t]*```[^\n]*$", re.MULTILINE | re.DOTALL)

KINDS = {
    "reply": "a reply an AI coding assistant wrote to a working programmer",
    "prose": "text an AI coding assistant is writing into a prose file",
    "code": "code, with its comments, an AI coding assistant is writing into a source file",
}


def cut(text: str, max_chars: int) -> str:
    if len(text) > max_chars:
        text = text[:max_chars] + "\n[text cut here]"
    return text


def prepare(text: str, kind: str, max_chars: int) -> str:
    """The text the model judges, cut to max_chars; in a reply or a prose file, code blocks
    are replaced by a marker first.

    Inline backtick spans stay, because the words around a span read differently without it
    (a possessive followed by a code-font noun is not elliptical). Code blocks in prose go,
    because they are quoted material and cost most of the tokens. In a code file the code is
    the text.
    """
    if kind != "code":
        text = FENCE.sub("[code block]", text)
    return cut(text, max_chars)


REMINDER = re.compile(r"<system-reminder>.*?</system-reminder>", re.DOTALL)
TRANSCRIPT_TAIL = 4 << 20
USER_MESSAGES = 3
USER_MESSAGE_CHARS = 2000


def user_messages(transcript: Path) -> list[str]:
    """The last USER_MESSAGES things the user typed in a Claude Code session transcript.

    The transcript is JSON lines. A typed prompt is a `user` entry whose content is a string
    or holds text blocks; tool results are `user` entries holding tool_result blocks, and hook
    feedback and skill bodies are `user` entries marked isMeta. Only the file's last
    TRANSCRIPT_TAIL bytes are read, since a long session's transcript runs to megabytes.
    """
    with transcript.open("rb") as f:
        f.seek(0, 2)
        size = f.tell()
        f.seek(max(0, size - TRANSCRIPT_TAIL))
        lines = f.read().decode(errors="replace").splitlines()
    if size > TRANSCRIPT_TAIL:
        lines = lines[1:]
    found = []
    for line in reversed(lines):
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if entry.get("type") != "user" or entry.get("isMeta") or entry.get("isSidechain"):
            continue
        content = entry.get("message", {}).get("content")
        if isinstance(content, list):
            content = "\n".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
        if not isinstance(content, str):
            continue
        text = REMINDER.sub("", content).strip()
        if text:
            found.append(cut(text, USER_MESSAGE_CHARS))
            if len(found) == USER_MESSAGES:
                break
    return list(reversed(found))


def dimensions_for(config: dict[str, Any], kind: str) -> dict[str, Any]:
    return {name: dim for name, dim in config["dimensions"].items() if kind in dim["targets"]}


def request_body(
    config: dict[str, Any],
    endpoint: dict[str, Any],
    text: str,
    kind: str,
    replaced: str | None,
    conversation: list[str],
) -> dict[str, Any]:
    state: dict[str, Any] = {"kind": KINDS[kind], "text": text}
    if replaced is not None:
        # An edit's old text, so a question can ask about what the edit removes.
        state["replaced text"] = replaced
    if conversation:
        # What the user said just before the text was written, so a question can ask whether
        # the text answers the conversation instead of a reader who never saw it.
        state["the user's latest messages to the assistant, oldest first (context, not the text judged)"] = (
            conversation
        )
    return {
        "model": endpoint["model"],
        "state": state,
        "questions": {name: question(dim) for name, dim in dimensions_for(config, kind).items()},
    }


def question(dim: dict[str, Any]) -> dict[str, Any]:
    if dim["type"] == "score":
        return {"type": "score", "instructions": dim["instructions"], "criteria": dim["levels"]}
    return {
        "type": "noul",
        "instructions": dim["instructions"],
        "criteria": {"true": dim["criteria"]["true"], "false": dim["criteria"]["false"]},
    }


def read_score(answer: dict[str, Any], levels: list[str]) -> dict[str, Any]:
    """A score answer as the hooks report it: the expected level index (0 for the first
    level), the number of levels, and the most likely level with its probability."""
    probs = [float(answer["probabilities"][str(i)]) for i in range(len(levels))]
    best = max(range(len(levels)), key=probs.__getitem__)
    return {"score": round(float(answer["score"]), 3), "levels": len(levels), "level": levels[best], "p": probs[best]}


def ask(endpoint: dict[str, Any], body: dict[str, Any], dims: dict[str, Any]) -> dict[str, Any]:
    headers = {"Content-Type": "application/json"}
    if endpoint.get("apiKeyFile"):
        key = Path(endpoint["apiKeyFile"]).read_text().strip()
        if not key:
            raise ValueError(f"{endpoint['apiKeyFile']} is empty")
        headers["Authorization"] = f"Api-Key {key}"
    req = urllib.request.Request(
        endpoint["url"].rstrip("/") + "/v1/systemone",
        data=json.dumps(body).encode(),
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=endpoint["timeout"]) as resp:
        answers = json.load(resp)["answers"]
    verdict: dict[str, Any] = {"answers": {}, "scores": {}}
    for name in body["questions"]:
        if dims[name]["type"] == "score":
            verdict["scores"][name] = read_score(answers[name], dims[name]["levels"])
        else:
            verdict["answers"][name] = float(answers[name]["noul"])
    return verdict


def judge(
    config: dict[str, Any], text: str, kind: str, replaced: str | None = None, conversation: Sequence[str] = ()
) -> tuple[dict[str, Any] | None, list[str]]:
    if not dimensions_for(config, kind):
        return None, [f"no enabled dimension targets {kind}"]
    if not config["endpoints"]:
        return None, ["no endpoints are enabled"]
    text = prepare(text, kind, config["maxChars"])
    if replaced is not None:
        replaced = prepare(replaced, kind, config["maxChars"])
    failures = []
    dims = dimensions_for(config, kind)
    for endpoint in config["endpoints"]:
        try:
            verdict = ask(endpoint, request_body(config, endpoint, text, kind, replaced, list(conversation)), dims)
        except (OSError, ValueError, KeyError, TypeError) as err:
            # OSError covers a refused connection, a timeout, an unreadable key file, and an
            # HTTP error status (urllib's HTTPError), such as the 422 a local decision-server
            # returns for a text over the model's prompt limit.
            failures.append(f"{endpoint['name']}: {err}")
            continue
        return {"endpoint": endpoint["name"], "model": endpoint["model"], **verdict}, failures
    return None, failures


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="claude-response-judge", description=__doc__.split("\n")[0])
    p.add_argument("--config", required=True, type=Path, help="the judge config (JSON)")
    p.add_argument("--kind", choices=sorted(KINDS), default="reply", help="what the text on stdin is")
    p.add_argument("--replaced", type=Path, default=None, help="file holding the text an edit replaces")
    p.add_argument("--transcript", type=Path, default=None, help="the session transcript, for the user's latest messages")
    args = p.parse_args(argv)
    config = json.loads(args.config.read_text())
    replaced = args.replaced.read_text() if args.replaced else None
    conversation = []
    if args.transcript:
        try:
            conversation = user_messages(args.transcript)
        except OSError as err:
            print(f"claude-response-judge: transcript: {err}", file=sys.stderr)
    verdict, failures = judge(config, sys.stdin.read(), args.kind, replaced, conversation)
    for failure in failures:
        print(f"claude-response-judge: {failure}", file=sys.stderr)
    if verdict is None:
        return 1
    json.dump(verdict, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
