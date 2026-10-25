# SPDX-License-Identifier: MIT
"""The program against a fake systemctl, a fake /proc and a fake vsock
probe: claiming a free slot, using a held slot again, refusing to stop
a slot another live session holds, reaping the slots of holders that
are gone, the relay command of connect, and the refusal of every
argument that is not a verb or a configured name."""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "src"
sys.path.insert(0, str(SRC))

from microvm_slots import cli  # noqa: E402
from microvm_slots.slots import Caller, Refused, Slots, start_time  # noqa: E402

FAKE_SYSTEMCTL = """\
import json, sys, time
state_path, log_path = {state!r}, {log!r}
args = sys.argv[1:]
with open(log_path, "a") as log:
    log.write(json.dumps(args) + "\\n")
try:
    state = json.load(open(state_path))
except FileNotFoundError:
    state = {{}}
if args[:1] == ["--no-ask-password"]:
    verb, unit = args[1], args[2]
    if unit in state.get("fail", []):
        print("Access denied", file=sys.stderr)
        sys.exit(4)
    active = state.setdefault("active", {{}})
    if verb in ("start", "restart"):
        if verb == "restart" or unit not in active:
            active[unit] = int(time.time()) - 5
    elif verb == "stop":
        active.pop(unit, None)
    json.dump(state, open(state_path, "w"))
elif args[:1] == ["is-active"]:
    on = args[1] in state.get("active", {{}})
    print("active" if on else "inactive")
    sys.exit(0 if on else 3)
elif args[:1] == ["show"]:
    since = state.get("active", {{}}).get(args[-1])
    print("@%d" % since if since is not None else "")
"""


def stat_line(pid: int, start: str, comm: str = "claude") -> str:
    return f"{pid} ({comm}) S " + " ".join(["0"] * 18) + f" {start} 0 0\n"


class Fixture(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.proc = self.root / "proc"
        self.proc.mkdir()
        self.state = self.root / "state"
        self.systemctl_state = self.root / "systemctl.json"
        self.log = self.root / "systemctl.log"
        fake = self.root / "systemctl"
        fake.write_text(
            f"#!{sys.executable}\n" + FAKE_SYSTEMCTL.format(state=str(self.systemctl_state), log=str(self.log))
        )
        fake.chmod(0o755)
        self.config = {
            "slots": {
                f"probe-{k}": {
                    "kind": "probe",
                    "index": k,
                    "cid": 100 + k,
                    "vsockPort": 5000,
                    "shares": [
                        {
                            "tag": "work-in",
                            "source": f"/var/lib/probe/probe-{k}/in",
                            "mountPoint": "/work/in",
                            "readOnly": True,
                        },
                        {
                            "tag": "work-out",
                            "source": f"/var/lib/probe/probe-{k}/out",
                            "mountPoint": "/work/out",
                        },
                    ],
                }
                for k in (1, 2)
            }
            | {"quiet-1": {"kind": "quiet", "index": 1, "cid": 201, "vsockPort": None, "shares": []}},
            "stateDir": str(self.state),
            "systemctl": str(fake),
            "socat": "/nix/store/socat/bin/socat",
            "upTimeout": 10,
            "procRoot": str(self.proc),
        }
        self.answering: set[int] = {101, 102}
        # The fake systemctl stamps units with the real time.
        self.now = time.time()

    # Fakes.

    def process(self, pid: int, start: str = "4242") -> Caller:
        (self.proc / str(pid)).mkdir(exist_ok=True)
        (self.proc / str(pid) / "stat").write_text(stat_line(pid, start))
        return Caller(session=f"session-{pid}", pid=pid, start=start)

    def end(self, pid: int) -> None:
        (self.proc / str(pid) / "stat").unlink()
        (self.proc / str(pid)).rmdir()

    def clock(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds

    def slots(self) -> tuple[Slots, io.StringIO]:
        out = io.StringIO()
        return (
            Slots(
                self.config,
                probe=lambda cid, port, timeout: cid in self.answering,
                clock=self.clock,
                sleep=self.sleep,
                out=out,
            ),
            out,
        )

    def calls(self) -> list[list[str]]:
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def lease(self, slot: str) -> dict | None:
        path = self.state / "leases" / f"{slot}.json"
        return json.loads(path.read_text()) if path.exists() else None


class SlotsCase(Fixture):

    def test_start_time_reads_field_22_past_a_command_with_parentheses(self) -> None:
        (self.proc / "7").mkdir()
        (self.proc / "7" / "stat").write_text(stat_line(7, "999", comm="a) (b c"))
        self.assertEqual(start_time(self.proc, 7), "999")
        self.assertIsNone(start_time(self.proc, 8))

    def test_up_claims_a_free_slot_and_records_the_holder(self) -> None:
        caller = self.process(1000)
        slots, out = self.slots()
        self.assertEqual(slots.up("probe", caller), "probe-1")
        lease = self.lease("probe-1")
        self.assertEqual(
            {k: lease[k] for k in ("slot", "kind", "session", "pid", "start")},
            {"slot": "probe-1", "kind": "probe", "session": "session-1000", "pid": 1000, "start": "4242"},
        )
        self.assertEqual(self.calls(), [["--no-ask-password", "restart", "microvm@probe-1.service"]])
        text = out.getvalue()
        self.assertIn("slot probe-1 (kind probe)", text)
        self.assertIn("vsock cid 101 port 5000", text)
        self.assertIn("share /var/lib/probe/probe-1/in (guest /work/in, read-only)", text)
        self.assertIn("share /var/lib/probe/probe-1/out (guest /work/out, writable)", text)
        self.assertEqual(sorted(p.name for p in (self.state / "leases").iterdir()), ["probe-1.json"])

    def test_up_uses_the_slot_the_session_holds_again(self) -> None:
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

    def test_down_refuses_a_slot_another_live_session_holds(self) -> None:
        first, second = self.process(1000), self.process(2000)
        slots, out = self.slots()
        slots.up("probe", first)
        with self.assertRaisesRegex(Refused, "probe-1 is held by another live session"):
            slots.down(second, "probe-1")
        self.assertIsNotNone(self.lease("probe-1"))
        # The session that holds it stops it, by the session ID alone, as
        # the SessionEnd hook does.
        slots.down(Caller(session="session-1000", pid=None, start=None), None)
        self.assertIsNone(self.lease("probe-1"))
        self.assertEqual(self.calls()[-1], ["--no-ask-password", "stop", "microvm@probe-1.service"])
        self.assertIn("stopped probe-1", out.getvalue())

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
        slots.reap()
        self.assertIsNone(self.lease("probe-1"))
        self.assertIsNotNone(self.lease("probe-2"))
        stops = [call for call in self.calls() if call[1:2] == ["stop"]]
        self.assertEqual(stops, [["--no-ask-password", "stop", "microvm@probe-1.service"]])
        self.assertIn("reaped probe-1", out.getvalue())

    def test_a_slot_of_a_holder_that_is_gone_is_free(self) -> None:
        slots, _ = self.slots()
        slots.up("probe", self.process(1000))
        slots.up("probe", self.process(2000))
        self.end(1000)
        self.assertEqual(slots.up("probe", self.process(3000)), "probe-1")
        self.assertEqual(self.lease("probe-1")["session"], "session-3000")
        self.assertEqual(self.calls()[-1], ["--no-ask-password", "restart", "microvm@probe-1.service"])

    def test_a_failed_start_releases_the_claim(self) -> None:
        self.systemctl_state.write_text(json.dumps({"fail": ["microvm@probe-1.service"]}))
        slots, _ = self.slots()
        with self.assertRaisesRegex(Refused, "systemctl restart microvm@probe-1.service failed .*Access denied"):
            slots.up("probe", self.process(1000))
        self.assertIsNone(self.lease("probe-1"))

    def test_a_guest_that_never_answers_stays_leased(self) -> None:
        self.answering = set()
        slots, _ = self.slots()
        with self.assertRaisesRegex(Refused, "did not answer within 10 seconds"):
            slots.up("probe", self.process(1000))
        self.assertIsNotNone(self.lease("probe-1"))

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

    def test_connect_relays_to_the_slot_and_up_finds_it_by_process(self) -> None:
        slots, _ = self.slots()
        claude = self.process(1000)
        # An MCP server knows no session ID; its parent holds the slot.
        server = Caller(session=None, pid=claude.pid, start=claude.start)
        self.assertEqual(
            slots.connect_argv("probe", server),
            ["/nix/store/socat/bin/socat", "STDIO", "VSOCK-CONNECT:101:5000"],
        )
        self.assertIsNone(self.lease("probe-1")["session"])
        # The agent's `up` in that session finds the slot by its process
        # and records the session ID, so the SessionEnd hook stops it.
        self.assertEqual(slots.up("probe", claude), "probe-1")
        self.assertEqual(self.lease("probe-1")["session"], "session-1000")
        with self.assertRaisesRegex(Refused, "declares no vsock port"):
            slots.connect_argv("quiet", server)


class CommandLineCase(Fixture):
    """The command line, end to end over the same fakes, for a kind that
    declares no vsock port, so no probe runs."""

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
            ["connect"],
        ):
            with self.subTest(argv=argv):
                code, out, err = self.main(*argv, env=env)
                self.assertEqual(code, 2)
                self.assertEqual(out, "")
                self.assertIn("usage:", err)
        self.assertEqual(self.calls(), [])
        self.assertFalse(self.state.exists())

    def test_the_trusted_wrapper_accepts_only_its_verbs(self) -> None:
        env = self.session_env(1000) | {"MICROVM_VERBS": "up,status,down"}
        for argv in (["reap"], ["connect", "probe"]):
            with self.subTest(argv=argv):
                code, _, err = self.main(*argv, env=env)
                self.assertEqual(code, 2)
                self.assertIn("unknown verb", err)
        self.assertEqual(self.calls(), [])

    def test_session_variables_are_checked(self) -> None:
        code, _, err = self.main("up", "quiet", env={"CLAUDE_CODE_SESSION_ID": "x/../y", "CLAUDE_PID": "1"})
        self.assertEqual(code, 1)
        self.assertIn("not a session ID", err)
        code, _, err = self.main("up", "quiet", env={"CLAUDE_CODE_SESSION_ID": "s", "CLAUDE_PID": "12345"})
        self.assertEqual(code, 1)
        self.assertIn("names no running process", err)
        code, _, err = self.main("up", "quiet", env={"CLAUDE_CODE_SESSION_ID": "s"})
        self.assertEqual(code, 1)
        self.assertIn("CLAUDE_PID", err)
        code, _, err = self.main("down")
        self.assertEqual(code, 1)
        self.assertIn("needs the calling session", err)
        self.assertEqual(self.calls(), [])

    def test_without_a_configuration_nothing_runs(self) -> None:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(["status"], {})
        self.assertEqual(code, 1)
        self.assertIn("MICROVM_CONFIG is not set", err.getvalue())


if __name__ == "__main__":
    unittest.main()
