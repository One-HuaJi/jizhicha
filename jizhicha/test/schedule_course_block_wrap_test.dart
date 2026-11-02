import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jizhicha/app_settings.dart';
import 'package:jizhicha/schedule/schedule_course_block.dart';
import 'package:jizhicha/schedule/schedule_fit_layout.dart';
import 'package:jizhicha/theme.dart';

/// 压缩态（一屏显示）下课块文字**不许被砍成省略号**的回归测试。
///
/// 背景：7 天并列时一块只有约 32~37 逻辑像素宽，课名一行只放得下 3 个汉字。
/// 旧实现是"单行 + 省略号"，于是教室、长课名、长教师名全被截断
/// （作者 2026-11-02："还会存在显示不完全的问题"）。
/// 现实现：按真实宽度折行，整块超高时由 FittedBox 等比缩小兜底。
///
/// 隐私红线：课名 / 教师 / 楼栋一律用占位字符串，不写真实数据。
void main() {
  Map<String, String> course() => {
    'name': '示例课程名称非常长的一门课',
    'teacher': '示例教师',
    'room': '示例楼901',
    'day': '周三',
    'time': '第二大节 (03,04小节)',
    'weeks': '1-17',
  };

  Future<void> pump(
    WidgetTester tester, {
    ScheduleFitPlan? density,
    double width = 45,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              // 非压缩态在真实页面里高度由内容决定，测试也不能人为限高，
              // 否则等于替被测代码制造一次 overflow。
              height: density?.rowHeight,
              child: ScheduleCourseBlock(
                course: course(),
                isNarrow: true,
                settings: AppSettings(peakShiftEnabled: false),
                density: density,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Text nameText(WidgetTester tester) =>
      tester.widget<Text>(find.text('示例课程名称非常长的一门课'));

  group('压缩态（一屏显示）：文字完整可读', () {
    testWidgets('长课名允许折行，不再被压成单行省略号', (tester) async {
      final plan = ScheduleFitLayout.plan(
        enabled: true,
        availableHeight: 600,
        dataRows: 5,
        narrow: true,
      );
      expect(plan.compressed, isTrue);
      await pump(tester, density: plan);

      final name = nameText(tester);
      expect(name.softWrap, isTrue);
      expect(name.maxLines, greaterThan(1));
      // 没有 RenderFlex overflow / 没有渲染异常。
      expect(tester.takeException(), isNull);
    });

    testWidgets('教室与教师同样允许折行（不再只给一行）', (tester) async {
      final plan = ScheduleFitLayout.plan(
        enabled: true,
        availableHeight: 600,
        dataRows: 5,
        narrow: true,
      );
      await pump(tester, density: plan);

      final room = tester.widget<Text>(find.text('示例楼901'));
      expect(room.softWrap, isTrue);
      expect(room.maxLines, greaterThan(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('超高时由 FittedBox 等比缩小兜底，而不是溢出', (tester) async {
      final plan = ScheduleFitLayout.plan(
        enabled: true,
        availableHeight: 600,
        dataRows: 5,
        narrow: true,
      );
      // 故意把块压得很矮，触发"内容高于块高"的分支。
      await pump(tester, density: plan, width: 45);
      expect(find.byType(FittedBox), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  group('非压缩态：行为保持原样', () {
    testWidgets('不限制行数（自然高度、纵向滚动兜底）', (tester) async {
      await pump(tester, density: null);
      expect(nameText(tester).maxLines, isNull);
      expect(tester.takeException(), isNull);
    });
  });
}
