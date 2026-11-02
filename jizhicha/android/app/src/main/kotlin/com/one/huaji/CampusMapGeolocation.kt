package com.one.huaji

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * 校园地图的**系统运行时定位权限**桥。
 *
 * ## 它现在只做一件事
 * 把 Dart 的 `requestLocationPermission` 转成系统的运行时权限对话框，并把
 * `onRequestPermissionsResult` 的结果回给 Dart。
 *
 * ## 它曾经做过的错事（2026-11-02 真机闪退，务必别回退）
 * 旧版本还负责"给 WebView 换一个自己的 `WebChromeClient`"，以便实现
 * `onGeolocationPermissionsShowPrompt`。但 `webview_flutter_android` 的
 * `WebViewProxyApi.setWebChromeClient` 内部有断言：
 *
 * ```
 * if (!(client instanceof WebChromeClientProxyApi.SecureWebChromeClient)) {
 *     throw new AssertionError("Client must be a SecureWebChromeClient.");
 * }
 * ```
 *
 * 一旦换掉就抛 `AssertionError`，而它发生在**平台线程**上 —— 不是 Dart 异常，
 * 不会被 Flutter 的错误处理接住，直接 FATAL 杀进程，表现为"点地图就闪退"。
 *
 * 正解：H5 定位授权改由插件官方的
 * `AndroidWebViewController.setGeolocationPermissionsPromptCallbacks` 处理
 * （见 `lib/campus_map_page.dart` 的 `_configureGeolocation`），原生层不再碰 ChromeClient。
 */
object CampusMapGeolocation {
    const val CHANNEL = "com.one.huaji/campus_map"

    private const val TAG = "CampusMapGeolocation"

    /** 请求码必须与 MainActivity 里的通知权限（1001）、VPN 授权码互不冲突。 */
    private const val PERMISSION_REQUEST_CODE = 1002

    private val LOCATION_PERMISSIONS = arrayOf(
        Manifest.permission.ACCESS_FINE_LOCATION,
        Manifest.permission.ACCESS_COARSE_LOCATION,
    )

    /**
     * Activity 必须弱引用：MainActivity 被系统回收时不能因为这里持有强引用而泄漏。
     * 每次 [register] 都会覆盖（FlutterEngine 重建时重新绑定新 Activity）。
     */
    private var activityRef: WeakReference<Activity>? = null

    /** 正在等用户点对话框的 Dart `requestLocationPermission` 调用。 */
    private var pendingPermissionResult: MethodChannel.Result? = null

    /**
     * 在 [MainActivity.configureFlutterEngine] 里调用一次，注册 Channel。
     *
     * @param activity 当前 Activity（用于申请运行时权限）
     * @param engine 要挂 Channel 的 FlutterEngine
     */
    fun register(activity: Activity, engine: FlutterEngine) {
        activityRef = WeakReference(activity)
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Dart 在打开地图时调用：确保系统运行时定位权限已授予。
                    "requestLocationPermission" -> requestLocationPermission(result)
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 把 MainActivity 的 `onRequestPermissionsResult` 转发进来。
     *
     * @return true 表示这次回调属于本模块，MainActivity 应停止后续处理。
     */
    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val activity = activityRef?.get()
        // grantResults 只反映「点了同意」，还要按实际授权状态复核（Android 12+ 允许
        // 用户只给「大致位置」＝仅 COARSE，此时 FINE 仍是拒绝）。
        val granted = activity != null && hasLocationPermission(activity)
        if (grantResults.isEmpty()) {
            Log.w(TAG, "定位权限请求被取消")
        }
        pendingPermissionResult?.let {
            pendingPermissionResult = null
            it.success(granted)
        }
        return true
    }

    private fun requestLocationPermission(result: MethodChannel.Result) {
        val activity = activityRef?.get()
        if (activity == null) {
            result.success(false)
            return
        }
        if (hasLocationPermission(activity)) {
            result.success(true)
            return
        }
        if (pendingPermissionResult != null) {
            // 已有一次请求在飞：同一个 Result 不能回应两次，也不再重复弹框。
            result.success(false)
            return
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(activity, LOCATION_PERMISSIONS, PERMISSION_REQUEST_CODE)
    }

    private fun hasLocationPermission(activity: Activity): Boolean {
        val fine = ContextCompat.checkSelfPermission(
            activity,
            Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        if (fine) return true
        // Android 12+ 用户可能只给「大致位置」（仅 COARSE）：仍然放行，让 H5 用粗定位，
        // 比直接拒绝让地图彻底没有当前位置要好。
        return ContextCompat.checkSelfPermission(
            activity,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
    }
}
