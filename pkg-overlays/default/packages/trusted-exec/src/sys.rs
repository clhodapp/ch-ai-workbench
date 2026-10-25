// SPDX-License-Identifier: MIT
//! The libc calls the standard library does not wrap, declared locally
//! so the crate has no dependencies. The constants are the Linux values
//! on x86-64 and AArch64, the two platforms the package builds for.

use std::io;
use std::os::raw::{c_int, c_void};

pub const SIGHUP: c_int = 1;
pub const SIGINT: c_int = 2;
pub const SIGQUIT: c_int = 3;
pub const SIGKILL: c_int = 9;
pub const SIGTERM: c_int = 15;

const SOL_SOCKET: c_int = 1;
const SO_PEERCRED: c_int = 17;

#[repr(C)]
struct Ucred {
    pid: i32,
    uid: u32,
    gid: u32,
}

unsafe extern "C" {
    fn kill(pid: i32, sig: c_int) -> c_int;
    fn getuid() -> u32;
    fn getsockopt(fd: c_int, level: c_int, name: c_int, val: *mut c_void, len: *mut u32) -> c_int;
    fn signal(sig: c_int, handler: usize) -> usize;
    fn pipe(fds: *mut c_int) -> c_int;
    fn write(fd: c_int, buf: *const c_void, n: usize) -> isize;
}

/// Send `sig` to every process in the process group `pgid`. A group
/// that no longer exists is not an error.
pub fn kill_group(pgid: u32, sig: c_int) {
    unsafe {
        kill(-(pgid as i32), sig);
    }
}

pub fn uid() -> u32 {
    unsafe { getuid() }
}

/// The uid of the process at the other end of a unix socket.
pub fn peer_uid(fd: c_int) -> io::Result<u32> {
    let mut cred = Ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    let mut len = std::mem::size_of::<Ucred>() as u32;
    let rc = unsafe {
        getsockopt(
            fd,
            SOL_SOCKET,
            SO_PEERCRED,
            &mut cred as *mut Ucred as *mut c_void,
            &mut len,
        )
    };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(cred.uid)
}

pub fn make_pipe() -> io::Result<(c_int, c_int)> {
    let mut fds = [0 as c_int; 2];
    if unsafe { pipe(fds.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok((fds[0], fds[1]))
}

/// Install `handler` for `sig`. glibc's `signal` restarts interrupted
/// reads, so the other threads' blocking IO is unaffected.
pub fn set_handler(sig: c_int, handler: extern "C" fn(c_int)) {
    unsafe {
        signal(sig, handler as usize);
    }
}

/// `write(2)` for a signal handler, which may not allocate or lock.
pub fn write_byte(fd: c_int, byte: u8) {
    unsafe {
        write(fd, &byte as *const u8 as *const c_void, 1);
    }
}
