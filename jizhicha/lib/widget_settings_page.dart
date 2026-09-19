import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel, PlatformException;

import 'widget_settings.dart';

/// 桌面小组件设置页：可调提醒/显示项 + 一键优化（小米后台权限）。
class WidgetSettingsPage extends StatefulWidget {
  const WidgetSettingsPage({super.key});

  @override
  State<WidgetSettingsPage> createState() => _WidgetSettingsPageState();
}

class _WidgetSettingsPageState extends State<WidgetSettingsPage>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('com.one.huaji/widget_settings');

  WidgetSettings _settings = WidgetSettings();
  bool _loaded = false;

  /// 原生权限状态。默认按「已授权」显示，避免非 Android 平台或旧原生包
  /// 在读取失败时弹出无意义的警告行。
  bool _notificationsEnabled = true;
  bool _canExactAlarm = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _refreshPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从系统设置页授权返回后重新读取状态，否则界面仍显示「未授权」。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshPermissions();
  }

  Future<void> _refreshPermissions() async {
    if (!Platform.isAndroid) return;
    bool notifications = true;
    bool exactAlarm = true;
    try {
      notifications =
          await _channel.invokeMethod<bool>('notificationsEnabled') ?? true;
    } catch (_) {}
    try {
      exactAlarm =
          await _channel.invokeMethod<bool>('canScheduleExactAlarm') ?? true;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _notificationsEnabled = notifications;
      _canExactAlarm = exactAlarm;
    });
  }

  Future<void> _load() async {
    final s = await WidgetSettings.load();
    if (!mounted) return;
    setState(() {
      _settings = s;
      _loaded = true;
    });
  }

  Future<void> _save() async {
    await _settings.save();
    await _refreshWidget();
  }

  Future<void> _refreshWidget() async {
    try {
      await _channel.invokeMethod('refreshWidget');
    } catch (_) {}
  }

  Future<void> _openBatteryOptimization() async {
    try {
      await _channel.invokeMethod('openBatteryOptimization');
    } catch (_) {}
  }

  Future<void> _openAutostart() async {
    try {
      await _channel.invokeMethod('openAutostart');
    } catch (_) {}
  }

  Future<void> _openExactAlarmSettings() async {
    try {
      await _channel.invokeMethod('openExactAlarmSettings');
    } catch (_) {}
  }

  Future<void> _openNotificationSettings() async {
    try {
      await _channel.invokeMethod('openNotificationSettings');
    } catch (_) {}
  }

  /// 开启「上课提醒」时先申请通知权限。
  ///
  /// Android 13+ 上 POST_NOTIFICATIONS 只在清单声明是无效的：不做运行时申请，
  /// 闹钟照样触发但通知被系统静默丢弃，用户完全看不到提醒。
  Future<bool> _requestNotificationPermission() async {
    try {
      final granted =
          await _channel.invokeMethod<bool>('requestNotificationPermission');
      return granted ?? false;
    } catch (_) {
      // 原生通道不可用（非 Android 或未更新的原生包）：不阻断用户开启开关。
      return true;
    }
  }

  Future<void> _onReminderChanged(bool enabled) async {
    // 提前捕获 messenger：后面有两次 await，跨 async gap 再用 context 既会踩
    // use_build_context_synchronously，也可能在页面已销毁后访问失效的 context。
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _settings.reminderEnabled = enabled);
    if (enabled && Platform.isAndroid) {
      final granted = await _requestNotificationPermission();
      await _refreshPermissions();
      if (!mounted) return;
      if (!granted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('未获得通知权限，上课提醒弹不出来。已先关闭开关，授权后再打开'),
          ),
        );
        setState(() => _settings.reminderEnabled = false);
        await _save();
        return;
      }
    }
    await _save();
  }

  Future<void> _requestPinWidget() async {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _channel.invokeMethod('requestPinWidget');
      messenger.showSnackBar(
        const SnackBar(content: Text('已请求添加，请在系统弹窗中点「添加」')),
      );
    } on PlatformException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.message ?? '添加失败，请长按桌面空白处手动添加小组件')),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('添加失败，请长按桌面空白处手动添加小组件')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('小组件设置')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                FilledButton.icon(
                  onPressed: _requestPinWidget,
                  icon: const Icon(Icons.add_to_home_screen),
                  label: const Text('一键添加到桌面'),
                ),
                const SizedBox(height: 6),
                Text(
                  '点上面按钮，系统会弹出确认框，选「添加」即可把小组件放到桌面，'
                  '不用再长按桌面慢慢找。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  title: const Text('上课提醒'),
                  subtitle: const Text('在上课前通过系统通知提醒'),
                  value: _settings.reminderEnabled,
                  onChanged: _onReminderChanged,
                ),
                // 通知被关时闹钟照样触发，但通知被系统静默丢弃，提醒等于失效。
                if (Platform.isAndroid && !_notificationsEnabled)
                  Card(
                    color: colorScheme.errorContainer,
                    child: ListTile(
                      leading: Icon(
                        Icons.notifications_off,
                        color: colorScheme.onErrorContainer,
                      ),
                      title: Text(
                        '通知权限已关闭',
                        style: TextStyle(color: colorScheme.onErrorContainer),
                      ),
                      subtitle: Text(
                        '上课提醒弹不出来，点此去系统设置打开',
                        style: TextStyle(color: colorScheme.onErrorContainer),
                      ),
                      onTap: _openNotificationSettings,
                    ),
                  ),
                // 精确闹钟未授权时原生已降级为窗口闹钟，提醒会晚最多 2 分钟。
                if (Platform.isAndroid &&
                    _settings.reminderEnabled &&
                    !_canExactAlarm)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.alarm_off),
                      title: const Text('精确闹钟未授权'),
                      subtitle: const Text('提醒会延后最多 2 分钟，点此授权可准点提醒'),
                      onTap: _openExactAlarmSettings,
                    ),
                  ),
                if (_settings.reminderEnabled)
                  ListTile(
                    title: const Text('提醒提前时间'),
                    subtitle: Text('课前 ${_settings.reminderMinutes} 分钟提醒'),
                    trailing: DropdownButton<int>(
                      value: _settings.reminderMinutes,
                      isDense: true,
                      items: const [5, 10, 15, 30]
                          .map(
                            (m) => DropdownMenuItem<int>(
                              value: m,
                              child: Text('$m 分钟'),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() => _settings.reminderMinutes = v);
                        _save();
                      },
                    ),
                  ),
                SwitchListTile(
                  title: const Text('显示老师 / 地点'),
                  subtitle: const Text('在小组件上显示老师和教室'),
                  value: _settings.showTeacherRoom,
                  onChanged: (v) {
                    setState(() => _settings.showTeacherRoom = v);
                    _save();
                  },
                ),
                const Divider(),
                const SizedBox(height: 8),
                Text(
                  '一键优化',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _openBatteryOptimization,
                  icon: const Icon(Icons.battery_saver),
                  label: const Text('① 电池优化 → 设为「无限制」'),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _openAutostart,
                  icon: const Icon(Icons.play_circle_outline),
                  label: const Text('② 自启动 → 打开「稽之查」'),
                ),
              ],
            ),
    );
  }
}
