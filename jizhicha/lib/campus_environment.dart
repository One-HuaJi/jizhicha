import 'dart:async' show Timer;

import 'package:flutter/foundation.dart' show ChangeNotifier;

import 'campus_vpn.dart';
import 'credential_store.dart';

/// 主页课表与成绩页共享同一份校园网络状态，避免两个常驻页面分别探测后
/// 显示互相矛盾的连接入口。
class CampusEnvironmentController extends ChangeNotifier {
  bool _checking = false;
  bool _actionLoading = false;
  bool _reconnecting = false;
  bool? _online;
  Future<void>? _detectTask;
  Timer? _healthTimer;
  bool _dropDetected = false;

  CampusEnvironmentController() {
    startHealthMonitor();
  }

  bool get checking => _checking;
  bool get actionLoading => _actionLoading;
  bool get reconnecting => _reconnecting;
  bool? get online => _online;

  /// 由 main.dart 注入：校园内网探测与教务会话重置，避免反向依赖 JwxtClient。
  static Future<bool> Function({required Duration timeout})? onCheckCampusReachable;
  static Future<void> Function()? onResetSession;

  Future<bool> _checkReachable() =>
      onCheckCampusReachable?.call(timeout: const Duration(seconds: 4)) ??
      Future.value(false);

  Future<void> _resetSession() => onResetSession?.call() ?? Future.value();

  /// 完整状态文案（账号摘要用）。
  String get statusSummary {
    if (_reconnecting) return '重连中';
    if (_checking) return '正在检测校内环境';
    return _online == true ? '校园内网可用' : '离线模式';
  }

  /// 短状态文案（顶部小字用）。
  String get statusShort {
    if (_reconnecting) return '重连中';
    if (_checking) return '检测中';
    return _online == true ? '校园网在线' : '离线模式';
  }

  Future<void> detect() {
    final running = _detectTask;
    if (running != null) return running;
    late final Future<void> task;
    task = _detectInternal().whenComplete(() {
      if (identical(_detectTask, task)) _detectTask = null;
    });
    _detectTask = task;
    return task;
  }

  Future<void> _detectInternal() async {
    _checking = true;
    notifyListeners();
    try {
      final status = await CampusVpnLauncher().currentStatus();
      if (status?['connected'] == true) {
        CampusVpnLauncher.onSourceAddressChanged?.call(status?['virtual_ip']?.toString());
      } else if (status != null) {
        CampusVpnLauncher.onSourceAddressChanged?.call(null);
      }
      _online = await _checkReachable();
    } catch (_) {
      _online = false;
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    if (_actionLoading) return;
    _actionLoading = true;
    notifyListeners();
    try {
      await CampusVpnLauncher().logout();
      await _resetSession();
      _online = null;
      await detect();
    } finally {
      _actionLoading = false;
      notifyListeners();
    }
  }

  /// 取走一次"静默下线"通知标记（供 UI 弹提示，取走后清零）。
  bool consumeDropDetected() {
    final v = _dropDetected;
    _dropDetected = false;
    return v;
  }

  /// 启动周期健康检查：在线时每 60 秒静默探测一次，
  /// 检测到隧道静默下线（原生状态断开或校园内网不可达）就标记为离线。
  void startHealthMonitor() {
    _healthTimer ??= Timer.periodic(const Duration(seconds: 60), (_) {
      _silentHealthCheck();
    });
  }

  Future<void> _silentHealthCheck() async {
    if (_checking || _actionLoading || _reconnecting || _online != true) return;
    try {
      final status = await CampusVpnLauncher().currentStatus();
      final stillConnected = status?['connected'] == true;
      if (!stillConnected) {
        await _reconnectSilently();
        return;
      }
      final reachable = await _checkReachable();
      if (!reachable) {
        await _reconnectSilently();
      }
    } catch (_) {
      // 静默失败，保持当前状态。
    }
  }

  /// 静默重连：用本地保存的最后一个加速器账密自动登录，最多重试 3 次。
  /// 不拉起任何认证界面，也不向用户显示错误。
  Future<void> _reconnectSilently() async {
    if (_reconnecting) return;
    _reconnecting = true;
    notifyListeners();
    var succeeded = false;
    try {
      final accounts = await CredentialStore.load(StoredAccountKind.vpn);
      if (accounts.isEmpty) {
        _online = false;
        _dropDetected = true;
        return;
      }
      final account = accounts.first;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          await CampusVpnLauncher().connect(
            username: account.username,
            password: account.password,
            authSource: 'SAM-all',
          ).timeout(const Duration(seconds: 25));
          succeeded = true;
          break;
        } catch (_) {
          // 清理可能残留的隧道状态，短暂等待后重试。
          try {
            await CampusVpnLauncher().disconnect();
          } catch (_) {}
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
      if (succeeded) {
        final status = await CampusVpnLauncher().currentStatus();
        CampusVpnLauncher.onSourceAddressChanged?.call(status?['virtual_ip']?.toString());
        // 二次验证：隧道连上不等于校园内网真正可达，再探测一次避免"标在线、实际不通"。
        final reachable = await _checkReachable();
        if (reachable) {
          _online = true;
        } else {
          _online = false;
          _dropDetected = true;
        }
      } else {
        _online = false;
        _dropDetected = true;
      }
    } catch (_) {
      _online = false;
      _dropDetected = true;
    } finally {
      _reconnecting = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    _healthTimer = null;
    super.dispose();
  }
}

final CampusEnvironmentController campusEnvironment =
    CampusEnvironmentController();
