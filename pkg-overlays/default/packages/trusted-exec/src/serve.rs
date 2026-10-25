// SPDX-License-Identifier: MIT
//! The service side: one process per connection, started by a systemd
//! socket unit with `Accept=yes`, which passes the connection as stdin.
//!
//! The request is untrusted input. From it the service takes the
//! arguments (after the declared ones), the working directory when no
//! fixed one is declared, and the variables the declaration names with
//! `--pass-env`. Everything else about the run comes from the service:
//! the program, its environment, and the sandbox systemd puts it in.
//!
//! The program runs in its own process group with piped stdio. Three
//! threads move bytes: one each for its stdout and stderr, and one for
//! the frames the caller sends (stdin and signals). A closed connection
//! means the caller is gone: the group gets SIGHUP, and SIGKILL if it is
//! still running after a grace period.

use std::ffi::OsString;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStringExt;
use std::os::unix::net::UnixStream;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use crate::protocol::*;
use crate::sys;

pub struct Config {
    /// The working directory of every run. `None` runs the program in
    /// the caller's working directory.
    pub cwd: Option<PathBuf>,
    /// The variables a caller may set.
    pub pass_env: Vec<OsString>,
    /// The program and the arguments every run starts with.
    pub program: Vec<OsString>,
}

const HANGUP_GRACE: Duration = Duration::from_secs(5);

/// A request holds at most this many frames, so a caller cannot make the
/// service hold an unbounded request in memory.
const MAX_REQUEST_FRAMES: usize = 1 << 16;

struct Request {
    args: Vec<OsString>,
    cwd: Option<PathBuf>,
    env: Vec<(OsString, OsString)>,
}

/// The program's process group, and whether the program has exited.
/// After the exit the group id may be reused, so nothing signals it.
struct Group {
    pgid: u32,
    exited: AtomicBool,
    hung_up: AtomicBool,
}

impl Group {
    fn signal(&self, sig: i32) {
        if !self.exited.load(Ordering::SeqCst) {
            sys::kill_group(self.pgid, sig);
        }
    }

    fn hang_up(self: &Arc<Self>) {
        if self.hung_up.swap(true, Ordering::SeqCst) {
            return;
        }
        self.signal(sys::SIGHUP);
        let group = Arc::clone(self);
        thread::spawn(move || {
            thread::sleep(HANGUP_GRACE);
            group.signal(sys::SIGKILL);
        });
    }
}

pub fn serve(config: &Config) -> i32 {
    let conn = unsafe { UnixStream::from_raw_fd(0) };
    match run(config, conn) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("trusted-exec serve: {e}");
            1
        }
    }
}

fn refuse(writer: &Mutex<UnixStream>, status: u8, message: &str) -> io::Result<()> {
    let mut payload = vec![status];
    payload.extend_from_slice(message.as_bytes());
    write_frame(&mut *writer.lock().unwrap(), ERROR, &payload)
}

fn run(config: &Config, conn: UnixStream) -> io::Result<()> {
    let mut reader = conn.try_clone()?;
    let writer = Arc::new(Mutex::new(conn));

    // The socket file is 0600, so only this user and root can connect.
    // The check keeps root's processes out as well.
    let peer = sys::peer_uid(reader.as_raw_fd())?;
    if peer != sys::uid() {
        return refuse(&writer, 126, &format!("refusing a caller with uid {peer}"));
    }

    let request = match read_request(&mut reader) {
        Ok(Some(request)) => request,
        Ok(None) => return Ok(()),
        Err(e) => return refuse(&writer, 126, &format!("bad request: {e}")),
    };
    let cwd = match (&config.cwd, request.cwd) {
        (Some(dir), _) => dir.clone(),
        (None, Some(dir)) if dir.is_absolute() => dir,
        (None, _) => {
            return refuse(
                &writer,
                126,
                "the request carries no absolute working directory",
            );
        }
    };

    let mut command = Command::new(&config.program[0]);
    command
        .args(&config.program[1..])
        .args(&request.args)
        .current_dir(&cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0);
    for (name, value) in &request.env {
        if config.pass_env.contains(name) {
            command.env(name, value);
        }
    }
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(e) => {
            let status = if e.kind() == io::ErrorKind::NotFound {
                127
            } else {
                126
            };
            let program = Path::new(&config.program[0]).display();
            return refuse(
                &writer,
                status,
                &format!("cannot run {program} in {}: {e}", cwd.display()),
            );
        }
    };

    let group = Arc::new(Group {
        pgid: child.id(),
        exited: AtomicBool::new(false),
        hung_up: AtomicBool::new(false),
    });
    let out = pump(child.stdout.take().unwrap(), STDOUT, &writer, &group);
    let err = pump(child.stderr.take().unwrap(), STDERR, &writer, &group);
    {
        let stdin = child.stdin.take();
        let group = Arc::clone(&group);
        thread::spawn(move || feed(reader, stdin, group));
    }

    let status = child.wait()?;
    group.exited.store(true, Ordering::SeqCst);
    // A process the program left behind that still holds its stdout or
    // stderr keeps the exchange open until it closes them, as with ssh.
    let _ = out.join();
    let _ = err.join();

    let mut payload = Vec::with_capacity(5);
    match status.code() {
        Some(code) => {
            payload.push(b'c');
            payload.extend_from_slice(&code.to_be_bytes());
        }
        None => {
            payload.push(b's');
            payload.extend_from_slice(&status.signal().unwrap_or(0).to_be_bytes());
        }
    }
    let sent = write_frame(&mut *writer.lock().unwrap(), EXIT, &payload);
    // After a hang-up the caller is gone, and nobody reads the status.
    if group.hung_up.load(Ordering::SeqCst) {
        return Ok(());
    }
    sent
}

/// The frames up to RUN. `None` when the caller closed the connection
/// before finishing the request.
fn read_request(reader: &mut UnixStream) -> io::Result<Option<Request>> {
    let mut request = Request {
        args: Vec::new(),
        cwd: None,
        env: Vec::new(),
    };
    let mut payload = Vec::new();
    for _ in 0..MAX_REQUEST_FRAMES {
        let kind = match read_frame(reader, &mut payload)? {
            Some(kind) => kind,
            None => return Ok(None),
        };
        let bytes = std::mem::take(&mut payload);
        match kind {
            ARG => request.args.push(OsString::from_vec(bytes)),
            CWD => request.cwd = Some(PathBuf::from(OsString::from_vec(bytes))),
            ENV => {
                let split = bytes.iter().position(|&b| b == b'=').filter(|&i| i > 0);
                let Some(i) = split else {
                    return Err(invalid("a variable without a name"));
                };
                let name = OsString::from_vec(bytes[..i].to_vec());
                let value = OsString::from_vec(bytes[i + 1..].to_vec());
                request.env.push((name, value));
            }
            RUN => return Ok(Some(request)),
            other => {
                return Err(invalid(&format!(
                    "frame {:?} before the request was complete",
                    other as char
                )));
            }
        }
    }
    Err(invalid("the request has too many frames"))
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.to_string())
}

/// Copy one of the program's output pipes to the caller as `kind`
/// frames until the pipe closes.
fn pump(
    mut source: impl Read + Send + 'static,
    kind: u8,
    writer: &Arc<Mutex<UnixStream>>,
    group: &Arc<Group>,
) -> JoinHandle<()> {
    let writer = Arc::clone(writer);
    let group = Arc::clone(group);
    thread::spawn(move || {
        let mut chunk = Chunk::new();
        loop {
            let n = match source.read(chunk.space()) {
                Ok(0) => return,
                Ok(n) => n,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => return,
            };
            if writer
                .lock()
                .unwrap()
                .write_all(chunk.frame(kind, n))
                .is_err()
            {
                group.hang_up();
                return;
            }
        }
    })
}

/// Apply the caller's stdin and signal frames until the connection
/// closes. A program that stops reading its stdin gets no more of it.
/// Later stdin frames are discarded, so the caller is not blocked.
fn feed(mut reader: UnixStream, mut stdin: Option<ChildStdin>, group: Arc<Group>) {
    let mut payload = Vec::new();
    loop {
        match read_frame(&mut reader, &mut payload) {
            Ok(Some(STDIN)) => {
                if payload.is_empty() {
                    stdin = None;
                } else if let Some(pipe) = stdin.as_mut() {
                    if pipe.write_all(&payload).is_err() {
                        stdin = None;
                    }
                }
            }
            Ok(Some(SIGNAL)) => {
                if let Some(&sig) = payload.first() {
                    let sig = sig as i32;
                    if FORWARDED_SIGNALS.contains(&sig) {
                        group.signal(sig);
                    }
                }
            }
            _ => {
                group.hang_up();
                return;
            }
        }
    }
}
