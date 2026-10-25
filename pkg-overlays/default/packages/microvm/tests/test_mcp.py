# SPDX-License-Identifier: MIT
"""The `microvm` MCP server against the fakes of the fixture and fake
guest MCP servers on socket pairs: the tools before any guest, a kind
agents may not use, a guest without MCP, the tools of a guest after
`microvm_up`, forwarding, names that collide, stopping, a dropped
connection, and the stop of the session's slots at exit."""

from __future__ import annotations

import json
import queue
import socket
import threading
import unittest
from typing import Any

from fixture import Fixture
from microvm_slots.mcp import MANAGER_TOOLS, Server

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
    def setUp(self) -> None:
        super().setUp()
        self.claude = self.process(1000)
        self.slots_, _ = self.slots(agents_only=True)
        self.guest_tools = {101: ["open_binary", "slow"], 102: ["open_binary"], 401: ["open_binary", "list_functions"]}
        self.guests: dict[int, FakeGuest] = {}
        self.connects: list[tuple[int, int]] = []
        self.sent: queue.Queue[dict[str, Any]] = queue.Queue()
        self.notes: list[dict[str, Any]] = []
        self.server = Server(self.slots_, self.claude, self.sent.put, connect=self.connect)
        self.thread = threading.Thread(target=self.server.run, daemon=True)
        self.thread.start()
        self.addCleanup(self.finish)
        self.next_id = 0
        self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}})

    def finish(self) -> None:
        if self.thread.is_alive():
            self.server.client(None)
            self.thread.join(WAIT)
        for guest in self.guests.values():
            guest.release.set()
            guest.close()

    def connect(self, cid: int, port: int) -> socket.socket:
        self.connects.append((cid, port))
        server_end, guest_end = socket.socketpair()
        self.guests[cid] = FakeGuest(guest_end, self.guest_tools[cid])
        return server_end

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
        up = self.request("tools/list")["result"]["tools"][0]
        self.assertEqual(sorted(up["inputSchema"]["properties"]["kind"]["enum"]), ["other", "probe", "quiet"])
        self.assertIn("serving MCP: Probes binaries.", up["description"])
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.connects, [])

    def test_a_kind_agents_may_not_use_is_refused(self) -> None:
        result = self.call("microvm_up", {"kind": "hidden"})
        self.assertTrue(result["isError"])
        self.assertIn("unknown kind 'hidden'", self.text(result))
        result = self.call("microvm_down", {"slot": "hidden-1"})
        self.assertTrue(result["isError"])
        self.assertNotIn("hidden", json.dumps(self.request("tools/list")))
        self.assertEqual(self.calls(), [])

    def test_a_kind_without_mcp_only_starts(self) -> None:
        result = self.call("microvm_up", {"kind": "quiet"})
        self.assertNotIn("isError", result)
        self.assertIn("slot quiet-1 (kind quiet)\nvsock cid 201", self.text(result))
        self.assertNotIn("sandbox module", self.text(result))
        self.assertEqual(self.connects, [])
        self.assertEqual(self.tool_names(), list(MANAGER_TOOLS))

    def test_up_adds_the_tools_of_the_guest_and_forwards_calls(self) -> None:
        result = self.call("microvm_up", {"kind": "probe"})
        self.assertNotIn("isError", result)
        self.assertIn("slot probe-1 (kind probe)", self.text(result))
        self.assertIn("share out /var/lib/probe/probe-1/out (writable in the guest)", self.text(result))
        self.assertIn("only when its checkout has chosen the sandbox module microvm-probe\n", self.text(result))
        self.assertIn("tools of this server now: open_binary, slow", self.text(result))
        self.assertEqual(self.connects, [(101, 5000)])
        self.assertEqual(self.list_changes(), 1)
        self.assertEqual(self.tool_names(), [*MANAGER_TOOLS, "open_binary", "slow"])
        guest = self.guests[101]
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

        # A second up uses the slot and the connection again.
        result = self.call("microvm_up", {"kind": "probe"})
        self.assertIn("tools of this server now: open_binary, slow", self.text(result))
        self.assertEqual(self.connects, [(101, 5000)])

    def test_a_tool_list_change_of_the_guest_is_passed_on(self) -> None:
        self.call("microvm_up", {"kind": "probe"})
        guest = self.guests[101]
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
        self.assertEqual(len([m for m in self.guests[401].received if m.get("method") == "tools/call"]), 1)
        self.assertEqual(len([m for m in self.guests[101].received if m.get("method") == "tools/call"]), 0)

    def test_down_removes_the_tools_and_fails_calls_in_flight(self) -> None:
        self.call("microvm_up", {"kind": "probe"})
        slow = self.send("tools/call", {"name": "slow", "arguments": {}})
        result = self.call("microvm_down", {"slot": "probe-1"})
        self.assertIn("stopped probe-1", self.text(result))
        self.assertEqual(self.response(slow)["error"]["code"], -32000)
        self.assertEqual(self.list_changes(), 2)
        self.assertEqual(self.tool_names(), list(MANAGER_TOOLS))
        self.assertIsNone(self.lease("probe-1"))
        self.guests[101].release.set()
        result = self.call("open_binary")
        self.assertTrue(result["isError"])

    def test_a_dropped_connection_removes_the_tools(self) -> None:
        self.call("microvm_up", {"kind": "probe"})
        slow = self.send("tools/call", {"name": "slow", "arguments": {}})
        self.guests[101].close()
        self.assertIn("is gone", self.response(slow)["error"]["message"])
        self.assertEqual(self.tool_names(), list(MANAGER_TOOLS))
        self.assertEqual(self.list_changes(), 2)
        # The slot stays leased; up connects to it again.
        self.assertIsNotNone(self.lease("probe-1"))
        result = self.call("microvm_up", {"kind": "probe"})
        self.assertIn("open_binary", self.text(result))
        self.assertEqual(self.connects, [(101, 5000), (101, 5000)])

    def test_a_guest_that_refuses_the_connection(self) -> None:
        def refuse(cid: int, port: int) -> socket.socket:
            raise ConnectionRefusedError("refused")

        self.server.connect = refuse
        result = self.call("microvm_up", {"kind": "probe"})
        self.assertTrue(result["isError"])
        self.assertIn("refused the connection", self.text(result))
        self.assertEqual(self.tool_names(), list(MANAGER_TOOLS))

    def test_the_end_of_input_stops_the_slots_of_the_session(self) -> None:
        self.call("microvm_up", {"kind": "probe"})
        self.call("microvm_up", {"kind": "quiet"})
        self.server.client(None)
        self.thread.join(WAIT)
        self.assertFalse(self.thread.is_alive())
        stops = sorted(call[-1] for call in self.calls() if "stop" in call)
        self.assertEqual(stops, ["microvm@probe-1.service", "microvm@quiet-1.service"])
        self.assertTrue(all("--no-block" in call for call in self.calls() if "stop" in call))
        self.assertIsNone(self.lease("probe-1"))
        self.assertIsNone(self.lease("quiet-1"))


if __name__ == "__main__":
    unittest.main()
