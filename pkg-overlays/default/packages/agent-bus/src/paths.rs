// SPDX-License-Identifier: MIT
//! Where the daemon listens and keeps its store.
//!
//! The socket lives under `$XDG_RUNTIME_DIR/agent-bus/`, the store under
//! `$XDG_STATE_HOME/agent-bus/` (default `~/.local/state`). The
//! `AGENT_BUS_SOCKET` and `AGENT_BUS_DB` environment variables override
//! both, and command-line flags override the environment.

use std::env;
use std::path::PathBuf;

use anyhow::{Context, Result};

pub fn socket(flag: Option<PathBuf>) -> Result<PathBuf> {
    if let Some(p) = flag {
        return Ok(p);
    }
    if let Some(p) = env::var_os("AGENT_BUS_SOCKET") {
        return Ok(PathBuf::from(p));
    }
    let runtime = env::var_os("XDG_RUNTIME_DIR")
        .context("XDG_RUNTIME_DIR is not set; pass --socket or set AGENT_BUS_SOCKET")?;
    Ok(PathBuf::from(runtime).join("agent-bus").join("socket"))
}

pub fn db(flag: Option<PathBuf>) -> Result<PathBuf> {
    if let Some(p) = flag {
        return Ok(p);
    }
    if let Some(p) = env::var_os("AGENT_BUS_DB") {
        return Ok(PathBuf::from(p));
    }
    let state = match env::var_os("XDG_STATE_HOME") {
        Some(s) => PathBuf::from(s),
        None => PathBuf::from(
            env::var_os("HOME").context("HOME is not set; pass --db or set AGENT_BUS_DB")?,
        )
        .join(".local")
        .join("state"),
    };
    Ok(state.join("agent-bus").join("bus.sqlite"))
}

/// The name of this machine, recorded on every participant and event so that
/// stores from different machines can later be merged.
pub fn machine() -> String {
    std::fs::read_to_string("/proc/sys/kernel/hostname")
        .map(|s| s.trim().to_string())
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "localhost".to_string())
}
