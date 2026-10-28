# SPDX-License-Identifier: MIT
"""The module tools: the decline record and ``show`` in the CLI, and the
agent tools in the MCP server, prompting through a fake claude-consent
and a fake client."""

import contextlib
import io
import json
import os
import queue
import sys
import tempfile
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path
from unittest import mock

from fixtures import WORK, write_registry

from agent_sandbox import cli
from agent_sandbox.mcp import TOOLS, Server

GIT = {
    "description": "git over ssh",
    "masked": True,
    "closure": ["/nix/store/ggg-git"],
    "path": ["/nix/store/git-farm/bin"],
    "packages": ["git-2.50.0"],
    "commands": ["git", "ssh"],
    "allowedDomains": ["github.com"],
}
GITHUB = {
    "description": "the GitHub CLI",
    "requires": ["git"],
    "masked": True,
    "closure": ["/nix/store/hhh-gh"],
    "path": ["/nix/store/gh-farm/bin"],
    "packages": ["gh-2.80.0"],
    "commands": ["gh"],
}
NIX = {
    "description": "nix builds",
    "masked": False,
    "closure": [],
    "path": ["/nix/store/nix-farm/bin"],
    "packages": ["nix-2.31.0"],
    "commands": ["nix"],
    "allowUnixSockets": ["/nix/var/nix/daemon-socket/socket"],
}

# A stand-in for claude-consent: records each call and prints the next
# scripted result. A result with "sleep" waits that long first.
FAKE_CONSENT = """\
import json, sys, time
from pathlib import Path
here = Path(__file__).parent
calls = here / "calls.jsonl"
with calls.open("a") as f:
    f.write(json.dumps({"argv": sys.argv[1:], "stdin": json.load(sys.stdin)}) + "\\n")
script = json.loads((here / "script.json").read_text())
result = script.pop(0)
(here / "script.json").write_text(json.dumps(script))
time.sleep(result.pop("sleep", 0))
print(json.dumps(result))
"""


class ToolsTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        tmp = Path(self._tmp.name)
        self.repo = tmp / "demo"
        (self.repo / ".git").mkdir(parents=True)
        self.config = tmp / "config"
        write_registry(self.config, {"work": WORK, "git": GIT, "github": GITHUB, "nix": NIX})
        self.fake = tmp / "fake"
        self.fake.mkdir()
        consent = self.fake / "claude-consent"
        consent.write_text(f"#!{sys.executable}\n" + FAKE_CONSENT)
        consent.chmod(0o755)
        self.consent_script([])
        self.env = {
            **os.environ,
            "AGENT_SANDBOX_CONFIG": str(self.config),
            "CLAUDE_PROJECT_DIR": str(self.repo),
            "CLAUDE_CODE_SESSION_ID": "0123abcd-0000-0000-0000-000000000000",
            "AGENT_SANDBOX_CONSENT": str(consent),
            "AGENT_SANDBOX_STATE": str(tmp / "state"),
        }
        patcher = mock.patch.dict(
            os.environ,
            {"AGENT_SANDBOX_CONFIG": str(self.config), "AGENT_SANDBOX_STATE": str(tmp / "state")},
        )
        patcher.start()
        self.addCleanup(patcher.stop)

    # --- helpers -----------------------------------------------------------

    def cli(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = cli.main([*argv[:1], "-C", str(self.repo), *argv[1:]])
        return rc, out.getvalue()

    def sidecar(self):
        return json.loads((self.repo / ".agent-sandbox" / "binding.json").read_text())

    def consent_script(self, results):
        (self.fake / "script.json").write_text(json.dumps(results))

    def consent_calls(self):
        path = self.fake / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def server(self, elicit=None, capabilities=None):
        """A server after initialize. ``elicit`` answers each elicitation
        request the server sends (None: the client advertises no
        elicitation)."""
        incoming = queue.Queue()
        sent = []

        def send(msg):
            sent.append(msg)
            if msg.get("method") == "elicitation/create":
                incoming.put({"jsonrpc": "2.0", "id": msg["id"], "result": elicit(msg["params"])})

        server = Server(incoming, send, self.env)
        caps = capabilities if capabilities is not None else ({"elicitation": {"form": {}}} if elicit else {})
        server.handle({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"capabilities": caps}})
        server.incoming_queue = incoming
        server.sent = sent
        return server

    def call(self, server, tool, **arguments):
        before = len(server.sent)
        server.handle(
            {
                "jsonrpc": "2.0",
                "id": 7,
                "method": "tools/call",
                "params": {"name": tool, "arguments": arguments, "_meta": {"claudecode/toolUseId": "toolu_x"}},
            }
        )
        responses = [m for m in server.sent[before:] if m.get("id") == 7]
        if not responses:
            return None
        result = responses[0]["result"]
        text = result["content"][0]["text"]
        try:
            value = json.loads(text)
        except ValueError:
            value = text
        return value, result.get("isError", False)

    # --- CLI ---------------------------------------------------------------

    def test_decline_records_and_status_reports_it(self):
        self.cli("enroll", "work", "--quiet")
        rc, _ = self.cli("decline", "nix", "--reason", "no store access here")
        self.assertEqual(rc, 0)
        refusal = self.sidecar()["declined"]["nix"]
        self.assertEqual(refusal["reason"], "no store access here")
        self.assertIn("at", refusal)
        _, out = self.cli("status")
        self.assertIn("declined [nix]", out)

    def test_declines_survive_sync_and_drop(self):
        self.cli("enroll", "work", "git", "--quiet")
        self.cli("decline", "nix", "--quiet")
        self.cli("sync", "--quiet")
        self.cli("drop", "git", "--quiet")
        self.assertIn("nix", self.sidecar()["declined"])

    def test_adding_a_module_withdraws_its_refusal(self):
        self.cli("enroll", "work", "--quiet")
        self.cli("decline", "nix", "git", "--quiet")
        self.cli("add", "nix", "--quiet")
        self.assertEqual(sorted(self.sidecar()["declined"]), ["git"])
        self.cli("enroll", "git", "--quiet")
        self.assertNotIn("declined", self.sidecar())

    def test_undecline_withdraws(self):
        self.cli("enroll", "work", "--quiet")
        self.cli("decline", "nix", "--quiet")
        self.assertEqual(self.cli("undecline", "nix", "--quiet")[0], 0)
        self.assertNotIn("declined", self.sidecar())
        self.assertEqual(self.cli("undecline", "nix", "--quiet")[0], 1)

    def test_an_enabled_module_cannot_be_declined(self):
        self.cli("enroll", "github", "--quiet")
        # git is enabled because github requires it.
        self.assertEqual(self.cli("decline", "git")[0], 1)
        self.assertNotIn("declined", self.sidecar())

    def test_show_names_the_grants(self):
        self.cli("enroll", "work", "--quiet")
        self.cli("decline", "nix", "--reason", "too wide", "--quiet")
        _, out = self.cli("show", "github", "nix")
        self.assertIn("Commands put on PATH: gh", out)
        self.assertIn("Enabling it also enables: git", out)
        self.assertIn("Unmasks the whole Nix store", out)
        self.assertIn("Unix sockets reachable: /nix/var/nix/daemon-socket/socket", out)
        self.assertIn("Declined for this checkout at", out)
        self.assertIn("too wide", out)

    def test_show_and_describe_name_trusted_executables(self):
        socket = "/home/u/.local/state/agent-sandbox/trusted/gh.sock"
        forge = {
            "description": "gh with the user's token",
            "masked": True,
            "closure": ["/nix/store/sss-stub"],
            "path": ["/nix/store/forge-farm/bin"],
            "packages": [],
            "commands": ["gh"],
            "allowUnixSockets": [socket],
            "trustedExecutables": [
                {
                    "name": "gh",
                    "description": "the GitHub CLI",
                    "program": "/nix/store/hhh-gh/bin/gh",
                    "args": ["--"],
                    "workingDirectory": None,
                    "passEnv": ["GH_REPO"],
                    "socket": socket,
                }
            ],
        }
        write_registry(self.config, {"work": WORK, "forge": forge})
        _, out = self.cli("show", "forge")
        self.assertIn(
            "Trusted executable gh: runs /nix/store/hhh-gh/bin/gh -- OUTSIDE the sandbox, "
            "in the working directory of the caller, with the arguments and stdin of the "
            "caller and the variables GH_REPO (the GitHub CLI)",
            out,
        )
        self.assertIn(f"Unix sockets reachable: {socket}", out)
        value, _ = self.call(self.server(), "describe-module", module="forge")
        self.assertEqual(value["trustedExecutables"][0]["program"], "/nix/store/hhh-gh/bin/gh")

    # --- MCP: protocol and read tools --------------------------------------

    def test_tools_list(self):
        server = self.server()
        server.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        names = [t["name"] for t in server.sent[-1]["result"]["tools"]]
        self.assertEqual(names, [t["name"] for t in TOOLS])
        self.assertEqual(
            names, ["list-modules", "enabled-modules", "describe-module", "declined-modules", "request-module"]
        )

    def test_unknown_method_is_an_error(self):
        server = self.server()
        server.handle({"jsonrpc": "2.0", "id": 1, "method": "resources/list"})
        self.assertEqual(server.sent[-1]["error"]["code"], -32601)

    def test_list_modules_reports_status(self):
        self.cli("enroll", "github", "--quiet")
        self.cli("decline", "nix", "--quiet")
        value, error = self.call(self.server(), "list-modules")
        self.assertFalse(error)
        status = {row["name"]: row["status"] for row in value["modules"]}
        self.assertEqual(
            status,
            {
                "git": "enabled (required by github)",
                "github": "enabled",
                "nix": "declined",
                "work": "available",
            },
        )

    def test_enabled_modules(self):
        self.cli("enroll", "github", "--quiet")
        value, _ = self.call(self.server(), "enabled-modules")
        self.assertEqual(value["enrollment"], "enrolled")
        self.assertEqual(value["chosen"], ["github"])
        self.assertEqual(value["enabled"], {"github": "chosen", "git": "required by github"})
        self.assertIn("current", value["status"])

    def test_enabled_modules_when_not_enrolled(self):
        value, error = self.call(self.server(), "enabled-modules")
        self.assertFalse(error)
        self.assertEqual(value["enrollment"], "not enrolled")

    def test_describe_module(self):
        self.cli("enroll", "work", "--quiet")
        value, _ = self.call(self.server(), "describe-module", module="github")
        self.assertEqual(value["commands"], ["gh"])
        self.assertEqual(value["alsoEnables"], ["git"])
        self.assertEqual(value["status"], "available")
        value, error = self.call(self.server(), "describe-module", module="nope")
        self.assertTrue(error)
        self.assertIn("unknown sandbox module", value)

    def test_declined_modules(self):
        self.cli("enroll", "work", "--quiet")
        self.cli("decline", "nix", "--reason", "too wide", "--quiet")
        value, _ = self.call(self.server(), "declined-modules")
        self.assertEqual(value["declined"]["nix"]["reason"], "too wide")
        value, _ = self.call(self.server(), "declined-modules", module="git")
        self.assertIs(value["declined"], False)

    # --- MCP: request-module ------------------------------------------------

    def test_request_enabled_module_does_not_prompt(self):
        self.cli("enroll", "github", "--quiet")
        value, error = self.call(self.server(), "request-module", module="git", reason="push")
        self.assertFalse(error)
        self.assertIn("already enabled", value)
        self.assertEqual(self.consent_calls(), [])

    def test_request_declined_module_does_not_prompt(self):
        self.cli("enroll", "work", "--quiet")
        self.cli("decline", "nix", "--reason", "too wide", "--quiet")
        value, error = self.call(self.server(), "request-module", module="nix", reason="build")
        self.assertFalse(error)
        self.assertIn("declined nix", value)
        self.assertIn("too wide", value)
        self.assertEqual(self.consent_calls(), [])

    def test_request_needs_enrollment(self):
        value, error = self.call(self.server(), "request-module", module="nix", reason="build")
        self.assertTrue(error)
        self.assertIn("not enrolled", value)

    def test_request_needs_a_reason(self):
        self.cli("enroll", "work", "--quiet")
        _value, error = self.call(self.server(), "request-module", module="nix", reason="  ")
        self.assertTrue(error)

    def test_consent_answer_enable_enables(self):
        self.cli("enroll", "work", "--quiet")
        self.consent_script([{"status": "answered", "value": "enable"}])
        value, error = self.call(self.server(), "request-module", module="github", reason="open a PR")
        self.assertFalse(error, value)
        self.assertIn("enabled github", value)
        self.assertIn("/stop", value)
        self.assertEqual(self.sidecar()["modules"], ["github", "work"])
        settings = json.loads((self.repo / ".claude" / "settings.local.json").read_text())
        self.assertIn("/nix/store/gh-farm/bin", settings["env"]["PATH"])
        self.assertIn("/nix/store/git-farm/bin", settings["env"]["PATH"])

        (call,) = self.consent_calls()
        argv = call["argv"]
        self.assertEqual(argv[0], "ask")
        self.assertEqual(argv[argv.index("--session") + 1], self.env["CLAUDE_CODE_SESSION_ID"])
        detail = argv[argv.index("--detail") + 1]
        self.assertIn("The agent's reason: open a PR", detail)
        self.assertIn("Commands put on PATH: gh", detail)
        self.assertIn("Enabling it also enables: git", detail)
        self.assertNotIn("--fallback", argv)  # this client cannot elicit
        self.assertEqual(call["stdin"]["tool_use_id"], "toolu_x")
        self.assertEqual(call["stdin"]["cwd"], str(self.repo))

    def test_consent_answer_decline_records_the_reason(self):
        self.cli("enroll", "work", "--quiet")
        self.consent_script([{"status": "answered", "value": "decline", "text": "not in this repo"}])
        value, _ = self.call(self.server(), "request-module", module="nix", reason="build")
        self.assertIn("declined nix", value)
        self.assertEqual(self.sidecar()["declined"]["nix"]["reason"], "not in this repo")
        self.assertEqual(self.sidecar()["modules"], ["work"])

    def test_not_now_and_timeout_record_nothing(self):
        self.cli("enroll", "work", "--quiet")
        self.consent_script([{"status": "answered", "value": "later"}, {"status": "timeout", "id": "x", "deadline": 900}])
        value, _ = self.call(self.server(), "request-module", module="nix", reason="build")
        self.assertIn("not now", value)
        value, _ = self.call(self.server(), "request-module", module="nix", reason="build")
        self.assertIn("did not answer", value)
        self.assertNotIn("declined", self.sidecar())
        self.assertEqual(self.sidecar()["modules"], ["work"])

    def test_the_question_key_ignores_the_reason(self):
        # A re-issued request consumes an answer stored for the first
        # one, so its key cannot depend on the agent's wording.
        self.cli("enroll", "work", "--quiet")
        self.consent_script([{"status": "answered", "value": "later"}] * 2)
        self.call(self.server(), "request-module", module="nix", reason="build")
        self.call(self.server(), "request-module", module="nix", reason="build it now")
        keys = [c["argv"][c["argv"].index("--key") + 1] for c in self.consent_calls()]
        self.assertEqual(keys[0], keys[1])

    def test_no_answerer_elicits_in_the_client(self):
        self.cli("enroll", "work", "--quiet")
        self.consent_script([{"status": "fallback", "value": "elicit"}])
        asked = []

        def elicit(params):
            asked.append(params)
            return {"action": "accept", "content": {"decision": "decline", "reason": "use the CI"}}

        value, _ = self.call(self.server(elicit), "request-module", module="nix", reason="build")
        self.assertIn("declined nix", value)
        self.assertEqual(self.sidecar()["declined"]["nix"]["reason"], "use the CI")
        self.assertIn("Unmasks the whole Nix store", asked[0]["message"])
        (call,) = self.consent_calls()
        self.assertEqual(call["argv"][call["argv"].index("--fallback") + 1], "elicit")

    def test_elicitation_enable(self):
        self.cli("enroll", "work", "--quiet")
        self.consent_script([{"status": "fallback", "value": "elicit"}])
        server = self.server(lambda _: {"action": "accept", "content": {"decision": "enable permanently"}})
        value, _ = self.call(server, "request-module", module="nix", reason="build")
        self.assertIn("enabled nix", value)
        self.assertEqual(self.sidecar()["modules"], ["nix", "work"])
        self.assertNotIn("expires", self.sidecar())

    def test_elicitation_enable_for_a_day(self):
        self.cli("enroll", "work", "--quiet")
        self.consent_script([{"status": "fallback", "value": "elicit"}])
        server = self.server(lambda _: {"action": "accept", "content": {"decision": "enable for a day"}})
        value, _ = self.call(server, "request-module", module="nix", reason="build")
        self.assertIn("enabled nix", value)
        self.assertIn(" until ", value)
        self.assertEqual(list(self.sidecar()["expires"]), ["nix"])

    def test_the_prompt_offers_a_day_a_week_and_permanently(self):
        self.cli("enroll", "work", "--quiet")
        self.consent_script([{"status": "answered", "value": "week"}])
        value, _ = self.call(self.server(), "request-module", module="nix", reason="build")
        (call,) = self.consent_calls()
        options = [call["argv"][i + 1] for i, a in enumerate(call["argv"]) if a == "--option"]
        self.assertEqual(
            options[:3], ["day=Enable for a day", "week=Enable for a week", "enable=Enable permanently"]
        )
        self.assertIn(" until ", value)
        at = datetime.fromisoformat(self.sidecar()["expires"]["nix"])
        self.assertAlmostEqual((at - datetime.now(UTC)).total_seconds(), 7 * 86400, delta=60)

    def test_an_expired_module_is_asked_for_again(self):
        self.cli("enroll", "work", "--quiet")
        self.cli("add", "nix", "--for", "day", "--quiet")
        later = datetime.now(UTC) + timedelta(days=2)
        self.consent_script([{"status": "answered", "value": "later"}])
        with mock.patch.object(cli, "_now", return_value=later):
            value, _ = self.call(self.server(), "request-module", module="nix", reason="build")
        self.assertIn("not now", value)
        self.assertEqual(len(self.consent_calls()), 1)
        self.assertEqual(self.sidecar()["modules"], ["work"])

    def test_cancelled_elicitation_stores_the_question(self):
        # Headless sessions cancel an elicitation at once; the question
        # then goes to the spool for a terminal answer.
        self.cli("enroll", "work", "--quiet")
        self.consent_script(
            [
                {"status": "fallback", "value": "elicit"},
                {"status": "pending", "id": "0123abcd-1-2-ff", "mode": "stored"},
            ]
        )
        server = self.server(lambda _: {"action": "cancel"})
        value, _ = self.call(server, "request-module", module="nix", reason="build")
        self.assertIn("claude-consent answer 0123abcd-1-2-ff", value)
        first, second = self.consent_calls()
        self.assertIn("--fallback", first["argv"])
        self.assertNotIn("--fallback", second["argv"])
        self.assertEqual(self.sidecar()["modules"], ["work"])
        self.assertNotIn("declined", self.sidecar())

    def test_elicitation_decline_action_is_a_refusal(self):
        self.cli("enroll", "work", "--quiet")
        self.consent_script([{"status": "fallback", "value": "elicit"}])
        server = self.server(lambda _: {"action": "decline"})
        self.call(server, "request-module", module="nix", reason="build")
        self.assertNotIn("reason", self.sidecar()["declined"]["nix"])

    def test_cancelling_the_call_stops_the_prompt(self):
        self.cli("enroll", "work", "--quiet")
        self.consent_script([{"status": "answered", "value": "enable", "sleep": 30}])
        server = self.server()
        server.incoming_queue.put({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 7}})
        self.assertIsNone(self.call(server, "request-module", module="nix", reason="build"))
        self.assertEqual(self.sidecar()["modules"], ["work"])

    def test_requests_arriving_during_a_prompt_are_served_after_it(self):
        self.cli("enroll", "work", "--quiet")
        self.consent_script([{"status": "answered", "value": "later", "sleep": 0.5}])
        server = self.server()
        server.incoming_queue.put({"jsonrpc": "2.0", "id": 8, "method": "ping"})
        self.call(server, "request-module", module="nix", reason="build")
        server.incoming_queue.put(None)
        self.assertEqual(server.run(), 0)
        self.assertEqual([m.get("id") for m in server.sent[-2:]], [7, 8])

    def test_end_of_input_during_a_prompt_stops_the_server(self):
        self.cli("enroll", "work", "--quiet")
        self.consent_script([{"status": "answered", "value": "enable", "sleep": 30}])
        server = self.server()
        server.incoming_queue.put(None)
        self.assertIsNone(self.call(server, "request-module", module="nix", reason="build"))
        self.assertEqual(server.run(), 0)
        self.assertEqual(self.sidecar()["modules"], ["work"])


if __name__ == "__main__":
    unittest.main()
