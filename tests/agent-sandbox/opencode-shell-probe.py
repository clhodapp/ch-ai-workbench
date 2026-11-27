# SPDX-License-Identifier: MIT
"""Run by real OpenCode's bash tool, through the bash chain, in a
checkout enrolled with the module `mock`: inside srt, the checkout and
the scratch directory are writable, the home directory and the
enrollment files are not, the mock model API on 127.0.0.2 is reachable
through srt's proxy, and a host no module lists is refused."""

import json
import os
import socket
import urllib.parse
import urllib.request
from pathlib import Path

from proxy_status import connect_status

root = Path.cwd()
assert os.environ.get("SANDBOX_RUNTIME"), "the shell command did not run inside srt"
assert os.environ.get("AGENT_SANDBOX_ROOT") == str(root), os.environ.get("AGENT_SANDBOX_ROOT")

(root / "opencode-write").write_text("allowed")
Path(os.environ["TMPDIR"], "opencode-write").write_text("allowed")
for path in (Path("/build/home/outside"), root / ".agent-sandbox/binding.json",
             root / ".agent-sandbox/shell-opencode.json", root / ".claude/settings.local.json"):
    try:
        with path.open("a") as target:
            target.write("UNEXPECTED WRITE")
    except PermissionError:
        pass
    except OSError as error:
        assert error.errno == 30, error
    else:
        raise AssertionError(f"the bash chain allowed a write to {path}")

with urllib.request.urlopen("http://127.0.0.2:18799/models", timeout=10) as response:
    assert json.load(response)["object"] == "list"

status = connect_status("unlisted.invalid", 443)
assert status == 403, f"srt's proxy answered {status} for a host no module lists"

with socket.socket(socket.AF_UNIX) as sock:
    try:
        sock.connect("/build/home/forbidden.sock")
    except OSError:
        pass
    else:
        raise AssertionError("the bash chain reached a socket no module lists")

Path("opencode-shell-passed").touch()
