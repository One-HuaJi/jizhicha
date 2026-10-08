package com.one.huaji

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Calendar

/// 桌面小组件「跨季节时刻 / 跨周周次」陈旧化的回归测试。
///
/// 锁住的是两个**只有 App 长期不打开才暴露**的真实缺陷：
///   1. 时刻快照：`widget_schedule.json` 里的 `start`/`end` 是写入时刻按当时季节
///      解析好的字符串。跨季节边界（9/30→10/1 或 4/30→5/1）而 App 没被打开过时，
///      小组件会一直显示旧季节时刻，甚至连上课提醒的闹钟也按旧季节响。
///      ⇒ 现在 JSON 额外落盘 `times.{springAutumnWinter,summer}` 两列，原生侧按
///      **设备当天日期**选列（固定模式则尊重用户选定的列）。
///   2. 周次快照：`week` 也是写文件时算死的，App 多周不打开就停在旧「第 N 周」。
///      ⇒ 现在额外落盘 `semesterStartDate`，原生侧按当天日期现算。
///
/// 全部时间都通过参数注入，因此在任何日期 / 时区运行都稳定。
class WidgetSeasonTest {

    // ---------- 辅助 ----------

    private val autumn = "springAutumnWinter"
    private val summer = "summer"

    private fun timeColumn(start: String, end: String): JSONObject = JSONObject().apply {
        put("start", start)
        put("end", end)
    }

    /// 一节课：`times` 落盘两季时刻（`start`/`end` 是与旧版原生代码衔接的兜底快照）。
    private fun seasonalCourse(
        day: Int,
        autumnStart: String,
        autumnEnd: String,
        summerStart: String,
        summerEnd: String,
        name: String = "课程",
        weeks: List<Int> = emptyList(),
    ): JSONObject = JSONObject().apply {
        put("day", day)
        put("start", autumnStart)
        put("end", autumnEnd)
        put("name", name)
        put("teacher", "老师")
        put("room", "教室")
        put("weeks", JSONArray(weeks))
        put(
            "times",
            JSONObject().apply {
                put(autumn, timeColumn(autumnStart, autumnEnd))
                put(summer, timeColumn(summerStart, summerEnd))
            },
        )
    }

    private fun payload(
        courses: List<JSONObject>,
        mode: String? = "automatic",
        week: Int = 1,
        semesterStartDate: String? = null,
    ): JSONObject {
        val arr = JSONArray()
        courses.forEach { arr.put(it) }
        return JSONObject().apply {
            put("week", week)
            put("courses", arr)
            if (mode != null) put("scheduleTimeMode", mode)
            if (semesterStartDate != null) put("semesterStartDate", semesterStartDate)
        }
    }

    private fun at(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0): Calendar =
        Calendar.getInstance().apply {
            set(year, month, day, hour, minute, 0)
            set(Calendar.MILLISECOND, 0)
        }

    /// 第 3 节（第一大节第 3 小节）两季差 10 分钟；第 5 节（下午）两季差 15 分钟。
    /// 数值本身来自 Dart 侧 `ScheduleTimeTable` 转录，这里只做「选列是否正确」的断言。
    private fun lesson3Course() = seasonalCourse(
        day = 1,
        autumnStart = "10:20",
        autumnEnd = "11:05",
        summerStart = "10:10",
        summerEnd = "10:55",
        name = "第三小节",
    )

    private fun sept30() = at(2026, Calendar.SEPTEMBER, 30, 12, 0)  // 夏季最后一天
    private fun oct1() = at(2026, Calendar.OCTOBER, 1, 12, 0)       // 春秋冬季第一天
    private fun apr30() = at(2027, Calendar.APRIL, 30, 12, 0)       // 春秋冬季最后一天
    private fun may1() = at(2027, Calendar.MAY, 1, 12, 0)           // 夏季第一天

    // ---------- 核心：跨季节时刻不再陈旧 ----------

    @Test
    fun automatic_mode_picks_the_column_for_the_device_date_not_the_write_date() {
        // 典型故障场景：App 在 9/30（夏季）写盘，之后再没打开过。
        // 旧实现里 JSON 的 `start` 固定是 10:10，10 月 1 日起小组件一直显示夏季时刻。
        val data = payload(
            courses = listOf(lesson3Course()),
            mode = "automatic",
            semesterStartDate = "2026-09-07",
        )

        val onSept30 = AppWidget.parseCourses(data, sept30())
        val onOct1 = AppWidget.parseCourses(data, oct1())

        assertEquals("9/30 仍是夏季，应取夏季列", "10:10", onSept30.single().start)
        assertEquals(
            "10/1 起必须自动切到春秋冬季列 —— 这是本 bug 的证伪点",
            "10:20",
            onOct1.single().start,
        )
        assertEquals("11:05", onOct1.single().endText)
        assertEquals("10:55", onSept30.single().endText)
    }

    @Test
    fun automatic_mode_switches_back_on_may_first() {
        // 反方向同样要自愈：4/30 是春秋冬季最后一天，5/1 起是夏季。
        val data = payload(courses = listOf(lesson3Course()), semesterStartDate = "2026-09-07")

        assertEquals("10:20", AppWidget.parseCourses(data, apr30()).single().start)
        assertEquals("10:10", AppWidget.parseCourses(data, may1()).single().start)
    }

    @Test
    fun automatic_boundary_is_exclusive_on_the_summer_side() {
        // 5 月 1 日与 9 月 30 日都是夏季；10 月 1 日与 4 月 30 日是春秋冬季。
        // 与 Dart `ScheduleTimeTable.resolveMode`（month in 5..9 → summer）逐条一致。
        assertEquals(summer, AppWidget.seasonForMonth(may1()))
        assertEquals(summer, AppWidget.seasonForMonth(sept30()))
        assertEquals(autumn, AppWidget.seasonForMonth(oct1()))
        assertEquals(autumn, AppWidget.seasonForMonth(apr30()))
    }

    @Test
    fun explicit_mid_season_dates_pick_the_right_column() {
        // 主线点名的两个"平时"日期：7/1 取夏季列，10/8 取春秋冬季列。
        // 10/8 正是真机上发现 `week=5`、上午第二大节 `10:20–12:00`、下午
        // `14:30–16:10` 的那天 —— 那批值是春秋冬季的，属于"写入时刻快照"。
        val data = payload(courses = listOf(lesson3Course()), semesterStartDate = "2026-09-07")

        assertEquals("10:10", AppWidget.parseCourses(data, at(2026, Calendar.JULY, 1)).single().start)
        assertEquals("10:20", AppWidget.parseCourses(data, at(2026, Calendar.OCTOBER, 8)).single().start)
    }

    @Test
    fun multi_sublesson_block_uses_first_start_and_last_end() {
        // 一个"大节"可能由多个小节组成（例如第 5、6 小节）：start 取首个小节的开始、
        // end 取末个小节的结束。Dart 侧 `WidgetScheduleStore._timeColumns` 必须与这里同口径
        // —— 曾经写成对两季的 start/end 都取首个小节，导致夏季 end 变成 15:30 而不是 16:25。
        val data = payload(
            courses = listOf(
                // 第 5 节：春秋冬季 14:30–15:15 / 夏季 14:45–15:30
                // 第 6 节：春秋冬季 15:25–16:10 / 夏季 15:40–16:25
                seasonalCourse(1, "14:30", "16:10", "14:45", "16:25", name = "下午大节"),
            ),
        )

        val onOct = AppWidget.parseCourses(data, oct1()).single()
        assertEquals("14:30", onOct.start)
        assertEquals("16:10", onOct.endText)

        val onJul = AppWidget.parseCourses(data, at(2026, Calendar.JULY, 1)).single()
        assertEquals("14:45", onJul.start)
        assertEquals("16:25", onJul.endText)
    }

    @Test
    fun fixed_mode_ignores_the_device_date() {
        // 真机实测用户把模式设成固定 springAutumnWinter：必须**永远**用那一列，
        // 哪怕设备当天是 7 月（夏季），否则就成了"替用户改设置"。
        val winter = payload(courses = listOf(lesson3Course()), mode = autumn)
        val summery = payload(courses = listOf(lesson3Course()), mode = summer)

        assertEquals("10:20", AppWidget.parseCourses(winter, may1()).single().start)
        assertEquals("10:20", AppWidget.parseCourses(winter, oct1()).single().start)
        assertEquals("10:10", AppWidget.parseCourses(summery, oct1()).single().start)
        assertEquals("10:10", AppWidget.parseCourses(summery, may1()).single().start)
    }

    @Test
    fun automatic_mode_switches_the_start_used_for_reminders() {
        // 提醒路径比显示更要紧：闹钟时刻由 `Course.start` 解析而来，
        // 若它与渲染走的不是同一套解析，跨季节后会"显示夏季时刻、闹钟按春秋冬季响"。
        val data = payload(courses = listOf(lesson3Course()), semesterStartDate = "2026-09-07")
        val monday = 1

        val writtenInSummer = AppWidget.nextReminderTargetAt(
            json = data,
            week = 1,
            reminderMinutes = 10,
            today = monday,
            nowMillis = at(2026, Calendar.SEPTEMBER, 21, 7, 0).timeInMillis,
            base = at(2026, Calendar.SEPTEMBER, 21, 7, 0),
        )
        val afterTheSwitch = AppWidget.nextReminderTargetAt(
            json = data,
            week = 1,
            reminderMinutes = 10,
            today = monday,
            nowMillis = at(2026, Calendar.OCTOBER, 12, 7, 0).timeInMillis,
            base = at(2026, Calendar.OCTOBER, 12, 7, 0),
        )

        // 9 月：10:10 上课 → 10:00 提醒
        assertEquals("10:00", clockOf(writtenInSummer!!.triggerAt))
        // 10 月：10:20 上课 → 10:10 提醒（旧实现仍按夏季排 10:00）
        assertEquals("10:10", clockOf(afterTheSwitch!!.triggerAt))
    }

    @Test
    fun reminder_and_display_agree_on_the_same_boundary() {
        // 同一次刷新里，渲染用的 start 与提醒用的 start 必须是同一个值。
        val data = payload(courses = listOf(lesson3Course()), semesterStartDate = "2026-09-07")
        val now = at(2026, Calendar.OCTOBER, 12, 7, 0)
        val shown = AppWidget.findNextClassAt(data, today = 1, nowMinutes = 7 * 60, now = now)
        val reminded = AppWidget.nextReminderTargetAt(
            json = data,
            week = 1,
            reminderMinutes = 10,
            today = 1,
            nowMillis = now.timeInMillis,
            base = now,
        )
        assertEquals("10:20", shown?.start)
        assertEquals(shown?.start, reminded?.course?.start)
    }

    // ---------- 向后兼容 ----------

    @Test
    fun legacy_json_without_times_keeps_rendering_the_stored_snapshot() {
        // 旧版 App 写的 JSON 没有 `times`/`scheduleTimeMode`/`semesterStartDate`。
        // 必须既不崩、也不空白：照旧用 `start` 快照。
        val legacy = JSONObject().apply {
            put("week", 3)
            put(
                "courses",
                JSONArray().apply {
                    put(
                        JSONObject().apply {
                            put("day", 1)
                            put("start", "10:10")
                            put("end", "10:55")
                            put("name", "旧数据")
                            put("teacher", "老师")
                            put("room", "教室")
                            put("weeks", JSONArray(listOf(1, 2, 3)))
                        },
                    )
                },
            )
        }

        val parsed = AppWidget.parseCourses(legacy, oct1())
        assertEquals(1, parsed.size)
        assertEquals("10:10", parsed.single().start)
        assertEquals("10:55", parsed.single().endText)
        // 没有 semesterStartDate → 周次回退到 `week` 快照，不会变成 0/负数。
        assertEquals(3, AppWidget.weekValue(legacy, oct1()))
    }

    @Test
    fun times_with_only_one_season_is_tolerated() {
        // 半新半旧（例如未来某版只落盘了一列）：缺的那一列回退快照，另一列照常生效。
        val partial = JSONObject().apply {
            put("day", 1)
            put("start", "10:20")
            put("end", "11:05")
            put("name", "半新")
            put("weeks", JSONArray())
            put("times", JSONObject().put(autumn, timeColumn("10:20", "11:05")))
        }
        val data = payload(courses = listOf(partial), semesterStartDate = "2026-09-07")

        assertEquals("10:20", AppWidget.parseCourses(data, oct1()).single().start)
        assertEquals(
            "夏季列缺失 → 回退快照，绝不返回空串",
            "10:20",
            AppWidget.parseCourses(data, may1()).single().start,
        )
    }

    @Test
    fun malformed_times_falls_back_to_the_snapshot_instead_of_blanking() {
        val broken = JSONObject().apply {
            put("day", 1)
            put("start", "10:20")
            put("end", "11:05")
            put("name", "坏数据")
            put("weeks", JSONArray())
            put(
                "times",
                JSONObject().apply {
                    put(autumn, JSONObject().put("start", "").put("end", ""))
                    put(summer, "not-an-object")
                },
            )
        }
        val data = payload(courses = listOf(broken), semesterStartDate = "2026-09-07")

        assertEquals("10:20", AppWidget.parseCourses(data, oct1()).single().start)
        assertEquals("10:20", AppWidget.parseCourses(data, may1()).single().start)
    }

    @Test
    fun unknown_mode_value_falls_back_to_automatic() {
        // 模式字段被写坏 / 未来新增了取值：按 automatic 处理，好过完全不动。
        val data = payload(courses = listOf(lesson3Course()), mode = "someFutureMode")
        assertEquals("10:20", AppWidget.parseCourses(data, oct1()).single().start)
        assertEquals("10:10", AppWidget.parseCourses(data, may1()).single().start)
    }

    @Test
    fun missing_mode_field_falls_back_to_automatic() {
        val data = payload(courses = listOf(lesson3Course()), mode = null)
        assertEquals("10:20", AppWidget.parseCourses(data, oct1()).single().start)
        assertEquals("10:10", AppWidget.parseCourses(data, may1()).single().start)
    }

    // ---------- 周次不再陈旧 ----------

    @Test
    fun week_value_recomputes_from_semester_start_date() {
        val data = payload(courses = listOf(lesson3Course()), semesterStartDate = "2026-09-07")
        assertEquals(1, AppWidget.weekValue(data, at(2026, Calendar.SEPTEMBER, 7)))
        assertEquals(2, AppWidget.weekValue(data, at(2026, Calendar.SEPTEMBER, 14)))
        assertEquals(4, AppWidget.weekValue(data, at(2026, Calendar.SEPTEMBER, 28)))
    }

    @Test
    fun week_value_is_zero_before_the_semester_starts() {
        // 0 是小组件显示「还没开学」的依据（与 Dart weekNumberFor 的约定一致）。
        val data = payload(courses = listOf(lesson3Course()), semesterStartDate = "2026-09-07")
        assertEquals(0, AppWidget.weekValue(data, at(2026, Calendar.AUGUST, 31)))
        assertEquals(0, AppWidget.weekValue(data, at(2026, Calendar.SEPTEMBER, 6)))
    }

    @Test
    fun week_value_past_the_end_of_the_semester_exceeds_max_week() {
        // >20 是小组件显示「本学期已结束」的依据。
        val start = at(2026, Calendar.SEPTEMBER, 7)
        // 第 20 周从开学第 133 天开始。
        assertEquals(20, AppWidget.weekNumberFor(start, at(2027, Calendar.JANUARY, 18)))
        assertEquals(21, AppWidget.weekNumberFor(start, at(2027, Calendar.JANUARY, 25)))
    }

    @Test
    fun week_number_matches_the_dart_rule_on_the_same_inputs() {
        // 交叉验证另一侧：`test/widget_schedule_store_test.dart` 用同一组「开学日 +
        // 偏移天数」断言 Dart `AcademicCalendar.weekNumberFor`，两边必须逐点相等。
        val start = at(2026, Calendar.SEPTEMBER, 7)
        val expected = listOf(-1 to 0, 0 to 1, 6 to 1, 7 to 2, 13 to 2, 14 to 3, 139 to 20)
        for ((offset, week) in expected) {
            val day = (start.clone() as Calendar).apply { add(Calendar.DAY_OF_MONTH, offset) }
            assertEquals(
                "开学日 + $offset 天 应为第 $week 周",
                week,
                AppWidget.weekNumberFor(start, day),
            )
        }
    }

    @Test
    fun week_value_ignores_a_stale_week_snapshot_when_start_date_is_present() {
        val data = payload(
            courses = listOf(lesson3Course()),
            week = 1, // 陈旧快照
            semesterStartDate = "2026-09-07",
        )
        assertEquals(4, AppWidget.weekValue(data, at(2026, Calendar.SEPTEMBER, 28)))
    }

    @Test
    fun week_value_falls_back_to_the_snapshot_when_start_date_is_missing_or_invalid() {
        assertEquals(5, AppWidget.weekValue(payload(emptyList(), week = 5), oct1()))
        assertEquals(
            5,
            AppWidget.weekValue(
                payload(emptyList(), week = 5, semesterStartDate = "not-a-date"),
                oct1(),
            ),
        )
        assertEquals(
            5,
            AppWidget.weekValue(
                payload(emptyList(), week = 5, semesterStartDate = "2026-13-45"),
                oct1(),
            ),
        )
    }

    @Test
    fun find_next_class_heals_a_stale_week_snapshot() {
        // 陈旧周次会让「单双周」过滤选错课：快照周次=14，实际已是第 15 周。
        // 旧实现永远返回 null（14 不在这节课的周次表里），修复后必须选出第 15 周那节课。
        val data = payload(
            courses = listOf(
                seasonalCourse(
                    day = 1,
                    autumnStart = "10:20",
                    autumnEnd = "11:05",
                    summerStart = "10:10",
                    summerEnd = "10:55",
                    name = "第15周课",
                    weeks = listOf(14, 15, 16),
                ),
            ),
            week = 14,
            semesterStartDate = "2026-09-07",
        )

        val stale = AppWidget.findNextClassAt(
            data,
            today = 1,
            nowMinutes = 7 * 60,
            // 2026-12-14 周一，落在这个学期的第 15 周（且处于春秋冬季）。
            now = at(2026, Calendar.DECEMBER, 14, 7, 0),
        )

        assertNotNull("陈旧周次不应再把该上的课过滤掉", stale)
        assertEquals("第15周课", stale!!.name)
        assertEquals("10:20", stale.start)
    }

    // ---------- seasonFor 的取值口径 ----------

    @Test
    fun season_for_maps_mode_values_to_columns() {
        // 固定值原样返回（不按日期改写用户设置），其余一律按日期。
        assertEquals(autumn, AppWidget.seasonFor(autumn, may1()))
        assertEquals(summer, AppWidget.seasonFor(summer, oct1()))
        assertEquals(summer, AppWidget.seasonFor("automatic", may1()))
        assertEquals(autumn, AppWidget.seasonFor("automatic", oct1()))
    }

    @Test
    fun parse_courses_tolerates_missing_and_malformed_fields() {
        // 小组件绝不能因为脏数据崩：缺 day / 缺 name / weeks 非数组都要能读出来。
        val dirty = JSONObject().apply {
            put("week", 1)
            put(
                "courses",
                JSONArray().apply {
                    put(JSONObject().put("start", "10:20"))
                    put("not-an-object")
                },
            )
        }
        val parsed = AppWidget.parseCourses(dirty, oct1())
        assertEquals(1, parsed.size)
        assertEquals(0, parsed.single().day)
        assertEquals("", parsed.single().name)
        assertEquals(emptyList<Int>(), parsed.single().weeks)
        assertTrue(parsed.single().start.isEmpty() || parsed.single().start == "10:20")
    }

    @Test
    fun parse_courses_returns_empty_for_a_payload_without_courses() {
        assertTrue(AppWidget.parseCourses(JSONObject(), oct1()).isEmpty())
        assertNull(AppWidget.findNextClassAt(JSONObject(), today = 1, nowMinutes = 0, now = oct1()))
    }

    // ---------- 工具 ----------

    private fun clockOf(millis: Long): String {
        val c = Calendar.getInstance().apply { timeInMillis = millis }
        val h = c.get(Calendar.HOUR_OF_DAY).toString().padStart(2, '0')
        val m = c.get(Calendar.MINUTE).toString().padStart(2, '0')
        return "$h:$m"
    }
}
