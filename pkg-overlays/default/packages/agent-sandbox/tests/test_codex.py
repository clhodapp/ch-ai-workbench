# SPDX-License-Identifier: MIT
"""Native Codex policy compilation and the post-mount socket boundary."""

import tempfile
import unittest
from pathlib import Path

from agent_sandbox.codex import bwrap_command, check_native_config, configuration
from agent_sandbox.files import ToolError


class CodexTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "repo"
        self.scratch = Path(self.tmp.name) / "run/tmp"
        self.root.mkdir()
        self.scratch.mkdir(parents=True)
        self.settings = {
            "filesystem": {
                "denyRead": ["/nix/store"],
                "allowRead": ["/nix/store/tool"],
                "allowWrite": [str(self.root), str(self.scratch), "/state/tool"],
                "denyWrite": [str(self.root / ".agent-sandbox/binding.json")],
            },
            "network": {
                "allowedDomains": ["github.com", "*.github.com"],
                "deniedDomains": ["blocked.github.com"],
                "allowUnixSockets": ["/run/nix.sock"],
            },
        }

    def test_maps_filesystem_and_keeps_guards(self):
        config = configuration(self.settings, self.root, self.scratch)
        self.assertEqual(config["approval_policy"], "on-request")
        self.assertNotIn("sandbox_mode", config)
        profile = config["permissions"]["agent-sandbox"]
        self.assertEqual(profile["extends"], ":workspace")
        fs = profile["filesystem"]
        self.assertEqual(fs[":slash_tmp"], "read")
        self.assertEqual(fs[str(self.scratch)], "write")
        self.assertEqual(fs["/state/tool"], "write")
        self.assertEqual(fs["/nix/store"], "deny")
        self.assertEqual(fs["/nix/store/tool"], "read")
        self.assertEqual(fs[str(self.root / ".agent-sandbox/binding.json")], "read")
        self.assertEqual(fs[str(self.scratch.parent)], "read")

    def test_network_is_native_and_deny_wins(self):
        config = configuration(self.settings, self.root, self.scratch)
        self.assertTrue(config["features"]["network_proxy"])
        net = config["permissions"]["agent-sandbox"]["network"]
        self.assertTrue(net["enabled"])
        self.assertEqual(net["domains"]["github.com"], "allow")
        self.assertEqual(net["domains"]["blocked.github.com"], "deny")
        self.assertEqual(net["unix_sockets"], {"/run/nix.sock": "allow"})

    def test_git_override_is_opt_in_and_keeps_explicit_guards(self):
        self.assertNotIn(str(self.root / ".git"),
                         configuration(self.settings, self.root, self.scratch)["permissions"]["agent-sandbox"]["filesystem"])
        fs = configuration(self.settings, self.root, self.scratch, git_write=True)["permissions"]["agent-sandbox"]["filesystem"]
        self.assertEqual(fs[str(self.root / ".git")], "write")
        self.assertEqual(fs[str(self.root / ".agent-sandbox/binding.json")], "read")
        self.settings["filesystem"]["denyWrite"].append(str(self.root / ".git"))
        fs = configuration(self.settings, self.root, self.scratch, git_write=True)["permissions"]["agent-sandbox"]["filesystem"]
        self.assertNotEqual(fs.get(str(self.root / ".git")), "write")

    def test_git_pointer_only_reopens_metadata_with_existing_write_grants(self):
        metadata = self.root / "metadata/worktree"
        metadata.mkdir(parents=True)
        (metadata / "commondir").write_text("..\n")
        (self.root / ".git").write_text("gitdir: metadata/worktree\n")
        fs = configuration(self.settings, self.root, self.scratch, git_write=True)["permissions"]["agent-sandbox"]["filesystem"]
        self.assertEqual(fs[str(metadata)], "write")
        # The common dir is not necessarily a .git directory; resolve
        # the Git pointer rather than assuming a checkout layout.
        self.assertEqual(fs[str(metadata.parent)], "write")
        outside = Path(self.tmp.name) / "other-repo"
        outside.mkdir()
        (self.root / ".git").write_text(f"gitdir: {outside}\n")
        fs = configuration(self.settings, self.root, self.scratch, git_write=True)["permissions"]["agent-sandbox"]["filesystem"]
        self.assertNotIn(str(outside), fs)
        (self.root / ".git").unlink()
        (self.root / ".git").symlink_to(outside, target_is_directory=True)
        fs = configuration(self.settings, self.root, self.scratch, git_write=True)["permissions"]["agent-sandbox"]["filesystem"]
        self.assertNotIn(str(self.root / ".git"), fs)

    def test_no_domains_means_no_network(self):
        self.settings["network"] = {}
        config = configuration(self.settings, self.root, self.scratch)
        self.assertFalse(config["permissions"]["agent-sandbox"]["network"]["enabled"])

    def test_port_scoped_domain_is_not_silently_widened(self):
        self.settings["network"]["allowedDomains"] = ["example.com:8443"]
        with self.assertRaisesRegex(ToolError, "port"):
            configuration(self.settings, self.root, self.scratch)

    def test_write_glob_is_not_silently_widened(self):
        self.settings["filesystem"]["allowWrite"].append("/work/*")
        with self.assertRaisesRegex(ToolError, "glob"):
            configuration(self.settings, self.root, self.scratch)

    def test_legacy_user_config_cannot_disable_the_profile(self):
        home = self.root / "codex-home"
        home.mkdir()
        (home / "config.toml").write_text('sandbox_mode = "danger-full-access"\n')
        with self.assertRaisesRegex(ToolError, "legacy sandbox"):
            check_native_config(self.root, {"CODEX_HOME": str(home)})

    def test_legacy_checkout_config_cannot_disable_the_profile(self):
        (self.root / ".codex").mkdir()
        (self.root / ".codex/config.toml").write_text('[sandbox_workspace_write]\nnetwork_access = true\n')
        with self.assertRaisesRegex(ToolError, "legacy sandbox"):
            check_native_config(self.root, {"CODEX_HOME": str(self.root / "unused")})

    def test_landlock_wraps_final_command_after_native_helper(self):
        policy = {"bwrap": "/bin/bwrap", "landlock": "/bin/landlock", "sockets": ["/run/nix.sock"]}
        args = ["--ro-bind", "/", "/", "--argv0", "codex-linux-sandbox", "--",
                "/bin/codex", "--apply-seccomp-then-exec", "--permission-profile", "{}",
                "--", "/bin/zsh", "-c", "echo hello"]
        cmd = bwrap_command(args, policy)
        self.assertEqual(cmd[:len(args) - 1], ["/bin/bwrap", "--disable-userns", *args[:-3]])
        self.assertEqual(cmd[-10:], ["/bin/landlock", "--restrict-sockets", "--socket-fallback", "closed", "--allow",
                                   "/run/nix.sock", "--", "/bin/zsh", "-c", "echo hello"])
        self.assertIn("--disable-userns", cmd[:cmd.index("codex-linux-sandbox")])

    def test_probes_are_forwarded(self):
        self.assertEqual(bwrap_command(["--help"], {"bwrap": "/bin/bwrap"}), ["/bin/bwrap", "--help"])

    def test_empty_socket_list_still_applies_landlock(self):
        args = ["--", "/bin/codex", "--apply-seccomp-then-exec", "--", "/bin/sh"]
        cmd = bwrap_command(args, {"bwrap": "/bin/bwrap", "landlock": "/bin/landlock", "sockets": []})
        self.assertIn("--restrict-sockets", cmd)
        self.assertNotIn("--allow", cmd)

    def test_explicit_open_socket_grant_stays_open(self):
        args = ["--", "/bin/codex", "--apply-seccomp-then-exec", "--", "/bin/sh"]
        cmd = bwrap_command(args, {"bwrap": "/bin/bwrap", "sockets": None})
        self.assertEqual(cmd, ["/bin/bwrap", "--disable-userns", *args])

    def test_local_identity_binds_precede_the_native_helper(self):
        args = ["--", "/bin/codex", "--apply-seccomp-then-exec", "--", "/bin/sh"]
        binds = ["--ro-bind", "/run/policy/passwd", "/etc/passwd"]
        cmd = bwrap_command(args, {"bwrap": "/bin/bwrap", "sockets": None, "identity_binds": binds})
        self.assertEqual(cmd[:5], ["/bin/bwrap", "--disable-userns", *binds])

    def test_missing_native_stage_fails_closed(self):
        with self.assertRaisesRegex(ToolError, "native"):
            bwrap_command(["--", "/bin/zsh"], {"bwrap": "/bin/bwrap", "sockets": []})
