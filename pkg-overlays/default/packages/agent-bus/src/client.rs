// SPDX-License-Identifier: MIT
//! A blocking client of the daemon's socket, used by the CLI, the MCP server
//! and the hooks. Each call opens a connection, sends one request and reads
//! one reply; a short-lived process does not need more.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;

use anyhow::{Context, Result, anyhow};
use serde_json::Value;

pub fn request(socket: &Path, req: &Value) -> Result<Value> {
    let mut stream = UnixStream::connect(socket).with_context(|| {
        format!(
            "connecting to the agent-bus daemon at {}; is it running?",
            socket.display()
        )
    })?;
    stream.write_all(format!("{req}\n").as_bytes())?;
    let mut line = String::new();
    BufReader::new(&stream).read_line(&mut line)?;
    let reply: Value = serde_json::from_str(&line).context("the daemon's reply is not JSON")?;
    if reply.get("ok").and_then(Value::as_bool) == Some(true) {
        Ok(reply.get("result").cloned().unwrap_or(Value::Null))
    } else {
        Err(anyhow!(
            "{}",
            reply
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("the daemon refused the request")
        ))
    }
}

/// Streams events after `after` to `each` until the daemon closes the
/// connection or `each` returns an error.
pub fn watch(socket: &Path, after: i64, mut each: impl FnMut(Value) -> Result<()>) -> Result<()> {
    let mut stream = UnixStream::connect(socket)
        .with_context(|| format!("connecting to the agent-bus daemon at {}", socket.display()))?;
    stream.write_all(
        format!("{}\n", serde_json::json!({"op": "watch", "after": after})).as_bytes(),
    )?;
    for line in BufReader::new(stream).lines() {
        each(serde_json::from_str(&line?)?)?;
    }
    Ok(())
}
