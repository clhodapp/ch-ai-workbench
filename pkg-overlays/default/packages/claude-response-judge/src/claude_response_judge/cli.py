# SPDX-License-Identifier: MIT
"""claude-response-judge: ask a decision model how likely each listed problem is in a text.

The text arrives on stdin. The config file (JSON, rendered by the claude-code module from
ch-ai-workbench.claude-code.judge) names the endpoints and the dimensions. Each dimension is
one yes/no question of the System One API (`POST /v1/systemone`, the API of Base Labs'
decision models elephant-1 and mammoth-1), and the model's answer to it is the probability
that the problem is present in the text.

Endpoints are tried in the config's order, and the first one that answers wins. A local
decision-server that is not running refuses the connection at once, so the next endpoint
(Baseten's cloud) is tried with almost no delay. An endpoint with an `apiKeyFile` sends the
file's contents as `Authorization: Api-Key <key>`, Baseten's scheme; an endpoint whose key
file cannot be read is skipped. When no endpoint answers, the program prints the reasons on
stderr and exits with status 1, and the hooks fall back to the regex table alone.

On success stdout holds one JSON object:
  {"endpoint": NAME, "model": MODEL, "answers": {DIMENSION: PROBABILITY, ...}}
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path
from typing import Any

FENCE = re.compile(r"^[ \t]*```.*?^[ \t]*```[^\n]*$", re.MULTILINE | re.DOTALL)

KINDS = {
    "reply": "a reply an AI coding assistant wrote to a working programmer",
    "edit": "text an AI coding assistant is writing into a prose file",
}


def prose(text: str, max_chars: int) -> str:
    """The text the model judges: code blocks replaced by a marker, cut to max_chars.

    Inline backtick spans stay, because the words around a span read differently without it
    (a possessive followed by a code-font noun is not elliptical). Code blocks go, because
    they are quoted material and cost most of the tokens.
    """
    text = FENCE.sub("[code block]", text)
    if len(text) > max_chars:
        text = text[:max_chars] + "\n[text cut here]"
    return text


def request_body(config: dict[str, Any], endpoint: dict[str, Any], text: str, kind: str) -> dict[str, Any]:
    return {
        "model": endpoint["model"],
        "state": {"kind": KINDS[kind], "text": text},
        "questions": {
            name: {
                "type": "noul",
                "instructions": dim["instructions"],
                "criteria": {"true": dim["criteria"]["true"], "false": dim["criteria"]["false"]},
            }
            for name, dim in config["dimensions"].items()
        },
    }


def ask(endpoint: dict[str, Any], body: dict[str, Any]) -> dict[str, float]:
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
    return {name: float(answers[name]["noul"]) for name in body["questions"]}


def judge(config: dict[str, Any], text: str, kind: str) -> tuple[dict[str, Any] | None, list[str]]:
    if not config["dimensions"]:
        return None, ["no dimensions are enabled"]
    if not config["endpoints"]:
        return None, ["no endpoints are enabled"]
    text = prose(text, config["maxChars"])
    failures = []
    for endpoint in config["endpoints"]:
        try:
            answers = ask(endpoint, request_body(config, endpoint, text, kind))
        except (OSError, ValueError, KeyError, TypeError) as err:
            # OSError covers a refused connection, a timeout, an unreadable key file, and an
            # HTTP error status (urllib's HTTPError), such as the 422 a local decision-server
            # returns for a text over the model's prompt limit.
            failures.append(f"{endpoint['name']}: {err}")
            continue
        return {"endpoint": endpoint["name"], "model": endpoint["model"], "answers": answers}, failures
    return None, failures


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="claude-response-judge", description=__doc__.split("\n")[0])
    p.add_argument("--config", required=True, type=Path, help="the judge config (JSON)")
    p.add_argument("--kind", choices=sorted(KINDS), default="reply", help="what the text on stdin is")
    args = p.parse_args(argv)
    config = json.loads(args.config.read_text())
    verdict, failures = judge(config, sys.stdin.read(), args.kind)
    for failure in failures:
        print(f"claude-response-judge: {failure}", file=sys.stderr)
    if verdict is None:
        return 1
    json.dump(verdict, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
