# SPDX-License-Identifier: MIT
"""Run by real Codex inside its native command sandbox, and by real Claude
Code inside its Bash sandbox, in a checkout that is not enrolled with the
agent-sandbox module `agent-bus`, under Nix check.

The daemon is running outside the sandbox. The probe connects to its
socket directly, so the result shows the socket refused rather than the
CLI missing. Claude Code's sandbox shows a checkout only the store paths
of its modules, so there the CLI is absent as well; where the CLI is
present, the probe also checks the error it prints."""

import errno
import os
import socket
import subprocess
from pathlib import Path

root = Path.cwd()
agent_bus = (root / "agent-bus-path").read_text().strip()
path = Path(os.environ["XDG_STATE_HOME"]) / "agent-bus/socket"

assert "AGENT_BUS_SOCKET" not in os.environ, os.environ["AGENT_BUS_SOCKET"]

client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    client.connect(str(path))
except OSError as error:
    # Landlock and seccomp refuse the connect; a sandbox that also hides
    # the socket file reports it missing.
    assert error.errno in (errno.EACCES, errno.EPERM, errno.ENOENT), error
    refusal = errno.errorcode[error.errno]
else:
    ancestry = []
    pid = os.getpid()
    while pid > 1:
        status = Path(f"/proc/{pid}/status").read_text()
        fields = dict(line.split(":\t", 1) for line in status.splitlines() if ":\t" in line)
        cmd = Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode()[:200]
        ancestry.append(f"{pid} seccomp={fields.get('Seccomp', '?').strip()} "
                        f"nnp={fields.get('NoNewPrivs', '?').strip()} {cmd}")
        pid = int(fields["PPid"])
    raise AssertionError(
        f"the sandbox allowed a connection to {path}; "
        f"SHELL={os.environ.get('SHELL')} SANDBOX_RUNTIME={os.environ.get('SANDBOX_RUNTIME')!r} "
        f"AGENT_SANDBOX_UNIX_SOCKETS={os.environ.get('AGENT_SANDBOX_UNIX_SOCKETS')!r}\n" + "\n".join(ancestry))

if os.path.exists(agent_bus):
    ls = subprocess.run([agent_bus, "--socket", str(path), "ls"], capture_output=True, text=True, check=False)
    assert ls.returncode != 0, ls.stdout
    if refusal in ("EACCES", "EPERM"):
        # The error names the missing grant, so an agent reading it is
        # not sent looking for a stopped daemon.
        assert "agent-sandbox module `agent-bus`" in ls.stderr, ls.stderr
    cli = "present"
else:
    cli = "absent"

(root / "agent-bus-denied-passed").write_text("passed")
print(f"agent-bus socket refused without the module ({refusal}; the CLI is {cli})")
