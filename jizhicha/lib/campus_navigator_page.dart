import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_mode.dart';
import 'auth_pages.dart';
import 'campus_environment.dart';
import 'campus_vpn.dart';
import 'common.dart';
import 'home_page.dart';
import 'jwxt_client.dart';

class CampusNavigatorPage extends StatefulWidget {
  final String studentId;

  const CampusNavigatorPage({required this.studentId, super.key});

  @override
  State<CampusNavigatorPage> createState() => _CampusNavigatorPageState();
}

class _CampusNavigatorPageState extends State<CampusNavigatorPage> {
  bool _disconnecting = false;

  static const _links =
      <({String title, String description, String url, IconData icon})>[
        (
          title: '学校教务系统',
          description: '打开教务系统登录页面',
          url: 'http://jw.huse.cn/jsxsd/',
          icon: Icons.school,
        ),
        (
          title: '图书馆',
          description: '打开学校图书馆网站',
          url: 'https://lib.huse.edu.cn/',
          icon: Icons.local_library,
        ),
        (
          title: '知网',
          description: '打开中国知网',
          url: 'https://www.cnki.net/',
          icon: Icons.menu_book,
        ),
      ];

  Future<void> _open(String url) async {
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开此校园网址')));
    }
  }

  /// 返回应用首页（课表页），**不中断**校园加速器隧道。
  ///
  /// ## 为什么不是"返回连接页"
  ///
  /// 旧实现是把本页 `pushReplacement` 成 `VpnSetupPage` —— 但用户此刻
  /// **已经连上了**，把他送回去重新认证是反直觉的：他按返回多半只是想
  /// "回到应用里"，而不是"断开重连"。
  ///
  /// 而且连接成功后认证页已经清栈（见 `auth_pages.dart` 的 `_openTarget`），
  /// 所以这里也无法再"弹回上一页"——必须有明确的目的地。
  /// 语义上最自然的落点就是应用首页。
  ///
  /// 想断开连接的用户有明确的入口：页内的「断开加速器」按钮。
  Future<void> _returnToHome() async {
    if (_disconnecting) return;
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => HomePage(studentId: widget.studentId),
      ),
      (_) => false,
    );
  }

  Future<void> _disconnect() async {
    if (_disconnecting) return;
    setState(() => _disconnecting = true);
    try {
      // ⚠️ 顺序很重要：**先**显式声明"用户不要校园网了"（落盘持久化意图），
      // 再拆隧道。否则控制器会以为用户仍想保持连接，过几秒把他静默连回来
      // —— 变成一个人为按不掉的开关。
      //
      // 这里刻意继续用 `CampusVpnLauncher().logout()`，而不是图省事改成
      // `campusEnvironment.logout()`：前者在 Windows 上还会额外做一次
      // 「网关旧会话清理」（同账号静默认证一次再断开，让学校网关淘汰旧会话），
      // 后者只做 `session.disconnect()`，少了这一步，而且 busy 时会直接 return。
      await campusEnvironment.clearKeepAliveIntent();
      await CampusVpnLauncher().logout();
      await JwxtClient().resetSession();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => VpnSetupPage(mode: AppMode.vpnOnly),
        ),
        (_) => false,
      );
    } finally {
      if (mounted) setState(() => _disconnecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 系统返回键/手势与页内「返回」按钮走同一条路径。
    //
    // 连接成功后认证页已经清栈，本页下面是空的；若放任系统返回直接 pop，
    // 行为会与页内按钮不一致（安卓上表现为退回桌面或上一个应用），
    // 用户会以为"登录被取消了"。这里统一成"回到应用首页"。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _returnToHome();
      },
      child: _buildScaffold(context, colorScheme),
    );
  }

  Widget _buildScaffold(BuildContext context, ColorScheme colorScheme) {
    return Scaffold(
      appBar: AppBar(
        leadingWidth: 106,
        leading: TextButton.icon(
          onPressed: _disconnecting ? null : _returnToHome,
          icon: const Icon(Icons.arrow_back, size: 23),
          label: const Text('返回', style: TextStyle(fontSize: 17)),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 34),
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: colorScheme.outlineVariant),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.check_circle,
                        color: colorScheme.primary,
                        size: 34,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '校园网已连接',
                              style: TextStyle(
                                color: colorScheme.onSurface,
                                fontSize: 19,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              '学号：${widget.studentId}',
                              style: TextStyle(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  '校园服务',
                  style: TextStyle(
                    color: colorScheme.onSurface,
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                for (final link in _links) ...[
                  _CampusLinkCard(
                    title: link.title,
                    description: link.description,
                    icon: link.icon,
                    onTap: () => _open(link.url),
                  ),
                  const SizedBox(height: 10),
                ],
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _disconnecting ? null : _disconnect,
                  icon: const Icon(Icons.power_settings_new),
                  label: const Text('断开校园加速器'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CampusLinkCard extends StatelessWidget {
  final String title;
  final String description;
  final IconData icon;
  final VoidCallback onTap;

  const _CampusLinkCard({
    required this.title,
    required this.description,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          child: Row(
            children: [
              Icon(icon, color: colorScheme.primary),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.open_in_new,
                color: colorScheme.onSurfaceVariant,
                size: 19,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ErrorBox extends StatelessWidget {
  final String message;

  const ErrorBox({required this.message});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.error.withAlpha(100)),
      ),
      child: Text(
        acceleratorText(message),
        style: TextStyle(color: colorScheme.onErrorContainer, height: 1.4),
      ),
    );
  }
}
