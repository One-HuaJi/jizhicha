import 'package:flutter_test/flutter_test.dart';
import 'package:jizhicha/schedule_time.dart';

/// 把 `HH:MM–HH:MM` 解析成分钟数（分隔符是 en dash U+2013，不是连字符）。
({int start, int end}) _parse(String value) {
  final parts = value.split('–');
  expect(parts.length, 2, reason: '时段格式应为 HH:MM–HH:MM，实际为 "$value"');
  int toMinutes(String hhmm) {
    final hm = hhmm.trim().split(':');
    expect(hm.length, 2, reason: '时刻格式应为 HH:MM，实际为 "$hhmm"');
    return int.parse(hm[0]) * 60 + int.parse(hm[1]);
  }

  return (start: toMinutes(parts[0]), end: toMinutes(parts[1]));
}

/// 上午 1–4 节、下午 5–8 节、晚上 9–11 节。
const _blocks = <String, List<int>>{
  '上午': [1, 2, 3, 4],
  '下午': [5, 6, 7, 8],
  '晚上': [9, 10, 11],
};

/// 依据：学校官方《湖南科技学院作息时间表》。
/// 春秋冬季 = 1月1日–4月30日 + 10月1日–12月31日；夏季 = 5月1日–9月30日。
/// 官方备注：教学实行每天 11 课时制，每节课为 45 分钟。
const _expectedSpringAutumnWinter = <int, String>{
  1: '08:20–09:05',
  2: '09:15–10:00',
  3: '10:20–11:05',
  4: '11:15–12:00',
  5: '14:30–15:15',
  6: '15:25–16:10',
  7: '16:25–17:10',
  8: '17:20–18:05',
  9: '19:10–19:55',
  10: '20:05–20:50',
  11: '21:00–21:45',
};

const _expectedSummer = <int, String>{
  1: '08:10–08:55',
  2: '09:05–09:50',
  3: '10:10–10:55',
  4: '11:05–11:50',
  5: '14:45–15:30',
  6: '15:40–16:25',
  7: '16:40–17:25',
  8: '17:35–18:20',
  9: '19:30–20:15',
  10: '20:25–21:10',
  11: '21:20–22:05',
};

String _timeOf(int lesson, ScheduleTimeMode mode) =>
    ScheduleTimeTable.lessonTime(lesson, mode)!;

/// 某一组小节在该模式下的"课间间隔序列"（前一节结束 → 后一节开始，分钟）。
List<int> _gaps(ScheduleTimeMode mode, List<int> lessons) {
  final gaps = <int>[];
  for (var i = 0; i < lessons.length - 1; i++) {
    final current = _parse(_timeOf(lessons[i], mode));
    final next = _parse(_timeOf(lessons[i + 1], mode));
    gaps.add(next.start - current.end);
  }
  return gaps;
}

void main() {
  group('ScheduleTimeTable', () {
    test('自动模式按本地日期切换季节', () {
      expect(
        ScheduleTimeTable.resolveMode(
          ScheduleTimeMode.automatic,
          now: DateTime(2026, 4, 30),
        ),
        ScheduleTimeMode.springAutumnWinter,
      );
      expect(
        ScheduleTimeTable.resolveMode(
          ScheduleTimeMode.automatic,
          now: DateTime(2026, 5, 1),
        ),
        ScheduleTimeMode.summer,
      );
      expect(
        ScheduleTimeTable.resolveMode(
          ScheduleTimeMode.automatic,
          now: DateTime(2026, 9, 30),
        ),
        ScheduleTimeMode.summer,
      );
      expect(
        ScheduleTimeTable.resolveMode(
          ScheduleTimeMode.automatic,
          now: DateTime(2026, 10, 1),
        ),
        ScheduleTimeMode.springAutumnWinter,
      );
    });

    test('固定模式不受日期影响', () {
      expect(
        ScheduleTimeTable.lessonTime(
          1,
          ScheduleTimeMode.springAutumnWinter,
          now: DateTime(2026, 7, 1),
        ),
        '08:20–09:05',
      );
      expect(
        ScheduleTimeTable.lessonTime(
          1,
          ScheduleTimeMode.summer,
          now: DateTime(2026, 1, 1),
        ),
        '08:10–08:55',
      );
    });

    test('只解析课程小节，过滤生活作息项目', () {
      expect(
        ScheduleTimeTable.formatSublessonLines(
          '第一大节 (01,02小节)',
          ScheduleTimeMode.springAutumnWinter,
        ),
        '01小节：08:20–09:05\n02小节：09:15–10:00',
      );
      expect(
        ScheduleTimeTable.formatSublessonLines(
          '第一大节 (01,02小节)',
          ScheduleTimeMode.springAutumnWinter,
          includeLabels: false,
        ),
        '08:20–09:05\n09:15–10:00',
      );
      expect(
        ScheduleTimeTable.formatSublessonLines(
          '第二大节 (03,04小节)',
          ScheduleTimeMode.summer,
        ),
        '03小节：10:10–10:55\n04小节：11:05–11:50',
      );
      expect(
        ScheduleTimeTable.formatSublessonLines(
          '午休',
          ScheduleTimeMode.automatic,
        ),
        isEmpty,
      );
    });

    test('无效或未知小节不生成时间标签', () {
      expect(
        ScheduleTimeTable.formatSublessonLines(
          '第一大节 (12小节)',
          ScheduleTimeMode.automatic,
        ),
        isEmpty,
      );
    });
  });

  // ─────────────────────────────────────────────────────────────
  // 以下为 2026-09-22 新增。
  //
  // 背景：春秋冬季第 3 节曾被误写成夏季的 `10:10–10:55`（官方为
  // `10:20–11:05`），而原有测试只固定了"夏季 03/04 节"，恰好绕开了
  // 出错的那一格，所以错误长期没被发现。下面把两套 22 个时段全部钉死，
  // 并补一条结构性不变量来防"跨列复制漏改"这一类错误。
  // ─────────────────────────────────────────────────────────────
  group('作息表时间值（对照官方《湖南科技学院作息时间表》）', () {
    test('春秋冬季 11 个小节时间与官方作息表逐条一致', () {
      for (final entry in _expectedSpringAutumnWinter.entries) {
        expect(
          _timeOf(entry.key, ScheduleTimeMode.springAutumnWinter),
          entry.value,
          reason: '春秋冬季第 ${entry.key} 小节与官方作息表不符',
        );
      }
    });

    test('夏季 11 个小节时间与官方作息表逐条一致', () {
      for (final entry in _expectedSummer.entries) {
        expect(
          _timeOf(entry.key, ScheduleTimeMode.summer),
          entry.value,
          reason: '夏季第 ${entry.key} 小节与官方作息表不符',
        );
      }
    });

    test('共 11 个小节，且每节课均为 45 分钟（官方备注）', () {
      for (final mode in [
        ScheduleTimeMode.springAutumnWinter,
        ScheduleTimeMode.summer,
      ]) {
        for (var lesson = 1; lesson <= 11; lesson++) {
          final slot = _parse(_timeOf(lesson, mode));
          expect(
            slot.end - slot.start,
            45,
            reason: '${mode.label} 第 $lesson 小节不是 45 分钟',
          );
        }
        // 第 12 小节不存在（官方是每天 11 课时制）。
        expect(
          ScheduleTimeTable.lessonTime(12, mode),
          isNull,
          reason: '官方是每天 11 课时制，不应存在第 12 小节',
        );
      }
    });

    test('同一大节内部的课间结构不随季节变化（只整体平移）', () {
      // 🔴 结构性不变量：季节只改变绝对时刻，不改变大课间落在第几节之后。
      //    历史缺陷正是破坏了它：春秋冬季第 3 节被写成夏季值后，
      //    上午的间隔序列从 [10,20,10] 变成 [10,10,20]，
      //    大课间从第 2 节后错位到第 3 节后。（旧数据下本用例失败。）
      for (final block in _blocks.entries) {
        expect(
          _gaps(ScheduleTimeMode.springAutumnWinter, block.value),
          _gaps(ScheduleTimeMode.summer, block.value),
          reason: '${block.key}的课间结构在两种季节间不一致',
        );
      }
    });

    test('上午存在一次 20 分钟大课间，落在第 2 节之后', () {
      for (final mode in [
        ScheduleTimeMode.springAutumnWinter,
        ScheduleTimeMode.summer,
      ]) {
        expect(
          _gaps(mode, _blocks['上午']!),
          [10, 20, 10],
          reason: '${mode.label} 上午的课间序列应为 10/20/10 分钟',
        );
      }
    });

    test('automatic 模式取到的是按日期解析后的时刻', () {
      // 7 月 → 夏季；1 月 → 春秋冬季（第 3 节正是历史出错的那一格）。
      expect(
        ScheduleTimeTable.lessonTime(
          3,
          ScheduleTimeMode.automatic,
          now: DateTime(2026, 7, 1),
        ),
        _expectedSummer[3],
      );
      expect(
        ScheduleTimeTable.lessonTime(
          3,
          ScheduleTimeMode.automatic,
          now: DateTime(2026, 1, 15),
        ),
        _expectedSpringAutumnWinter[3],
      );
    });

    test('从课表原始文本中取出小节编号', () {
      expect(ScheduleTimeTable.sublessonNumbers('第一大节 (01,02小节)'), [1, 2]);
      expect(ScheduleTimeTable.sublessonNumbers('第三大节 (05,06小节)'), [5, 6]);
      // 超出 1–11 的编号应被忽略（官方只有 11 课时）。
      expect(
        ScheduleTimeTable.sublessonNumbers('第X大节 (12,13小节)'),
        isEmpty,
      );
      // 没有括号（即生活作息项目）时返回空。
      expect(ScheduleTimeTable.sublessonNumbers('第一大节'), isEmpty);
    });
  });
}
