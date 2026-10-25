// SPDX-License-Identifier: MIT
//! The service side: one process per connection, started by a systemd
//! socket unit with `Accept=yes`, which passes the connection as stdin.
//!
//! The request is untrusted input. From it the service takes the
//! arguments (after the declared ones), the working directory when no
//! fixed one is declared, and the variables the declaration names with
//! `--pass-env`. Everything else about the run comes from the service:
//! the program, its environment, and the restrictions systemd applies.
//!
//! The program runs in its own process group with piped stdio. Four
//! threads move bytes:
//! - one each copies the stdout and stderr of the program to the caller;
//! - `feed` reads the frames the caller sends, queues stdin and delivers
//!   signals;
//! - `drain` writes the queued stdin to the program and credits it.
//!
//! `feed` never blocks on the program, so a signal or a closed
//! connection is seen even while the program does not read its stdin.
//! A closed connection means the caller is gone: the group gets SIGHUP,
//! and SIGKILL if it is still running after a grace period.
//!
//! Once the program has exited, a closed connection or a forwarded
//! signal ends the call, even while processes the program left behind
//! still hold its stdout or stderr. The service then exits, and systemd
//! stops what is left in the cgroup of the service instance.

use std::collections::VecDeque;
use std::ffi::OsString;
use std::io::{self, Read, Write};
use std::net::Shutdown;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStringExt;
use std::os::unix::net::UnixStream;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
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

/// The bytes a request may take, frame headers included, so a caller
/// cannot make the service hold an unbounded request in memory. Linux
/// limits the arguments and environment of a program to less than this.
const MAX_REQUEST_BYTES: usize = 4 << 20;

struct Request {
    args: Vec<OsString>,
    cwd: Option<PathBuf>,
    env: Vec<(OsString, OsString)>,
}

/// What the main thread waits for once the program has exited.
enum Event {
    /// One of the output pipes reached its end.
    OutputDone,
    /// The caller went away or sent a signal: stop waiting for the
    /// output pipes.
    Abandon,
}

/// The process group of the program. Once the program has exited,
/// nothing signals the group: its id may then belong to another group.
struct Group {
    pgid: u32,
    exited: AtomicBool,
    hung_up: AtomicBool,
    events: Sender<Event>,
}

impl Group {
    fn signal(&self, sig: i32) {
        if self.exited.load(Ordering::SeqCst) {
            let _ = self.events.send(Event::Abandon);
        } else {
            sys::kill_group(self.pgid, sig);
        }
    }

    fn hang_up(self: &Arc<Self>) {
        if self.hung_up.swap(true, Ordering::SeqCst) {
            return;
        }
        let _ = self.events.send(Event::Abandon);
        self.signal(sys::SIGHUP);
        let group = Arc::clone(self);
        thread::spawn(move || {
            thread::sleep(HANGUP_GRACE);
            group.signal(sys::SIGKILL);
        });
    }
}

/// Stdin chunks that `feed` has received and `drain` has not yet written.
/// `pending` counts their bytes, which the caller's window bounds.
struct Inbox {
    chunks: VecDeque<Vec<u8>>,
    pending: usize,
    closed: bool,
}

type Shared<T> = Arc<(Mutex<T>, Condvar)>;

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

/// Send an ERROR frame, then read what the caller still sends until it
/// closes the connection. Closing a unix socket with unread data makes
/// the next read of the peer fail with ECONNRESET, which would hide the
/// ERROR frame from the caller. The drain stops after a second or a
/// request's worth of bytes.
fn refuse(writer: &Mutex<UnixStream>, status: u8, message: &str) -> io::Result<()> {
    let mut payload = vec![status];
    payload.extend_from_slice(message.as_bytes());
    let conn = writer.lock().unwrap();
    write_frame(&mut &*conn, ERROR, &payload)?;
    conn.shutdown(Shutdown::Write)?;
    conn.set_read_timeout(Some(Duration::from_secs(1)))?;
    let mut sink = [0u8; CHUNK];
    let mut left = MAX_REQUEST_BYTES;
    while left > 0 {
        match (&*conn).read(&mut sink) {
            Ok(0) | Err(_) => break,
            Ok(n) => left = left.saturating_sub(n),
        }
    }
    Ok(())
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

    let (events, waiting) = mpsc::channel();
    let group = Arc::new(Group {
        pgid: child.id(),
        exited: AtomicBool::new(false),
        hung_up: AtomicBool::new(false),
        events,
    });
    pump(child.stdout.take().unwrap(), STDOUT, &writer, &group);
    pump(child.stderr.take().unwrap(), STDERR, &writer, &group);
    let inbox: Shared<Inbox> = Arc::new((
        Mutex::new(Inbox {
            chunks: VecDeque::new(),
            pending: 0,
            closed: false,
        }),
        Condvar::new(),
    ));
    {
        let stdin = child.stdin.take();
        let inbox = Arc::clone(&inbox);
        let writer = Arc::clone(&writer);
        thread::spawn(move || drain(stdin, inbox, writer));
    }
    {
        let group = Arc::clone(&group);
        thread::spawn(move || feed(reader, inbox, group));
    }

    let status = child.wait()?;
    group.exited.store(true, Ordering::SeqCst);
    let mut open = 2;
    while open > 0 {
        match waiting.recv() {
            Ok(Event::OutputDone) => open -= 1,
            Ok(Event::Abandon) | Err(_) => break,
        }
    }

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
    let mut taken = 0;
    loop {
        let kind = match read_frame(reader, &mut payload)? {
            Some(kind) => kind,
            None => return Ok(None),
        };
        taken += HEADER + payload.len();
        if taken > MAX_REQUEST_BYTES {
            return Err(invalid(&format!(
                "the request is over the {MAX_REQUEST_BYTES}-byte limit"
            )));
        }
        let what = match kind {
            ARG => "an argument",
            CWD => "the working directory",
            ENV => "a variable",
            RUN => return Ok(Some(request)),
            other => {
                return Err(invalid(&format!(
                    "frame {:?} before the request was complete",
                    other as char
                )));
            }
        };
        // A program cannot receive a NUL byte in an argument, a variable
        // or a path.
        if payload.contains(&0) {
            return Err(invalid(&format!("{what} contains a NUL byte")));
        }
        let bytes = payload.clone();
        match kind {
            ARG => request.args.push(OsString::from_vec(bytes)),
            CWD => request.cwd = Some(PathBuf::from(OsString::from_vec(bytes))),
            _ => {
                let split = bytes.iter().position(|&b| b == b'=').filter(|&i| i > 0);
                let Some(i) = split else {
                    return Err(invalid("a variable without a name"));
                };
                let name = OsString::from_vec(bytes[..i].to_vec());
                let value = OsString::from_vec(bytes[i + 1..].to_vec());
                request.env.push((name, value));
            }
        }
    }
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.to_string())
}

/// Copy one of the output pipes of the program to the caller as `kind`
/// frames until the pipe closes.
fn pump(
    mut source: impl Read + Send + 'static,
    kind: u8,
    writer: &Arc<Mutex<UnixStream>>,
    group: &Arc<Group>,
) {
    let writer = Arc::clone(writer);
    let group = Arc::clone(group);
    thread::spawn(move || {
        let mut chunk = Chunk::new();
        loop {
            let n = match source.read(chunk.space()) {
                Ok(0) => break,
                Ok(n) => n,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => break,
            };
            if writer
                .lock()
                .unwrap()
                .write_all(chunk.frame(kind, n))
                .is_err()
            {
                group.hang_up();
                break;
            }
        }
        let _ = group.events.send(Event::OutputDone);
    });
}

/// Read the frames the caller sends after RUN until the connection
/// closes: queue stdin for `drain`, and deliver signals.
fn feed(mut reader: UnixStream, inbox: Shared<Inbox>, group: Arc<Group>) {
    let (lock, ready) = &*inbox;
    let mut payload = Vec::new();
    let reason = loop {
        match read_frame(&mut reader, &mut payload) {
            Ok(Some(STDIN)) => {
                let mut inbox = lock.lock().unwrap();
                if payload.is_empty() {
                    inbox.closed = true;
                } else {
                    inbox.pending += payload.len();
                    if inbox.pending > WINDOW {
                        break Some("the caller sent stdin beyond its window".to_string());
                    }
                    inbox.chunks.push_back(std::mem::take(&mut payload));
                }
                ready.notify_one();
            }
            Ok(Some(SIGNAL)) => {
                if let Some(&sig) = payload.first() {
                    let sig = sig as i32;
                    if FORWARDED_SIGNALS.contains(&sig) {
                        group.signal(sig);
                    }
                }
            }
            Ok(Some(other)) => break Some(format!("unexpected frame {:?}", other as char)),
            Ok(None) => break None,
            Err(e) => break Some(e.to_string()),
        }
    };
    if let Some(reason) = reason {
        eprintln!("trusted-exec serve: {reason}; hanging up the program");
    }
    lock.lock().unwrap().closed = true;
    ready.notify_one();
    group.hang_up();
}

/// Write the queued stdin to the program and credit each chunk to the
/// caller. A program that closes its stdin gets no more of it: later
/// chunks are dropped and credited, so the caller is not held up. The
/// stdin of the program closes when the queue is empty and closed.
fn drain(mut stdin: Option<ChildStdin>, inbox: Shared<Inbox>, writer: Arc<Mutex<UnixStream>>) {
    let (lock, ready) = &*inbox;
    loop {
        let chunk = {
            let mut inbox = lock.lock().unwrap();
            while inbox.chunks.is_empty() && !inbox.closed {
                inbox = ready.wait(inbox).unwrap();
            }
            match inbox.chunks.pop_front() {
                Some(chunk) => chunk,
                None => return,
            }
        };
        if let Some(pipe) = stdin.as_mut() {
            if pipe.write_all(&chunk).is_err() {
                stdin = None;
            }
        }
        lock.lock().unwrap().pending -= chunk.len();
        let credit = (chunk.len() as u32).to_be_bytes();
        if write_frame(&mut *writer.lock().unwrap(), CREDIT, &credit).is_err() {
            return;
        }
    }
}
