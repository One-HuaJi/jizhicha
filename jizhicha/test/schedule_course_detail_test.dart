import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jizhicha/app_settings.dart';
import 'package:jizhicha/schedule/schedule_course_block.dart';
import 'package:jizhicha/schedule/schedule_course_detail.dart';
import 'package:jizhicha/schedule_time.dart';
import 'package:jizhicha/theme.dart';

/// 「点课程块 → 弹课程详情」回归测试。
///
/// 需求：点一下课块能看到这门课的完整信息（课程名 / 教师 / 教室 / 上课周数），
/// 错峰开关打开时还要能看出"这门课按哪一组的时刻上下课"；关掉弹窗不残留。
///
/// 为什么课程块被抽成公开 widget [ScheduleCourseBlock]：课表渲染在
/// `part of 'schedule_page.dart'` 的 mixin 里，私有方法测不到；而这里的交互
/// （点 → 弹 → 关）必须能被 widget 测试真正点到，不能只测纯函数。
void main() {
  // 隐私红线：一律占位，不写真实课程名/教师名/班级/学号。
  Map<String, String> course({String room = '尚美楼901'}) => {
    'name': '示例课程',
    'teacher': '示例教师',
    'room': room,
    'day': '周一',
    'time': '第二大节 (03,04小节)',
    'weeks': '2,5-13,16-17',
  };

  Future<void> pumpBlock(
    WidgetTester tester, {
    required bool peak,
    String room = '尚美楼901',
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 220,
              child: ScheduleCourseBlock(
                course: course(room: room),
                settings: AppSettings(
                  peakShiftEnabled: peak,
                  // 固定成夏季作息，避免测试结果随运行月份漂移
                  //（automatic 模式按当前月份解析季节）。
                  scheduleTimeMode: ScheduleTimeMode.summer,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('详情文案（纯函数，不依赖日期）', () {
    test('错峰开启：第 3/4 小节用本课分组的时刻，并给出错峰说明', () {
      final detail = ScheduleCourseDetailDialog.timeDetail(
        course: course(),
        peakShiftEnabled: true,
        mode: ScheduleTimeMode.summer,
      );
      expect(detail.headline, '周一 第二大节 (03,04小节)');
      expect(detail.lessonLines, contains('03小节：10:25'));
      expect(detail.lessonLines, contains('04小节：11:20'));
      expect(detail.peakNote, isNotNull);
      expect(detail.peakNote, contains('晚下课组'));
    });

    test('错峰关闭：回到季节作息，且没有错峰说明', () {
      final detail = ScheduleCourseDetailDialog.timeDetail(
        course: course(),
        peakShiftEnabled: false,
        mode: ScheduleTimeMode.summer,
      );
      expect(detail.lessonLines, contains('03小节：10:10'));
      expect(detail.lessonLines, contains('04小节：11:05'));
      expect(detail.lessonLines, isNot(contains('10:25')));
      expect(detail.peakNote, isNull);
    });

    test('B 组（早下课）楼栋 + 春秋冬季：错峰表比季节表早 10 分钟', () {
      final detail = ScheduleCourseDetailDialog.timeDetail(
        course: course(room: '鹤鸣楼901'),
        peakShiftEnabled: true,
        mode: ScheduleTimeMode.springAutumnWinter,
      );
      // 基准组（B 组，早下课）的第 3 小节是 10:10，季节表是 10:20 ⇒ 确实偏移了。
      expect(detail.lessonLines, contains('03小节：10:10'));
      expect(detail.peakNote, isNotNull);
      expect(detail.peakNote, contains('早下课组'));
    });

    test('B 组 + 夏季：与季节表一致时不给多余说明（不制造噪音）', () {
      final detail = ScheduleCourseDetailDialog.timeDetail(
        course: course(room: '鹤鸣楼901'),
        peakShiftEnabled: true,
        mode: ScheduleTimeMode.summer,
      );
      // 夏季第 3 小节本来就是 10:10，和早下课组一致 ⇒ 无需再提示"错峰"。
      expect(detail.lessonLines, contains('03小节：10:10'));
      expect(detail.peakNote, isNull);
    });
  });

  group('点课块弹详情', () {
    testWidgets('弹窗里能看到课程名 / 教师 / 地点 / 上课周数', (tester) async {
      await pumpBlock(tester, peak: true);

      // 还没点之前没有弹窗。
      expect(find.byType(AlertDialog), findsNothing);

      await tester.tap(find.text('示例课程'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('课程详情'), findsOneWidget);
      // 课程名：课块里一份 + 弹窗标题下一份。
      expect(find.text('示例课程'), findsNWidgets(2));
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('示例教师'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('尚美楼901'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('2,5-13,16-17'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('错峰开启：弹窗显示按本课分组的上课时刻 + 错峰说明', (tester) async {
      await pumpBlock(tester, peak: true);
      await tester.tap(find.text('示例课程'));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('10:25'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('晚下课组'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('错峰关闭：弹窗里不出现错峰时刻与错峰说明', (tester) async {
      await pumpBlock(tester, peak: false);
      await tester.tap(find.text('示例课程'));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('10:25'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('错峰上课'),
        ),
        findsNothing,
      );
      // 季节作息照常显示。
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('10:10'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('点「知道了」关闭后弹窗不残留', (tester) async {
      await pumpBlock(tester, peak: true);
      await tester.tap(find.text('示例课程'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('课程详情'), findsNothing);
      // 课块本身还在（关的是弹窗，不是把课删了）。
      expect(find.text('示例课程'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
