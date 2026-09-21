import 'dart:async' show unawaited;
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'app_mode.dart';
import 'app_settings.dart';
import 'campus_environment.dart';
import 'campus_navigator_page.dart';
import 'campus_vpn.dart';
import 'captcha_ocr.dart';
import 'common.dart';
import 'home_page.dart';
import 'credential_store.dart';
import 'jwxt_client.dart';
import 'offline_sync.dart';
import 'sync_cooldown.dart';
import 'vpn_session.dart';

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
                  title: '仅启动加速器',
                  description: '连接校园内网后访问校园导航、教务网址、图书馆等服务',
                  color: colorScheme.primary,
                  onTap: () => _openMode(context, AppMode.vpnOnly),
                ),
                const SizedBox(height: 18),
                _ModeCard(
                  icon: Icons.auto_graph,
                  title: '启动加速器并进入教务',
                  description: '先建立校园加速器，再使用独立的教务系统密码登录查询',
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


class VpnSetupPage extends StatefulWidget {
  final AppMode mode;
  final String? initialNotice;
  final GradeSyncScope gradeSyncScope;
  final bool syncSchedules;
  final bool forceScheduleSync;
  final bool fetchAllSchedules;
  final String? scheduleTerm;
  final String? gradeTerm;
  final bool syncGrades;

  const VpnSetupPage({
    required this.mode,
    this.initialNotice,
    this.gradeSyncScope = GradeSyncScope.latest,
    this.syncSchedules = true,
    this.forceScheduleSync = false,
    this.fetchAllSchedules = false,
    this.scheduleTerm,
    this.gradeTerm,
    this.syncGrades = true,
    super.key,
  });

  @override
  State<VpnSetupPage> createState() => _VpnSetupPageState();
}

class _VpnSetupPageState extends State<VpnSetupPage> {
  final _idCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  List<StoredAccount> _savedAccounts = const [];
  bool _submitting = false;
  bool _showPassword = false;
  String? _error;
  String? _progress;
  bool _initialNoticeShown = false;

  @override
  void initState() {
    super.initState();
    _loadSavedAccounts();
    if (widget.initialNotice != null && widget.initialNotice!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _initialNoticeShown) return;
        _initialNoticeShown = true;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(widget.initialNotice!)));
      });
    }
  }

  @override
  void dispose() {
    // 密码不允许在控制器销毁后仍以明文留在内存里等 GC（§4 红线）。
    _passwordCtrl.clear();
    _idCtrl.clear();
    _idCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSavedAccounts() async {
    final accounts = await CredentialStore.load(StoredAccountKind.vpn);
    if (!mounted) return;
    setState(() {
      _savedAccounts = accounts;
      // 默认填写最近一次认证的凭据，用户仍可直接编辑或用右侧箭头改选。
      if (_idCtrl.text.trim().isEmpty && accounts.isNotEmpty) {
        _idCtrl.text = accounts.first.username;
        _passwordCtrl.text = accounts.first.password;
      }
    });
  }

  void _selectSavedAccount(StoredAccount account) {
    setState(() {
      _idCtrl.text = account.username;
      _passwordCtrl.text = account.password;
      _error = null;
    });
  }

  /// 隧道已就绪后进入目标页。
  ///
  /// **这里是"能不能用教务"的判定点。** 状态机里的探测只看 `ns.huse.cn`，
  /// 而实测该域名在部分校园网段**完全不可达**（curl 返回 000），因此它只用于
  /// 显示在线与否，**不能**用来否决连接。真正决定放不放行的是对**目标端点**
  /// 的轮询（`waitForIntranet` → 172.20.63.226/jsxsd/）。
  ///
  /// 若轮询失败但**隧道仍在**，不再判定为失败 —— 因为：
  ///   1. 教务端点本身偶发慢/被 QoS，多等一次往往就通了；
  ///   2. 用户已经完成认证，此时把隧道拆掉重来体验极差；
  ///   3. 真正不可用时，下一个页面自己的请求会给出更准确的错误。
  /// 所以这里只在"隧道确实没了"时报错，否则带提示放行。
  Future<void> _openTarget({
    required String studentId,
    required AppMode targetMode,
    void Function(String message)? onProgress,
  }) async {
    // 网关需要 6-9 秒（偶尔更久）为新会话准备后端转发链路。把等待过程
    // 显示出来，用户就知道是在"等学校网关"，而不是以为卡死了。
    onProgress?.call('正在等待学校网关准备校内服务…');
    final campusReady = await JwxtClient().waitForIntranet(
      onTick: (attempt, _) {
        onProgress?.call(
          attempt <= 1
              ? '正在等待学校网关准备校内服务…'
              : '学校网关正在准备中…（第 $attempt 次尝试）',
        );
      },
    );

    // 探测失败时要区分"隧道没了"和"隧道在但教务暂时不通"。
    final status = await CampusVpnLauncher().currentStatus();
    final connected = status?['connected'] == true;
    if (!connected) {
      throw const _VpnConnectException(VpnFailure.tunnelStopped);
    }
    if (!campusReady) {
      throw const _VpnConnectException(
        VpnFailure.gatewayUnreachable,
        // 已经等了 45 秒还没通，说明这次确实没能就绪。文案要给出**下一步**
        // 而不是制造焦虑：隧道是好的，再点一次通常就好（网关那边可能刚
        // 完成准备）。
        customMessage: '校方握手失败，请再试一次',
      );
    }
    if (!mounted) return;
    final next = targetMode == AppMode.education
        ? EducationLoginPage(
            studentId: studentId,
            gradeSyncScope: widget.gradeSyncScope,
            syncSchedules: widget.syncSchedules,
            forceScheduleSync: widget.forceScheduleSync,
            fetchAllSchedules: widget.fetchAllSchedules,
            scheduleTerm: widget.scheduleTerm,
            gradeTerm: widget.gradeTerm,
            syncGrades: widget.syncGrades,
          )
        : CampusNavigatorPage(studentId: studentId);
    // ⚠️ 必须清栈（pushAndRemoveUntil），不能用 pushReplacement。
    //
    // 认证页常常是从课表页/成绩页 `push` 进来的（见 schedule_page.dart:111、
    // grades_page.dart:75 等）。用 pushReplacement 只替换**栈顶**这一个路由，
    // 底下的课表页/成绩页仍在栈里 —— 于是用户在导航页或教务页按**系统返回键**
    // 时，会直接落回"登录之前的界面"，看起来像是登录没生效/被退回了。
    //
    // 认证是一次性的入口动作：连上之后，旧页面不该再留在背后。
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => next),
      (_) => false,
    );
  }

  /// 页面主按钮。调用方若不指定 [targetMode]，则用页面自身的 [widget.mode]。
  /// 两个按钮始终显式传入自己的模式，因此这里实际只服务"程序化触发"的场景。
  Future<void> _connect({AppMode? targetMode}) async {
    final studentId = _idCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (studentId.isEmpty || password.isEmpty) {
      setState(() => _error = '请输入学号和加速器密码（默认为身份证后六位）');
      return;
    }
    final selectedMode = targetMode ?? widget.mode;
    FocusScope.of(context).unfocus();
    setState(() {
      _submitting = true;
      _error = null;
      _progress = '正在启动校园加速器…';
    });

    // 进度文案订阅状态机，不再由各处 onProgress 回调层层转发。
    void followProgress() {
      if (!mounted) return;
      final text = campusEnvironment.session.progress;
      if (text != null && text != _progress) setState(() => _progress = text);
    }

    campusEnvironment.session.addListener(followProgress);
    try {
      final session = campusEnvironment.session;
      final status = await CampusVpnLauncher().currentStatus();
      if (status?['connected'] == true) {
        final connectedStudentId =
            status?['username']?.toString().trim() ?? '';
        if (connectedStudentId.isNotEmpty && connectedStudentId != studentId) {
          throw const _VpnConnectException(VpnFailure.unknown,
              customMessage: '当前校园加速器已使用其他账号连接，请先退出登录后再切换加速器账号');
        }
        JwxtClient().setVpnSourceAddress(status?['virtual_ip']?.toString());
      } else {
        // 状态机负责：认证 → 建隧道 → 等虚拟 IP → 尝试确认网关。
        final ok = await session.connect(
          username: studentId,
          password: password,
        );
        if (!ok) {
          throw _VpnConnectException(session.failure ?? VpnFailure.unknown);
        }
        // ⚠️ 必须显式再同步一次源地址：`connect()` 内部已回调，但
        // auth 页这条路径历史上就是这样兜底的，去掉会导致部分机型
        // （虚拟 IP 下发晚于 connected）绑定到错误的源地址。
        JwxtClient().setVpnSourceAddress(session.virtualIp);
        await CredentialStore.save(
          StoredAccountKind.vpn,
          username: studentId,
          password: password,
        );
        await _loadSavedAccounts();
      }
      await _openTarget(
        studentId: studentId,
        targetMode: selectedMode,
        onProgress: (message) {
          if (mounted) setState(() => _progress = message);
        },
      );
    } on _VpnConnectException catch (e) {
      // ⚠️ 只有**隧道确实没了**才断开。绝不能因为"教务端点暂时不通"
      // 就拆掉一条健康的隧道 —— 真机实测过：ns.huse.cn 在这张网里
      // 完全不可达（curl 返回 000），但 172.20.63.226/jsxsd/ 是 200。
      // 旧写法在此处无条件 disconnect，导致用户重试时隧道刚建好又被拆，
      // 表现成"永远连不上、一直报教务服务器无响应"。
      if (e.kind == VpnFailure.tunnelStopped) {
        try {
          await campusEnvironment.session.disconnect();
        } catch (_) {}
      }
      if (mounted) setState(() => _error = e.display);
    } catch (error) {
      final kind = classifyVpnError(error);
      if (kind == VpnFailure.tunnelStopped) {
        try {
          await campusEnvironment.session.disconnect();
        } catch (_) {}
      }
      if (mounted) setState(() => _error = kind.message);
    } finally {
      campusEnvironment.session.removeListener(followProgress);
      if (mounted) {
        setState(() {
          _submitting = false;
          _progress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const title = '连接校园加速器';
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            tooltip: '账号填写说明',
            icon: const Icon(Icons.help_outline),
            onPressed: _submitting ? null : () => showStudentIdHelp(context),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
              children: [
                Icon(Icons.vpn_lock, color: colorScheme.primary, size: 52),
                const SizedBox(height: 14),
                // 说明文案只讲"连接之后能干什么"，不再承诺"直接进教务" ——
                // 主按钮现在落到校园导航页（那里有教务入口），用户点进去即可；
                // 文案与按钮目的地必须一致，否则又是一次误导。
                Text(
                  '连接校园内网后，可使用学校教务系统、图书馆、知网等服务',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 30),
                if (!Platform.isWindows && !Platform.isAndroid) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: colorScheme.outlineVariant),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.phone_android, color: colorScheme.primary),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            // 这个分支只在非 Windows、非 Android（实际是 Linux）
                            // 出现。VPN 核心只为 Windows / Android 编译，所以
                            // 这里说"不支持"是准确的；原文案"Android 隧道引擎
                            // 正在接入"是 Android 尚未完成时的残留，已过时。
                            '当前平台暂不支持校园加速器功能。如需在校园外访问教务、图书馆等服务，请在 Windows 或 Android 上使用。',
                            style: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                              height: 1.45,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
                _styledField(
                  controller: _idCtrl,
                  label: '学校加速器学号',
                  icon: Icons.badge_outlined,
                  keyboardType: TextInputType.number,
                  suffixIcon: _accountPicker(),
                ),
                const SizedBox(height: 16),
                _styledField(
                  controller: _passwordCtrl,
                  label: '学校加速器密码',
                  icon: Icons.lock_outline,
                  obscureText: !_showPassword,
                  suffixIcon: _PasswordVisibilityButton(
                    visible: _showPassword,
                    onPressed: () =>
                        setState(() => _showPassword = !_showPassword),
                  ),
                ),
                const SizedBox(height: 24),
                if (_error != null) ErrorBox(message: _error!),
                if (_error != null) const SizedBox(height: 16),
                if (_submitting && _progress != null) ...[
                  Text(
                    acceleratorText(_progress!),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                ],
                _connectButtons(colorScheme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 连接按钮。
  ///
  /// ## 为什么从两个按钮改成"一个主按钮 + 一个次级入口"
  ///
  /// 旧版有两个等权重按钮：「仅启动加速器」与「启动加速器并查询教务」。
  /// 它们的**连接过程完全相同**（都走 `_connect()` → 建隧道 → 等内网），
  /// 唯一差别只是最后跳到哪个页面。这带来三个问题：
  ///
  /// 1. **用户无法做出有意义的判断**："我要查教务，但我也想用加速器" ——
  ///    两个按钮看起来是互斥的两件事，实际是同一件事的两个出口。
  /// 2. **选错的代价不对称**：点了「仅启动」的用户到了导航页才发现要查教务，
  ///    得退回来重连一次（多花十几秒）。
  /// 3. **文字长、并排挤**：两个 7 字按钮在窄屏必须竖排，占据大量纵向空间。
  ///
  /// 现在改为：**主按钮只做一件事 —— "连接校园网"**。连接成功后进入导航页，
  /// 那里**本来就有**「学校教务系统」入口（`CampusNavigatorPage` 的服务列表），
  /// 用户点它即可查教务，且不需要重新连接。
  ///
  /// 也就是说：把"选出口"从连接**之前**移到连接**之后**。用户不必预测自己
  /// 要干什么，先连上（反正都要连），再决定去哪。
  ///
  /// 只有一种情况需要保留直达教务：调用方带着明确的同步参数进来
  /// （`syncSchedules` / `syncGrades` / 指定学期等，见 `widget.*`），
  /// 那是从课表页/成绩页的"更新"按钮发起的，此时用户意图已经明确，
  /// 就跳过导航页直达教务。
  Widget _connectButtons(ColorScheme colorScheme) {
    final supported = Platform.isWindows || Platform.isAndroid;
    // 调用方是否带了明确的同步意图（来自课表/成绩页的更新入口）。
    final intentIsEducation = widget.mode == AppMode.education &&
        (widget.forceScheduleSync ||
            widget.fetchAllSchedules ||
            widget.scheduleTerm != null ||
            widget.gradeTerm != null ||
            !widget.syncSchedules ||
            !widget.syncGrades);

    final primary = _oneConnectButton(
      colorScheme: colorScheme,
      mode: intentIsEducation ? AppMode.education : AppMode.vpnOnly,
      active: _submitting,
      idleIcon: Icons.vpn_lock,
      idleLabel: '连接校园网',
      enabled: supported,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        primary,
        const SizedBox(height: 12),
        // 次级入口：连接后直接进教务（老用户的习惯路径，避免"以前能直达、
        // 现在要多点一下"的倒退感）。不是等权按钮，视觉上明显更轻。
        TextButton(
          onPressed:
              (_submitting || !supported) ? null : () => _connect(targetMode: AppMode.education),
          child: const Text('连接后直接进入教务系统'),
        ),
      ],
    );
  }

  Widget _oneConnectButton({
    required ColorScheme colorScheme,
    required AppMode mode,
    required bool active,
    required IconData idleIcon,
    required String idleLabel,
    required bool enabled,
  }) {
    // 连接中的那个按钮保持高亮（用 primary 作禁用态底色），
    // 让用户一眼看出"是哪一个在连"，而不是两个都灰掉。
    final button = FilledButton.icon(
      onPressed: (_submitting || !enabled)
          ? null
          : () => _connect(targetMode: mode),
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(54),
        disabledBackgroundColor: _submitting
            ? (active ? colorScheme.primary : colorScheme.surfaceContainerHighest)
            : null,
        disabledForegroundColor: _submitting
            ? (active ? colorScheme.onPrimary : colorScheme.onSurfaceVariant)
            : null,
      ),
      icon: active
          ? _ButtonSpinner(color: colorScheme.onPrimary)
          : Icon(idleIcon),
      label: Text(active ? '正在连接…' : idleLabel),
    );
    // Windows 下由外层 Expanded 控制宽度；移动端铺满。
    return Platform.isWindows
        ? button
        : SizedBox(width: double.infinity, child: button);
  }

  Widget _styledField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool obscureText = false,
    TextInputType? keyboardType,
    Widget? suffixIcon,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        suffixIcon: suffixIcon,
      ),
    );
  }

  Widget _accountPicker() {
    return PopupMenuButton<StoredAccount>(
      tooltip: '选择已保存账号',
      icon: const Icon(Icons.keyboard_arrow_down),
      onSelected: _selectSavedAccount,
      itemBuilder: (context) {
        if (_savedAccounts.isEmpty) {
          return const [
            PopupMenuItem<StoredAccount>(
              enabled: false,
              child: Text('暂无已保存账号'),
            ),
          ];
        }
        return _savedAccounts
            .map(
              (account) => PopupMenuItem<StoredAccount>(
                value: account,
                child: Text(account.username),
              ),
            )
            .toList();
      },
    );
  }
}

class _PasswordVisibilityButton extends StatelessWidget {
  final bool visible;
  final VoidCallback onPressed;

  const _PasswordVisibilityButton({
    required this.visible,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: visible ? '隐藏密码' : '显示密码',
      onPressed: onPressed,
      icon: Icon(
        visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        size: 18,
      ),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _ButtonSpinner extends StatelessWidget {
  final Color color;
  const _ButtonSpinner({required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2, color: color),
    );
  }
}

enum _PasswordRecoveryStep { account, identity, success }

class PasswordRecoveryOutcome {
  final String studentId;
  final bool localCredentialsInvalidated;

  const PasswordRecoveryOutcome({
    required this.studentId,
    required this.localCredentialsInvalidated,
  });
}

class EducationPasswordChangedOutcome {
  final String studentId;
  final String newPassword;

  const EducationPasswordChangedOutcome({
    required this.studentId,
    required this.newPassword,
  });
}

class EducationPasswordRecoveryPage extends StatefulWidget {
  final String initialStudentId;

  const EducationPasswordRecoveryPage({
    required this.initialStudentId,
    super.key,
  });

  @override
  State<EducationPasswordRecoveryPage> createState() =>
      _EducationPasswordRecoveryPageState();
}

class _EducationPasswordRecoveryPageState
    extends State<EducationPasswordRecoveryPage> {
  late final TextEditingController _studentIdCtrl;
  final _captchaCtrl = TextEditingController();
  final _identityCtrl = TextEditingController();
  _PasswordRecoveryStep _step = _PasswordRecoveryStep.account;
  PasswordRecoveryAccountResult? _verifiedAccount;
  Uint8List? _captchaBytes;
  bool _loadingCaptcha = false;
  bool _submitting = false;
  bool _showIdentity = false;
  bool _localCredentialsInvalidated = false;
  bool _captchaOcrEnabled = true;
  bool _captchaOcrBusy = false;
  String? _captchaOcrHint;
  String _lastOcrCaptcha = '';
  int _captchaGeneration = 0;
  Future<void> _captchaOcrTail = Future<void>.value();
  String? _error;
  String? _successMessage;

  @override
  void initState() {
    super.initState();
    _studentIdCtrl = TextEditingController(text: widget.initialStudentId);
    unawaited(_initializeRecoveryCaptcha());
  }

  @override
  void dispose() {
    // §4 红线：身份证件号只允许存在于内存中的输入控制器，用完即清空。
    // 直接 dispose 会让明文残留在已销毁的控制器里等 GC —— 用户填完身份证号
    // 直接 pop 页面就会走到这条路径。同文件的教务改密页（1342 附近）已有 clear。
    _identityCtrl.clear();
    _studentIdCtrl.clear();
    _captchaCtrl.clear();
    _studentIdCtrl.dispose();
    _captchaCtrl.dispose();
    _identityCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadRecoveryCaptcha({bool clearError = true}) async {
    if (_loadingCaptcha || _submitting) return;
    final generation = ++_captchaGeneration;
    setState(() {
      _loadingCaptcha = true;
      _captchaBytes = null;
      _captchaCtrl.clear();
      _captchaOcrBusy = false;
      _captchaOcrHint = null;
      _lastOcrCaptcha = '';
      if (clearError) _error = null;
    });
    try {
      final bytes = await JwxtClient().beginPasswordRecovery().timeout(
        const Duration(seconds: 15),
      );
      if (mounted) {
        setState(() => _captchaBytes = bytes);
        if (_captchaOcrEnabled) {
          unawaited(_recognizeRecoveryCaptcha(bytes, generation: generation));
        }
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loadingCaptcha = false);
    }
  }

  Future<void> _initializeRecoveryCaptcha() async {
    try {
      final settings = await AppSettings.load();
      if (mounted) {
        setState(() => _captchaOcrEnabled = settings.captchaOcrEnabled);
      }
    } catch (_) {
      // 损坏的设置不能阻止官方找回密码页面显示，默认继续开启 OCR。
    }
    if (mounted) await _loadRecoveryCaptcha();
  }

  Future<void> _recognizeRecoveryCaptcha(
    Uint8List bytes, {
    required int generation,
  }) async {
    final task = _captchaOcrTail.catchError((_) {}).then<void>((_) async {
      if (!mounted || generation != _captchaGeneration || !_captchaOcrEnabled) {
        return;
      }
      await _recognizeRecoveryCaptchaNow(bytes, generation: generation);
    });
    _captchaOcrTail = task.catchError((_) {});
    await task;
  }

  Future<void> _recognizeRecoveryCaptchaNow(
    Uint8List bytes, {
    required int generation,
  }) async {
    if (!_captchaOcrEnabled || bytes.isEmpty) return;
    if (mounted) {
      setState(() {
        _captchaOcrBusy = true;
        _captchaOcrHint = null;
      });
    }
    String? recognized;
    try {
      recognized = await CaptchaOcr.recognize(bytes);
    } catch (_) {
      recognized = null;
    }
    if (!mounted || generation != _captchaGeneration || !_captchaOcrEnabled) {
      return;
    }
    final current = _captchaCtrl.text.trim();
    if (recognized != null && (current.isEmpty || current == _lastOcrCaptcha)) {
      _captchaCtrl.value = TextEditingValue(
        text: recognized,
        selection: TextSelection.collapsed(offset: recognized.length),
      );
      _lastOcrCaptcha = recognized;
      setState(() {
        _captchaOcrBusy = false;
        _captchaOcrHint = '已自动识别，可按需修改';
      });
    } else {
      setState(() {
        _captchaOcrBusy = false;
        _captchaOcrHint = recognized == null ? '未识别成功，请手动输入' : '验证码已手动修改';
      });
    }
  }

  Future<void> _verifyAccount() async {
    if (_submitting || _loadingCaptcha) return;
    final studentId = _studentIdCtrl.text.trim();
    final captcha = _captchaCtrl.text.trim();
    if (studentId.isEmpty || captcha.isEmpty) {
      setState(() => _error = '请输入学生学号和验证码');
      return;
    }
    if (!RegExp(r'^\d+$').hasMatch(studentId)) {
      setState(() => _error = passwordRecoveryStudentIdError);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final result = await JwxtClient().verifyPasswordRecoveryAccount(
        studentId: studentId,
        captcha: captcha,
      );
      if (!mounted) return;
      setState(() {
        _verifiedAccount = result;
        _studentIdCtrl.text = result.studentId;
        _step = _PasswordRecoveryStep.identity;
        ++_captchaGeneration;
        _captchaCtrl.clear();
        _captchaBytes = null;
        _captchaOcrBusy = false;
        _captchaOcrHint = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _submitting = false;
      });
      await _loadRecoveryCaptcha(clearError: false);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _resetWithIdentity() async {
    if (_submitting) return;
    final account = _verifiedAccount;
    final identity = _identityCtrl.text.trim();
    if (account == null) {
      setState(() => _error = '验证已超时，请返回上一步重新验证');
      return;
    }
    if (identity.length < 4) {
      setState(() => _error = '请输入正确的身份证件号');
      return;
    }
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) {
            final colorScheme = Theme.of(context).colorScheme;
            return AlertDialog(
              title: Text(
                '确认重置教务密码？',
                style: TextStyle(
                  color: colorScheme.onSurface,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              content: Text(
                '确认后，学校会把教务密码重置为身份证件号后六位。旧教务密码会立即从本机删除，临时密码不会保存。',
                style: TextStyle(color: colorScheme.onSurface),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('确认重置'),
                ),
              ],
            );
          },
        ) ??
        false;
    if (!confirmed || !mounted) return;

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final result = await JwxtClient().resetPasswordWithIdentity(
        account: account,
        identityNumber: identity,
      );
      if (!result.success) throw result.message;

      // 服务器已经完成重置后，立刻擦除身份证输入和本地旧密码。即使后续
      // 页面关闭，也不会把旧密码或身份证件号留在控制器/安全存储中。
      _identityCtrl.clear();
      final invalidated = await CredentialStore.invalidateEducationPassword(
        account.studentId,
      );
      await JwxtClient().resetSession();
      if (!mounted) return;
      setState(() {
        _localCredentialsInvalidated = invalidated;
        _successMessage = result.message;
        _step = _PasswordRecoveryStep.success;
      });
    } catch (error) {
      _identityCtrl.clear();
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _backToAccountStep() {
    if (_submitting) return;
    setState(() {
      _step = _PasswordRecoveryStep.account;
      _verifiedAccount = null;
      _identityCtrl.clear();
      _error = null;
    });
    _loadRecoveryCaptcha();
  }

  Widget _stepHeader(ColorScheme colorScheme) {
    final current = switch (_step) {
      _PasswordRecoveryStep.account => 1,
      _PasswordRecoveryStep.identity => 2,
      _PasswordRecoveryStep.success => 3,
    };
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 1; i <= 3; i++) ...[
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i <= current
                  ? colorScheme.primary
                  : colorScheme.surfaceContainerHighest,
            ),
            child: Text(
              '$i',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: i <= current
                    ? colorScheme.onPrimary
                    : colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (i < 3)
            Container(
              width: 48,
              height: 2,
              color: i < current
                  ? colorScheme.primary
                  : colorScheme.outlineVariant,
            ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_submitting && _step != _PasswordRecoveryStep.success,
      child: Scaffold(
        appBar: AppBar(title: const Text('找回教务密码')),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
                children: [
                  _stepHeader(colorScheme),
                  const SizedBox(height: 24),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 240),
                    child: switch (_step) {
                      _PasswordRecoveryStep.account => _buildAccountStep(
                        colorScheme,
                      ),
                      _PasswordRecoveryStep.identity => _buildIdentityStep(
                        colorScheme,
                      ),
                      _PasswordRecoveryStep.success => _buildSuccessStep(
                        colorScheme,
                      ),
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAccountStep(ColorScheme colorScheme) {
    return Column(
      key: const ValueKey('password-recovery-account'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '第一步：验证学生账号',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _studentIdCtrl,
          keyboardType: TextInputType.number,
          enabled: !_submitting,
          decoration: const InputDecoration(
            labelText: '学生学号',
            prefixIcon: Icon(Icons.badge_outlined),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _captchaCtrl,
                enabled: !_submitting,
                keyboardType: TextInputType.visiblePassword,
                textCapitalization: TextCapitalization.none,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (value) {
                  final lower = value.toLowerCase();
                  if (lower == value) return;
                  _captchaCtrl.value = _captchaCtrl.value.copyWith(
                    text: lower,
                    selection: TextSelection.collapsed(offset: lower.length),
                    composing: TextRange.empty,
                  );
                },
                decoration: const InputDecoration(
                  labelText: '验证码',
                  prefixIcon: Icon(Icons.verified_outlined),
                ),
              ),
            ),
            const SizedBox(width: 12),
            InkWell(
              onTap: _loadingCaptcha || _submitting
                  ? null
                  : _loadRecoveryCaptcha,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: 128,
                height: 58,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: colorScheme.outlineVariant),
                ),
                alignment: Alignment.center,
                child: _loadingCaptcha
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : _captchaBytes == null
                    ? const Icon(Icons.refresh)
                    : Image.memory(_captchaBytes!, fit: BoxFit.contain),
              ),
            ),
          ],
        ),
        if (_captchaOcrEnabled) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(
                _captchaOcrBusy ? Icons.sync : Icons.document_scanner_outlined,
                size: 15,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  _captchaOcrBusy
                      ? '正在本机识别验证码…'
                      : (_captchaOcrHint ??
                            (Platform.isAndroid || Platform.isWindows
                                ? '验证码自动识别已开启'
                                : '当前平台不支持 OCR，请手动输入')),
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 16),
          ErrorBox(message: _error!),
        ],
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _submitting || _loadingCaptcha || _captchaBytes == null
              ? null
              : _verifyAccount,
          icon: _submitting
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.arrow_forward),
          label: Text(_submitting ? '正在验证…' : '下一步：身份验证'),
        ),
      ],
    );
  }

  Widget _buildIdentityStep(ColorScheme colorScheme) {
    return Column(
      key: const ValueKey('password-recovery-identity'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '第二步：核验身份证件号',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        Text(
          '登录账号：${_verifiedAccount?.studentId ?? '-'}',
          textAlign: TextAlign.center,
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _identityCtrl,
          enabled: !_submitting,
          obscureText: !_showIdentity,
          keyboardType: TextInputType.visiblePassword,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: '身份证件号',
            prefixIcon: const Icon(Icons.credit_card),
            suffixIcon: IconButton(
              tooltip: _showIdentity ? '隐藏' : '显示',
              onPressed: () => setState(() => _showIdentity = !_showIdentity),
              icon: Icon(
                _showIdentity ? Icons.visibility_off : Icons.visibility,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '身份证件号仅提交给学校教务系统，不会写入本机文件或安全存储。',
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          ErrorBox(message: _error!),
        ],
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _submitting ? null : _backToAccountStep,
                child: const Text('上一步'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: _submitting ? null : _resetWithIdentity,
                icon: _submitting
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.restart_alt),
                label: Text(_submitting ? '正在重置…' : '重置密码'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSuccessStep(ColorScheme colorScheme) {
    return Column(
      key: const ValueKey('password-recovery-success'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.check_circle, size: 64, color: colorScheme.primary),
        const SizedBox(height: 14),
        Text(
          '密码已由学校重置',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        Text(_successMessage ?? '密码已重置为身份证件号后六位', textAlign: TextAlign.center),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _localCredentialsInvalidated
                ? colorScheme.primaryContainer.withAlpha(110)
                : colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            _localCredentialsInvalidated
                ? '旧教务密码已从本机删除。请返回登录页手动输入身份证后六位临时密码（不会被保存），'
                    '登录后请设置至少 8 位、同时包含字母和数字的新密码。'
                : '学校已完成重置，但本机旧密码未能确认清除。请手动输入身份证后六位登录，'
                    '不要选用已保存的旧密码；登录后请尽快设置新密码。',
          ),
        ),
        const SizedBox(height: 22),
        FilledButton.icon(
          onPressed: () => Navigator.pop(
            context,
            PasswordRecoveryOutcome(
              studentId: _verifiedAccount!.studentId,
              localCredentialsInvalidated: _localCredentialsInvalidated,
            ),
          ),
          icon: const Icon(Icons.login),
          label: const Text('返回教务登录'),
        ),
      ],
    );
  }
}

class EducationRequiredPasswordChangePage extends StatefulWidget {
  final String studentId;
  final EducationPasswordChangeForm form;

  const EducationRequiredPasswordChangePage({
    required this.studentId,
    required this.form,
    super.key,
  });

  @override
  State<EducationRequiredPasswordChangePage> createState() =>
      _EducationRequiredPasswordChangePageState();
}

class _EducationRequiredPasswordChangePageState
    extends State<EducationRequiredPasswordChangePage> {
  final _oldPasswordCtrl = TextEditingController();
  final _newPasswordCtrl = TextEditingController();
  final _confirmPasswordCtrl = TextEditingController();
  final _hintCtrl = TextEditingController();
  bool _submitting = false;
  bool _showPasswords = false;
  String? _error;

  @override
  void dispose() {
    _oldPasswordCtrl.clear();
    _newPasswordCtrl.clear();
    _confirmPasswordCtrl.clear();
    _hintCtrl.clear();
    _oldPasswordCtrl.dispose();
    _newPasswordCtrl.dispose();
    _confirmPasswordCtrl.dispose();
    _hintCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final oldPassword = _oldPasswordCtrl.text;
    final newPassword = _newPasswordCtrl.text;
    final confirmPassword = _confirmPasswordCtrl.text;
    final hint = _hintCtrl.text.trim();
    final validation = educationPasswordValidationError(
      oldPassword: oldPassword,
      newPassword: newPassword,
      confirmPassword: confirmPassword,
      passwordHint: hint,
    );
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final result = await JwxtClient().submitRequiredPasswordChange(
        form: widget.form,
        oldPassword: oldPassword,
        newPassword: newPassword,
        confirmPassword: confirmPassword,
        passwordHint: hint,
      );
      if (!result.success) throw result.message;
      if (!mounted) return;
      final outcome = EducationPasswordChangedOutcome(
        studentId: widget.studentId,
        newPassword: newPassword,
      );
      _oldPasswordCtrl.clear();
      _newPasswordCtrl.clear();
      _confirmPasswordCtrl.clear();
      _hintCtrl.clear();
      Navigator.pop(context, outcome);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_submitting,
      child: Scaffold(
        appBar: AppBar(title: const Text('设置新的教务密码')),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
                children: [
                  Icon(Icons.password, size: 54, color: colorScheme.primary),
                  const SizedBox(height: 14),
                  Text(
                    '密码过于简单，请重新设置',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '登录账号：${widget.studentId}',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer.withAlpha(110),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Text(
                      '旧密码是刚才用于登录的临时密码；最终新密码至少 8 位，并且必须同时包含字母和数字。',
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: _oldPasswordCtrl,
                    enabled: !_submitting,
                    obscureText: !_showPasswords,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: '旧密码（临时密码）',
                      prefixIcon: Icon(Icons.lock_clock_outlined),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _newPasswordCtrl,
                    enabled: !_submitting,
                    obscureText: !_showPasswords,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: '新密码',
                      prefixIcon: Icon(Icons.lock_reset),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _confirmPasswordCtrl,
                    enabled: !_submitting,
                    obscureText: !_showPasswords,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: '确认新密码',
                      prefixIcon: Icon(Icons.verified_user_outlined),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _hintCtrl,
                    enabled: !_submitting,
                    decoration: const InputDecoration(
                      labelText: '新密码提示',
                      prefixIcon: Icon(Icons.lightbulb_outline),
                      suffixIcon: Tooltip(
                        message: '作者的话：教务系统预留，目前作用未知',
                        child: Icon(Icons.help_outline),
                      ),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('显示密码'),
                    value: _showPasswords,
                    onChanged: _submitting
                        ? null
                        : (value) => setState(() => _showPasswords = value),
                  ),
                  Text(
                    '新密码和密码提示只会提交给学校；应用仅在学校明确返回修改成功后保存最终新密码。',
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    ErrorBox(message: _error!),
                  ],
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _submitting ? null : _submit,
                    icon: _submitting
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save),
                    label: Text(_submitting ? '正在提交学校…' : '保存新密码'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class EducationLoginPage extends StatefulWidget {
  final String studentId;
  final bool autoFillSavedAccount;
  final GradeSyncScope gradeSyncScope;
  final bool syncSchedules;
  final bool forceScheduleSync;
  final bool fetchAllSchedules;
  final String? scheduleTerm;
  final String? gradeTerm;
  final bool syncGrades;

  const EducationLoginPage({
    required this.studentId,
    this.autoFillSavedAccount = false,
    this.gradeSyncScope = GradeSyncScope.latest,
    this.syncSchedules = true,
    this.forceScheduleSync = false,
    this.fetchAllSchedules = false,
    this.scheduleTerm,
    this.gradeTerm,
    this.syncGrades = true,
    super.key,
  });

  @override
  State<EducationLoginPage> createState() => _EducationLoginPageState();
}

class _EducationLoginPageState extends State<EducationLoginPage> {
  late final TextEditingController _studentIdCtrl;
  final _passwordCtrl = TextEditingController();
  final _captchaCtrl = TextEditingController();
  List<StoredAccount> _savedAccounts = const [];
  bool _showPassword = false;
  Uint8List? _captchaBytes;
  bool _loadingCaptcha = false;
  bool _loggingIn = false;
  bool _openingPasswordRecovery = false;
  bool _passwordResetPendingInMemory = false;
  bool _captchaOcrEnabled = true;
  bool _captchaOcrBusy = false;
  String? _captchaOcrHint;
  String _lastOcrCaptcha = '';
  int _captchaGeneration = 0;
  // flutter_onnxruntime 的 Android 会话不允许多个推理同时访问。初始化时
  // “读取 OCR 设置”和“获取首张验证码”可能几乎同时完成；统一排队后，
  // 旧验证码过期时也只会被安全地跳过，不会让原生运行时收到并发请求。
  Future<void> _captchaOcrTail = Future<void>.value();
  String? _syncProgress;
  String? _authenticatedStudentId;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _studentIdCtrl = TextEditingController(text: widget.studentId);
    _loadSavedAccounts();
    unawaited(_initializeCaptcha());
  }

  @override
  void dispose() {
    // 教务密码是本项目最敏感的凭据，销毁前先清空，别把明文留给 GC
    // （与同文件教务改密页 dispose 的既有写法保持一致）。
    _passwordCtrl.clear();
    _studentIdCtrl.clear();
    _captchaCtrl.clear();
    _studentIdCtrl.dispose();
    _passwordCtrl.dispose();
    _captchaCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSavedAccounts() async {
    final accounts = await CredentialStore.load(StoredAccountKind.education);
    if (!mounted) return;
    StoredAccount? selectedAccount;
    final currentStudentId = _studentIdCtrl.text.trim();
    for (final account in accounts) {
      if (account.username == currentStudentId) {
        selectedAccount = account;
        break;
      }
    }
    if (selectedAccount == null &&
        widget.autoFillSavedAccount &&
        accounts.isNotEmpty) {
      selectedAccount = accounts.first;
    }
    setState(() {
      _savedAccounts = accounts;
      if (selectedAccount != null) {
        _studentIdCtrl.text = selectedAccount.username;
        _passwordCtrl.text = selectedAccount.password;
      }
    });
  }

  void _selectSavedAccount(StoredAccount account) {
    setState(() {
      _studentIdCtrl.text = account.username;
      _passwordCtrl.text = account.password;
      _error = null;
    });
  }

  Future<void> _loadCaptchaOcrSetting() async {
    final settings = await AppSettings.load();
    if (!mounted) return;
    setState(() {
      _captchaOcrEnabled = settings.captchaOcrEnabled;
      if (!_captchaOcrEnabled) {
        _captchaOcrBusy = false;
        _captchaOcrHint = null;
      }
    });
  }

  Future<void> _initializeCaptcha() async {
    // 先确定开关，再请求验证码，避免首屏同时启动两次 OCR。
    try {
      await _loadCaptchaOcrSetting();
    } catch (_) {
      // 设置文件损坏时保留默认开启状态，验证码仍应正常显示并允许手填。
    }
    if (mounted) await _refreshCaptcha();
  }

  Future<void> _recognizeCaptcha(
    Uint8List bytes, {
    required int generation,
  }) async {
    final task = _captchaOcrTail.catchError((_) {}).then<void>((_) async {
      if (!mounted || generation != _captchaGeneration || !_captchaOcrEnabled) {
        return;
      }
      await _recognizeCaptchaNow(bytes, generation: generation);
    });
    _captchaOcrTail = task.catchError((_) {});
    await task;
  }

  Future<void> _recognizeCaptchaNow(
    Uint8List bytes, {
    required int generation,
  }) async {
    if (!_captchaOcrEnabled || bytes.isEmpty) return;
    if (mounted) {
      setState(() {
        _captchaOcrBusy = true;
        _captchaOcrHint = null;
      });
    }
    String? recognized;
    try {
      recognized = await CaptchaOcr.recognize(bytes);
    } catch (_) {
      // OCR 是可选增强功能；任何平台/模型异常都必须回退到手动输入，
      // 不能因为自动识别失败阻断教务登录。
      recognized = null;
    }
    if (!mounted || generation != _captchaGeneration || !_captchaOcrEnabled) {
      return;
    }
    final current = _captchaCtrl.text.trim();
    if (recognized != null && (current.isEmpty || current == _lastOcrCaptcha)) {
      _captchaCtrl.value = TextEditingValue(
        text: recognized,
        selection: TextSelection.collapsed(offset: recognized.length),
      );
      _lastOcrCaptcha = recognized;
      setState(() {
        _captchaOcrBusy = false;
        _captchaOcrHint = '已自动识别，可按需修改';
      });
    } else {
      setState(() {
        _captchaOcrBusy = false;
        _captchaOcrHint = recognized == null ? '未识别成功，请手动输入' : '验证码已手动修改';
      });
    }
  }

  Future<void> _refreshCaptcha({bool clearError = true}) async {
    if (_loadingCaptcha) return;
    final previousError = clearError ? null : _error;
    final generation = ++_captchaGeneration;
    setState(() {
      _loadingCaptcha = true;
      _error = previousError;
      _captchaOcrBusy = false;
      _captchaOcrHint = null;
      _lastOcrCaptcha = '';
      _captchaCtrl.clear();
    });
    try {
      // 直接请求实际验证码接口，不再先做一轮容易受页面模板/502 影响的
      // 根路径探测。首个连接给隧道一点热身时间，短暂失败时自动重试，
      // 避免用户必须手动点击刷新。
      Object? lastError;
      const retryDelays = [
        Duration.zero,
        Duration(milliseconds: 700),
        Duration(milliseconds: 1400),
      ];
      Uint8List? bytes;
      for (var attempt = 0; attempt < retryDelays.length; attempt++) {
        if (attempt > 0) await Future<void>.delayed(retryDelays[attempt]);
        try {
          bytes = await JwxtClient().getCaptcha().timeout(
            const Duration(seconds: 10),
          );
          break;
        } catch (error) {
          lastError = error;
        }
      }
      if (bytes == null) throw lastError ?? '验证码请求失败';
      if (mounted) {
        setState(() => _captchaBytes = bytes);
        if (_captchaOcrEnabled) {
          unawaited(_recognizeCaptcha(bytes, generation: generation));
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          const refreshError = '获取教务验证码失败';
          _error = previousError == null
              ? refreshError
              : '$previousError\n$refreshError';
        });
      }
    } finally {
      if (mounted) setState(() => _loadingCaptcha = false);
    }
  }

  Future<void> _returnToMain() async {
    if (_loggingIn || _openingPasswordRecovery) return;
    await JwxtClient().resetSession();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => const VpnSetupPage(mode: AppMode.vpnOnly),
      ),
      (_) => false,
    );
  }

  Future<void> _openPasswordRecovery() async {
    if (_loggingIn || _openingPasswordRecovery) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _openingPasswordRecovery = true;
      _error = null;
      _notice = '正在确认校园内网连接…';
    });
    try {
      final reachable = await JwxtClient().waitForIntranet(
        timeout: const Duration(seconds: 15),
      );
      if (!mounted) return;
      if (!reachable) {
        setState(() {
          _notice = null;
          _error = '忘记密码页面只能在校园内网中使用，请先确认校园加速器已连接';
        });
        return;
      }
      setState(() => _notice = null);
      final outcome = await Navigator.of(context).push<PasswordRecoveryOutcome>(
        MaterialPageRoute(
          builder: (_) => EducationPasswordRecoveryPage(
            initialStudentId: _studentIdCtrl.text.trim(),
          ),
        ),
      );
      if (!mounted) return;

      // 找回流程会使用独立验证码会话。无论用户完成还是取消，返回登录页
      // 后都重新建立登录验证码，避免拿找回密码的 Cookie 去提交登录。
      await JwxtClient().resetSession();
      _captchaCtrl.clear();
      _authenticatedStudentId = null;
      if (outcome != null) {
        _studentIdCtrl.text = outcome.studentId;
        _passwordCtrl.clear();
        _passwordResetPendingInMemory = true;
        await _loadSavedAccounts();
        if (!mounted) return;
        setState(() {
          _savedAccounts = _savedAccounts
              .where((account) => account.username != outcome.studentId)
              .toList(growable: false);
          _passwordCtrl.clear();
          _notice = outcome.localCredentialsInvalidated
              ? '旧教务密码已删除。请手动输入身份证后六位临时密码；该临时密码不会保存。'
              : '学校已完成重置。应用会禁止保存 6 位数字临时密码，请勿继续使用任何旧密码。';
        });
      }
      await _refreshCaptcha(clearError: false);
    } catch (_) {
      if (mounted) {
        setState(() {
          _notice = null;
          // 不要把原始异常抛给用户：它可能是英文堆栈或 DioException，
          // 既看不懂也可能带内部地址。只给可执行的下一步。
          _error = '无法打开忘记密码流程，请重试；若多次失败请联系作者';
        });
      }
    } finally {
      if (mounted) setState(() => _openingPasswordRecovery = false);
    }
  }

  Future<void> _completeRequiredPasswordChange({
    required String studentId,
    required EducationPasswordChangeForm form,
  }) async {
    final outcome = await Navigator.of(context)
        .push<EducationPasswordChangedOutcome>(
          MaterialPageRoute(
            builder: (_) => EducationRequiredPasswordChangePage(
              studentId: studentId,
              form: form,
            ),
          ),
        );
    if (!mounted) return;
    if (outcome == null) {
      setState(() {
        _error = '必须完成新密码设置后才能继续；临时密码没有保存';
      });
      return;
    }

    final saved = await CredentialStore.save(
      StoredAccountKind.education,
      username: outcome.studentId,
      password: outcome.newPassword,
    );
    if (saved) {
      await CredentialStore.clearEducationPasswordResetPending(
        outcome.studentId,
      );
    }
    await JwxtClient().resetSession();
    if (!mounted) return;
    _authenticatedStudentId = null;
    _passwordResetPendingInMemory = !saved;
    _captchaCtrl.clear();
    _passwordCtrl.text = saved ? outcome.newPassword : '';
    await _loadSavedAccounts();
    if (!mounted) return;
    setState(() {
      if (!saved) {
        _savedAccounts = _savedAccounts
            .where((account) => account.username != outcome.studentId)
            .toList(growable: false);
        _passwordCtrl.clear();
      }
      _notice = saved
          ? '新密码设置成功并已安全保存。请重新输入验证码，用新密码登录。'
          : '学校已确认新密码设置成功，但本地安全存储写入失败。请手动输入新密码重新登录。';
      _error = null;
    });
    await _refreshCaptcha(clearError: false);
  }

  Future<void> _login() async {
    String? credentialNotice;
    final studentId = _studentIdCtrl.text.trim();
    final alreadyAuthenticated =
        JwxtClient().isLoggedIn &&
        (JwxtClient().authenticatedStudentId == studentId ||
            _authenticatedStudentId == studentId);
    if (studentId.isEmpty ||
        (!alreadyAuthenticated &&
            (_passwordCtrl.text.isEmpty || _captchaCtrl.text.trim().isEmpty))) {
      setState(() => _error = '请输入学号、教务密码和验证码');
      return;
    }
    // 认证和离线数据同步是两个独立阶段。认证成功后，即使同步被冷却、
    // 网络或某个学期查询失败，也必须让用户进入本地首页继续使用已有数据。
    var authenticationSucceeded = alreadyAuthenticated;
    FocusScope.of(context).unfocus();
    setState(() {
      _loggingIn = true;
      _syncProgress = !widget.syncGrades
          ? widget.fetchAllSchedules
                ? '正在手动保存所有已知学期课表…'
                : widget.scheduleTerm == null
                ? '正在手动保存最新课表…'
                : '正在手动保存课表：${widget.scheduleTerm}…'
          : alreadyAuthenticated
          ? widget.gradeTerm != null
                ? '正在手动更新成绩：${widget.gradeTerm}…'
                : widget.gradeSyncScope == GradeSyncScope.all
                ? '正在手动更新全部成绩…'
                : '正在更新最新学期成绩…'
          : '正在认证教务系统…';
      _error = null;
    });
    try {
      if (!alreadyAuthenticated) {
        final loginPassword = _passwordCtrl.text;
        final loginResult = await JwxtClient().login(
          studentId,
          loginPassword,
          _captchaCtrl.text.trim(),
        );
        if (loginResult.status == JwxtLoginStatus.passwordChangeRequired) {
          await _completeRequiredPasswordChange(
            studentId: studentId,
            form: loginResult.passwordChangeForm!,
          );
          return;
        }
        if (!loginResult.isSuccess) throw '教务系统未返回登录成功状态';
        authenticationSucceeded = true;
        _authenticatedStudentId = studentId;
        final resetPending =
            _passwordResetPendingInMemory ||
            await CredentialStore.isEducationPasswordResetPending(studentId);
        final maySave =
            !resetPending || isValidFinalEducationPassword(loginPassword);
        if (maySave) {
          final saved = await CredentialStore.save(
            StoredAccountKind.education,
            username: studentId,
            password: loginPassword,
          );
          if (saved && resetPending) {
            await CredentialStore.clearEducationPasswordResetPending(studentId);
            _passwordResetPendingInMemory = false;
          } else if (!saved) {
            // 走到这里说明 maySave 为真 —— 密码规则已经满足，失败原因只可能是
            // 安全存储写入失败。旧文案把两个原因并列，用户无法分辨。
            credentialNotice = '密码未能保存到本机，请稍后重试';
          }
        } else {
          credentialNotice = '当前是临时密码，不会被保存。请登录后尽快设置新密码';
        }
        await _loadSavedAccounts();
      }
      late final OfflineSyncResult syncResult;
      try {
        syncResult = await syncOfflineUserData(
          studentId: studentId,
          gradeSyncScope: widget.gradeSyncScope,
          syncSchedules: widget.syncSchedules,
          forceScheduleSync: widget.forceScheduleSync,
          fetchAllSchedules: widget.fetchAllSchedules,
          scheduleTerm: widget.scheduleTerm,
          gradeTerm: widget.gradeTerm,
          syncGrades: widget.syncGrades,
          onProgress: (message) {
            if (mounted) setState(() => _syncProgress = message);
          },
        );
      } catch (syncError) {
        if (!mounted) return;
        final raw = '$syncError';
        // 「更新冷却中，还需 X 后重试」是我们自己生成的提示（含剩余时间），
        // 可以直接展示；其它异常可能是原始堆栈，不外显。
        final syncNotice = raw.contains('更新冷却中')
            ? '已登录，$raw；稍后重试更新'
            : '已登录，但数据更新失败，稍后可在课表或成绩页面重试更新';
        final completeNotice = credentialNotice == null
            ? syncNotice
            : '$syncNotice；$credentialNotice';
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (_) =>
                HomePage(studentId: studentId, initialNotice: completeNotice),
          ),
          (_) => false,
        );
        return;
      }
      if (!mounted) return;
      final failedSuffix = syncResult.failedTerms.isEmpty
          ? ''
          : '；${syncResult.failedTerms.length} 个学期暂未更新，已保留原本地数据';
      final gradeSuffix = !widget.syncGrades || syncResult.gradesUpdated
          ? ''
          : '；成绩更新不完整，已保留原本地成绩';
      final gradeScopeText = syncResult.gradesFetchedAll
          ? '全部成绩'
          : widget.gradeTerm != null
          ? '${widget.gradeTerm}成绩'
          : '最新学期成绩';
      final savedDataPrefix = syncResult.schedulesUpdated
          ? syncResult.schedulesFetchedAll
                ? '已保存 ${syncResult.savedTermCount} 个学期课表'
                : widget.scheduleTerm != null
                ? '已更新 ${widget.scheduleTerm} 课表'
                : widget.syncGrades
                ? '已保存最新一期课表和 '
                : '已保存最新一期课表'
          : syncResult.schedulesSkipped
          ? '本地已有课表，跳过课表保存；'
          : widget.syncSchedules
          ? '本次未找到已发布课表；'
          : '已更新 ';
      final gradeDescription = widget.syncGrades
          ? '${syncResult.gradeCount} 条$gradeScopeText'
          : '';
      final notice = widget.syncGrades
          ? '$savedDataPrefix$gradeDescription$failedSuffix$gradeSuffix'
          : '$savedDataPrefix${failedSuffix.isEmpty ? '' : failedSuffix}';
      final completeNotice = credentialNotice == null
          ? notice
          : '$notice；$credentialNotice';
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) =>
              HomePage(studentId: studentId, initialNotice: completeNotice),
        ),
        (_) => false,
      );
    } catch (error) {
      if (mounted) {
        if (authenticationSucceeded) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (_) => HomePage(
                studentId: studentId,
                // 不把 $error 原始异常贴给用户；同步失败的具体原因
                // 可以在课表/成绩页重试时看到更明确的提示。
                initialNotice: '已登录，但本次数据同步未完成，'
                    '稍后可在课表或成绩页面重试更新',
              ),
            ),
            (_) => false,
          );
        } else {
          // jwxt_client 抛的是面向用户的中文说明（如"请检查教务密码和验证码"），
          // 可以原样展示；其它异常（网络层/Dio）可能是原始堆栈，不外显。
          _error = error is String ? error : '教务登录失败，请重试';
          _captchaCtrl.clear();
          await _refreshCaptcha(clearError: false);
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _loggingIn = false;
          _syncProgress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leadingWidth: 106,
        leading: TextButton.icon(
          onPressed: _loggingIn || _openingPasswordRecovery
              ? null
              : _returnToMain,
          icon: const Icon(Icons.arrow_back, size: 23),
          label: const Text('返回', style: TextStyle(fontSize: 17)),
        ),
        title: const Text('教务系统登录'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
              children: [
                Icon(Icons.lock_person, color: colorScheme.primary, size: 52),
                const SizedBox(height: 14),
                Text(
                  '第二步：登录教务系统',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colorScheme.onSurface,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 28),
                TextField(
                  controller: _studentIdCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: '教务系统学号',
                    prefixIcon: Icon(Icons.badge_outlined),
                    suffixIcon: _accountPicker(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordCtrl,
                  obscureText: !_showPassword,
                  decoration: InputDecoration(
                    labelText: '教务系统密码',
                    prefixIcon: Icon(Icons.lock_outline),
                    suffixIcon: _PasswordVisibilityButton(
                      visible: _showPassword,
                      onPressed: () =>
                          setState(() => _showPassword = !_showPassword),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _captchaCtrl,
                        keyboardType: TextInputType.visiblePassword,
                        textCapitalization: TextCapitalization.none,
                        autocorrect: false,
                        enableSuggestions: false,
                        onChanged: (value) {
                          final lower = value.toLowerCase();
                          if (lower != value) {
                            _captchaCtrl.value = _captchaCtrl.value.copyWith(
                              text: lower,
                              selection: TextSelection.collapsed(
                                offset: lower.length,
                              ),
                              composing: TextRange.empty,
                            );
                          }
                        },
                        decoration: const InputDecoration(
                          labelText: '验证码',
                          prefixIcon: Icon(Icons.verified_outlined),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    InkWell(
                      onTap:
                          _loadingCaptcha ||
                              _loggingIn ||
                              _openingPasswordRecovery
                          ? null
                          : _refreshCaptcha,
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        width: 128,
                        height: 58,
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: colorScheme.outlineVariant),
                        ),
                        alignment: Alignment.center,
                        child: _loadingCaptcha
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: colorScheme.primary,
                                ),
                              )
                            : _captchaBytes == null
                            ? Icon(
                                Icons.refresh,
                                color: colorScheme.onSurfaceVariant,
                              )
                            : Image.memory(_captchaBytes!, fit: BoxFit.contain),
                      ),
                    ),
                  ],
                ),
                if (_captchaOcrEnabled) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        _captchaOcrBusy
                            ? Icons.sync
                            : Icons.document_scanner_outlined,
                        size: 15,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          _captchaOcrBusy
                              ? '正在本机识别验证码…'
                              : (_captchaOcrHint ??
                                    (Platform.isAndroid || Platform.isWindows
                                        ? '验证码自动识别已开启'
                                        : '当前平台不支持 OCR，请手动输入')),
                          style: TextStyle(
                            color: colorScheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 20),
                if (_error != null) ErrorBox(message: _error!),
                if (_error != null) const SizedBox(height: 16),
                if (_notice != null) ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer.withAlpha(110),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(_notice!),
                  ),
                  const SizedBox(height: 16),
                ],
                LayoutBuilder(
                  builder: (context, constraints) {
                    final loginButton = SizedBox(
                      height: 54,
                      child: FilledButton.icon(
                        onPressed: _loggingIn || _openingPasswordRecovery
                            ? null
                            : _login,
                        icon: _loggingIn
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: colorScheme.onPrimary,
                                ),
                              )
                            : const Icon(Icons.login),
                        label: Text(
                          _loggingIn
                              ? (_syncProgress ?? '正在登录教务…')
                              : '登录并保存离线数据',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    );
                    final forgotButton = SizedBox(
                      height: 54,
                      child: OutlinedButton.icon(
                        onPressed: _loggingIn || _openingPasswordRecovery
                            ? null
                            : _openPasswordRecovery,
                        icon: _openingPasswordRecovery
                            ? const SizedBox.square(
                                dimension: 17,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.help_outline),
                        label: Text(
                          _openingPasswordRecovery ? '正在检查…' : '忘记密码',
                        ),
                      ),
                    );
                    if (constraints.maxWidth >= 520) {
                      return Row(
                        children: [
                          Expanded(child: loginButton),
                          const SizedBox(width: 12),
                          SizedBox(width: 150, child: forgotButton),
                        ],
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        loginButton,
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerRight,
                          child: forgotButton,
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _accountPicker() {
    return PopupMenuButton<StoredAccount>(
      tooltip: '选择已保存账号',
      icon: const Icon(Icons.keyboard_arrow_down),
      onSelected: _selectSavedAccount,
      itemBuilder: (context) {
        if (_savedAccounts.isEmpty) {
          return const [
            PopupMenuItem<StoredAccount>(
              enabled: false,
              child: Text('暂无已保存账号'),
            ),
          ];
        }
        return _savedAccounts
            .map(
              (account) => PopupMenuItem<StoredAccount>(
                value: account,
                child: Text(account.username),
              ),
            )
            .toList();
      },
    );
  }
}

/// 携带 [VpnFailure] 枚举的连接失败。
///
/// 改造前这里是裸字符串，UI 层拿到后要靠中文子串反推是哪种失败；
/// 现在类型本身就携带分类，_connect 直接 switch 即可。
class _VpnConnectException implements Exception {
  final VpnFailure kind;

  /// 需要覆盖默认文案时使用（例如"已用其他账号连接"没有对应的枚举值）。
  final String? customMessage;

  const _VpnConnectException(this.kind, {this.customMessage});

  String get display => customMessage ?? kind.message;

  @override
  String toString() => display;
}