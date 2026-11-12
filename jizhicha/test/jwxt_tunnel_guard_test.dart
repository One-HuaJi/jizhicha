import 'package:flutter_test/flutter_test.dart';
import 'package:jizhicha/jwxt_client.dart';

/// 教务请求的"隧道是否就绪"守卫。
///
/// 这里只覆盖不需要联网的分支：守卫本身必须在发请求之前就把请求拦下来，
/// 所以断言"拿到的是可读的业务错误"等价于断言"没有真的发出包"。
void main() {
  final client = JwxtClient();

  tearDown(() {
    client.tunnelAlive = null;
    client.setVpnSourceAddress(null);
    client.resetSession();
  });

  group('校园网未就绪时教务请求被拦截', () {
    test('源地址为空时给出可读错误，不暴露隧道实现概念', () async {
      client.tunnelAlive = () => false;
      await expectLater(
        client.getCaptcha(),
        throwsA(
          predicate<String>(
            (message) => message.contains('校园网尚未就绪'),
            '提示用户先连接校园加速器',
          ),
        ),
      );
    });

    test('状态机判定隧道已死时清掉残留源地址，不再绑定死网卡', () async {
      // 地址是建隧道时写进来的；隧道随后可能被系统回收或用户掐断，
      // 但状态机回调不一定来得及把地址清掉。
      client.setVpnSourceAddress('10.9.9.9');
      expect(client.vpnSourceAddress, '10.9.9.9');

      client.tunnelAlive = () => false;
      await expectLater(client.getCaptcha(), throwsA(isA<String>()));

      expect(
        client.vpnSourceAddress,
        isNull,
        reason: '否则后续请求会绑定到已消失的虚拟网卡，报 EADDRNOTAVAIL',
      );
    });

    test('隧道仍在线且地址有效时不误伤', () {
      client.setVpnSourceAddress('10.9.9.9');
      client.tunnelAlive = () => true;
      expect(client.debugAssertCampusTunnelReady, returnsNormally);
      expect(client.vpnSourceAddress, '10.9.9.9');
    });

    test('未注入状态机时退化为只看地址非空', () {
      client.tunnelAlive = null;
      client.setVpnSourceAddress('10.9.9.9');
      expect(client.debugAssertCampusTunnelReady, returnsNormally);
    });
  });

  group('源地址归一化', () {
    test('空白地址视为未连接，避免把 "  " 解析成 0.0.0.0', () {
      client.setVpnSourceAddress('  ');
      expect(client.vpnSourceAddress, isNull);
      client.setVpnSourceAddress(' 10.1.2.3 ');
      expect(client.vpnSourceAddress, '10.1.2.3');
    });
  });
}