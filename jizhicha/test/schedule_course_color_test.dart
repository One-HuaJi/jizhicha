import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jizhicha/schedule/schedule_course_colors.dart';
import 'package:jizhicha/schedule/schedule_peak_style.dart';
import 'package:jizhicha/theme.dart';

/// 「课程格子彩色」开关 + 课程色板回归测试。
///
/// 作者需求：加一个「课程格子彩色」开关，**默认关闭**；打开后按课程名取色
/// （同一门课永远同色），浅色与深色主题下都要能读，并且**本周高亮的视觉
/// 仍然压得住**；关闭时保持现在的中性底色。
///
/// 这里锁三件事：
///  1. 取色**稳定**：同一课名永远同一色，且色板被完整用到（不是永远取 0 号色）；
///  2. 两主题 × 普通/本周 四种组合的文字对比度都 ≥ 4.5:1（WCAG AA）；
///  3. 本周高亮靠**明度跳变**区分（不是靠色相，否则整表都是本周课时会失效）。
void main() {
  /// WCAG 2.x 相对亮度对比度。
  double contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final hi = math.max(la, lb);
    final lo = math.min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
  }

  final light = AppTheme.light.colorScheme;
  final dark = AppTheme.dark.colorScheme;

  // 24 个占位课名（不写任何真实课程名/姓名/班级，遵守隐私红线）。
  final names = List<String>.generate(24, (i) => '示例课程${i + 1}');

  group('取色稳定（同一门课永远同色）', () {
    test('同一个课名多次调用结果完全一致', () {
      for (final name in names) {
        final a = CourseColors.indexFor(name);
        final b = CourseColors.indexFor(name);
        expect(a, b);
        expect(
          CourseColors.fillFor(
            courseName: name,
            brightness: Brightness.light,
            highlighted: false,
          ),
          CourseColors.fillFor(
            courseName: name,
            brightness: Brightness.light,
            highlighted: false,
          ),
        );
        // 前后空白不影响取色（导入数据常带空格）。
        expect(CourseColors.indexFor('  $name  '), a);
      }
    });

    test('空课名固定落 0 号色（占位 "(未知课程)" 不会到处变色）', () {
      expect(CourseColors.indexFor(''), 0);
      expect(CourseColors.indexFor('   '), 0);
    });

    test('色板被完整用到（不是永远取 0 号色）', () {
      final indices = names.map(CourseColors.indexFor).toSet();
      expect(indices.length, CourseColors.paletteSize);
    });

    test('下标永远落在色板范围内', () {
      for (final name in [...names, '高等数学', '大学英语', '示例课程']) {
        final i = CourseColors.indexFor(name);
        expect(i, greaterThanOrEqualTo(0));
        expect(i, lessThan(CourseColors.paletteSize));
      }
    });
  });

  group('浅色 / 深色两主题都可读（WCAG AA ≥ 4.5:1）', () {
    test('8 个色相 × 两主题 × 普通/本周，文字对比度全部达标', () {
      final worst = <String, double>{};
      for (var i = 0; i < CourseColors.paletteSize; i++) {
        // 用能命中第 i 号色相的课名（避免依赖某个具体名字的散列值）。
        final name = names.firstWhere((n) => CourseColors.indexFor(n) == i);
        for (final brightness in [Brightness.light, Brightness.dark]) {
          for (final highlighted in [false, true]) {
            final fill = CourseColors.fillFor(
              courseName: name,
              brightness: brightness,
              highlighted: highlighted,
            );
            final ink = CourseColors.inkFor(
              courseName: name,
              brightness: brightness,
              highlighted: highlighted,
            );
            final ratio = contrast(fill, ink);
            final key =
                '${brightness.name}/${highlighted ? '本周' : '普通'}/#$i';
            worst[key] = ratio;
            expect(
              ratio,
              greaterThanOrEqualTo(4.5),
              reason: '$key 对比度不足：${ratio.toStringAsFixed(2)}:1',
            );
          }
        }
      }
      // 顺带把最差值打印出来，改色板时有据可依。
      final minRatio = worst.values.reduce(math.min);
      expect(minRatio, greaterThanOrEqualTo(4.5));
    });

    test('本周高亮 = 明度跳变：与普通块亮度差 ≥ 0.3', () {
      for (var i = 0; i < CourseColors.paletteSize; i++) {
        final name = names.firstWhere((n) => CourseColors.indexFor(n) == i);
        for (final brightness in [Brightness.light, Brightness.dark]) {
          final normal = CourseColors.fillFor(
            courseName: name,
            brightness: brightness,
            highlighted: false,
          );
          final highlighted = CourseColors.fillFor(
            courseName: name,
            brightness: brightness,
            highlighted: true,
          );
          expect(normal, isNot(highlighted));
          final delta =
              (normal.computeLuminance() - highlighted.computeLuminance()).abs();
          expect(
            delta,
            greaterThanOrEqualTo(0.3),
            reason: '第 $i 号色在 ${brightness.name} 下高亮差值只有 $delta',
          );
        }
      }
    });

    test('深色主题下普通块更深、本周块更浅（与浅色主题相反）', () {
      final name = names.first;
      final lightNormal = CourseColors.fillFor(
        courseName: name,
        brightness: Brightness.light,
        highlighted: false,
      );
      final lightHighlighted = CourseColors.fillFor(
        courseName: name,
        brightness: Brightness.light,
        highlighted: true,
      );
      final darkNormal = CourseColors.fillFor(
        courseName: name,
        brightness: Brightness.dark,
        highlighted: false,
      );
      final darkHighlighted = CourseColors.fillFor(
        courseName: name,
        brightness: Brightness.dark,
        highlighted: true,
      );
      expect(
        lightNormal.computeLuminance(),
        greaterThan(lightHighlighted.computeLuminance()),
      );
      expect(
        darkNormal.computeLuminance(),
        lessThan(darkHighlighted.computeLuminance()),
      );
    });
  });

  group('开关关闭 ⇒ 完全回到改造前的中性底色', () {
    test('关闭时填充/课名墨色/副文字墨色逐项等于历史实现', () {
      for (final scheme in [light, dark]) {
        for (final highlighted in [false, true]) {
          final fill = ScheduleCourseColors.fill(
            enabled: false,
            highlighted: highlighted,
            scheme: scheme,
            courseName: names.first,
          );
          expect(
            fill,
            highlighted
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest,
          );
          expect(
            ScheduleCourseColors.nameInk(
              enabled: false,
              highlighted: highlighted,
              scheme: scheme,
              courseName: names.first,
            ),
            scheme.onSurface,
          );
          final expectedSub = (!scheme.brightness.isDark || highlighted)
              ? scheme.onPrimaryContainer
              : scheme.onSurfaceVariant;
          expect(
            ScheduleCourseColors.subInk(
              enabled: false,
              highlighted: highlighted,
              scheme: scheme,
              courseName: names.first,
            ),
            expectedSub,
          );
          // 历史实现必须仍然达标（这条是既有行为的护栏）。
          expect(contrast(fill, expectedSub), greaterThanOrEqualTo(4.5));
        }
      }
    });

    test('开启时填充色来自色板，与关闭时不同', () {
      for (final scheme in [light, dark]) {
        final off = ScheduleCourseColors.fill(
          enabled: false,
          highlighted: false,
          scheme: scheme,
          courseName: names.first,
        );
        final on = ScheduleCourseColors.fill(
          enabled: true,
          highlighted: false,
          scheme: scheme,
          courseName: names.first,
        );
        expect(on, isNot(off));
        expect(
          on,
          CourseColors.fillFor(
            courseName: names.first,
            brightness: scheme.brightness,
            highlighted: false,
          ),
        );
      }
    });
  });

  group('错峰强调色在任何一种课块底色上都读得清', () {
    test('accentFor 在 16 个色板色 + 4 个中性底色上都 ≥ 4.5:1', () {
      final fills = <Color>[
        for (var i = 0; i < CourseColors.paletteSize; i++) CourseColors.paleFills[i],
        for (var i = 0; i < CourseColors.paletteSize; i++) CourseColors.deepFills[i],
        light.primaryContainer,
        light.surfaceContainerHighest,
        dark.primaryContainer,
        dark.surfaceContainerHighest,
      ];
      for (final fill in fills) {
        final accent = SchedulePeakStyle.accentFor(fill);
        final ratio = contrast(fill, accent);
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason:
              '底色 ${fill.toARGB32().toRadixString(16)} 上强调色对比度只有 '
              '${ratio.toStringAsFixed(2)}:1',
        );
      }
    });

    test('徽标底色/文字在两主题下都 ≥ 4.5:1', () {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        final bg = SchedulePeakStyle.badgeBackground(brightness);
        final fg = SchedulePeakStyle.badgeForeground(brightness);
        expect(
          contrast(bg, fg),
          greaterThanOrEqualTo(4.5),
          reason: '${brightness.name} 主题下错峰徽标对比度不足',
        );
      }
    });
  });
}

extension on Brightness {
  bool get isDark => this == Brightness.dark;
}
