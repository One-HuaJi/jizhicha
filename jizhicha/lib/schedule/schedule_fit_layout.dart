// 课表页职责：「一屏显示」的行高规划（纯计算，无 BuildContext、无 IO）。
//
// 为什么是独立库而不是 part 里的私有方法：这是本轮唯一需要"数学正确"的决策
// （把 N 行压进 H 像素、字号降到哪一档、压缩后还剩几行副文字），作者又要求
// "第一~第五大节完全显示、不用手动上下滑"。把它做成纯函数，`test/` 里就能
// **直接**验算（而不是 pump 一个真实课表页去目测），也避免渲染层与测试各写
// 一套数字（§9.19.5 的既定范式）。
import '../ui_constants.dart';
import 'schedule_peak_style.dart';

/// 一次"一屏显示"规划的产物：行高 + 字号档位 + 各行还能留哪些文字。
class ScheduleFitPlan {
  /// 是否真的启用了等高压缩（false ⇒ 按内容自然高度、仍可上下滑）。
  final bool compressed;

  /// 每一行（表头也算一行）的等高像素；[compressed] 为假时是 null。
  final double? rowHeight;

  /// 字号缩放档位（1.0 = 正常；越挤越小，见 [ScheduleFitLayout.textScaleTiers]）。
  final double textScale;

  /// 压缩后是否真的一屏放得下。
  ///
  /// false 只有一种情况：行高被压到 [ScheduleFitLayout.minRowHeight] 下限仍排不下
  /// （课表行数太多）。此时刻意**不**继续压缩（再压就看不清了），保留上下滑。
  final bool fits;

  /// 课名允许的最大行数（1 或 2）。压缩态下必须定行数，否则内容一多就把
  /// 等高行撑破（RenderFlex overflow）。
  final int nameMaxLines;

  /// 教师 / 教室 / 课块内错峰提示是否还有预算显示。
  final bool showTeacher;
  final bool showRoom;
  final bool showPeakHint;

  /// 节次栏的小节时刻 / 「错峰」徽标是否还有预算显示。
  final bool showTimeSub;
  final bool showPeakBadge;

  const ScheduleFitPlan({
    required this.compressed,
    required this.rowHeight,
    required this.textScale,
    required this.fits,
    required this.nameMaxLines,
    required this.showTeacher,
    required this.showRoom,
    required this.showPeakHint,
    required this.showTimeSub,
    required this.showPeakBadge,
  });

  /// 不压缩（开关关闭 / 无数据）：与改造前的行为逐项一致——
  /// 按内容自然高度、字号 1.0、所有文字都显示、由纵向滚动兜底。
  static const disabled = ScheduleFitPlan(
    compressed: false,
    rowHeight: null,
    textScale: 1,
    fits: false,
    nameMaxLines: 2,
    showTeacher: true,
    showRoom: true,
    showPeakHint: true,
    showTimeSub: true,
    showPeakBadge: true,
  );
}

/// 「一屏显示」的行高规划器。
///
/// 口径（作者选定）：**不补空大节**，行数由数据决定（`orderedTimes.length + 1`
/// 行表头），把这一堆行按可用高度等分，字号随行高降档，行内放不下的次要文字
/// 按优先级丢掉——而不是让用户去上下滑。
class ScheduleFitLayout {
  ScheduleFitLayout._();

  /// 行高下限：低于这个值，课名与节次已经挤成一团，宁可让用户滑。
  static const double minRowHeight = 34;

  /// 压缩态下表头的固定高度（不含系统字号放大）。
  ///
  /// 表头只放"节 / 一 / 10-26"三行小字，占满一整个数据行的高是纯浪费 ——
  /// 实测手机上表头会吃掉约 110 逻辑像素。所以表头单独定额，
  /// 剩余高度**只按数据行**等分。
  static const double headerRowHeight = 44;

  /// 行高上限：只有两三行数据时不要把课块拉成巨无霸。
  ///
  /// 2026-11-01 从 110 抬到 200：手机上五个大节的表**原本被这个上限卡住**，
  /// 行高最多 110，五个大节加表头只吃掉约 594 逻辑像素，而可用高度约 687
  /// —— 屏幕下方白白空出一条。作者反馈"课程上下空间利用率很低"就是这个。
  /// 抬到 200 后五行的表刚好铺满一屏，两三行的表仍受上限保护。
  static const double maxRowHeight = 200;

  /// 表格内横线的粗细（`schedule_table.dart` 里 horizontalInside 的值）。
  /// 每两行之间有一条，规划行高时必须把它算进去，否则总高多出
  /// `(行数-1)*0.6`，一屏会露出半行、仍在可滑状态。
  static const double separatorThickness = 0.6;

  /// 字号档位表（行高阈值 → 缩放系数），从宽到紧。
  ///
  /// 只降不改布局：同一档内所有字号同乘一个系数，保证"整体缩一号"的观感，
  /// 不会出现课名比副文字还小的怪相。
  /// ⚠️ 不要给这张表加 **大于 1.0** 的档位（2026-11-02 试过又撤回）：
  /// 行高 110 时给到 1.07，字号是大了，但行内预算随之收紧，
  /// 课名从两行掉成一行 —— 「生物分离技术」被截成「生物分…」。
  /// 空间填充应该靠**内容**（多显示一行信息），不能靠放大字号去挤掉课名。
  static const List<(double, double)> textScaleTiers = [
    (64, 1.0),
    (52, 0.94),
    (42, 0.86),
    (34, 0.8),
  ];

  /// 直接给一屏放不下时用的兜底档位（与 [minRowHeight] 对齐）。
  static const double tightestTextScale = 0.8;

  static double _textScaleFor(double rowHeight) {
    for (final (threshold, scale) in textScaleTiers) {
      if (rowHeight >= threshold) return scale;
    }
    return tightestTextScale;
  }

  /// 规划一屏显示。
  ///
  /// - [availableHeight]：表格可用高度（已扣掉外层内边距，见调用方）；
  /// - [dataRows]：数据行数（= `orderedTimes.length`），[headerRows] 默认 1 行表头；
  /// - [narrow]：窄屏（用一套更小的基准字号，规划随之变小）；
  /// - [outerTextScale]：系统字号放大系数（课表区域被钳到 ≤1.3），
  ///   必须参与预算，否则大字号用户会被撑出 overflow；
  /// - [blockPaddingVertical]：[ScheduleCellLayout.textPaddingFor] 的上下内边距合计；
  /// - [blockBottomMargin]：`ScheduleCellFill.rounded` 下的块下边距（filled 为 0）。
  static ScheduleFitPlan plan({
    required bool enabled,
    required double availableHeight,
    required int dataRows,
    required bool narrow,
    int headerRows = 1,
    double outerTextScale = 1.0,
    double blockPaddingVertical = 12,
    double blockBottomMargin = 2,
  }) {
    if (!enabled || dataRows <= 0 || availableHeight <= 0) {
      return ScheduleFitPlan.disabled;
    }
    final scale = outerTextScale <= 0 ? 1.0 : outerTextScale;
    final rows = dataRows + (headerRows > 0 ? headerRows : 0);
    if (rows <= 0) return ScheduleFitPlan.disabled;

    // 行与行之间有 (rows-1) 条 0.6px 横线，先扣掉再等分。
    // 表头定额（见 [headerRowHeight]），剩下的高度只分给数据行。
    final headerCount = rows - dataRows;
    final headerHeight = headerCount > 0 ? headerRowHeight * scale : 0.0;
    final usable = availableHeight -
        headerHeight -
        separatorThickness * (rows - 1);
    final raw = usable / dataRows;
    // 真能放下 = 等分出来的行高还在可读范围内。压到下限仍排不下时，
    // 说明这张表本身就放不进一屏（行数太多），老老实实保留上下滑。
    final fits = raw >= minRowHeight;
    final rowHeight = raw.clamp(minRowHeight, maxRowHeight).toDouble();
    final textScale = _textScaleFor(rowHeight);

    // ---- 行内预算：课块（课名 + 至多 3 行副文字）----
    final nameSize = (narrow
            ? AppDimens.courseNameNarrow
            : AppDimens.courseNameWide) *
        textScale *
        scale;
    final subSize = (narrow ? AppDimens.courseSubNarrow : AppDimens.courseSubWide) *
        textScale *
        scale;
    const nameHeightFactor = 1.25; // 与课名 TextStyle.height 一致
    const subHeightFactor = 1.2; // 与副文字 TextStyle.height 一致
    const lineGap = 2.0; // 每条副文字上方的 Padding(top: 2)
    final nameLine = nameSize * nameHeightFactor;
    final subLine = subSize * subHeightFactor;
    final inner = rowHeight - blockPaddingVertical - blockBottomMargin;

    // 课名：只有在"折两行之后仍放得下至少一行副文字"时才允许折，
    // 否则压缩态里优先保证课名完整性（单行 + 省略号）。
    final nameMaxLines = inner >= nameLine * 2 + subLine + lineGap ? 2 : 1;
    var rest = inner - nameLine * nameMaxLines;
    var slots = 0;
    while (slots < 3 && rest >= subLine + lineGap - 0.01) {
      rest -= subLine + lineGap;
      slots++;
    }
    // 副文字优先级是**显式**的（不靠字面顺序）：错峰提示 > 教师 > 教室。
    // 错峰提示排在教师前面，是因为它承载"这节课到底几点上下课"这个硬信息，
    // 而教师/教室在同一门课的所有周次里都是常量，紧的时候先让位。
    final showPeakHint = slots >= 1;
    final showTeacher = slots >= 2;
    final showRoom = slots >= 3;

    // ---- 行内预算：节次栏（大节名 + 小节时刻 + 错峰徽标）----
    final mainSize = (narrow
            ? AppDimens.timeCellMainNarrow
            : AppDimens.timeCellMainWide) *
        textScale *
        scale;
    final timeSubSize = (narrow
            ? AppDimens.timeCellSubNarrow
            : AppDimens.timeCellSubWide) *
        textScale *
        scale;
    final mainLine = mainSize * 1.25;
    final timeSubLine = timeSubSize * 1.25;
    final badgeHeight = SchedulePeakStyle.badgeHeight(fontSize: timeSubSize);
    // 小节时刻是**两行**（`formatSublessonLines` 每个小节一行，一个大节固定
    // 两个小节），预算必须按两行算，否则压缩态下节次栏会把行撑破。
    final timeSubBlock = timeSubLine * 2;
    final showTimeSub = rowHeight >= mainLine + timeSubBlock + 2;
    // 徽标与时刻行同时显示要额外的 4px 间距；只放得下一个时，留时刻行
    // （时刻本身已经说明了这行是错峰时间），避免"只剩一个孤立标签"。
    final showPeakBadge = showTimeSub
        ? rowHeight >= mainLine + timeSubBlock + badgeHeight + 4
        : rowHeight >= mainLine + badgeHeight + 2;

    return ScheduleFitPlan(
      compressed: true,
      rowHeight: rowHeight,
      textScale: textScale,
      fits: fits,
      nameMaxLines: nameMaxLines,
      showTeacher: showTeacher,
      showRoom: showRoom,
      showPeakHint: showPeakHint,
      showTimeSub: showTimeSub,
      showPeakBadge: showPeakBadge,
    );
  }
}
