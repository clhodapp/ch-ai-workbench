# SPDX-License-Identifier: MIT
"""The `microvm` MCP server against the fakes of the fixture and fake
guest MCP servers behind fake VMMs on the hybrid vsock sockets in the
directories of their instances: the tools before any guest, a kind
agents may not use, a guest without MCP, the tools of a guest after
`microvm_up`, a directory passed to `microvm_up`, forwarding, names
that collide, stopping, a dropped connection, the stop of the
session's instances at exit, and the label and arguments of the
program."""

from __future__ import annotations

import contextlib
import io
import json
import queue
import socket
import threading
import unittest
from pathlib import Path
from typing import Any

from fixture import Fixture
from ch_microvm.testing import FakeVmm
from microvm_mcp import cli
from microvm_mcp.mcp import MANAGER_TOOLS, Server

WAIT = 10.0


class FakeGuest:
    """An MCP server on one end of a socket pair. It lists `tools`,
    answers a call with the tool's name and arguments, holds a call of
    `slow` until `release` is set, and sends a progress notification
    first when the call carries a progress token."""

    def __init__(self, sock: socket.socket, tools: list[str]) -> None:
        self.sock = sock
        self.tools = tools
        self.received: list[dict[str, Any]] = []
        self.release = threading.Event()
        self.lock = threading.Lock()
        threading.Thread(target=self.serve, daemon=True).start()

    def send(self, msg: dict[str, Any]) -> None:
        with self.lock:
            self.sock.sendall((json.dumps(msg) + "\n").encode())

    def serve(self) -> None:
        try:
            for line in self.sock.makefile("r"):
                msg = json.loads(line)
                self.received.append(msg)
                method = msg.get("method")
                if "id" not in msg:
                    continue
                if method == "initialize":
                    self.send(
                        {
                            "jsonrpc": "2.0",
                            "id": msg["id"],
                            "result": {
                                "protocolVersion": "2025-06-18",
                                "capabilities": {"tools": {"listChanged": True}},
                                "serverInfo": {"name": "fake", "version": "0"},
                            },
                        }
                    )
                elif method == "tools/list":
                    tools = [
                        {"name": name, "description": f"does {name}", "inputSchema": {"type": "object"}}
                        for name in self.tools
                    ]
                    self.send({"jsonrpc": "2.0", "id": msg["id"], "result": {"tools": tools}})
                elif method == "tools/call":
                    threading.Thread(target=self.answer, args=(msg,), daemon=True).start()
        except (OSError, ValueError):
            pass

    def answer(self, msg: dict[str, Any]) -> None:
        params = msg["params"]
        token = (params.get("_meta") or {}).get("progressToken")
        if token is not None:
            self.send(
                {"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": token, "progress": 1}}
            )
        if params["name"] == "slow":
            self.release.wait(WAIT)
        text = f"{params['name']} {json.dumps(params.get('arguments') or {})}"
        try:
            self.send({"jsonrpc": "2.0", "id": msg["id"], "result": {"content": [{"type": "text", "text": text}]}})
        except OSError:
            pass

    def close(self) -> None:
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()


class ServerCase(Fixture):
    """The server, connecting to the guests through the hybrid vsock
    sockets in the directories of their instances. A fake VMM listens
    on the socket of an instance once its VMM unit starts, and hands
    each accepted connection to a fake guest."""

    def setUp(self) -> None:
        super().setUp()
        self.claude = self.process(1000)
        self.guest_tools = {
            "probe-1": ["open_binary", "slow"],
            "probe-2": ["open_binary"],
            "other-1": ["open_binary", "list_functions"],
        }
        self.guests: dict[str, FakeGuest] = {}
        self.connects: list[tuple[str, int]] = []
        self.vmms: dict[str, FakeVmm] = {}
        self.systemd.on_start.append(self.started)
        self.sent: queue.Queue[dict[str, Any]] = queue.Queue()
        self.notes: list[dict[str, Any]] = []
        self.server = Server(self.instances(), self.claude, self.sent.put, self.mcp_kinds)
        self.thread = threading.Thread(target=self.server.run, daemon=True)
        self.thread.start()
        self.addCleanup(self.finish)
        self.next_id = 0
        self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}})

    def started(self, instance: str, directory: Path) -> None:
        if instance not in self.guest_tools:
            return
        self.vmms[instance] = FakeVmm(
            directory / "notify.vsock", accepted=lambda conn, port: self.accept(instance, conn, port)
        )

    def finish(self) -> None:
        if self.thread.is_alive():
            self.server.client(None)
            self.thread.join(WAIT)
        for guest in self.guests.values():
            guest.release.set()
            guest.close()
        for vmm in self.vmms.values():
            vmm.close()

    def accept(self, instance: str, guest_end: socket.socket, port: int) -> None:
        self.connects.append((instance, port))
        self.guests[instance] = FakeGuest(guest_end, self.guest_tools[instance])

    def send(self, method: str, params: dict[str, Any] | None = None) -> int:
        self.next_id += 1
        msg: dict[str, Any] = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            msg["params"] = params
        self.server.client(msg)
        return self.next_id

    def response(self, msg_id: int) -> dict[str, Any]:
        for msg in self.notes:
            if msg.get("id") == msg_id and "method" not in msg:
                self.notes.remove(msg)
                return msg
        while True:
            msg = self.sent.get(timeout=WAIT)
            if msg.get("id") == msg_id and "method" not in msg:
                return msg
            self.notes.append(msg)

    def request(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        return self.response(self.send(method, params))

    def call(self, name: str, arguments: dict[str, Any] | None = None) -> dict[str, Any]:
        return self.request("tools/call", {"name": name, "arguments": arguments or {}})["result"]

    def tool_names(self) -> list[str]:
        return [tool["name"] for tool in self.request("tools/list")["result"]["tools"]]

    def list_changes(self) -> int:
        return sum(1 for note in self.notes if note.get("method") == "notifications/tools/list_changed")

    def text(self, result: dict[str, Any]) -> str:
        return result["content"][0]["text"]

    def test_initialize_and_the_tools_before_any_guest(self) -> None:
        names = self.tool_names()
        self.assertEqual(names, list(MANAGER_TOOLS))
        tools = self.request("tools/list")["result"]["tools"]
        up = tools[0]
        self.assertEqual(sorted(up["inputSchema"]["properties"]["kind"]["enum"]), ["other", "probe", "quiet"])
        self.assertEqual(up["inputSchema"]["properties"]["directory"]["type"], "string")
        self.assertIn("probe (at most 2 instances), serving MCP: Probes binaries.", up["description"])
        self.assertIn("; quiet (at most 1 instance).", up["description"])
        self.assertEqual(tools[1]["inputSchema"]["properties"]["instance"]["enum"], ["other-1", "probe-1", "probe-2", "quiet-1"])
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.connects, [])

    def test_a_kind_agents_may_not_use_is_refused(self) -> None:
        result = self.call("microvm_up", {"kind": "hidden"})
        self.assertTrue(result["isError"])
        self.assertIn("unknown kind 'hidden'", self.text(result))
        result = self.call("microvm_down", {"instance": "hidden-1"})
        self.assertTrue(result["isError"])
        self.assertNotIn("hidden", json.dumps(self.request("tools/list")))
        self.assertEqual(self.calls(), [])

    def test_a_kind_without_mcp_only_starts(self) -> None:
        result = self.call("microvm_up", {"kind": "quiet"})
        self.assertNotIn("isError", result)
        self.assertIn(f"instance quiet-1 (kind quiet)\ndirectory {self.directory('quiet-1')}", self.text(result))
        self.assertNotIn("sandbox module", self.text(result))
        self.assertEqual(self.connects, [])
        self.assertEqual(self.tool_names(), list(MANAGER_TOOLS))

    def test_the_lease_names_the_session(self) -> None:
        self.call("microvm_up", {"kind": "quiet"})
        lease = self.lease("quiet-1")
        self.assertEqual((lease["pid"], lease["label"]), (1000, "Claude Code session 1000"))
        result = self.call("microvm_status", {"all": True})
        self.assertIn("quiet-1  kind quiet  directory ", self.text(result))
        self.assertIn("  held by the caller  active", self.text(result))

    def test_up_adds_the_tools_of_the_guest_and_forwards_calls(self) -> None:
        result = self.call("microvm_up", {"kind": "probe"})
        self.assertNotIn("isError", result)
        self.assertIn("instance probe-1 (kind probe)", self.text(result))
        self.assertIn(f"share out {self.directory('probe-1')}/out", self.text(result))
        self.assertIn("only when its checkout has chosen the sandbox module microvm-probe\n", self.text(result))
        self.assertIn("tools of this server now: open_binary, slow", self.text(result))
        self.assertEqual(self.connects, [("probe-1", 5000)])
        self.assertEqual(self.list_changes(), 1)
        self.assertEqual(self.tool_names(), [*MANAGER_TOOLS, "open_binary", "slow"])
        guest = self.guests["probe-1"]
        self.assertEqual([m.get("method") for m in guest.received[:3]], ["initialize", "notifications/initialized", "tools/list"])

        msg_id = self.send(
            "tools/call", {"name": "open_binary", "arguments": {"path": "/work/in/a"}, "_meta": {"progressToken": "p"}}
        )
        reply = self.response(msg_id)
        self.assertEqual(reply["result"]["content"][0]["text"], 'open_binary {"path": "/work/in/a"}')
        self.assertIn(
            {"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": "p", "progress": 1}},
            self.notes,
        )
        # The guest saw an ID of the server, not the ID of Claude Code.
        forwarded = [m for m in guest.received if m.get("method") == "tools/call"][0]
        self.assertNotEqual(forwarded["id"], msg_id)

        # A second up uses the instance and the connection again.
        result = self.call("microvm_up", {"kind": "probe"})
        self.assertIn("tools of this server now: open_binary, slow", self.text(result))
        self.assertEqual(self.connects, [("probe-1", 5000)])

    def test_up_in_a_directory_the_agent_passes(self) -> None:
        work = self.root / "work"
        result = self.call("microvm_up", {"kind": "probe", "directory": str(work)})
        self.assertNotIn("isError", result)
        self.assertIn(f"directory {work} (passed by the caller, kept as it was)", self.text(result))
        self.assertIn("No sandbox module grants Bash commands the share directories", self.text(result))
        self.assertEqual(self.connects, [("probe-1", 5000)])
        self.assertTrue((work / "notify.vsock").exists())
        result = self.call("microvm_up", {"kind": "other", "directory": "relative"})
        self.assertTrue(result["isError"])
        self.assertIn("is not an absolute path", self.text(result))
        result = self.call("microvm_up", {"kind": "other", "directory": 7})
        self.assertTrue(result["isError"])

    def test_a_tool_list_change_of_the_guest_is_passed_on(self) -> None:
        self.call("microvm_up", {"kind": "probe"})
        guest = self.guests["probe-1"]
        guest.tools = ["open_binary", "decompile"]
        guest.send({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
        for _ in range(100):
            if self.list_changes() >= 2:
                break
            self.notes.append(self.sent.get(timeout=WAIT))
        self.assertEqual(self.tool_names(), [*MANAGER_TOOLS, "open_binary", "decompile"])

    def test_names_that_collide_get_the_kind_as_prefix(self) -> None:
        self.call("microvm_up", {"kind": "probe"})
        result = self.call("microvm_up", {"kind": "other"})
        self.assertIn("tools of this server now: other_open_binary, list_functions", self.text(result))
        tools = self.request("tools/list")["result"]["tools"]
        self.assertEqual(
            [tool["name"] for tool in tools],
            [*MANAGER_TOOLS, "open_binary", "slow", "other_open_binary", "list_functions"],
        )
        renamed = [tool for tool in tools if tool["name"] == "other_open_binary"][0]
        self.assertIn("The tool open_binary of the other guest, renamed", renamed["description"])
        reply = self.call("other_open_binary")
        self.assertEqual(self.text(reply), "open_binary {}")
        self.assertEqual(len([m for m in self.guests["other-1"].received if m.get("method") == "tools/call"]), 1)
        self.assertEqual(len([m for m in self.guests["probe-1"].received if m.get("method") == "tools/call"]), 0)

    def test_down_removes_the_tools_and_fails_calls_in_flight(self) -> None:
        self.call("microvm_up", {"kind": "probe"})
        slow = self.send("tools/call", {"name": "slow", "arguments": {}})
        result = self.call("microvm_down", {"instance": "probe-1"})
        self.assertIn("stopped probe-1", self.text(result))
        self.assertEqual(self.response(slow)["error"]["code"], -32000)
        self.assertEqual(self.list_changes(), 2)
        self.assertEqual(self.tool_names(), list(MANAGER_TOOLS))
        self.assertIsNone(self.lease("probe-1"))
        self.guests["probe-1"].release.set()
        result = self.call("open_binary")
        self.assertTrue(result["isError"])

    def test_a_dropped_connection_removes_the_tools(self) -> None:
        self.call("microvm_up", {"kind": "probe"})
        slow = self.send("tools/call", {"name": "slow", "arguments": {}})
        self.guests["probe-1"].close()
        self.assertIn("is gone", self.response(slow)["error"]["message"])
        self.assertEqual(self.tool_names(), list(MANAGER_TOOLS))
        self.assertEqual(self.list_changes(), 2)
        # The instance stays leased; up connects to it again.
        self.assertIsNotNone(self.lease("probe-1"))
        result = self.call("microvm_up", {"kind": "probe"})
        self.assertIn("open_binary", self.text(result))
        self.assertEqual(self.connects, [("probe-1", 5000), ("probe-1", 5000)])

    def test_a_guest_that_refuses_the_connection(self) -> None:
        def refusing(instance: str, directory: Path) -> None:
            self.vmms[instance].answer = lambda port: b"FAILED\n"

        self.systemd.on_start.append(refusing)
        result = self.call("microvm_up", {"kind": "probe"})
        self.assertTrue(result["isError"])
        self.assertIn(f"the MCP server of probe-1 at vsock port 5000 through {self.directory('probe-1')}/notify.vsock", self.text(result))
        self.assertIn(" is not reachable: probe-1 refused CONNECT 5000", self.text(result))
        self.assertEqual(self.tool_names(), list(MANAGER_TOOLS))

    def test_the_end_of_input_stops_the_instances_of_the_session(self) -> None:
        self.call("microvm_up", {"kind": "probe"})
        self.call("microvm_up", {"kind": "quiet"})
        before = len(self.calls())
        self.server.client(None)
        self.thread.join(WAIT)
        self.assertFalse(self.thread.is_alive())
        stops = [call for call in self.calls()[before:] if "stop" in call]
        self.assertEqual(
            stops,
            [
                ["systemctl", "--user", "--no-block", "stop", "microvm-probe-1.service", "microvm-probe-1-virtiofsd.service"],
                ["systemctl", "--user", "--no-block", "stop", "microvm-quiet-1.service"],
            ],
        )
        self.assertIsNone(self.lease("probe-1"))
        self.assertIsNone(self.lease("quiet-1"))


class ProgramCase(unittest.TestCase):
    def test_the_label_names_a_well_formed_session(self) -> None:
        self.assertEqual(cli.label_from({"CLAUDE_CODE_SESSION_ID": "s-1"}), "Claude Code session s-1")
        self.assertIsNone(cli.label_from({"CLAUDE_CODE_SESSION_ID": "x/../y"}))
        self.assertIsNone(cli.label_from({}))

    def test_arguments_and_a_missing_configuration_are_refused(self) -> None:
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(cli.main(["mcp"], {}), 2)
            self.assertEqual(cli.main([], {}), 1)
        self.assertIn("takes no arguments", err.getvalue())
        self.assertIn("MICROVM_MCP_CONFIG is not set", err.getvalue())


if __name__ == "__main__":
    unittest.main()
