import 'dart:convert';
import 'dart:io' show Directory, File, Platform;

import 'package:path_provider/path_provider.dart';

import 'schedule_time.dart';

// ==================== 设置持久化（本地文件，全程无云端） ====================

/// 应用设置，全部写到本地的 settings.json，绝不联网（符合"隐私本地化"硬要求）。
///
/// —— 课表设置 ——
/// - [highlightCurrentWeek]：本周视图——在课表中高亮"当前周"有课的课程。
/// - [filterByWeek]：按周筛选——只显示所选周次有课的课程，其它周隐藏。默认开启。
/// - [currentWeek]：手动选定的周次（1~20）。学校开课日期由作者维护，但仍允许手动调整，
///   本周视图高亮与按周筛选都以它为准。
/// - [scheduleTimeMode]：课表节次时间模式，默认按设备本地日期自动切换春秋冬季/夏季。
///
/// —— 成绩设置 ——
/// - [gradeCategoryEnabled]：是否启用"已完成 / 历史补考·重修"分类（关闭则所有课混在一组）。
/// - [gradeSortByYear]：按开课时间（学年）排序，以更大学年为顶，倒序展示。
/// - [gradeTermFilterEnabled]：是否显示成绩学期筛选器，默认开启。
///
/// —— 登录设置 ——
/// - [captchaOcrEnabled]：Android / Windows 端自动识别教务验证码，默认开启；识别失败时仍可手动输入。
class AppSettings {
  bool highlightCurrentWeek;
  bool filterByWeek;
  bool showWeekend;
  int scheduleTextSize;
  String semesterStartDate;
  int currentWeek;
  ScheduleTimeMode scheduleTimeMode;
  bool gradeCategoryEnabled;
  bool gradeSortByYear;
  bool gradeTermFilterEnabled;
  bool captchaOcrEnabled;
  bool updateCheckDisabled;

  AppSettings({
    this.highlightCurrentWeek = false,
    this.filterByWeek = true,
    this.showWeekend = true,
    this.scheduleTextSize = 1,
    this.semesterStartDate = '2026-09-07',
    this.currentWeek = 1,
    this.scheduleTimeMode = ScheduleTimeMode.automatic,
    this.gradeCategoryEnabled = true,
    this.gradeSortByYear = true,
    this.gradeTermFilterEnabled = true,
    this.captchaOcrEnabled = true,
    this.updateCheckDisabled = false,
  });

  static const _fileName = 'jizhicha_settings.json';
  // schemaVersion 仅用于老版本 settings.json 的字段迁移；当前版本无加速器字段。
  static const _schemaVersion = 7;

  /// 配置文件路径：优先用系统用户目录（Windows %APPDATA%），保证桌面端可写且稳定；
  /// 移动端没有这些环境变量，要回退到平台沙盒目录，否则会落到只读根目录。
  static Future<File> _file() async {
    final Directory folder;
    if (Platform.isWindows) {
      final base =
          Platform.environment['APPDATA'] ??
          Platform.environment['HOME'] ??
          Directory.current.path;
      folder = Directory(base);
    } else {
      // Android / Linux 使用 path_provider 提供的应用文档目录，
      // 避免 FileSystemException: Creation failed '/...' (OS Error: Read-only file system)。
      final dir = await getApplicationDocumentsDirectory();
      folder = dir;
    }
    try {
      if (!await folder.exists()) await folder.create(recursive: true);
    } catch (_) {}
    return File('${folder.path}${Platform.pathSeparator}$_fileName');
  }

  static Future<AppSettings> load() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final version = json['_v'] as int? ?? 1;
        if (version < _schemaVersion) {
          // 老版本文件：保留旧的课表/成绩字段，加速器三项按当前默认。
          return AppSettings(
            highlightCurrentWeek:
                json['highlightCurrentWeek'] as bool? ?? false,
            filterByWeek: version >= 2
                ? (json['filterByWeek'] as bool? ?? true)
                : true,
            showWeekend: json['showWeekend'] as bool? ?? true,
            scheduleTextSize: json['scheduleTextSize'] as int? ?? 1,
            semesterStartDate:
                json['semesterStartDate'] as String? ?? '2026-09-07',
            currentWeek: json['currentWeek'] as int? ?? 1,
            scheduleTimeMode: parseScheduleTimeMode(
              json['scheduleTimeMode'] as String?,
            ),
            gradeCategoryEnabled: json['gradeCategoryEnabled'] as bool? ?? true,
            gradeSortByYear: json['gradeSortByYear'] as bool? ?? true,
            gradeTermFilterEnabled:
                json['gradeTermFilterEnabled'] as bool? ?? true,
            captchaOcrEnabled: json['captchaOcrEnabled'] as bool? ?? true,
            updateCheckDisabled:
                json['updateCheckDisabled'] as bool? ?? false,
          );
        }
        return AppSettings(
          highlightCurrentWeek: json['highlightCurrentWeek'] as bool? ?? false,
          filterByWeek: json['filterByWeek'] as bool? ?? true,
          showWeekend: json['showWeekend'] as bool? ?? true,
          scheduleTextSize: json['scheduleTextSize'] as int? ?? 1,
          semesterStartDate:
              json['semesterStartDate'] as String? ?? '2026-09-07',
          currentWeek: json['currentWeek'] as int? ?? 1,
          scheduleTimeMode: parseScheduleTimeMode(
            json['scheduleTimeMode'] as String?,
          ),
          gradeCategoryEnabled: json['gradeCategoryEnabled'] as bool? ?? true,
          gradeSortByYear: json['gradeSortByYear'] as bool? ?? true,
          gradeTermFilterEnabled:
              json['gradeTermFilterEnabled'] as bool? ?? true,
          captchaOcrEnabled: json['captchaOcrEnabled'] as bool? ?? true,
          updateCheckDisabled: json['updateCheckDisabled'] as bool? ?? false,
        );
      }
    } catch (_) {}
    return AppSettings();
  }

  Future<void> save() async {
    try {
      final f = await _file();
      await f.writeAsString(
        jsonEncode({
          '_v': _schemaVersion,
          'highlightCurrentWeek': highlightCurrentWeek,
          'filterByWeek': filterByWeek,
          'showWeekend': showWeekend,
          'scheduleTextSize': scheduleTextSize,
          'semesterStartDate': semesterStartDate,
          'currentWeek': currentWeek,
          'scheduleTimeMode': scheduleTimeMode.storageValue,
          'gradeCategoryEnabled': gradeCategoryEnabled,
          'gradeSortByYear': gradeSortByYear,
          'gradeTermFilterEnabled': gradeTermFilterEnabled,
          'captchaOcrEnabled': captchaOcrEnabled,
          'updateCheckDisabled': updateCheckDisabled,
        }),
      );
    } catch (_) {}
  }
}
