package com.one.huaji

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/// 上课提醒闹钟触发后的广播接收器：弹系统通知，并重新调度下一节课。
class ReminderReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val name = intent.getStringExtra("name") ?: ""
        val start = intent.getStringExtra("start") ?: ""
        val teacher = intent.getStringExtra("teacher") ?: ""
        val room = intent.getStringExtra("room") ?: ""

        showNotification(context, name, start, teacher, room)
        // 弹完后重新调度下一节课的提醒。
        AppWidget.scheduleNextReminder(context)
    }

    private fun showNotification(
        context: Context,
        name: String,
        start: String,
        teacher: String,
        room: String,
    ) {
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = "class_reminder"
        if (android.os.Build.VERSION.SDK_INT >= 26) {
            val channel = NotificationChannel(
                channelId,
                "上课提醒",
                NotificationManager.IMPORTANCE_HIGH,
            )
            manager.createNotificationChannel(channel)
        }

        val launchIntent =
            context.packageManager.getLaunchIntentForPackage(context.packageName)
        val pending = if (launchIntent != null) {
            PendingIntent.getActivity(
                context,
                0,
                launchIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        } else {
            null
        }

        val detail = if (teacher.isNotEmpty() || room.isNotEmpty()) {
            teacher + " · " + room
        } else {
            ""
        }
        val contentText = if (detail.isNotEmpty()) start + "  " + detail else start

        val builder = if (android.os.Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(context, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        builder
            .setSmallIcon(R.drawable.ic_stat_notification)
            .setContentTitle("上课提醒：" + name)
            .setContentText(contentText)
            .setAutoCancel(true)
        if (pending != null) builder.setContentIntent(pending)
        manager.notify(1001, builder.build())
    }
}
