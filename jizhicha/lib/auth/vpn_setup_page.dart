// 校园加速器认证与连接页（VpnSetupPage、其私有部件与连接异常类型）。
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../app_mode.dart';
import '../campus_environment.dart';
import '../campus_navigator_page.dart';
import '../campus_vpn.dart';
import '../common.dart';
import '../credential_store.dart';
import '../jwxt_client.dart';
import '../sync_cooldown.dart';
import '../vpn_session.dart';
import 'auth_shared.dart';
import 'education_login_page.dart';

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
              customMessage: '当前校园网已使用其他账号连接，请先退出登录后再切换账号');
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
    const title = '连接校园网';
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
                  '连接校园网后，可使用学校教务系统、图书馆、知网等服务',
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
                  label: '校园加速器学号',
                  icon: Icons.badge_outlined,
                  keyboardType: TextInputType.number,
                  suffixIcon: _accountPicker(),
                ),
                const SizedBox(height: 16),
                _styledField(
                  controller: _passwordCtrl,
                  label: '校园加速器密码',
                  icon: Icons.lock_outline,
                  obscureText: !_showPassword,
                  suffixIcon: AuthPasswordVisibilityButton(
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
