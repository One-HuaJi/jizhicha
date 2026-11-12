//! Descriptor hygiene for the TUN descriptor handed over from Kotlin.
//!
//! Android's `VpnService` hands out the TUN descriptor through
//! `ParcelFileDescriptor`, which is created in **blocking** mode. Tokio's
//! `AsyncFd` requires a non-blocking descriptor: with a blocking one, the
//! `read` that finds no packet ready parks the whole runtime worker thread,
//! and the downlink that shares that thread stops draining TLS records. The
//! tunnel then looks frozen until the next packet happens to arrive.
//!
//! The flag is set here, on the Rust side, so the invariant lives next to the
//! `AsyncFd` that depends on it instead of in a Kotlin caller that may change.

use std::io;
use std::os::fd::RawFd;

/// Put `fd` into non-blocking mode. Idempotent: an already non-blocking
/// descriptor is left untouched.
pub fn set_nonblocking(fd: RawFd) -> io::Result<()> {
    // SAFETY: `fcntl` only reads or writes descriptor status flags. The
    // descriptor stays owned by the caller and is never closed here.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    if flags & libc::O_NONBLOCK != 0 {
        return Ok(());
    }
    if unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::fd::AsRawFd;
    use std::os::unix::net::UnixStream;

    #[test]
    fn sets_the_non_blocking_flag_and_is_idempotent() {
        let (left, _right) = UnixStream::pair().expect("socket pair");
        let fd = left.as_raw_fd();
        set_nonblocking(fd).expect("first call sets the flag");
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        assert_ne!(flags & libc::O_NONBLOCK, 0, "O_NONBLOCK must be set");
        set_nonblocking(fd).expect("second call is a no-op");
        let flags_after = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        assert_eq!(
            flags & libc::O_NONBLOCK,
            flags_after & libc::O_NONBLOCK,
            "the flag must not be cleared or toggled"
        );
    }

    #[test]
    fn a_descriptor_that_is_not_open_is_rejected() {
        let fd = {
            let (left, right) = UnixStream::pair().expect("socket pair");
            drop(right);
            left.as_raw_fd()
        };
        assert!(set_nonblocking(fd).is_err(), "closed descriptor must fail");
    }
}
