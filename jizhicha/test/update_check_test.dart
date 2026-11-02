import 'dart:io' show HandshakeException, SocketException;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jizhicha/update_check.dart';

// 更新检测的纯函数单测。
// 只测"可离线判定"的部分：版本比较、tag/重定向解析、release JSON 解析、
// 错误归类。真正发网络请求的 checkForUpdate() 不在这里测（要真网络，不稳定）。
void main() {
  group('compareVersions', () {
    test('主版本号大小', () {
      expect(compareVersions('1.1.1', '1.1.0'), greaterThan(0));
      expect(compareVersions('1.1.0', '1.1.1'), lessThan(0));
      expect(compareVersions('1.1.1', '1.1.1'), 0);
    });

    test('补零比较：1.2 与 1.2.0 视为相等', () {
      expect(compareVersions('1.2', '1.2.0'), 0);
      expect(compareVersions('1.2.0', '1.2'), 0);
    });

    test('位数不同时按缺位补 0', () {
      expect(compareVersions('1.10.0', '1.9.9'), greaterThan(0));
      expect(compareVersions('2', '1.99.99'), greaterThan(0));
    });

    test('非法数字按 0 处理，不抛异常', () {
      expect(() => compareVersions('x.y.z', '1.0.0'), returnsNormally);
      expect(compareVersions('x.y.z', '1.0.0'), lessThan(0));
    });
  });

  group('versionFromTag', () {
    test('去掉 v 前缀', () => expect(versionFromTag('v1.1.1'), '1.1.1'));
    test('大写 V 也去掉', () => expect(versionFromTag('V1.1.1'), '1.1.1'));
    test('没有前缀原样返回', () => expect(versionFromTag('1.1.1'), '1.1.1'));
    test('空白返回空串', () => expect(versionFromTag('   '), ''));
  });

  group('versionFromRedirectLocation', () {
    test('标准 releases/tag 地址', () {
      expect(
        versionFromRedirectLocation(
          'https://github.com/One-HuaJi/jizhicha/releases/tag/v1.1.1',
        ),
        '1.1.1',
      );
    });

    test('带查询串', () {
      expect(
        versionFromRedirectLocation(
          'https://github.com/One-HuaJi/jizhicha/releases/tag/v1.1.1?x=1',
        ),
        '1.1.1',
      );
    });

    test('没有 tag 段返回 null', () {
      expect(
        versionFromRedirectLocation(
          'https://github.com/One-HuaJi/jizhicha/releases',
        ),
        isNull,
      );
    });

    test('空值与非法值返回 null', () {
      expect(versionFromRedirectLocation(null), isNull);
      expect(versionFromRedirectLocation(''), isNull);
    });
  });

  group('parseLatestReleaseJson', () {
    Map<String, dynamic> release({
      String tag = 'v1.1.5',
      List<Map<String, dynamic>> assets = const [],
    }) => {
      'tag_name': tag,
      'html_url': 'https://github.com/One-HuaJi/jizhicha/releases/tag/$tag',
      'assets': assets,
    };

    test('Android 取名字含 arm64 的资产', () {
      final ok = parseLatestReleaseJson(
        release(
          assets: [
            {'name': 'jizhicha-1.1.5-Windows.zip', 'browser_download_url': 'w'},
            {'name': 'jizhicha-1.1.5-arm64-v8a.apk', 'browser_download_url': 'a'},
          ],
        ),
        isWindows: false,
      );
      expect(ok, isNotNull);
      expect(ok!.version, '1.1.5');
      expect(ok.downloadUrl, 'a');
      expect(ok.endpoint, 'api');
    });

    test('Windows 取名字含 Windows 的资产', () {
      final ok = parseLatestReleaseJson(
        release(
          assets: [
            {'name': 'jizhicha-1.1.5-Windows.zip', 'browser_download_url': 'w'},
            {'name': 'jizhicha-1.1.5-arm64-v8a.apk', 'browser_download_url': 'a'},
          ],
        ),
        isWindows: true,
      );
      expect(ok!.downloadUrl, 'w');
    });

    test('找不到匹配资产时回退到 html_url（不是空串）', () {
      final ok = parseLatestReleaseJson(release(), isWindows: false);
      expect(ok, isNotNull);
      expect(ok!.downloadUrl, contains('/releases/tag/'));
    });

    test('缺少 tag_name 返回 null', () {
      expect(
        parseLatestReleaseJson({'assets': []}, isWindows: false),
        isNull,
      );
    });

    test('非 Map 输入返回 null', () {
      expect(parseLatestReleaseJson('nope', isWindows: false), isNull);
      expect(parseLatestReleaseJson(null, isWindows: false), isNull);
    });

    test('hasUpdate 按当前版本判断', () {
      final newer = parseLatestReleaseJson(
        release(tag: 'v99.0.0'),
        isWindows: false,
      );
      final older = parseLatestReleaseJson(
        release(tag: 'v1.0.0'),
        isWindows: false,
      );
      expect(newer!.hasUpdate, isTrue);
      expect(older!.hasUpdate, isFalse);
    });
  });

  group('classifyFailure', () {
    DioException dio(DioExceptionType type, [Object? inner]) => DioException(
      requestOptions: RequestOptions(path: '/'),
      type: type,
      error: inner,
    );

    test('超时类归为 timeout', () {
      expect(
        classifyFailure(dio(DioExceptionType.connectionTimeout)),
        UpdateCheckFailure.timeout,
      );
      expect(
        classifyFailure(dio(DioExceptionType.receiveTimeout)),
        UpdateCheckFailure.timeout,
      );
    });

    test('域名解析失败归为 dns', () {
      expect(
        classifyFailure(const SocketException("Failed host lookup: 'api.github.com'")),
        UpdateCheckFailure.dns,
      );
    });

    test('连不上归为 connection', () {
      expect(
        classifyFailure(const SocketException('Connection refused')),
        UpdateCheckFailure.connection,
      );
    });

    test('TLS 握手失败归为 tls', () {
      expect(
        classifyFailure(const HandshakeException('bad cert')),
        UpdateCheckFailure.tls,
      );
      expect(
        classifyFailure(dio(DioExceptionType.badCertificate)),
        UpdateCheckFailure.tls,
      );
    });

    test('connectionError 会向内层错误归类（DNS 不被吞成 unknown）', () {
      expect(
        classifyFailure(
          dio(
            DioExceptionType.connectionError,
            const SocketException("Failed host lookup: 'github.com'"),
          ),
        ),
        UpdateCheckFailure.dns,
      );
    });

    test('其它异常归为 unknown', () {
      expect(classifyFailure('weird'), UpdateCheckFailure.unknown);
    });
  });

  group('describeUpdateCheckFailure', () {
    test('每种原因都有非空说明', () {
      for (final r in UpdateCheckFailure.values) {
        expect(describeUpdateCheckFailure(r).trim(), isNotEmpty);
      }
    });

    test('校园加速器开启时追加提示', () {
      final text = describeUpdateCheckFailure(
        UpdateCheckFailure.timeout,
        campusAcceleratorOn: true,
      );
      expect(text, contains('校园加速器'));
    });

    test('未开启时不提加速器', () {
      final text = describeUpdateCheckFailure(UpdateCheckFailure.timeout);
      expect(text.contains('校园加速器'), isFalse);
    });
  });
}
