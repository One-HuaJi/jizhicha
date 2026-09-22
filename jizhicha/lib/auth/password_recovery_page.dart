// 教务密码找回（账号验证 / 身份证件号核验）与登录后强制改密页面。
import 'dart:async' show unawaited;
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app_settings.dart';
import '../campus_navigator_page.dart';
import '../captcha_ocr.dart';
import '../credential_store.dart';
import '../jwxt_client.dart';

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
