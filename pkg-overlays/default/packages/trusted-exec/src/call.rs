// SPDX-License-Identifier: MIT
//! The caller side, which the stub on a sandboxed PATH runs.
//!
//! It sends the request in one write: its arguments, its working
//! directory, and the values of the variables the stub names. Then it
//! streams its stdin to the service and forwards SIGHUP, SIGINT, SIGQUIT
//! and SIGTERM, while writing the program's stdout and stderr to its own.
//! It exits with the program's exit code, or 128 plus the signal that
//! ended the program.
//!
//! The service decides what the request may change. The stub's list of
//! variables only keeps the rest of the caller's environment off the
//! connection.

use std::env;
use std::ffi::OsString;
use std::fs::File;
use std::io::{self, Read, Write};
use std::mem::ManuallyDrop;
use std::os::fd::FromRawFd;
use std::os::raw::c_int;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;

use crate::protocol::*;
use crate::sys;

pub struct Options {
    /// The command name, for messages.
    pub name: OsString,
    pub socket: PathBuf,
    pub pass_env: Vec<OsString>,
    pub args: Vec<OsString>,
}

/// The exit status for a failure to reach the service, or a connection
/// lost before the exit status arrived, as ssh uses it.
const TRANSPORT_FAILURE: i32 = 255;

/// 128 plus SIGPIPE: the status of a program whose stdout reader left.
const BROKEN_STDOUT: i32 = 141;

pub fn call(options: &Options) -> i32 {
    let name = options.name.to_string_lossy();
    let conn = match UnixStream::connect(&options.socket) {
        Ok(conn) => conn,
        Err(e) => {
            eprintln!(
                "{name}: cannot reach the trusted executable at {}: {e}",
                options.socket.display()
            );
            return TRANSPORT_FAILURE;
        }
    };
    match exchange(options, conn) {
        Ok(status) => status,
        Err(e) => {
            eprintln!("{name}: lost the connection to the trusted executable: {e}");
            TRANSPORT_FAILURE
        }
    }
}

fn exchange(options: &Options, conn: UnixStream) -> io::Result<i32> {
    let mut reader = conn.try_clone()?;
    let writer = Arc::new(Mutex::new(conn));

    let mut request = Vec::new();
    for arg in &options.args {
        push_frame(&mut request, ARG, arg.as_bytes());
    }
    if let Ok(dir) = env::current_dir() {
        push_frame(&mut request, CWD, dir.as_os_str().as_bytes());
    }
    for name in &options.pass_env {
        if let Some(value) = env::var_os(name) {
            let mut pair = name.as_bytes().to_vec();
            pair.push(b'=');
            pair.extend_from_slice(value.as_bytes());
            push_frame(&mut request, ENV, &pair);
        }
    }
    push_frame(&mut request, RUN, &[]);
    writer.lock().unwrap().write_all(&request)?;

    forward_signals(&writer)?;
    {
        let writer = Arc::clone(&writer);
        thread::spawn(move || pump_stdin(writer));
    }

    // Unbuffered, so each chunk reaches the reader as it arrives.
    let mut stdout = ManuallyDrop::new(unsafe { File::from_raw_fd(1) });
    let mut stderr = ManuallyDrop::new(unsafe { File::from_raw_fd(2) });
    let mut payload = Vec::new();
    loop {
        match read_frame(&mut reader, &mut payload)? {
            Some(STDOUT) => {
                if stdout.write_all(&payload).is_err() {
                    return Ok(BROKEN_STDOUT);
                }
            }
            Some(STDERR) => {
                let _ = stderr.write_all(&payload);
            }
            Some(EXIT) if payload.len() == 5 => {
                let value = i32::from_be_bytes([payload[1], payload[2], payload[3], payload[4]]);
                return Ok(if payload[0] == b's' {
                    128 + value
                } else {
                    value
                });
            }
            Some(ERROR) if !payload.is_empty() => {
                let name = options.name.to_string_lossy();
                eprintln!("{name}: {}", String::from_utf8_lossy(&payload[1..]));
                return Ok(payload[0] as i32);
            }
            Some(kind) => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("unexpected frame {:?}", kind as char),
                ));
            }
            None => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "the service closed the connection before sending the exit status",
                ));
            }
        }
    }
}

fn pump_stdin(writer: Arc<Mutex<UnixStream>>) {
    let mut stdin = ManuallyDrop::new(unsafe { File::from_raw_fd(0) });
    let mut chunk = Chunk::new();
    loop {
        // A closed or unreadable stdin reads as end of input.
        let n = match stdin.read(chunk.space()) {
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => 0,
        };
        if writer
            .lock()
            .unwrap()
            .write_all(chunk.frame(STDIN, n))
            .is_err()
            || n == 0
        {
            return;
        }
    }
}

/// The write end of the pipe the signal handler reports into. A handler
/// may not lock or allocate, so a thread turns the bytes into frames.
static SIGNAL_PIPE: AtomicI32 = AtomicI32::new(-1);

extern "C" fn on_signal(sig: c_int) {
    let fd = SIGNAL_PIPE.load(Ordering::Relaxed);
    if fd >= 0 {
        sys::write_byte(fd, sig as u8);
    }
}

fn forward_signals(writer: &Arc<Mutex<UnixStream>>) -> io::Result<()> {
    let (read_fd, write_fd) = sys::make_pipe()?;
    SIGNAL_PIPE.store(write_fd, Ordering::Relaxed);
    for sig in FORWARDED_SIGNALS {
        sys::set_handler(sig, on_signal);
    }
    let writer = Arc::clone(writer);
    thread::spawn(move || {
        let mut pipe = unsafe { File::from_raw_fd(read_fd) };
        let mut sig = [0u8; 1];
        while let Ok(1) = pipe.read(&mut sig) {
            if write_frame(&mut *writer.lock().unwrap(), SIGNAL, &sig).is_err() {
                return;
            }
        }
    });
    Ok(())
}
