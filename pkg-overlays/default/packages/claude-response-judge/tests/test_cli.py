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
        "instructions": "Does the prose drop subjects or verbs?",
        "criteria": {"true": "it does", "false": "it does not"},
    },
    "never": {
        "instructions": "Is never used as emphasis?",
        "criteria": {"true": "it is", "false": "it is not"},
    },
}


class Stub:
    """A System One server that records each request and answers with a fixed status."""

    def __init__(self, status: int = 200, answers: dict[str, float] | None = None):
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
                probs = answers or {name: 0.5 for name in body["questions"]}
                out = json.dumps(
                    {
                        "model": body["model"],
                        "answers": {name: {"type": "noul", "noul": probs[name]} for name in body["questions"]},
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
        stub = self.stub(answers={"fragments": 0.93, "never": 0.04})
        res = self.run_cli([endpoint("local", stub.url)], "Build green, pushed.\n```\nnever = 1\n```\nDone `x`.")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(
            json.loads(res.stdout),
            {"endpoint": "local", "model": "local-model", "answers": {"fragments": 0.93, "never": 0.04}},
        )
        [req] = stub.requests
        self.assertEqual(req["path"], "/v1/systemone")
        self.assertIsNone(req["auth"])
        body = req["body"]
        self.assertEqual(body["model"], "local-model")
        # Code blocks are replaced, inline spans kept.
        self.assertEqual(body["state"]["text"], "Build green, pushed.\n[code block]\nDone `x`.")
        self.assertIn("reply", body["state"]["kind"])
        self.assertEqual(
            body["questions"]["never"],
            {"type": "noul", "instructions": "Is never used as emphasis?", "criteria": {"true": "it is", "false": "it is not"}},
        )

    def test_edit_kind_and_truncation(self):
        stub = self.stub()
        res = self.run_cli([endpoint("local", stub.url)], "x" * 50, "--kind", "edit", max_chars=10)
        self.assertEqual(res.returncode, 0, res.stderr)
        state = stub.requests[0]["body"]["state"]
        self.assertIn("prose file", state["kind"])
        self.assertEqual(state["text"], "x" * 10 + "\n[text cut here]")

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
        self.assertIn("no dimensions", res.stderr)
        self.assertEqual(stub.requests, [])


if __name__ == "__main__":
    unittest.main()
