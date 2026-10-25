# SPDX-License-Identifier: MIT
"""The agent tools: an MCP server on stdio, started by Claude Code from
the skills-dir plugin.

A sandboxed agent cannot inspect or change its own sandbox from Bash: in
a masked enrollment the registry and parts are unreadable, the settings
and sidecar files are write-guarded, and the consent spool is outside
the write scope. Claude Code starts MCP servers outside the Bash
sandbox, so these tools can read the registry, prompt the user, and
apply the user's answer. The agent asks; only the user's answer changes
the checkout.

The checkout is the one the session was launched in
(``CLAUDE_PROJECT_DIR``, else the server's working directory): its
``.claude/settings.local.json`` is what governs the session's sandbox.

``request-module`` prompts the user, in this order:

1. ``claude-consent ask``, the workbench's prompt API. It consumes an
   answer the user already gave in a terminal to the same question, and
   with an answerer attached (Emacs, ``claude-consent watch``) it blocks
   until the user answers there.
2. With no answerer attached, an MCP elicitation: a dialog in the Claude
   Code terminal UI, when the client advertises form elicitation.
3. When the client cannot show one, or the dialog is cancelled (headless
   sessions cancel at once), the question is stored in the spool and the
   agent is told how the user answers it; calling the tool again consumes
   the answer.

An explicit refusal is recorded in the checkout's sidecar, so later
requests for that module report it instead of asking again. A dismissed
or unanswered prompt records nothing.
"""

from __future__ import annotations

import hashlib
import json
import os
import queue
import subprocess
import sys
import threading
import time
import uuid
from collections import deque
from collections.abc import Callable
from pathlib import Path
from typing import Any

from .cli import _status_line, decline_modules, enable_modules, expire_due, refusal_text
from .compose import check_known
from .files import ToolError, find_repo_root
from .registry import load_registry
from .report import (
    checkout_state,
    describe,
    describe_text,
    module_status,
    overview,
    require_enrolled,
)

SERVER_INFO = {"name": "claude-code-sandbox", "version": "0.1.0"}
PROTOCOL_VERSION = "2025-06-18"
CONSENT_ENV = "CLAUDE_CODE_SANDBOX_CONSENT"
# How long a prompt waits for the user before the request reports no
# answer. A forgotten prompt otherwise holds the agent's turn.
PROMPT_DEADLINE_SECONDS = 15 * 60
POLL_SECONDS = 0.2

# The answers that enable a module, to how long it stays chosen (None:
# until the user drops it). ``enable`` keeps its key so an answer stored
# before the time-limited choices existed still applies.
ENABLE_DURATIONS: dict[str, str | None] = {"day": "day", "week": "week", "enable": None}
# The elicitation dialog's spelling of the same answers.
ELICIT_ENABLE = {"enable for a day": "day", "enable for a week": "week", "enable permanently": "enable"}

_MODULE_ARG = {"type": "string", "description": "The sandbox module's name, as list-modules reports it."}

TOOLS: list[dict[str, Any]] = [
    {
        "name": "list-modules",
        "description": (
            "List the sandbox modules declared on this machine, each with its description, "
            "the modules it requires, and its status in this session's checkout: enabled "
            "(chosen, base, or required by another module), declined by the user, or available."
        ),
        "inputSchema": {"type": "object", "properties": {}},
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "enabled-modules",
        "description": (
            "Report this session's checkout: whether it is enrolled in the sandbox, the modules "
            "it chose, every module enabled in it with the reason (chosen, base, required by "
            "another), and whether its settings are current."
        ),
        "inputSchema": {"type": "object", "properties": {}},
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "describe-module",
        "description": (
            "Show what a sandbox module would allow: the commands and packages it puts on PATH, "
            "network domains, unix sockets, writable and readable paths, commands it runs "
            "outside the sandbox, environment, whether it unmasks the Nix store, and the modules "
            "enabling it would also enable. Also its status in this checkout."
        ),
        "inputSchema": {"type": "object", "properties": {"module": _MODULE_ARG}, "required": ["module"]},
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "declined-modules",
        "description": (
            "Report the sandbox modules the user has explicitly declined for this checkout, with "
            "when and why. Give a module name to check that one only. Do not request a declined "
            "module; tell the user what you need it for instead."
        ),
        "inputSchema": {"type": "object", "properties": {"module": _MODULE_ARG}},
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "request-module",
        "description": (
            "Ask the user to enable a sandbox module in this session's checkout. The user is "
            "prompted with what the module allows and your reason, and the call waits for the "
            "answer. The user enables it for a day, for a week, or permanently; a module enabled "
            "for a limited time is dropped at its deadline. On approval the module is enabled in "
            "the checkout's settings, but this "
            "session keeps its old sandbox rules: the user must stop the session with /stop and "
            "start it again before the module's grants apply. A refusal is recorded and later "
            "requests for the module "
            "report it without asking. Request only what the task needs, one module per call; "
            "check describe-module first."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "module": _MODULE_ARG,
                "reason": {
                    "type": "string",
                    "description": "Why the task needs this module, in a sentence the user reads in the prompt.",
                },
            },
            "required": ["module", "reason"],
        },
    },
]


class Cancelled(Exception):
    """The client cancelled the tool call being served."""


def _checkout(env: dict[str, str]) -> Path:
    start = Path(env.get("CLAUDE_PROJECT_DIR") or os.getcwd())
    root = find_repo_root(start)
    if root is None:
        raise ToolError(f"{start} is not inside a git checkout, so it has no sandbox enrollment")
    return root


def _text(value: Any) -> str:
    return value if isinstance(value, str) else json.dumps(value, indent=2, ensure_ascii=False)


class Server:
    """One MCP session. ``incoming`` yields parsed client messages (None
    at end of input); ``send`` writes one message to the client."""

    def __init__(
        self,
        incoming: queue.Queue[dict[str, Any] | None],
        send: Callable[[dict[str, Any]], None],
        env: dict[str, str] | None = None,
    ) -> None:
        self.incoming = incoming
        self.send = send
        self.env = dict(os.environ if env is None else env)
        self.session = self.env.get("CLAUDE_CODE_SESSION_ID") or str(uuid.uuid4())
        # Messages that arrived while a call waited, served after it; a
        # None in it is the end of input.
        self.backlog: deque[dict[str, Any] | None] = deque()
        self.can_elicit = False
        self.next_id = 0
        self.serving: Any = None  # the id of the tools/call in progress

    # --- message plumbing ----------------------------------------------

    def _next(self, timeout: float | None = None) -> dict[str, Any] | None:
        return self.incoming.get(timeout=timeout)

    def _side_message(self, msg: dict[str, Any] | None) -> None:
        """A message that arrived while a call waits: a cancellation of
        that call, or the end of input, aborts it; anything else is
        served afterwards."""
        if msg is None:
            self.backlog.append(None)
            raise Cancelled
        if msg.get("method") == "notifications/cancelled":
            if (msg.get("params") or {}).get("requestId") == self.serving:
                raise Cancelled
            return
        self.backlog.append(msg)

    def _drain_side_messages(self) -> None:
        while True:
            try:
                msg = self.incoming.get_nowait()
            except queue.Empty:
                return
            self._side_message(msg)

    def request_client(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        """Send a request to the client and wait for its response."""
        self.next_id += 1
        request_id = f"ccs-{self.next_id}"
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        while True:
            msg = self._next()
            if msg is not None and msg.get("id") == request_id and "method" not in msg:
                if "error" in msg:
                    raise ToolError(f"the client refused {method}: {msg['error'].get('message')}")
                return msg.get("result") or {}
            self._side_message(msg)

    def run(self) -> int:
        while True:
            msg = self.backlog.popleft() if self.backlog else self._next()
            if msg is None:
                return 0
            self.handle(msg)

    def handle(self, msg: dict[str, Any]) -> None:
        method = msg.get("method")
        if method is None or "id" not in msg:
            return  # a notification, or a response nobody waits for
        try:
            if method == "initialize":
                result = self.initialize(msg.get("params") or {})
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                result = {"tools": TOOLS}
            elif method == "tools/call":
                self.serving = msg["id"]
                try:
                    result = self.call(msg.get("params") or {})
                except Cancelled:
                    return  # a cancelled request gets no response
                finally:
                    self.serving = None
            else:
                self.send(
                    {"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": f"no method {method}"}}
                )
                return
        except Exception as e:  # noqa: BLE001 (report to the client, keep serving)
            self.send({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32603, "message": str(e)}})
            return
        self.send({"jsonrpc": "2.0", "id": msg["id"], "result": result})

    def initialize(self, params: dict[str, Any]) -> dict[str, Any]:
        elicitation = (params.get("capabilities") or {}).get("elicitation")
        # An empty elicitation object is the older spelling of form support.
        self.can_elicit = isinstance(elicitation, dict) and ("form" in elicitation or not elicitation)
        return {
            "protocolVersion": params.get("protocolVersion") or PROTOCOL_VERSION,
            "capabilities": {"tools": {}},
            "serverInfo": SERVER_INFO,
        }

    # --- tools ------------------------------------------------------------

    def call(self, params: dict[str, Any]) -> dict[str, Any]:
        name = params.get("name")
        args = params.get("arguments") or {}
        meta = params.get("_meta") or {}
        tools: dict[str, Callable[[dict[str, Any], dict[str, Any]], Any]] = {
            "list-modules": self.list_modules,
            "enabled-modules": self.enabled_modules,
            "describe-module": self.describe_module,
            "declined-modules": self.declined_modules,
            "request-module": self.request_module,
        }
        if name not in tools:
            return {"content": [{"type": "text", "text": f"no tool named {name}"}], "isError": True}
        try:
            value = tools[name](args, meta)
        except ToolError as e:
            return {"content": [{"type": "text", "text": str(e)}], "isError": True}
        return {"content": [{"type": "text", "text": _text(value)}]}

    def _state(self) -> tuple[dict[str, Any], dict[str, Any]]:
        registry = load_registry()
        root = _checkout(self.env)
        return registry, checkout_state(root, registry)

    def list_modules(self, args: dict[str, Any], meta: dict[str, Any]) -> Any:
        registry, state = self._state()
        return {
            "checkout": state["checkout"],
            "enrollment": state["enrollment"],
            "modules": overview(registry, state),
        }

    def enabled_modules(self, args: dict[str, Any], meta: dict[str, Any]) -> Any:
        _registry, state = self._state()
        out = {k: v for k, v in state.items() if k != "declined"}
        if state["enrollment"] != "not enrolled":
            out["status"] = _status_line(Path(state["checkout"]))[0]
        return out

    def describe_module(self, args: dict[str, Any], meta: dict[str, Any]) -> Any:
        registry, state = self._state()
        name = str(args.get("module") or "")
        info = describe(registry, name, state)
        refusal = state["declined"].get(name)
        if refusal:
            info["declined"] = refusal
        return info

    def declined_modules(self, args: dict[str, Any], meta: dict[str, Any]) -> Any:
        registry, state = self._state()
        declined = state["declined"]
        name = args.get("module")
        if name:
            check_known(registry, [name])
            declined = {name: declined[name]} if name in declined else {}
            if not declined:
                return {"checkout": state["checkout"], "module": name, "declined": False}
        return {"checkout": state["checkout"], "declined": declined}

    def request_module(self, args: dict[str, Any], meta: dict[str, Any]) -> Any:
        name = str(args.get("module") or "")
        reason = str(args.get("reason") or "").strip()
        if not reason:
            raise ToolError("give a reason: the user reads it in the prompt")
        registry, state = self._state()
        root = Path(state["checkout"])
        require_enrolled(state)
        check_known(registry, [name])
        if expire_due(root):
            state = checkout_state(root, registry)
        if name in state["enabled"]:
            return f"{name} is already {module_status(name, state)} in {root}."
        refusal = state["declined"].get(name)
        if refusal:
            return (
                f"The user declined {name} for {root}; not asking again. "
                + refusal_text(name, refusal)
                + " Tell the user what the task needs it for instead."
            )

        info = describe(registry, name, state)
        title = f"Enable sandbox module '{name}' in {root.name}?"
        detail = "\n".join(
            [
                f"An agent asks to enable this module in {root}.",
                f"The agent's reason: {reason}",
                "",
                describe_text(info),
            ]
        )
        decision, text, note = self.ask_user(root, name, title, detail, meta)

        if decision in ENABLE_DURATIONS:
            until = enable_modules(root, [name], ENABLE_DURATIONS[decision])
            enabled = checkout_state(root, registry)["enabled"]
            span = f" until {until.astimezone().isoformat(timespec='minutes')}" if until else ""
            return (
                f"The user enabled {name} in {root}{span}. Enabled modules: {', '.join(sorted(enabled))}. "
                "This session's sandboxed commands still run under the old rules. The new rules "
                "apply only after the user stops this session with /stop and starts it again. "
                "Tell the user that, and do not retry the commands that need the module until "
                "the session has restarted."
            )
        if decision == "decline":
            decline_modules(root, [name], text or None)
            because = f" Their reason: {text}" if text else ""
            return (
                f"The user declined {name} for {root}.{because} The refusal is recorded; "
                "request-module will not ask for it again."
            )
        return note

    # --- prompting --------------------------------------------------------

    def ask_user(
        self, root: Path, name: str, title: str, detail: str, meta: dict[str, Any]
    ) -> tuple[str, str | None, str]:
        """Prompt the user. Returns the decision (``enable``,
        ``decline``, or ``none`` when nothing was decided), free text the
        user gave with it, and the note the agent gets for ``none``."""
        key = hashlib.sha256(f"{root}\0{name}".encode()).hexdigest()[:32]
        payload = {
            "session_id": self.session,
            "tool_name": "request-module",
            "tool_input": {"module": name},
            "cwd": str(root),
        }
        if meta.get("claudecode/toolUseId"):
            payload["tool_use_id"] = meta["claudecode/toolUseId"]
        argv = [
            "ask",
            "--session",
            self.session,
            "--title",
            title,
            "--detail",
            detail,
            "--option",
            "day=Enable for a day",
            "--option",
            "week=Enable for a week",
            "--option",
            "enable=Enable permanently",
            "--option",
            "decline=Decline",
            "--option-text",
            "decline=Reason (optional)",
            "--option",
            "later=Not now",
            "--key",
            key,
            "--deadline",
            str(PROMPT_DEADLINE_SECONDS),
            "--payload-stdin",
        ]
        result = self.consent(argv + (["--fallback", "elicit"] if self.can_elicit else []), payload)
        if result.get("status") == "fallback":
            decision = self.elicit(title, detail)
            if decision is not None:
                return decision
            result = self.consent(argv, payload)
        return self._consent_outcome(result, name)

    def _consent_outcome(self, result: dict[str, Any], name: str) -> tuple[str, str | None, str]:
        status = result.get("status")
        if status == "answered":
            value = result.get("value")
            if value in ENABLE_DURATIONS or value == "decline":
                return value, result.get("text"), ""
            return "none", None, f"The user chose not now for {name}; nothing is recorded, so you may ask later."
        if status == "timeout":
            minutes = PROMPT_DEADLINE_SECONDS // 60
            return "none", None, f"The user did not answer within {minutes} minutes; nothing is recorded."
        if status == "pending":
            note = (
                f"No prompt could be shown to the user right now. The question is stored: the user "
                f"answers it with `claude-consent answer {result.get('id')}` in a terminal, and "
                f"calling request-module again for {name} then applies that answer. Tell the user."
            )
            return "none", None, note
        raise ToolError(f"claude-consent returned an unexpected result: {result}")

    def consent(self, argv: list[str], payload: dict[str, Any]) -> dict[str, Any]:
        """Run ``claude-consent`` with the payload on stdin, watching for
        a cancellation of the call while it waits."""
        command = self.env.get(CONSENT_ENV) or "claude-consent"
        try:
            proc = subprocess.Popen(
                [command, *argv],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=self.env,
            )
        except OSError as e:
            raise ToolError(f"cannot run {command}: {e}; is claude-consent installed?") from e
        assert proc.stdin is not None
        proc.stdin.write(json.dumps(payload))
        proc.stdin.close()
        try:
            while proc.poll() is None:
                self._drain_side_messages()
                time.sleep(POLL_SECONDS)
        except Cancelled:
            # A killed blocking ask leaves a record whose pid is gone;
            # every spool reader prunes it.
            proc.kill()
            proc.communicate()
            raise
        out, err = proc.communicate()
        if proc.returncode != 0:
            raise ToolError(f"claude-consent failed: {err.strip() or proc.returncode}")
        try:
            return json.loads(out.strip().splitlines()[-1])
        except (ValueError, IndexError) as e:
            raise ToolError(f"claude-consent printed no result: {out!r}") from e

    def elicit(self, title: str, detail: str) -> tuple[str, str | None, str] | None:
        """Ask through an MCP elicitation dialog. None when the client
        cannot show one or it was cancelled, so the caller stores the
        question instead."""
        if not self.can_elicit:
            return None
        result = self.request_client(
            "elicitation/create",
            {
                "mode": "form",
                "message": f"{title}\n\n{detail}",
                "requestedSchema": {
                    "type": "object",
                    "properties": {
                        "decision": {
                            "type": "string",
                            "title": "Decision",
                            "enum": [*ELICIT_ENABLE, "decline", "not now"],
                        },
                        "reason": {
                            "type": "string",
                            "title": "Reason, if you decline (optional)",
                        },
                    },
                    "required": ["decision"],
                },
            },
        )
        action = result.get("action")
        if action == "decline":
            return "decline", None, ""
        if action != "accept":
            return None
        content = result.get("content") or {}
        decision = content.get("decision")
        reason = str(content.get("reason") or "").strip() or None
        if decision in ELICIT_ENABLE:
            return ELICIT_ENABLE[decision], None, ""
        if decision == "decline":
            return "decline", reason, ""
        return "none", None, "The user chose not now; nothing is recorded, so you may ask later."


def _reader(stream: Any, incoming: queue.Queue[dict[str, Any] | None]) -> None:
    for line in stream:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if isinstance(msg, dict):
            incoming.put(msg)
    incoming.put(None)


def serve() -> int:
    incoming: queue.Queue[dict[str, Any] | None] = queue.Queue()
    threading.Thread(target=_reader, args=(sys.stdin, incoming), daemon=True).start()
    lock = threading.Lock()

    def send(msg: dict[str, Any]) -> None:
        with lock:
            sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
            sys.stdout.flush()

    return Server(incoming, send).run()
