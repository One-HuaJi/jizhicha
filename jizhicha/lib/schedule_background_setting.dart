import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app_settings.dart';
import 'common.dart';

/// 「课表背景图」设置项。
///
/// 作者 2026-11-01 要求「加个可以换背景图的功能」；口径确认：
/// **只作用于课表页显示，不进入导出截图**（导出仍走主题底色，保证截图清晰）。
///
/// 实现要点：
/// - 用户选的图片**复制**进 App 私有目录后只存路径（`AppSettings.scheduleBackgroundPath`），
///   不直接引用外部 Uri —— 相册/文件被移动或清理后背景图不会变成空白。
/// - 只保留一份：新选图覆盖旧文件，避免私有目录无限膨胀。
/// - 选图失败、复制失败都只提示不抛，不影响其它设置写入。
class ScheduleBackgroundSettingTile extends StatefulWidget {
  final AppSettings settings;

  const ScheduleBackgroundSettingTile({required this.settings, super.key});

  @override
  State<ScheduleBackgroundSettingTile> createState() =>
      _ScheduleBackgroundSettingTileState();
}

class _ScheduleBackgroundSettingTileState
    extends State<ScheduleBackgroundSettingTile> {
  static const _fileNamePrefix = 'schedule_background';
  bool _busy = false;

  String get _path => widget.settings.scheduleBackgroundPath;

  String get _displayName {
    if (_path.isEmpty) return '未设置：使用主题底色';
    final segments = Uri.file(_path).pathSegments;
    return segments.isEmpty ? '已设置' : '已设置：${segments.last}';
  }

  Future<Directory> _targetDir() async {
    // 与 AppSettings 同一套目录规则（Windows 用 %APPDATA%，移动端用应用文档目录），
    // 保证卸载/清理语义一致，也不会落到只读根目录。
    if (Platform.isWindows) {
      final base =
          Platform.environment['APPDATA'] ??
          Platform.environment['HOME'] ??
          Directory.current.path;
      return Directory(base);
    }
    return getApplicationDocumentsDirectory();
  }

  Future<void> _pick() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // file_picker 12.x：`FilePicker.platform` 已移除，改用静态 `pickFile`
      // 直接拿单个 `PlatformFile`（`pickFiles` 返回列表且恒为多选，不适用）。
      final picked = await FilePicker.pickFile(type: FileType.image);
      final source = picked?.path;
      if (source == null || source.isEmpty) return;

      final dir = await _targetDir();
      if (!await dir.exists()) await dir.create(recursive: true);
      final ext = _extensionOf(source);
      final target = File(
        '${dir.path}${Platform.pathSeparator}$_fileNamePrefix$ext',
      );
      // 先删旧文件（扩展名可能不同），再复制新图，只保留一份。
      for (final old in ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif']) {
        final f = File(
          '${dir.path}${Platform.pathSeparator}$_fileNamePrefix.$old',
        );
        if (await f.exists() && f.path != target.path) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
      await File(source).copy(target.path);

      widget.settings.scheduleBackgroundPath = target.path;
      await widget.settings.save();
      notifyAppSettingsChanged();
      if (!mounted) return;
      setState(() {});
      _toast('背景图已更新');
    } catch (e) {
      if (!mounted) return;
      _toast('选择背景图失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final old = _path;
      widget.settings.scheduleBackgroundPath = '';
      await widget.settings.save();
      notifyAppSettingsChanged();
      if (old.isNotEmpty) {
        try {
          final f = File(old);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {});
      _toast('已移除背景图');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _extensionOf(String path) {
    final segments = Uri.file(path).pathSegments;
    final name = segments.isEmpty ? '' : segments.last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '.jpg';
    final ext = name.substring(dot).toLowerCase();
    const allowed = {
      '.jpg',
      '.jpeg',
      '.png',
      '.webp',
      '.bmp',
      '.gif',
    };
    return allowed.contains(ext) ? ext : '.jpg';
  }

  void _toast(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(Icons.image_outlined, color: colorScheme.primary),
      title: const Text(
        '课表背景图',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: Text(
        '$_displayName\n只影响课表页显示，导出截图不带背景图。',
      ),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_path.isNotEmpty)
            TextButton(
              onPressed: _busy ? null : _clear,
              child: const Text('移除'),
            ),
          TextButton(
            onPressed: _busy ? null : _pick,
            child: Text(_busy ? '处理中…' : '选择'),
          ),
        ],
      ),
    );
  }
}
