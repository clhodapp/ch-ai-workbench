# SPDX-License-Identifier: MIT
"""Integrity detection: applied content missing from the settings file
(any cause, such as a hand edit or a tooling accident) must be visible to
status as CLOBBERED (attention) and repaired by a plain sync."""

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from fixtures import WORK, WORK_FRAGMENT, write_registry

from agent_sandbox import cli


class ClobberTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        tmp = Path(self._tmp.name)
        self.repo = tmp / "projects" / "demo"
        (self.repo / ".git").mkdir(parents=True)
        config = tmp / "config"
        write_registry(config, {"work": WORK})
        patcher = mock.patch.dict(
            os.environ, {"AGENT_SANDBOX_CONFIG": str(config)}
        )
        patcher.start()
        self.addCleanup(patcher.stop)
        cli.main(["enroll", "work", "-C", str(self.repo), "--quiet"])
        self.settings_file = self.repo / ".claude" / "settings.local.json"

    def clobber(self):
        # Simulate a foreign writer replacing the file with only its keys.
        self.settings_file.write_text(
            json.dumps({"permissions": {"allow": ["Bash(date:*)"]}})
        )

    def test_status_flags_clobbered_file(self):
        self.assertEqual(cli.main(["status", "-C", str(self.repo)]), 0)
        self.clobber()
        self.assertEqual(cli.main(["status", "-C", str(self.repo)]), 2)

    def test_sync_repairs_and_preserves_foreign_keys(self):
        self.clobber()
        self.assertEqual(cli.main(["sync", "-C", str(self.repo), "--quiet"]), 0)
        settings = json.loads(self.settings_file.read_text())
        self.assertEqual(settings["sandbox"], WORK_FRAGMENT["sandbox"])
        self.assertEqual(settings["permissions"], {"allow": ["Bash(date:*)"]})
        self.assertEqual(cli.main(["status", "-C", str(self.repo)]), 0)

    def test_partial_clobber_detected(self):
        # Writer kept the sandbox key but dropped env.
        content = json.loads(self.settings_file.read_text())
        del content["env"]
        self.settings_file.write_text(json.dumps(content))
        self.assertEqual(cli.main(["status", "-C", str(self.repo)]), 2)


if __name__ == "__main__":
    unittest.main()
