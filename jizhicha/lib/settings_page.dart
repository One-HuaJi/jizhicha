import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:url_launcher/url_launcher.dart';

import 'academic_calendar.dart';
import 'app_settings.dart';
import 'campus_environment.dart';
import 'campus_vpn.dart';
import 'common.dart';
import 'credential_store.dart';
import 'jwxt_client.dart';
import 'schedule_cache_store.dart';
import 'schedule_time.dart';
import 'theme.dart';
import 'update_check.dart';

// ==================== 设置页 ====================
class SettingsPage extends StatefulWidget {
  final String studentId;

  const SettingsPage({required this.studentId, super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AppSettings? _settings;
  bool _accountActionLoading = false;
  bool _versionChecking = false;
  String _versionStatus = '';

  @override
  void initState() {
    super.initState();
    appSettingsRevision.addListener(_reloadSettings);
    _load();
    _refreshVersionStatus();
  }

  @override
  void dispose() {
    appSettingsRevision.removeListener(_reloadSettings);
    super.dispose();
  }

  void _reloadSettings() {
    _load();
  }

  Future<void> _load() async {
    final s = await AppSettings.load();
    if (mounted) setState(() => _settings = s);
  }

  Future<void> _persist({bool notify = false}) async {
    await _settings?.save();
    if (notify) notifyAppSettingsChanged();
  }

  Future<void> _refreshVersionStatus() async {
    try {
      final info = await fetchLatestRelease();
      if (!mounted) return;
      final version = info?['version'] ?? '';
      String status;
      if (info == null || version.isEmpty) {
        status = '检测失败';
      } else if (compareVersions(version, currentAppVersion) > 0) {
        status = '有新版本 v$version';
      } else {
        status = '已是最新版本';
      }
      if (mounted) setState(() => _versionStatus = status);
    } catch (_) {
      if (mounted) setState(() => _versionStatus = '检测失败');
    }
  }

  Future<void> _checkVersion() async {
    if (_versionChecking) return;
    setState(() => _versionChecking = true);
    try {
      final info = await fetchLatestRelease();
      if (!mounted) return;
      final version = info?['version'] ?? '';
      if (info == null || version.isEmpty) {
        setState(() {
          _versionChecking = false;
          _versionStatus = '检测失败';
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('检测失败，请检查网络')));
        return;
      }
      if (compareVersions(version, currentAppVersion) > 0) {
        setState(() {
          _versionChecking = false;
          _versionStatus = '有新版本 v$version';
        });
        await showUpdateDialog(context, version, info['downloadUrl'] ?? '');
      } else {
        setState(() {
          _versionChecking = false;
          _versionStatus = '已是最新版本';
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已是最新版本')));
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _versionChecking = false;
          _versionStatus = '检测失败';
        });
      }
    }
  }

  /// 退出时彻底关闭加速器；本地加密账号保留，便于下次在登录页快速填充。
  Future<void> _logout() async {
    if (_accountActionLoading) return;
    final confirmed = await confirmAccountAction(context, message: '确定退出吗？');
    if (!confirmed || !mounted) return;
    setState(() => _accountActionLoading = true);
    try {
      await CampusVpnLauncher().logout();
      await JwxtClient().resetSession();
      if (!mounted) return;
      navigateToBootstrap(context);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('退出登录失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _accountActionLoading = false);
    }
  }

  /// 只清理旧教务会话，不动加速器隧道和加速器源地址。
  Future<void> _switchUser() async {
    if (_accountActionLoading) return;
    setState(() => _accountActionLoading = true);
    try {
      await switchToSavedAccount(context, currentStudentId: widget.studentId);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('切换用户失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _accountActionLoading = false);
    }
  }

  Future<void> _deleteLocalAccountInfo() async {
    if (_accountActionLoading) return;
    if (!await confirmAccountAction(context, message: '确定删除吗？') || !mounted) {
      return;
    }
    if (!await confirmAccountAction(
          context,
          message: '删除后无法恢复，确定吗？',
          orangeText: true,
        ) ||
        !mounted) {
      return;
    }
    setState(() => _accountActionLoading = true);
    try {
      // 必须先断开：logout 需要读取当前账号的安全存储，以便静默清理学校网关
      // 可能遗留的会话；删除后再执行会失去该凭据。
      await CampusVpnLauncher().logout();
      await JwxtClient().resetSession();
      final credentialsDeleted = await CredentialStore.deleteAll();
      final userDataDeleted = await UserDataCacheStore.clearAll();
      final scheduleDeleted = await ScheduleCacheStore.clearAll();
      final failures = <String>[
        if (!credentialsDeleted) '加密账号',
        if (!userDataDeleted) '成绩与课表快照',
        if (!scheduleDeleted) '旧版课表缓存',
      ];
      if (failures.isNotEmpty) {
        throw '无法彻底删除：${failures.join('、')}';
      }
      if (!mounted) return;
      navigateToBootstrap(context);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('删除本地信息失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _accountActionLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _settings ?? AppSettings();
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SizedBox(height: 18),

          // ==================== 外观设置 ====================
          _buildSectionHeader(Icons.palette, '外观'),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.dark_mode, color: colorScheme.primary),
                      const SizedBox(width: 16),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('外观颜色'),
                            SizedBox(height: 3),
                            Text('跟随系统（默认），也可以手动选择浅色或深色'),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<ThemeMode>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: ThemeMode.light,
                          label: Text('浅色'),
                          icon: Icon(Icons.light_mode),
                        ),
                        ButtonSegment(
                          value: ThemeMode.dark,
                          label: Text('深色'),
                          icon: Icon(Icons.dark_mode),
                        ),
                        ButtonSegment(
                          value: ThemeMode.system,
                          label: Text('系统'),
                          icon: Icon(Icons.auto_mode),
                        ),
                      ],
                      selected: <ThemeMode>{themeNotifier.value},
                      onSelectionChanged: (selection) {
                        final mode = selection.first;
                        themeNotifier.value = mode;
                        ThemeService.save(mode);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),

          // ==================== 课表设置 ====================
          _buildSectionHeader(Icons.calendar_today, '课表设置'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text(
                    '本周视图（高亮当周）',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text('在课表中高亮"当前周次"有课的课程，便于一眼看清本周安排。切换后立即应用。'),
                  secondary: Icon(Icons.highlight, color: colorScheme.primary),
                  value: s.highlightCurrentWeek,
                  onChanged: _settings == null
                      ? null
                      : (v) {
                          setState(() {
                            _settings!.highlightCurrentWeek = v;
                            if (v) _settings!.filterByWeek = false;
                          });
                          _persist(notify: true);
                        },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text(
                    '按周筛选（仅显示当周课程）',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text(
                    '已默认开启：切换到某一周后，只显示该周有课的课程，其它周次课程自动隐藏。关闭则显示全部周；切换后立即应用。',
                  ),
                  secondary: Icon(Icons.filter_alt, color: colorScheme.primary),
                  value: s.filterByWeek,
                  onChanged: _settings == null
                      ? null
                      : (v) {
                          setState(() {
                            _settings!.filterByWeek = v;
                            if (v) _settings!.highlightCurrentWeek = false;
                          });
                          _persist(notify: true);
                        },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(Icons.event, color: colorScheme.primary),
                  title: const Text('开学日期'),
                  subtitle: const Text('第一周周一，用于自动计算当前周次'),
                  trailing: TextButton(
                    onPressed: _settings == null
                        ? null
                        : () async {
                            final current = DateTime.tryParse(
                                  s.semesterStartDate,
                                ) ??
                                DateTime(2026, 9, 7);
                            final picked = await _pickSemesterStartDate(current);
                            if (picked == null) return;
                            setState(() {
                              _settings!.semesterStartDate = picked
                                  .toIso8601String()
                                  .substring(0, 10);
                            });
                            _persist(notify: true);
                          },
                    child: Text(s.semesterStartDate),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(Icons.date_range, color: colorScheme.primary),
                  title: const Text('当前周次'),
                  subtitle: const Text('每学期按20周显示。'),
                  trailing: DropdownButton<int>(
                    value: s.currentWeek,
                    items:
                        List.generate(
                              AcademicCalendar.weeksPerAcademicYear,
                              (i) => i + 1,
                            )
                            .map(
                              (w) => DropdownMenuItem(
                                value: w,
                                child: Text('第$w周'),
                              ),
                            )
                            .toList(),
                    onChanged: _settings == null
                        ? null
                        : (v) {
                            setState(() => _settings!.currentWeek = v!);
                            _persist(notify: true);
                          },
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(
                    Icons.view_week_outlined,
                    color: colorScheme.primary,
                  ),
                  title: const Text('显示筛选'),
                  subtitle: const Text('课表显示天数'),
                  trailing: SegmentedButton<bool>(
                    showSelectedIcon: false,
                    style: _scheduleSegmentedStyle(colorScheme),
                    segments: const [
                      ButtonSegment(value: false, label: Text('五天')),
                      ButtonSegment(value: true, label: Text('七天')),
                    ],
                    selected: {s.showWeekend},
                    onSelectionChanged: _settings == null
                        ? null
                        : (selection) {
                            setState(
                              () => _settings!.showWeekend = selection.first,
                            );
                            _persist(notify: true);
                          },
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(Icons.text_fields, color: colorScheme.primary),
                  title: const Text('课表文字大小'),
                  subtitle: const Text('课程字号'),
                  trailing: SegmentedButton<int>(
                    showSelectedIcon: false,
                    style: _scheduleSegmentedStyle(colorScheme),
                    segments: const [
                      ButtonSegment(value: 0, label: Text('小')),
                      ButtonSegment(value: 1, label: Text('中')),
                      ButtonSegment(value: 2, label: Text('大')),
                    ],
                    selected: {s.scheduleTextSize},
                    onSelectionChanged: _settings == null
                        ? null
                        : (selection) {
                            setState(
                              () => _settings!.scheduleTextSize =
                                  selection.first,
                            );
                            _persist(notify: true);
                          },
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(Icons.schedule, color: colorScheme.primary),
                  title: const Text('课表节次时间'),
                  subtitle: Text(
                    s.scheduleTimeMode == ScheduleTimeMode.automatic
                        ? '自动按本机日期切换：1–4月、10–12月春秋冬季，5–9月夏季'
                        : '固定使用${s.scheduleTimeMode.label}作息时间',
                  ),
                  trailing: DropdownButton<ScheduleTimeMode>(
                    value: s.scheduleTimeMode,
                    isDense: true,
                    items: ScheduleTimeMode.values
                        .map(
                          (mode) => DropdownMenuItem(
                            value: mode,
                            child: Text(mode.label),
                          ),
                        )
                        .toList(),
                    onChanged: _settings == null
                        ? null
                        : (mode) {
                            if (mode == null) return;
                            setState(() => _settings!.scheduleTimeMode = mode);
                            _persist(notify: true);
                          },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          // ==================== 成绩设置 ====================
          _buildSectionHeader(Icons.grade, '成绩设置'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text(
                    '按及格/不及格分类',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text(
                    '已默认开启：开启后把得分≥60 归入"已完成"，其余归入"历史补考/重修"。关闭则所有课程混在一起展示。',
                  ),
                  secondary: Icon(Icons.category, color: colorScheme.primary),
                  value: s.gradeCategoryEnabled,
                  onChanged: _settings == null
                      ? null
                      : (v) {
                          setState(() => _settings!.gradeCategoryEnabled = v);
                          _persist(notify: true);
                        },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text(
                    '按开课时间（学年）排序',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text('已默认开启：以更大学年为顶，从上往下排序。关闭则按抓取到的原始顺序展示。'),
                  secondary: Icon(Icons.sort, color: colorScheme.primary),
                  value: s.gradeSortByYear,
                  onChanged: _settings == null
                      ? null
                      : (v) {
                          setState(() => _settings!.gradeSortByYear = v);
                          _persist(notify: true);
                        },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text(
                    '按学期筛选成绩',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text('已默认开启：在成绩页选择“全部学期”或指定学期，只展示对应学期的成绩。'),
                  secondary: Icon(
                    Icons.filter_list,
                    color: colorScheme.primary,
                  ),
                  value: s.gradeTermFilterEnabled,
                  onChanged: _settings == null
                      ? null
                      : (v) {
                          setState(() => _settings!.gradeTermFilterEnabled = v);
                          _persist(notify: true);
                        },
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          // ==================== 教务登录设置 ====================
          _buildSectionHeader(Icons.verified_user, '教务登录'),
          Card(
            child: SwitchListTile(
              title: const Text(
                '自动识别验证码',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: const Text(
                '默认开启：Android / Windows 会在本机识别验证码并自动填入。识别失败时可直接手动修改。',
              ),
              secondary: Icon(
                Icons.document_scanner,
                color: colorScheme.primary,
              ),
              value: s.captchaOcrEnabled,
              onChanged: _settings == null
                  ? null
                  : (v) {
                      setState(() => _settings!.captchaOcrEnabled = v);
                      _persist(notify: true);
                    },
            ),
          ),
          const SizedBox(height: 18),

          // ==================== 账号操作 ====================
          _buildSectionHeader(Icons.account_circle, '账号'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(
                    Icons.switch_account,
                    color: colorScheme.primary,
                  ),
                  title: const Text('切换用户'),
                  subtitle: const Text('保持校园加速器，只切换本地保存的教务账号'),
                  onTap: _accountActionLoading ? null : _switchUser,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(Icons.logout, color: colorScheme.error),
                  title: const Text('退出登录'),
                  subtitle: const Text('断开校园加速器，返回应用主页面'),
                  onTap: _accountActionLoading ? null : _logout,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(Icons.delete_forever, color: colorScheme.error),
                  title: const Text('删除本地账号信息'),
                  subtitle: const Text('清除加密账号、静态课表与成绩，删除后无法恢复'),
                  onTap: _accountActionLoading ? null : _deleteLocalAccountInfo,
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          // ==================== 反馈 ====================
          _buildSectionHeader(Icons.feedback, '反馈'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(Icons.email, color: colorScheme.primary),
                  title: const Text('邮件反馈'),
                  subtitle: const Text('1410983@qq.com'),
                  onTap: () => launchUrl(
                    Uri.parse('mailto:1410983@qq.com'),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(Icons.code, color: colorScheme.primary),
                  title: const Text('GitHub'),
                  subtitle: const Text('github.com/One-HuaJi/jizhicha'),
                  onTap: () => launchUrl(
                    Uri.parse('https://github.com/One-HuaJi/jizhicha'),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _buildSectionHeader(Icons.info_outline, '关于'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(
                    Icons.system_update_alt,
                    color: colorScheme.primary,
                  ),
                  title: const Text('版本检测'),
                  subtitle: Text(
                    _versionChecking
                        ? '检测中…'
                        : (_versionStatus.isEmpty
                            ? '当前版本 $currentAppVersion，点击检测更新'
                            : _versionStatus),
                  ),
                  trailing: _versionChecking
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          _versionStatus.startsWith('有新版本')
                              ? Icons.arrow_circle_up
                              : Icons.check_circle_outline,
                          color: _versionStatus.startsWith('有新版本')
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                        ),
                  onTap: _checkVersion,
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '该项目处于测试阶段，发现bug属于特性，请多多反馈或提出issue',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  ButtonStyle _scheduleSegmentedStyle(ColorScheme colorScheme) {
    return ButtonStyle(
      visualDensity: VisualDensity.compact,
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        return states.contains(WidgetState.selected)
            ? colorScheme.primary
            : colorScheme.surfaceContainerHighest;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        return states.contains(WidgetState.selected)
            ? colorScheme.onPrimary
            : colorScheme.onSurfaceVariant;
      }),
    );
  }

  /// 三框独立输入年月日，避免系统日历卡顿与单框格式错误。
  Future<DateTime?> _pickSemesterStartDate(DateTime current) {
    final yearCtrl = TextEditingController(text: current.year.toString());
    final monthCtrl = TextEditingController(text: current.month.toString());
    final dayCtrl = TextEditingController(text: current.day.toString());
    return showDialog<DateTime>(
      context: context,
      builder: (ctx) {
        String? error;
        return StatefulBuilder(
          builder: (ctx, setInner) {
            return AlertDialog(
              title: const Text('设置开学日期'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('第一周的周一', style: TextStyle(fontSize: 13)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: TextField(controller: yearCtrl, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: const InputDecoration(labelText: '年', isDense: true, border: OutlineInputBorder()))),
                      const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Text('年')),
                      Expanded(child: TextField(controller: monthCtrl, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: const InputDecoration(labelText: '月', isDense: true, border: OutlineInputBorder()))),
                      const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Text('月')),
                      Expanded(child: TextField(controller: dayCtrl, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: const InputDecoration(labelText: '日', isDense: true, border: OutlineInputBorder()))),
                      const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Text('日')),
                    ],
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(error!, style: TextStyle(color: Theme.of(ctx).colorScheme.error, fontSize: 12)),
                  ],
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
                FilledButton(
                  onPressed: () {
                    final y = int.tryParse(yearCtrl.text);
                    final m = int.tryParse(monthCtrl.text);
                    final d = int.tryParse(dayCtrl.text);
                    if (y == null || m == null || d == null) {
                      setInner(() => error = '请输入年、月、日数字');
                      return;
                    }
                    if (y < 2000 || y > 2100) {
                      setInner(() => error = '年份需在 2000–2100 之间');
                      return;
                    }
                    final date = DateTime(y, m, d);
                    if (date.year != y || date.month != m || date.day != d) {
                      setInner(() => error = '日期不合法，请检查月和日');
                      return;
                    }
                    Navigator.pop(ctx, date);
                  },
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildSectionHeader(IconData icon, String title) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}

