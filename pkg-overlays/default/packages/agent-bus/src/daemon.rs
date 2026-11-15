// SPDX-License-Identifier: MIT
//! The daemon: one process per user, listening on a Unix socket.
//!
//! The protocol is newline-delimited JSON. Each request is an object with an
//! `op` and the op's fields; each reply is `{"ok": true, "result": ...}` or
//! `{"ok": false, "error": "..."}`. The `watch` op keeps the connection
//! open and streams every event after `after`, one per line, which is how
//! Emacs follows the bus.

use std::path::Path;
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result, anyhow, bail};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::broadcast;

use crate::store::Store;

struct Shared {
    store: Mutex<Store>,
    published: Mutex<i64>,
    events: broadcast::Sender<Value>,
}

fn field<'a>(req: &'a Value, name: &str) -> Result<&'a str> {
    req.get(name)
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("missing string field {name:?}"))
}

fn opt<'a>(req: &'a Value, name: &str) -> Option<&'a str> {
    req.get(name).and_then(Value::as_str)
}

/// Runs one request against the store.
fn dispatch(store: &mut Store, req: &Value) -> Result<Value> {
    let op = field(req, "op")?;
    match op {
        "register" => Ok(json!(store.register(
            field(req, "harness")?,
            field(req, "harness_session")?,
            opt(req, "label"),
            opt(req, "cwd"),
        )?)),
        "participants" => Ok(json!(store.participants()?)),
        "edges" => Ok(json!(store.edges()?)),
        "whoami" => store.whoami(field(req, "caller")?),
        "set_status" => Ok(json!(
            store.set_status(field(req, "caller")?, field(req, "text")?)?
        )),
        "read_status" => Ok(json!(
            store.read_status(field(req, "caller")?, field(req, "target")?)?
        )),
        "link" => Ok(json!(store.link(
            field(req, "caller")?,
            field(req, "kind")?,
            field(req, "from")?,
            field(req, "to")?,
            opt(req, "scope"),
            req.get("replies").and_then(Value::as_bool).unwrap_or(false),
        )?)),
        "unlink" => {
            store.unlink(field(req, "caller")?, field(req, "edge")?)?;
            Ok(Value::Null)
        }
        "send" => store.send(
            field(req, "caller")?,
            opt(req, "to"),
            field(req, "kind")?,
            field(req, "body")?,
            opt(req, "reply_to"),
        ),
        "inbox" => store.inbox(
            field(req, "caller")?,
            req.get("mark_read")
                .and_then(Value::as_bool)
                .unwrap_or(true),
        ),
        "unread" => Ok(json!(store.unread(field(req, "caller")?)?)),
        "log" => Ok(json!(store.events_after(
            req.get("after").and_then(Value::as_i64).unwrap_or(0)
        )?)),
        other => bail!("unknown op {other:?}"),
    }
}

impl Shared {
    fn handle(&self, req: &Value) -> Value {
        let mut store = self.store.lock().expect("store lock");
        let reply = match dispatch(&mut store, req) {
            Ok(result) => json!({"ok": true, "result": result}),
            Err(e) => json!({"ok": false, "error": format!("{e:#}")}),
        };
        // Publish whatever the request appended to the log.
        let mut published = self.published.lock().expect("published lock");
        if let Ok(new) = store.events_after(*published) {
            for ev in new {
                if let Some(seq) = ev.get("seq").and_then(Value::as_i64) {
                    *published = seq;
                }
                let _ = self.events.send(ev);
            }
        }
        reply
    }
}

async fn serve_conn(shared: Arc<Shared>, stream: UnixStream) -> Result<()> {
    let (read, mut write) = stream.into_split();
    let mut lines = BufReader::new(read).lines();
    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }
        let req: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(e) => {
                let reply = json!({"ok": false, "error": format!("request is not JSON: {e}")});
                write.write_all(format!("{reply}\n").as_bytes()).await?;
                continue;
            }
        };
        if req.get("op").and_then(Value::as_str) == Some("watch") {
            let after = req.get("after").and_then(Value::as_i64).unwrap_or(0);
            // Subscribe before reading the backlog so nothing falls between.
            let mut rx = shared.events.subscribe();
            let backlog = shared
                .store
                .lock()
                .expect("store lock")
                .events_after(after)?;
            let mut last = after;
            for ev in backlog {
                last = ev.get("seq").and_then(Value::as_i64).unwrap_or(last);
                write.write_all(format!("{ev}\n").as_bytes()).await?;
            }
            loop {
                match rx.recv().await {
                    Ok(ev) => {
                        let seq = ev.get("seq").and_then(Value::as_i64).unwrap_or(0);
                        if seq <= last {
                            continue;
                        }
                        last = seq;
                        write.write_all(format!("{ev}\n").as_bytes()).await?;
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => {
                        // Catch up from the store instead of dropping events.
                        let missed = shared
                            .store
                            .lock()
                            .expect("store lock")
                            .events_after(last)?;
                        for ev in missed {
                            last = ev.get("seq").and_then(Value::as_i64).unwrap_or(last);
                            write.write_all(format!("{ev}\n").as_bytes()).await?;
                        }
                    }
                    Err(broadcast::error::RecvError::Closed) => return Ok(()),
                }
            }
        }
        let reply = shared.handle(&req);
        write.write_all(format!("{reply}\n").as_bytes()).await?;
    }
    Ok(())
}

/// Removes a socket file left by a daemon that is no longer running, and
/// refuses to start when one is.
fn claim_socket(path: &Path) -> Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    if path.exists() {
        if std::os::unix::net::UnixStream::connect(path).is_ok() {
            bail!(
                "another agent-bus daemon is listening on {}",
                path.display()
            );
        }
        std::fs::remove_file(path)?;
    }
    Ok(())
}

pub fn run(socket: &Path, db: &Path) -> Result<()> {
    let store = Store::open(db, crate::paths::machine())
        .with_context(|| format!("opening the store at {}", db.display()))?;
    let published = store.last_seq()?;
    claim_socket(socket)?;
    let (events, _) = broadcast::channel(1024);
    let shared = Arc::new(Shared {
        store: Mutex::new(store),
        published: Mutex::new(published),
        events,
    });
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    rt.block_on(async move {
        let listener =
            UnixListener::bind(socket).with_context(|| format!("binding {}", socket.display()))?;
        let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
        loop {
            tokio::select! {
                accepted = listener.accept() => {
                    let (stream, _) = accepted?;
                    let shared = shared.clone();
                    tokio::spawn(async move {
                        if let Err(e) = serve_conn(shared, stream).await {
                            eprintln!("agent-bus: connection ended: {e:#}");
                        }
                    });
                }
                _ = tokio::signal::ctrl_c() => break,
                _ = term.recv() => break,
            }
        }
        let _ = std::fs::remove_file(socket);
        Ok::<(), anyhow::Error>(())
    })
}
