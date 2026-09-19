// 文件分享桥接：Android 走原生 MethodChannel 调系统分享面板；其它平台不支持。
//
// 这里**没有**引入 `share_plus` 等第三方插件，而是复用项目已有的 MethodChannel
// 模式在 MainActivity 里实现。原因：少一个依赖就少一处版本冲突与体积开销，
// 而这段原生代码只有十几行；`FileProvider` 也已在 AndroidManifest 里注册。
//
// 分享前必须让文件落在 FileProvider 白名单覆盖的目录里——Dart 侧写的是
// `getTemporaryDirectory()`，对应 `<cache-path>`，已在 `res/xml/file_paths.xml`
// 中开放。

import 'dart:io';

import 'package:flutter/services.dart';

const MethodChannel _channel = MethodChannel('com.one.huaji/widget_settings');

/// 通过系统分享面板发送文件。
///
/// 仅 Android 实现；其它平台调用会抛 [UnsupportedError]，调用方应先判断平台。
Future<void> shareFile({
  required String path,
  required String mimeType,
  String subject = '',
}) async {
  if (!Platform.isAndroid) {
    throw UnsupportedError('当前平台不支持系统分享，请直接使用导出的文件');
  }
  await _channel.invokeMethod<bool>('shareFile', {
    'path': path,
    'mimeType': mimeType,
    'subject': subject,
  });
}
