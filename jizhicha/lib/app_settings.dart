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
/// - [peakShiftEnabled]：错峰上课表开关，默认**关闭**（作者 2026-10-08 明确要求
///   「错峰上课改成一个能开关的按钮，默认关闭，如果关闭则第二大节下面的错峰不显示」）。
///   **只影响第二大节（第 3、4 小节）**：
///   打开后按课程楼栋取 A/B 组的错峰时刻（见 [SchedulePeakShift]），其余小节照常按
///   季节解析。小组件与 `.ics` 导出同步跟随。
/// - [courseCellFill]：课程格子底色的形状，默认 [ScheduleCellFill.filled]（长方形铺满）。
///   只改底色圆角/留白，不改配色、不改布局、不动格间 0.6px 细线。
/// - [fitToScreenEnabled]：一屏显示——把课表各行等高压缩到可用高度内，尽量让
///   第一~第五大节在手机上不用上下滑（默认开启）。关闭后回到"内容自然撑高"的老行为。
/// - [courseColorEnabled]：课程格子彩色——按课程名稳定散列取色，同一门课永远是同一色，
///   默认**关闭**（作者 2026-11-01 要求「加一个课程格子彩色开关，默认关闭」）。
/// - [scheduleBackgroundPath]：课表页背景图的本地文件绝对路径，空串表示不设背景图。
///   图片由用户从本地选，复制进 App 私有目录后只存路径；**不参与导出截图**。
///
/// —— 校园网设置 ——
/// - [autoConnectCampus]：打开 App 后是否自动连接校园网（启动与回前台都算），
///   默认**关闭**（作者 2026-11-01 要求「把 app 自动连接校园网的功能做到设置内，默认关闭」）。
///   关闭时不再在后台自动认证，但仍保留手动连接与"要用校内网时按需连接"的路径。
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
  bool peakShiftEnabled;
  ScheduleCellFill courseCellFill;
  bool fitToScreenEnabled;
  bool courseColorEnabled;
  String scheduleBackgroundPath;
  bool autoConnectCampus;
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
    this.peakShiftEnabled = false,
    this.courseCellFill = ScheduleCellFill.filled,
    this.fitToScreenEnabled = true,
    this.courseColorEnabled = false,
    this.scheduleBackgroundPath = '',
    this.autoConnectCampus = false,
    this.gradeCategoryEnabled = true,
    this.gradeSortByYear = true,
    this.gradeTermFilterEnabled = true,
    this.captchaOcrEnabled = true,
    this.updateCheckDisabled = false,
  });

  static const _fileName = 'jizhicha_settings.json';
  // schemaVersion 仅用于老版本 settings.json 的字段迁移；当前版本无加速器字段。
  // 纯新增字段（缺键回退默认值）不需要升版本号，见 `appSettingsFromJson`。
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
        // 迁移分支与正常分支共用同一个解码器（`appSettingsFromJson`），
        // 差别只有 `_v == 1` 时 filterByWeek 字段尚不存在这一条。
        return appSettingsFromJson(
          json,
          migrateFilterByWeek: version < 2,
        );
      }
    } catch (_) {}
    return AppSettings();
  }

  Future<void> save() async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(toJson()));
    } catch (_) {}
  }

  /// 把当前设置编码成落盘 JSON。**唯一**一份编码逻辑，`save()` 与单测都用它。
  ///
  /// 单测直接断言 `appSettingsFromJson(s.toJson())` 的往返结果，不必真的读写
  /// 用户目录（`load()` 走 `path_provider` / `%APPDATA%`，会污染真实设置文件）。
  Map<String, dynamic> toJson() => {
    '_v': _schemaVersion,
    'highlightCurrentWeek': highlightCurrentWeek,
    'filterByWeek': filterByWeek,
    'showWeekend': showWeekend,
    'scheduleTextSize': scheduleTextSize,
    'semesterStartDate': semesterStartDate,
    'currentWeek': currentWeek,
    'scheduleTimeMode': scheduleTimeMode.storageValue,
    'peakShiftEnabled': peakShiftEnabled,
    'courseCellFill': courseCellFill.storageValue,
    'fitToScreenEnabled': fitToScreenEnabled,
    'courseColorEnabled': courseColorEnabled,
    'scheduleBackgroundPath': scheduleBackgroundPath,
    'autoConnectCampus': autoConnectCampus,
    'gradeCategoryEnabled': gradeCategoryEnabled,
    'gradeSortByYear': gradeSortByYear,
    'gradeTermFilterEnabled': gradeTermFilterEnabled,
    'captchaOcrEnabled': captchaOcrEnabled,
    'updateCheckDisabled': updateCheckDisabled,
  };
}

/// 从落盘 JSON 还原 [AppSettings]。**唯一**一份解码逻辑：`load()` 的
/// 迁移分支（`_v < _schemaVersion`）与正常分支都走这里，两个分支不可能再
/// "只改了一个"而分叉。
///
/// 缺字段一律回退到与 [AppSettings] 构造函数一致的默认值 —— 老
/// `settings.json` 里没有 `peakShiftEnabled` / `courseCellFill` 时，
/// 分别回退为 `false`（错峰关闭）与 [ScheduleCellFill.filled]（底色铺满）；
/// 没有 `fitToScreenEnabled` 回退 `true`（一屏显示默认开）、`courseColorEnabled`
/// 回退 `false`（彩色默认关）、`scheduleBackgroundPath` 回退空串、
/// `autoConnectCampus` 回退 `false`（自动连校园网默认关）。
///
/// [migrateFilterByWeek] 为真时代表这是 `_v == 1` 的老文件：那时 `filterByWeek`
/// 字段还不存在，语义上必须按 `true` 处理（与历史迁移分支完全一致）。
AppSettings appSettingsFromJson(
  Map<String, dynamic> json, {
  bool migrateFilterByWeek = false,
}) {
  return AppSettings(
    highlightCurrentWeek: json['highlightCurrentWeek'] as bool? ?? false,
    filterByWeek: migrateFilterByWeek
        ? true
        : (json['filterByWeek'] as bool? ?? true),
    showWeekend: json['showWeekend'] as bool? ?? true,
    scheduleTextSize: json['scheduleTextSize'] as int? ?? 1,
    semesterStartDate: json['semesterStartDate'] as String? ?? '2026-09-07',
    currentWeek: json['currentWeek'] as int? ?? 1,
    scheduleTimeMode: parseScheduleTimeMode(json['scheduleTimeMode'] as String?),
    peakShiftEnabled: json['peakShiftEnabled'] as bool? ?? false,
    courseCellFill: parseScheduleCellFill(json['courseCellFill'] as String?),
    fitToScreenEnabled: json['fitToScreenEnabled'] as bool? ?? true,
    courseColorEnabled: json['courseColorEnabled'] as bool? ?? false,
    scheduleBackgroundPath:
        json['scheduleBackgroundPath'] as String? ?? '',
    autoConnectCampus: json['autoConnectCampus'] as bool? ?? false,
    gradeCategoryEnabled: json['gradeCategoryEnabled'] as bool? ?? true,
    gradeSortByYear: json['gradeSortByYear'] as bool? ?? true,
    gradeTermFilterEnabled: json['gradeTermFilterEnabled'] as bool? ?? true,
    captchaOcrEnabled: json['captchaOcrEnabled'] as bool? ?? true,
    updateCheckDisabled: json['updateCheckDisabled'] as bool? ?? false,
  );
}
