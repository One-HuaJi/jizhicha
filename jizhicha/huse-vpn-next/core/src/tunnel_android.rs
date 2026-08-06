//! Android layer-3 forwarding for an Android `VpnService` TUN descriptor.
//!
//! The Android service owns the system VPN permission and creates the TUN.
//! This module only moves raw IP packets between that descriptor and the
//! already-authenticated NC/TLS stream. Routes are installed by Kotlin with
//! `VpnService.Builder`, so the Gateway control socket remains on the physical
//! network and does not need an Android `protect()` callback.

use crate::error::{HuseVpnError, Result};
use crate::nc::{build_nc_data_frame, parse_nc_data_frames};
use crate::tls::RawTlsClient;
use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use tokio::io::unix::AsyncFd;

/// Forward packets until either the Android TUN or the NC/TLS connection
/// closes. `tun_fd` is an owned descriptor detached from a
/// `ParcelFileDescriptor`; this function takes responsibility for closing it.
pub async fn run_android_tunnel(tls: RawTlsClient, tun_fd: RawFd) -> Result<()> {
    let tun = unsafe { File::from_raw_fd(tun_fd) };
    let tun_reader = AsyncFd::new(tun.try_clone().map_err(|error| {
        HuseVpnError::Tunnel(format!("failed to duplicate Android TUN: {error}"))
    })?)
    .map_err(|error| HuseVpnError::Tunnel(format!("failed to watch Android TUN: {error}")))?;
    let tun_writer = AsyncFd::new(tun)
        .map_err(|error| HuseVpnError::Tunnel(format!("failed to watch Android TUN: {error}")))?;

    let (mut tls_reader, mut tls_writer) = tls.into_split();

    let uplink = async move {
        let mut packet = vec![0u8; u16::MAX as usize];
        loop {
            let length = read_tun(&tun_reader, &mut packet).await?;
            if length == 0 {
                return Err(HuseVpnError::Tunnel("Android TUN reader closed".into()));
            }
            validate_ip_packet(&packet[..length])?;
            let frame = build_nc_data_frame(&packet[..length])?;
            tls_writer.write(&frame).await?;
        }
    };

    let downlink = async move {
        loop {
            let record = tls_reader.read_record().await?;
            for packet in parse_nc_data_frames(&record)? {
                validate_ip_packet(&packet)?;
                write_tun(&tun_writer, &packet).await?;
            }
        }
    };

    tokio::select! {
        result = uplink => result,
        result = downlink => result,
    }
}

async fn read_tun(tun: &AsyncFd<File>, buffer: &mut [u8]) -> Result<usize> {
    loop {
        let mut guard = tun.readable().await.map_err(|error| {
            HuseVpnError::Tunnel(format!("Android TUN read readiness failed: {error}"))
        })?;
        match guard.try_io(|inner| unsafe_read(inner.get_ref().as_raw_fd(), buffer)) {
            Ok(result) => {
                return result.map_err(|error| {
                    HuseVpnError::Tunnel(format!("Android TUN read failed: {error}"))
                })
            }
            Err(_would_block) => continue,
        }
    }
}

async fn write_tun(tun: &AsyncFd<File>, packet: &[u8]) -> Result<()> {
    let mut offset = 0;
    while offset < packet.len() {
        let mut guard = tun.writable().await.map_err(|error| {
            HuseVpnError::Tunnel(format!("Android TUN write readiness failed: {error}"))
        })?;
        match guard.try_io(|inner| unsafe_write(inner.get_ref().as_raw_fd(), &packet[offset..])) {
            Ok(result) => {
                let written = result.map_err(|error| {
                    HuseVpnError::Tunnel(format!("Android TUN write failed: {error}"))
                })?;
                if written == 0 {
                    return Err(HuseVpnError::Tunnel("Android TUN writer closed".into()));
                }
                offset += written;
            }
            Err(_would_block) => continue,
        }
    }
    Ok(())
}

fn unsafe_read(fd: RawFd, buffer: &mut [u8]) -> io::Result<usize> {
    let result = unsafe { libc::read(fd, buffer.as_mut_ptr().cast(), buffer.len()) };
    if result < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(result as usize)
    }
}

fn unsafe_write(fd: RawFd, buffer: &[u8]) -> io::Result<usize> {
    let result = unsafe { libc::write(fd, buffer.as_ptr().cast(), buffer.len()) };
    if result < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(result as usize)
    }
}

fn validate_ip_packet(packet: &[u8]) -> Result<()> {
    if packet.is_empty() || !matches!(packet[0] >> 4, 4 | 6) {
        return Err(HuseVpnError::Protocol(
            "Android TUN payload is not an IPv4 or IPv6 packet".into(),
        ));
    }
    Ok(())
}
