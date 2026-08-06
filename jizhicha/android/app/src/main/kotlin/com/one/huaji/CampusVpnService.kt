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
        }
    }

    private val handler = Handler(Looper.getMainLooper())
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
        when (intent?.action) {
            ACTION_CONNECT -> {
                startForeground(NOTIFICATION_ID, buildNotification("正在连接校园加速器"))
                val username = intent.getStringExtra(EXTRA_USERNAME).orEmpty()
                val password = intent.getStringExtra(EXTRA_PASSWORD).orEmpty()
                val source = intent.getStringExtra(EXTRA_AUTH_SOURCE) ?: "SAM-all"
                beginConnect(username, password, source)
            }
            ACTION_DISCONNECT -> disconnectAndStop()
        }
        return START_NOT_STICKY
    }

    private fun beginConnect(username: String, password: String, source: String) {
        handler.removeCallbacksAndMessages(null)
        closeTun()
        nativeStarted = false
        val result = nativePrepare(username, password, source)
        if (result != 0) {
            updateStatus("{\"connected\":false,\"stage\":\"native_error\",\"error\":\"native prepare failed ($result)\"}")
            return
        }
        handler.post(pollForTun)
    }

    private val pollForTun = object : Runnable {
        override fun run() {
            val statusText = runCatching { nativeStatusJson() }.getOrElse {
                "{\"connected\":false,\"stage\":\"native_error\",\"error\":\"${it.message}\"}"
            }
            updateStatus(statusText)
            val status = runCatching { JSONObject(statusText) }.getOrNull()
            when (status?.optString("stage")) {
                "awaiting_tun" -> establishTun(status)
                "connected", "tunnel_stopped", "heartbeat_error" -> {
                    if (status.optBoolean("connected", false)) {
                        updateNotification("校园加速器已连接")
                    }
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
            updateStatus(
                "{\"connected\":false,\"stage\":\"adapter_error\",\"error\":${JSONObject.quote(error.message ?: "failed to establish Android accelerator")}}"
            )
            handler.removeCallbacks(pollForTun)
            nativeDisconnect()
        }
    }

    private fun disconnectAndStop() {
        handler.removeCallbacksAndMessages(null)
        nativeDisconnect()
        updateStatus(nativeStatusJson())
        nativeStarted = false
        closeTun()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun closeTun() {
        runCatching { tun?.close() }
        tun = null
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        nativeDisconnect()
        closeTun()
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
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle("稽之查")
                .setContentText(text)
                .setContentIntent(pendingIntent)
                .setOngoing(true)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setSmallIcon(R.mipmap.ic_launcher)
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
