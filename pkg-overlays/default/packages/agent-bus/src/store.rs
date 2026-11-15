// SPDX-License-Identifier: MIT
//! The bus's state: an append-only event log in SQLite, plus tables derived
//! from it in the same transaction.
//!
//! Every change appends one row to `events`, carrying the machine it happened
//! on and a sequence number, and updates `participants`, `edges` or
//! `messages`. The log is what the Emacs views replay and what replication
//! between machines will exchange.
//!
//! Every operation names its caller in `caller`: a participant's id or label,
//! or `user` for the person at Emacs or the CLI. The edge rules of the design
//! note (docs/development/agent-bus.md in ch-nix-workspace) are enforced in
//! `send` and `read_status`.

use anyhow::{Result, anyhow, bail};
use rusqlite::{Connection, OptionalExtension, params};
use serde::Serialize;
use serde_json::{Value, json};

pub const USER: &str = "user";

const SCHEMA: &str = r#"
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS events (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  machine TEXT NOT NULL,
  ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  kind TEXT NOT NULL,
  body TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS participants (
  id TEXT PRIMARY KEY,
  machine TEXT NOT NULL,
  harness TEXT NOT NULL,
  harness_session TEXT NOT NULL,
  label TEXT NOT NULL UNIQUE,
  cwd TEXT,
  state TEXT NOT NULL DEFAULT 'idle',
  status TEXT,
  status_ts TEXT,
  created TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  UNIQUE (harness, harness_session)
);
CREATE TABLE IF NOT EXISTS edges (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('supervises', 'informs', 'interface')),
  from_id TEXT NOT NULL REFERENCES participants (id),
  to_id TEXT NOT NULL REFERENCES participants (id),
  scope TEXT,
  replies INTEGER NOT NULL DEFAULT 0,
  created TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE TABLE IF NOT EXISTS messages (
  id TEXT PRIMARY KEY,
  from_id TEXT NOT NULL,
  to_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  body TEXT NOT NULL,
  reply_to TEXT,
  edge_id TEXT,
  state TEXT NOT NULL DEFAULT 'queued',
  created TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  read_ts TEXT
);
"#;

/// The message kinds of the design note.
pub const KINDS: &[&str] = &[
    "directive",
    "report",
    "question",
    "answer",
    "notice",
    "relay",
];

#[derive(Debug, Clone, Serialize)]
pub struct Participant {
    pub id: String,
    pub machine: String,
    pub harness: String,
    pub harness_session: String,
    pub label: String,
    pub cwd: Option<String>,
    pub state: String,
    pub status: Option<String>,
    pub status_ts: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Edge {
    pub id: String,
    pub kind: String,
    pub from: String,
    pub to: String,
    pub scope: Option<String>,
    pub replies: bool,
}

pub struct Store {
    conn: Connection,
    machine: String,
}

fn new_id() -> String {
    ulid::Ulid::generate().to_string()
}

impl Store {
    pub fn open(path: &std::path::Path, machine: String) -> Result<Store> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let conn = Connection::open(path)?;
        conn.execute_batch(SCHEMA)?;
        Ok(Store { conn, machine })
    }

    fn event(&self, kind: &str, body: &Value) -> Result<i64> {
        self.conn.execute(
            "INSERT INTO events (machine, kind, body) VALUES (?1, ?2, ?3)",
            params![self.machine, kind, body.to_string()],
        )?;
        Ok(self.conn.last_insert_rowid())
    }

    pub fn last_seq(&self) -> Result<i64> {
        Ok(self
            .conn
            .query_row("SELECT COALESCE(MAX(seq), 0) FROM events", [], |r| r.get(0))?)
    }

    pub fn events_after(&self, after: i64) -> Result<Vec<Value>> {
        let mut stmt = self.conn.prepare(
            "SELECT seq, machine, ts, kind, body FROM events WHERE seq > ?1 ORDER BY seq",
        )?;
        let rows = stmt.query_map(params![after], |r| {
            let body: String = r.get(4)?;
            Ok(json!({
                "seq": r.get::<_, i64>(0)?,
                "machine": r.get::<_, String>(1)?,
                "ts": r.get::<_, String>(2)?,
                "kind": r.get::<_, String>(3)?,
                "body": serde_json::from_str::<Value>(&body).unwrap_or(Value::Null),
            }))
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    // ----- participants -------------------------------------------------

    fn participant_row(r: &rusqlite::Row) -> rusqlite::Result<Participant> {
        Ok(Participant {
            id: r.get(0)?,
            machine: r.get(1)?,
            harness: r.get(2)?,
            harness_session: r.get(3)?,
            label: r.get(4)?,
            cwd: r.get(5)?,
            state: r.get(6)?,
            status: r.get(7)?,
            status_ts: r.get(8)?,
        })
    }

    const PARTICIPANT_COLS: &'static str =
        "id, machine, harness, harness_session, label, cwd, state, status, status_ts";

    /// A participant by id or label.
    pub fn resolve(&self, key: &str) -> Result<Participant> {
        let sql = format!(
            "SELECT {} FROM participants WHERE id = ?1 OR label = ?1",
            Self::PARTICIPANT_COLS
        );
        self.conn
            .query_row(&sql, params![key], Self::participant_row)
            .optional()?
            .ok_or_else(|| anyhow!("no participant with id or label {key:?}"))
    }

    pub fn participants(&self) -> Result<Vec<Participant>> {
        let sql = format!(
            "SELECT {} FROM participants ORDER BY created",
            Self::PARTICIPANT_COLS
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt.query_map([], Self::participant_row)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// Registers a session, or returns the participant already bound to the
    /// same harness session, which is what a resume does.
    pub fn register(
        &mut self,
        harness: &str,
        harness_session: &str,
        label: Option<&str>,
        cwd: Option<&str>,
    ) -> Result<Participant> {
        let existing = self
            .conn
            .query_row(
                "SELECT id FROM participants WHERE harness = ?1 AND harness_session = ?2",
                params![harness, harness_session],
                |r| r.get::<_, String>(0),
            )
            .optional()?;
        if let Some(id) = existing {
            if let Some(cwd) = cwd {
                self.conn.execute(
                    "UPDATE participants SET cwd = ?2 WHERE id = ?1",
                    params![id, cwd],
                )?;
            }
            return self.resolve(&id);
        }
        let id = new_id();
        let label = match label {
            Some(l) => l.to_string(),
            None => {
                let short: String = harness_session.chars().take(6).collect();
                format!("{harness}-{short}")
            }
        };
        if label == USER {
            bail!("the label {USER:?} is reserved for the person operating the bus");
        }
        let tx = self.conn.transaction()?;
        tx.execute(
            "INSERT INTO participants (id, machine, harness, harness_session, label, cwd) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![id, self.machine, harness, harness_session, label, cwd],
        )?;
        tx.commit()?;
        self.event(
            "participant_registered",
            &json!({"id": id, "harness": harness, "harness_session": harness_session, "label": label, "cwd": cwd}),
        )?;
        self.resolve(&id)
    }

    pub fn set_status(&mut self, caller: &str, text: &str) -> Result<Participant> {
        let p = self.resolve(caller)?;
        self.conn.execute(
            "UPDATE participants SET status = ?2, status_ts = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?1",
            params![p.id, text],
        )?;
        self.event("status_set", &json!({"id": p.id, "status": text}))?;
        self.resolve(&p.id)
    }

    // ----- edges ----------------------------------------------------------

    fn edge_row(r: &rusqlite::Row) -> rusqlite::Result<Edge> {
        Ok(Edge {
            id: r.get(0)?,
            kind: r.get(1)?,
            from: r.get(2)?,
            to: r.get(3)?,
            scope: r.get(4)?,
            replies: r.get::<_, i64>(5)? != 0,
        })
    }

    pub fn edges(&self) -> Result<Vec<Edge>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, kind, from_id, to_id, scope, replies FROM edges ORDER BY created",
        )?;
        let rows = stmt.query_map([], Self::edge_row)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    fn edges_touching(&self, id: &str) -> Result<Vec<Edge>> {
        Ok(self
            .edges()?
            .into_iter()
            .filter(|e| e.from == id || e.to == id)
            .collect())
    }

    /// Creates an edge. Only the user creates edges in this slice; spawning
    /// and proposals come with later steps of the build order.
    pub fn link(
        &mut self,
        caller: &str,
        kind: &str,
        from: &str,
        to: &str,
        scope: Option<&str>,
        replies: bool,
    ) -> Result<Edge> {
        if caller != USER {
            bail!("only the user creates edges; a session proposes one instead");
        }
        if !["supervises", "informs", "interface"].contains(&kind) {
            bail!("unknown relationship {kind:?}; use supervises, informs or interface");
        }
        let a = self.resolve(from)?;
        let b = self.resolve(to)?;
        if a.id == b.id {
            bail!("an edge needs two different participants");
        }
        if kind == "supervises" {
            let has: Option<String> = self
                .conn
                .query_row(
                    "SELECT from_id FROM edges WHERE kind = 'supervises' AND to_id = ?1",
                    params![b.id],
                    |r| r.get(0),
                )
                .optional()?;
            if let Some(sup) = has {
                let sup = self.resolve(&sup)?;
                bail!(
                    "{} already has a supervisor, {}; a session has at most one",
                    b.label,
                    sup.label
                );
            }
        }
        let replies = kind == "informs" && replies;
        let id = new_id();
        self.conn.execute(
            "INSERT INTO edges (id, kind, from_id, to_id, scope, replies) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![id, kind, a.id, b.id, scope, replies as i64],
        )?;
        self.event(
            "edge_created",
            &json!({"id": id, "kind": kind, "from": a.id, "to": b.id, "scope": scope, "replies": replies}),
        )?;
        Ok(Edge {
            id,
            kind: kind.into(),
            from: a.id,
            to: b.id,
            scope: scope.map(Into::into),
            replies,
        })
    }

    pub fn unlink(&mut self, caller: &str, edge: &str) -> Result<()> {
        if caller != USER {
            bail!("only the user removes edges");
        }
        let n = self
            .conn
            .execute("DELETE FROM edges WHERE id = ?1", params![edge])?;
        if n == 0 {
            bail!("no edge {edge:?}");
        }
        self.event("edge_removed", &json!({"id": edge}))?;
        Ok(())
    }

    // ----- what a participant sees -------------------------------------

    fn label_of(&self, id: &str) -> String {
        self.resolve(id)
            .map(|p| p.label)
            .unwrap_or_else(|_| id.to_string())
    }

    /// The caller's identity and every relationship it is part of, in the
    /// shape the session-start brief and `bus_whoami` present.
    pub fn whoami(&self, caller: &str) -> Result<Value> {
        let me = self.resolve(caller)?;
        let mut supervisor = Value::Null;
        let mut children = vec![];
        let mut informs = vec![];
        let mut informed_by = vec![];
        let mut fronts = vec![];
        let mut fronted_by = vec![];
        for e in self.edges_touching(&me.id)? {
            let outgoing = e.from == me.id;
            let peer = self.label_of(if outgoing { &e.to } else { &e.from });
            let entry = json!({"edge": e.id, "peer": peer, "scope": e.scope, "replies": e.replies});
            match (e.kind.as_str(), outgoing) {
                ("supervises", true) => children.push(json!(peer)),
                ("supervises", false) => supervisor = json!(peer),
                ("informs", true) => informs.push(entry),
                ("informs", false) => informed_by.push(entry),
                ("interface", true) => fronts.push(entry),
                ("interface", false) => fronted_by.push(entry),
                _ => {}
            }
        }
        Ok(json!({
            "participant": me,
            "supervisor": supervisor,
            "children": children,
            "informs": informs,
            "informed_by": informed_by,
            "interface_for": fronts,
            "fronted_by": fronted_by,
        }))
    }

    /// Whether `reader` may see `target`'s status: the user always; otherwise
    /// a supervisor or child, the informed side of an informs edge, or either
    /// side of an interface edge.
    pub fn read_status(&self, caller: &str, target: &str) -> Result<Participant> {
        let t = self.resolve(target)?;
        if caller == USER {
            return Ok(t);
        }
        let me = self.resolve(caller)?;
        let ok = self.edges_touching(&me.id)?.iter().any(|e| {
            let between = (e.from == me.id && e.to == t.id) || (e.from == t.id && e.to == me.id);
            between
                && match e.kind.as_str() {
                    "supervises" | "interface" => true,
                    "informs" => e.to == me.id,
                    _ => false,
                }
        });
        if !ok {
            bail!(
                "{} has no edge that lets it read the status of {}",
                me.label,
                t.label
            );
        }
        Ok(t)
    }

    // ----- messages -----------------------------------------------------

    /// The edge that allows `from` to send `kind` to `to`, or the reason none
    /// does. `None` with `Ok` means the sender is the user.
    fn permitting_edge(
        &self,
        from: &Participant,
        to: &Participant,
        kind: &str,
        reply_to: Option<&str>,
    ) -> Result<Edge> {
        let edges = self.edges_touching(&from.id)?;
        let mut reasons = vec![];
        for e in edges {
            let down = e.from == from.id && e.to == to.id;
            let up = e.from == to.id && e.to == from.id;
            if !down && !up {
                continue;
            }
            match e.kind.as_str() {
                "supervises" => {
                    if down && kind == "report" {
                        reasons.push("a supervisor sends directives, not reports".to_string());
                    } else if up && kind == "directive" {
                        reasons.push("a child sends reports, not directives".to_string());
                    } else {
                        return Ok(e);
                    }
                }
                "interface" => return Ok(e),
                "informs" => {
                    if down {
                        return Ok(e);
                    }
                    // The informed side may only reply, and only when the
                    // edge has replies on.
                    if !e.replies {
                        reasons.push(format!(
                            "{} is informed of {} one-way without replies",
                            from.label, to.label
                        ));
                        continue;
                    }
                    let Some(r) = reply_to else {
                        reasons.push(
                            "over a one-way edge with replies, only replies may be sent".into(),
                        );
                        continue;
                    };
                    let answers_sender: bool = self
                        .conn
                        .query_row(
                            "SELECT COUNT(*) FROM messages WHERE id = ?1 AND from_id = ?2 AND to_id = ?3",
                            params![r, to.id, from.id],
                            |row| row.get::<_, i64>(0),
                        )
                        .map(|n| n > 0)?;
                    if answers_sender {
                        return Ok(e);
                    }
                    reasons.push(format!(
                        "message {r} is not one {} sent to {}",
                        to.label, from.label
                    ));
                }
                _ => {}
            }
        }
        if reasons.is_empty() {
            bail!(
                "{} has no edge to {}; ask the user for one with bus_propose_peer",
                from.label,
                to.label
            )
        }
        bail!(reasons.join("; "))
    }

    fn insert_message(
        &mut self,
        from_id: &str,
        to_id: &str,
        kind: &str,
        body: &str,
        reply_to: Option<&str>,
        edge_id: Option<&str>,
    ) -> Result<String> {
        let id = new_id();
        self.conn.execute(
            "INSERT INTO messages (id, from_id, to_id, kind, body, reply_to, edge_id) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![id, from_id, to_id, kind, body, reply_to, edge_id],
        )?;
        self.event(
            "message_sent",
            &json!({"id": id, "from": from_id, "to": to_id, "kind": kind, "reply_to": reply_to, "edge": edge_id}),
        )?;
        Ok(id)
    }

    /// Sends a message. A `notice` with no recipient goes to every participant
    /// informed of the sender. Returns the ids and recipients of the messages
    /// created.
    pub fn send(
        &mut self,
        caller: &str,
        to: Option<&str>,
        kind: &str,
        body: &str,
        reply_to: Option<&str>,
    ) -> Result<Value> {
        if !KINDS.contains(&kind) {
            bail!(
                "unknown message kind {kind:?}; use one of {}",
                KINDS.join(", ")
            );
        }
        if body.trim().is_empty() {
            bail!("a message needs a body");
        }
        if to == Some(USER) {
            bail!(
                "sessions reach the user by escalation through their managers, which this version of the bus does not carry yet"
            );
        }
        if caller == USER {
            let to = to.ok_or_else(|| anyhow!("the user names a recipient"))?;
            let t = self.resolve(to)?;
            let id = self.insert_message(USER, &t.id, kind, body, reply_to, None)?;
            return Ok(json!({"sent": [{"id": id, "to": t.label}]}));
        }
        let me = self.resolve(caller)?;
        if kind == "relay" {
            bail!(
                "relays of the user's words are verified against the user's prompts, which this version of the bus does not record yet"
            );
        }
        let mut sent = vec![];
        match to {
            None => {
                if kind != "notice" {
                    bail!(
                        "only a notice may omit the recipient; it then goes to everyone informed of you"
                    );
                }
                let informed: Vec<Edge> = self
                    .edges_touching(&me.id)?
                    .into_iter()
                    .filter(|e| e.kind == "informs" && e.from == me.id)
                    .collect();
                if informed.is_empty() {
                    bail!(
                        "nobody is informed of {}, so a notice has no recipients",
                        me.label
                    );
                }
                for e in informed {
                    let id =
                        self.insert_message(&me.id, &e.to, kind, body, reply_to, Some(&e.id))?;
                    sent.push(json!({"id": id, "to": self.label_of(&e.to)}));
                }
            }
            Some(to) => {
                let t = self.resolve(to)?;
                let e = self.permitting_edge(&me, &t, kind, reply_to)?;
                let id = self.insert_message(&me.id, &t.id, kind, body, reply_to, Some(&e.id))?;
                sent.push(json!({"id": id, "to": t.label}));
            }
        }
        Ok(json!({"sent": sent}))
    }

    /// The caller's unread messages, oldest first, marked read unless
    /// `mark_read` is false.
    pub fn inbox(&mut self, caller: &str, mark_read: bool) -> Result<Value> {
        let me = self.resolve(caller)?;
        let mut stmt = self.conn.prepare(
            "SELECT id, from_id, kind, body, reply_to, edge_id, created FROM messages WHERE to_id = ?1 AND state != 'read' ORDER BY created, id",
        )?;
        let rows: Vec<(
            String,
            String,
            String,
            String,
            Option<String>,
            Option<String>,
            String,
        )> = stmt
            .query_map(params![me.id], |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get(3)?,
                    r.get(4)?,
                    r.get(5)?,
                    r.get(6)?,
                ))
            })?
            .collect::<rusqlite::Result<_>>()?;
        drop(stmt);
        let mut out = vec![];
        for (id, from, kind, body, reply_to, edge, created) in rows {
            let from_label = if from == USER {
                USER.to_string()
            } else {
                self.label_of(&from)
            };
            out.push(json!({"id": id, "from": from_label, "kind": kind, "body": body, "reply_to": reply_to, "edge": edge, "sent": created}));
            if mark_read {
                self.conn.execute(
                    "UPDATE messages SET state = 'read', read_ts = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?1",
                    params![id],
                )?;
                self.event("message_read", &json!({"id": id, "by": me.id}))?;
            }
        }
        Ok(json!({"messages": out}))
    }

    /// How many unread messages the caller has, for the hooks that tell a
    /// session it has mail without delivering the bodies.
    pub fn unread(&self, caller: &str) -> Result<i64> {
        let me = self.resolve(caller)?;
        Ok(self.conn.query_row(
            "SELECT COUNT(*) FROM messages WHERE to_id = ?1 AND state != 'read'",
            params![me.id],
            |r| r.get(0),
        )?)
    }
}
