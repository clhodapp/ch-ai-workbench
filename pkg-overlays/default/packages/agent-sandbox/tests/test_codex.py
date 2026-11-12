# SPDX-License-Identifier: MIT
"""Native Codex policy compilation and the post-mount socket boundary."""

import tempfile
import json
import os
import unittest
from unittest import mock
from pathlib import Path

from agent_sandbox.codex import (bwrap_command, check_native_config, configuration,
                                permission_profile_id, policy_for_command, private_tmp_bindings, socket_boundary_command, refresh_runtime_command_environment)
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
        profile = config["permissions"][permission_profile_id(self.root)]
        self.assertEqual(profile["extends"], ":workspace")
        fs = profile["filesystem"]
        self.assertEqual(fs[":slash_tmp"], "read")
        self.assertEqual(fs[":tmpdir"], "write")
        self.assertNotIn(str(self.scratch), fs)
        self.assertEqual(fs["/state/tool"], "write")
        self.assertEqual(fs["/nix/store"], "deny")
        self.assertEqual(fs["/nix/store/tool"], "read")
        self.assertEqual(fs[str(self.root / ".agent-sandbox/binding.json")], "read")
        self.assertEqual(fs[str(self.scratch.parent.parent)], "read")

    def test_network_is_native_and_deny_wins(self):
        config = configuration(self.settings, self.root, self.scratch)
        self.assertTrue(config["features"]["network_proxy"])
        net = config["permissions"][permission_profile_id(self.root)]["network"]
        self.assertTrue(net["enabled"])
        self.assertEqual(net["domains"]["github.com"], "allow")
        self.assertEqual(net["domains"]["blocked.github.com"], "deny")
        self.assertEqual(net["unix_sockets"], {"/run/nix.sock": "allow"})

    def test_public_internet_wildcard_keeps_explicit_domain_denials(self):
        self.settings["network"]["allowedDomains"] = ["*"]
        config = configuration(self.settings, self.root, self.scratch)
        net = config["permissions"][permission_profile_id(self.root)]["network"]
        self.assertEqual(net["domains"], {"*": "allow", "blocked.github.com": "deny"})
        self.assertEqual(config["permissions"][permission_profile_id(self.root)]["filesystem"]["/nix/store"], "deny")

    def test_profile_does_not_change_between_launches(self):
        import copy
        settings = copy.deepcopy(self.settings)
        settings["filesystem"]["allowWrite"].append(str(self.scratch))
        settings["network"]["allowUnixSockets"].append(str(self.scratch.parent / "emacs-mcp.sock"))
        first = configuration(settings, self.root, self.scratch)
        another = self.scratch.parent.parent / "another-run/tmp"
        settings["filesystem"]["allowWrite"] = [
            str(another) if p == str(self.scratch) else p
            for p in settings["filesystem"]["allowWrite"]
        ]
        settings["network"]["allowUnixSockets"][-1] = str(another.parent / "emacs-mcp.sock")
        self.assertEqual(first, configuration(settings, self.root, another))

    def test_two_clones_do_not_share_a_profile_identity(self):
        other = self.root.parent / "clone-two"
        first = configuration(self.settings, self.root, self.scratch)
        second = configuration(self.settings, other, self.scratch)
        self.assertNotEqual(first["default_permissions"], second["default_permissions"])

    def test_command_environment_overrides_cached_native_environment(self):
        args = ["--setenv", "PATH", "/stale/gh", "--", "/bin/codex",
                "--apply-seccomp-then-exec", "--", "/bin/sh", "-c", "gh auth status"]
        policy = {"bwrap": "/bin/bwrap", "sockets": None,
                  "command_env": {"PATH": "/enrolled/github/bin", "SANDBOX_RUNTIME": "1"}}
        command = bwrap_command(args, policy)
        self.assertGreater(command.index("/enrolled/github/bin"), command.index("/stale/gh"))
        self.assertLess(command.index("/enrolled/github/bin"), command.index("--"))
        self.assertEqual(command[-3:], ["/bin/sh", "-c", "gh auth status"])

    def test_udev_bridge_runs_after_native_helper_and_socket_confinement(self):
        env = {"LD_PRELOAD": "/nix/store/bridge/lib/libudev-monitor-bridge.so",
               "AGENT_SANDBOX_UDEV_SOCKET": "/state/udev.sock"}
        config = configuration(self.settings, self.root, self.scratch, module_env=env)
        self.assertEqual(config["shell_environment_policy"]["set"]["LD_PRELOAD"], env["LD_PRELOAD"])
        args = ["--", "/bin/codex", "--apply-seccomp-then-exec", "--", "/bin/sh"]
        policy = {"bwrap": "/bin/bwrap", "landlock": "/bin/landlock", "sockets": ["/state/udev.sock"], "command_env": env}
        command = bwrap_command(args, policy)
        self.assertGreater(command.index("/nix/store/bridge/bin/udev-monitor-exec"), command.index("/bin/landlock"))
        self.assertGreater(command.index(env["LD_PRELOAD"]), command.index("--apply-seccomp-then-exec"))
        policy["sockets"] = []
        with self.assertRaisesRegex(ToolError, "socket allowlist"):
            bwrap_command(args, policy)

    def test_udev_sync_updates_only_explicit_broker_capability(self):
        runtime = self.root.parent / "udev-runtimes"
        old = runtime / "run-789"
        (old / "bin").mkdir(parents=True)
        old.chmod(0o700)
        config = configuration(self.settings, self.root, self.scratch, command_path="/old/bin")
        policy_file = old / "codex.json"
        policy_file.write_text(json.dumps({"config": config, "sockets": ["/run/old.sock"]}))
        import copy
        settings = copy.deepcopy(self.settings)
        settings["network"]["allowUnixSockets"].append("/state/udev.sock")
        env = {"LD_PRELOAD": "/nix/store/tool/lib/bridge.so", "AGENT_SANDBOX_UDEV_SOCKET": "/state/udev.sock"}
        new = configuration(settings, self.root, self.scratch, command_path="/old/bin", module_env=env)
        with mock.patch("agent_sandbox.run.runtime_dir", return_value=runtime):
            refresh_runtime_command_environment(self.root, new, {"shell": "/bin/sh", "cli": "/cli"})
        value = json.loads(policy_file.read_text())
        self.assertEqual(value["sockets"], ["/run/nix.sock", "/run/old.sock", "/state/udev.sock"])
        self.assertEqual(value["config"], config)
        # A later sync dropping the capability must revoke it while
        # preserving transient launch sockets and the original config.
        with mock.patch("agent_sandbox.run.runtime_dir", return_value=runtime):
            refresh_runtime_command_environment(self.root, config, {"shell": "/bin/sh", "cli": "/cli"})
        dropped = json.loads(policy_file.read_text())
        self.assertNotIn("/state/udev.sock", dropped["sockets"])
        self.assertIn("/run/old.sock", dropped["sockets"])

    def test_moved_thread_uses_only_its_guarded_new_clones_socket_grants(self):
        other = self.root.parent / "moved"
        (other / ".agent-sandbox").mkdir(parents=True)
        manifest = other / ".agent-sandbox/codex-config.json"
        binding = other / ".agent-sandbox/binding.json"
        binding.write_text(json.dumps({"modules": ["a16"], "applied": {}}))
        config = configuration(self.settings, other, self.scratch, command_path="/new/tools")
        config["permissions"][permission_profile_id(other)]["network"]["unix_sockets"] = {"/run/a16.sock": "allow"}
        manifest.write_text(json.dumps({"target": str(other / ".codex/config.toml"), "applied": config}))
        native = {"file_system": {"entries": [{"path": {"type": "path", "path": str(p)}, "access": "read"} for p in (manifest, binding)]}}
        args = ["--sandbox-policy-cwd", str(other), "--permission-profile", json.dumps(native)]
        old = {"command_env": {"AGENT_SANDBOX_ROOT": str(self.root)}, "sockets": ["/run/old.sock"]}
        result = policy_for_command(args, old)
        self.assertEqual(result["sockets"], ["/run/a16.sock"])
        self.assertEqual(result["path"], "/new/tools")
        self.assertEqual(old["sockets"], ["/run/old.sock"])
        tail = ["--allow", "/run/old.sock", "--", "/bin/target"]
        argv, env = socket_boundary_command(tail, "/bin/landlock", old["command_env"], cwd=other, guarded=True)
        self.assertIn("/run/a16.sock", argv)
        self.assertNotIn("/run/old.sock", argv)
        self.assertEqual(env["AGENT_SANDBOX_ROOT"], str(other))
        with self.assertRaisesRegex(ToolError, "read-only enrollment"):
            socket_boundary_command(tail, "/bin/landlock", old["command_env"], cwd=other, guarded=False)
        config["shell_environment_policy"]["set"]["AGENT_SANDBOX_ROOT"] = str(self.root)
        manifest.write_text(json.dumps({"target": str(other / ".codex/config.toml"), "applied": config}))
        binding.write_text("{}")  # native synthetic guard, not a real binding
        inherited, _ = socket_boundary_command(tail, "/bin/landlock", old["command_env"], cwd=other, guarded=False)
        self.assertEqual(inherited, ["/bin/landlock", *tail])
        nested = other / ".scratch/cabal-native"
        nested.mkdir(parents=True)
        binding.write_text("")  # exact stale native placeholder observed
        inherited, _ = socket_boundary_command(tail, "/bin/landlock", old["command_env"], cwd=nested, guarded=False)
        self.assertEqual(inherited, ["/bin/landlock", *tail])
        nested_args = ["--sandbox-policy-cwd", str(other), "--command-cwd", str(nested)]
        self.assertIs(policy_for_command(nested_args, old), old)
        binding.write_text(json.dumps({"modules": ["a16"], "applied": {}}))
        config["shell_environment_policy"]["set"]["AGENT_SANDBOX_ROOT"] = str(other)
        manifest.write_text(json.dumps({"target": str(other / ".codex/config.toml"), "applied": config}))
        native["file_system"]["entries"] = []
        args[-1] = json.dumps(native)
        with self.assertRaisesRegex(ToolError, "read-only guards"):
            policy_for_command(args, old)

    def test_secret_environment_cannot_be_persisted_in_runtime_policy(self):
        args = ["--", "/bin/codex", "--apply-seccomp-then-exec", "--", "/bin/sh"]
        with self.assertRaisesRegex(ToolError, "command environment"):
            bwrap_command(args, {"bwrap": "/bin/bwrap", "sockets": None,
                                 "command_env": {"GH_TOKEN": "not-a-real-token"}})

    def test_sync_repairs_only_the_owning_clones_cached_runtime(self):
        runtime = self.root.parent / "runtimes"
        old = runtime / "run-123"
        (old / "bin").mkdir(parents=True)
        old.chmod(0o700)
        wrapper = old / "bin/bwrap"
        wrapper.write_text("old launcher")
        config = configuration(self.settings, self.root, self.scratch, command_path="/old/gh")
        policy_file = old / "codex.json"
        policy_file.write_text(json.dumps({"config": config, "sockets": ["/run/allowed.sock"]}))
        new = configuration(self.settings, self.root, self.scratch, command_path="/enrolled/github/bin")
        base = {"shell": "/bin/sh", "cli": "/current/agent-sandbox", "nativeBwrap": "/current/native-bwrap"}
        with mock.patch("agent_sandbox.run.runtime_dir", return_value=runtime):
            refresh_runtime_command_environment(self.root.parent / "unrelated", new, base)
            self.assertEqual(wrapper.read_text(), "old launcher")
            refresh_runtime_command_environment(self.root, new, base)
        value = json.loads(policy_file.read_text())
        self.assertEqual(value["command_env"]["PATH"], "/enrolled/github/bin")
        self.assertEqual(value["bwrap"], "/current/native-bwrap")
        self.assertEqual(value["sockets"], ["/run/allowed.sock", "/run/nix.sock"])
        self.assertEqual(value["config"], config)
        self.assertIn("/current/agent-sandbox", wrapper.read_text())
        self.assertEqual(wrapper.stat().st_mode & 0o777, 0o500)

    def test_runtime_path_refresh_cannot_outrun_a_store_mask(self):
        runtime = self.root.parent / "masked-runtimes"
        old = runtime / "run-456"
        (old / "bin").mkdir(parents=True)
        old.chmod(0o700)
        (old / "bin/bwrap").write_text("old launcher")
        config = configuration(self.settings, self.root, self.scratch, command_path="/old/gh")
        policy_file = old / "codex.json"
        policy_file.write_text(json.dumps({"config": config}))
        import copy
        settings = copy.deepcopy(self.settings)
        settings["filesystem"]["allowRead"].append("/nix/store/new-gh")
        new = configuration(settings, self.root, self.scratch, command_path="/nix/store/new-gh/bin")
        with mock.patch("agent_sandbox.run.runtime_dir", return_value=runtime):
            refresh_runtime_command_environment(self.root, new, {"shell": "/bin/sh", "cli": "/new/cli"})
        self.assertNotIn("command_env", json.loads(policy_file.read_text()))
        self.assertEqual((old / "bin/bwrap").read_text(), "old launcher")

    def test_git_override_is_opt_in_and_keeps_explicit_guards(self):
        self.assertNotIn(str(self.root / ".git"),
                         configuration(self.settings, self.root, self.scratch)["permissions"][permission_profile_id(self.root)]["filesystem"])
        fs = configuration(self.settings, self.root, self.scratch, git_write=True)["permissions"][permission_profile_id(self.root)]["filesystem"]
        self.assertEqual(fs[str(self.root / ".git")], "write")
        self.assertEqual(fs[str(self.root / ".agent-sandbox/binding.json")], "read")
        self.settings["filesystem"]["denyWrite"].append(str(self.root / ".git"))
        fs = configuration(self.settings, self.root, self.scratch, git_write=True)["permissions"][permission_profile_id(self.root)]["filesystem"]
        self.assertNotEqual(fs.get(str(self.root / ".git")), "write")

    def test_git_pointer_only_reopens_metadata_with_existing_write_grants(self):
        metadata = self.root / "metadata/worktree"
        metadata.mkdir(parents=True)
        (metadata / "commondir").write_text("..\n")
        (self.root / ".git").write_text("gitdir: metadata/worktree\n")
        fs = configuration(self.settings, self.root, self.scratch, git_write=True)["permissions"][permission_profile_id(self.root)]["filesystem"]
        self.assertEqual(fs[str(metadata)], "write")
        # The common dir is not necessarily a .git directory; resolve
        # the Git pointer rather than assuming a checkout layout.
        self.assertEqual(fs[str(metadata.parent)], "write")
        outside = Path(self.tmp.name) / "other-repo"
        outside.mkdir()
        (self.root / ".git").write_text(f"gitdir: {outside}\n")
        fs = configuration(self.settings, self.root, self.scratch, git_write=True)["permissions"][permission_profile_id(self.root)]["filesystem"]
        self.assertNotIn(str(outside), fs)
        (self.root / ".git").unlink()
        (self.root / ".git").symlink_to(outside, target_is_directory=True)
        fs = configuration(self.settings, self.root, self.scratch, git_write=True)["permissions"][permission_profile_id(self.root)]["filesystem"]
        self.assertNotIn(str(self.root / ".git"), fs)

    def test_no_domains_means_no_network(self):
        self.settings["network"] = {}
        config = configuration(self.settings, self.root, self.scratch)
        self.assertFalse(config["permissions"][permission_profile_id(self.root)]["network"]["enabled"])

    def test_port_scoped_domain_is_not_silently_widened(self):
        self.settings["network"]["allowedDomains"] = ["example.com:8443"]
        with self.assertRaisesRegex(ToolError, "port"):
            configuration(self.settings, self.root, self.scratch)

    def test_local_tests_enable_isolated_network_without_external_domains(self):
        self.settings["network"] = {"allowLocalBinding": True}
        network = configuration(self.settings, self.root, self.scratch)["permissions"][permission_profile_id(self.root)]["network"]
        self.assertTrue(network["enabled"])
        self.assertTrue(network["allow_local_binding"])
        self.assertEqual(network.get("domains", {}), {})

    def test_explicit_local_binding_denial_is_preserved(self):
        self.settings["network"]["allowLocalBinding"] = False
        network = configuration(self.settings, self.root, self.scratch)["permissions"][permission_profile_id(self.root)]["network"]
        self.assertFalse(network["allow_local_binding"])

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

    def test_legacy_temp_adapter_sets_device_wrapper_recursion_guard(self):
        from argparse import Namespace
        from agent_sandbox.cli import cmd_codex_temp_bwrap

        policy = self.root / "policy.json"
        policy.write_text("{}")
        args = Namespace(policy=str(policy), bwrap="/device-wrapper/bwrap",
                         agent_command=["--", "--version"])
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch("os.execve") as execute:
            cmd_codex_temp_bwrap(args)
        execute.assert_called_once_with("/device-wrapper/bwrap",
                                        ["/device-wrapper/bwrap", "--version"],
                                        {"AGENT_SANDBOX_NATIVE_BWRAP_ACTIVE": "1"})

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

    def test_private_tmp_aliases_require_current_scratch_write_grant(self):
        native = {"file_system": {"entries": [{
            "access": "write", "path": {"type": "special", "value": {"kind": "tmpdir"}},
        }]}}
        args = ["--ro-bind", "/", "/", "--", "/bin/codex", "--apply-seccomp-then-exec",
                "--permission-profile", json.dumps(native), "--", "/bin/sh"]
        policy = {"bwrap": "/bin/bwrap", "sockets": None, "config": {
            "shell_environment_policy": {"set": {"TMPDIR": str(self.scratch)}},
        }}
        with mock.patch("agent_sandbox.codex.Path.is_dir", return_value=True):
            command = bwrap_command(args, policy)
        mounts = ["--bind", str(self.scratch), "/tmp", "--bind", str(self.scratch), "/var/tmp"]
        index = command.index("--bind")
        self.assertEqual(command[index:index + 6], mounts)
        self.assertLess(index, command.index("--"))
        self.assertEqual(private_tmp_bindings(command[1:], policy), [])
        native["file_system"]["entries"][0]["access"] = "read"
        args[args.index("--permission-profile") + 1] = json.dumps(native)
        self.assertNotIn("--bind", bwrap_command(args, policy))

    def test_missing_native_stage_fails_closed(self):
        with self.assertRaisesRegex(ToolError, "native"):
            bwrap_command(["--", "/bin/zsh"], {"bwrap": "/bin/bwrap", "sockets": []})
