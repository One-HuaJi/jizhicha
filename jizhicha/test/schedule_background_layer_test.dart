import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jizhicha/schedule/schedule_background_layer.dart';
import 'package:jizhicha/theme.dart';

/// 「换背景图」渲染侧回归测试。
///
/// 作者需求：背景图只作用于课表页显示，**导出截图不带背景图**；文件不存在时
/// 静默回退主题底色，不许抛异常。
///
/// 这里锁四件事：
///  1. 路径解析：空串 / 不存在 / 是目录 / 空文件 ⇒ 一律回退（不抛）；
///  2. 有背景图时 `Image` 一定在调用方给的 `RepaintBoundary` **之外**
///     —— 这是"导出图不含背景图"的结构性保证：`RepaintBoundary.toImage()`
///     只截自己子树，背景层在它外层就永远截不到；
///  3. 文件缺失时回退成主题底色（不是白屏、不是报错）；
///  4. 可读性遮罩真的存在（否则深色课块压在照片上会糊）。
void main() {
  // 1x1 透明 PNG（合法图片，不写任何真实照片）。
  final pngBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGA'
    'hKmMIQAAAABJRU5ErkJggg==',
  );

  late Directory tempDir;
  late File imageFile;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('jizhicha_bg_test_');
    imageFile = File('${tempDir.path}${Platform.pathSeparator}bg.png')
      ..writeAsBytesSync(pngBytes);
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('路径解析：任何异常情况都静默回退', () {
    test('空串 / 空白串 ⇒ null', () {
      expect(resolveScheduleBackgroundFile(''), isNull);
      expect(resolveScheduleBackgroundFile('   '), isNull);
    });

    test('文件不存在 ⇒ null（不抛异常）', () {
      final missing = File(
        '${tempDir.path}${Platform.pathSeparator}not_here.png',
      );
      expect(missing.existsSync(), isFalse);
      expect(resolveScheduleBackgroundFile(missing.path), isNull);
    });

    test('路径是目录 ⇒ null', () {
      expect(resolveScheduleBackgroundFile(tempDir.path), isNull);
    });

    test('0 字节文件 ⇒ null（避免拿一个坏文件去解码）', () {
      final empty = File('${tempDir.path}${Platform.pathSeparator}empty.png')
        ..writeAsBytesSync(const <int>[]);
      expect(resolveScheduleBackgroundFile(empty.path), isNull);
    });

    test('合法文件 ⇒ 返回同一个路径的 File', () {
      final resolved = resolveScheduleBackgroundFile(imageFile.path);
      expect(resolved, isNotNull);
      expect(resolved!.path, imageFile.path);
    });
  });

  group('渲染：背景图在 RepaintBoundary 之外（导出不含背景）', () {
    testWidgets('有背景图时 Image 存在，但不在给定的 RepaintBoundary 子树内',
        (tester) async {
      // 模拟课表页结构：背景层 → RepaintBoundary(导出源) → 内容。
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: ScheduleBackgroundLayer(
              path: imageFile.path,
              child: RepaintBoundary(
                key: boundaryKey,
                child: const ColoredBox(
                  color: Colors.transparent,
                  child: SizedBox(width: 100, height: 100),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // 背景图确实铺上了……
      expect(find.byType(Image), findsOneWidget);
      // ……但**不在**导出的 RepaintBoundary 里面 —— 这条就是"导出不带背景图"
      // 的结构性保证（schedule_export.dart 取的就是表格卡片自己的
      // RepaintBoundary）。
      expect(
        find.descendant(
          of: find.byKey(boundaryKey),
          matching: find.byType(Image),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('有背景图时铺一层可读性遮罩', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: ScheduleBackgroundLayer(
              path: imageFile.path,
              child: const SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      );
      await tester.pump();

      final scrim = scheduleBackgroundScrimColor(Brightness.light);
      expect(
        find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == scrim,
        ),
        findsOneWidget,
      );
      // 遮罩要足够厚（≥60%），否则深色课块压在照片上会糊。
      expect(scheduleBackgroundScrimAlpha, greaterThanOrEqualTo(153));
      expect(tester.takeException(), isNull);
    });
  });

  group('渲染：文件缺失静默回退主题底色', () {
    testWidgets('路径不存在 ⇒ 没有 Image、底板是主题底色、不抛异常', (tester) async {
      final missing = '${tempDir.path}${Platform.pathSeparator}gone.png';
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: ScheduleBackgroundLayer(
              path: missing,
              child: const SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(Image), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == AppTheme.light.colorScheme.surface,
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('空路径（未设背景图）⇒ 与主题底色一致', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(
            body: ScheduleBackgroundLayer(
              path: '',
              child: SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(Image), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == AppTheme.dark.colorScheme.surface,
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
