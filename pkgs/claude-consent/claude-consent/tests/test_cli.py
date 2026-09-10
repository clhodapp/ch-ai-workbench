# SPDX-License-Identifier: MIT
"""The prompt API end to end, through the command line in a
subprocess: the four ask outcomes (answered, timeout, fallback,
pending), stored answers consumed by key, the async waiter re-entering
a command with the answer on stdin, handler liveness, and the
non-interactive answer command."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "src"
sys.path.insert(0, str(SRC))
SESSION = "0123456789abcdef-0000-4000-8000-000000000000"


def run_cli(spool: Path, *args: str, stdin: str | None = None, timeout: float = 30) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    env["PYTHONPATH"] = os.pathsep.join([str(SRC), env.get("PYTHONPATH", "")])
    return subprocess.run(
        [sys.executable, "-m", "claude_consent.cli", "--spool", str(spool), *args],
        input=stdin,
        capture_output=True,
        text=True,
        env=env,
        timeout=timeout,
        check=False,
    )


def out(completed: subprocess.CompletedProcess[str]) -> dict:
    assert completed.returncode == 0, completed.stderr
    return json.loads(completed.stdout)


def wait_for(predicate, timeout: float = 10) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError("condition never held")


class SpoolCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.spool = Path(self.tmp.name) / "spool"
        self.addCleanup(self.tmp.cleanup)

    def register_handler(self, name: str = "test", pid: int | None = None) -> None:
        (self.spool / "handlers").mkdir(parents=True, exist_ok=True)
        (self.spool / "handlers" / f"{name}.json").write_text(
            json.dumps({"name": name, "pid": pid if pid is not None else os.getpid()})
        )

    def pending(self) -> list[dict]:
        directory = self.spool / "pending"
        if not directory.is_dir():
            return []
        return [json.loads(path.read_text()) for path in directory.glob("*.json")]

    def answer(self, record: dict, value: str, text: str | None = None) -> None:
        answer = {"id": record["id"], "value": value}
        if text:
            answer["text"] = text
        path = self.spool / "answers" / f"{record['id']}.json"
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(answer))
        os.replace(tmp, path)


class AskTests(SpoolCase):
    def test_layout_is_owner_only(self) -> None:
        out(run_cli(self.spool, "ask", "--session", SESSION, "--title", "t", "--option", "allow", "--fallback", "allow"))
        self.assertEqual(self.spool.stat().st_mode & 0o777, 0o700)
        for sub in ("territory", "pending", "answers", "handlers", "log"):
            self.assertTrue((self.spool / sub).is_dir())

    def test_fallback_when_nobody_is_attached(self) -> None:
        result = out(
            run_cli(
                self.spool,
                "ask",
                "--session",
                SESSION,
                "--title",
                "Edit outside territory",
                "--option",
                "allow",
                "--option",
                "deny",
                "--fallback",
                "ask",
            )
        )
        self.assertEqual(result["status"], "fallback")
        self.assertEqual(result["value"], "ask")
        self.assertEqual(self.pending(), [])

    def test_stored_then_consumed_by_key(self) -> None:
        first = out(
            run_cli(
                self.spool,
                "ask",
                "--session",
                SESSION,
                "--title",
                "Which branch?",
                "--option",
                "main",
                "--option",
                "topic",
                "--key",
                "k1",
            )
        )
        self.assertEqual(first["status"], "pending")
        self.assertEqual(first["mode"], "stored")
        self.assertTrue(first["id"].startswith("01234567-"))
        self.assertIn(f"claude-consent answer {first['id']}", first["instructions"])
        records = self.pending()
        self.assertEqual(len(records), 1)
        self.assertIsNone(records[0]["pid"])
        # A second ask before any answer stores nothing new and stays pending.
        again = out(run_cli(self.spool, "ask", "--session", SESSION, "--title", "Which branch?", "--option", "main", "--option", "topic", "--key", "k1"))
        self.assertEqual(again["status"], "pending")
        self.assertEqual(len(self.pending()), 2)
        # The user answers in a terminal.
        completed = run_cli(self.spool, "answer", first["id"], "--value", "topic", "--text", "because")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        # A different key does not see it.
        other = out(run_cli(self.spool, "ask", "--session", SESSION, "--title", "Which branch?", "--option", "main", "--option", "topic", "--key", "k2"))
        self.assertEqual(other["status"], "pending")
        # The same key consumes it, once.
        consumed = out(run_cli(self.spool, "ask", "--session", SESSION, "--title", "Which branch?", "--option", "main", "--option", "topic", "--key", "k1"))
        self.assertEqual(consumed, {"status": "answered", "value": "topic", "text": "because"})
        self.assertFalse((self.spool / "answers" / f"{first['id']}.json").exists())
        # Another session's stored answer is not ours.
        stranger = out(run_cli(self.spool, "ask", "--session", "ffffffff-rest", "--title", "Which branch?", "--option", "main", "--key", "k1"))
        self.assertEqual(stranger["status"], "pending")

    def test_answer_rejects_values_outside_the_options(self) -> None:
        first = out(run_cli(self.spool, "ask", "--session", SESSION, "--title", "t", "--option", "a", "--option", "b"))
        completed = run_cli(self.spool, "answer", first["id"], "--value", "c")
        self.assertEqual(completed.returncode, 1)
        self.assertIn("not an option", completed.stderr)
        completed = run_cli(self.spool, "answer", "01234567", "--value", "a")
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_answer_by_agent_id_needs_one_match(self) -> None:
        out(run_cli(self.spool, "ask", "--session", SESSION, "--title", "t1", "--option", "a", "--key", "k1"))
        out(run_cli(self.spool, "ask", "--session", SESSION, "--title", "t2", "--option", "a", "--key", "k2"))
        completed = run_cli(self.spool, "answer", "01234567", "--value", "a")
        self.assertEqual(completed.returncode, 1)
        self.assertIn("matches 2 prompts", completed.stderr)

    def test_blocking_ask_returns_the_answer(self) -> None:
        self.register_handler()
        payload = json.dumps(
            {
                "session_id": SESSION,
                "hook_event_name": "PreToolUse",
                "tool_name": "Write",
                "tool_input": {"file_path": "/elsewhere/x"},
                "cwd": "/proj",
            }
        )

        def answer_when_seen() -> None:
            wait_for(lambda: len(self.pending()) == 1)
            record = self.pending()[0]
            assert record["mode"] == "blocking"
            assert record["hook"]["tool_name"] == "Write"
            assert record["territory"]["roots"] == ["/proj"]
            assert record["prompt"]["options"][1]["text"] == "Deny reason"
            self.answer(record, "deny", "wrong repo")

        thread = threading.Thread(target=answer_when_seen)
        thread.start()
        result = out(
            run_cli(
                self.spool,
                "ask",
                "--payload-stdin",
                "--title",
                "Write outside territory",
                "--option",
                "allow=Allow this call",
                "--option",
                "deny=Deny",
                "--option-text",
                "deny=Deny reason",
                "--extra",
                json.dumps({"territory": {"roots": ["/proj"]}}),
                "--fallback",
                "ask",
                stdin=payload,
            )
        )
        thread.join()
        self.assertEqual(result, {"status": "answered", "value": "deny", "text": "wrong repo"})
        self.assertEqual(self.pending(), [])
        self.assertEqual(list((self.spool / "answers").glob("*.json")), [])

    def test_blocking_ask_times_out(self) -> None:
        self.register_handler()
        result = out(run_cli(self.spool, "ask", "--session", SESSION, "--title", "t", "--option", "a", "--deadline", "1"))
        self.assertEqual(result["status"], "timeout")
        self.assertEqual(self.pending(), [])

    def test_dead_handler_is_not_attached(self) -> None:
        self.register_handler(pid=4194301)
        result = out(run_cli(self.spool, "ask", "--session", SESSION, "--title", "t", "--option", "a", "--fallback", "a"))
        self.assertEqual(result["status"], "fallback")
        self.assertEqual(list((self.spool / "handlers").glob("*.json")), [])

    def test_async_reenters_with_the_answer(self) -> None:
        self.register_handler()
        sink = self.spool / "reentered.json"
        script = self.spool.parent / "hook.sh"
        script.write_text("#!/bin/sh\ncat > \"$1\"\necho \"reentry=$CLAUDE_CONSENT_REENTRY\"\n")
        script.chmod(0o755)
        payload = json.dumps({"session_id": SESSION, "hook_event_name": "Stop", "cwd": "/"})
        result = out(
            run_cli(
                self.spool,
                "ask",
                "--payload-stdin",
                "--title",
                "Open a pull request?",
                "--option",
                "yes",
                "--option",
                "no",
                "--async",
                "--",
                str(script),
                str(sink),
                stdin=payload,
            )
        )
        self.assertEqual(result["status"], "pending")
        self.assertEqual(result["mode"], "waiter")
        self.assertNotIn("instructions", result)
        wait_for(lambda: self.pending() and self.pending()[0].get("pid"))
        record = self.pending()[0]
        self.assertEqual(record["mode"], "waiter")
        self.assertTrue(Path(f"/proc/{record['pid']}").is_dir())
        self.answer(record, "yes")
        wait_for(sink.exists)
        wait_for(lambda: self.pending() == [])
        reentered = json.loads(sink.read_text())
        self.assertEqual(reentered["hook_event_name"], "Stop")
        self.assertEqual(reentered["consent_answer"], {"id": record["id"], "status": "answered", "value": "yes"})
        log = self.spool / "log" / f"{record['id']}.log"
        wait_for(log.exists)
        wait_for(lambda: "reentry=" in log.read_text())
        self.assertEqual(log.read_text().strip(), f"reentry={record['id']}")

    def test_async_without_handler_gives_instructions(self) -> None:
        script = self.spool.parent / "hook.sh"
        script.write_text("#!/bin/sh\ncat >/dev/null\n")
        script.chmod(0o755)
        result = out(
            run_cli(self.spool, "ask", "--session", SESSION, "--title", "t", "--option", "a", "--async", "--", str(script))
        )
        self.assertEqual(result["mode"], "waiter")
        self.assertIn("claude-consent answer", result["instructions"])
        wait_for(lambda: self.pending() and self.pending()[0].get("pid"))
        completed = run_cli(self.spool, "answer", result["id"], "--value", "a")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        wait_for(lambda: self.pending() == [])

    def test_async_needs_a_command(self) -> None:
        completed = run_cli(self.spool, "ask", "--session", SESSION, "--title", "t", "--option", "a", "--async")
        self.assertEqual(completed.returncode, 1)
        self.assertIn("re-entry command", completed.stderr)


class ListingTests(SpoolCase):
    def test_list_prunes_dead_and_expired(self) -> None:
        (self.spool / "pending").mkdir(parents=True)
        (self.spool / "answers").mkdir()
        now = int(time.time())
        rows = [
            {"id": "live", "session_id": SESSION, "mode": "blocking", "pid": os.getpid(), "created": 1, "deadline": now + 60, "prompt": {"title": "live"}},
            {"id": "dead", "session_id": SESSION, "mode": "blocking", "pid": 4194301, "created": 2, "deadline": now + 60, "prompt": {"title": "dead"}},
            {"id": "kept", "session_id": SESSION, "mode": "stored", "pid": None, "created": 3, "deadline": now + 60, "prompt": {"title": "kept"}},
            {"id": "old", "session_id": SESSION, "mode": "stored", "pid": None, "created": 4, "deadline": now - 1, "prompt": {"title": "old"}},
        ]
        for row in rows:
            (self.spool / "pending" / f"{row['id']}.json").write_text(json.dumps(row))
        (self.spool / "answers" / "dead.json").write_text(json.dumps({"id": "dead", "value": "a"}))
        (self.spool / "pending" / "garbage.json").write_text("{")
        listed = out(run_cli(self.spool, "list", "--json"))
        self.assertEqual([row["id"] for row in listed["pending"]], ["live", "kept"])
        self.assertFalse((self.spool / "answers" / "dead.json").exists())
        text = run_cli(self.spool, "list").stdout
        self.assertIn("live", text)
        self.assertNotIn("old", text)

    def test_handlers_listing(self) -> None:
        (self.spool / "handlers").mkdir(parents=True)
        (self.spool / "handlers" / "emacs.json").write_text(json.dumps({"name": "emacs", "pid": os.getpid()}))
        (self.spool / "handlers" / "gone.json").write_text(json.dumps({"name": "gone", "pid": 4194301}))
        listed = out(run_cli(self.spool, "handlers", "--json"))
        self.assertEqual([handler["name"] for handler in listed["handlers"]], ["emacs"])

    def test_no_runtime_dir_is_an_error(self) -> None:
        env = dict(os.environ)
        env.pop("XDG_RUNTIME_DIR", None)
        env["PYTHONPATH"] = os.pathsep.join([str(SRC), env.get("PYTHONPATH", "")])
        completed = subprocess.run(
            [sys.executable, "-m", "claude_consent.cli", "ask", "--session", SESSION, "--title", "t", "--option", "a"],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        self.assertEqual(completed.returncode, 1)
        self.assertIn("XDG_RUNTIME_DIR", completed.stderr)


class OptionKeyTests(unittest.TestCase):
    def test_option_keys(self) -> None:
        from claude_consent.spool import option_keys

        self.assertEqual(option_keys([{"value": "allow"}, {"value": "deny"}]), ["a", "d"])
        self.assertEqual(option_keys([{"value": "a1"}, {"value": "a2"}, {"value": "-"}]), ["a", "1", "2"])


if __name__ == "__main__":
    unittest.main()
