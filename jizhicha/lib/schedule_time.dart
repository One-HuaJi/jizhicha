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

/// 课程格子的底色形状。
///
/// 只改变**底色**的形状（圆角 / 铺满整格），不改配色、不改布局、不改细线：
/// - [rounded]：沿用历史外观，课程块底色是 8px 圆角矩形、四周留 2~6px 内缩；
/// - [filled]：底色铺满整个单元格（本次默认）。格内文字的内边距保持原样，
///   相邻格之间 0.6px 的分隔细线也照旧保留（一个元素一个信号：
///   铺满只负责"要不要留白"，细线只负责"分格"）。
enum ScheduleCellFill { rounded, filled }

extension ScheduleCellFillText on ScheduleCellFill {
  String get label => switch (this) {
    ScheduleCellFill.rounded => '圆角',
    ScheduleCellFill.filled => '长方形铺满',
  };

  String get storageValue => switch (this) {
    ScheduleCellFill.rounded => 'rounded',
    ScheduleCellFill.filled => 'filled',
  };
}

ScheduleCellFill parseScheduleCellFill(String? value) {
  switch (value) {
    case 'rounded':
      return ScheduleCellFill.rounded;
    case 'filled':
    default:
      // 默认铺满：与 [AppSettings.courseCellFill] 的默认值保持一致。
      return ScheduleCellFill.filled;
  }
}

/// 错峰分组：学校只对**第二大节（第 3、4 小节）**按楼栋错峰。
///
/// 依据：作者提供的《湖南科技学院"错峰"作息时间表》（原文见交接文档 §9.18.1）。
/// 作者确认的口径是「错峰只调整第二节课；第一节课别管了……当春秋冬季看」
/// ⇒ 错峰**只覆盖第 3、4 小节**，其余小节（1、2、5～11）完全按季节表解析。
enum SchedulePeakShiftGroup { late, early }

extension SchedulePeakShiftGroupText on SchedulePeakShiftGroup {
  String get label => switch (this) {
    SchedulePeakShiftGroup.late => '晚下课组',
    SchedulePeakShiftGroup.early => '早下课组',
  };
}

/// 「错峰」作息：分组名单 + 第 3、4 小节的错峰时刻。
///
/// ⚠️ **不要**把错峰表里其它小节的值搬进来。作者明确说"第一节课别管了……
/// 当春秋冬季看"——错峰表上午写的是 `8:10`（= 夏季列），若照搬会让春秋冬季的
/// 第 1、2 小节凭空提前 10 分钟（历史上正是这类"跨列搬值"造成过第 3 节错位）。
/// 所以这里**只有**第 3、4 小节两行数据，且纯函数 [timeFor] 对其它小节一律返回
/// null，调用方应回退到季节表。
class SchedulePeakShift {
  SchedulePeakShift._();

  /// 错峰涉及的唯一大节：第二大节 = 第 3、4 小节。
  static const lessons = <int>[3, 4];

  /// A 组（晚下课）。名单照抄学校原表。
  static const lateBuildings = <String>[
    '尚美楼',
    '毓秀楼',
    '荟英楼',
    '弘毅楼',
    '逸夫楼',
    '知行楼',
    '日新楼',
    '明理楼',
    '立信楼',
    '致远楼',
    '潇湘大讲堂',
  ];

  /// B 组（早下课）。学校原表把"其它场所（田径场等）"也归在 B 组。
  static const earlyBuildings = <String>[
    '鹤鸣楼',
    '明德楼',
    '博雅楼',
    '训练馆',
    '工训楼',
    '创新创业学院',
    '美术楼',
  ];

  /// 基准组 = B 组（早下课）。节次栏只显示这一组，另一组在课块内单独提示。
  static const baselineGroup = SchedulePeakShiftGroup.early;

  static const _times = <int, Map<SchedulePeakShiftGroup, String>>{
    3: {
      SchedulePeakShiftGroup.late: '10:25–11:10',
      SchedulePeakShiftGroup.early: '10:10–10:55',
    },
    4: {
      SchedulePeakShiftGroup.late: '11:20–12:05',
      SchedulePeakShiftGroup.early: '11:05–11:50',
    },
  };

  /// 该小节是否受错峰影响（只有第 3、4 小节）。
  static bool affectsLesson(int lesson) => _times.containsKey(lesson);

  /// 错峰表中的时刻；不受影响的小节返回 null（调用方回退季节表）。
  static String? timeFor(int lesson, SchedulePeakShiftGroup group) =>
      _times[lesson]?[group];

  /// 课块内那一行"自己的错峰时刻"的文案：`10:25–11:10`。
  ///
  /// 作者 2026-10-08 明确要求**只保留时间**、不要 `03小节：` 这种前缀
  /// （前缀会让窄格里的文字多折一行）。
  ///
  /// ⚠️ 只有**不属于 [baselineGroup]（B 组，早下课）**的课才需要这一行 ——
  /// B 组的时刻已经显示在节次栏里，再显示一遍就是纯噪音。返回 null 表示
  /// "没有可提示的内容"（该大节不在错峰范围内）。
  ///
  /// 抽成公开静态函数是为了让渲染层与单测共用**同一份**话术，避免
  /// "测了 A 文案、界面显示 B 文案"这种假绿灯。
  static String? hintFor(
    Iterable<int> lessons,
    SchedulePeakShiftGroup group,
  ) {
    final lines = <String>[];
    for (final lesson in lessons) {
      final time = timeFor(lesson, group);
      if (time != null) lines.add(time);
    }
    return lines.isEmpty ? null : lines.join('\n');
  }

  /// 地点 → 错峰分组。
  ///
  /// **识别不出来一律算 B 组（早下课组）** —— 这是作者确认的兜底口径
  /// （"走早下课"）。因此默认值就是 [baselineGroup]，只有精确命中 A 组名单
  /// 的楼栋才归 A 组。
  ///
  /// 提取过程：[buildingOf] → 名单**精确相等**比较（不是 `contains`，
  /// 否则 `明德楼` 与 `明德楼XX` 之类残串会互相误配）。
  static SchedulePeakShiftGroup groupForRoom(String? room) {
    final building = buildingOf(room);
    if (lateBuildings.contains(building)) return SchedulePeakShiftGroup.late;
    return SchedulePeakShiftGroup.early;
  }

  /// 从课程的地点字段里取出**楼名**。
  ///
  /// 输入是教务原始教室串（`jwxt_client.dart:1575` 的 `'room'`，整串不拆分），
  /// 形如 `逸夫楼908` / `明德楼903（会议室）` / `教A901` / `理科楼101`。
  /// 处理顺序（顺序不能反，否则 `明德楼903（会议室）` 的括号会把数字裹住）：
  ///   1. 去掉**结尾的**成对括号段（中英文括号都去，可连续多段）；
  ///   2. 去掉**结尾的**房间号：连续的数字（`A101`、`B203` 里的字母因为不连续
  ///      数字会被截断，故同时去掉尾部残留的单个字母）；
  ///   3. 去掉空白。
  ///
  /// 例：`逸夫楼908` → `逸夫楼`；`明德楼903（会议室）` → `明德楼`；
  /// `教A901` → `教`；`理科楼101` → `理科楼`；`创新创业学院` → 原样。
  static String buildingOf(String? room) {
    if (room == null) return '';
    var value = room.trim();
    if (value.isEmpty) return '';
    // 1) 结尾的括号段（可有多段，如「楼901（A）（B）」）。
    while (true) {
      final stripped = value.replaceFirst(
        RegExp(r'\s*[（(][^（()）]*[)）]\s*$'),
        '',
      );
      if (stripped == value) break;
      value = stripped;
    }
    // 2) 结尾的房间号：先剥纯数字，再剥可能残留的字母前缀（A101 → A）。
    value = value.replaceFirst(RegExp(r'\s*\d+$'), '');
    value = value.replaceFirst(RegExp(r'\s*[A-Za-z]+$'), '');
    return value.trim();
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
///
/// **依据**：学校官方《湖南科技学院作息时间表》
/// （春秋冬季 = 1月1日–4月30日 + 10月1日–12月31日；夏季 = 5月1日–9月30日）。
/// 官方备注：教学实行每天 11 课时制，每节课为 45 分钟。
///
/// ⚠️ 改这张表前请先拿到官方作息表对照。本文件曾把 **春秋冬季第 3 节**
/// 误写成夏季的 `10:10–10:55`（正确为 `10:20–11:05`），导致大课间落点
/// 从第 2 节后错位到第 3 节后。`test/schedule_time_test.dart` 现已把
/// 22 个时段全部钉死，改错会立刻红灯。
class ScheduleTimeTable {
  ScheduleTimeTable._();

  static const _lessonTimes = <int, _LessonTimePair>{
    1: _LessonTimePair('08:20–09:05', '08:10–08:55'),
    2: _LessonTimePair('09:15–10:00', '09:05–09:50'),
    3: _LessonTimePair('10:20–11:05', '10:10–10:55'),
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
    bool peakShift = false,
    SchedulePeakShiftGroup? peakShiftGroup,
  }) {
    // 错峰只覆盖第 3、4 小节，且必须先于季节解析生效 —— 作者口径是
    // "错峰是新的时间"，所以固定 summer 模式下也照样走错峰组
    // （见 test/schedule_peak_time_test.dart 的对应断言）。
    if (peakShift) {
      final shifted = SchedulePeakShift.timeFor(
        lesson,
        peakShiftGroup ?? SchedulePeakShift.baselineGroup,
      );
      if (shifted != null) return shifted;
    }
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
  ///
  /// [peakShift] 为真时表示"课表设置里开了错峰开关"：此时节次栏显示的是
  /// **基准组（B 组，早下课）** 的第 3、4 小节时刻；A 组的差异由课程块内
  /// 那一行小字单独提示（见 `schedule_table.dart` 的 `_buildCourseEntry`）。
  /// 其余小节不受影响，仍然按季节解析。
  static String formatSublessonLines(
    String value,
    ScheduleTimeMode mode, {
    DateTime? now,
    bool includeLabels = true,
    bool peakShift = false,
  }) {
    final numbers = sublessonNumbers(value);
    if (numbers.isEmpty) return '';
    return numbers
        .map((number) {
          final time = lessonTime(
            number,
            mode,
            now: now,
            peakShift: peakShift,
            peakShiftGroup: SchedulePeakShift.baselineGroup,
          );
          return includeLabels
              ? '${number.toString().padLeft(2, '0')}小节：$time'
              : time!;
        })
        .join('\n');
  }
}
