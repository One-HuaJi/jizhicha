import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier;

import 'campus_vpn.dart';

/// 加速器连接的**唯一真相**。
///
/// ## 为什么需要这个文件
///
/// 改造前"校园网到底通没通"有三个互不相干的来源：
///   1. 原生隧道状态（`CampusVpnLauncher.currentStatus()` 的 `connected`）
///   2. 可达性探测（`JwxtClient.checkCampusNameServerReachable()`）
///   3. 各页面自己读 `campusEnvironment.online` 后的本地判断
///
/// 没有任何一处是权威的，于是每个调用点都要自己决定"补测几次"，
/// 代码里散落着 `_probeReachable(attempts: 2)` / `(attempts: 3)` /
/// `(connected ? 2 : 1)` 这类魔法补丁。本文件把这三者收敛成一个状态机，
/// 对外只暴露 [phase]，探测重试策略内聚在内部。
///
/// ## 状态含义
///
/// ```
/// idle ──connect()──▶ preparing ──▶ tunnelUp ──▶ gatewayReady ──▶ online
///   ▲                     │            │              │              │
///   └────disconnect()─────┴────────────┴──────────────┴──── failed ──┘
/// ```
///
/// - [VpnPhase.tunnelUp]：原生层报告 `connected`，但**还没验证**网关可用。
/// - [VpnPhase.gatewayReady]：内网 HTTP 探测通过，可以发教务请求了。
/// - [VpnPhase.online]：[gatewayReady] 的稳定态（同一件事，用于 UI 显示）。
///
/// 之所以把 tunnelUp 与 gatewayReady 分开，是因为原生 `connected` 只代表
/// 隧道任务建立，不代表网关会话就绪 —— 这一点在旧代码注释里反复出现，
/// 却没有任何类型层面的表达。
enum VpnPhase {
  /// 未连接，也没有正在进行的操作。
  idle,

  /// 正在认证 / 建隧道 / 等虚拟 IP。
  preparing,

  /// 隧道已建立，尚未确认网关可达。
  tunnelUp,

  /// 网关已确认可达。
  online,

  /// 最近一次操作失败，[VpnSession.failure] 有原因。
  failed,
}

/// 失败原因。**不要用字符串匹配判断错误类型**。
///
/// 改造前 `campus_vpn.dart` 靠 `'no physical ipv4 default route'` 这类
/// 英文子串决定是否重试，`auth_pages.dart` 又靠中文子串决定给用户看什么，
/// 任何一次文案调整都会静默破坏控制流。改为枚举后，文案改动不再影响逻辑。
enum VpnFailure {
  /// 学号/密码错误（SAC 拒绝）。
  badCredentials,

  /// 网关响应超时（通常可重试）。
  gatewayTimeout,

  /// 隧道已停止 / 未建立。
  tunnelStopped,

  /// 上次未正常下线，Wintun 适配器尚未释放（可重试）。
  adapterBusy,

  /// 隧道通了但内网 HTTP 不可达（路由/DNS 问题）。
  gatewayUnreachable,

  /// 虚拟 IP 未下发。
  noVirtualIp,

  /// 用户尚未授予 Android 系统 VPN 权限。
  permissionDenied,

  /// 其它未分类错误。
  unknown,
}

extension VpnFailureText on VpnFailure {
  /// 给用户看的中文文案。集中在一处，避免同一错误在不同页面表述不一致。
  String get message {
    switch (this) {
      case VpnFailure.badCredentials:
        // ⚠️ 不要写成"请检查密码是否填错"。
        //
        // 学校网关对这几类情况返回的是同一个拒绝码：密码错、学号尚未在
        // 教务系统录入/开通、账号被停用、认证源不对。如果只说"检查密码"，
        // 那些**密码本来就正确**的学生会反复重输、以为系统坏了 —— 而我们
        // 把他们指向了一个永远不会成功的动作。
        return '学校网关拒绝了认证。请先确认密码是身份证后六位；'
            '若确认无误仍失败，通常是学号尚未在教务系统录入或开通，请联系辅导员处理';
      case VpnFailure.gatewayTimeout:
        return '学校加速器网关响应超时，请稍候重试';
      case VpnFailure.tunnelStopped:
        return '校园加速器隧道已停止，请重新认证';
      case VpnFailure.adapterBusy:
        return '上次没有正常下线，请再认证一次';
      case VpnFailure.gatewayUnreachable:
        return '加速器已连接，但教务服务器无响应，请重试';
      case VpnFailure.noVirtualIp:
        return '加速器已连接但虚拟 IP 未下发，请重试';
      case VpnFailure.permissionDenied:
        return '请在 Android 系统网络授权对话框中允许稽之查，然后再次点击连接';
      case VpnFailure.unknown:
        return '加速器连接失败，请重试';
    }
  }

  /// 是否值得自动重试。凭据错误重试多少次都是错的，不要浪费用户时间。
  bool get isRetryable {
    switch (this) {
      case VpnFailure.badCredentials:
      case VpnFailure.permissionDenied:
        return false;
      case VpnFailure.gatewayTimeout:
      case VpnFailure.tunnelStopped:
      case VpnFailure.adapterBusy:
      case VpnFailure.gatewayUnreachable:
      case VpnFailure.noVirtualIp:
      case VpnFailure.unknown:
        return true;
    }
  }
}

/// 把任意异常归类成 [VpnFailure]。
///
/// 这里**只做一次**字符串匹配（在异常边界上不可避免，因为 Rust 侧错误
/// 是文本形式的），归类之后全项目都按枚举判断。旧代码是在**多个决策点**
/// 反复匹配子串，那才是脆弱的根源。
VpnFailure classifyVpnError(Object error) {
  final m = '$error'.toLowerCase();
  if (m.contains('wintunstartsession failed') ||
      m.contains('failed to create wintun adapter')) {
    return VpnFailure.adapterBusy;
  }
  if (m.contains('no physical ipv4 default route')) {
    return VpnFailure.gatewayUnreachable;
  }
  if (m.contains('0x020004ab') || m.contains('sac login rejected')) {
    return VpnFailure.badCredentials;
  }
  if (m.contains('gateway session setup timed out')) {
    return VpnFailure.gatewayTimeout;
  }
  if (m.contains('虚拟 ip 未下发')) return VpnFailure.noVirtualIp;
  if (m.contains('隧道已停止')) return VpnFailure.tunnelStopped;
  if (m.contains('无 http 响应')) return VpnFailure.gatewayUnreachable;
  if (m.contains('网络授权') || m.contains('系统网络授权')) {
    return VpnFailure.permissionDenied;
  }
  if (m.contains('timeout') || m.contains('超时')) {
    return VpnFailure.gatewayTimeout;
  }
  return VpnFailure.unknown;
}

/// 内网可达性探测函数。由 main.dart 注入 `JwxtClient` 的实现，
/// 避免本文件反向依赖网络层（这里的依赖方向是刻意保留的：
/// 网络客户端比状态机更底层，且状态机需要被单测，不能拖上 Dio）。
typedef CampusProbe = Future<bool> Function({required Duration timeout});

/// [VpnSession] 需要的加速器原生能力。
///
/// 抽出接口是为了让状态机**可测**：改造前连接逻辑直接 `new` 出真实
/// `CampusVpnLauncher`，测试里必然触发 MethodChannel / FFI，跑不起来。
abstract class CampusVpnLauncherAdapter {
  Future<void> connect({
    required String username,
    required String password,
    String? authSource,
    void Function(String message)? onProgress,
  });

  Future<void> disconnect();

  /// 当前隧道状态；读取失败时返回 null（视为未连接）。
  Future<Map<String, dynamic>?> currentStatus();
}

/// 让真实的 [CampusVpnLauncher] 满足上面的接口。
class _LauncherAdapter implements CampusVpnLauncherAdapter {
  _LauncherAdapter(this._inner);

  final CampusVpnLauncher _inner;

  @override
  Future<void> connect({
    required String username,
    required String password,
    String? authSource,
    void Function(String message)? onProgress,
  }) =>
      _inner.connect(
        username: username,
        password: password,
        authSource: authSource,
        onProgress: onProgress,
      );

  @override
  Future<void> disconnect() => _inner.disconnect();

  @override
  Future<Map<String, dynamic>?> currentStatus() => _inner.currentStatus();
}

/// 加速器会话状态机。
class VpnSession extends ChangeNotifier {
  VpnSession({
    required CampusProbe probe,
    CampusVpnLauncherAdapter? launcher,
  })  : _probe = probe,
        _launcher = launcher ?? _LauncherAdapter(CampusVpnLauncher());

  final CampusProbe _probe;
  final CampusVpnLauncherAdapter _launcher;

  VpnPhase _phase = VpnPhase.idle;
  VpnFailure? _failure;
  String? _virtualIp;

  /// 隧道建立后回调虚拟 IP。
  ///
  /// 由 main.dart 注入到 `JwxtClient.setVpnSourceAddress` —— 教务请求必须
  /// 绑定到隧道分配的虚拟 IP，否则会被系统的 TUN（如 FlClash）抢走。
  /// `CampusVpnLauncher` 内部也会经 `onSourceAddressChanged` 同步一次，
  /// 这里再兜一次是为了覆盖"状态机被单独使用"的场景。
  void Function(String? virtualIp)? onTunnelEstablished;

  /// 连接过程中的进度文案（"正在认证…"之类），仅用于 UI 展示，不参与判断。
  String? _progress;

  VpnPhase get phase => _phase;
  VpnFailure? get failure => _failure;
  String? get virtualIp => _virtualIp;
  String? get progress => _progress;

  /// 是否正在执行操作（连接或断开）。UI 用这个禁用按钮。
  bool get busy => _phase == VpnPhase.preparing;

  /// 是否可以认为校园网可用。**这是全项目唯一的判据。**
  bool get online => _phase == VpnPhase.online;

  /// 隧道已建立但网关还没确认。UI 可显示"连接中…"。
  bool get tunnelUp => _phase == VpnPhase.tunnelUp;

  void _set(VpnPhase phase, {VpnFailure? failure, String? progress}) {
    final changed = _phase != phase || _failure != failure;
    _phase = phase;
    _failure = failure;
    _progress = progress;
    if (changed) notifyListeners();
  }

  /// 只更新进度文案，不改变状态机位置。
  void _setProgress(String? text) {
    if (_progress == text) return;
    _progress = text;
    notifyListeners();
  }

  /// 连接。成功时 [phase] 到达 [VpnPhase.online]，失败时到达
  /// [VpnPhase.failed] 并设置 [failure]（**不抛异常**，调用方读状态即可）。
  ///
  /// 之所以不抛异常：旧实现把异常从 `_openTarget` 抛到 `_connect` 的 catch，
  /// 中间又用字符串重新分类一次，路径难追。改为状态机后，调用方
  /// `await session.connect(...)` 然后读 `session.failure` 就够了。
  ///
  /// ## ⚠️ 关于"是否要用探测把关连接成功"
  ///
  /// **不要把探测失败当成连接失败。** 这是本文件第一版犯过的错（真机上
  /// 表现为"加速器已连接，但教务服务器无响应，请重试"，而隧道其实是好的）。
  ///
  /// 原因：`ns.huse.cn` 的 HTTP 探测**本身就不稳定**（`jwxt_client.dart`
  /// 的注释、`campus_environment.dart` 的历史注释都反复提到这点），而
  /// 隧道刚建立时 DNS 还没预热。旧流程从来没在 `connect()` 里做这件事 ——
  /// 它把验证交给 `_openTarget` 里的 `waitForIntranet`（30 秒、对**真正
  /// 要用的教务端点**轮询、约 6 次机会）。
  ///
  /// 现在的分工：
  ///   - `connect()` 只负责把隧道建起来，到达 [VpnPhase.tunnelUp] 即算成功；
  ///   - 探测**只用于把状态提升到 [VpnPhase.online]**（UI 显示"在线"、
  ///     健康检查判断是否需要重连），探测不通过就停在 `tunnelUp`；
  ///   - 真正的可用性判定仍由调用方的 `waitForIntranet` 负责，它对**目标
  ///     端点**探测，比这里对 `ns.huse.cn` 探测更贴近"能不能用"。
  ///
  /// 返回 `true` 表示**隧道已建立**（不等于网关已验证）。
  Future<bool> connect({
    required String username,
    required String password,
    String authSource = 'SAM-all',
  }) async {
    if (_phase == VpnPhase.preparing) return false;
    _set(VpnPhase.preparing, progress: '正在启动校园加速器…');
    try {
      await _launcher.connect(
        username: username,
        password: password,
        authSource: authSource,
        onProgress: _setProgress,
      );
      // 隧道已建立。源地址由 CampusVpnLauncher 内部经 onSourceAddressChanged
      // 同步给 JwxtClient（在 connect 返回前完成），这里再兜一次，确保后续
      // 教务请求绑定到正确的虚拟 IP。
      _virtualIp = await _readVirtualIp();
      onTunnelEstablished?.call(_virtualIp);

      // 探测只用来"提升"状态，不用来"否决"连接。
      _set(VpnPhase.tunnelUp, progress: '正在验证校园内网连通性…');
      final reachable = await _probeWithRetry();
      _set(reachable ? VpnPhase.online : VpnPhase.tunnelUp);
      return true;
    } catch (error) {
      _set(VpnPhase.failed, failure: classifyVpnError(error));
      return false;
    }
  }

  /// 断开并回到 [VpnPhase.idle]。
  Future<void> disconnect() async {
    try {
      await _launcher.disconnect();
    } catch (_) {
      // 断开失败也要落到 idle：否则 UI 会永远卡在"连接中"。
    }
    _virtualIp = null;
    _set(VpnPhase.idle);
  }

  /// 重新探测当前链路是否仍然可用，用于健康检查。
  ///
  /// 返回 false 时**不会**自动重连，只是把状态纠正为 [VpnPhase.idle] —— 
  /// 是否重连由调用方（健康检查）决定，见 [CampusEnvironmentController]。
  Future<bool> recheck() async {
    if (_phase != VpnPhase.online && _phase != VpnPhase.tunnelUp) return false;
    final reachable = await _probeWithRetry();
    if (reachable) {
      if (_phase != VpnPhase.online) _set(VpnPhase.online);
      return true;
    }
    _set(VpnPhase.idle);
    return false;
  }

  /// 同步原生层状态到本状态机（用于 App 启动后首次探测）。
  ///
  /// 原生报告 connected 时**不直接置 online**，而是先探测网关 —— 这正是
  /// 旧代码 `_detectInternal` 里那段"隧道报告 connected 时多补测一次"
  /// 注释想表达的事，现在它成了类型层面的必然行为。
  Future<void> syncFromNative() async {
    try {
      final status = await _launcher.currentStatus();
      final connected = status?['connected'] == true;
      if (!connected) {
        _virtualIp = null;
        if (_phase != VpnPhase.preparing) _set(VpnPhase.idle);
        return;
      }
      _virtualIp = status?['virtual_ip']?.toString();
      if (_phase == VpnPhase.online) return; // 已是稳定态，不打扰
      _set(VpnPhase.tunnelUp);
      final reachable = await _probeWithRetry();
      _set(reachable ? VpnPhase.online : VpnPhase.idle);
    } catch (_) {
      // 状态接口异常不应改变已有状态。
    }
  }

  Future<String?> _readVirtualIp() async {
    for (var attempt = 0; attempt < 5; attempt++) {
      final status = await _launcher.currentStatus();
      final ip = status?['virtual_ip']?.toString();
      if (ip != null && ip.isNotEmpty) return ip;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return null;
  }

  /// 带补测的探测。
  ///
  /// 补测是必要的：单次探测只有几秒预算，却要覆盖 DNS 解析加一次完整
  /// HTTP 往返，隧道刚建立时很容易不够。改造前这个"补测几次"由每个调用点
  /// 自己决定（2 次/3 次/按 connected 决定），现在收敛到这里。
  ///
  /// ⚠️ 预算给得比较宽松（约 20 秒），因为 `ns.huse.cn` 探测本身不稳定，
  /// 而**这个探测的结果只影响"是否显示在线"，不会否决连接**（见 [connect]）。
  /// 宁可多等几秒拿到准确状态，也不要因为一次超时就报"服务器无响应"。
  Future<bool> _probeWithRetry({
    int attempts = 4,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        if (await _probe(timeout: timeout)) return true;
      } catch (_) {
        // 探测本身抛异常一律视为本次失败，继续补测。
      }
      if (attempt + 1 < attempts) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    }
    return false;
  }
}
