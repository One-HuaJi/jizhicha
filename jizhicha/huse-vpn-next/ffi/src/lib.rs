#![allow(clippy::missing_safety_doc)]

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::{Mutex, OnceLock};

use tokio::runtime::Runtime;
use tokio::task::JoinHandle;

#[allow(dead_code)]
#[path = "../../desktop/src-tauri/src/commands.rs"]
mod vpn_commands;

struct FfiRuntime {
    runtime: Runtime,
    state: vpn_commands::VpnState,
    operation: Mutex<Option<JoinHandle<()>>>,
}

static INSTANCE: OnceLock<FfiRuntime> = OnceLock::new();

fn instance() -> &'static FfiRuntime {
    INSTANCE.get_or_init(|| FfiRuntime {
        runtime: Runtime::new().expect("HUSE VPN FFI runtime initialization failed"),
        state: vpn_commands::VpnState::new(),
        operation: Mutex::new(None),
    })
}

fn read_required(value: *const c_char) -> Option<String> {
    if value.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(value).to_str().ok().map(ToOwned::to_owned) }
}

fn read_optional(value: *const c_char) -> Option<String> {
    if value.is_null() {
        return None;
    }
    read_required(value)
}

fn cancel_operation(host: &FfiRuntime) {
    if let Some(operation) = host.operation.lock().unwrap().take() {
        operation.abort();
        // Aborting a Tokio task is cooperative: the task must be polled once
        // more before its cleanup guards (routes, proxy state and Wintun
        // handles) are dropped. Wait here so a new connect/disconnect cannot
        // overlap the previous operation and leave a stale adapter session.
        host.runtime.block_on(async {
            let _ = operation.await;
        });
    }
}

fn spawn_operation(
    host: &'static FfiRuntime,
    operation: impl std::future::Future<Output = ()> + Send + 'static,
) {
    let task = host.runtime.handle().spawn(operation);
    *host.operation.lock().unwrap() = Some(task);
}

/// Start the VPN asynchronously. The Flutter UI reads progress from
/// `huse_vpn_status_json` while the Rust session negotiates the tunnel.
#[no_mangle]
pub extern "C" fn huse_vpn_connect(
    username: *const c_char,
    password: *const c_char,
    auth_source: *const c_char,
) -> i32 {
    let Some(username) = read_required(username) else {
        return -1;
    };
    let Some(password) = read_required(password) else {
        return -2;
    };
    let auth_source = read_optional(auth_source);
    let host = instance();
    cancel_operation(host);
    vpn_commands::prepare_connect(&host.state, &username);
    spawn_operation(host, async move {
        let _ = vpn_commands::connect_vpn_inner(username, password, auth_source, &host.state).await;
    });
    0
}

/// Disconnect the current tunnel asynchronously.
#[no_mangle]
pub extern "C" fn huse_vpn_disconnect() -> i32 {
    let host = instance();
    cancel_operation(host);
    spawn_operation(host, async move {
        let _ = vpn_commands::disconnect_vpn_inner(&host.state).await;
    });
    0
}

/// Return the complete diagnostic/status object as a UTF-8 JSON string.
/// The caller must release it with `huse_vpn_free_string`.
#[no_mangle]
pub extern "C" fn huse_vpn_status_json() -> *mut c_char {
    let host = instance();
    let status = host
        .runtime
        .block_on(vpn_commands::get_status_inner(&host.state));
    let json = match status
        .and_then(|value| serde_json::to_string(&value).map_err(|error| error.to_string()))
    {
        Ok(json) => json,
        Err(error) => serde_json::json!({
            "connected": false,
            "stage": "ffi_error",
            "message": "加速器状态序列化失败",
            "error": error,
        })
        .to_string(),
    };
    CString::new(json)
        .unwrap_or_else(|_| CString::new("{\"connected\":false,\"stage\":\"ffi_error\"}").unwrap())
        .into_raw()
}

#[no_mangle]
pub unsafe extern "C" fn huse_vpn_free_string(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

/// A small health check used by Flutter before loading the native module.
#[no_mangle]
pub extern "C" fn huse_vpn_ffi_version() -> *mut c_char {
    CString::new("huse-vpn-ffi/0.1").unwrap().into_raw()
}

#[no_mangle]
pub unsafe extern "C" fn huse_vpn_shutdown() {
    let Some(host) = INSTANCE.get() else {
        return;
    };
    cancel_operation(host);
    host.runtime
        .block_on(vpn_commands::disconnect_vpn_inner(&host.state))
        .ok();
}
