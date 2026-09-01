// 全局设计常量：把散落在各处的字号、间距、高度集中到一处，方便统一调整。
// 命名约定：按「区域 + 用途」命名，窄屏(手机) 与 宽屏(电脑/平板) 分两档。
abstract final class AppDimens {
  // ---- 课表表头字号 ----
  static const double scheduleHeaderNarrow = 12;
  static const double scheduleHeaderWide = 16;

  // ---- 课程名 / 教师 / 地点 基础字号（实际 = 基础 + 用户「课表文字大小」增量）----
  static const double courseNameNarrow = 10;
  static const double courseNameWide = 15;
  static const double courseSubNarrow = 8;
  static const double courseSubWide = 13;

  // ---- 节次列字号 ----
  static const double timeCellMainNarrow = 12;
  static const double timeCellMainWide = 15;
  static const double timeCellSubNarrow = 10;
  static const double timeCellSubWide = 13;

  // ---- 课表格高度 ----
  static const double scheduleCellMinHeight = 72;

  // ---- 课表操作菜单 ----
  static const double toolsTitleFont = 12.5;
  static const double toolsLabelFont = 12;
  static const double toolsButtonMinHeight = 32;

  // ---- 学期进度条 ----
  static const int progressBarWeeks = 15;
  static const double progressBarHeight = 5;
}
