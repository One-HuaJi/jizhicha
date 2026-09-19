#![allow(clippy::missing_safety_doc)]

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Mutex, MutexGuard, OnceLock};

use tokio::runtime::Runtime;
use tokio::task::JoinHandle;

#[allow(dead_code)]
#[path = "../../desktop/src-tauri/src/commands.rs"]
mod vpn_commands;

/// 原生内部异常统一映射成这个返回码；Dart 侧只判「非 0 即失败」。
const FFI_PANIC_CODE: i32 = -3;

/// 状态 JSON 的兜底串。不含 NUL 字节，`CString::new` 在此不可能失败。
const FALLBACK_STATUS_JSON: &str = "{\"connected\":false,\"stage\":\"ffi_error\"}";

struct FfiRuntime {
    runtime: Runtime,
    state: vpn_commands::VpnState,
    operation: Mutex<Option<JoinHandle<()>>>,
}

static INSTANCE: OnceLock<FfiRuntime> = OnceLock::new();

/// 在 FFI 边界捕获 panic。
///
/// 跨 FFI 边界展开 panic 是未定义行为：Dart/Flutter 侧的调用栈没有 Rust 的
/// 展开表，内部任何一处 `.lock().unwrap()`（mutex 中毒）、`CString::new().unwrap()`
/// 或 `Runtime::new().expect()` 失败都会直接拖垮整个 Flutter 进程，而不是让
/// 调用方收到一个错误码。这里统一兜住并返回 `fallback()`。
///
/// **注意**：本函数依赖 `panic = "unwind"`。若日后给 `[profile.release]` 加上
/// `panic = "abort"`，catch_unwind 会完全失效（abort 不可捕获），两个方向只能
/// 选一个 —— 见交接文档 §9.5。
///
/// `fallback` 是闭包而非值：状态轮询每 350ms 调一次，提前构造兜底 CString 会
/// 每次都分配并泄漏一个永远不会被释放的字符串。
fn ffi_guard<T>(fallback: impl FnOnce() -> T, body: impl FnOnce() -> T) -> T {
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(value) => value,
        Err(_) => fallback(),
    }
}

/// 取锁并容忍中毒：持锁线程 panic 过不代表数据已损坏，直接沿用内部值，
/// 避免一次中毒把后续所有 FFI 调用都变成失败。
fn lock_or_recover<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn fallback_status_json() -> *mut c_char {
    CString::new(FALLBACK_STATUS_JSON)
        .expect("FALLBACK_STATUS_JSON is a NUL-free literal")
        .into_raw()
}

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
    if let Some(operation) = lock_or_recover(&host.operation).take() {
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
    *lock_or_recover(&host.operation) = Some(task);
}

/// Start the VPN asynchronously. The Flutter UI reads progress from
/// `huse_vpn_status_json` while the Rust session negotiates the tunnel.
#[no_mangle]
pub extern "C" fn huse_vpn_connect(
    username: *const c_char,
    password: *const c_char,
    auth_source: *const c_char,
) -> i32 {
    ffi_guard(
        || FFI_PANIC_CODE,
        || {
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
                let _ =
                    vpn_commands::connect_vpn_inner(username, password, auth_source, &host.state)
                        .await;
            });
            0
        },
    )
}

/// Disconnect the current tunnel asynchronously.
#[no_mangle]
pub extern "C" fn huse_vpn_disconnect() -> i32 {
    ffi_guard(
        || FFI_PANIC_CODE,
        || {
            let host = instance();
            cancel_operation(host);
            spawn_operation(host, async move {
                let _ = vpn_commands::disconnect_vpn_inner(&host.state).await;
            });
            0
        },
    )
}

/// Return the complete diagnostic/status object as a UTF-8 JSON string.
/// The caller must release it with `huse_vpn_free_string`.
#[no_mangle]
pub extern "C" fn huse_vpn_status_json() -> *mut c_char {
    ffi_guard(fallback_status_json, || {
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
        // serde_json 的输出不含裸 NUL，但仍保留兜底而不是 unwrap：这条路径
        // 每次状态轮询都会走，不能成为 panic 源。
        match CString::new(json) {
            Ok(value) => value.into_raw(),
            Err(_) => fallback_status_json(),
        }
    })
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
    // NUL-free 字面量，`CString::new` 在此不可能失败，因此不需要 ffi_guard
    // 的兜底分支（拿状态 JSON 当版本号反而是错的）。
    CString::new("huse-vpn-ffi/0.1")
        .expect("version string is a NUL-free literal")
        .into_raw()
}

#[no_mangle]
pub unsafe extern "C" fn huse_vpn_shutdown() {
    ffi_guard(
        || (),
        || {
            let Some(host) = INSTANCE.get() else {
                return;
            };
            cancel_operation(host);
            host.runtime
                .block_on(vpn_commands::disconnect_vpn_inner(&host.state))
                .ok();
        },
    )
}
