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
use std::sync::{Arc, Mutex, OnceLock};
use tokio::runtime::Runtime;
use tokio::task::JoinHandle;
use zeroize::Zeroizing;

const SERVER: &str = "222.243.204.22:6443";
const REQUIRED_TARGETS: [Ipv4Addr; 4] = [
    Ipv4Addr::new(172, 19, 0, 192),
    Ipv4Addr::new(172, 19, 0, 200),
    Ipv4Addr::new(172, 20, 63, 226),
    Ipv4Addr::new(222, 243, 204, 25),
];

struct PendingSession {
    tls: Option<RawTlsClient>,
    reply: NcAuthReply,
    ticket: [u8; 32],
    username: String,
}

struct MobileState {
    status: Mutex<MobileStatus>,
    operation: Mutex<Option<JoinHandle<()>>>,
    tunnel: Mutex<Option<JoinHandle<()>>>,
    heartbeat: Mutex<Option<JoinHandle<()>>>,
    session: Mutex<Option<PendingSession>>,
}

impl MobileState {
    fn new() -> Self {
        Self {
            status: Mutex::new(MobileStatus::default()),
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
        }
    }
}

fn cancel_task(slot: &Mutex<Option<JoinHandle<()>>>) {
    if let Some(task) = slot.lock().unwrap().take() {
        task.abort();
    }
}

fn stop_all(host: &MobileHost) {
    cancel_task(&host.state.operation);
    cancel_task(&host.state.tunnel);
    cancel_task(&host.state.heartbeat);
    host.state.session.lock().unwrap().take();
}

fn set_stage(state: &MobileState, stage: &str, message: &str) {
    let mut status = state.status.lock().unwrap();
    status.stage = stage.to_string();
    status.message = message.to_string();
    status.error = None;
}

fn fail(state: &MobileState, username: String, stage: &str, error: impl Into<String>) {
    let mut status = state.status.lock().unwrap();
    status.connected = false;
    status.stage = stage.to_string();
    status.message = "连接未完成".into();
    status.username = Some(username);
    status.error = Some(error.into());
}

fn spawn_prepare(host: &'static MobileHost, username: String, password: String, source: String) {
    let state = host.state.clone();
    let task = host.runtime.handle().spawn(async move {
        prepare_inner(username, password, source, state).await;
    });
    *host.state.operation.lock().unwrap() = Some(task);
}

async fn prepare_inner(
    username: String,
    password: String,
    source: String,
    state: Arc<MobileState>,
) {
    let address: SocketAddr = match SERVER.parse() {
        Ok(address) => address,
        Err(error) => {
            fail(
                &state,
                username,
                "sac_error",
                format!("Gateway 地址无效: {error}"),
            );
            return;
        }
    };

    set_stage(&state, "sac", "正在通过学校加速器网关进行原生认证");
    let sac_client = SacClient::new(address);
    let password = Zeroizing::new(password);
    let login = sac_client
        .login_with_source(&username, password.as_str(), Some(&source))
        .await;
    drop(password);
    let (sac_login, diagnostics) = match login {
        Ok(value) => value,
        Err(error) => {
            fail(&state, username, "sac_error", error.to_string());
            return;
        }
    };
    state.status.lock().unwrap().sac = Some(diagnostics);

    let ticket = sac_login.ticket;
    set_stage(
        &state,
        "session",
        "正在向网关发送 GET_USERDATA 建立登录会话",
    );
    let hardware_addresses = local_hardware_addresses();
    let userdata = sac_client.get_userdata(&ticket, &hardware_addresses).await;
    let (request_len, response_len, result) = match userdata {
        Ok(value) => value,
        Err(error) => {
            fail(&state, username, "session_error", error.to_string());
            return;
        }
    };
    {
        let mut status = state.status.lock().unwrap();
        if let Some(sac) = status.sac.as_mut() {
            sac.get_userdata_request_len = Some(request_len);
            sac.get_userdata_response_len = Some(response_len);
            sac.get_userdata_result = Some(result);
        }
    }
    if result != 0 {
        fail(
            &state,
            username,
            "session_error",
            format!("Gateway GET_USERDATA rejected session setup with status 0x{result:08x}"),
        );
        return;
    }

    set_stage(&state, "tls", "正在建立网关 TLS 数据通道");
    let mut tls = match RawTlsClient::connect(address).await {
        Ok(value) => value,
        Err(error) => {
            fail(&state, username, "tls_error", error.to_string());
            return;
        }
    };
    set_stage(&state, "nc_auth", "正在使用 NC Ticket 请求虚拟 IP");
    if let Err(error) = tls.send_nc_auth(&ticket, &username).await {
        fail(&state, username, "nc_error", error.to_string());
        return;
    }
    if let Err(error) = notify_safeupdate(address, &ticket).await {
        eprintln!("HUSE mobile VPN session notification skipped: {error}");
    }
    let reply = match tls.read_nc_auth_reply().await {
        Ok(value) => value,
        Err(error) => {
            fail(&state, username, "nc_error", error.to_string());
            return;
        }
    };
    if reply.virtual_ip.parse::<Ipv4Addr>().is_err() {
        fail(
            &state,
            username,
            "nc_error",
            "Gateway returned an invalid virtual IPv4 address",
        );
        return;
    }

    let routes = route_prefixes(&reply);
    let virtual_ip = reply.virtual_ip.clone();
    *state.session.lock().unwrap() = Some(PendingSession {
        tls: Some(tls),
        reply,
        ticket,
        username: username.clone(),
    });
    let mut status = state.status.lock().unwrap();
    status.connected = false;
    status.stage = "awaiting_tun".into();
    status.message = "学校加速器认证完成，正在请求 Android 系统网络授权".into();
    status.username = Some(username);
    status.virtual_ip = Some(virtual_ip);
    status.routes = routes;
    status.required_route_count = REQUIRED_TARGETS.len();
    status.error = None;
}

fn start_tunnel(host: &'static MobileHost, tun_fd: RawFd) -> i32 {
    if tun_fd < 0 {
        return -1;
    }
    let Some(mut pending) = host.state.session.lock().unwrap().take() else {
        return -2;
    };
    let Some(tls) = pending.tls.take() else {
        return -3;
    };
    let reply = pending.reply;
    let ticket = pending.ticket;
    let username = pending.username;
    let routes = route_prefixes(&reply);
    let virtual_ip = reply.virtual_ip.clone();
    let state = host.state.clone();

    let tunnel_task = host.runtime.handle().spawn(async move {
        let result = run_android_tunnel(tls, tun_fd).await;
        let mut status = state.status.lock().unwrap();
        status.connected = false;
        status.stage = "tunnel_stopped".into();
        status.error = Some(match result {
            Ok(()) => "Android 加速器隧道已停止".into(),
            Err(error) => error.to_string(),
        });
    });
    *host.state.tunnel.lock().unwrap() = Some(tunnel_task);

    let heartbeat_state = host.state.clone();
    let heartbeat = host.runtime.handle().spawn(async move {
        let client = SacClient::new(SERVER.parse().expect("valid Gateway address"));
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(60)).await;
            if let Err(error) = client.heartbeat(&ticket).await {
                let mut status = heartbeat_state.status.lock().unwrap();
                if status.connected {
                    status.stage = "heartbeat_error".into();
                    status.error = Some(error.to_string());
                }
                break;
            }
        }
    });
    *host.state.heartbeat.lock().unwrap() = Some(heartbeat);

    let sac = host.state.status.lock().unwrap().sac.clone();
    *host.state.status.lock().unwrap() = MobileStatus {
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
    };
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
    let Some(username) = read_jstring(&mut env, username) else {
        return -1;
    };
    let Some(password) = read_jstring(&mut env, password) else {
        return -2;
    };
    let source = read_jstring(&mut env, auth_source).unwrap_or_else(|| "SAM-all".into());
    let host = instance();
    stop_all(host);
    *host.state.status.lock().unwrap() = MobileStatus {
        connected: false,
        stage: "starting".into(),
        message: "正在启动 Android 校园加速器".into(),
        username: Some(username.clone()),
        ..MobileStatus::default()
    };
    spawn_prepare(host, username, password, source);
    0
}

#[no_mangle]
pub extern "system" fn Java_com_one_huaji_CampusVpnService_nativeStatusJson(
    env: JNIEnv<'_>,
    _this: JObject<'_>,
) -> jstring {
    let status = serde_json::to_string(&*instance().state.status.lock().unwrap())
        .unwrap_or_else(|_| "{\"connected\":false,\"stage\":\"ffi_error\"}".into());
    to_jstring(env, status)
}

#[no_mangle]
pub extern "system" fn Java_com_one_huaji_CampusVpnService_nativeStartTunnel(
    _env: JNIEnv<'_>,
    _this: JObject<'_>,
    tun_fd: jint,
) -> jint {
    start_tunnel(instance(), tun_fd as RawFd)
}

#[no_mangle]
pub extern "system" fn Java_com_one_huaji_CampusVpnService_nativeDisconnect(
    _env: JNIEnv<'_>,
    _this: JObject<'_>,
) -> jint {
    let host = instance();
    stop_all(host);
    *host.state.status.lock().unwrap() = MobileStatus::default();
    0
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
