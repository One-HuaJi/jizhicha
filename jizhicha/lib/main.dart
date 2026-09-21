import 'dart:async' show runZonedGuarded;

import 'package:flutter/foundation.dart' show debugPrint, kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_bootstrap_page.dart';
import 'campus_environment.dart';
import 'campus_vpn.dart';
import 'jwxt_client.dart';
import 'theme.dart';

void main() {
  // 用 runZonedGuarded 包一层：所有未捕获的异步异常都会进 zoneError，
  // 避免被 Flutter 静默吞掉导致 UI 看起来"卡死未响应"。
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      // 注入加速器源地址回调，避免 campus_vpn.dart 反向依赖 JwxtClient。
      CampusVpnLauncher.onSourceAddressChanged = (ip) {
        JwxtClient().setVpnSourceAddress(ip);
      };
      // 给环境控制器注入真实的内网探测与会话重置实现。
      //
      // 探测使用**教务端点**而不是校内域名服务器：实测同一时刻教务端点可达、
      // 校内域名服务器可能完全不可达。用后者当在线判据会让状态机永远停在
      // tunnelUp、UI 一直显示"离线模式"。教务端点才是用户真正要用的那个。
      campusEnvironment.configure(
        probe: ({required Duration timeout}) =>
            JwxtClient().checkIntranetReachable(timeout: timeout),
        resetSession: () => JwxtClient().resetSession(),
        onTunnelEstablished: (ip) => JwxtClient().setVpnSourceAddress(ip),
      );
      runApp(const MyApp());
    },
    (e, st) {
      // Release builds must not emit full exception text + stack traces:
      // uncaught network/file errors can contain URLs, local paths, student IDs
      // or backend response text. Keep diagnostics minimal outside debug builds.
      if (kReleaseMode) {
        debugPrint('[zoneError] uncaught async error (details suppressed in release)');
        return;
      }
      debugPrint('=== [zoneError] 未捕获异步异常: $e');
      debugPrint('$st');
    },
  );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    themeNotifier.addListener(_onThemeChanged);
    ThemeService.load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    CampusVpnLauncher.shutdownNow();
    // 全局环境控制器持有 60 秒健康检查定时器，进程退出时一并停掉，
    // 避免测试或热重启场景下定时器继续持有回调。
    campusEnvironment.dispose();
    themeNotifier.removeListener(_onThemeChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      CampusVpnLauncher.shutdownNow();
    }
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '稽之查',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeNotifier.value,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const AppBootstrapPage(),
    );
  }
}
