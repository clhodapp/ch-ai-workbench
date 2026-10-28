# SPDX-License-Identifier: MIT
"""Migration of checkouts and state bound under the tool's old name."""

import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from fixtures import WORK, WORK_FRAGMENT, write_registry

from agent_sandbox import cli, files


class MigrateTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        tmp = Path(self._tmp.name)
        self.repo = tmp / "projects" / "demo"
        (self.repo / ".git").mkdir(parents=True)
        self.config = tmp / "config"
        write_registry(self.config, {"work": WORK})
        self.xdg_state = tmp / "xdg-state"
        env = {"AGENT_SANDBOX_CONFIG": str(self.config), "XDG_STATE_HOME": str(self.xdg_state)}
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        os.environ.pop("AGENT_SANDBOX_STATE", None)
        self.old_dir = self.repo / ".claude" / "claude-code-sandbox"
        self.old_sidecar = self.repo / ".claude" / "claude-code-sandbox.json"
        self.new_sidecar = self.repo / ".agent-sandbox" / "binding.json"

    def write_old_checkout(self, applied=None):
        (self.repo / ".claude").mkdir(exist_ok=True)
        self.old_sidecar.write_text(
            json.dumps({"modules": ["work"], "applied": applied if applied is not None else {}})
        )
        (self.old_dir / "creds").mkdir(parents=True)
        (self.old_dir / "creds" / "ssh_config").write_text("Host x\n")
        (self.old_dir / "jobs" / "job1" / "tmp").mkdir(parents=True)

    def test_sidecar_moves_and_creds_go(self):
        self.write_old_checkout({"env": {"A": "1"}})
        self.assertTrue(files.migrate_checkout(self.repo))
        self.assertFalse(self.old_sidecar.exists())
        self.assertEqual(json.loads(self.new_sidecar.read_text())["applied"], {"env": {"A": "1"}})
        self.assertFalse((self.old_dir / "creds").exists())

    def test_jobs_dir_is_kept(self):
        self.write_old_checkout()
        files.migrate_checkout(self.repo)
        self.assertTrue((self.old_dir / "jobs" / "job1" / "tmp").is_dir())

    def test_idempotent(self):
        self.write_old_checkout()
        self.assertTrue(files.migrate_checkout(self.repo))
        before = self.new_sidecar.read_text()
        self.assertFalse(files.migrate_checkout(self.repo))
        self.assertEqual(self.new_sidecar.read_text(), before)

    def test_checkout_without_any_binding_is_untouched(self):
        self.assertFalse(files.migrate_checkout(self.repo))
        self.assertFalse((self.repo / ".agent-sandbox").exists())

    def test_existing_new_binding_wins(self):
        self.write_old_checkout({"env": {"OLD": "1"}})
        self.new_sidecar.parent.mkdir()
        self.new_sidecar.write_text(json.dumps({"modules": [], "applied": {}}))
        self.assertFalse(files.migrate_checkout(self.repo))
        self.assertEqual(json.loads(self.new_sidecar.read_text()), {"modules": [], "applied": {}})
        self.assertTrue(self.old_sidecar.exists())
        self.assertTrue((self.old_dir / "creds" / "ssh_config").exists())

    def test_empty_old_dir_is_removed(self):
        (self.repo / ".claude").mkdir()
        self.old_sidecar.write_text(json.dumps({"modules": [], "applied": {}}))
        (self.old_dir / "creds").mkdir(parents=True)
        files.migrate_checkout(self.repo)
        self.assertFalse(self.old_dir.exists())

    def test_pruner_empties_old_jobs_and_removes_old_dir(self):
        self.write_old_checkout()
        files.migrate_checkout(self.repo)
        jobs = Path(self._tmp.name) / "jobs"
        job = jobs / "live"
        (job / "tmp").mkdir(parents=True)
        # job1 has no job dir any more; the pruner takes it.
        with mock.patch.dict(os.environ, {"CLAUDE_JOB_DIR": str(job)}):
            cli.redirect_job_tmp(self.repo)
        self.assertFalse(self.old_dir.exists())
        self.assertTrue((self.repo / ".agent-sandbox" / "jobs" / "live" / "tmp").is_dir())

    def test_pruner_keeps_old_jobs_that_are_alive(self):
        self.write_old_checkout()
        files.migrate_checkout(self.repo)
        jobs = Path(self._tmp.name) / "jobs"
        (jobs / "job1").mkdir(parents=True)
        (jobs / "other" / "tmp").mkdir(parents=True)
        with mock.patch.dict(os.environ, {"CLAUDE_JOB_DIR": str(jobs / "other")}):
            cli.redirect_job_tmp(self.repo)
        self.assertTrue((self.old_dir / "jobs" / "job1" / "tmp").is_dir())

    def test_state_index_moves(self):
        old = self.xdg_state / "claude-code-sandbox"
        old.mkdir(parents=True)
        (old / "expiring.json").write_text(json.dumps({"checkouts": ["/x"]}))
        self.assertTrue(files.migrate_state())
        new = self.xdg_state / "agent-sandbox" / "expiring.json"
        self.assertEqual(json.loads(new.read_text()), {"checkouts": ["/x"]})
        self.assertFalse(old.exists())
        self.assertFalse(files.migrate_state())

    def test_state_index_is_not_migrated_over_an_existing_one(self):
        old = self.xdg_state / "claude-code-sandbox"
        old.mkdir(parents=True)
        (old / "expiring.json").write_text(json.dumps({"checkouts": ["/x"]}))
        new = self.xdg_state / "agent-sandbox"
        new.mkdir(parents=True)
        (new / "expiring.json").write_text(json.dumps({"checkouts": ["/y"]}))
        self.assertFalse(files.migrate_state())
        self.assertEqual(json.loads((new / "expiring.json").read_text()), {"checkouts": ["/y"]})

    def test_state_override_disables_the_state_migration(self):
        old = self.xdg_state / "claude-code-sandbox"
        old.mkdir(parents=True)
        (old / "expiring.json").write_text(json.dumps({"checkouts": ["/x"]}))
        with mock.patch.dict(os.environ, {"AGENT_SANDBOX_STATE": str(Path(self._tmp.name) / "s")}):
            self.assertFalse(files.migrate_state())
        self.assertTrue((old / "expiring.json").exists())

    def test_verbs_migrate_before_acting(self):
        self.write_old_checkout()
        with contextlib.redirect_stdout(io.StringIO()):
            cli.main(["status", "-C", str(self.repo)])
        self.assertTrue(self.new_sidecar.exists())
        self.assertFalse(self.old_sidecar.exists())

    def test_scan_finds_and_migrates_old_checkouts(self):
        self.write_old_checkout()
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            cli.main(["scan", str(Path(self._tmp.name) / "projects")])
        self.assertIn(str(self.repo), buf.getvalue())
        self.assertTrue(self.new_sidecar.exists())

    def test_session_start_hook_migrates(self):
        self.write_old_checkout()
        cwd = os.getcwd()
        os.chdir(self.repo)
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(cli.main(["hook-session-start"]), 0)
        finally:
            os.chdir(cwd)
        self.assertTrue(self.new_sidecar.exists())

    def test_sync_swaps_the_old_env_key_for_the_new_one(self):
        # The sidecar's applied fragment moves with it and is the merge
        # base, so the next sync removes the old key and adds the new.
        old_applied = {
            **WORK_FRAGMENT,
            "env": {**WORK_FRAGMENT["env"], "CLAUDE_CODE_SANDBOX_ROOT": str(self.repo)},
        }
        self.write_old_checkout(old_applied)
        (self.repo / ".claude" / "settings.local.json").write_text(
            json.dumps({**old_applied, "permissions": {"allow": ["x"]}})
        )
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cli.main(["sync", "-C", str(self.repo)]), 0)
        settings = json.loads((self.repo / ".claude" / "settings.local.json").read_text())
        self.assertNotIn("CLAUDE_CODE_SANDBOX_ROOT", settings["env"])
        self.assertEqual(settings["env"]["AGENT_SANDBOX_ROOT"], str(self.repo))
        self.assertEqual(settings["permissions"], {"allow": ["x"]})

    def test_expire_migrates_state_and_checkouts(self):
        self.write_old_checkout()
        old = self.xdg_state / "claude-code-sandbox"
        old.mkdir(parents=True)
        (old / "expiring.json").write_text(json.dumps({"checkouts": [str(self.repo)]}))
        self.assertEqual(cli.main(["expire", "--quiet"]), 0)
        self.assertTrue(self.new_sidecar.exists())
        self.assertFalse((old / "expiring.json").exists())


if __name__ == "__main__":
    unittest.main()
