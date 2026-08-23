# SPDX-License-Identifier: LGPL-3.0-or-later
"""Unit tests for the three-way settings merge."""

import unittest
from typing import Any

from claude_code_sandbox.merge import adhoc_additions, merge

FRAG_A: dict[str, Any] = {
    "sandbox": {
        "enabled": True,
        "failIfUnavailable": True,
        "filesystem": {
            "denyRead": ["/nix/store"],
            "allowRead": ["/nix/store/aaa-hello", "/nix/store/bbb-bash"],
        },
    },
    "env": {"PATH": "/profile-a/bin", "SHELL": "/nix/store/bbb-bash/bin/bash"},
}

FRAG_B: dict[str, Any] = {
    "sandbox": {
        "enabled": True,
        "failIfUnavailable": True,
        "filesystem": {
            "denyRead": ["/nix/store"],
            "allowRead": ["/nix/store/ccc-python", "/nix/store/bbb-bash"],
        },
    },
    "env": {"PATH": "/profile-b/bin", "SHELL": "/nix/store/bbb-bash/bin/bash"},
}


class MergeTest(unittest.TestCase):
    def test_first_enroll_into_empty_file(self):
        merged, report = merge({}, {}, FRAG_A)
        self.assertEqual(merged, FRAG_A)
        self.assertFalse(report.has_findings())

    def test_foreign_top_level_keys_untouched(self):
        current = {"permissions": {"allow": ["WebFetch(domain:example.com)"]}}
        merged, _ = merge(current, {}, FRAG_A)
        self.assertEqual(merged["permissions"], current["permissions"])
        self.assertEqual(merged["sandbox"], FRAG_A["sandbox"])

    def test_interleaved_foreign_keys_inside_owned_subtree(self):
        # The /sandbox panel writes into the sandbox subtree; keys we never
        # applied must survive a retarget.
        current = dict(FRAG_A)
        current["sandbox"] = {**FRAG_A["sandbox"], "autoAllowBashIfSandboxed": True}
        merged, _ = merge(current, FRAG_A, FRAG_B)
        self.assertTrue(merged["sandbox"]["autoAllowBashIfSandboxed"])
        self.assertEqual(
            merged["sandbox"]["filesystem"]["allowRead"],
            FRAG_B["sandbox"]["filesystem"]["allowRead"],
        )

    def test_retarget_removes_old_entries_and_keeps_adhoc(self):
        current = dict(FRAG_A)
        current["sandbox"] = {
            **FRAG_A["sandbox"],
            "filesystem": {
                "denyRead": ["/nix/store"],
                "allowRead": FRAG_A["sandbox"]["filesystem"]["allowRead"]
                + ["/home/user/datasets"],
            },
        }
        merged, report = merge(current, FRAG_A, FRAG_B)
        allow = merged["sandbox"]["filesystem"]["allowRead"]
        self.assertIn("/nix/store/ccc-python", allow)
        self.assertNotIn("/nix/store/aaa-hello", allow)
        self.assertIn("/home/user/datasets", allow)  # ad-hoc persists
        self.assertTrue(any("allowRead" in p for p, _ in report.adhoc_entries))

    def test_hand_removal_does_not_persist(self):
        current = dict(FRAG_A)
        current["sandbox"] = {
            **FRAG_A["sandbox"],
            "filesystem": {
                "denyRead": ["/nix/store"],
                "allowRead": ["/nix/store/aaa-hello"],  # user removed bbb-bash
            },
        }
        merged, _ = merge(current, FRAG_A, FRAG_A)
        self.assertIn(
            "/nix/store/bbb-bash", merged["sandbox"]["filesystem"]["allowRead"]
        )

    def test_scalar_drift_overridden_and_reported(self):
        current = dict(FRAG_A)
        current["env"] = {**FRAG_A["env"], "PATH": "/tampered/bin"}
        merged, report = merge(current, FRAG_A, FRAG_A)
        self.assertEqual(merged["env"]["PATH"], "/profile-a/bin")
        self.assertTrue(
            any(p == "env.PATH" for p, _, _ in report.overridden_scalars)
        )

    def test_abandon_to_empty_fragment_prunes_owned_content(self):
        current = dict(FRAG_A)
        current["permissions"] = {"allow": ["Bash(date:*)"]}
        merged, _ = merge(current, FRAG_A, {})
        self.assertNotIn("sandbox", merged)
        self.assertNotIn("env", merged)
        self.assertIn("permissions", merged)

    def test_abandon_preserves_drifted_scalar(self):
        current = dict(FRAG_A)
        current["env"] = {**FRAG_A["env"], "SHELL": "/custom/shell"}
        merged, report = merge(current, FRAG_A, {})
        self.assertEqual(merged["env"], {"SHELL": "/custom/shell"})
        self.assertTrue(any(p == "env.SHELL" for p, _ in report.preserved_drift))

    def test_idempotent(self):
        merged, _ = merge(FRAG_A, FRAG_A, FRAG_A)
        self.assertEqual(merged, FRAG_A)

    def test_recovery_after_foreign_writer_dropped_keys(self):
        # If a writer clobbered our keys, base subtraction finds nothing and
        # the union re-adds cleanly.
        current = {"permissions": {"allow": ["x"]}}
        merged, _ = merge(current, FRAG_A, FRAG_A)
        self.assertEqual(merged["sandbox"], FRAG_A["sandbox"])
        self.assertEqual(merged["permissions"], {"allow": ["x"]})

    def test_inputs_not_mutated(self):
        current = {"sandbox": {"enabled": True}}
        snapshot = {"sandbox": {"enabled": True}}
        merge(current, FRAG_A, FRAG_B)
        self.assertEqual(current, snapshot)


class AdhocTest(unittest.TestCase):
    def test_reports_extras_within_domain_only(self):
        current = dict(FRAG_A)
        current["sandbox"] = {
            **FRAG_A["sandbox"],
            "filesystem": {
                "denyRead": ["/nix/store"],
                "allowRead": FRAG_A["sandbox"]["filesystem"]["allowRead"]
                + ["/extra"],
            },
        }
        current["permissions"] = {"allow": ["y"]}
        findings = adhoc_additions(current, FRAG_A)
        self.assertEqual(len(findings), 1)
        path, extras = findings[0]
        self.assertIn("allowRead", path)
        self.assertEqual(extras, ["/extra"])


if __name__ == "__main__":
    unittest.main()
