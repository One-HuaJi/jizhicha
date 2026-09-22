#![allow(clippy::missing_safety_doc)]

use std::ffi::{CStr, CString};
use std::future::Future;
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::time::Duration;

use tokio::runtime::Runtime;
use tokio::task::JoinHandle;

#[allow(dead_code)]
#[path = "../../desktop/src-tauri/src/commands.rs"]
mod vpn_commands;

/// 原生内部异常统一映射成这个返回码；Dart 侧只判「非 0 即失败」。
const FFI_PANIC_CODE: i32 = -3;

/// 状态 JSON 的兜底串。不含 NUL 字节，`CString::new` 在此不可能失败。
const FALLBACK_STATUS_JSON: &str = "{\"connected\":false,\"stage\":\"ffi_error\"}";

/// 等待被取消的操作真正收尾的上限。
///
/// `JoinHandle::abort` 只发出取消请求，任务要再被 poll 一次才会释放路由、代理
/// 状态和 Wintun 句柄；这里等它结束，避免与下一次连接重叠。等待必须有上限：
/// 旧任务可能卡在不可中断的系统调用里（例如安装网关路由的 netsh 子进程），
/// 不能把 Dart 侧调用线程永久挂住。超时后旧任务可能仍在运行，但
/// `vpn_commands` 里的会话锁与代次校验保证它既不会与新流程并行改状态，也无法
/// 污染新会话的 status。
const OPERATION_CANCEL_TIMEOUT: Duration = Duration::from_secs(5);

struct FfiRuntime {
    runtime: Runtime,
    state: vpn_commands::VpnState,
    operation: Mutex<Option<JoinHandle<()>>>,
    /// 串行化「取消旧操作 → 启动新操作」这一整段（缺陷 4）。
    ///
    /// 若两个并发调用各自「取走槽位 → spawn」，它们可能都取到 `None`，于是各自
    /// spawn：旧任务谁也没取消，继续和新任务并行运行并覆盖状态。
    session: Mutex<()>,
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
        session: Mutex::new(()),
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
        // 等待有上限，理由见 `OPERATION_CANCEL_TIMEOUT`。
        host.runtime.block_on(async {
            let _ = tokio::time::timeout(OPERATION_CANCEL_TIMEOUT, operation).await;
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

/// 取消旧操作，然后（在同一临界区内）启动新操作（缺陷 4 的串行化）。
///
/// 「取走旧 handle → abort → 有界等待 → 写入新 handle」四步必须原子完成；
/// 否则两个并发的 connect/disconnect 调用可能都取到 `None`，于是各自 spawn，
/// 旧任务被漏掉继续运行。会话级状态污染由 `vpn_commands` 的代次校验兜底，
/// 这里保证的是「同一时刻只有一个操作在推进」。
///
/// `build` 在旧操作取消之后、新操作 spawn 之前被调用：`huse_vpn_connect` 用它
/// 同步写下 "starting"，保持与旧版本一致的可观测顺序（导出返回时状态已经是
/// starting，而不是等新任务被调度后才更新）。
///
/// 锁在 `block_on` 期间一直持有，因此其它 FFI 调用会排队而不是与之交错；被等待
/// 的任务不会回调任何 FFI 导出，因此不存在自锁。
fn replace_operation<F, Fut>(host: &'static FfiRuntime, build: F)
where
    F: FnOnce() -> Fut,
    Fut: Future<Output = ()> + Send + 'static,
{
    let _session = lock_or_recover(&host.session);
    cancel_operation(host);
    spawn_operation(host, build());
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
            replace_operation(host, || {
                // 顺序保持 cancel → prepare → connect：旧的连接流程已在
                // `replace_operation` 里取消并（有界地）等待收尾。
                vpn_commands::prepare_connect(&host.state, &username);
                async move {
                    let _ = vpn_commands::connect_vpn_inner(
                        username,
                        password,
                        auth_source,
                        &host.state,
                    )
                    .await;
                }
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
            replace_operation(host, || async move {
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
            // 与 connect/disconnect 共用同一把串行锁：关闭不会和正在推进的连接
            // 流程交错执行。
            let _session = lock_or_recover(&host.session);
            cancel_operation(host);
            host.runtime
                .block_on(vpn_commands::disconnect_vpn_inner(&host.state))
                .ok();
        },
    )
}
