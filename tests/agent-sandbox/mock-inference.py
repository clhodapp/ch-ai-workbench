# SPDX-License-Identifier: MIT
"""A stand-in for a model API, for agents running inside agent-sandbox.

It answers Codex's Responses API (POST .../responses) and the
OpenAI-compatible chat completions API (POST .../chat/completions), both
streamed as server-sent events. A request that offers a tool whose name
contains TOOL (default `mark`) and carries no tool result yet gets a
call to that tool. OpenCode 2 offers the tools of MCP servers only
inside its Code Mode tool `execute`; a request that offers `execute`
and no TOOL gets an `execute` call whose code calls TOOL of the MCP
server SERVER (default `emacs`). A request whose input names
`PATCH-OUTSIDE:PATH`, offers Codex's `apply_patch` and carries no tool
result yet gets an `apply_patch` call adding the file PATH; one whose
messages name `WRITE-OUTSIDE:PATH` gets an OpenCode `write` call to
PATH the same way. Any other
request gets a short text answer. Every request body is appended to
the log file, one JSON object per line.

usage: mock-inference.py HOST PORT LOG [TOOL [SERVER]]
"""

import itertools
import json
import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST, PORT, LOG = sys.argv[1], int(sys.argv[2]), sys.argv[3]
TOOL = sys.argv[4] if len(sys.argv) > 4 else "mark"
SERVER = sys.argv[5] if len(sys.argv) > 5 else "emacs"
# Tool call IDs, unique across the run.
CALLS = itertools.count(1)


def tool_names(body):
    """The offered tools as (namespace, name) pairs. Codex offers the tools
    of an MCP server inside a namespace of the Responses API."""
    names = []
    for tool in body.get("tools") or []:
        if tool.get("type") == "namespace":
            names += [(tool["name"], inner["name"]) for inner in tool.get("tools") or []]
            continue
        name = tool.get("name") or (tool.get("function") or {}).get("name")
        if name:
            names.append((None, name))
    return names


def tool_results(body):
    """The text of every tool result the request carries."""
    results = []
    for item in body.get("input") or []:
        if isinstance(item, dict) and item.get("type", "").endswith("_call_output"):
            results.append(json.dumps(item.get("output")))
    for message in body.get("messages") or []:
        if message.get("role") == "tool":
            results.append(json.dumps(message.get("content")))
    return results


def outside_patch(body):
    """The `apply_patch` call as (None, "apply_patch", patch, "custom") when
    the input asks for one, or None."""
    names = [name for _, name in tool_names(body)]
    found = re.search(r"PATCH-OUTSIDE:([A-Za-z0-9_./-]+)", json.dumps(body.get("input") or []))
    if found and "apply_patch" in names and not tool_results(body):
        patch = f"*** Begin Patch\n*** Add File: {found.group(1)}\n+written by the mock\n*** End Patch\n"
        return (None, "apply_patch", patch, "custom")
    return None


def outside_write(body):
    """The `write` call as (None, "write", arguments) when the messages
    ask for one with `WRITE-OUTSIDE:PATH`, or None. The file argument is
    the one the offered tool names: `filePath` in OpenCode 1, `path` in
    OpenCode 2."""
    found = re.search(r"WRITE-OUTSIDE:([A-Za-z0-9_./-]+)", json.dumps(body.get("messages") or []))
    if not found or tool_results(body):
        return None
    for tool in body.get("tools") or []:
        function = tool.get("function") or {}
        if function.get("name") == "write":
            properties = (function.get("parameters") or {}).get("properties") or {}
            key = "filePath" if "filePath" in properties else "path"
            return (None, "write", json.dumps({key: found.group(1), "content": "written by the mock\n"}))
    return None


def mark_tool(body):
    """The tool to call as (namespace, name, arguments), or None.

    OpenCode 2 connects MCP servers while the session already runs, so
    a server's tools may be missing from the first step; an `execute`
    call is therefore repeated, up to eight times and half a second
    apart (a real model takes longer than that per step), until a
    result shows that the tool ran."""
    results = tool_results(body)
    if any("marked" in result for result in results):
        return None
    names = tool_names(body)
    found = next((pair for pair in names if TOOL in pair[1]), None)
    if found and not results:
        return (*found, "{}")
    if any(name == "execute" for _, name in names) and len(results) < 8:
        if results:
            time.sleep(0.5)
        code = os.environ.get("MOCK_CODE") or f'return await tools[{json.dumps(SERVER)}][{json.dumps(TOOL)}]({{}})'
        return (None, "execute", json.dumps({"code": code}))
    return None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def events(self, chunks):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        for chunk in chunks:
            self.wfile.write(chunk.encode())
            self.wfile.flush()
        self.close_connection = True

    def do_GET(self):
        # Model listings: one model, the one the agents are told to use.
        body = json.dumps({"object": "list", "data": [{"id": "mock-model", "object": "model"}]})
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body.encode())

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
        with open(LOG, "a") as log:
            log.write(json.dumps({"path": self.path, "body": body}) + "\n")
        tool = outside_patch(body) or outside_write(body) or mark_tool(body)
        if self.path.endswith("/responses"):
            self.events(responses(tool))
        else:
            self.events(chat(tool, body))


def sse(event, data):
    return f"event: {event}\ndata: {json.dumps(data)}\n\n"


def responses(tool):
    if tool and tool[3:] == ("custom",):
        item = {
            "type": "custom_tool_call",
            "id": "ctc_1",
            "call_id": f"call_{next(CALLS)}",
            "name": tool[1],
            "input": tool[2],
            "status": "completed",
        }
    elif tool:
        namespace, name, arguments = tool
        item = {
            "type": "function_call",
            "id": "fc_1",
            "call_id": f"call_{next(CALLS)}",
            "name": name,
            "arguments": arguments,
            "status": "completed",
        }
        if namespace:
            item["namespace"] = namespace
    else:
        item = {
            "type": "message",
            "id": "msg_1",
            "role": "assistant",
            "status": "completed",
            "content": [{"type": "output_text", "text": "done", "annotations": []}],
        }
    usage = {
        "input_tokens": 1,
        "input_tokens_details": {"cached_tokens": 0},
        "output_tokens": 1,
        "output_tokens_details": {"reasoning_tokens": 0},
        "total_tokens": 2,
    }
    return [
        sse("response.created", {"type": "response.created", "response": {"id": "resp_1"}}),
        sse("response.output_item.done", {"type": "response.output_item.done", "output_index": 0, "item": item}),
        sse(
            "response.completed",
            {"type": "response.completed", "response": {"id": "resp_1", "usage": usage}},
        ),
    ]


def chunk(delta, finish=None):
    return "data: " + json.dumps(
        {
            "id": "chatcmpl-1",
            "object": "chat.completion.chunk",
            "created": 0,
            "model": "mock-model",
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
        }
    ) + "\n\n"


DIAGRAM = "Here it is:\n\n```mermaid\ngraph TD\n  A[Emacs] --> B[Agent]\n```\n"


def text_answer(request):
    """The text answer: a mermaid diagram when the messages ask to draw
    one, `done` otherwise."""
    return DIAGRAM if "Draw a diagram" in json.dumps(request.get("messages") or []) else "done"


def chat(tool, request):
    if tool:
        call = {"index": 0, "id": f"call_{next(CALLS)}", "type": "function", "function": {"name": tool[1], "arguments": tool[2]}}
        body = [chunk({"role": "assistant", "tool_calls": [call]}), chunk({}, "tool_calls")]
    else:
        body = [chunk({"role": "assistant", "content": text_answer(request)}), chunk({}, "stop")]
    usage = "data: " + json.dumps(
        {
            "id": "chatcmpl-1",
            "object": "chat.completion.chunk",
            "created": 0,
            "model": "mock-model",
            "choices": [],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        }
    ) + "\n\n"
    return [*body, usage, "data: [DONE]\n\n"]


ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
