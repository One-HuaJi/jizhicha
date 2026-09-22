// 模式选择页：选择"仅连接校园网"或"连接校园网并进入教务"。
import 'package:flutter/material.dart';

import '../app_mode.dart';
import 'vpn_setup_page.dart';

// ==================== 登录页 ====================

class ModeSelectionPage extends StatelessWidget {
  const ModeSelectionPage({super.key});

  void _openMode(BuildContext context, AppMode mode) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => VpnSetupPage(mode: mode)));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 46, 24, 32),
              children: [
                Icon(Icons.school, size: 64, color: colorScheme.primary),
                const SizedBox(height: 18),
                Text(
                  '稽之查校园助手',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colorScheme.onSurface,
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '选择你要使用的服务',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 42),
                _ModeCard(
                  icon: Icons.vpn_lock,
                  title: '仅连接校园网',
                  description: '连接校园网后访问校园导航、教务网址、图书馆等服务',
                  color: colorScheme.primary,
                  onTap: () => _openMode(context, AppMode.vpnOnly),
                ),
                const SizedBox(height: 18),
                _ModeCard(
                  icon: Icons.auto_graph,
                  title: '连接校园网并进入教务',
                  description: '先连接校园网，再使用独立的教务系统密码登录查询',
                  color: colorScheme.tertiary,
                  onTap: () => _openMode(context, AppMode.education),
                ),
                const SizedBox(height: 34),
                Text(
                  '账号密码仅在认证成功后加密保存在本机，可在下次登录时快速填充。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant.withAlpha(180),
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final Color color;
  final VoidCallback onTap;

  const _ModeCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Row(
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: color.withAlpha(46),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Icon(icon, color: color, size: 30),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: colorScheme.onSurface,
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      description,
                      style: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
