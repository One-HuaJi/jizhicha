import 'dart:io' show HandshakeException, Platform, SocketException;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_settings.dart';

// ==================== 更新检测 ====================

/// 当前应用版本（与 pubspec.yaml 的 version 保持一致）。
const String currentAppVersion = '1.1.1';

/// Releases 页面（供"检测失败时用浏览器打开"的兜底入口）。
const String releasesPageUrl =
    'https://github.com/One-HuaJi/jizhicha/releases/latest';

const String _apiEndpoint =
    'https://api.github.com/repos/One-HuaJi/jizhicha/releases/latest';

/// 备用端点：`github.com` 上的 Releases 重定向（302 → `/releases/tag/vX.Y.Z`）。
///
/// 为什么要两个端点：`api.github.com` 与 `github.com` 是**不同的主机、不同的
/// 出口路径**。实测过 `api.github.com` 可达而 `github.com:443` 间歇性不通
/// （反之亦然）的情况；国内手机开代理/VPN 时更常见只通一边。
const String _redirectEndpoint =
    'https://github.com/One-HuaJi/jizhicha/releases/latest';

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

/// 去掉 tag 前缀的 `v`，得到纯版本号（`v1.1.1` → `1.1.1`）。
String versionFromTag(String tag) {
  final t = tag.trim();
  if (t.isEmpty) return '';
  return (t.startsWith('v') || t.startsWith('V')) ? t.substring(1) : t;
}

/// 从 Releases 页面的重定向地址里取版本号。
///
/// 形如 `https://github.com/One-HuaJi/jizhicha/releases/tag/v1.1.1`
/// （也可能带查询串）。取不到返回 null。
String? versionFromRedirectLocation(String? location) {
  if (location == null || location.isEmpty) return null;
  final uri = Uri.tryParse(location);
  if (uri == null) return null;
  final segments = uri.pathSegments;
  final idx = segments.indexOf('tag');
  if (idx < 0 || idx + 1 >= segments.length) return null;
  final version = versionFromTag(segments[idx + 1]);
  return version.isEmpty ? null : version;
}

/// 检测失败的原因分类。给用户看的是 [label]，技术上用于测试与排障。
enum UpdateCheckFailure {
  /// 连接或读取超时。
  timeout,

  /// 域名解析失败（代理/VPN 改了 DNS，或没有网络）。
  dns,

  /// TLS 握手失败（代理中间人、系统时间错、证书不受信）。
  tls,

  /// 连不上（被隧道/防火墙拦掉、端口不通）。
  connection,

  /// 服务器返回了非预期的 HTTP 状态码。
  httpStatus,

  /// 拿到了响应但解析不出内容（API 变更、被劫持返回 HTML）。
  parse,

  /// 其它未分类错误。
  unknown,
}

/// 检测结果。
sealed class UpdateCheckResult {
  const UpdateCheckResult();
}

/// 成功拿到最新版本信息。
final class UpdateCheckOk extends UpdateCheckResult {
  final String version;
  final String downloadUrl;
  final String htmlUrl;

  /// 用哪个端点拿到的（`api` / `redirect`），用于排障。
  final String endpoint;

  const UpdateCheckOk({
    required this.version,
    required this.downloadUrl,
    required this.htmlUrl,
    required this.endpoint,
  });

  bool get hasUpdate => compareVersions(version, currentAppVersion) > 0;
}

/// 检测失败。
final class UpdateCheckError extends UpdateCheckResult {
  final UpdateCheckFailure reason;

  /// 原始错误摘要（只用于展示与排障，**不含任何个人信息**）。
  final String detail;

  /// 最后一次尝试的端点。
  final String endpoint;

  const UpdateCheckError({
    required this.reason,
    required this.detail,
    required this.endpoint,
  });
}

/// 解析 `api.github.com` 的 release JSON。解析不出返回 null。
///
/// 抽成纯函数（`isWindows` 由外部注入而不是读 `Platform`），便于单测。
UpdateCheckOk? parseLatestReleaseJson(
  Object? data, {
  required bool isWindows,
  String endpoint = 'api',
}) {
  if (data is! Map) return null;
  final tag = (data['tag_name'] as String?) ?? '';
  final version = versionFromTag(tag);
  if (version.isEmpty) return null;

  // 按平台找对应下载资产：Windows 取 zip，Android 取 arm64 APK。
  String? downloadUrl;
  final assets = (data['assets'] as List?) ?? const [];
  for (final a in assets) {
    if (a is! Map) continue;
    final name = (a['name'] as String?) ?? '';
    final url = (a['browser_download_url'] as String?) ?? '';
    final match = isWindows ? name.contains('Windows') : name.contains('arm64');
    if (match && url.isNotEmpty) {
      downloadUrl = url;
      break;
    }
  }
  return UpdateCheckOk(
    version: version,
    downloadUrl: downloadUrl ?? (data['html_url'] as String?) ?? '',
    htmlUrl: (data['html_url'] as String?) ?? releasesPageUrl,
    endpoint: endpoint,
  );
}

/// 把任意异常归类成 [UpdateCheckFailure]。
UpdateCheckFailure classifyFailure(Object error) {
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return UpdateCheckFailure.timeout;
      case DioExceptionType.badCertificate:
        return UpdateCheckFailure.tls;
      case DioExceptionType.badResponse:
        return UpdateCheckFailure.httpStatus;
      case DioExceptionType.cancel:
        return UpdateCheckFailure.unknown;
      case DioExceptionType.connectionError:
      case DioExceptionType.unknown:
        return classifyFailure(error.error ?? error);
    }
  }
  if (error is HandshakeException) return UpdateCheckFailure.tls;
  if (error is SocketException) {
    final msg = error.message.toLowerCase();
    // dart:io 解析失败时的 message 是 `Failed host lookup: '<host>'`。
    if (msg.contains('failed host lookup') || msg.contains('name or service')) {
      return UpdateCheckFailure.dns;
    }
    return UpdateCheckFailure.connection;
  }
  return UpdateCheckFailure.unknown;
}

String _detailOf(Object error) {
  if (error is DioException) {
    final inner = error.error;
    if (inner != null) return inner.toString();
    return '${error.type} ${error.message ?? ''}'.trim();
  }
  return error.toString();
}

Future<Dio> _buildDio() async {
  return Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
      // GitHub 的 Releases 端点会 302，交给下面按端点决定是否跟随。
      followRedirects: true,
      validateStatus: (s) => s != null && s >= 200 && s < 400,
    ),
  );
}

/// 尝试单个端点一次。成功返回 [UpdateCheckOk]，失败抛异常由上层归类。
Future<UpdateCheckOk> _tryApiEndpoint(Dio dio, {required bool isWindows}) async {
  final resp = await dio.get<dynamic>(
    _apiEndpoint,
    options: Options(
      headers: const {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'jizhicha-updater',
      },
    ),
  );
  final ok = parseLatestReleaseJson(
    resp.data,
    isWindows: isWindows,
    endpoint: 'api',
  );
  if (ok == null) {
    throw const FormatException('api.github.com 返回内容无法解析');
  }
  return ok;
}

/// 备用端点：不跟随重定向，只从 `Location` 头里取 tag 名。
///
/// 拿不到下载直链（这个端点不给 assets 列表），所以 [UpdateCheckOk.downloadUrl]
/// 退回 Releases 页面地址 —— 用户点"更新"会打开网页，仍然可用。
Future<UpdateCheckOk> _tryRedirectEndpoint(
  Dio dio, {
  required bool isWindows,
}) async {
  final resp = await dio.get<dynamic>(
    _redirectEndpoint,
    options: Options(
      followRedirects: false,
      headers: const {'User-Agent': 'jizhicha-updater'},
      validateStatus: (s) => s != null && s < 400,
    ),
  );
  final location = resp.headers.value('location');
  final version = versionFromRedirectLocation(location);
  if (version == null) {
    throw const FormatException('github.com 未返回可用的 releases 重定向');
  }
  return UpdateCheckOk(
    version: version,
    downloadUrl: releasesPageUrl,
    htmlUrl: releasesPageUrl,
    endpoint: 'redirect',
  );
}

/// 检测最新版本。**不会静默吞掉失败** —— 失败一定返回 [UpdateCheckError]，
/// 由调用方决定怎么说给用户听（自动检查可以忽略，手动检查必须显示原因）。
///
/// 顺序是"先用 API，失败再换另一个主机"，两个端点各试 [attempts] 次，
/// 这样即使其中一台被代理/VPN 拦掉，另一台还有机会。
Future<UpdateCheckResult> checkForUpdate({int attempts = 2}) async {
  final dio = await _buildDio();
  final isWindows = Platform.isWindows;

  Object? lastError;
  var lastEndpoint = 'api';

  final tries = <({String name, Future<UpdateCheckOk> Function() run})>[
    (name: 'api', run: () => _tryApiEndpoint(dio, isWindows: isWindows)),
    (
      name: 'redirect',
      run: () => _tryRedirectEndpoint(dio, isWindows: isWindows),
    ),
  ];

  for (final t in tries) {
    for (var i = 0; i < attempts; i++) {
      lastEndpoint = t.name;
      try {
        return await t.run();
      } catch (e) {
        lastError = e;
        // 分类为"解析失败"说明网络是通的、只是内容不对，重试无意义，直接换端点。
        if (classifyFailure(e) == UpdateCheckFailure.parse) break;
        if (i + 1 < attempts) {
          await Future<void>.delayed(Duration(milliseconds: 400 * (i + 1)));
        }
      }
    }
  }

  return UpdateCheckError(
    reason: classifyFailure(lastError ?? 'unknown'),
    detail: _detailOf(lastError ?? 'unknown'),
    endpoint: lastEndpoint,
  );
}

/// 兼容旧调用点的薄封装：成功返回 `{version, downloadUrl, htmlUrl}`，失败 null。
///
/// 新代码请直接用 [checkForUpdate]（能拿到失败原因）；这个包装只为不打断
/// 既有调用方（`lib/app_bootstrap_page.dart` 的自动检查）。
Future<Map<String, String>?> fetchLatestRelease() async {
  final result = await checkForUpdate();
  if (result is UpdateCheckOk) {
    return {
      'version': result.version,
      'downloadUrl': result.downloadUrl,
      'htmlUrl': result.htmlUrl,
    };
  }
  return null;
}

/// 把失败原因说成人话，并给出下一步建议。
String describeUpdateCheckFailure(
  UpdateCheckFailure reason, {
  bool campusAcceleratorOn = false,
}) {
  final base = switch (reason) {
    UpdateCheckFailure.timeout => '连接 GitHub 超时。',
    UpdateCheckFailure.dns => '域名解析失败，可能当前网络（代理 / 校园加速器）改了 DNS。',
    UpdateCheckFailure.tls => '加密连接握手失败，可能被中间代理拦截，或系统时间不正确。',
    UpdateCheckFailure.connection => '连不上 GitHub，可能当前网络把外网请求拦掉了。',
    UpdateCheckFailure.httpStatus => 'GitHub 返回了异常状态码。',
    UpdateCheckFailure.parse => '收到响应但无法解析，可能是网络被劫持或接口有变动。',
    UpdateCheckFailure.unknown => '检测更新失败。',
  };
  if (campusAcceleratorOn) {
    return '$base\n\n当前「校园加速器」已开启：加速器会把流量送进校内网络，'
        '外网请求可能因此失败。可先断开加速器再重试。';
  }
  return base;
}

/// 手动检测失败时的对话框：说明原因 + 重试 + 用浏览器打开 Releases。
///
/// 返回 true 表示用户选了"重试"。
Future<bool> showUpdateCheckFailureDialog(
  BuildContext context, {
  required UpdateCheckError error,
  bool campusAcceleratorOn = false,
}) async {
  if (!context.mounted) return false;
  final retry = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('检测更新失败'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(describeUpdateCheckFailure(error.reason, campusAcceleratorOn: campusAcceleratorOn)),
          const SizedBox(height: 12),
          Text(
            '技术信息：${error.reason.name}（端点 ${error.endpoint}）',
            style: Theme.of(ctx).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('用浏览器打开'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('重试'),
        ),
      ],
    ),
  );
  if (retry == null || !retry) {
    final uri = Uri.tryParse(releasesPageUrl);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    return false;
  }
  return true;
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
