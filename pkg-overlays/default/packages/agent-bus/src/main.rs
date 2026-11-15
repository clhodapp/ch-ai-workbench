// SPDX-License-Identifier: MIT
//! `agent-bus`: the coordination bus for agent sessions.
//!
//! One binary with a verb per role: `daemon` runs the per-user daemon, `mcp`
//! is the MCP server a harness starts for each session, and the remaining
//! verbs are the operator's CLI. The design is in ch-nix-workspace's
//! docs/development/agent-bus.md.

mod client;
mod daemon;
mod mcp;
mod paths;
mod store;

use std::path::PathBuf;

use anyhow::Result;
use clap::{Parser, Subcommand};
use serde_json::{Value, json};

#[derive(Parser)]
#[command(
    name = "agent-bus",
    version,
    about = "Coordination bus for agent sessions"
)]
struct Cli {
    /// The daemon's socket (default: $AGENT_BUS_SOCKET, then $XDG_RUNTIME_DIR/agent-bus/socket).
    #[arg(long, global = true)]
    socket: Option<PathBuf>,
    #[command(subcommand)]
    verb: Verb,
}

#[derive(Subcommand)]
enum Verb {
    /// Run the daemon.
    Daemon {
        /// The store (default: $AGENT_BUS_DB, then $XDG_STATE_HOME/agent-bus/bus.sqlite).
        #[arg(long)]
        db: Option<PathBuf>,
    },
    /// Serve MCP over stdio for the session named by AGENT_BUS_PARTICIPANT.
    Mcp,
    /// Register a session, or find the participant already bound to it, and print its id.
    Register {
        #[arg(long)]
        harness: String,
        #[arg(long)]
        session: String,
        #[arg(long)]
        label: Option<String>,
        #[arg(long)]
        cwd: Option<String>,
    },
    /// List participants.
    Ls,
    /// List edges.
    Edges,
    /// Create an edge.
    Link {
        #[command(subcommand)]
        kind: LinkKind,
    },
    /// Remove an edge by id.
    Unlink { edge: String },
    /// Send a message as the user.
    Send {
        to: String,
        body: String,
        #[arg(long, default_value = "directive")]
        kind: String,
        #[arg(long)]
        reply_to: Option<String>,
    },
    /// Print events after a sequence number; with --follow, keep printing new ones.
    Log {
        #[arg(long, default_value_t = 0)]
        after: i64,
        #[arg(long)]
        follow: bool,
    },
}

#[derive(Subcommand)]
enum LinkKind {
    /// PARENT supervises CHILD.
    Supervise { parent: String, child: String },
    /// FROM informs TO within SCOPE; --both adds the reverse edge with the same scope.
    Inform {
        from: String,
        to: String,
        #[arg(long)]
        scope: Option<String>,
        #[arg(long)]
        both: bool,
        /// Let TO reply to what FROM sends over a one-way edge.
        #[arg(long)]
        replies: bool,
    },
    /// INTERFACE fronts PEER for the user.
    Interface { interface: String, peer: String },
}

fn print_table(rows: &[Vec<String>]) {
    let cols = rows.iter().map(Vec::len).max().unwrap_or(0);
    let widths: Vec<usize> = (0..cols)
        .map(|c| {
            rows.iter()
                .map(|r| r.get(c).map_or(0, |s| s.chars().count()))
                .max()
                .unwrap_or(0)
        })
        .collect();
    for r in rows {
        let line: Vec<String> = r
            .iter()
            .enumerate()
            .map(|(i, s)| {
                if i + 1 == r.len() {
                    s.clone()
                } else {
                    format!("{s:<w$}", w = widths[i])
                }
            })
            .collect();
        println!("{}", line.join("  ").trim_end());
    }
}

fn s(v: &Value, k: &str) -> String {
    v.get(k).and_then(Value::as_str).unwrap_or("-").to_string()
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    if let Verb::Daemon { db } = cli.verb {
        return daemon::run(&paths::socket(cli.socket)?, &paths::db(db)?);
    }
    let socket = paths::socket(cli.socket)?;
    let req = |v: Value| client::request(&socket, &v);
    match cli.verb {
        Verb::Daemon { .. } => unreachable!(),
        Verb::Mcp => mcp::run(&socket)?,
        Verb::Register {
            harness,
            session,
            label,
            cwd,
        } => {
            let p = req(
                json!({"op": "register", "harness": harness, "harness_session": session, "label": label, "cwd": cwd}),
            )?;
            println!("{}", s(&p, "id"));
        }
        Verb::Ls => {
            let ps = req(json!({"op": "participants"}))?;
            let edges = req(json!({"op": "edges"}))?;
            let mut rows = vec![vec![
                "LABEL".into(),
                "HARNESS".into(),
                "STATE".into(),
                "SUPERVISOR".into(),
                "STATUS".into(),
            ]];
            let label_of = |id: &str| {
                ps.as_array()
                    .and_then(|a| {
                        a.iter()
                            .find(|p| p.get("id").and_then(Value::as_str) == Some(id))
                    })
                    .map(|p| s(p, "label"))
                    .unwrap_or_else(|| id.to_string())
            };
            for p in ps.as_array().into_iter().flatten() {
                let id = s(p, "id");
                let sup = edges
                    .as_array()
                    .into_iter()
                    .flatten()
                    .find(|e| s(e, "kind") == "supervises" && s(e, "to") == id)
                    .map(|e| label_of(&s(e, "from")))
                    .unwrap_or_else(|| "-".into());
                rows.push(vec![
                    s(p, "label"),
                    s(p, "harness"),
                    s(p, "state"),
                    sup,
                    s(p, "status"),
                ]);
            }
            print_table(&rows);
        }
        Verb::Edges => {
            let ps = req(json!({"op": "participants"}))?;
            let label_of = |id: &str| {
                ps.as_array()
                    .and_then(|a| {
                        a.iter()
                            .find(|p| p.get("id").and_then(Value::as_str) == Some(id))
                    })
                    .map(|p| s(p, "label"))
                    .unwrap_or_else(|| id.to_string())
            };
            let edges = req(json!({"op": "edges"}))?;
            let mut rows = vec![vec![
                "ID".into(),
                "KIND".into(),
                "FROM".into(),
                "TO".into(),
                "REPLIES".into(),
                "SCOPE".into(),
            ]];
            for e in edges.as_array().into_iter().flatten() {
                let replies = if e.get("replies").and_then(Value::as_bool) == Some(true) {
                    "yes"
                } else {
                    "-"
                };
                rows.push(vec![
                    s(e, "id"),
                    s(e, "kind"),
                    label_of(&s(e, "from")),
                    label_of(&s(e, "to")),
                    replies.into(),
                    s(e, "scope"),
                ]);
            }
            print_table(&rows);
        }
        Verb::Link { kind } => {
            let mut made = vec![];
            match kind {
                LinkKind::Supervise { parent, child } => {
                    made.push(req(json!({"op": "link", "caller": store::USER, "kind": "supervises", "from": parent, "to": child}))?);
                }
                LinkKind::Inform {
                    from,
                    to,
                    scope,
                    both,
                    replies,
                } => {
                    made.push(req(json!({"op": "link", "caller": store::USER, "kind": "informs", "from": from, "to": to, "scope": scope, "replies": replies}))?);
                    if both {
                        made.push(req(json!({"op": "link", "caller": store::USER, "kind": "informs", "from": to, "to": from, "scope": scope}))?);
                    }
                }
                LinkKind::Interface { interface, peer } => {
                    made.push(req(json!({"op": "link", "caller": store::USER, "kind": "interface", "from": interface, "to": peer}))?);
                }
            }
            for e in made {
                println!("{}", s(&e, "id"));
            }
        }
        Verb::Unlink { edge } => {
            req(json!({"op": "unlink", "caller": store::USER, "edge": edge}))?;
        }
        Verb::Send {
            to,
            body,
            kind,
            reply_to,
        } => {
            let r = req(
                json!({"op": "send", "caller": store::USER, "to": to, "kind": kind, "body": body, "reply_to": reply_to}),
            )?;
            for m in r
                .get("sent")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                println!("{}", s(m, "id"));
            }
        }
        Verb::Log { after, follow } => {
            if follow {
                client::watch(&socket, after, |ev| {
                    println!("{ev}");
                    Ok(())
                })?;
            } else {
                for ev in req(json!({"op": "log", "after": after}))?
                    .as_array()
                    .into_iter()
                    .flatten()
                {
                    println!("{ev}");
                }
            }
        }
    }
    Ok(())
}
