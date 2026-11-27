# SPDX-License-Identifier: MIT
"""Run by real Claude Code inside its Bash sandbox, in a checkout whose
modules declare unix sockets, so the command runs under the socket-restriction step.

srt relays the sandbox's loopback proxy port to the proxy's unix socket
from the same shell that runs the command. The request reaches the mock
model API on 127.0.0.2, which the module `mock` allows, only through that
relay."""

import json
import os
import urllib.request
from pathlib import Path

assert os.environ.get("SANDBOX_RUNTIME"), "not inside Claude Code's sandbox"
assert os.environ.get("HTTP_PROXY"), "no proxy in the sandbox"

with urllib.request.urlopen("http://127.0.0.2:18799/models", timeout=10) as response:
    listing = json.load(response)
assert listing["data"][0]["id"] == "mock-model", listing

Path("claude-network-passed").touch()
