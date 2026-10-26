# SPDX-License-Identifier: MIT
"""claude-ghost-check: which sentences of a write are candidates, and the command line end to
end against a stub System One server: a candidate is asked about with the replaced text and
the user's messages beside it, the answer sets its action, and with no endpoint answering the
result is empty."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from test_cli import Stub, closed_port_url, endpoint

SRC = Path(__file__).resolve().parents[1] / "src"
sys.path.insert(0, str(SRC))

from claude_response_judge.ghosts import candidates  # noqa: E402


class CandidatesTest(unittest.TestCase):
    def test_a_negation_about_what_the_user_said(self):
        found = candidates(
            "A registration joins the registry beneath. The registry of this configuration is unchanged.",
            ["it should not apply to this configuration"],
        )
        self.assertEqual(found, [{"sentence": "The registry of this configuration is unchanged.", "source": "negation"}])

    def test_a_negation_with_nothing_to_answer(self):
        # A limit stated for its own sake shares no word with what the user said.
        self.assertEqual(candidates("The parser does not follow symlinks.", ["add a lexer"]), [])

    def test_narration(self):
        found = candidates("FINAL SHAPE after two corrections from the user: core is a symlink.", [])
        self.assertEqual([c["source"] for c in found], ["narration"])

    def test_code_blocks_are_not_sentences(self):
        self.assertEqual(candidates("Run it:\n```\nnot unchanged\n```\n", ["unchanged"]), [])


class CommandTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.stubs = []

    def tearDown(self):
        for stub in self.stubs:
            stub.close()

    def run_check(self, new, replaced, endpoints, said="the registry should not change"):
        config = self.tmp / "config.json"
        config.write_text(json.dumps({"endpoints": endpoints, "ghosts": {"pushBackAbove": 0.6, "reportAbove": 0.4}}))
        old = self.tmp / "old.txt"
        old.write_text(replaced)
        args = [sys.executable, "-m", "claude_response_judge.ghosts", "--config", str(config), "--replaced", str(old)]
        transcript = self.tmp / "t.jsonl"
        transcript.write_text(json.dumps({"type": "user", "message": {"role": "user", "content": said}}) + "\n")
        args += ["--transcript", str(transcript)]
        env = dict(os.environ, PYTHONPATH=str(SRC))
        env.pop("http_proxy", None)
        env.pop("HTTP_PROXY", None)
        res = subprocess.run(args, input=new, capture_output=True, text=True, env=env, timeout=30, check=False)
        self.assertEqual(res.returncode, 0, res.stderr)
        return json.loads(res.stdout)

    def test_asks_about_each_candidate(self):
        stub = Stub(answers={"ghost-sentence": 0.7})
        self.stubs.append(stub)
        out = self.run_check(
            "The result is JSON. caisson publishes nothing under packages.",
            "The result is published as packages.<system>.<name>.",
            [endpoint("local", stub.url)],
            said="it should not publish packages",
        )
        self.assertEqual(out["endpoint"], "local")
        self.assertEqual(
            out["sentences"],
            [{"sentence": "caisson publishes nothing under packages.", "source": "negation", "p": 0.7, "action": "block"}],
        )
        [req] = stub.requests
        state = req["body"]["state"]
        self.assertEqual(state["the sentence"], "caisson publishes nothing under packages.")
        self.assertEqual(state["replaced text"], "The result is published as packages.<system>.<name>.")
        self.assertEqual(state["the user's latest messages (context)"], ["it should not publish packages"])
        self.assertEqual(list(req["body"]["questions"]), ["ghost-sentence"])

    def test_report_and_none(self):
        for p, action in ((0.5, "report"), (0.2, "none")):
            stub = Stub(answers={"ghost-sentence": p})
            self.stubs.append(stub)
            out = self.run_check("The registry is unchanged.", "The registry applies, not here.", [endpoint("local", stub.url)])
            self.assertEqual([s["action"] for s in out["sentences"]], [action])

    def test_no_candidate_asks_nothing(self):
        stub = Stub(answers={"ghost-sentence": 0.9})
        self.stubs.append(stub)
        out = self.run_check("The parser reads every line.", "The parser reads lines.", [endpoint("local", stub.url)])
        self.assertEqual(out, {"endpoint": None, "sentences": []})
        self.assertEqual(stub.requests, [])

    def test_no_endpoint(self):
        out = self.run_check("The registry is unchanged.", "The registry applies, not here.", [endpoint("local", closed_port_url())])
        self.assertEqual(out, {"endpoint": None, "sentences": []})


if __name__ == "__main__":
    unittest.main()
