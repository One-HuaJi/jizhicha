import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_settings.dart';

// ==================== 更新检测 ====================

/// 当前应用版本（与 pubspec.yaml 保持一致）。
const String currentAppVersion = '1.0.9';

/// 比较版本号 a 与 b：a>b 返回正数，a<b 返回负数，相等返回 0。
int compareVersions(String a, String b) {
  final pa = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  final pb = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  final len = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < len; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// 拉取 GitHub 最新 release；返回 {version, downloadUrl}，失败返回 null（静默）。
Future<Map<String, String>?> fetchLatestRelease() async {
  try {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
      ),
    );
    final resp = await dio.get<dynamic>(
      'https://api.github.com/repos/One-HuaJi/jizhicha/releases/latest',
      options: Options(
        headers: const {
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'jizhicha-updater',
        },
      ),
    );
    final data = resp.data;
    if (data is! Map) return null;
    final tag = (data['tag_name'] as String?) ?? '';
    final version = tag.startsWith('v') ? tag.substring(1) : tag;
    if (version.isEmpty) return null;

    // 按平台找对应下载资产：Windows 取 zip，Android 取 arm64 APK。
    String? downloadUrl;
    final assets = (data['assets'] as List?) ?? const [];
    for (final a in assets) {
      if (a is! Map) continue;
      final name = (a['name'] as String?) ?? '';
      final url = (a['browser_download_url'] as String?) ?? '';
      final match = Platform.isWindows
          ? name.contains('Windows')
          : name.contains('arm64');
      if (match && url.isNotEmpty) {
        downloadUrl = url;
        break;
      }
    }
    return {
      'version': version,
      'downloadUrl': downloadUrl ?? (data['html_url'] as String?) ?? '',
    };
  } catch (_) {
    return null;
  }
}

/// 弹出"检测到新版本"对话框；勾选"永不弹出"则写入设置，点"更新"打开下载链接。
Future<void> showUpdateDialog(
  BuildContext context,
  String version,
  String downloadUrl,
) async {
  var neverAgain = false;
  final doUpdate = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setInner) => AlertDialog(
        title: const Text('检测到新版本'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('发现新版本 v$version，是否更新？'),
            const SizedBox(height: 4),
            CheckboxListTile(
              value: neverAgain,
              onChanged: (v) => setInner(() => neverAgain = v ?? false),
              title: const Text('永不弹出'),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('更新'),
          ),
        ],
      ),
    ),
  );

  if (neverAgain) {
    final settings = await AppSettings.load();
    settings.updateCheckDisabled = true;
    await settings.save();
  }
  if (doUpdate == true && downloadUrl.isNotEmpty) {
    final uri = Uri.tryParse(downloadUrl);
    if (uri != null) {
      launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
