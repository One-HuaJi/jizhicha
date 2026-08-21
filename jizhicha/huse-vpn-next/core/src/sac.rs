//! Native Gateway/SAC authentication.
//!
//! The installed Gateway client does not obtain its NC ticket from the PHP
//! portal.  It opens a fresh TLS connection for each SAC request and sends a
//! compact big-endian message.  The message body is a sequence of fixed
//! fields; strings are length-prefixed and padded to a four-byte boundary.

use crate::error::{HuseVpnError, Result};
use crate::nc::decode_ticket_hex;
use crate::tls::RawTlsClient;
use serde::Serialize;
use std::net::SocketAddr;
use std::time::Duration;

pub const MSG_SAC_GET_PORTAL: u32 = 0x0200_0002;
pub const MSG_SAC_LOGIN: u32 = 0x0200_0003;
pub const MSG_SAC_GET_USERDATA: u32 = 0x0200_0005;
pub const MSG_SAC_HEART_BEAT: u32 = 0x0200_000d;
const DEFAULT_AUTH_NAME: &str = "SAM-all";
const GET_USERDATA_ATTEMPTS: usize = 3;
const GET_USERDATA_TIMEOUT: Duration = Duration::from_secs(12);

#[derive(Debug, Clone, Serialize)]
pub struct SacAuthSource {
    pub auth_id: u32,
    pub auth_name: String,
    pub sub_auth_id: u32,
    pub sub_auth_name: String,
    pub sub_auth_type: u32,
}

#[derive(Debug, Clone, Serialize)]
pub struct SacLogin {
    pub ticket: [u8; 32],
    pub auth_id: u32,
    pub sub_auth_id: u32,
    pub auth_name: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct SacDiagnostics {
    pub gateway: String,
    pub get_portal_request_len: usize,
    pub get_portal_response_len: usize,
    pub get_userdata_request_len: Option<usize>,
    pub get_userdata_response_len: Option<usize>,
    pub get_userdata_result: Option<u32>,
    pub auth_source_count: usize,
    pub selected_auth_id: u32,
    pub selected_sub_auth_id: u32,
    pub selected_sub_auth_type: u32,
    pub login_request_len: usize,
    pub login_response_len: usize,
    pub login_result: Option<u32>,
    /// Structural information only. The SAC response contains reusable
    /// session material, so the raw response must never be exposed through
    /// diagnostics or the GUI.
    pub login_response_summary: String,
}

pub struct SacClient {
    address: SocketAddr,
}

impl SacClient {
    pub fn new(address: SocketAddr) -> Self {
        Self { address }
    }

    /// Enumerate the authentication sources advertised by this Gateway
    /// endpoint without submitting a username or password.
    pub async fn auth_sources(&self) -> Result<Vec<SacAuthSource>> {
        let (sources, _, _) = self.fetch_auth_sources().await?;
        Ok(sources)
    }

    pub async fn login(
        &self,
        username: &str,
        password: &str,
    ) -> Result<(SacLogin, SacDiagnostics)> {
        self.login_with_source(username, password, None).await
    }

    /// Authenticate with an explicitly selected authentication source.
    /// Pass `None` for `source_name` to auto-select `SAM-all` (default).
    pub async fn login_with_source(
        &self,
        username: &str,
        password: &str,
        source_name: Option<&str>,
    ) -> Result<(SacLogin, SacDiagnostics)> {
        if username.trim().is_empty() || password.is_empty() {
            return Err(HuseVpnError::Authentication(
                "student ID and password are required".into(),
            ));
        }

        let (sources, get_portal_len, get_reply_len) = self.fetch_auth_sources().await?;
        let lookup = source_name.unwrap_or(DEFAULT_AUTH_NAME);
        let selected = sources
            .iter()
            .find(|source| source.auth_name.eq_ignore_ascii_case(lookup))
            .or_else(|| {
                sources
                    .iter()
                    .find(|source| source.auth_name.eq_ignore_ascii_case(DEFAULT_AUTH_NAME))
            })
            .or_else(|| sources.first())
            .cloned()
            .ok_or_else(|| {
                HuseVpnError::Authentication(
                    "SAC returned no usable school authentication source".into(),
                )
            })?;

        let gateway_name = self.gateway_name();
        let login_request = build_login_request(
            username,
            password,
            selected.auth_id,
            selected.sub_auth_id,
            selected.sub_auth_type,
            &gateway_name,
        )?;
        let login_reply = self.exchange(&login_request).await?;
        let login_response_summary = summarize_login_response(&login_reply);
        let (ticket, result) = parse_login_reply(&login_reply)?;
        let diagnostics = SacDiagnostics {
            gateway: self.address.to_string(),
            get_portal_request_len: get_portal_len,
            get_portal_response_len: get_reply_len,
            get_userdata_request_len: None,
            get_userdata_response_len: None,
            get_userdata_result: None,
            auth_source_count: sources.len(),
            selected_auth_id: selected.auth_id,
            selected_sub_auth_id: selected.sub_auth_id,
            selected_sub_auth_type: selected.sub_auth_type,
            login_request_len: login_request.len(),
            login_response_len: login_reply.len(),
            login_result: Some(result),
            login_response_summary,
        };
        Ok((
            SacLogin {
                ticket,
                auth_id: selected.auth_id,
                sub_auth_id: selected.sub_auth_id,
                auth_name: selected.auth_name,
            },
            diagnostics,
        ))
    }

    async fn exchange(&self, request: &[u8]) -> Result<Vec<u8>> {
        let mut tls = RawTlsClient::connect(self.address).await?;
        tls.write(request).await?;
        tls.read_record().await
    }

    /// Put the authenticated SAC session online before opening the NC data
    /// channel. The installed client sends the ticket, the Windows platform
    /// code, the gateway host/port, and the local hardware-address list in a
    /// separate TLS connection. Without this step the NC auth exchange can
    /// still return a virtual IP while the Gateway never forwards packets.
    pub async fn get_userdata(
        &self,
        ticket: &[u8; 32],
        hardware_addresses: &[String],
    ) -> Result<(usize, usize, u32)> {
        let gateway_host = self.gateway_host();
        let request = build_get_userdata_request(
            ticket,
            10,
            &gateway_host,
            self.address.port(),
            hardware_addresses,
        )?;
        // LOGIN and GET_USERDATA use separate TLS connections. The school
        // Gateway occasionally accepts LOGIN but is not ready to answer the
        // first GET_USERDATA connection yet, especially immediately after an
        // earlier session was torn down. Reuse the accepted ticket and retry
        // only this idempotent session-setup request; repeating LOGIN here can
        // create another stale account session at the Gateway.
        let mut response = None;
        let mut last_error = None;
        for attempt in 1..=GET_USERDATA_ATTEMPTS {
            match tokio::time::timeout(GET_USERDATA_TIMEOUT, self.exchange(&request)).await {
                Ok(Ok(value)) => {
                    response = Some(value);
                    break;
                }
                Ok(Err(error)) => {
                    eprintln!(
                        "HUSE VPN GET_USERDATA transport failure: attempt={attempt}/{GET_USERDATA_ATTEMPTS}, error={error}"
                    );
                    last_error = Some(error);
                }
                Err(_) => {
                    eprintln!(
                        "HUSE VPN GET_USERDATA timeout: attempt={attempt}/{GET_USERDATA_ATTEMPTS}"
                    );
                    last_error = Some(HuseVpnError::Authentication(
                        "Gateway session setup timed out".into(),
                    ));
                }
            }

            if attempt < GET_USERDATA_ATTEMPTS {
                tokio::time::sleep(Duration::from_millis(800 * attempt as u64)).await;
            }
        }
        let response = match response {
            Some(value) => value,
            None => {
                return Err(last_error.unwrap_or_else(|| {
                    HuseVpnError::Authentication("Gateway session setup failed".into())
                }))
            }
        };
        if response.len() < 12 {
            return Err(HuseVpnError::Protocol(
                "Gateway session setup returned a short response".into(),
            ));
        }
        let response_type = u32::from_be_bytes(response[0..4].try_into().unwrap());
        let expected_type = MSG_SAC_GET_USERDATA | 0x8000_0000;
        if response_type != expected_type {
            return Err(HuseVpnError::Protocol(format!(
                "unexpected Gateway session response type 0x{response_type:08x}"
            )));
        }
        let result = u32::from_be_bytes(response[8..12].try_into().unwrap());
        eprintln!(
            "HUSE VPN GET_USERDATA response: request_len={}, response_len={}, result=0x{result:08x}",
            request.len(),
            response.len(),
        );
        Ok((request.len(), response.len(), result))
    }

    /// Send the official SAC heartbeat on a fresh TLS connection. The native
    /// client sends exactly the 32-byte ticket as the message body.
    pub async fn heartbeat(&self, ticket: &[u8; 32]) -> Result<()> {
        let mut writer = SacWriter::new(MSG_SAC_HEART_BEAT);
        writer.bytes(ticket);
        let request = writer.finish();
        let response = tokio::time::timeout(Duration::from_secs(10), self.exchange(&request))
            .await
            .map_err(|_| HuseVpnError::Authentication("Gateway heartbeat timed out".into()))??;
        if response.len() < 8 {
            return Err(HuseVpnError::Protocol(
                "Gateway heartbeat returned a short response".into(),
            ));
        }
        let response_type = u32::from_be_bytes(response[0..4].try_into().unwrap());
        let expected_type = MSG_SAC_HEART_BEAT | 0x8000_0000;
        if response_type != expected_type {
            return Err(HuseVpnError::Protocol(format!(
                "unexpected Gateway heartbeat response type 0x{response_type:08x}"
            )));
        }
        eprintln!(
            "HUSE VPN heartbeat accepted: request_len={}, response_len={}",
            request.len(),
            response.len()
        );
        Ok(())
    }

    async fn fetch_auth_sources(&self) -> Result<(Vec<SacAuthSource>, usize, usize)> {
        // The Gateway client identifies the target VPN gateway in this
        // request.  This is deliberately not the client OS string used by
        // the later LOGIN packet.
        let gateway_name = self.gateway_name();
        let get_portal = build_get_portal_request(&gateway_name)?;
        let get_reply = self.exchange(&get_portal).await?;
        let sources = parse_get_portal_reply(&get_reply)?;
        Ok((sources, get_portal.len(), get_reply.len()))
    }

    fn gateway_name(&self) -> String {
        format!("{}:{}", self.address.ip(), self.address.port())
    }

    fn gateway_host(&self) -> String {
        self.address.ip().to_string()
    }
}

/// Notify the Gateway's session service after SAC has issued an NC ticket.
/// The native client performs this request between NC authentication and
/// virtual-adapter setup. The ticket is kept in memory and is never included
/// in an error string or diagnostic payload.
pub async fn notify_safeupdate(address: SocketAddr, ticket: &[u8; 32]) -> Result<()> {
    let request = format!(
        "GET /extra/safeupdate.php?ticket={} HTTP/1.1\r\nHost: {}\r\nUser-Agent: HUSE-VPN-Next/0.1\r\nAccept: */*\r\nConnection: close\r\n\r\n",
        hex::encode(ticket),
        address,
    );
    let response = tokio::time::timeout(Duration::from_secs(10), async {
        // Reuse the Gateway-compatible TLS implementation so this auxiliary
        // HTTPS request is protected by the same SPKI pin as SAC and NC.
        let mut tls = RawTlsClient::connect(address).await?;
        tls.write(request.as_bytes()).await?;
        let mut response = Vec::new();
        while !response.windows(4).any(|window| window == b"\r\n\r\n") {
            let record = tls.read_record().await?;
            response.extend_from_slice(&record);
            if response.len() > 64 * 1024 {
                return Err(HuseVpnError::Protocol(
                    "Gateway session notification headers were too large".into(),
                ));
            }
        }
        Ok::<_, HuseVpnError>(response)
    })
    .await
    .map_err(|_| HuseVpnError::Authentication("Gateway session notification timed out".into()))??;
    let status = String::from_utf8_lossy(&response)
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|value| value.parse::<u16>().ok())
        .ok_or_else(|| {
            HuseVpnError::Protocol("Gateway session notification returned invalid HTTP".into())
        })?;
    if !(200..400).contains(&status) {
        return Err(HuseVpnError::Authentication(format!(
            "Gateway session notification returned HTTP {status}"
        )));
    }
    eprintln!("HUSE VPN session notification response: HTTP {}", status);
    Ok(())
}

/// Build the exact SAC source-enumeration request used by Gateway.
///
/// `GET_PORTAL` has a distinct body from LOGIN: a length/padded gateway
/// `host:port` string followed by the big-endian flag `1`.  Supplying the
/// LOGIN platform string here is accepted by some gateways but does not
/// faithfully identify the selected gateway/authentication source.
fn build_get_portal_request(gateway_name: &str) -> Result<Vec<u8>> {
    let mut writer = SacWriter::new(MSG_SAC_GET_PORTAL);
    writer.string(gateway_name)?;
    writer.u32(1);
    Ok(writer.finish())
}

/// Build the ordinary password LOGIN request emitted by the installed
/// Gateway client's main program (its `SubAuthType == 1` branch).
///
/// This is intentionally distinct from the older `gwuimng.dll` serializer:
/// the working client identifies the selected authentication source with
/// three numeric fields, then sends the username/password and a small set of
/// empty optional fields.  In particular, it does not put the visible
/// `SAM-all` label or `Windows 7` into this request body.
fn build_login_request(
    username: &str,
    password: &str,
    auth_id: u32,
    sub_auth_id: u32,
    sub_auth_type: u32,
    gateway_name: &str,
) -> Result<Vec<u8>> {
    let mut writer = SacWriter::new(MSG_SAC_LOGIN);
    writer.u32(auth_id);
    writer.u32(sub_auth_id);
    writer.u32(sub_auth_type);
    writer.u32(2);
    writer.string(username)?;
    writer.string(password)?;
    // Four optional client-side strings are empty in the normal
    // student-password flow captured from the installed client.
    writer.string("")?;
    writer.string("")?;
    writer.string("")?;
    writer.u32(1);
    // The client flag is 0 for the ordinary non-token path.  The official
    // program uses 4 only when an optional runtime client object exists.
    writer.u32(0);
    writer.string(gateway_name)?;
    writer.string("APP")?;
    writer.string("")?;
    writer.u32(0);
    writer.bytes(&[0; 32]);
    Ok(writer.finish())
}

/// Build the official `MSG_SAC_GET_USERDATA` body.
///
/// The native client uses the bare gateway host here (the port is a separate
/// u32), unlike GET_PORTAL/LOGIN which use a `host:port` string. The first
/// list contains lower-case, hyphen-separated MAC addresses; the second list
/// is the local-address list and is empty for the current Gateway client flow.
fn build_get_userdata_request(
    ticket: &[u8; 32],
    platform_code: u32,
    gateway_host: &str,
    gateway_port: u16,
    hardware_addresses: &[String],
) -> Result<Vec<u8>> {
    let mut writer = SacWriter::new(MSG_SAC_GET_USERDATA);
    writer.bytes(ticket);
    writer.u32(platform_code);
    writer.string(gateway_host)?;
    writer.u32(u32::from(gateway_port));
    writer.list_strings(hardware_addresses)?;
    writer.u32(0);
    Ok(writer.finish())
}

fn parse_get_portal_reply(frame: &[u8]) -> Result<Vec<SacAuthSource>> {
    let mut reader = SacReader::new(frame, MSG_SAC_GET_PORTAL | 0x8000_0000)?;
    let result = reader.u32()?;
    if result != 0 {
        return Err(HuseVpnError::Authentication(format!(
            "SAC gateway rejected authentication-source enumeration (0x{result:08x})"
        )));
    }
    let count = reader.count()?;
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        let auth_id = reader.u32()?;
        let auth_name = reader.string()?;
        let sub_auth_id = reader.u32()?;
        let sub_auth_name = reader.string()?;
        let sub_auth_type = reader.u32()?;
        let _qr_flag = reader.u32()?;
        let _push_flag = reader.u32()?;
        let _otp_type = reader.u32()?;
        out.push(SacAuthSource {
            auth_id,
            auth_name,
            sub_auth_id,
            sub_auth_name,
            sub_auth_type,
        });
    }
    Ok(out)
}

fn parse_login_reply(frame: &[u8]) -> Result<([u8; 32], u32)> {
    let mut reader = SacReader::new(frame, MSG_SAC_LOGIN | 0x8000_0000)?;
    let result = reader.u32()?;

    if result != 0 {
        let gateway_message = find_gateway_message(&mut reader);
        let suffix = gateway_message
            .map(|message| format!("; gateway_message={message}"))
            .unwrap_or_default();
        return Err(HuseVpnError::Authentication(format!(
            "SAC LOGIN rejected (0x{result:08x}){suffix}"
        )));
    }

    // The installed client consumes the next typed 32-byte value and
    // forwards it to NC_START as the ticket. The old fallback copied only
    // 24 bytes and appended zeroes, which made the NC request look valid
    // while guaranteeing ticket rejection.
    let ticket = parse_ticket_field(&mut reader)?;
    Ok((ticket, result))
}

fn parse_ticket_field(reader: &mut SacReader<'_>) -> Result<[u8; 32]> {
    let start = reader.offset;

    // Keep compatibility with a gateway variant that serializes the same
    // ticket as a length-prefixed 64-character hex string. This branch is
    // deliberately strict and never truncates or pads.
    if reader.data.len().saturating_sub(start) >= 4 {
        let len = u32::from_be_bytes(reader.data[start..start + 4].try_into().unwrap()) as usize;
        let padded = (len + 3) & !3;
        if len == 64
            && start + 4 + padded <= reader.data.len()
            && reader.data[start + 4..start + 4 + len]
                .iter()
                .all(|byte| byte.is_ascii_hexdigit())
            && reader.data[start + 4 + len..start + 4 + padded]
                .iter()
                .all(|byte| *byte == 0)
        {
            let text =
                std::str::from_utf8(&reader.data[start + 4..start + 4 + len]).map_err(|error| {
                    HuseVpnError::Protocol(format!("SAC ticket is not UTF-8: {error}"))
                })?;
            reader.offset = start + 4 + padded;
            return decode_ticket_hex(text);
        }
    }

    if reader.data.len().saturating_sub(reader.offset) < 32 {
        return Err(HuseVpnError::Protocol(format!(
            "SAC LOGIN succeeded but omitted the official 32-byte NC ticket field (response_len={})",
            reader.data.len() + 8
        )));
    }

    let bytes = reader.take(32)?;
    let mut ticket = [0u8; 32];
    ticket.copy_from_slice(bytes);
    Ok(ticket)
}

fn find_gateway_message(reader: &mut SacReader<'_>) -> Option<String> {
    let mut best: Option<String> = None;
    while reader.offset + 4 <= reader.data.len() {
        let here = reader.offset;
        let length = u32::from_be_bytes(reader.data[here..here + 4].try_into().unwrap()) as usize;
        let padded = (length + 3) & !3;
        if length > 0 && length <= 1024 && here + 4 + padded <= reader.data.len() {
            let candidate = &reader.data[here + 4..here + 4 + length];
            if candidate
                .iter()
                .all(|byte| byte.is_ascii_graphic() || *byte == b' ')
                && best.as_ref().map_or(true, |current| length > current.len())
            {
                best = String::from_utf8(candidate.to_vec()).ok();
            }
            reader.offset = here + 4 + padded;
        } else {
            reader.offset = here + 4;
        }
    }
    best
}

fn summarize_login_response(frame: &[u8]) -> String {
    format!(
        "response_len={} bytes; body_len={} bytes; ticket_field=32 bytes",
        frame.len(),
        frame.len().saturating_sub(8)
    )
}

struct SacWriter {
    data: Vec<u8>,
}

impl SacWriter {
    fn new(message_type: u32) -> Self {
        let mut data = Vec::with_capacity(256);
        data.extend_from_slice(&message_type.to_be_bytes());
        data.extend_from_slice(&0u32.to_be_bytes());
        Self { data }
    }

    fn u32(&mut self, value: u32) {
        self.data.extend_from_slice(&value.to_be_bytes());
    }

    fn bytes(&mut self, value: &[u8]) {
        self.data.extend_from_slice(value);
    }

    fn list_strings(&mut self, values: &[String]) -> Result<()> {
        let count = u32::try_from(values.len())
            .map_err(|_| HuseVpnError::Protocol("SAC list is too long".into()))?;
        self.u32(count);
        for value in values {
            self.string(value)?;
        }
        Ok(())
    }

    fn string(&mut self, value: &str) -> Result<()> {
        let bytes = value.as_bytes();
        let len = u32::try_from(bytes.len())
            .map_err(|_| HuseVpnError::Protocol("SAC string is too long".into()))?;
        self.u32(len);
        self.data.extend_from_slice(bytes);
        let padded = (bytes.len() + 3) & !3;
        self.data
            .resize(self.data.len() + (padded - bytes.len()), 0);
        Ok(())
    }

    fn finish(mut self) -> Vec<u8> {
        // The outer official send wrapper finalizes this field immediately
        // before writing to TLS.  Our direct client has no such wrapper, so
        // it must place the big-endian payload length here itself.
        let payload_len = (self.data.len() - 8) as u32;
        self.data[4..8].copy_from_slice(&payload_len.to_be_bytes());
        self.data
    }
}

struct SacReader<'a> {
    data: &'a [u8],
    offset: usize,
}

impl<'a> SacReader<'a> {
    fn new(frame: &'a [u8], expected_type: u32) -> Result<Self> {
        if frame.len() < 8 {
            return Err(HuseVpnError::Protocol(
                "SAC response is shorter than its header".into(),
            ));
        }
        let message_type = u32::from_be_bytes(frame[0..4].try_into().unwrap());
        if message_type != expected_type {
            return Err(HuseVpnError::Protocol(format!(
                "unexpected SAC response type 0x{message_type:08x}"
            )));
        }
        let declared = u32::from_be_bytes(frame[4..8].try_into().unwrap()) as usize;
        if declared != frame.len() - 8 {
            return Err(HuseVpnError::Protocol(
                "SAC response length mismatch".into(),
            ));
        }
        Ok(Self {
            data: &frame[8..],
            offset: 0,
        })
    }

    fn take(&mut self, len: usize) -> Result<&'a [u8]> {
        let end = self
            .offset
            .checked_add(len)
            .ok_or_else(|| HuseVpnError::Protocol("SAC offset overflow".into()))?;
        if end > self.data.len() {
            return Err(HuseVpnError::Protocol(
                "SAC response ended inside a field".into(),
            ));
        }
        let value = &self.data[self.offset..end];
        self.offset = end;
        Ok(value)
    }

    fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_be_bytes(self.take(4)?.try_into().unwrap()))
    }

    fn count(&mut self) -> Result<usize> {
        let count = self.u32()? as usize;
        if count > 64 || count.saturating_mul(20) > self.data.len().saturating_sub(self.offset) {
            return Err(HuseVpnError::Protocol("SAC list count is invalid".into()));
        }
        Ok(count)
    }

    fn string(&mut self) -> Result<String> {
        let len = self.u32()? as usize;
        let padded = (len + 3) & !3;
        let bytes = self.take(padded)?;
        if bytes[len..].iter().any(|byte| *byte != 0) {
            return Err(HuseVpnError::Protocol(
                "SAC string padding is not zero".into(),
            ));
        }
        String::from_utf8(bytes[..len].to_vec())
            .map_err(|error| HuseVpnError::Protocol(format!("SAC string is not UTF-8: {error}")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_lengths_and_header_are_stable() {
        let get = build_get_portal_request("222.243.204.22:6443").unwrap();
        assert_eq!(get.len(), 36);
        assert_eq!(&get[..8], &[0x02, 0, 0, 2, 0, 0, 0, 28]);
        assert_eq!(u32::from_be_bytes(get[8..12].try_into().unwrap()), 19);
        assert_eq!(&get[12..31], b"222.243.204.22:6443");
        assert_eq!(u32::from_be_bytes(get[32..36].try_into().unwrap()), 1);
        let login =
            build_login_request("202400000001", "pw", 3, 3, 1, "222.243.204.22:6443").unwrap();
        assert_eq!(&login[..4], &MSG_SAC_LOGIN.to_be_bytes());
        assert_eq!(login.len(), 140);
        assert_eq!(u32::from_be_bytes(login[4..8].try_into().unwrap()), 132);
        assert_eq!(
            &login[8..24],
            &[0, 0, 0, 3, 0, 0, 0, 3, 0, 0, 0, 1, 0, 0, 0, 2]
        );
        let long_password =
            build_login_request("202400000001", "password", 3, 3, 1, "222.243.204.22:6443")
                .unwrap();
        assert_eq!(
            u32::from_be_bytes(long_password[4..8].try_into().unwrap()),
            136
        );
        assert_eq!(
            u32::from_be_bytes(login[4..8].try_into().unwrap()) as usize,
            login.len() - 8
        );

        let macs = vec!["10-7c-61-b7-9b-ea".to_string()];
        let userdata =
            build_get_userdata_request(&[0x11; 32], 10, "222.243.204.22", 6443, &macs).unwrap();
        assert_eq!(userdata.len(), 100);
        assert_eq!(
            u32::from_be_bytes(userdata[..4].try_into().unwrap()),
            MSG_SAC_GET_USERDATA
        );
        assert_eq!(u32::from_be_bytes(userdata[4..8].try_into().unwrap()), 92);
        assert_eq!(&userdata[8..40], &[0x11; 32]);
        assert_eq!(u32::from_be_bytes(userdata[40..44].try_into().unwrap()), 10);
        assert_eq!(
            u32::from_be_bytes(userdata[64..68].try_into().unwrap()),
            6443
        );
        assert_eq!(u32::from_be_bytes(userdata[68..72].try_into().unwrap()), 1);
        assert_eq!(u32::from_be_bytes(userdata[72..76].try_into().unwrap()), 17);
        assert_eq!(&userdata[76..93], b"10-7c-61-b7-9b-ea");
        assert_eq!(u32::from_be_bytes(userdata[96..100].try_into().unwrap()), 0);

        let heartbeat = {
            let mut writer = SacWriter::new(MSG_SAC_HEART_BEAT);
            writer.bytes(&[0x22; 32]);
            writer.finish()
        };
        assert_eq!(heartbeat.len(), 40);
        assert_eq!(
            u32::from_be_bytes(heartbeat[..4].try_into().unwrap()),
            MSG_SAC_HEART_BEAT
        );
        assert_eq!(u32::from_be_bytes(heartbeat[4..8].try_into().unwrap()), 32);
    }

    #[test]
    fn parses_source_list_and_binary_login_ticket() {
        let mut body = 0u32.to_be_bytes().to_vec();
        body.extend_from_slice(&1u32.to_be_bytes());
        body.extend_from_slice(&3u32.to_be_bytes());
        push_string(&mut body, "SAM-all");
        body.extend_from_slice(&3u32.to_be_bytes());
        push_string(&mut body, "SAM-all");
        body.extend_from_slice(&1u32.to_be_bytes());
        body.extend_from_slice(&[0u8; 12]);

        let mut frame = (MSG_SAC_GET_PORTAL | 0x8000_0000).to_be_bytes().to_vec();
        frame.extend_from_slice(&(body.len() as u32).to_be_bytes());
        frame.extend_from_slice(&body);
        let sources = parse_get_portal_reply(&frame).unwrap();
        assert_eq!(sources[0].auth_id, 3);
        assert_eq!(sources[0].auth_name, "SAM-all");

        let ticket = [0x5au8; 32];
        let mut login_body = 0u32.to_be_bytes().to_vec();
        login_body.extend_from_slice(&ticket);
        let mut login_frame = (MSG_SAC_LOGIN | 0x8000_0000).to_be_bytes().to_vec();
        login_frame.extend_from_slice(&(login_body.len() as u32).to_be_bytes());
        login_frame.extend_from_slice(&login_body);
        let (parsed, result) = parse_login_reply(&login_frame).unwrap();
        assert_eq!(result, 0);
        assert_eq!(parsed, ticket);
    }

    #[test]
    fn parses_length_prefixed_hex_login_ticket() {
        let ticket_text = "0123456789abcdef".repeat(4);
        let mut login_body = 0u32.to_be_bytes().to_vec();
        push_string(&mut login_body, &ticket_text);
        let mut login_frame = (MSG_SAC_LOGIN | 0x8000_0000).to_be_bytes().to_vec();
        login_frame.extend_from_slice(&(login_body.len() as u32).to_be_bytes());
        login_frame.extend_from_slice(&login_body);
        let (ticket, result) = parse_login_reply(&login_frame).unwrap();
        assert_eq!(result, 0);
        assert_eq!(hex::encode(ticket), ticket_text);
    }

    #[test]
    fn rejects_success_without_a_complete_ticket() {
        let mut login_body = 0u32.to_be_bytes().to_vec();
        login_body.extend_from_slice(&[0u8; 24]);
        let mut login_frame = (MSG_SAC_LOGIN | 0x8000_0000).to_be_bytes().to_vec();
        login_frame.extend_from_slice(&(login_body.len() as u32).to_be_bytes());
        login_frame.extend_from_slice(&login_body);
        assert!(parse_login_reply(&login_frame).is_err());
    }

    fn push_string(out: &mut Vec<u8>, value: &str) {
        out.extend_from_slice(&(value.len() as u32).to_be_bytes());
        out.extend_from_slice(value.as_bytes());
        out.resize(out.len() + ((4 - value.len() % 4) % 4), 0);
    }
}
