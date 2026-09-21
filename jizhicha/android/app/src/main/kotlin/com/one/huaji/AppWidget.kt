package com.one.huaji

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.widget.RemoteViews
import org.json.JSONObject
import java.io.File
import java.util.Calendar

/// 桌面小组件：显示「下一节课」（时间 / 课程名 / 老师 / 教室），并调度上课提醒闹钟。
/// 数据来自 Flutter 侧写入的 widget_schedule.json（位于应用文档目录）。
class AppWidget : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        // 课表与设置只读一次，再传给每个 widgetId，避免 N 个实例重复读盘解析。
        val json = readJson(context)
        val settings = readSettings(context)
        for (widgetId in appWidgetIds) {
            updateWidget(context, appWidgetManager, widgetId, json, settings)
        }
        scheduleNextReminder(context)
    }

    override fun onEnabled(context: Context) {
        scheduleNextReminder(context)
    }

    override fun onDisabled(context: Context) {
        cancelReminder(context)
    }

    companion object {
        private const val FILE_NAME = "widget_schedule.json"
        private const val SETTINGS_FILE_NAME = "widget_settings.json"
        const val ACTION_REMINDER = "com.one.huaji.ACTION_CLASS_REMINDER"

        /// 每学期按 20 周显示；与 Dart 侧 AcademicCalendar.weeksPerAcademicYear 一致。
        private const val MAX_WEEK = 20

        /// 未授权精确闹钟时 setWindow 的容许窗口（毫秒）。
        private const val INEXACT_WINDOW_MS = 120_000L

        /// 保留原签名：自行读盘后转调带参重载。
        fun updateWidget(context: Context, manager: AppWidgetManager, widgetId: Int) {
            updateWidget(context, manager, widgetId, readJson(context), readSettings(context))
        }

        /// 刷新全部已添加的小组件实例。
        ///
        /// 抽出来是为了让「开机 / 应用更新」路径也能复用同一份刷新逻辑，
        /// 避免在接收器里再抄一遍 widgetId 遍历。
        fun refreshAll(context: Context) {
            try {
                val manager = AppWidgetManager.getInstance(context)
                val component = ComponentName(context, AppWidget::class.java)
                // 读盘只做一次，多个实例共用同一份数据。
                val json = readJson(context)
                val settings = readSettings(context)
                for (id in manager.getAppWidgetIds(component)) {
                    updateWidget(context, manager, id, json, settings)
                }
            } catch (_: Exception) {
                // 刷新失败不影响提醒重排。
            }
        }

        fun updateWidget(
            context: Context,
            manager: AppWidgetManager,
            widgetId: Int,
            json: JSONObject?,
            settings: JSONObject,
        ) {
            val views = RemoteViews(context.packageName, R.layout.appwidget)
            val showTeacherRoom = settings.optBoolean("showTeacherRoom", true)

            val week = json?.optInt("week", 0) ?: 0
            when {
                json == null -> {
                    views.setTextViewText(R.id.widget_title, "暂无课表")
                    views.setTextViewText(R.id.widget_time, "--:--")
                    views.setTextViewText(R.id.widget_name, "请登录并同步课表")
                    views.setTextViewText(R.id.widget_detail, "")
                }
                week < 1 -> {
                    views.setTextViewText(R.id.widget_title, "还没开学")
                    views.setTextViewText(R.id.widget_time, "--:--")
                    views.setTextViewText(R.id.widget_name, "开学后会显示下一节课")
                    views.setTextViewText(R.id.widget_detail, "")
                }
                week > MAX_WEEK -> {
                    views.setTextViewText(R.id.widget_title, "本学期已结束")
                    views.setTextViewText(R.id.widget_time, "--:--")
                    views.setTextViewText(R.id.widget_name, "好好休息")
                    views.setTextViewText(R.id.widget_detail, "")
                }
                else -> {
                    val next = findNextClass(json)
                    if (next == null) {
                        views.setTextViewText(R.id.widget_title, "近期没有课")
                        views.setTextViewText(R.id.widget_time, "--:--")
                        views.setTextViewText(R.id.widget_name, "好好休息")
                        views.setTextViewText(R.id.widget_detail, "")
                    } else {
                        views.setTextViewText(R.id.widget_title, "下一节课")
                        views.setTextViewText(R.id.widget_time, next.start)
                        views.setTextViewText(R.id.widget_name, next.name)
                        val detail =
                            if (showTeacherRoom) next.teacher + " · " + next.room else ""
                        views.setTextViewText(R.id.widget_detail, detail)
                    }
                }
            }

            val launchIntent =
                context.packageManager.getLaunchIntentForPackage(context.packageName)
            if (launchIntent != null) {
                val pending = PendingIntent.getActivity(
                    context,
                    0,
                    launchIntent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
                views.setOnClickPendingIntent(R.id.widget_root, pending)
            }

            manager.updateAppWidget(widgetId, views)
        }

        /// 调度下一个还需要提醒的上课闹钟（课前 reminderMinutes 分钟）。
        ///
        /// 关键点：必须挑「提醒时刻仍在未来」的那节课，而不是先挑最近的一节课再判断
        /// 它的提醒时刻是否已过。提醒刚触发时本节仍在未来（几分钟后才上课），旧逻辑会
        /// 选中它、算出 triggerAt <= now 后直接 return，导致下一节课的提醒永远排不上，
        /// 只能等 30 分钟的 APPWIDGET_UPDATE 心跳补救（Doze/HyperOS 下并不可靠），
        /// 连堂课必然漏提醒。
        fun scheduleNextReminder(context: Context) {
            try {
                // Missing/corrupt widget JSON means account data was removed or
                // no longer usable. Cancel the old PendingIntent before returning;
                // otherwise an already scheduled reminder can expose prior-user
                // course/teacher/room information after logout/data deletion.
                val json = readJson(context) ?: run {
                    cancelReminder(context)
                    return
                }
                val settings = readSettings(context)
                if (!settings.optBoolean("reminderEnabled", true)) {
                    cancelReminder(context)
                    return
                }
                val week = json.optInt("week", 0)
                if (week < 1 || week > MAX_WEEK) {
                    cancelReminder(context)
                    return
                }
                val reminderMinutes = settings.optInt("reminderMinutes", 10)
                val target = nextReminderTarget(json, week, reminderMinutes)
                if (target == null) {
                    // 未来 7 天内没有还需要提醒的课：清掉旧闹钟，避免它再响一次。
                    cancelReminder(context)
                    return
                }

                val alarm = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
                val intent = Intent(context, ReminderReceiver::class.java).apply {
                    action = ACTION_REMINDER
                    putExtra("name", target.course.name)
                    putExtra("start", target.course.start)
                    putExtra("teacher", target.course.teacher)
                    putExtra("room", target.course.room)
                }
                val pending = PendingIntent.getBroadcast(
                    context,
                    0,
                    intent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
                // Android 12(API 31) 起精确闹钟需用户授权，targetSdk 33+ 默认拒绝，
                // 未授权时 setExactAndAllowWhileIdle 抛 SecurityException。降级为窗口
                // 闹钟（不精确但无需权限），保证提醒不会完全失效。
                if (canScheduleExactAlarm(context)) {
                    alarm.setExactAndAllowWhileIdle(
                        AlarmManager.RTC_WAKEUP,
                        target.triggerAt,
                        pending,
                    )
                } else {
                    alarm.setWindow(
                        AlarmManager.RTC_WAKEUP,
                        target.triggerAt,
                        INEXACT_WINDOW_MS,
                        pending,
                    )
                }
            } catch (_: Exception) {
                // 其它异常时静默跳过，不影响小组件渲染。
            }
        }

        /// 当前是否可以使用精确闹钟。API 31 以下无需授权。
        fun canScheduleExactAlarm(context: Context): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
            return try {
                val alarm = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
                alarm.canScheduleExactAlarms()
            } catch (_: Exception) {
                false
            }
        }

        fun cancelReminder(context: Context) {
            try {
                val alarm = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
                val intent = Intent(context, ReminderReceiver::class.java).apply {
                    action = ACTION_REMINDER
                }
                val pending = PendingIntent.getBroadcast(
                    context,
                    0,
                    intent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_NO_CREATE,
                )
                if (pending != null) alarm.cancel(pending)
            } catch (_: Exception) {
            }
        }

        /// 今天是 ISO 周几：1=周一 … 7=周日。
        private fun todayIso(): Int {
            val dow = Calendar.getInstance().get(Calendar.DAY_OF_WEEK)
            return if (dow == Calendar.SUNDAY) 7 else dow - 1
        }

        private fun reminderTime(next: Course, minutes: Int): Long? {
            return reminderTriggerAt(next, minutes, todayIso(), Calendar.getInstance())
        }

        /// 可注入「今天」与基准时刻的提醒时刻计算。
        ///
        /// 真实调用点只传系统时钟（见上面的 `reminderTime`），行为与改造前完全一致；
        /// 拆出参数是为了让「提醒时刻是否已过」这类边界能在 JVM 单测里确定复现
        /// —— §9.1 的两个提醒 bug 正出在这段逻辑里。
        internal fun reminderTriggerAt(
            next: Course,
            minutes: Int,
            today: Int,
            base: Calendar,
        ): Long? {
            val dayOffset = (next.day - today + 7) % 7
            val parts = next.start.split(":")
            if (parts.size < 2) return null
            val h = parts[0].toIntOrNull() ?: return null
            val m = parts[1].toIntOrNull() ?: return null
            val classTime = (base.clone() as Calendar).apply {
                add(Calendar.DAY_OF_YEAR, dayOffset)
                set(Calendar.HOUR_OF_DAY, h)
                set(Calendar.MINUTE, m)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
            }
            return classTime.timeInMillis - minutes * 60_000L
        }

        internal data class Course(
            val day: Int,
            val start: String,
            val name: String,
            val teacher: String,
            val room: String,
            val weeks: List<Int>,
        )

        internal data class ReminderTarget(
            val course: Course,
            val triggerAt: Long,
        )

        /// 解析全部课程（不做周次过滤），由调用方按各自口径筛选。
        internal fun parseCourses(json: JSONObject): List<Course> {
            val courses = json.optJSONArray("courses") ?: return emptyList()
            val all = ArrayList<Course>(courses.length())
            for (i in 0 until courses.length()) {
                val obj = courses.optJSONObject(i) ?: continue
                val weeksArr = obj.optJSONArray("weeks")
                val weekList = ArrayList<Int>()
                if (weeksArr != null) {
                    for (j in 0 until weeksArr.length()) {
                        weekList.add(weeksArr.optInt(j, -1))
                    }
                }
                all.add(
                    Course(
                        day = obj.optInt("day", 0),
                        start = obj.optString("start", ""),
                        name = obj.optString("name", ""),
                        teacher = obj.optString("teacher", ""),
                        room = obj.optString("room", ""),
                        weeks = weekList,
                    ),
                )
            }
            return all
        }

        /// 课程是否在 [targetWeek] 这周上。
        /// weeks 为空表示 Dart 侧未能解析出周次，按「每周都有」处理：宁可多显示一节
        /// 课，也不要让学生因脏数据漏掉一节课。
        internal fun runsInWeek(course: Course, targetWeek: Int): Boolean {
            return course.weeks.isEmpty() || targetWeek in course.weeks
        }

        /// 跨周换算：7 天前瞻窗口会落到下一周（例如周日看明天周一），此时必须用
        /// week+1 过滤单双周课程，否则周日晚会把下周一不该上的课当成「下一节课」。
        private fun weekForOffset(week: Int, dayOffset: Int): Int {
            return weekForOffsetAt(todayIso(), week, dayOffset)
        }

        /// 可注入「今天」的跨周换算（行为与 `weekForOffset` 完全一致，仅供测试）。
        internal fun weekForOffsetAt(today: Int, week: Int, dayOffset: Int): Int {
            return if (today + dayOffset <= 7) week else week + 1
        }

        /// 显示用：未来 7 天内（含今天剩余）最近的一节课。
        private fun findNextClass(json: JSONObject): Course? {
            val now = Calendar.getInstance()
            val nowMinutes =
                now.get(Calendar.HOUR_OF_DAY) * 60 + now.get(Calendar.MINUTE)
            return findNextClassAt(json, todayIso(), nowMinutes)
        }

        /// 可注入「今天」与「当日分钟数」的下一节课查询（仅供测试复用）。
        internal fun findNextClassAt(
            json: JSONObject,
            today: Int,
            nowMinutes: Int,
        ): Course? {
            val week = json.optInt("week", 0)

            var best: Course? = null
            var bestOffset = Int.MAX_VALUE
            for (course in parseCourses(json)) {
                if (course.day <= 0 || course.start.isEmpty()) continue
                val startMinutes = parseMinutes(course.start) ?: continue
                val dayOffset = (course.day - today + 7) % 7
                val targetWeek = weekForOffsetAt(today, week, dayOffset)
                if (targetWeek > MAX_WEEK) continue
                if (week > 0 && !runsInWeek(course, targetWeek)) continue
                val offset = dayOffset * 24 * 60 + (startMinutes - nowMinutes)
                if (offset >= 0 && offset < bestOffset) {
                    bestOffset = offset
                    best = course
                }
            }
            return best
        }

        /// 提醒用：未来 7 天内「提醒时刻仍在未来」的最早一节课。
        /// 与 findNextClass 的区别是筛选条件基于 triggerAt 而非上课时刻，因此提醒刚
        /// 触发后能正确推进到下一节，而不是原地返回 null。
        private fun nextReminderTarget(
            json: JSONObject,
            week: Int,
            reminderMinutes: Int,
        ): ReminderTarget? {
            return nextReminderTargetAt(
                json = json,
                week = week,
                reminderMinutes = reminderMinutes,
                today = todayIso(),
                nowMillis = System.currentTimeMillis(),
                base = Calendar.getInstance(),
            )
        }

        /// 可注入时钟的提醒目标查询（仅供测试复用；生产路径只传系统时钟）。
        internal fun nextReminderTargetAt(
            json: JSONObject,
            week: Int,
            reminderMinutes: Int,
            today: Int,
            nowMillis: Long,
            base: Calendar,
        ): ReminderTarget? {
            var best: ReminderTarget? = null
            for (course in parseCourses(json)) {
                if (course.day <= 0 || course.start.isEmpty()) continue
                val dayOffset = (course.day - today + 7) % 7
                val targetWeek = weekForOffsetAt(today, week, dayOffset)
                if (targetWeek > MAX_WEEK) continue
                if (!runsInWeek(course, targetWeek)) continue
                val triggerAt = reminderTriggerAt(course, reminderMinutes, today, base)
                    ?: continue
                // 提醒时刻已过（含「距上课不足 reminderMinutes 分钟」）：跳过这节继续
                // 找下一节，而不是直接返回。
                if (triggerAt <= nowMillis) continue
                if (best == null || triggerAt < best.triggerAt) {
                    best = ReminderTarget(course, triggerAt)
                }
            }
            return best
        }

        /// "HH:mm" → 当日分钟数；非法格式返回 null，避免坏数据以「午夜 0 分」参与
        /// 排序而错误地当选下一节课。
        internal fun parseMinutes(hhmm: String): Int? {
            val parts = hhmm.split(":")
            if (parts.size < 2) return null
            val h = parts[0].toIntOrNull() ?: return null
            val m = parts[1].toIntOrNull() ?: return null
            if (h !in 0..23 || m !in 0..59) return null
            return h * 60 + m
        }

        fun readJson(context: Context): JSONObject? {
            return try {
                // 与 path_provider 的 getApplicationDocumentsDirectory 一致：
                // 即 context.getDir("flutter", MODE_PRIVATE)。
                val dir = context.getDir("flutter", Context.MODE_PRIVATE)
                val file = File(dir, FILE_NAME)
                if (!file.exists()) return null
                JSONObject(file.readText())
            } catch (_: Exception) {
                null
            }
        }

        fun readSettings(context: Context): JSONObject {
            return try {
                val dir = context.getDir("flutter", Context.MODE_PRIVATE)
                val file = File(dir, SETTINGS_FILE_NAME)
                if (!file.exists()) JSONObject() else JSONObject(file.readText())
            } catch (_: Exception) {
                JSONObject()
            }
        }
    }
}
