// SPDX-License-Identifier: MIT
//! The MCP server agents use: JSON-RPC 2.0 over stdio, one process per
//! session, each request turned into a request to the daemon.
//!
//! The server knows which participant it serves from `AGENT_BUS_PARTICIPANT`
//! (an id or a label). The protocol is implemented here directly rather than
//! through an SDK: it is small, and the bus will need notifications that
//! SDKs do not model, such as Claude Code channel events and the events
//! OpenCode's `watch_mcp_event` subscribes to.

use std::io::{BufRead, Write};
use std::path::Path;

use anyhow::Result;
use serde_json::{Value, json};

use crate::client;

const PROTOCOL: &str = "2025-06-18";

fn tools() -> Value {
    json!([
        {
            "name": "bus_whoami",
            "description": "Your participant id and label, your supervisor and children, and every peer edge you are part of with its scope.",
            "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false}
        },
        {
            "name": "bus_status",
            "description": "Set your status: a short text saying what you are doing, which your supervisor and the sessions informed of you can read.",
            "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"], "additionalProperties": false}
        },
        {
            "name": "bus_read_status",
            "description": "Read the state and status of a participant you have an edge to, by label or id.",
            "inputSchema": {"type": "object", "properties": {"participant": {"type": "string"}}, "required": ["participant"], "additionalProperties": false}
        },
        {
            "name": "bus_inbox",
            "description": "List your unread messages, oldest first, and mark them read unless mark_read is false.",
            "inputSchema": {"type": "object", "properties": {"mark_read": {"type": "boolean"}}, "additionalProperties": false}
        },
        {
            "name": "bus_send",
            "description": "Send a message along an edge. Kinds: directive (supervisor to child), report (child to supervisor), question, answer, notice. A notice with no recipient goes to everyone informed of you. Set reply_to when answering a message.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "to": {"type": "string", "description": "Recipient label or id; omit for a notice to everyone informed of you."},
                    "kind": {"type": "string", "enum": ["directive", "report", "question", "answer", "notice"]},
                    "body": {"type": "string"},
                    "reply_to": {"type": "string", "description": "Id of the message this answers."}
                },
                "required": ["kind", "body"],
                "additionalProperties": false
            }
        }
    ])
}

fn call(socket: &Path, participant: Option<&str>, name: &str, args: &Value) -> Result<Value> {
    let Some(me) = participant else {
        anyhow::bail!(
            "this session is not registered with the agent bus: AGENT_BUS_PARTICIPANT is not set for the MCP server"
        );
    };
    let s = |k: &str| args.get(k).and_then(Value::as_str);
    let req = match name {
        "bus_whoami" => json!({"op": "whoami", "caller": me}),
        "bus_status" => json!({"op": "set_status", "caller": me, "text": s("text")}),
        "bus_read_status" => json!({"op": "read_status", "caller": me, "target": s("participant")}),
        "bus_inbox" => {
            json!({"op": "inbox", "caller": me, "mark_read": args.get("mark_read").and_then(Value::as_bool).unwrap_or(true)})
        }
        "bus_send" => {
            json!({"op": "send", "caller": me, "to": s("to"), "kind": s("kind"), "body": s("body"), "reply_to": s("reply_to")})
        }
        other => anyhow::bail!("unknown tool {other:?}"),
    };
    client::request(socket, &req)
}

fn result_text(value: &Value, is_error: bool) -> Value {
    let text = match value {
        Value::String(s) => s.clone(),
        v => serde_json::to_string_pretty(v).unwrap_or_default(),
    };
    json!({"content": [{"type": "text", "text": text}], "isError": is_error})
}

/// Answers one JSON-RPC message, or returns `None` for a notification.
fn answer(socket: &Path, participant: Option<&str>, msg: &Value) -> Option<Value> {
    let id = msg.get("id")?.clone();
    let method = msg.get("method").and_then(Value::as_str).unwrap_or("");
    let result = match method {
        "initialize" => {
            let version = msg
                .pointer("/params/protocolVersion")
                .and_then(Value::as_str)
                .unwrap_or(PROTOCOL);
            json!({
                "protocolVersion": version,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "agent-bus", "version": env!("CARGO_PKG_VERSION")}
            })
        }
        "ping" => json!({}),
        "tools/list" => json!({"tools": tools()}),
        "tools/call" => {
            let name = msg
                .pointer("/params/name")
                .and_then(Value::as_str)
                .unwrap_or("");
            let args = msg
                .pointer("/params/arguments")
                .cloned()
                .unwrap_or(json!({}));
            match call(socket, participant, name, &args) {
                Ok(v) => result_text(&v, false),
                Err(e) => result_text(&Value::String(format!("{e:#}")), true),
            }
        }
        other => {
            return Some(json!({
                "jsonrpc": "2.0", "id": id,
                "error": {"code": -32601, "message": format!("method not found: {other}")}
            }));
        }
    };
    Some(json!({"jsonrpc": "2.0", "id": id, "result": result}))
}

pub fn run(socket: &Path) -> Result<()> {
    let participant = std::env::var("AGENT_BUS_PARTICIPANT")
        .ok()
        .filter(|s| !s.is_empty());
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();
    for line in stdin.lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let reply = match serde_json::from_str::<Value>(&line) {
            Ok(msg) => answer(socket, participant.as_deref(), &msg),
            Err(e) => Some(json!({
                "jsonrpc": "2.0", "id": null,
                "error": {"code": -32700, "message": format!("parse error: {e}")}
            })),
        };
        if let Some(reply) = reply {
            writeln!(stdout, "{reply}")?;
            stdout.flush()?;
        }
    }
    Ok(())
}
