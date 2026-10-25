# SPDX-License-Identifier: MIT
"""claude-turn-text on transcripts: the turn starts after the last typed prompt, messages
split at tool calls, the final message appears once whether or not the transcript holds it,
the length budget keeps the newest messages, and an unreadable transcript gives the final
message alone."""

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

from claude_response_judge.turn import turn_text


def prompt(text):
    return {"type": "user", "message": {"role": "user", "content": text}}


def say(*blocks):
    content = [{"type": "text", "text": b} if isinstance(b, str) else b for b in blocks]
    return {"type": "assistant", "message": {"role": "assistant", "content": content}}


def tool():
    return {"type": "tool_use", "id": "t", "name": "Bash", "input": {}}


def result():
    return {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t", "content": "ok"}]}}


ENTRIES = [
    prompt("an older prompt"),
    say("an older reply"),
    prompt("fix the parser"),
    say("Reading the parser.", tool()),
    result(),
    {"type": "user", "isMeta": True, "message": {"content": "Stop hook feedback:\ntic-check: check"}},
    say("Found it.", "Fixing the tab case.", tool()),
    result(),
    {"type": "assistant", "isSidechain": True, "message": {"content": [{"type": "text", "text": "a subagent"}]}},
    say("The parser handles tabs now."),
]


class TurnTextTest(unittest.TestCase):
    def test_turn_since_the_last_prompt(self):
        self.assertEqual(
            turn_text("The parser handles tabs now.\n", ENTRIES, 10000),
            "[earlier message of this turn]\nReading the parser.\n\n"
            "[earlier message of this turn]\nFound it.\n\nFixing the tab case.\n\n"
            "[final message]\nThe parser handles tabs now.",
        )

    def test_final_message_not_yet_in_the_transcript(self):
        self.assertEqual(turn_text("Done.", ENTRIES[:-1], 10000).count("[final message]\nDone."), 1)
        self.assertTrue(turn_text("Done.", ENTRIES[:-1], 10000).startswith("[earlier message of this turn]\nReading"))

    def test_single_message_turn(self):
        self.assertEqual(turn_text("Hi.", [prompt("hello"), say("Hi.")], 10000), "[final message]\nHi.")

    def test_budget_keeps_the_newest(self):
        text = turn_text("The parser handles tabs now.", ENTRIES, 120)
        self.assertTrue(text.startswith("[older messages of this turn left out]\n\n[earlier message of this turn]\nFound it."))
        self.assertNotIn("Reading the parser.", text)
        long_final = "x" * 500
        self.assertEqual(turn_text(long_final, ENTRIES, 120), f"[older messages of this turn left out]\n\n[final message]\n{long_final}")

    def test_cli(self):
        env = dict(os.environ, PYTHONPATH=str(SRC))
        with tempfile.TemporaryDirectory() as tmp:
            transcript = Path(tmp, "t.jsonl")
            transcript.write_text("\n".join(json.dumps(e) for e in ENTRIES) + "\n")
            def run(path):
                return subprocess.run(
                    [sys.executable, "-m", "claude_response_judge.turn", "--transcript", str(path)],
                    input="The parser handles tabs now.",
                    capture_output=True,
                    text=True,
                    env=env,
                    check=False,
                )

            res = run(transcript)
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertIn("Found it.", res.stdout)
            res = run(Path(tmp, "absent.jsonl"))
            self.assertEqual((res.returncode, res.stdout), (0, "The parser handles tabs now.\n"))


if __name__ == "__main__":
    unittest.main()
