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

  /// 上一次停留的 tab，只用来判断切换方向（决定新页从哪一侧滑入）。
  int _prevIndex = 0;

  void _onSelectTab(int i) {
    if (i == _index) return;
    setState(() {
      _prevIndex = _index;
      _index = i;
      _visited.add(i);
    });
  }

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
    // 页面切换：方向感知的淡入 + 侧移 + 微缩放（作者 2026-11-02：
    // 动画再做的丰富一点，过渡好一点）。
    //  - 往右边的 tab 切：新页从右侧滑入、旧页向左退一点；往左切反之；
    //  - 三套动画时长/曲线刻意错开（淡入 260 / 位移 320 / 缩放 320），
    //    层次比三件套齐步走更自然；
    //  - 所有页面 State 都保留（Stack + IgnorePointer），不丢滚动位置。
    final forward = _index >= _prevIndex;
    double exitOffset(int i) {
      final sign = i < _index ? -1.0 : 1.0;
      return sign * (forward ? 0.06 : 0.04);
    }

    final pageStack = Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < pages.length; i++)
          IgnorePointer(
            ignoring: i != _index,
            child: AnimatedOpacity(
              opacity: i == _index ? 1 : 0,
              duration: Duration(
                milliseconds: i == _index ? 260 : 180,
              ),
              curve: Curves.easeOutCubic,
              child: AnimatedSlide(
                offset:
                    i == _index ? Offset.zero : Offset(exitOffset(i), 0),
                duration: Duration(
                  milliseconds: i == _index ? 320 : 220,
                ),
                curve: Curves.easeOutQuart,
                child: AnimatedScale(
                  scale: i == _index ? 1 : 0.985,
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeOutCubic,
                  child: pages[i],
                ),
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
                  onDestinationSelected: _onSelectTab,
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

    // 底部导航常驻，不做折叠、不做隐藏（作者 2026-11-02：
    // 最下面四个课表成绩这些折叠删了，不要做折叠）。
    // 横屏以前会直接把 bottomNavigationBar 置 null —— 那等于横屏下
    // 完全没有 tab 可点，是个死角；现在横竖屏都常驻。
    return Scaffold(
      body: pageStack,
      bottomNavigationBar: _buildBottomNav(colorScheme),
    );
  }

  /// 底部导航栏。不折叠、不隐藏（见 build 里的说明）。
  ///
  /// `animationDuration` 从 M3 默认的 500ms 调到 320ms：切换时
  /// 指示器滑动更跟手，又不至于嗖地闪过去。
  Widget _buildBottomNav(ColorScheme colorScheme) {
    return NavigationBar(
      selectedIndex: _index,
      animationDuration: const Duration(milliseconds: 320),
      onDestinationSelected: _onSelectTab,
      destinations: [
        for (final t in _tabs)
          NavigationDestination(
            icon: Icon(t.icon),
            selectedIcon: Icon(t.icon, color: colorScheme.primary),
            label: t.label,
          ),
      ],
    );
  }
}

class _TabSpec {
  final String label;
  final IconData icon;
  const _TabSpec(this.label, this.icon);
}
