# SPDX-License-Identifier: MIT
"""The status srt's HTTP proxy answers a CONNECT with, for the probes
that run inside srt. A host the rules refuse gets 403; a host they admit
gets the proxy's attempt to connect, which in the build sandbox, with
no DNS, fails with another status. The proxy URL carries the
credentials the proxy requires."""

import base64
import os
import socket
import urllib.parse


def connect_status(host: str, port: int) -> int:
    proxy = urllib.parse.urlsplit(os.environ.get("HTTPS_PROXY") or os.environ["HTTP_PROXY"])
    headers = f"Host: {host}:{port}\r\n"
    if proxy.username is not None:
        credentials = f"{urllib.parse.unquote(proxy.username)}:{urllib.parse.unquote(proxy.password or '')}"
        headers += f"Proxy-Authorization: Basic {base64.b64encode(credentials.encode()).decode()}\r\n"
    with socket.create_connection((proxy.hostname, proxy.port), timeout=20) as sock:
        sock.sendall(f"CONNECT {host}:{port} HTTP/1.1\r\n{headers}\r\n".encode())
        line = sock.makefile("rb").readline().decode()
    return int(line.split()[1])
