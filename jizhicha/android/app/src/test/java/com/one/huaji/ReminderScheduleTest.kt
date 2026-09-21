package com.one.huaji

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Calendar

/// 提醒调度的纯函数回归测试。
///
/// 这里锁住的是 §9.1 里**真实出过的两个提醒 bug**，它们是纯逻辑问题、
/// 却一直零测试：
///   1. 「提醒刚触发时，下一节课的闹钟永远排不上」——旧实现先挑最近一节课，
///      再判断它的提醒时刻是否已过，已过就 `return`，于是原地卡死；
///   2. 「周日晚把下周一不该上的单双周课当成下一节课」——7 天前瞻跨周后
///      仍用当前周次过滤。
///
/// 所有时间都通过参数注入，因此这些用例在任何日期/时区运行都稳定。
class ReminderScheduleTest {

    // ---------- 辅助 ----------

    private fun json(courses: List<JSONObject>, week: Int = 1): JSONObject {
        val arr = JSONArray()
        courses.forEach { arr.put(it) }
        return JSONObject().apply {
            put("week", week)
            put("courses", arr)
        }
    }

    private fun course(
        day: Int,
        start: String,
        name: String = "课程",
        weeks: List<Int> = emptyList(),
    ): JSONObject = JSONObject().apply {
        put("day", day)
        put("start", start)
        put("name", name)
        put("teacher", "老师")
        put("room", "教室")
        put("weeks", JSONArray(weeks))
    }

    /// 固定到「2026-09-21 周一」这一天的 08:00。
    private fun mondayAt(hour: Int, minute: Int): Calendar =
        Calendar.getInstance().apply {
            set(2026, Calendar.SEPTEMBER, 21, hour, minute, 0)
            set(Calendar.MILLISECOND, 0)
        }

    /// 周一=1 … 周日=7，与 AppWidget.todayIso() 的口径一致。
    private val monday = 1
    private val sunday = 7

    // ---------- parseMinutes ----------

    @Test
    fun parseMinutes_accepts_valid_clock_text() {
        assertEquals(0, AppWidget.parseMinutes("00:00"))
        assertEquals(8 * 60, AppWidget.parseMinutes("08:00"))
        assertEquals(23 * 60 + 59, AppWidget.parseMinutes("23:59"))
    }

    @Test
    fun parseMinutes_rejects_bad_input_instead_of_returning_midnight() {
        // 旧实现返回 0，会让坏数据以「午夜 0 分」参与排序而错误当选下一节课。
        assertNull(AppWidget.parseMinutes(""))
        assertNull(AppWidget.parseMinutes("8"))
        assertNull(AppWidget.parseMinutes("abc:def"))
        assertNull(AppWidget.parseMinutes("24:00"))
        assertNull(AppWidget.parseMinutes("08:60"))
        assertNull(AppWidget.parseMinutes("-1:00"))
    }

    // ---------- runsInWeek ----------

    @Test
    fun runsInWeek_treats_empty_weeks_as_every_week() {
        // 空 weeks 是 Dart 侧解析失败的产物；宁可多显示一节，也不要漏课。
        val c = AppWidget.parseCourses(json(listOf(course(1, "08:00")))).single()
        assertTrue(AppWidget.runsInWeek(c, 1))
        assertTrue(AppWidget.runsInWeek(c, 19))
    }

    @Test
    fun runsInWeek_filters_by_declared_weeks() {
        val c = AppWidget
            .parseCourses(json(listOf(course(1, "08:00", weeks = listOf(1, 3, 5)))))
            .single()
        assertTrue(AppWidget.runsInWeek(c, 3))
        assertTrue(!AppWidget.runsInWeek(c, 2))
    }

    // ---------- weekForOffset（历史 bug 2） ----------

    @Test
    fun weekForOffset_rolls_to_next_week_only_when_the_window_crosses_sunday() {
        // 周一 + 6 天 = 周日，仍属本周。
        assertEquals(5, AppWidget.weekForOffsetAt(monday, 5, 6))
        // 周日 + 1 天 = 下周一，必须换到 week+1。
        assertEquals(6, AppWidget.weekForOffsetAt(sunday, 5, 1))
        // 周日看今天（offset 0）仍是本周。
        assertEquals(5, AppWidget.weekForOffsetAt(sunday, 5, 0))
    }

    @Test
    fun findNextClass_does_not_pick_a_next_week_odd_week_course_on_sunday() {
        // 周日：本周（第 5 周）没有课；下周一（第 6 周）那节只在单周上。
        // 6 是双周 → 不该被选为「下一节课」。
        val data = json(
            courses = listOf(course(1, "08:00", name = "单周课", weeks = listOf(1, 3, 5, 7))),
            week = 5,
        )
        val picked = AppWidget.findNextClassAt(data, today = sunday, nowMinutes = 20 * 60)
        assertNull("周日不应把下周一不该上的单周课当成下一节课", picked)
    }

    @Test
    fun findNextClass_picks_next_week_course_when_week_matches() {
        val data = json(
            courses = listOf(course(1, "08:00", name = "双周课", weeks = listOf(2, 4, 6))),
            week = 5,
        )
        val picked = AppWidget.findNextClassAt(data, today = sunday, nowMinutes = 20 * 60)
        assertEquals("双周课", picked?.name)
    }

    // ---------- nextReminderTarget（历史 bug 1） ----------

    @Test
    fun nextReminderTarget_advances_past_the_class_that_just_triggered() {
        // 这是 bug 1 的核心场景：连堂课。
        // 第一节 08:00 的提醒（提前 10 分钟 = 07:50）刚刚触发，此刻是 07:50:30，
        // 第一节仍在未来（08:00 才上课）。旧实现会选中第一节、算出 triggerAt 已过
        // 然后 return，导致第二节 10:00 的提醒永远排不上。
        val data = json(
            courses = listOf(
                course(1, "08:00", name = "第一节"),
                course(1, "10:00", name = "第二节"),
            ),
        )
        val base = mondayAt(7, 50)
        val now = base.timeInMillis + 30_000 // 07:50:30

        val target = AppWidget.nextReminderTargetAt(
            json = data,
            week = 1,
            reminderMinutes = 10,
            today = monday,
            nowMillis = now,
            base = base,
        )

        assertEquals("必须推进到第二节，而不是原地返回 null", "第二节", target?.course?.name)
        val expected = (base.clone() as Calendar).apply {
            set(Calendar.HOUR_OF_DAY, 10)
            set(Calendar.MINUTE, 0)
        }.timeInMillis - 10 * 60_000L
        assertEquals(expected, target?.triggerAt)
    }

    @Test
    fun nextReminderTarget_skips_a_class_starting_within_the_reminder_window() {
        // 距上课不足 reminderMinutes：提醒时刻已过，应跳过而不是排出过去的闹钟。
        val data = json(
            courses = listOf(
                course(1, "08:00", name = "马上要上"),
                course(1, "09:00", name = "下一节"),
            ),
        )
        val base = mondayAt(7, 55) // 距 08:00 只有 5 分钟，< 10 分钟
        val target = AppWidget.nextReminderTargetAt(
            json = data,
            week = 1,
            reminderMinutes = 10,
            today = monday,
            nowMillis = base.timeInMillis,
            base = base,
        )
        assertEquals("下一节", target?.course?.name)
    }

    @Test
    fun nextReminderTarget_returns_null_when_nothing_remains_today() {
        // 今天两节课的提醒都已过，且未来 7 天无课 → null（调用方据此取消旧闹钟）。
        val data = json(courses = listOf(course(1, "08:00", name = "已过")))
        val base = mondayAt(23, 0)
        val target = AppWidget.nextReminderTargetAt(
            json = data,
            week = 1,
            reminderMinutes = 10,
            today = monday,
            nowMillis = base.timeInMillis,
            base = base,
        )
        assertNull(target)
    }

    @Test
    fun nextReminderTarget_finds_tomorrow_when_today_is_done() {
        val data = json(
            courses = listOf(
                course(1, "08:00", name = "今天已过"),
                course(2, "09:00", name = "明天第一节课"),
            ),
        )
        val base = mondayAt(23, 0)
        val target = AppWidget.nextReminderTargetAt(
            json = data,
            week = 1,
            reminderMinutes = 10,
            today = monday,
            nowMillis = base.timeInMillis,
            base = base,
        )
        assertEquals("明天第一节课", target?.course?.name)
    }

    @Test
    fun nextReminderTarget_ignores_week_0_before_term_starts() {
        // 还没开学（week=0）时 targetWeek 会 > MAX_WEEK，不能排出任何提醒。
        val data = json(
            courses = listOf(course(7, "08:00", name = "周日的课")),
            week = 0,
        )
        val base = mondayAt(8, 0)
        val target = AppWidget.nextReminderTargetAt(
            json = data,
            week = 0,
            reminderMinutes = 10,
            today = sunday,
            nowMillis = base.timeInMillis,
            base = base,
        )
        assertNull("开学前不应排出提醒", target)
    }

    // ---------- reminderTriggerAt ----------

    @Test
    fun reminderTriggerAt_is_class_start_minus_lead_time() {
        val c = AppWidget
            .parseCourses(json(listOf(course(1, "08:00"))))
            .single()
        val base = mondayAt(0, 0)
        val expected = (base.clone() as Calendar).apply {
            set(Calendar.HOUR_OF_DAY, 8)
            set(Calendar.MINUTE, 0)
        }.timeInMillis - 10 * 60_000L
        assertEquals(expected, AppWidget.reminderTriggerAt(c, 10, monday, base))
    }

    @Test
    fun reminderTriggerAt_rejects_a_malformed_start_time() {
        val c = AppWidget
            .parseCourses(json(listOf(course(1, "oops"))))
            .single()
        assertNull(AppWidget.reminderTriggerAt(c, 10, monday, mondayAt(0, 0)))
    }
}
