# SPDX-License-Identifier: MIT
"""`agent-sandbox run`: the srt settings and the command a whole agent
runs under, composed from the checkout's modules and the agent's own."""

import json
import os
import socket
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from agent_sandbox.cli import main
from agent_sandbox.files import ToolError
from agent_sandbox.run import grant_socket, prepare, sandboxed_command, srt_settings
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

RUN_BASE = {**BASE, "setsid": "/nix/store/util-linux/bin/setsid", "bwrap": "/nix/store/bwrap-wrapper/bin/bwrap"}

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
        self.assertIn('default_permissions="agent-sandbox"', argv)
        policy = json.loads(Path(env["AGENT_SANDBOX_CODEX_POLICY"]).read_text())
        self.assertEqual(policy["sockets"], [])
        self.assertEqual(policy["config"]["approval_policy"], "on-request")
        shell_env = policy["config"]["shell_environment_policy"]["set"]
        self.assertEqual(shell_env["TMPDIR"], env["TMPDIR"])
        self.assertEqual(shell_env["TMPPREFIX"], str(Path(env["TMPDIR"]) / "zsh"))
        wrapper = Path(env["PATH"].split(":")[0]) / "bwrap"
        self.assertIn("codex-bwrap --policy", wrapper.read_text())
        self.assertNotIn(str(wrapper.parent), policy["path"])

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

    def test_git_metadata_permission_follows_module_dependencies(self):
        base = {**RUN_BASE, "cli": "/bin/agent-sandbox", "landlock": "/bin/landlock"}
        work = {**WORK, "requires": ["git"]}
        write_registry(self.config, {"work": work, "git": {**WORK, "allowGit": True},
                                     "agent": self.agent_part}, base=base,
                       extra={**EXTRA, "agents": {"codex": {"backend": "codex", "modules": ["agent"]}}})
        self.enroll("work")
        _, env, _ = prepare("codex", ["/bin/codex"], self.root, False)
        fs = json.loads(Path(env["AGENT_SANDBOX_CODEX_POLICY"]).read_text())["config"]["permissions"]["agent-sandbox"]["filesystem"]
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


if __name__ == "__main__":
    unittest.main()
