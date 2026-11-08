# SPDX-License-Identifier: MIT
"""A registered worktree inherits the primary checkout's sandbox enrollment."""
import os
import subprocess
from pathlib import Path

root = Path.cwd()
owner = Path(os.environ["AGENT_SANDBOX_ROOT"])
assert owner != root
(root / "worktree-write").write_text("allowed")
for args in (["add", "worktree-write"],
             ["-c", "user.name=Sandbox test", "-c", "user.email=sandbox@example.invalid",
              "commit", "-qm", "worktree sandbox probe"]):
    result = subprocess.run(["git", *args], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
for protected in (owner / ".agent-sandbox/binding.json", root / ".codex/config.toml",
                  root / ".agent-sandbox/codex-config.json"):
    try:
        with protected.open("a") as target:
            target.write("UNEXPECTED")
    except OSError:
        pass
    else:
        raise AssertionError(f"worktree allowed policy edits: {protected}")
credential = subprocess.run(["gh", "auth", "token", "--hostname", "github.com"],
                            capture_output=True, text=True)
assert credential.returncode == 0, credential.stderr
assert credential.stdout.strip() == "sandbox-test-github-token"
(root / "native-worktree-passed").touch()
print("inherited worktree writes, Git metadata, credentials and policy guards passed")
