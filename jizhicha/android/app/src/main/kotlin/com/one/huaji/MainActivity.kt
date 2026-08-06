package com.one.huaji

import android.content.Intent
import android.net.VpnService
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.one.huaji/android_vpn"
    }

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
    }

    @Suppress("UNUSED_PARAMETER")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
    }
}
