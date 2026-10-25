# SPDX-License-Identifier: MIT
"""The `microvm` MCP server: `microvm mcp`.

Claude Code starts the server from the `microvm` plugin, outside the
sandbox of Bash, so the server reaches the system bus and the vsock of
the guests itself. It serves the tools `microvm_up`, `microvm_down` and
`microvm_status` for the kinds that the configuration lets agents use,
and for no other kind. It starts a guest only when `microvm_up` asks.

When `microvm_up` brings up a guest of a kind that serves MCP, the
server connects to the vsock port of the guest, initializes the MCP
server of the guest, and adds the tools of that server to its own
tools, under their own names. A name that a tool of this server or of a
guest connected earlier already has gets the prefix `<kind>_`. The
server then sends `notifications/tools/list_changed`. It forwards a call
of such a tool to its guest, and the progress and log notifications of
the guest back. When the guest stops, its connection drops, or
`microvm_down` stops it, the server fails the calls in flight, removes
the tools of the guest and sends `list_changed` again.

The holder of what the server claims is its parent process, Claude
Code, with that process's start time. The server stops the slots of the
session when its input ends or it receives SIGTERM or SIGHUP, which
happens when the session ends. It queues each stop with
`systemctl --no-block`, so that it exits before Claude Code kills it.
The reap timer stops the slots of a session that crashed.
"""

from __future__ import annotations

import json
import queue
import signal
import socket
import sys
import threading
from typing import Any, Callable

from .guests import Guest, read_lines, vsock_connect
from .slots import Caller, Refused, Slots

SERVER_INFO = {"name": "microvm", "version": "0.1.0"}
PROTOCOL_VERSION = "2025-06-18"
MANAGER_TOOLS = ("microvm_up", "microvm_down", "microvm_status")
# What the server forwards from a guest to Claude Code without a request.
FORWARDED_NOTIFICATIONS = ("notifications/progress", "notifications/message")


def kind_line(kind: str, info: dict) -> str:
    count = len(info["slots"])
    line = f"{kind} ({count} slot{'s' if count != 1 else ''})"
    mcp = info.get("mcp")
    if mcp is not None:
        line += f", serving MCP: {mcp['description']}"
    return line


def manager_tools(slots: Slots) -> list[dict[str, Any]]:
    kinds = sorted(slots.kinds)
    names = sorted(slots.slots)
    listing = "; ".join(kind_line(kind, slots.kind_info[kind]) for kind in kinds) or "none"
    return [
        {
            "name": "microvm_up",
            "description": (
                "Lease a guest virtual machine of a kind to this session, start it, and wait until it "
                "answers. The result names the slot, its vsock CID and port, and its share directories "
                "on the host. A guest this session already holds is used again. When the kind serves "
                "MCP, the tools of the guest then appear among the tools of this server. Start a guest "
                "only when the task needs it: each takes memory and the slots of a kind are few. "
                f"The kinds: {listing}."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {"kind": {"type": "string", "enum": kinds, "description": "The kind of guest."}},
                "required": ["kind"],
            },
        },
        {
            "name": "microvm_down",
            "description": (
                "Stop the guests this session holds, or one of them, and remove the tools they served. "
                "Stop a guest when the task that needed it is done. A guest started again later is a "
                "fresh guest. The guests of this session also stop when the session ends."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "slot": {
                        "type": "string",
                        "enum": names,
                        "description": "One slot to stop. Without it, every slot this session holds stops.",
                    }
                },
            },
        },
        {
            "name": "microvm_status",
            "description": (
                "Show the guests this session holds, each with the state of its unit, whether it "
                "answers and how long it has run, and how many slots of each kind are free. With "
                "all, show every slot and the session that holds it."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {"all": {"type": "boolean", "description": "Show every slot."}},
            },
            "annotations": {"readOnlyHint": True},
        },
    ]


def text_result(text: str, is_error: bool = False) -> dict[str, Any]:
    result: dict[str, Any] = {"content": [{"type": "text", "text": text.rstrip("\n")}]}
    if is_error:
        result["isError"] = True
    return result


class Server:
    """One MCP session over `slots`, for `caller`. Every message goes
    through `events`; the thread that calls `run` handles them in order.
    The tools of this server run in threads of their own, so a guest
    that boots does not hold up the calls of other guests."""

    def __init__(
        self,
        slots: Slots,
        caller: Caller,
        send: Callable[[dict[str, Any]], None],
        *,
        connect: Callable[[int, int], socket.socket] = vsock_connect,
    ) -> None:
        self.slots = slots
        self.caller = caller
        self.send_client = send
        self.connect = connect
        self.events: queue.Queue[tuple] = queue.Queue()
        self.guests: dict[str, Guest] = {}
        self.generation = 0
        # The `microvm_up` calls that wait for the guest of a kind to
        # list its tools: the ID of each call and what bringing up the
        # slot printed.
        self.waiting: dict[str, list[tuple[Any, str]]] = {}
        # The tools of the guests, by the name this server gives each,
        # to the kind and the name of the tool in its guest.
        self.exposed: dict[str, tuple[str, str]] = {}
        self.guest_tools: list[dict[str, Any]] = []

    # Events from the other threads.

    def client(self, msg: dict[str, Any] | None) -> None:
        self.events.put(("client", msg))

    def deliver(self, guest: Guest, msg: dict[str, Any] | None) -> None:
        self.events.put(("guest", guest, msg))

    # The loop.

    def run(self) -> int:
        try:
            while True:
                event = self.events.get()
                if event[0] == "client":
                    if event[1] is None:
                        return 0
                    self.from_client(event[1])
                elif event[0] == "guest":
                    _, guest, msg = event
                    if self.guests.get(guest.kind) is not guest:
                        continue
                    if msg is None:
                        self.drop(guest, "the connection to its MCP server dropped")
                    else:
                        self.from_guest(guest, msg)
                elif event[0] == "done":
                    self.done(*event[1:])
        finally:
            self.cleanup()

    def cleanup(self) -> None:
        """Close the connections and stop the slots of the session, best
        effort."""
        for guest in list(self.guests.values()):
            guest.close()
        self.guests.clear()
        try:
            with self.slots.capture() as out:
                self.slots.down(self.caller, None, no_block=True)
            sys.stderr.write(out.getvalue())
        except (Refused, OSError) as error:
            print(f"microvm: {error}", file=sys.stderr)

    # Claude Code.

    def reply(self, msg_id: Any, result: dict[str, Any]) -> None:
        self.send_client({"jsonrpc": "2.0", "id": msg_id, "result": result})

    def fail(self, msg_id: Any, code: int, message: str) -> None:
        self.send_client({"jsonrpc": "2.0", "id": msg_id, "error": {"code": code, "message": message}})

    def list_changed(self) -> None:
        self.send_client({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})

    def from_client(self, msg: dict[str, Any]) -> None:
        method = msg.get("method")
        if method is None:
            return  # a response; this server sends Claude Code no requests
        if "id" not in msg:
            if method == "notifications/cancelled":
                self.cancel((msg.get("params") or {}).get("requestId"), msg)
            return
        params = msg.get("params") or {}
        if method == "initialize":
            self.reply(
                msg["id"],
                {
                    "protocolVersion": params.get("protocolVersion") or PROTOCOL_VERSION,
                    "capabilities": {"tools": {"listChanged": True}},
                    "serverInfo": SERVER_INFO,
                },
            )
        elif method == "ping":
            self.reply(msg["id"], {})
        elif method == "tools/list":
            self.reply(msg["id"], {"tools": manager_tools(self.slots) + self.guest_tools})
        elif method == "tools/call":
            self.call(msg["id"], params)
        else:
            self.fail(msg["id"], -32601, f"no method {method}")

    def cancel(self, request_id: Any, msg: dict[str, Any]) -> None:
        for guest in self.guests.values():
            for guest_id, answers in guest.pending.items():
                if answers == ("call", request_id):
                    try:
                        guest.send(dict(msg, params=dict(msg.get("params") or {}, requestId=guest_id)))
                    except OSError:
                        pass
                    return

    def call(self, msg_id: Any, params: dict[str, Any]) -> None:
        name = params.get("name")
        args = params.get("arguments") or {}
        if name in MANAGER_TOOLS:
            threading.Thread(target=self.work, args=(name, args, msg_id), daemon=True).start()
            return
        if name in self.exposed:
            kind, original = self.exposed[name]
            guest = self.guests[kind]
            try:
                guest.request("tools/call", dict(params, name=original), ("call", msg_id))
            except OSError:
                self.drop(guest, "the connection to its MCP server dropped")
            return
        self.reply(msg_id, text_result(f"no tool named {name}", is_error=True))

    # The tools of this server.

    def work(self, name: str, args: dict[str, Any], msg_id: Any) -> None:
        """Run a tool of this server, in a thread of its own, and hand
        the outcome to the loop."""
        error = None
        with self.slots.capture() as out:
            try:
                if name == "microvm_up":
                    kind = args.get("kind")
                    if kind not in self.slots.kinds:
                        raise Refused(
                            f"unknown kind {kind!r}; the kinds agents may use are "
                            f"{', '.join(sorted(self.slots.kinds)) or 'none'}"
                        )
                    self.slots.up(kind, self.caller)
                elif name == "microvm_down":
                    slot = args.get("slot")
                    if slot is not None and slot not in self.slots.slots:
                        raise Refused(
                            f"unknown slot {slot!r}; the slots agents may use are "
                            f"{', '.join(sorted(self.slots.slots)) or 'none'}"
                        )
                    self.slots.down(self.caller, slot)
                else:
                    self.slots.status(self.caller, bool(args.get("all")))
            except (Refused, OSError) as e:
                error = str(e)
            except Exception as e:  # noqa: BLE001 (report to the agent, keep serving)
                error = f"{name} failed: {e}"
        self.events.put(("done", name, args, msg_id, out.getvalue(), error))

    def done(self, name: str, args: dict[str, Any], msg_id: Any, text: str, error: str | None) -> None:
        if name == "microvm_down":
            self.drop_stopped()
        if error is not None:
            self.reply(msg_id, text_result(text + error, is_error=True))
        elif name == "microvm_up":
            self.connect_guest(args["kind"], msg_id, text)
        else:
            self.reply(msg_id, text_result(text))

    def drop_stopped(self) -> None:
        """Close the connections to the guests whose slot this session
        no longer holds."""
        leases = self.slots.leases()
        for guest in list(self.guests.values()):
            lease = leases.get(guest.slot)
            if lease is None or not self.slots.holds(self.caller, lease):
                self.drop(guest, "it was stopped")

    # The guests.

    def held(self, kind: str) -> str | None:
        leases = self.slots.leases()
        for slot in self.slots.kinds[kind]:
            if slot in leases and self.slots.holds(self.caller, leases[slot]):
                return slot
        return None

    def connect_guest(self, kind: str, msg_id: Any, text: str) -> None:
        """After `microvm_up` of `kind`: connect to the MCP server of its
        guest when the kind serves MCP, and answer the call once the
        tools of the guest are listed."""
        if self.slots.kind_info[kind].get("mcp") is None:
            self.reply(msg_id, text_result(text))
            return
        slot = self.held(kind)
        guest = self.guests.get(kind)
        if guest is not None and guest.slot != slot:
            self.drop(guest, "this session holds another slot of its kind now")
            guest = None
        if guest is not None and guest.state == "ready":
            self.reply(msg_id, text_result(text + self.tools_line(kind)))
            return
        self.waiting.setdefault(kind, []).append((msg_id, text))
        if guest is not None:
            return  # the connection is being set up
        if slot is None:
            self.answer_waiting(kind, f"the {kind} guest is no longer held by this session", is_error=True)
            return
        info = self.slots.slots[slot]
        try:
            sock = self.connect(info["cid"], info["vsockPort"])
        except OSError as e:
            self.answer_waiting(
                kind,
                f"the MCP server of {slot} at vsock {info['cid']}:{info['vsockPort']} refused the connection: {e}",
                is_error=True,
            )
            return
        self.generation += 1
        guest = Guest(kind, slot, self.generation, sock, self.deliver)
        self.guests[kind] = guest
        try:
            guest.request(
                "initialize",
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "capabilities": {},
                    "clientInfo": {"name": "microvm", "version": SERVER_INFO["version"]},
                },
                ("initialize",),
            )
        except OSError:
            self.drop(guest, "the connection to its MCP server dropped")

    def tools_line(self, kind: str) -> str:
        names = [name for name, (owner, _) in self.exposed.items() if owner == kind]
        return f"the tools of its MCP server are tools of this server now: {', '.join(names) or 'none'}"

    def answer_waiting(self, kind: str, line: str, is_error: bool = False) -> None:
        for msg_id, text in self.waiting.pop(kind, []):
            self.reply(msg_id, text_result(text + line, is_error=is_error))

    def from_guest(self, guest: Guest, msg: dict[str, Any]) -> None:
        method = msg.get("method")
        if method is None:
            answers = guest.pending.pop(msg.get("id"), None)
            if answers is not None:
                self.guest_response(guest, answers, msg)
            return
        if "id" in msg:
            # A request of the guest. This server answers ping and
            # refuses the rest, since it offers the guest nothing.
            try:
                if method == "ping":
                    guest.send({"jsonrpc": "2.0", "id": msg["id"], "result": {}})
                else:
                    guest.send(
                        {"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": f"no method {method}"}}
                    )
            except OSError:
                self.drop(guest, "the connection to its MCP server dropped")
            return
        if method == "notifications/tools/list_changed" and guest.state == "ready":
            self.list_tools(guest, [])
        elif method in FORWARDED_NOTIFICATIONS:
            self.send_client(msg)

    def guest_response(self, guest: Guest, answers: tuple, msg: dict[str, Any]) -> None:
        step = answers[0]
        if step == "call":
            self.send_client(dict(msg, id=answers[1]))
        elif step == "initialize":
            if "error" in msg:
                self.drop(guest, f"its MCP server refused initialize: {msg['error'].get('message')}")
                return
            try:
                guest.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
            except OSError:
                self.drop(guest, "the connection to its MCP server dropped")
                return
            guest.state = "listing"
            self.list_tools(guest, [])
        elif step == "list":
            if "error" in msg:
                if guest.state == "listing":
                    self.drop(guest, f"its MCP server refused tools/list: {msg['error'].get('message')}")
                return
            result = msg.get("result") or {}
            tools = answers[1] + [tool for tool in result.get("tools") or [] if isinstance(tool, dict)]
            cursor = result.get("nextCursor")
            if cursor:
                self.list_tools(guest, tools, cursor)
                return
            first = guest.state != "ready"
            guest.tools = tools
            guest.state = "ready"
            self.rebuild()
            self.list_changed()
            if first:
                self.answer_waiting(guest.kind, self.tools_line(guest.kind))

    def list_tools(self, guest: Guest, so_far: list, cursor: str | None = None) -> None:
        try:
            guest.request("tools/list", {"cursor": cursor} if cursor else {}, ("list", so_far))
        except OSError:
            self.drop(guest, "the connection to its MCP server dropped")

    def rebuild(self) -> None:
        """Name the tools of the guests. The guest connected first keeps
        a name both offer, and a later one gets the prefix `<kind>_`."""
        used = set(MANAGER_TOOLS)
        self.exposed = {}
        self.guest_tools = []
        for guest in sorted(self.guests.values(), key=lambda g: g.generation):
            if guest.state != "ready":
                continue
            for tool in guest.tools:
                original = tool.get("name")
                if not isinstance(original, str):
                    continue
                name = original
                tool = dict(tool)
                if name in used:
                    name = f"{guest.kind}_{original}"
                    tool["description"] = (
                        f"The tool {original} of the {guest.kind} guest, renamed because another tool has "
                        f"that name. " + str(tool.get("description") or "")
                    ).strip()
                if name in used:
                    print(f"microvm: the tool {original} of {guest.slot} is left out: {name} is taken", file=sys.stderr)
                    continue
                used.add(name)
                tool["name"] = name
                self.exposed[name] = (guest.kind, original)
                self.guest_tools.append(tool)

    def drop(self, guest: Guest, reason: str) -> None:
        """Close the connection to `guest`, fail what waits on it, and
        remove its tools."""
        if self.guests.get(guest.kind) is not guest:
            return
        del self.guests[guest.kind]
        guest.close()
        for answers in guest.pending.values():
            if answers[0] == "call":
                self.fail(answers[1], -32000, f"the {guest.kind} guest {guest.slot} is gone: {reason}")
        guest.pending.clear()
        self.answer_waiting(guest.kind, f"the MCP server of {guest.slot} is not available: {reason}", is_error=True)
        if guest.state == "ready":
            self.rebuild()
            self.list_changed()


def serve(slots: Slots, caller: Caller) -> int:
    lock = threading.Lock()

    def send(msg: dict[str, Any]) -> None:
        with lock:
            sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
            sys.stdout.flush()

    server = Server(slots, caller, send)
    # SystemExit unwinds through the cleanup of `run`.
    for signum in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, lambda *_: sys.exit(0))
    threading.Thread(target=read_lines, args=(sys.stdin, server.client), daemon=True).start()
    return server.run()
