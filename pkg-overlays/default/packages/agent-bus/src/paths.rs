// SPDX-License-Identifier: MIT
//! Where the daemon listens and keeps its store.
//!
//! Both live under `$XDG_STATE_HOME/agent-bus/` (default
//! `~/.local/state`). The socket is there rather than under
//! `$XDG_RUNTIME_DIR` because agent sandboxes grant sockets by an absolute
//! path fixed when the configuration is evaluated, and the runtime
//! directory holds the uid, which that evaluation does not know. The
//! `AGENT_BUS_SOCKET` and `AGENT_BUS_DB` environment variables override
//! both, and command-line flags override the environment.

use std::env;
use std::path::PathBuf;

use anyhow::{Context, Result};

fn state_dir() -> Result<PathBuf> {
    Ok(match env::var_os("XDG_STATE_HOME") {
        Some(s) => PathBuf::from(s),
        None => PathBuf::from(
            env::var_os("HOME")
                .context("HOME is not set; pass --socket/--db or set AGENT_BUS_*")?,
        )
        .join(".local")
        .join("state"),
    }
    .join("agent-bus"))
}

pub fn socket(flag: Option<PathBuf>) -> Result<PathBuf> {
    if let Some(p) = flag {
        return Ok(p);
    }
    if let Some(p) = env::var_os("AGENT_BUS_SOCKET") {
        return Ok(PathBuf::from(p));
    }
    Ok(state_dir()?.join("socket"))
}

pub fn db(flag: Option<PathBuf>) -> Result<PathBuf> {
    if let Some(p) = flag {
        return Ok(p);
    }
    if let Some(p) = env::var_os("AGENT_BUS_DB") {
        return Ok(PathBuf::from(p));
    }
    Ok(state_dir()?.join("bus.sqlite"))
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
