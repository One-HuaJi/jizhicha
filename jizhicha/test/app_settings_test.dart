import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:jizhicha/app_settings.dart';
import 'package:jizhicha/schedule_time.dart';

/// `AppSettings` 持久化回归测试。
///
/// 重点覆盖本轮新增的两个字段（`peakShiftEnabled` / `courseCellFill`）：
///   * 编码 → 解码的**往返**必须一字不差；
///   * **老 `settings.json` 缺这两个键**时必须回退到默认值
///     （`false` / [ScheduleCellFill.filled]），即向后兼容 —— 用户升级后第一次
///     打开不能因为多出来的字段把原有设置读丢或读崩；
///   * `_v == 1` 的老文件仍按历史迁移语义处理（`filterByWeek` 强制 true）；
///   * `_schemaVersion` 本轮**刻意没有提升**（还是 7），这条被测试钉死。
///
/// ⚠️ 关于真实文件：`load()` / `save()` 走的路径是 `%APPDATA%/jizhicha_settings.json`
/// （Windows）或 path_provider 沙盒目录（移动端），**没有注入点**。所以本文件里
/// 「真实文件往返」那一组测试会**先备份原文件全部字节**，测完在 `finally` 里
/// 原样写回并核对 SHA-256。备份路径会在测试输出里打印，便于人工兜底。
void main() {
  group('编码 / 解码往返（不触碰磁盘）', () {
    test('toJson → appSettingsFromJson 保留全部字段，含两个新字段', () {
      final source = AppSettings(
        highlightCurrentWeek: true,
        filterByWeek: false,
        showWeekend: false,
        scheduleTextSize: 3,
        semesterStartDate: '2026-02-23',
        currentWeek: 12,
        scheduleTimeMode: ScheduleTimeMode.summer,
        peakShiftEnabled: true,
        courseCellFill: ScheduleCellFill.rounded,
        gradeCategoryEnabled: false,
        gradeSortByYear: false,
        gradeTermFilterEnabled: false,
        captchaOcrEnabled: false,
        updateCheckDisabled: true,
      );

      final restored = appSettingsFromJson(source.toJson());

      expect(restored.highlightCurrentWeek, isTrue);
      expect(restored.filterByWeek, isFalse);
      expect(restored.showWeekend, isFalse);
      expect(restored.scheduleTextSize, 3);
      expect(restored.semesterStartDate, '2026-02-23');
      expect(restored.currentWeek, 12);
      expect(restored.scheduleTimeMode, ScheduleTimeMode.summer);
      expect(restored.peakShiftEnabled, isTrue);
      expect(restored.courseCellFill, ScheduleCellFill.rounded);
      expect(restored.gradeCategoryEnabled, isFalse);
      expect(restored.gradeSortByYear, isFalse);
      expect(restored.gradeTermFilterEnabled, isFalse);
      expect(restored.captchaOcrEnabled, isFalse);
      expect(restored.updateCheckDisabled, isTrue);
    });

    test('默认构造的往返：错峰关闭 + 底色铺满', () {
      final restored = appSettingsFromJson(AppSettings().toJson());
      expect(
        restored.peakShiftEnabled,
        isFalse,
        reason: '作者 m01571 明确要求「错峰上课…默认关闭」',
      );
      expect(
        restored.courseCellFill,
        ScheduleCellFill.filled,
        reason: '作者口径：默认是长方形的（底色铺满）',
      );
    });

    test('toJson 写出两个新键，且 _v 仍是 7（本轮不升 schema 版本）', () {
      final json = AppSettings().toJson();
      expect(json['peakShiftEnabled'], isA<bool>());
      expect(json['courseCellFill'], isA<String>());
      expect(json['courseCellFill'], ScheduleCellFill.filled.storageValue);
      expect(
        json['_v'],
        7,
        reason:
            '本轮只做纯新增字段、缺字段走 ?? 默认值，没有必要升版本；'
            '若这里失败说明 _schemaVersion 被改了，需要同步核实迁移分支',
      );
    });
  });

  group('向后兼容：老 JSON 缺字段', () {
    test('缺 peakShiftEnabled / courseCellFill 时回退 false / filled', () {
      // 这是本轮改动上线前真实落盘的文件形态（没有这两个键）。
      final legacy = <String, dynamic>{
        '_v': 7,
        'highlightCurrentWeek': true,
        'filterByWeek': true,
        'showWeekend': true,
        'scheduleTextSize': 1,
        'semesterStartDate': '2026-09-07',
        'currentWeek': 4,
        'scheduleTimeMode': 'springAutumnWinter',
        'gradeCategoryEnabled': true,
        'gradeSortByYear': true,
        'gradeTermFilterEnabled': true,
        'captchaOcrEnabled': true,
        'updateCheckDisabled': false,
      };

      final s = appSettingsFromJson(legacy);

      expect(
        s.peakShiftEnabled,
        isFalse,
        reason: '老文件没有错峰字段 ⇒ 回退默认值（关闭）',
      );
      expect(
        s.courseCellFill,
        ScheduleCellFill.filled,
        reason: '老文件没有底色字段 ⇒ 必须回退默认的"铺满"',
      );
      // 老字段本身不能被新代码读丢。
      expect(s.currentWeek, 4);
      expect(s.scheduleTimeMode, ScheduleTimeMode.springAutumnWinter);
      expect(s.highlightCurrentWeek, isTrue);
    });

    test('空 JSON {} 全部回退到构造函数默认值', () {
      final s = appSettingsFromJson(const <String, dynamic>{});
      final d = AppSettings();
      expect(s.highlightCurrentWeek, d.highlightCurrentWeek);
      expect(s.filterByWeek, d.filterByWeek);
      expect(s.showWeekend, d.showWeekend);
      expect(s.scheduleTextSize, d.scheduleTextSize);
      expect(s.semesterStartDate, d.semesterStartDate);
      expect(s.currentWeek, d.currentWeek);
      expect(s.scheduleTimeMode, d.scheduleTimeMode);
      expect(s.peakShiftEnabled, d.peakShiftEnabled);
      expect(s.courseCellFill, d.courseCellFill);
      expect(s.gradeCategoryEnabled, d.gradeCategoryEnabled);
      expect(s.gradeSortByYear, d.gradeSortByYear);
      expect(s.gradeTermFilterEnabled, d.gradeTermFilterEnabled);
      expect(s.captchaOcrEnabled, d.captchaOcrEnabled);
      expect(s.updateCheckDisabled, d.updateCheckDisabled);
    });

    test('类型不对（null / 字符串 / 数字）也必须回退，不抛异常', () {
      final s = appSettingsFromJson(const <String, dynamic>{
        'peakShiftEnabled': null,
        'courseCellFill': null,
        'filterByWeek': null,
        'currentWeek': null,
      });
      expect(s.peakShiftEnabled, isFalse);
      expect(s.courseCellFill, ScheduleCellFill.filled);
      expect(s.filterByWeek, isTrue);
      expect(s.currentWeek, 1);
    });

    test('_v == 1 的迁移语义：filterByWeek 强制 true（即使 json 里是 false）', () {
      // load() 里 `final version = json['_v'] as int? ?? 1;` ⇒
      // migrateFilterByWeek: version < 2。这里直接钉住解码器的迁移行为。
      final s = appSettingsFromJson(const <String, dynamic>{
        'filterByWeek': false,
      }, migrateFilterByWeek: true);
      expect(
        s.filterByWeek,
        isTrue,
        reason: '_v == 1 时代 filterByWeek 字段尚不存在，语义上必须按 true 处理',
      );
      // 同一份 JSON 走正常分支时必须尊重用户值（证明上一条不是恒真）。
      expect(
        appSettingsFromJson(const <String, dynamic>{
          'filterByWeek': false,
        }).filterByWeek,
        isFalse,
      );
    });
  });

  group('枚举解析', () {
    test('parseScheduleCellFill：默认 filled，未知值也回退 filled', () {
      expect(parseScheduleCellFill(null), ScheduleCellFill.filled);
      expect(parseScheduleCellFill('filled'), ScheduleCellFill.filled);
      expect(parseScheduleCellFill('rounded'), ScheduleCellFill.rounded);
      expect(parseScheduleCellFill(''), ScheduleCellFill.filled);
      expect(parseScheduleCellFill('方形'), ScheduleCellFill.filled);
      expect(parseScheduleCellFill('ROUNDED'), ScheduleCellFill.filled);
    });

    test('storageValue 是稳定的落盘值（改了会让老文件读不回）', () {
      expect(ScheduleCellFill.filled.storageValue, 'filled');
      expect(ScheduleCellFill.rounded.storageValue, 'rounded');
      expect(ScheduleCellFill.filled.label, '长方形铺满');
      expect(ScheduleCellFill.rounded.label, '圆角');
    });

    test('往返：storageValue 编出去、parse 解得回同一个枚举', () {
      for (final fill in ScheduleCellFill.values) {
        expect(parseScheduleCellFill(fill.storageValue), fill);
      }
    });
  });

  group('真实文件往返（先备份原文件，finally 原样还原）', () {
    /// 与 `AppSettings._file()` 同一条路径规则（Windows 走 %APPDATA%）。
    File realSettingsFile() {
      final base =
          Platform.environment['APPDATA'] ??
          Platform.environment['HOME'] ??
          Directory.current.path;
      return File('$base${Platform.pathSeparator}jizhicha_settings.json');
    }

    test('save() → load() 往返 + 老文件（无新字段 / 无 _v）兼容', () async {
      final file = realSettingsFile();
      final existedBefore = file.existsSync();
      final originalBytes = existedBefore ? file.readAsBytesSync() : null;

      // 备份留在临时目录不删：万一测试进程被强杀（finally 没跑到），
      // 人工还能从这个文件把原设置拷回去。路径打印出来备查。
      final backup = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'jizhicha_settings_test_backup.json',
      );
      if (originalBytes != null) {
        backup.writeAsBytesSync(originalBytes);
        debugPrint('[app_settings_test] 原设置已备份到: ${backup.path}');
      }

      try {
        // —— ① 真实 save() 落盘 → load() 读回 ——
        final saved = AppSettings(
          currentWeek: 7,
          semesterStartDate: '2026-09-07',
          scheduleTimeMode: ScheduleTimeMode.summer,
          peakShiftEnabled: true,
          courseCellFill: ScheduleCellFill.rounded,
        );
        await saved.save();

        final loaded = await AppSettings.load();
        expect(loaded.currentWeek, 7);
        expect(loaded.scheduleTimeMode, ScheduleTimeMode.summer);
        expect(
          loaded.peakShiftEnabled,
          isTrue,
          reason: 'save() 必须把错峰开关落盘，load() 必须读回',
        );
        expect(
          loaded.courseCellFill,
          ScheduleCellFill.rounded,
          reason: 'save() 必须把底色形状落盘，load() 必须读回',
        );

        // —— ② 老文件（本改动上线前的形态：无 _v、无两个新字段）——
        file.writeAsStringSync(
          jsonEncode(const <String, dynamic>{
            'highlightCurrentWeek': true,
            'filterByWeek': false,
            'showWeekend': true,
            'scheduleTextSize': 2,
            'semesterStartDate': '2026-09-07',
            'currentWeek': 5,
            'scheduleTimeMode': 'automatic',
          }),
        );
        final legacy = await AppSettings.load();
        expect(legacy.currentWeek, 5);
        expect(legacy.scheduleTextSize, 2);
        expect(legacy.peakShiftEnabled, isFalse, reason: '老文件 ⇒ 错峰关闭');
        expect(
          legacy.courseCellFill,
          ScheduleCellFill.filled,
          reason: '老文件 ⇒ 底色回退"铺满"',
        );
        expect(
          legacy.filterByWeek,
          isTrue,
          reason: '无 _v 视为 _v == 1 ⇒ 走历史迁移，filterByWeek 强制 true',
        );

        // —— ③ 文件损坏时不能崩：load() 回退默认值 ——
        file.writeAsStringSync('{ this is not json');
        final broken = await AppSettings.load();
        expect(broken.currentWeek, AppSettings().currentWeek);
        expect(broken.peakShiftEnabled, isFalse);
        expect(broken.courseCellFill, ScheduleCellFill.filled);
      } finally {
        // 无论断言成功失败，原文件必须原样还原。
        if (originalBytes != null) {
          file.writeAsBytesSync(originalBytes);
          expect(
            file.readAsBytesSync(),
            originalBytes,
            reason: '还原后字节必须与备份完全一致',
          );
        } else {
          if (file.existsSync()) file.deleteSync();
        }
        // 注意：备份文件**刻意不删**，留给强杀场景人工兜底。
      }

      expect(
        file.existsSync(),
        existedBefore,
        reason: '测试不得改变"设置文件是否存在"这一事实',
      );
    });
  });
}
