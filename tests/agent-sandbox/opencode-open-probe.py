# SPDX-License-Identifier: MIT
"""Run by real OpenCode's bash tool, through the bash chain, in a
checkout whose modules grant every host (`*`): srt's proxy tries a host
no list names rather than refusing it, while IP addresses and loopback
names the rules do not list stay refused."""

import os
from pathlib import Path

from proxy_status import connect_status

assert os.environ.get("SANDBOX_RUNTIME"), "the shell command did not run inside srt"
status = connect_status("unlisted.invalid", 443)
assert status != 403, "srt's proxy refused a host in a checkout that grants every host"
for host in ("127.0.0.3", "169.254.169.254", "[::1]", "localhost", "probe.localhost"):
    status = connect_status(host, 80)
    assert status == 403, f"srt's proxy answered {status} for {host}, which no module lists"

Path("opencode-open-passed").touch()
