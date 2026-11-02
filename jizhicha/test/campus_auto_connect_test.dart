import 'package:flutter_test/flutter_test.dart';
import 'package:jizhicha/campus_environment.dart';
import 'package:jizhicha/credential_store.dart';
import 'package:jizhicha/vpn_session.dart';

/// 「打开 App 后自动连接校园网」总闸的行为测试。
///
/// 这里测的不是某个私有方法，而是**四条自动认证入口在总闸关掉之后是否真的
/// 一条都不走**：启动（`ensureCampusAlive(silent: true)`）、回前台
/// （`handleAppResumed()`）、以及它们最终都会汇入的 `_reconnectSilently()`。
/// 断言方式统一是"数假加速器上被调用了几次 `connect()`" —— 只有真的向学校
/// 网关发过认证，这个计数才会变。所以这些测试失败时说明的是**真的发出了
/// 认证请求**，而不是某个内部字段没置对。
///
/// 全部使用占位数据：账号 `demo-user` / `demo-pass`，虚拟地址用 RFC 5737
/// 文档保留段，不含任何真实学号、密码或会话地址。
void main() {
  group('总闸默认关闭', () {
    test('启动时的静默保活不发认证请求（ensureCampusAlive silent）', () async {
      final rig = _Rig(autoConnect: false, storedIntent: true);

      final alive = await rig.env.ensureCampusAlive();

      expect(alive, isFalse);
      expect(
        rig.launcher.connectCalls,
        0,
        reason: '总闸关着，启动路径不能自己发起认证',
      );
      expect(rig.probe.calls, 0, reason: '连探测都不该做（启动路径的既定约束）');
      // 关总闸不改写"用户希望保持连接"的意图：它只是不自动连。
      expect(rig.env.keepAlive, isTrue);
      expect(rig.store.value, isTrue, reason: '总闸不该把 keepAlive 写成 false');

      rig.env.dispose();
    });

    test('总闸关着时，回到前台也不发认证请求', () async {
      // 先在总闸开着的状态下把隧道连起来（模拟"用户手动连上、然后把总闸关了"），
      // 再让网关探测失败，逼回前台路径进入"需要重新认证"的分支。
      final rig = _Rig(autoConnect: false, storedIntent: true);
      await rig.session.connect(username: 'demo-user', password: 'demo-pass');
      expect(rig.launcher.connectCalls, 1);
      expect(rig.session.online, isTrue);

      rig.probe.reachable = false; // 复核会失败 → 走到重认证那一步
      await rig.env.handleAppResumed();

      expect(
        rig.launcher.connectCalls,
        1,
        reason: '总闸关着，回前台只允许"看"，不允许"连"',
      );
      // 关开关 ≠ 断网：不许主动拆掉已经连上的隧道。
      expect(rig.launcher.disconnectCalls, 0);
      expect(rig.env.keepAlive, isTrue);
      expect(rig.store.value, isTrue);

      rig.env.dispose();
    });

    test('总闸关着时，静默保活一条自动路径都不会写 keepAlive', () async {
      final rig = _Rig(autoConnect: false, storedIntent: null);

      await rig.env.ensureCampusAlive();
      await rig.env.handleAppResumed();

      expect(rig.store.saveCalls, 0, reason: '自动路径不该产生任何意图写入');
      expect(rig.launcher.connectCalls, 0);

      rig.env.dispose();
    });
  });

  group('总闸打开后行为不变', () {
    test('启动时的静默保活照旧认证（ensureCampusAlive silent）', () async {
      final rig = _Rig(autoConnect: true, storedIntent: true);

      final alive = await rig.env.ensureCampusAlive();

      expect(alive, isTrue);
      expect(rig.launcher.connectCalls, 1);
      expect(rig.session.online, isTrue);

      rig.env.dispose();
    });

    test('回到前台仍会重新认证（与总闸关形成对照）', () async {
      final rig = _Rig(autoConnect: true, storedIntent: true);
      // 直接调状态机连一次（不走控制器），这样控制器里"上次尝试时间"还是空的，
      // 回前台那次紧急重连不会被 10 秒下限挡住 —— 对照组要能真的连上去。
      await rig.session.connect(username: 'demo-user', password: 'demo-pass');
      expect(rig.launcher.connectCalls, 1);

      rig.probe.reachable = false;
      await rig.env.handleAppResumed();

      expect(
        rig.launcher.connectCalls,
        2,
        reason: '总闸开着 = 现有行为：回前台发现网关不可达就重新认证',
      );

      rig.env.dispose();
    });
  });

  group('手动连接不受总闸影响', () {
    test('总闸关着时 ensureCampusAlive(silent: false) 仍能连上', () async {
      final rig = _Rig(autoConnect: false, storedIntent: false);

      final alive = await rig.env.ensureCampusAlive(silent: false);

      expect(alive, isTrue);
      expect(rig.launcher.connectCalls, 1);
      expect(rig.session.online, isTrue);

      rig.env.dispose();
    });

    test('手动连接会越过"本会话已暂停自动认证"的挡板', () async {
      // 第一次自动尝试被网关拒绝（不可重试）→ 本会话暂停自动认证；
      // 用户随后在界面上手动连接（silent: false）必须能真的再试一次。
      final rig = _Rig(
        autoConnect: true,
        storedIntent: true,
        connectError: '请在 Android 系统网络授权对话框中允许稽之查',
      );
      await rig.env.ensureCampusAlive();
      expect(rig.launcher.connectCalls, 1);

      rig.launcher.connectError = null; // 用户已在系统里授权
      final alive = await rig.env.ensureCampusAlive(silent: false);

      expect(alive, isTrue);
      expect(rig.launcher.connectCalls, 2);

      rig.env.dispose();
    });
  });

  group('意图 keepAlive 与总闸的优先级', () {
    test('凭据推断出 keepAlive=true 也绕不过关闭的总闸', () async {
      // 磁盘上没有 keepAlive 记录（老版本升级上来的设备），但本地存着加速器
      // 凭据 → `_restoreKeepAliveIntent` 会把 keepAlive 推断成 true。
      final rig = _Rig(autoConnect: false, storedIntent: null);

      final alive = await rig.env.ensureCampusAlive();

      expect(
        rig.env.keepAlive,
        isTrue,
        reason: '推断分支本身照旧工作（凭据存在 → 希望保持连接）',
      );
      expect(alive, isFalse, reason: '但总闸关着，优先级更高：不许自动认证');
      expect(rig.launcher.connectCalls, 0);

      rig.env.dispose();
    });

    test('总闸开着但用户明确断开过（keepAlive=false）→ 仍然不自动连', () async {
      final rig = _Rig(autoConnect: true, storedIntent: false);

      final alive = await rig.env.ensureCampusAlive();

      expect(rig.env.keepAlive, isFalse);
      expect(alive, isFalse);
      expect(rig.launcher.connectCalls, 0);

      rig.env.dispose();
    });

    test('两个意图都成立时才自动认证', () async {
      final rig = _Rig(autoConnect: true, storedIntent: true);

      final alive = await rig.env.ensureCampusAlive();

      expect(alive, isTrue);
      expect(rig.launcher.connectCalls, 1);

      rig.env.dispose();
    });
  });

  group('暂停自动认证的恢复入口', () {
    test('系统 VPN 授权被拒后，回到前台会解除暂停', () async {
      final rig = _Rig(
        autoConnect: true,
        storedIntent: true,
        connectError: '请在 Android 系统网络授权对话框中允许稽之查',
      );

      await rig.env.ensureCampusAlive();
      expect(rig.launcher.connectCalls, 1, reason: '第一次自动尝试真的发出去了');

      await rig.env.ensureCampusAlive();
      expect(
        rig.launcher.connectCalls,
        1,
        reason: '不可重试失败后本会话暂停自动认证（防止抖网关）',
      );

      await rig.env.handleAppResumed();
      await rig.env.ensureCampusAlive();

      expect(
        rig.launcher.connectCalls,
        2,
        reason: '用户可能已在系统里授予权限，回到前台必须给一次重试机会',
      );

      rig.env.dispose();
    });

    test('密码错不会因为切前后台而被无脑重试', () async {
      final rig = _Rig(
        autoConnect: true,
        storedIntent: true,
        connectError: 'sac login rejected',
      );

      await rig.env.ensureCampusAlive();
      expect(rig.launcher.connectCalls, 1);

      await rig.env.handleAppResumed();
      await rig.env.ensureCampusAlive();
      expect(
        rig.launcher.connectCalls,
        1,
        reason: '密码错不会因为过了一段时间就变对，反复认证只会撞网关风控',
      );

      // 手动连接仍然是恢复入口。
      rig.launcher.connectError = null;
      await rig.env.ensureCampusAlive(silent: false);
      expect(rig.launcher.connectCalls, 2);

      rig.env.dispose();
    });
  });
}

/// 内存里的 keep-alive 意图存储（不碰 `path_provider`／真实文件）。
class _MemoryKeepAliveStore implements CampusKeepAliveStore {
  _MemoryKeepAliveStore(this.value);

  bool? value;
  int saveCalls = 0;

  @override
  Future<bool?> load() async => value;

  @override
  Future<void> save(bool newValue) async {
    value = newValue;
    saveCalls++;
  }
}

/// 可切换结果的探测函数，并记录被调用次数。
class _Probe {
  bool reachable = true;
  int calls = 0;

  Future<bool> call({required Duration timeout}) async {
    calls++;
    return reachable;
  }
}

/// 假加速器：`connect()` 的调用次数就是"向学校网关发过几次认证"。
class _FakeLauncher implements CampusVpnLauncherAdapter {
  _FakeLauncher({this.connectError});

  String? connectError;
  int connectCalls = 0;
  int disconnectCalls = 0;
  Map<String, dynamic> _status = const {'connected': false};

  @override
  Future<void> connect({
    required String username,
    required String password,
    String? authSource,
    void Function(String message)? onProgress,
  }) async {
    connectCalls++;
    onProgress?.call('正在认证…');
    if (connectError != null) throw connectError!;
    _status = {
      'connected': true,
      // RFC 5737 文档保留地址，仅占位；绝不是真实会话地址。
      'virtual_ip': '192.0.2.10',
      'username': username,
    };
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    _status = const {'connected': false};
  }

  @override
  Future<Map<String, dynamic>?> currentStatus() async => _status;
}

/// 一个控制器 + 它的假依赖，逐字段都可在用例中查询/改动。
class _Rig {
  _Rig({
    required bool autoConnect,
    required bool? storedIntent,
    String? connectError,
  }) : store = _MemoryKeepAliveStore(storedIntent),
       launcher = _FakeLauncher(connectError: connectError),
       _gate = autoConnect {
    session = VpnSession(probe: probe.call, launcher: launcher);
    env = CampusEnvironmentController(
      session: session,
      keepAliveStore: store,
      loadVpnAccounts: () async => const [
        StoredAccount(username: 'demo-user', password: 'demo-pass'),
      ],
      loadAutoConnectCampus: () async => _gate,
    );
  }

  final _MemoryKeepAliveStore store;
  final _FakeLauncher launcher;
  final _Probe probe = _Probe();
  late final VpnSession session;
  late final CampusEnvironmentController env;

  /// 设置里总闸的值（构造时固定）。
  final bool _gate;
}
