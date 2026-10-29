# SPDX-License-Identifier: MIT
"""A stand-in for the Emacs MCP bridge, which agent-sandbox serves from
outside the sandbox. It speaks MCP on stdio and offers one tool, `mark`.
A call appends the server's working directory to the file named in
FAKE_MCP_MARKS, which only a process outside the sandbox can write.
When FAKE_MCP_STARTED names a file, `initialize` appends the working
directory there too, which shows that an agent started the server."""

import json
import os
import sys


def reply(msg_id, result):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg_id, "result": result}) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    msg = json.loads(line)
    method = msg.get("method")
    if os.environ.get("FAKE_MCP_METHODS"):
        with open(os.environ["FAKE_MCP_METHODS"], "a") as methods:
            methods.write(json.dumps(msg) + "\n")
    if "id" not in msg:
        continue
    if method == "initialize":
        if os.environ.get("FAKE_MCP_STARTED"):
            with open(os.environ["FAKE_MCP_STARTED"], "a") as started:
                started.write(os.getcwd() + "\n")
        reply(
            msg["id"],
            {
                "protocolVersion": msg.get("params", {}).get("protocolVersion", "2025-06-18"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "fake-emacs", "version": "0"},
            },
        )
    elif method == "tools/list":
        reply(
            msg["id"],
            {
                "tools": [
                    {
                        "name": "mark",
                        "description": "Record that the agent reached this server.",
                        "inputSchema": {"type": "object", "properties": {}},
                    }
                ]
            },
        )
    elif method == "tools/call":
        with open(os.environ["FAKE_MCP_MARKS"], "a") as marks:
            marks.write(os.getcwd() + "\n")
        reply(msg["id"], {"content": [{"type": "text", "text": "marked"}]})
    else:
        reply(msg["id"], {})
