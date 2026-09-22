#![cfg(target_os = "android")]
#![allow(clippy::missing_safety_doc)]

use chrono::Local;
use huse_vpn_core::nc::NcAuthReply;
use huse_vpn_core::sac::{notify_safeupdate, SacClient, SacDiagnostics};
use huse_vpn_core::tls::RawTlsClient;
use huse_vpn_core::tunnel_android::run_android_tunnel;
use jni::objects::{JObject, JString};
use jni::sys::{jint, jstring};
use jni::JNIEnv;
use serde::Serialize;
use std::collections::BTreeSet;
use std::ffi::c_void;
use std::net::{Ipv4Addr, SocketAddr};
use std::os::fd::RawFd;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::Duration;
use tokio::runtime::Runtime;
use tokio::task::JoinHandle;
use zeroize::Zeroizing;

const SERVER: &str = "222.243.204.22:6443";

/// 原生内部异常统一映射成这个返回码；Kotlin 侧只判「非 0 即失败」。
const FFI_PANIC_CODE: jint = -99;

/// 状态序列化失败或 panic 时的兜底 JSON。
const FALLBACK_STATUS_JSON: &str = "{\"connected\":false,\"stage\":\"ffi_error\"}";

/// 在 JNI 边界捕获 panic。
///
/// 跨 JNI 展开比跨 C FFI 更致命：JVM 会直接 abort，整个 Android 应用进程立即
/// 死亡且无法上报。内部约 19 处 `.lock()`、`Runtime::new().expect()` 与
/// `SERVER.parse().expect()` 都是潜在 panic 源，因此每个导出都必须兜住并返回
/// 错误码，而不是让 panic 穿过 JNI。
///
/// **注意**：依赖 `panic = "unwind"`。若日后给 `[profile.release]` 加上
/// `panic = "abort"`，catch_unwind 会完全失效，两个方向只能选一个（见交接文档 §9.5）。
///
/// `fallback` 是闭包而非值，避免在正常路径上白白构造兜底对象。
fn ffi_guard<T>(fallback: impl FnOnce() -> T, body: impl FnOnce() -> T) -> T {
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(value) => value,
        Err(_) => fallback(),
    }
}
const REQUIRED_TARGETS: [Ipv4Addr; 4] = [
    Ipv4Addr::new(172, 19, 0, 192),
    Ipv4Addr::new(172, 19, 0, 200),
    Ipv4Addr::new(172, 20, 63, 226),
    Ipv4Addr::new(222, 243, 204, 25),
];

/// Deadline for a single setup step (SAC login, TLS connect, NC handshake).
/// Bounds worst-case connect time so a stalled Gateway always ends in a
/// terminal, user-visible failure instead of an indefinitely pending future.
const SETUP_STEP_TIMEOUT: Duration = Duration::from_secs(30);

/// 取消任务时等待旧任务真正收尾的上限。
///
/// `.abort()` 只是**异步请求**取消：被取消的任务要再被 poll 一次才会释放 TLS
/// 会话、TUN 等资源（对已经挂起在 await 上的任务就是微秒级）。这里在启动新任务
/// 之前对旧 handle 做一次有界等待，让"取消 → 启动新任务"之间不再重叠。
///
/// 等待发生在 JNI 线程上（`nativeDisconnect` / `nativeStartTunnel` 可能由 Kotlin
/// 主线程调用），因此上限必须很小：单槽位 250ms，`stop_all` 最多三个槽位，最坏
/// 约 750ms，而常态是立即返回。超时不影响正确性 —— 代次校验会丢弃任何迟到写入。
const CANCEL_JOIN_TIMEOUT: Duration = Duration::from_millis(250);

/// 心跳正常间隔：网关会话有 15 分钟时限，60 秒续期一次留足余量。
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(60);

/// 心跳失败退避阶梯：10s → 20s → 30s 封顶，与桌面侧保持同一序列。
const HEARTBEAT_BACKOFF_STEPS: [u64; 3] = [10, 20, 30];

/// 心跳降级态阶段名。Kotlin/Dart 侧按这个字符串判断"可恢复的不稳定"
/// （CampusVpnService 见到它就只更新通知、不拆隧道），不能改名。
const HEARTBEAT_ERROR_STAGE: &str = "heartbeat_error";

/// 心跳失败后的下一次等待间隔：首次失败 10s，之后 20s、30s 封顶。
fn heartbeat_backoff(consecutive_failures: u32) -> Duration {
    let last = HEARTBEAT_BACKOFF_STEPS.len() as u32 - 1;
    let index = consecutive_failures.saturating_sub(1).min(last) as usize;
    Duration::from_secs(HEARTBEAT_BACKOFF_STEPS[index])
}

/// 心跳循环每轮等待多久：健康时 60s，失败后走退避阶梯。
fn heartbeat_delay(consecutive_failures: u32) -> Duration {
    if consecutive_failures == 0 {
        HEARTBEAT_INTERVAL
    } else {
        heartbeat_backoff(consecutive_failures)
    }
}

/// 心跳是否还应该继续运行（缺陷 2 的纯判定）。
///
/// 隧道任务已退出（`tunnel_alive == false`），或会话已被更新的
/// prepare/start_tunnel/disconnect 取代（代次不再匹配）时，心跳必须自行退出：
/// 隧道都不在了，续期既无意义，还会把 `tunnel_stopped` 覆盖回 `connected`，
/// 让 Dart 侧以为"已连接"而实际没有隧道。
///
/// ⚠️ 本 crate 整体是 `#![cfg(target_os = "android")]`，宿主机编不出任何内容，
/// 因此本文件里这几个纯逻辑函数无法在宿主机测试；等价的宿主机测试在
/// `desktop/src-tauri/src/commands.rs` 的 `tests` 模块（由 `ffi/src/lib.rs`
/// 经 `#[path]` 引入后运行）。两边必须保持同一实现。
fn heartbeat_should_continue(generation_is_current: bool, tunnel_alive: bool) -> bool {
    generation_is_current && tunnel_alive
}

/// 心跳在"续期恢复"时是否允许改写 stage。
///
/// 只认我们自己写下的阶段（正常态 `connected` 与心跳降级态
/// `heartbeat_error`）；`tunnel_stopped` / `idle` / 各类 `*_error` 都是别处给出
/// 的终态，绝不能被心跳改写回去。
fn heartbeat_may_restore_stage(stage: &str) -> bool {
    stage == "connected" || stage == HEARTBEAT_ERROR_STAGE
}

/// 会话代次（缺陷 1）。
///
/// 每次 prepare/start_tunnel/disconnect 真正开始推进时 `begin()` 递增一次。
/// 后台任务（准备、隧道、心跳）启动时记下自己的代次，**任何一次 status 写入
/// 之前**都先复核该代次是否仍是当前值；不匹配说明会话已被更新的流程取代 ——
/// 丢弃这次写入并退出。
///
/// 旧实现取消时只 `.abort()` 就立刻启动新任务。abort 只是异步请求取消：被取消
/// 的任务要再被 poll 一次才真正结束，在那一瞬间它仍可能把新会话的 status 覆盖
/// 成旧值（表现：UI 显示"已连接"但隧道已换，或状态在旧值/新值之间跳）。代次
/// 校验让旧任务永远无法污染新会话状态。
#[derive(Debug)]
struct Generation(AtomicU64);

impl Generation {
    fn new() -> Self {
        Self(AtomicU64::new(0))
    }

    /// 开启一个会话，返回属于它的代次（严格递增）。
    fn begin(&self) -> u64 {
        self.0.fetch_add(1, Ordering::SeqCst) + 1
    }

    fn is_current(&self, generation: u64) -> bool {
        self.0.load(Ordering::SeqCst) == generation
    }
}

/// 取状态锁并容忍中毒：持锁线程 panic 过不代表数据已损坏。
fn lock_status(status: &Mutex<MobileStatus>) -> MutexGuard<'_, MobileStatus> {
    status
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn lock_task(slot: &Mutex<Option<JoinHandle<()>>>) -> MutexGuard<'_, Option<JoinHandle<()>>> {
    slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

struct PendingSession {
    tls: Option<RawTlsClient>,
    reply: NcAuthReply,
    ticket: [u8; 32],
    username: String,
}

struct MobileState {
    status: Mutex<MobileStatus>,
    /// 会话代次：见 `Generation`。
    generation: Generation,
    /// 隧道任务是否仍在运行。隧道退出时置 false，心跳循环据此自行退出。
    tunnel_alive: AtomicBool,
    operation: Mutex<Option<JoinHandle<()>>>,
    tunnel: Mutex<Option<JoinHandle<()>>>,
    heartbeat: Mutex<Option<JoinHandle<()>>>,
    session: Mutex<Option<PendingSession>>,
}

impl MobileState {
    fn new() -> Self {
        Self {
            status: Mutex::new(MobileStatus::default()),
            generation: Generation::new(),
            tunnel_alive: AtomicBool::new(false),
            operation: Mutex::new(None),
            tunnel: Mutex::new(None),
            heartbeat: Mutex::new(None),
            session: Mutex::new(None),
        }
    }
}

struct MobileHost {
    runtime: Runtime,
    state: Arc<MobileState>,
}

static INSTANCE: OnceLock<MobileHost> = OnceLock::new();

fn instance() -> &'static MobileHost {
    INSTANCE.get_or_init(|| MobileHost {
        runtime: Runtime::new().expect("HUSE mobile VPN runtime initialization failed"),
        state: Arc::new(MobileState::new()),
    })
}

#[derive(Debug, Clone, Serialize)]
struct MobileStatus {
    connected: bool,
    stage: String,
    message: String,
    username: Option<String>,
    virtual_ip: Option<String>,
    connected_since: Option<String>,
    routes: Vec<String>,
    required_route_count: usize,
    sac: Option<SacDiagnostics>,
    error: Option<String>,
    /// Non-fatal problem worth surfacing (e.g. the Gateway's session
    /// notification failed). Deliberately separate from `error` so a partially
    /// degraded but usable tunnel is not reported as a hard failure.
    warning: Option<String>,
}

impl Default for MobileStatus {
    fn default() -> Self {
        Self {
            connected: false,
            stage: "idle".into(),
            message: "等待学校加速器账号".into(),
            username: None,
            virtual_ip: None,
            connected_since: None,
            routes: Vec::new(),
            required_route_count: REQUIRED_TARGETS.len(),
            sac: None,
            error: None,
            warning: None,
        }
    }
}

/// 取消一个任务槽位，并对旧 handle 做一次**有界**等待。
///
/// 取消不能只是 `.abort()`：那只是异步请求，被取消的任务要再被 poll 一次才会
/// 真正收尾。这里等到它结束（或超时）再返回，让调用方可以立刻安全地启动新
/// 任务。`block_on` 要求在运行时之外调用 —— 这些函数只从 JNI 导出进入，都在
/// Kotlin 的 worker 线程上，满足该前提。
fn cancel_task(host: &'static MobileHost, slot: &Mutex<Option<JoinHandle<()>>>) {
    let task = lock_task(slot).take();
    if let Some(task) = task {
        task.abort();
        host.runtime.block_on(async {
            let _ = tokio::time::timeout(CANCEL_JOIN_TIMEOUT, task).await;
        });
    }
}

fn stop_all(host: &'static MobileHost) {
    // 先宣告隧道已死：即使后面的 abort/等待还没跑完，运行中的心跳下一轮也会
    // 自行退出，不会继续续期或把 tunnel_stopped 覆盖回 connected。
    host.state.tunnel_alive.store(false, Ordering::SeqCst);
    cancel_task(host, &host.state.operation);
    cancel_task(host, &host.state.tunnel);
    cancel_task(host, &host.state.heartbeat);
    host.state
        .session
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .take();
}

/// 后台任务持有的会话写入句柄：把「代次校验」和「status 写入」绑在一起，让
/// "写入前先确认自己仍是当前会话"成为唯一入口，而不是指望每个调用点自觉。
#[derive(Clone)]
struct SessionWriter {
    state: Arc<MobileState>,
    id: u64,
}

impl SessionWriter {
    fn new(state: Arc<MobileState>, id: u64) -> Self {
        Self { state, id }
    }

    /// 自己是否仍属于当前会话。
    fn is_current(&self) -> bool {
        self.state.generation.is_current(self.id)
    }

    /// 代次校验通过才写入；过期写入被静默丢弃并返回 false。
    ///
    /// 校验与写入必须在同一把锁下完成：若"先校验、后取锁"，`begin()` 就能在
    /// 两者之间插入，旧任务仍可抢在新会话之后写入（TOCTOU）。
    fn write(&self, update: impl FnOnce(&mut MobileStatus)) -> bool {
        let mut status = lock_status(&self.state.status);
        if !self.is_current() {
            return false;
        }
        update(&mut status);
        true
    }

    fn set_stage(&self, stage: &str, message: &str) -> bool {
        self.write(|status| {
            status.stage = stage.to_string();
            status.message = message.to_string();
            status.error = None;
            // A new stage belongs to a new attempt: do not carry a previous
            // attempt's non-fatal warning into a later, unrelated stage.
            status.warning = None;
        })
    }

    fn fail(&self, username: &str, stage: &str, error: impl Into<String>) -> bool {
        self.write(|status| {
            status.connected = false;
            status.stage = stage.to_string();
            status.message = "连接未完成".into();
            status.username = Some(username.to_string());
            status.error = Some(error.into());
        })
    }
}

fn spawn_prepare(
    host: &'static MobileHost,
    username: String,
    password: String,
    source: String,
    generation: u64,
) {
    let state = host.state.clone();
    let task = host.runtime.handle().spawn(async move {
        prepare_inner(username, password, source, state, generation).await;
    });
    *lock_task(&host.state.operation) = Some(task);
}

async fn prepare_inner(
    username: String,
    password: String,
    source: String,
    state: Arc<MobileState>,
    generation: u64,
) {
    let session = SessionWriter::new(state.clone(), generation);
    let address: SocketAddr = match SERVER.parse() {
        Ok(address) => address,
        Err(error) => {
            session.fail(&username, "sac_error", format!("Gateway 地址无效: {error}"));
            return;
        }
    };

    session.set_stage("sac", "正在通过学校加速器网关进行原生认证");
    let sac_client = SacClient::new(address);
    let password = Zeroizing::new(password);
    // Every setup step needs its own deadline: without one, a half-open Gateway
    // socket leaves the whole connect future pending forever, so the UI spinner
    // spins, silent re-auth never finishes, and the Android foreground service
    // can never report a terminal state.
    let login = match tokio::time::timeout(
        SETUP_STEP_TIMEOUT,
        sac_client.login_with_source(&username, password.as_str(), Some(&source)),
    )
    .await
    {
        Ok(value) => value,
        Err(_) => {
            drop(password);
            session.fail(&username, "sac_error", "Gateway authentication timed out");
            return;
        }
    };
    drop(password);
    let (sac_login, diagnostics) = match login {
        Ok(value) => value,
        Err(error) => {
            session.fail(&username, "sac_error", error.to_string());
            return;
        }
    };
    session.write(|status| status.sac = Some(diagnostics));

    let ticket = sac_login.ticket;
    session.set_stage("session", "正在向网关发送 GET_USERDATA 建立登录会话");
    let hardware_addresses = local_hardware_addresses();
    let userdata = sac_client.get_userdata(&ticket, &hardware_addresses).await;
    let (request_len, response_len, result) = match userdata {
        Ok(value) => value,
        Err(error) => {
            session.fail(&username, "session_error", error.to_string());
            return;
        }
    };
    session.write(|status| {
        if let Some(sac) = status.sac.as_mut() {
            sac.get_userdata_request_len = Some(request_len);
            sac.get_userdata_response_len = Some(response_len);
            sac.get_userdata_result = Some(result);
        }
    });
    if result != 0 {
        session.fail(
            &username,
            "session_error",
            format!("Gateway GET_USERDATA rejected session setup with status 0x{result:08x}"),
        );
        return;
    }

    session.set_stage("tls", "正在建立网关 TLS 数据通道");
    let mut tls =
        match tokio::time::timeout(SETUP_STEP_TIMEOUT, RawTlsClient::connect(address)).await {
            Ok(Ok(value)) => value,
            Ok(Err(error)) => {
                session.fail(&username, "tls_error", error.to_string());
                return;
            }
            Err(_) => {
                session.fail(&username, "tls_error", "Gateway TLS handshake timed out");
                return;
            }
        };
    session.set_stage("nc_auth", "正在使用 NC Ticket 请求虚拟 IP");
    match tokio::time::timeout(SETUP_STEP_TIMEOUT, tls.send_nc_auth(&ticket, &username)).await {
        Ok(Ok(())) => {}
        Ok(Err(error)) => {
            session.fail(&username, "nc_error", error.to_string());
            return;
        }
        Err(_) => {
            session.fail(&username, "nc_error", "NC auth request timed out");
            return;
        }
    }
    if let Err(error) = notify_safeupdate(address, &ticket).await {
        // The Gateway's session notification is required for forwarding on some
        // deployments. It is not fatal to keep connecting (the tunnel may still
        // work), but silently logging hid a possible "connected but no traffic"
        // state — record it as a surfaced warning instead.
        eprintln!("HUSE mobile VPN session notification failed: {error}");
        session.write(|status| {
            status.warning = Some(format!(
                "Gateway session notification failed; forwarding may be unavailable: {error}"
            ));
        });
    }
    let reply = match tokio::time::timeout(SETUP_STEP_TIMEOUT, tls.read_nc_auth_reply()).await {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => {
            session.fail(&username, "nc_error", error.to_string());
            return;
        }
        Err(_) => {
            session.fail(&username, "nc_error", "NC auth reply timed out");
            return;
        }
    };
    if reply.virtual_ip.parse::<Ipv4Addr>().is_err() {
        session.fail(
            &username,
            "nc_error",
            "Gateway returned an invalid virtual IPv4 address",
        );
        return;
    }

    // 会话已被更新的 prepare/disconnect 取代：绝不为一个已作废的尝试安装
    // pending 会话（否则旧的 TLS 会话可能被新流程拿去建隧道）。
    if !session.is_current() {
        return;
    }
    let routes = route_prefixes(&reply);
    let virtual_ip = reply.virtual_ip.clone();
    *state
        .session
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(PendingSession {
        tls: Some(tls),
        reply,
        ticket,
        username: username.clone(),
    });
    session.write(|status| {
        status.connected = false;
        status.stage = "awaiting_tun".into();
        status.message = "学校加速器认证完成，正在请求 Android 系统网络授权".into();
        status.username = Some(username);
        status.virtual_ip = Some(virtual_ip);
        status.routes = routes;
        status.required_route_count = REQUIRED_TARGETS.len();
        status.error = None;
    });
}

fn start_tunnel(host: &'static MobileHost, tun_fd: RawFd) -> i32 {
    if tun_fd < 0 {
        return -1;
    }
    let Some(mut pending) = host
        .state
        .session
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .take()
    else {
        return -2;
    };
    let Some(tls) = pending.tls.take() else {
        return -3;
    };
    // 先停掉可能仍在运行的旧隧道/心跳：它们的 handle 若被直接覆盖就再也没人
    // 管，旧隧道会继续持有 TUN 与路由，并继续往新会话的状态里写东西。
    host.state.tunnel_alive.store(false, Ordering::SeqCst);
    cancel_task(host, &host.state.tunnel);
    cancel_task(host, &host.state.heartbeat);
    // 新会话：代次递增，上一代任务的写入从此刻起被丢弃。
    let generation = host.state.generation.begin();
    let reply = pending.reply;
    let ticket = pending.ticket;
    let username = pending.username;
    let routes = route_prefixes(&reply);
    let virtual_ip = reply.virtual_ip.clone();
    let state = host.state.clone();
    let tunnel_session = SessionWriter::new(state.clone(), generation);

    // 隧道即将运行：心跳的存活判定从此刻起有效（必须在 spawn 之前置位，否则
    // 立刻失败的隧道任务可能先把它置回 false，被这里覆盖成"仍然存活"）。
    host.state.tunnel_alive.store(true, Ordering::SeqCst);
    let tunnel_task = host.runtime.handle().spawn(async move {
        let result = run_android_tunnel(tls, tun_fd).await;
        // 隧道结束：先让存活判定说真话，再写终态（写入仍受代次校验保护）。
        state.tunnel_alive.store(false, Ordering::SeqCst);
        let error = match result {
            Ok(()) => "Android 加速器隧道已停止".to_string(),
            Err(error) => error.to_string(),
        };
        tunnel_session.write(|status| {
            status.connected = false;
            status.stage = "tunnel_stopped".into();
            status.error = Some(error);
        });
        // 主动取消心跳（缺陷 2）：隧道都没了还继续续期，会把 tunnel_stopped
        // 覆盖回 connected，Dart 侧就会以为"已连接"而实际没有隧道。
        let heartbeat = lock_task(&state.heartbeat).take();
        if let Some(heartbeat) = heartbeat {
            heartbeat.abort();
            let _ = heartbeat.await;
        }
    });
    // 记下隧道 handle：后续的 prepare/disconnect 才能取消它并等待收尾。
    *lock_task(&host.state.tunnel) = Some(tunnel_task);

    let heartbeat_state = host.state.clone();
    let heartbeat = host.runtime.handle().spawn(async move {
        let client = SacClient::new(SERVER.parse().expect("valid Gateway address"));
        // 学校网关的会话有 **15 分钟**时限（用户实测），心跳就是用来续期的。
        //
        // ⚠️ 旧实现：心跳失败一次就 `break` 永久退出循环，且只把状态写成
        // `heartbeat_error` 而不通知任何人 —— 结果网关到期踢人之后，客户端
        // 再也不会心跳，只能等 Dart 侧 60 秒健康检查慢慢发现，用户感知就是
        // "用着用着就掉了，而且要等很久才恢复"。
        //
        // 现在：失败不再退出循环，而是记录 `heartbeat_error` 让 Dart 侧能
        // **立刻**看到并触发重认证；同时继续按退避重试，万一只是瞬时抖动，
        // 续期成功就把状态恢复成正常，不需要任何重连。
        let heartbeat_session = SessionWriter::new(heartbeat_state.clone(), generation);
        let mut consecutive_failures: u32 = 0;
        loop {
            // 正常 60 秒一次；连续失败时按 10s → 20s → 30s 退避，尽快恢复续期。
            tokio::time::sleep(heartbeat_delay(consecutive_failures)).await;

            // 每轮复核隧道是否还活着（缺陷 2）：隧道任务已退出，或会话已被
            // 更新的 prepare/start_tunnel/disconnect 取代，就自行退出，绝不
            // 继续为一个已经消失的隧道续期。
            if !heartbeat_should_continue(
                heartbeat_session.is_current(),
                heartbeat_state.tunnel_alive.load(Ordering::SeqCst),
            ) {
                break;
            }

            match client.heartbeat(&ticket).await {
                Ok(()) => {
                    if consecutive_failures > 0 {
                        // 续期恢复：只在阶段仍是我们写下的降级态时改回正常，
                        // tunnel_stopped 等终态绝不能被心跳改写。
                        heartbeat_session.write(|status| {
                            if heartbeat_may_restore_stage(&status.stage) {
                                status.stage = "connected".into();
                                status.error = None;
                            }
                        });
                        eprintln!(
                            "HUSE VPN heartbeat recovered after {consecutive_failures} failures"
                        );
                    }
                    consecutive_failures = 0;
                }
                Err(error) => {
                    consecutive_failures = consecutive_failures.saturating_add(1);
                    heartbeat_session.write(|status| {
                        // 只有仍标记为连接中时才写错误，避免覆盖 tunnel_stopped
                        // 等更准确的原因。
                        if status.connected || heartbeat_may_restore_stage(&status.stage) {
                            status.stage = HEARTBEAT_ERROR_STAGE.into();
                            status.error = Some(error.to_string());
                        }
                    });
                    eprintln!(
                        "HUSE VPN heartbeat failed ({consecutive_failures} consecutive), retrying in {:?}",
                        heartbeat_backoff(consecutive_failures)
                    );
                }
            }
        }
    });
    *lock_task(&host.state.heartbeat) = Some(heartbeat);

    let (sac, warning) = {
        let status = lock_status(&host.state.status);
        // Preserve a non-fatal warning raised during setup (e.g. the Gateway
        // session notification failed): it must survive the transition to
        // connected, otherwise "connected but forwarding may be unavailable"
        // is silently indistinguishable from a healthy tunnel.
        (status.sac.clone(), status.warning.clone())
    };
    // 代次校验通过才写：若并发的 prepare 已经开启新会话，这次写入必须被丢弃。
    SessionWriter::new(host.state.clone(), generation).write(|status| {
        *status = MobileStatus {
            connected: true,
            stage: "connected".into(),
            message: "校园内网隧道已建立".into(),
            username: Some(username),
            virtual_ip: Some(virtual_ip),
            connected_since: Some(Local::now().format("%Y-%m-%d %H:%M:%S").to_string()),
            routes,
            required_route_count: REQUIRED_TARGETS.len(),
            sac,
            error: None,
            warning,
        };
    });
    0
}

fn route_prefixes(reply: &NcAuthReply) -> Vec<String> {
    let mut prefixes = BTreeSet::new();
    for route in &reply.profile_routes {
        let address = route.address.parse::<Ipv4Addr>();
        let mask = route.netmask.parse::<Ipv4Addr>();
        if let (Ok(address), Ok(mask)) = (address, mask) {
            if let Some(prefix) = network_prefix(address, mask) {
                prefixes.insert(prefix);
            }
        }
    }
    for target in REQUIRED_TARGETS {
        prefixes.insert(format!("{target}/32"));
    }
    prefixes.into_iter().collect()
}

fn network_prefix(address: Ipv4Addr, mask: Ipv4Addr) -> Option<String> {
    let mask = u32::from(mask);
    let prefix_length = mask.leading_ones();
    if prefix_length == 0 {
        return None;
    }
    let expected = u32::MAX.checked_shl(32 - prefix_length).unwrap_or(0);
    if mask != expected {
        return None;
    }
    Some(format!(
        "{}/{}",
        Ipv4Addr::from(u32::from(address) & mask),
        prefix_length
    ))
}

fn local_hardware_addresses() -> Vec<String> {
    let mut addresses = BTreeSet::new();
    let Ok(entries) = std::fs::read_dir("/sys/class/net") else {
        return Vec::new();
    };
    for entry in entries.flatten() {
        let path = entry.path().join("address");
        let Ok(value) = std::fs::read_to_string(path) else {
            continue;
        };
        let normalized = value.trim().replace(':', "-").to_ascii_lowercase();
        if normalized.len() == 17
            && normalized.split('-').count() == 6
            && normalized
                .split('-')
                .all(|part| part.len() == 2 && part.bytes().all(|byte| byte.is_ascii_hexdigit()))
            && normalized != "00-00-00-00-00-00"
        {
            addresses.insert(normalized);
        }
    }
    addresses.into_iter().collect()
}

fn read_jstring(env: &mut JNIEnv<'_>, value: JString<'_>) -> Option<String> {
    env.get_string(&value)
        .ok()?
        .to_str()
        .ok()
        .map(ToOwned::to_owned)
}

fn to_jstring(env: JNIEnv<'_>, value: String) -> jstring {
    env.new_string(value)
        .map(|value| value.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub extern "system" fn Java_com_one_huaji_CampusVpnService_nativePrepare(
    mut env: JNIEnv<'_>,
    _this: JObject<'_>,
    username: JString<'_>,
    password: JString<'_>,
    auth_source: JString<'_>,
) -> jint {
    ffi_guard(
        || FFI_PANIC_CODE,
        || {
            let Some(username) = read_jstring(&mut env, username) else {
                return -1;
            };
            let Some(password) = read_jstring(&mut env, password) else {
                return -2;
            };
            let source = read_jstring(&mut env, auth_source).unwrap_or_else(|| "SAM-all".into());
            let host = instance();
            // 新会话：代次先递增，上一会话遗留的后台任务从此刻起再也写不进
            // 状态；随后再取消它们（abort + 有界等待收尾），两道保险。
            let generation = host.state.generation.begin();
            stop_all(host);
            SessionWriter::new(host.state.clone(), generation).write(|status| {
                *status = MobileStatus {
                    connected: false,
                    stage: "starting".into(),
                    message: "正在启动 Android 校园加速器".into(),
                    username: Some(username.clone()),
                    ..MobileStatus::default()
                };
            });
            spawn_prepare(host, username, password, source, generation);
            0
        },
    )
}

#[no_mangle]
pub extern "system" fn Java_com_one_huaji_CampusVpnService_nativeStatusJson(
    env: JNIEnv<'_>,
    _this: JObject<'_>,
) -> jstring {
    // guard 只包住「取锁 + 序列化」这段（panic 源都在这里）并返回 String；
    // to_jstring 留在 guard 外，否则 env 会被兜底闭包和主体闭包同时借用。
    let status = ffi_guard(
        || FALLBACK_STATUS_JSON.to_string(),
        || {
            serde_json::to_string(
                &*instance()
                    .state
                    .status
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner()),
            )
            .unwrap_or_else(|_| FALLBACK_STATUS_JSON.to_string())
        },
    );
    to_jstring(env, status)
}

#[no_mangle]
pub extern "system" fn Java_com_one_huaji_CampusVpnService_nativeStartTunnel(
    _env: JNIEnv<'_>,
    _this: JObject<'_>,
    tun_fd: jint,
) -> jint {
    ffi_guard(
        || FFI_PANIC_CODE,
        || start_tunnel(instance(), tun_fd as RawFd),
    )
}

#[no_mangle]
pub extern "system" fn Java_com_one_huaji_CampusVpnService_nativeDisconnect(
    _env: JNIEnv<'_>,
    _this: JObject<'_>,
) -> jint {
    ffi_guard(
        || FFI_PANIC_CODE,
        || {
            let host = instance();
            // 递增代次后停止一切：即便某个任务没能在有界等待内收尾，它的写入
            // 也已经作废，不会把默认状态覆盖成旧会话的 connected。
            let generation = host.state.generation.begin();
            stop_all(host);
            SessionWriter::new(host.state.clone(), generation)
                .write(|status| *status = MobileStatus::default());
            0
        },
    )
}

#[no_mangle]
pub extern "system" fn Java_com_one_huaji_CampusVpnService_nativeVersion(
    env: JNIEnv<'_>,
    _this: JObject<'_>,
) -> jstring {
    to_jstring(env, "huse-vpn-mobile-ffi/0.1".into())
}

// Keep the symbol's ABI explicit on Android builds. The import also prevents
// accidental removal of the JNI-facing `c_void` type when compiling with a
// stricter release profile.
#[allow(dead_code)]
fn _jni_abi_marker(_: *mut c_void) {}
