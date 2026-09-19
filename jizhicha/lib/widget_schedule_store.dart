import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:flutter/services.dart' show MethodChannel;
import 'package:path_provider/path_provider.dart';

import 'academic_calendar.dart';
import 'app_settings.dart';
import 'jwxt_client.dart';
import 'schedule_cache_store.dart';
import 'schedule_time.dart';

/// 给 Android 桌面小组件写一份紧凑的课表 JSON。
///
/// 桌面小组件是原生 Kotlin（AppWidget + RemoteViews）实现，不能直接读
/// Flutter 的内存对象，只能读文件。这里把当前账号的课表解析后落盘到
/// 应用文档目录（Android 上即 context.filesDir，与原生 AppWidget 同包共享），
/// 小组件读取后渲染「下一节课」。
class WidgetScheduleStore {
  WidgetScheduleStore._();

  static const _fileName = 'widget_schedule.json';
  static const _channel = MethodChannel('com.one.huaji/widget_settings');

  /// 把当前账号的课表写入小组件 JSON；任何失败都不影响主流程。
  static Future<void> writeCurrentSchedule(String studentId) async {
    try {
      final normalized = studentId.trim();
      if (normalized.isEmpty) return;

      final settings = await AppSettings.load();
      final profile = await UserDataCacheStore.loadProfile(normalized);
      if (profile == null || profile.scheduleTerms.isEmpty) return;

      final term = profile.scheduleTerms.first;
      final html = await UserDataCacheStore.loadScheduleHtml(normalized, term);
      if (html == null || html.trim().isEmpty) return;

      final courses = parseScheduleHtml(html);
      if (courses.isEmpty) return;

      // 当前周次：按开学日期自动算；算出的周次可能 <1（未开学）或 >20（已结束），
      // 小组件侧据此显示「还没开学 / 本学期已结束」。
      final startDate = DateTime.tryParse(settings.semesterStartDate);
      var week = settings.currentWeek;
      if (startDate != null) {
        week = AcademicCalendar.weekNumberFor(startDate, DateTime.now());
      }

      final widgetCourses = <Map<String, dynamic>>[];
      for (final c in courses) {
        final day = _dayNumber(c['day'] ?? '');
        final sublessons = ScheduleTimeTable.sublessonNumbers(c['time'] ?? '');
        if (day <= 0 || sublessons.isEmpty) continue;
        final start = _lessonBoundary(
          sublessons.first,
          settings.scheduleTimeMode,
          start: true,
        );
        final end = _lessonBoundary(
          sublessons.last,
          settings.scheduleTimeMode,
          start: false,
        );
        if (start == null || end == null) continue;
        widgetCourses.add({
          'day': day,
          'start': start,
          'end': end,
          'name': c['name'] ?? '',
          'teacher': c['teacher'] ?? '',
          'room': c['room'] ?? '',
          'weeks': _expandWeeks(c['weeks'] ?? ''),
        });
      }

      final dir = await getApplicationDocumentsDirectory();
      final file = File(dir.path + Platform.pathSeparator + _fileName);
      await file.writeAsString(
        jsonEncode({
          'week': week,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
          'courses': widgetCourses,
        }),
        flush: true,
      );
      // 数据落盘后立即刷新小组件，避免等 30 分钟轮询。
      try {
        await _channel.invokeMethod('refreshWidget');
      } catch (_) {}
    } catch (_) {
      // 写失败不阻塞主流程。
    }
  }

  static int _dayNumber(String day) {
    switch (day) {
      case '周一':
        return 1;
      case '周二':
        return 2;
      case '周三':
        return 3;
      case '周四':
        return 4;
      case '周五':
        return 5;
      case '周六':
        return 6;
      case '周日':
        return 7;
      default:
        return 0;
    }
  }

  static String? _lessonBoundary(
    int lesson,
    ScheduleTimeMode mode, {
    required bool start,
  }) {
    final full = ScheduleTimeTable.lessonTime(lesson, mode);
    if (full == null) return null;
    final parts = full.split(RegExp(r'[–-]'));
    if (parts.length != 2) return null;
    return (start ? parts[0] : parts[1]).trim();
  }

  /// 把「1-16周」「1,3,5周」之类文本展开成周次列表。
  static List<int> _expandWeeks(String weeks) {
    final clean = weeks
        .replaceAll(RegExp(r'\[[^\]]*\]'), '')
        .replaceAll(RegExp(r'[^\d,\-]'), '');
    final result = <int>{};
    for (final part in clean.split(',')) {
      final t = part.trim();
      if (t.isEmpty) continue;
      if (t.contains('-')) {
        final nums = t
            .split('-')
            .map((e) => int.tryParse(e.trim()) ?? 0)
            .toList();
        if (nums.length == 2 && nums[0] > 0 && nums[1] >= nums[0]) {
          for (var w = nums[0]; w <= nums[1]; w++) {
            result.add(w);
          }
        }
      } else {
        final n = int.tryParse(t);
        if (n != null && n > 0) result.add(n);
      }
    }
    final list = result.toList()..sort();
    return list;
  }
}
