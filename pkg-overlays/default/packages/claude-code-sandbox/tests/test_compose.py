# SPDX-License-Identifier: MIT
"""Composition rules: how a set of sandbox module parts becomes one
settings fragment."""

import json
import tempfile
import unittest
from pathlib import Path

from fixtures import BASE, WORK, WORK_FRAGMENT, write_registry

from claude_code_sandbox.compose import DEVICES_ENV_VAR, SOCKETS_ENV_VAR, compose
from claude_code_sandbox.files import ToolError, read_json


def part(name, **grants):
    return {
        "masked": True,
        "closure": [f"/nix/store/{name}-dep"],
        "path": [f"/nix/store/{name}-farm/bin"],
        **grants,
    }


class ComposeTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.config = Path(self._tmp.name)

    def compose(self, modules, chosen, base_modules=()):
        write_registry(self.config, modules, base_modules=base_modules)
        return compose(read_json(self.config / "registry.json"), chosen)

    def test_single_module(self):
        self.assertEqual(self.compose({"work": WORK}, ["work"]), WORK_FRAGMENT)

    def test_list_grants_union_and_null_stays_absent(self):
        fragment = self.compose(
            {
                "a": part("a", allowedDomains=["a.example", "shared.example"]),
                "b": part("b", allowedDomains=["shared.example", "b.example"]),
                "c": part("c"),
            },
            ["a", "b", "c"],
        )
        self.assertEqual(
            fragment["sandbox"]["network"]["allowedDomains"],
            ["a.example", "shared.example", "b.example"],
        )
        self.assertNotIn("deniedDomains", fragment["sandbox"]["network"])
        self.assertNotIn("excludedCommands", fragment["sandbox"])

    def test_closures_union_into_sorted_allow_read(self):
        fragment = self.compose(
            {"b": part("b", extraAllowRead=["/etc/extra"]), "a": part("a")}, ["a", "b"]
        )
        self.assertEqual(
            fragment["sandbox"]["filesystem"]["allowRead"],
            [
                "/nix/store/a-dep",
                "/nix/store/b-dep",
                "/nix/store/bbb-base",
                "/etc/extra",
            ],
        )

    def test_path_is_wrapper_then_modules_by_name_then_base(self):
        fragment = self.compose({"zed": part("zed"), "alpha": part("alpha")}, ["zed", "alpha"])
        self.assertEqual(
            fragment["env"]["PATH"].split(":"),
            [
                "/nix/store/ssh-wrapper/bin",
                "/nix/store/alpha-farm/bin",
                "/nix/store/zed-farm/bin",
                "/nix/store/base-farm/bin",
                "/nix/store/bwrap/bin",
            ],
        )

    def test_one_unmasked_module_unmasks_the_store(self):
        fragment = self.compose(
            {
                "work": WORK,
                "nix": part(
                    "nix",
                    masked=False,
                    allowWrite=["/home/u/.cache/nix"],
                ),
            },
            ["work", "nix"],
        )
        fs = fragment["sandbox"]["filesystem"]
        self.assertNotIn("denyRead", fs)
        self.assertNotIn("allowRead", fs)
        self.assertEqual(fs["allowWrite"], ["/home/u/.cache/nix"])

    def test_requires_and_base_modules_are_resolved(self):
        fragment = self.compose(
            {
                "git": part("git", allowedDomains=["github.com"]),
                "gh": part("gh", requires=["git"]),
                "claude": part("claude", allowedDomains=["*.anthropic.com"]),
            },
            ["gh"],
            base_modules=["claude"],
        )
        self.assertEqual(
            sorted(fragment["sandbox"]["network"]["allowedDomains"]),
            ["*.anthropic.com", "github.com"],
        )
        self.assertIn("/nix/store/git-farm/bin", fragment["env"]["PATH"])

    def test_requires_cycle_terminates(self):
        fragment = self.compose(
            {"a": part("a", requires=["b"]), "b": part("b", requires=["a"])}, ["a"]
        )
        self.assertIn("/nix/store/b-farm/bin", fragment["env"]["PATH"])

    def test_unknown_required_module_is_an_error(self):
        with self.assertRaisesRegex(ToolError, "unknown sandbox module"):
            self.compose({"a": part("a", requires=["ghost"])}, ["a"])

    def test_socket_allowlist_narrows_through_the_socket_shell(self):
        fragment = self.compose(
            {
                "a": part("a", allowUnixSockets=["/run/a.sock"]),
                "b": part("b", allowUnixSockets=["/run/b.sock"]),
            },
            ["a", "b"],
        )
        net = fragment["sandbox"]["network"]
        self.assertEqual(net["allowUnixSockets"], ["/run/a.sock", "/run/b.sock"])
        self.assertIs(net["allowAllUnixSockets"], True)
        self.assertEqual(fragment["env"]["SHELL"], BASE["socketShell"])
        self.assertEqual(fragment["env"][SOCKETS_ENV_VAR], "/run/a.sock\n/run/b.sock")

    def test_explicit_allow_all_skips_narrowing(self):
        fragment = self.compose(
            {
                "a": part("a", allowUnixSockets=["/run/a.sock"]),
                "b": part("b", allowAllUnixSockets=True),
            },
            ["a", "b"],
        )
        self.assertIs(fragment["sandbox"]["network"]["allowAllUnixSockets"], True)
        self.assertEqual(fragment["env"]["SHELL"], BASE["shell"])
        self.assertNotIn(SOCKETS_ENV_VAR, fragment["env"])

    def test_devices_union_into_the_wrapper_variable(self):
        fragment = self.compose(
            {
                "a": part("a", devices=["/dev/dri/renderD*", "/dev/kfd"]),
                "b": part("b", devices=["/dev/kfd", "/dev/fuse"]),
            },
            ["a", "b"],
        )
        self.assertEqual(fragment["env"][DEVICES_ENV_VAR], "/dev/dri/renderD*\n/dev/kfd\n/dev/fuse")
        self.assertNotIn("devices", fragment["sandbox"])

    def test_no_devices_writes_an_empty_variable(self):
        # A running session applies a changed value and keeps a removed
        # variable, so the empty value is what unbinds the devices of a
        # dropped module.
        fragment = self.compose({"work": WORK, "a": part("a", devices=[])}, ["work", "a"])
        self.assertEqual(fragment["env"][DEVICES_ENV_VAR], "")

    def test_no_sockets_keeps_the_plain_shell(self):
        fragment = self.compose({"work": WORK}, ["work"])
        self.assertEqual(fragment["env"]["SHELL"], BASE["shell"])
        self.assertNotIn("network", fragment["sandbox"])

    def test_env_merges_and_conflicts_are_errors(self):
        fragment = self.compose(
            {"a": part("a", env={"A": "1", "SHARED": "x"}), "b": part("b", env={"SHARED": "x"})},
            ["a", "b"],
        )
        self.assertEqual(fragment["env"]["A"], "1")
        self.assertEqual(fragment["env"]["SHARED"], "x")
        with self.assertRaisesRegex(ToolError, "SHARED"):
            self.compose(
                {"a": part("a", env={"SHARED": "x"}), "b": part("b", env={"SHARED": "y"})},
                ["a", "b"],
            )

    def test_settings_passthrough_merges_and_conflicts_are_errors(self):
        fragment = self.compose(
            {
                "a": part("a", settings={"sandbox": {"autoAllowBashIfSandboxed": True}}),
                "b": part("b", settings={"permissions": {"allow": ["Bash(make:*)"]}}),
                "c": part("c", settings={"permissions": {"allow": ["Bash(just:*)"]}}),
            },
            ["a", "b", "c"],
        )
        self.assertIs(fragment["sandbox"]["autoAllowBashIfSandboxed"], True)
        self.assertIs(fragment["sandbox"]["failIfUnavailable"], True)
        self.assertEqual(
            fragment["permissions"]["allow"], ["Bash(make:*)", "Bash(just:*)"]
        )
        with self.assertRaisesRegex(ToolError, "autoAllowBashIfSandboxed"):
            self.compose(
                {
                    "a": part("a", settings={"sandbox": {"autoAllowBashIfSandboxed": True}}),
                    "b": part("b", settings={"sandbox": {"autoAllowBashIfSandboxed": False}}),
                },
                ["a", "b"],
            )

    def test_settings_lists_of_objects_union(self):
        hook = {"matcher": "Bash", "hooks": [{"type": "command", "command": "x"}]}
        other = {"matcher": "Edit", "hooks": []}
        fragment = self.compose(
            {
                "a": part("a", settings={"hooks": {"PreToolUse": [hook]}}),
                "b": part("b", settings={"hooks": {"PreToolUse": [hook, other]}}),
            },
            ["a", "b"],
        )
        self.assertEqual(fragment["hooks"]["PreToolUse"], [hook, other])

    def test_oversized_fragment_is_an_error(self):
        huge = part("huge")
        huge["closure"] = [f"/nix/store/{i:032d}-dep" for i in range(3000)]
        with self.assertRaisesRegex(ToolError, "E2BIG"):
            self.compose({"huge": huge}, ["huge"])

    def test_parts_are_read_fresh(self):
        # A part changed on disk after a switch is what the next compose
        # sees: nothing is cached between calls.
        paths = write_registry(self.config, {"work": WORK})
        registry = read_json(self.config / "registry.json")
        paths["work"].write_text(json.dumps({**WORK, "allowedDomains": ["new.example"]}))
        fragment = compose(registry, ["work"])
        self.assertEqual(fragment["sandbox"]["network"]["allowedDomains"], ["new.example"])


if __name__ == "__main__":
    unittest.main()
