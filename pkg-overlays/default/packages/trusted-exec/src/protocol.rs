// SPDX-License-Identifier: MIT
//! The frames `call` and `serve` exchange over the connection.
//!
//! A frame is one kind byte, a four-byte big-endian payload length, and
//! the payload. The caller sends the request first: any number of ARG,
//! CWD and ENV frames, then RUN. After RUN the caller sends STDIN and
//! SIGNAL frames. The service sends STDOUT, STDERR and CREDIT frames, and
//! then one EXIT or ERROR frame as its last frame.
//!
//! Stdin is flow-controlled by credit. The caller may have at most
//! WINDOW bytes of stdin sent and not yet credited. The service credits
//! each chunk once the program has taken it, or once it has dropped the
//! chunk because the program closed its stdin. The service therefore
//! never has to stop reading the connection to hold back stdin, and a
//! SIGNAL frame or a closed connection reaches it even while the program
//! is not reading.

use std::io::{self, Read, Write};

pub const HEADER: usize = 5;

/// The largest payload either side sends in one frame. The caller's
/// reads and the service's reads of the program's output are this size,
/// so a busy stream moves in 64 KiB writes.
pub const CHUNK: usize = 64 * 1024;

/// The largest payload either side accepts. A request frame holds one
/// argument or one variable, so this bounds a single argument too.
pub const MAX_PAYLOAD: usize = 1 << 20;

/// The stdin bytes a caller may have in flight: sent, and not yet
/// credited by the service.
pub const WINDOW: usize = 1 << 20;

/// Caller to service: one argument after the declared ones.
pub const ARG: u8 = b'A';
/// Caller to service: the caller's working directory.
pub const CWD: u8 = b'C';
/// Caller to service: one `NAME=VALUE` variable.
pub const ENV: u8 = b'V';
/// Caller to service: the request is complete; start the program.
pub const RUN: u8 = b'R';
/// Caller to service: bytes for the program's stdin. An empty payload
/// closes the program's stdin.
pub const STDIN: u8 = b'0';
/// Caller to service: one byte, a signal number for the program's
/// process group.
pub const SIGNAL: u8 = b'S';
/// Service to caller: bytes the program wrote to stdout.
pub const STDOUT: u8 = b'1';
/// Service to caller: bytes the program wrote to stderr.
pub const STDERR: u8 = b'2';
/// Service to caller: a four-byte big-endian count of stdin bytes the
/// caller may send again.
pub const CREDIT: u8 = b'K';
/// Service to caller: `c` and the exit code, or `s` and the signal that
/// ended the program, as a four-byte big-endian integer.
pub const EXIT: u8 = b'X';
/// Service to caller: the exit status the caller should use, then a
/// message, when the program did not run.
pub const ERROR: u8 = b'E';

/// The signals a caller may forward. Anything else in a SIGNAL frame is
/// ignored.
pub const FORWARDED_SIGNALS: [i32; 4] = [
    crate::sys::SIGHUP,
    crate::sys::SIGINT,
    crate::sys::SIGQUIT,
    crate::sys::SIGTERM,
];

/// Append one frame to `buf`, for a caller that sends several in one
/// write.
pub fn push_frame(buf: &mut Vec<u8>, kind: u8, payload: &[u8]) {
    buf.push(kind);
    buf.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    buf.extend_from_slice(payload);
}

pub fn write_frame(w: &mut impl Write, kind: u8, payload: &[u8]) -> io::Result<()> {
    let mut buf = Vec::with_capacity(HEADER + payload.len());
    push_frame(&mut buf, kind, payload);
    w.write_all(&buf)
}

/// A buffer whose first HEADER bytes are kept free, so that a chunk read
/// into the rest goes out with its header in one write.
pub struct Chunk {
    buf: Box<[u8]>,
}

impl Chunk {
    pub fn new() -> Self {
        Chunk {
            buf: vec![0u8; HEADER + CHUNK].into_boxed_slice(),
        }
    }

    pub fn space(&mut self) -> &mut [u8] {
        &mut self.buf[HEADER..]
    }

    /// The frame holding the first `len` bytes of `space()`.
    pub fn frame(&mut self, kind: u8, len: usize) -> &[u8] {
        self.buf[0] = kind;
        self.buf[1..HEADER].copy_from_slice(&(len as u32).to_be_bytes());
        &self.buf[..HEADER + len]
    }
}

/// Read one frame into `payload`, replacing its contents. Returns the
/// kind, or `None` when the peer closed the connection between frames.
/// The payload is read into the spare capacity of `payload`, so a reused
/// buffer is not zero-filled first.
pub fn read_frame(r: &mut impl Read, payload: &mut Vec<u8>) -> io::Result<Option<u8>> {
    let mut header = [0u8; HEADER];
    let mut got = 0;
    while got < HEADER {
        match r.read(&mut header[got..]) {
            Ok(0) if got == 0 => return Ok(None),
            Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
            Ok(n) => got += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    let len = u32::from_be_bytes([header[1], header[2], header[3], header[4]]) as usize;
    if len > MAX_PAYLOAD {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("frame of {len} bytes is over the {MAX_PAYLOAD}-byte limit"),
        ));
    }
    payload.clear();
    payload.reserve(len);
    if r.by_ref().take(len as u64).read_to_end(payload)? != len {
        return Err(io::ErrorKind::UnexpectedEof.into());
    }
    Ok(Some(header[0]))
}

/// A four-byte big-endian count, the payload of a CREDIT frame.
pub fn count(payload: &[u8]) -> Option<usize> {
    let bytes: [u8; 4] = payload.try_into().ok()?;
    Some(u32::from_be_bytes(bytes) as usize)
}
