import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jizhicha/app_settings.dart';
import 'package:jizhicha/schedule/schedule_course_block.dart';
import 'package:jizhicha/schedule/schedule_peak_style.dart';
import 'package:jizhicha/schedule_time.dart';
import 'package:jizhicha/theme.dart';

/// 「错峰提示重做」的呈现回归测试。
///
/// 作者原话：错峰提示表现不佳 —— 旧实现是节次栏里一个裸的
/// `Text('错峰', labelSmall, onSurfaceVariant)`（无底色、宽度随字宽），
/// 课块内的错峰时刻又和教师/教室副文字**同字号同色**，看不出"这是错峰时间"。
///
/// 重做后的口径：
///  * 节次栏：一颗**实心 pill 徽标**（强调色底 + 高对比文字 + 固定圆角）；
///  * 课块内：一行「错峰」+ 时刻，用**与副文字不同的颜色与字重**（w800 标签
///    + w600 时刻），外面套一层 12% 底纹条，仍然**不加边框**；
///  * 开关（`peakShiftEnabled`）关闭时两者都不出现 —— B 组（早下课）学生
///    视觉零变化。
void main() {
  const peakTime = '第二大节 (03,04小节)';
  const plainTime = '第一大节 (01,02小节)';
  // A 组（晚下课）楼栋：尚美楼在 SchedulePeakShift.lateBuildings 里。
  const lateRoom = '尚美楼901';
  // B 组（早下课 = 基准组）楼栋。
  const earlyRoom = '鹤鸣楼901';

  group('何时显示徽标（纯决策）', () {
    test('开关关闭 ⇒ 永不显示', () {
      expect(
        SchedulePeakStyle.badgeVisible(enabled: false, time: peakTime),
        isFalse,
      );
    });

    test('开关打开 ⇒ 只在大节里含第 3/4 小节时显示', () {
      expect(
        SchedulePeakStyle.badgeVisible(enabled: true, time: peakTime),
        isTrue,
      );
      expect(
        SchedulePeakStyle.badgeVisible(enabled: true, time: plainTime),
        isFalse,
      );
      // 认不出小节的脏数据不显示，不误报。
      expect(SchedulePeakStyle.badgeVisible(enabled: true, time: ''), isFalse);
      expect(
        SchedulePeakStyle.badgeVisible(enabled: true, time: '第九大节'),
        isFalse,
      );
    });
  });

  group('何时显示课块内的错峰提示（纯决策）', () {
    test('开关关闭 ⇒ 不显示（B 组学生视觉零变化）', () {
      expect(
        SchedulePeakStyle.courseHint(
          enabled: false,
          time: peakTime,
          room: lateRoom,
        ),
        isNull,
      );
    });

    test('开关打开 + A 组楼栋 + 第 3/4 小节 ⇒ 显示，且时刻是 A 组的', () {
      final hint = SchedulePeakStyle.courseHint(
        enabled: true,
        time: peakTime,
        room: lateRoom,
      );
      expect(hint, isNotNull);
      expect(hint!.label, '错峰');
      expect(hint.body, contains('10:25'));
      expect(hint.body, contains('11:20'));
    });

    test('开关打开但课在 B 组（基准组）楼栋 ⇒ 不显示', () {
      expect(
        SchedulePeakStyle.courseHint(
          enabled: true,
          time: peakTime,
          room: earlyRoom,
        ),
        isNull,
      );
    });

    test('开关打开但不是第二大节 ⇒ 不显示（错峰只覆盖第 3、4 小节）', () {
      expect(
        SchedulePeakStyle.courseHint(
          enabled: true,
          time: plainTime,
          room: lateRoom,
        ),
        isNull,
      );
    });

    test('认不出楼栋 ⇒ 按 B 组（早下课）处理，不显示', () {
      expect(
        SchedulePeakStyle.courseHint(
          enabled: true,
          time: peakTime,
          room: '未知地点',
        ),
        isNull,
      );
      // 楼栋为空的脏数据同样按基准组。
      expect(
        SchedulePeakStyle.courseHint(
          enabled: true,
          time: peakTime,
          room: null,
        ),
        isNull,
      );
    });
  });

  group('徽标渲染：实心 pill + 高对比', () {
    testWidgets('显示「错峰」二字，并有强调色底色与固定圆角', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: const Scaffold(
            body: Center(child: SchedulePeakBadge(fontSize: 9)),
          ),
        ),
      );

      expect(find.text('错峰'), findsOneWidget);

      final container = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(SchedulePeakBadge),
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = container.decoration! as BoxDecoration;
      // 有底色（改造前是裸文字，没有底色）——这就是"一眼能分辨"的关键。
      expect(decoration.color, SchedulePeakStyle.badgeBackground(Brightness.light));
      expect(
        decoration.borderRadius,
        BorderRadius.circular(SchedulePeakStyle.badgeRadius),
      );
      // 本仓课表刻意无边框，徽标也不许加。
      expect(decoration.border, isNull);

      final text = tester.widget<Text>(find.text('错峰'));
      expect(text.style!.fontWeight, FontWeight.w800);
      expect(
        text.style!.color,
        SchedulePeakStyle.badgeForeground(Brightness.light),
      );
      // 窄列（34px）下不换行：靠 FittedBox 缩小而不是溢出。
      expect(text.maxLines, 1);
      expect(text.softWrap, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('深色主题换另一套底色（不是同一色硬套）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(
            body: Center(child: SchedulePeakBadge(fontSize: 9)),
          ),
        ),
      );
      final container = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(SchedulePeakBadge),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(
        (container.decoration! as BoxDecoration).color,
        SchedulePeakStyle.badgeBackground(Brightness.dark),
      );
    });
  });

  group('课块内的错峰时刻提示：开 / 关差异', () {
    Map<String, String> course() => {
      'name': '示例课程',
      'teacher': '示例教师',
      'room': lateRoom,
      'day': '周一',
      'time': peakTime,
      'weeks': '2,5-13',
    };

    Future<void> pumpBlock(WidgetTester tester, {required bool peak}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                child: ScheduleCourseBlock(
                  course: course(),
                  settings: AppSettings(
                    peakShiftEnabled: peak,
                    scheduleTimeMode: ScheduleTimeMode.springAutumnWinter,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('开启 ⇒ 课块里出现「错峰」+ A 组时刻，颜色与副文字不同', (tester) async {
      await pumpBlock(tester, peak: true);

      // 错峰提示行是一条 Text.rich（'错峰' + 空格 + 时刻），所以要 findRichText。
      final richFinder = find.byWidgetPredicate(
        (w) =>
            w is RichText &&
            w.text.toPlainText().contains('错峰') &&
            w.text.toPlainText().contains('10:25'),
      );
      expect(richFinder, findsOneWidget);

      final rich = tester.widget<RichText>(richFinder);
      final accent =
          rich.text.style!.color; // 整行用同一个强调色
      expect(accent, isNotNull);
      // 强调色 ≠ 副文字色（教师/教室那一行的颜色）—— 这才是"看得出是错峰"。
      final subText = tester.widget<Text>(find.text('@示例教师'));
      expect(accent, isNot(subText.style!.color));

      expect(tester.takeException(), isNull);
    });

    testWidgets('关闭 ⇒ 课块里没有错峰提示，只剩教师/教室', (tester) async {
      await pumpBlock(tester, peak: false);

      expect(
        find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText().contains('错峰'),
        ),
        findsNothing,
      );
      // 副文字照旧（错峰行消失不影响别的行）。
      expect(find.text('@示例教师'), findsOneWidget);
      expect(find.text(lateRoom), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
