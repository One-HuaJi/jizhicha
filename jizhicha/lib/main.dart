import 'dart:async' show runZonedGuarded, unawaited;

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
      //
      // ⚠️ release 下必须**什么都不输出**：`debugPrint` 在 release 包里照样写
      // stdout（Android 上就是 logcat 的 `flutter` tag），所以旧版在这里打的
      // 那一行"details suppressed in release"占位文案，本身就已经是
      // "release 包仍输出调试日志"。占位行不含隐私、但也没有任何诊断价值 ——
      // 真要看异常文本和堆栈只能靠 debug 包。故 release 直接静默返回。
      if (kReleaseMode) return;
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
      return;
    }
    if (state == AppLifecycleState.resumed) {
      // ⚠️ 回到前台必须**立刻**补一次探测（必要时静默重认证），不能等下一个
      // 定时器 tick。
      //
      // 自动重连的两个决策定时器（10 秒快探测 / 60 秒慢探测）都是 Dart
      // `Timer.periodic`。Android 不像 iOS 那样直接挂起进程，但这些定时器在
      // 息屏/后台期间并不可靠：CPU 会被挂起、Doze 会限制网络、国产 ROM 还会
      // 冻结或清理后台进程，定时器可能被拖到几分钟甚至不再触发；更糟的是
      // 后台期间的失败会把退避阶梯推到 5 分钟（见 `_reconnectSilently`）。
      // 用户"锁屏一会儿、切回来发现校园网断了且不会自己好"正是这个表现，
      // 而"切回来"这一刻是唯一确定会发生的时机。
      //
      // 不 await：生命周期回调是同步的，检查/认证在后台自己跑；异常也不能冒到
      // 框架的生命周期分发里。意图（用户主动断开后不重连）仍由
      // `handleAppResumed()` → `_reconnectSilently()` 内部把关。
      unawaited(
        campusEnvironment.handleAppResumed().catchError((Object _) {}),
      );
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
