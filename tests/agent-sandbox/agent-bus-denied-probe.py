# SPDX-License-Identifier: MIT
"""Run by real Codex inside its native command sandbox, in a checkout that
is not enrolled with the agent-sandbox module `agent-bus`, under Nix check.

The daemon is running outside the sandbox; the socket must be refused, not
merely missing from the PATH, so the probe calls the CLI by its store path."""

import os
import subprocess
from pathlib import Path

root = Path.cwd()
agent_bus = (root / "agent-bus-path").read_text().strip()
socket = Path(os.environ["XDG_STATE_HOME"]) / "agent-bus/socket"

assert "AGENT_BUS_SOCKET" not in os.environ, os.environ["AGENT_BUS_SOCKET"]
ls = subprocess.run([agent_bus, "--socket", str(socket), "ls"], capture_output=True, text=True)
assert ls.returncode != 0, ls.stdout
assert "Permission denied" in ls.stderr, ls.stderr
# The error names the missing grant, so an agent reading it is not sent
# looking for a stopped daemon.
assert "agent-sandbox module `agent-bus`" in ls.stderr, ls.stderr

(root / "agent-bus-denied-passed").write_text("passed")
print("agent-bus socket refused without the module")
