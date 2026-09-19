package com.one.huaji

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.widget.Toast

/// 接收 requestPinAppWidget 的添加成功回调，用于给用户即时反馈。
class PinWidgetReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_PIN_RESULT) {
            Toast.makeText(context, "已添加到桌面，可返回桌面查看", Toast.LENGTH_SHORT).show()
        }
    }

    companion object {
        const val ACTION_PIN_RESULT = "com.one.huaji.ACTION_PIN_WIDGET_RESULT"
    }
}
