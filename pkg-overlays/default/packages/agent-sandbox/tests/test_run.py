# SPDX-License-Identifier: MIT
"""`agent-sandbox run`: the srt settings and the command a whole agent
runs under, composed from the checkout's modules and the agent's own."""

import json
import io
import os
import socket
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path
from unittest import mock

from agent_sandbox.cli import main
from agent_sandbox.codex import permission_profile_id
from agent_sandbox.files import ToolError
from agent_sandbox.run import grant_socket, native_enrollment_root, prepare, sandboxed_command, srt_settings
from fixtures import BASE, WORK, write_registry

AGENT_PART = {
    "description": "the agent itself",
    "masked": True,
    "closure": ["/nix/store/ccc-agent"],
    "path": ["/nix/store/agent-farm/bin"],
    # setUp names a directory of the test here, which does not exist yet.
    "allowWrite": [],
    "allowedDomains": ["api.example.com"],
}

SOCKETS_PART = {
    "description": "a socket",
    "masked": True,
    "allowUnixSockets": ["/run/thing.sock"],
}

RUN_BASE = {**BASE, "setsid": "/nix/store/util-linux/bin/setsid", "bwrap": "/nix/store/bwrap-wrapper/bin/bwrap",
            "configMerger": shutil.which("agent-config")}

EXTRA = {
    "srt": "/nix/store/srt/bin/srt",
    "guards": [".claude/settings.local.json", ".agent-sandbox/binding.json", "/state/expiring.json"],
    "agents": {
        "coder": {
            "modules": ["agent"],
            "args": ["-c", 'sandbox_mode="danger-full-access"'],
            "env": {"CODER_PATH": "/nix/store/shim/bin/coder"},
        }
    },
}


class RunTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        tmp = Path(self._tmp.name)
        self.config = tmp / "config"
        self.root = tmp / "repo"
        (self.root / ".git").mkdir(parents=True)
        self.runtime = tmp / "runtime"
        self.agent_state = tmp / "home" / ".agent"
        self.agent_part = {**AGENT_PART, "allowWrite": [str(self.agent_state)]}
        write_registry(
            self.config,
            {"work": WORK, "agent": self.agent_part, "sockets": SOCKETS_PART},
            base=RUN_BASE,
            extra=EXTRA,
        )
        self.env = mock.patch.dict(
            os.environ,
            {
                "AGENT_SANDBOX_CONFIG": str(self.config),
                "AGENT_SANDBOX_STATE": str(tmp / "state"),
                "XDG_RUNTIME_DIR": str(self.runtime),
            },
        )
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self._tmp.cleanup()

    def enroll(self, *modules):
        self.assertEqual(main(["enroll", "-C", str(self.root), *modules, "--quiet"]), 0)

    def test_unenrolled_checkout_runs_unchanged(self):
        self.assertIsNone(prepare("coder", ["/bin/coder"], self.root, False))

    def test_outside_any_checkout_runs_unchanged(self):
        self.assertIsNone(prepare("coder", ["/bin/coder"], Path("/"), False))

    def test_enrolled_checkout_runs_under_srt(self):
        self.enroll("work")
        argv, env, server = prepare("coder", ["/bin/coder", "exec", "hi"], self.root, False)
        self.assertIsNone(server)
        self.assertNotIn("AGENT_SANDBOX_EMACS_MCP", env)
        self.assertEqual(argv[:2], ["/nix/store/srt/bin/srt", "--settings"])
        self.assertEqual(
            argv[3:],
            ["--", "/bin/coder", "-c", 'sandbox_mode="danger-full-access"', "exec", "hi"],
        )
        settings = json.loads(Path(argv[2]).read_text())
        fs = settings["filesystem"]
        self.assertEqual(fs["denyRead"], ["/nix/store"])
        for path in ("/nix/store/aaa-hello", "/nix/store/bbb-base", "/nix/store/ccc-agent"):
            self.assertIn(path, fs["allowRead"])
        self.assertEqual(fs["allowWrite"][:2], [str(self.root), env["TMPDIR"]])
        self.assertIn(str(self.agent_state), fs["allowWrite"])
        # A granted directory that did not exist is created before the
        # sandbox starts, because srt can grant only a path that exists.
        self.assertTrue(self.agent_state.is_dir())
        self.assertEqual(
            fs["denyWrite"],
            [
                str(self.root / ".claude/settings.local.json"),
                str(self.root / ".agent-sandbox/binding.json"),
                "/state/expiring.json",
            ],
        )
        self.assertEqual(settings["network"]["allowedDomains"], ["api.example.com"])
        self.assertEqual(settings["bwrapPath"], "/nix/store/bwrap-wrapper/bin/bwrap")
        self.assertIn("/nix/store/agent-farm/bin", env["PATH"])
        self.assertEqual(env["AGENT_SANDBOX_ROOT"], str(self.root))
        self.assertEqual(env["CODER_PATH"], "/nix/store/shim/bin/coder")
        self.assertTrue(Path(env["TMPDIR"]).is_dir())
        self.assertEqual(env["CLAUDE_CODE_TMPDIR"], env["TMPDIR"])
        self.assertEqual(env["TMPPREFIX"], str(Path(env["TMPDIR"]) / "zsh"))
        self.assertNotIn(str(Path(argv[2]).parent), fs["allowWrite"])

    def test_no_network_unless_a_module_allows_it(self):
        settings = srt_settings({"sandbox": {}}, self.root, [], self.root / "tmp", None)
        self.assertEqual(settings["network"], {"allowedDomains": [], "deniedDomains": []})
        self.assertNotIn("bwrapPath", settings)

    def test_unknown_agent_is_an_error(self):
        self.enroll("work")
        with self.assertRaises(ToolError):
            prepare("nobody", ["/bin/x"], self.root, False)

    def test_local_binding_grant_survives_composition_adapter(self):
        fragment = {"sandbox": {"network": {"allowLocalBinding": True}}}
        settings = srt_settings(fragment, self.root, [], self.root / "tmp", None)
        self.assertTrue(settings["network"]["allowLocalBinding"])

    def test_codex_uses_native_profile_without_parent_landlock(self):
        base = {**RUN_BASE, "cli": "/bin/agent-sandbox", "landlock": "/bin/landlock"}
        write_registry(self.config, {"work": WORK, "agent": self.agent_part}, base=base,
                       extra={**EXTRA, "agents": {"codex": {"backend": "codex", "modules": ["agent"]}}})
        self.enroll("work")
        argv, env, server = prepare("codex", ["/bin/codex", "exec", "hi"], self.root, False)
        self.assertIsNone(server)
        self.assertEqual(argv[0], "/bin/codex")
        self.assertEqual(argv[-2:], ["exec", "hi"])
        self.assertNotIn(BASE["socketShell"], argv)
        self.assertNotIn('sandbox_mode="danger-full-access"', argv)
        self.assertIn(f'default_permissions="{permission_profile_id(self.root)}"', argv)
        policy = json.loads(Path(env["AGENT_SANDBOX_CODEX_POLICY"]).read_text())
        self.assertEqual(policy["sockets"], [])
        self.assertEqual(policy["config"]["approval_policy"], "on-request")
        shell_env = policy["config"]["shell_environment_policy"]["set"]
        self.assertEqual(shell_env["TMPDIR"], env["TMPDIR"])
        self.assertEqual(shell_env["TMPPREFIX"], str(Path(env["TMPDIR"]) / "zsh"))
        wrapper = Path(env["PATH"].split(":")[0]) / "bwrap"
        self.assertIn("codex-bwrap --policy", wrapper.read_text())
        self.assertNotIn(str(wrapper.parent), policy["path"])
        persisted = tomllib.loads((self.root / ".codex/config.toml").read_text())
        self.assertEqual(persisted["permissions"], policy["config"]["permissions"])
        self.assertEqual(persisted["shell_environment_policy"]["set"], {
            "SANDBOX_RUNTIME": "1", "AGENT_SANDBOX_ROOT": str(self.root),
            "PATH": policy["path"],
        })
        self.assertNotIn(str(Path(env["TMPDIR"]).parent), json.dumps(persisted))

    def test_codex_disk_scratch_keeps_runtime_control_path(self):
        disk = self.root.parent / "disk-scratch"
        base = {**RUN_BASE, "cli": "/bin/agent-sandbox", "landlock": "/bin/landlock",
                "nativeTmpRoot": str(disk)}
        write_registry(self.config, {"work": WORK, "agent": self.agent_part}, base=base,
                       extra={**EXTRA, "agents": {"codex": {"backend": "codex", "modules": ["agent"]}}})
        self.enroll("work")
        _, env, _ = prepare("codex", ["/bin/codex"], self.root, False)
        scratch = Path(env["TMPDIR"])
        self.assertTrue(scratch.is_symlink())
        self.assertEqual(scratch.resolve().parent, disk)
        self.assertEqual(Path(env["AGENT_SANDBOX_CODEX_POLICY"]).parent, scratch.parent)
        (scratch / "preserved").write_text("live")
        _, again, _ = prepare("codex", ["/bin/codex"], self.root, False)
        self.assertEqual(again["TMPDIR"], str(scratch))
        self.assertEqual((scratch / "preserved").read_text(), "live")

    def test_codex_enrollment_stays_out_of_git_status(self):
        # The fixture's bare `.git` directory is enough for root discovery
        # but not for `git rev-parse`; make it a real repository.
        shutil.rmtree(self.root / ".git")
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        base = {**RUN_BASE, "cli": "/bin/agent-sandbox", "landlock": "/bin/landlock"}
        write_registry(self.config, {"work": WORK, "agent": self.agent_part}, base=base,
                       extra={**EXTRA, "agents": {"codex": {"backend": "codex", "modules": ["agent"]}}})
        self.enroll("work")
        self.enroll("work")
        self.assertTrue((self.root / ".codex/config.toml").is_file())
        exclude = (self.root / ".git/info/exclude").read_text()
        self.assertEqual(exclude.splitlines().count("/.codex/config.toml"), 1)
        status = subprocess.run(["git", "-C", str(self.root), "status", "--porcelain", "--", ".codex"],
                                capture_output=True, text=True, check=True).stdout
        self.assertEqual(status, "")

    def test_codex_acp_child_gets_the_same_native_profile(self):
        base = {**RUN_BASE, "cli": "/bin/agent-sandbox", "landlock": "/bin/landlock"}
        write_registry(self.config, {"work": WORK, "agent": self.agent_part}, base=base,
                       extra={**EXTRA, "agents": {"codex-acp": {
                           "backend": "codex", "modules": ["agent"], "env": {"CODEX_PATH": "/bin/native-child"}}}})
        self.enroll("work")
        argv, env, _ = prepare("codex-acp", ["/bin/codex-acp"], self.root, False)
        self.assertEqual(argv, ["/bin/codex-acp"])
        self.assertEqual(env["CODEX_PATH"], "/bin/native-child")
        self.assertTrue(Path(env["AGENT_SANDBOX_CODEX_POLICY"]).is_file())

    def test_sync_and_abandon_update_native_enrollment_without_runtime_state(self):
        base = {**RUN_BASE, "cli": "/bin/agent-sandbox", "landlock": "/bin/landlock"}
        extra = {**EXTRA, "agents": {"codex": {"backend": "codex", "modules": ["agent"]}}}
        write_registry(self.config, {"work": WORK, "agent": self.agent_part}, base=base, extra=extra)
        (self.root / ".codex").mkdir()
        config = self.root / ".codex/config.toml"
        config.write_text('# user preference\nmodel = "chosen-model"\n')
        self.enroll("work")
        updated = {**self.agent_part, "allowedDomains": ["new.example.com"]}
        write_registry(self.config, {"work": WORK, "agent": updated}, base=base, extra=extra)
        self.assertEqual(main(["sync", "-C", str(self.root), "--quiet"]), 0)
        value = tomllib.loads(config.read_text())
        domains = value["permissions"][permission_profile_id(self.root)]["network"]["domains"]
        self.assertEqual(domains["new.example.com"], "allow")
        self.assertNotIn("api.example.com", domains)
        self.assertFalse(self.runtime.exists())
        self.assertEqual(main(["abandon", "-C", str(self.root), "--quiet"]), 0)
        self.assertEqual(tomllib.loads(config.read_text()), {"model": "chosen-model"})
        self.assertIn("# user preference", config.read_text())

    def test_native_worktree_inherits_primary_enrollment_and_git_metadata(self):
        base = {**RUN_BASE, "cli": "/bin/agent-sandbox", "landlock": "/bin/landlock"}
        extra = {**EXTRA, "agents": {"codex": {"backend": "codex", "modules": ["agent"]}}}
        write_registry(self.config, {"work": {**WORK, "allowGit": True}, "agent": self.agent_part},
                       base=base, extra=extra)
        self.enroll("work")
        linked = self.root.parent / "linked"
        linked.mkdir()
        metadata = self.root / ".git/worktrees/linked"
        metadata.mkdir(parents=True)
        (linked / ".git").write_text(f"gitdir: {metadata}\n")
        (metadata / "commondir").write_text("../..\n")
        (metadata / "gitdir").write_text(str(linked / ".git"))
        self.assertEqual(native_enrollment_root(linked), self.root)
        _, env, _ = prepare("codex", ["/bin/codex"], linked, False)
        profile = tomllib.loads((linked / ".codex/config.toml").read_text())
        fs = profile["permissions"][permission_profile_id(linked)]["filesystem"]
        self.assertEqual(fs[str(self.root / ".git")], "write")
        self.assertEqual(fs[str(metadata)], "write")
        self.assertEqual(fs[str(linked)], "write")
        self.assertEqual(fs[str(linked / ".agent-sandbox/binding.json")], "read")
        self.assertFalse((linked / ".agent-sandbox/binding.json").exists())
        self.assertEqual(main(["sync", "-C", str(linked), "--quiet"]), 0)
        self.assertEqual(tomllib.loads((linked / ".codex/config.toml").read_text()), profile)
        # Native missing-file guards may leave a zero-byte placeholder,
        # including while another command is using that guarded path.
        (linked / ".agent-sandbox/binding.json").write_text("")
        self.assertEqual(native_enrollment_root(linked), self.root)
        self.assertEqual(main(["sync", "-C", str(linked), "--quiet"]), 0)
        (metadata / "gitdir").write_text(str(self.root / ".git"))
        with self.assertRaises(ToolError):
            native_enrollment_root(linked)
        (metadata / "gitdir").write_text(str(linked / ".git"))
        # Changing the primary enrollment must eagerly propagate both
        # additions and removals without a separate worktree sync.
        parts = {"work": {**WORK, "allowGit": True}, "agent": self.agent_part,
                 "internet": {"masked": True, "allowedDomains": ["*"]}}
        write_registry(self.config, parts, base=base, extra=extra)
        self.assertEqual(main(["add", "-C", str(self.root), "internet", "--quiet"]), 0)
        updated = tomllib.loads((linked / ".codex/config.toml").read_text())
        self.assertEqual(updated["permissions"][permission_profile_id(linked)]["network"]["domains"]["*"], "allow")
        self.assertEqual(main(["drop", "-C", str(self.root), "internet", "--quiet"]), 0)
        updated = tomllib.loads((linked / ".codex/config.toml").read_text())
        self.assertNotIn("*", updated["permissions"][permission_profile_id(linked)]["network"]["domains"])
        # Primary abandonment clears inherited grants; re-enrollment must
        # still recognize a native empty guard left in the worktree.
        self.assertEqual(main(["abandon", "-C", str(self.root), "--quiet"]), 0)
        self.assertNotIn("permissions", tomllib.loads((linked / ".codex/config.toml").read_text()))
        self.assertEqual(main(["enroll", "-C", str(self.root), "work", "--quiet"]), 0)
        self.assertIn("permissions", tomllib.loads((linked / ".codex/config.toml").read_text()))
        # An explicit local abandonment stops inheritance.
        self.assertEqual(main(["enroll", "-C", str(linked), "work", "--quiet"]), 0)
        self.assertEqual(main(["abandon", "-C", str(linked), "--quiet"]), 0)
        self.assertIsNone(prepare("codex", ["/bin/codex"], linked, False))
        before = (linked / ".codex/config.toml").read_text()
        self.assertEqual(main(["add", "-C", str(self.root), "internet", "--quiet"]), 0)
        self.assertEqual((linked / ".codex/config.toml").read_text(), before)

    def test_git_pointer_without_back_registration_cannot_inherit(self):
        self.enroll("work")
        linked = self.root.parent / "unregistered"
        linked.mkdir()
        metadata = self.root / ".git/worktrees/forged"
        metadata.mkdir(parents=True)
        (linked / ".git").write_text(f"gitdir: {metadata}\n")
        (metadata / "commondir").write_text("../..\n")
        (metadata / "gitdir").write_text(str(self.root / ".git"))
        self.assertEqual(native_enrollment_root(linked), linked)

    def test_git_metadata_permission_follows_module_dependencies(self):
        base = {**RUN_BASE, "cli": "/bin/agent-sandbox", "landlock": "/bin/landlock"}
        work = {**WORK, "requires": ["git"]}
        write_registry(self.config, {"work": work, "git": {**WORK, "allowGit": True},
                                     "agent": self.agent_part}, base=base,
                       extra={**EXTRA, "agents": {"codex": {"backend": "codex", "modules": ["agent"]}}})
        self.enroll("work")
        _, env, _ = prepare("codex", ["/bin/codex"], self.root, False)
        fs = json.loads(Path(env["AGENT_SANDBOX_CODEX_POLICY"]).read_text())["config"]["permissions"][permission_profile_id(self.root)]["filesystem"]
        self.assertEqual(fs[str(self.root / ".git")], "write")

    def test_terminal_runs_through_setsid(self):
        cmd = sandboxed_command(["/bin/a", "x"], {}, {}, RUN_BASE, True)
        self.assertEqual(cmd, ["/nix/store/util-linux/bin/setsid", "-w", "-c", "/bin/a", "x"])

    def test_socket_allowlist_narrows_the_agent_itself(self):
        self.enroll("work", "sockets")
        argv, _, _ = prepare("coder", ["/bin/coder"], self.root, True)
        cmd = argv[4:]
        self.assertEqual(cmd[:3], ["/nix/store/util-linux/bin/setsid", "-w", "-c"])
        self.assertEqual(cmd[3:6], [BASE["socketShell"], "-c", 'exec "$0" "$@"'])
        self.assertEqual(cmd[6], "/bin/coder")
        settings = json.loads(Path(argv[2]).read_text())
        self.assertEqual(settings["network"]["allowUnixSockets"], ["/run/thing.sock"])
        self.assertTrue(settings["network"]["allowAllUnixSockets"])

    def test_emacs_mcp_is_served_on_a_socket_of_the_run(self):
        # A bridge that reports where it runs and echoes one line.
        bridge = [sys.executable, "-c", "import os, sys; print(os.getcwd()); print(sys.stdin.readline().strip())"]
        write_registry(
            self.config,
            {"work": WORK, "agent": self.agent_part},
            base=RUN_BASE,
            extra={**EXTRA, "emacsMcp": bridge},
        )
        self.enroll("work")
        argv, env, server = prepare("coder", ["/bin/coder"], self.root, False)
        self.addCleanup(server.close)
        sock_path = env["AGENT_SANDBOX_EMACS_MCP"]
        self.assertEqual(Path(sock_path).parent, Path(argv[2]).parent)
        settings = json.loads(Path(argv[2]).read_text())
        self.assertEqual(settings["network"]["allowUnixSockets"], [sock_path])
        self.assertTrue(settings["network"]["allowAllUnixSockets"])
        self.assertEqual(env["AGENT_SANDBOX_UNIX_SOCKETS"], sock_path)
        self.assertIn(BASE["socketShell"], argv)

        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.connect(sock_path)
            conn.sendall(b"hello\n")
            reply = b""
            while reply.count(b"\n") < 2:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                reply += chunk
        self.assertEqual(reply.decode().splitlines(), [str(self.root), "hello"])

    def test_granting_a_socket_keeps_an_open_allowance_open(self):
        fragment = {"sandbox": {"network": {"allowAllUnixSockets": True}}, "env": {}}
        grant_socket(fragment, "/run/x.sock")
        self.assertEqual(fragment["sandbox"]["network"]["allowUnixSockets"], ["/run/x.sock"])
        self.assertNotIn("AGENT_SANDBOX_UNIX_SOCKETS", fragment["env"])

    def test_granting_a_socket_joins_the_allowlist(self):
        fragment = {
            "sandbox": {"network": {"allowUnixSockets": ["/run/a.sock"], "allowAllUnixSockets": True}},
            "env": {"AGENT_SANDBOX_UNIX_SOCKETS": "/run/a.sock"},
        }
        grant_socket(fragment, "/run/x.sock")
        self.assertEqual(fragment["env"]["AGENT_SANDBOX_UNIX_SOCKETS"], "/run/a.sock\n/run/x.sock")

    def test_dead_runs_are_pruned(self):
        self.enroll("work")
        stale = self.runtime / "agent-sandbox" / "run-999999999" / "tmp"
        stale.mkdir(parents=True)
        (stale / "f").write_text("x")
        prepare("coder", ["/bin/coder"], self.root, False)
        self.assertFalse(stale.parent.exists())


    def test_cleanup_failure_does_not_prevent_a_new_run(self):
        self.enroll("work")
        stale = self.runtime / "agent-sandbox/run-999999999/tmp"
        stale.mkdir(parents=True)
        with mock.patch("agent_sandbox.run.shutil.rmtree", side_effect=PermissionError("read-only build tree")), \
                mock.patch("sys.stderr", new_callable=io.StringIO) as errors:
            argv, env, _ = prepare("coder", ["/bin/coder"], self.root, False)
        self.assertEqual(argv[0], "/nix/store/srt/bin/srt")
        self.assertTrue(Path(env["TMPDIR"]).is_dir())
        self.assertIn("continuing launch", errors.getvalue())

    def test_cleanup_does_not_follow_a_run_symlink(self):
        self.enroll("work")
        outside = self.root.parent / "outside-scratch"
        outside.mkdir()
        marker = outside / "keep"
        marker.write_text("keep")
        runs = self.runtime / "agent-sandbox"
        runs.mkdir(parents=True)
        (runs / "run-999999999").symlink_to(outside, target_is_directory=True)
        prepare("coder", ["/bin/coder"], self.root, False)
        self.assertEqual(marker.read_text(), "keep")

    def test_native_helpers_survive_dashboard_launcher_exit(self):
        self.enroll("work")
        old = self.runtime / "agent-sandbox/run-2147483647"
        (old / "tmp").mkdir(parents=True)
        (old / "codex.json").write_text("{}")
        (old / "tmp/still-in-use").write_text("shared-server thread")
        with mock.patch("agent_sandbox.run.os.kill", side_effect=ProcessLookupError):
            prepare("coder", ["/bin/coder"], self.root, False)
        self.assertEqual((old / "tmp/still-in-use").read_text(), "shared-server thread")

    def test_read_only_build_directory_does_not_block_startup(self):
        self.enroll("work")
        locked = self.runtime / "agent-sandbox/run-999999999/tmp/build/src"
        locked.mkdir(parents=True)
        (locked / "purifier_native.cc").write_text("source")
        locked.chmod(0o555)
        try:
            with mock.patch("sys.stderr", new_callable=io.StringIO) as errors:
                argv, env, _ = prepare("coder", ["/bin/coder"], self.root, False)
            self.assertEqual(argv[0], "/nix/store/srt/bin/srt")
            self.assertTrue(Path(env["TMPDIR"]).is_dir())
            self.assertIn("continuing launch", errors.getvalue())
            self.assertEqual(locked.stat().st_mode & 0o777, 0o555)
        finally:
            locked.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
