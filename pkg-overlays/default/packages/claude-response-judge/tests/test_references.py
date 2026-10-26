# SPDX-License-Identifier: MIT
"""claude-reference-check end to end, through the command line in a subprocess: synthetic
transcripts and a session index in a temp directory, and a stub System One server on
loopback whose answers depend on the candidate it is asked about."""

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


class Stub:
    """A System One server that answers each request with ANSWER(candidate), a pair of
    (P(resolvable), P(presupposed)), and records the states it was sent."""

    def __init__(self, answer):
        self.states: list[dict] = []
        stub = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                stub.states.append(body["state"])
                resolvable, presupposed = answer(body["state"]["candidate"])
                out = json.dumps(
                    {
                        "model": body["model"],
                        "answers": {
                            "reference-resolvable": {"type": "noul", "noul": resolvable},
                            "reference-presupposed": {"type": "noul", "noul": presupposed},
                        },
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


def user(text: str) -> dict:
    return {"type": "user", "message": {"role": "user", "content": text}}


def assistant(text: str) -> dict:
    return {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}


def tool(command: str, output: str) -> list[dict]:
    return [
        {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Bash", "input": {"command": command}}]}},
        {"type": "user", "message": {"content": [{"type": "tool_result", "content": output}]}},
    ]


class ReferenceCheckTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.projects = self.tmp / "projects"
        self.projects.mkdir()
        self.index = self.tmp / "index.json"
        self.stubs: list[Stub] = []
        self.write_index({})

    def tearDown(self):
        for stub in self.stubs:
            stub.close()

    def stub(self, answer) -> Stub:
        stub = Stub(answer)
        self.stubs.append(stub)
        return stub

    def write_index(self, user_words=(), assistant_words=(), assistant_phrases=()):
        entry = {
            "offset": 0,
            "started": "2026-01-01T00:00:00Z",
            "user_words": sorted(user_words),
            "assistant_words": sorted(assistant_words),
            "assistant_phrases": sorted(assistant_phrases),
        }
        self.index.write_text(json.dumps({"version": 1, "sessions": {str(self.tmp / "older.jsonl"): entry}}))

    def run_check(self, entries: list[dict], final: str, url: str | None = None, **references) -> dict:
        transcript = self.tmp / "session.jsonl"
        # The final message is in the transcript already, as it often is when the Stop hook runs.
        transcript.write_text("\n".join(json.dumps(e) for e in entries + [assistant(final)]) + "\n")
        endpoints = [{"name": "local", "url": url, "model": "elephant-1", "apiKeyFile": None, "timeout": 5}] if url else []
        config = self.tmp / "config.json"
        config.write_text(json.dumps({"endpoints": endpoints, "references": references}))
        env = dict(os.environ)
        env["PYTHONPATH"] = os.pathsep.join([str(SRC), env.get("PYTHONPATH", "")])
        env.pop("http_proxy", None)
        env.pop("HTTP_PROXY", None)
        res = subprocess.run(
            [
                sys.executable, "-m", "claude_response_judge.references",
                "--config", str(config), "--transcript", str(transcript),
                "--index", str(self.index), "--projects", str(self.projects),
            ],
            input=final,
            capture_output=True,
            text=True,
            env=env,
            timeout=30,
            check=False,
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        return json.loads(res.stdout)

    def test_definite_reference_to_tool_output_is_flagged(self):
        entries = [user("record the lockfile"), *tool("nix build .#deps", "starting the recording proxy on :8080")]
        out = self.run_check(entries, "The lockfile failed because the recording proxy bypasses the sandbox.")
        self.assertEqual(
            out["flags"],
            [
                {
                    "reference": "the recording proxy",
                    "sentence": "The lockfile failed because the recording proxy bypasses the sandbox.",
                    "source": "definite",
                    "p": None,
                }
            ],
        )
        self.assertIsNone(out["endpoint"])
        self.assertFalse(out["block"])

    def test_anchored_references_do_not_fire(self):
        entries = [user("record the lockfile"), assistant("I'll start a recording proxy for Maven first.")]
        # Shown before, and with an antecedent earlier in the same message.
        final = "The recording proxy is up. A polkit rule lets you start it, and the polkit rule covers one unit only."
        self.assertEqual(self.run_check(entries, final)["flags"], [])
        # A phrase the assistant showed the user in an earlier session.
        self.write_index(assistant_phrases={"ownership rule"})
        self.assertEqual(self.run_check([user("go on")], "This follows the ownership rule.")["flags"], [])

    def test_tool_only_names_go_to_the_judge(self):
        stub = self.stub(lambda c: (0.1, 0.9) if c == "pwndbgArgs" else (0.9, 0.2))
        entries = [
            user("package the tools"),
            *tool("edit default.nix", "pwndbgArgs = null; wrapper uses cecSync"),
            user("continue"),
        ]
        final = "`pwndbgArgs` is still undefined, and `cecSync` picked it up."
        out = self.run_check(entries, final, stub.url)
        self.assertEqual(out["endpoint"], "local")
        self.assertEqual(
            out["flags"], [{"reference": "pwndbgArgs", "sentence": "`pwndbgArgs` is still undefined, and `cecSync` picked it up.",
                            "source": "tool-only", "p": 0.81}]
        )
        self.assertEqual([s["candidate"] for s in stub.states], ["pwndbgArgs", "cecSync"])
        state = stub.states[0]
        self.assertEqual(state["user_messages"], ["package the tools", "continue"])
        self.assertEqual(state["reader_saw"], ["nothing"])
        self.assertEqual(state["text"], final)

    def test_lexicon_and_shown_text_gate_the_judge(self):
        stub = self.stub(lambda c: (0.0, 1.0))
        entries = [user("check pwndbgArgs please"), *tool("grep", "pwndbgArgs cecSync")]
        self.write_index(user_words={"cecsync"})
        out = self.run_check(entries, "`pwndbgArgs` and `cecSync` are set.", stub.url)
        # The user typed one name in this session and the other in an earlier one.
        self.assertEqual(out["flags"], [])
        self.assertEqual(stub.states, [])

    def test_block_count(self):
        entries = [user("go on"), *tool("x", "y")]
        final = "Their notes disagree, and the documentation agent missed it."
        out = self.run_check(entries, final)
        self.assertEqual([f["reference"] for f in out["flags"]], ["Their notes", "the documentation agent"])
        self.assertTrue(out["block"])
        self.assertFalse(self.run_check(entries, final, blockAtFlags=3)["block"])

    def test_no_endpoint_flags_definite_references_only(self):
        entries = [user("go on"), *tool("edit", "pwndbgArgs = null")]
        out = self.run_check(entries, "`pwndbgArgs` is unset, as the recording proxy showed.", closed_port_url())
        self.assertIsNone(out["endpoint"])
        self.assertEqual([(f["reference"], f["source"]) for f in out["flags"]], [("the recording proxy", "definite")])

    def test_unreadable_input_still_answers(self):
        transcript_missing = self.tmp / "absent.jsonl"
        config = self.tmp / "config.json"
        config.write_text("{}")
        env = dict(os.environ, PYTHONPATH=str(SRC))
        res = subprocess.run(
            [sys.executable, "-m", "claude_response_judge.references", "--config", str(config),
             "--transcript", str(transcript_missing), "--index", str(self.index), "--projects", str(self.projects)],
            input="the recording proxy failed", capture_output=True, text=True, env=env, timeout=30, check=False,
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(json.loads(res.stdout)["block"], False)


if __name__ == "__main__":
    unittest.main()
