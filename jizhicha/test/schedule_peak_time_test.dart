import 'package:flutter_test/flutter_test.dart';
import 'package:jizhicha/schedule_time.dart';

/// 「错峰上课表」回归测试。
///
/// 背景（作者逐条确认过的口径）：
///   「1 错峰是新的时间，第一节课别管了，按照第二节课来调整，因为错峰只调整
///     第二节课，当春秋冬季看，这是暂行的办法，2走早下课，3跟着错峰」
///
/// ⇒ 落地语义：
///   * 错峰**只**影响第二大节 = 第 3、4 小节；
///   * 其余小节（1、2、5～11）**完全按现有季节模式**解析 ——
///     错峰表上午写的是 `8:10`（那其实是夏季列的值），照搬会让春秋冬季的
///     第 1、2 小节凭空提前 10 分钟。本文件里"其余小节不受影响"那几条
///     专门钉死这一点（历史上正是这类跨列搬值造成过第 3 节错位）；
///   * 第 3/4 小节按楼栋分两组：早下课 B 组（基准组）/ 晚下课 A 组；
///   * **识别不出楼栋 → B 组**（作者原话"走早下课"），所以默认值就是 B 组；
///   * 错峰是"新的时间"，与季节无关 ⇒ 固定 `summer` 模式打开开关时也走错峰组。
///
/// ⚠️ 分隔符必须与既有作息表一致：**en dash `–`（U+2013）**，不是 ASCII 连字符。
/// 下面的期望值刻意逐字符写死（含 en dash），而不是从实现里取值再比对。
void main() {
  // 错峰两组第 3、4 小节的精确时刻（逐字符，含 en dash）。
  const late3 = '10:25–11:10';
  const late4 = '11:20–12:05';
  const early3 = '10:10–10:55';
  const early4 = '11:05–11:50';

  // 现有季节表里第 3、4 小节的值（用于证明"关掉开关 = 回到季节表"）。
  const autumn3 = '10:20–11:05';
  const autumn4 = '11:15–12:00';
  const summer3 = '10:10–10:55';
  const summer4 = '11:05–11:50';

  // 2026-11-15 是春秋冬季；2026-06-15 是夏季（5–9 月）。
  final november = DateTime(2026, 11, 15);
  final june = DateTime(2026, 6, 15);

  group('错峰第 3/4 小节：A/B 两组逐字符断言', () {
    test('晚下课组（A 组）：第 3 小节 10:25–11:10、第 4 小节 11:20–12:05', () {
      expect(
        ScheduleTimeTable.lessonTime(
          3,
          ScheduleTimeMode.springAutumnWinter,
          peakShift: true,
          peakShiftGroup: SchedulePeakShiftGroup.late,
        ),
        late3,
      );
      expect(
        ScheduleTimeTable.lessonTime(
          4,
          ScheduleTimeMode.springAutumnWinter,
          peakShift: true,
          peakShiftGroup: SchedulePeakShiftGroup.late,
        ),
        late4,
      );
    });

    test('早下课组（B 组）：第 3 小节 10:10–10:55、第 4 小节 11:05–11:50', () {
      expect(
        ScheduleTimeTable.lessonTime(
          3,
          ScheduleTimeMode.springAutumnWinter,
          peakShift: true,
          peakShiftGroup: SchedulePeakShiftGroup.early,
        ),
        early3,
      );
      expect(
        ScheduleTimeTable.lessonTime(
          4,
          ScheduleTimeMode.springAutumnWinter,
          peakShift: true,
          peakShiftGroup: SchedulePeakShiftGroup.early,
        ),
        early4,
      );
    });

    test('错峰时刻里用的是 en dash（U+2013），不是 ASCII 连字符', () {
      for (final value in [late3, late4, early3, early4]) {
        expect(
          value.contains('\u2013'),
          isTrue,
          reason: '$value 必须使用 en dash 分隔，与既有作息表一致',
        );
        expect(
          value.contains('-'),
          isFalse,
          reason: '$value 不能含 ASCII 连字符，否则小组件/ics 的切分正则会走另一条路',
        );
      }
    });

    test('错峰只覆盖第 3、4 小节（affectsLesson 的边界）', () {
      expect(SchedulePeakShift.affectsLesson(3), isTrue);
      expect(SchedulePeakShift.affectsLesson(4), isTrue);
      for (final lesson in [1, 2, 5, 6, 7, 8, 9, 10, 11]) {
        expect(
          SchedulePeakShift.affectsLesson(lesson),
          isFalse,
          reason: '第 $lesson 小节不在错峰范围内',
        );
      }
    });
  });

  group('开关关闭：第 3/4 小节必须等于现有季节表', () {
    test('春秋冬季（显式模式）', () {
      expect(
        ScheduleTimeTable.lessonTime(
          3,
          ScheduleTimeMode.springAutumnWinter,
        ),
        autumn3,
      );
      expect(
        ScheduleTimeTable.lessonTime(
          4,
          ScheduleTimeMode.springAutumnWinter,
        ),
        autumn4,
      );
    });

    test('夏季（显式模式）', () {
      expect(ScheduleTimeTable.lessonTime(3, ScheduleTimeMode.summer), summer3);
      expect(ScheduleTimeTable.lessonTime(4, ScheduleTimeMode.summer), summer4);
    });

    test('automatic：按日期解析（11 月 → 春秋冬季，6 月 → 夏季）', () {
      expect(
        ScheduleTimeTable.lessonTime(
          3,
          ScheduleTimeMode.automatic,
          now: november,
        ),
        autumn3,
      );
      expect(
        ScheduleTimeTable.lessonTime(3, ScheduleTimeMode.automatic, now: june),
        summer3,
      );
    });
  });

  group('开关打开：其余小节完全不受影响（禁止把错峰表上午的值搬进来）', () {
    test('显式春秋冬季模式下，第 1、2、5～11 小节与不开开关完全相同', () {
      for (final lesson in [1, 2, 5, 6, 7, 8, 9, 10, 11]) {
        final off = ScheduleTimeTable.lessonTime(
          lesson,
          ScheduleTimeMode.springAutumnWinter,
        );
        final on = ScheduleTimeTable.lessonTime(
          lesson,
          ScheduleTimeMode.springAutumnWinter,
          peakShift: true,
          peakShiftGroup: SchedulePeakShiftGroup.late,
        );
        expect(on, off, reason: '第 $lesson 小节不该被错峰改动');
      }
    });

    test('第 3/4 小节以外的边界值：第 1 小节 08:20–09:05、第 11 小节 21:00–21:45', () {
      expect(
        ScheduleTimeTable.lessonTime(1, ScheduleTimeMode.springAutumnWinter),
        '08:20–09:05',
      );
      expect(
        ScheduleTimeTable.lessonTime(11, ScheduleTimeMode.springAutumnWinter),
        '21:00–21:45',
      );
    });

    test('automatic 模式跨季节：月份切换只影响错峰范围内的值', () {
      for (final lesson in [1, 2, 5, 6, 7, 8, 9, 10, 11]) {
        expect(
          ScheduleTimeTable.lessonTime(
            lesson,
            ScheduleTimeMode.automatic,
            now: november,
            peakShift: true,
          ),
          ScheduleTimeTable.lessonTime(
            lesson,
            ScheduleTimeMode.automatic,
            now: november,
          ),
          reason: '11 月（春秋冬季）：第 $lesson 小节不该被错峰改动',
        );
        expect(
          ScheduleTimeTable.lessonTime(
            lesson,
            ScheduleTimeMode.automatic,
            now: june,
            peakShift: true,
          ),
          ScheduleTimeTable.lessonTime(
            lesson,
            ScheduleTimeMode.automatic,
            now: june,
          ),
          reason: '6 月（夏季）：第 $lesson 小节不该被错峰改动',
        );
      }
    });
  });

  group('固定季节模式 + 开关打开：第 3/4 小节仍走错峰组（"错峰是新的时间"）', () {
    test('固定 summer：A 组仍得晚下课组时刻，不受季节表干扰', () {
      expect(
        ScheduleTimeTable.lessonTime(
          3,
          ScheduleTimeMode.summer,
          peakShift: true,
          peakShiftGroup: SchedulePeakShiftGroup.late,
        ),
        late3,
        reason: '夏季第 3 小节本身就是 10:10–10:55，若错峰被季节模式吃掉就会误判成"没生效"',
      );
      expect(
        ScheduleTimeTable.lessonTime(
          4,
          ScheduleTimeMode.summer,
          peakShift: true,
          peakShiftGroup: SchedulePeakShiftGroup.late,
        ),
        late4,
      );
    });

    test('固定 summer：B 组得早下课组时刻', () {
      expect(
        ScheduleTimeTable.lessonTime(
          3,
          ScheduleTimeMode.summer,
          peakShift: true,
          peakShiftGroup: SchedulePeakShiftGroup.early,
        ),
        early3,
      );
      expect(
        ScheduleTimeTable.lessonTime(
          4,
          ScheduleTimeMode.summer,
          peakShift: true,
          peakShiftGroup: SchedulePeakShiftGroup.early,
        ),
        early4,
      );
    });

    test('固定 springAutumnWinter 同样走错峰组', () {
      expect(
        ScheduleTimeTable.lessonTime(
          3,
          ScheduleTimeMode.springAutumnWinter,
          peakShift: true,
          peakShiftGroup: SchedulePeakShiftGroup.early,
        ),
        early3,
      );
    });
  });

  group('楼名 → 分组：精确匹配，识别不出一律 B 组（早下课）', () {
    test('命中 A 组名单：逸夫楼（含教室号）走晚下课组', () {
      expect(
        SchedulePeakShift.buildingOf('逸夫楼908'),
        '逸夫楼',
      );
      expect(
        SchedulePeakShift.groupForRoom('逸夫楼908'),
        SchedulePeakShiftGroup.late,
      );
    });

    test('明德楼属 B 组（早下课），带括号后缀也要正确剥掉', () {
      expect(
        SchedulePeakShift.buildingOf('明德楼903（会议室）'),
        '明德楼',
      );
      expect(
        SchedulePeakShift.groupForRoom('明德楼903（会议室）'),
        SchedulePeakShiftGroup.early,
      );
    });

    test('识别不出来的地点一律走早下课组（B 组）', () {
      for (final room in ['教A901', '理科楼101', '', '  ', '田径场', null]) {
        expect(
          SchedulePeakShift.groupForRoom(room),
          SchedulePeakShiftGroup.early,
          reason: '「$room」不在 A 组名单里，必须回退到 B 组（作者：走早下课）',
        );
      }
    });

    test('反例：子串不得误配 —— "明德"≠"明德楼"，"逸夫"≠"逸夫楼"', () {
      // 若实现用 contains 匹配，'逸夫' 会命中 '逸夫楼'；这里必须不命中。
      expect(
        SchedulePeakShift.groupForRoom('逸夫'),
        SchedulePeakShiftGroup.early,
        reason: '残串不应命中 A 组名单（必须精确相等，不能用 contains）',
      );
      expect(
        SchedulePeakShift.groupForRoom('明德'),
        SchedulePeakShiftGroup.early,
      );
      // 名单里没有的楼，即使与 A 组名单有一字相同也不能误配。
      expect(
        SchedulePeakShift.groupForRoom('尚美'),
        SchedulePeakShiftGroup.early,
      );
    });

    test('A 组名单本身逐个命中晚下课组（名单完整性）', () {
      for (final building in SchedulePeakShift.lateBuildings) {
        expect(
          SchedulePeakShift.groupForRoom(building),
          SchedulePeakShiftGroup.late,
          reason: '$building 应在 A 组（晚下课）',
        );
      }
    });

    test('B 组名单本身逐个命中早下课组', () {
      for (final building in SchedulePeakShift.earlyBuildings) {
        expect(
          SchedulePeakShift.groupForRoom(building),
          SchedulePeakShiftGroup.early,
          reason: '$building 应在 B 组（早下课）',
        );
      }
    });

    test('基准组就是 B 组（早下课）：课块内只对 A 组课加提示行', () {
      expect(SchedulePeakShift.baselineGroup, SchedulePeakShiftGroup.early);
    });
  });

  group('节次栏 / 课块的错峰文案', () {
    test('formatSublessonLines 打开错峰时第 3/4 小节显示基准组（B 组）时刻', () {
      final text = ScheduleTimeTable.formatSublessonLines(
        '第二大节 (03,04小节)',
        ScheduleTimeMode.springAutumnWinter,
        includeLabels: false,
        peakShift: true,
      );
      expect(text, '$early3\n$early4');
    });

    test('formatSublessonLines 关闭错峰时等于季节表（默认参数即是关闭）', () {
      const input = '第二大节 (03,04小节)';
      expect(
        ScheduleTimeTable.formatSublessonLines(
          input,
          ScheduleTimeMode.springAutumnWinter,
          includeLabels: false,
        ),
        '$autumn3\n$autumn4',
      );
      // 显式传 peakShift: false 与不传必须完全一致（默认值必须为 false，
      // 否则既有调用点会静默改变行为）。
      expect(
        ScheduleTimeTable.formatSublessonLines(
          input,
          ScheduleTimeMode.springAutumnWinter,
          includeLabels: false,
          peakShift: false,
        ),
        '$autumn3\n$autumn4',
      );
    });

    test('第 1、2 小节在错峰开关下仍显示季节表时刻', () {
      expect(
        ScheduleTimeTable.formatSublessonLines(
          '第一大节 (01,02小节)',
          ScheduleTimeMode.springAutumnWinter,
          includeLabels: false,
          peakShift: true,
        ),
        '08:20–09:05\n09:15–10:00',
      );
    });

    test('课块内提示行只给 A 组：hintFor 逐行给时刻，且**不带** `03小节：` 前缀', () {
      expect(
        SchedulePeakShift.hintFor([3, 4], SchedulePeakShiftGroup.late),
        '$late3\n$late4',
        reason: '作者 m01571：「把03小节，04小节这几个字去掉，只保留时间」',
      );
      // 不受错峰影响的小节拿不到文案（调用方据此不显示这一行）。
      expect(
        SchedulePeakShift.hintFor([1, 2], SchedulePeakShiftGroup.late),
        isNull,
      );
    });
  });
}
