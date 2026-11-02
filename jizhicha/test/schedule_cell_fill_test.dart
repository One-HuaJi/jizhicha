import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jizhicha/schedule/schedule_cell_layout.dart';
import 'package:jizhicha/schedule_time.dart';
import 'package:jizhicha/widget_schedule_store.dart';

/// 「课程格子底色形状」(`ScheduleCellFill`)、错峰载荷的回归测试。
///
/// 分三组：
///  1. **几何契约**：`filled` 必须把 cell padding / 课块 borderRadius 归零
///     （底色铺满整格），而课块**内部文字内边距保持不变**。断言的是**真代码**
///     `ScheduleCellLayout`（渲染层与单测共用同一份实现），不是复刻数字 ——
///     真代码被改回旧行为时这一组会真的变红。
///  2. **溢出证明**：在「窄屏横屏」(`pure`) 形态下，格子高度是
///     `(maxHeight - 2) / numRows` 的**紧高度**（`schedule_table.dart:57-59`），
///     这是唯一可能把课块内容挤爆的布局；`filled` 把那圈 `all(2)` 内边距拿掉后
///     内容只会**更宽松**，这里用 widget 层断言证明**没有** `RenderFlex overflow`。
///  3. **小组件载荷**：错峰开关打开时，`times` 两列（春秋冬季 / 夏季）对第 3、4
///     小节都必须已经是错峰时刻 —— Kotlin 侧不改代码就必须能跟随。
///
/// ⚠️ 关于第 2 组为什么是"复刻 widget 树"而不是直接 pump 真页面：
/// `_ScheduleTableSection` 是 `schedule_page.dart` 的 `part` 私有 mixin（外部库
/// 拿不到），而 `SchedulePage` 的初始化要读 `%APPDATA%` 下**用户真实的**课表缓存
/// 文件（`schedule_cache_store.dart:94-111`）并会拉起全局 60s 健康检查定时器
/// （`campus_environment.dart:765-766`）。为了不写用户真实缓存、也不给测试引入
/// 定时器泄漏，这里按 `schedule_table.dart` 的真实层级复刻同一棵树；但
/// **所有几何取值一律调用真代码 `ScheduleCellLayout`**，复刻的只是树形结构与
/// `cellHeight` 那两个公式（:57-59 与 `:361-362`）。
void main() {
  // ==================== 1. 几何契约（真代码） ====================

  group('底色形状的几何契约（断言真代码 ScheduleCellLayout）', () {
    test('filled：cell 内边距归零（铺满的先决条件）', () {
      expect(
        ScheduleCellLayout.cellPadding(ScheduleCellFill.filled, null),
        EdgeInsets.zero,
      );
      expect(
        ScheduleCellLayout.cellPadding(ScheduleCellFill.filled, 59.6),
        EdgeInsets.zero,
      );
    });

    test('rounded：保留历史外观（非 pure 6，pure 2）', () {
      expect(
        ScheduleCellLayout.cellPadding(ScheduleCellFill.rounded, null),
        const EdgeInsets.all(6),
      );
      expect(
        ScheduleCellLayout.cellPadding(ScheduleCellFill.rounded, 59.6),
        const EdgeInsets.all(2),
        reason: 'pure 下 cellHeight 非空，历史值是 all(2)',
      );
    });

    test('filled：课块圆角为 null（方角），冲突块同理（内 8 / InkWell 9 一起变）', () {
      expect(ScheduleCellLayout.blockRadius(ScheduleCellFill.filled), isNull);
      expect(
        ScheduleCellLayout.blockRadius(ScheduleCellFill.filled, radius: 9),
        isNull,
      );
      expect(
        ScheduleCellLayout.blockRadius(ScheduleCellFill.rounded),
        BorderRadius.circular(8),
      );
      expect(
        ScheduleCellLayout.blockRadius(ScheduleCellFill.rounded, radius: 9),
        BorderRadius.circular(9),
      );
    });

    test('filled：课块与相邻格之间的外边距也归零（否则底色仍差 2px 铺不满）', () {
      expect(ScheduleCellLayout.blockMargin(ScheduleCellFill.filled), isNull);
      expect(
        ScheduleCellLayout.blockMargin(ScheduleCellFill.rounded),
        const EdgeInsets.only(bottom: 2),
      );
    });

    test('文字内边距与底色形状无关：作者要的是"底色铺满"，不是"文字贴边"', () {
      // 这条是把两件事拆开：形状只改 padding/radius，
      // 文字那圈呼吸位始终保留（pure 与非 pure 各一套固定值）。
      expect(
        ScheduleCellLayout.textPaddingFor(pure: false),
        // 2026-11-02 横向 7/6 -> 5/5，给窄块多约 12% 的每行字数。
        const EdgeInsets.fromLTRB(5, 6, 5, 6),
      );
      expect(
        ScheduleCellLayout.textPaddingFor(pure: true),
        const EdgeInsets.fromLTRB(7, 3, 6, 3),
      );
    });
  });

  // ==================== 2. widget 层溢出证明 ====================

  /// 按 `schedule_table.dart:9-140` / `:297-393` / `:652-780` 复刻一张
  /// 「8 列 × [numRows] 行」的课表：节次栏 + 周一~周日，唯一课程块直挂 cell
  /// （单块时不套 Column —— `:379-386` 的留档：套 Column 会把圆角底色缩回去）。
  ///
  /// [A 组课]（`room: '逸夫楼908'`）在非 pure 下会多出一行错峰提示；
  /// pure 下提示被刻意隐藏（`_buildCourseEntry` 里 `pure ? null : ...`），
  /// 本函数复刻同一条件。
  Widget replicaTable({
    required ScheduleCellFill fill,
    required bool pure,
    required int numRows,
    required int linesPerCourse,
    required bool aGroupCourse,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: LayoutBuilder(
          builder: (context, constraints) {
            final cellHeight = pure
                ? (constraints.maxHeight - 2) / numRows
                : null;

            Widget timeCell() => Container(
              height: cellHeight,
              padding: EdgeInsets.symmetric(
                vertical: cellHeight == null ? 8 : 0,
                horizontal: 4,
              ),
              alignment: Alignment.center,
              decoration: const BoxDecoration(color: Color(0x22000000)),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('第二\n大节', textAlign: TextAlign.center),
                  // showDetails = cellHeight == null：pure 下不显示副文字，
                  // 也不显示错峰标记（schedule_table.dart:247 / :285-288）。
                  if (cellHeight == null) ...[
                    const SizedBox(height: 2),
                    const Text(
                      '10:10–10:55\n11:05–11:50',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 2),
                    const Text('错峰'),
                  ],
                ],
              ),
            );

            Widget courseBlock() => Container(
              key: const ValueKey('block'),
              margin: ScheduleCellLayout.blockMargin(fill),
              padding: ScheduleCellLayout.textPaddingFor(pure: pure),
              decoration: BoxDecoration(
                color: const Color(0x33000000),
                borderRadius: ScheduleCellLayout.blockRadius(fill),
              ),
              child: Column(
                key: const ValueKey('col'),
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '课程名',
                    style: TextStyle(fontSize: 10, height: 1.25),
                  ),
                  for (var i = 1; i < linesPerCourse; i++)
                    Text(
                      '副文字$i',
                      style: const TextStyle(fontSize: 10, height: 1.25),
                    ),
                  if (aGroupCourse && !pure)
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Text(
                        '10:25–11:10\n11:20–12:05',
                        style: TextStyle(fontSize: 10, height: 1.2),
                      ),
                    ),
                ],
              ),
            );

            final rows = <TableRow>[];
            for (var r = 0; r < numRows; r++) {
              rows.add(
                TableRow(
                  children: [
                    timeCell(),
                    for (var d = 0; d < 7; d++)
                      Container(
                        key: ValueKey('cell-$r-$d'),
                        padding: ScheduleCellLayout.cellPadding(
                          fill,
                          cellHeight,
                        ),
                        height: cellHeight,
                        constraints: cellHeight == null
                            ? const BoxConstraints(minHeight: 56)
                            : null,
                        // 单块时课块直接作为 cell 的子节点（真实实现亦然）。
                        child: r == 0 && d == 0
                            ? courseBlock()
                            : const SizedBox.shrink(),
                      ),
                  ],
                ),
              );
            }

            return SizedBox(
              width: constraints.maxWidth,
              height: constraints.maxHeight,
              child: Table(
                defaultColumnWidth: const FlexColumnWidth(),
                defaultVerticalAlignment:
                    TableCellVerticalAlignment.intrinsicHeight,
                children: rows,
              ),
            );
          },
        ),
      ),
    );
  }

  /// 让 MediaQuery 呈现「窄屏 + 横屏」（`shortestSide < 600` 且 landscape）。
  Future<void> pumpAt(WidgetTester tester, Size size, Widget widget) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: size),
        child: widget,
      ),
    );
  }

  group('filled + 窄屏横屏（pure）不溢出', () {
    // 648x360 是真实手机横屏量级：shortestSide=360 < 600 ⇒ pure 生效。
    const phoneLandscape = Size(648, 360);

    testWidgets('pure：filled 与 rounded 都不产生任何异常（含 RenderFlex overflow）', (
      tester,
    ) async {
      for (final fill in ScheduleCellFill.values) {
        await pumpAt(
          tester,
          phoneLandscape,
          replicaTable(
            fill: fill,
            pure: true,
            numRows: 6,
            linesPerCourse: 3,
            aGroupCourse: true,
          ),
        );
        expect(
          tester.takeException(),
          isNull,
          reason: '$fill 在 pure（窄屏横屏）下不得抛任何异常/溢出',
        );
      }
    });

    testWidgets('pure：filled 把 inner 高度让给内容，比 rounded 多出 (2+2+2) px', (
      tester,
    ) async {
      await pumpAt(
        tester,
        phoneLandscape,
        replicaTable(
          fill: ScheduleCellFill.rounded,
          pure: true,
          numRows: 6,
          linesPerCourse: 3,
          aGroupCourse: true,
        ),
      );
      expect(tester.takeException(), isNull);
      final roundedCol = tester.getSize(find.byKey(const ValueKey('col')));

      await pumpAt(
        tester,
        phoneLandscape,
        replicaTable(
          fill: ScheduleCellFill.filled,
          pure: true,
          numRows: 6,
          linesPerCourse: 3,
          aGroupCourse: true,
        ),
      );
      expect(tester.takeException(), isNull);
      final filledCol = tester.getSize(find.byKey(const ValueKey('col')));

      // rounded：cell padding all(2) ×2 + 块 margin bottom 2 共多占 6px。
      expect(
        filledCol.height - roundedCol.height,
        closeTo(6, 0.01),
        reason: 'filled 必须真的把那 6px（4 内边距 + 2 下边距）还给内容',
      );
      expect(
        filledCol.height,
        greaterThan(roundedCol.height),
        reason: '铺满模式的内容可用高度只能更宽松 —— 这就是"不会因 padding 归零而溢出"的依据',
      );

      // 精确值：cellHeight = (360 - 2) / 6 = 59.666…；
      // filled 扣掉文字内边距 6（上下各 3）⇒ 53.666…；
      // rounded 再扣掉 cell padding 4 + 块 margin bottom 2 ⇒ 47.666…。
      const cellHeight = (360 - 2) / 6;
      expect(filledCol.height, closeTo(cellHeight - 6, 0.01));
      expect(roundedCol.height, closeTo(cellHeight - 12, 0.01));
      expect(
        filledCol.height,
        greaterThan(3 * 10 * 1.25),
        reason: 'pure 下真实课块 3 行（课程名/教师/教室）必须能整行放下，否则会 RenderFlex overflow',
      );
    });

    testWidgets('pure：内容不足时两种模式都空得下；内容更多也不会翻车', (tester) async {
      // 真实课块在 pure 下最多 3 行（课程名 / 教师 / 教室），提示行被刻意隐藏。
      for (final lines in [1, 3]) {
        for (final fill in ScheduleCellFill.values) {
          await pumpAt(
            tester,
            phoneLandscape,
            replicaTable(
              fill: fill,
              pure: true,
              numRows: 6,
              linesPerCourse: lines,
              aGroupCourse: true,
            ),
          );
          expect(
            tester.takeException(),
            isNull,
            reason: 'lines=$lines / $fill 不应溢出',
          );
        }
      }
    });
  });

  group('非 pure（正常布局）下的铺满与提示行', () {
    testWidgets('filled 的课块宽度等于格子宽度（底色真的铺满）', (tester) async {
      const size = Size(800, 600);
      await pumpAt(
        tester,
        size,
        replicaTable(
          fill: ScheduleCellFill.filled,
          pure: false,
          numRows: 6,
          linesPerCourse: 3,
          aGroupCourse: true,
        ),
      );
      expect(tester.takeException(), isNull);

      final cell = tester.getSize(find.byKey(const ValueKey('cell-0-0')));
      final block = tester.getSize(find.byKey(const ValueKey('block')));
      expect(
        block.width,
        cell.width,
        reason: 'filled：cell padding 归零后课块必须横向顶满整格',
      );
    });

    testWidgets('rounded 的课块比格子窄 12px（左右各 6 的历史内边距），对照证明不是恒等', (tester) async {
      const size = Size(800, 600);
      await pumpAt(
        tester,
        size,
        replicaTable(
          fill: ScheduleCellFill.rounded,
          pure: false,
          numRows: 6,
          linesPerCourse: 3,
          aGroupCourse: true,
        ),
      );
      expect(tester.takeException(), isNull);

      final cell = tester.getSize(find.byKey(const ValueKey('cell-0-0')));
      final block = tester.getSize(find.byKey(const ValueKey('block')));
      expect(
        cell.width - block.width,
        closeTo(12, 0.01),
        reason: 'rounded：左右各留 6px，块比格子窄 12px',
      );
    });

    testWidgets('A 组课在非 pure 下多出提示行，且不溢出', (tester) async {
      const size = Size(800, 600);
      await pumpAt(
        tester,
        size,
        replicaTable(
          fill: ScheduleCellFill.filled,
          pure: false,
          numRows: 6,
          linesPerCourse: 3,
          aGroupCourse: true,
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.textContaining('10:25–11:10'), findsOneWidget);
    });
  });

  // ==================== 3. 小组件载荷（真实代码，非复刻） ====================

  group('小组件载荷：错峰增量必须同时进两季列', () {
    const autumn3Start = '10:20';
    const autumn3End = '11:05';
    const summer3Start = '10:10';
    const summer3End = '10:55';
    const late3Start = '10:25';
    const late3End = '11:10';
    const early3Start = '10:10';
    const early3End = '10:55';
    const late4End = '12:05';
    const early4End = '11:50';

    Map<String, dynamic> course({
      String time = '（03小节）',
      String room = '逸夫楼908',
      String day = '周一',
    }) => {
      'day': day,
      'time': time,
      'name': '课程',
      'teacher': '老师',
      'room': room,
      'weeks': '1-16周',
    };

    Map<String, dynamic> build(
      List<Map<String, dynamic>> courses, {
      bool peakShift = false,
      ScheduleTimeMode mode = ScheduleTimeMode.automatic,
      DateTime? now,
    }) => WidgetScheduleStore.buildPayload(
      courses,
      mode: mode,
      peakShift: peakShift,
      semesterStartDate: '2026-09-07',
      now: now,
    );

    Map<String, dynamic> timesOf(Map<String, dynamic> payload) =>
        ((payload['courses'] as List).single as Map)['times']
            as Map<String, dynamic>;

    test('开关打开：A 组（逸夫楼）第 3 小节两季列都是 10:25–11:10', () {
      final payload = build(
        [course()],
        peakShift: true,
        now: DateTime(2026, 1, 15),
      );
      final times = timesOf(payload);

      expect(times['springAutumnWinter'], {
        'start': late3Start,
        'end': late3End,
      });
      expect(times['summer'], {
        'start': late3Start,
        'end': late3End,
      }, reason: '错峰是"新的时间"：夏季列也必须是错峰值，否则 5–9 月的小组件会显示旧时刻');
    });

    test('开关打开：B 组（明德楼）第 3 小节两季列都是 10:10–10:55', () {
      final payload = build(
        [course(room: '明德楼903（会议室）')],
        peakShift: true,
        now: DateTime(2026, 1, 15),
      );
      final times = timesOf(payload);
      expect(times['springAutumnWinter'], {
        'start': early3Start,
        'end': early3End,
      });
      expect(times['summer'], {'start': early3Start, 'end': early3End});
    });

    test('开关打开：识别不出的楼栋走 B 组（早下课）', () {
      final times = timesOf(build([course(room: '理科楼101')], peakShift: true));
      expect(times['springAutumnWinter'], {
        'start': early3Start,
        'end': early3End,
      });
    });

    test('开关打开：第 4 小节 end 取 A/B 两组各自的结束时刻', () {
      final late = timesOf(build([course(time: '（04小节）')], peakShift: true));
      expect(late['springAutumnWinter'], {'start': '11:20', 'end': late4End});

      final early = timesOf(
        build([course(time: '（04小节）', room: '明德楼903')], peakShift: true),
      );
      expect(early['springAutumnWinter'], {'start': '11:05', 'end': early4End});
    });

    test('开关打开：跨 3、4 小节的课，start 取第 3 节、end 取第 4 节', () {
      final late = timesOf(build([course(time: '（03,04小节）')], peakShift: true));
      expect(late['springAutumnWinter'], {
        'start': late3Start,
        'end': late4End,
      });
      expect(late['summer'], {'start': late3Start, 'end': late4End});
    });

    test('开关关闭（默认）：与既有行为完全一致，两季列等于季节表', () {
      final payload = build([course()], now: DateTime(2026, 1, 15));
      final times = timesOf(payload);
      expect(times['springAutumnWinter'], {
        'start': autumn3Start,
        'end': autumn3End,
      });
      expect(times['summer'], {'start': summer3Start, 'end': summer3End});
      // 不传 peakShift 与显式 false 必须一致（默认值不能悄悄变）。
      expect(
        timesOf(build([course()], now: DateTime(2026, 1, 15))),
        timesOf(
          build([course()], peakShift: false, now: DateTime(2026, 1, 15)),
        ),
      );
    });

    test('开关打开：不受错峰影响的小节（第 1 小节）载荷一字不变', () {
      final off = timesOf(build([course(time: '（01小节）')]));
      final on = timesOf(build([course(time: '（01小节）')], peakShift: true));
      expect(on, off, reason: '错峰只作用于第 3、4 小节，第 1 小节必须纹丝不动');
      expect(off['springAutumnWinter'], {'start': '08:20', 'end': '09:05'});
      expect(off['summer'], {'start': '08:10', 'end': '08:55'});
    });

    test('固定季节模式不写 times，但顶层 start/end 必须已含错峰增量', () {
      final payload = build(
        [course()],
        peakShift: true,
        mode: ScheduleTimeMode.summer,
        now: DateTime(2026, 1, 15),
      );
      final entry = (payload['courses'] as List).single as Map;
      expect(
        entry.containsKey('times'),
        isFalse,
        reason: '固定模式没有"选列"一说，落盘两列反而会让人以为会切换',
      );
      expect(
        entry['start'],
        late3Start,
        reason: '固定模式下 Kotlin 只读顶层 start/end，错峰增量必须落在这里',
      );
      expect(entry['end'], late3End);
    });

    test('错峰只按该课自己的楼栋分组：同一次写入里 A/B 两组可以并存', () {
      final payload = build([
        course(room: '逸夫楼908'),
        course(room: '明德楼903', day: '周二'),
      ], peakShift: true);
      final list = payload['courses'] as List;
      expect(list.length, 2);
      final a = (list[0] as Map)['times'] as Map<String, dynamic>;
      final b = (list[1] as Map)['times'] as Map<String, dynamic>;
      expect(a['springAutumnWinter'], {'start': late3Start, 'end': late3End});
      expect(b['springAutumnWinter'], {'start': early3Start, 'end': early3End});
    });
  });
}
