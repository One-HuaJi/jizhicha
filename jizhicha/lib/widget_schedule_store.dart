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
///
/// ## ⚠️ 两个"写文件时算死就会过期"的量（别再写死第三个）
///
/// 小组件可能连续数周不被打开 App 触发重写，所以**凡是随日期变化的量都不能只落盘
/// 一份快照**，必须落盘「算它所需的输入」，由 Kotlin 侧按设备当天日期现算：
///
/// 1. **课次时刻**：季节（春秋冬季 / 夏季）决定时刻。`automatic` 模式下额外落盘
///    `times.{springAutumnWinter,summer}` 两列，Kotlin 按当天月份选列；
///    固定模式落盘用户选定的那一列（快照即用户意图，不存在过期）。
/// 2. **当前周次**：额外落盘 `semesterStartDate`，Kotlin 按当天日期现算周次；
///    App 未提供开学日期时才回退到 `week` 快照。
///
/// **时刻的唯一真相仍然是 `lib/schedule_time.dart` 的 [ScheduleTimeTable]** ——
/// 这里只把已算好的时刻转录进 JSON，绝不在 Kotlin 侧复制第二份作息表。
class WidgetScheduleStore {
  WidgetScheduleStore._();

  static const _fileName = 'widget_schedule.json';
  static const _channel = MethodChannel('com.one.huaji/widget_settings');

  /// 小组件数据文件。此文件是**全局单份**（不是按账号分文件），因此在删除
  /// 账号或切换到无课表账号时必须显式清理，不能让 launcher 继续显示前一人的
  /// 课程/老师/教室。
  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(dir.path + Platform.pathSeparator + _fileName);
  }

  /// 删除 widget JSON、取消旧提醒并刷新为“暂无课表”。
  /// 任一失败都不阻塞主流程，但该方法必须被删除账号/切换账号路径调用。
  static Future<void> clear() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Native side will retry deletion/cancel when invoked below.
    }
    try {
      await _channel.invokeMethod('clearWidgetData');
    } catch (_) {
      // Widgets are optional; privacy-sensitive file deletion above already ran.
    }
  }

  /// 把当前账号的课表写入小组件 JSON；任何失败都不影响主流程。
  static Future<void> writeCurrentSchedule(String studentId) async {
    try {
      final normalized = studentId.trim();
      if (normalized.isEmpty) {
        await clear();
        return;
      }

      final settings = await AppSettings.load();
      final profile = await UserDataCacheStore.loadProfile(normalized);
      if (profile == null || profile.scheduleTerms.isEmpty) {
        await clear();
        return;
      }

      final term = profile.scheduleTerms.first;
      final html = await UserDataCacheStore.loadScheduleHtml(normalized, term);
      if (html == null || html.trim().isEmpty) {
        await clear();
        return;
      }

      final courses = parseScheduleHtml(html);
      if (courses.isEmpty) {
        await clear();
        return;
      }

      final file = await _file();
      await file.writeAsString(
        jsonEncode(
          buildPayload(
            courses,
            mode: settings.scheduleTimeMode,
            peakShift: settings.peakShiftEnabled,
            semesterStartDate: settings.semesterStartDate,
            fallbackWeek: settings.currentWeek,
            now: DateTime.now(),
          ),
        ),
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

  /// 构造小组件 JSON 的可测纯函数（不碰文件系统、不读平台通道）。
  ///
  /// 之所以抽出来：小组件"错季节"这个缺陷只有在**写入时刻的季节 ≠ 读取时刻的季节**
  /// 时才暴露，而真实写盘依赖 `path_provider` + `MethodChannel`，无法在单测里复现。
  /// 这里把"写进去什么"与"什么时候读得到"解耦——单测直接构造 9 月（夏季）的
  /// 载荷，再断言语义上 10 月（春秋冬季）能取到另一列。
  ///
  /// [courses] 是 `parseScheduleHtml` 的原始课程行；[mode] 是用户在设置页选的模式
  /// （**固定模式必须被尊重**，只有 `automatic` 才按日期切列）；[now] 注入"写入时刻"。
  ///
  /// [peakShift] 为真时启用错峰上课表（设置页开关）：第 3、4 小节的时刻改为按该课
  /// 楼栋取 A/B 组的错峰值（[SchedulePeakShift.groupForRoom]）。
  /// Kotlin 侧**完全不用改**：`AppWidget.kt` 只按月份在 `springAutumnWinter` /
  /// `summer` 两列之间选，所以只要把错峰增量算进**两列**，两季读到的都是错峰值。
  static Map<String, dynamic> buildPayload(
    List<Map<String, dynamic>> courses, {
    required ScheduleTimeMode mode,
    bool peakShift = false,
    String? semesterStartDate,
    int fallbackWeek = 1,
    DateTime? now,
  }) {
    final moment = now ?? DateTime.now();

    final widgetCourses = <Map<String, dynamic>>[];
    for (final c in courses) {
      final day = _dayNumber(c['day'] ?? '');
      final sublessons = ScheduleTimeTable.sublessonNumbers(c['time'] ?? '');
      if (day <= 0 || sublessons.isEmpty) continue;
      final first = sublessons.first;
      final last = sublessons.last;

      // 错峰只作用于第 3、4 小节；组别由课程楼栋决定（识别不出一律 B 组）。
      final room = c['room'] as String? ?? '';
      final peakGroup = peakShift && SchedulePeakShift.affectsLesson(first)
          ? SchedulePeakShift.groupForRoom(room)
          : null;

      // 落盘两列各自的时刻；`start`/`end` 是与旧版 Kotlin 的唯一衔接点。
      // ⚠️ 固定季节模式下不写 `times`，Kotlin 只能读 `start`/`end`，
      // 所以错峰增量必须**同时**体现在这两个顶层字段里（否则小组件显示旧时刻）。
      final base = _lessonBoundary(
        first,
        mode,
        start: true,
        now: moment,
        peakShift: peakShift,
        peakShiftGroup: peakGroup,
      );
      final baseEnd = _lessonBoundary(
        last,
        mode,
        start: false,
        now: moment,
        peakShift: peakShift,
        peakShiftGroup: peakGroup,
      );
      if (base == null || baseEnd == null) continue;

      final entry = <String, dynamic>{
        'day': day,
        'start': base,
        'end': baseEnd,
        'name': c['name'] ?? '',
        'teacher': c['teacher'] ?? '',
        'room': c['room'] ?? '',
        'weeks': _expandWeeks(c['weeks'] ?? ''),
      };
      if (mode == ScheduleTimeMode.automatic) {
        entry['times'] = _timeColumns(
          first,
          last,
          now: moment,
          peakShift: peakShift,
          peakShiftGroup: peakGroup,
        );
      }
      widgetCourses.add(entry);
    }

    // 当前周次：算出的结果可能 <1（未开学）或 >20（学期已结束），
    // 小组件侧据此显示「还没开学 / 本学期已结束」。
    //
    // 同时落盘 `semesterStartDate`：周次本身是**快照**，App 多周不打开就会一直显示
    // 旧的「第 N 周」。Kotlin 侧优先用它按当天日期现算，算不出才回退 `week`。
    final startDate = semesterStartDate == null
        ? null
        : DateTime.tryParse(semesterStartDate);
    final week = startDate == null
        ? fallbackWeek
        : AcademicCalendar.weekNumberFor(startDate, moment);

    return {
      'week': week,
      'semesterStartDate': semesterStartDate ?? '',
      'scheduleTimeMode': mode.storageValue,
      'updatedAt': moment.millisecondsSinceEpoch,
      'courses': widgetCourses,
    };
  }

  /// 同一大节在春秋冬季 / 夏季两套作息下的 `{start, end}`。
  ///
  /// 值一律取自 [ScheduleTimeTable]（作息表的唯一真相），这里只是把它转录成
  /// JSON 字段，**不引入第二份时刻数据**。
  ///
  /// [peakShift] / [peakShiftGroup]：错峰开关打开且该课落在第 3、4 小节时，
  /// **两列都写该组的错峰时刻**（作者口径"错峰是新的时间"，与季节无关）。
  static Map<String, Map<String, String>> _timeColumns(
    int first,
    int last, {
    DateTime? now,
    bool peakShift = false,
    SchedulePeakShiftGroup? peakShiftGroup,
  }) {
    // start 取首个小节的开始、end 取末个小节的结束 —— 与 `start`/`end` 快照同一口径。
    // 注意 `now` 必须一透到底：它决定 automatic 模式下"哪一列算快照列"，
    // 不传的话两列虽然各自都写死模式（不受影响），但可注入性会丢掉、测试会失真。
    String? boundary(
      int lesson,
      ScheduleTimeMode mode, {
      required bool start,
    }) => _lessonBoundary(
      lesson,
      mode,
      start: start,
      now: now,
      peakShift: peakShift,
      peakShiftGroup: peakShiftGroup,
    );

    final sawStart = boundary(
      first,
      ScheduleTimeMode.springAutumnWinter,
      start: true,
    );
    final sawEnd = boundary(
      last,
      ScheduleTimeMode.springAutumnWinter,
      start: false,
    );
    final summerStart = boundary(first, ScheduleTimeMode.summer, start: true);
    final summerEnd = boundary(last, ScheduleTimeMode.summer, start: false);
    if (sawStart == null ||
        sawEnd == null ||
        summerStart == null ||
        summerEnd == null) {
      return const {};
    }
    return {
      'springAutumnWinter': {'start': sawStart, 'end': sawEnd},
      'summer': {'start': summerStart, 'end': summerEnd},
    };
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
    DateTime? now,
    bool peakShift = false,
    SchedulePeakShiftGroup? peakShiftGroup,
  }) {
    final full = ScheduleTimeTable.lessonTime(
      lesson,
      mode,
      now: now,
      peakShift: peakShift,
      peakShiftGroup: peakShiftGroup,
    );
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
