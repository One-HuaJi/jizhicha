import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import 'app_mode.dart';
import 'app_settings.dart';
import 'auth_pages.dart';
import 'campus_environment.dart';
import 'credential_store.dart';
import 'home_page.dart';
import 'schedule_cache_store.dart';
import 'update_check.dart';

/// 应用启动时优先展示本机已经保存的离线课表与成绩。
///
/// 只有在本机没有任何可展示的教务课表时才进入认证页；此时默认走**教务**这条
/// 路径（第一次使用必须先登录一次教务系统并保存离线数据），而不是只连校园网。
/// 这样离线时也能查看自己的已保存课表，同时不会因为启动应用而额外向校园网
/// 发起请求。
///
/// 从 `main.dart` 拆出：`common.dart` 的 `navigateToBootstrap` 需要直接
/// 构建本页（退出登录后回到启动页），留在入口文件会造成反向依赖。
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
          // 需求 1（首次进入默认走教务路径）：本机没有任何课表/成绩时，直接
          // 落到"连接校园网并进入教务系统"这条路径 —— 第一次必须登录一次
          // 教务系统并保存离线数据，之后启动才能直接进主页。
          : const VpnSetupPage(
              mode: AppMode.education,
              // ⚠️ 这里的 `forceScheduleSync` 不是为了强制重抓课表：本机既然
              // 没有任何本地数据，同步本来就会抓课表（见 offline_sync.dart
              // 的 `!hadScheduleBefore` 分支）。它只是让 VpnSetupPage 把主按钮
              // 指向教务登录页 —— 该页按"调用方是否带同步意图"决定出口，见
              // vpn_setup_page.dart 的 `_connectButtons`。
              forceScheduleSync: true,
              initialNotice: '第一次使用需要先用教务系统账号登录一次，之后就无需重复认证了',
            );
    });

    // 需求 2（之后每次打开：静默认证校园网）：本机已有本地数据 → 直接进主页，
    // 同时在后台静默认证一次校园网，让"校园网可用"尽快就位。
    //
    // 三条硬约束：
    //   1. **不 await**：首屏（HomePage）已经 setState 出去，认证在后台自己跑；
    //   2. **不 setState、不弹提示**：静默就是静默，失败也由校园网自己的
    //      状态提示负责（`consumeDropDetected`），这里不打扰用户；
    //   3. `ensureCampusAlive(silent: true)` 内部保证"用户主动登出后不重连"，
    //      我们不碰这个意图，也不在这里做任何 disconnect。
    // 再兜一层 catchError：启动路径不该冒出无人处理的异步错误。
    if (account != null) {
      unawaited(
        campusEnvironment.ensureCampusAlive().catchError((Object _) => false),
      );
    }
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
