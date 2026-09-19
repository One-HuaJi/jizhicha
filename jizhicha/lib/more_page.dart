import 'package:flutter/material.dart';

import 'fitness.dart';
import 'widget_settings_page.dart';
import 'zongce_page.dart';

/// 「暂未开放」提示的节流时间窗：1.5 秒内不重复弹，避免连点堆积 SnackBar 卡顿。
DateTime? _lastComingSoonToast;

void _showComingSoon(BuildContext context) {
  final now = DateTime.now();
  if (_lastComingSoonToast != null &&
      now.difference(_lastComingSoonToast!) <
          const Duration(milliseconds: 1500)) {
    return;
  }
  _lastComingSoonToast = now;
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    const SnackBar(
      content: Text('暂未开放，敬请期待'),
      duration: Duration(seconds: 1),
    ),
  );
}

/// 更多工具页：体测计算器 + 后续规划中的实用工具入口。
class MorePage extends StatelessWidget {
  const MorePage({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('更多')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.fitness_center),
            title: const Text('体测计算器'),
            subtitle: const Text('国家学生体质健康标准评分'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const FitnessPage()),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.assessment_outlined),
            title: const Text('综测计算器'),
            subtitle: const Text('五育加减分自评，导出 Word 自评表'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ZongcePage()),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.bolt),
            title: const Text('抢课'),
            subtitle: const Text('教务抢课助手'),
            trailing: Icon(
              Icons.lock_outline,
              color: colorScheme.onSurfaceVariant,
            ),
            onTap: () => _showComingSoon(context),
          ),
          ListTile(
            leading: const Icon(Icons.widgets),
            title: const Text('小组件（测试）'),
            subtitle: const Text('桌面小组件与上课提醒'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const WidgetSettingsPage()),
            ),
          ),
        ],
      ),
    );
  }
}
