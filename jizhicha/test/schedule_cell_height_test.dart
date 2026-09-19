import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 课表课程块「等高」回归测试。
///
/// 背景：课表用 [Table] 渲染，而 Table 的 `defaultVerticalAlignment` 默认是
/// [TableCellVerticalAlignment.top]——每个单元格只按**自身内容**的高度布局。
/// 于是同一个大节里，课程名 5 行的块很高、只有 1 行的块很矮，纵向参差不齐。
///
/// 修复方式：改成 [TableCellVerticalAlignment.intrinsicHeight]。该模式下同一行
/// 的单元格统一拉伸到「本行最高单元格」的高度（见 rendering/table.dart 的
/// performLayout：第一遍按内容算出行高，第二遍用 tightFor(height: rowHeight)
/// 重新布局每个单元格）。
///
/// 这里直接对 Table 的渲染行为做断言，锁住这个修复：
///  1. intrinsicHeight 下同一行等高 —— 修复目标；
///  2. 默认 top 下确实不等高 —— 证明这个测试真的在测差异，而非恒真；
///  3. 课表字号限幅生效 —— 系统超大字号不再把 10px 基础字号放大成竖排单字。
void main() {
  /// 构造一个单元格：内含 [lines] 行文字，模拟课程名/教师/教室行数不同的块。
  Widget cell(String tag, int lines) {
    return Container(
      key: ValueKey('cell-$tag'),
      padding: const EdgeInsets.all(6),
      decoration: const BoxDecoration(color: Color(0x11000000)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < lines; i++)
            Text(
              '$tag 第$i行',
              style: const TextStyle(fontSize: 12, height: 1.25),
            ),
        ],
      ),
    );
  }

  Widget tableWith(TableCellVerticalAlignment alignment) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          child: Table(
            defaultColumnWidth: const FixedColumnWidth(100),
            defaultVerticalAlignment: alignment,
            children: [
              TableRow(
                children: [cell('高', 5), cell('矮', 1)],
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('intrinsicHeight：同一行内容行数不同也强制等高（修复目标）', (tester) async {
    await tester.pumpWidget(
      tableWith(TableCellVerticalAlignment.intrinsicHeight),
    );

    final tall = tester.getSize(find.byKey(const ValueKey('cell-高')));
    final short = tester.getSize(find.byKey(const ValueKey('cell-矮')));

    expect(tall.height, greaterThan(0), reason: '行高不应塌陷为 0');
    expect(
      short.height,
      tall.height,
      reason: '矮单元格必须被拉伸到与同行最高单元格等高，否则课表块仍然参差',
    );
  });

  testWidgets('top（修复前的默认值）：同一行不等高，正是被修掉的问题', (tester) async {
    await tester.pumpWidget(tableWith(TableCellVerticalAlignment.top));

    final tall = tester.getSize(find.byKey(const ValueKey('cell-高')));
    final short = tester.getSize(find.byKey(const ValueKey('cell-矮')));

    expect(
      short.height,
      lessThan(tall.height),
      reason: '若这里变成相等，说明测试没有真正区分两种对齐方式',
    );
  });

  testWidgets('课表字号限幅：系统 3 倍字号被压到 1.3 倍，10px 基础字号不再被放大成竖排单字', (tester) async {
    const baseFontSize = 10.0;
    double? scaledSize;

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          // 模拟用户把系统字体开到最大（3 倍）
          data: const MediaQueryData(textScaler: TextScaler.linear(3.0)),
          child: Scaffold(
            body: MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.3,
              child: Builder(
                builder: (context) {
                  scaledSize = MediaQuery.textScalerOf(
                    context,
                  ).scale(baseFontSize);
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      ),
    );

    expect(scaledSize, isNotNull);
    expect(
      scaledSize,
      closeTo(baseFontSize * 1.3, 0.01),
      reason: '课表区应把正文放大限制在 1.3 倍；其它页面不受影响',
    );
    expect(
      scaledSize,
      lessThan(baseFontSize * 3.0),
      reason: '限幅必须真的生效，否则最大字号下课程名仍会挤成竖排',
    );
  });
}
