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

        // onReceive 默认在**广播主线程**同步执行，而下面这两步都要读盘：
        //   - showNotification 会走 packageManager / NotificationManager；
        //   - scheduleNextReminder 内部是 AppWidget.readJson + readSettings
        //     （两个 JSON 文件的完整读取 + 解析）再重排闹钟。
        // 主线程上的文件 I/O 一旦遇到存储抖动（低端机、杀后台后的冷启动、
        // 外部存储挂载）就可能吃掉几秒，直接顶到广播 10 秒上限 → ANR。
        //
        // goAsync() 把这次广播的「完成信号」交回给自己：主线程立刻返回，读盘与
        // 调度挪到后台线程执行。代价是必须自己负责收尾 —— 后台线程结束时调用
        // pendingResult.finish()，否则系统仍会判定广播超时（并且 PendingResult
        // 未 finish 会持续占用广播配额）。
        //
        // 注意：finish() 只调用**恰好一次**，因此后台任务整体包在
        // try/catch/finally 里，由 finally 负责收尾。
        val pendingResult = goAsync()
        // 用 applicationContext：goAsync 之后接收器随时可能被回收，
        // 而 application context 与进程同寿命，后台线程里用它最稳。
        val appContext = context.applicationContext

        val work = Thread({
            try {
                // showNotification 在后台线程调用 NotificationManager 是安全的：
                // 这些都是 Binder 调用，本身与线程无关，通知内容与既有行为完全一致。
                showNotification(appContext, name, start, teacher, room)
                // 弹完后重新调度下一节课的提醒。
                AppWidget.scheduleNextReminder(appContext)
            } catch (t: Throwable) {
                // 这条线程不属于任何框架，未捕获异常会直接杀进程。提醒失败不该
                // 让 App 崩掉，与 AppWidget 内部「提醒链路异常静默跳过」保持一致。
                // 异常类型不记录，避免把课程/教师/教室等个人信息写进日志。
            } finally {
                // 恰好一次：正常、异常、提前 return 三条路径都走这里。
                pendingResult.finish()
            }
        }, "ReminderReceiver")

        try {
            work.start()
        } catch (t: Throwable) {
            // 极端情况（如 OOM 导致无法创建线程）：此时后台任务根本没跑，
            // 上面那个 finally 不会执行，所以这里必须自己把广播还给系统一次，
            // 否则这次广播会一直挂到超时。仍然是「恰好一次」。
            pendingResult.finish()
        }
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
            // Lock-screen privacy: course, teacher and room stay on the
            // unlocked device; the public (locked) version is generic.
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(
                if (android.os.Build.VERSION.SDK_INT >= 26) {
                    Notification.Builder(context, channelId)
                        .setSmallIcon(R.drawable.ic_stat_notification)
                        .setContentTitle("稽之查")
                        .setContentText("你有一条上课提醒")
                        .setAutoCancel(true)
                        .build()
                } else {
                    @Suppress("DEPRECATION")
                    Notification.Builder(context)
                        .setSmallIcon(R.drawable.ic_stat_notification)
                        .setContentTitle("稽之查")
                        .setContentText("你有一条上课提醒")
                        .setAutoCancel(true)
                        .build()
                },
            )
        if (pending != null) builder.setContentIntent(pending)
        manager.notify(1001, builder.build())
    }
}
