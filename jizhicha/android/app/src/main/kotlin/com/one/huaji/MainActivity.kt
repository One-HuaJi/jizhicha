package com.one.huaji

import android.Manifest
import android.app.NotificationManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.one.huaji/android_vpn"
        private const val WIDGET_CHANNEL = "com.one.huaji/widget_settings"
        private const val NOTIFICATION_PERMISSION_REQUEST = 1001
    }

    /// 尚未回应的通知权限请求。必须保证 result 恰好被调用一次：
    /// onRequestPermissionsResult 正常回应，onDestroy 兜底回 false，
    /// 否则 Dart 侧的 Future 会永久挂起。
    private var pendingNotificationResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(android.os.Build.VERSION.SDK_INT >= 26)
                "prepare" -> {
                    val intent = VpnService.prepare(this)
                    if (intent == null) {
                        result.success(true)
                    } else {
                        startActivityForResult(intent, CampusVpnService.permissionRequestCode())
                        result.success(false)
                    }
                }
                "connect" -> {
                    val username = call.argument<String>("username").orEmpty()
                    val password = call.argument<String>("password").orEmpty()
                    val authSource = call.argument<String>("authSource") ?: "SAM-all"
                    if (VpnService.prepare(this) != null) {
                        result.error("VPN_PERMISSION", "请先允许 Android 系统网络授权", null)
                    } else {
                        CampusVpnService.startConnect(this, username, password, authSource)
                        result.success(true)
                    }
                }
                "status" -> result.success(CampusVpnService.status())
                "disconnect" -> {
                    CampusVpnService.stop(this)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // 小组件设置：打开电池优化 / 自启动权限页（小米后台优化一键入口）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WIDGET_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openBatteryOptimization" -> {
                        openBatteryOptimization()
                        result.success(true)
                    }
                    "openAutostart" -> {
                        openAutostart()
                        result.success(true)
                    }
                    "refreshWidget" -> {
                        refreshWidget()
                        result.success(true)
                    }
                    "clearWidgetData" -> {
                        clearWidgetData()
                        result.success(true)
                    }
                    "requestPinWidget" -> {
                        requestPinWidget(result)
                    }
                    "notificationsEnabled" -> result.success(notificationsEnabled())
                    "requestNotificationPermission" ->
                        requestNotificationPermission(result)
                    "canScheduleExactAlarm" ->
                        result.success(AppWidget.canScheduleExactAlarm(this))
                    "openExactAlarmSettings" -> {
                        openExactAlarmSettings()
                        result.success(true)
                    }
                    "openNotificationSettings" -> {
                        openNotificationSettings()
                        result.success(true)
                    }
                    "shareFile" -> {
                        val path = call.argument<String>("path").orEmpty()
                        val mime = call.argument<String>("mimeType")
                            ?: "application/octet-stream"
                        val subject = call.argument<String>("subject").orEmpty()
                        if (path.isEmpty()) {
                            result.error("BAD_ARGS", "缺少 path", null)
                        } else {
                            try {
                                shareFile(path, mime, subject)
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("SHARE_FAILED", e.message ?: "分享失败", null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// 通过系统分享面板发送应用私有目录里的文件。
    ///
    /// 必须走 FileProvider 生成 content:// URI 并显式授予读权限：
    /// Android 7(API 24) 起传 file:// 会直接抛 FileUriExposedException，
    /// 且接收方（微信/QQ/邮件）没有我们私有目录的读权限。
    private fun shareFile(path: String, mimeType: String, subject: String) {
        val file = java.io.File(path)
        if (!file.exists()) {
            throw java.io.FileNotFoundException("文件不存在：$path")
        }
        val uri = androidx.core.content.FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            file,
        )
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = mimeType
            putExtra(Intent.EXTRA_STREAM, uri)
            if (subject.isNotEmpty()) putExtra(Intent.EXTRA_SUBJECT, subject)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = Intent.createChooser(intent, "分享自评表").apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            // 从非 Activity 上下文启动时需要
            if (this@MainActivity !is android.app.Activity) {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        }
        startActivity(chooser)
    }

    private fun openBatteryOptimization() {
        try {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        } catch (_: Exception) {
            openAppDetails()
        }
    }

    private fun openAutostart() {
        // 小米/HyperOS 自启动管理页（非公开 API，失败则回退到应用详情页）。
        try {
            val intent = Intent("miui.intent.action.APP_PERM_EDITOR")
            intent.setClassName(
                "com.miui.securitycenter",
                "com.miui.permcenter.autostart.AutoStartManagementActivity",
            )
            intent.putExtra("extra_pkgname", packageName)
            startActivity(intent)
        } catch (_: Exception) {
            openAppDetails()
        }
    }

    private fun openAppDetails() {
        try {
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            intent.data = Uri.parse("package:$packageName")
            startActivity(intent)
        } catch (_: Exception) {
        }
    }

    private fun refreshWidget() {
        // 与「开机 / 应用更新」路径共用同一份刷新实现（AppWidget.refreshAll），
        // 避免两处各抄一遍 widgetId 遍历后行为漂移。
        AppWidget.refreshAll(this)
        AppWidget.scheduleNextReminder(this)
    }

    /**
     * Privacy cleanup for account deletion / switch to an account without a
     * schedule. Widget JSON is a global app file, so leaving it behind would
     * show the prior student's course, teacher and room on the launcher.
     */
    private fun clearWidgetData() {
        try {
            val flutterDir = getDir("flutter", MODE_PRIVATE)
            java.io.File(flutterDir, "widget_schedule.json").delete()
        } catch (_: Exception) {
        }
        AppWidget.cancelReminder(this)
        refreshWidget()
    }

    private fun requestPinWidget(result: MethodChannel.Result) {
        try {
            val manager = AppWidgetManager.getInstance(this)
            val component = ComponentName(this, AppWidget::class.java)
            if (!manager.isRequestPinAppWidgetSupported) {
                // 桌面不支持程序化添加（小米/部分第三方桌面常见）：给出可执行的引导。
                result.error(
                    "NOT_SUPPORTED",
                    "当前桌面不支持一键添加，请长按桌面空白处手动添加「稽之查·下一节课」小组件",
                    null,
                )
                return
            }
            // 部分桌面要求 successCallback 非空才真正完成添加，同时用它给用户即时反馈。
            val callbackIntent = Intent(this, PinWidgetReceiver::class.java).apply {
                action = PinWidgetReceiver.ACTION_PIN_RESULT
            }
            val callback = PendingIntent.getBroadcast(
                this,
                0,
                callbackIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val sent = manager.requestPinAppWidget(component, null, callback)
            if (sent) {
                // 系统会弹出「添加到主屏幕」确认框，用户点「添加」后触发 successCallback。
                result.success(true)
            } else {
                result.error("PIN_FAILED", "系统未接受添加请求，请长按桌面空白处手动添加小组件", null)
            }
        } catch (e: Exception) {
            result.error("PIN_FAILED", e.message ?: "一键添加失败，请长按桌面空白处手动添加小组件", null)
        }
    }

    /// 通知总开关是否打开（用户可在系统设置里单独关掉）。
    private fun notificationsEnabled(): Boolean {
        return try {
            val manager = getSystemService(NotificationManager::class.java)
            manager.areNotificationsEnabled()
        } catch (_: Exception) {
            false
        }
    }

    /// 运行时申请 POST_NOTIFICATIONS。Android 13 以下没有该运行时权限，直接回报
    /// 当前开关状态；已授权时也直接回报，不重复弹框。
    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(notificationsEnabled())
            return
        }
        val granted = checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (granted) {
            result.success(true)
            return
        }
        if (pendingNotificationResult != null) {
            // 已有请求在飞：直接回 false，避免同一个 result 被调用两次抛异常。
            result.success(false)
            return
        }
        pendingNotificationResult = result
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST,
        )
    }

    /// 打开「闹钟和提醒」授权页（Android 12+）。失败回退到应用详情页。
    private fun openExactAlarmSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        try {
            val intent = Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
                data = Uri.parse("package:$packageName")
            }
            startActivity(intent)
        } catch (_: Exception) {
            openAppDetails()
        }
    }

    /// 打开本应用的通知设置页（用户永久拒绝权限后只能从这里重新打开）。
    private fun openNotificationSettings() {
        try {
            val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            }
            startActivity(intent)
        } catch (_: Exception) {
            openAppDetails()
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        // 必须调 super：Flutter 插件（如 gal 的存储权限）也走这条回调。
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST) return
        val pending = pendingNotificationResult ?: return
        pendingNotificationResult = null
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pending.success(granted)
    }

    override fun onDestroy() {
        // 欠 Dart 的回应必须在销毁前补上，否则 invokeMethod 的 Future 永久挂起。
        pendingNotificationResult?.success(false)
        pendingNotificationResult = null
        super.onDestroy()
    }

    @Suppress("UNUSED_PARAMETER")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
    }
}
