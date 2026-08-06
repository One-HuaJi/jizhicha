//! Gateway/SecWorld NC tunnel framing.
//!
//! This module mirrors the framing used by `gwnc.dll` for the first tunnel
//! authentication exchange. All integer fields are unsigned big-endian
//! values. Strings carry their byte length and are padded with zeroes to a
//! four-byte boundary.

use crate::error::{HuseVpnError, Result};

/// NC authentication command used in the eight-byte application frame header.
pub const CMD_NC_AUTH: u32 = 0x0100_0002;

/// NC data command. Its payload is `u32 reserved` followed by one raw IP
/// packet (the native client removes the 14-byte Ethernet header first).
pub const CMD_NC_DATA: u32 = 0x0100_000a;

/// Successful NC authentication response and the network configuration sent
/// by the gateway.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NcAuthReply {
    pub command: u32,
    pub virtual_ip: String,
    pub dns_servers: Vec<String>,
    pub wins_servers: Vec<String>,
    pub profile_routes: Vec<ProfileRoute>,
    pub route_monitor: u32,
    pub route_generate: u32,
    pub dns_suffix: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProfileRoute {
    pub address: String,
    pub netmask: String,
}

/// Decode the 64-character ticket returned by the login service into the
/// exact 32 bytes consumed by the NC protocol.
pub fn decode_ticket_hex(value: &str) -> Result<[u8; 32]> {
    let value = value.trim();
    if value.len() != 64 || !value.as_bytes().iter().all(u8::is_ascii_hexdigit) {
        return Err(HuseVpnError::Protocol(
            "NC ticket must contain exactly 64 hexadecimal characters".into(),
        ));
    }

    let decoded = hex::decode(value)
        .map_err(|e| HuseVpnError::Protocol(format!("invalid NC ticket: {e}")))?;
    let mut ticket = [0u8; 32];
    ticket.copy_from_slice(&decoded);
    Ok(ticket)
}

/// Build the complete application frame sent immediately after the TLS
/// handshake.
pub fn build_nc_auth_frame(ticket: &[u8; 32], username: &str) -> Result<Vec<u8>> {
    if username.is_empty() {
        return Err(HuseVpnError::Protocol(
            "NC authentication username is empty".into(),
        ));
    }
    let username_len = u32::try_from(username.len())
        .map_err(|_| HuseVpnError::Protocol("NC authentication username is too long".into()))?;
    let padded_username_len = padded_len(username.len())?;

    let mut payload = Vec::with_capacity(32 + 4 + padded_username_len + 8);
    payload.extend_from_slice(ticket);
    payload.extend_from_slice(&username_len.to_be_bytes());
    payload.extend_from_slice(username.as_bytes());
    payload.resize(32 + 4 + padded_username_len, 0);
    payload.extend_from_slice(&1u32.to_be_bytes());
    payload.extend_from_slice(&0u32.to_be_bytes());

    let payload_len = u32::try_from(payload.len())
        .map_err(|_| HuseVpnError::Protocol("NC authentication payload is too long".into()))?;
    let mut frame = Vec::with_capacity(payload.len() + 8);
    frame.extend_from_slice(&CMD_NC_AUTH.to_be_bytes());
    frame.extend_from_slice(&payload_len.to_be_bytes());
    frame.extend_from_slice(&payload);
    Ok(frame)
}

/// Wrap one IPv4/IPv6 packet for transport over the authenticated TLS stream.
pub fn build_nc_data_frame(ip_packet: &[u8]) -> Result<Vec<u8>> {
    if ip_packet.is_empty() {
        return Err(HuseVpnError::Protocol("NC IP packet is empty".into()));
    }
    let payload_len = ip_packet
        .len()
        .checked_add(4)
        .and_then(|length| u32::try_from(length).ok())
        .ok_or_else(|| HuseVpnError::Protocol("NC IP packet is too large".into()))?;

    let mut frame = Vec::with_capacity(ip_packet.len() + 12);
    frame.extend_from_slice(&CMD_NC_DATA.to_be_bytes());
    frame.extend_from_slice(&payload_len.to_be_bytes());
    frame.extend_from_slice(&0u32.to_be_bytes());
    frame.extend_from_slice(ip_packet);
    Ok(frame)
}

/// Parse all complete NC data frames from one decrypted TLS application
/// record. The native client accepts multiple concatenated frames.
pub fn parse_nc_data_frames(mut data: &[u8]) -> Result<Vec<Vec<u8>>> {
    let mut packets = Vec::new();
    while !data.is_empty() {
        if data.len() < 12 {
            return Err(HuseVpnError::Protocol(
                "NC data frame is shorter than its 12-byte header".into(),
            ));
        }
        let command = u32::from_be_bytes(data[0..4].try_into().unwrap());
        if command != CMD_NC_DATA {
            return Err(HuseVpnError::Protocol(format!(
                "unexpected NC data command 0x{command:08x}"
            )));
        }
        let payload_len = u32::from_be_bytes(data[4..8].try_into().unwrap()) as usize;
        if payload_len < 4 {
            return Err(HuseVpnError::Protocol(
                "NC data payload length is smaller than its reserved field".into(),
            ));
        }
        let frame_len = payload_len
            .checked_add(8)
            .ok_or_else(|| HuseVpnError::Protocol("NC data frame length overflow".into()))?;
        if frame_len > data.len() {
            return Err(HuseVpnError::Protocol(
                "NC data frame ended inside an IP packet".into(),
            ));
        }
        packets.push(data[12..frame_len].to_vec());
        data = &data[frame_len..];
    }
    Ok(packets)
}

/// Parse a complete framed NC authentication reply.
pub fn parse_nc_auth_reply(frame: &[u8]) -> Result<NcAuthReply> {
    if frame.len() < 8 {
        return Err(HuseVpnError::Protocol(
            "NC authentication reply is shorter than its frame header".into(),
        ));
    }

    let command = u32::from_be_bytes(frame[0..4].try_into().unwrap());
    let declared_len = u32::from_be_bytes(frame[4..8].try_into().unwrap()) as usize;
    if declared_len != frame.len() - 8 {
        return Err(HuseVpnError::Protocol(format!(
            "NC authentication reply length mismatch: header={declared_len}, actual={}",
            frame.len() - 8
        )));
    }

    let mut reader = ProtocolReader::new(&frame[8..]);
    let status = reader.read_u32()?;
    if status != 0 {
        return Err(HuseVpnError::Authentication(format!(
            "NC gateway rejected authentication with status 0x{status:08x}"
        )));
    }

    let virtual_ip = reader.read_string()?;

    let dns_count = reader.read_count("DNS server")?;
    let mut dns_servers = Vec::with_capacity(dns_count);
    for _ in 0..dns_count {
        dns_servers.push(reader.read_string()?);
    }

    let wins_count = reader.read_count("WINS server")?;
    let mut wins_servers = Vec::with_capacity(wins_count);
    for _ in 0..wins_count {
        wins_servers.push(reader.read_string()?);
    }

    let route_count = reader.read_count("profile route")?;
    let mut profile_routes = Vec::with_capacity(route_count);
    for _ in 0..route_count {
        profile_routes.push(ProfileRoute {
            address: reader.read_string()?,
            netmask: reader.read_string()?,
        });
    }

    let route_monitor = reader.read_u32()?;
    let route_generate = reader.read_u32()?;
    let dns_suffix = reader.read_string()?;
    if !reader.remaining().iter().all(|byte| *byte == 0) {
        return Err(HuseVpnError::Protocol(format!(
            "NC authentication reply has {} unexpected trailing bytes",
            reader.remaining().len()
        )));
    }

    Ok(NcAuthReply {
        command,
        virtual_ip,
        dns_servers,
        wins_servers,
        profile_routes,
        route_monitor,
        route_generate,
        dns_suffix,
    })
}

impl crate::tls::RawTlsClient {
    /// Send the NC authentication request without waiting for the reply.
    /// The native client performs its session notification after this write
    /// and before it consumes the authentication response.
    pub async fn send_nc_auth(&mut self, ticket: &[u8; 32], username: &str) -> Result<()> {
        let request = build_nc_auth_frame(ticket, username)?;
        self.write(&request).await
    }

    /// Read and decode the NC authentication response after the session
    /// notification has been sent.
    pub async fn read_nc_auth_reply(&mut self) -> Result<NcAuthReply> {
        let response = self.read_record().await?;
        parse_nc_auth_reply(&response)
    }

    /// Send the first NC authentication frame over an established raw TLS
    /// connection and parse the gateway's configuration reply.
    pub async fn authenticate_nc(
        &mut self,
        ticket: &[u8; 32],
        username: &str,
    ) -> Result<NcAuthReply> {
        self.send_nc_auth(ticket, username).await?;
        self.read_nc_auth_reply().await
    }
}

fn padded_len(len: usize) -> Result<usize> {
    len.checked_add(3)
        .map(|value| value & !3)
        .ok_or_else(|| HuseVpnError::Protocol("NC string length overflow".into()))
}

struct ProtocolReader<'a> {
    data: &'a [u8],
    offset: usize,
}

impl<'a> ProtocolReader<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, offset: 0 }
    }

    fn read_u32(&mut self) -> Result<u32> {
        let bytes = self.take(4)?;
        Ok(u32::from_be_bytes(bytes.try_into().unwrap()))
    }

    fn read_count(&mut self, field: &str) -> Result<usize> {
        let count = self.read_u32()? as usize;
        let minimum_bytes = count.checked_mul(4).ok_or_else(|| {
            HuseVpnError::Protocol(format!("NC {field} count overflows address space"))
        })?;
        if minimum_bytes > self.remaining().len() {
            return Err(HuseVpnError::Protocol(format!(
                "NC {field} count {count} exceeds the remaining reply"
            )));
        }
        Ok(count)
    }

    fn read_string(&mut self) -> Result<String> {
        let length = self.read_u32()? as usize;
        let padded = padded_len(length)?;
        let bytes = self.take(padded)?;
        if bytes[length..].iter().any(|byte| *byte != 0) {
            return Err(HuseVpnError::Protocol(
                "NC string contains non-zero alignment padding".into(),
            ));
        }
        String::from_utf8(bytes[..length].to_vec())
            .map_err(|e| HuseVpnError::Protocol(format!("NC string is not UTF-8: {e}")))
    }

    fn take(&mut self, length: usize) -> Result<&'a [u8]> {
        let end = self.offset.checked_add(length).ok_or_else(|| {
            HuseVpnError::Protocol("NC authentication reply offset overflow".into())
        })?;
        if end > self.data.len() {
            return Err(HuseVpnError::Protocol(
                "NC authentication reply ended inside a field".into(),
            ));
        }
        let value = &self.data[self.offset..end];
        self.offset = end;
        Ok(value)
    }

    fn remaining(&self) -> &'a [u8] {
        &self.data[self.offset..]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn push_string(out: &mut Vec<u8>, value: &str) {
        out.extend_from_slice(&(value.len() as u32).to_be_bytes());
        out.extend_from_slice(value.as_bytes());
        out.resize(out.len() + ((4 - value.len() % 4) % 4), 0);
    }

    #[test]
    fn auth_frame_matches_reverse_engineered_layout() {
        let ticket = [0x5au8; 32];
        let frame = build_nc_auth_frame(&ticket, "202200000001").unwrap();

        assert_eq!(frame.len(), 64);
        assert_eq!(&frame[0..4], &CMD_NC_AUTH.to_be_bytes());
        assert_eq!(&frame[4..8], &56u32.to_be_bytes());
        assert_eq!(&frame[8..40], &ticket);
        assert_eq!(&frame[40..44], &12u32.to_be_bytes());
        assert_eq!(&frame[44..56], b"202200000001");
        assert_eq!(&frame[56..60], &1u32.to_be_bytes());
        assert_eq!(&frame[60..64], &0u32.to_be_bytes());
    }

    #[test]
    fn auth_frame_zero_pads_a_non_aligned_username() {
        let frame = build_nc_auth_frame(&[0u8; 32], "abcde").unwrap();
        assert_eq!(&frame[40..44], &5u32.to_be_bytes());
        assert_eq!(&frame[44..49], b"abcde");
        assert_eq!(&frame[49..52], &[0, 0, 0]);
        assert_eq!(&frame[52..56], &1u32.to_be_bytes());
    }

    #[test]
    fn nc_data_frame_contains_raw_ip_without_ethernet_header() {
        let ip_packet = [0x45, 0, 0, 20, 1, 2, 3, 4];
        let frame = build_nc_data_frame(&ip_packet).unwrap();
        assert_eq!(&frame[0..4], &CMD_NC_DATA.to_be_bytes());
        assert_eq!(&frame[4..8], &12u32.to_be_bytes());
        assert_eq!(&frame[8..12], &[0, 0, 0, 0]);
        assert_eq!(&frame[12..], &ip_packet);
        assert_eq!(parse_nc_data_frames(&frame).unwrap(), [ip_packet]);
    }

    #[test]
    fn parses_concatenated_nc_data_frames() {
        let first = build_nc_data_frame(&[0x45, 1, 2]).unwrap();
        let second = build_nc_data_frame(&[0x60, 3, 4, 5]).unwrap();
        let joined = [first, second].concat();
        assert_eq!(
            parse_nc_data_frames(&joined).unwrap(),
            [vec![0x45, 1, 2], vec![0x60, 3, 4, 5]]
        );
    }

    #[test]
    fn parses_successful_auth_reply() {
        let mut payload = 0u32.to_be_bytes().to_vec();
        push_string(&mut payload, "172.16.128.25");
        payload.extend_from_slice(&1u32.to_be_bytes());
        push_string(&mut payload, "172.16.0.10");
        payload.extend_from_slice(&0u32.to_be_bytes());
        payload.extend_from_slice(&1u32.to_be_bytes());
        push_string(&mut payload, "172.20.0.0");
        push_string(&mut payload, "255.255.0.0");
        payload.extend_from_slice(&1u32.to_be_bytes());
        payload.extend_from_slice(&0u32.to_be_bytes());
        push_string(&mut payload, "huse.cn");

        let mut frame = CMD_NC_AUTH.to_be_bytes().to_vec();
        frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        frame.extend_from_slice(&payload);

        let parsed = parse_nc_auth_reply(&frame).unwrap();
        assert_eq!(parsed.virtual_ip, "172.16.128.25");
        assert_eq!(parsed.dns_servers, ["172.16.0.10"]);
        assert!(parsed.wins_servers.is_empty());
        assert_eq!(parsed.profile_routes[0].address, "172.20.0.0");
        assert_eq!(parsed.profile_routes[0].netmask, "255.255.0.0");
        assert_eq!(parsed.route_monitor, 1);
        assert_eq!(parsed.route_generate, 0);
        assert_eq!(parsed.dns_suffix, "huse.cn");
    }

    #[test]
    fn rejects_malformed_ticket_and_reply_length() {
        assert!(decode_ticket_hex("abcd").is_err());
        let mut frame = CMD_NC_AUTH.to_be_bytes().to_vec();
        frame.extend_from_slice(&99u32.to_be_bytes());
        assert!(parse_nc_auth_reply(&frame).is_err());
    }
}
