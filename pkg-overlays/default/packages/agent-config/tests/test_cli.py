# SPDX-License-Identifier: MIT
"""The CLI against real files: sidecar bases, symlinked targets, modes,
and the formats."""

import json
import os
import stat
import tempfile
import unittest
from pathlib import Path

from agent_config.cli import ToolError, apply, main


class CliTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        self.sidecar = self.dir / "state" / "t.json"

    def tearDown(self):
        self._tmp.cleanup()

    def run_apply(self, fmt, target, fragment):
        frag = self.dir / "fragment.json"
        frag.write_text(json.dumps(fragment))
        return main(
            [
                "apply",
                "--format",
                fmt,
                "--target",
                str(target),
                "--fragment",
                str(frag),
                "--sidecar",
                str(self.sidecar),
            ]
        )

    def test_new_file_is_0600_and_sidecar_records_target(self):
        target = self.dir / "cfg" / "settings.json"
        self.assertEqual(self.run_apply("json", target, {"a": 1}), 0)
        self.assertEqual(json.loads(target.read_text()), {"a": 1})
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
        recorded = json.loads(self.sidecar.read_text())
        self.assertEqual(recorded, {"target": str(target), "applied": {"a": 1}})

    def test_second_apply_removes_what_the_first_applied(self):
        target = self.dir / "settings.json"
        target.write_text(json.dumps({"mine": True}))
        self.run_apply("json", target, {"a": 1, "b": 2})
        self.run_apply("json", target, {"a": 1})
        self.assertEqual(json.loads(target.read_text()), {"mine": True, "a": 1})

    def test_existing_mode_is_kept(self):
        target = self.dir / "settings.json"
        target.write_text("{}")
        os.chmod(target, 0o644)
        self.run_apply("json", target, {"a": 1})
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o644)

    def test_symlinked_target_becomes_a_regular_file(self):
        store = self.dir / "store-config.json"
        store.write_text(json.dumps({"model": "x"}))
        os.chmod(store, 0o444)
        target = self.dir / "opencode.json"
        target.symlink_to(store)
        self.run_apply("json", target, {"model": "x"})
        self.assertFalse(target.is_symlink())
        self.assertEqual(json.loads(target.read_text()), {"model": "x"})
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
        self.assertEqual(json.loads(store.read_text()), {"model": "x"})

    def test_sidecar_for_another_target_is_not_a_base(self):
        target = self.dir / "settings.json"
        self.sidecar.parent.mkdir(parents=True)
        self.sidecar.write_text(json.dumps({"target": "/elsewhere", "applied": {"a": 1}}))
        target.write_text(json.dumps({"a": 1}))
        self.run_apply("json", target, {})
        self.assertEqual(json.loads(target.read_text()), {"a": 1})

    def test_toml_target_keeps_comments(self):
        target = self.dir / "config.toml"
        target.write_text('# mine\nmodel = "o3"\n')
        self.run_apply("toml", target, {"mcp_servers": {"emacs": {"command": "e"}}})
        text = target.read_text()
        self.assertTrue(text.startswith('# mine\nmodel = "o3"\n'))
        self.assertIn("[mcp_servers.emacs]", text)

    def test_toml_rejects_null(self):
        with self.assertRaises(ToolError):
            apply("toml", self.dir / "c.toml", {"a": None}, self.sidecar, "t")

    def test_invalid_json_target_is_an_error_and_untouched(self):
        target = self.dir / "settings.json"
        target.write_text("{not json")
        self.assertEqual(self.run_apply("json", target, {"a": 1}), 1)
        self.assertEqual(target.read_text(), "{not json")

    def test_dry_run_writes_nothing(self):
        target = self.dir / "settings.json"
        merged, _ = apply("json", target, {"a": 1}, self.sidecar, "t", dry_run=True)
        self.assertEqual(json.loads(merged), {"a": 1})
        self.assertFalse(target.exists())
        self.assertFalse(self.sidecar.exists())


if __name__ == "__main__":
    unittest.main()
