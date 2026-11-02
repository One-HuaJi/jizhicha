// 课表页职责：课程详情弹窗（点击课表里的课块弹出）。
//
// 数据只有 `Map<String, String>` 五个键（`day` / `time` / `name` / `teacher` /
// `room` / `weeks`，来自 `jwxt_client.dart` 的解析结果）。所以这里**只排版已有
// 字段**，绝不臆造学分/课程代码/绩点这类解析器根本没给的东西。
//
// 视觉语言与既有「课程冲突」弹窗一致（`schedule_table.dart` 的
// `_showConflictDialog`）：AlertDialog + 标题行图标 + 可滚动的 content +
// 单个「知道了」按钮，不另造风格。
import 'package:flutter/material.dart';

import '../app_settings.dart';
import '../schedule_time.dart';

/// 上课时间的排版结果。
class CourseTimeDetail {
  /// 第一行：星期 + 原始节次文本，例如 `周一 第一大节 (01,02小节)`。
  final String headline;

  /// 每个小节一行时刻，例如 `01小节：08:00–08:45`。
  final String lessonLines;

  /// 错峰说明（本课实际按哪一组时刻）；没开错峰 / 不涉及第 3、4 小节时为 null。
  final String? peakNote;

  const CourseTimeDetail({
    required this.headline,
    required this.lessonLines,
    required this.peakNote,
  });
}

/// 课程详情弹窗。
class ScheduleCourseDetailDialog extends StatelessWidget {
  const ScheduleCourseDetailDialog({
    super.key,
    required this.course,
    required this.settings,
  });

  final Map<String, String> course;
  final AppSettings settings;

  /// 打开详情弹窗。调用方（课块）只认这个入口，测试也走同一条路径。
  static Future<void> show(
    BuildContext context, {
    required Map<String, String> course,
    required AppSettings settings,
  }) {
    // 弹窗自己做过渡（作者 2026-11-02：动画再做的丰富一点，过渡好一点）：
    // 默认的 showDialog 只有整屏淡入，弹窗本身几乎不动。这里改成
    // 淡入 + 从 0.92 弹到 1.0，用 easeOutBack 给一点回弹，220ms。
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭',
      barrierColor: Colors.black.withAlpha(120),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (_, _, _) =>
          ScheduleCourseDetailDialog(course: course, settings: settings),
      transitionBuilder: (_, animation, _, child) {
        final fade = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOut,
          reverseCurve: Curves.easeIn,
        );
        final scale = Tween<double>(begin: 0.92, end: 1).animate(
          CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutBack,
            reverseCurve: Curves.easeInCubic,
          ),
        );
        return FadeTransition(
          opacity: fade,
          child: ScaleTransition(scale: scale, child: child),
        );
      },
    );
  }

  /// 计算"上课时间"整段文案（纯函数，单测直接调）。
  ///
  /// 错峰口径（§9.19.2）：开着错峰开关且本课落在第 3、4 小节时，详情里显示的
  /// 必须是**这门课实际所属分组**的时刻——按楼栋分组，识别不出楼栋落到基准组
  /// （B 组，早下课）。否则详情和格子里的时刻会互相打架。
  static CourseTimeDetail timeDetail({
    required Map<String, String> course,
    required bool peakShiftEnabled,
    required ScheduleTimeMode mode,
  }) {
    final day = (course['day'] ?? '').trim();
    final time = (course['time'] ?? '').trim();
    final room = course['room'];
    final headline = [day, time].where((s) => s.isNotEmpty).join(' ');
    final numbers = ScheduleTimeTable.sublessonNumbers(time);
    if (numbers.isEmpty) {
      return CourseTimeDetail(
        headline: headline.isEmpty ? '未填写' : headline,
        lessonLines: '',
        peakNote: null,
      );
    }
    final group = SchedulePeakShift.groupForRoom(room);
    final shifted = peakShiftEnabled && numbers.any(SchedulePeakShift.affectsLesson);
    final lines = <String>[];
    // 是否**真的**偏离了季节作息：B 组在夏季作息下和季节表完全一致
    // （第 3 小节都是 10:10），这时再给一句"错峰上课…"就是纯噪音 ——
    // 只在时刻确实不同的时候才说明。
    var reallyShifted = false;
    for (final n in numbers) {
      final String? base = ScheduleTimeTable.lessonTime(n, mode);
      final String? t = (shifted && SchedulePeakShift.affectsLesson(n))
          ? SchedulePeakShift.timeFor(n, group) ?? base
          : base;
      if (t != null && base != null && t != base) reallyShifted = true;
      lines.add('${n.toString().padLeft(2, '0')}小节：${t ?? ''}');
    }
    return CourseTimeDetail(
      headline: headline.isEmpty ? '未填写' : headline,
      lessonLines: lines.join('\n'),
      peakNote: reallyShifted
          ? '错峰上课：本课按「${group.label}」的时刻上下课'
                '（第 3、4 小节错峰，其余小节按季节作息）'
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = (course['name'] ?? '').trim();
    final teacher = (course['teacher'] ?? '').trim();
    final room = (course['room'] ?? '').trim();
    final weeks = (course['weeks'] ?? '').trim();
    final detail = timeDetail(
      course: course,
      peakShiftEnabled: settings.peakShiftEnabled,
      mode: settings.scheduleTimeMode,
    );
    final timeValue = [
      detail.headline,
      if (detail.lessonLines.isNotEmpty) detail.lessonLines,
    ].join('\n');
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.menu_book_outlined, color: scheme.primary, size: 20),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '课程详情',
              style: TextStyle(fontSize: 16),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: SafeArea(
          // 周数可能很长（如 2,5-13,16-17），窄屏也会换行，所以整段可滚。
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name.isNotEmpty ? name : '(未知课程)',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 10),
                _DetailRow(
                  icon: Icons.person_outline,
                  label: '教师',
                  value: teacher.isEmpty ? '未填写' : teacher,
                ),
                _DetailRow(
                  icon: Icons.place_outlined,
                  label: '地点',
                  value: room.isEmpty ? '未填写' : room,
                ),
                _DetailRow(
                  icon: Icons.schedule,
                  label: '上课时间',
                  value: timeValue,
                  extra: detail.peakNote,
                ),
                _DetailRow(
                  icon: Icons.date_range_outlined,
                  label: '上课周数',
                  value: weeks.isEmpty ? '未填写' : weeks,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    );
  }
}

/// 详情里的一行：图标 + 标签 + 值（值可多行）。
class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
    this.extra,
  });

  final IconData icon;
  final String label;
  final String value;

  /// 补充说明（目前只有错峰说明用），显示在值下面。
  final String? extra;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          SizedBox(
            width: 56,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(value, style: const TextStyle(fontSize: 12.5)),
                if (extra != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      extra!,
                      style: TextStyle(fontSize: 11.5, color: scheme.primary),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
