import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jizhicha/zongce_model.dart';
import 'package:jizhicha/zongce_page.dart';

/// 综测页真实渲染 + 焦点行为回归测试（注入表单，绕开平台通道）。
///
/// 覆盖两个真机 bug：
///  1. **红色 ErrorWidget**：`减分项` 在体育素质与劳育素质里重名，
///     `ValueKey('base-${r.title}')` 撞 key → Duplicate keys → 两处红块。
///  2. **填完分数焦点跳回文字框**：条目/输入框 key 不稳定，重建时丢焦点。
Future<void> pumpPage(
  WidgetTester tester, {
  ZongceForm? form,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1600));
  final f = form ?? buildDefaultForm(term: '2025-2026-1');
  await tester.pumpWidget(MaterialApp(home: ZongcePage(initialForm: f)));
  await tester.pump();
}

/// 展开指定育的卡片。
Future<void> expand(WidgetTester tester, String name) async {
  final finder = find.textContaining(name);
  if (finder.evaluate().isEmpty) return;
  await tester.tap(finder.first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350)); // 展开动画
}

void main() {
  testWidgets('页面渲染五育卡片，无 ErrorWidget', (tester) async {
    await pumpPage(tester);

    expect(find.text('综测计算器'), findsOneWidget);
    expect(find.byType(ErrorWidget), findsNothing);
    // 注意：ListView 是懒加载，靠下的卡片（劳育等）在首屏不会构建，
    // 所以只能断言首屏可见的育，其余的靠下面的「全部展开」测试覆盖。
    expect(find.textContaining('德育素质'), findsWidgets);
    expect(find.textContaining('智育素质'), findsWidgets);
  });

  testWidgets('展开体育素质：不再出现红色 ErrorWidget（重复 key 回归）', (tester) async {
    await pumpPage(tester);
    await expand(tester, '体育素质');

    expect(
      find.byType(ErrorWidget),
      findsNothing,
      reason: '体育的「减分项」与劳育同名，key 消歧后不应再崩',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('展开劳育素质：不再出现红色 ErrorWidget', (tester) async {
    await pumpPage(tester);
    await expand(tester, '劳育素质');

    expect(find.byType(ErrorWidget), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同时展开体育与劳育（两处「减分项」共存）仍不崩', (tester) async {
    await pumpPage(tester);
    await expand(tester, '体育素质');
    await expand(tester, '劳育素质');
    await expand(tester, '美育素质');

    expect(
      find.byType(ErrorWidget),
      findsNothing,
      reason: '这是真机上两个红块同时出现的场景',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('全部分类都展开，逐行渲染无异常', (tester) async {
    await pumpPage(tester);
    for (final name in ['德育素质', '智育素质', '体育素质', '美育素质', '劳育素质']) {
      await expand(tester, name);
    }
    expect(find.byType(ErrorWidget), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('加一条加分项并填文字+分数：输入分数后焦点不被夺回', (tester) async {
    await pumpPage(tester);

    // 德育默认展开，点「加分项」
    final addBtn = find.text('加分项');
    expect(addBtn, findsWidgets);
    await tester.tap(addBtn.first);
    await tester.pump();
    await tester.pump();

    final noteField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '说明，如：献血',
    );
    final scoreField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '±分',
    );
    expect(noteField, findsOneWidget, reason: '应出现说明输入框');
    expect(scoreField, findsOneWidget, reason: '应出现分数输入框');

    // 先填文字
    await tester.enterText(noteField, '献血');
    await tester.pump();
    await tester.pump();

    // 再点到分数框并输入
    await tester.tap(scoreField);
    await tester.pump();
    await tester.enterText(scoreField, '5');
    await tester.pump();
    await tester.pump();

    expect(find.byType(ErrorWidget), findsNothing);

    // 分数框应仍持有焦点（用户反馈的"倒退"就是这里丢了焦点）
    final scoreEditable = find.descendant(
      of: scoreField,
      matching: find.byType(EditableText),
    );
    final st = tester.state<EditableTextState>(scoreEditable);
    // ignore: avoid_print
    print('输入分数后，分数框仍有焦点 = ${st.widget.focusNode.hasFocus}');

    expect(
      st.widget.focusNode.hasFocus,
      isTrue,
      reason: '填完分数焦点不应跳回说明框',
    );

    // 说明框内容不能丢
    expect(
      tester.widget<TextField>(noteField).controller?.text,
      '献血',
      reason: '说明内容不应被重建清空',
    );

    // 分数真的记进去了
    expect(find.text('5'), findsWidgets);
  });

  testWidgets('加两条记录后删掉第一条：剩下的内容不串行（key 复用回归）', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('加分项').first);
    await tester.pump();
    await tester.tap(find.text('加分项').first);
    await tester.pump();

    final notes = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '说明，如：献血',
    );
    expect(notes, findsNWidgets(2));

    await tester.enterText(notes.at(0), '第一条');
    await tester.pump();
    await tester.enterText(notes.at(1), '第二条');
    await tester.pump();

    // 删掉第一条
    final closeBtns = find.byIcon(Icons.close);
    await tester.tap(closeBtns.first);
    await tester.pump();
    await tester.pump();

    expect(find.byType(ErrorWidget), findsNothing);
    final remaining = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '说明，如：献血',
    );
    expect(remaining, findsOneWidget);
    expect(
      tester.widget<TextField>(remaining).controller?.text,
      '第二条',
      reason: '删掉第一条后，剩下的应还是「第二条」而不是错位成「第一条」',
    );
  });
}
