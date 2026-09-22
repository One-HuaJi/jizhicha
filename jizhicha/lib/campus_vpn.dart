// ==================== Embedded Campus Accelerator ====================
/// The accelerator is part of this Flutter application through Dart FFI.
/// No standalone accelerator executable or local control API is used.

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' show File, Platform;

import 'package:ffi/ffi.dart' as ffi_utils;
import 'package:flutter/services.dart' show MethodChannel;

import 'credential_store.dart';
// `classifyVpnError` 与 `VpnFailure` 枚举来自状态机；错误文案（`message`）由
// UI 层通过 `VpnFailureText` 取，这里不再需要引入该扩展名。
import 'vpn_session.dart' show VpnFailure, classifyVpnError;

typedef _ConnectNative =
    ffi.Int32 Function(
      ffi.Pointer<ffi_utils.Utf8>,
      ffi.Pointer<ffi_utils.Utf8>,
      ffi.Pointer<ffi_utils.Utf8>,
    );
typedef _ConnectDart =
    int Function(
      ffi.Pointer<ffi_utils.Utf8>,
      ffi.Pointer<ffi_utils.Utf8>,
      ffi.Pointer<ffi_utils.Utf8>,
    );
typedef _DisconnectNative = ffi.Int32 Function();
typedef _DisconnectDart = int Function();
typedef _ShutdownNative = ffi.Void Function();
typedef _ShutdownDart = void Function();
typedef _StatusNative = ffi.Pointer<ffi_utils.Utf8> Function();
typedef _StatusDart = ffi.Pointer<ffi_utils.Utf8> Function();
typedef _FreeStringNative = ffi.Void Function(ffi.Pointer<ffi_utils.Utf8>);
typedef _FreeStringDart = void Function(ffi.Pointer<ffi_utils.Utf8>);

class _EmbeddedVpnBindings {
  static const _androidChannel = MethodChannel('com.one.huaji/android_vpn');
  ffi.DynamicLibrary? _library;
  _ConnectDart? _connect;
  _DisconnectDart? _disconnect;
  _ShutdownDart? _shutdown;
  _StatusDart? _status;
  _FreeStringDart? _freeString;

  void ensureLoaded() {
    if (_library != null) return;
    if (Platform.isAndroid) return;
    if (!Platform.isWindows) {
      throw '内置校园加速器当前仅支持 Windows；当前平台暂不支持校园网连接功能';
    }
    final libraryPath = File(
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}huse_vpn_ffi.dll',
    ).path;
    final library = ffi.DynamicLibrary.open(libraryPath);
    _library = library;
    _connect = library.lookupFunction<_ConnectNative, _ConnectDart>(
      'huse_vpn_connect',
    );
    _disconnect = library.lookupFunction<_DisconnectNative, _DisconnectDart>(
      'huse_vpn_disconnect',
    );
    _shutdown = library.lookupFunction<_ShutdownNative, _ShutdownDart>(
      'huse_vpn_shutdown',
    );
    _status = library.lookupFunction<_StatusNative, _StatusDart>(
      'huse_vpn_status_json',
    );
    _freeString = library.lookupFunction<_FreeStringNative, _FreeStringDart>(
      'huse_vpn_free_string',
    );
  }

  Future<bool> androidPrepare() async {
    if (!Platform.isAndroid) return true;
    return await _androidChannel.invokeMethod<bool>('prepare') ?? false;
  }

  Future<void> androidConnect({
    required String username,
    required String password,
    required String authSource,
  }) async {
    await _androidChannel.invokeMethod<void>('connect', {
      'username': username,
      'password': password,
      'authSource': authSource,
    });
  }

  Future<Map<String, dynamic>> androidStatus() async {
    final value = await _androidChannel.invokeMethod<String>('status');
    if (value == null || value.isEmpty) throw '校园加速器未返回状态信息，请重试';
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic>) throw '校园加速器状态异常，请重试';
    return decoded;
  }

  Future<void> androidDisconnect() async {
    await _androidChannel.invokeMethod<void>('disconnect');
  }

  int connect(
    ffi.Pointer<ffi_utils.Utf8> username,
    ffi.Pointer<ffi_utils.Utf8> password,
    ffi.Pointer<ffi_utils.Utf8> authSource,
  ) {
    ensureLoaded();
    return _connect!(username, password, authSource);
  }

  int disconnect() {
    ensureLoaded();
    return _disconnect!();
  }

  /// Synchronously release the native tunnel before the desktop process exits.
  /// Do not load the DLL solely for shutdown when the accelerator was never used.
  void shutdown() {
    _shutdown?.call();
  }

  Map<String, dynamic> status() {
    ensureLoaded();
    final pointer = _status!();
    try {
      if (pointer.address == 0) throw '校园加速器未返回状态信息，请重试';
      final decoded = jsonDecode(pointer.toDartString());
      if (decoded is! Map<String, dynamic>) throw '校园加速器状态异常，请重试';
      return decoded;
    } finally {
      _freeString!(pointer);
    }
  }
}

/// 用户尚未授予 Android 系统 VPN 权限。
///
/// 单独一个类型是为了让重试逻辑能识别它并**不重试** —— 重试只会重复弹
/// 系统授权对话框，必须让用户先去点"允许"。
class AcceleratorPermissionDenied implements Exception {
  const AcceleratorPermissionDenied();

  @override
  String toString() => '请在 Android 系统网络授权对话框中允许稽之查，然后再次点击连接';
}

class CampusVpnLauncher {
  /// 由 main.dart 注入：隧道状态变化时同步教务 HTTP 探测的源地址。
  static void Function(String?)? onSourceAddressChanged;
  static final _EmbeddedVpnBindings _bindings = _EmbeddedVpnBindings();

  static void shutdownNow() {
    if (Platform.isWindows) _bindings.shutdown();
  }

  Future<void> start() async => _bindings.ensureLoaded();

  // 错误归类统一走 `vpn_session.dart` 的 `classifyVpnError`，避免同一批
  // 英文子串在本文件与 UI 层各匹配一次（改造前就是那样，改文案会静默
  // 破坏重试策略）。
  bool _isWintunCleanupFailure(Object error) =>
      classifyVpnError(error) == VpnFailure.adapterBusy;

  bool _isTransientWindowsFailure(Object error) {
    final kind = classifyVpnError(error);
    return kind == VpnFailure.adapterBusy ||
        kind == VpnFailure.gatewayUnreachable ||
        kind == VpnFailure.badCredentials ||
        kind == VpnFailure.gatewayTimeout;
  }

  /// 获取当前隧道状态。读取失败时视为未连接，避免状态接口异常阻断页面跳转。
  Future<Map<String, dynamic>?> currentStatus() async {
    try {
      if (Platform.isAndroid) return await _bindings.androidStatus();
      if (Platform.isWindows) return _bindings.status();
    } catch (_) {
      // 状态接口只用于优化重入流程，失败时由正常连接流程继续处理。
    }
    return null;
  }

  Future<void> _connectWindowsOnce({
    required String username,
    required String password,
    String? authSource,
    void Function(String message)? onProgress,
  }) async {
    final userPointer = username.toNativeUtf8();
    final passwordPointer = password.toNativeUtf8();
    final sourcePointer = (authSource ?? 'SAM-all').toNativeUtf8();
    try {
      final result = _bindings.connect(
        userPointer,
        passwordPointer,
        sourcePointer,
      );
      if (result != 0) throw '校园加速器启动参数无效，请重试';
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      Object? lastError;
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 350));
        final status = _bindings.status();
        final message = status['message']?.toString();
        if (message != null && message.isNotEmpty) onProgress?.call(message);
        if (status['connected'] == true) {
          // 隧道刚标记 connected 时，原生层有时还没把虚拟 IP 填进 status。
          // 探测 HttpClient 必须绑定这个虚拟 IP 才能避开 FlClash TUN，
          // 因此再短轮询一段，直到拿到非空值。最多 2.5 秒；
          // 2.5 秒后仍为空视为配置异常，回落到断开重建。
          var virtualIp = status['virtual_ip']?.toString();
          var attempts = 0;
          while ((virtualIp == null || virtualIp.isEmpty) && attempts < 5) {
            attempts += 1;
            await Future<void>.delayed(const Duration(milliseconds: 500));
            // This is the Windows branch.  Calling the Android method here
            // leaves the desktop build waiting on a channel that does not
            // exist, even though the native tunnel is already connected.
            virtualIp = _bindings.status()['virtual_ip']?.toString();
          }
          if (virtualIp == null || virtualIp.isEmpty) {
            // ⚠️ 与 Android 分支同文案，且是 `classifyVpnError` 的匹配键
            // （见 vpn_session.dart 的 '尚未获取到校园网地址'）。
            throw '校园网已连接，但尚未获取到校园网地址，请重试';
          }
          onSourceAddressChanged?.call(virtualIp);
          return;
        }
        final error = status['error']?.toString();
        if (error != null && error.isNotEmpty) {
          lastError = error;
          final stage = status['stage']?.toString() ?? '';
          if (stage.endsWith('_error') ||
              stage == 'ffi_error' ||
              stage == 'tunnel_stopped') {
            throw error;
          }
        }
      }
      // 不把内部阶段名（sac/session/tls/nc_auth）显示给用户：看不懂也没法行动。
      throw lastError ?? '校园网连接超时，请重试';
    } finally {
      ffi_utils.calloc.free(userPointer);
      ffi_utils.calloc.free(passwordPointer);
      ffi_utils.calloc.free(sourcePointer);
    }
  }

  /// Android 单次连接尝试：准备 → 发起 → 轮询到 connected 或错误。
  Future<void> _connectAndroidOnce({
    required String username,
    required String password,
    String? authSource,
    void Function(String message)? onProgress,
  }) async {
    final prepared = await _bindings.androidPrepare();
    if (!prepared) {
      // 这条不该重试：需要用户去点系统授权弹窗，重试只会重复弹。
      throw const AcceleratorPermissionDenied();
    }
    await _bindings.androidConnect(
      username: username,
      password: password,
      authSource: authSource ?? 'SAM-all',
    );
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 350));
      final status = await _bindings.androidStatus();
      final message = status['message']?.toString();
      if (message != null && message.isNotEmpty) {
        onProgress?.call(message);
      } else {
        // 原生还没产出 message：把状态的**脱敏摘要**当作进度显示，
        // 让"卡在连接中"在屏幕上可诊断（MIUI 会吞掉 release 包的日志输出，
        // 所以只能靠屏幕）。
        //
        // 🔴 必须脱敏：这段文案会经 `onProgress` 直接渲染到**屏幕**上
        // （`vpn_setup_page.dart` / `campus_navigator_page.dart`），
        // 而原始 status 里带 `username`（真实学号）与 `virtual_ip`
        // （本次会话的校园网地址）—— 那是用户可见内容，会被截图或旁人看到。
        // 字段白名单与 Kotlin 侧 `redactStatus()` 保持一致。
        onProgress?.call('原生状态：${_redactStatusForDisplay(status)}');
      }
      if (status['connected'] == true) {
        // 隧道刚标记 connected 时，原生层有时还没把虚拟 IP 填进 status。
        // 探测 HttpClient 必须绑定这个虚拟 IP 才能避开 FlClash TUN，
        // 因此再短轮询一段，直到拿到非空值。最多 2.5 秒；
        // 2.5 秒后仍为空视为配置异常，回落到断开重建。
        var virtualIp = status['virtual_ip']?.toString();
        var attempts = 0;
        while ((virtualIp == null || virtualIp.isEmpty) && attempts < 5) {
          attempts += 1;
          await Future<void>.delayed(const Duration(milliseconds: 500));
          // This is the Android branch.  The Windows-only `status()` binding
          // is never loaded here (`ensureLoaded` returns early on Android),
          // so calling it throws a null-check error instead of retrying.
          virtualIp = (await _bindings.androidStatus())['virtual_ip']
              ?.toString();
        }
        if (virtualIp == null || virtualIp.isEmpty) {
          // ⚠️ 这段文字同时是 `classifyVpnError` 的匹配键（见 vpn_session.dart
          // 的 '尚未获取到校园网地址'）。改文案必须同步改分类器，否则会
          // 静默退化成 unknown。
          throw '校园网已连接，但尚未获取到校园网地址，请重试';
        }
        onSourceAddressChanged?.call(virtualIp);
        return;
      }
      final error = status['error']?.toString();
      if (error != null && error.isNotEmpty) {
        lastError = error;
        final stage = status['stage']?.toString() ?? '';
        if (stage.endsWith('_error') || stage == 'tunnel_stopped') {
          throw error;
        }
      }
    }
    throw lastError ?? '校园网连接超时';
  }

  Future<void> connect({
    required String username,
    required String password,
    String? authSource,
    void Function(String message)? onProgress,
  }) async {
    if (Platform.isAndroid) {
      // ⚠️ Android 只做**一次**连接尝试，不在这一层做断开重连循环。
      //
      // 曾经在这里加过「失败 → disconnect → 等 idle → 再连」的最多 2 次重试，
      // 结果是**把人卡死在"正在连接"**：重连会重启前台服务，而系统 VPN 权限、
      // TUN 建立与网关侧的旧会话释放都不是"断开就能立刻干净"的，重试反而让
      // 状态在 stopSelf / 重新 startForeground 之间来回摆动，Dart 侧最后
      // 卡在一个等不到回包的原生调用上。
      //
      // 网关收敛（实测 6~9 秒，偶尔 >30 秒）本来就由调用方的
      // `waitForIntranet`（45 秒、对**真正要用的教务端点**轮询）耐心等待，
      // 不需要在这一层急着重连。失败就如实上报，交给用户决定是否重试。
      await _connectAndroidOnce(
        username: username,
        password: password,
        authSource: authSource,
        onProgress: onProgress,
      );
      return;
    }
    try {
      await _connectWindowsOnce(
        username: username,
        password: password,
        authSource: authSource,
        onProgress: onProgress,
      );
    } catch (firstError) {
      if (!_isTransientWindowsFailure(firstError)) rethrow;

      // 非正常退出时，Wintun 的会话和学校网关会短暂处于清理状态。此前
      // disconnect() 只等待 connected=false，可能在原生任务尚未真正释放
      // 适配器前就再次发起连接，进而出现 WintunStartSession failed。
      // 现在等待 Rust 侧状态回到 idle 后再重试；Wintun 类错误多给一次
      // 清理机会，真实密码错误则不会进入这个分支。
      Object lastError = firstError;
      final retryCount = _isWintunCleanupFailure(firstError) ? 2 : 1;
      for (var retry = 0; retry < retryCount; retry++) {
        onProgress?.call('正在清理上次连接，请稍候…');
        try {
          await disconnect();
        } catch (_) {
          // 后续连接仍会给出最终明确错误；此处不因清理接口本身中断重试。
        }
        await Future<void>.delayed(
          Duration(milliseconds: retry == 0 ? 1800 : 3200),
        );
        try {
          await _connectWindowsOnce(
            username: username,
            password: password,
            authSource: authSource,
            onProgress: onProgress,
          );
          return;
        } catch (error) {
          lastError = error;
          if (!_isTransientWindowsFailure(error)) rethrow;
        }
      }

      // 仍无法创建会话时，向用户解释为可操作的信息，而不暴露 Wintun
      // 内部错误。下一次认证会使用已经完成清理的适配器状态。
      if (_isWintunCleanupFailure(lastError)) {
        throw '上次没有正常下线，请再认证一次';
      }
      throw lastError;
    }
  }

  Future<void> disconnect() async {
    try {
      if (Platform.isAndroid) {
        await _bindings.androidDisconnect();
        return;
      }
      if (!Platform.isWindows) return;
      final result = _bindings.disconnect();
      if (result != 0) return;
      final deadline = DateTime.now().add(const Duration(seconds: 12));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        final status = _bindings.status();
        // Rust 的 disconnect_vpn_inner 会在 stop_tunnel 完成后才写入 idle。
        // 只看 connected=false 会和 Wintun 的异步释放竞争，导致下一次连接
        // 偶发创建适配器失败。
        if (status['stage']?.toString() == 'idle') {
          await Future<void>.delayed(const Duration(milliseconds: 700));
          return;
        }
      }
      // 12 秒内 Rust 侧未回到 idle，可能 native 线程卡死或 Wintun 驱动
      // 未释放；直接调 shutdown 强制重置，避免下次 connect 陷入永久等待。
      _bindings.shutdown();
    } finally {
      onSourceAddressChanged?.call(null);
    }
  }

  /// 清理学校网关可能残留的会话。
  ///
  /// 本地停止 Wintun 不一定会让学校网关立即淘汰上一次认证。退出时，若能
  /// 找到当前学号对应的本地加密加速器凭据，则静默完成一次同账号认证并再次
  /// 断开，以让网关刷新旧会话。绝不故意提交错误密码，避免触发学校风控。
  /// 清理失败不阻断退出；下次正常连接仍会保留原有的错误提示作为兜底。
  Future<void> logout() async {
    final status = await currentStatus();
    final wasConnected = status?['connected'] == true;
    final username = status?['username']?.toString().trim() ?? '';
    StoredAccount? account;
    if (wasConnected && username.isNotEmpty) {
      final accounts = await CredentialStore.load(StoredAccountKind.vpn);
      for (final candidate in accounts) {
        if (candidate.username == username) {
          account = candidate;
          break;
        }
      }
    }

    await disconnect();
    if (!wasConnected || account == null || !Platform.isWindows) return;

    try {
      // 给已取消的原生任务和网关会话一个很短的释放窗口；不向 UI 暴露账户
      // 或密码，也不会单独打开任何窗口。
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await _connectWindowsOnce(
        username: account.username,
        password: account.password,
        authSource: 'SAM-all',
      ).timeout(const Duration(seconds: 25));
    } catch (_) {
      // 只要认证请求已经发出，学校网关已有机会刷新状态。此处继续执行最终
      // 断开；真正仍然存在的 Wintun/认证问题会在下一次用户主动连接时显示。
    } finally {
      await disconnect();
    }
  }

  Future<bool> waitForCampusNetwork({
    Duration timeout = const Duration(seconds: 90),
  }) async {
    if (Platform.isAndroid) {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        if ((await _bindings.androidStatus())['connected'] == true) return true;
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      return false;
    }
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_bindings.status()['connected'] == true) return true;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return false;
  }
}

/// 把原生 status 压成**可安全显示在屏幕上**的摘要。
///
/// 🔴 为什么必须脱敏：这个字符串会由调用方通过 `onProgress` 直接渲染到
/// **屏幕**上（`vpn_setup_page.dart` / `campus_navigator_page.dart`），
/// 而原生 status 里带 `username`（真实学号）与 `virtual_ip`（本次会话的
/// 校园网地址）。那是**用户可见内容**，会被截图或被旁人看到 —— 不能因为
/// 要在屏幕上做诊断，就把隐私显示出来。
///
/// 字段白名单与 Kotlin 侧 `redactStatus()` 保持一致：只留排查"卡在哪一步"
/// 真正需要的 connected / stage / error / warning。
String _redactStatusForDisplay(Map<String, dynamic> status) {
  const keep = <String>['connected', 'stage', 'error', 'warning'];
  final safe = <String, dynamic>{};
  for (final key in keep) {
    if (status.containsKey(key)) safe[key] = status[key];
  }
  return jsonEncode(safe);
}