/// 学校作息时间模式。
///
/// 自动模式使用设备本地日期：5 月 1 日至 9 月 30 日采用夏季作息，
/// 其余日期采用春秋冬季作息。这里使用本地日期，不读取日历事件，也不需要
/// 日历权限。
enum ScheduleTimeMode { automatic, springAutumnWinter, summer }

extension ScheduleTimeModeText on ScheduleTimeMode {
  String get label => switch (this) {
    ScheduleTimeMode.automatic => '自动（按日期）',
    ScheduleTimeMode.springAutumnWinter => '春秋冬季',
    ScheduleTimeMode.summer => '夏季',
  };

  String get storageValue => switch (this) {
    ScheduleTimeMode.automatic => 'automatic',
    ScheduleTimeMode.springAutumnWinter => 'springAutumnWinter',
    ScheduleTimeMode.summer => 'summer',
  };
}

ScheduleTimeMode parseScheduleTimeMode(String? value) {
  switch (value) {
    case 'springAutumnWinter':
      return ScheduleTimeMode.springAutumnWinter;
    case 'summer':
      return ScheduleTimeMode.summer;
    case 'automatic':
    default:
      return ScheduleTimeMode.automatic;
  }
}

class _LessonTimePair {
  final String springAutumnWinter;
  final String summer;

  const _LessonTimePair(this.springAutumnWinter, this.summer);

  String forMode(ScheduleTimeMode mode, {DateTime? now}) {
    final resolved = ScheduleTimeTable.resolveMode(mode, now: now);
    return resolved == ScheduleTimeMode.summer ? summer : springAutumnWinter;
  }
}

/// 湘科院作息表中真正用于课程的 11 个小节时间。
/// 起床、早锻炼、早餐、早读、午餐、午休、预备铃、晚餐、自由活动、熄灯
/// 等生活安排不在这里，因此不会被显示到课表节次栏。
class ScheduleTimeTable {
  ScheduleTimeTable._();

  static const _lessonTimes = <int, _LessonTimePair>{
    1: _LessonTimePair('08:20–09:05', '08:10–08:55'),
    2: _LessonTimePair('09:15–10:00', '09:05–09:50'),
    3: _LessonTimePair('10:10–10:55', '10:10–10:55'),
    4: _LessonTimePair('11:15–12:00', '11:05–11:50'),
    5: _LessonTimePair('14:30–15:15', '14:45–15:30'),
    6: _LessonTimePair('15:25–16:10', '15:40–16:25'),
    7: _LessonTimePair('16:25–17:10', '16:40–17:25'),
    8: _LessonTimePair('17:20–18:05', '17:35–18:20'),
    9: _LessonTimePair('19:10–19:55', '19:30–20:15'),
    10: _LessonTimePair('20:05–20:50', '20:25–21:10'),
    11: _LessonTimePair('21:00–21:45', '21:20–22:05'),
  };

  static ScheduleTimeMode resolveMode(ScheduleTimeMode mode, {DateTime? now}) {
    if (mode != ScheduleTimeMode.automatic) return mode;
    final month = (now ?? DateTime.now()).month;
    return month >= 5 && month <= 9
        ? ScheduleTimeMode.summer
        : ScheduleTimeMode.springAutumnWinter;
  }

  static String? lessonTime(
    int lesson,
    ScheduleTimeMode mode, {
    DateTime? now,
  }) {
    return _lessonTimes[lesson]?.forMode(mode, now: now);
  }

  /// 从课表原始节次文本中读取小节编号，例如 `第一大节 (01,02小节)`。
  static List<int> sublessonNumbers(String value) {
    final match = RegExp(r'[（(]([^）)]*)[）)]').firstMatch(value);
    if (match == null) return const [];
    final numbers = <int>[];
    for (final m in RegExp(r'\d{1,2}').allMatches(match.group(1)!)) {
      final number = int.tryParse(m.group(0)!);
      if (number != null && _lessonTimes.containsKey(number)) {
        if (!numbers.contains(number)) numbers.add(number);
      }
    }
    return numbers;
  }

  /// 返回节次栏第二行要显示的内容，每个小节单独换行。
  static String formatSublessonLines(
    String value,
    ScheduleTimeMode mode, {
    DateTime? now,
  }) {
    final numbers = sublessonNumbers(value);
    if (numbers.isEmpty) return '';
    return numbers
        .map((number) {
          final time = lessonTime(number, mode, now: now);
          return '${number.toString().padLeft(2, '0')}小节：$time';
        })
        .join('\n');
  }
}
