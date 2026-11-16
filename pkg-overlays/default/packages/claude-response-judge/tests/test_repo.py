# SPDX-License-Identifier: MIT
"""repo.known and repo.session_cwd: a name counts as used when the main branch of the repository
holds it as a whole word, and the working directory comes from the transcript."""

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

from claude_response_judge import repo  # noqa: E402

ENV = dict(
    os.environ,
    GIT_AUTHOR_NAME="t",
    GIT_AUTHOR_EMAIL="t@example.com",
    GIT_COMMITTER_NAME="t",
    GIT_COMMITTER_EMAIL="t@example.com",
    GIT_CONFIG_GLOBAL="/dev/null",
    GIT_CONFIG_SYSTEM="/dev/null",
)


def git(cwd: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True, env=ENV)


class KnownTest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        git(self.dir, "init", "-q", "-b", "main")
        (self.dir / "notes.md").write_text("The composer is the only place that writes the keys.\n")
        git(self.dir, "add", "notes.md")
        git(self.dir, "commit", "-q", "-m", "notes")

    def test_a_name_on_the_main_branch_is_known_whatever_its_case(self):
        self.assertTrue(repo.known("composer", self.dir))
        self.assertTrue(repo.known("Composer", self.dir))
        self.assertTrue(repo.known("`composer`", self.dir))

    def test_only_a_whole_word_counts(self):
        self.assertFalse(repo.known("compos", self.dir))
        self.assertFalse(repo.known("composers", self.dir))

    def test_a_name_that_is_only_in_the_working_tree_is_not_known(self):
        (self.dir / "draft.md").write_text("The brokerage is new.\n")
        git(self.dir, "add", "draft.md")
        self.assertFalse(repo.known("brokerage", self.dir))

    def test_a_name_that_is_only_on_a_topic_branch_is_not_known(self):
        git(self.dir, "checkout", "-q", "-b", "topic")
        (self.dir / "topic.md").write_text("The brokerage is new.\n")
        git(self.dir, "add", "topic.md")
        git(self.dir, "commit", "-q", "-m", "topic")
        self.assertFalse(repo.known("brokerage", self.dir))
        self.assertTrue(repo.known("composer", self.dir))

    def test_short_phrases_and_missing_places_are_not_known(self):
        self.assertFalse(repo.known("the", self.dir))
        self.assertFalse(repo.known("composer", None))
        self.assertFalse(repo.known("composer", Path(tempfile.mkdtemp())))


class SessionCwdTest(unittest.TestCase):
    def test_the_last_existing_directory_of_the_transcript(self):
        tmp = Path(tempfile.mkdtemp())
        here = tmp / "here"
        here.mkdir()
        transcript = tmp / "t.jsonl"
        lines = [
            {"type": "user", "cwd": str(here), "message": {"role": "user", "content": "a"}},
            {"type": "user", "cwd": str(tmp / "gone"), "message": {"role": "user", "content": "b"}},
        ]
        transcript.write_text("\n".join(json.dumps(line) for line in lines) + "\n")
        self.assertEqual(repo.session_cwd(transcript), here)

    def test_no_transcript_or_no_cwd(self):
        self.assertIsNone(repo.session_cwd(None))
        self.assertIsNone(repo.session_cwd(Path(tempfile.mkdtemp()) / "missing.jsonl"))
        transcript = Path(tempfile.mkdtemp()) / "t.jsonl"
        transcript.write_text(json.dumps({"type": "user", "message": {"role": "user", "content": "a"}}) + "\n")
        self.assertIsNone(repo.session_cwd(transcript))


if __name__ == "__main__":
    unittest.main()
