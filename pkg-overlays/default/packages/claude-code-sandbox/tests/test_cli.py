# SPDX-License-Identifier: MIT
"""End-to-end CLI tests against a temp checkout and registry."""

import contextlib
import io
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path
from unittest import mock

from fixtures import WORK, WORK_FRAGMENT, write_registry

from claude_code_sandbox import cli

TOOLS = {
    "description": "more tools",
    "masked": True,
    "closure": ["/nix/store/ccc-tools"],
    "path": ["/nix/store/tools-farm/bin"],
    "allowedDomains": ["example.org"],
}


def with_root(fragment, root):
    """``fragment`` as applied to the checkout at ``root``: the CLI names
    the enrolled root in the env."""
    return {**fragment, "env": {**fragment["env"], "CLAUDE_CODE_SANDBOX_ROOT": str(root)}}


class CliTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        tmp = Path(self._tmp.name)

        self.repo = tmp / "projects" / "demo"
        (self.repo / ".git").mkdir(parents=True)  # enough for root discovery

        self.config = tmp / "config"
        self.parts = write_registry(self.config, {"work": WORK, "tools": TOOLS})
        self.state = tmp / "state"
        patcher = mock.patch.dict(
            os.environ,
            {
                "CLAUDE_CODE_SANDBOX_CONFIG": str(self.config),
                "CLAUDE_CODE_SANDBOX_STATE": str(self.state),
            },
        )
        patcher.start()
        self.addCleanup(patcher.stop)

    def settings(self):
        path = self.repo / ".claude" / "settings.local.json"
        return json.loads(path.read_text()) if path.exists() else None

    def sidecar(self):
        return json.loads((self.repo / ".claude" / "claude-code-sandbox.json").read_text())

    def run_cli(self, *argv):
        return cli.main(list(argv))

    def output_of(self, *argv):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = self.run_cli(*argv)
        return rc, buf.getvalue()

    def enroll(self, *modules):
        return self.run_cli("enroll", *modules, "-C", str(self.repo), "--quiet")

    def test_enroll_writes_settings_and_sidecar(self):
        self.assertEqual(self.enroll("work"), 0)
        # The enrolled root is in the env so the ssh wrapper can find the
        # creds dir cwd-independently.
        expected = with_root(WORK_FRAGMENT, self.repo)
        self.assertEqual(self.settings(), expected)
        self.assertEqual(
            self.settings()["env"]["CLAUDE_CODE_SANDBOX_ROOT"], str(self.repo)
        )
        self.assertEqual(self.sidecar(), {"modules": ["work"], "applied": expected})

    def expiring(self):
        path = self.state / "expiring.json"
        return json.loads(path.read_text())["checkouts"] if path.exists() else None

    def later(self, days):
        return mock.patch.object(
            cli, "_now", return_value=datetime.now(UTC) + timedelta(days=days)
        )

    def test_add_for_a_day_records_the_deadline_and_indexes_the_checkout(self):
        self.enroll("work")
        rc, out = self.output_of("add", "tools", "--for", "day", "-C", str(self.repo))
        self.assertEqual(rc, 0)
        self.assertIn("[tools] chosen until ", out)
        at = datetime.fromisoformat(self.sidecar()["expires"]["tools"])
        self.assertAlmostEqual(
            (at - datetime.now(UTC)).total_seconds(), 86400, delta=60
        )
        self.assertEqual(self.sidecar()["modules"], ["tools", "work"])
        self.assertIn("example.org", self.settings()["sandbox"]["network"]["allowedDomains"])
        self.assertEqual(self.expiring(), [str(self.repo)])
        rc, out = self.output_of("status", "-C", str(self.repo))
        self.assertEqual(rc, 0)
        self.assertIn("temporary [tools until ", out)

    def test_expire_drops_due_modules_and_leaves_the_index(self):
        self.enroll("work")
        self.run_cli("add", "tools", "--for", "day", "-C", str(self.repo), "--quiet")
        self.assertEqual(self.output_of("expire")[1], "")
        self.assertEqual(self.sidecar()["modules"], ["tools", "work"])
        with self.later(2):
            rc, out = self.output_of("expire")
        self.assertEqual(rc, 0)
        self.assertIn("dropped expired [tools]", out)
        self.assertEqual(self.sidecar(), {"modules": ["work"], "applied": with_root(WORK_FRAGMENT, self.repo)})
        self.assertEqual(self.settings(), with_root(WORK_FRAGMENT, self.repo))
        self.assertEqual(self.expiring(), [])

    def test_a_week_outlasts_a_day(self):
        self.enroll("work")
        self.run_cli("add", "tools", "--for", "week", "-C", str(self.repo), "--quiet")
        with self.later(2):
            self.output_of("expire")
        self.assertEqual(self.sidecar()["modules"], ["tools", "work"])
        with self.later(8):
            self.output_of("expire")
        self.assertEqual(self.sidecar()["modules"], ["work"])

    def test_status_reports_an_expired_module(self):
        self.enroll("work")
        self.run_cli("add", "tools", "--for", "day", "-C", str(self.repo), "--quiet")
        with self.later(2):
            rc, out = self.output_of("status", "-C", str(self.repo))
        self.assertEqual(rc, 2)
        self.assertIn("EXPIRED [tools] (sync drops)", out)

    def test_sync_drops_expired_modules(self):
        self.enroll("work")
        self.run_cli("add", "tools", "--for", "day", "-C", str(self.repo), "--quiet")
        with self.later(2):
            self.run_cli("sync", "-C", str(self.repo), "--quiet")
        self.assertEqual(self.sidecar()["modules"], ["work"])

    def test_plain_add_makes_a_temporary_module_lasting(self):
        self.enroll("work")
        self.run_cli("add", "tools", "--for", "day", "-C", str(self.repo), "--quiet")
        self.run_cli("add", "tools", "-C", str(self.repo), "--quiet")
        self.assertNotIn("expires", self.sidecar())
        self.assertEqual(self.expiring(), [])

    def test_drop_and_enroll_forget_deadlines(self):
        self.enroll("work")
        self.run_cli("add", "tools", "--for", "day", "-C", str(self.repo), "--quiet")
        self.run_cli("drop", "tools", "-C", str(self.repo), "--quiet")
        self.assertNotIn("expires", self.sidecar())
        self.run_cli("add", "tools", "--for", "day", "-C", str(self.repo), "--quiet")
        self.enroll("work", "tools")
        self.assertNotIn("expires", self.sidecar())
        self.assertEqual(self.expiring(), [])

    def test_expire_prunes_checkouts_that_are_gone(self):
        self.enroll("work")
        self.run_cli("add", "tools", "--for", "day", "-C", str(self.repo), "--quiet")
        shutil.rmtree(self.repo / ".claude")
        self.assertEqual(self.run_cli("expire"), 0)
        self.assertEqual(self.expiring(), [])

    def test_enroll_composes_several_modules(self):
        self.assertEqual(self.enroll("work", "tools"), 0)
        settings = self.settings()
        self.assertEqual(self.sidecar()["modules"], ["tools", "work"])
        self.assertIn("/nix/store/ccc-tools", settings["sandbox"]["filesystem"]["allowRead"])
        self.assertIn("/nix/store/aaa-hello", settings["sandbox"]["filesystem"]["allowRead"])
        self.assertEqual(settings["sandbox"]["network"]["allowedDomains"], ["example.org"])

    def test_enroll_with_no_modules_is_base_only(self):
        self.assertEqual(self.enroll(), 0)
        self.assertEqual(self.sidecar()["modules"], [])
        self.assertEqual(
            self.settings()["sandbox"]["filesystem"]["allowRead"], ["/nix/store/bbb-base"]
        )

    def test_enroll_root_env_and_status_current(self):
        # The root env is tool-owned (part of the applied fragment), so
        # status reports current right after enroll, not stale.
        self.enroll("work")
        rc, out = self.output_of("status", "-C", str(self.repo))
        self.assertEqual(rc, 0)
        self.assertIn("modules [work], current", out)

    def test_add_and_drop_edit_the_chosen_set(self):
        self.enroll("work")
        self.assertEqual(self.run_cli("add", "tools", "-C", str(self.repo), "--quiet"), 0)
        self.assertEqual(self.sidecar()["modules"], ["tools", "work"])
        self.assertEqual(
            self.settings()["sandbox"]["network"]["allowedDomains"], ["example.org"]
        )
        self.assertEqual(self.run_cli("drop", "tools", "-C", str(self.repo), "--quiet"), 0)
        self.assertEqual(self.sidecar()["modules"], ["work"])
        self.assertNotIn("network", self.settings()["sandbox"])
        self.assertEqual(self.settings(), with_root(WORK_FRAGMENT, self.repo))

    def test_size_check_covers_the_checkout_root(self):
        # A fragment just under the limit before the root is added must
        # still be refused once the root makes it the fragment applied.
        from claude_code_sandbox.compose import FRAGMENT_LIMIT

        root_entry = len(f',\n    "CLAUDE_CODE_SANDBOX_ROOT": "{self.repo}"')
        base_size = len(json.dumps(cli.compose(cli.load_registry(), ["work"]), indent=2))
        pad = FRAGMENT_LIMIT - base_size - root_entry // 2
        padded = {**WORK, "env": {"PAD": "x" * pad}}
        write_registry(self.config, {"work": padded})
        size_without_root = len(json.dumps(cli.compose(cli.load_registry(), ["work"]), indent=2))
        self.assertLessEqual(size_without_root, FRAGMENT_LIMIT)
        self.assertEqual(self.enroll("work"), 1)
        self.assertFalse((self.repo / ".claude" / "settings.local.json").exists())

    def test_drop_of_an_unchosen_module_fails_cleanly(self):
        self.enroll("work")
        self.assertEqual(self.run_cli("drop", "tools", "-C", str(self.repo)), 1)
        self.assertEqual(self.sidecar()["modules"], ["work"])

    def test_add_needs_an_enrollment(self):
        self.assertEqual(self.run_cli("add", "work", "-C", str(self.repo)), 1)
        self.run_cli("abandon", "-C", str(self.repo), "--quiet")
        self.assertEqual(self.run_cli("add", "work", "-C", str(self.repo)), 1)

    def test_enroll_preserves_existing_foreign_keys(self):
        claude_dir = self.repo / ".claude"
        claude_dir.mkdir()
        (claude_dir / "settings.local.json").write_text(
            json.dumps({"permissions": {"allow": ["Bash(date:*)"]}})
        )
        self.enroll("work")
        settings = self.settings()
        self.assertEqual(settings["permissions"], {"allow": ["Bash(date:*)"]})
        self.assertEqual(settings["sandbox"], WORK_FRAGMENT["sandbox"])

    def test_abandon_empties_owned_keys_only(self):
        self.enroll("work")
        settings_file = self.repo / ".claude" / "settings.local.json"
        content = json.loads(settings_file.read_text())
        content["permissions"] = {"allow": ["x"]}
        settings_file.write_text(json.dumps(content))
        rc = self.run_cli("abandon", "-C", str(self.repo), "--quiet")
        self.assertEqual(rc, 0)
        settings = self.settings()
        self.assertNotIn("sandbox", settings)
        self.assertNotIn("env", settings)
        self.assertEqual(settings["permissions"], {"allow": ["x"]})
        self.assertEqual(self.sidecar(), {"modules": None, "applied": {}})
        rc, out = self.output_of("status", "-C", str(self.repo))
        self.assertEqual(rc, 0)
        self.assertIn("abandoned, current", out)

    def test_profile_era_none_sidecar_reads_as_abandoned(self):
        claude_dir = self.repo / ".claude"
        claude_dir.mkdir()
        (claude_dir / "claude-code-sandbox.json").write_text(
            json.dumps({"profile": "none", "applied": {}})
        )
        rc, out = self.output_of("status", "-C", str(self.repo))
        self.assertEqual(rc, 0)
        self.assertIn("abandoned", out)

    def test_profile_era_binding_reports_and_reenrolls(self):
        # A checkout bound to a profile keeps its applied fragment until
        # someone chooses its modules; that fragment is the merge base,
        # so enrolling replaces every key the profile applied.
        old = {
            "sandbox": {"enabled": True, "network": {"allowedDomains": ["old.example"]}},
            "env": {"PATH": "/old/bin"},
        }
        claude_dir = self.repo / ".claude"
        claude_dir.mkdir()
        (claude_dir / "settings.local.json").write_text(
            json.dumps({**old, "permissions": {"allow": ["x"]}})
        )
        (claude_dir / "claude-code-sandbox.json").write_text(
            json.dumps({"profile": "nix", "applied": old})
        )
        rc, out = self.output_of("status", "-C", str(self.repo))
        self.assertEqual(rc, 2)
        self.assertIn("profile 'nix', which no longer exists", out)
        self.assertEqual(self.run_cli("sync", "-C", str(self.repo), "--quiet"), 1)
        self.assertEqual(self.run_cli("add", "work", "-C", str(self.repo), "--quiet"), 1)

        self.assertEqual(self.enroll("work"), 0)
        settings = self.settings()
        self.assertNotIn("network", settings["sandbox"])
        self.assertEqual(settings["env"]["PATH"], WORK_FRAGMENT["env"]["PATH"])
        self.assertEqual(settings["permissions"], {"allow": ["x"]})
        self.assertEqual(self.sidecar()["modules"], ["work"])

    def test_status_survives_device_settings_file(self):
        # A worktree / bg-isolation harness can bind the checkout's
        # settings file to a character device (e.g. /dev/null), which is
        # not a regular file and may deny reads. status must degrade, not
        # crash with a traceback.
        self.enroll("work")
        settings = self.repo / ".claude" / "settings.local.json"
        settings.unlink()
        os.symlink("/dev/null", settings)
        rc, out = self.output_of("status", "-C", str(self.repo))
        # /dev/null reads as empty, so no settings match the sidecar, but
        # the sidecar is intact, so status still reports the modules.
        self.assertIn(rc, (0, 2))
        self.assertIn("modules [work]", out)

    def _write_registry_with_credentials(self, creds):
        write_registry(self.config, {"work": WORK, "tools": TOOLS}, credentials=creds)

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

    def test_status_reports_stale_after_part_change(self):
        self.enroll("work")
        self.parts["work"].write_text(json.dumps({**WORK, "path": ["/nix/store/new-farm/bin"]}))
        self.assertEqual(self.run_cli("status", "-C", str(self.repo)), 2)
        self.assertEqual(self.run_cli("sync", "-C", str(self.repo), "--quiet"), 0)
        self.assertIn("/nix/store/new-farm/bin", self.settings()["env"]["PATH"])
        self.assertEqual(self.run_cli("status", "-C", str(self.repo)), 0)

    def test_status_reports_dangling_when_a_module_disappears(self):
        self.enroll("work", "tools")
        write_registry(self.config, {"work": WORK})
        rc, out = self.output_of("status", "-C", str(self.repo))
        self.assertEqual(rc, 2)
        self.assertIn("DANGLING", out)
        self.assertIn("tools", out)

    def test_status_degrades_inside_masked_store(self):
        # Inside a masked-store sandbox the HM symlinks for the registry
        # and parts dangle (targets in /nix/store are outside the
        # allowRead closure). Status must still report the enrollment
        # from the sidecar, with freshness unknown, and not claim a
        # module is dangling.
        self.enroll("work")
        for p in (self.parts["work"], self.parts["base"], self.config / "registry.json"):
            p.unlink()
            p.symlink_to("/nix/store/masked-away")
        rc, out = self.output_of("status", "-C", str(self.repo))
        self.assertEqual(rc, 0)
        self.assertIn("modules [work]", out)
        self.assertIn("freshness unknown", out)
        self.assertNotIn("DANGLING", out)

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
        self.enroll("work")
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
        self.enroll("work")
        cwd = os.getcwd()
        os.chdir(self.repo)
        try:
            with mock.patch.dict(os.environ, {}, clear=False):
                os.environ.pop("CLAUDE_JOB_DIR", None)
                self.assertEqual(self.run_cli("hook-session-start"), 0)
        finally:
            os.chdir(cwd)
        self.assertFalse((self.repo / ".claude" / "claude-code-sandbox").exists())

    def test_hook_drops_expired_modules(self):
        self.enroll("work")
        self.run_cli("add", "tools", "--for", "day", "-C", str(self.repo), "--quiet")
        cwd = os.getcwd()
        os.chdir(self.repo)
        try:
            with self.later(2):
                rc, out = self.output_of("hook-session-start")
        finally:
            os.chdir(cwd)
        self.assertEqual(rc, 0)
        self.assertIn("dropped expired [tools]", out)
        self.assertNotIn("hook error", out)
        self.assertEqual(self.sidecar()["modules"], ["work"])

    def test_hook_syncs_stale_checkout(self):
        self.enroll("work")
        self.parts["work"].write_text(json.dumps({**WORK, "path": ["/nix/store/new-farm/bin"]}))
        cwd = os.getcwd()
        os.chdir(self.repo)
        try:
            rc, out = self.output_of("hook-session-start")
        finally:
            os.chdir(cwd)
        self.assertEqual(rc, 0)
        self.assertIn("synced now", out)
        self.assertIn("/nix/store/new-farm/bin", self.settings()["env"]["PATH"])

    def test_hook_reports_profile_era_binding_without_touching_it(self):
        old = {"env": {"PATH": "/old/bin"}}
        claude_dir = self.repo / ".claude"
        claude_dir.mkdir()
        (claude_dir / "settings.local.json").write_text(json.dumps(old))
        (claude_dir / "claude-code-sandbox.json").write_text(
            json.dumps({"profile": "nix", "applied": old})
        )
        cwd = os.getcwd()
        os.chdir(self.repo)
        try:
            rc, out = self.output_of("hook-session-start")
        finally:
            os.chdir(cwd)
        self.assertEqual(rc, 0)
        self.assertIn("profile 'nix', which no longer exists", out)
        self.assertEqual(self.settings(), old)

    def test_list_names_modules_with_notes(self):
        write_registry(
            self.config,
            {
                "work": WORK,
                "tools": {**TOOLS, "requires": ["work"]},
                "nix": {"masked": False, "description": "nix with the store unmasked"},
            },
            base_modules=["work"],
        )
        rc, out = self.output_of("list")
        self.assertEqual(rc, 0)
        self.assertEqual(
            out.splitlines(),
            [
                "nix (unmasks the store): nix with the store unmasked",
                "tools (requires work): more tools",
                "work (in every enrollment): the work tools",
            ],
        )

    def test_scan_walks_given_directory_only(self):
        self.enroll("work")
        rc = self.run_cli("scan", str(Path(self._tmp.name) / "projects"))
        self.assertEqual(rc, 0)
        # A directory containing nothing enrolled reports cleanly.
        empty = Path(self._tmp.name) / "elsewhere"
        empty.mkdir()
        rc = self.run_cli("scan", str(empty))
        self.assertEqual(rc, 0)

    def test_unknown_module_fails_cleanly(self):
        self.assertEqual(self.enroll("nope"), 1)
        self.assertFalse((self.repo / ".claude").exists())

    def test_outside_repo_fails_cleanly(self):
        outside = Path(self._tmp.name) / "loose"
        outside.mkdir()
        rc = self.run_cli("status", "-C", str(outside))
        self.assertEqual(rc, 1)


if __name__ == "__main__":
    unittest.main()
