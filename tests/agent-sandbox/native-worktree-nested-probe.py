# SPDX-License-Identifier: MIT
"""Read-only commands under a nested directory of an inherited worktree."""
import os
import subprocess
from pathlib import Path

cwd = Path.cwd()
assert cwd.parts[-2:] == (".scratch", "nested-probe")
assert Path(os.environ["AGENT_SANDBOX_ROOT"]) != cwd
assert subprocess.run(["git", "status", "--short"], capture_output=True).returncode == 0
assert (cwd.parents[1] / ".agent-sandbox/codex-config.json").read_text()
(cwd / "nested-passed").touch()
print("nested inherited worktree default execution passed")
