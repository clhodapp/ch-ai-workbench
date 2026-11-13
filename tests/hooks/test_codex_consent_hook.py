"""Command approvals cannot escape an enrolled sandbox or open another prompt."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HOOK = sys.argv.pop(1)


class ConsentTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = {k: v for k, v in os.environ.items()
                    if k not in ("AGENT_SANDBOX_CODEX_POLICY", "CLAUDE_QUEUE_TASK")}

    def call(self, tool="Bash", cwd=None, env=None):
        payload = {"tool_name": tool, "cwd": str(cwd or self.root),
                   "tool_input": {"command": "python3 test.py"}}
        result = subprocess.run([HOOK], input=json.dumps(payload), text=True,
                                capture_output=True, env=env or self.env, check=True)
        return json.loads(result.stdout) if result.stdout.strip() else None

    def enroll(self):
        marker = self.root / ".agent-sandbox/codex-config.json"
        marker.parent.mkdir()
        marker.write_text("{}")

    def test_enrolled_commands_are_denied_including_automatic_retry(self):
        self.enroll()
        for tool in ("Bash", "exec_command", "shell_command", "shell", "write_stdin"):
            with self.subTest(tool=tool):
                decision = self.call(tool)["hookSpecificOutput"]["decision"]
                self.assertEqual(decision["behavior"], "deny")
                self.assertIn("default sandbox", decision["message"])

    def test_descendant_and_uri_working_directories(self):
        self.enroll()
        child = self.root / "src"
        child.mkdir()
        for cwd in (child, child.as_uri()):
            self.assertEqual(self.call(cwd=cwd)["hookSpecificOutput"]["decision"]["behavior"], "deny")

    def test_native_runtime_is_enrolled_even_outside_project_cwd(self):
        policy = self.root / "codex.json"
        policy.write_text("{}")
        env = {**self.env, "AGENT_SANDBOX_CODEX_POLICY": str(policy)}
        self.assertEqual(self.call(env=env)["hookSpecificOutput"]["decision"]["behavior"], "deny")

    def test_unenrolled_and_other_tools_preserve_existing_policy(self):
        self.assertIsNone(self.call())
        self.enroll()
        for tool in ("apply_patch", "request_permissions", "mcp__example__exec_command"):
            self.assertIsNone(self.call(tool))

    def test_interchat_communication_still_allowed(self):
        self.enroll()
        self.assertEqual(self.call("mcp__codex_tui__send_message_to_thread")
                         ["hookSpecificOutput"]["decision"]["behavior"], "allow")


unittest.main()
