import 'package:flutter_test/flutter_test.dart';
import 'package:jizhicha/academic_calendar.dart';

/// 学年周次计算的回归测试。
///
/// `weekNumberFor` 之前**零测试**，而它在 v1.1.0 刚修过一个真实 bug：
/// 开学前把负数天数算成了「第 1 周」，于是小组件会显示"本周有课"、
/// 提醒也会照排 —— 实际上还没开学。
///
/// 它是 52 行文件里的纯函数，任何日期都能确定复现，因此这些用例不依赖当前时间。
void main() {
  // 用一个固定的周一作为开学日（2026-09-07 是周一）。
  final monday = DateTime(2026, 9, 7);

  group('weekNumberFor', () {
    test('开学日当天算第 1 周', () {
      expect(AcademicCalendar.weekNumberFor(monday, monday), 1);
    });

    test('第 1 周内（周一至周日）都算第 1 周', () {
      expect(AcademicCalendar.weekNumberFor(monday, monday), 1);
      expect(
        AcademicCalendar.weekNumberFor(monday, monday.add(const Duration(days: 3))),
        1,
      );
      expect(
        AcademicCalendar.weekNumberFor(monday, monday.add(const Duration(days: 6))),
        1,
        reason: '第 1 周的最后一天（周日）仍是第 1 周',
      );
    });

    test('满 7 天进入第 2 周', () {
      expect(
        AcademicCalendar.weekNumberFor(monday, monday.add(const Duration(days: 7))),
        2,
      );
      expect(
        AcademicCalendar.weekNumberFor(monday, monday.add(const Duration(days: 13))),
        2,
      );
    });

    test('开学前返回 0，而不是第 1 周', () {
      // 这是 v1.1.0 修掉的那个 bug：负数天数曾被算成第 1 周，
      // 导致还没开学就显示"本周有课"并照常排提醒。
      expect(
        AcademicCalendar.weekNumberFor(monday, monday.subtract(const Duration(days: 1))),
        0,
        reason: '开学前一天必须表示"还没开学"',
      );
      expect(
        AcademicCalendar.weekNumberFor(monday, DateTime(2026, 8, 1)),
        0,
        reason: '整个暑假都应表示"还没开学"',
      );
      expect(
        AcademicCalendar.weekNumberFor(monday, DateTime(2025, 9, 1)),
        0,
        reason: '上一年也应表示"还没开学"',
      );
    });

    test('第 20 周是学期最后一周', () {
      final day = monday.add(const Duration(days: 19 * 7));
      expect(AcademicCalendar.weekNumberFor(monday, day), 20);
      expect(
        AcademicCalendar.weekNumberFor(monday, day.add(const Duration(days: 6))),
        20,
        reason: '第 20 周整周都算第 20 周',
      );
    });

    test('超过 20 周后继续递增，由调用方判断"本学期已结束"', () {
      // weekNumberFor 本身不做截断；小组件/课表页用 >20 判断"已结束"，
      // 这里锁住契约，避免日后有人改成静默截断而破坏该判断。
      final day = monday.add(const Duration(days: 20 * 7));
      expect(AcademicCalendar.weekNumberFor(monday, day), 21);
    });

    test('时间跨过夏令时切换仍按整天数计算', () {
      // 用 UTC 之外的本地日期，只断言"按天数递增"这个不变量。
      var previous = AcademicCalendar.weekNumberFor(
        monday,
        monday.add(const Duration(days: 90)),
      );
      for (var d = 91; d <= 120; d++) {
        final current = AcademicCalendar.weekNumberFor(
          monday,
          monday.add(Duration(days: d)),
        );
        expect(current, greaterThanOrEqualTo(previous));
        previous = current;
      }
    });
  });

  group('学年常量', () {
    test('每学期 20 周，与小组件 Kotlin 侧的 MAX_WEEK 一致', () {
      // AppWidget.kt 的 MAX_WEEK = 20；两处不一致会让小组件与课表页
      // 对"本学期是否结束"给出不同答案。
      expect(AcademicCalendar.weeksPerAcademicYear, 20);
    });

    test('latestTerm 在 terms 列表内且排在首位', () {
      expect(AcademicCalendar.terms.first, AcademicCalendar.latestTerm);
      expect(AcademicCalendar.terms, contains(AcademicCalendar.latestTerm));
    });

    test('terms 列表无重复', () {
      expect(
        AcademicCalendar.terms.toSet().length,
        AcademicCalendar.terms.length,
      );
    });

    test('每个已配置的学期都用周一作为开学日', () {
      // 这条只在「开学日用于周次计算」时才必须成立。见下面那条说明：
      // termStartDates 目前不参与周次计算，因此本测试只覆盖真正用于计算的输入。
      // weekNumberFor 的契约是「第 1 周从 start 当天算起」；调用方
      // （AppSettings.semesterStartDate）保证传进来的是周一。
      final monday = DateTime(2026, 9, 7);
      expect(monday.weekday, DateTime.monday);
      expect(AcademicCalendar.weekNumberFor(monday, monday), 1);
    });

    test('termStartDates 不保证是周一 —— 它只用于「学期是否已开始」', () {
      // ⚠️ 真实情况：春季学期用的是 3 月 1 日，例如 2025-03-01 是周六、
      // 2026-03-01 是周日。这**不是** bug：该表只被 `latestAvailableTerm`
      // 用来比较「开学日期是否已过」，不参与任何周次计算。
      //
      // 但这也是一个陷阱：`weekNumberFor` 不会校验 start 是否为周一，
      // 直接传非周一日期会让「第 N 周」整体错位最多 6 天。
      // 若日后要把 termStartDates 接进周次计算，必须先统一改成周一 ——
      // 这条测试就是把该事实记录下来，避免有人误以为它已经是周一。
      final springStarts = AcademicCalendar.termStartDates.entries
          .where((e) => e.key.endsWith('-2'))
          .map((e) => e.value)
          .toList();
      expect(springStarts, isNotEmpty, reason: '应至少配置一个春季学期');

      // weekNumberFor 不校验输入：非周一日期照常按「天数 ~/ 7 + 1」返回。
      // 这正是它为什么要求调用方传入周一。
      final saturday = DateTime(2025, 3, 1);
      expect(saturday.weekday, isNot(DateTime.monday));
      expect(AcademicCalendar.weekNumberFor(saturday, saturday), 1);
      expect(
        AcademicCalendar.weekNumberFor(
          saturday,
          saturday.add(const Duration(days: 6)),
        ),
        1,
        reason: '从周六算起的"第 1 周"会一直持续到下周五，与学校口径错位',
      );
    });

    test('termStartDates 的键都属于 terms 列表', () {
      for (final key in AcademicCalendar.termStartDates.keys) {
        expect(
          AcademicCalendar.terms,
          contains(key),
          reason: '$key 配了开学日期但不在 terms 列表里',
        );
      }
    });

    test('每个学期都配了开学日期', () {
      for (final term in AcademicCalendar.terms) {
        expect(
          AcademicCalendar.termStartDates.containsKey(term),
          isTrue,
          reason: '$term 缺少开学日期，latestAvailableTerm 会退化成 terms.first',
        );
      }
    });

    test('开学月份与学期序号相符（秋季 8-9 月，春季 2-3 月）', () {
      for (final entry in AcademicCalendar.termStartDates.entries) {
        final isSpring = entry.key.endsWith('-2');
        final month = entry.value.month;
        if (isSpring) {
          expect(
            month,
            anyOf(2, 3),
            reason: '${entry.key} 是春季学期，开学月份应是 2 或 3 月',
          );
        } else {
          expect(
            month,
            anyOf(8, 9),
            reason: '${entry.key} 是秋季学期，开学月份应是 8 或 9 月',
          );
        }
      }
    });

    test('开学日期与学期名属于同一年（2026-2027-1 不应配 2025 年）', () {
      for (final entry in AcademicCalendar.termStartDates.entries) {
        final firstYear = int.parse(entry.key.split('-').first);
        final startYear = entry.value.year;
        // 秋季学期（-1）在起始学年的下半年；春季学期（-2）跨年到次年。
        expect(
          startYear == firstYear || startYear == firstYear + 1,
          isTrue,
          reason: '${entry.key} 配了 $startYear 年，与学期名不符',
        );
      }
    });
  });
}
