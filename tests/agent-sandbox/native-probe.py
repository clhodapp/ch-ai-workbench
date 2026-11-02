# SPDX-License-Identifier: MIT
"""Run by real Codex inside its native command sandbox, under Nix check."""

import json
import os
import socket
import subprocess
import sys
import urllib.request
from pathlib import Path

root = Path.cwd()
(root / "native-write").write_text("allowed")
Path(os.environ["TMPDIR"], "native-write").write_text("allowed")
# zsh's default /tmp/zsh prefix is read-only even when TMPDIR is writable.
heredoc = subprocess.run(["zsh", "-f", "-c", "cat <<'EOF'\nheredoc works\nEOF\n"],
                         capture_output=True, text=True)
assert heredoc.returncode == 0, heredoc.stderr
assert heredoc.stdout == "heredoc works\n", heredoc.stdout
# Exercise both the workspace repository and submodule metadata, which
# lives under the enclosing .git/modules directory.
for directory in (root, root / "child"):
    (directory / "git-write-probe").write_text("allowed")
    for args in (["add", "git-write-probe"],
                 ["-c", "user.name=Sandbox test", "-c", "user.email=sandbox@example.invalid",
                  "commit", "-qm", "sandbox write probe"],
                 ["update-ref", "refs/remotes/origin/probe", "HEAD"]):
        result = subprocess.run(["git", "-C", str(directory), *args], capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
# The shared server's process-identity check requires ps on the same PATH.
identity = subprocess.run(["ps", "-p", str(os.getpid()), "-o", "pid="], capture_output=True, text=True)
assert identity.returncode == 0 and int(identity.stdout.strip()) == os.getpid(), identity.stderr
for path in (Path("/build/home/outside"), root / ".agent-sandbox/binding.json",
             root / ".agents/guard-probe", root / ".codex/guard-probe", root / ".aws/guard-probe",
             Path(os.environ["AGENT_SANDBOX_CODEX_POLICY"])):
    try:
        with path.open("a") as target:
            target.write("UNEXPECTED WRITE")
    except PermissionError:
        pass
    except OSError as error:
        assert error.errno == 30, error
    else:
        raise AssertionError(f"native sandbox allowed a write to {path}")

url = "http://127.0.0.2:18799/models"
with urllib.request.urlopen(url, timeout=5) as response:
    assert json.load(response)["object"] == "list"

# OpenSSH needs a local passwd identity and an explicit CONNECT transport;
# unlike gh and curl it does not consume HTTP_PROXY itself.
ssh = subprocess.run(["ssh", "-G", "-o", "BatchMode=yes", "git@127.0.0.2"],
                     capture_output=True, text=True)
assert ssh.returncode == 0, ssh.stderr
assert "proxycommand " in ssh.stdout and "PROXY:" in ssh.stdout, ssh.stdout
with socket.socket(socket.AF_UNIX) as sock:
    sock.connect(os.environ["AGENT_SANDBOX_EMACS_MCP"])

# An empty list must narrow even a socket the parent domain permits.
policy = json.loads(Path(os.environ["AGENT_SANDBOX_CODEX_POLICY"]).read_text())
empty = subprocess.run([
    policy["landlock"], "--restrict-sockets", "--socket-fallback", "closed", "--", sys.executable, "-c",
    "import os,socket; socket.socket(socket.AF_UNIX).connect(os.environ['AGENT_SANDBOX_EMACS_MCP'])",
], capture_output=True)
assert empty.returncode != 0 and b"PermissionError" in empty.stderr, empty.stderr
with socket.socket(socket.AF_UNIX) as sock:
    try:
        sock.connect("/build/home/forbidden.sock")
    except PermissionError:
        pass
    else:
        raise AssertionError("Landlock allowed an unlisted socket")

# Running another bwrap must not let a hostile workload detach guards.
attempt = subprocess.run(["bwrap", "--unshare-user", "--ro-bind", "/", "/", "true"],
                         capture_output=True)
assert attempt.returncode != 0, "nested user namespaces remained available"
(root / "native-probe-passed").write_text("passed")
print("native filesystem, network, sockets and namespace checks passed")
