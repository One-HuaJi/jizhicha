import 'package:flutter_test/flutter_test.dart';
import 'package:jizhicha/schedule/schedule_fit_layout.dart';

/// 「一屏显示」（等高压缩 + 顶部可折叠）的行高规划回归测试。
///
/// 背景（作者口径）：主页面第一~第五大节要完全显示、不需要手动上下滑。
/// 采取的办法**不是补空大节**，而是把「实际行数」按可用高度等分压缩，
/// 字号随行高自动降一档。
///
/// 为什么这些断言测的是纯函数：课表渲染住在 `part of 'schedule_page.dart'` 的
/// mixin 里，私有成员无法被测试引用，而 `SchedulePage` 本体初始化要读
/// `%APPDATA%` 下的真实课表缓存（见 `test/schedule_cell_fill_test.dart` 的说明）。
/// 所以按本仓既定范式，把"算行高/算能放几行"抽成公开静态函数
/// [ScheduleFitLayout.plan]，渲染层与单测共用同一份实现 —— 避免出现
/// "测试里复刻一套数字、渲染层另一套"的假绿灯。
void main() {
  group('关闭开关 ⇒ 与改造前行为完全一致', () {
    test('enabled=false 返回 disabled 档位', () {
      final plan = ScheduleFitLayout.plan(
        enabled: false,
        availableHeight: 700,
        dataRows: 5,
        narrow: true,
      );
      expect(plan.compressed, isFalse);
      // rowHeight=null ⇒ 渲染层传 null 的 cellHeight ⇒ 行按内容自然撑高，
      // 保留纵向滚动，和改造前完全一样。
      expect(plan.rowHeight, isNull);
      expect(plan.textScale, 1.0);
      expect(plan.nameMaxLines, 2);
      expect(plan.showTeacher, isTrue);
      expect(plan.showRoom, isTrue);
      expect(plan.showPeakHint, isTrue);
      expect(plan.showTimeSub, isTrue);
      expect(plan.showPeakBadge, isTrue);
    });

    test('没有数据 / 没有高度时也不压缩', () {
      for (final plan in [
        ScheduleFitLayout.plan(
          enabled: true,
          availableHeight: 700,
          dataRows: 0,
          narrow: true,
        ),
        ScheduleFitLayout.plan(
          enabled: true,
          availableHeight: 0,
          dataRows: 5,
          narrow: true,
        ),
      ]) {
        expect(plan.compressed, isFalse);
        expect(plan.rowHeight, isNull);
      }
    });
  });

  group('一屏压缩的行高计算', () {
    test('五大节 + 表头 = 6 行：等分后总高不超可用高度', () {
      const available = 700.0;
      final plan = ScheduleFitLayout.plan(
        enabled: true,
        availableHeight: available,
        dataRows: 5,
        narrow: true,
      );
      expect(plan.compressed, isTrue);
      expect(plan.fits, isTrue);
      // 合同变更（§9.22.2）：表头定额 44px，剩余高度只分给数据行。
      // 行数由数据决定：orderedTimes.length 行数据 + 1 行表头，**不补空大节**。
      const dataRows = 5;
      const rows = dataRows + 1;
      final total = plan.rowHeight! * dataRows +
          ScheduleFitLayout.headerRowHeight +
          ScheduleFitLayout.separatorThickness * (rows - 1);
      expect(total, lessThanOrEqualTo(available));
      // (700 - 44 表头 - 3 横线) / 5 = 130.6，低于上限 ⇒ 不再被钳住，
      // 五个大节正好铺满一屏（这正是抬上限的目的）。
      expect(plan.rowHeight, closeTo(130.6, 0.01));
      expect(plan.rowHeight, lessThan(ScheduleFitLayout.maxRowHeight));
      // 字号不允许超过基准（超过就会挤掉课名的一行，见档位表注释）。
      expect(plan.textScale, 1.0);
      // 行高够：三行副文字（错峰提示 / 教师 / 教室）全显示。
      expect(plan.showPeakHint, isTrue);
      expect(plan.showTeacher, isTrue);
      expect(plan.showRoom, isTrue);
      expect(plan.showTimeSub, isTrue);
      expect(plan.showPeakBadge, isTrue);
    });

    // 合同变更（2026-11-01）：表头不再占满一个数据行的高，改由
    // ScheduleFitLayout.headerRowHeight 定额，剩余高度只分给数据行。
    // 所以这里的期望从 (240-3)/6=39.5 变为 (240-44-3)/5=38.6。
    test('压到 38.6px/行：字号降一档、副文字按优先级只留错峰提示', () {
      final plan = ScheduleFitLayout.plan(
        enabled: true,
        availableHeight: 240,
        dataRows: 5,
        narrow: true,
      );
      expect(plan.compressed, isTrue);
      expect(plan.fits, isTrue);
      // (240 - 44 表头 - 3 横线) / 5 数据行
      expect(plan.rowHeight, closeTo(38.6, 0.01));
      expect(plan.textScale, ScheduleFitLayout.tightestTextScale);
      // 放不下两行课名 + 一行副文字 ⇒ 课名单行 + 省略号。
      expect(plan.nameMaxLines, 1);
      // 副文字优先级：错峰提示 > 教师 > 教室（硬信息优先，常量信息让位）。
      expect(plan.showPeakHint, isTrue);
      expect(plan.showTeacher, isFalse);
      expect(plan.showRoom, isFalse);
      // 节次栏还能放下小节时刻，但放不下时刻 + 错峰徽标
      // ⇒ 留时刻行（时刻本身已经说明这行是错峰时间）。
      expect(plan.showTimeSub, isTrue);
      expect(plan.showPeakBadge, isFalse);
    });

    test('同样的行高下，宽屏基准字号更大 ⇒ 能放的副文字更少', () {
      final narrow = ScheduleFitLayout.plan(
        enabled: true,
        availableHeight: 240,
        dataRows: 5,
        narrow: true,
      );
      final wide = ScheduleFitLayout.plan(
        enabled: true,
        availableHeight: 240,
        dataRows: 5,
        narrow: false,
      );
      // 行高只由可用高度与行数决定，与字号基准无关。
      expect(wide.rowHeight, narrow.rowHeight);
      expect(narrow.showPeakHint, isTrue);
      expect(wide.showPeakHint, isFalse);
    });

    test('行数太多放不进一屏 ⇒ fits=false（不谎报能放下）', () {
      final plan = ScheduleFitLayout.plan(
        enabled: true,
        availableHeight: 700,
        dataRows: 20,
        narrow: true,
      );
      expect(plan.compressed, isTrue);
      expect(plan.fits, isFalse);
      // 压到下限就停，不再继续压（再压就没法读）。
      expect(plan.rowHeight, ScheduleFitLayout.minRowHeight);
      expect(plan.textScale, ScheduleFitLayout.tightestTextScale);
    });

    test('行数越多，单行高度单调不增', () {
      double? previous;
      for (var rows = 1; rows <= 12; rows++) {
        final plan = ScheduleFitLayout.plan(
          enabled: true,
          availableHeight: 640,
          dataRows: rows,
          narrow: true,
        );
        final height = plan.rowHeight!;
        if (previous != null) {
          expect(height, lessThanOrEqualTo(previous));
        }
        previous = height;
      }
    });

    test('系统大字号参与预算 ⇒ 显示的行数不增', () {
      final normal = ScheduleFitLayout.plan(
        enabled: true,
        availableHeight: 240,
        dataRows: 5,
        narrow: true,
      );
      final huge = ScheduleFitLayout.plan(
        enabled: true,
        availableHeight: 240,
        dataRows: 5,
        narrow: true,
        outerTextScale: 1.3,
      );
      // 表头定额随系统字号一起放大（44 * 1.3），留给数据行的高度只会更少
      // ⇒ 行高只能更小或持平，绝不允许更大。
      expect(huge.rowHeight, lessThanOrEqualTo(normal.rowHeight!));
      final normalLines =
          (normal.nameMaxLines) +
          (normal.showTeacher ? 1 : 0) +
          (normal.showRoom ? 1 : 0) +
          (normal.showPeakHint ? 1 : 0);
      final hugeLines =
          (huge.nameMaxLines) +
          (huge.showTeacher ? 1 : 0) +
          (huge.showRoom ? 1 : 0) +
          (huge.showPeakHint ? 1 : 0);
      expect(hugeLines, lessThanOrEqualTo(normalLines));
    });
  });
}
