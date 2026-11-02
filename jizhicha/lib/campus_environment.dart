import 'dart:async' show Timer;
import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:io' show Directory, File, Platform;

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory;

import 'app_settings.dart';
import 'campus_vpn.dart';
import 'credential_store.dart';
import 'vpn_session.dart';

/// 「保持校园网存活」意图的持久化后端。
///
/// 只存一个布尔值，**不含**账号、密码、学号、虚拟 IP（隐私红线）。
/// 抽成接口有两个目的：
///   1. 宿主单测可以注入内存实现，不必拉起 `path_provider` 插件；
///   2. 将来若要把这个标志并进 `AppSettings`，只要换一个实现，
///      本文件之外没有任何调用点需要改。
abstract class CampusKeepAliveStore {
  const CampusKeepAliveStore();

  /// 读取已持久化的意图。**返回 null 表示从来没有记录过**（即本次改动之前
  /// 安装的旧版本），调用方据此决定要不要用别的证据推断初始意图。
  Future<bool?> load();

  Future<void> save(bool value);
}

/// 默认实现：独立的一个小 JSON 文件。
///
/// 目录规则与 `app_settings.dart` 完全一致（Windows 用 `%APPDATA%`，其它平台
/// 用 `path_provider` 的应用文档目录），但**不复用它的文件**：`app_settings.dart`
/// 不在本次允许修改的清单里，而它的 schema（`_schemaVersion`）是设置页共用的，
/// 从外部追加字段会静默影响设置页的读写。独立文件里只有一个布尔值，
/// 任何一侧出错都不会牵连另一侧。
class CampusKeepAliveFileStore implements CampusKeepAliveStore {
  const CampusKeepAliveFileStore();

  static const _fileName = 'jizhicha_campus_keep_alive.json';

  static Future<File> _file() async {
    final Directory folder;
    if (Platform.isWindows) {
      final base =
          Platform.environment['APPDATA'] ??
          Platform.environment['HOME'] ??
          Directory.current.path;
      folder = Directory(base);
    } else {
      folder = await getApplicationDocumentsDirectory();
    }
    try {
      if (!await folder.exists()) await folder.create(recursive: true);
    } catch (_) {
      // 目录建不出来时后面的读写会各自失败并被吞掉，不影响本次运行。
    }
    return File('${folder.path}${Platform.pathSeparator}$_fileName');
  }

  @override
  Future<bool?> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final value = decoded['keepAlive'];
      if (value is! bool) return null;
      return value;
    } catch (_) {
      // 读不到/读坏了都当成"没有记录"，交给调用方用凭据推断。
      // 宁可少自动连一次，也不要凭空替用户连上。
      return null;
    }
  }

  @override
  Future<void> save(bool value) async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode({'keepAlive': value}));
    } catch (_) {
      // 持久化失败只影响"下次启动是否自动连"，不影响本次运行。
    }
  }
}

/// 校园网络状态的门面。
///
/// 改造后它**不再自己判断在线与否** —— 那件事由 [VpnSession] 唯一负责。
/// 本类只做四件事：
///   1. 持有 [VpnSession] 并把它的通知转发给 UI；
///   2. 周期性健康检查（发现掉线 → 尝试静默重连）；
///   3. 记住"刚刚掉线过"这一一次性事件，供 UI 弹提示；
///   4. 维护「保持校园网存活」这个**显式意图**（见 [keepAlive]），
///      它决定第 2 步到底允不允许自动重认证；
///   5. 应用回到前台时**立刻**做一次健康检查（见 [handleAppResumed]）——
///      第 2 步那两个定时器在后台并不可靠，不能只依赖它们；
///   6. 持有设置里的**总闸**「打开 App 后自动连接校园网」（见
///      [autoConnectEnabled]）——它决定第 2/5 步允不允许**自动发起认证**。
///
/// ## 两层意图，各管一件事（不要混成一套真相）
///
/// | 层 | 存在哪 | 语义 | 谁写 |
/// |---|---|---|---|
/// | **总闸** `autoConnectCampus` | `app_settings.dart` 的 `settings.json` | "这个 App 允不允许自己发起认证" | 只有设置页的开关 |
/// | **意愿** `keepAlive` | 独立的 `jizhicha_campus_keep_alive.json` | "用户上一次是想要校园网通着，还是明确断开了" | 认证成功置 true、主动登出置 false |
///
/// 判定顺序（[ensureCampusAlive] / [_reconnectSilently] 里逐条落地）：
/// 1. **手动**（`silent: false` / 界面上的连接按钮）→ 一律放行，两个意图都不看；
/// 2. **总闸关** → 所有自动路径都不发起认证（不论 [keepAlive] 是什么）；
/// 3. 总闸开 + [keepAlive] false → 用户明确断开过，不自动连（与今天的行为一致）；
/// 4. 总闸开 + [keepAlive] true → 照旧自动认证，并受退避阶梯与
///    [_autoRetrySuppressed] 约束。
///
/// 两层**互不写对方**：关总闸不等于断网（不碰隧道、不改 [keepAlive]），
/// 主动登出也不改总闸（用户只是这次不想要，而不是取消"以后自动连"的偏好）。
/// 唯一的方向性例外是"总闸打开"本身不改 [keepAlive] —— 那是作者要求的
/// "总闸开 = 现有行为"。
///
/// 这样课表页、成绩页读到的 `online` 与状态机完全一致，不会再出现
/// "一个页面说在线、另一个说离线"的矛盾。
class CampusEnvironmentController extends ChangeNotifier {
  CampusEnvironmentController({
    VpnSession? session,
    this.keepAliveStore = const CampusKeepAliveFileStore(),
    this.loadVpnAccounts = _loadStoredVpnAccounts,
    this.loadAutoConnectCampus = _loadAutoConnectCampusSetting,
  }) : session = session ?? VpnSession(probe: _missingProbe) {
    this.session.addListener(_onSessionChanged);
    _intentReady = _restoreKeepAliveIntent();
    _autoConnectReady = _refreshAutoConnectCampus(force: true);
    startHealthMonitor();
  }

  /// 未注入探测函数时的兜底：永远探测失败。
  ///
  /// 生产环境在 `main()` 里通过 [configure] 注入真实实现（`JwxtClient`）。
  static Future<bool> _missingProbe({required Duration timeout}) async => false;

  /// 读本机保存的加速器凭据。默认走 [CredentialStore]（安全存储）。
  ///
  /// 做成可注入的**唯一**原因是让"退避节流"这条最容易出错的逻辑能在宿主上
  /// 被真正跑到：`FlutterSecureStorage` 是平台插件，单测里必然读不到东西，
  /// 于是静默重连会停在"没有凭据"上，永远走不到真正发起认证那一步。
  static Future<List<StoredAccount>> _loadStoredVpnAccounts() =>
      CredentialStore.load(StoredAccountKind.vpn);

  final Future<List<StoredAccount>> Function() loadVpnAccounts;

  /// 读设置里的**总闸**「打开 App 后自动连接校园网」。
  ///
  /// 与 [loadVpnAccounts] 同理，做成可注入的**唯一**理由是让"总闸关掉之后
  /// 自动路径一条都不许走"这件事能在宿主上被真正跑到：默认实现会读
  /// `app_settings.dart` 的真实 `settings.json`，单测里那样会污染用户设置文件。
  ///
  /// 默认实现返回 `false`（[AppSettings.autoConnectCampus] 的默认值），
  /// 所以**任何读不出来/读失败的情况都落到"不自动连"** —— 安全方向：
  /// 宁可少自动连一次，也不要凭空替用户连上。
  final Future<bool> Function() loadAutoConnectCampus;

  static Future<bool> _loadAutoConnectCampusSetting() async {
    try {
      return (await AppSettings.load()).autoConnectCampus;
    } catch (_) {
      return false;
    }
  }

  /// 总闸是否已从设置里读过一次。所有自动路径都要先等它，
  /// 否则冷启动头几秒会把"还没读出来的 false"当成结论。
  late final Future<void> _autoConnectReady;

  /// 总闸当前值（最近一次读到的设置）。默认 `false` = 不自动连。
  bool _autoConnectCampusEnabled = false;

  /// 上次真正读设置的时刻，用于给 10 秒快探测那条路径做读取节流
  /// （见 [_refreshAutoConnectCampus] 的 `force`）。
  DateTime? _autoConnectReadAt;

  /// 两次非强制读取之间的最小间隔。
  ///
  /// 为什么需要：快探测每 10 秒 tick 一次，而 `AppSettings.load()` 在 Android 上
  /// 每次都会走一次 `path_provider` 平台通道 + 读一个小 JSON。总闸是个用户手动
  /// 拨的开关，晚 20 秒生效没有任何实际影响，没必要每 10 秒问一次磁盘。
  static const Duration _autoConnectRefreshInterval = Duration(seconds: 20);

  /// 设置里的总闸当前是否打开（只读，供 UI/单测断言用）。
  bool get autoConnectEnabled => _autoConnectCampusEnabled;

  /// 重新读一次设置里的总闸。
  ///
  /// [force] 为真时无视节流 —— 只在"用户刚做了可能改过设置的动作"时用
  /// （回到前台、启动、手动连接），保证拨完开关回到 App 立刻生效。
  ///
  /// 读失败**不改**当前值：`AppSettings.load()` 自己会把读不出来的文件降级成
  /// 默认设置（总闸 false），那已经是安全方向；这里再兜一层 catch，
  /// 避免"设置文件损坏"把控制器打成异常路径。
  Future<void> _refreshAutoConnectCampus({bool force = false}) async {
    if (_disposed) return;
    final now = DateTime.now();
    final last = _autoConnectReadAt;
    if (!force && last != null && now.difference(last) < _autoConnectRefreshInterval) {
      return;
    }
    _autoConnectReadAt = now;
    final bool enabled;
    try {
      enabled = await loadAutoConnectCampus();
    } catch (_) {
      return;
    }
    if (_disposed) return;
    if (_autoConnectCampusEnabled == enabled) return;
    _autoConnectCampusEnabled = enabled;
    if (enabled) {
      // 用户刚把总闸拨到"开"：这就是一次明确的"我要它自动连"的表示，所以
      // 立刻把本会话的暂停与退避阶梯清零 —— 否则他打开开关后仍要等 5 分钟
      // 退避窗口（甚至要重启 App）才看见效果，开关看起来是坏的。
      //
      // 刻意**不动** [keepAlive]：总闸只管"允不允许自动认证"，不改写
      // "用户上次是想要还是断开"那份记录（见类文档的优先级表）。
      _reconnectFailures = 0;
      _nextReconnectAt = null;
      _autoRetrySuppressed = false;
      _suppressedBy = null;
      // 开关拨开但用户上次明确断开过：这时不该自己连（第 3 条优先级）。
      // 不发通知也没法提示（设置页不在本文件的可改范围），但至少让
      // 下一次 ensureCampusAlive 如实返回 false，不假装在努力。
    }
    _notify();
  }

  VpnSession session;

  /// 「保持校园网存活」意图的落盘后端。可注入，宿主单测用内存实现即可。
  final CampusKeepAliveStore keepAliveStore;

  /// 意图是否已经从磁盘恢复完成。所有"要不要自动重连"的判断都要先等它，
  /// 否则冷启动头几秒会把"还没读出来的 true"当成 false。
  late final Future<void> _intentReady;

  bool _reconnecting = false;
  Timer? _healthTimer;
  Timer? _fastTimer;
  bool _dropDetected = false;

  /// 用户是否希望校园网一直通着。
  ///
  /// **置 true**：一次认证成功、隧道建立时（由 [configure] 安装的
  /// `CampusVpnLauncher.onSourceAddressChanged` 回调观察到）。用户手动连一次
  /// 成功的语义就是"我要它通着"，所以之后掉线可以静默补认证。
  ///
  /// **置 false**：用户主动登出（[logout]）或从别处显式拆掉隧道
  /// （例如 `campus_navigator_page.dart` 的「断开加速器」直接调
  /// `CampusVpnLauncher().logout()`，不经过本控制器 —— 那条路径只能靠上面
  /// 那个回调看到）。置 false 之后**绝不**再静默连接，直到用户再次手动连上。
  ///
  /// 该值跨进程持久化（见 [CampusKeepAliveStore]），因此重启 App 后
  /// [ensureCampusAlive] 能立刻知道用户上次的意愿；旧版本升上来的第一次启动
  /// 还没有记录，那时按"本机是否存有加速器凭据"推断（见
  /// [_restoreKeepAliveIntent]）。
  bool get keepAlive => _keepAlive;

  bool _keepAlive = false;

  /// 磁盘上的意图是否已被内存里的值覆盖过（防止慢加载把"刚登出"刷回 true）。
  bool _intentTouched = false;

  /// 回调是否已经接管过（[configure] 可能被调用多次）。
  bool _launcherHookInstalled = false;

  /// 是否已经 dispose。异步回来的静默重连/意图回调据此停止通知。
  bool _disposed = false;

  /// 静默重连退避阶梯：首次掉线 **10 秒**后重试，之后 20s / 40s / 80s / 160s，
  /// **5 分钟**封顶。
  ///
  /// 为什么必须退避：学校网关是"同账号新会话踢掉旧会话"的语义，高频认证既
  /// 踢不活别人、又会把自己变成风控眼里的密码爆破（有临时封号风险）。
  static const Duration _reconnectFirstDelay = Duration(seconds: 10);
  static const Duration _reconnectMaxDelay = Duration(minutes: 5);

  /// 一次静默认证的硬上限（看门狗）。
  ///
  /// `VpnSession.connect()` 正常情况下有界（原生侧 60 秒 + 探测约 20 秒），
  /// 这个上限只是兜住"原生调用永远不返回"的极端情况：没有它，
  /// [_reconnecting] 会永远为真、按钮永远禁用 —— 正是要避免的"卡死"。
  static const Duration _silentConnectTimeout = Duration(seconds: 150);

  int _reconnectFailures = 0;

  /// 本次进程内是否已因「不可重试失败」暂停自动认证。
  ///
  /// ⚠️ 它与持久化的 [keepAlive] **语义不同，不要混用**：
  ///   - `keepAlive == false` = **用户明确不想保持连接**（只有主动登出才写盘）；
  ///   - 本标志 = **这次会话先别再试了**（凭据错 / 未授权），**不落盘**。
  ///
  /// 为什么必须分开：`permissionDenied` 完全可能是**瞬时的**（刚重装后的授权
  /// 窗口、系统里同时有另一个 VPN、用户误点了拒绝）。如果因此把持久化意图关掉，
  /// 用户的"保持校园网连接"意愿就被**永久遗忘** —— 表现就是"明明设置过，下次
  /// 打开却再也不自动认证了"。所以：只暂停本会话，下次启动照常尝试。
  bool _autoRetrySuppressed = false;

  /// 触发本次会话暂停的那一次失败类型（`null` = 没有暂停）。
  ///
  /// 存在的唯一原因是：[_autoRetrySuppressed] 需要**有恢复入口**，而两种
  /// 不可重试失败的可恢复性完全不同 —— 见 [handleAppResumed] 里的
  /// `_clearSuppressionOnResume`。
  VpnFailure? _suppressedBy;

  /// 下一次允许静默重连的时刻；null 表示"还没有安排"。
  DateTime? _nextReconnectAt;

  /// 上一次**真正发起**认证的时刻。只用于给"紧急"重连设下限，不参与退避阶梯。
  ///
  /// 见 [_reconnectSilently] 里的 `urgent`：冷启动 / 用户刚切回前台这类紧急
  /// 信号允许跳过退避等待，但两次紧急尝试之间至少隔 [_reconnectFirstDelay]，
  /// 否则反复切前后台会变成对学校网关的高频认证。
  DateTime? _lastAttemptAt;

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
    _installKeepAliveHook();
    _resetSession = resetSession;
    session.removeListener(_onSessionChanged);
    session.dispose();
    session = VpnSession(probe: probe)
      ..onTunnelEstablished = onTunnelEstablished;
    session.addListener(_onSessionChanged);
  }

  /// 接管 `CampusVpnLauncher.onSourceAddressChanged`（链式包装）。
  ///
  /// 为什么选这个回调：`campus_vpn.dart` 只在**两处**调用它 —— 认证成功
  /// （传入虚拟 IP）与有人显式拆掉隧道（传 null）。这正好是维护 keep-alive
  /// 意图所需的两个信号，而且是**精确**的：`campus_navigator_page.dart` 的
  /// 「断开加速器」直接调 `CampusVpnLauncher().logout()`，不经过本控制器，
  /// 只有这个回调能看见它。没有它，用户按了断开会被自动连回来，
  /// 变成一个"按不掉的开关"。
  ///
  /// 调用方是 `main.dart`：它先装好自己的回调（同步教务 HTTP 源地址），
  /// 再调 [configure]，所以这里做链式包装而不是直接覆盖。
  void _installKeepAliveHook() {
    if (_launcherHookInstalled) return;
    _launcherHookInstalled = true;
    final previous = CampusVpnLauncher.onSourceAddressChanged;
    CampusVpnLauncher.onSourceAddressChanged = (ip) {
      previous?.call(ip);
      _onLauncherSourceAddressChanged(ip);
    };
  }

  /// 隧道**建立成功**时置位「保持校园网存活」意图。
  ///
  /// 刻意**只在非空 IP 时**做判断。早先这里还有一条"收到 null 就当用户主动断开"
  /// 的启发式，用来兜住 `campus_navigator_page.dart` 绕过控制器的
  /// `CampusVpnLauncher().logout()`。那条启发式已被删除：
  ///
  ///   - 它会**误判**：`campus_vpn.dart` 的 `disconnect()` 在 `finally` 里无条件
  ///     回调 null（连 Android 上提前 return 的分支也走 finally），于是冷启动等
  ///     场景会把用户辛苦保存的意图**静默清成 false** —— 表现就是"明明设置过
  ///     保持校园网，下次打开却再也不自动认证了"（真机上复现过两次）。
  ///   - 它也不再必要：那条绕过路径现在会**显式**调
  ///     [clearKeepAliveIntent] 声明意图。
  ///
  /// 不变量见 [clearKeepAliveIntent] 的文档：新增拆隧道入口必须显式声明意图。
  void _onLauncherSourceAddressChanged(String? ip) {
    if ((ip ?? '').trim().isEmpty) return;
    // 隧道建立成功 ⇒ 用户希望校园网通着（手动连的、静默连的都一样）。
    _setKeepAlive(true);
  }

  /// 从磁盘恢复「保持校园网存活」意图。
  ///
  /// 磁盘上**没有记录**（本次改动之前安装的旧版本）时，用"本机是否存有加速器
  /// 凭据"推断初始意图：凭据只会在**一次成功认证之后**才写入
  /// （见 `auth/vpn_setup_page.dart` 里 `CredentialStore.save` 的位置），
  /// 所以"存着加速器凭据"确实等价于"用户在这台机器上成功连过校园网"。
  /// 没有凭据则一律 false —— 绝不能凭空替用户连上。
  ///
  /// 之后的意愿完全以落盘的值为准：用户一旦主动登出就会写下 false，
  /// 再也不会被这里的推断翻回 true。
  Future<void> _restoreKeepAliveIntent() async {
    final stored = await keepAliveStore.load();
    if (_intentTouched) return;
    if (stored != null) {
      _keepAlive = stored;
      return;
    }
    _keepAlive = await _hasStoredVpnCredentials();
  }

  Future<bool> _hasStoredVpnCredentials() async {
    try {
      final accounts = await loadVpnAccounts();
      return accounts.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// 写入并持久化「保持校园网存活」意图。
  Future<void> _setKeepAlive(bool value) async {
    _intentTouched = true;
    if (value) {
      // 连上了（或被显式要求保持）：退避阶梯与"本会话暂停"一起归零。
      // 放在相等判断之前：一次成功的（重新）认证本来就该清掉过去的失败计数。
      _reconnectFailures = 0;
      _nextReconnectAt = null;
      _autoRetrySuppressed = false;
      _suppressedBy = null;
    }
    if (_keepAlive == value) return;
    _keepAlive = value;
    await keepAliveStore.save(value);
    _notify();
  }

  Future<void> Function() _resetSession = () async {};

  void _onSessionChanged() => _notify();

  /// 已 dispose 时不再通知。
  ///
  /// 静默重连是**异步**的，而 `CampusVpnLauncher.onSourceAddressChanged` 这个
  /// 全局回调在任何时刻都可能被 `campus_vpn.dart` 调到（包括 App 正在退出、
  /// 控制器已经 dispose 之后）。ChangeNotifier 在 debug 下会因为
  /// "used after being disposed" 直接断言失败，这里挡掉。
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  // ---- 对 UI 暴露的只读状态（全部代理到状态机）----

  VpnPhase get phase => session.phase;

  /// 是否正在连接。UI 用它禁用按钮 / 显示 spinner。
  bool get checking => session.busy;

  bool get actionLoading => session.busy;

  bool get reconnecting => _reconnecting;

  /// 校园网是否可用。**唯一判据来自状态机。**
  bool? get online => session.online;

  /// **仅供界面展示**：校园加速器（原生隧道）是否已经建立。
  ///
  /// ⚠️ 这**不是**逻辑门禁。任何"能不能发教务请求 / 能不能同步 / 按钮该不该
  /// 禁用"的判断都必须继续用 [online]，本 getter 只允许出现在文案与图标里。
  ///
  /// 为什么展示层需要它：`online` 只覆盖"隧道通了**并且**内网探测也通过"这一
  /// 种情况，于是「隧道已建立、只是校园网探测暂时不通」与「根本没有隧道」在
  /// `online` 上完全一样 —— 文案过去把两者都写成「离线模式」。真机表现就是
  /// "TUN 在、前台服务在跑、原生 status 报 connected，界面却说离线"。
  ///
  /// 判据取二选一（都只**读**状态机已有的公开状态，不写字段、不发请求）：
  ///   1. [VpnSession.tunnelUp] —— 刚认证完、探测还没通过（连接流程内的状态）；
  ///   2. [VpnSession.virtualIp] 非空 —— 原生状态里报过 `connected` 且下发过
  ///      虚拟地址，状态机据此认为"隧道身份成立"。
  ///
  /// 第 2 条是必需的，不能只判 `tunnelUp`：`syncFromNative()` 在"原生报
  /// connected 但探测失败"时会把 phase 落回 [VpnPhase.idle]（见
  /// `vpn_session.dart` 与单测『原生 connected 但网关不可达时不置 online』），
  /// 那时隧道其实还在，只是**没有任何 phase 能表达它**，只剩虚拟地址这条已有
  /// 证据可用。它由 `_clearTunnelIdentity()` 在"原生报未连接 / 主动断开 /
  /// 连接失败"时立即清空，所以真的断开后不会长期残留（最迟一个健康检查周期
  /// 即 60 秒内归零）。
  bool get acceleratorUp =>
      session.tunnelUp || (session.virtualIp ?? '').isNotEmpty;

  String? get failureMessage => session.failure?.message;

  /// 完整状态文案（账号摘要用）。
  ///
  /// 分支顺序即优先级：
  ///   1. 重连中 / 2. 正在检测 —— 这两条表示"有操作在跑"，与隧道状态无关，
  ///      所以排在最前；
  ///   3. 校园网可用；4. 加速器已连接但校园网待确认；5. 真的离线。
  ///
  /// 第 4 条是本次修正的核心：它把"有隧道、探测没通过"从「离线模式」里摘出来，
  /// 不再与"根本没有隧道"共用同一句话。
  String get statusSummary {
    if (_reconnecting) return '重连中';
    if (session.busy) return '正在检测校内环境';
    if (session.online) return '校园网可用';
    if (acceleratorUp) return '校园加速器已连接，正在确认校园网';
    return '离线模式';
  }

  /// 短状态文案（顶部小字用）。与 [statusSummary] 同构，只是更短。
  String get statusShort {
    if (_reconnecting) return '重连中';
    if (session.busy) return '检测中';
    if (session.online) return '校园网在线';
    if (acceleratorUp) return '加速器已连接';
    return '离线模式';
  }

  /// 重新同步一次状态。
  Future<void> detect() => session.syncFromNative();

  /// 应用**回到前台**时调用一次（由 `main.dart` 的 `WidgetsBindingObserver`）。
  ///
  /// ## 为什么必须有这个入口
  ///
  /// 自动重连的两个决策定时器（10 秒快探测 / 60 秒慢探测）都是 Dart
  /// `Timer.periodic`。Android 上进程不会因为进入后台就被 Flutter 挂起 isolate，
  /// 所以只要进程活着、CPU 被调度到，定时器仍会触发；但息屏 + 静止时系统会挂起
  /// CPU、Doze 会限制网络、国产 ROM 还会冻结或清理后台进程，定时器因此可能被拖到
  /// 几分钟甚至不再触发。用户"锁屏一会儿、切回来发现校园网断了且不会自己好"
  /// 正是这个表现 —— 回到前台这一刻是唯一**确定**会发生的时机，必须马上自己查。
  ///
  /// ## 顺序是有讲究的（对应 H5）
  ///
  /// 1. 先与原生同步一次（等价于 [detect]）；
  /// 2. 原生 stage 报 `heartbeat_error` / `tunnel_stopped`（**网关会话已死，
  ///    但隧道还在**）→ 立刻重认证；
  /// 3. 状态机自认在线 → 复核一次（探测失败说明会话可能已死）→ 失败立刻重认证；
  /// 4. 离线且原生确认隧道真的没了 → 立刻重认证。
  ///
  /// 第 2 步**必须排在"状态机是否在线"之前**：网关会话过期时原生 `connected`
  /// 仍是 true、虚拟地址也还在，`syncFromNative()` 会认为"已经是稳定态"直接返回，
  /// 单靠探测判据可能在"隧道在、网关会话已死"时误判为在线而永不重认证。
  ///
  /// 重认证按"紧急"处理（`ignoreBackoff`）：用户就在屏幕前等着，不能被后台期间
  /// 累积出来的 5 分钟退避窗口拖住。反复切前后台由 [_reconnectSilently] 内的
  /// 紧急尝试下限兜住，不会退化成高频认证。
  ///
  /// **永远不会越过「用户主动断开」的意图**：[keepAlive] 为 false 时
  /// [_reconnectSilently] 直接返回，这里不做任何例外。同理也**不会越过总闸**：
  /// 白天把「打开 App 后自动连接校园网」关掉之后，来回切前后台不会自己认证。
  /// 注意第 1 步的原生同步与第 3 步的复核**照旧执行** —— 那是"看"，
  /// 不是"连"；总闸关着时若隧道被别处拆掉，界面仍要如实显示成离线。
  Future<void> handleAppResumed() async {
    if (_disposed) return;
    // 0) 先刷新总闸。用户很可能就是去系统设置里拨完开关再切回来的，
    //    这里不能沿用后台期间那份可能已经过时的值（`force: true` 绕过节流）。
    await _autoConnectReady;
    await _refreshAutoConnectCampus(force: true);
    if (_disposed) return;
    // 0') 给出"暂停自动认证"的恢复入口，见 [_clearSuppressionOnResume]。
    _clearSuppressionOnResume();
    // 1) 立刻同步一次：把"隧道还在不在 / 虚拟地址还在不在"拉回来。
    await session.syncFromNative();
    if (_disposed || session.busy || _reconnecting) return;

    // 2) 网关会话已死（心跳失败）→ 唯一出路是重新认证。
    if (await _nativeReportsGatewayDead()) {
      await _reconnectSilently(ignoreBackoff: true);
      return;
    }
    // 3) 状态机自认在线：复核一次。不复核就可能一直显示"校园网可用"却用不了。
    if (session.online) {
      if (!await session.recheck()) {
        await _reconnectSilently(ignoreBackoff: true);
      }
      return;
    }
    // 4) 离线：只有原生确认隧道真的没了才重认证 —— 与 [_silentHealthCheck] 同一
    //    判据（一次内网探测抖动不该把一条还活着的隧道顶掉）。状态读不到
    //    （null）时什么都不做，宁可等下一次探测。
    final status = await CampusVpnLauncher().currentStatus();
    if (_disposed) return;
    if (status != null && status['connected'] != true) {
      await _reconnectSilently(ignoreBackoff: true);
    }
  }

  /// 回到前台时，把**可能已经被用户从外部修好**的那一类暂停清掉。
  ///
  /// ## 为什么需要（这是"自动连接还有问题"的一个具体失败路径）
  ///
  /// [_autoRetrySuppressed] 是**进程级**的：不可重试失败（
  /// [VpnFailure.isRetryable] 为 false）会把它置 true，而只有
  /// [clearKeepAliveIntent]、[_setKeepAlive] 成功、总闸由关变开这三件事会清它。
  /// 于是出现这条死路：
  ///
  /// 1. 用户点了连接，Android 弹出系统 VPN 授权框，他没看清就按了「取消」
  ///    → `permissionDenied` → 本次会话内**自动重连彻底停摆**；
  /// 2. 用户随后在系统里授予了权限（或重新点一次连接成功了）；
  /// 3. 但这条隧道之后真断了时，自动路径仍被第 1 步那个标志挡住，
  ///    直到杀进程重启 —— 用户看到的现象是"自动连接时好时坏/干脆不连了"。
  ///
  /// 而 [VpnFailure.permissionDenied] 恰好是**唯一**明显可由用户在系统 UI 里
  /// 修好的失败类型，所以每次回到前台都允许它重试一次是安全且必要的。
  ///
  /// ## 为什么 [VpnFailure.badCredentials] 不在此列
  ///
  /// 密码错不会因为"过了十分钟"或"切了一次前后台"而变对，无脑重置只会
  /// 让 App 每隔一会儿就拿错的凭据去撞一次学校网关。学校网关是
  /// "同账号新会话踢掉旧会话"的语义，这种无谓认证还可能顶掉别的设备
  /// 上那条好的会话。凭据错的恢复入口是**手动连接**（
  /// [ensureCampusAlive]`(silent: false)` 会清暂停）—— 那表示用户已经
  /// 改过密码、真的要再试一次。
  ///
  /// 退避阶梯（[_reconnectFailures] / [_nextReconnectAt]）一起清零：只清暂停
  /// 不清退避的话，用户回到前台仍要等上一个 5 分钟窗口。
  ///
  /// 连 [_lastAttemptAt] 也清掉：它和 [_reconnectFirstDelay] 一起构成"两次紧急
  /// 尝试至少隔 10 秒"的下限（见 [_reconnectSilently] 的 `urgent`）。上一次尝试
  /// 属于"用户还没授权"的那段时间，把它留着会让刚授完权的用户回到前台后仍被
  /// 按 10 秒不连。这里不会因此变成"每次切前后台都认证一次"：暂停只可能被清
  /// 一次 —— 清掉之后要么连成功（暂停自然消失），要么再失败一次（立刻重新置
  /// 暂停并刷新 [_lastAttemptAt]），所以每个"暂停周期"最多多一次尝试。
  void _clearSuppressionOnResume() {
    if (!_autoRetrySuppressed) return;
    if (_suppressedBy != VpnFailure.permissionDenied) return;
    _autoRetrySuppressed = false;
    _suppressedBy = null;
    _reconnectFailures = 0;
    _nextReconnectAt = null;
    _lastAttemptAt = null;
  }

  /// 原生 stage 是否表示"网关会话已死、必须重新认证"。
  ///
  /// 与 [_fastGatewayWatch] 共用同一个事实来源，避免两处判据漂移：
  ///   - `heartbeat_error`：Rust 心跳续期失败（网关 15 分钟时限到期后必然发生），
  ///     此时原生 `connected` 仍是 true、隧道还在，只有重新认证能救；
  ///   - `tunnel_stopped` 且 `connected != true`：原生已判定隧道停止。
  ///
  /// 状态读不到（null / 抛异常）时返回 false：宁可等下一次探测，也不要凭猜测
  /// 重认证（学校是"同账号新会话踢掉旧会话"的语义，误重认证会顶掉一条好隧道）。
  Future<bool> _nativeReportsGatewayDead() async {
    try {
      final status = await CampusVpnLauncher().currentStatus();
      if (status == null) return false;
      final stage = status['stage']?.toString() ?? '';
      if (stage == 'heartbeat_error') return true;
      return stage == 'tunnel_stopped' && status['connected'] != true;
    } catch (_) {
      return false;
    }
  }

  /// **用户明确表示"我不要校园网了"** —— 落盘关掉「保持校园网存活」意图。
  ///
  /// 供那些**必须自己拆隧道**的调用方使用（典型是 `campus_navigator_page.dart`
  /// 的「断开校园加速器」：它要走 `CampusVpnLauncher().logout()` 以复用 Windows
  /// 上的「网关旧会话清理」，那是 [logout] 里 `session.disconnect()` 不做的）。
  ///
  /// ## ⚠️ 不变量：任何"用户主动断开"的路径都**必须**声明意图
  ///
  /// 早先的实现是靠监听 `CampusVpnLauncher.onSourceAddressChanged(null)` 去**猜**
  /// 用户意图（谁拆隧道就当谁登出）。那条启发式已被移除，因为它在冷启动等场景会
  /// 误判、把用户的意图**静默清成 false**，导致"明明设置过，下次打开却不再自动
  /// 认证"。现在改成显式声明：**新增任何拆隧道入口时，先调本方法。**
  /// 漏调的后果是那一条路径断开后会被自动连回来（一个按不掉的开关）。
  Future<void> clearKeepAliveIntent() async {
    _autoRetrySuppressed = false;
    _suppressedBy = null;
    await _setKeepAlive(false);
  }

  Future<void> logout() async {
    if (session.busy) return;
    // 用户主动登出 = 明确不要校园网了。**先落盘意图、再拆隧道**：
    // 即使 disconnect() 卡住，重启后也不会被静默连回来。
    await _setKeepAlive(false);
    await session.disconnect();
    await _resetSession();
  }

  /// 应用启动时调用一次：若用户此前希望保持校园网连接、且本机存有加速器
  /// 凭据，就静默认证一次。
  ///
  /// **返回值语义**：`true` 表示最终处于可用状态 —— 原生隧道已建立，
  /// 即 [online] 为真或 `session.tunnelUp` 为真（后者只代表内网探测还没通过，
  /// 隧道本身是好的）。
  ///
  /// **绝不在用户已主动登出后连接**：那时 [keepAlive]（含从磁盘恢复的值）
  /// 为 false，直接返回 false。本方法**不会**改写这个意图。
  ///
  /// **总闸关着就什么都不做**：[silent] 为 true 时先看设置里的
  /// [autoConnectEnabled]（「打开 App 后自动连接校园网」，默认关）——
  /// 关着就**连探测都不做**，立刻返回 false。这条判定放在本方法**和**
  /// [_reconnectSilently] 两处：这里省掉启动时那次无意义的内网探测，
  /// 那里是所有自动路径的兜底不变量（将来新增自动入口也不会漏）。
  ///
  /// [silent] 为 true（默认）时：不弹任何 UI、不抛异常；失败只返回 false，
  /// 并把 [consumeDropDetected] 的标记置位，交由 UI 决定是否提示。
  /// 传 false 表示调用方就在界面上等结果（例如登录引导页），此时**允许**
  /// 无视总闸与已持久化的 keep-alive 意图发起一次认证 —— 用户正看着，
  /// 不算静默；同一次调用还会清掉"本会话已暂停自动认证"的标志，
  /// 让用户按下的"重试"是真的重试。
  ///
  /// 与周期健康检查共用同一条静默通道（[_reconnecting]），所以任意时刻调用
  /// 都不会与健康检查并发发出认证请求；也不会先 `disconnect()` 再连。
  Future<bool> ensureCampusAlive({bool silent = true}) async {
    // 控制器已经 dispose（App 退出、`_MyAppState.dispose()` 里调过）时绝不能再
    // 发起认证：`dispose()` 只摘掉了监听和定时器，[session] 本身还活着，此时
    // 连一次就是"用户正在退出，后台却向学校网关发认证"。
    if (_disposed) return false;
    await _intentReady;
    if (silent) {
      // 总闸（设置里的「打开 App 后自动连接校园网」）是自动路径的总开关。
      // 放在这里而不是只放在 [_reconnectSilently] 里，是为了连"探测"都不做：
      // 启动路径（`app_bootstrap_page.dart`）的既定约束本来就是"不因为打开
      // App 就额外向校园网发起请求"，总闸关闭时更应如此。
      //
      // `force: true` 的读取：这是启动/手动入口，用户可能刚在设置里拨过开关。
      await _autoConnectReady;
      await _refreshAutoConnectCampus(force: true);
      if (!_autoConnectCampusEnabled) return false;
      if (!_keepAlive) return false;
    } else {
      // `silent: false` = 用户正看着界面等结果（登录引导页 / 「立即连接」）。
      // 手动路径**不受**总闸与"用户不想要"两个意图的约束，但这是唯一
      // 允许越过它的地方。用户主动要连 = 一次明确的"再试一次"，
      // 顺手把本会话的暂停与退避清掉，否则"手动连成功过一次之后，
      // 自动路径仍被上一次 permissionDenied 永久挡住"。
      _autoRetrySuppressed = false;
      _suppressedBy = null;
    }
    if (session.busy || _reconnecting) {
      // 已经有一次连接在跑：如实回报当前是否已经可用，不再叠一次认证。
      return session.online || session.tunnelUp;
    }
    // 原生可能已经通着（进程被系统回收后重启、前台服务还在跑）：先同步一次，
    // 已经在隧道上就绝不重复认证 —— 重复认证会顶掉网关侧的同账号旧会话。
    await session.syncFromNative();
    if (session.online || session.tunnelUp) return true;
    if (session.busy) return false;
    // 冷启动不受周期退避窗口限制：用户刚打开 App，正是要用的时刻。
    // （唯一的下限是"两次紧急尝试至少隔 10 秒"，见 [_reconnectSilently]。）
    // `force: !silent` —— 调用方在界面上等结果（silent=false，用户主动点连接）
    // 时，连"本会话已因不可重试失败暂停"也要放行，否则按钮按不动。
    return _reconnectSilently(
      ignoreBackoff: true,
      honorIntent: silent,
      force: !silent,
    );
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
  ///
  /// ⚠️ 快探测能不能看见 `heartbeat_error`，取决于 Kotlin 侧的 `cachedStatus`
  /// 有没有被持续刷新。`CampusVpnService.establishTun()` 成功后曾经不再续
  /// `pollForTun`，导致状态冻结在 `connected`、本方法永远等不到掉线信号 ——
  /// 那是本次"掉认证不重连"的原生根因，已在 Kotlin 侧修掉。
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
      // 判据与"回到前台"共用 [_nativeReportsGatewayDead]，避免两处漂移。
      // ⚠️ 这里**不**传 `ignoreBackoff`：周期探测必须老实走退避阶梯，否则每
      // 10 秒一次的重认证对学校网关近似暴力破解（同账号新会话踢旧会话 + 风控）。
      if (await _nativeReportsGatewayDead()) await _reconnectSilently();
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
      // 慢探测发现自己处于离线态：只要用户希望校园网通着，就补一次静默认证。
      //
      // 但这里**先确认原生隧道是不是真的没了**：内网 HTTP 探测本身会偶发抖动
      // （真机上 `ns.huse.cn` 曾在同一张网里完全不可达，而教务端点是 200），
      // 抖动不该触发重认证 —— 学校是"同账号新会话踢掉旧会话"的语义，
      // 为一次抖动重新认证反而会把一条好好的隧道顶掉。
      // 状态读不到（null）时也什么都不做：宁可等下一次探测，也不要盲目重连。
      final status = await CampusVpnLauncher().currentStatus();
      if (status != null && status['connected'] != true) {
        await _reconnectSilently();
      }
    } catch (_) {
      // 静默失败，保持当前状态。
    }
  }

  /// 静默重连：用本地保存的最后一个加速器账密自动认证。
  ///
  /// 返回 `true` 表示隧道已建立。
  ///
  /// ## ⚠️ 不要在这里套多层重试，也**不要**在重连前调 `disconnect()`
  ///
  /// 1. 旧注释说"`CampusVpnLauncher.connect()` 内部已经实现了完整的重试策略"，
  ///    这句**已经过时**：`campus_vpn.dart` 的 Android 分支现在只有一次尝试、
  ///    没有任何重试（那层重试因为会把人卡死在"正在连接"而被移除，见
  ///    HANDOFF §9.11 第 5 条）。因此退避与重试**只允许存在于本层**，
  ///    绝不在多层里各来一遍（历史教训：3 × 3 = 9 次认证请求，对学校网关
  ///    近似暴力破解）。
  /// 2. 静默重连前**绝不**先 `disconnect()`。学校网关是"同账号新会话踢掉
  ///    旧会话"的语义，直接重新认证即可；而"断开 → 等 idle → 再连"正是把
  ///    用户卡死在"正在连接"的那次事故：重连会重启前台服务，而系统 VPN
  ///    授权、TUN 建立、网关侧旧会话释放都不是"断开就干净"的，状态会在
  ///    `stopSelf` / `startForeground` 之间来回摆动。
  /// 3. 节流见 [_reconnectDelayFor]：首次掉线 10 秒后试，此后翻倍、5 分钟封顶。
  ///    重复的掉线检测（快探测每 10 秒一次）**不会**把重试时间点往后推。
  ///    **紧急**调用（冷启动 / 用户刚切回前台，`ignoreBackoff: true`）可以跳过
  ///    这段等待，但两次紧急尝试之间仍有 [_reconnectFirstDelay] 的下限；
  ///    **手动**调用（`force: true`，用户正按着界面上的连接按钮）连这个下限
  ///    也不受 —— 反正认证进行中按钮是禁用的，用户点了就必须有反应。
  ///
  /// 失败时设置 [_dropDetected] 让 UI 能提示，但**不会**因此永久放弃 ——
  /// 退避阶梯会一直继续，直到成功或意图被关掉。唯一的例外是
  /// [VpnFailure.isRetryable] 为 false（凭据错 / 未授权）：再试多少次都不会
  /// 成功，继续认证只会把学校网关当成密码爆破靶子（风控/临时封号风险），
  /// 所以那种情况会暂停**本会话**的自动认证（[_autoRetrySuppressed]），
  /// 但**不**落盘关掉 keep-alive 意图 —— 那类失败完全可能是瞬时的，落盘关掉
  /// 会让用户的意愿被永久遗忘（见 [VpnFailure.isRetryable] 与
  /// [_autoRetrySuppressed] 的说明）。
  Future<bool> _reconnectSilently({
    bool ignoreBackoff = false,
    bool honorIntent = true,
    bool force = false,
  }) async {
    if (_reconnecting) return false;
    await _intentReady;
    // ── 总闸：**所有**自动认证路径的兜底不变量 ──────────────────────────
    //
    // `honorIntent` 正好是"这次是自动还是手动"的判据：四个自动入口
    // （[_fastGatewayWatch] / [_silentHealthCheck] / [handleAppResumed] /
    // [ensureCampusAlive]`(silent: true)`）都用默认值 true，唯一的 false 来自
    // [ensureCampusAlive]`(silent: false)` —— 也就是用户正看着界面的手动连接。
    // 所以判定只需要写在这一处，新增自动入口也不会漏。
    //
    // 这里读设置时**不**带 `force`：这是最内层、调用最频繁的路径，配合
    // [_autoConnectRefreshInterval] 节流，避免每 10 秒一次快探测都去读磁盘。
    // 需要立刻生效的场景（启动 / 回前台 / 手动）都在更外层用 force 读过了。
    if (honorIntent) {
      await _autoConnectReady;
      await _refreshAutoConnectCampus();
      if (!_autoConnectCampusEnabled) return false;
    }
    if (honorIntent && !_keepAlive) return false;
    // 「本会话已暂停」只拦**自动**重试；用户在界面上主动要连（force=true）
    // 必须放行，否则按钮会变成一个按不动的开关。
    if (_autoRetrySuppressed && !force) return false;

    final now = DateTime.now();
    // 「紧急」信号：冷启动（`ensureCampusAlive()` 的语义是"用户刚打开 App，
    // 别让他等 10 秒"）以及**用户刚切回前台**（见 [handleAppResumed]）。
    // 用户就在屏幕前等着，绝不能被退避窗口拖住 —— 一次后台期间的连续失败会把
    // 重试点排到 5 分钟后，表现就是"切回来还要干等几分钟，甚至永远不好"。
    //
    // ⚠️ 紧急放行必须**有下限**：两次紧急尝试之间至少隔 [_reconnectFirstDelay]
    // （10 秒）。没有它，反复切前后台（每次 resume 都会来一次）就变成对学校
    // 网关的高频认证 —— 那正是本类一直在防的事（同账号踢旧会话 + 风控风险）。
    final lastAttempt = _lastAttemptAt;
    final urgent =
        ignoreBackoff &&
        (lastAttempt == null ||
            now.difference(lastAttempt) >= _reconnectFirstDelay);
    // `force` = 用户正按着界面上的连接按钮。它必须**越过退避窗口**，否则会
    // 出现这条死路：用户在 10 秒内连点两次连接，第二次直接 `return false`，
    // 界面上什么都没发生 —— 按钮看起来"按不动"，正是本类一直在修的那类症状。
    //
    // 为什么可以无条件越过：force 只来自 [ensureCampusAlive]`(silent: false)`，
    // 也就是有人在看着界面等结果；认证进行中 `session.busy` 为真、按钮被禁用，
    // 所以这里不可能被连点刷成高频认证。
    final bypassBackoff = force || urgent;
    if (_nextReconnectAt == null) {
      // 掉线后的**第一次**尝试先等 10 秒：Rust 心跳自己会按 10s/20s/30s
      // 退避续期，瞬时抖动往往在这段时间内自愈，等一等能少发一次不必要的
      // 认证请求（学校网关有风控）。
      _nextReconnectAt = now.add(_reconnectDelayFor(_reconnectFailures));
      if (!bypassBackoff) return false;
    }
    if (!bypassBackoff && now.isBefore(_nextReconnectAt!)) return false;

    _reconnecting = true;
    _lastAttemptAt = now;
    _notify();
    try {
      final accounts = await loadVpnAccounts();
      if (accounts.isEmpty) {
        // 没有本地凭据就无法自动认证（用户可能没勾选保存）。保持提示，
        // 并按当前退避节奏继续等，不做高频空转。
        _dropDetected = true;
        _scheduleNextAttempt();
        return false;
      }
      final account = accounts.first;
      // 只调一次。内层（campus_vpn.dart）不做重试，见上面的说明。
      final ok = await session
          .connect(username: account.username, password: account.password)
          .timeout(
            _silentConnectTimeout,
            onTimeout: () {
              // 看门狗：原生调用挂死时把状态机从 preparing 里救出来，
              // 否则 busy 会永远为真、按钮永远禁用。
              session.abortHangingConnect();
              return false;
            },
          );
      if (ok) {
        _reconnectFailures = 0;
        _nextReconnectAt = null;
        // 一次成功的认证就证明了凭据和系统授权都没问题，顺带解掉
        // 「本会话已暂停」：这是 force（用户手动）越过暂停后成功的路径，
        // 不解就会留下"手动连得上、自动却永远不连"的怪状态，
        // 直到进程重启为止。
        _autoRetrySuppressed = false;
        _suppressedBy = null;
        return true;
      }
      _dropDetected = true;
      final failure = session.failure;
      if (failure != null && !failure.isRetryable) {
        // 凭据错 / 未授权：**只暂停本会话**的自动认证，避免每分钟再打一次网关。
        // 刻意**不**关掉持久化意图 —— 见 [_autoRetrySuppressed] 的说明：
        // 这类失败可能是瞬时的，落盘关掉会让用户"保持校园网"的意愿被永久遗忘。
        _autoRetrySuppressed = true;
        // 记下是**哪种**失败，[handleAppResumed] 据此判断能不能在回前台时
        // 解除暂停（permissionDenied 可以，badCredentials 不行）。
        _suppressedBy = failure;
        _reconnectFailures = 0;
        _nextReconnectAt = null;
        return false;
      }
      _scheduleNextAttempt();
      return false;
    } catch (_) {
      _dropDetected = true;
      _scheduleNextAttempt();
      return false;
    } finally {
      _reconnecting = false;
      _notify();
    }
  }

  /// 记一次失败并安排下一次尝试（`_nextReconnectAt` 从"现在"起算）。
  void _scheduleNextAttempt() {
    _reconnectFailures += 1;
    _nextReconnectAt = DateTime.now().add(
      _reconnectDelayFor(_reconnectFailures),
    );
  }

  /// 退避阶梯：第 0 次（还没有失败过）10 秒；1 次失败后 20s，然后 40s、80s、
  /// 160s，300 秒（5 分钟）封顶。
  Duration _reconnectDelayFor(int failures) {
    var seconds = _reconnectFirstDelay.inSeconds;
    final cap = _reconnectMaxDelay.inSeconds;
    for (var i = 0; i < failures && seconds < cap; i++) {
      seconds *= 2;
    }
    if (seconds > cap) seconds = cap;
    return Duration(seconds: seconds);
  }

  @override
  void dispose() {
    _disposed = true;
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
