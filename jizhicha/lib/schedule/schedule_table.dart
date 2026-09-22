// 课表页职责：课表表格/课程块渲染，以及单元格与整表派生数据类。
part of 'schedule_page.dart';

mixin _ScheduleTableSection on _SchedulePageDataSection {
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
        final fSize = isNarrow
            ? AppDimens.scheduleHeaderNarrow
            : AppDimens.scheduleHeaderWide;
        final startDate = DateTime.tryParse(_s.semesterStartDate);
        final weekOffsetDays = (_s.currentWeek - 1) * 7;
        final numRows = orderedTimes.length + 1;
        final cellHeight = pure && numRows > 0
            ? (constraints.maxHeight - 2) / numRows
            : null;

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
                          _buildHeaderCell('节', fontSize: fSize, cellHeight: cellHeight),
                          for (var i = 0; i < dayOrder.length; i++)
                            _buildHeaderCell(
                              isNarrow ? dayOrder[i][1] : dayOrder[i],
                              fontSize: fSize,
                              sub: _dayDateLabel(
                                startDate,
                                weekOffsetDays + i,
                              ),
                              cellHeight: cellHeight,
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
    return d.month.toString() + '/' + d.day.toString();
  }

  Widget _buildTimeCell(String time, [double? cellHeight, bool isNarrow = false]) {
    // 例 "第一大节 (01,02小节)" / "第一节 (01,02小节)" → 主行 + 小节行
    final match = RegExp(
      r'^(第[一二三四五六七八九十]+(?:大)?节)(?:\s*[（(]([^）)]*)[）)])?',
    ).firstMatch(time);
    final main = match?.group(1) ?? time;
    final legacySub = match?.group(2) ?? '';
    final sub = ScheduleTimeTable.formatSublessonLines(
      time,
      _s.scheduleTimeMode,
      includeLabels: false,
    );
    final colorScheme = Theme.of(context).colorScheme;
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
              fontSize: isNarrow
                  ? AppDimens.timeCellMainNarrow
                  : AppDimens.timeCellMainWide,
              color: colorScheme.onSurface,
            ),
          ),
          if (cellHeight == null && (sub.isNotEmpty || legacySub.isNotEmpty)) ...[
            const SizedBox(height: 2),
            Text(
              sub.isNotEmpty ? sub : legacySub,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: isNarrow
                    ? AppDimens.timeCellSubNarrow
                    : AppDimens.timeCellSubWide,
                height: 1.25,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
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

    return Container(
      padding: EdgeInsets.all(cellHeight == null ? 6 : 2),
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
        borderRadius: BorderRadius.circular(9),
        onTap: () => _showConflictDialog(courses),
        child: Container(
          padding: const EdgeInsets.fromLTRB(7, 7, 6, 7),
          decoration: BoxDecoration(
            // 冲突块：只靠整块 error 底色表达"这里冲突了"（可点击查看详情）。
            // 与课程块保持同一套画法：**一个元素只有一个视觉信号**，不再描边
            // —— 描边会和格内其它块、以及整格高亮的方框叠在一起"多重发亮"。
            // 底色用 errorContainer 略微加强，补偿去掉红条后损失的醒目度。
            color: colorScheme.errorContainer.withAlpha(110),
            // 圆角与课程块统一为 8（此前这里是 9，两种块圆角不一致显得毛糙）。
            borderRadius: BorderRadius.circular(8),
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

  /// 渲染一个课程块。
  ///
  /// [highlighted] 表示**这一个课块**属于"本周"（由它所在簇的
  /// [_ScheduleCluster.highlighted] 决定，见 [_ScheduleCellData.compute]）。
  /// 它是本块**唯一**的高亮手段：只把同一块底色加深，不画任何边框 ——
  /// 这样高亮永远只作用在一个元素上，不会出现"整格一层 + 课块一层"的
  /// 双重发亮（用户明确反馈过那种观感很差）。
  Widget _buildCourseEntry(
    Map<String, String> c, [
    bool isNarrow = false,
    bool highlighted = false,
  ]) {
    final name = (c['name'] ?? '').trim();
    final teacher = (c['teacher'] ?? '').trim();
    final room = (c['room'] ?? '').trim();
    final pure =
        MediaQuery.sizeOf(context).shortestSide < 600 &&
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = colorScheme.brightness == Brightness.dark;
    // 课程块配色：**全表没有任何边框**，只用"整块底色"表达。
    //
    // 演进留档（用户连续三轮反馈，这段历史值得留着，避免又绕回去）：
    //   ① "只画左边"的 3px 主色竖条 → 像括号残片、还占位置；
    //   ② 整格填充 + 格内块描边 → 两个圆角矩形嵌套同时发亮，"观感很差"；
    //   ③ 整格 2px 琥珀色加粗方框 → "太丑，几个框重叠在一起"
    //      （按格画框时相邻格边框必然紧挨成双线，这是该画法无法避免的）。
    // 最终方案：**格级不画任何装饰**，高亮只作用在课块自己的底色上。
    //
    // 层次来自**色相差**而不是同一颜色的深浅差：
    //   本周块  = primaryContainer（主题的暖色容器：浅=beige / 深=#5C4D2A）
    //   普通块  = surfaceContainerHighest（同主题的中性暖灰：浅=creamDark / 深=darkSurface）
    // 为什么不用"同一色不同 alpha"：默认开着「按周筛选」时，表里显示的全部都是
    // 本周课，深浅差会退化成整表同色、看不出任何层次；而"暖 ↔ 中性"的差异在
    // 整表同属本周时依然是**统一且好看**的一套色，不会显得扁平。
    // 两个色都取自主题色板，所以自动跟随深浅主题、不存在"不搭"。
    final courseFill = highlighted
        ? colorScheme.primaryContainer
        : colorScheme.surfaceContainerHighest;
    /// 次要文字（教师/教室/占位课名）。
    ///
    /// 按实测对比度选（AA 门槛 4.5:1）：
    ///   浅色：两种底上都只有 `onPrimaryContainer`(#5A5348) 够 —
    ///         creamDark 6.7:1 / beige 5.8:1；`onSurfaceVariant`(#756D62)
    ///         在 beige 上只有 3.9:1，不达标。
    ///   深色：中性底用 `onSurfaceVariant`(#B8A98F) 6.6:1；
    ///         暖底(#5C4D2A)上它只剩 3.6:1，必须换 `onPrimaryContainer`(#F2E8D5) 6.8:1。
    final courseSubText = (!isDark || highlighted)
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSurfaceVariant;
    final textDelta = (_s.scheduleTextSize - 1).toDouble();
    final nameSize = (isNarrow
            ? AppDimens.courseNameNarrow
            : AppDimens.courseNameWide) +
        textDelta;
    final subSize = (isNarrow
            ? AppDimens.courseSubNarrow
            : AppDimens.courseSubWide) +
        textDelta;
    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      padding: EdgeInsets.fromLTRB(7, pure ? 3 : 6, 6, pure ? 3 : 6),
      decoration: BoxDecoration(
        color: courseFill,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            name.isNotEmpty ? name : '(未知课程)',
            softWrap: !pure,
            maxLines: pure ? 1 : null,
            overflow: pure ? TextOverflow.ellipsis : null,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: nameSize,
              height: 1.25,
              color: name.isNotEmpty ? colorScheme.onSurface : courseSubText,
            ),
          ),
          if (teacher.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: pure ? 1 : 2),
              child: Text(
                '@$teacher',
                softWrap: !pure,
                maxLines: pure ? 1 : null,
                overflow: pure ? TextOverflow.ellipsis : null,
                style: TextStyle(
                  fontSize: subSize,
                  height: 1.2,
                  color: courseSubText,
                ),
              ),
            ),
          if (room.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: pure ? 1 : 2),
              child: Text(
                '$room',
                softWrap: !pure,
                maxLines: pure ? 1 : null,
                overflow: pure ? TextOverflow.ellipsis : null,
                style: TextStyle(
                  fontSize: subSize,
                  height: 1.2,
                  color: courseSubText,
                ),
              ),
            ),
        ],
      ),
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

