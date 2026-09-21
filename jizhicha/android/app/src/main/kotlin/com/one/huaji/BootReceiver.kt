package com.one.huaji

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/// 开机 / 应用更新后重新排定上课提醒。
///
/// Android 在**重启**和**应用被更新**时都会清空本应用已注册的全部闹钟，
/// 而小组件侧的 30 分钟 `APPWIDGET_UPDATE` 心跳在 Doze/HyperOS 下并不可靠。
/// 没有这个接收器时，重启或覆盖安装后上课提醒会**静默失效**，直到用户
/// 手动打开 App（或系统碰巧刷新了小组件）才会重新排上。
///
/// 这里只做「重排 + 刷新小组件」两件事，不启动任何前台服务，也不读账号数据；
/// `scheduleNextReminder` 在没有课表数据时会自行 `cancelReminder`，是安全的空操作。
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            ACTION_QUICKBOOT_POWERON,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            -> {
                AppWidget.refreshAll(context)
                AppWidget.scheduleNextReminder(context)
            }
        }
    }

    private companion object {
        /// 部分厂商（小米/OPPO/vivo）在「快速开机」时发这个广播而不是
        /// `ACTION_BOOT_COMPLETED`，两个都要接。
        const val ACTION_QUICKBOOT_POWERON = "android.intent.action.QUICKBOOT_POWERON"
    }
}
