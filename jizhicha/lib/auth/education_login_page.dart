// 教务系统登录页（验证码识别、离线数据同步与页面跳转）。
import 'dart:async' show unawaited;
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app_mode.dart';
import '../app_settings.dart';
import '../campus_navigator_page.dart';
import '../captcha_ocr.dart';
import '../credential_store.dart';
import '../home_page.dart';
import '../jwxt_client.dart';
import '../offline_sync.dart';
import '../sync_cooldown.dart';
import 'auth_shared.dart';
import 'password_recovery_page.dart';
import 'vpn_setup_page.dart';

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
      _notice = '正在确认校园网连接…';
    });
    try {
      final reachable = await JwxtClient().waitForIntranet(
        timeout: const Duration(seconds: 15),
      );
      if (!mounted) return;
      if (!reachable) {
        setState(() {
          _notice = null;
          _error = '忘记密码页面只能在校园网中使用，请先连接校园加速器';
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
                    suffixIcon: AuthPasswordVisibilityButton(
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
