import 'package:flutter_test/flutter_test.dart';
import 'package:jizhicha/schedule/schedule_ics.dart';
import 'package:jizhicha/schedule_time.dart';

void main() {
  group('Schedule ICS export', () {
    test('generateScheduleIcs produces valid iCalendar format', () {
      final courses = [
        {
          'name': '高等数学',
          'teacher': '张老师',
          'room': '理科楼901',
          'weeks': '1-2(周)',
          'day': '1', // 周一
          'time': '第一大节 (01,02小节)',
        },
      ];

      final ics = generateScheduleIcs(
        courses: courses,
        term: '2026-2027-1',
        mode: ScheduleTimeMode.springAutumnWinter,
      );

      expect(ics, contains('BEGIN:VCALENDAR'));
      expect(ics, contains('VERSION:2.0'));
      expect(ics, contains('PRODID:-//One-HuaJi//Jizhicha Campus Helper//CN'));
      expect(ics, contains('SUMMARY:高等数学'));
      expect(ics, contains('LOCATION:理科楼901'));
      expect(ics, contains('教师：张老师'));
      expect(ics, contains('第 1 周 (第 1-2 节)'));
      expect(ics, contains('第 2 周 (第 1-2 节)'));
      expect(ics, contains('END:VCALENDAR'));

      // 验证生成了两个 VEVENT（第1周和第2周）
      final eventCount = 'BEGIN:VEVENT'.allMatches(ics).length;
      expect(eventCount, equals(2));
    });

    test('generateScheduleIcs handles empty course list gracefully', () {
      final ics = generateScheduleIcs(
        courses: [],
        term: '2026-2027-1',
      );
      expect(ics, contains('BEGIN:VCALENDAR'));
      expect(ics, contains('END:VCALENDAR'));
      expect(ics.contains('BEGIN:VEVENT'), isFalse);
    });
  });
}
