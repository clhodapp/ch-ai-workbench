# SPDX-License-Identifier: MIT
"""claude-turn-load: prose word counting, the opening prompt of a turn (typed, or a task
notification counted as no request), the score formula, and the command line; and the split
between turn inputs and typed prompts it relies on."""

from __future__ import annotations

import json
import math
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "src"
sys.path.insert(0, str(SRC))

from claude_response_judge.cli import turn_input, typed_prompt
from claude_response_judge.load import ask_words, load_score, prose_words
from claude_response_judge.turn import earlier_messages


def human(text):
    return {"type": "user", "origin": {"kind": "human"}, "message": {"role": "user", "content": text}}


def notification(text):
    return {"type": "user", "origin": {"kind": "task-notification"}, "message": {"content": text}}


def say(text, tool=False):
    blocks = [{"type": "text", "text": text}]
    if tool:
        blocks.append({"type": "tool_use", "id": "t", "name": "Bash", "input": {}})
    return {"type": "assistant", "message": {"role": "assistant", "content": blocks}}


class LoadTest(unittest.TestCase):
    def test_prose_words(self):
        text = "One two three.\n```\ncode is not prose\n```\nUse `a b c` here.\nresult: done in one line"
        self.assertEqual(prose_words(text), 6)

    def test_typed_prompt_and_turn_input(self):
        self.assertEqual(typed_prompt(human("fix it")), "fix it")
        self.assertEqual(typed_prompt({"type": "user", "message": {"content": "no origin"}}), "no origin")
        self.assertIsNone(typed_prompt(notification("<task-notification>done</task-notification>")))
        self.assertEqual(turn_input(notification("done")), "done")

    def test_ask_words(self):
        self.assertEqual(ask_words([human("please fix the parser now"), say("ok", tool=True)]), 5)
        self.assertEqual(ask_words([human("please fix the parser now"), notification("done")]), 0)
        self.assertEqual(ask_words([]), 0)

    def test_a_notification_starts_a_turn(self):
        entries = [human("go"), say("Working.", tool=True), notification("done"), say("Finished.")]
        self.assertEqual(earlier_messages(entries), ["Finished."])

    def test_score(self):
        self.assertAlmostEqual(load_score(200, 2.2, 0), math.log(201) + 2.2 - 0.25 * math.log(8))
        self.assertGreater(load_score(400, 2.2, 0), load_score(400, 2.2, 50))
        self.assertGreater(load_score(200, 2.5, 10), load_score(200, 2.0, 10))

    def test_cli(self):
        env = dict(os.environ, PYTHONPATH=str(SRC))
        with tempfile.TemporaryDirectory() as tmp:
            transcript = Path(tmp, "t.jsonl")
            transcript.write_text("\n".join(json.dumps(e) for e in [human("one two three"), say("x", tool=True)]) + "\n")
            res = subprocess.run(
                [sys.executable, "-m", "claude_response_judge.load", "--density", "2", "--transcript", str(transcript)],
                input="four words of prose",
                capture_output=True,
                text=True,
                env=env,
                check=False,
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            out = json.loads(res.stdout)
            self.assertEqual((out["words"], out["ask_words"]), (4, 3))
            self.assertAlmostEqual(out["score"], round(load_score(4, 2, 3), 3))


if __name__ == "__main__":
    unittest.main()
