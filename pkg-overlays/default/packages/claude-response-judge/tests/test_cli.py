# SPDX-License-Identifier: MIT
"""The judge client end to end, through the command line in a subprocess, against stub
System One servers on loopback: the request it sends, the order it tries endpoints in, the
API key header, and the failures that move it on to the next endpoint or make it give up."""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "src"

DIMENSIONS = {
    "fragments": {
        "type": "noul",
        "instructions": "Does the prose drop subjects or verbs?",
        "criteria": {"true": "it does", "false": "it does not"},
        "targets": ["reply", "prose"],
    },
    "never": {
        "type": "noul",
        "instructions": "Is never used as emphasis?",
        "criteria": {"true": "it is", "false": "it is not"},
        "targets": ["reply", "prose"],
    },
    "ghosts": {
        "type": "noul",
        "instructions": "Does a comment explain what is absent?",
        "criteria": {"true": "one does", "false": "none does"},
        "targets": ["reply", "prose", "code"],
    },
    "density": {
        "type": "score",
        "instructions": "How much does each sentence carry?",
        "levels": ["sparse", "even", "dense"],
        "targets": ["reply"],
    },
}


def stub_answer(question: dict, value) -> dict:
    """A System One answer to one question: a noul with probability VALUE (0.5 when None),
    or a score whose level probabilities are VALUE (uniform when None), shaped as qev
    answers it."""
    if question["type"] == "score":
        n = len(question["criteria"])
        probs = value or [1 / n] * n
        return {
            "type": "score",
            "score": sum(i * p for i, p in enumerate(probs)),
            "legend": {str(i): level for i, level in enumerate(question["criteria"])},
            "probabilities": {str(i): p for i, p in enumerate(probs)},
            "confidence": max(probs),
        }
    return {"type": "noul", "noul": 0.5 if value is None else value}


class Stub:
    """A System One server that records each request and answers with a fixed status."""

    def __init__(self, status: int = 200, answers: dict | None = None):
        self.requests: list[dict] = []
        stub = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                stub.requests.append({"path": self.path, "auth": self.headers.get("Authorization"), "body": body})
                if status != 200:
                    self.send_response(status)
                    self.end_headers()
                    return
                given = answers or {}
                out = json.dumps(
                    {
                        "model": body["model"],
                        "answers": {name: stub_answer(q, given.get(name)) for name, q in body["questions"].items()},
                        "usage": {"input_tokens": 1, "output_tokens": 0},
                    }
                ).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(out)))
                self.end_headers()
                self.wfile.write(out)

            def log_message(self, format, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def closed_port_url() -> str:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    return f"http://127.0.0.1:{port}"


def endpoint(name: str, url: str, **extra) -> dict:
    return {"name": name, "url": url, "model": f"{name}-model", "apiKeyFile": None, "timeout": 5, **extra}


class JudgeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.stubs: list[Stub] = []

    def tearDown(self):
        for stub in self.stubs:
            stub.close()

    def stub(self, **kwargs) -> Stub:
        stub = Stub(**kwargs)
        self.stubs.append(stub)
        return stub

    def run_cli(self, endpoints: list[dict], text: str, *args: str, dimensions=DIMENSIONS, max_chars=1000):
        config = self.tmp / "config.json"
        config.write_text(json.dumps({"endpoints": endpoints, "dimensions": dimensions, "maxChars": max_chars}))
        env = dict(os.environ)
        env["PYTHONPATH"] = os.pathsep.join([str(SRC), env.get("PYTHONPATH", "")])
        env.pop("http_proxy", None)
        env.pop("HTTP_PROXY", None)
        return subprocess.run(
            [sys.executable, "-m", "claude_response_judge.cli", "--config", str(config), *args],
            input=text,
            capture_output=True,
            text=True,
            env=env,
            timeout=30,
            check=False,
        )

    def test_request_shape_and_verdict(self):
        stub = self.stub(answers={"fragments": 0.93, "never": 0.04, "ghosts": 0.5, "density": [0.1, 0.25, 0.65]})
        res = self.run_cli([endpoint("local", stub.url)], "Build green, pushed.\n```\nnever = 1\n```\nDone `x`.")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(
            json.loads(res.stdout),
            {
                "endpoint": "local",
                "model": "local-model",
                "answers": {"fragments": 0.93, "never": 0.04, "ghosts": 0.5},
                "scores": {"density": {"score": 1.55, "levels": 3, "level": "dense", "p": 0.65}},
            },
        )
        [req] = stub.requests
        self.assertEqual(req["path"], "/v1/systemone")
        self.assertIsNone(req["auth"])
        body = req["body"]
        self.assertNotIn("replaced text", body["state"])
        self.assertEqual(body["model"], "local-model")
        # Code blocks are replaced, inline spans kept.
        self.assertEqual(body["state"]["text"], "Build green, pushed.\n[code block]\nDone `x`.")
        self.assertIn("reply", body["state"]["kind"])
        self.assertEqual(
            body["questions"]["never"],
            {"type": "noul", "instructions": "Is never used as emphasis?", "criteria": {"true": "it is", "false": "it is not"}},
        )
        self.assertEqual(
            body["questions"]["density"],
            {"type": "score", "instructions": "How much does each sentence carry?", "criteria": ["sparse", "even", "dense"]},
        )

    def test_transcript_gives_the_latest_typed_messages(self):
        stub = self.stub()
        transcript = self.tmp / "session.jsonl"
        entries = [
            {"type": "user", "message": {"role": "user", "content": "first"}},
            {"type": "user", "message": {"role": "user", "content": "use the registry"}},
            {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "ok"}]}},
            {"type": "user", "message": {"content": [{"type": "tool_result", "content": "output"}]}},
            {"type": "user", "isMeta": True, "message": {"content": "Stop hook feedback:\ntic-check: check"}},
            {"type": "user", "isSidechain": True, "message": {"content": "a subagent prompt"}},
            {
                "type": "user",
                "message": {"content": [{"type": "text", "text": "<system-reminder>x</system-reminder>no path refs"}]},
            },
            {"type": "user", "message": {"content": "do not keep packages"}},
        ]
        transcript.write_text("\n".join(json.dumps(e) for e in entries) + "\nnot json\n")
        res = self.run_cli(
            [endpoint("local", stub.url)], "x = 1", "--kind", "code", "--transcript", str(transcript)
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        [conversation] = [v for k, v in stub.requests[0]["body"]["state"].items() if "latest messages" in k]
        self.assertEqual(conversation, ["use the registry", "no path refs", "do not keep packages"])
        # A missing transcript costs the context, not the verdict.
        res = self.run_cli([endpoint("local", stub.url)], "x", "--transcript", str(self.tmp / "absent"))
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertFalse(any("latest messages" in k for k in stub.requests[1]["body"]["state"]))

    def test_prose_kind_and_truncation(self):
        stub = self.stub()
        res = self.run_cli([endpoint("local", stub.url)], "x" * 50, "--kind", "prose", max_chars=10)
        self.assertEqual(res.returncode, 0, res.stderr)
        state = stub.requests[0]["body"]["state"]
        self.assertIn("prose file", state["kind"])
        self.assertEqual(state["text"], "x" * 10 + "\n[text cut here]")

    def test_code_kind_asks_its_dimensions_with_the_replaced_text(self):
        stub = self.stub()
        old = self.tmp / "old"
        old.write_text("pkg = pkgs.nix;\n```\nkept\n```\n")
        text = "# pkg is not set here.\n```\nkept\n```\n"
        res = self.run_cli([endpoint("local", stub.url)], text, "--kind", "code", "--replaced", str(old))
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(json.loads(res.stdout)["answers"], {"ghosts": 0.5})
        self.assertEqual(json.loads(res.stdout)["scores"], {})
        body = stub.requests[0]["body"]
        self.assertEqual(list(body["questions"]), ["ghosts"])
        # Code is the text in a code file, fences included.
        self.assertEqual(body["state"]["text"], text)
        self.assertEqual(body["state"]["replaced text"], old.read_text())
        self.assertIn("source file", body["state"]["kind"])

    def test_refused_local_falls_through_to_cloud_with_key(self):
        cloud = self.stub()
        key = self.tmp / "key"
        key.write_text("secret-value\n")
        res = self.run_cli(
            [endpoint("local", closed_port_url()), endpoint("baseten", cloud.url, apiKeyFile=str(key))],
            "hello",
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(json.loads(res.stdout)["endpoint"], "baseten")
        self.assertEqual(cloud.requests[0]["auth"], "Api-Key secret-value")
        self.assertIn("local:", res.stderr)

    def test_http_error_moves_on(self):
        bad, good = self.stub(status=422), self.stub()
        res = self.run_cli([endpoint("local", bad.url), endpoint("cloud", good.url)], "hello")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(json.loads(res.stdout)["endpoint"], "cloud")
        self.assertEqual(len(bad.requests), 1)

    def test_missing_key_file_skips_endpoint(self):
        cloud, local = self.stub(), self.stub()
        res = self.run_cli(
            [endpoint("baseten", cloud.url, apiKeyFile=str(self.tmp / "absent")), endpoint("local", local.url)],
            "hello",
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(json.loads(res.stdout)["endpoint"], "local")
        self.assertEqual(cloud.requests, [])

    def test_all_fail(self):
        res = self.run_cli([endpoint("local", closed_port_url())], "hello")
        self.assertEqual(res.returncode, 1)
        self.assertEqual(res.stdout, "")
        self.assertIn("local:", res.stderr)

    def test_nothing_enabled(self):
        res = self.run_cli([], "hello")
        self.assertEqual(res.returncode, 1)
        self.assertIn("no endpoints", res.stderr)
        stub = self.stub()
        res = self.run_cli([endpoint("local", stub.url)], "hello", dimensions={})
        self.assertEqual(res.returncode, 1)
        self.assertIn("no enabled dimension targets reply", res.stderr)
        prose_only = {name: dim for name, dim in DIMENSIONS.items() if "code" not in dim["targets"]}
        res = self.run_cli([endpoint("local", stub.url)], "x = 1", "--kind", "code", dimensions=prose_only)
        self.assertEqual(res.returncode, 1)
        self.assertIn("no enabled dimension targets code", res.stderr)
        self.assertEqual(stub.requests, [])


if __name__ == "__main__":
    unittest.main()
