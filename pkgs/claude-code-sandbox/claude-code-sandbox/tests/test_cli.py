# SPDX-License-Identifier: LGPL-3.0-or-later
"""End-to-end CLI tests against a temp checkout and registry."""

import contextlib
import io
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from claude_code_sandbox import cli

FRAGMENT = {
    "sandbox": {
        "enabled": True,
        "failIfUnavailable": True,
        "filesystem": {
            "denyRead": ["/nix/store"],
            "allowRead": ["/nix/store/aaa-hello"],
        },
    },
    "env": {"PATH": "/profile/bin"},
}


class CliTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        tmp = Path(self._tmp.name)

        self.repo = tmp / "projects" / "demo"
        (self.repo / ".git").mkdir(parents=True)  # enough for root discovery

        config = tmp / "config"
        (config / "profiles").mkdir(parents=True)
        self.fragment_path = config / "profiles" / "work.json"
        self.fragment_path.write_text(json.dumps(FRAGMENT))
        none_path = config / "profiles" / "none.json"
        none_path.write_text("{}")
        default_path = config / "profiles" / "default.json"
        default_path.write_text("{}")
        (config / "registry.json").write_text(
            json.dumps(
                {
                    "profiles": {
                        "work": str(self.fragment_path),
                        "none": str(none_path),
                        "default": str(default_path),
                    },
                }
            )
        )
        patcher = mock.patch.dict(
            os.environ, {"CLAUDE_CODE_SANDBOX_CONFIG": str(config)}
        )
        patcher.start()
        self.addCleanup(patcher.stop)

    def settings(self):
        path = self.repo / ".claude" / "settings.local.json"
        return json.loads(path.read_text()) if path.exists() else None

    def run_cli(self, *argv):
        return cli.main(list(argv))

    def test_enroll_writes_settings_and_sidecar(self):
        rc = self.run_cli("enroll", "--profile", "work", str(self.repo), "--quiet")
        self.assertEqual(rc, 0)
        self.assertEqual(self.settings(), FRAGMENT)
        sidecar = json.loads(
            (self.repo / ".claude" / "claude-code-sandbox.json").read_text()
        )
        self.assertEqual(sidecar["profile"], "work")
        self.assertEqual(sidecar["applied"], FRAGMENT)

    def test_enroll_preserves_existing_foreign_keys(self):
        claude_dir = self.repo / ".claude"
        claude_dir.mkdir()
        (claude_dir / "settings.local.json").write_text(
            json.dumps({"permissions": {"allow": ["Bash(date:*)"]}})
        )
        self.run_cli("enroll", "--profile", "work", str(self.repo), "--quiet")
        settings = self.settings()
        self.assertEqual(settings["permissions"], {"allow": ["Bash(date:*)"]})
        self.assertEqual(settings["sandbox"], FRAGMENT["sandbox"])

    def test_abandon_empties_owned_keys_only(self):
        self.run_cli("enroll", "--profile", "work", str(self.repo), "--quiet")
        settings_file = self.repo / ".claude" / "settings.local.json"
        content = json.loads(settings_file.read_text())
        content["permissions"] = {"allow": ["x"]}
        settings_file.write_text(json.dumps(content))
        rc = self.run_cli("abandon", str(self.repo), "--quiet")
        self.assertEqual(rc, 0)
        settings = self.settings()
        self.assertNotIn("sandbox", settings)
        self.assertNotIn("env", settings)
        self.assertEqual(settings["permissions"], {"allow": ["x"]})
        sidecar = json.loads(
            (self.repo / ".claude" / "claude-code-sandbox.json").read_text()
        )
        self.assertEqual(sidecar["profile"], "none")

    def test_status_survives_device_settings_file(self):
        # A worktree / bg-isolation harness can bind the checkout's
        # settings file to a character device (e.g. /dev/null), which is
        # not a regular file and may deny reads. status must degrade, not
        # crash with a traceback.
        self.run_cli("enroll", "--profile", "work", str(self.repo), "--quiet")
        settings = self.repo / ".claude" / "settings.local.json"
        settings.unlink()
        os.symlink("/dev/null", settings)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = self.run_cli("status", str(self.repo))
        # /dev/null reads as empty -> no sidecar-matching settings, but
        # the sidecar is intact, so status still reports the profile.
        self.assertIn(rc, (0, 2))
        self.assertIn("profile 'work'", buf.getvalue())

    def _write_registry_with_credentials(self, creds):
        config = Path(os.environ["CLAUDE_CODE_SANDBOX_CONFIG"])
        reg = json.loads((config / "registry.json").read_text())
        reg["credentials"] = creds
        (config / "registry.json").write_text(json.dumps(reg))

    def test_provision_creds_copies_owned_content(self):
        src = Path(self._tmp.name) / "src_ssh_config"
        src.write_text("Host example\n  User me\n")
        self._write_registry_with_credentials(
            {"ssh-config": {"source": str(src), "target": "ssh_config"}}
        )
        written = cli.provision_creds(self.repo)
        self.assertEqual(written, ["ssh_config"])
        dest = self.repo / ".claude" / "claude-code-sandbox" / "creds" / "ssh_config"
        self.assertEqual(dest.read_text(), "Host example\n  User me\n")
        self.assertEqual(dest.stat().st_mode & 0o777, 0o600)
        # Idempotent: a second run rewrites the same content, no error.
        self.assertEqual(cli.provision_creds(self.repo), ["ssh_config"])
        self.assertEqual(dest.read_text(), "Host example\n  User me\n")

    def test_provision_creds_skips_absent_source(self):
        self._write_registry_with_credentials(
            {"ssh-config": {"source": "/no/such/file", "target": "ssh_config"}}
        )
        self.assertEqual(cli.provision_creds(self.repo), [])
        dest = self.repo / ".claude" / "claude-code-sandbox" / "creds" / "ssh_config"
        self.assertFalse(dest.exists())

    def test_provision_creds_null_source_is_empty_droppoint(self):
        self._write_registry_with_credentials(
            {"token": {"source": None, "target": "token"}}
        )
        self.assertEqual(cli.provision_creds(self.repo), ["token"])
        dest = self.repo / ".claude" / "claude-code-sandbox" / "creds" / "token"
        self.assertTrue(dest.exists())
        self.assertEqual(dest.read_text(), "")
        # A provisioner fills it; a later hook run must not clobber it.
        dest.write_text("delegated-secret")
        self.assertEqual(cli.provision_creds(self.repo), [])
        self.assertEqual(dest.read_text(), "delegated-secret")

    def test_status_reports_stale_after_fragment_change(self):
        self.run_cli("enroll", "--profile", "work", str(self.repo), "--quiet")
        changed = dict(FRAGMENT)
        changed["env"] = {"PATH": "/new-profile/bin"}
        self.fragment_path.write_text(json.dumps(changed))
        rc = self.run_cli("status", str(self.repo))
        self.assertEqual(rc, 2)
        rc = self.run_cli("sync", str(self.repo), "--quiet")
        self.assertEqual(rc, 0)
        self.assertEqual(self.settings()["env"]["PATH"], "/new-profile/bin")
        rc = self.run_cli("status", str(self.repo))
        self.assertEqual(rc, 0)

    def test_status_degrades_inside_masked_store(self):
        # Inside a masked-store sandbox the HM symlinks for the registry
        # and fragments dangle (targets in /nix/store are outside the
        # allowRead closure). Status must still report the enrollment
        # from the sidecar, with freshness unknown, and not claim the
        # profile is dangling.
        self.run_cli("enroll", "--profile", "work", str(self.repo), "--quiet")
        config = Path(os.environ["CLAUDE_CODE_SANDBOX_CONFIG"])
        for p in (self.fragment_path, config / "registry.json"):
            p.unlink()
            p.symlink_to("/nix/store/masked-away")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = self.run_cli("status", str(self.repo))
        self.assertEqual(rc, 0)
        self.assertIn("profile 'work'", buf.getvalue())
        self.assertIn("freshness unknown", buf.getvalue())
        self.assertNotIn("DANGLING", buf.getvalue())

    def _git_init_repo(self):
        # The fixture's bare `.git` directory is enough for root discovery
        # but not for `git rev-parse`; make it a real repository.
        shutil.rmtree(self.repo / ".git")
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)

    def test_hook_redirects_job_tmp_into_checkout(self):
        # Background jobs are told to write under $CLAUDE_JOB_DIR/tmp,
        # which is read-only inside the sandbox; the hook replaces it
        # with a symlink into the checkout's working tree (writable
        # there, per checkout), preserving anything already present,
        # pruning scratch of jobs that no longer exist, excluding the
        # tree from git status, and is idempotent.
        self._git_init_repo()
        self.run_cli("enroll", "--profile", "work", str(self.repo), "--quiet")
        tmp = Path(self._tmp.name)
        job = tmp / "jobs" / "abc123"
        (job / "tmp").mkdir(parents=True)
        (job / "tmp" / "keep.txt").write_text("x")
        scratch = self.repo / ".claude" / "claude-code-sandbox" / "jobs"
        (scratch / "gone-job" / "tmp").mkdir(parents=True)  # its job dir does not exist
        cwd = os.getcwd()
        os.chdir(self.repo)
        try:
            with mock.patch.dict(os.environ, {"CLAUDE_JOB_DIR": str(job)}):
                self.assertEqual(self.run_cli("hook-session-start"), 0)
                self.assertEqual(self.run_cli("hook-session-start"), 0)
        finally:
            os.chdir(cwd)
        link = job / "tmp"
        target = scratch / "abc123" / "tmp"
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.resolve(), target.resolve())
        self.assertEqual((link / "keep.txt").read_text(), "x")
        self.assertFalse((scratch / "gone-job").exists())
        exclude = (self.repo / ".git" / "info" / "exclude").read_text()
        self.assertEqual(exclude.count("/.claude/claude-code-sandbox/"), 1)

    def test_hook_leaves_job_tmp_alone_without_job_dir(self):
        self._git_init_repo()
        self.run_cli("enroll", "--profile", "work", str(self.repo), "--quiet")
        cwd = os.getcwd()
        os.chdir(self.repo)
        try:
            with mock.patch.dict(os.environ, {}, clear=False):
                os.environ.pop("CLAUDE_JOB_DIR", None)
                self.assertEqual(self.run_cli("hook-session-start"), 0)
        finally:
            os.chdir(cwd)
        self.assertFalse((self.repo / ".claude" / "claude-code-sandbox").exists())

    def test_scan_walks_given_directory_only(self):
        self.run_cli("enroll", "--profile", "work", str(self.repo), "--quiet")
        rc = self.run_cli("scan", str(Path(self._tmp.name) / "projects"))
        self.assertEqual(rc, 0)
        # A directory containing nothing enrolled reports cleanly.
        empty = Path(self._tmp.name) / "elsewhere"
        empty.mkdir()
        rc = self.run_cli("scan", str(empty))
        self.assertEqual(rc, 0)

    def test_unknown_profile_fails_cleanly(self):
        rc = self.run_cli("enroll", "--profile", "nope", str(self.repo), "--quiet")
        self.assertEqual(rc, 1)

    def test_outside_repo_fails_cleanly(self):
        outside = Path(self._tmp.name) / "loose"
        outside.mkdir()
        rc = self.run_cli("status", str(outside))
        self.assertEqual(rc, 1)


if __name__ == "__main__":
    unittest.main()
