use huse_vpn_core::nc::NcAuthReply;
use huse_vpn_core::sac::{notify_safeupdate, SacClient, SacDiagnostics};
use huse_vpn_core::tls::RawTlsClient;
use huse_vpn_core::tunnel::{run_target_tunnel_with_ready, GatewayRoute};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager, State};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpSocket, TcpStream};
use zeroize::Zeroizing;

const SERVER: &str = "222.243.204.22:6443";
pub const CONTROL_PORT: u16 = 47831;
const CONTROL_TOKEN: &str = "huse-vpn-next-local-control-v1";
const CONTROL_MAX_REQUEST: usize = 64 * 1024;
// The gateway's current service list includes these two fixed campus web
// endpoints in addition to the two HUSE DNS answers used by the UI. Keep the
// list target-scoped so FlClash remains the default route for everything else.
const REQUIRED_TARGETS: [Ipv4Addr; 4] = [
    Ipv4Addr::new(172, 19, 0, 192),
    Ipv4Addr::new(172, 19, 0, 200),
    Ipv4Addr::new(172, 20, 63, 226),
    Ipv4Addr::new(222, 243, 204, 25),
];
const CAMPUS_NAVIGATION_URL: &str = "http://ns.huse.cn/";
const CAMPUS_AUTH_URL: &str = "http://self.huse.cn/selfservice/";
const CAMPUS_AUTH_IP: Ipv4Addr = Ipv4Addr::new(172, 19, 0, 200);

#[cfg(target_os = "windows")]
const CAMPUS_PROXY_BYPASS: &str = "*.huse.cn";

#[cfg(target_os = "windows")]
use std::os::windows::process::CommandExt;

#[cfg(target_os = "windows")]
const CREATE_NO_WINDOW: u32 = 0x08000000;

#[cfg(target_os = "windows")]
fn hidden_command(program: &str) -> Command {
    let mut command = Command::new(program);
    command.creation_flags(CREATE_NO_WINDOW);
    command
}

/// 心跳正常间隔：网关会话有 15 分钟时限，60 秒续期一次留足余量。
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(60);

/// 心跳失败退避阶梯：10s → 20s → 30s 封顶。
///
/// 旧实现一次瞬时失败就退出心跳循环：状态停在 `connected` / 降级态，之后再也
/// 不会续期，用户以为连着、其实网关认证早已过期。现在失败只降级不退出，并按
/// 这张阶梯退避重试；30 秒封顶保证不会退化成无限快速重试（对校园网关而言
/// 近似暴力尝试）。
const HEARTBEAT_BACKOFF_STEPS: [u64; 3] = [10, 20, 30];

/// 心跳降级态的阶段名。Kotlin/Dart 侧按这个字符串判断"可恢复的不稳定"，
/// 不能改名。
const HEARTBEAT_ERROR_STAGE: &str = "heartbeat_error";

/// 心跳失败后的下一次等待间隔：首次失败 10s，之后 20s、30s 封顶。
///
/// **纯函数**：单调不减、有上限，宿主机可直接测试（见文件末尾的测试）。
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
/// 隧道任务已退出（`tunnel_alive == false`），或会话已被更新的连接/断开取代
/// （代次不再匹配）时，心跳必须自行退出：隧道都不在了，续期既无意义，还会把
/// `tunnel_stopped` 覆盖回 `connected`，让 UI 显示"已连接"而实际没有隧道。
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
/// 每次「连接 / 断开」真正开始推进时 `begin()` 递增一次。后台任务（隧道、
/// 心跳）启动时记下自己的代次，**任何一次 status 写入之前**都先复核该代次是否
/// 仍是当前值；不匹配说明会话已被更新的流程取代 —— 丢弃这次写入并退出。
///
/// 旧实现取消时只 `.abort()` 就立刻启动新任务。abort 只是**异步请求**取消：
/// 被取消的任务要再被 poll 一次才真正结束，在那一瞬间它仍可能把新会话的
/// status 覆盖成旧值（表现就是 UI 显示"已连接"但隧道已换，或状态在旧值/新值
/// 之间来回跳）。代次校验让旧任务永远无法污染新会话状态，与取消路径的等待
/// 互为兜底。
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

    fn current(&self) -> u64 {
        self.0.load(Ordering::SeqCst)
    }

    fn is_current(&self, generation: u64) -> bool {
        self.0.load(Ordering::SeqCst) == generation
    }
}

/// 取状态锁并容忍中毒：这里是状态写入的公共入口，一次持锁 panic 不应该让后续
/// 所有状态读写都变成失败。
fn lock_status(status: &Mutex<ConnectionStatus>) -> MutexGuard<'_, ConnectionStatus> {
    status
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn lock_task(
    slot: &Mutex<Option<tokio::task::JoinHandle<()>>>,
) -> MutexGuard<'_, Option<tokio::task::JoinHandle<()>>> {
    slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// 后台任务持有的会话写入句柄：把「代次校验」和「status 写入」绑在一起，让
/// "写入前先确认自己仍是当前会话"成为唯一入口，而不是指望每个调用点自觉。
#[derive(Clone)]
struct SessionWriter {
    status: Arc<Mutex<ConnectionStatus>>,
    generation: Arc<Generation>,
    id: u64,
}

impl SessionWriter {
    /// 自己是否仍属于当前会话。
    fn is_current(&self) -> bool {
        self.generation.is_current(self.id)
    }

    /// 代次校验通过才写入；过期写入被静默丢弃并返回 false。
    ///
    /// 校验与写入必须在同一把锁下完成：若"先校验、后取锁"，`begin()` 就能在
    /// 两者之间插入，旧任务仍可抢在新会话之后写入（TOCTOU）。
    fn write(&self, update: impl FnOnce(&mut ConnectionStatus)) -> bool {
        let mut status = lock_status(&self.status);
        if !self.is_current() {
            return false;
        }
        update(&mut status);
        true
    }

    fn snapshot(&self) -> ConnectionStatus {
        lock_status(&self.status).clone()
    }

    fn set_stage(&self, stage: &str, message: &str) -> bool {
        self.write(|status| {
            status.stage = stage.to_string();
            status.message = message.to_string();
            status.error = None;
        })
    }

    fn fail(
        &self,
        username: &str,
        stage: &str,
        message: impl Into<String>,
    ) -> Result<ConnectionStatus, String> {
        let message = message.into();
        self.write(|status| {
            status.connected = false;
            status.stage = stage.to_string();
            status.message = "连接未完成".into();
            status.username = Some(username.to_string());
            status.error = Some(message.clone());
        });
        Err(message)
    }
}

pub struct VpnState {
    status: Arc<Mutex<ConnectionStatus>>,
    tunnel: Arc<Mutex<Option<tokio::task::JoinHandle<()>>>>,
    heartbeat: Arc<Mutex<Option<tokio::task::JoinHandle<()>>>>,
    /// 会话代次：见 `Generation`。用 `Arc` 是为了让后台任务也能复核它。
    generation: Arc<Generation>,
    /// 隧道任务是否仍在运行。隧道退出时置 false，心跳循环据此自行退出。
    tunnel_alive: Arc<AtomicBool>,
    /// 会话级串行锁（缺陷 4）：任意时刻只允许一个「连接 / 断开」流程推进，
    /// 避免两个并发请求同时改路由、适配器和状态。
    session: tokio::sync::Mutex<()>,
    campus_proxy_bypass_added: Mutex<bool>,
}

impl VpnState {
    pub fn new() -> Self {
        Self {
            status: Arc::new(Mutex::new(ConnectionStatus::default())),
            tunnel: Arc::new(Mutex::new(None)),
            heartbeat: Arc::new(Mutex::new(None)),
            generation: Arc::new(Generation::new()),
            tunnel_alive: Arc::new(AtomicBool::new(false)),
            session: tokio::sync::Mutex::new(()),
            campus_proxy_bypass_added: Mutex::new(false),
        }
    }

    /// 为指定代次构造会话写入句柄。
    fn writer(&self, generation: u64) -> SessionWriter {
        SessionWriter {
            status: self.status.clone(),
            generation: self.generation.clone(),
            id: generation,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct ConnectionStatus {
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
}

pub fn prepare_connect(state: &VpnState, username: &str) {
    // 只写"准备中"提示，**不**递增代次：此刻可能已经有一个连接流程在推进，
    // 递增代次会把它的状态写入全部作废（隧道照建、状态却不再更新）。写入仍走
    // 代次校验，万一中途真的有新会话开始，这次提示会被丢弃而不是污染新会话。
    state.writer(state.generation.current()).write(|status| {
        *status = ConnectionStatus {
            stage: "starting".into(),
            message: "正在启动校园 VPN".into(),
            username: Some(username.to_string()),
            ..ConnectionStatus::default()
        };
    });
}

impl Default for ConnectionStatus {
    fn default() -> Self {
        Self {
            connected: false,
            stage: "idle".into(),
            message: "等待学校 VPN 账号".into(),
            username: None,
            virtual_ip: None,
            connected_since: None,
            routes: Vec::new(),
            required_route_count: 0,
            sac: None,
            error: None,
        }
    }
}

/// 停止当前隧道与心跳，并等待它们真正收尾。
///
/// 取消是**非 joining** 的：`.abort()` 只发出取消请求，任务要再被 poll 一次才
/// 释放路由、代理与 Wintun 句柄。这里 await 旧 handle 让"取消 → 启动新任务"
/// 之间不再有重叠窗口；代次校验则兜住任何仍然迟到的写入。
async fn stop_tunnel(state: &VpnState) {
    // 先宣告隧道已死：即使后面的 abort/await 还没跑完，运行中的心跳下一轮也会
    // 自行退出，不会继续续期或把 tunnel_stopped 覆盖回 connected。
    state.tunnel_alive.store(false, Ordering::SeqCst);
    let heartbeat = lock_task(&state.heartbeat).take();
    if let Some(heartbeat) = heartbeat {
        heartbeat.abort();
        let _ = heartbeat.await;
    }
    let task = lock_task(&state.tunnel).take();
    if let Some(task) = task {
        task.abort();
        let _ = task.await;
    }
    restore_campus_proxy_bypass(state);
}

#[cfg(target_os = "windows")]
#[link(name = "wininet")]
extern "system" {
    fn InternetSetOptionW(
        internet: *mut std::ffi::c_void,
        option: u32,
        buffer: *mut std::ffi::c_void,
        buffer_length: u32,
    ) -> i32;
}

#[cfg(target_os = "windows")]
fn refresh_system_proxy_settings() {
    const INTERNET_OPTION_REFRESH: u32 = 37;
    const INTERNET_OPTION_SETTINGS_CHANGED: u32 = 39;
    unsafe {
        let _ = InternetSetOptionW(
            std::ptr::null_mut(),
            INTERNET_OPTION_SETTINGS_CHANGED,
            std::ptr::null_mut(),
            0,
        );
        let _ = InternetSetOptionW(
            std::ptr::null_mut(),
            INTERNET_OPTION_REFRESH,
            std::ptr::null_mut(),
            0,
        );
    }
}

#[cfg(target_os = "windows")]
fn read_system_proxy_override() -> Result<Option<String>, String> {
    const MISSING: &str = "__HUSE_PROXY_OVERRIDE_MISSING__";
    let script = "$value = (Get-ItemProperty -Path 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings' -Name ProxyOverride -ErrorAction SilentlyContinue).ProxyOverride; if ($null -eq $value) { [Console]::Out.Write('__HUSE_PROXY_OVERRIDE_MISSING__') } else { [Console]::Out.Write([string]$value) }";
    let output = hidden_command("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-Command", script])
        .output()
        .map_err(|error| format!("读取系统代理绕过列表失败: {error}"))?;
    if !output.status.success() {
        let detail = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(if detail.is_empty() {
            "读取系统代理绕过列表失败".into()
        } else {
            format!("读取系统代理绕过列表失败: {detail}")
        });
    }
    let value = String::from_utf8_lossy(&output.stdout)
        .trim_end_matches(['\r', '\n'])
        .to_string();
    if value == MISSING {
        Ok(None)
    } else {
        Ok(Some(value))
    }
}

#[cfg(target_os = "windows")]
fn write_system_proxy_override(value: Option<&str>) -> Result<(), String> {
    const KEY: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings";
    let output = match value {
        Some(value) => hidden_command("reg.exe")
            .args([
                "ADD",
                KEY,
                "/v",
                "ProxyOverride",
                "/t",
                "REG_SZ",
                "/d",
                value,
                "/f",
            ])
            .output(),
        None => hidden_command("reg.exe")
            .args(["DELETE", KEY, "/v", "ProxyOverride", "/f"])
            .output(),
    }
    .map_err(|error| format!("写入系统代理绕过列表失败: {error}"))?;
    if !output.status.success() {
        let detail = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(if detail.is_empty() {
            "写入系统代理绕过列表失败".into()
        } else {
            format!("写入系统代理绕过列表失败: {detail}")
        });
    }
    refresh_system_proxy_settings();
    Ok(())
}

#[cfg(target_os = "windows")]
fn contains_campus_proxy_bypass(value: &str) -> bool {
    value
        .split(';')
        .any(|entry| entry.trim().eq_ignore_ascii_case(CAMPUS_PROXY_BYPASS))
}

#[cfg(target_os = "windows")]
fn without_campus_proxy_bypass(value: &str) -> String {
    value
        .split(';')
        .filter(|entry| !entry.trim().eq_ignore_ascii_case(CAMPUS_PROXY_BYPASS))
        .collect::<Vec<_>>()
        .join(";")
}

#[cfg(target_os = "windows")]
fn enable_campus_proxy_bypass(state: &VpnState) -> Result<(), String> {
    let current = read_system_proxy_override()?;
    if current
        .as_deref()
        .map(contains_campus_proxy_bypass)
        .unwrap_or(false)
    {
        return Ok(());
    }
    let updated = match current.as_deref() {
        Some(value) if !value.is_empty() => format!("{value};{CAMPUS_PROXY_BYPASS}"),
        _ => CAMPUS_PROXY_BYPASS.to_string(),
    };
    write_system_proxy_override(Some(&updated))?;
    *state.campus_proxy_bypass_added.lock().unwrap() = true;
    eprintln!("HUSE VPN: added {CAMPUS_PROXY_BYPASS} to the system proxy bypass list");
    Ok(())
}

#[cfg(target_os = "windows")]
fn restore_campus_proxy_bypass(state: &VpnState) {
    let should_restore = {
        let mut added = state.campus_proxy_bypass_added.lock().unwrap();
        if *added {
            *added = false;
            true
        } else {
            false
        }
    };
    if !should_restore {
        return;
    }
    let result = (|| {
        let Some(current) = read_system_proxy_override()? else {
            return Ok::<(), String>(());
        };
        let updated = without_campus_proxy_bypass(&current);
        if updated == current {
            return Ok(());
        }
        if updated.is_empty() {
            write_system_proxy_override(None)
        } else {
            write_system_proxy_override(Some(&updated))
        }
    })();
    if let Err(error) = result {
        eprintln!("HUSE VPN: failed to restore system proxy bypass list: {error}");
    }
}

#[cfg(not(target_os = "windows"))]
fn enable_campus_proxy_bypass(_state: &VpnState) -> Result<(), String> {
    Ok(())
}

#[cfg(not(target_os = "windows"))]
fn restore_campus_proxy_bypass(_state: &VpnState) {}

fn find_wintun() -> Result<PathBuf, String> {
    if let Some(path) = std::env::var_os("HUSE_VPN_WINTUN") {
        let path = PathBuf::from(path);
        if path.is_file() {
            return Ok(path);
        }
    }
    let sibling = std::env::current_exe()
        .ok()
        .and_then(|path| path.parent().map(|directory| directory.join("wintun.dll")));
    if let Some(path) = sibling.filter(|path| path.is_file()) {
        return Ok(path);
    }
    Err("找不到 wintun.dll：请放到程序同目录，或设置 HUSE_VPN_WINTUN".into())
}

fn reply_routes(reply: &NcAuthReply) -> Vec<String> {
    reply
        .profile_routes
        .iter()
        .map(|route| format!("{} / {}", route.address, route.netmask))
        .collect()
}

#[tauri::command]
pub async fn connect_vpn(
    username: String,
    password: String,
    auth_source: Option<String>,
    state: State<'_, VpnState>,
) -> Result<ConnectionStatus, String> {
    connect_vpn_inner(username, password, auth_source, state.inner()).await
}

/// 连接入口（缺陷 4）：并发连接请求在这里排队，而不是同时改路由/适配器/状态。
pub async fn connect_vpn_inner(
    username: String,
    password: String,
    auth_source: Option<String>,
    state: &VpnState,
) -> Result<ConnectionStatus, String> {
    // 会话级串行锁：任意时刻只有一个连接流程推进。若已有一个连接正在认证或
    // 建适配器，本次调用会等它结束后再开始，不会出现两条流程同时改路由、
    // 适配器与状态。
    let _serial = state.session.lock().await;
    // 新会话开始：代次递增。上一会话遗留的后台任务（隧道、心跳）从这一刻起
    // 再也写不进 status —— 它们迟到的收尾写入会被 `SessionWriter` 丢弃。
    let generation = state.generation.begin();
    let session = state.writer(generation);
    connect_session(username, password, auth_source, state, session).await
}

/// 在会话锁保护下推进一次连接。
async fn connect_session(
    username: String,
    password: String,
    auth_source: Option<String>,
    state: &VpnState,
    session: SessionWriter,
) -> Result<ConnectionStatus, String> {
    stop_tunnel(state).await;
    let password = Zeroizing::new(password);
    let source_label = auth_source.as_deref().unwrap_or("SAM-all");
    session.write(|status| {
        *status = ConnectionStatus {
            stage: "sac".into(),
            message: format!("正在通过学校 VPN 网关的 {source_label} 原生认证"),
            username: Some(username.clone()),
            ..ConnectionStatus::default()
        };
    });

    let address: SocketAddr = SERVER
        .parse()
        .map_err(|error| format!("invalid gateway address: {error}"))?;
    let gateway_ip = match address.ip() {
        std::net::IpAddr::V4(ip) => ip,
        std::net::IpAddr::V6(_) => {
            return session.fail(&username, "route_error", "Gateway must use an IPv4 address")
        }
    };
    let gateway_route = match GatewayRoute::install(gateway_ip) {
        Ok(route) => route,
        Err(error) => return session.fail(&username, "route_error", error.to_string()),
    };
    let sac_client = SacClient::new(address);
    let sac = sac_client
        .login_with_source(&username, password.as_str(), auth_source.as_deref())
        .await;
    drop(password);
    let (sac_login, sac_diagnostics) = match sac {
        Ok(value) => value,
        Err(error) => return session.fail(&username, "sac_error", error.to_string()),
    };
    session.write(|status| status.sac = Some(sac_diagnostics));

    session.set_stage("ticket", "学校账号已通过网关原生认证，正在使用 NC Ticket");
    let ticket = sac_login.ticket;

    session.set_stage(
        "session",
        "正在通过学校 VPN 登录会话，向网关发送 GET_USERDATA",
    );
    let hardware_addresses = local_hardware_addresses();
    if hardware_addresses.is_empty() {
        eprintln!("HUSE VPN GET_USERDATA: no local hardware addresses found");
    } else {
        eprintln!(
            "HUSE VPN GET_USERDATA: collected {} local hardware addresses",
            hardware_addresses.len()
        );
    }
    let (userdata_request_len, userdata_response_len, userdata_result) =
        match sac_client.get_userdata(&ticket, &hardware_addresses).await {
            Ok(value) => value,
            Err(error) => return session.fail(&username, "session_error", error.to_string()),
        };
    session.write(|status| {
        if let Some(sac) = status.sac.as_mut() {
            sac.get_userdata_request_len = Some(userdata_request_len);
            sac.get_userdata_response_len = Some(userdata_response_len);
            sac.get_userdata_result = Some(userdata_result);
        }
    });
    if userdata_result != 0 {
        return session.fail(
            &username,
            "session_error",
            format!(
                "Gateway GET_USERDATA rejected session setup with status 0x{userdata_result:08x}"
            ),
        );
    }

    session.set_stage("tls", "正在建立兼容网关的 TLS 数据通道");
    let mut tls = match RawTlsClient::connect(address).await {
        Ok(tls) => tls,
        Err(error) => return session.fail(&username, "tls_error", error.to_string()),
    };

    session.set_stage("nc_auth", "正在使用 NC Ticket 请求虚拟 IP 和校园路由");
    if let Err(error) = tls.send_nc_auth(&ticket, &username).await {
        return session.fail(&username, "nc_error", error.to_string());
    }
    if let Err(error) = notify_safeupdate(address, &ticket).await {
        eprintln!("HUSE VPN session notification skipped: {error}");
    }
    let reply = match tls.read_nc_auth_reply().await {
        Ok(reply) => reply,
        Err(error) => return session.fail(&username, "nc_error", error.to_string()),
    };
    let virtual_ip = reply.virtual_ip.clone();
    let routes = reply_routes(&reply);

    session.set_stage("adapter", "正在创建 Wintun 并安装校园目标路由");
    let wintun = match find_wintun() {
        Ok(path) => path,
        Err(error) => return session.fail(&username, "adapter_error", error),
    };
    let tunnel_session = session.clone();
    let tunnel_alive = state.tunnel_alive.clone();
    let heartbeat_slot = state.heartbeat.clone();
    let (ready_tx, ready_rx) = tokio::sync::oneshot::channel();
    // 隧道即将运行：存活判定从此刻起有效，心跳才会继续续期。
    state.tunnel_alive.store(true, Ordering::SeqCst);
    let task = tokio::spawn(async move {
        let result = run_target_tunnel_with_ready(
            tls,
            &reply,
            &REQUIRED_TARGETS,
            wintun,
            gateway_route,
            ready_tx,
        )
        .await;
        // 隧道结束：先让存活判定说真话，再写终态（写入仍受代次校验保护）。
        tunnel_alive.store(false, Ordering::SeqCst);
        let error = match result {
            Ok(()) => "隧道意外停止".to_string(),
            Err(error) => error.to_string(),
        };
        tunnel_session.write(|status| {
            status.connected = false;
            status.stage = "tunnel_stopped".into();
            status.error = Some(error);
        });
        // 主动取消心跳（缺陷 2）：隧道都没了还继续续期，会把 tunnel_stopped
        // 覆盖回 connected，UI 就会显示"已连接"而实际没有隧道。
        let heartbeat = lock_task(&heartbeat_slot).take();
        if let Some(heartbeat) = heartbeat {
            heartbeat.abort();
            let _ = heartbeat.await;
        }
    });
    *lock_task(&state.tunnel) = Some(task);

    match ready_rx.await {
        Ok(Ok(())) => {}
        Ok(Err(error)) => {
            stop_tunnel(state).await;
            return session.fail(&username, "adapter_error", error);
        }
        Err(_) => {
            stop_tunnel(state).await;
            return session.fail(&username, "adapter_error", "隧道任务在路由就绪前停止");
        }
    }

    if let Err(error) = enable_campus_proxy_bypass(state) {
        eprintln!("HUSE VPN: campus browser proxy bypass skipped: {error}");
    }

    let heartbeat_client = SacClient::new(address);
    let heartbeat_ticket = ticket;
    let heartbeat_session = session.clone();
    let heartbeat_alive = state.tunnel_alive.clone();
    let heartbeat = tokio::spawn(async move {
        let mut consecutive_failures: u32 = 0;
        loop {
            // 正常 60 秒续期一次；失败后退避重试（10s → 20s → 30s 封顶），
            // 不再"一次失败就永久退出"（缺陷 3）。
            tokio::time::sleep(heartbeat_delay(consecutive_failures)).await;
            // 每轮复核隧道是否还活着：隧道任务已退出（或会话已换代）就自行
            // 退出，绝不继续续期。
            if !heartbeat_should_continue(
                heartbeat_session.is_current(),
                heartbeat_alive.load(Ordering::SeqCst),
            ) {
                break;
            }
            match heartbeat_client.heartbeat(&heartbeat_ticket).await {
                Ok(()) => {
                    if consecutive_failures > 0 {
                        // 续期恢复：只在阶段仍是我们写下的降级态时改回正常；
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
                    // 降级但可诊断：不退出循环，按退避继续尝试续期，成功后恢复。
                    heartbeat_session.write(|status| {
                        if status.connected || heartbeat_may_restore_stage(&status.stage) {
                            status.stage = HEARTBEAT_ERROR_STAGE.into();
                            status.error = Some(error.to_string());
                        }
                    });
                    eprintln!(
                        "HUSE VPN heartbeat failed ({consecutive_failures} consecutive), retrying in {:?}: {error}",
                        heartbeat_backoff(consecutive_failures)
                    );
                }
            }
        }
    });
    *lock_task(&state.heartbeat) = Some(heartbeat);

    let status = ConnectionStatus {
        connected: true,
        stage: "connected".into(),
        message: "校园内网隧道已建立".into(),
        username: Some(username),
        virtual_ip: Some(virtual_ip),
        connected_since: Some(chrono::Local::now().format("%Y-%m-%d %H:%M:%S").to_string()),
        routes,
        required_route_count: REQUIRED_TARGETS.len(),
        sac: session.snapshot().sac.clone(),
        error: None,
    };
    session.write(|current| *current = status.clone());
    Ok(status)
}

/// The official session serializer sends every locally enumerated adapter MAC
/// address as a lower-case, hyphen-separated string. Keep collection local to
/// the desktop process and pass only normalized values into the protocol
/// builder; no account or session material is involved.
fn local_hardware_addresses() -> Vec<String> {
    #[cfg(target_os = "windows")]
    {
        let script = "Get-NetAdapter -IncludeHidden | Select-Object -ExpandProperty MacAddress";
        let output = match hidden_command("powershell.exe")
            .args(["-NoProfile", "-NonInteractive", "-Command", script])
            .output()
        {
            Ok(output) if output.status.success() => output,
            _ => return Vec::new(),
        };
        let mut addresses = BTreeSet::new();
        for line in String::from_utf8_lossy(&output.stdout).lines() {
            if let Some(address) = normalize_mac_address(line) {
                addresses.insert(address);
            }
        }
        // 该块在 Windows 上是函数体的尾表达式（非 Windows 分支已被 cfg 移除），
        // 因此不需要显式 `return`。
        addresses.into_iter().collect()
    }

    #[cfg(not(target_os = "windows"))]
    {
        Vec::new()
    }
}

fn normalize_mac_address(value: &str) -> Option<String> {
    let pieces: Vec<_> = value.trim().split('-').collect();
    if pieces.len() != 6
        || pieces
            .iter()
            .any(|piece| piece.len() != 2 || !piece.bytes().all(|byte| byte.is_ascii_hexdigit()))
    {
        return None;
    }
    Some(pieces.join("-").to_ascii_lowercase())
}

#[tauri::command]
pub async fn disconnect_vpn(state: State<'_, VpnState>) -> Result<ConnectionStatus, String> {
    disconnect_vpn_inner(state.inner()).await
}

pub async fn disconnect_vpn_inner(state: &VpnState) -> Result<ConnectionStatus, String> {
    // 与连接流程共用同一把会话锁（缺陷 4）：断开不会和"正在推进的连接"交叉
    // 执行，它会等连接流程收尾后再拆隧道。
    let _serial = state.session.lock().await;
    // 递增代次，作废所有旧会话任务的写入；随后停掉隧道与心跳并等待收尾。
    let generation = state.generation.begin();
    stop_tunnel(state).await;
    let status = ConnectionStatus::default();
    state
        .writer(generation)
        .write(|current| *current = status.clone());
    Ok(status)
}

#[tauri::command]
pub async fn get_status(state: State<'_, VpnState>) -> Result<ConnectionStatus, String> {
    get_status_inner(state.inner()).await
}

pub async fn get_status_inner(state: &VpnState) -> Result<ConnectionStatus, String> {
    Ok(state.status.lock().unwrap().clone())
}

#[derive(Debug, Deserialize)]
struct ControlConnectRequest {
    username: String,
    password: String,
    auth_source: Option<String>,
}

/// A loopback-only control API used by the Flutter shell. It deliberately
/// accepts credentials only in memory and never writes request bodies to logs.
pub async fn run_control_server(app: AppHandle) {
    let listener = match TcpListener::bind(("127.0.0.1", CONTROL_PORT)).await {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("HUSE VPN control server unavailable: {error}");
            return;
        }
    };
    eprintln!("HUSE VPN control server listening on 127.0.0.1:{CONTROL_PORT}");

    loop {
        let (stream, _) = match listener.accept().await {
            Ok(value) => value,
            Err(error) => {
                eprintln!("HUSE VPN control connection failed: {error}");
                continue;
            }
        };
        let app = app.clone();
        tauri::async_runtime::spawn(async move {
            if let Err(error) = handle_control_connection(stream, app).await {
                eprintln!("HUSE VPN control request failed: {error}");
            }
        });
    }
}

async fn handle_control_connection(mut stream: TcpStream, app: AppHandle) -> Result<(), String> {
    let (method, path, headers, body) = read_control_request(&mut stream).await?;
    if headers.get("x-huse-control-token").map(String::as_str) != Some(CONTROL_TOKEN) {
        return write_control_response(
            &mut stream,
            401,
            "Unauthorized",
            serde_json::json!({"ok": false, "error": "unauthorized"}),
        )
        .await;
    }

    let state = app.state::<VpnState>();
    match (method.as_str(), path.as_str()) {
        ("GET", "/status") => {
            let status = get_status_inner(state.inner()).await?;
            write_control_response(
                &mut stream,
                200,
                "OK",
                serde_json::json!({"ok": true, "status": status}),
            )
            .await
        }
        ("POST", "/connect") => {
            let request: ControlConnectRequest = serde_json::from_slice(&body)
                .map_err(|error| format!("invalid control request: {error}"))?;
            match connect_vpn_inner(
                request.username,
                request.password,
                request.auth_source,
                state.inner(),
            )
            .await
            {
                Ok(status) => {
                    write_control_response(
                        &mut stream,
                        200,
                        "OK",
                        serde_json::json!({"ok": true, "status": status}),
                    )
                    .await
                }
                Err(error) => {
                    let status = get_status_inner(state.inner()).await?;
                    write_control_response(
                        &mut stream,
                        500,
                        "Internal Server Error",
                        serde_json::json!({"ok": false, "status": status, "error": error}),
                    )
                    .await
                }
            }
        }
        ("POST", "/disconnect") => {
            let status = disconnect_vpn_inner(state.inner()).await?;
            write_control_response(
                &mut stream,
                200,
                "OK",
                serde_json::json!({"ok": true, "status": status}),
            )
            .await
        }
        _ => {
            write_control_response(
                &mut stream,
                404,
                "Not Found",
                serde_json::json!({"ok": false, "error": "not found"}),
            )
            .await
        }
    }
}

async fn read_control_request(
    stream: &mut TcpStream,
) -> Result<(String, String, HashMap<String, String>, Vec<u8>), String> {
    let mut buffer = Vec::with_capacity(4096);
    let header_end = loop {
        if buffer.len() > CONTROL_MAX_REQUEST {
            return Err("control request is too large".into());
        }
        let mut chunk = [0u8; 2048];
        let count = stream
            .read(&mut chunk)
            .await
            .map_err(|error| format!("control request read failed: {error}"))?;
        if count == 0 {
            return Err("control request ended before headers".into());
        }
        buffer.extend_from_slice(&chunk[..count]);
        if let Some(index) = buffer.windows(4).position(|part| part == b"\r\n\r\n") {
            break index;
        }
    };

    let header_text = String::from_utf8(buffer[..header_end].to_vec())
        .map_err(|_| "control request headers are not valid UTF-8".to_string())?;
    let mut lines = header_text.split("\r\n");
    let request_line = lines
        .next()
        .ok_or_else(|| "control request line is missing".to_string())?;
    let mut request_parts = request_line.split_whitespace();
    let method = request_parts
        .next()
        .ok_or_else(|| "control request method is missing".to_string())?
        .to_string();
    let path = request_parts
        .next()
        .ok_or_else(|| "control request path is missing".to_string())?
        .to_string();
    let mut headers = HashMap::new();
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            headers.insert(name.trim().to_ascii_lowercase(), value.trim().to_string());
        }
    }

    let content_length = headers
        .get("content-length")
        .map(|value| value.parse::<usize>())
        .transpose()
        .map_err(|_| "invalid content length".to_string())?
        .unwrap_or(0);
    if content_length > CONTROL_MAX_REQUEST {
        return Err("control request body is too large".into());
    }
    let body_start = header_end + 4;
    let mut body = buffer[body_start..].to_vec();
    body.truncate(content_length);
    while body.len() < content_length {
        let remaining = content_length - body.len();
        let mut chunk = vec![0u8; remaining.min(2048)];
        let count = stream
            .read(&mut chunk)
            .await
            .map_err(|error| format!("control request body read failed: {error}"))?;
        if count == 0 {
            return Err("control request body ended early".into());
        }
        body.extend_from_slice(&chunk[..count]);
    }
    Ok((method, path, headers, body))
}

async fn write_control_response(
    stream: &mut TcpStream,
    status: u16,
    reason: &str,
    payload: serde_json::Value,
) -> Result<(), String> {
    let body = serde_json::to_vec(&payload)
        .map_err(|error| format!("control response serialization failed: {error}"))?;
    let header = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream
        .write_all(header.as_bytes())
        .await
        .map_err(|error| format!("control response write failed: {error}"))?;
    stream
        .write_all(&body)
        .await
        .map_err(|error| format!("control response body write failed: {error}"))
}

/// Open one of the two fixed campus pages in the user's default browser.
/// The URL is selected from an allowlist rather than passed to a shell.
#[tauri::command]
pub fn open_campus_page(target: String) -> Result<(), String> {
    let url = match target.as_str() {
        "navigation" => CAMPUS_NAVIGATION_URL,
        "authentication" => CAMPUS_AUTH_URL,
        _ => return Err("unknown campus page".into()),
    };

    #[cfg(target_os = "windows")]
    {
        hidden_command("explorer.exe")
            .arg(url)
            .spawn()
            .map(|_| ())
            .map_err(|error| format!("failed to open campus page: {error}"))
    }

    #[cfg(not(target_os = "windows"))]
    {
        let _ = url;
        Err("opening campus pages is only supported on Windows".into())
    }
}

async fn probe_campus_page_direct(
    source_ip: Ipv4Addr,
    started: Instant,
) -> Result<CampusProbe, String> {
    let target = SocketAddr::new(IpAddr::V4(CAMPUS_AUTH_IP), 80);
    let source = SocketAddr::new(IpAddr::V4(source_ip), 0);
    let mut socket = None;
    let mut last_bind_error = None;
    for attempt in 0..30 {
        let candidate = TcpSocket::new_v4()
            .map_err(|error| format!("VPN probe socket creation failed: {error}"))?;
        match candidate.bind(source) {
            Ok(()) => {
                socket = Some(candidate);
                break;
            }
            Err(error) if error.raw_os_error() == Some(10049) && attempt < 29 => {
                last_bind_error = Some(error.to_string());
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            Err(error) => {
                return Err(format!("VPN probe virtual-IP bind failed: {error}"));
            }
        }
    }
    let socket = socket.ok_or_else(|| {
        format!(
            "VPN probe virtual-IP bind failed after waiting for adapter: {}",
            last_bind_error.unwrap_or_else(|| "address unavailable".into())
        )
    })?;
    let mut stream = tokio::time::timeout(Duration::from_secs(8), socket.connect(target))
        .await
        .map_err(|_| "VPN direct TCP connection timed out".to_string())?
        .map_err(|error| format!("VPN direct TCP connection failed: {error}"))?;

    let response = tokio::time::timeout(Duration::from_secs(8), async {
        stream
            .write_all(
                b"GET /selfservice/ HTTP/1.1\r\nHost: self.huse.cn\r\nUser-Agent: HUSE-VPN-Next/0.1\r\nConnection: close\r\n\r\n",
            )
            .await?;
        let mut headers = Vec::with_capacity(1024);
        let mut chunk = [0u8; 1024];
        while headers.len() < 16 * 1024
            && !headers.windows(4).any(|part| part == b"\r\n\r\n")
        {
            let count = stream.read(&mut chunk).await?;
            if count == 0 {
                break;
            }
            headers.extend_from_slice(&chunk[..count]);
        }
        Ok::<Vec<u8>, std::io::Error>(headers)
    })
    .await;
    let elapsed_ms = started.elapsed().as_millis();

    match response {
        Ok(Ok(headers)) => {
            let status = headers
                .split(|byte| *byte == b'\n')
                .next()
                .and_then(|line| {
                    let text = String::from_utf8_lossy(line);
                    text.split_whitespace().nth(1).map(str::to_owned)
                })
                .and_then(|value| value.parse::<u16>().ok());
            let ok = status.is_some_and(|value| (200..400).contains(&value));
            Ok(CampusProbe {
                target: CAMPUS_AUTH_URL.into(),
                ok,
                status,
                elapsed_ms,
                error: match status {
                    Some(_) if ok => None,
                    Some(value) => Some(format!("campus server returned HTTP {value}")),
                    None => Some("VPN direct connection returned no valid HTTP status".into()),
                },
            })
        }
        Ok(Err(error)) => Ok(CampusProbe {
            target: CAMPUS_AUTH_URL.into(),
            ok: false,
            status: None,
            elapsed_ms,
            error: Some(format!("VPN direct HTTP request failed: {error}")),
        }),
        Err(_) => Ok(CampusProbe {
            target: CAMPUS_AUTH_URL.into(),
            ok: false,
            status: None,
            elapsed_ms,
            error: Some("VPN direct HTTP request timed out".into()),
        }),
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct CampusProbe {
    target: String,
    ok: bool,
    status: Option<u16>,
    elapsed_ms: u128,
    error: Option<String>,
}

/// Perform a direct, target-scoped HTTP probe through the active VPN tunnel.
/// It binds the TCP socket to the assigned virtual IP and sends an HTTP/1.1
/// request to the known internal address, so the result is independent of
/// Chrome and FlClash proxy settings.
#[tauri::command]
pub async fn probe_campus_page(state: State<'_, VpnState>) -> Result<CampusProbe, String> {
    let virtual_ip = {
        let status = state.status.lock().unwrap();
        if !status.connected {
            return Err("请先连接校园内网".into());
        }
        status
            .virtual_ip
            .clone()
            .ok_or_else(|| "当前连接没有虚拟 IP".to_string())?
    };
    let source_ip = virtual_ip
        .parse::<Ipv4Addr>()
        .map_err(|_| "当前虚拟 IP 无效".to_string())?;
    let started = Instant::now();
    probe_campus_page_direct(source_ip, started).await
}

/// 这些测试只覆盖与 JNI/Tauri/网络无关的**纯逻辑**（代次判定、退避序列、
/// 状态覆盖保护、隧道存活判定），因此可以在宿主机上直接跑。这个模块被
/// `ffi/src/lib.rs` 用 `#[path]` 引入，所以 `cargo test -p huse-vpn-ffi`
/// 就会执行它们。
#[cfg(test)]
mod tests {
    use super::*;

    /// 缺陷 1 的纯逻辑：代次严格递增。
    #[test]
    fn generation_increments_monotonically() {
        let generation = Generation::new();
        assert_eq!(generation.current(), 0);
        let first = generation.begin();
        let second = generation.begin();
        assert_eq!(first, 1);
        assert_eq!(second, 2);
        assert_eq!(generation.current(), second);
        assert!(generation.is_current(second));
        assert!(!generation.is_current(first));
    }

    /// 缺陷 1 的核心：旧代次任务的写入必须被拒绝，且无法覆盖新会话状态。
    #[test]
    fn stale_generation_write_is_rejected_and_cannot_overwrite_new_session() {
        let state = VpnState::new();
        let old_generation = state.generation.begin();
        let old_writer = state.writer(old_generation);
        assert!(old_writer.set_stage("connected", "旧会话已连接"));

        // 新会话开始（模拟用户立刻重新连接）。
        let new_generation = state.generation.begin();
        let new_writer = state.writer(new_generation);
        assert!(new_writer.set_stage("sac", "新会话正在认证"));

        // 旧任务此刻才写（abort 还没被 poll 到）：必须被丢弃。
        assert!(!old_writer.set_stage("connected", "旧会话已连接"));
        assert!(!old_writer.write(|status| status.error = Some("旧会话的错误".into())));

        let status = new_writer.snapshot();
        assert_eq!(status.stage, "sac");
        assert_eq!(status.message, "新会话正在认证");
        assert!(status.error.is_none());
        assert!(!status.connected);
    }

    /// 当前代次的写入正常生效（守卫不能把正常路径也挡掉）。
    #[test]
    fn current_generation_write_is_applied() {
        let state = VpnState::new();
        let writer = state.writer(state.generation.begin());
        assert!(writer.write(|status| {
            status.connected = true;
            status.stage = "connected".into();
        }));
        let status = writer.snapshot();
        assert!(status.connected);
        assert_eq!(status.stage, "connected");
    }

    /// 缺陷 3：退避序列单调不减且有上限，不会退化成无限快速重试。
    #[test]
    fn heartbeat_backoff_is_monotonic_and_capped() {
        let mut previous = heartbeat_backoff(1);
        assert_eq!(previous, Duration::from_secs(10));
        for failures in 2..64 {
            let current = heartbeat_backoff(failures);
            assert!(current >= previous, "退避必须单调不减: failures={failures}");
            previous = current;
        }
        assert_eq!(previous, Duration::from_secs(30));
        // 健康时用正常间隔，且比退避上限长得多。
        assert_eq!(heartbeat_delay(0), HEARTBEAT_INTERVAL);
        assert!(heartbeat_delay(0) > heartbeat_backoff(u32::MAX));
    }

    /// 缺陷 2：隧道已死或会话已换代时，心跳必须自行退出。
    #[test]
    fn heartbeat_exits_once_the_tunnel_is_gone() {
        let state = VpnState::new();
        let writer = state.writer(state.generation.begin());
        assert!(heartbeat_should_continue(writer.is_current(), true));
        // 隧道任务已退出。
        assert!(!heartbeat_should_continue(writer.is_current(), false));
        // 会话被更新的连接/断开取代。
        state.generation.begin();
        assert!(!heartbeat_should_continue(writer.is_current(), true));
        assert!(!heartbeat_should_continue(writer.is_current(), false));
    }

    /// 缺陷 2 的另一半：心跳恢复不得把终态改写回 connected。
    #[test]
    fn heartbeat_never_restores_a_terminal_stage() {
        assert!(heartbeat_may_restore_stage("connected"));
        assert!(heartbeat_may_restore_stage(HEARTBEAT_ERROR_STAGE));
        for stage in [
            "tunnel_stopped",
            "idle",
            "starting",
            "sac_error",
            "adapter_error",
            "ffi_error",
        ] {
            assert!(
                !heartbeat_may_restore_stage(stage),
                "终态不可被心跳改写: {stage}"
            );
        }

        // 端到端一点：隧道写下的 tunnel_stopped 不会被心跳的恢复分支改写。
        let state = VpnState::new();
        let writer = state.writer(state.generation.begin());
        writer.write(|status| {
            status.connected = false;
            status.stage = "tunnel_stopped".into();
        });
        writer.write(|status| {
            if heartbeat_may_restore_stage(&status.stage) {
                status.stage = "connected".into();
                status.error = None;
            }
        });
        assert_eq!(writer.snapshot().stage, "tunnel_stopped");
    }

    /// 缺陷 3 的降级态：失败写 heartbeat_error，恢复后清错误并回到 connected。
    #[test]
    fn heartbeat_degraded_stage_round_trips() {
        let state = VpnState::new();
        let writer = state.writer(state.generation.begin());
        writer.write(|status| {
            status.connected = true;
            status.stage = "connected".into();
        });
        // 失败一次：降级但保持 connected 语义（Kotlin/Dart 侧据此立即重认证）。
        writer.write(|status| {
            if status.connected || heartbeat_may_restore_stage(&status.stage) {
                status.stage = HEARTBEAT_ERROR_STAGE.into();
                status.error = Some("Gateway heartbeat timed out".into());
            }
        });
        assert_eq!(writer.snapshot().stage, "heartbeat_error");
        // 退避后成功：恢复 connected 并清掉错误。
        writer.write(|status| {
            if heartbeat_may_restore_stage(&status.stage) {
                status.stage = "connected".into();
                status.error = None;
            }
        });
        let status = writer.snapshot();
        assert_eq!(status.stage, "connected");
        assert!(status.error.is_none());
        assert!(status.connected);
    }
}
