# SPDX-License-Identifier: MIT
"""The fakes the tests share: a systemctl that keeps unit state in a
file, a /proc of stat files, a vsock probe, the hybrid vsock socket of
a VMM, and a configuration of four kinds. `probe` and `other` serve MCP, `quiet` serves nothing, and agents
may not use `hidden`."""

from __future__ import annotations

import io
import json
import socket
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from typing import Callable

SRC = Path(__file__).resolve().parents[1] / "src"
sys.path.insert(0, str(SRC))

from microvm_slots.slots import Caller, Slots  # noqa: E402
from microvm_slots.transport import Endpoint  # noqa: E402

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
    if verb in state.get("fail", {{}}).get(unit, []):
        print("Access denied", file=sys.stderr)
        sys.exit(4)
    active = state.setdefault("active", {{}})
    if verb == "start":
        if unit not in active:
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


class FakeVmm:
    """The hybrid vsock socket of a cloud-hypervisor VMM, listening at
    `path`. For each connection it reads one line, records it in
    `requests`, and sends what `answer` returns for the requested port,
    or closes the connection when `answer` returns None. After an
    answer that starts with `OK `, it hands the connection and the port
    to `accepted`, or closes the connection when `accepted` is None."""

    def __init__(
        self,
        path: Path,
        answer: Callable[[int], bytes | None] = lambda port: b"OK 1073741824\n",
        accepted: Callable[[socket.socket, int], None] | None = None,
    ) -> None:
        self.path = path
        self.answer = answer
        self.accepted = accepted
        self.requests: list[bytes] = []
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(path))
        self.listener.listen(8)
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self) -> None:
        while True:
            try:
                conn, _ = self.listener.accept()
            except OSError:
                return
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()

    def handle(self, conn: socket.socket) -> None:
        line = bytearray()
        while not line.endswith(b"\n"):
            byte = conn.recv(1)
            if not byte:
                conn.close()
                return
            line += byte
        self.requests.append(bytes(line))
        verb, _, port = line.decode().strip().partition(" ")
        reply = self.answer(int(port)) if verb == "CONNECT" and port.isdigit() else None
        if reply is None:
            conn.close()
            return
        if reply:
            conn.sendall(reply)
        if not reply.startswith(b"OK "):
            conn.close()
        elif self.accepted is not None:
            self.accepted(conn, int(port))
        else:
            conn.close()

    def close(self) -> None:
        try:
            self.listener.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.listener.close()


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
        # The share root of `probe`. No share directory exists until a
        # test creates it.
        self.shares = self.root / "shares"
        self.config = {
            "kinds": {
                "probe": {
                    "slots": [{"name": "probe-1", "cid": 101}, {"name": "probe-2", "cid": 102}],
                    "vsockPort": 5000,
                    "shareRoot": str(self.shares),
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

    def probe(self, endpoint: Endpoint, timeout: float) -> None:
        if endpoint.cid not in self.answering:
            raise ConnectionRefusedError(f"{endpoint.slot} does not answer")

    def slots(self, agents_only: bool = False) -> tuple[Slots, io.StringIO]:
        out = io.StringIO()
        return (
            Slots(
                self.config,
                agents_only=agents_only,
                probe=self.probe,
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
