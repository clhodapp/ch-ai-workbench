# SPDX-License-Identifier: MIT
"""claude-familiarity-check: which strings of a write are candidates, and the command line end
to end against a stub System One server: each candidate gets the two questions, a candidate at
the conversation level without a description is a block, a description exonerates it, and
with no endpoint answering the result is empty."""

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

from claude_response_judge.familiarity import candidates  # noqa: E402

CHAT = [0.05, 0.05, 0.1, 0.8]
CODEBASE = [0.1, 0.1, 0.7, 0.1]


class CandidatesTest(unittest.TestCase):
    def test_work_phrases_come_first(self):
        found = candidates("docs: rewrite the `lib.md` passages a phrasing review flagged", "")
        self.assertEqual(found[0], "a phrasing review")
        self.assertIn("lib.md", found)

    def test_counts_and_numbered_items(self):
        found = candidates("This is item 4 of the plan; 29 of 29 pass.", "")
        self.assertIn("item 4", found)
        self.assertIn("29 of 29", found)

    def test_what_the_file_already_had_is_left_out(self):
        self.assertNotIn("mkLib", candidates("`mkLib` takes `pkgSets`.", "`mkLib` takes `inputs`."))

    def test_the_attribution_trailer_is_left_out(self):
        found = candidates("fix: a thing\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>", "")
        self.assertFalse({"co-authored-by", "anthropic.com"} & {c.lower() for c in found})


class CommandTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.stubs = []

    def tearDown(self):
        for stub in self.stubs:
            stub.close()

    def stub(self, **kwargs):
        stub = Stub(**kwargs)
        self.stubs.append(stub)
        return stub

    def run_check(self, text, endpoints, kind="message"):
        config = self.tmp / "config.json"
        config.write_text(json.dumps({"endpoints": endpoints, "familiarity": {"pushBackAbove": 0.7, "reportAbove": 0.4, "describedBelow": 0.8}}))
        env = dict(os.environ, PYTHONPATH=str(SRC))
        env.pop("http_proxy", None)
        env.pop("HTTP_PROXY", None)
        res = subprocess.run(
            [sys.executable, "-m", "claude_response_judge.familiarity", "--config", str(config), "--kind", kind],
            input=text, capture_output=True, text=True, env=env, timeout=30, check=False,
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        return json.loads(res.stdout)

    def test_a_conversation_reference_without_a_description_blocks(self):
        stub = self.stub(answers={"familiarity": CHAT, "described": 0.2})
        out = self.run_check("docs: rewrite the passages a phrasing review flagged", [endpoint("local", stub.url)])
        self.assertEqual(out["endpoint"], "local")
        self.assertEqual(out["candidates"], [{"candidate": "a phrasing review", "chat": 0.8, "described": 0.2, "action": "block"}])
        [req] = stub.requests
        self.assertEqual(set(req["body"]["questions"]), {"familiarity", "described"})
        self.assertEqual(req["body"]["state"]["candidate"], "a phrasing review")
        self.assertIn("commit message", req["body"]["state"]["kind"])

    def test_a_brief_description_exonerates(self):
        stub = self.stub(answers={"familiarity": CHAT, "described": 0.9})
        out = self.run_check("docs: rewrite the passages a phrasing review flagged", [endpoint("local", stub.url)])
        self.assertEqual([c["action"] for c in out["candidates"]], ["none"])

    def test_the_codebase_level_is_allowed(self):
        stub = self.stub(answers={"familiarity": CODEBASE, "described": 0.1})
        out = self.run_check("fix: `mkLib` takes `pkgSets`", [endpoint("local", stub.url)], kind="prose")
        self.assertEqual({c["action"] for c in out["candidates"]}, {"none"})

    def test_no_endpoint(self):
        out = self.run_check("docs: rewrite what a phrasing review flagged", [endpoint("local", closed_port_url())])
        self.assertEqual(out, {"endpoint": None, "candidates": []})


if __name__ == "__main__":
    unittest.main()
