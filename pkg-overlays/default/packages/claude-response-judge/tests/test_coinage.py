# SPDX-License-Identifier: MIT
"""claude-coinage-check end to end, through the command line in a subprocess, on synthetic
transcripts with a session index in a temp directory and a stub System One server: a phrase
fires at its second use, the user's words and phrases common in earlier sessions are not
candidates, a phrase is judged once per session, a durable write counts as a use, and with
no endpoint answering the result is empty."""

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

from claude_response_judge import sessions  # noqa: E402
from claude_response_judge.coinage import DEFAULT_INSTRUCTIONS, DEFAULT_LEVELS, occurrences  # noqa: E402

COINAGE = {
    "instructions": DEFAULT_INSTRUCTIONS,
    "levels": DEFAULT_LEVELS,
    "pushBackAbove": 1.4,
    "writePushBackAbove": 1.2,
    "reportAbove": 1.0,
}
MIDDLING = {"name-opacity": [0.0, 0.7, 0.3]}  # expected level 1.3
OPAQUE = {"name-opacity": [0.05, 0.15, 0.8]}  # expected level 1.75


def prompt(text, ts="2026-10-20T10:00:00Z"):
    return {"type": "user", "timestamp": ts, "message": {"role": "user", "content": text}}


def say(text, ts="2026-10-20T10:00:01Z"):
    return {"type": "assistant", "timestamp": ts, "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}


def tool_use():
    return {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t", "name": "Bash", "input": {}}]}}


class CoinageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.projects = self.tmp / "projects"
        (self.projects / "p").mkdir(parents=True)
        self.index = self.tmp / "index.json"
        self.runtime = self.tmp / "run"
        self.runtime.mkdir()
        self.stubs = []

    def tearDown(self):
        for stub in self.stubs:
            stub.close()

    def stub(self, **kwargs):
        stub = Stub(**kwargs)
        self.stubs.append(stub)
        return stub

    def session(self, name, entries):
        path = self.projects / "p" / f"{name}.jsonl"
        # Compact, as Claude Code writes them: the index finds entries by '"type":"user"'.
        path.write_text("".join(json.dumps(e, separators=(",", ":")) + "\n" for e in entries))
        return path

    def other_session(self, name, assistant, user="ok", ts="2026-10-01T00:00:00Z"):
        return self.session(name, [prompt(user, ts), say(assistant, ts)])

    def run_check(self, transcript, stdin, *args, endpoints, runtime=True):
        sessions.update(self.projects, self.index)
        config = self.tmp / "config.json"
        config.write_text(json.dumps({"endpoints": endpoints, "dimensions": {}, "maxChars": 1000, "coinage": COINAGE}))
        env = dict(os.environ)
        env["PYTHONPATH"] = os.pathsep.join([str(SRC), env.get("PYTHONPATH", "")])
        env.pop("http_proxy", None)
        env.pop("HTTP_PROXY", None)
        env.pop("XDG_RUNTIME_DIR", None)
        if runtime:
            env["XDG_RUNTIME_DIR"] = str(self.runtime)
        res = subprocess.run(
            [
                sys.executable, "-m", "claude_response_judge.coinage",
                "--config", str(config), "--transcript", str(transcript),
                "--index", str(self.index), "--projects", str(self.projects), *args,
            ],
            input=stdin, capture_output=True, text=True, env=env, timeout=30, check=False,
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        return json.loads(res.stdout)

    def current(self, *extra):
        """A session that used "the ladder" once before the user's latest prompt."""
        return self.session(
            "current",
            [
                prompt("score the replies for readability"),
                say("The scores share one scale, `lib/judge-ladder.nix`. The ladder has four levels."),
                prompt("how does it look"),
                *extra,
            ],
        )

    def test_a_contraction_is_not_part_of_a_name(self):
        self.assertEqual(
            [p for p, _ in occurrences("The judge doesn't decide. The judge doesn’t either.")],
            ["judge", "judge"],
        )
        self.assertEqual([p for p, _ in occurrences("The edit hook runs.")], ["edit", "edit hook"])

    def test_second_use_fires_with_the_question_and_state(self):
        stub = self.stub(answers=OPAQUE)
        path = self.current(say("Checking the tarball first."), tool_use())
        out = self.run_check(path, "Each reply sits on the ladder.", endpoints=[endpoint("local", stub.url)])
        self.assertEqual(out["endpoint"], "local")
        [cand] = out["candidates"]
        self.assertEqual(cand["phrase"], "the ladder")
        self.assertEqual(cand["action"], "block")
        self.assertAlmostEqual(cand["score"], 1.75)
        self.assertEqual(cand["real_name"], "lib/judge-ladder.nix")
        self.assertEqual(cand["sentence"], "Each reply sits on the ladder.")
        # "the tarball" is used once, so it is not asked about.
        [req] = stub.requests
        body = req["body"]
        self.assertEqual(
            body["questions"],
            {"name-opacity": {"type": "score", "instructions": DEFAULT_INSTRUCTIONS, "criteria": DEFAULT_LEVELS}},
        )
        state = body["state"]
        self.assertEqual(state["phrase"], "the ladder")
        self.assertEqual(
            state["sentences where the assistant used it, oldest first"],
            ["The ladder has four levels.", "Each reply sits on the ladder."],
        )
        self.assertIn("lib/judge-ladder.nix", state["backticked names the assistant used so far"])
        self.assertEqual(
            state["the user's latest messages to the assistant, oldest first (context)"],
            ["score the replies for readability", "how does it look"],
        )

    def test_report_and_none_levels(self):
        for probs, action in (([0.1, 0.8, 0.1], "report"), ([0.8, 0.2, 0.0], "none")):
            stub = self.stub(answers={"name-opacity": probs})
            path = self.current()
            out = self.run_check(path, "On the ladder.", endpoints=[endpoint("local", stub.url)], runtime=False)
            self.assertEqual([c["action"] for c in out["candidates"]], [action])

    def test_final_message_already_in_the_transcript_counts_once(self):
        stub = self.stub(answers=OPAQUE)
        path = self.session("current", [prompt("go"), say("The ladder has four levels.")])
        out = self.run_check(path, "The ladder has four levels.", endpoints=[endpoint("local", stub.url)])
        self.assertEqual(out["candidates"], [])
        self.assertEqual(stub.requests, [])

    def test_user_word_gate(self):
        stub = self.stub(answers=OPAQUE)
        self.other_session("older", "Fine.", user="the ladders in that diagram are wrong")
        path = self.current()
        out = self.run_check(path, "On the ladder.", endpoints=[endpoint("local", stub.url)])
        self.assertEqual(out["candidates"], [])
        self.assertEqual(stub.requests, [])

    def test_an_accepted_suggestion_does_not_vouch_for_a_phrase(self):
        # A prompt suggestion is generated from the conversation, so sending one that uses
        # the assistant's phrase does not make the phrase the user's word.
        stub = self.stub(answers=OPAQUE)
        for source, expected in (("suggestion_accepted", ["the ladder"]), ("typed", [])):
            ask = {**prompt("show me the ladder levels"), "promptSource": source}
            path = self.session(
                source,
                [prompt("score the replies"), say("The ladder has four levels."), ask],
            )
            out = self.run_check(path, "On the ladder.", endpoints=[endpoint("local", stub.url)], runtime=False)
            self.assertEqual([c["phrase"] for c in out["candidates"]], expected, source)

    def test_rarity_gate_counts_earlier_sessions_only(self):
        stub = self.stub(answers=OPAQUE)
        for i in range(3):
            self.other_session(f"later{i}", "The ladder again.", ts="2026-10-30T00:00:00Z")
        path = self.current()
        out = self.run_check(path, "On the ladder.", endpoints=[endpoint("local", stub.url)], runtime=False)
        self.assertEqual([c["phrase"] for c in out["candidates"]], ["the ladder"])
        for i in range(3):
            self.other_session(f"older{i}", "The ladder again.")
        out = self.run_check(path, "On the ladder.", endpoints=[endpoint("local", stub.url)], runtime=False)
        self.assertEqual(out["candidates"], [])

    def test_once_per_session(self):
        stub = self.stub(answers=OPAQUE)
        path = self.current()
        first = self.run_check(path, "On the ladder.", endpoints=[endpoint("local", stub.url)])
        self.assertEqual(len(first["candidates"]), 1)
        again = self.run_check(path, "Still on the ladder.", endpoints=[endpoint("local", stub.url)])
        self.assertEqual(again["candidates"], [])
        self.assertEqual(len(stub.requests), 1)
        kept = json.loads((self.runtime / "claude-tic-check" / "coinage" / "current.json").read_text())
        self.assertEqual(kept, {"ladder": {"score": 1.75, "action": "block"}})
        # Without XDG_RUNTIME_DIR nothing is kept, so the phrase is judged again.
        self.run_check(path, "Still on the ladder.", endpoints=[endpoint("local", stub.url)], runtime=False)
        self.assertEqual(len(stub.requests), 2)

    def test_write_counts_as_a_use(self):
        stub = self.stub(answers=OPAQUE)
        path = self.session("current", [prompt("go"), say("The ladder has four levels.")])
        out = self.run_check(path, "Memory: the ladder measures familiarity.", "--write", endpoints=[endpoint("local", stub.url)])
        self.assertEqual([c["phrase"] for c in out["candidates"]], ["the ladder"])
        # A phrase the assistant never used in the session is not a coinage of this session.
        out = self.run_check(path, "Memory: the gauge measures it.", "--write", endpoints=[endpoint("local", stub.url)])
        self.assertEqual(out["candidates"], [])

    def test_a_write_blocks_at_the_lower_level(self):
        stub = self.stub(answers=MIDDLING)
        path = self.session("current", [prompt("go"), say("The ladder has four levels.")])
        out = self.run_check(path, "Memory: the ladder measures familiarity.", "--write", endpoints=[endpoint("local", stub.url)], runtime=False)
        self.assertEqual([(c["phrase"], c["action"]) for c in out["candidates"]], [("the ladder", "block")])
        path = self.current()
        out = self.run_check(path, "On the ladder.", endpoints=[endpoint("local", stub.url)], runtime=False)
        self.assertEqual([(c["phrase"], c["action"]) for c in out["candidates"]], [("the ladder", "report")])

    def test_a_write_blocks_a_phrase_a_reply_only_reported(self):
        stub = self.stub(answers=MIDDLING)
        path = self.current()
        out = self.run_check(path, "On the ladder.", endpoints=[endpoint("local", stub.url)])
        self.assertEqual([c["action"] for c in out["candidates"]], ["report"])
        out = self.run_check(path, "Memory: the ladder measures familiarity.", "--write", endpoints=[endpoint("local", stub.url)])
        self.assertEqual([(c["phrase"], c["action"], c["score"]) for c in out["candidates"]], [("the ladder", "block", 1.3)])
        self.assertEqual(len(stub.requests), 1)
        # The block is kept, so the next write with the phrase is not denied again.
        out = self.run_check(path, "Memory: the ladder again.", "--write", endpoints=[endpoint("local", stub.url)])
        self.assertEqual(out["candidates"], [])

    def test_no_endpoint_reports_nothing_and_keeps_nothing(self):
        path = self.current()
        out = self.run_check(path, "On the ladder.", endpoints=[endpoint("local", closed_port_url())])
        self.assertEqual(out, {"endpoint": None, "candidates": []})
        self.assertFalse((self.runtime / "claude-tic-check" / "coinage" / "current.json").exists())
        out = self.run_check(self.tmp / "absent.jsonl", "On the ladder.", endpoints=[endpoint("local", closed_port_url())])
        self.assertEqual(out, {"endpoint": None, "candidates": []})


if __name__ == "__main__":
    unittest.main()
