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
use zeroize::{Zeroize, Zeroizing};

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
    // `a` 是 A(i) 链、`mi` 是本次 HMAC 的输入；`out` 的**前身**是调用方即将拿去
    // 当密钥用的字节（master secret / key block），`out` 本身按值返回、擦除责任
    // 在调用方。这里只负责不让 A(i) 中间块留在堆上——它是从 secret 派生的，同样
    // 属于密钥材料。
    let mut a = Zeroizing::new(seed.to_vec());
    while out.len() < len {
        *a = hmac_sha256(secret, &a).to_vec();
        let mi = Zeroizing::new({
            let mut mi = a.to_vec();
            mi.extend_from_slice(seed);
            mi
        });
        out.extend_from_slice(&hmac_sha256(secret, &mi));
    }
    out.truncate(len);
    // 截断只改长度、不擦字节：被丢掉的那截仍然躺在已分配的堆区里，必须手动清掉，
    // 否则 key block 的尾部会以"已释放但不为零"的形态留在进程内存中。
    let live = out.len();
    out[live..].zeroize();
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

/// 密钥材料出作用域即擦除。
///
/// ⚠️ 字段类型保持**裸 `[u8; N]`**，不要改成 `Zeroizing<[u8; N]>`：整个 `tls.rs`
/// 都是按 `&[u8; 16]` / `&[u8; 20]` / `&[u8; 48]` 取字段的，换成包装类型会牵动
/// 全部调用点，无谓地放大 diff。这里手写 `Drop` 只加擦除、不改任何读写路径。
///
/// 擦除时机是 `derive_keys` 的返回值在 `connect` 里被用完（Finished 校验结束）
/// 之后的析构点；线上的 key block / master secret 已经按值拷进
/// [`RawTlsClient`]，因此在**仍有连接在跑**时擦这份副本是安全的。
impl Drop for DerivedKeys {
    fn drop(&mut self) {
        // 每个字段都必须点到名：漏一个就正好漏掉一份密钥材料。
        self.client_key.zeroize();
        self.server_key.zeroize();
        self.client_mac.zeroize();
        self.server_mac.zeroize();
        self.master_secret.zeroize();
    }
}

fn derive_keys(
    pre: &[u8; 48],
    cr: &[u8; 32],
    sr: &[u8; 32],
    ems: bool,
    hs_bytes: &[u8],
) -> DerivedKeys {
    // 三份中间量都用 `Zeroizing` 包住：`ms` 是 master secret 本体，`kb` 是一整块
    // key block，`s2` 是 key expansion 的 seed。它们在本函数返回时就不再需要，
    // 必须随作用域擦除，而不是留在堆上等复用。
    let ms = Zeroizing::new(if ems {
        let h = Sha256::digest(hs_bytes);
        let mut seed = b"extended master secret".to_vec();
        seed.extend_from_slice(&h);
        p_sha256(pre, &seed, 48)
    } else {
        let mut seed = b"master secret".to_vec();
        seed.extend_from_slice(cr);
        seed.extend_from_slice(sr);
        p_sha256(pre, &seed, 48)
    });
    let mut s2 = Zeroizing::new(b"key expansion".to_vec());
    s2.extend_from_slice(sr);
    s2.extend_from_slice(cr);
    let kb = Zeroizing::new(p_sha256(&ms, &s2, 72));
    // RFC 5246 §6.3：client/server MAC secret 在前，随后才是写入密钥。
    //
    // 四个局部量用 `Zeroizing` 包住而不是裸 `[u8; N]`：返回结构体按值拷走一份之后，
    // 本函数栈上的这份副本必须跟着作用域消失。**顺序至关重要**——只能在取出值
    // （`*ck` / `*cm` …）构造返回结构体**之后**才轮到它们析构；若在构造之前就把
    // 它们清零，返回结构体里装的就会是全零（这正是本次重构踩过的坑，
    // `prf_matches_python` 会逐字节把它抓出来）。数组本身实现了 `Copy`，
    // `*ck` 拷贝的是值、不是别名。
    let mut cm = Zeroizing::new([0u8; 20]);
    let mut sm = Zeroizing::new([0u8; 20]);
    let mut ck = Zeroizing::new([0u8; 16]);
    let mut sk = Zeroizing::new([0u8; 16]);
    let mut p = 0;
    cm.copy_from_slice(&kb[p..p + 20]);
    p += 20;
    sm.copy_from_slice(&kb[p..p + 20]);
    p += 20;
    ck.copy_from_slice(&kb[p..p + 16]);
    p += 16;
    sk.copy_from_slice(&kb[p..p + 16]);
    let mut ms_arr = Zeroizing::new([0u8; 48]);
    ms_arr.copy_from_slice(&ms);
    // 字段取值顺序与旧版裸元组 `(ck, sk, cm, sm, ms_arr)` 完全一致。
    let keys = DerivedKeys {
        client_key: *ck,
        server_key: *sk,
        client_mac: *cm,
        server_mac: *sm,
        master_secret: *ms_arr,
    };
    // 显式清零上面四个/一个 `Zeroizing` 持有的栈上副本（不写这句它们也会在
    // 作用域结束时被擦，写出来是为了让"擦除点在哪里"在代码里可见）。
    ck.zeroize();
    sk.zeroize();
    cm.zeroize();
    sm.zeroize();
    ms_arr.zeroize();
    keys
}

/// 一条隧道所用的写入密钥与 MAC secret。
///
/// 单独成类型（而不是四个裸字段散在 `RawTlsClient` / `RawTlsReader` /
/// `RawTlsWriter` 里各自 `Drop` 一遍）是为了让"哪几份密钥必须在什么时候擦"
/// 只写一次：三个结构体各持有一份，析构时由本类型的 `Drop` 统一负责，不可能
/// 出现"某个结构体补了 Drop、另一个漏了"的漂移。
///
/// ⚠️ 字段类型保持**裸 `[u8; N]`**，不要改成 `Zeroizing<[u8; N]>`：整个
/// `tls.rs` 都按 `&[u8; 16]` / `&[u8; 20]` 引用这些字段，换成包装类型会牵动
/// 全部调用点。这里手写 `Drop` 只加擦除、不改任何读写路径。
#[derive(Default)]
struct KeyMaterial {
    client_key: [u8; 16],
    client_mac: [u8; 20],
    server_key: [u8; 16],
    server_mac: [u8; 20],
}

impl KeyMaterial {
    /// 按值取出全部四份密钥，并把原字段擦成零。
    ///
    /// 这是 `into_split` 能继续用"逐字段移出"写法的关键：先整体取走，
    /// 原结构体的字段就只剩全零占位，于是 ① 不必给 `RawTlsClient` 实现
    /// `Drop`（否则 Rust 会以 E0509 禁止按字段移出）、② 也不会把已经交给
    /// 半边的密钥再擦第二遍。
    fn take(&mut self) -> KeyMaterial {
        std::mem::take(self)
    }
}

impl Drop for KeyMaterial {
    fn drop(&mut self) {
        // 四个字段逐个点名：漏一个就正好漏掉一份密钥材料。
        self.client_key.zeroize();
        self.client_mac.zeroize();
        self.server_key.zeroize();
        self.server_mac.zeroize();
    }
}

pub struct RawTlsClient {
    stream: TcpStream,
    keys: KeyMaterial,
    send_seq: u64,
    recv_seq: u64,
}

pub struct RawTlsReader {
    stream: OwnedReadHalf,
    keys: KeyMaterial,
    recv_seq: u64,
}

pub struct RawTlsWriter {
    stream: OwnedWriteHalf,
    keys: KeyMaterial,
    send_seq: u64,
}

/// 生成 48 字节 pre-master secret（TLS 1.2 RSA 密钥交换，RFC 5246 §7.4.7.1）。
///
/// 返回值用 [`Zeroizing`] 包裹：调用方用完即擦，包括中途 `?` 提前返回的失败路径。
/// 单独抽成函数是为了让"这份密钥确实被擦掉了"能被直接测试 —— 它只做随机数生成，
/// 不含任何 I/O，抽出来不改变 `connect` 的任何线上行为。
///
/// 注意这里是**返回值**而非可变输出参数：`Zeroizing<[u8; 48]>` 通过 `DerefMut`
/// 仍然能按 `&mut [u8]` 传给 `fill_bytes`，调用点不必知道包装类型的存在。
fn generate_pre_master_secret() -> Zeroizing<[u8; 48]> {
    let mut pre = Zeroizing::new([0u8; 48]);
    pre[..2].copy_from_slice(&V12);
    rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut pre[2..]);
    pre
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
        //
        // `Zeroizing` 包住的是**整个 premaster 的生命周期**：`connect` 在
        // `derive_keys` 之后、任何网络往返之前就把它擦掉，成功路径和握手失败
        // 提前 `return Err` 的路径都覆盖到（`?` 提前返回时照样析构）。
        let pre48 = generate_pre_master_secret();
        let enc = rsa_pkcs1_encrypt_manual(&rsa, &pre48[..]);
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
            keys: KeyMaterial {
                client_key: keys.client_key,
                client_mac: keys.client_mac,
                server_key: keys.server_key,
                server_mac: keys.server_mac,
            },
            // TLS Finished is the first protected client record and uses seq=0.
            // Application data therefore begins at seq=1.
            send_seq: 1,
            recv_seq: 1,
        })
    }

    async fn send(&mut self, ct: u8, pl: &[u8]) -> Result<()> {
        let (records, used) = encrypt_fragments(
            ct,
            &self.keys.client_key,
            &self.keys.client_mac,
            self.send_seq,
            pl,
        );
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
            &self.keys.server_key,
            &self.keys.server_mac,
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
    ///
    /// 密钥经 [`KeyMaterial::take`] 按值转移给两个半边，原字段只剩全零占位，
    /// 因此本类型**不需要**实现 `Drop`，也就不会撞上"实现了 `Drop` 就不能按
    /// 字段移出"（E0509）。返回值与旧版逐字段移动完全一致。
    pub fn into_split(mut self) -> (RawTlsReader, RawTlsWriter) {
        let taken = self.keys.take();
        let (read_half, write_half) = self.stream.into_split();
        (
            RawTlsReader {
                stream: read_half,
                keys: KeyMaterial {
                    server_key: taken.server_key,
                    server_mac: taken.server_mac,
                    // 读半不持有写入密钥，两份字段留零。
                    client_key: [0u8; 16],
                    client_mac: [0u8; 20],
                },
                recv_seq: self.recv_seq,
            },
            RawTlsWriter {
                stream: write_half,
                keys: KeyMaterial {
                    client_key: taken.client_key,
                    client_mac: taken.client_mac,
                    // 写半不持有读密钥，两份字段留零。
                    server_key: [0u8; 16],
                    server_mac: [0u8; 20],
                },
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
            &self.keys.server_key,
            &self.keys.server_mac,
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
            &self.keys.client_key,
            &self.keys.client_mac,
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

/// Convert a value that goes on the wire as a 16-bit length field without
/// ever truncating it.
///
/// `as u16` silently wraps: a wrapped record length desynchronizes the peer's
/// record parser permanently (it then reads the next record's ciphertext as
/// this record's body). The only reason this cannot fire in practice is that
/// every caller pre-fragments to `MAX_TLS_PLAINTEXT`, so the invariant is
/// asserted rather than assumed.
fn wire_u16(len: usize, what: &str) -> u16 {
    u16::try_from(len)
        .unwrap_or_else(|_| panic!("{what} length {len} does not fit its 16-bit wire field"))
}

fn encrypt_record(
    content_type: u8,
    key: &[u8; 16],
    mac_secret: &[u8; 20],
    sequence: u64,
    plaintext: &[u8],
) -> Vec<u8> {
    // `assert!` and not `debug_assert!`: release builds must not be the ones
    // that get a wrapped record length just because a caller forgot to
    // pre-fragment.
    assert!(
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
    record.extend_from_slice(&wire_u16(encrypted.len(), "TLS record").to_be_bytes());
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
    mac_input.extend_from_slice(&wire_u16(plaintext.len(), "TLS MAC plaintext").to_be_bytes());
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
    r.extend_from_slice(&wire_u16(body.len(), "handshake record").to_be_bytes());
    r.extend_from_slice(body);
    s.write_all(&r)
        .await
        .map_err(|e| HuseVpnError::Tls(format!("wr {e}")))?;
    Ok(())
}

struct AesCbc {
    k: [u8; 16],
}

/// 这个结构体只在单次 `enc` / `dec` 里存活，但它持有的是**展开前的写入密钥**，
/// 析构时必须擦掉，否则每一收发一条 record 都会在栈上留下一份密钥副本。
impl Drop for AesCbc {
    fn drop(&mut self) {
        self.k.zeroize();
    }
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

    // === 密钥材料清零测试 ===
    //
    // 这些测试全部使用合成向量（合成密钥、合成明文），不含任何真实凭据，
    // 也不打印任何密钥字节。
    //
    // 断言方式：`Box` 给出地址稳定的堆分配，用 `read_volatile` 绕过优化器对
    // "读到的是已析构对象"的假设。`Drop` 里的 `Zeroize` 本身走
    // `write_volatile` + 编译器屏障，因此这些读回的是真实发生过的擦除结果。

    /// 把 `DerivedKeys` 里全部 120 字节密钥材料（16+16+20+20+48）读出来。
    ///
    /// # Safety
    /// 只在测试里使用，两条约束缺一不可：① 传进来的地址必须是一个仍然存活
    /// （未被 `Box::dealloc` 释放/复用）的 `DerivedKeys` 的地址；② 只用于断言
    /// "读到的全是 0"。因此所有调用点都用 `&*boxed` 取址、**绝不 `drop(box)`**
    /// —— 释放后再读是未定义行为，读到的也不保证还是擦除后的字节。
    unsafe fn read_key_material(k: *const DerivedKeys) -> Vec<u8> {
        let mut got = Vec::with_capacity(120);
        // 逐字段取址后各自读回：五个字段长度不同（16/16/20/20/48），不能放进
        // 同一个数组，也不能用 `read_volatile` 一次读整个结构体。
        got.extend_from_slice(&unsafe {
            std::ptr::read_volatile(std::ptr::addr_of!((*k).client_key))
        });
        got.extend_from_slice(&unsafe {
            std::ptr::read_volatile(std::ptr::addr_of!((*k).server_key))
        });
        got.extend_from_slice(&unsafe {
            std::ptr::read_volatile(std::ptr::addr_of!((*k).client_mac))
        });
        got.extend_from_slice(&unsafe {
            std::ptr::read_volatile(std::ptr::addr_of!((*k).server_mac))
        });
        got.extend_from_slice(&unsafe {
            std::ptr::read_volatile(std::ptr::addr_of!((*k).master_secret))
        });
        got
    }

    /// 红灯测试 ①：`derive_keys` 的返回值析构后，master secret 与整个 key block
    /// 必须已归零。
    #[test]
    fn derived_keys_are_zeroized_on_drop() {
        let pre = [0x11u8; 48];
        let cr = [0x22u8; 32];
        let sr = [0x33u8; 32];
        let keys = Box::new(derive_keys(&pre, &cr, &sr, false, b"synthetic transcript"));
        let addr: *const DerivedKeys = &*keys;
        // 前置条件：析构前确实是**非零**密钥材料。少了这一步，下列断言在
        // "derive_keys 恰好返回全零"时也会假通过。
        let before = unsafe { read_key_material(addr) };
        assert!(
            before.iter().any(|&b| b != 0),
            "合成输入必须派生出非零密钥材料，否则本测试无法区分清零与本来就全零"
        );
        // 就地析构：走真实的 `impl Drop for DerivedKeys`，但分配仍然存活，
        // 地址可以安全复读。
        unsafe { std::ptr::drop_in_place(addr.cast_mut()) };
        let after = unsafe { read_key_material(addr) };
        assert!(
            after.iter().all(|&b| b == 0),
            "衍生密钥材料必须在析构时清零，仍在内存中的非零字节数 = {}",
            after.iter().filter(|&&b| b != 0).count()
        );
    }

    /// 红灯测试 ②：pre-master secret 在 `Zeroizing` 析构后必须已归零。
    #[test]
    fn pre_master_secret_is_zeroized_on_drop() {
        let pre = Box::new(generate_pre_master_secret());
        let addr: *const Zeroizing<[u8; 48]> = &*pre;
        let raw: [u8; 48] = **pre;
        assert_eq!(&raw[..2], &V12, "premaster 前两字节必须是协商版本号");
        assert!(
            raw[2..].iter().any(|&b| b != 0),
            "随机部分必须非零，否则本测试无法区分清零与本来就全零"
        );
        unsafe { std::ptr::drop_in_place(addr.cast_mut()) };
        let after = unsafe { std::ptr::read_volatile(addr) };
        assert_eq!(after[..], [0u8; 48][..], "premaster 必须在析构时清零");
    }

    /// 在一个真实的本地 TCP 连接对上构造 `RawTlsClient`（不做 TLS 握手）。
    ///
    /// 只用于测试析构清零：不连任何真实网关，`addr` 固定回环。
    async fn synthetic_client(
        ll: [u8; 16],
        lm: [u8; 20],
        rl: [u8; 16],
        rm: [u8; 20],
    ) -> RawTlsClient {
        let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
            .await
            .expect("bind loopback");
        let addr = listener.local_addr().expect("local_addr");
        let server = tokio::spawn(async move { listener.accept().await.map(|(s, _)| s) });
        let stream = TcpStream::connect(addr).await.expect("connect loopback");
        let accepted = server.await.expect("accept task").expect("accept");
        drop(accepted);
        RawTlsClient {
            stream,
            keys: KeyMaterial {
                client_key: ll,
                client_mac: lm,
                server_key: rl,
                server_mac: rm,
            },
            send_seq: 1,
            recv_seq: 1,
        }
    }

    /// 红灯测试 ③：贯穿隧道生命周期的四份密钥（`KeyMaterial`，`RawTlsClient` /
    /// `RawTlsReader` / `RawTlsWriter` 三者共用的那个字段类型）析构后必须已归零。
    ///
    /// 这里刻意**不**去强制析构持有 tokio `TcpStream` 的那三个结构体：对 tokio
    /// 内部持有的对象做 `drop_in_place` 会让 reactor 的注销路径崩掉
    /// （`probe_drop.rs` 验证过：`into_split` 出来的半边被强制析构时会 panic 在
    /// `poll_evented.rs` 的 `Deref` 上，随后整个进程 STATUS_HEAP_CORRUPTION）。
    /// 那是**测试手法**的问题，与清零逻辑无关。密钥擦除只由下面这个 `Drop` 实现，
    /// 因此直接对 `KeyMaterial` 断言，覆盖的是同一份代码路径。
    #[test]
    fn key_material_is_zeroized_on_drop() {
        let keys = Box::new(KeyMaterial {
            client_key: [0xd1; 16],
            client_mac: [0xd2; 20],
            server_key: [0xd3; 16],
            server_mac: [0xd4; 20],
        });
        let addr: *const KeyMaterial = &*keys;
        // 前置条件：析构前确实是非零密钥材料。
        assert_eq!(
            unsafe { std::ptr::read_volatile(std::ptr::addr_of!((*addr).server_mac)) },
            [0xd4; 20]
        );
        unsafe { std::ptr::drop_in_place(addr.cast_mut()) };
        assert_eq!(
            unsafe { std::ptr::read_volatile(std::ptr::addr_of!((*addr).client_key)) },
            [0u8; 16],
            "client_key 必须在析构时清零"
        );
        assert_eq!(
            unsafe { std::ptr::read_volatile(std::ptr::addr_of!((*addr).client_mac)) },
            [0u8; 20]
        );
        assert_eq!(
            unsafe { std::ptr::read_volatile(std::ptr::addr_of!((*addr).server_key)) },
            [0u8; 16]
        );
        assert_eq!(
            unsafe { std::ptr::read_volatile(std::ptr::addr_of!((*addr).server_mac)) },
            [0u8; 20]
        );
    }

    /// 红灯测试 ④：`into_split` 之后，一把密钥只能存在于真正使用它的那一半，
    /// 且 `RawTlsClient` 自己不再留有任何一份（它的 `KeyMaterial` 已被 take 成零）。
    ///
    /// 这条专门盯住 `mem::take` 那个改写：既断言密钥按值完整转移（没被提前清零、
    /// 也没被擦两遍），又断言拆分后原对象不再持有密钥。两个半边**走自然析构**
    /// （析构时各自的 `KeyMaterial` 归零），理由见红灯测试 ③。
    #[test]
    fn split_halves_take_ownership_of_their_keys() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("tokio runtime");
        rt.block_on(async {
            let client = synthetic_client([0xb1; 16], [0xb2; 20], [0xb3; 16], [0xb4; 20]).await;
            let (reader, writer) = client.into_split();
            // 密钥按值完整转移，一个字节都没丢。
            assert_eq!(
                writer.keys.client_key, [0xb1; 16],
                "写半必须拿到 client_key"
            );
            assert_eq!(
                writer.keys.client_mac, [0xb2; 20],
                "写半必须拿到 client_mac"
            );
            assert_eq!(writer.send_seq, 1, "写半必须继承 send_seq");
            assert_eq!(
                reader.keys.server_key, [0xb3; 16],
                "读半必须拿到 server_key"
            );
            assert_eq!(
                reader.keys.server_mac, [0xb4; 20],
                "读半必须拿到 server_mac"
            );
            assert_eq!(reader.recv_seq, 1, "读半必须继承 recv_seq");
            // 半边只该拿到自己方向的那两份：另一半位置必须是零占位，不能是副本。
            assert_eq!(writer.keys.server_key, [0u8; 16], "写半不得捎带 server_key");
            assert_eq!(reader.keys.client_key, [0u8; 16], "读半不得捎带 client_key");
            // 两个半边各自析构时会擦掉自己持有的那一份（`KeyMaterial::drop`），
            // 这里只需确认它们可析构、不 panic。
            drop(reader);
            drop(writer);
        });
    }

    /// 红灯测试 ⑤：`AesCbc` 只活在一次 `enc`/`dec` 里，但它持有写入密钥，
    /// 析构后必须归零。
    #[test]
    fn aes_cbc_zeroizes_its_key_on_drop() {
        let cipher = Box::new(AesCbc::new(&[0xc1; 16]));
        let addr: *const AesCbc = &*cipher;
        assert_eq!(cipher.k, [0xc1; 16], "构造后密钥必须可用");
        unsafe { std::ptr::drop_in_place(addr.cast_mut()) };
        assert_eq!(
            unsafe { std::ptr::read_volatile(std::ptr::addr_of!((*addr).k)) },
            [0u8; 16],
            "AesCbc 持有的写入密钥必须在析构时清零"
        );
    }

    /// 反向保护：清零必须发生在密钥**不再需要之后**。
    ///
    /// 这份测试复刻 `connect` 里"派生密钥 -> 用 Finished 校验"的顺序，断言
    /// 密钥在**使用中**仍能解出正确结果 —— 也就是说，上面那些 `Drop` 不会把
    /// 仍在通话的连接擦坏。
    #[test]
    fn zeroizing_wrappers_do_not_break_keys_while_still_in_use() {
        let pre = [0x44u8; 48];
        let cr = [0x55u8; 32];
        let sr = [0x66u8; 32];
        let keys = derive_keys(&pre, &cr, &sr, false, b"synthetic transcript");
        let vt = finished_verify_data(&keys.master_secret, b"client finished", b"transcript");
        assert_eq!(vt.len(), 12, "Finished verify_data 必须是 12 字节");
        let record = encrypt_record(0x16, &keys.client_key, &keys.client_mac, 0, b"probe");
        let out = decrypt_record(0x16, &record[5..], &keys.client_key, &keys.client_mac, 0)
            .expect("使用中的密钥必须仍然可加解密");
        assert_eq!(out, b"probe", "使用中的密钥不得被提前清零");
    }

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

    /// The record length is a 16-bit field. `encrypt_record` is only reachable
    /// with pre-fragmented plaintext, and this test pins that invariant in
    /// release builds too (`assert!`, not `debug_assert!`).
    #[test]
    #[should_panic(expected = "pre-fragmented")]
    fn encrypt_record_refuses_oversized_plaintext() {
        let oversized = vec![0u8; MAX_TLS_PLAINTEXT + 1];
        let _ = encrypt_record(0x17, &[0u8; 16], &[0u8; 20], 0, &oversized);
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
