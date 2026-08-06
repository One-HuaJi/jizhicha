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
use std::sync::{Arc, Mutex};
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

pub struct VpnState {
    status: Arc<Mutex<ConnectionStatus>>,
    tunnel: Mutex<Option<tokio::task::JoinHandle<()>>>,
    heartbeat: Mutex<Option<tokio::task::JoinHandle<()>>>,
    campus_proxy_bypass_added: Mutex<bool>,
}

impl VpnState {
    pub fn new() -> Self {
        Self {
            status: Arc::new(Mutex::new(ConnectionStatus::default())),
            tunnel: Mutex::new(None),
            heartbeat: Mutex::new(None),
            campus_proxy_bypass_added: Mutex::new(false),
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
    *state.status.lock().unwrap() = ConnectionStatus {
        stage: "starting".into(),
        message: "正在启动校园 VPN".into(),
        username: Some(username.to_string()),
        ..ConnectionStatus::default()
    };
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

fn set_stage(state: &VpnState, stage: &str, message: &str) {
    let mut status = state.status.lock().unwrap();
    status.stage = stage.to_string();
    status.message = message.to_string();
    status.error = None;
}

fn fail(
    state: &VpnState,
    username: String,
    stage: &str,
    message: impl Into<String>,
) -> Result<ConnectionStatus, String> {
    let message = message.into();
    let mut status = state.status.lock().unwrap();
    status.connected = false;
    status.stage = stage.to_string();
    status.message = "连接未完成".into();
    status.username = Some(username);
    status.error = Some(message.clone());
    Err(message)
}

async fn stop_tunnel(state: &VpnState) {
    let heartbeat = state.heartbeat.lock().unwrap().take();
    if let Some(heartbeat) = heartbeat {
        heartbeat.abort();
        let _ = heartbeat.await;
    }
    let task = state.tunnel.lock().unwrap().take();
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

pub async fn connect_vpn_inner(
    username: String,
    password: String,
    auth_source: Option<String>,
    state: &VpnState,
) -> Result<ConnectionStatus, String> {
    stop_tunnel(&state).await;
    let password = Zeroizing::new(password);
    let source_label = auth_source.as_deref().unwrap_or("SAM-all");
    *state.status.lock().unwrap() = ConnectionStatus {
        stage: "sac".into(),
        message: format!("正在通过学校 VPN 网关的 {source_label} 原生认证"),
        username: Some(username.clone()),
        ..ConnectionStatus::default()
    };

    let address: SocketAddr = SERVER
        .parse()
        .map_err(|error| format!("invalid gateway address: {error}"))?;
    let gateway_ip = match address.ip() {
        std::net::IpAddr::V4(ip) => ip,
        std::net::IpAddr::V6(_) => {
            return fail(
                &state,
                username,
                "route_error",
                "Gateway must use an IPv4 address",
            )
        }
    };
    let gateway_route = match GatewayRoute::install(gateway_ip) {
        Ok(route) => route,
        Err(error) => return fail(&state, username, "route_error", error.to_string()),
    };
    let sac_client = SacClient::new(address);
    let sac = sac_client
        .login_with_source(&username, password.as_str(), auth_source.as_deref())
        .await;
    drop(password);
    let (sac_login, sac_diagnostics) = match sac {
        Ok(value) => value,
        Err(error) => return fail(&state, username, "sac_error", error.to_string()),
    };
    state.status.lock().unwrap().sac = Some(sac_diagnostics);

    set_stage(
        &state,
        "ticket",
        "学校账号已通过网关原生认证，正在使用 NC Ticket",
    );
    let ticket = sac_login.ticket;

    set_stage(
        &state,
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
            Err(error) => return fail(&state, username, "session_error", error.to_string()),
        };
    {
        let mut status = state.status.lock().unwrap();
        if let Some(sac) = status.sac.as_mut() {
            sac.get_userdata_request_len = Some(userdata_request_len);
            sac.get_userdata_response_len = Some(userdata_response_len);
            sac.get_userdata_result = Some(userdata_result);
        }
    }
    if userdata_result != 0 {
        return fail(
            &state,
            username,
            "session_error",
            format!(
                "Gateway GET_USERDATA rejected session setup with status 0x{userdata_result:08x}"
            ),
        );
    }

    set_stage(&state, "tls", "正在建立兼容网关的 TLS 数据通道");
    let mut tls = match RawTlsClient::connect(address).await {
        Ok(tls) => tls,
        Err(error) => return fail(&state, username, "tls_error", error.to_string()),
    };

    set_stage(
        &state,
        "nc_auth",
        "正在使用 NC Ticket 请求虚拟 IP 和校园路由",
    );
    if let Err(error) = tls.send_nc_auth(&ticket, &username).await {
        return fail(&state, username, "nc_error", error.to_string());
    }
    if let Err(error) = notify_safeupdate(address, &ticket).await {
        eprintln!("HUSE VPN session notification skipped: {error}");
    }
    let reply = match tls.read_nc_auth_reply().await {
        Ok(reply) => reply,
        Err(error) => return fail(&state, username, "nc_error", error.to_string()),
    };
    let virtual_ip = reply.virtual_ip.clone();
    let routes = reply_routes(&reply);

    set_stage(&state, "adapter", "正在创建 Wintun 并安装校园目标路由");
    let wintun = match find_wintun() {
        Ok(path) => path,
        Err(error) => return fail(&state, username, "adapter_error", error),
    };
    let shared_status = state.status.clone();
    let (ready_tx, ready_rx) = tokio::sync::oneshot::channel();
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
        let mut status = shared_status.lock().unwrap();
        status.connected = false;
        status.stage = "tunnel_stopped".into();
        status.error = Some(match result {
            Ok(()) => "隧道意外停止".into(),
            Err(error) => error.to_string(),
        });
    });
    *state.tunnel.lock().unwrap() = Some(task);

    match ready_rx.await {
        Ok(Ok(())) => {}
        Ok(Err(error)) => {
            stop_tunnel(&state).await;
            return fail(&state, username, "adapter_error", error);
        }
        Err(_) => {
            stop_tunnel(&state).await;
            return fail(
                &state,
                username,
                "adapter_error",
                "隧道任务在路由就绪前停止",
            );
        }
    }

    if let Err(error) = enable_campus_proxy_bypass(&state) {
        eprintln!("HUSE VPN: campus browser proxy bypass skipped: {error}");
    }

    let heartbeat_client = SacClient::new(address);
    let heartbeat_ticket = ticket;
    let heartbeat_status = state.status.clone();
    let heartbeat = tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(60)).await;
            if let Err(error) = heartbeat_client.heartbeat(&heartbeat_ticket).await {
                let mut status = heartbeat_status.lock().unwrap();
                if status.connected {
                    status.stage = "heartbeat_error".into();
                    status.error = Some(error.to_string());
                }
                eprintln!("HUSE VPN heartbeat stopped: {error}");
                break;
            }
        }
    });
    *state.heartbeat.lock().unwrap() = Some(heartbeat);

    let status = ConnectionStatus {
        connected: true,
        stage: "connected".into(),
        message: "校园内网隧道已建立".into(),
        username: Some(username),
        virtual_ip: Some(virtual_ip),
        connected_since: Some(chrono::Local::now().format("%Y-%m-%d %H:%M:%S").to_string()),
        routes,
        required_route_count: REQUIRED_TARGETS.len(),
        sac: state.status.lock().unwrap().sac.clone(),
        error: None,
    };
    *state.status.lock().unwrap() = status.clone();
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
        return addresses.into_iter().collect();
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
    stop_tunnel(state).await;
    let status = ConnectionStatus::default();
    *state.status.lock().unwrap() = status.clone();
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
    return probe_campus_page_direct(source_ip, started).await;
}
