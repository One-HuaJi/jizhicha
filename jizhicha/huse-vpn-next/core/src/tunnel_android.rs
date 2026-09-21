//! Android layer-3 forwarding for an Android `VpnService` TUN descriptor.
//!
//! The Android service owns the system VPN permission and creates the TUN.
//! This module only moves raw IP packets between that descriptor and the
//! already-authenticated NC/TLS stream. Routes are installed by Kotlin with
//! `VpnService.Builder`, so the Gateway control socket remains on the physical
//! network and does not need an Android `protect()` callback.

use crate::error::{HuseVpnError, Result};
use crate::nc::{build_nc_data_frame, NcFrameAssembler};
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
            // ⚠️ 单个坏包不能拖垮整条隧道。
            //
            // 旧实现用 `?` 直接上抛：TUN 上只要出现一个非 IP 包（驱动异常、
            // 半截读、或内核塞进来的非 IP 流量），`tokio::select!` 就会
            // 结束整个 tunnel，用户表现为"用着用着突然断了"，而且要重新认证。
            // 而一个坏包只应被丢弃 —— 后面的好包还得继续转发。
            //
            // 注意：这里**只**吞掉"包内容非法"这一类错误；TUN 读失败、
            // TLS 写失败仍然上抛，因为那确实意味着隧道不可用。
            if validate_ip_packet(&packet[..length]).is_err() {
                continue;
            }
            let frame = match build_nc_data_frame(&packet[..length]) {
                Ok(frame) => frame,
                Err(_) => continue,
            };
            tls_writer.write(&frame).await?;
        }
    };

    let downlink = async move {
        // Reassemble NC frames that may be split across TLS record boundaries.
        let mut assembler = NcFrameAssembler::new();
        loop {
            let record = tls_reader.read_record().await?;
            for packet in assembler.feed(&record)? {
                // 下行同理：坏包丢弃，不中断整条隧道。
                if validate_ip_packet(&packet).is_err() {
                    continue;
                }
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

#[cfg(test)]
mod tests {
    use super::*;

    /// IPv4/IPv6 的一字节版本头应被接受，其余一律拒绝。
    ///
    /// 这条守着 `run_android_tunnel` 里的"坏包丢弃"逻辑：只有当
    /// `validate_ip_packet` 能稳定地把非 IP 包判为错误时，上层才能用
    /// `continue` 跳过它、而不是把整条隧道带崩。
    #[test]
    fn accepts_ip_version_headers_only() {
        assert!(validate_ip_packet(&[0x45]).is_ok(), "IPv4");
        assert!(validate_ip_packet(&[0x60]).is_ok(), "IPv6");
        assert!(validate_ip_packet(&[0x4f]).is_ok(), "IPv4 高四位为 4");
        assert!(validate_ip_packet(&[0x6f]).is_ok(), "IPv6 高四位为 6");
    }

    #[test]
    fn rejects_non_ip_and_empty() {
        assert!(validate_ip_packet(&[]).is_err(), "空包");
        for header in [0x00u8, 0x10, 0x30, 0x50, 0x70, 0x80, 0xf0] {
            assert!(
                validate_ip_packet(&[header]).is_err(),
                "0x{header:02x} 不是 IPv4/IPv6"
            );
        }
    }

    /// 断言错误类型是 `Protocol`（内容问题）而不是 `Tunnel`（链路问题）——
    /// 这个区分正是"能安全跳过的坏包"与"必须上抛的故障"的边界。
    #[test]
    fn bad_packet_is_protocol_error_not_tunnel_error() {
        let error = validate_ip_packet(&[0x00]).unwrap_err();
        assert!(
            matches!(error, HuseVpnError::Protocol(_)),
            "坏包必须归类为 Protocol，才能被 uplink/downlink 安全跳过；实际: {error:?}"
        );
    }
}
