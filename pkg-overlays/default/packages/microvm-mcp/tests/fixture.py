# SPDX-License-Identifier: MIT
"""The fixture of the tests: the fakes that the library `ch_microvm`
publishes in `ch_microvm.testing`, in a temporary directory, a
configuration of ch-microvm with four kinds, and the kinds agents may
use. `probe` and `other` serve MCP, `quiet` serves nothing, and agents
may not use `hidden`."""

from __future__ import annotations

import json
import sys
import tempfile
import time
import unittest
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "src"
sys.path.insert(0, str(SRC))

from ch_microvm.instances import Holder, Instances  # noqa: E402
from ch_microvm.testing import FakeProc, FakeSystemd, fake_runner  # noqa: E402
from ch_microvm.transport import Endpoint  # noqa: E402

UID = 1234


class Fixture(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.proc = FakeProc(self.root / "proc")
        self.systemd = FakeSystemd(self.root)
        self.state = self.root / "state"
        runner = fake_runner(self.root / "runner-probe", virtiofsd=True, notify=True)
        quiet_runner = fake_runner(self.root / "runner-quiet", virtiofsd=False, notify=False)
        self.instances_root = self.root / "instances"
        common = {"stateRoot": str(self.instances_root), "runtimeMaxSec": None}
        self.config = {
            "kinds": {
                "probe": common
                | {"runner": str(runner), "shares": ["in", "out"], "vsockPort": 5000, "maxInstances": 2},
                "other": common | {"runner": str(runner), "shares": [], "vsockPort": 6000, "maxInstances": 1},
                "quiet": common | {"runner": str(quiet_runner), "shares": [], "vsockPort": None, "maxInstances": 1},
                "hidden": common | {"runner": str(quiet_runner), "shares": [], "vsockPort": None, "maxInstances": 1},
            },
            "stateDir": str(self.state),
            "systemctl": self.systemd.systemctl,
            "systemdRun": self.systemd.systemd_run,
            "path": "/fake/bin",
            "upTimeout": 10,
            "procRoot": str(self.proc.root),
        }
        # The kinds agents may use, each with the MCP server of its
        # guest or None.
        self.mcp_kinds = {
            "probe": {"description": "Probes binaries."},
            "other": {"description": "Other tools."},
            "quiet": None,
        }
        self.answering = {"probe-1", "probe-2", "other-1"}
        self.now = time.time()

    def probe(self, endpoint: Endpoint, timeout: float) -> None:
        """The readiness probe of `up`: the instances in `answering`
        answer at once."""
        if endpoint.instance not in self.answering:
            raise ConnectionRefusedError(f"{endpoint.instance} does not answer")

    def process(self, pid: int, start: str = "4242") -> Holder:
        self.proc.process(pid, start)
        return Holder(pid=pid, start=start, label=f"Claude Code session {pid}")

    def clock(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds

    def instances(self) -> Instances:
        return Instances(
            self.config,
            kinds=self.mcp_kinds,
            run=self.systemd.run,
            probe=self.probe,
            clock=self.clock,
            sleep=self.sleep,
            uid=UID,
        )

    def calls(self) -> list[list[str]]:
        return self.systemd.calls()

    def lease(self, name: str) -> dict | None:
        path = self.state / "leases" / f"{name}.json"
        return json.loads(path.read_text()) if path.exists() else None

    def directory(self, name: str) -> Path:
        return self.instances_root / name
