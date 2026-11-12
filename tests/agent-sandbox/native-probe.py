# SPDX-License-Identifier: MIT
"""Run by real Codex inside its native command sandbox, under Nix check."""

import json
import http.server
import os
import socket
import subprocess
import sys
import threading
import tomllib
import urllib.request
from pathlib import Path

root = Path.cwd()
# Normal clients must reach servers started by the test itself, without
# proxying namespace-local loopback to a host-side network proxy.
class TestHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"sandbox-local")

    def log_message(self, *args):
        pass

with http.server.HTTPServer(("127.0.0.1", 0), TestHandler) as local_server:
    serving = threading.Thread(target=local_server.handle_request)
    serving.start()
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{local_server.server_port}/", timeout=5) as response:
            assert response.read() == b"sandbox-local"
    finally:
        serving.join(timeout=6)
    assert not serving.is_alive()

(root / "native-write").write_text("allowed")
Path(os.environ["TMPDIR"], "native-write").write_text("allowed")
scratch = Path(os.environ["TMPDIR"])
assert scratch.is_symlink(), "native scratch must use the disk-backed allocation"
assert scratch.resolve().parent == Path(os.environ["XDG_STATE_HOME"]) / "agent-sandbox/tmp"
# Conventional temporary paths expose only this runtime's granted scratch.
assert not Path("/tmp/agent-sandbox-host-temp-marker").exists()
for directory in ("/tmp", "/var/tmp"):
    if not Path(directory).is_dir():
        continue
    target = Path(directory) / "native-private-temp"
    target.write_text("private scratch")
    assert Path(os.environ["TMPDIR"], target.name).read_text() == "private scratch"
    target.unlink()
# zsh heredocs also work when a tool uses its default temporary prefix.
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
# The host keyring is not reachable through the session bus. A narrow
# broker supplies gh's token in memory, while gh remains sandboxed.
credential = subprocess.run(["gh", "auth", "token", "--hostname", "github.com"], capture_output=True, text=True)
assert credential.returncode == 0, credential.stderr
assert credential.stdout.strip() == "sandbox-test-github-token"
without_marker = subprocess.run(["gh", "auth", "git-credential", "get"],
    input="protocol=https\nhost=github.com\n\n", capture_output=True, text=True,
    env={key: value for key, value in os.environ.items() if key != "SANDBOX_RUNTIME"})
assert without_marker.returncode == 0, without_marker.stderr
assert "password=sandbox-test-github-token" in without_marker.stdout
explicit = subprocess.run(["gh", "auth", "token", "--hostname", "github.com"],
                          env={**os.environ, "GH_TOKEN": "explicit-test-token"}, capture_output=True, text=True)
assert explicit.returncode == 0 and explicit.stdout.strip() == "explicit-test-token"
rejected = subprocess.run(["github-auth-token", "--hostname", "other.invalid"], capture_output=True)
assert rejected.returncode != 0 and not rejected.stdout
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
enrollment = tomllib.loads((root / ".codex/config.toml").read_text())
assert enrollment["permissions"] == policy["config"]["permissions"]
assert enrollment["shell_environment_policy"]["set"] == {
    "SANDBOX_RUNTIME": "1", "AGENT_SANDBOX_ROOT": str(root),
    "PATH": policy["path"],
}
assert str(Path(os.environ["TMPDIR"]).parent) not in json.dumps(enrollment)
blocked_credential = subprocess.run([
    policy["landlock"], "--restrict-sockets", "--socket-fallback", "closed", "--",
    "gh", "auth", "token", "--hostname", "github.com",
], capture_output=True)
assert blocked_credential.returncode != 0 and not blocked_credential.stdout
assert b"sandbox credential broker failed" in blocked_credential.stderr
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
