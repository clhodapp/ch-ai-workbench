# SPDX-License-Identifier: MIT
"""claude-session-index: what an entry records from a transcript (typed words, assistant
prose words and "the" phrases, the start time), reading only the lines appended since the
last update, sessions that started earlier, and the command line."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "src"
sys.path.insert(0, str(SRC))

from claude_response_judge import sessions


def line(entry):
    return json.dumps(entry, separators=(",", ":")) + "\n"


def human(text, ts):
    return {"type": "user", "timestamp": ts, "origin": {"kind": "human"}, "message": {"content": text}}


def say(text, ts):
    return {"type": "assistant", "timestamp": ts, "message": {"content": [{"type": "text", "text": text}]}}


class SessionsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.projects = self.tmp / "projects"
        (self.projects / "p").mkdir(parents=True)
        self.index = self.tmp / "cache" / "index.json"

    def transcript(self, name, *entries):
        path = self.projects / "p" / f"{name}.jsonl"
        with path.open("a") as f:
            for e in entries:
                f.write(line(e))
        return path

    def test_entry_contents(self):
        path = self.transcript(
            "a",
            human("Fix the Parser please", "2026-10-01T00:00:00Z"),
            say("The judge reads `the code span` and\n```\nthe fence\n```\nthe ladder too.", "2026-10-01T00:01:00Z"),
            {"type": "user", "message": {"content": [{"type": "tool_result", "content": "the tool output"}]}},
        )
        self.assertEqual(sessions.update(self.projects, self.index), 1)
        e = sessions.load(self.index)["sessions"][str(path)]
        self.assertEqual(e["started"], "2026-10-01T00:00:00Z")
        self.assertIn("parser", e["user_words"])
        self.assertIn("judge", e["assistant_words"])
        self.assertNotIn("fence", e["assistant_words"])
        self.assertNotIn("output", e["assistant_words"] + e["user_words"])
        self.assertTrue({"judge", "judge reads", "ladder"} <= set(e["assistant_phrases"]))
        self.assertNotIn("code", " ".join(e["assistant_phrases"]))

    def test_incremental(self):
        path = self.transcript("a", human("one", "2026-10-01T00:00:00Z"))
        sessions.update(self.projects, self.index)
        self.assertEqual(sessions.update(self.projects, self.index), 0)
        # A half-written line is left for the next update.
        with path.open("a") as f:
            f.write(line(say("the extractor", "2026-10-01T00:02:00Z")) + '{"type":"user"')
        self.assertEqual(sessions.update(self.projects, self.index), 1)
        e = sessions.load(self.index)["sessions"][str(path)]
        self.assertIn("extractor", e["assistant_phrases"])
        self.assertEqual(e["offset"], path.stat().st_size - len('{"type":"user"'))
        self.assertEqual(e["user_words"], ["one"])

    def test_earlier(self):
        a = self.transcript("a", human("first", "2026-10-01T00:00:00Z"))
        b = self.transcript("b", human("second", "2026-10-02T00:00:00Z"))
        c = self.transcript("c", human("third", "2026-10-03T00:00:00Z"))
        sessions.update(self.projects, self.index)
        data = sessions.load(self.index)
        self.assertEqual([e["user_words"] for e in sessions.earlier(data, b)], [["first"]])
        self.assertEqual(len(sessions.earlier(data, c)), 2)
        self.assertEqual(len(sessions.earlier(data, self.projects / "p" / "unknown.jsonl")), 3)
        self.assertEqual(sessions.earlier(data, a), [])

    def test_unreadable_index_is_empty(self):
        self.index.parent.mkdir(parents=True)
        self.index.write_text("not json")
        self.assertEqual(sessions.load(self.index)["sessions"], {})

    def test_cli(self):
        self.transcript("a", human("hello", "2026-10-01T00:00:00Z"))
        env = dict(os.environ, PYTHONPATH=str(SRC))
        res = subprocess.run(
            [sys.executable, "-m", "claude_response_judge.sessions", "update", "--projects", str(self.projects), "--index", str(self.index)],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("1 transcripts read", res.stderr)
        self.assertEqual(len(sessions.load(self.index)["sessions"]), 1)


if __name__ == "__main__":
    unittest.main()
