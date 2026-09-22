package com.one.huaji

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import org.json.JSONObject

/**
 * Owns Android's VPN permission and TUN descriptor. Protocol authentication
 * and packet forwarding remain in the Rust mobile FFI library.
 */
class CampusVpnService : VpnService() {
    companion object {
        const val ACTION_CONNECT = "com.one.huaji.action.CONNECT"
        const val ACTION_DISCONNECT = "com.one.huaji.action.DISCONNECT"
        private const val EXTRA_USERNAME = "username"
        private const val EXTRA_PASSWORD = "password"
        private const val EXTRA_AUTH_SOURCE = "auth_source"
        private const val CHANNEL_ID = "huse-campus-vpn"
        private const val NOTIFICATION_ID = 2608
        /// logcat 统一 tag：debug 日志与 release 状态跃迁共用。
        private const val TAG = "JizhichaVpn"
        private const val POLL_MS = 250L
        // Once connected, native status only needs a health poll; polling at
        // 250ms forever wastes battery and previously hid terminal stages.
        private const val HEALTH_POLL_MS = 5_000L
        private const val VPN_PERMISSION_REQUEST = 2609

        @Volatile
        private var cachedStatus = "{\"connected\":false,\"stage\":\"idle\"}"

        /// release 包是否允许输出调试日志（等价于 `BuildConfig.DEBUG`）。
        ///
        /// ⚠️ 刻意**不用** `BuildConfig`：本模块没有开启
        /// `buildFeatures.buildConfig`（构建脚本里没有该配置，构建产物中也没有
        /// 应用自身的 BuildConfig.java，只有插件模块有），直接引用会编译失败。
        /// `ApplicationInfo.FLAG_DEBUGGABLE` 与 `BuildConfig.DEBUG` 语义一致，
        /// 且改动完全落在本文件内，不必动构建脚本。
        /// 由 [onCreate] 按当前进程的可调试标志赋值。
        @Volatile
        private var debugLogging = false

        /// 最近一条**已经输出过**的脱敏状态，用于 release 下只记录状态跃迁。
        @Volatile
        private var lastLoggedStatus: String? = null

        fun startConnect(context: Context, username: String, password: String, authSource: String) {
            val intent = Intent(context, CampusVpnService::class.java).apply {
                action = ACTION_CONNECT
                putExtra(EXTRA_USERNAME, username)
                putExtra(EXTRA_PASSWORD, password)
                putExtra(EXTRA_AUTH_SOURCE, authSource)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, CampusVpnService::class.java).apply {
                action = ACTION_DISCONNECT
            }
            context.startService(intent)
        }

        fun status(): String = cachedStatus

        fun permissionRequestCode(): Int = VPN_PERMISSION_REQUEST

        private fun updateStatus(value: String) {
            cachedStatus = value
            // ⚠️ 必须脱敏：原生 status 里带 `username`（真实学号）与
            // `virtual_ip`（会话级虚拟地址），项目红线禁止把它们写进日志。
            // 健康轮询续上之后，本方法从"一条连接只走几次"变成
            // "每 5 秒走一次"，不脱敏等于把学号按 5 秒一条刷进 logcat。
            val redacted = redactStatus(value)
            if (debugLogging) {
                // debug 包：每条状态都记（含 5 秒健康心跳），本地排查最省事。
                android.util.Log.d(TAG, "status=$redacted")
                return
            }
            // release 包：**不输出**逐条心跳 —— 每 5 秒一条属于调试噪音，
            // release 包不该带。但"卡在连接中"仍然必须只靠 logcat 就能判断，
            // 因此只在脱敏状态**真正发生变化**时记一条：一条连接通常只有几次
            // 跃迁（idle → tls → nc_auth → awaiting_tun → connected），
            // 量级极小，且 redactStatus 已保证不含学号/虚拟 IP。
            if (redacted != lastLoggedStatus) {
                lastLoggedStatus = redacted
                android.util.Log.i(TAG, "status=$redacted")
            }
        }

        /// 只保留诊断真正需要的字段（connected / stage / error / warning）。
        ///
        /// 刻意丢掉 username、virtual_ip、message、routes、sac：它们要么是
        /// 隐私数据，要么是给 UI 看的文案，对"卡在哪个阶段"的排查没有帮助。
        private fun redactStatus(value: String): String {
            return runCatching {
                val json = JSONObject(value)
                JSONObject().apply {
                    put("connected", json.optBoolean("connected", false))
                    put("stage", json.optString("stage"))
                    json.optString("error")
                        .takeIf { it.isNotBlank() }
                        ?.let { put("error", it) }
                    json.optString("warning")
                        .takeIf { it.isNotBlank() }
                        ?.let { put("warning", it) }
                }.toString()
            }.getOrElse { "unparsable" }
        }
    }

    private val handler = Handler(Looper.getMainLooper())

    /// Native setup runs here, never on the main thread.
    ///
    /// `nativePrepare`/`nativeDisconnect` take native locks that an in-flight
    /// task may still hold. Blocking the main thread would also block the
    /// Flutter MethodChannel (`status`/`connect` replies are delivered on the
    /// main looper), which made the UI hang forever at "正在连接".
    private val workerThread = android.os.HandlerThread("CampusVpnNative").apply {
        start()
    }
    private val worker = Handler(workerThread.looper)

    private var nativeStarted = false
    private var tun: ParcelFileDescriptor? = null

    /// 最近一次写进通知栏的文案。
    ///
    /// 健康轮询每 5 秒跑一次，`updateNotification("校园网已连接")` 会在每条
    /// 健康心跳上被调用；内容没变时不再 `notify()`，避免无意义的跨进程通知
    /// 刷新（部分 ROM 上还会闪一下）。
    private var lastNotificationText: String? = null

    private external fun nativePrepare(username: String, password: String, authSource: String): Int
    private external fun nativeStatusJson(): String
    private external fun nativeStartTunnel(tunFd: Int): Int
    private external fun nativeDisconnect(): Int

    init {
        System.loadLibrary("huse_vpn_mobile_ffi")
    }

    override fun onCreate() {
        super.onCreate()
        // 日志开关按「当前包是否可调试」判定（等价于 BuildConfig.DEBUG）：
        // debug 包全量输出，release 包只保留状态跃迁那几条。
        debugLogging = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (debugLogging) {
            android.util.Log.d(TAG, "onStartCommand action=${intent?.action}")
        }
        when (intent?.action) {
            ACTION_CONNECT -> {
                // 文案统一（见 HANDOFF §9.12）：连的是「校园网」，用的是「校园加速器」这个功能。
                lastNotificationText = "正在连接校园网"
                startForeground(NOTIFICATION_ID, buildNotification("正在连接校园网"))
                val username = intent.getStringExtra(EXTRA_USERNAME).orEmpty()
                val password = intent.getStringExtra(EXTRA_PASSWORD).orEmpty()
                val source = intent.getStringExtra(EXTRA_AUTH_SOURCE) ?: "SAM-all"
                // Off the main thread: native setup can block on native locks.
                worker.post { beginConnect(username, password, source) }
            }
            ACTION_DISCONNECT -> disconnectAndStop()
        }
        return START_NOT_STICKY
    }

    private fun statusJson(stage: String, error: String? = null): String {
        return JSONObject().apply {
            put("connected", false)
            put("stage", stage)
            if (!error.isNullOrBlank()) put("error", error)
        }.toString()
    }

    /**
     * One terminal path for every failed/ended connection attempt.
     *
     * Previously startForeground() happened before native work, but SAC/TLS/NC
     * errors only updated cached status; the service, ongoing notification and
     * 250ms poll could survive indefinitely. Preserve a non-connected error
     * snapshot for Dart, then fully tear down the service.
     */
    private fun terminalFailure(stage: String, error: String?) {
        handler.removeCallbacksAndMessages(null)
        runCatching { nativeDisconnect() }
        nativeStarted = false
        closeTun()
        updateStatus(statusJson(stage, error))
        stopForeground(STOP_FOREGROUND_REMOVE)
        getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
        lastNotificationText = null
        stopSelf()
    }

    private fun beginConnect(username: String, password: String, source: String) {
        handler.removeCallbacksAndMessages(null)
        closeTun()
        nativeStarted = false
        // 🔴 必须在这里就把静态 `cachedStatus` 重置为"未连接"。
        //
        // `cachedStatus` 只由 [updateStatus] 写入，而 [updateStatus] 只在
        // `pollForTun` 跑起来之后才被调用（`handler.post` 是异步的），
        // `nativePrepare` 内部也**不会**碰它。所以在下面这几百毫秒里，
        // `cachedStatus` 仍然是**上一次连接**的快照 —— 对"重连"场景就是
        // `connected:true` + 旧的虚拟 IP。
        //
        // 后果（真机上表现为"自动重连没生效"）：Dart 侧 `_connectAndroidOnce`
        // 在 `startConnect()` 返回约 350ms 后就读 `androidStatus()`，拿到那张
        // 旧快照 → **立刻判定"已连接"** → 清零退避 → App 以为恢复了，
        // 而学校网关的会话其实还没重建。
        updateStatus(statusJson("idle"))
        // `nativePrepare` already calls stop_all() internally; calling
        // nativeDisconnect() here as well only added a second native lock round
        // trip on the setup path.
        val result = nativePrepare(username, password, source)
        if (debugLogging) {
            // 纯调试值：失败时下方 terminalFailure 会把
            // "native prepare failed ($result)" 写进脱敏 status，
            // release 包靠状态跃迁日志就能看到，不必再单独打一条。
            android.util.Log.d(TAG, "nativePrepare=$result")
        }
        if (result != 0) {
            terminalFailure("native_error", "native prepare failed ($result)")
            return
        }
        handler.post(pollForTun)
    }

    private val pollForTun = object : Runnable {
        override fun run() {
            val statusText = runCatching { nativeStatusJson() }.getOrElse {
                statusJson("native_error", it.message ?: "native status failed")
            }
            val status = runCatching { JSONObject(statusText) }.getOrElse {
                terminalFailure("native_error", "native status JSON malformed")
                return
            }
            updateStatus(statusText)
            val stage = status.optString("stage")
            val error = status.optString("error").takeIf { it.isNotBlank() }
            when {
                stage == "awaiting_tun" -> establishTun(status)
                status.optBoolean("connected", false) -> {
                    updateNotification("校园网已连接")
                    // Keep a low-rate health poll so tunnel_stopped reaches Dart
                    // and terminal cleanup; do not busy-poll a healthy tunnel.
                    scheduleHealthPoll()
                }
                stage == "heartbeat_error" -> {
                    // NOT terminal: the native heartbeat backs off and restores
                    // `connected` by itself once the gateway answers again.
                    // Tearing the tunnel down here killed recoverable sessions.
                    updateNotification("校园网连接不稳定，正在重试")
                    scheduleHealthPoll()
                }
                stage == "tunnel_stopped" -> {
                    terminalFailure(stage, error ?: "校园网连接已断开")
                }
                stage.endsWith("_error") -> {
                    terminalFailure(stage, error ?: "校园网连接失败")
                }
                else -> handler.postDelayed(this, POLL_MS)
            }
        }
    }

    /**
     * 把低频健康轮询**幂等**地续上。
     *
     * 这是「掉认证后不会自动重连」的 Kotlin 侧根因修复。修复前
     * `establishTun()` 成功路径写完之后**没有**再 `postDelayed(pollForTun)`，
     * 于是这条唯一的轮询链就此结束，静态 `cachedStatus` 永久冻结在
     * `{"connected":true,"stage":"connected"}`。
     *
     * 后果：Rust 心跳失败虽然会把 stage 改写成 `heartbeat_error`（网关会话
     * 15 分钟到期后必然发生），但 Kotlin 再也不调 `nativeStatusJson()`，
     * Dart 的 `currentStatus()` 于是永远回答"已连接"，
     * `campus_environment.dart` 的快探测永远看不到 `heartbeat_error`，
     * 重认证永远不会被触发。修好之后成功路径也续上低频轮询，
     * `cachedStatus` 始终反映原生真实状态。
     *
     * 只 `removeCallbacks` 自己这一个 runnable（不用
     * `removeCallbacksAndMessages(null)`，以免误删其它挂起任务），
     * 因此重复调用不会叠出多条并行的轮询链。
     */
    private fun scheduleHealthPoll() {
        handler.removeCallbacks(pollForTun)
        handler.postDelayed(pollForTun, HEALTH_POLL_MS)
    }

    private fun establishTun(status: JSONObject) {
        if (nativeStarted) {
            // 已经建立过 TUN（例如 stage 仍短暂停留在 awaiting_tun）：
            // 不能再 establish 一次，但必须把轮询续上 —— 这条 return 与
            // 成功路径一样，曾经是 cachedStatus 被冻结的入口。
            scheduleHealthPoll()
            return
        }
        val virtualIp = status.optString("virtual_ip")
        if (virtualIp.isBlank()) {
            handler.postDelayed(pollForTun, POLL_MS)
            return
        }
        try {
            val builder = Builder()
                .setSession("稽之查")
                .addAddress(virtualIp, 32)
            val routes = status.optJSONArray("routes")
            if (routes != null) {
                for (index in 0 until routes.length()) {
                    val route = routes.optString(index)
                    val separator = route.lastIndexOf('/')
                    if (separator <= 0) continue
                    val address = route.substring(0, separator)
                    val prefix = route.substring(separator + 1).toIntOrNull() ?: continue
                    if (prefix in 1..32) builder.addRoute(address, prefix)
                }
            }
            val descriptor = builder.establish()
                ?: throw IllegalStateException("Android system network permission was not granted")
            val fd = descriptor.detachFd()
            descriptor.close()
            tun = null
            val result = nativeStartTunnel(fd)
            if (result != 0) {
                ParcelFileDescriptor.adoptFd(fd).close()
                throw IllegalStateException("native tunnel start failed ($result)")
            }
            nativeStarted = true
            updateNotification("校园网已连接")
            updateStatus(nativeStatusJson())
            // ⚠️ 关键修复（缺陷根因 1）：成功路径**必须**续上低频健康轮询。
            // 此前这里直接结束，pollForTun 不再被 post，cachedStatus 冻结在
            // {connected:true,stage:"connected"}；之后 Rust 心跳失败写下的
            // heartbeat_error / tunnel_stopped 永远传不到 Dart，掉认证也就
            // 永远不会被自动重连。健康时只用 HEALTH_POLL_MS（5 秒），
            // 不用 POLL_MS（250ms）去轮询一条已经健康的隧道。
            scheduleHealthPoll()
        } catch (error: Throwable) {
            terminalFailure(
                "adapter_error",
                error.message ?: "failed to establish Android accelerator",
            )
        }
    }

    private fun disconnectAndStop() {
        handler.removeCallbacksAndMessages(null)
        runCatching { nativeDisconnect() }
        nativeStarted = false
        closeTun()
        // Explicit user disconnect should not leave a stale connected/error
        // snapshot for the next Flutter activity instance.
        updateStatus(statusJson("idle"))
        stopForeground(STOP_FOREGROUND_REMOVE)
        getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
        lastNotificationText = null
        stopSelf()
    }

    private fun closeTun() {
        runCatching { tun?.close() }
        tun = null
    }

    override fun onRevoke() {
        // Android normally stopSelf()s after revoke, but explicit cleanup makes
        // native/TUN/status behavior deterministic and avoids stale UI state.
        disconnectAndStop()
        super.onRevoke()
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        worker.removeCallbacksAndMessages(null)
        workerThread.quitSafely()
        runCatching { nativeDisconnect() }
        nativeStarted = false
        closeTun()
        // Do not leave a static connected=true snapshot after system teardown.
        val current = runCatching { JSONObject(cachedStatus) }.getOrNull()
        if (current?.optBoolean("connected", false) != false) {
            updateStatus(statusJson("idle"))
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent): IBinder? = super.onBind(intent)

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "校园加速器", NotificationManager.IMPORTANCE_LOW)
        )
    }

    private fun buildNotification(text: String): Notification {
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_notification)
                .setContentTitle("稽之查")
                .setContentText(text)
                .setContentIntent(pendingIntent)
                .setOngoing(true)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setSmallIcon(R.drawable.ic_stat_notification)
                .setContentTitle("稽之查")
                .setContentText(text)
                .setContentIntent(pendingIntent)
                .setOngoing(true)
                .build()
        }
    }

    private fun updateNotification(text: String) {
        if (text == lastNotificationText) return
        lastNotificationText = text
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(text))
    }
}
