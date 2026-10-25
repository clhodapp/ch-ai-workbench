# SPDX-License-Identifier: MIT
"""Connections to the vsock port of a guest.

A slot reaches its guest in one of two ways. Without a vsock socket,
the program connects an `AF_VSOCK` socket to `<cid>:<port>`. With a
vsock socket, the guest runs under cloud-hypervisor, whose hybrid vsock
is a Unix socket on the host. The program connects to that socket,
sends `CONNECT <port>\\n`, and reads one line. The VMM answers
`OK <host-port>\\n` when the guest accepts the connection. Any other
line, or the end of the stream, means the guest refused it. After the
answer, the stream is the connection to the port of the guest.

The readiness probe of `up` and the connection to the MCP server of a
guest both go through `connect`.
"""

from __future__ import annotations

import socket
from dataclasses import dataclass

# The longest answer to CONNECT the program reads. `OK <host-port>\n`
# is far shorter.
MAX_ANSWER = 64


@dataclass(frozen=True)
class Endpoint:
    """The vsock port of the guest in `slot`. With `vsock_socket`, the
    program reaches it through the hybrid vsock of cloud-hypervisor at
    that path, and through `AF_VSOCK` to `cid` otherwise."""

    slot: str
    cid: int
    port: int
    vsock_socket: str | None = None

    def __str__(self) -> str:
        if self.vsock_socket is not None:
            return f"vsock port {self.port} through {self.vsock_socket}"
        return f"vsock {self.cid}:{self.port}"


def connect(endpoint: Endpoint, timeout: float) -> socket.socket:
    """A connection to the port of `endpoint`. Connecting, and the
    exchange of the hybrid vsock, each wait at most `timeout` seconds.
    The returned socket blocks without a timeout. A failure raises
    OSError, with a message that names the slot."""
    if endpoint.vsock_socket is None:
        return vsock_connect(endpoint, timeout)
    return hybrid_connect(endpoint, timeout)


def probe(endpoint: Endpoint, timeout: float) -> None:
    """Return when the guest accepts a connection on the port of
    `endpoint`, and raise OSError as `connect` does when it does not."""
    connect(endpoint, timeout).close()


def vsock_connect(endpoint: Endpoint, timeout: float) -> socket.socket:
    sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    try:
        sock.settimeout(timeout)
        sock.connect((endpoint.cid, endpoint.port))
        sock.settimeout(None)
    except BaseException:
        sock.close()
        raise
    return sock


def hybrid_connect(endpoint: Endpoint, timeout: float) -> socket.socket:
    path = endpoint.vsock_socket
    assert path is not None
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(timeout)
        try:
            sock.connect(path)
        except FileNotFoundError:
            raise FileNotFoundError(
                f"the vsock socket {path} of {endpoint.slot} does not exist; the VMM of {endpoint.slot} does not run"
            ) from None
        except PermissionError:
            raise PermissionError(
                f"permission denied on the vsock socket {path} of {endpoint.slot}; "
                f"the user must be an operator of {endpoint.slot}"
            ) from None
        except ConnectionRefusedError:
            raise ConnectionRefusedError(
                f"nothing listens on the vsock socket {path} of {endpoint.slot}; "
                f"the VMM of {endpoint.slot} does not run"
            ) from None
        try:
            sock.sendall(f"CONNECT {endpoint.port}\n".encode())
            answer = read_answer(sock)
        except TimeoutError:
            raise TimeoutError(
                f"the VMM of {endpoint.slot} did not answer CONNECT {endpoint.port} on {path} "
                f"within {timeout:g} seconds"
            ) from None
        if not answer.startswith(b"OK "):
            shown = answer.decode("utf-8", "replace").strip()
            raise ConnectionRefusedError(
                f"{endpoint.slot} refused CONNECT {endpoint.port} on {path}: "
                + (f"the VMM answered {shown!r}" if shown else "the VMM closed the connection")
            )
        sock.settimeout(None)
    except BaseException:
        sock.close()
        raise
    return sock


def read_answer(sock: socket.socket) -> bytes:
    """The line the VMM answers CONNECT with, read a byte at a time so
    that nothing the guest sends after it is consumed. The result ends
    without its newline, and is empty or partial when the stream ends
    first."""
    answer = bytearray()
    while len(answer) < MAX_ANSWER:
        byte = sock.recv(1)
        if not byte or byte == b"\n":
            break
        answer += byte
    return bytes(answer)
