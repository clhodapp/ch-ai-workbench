# SPDX-License-Identifier: MIT
"""The program `microvm-mcp`, which serves the MCP server `microvm` on
stdio.

`MICROVM_MCP_CONFIG` names the configuration of the program, which the
wrapper the home-manager module builds sets. The configuration names
the configuration file of ch-microvm and the kinds agents may use, each
with the MCP server of its guest or null.

The holder of every instance the server leases is its parent process:
Claude Code, which starts the server. The label of the holder names the
session, from `CLAUDE_CODE_SESSION_ID`, so `ch-microvm status` shows
which session holds an instance.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

from ch_microvm.instances import Instances, Refused, load

CONFIG_VARIABLE = "MICROVM_MCP_CONFIG"

SESSION_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")


def label_from(env: dict[str, str]) -> str | None:
    """The label of the holder: the session ID of Claude Code, when the
    environment carries a well-formed one."""
    session = env.get("CLAUDE_CODE_SESSION_ID") or None
    if session is None or not SESSION_PATTERN.fullmatch(session):
        return None
    return f"Claude Code session {session}"


def main(argv: list[str] | None = None, env: dict[str, str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    env = dict(os.environ) if env is None else env
    if argv:
        print("microvm-mcp: the program takes no arguments; it serves MCP on stdio", file=sys.stderr)
        return 2
    try:
        config_path = env.get(CONFIG_VARIABLE)
        if not config_path:
            raise Refused(f"{CONFIG_VARIABLE} is not set; run the microvm-mcp command the home-manager module installs")
        config = json.loads(Path(config_path).read_text())
        mcp_kinds: dict[str, dict | None] = {kind: info.get("mcp") for kind, info in config["kinds"].items()}
        # What the library says goes to stderr, since the protocol owns
        # stdout.
        instances = Instances(load(config["instances"]), kinds=mcp_kinds, out=sys.stderr)
        holder = instances.holder_for(os.getppid(), label_from(env))
    except Refused as error:
        print(f"microvm-mcp: {error}", file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError) as error:
        print(f"microvm-mcp: {error}", file=sys.stderr)
        return 1

    from .mcp import serve

    return serve(instances, holder, mcp_kinds)


if __name__ == "__main__":
    sys.exit(main())
