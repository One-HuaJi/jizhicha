package com.one.huaji

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.os.Build
import android.util.Log
import android.widget.RemoteViews
import org.json.JSONObject
import java.io.File
import java.util.Calendar
import java.util.concurrent.TimeUnit

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

        /// 作息季节：5 月 1 日–9 月 30 日为夏季，其余日期为春秋冬季。
        /// 与 Dart 侧 `ScheduleTimeTable.resolveMode`（`month >= 5 && month <= 9`）一致。
        ///
        /// ⚠️ 这里只是**选列规则**，不是第二份作息表：具体的 22 个时刻唯一定义在
        /// Dart 侧 `lib/schedule_time.dart` 的 `ScheduleTimeTable`，由 Flutter 转录进
        /// widget_schedule.json 的 `times` 字段。Kotlin 侧永远不硬编码 HH:mm。
        private const val SEASON_SPRING_AUTUMN_WINTER = "springAutumnWinter"
        private const val SEASON_SUMMER = "summer"

        /// 小组件 JSON 里 `scheduleTimeMode` / `times` 的字段名。
        private const val FIELD_SCHEDULE_TIME_MODE = "scheduleTimeMode"
        private const val FIELD_TIMES = "times"
        private const val FIELD_SEMESTER_START_DATE = "semesterStartDate"

        /// 「自动」模式：`times` 里的两列由**设备当天日期**决定用哪一列。
        /// 与 Dart 侧 `ScheduleTimeMode.automatic.storageValue` 一致。
        private const val MODE_AUTOMATIC = "automatic"

        private const val TAG = "AppWidget"

        /// release 版本不打任何调试日志（app 模块不生成 BuildConfig，
        /// 所以用 ApplicationInfo.FLAG_DEBUGGABLE 判断，与 CampusVpnService 同一套模式）。
        private var debugLogging = false

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

            // 同一个 Calendar 贯穿本次刷新：周次、季节列、下一节课的排序基准都用它，
            // 避免跨午夜/跨季节边界时三个判断各自取到不同的一天。
            val now = Calendar.getInstance()
            debugLogging =
                (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
            // 周次不再直接读 `week` 快照：App 多周不打开时它会停在旧值，
            // weekValue 优先用落盘的 semesterStartDate 按当天日期现算。
            val week = json?.let { weekValue(it, now) } ?: 0
            if (debugLogging) {
                // 只打"解析出的选择"，不打任何课程内容/学生信息。
                val mode = json?.optString(FIELD_SCHEDULE_TIME_MODE, MODE_AUTOMATIC)
                    ?: MODE_AUTOMATIC
                Log.d(TAG, "update: mode=$mode season=${seasonFor(mode, now)} week=$week")
            }
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
                    // json 在此分支必非空；用局部变量让编译器完成智能转换。
                    val data = json
                    val next = findNextClass(data, now)
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
                // 周次同样不能只信快照：App 多周不打开时 `week` 会停在旧值。
                // weekValue 优先用落盘的 semesterStartDate 按当天日期现算。
                val week = weekValue(json, Calendar.getInstance())
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
            /// 本节课**按当天日期解析后**的开始时刻。
            ///
            /// 不叫快照：`parseCourses` 已经按 `scheduleTimeMode` + 设备当天日期选过季了，
            /// 因此下游的渲染（`widget_time`）与提醒（`reminderTriggerAt` 解析 "HH:mm"）
            /// 自动都拿到正确季节的时刻，不需要各自再判一次季节。
            val start: String,
            val name: String,
            val teacher: String,
            val room: String,
            val weeks: List<Int>,
            /// 本节课按当天日期解析后的结束时刻（旧版只读 `start`，这里补齐）。
            val endText: String = "",
        )

        internal data class ReminderTarget(
            val course: Course,
            val triggerAt: Long,
        )

        /// 解析全部课程（不做周次过滤），由调用方按各自口径筛选。
        ///
        /// 时刻在这里一次性按「模式 + 当天日期」解析完毕：
        /// - 固定模式取用户选定那一列（快照即用户意图，不会过期）；
        /// - `automatic` 取当天月份对应的那一列 —— App 几周不打开也能自愈；
        /// - 旧 JSON 没有 `times` 时回退 `start`/`end` 快照（向后兼容，不空白）。
        ///
        /// [now] 与 [mode] 只在测试里注入，生产路径读系统时钟与 JSON 里的模式字段。
        internal fun parseCourses(
            json: JSONObject,
            now: Calendar = Calendar.getInstance(),
            mode: String = json.optString(FIELD_SCHEDULE_TIME_MODE, MODE_AUTOMATIC),
        ): List<Course> {
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
                val columns = parseTimeColumns(obj)
                val season = seasonFor(mode, now)
                val start = columns?.get(season)?.get("start")
                    ?: obj.optString("start", "")
                val end = columns?.get(season)?.get("end")
                    ?: obj.optString("end", "")
                all.add(
                    Course(
                        day = obj.optInt("day", 0),
                        start = start,
                        name = obj.optString("name", ""),
                        teacher = obj.optString("teacher", ""),
                        room = obj.optString("room", ""),
                        weeks = weekList,
                        endText = end,
                    ),
                )
            }
            return all
        }

        /// 读取课程对象里的双季节时刻表；字段缺失/形状不对一律返回 null。
        ///
        /// 返回 null 等价于"按旧协议走"：渲染与提醒都用 `start` 快照。**旧版 app 写的
        /// JSON 走的正是这条路径**，因此不会崩、也不会显示空白。
        private fun parseTimeColumns(obj: JSONObject): Map<String, Map<String, String>>? {
            val times = obj.optJSONObject(FIELD_TIMES) ?: return null
            val result = HashMap<String, Map<String, String>>(2)
            for (season in listOf(SEASON_SPRING_AUTUMN_WINTER, SEASON_SUMMER)) {
                val column = times.optJSONObject(season) ?: continue
                val start = column.optString("start", "")
                val end = column.optString("end", "")
                if (start.isEmpty() || end.isEmpty()) continue
                result[season] = mapOf("start" to start, "end" to end)
            }
            return result.ifEmpty { null }
        }

        /// 按 `scheduleTimeMode` 与**设备当天日期**决定用哪一列时刻。
        ///
        /// - 固定模式（`springAutumnWinter` / `summer`）：永远用用户选定的那一列，
        ///   这是用户显式表达的意图，必须尊重（真机上实测就是固定春秋冬季）。
        /// - 自动模式（`automatic`，也是缺失/写坏时的兜底）：按当天月份在春秋冬季 /
        ///   夏季之间切换 —— 这正是修掉"跨季节后小组件仍显示旧季节时刻"的关键。
        internal fun seasonFor(mode: String, now: Calendar): String = when (mode) {
            SEASON_SPRING_AUTUMN_WINTER -> SEASON_SPRING_AUTUMN_WINTER
            SEASON_SUMMER -> SEASON_SUMMER
            else -> seasonForMonth(now)
        }

        /// 当天月份决定季节：5–9 月夏季，其余春秋冬季。
        /// 与 Dart 侧 `ScheduleTimeTable.resolveMode`（`month >= 5 && month <= 9`）一致。
        internal fun seasonForMonth(now: Calendar): String =
            if (now.get(Calendar.MONTH) in 4..8) SEASON_SUMMER else SEASON_SPRING_AUTUMN_WINTER

        /// 当前周次：**优先按落盘的 `semesterStartDate` + 当天日期现算**。
        ///
        /// 旧协议只落盘 `week` 快照，App 多周不打开就会一直显示旧的「第 N 周」，
        /// 且 30 分钟轮询也纠正不了。新版 JSON 带 `semesterStartDate`，Kotlin 侧
        /// 现算即可自愈。算法逐条抄自 Dart 侧 `AcademicCalendar.weekNumberFor`。
        internal fun weekValue(json: JSONObject, today: Calendar): Int {
            val start = parseSemesterStart(json)
                ?: return json.optInt("week", 0)
            return weekNumberFor(start, today)
        }

        /// 周次算法（与 Dart `AcademicCalendar.weekNumberFor` 逐条一致）：
        /// 第一周从开学日当天算起；早于开学日返回 0（小组件据此显示「还没开学」）；
        /// 超过 MAX_WEEK 显示「本学期已结束」。Dart 侧 `DateTime.difference(...).inDays`
        /// 对带时间戳的 `now` 向零截断，这里把 `now` 归零到当天 00:00 后取整天数，
        /// 语义等价且不受本地时区偏移（如 +08:00，会少算 8 小时的余数）影响。
        internal fun weekNumberFor(start: Calendar, now: Calendar): Int {
            val startDay = startOfDay(start)
            val nowDay = startOfDay(now)
            if (nowDay < startDay) return 0
            val days = TimeUnit.MILLISECONDS.toDays(nowDay - startDay)
            return (days / 7).toInt() + 1
        }

        /// 解析 `semesterStartDate`（`yyyy-MM-dd`）。缺失/非法返回 null → 回退 `week` 快照。
        private fun parseSemesterStart(json: JSONObject): Calendar? {
            val raw = json.optString(FIELD_SEMESTER_START_DATE, "")
            if (raw.length < 10) return null
            val year = raw.substring(0, 4).toIntOrNull() ?: return null
            val month = raw.substring(5, 7).toIntOrNull() ?: return null
            val day = raw.substring(8, 10).toIntOrNull() ?: return null
            if (month !in 1..12 || day !in 1..31) return null
            return try {
                (Calendar.getInstance()).apply {
                    clear()
                    set(year, month - 1, day, 0, 0, 0)
                }
            } catch (_: Exception) {
                null
            }
        }

        private fun startOfDay(source: Calendar): Long =
            (source.clone() as Calendar).apply {
                set(Calendar.HOUR_OF_DAY, 0)
                set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
            }.timeInMillis

        /// 课程是否在 [targetWeek] 这周上。
        /// weeks 为空表示 Dart 侧未能解析出周次，按「每周都有」处理：宁可多显示一节
        /// 课，也不要让学生因脏数据漏掉一节课。
        internal fun runsInWeek(course: Course, targetWeek: Int): Boolean {
            return course.weeks.isEmpty() || targetWeek in course.weeks
        }

        /// 跨周换算：7 天前瞻窗口会落到下一周（例如周日看明天周一），此时必须用
        /// week+1 过滤单双周课程，否则周日晚会把下周一不该上的课当成「下一节课」。
        ///
        /// 「今天」由调用方传入（原先是内部读 `todayIso()` 的私有重载；本次改造把
        /// 调用方统一成持有同一个 `Calendar` 的 `findNextClass` / `nextReminderTargetAt`，
        /// 于是那个私有重载变成死代码，已删除）。
        internal fun weekForOffsetAt(today: Int, week: Int, dayOffset: Int): Int {
            return if (today + dayOffset <= 7) week else week + 1
        }

        /// 显示用：未来 7 天内（含今天剩余）最近的一节课。
        ///
        /// [now] 由调用方传入同一次刷新共用的 Calendar（周次/季节/排序同一基准）。
        private fun findNextClass(json: JSONObject, now: Calendar): Course? {
            val nowMinutes =
                now.get(Calendar.HOUR_OF_DAY) * 60 + now.get(Calendar.MINUTE)
            return findNextClassAt(json, todayIso(), nowMinutes, now)
        }

        /// 可注入「今天」「当日分钟数」与「当天日期」的下一节课查询（仅供测试复用）。
        ///
        /// [now] 同时决定季节列与周次现算基准，生产路径传系统时钟。
        internal fun findNextClassAt(
            json: JSONObject,
            today: Int,
            nowMinutes: Int,
            now: Calendar = Calendar.getInstance(),
        ): Course? {
            // 周次不能只信快照：App 多周不打开时 `week` 会停在旧值，
            // weekValue 优先用落盘的 semesterStartDate 按当天日期现算。
            val week = weekValue(json, now)

            var best: Course? = null
            var bestOffset = Int.MAX_VALUE
            for (course in parseCourses(json, now)) {
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
        ///
        /// [base] 同时是三处判断的同一基准：季节列的日期、`weekValue` 的"今天"、
        /// `reminderTriggerAt` 解析 `course.start`（已按季节解析过）的日期。
        /// 用同一个 Calendar 保证跨午夜/跨季节时三者不会各自取到不同的一天。
        internal fun nextReminderTargetAt(
            json: JSONObject,
            week: Int,
            reminderMinutes: Int,
            today: Int,
            nowMillis: Long,
            base: Calendar,
        ): ReminderTarget? {
            var best: ReminderTarget? = null
            // 按 base 的日期选季节：提醒走的必须与渲染完全同一套解析，
            // 否则跨季节时"显示夏季时刻、闹钟按春秋冬季响"。
            for (course in parseCourses(json, base)) {
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
