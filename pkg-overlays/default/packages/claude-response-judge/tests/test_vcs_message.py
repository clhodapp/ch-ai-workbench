# SPDX-License-Identifier: MIT
"""claude-vcs-message on the command shapes an assistant uses to write a commit message or a
pull request text, and on commands that write neither."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "src"
sys.path.insert(0, str(SRC))

from claude_response_judge.vcs_message import texts

HERE = Path(".")


class TextsTest(unittest.TestCase):
    def test_commit_message_options(self):
        self.assertEqual(texts('git commit -m "subject" -m "body line"', HERE), ["subject", "body line"])
        self.assertEqual(texts("git commit -mshort --message=long", HERE), ["short", "long"])
        self.assertEqual(texts('git commit --amend --message "again"', HERE), ["again"])

    def test_commit_from_a_heredoc(self):
        command = "cd x && git -C repo commit -q -F - <<'EOF'\nfeat: x\n\nbody\nEOF\ngit log --oneline -1"
        self.assertEqual(texts(command, HERE), ["feat: x\n\nbody"])

    def test_commit_from_a_heredoc_in_a_substitution(self):
        command = "git commit -m \"$(cat <<'EOF'\nfeat: in a substitution\n\nbody\nEOF\n)\""
        self.assertEqual(texts(command, HERE), ["feat: in a substitution\n\nbody"])

    def test_commit_from_a_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "msg.txt").write_text("from a file\n")
            self.assertEqual(texts("git commit -F msg.txt", Path(tmp)), ["from a file"])
            self.assertEqual(texts("git commit --file=absent.txt", Path(tmp)), [])

    def test_commit_after_other_commands_on_lines(self):
        self.assertEqual(texts("git status\ngit add -A\ngit commit -m 'third line'", HERE), ["third line"])

    def test_pull_requests(self):
        command = "gh pr create --title 'Add the thing' --body-file - <<'EOF'\nThe body.\nEOF"
        self.assertEqual(texts(command, HERE), ["Add the thing", "The body."])
        self.assertEqual(texts('gh pr edit 59 --body="inline body"', HERE), ["inline body"])
        self.assertEqual(texts("gh pr comment 59 -b 'a comment'", HERE), ["a comment"])

    def test_reviews(self):
        self.assertEqual(texts("gh pr review 59 --comment --body 'Looks right.'", HERE), ["Looks right."])
        command = "gh pr review 59 --request-changes --body-file - <<'EOF'\nThe parser drops tabs.\nEOF"
        self.assertEqual(texts(command, HERE), ["The parser drops tabs."])

    def test_review_comments_through_the_api(self):
        command = (
            "gh api repos/o/r/pulls/59/comments -f body='Rename this.' -f path=a.py -F line=3"
            " -f commit_id=abc"
        )
        self.assertEqual(texts(command, HERE), ["Rename this."])
        command = "gh api -X POST repos/o/r/pulls/59/reviews -f event=COMMENT -f 'comments[][body]=inline one' -f body=summary"
        self.assertEqual(texts(command, HERE), ["inline one", "summary"])
        command = (
            "gh api repos/o/r/pulls/59/reviews --input - <<'EOF'\n"
            '{"body": "overall", "event": "COMMENT", "comments": [{"path": "a.py", "line": 3, "body": "here"}]}\n'
            "EOF"
        )
        self.assertEqual(texts(command, HERE), ["overall", "here"])
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "reply.md").write_text("from a file\n")
            self.assertEqual(texts("gh api repos/o/r/issues/59/comments -F body=@reply.md", Path(tmp)), ["from a file"])
        self.assertEqual(texts("gh api repos/o/r/pulls/59 -f body=x", HERE), [])
        self.assertEqual(texts("gh api repos/o/r/pulls/59/comments", HERE), [])

    def test_commands_that_write_no_message(self):
        for command in [
            "git log --oneline | grep commit",
            "git -C repo push origin main",
            "gh pr view 59 --json body",
            "echo hi",
            "git commit -m 'unbalanced",
            "",
        ]:
            self.assertEqual(texts(command, HERE), [], command)

    def test_cli(self):
        env = dict(os.environ, PYTHONPATH=str(SRC))
        res = subprocess.run(
            [sys.executable, "-m", "claude_response_judge.vcs_message"],
            input="git commit -m one -m two",
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        self.assertEqual((res.returncode, res.stdout), (0, "one\n\ntwo\n"))
        res = subprocess.run(
            [sys.executable, "-m", "claude_response_judge.vcs_message"],
            input="ls",
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        self.assertEqual((res.returncode, res.stdout), (0, ""))


if __name__ == "__main__":
    unittest.main()
