import 'dart:async' show Timer;

import 'package:flutter/foundation.dart' show ChangeNotifier;

import 'campus_vpn.dart';
import 'credential_store.dart';
import 'vpn_session.dart';

/// 校园网络状态的门面。
///
/// 改造后它**不再自己判断在线与否** —— 那件事由 [VpnSession] 唯一负责。
/// 本类只做三件事：
///   1. 持有 [VpnSession] 并把它的通知转发给 UI；
///   2. 周期性健康检查（发现掉线 → 尝试静默重连）；
///   3. 记住"刚刚掉线过"这一一次性事件，供 UI 弹提示。
///
/// 这样课表页、成绩页读到的 `online` 与状态机完全一致，不会再出现
/// "一个页面说在线、另一个说离线"的矛盾。
class CampusEnvironmentController extends ChangeNotifier {
  CampusEnvironmentController({VpnSession? session})
      : session = session ?? VpnSession(probe: _missingProbe) {
    this.session.addListener(_onSessionChanged);
    startHealthMonitor();
  }

  /// 未注入探测函数时的兜底：永远探测失败。
  ///
  /// 生产环境在 `main()` 里通过 [configure] 注入真实实现（`JwxtClient`）。
  static Future<bool> _missingProbe({required Duration timeout}) async => false;

  VpnSession session;

  bool _reconnecting = false;
  Timer? _healthTimer;
  Timer? _fastTimer;
  bool _dropDetected = false;

  /// 由 main.dart 在启动时调用，注入真实的内网探测与会话重置实现。
  ///
  /// 之所以保留"注入"而不是像页面那样直接 import：本模块与 `JwxtClient`
  /// 之间是**双向**关系（网络层要知道当前虚拟 IP，环境层要探测网络），
  /// 直接互相 import 会形成循环。这里注入的是**两个纯函数**，不是页面
  /// 构造器，不会出现"漏注入导致运行时崩溃且难以发现"的问题：
  /// 未注入时 [VpnSession] 会稳定地判定为离线，行为可预期。
  void configure({
    required CampusProbe probe,
    required Future<void> Function() resetSession,
    void Function(String? virtualIp)? onTunnelEstablished,
  }) {
    _resetSession = resetSession;
    session.removeListener(_onSessionChanged);
    session.dispose();
    session = VpnSession(probe: probe)
      ..onTunnelEstablished = onTunnelEstablished;
    session.addListener(_onSessionChanged);
  }

  Future<void> Function() _resetSession = () async {};

  void _onSessionChanged() => notifyListeners();

  // ---- 对 UI 暴露的只读状态（全部代理到状态机）----

  VpnPhase get phase => session.phase;

  /// 是否正在连接。UI 用它禁用按钮 / 显示 spinner。
  bool get checking => session.busy;

  bool get actionLoading => session.busy;

  bool get reconnecting => _reconnecting;

  /// 校园网是否可用。**唯一判据来自状态机。**
  bool? get online => session.online;

  String? get failureMessage => session.failure?.message;

  /// 完整状态文案（账号摘要用）。
  String get statusSummary {
    if (_reconnecting) return '重连中';
    if (session.busy) return '正在检测校内环境';
    return session.online ? '校园内网可用' : '离线模式';
  }

  /// 短状态文案（顶部小字用）。
  String get statusShort {
    if (_reconnecting) return '重连中';
    if (session.busy) return '检测中';
    return session.online ? '校园网在线' : '离线模式';
  }

  /// 重新同步一次状态。
  Future<void> detect() => session.syncFromNative();

  Future<void> logout() async {
    if (session.busy) return;
    await session.disconnect();
    await _resetSession();
  }

  /// 取走一次"静默下线"通知标记（供 UI 弹提示，取走后清零）。
  bool consumeDropDetected() {
    final v = _dropDetected;
    _dropDetected = false;
    return v;
  }

  /// 启动周期性健康检查。
  ///
  /// 两级节奏：
  ///   - **快探测（10 秒）**：只看原生 stage。学校网关会话有 15 分钟时限，
  ///     一旦原生报 `heartbeat_error` 就**立刻**重认证，而不是等 60 秒轮询
  ///     撞上。这是把"掉线后最长等 60 秒"压到"几秒"的关键。
  ///   - **慢探测（60 秒）**：完整复核（含内网 HTTP 探测），发现隧道静默
  ///     失效时重连。快探测只读状态、不发网络请求，开销可忽略。
  void startHealthMonitor() {
    _healthTimer ??= Timer.periodic(const Duration(seconds: 60), (_) {
      _silentHealthCheck();
    });
    _fastTimer ??= Timer.periodic(const Duration(seconds: 10), (_) {
      _fastGatewayWatch();
    });
  }

  /// 快探测：原生 stage 出现 `heartbeat_error` / `tunnel_stopped` 时立刻重认证。
  Future<void> _fastGatewayWatch() async {
    if (session.busy || _reconnecting) return;
    try {
      final status = await CampusVpnLauncher().currentStatus();
      if (status == null) return;
      final stage = status['stage']?.toString() ?? '';
      final connected = status['connected'] == true;

      // 网关会话过期：心跳失败会写 heartbeat_error。立刻静默重认证。
      if (stage == 'heartbeat_error') {
        await _reconnectSilently();
        return;
      }
      // 隧道被原生判定停止，同样立刻处理。
      if (stage == 'tunnel_stopped' && !connected) {
        await _reconnectSilently();
      }
    } catch (_) {
      // 快探测失败保持静默，交给慢探测兜底。
    }
  }

  Future<void> _silentHealthCheck() async {
    if (session.busy || _reconnecting) return;
    try {
      await session.syncFromNative();
      if (session.online) {
        // 已在线的复核：单次探测失败不拆隧道，交给 recheck 内部补测。
        if (!await session.recheck()) await _reconnectSilently();
        return;
      }
      // 离线时不主动连接：用户没点连接就不该被静默连上加速器。
      // （旧实现这里有个 `_online != true` 早退 bug，会让离线态永久锁死；
      //   现在离线就是 idle，定时器会继续尝试同步，不会卡住。）
    } catch (_) {
      // 静默失败，保持当前状态。
    }
  }

  /// 静默重连：用本地保存的最后一个加速器账密自动登录。
  ///
  /// ## ⚠️ 这里**不要**再套一层重试循环
  ///
  /// `CampusVpnLauncher.connect()` 内部已经实现了完整的重试策略
  /// （瞬时错误最多再试 2 次，每次之间 `disconnect()` + 等待原生回到
  /// `idle`，见 `campus_vpn.dart` 的 Android 分支）。如果这里再套一层
  /// 3 次循环，最坏会变成 **3 × 3 = 9 次认证请求** —— 对学校网关来说
  /// 近似暴力破解，有触发风控（甚至临时封号）的风险。
  ///
  /// **重试策略只允许存在于一个层级。** 选择放在 `campus_vpn.dart`，
  /// 因为那是"与网关对话"的那一层，最清楚什么错误值得重试。
  /// 本方法只负责：取凭据 → 调一次 → 记录结果。
  ///
  /// 失败后设置 [_dropDetected]，让 UI 提示用户"加速器已断开"，
  /// 由用户决定是否手动重连（而不是我们继续替他硬试）。
  Future<void> _reconnectSilently() async {
    if (_reconnecting) return;
    _reconnecting = true;
    notifyListeners();
    try {
      final accounts = await CredentialStore.load(StoredAccountKind.vpn);
      if (accounts.isEmpty) {
        _dropDetected = true;
        return;
      }
      final account = accounts.first;
      // 只调一次。内层的重试已经覆盖了瞬时失败。
      final ok = await session.connect(
        username: account.username,
        password: account.password,
      );
      if (!ok) _dropDetected = true;
    } catch (_) {
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
    _fastTimer?.cancel();
    _fastTimer = null;
    session.removeListener(_onSessionChanged);
    super.dispose();
  }
}

/// 全局单例。页面直接引用它，不再经过函数指针注入。
final CampusEnvironmentController campusEnvironment =
    CampusEnvironmentController();
