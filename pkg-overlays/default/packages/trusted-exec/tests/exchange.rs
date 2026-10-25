// SPDX-License-Identifier: MIT
//! `call` against `serve` over a real unix socket. Each test accepts one
//! connection and starts `serve` with it as stdin, as a systemd socket
//! with `Accept=yes` does.

use std::ffi::OsStr;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::OwnedFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Output, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

const BIN: &str = env!("CARGO_BIN_EXE_trusted-exec");

unsafe extern "C" {
    fn kill(pid: i32, sig: i32) -> i32;
}

fn scratch() -> PathBuf {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let dir = std::env::temp_dir().join(format!(
        "trusted-exec-test-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::SeqCst)
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// A listening socket whose one connection is served by `serve ARGS`.
struct Service {
    socket: PathBuf,
    done: JoinHandle<ExitStatus>,
}

fn service(args: &[&str]) -> Service {
    let socket = scratch().join("s.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let args: Vec<String> = args.iter().map(|a| a.to_string()).collect();
    let done = thread::spawn(move || {
        let (conn, _) = listener.accept().unwrap();
        Command::new(BIN)
            .arg("serve")
            .args(&args)
            .env_remove("DROP")
            .stdin(Stdio::from(OwnedFd::from(conn)))
            .status()
            .unwrap()
    });
    Service { socket, done }
}

fn caller(socket: &Path, pass_env: &[&str], args: &[&OsStr]) -> Command {
    let mut command = Command::new(BIN);
    command
        .args(["call", "--name", "tool", "--socket"])
        .arg(socket);
    for name in pass_env {
        command.args(["--pass-env", name]);
    }
    command.arg("--").args(args);
    command
}

fn run(mut command: Command, input: Vec<u8>) -> Output {
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    // The caller may exit before it has read all of its input.
    thread::spawn(move || {
        let _ = stdin.write_all(&input);
    });
    child.wait_with_output().unwrap()
}

fn sh(script: &str) -> Vec<&str> {
    vec!["--", "/bin/sh", "-c", script, "sh"]
}

#[test]
fn streams_stdout_stderr_and_the_exit_code() {
    let svc = service(&sh("echo out; echo err >&2; exit 3"));
    let out = run(caller(&svc.socket, &[], &[]), Vec::new());
    assert_eq!(out.stdout, b"out\n");
    assert_eq!(out.stderr, b"err\n");
    assert_eq!(out.status.code(), Some(3));
    assert!(svc.done.join().unwrap().success());
}

#[test]
fn round_trips_a_large_stdin() {
    let svc = service(&sh("exec cat"));
    let input: Vec<u8> = (0..16 * 1024 * 1024u32).map(|i| (i % 251) as u8).collect();
    let out = run(caller(&svc.socket, &[], &[]), input.clone());
    assert_eq!(out.status.code(), Some(0));
    assert!(out.stdout == input, "stdout differs from stdin");
}

#[test]
fn appends_arguments_as_raw_bytes() {
    let svc = service(&sh(r#"printf '%s\n' "$@""#));
    let odd = OsStr::from_bytes(b"\xff\xfe");
    let out = run(
        caller(&svc.socket, &[], &[OsStr::new("a b"), odd]),
        Vec::new(),
    );
    assert_eq!(out.stdout, b"a b\n\xff\xfe\n");
}

#[test]
fn the_service_decides_which_variables_pass() {
    let mut args = vec!["--pass-env", "KEEP"];
    args.extend(sh(r#"echo "${KEEP-unset} ${DROP-unset}""#));
    let svc = service(&args);
    let mut command = caller(&svc.socket, &["KEEP", "DROP"], &[]);
    command.env("KEEP", "1").env("DROP", "2");
    let out = run(command, Vec::new());
    assert_eq!(out.stdout, b"1 unset\n");
}

#[test]
fn runs_in_the_callers_directory_unless_one_is_declared() {
    let dir = scratch().canonicalize().unwrap();
    let svc = service(&sh("pwd"));
    let mut command = caller(&svc.socket, &[], &[]);
    command.current_dir(&dir);
    let out = run(command, Vec::new());
    assert_eq!(out.stdout, format!("{}\n", dir.display()).into_bytes());

    let mut args = vec!["--cwd", "/"];
    args.extend(sh("pwd"));
    let svc = service(&args);
    let mut command = caller(&svc.socket, &[], &[]);
    command.current_dir(&dir);
    assert_eq!(run(command, Vec::new()).stdout, b"/\n");
}

#[test]
fn a_missing_program_is_127() {
    let svc = service(&["--", "/nonexistent/program"]);
    let out = run(caller(&svc.socket, &[], &[]), Vec::new());
    assert_eq!(out.status.code(), Some(127));
    assert!(String::from_utf8_lossy(&out.stderr).contains("cannot run /nonexistent/program"));
}

/// A caller whose program has printed `ready`. With `input`, the caller
/// is fed that stdin from a thread that ignores write errors.
fn spawn_ready(
    svc: &Service,
    input: Option<Vec<u8>>,
) -> (Child, BufReader<std::process::ChildStdout>) {
    let stdin = if input.is_some() {
        Stdio::piped()
    } else {
        Stdio::null()
    };
    let mut child = caller(&svc.socket, &[], &[])
        .stdin(stdin)
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    if let Some(input) = input {
        let mut pipe = child.stdin.take().unwrap();
        thread::spawn(move || {
            let _ = pipe.write_all(&input);
        });
    }
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    let mut line = String::new();
    stdout.read_line(&mut line).unwrap();
    assert_eq!(line, "ready\n");
    (child, stdout)
}

#[test]
fn forwards_signals_to_the_program() {
    let script = r#"trap 'exit 42' TERM; echo ready; while :; do sleep 0.05; done"#;
    let svc = service(&sh(script));
    let (mut child, _) = spawn_ready(&svc, None);
    unsafe { kill(child.id() as i32, 15) };
    assert_eq!(child.wait().unwrap().code(), Some(42));
}

#[test]
fn signals_reach_a_program_that_does_not_read_stdin() {
    let script = r#"trap 'exit 42' TERM; echo ready; while :; do sleep 0.05; done"#;
    let svc = service(&sh(script));
    let (mut child, _) = spawn_ready(&svc, Some(vec![0u8; 16 * 1024 * 1024]));
    // Long enough for the window and the pipe of the program to fill.
    thread::sleep(Duration::from_millis(500));
    unsafe { kill(child.id() as i32, 15) };
    assert_eq!(child.wait().unwrap().code(), Some(42));
}

#[test]
fn a_signal_after_the_program_exits_ends_the_call() {
    // The background sleep keeps the stdout of the program open.
    let svc = service(&sh("sleep 30 & echo ready; exit 5"));
    let (mut child, _) = spawn_ready(&svc, None);
    thread::sleep(Duration::from_millis(200));
    let start = Instant::now();
    unsafe { kill(child.id() as i32, 2) };
    assert_eq!(child.wait().unwrap().code(), Some(5));
    assert!(start.elapsed() < Duration::from_secs(10));
}

#[test]
fn a_vanished_caller_ends_the_call_after_the_program_exits() {
    let svc = service(&sh("sleep 30 & echo ready; exit 0"));
    let (mut child, _) = spawn_ready(&svc, None);
    thread::sleep(Duration::from_millis(200));
    let start = Instant::now();
    child.kill().unwrap();
    child.wait().unwrap();
    assert!(svc.done.join().unwrap().success());
    assert!(
        start.elapsed() < Duration::from_secs(10),
        "the service waited for a process the program left behind"
    );
}

#[test]
fn a_vanished_caller_hangs_up_the_program() {
    let script = "echo ready; exec sleep 30";
    let svc = service(&sh(script));
    let (mut child, _) = spawn_ready(&svc, None);
    let start = Instant::now();
    child.kill().unwrap();
    child.wait().unwrap();
    assert!(svc.done.join().unwrap().success());
    assert!(
        start.elapsed() < Duration::from_secs(10),
        "the program outlived its caller"
    );
}

#[test]
fn a_program_that_ignores_stdin_still_finishes() {
    let svc = service(&sh("exit 0"));
    let input = vec![0u8; 16 * 1024 * 1024];
    let out = run(caller(&svc.socket, &[], &[]), input);
    assert_eq!(out.status.code(), Some(0));
}

#[test]
fn refuses_a_frame_before_the_request() {
    let svc = service(&sh("echo ran"));
    let mut conn = UnixStream::connect(&svc.socket).unwrap();
    conn.write_all(&[b'0', 0, 0, 0, 1, b'x']).unwrap();
    let mut reply = Vec::new();
    conn.read_to_end(&mut reply).unwrap();
    assert_eq!(reply[0], b'E');
    assert_eq!(reply[5], 126);
    assert!(String::from_utf8_lossy(&reply[6..]).contains("before the request was complete"));
}

/// The reply to a hand-written request: the status byte and message of
/// the ERROR frame the service answers with.
fn refusal(request: &[u8]) -> (u8, String) {
    let svc = service(&sh("echo ran"));
    let mut conn = UnixStream::connect(&svc.socket).unwrap();
    // The service stops reading once it refuses, so the rest of an
    // oversized request may not be taken.
    let _ = conn.write_all(request);
    let mut reply = Vec::new();
    conn.read_to_end(&mut reply).unwrap();
    assert_eq!(reply[0], b'E');
    (reply[5], String::from_utf8_lossy(&reply[6..]).into_owned())
}

fn frame(kind: u8, payload: &[u8]) -> Vec<u8> {
    let mut out = vec![kind];
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(payload);
    out
}

#[test]
fn refuses_a_request_over_the_size_limit() {
    let mut request = Vec::new();
    for _ in 0..5 {
        request.extend(frame(b'A', &vec![b'x'; 1 << 20]));
    }
    let (status, message) = refusal(&request);
    assert_eq!(status, 126);
    assert!(message.contains("over the"), "{message}");
}

#[test]
fn refuses_a_nul_byte_in_an_argument() {
    let mut request = frame(b'A', b"a\0b");
    request.extend(frame(b'R', b""));
    let (status, message) = refusal(&request);
    assert_eq!(status, 126);
    assert!(
        message.contains("an argument contains a NUL byte"),
        "{message}"
    );
}

#[test]
fn an_unreachable_service_is_255() {
    let socket = scratch().join("absent.sock");
    let out = run(caller(&socket, &[], &[]), Vec::new());
    assert_eq!(out.status.code(), Some(255));
    assert!(String::from_utf8_lossy(&out.stderr).contains("cannot reach the trusted executable"));
}
