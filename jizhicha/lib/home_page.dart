import 'package:flutter/material.dart';

import 'campus_environment.dart';
import 'grades_page.dart';
import 'more_page.dart';
import 'schedule_page.dart';
import 'settings_page.dart';

/// 教务首页（带底部导航栏的壳）。首页课表优先显示此账号本地保存的最新学期，
/// 因此即使未连接加速器也能查看历史缓存。
///
/// 从 `main.dart` 拆出：它被多处需要（登录成功后跳转、删除账号后回首页、
/// 启动页判定），留在 `main.dart` 里会迫使其他模块反向依赖入口文件，
/// 只能靠注入回调绕开循环依赖。
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

  // 顺序：1.学期课表 2.成绩查询 3.更多工具 4.设置（用户要求放最后）
  static const _tabs = <_TabSpec>[
    _TabSpec('课表', Icons.calendar_today),
    _TabSpec('成绩', Icons.grade),
    _TabSpec('更多', Icons.apps),
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
          return const MorePage();
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
