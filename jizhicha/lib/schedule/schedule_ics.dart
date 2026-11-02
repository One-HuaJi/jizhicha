// 课表导出为标准 iCalendar (.ics) 日历格式
//
// 规范依据：RFC 5545 (Internet Calendaring and Scheduling Core Object Specification)
// 支持将当前学期课表按周次、星期和湘科院作息时间表转换为日历日程，
// 便于学生导入系统日历（如小米日历、华为日历、iOS 日历等）。

import '../academic_calendar.dart';
import '../jwxt_client.dart';
import '../schedule_time.dart';

/// 生成课表的标准 iCalendar (.ics) 字符串。
///
/// [courses] 为教务系统解析出的课程列表。
/// [term] 为对应学期（如 '2026-2027-1'）。
/// [mode] 为作息时间模式（默认自动）。
/// [peakShift] 为真时启用错峰上课表（设置页开关）：第 3、4 小节改为按该课楼栋取
/// A/B 组的错峰时刻（[SchedulePeakShift.groupForRoom]），其余小节不受影响。
/// 课程行的 `room` 在这里已经可得（见下方 `final room = ...`），所以能准确分组。
String generateScheduleIcs({
  required List<Map<String, String>> courses,
  required String term,
  ScheduleTimeMode mode = ScheduleTimeMode.automatic,
  bool peakShift = false,
}) {
  final startDate = AcademicCalendar.termStartDates[term] ??
      (term.contains('-1') ? DateTime(2026, 9, 7) : DateTime(2026, 3, 1));

  // 确保基准开学日是周一（1 = Monday）
  final termMonday = startDate.subtract(Duration(days: startDate.weekday - 1));

  final buffer = StringBuffer();
  buffer.writeln('BEGIN:VCALENDAR');
  buffer.writeln('VERSION:2.0');
  buffer.writeln('PRODID:-//One-HuaJi//Jizhicha Campus Helper//CN');
  buffer.writeln('CALSCALE:GREGORIAN');
  buffer.writeln('METHOD:PUBLISH');
  buffer.writeln('X-WR-CALNAME:课程表 ($term)');
  buffer.writeln('X-WR-TIMEZONE:Asia/Shanghai');

  final nowUtcStr = _formatIcsDateTimeUtc(DateTime.now().toUtc());

  var uidSeq = 1;

  for (final course in courses) {
    final name = course['name']?.trim() ?? '';
    if (name.isEmpty) continue;

    final teacher = course['teacher']?.trim() ?? '';
    final room = course['room']?.trim() ?? '';
    final weeksStr = course['weeks']?.trim() ?? '';
    final dayStr = course['day']?.trim() ?? '';
    final timeStr = course['time']?.trim() ?? '';

    final dayOfWeek = int.tryParse(dayStr) ?? 1; // 1 = 周一, 7 = 周日
    final sublessons = ScheduleTimeTable.sublessonNumbers(timeStr);
    if (sublessons.isEmpty) continue;

    final startLesson = sublessons.first;
    final endLesson = sublessons.last;

    // 错峰只作用于第 3、4 小节；组别由该课的教室串推楼名决定（识别不出一律 B 组）。
    final peakGroup = peakShift && SchedulePeakShift.affectsLesson(startLesson)
        ? SchedulePeakShift.groupForRoom(room)
        : null;

    // 针对每个有课的周次生成独立的 VEVENT
    for (var week = 1; week <= AcademicCalendar.weeksPerAcademicYear; week++) {
      if (!weekInWeeks(weeksStr, week)) continue;

      // 该周该天的具体公历日期
      final classDate = termMonday.add(Duration(days: (week - 1) * 7 + (dayOfWeek - 1)));

      final (startHour, startMin) = _getLessonStartTime(
        startLesson,
        classDate,
        mode,
        peakShift: peakShift,
        peakShiftGroup: peakGroup,
      );
      final (endHour, endMin) = _getLessonEndTime(
        endLesson,
        classDate,
        mode,
        peakShift: peakShift,
        peakShiftGroup: peakGroup,
      );

      final dtStart = DateTime(classDate.year, classDate.month, classDate.day, startHour, startMin);
      final dtEnd = DateTime(classDate.year, classDate.month, classDate.day, endHour, endMin);

      final uid = 'jizhicha-$term-${uidSeq++}@huse';

      buffer.writeln('BEGIN:VEVENT');
      buffer.writeln('UID:$uid');
      buffer.writeln('DTSTAMP:$nowUtcStr');
      buffer.writeln('DTSTART:${_formatIcsDateTimeLocal(dtStart)}');
      buffer.writeln('DTEND:${_formatIcsDateTimeLocal(dtEnd)}');
      buffer.writeln('SUMMARY:${_escapeIcs(name)}');

      final description = StringBuffer();
      if (teacher.isNotEmpty) description.write('教师：$teacher\\n');
      if (room.isNotEmpty) description.write('教室：$room\\n');
      description.write('第 $week 周 (第 $startLesson-$endLesson 节)');
      buffer.writeln('DESCRIPTION:${description.toString()}');

      if (room.isNotEmpty) {
        buffer.writeln('LOCATION:${_escapeIcs(room)}');
      }

      buffer.writeln('STATUS:CONFIRMED');
      buffer.writeln('END:VEVENT');
    }
  }

  buffer.writeln('END:VCALENDAR');
  return buffer.toString();
}

(int, int) _getLessonStartTime(
  int lesson,
  DateTime date,
  ScheduleTimeMode mode, {
  bool peakShift = false,
  SchedulePeakShiftGroup? peakShiftGroup,
}) {
  final timeStr = ScheduleTimeTable.lessonTime(
    lesson,
    mode,
    now: date,
    peakShift: peakShift,
    peakShiftGroup: peakShiftGroup,
  );
  if (timeStr == null) return (8, 0);
  final parts = timeStr.split(RegExp(r'[–-]'));
  if (parts.isEmpty) return (8, 0);
  final startParts = parts[0].trim().split(':');
  if (startParts.length < 2) return (8, 0);
  final h = int.tryParse(startParts[0]) ?? 8;
  final m = int.tryParse(startParts[1]) ?? 0;
  return (h, m);
}

(int, int) _getLessonEndTime(
  int lesson,
  DateTime date,
  ScheduleTimeMode mode, {
  bool peakShift = false,
  SchedulePeakShiftGroup? peakShiftGroup,
}) {
  final timeStr = ScheduleTimeTable.lessonTime(
    lesson,
    mode,
    now: date,
    peakShift: peakShift,
    peakShiftGroup: peakShiftGroup,
  );
  if (timeStr == null) return (8, 45);
  final parts = timeStr.split(RegExp(r'[–-]'));
  if (parts.length < 2) return (8, 45);
  final endParts = parts[1].trim().split(':');
  if (endParts.length < 2) return (8, 45);
  final h = int.tryParse(endParts[0]) ?? 8;
  final m = int.tryParse(endParts[1]) ?? 45;
  return (h, m);
}

String _formatIcsDateTimeLocal(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}${two(dt.month)}${two(dt.day)}T${two(dt.hour)}${two(dt.minute)}00';
}

String _formatIcsDateTimeUtc(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}${two(dt.month)}${two(dt.day)}T${two(dt.hour)}${two(dt.minute)}00Z';
}

String _escapeIcs(String text) {
  return text
      .replaceAll('\\', '\\\\')
      .replaceAll(';', '\\;')
      .replaceAll(',', '\\,')
      .replaceAll('\n', '\\n');
}
