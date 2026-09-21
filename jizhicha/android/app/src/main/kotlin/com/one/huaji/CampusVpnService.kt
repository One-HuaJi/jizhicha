package com.one.huaji

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
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
        private const val POLL_MS = 250L
        // Once connected, native status only needs a health poll; polling at
        // 250ms forever wastes battery and previously hid terminal stages.
        private const val HEALTH_POLL_MS = 5_000L
        private const val VPN_PERMISSION_REQUEST = 2609

        @Volatile
        private var cachedStatus = "{\"connected\":false,\"stage\":\"idle\"}"

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
            // Status transitions are logged so a stuck "connecting" state can be
            // diagnosed from logcat without a debugger attached.
            android.util.Log.i("JizhichaVpn", "status=$value")
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

    private external fun nativePrepare(username: String, password: String, authSource: String): Int
    private external fun nativeStatusJson(): String
    private external fun nativeStartTunnel(tunFd: Int): Int
    private external fun nativeDisconnect(): Int

    init {
        System.loadLibrary("huse_vpn_mobile_ffi")
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        android.util.Log.i("JizhichaVpn", "onStartCommand action=${intent?.action}")
        when (intent?.action) {
            ACTION_CONNECT -> {
                startForeground(NOTIFICATION_ID, buildNotification("正在连接校园加速器"))
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
        stopSelf()
    }

    private fun beginConnect(username: String, password: String, source: String) {
        handler.removeCallbacksAndMessages(null)
        closeTun()
        nativeStarted = false
        // `nativePrepare` already calls stop_all() internally; calling
        // nativeDisconnect() here as well only added a second native lock round
        // trip on the setup path.
        val result = nativePrepare(username, password, source)
        android.util.Log.i("JizhichaVpn", "nativePrepare=$result")
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
                    updateNotification("校园加速器已连接")
                    // Keep a low-rate health poll so tunnel_stopped reaches Dart
                    // and terminal cleanup; do not busy-poll a healthy tunnel.
                    handler.postDelayed(this, HEALTH_POLL_MS)
                }
                stage == "heartbeat_error" -> {
                    // NOT terminal: the native heartbeat backs off and restores
                    // `connected` by itself once the gateway answers again.
                    // Tearing the tunnel down here killed recoverable sessions.
                    updateNotification("校园加速器连接不稳定，正在重试")
                    handler.postDelayed(this, HEALTH_POLL_MS)
                }
                stage == "tunnel_stopped" -> {
                    terminalFailure(stage, error ?: "校园加速器连接已停止")
                }
                stage.endsWith("_error") -> {
                    terminalFailure(stage, error ?: "校园加速器连接失败")
                }
                else -> handler.postDelayed(this, POLL_MS)
            }
        }
    }

    private fun establishTun(status: JSONObject) {
        if (nativeStarted) return
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
            updateNotification("校园加速器已连接")
            updateStatus(nativeStatusJson())
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
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(text))
    }
}
