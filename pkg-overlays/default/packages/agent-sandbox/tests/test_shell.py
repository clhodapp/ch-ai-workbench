# SPDX-License-Identifier: MIT
"""The rules the srt step of the bash chain reads, written at enroll and
sync time, and the domain forms srt accepts."""

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from agent_sandbox.cli import main
from agent_sandbox.run import srt_domain, srt_domains
from fixtures import WORK, write_registry
from test_run import AGENT_PART, EXTRA, RUN_BASE, SOCKETS_PART

OPEN_PART = {
    "description": "every host",
    "masked": True,
    "allowedDomains": ["*", "productionresultssa*.blob.core.windows.net"],
}


class SrtDomainTest(unittest.TestCase):
    def test_plain_and_leading_wildcards_are_kept(self):
        for entry in ("example.com", "*.example.com", "127.0.0.2:8091", "[::1]:80", "::1"):
            self.assertEqual(srt_domain(entry), entry)

    def test_mid_label_wildcard_widens_to_a_leading_one(self):
        self.assertEqual(srt_domain("productionresultssa*.blob.core.windows.net"), "*.blob.core.windows.net")
        self.assertEqual(srt_domain("a.b*.example.com:443"), "*.example.com:443")

    def test_wildcard_over_too_few_labels_has_no_form(self):
        self.assertIsNone(srt_domain("foo*.com"))

    def test_star_grants_every_host_and_is_left_out(self):
        self.assertEqual(srt_domains(["*", "a.com", "x*.b.c.d", "y*.b.c.d"]), (["a.com", "*.b.c.d"], True))
        self.assertEqual(srt_domains(["a.com"]), (["a.com"], False))


class ShellRulesTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        tmp = Path(self._tmp.name)
        self.config = tmp / "config"
        self.root = tmp / "repo"
        (self.root / ".git").mkdir(parents=True)
        self.runtime = tmp / "runtime"
        agent_part = {**AGENT_PART, "allowWrite": [str(tmp / "home" / ".agent")]}
        write_registry(
            self.config,
            {"work": WORK, "agent": agent_part, "sockets": SOCKETS_PART, "open": OPEN_PART},
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

    def rules(self) -> dict:
        return json.loads((self.root / ".agent-sandbox" / "shell-coder.json").read_text())

    def test_abandoned_checkout_has_no_rules(self):
        self.assertEqual(main(["enroll", "-C", str(self.root), "work", "--quiet"]), 0)
        self.assertEqual(main(["abandon", "-C", str(self.root), "--quiet"]), 0)
        self.assertFalse((self.root / ".agent-sandbox" / "shell-coder.json").exists())

    def test_adding_a_module_rewrites_the_rules(self):
        self.assertEqual(main(["enroll", "-C", str(self.root), "work", "--quiet"]), 0)
        self.assertFalse(self.rules()["allowAll"])
        self.assertEqual(main(["add", "-C", str(self.root), "open", "--quiet"]), 0)
        self.assertTrue(self.rules()["allowAll"])

    def test_enrolled_checkout_writes_rules(self):
        self.assertEqual(main(["enroll", "-C", str(self.root), "work", "--quiet"]), 0)
        rules = self.rules()
        self.assertFalse(rules["allowAll"])
        self.assertEqual(rules["settings"]["network"]["allowedDomains"], ["api.example.com"])
        self.assertEqual(rules["settings"]["bwrapPath"], RUN_BASE["bwrap"])
        self.assertEqual(rules["shell"], RUN_BASE["shell"])
        self.assertEqual(rules["env"]["AGENT_SANDBOX_ROOT"], str(self.root))
        self.assertEqual(rules["env"]["TMPDIR"], rules["scratch"])
        self.assertTrue(rules["scratch"].startswith(str(self.runtime)))
        self.assertEqual(rules["settings"]["filesystem"]["allowWrite"][:2], [str(self.root), rules["scratch"]])

    def test_socket_grants_use_the_socket_restriction_step(self):
        self.assertEqual(main(["enroll", "-C", str(self.root), "work", "sockets", "--quiet"]), 0)
        self.assertEqual(self.rules()["shell"], RUN_BASE["socketRestriction"])

    def test_star_sets_allow_all(self):
        self.assertEqual(main(["enroll", "-C", str(self.root), "work", "open", "--quiet"]), 0)
        rules = self.rules()
        self.assertTrue(rules["allowAll"])
        self.assertNotIn("*", rules["settings"]["network"]["allowedDomains"])
        self.assertIn("*.blob.core.windows.net", rules["settings"]["network"]["allowedDomains"])


if __name__ == "__main__":
    unittest.main()
