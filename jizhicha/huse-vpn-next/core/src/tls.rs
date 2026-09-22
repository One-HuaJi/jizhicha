//! TLS 1.2 + RSA-AES128-CBC-SHA + EMS（精确匹配 GWSetup.exe ClientHello）
use crate::error::{HuseVpnError, Result};
use crate::packet_trace_enabled;
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

/// [`derive_keys`] 的返回值。
///
/// 改用命名字段是为了消除裸五元组 + 位置解构带来的静默错序风险：密码学代码里
/// 把 client/server 或 key/mac 的位置写反不会编译报错，只会让握手全错。
///
/// ⚠️ 字段名与 key block 切分偏移的对应关系（**唯一依据是下面 `derive_keys`
/// 内部的 `kb[..]` 切片**，不是本结构体的字段声明顺序）：
///   * `client_mac`    = key block[0..20]
///   * `server_mac`    = key block[20..40]
///   * `client_key`    = key block[40..56]
///   * `server_key`    = key block[56..72]
///   * `master_secret` = PRF(pre_master_secret, "master secret", client_random + server_random)
///
/// 注意 RFC 5246 §6.3 规定 key block 里 **MAC secret 在前、写入密钥在后**，
/// 所以"客户端在前"的命名顺序与 key block 的物理顺序并不一致。
/// `core/src/tls.rs` 底部的 `prf_matches_python` 测试逐字节断言了上述映射。
struct DerivedKeys {
    client_key: [u8; 16],
    server_key: [u8; 16],
    client_mac: [u8; 20],
    server_mac: [u8; 20],
    master_secret: [u8; 48],
}

fn derive_keys(
    pre: &[u8; 48],
    cr: &[u8; 32],
    sr: &[u8; 32],
    ems: bool,
    hs_bytes: &[u8],
) -> DerivedKeys {
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
    // 字段取值顺序与旧版裸元组 `(ck, sk, cm, sm, ms_arr)` 完全一致。
    DerivedKeys {
        client_key: ck,
        server_key: sk,
        client_mac: cm,
        server_mac: sm,
        master_secret: ms_arr,
    }
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

        let keys = derive_keys(&pre48, &cr, &sr, ems, &hs);
        let client_finished = finished_verify_data(&keys.master_secret, b"client finished", &hs);
        let client_finished_message = bs(0x14, &client_finished);
        let client_finished_record = encrypt_record(
            0x16,
            &keys.client_key,
            &keys.client_mac,
            0,
            &client_finished_message,
        );
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
        let server_finished = decrypt_record(
            server_type,
            &server_body,
            &keys.server_key,
            &keys.server_mac,
            0,
        )?;
        let expected = bs(
            0x14,
            &finished_verify_data(&keys.master_secret, b"server finished", &hs),
        );
        if server_type != 0x16 || server_finished != expected {
            return Err(HuseVpnError::Tls(
                "server Finished verification failed".into(),
            ));
        }
        Ok(RawTlsClient {
            stream: s,
            client_key: keys.client_key,
            client_mac: keys.client_mac,
            server_key: keys.server_key,
            server_mac: keys.server_mac,
            // TLS Finished is the first protected client record and uses seq=0.
            // Application data therefore begins at seq=1.
            send_seq: 1,
            recv_seq: 1,
        })
    }

    async fn send(&mut self, ct: u8, pl: &[u8]) -> Result<()> {
        let (records, used) =
            encrypt_fragments(ct, &self.client_key, &self.client_mac, self.send_seq, pl);
        self.send_seq += used;
        self.stream
            .write_all(&records)
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
        if packet_trace_enabled() {
            eprintln!(
                "HUSE VPN downlink TLS record: type=0x{content_type:02x}, encrypted_len={}",
                body.len()
            );
        }
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
        let (records, used) = encrypt_fragments(
            0x17,
            &self.client_key,
            &self.client_mac,
            self.send_seq,
            data,
        );
        self.send_seq += used;
        self.stream
            .write_all(&records)
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

/// TLS 1.2 limits a single record's plaintext to 2^14 bytes, and the record
/// length field is only 16 bits. One NC data frame can carry a 65535-byte IP
/// packet plus a 12-byte header, so writing it as one record would wrap the
/// length field and permanently desynchronize the peer's record parser.
/// Every application-data write is therefore split into legal records.
const MAX_TLS_PLAINTEXT: usize = 16_384;

/// Encrypt `plaintext` into one or more TLS records.
///
/// Returns the concatenated records and how many TLS sequence numbers were
/// consumed, so callers keep their send sequence in sync.
fn encrypt_fragments(
    content_type: u8,
    key: &[u8; 16],
    mac_secret: &[u8; 20],
    sequence: u64,
    plaintext: &[u8],
) -> (Vec<u8>, u64) {
    if plaintext.is_empty() {
        // Keep empty writes representable as a single legal record.
        return (
            encrypt_record(content_type, key, mac_secret, sequence, &[]),
            1,
        );
    }
    let mut out =
        Vec::with_capacity(plaintext.len() + (plaintext.len() / MAX_TLS_PLAINTEXT + 1) * 64);
    let mut used = 0u64;
    // 用 enumerate 取代手写计数器：`sequence + offset` 与旧版 `seq` 完全等价。
    for (offset, chunk) in plaintext.chunks(MAX_TLS_PLAINTEXT).enumerate() {
        out.extend_from_slice(&encrypt_record(
            content_type,
            key,
            mac_secret,
            sequence + offset as u64,
            chunk,
        ));
        used += 1;
    }
    (out, used)
}

fn encrypt_record(
    content_type: u8,
    key: &[u8; 16],
    mac_secret: &[u8; 20],
    sequence: u64,
    plaintext: &[u8],
) -> Vec<u8> {
    debug_assert!(
        plaintext.len() <= MAX_TLS_PLAINTEXT,
        "encrypt_record must only receive pre-fragmented plaintext"
    );
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

/// 常量时间字节比较：用于校验 MAC，避免"逐字节比较 + 提前 return"把
/// 正确前缀的长度通过耗时泄露给攻击者。
///
/// 实现要点：
/// - 先把**长度差**计入 diff（长度不等时 diff 必非 0），不提前 return；
/// - 再按两者较短长度逐字节异或累加到 diff，同样不提前 return；
/// - 最后只做一次 `diff == 0` 判断。
///
/// 长度不等时读到的内容不影响结论（diff 已由长度差确定），因此不泄露信息。
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    let mut diff = a.len() ^ b.len();
    let n = a.len().min(b.len());
    for i in 0..n {
        diff |= (a[i] ^ b[i]) as usize;
    }
    diff == 0
}

/// 独立校验并剥离 TLS 1.2 CBC 的 padding（RFC 5246 §6.2.3.2）。
///
/// 编码方式与 [`AesCbc::enc`] 一致：最后一个字节是 `N-1`，表示共有 `N` 个
/// padding 字节，且这 `N` 个字节**每一个都等于 `N-1`**。
///
/// 这里是必须通过的一步：padding 非法（长度越界、字节不一致、没有 padding
/// 字节）一律返回 `Err`，绝不把"含 padding 的明文"当成明文继续往下走。
/// 调用方必须在本函数成功之后再计算/校验 MAC，二者不混在一起。
fn strip_tls_padding(buf: &mut Vec<u8>) -> Result<()> {
    // 空缓冲意味着连 padding 长度字节都没有，即"padding 长度为 0"，非法。
    let pad_byte = match buf.last() {
        Some(&b) => b,
        None => {
            return Err(HuseVpnError::Tls(
                "TLS record padding length is zero".into(),
            ))
        }
    };
    // 线上编码是 N-1，所以真实 padding 长度是 pad_byte + 1。
    let pad_len = pad_byte as usize + 1;
    // pad_byte + 1 恒 >= 1，故 `pad_len == 0` 在非空缓冲下不会成立；这里仍然
    // 显式写出来作为纵深防御（TLS 记录必须至少带 1 个 padding 字节）。
    if pad_len == 0 || pad_len > 16 || pad_len > buf.len() {
        return Err(HuseVpnError::Tls(format!(
            "invalid TLS record padding length {pad_len}"
        )));
    }
    // 每一个 padding 字节都必须等于 pad_byte，不允许"部分正确"的填充。
    if !buf[buf.len() - pad_len..].iter().all(|&b| b == pad_byte) {
        return Err(HuseVpnError::Tls("invalid TLS record padding bytes".into()));
    }
    buf.truncate(buf.len() - pad_len);
    Ok(())
}

fn decrypt_record(
    content_type: u8,
    body: &[u8],
    key: &[u8; 16],
    mac_secret: &[u8; 20],
    sequence: u64,
) -> Result<Vec<u8>> {
    // `!(x % 16 == 0)` 写作 `!x.is_multiple_of(16)`，比较结果与语义完全一致。
    if body.len() < 32 || !(body.len() - 16).is_multiple_of(16) {
        return Err(HuseVpnError::Tls(
            "invalid AES-CBC TLS record length".into(),
        ));
    }
    let iv: [u8; 16] = body[..16].try_into().expect("explicit IV length");
    let mut decrypted = AesCbc::new(key).dec(&iv, &body[16..]);
    if decrypted.len() < 20 {
        return Err(HuseVpnError::Tls(
            "TLS record shorter than HMAC-SHA1".into(),
        ));
    }
    // 第一步：独立且必须通过的 padding 校验。
    strip_tls_padding(&mut decrypted)?;
    if decrypted.len() < 20 {
        return Err(HuseVpnError::Tls(
            "TLS record shorter than HMAC-SHA1".into(),
        ));
    }
    // 第二步：在剥掉 padding 之后才对明文算 MAC，并用常量时间比较。
    let split = decrypted.len() - 20;
    let (plaintext, received_mac) = decrypted.split_at(split);
    let expected_mac = record_mac(mac_secret, sequence, content_type, plaintext);
    if !constant_time_eq(received_mac, &expected_mac) {
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
    // modulus 字节数：`(bits + 7) / 8` 即 `bits.div_ceil(8)`。
    let k = pubkey.n().bits().div_ceil(8);
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
        p.extend(std::iter::repeat_n((pad_bytes - 1) as u8, pad_bytes));
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
    /// 纯 AES-128-CBC 解密：只做分组解密与 IV 链，**不碰 padding**，
    /// 返回值里仍然带着填充字节。
    ///
    /// 之前这里会在"padding 看起来合法"时顺手截断、非法时静默保留原样，
    /// 于是非法 padding 会被当成明文送去算 MAC。现在 padding 校验被拆成
    /// 独立的一步 [`strip_tls_padding`]，调用方必须先做完它并通过，才能
    /// 使用这里的返回值。
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
            // 等价于 `for i in 2..48 { p[i] = b'A' }`，只是不再手工索引。
            for b in p.iter_mut().skip(2) {
                *b = b'A';
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
        // NOTE: do not print derived key material, even for synthetic vectors —
        // the pattern gets copied into real code and leaks into CI logs.
        assert_eq!(ms_hex, "38dc329f2291aee192b0059a28b78f86ea6d0fd10bcdf75b1f067d365e986b6dfc2850c10e154c304c432fbe5691010f",
            "master_secret should match Python");

        // key block (RFC 5246 order: MAC first, then KEY)
        let mut ke_seed = b"key expansion".to_vec();
        ke_seed.extend_from_slice(&sr);
        ke_seed.extend_from_slice(&cr);
        let kb = p_sha256(&ms, &ke_seed, 72);
        let cm = &kb[0..20];
        let ck = &kb[40..56];

        let derived = derive_keys(&pre, &cr, &sr, false, hs_data);
        assert_eq!(&derived.master_secret[..], &ms[..]);
        assert_eq!(&derived.client_mac[..], &kb[0..20]);
        assert_eq!(&derived.server_mac[..], &kb[20..40]);
        assert_eq!(&derived.client_key[..], &kb[40..56]);
        assert_eq!(&derived.server_key[..], &kb[56..72]);

        // verify_data
        let hh = Sha256::digest(hs_data);
        let mut vd_seed = b"client finished".to_vec();
        vd_seed.extend_from_slice(&hh);
        let vd = p_sha256(&ms, &vd_seed, 12);
        assert_eq!(vd.len(), 12, "TLS Finished verify_data is 12 bytes");

        // AES round-trip test
        let ac = AesCbc::new(ck.try_into().unwrap());
        let iv = [0u8; 16];
        let plain = b"Hello TLS Record!";
        let enc = ac.enc(&iv, plain);
        let dec = ac.dec(&iv, &enc[16..]);
        assert_eq!(plain, &dec[..plain.len()], "AES round-trip failed");
        let _ = cm;
    }

    /// A single NC frame can exceed the TLS 1.2 plaintext limit; writing it as one
    /// record used to wrap the 16-bit length field and desynchronize the stream.
    #[test]
    fn oversized_application_data_is_split_into_legal_records() {
        let key = [0x11u8; 16];
        let mac_secret = [0x22u8; 20];
        // 65535-byte IP packet + 12-byte NC header, the real worst case.
        let plaintext = vec![0x45u8; 65_535 + 12];

        let (records, used) = encrypt_fragments(0x17, &key, &mac_secret, 0, &plaintext);

        assert!(used >= 4, "超长 payload 必须拆成多条 record，实际 {used}");
        // Walk the record headers back out and assert each declared length is
        // consistent with the bytes that actually follow it.
        let mut offset = 0usize;
        let mut seen = 0u64;
        while offset < records.len() {
            let content_type = records[offset];
            let version = &records[offset + 1..offset + 3];
            let declared =
                u16::from_be_bytes(records[offset + 3..offset + 5].try_into().unwrap()) as usize;
            assert_eq!(content_type, 0x17);
            assert_eq!(version, &V12);
            assert!(
                offset + 5 + declared <= records.len(),
                "record 长度字段越界（发生了 16 位截断）"
            );
            offset += 5 + declared;
            seen += 1;
        }
        assert_eq!(offset, records.len(), "record 必须精确首尾相接");
        assert_eq!(seen, used, "解析出的 record 数必须等于消耗的序列号数");
    }

    #[test]
    fn fragmented_records_stay_within_the_tls_plaintext_limit() {
        let key = [0x33u8; 16];
        let mac_secret = [0x44u8; 20];
        let plaintext = vec![0x60u8; MAX_TLS_PLAINTEXT * 2 + 1];
        let (records, used) = encrypt_fragments(0x17, &key, &mac_secret, 0, &plaintext);
        assert_eq!(used, 3, "两倍上限加一字节应拆成 3 条");
        assert!(!records.is_empty());
    }

    #[test]
    fn empty_write_still_emits_one_record() {
        let key = [0x55u8; 16];
        let mac_secret = [0x66u8; 20];
        let (records, used) = encrypt_fragments(0x17, &key, &mac_secret, 0, &[]);
        assert_eq!(used, 1);
        assert!(records.len() >= 24, "空记录仍需带 IV 与 HMAC");
    }

    /// Strongest local proof that fragmentation is wire-correct: split the
    /// records back out, decrypt each with its own sequence number, verify the
    /// MAC, and confirm the plaintext reassembles byte-for-byte.
    #[test]
    fn fragmented_records_round_trip_through_the_decryptor() {
        let key = [0x77u8; 16];
        let mac_secret = [0x88u8; 20];
        // Deliberately cross both the single-record limit and a partial tail.
        let mut plaintext = Vec::new();
        for i in 0..(MAX_TLS_PLAINTEXT * 2 + 123) {
            plaintext.push((i % 251) as u8);
        }

        let (records, used) = encrypt_fragments(0x17, &key, &mac_secret, 7, &plaintext);
        assert_eq!(used, 3, "应拆成 3 条 record");

        let mut offset = 0usize;
        let mut seq = 7u64;
        let mut rebuilt = Vec::new();
        while offset < records.len() {
            let content_type = records[offset];
            let declared =
                u16::from_be_bytes(records[offset + 3..offset + 5].try_into().unwrap()) as usize;
            let body = &records[offset + 5..offset + 5 + declared];
            let decrypted = decrypt_record(content_type, body, &key, &mac_secret, seq)
                .expect("分片后的每条 record 都必须能通过 MAC 校验");
            rebuilt.extend_from_slice(&decrypted);
            offset += 5 + declared;
            seq += 1;
        }

        assert_eq!(rebuilt, plaintext, "重组后的明文必须与原文完全一致");
    }

    /// A single sequence number reused across fragments would produce duplicate
    /// MACs and a rejected stream; assert the sequence advances per record.
    #[test]
    fn each_fragment_uses_a_distinct_sequence_number() {
        let key = [0x99u8; 16];
        let mac_secret = [0xaau8; 20];
        let plaintext = vec![0x5au8; MAX_TLS_PLAINTEXT + 1];
        let (records, used) = encrypt_fragments(0x17, &key, &mac_secret, 0, &plaintext);
        assert_eq!(used, 2);

        // Decrypting the second record with sequence 0 (the first record's
        // number) must fail; with sequence 1 it must succeed.
        let first_len = 5 + u16::from_be_bytes(records[3..5].try_into().unwrap()) as usize;
        let second = &records[first_len..];
        let second_type = second[0];
        let second_body_len = u16::from_be_bytes(second[3..5].try_into().unwrap()) as usize;
        let second_body = &second[5..5 + second_body_len];

        assert!(
            decrypt_record(second_type, second_body, &key, &mac_secret, 0).is_err(),
            "第二条 record 不能用序号 0 解密"
        );
        assert!(
            decrypt_record(second_type, second_body, &key, &mac_secret, 1).is_ok(),
            "第二条 record 必须使用序号 1"
        );
    }

    // === CBC padding / MAC 加固测试 ===
    // 全部使用合成向量（合成密钥、合成明文），不含任何真实凭据。

    /// 测试用原始 AES-128-CBC 加密：分组对齐、**不做任何 padding 处理**，
    /// 这样测试才能自己拼出 padding 畸形的 record。
    fn raw_cbc_encrypt(key: &[u8; 16], iv: &[u8; 16], data: &[u8]) -> Vec<u8> {
        use aes::cipher::{BlockEncrypt, KeyInit};
        assert_eq!(data.len() % 16, 0, "测试向量必须分组对齐");
        let c = aes::Aes128::new_from_slice(key).unwrap();
        let mut pr = *iv;
        let mut out = iv.to_vec();
        for chunk in data.chunks(16) {
            let mut blk = [0u8; 16];
            blk.copy_from_slice(chunk);
            for (x, y) in blk.iter_mut().zip(pr.iter()) {
                *x ^= y;
            }
            let mut a = blk;
            c.encrypt_block((&mut a).into());
            out.extend_from_slice(&a);
            pr = a;
        }
        out
    }

    /// 按 RFC 5246 §6.2.3.2 生成**合法** padding：`N` 个字节，每个都等于 `N-1`。
    /// `prefix_len` 是 padding 之前的长度（明文 + HMAC）。
    fn legal_tls_padding(prefix_len: usize) -> Vec<u8> {
        let pad_len = 16 - (prefix_len % 16);
        vec![(pad_len - 1) as u8; pad_len]
    }

    /// 把 `plaintext || HMAC || padding` 拼成一条 record 的 body（IV || 密文）。
    fn craft_body(key: &[u8; 16], iv: &[u8; 16], fragment: &[u8]) -> Vec<u8> {
        raw_cbc_encrypt(key, iv, fragment)
    }

    /// 缺陷 1 回归：padding 非法时必须由**独立的 padding 校验**拒绝，
    /// 而不是靠 MAC 顺带失败，更不能把带 padding 的明文当明文放行。
    #[test]
    fn invalid_cbc_padding_is_rejected() {
        let key = [0x11u8; 16];
        let mac_secret = [0x12u8; 20];
        let iv = [0x13u8; 16];
        let seq = 3u64;
        let plaintext = b"synthetic padding probe".to_vec();
        let mac = record_mac(&mac_secret, seq, 0x17, &plaintext);

        // 用给定 padding 字节构造 body；MAC 只覆盖 plaintext（与线上格式一致）。
        let mk = |pad: &[u8]| {
            let mut f = plaintext.clone();
            f.extend_from_slice(&mac);
            f.extend_from_slice(pad);
            craft_body(&key, &iv, &f)
        };

        // (1) padding 字节不一致：5 个填充字节里改坏一个。
        let mut inconsistent = legal_tls_padding(plaintext.len() + 20);
        assert_eq!(inconsistent, vec![4u8; 5], "合成向量自检：应为 5 个 0x04");
        inconsistent[1] = 0x00;
        let bad = mk(&inconsistent);
        let msg = format!(
            "{}",
            decrypt_record(0x17, &bad, &key, &mac_secret, seq).unwrap_err()
        );
        assert!(
            msg.contains("padding"),
            "padding 字节不一致必须被独立的 padding 校验拒绝，实际错误: {msg}"
        );

        // (2) padding 长度 > 16：末尾字节 0xff 表示 256 字节填充，越界。
        let mut too_long = legal_tls_padding(plaintext.len() + 20);
        *too_long.last_mut().unwrap() = 0xff;
        let bad = mk(&too_long);
        let msg = format!(
            "{}",
            decrypt_record(0x17, &bad, &key, &mac_secret, seq).unwrap_err()
        );
        assert!(
            msg.contains("padding"),
            "padding 长度 > 16 必须被拒绝，实际错误: {msg}"
        );

        // (3) padding 长度为 0：没有任何 padding 字节。
        //     注意 RFC 5246 的线上编码是 `N-1`，非空缓冲里 N 恒 >= 1，所以
        //     "一个填充字节都没有"只在解密路径入口（空缓冲）上可能出现，
        //     这里直接打 padding 校验入口。反过来，一个字节 0x00 的填充是
        //     合法编码（N=1），见 legal_cbc_padding_still_decrypts。
        let mut none = Vec::new();
        let msg = format!("{}", strip_tls_padding(&mut none).unwrap_err());
        assert!(
            msg.contains("padding"),
            "padding 长度为 0 必须被拒绝，实际错误: {msg}"
        );
        assert!(none.is_empty(), "拒绝后不得留下任何中间状态");
    }

    /// 缺陷 1 的正向对照：合法 padding 仍能正常解出明文，包括两个边界
    /// （N = 1 的 0x00 填充、N = 16 的最大填充）。
    #[test]
    fn legal_cbc_padding_still_decrypts() {
        let key = [0x31u8; 16];
        let mac_secret = [0x32u8; 20];
        // 11 字节 -> 明文+MAC = 31 -> 单字节 0x00 填充
        // 12 字节 -> 明文+MAC = 32 -> 16 字节 0x0f 填充
        // 23 字节 -> 明文+MAC = 43 -> 5 字节 0x04 填充
        for plaintext in [
            b"synthetic-1".to_vec(),
            b"synthetic-12".to_vec(),
            b"synthetic padding probe!".to_vec(),
        ] {
            let record = encrypt_record(0x17, &key, &mac_secret, 9, &plaintext);
            let out = decrypt_record(0x17, &record[5..], &key, &mac_secret, 9)
                .expect("合法 padding 的记录必须能解开");
            assert_eq!(out, plaintext, "合法 padding 路径不得影响明文");
        }
    }

    /// 缺陷 2 回归：只篡改 MAC 的一个字节（padding 完全合法），必须被拒绝，
    /// 且走的是 MAC 校验分支；顺带确认同一明文用正确 MAC 仍能通过。
    #[test]
    fn tampered_mac_is_rejected() {
        let key = [0x21u8; 16];
        let mac_secret = [0x22u8; 20];
        let iv = [0x23u8; 16];
        let seq = 11u64;
        let plaintext = b"synthetic mac probe".to_vec();
        let mut mac = record_mac(&mac_secret, seq, 0x17, &plaintext);
        mac[7] ^= 0x01;
        let mut fragment = plaintext.clone();
        fragment.extend_from_slice(&mac);
        fragment.extend_from_slice(&legal_tls_padding(plaintext.len() + 20));
        let body = craft_body(&key, &iv, &fragment);

        let msg = format!(
            "{}",
            decrypt_record(0x17, &body, &key, &mac_secret, seq).unwrap_err()
        );
        assert!(
            msg.contains("MAC"),
            "篡改 MAC 必须被 MAC 校验拒绝，实际错误: {msg}"
        );

        let good = encrypt_record(0x17, &key, &mac_secret, seq, &plaintext);
        assert_eq!(
            decrypt_record(0x17, &good[5..], &key, &mac_secret, seq).unwrap(),
            plaintext,
            "未篡改的记录必须仍然通过"
        );
    }

    /// 缺陷 2：常量时间比较函数本身的单元测试。
    #[test]
    fn constant_time_eq_handles_equal_diff_and_length_mismatch() {
        // 相等
        assert!(constant_time_eq(
            b"synthetic-mac-bytes",
            b"synthetic-mac-bytes"
        ));
        assert!(constant_time_eq(&[], &[]));
        // 长度不同（含一边为空、以及长公共前缀）
        assert!(!constant_time_eq(
            b"synthetic-mac-bytes",
            b"synthetic-mac-byte"
        ));
        assert!(!constant_time_eq(&[], b"synthetic-mac-bytes"));
        assert!(!constant_time_eq(b"synthetic-mac-bytes", &[]));
        assert!(!constant_time_eq(&[0xab; 20], &[0xab; 21]));
        // 单字节不同（首字节、末字节各一例）
        assert!(!constant_time_eq(
            b"synthetic-mac-bytes",
            b"Xynthetic-mac-bytes"
        ));
        assert!(!constant_time_eq(
            b"synthetic-mac-bytes",
            b"synthetic-mac-byteX"
        ));
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
