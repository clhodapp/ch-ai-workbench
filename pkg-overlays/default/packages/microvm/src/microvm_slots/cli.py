# SPDX-License-Identifier: MIT
"""The command line of `microvm`.

The program accepts only its verbs and the kind and slot names of the
generated configuration, and refuses everything else before it reads
any state. `MICROVM_CONFIG`, the path of the generated configuration,
comes from the wrapper the home-manager module builds.

The holder of what a call claims is a process. For `mcp`, which Claude
Code starts as an MCP server, it is the parent process, Claude Code
itself. For the other verbs it is the process `CLAUDE_PID` names when
that variable is set, and the parent process otherwise: the shell a
user types the command in.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

from .slots import Caller, Refused, Slots, start_time

VERBS = ("up", "status", "down", "reap", "mcp")

USAGE = """usage:
  microvm up <kind>        lease a slot of <kind> to the calling process, start it, wait until it answers
  microvm status [--all]   the slots of the calling process, or with --all every slot and its holder
  microvm down [<slot>]    stop the slots of the calling process, or one of them
  microvm reap             stop every slot whose holder process is gone
  microvm mcp              serve the guests of the kinds agents may use over MCP on stdio"""

SESSION_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")


class UsageError(Exception):
    pass


def parse(argv: list[str], config: dict) -> tuple[str, str | None, bool]:
    """The verb, its name argument and the --all flag, from argv. Any
    argument that is not one of these is refused."""
    kinds: dict[str, dict] = config["kinds"]
    slots = {slot["name"] for info in kinds.values() for slot in info["slots"]}
    if not argv:
        raise UsageError("no verb given")
    verb, rest = argv[0], argv[1:]
    if verb not in VERBS:
        raise UsageError(f"unknown verb {verb!r}; the verbs are {', '.join(VERBS)}")
    if verb == "up":
        if len(rest) != 1:
            raise UsageError("up takes one kind")
        if rest[0] not in kinds:
            raise UsageError(f"unknown kind {rest[0]!r}; the kinds are {', '.join(sorted(kinds)) or 'none'}")
        return verb, rest[0], False
    if verb == "status":
        if rest not in ([], ["--all"]):
            raise UsageError("status takes only --all")
        return verb, None, rest == ["--all"]
    if verb == "down":
        if len(rest) > 1:
            raise UsageError("down takes at most one slot")
        if rest and rest[0] not in slots:
            raise UsageError(f"unknown slot {rest[0]!r}; the slots are {', '.join(sorted(slots)) or 'none'}")
        return verb, (rest[0] if rest else None), False
    if rest:
        raise UsageError(f"{verb} takes no arguments")
    return verb, None, False


def session_from(env: dict[str, str]) -> str | None:
    """The session ID of Claude Code, when the environment carries a
    well-formed one. It is for display only."""
    session = env.get("CLAUDE_CODE_SESSION_ID") or None
    if session is not None and not SESSION_PATTERN.fullmatch(session):
        return None
    return session


def caller_from(env: dict[str, str], proc_root: Path, parent: int, *, claude_pid: bool) -> Caller:
    """The holding process: the process `CLAUDE_PID` names when
    `claude_pid` is true and the variable is set, and `parent`
    otherwise."""
    raw_pid = (env.get("CLAUDE_PID") or None) if claude_pid else None
    if raw_pid is not None:
        if not raw_pid.isdigit() or int(raw_pid) <= 0:
            raise Refused("CLAUDE_PID is not a process ID")
        pid = int(raw_pid)
    else:
        pid = parent
    start = start_time(proc_root, pid)
    if start is None:
        raise Refused(f"the holding process {pid} does not run")
    return Caller(session=session_from(env), pid=pid, start=start)


def main(argv: list[str] | None = None, env: dict[str, str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    env = dict(os.environ) if env is None else env
    try:
        config_path = env.get("MICROVM_CONFIG")
        if not config_path:
            raise Refused("MICROVM_CONFIG is not set; run the microvm command the home-manager module installs")
        config = json.loads(Path(config_path).read_text())
        try:
            verb, name, everything = parse(argv, config)
        except UsageError as error:
            print(f"microvm: {error}\n{USAGE}", file=sys.stderr)
            return 2

        # The MCP server writes the protocol to stdout, so what the
        # program says there goes to stderr.
        served = verb == "mcp"
        slots = Slots(config, agents_only=served, out=sys.stderr if served else sys.stdout)
        if verb == "reap":
            slots.reap()
            return 0
        caller = caller_from(env, slots.proc_root, os.getppid(), claude_pid=not served)

        if verb == "up":
            slots.up(name, caller)
        elif verb == "status":
            slots.status(caller, everything)
        elif verb == "down":
            slots.down(caller, name)
        elif verb == "mcp":
            from .mcp import serve

            return serve(slots, caller)
        return 0
    except Refused as error:
        print(f"microvm: {error}", file=sys.stderr)
        return 1
    except (OSError, ValueError) as error:
        print(f"microvm: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
