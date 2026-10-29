# SPDX-License-Identifier: MIT
"""A stand-in for a model API, for agents running inside agent-sandbox.

It answers Codex's Responses API (POST .../responses) and the
OpenAI-compatible chat completions API (POST .../chat/completions), both
streamed as server-sent events. A request that offers a tool whose name
contains `mark` and carries no tool result yet gets a call to that tool;
any other request gets a short text answer. Every request body is
appended to the log file, one JSON object per line.

usage: mock-inference.py HOST PORT LOG
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST, PORT, LOG = sys.argv[1], int(sys.argv[2]), sys.argv[3]


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


def has_tool_result(body):
    for item in body.get("input") or []:
        if isinstance(item, dict) and item.get("type") == "function_call_output":
            return True
    return any(message.get("role") == "tool" for message in body.get("messages") or [])


def mark_tool(body):
    if has_tool_result(body):
        return None
    return next((pair for pair in tool_names(body) if "mark" in pair[1]), None)


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
        tool = mark_tool(body)
        if self.path.endswith("/responses"):
            self.events(responses(tool))
        else:
            self.events(chat(tool))


def sse(event, data):
    return f"event: {event}\ndata: {json.dumps(data)}\n\n"


def responses(tool):
    if tool:
        namespace, name = tool
        item = {
            "type": "function_call",
            "id": "fc_1",
            "call_id": "call_1",
            "name": name,
            "arguments": "{}",
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


def chat(tool):
    if tool:
        call = {"index": 0, "id": "call_1", "type": "function", "function": {"name": tool[1], "arguments": "{}"}}
        body = [chunk({"role": "assistant", "tool_calls": [call]}), chunk({}, "tool_calls")]
    else:
        body = [chunk({"role": "assistant", "content": "done"}), chunk({}, "stop")]
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
