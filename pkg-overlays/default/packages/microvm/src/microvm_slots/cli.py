# SPDX-License-Identifier: MIT
"""The command line of `microvm`.

The arguments and the session variables are untrusted: a sandboxed
agent supplies them through the trusted executable. The program accepts
only its verbs and the kind and slot names of the generated
configuration, and refuses everything else before it reads any state.

Two variables come from the wrapper the home-manager module builds, and
no caller can set them: `MICROVM_CONFIG`, the path of the generated
configuration, and `MICROVM_VERBS`, the verbs this wrapper accepts. The
wrapper behind the trusted executable accepts `up`, `status` and `down`.
The command the home installs accepts every verb.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

from .slots import Caller, Refused, Slots, start_time

VERBS = ("up", "status", "down", "reap", "connect")

USAGE = """usage:
  microvm up <kind>        lease a slot of <kind> to this session, start it, wait until it answers
  microvm status [--all]   the slots of this session, or with --all every slot and its holder
  microvm down [<slot>]    stop the slots of this session, or one of them
  microvm reap             stop every slot whose holder process is gone
  microvm connect <kind>   bring up this session's slot of <kind> and relay stdin and stdout to it"""

SESSION_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")


class UsageError(Exception):
    pass


def parse(argv: list[str], allowed: tuple[str, ...], slots: Slots) -> tuple[str, str | None, bool]:
    """The verb, its name argument and the --all flag, from argv. Any
    argument that is not one of these is refused."""
    if not argv:
        raise UsageError("no verb given")
    verb, rest = argv[0], argv[1:]
    if verb not in allowed:
        raise UsageError(f"unknown verb {verb!r}; this command accepts {', '.join(allowed)}")
    if verb in ("up", "connect"):
        if len(rest) != 1:
            raise UsageError(f"{verb} takes one kind")
        if rest[0] not in slots.kinds:
            raise UsageError(f"unknown kind {rest[0]!r}; the kinds are {', '.join(sorted(slots.kinds)) or 'none'}")
        return verb, rest[0], False
    if verb == "status":
        if rest not in ([], ["--all"]):
            raise UsageError("status takes only --all")
        return verb, None, rest == ["--all"]
    if verb == "down":
        if len(rest) > 1:
            raise UsageError("down takes at most one slot")
        if rest and rest[0] not in slots.slots:
            raise UsageError(f"unknown slot {rest[0]!r}; the slots are {', '.join(sorted(slots.slots)) or 'none'}")
        return verb, (rest[0] if rest else None), False
    if rest:
        raise UsageError(f"{verb} takes no arguments")
    return verb, None, False


def caller_from(env: dict[str, str], proc_root: Path, fallback_pid: int | None) -> Caller:
    """The calling session from CLAUDE_CODE_SESSION_ID and CLAUDE_PID.
    Without CLAUDE_PID, `fallback_pid` names the holding process."""
    session = env.get("CLAUDE_CODE_SESSION_ID") or None
    if session is not None and not SESSION_PATTERN.fullmatch(session):
        raise Refused("CLAUDE_CODE_SESSION_ID is not a session ID")
    raw_pid = env.get("CLAUDE_PID") or None
    if raw_pid is not None:
        if not raw_pid.isdigit() or int(raw_pid) <= 0:
            raise Refused("CLAUDE_PID is not a process ID")
        pid: int | None = int(raw_pid)
    else:
        pid = fallback_pid
    start = start_time(proc_root, pid) if pid is not None else None
    if raw_pid is not None and start is None:
        raise Refused(f"CLAUDE_PID names no running process ({pid})")
    return Caller(session=session, pid=pid if start is not None else None, start=start)


def main(argv: list[str] | None = None, env: dict[str, str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    env = dict(os.environ) if env is None else env
    try:
        config_path = env.get("MICROVM_CONFIG")
        if not config_path:
            raise Refused("MICROVM_CONFIG is not set; run the microvm command the home-manager module installs")
        config = json.loads(Path(config_path).read_text())
        allowed = tuple(v for v in (env.get("MICROVM_VERBS") or ",".join(VERBS)).split(",") if v in VERBS)
        # connect's stdout is the relayed stream, so what it says goes
        # to stderr.
        slots = Slots(config, out=sys.stderr if argv[:1] == ["connect"] else sys.stdout)
        try:
            verb, name, everything = parse(argv, allowed, slots)
        except UsageError as error:
            print(f"microvm: {error}\n{USAGE}", file=sys.stderr)
            return 2

        # An MCP server that Claude Code starts runs connect; its parent
        # is the Claude Code process, which then holds the slot.
        caller = caller_from(env, slots.proc_root, os.getppid() if verb == "connect" else None)
        if verb in ("status", "down") and caller.session is None and caller.pid is None:
            raise Refused(f"{verb} needs the calling session: CLAUDE_CODE_SESSION_ID or CLAUDE_PID")

        if verb == "up":
            slots.up(name, caller)
        elif verb == "status":
            slots.status(caller, everything)
        elif verb == "down":
            slots.down(caller, name)
        elif verb == "reap":
            slots.reap()
        elif verb == "connect":
            relay = slots.connect_argv(name, caller)
            sys.stdout.flush()
            os.execv(relay[0], relay)
        return 0
    except Refused as error:
        print(f"microvm: {error}", file=sys.stderr)
        return 1
    except (OSError, ValueError) as error:
        print(f"microvm: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
