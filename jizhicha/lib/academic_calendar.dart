// ==================== 学年日期（作者手动维护） ====================
/// 教务系统的学年选项和开课日期由作者手动维护，不从校园网额外探测。
///
/// 每个学期按 20 周显示周次；如果学校调整开课日期，只需要修改这里，
/// 不需要改动课表页面的查询逻辑。当前日期由 DateTime.now() 在本机读取。
class AcademicCalendar {
  AcademicCalendar._();

  static const int weeksPerAcademicYear = 20;

  // 新学年发布后，作者手动把最新学期放在第一项并更新 latestTerm。
  static const String latestTerm = '2026-2027-1';
  static final DateTime latestTermQueryDate = DateTime(2026, 9, 1);

  static const List<String> terms = [
    latestTerm,
    '2025-2026-2',
    '2025-2026-1',
    '2024-2025-2',
    '2024-2025-1',
    '2023-2024-2',
    '2023-2024-1',
  ];

  // 这些日期仅作为作者维护记录，暂不强制覆盖设置页的手动周次选择。
  static final Map<String, DateTime> termStartDates = {
    '2026-2027-1': DateTime(2026, 9, 7),
    '2025-2026-2': DateTime(2026, 3, 1),
    '2025-2026-1': DateTime(2025, 9, 1),
    '2024-2025-2': DateTime(2025, 3, 1),
    '2024-2025-1': DateTime(2024, 9, 1),
    '2023-2024-2': DateTime(2024, 3, 1),
    '2023-2024-1': DateTime(2023, 9, 1),
  };

  static bool isBeforeLatestTermQueryDate(DateTime now) =>
      now.isBefore(latestTermQueryDate);

  /// 计算 [now] 落在第几周；第一周从 [start] 当天（周一）算起。
  /// [now] 早于开学日期时返回 0，表示「还没开学」。
  static int weekNumberFor(DateTime start, DateTime now) {
    final days = now.difference(start).inDays;
    if (days < 0) return 0;
    return (days ~/ 7) + 1;
  }

  /// 返回已经开始的、按学期列表顺序排列的第一个学期。
  ///
  /// [latestTerm] 可能会在新学期开始前提前写入配置；成绩快速同步不能在
  /// 这个时间点查询一个尚未开放的学期，否则会漏掉当前仍在展示成绩的学期。
  static String get latestAvailableTerm {
    final now = DateTime.now();
    for (final term in terms) {
      final start = termStartDates[term];
      if (start == null || !start.isAfter(now)) return term;
    }
    return terms.first;
  }
}
