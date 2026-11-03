// 课表页职责：课表表格/课程块渲染，以及单元格与整表派生数据类。
part of 'schedule_page.dart';

mixin _ScheduleTableSection on _SchedulePageDataSection {
  /// 本次 build 算出来的"一屏显示"行内预算；null = 不压缩（按内容自然高度）。
  ///
  /// 只存在于单帧渲染期间：`_buildScheduleTable` 先算好，`_buildTimeCell` /
  /// `_buildCourseEntry` 在同一个 build 里读它。刻意**不进** `_scheduleLayout()`
  /// 的缓存键——它由设置与可用高度现算，缓存了反而会拿到上一帧的高度。
  ScheduleFitPlan? _rowPlan;

  // ==================== 课表表格 ====================

  /// 把课表渲染成 8 列表格：节次(行) × 周一~周日(列)。
  /// 同一格内若有多个课程（如同一时间多门课），会纵向堆叠。
  Widget _buildScheduleTable() {
    const dayOrder = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

    // 派生布局（筛选 / 节次去重 / 冲突聚类 / 本周高亮）走缓存，见 _scheduleLayout()。
    final layout = _scheduleLayout();
    final orderedTimes = layout.orderedTimes;
    if (orderedTimes.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _s.filterByWeek ? '第${_s.currentWeek}周暂无课程安排' : '暂无课程数据',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 14,
            ),
          ),
        ),
      );
    }

    // 渲染：宽屏宽列；窄屏缩列让周一~周五可见，周六日横向滑动
    final widthCtx = context;
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = constraints.maxWidth;
        final isNarrow = MediaQuery.sizeOf(context).shortestSide < 600;
        final pure =
            isNarrow &&
            MediaQuery.orientationOf(context) == Orientation.landscape;

        // 列宽：按实际可用宽度均分，让 7 天始终撑满（横屏也撑满，不再靠左）。
        // 手机竖屏且关闭七天时才只显示 5 天（周六日横向滑动）。
        const timeWidth = 34.0;
        final showWeekend = _s.showWeekend;
        final visibleDays = (isNarrow && !showWeekend && !pure) ? 5 : 7;
        final timeCol = isNarrow ? timeWidth : 96.0;
        final dayWidth = ((screenWidth - timeCol - 8) / visibleDays).clamp(
          isNarrow ? (visibleDays == 7 ? 40.0 : 48.0) : 70.0,
          500.0,
        );
        final tPad = isNarrow ? 4.0 : 8.0;
        final baseHeaderSize = isNarrow
            ? AppDimens.scheduleHeaderNarrow
            : AppDimens.scheduleHeaderWide;
        final startDate = DateTime.tryParse(_s.semesterStartDate);
        final weekOffsetDays = (_s.currentWeek - 1) * 7;
        // 「一屏显示」：把**实际行数**（数据行 + 1 行表头，不补空大节）按可用
        // 高度等分压缩，字号随行高降档。决策与验算都在 ScheduleFitLayout(
        // 纯函数，单测直接调)。开关关闭 ⇒ compressed=false，回到改造前的
        // "按内容自然高度 + 纵向滚动"。
        final plan = ScheduleFitLayout.plan(
          enabled: _s.fitToScreenEnabled,
          // 扣掉表格外层 Padding 的上下内边距（pure 下为 0）与 1px 余量，
          // 否则算出来的总高会比可用高度多出一点点，屏幕底部永远露半行。
          availableHeight: constraints.maxHeight - (pure ? 0 : 24) - 1,
          dataRows: orderedTimes.length,
          narrow: isNarrow,
          // 课表区域被 clamp 到 1.3 倍，按实际上限做预算（不是按 1.0）。
          outerTextScale: MediaQuery.textScalerOf(context).scale(1).clamp(1, 1.3),
          blockPaddingVertical: _courseTextPadding.vertical,
          blockBottomMargin:
              ScheduleCellLayout.blockMargin(_s.courseCellFill)?.bottom ?? 0,
        );
        _rowPlan = plan.compressed ? plan : null;
        final cellHeight = plan.rowHeight;
        final fSize = (baseHeaderSize * plan.textScale)
            .clamp(9.0, baseHeaderSize)
            .toDouble();

        // 表头不需要一整行那么高：压缩态给它一个固定矮高度，省下来的
        // 高度全部让给数据行（见 ScheduleFitLayout.headerRowHeight）。
        final headerCellHeight = plan.compressed
            ? ScheduleFitLayout.headerRowHeight * plan.textScale
            : cellHeight;

        final tableRows = <TableRow>[];
        for (var rowIndex = 0; rowIndex < orderedTimes.length; rowIndex++) {
          final time = orderedTimes[rowIndex];
          tableRows.add(
            // 整张表**不画隔行底色**，所有行共用外层卡片的 surface 底色。
            //
            // 留档（这里踩过一次）：原代码写的是
            //   `rowIndex.isEven ? surface : surfaceContainerLowest.withAlpha(100)`
            // 但主题从未定义 `surfaceContainerLowest`，Flutter 的 getter 会兜底成
            // `surface`（color_scheme.dart:1248），所以两行**完全相同** ——
            // 这条"斑马纹"其实一直是死的、没生效。
            // 当时把死代码"救活"（改用已定义的 surfaceContainerLow）是错误判断：
            // 它让一个没人要的错落灰底突然出现，用户反馈"颜色又不一样更混淆了"。
            // 现在直接**删掉装饰**，不留任何可被重新激活的画法：
            // 需要无色可画时，正确的做法是删掉它，而不是替它找一个能生效的颜色。
            TableRow(
              children: [
                _buildTimeCell(time, cellHeight, isNarrow),
                for (final d in dayOrder)
                  _buildDayCell(
                    layout.cells[time]?[d] ?? _ScheduleCellData.empty,
                    isNarrow,
                    cellHeight,
                  ),
              ],
            ),
          );
        }

        return SingleChildScrollView(
          scrollDirection: Axis.vertical,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Padding(
              padding: pure
                  ? EdgeInsets.zero
                  : EdgeInsets.fromLTRB(tPad, 8, tPad, 16),
              child: RepaintBoundary(
                key: _scheduleTableRepaintKey,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(widthCtx).colorScheme.surface,
                    borderRadius: pure ? null : BorderRadius.circular(16),
                    border: pure
                        ? null
                        : Border.all(
                            color: Theme.of(
                              widthCtx,
                            ).colorScheme.outlineVariant.withAlpha(180),
                          ),
                    boxShadow: pure
                        ? null
                        : [
                            BoxShadow(
                              color: Theme.of(
                                widthCtx,
                              ).colorScheme.shadow.withAlpha(18),
                              blurRadius: 16,
                              offset: const Offset(0, 4),
                            ),
                          ],
                  ),
                child: ClipRRect(
                  borderRadius: pure
                      ? BorderRadius.zero
                      : BorderRadius.circular(16),
                  child: Table(
                    defaultColumnWidth: FixedColumnWidth(dayWidth),
                    columnWidths: {0: FixedColumnWidth(timeCol)},
                    // 同一行（同一个大节）的所有单元格统一拉伸到"该行最高内容"
                    // 的高度，这样同一大节内的课程块上下边缘对齐，不再是高矮
                    // 参差的块。
                    // 用 intrinsicHeight 而不是 fill：fill 不参与行高计算
                    // （rendering/table.dart 里直接 break），整行会塌成 0 高。
                    defaultVerticalAlignment:
                        TableCellVerticalAlignment.intrinsicHeight,
                    border: TableBorder(
                      horizontalInside: BorderSide(
                        color: Theme.of(
                          widthCtx,
                        ).colorScheme.outlineVariant.withAlpha(120),
                        width: 0.6,
                      ),
                      verticalInside: BorderSide(
                        color: Theme.of(
                          widthCtx,
                        ).colorScheme.outlineVariant.withAlpha(100),
                        width: 0.6,
                      ),
                    ),
                    children: [
                      TableRow(
                        decoration: BoxDecoration(
                          color: Theme.of(
                            widthCtx,
                          ).colorScheme.surfaceContainerHighest.withAlpha(180),
                        ),
                        children: [
                          _buildHeaderCell(
                            '节',
                            fontSize: fSize,
                            cellHeight: headerCellHeight,
                          ),
                          for (var i = 0; i < dayOrder.length; i++)
                            _buildHeaderCell(
                              isNarrow ? dayOrder[i][1] : dayOrder[i],
                              fontSize: fSize,
                              sub: _dayDateLabel(
                                startDate,
                                weekOffsetDays + i,
                              ),
                              cellHeight: headerCellHeight,
                            ),
                        ],
                      ),
                      ...tableRows,
                    ],
                  ),
                ),
              ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeaderCell(
    String text, {
    double fontSize = 13,
    String? sub,
    double? cellHeight,
  }) {
    return Container(
      height: cellHeight,
      padding: EdgeInsets.symmetric(
        vertical: cellHeight == null ? 8 : 0,
        horizontal: 4,
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            text,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: fontSize,
              letterSpacing: 0.2,
            ),
          ),
          if (sub != null)
            Text(
              sub,
              style: TextStyle(
                fontSize: fontSize - 2,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  String? _dayDateLabel(DateTime? startDate, int offsetDays) {
    if (startDate == null) return null;
    final d = startDate.add(Duration(days: offsetDays));
    return '${d.month}/${d.day}';
  }

  Widget _buildTimeCell(String time, [double? cellHeight, bool isNarrow = false]) {
    // 例 "第一大节 (01,02小节)" / "第一节 (01,02小节)" → 主行 + 小节行
    final match = RegExp(
      r'^(第[一二三四五六七八九十]+(?:大)?节)(?:\s*[（(]([^）)]*)[）)])?',
    ).firstMatch(time);
    final rawMain = match?.group(1) ?? time;
    final legacySub = match?.group(2) ?? '';
    // 错峰开关打开时，节次栏「第二大节」这一格显示**基准组（B 组，早下课）**
    // 的错峰时刻；其余小节照旧走季节表（`peakShift: false` 的那条路径）。
    // 判据由 SchedulePeakStyle 提供（渲染与单测共用同一份）。
    final peakShiftCell = SchedulePeakStyle.badgeVisible(
      enabled: _peakShiftOn,
      time: time,
    );
    final sub = ScheduleTimeTable.formatSublessonLines(
      time,
      _s.scheduleTimeMode,
      includeLabels: false,
      peakShift: peakShiftCell,
    );
    final colorScheme = Theme.of(context).colorScheme;
    // 能显示几行，由「一屏显示」的行内预算决定（_rowPlan）：
    //  - 压缩态：按行高算出来的 showTimeSub / showPeakBadge；
    //  - 非压缩态：回到改造前的口径 —— 有 cellHeight（pure 窄屏横屏）就不显示
    //    副文字，没 cellHeight 才显示。
    final plan = _rowPlan;
    // 压缩态（一屏显示）：节次栏只有约 34px 宽，"第一大节"必然折成两行，
    // 而行内预算（ScheduleFitLayout）只算了 **一行** 大节名 —— 多出来的
    // 那一行就是"五大节挤在一起"的直接原因。压缩态只留序号单字。
    final main = plan == null ? rawMain : _compactPeriodLabel(rawMain);
    final textScale = plan?.textScale ?? 1.0;
    final showSub = plan?.showTimeSub ?? (cellHeight == null);
    final showBadge = plan?.showPeakBadge ?? (cellHeight == null);
    // 压缩态下行高是定死的，而节次列只有约 34px 宽：完整的
    // "08:20–09:05" 这种区间串会被折成三行再被 ellipsis 截成
    // "08:20 - 0…"。所以压缩态只保留「大节起 → 大节止」两行短文本。
    // 非压缩态维持改造前的口径（原样多行），由纵向滚动兜底。
    final rawSub = sub.isNotEmpty ? sub : legacySub;
    // 作者 2026-11-03：节次栏要显示**每个小节自己的**完整区间
    // （`08:20–09:05` 换行 `09:15–10:00`），而不是"大节起→大节止"。
    //
    // 但 34px 的窄列放不下 `08:20–09:05` 这种 11 字符的整行 —— FittedBox 一缩，
    // 字号只剩约 5px，肉眼几乎看不清（作者："字太小了，允许分段"）。
    // 所以这里**允许分段**：把区间的连接号换成换行，每行只放 5 个字符
    // （`08:20` / `09:05`），字号就能保持原尺寸，不再被压缩。
    final displaySub = rawSub
        .replaceAll('–', '\n')
        .replaceAll('—', '\n');
    final mainSize = (isNarrow
            ? AppDimens.timeCellMainNarrow
            : AppDimens.timeCellMainWide) *
        textScale;
    final subSize = (isNarrow
            ? AppDimens.timeCellSubNarrow
            : AppDimens.timeCellSubWide) *
        textScale;
    return Container(
      height: cellHeight,
      padding: EdgeInsets.symmetric(
        vertical: cellHeight == null ? 8 : 0,
        horizontal: 4,
      ),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withAlpha(150),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            main,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: mainSize,
              color: colorScheme.onSurface,
            ),
          ),
          if (showSub && displaySub.isNotEmpty) ...[
            const SizedBox(height: 2),
            // 已经按 5 字符一段分好行，正常字号就能放下；FittedBox 只作为
            // 极端情况（超大系统字号）的兜底，平时不参与缩放。
            // **绝不能用 ellipsis** —— 那会把时刻截成 `08:20 - 0…`（2026-11-01 踩过）。
            SizedBox(
              width: double.infinity,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  displaySub,
                  textAlign: TextAlign.center,
                  maxLines: 8,
                  style: TextStyle(
                    fontSize: subSize,
                    height: 1.22,
                    fontWeight: FontWeight.w500,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
          if (showBadge && peakShiftCell) ...[
            const SizedBox(height: 2),
            SchedulePeakBadge(fontSize: subSize * 0.92),
          ],
        ],
      ),
    );
  }



  /// "第一大节" / "第三节" → "一" / "三"（压缩态节次栏只留序号单字）。
  /// 识别不出来就原样返回，不做猜测。
  String _compactPeriodLabel(String label) {
    final m = RegExp(r'^第([一二三四五六七八九十]+)(?:大)?节$').firstMatch(label);
    return m?.group(1) ?? label;
  }

  /// 渲染一个 (节次, 星期) 单元格。
  /// [data] 里的课程分组、冲突簇、以及**每个簇自己**的本周高亮标志都已在
  /// 布局缓存里算好（见 [_scheduleLayout]），这里不再跑 parseWeekSpans 与并查集。
  Widget _buildDayCell(
    _ScheduleCellData data,
    bool isNarrow,
    double? cellHeight,
  ) {
    final courses = data.courses;
    if (courses.isEmpty) {
      return Container(
        height: cellHeight ?? AppDimens.scheduleCellMinHeight,
        alignment: Alignment.center,
        child: Text(
          '-',
          style: TextStyle(
            color: Theme.of(context).colorScheme.outline,
            fontSize: 15,
          ),
        ),
      );
    }

    // 按"周次是否重叠"把同格课程分组：
    //  - 周次重叠的多门课 → 归为一个"冲突簇"，渲染成可点击的冲突块；
    //  - 周次不重叠（如 1-10 周与 11-12 周）→ 各自单独正常显示。
    final clusters = data.clusters;

    final children = <Widget>[];
    var first = true;
    for (final cluster in clusters) {
      if (!first) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Divider(
              height: 1,
              thickness: 0.5,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        );
      }
      first = false;

      if (cluster.courses.length == 1) {
        // 把"本簇是否本周"传下去：高亮只作用在课块底色上（见 _buildCourseEntry）。
        //
        // 注意这里取的是 **cluster.highlighted**（本簇是否有课在本周），
        // 而不是"整格是否有课在本周"：同一格里周次不重叠的两门课会各成一个
        // 块，整格标志会把两块一起点亮，而只有一个块真的本周要上课。
        children.add(
          _buildCourseEntry(
            cluster.courses.first,
            isNarrow,
            cluster.highlighted,
          ),
        );
      } else {
        // 冲突块：把整个簇传进去，它同样**能拿到自己那一簇的高亮标志**
        // （cluster.highlighted）——具体怎么表现见 _buildConflictCell 的说明。
        children.add(_buildConflictCell(cluster));
      }
    }

    // 格子底色形状：filled（默认）时 cell 内边距归零，让课块底色铺满整格；
    // rounded 时保留历史外观。见 [_cellPadding] 关于 pure 模式补偿的说明。
    return Container(
      padding: _cellPadding(cellHeight),
      height: cellHeight,
      constraints: cellHeight == null
          ? BoxConstraints(minHeight: AppDimens.scheduleCellMinHeight)
          : null,
      // 整格**不再有任何装饰**。
      //
      // 演进过程（用户两次反馈，值得留档）：
      //   ① 最早是"只画左边"的 3px 主色竖条 —— 像括号残片、还占位置；
      //   ② 改成整格填充 primaryContainer + 格内课块描边 —— 两个圆角矩形
      //      嵌套同时发亮，用户反馈"圆框和方框都一起亮，观感很差"；
      //   ③ 改成整格 2px 琥珀色加粗方框 —— 用户反馈"琥珀色加粗太丑，
      //      几个框重叠在一起"（相邻高亮格的边框会紧挨成双线，这是按格画框
      //      无法避免的）。
      // 最终：**格级不画任何东西**，本周高亮完全交给课块自己的底色深浅
      // （见 _buildCourseEntry 的 highlighted）。一个元素一个信号，稳定可控。
      // 顺带：去掉边框后 decoration.padding 不再计入，内容左内缩自然回到 6。
      // 只有一个课程块时，直接把它作为单元格的子节点返回：在 Table 的
      // intrinsicHeight 下单元格拿到的是"紧高度"，块自身的圆角底色
      // 因此能撑满整格，与同一大节的其它块等高。
      // 若仍套一层 Column，子节点只按内容自然高度布局，装饰又会被缩回去。
      // 注意：这里不能用 Expanded/Flexible 撑开——intrinsicHeight 的第一遍
      // 布局高度无界，带 flex 的子节点会直接抛错。
      child: children.length == 1
          ? children.single
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: children,
            ),
    );
  }

  /// 同一节次、周次重叠的多门课——冲突块，点击可查看详情。
  ///
  /// 入参是整个 [_ScheduleCluster]（而不是裸的课程列表），这样冲突块**能拿到
  /// 自己那一簇的本周高亮标志** `cluster.highlighted`，不必回头去查"整格"。
  ///
  /// 关于这个标志怎么表现，这里的取舍是**刻意不做任何本周着色**：
  ///  - 冲突块整块铺 errorContainer，"这里撞课了、得自己挑一门"是它唯一的、
  ///    也是优先级最高的视觉信号；底色的两个色位（primaryContainer /
  ///    surfaceContainerHighest）是课程块专用的既定配色，冲突块一旦占用，
  ///    "冲突"这个更强的信息就消失了；
  ///  - 再叠一层边框或角标，又会破坏本文件反复留档的"一个元素只有一个视觉
  ///    信号"原则（历史上正是"框套框一起发亮"被用户否掉的）。
  /// 另外这也意味着**视觉零回归**：旧实现压根没把高亮传进冲突块
  /// （`_buildConflictCell` 只收一个裸列表，格级标志到不了这里），
  /// 所以冲突块过去不会亮、现在依然不会亮。
  /// 标志仍然挂在簇上、随簇一起传进来：数据模型是完整的，将来若要改表现
  /// （比如给"本周冲突"加角标或调整详情弹窗顺序），不必再回头动聚类逻辑。
  Widget _buildConflictCell(_ScheduleCluster cluster) {
    final courses = cluster.courses;
    final names = courses.map((c) {
      final n = (c['name'] ?? '').trim();
      return n.isNotEmpty ? n : '(未知课程)';
    }).toList();
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: _cellBlockRadius(radius: 9),
        onTap: () => _showConflictDialog(courses),
        child: Container(
          padding: const EdgeInsets.fromLTRB(7, 7, 6, 7),
          decoration: BoxDecoration(
            // 冲突块：只靠整块 error 底色表达"这里冲突了"（可点击查看详情）。
            // 与课程块保持同一套画法：**一个元素只有一个视觉信号**，不再描边
            // —— 描边会和格内其它块、以及整格高亮的方框叠在一起"多重发亮"。
            // 底色用 errorContainer 略微加强，补偿去掉红条后损失的醒目度。
            color: colorScheme.errorContainer.withAlpha(110),
            // 圆角与课程块统一为 8（此前这里是 9，两种块圆角不一致显得毛糙）；
            // 格子底色选"铺满"时一起变方，见 [_cellBlockRadius]。
            borderRadius: _cellBlockRadius(),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final n in names)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '· $n',
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 冲突弹窗：逐条列出每门课的完整安排，由用户自行判断去上哪门。
  void _showConflictDialog(List<Map<String, String>> courses) {
    showDialog(
      context: context,
      builder: (ctx) {
        final colorScheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                color: colorScheme.error,
                size: 20,
              ),
              const SizedBox(width: 8),
              const Text('课程冲突', style: TextStyle(fontSize: 16)),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: courses.length,
              itemBuilder: (ctx2, i) {
                final c = courses[i];
                final name = (c['name'] ?? '').trim();
                final teacher = (c['teacher'] ?? '').trim();
                final room = (c['room'] ?? '').trim();
                final weeks = (c['weeks'] ?? '').trim();
                return Padding(
                  padding: EdgeInsets.only(
                    bottom: i < courses.length - 1 ? 12 : 0,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${i + 1}. ${name.isNotEmpty ? name : '(未知课程)'}',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '时间：${c['day'] ?? ''} ${c['time'] ?? ''}',
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (teacher.isNotEmpty)
                        Text(
                          '教师：$teacher',
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      if (room.isNotEmpty)
                        Text(
                          '地点：$room',
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      if (weeks.isNotEmpty)
                        Text(
                          '周次：$weeks',
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      if (i < courses.length - 1)
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: Divider(),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('知道了'),
            ),
          ],
        );
      },
    );
  }

  /// 课块内部文字的内边距：横向固定，纵向在 pure（窄屏横屏）下压到 3。
  ///
  /// ⚠️ 这个值与「格子底色形状」设置**无关**。作者要的是"底色铺满"，
  /// 不是"文字贴边"——`ScheduleCellFill.filled` 只把 cell padding / 块 margin /
  /// borderRadius 归零，文字仍然留这圈呼吸位。
  EdgeInsets get _courseTextPadding =>
      ScheduleCellLayout.textPaddingFor(pure: _isPureViewport);

  /// 当前是否处于 pure（窄屏 + 横屏）紧凑形态。
  bool get _isPureViewport =>
      MediaQuery.sizeOf(context).shortestSide < 600 &&
      MediaQuery.orientationOf(context) == Orientation.landscape;

  /// 单元格内边距。实现见 [ScheduleCellLayout.cellPadding]（渲染层与单测共用
  /// 同一份决策，避免测试只能复刻数字）。
  EdgeInsets _cellPadding(double? cellHeight) =>
      ScheduleCellLayout.cellPadding(_s.courseCellFill, cellHeight);

  /// 格子内块状元素（课程块／冲突块）的圆角。
  /// 实现见 [ScheduleCellLayout.blockRadius]（`filled` ⇒ null ⇒ 方角铺满）。
  BorderRadius? _cellBlockRadius({double radius = 8}) =>
      ScheduleCellLayout.blockRadius(_s.courseCellFill, radius: radius);

  /// 是否开启错峰上课表（设置页开关）。渲染层统一从这里取。
  bool get _peakShiftOn => _s.peakShiftEnabled;

  /// 渲染一个课程块。
  ///
  /// [highlighted] 表示**这一个课块**属于"本周"（由它所在簇的
  /// [_ScheduleCluster.highlighted] 决定）。它是本块**唯一**的高亮手段：
  /// 只把同一块底色加深，不画任何边框 —— 这样高亮永远只作用在一个元素上，
  /// 不会出现"整格一层 + 课块一层"的双重发亮（用户明确反馈过那种观感很差）。
  ///
  /// 具体绘制搬到公开 widget [ScheduleCourseBlock]（见该文件头部的理由：
  /// part 的私有方法测不到，而"点击课块 → 弹课程详情"必须被 widget 测试点到）。
  /// **参数列表与返回类型保持不变**：本文件其它地方、以及 3 个既有测试文件
  /// 都按 `(course, [isNarrow, highlighted])` 这个形状依赖它。
  Widget _buildCourseEntry(
    Map<String, String> c, [
    bool isNarrow = false,
    bool highlighted = false,
  ]) {
    return ScheduleCourseBlock(
      course: c,
      isNarrow: isNarrow,
      highlighted: highlighted,
      settings: _s,
      // 一屏压缩的行内预算：决定字号档位、课名行数、还要不要显示
      // 教师/教室/错峰提示。null ⇒ 按内容自然高度。
      density: _rowPlan,
    );
  }
}

/// 一个"显示课块"的派生数据：同格内**周次互相重叠**的若干课程（并查集聚成一组）。
///
/// 为什么是"簇对象"而不是「clusters + 平行的 clusterHighlighted 两个列表」：
/// 平行列表靠**下标对齐**维持不变式，编译器完全帮不上忙——将来任何一次过滤、
/// 排序或插入只要漏改其中一个列表，高亮就会整体错位，而且错得非常隐蔽
/// （颜色看着正常，只是亮错了块）。把标志和它描述的那组课程绑在同一个对象上，
/// 二者在类型层面就不可能对不上；渲染侧也只能从簇上取标志，拿不到"整格标志"
/// 这种更容易用错的中间量（旧的 `_ScheduleCellData.inCurrentWeek` 已删除）。
class _ScheduleCluster {
  /// 簇内课程，保持课表数据里的原始顺序，
  /// 与旧实现 `idxs.map((i) => courses[i])` 一致。
  final List<Map<String, String>> courses;

  /// 本簇是否**至少有一门课在本周**（本周视图高亮的判据）。
  ///
  /// 粒度之所以必须下沉到"簇"而不是"整格"：同一个格里可能放着周次**不重叠**
  /// 的两门课（如 1-8 周与 9-16 周），它们会被聚成两个簇、各渲染成一个块。
  /// 按整格算一个标志时，第 3 周会把两块**一起**点亮——可第 9-16 周那门课
  /// 此刻还没开课；反之第 12 周又会把 1-8 周那门课点亮。只有按簇判"本簇内
  /// 有没有课在本周"，才与用户真正关心的"这个块这周要不要来上"一致。
  final bool highlighted;

  const _ScheduleCluster({required this.courses, required this.highlighted});
}

/// 课表某个 (节次, 星期) 单元格的派生数据。
///
/// 内容全部由课程数据派生，缓存后渲染时不再重跑 [parseWeekSpans] 与并查集
/// 冲突聚类（旧实现每门课每次 build 解析两次周次）。
class _ScheduleCellData {
  final List<Map<String, String>> courses;

  /// 按"周次是否重叠"聚好的簇，每个簇自带自己的本周高亮标志。
  final List<_ScheduleCluster> clusters;

  const _ScheduleCellData({required this.courses, required this.clusters});

  /// 单元格无课程时的占位，等价于旧实现的 `?? const []`。
  static const empty = _ScheduleCellData(courses: [], clusters: []);

  /// 计算一个单元格的冲突簇，以及**每个簇各自**的本周高亮。
  /// 每门课的周次只解析一次（旧实现解析两次：高亮一次、聚类一次）。
  factory _ScheduleCellData.compute(
    List<Map<String, String>> courses,
    int? highlightWeek,
  ) {
    final spans = courses.map((c) => parseWeekSpans(c['weeks'] ?? '')).toList();
    final n = courses.length;
    final parent = List.generate(n, (i) => i);
    int find(int x) => parent[x] == x ? x : parent[x] = find(parent[x]);
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        if (spans[i].isEmpty || spans[j].isEmpty) continue;
        if (weekSpansOverlap(spans[i], spans[j])) {
          parent[find(i)] = find(j);
        }
      }
    }
    final grouped = <int, List<int>>{};
    for (var i = 0; i < n; i++) {
      grouped.putIfAbsent(find(i), () => <int>[]).add(i);
    }
    final w = highlightWeek;
    return _ScheduleCellData(
      courses: courses,
      clusters: [
        for (final idxs in grouped.values)
          _ScheduleCluster(
            courses: [for (final i in idxs) courses[i]],
            // 判据：**簇内任意一门课**在本周即点亮本簇。
            //
            // 簇内周次是"互相重叠"的（见上面的并查集），但重叠 ≠ 同一个区间：
            // 例如 1-10 周与 5-16 周会进同一个簇，第 3 周只有前者有课、第 14 周
            // 只有后者有课。这时用 any 而不是 all，是因为用户问的是"这个块本周
            // 要不要来上"——只要簇里有一门课本周要上，这个块就该亮。
            // 用 [parseWeekSpans] 覆盖逗号分段，避免"1-4,9-12(周)"在第 11 周不亮。
            highlighted:
                w != null &&
                idxs.any(
                  (i) => spans[i].any(
                    (span) => span['start']! <= w && w <= span['end']!,
                  ),
                ),
          ),
      ],
    );
  }
}

/// 课表表格的派生布局：节次去重顺序 + 每个 (节次, 星期) 单元格的缓存数据。
class _ScheduleTableLayout {
  final List<String> orderedTimes;
  final Map<String, Map<String, _ScheduleCellData>> cells;

  const _ScheduleTableLayout({required this.orderedTimes, required this.cells});

  static const empty = _ScheduleTableLayout(orderedTimes: [], cells: {});
}

