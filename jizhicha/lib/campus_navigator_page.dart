import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_mode.dart';
import 'campus_vpn.dart';
import 'common.dart';
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

  /// 返回连接页，不中断校园加速器隧道。
  Future<void> _returnToConnect() async {
    if (_disconnecting) return;
    await JwxtClient().resetSession();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => buildVpnSetupPage!(mode: AppMode.vpnOnly),
      ),
    );
  }

  Future<void> _disconnect() async {
    if (_disconnecting) return;
    setState(() => _disconnecting = true);
    try {
      await CampusVpnLauncher().logout();
      await JwxtClient().resetSession();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => buildVpnSetupPage!(mode: AppMode.vpnOnly),
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
    return Scaffold(
      appBar: AppBar(
        leadingWidth: 106,
        leading: TextButton.icon(
          onPressed: _disconnecting ? null : _returnToConnect,
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
                              '校园加速器已连接',
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
                  label: const Text('断开加速器'),
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
