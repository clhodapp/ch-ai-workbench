// SPDX-License-Identifier: MIT
//! trusted-exec: run a trusted executable outside Claude Code's sandbox,
//! with its IO streamed over a unix socket.
//!
//! Usage:
//!   trusted-exec call --name NAME --socket PATH [--pass-env VAR]... -- [ARG]...
//!   trusted-exec serve [--cwd DIR] [--pass-env VAR]... -- PROGRAM [ARG]...
//!
//! The home-manager module of agent-sandbox declares each trusted
//! executable as a systemd user socket with `Accept=yes`, whose service
//! runs `serve` with the connection as stdin. A sandbox module that
//! grants the executable puts a stub on PATH that runs `call`, and adds
//! the socket to the unix-socket allowlist of every checkout choosing
//! the module. The socket is the capability: `call` only speaks the
//! protocol in `protocol.rs`.

mod call;
mod protocol;
mod serve;
mod sys;

use std::ffi::OsString;
use std::path::PathBuf;
use std::process::exit;

fn usage() -> ! {
    eprintln!(
        "usage: trusted-exec call --name NAME --socket PATH [--pass-env VAR]... -- [ARG]...\n\
         \x20      trusted-exec serve [--cwd DIR] [--pass-env VAR]... -- PROGRAM [ARG]..."
    );
    exit(2)
}

/// Options before `--` as (flag, value) pairs, and the words after it.
fn split_options(
    mut args: impl Iterator<Item = OsString>,
) -> (Vec<(String, OsString)>, Vec<OsString>) {
    let mut options = Vec::new();
    loop {
        let Some(flag) = args.next() else { usage() };
        if flag == "--" {
            return (options, args.collect());
        }
        let Some(flag) = flag.to_str().map(str::to_string) else {
            usage()
        };
        let Some(value) = args.next() else { usage() };
        options.push((flag, value));
    }
}

fn main() {
    let mut args = std::env::args_os().skip(1);
    let verb = args.next();
    let (options, rest) = split_options(args);
    let mut pass_env = Vec::new();
    let status = match verb.as_ref().and_then(|v| v.to_str()) {
        Some("call") => {
            let mut name = None;
            let mut socket = None;
            for (flag, value) in options {
                match flag.as_str() {
                    "--name" => name = Some(value),
                    "--socket" => socket = Some(PathBuf::from(value)),
                    "--pass-env" => pass_env.push(value),
                    _ => usage(),
                }
            }
            let (Some(name), Some(socket)) = (name, socket) else {
                usage()
            };
            call::call(&call::Options {
                name,
                socket,
                pass_env,
                args: rest,
            })
        }
        Some("serve") => {
            let mut cwd = None;
            for (flag, value) in options {
                match flag.as_str() {
                    "--cwd" => cwd = Some(PathBuf::from(value)),
                    "--pass-env" => pass_env.push(value),
                    _ => usage(),
                }
            }
            if rest.is_empty() {
                usage();
            }
            serve::serve(&serve::Config {
                cwd,
                pass_env,
                program: rest,
            })
        }
        _ => usage(),
    };
    exit(status)
}
