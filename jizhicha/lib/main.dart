import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, MethodChannel, FilteringTextInputFormatter;
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' show parse;
import 'package:image/image.dart' as img;
import 'package:ffi/ffi.dart' as ffi_utils;
import 'package:path_provider/path_provider.dart';
import 'package:gal/gal.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:async' show Timer, runZonedGuarded, unawaited;
import 'dart:io'
    show Directory, File, HttpClient, InternetAddress, Platform, Socket;

import 'academic_calendar.dart';
import 'app_mode.dart';
import 'app_settings.dart';
import 'auth_pages.dart';
import 'campus_environment.dart';
import 'campus_navigator_page.dart';
import 'campus_vpn.dart';
import 'captcha_ocr.dart';
import 'common.dart';
import 'credential_store.dart';
import 'fitness.dart';
import 'grades_page.dart';
import 'jwxt_client.dart';
import 'offline_sync.dart';
import 'schedule_cache_store.dart';
import 'schedule_page.dart';
import 'schedule_time.dart';
import 'settings_page.dart';
import 'sync_cooldown.dart';
import 'theme.dart';
import 'ui_constants.dart';
import 'update_check.dart';


void main() {
  // 用 runZonedGuarded 包一层：所有未捕获的异步异常都会进 zoneError，
  // 避免被 Flutter 静默吞掉导致 UI 看起来"卡死未响应"。
  // VS Code 调试控制台会直接看到 stack trace，下次卡住能精确定位。
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      // 注入加速器源地址回调，避免 campus_vpn.dart 反向依赖 JwxtClient。
      CampusVpnLauncher.onSourceAddressChanged = (ip) {
        JwxtClient().setVpnSourceAddress(ip);
      };
      // 注入校园内网探测与会话重置回调，避免 campus_environment.dart 反向依赖 JwxtClient。
      CampusEnvironmentController.onCheckCampusReachable = ({
        required Duration timeout,
      }) =>
          JwxtClient().checkCampusNameServerReachable(timeout: timeout);
      CampusEnvironmentController.onResetSession =
          () => JwxtClient().resetSession();
      // 注入切换账号的目标页面构建回调，打破 common.dart 对页面类的循环依赖。
      buildAccountDestination = (studentId, hasLocalData) {
        if (hasLocalData) return HomePage(studentId: studentId);
        return const VpnSetupPage(
          mode: AppMode.education,
          initialNotice: '您之前未进行过认证，本地暂无存储，请认证后保存课表',
        );
      };
      buildVpnSetupPage = ({
        required mode,
        initialNotice,
        gradeSyncScope = GradeSyncScope.latest,
        syncSchedules = true,
        forceScheduleSync = false,
        fetchAllSchedules = false,
        scheduleTerm,
        gradeTerm,
        syncGrades = true,
      }) =>
          VpnSetupPage(
            mode: mode,
            initialNotice: initialNotice,
            gradeSyncScope: gradeSyncScope,
            syncSchedules: syncSchedules,
            forceScheduleSync: forceScheduleSync,
            fetchAllSchedules: fetchAllSchedules,
            scheduleTerm: scheduleTerm,
            gradeTerm: gradeTerm,
            syncGrades: syncGrades,
          );
      navigateToBootstrap = (context) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const AppBootstrapPage()),
          (_) => false,
        );
      };
      buildHomePage = (studentId, initialNotice) =>
          HomePage(studentId: studentId, initialNotice: initialNotice);
      runApp(const MyApp());
    },
    (e, st) {
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

/// 应用启动时优先展示本机已经保存的离线课表与成绩。
///
/// 只有在本机没有任何可展示的教务课表时才进入加速器认证页。这样离线时也能
/// 查看自己的已保存课表，同时不会因为启动应用而额外向校园网发起请求。
class AppBootstrapPage extends StatefulWidget {
  const AppBootstrapPage({super.key});

  @override
  State<AppBootstrapPage> createState() => _AppBootstrapPageState();
}

class _AppBootstrapPageState extends State<AppBootstrapPage> {
  Widget? _destination;

  @override
  void initState() {
    super.initState();
    _resolveStartupDestination();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkForUpdates();
    });
  }

  Future<void> _resolveStartupDestination() async {
    final accounts = await CredentialStore.load(StoredAccountKind.education);
    StoredAccount? account;
    for (final candidate in accounts) {
      final profile = await UserDataCacheStore.loadProfile(candidate.username);
      final legacySchedule = profile == null
          ? await ScheduleCacheStore.loadLatest(candidate.username)
          : null;
      if (profile != null || legacySchedule != null) {
        account = candidate;
        break;
      }
    }

    if (!mounted) return;
    setState(() {
      _destination = account != null
          ? HomePage(studentId: account.username)
          : const VpnSetupPage(
              mode: AppMode.vpnOnly,
              initialNotice: '您之前未进行过认证，本地暂无存储，请认证后保存课表',
            );
    });
  }

  Future<void> _checkForUpdates() async {
    try {
      final settings = await AppSettings.load();
      if (settings.updateCheckDisabled) return;
      final info = await fetchLatestRelease();
      if (info == null || !mounted) return;
      if (compareVersions(info['version'] ?? '', currentAppVersion) <= 0) {
        return;
      }
      if (!mounted) return;
      await showUpdateDialog(context, info['version'] ?? '', info['downloadUrl'] ?? '');
    } catch (_) {
      // 静默失败：网络异常等不打扰用户。
    }
  }

  @override
  Widget build(BuildContext context) {
    // 启动时从加载态到内容用淡入过渡，避免第一屏硬切。
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: _destination ??
          const Scaffold(
            key: ValueKey('bootstrap-loading'),
            body: Center(child: CircularProgressIndicator()),
          ),
    );
  }
}







// ==================== 首页 ====================



/// 教务首页（带底部导航栏的壳）。首页课表优先显示此账号本地保存的最新学期，
/// 因此即使未连接加速器也能查看历史缓存。
class HomePage extends StatefulWidget {
  final String studentId;
  final String? initialNotice;

  const HomePage({required this.studentId, this.initialNotice, super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;
  final Set<int> _visited = {0};

  @override
  void initState() {
    super.initState();
    campusEnvironment.detect();
    final notice = widget.initialNotice;
    if (notice != null && notice.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(notice)));
      });
    }
  }

  // 顺序：1.学期课表 2.成绩查询 3.体测成绩计算器 4.设置（用户要求放最后）
  static const _tabs = <_TabSpec>[
    _TabSpec('课表', Icons.calendar_today),
    _TabSpec('成绩', Icons.grade),
    _TabSpec('体测', Icons.fitness_center),
    _TabSpec('设置', Icons.settings),
  ];

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    Widget pageAt(int i) {
      switch (i) {
        case 0:
          return SchedulePage(studentId: widget.studentId);
        case 1:
          return GradesPage(studentId: widget.studentId);
        case 2:
          return const FitnessPage();
        case 3:
          return SettingsPage(studentId: widget.studentId);
        default:
          return const SizedBox.shrink();
      }
    }

    // 懒加载：只在首次进入某页时才构建，降低首屏构建开销。
    final pages = <Widget>[
      for (var i = 0; i < _tabs.length; i++)
        _visited.contains(i) ? pageAt(i) : const SizedBox.shrink(),
    ];
    // 保留每个页面 State，并用轻微淡入/平移动画切换，避免页面像被硬切开。
    final pageStack = Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < pages.length; i++)
          IgnorePointer(
            ignoring: i != _index,
            child: AnimatedOpacity(
              opacity: i == _index ? 1 : 0,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: AnimatedSlide(
                offset: i == _index ? Offset.zero : const Offset(0.025, 0),
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                child: pages[i],
              ),
            ),
          ),
      ],
    );

    // 桌面端使用侧边导航，避免把宽屏也套成手机底部导航；手机仍保留
    // 底部导航，保证单手操作和已有用户习惯不变。
    final desktop = MediaQuery.sizeOf(context).width >= 900;
    if (desktop) {
      return Scaffold(
        body: Row(
          children: [
            SafeArea(
              child: Material(
                color: colorScheme.surfaceContainerLow,
                child: NavigationRail(
                  minWidth: 82,
                  groupAlignment: -0.55,
                  labelType: NavigationRailLabelType.all,
                  selectedIndex: _index,
                  onDestinationSelected: (i) => setState(() {
                    _index = i;
                    _visited.add(i);
                  }),
                  indicatorColor: colorScheme.primaryContainer,
                  destinations: [
                    for (final t in _tabs)
                      NavigationRailDestination(
                        icon: Icon(t.icon),
                        selectedIcon: Icon(t.icon),
                        label: Text(t.label),
                      ),
                  ],
                ),
              ),
            ),
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: colorScheme.outlineVariant.withAlpha(110),
            ),
            Expanded(child: pageStack),
          ],
        ),
      );
    }

    return Scaffold(
      body: pageStack,
      bottomNavigationBar:
          MediaQuery.orientationOf(context) == Orientation.landscape
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() {
                    _index = i;
                    _visited.add(i);
                  }),
              destinations: [
                for (final t in _tabs)
                  NavigationDestination(
                    icon: Icon(t.icon),
                    selectedIcon: Icon(t.icon, color: colorScheme.primary),
                    label: t.label,
                  ),
              ],
            ),
    );
  }
}

class _TabSpec {
  final String label;
  final IconData icon;
  const _TabSpec(this.label, this.icon);
}

