import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:path_provider/path_provider.dart';

/// 桌面小组件的可调设置，全部写本地 JSON（widget_settings.json），无云端。
///
/// 深色模式不做开关：小组件永远跟随系统外观（day/night 资源自动切换），
/// 因此这里不提供「深色/浅色」选项。
class WidgetSettings {
  bool reminderEnabled;
  int reminderMinutes;
  bool showTeacherRoom;

  WidgetSettings({
    this.reminderEnabled = true,
    this.reminderMinutes = 10,
    this.showTeacherRoom = true,
  });

  static const _fileName = 'widget_settings.json';

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  static Future<WidgetSettings> load() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        return WidgetSettings(
          reminderEnabled: json['reminderEnabled'] as bool? ?? true,
          reminderMinutes: json['reminderMinutes'] as int? ?? 10,
          showTeacherRoom: json['showTeacherRoom'] as bool? ?? true,
        );
      }
    } catch (_) {}
    return WidgetSettings();
  }

  Future<void> save() async {
    try {
      final f = await _file();
      await f.writeAsString(
        jsonEncode({
          'reminderEnabled': reminderEnabled,
          'reminderMinutes': reminderMinutes,
          'showTeacherRoom': showTeacherRoom,
        }),
        flush: true,
      );
    } catch (_) {}
  }
}
