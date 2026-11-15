# SPDX-License-Identifier: MIT
"""Run by real Codex inside its native command sandbox, in a checkout
enrolled with the agent-sandbox module `agent-bus`, under Nix check.

The daemon runs outside the sandbox under socket activation, and the test
registered the participant `probe-session` before Codex started."""

import json
import os
import subprocess
from pathlib import Path

root = Path.cwd()
agent_bus = (root / "agent-bus-path").read_text().strip()
expected_socket = Path(os.environ["XDG_STATE_HOME"]) / "agent-bus/socket"

# The module carries the socket's path into the sandbox.
assert os.environ.get("AGENT_BUS_SOCKET") == str(expected_socket), os.environ.get("AGENT_BUS_SOCKET")

# The CLI on the sandbox's PATH reaches the daemon.
ls = subprocess.run(["agent-bus", "ls"], capture_output=True, text=True)
assert ls.returncode == 0, ls.stderr
assert "probe-session" in ls.stdout, ls.stdout

# So does the MCP server, as OpenCode runs it inside its sandbox.
requests = [
    {"jsonrpc": "2.0", "id": 0, "method": "initialize",
     "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "probe", "version": "0"}}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "bus_whoami", "arguments": {}}},
]
mcp = subprocess.run(["agent-bus", "mcp"], input="".join(json.dumps(r) + "\n" for r in requests),
                     env={**os.environ, "AGENT_BUS_PARTICIPANT": "probe-session"},
                     capture_output=True, text=True)
assert mcp.returncode == 0, mcp.stderr
replies = [json.loads(line) for line in mcp.stdout.splitlines()]
result = replies[1]["result"]
assert result["isError"] is False, result
assert json.loads(result["content"][0]["text"])["participant"]["label"] == "probe-session"

# The store itself stays out of reach: a session changes the bus only
# through the daemon, which enforces the relationships.
store = expected_socket.with_name("bus.sqlite")
try:
    with store.open("ab") as target:
        target.write(b"UNEXPECTED WRITE")
except PermissionError:
    pass
except OSError as error:
    assert error.errno == 30, error
else:
    raise AssertionError(f"the sandbox allowed a write to {store}")

# The grant is what lets the CLI through: narrowed to no sockets, the same
# command is refused at connect.
policy = json.loads(Path(os.environ["AGENT_SANDBOX_CODEX_POLICY"]).read_text())
narrowed = subprocess.run([policy["landlock"], "--restrict-sockets", "--socket-fallback", "closed", "--",
                           agent_bus, "ls"], capture_output=True, text=True)
assert narrowed.returncode != 0, narrowed.stdout
assert "Permission denied" in narrowed.stderr, narrowed.stderr

(root / "agent-bus-probe-passed").write_text("passed")
print("agent-bus reachable through the module, and refused without its grant")
