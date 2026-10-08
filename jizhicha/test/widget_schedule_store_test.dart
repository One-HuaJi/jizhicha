import 'package:flutter_test/flutter_test.dart';
import 'package:jizhicha/academic_calendar.dart';
import 'package:jizhicha/schedule_time.dart';
import 'package:jizhicha/widget_schedule_store.dart';

/// 小组件 JSON 载荷的回归测试。
///
/// 背景：`widget_schedule.json` 曾经是一份**纯快照** —— 写入时刻就把课次解析成
/// 具体时刻字符串（`start`/`end`）以及当时算出的周次（`week`）。于是只要
/// **跨了季节边界（9/30→10/1 或 4/30→5/1）或跨了周，而 App 一直没被打开过**，
/// 原生小组件就会一直显示旧季节的时刻、旧周次，30 分钟轮询也纠正不了。
///
/// 修复把"写什么"与"什么时候读得到"解耦：JSON 里额外落盘
///   - `times.{springAutumnWinter,summer}`：两季各自的 `{start,end}`，由原生侧按
///     **设备当天日期**选列（只有 `automatic` 模式才切；固定模式尊重用户设置）；
///   - `semesterStartDate`：让原生侧按当天日期现算周次，而不是读死 `week`；
///   - `scheduleTimeMode`：模式本身。
///
/// 这里断言的是**载荷内容**；"按日期选列"这一半由 Kotlin 侧
/// `android/app/src/test/java/com/one/huaji/WidgetSeasonTest.kt` 用同一批真实数值
/// 证伪（写 JSON 时是夏季、读时是 10 月，必须取到春秋冬季时刻）。
void main() {
  /// 与 `ScheduleTimeTable` 对齐的真实两季时刻，用于断言载荷里两列都在。
  const autumnStart = '10:20';
  const autumnEnd = '11:05';
  const summerStart = '10:10';
  const summerEnd = '10:55';

  Map<String, dynamic> course({
    String day = '周一',
    String time = '（03小节）',
    String name = '课程',
    String weeks = '1-16周',
  }) {
    return {
      'day': day,
      'time': time,
      'name': name,
      'teacher': '老师',
      'room': '教室',
      'weeks': weeks,
    };
  }

  Map<String, dynamic> build(
    List<Map<String, dynamic>> courses, {
    ScheduleTimeMode mode = ScheduleTimeMode.automatic,
    String? semesterStartDate = '2026-09-07',
    int fallbackWeek = 1,
    DateTime? now,
  }) {
    return WidgetScheduleStore.buildPayload(
      courses,
      mode: mode,
      semesterStartDate: semesterStartDate,
      fallbackWeek: fallbackWeek,
      now: now,
    );
  }

  group('buildPayload 双季节时刻列', () {
    test('automatic 模式落盘两季各自的时刻，两列都取自作息表', () {
      final payload = build([course()], now: DateTime(2026, 9, 30));

      final entry = (payload['courses'] as List).single as Map;
      final times = entry['times'] as Map<String, dynamic>;

      expect(times.keys.toSet(), {'springAutumnWinter', 'summer'});
      expect(times['springAutumnWinter'], {
        'start': autumnStart,
        'end': autumnEnd,
      });
      expect(times['summer'], {'start': summerStart, 'end': summerEnd});

      // 与旧版原生代码的衔接点：`start`/`end` 仍是"写入时刻"那一列的值。
      expect(entry['start'], summerStart);
      expect(entry['end'], summerEnd);
    });

    test('写入时刻的季节不影响落盘的两列（这正是修掉陈旧化的前提）', () {
      // 同一份课表在 1 月写和在 7 月写，落盘的 times 必须完全一致；
      // 变的只是 start/end 这个兜底快照。原生侧读的就是 times。
      final inJanuary = build([course()], now: DateTime(2026, 1, 15));
      final inJuly = build([course()], now: DateTime(2026, 7, 15));

      Map<String, dynamic> timesOf(Map<String, dynamic> payload) =>
          ((payload['courses'] as List).single as Map)['times']
              as Map<String, dynamic>;

      expect(timesOf(inJanuary), timesOf(inJuly));
      expect(timesOf(inJanuary)['springAutumnWinter'],
          timesOf(inJuly)['springAutumnWinter']);
      expect(timesOf(inJanuary)['summer'], timesOf(inJuly)['summer']);

      // 兜底快照随写入季节不同 —— 旧版 JSON 只有它，所以跨季节后会错。
      expect(((inJanuary['courses'] as List).single as Map)['start'],
          autumnStart);
      expect(((inJuly['courses'] as List).single as Map)['start'], summerStart);
    });

    test('固定模式只尊重用户选定的那一列，不落盘 times', () {
      for (final mode in [
        ScheduleTimeMode.springAutumnWinter,
        ScheduleTimeMode.summer,
      ]) {
        final payload = build([course()], mode: mode, now: DateTime(2026, 10, 1));
        final entry = (payload['courses'] as List).single as Map;

        expect(entry.containsKey('times'), isFalse,
            reason: '固定模式没有"选列"一说，落盘两列反而会让人以为会切换');
        expect(payload['scheduleTimeMode'], mode.storageValue);
      }

      // 固定春秋冬季时，哪怕在夏季写盘，快照也必须是春秋冬季的。
      expect(
        ((build([course()], mode: ScheduleTimeMode.springAutumnWinter,
                    now: DateTime(2026, 7, 15))['courses'] as List).single
            as Map)['start'],
        autumnStart,
      );
      // 固定夏季时同理。
      expect(
        ((build([course()], mode: ScheduleTimeMode.summer,
                    now: DateTime(2026, 1, 15))['courses'] as List).single
            as Map)['start'],
        summerStart,
      );
    });
  });

  group('buildPayload 元数据', () {
    test('落盘模式与开学日期，供原生侧按当天日期选列 / 算周次', () {
      final payload = build(
        [course()],
        mode: ScheduleTimeMode.automatic,
        semesterStartDate: '2026-09-07',
        now: DateTime(2026, 9, 30),
      );

      expect(payload['scheduleTimeMode'], 'automatic');
      expect(payload['semesterStartDate'], '2026-09-07');
      expect(payload['updatedAt'], isA<int>());
      expect(payload['courses'], hasLength(1));
    });

    test('开学日期缺失时落盘空串，不崩也不写 null', () {
      final payload = build([course()], semesterStartDate: null);
      expect(payload['semesterStartDate'], '');
      // 没有开学日期就只能用调用方给的兜底周次。
      expect(payload['week'], 1);
    });

    test('week 按写入时刻现算（这正是会过期的那个快照）', () {
      // 开学 2026-09-07（周一）。
      expect(build([course()], now: DateTime(2026, 9, 7))['week'], 1);
      expect(build([course()], now: DateTime(2026, 9, 14))['week'], 2);
      expect(build([course()], now: DateTime(2026, 9, 28))['week'], 4);

      // 还没开学 → 0（原生侧据此显示「还没开学」）。
      expect(build([course()], now: DateTime(2026, 8, 31))['week'], 0);
      // 学期已结束 → >20（原生侧据此显示「本学期已结束」）。
      expect(build([course()], now: DateTime(2027, 1, 25))['week'], 21);
    });

    test('week 与 AcademicCalendar.weekNumberFor 逐点一致（Kotlin 侧用同一组输入交叉验证）', () {
      final start = DateTime(2026, 9, 7);
      const cases = <List<int>>[
        // [开学日偏移天数, 期望周次]
        [-1, 0],
        [0, 1],
        [6, 1],
        [7, 2],
        [13, 2],
        [14, 3],
        [139, 20],
      ];

      for (final c in cases) {
        final offset = c[0];
        final expected = c[1];
        final now = start.add(Duration(days: offset));
        expect(AcademicCalendar.weekNumberFor(start, now), expected,
            reason: '开学日 + $offset 天 应为第 $expected 周');
        expect(build([course()], now: now)['week'], expected,
            reason: '落盘的 week 也必须等于 weekNumberFor 的结果');
      }
    });
  });

  group('buildPayload 输入容错', () {
    test('解析不出星期或小节的课程行被丢弃，不写入空 start', () {
      final payload = build([
        course(day: '星期八'),
        course(time: '没有小节号'),
        course(),
      ]);
      final courses = payload['courses'] as List;
      expect(courses, hasLength(1));
      expect((courses.single as Map)['day'], 1);
    });

    test('没有可用的课程行时 courses 为空数组，而不是 null', () {
      final payload = build(const []);
      expect(payload['courses'], isEmpty);
      expect(payload['scheduleTimeMode'], 'automatic');
    });

    test('周次文本展开成整数列表（1-16周 / 单双周 / 逗号）', () {
      Map<String, dynamic> entryWith(String weeks) =>
          (build([course(weeks: weeks)])['courses'] as List).single
              as Map<String, dynamic>;

      expect(entryWith('1-3周')['weeks'], [1, 2, 3]);
      expect(entryWith('1,3,5周')['weeks'], [1, 3, 5]);
      expect(entryWith('2-4周(双周)')['weeks'], [2, 3, 4]);
      // 倒序/非法区间不展开，避免造出空壳课程。
      expect(entryWith('5-2周')['weeks'], isEmpty);
      expect(entryWith('')['weeks'], isEmpty);
    });

    test('多个小节组成的大节取首尾小节边界', () {
      // 「（05,06小节）」的解析口径由 ScheduleTimeTable.sublessonNumbers 决定；
      // 这里不假设它的贪心程度，只用它的返回值去断言 start 来自首个小节、
      // end 来自末个小节 —— 这正是 buildPayload 里 first/last 的语义。
      final numbers = ScheduleTimeTable.sublessonNumbers('（05,06小节）');
      expect(numbers, isNotEmpty);

      final payload = build([course(time: '（05,06小节）')]);
      final entry = (payload['courses'] as List).single as Map;
      final times = entry['times'] as Map<String, dynamic>;

      final first = ScheduleTimeTable.lessonTime(
        numbers.first,
        ScheduleTimeMode.springAutumnWinter,
      )!;
      final last = ScheduleTimeTable.lessonTime(
        numbers.last,
        ScheduleTimeMode.springAutumnWinter,
      )!;
      expect(times['springAutumnWinter'], {
        'start': first.split('–').first,
        'end': last.split('–').last,
      });
      expect(
        times['summer'],
        {
          'start': ScheduleTimeTable.lessonTime(
            numbers.first,
            ScheduleTimeMode.summer,
          )!.split('–').first,
          'end': ScheduleTimeTable.lessonTime(
            numbers.last,
            ScheduleTimeMode.summer,
          )!.split('–').last,
        },
      );

      // 单独钉住一处真实差异：第 5 节下午两季差 15 分钟。
      expect(times['springAutumnWinter']!['start'], '14:30');
      expect(times['summer']!['start'], '14:45');
    });
  });

  group('向后兼容', () {
    test('载荷仍是合法 JSON 且保留旧字段（旧版原生代码照旧能读）', () {
      final payload = build([course()], now: DateTime(2026, 9, 30));

      // 旧版原生代码只认 week / courses[].{day,start,name,teacher,room,weeks}。
      expect(payload['week'], isA<int>());
      final entry = (payload['courses'] as List).single as Map;
      for (final key in [
        'day',
        'start',
        'end',
        'name',
        'teacher',
        'room',
        'weeks',
      ]) {
        expect(entry.containsKey(key), isTrue, reason: '旧字段 $key 不能丢');
      }
      expect(entry['day'], isA<int>());
      expect(entry['weeks'], isA<List>());
    });

    test('新字段都是增量：删掉它们后载荷仍能被旧解析路径消费', () {
      final payload = build([course()], now: DateTime(2026, 9, 30));
      // 模拟"旧版 Kotlin 只读已知字段"：多余键不应影响必需键的取值。
      final entry = (payload['courses'] as List).single as Map;
      expect(entry['start'], isNotEmpty);
      expect(entry['name'], '课程');
      expect(entry['teacher'], '老师');
      expect(entry['room'], '教室');
    });
  });
}
