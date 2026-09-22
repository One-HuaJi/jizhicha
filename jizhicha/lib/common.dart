import 'package:flutter/material.dart';

import 'app_bootstrap_page.dart';
import 'app_mode.dart';
import 'auth_pages.dart';
import 'campus_environment.dart';
import 'credential_store.dart';
import 'home_page.dart';
import 'jwxt_client.dart';
import 'schedule_cache_store.dart';
import 'widget_schedule_store.dart';

/// 首页的页面栈会保留课表、成绩与设置页各自的 State。设置写入本地文件后，
/// 通过统一修订号通知其它仍在内存中的页面立即重新读取，避免必须重启或重新登录。
final ValueNotifier<int> appSettingsRevision = ValueNotifier<int>(0);

/// 用户可见文案的**兜底脱敏**。
///
/// [acceleratorText] 是所有校园网错误/进度文案走到屏幕的**唯一漏斗**
/// （认证页、导航页、各处 SnackBar 都经过它），所以在出口再兜一道：
/// 无论上游（原生 status 的 `message`、异常文本）带了什么，都不该把隐私
/// 显示到屏幕上。
///
/// 抹掉两类：
///   - **会话级虚拟 IP**（`172.16.x.x`）—— 本次连接分配的地址。
///     ⚠️ 只抹 `172.16.`：校园服务地址（如 `172.20.x.x`）是允许出现在源码与
///     提示里的，误伤它会让人看不懂错误信息。
///   - **12 位学号形态** —— 仅放行已文档化的占位号段 `2024000000xx`。
///
/// 真正的防线在**源头**（Dart 侧 `_redactStatusForDisplay`、Kotlin 侧
/// `redactStatus()`）；这里只是防止将来新增的路径漏掉脱敏。
String _scrubPrivateForDisplay(String text) {
  var out = text.replaceAll(
    RegExp(r'\b172\.16\.\d{1,3}\.\d{1,3}\b'),
    '<校园网地址>',
  );
  out = out.replaceAllMapped(RegExp(r'\b(20\d{2})(\d{8})\b'), (match) {
    final id = '${match[1]}${match[2]}';
    return id.startsWith('2024000000') ? id : '<学号>';
  });
  return out;
}

String acceleratorText(Object value) {
  final text = '$value';
  if (text.toLowerCase().contains('spki pin mismatch')) {
    return '校园加速器网关身份验证失败：服务器证书与应用内置安全指纹不一致。'
        '为保护账号密码，连接已中止，请联系作者核对网关证书。';
  }
  return _scrubPrivateForDisplay(
    text.replaceAll(RegExp('vpn', caseSensitive: false), '校园加速器'),
  );
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
          // 原文案 80+ 字、夹半角逗号、结尾"我们无能为力"偏消极。
          // 拆成三段，用中文标点，并给出可执行的下一步。
          '学号：学校下发的 12 位纯数字学号，格式为「年份 + 专业 + 系别 + 序号」。\n\n'
          '密码：身份证后六位。\n\n'
          '如果提示无法登录，通常是学校尚未把该学号录入或开通。'
          '这需要学校侧处理，请联系辅导员或教务处确认后再试。',
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
  // Keep the single global widget cache aligned with the newly selected
  // account. If it has no schedule, writeCurrentSchedule clears prior data.
  await WidgetScheduleStore.writeCurrentSchedule(account.username);
  if (!context.mounted) return;
  final hasLocalData = cached != null || profile != null;
  // 原先这里走 buildAccountDestination 注入回调，现改为编译期直接依赖：
  // 依赖方向固定为 common → pages，由本文件单向导入各页面即可。
  // 不再需要运行时可空的函数指针（漏注入会在运行时才崩，且测试覆盖不到）。
  final destination = hasLocalData
      ? HomePage(studentId: account.username)
      : VpnSetupPage(
          mode: AppMode.education,
          // 与「首次进入」保持一致：目标账号在本机还没有数据时，用户要的是
          // **登录教务把数据取回来**，而不是去校园导航页。`VpnSetupPage` 会按
          // "调用方是否带同步意图"决定主按钮出口，这里用 forceScheduleSync 表达
          // 该意图；对一个还没有任何本地数据的账号，它在同步层面是空操作
          // （没有旧数据可强制刷新），只影响主按钮指向。
          forceScheduleSync: true,
          initialNotice: '该账号在本机还没有课表，需要先登录一次教务系统',
        );
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => destination),
    (_) => false,
  );
}

/// 退出登录/删除账号后回到启动页（AppBootstrapPage）。
void navigateToBootstrap(BuildContext context) {
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const AppBootstrapPage()),
    (_) => false,
  );
}

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
  // 判据必须与**按钮显示**用同一套，否则按钮会说谎。
  //
  // 隧道只要还在（`online` 或 `acceleratorUp`），这个按钮的语义就是"登出"：
  // 界面正是按 `online || acceleratorUp` 把它显示成「登出校园加速器」的。
  // 曾经这里只看 `online`，于是"隧道已建立、但校园网探测还没通过"
  // （`acceleratorUp && !online`）那一态会出现
  // **「按钮写着登出，点下去却跳到认证页」** —— 用户想关掉隧道却关不掉，
  // 而那时隧道可能正在耗电。
  //
  // 为什么这样改是安全的：登出**不发送任何校园网请求**（只是拆隧道 + 清
  // 教务 Cookie），所以不存在"放行未经探测的请求"的风险 —— 那条约束针对的是
  // 能不能**发**请求，与"能不能**断**"无关。
  if (campusEnvironment.online != true &&
      campusEnvironment.acceleratorUp != true) {
    await openVpnSetup();
    return;
  }
  try {
    await campusEnvironment.logout();
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('登出校园加速器失败：${acceleratorText(error)}')),
      );
    }
  }
}
