import 'package:flutter_test/flutter_test.dart';
import 'package:jizhicha/vpn_session.dart';

/// [VpnSession] 的纯逻辑测试。
///
/// 这个文件本身就是本次重构的主要收益：改造前"连接流程"只能靠在真机上
/// 手点验证，因为它和平台通道（MethodChannel / FFI）以及页面 State
/// 绑死在一起。引入状态机后，只要注入一个假的探测函数就能把
/// "认证 → 建隧道 → 验证网关 → 在线"整条路径跑完。
void main() {
  group('VpnFailure 分类', () {
    test('Wintun 相关错误归类为 adapterBusy 且可重试', () {
      expect(
        classifyVpnError('WintunStartSession failed'),
        VpnFailure.adapterBusy,
      );
      expect(
        classifyVpnError('failed to create wintun adapter'),
        VpnFailure.adapterBusy,
      );
      expect(VpnFailure.adapterBusy.isRetryable, isTrue);
    });

    test('密码错误归类为 badCredentials 且不可重试', () {
      expect(classifyVpnError('sac login rejected'), VpnFailure.badCredentials);
      expect(classifyVpnError('error 0x020004AB'), VpnFailure.badCredentials);
      expect(
        VpnFailure.badCredentials.isRetryable,
        isFalse,
        reason: '凭据错重试多少次都是错的，不该浪费用户时间',
      );
    });

    test('超时类错误可重试', () {
      expect(
        classifyVpnError('gateway session setup timed out'),
        VpnFailure.gatewayTimeout,
      );
      expect(VpnFailure.gatewayTimeout.isRetryable, isTrue);
    });

    test('未知错误落到 unknown 且默认可重试', () {
      expect(classifyVpnError('something totally unexpected'), VpnFailure.unknown);
      expect(VpnFailure.unknown.isRetryable, isTrue);
    });

    test('权限未授权不可重试（要用户去点系统弹窗）', () {
      expect(
        classifyVpnError('请在 Android 系统网络授权对话框中允许稽之查'),
        VpnFailure.permissionDenied,
      );
      expect(VpnFailure.permissionDenied.isRetryable, isFalse);
    });

    test('每种失败都有非空中文文案', () {
      for (final kind in VpnFailure.values) {
        expect(kind.message.trim(), isNotEmpty, reason: '$kind 缺文案');
      }
    });
  });

  group('状态机迁移', () {
    test('探测成功时最终到达 online', () async {
      var probeCalls = 0;
      final session = VpnSession(
        probe: ({required timeout}) async {
          probeCalls++;
          return true;
        },
        launcher: _FakeLauncher(),
      );

      expect(session.phase, VpnPhase.idle);
      expect(session.online, isFalse);

      final ok = await session.connect(username: 'u', password: 'p');

      expect(ok, isTrue);
      expect(session.phase, VpnPhase.online);
      expect(session.online, isTrue);
      expect(session.failure, isNull);
      expect(probeCalls, greaterThan(0), reason: '必须真的探测过网关');
    });

    test('探测失败时连接仍成功，但状态停在 tunnelUp（不置在线）', () async {
      final session = VpnSession(
        probe: ({required timeout}) async => false,
        launcher: _FakeLauncher(),
      );

      final ok = await session.connect(username: 'u', password: 'p');

      // ⚠️ 这是真机回归后修正的契约：**探测失败不能否决连接**。
      // ns.huse.cn 探测本身不稳定，若把它当硬门槛，隧道明明建好了却报
      // "加速器已连接，但教务服务器无响应，请重试"（真机实测过）。
      // 能不能用教务由调用方的 waitForIntranet（对目标端点轮询 30 秒）决定。
      expect(ok, isTrue, reason: '隧道建好了就算连接成功');
      expect(session.phase, VpnPhase.tunnelUp);
      expect(session.online, isFalse, reason: '没验证过网关就不该显示在线');
      expect(session.failure, isNull, reason: '这不是失败，只是还没确认');
    });

    test('探测失败会补测（单次失败不该判定掉线）', () async {
      var calls = 0;
      final session = VpnSession(
        probe: ({required timeout}) async {
          calls++;
          return calls >= 2; // 第一次失败，第二次成功
        },
        launcher: _FakeLauncher(),
      );

      final ok = await session.connect(username: 'u', password: 'p');

      expect(ok, isTrue, reason: '补测成功应判定在线');
      expect(calls, greaterThanOrEqualTo(2));
      expect(session.phase, VpnPhase.online);
    });

    test('原生 connect 抛错时归类为枚举，而不是抛给调用方', () async {
      final session = VpnSession(
        probe: ({required timeout}) async => true,
        launcher: _FakeLauncher(connectError: 'sac login rejected'),
      );

      // 不抛异常：状态机把失败表达为状态，调用方读 session.failure 即可。
      final ok = await session.connect(username: 'u', password: 'wrong');

      expect(ok, isFalse);
      expect(session.phase, VpnPhase.failed);
      expect(session.failure, VpnFailure.badCredentials);
    });

    test('disconnect 回到 idle 并清空虚拟 IP', () async {
      final session = VpnSession(
        probe: ({required timeout}) async => true,
        launcher: _FakeLauncher(),
      );
      await session.connect(username: 'u', password: 'p');
      expect(session.online, isTrue);

      await session.disconnect();

      expect(session.phase, VpnPhase.idle);
      expect(session.online, isFalse);
      expect(session.virtualIp, isNull);
    });

    test('连接中再次 connect 会被忽略（防重复点击）', () async {
      final launcher = _FakeLauncher(connectDelay: const Duration(milliseconds: 80));
      final session = VpnSession(
        probe: ({required timeout}) async => true,
        launcher: launcher,
      );

      final first = session.connect(username: 'u', password: 'p');
      final second = await session.connect(username: 'u', password: 'p');
      expect(second, isFalse, reason: '第二次应被拒绝');
      expect(await first, isTrue);
      expect(launcher.connectCalls, 1);
    });
  });

  group('回归：不要把探测失败当成连接失败（2026-09-18 真机 bug）', () {
    test('探测全失败时不会调用 disconnect —— 隧道必须留着', () async {
      final launcher = _FakeLauncher();
      final session = VpnSession(
        probe: ({required timeout}) async => false,
        launcher: launcher,
      );

      await session.connect(username: 'u', password: 'p');

      // bug 版本里探测失败会调 `_launcher.disconnect()` 把好隧道拆掉，
      // 用户看到"加速器已连接，但教务服务器无响应，请重试"且再也连不上。
      expect(
        launcher.disconnectCalls,
        0,
        reason: '探测失败不该拆掉已经建好的隧道',
      );
    });

    test('探测失败后仍是 tunnelUp，后续 recheck 能提升为 online', () async {
      var reachable = false;
      final session = VpnSession(
        probe: ({required timeout}) async => reachable,
        launcher: _FakeLauncher(),
      );

      await session.connect(username: 'u', password: 'p');
      expect(session.phase, VpnPhase.tunnelUp);

      // 网络稍后恢复，健康检查应能把状态提升到在线，而不是要求用户重连。
      reachable = true;
      final ok = await session.recheck();

      expect(ok, isTrue);
      expect(session.phase, VpnPhase.online);
    });

    test('recheck 失败时也只回到 idle，不主动 disconnect', () async {
      // 真机实测：ns.huse.cn 在某校园网段完全不可达（curl 000），
      // 而教务端点 172.20.63.226/jsxsd/ 是 200。此时隧道是好的，
      // 绝不能因为探测失败就把它拆掉 —— 那会让用户"永远连不上"。
      final launcher = _FakeLauncher();
      final session = VpnSession(
        probe: ({required timeout}) async => false,
        launcher: launcher,
      );
      await session.connect(username: 'u', password: 'p');

      await session.recheck();

      expect(
        launcher.disconnectCalls,
        0,
        reason: 'recheck 只纠正状态，不该拆隧道（拆不拆由调用方决定）',
      );
    });

    test('隧道建立后回调虚拟 IP（教务请求要绑定它）', () async {
      String? got;
      final session = VpnSession(
        probe: ({required timeout}) async => true,
        launcher: _FakeLauncher(),
      )..onTunnelEstablished = (ip) => got = ip;

      await session.connect(username: 'u', password: 'p');

      expect(got, '172.19.0.5', reason: '必须把虚拟 IP 交给 JwxtClient 绑定');
    });
  });

  group('与原生状态同步', () {
    test('原生 connected 但网关不可达时不置 online', () async {
      final session = VpnSession(
        probe: ({required timeout}) async => false,
        launcher: _FakeLauncher(
          status: {'connected': true, 'virtual_ip': '172.19.0.5'},
        ),
      );

      await session.syncFromNative();

      // 这正是旧代码里"隧道 connected ≠ 网关就绪"那段注释想表达的事，
      // 现在它是类型层面的必然行为，而不是靠调用方记得补测。
      expect(session.online, isFalse);
      expect(session.phase, VpnPhase.idle);
    });

    test('原生 connected 且网关可达时置 online 并记录虚拟 IP', () async {
      final session = VpnSession(
        probe: ({required timeout}) async => true,
        launcher: _FakeLauncher(
          status: {
            'connected': true,
            'virtual_ip': '172.19.0.5',
            'username': '202400000000',
          },
        ),
      );

      await session.syncFromNative();

      expect(session.phase, VpnPhase.online);
      expect(session.online, isTrue);
      expect(session.virtualIp, '172.19.0.5');
    });

    test('原生未连接时回到 idle', () async {
      final session = VpnSession(
        probe: ({required timeout}) async => true,
        launcher: _FakeLauncher(status: {'connected': false}),
      );

      await session.syncFromNative();

      expect(session.phase, VpnPhase.idle);
      expect(session.virtualIp, isNull);
    });

    test('状态接口抛异常不改变已有状态', () async {
      final session = VpnSession(
        probe: ({required timeout}) async => true,
        launcher: _FakeLauncher(),
      );
      await session.connect(username: 'u', password: 'p');
      expect(session.online, isTrue);

      (session as dynamic); // 保持 API 稳定；下面的 launcher 换成会抛错的
      final broken = VpnSession(
        probe: ({required timeout}) async => true,
        launcher: _FakeLauncher(statusError: 'boom'),
      );
      await broken.syncFromNative();
      expect(broken.phase, VpnPhase.idle);
    });
  });

  group('recheck', () {
    test('在线时探测失败会退出在线态', () async {
      var fail = false;
      final session = VpnSession(
        probe: ({required timeout}) async => !fail,
        launcher: _FakeLauncher(),
      );
      await session.connect(username: 'u', password: 'p');
      expect(session.online, isTrue);

      fail = true;
      final still = await session.recheck();

      expect(still, isFalse);
      expect(session.online, isFalse);
    });

    test('不在线时 recheck 直接返回 false，不发起探测', () async {
      var calls = 0;
      final session = VpnSession(
        probe: ({required timeout}) async {
          calls++;
          return true;
        },
        launcher: _FakeLauncher(),
      );

      final result = await session.recheck();

      expect(result, isFalse);
      expect(calls, 0);
    });
  });

  group('状态变化会通知监听者', () {
    test('online 变化触发 notifyListeners', () async {
      final session = VpnSession(
        probe: ({required timeout}) async => true,
        launcher: _FakeLauncher(),
      );
      var notifications = 0;
      session.addListener(() => notifications++);

      await session.connect(username: 'u', password: 'p');

      expect(notifications, greaterThan(0));
    });
  });
}

/// 假的加速器原生层。只实现 [VpnSession] 用到的那几个方法。
///
/// 之所以能这么写，是因为 [VpnSession] 把 `CampusVpnLauncher` 作为可注入
/// 参数 —— 改造前连接逻辑直接 `new` 出真实 launcher，测试里必然触发
/// MethodChannel / FFI，跑不起来。
class _FakeLauncher implements CampusVpnLauncherAdapter {
  _FakeLauncher({
    this.connectError,
    this.statusError,
    Map<String, dynamic>? status,
    this.connectDelay,
  }) : _status = status ?? {'connected': false};

  final String? connectError;
  final String? statusError;
  final Duration? connectDelay;
  Map<String, dynamic> _status;

  int connectCalls = 0;
  int disconnectCalls = 0;

  @override
  Future<void> connect({
    required String username,
    required String password,
    String? authSource,
    void Function(String message)? onProgress,
  }) async {
    connectCalls++;
    onProgress?.call('正在认证…');
    if (connectDelay != null) await Future<void>.delayed(connectDelay!);
    if (connectError != null) throw connectError!;
    _status = {
      'connected': true,
      'virtual_ip': '172.19.0.5',
      'username': username,
    };
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    _status = {'connected': false};
  }

  @override
  Future<Map<String, dynamic>?> currentStatus() async {
    if (statusError != null) throw statusError!;
    return _status;
  }
}
