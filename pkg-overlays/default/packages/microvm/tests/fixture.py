# SPDX-License-Identifier: MIT
"""The fakes the tests share: a systemctl that keeps unit state in a
file, a /proc of stat files, a vsock probe, and a configuration of four
kinds. `probe` and `other` serve MCP, `quiet` serves nothing, and agents
may not use `hidden`."""

from __future__ import annotations

import io
import json
import sys
import tempfile
import time
import unittest
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "src"
sys.path.insert(0, str(SRC))

from microvm_slots.slots import Caller, Slots  # noqa: E402

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
    verb, unit = args[-2], args[-1]
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
            "kinds": {
                "probe": {
                    "slots": [{"name": "probe-1", "cid": 101}, {"name": "probe-2", "cid": 102}],
                    "vsockPort": 5000,
                    "shareRoot": "/var/lib/probe",
                    "agents": True,
                    "mcp": {"description": "Probes binaries."},
                },
                "other": {
                    "slots": [{"name": "other-1", "cid": 401}],
                    "vsockPort": 6000,
                    "shareRoot": None,
                    "agents": True,
                    "mcp": {"description": "Other tools."},
                },
                "quiet": {
                    "slots": [{"name": "quiet-1", "cid": 201}],
                    "vsockPort": None,
                    "shareRoot": None,
                    "agents": True,
                    "mcp": None,
                },
                "hidden": {
                    "slots": [{"name": "hidden-1", "cid": 301}],
                    "vsockPort": None,
                    "shareRoot": None,
                    "agents": False,
                    "mcp": None,
                },
            },
            "stateDir": str(self.state),
            "systemctl": str(fake),
            "upTimeout": 10,
            "procRoot": str(self.proc),
        }
        self.answering: set[int] = {101, 102, 401}
        # The fake systemctl stamps units with the real time.
        self.now = time.time()

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

    def slots(self, agents_only: bool = False) -> tuple[Slots, io.StringIO]:
        out = io.StringIO()
        return (
            Slots(
                self.config,
                agents_only=agents_only,
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
