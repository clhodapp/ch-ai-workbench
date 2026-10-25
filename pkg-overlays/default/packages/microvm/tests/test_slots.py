# SPDX-License-Identifier: MIT
"""The leases and the command line against a fake systemctl, a fake
/proc and a fake vsock probe: claiming a free slot, using a held slot
again, waiting for a guest through its hybrid vsock socket, the end of
the wait at a permission error, refusing to stop a slot another live session holds, reaping the
slots of holders that are gone, the holding process of each verb, the
kinds agents may use, and the refusal of every argument that is not a
verb or a configured name."""

from __future__ import annotations

import contextlib
import io
import json
import unittest

from fixture import FakeVmm, Fixture, stat_line  # noqa: F401
from microvm_slots import cli, transport
from microvm_slots.slots import Caller, Refused, start_time
from microvm_slots.transport import Endpoint


class SlotsCase(Fixture):
    def test_start_time_reads_field_22_past_a_command_with_parentheses(self) -> None:
        (self.proc / "7").mkdir()
        (self.proc / "7" / "stat").write_text(stat_line(7, "999", comm="a) (b c"))
        self.assertEqual(start_time(self.proc, 7), "999")
        self.assertIsNone(start_time(self.proc, 8))

    def test_slots_come_from_the_kinds(self) -> None:
        slots, _ = self.slots()
        self.assertEqual(slots.kinds["probe"], ["probe-1", "probe-2"])
        self.assertEqual(
            slots.slots["probe-2"],
            {
                "kind": "probe",
                "index": 2,
                "cid": 102,
                "vsockSocket": None,
                "vsockPort": 5000,
                "shares": [
                    {"name": "in", "source": "/var/lib/probe/probe-2/in", "readOnly": True},
                    {"name": "out", "source": "/var/lib/probe/probe-2/out", "readOnly": False},
                ],
            },
        )
        self.assertEqual(slots.slots["quiet-1"]["shares"], [])
        agents, _ = self.slots(agents_only=True)
        self.assertEqual(sorted(agents.kinds), ["other", "probe", "quiet"])
        self.assertNotIn("hidden-1", agents.slots)

    def test_up_claims_a_free_slot_and_records_the_holder(self) -> None:
        caller = self.process(1000)
        slots, out = self.slots()
        self.assertEqual(slots.up("probe", caller), "probe-1")
        lease = self.lease("probe-1")
        self.assertEqual(
            {k: lease[k] for k in ("slot", "kind", "session", "pid", "start")},
            {"slot": "probe-1", "kind": "probe", "session": "session-1000", "pid": 1000, "start": "4242"},
        )
        self.assertEqual(
            self.calls(),
            [
                ["--no-ask-password", "stop", "microvm@probe-1.service"],
                ["--no-ask-password", "start", "microvm@probe-1.service"],
            ],
        )
        text = out.getvalue()
        self.assertIn("slot probe-1 (kind probe)", text)
        self.assertIn("vsock cid 101 port 5000", text)
        self.assertIn("share in /var/lib/probe/probe-1/in (read-only in the guest)", text)
        self.assertIn("share out /var/lib/probe/probe-1/out (writable in the guest)", text)
        self.assertEqual(sorted(p.name for p in (self.state / "leases").iterdir()), ["probe-1.json"])

    def test_up_uses_the_slot_the_holder_holds_again(self) -> None:
        caller = self.process(1000)
        slots, _ = self.slots()
        slots.up("probe", caller)
        self.assertEqual(slots.up("probe", caller), "probe-1")
        self.assertEqual(self.calls()[-1], ["--no-ask-password", "start", "microvm@probe-1.service"])

    def test_sessions_get_their_own_slots_until_none_is_free(self) -> None:
        slots, _ = self.slots()
        self.assertEqual(slots.up("probe", self.process(1000)), "probe-1")
        self.assertEqual(slots.up("probe", self.process(2000)), "probe-2")
        with self.assertRaisesRegex(Refused, "every slot of the kind probe is held"):
            slots.up("probe", self.process(3000))
        self.assertIsNone(self.lease("quiet-1"))

    def test_the_session_id_alone_holds_nothing(self) -> None:
        slots, _ = self.slots()
        slots.up("probe", self.process(1000))
        same_session = Caller(session="session-1000", pid=2000, start="4242")
        self.process(2000)
        with self.assertRaisesRegex(Refused, "probe-1 is held by another live session"):
            slots.down(same_session, "probe-1")

    def test_down_refuses_a_slot_another_live_session_holds(self) -> None:
        first, second = self.process(1000), self.process(2000)
        slots, out = self.slots()
        slots.up("probe", first)
        with self.assertRaisesRegex(Refused, "probe-1 is held by another live session"):
            slots.down(second, "probe-1")
        self.assertIsNotNone(self.lease("probe-1"))
        slots.down(first, None)
        self.assertIsNone(self.lease("probe-1"))
        self.assertEqual(self.calls()[-1], ["--no-ask-password", "stop", "microvm@probe-1.service"])
        self.assertIn("stopped probe-1", out.getvalue())

    def test_down_without_blocking_queues_the_stop(self) -> None:
        caller = self.process(1000)
        slots, _ = self.slots()
        slots.up("probe", caller)
        slots.down(caller, None, no_block=True)
        self.assertEqual(self.calls()[-1], ["--no-ask-password", "--no-block", "stop", "microvm@probe-1.service"])
        self.assertIsNone(self.lease("probe-1"))

    def test_a_reused_process_id_is_not_the_holder(self) -> None:
        slots, _ = self.slots()
        slots.up("probe", self.process(1000, start="1"))
        # The process ends and another takes its ID.
        self.process(1000, start="2")
        self.assertFalse(slots.alive(self.lease("probe-1")))
        stranger = Caller(session="other", pid=1000, start="2")
        slots.down(stranger, "probe-1")
        self.assertIsNone(self.lease("probe-1"))

    def test_reap_stops_the_slots_of_holders_that_are_gone(self) -> None:
        slots, out = self.slots()
        slots.up("probe", self.process(1000))
        slots.up("probe", self.process(2000))
        self.end(1000)
        before = len(self.calls())
        slots.reap()
        self.assertIsNone(self.lease("probe-1"))
        self.assertIsNotNone(self.lease("probe-2"))
        stops = [call for call in self.calls()[before:] if call[1:2] == ["stop"]]
        self.assertEqual(stops, [["--no-ask-password", "stop", "microvm@probe-1.service"]])
        self.assertIn("reaped probe-1", out.getvalue())

    def test_a_slot_of_a_holder_that_is_gone_is_free(self) -> None:
        slots, _ = self.slots()
        slots.up("probe", self.process(1000))
        slots.up("probe", self.process(2000))
        self.end(1000)
        self.assertEqual(slots.up("probe", self.process(3000)), "probe-1")
        self.assertEqual(self.lease("probe-1")["session"], "session-3000")
        self.assertEqual(
            self.calls()[-2:],
            [
                ["--no-ask-password", "stop", "microvm@probe-1.service"],
                ["--no-ask-password", "start", "microvm@probe-1.service"],
            ],
        )

    def test_a_failed_start_releases_the_claim(self) -> None:
        self.systemctl_state.write_text(json.dumps({"fail": {"microvm@probe-1.service": ["start"]}}))
        slots, _ = self.slots()
        with self.assertRaisesRegex(Refused, "systemctl start microvm@probe-1.service failed .*Access denied"):
            slots.up("probe", self.process(1000))
        self.assertIsNone(self.lease("probe-1"))

    def test_a_guest_that_never_answers_stays_leased(self) -> None:
        self.answering = set()
        slots, _ = self.slots()
        with self.assertRaisesRegex(Refused, "did not answer within 10 seconds"):
            slots.up("probe", self.process(1000))
        self.assertIsNotNone(self.lease("probe-1"))

    def test_a_slot_with_a_vsock_socket_is_reached_through_it(self) -> None:
        self.config["kinds"]["probe"]["slots"][1]["vsockSocket"] = "/run/probe-2.vsock"
        slots, _ = self.slots()
        self.assertEqual(slots.endpoint("probe-1"), Endpoint("probe-1", 101, 5000, None))
        self.assertEqual(slots.endpoint("probe-2"), Endpoint("probe-2", 102, 5000, "/run/probe-2.vsock"))
        self.assertIsNone(slots.endpoint("quiet-1"))

    def test_up_waits_for_the_guest_through_its_vsock_socket(self) -> None:
        path = self.root / "probe-1.vsock"
        self.config["kinds"]["probe"]["slots"][0]["vsockSocket"] = str(path)
        # The VMM refuses CONNECT twice, as it does while the guest boots.
        answers = [None, b"FAILED\n", b"OK 1073741824\n"]
        vmm = FakeVmm(path, answer=lambda port: answers.pop(0))
        self.addCleanup(vmm.close)
        slots, _ = self.slots()
        slots.probe = transport.probe
        self.assertEqual(slots.up("probe", self.process(1000)), "probe-1")
        self.assertEqual(vmm.requests, [b"CONNECT 5000\n"] * 3)

    def test_a_permission_error_ends_the_wait_at_once(self) -> None:
        def denied(endpoint: Endpoint, timeout: float) -> None:
            raise PermissionError(f"permission denied on the vsock socket /s of {endpoint.slot}")

        slots, out = self.slots()
        slots.probe = denied
        started = self.now
        with self.assertRaisesRegex(
            Refused, "^probe-1 was started but permission denied on the vsock socket /s of probe-1; it stays leased"
        ):
            slots.up("probe", self.process(1000))
        self.assertEqual(self.now, started)
        self.assertIsNotNone(self.lease("probe-1"))
        slots.status(self.process(1000), everything=False)
        self.assertIn("probe-1  kind probe  active  not answering: permission denied", out.getvalue())

    def test_status_shows_the_slots_and_their_holders(self) -> None:
        slots, out = self.slots()
        caller = self.process(1000)
        slots.status(caller, everything=False)
        self.assertIn("this session holds no slots", out.getvalue())
        slots.up("probe", caller)
        slots.up("probe", self.process(2000))
        out.truncate(0)
        out.seek(0)
        slots.status(caller, everything=False)
        lines = out.getvalue().splitlines()
        self.assertRegex(lines[0], r"^probe-1  kind probe  active  answering  up \d+s$")
        self.assertIn("  probe: 2 slots, 0 free", lines)
        self.assertIn("  quiet: 1 slots, 1 free", lines)
        out.truncate(0)
        out.seek(0)
        slots.status(caller, everything=True)
        text = out.getvalue()
        self.assertIn("probe-1  kind probe  held by this session  active", text)
        self.assertIn("probe-2  kind probe  held by session session-2000  active", text)
        self.assertIn("quiet-1  kind quiet  free  inactive", text)


class CommandLineCase(Fixture):
    """The command line, end to end over the same fakes, for kinds that
    declare no vsock port, so no probe runs."""

    def main(self, *argv: str, env: dict[str, str] | None = None) -> tuple[int, str, str]:
        config_path = self.root / "config.json"
        config_path.write_text(json.dumps(self.config))
        base = {"MICROVM_CONFIG": str(config_path)}
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(list(argv), base | (env or {}))
        return code, out.getvalue(), err.getvalue()

    def session_env(self, pid: int) -> dict[str, str]:
        caller = self.process(pid)
        return {"CLAUDE_CODE_SESSION_ID": caller.session, "CLAUDE_PID": str(pid)}

    def test_up_status_down(self) -> None:
        env = self.session_env(1000)
        code, out, err = self.main("up", "quiet", env=env)
        self.assertEqual((code, err), (0, ""))
        self.assertIn("slot quiet-1 (kind quiet)", out)
        code, out, _ = self.main("status", "--all", env=env)
        self.assertEqual(code, 0)
        self.assertIn("quiet-1  kind quiet  held by this session  active", out)
        code, out, _ = self.main("down", "quiet-1", env=env)
        self.assertEqual(code, 0)
        self.assertIn("stopped quiet-1", out)

    def test_the_command_controls_a_kind_agents_may_not_use(self) -> None:
        env = self.session_env(1000)
        code, out, err = self.main("up", "hidden", env=env)
        self.assertEqual((code, err), (0, ""))
        self.assertIn("slot hidden-1 (kind hidden)", out)
        code, out, _ = self.main("down", env=env)
        self.assertEqual(code, 0)
        self.assertIn("stopped hidden-1", out)

    def test_arguments_outside_the_verbs_and_names_are_refused(self) -> None:
        env = self.session_env(1000)
        for argv in (
            [],
            ["start", "probe"],
            ["up"],
            ["up", "probe", "probe"],
            ["up", "../etc"],
            ["up", "probe-1"],
            ["up", "--all"],
            ["status", "--json"],
            ["status", "probe-1"],
            ["down", "probe"],
            ["down", "probe-1", "probe-2"],
            ["down", "--all"],
            ["reap", "probe-1"],
            ["mcp", "probe"],
            ["connect", "probe"],
            ["relay", "probe"],
        ):
            with self.subTest(argv=argv):
                code, out, err = self.main(*argv, env=env)
                self.assertEqual(code, 2)
                self.assertEqual(out, "")
                self.assertIn("usage:", err)
        self.assertEqual(self.calls(), [])
        self.assertFalse(self.state.exists())

    def test_a_bad_holder_is_refused(self) -> None:
        code, _, err = self.main("up", "quiet", env={"CLAUDE_PID": "x1"})
        self.assertEqual(code, 1)
        self.assertIn("CLAUDE_PID is not a process ID", err)
        code, _, err = self.main("up", "quiet", env={"CLAUDE_PID": "12345"})
        self.assertEqual(code, 1)
        self.assertIn("the holding process 12345 does not run", err)
        self.assertEqual(self.calls(), [])

    def test_the_holder_is_claude_pid_or_the_parent(self) -> None:
        self.process(1000)
        self.process(2000, start="77")
        env = {"CLAUDE_PID": "1000", "CLAUDE_CODE_SESSION_ID": "s-1"}
        # A verb a user types names CLAUDE_PID when it is set.
        self.assertEqual(
            cli.caller_from(env, self.proc, 2000, claude_pid=True),
            Caller(session="s-1", pid=1000, start="4242"),
        )
        self.assertEqual(
            cli.caller_from({}, self.proc, 2000, claude_pid=True),
            Caller(session=None, pid=2000, start="77"),
        )
        # The MCP server names its parent, Claude Code, whatever the
        # environment says.
        self.assertEqual(
            cli.caller_from(env, self.proc, 2000, claude_pid=False),
            Caller(session="s-1", pid=2000, start="77"),
        )
        # A malformed session ID is not recorded.
        self.assertIsNone(cli.caller_from({"CLAUDE_CODE_SESSION_ID": "x/../y"}, self.proc, 2000, claude_pid=False).session)

    def test_without_a_configuration_nothing_runs(self) -> None:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(["status"], {})
        self.assertEqual(code, 1)
        self.assertIn("MICROVM_CONFIG is not set", err.getvalue())


if __name__ == "__main__":
    unittest.main()
