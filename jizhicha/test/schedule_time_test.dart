import 'package:flutter_test/flutter_test.dart';
import 'package:jizhicha/schedule_time.dart';

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
}
