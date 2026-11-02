// 「课程格子底色形状」的几何决策：cell 内边距 / 块圆角 / 文字内边距。
//
// 单独成文件（而不是塞在 schedule_table.dart 里）的理由：
// `schedule_table.dart` 是 `schedule_page.dart` 的 part 文件，外部库拿不到它的
// 任何私有成员；而「铺满」与「圆角」的差异**只由这三个值决定**，它们必须能被
// 回归测试直接断言到**真代码**上 —— 否则测试就只能复刻一份数字，真代码被改回
// 旧行为时用例依然全绿（假绿灯）。一个决策点、一处实现、一份测试。
import 'package:flutter/painting.dart';

import '../schedule_time.dart';

/// [ScheduleCellFill] 的落地几何。
///
/// 只负责**底色**的形状，不碰配色、不碰布局、不碰表格分隔线：
/// - [ScheduleCellFill.rounded]：沿用历史外观（cell 内缩 2~6px、块底色 8px 圆角）；
/// - [ScheduleCellFill.filled]：cell 内边距与块圆角都归零 ⇒ 底色铺满整格，
///   但**课块内部文字的内边距保持原样**（作者要的是"底色铺满"，不是"文字贴边"）。
class ScheduleCellLayout {
  const ScheduleCellLayout._();

  /// 单元格内边距：`filled` 时归零，让课块／冲突块的底色直接顶到格子边界。
  ///
  /// ⚠️ pure 模式 `cellHeight` 的补偿值 `(maxHeight - 2) / numRows` 本就是为
  /// 这里的 `all(2)` 留的 —— 内边距归零只会让内容**更宽松**（纵向可用高度由
  /// `height: cellHeight` 的紧约束决定，不受 padding 影响），不会因此溢出。
  /// 这一条由 `test/schedule_cell_fill_test.dart` 的 widget 层用例实测证明。
  static EdgeInsets cellPadding(ScheduleCellFill fill, double? cellHeight) =>
      fill == ScheduleCellFill.filled
      ? EdgeInsets.zero
      : EdgeInsets.all(cellHeight == null ? 6 : 2);

  /// 格子内块状元素（课程块／冲突块）的圆角。
  ///
  /// `filled` 时返回 null（不设 borderRadius ⇒ 方角铺满）；`rounded` 时是历史值
  /// （课程块与冲突块的底色都统一为 8，冲突块的 InkWell 用 9 以配合水波纹点击区）。
  static BorderRadius? blockRadius(
    ScheduleCellFill fill, {
    double radius = 8,
  }) => fill == ScheduleCellFill.filled ? null : BorderRadius.circular(radius);

  /// 课块与相邻格子之间的外边距：`filled` 时归零，否则保留历史的下边 2px。
  ///
  /// 返回 null 表示"不设 margin"（而不是 `EdgeInsets.zero`），这样 `filled` 下
  /// 课块不会因为多包一层 `Padding` 而改变布局层级。
  static EdgeInsets? blockMargin(ScheduleCellFill fill) =>
      fill == ScheduleCellFill.filled ? null : const EdgeInsets.only(bottom: 2);

  /// 课块**内部文字**的内边距：横向固定，纵向在 pure（窄屏横屏）下压到 3。
  ///
  /// ⚠️ 刻意与底色形状设置**无关**：形状只决定"底色铺不铺满"，文字那圈呼吸位
  /// 两种模式下完全一样。
  static EdgeInsets textPaddingFor({required bool pure}) =>
      pure ? textPaddingPure : textPaddingNormal;

  // 2026-11-02 横向由 7/6 收紧到 5/5：7 天并列时课块文字区只有约 32
  // 逻辑像素宽，这 4px 换来约 +12% 的每行字数（课名 3.2 -> 3.6 字/行）。
  // 纵向不变，"文字不贴边"的呼吸位仍然保留。
  static const EdgeInsets textPaddingNormal = EdgeInsets.fromLTRB(5, 6, 5, 6);
  static const EdgeInsets textPaddingPure = EdgeInsets.fromLTRB(7, 3, 6, 3);
}
