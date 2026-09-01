import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/material.dart';

import 'app_mode.dart';
import 'campus_environment.dart';
import 'credential_store.dart';
import 'jwxt_client.dart';
import 'schedule_cache_store.dart';
import 'sync_cooldown.dart';

/// 首页的页面栈会保留课表、成绩与设置页各自的 State。设置写入本地文件后，
/// 通过统一修订号通知其它仍在内存中的页面立即重新读取，避免必须重启或重新登录。
final ValueNotifier<int> appSettingsRevision = ValueNotifier<int>(0);

String acceleratorText(Object value) {
  final text = '$value';
  if (text.toLowerCase().contains('spki pin mismatch')) {
    return '加速器网关身份验证失败：服务器证书与应用内置安全指纹不一致。'
        '为保护账号密码，连接已中止，请联系作者核对网关证书。';
  }
  return text.replaceAll(RegExp('vpn', caseSensitive: false), '加速器');
}

void notifyAppSettingsChanged() {
  appSettingsRevision.value += 1;
}

Future<void> showStudentIdHelp(BuildContext context) async {
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.help_outline),
          SizedBox(width: 8),
          Text('账号填写说明'),
        ],
      ),
      content: const SingleChildScrollView(
        child: SelectableText(
          '学号为湘科院官方下发的纯数字学号，格式为[年份][专业][系别][学号]的十二位纯数字学号，密码为身份证后六位,若显示无法登陆则可能校方并未录入数据，我们无能为力，请静待校方添加。',
          style: TextStyle(height: 1.6),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}

Future<bool> confirmAccountAction(
  BuildContext context, {
  required String message,
  bool orangeText = false,
  String confirmLabel = '确定',
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      content: Text(
        message,
        style: orangeText
            ? TextStyle(
                color: Colors.orange.shade800,
                fontWeight: FontWeight.w700,
              )
            : null,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

Future<StoredAccount?> pickSavedEducationAccount(
  BuildContext context, {
  required String currentStudentId,
}) async {
  final accounts = await CredentialStore.load(StoredAccountKind.education);
  if (!context.mounted) return null;
  if (accounts.isEmpty) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('暂无本地保存的教务账号')));
    return null;
  }
  return showModalBottomSheet<StoredAccount>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const ListTile(
            title: Text('选择要查看的账号课表'),
            subtitle: Text('切换不会断开校园加速器'),
          ),
          for (final account in accounts)
            ListTile(
              leading: Icon(
                account.username == currentStudentId
                    ? Icons.check_circle
                    : Icons.account_circle_outlined,
              ),
              title: Text(account.username),
              subtitle: Text(
                account.username == currentStudentId ? '当前账号' : '查看本地保存课表',
              ),
              onTap: () => Navigator.of(sheetContext).pop(account),
            ),
        ],
      ),
    ),
  );
}

/// 由 main.dart 注入：根据学号和是否有本地数据，构建切换账号后的目标页面。
/// 用回调打破 common.dart 对 HomePage / VpnSetupPage 的循环依赖。
Widget Function(String studentId, bool hasLocalData)? buildAccountDestination;

/// 切换仅影响当前展示与教务 Cookie；校园加速器不会断开。
Future<void> switchToSavedAccount(
  BuildContext context, {
  required String currentStudentId,
}) async {
  final account = await pickSavedEducationAccount(
    context,
    currentStudentId: currentStudentId,
  );
  if (account == null ||
      account.username == currentStudentId ||
      !context.mounted) {
    return;
  }
  final confirmed = await confirmAccountAction(context, message: '确定切换吗？');
  if (!confirmed) return;

  await JwxtClient().resetSession();
  final cached = await ScheduleCacheStore.loadLatest(account.username);
  final profile = await UserDataCacheStore.loadProfile(account.username);
  if (!context.mounted) return;
  final hasLocalData = cached != null || profile != null;
  final destination = buildAccountDestination!(account.username, hasLocalData);
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => destination),
    (_) => false,
  );
}

/// 由 main.dart 注入：构建加速器认证页（VpnSetupPage）。
/// 用回调打破 common/页面 对 VpnSetupPage 的循环依赖。
Widget Function({
  required AppMode mode,
  String? initialNotice,
  GradeSyncScope gradeSyncScope,
  bool syncSchedules,
  bool forceScheduleSync,
  bool fetchAllSchedules,
  String? scheduleTerm,
  String? gradeTerm,
  bool syncGrades,
})? buildVpnSetupPage;

/// 由 main.dart 注入：退出登录/删除账号后回到启动页（AppBootstrapPage）。
void Function(BuildContext context)? navigateToBootstrap;

/// 由 main.dart 注入：构建教务首页（HomePage），登录成功后跳转用。
Widget Function(String studentId, String? initialNotice)? buildHomePage;

/// 课表页与成绩页共用的加速器按钮逻辑：在线则登出，离线则跳认证页。
Future<void> handleCampusAcceleratorAction(
  BuildContext context, {
  required Future<void> Function() openVpnSetup,
}) async {
  if (campusEnvironment.checking ||
      campusEnvironment.actionLoading ||
      campusEnvironment.reconnecting) {
    return;
  }
  if (campusEnvironment.online != true) {
    await openVpnSetup();
    return;
  }
  try {
    await campusEnvironment.logout();
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('登出加速器失败：${acceleratorText(error)}')),
      );
    }
  }
}
