// 课表页职责：**一个课程块**的渲染（含点击弹详情）。
//
// 为什么从 part 的 `_buildCourseEntry` 里搬出来成公开 widget：
//  - 课块是本次改造的视觉主体（彩色底、错峰提示、一屏压缩的字号档位都落在
//    这里），而 part 文件的私有方法**单元测试摸不到**，只能靠 pump 整个
//    `SchedulePage`（它初始化要读 `%APPDATA%` 的真实缓存，测试里不可控）。
//    搬成公开 widget 后，"点击课块 → 弹详情"这条链路可以用真组件测到；
//  - 渲染纪律不变：整表无边框，一个元素只有一个视觉信号，高亮只作用在
//    课块底色上。搬动只是把代码搬家 + 加了一层 InkWell。
import 'package:flutter/material.dart';

import '../app_settings.dart';
import '../ui_constants.dart';
import 'schedule_cell_layout.dart';
import 'schedule_course_colors.dart';
import 'schedule_course_detail.dart';
import 'schedule_fit_layout.dart';
import 'schedule_peak_style.dart';

/// 一个课程块的渲染。
///
/// 配色（是否彩色、是否本周高亮）、几何（铺满/圆角）、字号档位（系统字号 +
/// 一屏压缩档）全部在这里落地；决策本身来自各自的公开库：
/// [ScheduleCourseColors]、[ScheduleCellLayout]、[ScheduleFitLayout]、
/// [SchedulePeakStyle]。
class ScheduleCourseBlock extends StatelessWidget {
  const ScheduleCourseBlock({
    super.key,
    required this.course,
    this.isNarrow = false,
    this.highlighted = false,
    this.settings,
    this.density,
  });

  /// 课表数据里的一门课（`day`/`time`/`name`/`teacher`/`room`/`weeks`）。
  final Map<String, String> course;

  /// 窄屏（手机）：用一套更小的基准字号。
  final bool isNarrow;

  /// 本块是否属于"本周"（由它所在冲突簇的 `highlighted` 决定）。
  final bool highlighted;

  /// 课表设置；为 null 时用 [AppSettings] 的默认值（等价于"全部默认"）。
  final AppSettings? settings;

  /// 一屏压缩的行内预算（`ScheduleFitLayout.plan` 的产物）。
  /// null = 不压缩，保持改造前的"按内容自然高度"。
  final ScheduleFitPlan? density;

  @override
  Widget build(BuildContext context) {
    final s = settings ?? AppSettings();
    final name = (course['name'] ?? '').trim();
    final teacher = (course['teacher'] ?? '').trim();
    final room = (course['room'] ?? '').trim();
    final pure =
        MediaQuery.sizeOf(context).shortestSide < 600 &&
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final colorScheme = Theme.of(context).colorScheme;
    final plan = (density?.compressed ?? false) ? density : null;

    // 定高行的两条铁律：所有文字单行（否则 RenderFlex overflow），
    // 次要行按预算取舍。pure（窄屏横屏）本来就只有单行，口径一致。
    final singleLine = pure || plan != null;
    final nameMaxLines = plan?.nameMaxLines ?? 1;
    // 压缩态（一屏显示、竖屏）：**纵向折行 + 整体等比缩小**，不再用"单行+省略号"。
    // 实测 7 天并列时一块只有约 32~37 逻辑像素宽，课名一行只放得下 3 个汉字，
    // 单行省略号必然把「逸夫楼907」「中学学科课程标准与教材研究」砍掉
    // （作者 2026-11-02："还会存在显示不完全的问题"）。
    // pure（窄屏横屏）保持原口径：那一行本来就只有一行的高度。
    final wrapCompact = plan != null && !pure;

    final fillSetting = s.courseCellFill;
    final courseFill = ScheduleCourseColors.fill(
      enabled: s.courseColorEnabled,
      highlighted: highlighted,
      scheme: colorScheme,
      courseName: name,
    );
    final nameInk = ScheduleCourseColors.nameInk(
      enabled: s.courseColorEnabled,
      highlighted: highlighted,
      scheme: colorScheme,
      courseName: name,
    );
    final courseSubText = ScheduleCourseColors.subInk(
      enabled: s.courseColorEnabled,
      highlighted: highlighted,
      scheme: colorScheme,
      courseName: name,
    );

    final textScale = plan?.textScale ?? 1.0;
    final textDelta = (s.scheduleTextSize - 1).toDouble();
    final nameSize =
        ((isNarrow ? AppDimens.courseNameNarrow : AppDimens.courseNameWide) +
            textDelta) *
        textScale;
    final subSize =
        ((isNarrow ? AppDimens.courseSubNarrow : AppDimens.courseSubWide) +
            textDelta) *
        textScale;

    // 错峰提示行：只有"所属组 ≠ 基准组 B 组"的课会拿到内容。
    // 压缩态下还要看行内预算（[ScheduleFitPlan.showPeakHint]）。
    final peakHint = singleLine && plan == null
        ? null
        : (plan?.showPeakHint ?? true)
        ? SchedulePeakStyle.courseHint(
            enabled: s.peakShiftEnabled,
            time: course['time'] ?? '',
            room: course['room'],
            compact: plan != null,
          )
        : null;
    final showTeacher = teacher.isNotEmpty && (plan?.showTeacher ?? true);
    final showRoom = room.isNotEmpty && (plan?.showRoom ?? true);

    final radius = ScheduleCellLayout.blockRadius(fillSetting);
    final blockMargin = ScheduleCellLayout.blockMargin(fillSetting);
    // 压缩态：让每个课块**填满本行高度**。这样同一大节内所有块的上下
    // 边缘都对齐，整张表是一道道整齐的色带，而不是"内容撑多高就多高"
    // 的碎块（作者 2026-11-01 的"不美观"就是这个）。
    final rowHeight = plan?.rowHeight;
    final blockHeight = rowHeight == null
        ? null
        : (rowHeight - (blockMargin?.bottom ?? 0) - 1)
              .clamp(20.0, rowHeight)
              .toDouble();
    return Container(
      margin: blockMargin,
      height: blockHeight,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: radius,
          // 点课块 → 课程详情。涟漪即可，**不改**底色与形状：
          // 底色仍然只有"本周高亮"一个信号（见文件头的渲染纪律）。
          onTap: () => ScheduleCourseDetailDialog.show(
            context,
            course: course,
            settings: s,
          ),
          child: Ink(
            padding: ScheduleCellLayout.textPaddingFor(pure: pure),
            decoration: BoxDecoration(color: courseFill, borderRadius: radius),
            child: _compactText(
              wrap: wrapCompact,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                // 纵向对齐分两种：
                //  - wrapCompact（压缩态竖屏）：文字按真实宽度折行后，整块的
                //    垂直位置交给外层 FittedBox 居中，这里从顶部顺排即可；
                //  - 其余压缩场景（pure）：spaceEvenly 把多余高度均分到行间，
                //    避免 center 造成的"上下空很多、中间挤一坨"。
                mainAxisAlignment: wrapCompact
                    ? MainAxisAlignment.start
                    : (plan != null
                          ? MainAxisAlignment.spaceEvenly
                          : MainAxisAlignment.center),
                children: [
                  Text(
                    name.isNotEmpty ? name : '(未知课程)',
                    softWrap: wrapCompact ? true : !singleLine,
                    maxLines: wrapCompact
                        ? 8
                        : (singleLine ? nameMaxLines : null),
                    overflow: (wrapCompact || singleLine)
                        ? TextOverflow.ellipsis
                        : null,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: nameSize,
                      height: 1.25,
                      color: name.isNotEmpty ? nameInk : courseSubText,
                    ),
                  ),
                  if (showTeacher)
                    Padding(
                      padding: EdgeInsets.only(
                        top: (pure || plan != null) ? 1 : 2,
                      ),
                      child: Text(
                        '@$teacher',
                        softWrap: wrapCompact ? true : !singleLine,
                        maxLines: wrapCompact ? 4 : (singleLine ? 1 : null),
                        overflow: (wrapCompact || singleLine)
                            ? TextOverflow.ellipsis
                            : null,
                        style: TextStyle(
                          fontSize: subSize,
                          height: 1.2,
                          color: courseSubText,
                        ),
                      ),
                    ),
                  if (showRoom)
                    Padding(
                      padding: EdgeInsets.only(
                        top: (pure || plan != null) ? 1 : 2,
                      ),
                      child: Text(
                        room,
                        softWrap: wrapCompact ? true : !singleLine,
                        maxLines: wrapCompact ? 4 : (singleLine ? 1 : null),
                        overflow: (wrapCompact || singleLine)
                            ? TextOverflow.ellipsis
                            : null,
                        style: TextStyle(
                          fontSize: subSize,
                          height: 1.2,
                          color: courseSubText,
                        ),
                      ),
                    ),
                  if (peakHint != null)
                    _buildPeakHintLine(
                      peakHint: peakHint,
                      accent: SchedulePeakStyle.accentFor(courseFill),
                      subSize: subSize,
                      singleLine: singleLine,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 压缩态的文字容器：先按真实宽度折行，整块超高时等比缩小。
  ///
  /// ⚠️ FittedBox 会用**无界**约束布局子树，所以里面必须用 ConstrainedBox
  /// 把宽度钉回块宽；否则 Text 拿到无限宽就不会折行，最后整块被缩成
  /// 一条横向小字（比省略号还难读）。
  Widget _compactText({required bool wrap, required Widget child}) {
    if (!wrap) return child;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        if (!w.isFinite || w <= 0) return child;
        return FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.center,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: w, maxWidth: w),
            child: child,
          ),
        );
      },
    );
  }

  /// 课块内的错峰提示行。
  ///
  /// 改造点（作者原话："看不出这是错峰时间"）：
  ///  - 与教师/教室副文字**不同色**：用 [SchedulePeakStyle.accentFor] 按底色
  ///    明暗选的强调色（浅底深赭 / 深底浅琥珀），实测对比度 ≥5.3:1；
  ///  - **不同字重**：「错峰」两个字 w800，时刻 w600（副文字是默认 w400）；
  ///  - 一层 **12% 的强调色底纹**（不是边框，本仓课块刻意无边框）把这一行
  ///    从"三行灰字里的第三行"里拎出来，一眼能看出"这几行时刻是错峰的"。
  Widget _buildPeakHintLine({
    required SchedulePeakHint peakHint,
    required Color accent,
    required double subSize,
    required bool singleLine,
  }) {
    final Widget rich = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: peakHint.label,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
            ),
          ),
          TextSpan(
            text: ' ${peakHint.body}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
      softWrap: !singleLine,
      maxLines: singleLine ? 1 : null,
      overflow: singleLine ? TextOverflow.ellipsis : null,
      style: TextStyle(fontSize: subSize, height: 1.2, color: accent),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
        decoration: BoxDecoration(
          color: accent.withAlpha(30),
          borderRadius: BorderRadius.circular(5),
        ),
        // 压缩态（一屏显示）下课块很窄，用 FittedBox 等比缩排兜底：
        // 宁可字略小一点，也不要出现 "错峰 10:2…" 这种被截断的半截时刻。
        child: singleLine
            ? FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: rich,
              )
            : rich,
      ),
    );
  }
}
