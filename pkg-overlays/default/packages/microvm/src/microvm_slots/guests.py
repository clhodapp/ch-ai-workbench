# SPDX-License-Identifier: MIT
"""Connections to the MCP servers of guests.

A guest of a kind that serves MCP listens on the vsock port of its kind.
The `microvm` MCP server opens one connection per running guest, speaks
MCP to it as a client, one JSON-RPC message per line, and hands every
message the guest sends to a callback.
"""

from __future__ import annotations

import json
import socket
import threading
from typing import Any, Callable


def vsock_connect(cid: int, port: int) -> socket.socket:
    """A connection to port `port` of the guest with CID `cid`."""
    sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    try:
        sock.settimeout(5.0)
        sock.connect((cid, port))
        sock.settimeout(None)
    except OSError:
        sock.close()
        raise
    return sock


def read_lines(stream: Any, put: Callable[[dict[str, Any] | None], None]) -> None:
    """Parse one JSON-RPC message per line from `stream` and hand each to
    `put`, then None at the end of the stream."""
    try:
        for line in stream:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if isinstance(msg, dict):
                put(msg)
    except (OSError, ValueError):
        pass
    put(None)


class Guest:
    """One connection to the MCP server of the guest in `slot`. The
    connection numbers its requests itself, so they never meet the IDs
    of Claude Code. A thread reads what the guest sends and passes each
    message, then None when the connection ends, to `deliver`."""

    def __init__(
        self,
        kind: str,
        slot: str,
        generation: int,
        sock: socket.socket,
        deliver: Callable[["Guest", dict[str, Any] | None], None],
    ) -> None:
        self.kind = kind
        self.slot = slot
        self.generation = generation
        self.sock = sock
        # "initializing", then "listing" while the first tools/list is
        # out, then "ready".
        self.state = "initializing"
        self.tools: list[dict[str, Any]] = []
        self.next_id = 0
        # Requests sent to the guest: the ID the connection gave each,
        # to what it answers (an ID of Claude Code, or a step of setup).
        self.pending: dict[str, Any] = {}
        self.closed = False
        reader = sock.makefile("r", encoding="utf-8")
        threading.Thread(target=read_lines, args=(reader, lambda msg: deliver(self, msg)), daemon=True).start()

    def request(self, method: str, params: dict[str, Any], answers: Any) -> str:
        self.next_id += 1
        request_id = f"microvm-{self.generation}-{self.next_id}"
        self.pending[request_id] = answers
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        return request_id

    def send(self, msg: dict[str, Any]) -> None:
        self.sock.sendall((json.dumps(msg, ensure_ascii=False) + "\n").encode())

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()
