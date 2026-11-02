// 课表页职责：课块底色的"取色决策"。
//
// 单独成库（而不是写成 part 里的私有 getter）的理由与 `schedule_cell_layout.dart`
// 完全相同：part 文件的私有成员**单元测试摸不到**，而"关闭开关时必须与旧实现
// 逐字节一致"这种要求，只有让渲染层与测试共用同一份实现才验证得了
// （复刻一份数字进测试里，改坏了也照样是绿灯）。
import 'package:flutter/material.dart';

import '../theme.dart';

/// 课块配色入口。两种模式：
///  - `courseColorEnabled == false`（默认）：**保持历史外观**，本周块用
///    `primaryContainer`、普通块用 `surfaceContainerHighest`；
///  - `courseColorEnabled == true`：交给 [CourseColors] 按课程名散列取色。
class ScheduleCourseColors {
  ScheduleCourseColors._();

  /// 课块填充色。
  static Color fill({
    required bool enabled,
    required bool highlighted,
    required ColorScheme scheme,
    required String courseName,
  }) {
    if (!enabled) {
      return highlighted
          ? scheme.primaryContainer
          : scheme.surfaceContainerHighest;
    }
    return CourseColors.fillFor(
      courseName: courseName,
      brightness: scheme.brightness,
      highlighted: highlighted,
    );
  }

  /// 课名文字色。关闭彩色时沿用历史实现：`onSurface`（课名永远够黑/够亮）。
  static Color nameInk({
    required bool enabled,
    required bool highlighted,
    required ColorScheme scheme,
    required String courseName,
  }) {
    if (!enabled) return scheme.onSurface;
    return CourseColors.inkFor(
      courseName: courseName,
      brightness: scheme.brightness,
      highlighted: highlighted,
    );
  }

  /// 次要文字（教师 / 教室 / `(未知课程)` 占位）的颜色。
  ///
  /// 关闭彩色时逐字保留历史实现（含那段对比度推导）：
  ///   浅色：两种底上都只有 `onPrimaryContainer`(#5A5348) 够 —
  ///         creamDark 6.7:1 / beige 5.8:1；
  ///   深色：中性底用 `onSurfaceVariant`(#B8A98F) 6.6:1，
  ///         暖底(#5C4D2A)上只剩 3.6:1，必须换 `onPrimaryContainer` 6.8:1。
  /// 开启彩色时直接用色板的配套墨色（paleInks / deepInk 都是实测 ≥6.7:1）。
  static Color subInk({
    required bool enabled,
    required bool highlighted,
    required ColorScheme scheme,
    required String courseName,
  }) {
    if (!enabled) {
      final isDark = scheme.brightness == Brightness.dark;
      return (!isDark || highlighted)
          ? scheme.onPrimaryContainer
          : scheme.onSurfaceVariant;
    }
    return CourseColors.inkFor(
      courseName: courseName,
      brightness: scheme.brightness,
      highlighted: highlighted,
    );
  }
}
