import 'package:flutter/material.dart';

import 'app_mode.dart';
import 'app_settings.dart';
import 'auth_pages.dart';
import 'credential_store.dart';
import 'home_page.dart';
import 'schedule_cache_store.dart';
import 'update_check.dart';

/// 应用启动时优先展示本机已经保存的离线课表与成绩。
///
/// 只有在本机没有任何可展示的教务课表时才进入加速器认证页。这样离线时也能
/// 查看自己的已保存课表，同时不会因为启动应用而额外向校园网发起请求。
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
