//! TLS 1.2 + RSA-AES128-CBC-SHA + EMS（精确匹配 GWSetup.exe ClientHello）
use crate::error::{HuseVpnError, Result};
use num_bigint::BigUint;
use rsa::{pkcs1::DecodeRsaPublicKey, traits::PublicKeyParts, RsaPublicKey};
use sha1::Sha1;
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::TcpStream;
use x509_cert::der::{Decode, Encode};

const V12: [u8; 2] = [0x03, 0x03];
const MAX_SERVER_HANDSHAKE_BYTES: usize = 1024 * 1024;

/// SHA-256 pins of the DER-encoded SubjectPublicKeyInfo accepted for the
/// school's fixed Gateway endpoint. The current key was independently read
/// from `222.243.204.22:6443` on 2026-08-21. Keep the previous pin beside a
/// replacement during a planned school-side key rotation, then remove it
/// after the transition window.
const GATEWAY_SPKI_SHA256_PINS: [[u8; 32]; 1] = [[
    0x3e, 0xd8, 0x79, 0xfb, 0x63, 0x68, 0x6c, 0x3d, 0x14, 0xae, 0x54, 0x97, 0xc7, 0x0d, 0x68, 0x51,
    0x97, 0x93, 0x44, 0xbd, 0xe4, 0x2b, 0x5b, 0x67, 0xa1, 0x16, 0x32, 0x78, 0xf8, 0xdf, 0x40, 0x13,
]];

fn verify_gateway_spki_pin(spki_der: &[u8]) -> Result<()> {
    let digest = Sha256::digest(spki_der);
    let mut actual = [0u8; 32];
    actual.copy_from_slice(&digest);
    if GATEWAY_SPKI_SHA256_PINS.contains(&actual) {
        return Ok(());
    }
    Err(HuseVpnError::Tls(format!(
        "Gateway certificate SPKI pin mismatch (received {})",
        hex::encode(actual)
    )))
}

fn p_sha256(secret: &[u8], seed: &[u8], len: usize) -> Vec<u8> {
    let mut out = Vec::new();
    let mut a = seed.to_vec();
    while out.len() < len {
        a = hmac_sha256(secret, &a).to_vec();
        let mut mi = a.clone();
        mi.extend_from_slice(seed);
        out.extend_from_slice(&hmac_sha256(secret, &mi));
    }
    out.truncate(len);
    out
}
fn hmac_sha256(key: &[u8], data: &[u8]) -> [u8; 32] {
    let mut blk = [0u8; 64];
    if key.len() <= 64 {
        blk[..key.len()].copy_from_slice(key);
    } else {
        blk[..32].copy_from_slice(&Sha256::digest(key));
    }
    let mut ok = [0x5cu8; 64];
    let mut ik = [0x36u8; 64];
    for i in 0..64 {
        ok[i] ^= blk[i];
        ik[i] ^= blk[i];
    }
    let mut ii = ik.to_vec();
    ii.extend_from_slice(data);
    let i = Sha256::digest(&ii);
    let mut oo = ok.to_vec();
    oo.extend_from_slice(&i);
    let o = Sha256::digest(&oo);
    let mut r = [0u8; 32];
    r.copy_from_slice(&o);
    r
}
fn hmac_sha1(key: &[u8], data: &[u8]) -> [u8; 20] {
    let mut blk = [0u8; 64];
    if key.len() <= 64 {
        blk[..key.len()].copy_from_slice(key);
    } else {
        blk[..20].copy_from_slice(&Sha1::digest(key));
    }
    let mut ok = [0x5cu8; 64];
    let mut ik = [0x36u8; 64];
    for i in 0..64 {
        ok[i] ^= blk[i];
        ik[i] ^= blk[i];
    }
    let mut ii = ik.to_vec();
    ii.extend_from_slice(data);
    let i = Sha1::digest(&ii);
    let mut oo = ok.to_vec();
    oo.extend_from_slice(&i);
    let o = Sha1::digest(&oo);
    let mut r = [0u8; 20];
    r.copy_from_slice(&o);
    r
}

fn derive_keys(
    pre: &[u8; 48],
    cr: &[u8; 32],
    sr: &[u8; 32],
    ems: bool,
    hs_bytes: &[u8],
) -> ([u8; 16], [u8; 16], [u8; 20], [u8; 20], [u8; 48]) {
    let ms = if ems {
        let h = Sha256::digest(hs_bytes);
        let mut seed = b"extended master secret".to_vec();
        seed.extend_from_slice(&h);
        p_sha256(pre, &seed, 48)
    } else {
        let mut seed = b"master secret".to_vec();
        seed.extend_from_slice(cr);
        seed.extend_from_slice(sr);
        p_sha256(pre, &seed, 48)
    };
    let mut s2 = b"key expansion".to_vec();
    s2.extend_from_slice(sr);
    s2.extend_from_slice(cr);
    let kb = p_sha256(&ms, &s2, 72);
    // RFC 5246 §6.3：client/server MAC secret 在前，随后才是写入密钥。
    let mut ck = [0u8; 16];
    let mut sk = [0u8; 16];
    let mut cm = [0u8; 20];
    let mut sm = [0u8; 20];
    let mut p = 0;
    cm.copy_from_slice(&kb[p..p + 20]);
    p += 20;
    sm.copy_from_slice(&kb[p..p + 20]);
    p += 20;
    ck.copy_from_slice(&kb[p..p + 16]);
    p += 16;
    sk.copy_from_slice(&kb[p..p + 16]);
    let mut ms_arr = [0u8; 48];
    ms_arr.copy_from_slice(&ms);
    (ck, sk, cm, sm, ms_arr)
}

pub struct RawTlsClient {
    stream: TcpStream,
    client_key: [u8; 16],
    client_mac: [u8; 20],
    server_key: [u8; 16],
    server_mac: [u8; 20],
    send_seq: u64,
    recv_seq: u64,
}

pub struct RawTlsReader {
    stream: OwnedReadHalf,
    server_key: [u8; 16],
    server_mac: [u8; 20],
    recv_seq: u64,
}

pub struct RawTlsWriter {
    stream: OwnedWriteHalf,
    client_key: [u8; 16],
    client_mac: [u8; 20],
    send_seq: u64,
}

impl RawTlsClient {
    pub async fn connect(addr: std::net::SocketAddr) -> Result<Self> {
        let mut s = TcpStream::connect(addr)
            .await
            .map_err(|e| HuseVpnError::Tls(format!("TCP {e}")))?;
        let (rec, cr, ch) = build_ch();
        let mut hs = ch.clone();
        s.write_all(&rec)
            .await
            .map_err(|e| HuseVpnError::Tls(format!("CH {e}")))?;

        let (sr, rsa, sh, ems) = read_sh(&mut s).await?;
        hs.extend_from_slice(&sh);

        // TLS_RSA_WITH_AES_128_CBC_SHA: 48-byte pre-master secret encrypted with
        // the certificate's RSA key. The pre-master itself, not its PKCS#1 padding,
        // is the input to the TLS PRF.
        let mut pre48 = [0u8; 48];
        pre48[..2].copy_from_slice(&V12);
        rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut pre48[2..]);
        let enc = rsa_pkcs1_encrypt_manual(&rsa, &pre48);
        let mut cke_body = Vec::with_capacity(enc.len() + 2);
        cke_body.extend_from_slice(&(enc.len() as u16).to_be_bytes());
        cke_body.extend_from_slice(&enc);
        let cke = bs(0x10, &cke_body);
        hs.extend_from_slice(&cke);
        wr(&mut s, 0x16, &cke).await?;

        let (client_key, server_key, client_mac, server_mac, master_secret) =
            derive_keys(&pre48, &cr, &sr, ems, &hs);
        let client_finished = finished_verify_data(&master_secret, b"client finished", &hs);
        let client_finished_message = bs(0x14, &client_finished);
        let client_finished_record =
            encrypt_record(0x16, &client_key, &client_mac, 0, &client_finished_message);
        wr(&mut s, 0x14, &[0x01]).await?;
        s.write_all(&client_finished_record)
            .await
            .map_err(|e| HuseVpnError::Tls(format!("client Finished: {e}")))?;
        hs.extend_from_slice(&client_finished_message);

        let (ccs_type, ccs_body) = read_tls_record(&mut s).await?;
        if ccs_type != 0x14 || ccs_body != [0x01] {
            return Err(HuseVpnError::Tls(format!(
                "expected server CCS, got type=0x{ccs_type:02x} body={}",
                hex::encode(ccs_body)
            )));
        }
        let (server_type, server_body) = read_tls_record(&mut s).await?;
        if server_type == 0x15 {
            return Err(HuseVpnError::Tls(format!(
                "server alert after Finished: {}",
                hex::encode(server_body)
            )));
        }
        let server_finished =
            decrypt_record(server_type, &server_body, &server_key, &server_mac, 0)?;
        let expected = bs(
            0x14,
            &finished_verify_data(&master_secret, b"server finished", &hs),
        );
        if server_type != 0x16 || server_finished != expected {
            return Err(HuseVpnError::Tls(
                "server Finished verification failed".into(),
            ));
        }
        Ok(RawTlsClient {
            stream: s,
            client_key,
            client_mac,
            server_key,
            server_mac,
            // TLS Finished is the first protected client record and uses seq=0.
            // Application data therefore begins at seq=1.
            send_seq: 1,
            recv_seq: 1,
        })
    }

    async fn send(&mut self, ct: u8, pl: &[u8]) -> Result<()> {
        let record = encrypt_record(ct, &self.client_key, &self.client_mac, self.send_seq, pl);
        self.send_seq += 1;
        self.stream
            .write_all(&record)
            .await
            .map_err(|e| HuseVpnError::Tls(format!("s {e}")))?;
        Ok(())
    }

    pub async fn write(&mut self, data: &[u8]) -> Result<()> {
        self.send(0x17, data).await
    }
    pub async fn read_record(&mut self) -> Result<Vec<u8>> {
        let (content_type, body) = read_tls_record(&mut self.stream).await?;
        let plaintext = decrypt_record(
            content_type,
            &body,
            &self.server_key,
            &self.server_mac,
            self.recv_seq,
        )?;
        self.recv_seq += 1;
        if content_type == 0x15 {
            return Err(HuseVpnError::Tls(format!(
                "server alert: {}",
                hex::encode(plaintext)
            )));
        }
        Ok(plaintext)
    }

    /// Split an authenticated connection into independently usable read and
    /// write halves. Each half retains its own TLS record sequence number.
    pub fn into_split(self) -> (RawTlsReader, RawTlsWriter) {
        let (read_half, write_half) = self.stream.into_split();
        (
            RawTlsReader {
                stream: read_half,
                server_key: self.server_key,
                server_mac: self.server_mac,
                recv_seq: self.recv_seq,
            },
            RawTlsWriter {
                stream: write_half,
                client_key: self.client_key,
                client_mac: self.client_mac,
                send_seq: self.send_seq,
            },
        )
    }
}

impl RawTlsReader {
    pub async fn read_record(&mut self) -> Result<Vec<u8>> {
        let (content_type, body) = read_tls_record(&mut self.stream).await?;
        eprintln!(
            "HUSE VPN downlink TLS record: type=0x{content_type:02x}, encrypted_len={}",
            body.len()
        );
        let plaintext = decrypt_record(
            content_type,
            &body,
            &self.server_key,
            &self.server_mac,
            self.recv_seq,
        )?;
        self.recv_seq += 1;
        if content_type == 0x15 {
            return Err(HuseVpnError::Tls(format!(
                "server alert: {}",
                hex::encode(plaintext)
            )));
        }
        Ok(plaintext)
    }
}

impl RawTlsWriter {
    pub async fn write(&mut self, data: &[u8]) -> Result<()> {
        let record = encrypt_record(
            0x17,
            &self.client_key,
            &self.client_mac,
            self.send_seq,
            data,
        );
        self.send_seq += 1;
        self.stream
            .write_all(&record)
            .await
            .map_err(|e| HuseVpnError::Tls(format!("application data write: {e}")))?;
        Ok(())
    }
}

fn finished_verify_data(master_secret: &[u8; 48], label: &[u8], transcript: &[u8]) -> [u8; 12] {
    let handshake_hash = Sha256::digest(transcript);
    let mut seed = label.to_vec();
    seed.extend_from_slice(&handshake_hash);
    let verify_data = p_sha256(master_secret, &seed, 12);
    verify_data
        .try_into()
        .expect("TLS Finished verify_data length")
}

fn encrypt_record(
    content_type: u8,
    key: &[u8; 16],
    mac_secret: &[u8; 20],
    sequence: u64,
    plaintext: &[u8],
) -> Vec<u8> {
    let mac = record_mac(mac_secret, sequence, content_type, plaintext);
    let mut fragment = plaintext.to_vec();
    fragment.extend_from_slice(&mac);
    let mut iv = [0u8; 16];
    rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut iv);
    let encrypted = AesCbc::new(key).enc(&iv, &fragment);
    let mut record = vec![content_type];
    record.extend_from_slice(&V12);
    record.extend_from_slice(&(encrypted.len() as u16).to_be_bytes());
    record.extend_from_slice(&encrypted);
    record
}

fn decrypt_record(
    content_type: u8,
    body: &[u8],
    key: &[u8; 16],
    mac_secret: &[u8; 20],
    sequence: u64,
) -> Result<Vec<u8>> {
    if body.len() < 32 || (body.len() - 16) % 16 != 0 {
        return Err(HuseVpnError::Tls(
            "invalid AES-CBC TLS record length".into(),
        ));
    }
    let iv: [u8; 16] = body[..16].try_into().expect("explicit IV length");
    let decrypted = AesCbc::new(key).dec(&iv, &body[16..]);
    if decrypted.len() < 20 {
        return Err(HuseVpnError::Tls(
            "TLS record shorter than HMAC-SHA1".into(),
        ));
    }
    let split = decrypted.len() - 20;
    let (plaintext, received_mac) = decrypted.split_at(split);
    let expected_mac = record_mac(mac_secret, sequence, content_type, plaintext);
    if received_mac != expected_mac {
        return Err(HuseVpnError::Tls(
            "TLS record MAC verification failed".into(),
        ));
    }
    Ok(plaintext.to_vec())
}

fn record_mac(secret: &[u8; 20], sequence: u64, content_type: u8, plaintext: &[u8]) -> [u8; 20] {
    let mut mac_input = sequence.to_be_bytes().to_vec();
    mac_input.push(content_type);
    mac_input.extend_from_slice(&V12);
    mac_input.extend_from_slice(&(plaintext.len() as u16).to_be_bytes());
    mac_input.extend_from_slice(plaintext);
    hmac_sha1(secret, &mac_input)
}

async fn read_tls_record<R>(stream: &mut R) -> Result<(u8, Vec<u8>)>
where
    R: tokio::io::AsyncRead + Unpin,
{
    let mut header = [0u8; 5];
    stream
        .read_exact(&mut header)
        .await
        .map_err(|e| HuseVpnError::Tls(format!("read TLS header: {e}")))?;
    if header[1..3] != V12 {
        return Err(HuseVpnError::Tls(format!(
            "unexpected TLS record version {:02x}{:02x}",
            header[1], header[2]
        )));
    }
    let len = u16::from_be_bytes([header[3], header[4]]) as usize;
    let mut body = vec![0u8; len];
    stream
        .read_exact(&mut body)
        .await
        .map_err(|e| HuseVpnError::Tls(format!("read TLS record body: {e}")))?;
    Ok((header[0], body))
}

// === ClientHello (exact GWSetup.exe match) ===
fn build_ch() -> (Vec<u8>, [u8; 32], Vec<u8>) {
    let mut b = Vec::new();
    b.extend_from_slice(&V12);
    let mut r = [0u8; 32];
    rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut r);
    r[..2].copy_from_slice(&V12);
    b.extend_from_slice(&r);
    b.push(0x00);
    let cs: [u16; 18] = [
        0xC02C, 0xC02B, 0xC030, 0xC02F, 0xC024, 0xC023, 0xC028, 0xC027, 0xC00A, 0xC009, 0xC014,
        0xC013, 0x009D, 0x009C, 0x003D, 0x003C, 0x0035, 0x002F,
    ];
    b.extend_from_slice(&((cs.len() * 2) as u16).to_be_bytes());
    for c in cs {
        b.extend_from_slice(&c.to_be_bytes());
    }
    b.push(1);
    b.push(0x00);
    let mut ex = Vec::new();
    ex.extend_from_slice(&0x000a_u16.to_be_bytes());
    ex.extend_from_slice(&8u16.to_be_bytes());
    ex.extend_from_slice(&[0, 6, 0, 0x1d, 0, 0x17, 0, 0x18]);
    ex.extend_from_slice(&0x000b_u16.to_be_bytes());
    ex.extend_from_slice(&2u16.to_be_bytes());
    ex.extend_from_slice(&[1, 0]);
    let sa: [u16; 12] = [
        0x0804, 0x0805, 0x0806, 0x0401, 0x0501, 0x0201, 0x0403, 0x0503, 0x0203, 0x0202, 0x0601,
        0x0603,
    ];
    let mut sb = vec![((sa.len() * 2) >> 8) as u8, (sa.len() * 2) as u8];
    for s in sa {
        sb.extend_from_slice(&s.to_be_bytes());
    }
    ex.extend_from_slice(&0x000d_u16.to_be_bytes());
    ex.extend_from_slice(&(sb.len() as u16).to_be_bytes());
    ex.extend_from_slice(&sb);
    // 与 GWSetup.exe 抓包一致：提供 session_ticket 和 EMS；服务器当前仅回
    // renegotiation_info，因此最终是否使用 EMS 由 ServerHello 决定。
    ex.extend_from_slice(&0x0023_u16.to_be_bytes());
    ex.extend_from_slice(&0u16.to_be_bytes());
    ex.extend_from_slice(&0x0017_u16.to_be_bytes());
    ex.extend_from_slice(&0u16.to_be_bytes());
    ex.extend_from_slice(&0xFF01_u16.to_be_bytes());
    ex.extend_from_slice(&1u16.to_be_bytes());
    ex.push(0);
    b.extend_from_slice(&(ex.len() as u16).to_be_bytes());
    b.extend_from_slice(&ex);
    let mut hs = vec![0x01];
    hs.extend_from_slice(&(b.len() as u32).to_be_bytes()[1..]);
    hs.extend_from_slice(&b);
    let mut rec = vec![0x16];
    rec.extend_from_slice(&V12);
    rec.extend_from_slice(&(hs.len() as u16).to_be_bytes());
    rec.extend_from_slice(&hs);
    (rec, r, hs)
}

// === 服务器握手解析 ===
async fn read_sh(stream: &mut TcpStream) -> Result<([u8; 32], RsaPublicKey, Vec<u8>, bool)> {
    let mut buf = Vec::new();
    let mut t = [0u8; 8192];
    let mut sr = [0u8; 32];
    let mut rsa = None;
    let mut ems = false;
    let mut saw_server_hello = false;
    let mut hs = Vec::new();
    let mut p = 0;
    loop {
        let n = stream
            .read(&mut t)
            .await
            .map_err(|e| HuseVpnError::Tls(format!("rhs {e}")))?;
        if n == 0 {
            return Err(HuseVpnError::Tls("EOF".into()));
        }
        buf.extend_from_slice(&t[..n]);
        if buf.len() > MAX_SERVER_HANDSHAKE_BYTES {
            return Err(HuseVpnError::Tls(
                "Gateway TLS handshake exceeded the safety limit".into(),
            ));
        }
        while p + 5 <= buf.len() {
            if buf[p] != 0x16 {
                p += 5 + u16::from_be_bytes([buf[p + 3], buf[p + 4]]) as usize;
                continue;
            }
            let rl = u16::from_be_bytes([buf[p + 3], buf[p + 4]]) as usize;
            if p + 5 + rl > buf.len() {
                break;
            }
            hs.extend_from_slice(&buf[p + 5..p + 5 + rl]);
            let mut q = p + 5;
            let e = q + rl;
            while q + 4 <= e {
                let ty = buf[q];
                let hl = ((buf[q + 1] as usize) << 16)
                    | ((buf[q + 2] as usize) << 8)
                    | (buf[q + 3] as usize);
                let b = q + 4;
                if b + hl > e {
                    break;
                }
                match ty {
                    0x02 => {
                        if hl < 38 {
                            return Err(HuseVpnError::Tls("truncated ServerHello".into()));
                        }
                        sr.copy_from_slice(&buf[b + 2..b + 2 + 32]);
                        let s = 2 + 32;
                        let sl = buf[b + s] as usize;
                        let cso = b + s + 1 + sl;
                        if cso + 2 > b + hl {
                            return Err(HuseVpnError::Tls(
                                "truncated ServerHello cipher suite".into(),
                            ));
                        }
                        let cipher = u16::from_be_bytes([buf[cso], buf[cso + 1]]);
                        if cipher != 0x002f {
                            return Err(HuseVpnError::Tls(format!(
                                "gateway selected unsupported cipher 0x{cipher:04x}"
                            )));
                        }
                        // check EMS in ServerHello extensions
                        let mut xo = b + s + 1 + sl + 2 + 1; // after cipher(2)+comp(1)
                        if xo + 2 <= b + hl {
                            let xl = u16::from_be_bytes([buf[xo], buf[xo + 1]]) as usize;
                            xo += 2;
                            let xe = xo + xl;
                            while xo + 4 <= xe && xo + 4 <= b + hl {
                                let et = u16::from_be_bytes([buf[xo], buf[xo + 1]]);
                                let el = u16::from_be_bytes([buf[xo + 2], buf[xo + 3]]) as usize;
                                xo += 4;
                                if et == 0x0017 {
                                    ems = true;
                                }
                                xo += el;
                            }
                        }
                        saw_server_hello = true;
                    }
                    0x0b => {
                        if hl < 6 {
                            return Err(HuseVpnError::Tls(
                                "truncated Gateway certificate message".into(),
                            ));
                        }
                        let mut cq = b + 3;
                        let cl = ((buf[cq] as usize) << 16)
                            | ((buf[cq + 1] as usize) << 8)
                            | (buf[cq + 2] as usize);
                        cq += 3;
                        if cl == 0 || cq + cl > b + hl {
                            return Err(HuseVpnError::Tls(
                                "invalid Gateway certificate length".into(),
                            ));
                        }
                        rsa = Some(parse_rsa(&buf[cq..cq + cl])?);
                    }
                    0x0e => {
                        if saw_server_hello {
                            if let Some(r) = rsa {
                                return Ok((sr, r, hs, ems));
                            }
                        }
                        if rsa.is_some() {
                            return Err(HuseVpnError::Tls(
                                "Gateway sent a certificate without ServerHello".into(),
                            ));
                        } else {
                            return Err(HuseVpnError::Tls(
                                "Gateway did not provide a certificate".into(),
                            ));
                        }
                    }
                    _ => {}
                }
                q = b + hl;
            }
            p = e;
        }
    }
}

fn parse_rsa(der: &[u8]) -> Result<RsaPublicKey> {
    use x509_cert::Certificate;
    let c = Certificate::from_der(der).map_err(|e| HuseVpnError::Tls(format!("cert {e}")))?;
    let spki = c.tbs_certificate().subject_public_key_info();
    let spki_der = spki
        .to_der()
        .map_err(|e| HuseVpnError::Tls(format!("Gateway SPKI encoding failed: {e}")))?;
    verify_gateway_spki_pin(&spki_der)?;
    let spki_bytes = spki.subject_public_key.raw_bytes();
    // Use PKCS1 format (standard for BIT STRING content)
    RsaPublicKey::from_pkcs1_der(spki_bytes).map_err(|e| HuseVpnError::Tls(format!("rsa {e}")))
}

/// 手动 RSA PKCS1v15 加密，使用 BigUint 直接计算 m^e mod n
fn rsa_pkcs1_encrypt_manual(pubkey: &RsaPublicKey, plaintext: &[u8]) -> Vec<u8> {
    let k = (pubkey.n().bits() as usize + 7) / 8; // modulus 字节数
                                                  // PKCS1v15 padding: 00 || 02 || PS || 00 || D
    let ps_len = k - 3 - plaintext.len();
    let mut padded = vec![0x00u8, 0x02u8];
    // 填充非零随机字节
    let mut rng = rand::thread_rng();
    for _ in 0..ps_len {
        let mut b = 0u8;
        while b == 0 {
            b = rand::RngCore::next_u32(&mut rng) as u8;
        }
        padded.push(b);
    }
    padded.push(0x00u8);
    padded.extend_from_slice(plaintext);

    // 将 rsa crate 的 BigUint (num-bigint-dig) 转为 num_bigint::BigUint
    let n_bytes = pubkey.n().to_bytes_be();
    let e_bytes = pubkey.e().to_bytes_be();
    let n = BigUint::from_bytes_be(&n_bytes);
    let e = BigUint::from_bytes_be(&e_bytes);

    // m^e mod n
    let m = BigUint::from_bytes_be(&padded);
    let c = m.modpow(&e, &n);
    let mut result = c.to_bytes_be();
    // 确保输出长度 = k
    while result.len() < k {
        result.insert(0, 0);
    }
    result
}

fn bs(ty: u8, body: &[u8]) -> Vec<u8> {
    let mut v = vec![ty];
    v.extend_from_slice(&(body.len() as u32).to_be_bytes()[1..]);
    v.extend_from_slice(body);
    v
}
async fn wr(s: &mut TcpStream, ct: u8, body: &[u8]) -> Result<()> {
    let mut r = vec![ct];
    r.extend_from_slice(&V12);
    r.extend_from_slice(&(body.len() as u16).to_be_bytes());
    r.extend_from_slice(body);
    s.write_all(&r)
        .await
        .map_err(|e| HuseVpnError::Tls(format!("wr {e}")))?;
    Ok(())
}

struct AesCbc {
    k: [u8; 16],
}
impl AesCbc {
    fn new(k: &[u8; 16]) -> Self {
        Self { k: *k }
    }
    fn enc(&self, iv: &[u8; 16], pl: &[u8]) -> Vec<u8> {
        use aes::cipher::{BlockEncrypt, KeyInit};
        let c = aes::Aes128::new_from_slice(&self.k).unwrap();
        // TLS CBC padding is not PKCS#7: there are N padding bytes and each
        // byte is N-1 (RFC 5246 §6.2.3.2). At least one padding byte is present.
        let pad_bytes = 16 - (pl.len() % 16);
        let mut p = pl.to_vec();
        p.extend(std::iter::repeat((pad_bytes - 1) as u8).take(pad_bytes));
        let mut pr = *iv;
        let mut o = iv.to_vec();
        for b in p.chunks_mut(16) {
            for (x, y) in b.iter_mut().zip(pr.iter()) {
                *x ^= y;
            }
            let mut a = [0u8; 16];
            a.copy_from_slice(b);
            c.encrypt_block((&mut a).into());
            o.extend_from_slice(&a);
            pr = a;
        }
        o
    }
    fn dec(&self, iv: &[u8; 16], ct: &[u8]) -> Vec<u8> {
        use aes::cipher::{BlockDecrypt, KeyInit};
        let c = aes::Aes128::new_from_slice(&self.k).unwrap();
        let mut pr = *iv;
        let mut o = Vec::new();
        for b in ct.chunks(16) {
            let mut a = [0u8; 16];
            a.copy_from_slice(b);
            c.decrypt_block((&mut a).into());
            for (x, y) in a.iter_mut().zip(pr.iter()) {
                *x ^= y;
            }
            o.extend_from_slice(&a);
            pr = *b.try_into().unwrap_or(&[0u8; 16]);
        }
        if let Some(&pad) = o.last() {
            let pad_bytes = pad as usize + 1;
            if pad_bytes <= 16
                && pad_bytes <= o.len()
                && o[o.len() - pad_bytes..].iter().all(|&b| b == pad)
            {
                o.truncate(o.len() - pad_bytes);
            }
        }
        o
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::engine::general_purpose::STANDARD as BASE64;
    use base64::Engine as _;

    #[test]
    fn accepts_only_the_pinned_gateway_spki() {
        let spki = BASE64
            .decode("MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCxiIN/pAoIjnB9DjbRsQEQuNYbs/C51yzemJBXONrSNMIUINCG8ex7oPyYw+zGSwH/5sAF3eCxgkBQxHl0xd55+p/IBXZmJbkNYlEegdnWqA0NxDhMoTzq5uHbXz7FGV39ZJHw9CLxRE5Uq0NzlqsrdZCDHHed1fZQCngp6HPC/wIDAQAB")
            .unwrap();
        verify_gateway_spki_pin(&spki).unwrap();

        let mut substituted = spki;
        *substituted.last_mut().unwrap() ^= 1;
        assert!(verify_gateway_spki_pin(&substituted).is_err());
    }

    #[test]
    fn prf_matches_python() {
        // Same inputs as verify_crypto.py
        let pre: [u8; 48] = {
            let mut p = [0u8; 48];
            p[..2].copy_from_slice(&[0x03, 0x03]);
            for i in 2..48 {
                p[i] = b'A';
            }
            p
        };
        let cr = [b'B'; 32];
        let sr = [b'C'; 32];
        let hs_data = b"CHSHCERTSHDCKE";

        // master_secret
        let mut ms_seed = b"master secret".to_vec();
        ms_seed.extend_from_slice(&cr);
        ms_seed.extend_from_slice(&sr);
        let ms = p_sha256(&pre, &ms_seed, 48);
        let ms_hex = hex::encode(&ms);
        println!("master_secret: {ms_hex}");
        assert_eq!(ms_hex, "38dc329f2291aee192b0059a28b78f86ea6d0fd10bcdf75b1f067d365e986b6dfc2850c10e154c304c432fbe5691010f",
            "master_secret should match Python");

        // key block (RFC 5246 order: MAC first, then KEY)
        let mut ke_seed = b"key expansion".to_vec();
        ke_seed.extend_from_slice(&sr);
        ke_seed.extend_from_slice(&cr);
        let kb = p_sha256(&ms, &ke_seed, 72);
        let cm = &kb[0..20];
        let ck = &kb[40..56];
        println!("client_write_key: {}", hex::encode(ck));
        println!("client_write_mac: {}", hex::encode(cm));

        let (derived_ck, derived_sk, derived_cm, derived_sm, derived_ms) =
            derive_keys(&pre, &cr, &sr, false, hs_data);
        assert_eq!(&derived_ms[..], &ms[..]);
        assert_eq!(&derived_cm[..], &kb[0..20]);
        assert_eq!(&derived_sm[..], &kb[20..40]);
        assert_eq!(&derived_ck[..], &kb[40..56]);
        assert_eq!(&derived_sk[..], &kb[56..72]);

        // verify_data
        let hh = Sha256::digest(hs_data);
        println!("HS hash: {}", hex::encode(&hh));
        let mut vd_seed = b"client finished".to_vec();
        vd_seed.extend_from_slice(&hh);
        let vd = p_sha256(&ms, &vd_seed, 12);
        println!("verify_data: {}", hex::encode(&vd));

        // AES round-trip test
        let ac = AesCbc::new(ck.try_into().unwrap());
        let iv = [0u8; 16];
        let plain = b"Hello TLS Record!";
        let enc = ac.enc(&iv, plain);
        let dec = ac.dec(&iv, &enc[16..]);
        assert_eq!(plain, &dec[..plain.len()], "AES round-trip failed");
        println!("AES round-trip: OK");
    }

    #[test]
    fn client_hello_matches_captured_gateway_profile() {
        let (record, _random, handshake) = build_ch();
        // `cap_all_20260728_222630.pcapng`, stream 41: TLS record length 142.
        assert_eq!(&record[..5], &[0x16, 0x03, 0x03, 0x00, 0x8e]);
        assert_eq!(record.len(), 147);
        assert_eq!(handshake[0], 0x01);
        assert_eq!(handshake[4 + 2 + 32], 0, "Session ID must be empty");
        assert!(handshake.ends_with(&[
            0x00, 0x23, 0x00, 0x00, // session_ticket
            0x00, 0x17, 0x00, 0x00, // extended_master_secret
            0xff, 0x01, 0x00, 0x01, 0x00, // renegotiation_info
        ]));
    }
}
