// 课表页职责：错峰上课的**呈现决策**（要不要显示、显示什么、用什么颜色）。
//
// 单独成库（而不是写成 part 里的私有方法）的理由与 `schedule_cell_layout.dart`
// 相同：节次栏的「错峰」徽标与课块内的错峰时刻提示，作者反复要求"一眼能分辨"，
// 这类"样式阈值 / 对比度"只有让渲染层与测试共用同一份实现才验证得住。
import 'package:flutter/material.dart';

import '../schedule_time.dart';

/// 错峰提示的内容：标签 + 时刻正文（可能多行）。
///
/// 分成两段而不是一个拼好的字符串，是为了让渲染层把「错峰」两个字做成
/// 强调段（粗体 + 强调色），后面的时刻用正常字重，一眼能看出"这是错峰时刻"。
class SchedulePeakHint {
  /// 强调标签，固定是「错峰」。
  final String label;

  /// 时刻正文，例如 `10:25–11:10`；同一次课占多个小节时是多行。
  final String body;

  const SchedulePeakHint({required this.label, required this.body});

  /// 纯文本形式（单测 / tooltip 用）。
  String get text => '$label $body';
}

/// 错峰上课的呈现规则。渲染层只从这里取决策，不自己写阈值。
class SchedulePeakStyle {
  SchedulePeakStyle._();

  /// 徽标与提示行上的强调词。
  static const String label = '错峰';

  /// 深底上的强调色（暖浅琥珀）。实测最差对比度 5.31:1（在 #7A4E12 上）。
  static const Color accentOnDark = Color(0xFFFFD98A);

  /// 浅底上的强调色（深赭红）。实测最差对比度 6.03:1（在 beige 上）。
  static const Color accentOnLight = Color(0xFF8F3418);

  /// 对比度阈值：WCAG AA 对非大号文字的要求（本仓课表字号全部 < 18pt）。
  static const double minContrast = 4.5;

  /// 徽标药丸的圆角（够圆但不像按钮，与课块 8px 圆角区分开）。
  static const double badgeRadius = 6;

  /// 通用强调色规则：**看底色明暗选色**，不看主题。
  ///
  /// 为什么按底色而不是按 `Brightness` 选：开启「课程格子彩色」后，同一个
  /// 主题里可能同时出现浅底块（浅色主题的本周块是深底）与深底块，按主题选色
  /// 会在其中一种上掉到 1.1:1（实测），等于看不见。
  /// 阈值 0.5 是安全的：色板与主题色板里的填充色都集中在
  /// Luminance ≥0.77（浅档）与 ≤0.10（深档）两端，中间调是被刻意禁止的。
  static Color accentFor(Color fill) =>
      fill.computeLuminance() > 0.5 ? accentOnLight : accentOnDark;

  /// 节次栏「错峰」徽标的底色 / 文字色（实心 pill，高对比）。
  static Color badgeBackground(Brightness brightness) =>
      brightness == Brightness.dark ? accentOnDark : accentOnLight;

  static Color badgeForeground(Brightness brightness) =>
      brightness == Brightness.dark ? const Color(0xFF28241F) : const Color(0xFFFFFEFB);

  /// 徽标 pill 的高度估算（供一屏压缩的行高预算使用）。
  static double badgeHeight({required double fontSize}) => fontSize * 1.1 + 3;

  /// 节次栏要不要显示「错峰」徽标。
  ///
  /// 只有"错峰开关打开 + 这一行确实是错峰覆盖的节次（第 3、4 小节所在大节）"
  /// 才出现；其余大节必须与旧实现一样干净。
  static bool badgeVisible({required bool enabled, required String time}) {
    if (!enabled) return false;
    final numbers = ScheduleTimeTable.sublessonNumbers(time);
    if (numbers.isEmpty) return false;
    return SchedulePeakShift.affectsLesson(numbers.first);
  }

  /// 课块内的错峰提示内容；null = 不显示。
  ///
  /// 只有**不属于基准组（B 组，早下课）**的课才需要提示：B 组学生按基准表
  /// 上课，多一行"错峰"只会变成噪音（视觉零变化是 §9.19.2 定的口径）。
  /// 时刻文本由 [SchedulePeakShift.hintFor] 统一提供（渲染与单测共用一份，
  /// 连 en dash 都一致）。
  static SchedulePeakHint? courseHint({
    required bool enabled,
    required String time,
    required String? room,
    bool compact = false,
  }) {
    if (!enabled) return null;
    final numbers = ScheduleTimeTable.sublessonNumbers(time);
    if (numbers.isEmpty) return null;
    final group = SchedulePeakShift.groupForRoom(room);
    if (group == SchedulePeakShift.baselineGroup) return null;
    var body = SchedulePeakShift.hintFor(numbers, group);
    if (body == null || body.isEmpty) return null;
    if (compact) {
      // 压缩态（一屏显示）：7 天视图的课块只剩约 44px 可用宽，
      // 完整区间放不下。只保留该课实际**开始时刻**，
      // 完整的两小节区间由详情弹窗与节次栏承担。
      final firstLine = body.split('\n').first.trim();
      final start = firstLine.split(RegExp(r'[–-]')).first.trim();
      if (start.isNotEmpty) body = start;
    }
    return SchedulePeakHint(label: label, body: body);
  }

  /// 节次栏徽标的 tooltip（完整对照表）。
  static String badgeTooltip() {
    final late = SchedulePeakShift.timeFor(3, SchedulePeakShiftGroup.late);
    final lateEnd = SchedulePeakShift.timeFor(4, SchedulePeakShiftGroup.late);
    final early = SchedulePeakShift.timeFor(3, SchedulePeakShiftGroup.early);
    final earlyEnd = SchedulePeakShift.timeFor(4, SchedulePeakShiftGroup.early);
    return '错峰上课：第二大节按楼栋分两组\n'
        '早下课（B 组）：$early / $earlyEnd\n'
        '晚下课（A 组）：$late / $lateEnd\n'
        '其余小节按季节作息不变';
  }
}

/// 节次栏里的「错峰」徽标：一颗**实心 pill**（强调色底 + 高对比文字）。
///
/// 改造原因（作者原话："错峰提示表现不佳，看不出是什么"）：旧实现是一个裸的
/// `Text('错峰', labelSmall, onSurfaceVariant)`，无底色、宽度随字宽、和下面那
/// 两行小节时刻同色同重，读起来像"漏了第三行灰字"，也不在任何位置说明这一格
/// 的时刻来自错峰表。
///
/// 现在的画法（仍然**不加边框**——本仓课表刻意无边框，也不放图标）：
///  - 底色 [SchedulePeakStyle.badgeBackground] + 文字
///    [SchedulePeakStyle.badgeForeground]，实测对比度 ≥6.7:1；
///  - 圆角 6 + 水平 4px 内边距 ⇒ 有固定"药丸"形状，一眼与普通文字区分；
///  - 外面套 `FittedBox(scaleDown)`：窄屏节次栏只有 34px 宽，系统字号拉到
///    1.3 倍时这颗药丸会缩而不是溢出；
///  - 完整 A/B 两组对照表放在 tooltip 里，不在课表上堆字。
class SchedulePeakBadge extends StatelessWidget {
  const SchedulePeakBadge({super.key, required this.fontSize});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).colorScheme.brightness;
    return Tooltip(
      message: SchedulePeakStyle.badgeTooltip(),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
          decoration: BoxDecoration(
            color: SchedulePeakStyle.badgeBackground(brightness),
            borderRadius: BorderRadius.circular(SchedulePeakStyle.badgeRadius),
          ),
          child: Text(
            SchedulePeakStyle.label,
            textAlign: TextAlign.center,
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              fontSize: fontSize,
              height: 1.1,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
              color: SchedulePeakStyle.badgeForeground(brightness),
            ),
          ),
        ),
      ),
    );
  }
}
