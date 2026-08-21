import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, MethodChannel;
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' show parse;
import 'package:image/image.dart' as img;
import 'package:ffi/ffi.dart' as ffi_utils;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:async' show Timer, runZonedGuarded;
import 'dart:io'
    show Directory, File, HttpClient, InternetAddress, Platform, Socket;

import 'credential_store.dart';
import 'schedule_cache_store.dart';
import 'theme.dart';

void main() {
  // 用 runZonedGuarded 包一层：所有未捕获的异步异常都会进 zoneError，
  // 避免被 Flutter 静默吞掉导致 UI 看起来"卡死未响应"。
  // VS Code 调试控制台会直接看到 stack trace，下次卡住能精确定位。
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      runApp(const MyApp());
    },
    (e, st) {
      debugPrint('=== [zoneError] 未捕获异步异常: $e');
      debugPrint('$st');
    },
  );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    themeNotifier.addListener(_onThemeChanged);
    ThemeService.load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    CampusVpnLauncher.shutdownNow();
    themeNotifier.removeListener(_onThemeChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      CampusVpnLauncher.shutdownNow();
    }
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '稽之查',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeNotifier.value,
      home: const AppBootstrapPage(),
    );
  }
}

/// 应用启动时优先展示本机已经保存的离线课表与成绩。
///
/// 只有在本机没有任何可展示的教务课表时才进入加速器认证页。这样离线时也能
/// 查看自己的已保存课表，同时不会因为启动应用而额外向校园网发起请求。
class AppBootstrapPage extends StatefulWidget {
  const AppBootstrapPage({super.key});

  @override
  State<AppBootstrapPage> createState() => _AppBootstrapPageState();
}

class _AppBootstrapPageState extends State<AppBootstrapPage> {
  Widget? _destination;

  @override
  void initState() {
    super.initState();
    _resolveStartupDestination();
  }

  Future<void> _resolveStartupDestination() async {
    final accounts = await CredentialStore.load(StoredAccountKind.education);
    StoredAccount? account;
    for (final candidate in accounts) {
      final profile = await UserDataCacheStore.loadProfile(candidate.username);
      final legacySchedule = profile == null
          ? await ScheduleCacheStore.loadLatest(candidate.username)
          : null;
      if (profile != null || legacySchedule != null) {
        account = candidate;
        break;
      }
    }

    if (!mounted) return;
    setState(() {
      _destination = account != null
          ? HomePage(studentId: account.username)
          : const VpnSetupPage(
              mode: AppMode.vpnOnly,
              initialNotice: '您之前未进行过认证，本地暂无存储，请认证后保存课表',
            );
    });
  }

  @override
  Widget build(BuildContext context) {
    return _destination ??
        const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

// ==================== 网络核心（单例，Cookie共享） ====================
enum GradeSyncScope { latest, all }

enum SyncResource { schedule, grade }

/// 手动课表/成绩查询共用的短冷却，避免用户连续点击导致教务系统重复
/// 返回同一份页面或触发网关限流。冷却从请求开始计时，失败时也保留，
/// 这样“重试”不会在几秒内形成请求风暴。
class DataSyncCooldownController extends ChangeNotifier {
  static const duration = Duration(seconds: 30);

  DateTime? _scheduleUntil;
  DateTime? _gradeUntil;
  Timer? _timer;

  DateTime? _untilFor(SyncResource resource) =>
      resource == SyncResource.schedule ? _scheduleUntil : _gradeUntil;

  Duration remaining(SyncResource resource, {DateTime? now}) {
    final until = _untilFor(resource);
    if (until == null) return Duration.zero;
    final left = until.difference(now ?? DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  bool isCooling(SyncResource resource) => remaining(resource) > Duration.zero;

  String remainingText(SyncResource resource) {
    final seconds = remaining(resource).inSeconds.ceil();
    return seconds <= 0 ? '' : '${seconds}s';
  }

  bool tryStartAll(Iterable<SyncResource> resources) {
    final unique = resources.toSet();
    if (unique.any(isCooling)) return false;
    final until = DateTime.now().add(duration);
    if (unique.contains(SyncResource.schedule)) _scheduleUntil = until;
    if (unique.contains(SyncResource.grade)) _gradeUntil = until;
    if (unique.isNotEmpty) {
      _ensureTimer();
      notifyListeners();
    }
    return true;
  }

  void _ensureTimer() {
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!isCooling(SyncResource.schedule) && !isCooling(SyncResource.grade)) {
        _timer?.cancel();
        _timer = null;
      }
      notifyListeners();
    });
  }
}

final dataSyncCooldown = DataSyncCooldownController();

/// 显示课表/成绩本次同步的 30 秒冷却状态。
/// 页面本身监听 [dataSyncCooldown]，因此倒计时会在不重新进入页面的情况下
/// 每秒刷新；没有冷却时不占用额外的布局空间。
class _SyncCooldownIndicator extends StatelessWidget {
  final SyncResource resource;

  const _SyncCooldownIndicator({required this.resource});

  @override
  Widget build(BuildContext context) {
    final remaining = dataSyncCooldown.remaining(resource);
    if (remaining <= Duration.zero) return const SizedBox.shrink();
    final seconds = remaining.inSeconds.ceil();
    final totalMilliseconds =
        DataSyncCooldownController.duration.inMilliseconds;
    final progress = (1 - remaining.inMilliseconds / totalMilliseconds).clamp(
      0.0,
      1.0,
    );
    final label = resource == SyncResource.schedule ? '课表' : '成绩';
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '$label更新冷却中，还需 $seconds 秒',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(
              value: progress,
              strokeWidth: 3,
              color: colorScheme.primary,
              backgroundColor: colorScheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$label冷却 ${seconds}s',
            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

enum JwxtLoginStatus { success, passwordChangeRequired }

class JwxtLoginResult {
  final JwxtLoginStatus status;
  final EducationPasswordChangeForm? passwordChangeForm;

  const JwxtLoginResult._(this.status, [this.passwordChangeForm]);

  const JwxtLoginResult.success() : this._(JwxtLoginStatus.success);

  const JwxtLoginResult.passwordChangeRequired(EducationPasswordChangeForm form)
    : this._(JwxtLoginStatus.passwordChangeRequired, form);

  bool get isSuccess => status == JwxtLoginStatus.success;
}

class EducationPasswordChangeForm {
  final String action;
  final String oldPasswordField;
  final String newPasswordField;
  final String confirmPasswordField;
  final String passwordHintField;
  final Map<String, String> hiddenFields;

  const EducationPasswordChangeForm({
    required this.action,
    required this.oldPasswordField,
    required this.newPasswordField,
    required this.confirmPasswordField,
    required this.passwordHintField,
    required this.hiddenFields,
  });
}

class PasswordRecoveryAccountResult {
  final String studentId;
  final String accountType;

  const PasswordRecoveryAccountResult({
    required this.studentId,
    required this.accountType,
  });
}

class PasswordRecoveryResetResult {
  final bool success;
  final String message;

  const PasswordRecoveryResetResult({
    required this.success,
    required this.message,
  });
}

class EducationPasswordChangeResult {
  final bool success;
  final String message;

  const EducationPasswordChangeResult({
    required this.success,
    required this.message,
  });
}

bool isValidFinalEducationPassword(String password) {
  return isEducationPasswordSafeToStore(password);
}

String? educationPasswordValidationError({
  required String oldPassword,
  required String newPassword,
  required String confirmPassword,
  required String passwordHint,
}) {
  if (oldPassword.isEmpty ||
      newPassword.isEmpty ||
      confirmPassword.isEmpty ||
      passwordHint.trim().isEmpty) {
    return '请完整填写旧密码、新密码、确认新密码和新密码提示';
  }
  if (!isValidFinalEducationPassword(newPassword)) {
    return '新密码至少 8 位，并且必须同时包含字母和数字';
  }
  if (newPassword != confirmPassword) return '两次输入的新密码不一致';
  if (newPassword == oldPassword) return '新密码不能与临时旧密码相同';
  if (passwordHint.toLowerCase().contains(newPassword.toLowerCase())) {
    return '新密码提示不能包含完整的新密码';
  }
  return null;
}

String _compactHtmlText(String value) =>
    value.replaceAll(RegExp(r'\s+'), ' ').trim();

String? extractJwxtAlertMessage(String html) {
  final messages = _extractJwxtAlertMessages(html);
  if (messages.isNotEmpty) return messages.first;
  final showMessage = _compactHtmlText(
    parse(html).querySelector('#showMsg')?.text ?? '',
  );
  return showMessage.isEmpty ? null : showMessage;
}

List<String> _extractJwxtAlertMessages(String html) {
  final messages = RegExp(
    r'''alert\s*\(\s*['"]([^'"]+)['"]\s*\)''',
    caseSensitive: false,
  ).allMatches(html).map((match) => _compactHtmlText(match.group(1) ?? ''));
  return messages
      .where((message) => message.isNotEmpty)
      .toList(growable: false);
}

bool _isPasswordChangeSuccessMessage(String value) {
  final normalized = _compactHtmlText(value);
  return RegExp(
    r'(密码\s*(?:修改|设置|更新|保存|重置)\s*成功|'
    r'(?:修改|设置|更新|保存)\s*(?:新)?密码\s*成功|'
    r'(?:修改|设置|更新|保存|提交|操作)\s*成功)',
  ).hasMatch(normalized);
}

bool _isPasswordChangeFailureMessage(String value) {
  final normalized = _compactHtmlText(value);
  return RegExp(r'(失败|错误|不正确|不能为空|请输入完整|未成功|无效|拒绝|不符合)').hasMatch(normalized);
}

EducationPasswordChangeResult parseEducationPasswordChangeResponse({
  required int? statusCode,
  required String location,
  required String raw,
}) {
  final lowerLocation = location.toLowerCase();
  if (lowerLocation.contains('framework') || lowerLocation.contains('xsmain')) {
    return const EducationPasswordChangeResult(
      success: true,
      message: '新密码设置成功',
    );
  }

  final normalizedRaw = raw.trim();
  try {
    final decoded = jsonDecode(normalizedRaw);
    if (decoded is Map) {
      final successValue = decoded['success'];
      final success =
          successValue == true ||
          successValue?.toString().toLowerCase() == 'true';
      final message =
          decoded['message']?.toString().trim() ??
          (success ? '新密码设置成功' : '新密码设置失败');
      return EducationPasswordChangeResult(success: success, message: message);
    }
  } catch (_) {
    // 官网常返回 HTML/脚本，继续按页面响应解析。
  }

  final document = parse(normalizedRaw);
  final showMessage = _compactHtmlText(
    document.querySelector('#showMsg')?.text ?? '',
  );
  final bodyMessage = _compactHtmlText(document.body?.text ?? '');
  final visibleMessages = <String>[
    if (showMessage.isNotEmpty) showMessage,
    if (bodyMessage.isNotEmpty && bodyMessage != showMessage) bodyMessage,
  ];

  // 页面正文或 #showMsg 是服务器明确展示给用户的结果，优先于脚本中的
  // 表单校验提示，避免把页面源码里的“请输入完整信息”误当成实际结果。
  for (final message in visibleMessages) {
    if (_isPasswordChangeSuccessMessage(message)) {
      return EducationPasswordChangeResult(success: true, message: message);
    }
  }
  for (final message in visibleMessages) {
    if (_isPasswordChangeFailureMessage(message)) {
      return EducationPasswordChangeResult(success: false, message: message);
    }
  }

  final scripts = _extractJwxtAlertMessages(normalizedRaw);
  final scriptSuccess = scripts.where(_isPasswordChangeSuccessMessage);
  if (scriptSuccess.isNotEmpty) {
    return EducationPasswordChangeResult(
      success: true,
      message: scriptSuccess.first,
    );
  }
  final scriptFailure = scripts.where(_isPasswordChangeFailureMessage);
  if (scriptFailure.isNotEmpty) {
    return EducationPasswordChangeResult(
      success: false,
      message: scriptFailure.first,
    );
  }

  // 某些版本不使用 HTTP Location，而是用脚本跳转到首页。
  final scriptedLocation = RegExp(
    r'''(?:location(?:\.href)?|window\.location(?:\.href)?|'''
    r'''top\.location(?:\.href)?|parent\.location(?:\.href)?)\s*'''
    r'''(?:=\s*|\.replace\s*\(\s*)['"]([^'"]+)['"]''',
    caseSensitive: false,
  ).firstMatch(normalizedRaw)?.group(1);
  final lowerScriptedLocation = scriptedLocation?.toLowerCase() ?? '';
  if (lowerScriptedLocation.contains('framework') ||
      lowerScriptedLocation.contains('xsmain')) {
    return const EducationPasswordChangeResult(
      success: true,
      message: '新密码设置成功',
    );
  }

  final message = visibleMessages.isNotEmpty
      ? visibleMessages.first
      : scripts.isNotEmpty
      ? scripts.first
      : '学校未返回可识别的改密结果，请勿重复提交并联系教务处确认';
  return EducationPasswordChangeResult(success: false, message: message);
}

const passwordRecoveryStudentIdError = '学号格式错误或未录入数据';

String normalizePasswordRecoveryAccountError(String message) {
  final normalized = _compactHtmlText(message);
  // 强智教务对“学号不存在/未录入”的返回文案不固定，有的版本会复用
  // 登录页的“用户名或密码错误”，也有版本会错误地提示身份证号。
  // 这些都发生在第一步账号验证阶段，不能原样展示给用户造成误解。
  if (normalized.contains('用户名或密码错误') ||
      normalized.contains('账号不存在') ||
      normalized.contains('帐号不存在') ||
      normalized.contains('学号不存在') ||
      normalized.contains('请输入正确的身份证号')) {
    return passwordRecoveryStudentIdError;
  }
  return message;
}

PasswordRecoveryAccountResult parsePasswordRecoveryAccountPage(
  String html, {
  required String expectedStudentId,
}) {
  final normalizedId = expectedStudentId.trim();
  final document = parse(html);
  final identityInput = document.querySelector('input[name="sfzjh"]');
  final accountInput = document.querySelector('input[name="account"]');
  // 官网成功页偶尔会同时带一段提示脚本。只要身份证表单和账号字段
  // 完整存在，就应优先按成功页解析，不能被页面中无关的 alert 拦截。
  if (identityInput != null && accountInput != null) {
    final returnedAccount = accountInput.attributes['value']?.trim() ?? '';
    if (returnedAccount != normalizedId) {
      throw '学校返回的账号与输入账号不一致，已停止重置';
    }
    final accountType =
        document
            .querySelector('input[name="accounttype"]')
            ?.attributes['value']
            ?.trim() ??
        '2';
    return PasswordRecoveryAccountResult(
      studentId: returnedAccount,
      accountType: accountType,
    );
  }

  final message = extractJwxtAlertMessage(html);
  if (message != null && message.isNotEmpty) {
    throw normalizePasswordRecoveryAccountError(message);
  }
  throw '学校找回密码页面结构发生变化，请稍后重试';
}

PasswordRecoveryResetResult parsePasswordRecoveryResetResponse(String raw) {
  final normalized = raw.trim();
  try {
    final decoded = jsonDecode(normalized);
    if (decoded is Map) {
      final successValue = decoded['success'] ?? decoded['result'];
      final normalizedSuccess = successValue?.toString().trim().toLowerCase();
      final success =
          successValue == true ||
          successValue == 1 ||
          normalizedSuccess == 'true' ||
          normalizedSuccess == '1' ||
          normalizedSuccess == 'success' ||
          normalizedSuccess == 'ok';
      return PasswordRecoveryResetResult(
        success: success,
        message:
            decoded['message']?.toString().trim() ??
            decoded['msg']?.toString().trim() ??
            (success ? '密码重置成功' : '密码重置失败'),
      );
    }
  } catch (_) {}

  bool isSuccessMessage(String value) {
    final text = _compactHtmlText(value);
    return RegExp(
      r'(密码\s*(?:已)?重置\s*成功|重置\s*密码\s*成功|密码\s*已重置为|密码\s*重置为.{0,30}后六位|操作\s*成功)',
    ).hasMatch(text);
  }

  bool isFailureMessage(String value) {
    return RegExp(
      r'(失败|错误|不正确|无效|未录入|不存在|不能为空|验证码有误)',
    ).hasMatch(_compactHtmlText(value));
  }

  final document = parse(normalized);
  final messages = <String>[
    ..._extractJwxtAlertMessages(normalized),
    _compactHtmlText(document.querySelector('#showMsg')?.text ?? ''),
  ].where((message) => message.isNotEmpty).toList(growable: false);
  for (final message in messages) {
    if (isFailureMessage(message)) {
      return PasswordRecoveryResetResult(success: false, message: message);
    }
    if (isSuccessMessage(message)) {
      return PasswordRecoveryResetResult(success: true, message: message);
    }
  }

  // Some StrongSoft variants return a small success page instead of JSON.
  // Only inspect body text when the identity form is no longer present, so
  // instructional text on the original form cannot impersonate success.
  final stillOnIdentityForm =
      document.querySelector('input[name="sfzjh"]') != null;
  final bodyMessage = _compactHtmlText(document.body?.text ?? '');
  if (!stillOnIdentityForm && isSuccessMessage(bodyMessage)) {
    return PasswordRecoveryResetResult(
      success: true,
      message: bodyMessage.isEmpty ? '密码重置成功' : bodyMessage,
    );
  }
  if (isFailureMessage(bodyMessage)) {
    return PasswordRecoveryResetResult(success: false, message: bodyMessage);
  }
  return PasswordRecoveryResetResult(
    success: false,
    message: messages.isNotEmpty
        ? messages.first
        : '学校未返回可识别的重置结果，请勿重复提交并联系教务处确认',
  );
}

bool isExpectedJwxtProbeResponse(int? statusCode, String body) {
  if (statusCode == null || statusCode < 200 || statusCode >= 500) return false;
  final lower = body.toLowerCase();
  if (lower.isEmpty) return false;
  return lower.contains('logintoxk') ||
      lower.contains('randomcode') ||
      lower.contains('verifycode.servlet') ||
      (lower.contains('jsxsd') &&
          (body.contains('强智') || body.contains('教务') || body.contains('验证码')));
}

String _nearbyInputText(html_dom.Element input) {
  html_dom.Element? current = input.parent;
  for (var depth = 0; current != null && depth < 5; depth++) {
    final text = _compactHtmlText(current.text);
    if (text.isNotEmpty) return text;
    current = current.parent;
  }
  return '';
}

/// 从学校“密码过于简单”页面动态解析字段名与提交地址。强智不同版本的
/// 字段名不完全一致，因此不硬编码旧/新密码参数，避免升级后把密码填错字段。
EducationPasswordChangeForm? parseEducationPasswordChangeForm(
  String html, {
  String fallbackAction = '/jsxsd/grsz/grsz_xgmm_beg.do',
}) {
  final document = parse(html);
  html_dom.Element? form;
  for (final candidate in document.querySelectorAll('form')) {
    final text = _compactHtmlText(candidate.text);
    final action = candidate.attributes['action']?.toLowerCase() ?? '';
    if ((text.contains('旧密码') && text.contains('新密码')) ||
        action.contains('xgmm')) {
      form = candidate;
      break;
    }
  }
  if (form == null) return null;
  final selectedForm = form;

  final hiddenFields = <String, String>{};
  final passwordInputs = <html_dom.Element>[];
  final textInputs = <html_dom.Element>[];
  String? oldField;
  String? newField;
  String? confirmField;
  String? hintField;

  for (final input in selectedForm.querySelectorAll('input')) {
    final name = input.attributes['name']?.trim() ?? '';
    if (name.isEmpty || input.attributes.containsKey('disabled')) continue;
    final type = (input.attributes['type'] ?? 'text').toLowerCase();
    final value = input.attributes['value'] ?? '';
    if (type == 'hidden' || input.attributes.containsKey('readonly')) {
      hiddenFields[name] = value;
      continue;
    }
    if (type == 'password') passwordInputs.add(input);
    if (type == 'text') textInputs.add(input);

    final nearby = _nearbyInputText(input);
    if (nearby.contains('确认新密码')) {
      confirmField = name;
    } else if (nearby.contains('旧密码')) {
      oldField = name;
    } else if (nearby.contains('新密码提示') || nearby.contains('密码提示')) {
      hintField = name;
    } else if (nearby.contains('新密码')) {
      newField = name;
    }
  }

  final passwordNames = passwordInputs
      .map((input) => input.attributes['name']?.trim() ?? '')
      .where((name) => name.isNotEmpty)
      .toList(growable: false);
  if (oldField == null && passwordNames.isNotEmpty) {
    oldField = passwordNames[0];
  }
  if (newField == null && passwordNames.length > 1) {
    newField = passwordNames[1];
  }
  if (confirmField == null && passwordNames.length > 2) {
    confirmField = passwordNames[2];
  }
  if (hintField == null) {
    for (final input in textInputs.reversed) {
      if (input.attributes.containsKey('readonly')) continue;
      final name = input.attributes['name']?.trim() ?? '';
      if (name.isNotEmpty) {
        hintField = name;
        break;
      }
    }
  }

  if (oldField == null ||
      newField == null ||
      confirmField == null ||
      hintField == null) {
    return null;
  }
  var action = selectedForm.attributes['action']?.trim();
  if (action == null ||
      action.isEmpty ||
      action == '#' ||
      action.toLowerCase().startsWith('javascript:')) {
    final scriptedAction = RegExp(
      r'''(?:url\s*:\s*|action\s*=\s*)['"]([^'"]*xgmm[^'"]*)['"]''',
      caseSensitive: false,
    ).firstMatch(html)?.group(1);
    action = scriptedAction?.trim();
  }
  return EducationPasswordChangeForm(
    action: action == null || action.isEmpty ? fallbackAction : action,
    oldPasswordField: oldField,
    newPasswordField: newField,
    confirmPasswordField: confirmField,
    passwordHintField: hintField,
    hiddenFields: hiddenFields,
  );
}

class GradeFetchResult {
  final List<Map<String, String>> grades;
  final List<String> failedTerms;

  /// 学校返回了有效成绩表的学期。即使表格为空，也算该学期查询成功，
  /// 这样本地缓存可以正确清除该学期已经不存在的旧成绩。
  final List<String> successfulTerms;

  const GradeFetchResult({
    required this.grades,
    required this.failedTerms,
    this.successfulTerms = const [],
  });

  bool get isComplete => failedTerms.isEmpty;
}

class JwxtClient {
  static final JwxtClient _instance = JwxtClient._internal();
  factory JwxtClient() => _instance;
  // Use the official host name for every HTTP request.  The old IP-only Host
  // header works on some StrongSoft deployments, but newer gateways route the
  // plain-HTTP site by virtual host and return a generic page to 172.20.63.226.
  static const _baseUrl = 'http://jw.huse.cn';
  static const _baseReferer = 'http://jw.huse.cn/jsxsd/';
  static const _hostAddress = '172.20.63.226';
  final CookieJar _cookieJar = CookieJar();
  late Dio _dio;
  bool isLoggedIn = false;
  String? authenticatedStudentId;
  String? _kbjcmsidCache; // 缓存从表单动态读取的节次模式ID，避免每次查询重复 GET
  String? _vpnSourceAddress;

  JwxtClient._internal() {
    _dio = _newDio();
  }

  Dio _newDio() {
    final dio = Dio(
      BaseOptions(
        baseUrl: _baseUrl,
        connectTimeout: const Duration(seconds: 15),
        followRedirects: false,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'zh-CN,zh;q=0.9',
        },
      ),
    );
    _configureDirectHttpClient(dio);
    dio.interceptors.add(CookieManager(_cookieJar));
    // 把连接/超时异常统一翻译为“加速器未连接”提示，避免每次手动 try/catch。
    // Dio 抛出的 DioException 在底层就是 SocketException / HandshakeException 包装的。
    dio.interceptors.add(
      InterceptorsWrapper(
        onError: (e, handler) {
          if (e.type == DioExceptionType.connectionError ||
              e.type == DioExceptionType.connectionTimeout ||
              e.type == DioExceptionType.sendTimeout ||
              e.type == DioExceptionType.receiveTimeout) {
            handler.reject(
              DioException(
                requestOptions: e.requestOptions,
                type: e.type,
                error: '无法连接校园内网（$_hostAddress），请确认已连接校园加速器后重试',
                stackTrace: e.stackTrace,
              ),
            );
            return;
          }
          handler.next(e);
        },
      ),
    );
    return dio;
  }

  /// 清除教务系统会话，但不影响已经建立的校园加速器隧道。
  ///
  /// “切换用户”需要保留加速器的源地址/代理，同时避免旧用户的 Cookie
  /// 被带到下一次验证码和登录请求中；“退出登录”也会复用这个清理动作。
  Future<void> resetSession() async {
    await _cookieJar.deleteAll();
    _kbjcmsidCache = null;
    isLoggedIn = false;
    authenticatedStudentId = null;
  }

  /// FlClash 的 TUN 会接管未绑定源地址的 TCP 连接，即使 Windows 路由表
  /// 已经存在 CampusVPN 的 /32 路由。加速器建好后把教务请求绑定到
  /// Wintun 分配的虚拟 IP，确保请求进入内置隧道，不被 FlClash 抢走。
  void setVpnSourceAddress(String? address) {
    final normalized = address?.trim();
    final nextAddress = normalized == null || normalized.isEmpty
        ? null
        : normalized;
    if (nextAddress == _vpnSourceAddress) return;

    // IOHttpClientAdapter 会缓存第一个 HttpClient。加速器重连后虚拟 IP 已经
    // 变化时，若继续使用旧客户端，验证码请求仍会绑定到已失效的源地址，
    // 表现为“加速器已连接但无法获取验证码”。切换源地址时重建传输层，Cookie
    // Jar 保持不变，因此不会影响同一教务会话的登录状态。
    final oldDio = _dio;
    _vpnSourceAddress = nextAddress;
    _dio = _newDio();
    oldDio.close(force: true);
  }

  HttpClient _newDirectHttpClient() {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 8);
    client.idleTimeout = const Duration(seconds: 8);
    // 教务服务器是加速器内网地址，不能把请求交给 FlClash/系统代理。
    client.findProxy = (_) => 'DIRECT';
    final sourceAddress = _vpnSourceAddress;
    final source = sourceAddress == null
        ? null
        : InternetAddress.tryParse(sourceAddress);
    if (source != null) {
      client.connectionFactory = (uri, proxyHost, proxyPort) {
        final host = proxyHost ?? uri.host;
        final port = proxyPort ?? uri.port;
        return Socket.startConnect(host, port, sourceAddress: source);
      };
    }
    return client;
  }

  void _configureDirectHttpClient(Dio client) {
    // Dio 5.x 的 Windows/Android IO 适配器公开 createHttpClient；使用
    // dynamic 保持现有多平台代码兼容，不把桌面实现暴露给 UI 层。
    (client.httpClientAdapter as dynamic).createHttpClient = () =>
        _newDirectHttpClient();
  }

  /// The school JWXT endpoint itself only exposes HTTP. Sensitive requests
  /// are therefore allowed only after the native layer has authenticated the
  /// pinned Gateway certificate and assigned a tunnel source address. The
  /// HTTP packets then travel inside that verified encrypted tunnel.
  void _requireVerifiedCampusTunnel() {
    if (_vpnSourceAddress == null) {
      throw '安全保护：未检测到经过网关身份校验的校园加速器隧道，请先重新连接加速器';
    }
  }

  String _b64(String s) => base64Encode(utf8.encode(s));

  /// 探测校园内网（172.20.63.226）是否真正可达。
  /// 返回 `true` 表示已连入加速器/校园网，可以直接走原路径；
  /// 返回 `false` 表示本机没有到教务内网的路由（多半是加速器隧道未建好）。
  ///
  /// 关键：不能只看 TCP 80 端口是否可达。
  ///   - 某些网络环境下 172.20.63.226:80 即使没建加速器也能路由到（NAT/暴露到公网等），
  ///     仅 TCP 通会被误判为"已联通"，实际访问教务页面会失败。
  ///   - 因此改成发 HTTP GET 到真实的 `/jsxsd/` 登录入口。优先检查强智教务
  ///     特征字；如果学校更换了页面模板，只要经已验证隧道收到目标服务器的
  ///     非空 HTTP 响应，也视为连通，避免把模板变化误判成断网。
  /// 探测用独立 Dio，避免污染主 _dio 的 cookie jar 和错误拦截器。
  Future<bool> checkIntranetReachable({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final probe = Dio(
      BaseOptions(
        baseUrl: _baseUrl,
        connectTimeout: timeout,
        receiveTimeout: timeout,
        sendTimeout: timeout,
        followRedirects: true,
        // 强智登录页 302 重定向到 /jsxsd/，但偶尔也会 200/403/302 混合出现。
        // 4xx 也说明已经到达目标服务器；真正的验证码请求会继续负责
        // 判断登录入口是否可用。
        validateStatus: (s) => s != null && s >= 200 && s < 500,
        headers: const {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Accept': 'text/html',
          'Accept-Language': 'zh-CN,zh;q=0.9',
        },
      ),
    );
    _configureDirectHttpClient(probe);
    try {
      final r = await probe.get<String>('/jsxsd/');
      final body = r.data ?? '';
      if (isExpectedJwxtProbeResponse(r.statusCode, body)) return true;
      // The authenticated tunnel is already bound to the virtual source IP
      // and this request uses jw.huse.cn as Host. A non-empty HTTP response
      // from that target is therefore sufficient even when the school swaps
      // the StrongSoft login template or returns a generic 4xx page.
      return r.statusCode != null &&
          r.statusCode! >= 200 &&
          r.statusCode! < 500 &&
          body.trim().isNotEmpty;
    } catch (_) {
      return false;
    } finally {
      probe.close(force: true);
    }
  }

  Future<bool> waitForIntranet({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await checkIntranetReachable(timeout: const Duration(seconds: 4))) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    return false;
  }

  /// 加速器原生层报告 connected 后，对校园内网导航站做一次无副作用的数据探测。
  ///
  /// 不调用系统 ping.exe，避免 Windows GUI 中出现 CMD 闪窗。直接请求
  /// `ns.huse.cn` 能同时验证域名解析、校园路由和实际数据通道；只有收到
  /// 非空响应数据才视为可用。探测使用独立直连客户端，不携带或污染教务 Cookie。
  Future<bool> checkCampusNameServerReachable({
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final probe = Dio(
      BaseOptions(
        baseUrl: 'http://ns.huse.cn',
        connectTimeout: timeout,
        receiveTimeout: timeout,
        sendTimeout: timeout,
        followRedirects: true,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 500,
        headers: const {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
        },
      ),
    );
    _configureDirectHttpClient(probe);
    try {
      final response = await probe.get<String>(
        '/',
        options: Options(responseType: ResponseType.plain),
      );
      final body = response.data?.trim() ?? '';
      return (response.statusCode ?? 0) >= 200 &&
          (response.statusCode ?? 0) < 500 &&
          body.isNotEmpty;
    } catch (_) {
      return false;
    } finally {
      probe.close(force: true);
    }
  }

  /// 获取验证码
  Future<Uint8List> getCaptcha() async {
    _requireVerifiedCampusTunnel();
    await _dio.get('/jsxsd/');
    final res = await _dio.get(
      '/jsxsd/verifycode.servlet',
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(res.data);
  }

  /// 建立官方“忘记密码”会话并获取该会话对应的验证码。必须先访问入口页，
  /// 否则验证码 Cookie 与后续 showAccount.do 请求可能不属于同一会话。
  Future<Uint8List> beginPasswordRecovery() async {
    _requireVerifiedCampusTunnel();
    await resetSession();
    final page = await _dio.get(
      '/jsxsd/view/findpwd/enteraccount.htmlx',
      options: Options(validateStatus: (status) => status == 200),
    );
    if (!page.data.toString().contains('/jsxsd/system/showAccount.do')) {
      throw '学校忘记密码页面暂不可用，请稍后重试';
    }
    final response = await _dio.get<List<int>>(
      '/jsxsd/verifycode.servlet?t=${DateTime.now().millisecondsSinceEpoch}',
      options: Options(
        responseType: ResponseType.bytes,
        validateStatus: (status) => status == 200,
        headers: const {
          'Referer': '$_baseUrl/jsxsd/view/findpwd/enteraccount.htmlx',
        },
      ),
    );
    final bytes = response.data;
    if (bytes == null || bytes.isEmpty) throw '获取找回密码验证码失败';
    return Uint8List.fromList(bytes);
  }

  Future<PasswordRecoveryAccountResult> verifyPasswordRecoveryAccount({
    required String studentId,
    required String captcha,
  }) async {
    _requireVerifiedCampusTunnel();
    final normalizedId = studentId.trim();
    final normalizedCaptcha = captcha.trim().toLowerCase();
    if (normalizedId.isEmpty || normalizedCaptcha.isEmpty) {
      throw '请输入学号和验证码';
    }
    final response = await _dio.post<String>(
      '/jsxsd/system/showAccount.do',
      data: {
        'account': normalizedId,
        'encoded': _b64(normalizedId),
        'RANDOMCODE': normalizedCaptcha,
      },
      options: Options(
        responseType: ResponseType.plain,
        contentType: Headers.formUrlEncodedContentType,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 500,
        headers: const {
          'Referer': '$_baseUrl/jsxsd/view/findpwd/enteraccount.htmlx',
        },
      ),
    );
    return parsePasswordRecoveryAccountPage(
      response.data ?? '',
      expectedStudentId: normalizedId,
    );
  }

  Future<PasswordRecoveryResetResult> resetPasswordWithIdentity({
    required PasswordRecoveryAccountResult account,
    required String identityNumber,
  }) async {
    _requireVerifiedCampusTunnel();
    final identity = identityNumber.trim();
    if (identity.length < 4) throw '请输入正确的身份证件号';
    final response = await _dio.post<String>(
      '/jsxsd/system/resetPasswd.do',
      data: {
        'account': account.studentId,
        'accounttype': account.accountType,
        'sfzjh': identity,
        'encoded': _b64(account.studentId),
      },
      options: Options(
        responseType: ResponseType.plain,
        contentType: Headers.formUrlEncodedContentType,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 500,
        headers: const {
          'Referer': '$_baseUrl/jsxsd/system/showAccount.do',
          'X-Requested-With': 'XMLHttpRequest',
        },
      ),
    );
    final initial = parsePasswordRecoveryResetResponse(response.data ?? '');
    if (initial.success) return initial;

    final location = response.headers.value('location')?.trim() ?? '';
    final statusCode = response.statusCode ?? 0;
    final isRedirect = statusCode >= 300 && statusCode < 400;
    if (!isRedirect || location.isEmpty) return initial;
    final absolute = Uri.tryParse(location);
    if (absolute?.hasScheme == true &&
        absolute!.host != '172.20.63.226' &&
        absolute.host.toLowerCase() != 'jw.huse.cn') {
      return initial;
    }

    // Some versions commit the reset and then redirect to a page containing
    // the actual result. Follow one same-host GET without resubmitting the ID.
    final follow = await _dio.get<String>(
      _jwxtPath(location, basePath: '/jsxsd/view/findpwd/enteraccount.htmlx'),
      options: Options(
        responseType: ResponseType.plain,
        followRedirects: false,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 500,
      ),
    );
    return parsePasswordRecoveryResetResponse(follow.data ?? '');
  }

  String _jwxtPath(String location, {String basePath = '/jsxsd/'}) {
    final trimmed = location.trim();
    if (trimmed.isEmpty) return basePath;
    final resolved = Uri.parse('$_baseUrl$basePath').resolve(trimmed);
    return resolved.hasQuery
        ? '${resolved.path}?${resolved.query}'
        : resolved.path;
  }

  Future<EducationPasswordChangeForm> _loadPasswordChangeForm(
    String location,
  ) async {
    final path = _jwxtPath(location, basePath: '/jsxsd/grsz/grsz_xgmm_beg.do');
    final response = await _dio.get<String>(
      path,
      options: Options(
        responseType: ResponseType.plain,
        validateStatus: (status) => status == 200,
      ),
    );
    final form = parseEducationPasswordChangeForm(
      response.data ?? '',
      fallbackAction: path,
    );
    if (form == null) {
      throw '教务系统要求修改密码，但无法识别学校的改密页面，请勿保存临时密码';
    }
    return form;
  }

  Future<EducationPasswordChangeResult> submitRequiredPasswordChange({
    required EducationPasswordChangeForm form,
    required String oldPassword,
    required String newPassword,
    required String confirmPassword,
    required String passwordHint,
  }) async {
    _requireVerifiedCampusTunnel();
    final validation = educationPasswordValidationError(
      oldPassword: oldPassword,
      newPassword: newPassword,
      confirmPassword: confirmPassword,
      passwordHint: passwordHint,
    );
    if (validation != null) throw validation;
    final data = <String, String>{
      ...form.hiddenFields,
      form.oldPasswordField: oldPassword,
      form.newPasswordField: newPassword,
      form.confirmPasswordField: confirmPassword,
      form.passwordHintField: passwordHint.trim(),
    };
    final path = _jwxtPath(
      form.action,
      basePath: '/jsxsd/grsz/grsz_xgmm_beg.do',
    );
    final response = await _dio.post<String>(
      path,
      data: data,
      options: Options(
        responseType: ResponseType.plain,
        followRedirects: false,
        contentType: Headers.formUrlEncodedContentType,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 500,
        headers: const {'Referer': '$_baseUrl/jsxsd/grsz/grsz_xgmm_beg.do'},
      ),
    );
    final location = response.headers.value('location') ?? '';
    final raw = response.data?.trim() ?? '';
    final result = parseEducationPasswordChangeResponse(
      statusCode: response.statusCode,
      location: location,
      raw: raw,
    );
    final isRedirect =
        response.statusCode != null &&
        response.statusCode! >= 300 &&
        response.statusCode! < 400;
    if (result.success ||
        !isRedirect ||
        location.trim().isEmpty ||
        location.contains('://')) {
      return result;
    }

    // 有些版本改密后先 302 回到改密入口，再在下一次 GET 中展示“修改成功”；
    // 只看第一跳会把已经成功的密码修改误报为失败。这里最多跟随一次跳转，
    // 不会再次提交密码，也不会对外部地址发起请求。
    final redirectPath = _jwxtPath(
      location,
      basePath: '/jsxsd/grsz/grsz_xgmm_beg.do',
    );
    final follow = await _dio.get<String>(
      redirectPath,
      options: Options(
        responseType: ResponseType.plain,
        followRedirects: false,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 500,
        headers: const {'Referer': '$_baseUrl/jsxsd/grsz/grsz_xgmm_beg.do'},
      ),
    );
    return parseEducationPasswordChangeResponse(
      statusCode: follow.statusCode,
      location: follow.headers.value('location') ?? '',
      raw: follow.data?.trim() ?? '',
    );
  }

  /// 登录
  Future<JwxtLoginResult> login(String id, String pwd, String code) async {
    _requireVerifiedCampusTunnel();
    // 教务验证码统一按小写提交，避免用户照着图片输入大写时被误判。
    final captcha = code.trim().toLowerCase();
    final logonRes = await _dio.get(
      '/Logon.do?method=logon',
      options: Options(validateStatus: (s) => true),
    );
    String ticqzket = '';
    if (logonRes.statusCode == 302 || logonRes.statusCode == 301) {
      final loc = logonRes.headers.value('location') ?? '';
      ticqzket = Uri.parse(loc).queryParameters['ticqzket'] ?? '';
    }

    var loginUrl = '/jsxsd/xk/LoginToXk?method=jwxt';
    if (ticqzket.isNotEmpty) loginUrl += '&ticqzket=$ticqzket';

    final encoded = '${_b64(id)}%%%${_b64(pwd)}';
    final res = await _dio.post(
      loginUrl,
      data: {
        'loginMethod': 'LoginToXk',
        'userAccount': id,
        'userPassword': pwd,
        'RANDOMCODE': captcha,
        'encoded': encoded,
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        validateStatus: (s) => true,
        headers: {'Referer': _baseReferer},
      ),
    );

    if (res.statusCode == 302 || res.statusCode == 301) {
      final loc = res.headers.value('location') ?? '';
      final lowerLoc = loc.toLowerCase();
      if (lowerLoc.contains('grsz_xgmm')) {
        isLoggedIn = false;
        final form = await _loadPasswordChangeForm(loc);
        return JwxtLoginResult.passwordChangeRequired(form);
      }
      if (lowerLoc.contains('framework') || lowerLoc.contains('xsmain')) {
        isLoggedIn = true;
        authenticatedStudentId = id;
        return const JwxtLoginResult.success();
      }
    }

    final html = res.data.toString();
    if (html.contains('密码过于简单') || html.contains('grsz_xgmm')) {
      isLoggedIn = false;
      final form =
          parseEducationPasswordChangeForm(html) ??
          await _loadPasswordChangeForm('/jsxsd/grsz/grsz_xgmm_beg.do');
      return JwxtLoginResult.passwordChangeRequired(form);
    }
    final errorMatch = RegExp(
      r'<font[^>]*id="showMsg"[^>]*>(.*?)</font>',
      dotAll: true,
    ).firstMatch(html);
    final errorMsg = errorMatch?.group(1)?.trim() ?? '';
    if (errorMsg.isNotEmpty) throw errorMsg.replaceAll(RegExp(r'<[^>]+>'), '');

    if (html.contains('我的桌面') ||
        html.contains('学籍成绩') ||
        html.contains('framework')) {
      isLoggedIn = true;
      authenticatedStudentId = id;
      return const JwxtLoginResult.success();
    }
    final plain = parse(html).body?.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final hint = plain == null || plain.isEmpty
        ? null
        : plain.length > 100
        ? plain.substring(0, 100)
        : plain;
    throw hint == null ? '教务登录失败：请检查教务密码和验证码' : '教务登录失败：$hint';
  }

  /// 获取课表（POST带完整表单参数）；内部委托给 fetchScheduleHtml + parseScheduleHtml
  Future<List<Map<String, String>>> getSchedule(String term) async {
    final html = await fetchScheduleHtml(term);
    final courses = parseScheduleHtml(html);
    if (courses.isEmpty) {
      final hint =
          (html.contains('登录') ||
              html.contains('login') ||
              html.contains('Logon'))
          ? '（疑似会话失效，请退出重新登录）'
          : '（未解析到课程，可能页面结构变化或本学期暂无课表）';
      throw '未查询到课程数据$hint';
    }
    return courses;
  }

  /// 仅抓取课表原始 HTML 字符串（含可能的 iframe 自动跟随），不解析。
  /// 暴露为 public 是为了让 UI 层在解析失败时把原始 HTML 保存下来用于排查。
  Future<String> fetchScheduleHtml(String term) async {
    _requireVerifiedCampusTunnel();
    // 1) 先 GET 课表页面：建立页面上下文（金智教务直接 POST 常返回空），
    //    并从表单中读取本校真实的 kbjcmsid（节次模式ID，各校不同，硬编码极易查不到课）。
    String kbjcmsid = _kbjcmsidCache ?? '8E05FF03C15B4CD7AD02FA8443BB4BF6';
    try {
      final formRes = await _dio.get(
        '/jsxsd/xskb/xskb_list.do',
        options: Options(validateStatus: (s) => true),
      );
      if (formRes.statusCode == 200) {
        final extracted = _extractKbjcmsid(formRes.data.toString());
        if (extracted != null && extracted.isNotEmpty) {
          kbjcmsid = extracted;
          _kbjcmsidCache = extracted;
        }
      }
    } catch (_) {
      // 读取失败则继续使用兜底值，不影响后续 POST
    }

    // 2) 提交查询
    final res = await _dio.post(
      '/jsxsd/xskb/xskb_list.do',
      data: {
        'xnxq01id': term,
        'zc': '',
        'kbjcmsid': kbjcmsid,
        'demo': '',
        'sfFD': '1', // 放大显示
        'wkbkc': '1', // 显示无课表课程
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        validateStatus: (s) => true,
        headers: {'Referer': '$_baseUrl/jsxsd/xskb/xskb_list.do'},
      ),
    );

    // 显式报错，避免静默吞掉
    if (res.statusCode != 200) {
      throw '课表查询返回 HTTP ${res.statusCode}（可能会话失效，请退出重新登录）';
    }

    var html = res.data.toString();

    // 3) iframe 跟随：金智教务部分版本会通过 <iframe src="..."> 内嵌真正的课表，
    //    直接 POST 返回的是一个壳页面，需要二次抓取 iframe 内容。
    try {
      final src = extractIframeSrc(html);
      if (src != null && src.isNotEmpty) {
        String path;
        if (src.startsWith('http://') || src.startsWith('https://')) {
          path = Uri.parse(src).path.isEmpty ? src : Uri.parse(src).path;
        } else if (src.startsWith('/')) {
          path = src;
        } else {
          path = '/$src';
        }
        final iframeRes = await _dio.get(
          path,
          options: Options(
            validateStatus: (s) => true,
            headers: {'Referer': '$_baseUrl/jsxsd/xskb/xskb_list.do'},
          ),
        );
        if (iframeRes.statusCode == 200) {
          html = iframeRes.data.toString();
        }
      }
    } catch (_) {
      // iframe 跟随失败不影响原始 HTML 返回
    }

    return html;
  }

  /// 从课表表单页解析默认选中的 kbjcmsid（节次模式ID）
  String? _extractKbjcmsid(String html) {
    try {
      final doc = parse(html);
      final select = doc.querySelector('select[name="kbjcmsid"]');
      if (select == null) return null;
      final selected = select.querySelector('option[selected]');
      final opt = selected ?? select.querySelector('option');
      return opt?.attributes['value']?.trim();
    } catch (_) {
      return null;
    }
  }

  /// 获取指定学期的成绩；未传参数时保留全量抓取行为，供手动刷新使用。
  Future<GradeFetchResult> getAllGrades({Iterable<String>? terms}) async {
    _requireVerifiedCampusTunnel();
    final requestedTerms = (terms ?? AcademicCalendar.terms)
        .map((term) => term.trim())
        .where((term) => term.isNotEmpty)
        .toSet()
        .toList(growable: false);

    final List<Map<String, String>> allGrades = [];
    final failedTerms = <String>[];
    final successfulTerms = <String>[];
    for (final term in requestedTerms) {
      try {
        final res = await _dio.post(
          '/jsxsd/kscj/cjcx_list',
          data: {'xnxq01id': term},
          options: Options(
            contentType: Headers.formUrlEncodedContentType,
            validateStatus: (s) => true,
          ),
        );
        final responseHtml = res.data.toString();
        // An empty data table is a valid result for a term with no grades. A
        // missing table or a non-200 response usually means the session
        // expired or the request failed, and must not overwrite old cache.
        if (res.statusCode != 200 ||
            parse(responseHtml).querySelector('#dataList') == null) {
          failedTerms.add(term);
          continue;
        }
        successfulTerms.add(term);
        final grades = _parseGradeHtml(responseHtml);
        allGrades.addAll(grades);
      } catch (_) {
        failedTerms.add(term);
      }
    }

    final seen = <String>{};
    final unique = allGrades.where((g) {
      final key = '${g['term']}-${g['code']}-${g['course']}-${g['grade']}';
      return seen.add(key);
    }).toList();

    unique.sort((a, b) => (b['term'] ?? '').compareTo(a['term'] ?? ''));
    return GradeFetchResult(
      grades: unique,
      failedTerms: failedTerms,
      successfulTerms: successfulTerms,
    );
  }

  /// 解析成绩HTML
  List<Map<String, String>> _parseGradeHtml(String html) {
    final doc = parse(html);
    final table = doc.querySelector('#dataList');
    if (table == null) return [];

    final rows = table.querySelectorAll('tr');
    final List<Map<String, String>> grades = [];

    for (var i = 1; i < rows.length; i++) {
      final cells = rows[i].querySelectorAll('td');
      if (cells.length < 10) continue;

      final course = cells.length > 3 ? cells[3].text.trim() : '';
      if (course.isEmpty) continue;

      final gradeText = cells.length > 4 ? cells[4].text.trim() : '';
      final credit = cells.length > 6 ? cells[6].text.trim() : '';
      final gpa = cells.length > 8 ? cells[8].text.trim() : '';
      final examType = cells.length > 10 ? cells[10].text.trim() : '';
      final courseType = cells.length > 13 ? cells[13].text.trim() : '';
      final term = cells.length > 1 ? cells[1].text.trim() : '';
      final code = cells.length > 2 ? cells[2].text.trim() : '';

      grades.add({
        'term': term,
        'code': code,
        'course': course,
        'grade': gradeText,
        'credit': credit,
        'gpa': gpa,
        'examType': examType,
        'courseType': courseType,
      });
    }
    return grades;
  }
}

// ==================== 课表 HTML 解析（文件级函数，便于单测） ====================

/// 检测响应 HTML 中的 <iframe src="...">（兼容单/双引号），返回 src 或 null。
/// 金智教务部分版本把课表内容嵌在 <iframe> 内，需二次抓取。
String? extractIframeSrc(String html) {
  final m = RegExp(
    r'''<iframe\b[^>]*?\bsrc\s*=\s*["']?([^"'\s>]+)''',
    caseSensitive: false,
  ).firstMatch(html);
  if (m == null) return null;
  final src = m.group(1)?.trim();
  if (src == null || src.isEmpty) return null;
  if (src.startsWith('javascript:')) return null;
  if (src == 'about:blank') return null;
  return src;
}

/// 抽取 HTML 中所有 <table>…</table> 块（含标签），用于调试导出课表结构。
List<String> extractTableBlocks(String html) {
  final re = RegExp(
    r'<table\b[^>]*>.*?</table>',
    caseSensitive: false,
    dotAll: true,
  );
  return re.allMatches(html).map((m) => m.group(0)!).toList();
}

/// 课表结构自检：返回表格数量 / id / class 以及是否存在关键标记。
/// 解析为空时打印出来，无需用户手动贴整页 HTML 即可定位结构差异。
Map<String, String> scheduleDiagnostics(String html) {
  final tableIds = RegExp(
    r'''<table\b[^>]*\bid=["']([^"']+)''',
    caseSensitive: false,
  ).allMatches(html).map((m) => m.group(1)!).toList();
  final tableClasses = RegExp(
    r'''<table\b[^>]*\bclass=["']([^"']+)''',
    caseSensitive: false,
  ).allMatches(html).map((m) => m.group(1)!).toList();
  final lower = html.toLowerCase();

  // 针对 #timetable 的细粒度诊断：行数、每行最大单元格数、课程 div 的 class 集合
  var ttRows = '(无 #timetable)';
  var ttMaxCells = '(无 #timetable)';
  var ttDivClasses = '(无 #timetable)';
  try {
    final doc = parse(html);
    final tt = doc.querySelector('#timetable');
    if (tt != null) {
      final rows = tt.querySelectorAll('tr');
      var maxCells = 0;
      final classes = <String>{};
      for (final r in rows) {
        final cells = r.querySelectorAll('td, th');
        if (cells.length > maxCells) maxCells = cells.length;
        for (final c in cells) {
          for (final d in c.querySelectorAll('div')) {
            final cls = d.attributes['class'];
            if (cls != null && cls.trim().isNotEmpty) classes.add(cls.trim());
          }
        }
      }
      ttRows = rows.length.toString();
      ttMaxCells = maxCells.toString();
      ttDivClasses = classes.isEmpty ? '(无 div)' : classes.join(' | ');
    }
  } catch (_) {}

  return {
    'htmlLength': html.length.toString(),
    'tableCount': RegExp(
      r'<table\b',
      caseSensitive: false,
    ).allMatches(html).length.toString(),
    'tableIds': tableIds.isEmpty ? '(无)' : tableIds.join(', '),
    'tableClasses': tableClasses.isEmpty ? '(无)' : tableClasses.join(', '),
    'hasKbcontent': html.contains('kbcontent') ? '是' : '否',
    'hasIframe': lower.contains('<iframe') ? '是' : '否',
    'hasWeekdayHeader':
        (html.contains('周一') || html.contains('星期') || html.contains('节次'))
        ? '是'
        : '否',
    'vendor': html.contains('强智')
        ? '强智科技'
        : (html.contains('金智') ? '金智' : '(未知)'),
    '#timetable.行数': ttRows,
    '#timetable.最大单元格数/行': ttMaxCells,
    '#timetable.divClass集合': ttDivClasses,
  };
}

/// 抽取指定 id 的 <table>…</table> 块（含标签），用于精准导出某校课表结构。
String? extractTableById(String html, String id) {
  // 先按 id 精确匹配，再抽取其完整 <table>...</table>
  // 注意：此处不能用 raw 字符串，否则 $id 不会被插值；用 RegExp.escape 防止 id 含正则特殊字符。
  final openRe = RegExp(
    '<table\\b[^>]*\\bid=["\']${RegExp.escape(id)}["\'][^>]*>',
    caseSensitive: false,
  );
  final m = openRe.firstMatch(html);
  if (m == null) return null;
  final start = m.start;
  // 从 start 起用括号计数法匹配成对的 <table>...</table>（课表通常无嵌套 table）
  final tableRe = RegExp(r'<table\b', caseSensitive: false);
  final endRe = RegExp(r'</table>', caseSensitive: false);
  var depth = 0;
  var end = start;
  var iOpen = start;
  var iClose = start;
  while (true) {
    final nextOpen = tableRe.firstMatch(html.substring(iOpen));
    final nextClose = endRe.firstMatch(html.substring(iClose));
    final o = nextOpen == null ? -1 : nextOpen.start + iOpen;
    final c = nextClose == null ? -1 : nextClose.start + iClose;
    if (c == -1) break; // 没有闭合
    if (o != -1 && o < c) {
      depth++;
      iOpen = o + 1;
    } else {
      depth--;
      iClose = c + 1;
      if (depth == 0) {
        end = c + '</table>'.length;
        break;
      }
    }
  }
  if (end <= start) return null;
  return html.substring(start, end);
}

/// 从课表的周次字段（如 "1-10(周)" / "11-12(周)[01-02节]" / "1-4,9-12(周)" / "5(周)"）
/// 解析出**所有**区间段（支持逗号分隔的多段），忽略 [01-02节] 这类节次标记。
/// 形如 "1-4,9-12(周)" 会返回 [{1..4},{9..12}]；无法识别则返回空列表。
/// 所有需要判断"某课程在第几周有课"的地方（筛选 / 高亮 / 冲突判定）都必须用它，
/// 避免只看首段导致"第11周仍显示1-10周课程""漏报多段冲突"等口径不一致的 bug。
List<Map<String, int>> parseWeekSpans(String weeks) {
  final clean = _cleanWeeks(weeks).replaceAll(RegExp(r'[^\d,\-]'), '');
  final result = <Map<String, int>>[];
  for (final part in clean.split(',')) {
    final t = part.trim();
    if (t.isEmpty) continue;
    if (t.contains('-')) {
      final nums = t
          .split('-')
          .map((e) => int.tryParse(e.trim()) ?? 0)
          .toList();
      if (nums.length == 2) result.add({'start': nums[0], 'end': nums[1]});
    } else {
      final n = int.tryParse(t);
      if (n != null) result.add({'start': n, 'end': n});
    }
  }
  return result;
}

/// 判断两个周次区间列表是否相交（用于冲突判定）。
bool weekSpansOverlap(List<Map<String, int>> a, List<Map<String, int>> b) {
  for (final x in a) {
    for (final y in b) {
      if (x['start']! <= y['end']! && y['start']! <= x['end']!) return true;
    }
  }
  return false;
}

/// 解析课表HTML
///
/// 强智科技系统里，**每一门课会出现在两个 div 中**：
///   - `kbcontent1`（名称卡）：含 课程名 + 教室 + 周次
///   - `kbcontent` （详情卡）：含 课程名 + 教师 + 周次[带节次]
/// 两个卡是一一对应的。若把它们都当独立课程处理，会产生重复，且
/// 教师 / 教室被拆到两条记录里。正确做法：先从详情卡建
/// `(课程名|周次)->教师` 映射，再只从名称卡生成课程并补上教师。
List<Map<String, String>> parseScheduleHtml(String html) {
  final doc = parse(html);
  // 兼容不同页面结构：优先 #timetable，其次常见 id，最后兜底取首个表格
  var table = doc.querySelector('#timetable');
  table ??= doc.querySelector('table#kbgrid');
  table ??= doc.querySelector('table.table');

  final List<Map<String, String>> courses = [];
  if (table == null) return courses;

  // —— Pass 1：从 kbcontent（详情卡，含教师）建立 (课程名|周次) -> 教师 映射 ——
  // 强智系统里教师/教室/周次都在「详情卡」kbcontent 中，且该卡默认 display:none（隐藏，
  // 仅用于弹窗/悬停）。因此这里【不能】跳过 display:none 的 div，否则教师永远为空。
  // 注意：真实 HTML 的 title 属性用单引号（title='教师'），正则需兼容单/双引号。
  final teacherMap = <String, String>{};
  for (final div in table.querySelectorAll('div')) {
    final cls = div.attributes['class'] ?? '';
    if (!cls.contains('kbcontent') || cls.contains('kbcontent1')) {
      continue; // 只看详情卡（含隐藏的）
    }
    for (final raw in _splitCourseBlocks(div.innerHtml)) {
      // 去掉分隔线后可能残留的首个 <br>，否则课程名会解析为空
      final block = raw.replaceFirst(RegExp(r'^<br\s*/?>'), '');
      final name = _extractCourseName(block);
      if (name.isEmpty) continue;
      final weeks = _extractWeeks(block);
      final clean = _cleanWeeks(weeks);
      if (clean.isEmpty) continue;
      final t = _extractTeacher(block); // 同名同周次取最后非空教师
      if (t.isNotEmpty) teacherMap['$name|$clean'] = t;
    }
  }

  // —— Pass 2：从 kbcontent1（名称卡）生成课程，并补上教师 ——
  final rows = table.querySelectorAll('tr');
  const dayNames = ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  // 强智"节次"列常用 rowspan 合并：被合并的后续行在 DOM 里只有 7 个 <td>（时间格被"借用"但没写 <td>）。
  // 因此不能硬性要求 >=8 格，否则这些行会被整行跳过、课程全丢。
  String lastTimeSlot = '';
  for (var i = 1; i < rows.length; i++) {
    final cells = rows[i].querySelectorAll('td, th');
    if (cells.isEmpty) continue;

    String timeSlot;
    final dayCells = (cells.length >= 8)
        ? cells.sublist(1, 8) // 周一..周日
        : cells.take(7).toList(); // 时间格被 rowspan 合并掉，整行都是星期列

    if (cells.length >= 8) {
      timeSlot = cells[0].text.trim().replaceAll(RegExp(r'\s+'), ' ');
      lastTimeSlot = timeSlot;
    } else {
      timeSlot = lastTimeSlot;
    }

    var day = 1;
    for (final cell in dayCells) {
      final divs = cell.querySelectorAll('div');

      for (final div in divs) {
        final cls = div.attributes['class'] ?? '';
        if (!cls.contains('kbcontent')) continue; // 只处理课表卡

        final style = div.attributes['style'] ?? '';
        final hidden =
            style.contains('display:none') || style.contains('display: none');
        final isNameCard = cls.contains('kbcontent1');

        // 隐藏的详情卡（display:none）只用于 Pass1 建教师映射，这里跳过，避免重复生成课程。
        if (!isNameCard && hidden) continue;

        final rawHtml = div.innerHtml.trim();
        if (rawHtml.isEmpty || rawHtml == '&nbsp;') continue;

        for (var block in _splitCourseBlocks(rawHtml)) {
          block = block.replaceFirst(RegExp(r'^<br\s*/?>'), '');

          // 课程名位于第一个 <br>/<font> 之前，兼容 <span> 包裹。
          final baseName = _extractCourseName(block);
          if (baseName.isEmpty || baseName == '&nbsp;') continue;

          // 追加分组/类型后缀，如 "(分组03)"、"(足球)"
          var courseName = baseName;
          final groupMatch = RegExp(
            r'<br>\s*(\([^)]+\))(?:\s*<br>|$)',
          ).firstMatch(block);
          if (groupMatch != null &&
              !block.substring(0, groupMatch.end).contains('title=')) {
            courseName += ' ${groupMatch.group(1)}';
          }

          final room = _extractRoom(block);
          final weeks = _extractWeeks(block);
          final clean = _cleanWeeks(weeks);
          // 名称卡教师优先取 Pass1 详情卡映射，取不到再尝试直接从名称卡读；
          // 可见详情卡直接读取教师。
          final teacher = isNameCard
              ? (teacherMap['$baseName|$clean'] ?? _extractTeacher(block))
              : _extractTeacher(block);

          courses.add({
            'day': dayNames[day],
            'time': timeSlot,
            'name': courseName,
            'teacher': teacher,
            'room': room,
            'weeks': weeks,
          });
        }
      }
      day++;
    }
  }
  return courses;
}

/// 按课程分隔线（连续 5 个以上短横）切分同一单元格内的多门课程。
/// 强智系统用 `----------------------` 之类分隔，故用正则而非固定字符串。
List<String> _splitCourseBlocks(String html) => html
    .split(RegExp(r'-{5,}'))
    .map((b) => b.trim())
    .where((b) => b.isNotEmpty)
    .toList();

String _extractTeacher(String block) {
  // 真实 HTML 用单引号：title='教师'；这里兼容单/双引号。
  // 真实 HTML 用单引号 title='教师'；用十六进制转义 \x27(单引号) \x22(双引号) 兼容两种引号，
  // 避免把引号直接写进原始字符串导致 Dart 字符串提前结束。
  final m = RegExp(
    r"<font[^>]*title=[\x27\x22]教师[\x27\x22][^>]*>(.*?)</font>",
    caseSensitive: false,
  ).firstMatch(block);
  return m?.group(1)?.trim() ?? '';
}

String _extractRoom(String block) {
  final m = RegExp(
    r"<font[^>]*title=[\x27\x22]教室[\x27\x22][^>]*>(.*?)</font>",
    caseSensitive: false,
  ).firstMatch(block);
  return m?.group(1)?.trim() ?? '';
}

String _extractWeeks(String block) {
  final m = RegExp(
    r"<font[^>]*title=[\x27\x22]周次\(节次\)[\x27\x22][^>]*>(.*?)</font>",
    caseSensitive: false,
  ).firstMatch(block);
  return m?.group(1)?.trim() ?? '';
}

/// 去掉周次里的节次标注，如 "1-10(周)[01-02节]" -> "1-10(周)"，便于做匹配键。
String _cleanWeeks(String weeks) =>
    weeks.replaceAll(RegExp(r'\[[^\]]*\]'), '').trim();

/// 判断某周是否落在课程周次区间内（支持逗号分隔的多段，如 "1-4,6-12(周)"）。
bool weekInWeeks(String weeks, int week) {
  final clean = _cleanWeeks(weeks).replaceAll(RegExp(r'[^\d,\-]'), '');
  for (final part in clean.split(',')) {
    final t = part.trim();
    if (t.isEmpty) continue;
    if (t.contains('-')) {
      final nums = t
          .split('-')
          .map((e) => int.tryParse(e.trim()) ?? 0)
          .toList();
      if (nums.length == 2 && week >= nums[0] && week <= nums[1]) return true;
    } else {
      final n = int.tryParse(t);
      if (n != null && n == week) return true;
    }
  }
  return false;
}

/// 从单个课程块中提取课程名：取第一个 `<br>`/`<font>` 之前的文本，
/// 兼容 `<span>高等数学</span>` 这类包裹写法。
String _extractCourseName(String block) {
  final lower = block.toLowerCase();
  final iBr = lower.indexOf('<br');
  final iFont = lower.indexOf('<font');
  int end;
  if (iBr == -1 && iFont == -1) {
    end = block.length;
  } else if (iBr == -1) {
    end = iFont;
  } else if (iFont == -1) {
    end = iBr;
  } else {
    end = iBr < iFont ? iBr : iFont;
  }
  final head = block.substring(0, end);
  return parse(head).body?.text.trim() ?? '';
}

// ==================== 学年日期（作者手动维护） ====================
/// 教务系统的学年选项和开课日期由作者手动维护，不从校园网额外探测。
///
/// 每个学期按 20 周显示周次；如果学校调整开课日期，只需要修改这里，
/// 不需要改动课表页面的查询逻辑。当前日期由 DateTime.now() 在本机读取。
class AcademicCalendar {
  AcademicCalendar._();

  static const int weeksPerAcademicYear = 20;

  // 新学年发布后，作者手动把最新学期放在第一项并更新 latestTerm。
  static const String latestTerm = '2026-2027-1';
  static final DateTime latestTermQueryDate = DateTime(2026, 9, 1);

  static const List<String> terms = [
    latestTerm,
    '2025-2026-2',
    '2025-2026-1',
    '2024-2025-2',
    '2024-2025-1',
    '2023-2024-2',
    '2023-2024-1',
  ];

  // 这些日期仅作为作者维护记录，暂不强制覆盖设置页的手动周次选择。
  static final Map<String, DateTime> termStartDates = {
    '2026-2027-1': DateTime(2026, 9, 1),
    '2025-2026-2': DateTime(2026, 3, 1),
    '2025-2026-1': DateTime(2025, 9, 1),
    '2024-2025-2': DateTime(2025, 3, 1),
    '2024-2025-1': DateTime(2024, 9, 1),
    '2023-2024-2': DateTime(2024, 3, 1),
    '2023-2024-1': DateTime(2023, 9, 1),
  };

  static bool isBeforeLatestTermQueryDate(DateTime now) =>
      now.isBefore(latestTermQueryDate);

  /// 返回已经开始的、按学期列表顺序排列的第一个学期。
  ///
  /// [latestTerm] 可能会在新学期开始前提前写入配置；成绩快速同步不能在
  /// 这个时间点查询一个尚未开放的学期，否则会漏掉当前仍在展示成绩的学期。
  static String get latestAvailableTerm {
    final now = DateTime.now();
    for (final term in terms) {
      final start = termStartDates[term];
      if (start == null || !start.isAfter(now)) return term;
    }
    return terms.first;
  }
}

class OfflineSyncResult {
  final int savedTermCount;
  final int gradeCount;
  final List<String> failedTerms;
  final List<String> failedGradeTerms;
  final bool gradesUpdated;
  final bool schedulesUpdated;
  final bool schedulesSkipped;
  final bool schedulesFetchedAll;
  final bool gradesFetchedAll;

  const OfflineSyncResult({
    required this.savedTermCount,
    required this.gradeCount,
    required this.failedTerms,
    required this.failedGradeTerms,
    required this.gradesUpdated,
    required this.schedulesUpdated,
    required this.schedulesSkipped,
    this.schedulesFetchedAll = false,
    this.gradesFetchedAll = false,
  });
}

/// 教务认证成功后同步离线数据。
///
/// 首次认证会把所有配置学期中能成功返回的课表和成绩都写入本地；
/// 已有本地快照后，普通登录只更新最新成绩，手动更新则可指定一个学期，
/// 或通过 [GradeSyncScope.all] 查询全部成绩。课表首次全量抓取后不再删除
/// 其它学期文件，指定学期更新也只替换对应缓存。
/// 主页只读取这里写下来的本地静态文件，不会因为切换课表或成绩页面再次
/// 访问校园网。
Future<OfflineSyncResult> syncOfflineUserData({
  required String studentId,
  void Function(String message)? onProgress,
  GradeSyncScope gradeSyncScope = GradeSyncScope.latest,
  bool syncSchedules = true,
  bool forceScheduleSync = false,
  bool fetchAllSchedules = false,
  String? scheduleTerm,
  String? gradeTerm,
  bool syncGrades = true,
}) async {
  final client = JwxtClient();
  final htmlByTerm = <String, String>{};
  final failedTerms = <String>[];
  final terms = AcademicCalendar.terms;
  final hadScheduleBefore = await _hasLocalSchedule(studentId);
  final hadGradesBefore = await _hasLocalGrades(studentId);
  final normalizedScheduleTerm = scheduleTerm?.trim();
  final normalizedGradeTerm = gradeTerm?.trim();
  final shouldSyncSchedules =
      syncSchedules &&
      (forceScheduleSync ||
          fetchAllSchedules ||
          normalizedScheduleTerm?.isNotEmpty == true ||
          !hadScheduleBefore);
  final schedulesFetchedAll =
      shouldSyncSchedules &&
      (fetchAllSchedules ||
          (!hadScheduleBefore && normalizedScheduleTerm?.isNotEmpty != true));
  final scheduleQueryTerms = normalizedScheduleTerm?.isNotEmpty == true
      ? <String>[normalizedScheduleTerm!]
      : terms;
  final gradeQueryTerms = normalizedGradeTerm?.isNotEmpty == true
      ? <String>[normalizedGradeTerm!]
      : (gradeSyncScope == GradeSyncScope.all || !hadGradesBefore)
      ? terms
      : <String>[AcademicCalendar.latestAvailableTerm];
  final gradesFetchedAll =
      syncGrades &&
      normalizedGradeTerm?.isNotEmpty != true &&
      (gradeSyncScope == GradeSyncScope.all || !hadGradesBefore);

  final resourcesToSync = <SyncResource>[
    if (shouldSyncSchedules) SyncResource.schedule,
    if (syncGrades) SyncResource.grade,
  ];
  if (!dataSyncCooldown.tryStartAll(resourcesToSync)) {
    final blocked = resourcesToSync.firstWhere(
      dataSyncCooldown.isCooling,
      orElse: () => SyncResource.schedule,
    );
    final label = blocked == SyncResource.schedule ? '课表' : '成绩';
    throw '$label更新冷却中，还需 ${dataSyncCooldown.remainingText(blocked)} 后重试';
  }

  if (shouldSyncSchedules) {
    // 首次认证查询所有配置学期；普通/手动“最新”更新按新旧顺序回退，
    // 新学期未发布时继续尝试第二新的已发布课表；指定学期只查那一学期。
    for (var index = 0; index < scheduleQueryTerms.length; index++) {
      final term = scheduleQueryTerms[index];
      onProgress?.call(
        schedulesFetchedAll
            ? '正在获取课表 ${index + 1}/${scheduleQueryTerms.length}：$term'
            : '正在查找最新课表：$term',
      );
      try {
        final html = await client
            .fetchScheduleHtml(term)
            .timeout(const Duration(seconds: 30));
        if (html.trim().isEmpty) throw '课表响应为空';
        if (parseScheduleHtml(html).isEmpty) {
          // 空表通常表示该学期尚未发布；继续尝试第二新学期。
          continue;
        }
        htmlByTerm[term] = html;
        if (!schedulesFetchedAll) break;
      } catch (_) {
        failedTerms.add(term);
      }
    }
  }

  GradeFetchResult gradeResult;
  if (syncGrades) {
    final gradeTerms = gradeQueryTerms;
    onProgress?.call(
      gradesFetchedAll
          ? '正在更新全部学期成绩…'
          : normalizedGradeTerm?.isNotEmpty == true
          ? '正在更新成绩：$normalizedGradeTerm…'
          : '正在更新最新学期成绩…',
    );
    try {
      gradeResult = await client
          .getAllGrades(terms: gradeTerms)
          .timeout(const Duration(minutes: 2));
    } catch (_) {
      gradeResult = GradeFetchResult(
        grades: const [],
        failedTerms: List<String>.from(gradeTerms),
      );
    }
  } else {
    gradeResult = const GradeFetchResult(
      grades: [],
      failedTerms: [],
      successfulTerms: [],
    );
  }
  if (htmlByTerm.isEmpty &&
      gradeResult.successfulTerms.isEmpty &&
      !hadScheduleBefore &&
      !hadGradesBefore) {
    throw '教务认证成功，但未能获取可保存的课表或成绩，请稍后重新连接更新';
  }

  if (htmlByTerm.isNotEmpty || gradeResult.successfulTerms.isNotEmpty) {
    onProgress?.call('正在写入本地离线主页…');
  }
  await UserDataCacheStore.saveSnapshot(
    studentId: studentId,
    scheduleHtmlByTerm: htmlByTerm,
    grades: gradeResult.grades,
    replaceGrades: syncGrades && gradesFetchedAll && gradeResult.isComplete,
    replaceGradeTerms: gradeResult.successfulTerms,
    replaceSchedules: false,
  );
  return OfflineSyncResult(
    savedTermCount: htmlByTerm.length,
    gradeCount: gradeResult.grades.length,
    failedTerms: failedTerms,
    failedGradeTerms: gradeResult.failedTerms,
    gradesUpdated: syncGrades && gradeResult.isComplete,
    schedulesUpdated: htmlByTerm.isNotEmpty,
    schedulesSkipped: syncSchedules && !shouldSyncSchedules,
    schedulesFetchedAll: schedulesFetchedAll,
    gradesFetchedAll: gradesFetchedAll,
  );
}

/// 判断当前账号是否已经有可展示的课表。兼容早期版本的单学期缓存，
/// 这样普通登录不会因为升级后找不到 profile 而重复抓取全部课表。
Future<bool> _hasLocalSchedule(String studentId) async {
  final profile = await UserDataCacheStore.loadProfile(studentId);
  if (profile != null && profile.scheduleTerms.isNotEmpty) return true;
  return await ScheduleCacheStore.loadLatest(studentId) != null;
}

Future<bool> _hasLocalGrades(String studentId) async {
  final profile = await UserDataCacheStore.loadProfile(studentId);
  if (profile?.hasGrades == true) return true;
  return (await UserDataCacheStore.loadGrades(studentId)).isNotEmpty;
}

// ==================== 设置持久化（本地文件，全程无云端） ====================

/// 应用设置，全部写到本地的 settings.json，绝不联网（符合"隐私本地化"硬要求）。
///
/// —— 课表设置 ——
/// - [highlightCurrentWeek]：本周视图——在课表中高亮"当前周"有课的课程。
/// - [filterByWeek]：按周筛选——只显示所选周次有课的课程，其它周隐藏。默认开启。
/// - [currentWeek]：手动选定的周次（1~20）。学校开课日期由作者维护，但仍允许手动调整，
///   本周视图高亮与按周筛选都以它为准。
///
/// —— 成绩设置 ——
/// - [gradeCategoryEnabled]：是否启用"已完成 / 历史补考·重修"分类（关闭则所有课混在一组）。
/// - [gradeSortByYear]：按开课时间（学年）排序，以更大学年为顶，倒序展示。
/// - [gradeTermFilterEnabled]：是否显示成绩学期筛选器，默认开启。
class AppSettings {
  bool highlightCurrentWeek;
  bool filterByWeek;
  int currentWeek;
  bool gradeCategoryEnabled;
  bool gradeSortByYear;
  bool gradeTermFilterEnabled;

  AppSettings({
    this.highlightCurrentWeek = false,
    this.filterByWeek = true,
    this.currentWeek = 1,
    this.gradeCategoryEnabled = true,
    this.gradeSortByYear = true,
    this.gradeTermFilterEnabled = true,
  });

  static const _fileName = 'jizhicha_settings.json';
  // schemaVersion 仅用于老版本 settings.json 的字段迁移；当前版本无加速器字段。
  static const _schemaVersion = 5;

  /// 配置文件路径：优先用系统用户目录（Windows %APPDATA%），保证桌面端可写且稳定；
  /// 移动端没有这些环境变量，要回退到平台沙盒目录，否则会落到只读根目录。
  static Future<File> _file() async {
    final Directory folder;
    if (Platform.isWindows) {
      final base =
          Platform.environment['APPDATA'] ??
          Platform.environment['HOME'] ??
          Directory.current.path;
      folder = Directory(base);
    } else {
      // Android / Linux 使用 path_provider 提供的应用文档目录，
      // 避免 FileSystemException: Creation failed '/...' (OS Error: Read-only file system)。
      final dir = await getApplicationDocumentsDirectory();
      folder = dir;
    }
    try {
      if (!await folder.exists()) await folder.create(recursive: true);
    } catch (_) {}
    return File('${folder.path}${Platform.pathSeparator}$_fileName');
  }

  static Future<AppSettings> load() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final version = json['_v'] as int? ?? 1;
        if (version < _schemaVersion) {
          // 老版本文件：保留旧的课表/成绩字段，加速器三项按当前默认。
          return AppSettings(
            highlightCurrentWeek:
                json['highlightCurrentWeek'] as bool? ?? false,
            filterByWeek: version >= 2
                ? (json['filterByWeek'] as bool? ?? true)
                : true,
            currentWeek: json['currentWeek'] as int? ?? 1,
            gradeCategoryEnabled: json['gradeCategoryEnabled'] as bool? ?? true,
            gradeSortByYear: json['gradeSortByYear'] as bool? ?? true,
            gradeTermFilterEnabled:
                json['gradeTermFilterEnabled'] as bool? ?? true,
          );
        }
        return AppSettings(
          highlightCurrentWeek: json['highlightCurrentWeek'] as bool? ?? false,
          filterByWeek: json['filterByWeek'] as bool? ?? true,
          currentWeek: json['currentWeek'] as int? ?? 1,
          gradeCategoryEnabled: json['gradeCategoryEnabled'] as bool? ?? true,
          gradeSortByYear: json['gradeSortByYear'] as bool? ?? true,
          gradeTermFilterEnabled:
              json['gradeTermFilterEnabled'] as bool? ?? true,
        );
      }
    } catch (_) {}
    return AppSettings();
  }

  Future<void> save() async {
    try {
      final f = await _file();
      await f.writeAsString(
        jsonEncode({
          '_v': _schemaVersion,
          'highlightCurrentWeek': highlightCurrentWeek,
          'filterByWeek': filterByWeek,
          'currentWeek': currentWeek,
          'gradeCategoryEnabled': gradeCategoryEnabled,
          'gradeSortByYear': gradeSortByYear,
          'gradeTermFilterEnabled': gradeTermFilterEnabled,
        }),
      );
    } catch (_) {}
  }
}

/// 首页的页面栈会保留课表、成绩与设置页各自的 State。设置写入本地文件后，
/// 通过统一修订号通知其它仍在内存中的页面立即重新读取，避免必须重启或重新登录。
final ValueNotifier<int> _appSettingsRevision = ValueNotifier<int>(0);

String _acceleratorText(Object value) {
  final text = '$value';
  if (text.toLowerCase().contains('spki pin mismatch')) {
    return '加速器网关身份验证失败：服务器证书与应用内置安全指纹不一致。'
        '为保护账号密码，连接已中止，请联系作者核对网关证书。';
  }
  return text.replaceAll(RegExp('vpn', caseSensitive: false), '加速器');
}

void _notifyAppSettingsChanged() {
  _appSettingsRevision.value += 1;
}

// ==================== 登录页 ====================
// ==================== Embedded Campus Accelerator ====================
/// The accelerator is part of this Flutter application through Dart FFI.
/// No standalone accelerator executable or local control API is used.

typedef _ConnectNative =
    ffi.Int32 Function(
      ffi.Pointer<ffi_utils.Utf8>,
      ffi.Pointer<ffi_utils.Utf8>,
      ffi.Pointer<ffi_utils.Utf8>,
    );
typedef _ConnectDart =
    int Function(
      ffi.Pointer<ffi_utils.Utf8>,
      ffi.Pointer<ffi_utils.Utf8>,
      ffi.Pointer<ffi_utils.Utf8>,
    );
typedef _DisconnectNative = ffi.Int32 Function();
typedef _DisconnectDart = int Function();
typedef _ShutdownNative = ffi.Void Function();
typedef _ShutdownDart = void Function();
typedef _StatusNative = ffi.Pointer<ffi_utils.Utf8> Function();
typedef _StatusDart = ffi.Pointer<ffi_utils.Utf8> Function();
typedef _FreeStringNative = ffi.Void Function(ffi.Pointer<ffi_utils.Utf8>);
typedef _FreeStringDart = void Function(ffi.Pointer<ffi_utils.Utf8>);

class _EmbeddedVpnBindings {
  static const _androidChannel = MethodChannel('com.one.huaji/android_vpn');
  ffi.DynamicLibrary? _library;
  _ConnectDart? _connect;
  _DisconnectDart? _disconnect;
  _ShutdownDart? _shutdown;
  _StatusDart? _status;
  _FreeStringDart? _freeString;

  void ensureLoaded() {
    if (_library != null) return;
    if (Platform.isAndroid) return;
    if (!Platform.isWindows) {
      throw '内置校园加速器当前仅支持 Windows，手机端需要接入系统网络隧道实现';
    }
    final libraryPath = File(
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}huse_vpn_ffi.dll',
    ).path;
    final library = ffi.DynamicLibrary.open(libraryPath);
    _library = library;
    _connect = library.lookupFunction<_ConnectNative, _ConnectDart>(
      'huse_vpn_connect',
    );
    _disconnect = library.lookupFunction<_DisconnectNative, _DisconnectDart>(
      'huse_vpn_disconnect',
    );
    _shutdown = library.lookupFunction<_ShutdownNative, _ShutdownDart>(
      'huse_vpn_shutdown',
    );
    _status = library.lookupFunction<_StatusNative, _StatusDart>(
      'huse_vpn_status_json',
    );
    _freeString = library.lookupFunction<_FreeStringNative, _FreeStringDart>(
      'huse_vpn_free_string',
    );
  }

  Future<bool> androidPrepare() async {
    if (!Platform.isAndroid) return true;
    return await _androidChannel.invokeMethod<bool>('prepare') ?? false;
  }

  Future<void> androidConnect({
    required String username,
    required String password,
    required String authSource,
  }) async {
    await _androidChannel.invokeMethod<void>('connect', {
      'username': username,
      'password': password,
      'authSource': authSource,
    });
  }

  Future<Map<String, dynamic>> androidStatus() async {
    final value = await _androidChannel.invokeMethod<String>('status');
    if (value == null || value.isEmpty) throw 'Android 加速器状态为空';
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic>) throw 'Android 加速器状态格式错误';
    return decoded;
  }

  Future<void> androidDisconnect() async {
    await _androidChannel.invokeMethod<void>('disconnect');
  }

  int connect(
    ffi.Pointer<ffi_utils.Utf8> username,
    ffi.Pointer<ffi_utils.Utf8> password,
    ffi.Pointer<ffi_utils.Utf8> authSource,
  ) {
    ensureLoaded();
    return _connect!(username, password, authSource);
  }

  int disconnect() {
    ensureLoaded();
    return _disconnect!();
  }

  /// Synchronously release the native tunnel before the desktop process exits.
  /// Do not load the DLL solely for shutdown when the accelerator was never used.
  void shutdown() {
    _shutdown?.call();
  }

  Map<String, dynamic> status() {
    ensureLoaded();
    final pointer = _status!();
    try {
      if (pointer.address == 0) throw '加速器状态接口返回为空';
      final decoded = jsonDecode(pointer.toDartString());
      if (decoded is! Map<String, dynamic>) throw '加速器状态接口返回格式错误';
      return decoded;
    } finally {
      _freeString!(pointer);
    }
  }
}

class CampusVpnLauncher {
  static final _EmbeddedVpnBindings _bindings = _EmbeddedVpnBindings();

  static void shutdownNow() {
    if (Platform.isWindows) _bindings.shutdown();
  }

  Future<void> start() async => _bindings.ensureLoaded();

  bool _isWintunCleanupFailure(Object error) {
    final message = '$error'.toLowerCase();
    return message.contains('wintunstartsession failed') ||
        message.contains('failed to create wintun adapter');
  }

  bool _isTransientWindowsFailure(Object error) {
    final message = '$error'.toLowerCase();
    return _isWintunCleanupFailure(error) ||
        message.contains('no physical ipv4 default route') ||
        message.contains('0x020004ab');
  }

  /// 获取当前隧道状态。读取失败时视为未连接，避免状态接口异常阻断页面跳转。
  Future<Map<String, dynamic>?> currentStatus() async {
    try {
      if (Platform.isAndroid) return await _bindings.androidStatus();
      if (Platform.isWindows) return _bindings.status();
    } catch (_) {
      // 状态接口只用于优化重入流程，失败时由正常连接流程继续处理。
    }
    return null;
  }

  Future<void> _connectWindowsOnce({
    required String username,
    required String password,
    String? authSource,
    void Function(String message)? onProgress,
  }) async {
    final userPointer = username.toNativeUtf8();
    final passwordPointer = password.toNativeUtf8();
    final sourcePointer = (authSource ?? 'SAM-all').toNativeUtf8();
    try {
      final result = _bindings.connect(
        userPointer,
        passwordPointer,
        sourcePointer,
      );
      if (result != 0) throw '内置加速器参数无效';
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      Object? lastError;
      String? lastStage;
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 350));
        final status = _bindings.status();
        lastStage = status['stage']?.toString();
        final message = status['message']?.toString();
        if (message != null && message.isNotEmpty) onProgress?.call(message);
        if (status['connected'] == true) {
          // 隧道刚标记 connected 时，原生层有时还没把虚拟 IP 填进 status。
          // 探测 HttpClient 必须绑定这个虚拟 IP 才能避开 FlClash TUN，
          // 因此再短轮询一段，直到拿到非空值。最多 2.5 秒；
          // 2.5 秒后仍为空视为配置异常，回落到断开重建。
          var virtualIp = status['virtual_ip']?.toString();
          var attempts = 0;
          while ((virtualIp == null || virtualIp.isEmpty) && attempts < 5) {
            attempts += 1;
            await Future<void>.delayed(const Duration(milliseconds: 500));
            // This is the Windows branch.  Calling the Android method here
            // leaves the desktop build waiting on a channel that does not
            // exist, even though the native tunnel is already connected.
            virtualIp = _bindings.status()['virtual_ip']?.toString();
          }
          if (virtualIp == null || virtualIp.isEmpty) {
            throw '加速器已连接但虚拟 IP 未下发，请重试';
          }
          JwxtClient().setVpnSourceAddress(virtualIp);
          return;
        }
        final error = status['error']?.toString();
        if (error != null && error.isNotEmpty) {
          lastError = error;
          final stage = status['stage']?.toString() ?? '';
          if (stage.endsWith('_error') ||
              stage == 'ffi_error' ||
              stage == 'tunnel_stopped') {
            throw error;
          }
        }
      }
      throw lastError ?? '校园加速器连接超时（当前阶段：${lastStage ?? '未知'}，请重试）';
    } finally {
      ffi_utils.calloc.free(userPointer);
      ffi_utils.calloc.free(passwordPointer);
      ffi_utils.calloc.free(sourcePointer);
    }
  }

  Future<void> connect({
    required String username,
    required String password,
    String? authSource,
    void Function(String message)? onProgress,
  }) async {
    if (Platform.isAndroid) {
      final prepared = await _bindings.androidPrepare();
      if (!prepared) {
        throw '请在 Android 系统网络授权对话框中允许稽之查，然后再次点击连接';
      }
      await _bindings.androidConnect(
        username: username,
        password: password,
        authSource: authSource ?? 'SAM-all',
      );
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      Object? lastError;
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 350));
        final status = await _bindings.androidStatus();
        final message = status['message']?.toString();
        if (message != null && message.isNotEmpty) onProgress?.call(message);
        if (status['connected'] == true) {
          // 隧道刚标记 connected 时，原生层有时还没把虚拟 IP 填进 status。
          // 探测 HttpClient 必须绑定这个虚拟 IP 才能避开 FlClash TUN，
          // 因此再短轮询一段，直到拿到非空值。最多 2.5 秒；
          // 2.5 秒后仍为空视为配置异常，回落到断开重建。
          var virtualIp = status['virtual_ip']?.toString();
          var attempts = 0;
          while ((virtualIp == null || virtualIp.isEmpty) && attempts < 5) {
            attempts += 1;
            await Future<void>.delayed(const Duration(milliseconds: 500));
            virtualIp = _bindings.status()['virtual_ip']?.toString();
          }
          if (virtualIp == null || virtualIp.isEmpty) {
            throw '加速器已连接但虚拟 IP 未下发，请重试';
          }
          JwxtClient().setVpnSourceAddress(virtualIp);
          return;
        }
        final error = status['error']?.toString();
        if (error != null && error.isNotEmpty) {
          lastError = error;
          final stage = status['stage']?.toString() ?? '';
          if (stage.endsWith('_error') || stage == 'tunnel_stopped') {
            throw error;
          }
        }
      }
      throw lastError ?? '校园加速器连接超时';
    }
    try {
      await _connectWindowsOnce(
        username: username,
        password: password,
        authSource: authSource,
        onProgress: onProgress,
      );
    } catch (firstError) {
      if (!_isTransientWindowsFailure(firstError)) rethrow;

      // 非正常退出时，Wintun 的会话和学校网关会短暂处于清理状态。此前
      // disconnect() 只等待 connected=false，可能在原生任务尚未真正释放
      // 适配器前就再次发起连接，进而出现 WintunStartSession failed。
      // 现在等待 Rust 侧状态回到 idle 后再重试；Wintun 类错误多给一次
      // 清理机会，真实密码错误则不会进入这个分支。
      Object lastError = firstError;
      final retryCount = _isWintunCleanupFailure(firstError) ? 2 : 1;
      for (var retry = 0; retry < retryCount; retry++) {
        onProgress?.call('正在清理上次加速器会话，请稍候…');
        try {
          await disconnect();
        } catch (_) {
          // 后续连接仍会给出最终明确错误；此处不因清理接口本身中断重试。
        }
        await Future<void>.delayed(
          Duration(milliseconds: retry == 0 ? 1800 : 3200),
        );
        try {
          await _connectWindowsOnce(
            username: username,
            password: password,
            authSource: authSource,
            onProgress: onProgress,
          );
          return;
        } catch (error) {
          lastError = error;
          if (!_isTransientWindowsFailure(error)) rethrow;
        }
      }

      // 仍无法创建会话时，向用户解释为可操作的信息，而不暴露 Wintun
      // 内部错误。下一次认证会使用已经完成清理的适配器状态。
      if (_isWintunCleanupFailure(lastError)) {
        throw '上次没有正常下线，请再认证一次';
      }
      throw lastError;
    }
  }

  Future<void> disconnect() async {
    try {
      if (Platform.isAndroid) {
        await _bindings.androidDisconnect();
        return;
      }
      if (!Platform.isWindows) return;
      final result = _bindings.disconnect();
      if (result != 0) return;
      final deadline = DateTime.now().add(const Duration(seconds: 12));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        final status = _bindings.status();
        // Rust 的 disconnect_vpn_inner 会在 stop_tunnel 完成后才写入 idle。
        // 只看 connected=false 会和 Wintun 的异步释放竞争，导致下一次连接
        // 偶发创建适配器失败。
        if (status['stage']?.toString() == 'idle') {
          await Future<void>.delayed(const Duration(milliseconds: 700));
          return;
        }
      }
      // 12 秒内 Rust 侧未回到 idle，可能 native 线程卡死或 Wintun 驱动
      // 未释放；直接调 shutdown 强制重置，避免下次 connect 陷入永久等待。
      _bindings.shutdown();
    } finally {
      JwxtClient().setVpnSourceAddress(null);
    }
  }

  /// 清理学校网关可能残留的会话。
  ///
  /// 本地停止 Wintun 不一定会让学校网关立即淘汰上一次认证。退出时，若能
  /// 找到当前学号对应的本地加密加速器凭据，则静默完成一次同账号认证并再次
  /// 断开，以让网关刷新旧会话。绝不故意提交错误密码，避免触发学校风控。
  /// 清理失败不阻断退出；下次正常连接仍会保留原有的错误提示作为兜底。
  Future<void> logout() async {
    final status = await currentStatus();
    final wasConnected = status?['connected'] == true;
    final username = status?['username']?.toString().trim() ?? '';
    StoredAccount? account;
    if (wasConnected && username.isNotEmpty) {
      final accounts = await CredentialStore.load(StoredAccountKind.vpn);
      for (final candidate in accounts) {
        if (candidate.username == username) {
          account = candidate;
          break;
        }
      }
    }

    await disconnect();
    if (!wasConnected || account == null || !Platform.isWindows) return;

    try {
      // 给已取消的原生任务和网关会话一个很短的释放窗口；不向 UI 暴露账户
      // 或密码，也不会单独打开任何窗口。
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await _connectWindowsOnce(
        username: account.username,
        password: account.password,
        authSource: 'SAM-all',
      ).timeout(const Duration(seconds: 25));
    } catch (_) {
      // 只要认证请求已经发出，学校网关已有机会刷新状态。此处继续执行最终
      // 断开；真正仍然存在的 Wintun/认证问题会在下一次用户主动连接时显示。
    } finally {
      await disconnect();
    }
  }

  Future<bool> waitForCampusNetwork({
    Duration timeout = const Duration(seconds: 90),
  }) async {
    if (Platform.isAndroid) {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        if ((await _bindings.androidStatus())['connected'] == true) return true;
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      return false;
    }
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_bindings.status()['connected'] == true) return true;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return false;
  }
}

/// 主页课表与成绩页共享同一份校园网络状态，避免两个常驻页面分别探测后
/// 显示互相矛盾的连接入口。
class CampusEnvironmentController extends ChangeNotifier {
  bool _checking = false;
  bool _actionLoading = false;
  bool? _online;
  Future<void>? _detectTask;

  bool get checking => _checking;
  bool get actionLoading => _actionLoading;
  bool? get online => _online;

  Future<void> detect() {
    final running = _detectTask;
    if (running != null) return running;
    late final Future<void> task;
    task = _detectInternal().whenComplete(() {
      if (identical(_detectTask, task)) _detectTask = null;
    });
    _detectTask = task;
    return task;
  }

  Future<void> _detectInternal() async {
    _checking = true;
    notifyListeners();
    try {
      final status = await CampusVpnLauncher().currentStatus();
      if (status?['connected'] == true) {
        JwxtClient().setVpnSourceAddress(status?['virtual_ip']?.toString());
      } else if (status != null) {
        JwxtClient().setVpnSourceAddress(null);
      }
      _online = await JwxtClient().checkCampusNameServerReachable(
        timeout: const Duration(seconds: 4),
      );
    } catch (_) {
      _online = false;
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    if (_actionLoading) return;
    _actionLoading = true;
    notifyListeners();
    try {
      await CampusVpnLauncher().logout();
      await JwxtClient().resetSession();
      _online = null;
      await detect();
    } finally {
      _actionLoading = false;
      notifyListeners();
    }
  }
}

final CampusEnvironmentController _campusEnvironment =
    CampusEnvironmentController();

enum AppMode { vpnOnly, education }

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
  AppMode? _connectingMode;
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

  Future<void> _openTarget({
    required String studentId,
    required AppMode targetMode,
    void Function(String message)? onProgress,
  }) async {
    final education = targetMode == AppMode.education;
    // 原生层显示 connected 只代表隧道任务已建立，不保证网关会话立即可用。
    // 用 waitForIntranet 轮询 172.20.63.226/jsxsd/（30 秒 / 800ms 重试），
    // 和教务入口、环境检测共用同一条可达判定，避免 ns.huse.cn HTTP 不稳定
    // 导致刚建好的隧道被误判断开。
    onProgress?.call('正在验证校园内网连通性…');
    final campusReady = await JwxtClient().waitForIntranet(
      timeout: const Duration(seconds: 30),
    );
    if (!campusReady) {
      // Distinguish a stopped native tunnel from an HTTP/template failure.
      // The old single message made both cases look like bad credentials and
      // discarded the only useful diagnostic before the catch block called
      // disconnect().
      final nativeStatus = await CampusVpnLauncher().currentStatus();
      final nativeError = nativeStatus?['error']?.toString().trim() ?? '';
      final nativeStage = nativeStatus?['stage']?.toString().trim() ?? '';
      if (nativeError.isNotEmpty && nativeStage != 'connected') {
        throw nativeError;
      }
      if (nativeStatus?['connected'] != true) {
        throw '校园加速器隧道已停止（阶段：${nativeStage.isEmpty ? '未知' : nativeStage}），请重新认证';
      }
      throw '校园加速器已连接，但教务服务器无 HTTP 响应，请检查 CampusVPN 路由后重试';
    }
    if (!mounted) return;
    final next = education
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
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => next));
  }

  Future<void> _connect({AppMode? targetMode}) async {
    final studentId = _idCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (studentId.isEmpty || password.isEmpty) {
      setState(() => _error = '请输入学号和加速器密码');
      return;
    }
    final selectedMode = targetMode ?? widget.mode;
    FocusScope.of(context).unfocus();
    setState(() {
      _submitting = true;
      _connectingMode = selectedMode;
      _error = null;
      _progress = '正在启动校园加速器…';
    });
    try {
      final launcher = CampusVpnLauncher();
      final currentStatus = await launcher.currentStatus();
      if (currentStatus?['connected'] == true) {
        final connectedStudentId =
            currentStatus?['username']?.toString().trim() ?? '';
        if (connectedStudentId.isNotEmpty && connectedStudentId != studentId) {
          throw '当前校园加速器已使用其他账号连接，请先退出登录后再切换加速器账号';
        }
        JwxtClient().setVpnSourceAddress(
          currentStatus?['virtual_ip']?.toString(),
        );
        await _openTarget(
          studentId: studentId,
          targetMode: selectedMode,
          onProgress: (message) {
            if (mounted) setState(() => _progress = message);
          },
        );
        return;
      }
      await launcher.connect(
        username: studentId,
        password: password,
        authSource: 'SAM-all',
        onProgress: (message) {
          if (mounted && message != _progress) {
            setState(() => _progress = message);
          }
        },
      );
      await CredentialStore.save(
        StoredAccountKind.vpn,
        username: studentId,
        password: password,
      );
      await _loadSavedAccounts();
      await _openTarget(
        studentId: studentId,
        targetMode: selectedMode,
        onProgress: (message) {
          if (mounted) setState(() => _progress = message);
        },
      );
    } catch (error) {
      final message = _acceleratorText(error);
      if (message.contains('校园网服务未就绪') ||
          message.contains('校园加速器隧道已停止') ||
          message.contains('教务服务器无 HTTP 响应')) {
        // 必须回到 idle；否则下一次点击会复用 connected 状态，无法触发真正
        // 的学校加速器再认证。
        try {
          await CampusVpnLauncher().disconnect();
        } catch (_) {}
      }
      final lowerMessage = message.toLowerCase();
      final displayMessage =
          lowerMessage.contains('wintunstartsession failed') ||
              lowerMessage.contains('failed to create wintun adapter')
          ? '上次没有正常下线，请再认证一次'
          : lowerMessage.contains('gateway session setup timed out')
          ? '学校加速器网关响应超时，已自动重试，请稍候后再次认证'
          : lowerMessage.contains('sac login rejected')
          ? '加速器认证失败（默认为身份证后六位数字）,请检查是否填入错误密码'
          : message;
      if (mounted) setState(() => _error = displayMessage);
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
          _connectingMode = null;
          _progress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const title = '连接校园加速器';
    final colorScheme = Theme.of(context).colorScheme;
    final connectingVpn = _submitting && _connectingMode == AppMode.vpnOnly;
    final connectingEducation =
        _submitting && _connectingMode == AppMode.education;
    FilledButtonThemeData? connectionButtonTheme(bool active) {
      if (!_submitting) return null;
      return FilledButtonThemeData(
        style: FilledButton.styleFrom(
          disabledBackgroundColor: active
              ? colorScheme.primary
              : colorScheme.surfaceContainerHighest,
          disabledForegroundColor: active
              ? colorScheme.onPrimary
              : colorScheme.onSurfaceVariant,
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
              children: [
                Icon(Icons.vpn_lock, color: colorScheme.primary, size: 52),
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
                            '手机端界面已就绪，Android 系统网络隧道引擎正在接入。当前 APK 可用于体验首页和教务流程，加速器连接功能暂不可用。',
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
                  obscureText: true,
                ),
                const SizedBox(height: 24),
                if (_error != null) _ErrorBox(message: _error!),
                if (_error != null) const SizedBox(height: 16),
                if (_submitting && _progress != null) ...[
                  Text(
                    _acceleratorText(_progress!),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                ],
                if (Platform.isWindows)
                  Row(
                    children: [
                      Expanded(
                        child: FilledButtonTheme(
                          data:
                              connectionButtonTheme(connectingVpn) ??
                              const FilledButtonThemeData(),
                          child: FilledButton.icon(
                            onPressed: _submitting
                                ? null
                                : () => _connect(targetMode: AppMode.vpnOnly),
                            icon: connectingVpn
                                ? _ButtonSpinner(color: colorScheme.onPrimary)
                                : const Icon(Icons.vpn_lock),
                            label: Text(connectingVpn ? '正在连接…' : '仅启动加速器'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButtonTheme(
                          data:
                              connectionButtonTheme(connectingEducation) ??
                              const FilledButtonThemeData(),
                          child: FilledButton.icon(
                            onPressed: _submitting
                                ? null
                                : () => _connect(targetMode: AppMode.education),
                            icon: connectingEducation
                                ? _ButtonSpinner(color: colorScheme.onPrimary)
                                : const Icon(Icons.school),
                            label: Text(
                              connectingEducation ? '正在连接…' : '启动加速器并查询教务',
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                else ...[
                  // 移动端窄屏上下排布，避免两个长文本按钮互相挤压。
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed:
                          _submitting ||
                              (!Platform.isWindows && !Platform.isAndroid)
                          ? null
                          : () => _connect(targetMode: AppMode.vpnOnly),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(54),
                        disabledBackgroundColor: _submitting
                            ? connectingVpn
                                  ? colorScheme.primary
                                  : colorScheme.surfaceContainerHighest
                            : null,
                        disabledForegroundColor: _submitting
                            ? connectingVpn
                                  ? colorScheme.onPrimary
                                  : colorScheme.onSurfaceVariant
                            : null,
                      ),
                      icon: connectingVpn
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: colorScheme.onPrimary,
                              ),
                            )
                          : const Icon(Icons.vpn_lock),
                      label: Text(connectingVpn ? '正在连接…' : '仅启动加速器'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed:
                          _submitting ||
                              (!Platform.isWindows && !Platform.isAndroid)
                          ? null
                          : () => _connect(targetMode: AppMode.education),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(54),
                        disabledBackgroundColor: _submitting
                            ? connectingEducation
                                  ? colorScheme.primary
                                  : colorScheme.surfaceContainerHighest
                            : null,
                        disabledForegroundColor: _submitting
                            ? connectingEducation
                                  ? colorScheme.onPrimary
                                  : colorScheme.onSurfaceVariant
                            : null,
                      ),
                      icon: connectingEducation
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: colorScheme.onPrimary,
                              ),
                            )
                          : const Icon(Icons.school),
                      label: Text(connectingEducation ? '正在连接…' : '启动加速器并查询教务'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
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
  String? _error;
  String? _successMessage;

  @override
  void initState() {
    super.initState();
    _studentIdCtrl = TextEditingController(text: widget.initialStudentId);
    _loadRecoveryCaptcha();
  }

  @override
  void dispose() {
    _studentIdCtrl.dispose();
    _captchaCtrl.dispose();
    _identityCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadRecoveryCaptcha({bool clearError = true}) async {
    if (_loadingCaptcha || _submitting) return;
    setState(() {
      _loadingCaptcha = true;
      _captchaBytes = null;
      _captchaCtrl.clear();
      if (clearError) _error = null;
    });
    try {
      final bytes = await JwxtClient().beginPasswordRecovery().timeout(
        const Duration(seconds: 15),
      );
      if (mounted) setState(() => _captchaBytes = bytes);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loadingCaptcha = false);
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
        _captchaCtrl.clear();
        _captchaBytes = null;
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
      setState(() => _error = '账号验证会话已失效，请返回上一步重新验证');
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
        if (_error != null) ...[
          const SizedBox(height: 16),
          _ErrorBox(message: _error!),
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
          _ErrorBox(message: _error!),
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
                ? '旧教务密码已从本地删除。请返回登录页，手动输入身份证后六位临时密码；临时密码不会保存。登录后请按提示设置至少 8 位且同时包含字母、数字的新密码。'
                : '学校已完成重置，但本地安全存储清理未能确认。应用仍会禁止保存 6 位数字临时密码；请返回后不要选择任何旧账号密码，并尽快完成强制改密。',
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
                    _ErrorBox(message: _error!),
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
  Uint8List? _captchaBytes;
  bool _loadingCaptcha = false;
  bool _loggingIn = false;
  bool _openingPasswordRecovery = false;
  bool _passwordResetPendingInMemory = false;
  String? _syncProgress;
  String? _authenticatedStudentId;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _studentIdCtrl = TextEditingController(text: widget.studentId);
    _loadSavedAccounts();
    _refreshCaptcha();
  }

  @override
  void dispose() {
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

  Future<void> _refreshCaptcha({bool clearError = true}) async {
    if (_loadingCaptcha) return;
    final previousError = clearError ? null : _error;
    setState(() {
      _loadingCaptcha = true;
      _error = previousError;
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
      if (mounted) setState(() => _captchaBytes = bytes);
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
    } catch (error) {
      if (mounted) {
        setState(() {
          _notice = null;
          _error = '无法打开忘记密码流程：$error';
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
            credentialNotice = '当前密码不符合最终强密码规则或安全存储写入失败，未保存到本地';
          }
        } else {
          credentialNotice = '当前使用的是临时密码，已禁止保存；请尽快设置最终新密码';
        }
        await _loadSavedAccounts();
      }
      final syncResult = await syncOfflineUserData(
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
        setState(() => _error = '$error');
        if (!JwxtClient().isLoggedIn || _authenticatedStudentId != studentId) {
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
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '教务系统密码',
                    prefixIcon: Icon(Icons.lock_outline),
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
                const SizedBox(height: 20),
                if (_error != null) _ErrorBox(message: _error!),
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

class CampusNavigatorPage extends StatefulWidget {
  final String studentId;

  const CampusNavigatorPage({required this.studentId, super.key});

  @override
  State<CampusNavigatorPage> createState() => _CampusNavigatorPageState();
}

class _CampusNavigatorPageState extends State<CampusNavigatorPage> {
  bool _disconnecting = false;

  static const _links =
      <({String title, String description, String url, IconData icon})>[
        (
          title: '学校教务系统',
          description: '打开教务系统登录页面',
          url: 'http://jw.huse.cn/jsxsd/',
          icon: Icons.school,
        ),
        (
          title: '图书馆',
          description: '打开学校图书馆网站',
          url: 'https://lib.huse.edu.cn/',
          icon: Icons.local_library,
        ),
        (
          title: '知网',
          description: '打开中国知网',
          url: 'https://www.cnki.net/',
          icon: Icons.menu_book,
        ),
      ];

  Future<void> _open(String url) async {
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开此校园网址')));
    }
  }

  /// 返回连接页，不中断校园加速器隧道。
  Future<void> _returnToConnect() async {
    if (_disconnecting) return;
    await JwxtClient().resetSession();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => const VpnSetupPage(mode: AppMode.vpnOnly),
      ),
    );
  }

  Future<void> _disconnect() async {
    if (_disconnecting) return;
    setState(() => _disconnecting = true);
    try {
      await CampusVpnLauncher().logout();
      await JwxtClient().resetSession();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => const VpnSetupPage(mode: AppMode.vpnOnly),
        ),
        (_) => false,
      );
    } finally {
      if (mounted) setState(() => _disconnecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leadingWidth: 106,
        leading: TextButton.icon(
          onPressed: _disconnecting ? null : _returnToConnect,
          icon: const Icon(Icons.arrow_back, size: 23),
          label: const Text('返回', style: TextStyle(fontSize: 17)),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 34),
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: colorScheme.outlineVariant),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.check_circle,
                        color: colorScheme.primary,
                        size: 34,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '校园加速器已连接',
                              style: TextStyle(
                                color: colorScheme.onSurface,
                                fontSize: 19,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              '学号：${widget.studentId}',
                              style: TextStyle(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  '校园服务',
                  style: TextStyle(
                    color: colorScheme.onSurface,
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                for (final link in _links) ...[
                  _CampusLinkCard(
                    title: link.title,
                    description: link.description,
                    icon: link.icon,
                    onTap: () => _open(link.url),
                  ),
                  const SizedBox(height: 10),
                ],
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _disconnecting ? null : _disconnect,
                  icon: const Icon(Icons.power_settings_new),
                  label: const Text('断开加速器'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CampusLinkCard extends StatelessWidget {
  final String title;
  final String description;
  final IconData icon;
  final VoidCallback onTap;

  const _CampusLinkCard({
    required this.title,
    required this.description,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          child: Row(
            children: [
              Icon(icon, color: colorScheme.primary),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.open_in_new,
                color: colorScheme.onSurfaceVariant,
                size: 19,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final String message;

  const _ErrorBox({required this.message});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.error.withAlpha(100)),
      ),
      child: Text(
        _acceleratorText(message),
        style: TextStyle(color: colorScheme.onErrorContainer, height: 1.4),
      ),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _idCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  Uint8List? _captchaBytes;
  bool _loading = false;
  bool _vpnActionLoading = false;
  bool _vpnOnline = false; // 悲观默认：探测确认前视为未连通，避免误显示"已联通"
  bool _vpnChecking = true; // 探测中：UI 显示骨架，避免出现"绿→橙"闪烁

  @override
  void initState() {
    super.initState();
    _checkVpn();
    _loadCaptcha();
  }

  /// 探测校园内网（172.20.63.226）是否可达。
  /// 连不上说明本机没有到内网 IP 的路由——多半是加速器没建好隧道，
  /// 此时登录页显示橙色“未检测到校园内网”提示，提醒用户先连加速器。
  Future<void> _checkVpn() async {
    final ok = await JwxtClient().checkIntranetReachable();
    if (mounted) {
      setState(() {
        _vpnOnline = ok;
        _vpnChecking = false;
      });
    }
  }

  Future<void> _startVpn({required bool waitForCampusNetwork}) async {
    if (!Platform.isWindows) {
      _showMsg('内置校园加速器目前仅支持 Windows');
      return;
    }
    setState(() => _vpnActionLoading = true);
    try {
      final launcher = CampusVpnLauncher();
      await launcher.start();
      if (!waitForCampusNetwork) {
        if (mounted) {
          _showMsg('加速器客户端已启动，请在新窗口完成连接');
        }
        return;
      }

      if (mounted) {
        _showMsg('加速器客户端已启动，请完成账号认证；应用会自动等待校园网');
      }
      final connected = await launcher.waitForCampusNetwork();
      if (!mounted) return;
      if (connected) {
        setState(() {
          _vpnOnline = true;
          _vpnChecking = false;
        });
        await _loadCaptcha();
        if (mounted) _showMsg('校园加速器已连接，教务系统已就绪');
      } else {
        _showMsg('尚未检测到校园网，请完成加速器连接后重试');
      }
    } catch (error) {
      if (mounted) _showMsg('$error');
    } finally {
      if (mounted) setState(() => _vpnActionLoading = false);
    }
  }

  Future<void> _loadCaptcha() async {
    setState(() => _captchaBytes = null);
    try {
      final bytes = await JwxtClient().getCaptcha();
      if (mounted) setState(() => _captchaBytes = bytes);
    } catch (e) {
      if (mounted) _showMsg('获取验证码失败：$e');
    }
  }

  Future<void> _login() async {
    final id = _idCtrl.text.trim();
    final pwd = _pwdCtrl.text;
    final code = _codeCtrl.text.trim();
    if (id.isEmpty || pwd.isEmpty || code.isEmpty) {
      _showMsg('请填写完整');
      return;
    }
    setState(() => _loading = true);
    try {
      final loginResult = await JwxtClient().login(id, pwd, code);
      if (loginResult.status == JwxtLoginStatus.passwordChangeRequired) {
        throw '教务系统要求设置新的强密码，请返回新版教务登录页完成修改；临时密码未保存';
      }
      if (loginResult.isSuccess && mounted) {
        final resetPending =
            await CredentialStore.isEducationPasswordResetPending(id);
        if (!resetPending || isValidFinalEducationPassword(pwd)) {
          final saved = await CredentialStore.save(
            StoredAccountKind.education,
            username: id,
            password: pwd,
          );
          if (saved && resetPending) {
            await CredentialStore.clearEducationPasswordResetPending(id);
          }
        }
        await syncOfflineUserData(studentId: id);
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => HomePage(studentId: id)),
        );
      }
    } catch (e) {
      if (mounted) {
        _showMsg('❌ $e');
        _loadCaptcha();
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showMsg(String msg) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(_acceleratorText(msg))));

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 60),
              Icon(Icons.school, size: 80, color: colorScheme.primary),
              const SizedBox(height: 16),
              Text(
                '教务查询系统',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '湖南科技学院',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 40),
              // 校园内网检测：探测中显示骨架；未连通显示橙色提示；已连通显示绿色提示。
              if (Platform.isWindows)
                Container(
                  margin: const EdgeInsets.only(bottom: 20),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer.withAlpha(120),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: colorScheme.outlineVariant),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.vpn_key, color: colorScheme.primary),
                          const SizedBox(width: 8),
                          Text(
                            '校园加速器',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '可单独启动加速器，也可以连接成功后自动回到本页查询教务。',
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _vpnActionLoading
                                  ? null
                                  : () =>
                                        _startVpn(waitForCampusNetwork: false),
                              icon: const Icon(Icons.open_in_new, size: 18),
                              label: const Text('仅启动加速器'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _vpnActionLoading
                                  ? null
                                  : () => _startVpn(waitForCampusNetwork: true),
                              icon: _vpnActionLoading
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.login, size: 18),
                              label: const Text('连接并进入教务'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              if (_vpnChecking)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '正在检测校园内网连接…',
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                )
              else if (!_vpnOnline)
                Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.errorContainer.withAlpha(120),
                    border: Border.all(color: colorScheme.error.withAlpha(120)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.vpn_key_off,
                        color: colorScheme.error,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '未检测到校园内网（172.20.63.226），请先连接加速器后再登录教务系统',
                          style: TextStyle(
                            color: colorScheme.onErrorContainer,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else if (_vpnOnline)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.tertiaryContainer.withAlpha(120),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.vpn_key,
                        color: colorScheme.tertiary,
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '校园内网已连通',
                        style: TextStyle(
                          color: colorScheme.onTertiaryContainer,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              TextField(
                controller: _idCtrl,
                decoration: const InputDecoration(
                  labelText: '学号',
                  prefixIcon: Icon(Icons.person),
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _pwdCtrl,
                decoration: const InputDecoration(
                  labelText: '密码',
                  prefixIcon: Icon(Icons.lock),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _codeCtrl,
                      decoration: const InputDecoration(
                        labelText: '验证码',
                        hintText: '按图片原样输入',
                        prefixIcon: Icon(Icons.security),
                      ),
                      onChanged: (value) {
                        final lower = value.toLowerCase();
                        if (lower != value) {
                          _codeCtrl.value = _codeCtrl.value.copyWith(
                            text: lower,
                            selection: TextSelection.collapsed(
                              offset: lower.length,
                            ),
                            composing: TextRange.empty,
                          );
                        }
                      },
                      maxLength: 4,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: GestureDetector(
                      onTap: _captchaBytes == null ? null : _loadCaptcha,
                      child: Container(
                        height: 56,
                        decoration: BoxDecoration(
                          border: Border.all(color: colorScheme.outline),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: _captchaBytes != null
                            ? Image.memory(_captchaBytes!, fit: BoxFit.contain)
                            : const Center(child: CircularProgressIndicator()),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '点击图片刷新验证码',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                height: 48,
                child: FilledButton(
                  onPressed: _loading ? null : _login,
                  child: _loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('登 录', style: TextStyle(fontSize: 16)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==================== 首页 ====================

Future<bool> _confirmAccountAction(
  BuildContext context, {
  required String message,
  bool orangeText = false,
  String confirmLabel = '确定',
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      content: Text(
        message,
        style: orangeText
            ? TextStyle(
                color: Colors.orange.shade800,
                fontWeight: FontWeight.w700,
              )
            : null,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

Future<StoredAccount?> _pickSavedEducationAccount(
  BuildContext context, {
  required String currentStudentId,
}) async {
  final accounts = await CredentialStore.load(StoredAccountKind.education);
  if (!context.mounted) return null;
  if (accounts.isEmpty) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('暂无本地保存的教务账号')));
    return null;
  }
  return showModalBottomSheet<StoredAccount>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const ListTile(
            title: Text('选择要查看的账号课表'),
            subtitle: Text('切换不会断开校园加速器'),
          ),
          for (final account in accounts)
            ListTile(
              leading: Icon(
                account.username == currentStudentId
                    ? Icons.check_circle
                    : Icons.account_circle_outlined,
              ),
              title: Text(account.username),
              subtitle: Text(
                account.username == currentStudentId ? '当前账号' : '查看本地保存课表',
              ),
              onTap: () => Navigator.of(sheetContext).pop(account),
            ),
        ],
      ),
    ),
  );
}

/// 切换仅影响当前展示与教务 Cookie；校园加速器不会断开。
Future<void> _switchToSavedAccount(
  BuildContext context, {
  required String currentStudentId,
}) async {
  final account = await _pickSavedEducationAccount(
    context,
    currentStudentId: currentStudentId,
  );
  if (account == null ||
      account.username == currentStudentId ||
      !context.mounted) {
    return;
  }
  final confirmed = await _confirmAccountAction(context, message: '确定切换吗？');
  if (!confirmed) return;

  await JwxtClient().resetSession();
  final cached = await ScheduleCacheStore.loadLatest(account.username);
  final profile = await UserDataCacheStore.loadProfile(account.username);
  if (!context.mounted) return;
  final destination = cached == null && profile == null
      ? const VpnSetupPage(
          mode: AppMode.education,
          initialNotice: '您之前未进行过认证，本地暂无存储，请认证后保存课表',
        )
      : HomePage(studentId: account.username);
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => destination),
    (_) => false,
  );
}

/// 教务首页（带底部导航栏的壳）。首页课表优先显示此账号本地保存的最新学期，
/// 因此即使未连接加速器也能查看历史缓存。
class HomePage extends StatefulWidget {
  final String studentId;
  final String? initialNotice;

  const HomePage({required this.studentId, this.initialNotice, super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _campusEnvironment.detect();
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

  // 顺序：1.学期课表 2.成绩查询 3.体测成绩计算器 4.设置（用户要求放最后）
  static const _tabs = <_TabSpec>[
    _TabSpec('课表', Icons.calendar_today),
    _TabSpec('成绩', Icons.grade),
    _TabSpec('体测', Icons.fitness_center),
    _TabSpec('设置', Icons.settings),
  ];

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final pages = <Widget>[
      SchedulePage(studentId: widget.studentId),
      GradesPage(studentId: widget.studentId),
      const FitnessPage(),
      SettingsPage(studentId: widget.studentId),
    ];
    return Scaffold(
      // 保留每个页面 State，并用轻微淡入/平移动画切换，避免底部导航
      // 点击后页面像被硬切开一样割裂。
      body: Stack(
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
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
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

  @override
  void initState() {
    super.initState();
    _appSettingsRevision.addListener(_reloadSettings);
    _load();
  }

  @override
  void dispose() {
    _appSettingsRevision.removeListener(_reloadSettings);
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
    if (notify) _notifyAppSettingsChanged();
  }

  /// 退出时彻底关闭加速器；本地加密账号保留，便于下次在登录页快速填充。
  Future<void> _logout() async {
    if (_accountActionLoading) return;
    final confirmed = await _confirmAccountAction(context, message: '确定退出吗？');
    if (!confirmed || !mounted) return;
    setState(() => _accountActionLoading = true);
    try {
      await CampusVpnLauncher().logout();
      await JwxtClient().resetSession();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const AppBootstrapPage()),
        (_) => false,
      );
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
      await _switchToSavedAccount(context, currentStudentId: widget.studentId);
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
    if (!await _confirmAccountAction(context, message: '确定删除吗？') || !mounted) {
      return;
    }
    if (!await _confirmAccountAction(
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
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const AppBootstrapPage()),
        (_) => false,
      );
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
                            Text('深色模式'),
                            SizedBox(height: 3),
                            Text('浅色 / 深色 / 跟随系统'),
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
                          setState(() => _settings!.highlightCurrentWeek = v);
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
                          setState(() => _settings!.filterByWeek = v);
                          _persist(notify: true);
                        },
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

// ==================== 课表页（带学期选择） ====================
enum _ScheduleExportFormat { jpg, png, html }

class SchedulePage extends StatefulWidget {
  final String studentId;

  const SchedulePage({required this.studentId, super.key});

  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage> {
  static const _latestScheduleTermsValue = '__latest_schedule_term__';
  static const _allScheduleTermsValue = '__all_schedule_terms__';
  final _scheduleRepaintKey = GlobalKey();
  List<String> _terms = const [];
  String _selectedTerm = AcademicCalendar.latestTerm;
  List<Map<String, String>> _courses = [];
  bool _loading = true;
  String? _error;
  String? _emptyMessage;
  String? _debugHtmlPath; // 本次抓到的原始 HTML 落盘路径（解析失败时填，用于排查）
  String _lastRawHtml = ''; // 解析失败时也保留在内存里，便于"显示 HTML 预览"
  bool _showHtmlPreview = false;
  bool _showDiagnostics = false;
  bool _loadedFromCache = false;
  DateTime? _cachedAt;
  String? _selectedScheduleUpdateTerm;

  // 设置（本地持久化）：本周视图高亮 + 按周筛选，均基于手动选定的"当前周次"。
  AppSettings? _settings;
  @override
  void initState() {
    super.initState();
    _appSettingsRevision.addListener(_reloadSettings);
    _campusEnvironment.addListener(_refreshCampusEnvironment);
    dataSyncCooldown.addListener(_refreshSyncCooldown);
    _initialize();
  }

  @override
  void dispose() {
    _appSettingsRevision.removeListener(_reloadSettings);
    _campusEnvironment.removeListener(_refreshCampusEnvironment);
    dataSyncCooldown.removeListener(_refreshSyncCooldown);
    super.dispose();
  }

  void _refreshCampusEnvironment() {
    if (mounted) setState(() {});
  }

  void _refreshSyncCooldown() {
    if (mounted) setState(() {});
  }

  void _reloadSettings() {
    AppSettings.load().then((settings) {
      if (mounted) setState(() => _settings = settings);
    });
  }

  Future<void> _saveSettingsAndRefresh() async {
    await _settings?.save();
    _notifyAppSettingsChanged();
  }

  Future<void> _detectCampusEnvironment() async {
    await _campusEnvironment.detect();
  }

  Future<void> _openVpnSetup() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const VpnSetupPage(mode: AppMode.education),
      ),
    );
    if (mounted) await _detectCampusEnvironment();
  }

  List<String> _scheduleUpdateTerms() {
    final terms = <String>{...AcademicCalendar.terms, ..._terms}.toList();
    terms.sort((a, b) {
      final aIndex = AcademicCalendar.terms.indexOf(a);
      final bIndex = AcademicCalendar.terms.indexOf(b);
      if (aIndex >= 0 && bIndex >= 0) return aIndex.compareTo(bIndex);
      if (aIndex >= 0) return -1;
      if (bIndex >= 0) return 1;
      return b.compareTo(a);
    });
    return terms;
  }

  Future<bool> _canReuseEducationSession() async {
    if (_campusEnvironment.checking) await _detectCampusEnvironment();
    if (_campusEnvironment.online != true) {
      await _detectCampusEnvironment();
    }
    final client = JwxtClient();
    return _campusEnvironment.online == true &&
        client.isLoggedIn &&
        client.authenticatedStudentId == widget.studentId;
  }

  Future<void> _openManualScheduleSave() async {
    final remaining = dataSyncCooldown.remaining(SyncResource.schedule);
    if (remaining > Duration.zero) {
      _showSyncCooldownMessage(SyncResource.schedule);
      return;
    }
    final selected = _selectedScheduleUpdateTerm;
    final fetchAll = selected == _allScheduleTermsValue;
    final term = fetchAll ? null : selected;
    if (await _canReuseEducationSession()) {
      setState(() {
        _loading = true;
        _error = null;
      });
      try {
        final result = await syncOfflineUserData(
          studentId: widget.studentId,
          syncSchedules: true,
          forceScheduleSync: true,
          fetchAllSchedules: fetchAll,
          scheduleTerm: term,
          syncGrades: false,
          onProgress: (message) {
            if (mounted) setState(() => _emptyMessage = message);
          },
        );
        await _initialize();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                result.schedulesFetchedAll
                    ? '已保存 ${result.savedTermCount} 个学期课表'
                    : term == null
                    ? '已更新最新一期课表'
                    : '已更新 $term 课表',
              ),
            ),
          );
        }
      } catch (error) {
        if (mounted) setState(() => _error = '$error');
      } finally {
        if (mounted) setState(() => _loading = false);
      }
      return;
    }

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VpnSetupPage(
          mode: AppMode.education,
          forceScheduleSync: true,
          fetchAllSchedules: fetchAll,
          scheduleTerm: term,
          syncGrades: false,
          initialNotice: fetchAll
              ? '本次更新所有已知学期课表'
              : term == null
              ? '本次仅手动保存最新一期已发布课表'
              : '本次仅更新 $term 课表',
        ),
      ),
    );
    if (mounted) {
      await _initialize();
      await _detectCampusEnvironment();
    }
  }

  void _showSyncCooldownMessage(SyncResource resource) {
    final remaining = dataSyncCooldown.remainingText(resource);
    if (remaining.isEmpty || !mounted) return;
    final label = resource == SyncResource.schedule ? '课表' : '成绩';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$label更新冷却中，还需 $remaining 后重试')));
  }

  Future<void> _handleCampusAcceleratorAction() async {
    if (_campusEnvironment.checking || _campusEnvironment.actionLoading) return;
    if (_campusEnvironment.online != true) {
      await _openVpnSetup();
      return;
    }
    try {
      await _campusEnvironment.logout();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('登出加速器失败：${_acceleratorText(error)}')),
        );
      }
    }
  }

  Future<void> _initialize() async {
    final settings = await AppSettings.load();
    final profile = await UserDataCacheStore.loadProfile(widget.studentId);
    if (!mounted) return;

    if (profile != null && profile.scheduleTerms.isNotEmpty) {
      final knownTerms = AcademicCalendar.terms
          .where(profile.scheduleTerms.contains)
          .toList(growable: true);
      final unknownTerms =
          profile.scheduleTerms
              .where((term) => !AcademicCalendar.terms.contains(term))
              .toList(growable: false)
            ..sort((a, b) => b.compareTo(a));
      knownTerms.addAll(unknownTerms);
      final selectedTerm = knownTerms.contains(AcademicCalendar.latestTerm)
          ? AcademicCalendar.latestTerm
          : knownTerms.first;
      setState(() {
        _settings = settings;
        _terms = knownTerms;
        _selectedTerm = selectedTerm;
        _loadedFromCache = true;
        _cachedAt = profile.savedAt;
      });
      await _loadLocalTerm(selectedTerm);
      return;
    }

    // 兼容旧版仅保存“最新学期解析结果”的缓存。新认证完成后会自动迁移到
    // 每学期一份静态 HTML 的完整离线目录。
    final legacy = await ScheduleCacheStore.loadLatest(widget.studentId);
    if (!mounted) return;
    if (legacy != null) {
      setState(() {
        _settings = settings;
        _terms = [legacy.term];
        _selectedTerm = legacy.term;
        _courses = legacy.courses
            .map((course) => Map<String, String>.from(course))
            .toList(growable: false);
        _emptyMessage = legacy.courses.isEmpty
            ? _emptyMessageFor(legacy.term)
            : null;
        _loading = false;
        _loadedFromCache = true;
        _cachedAt = legacy.savedAt;
      });
      return;
    }

    setState(() {
      _settings = settings;
      _loading = false;
      _emptyMessage = '暂无本地课表，请连接校园加速器后认证并保存';
    });
  }

  // 设置未加载完成时的兜底：两功能都关、周次 1。
  AppSettings get _s => _settings ?? AppSettings();

  /// 应用"按周筛选"：开启时只保留当前周次有课的课程。
  List<Map<String, String>> get _visibleCourses {
    if (!_s.filterByWeek) return _courses;
    final w = _s.currentWeek;
    return _courses.where((c) => weekInWeeks(c['weeks'] ?? '', w)).toList();
  }

  String _emptyMessageFor(String term) {
    return term == AcademicCalendar.latestTerm &&
            AcademicCalendar.isBeforeLatestTermQueryDate(DateTime.now())
        ? '课表为空，可能是未开放查询'
        : '暂无课程安排';
  }

  String _formatCachedAt(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}';
  }

  Future<void> _loadLocalTerm(String term) async {
    setState(() {
      _selectedTerm = term;
      _loading = true;
      _error = null;
      _emptyMessage = null;
      _courses = [];
      _debugHtmlPath = null;
      _showHtmlPreview = false;
      _lastRawHtml = '';
    });
    try {
      final rawHtml = await UserDataCacheStore.loadScheduleHtml(
        widget.studentId,
        term,
      );
      if (!mounted) return;
      if (rawHtml == null) {
        setState(() {
          _emptyMessage = '该学期暂无本地课表，请重新连接校园加速器后认证并保存';
          _loading = false;
        });
        return;
      }
      final courses = parseScheduleHtml(rawHtml);
      setState(() {
        _lastRawHtml = rawHtml;
        _courses = courses;
        _emptyMessage = courses.isEmpty ? _emptyMessageFor(term) : null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '本地课表文件无法读取，请重新连接校园加速器后认证并保存';
        _emptyMessage = null;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final updateTerms = _scheduleUpdateTerms();
    final selectedUpdateValue = _selectedScheduleUpdateTerm == null
        ? _latestScheduleTermsValue
        : _selectedScheduleUpdateTerm!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('学期课表'),
        actions: [
          TextButton.icon(
            onPressed: () => _switchToSavedAccount(
              context,
              currentStudentId: widget.studentId,
            ),
            icon: const Icon(Icons.switch_account, size: 18),
            label: const Text('切换用户'),
          ),
          if (!_campusEnvironment.checking)
            TextButton.icon(
              onPressed: _campusEnvironment.actionLoading
                  ? null
                  : _handleCampusAcceleratorAction,
              icon: _campusEnvironment.actionLoading
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      _campusEnvironment.online == true
                          ? Icons.logout
                          : Icons.vpn_lock,
                      size: 18,
                    ),
              label: Text(
                _campusEnvironment.actionLoading
                    ? '正在登出…'
                    : _campusEnvironment.online == true
                    ? '登出加速器'
                    : '连接校园加速器',
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _loadedFromCache
                        ? '正在显示账号 ${widget.studentId} 的本地课表'
                              '${_cachedAt == null ? '' : ' · ${_formatCachedAt(_cachedAt!)}'}'
                        : '账号 ${widget.studentId} 暂无本地课表',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Tooltip(
                  message: '点击重新检测是否为校内环境',
                  child: OutlinedButton.icon(
                    onPressed: _campusEnvironment.checking
                        ? null
                        : _detectCampusEnvironment,
                    icon: _campusEnvironment.checking
                        ? const SizedBox.square(
                            dimension: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            _campusEnvironment.online == true
                                ? Icons.wifi
                                : Icons.cloud_off,
                            size: 17,
                          ),
                    label: Text(
                      _campusEnvironment.checking
                          ? '正在检测校内环境'
                          : _campusEnvironment.online == true
                          ? '在线模式 · 校园内网可用'
                          : '离线模式 · 使用本地数据',
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: DropdownButtonFormField<String>(
              key: ValueKey(_selectedTerm),
              decoration: const InputDecoration(
                labelText: '本地学年学期',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.calendar_month),
              ),
              initialValue: _terms.contains(_selectedTerm)
                  ? _selectedTerm
                  : null,
              items: _terms
                  .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                  .toList(),
              onChanged: _loading
                  ? null
                  : (v) {
                      if (v == null || v == _selectedTerm) return;
                      _loadLocalTerm(v);
                    },
            ),
          ),
          // 第二行：导出课表 + 周次选择（按设置页的"本周视图/按周筛选"决定是否显示与高亮）
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _lastRawHtml.isEmpty
                      ? null
                      : _chooseScheduleExport,
                  icon: const Icon(Icons.save_alt, size: 16),
                  label: const Text('导出课表'),
                ),
                const Spacer(),
                // 仅当开启"本周视图"或"按周筛选"时才需要选择周次
                if (_s.highlightCurrentWeek || _s.filterByWeek) ...[
                  Text(
                    _s.filterByWeek && _s.highlightCurrentWeek
                        ? '高亮+筛选'
                        : _s.filterByWeek
                        ? '按周筛选'
                        : '本周视图',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(width: 6),
                  DropdownButton<int>(
                    value: _s.currentWeek,
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
                            _saveSettingsAndRefresh();
                          },
                  ),
                ] else
                  Text(
                    '未启用周视图（设置中开启）',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: ValueKey(
                          'schedule-update-$selectedUpdateValue-${updateTerms.join('|')}',
                        ),
                        initialValue:
                            updateTerms.contains(selectedUpdateValue) ||
                                selectedUpdateValue ==
                                    _latestScheduleTermsValue ||
                                selectedUpdateValue == _allScheduleTermsValue
                            ? selectedUpdateValue
                            : _latestScheduleTermsValue,
                        decoration: const InputDecoration(
                          labelText: '更新学期',
                          prefixIcon: Icon(Icons.cloud_download),
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: [
                          const DropdownMenuItem(
                            value: _latestScheduleTermsValue,
                            child: Text('最新一期（自动回退）'),
                          ),
                          const DropdownMenuItem(
                            value: _allScheduleTermsValue,
                            child: Text('所有已知学期'),
                          ),
                          ...updateTerms.map(
                            (term) => DropdownMenuItem(
                              value: term,
                              child: Text(term),
                            ),
                          ),
                        ],
                        onChanged: _loading
                            ? null
                            : (value) {
                                if (value == null) return;
                                setState(() {
                                  _selectedScheduleUpdateTerm =
                                      value == _latestScheduleTermsValue
                                      ? null
                                      : value;
                                });
                              },
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed:
                          _loading ||
                              dataSyncCooldown.isCooling(SyncResource.schedule)
                          ? null
                          : _openManualScheduleSave,
                      icon: const Icon(Icons.sync, size: 18),
                      label: const Text('更新课表'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: _SyncCooldownIndicator(
                    resource: SyncResource.schedule,
                  ),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: RepaintBoundary(
              key: _scheduleRepaintKey,
              child: ColoredBox(
                color: Theme.of(context).scaffoldBackgroundColor,
                child: _error != null
                    ? _buildErrorView(context)
                    : _courses.isEmpty
                    ? Center(
                        child: Text(
                          _loading
                              ? '正在读取本地课表…'
                              : (_emptyMessage ?? '暂无本地课表数据'),
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : _buildScheduleTable(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorView(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colorScheme.error.withAlpha(140)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.error_outline, color: colorScheme.error),
                    const SizedBox(width: 8),
                    Text(
                      '本地课表读取失败',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.error,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: colorScheme.onErrorContainer),
                ),
                if (_debugHtmlPath != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    '已把本次响应的原始 HTML 保存到本地，便于排查：',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: colorScheme.surface,
                      border: Border.all(color: colorScheme.outlineVariant),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: SelectableText(
                      _debugHtmlPath!,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('复制路径'),
                        onPressed: () async {
                          await _copyToClipboard(_debugHtmlPath!);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('路径已复制')),
                          );
                        },
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.table_chart, size: 16),
                        label: const Text('复制课表表格'),
                        onPressed: () async {
                          final tables = extractTableBlocks(_lastRawHtml);
                          final text = tables.isEmpty
                              ? '(本页未找到任何 <table>，课表可能是 JS/AJAX 动态加载，请把"结构自检"内容发来)'
                              : tables.join('\n\n');
                          await _copyToClipboard(text);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                tables.isEmpty
                                    ? '未找到表格'
                                    : '已复制 ${tables.length} 个表格',
                              ),
                            ),
                          );
                        },
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.grid_view, size: 16),
                        label: const Text('复制 timetable 表'),
                        onPressed: () async {
                          final tt = extractTableById(
                            _lastRawHtml,
                            'timetable',
                          );
                          if (tt == null) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('未找到 #timetable')),
                            );
                            return;
                          }
                          await _copyToClipboard(tt);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已复制 #timetable')),
                          );
                        },
                      ),
                      OutlinedButton.icon(
                        icon: Icon(
                          _showHtmlPreview
                              ? Icons.expand_less
                              : Icons.expand_more,
                          size: 16,
                        ),
                        label: Text(
                          _showHtmlPreview ? '收起 HTML 预览' : '展开 HTML 预览',
                        ),
                        onPressed: () => setState(
                          () => _showHtmlPreview = !_showHtmlPreview,
                        ),
                      ),
                      OutlinedButton.icon(
                        icon: Icon(
                          _showDiagnostics
                              ? Icons.expand_less
                              : Icons.expand_more,
                          size: 16,
                        ),
                        label: Text(_showDiagnostics ? '收起结构自检' : '结构自检'),
                        onPressed: () => setState(
                          () => _showDiagnostics = !_showDiagnostics,
                        ),
                      ),
                    ],
                  ),
                  if (_showHtmlPreview) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        border: Border.all(color: colorScheme.outlineVariant),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: SelectableText(
                        _lastRawHtml.length > 4096
                            ? '${_lastRawHtml.substring(0, 4096)}\n\n… (已截断，共 ${_lastRawHtml.length} 字符)'
                            : _lastRawHtml,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                  if (_showDiagnostics) ...[
                    const SizedBox(height: 12),
                    _buildDiagnosticsView(),
                  ],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _copyToClipboard(String text) async {
    // 避免对 flutter/services 的硬依赖，调用方式与项目其它地方一致
    await Clipboard.setData(ClipboardData(text: text));
  }

  Widget _buildDiagnosticsView() {
    final diag = scheduleDiagnostics(_lastRawHtml);
    final lines = diag.entries.map((e) => '${e.key}: ${e.value}').join('\n');
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colorScheme.tertiaryContainer,
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('复制自检'),
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  await _copyToClipboard(lines);
                  if (!context.mounted) return;
                  messenger.showSnackBar(
                    const SnackBar(content: Text('自检内容已复制')),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            lines,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ],
      ),
    );
  }

  // ==================== 课表表格 ====================

  /// 把课表渲染成 8 列表格：节次(行) × 周一~周日(列)。
  /// 同一格内若有多个课程（如同一时间多门课），会纵向堆叠。
  Widget _buildScheduleTable() {
    const dayOrder = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

    // 按周筛选后的可见课程；本周视图高亮也基于同一"当前周次"。
    final list = _visibleCourses;
    if (list.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _s.filterByWeek ? '第${_s.currentWeek}周暂无课程安排' : '暂无课程数据',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 14,
            ),
          ),
        ),
      );
    }

    // 1) 按出现顺序收集去重的时间节次（解析器已按行顺序输出，保持原顺序）
    final orderedTimes = <String>[];
    final seen = <String>{};
    for (final c in list) {
      final t = c['time'] ?? '';
      if (!seen.add(t)) continue;
      orderedTimes.add(t);
    }

    // 2) 按 (time, day) 分组，方便填表
    final tableData = <String, Map<String, List<Map<String, String>>>>{};
    for (final c in list) {
      final t = c['time'] ?? '';
      final d = c['day'] ?? '';
      tableData
          .putIfAbsent(t, () => <String, List<Map<String, String>>>{})
          .putIfAbsent(d, () => <Map<String, String>>[])
          .add(c);
    }

    // 3) 表体：本周视图开启时，把"当前周次"传下去做高亮
    final highlightWeek = _s.highlightCurrentWeek ? _s.currentWeek : null;

    // 4) 渲染：宽屏宽列；窄屏缩列让周一~周五可见，周六日横向滑动
    final widthCtx = context;
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = constraints.maxWidth;
        final isNarrow = screenWidth < 600;

        // 手机端列宽：6 列可见 (节次 + 周一~周五)，超出部分滑动
        const timeWidth = 34.0;
        final dayWidth = isNarrow
            ? ((screenWidth - timeWidth - 8) / 5).clamp(48.0, 72.0)
            : 112.0;
        final tPad = isNarrow ? 4.0 : 8.0;
        final fSize = isNarrow ? 12.0 : 13.0;

        final tableRows = <TableRow>[];
        for (final time in orderedTimes) {
          tableRows.add(
            TableRow(
              children: [
                _buildTimeCell(time),
                for (final d in dayOrder)
                  _buildDayCell(
                    tableData[time]?[d] ?? const [],
                    highlightWeek,
                    isNarrow,
                  ),
              ],
            ),
          );
        }

        return SingleChildScrollView(
          scrollDirection: Axis.vertical,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Padding(
              padding: EdgeInsets.all(tPad),
              child: Table(
                defaultColumnWidth: FixedColumnWidth(dayWidth),
                columnWidths: isNarrow
                    ? const {0: FixedColumnWidth(timeWidth)}
                    : const {0: FixedColumnWidth(96)},
                border: TableBorder(
                  horizontalInside: BorderSide(
                    color: Theme.of(widthCtx).colorScheme.outlineVariant,
                    width: 0.5,
                  ),
                  verticalInside: BorderSide(
                    color: Theme.of(widthCtx).colorScheme.outlineVariant,
                    width: 0.5,
                  ),
                  top: BorderSide(
                    color: Theme.of(widthCtx).colorScheme.outline,
                  ),
                  bottom: BorderSide(
                    color: Theme.of(widthCtx).colorScheme.outline,
                  ),
                  left: BorderSide(
                    color: Theme.of(widthCtx).colorScheme.outline,
                  ),
                  right: BorderSide(
                    color: Theme.of(widthCtx).colorScheme.outline,
                  ),
                ),
                children: [
                  TableRow(
                    decoration: BoxDecoration(
                      color: Theme.of(
                        widthCtx,
                      ).colorScheme.primaryContainer.withAlpha(102),
                    ),
                    children: [
                      _buildHeaderCell('节', fontSize: fSize),
                      for (var i = 0; i < dayOrder.length; i++)
                        _buildHeaderCell(
                          isNarrow ? dayOrder[i][1] : dayOrder[i],
                          fontSize: fSize,
                        ),
                    ],
                  ),
                  ...tableRows,
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeaderCell(String text, {double fontSize = 13}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      alignment: Alignment.center,
      child: Text(
        text,
        style: TextStyle(fontWeight: FontWeight.bold, fontSize: fontSize),
      ),
    );
  }

  Widget _buildTimeCell(String time) {
    // 例 "第一大节 (01,02小节)" / "第一节 (01,02小节)" → 主行 + 小节行
    final match = RegExp(
      r'^(第[一二三四五六七八九十]+(?:大)?节)(?:\s*\(([^)]+)\))?',
    ).firstMatch(time);
    final main = match?.group(1) ?? time;
    final sub = match?.group(2) ?? '';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withAlpha(128),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            main,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          ),
          if (sub.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              sub,
              style: TextStyle(
                fontSize: 10,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDayCell(
    List<Map<String, String>> courses, [
    int? highlightWeek,
    bool isNarrow = false,
  ]) {
    if (courses.isEmpty) {
      return Container(
        height: 64,
        alignment: Alignment.center,
        decoration: highlightWeek != null
            ? BoxDecoration(
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              )
            : null,
        child: Text(
          '-',
          style: TextStyle(
            color: Theme.of(context).colorScheme.outline,
            fontSize: 18,
          ),
        ),
      );
    }

    // 本周视图高亮：当周落在任意课程周次区间内，则该格高亮（淡黄底色）。
    // 用 parseWeekSpans 覆盖所有逗号分段，避免"1-4,9-12(周)"在第11周不亮。
    // 本周视图高亮：当周落在任意课程周次区间内，则该格高亮（淡黄底色）。
    // 用 parseWeekSpans 覆盖所有逗号分段，避免"1-4,9-12(周)"在第11周不亮。
    final w = highlightWeek;
    final bool inCurrentWeek =
        w != null &&
        courses.any((c) {
          return parseWeekSpans(
            c['weeks'] ?? '',
          ).any((s) => s['start']! <= w && w <= s['end']!);
        });

    // 按"周次是否重叠"把同格课程分组：
    //  - 周次重叠的多门课 → 归为一个"冲突簇"，渲染成可点击的冲突块；
    //  - 周次不重叠（如 1-10 周与 11-12 周）→ 各自单独正常显示。
    final spans = courses.map((c) => parseWeekSpans(c['weeks'] ?? '')).toList();
    final n = courses.length;
    final parent = List.generate(n, (i) => i);
    int find(int x) => parent[x] == x ? x : parent[x] = find(parent[x]);
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        if (spans[i].isEmpty || spans[j].isEmpty) continue;
        if (weekSpansOverlap(spans[i], spans[j])) {
          parent[find(i)] = find(j);
        }
      }
    }
    final clusters = <int, List<int>>{};
    for (var i = 0; i < n; i++) {
      clusters.putIfAbsent(find(i), () => <int>[]).add(i);
    }

    final children = <Widget>[];
    var first = true;
    for (final idxs in clusters.values) {
      if (!first) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Divider(
              height: 1,
              thickness: 0.5,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        );
      }
      first = false;

      if (idxs.length == 1) {
        children.add(_buildCourseEntry(courses[idxs.first], isNarrow));
      } else {
        // 合并冲突簇的各段区间，求真实的覆盖区间作为标签（支持多段）。
        // 例如 A=1-4,9-12 与 C=9-10 冲突，标签应显示二者真实重叠的 "9-12周"，
        // 而非只看首段得出的误导性的 "1-4周"。
        int? s;
        int? e;
        for (final i in idxs) {
          for (final sp in spans[i]) {
            final st = sp['start']!;
            final en = sp['end']!;
            s = s == null ? st : (st < s ? st : s);
            e = e == null ? en : (en > e ? en : e);
          }
        }
        final label = (s != null && e != null) ? '$s-$e周' : '课程';
        children.add(
          _buildConflictCell(idxs.map((i) => courses[i]).toList(), label),
        );
      }
    }

    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(minHeight: 64),
      decoration: inCurrentWeek
          ? BoxDecoration(
              color: colorScheme.primaryContainer.withAlpha(120),
              border: Border.all(color: colorScheme.primary, width: 1),
              borderRadius: BorderRadius.circular(2),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }

  /// 同一节次、周次重叠的多门课——标记为冲突，点击查看详情。
  /// [weekLabel] 如 "1-10周"，让用户一眼看到冲突发生在哪些周。
  /// 主动展示冲突的课程名（不只显示数量），避免必须点击才能看到具体是哪几门冲突。
  Widget _buildConflictCell(
    List<Map<String, String>> courses,
    String weekLabel,
  ) {
    final names = courses.map((c) {
      final n = (c['name'] ?? '').trim();
      return n.isNotEmpty ? n : '(未知课程)';
    }).toList();
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => _showConflictDialog(courses),
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: colorScheme.errorContainer.withAlpha(140),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: colorScheme.error.withAlpha(140)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: colorScheme.error,
                  size: 14,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '$weekLabel 冲突',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.error,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // 主动列出冲突课程名（按 · 排列），不用点也能看清是哪几门
            for (final n in names)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '· $n',
                  style: TextStyle(fontSize: 11, color: colorScheme.onSurface),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            const SizedBox(height: 4),
            Text(
              '点击查看 ${names.length} 门详情',
              style: TextStyle(fontSize: 9, color: colorScheme.error),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _chooseScheduleExport() async {
    if (_lastRawHtml.isEmpty || !mounted) return;
    final format = await showDialog<_ScheduleExportFormat>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择课表导出格式'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, _ScheduleExportFormat.jpg),
            child: const ListTile(
              leading: Icon(Icons.photo, color: Colors.deepOrange),
              title: Text('JPG（默认）'),
              subtitle: Text('适合手机相册与分享，按当前窗口尺寸导出'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, _ScheduleExportFormat.png),
            child: const ListTile(
              leading: Icon(Icons.image),
              title: Text('PNG'),
              subtitle: Text('无损图片，保留当前窗口尺寸'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, _ScheduleExportFormat.html),
            child: const ListTile(
              leading: Icon(Icons.code),
              title: Text('HTML'),
              subtitle: Text('导出教务系统返回的原始课表页面'),
            ),
          ),
        ],
      ),
    );
    if (format == null || !mounted) return;
    await _exportSchedule(format);
  }

  Future<Directory> _scheduleExportDirectory() async {
    if (Platform.isWindows) return Directory.current;
    return getApplicationDocumentsDirectory();
  }

  /// 导出当前屏幕可见的课表区域。手机端的 RepaintBoundary 覆盖实际窗口
  /// 分辨率，并使用设备像素比生成清晰图片；桌面端则按窗口大小导出。
  Future<void> _exportSchedule(_ScheduleExportFormat format) async {
    if (_lastRawHtml.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final dir = await _scheduleExportDirectory();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final extension = switch (format) {
        _ScheduleExportFormat.jpg => 'jpg',
        _ScheduleExportFormat.png => 'png',
        _ScheduleExportFormat.html => 'html',
      };
      final file = File(
        '${dir.path}${Platform.pathSeparator}jizhicha_schedule_${_selectedTerm}_$stamp.$extension',
      );

      if (format == _ScheduleExportFormat.html) {
        await file.writeAsString(_lastRawHtml, flush: true);
      } else {
        if (_courses.isEmpty) throw '当前学期没有可导出的课程';
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
        final renderObject = _scheduleRepaintKey.currentContext
            ?.findRenderObject();
        if (renderObject is! RenderRepaintBoundary) {
          throw '课表尚未完成渲染，请稍后再试';
        }
        final media = MediaQuery.of(context);
        final ratio = media.devicePixelRatio.clamp(1.0, 3.0).toDouble();
        final image = await renderObject.toImage(pixelRatio: ratio);
        try {
          final byteData = await image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          if (byteData == null) throw '无法生成课表图片';
          final pngBytes = byteData.buffer.asUint8List();
          final bytes = format == _ScheduleExportFormat.png
              ? pngBytes
              : img.encodeJpg(img.decodePng(pngBytes)!, quality: 92);
          await file.writeAsBytes(bytes, flush: true);
        } finally {
          image.dispose();
        }
      }
      messenger.showSnackBar(SnackBar(content: Text('已导出：${file.path}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导出失败：$e')));
    }
  }

  /// 冲突弹窗：逐条列出每门课的完整安排，由用户自行判断去上哪门。
  void _showConflictDialog(List<Map<String, String>> courses) {
    showDialog(
      context: context,
      builder: (ctx) {
        final colorScheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                color: colorScheme.error,
                size: 20,
              ),
              const SizedBox(width: 8),
              const Text('课程冲突', style: TextStyle(fontSize: 16)),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: courses.length,
              itemBuilder: (ctx2, i) {
                final c = courses[i];
                final name = (c['name'] ?? '').trim();
                final teacher = (c['teacher'] ?? '').trim();
                final room = (c['room'] ?? '').trim();
                final weeks = (c['weeks'] ?? '').trim();
                return Padding(
                  padding: EdgeInsets.only(
                    bottom: i < courses.length - 1 ? 12 : 0,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${i + 1}. ${name.isNotEmpty ? name : '(未知课程)'}',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '时间：${c['day'] ?? ''} ${c['time'] ?? ''}',
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (teacher.isNotEmpty)
                        Text(
                          '教师：$teacher',
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      if (room.isNotEmpty)
                        Text(
                          '地点：$room',
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      if (weeks.isNotEmpty)
                        Text(
                          '周次：$weeks',
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      if (i < courses.length - 1)
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: Divider(),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('知道了'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCourseEntry(Map<String, String> c, [bool isNarrow = false]) {
    final name = (c['name'] ?? '').trim();
    final teacher = (c['teacher'] ?? '').trim();
    final room = (c['room'] ?? '').trim();
    final nameSize = isNarrow ? 11.0 : 12.0;
    final subSize = isNarrow ? 9.0 : 10.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          name.isNotEmpty ? name : '(未知课程)',
          maxLines: isNarrow ? null : 2,
          overflow: isNarrow ? null : TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: nameSize,
            color: name.isNotEmpty
                ? Theme.of(context).colorScheme.onSurface
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (teacher.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(
              '@$teacher',
              maxLines: isNarrow ? null : 1,
              overflow: isNarrow ? null : TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: subSize,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (room.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(
              '📍$room',
              maxLines: isNarrow ? null : 1,
              overflow: isNarrow ? null : TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: subSize,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

// ==================== 成绩页 ====================
class GradesPage extends StatefulWidget {
  final String studentId;

  const GradesPage({required this.studentId, super.key});

  @override
  State<GradesPage> createState() => _GradesPageState();
}

class _GradesPageState extends State<GradesPage> {
  static const _latestGradeTermsValue = '__latest_grade_term__';
  static const _allGradeTermsValue = '__all_grade_terms__';
  List<Map<String, String>> _grades = [];
  bool _loading = false;
  String? _error;
  AppSettings? _settings;
  DateTime? _cachedAt;
  bool _hasSavedSnapshot = false;
  String? _selectedGradeUpdateTerm;
  String? _selectedGradeTerm;
  // 折叠状态：默认两个分组都展开；点击分组标题可切换
  bool _showDone = true;
  bool _showRetry = true;

  @override
  void initState() {
    super.initState();
    _appSettingsRevision.addListener(_reloadDisplaySettings);
    _campusEnvironment.addListener(_refreshCampusEnvironment);
    dataSyncCooldown.addListener(_refreshSyncCooldown);
    _loadLocal();
  }

  @override
  void dispose() {
    _appSettingsRevision.removeListener(_reloadDisplaySettings);
    _campusEnvironment.removeListener(_refreshCampusEnvironment);
    dataSyncCooldown.removeListener(_refreshSyncCooldown);
    super.dispose();
  }

  void _refreshCampusEnvironment() {
    if (mounted) setState(() {});
  }

  void _refreshSyncCooldown() {
    if (mounted) setState(() {});
  }

  Future<void> _openAcceleratorSetup() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const VpnSetupPage(mode: AppMode.education),
      ),
    );
    if (mounted) await _campusEnvironment.detect();
  }

  Future<bool> _canReuseEducationSession() async {
    if (_campusEnvironment.checking) await _campusEnvironment.detect();
    if (_campusEnvironment.online != true) {
      await _campusEnvironment.detect();
    }
    final client = JwxtClient();
    return _campusEnvironment.online == true &&
        client.isLoggedIn &&
        client.authenticatedStudentId == widget.studentId;
  }

  void _showSyncCooldownMessage() {
    final remaining = dataSyncCooldown.remainingText(SyncResource.grade);
    if (remaining.isEmpty || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('成绩更新冷却中，还需 $remaining 后重试')));
  }

  /// 手动刷新成绩默认只请求最新学期；可切换为指定学期或全部已知学期。
  /// 校园内网和当前教务会话都有效时直接请求，不重复打开认证页。
  Future<void> _openGradeUpdate() async {
    if (_loading) return;
    if (dataSyncCooldown.isCooling(SyncResource.grade)) {
      _showSyncCooldownMessage();
      return;
    }
    final selected = _selectedGradeUpdateTerm;
    final fetchAll = selected == _allGradeTermsValue;
    final term = fetchAll || selected == null ? null : selected;
    final scope = fetchAll ? GradeSyncScope.all : GradeSyncScope.latest;
    if (await _canReuseEducationSession()) {
      setState(() {
        _loading = true;
        _error = null;
      });
      try {
        final result = await syncOfflineUserData(
          studentId: widget.studentId,
          syncSchedules: false,
          gradeSyncScope: scope,
          gradeTerm: term,
          syncGrades: true,
        );
        await _loadLocal();
        if (mounted) {
          final description = result.gradesFetchedAll
              ? '已更新全部学期成绩（${result.gradeCount} 条）'
              : term == null
              ? '已更新最新学期成绩（${result.gradeCount} 条）'
              : '已更新 $term 成绩（${result.gradeCount} 条）';
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(description)));
        }
      } catch (error) {
        if (mounted) setState(() => _error = '$error');
      } finally {
        if (mounted) setState(() => _loading = false);
      }
      return;
    }

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VpnSetupPage(
          mode: AppMode.education,
          gradeSyncScope: scope,
          syncSchedules: false,
          gradeTerm: term,
          initialNotice: fetchAll
              ? '本次只更新全部已知学期成绩，不会重新抓取课表'
              : term == null
              ? '本次只更新最新学期成绩，不会重新抓取课表'
              : '本次只更新 $term 成绩，不会重新抓取课表',
        ),
      ),
    );
    if (mounted) await _loadLocal();
  }

  Future<void> _handleCampusAcceleratorAction() async {
    if (_campusEnvironment.checking || _campusEnvironment.actionLoading) return;
    if (_campusEnvironment.online != true) {
      await _openAcceleratorSetup();
      return;
    }
    try {
      await _campusEnvironment.logout();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('登出加速器失败：${_acceleratorText(error)}')),
        );
      }
    }
  }

  void _reloadDisplaySettings() {
    AppSettings.load().then((settings) {
      if (mounted) setState(() => _settings = settings);
    });
  }

  List<String> _availableGradeTerms() {
    final terms = _grades
        .map((grade) => (grade['term'] ?? '').trim())
        .where((term) => term.isNotEmpty)
        .toSet()
        .toList();
    terms.sort((a, b) => _termSortKey(b).compareTo(_termSortKey(a)));
    return terms;
  }

  List<String> _availableGradeUpdateTerms() {
    final terms = <String>{
      ...AcademicCalendar.terms,
      ..._availableGradeTerms(),
    }.toList();
    terms.sort((a, b) => _termSortKey(b).compareTo(_termSortKey(a)));
    return terms;
  }

  Future<void> _loadLocal() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final profile = await UserDataCacheStore.loadProfile(widget.studentId);
      final data = await UserDataCacheStore.loadGrades(widget.studentId);
      final s = await AppSettings.load();
      if (mounted) {
        setState(() {
          _grades = data;
          _settings = s;
          _cachedAt = profile?.savedAt;
          _hasSavedSnapshot = profile?.hasGrades == true;
          final terms = data
              .map((grade) => (grade['term'] ?? '').trim())
              .where((term) => term.isNotEmpty)
              .toSet();
          if (_selectedGradeTerm != null &&
              _selectedGradeTerm != '全部学期' &&
              !terms.contains(_selectedGradeTerm)) {
            _selectedGradeTerm = null;
          }
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      title: const Text('本地成绩'),
      actions: [
        TextButton.icon(
          onPressed: () => _switchToSavedAccount(
            context,
            currentStudentId: widget.studentId,
          ),
          icon: const Icon(Icons.switch_account, size: 18),
          label: const Text('切换用户'),
        ),
        if (!_campusEnvironment.checking)
          TextButton.icon(
            onPressed: _campusEnvironment.actionLoading
                ? null
                : _handleCampusAcceleratorAction,
            icon: _campusEnvironment.actionLoading
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    _campusEnvironment.online == true
                        ? Icons.logout
                        : Icons.vpn_lock,
                    size: 18,
                  ),
            label: Text(
              _campusEnvironment.actionLoading
                  ? '正在登出…'
                  : _campusEnvironment.online == true
                  ? '登出加速器'
                  : '连接校园加速器',
            ),
          ),
      ],
    );
  }

  String _formatCachedAt(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}';
  }

  Widget _buildGradeUpdateControls() {
    final terms = _availableGradeUpdateTerms();
    final selected = _selectedGradeUpdateTerm ?? _latestGradeTermsValue;
    final selectedValue =
        selected == _allGradeTermsValue ||
            selected == _latestGradeTermsValue ||
            terms.contains(selected)
        ? selected
        : _latestGradeTermsValue;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: ValueKey(
                    'grade-update-$selectedValue-${terms.join('|')}',
                  ),
                  initialValue: selectedValue,
                  decoration: const InputDecoration(
                    labelText: '更新学期',
                    prefixIcon: Icon(Icons.sync),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: _latestGradeTermsValue,
                      child: Text('最新学期'),
                    ),
                    const DropdownMenuItem(
                      value: _allGradeTermsValue,
                      child: Text('所有已知学期'),
                    ),
                    ...terms.map(
                      (term) =>
                          DropdownMenuItem(value: term, child: Text(term)),
                    ),
                  ],
                  onChanged: _loading
                      ? null
                      : (value) {
                          if (value == null) return;
                          setState(() {
                            _selectedGradeUpdateTerm =
                                value == _latestGradeTermsValue ? null : value;
                          });
                        },
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed:
                    _loading || dataSyncCooldown.isCooling(SyncResource.grade)
                    ? null
                    : _openGradeUpdate,
                icon: const Icon(Icons.cloud_download, size: 18),
                label: const Text('更新成绩'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: _SyncCooldownIndicator(resource: SyncResource.grade),
          ),
        ],
      ),
    );
  }

  Widget _buildGradeTermSelector(AppSettings settings) {
    if (!settings.gradeTermFilterEnabled) return const SizedBox.shrink();
    final terms = _availableGradeTerms();
    final selected =
        _selectedGradeTerm != null && terms.contains(_selectedGradeTerm)
        ? _selectedGradeTerm!
        : '全部学期';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: DropdownButtonFormField<String>(
        key: ValueKey('grade-term-$selected-${terms.join('|')}'),
        initialValue: selected,
        decoration: const InputDecoration(
          labelText: '成绩学期',
          prefixIcon: Icon(Icons.filter_list),
          border: OutlineInputBorder(),
        ),
        items: [
          const DropdownMenuItem(value: '全部学期', child: Text('全部学期')),
          ...terms.map(
            (term) => DropdownMenuItem(value: term, child: Text(term)),
          ),
        ],
        onChanged: (value) {
          if (value == null) return;
          setState(() {
            _selectedGradeTerm = value == '全部学期' ? null : value;
          });
        },
      ),
    );
  }

  /// 把成绩归档：
  /// - 数字得分 >= 60 → "已完成"
  /// - 文字评分（优/良/合格/中等/及格/通过/优秀/良好）→ "已完成"
  /// - 数字得分 < 60 或 "不合格/不及格/未通过/缓考(不及格)" → "历史补考/重修"
  /// 并按「课程名称 + 学分 + 课程性质 + 课程编码 + 开课学期」五字段
  /// 合并为同一门课（同一门课可能在多个学期出现，取最高分代表成绩）。
  static List<_GradeArchive> _archiveGrades(List<Map<String, String>> grades) {
    const keyFields = ['course', 'credit', 'courseType', 'code', 'term'];
    final map = <String, _GradeArchive>{};
    for (final g in grades) {
      final key = keyFields.map((k) => (g[k] ?? '').trim()).join('|');
      final gradeText = (g['grade'] ?? '').trim();
      final failed = isGradeFail(gradeText);

      // 取"代表成绩"：数字优先，否则用原文。
      final score = double.tryParse(gradeText);
      final displayGrade = score != null ? gradeText : gradeText;

      final existing = map[key];
      if (existing == null) {
        map[key] = _GradeArchive(
          course: (g['course'] ?? '').trim(),
          credit: (g['credit'] ?? '').trim(),
          courseType: (g['courseType'] ?? '').trim(),
          code: (g['code'] ?? '').trim(),
          term: (g['term'] ?? '').trim(),
          grade: displayGrade,
          isFail: failed,
        );
      } else {
        // 同一门课（五字段一致）若出现过更高分，则代表成绩取最高分；
        // 只要任意一次未通过，归入"历史补考/重修"。
        final existingScore = double.tryParse(existing.grade);
        if (score != null && (existingScore == null || score > existingScore)) {
          existing.grade = gradeText;
        } else if (score == null &&
            existingScore == null &&
            displayGrade.isNotEmpty) {
          // 两边都是文字：用文字长度当排序 key（仅在两个非数字时兜底）
          if (displayGrade.length > existing.grade.length) {
            existing.grade = displayGrade;
          }
        }
        if (failed) existing.isFail = true;
      }
    }
    return map.values.toList();
  }

  /// 把学期字符串（如 "2024-2025-1" / "2024-2025-2" / "2024-2025"）转成可比较的整数键：
  /// 学年 × 10 + 学期序号，缺学期序号视为 1。返回越大越靠前。
  static int _termSortKey(String term) {
    final m =
        RegExp(r'(\d{4})\s*-\s*(\d{4})\s*-\s*(\d+)').firstMatch(term) ??
        RegExp(r'(\d{4})\s*-\s*(\d{4})').firstMatch(term) ??
        RegExp(r'(\d{4})').firstMatch(term);
    if (m == null) return 0;
    if (m.groupCount >= 3) {
      return int.parse(m.group(1)!) * 10 + int.parse(m.group(3)!);
    }
    return int.parse(m.group(1)!) * 10 + 1;
  }

  void _sortByTermDesc(List<_GradeArchive> list) {
    list.sort((a, b) => _termSortKey(b.term).compareTo(_termSortKey(a.term)));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
        appBar: _buildAppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Scaffold(
        appBar: _buildAppBar(),
        body: Center(
          child: Text(
            '本地成绩读取失败：$_error',
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    if (!_hasSavedSnapshot || _grades.isEmpty) {
      return Scaffold(
        appBar: _buildAppBar(),
        body: Column(
          children: [
            if (_hasSavedSnapshot && _cachedAt != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '账号 ${widget.studentId} · 本地保存于 '
                    '${_formatCachedAt(_cachedAt!)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            _buildGradeUpdateControls(),
            Expanded(
              child: Center(
                child: Text(
                  _hasSavedSnapshot ? '本地成绩为空' : '暂无本地成绩，请连接校园加速器后认证并保存',
                  style: TextStyle(color: colorScheme.onSurfaceVariant),
                ),
              ),
            ),
          ],
        ),
      );
    }
    final settings = _settings ?? AppSettings();
    final selectedTerm = settings.gradeTermFilterEnabled
        ? _selectedGradeTerm
        : null;
    final gradesForDisplay = selectedTerm == null
        ? _grades
        : _grades
              .where((grade) => (grade['term'] ?? '').trim() == selectedTerm)
              .toList(growable: false);
    final archived = _archiveGrades(gradesForDisplay);
    final done = archived.where((a) => !a.isFail).toList();
    final retry = archived.where((a) => a.isFail).toList();
    if (settings.gradeSortByYear) {
      _sortByTermDesc(done);
      _sortByTermDesc(retry);
    }

    return Scaffold(
      appBar: _buildAppBar(),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              '正在显示账号 ${widget.studentId} 的本地成绩'
              '${_cachedAt == null ? '' : ' · ${_formatCachedAt(_cachedAt!)}'}',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          _buildGradeUpdateControls(),
          _buildGradeTermSelector(settings),
          if (settings.gradeCategoryEnabled) ...[
            _buildArchiveSection(
              '已完成',
              done,
              colorScheme.primary,
              _showDone,
              (v) => setState(() => _showDone = v),
            ),
            _buildArchiveSection(
              '历史补考/重修',
              retry,
              colorScheme.error,
              _showRetry,
              (v) => setState(() => _showRetry = v),
            ),
          ] else
            _buildArchiveSection(
              '全部成绩',
              archived,
              colorScheme.primary,
              true,
              (_) {},
            ),
        ],
      ),
    );
  }

  Widget _buildArchiveSection(
    String title,
    List<_GradeArchive> items,
    Color color,
    bool expanded,
    ValueChanged<bool> onToggle,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => onToggle(!expanded),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Icon(Icons.folder, color: color, size: 18),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '(${items.length})',
                  style: TextStyle(
                    fontSize: 13,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        if (expanded)
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Text(
                '暂无',
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
            )
          else
            for (final a in items) _buildGradeCard(a, color),
      ],
    );
  }

  /// 单门课程卡片：第一行显示「课程名称 + 得分」，第二行小字显示
  /// 「学分 · 课程性质 · 课程编码 · 开课学期」。
  Widget _buildGradeCard(_GradeArchive a, Color color) {
    final score = double.tryParse(a.grade);
    final failed = score != null && score < 60;
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 第一行：课程名称
                  Text(
                    a.course.isEmpty ? '未知课程' : a.course,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  // 第二行小字：五字段中的学分/课程性质/课程编码/开课学期
                  Text(
                    [
                          '学分 ${a.credit.isEmpty ? '-' : a.credit}',
                          a.courseType,
                          '编码 ${a.code.isEmpty ? '-' : a.code}',
                          '学期 ${a.term.isEmpty ? '-' : a.term}',
                        ]
                        .where((e) => e.isNotEmpty && !e.endsWith('-'))
                        .join('  ·  '),
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // 得分：第一行的右端，不及格显红
            Text(
              a.grade.isEmpty ? '-' : a.grade,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: failed ? colorScheme.error : color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 归档后的单门课程（已按五字段合并）。
class _GradeArchive {
  final String course;
  final String credit;
  final String courseType;
  final String code;
  final String term;
  String grade;
  bool isFail;

  _GradeArchive({
    required this.course,
    required this.credit,
    required this.courseType,
    required this.code,
    required this.term,
    required this.grade,
    required this.isFail,
  });
}

/// 综合判断一门成绩是否"未通过"（用于成绩归档）。
/// 规则（按优先级）：
/// 1) 含"不及格/不合格/未通过/不通过" 等明确失败关键词 → 未通过
/// 2) 含"优秀/良好/中等/合格/及格/通过/优/良" 等合格关键词 → 通过
/// 3) 数字解析成功：>= 60 → 通过；< 60 → 未通过
/// 4) 完全无法识别 → 未通过（保守归入补考/重修）
bool isGradeFail(String gradeText) {
  final t = gradeText.trim();
  if (t.isEmpty) return true;
  if (RegExp(r'(不及格|不合格|未通过|不通过)').hasMatch(t)) return true;
  if (RegExp(r'(优秀|良好|中等|合格|及格|通过|优|良)').hasMatch(t)) return false;
  final score = double.tryParse(t);
  if (score != null) return score < 60;
  return true;
}

// ==================== 体测成绩计算器 ====================
// 依据《国家学生体质健康标准（2014年修订）》大学生评分标准。
// 单项权重：BMI 15% / 肺活量 15% / 50米 20% / 坐位体前屈 10% /
// 立定跳远 10% / 引体向上(男)·1分钟仰卧起坐(女) 10% / 1000米(男)·800米(女) 20%。
// 年级分两组：大一大二、大三大四（阈值不同）。数据来自官方评分表，
// 如需微调可直接改下面两张表。table 每项 [阈值, 单项得分]，按得分降序。

// 表 key 后缀与 _FitItemDef.key 一一对应：
// _lung/_50/_reach/_jump/_pu/_1000/_800。注意：男生引体/女生仰卧起坐都用 '_pu'。
const Map<String, List<List<double>>> fitHigher = {
  'M12_lung': [
    [5040, 100],
    [4920, 95],
    [4800, 90],
    [4550, 85],
    [4300, 80],
    [4180, 78],
    [4060, 76],
    [3940, 74],
    [3820, 72],
    [3700, 70],
    [3580, 68],
    [3460, 66],
    [3340, 64],
    [3220, 62],
    [3100, 60],
    [2940, 50],
    [2780, 40],
    [2620, 30],
    [2460, 20],
    [2300, 10],
  ],
  'M34_lung': [
    [5140, 100],
    [5020, 95],
    [4900, 90],
    [4650, 85],
    [4400, 80],
    [4280, 78],
    [4160, 76],
    [4040, 74],
    [3920, 72],
    [3800, 70],
    [3680, 68],
    [3560, 66],
    [3440, 64],
    [3320, 62],
    [3200, 60],
    [3030, 50],
    [2860, 40],
    [2690, 30],
    [2520, 20],
    [2350, 10],
  ],
  'F12_lung': [
    [3400, 100],
    [3350, 95],
    [3300, 90],
    [3150, 85],
    [3000, 80],
    [2900, 78],
    [2800, 76],
    [2700, 74],
    [2600, 72],
    [2500, 70],
    [2400, 68],
    [2300, 66],
    [2200, 64],
    [2100, 62],
    [2000, 60],
    [1960, 50],
    [1920, 40],
    [1880, 30],
    [1840, 20],
    [1800, 10],
  ],
  'F34_lung': [
    [3450, 100],
    [3400, 95],
    [3350, 90],
    [3200, 85],
    [3050, 80],
    [2950, 78],
    [2850, 76],
    [2750, 74],
    [2650, 72],
    [2550, 70],
    [2450, 68],
    [2350, 66],
    [2250, 64],
    [2150, 62],
    [2050, 60],
    [2010, 50],
    [1970, 40],
    [1930, 30],
    [1890, 20],
    [1850, 10],
  ],
  'M12_reach': [
    [24.9, 100],
    [23.1, 95],
    [21.3, 90],
    [19.5, 85],
    [17.7, 80],
    [16.3, 78],
    [14.9, 76],
    [13.5, 74],
    [12.1, 72],
    [10.7, 70],
    [9.3, 68],
    [7.9, 66],
    [6.5, 64],
    [5.1, 62],
    [3.7, 60],
    [2.7, 50],
    [1.7, 40],
    [0.7, 30],
    [-0.3, 20],
    [-1.3, 10],
  ],
  'M34_reach': [
    [25.1, 100],
    [23.3, 95],
    [21.5, 90],
    [19.9, 85],
    [18.2, 80],
    [16.8, 78],
    [15.4, 76],
    [14.0, 74],
    [12.6, 72],
    [11.2, 70],
    [9.8, 68],
    [8.4, 66],
    [7.0, 64],
    [5.6, 62],
    [4.2, 60],
    [3.2, 50],
    [2.2, 40],
    [1.2, 30],
    [0.2, 20],
    [-0.8, 10],
  ],
  'F12_reach': [
    [25.8, 100],
    [24.0, 95],
    [22.2, 90],
    [20.6, 85],
    [19.0, 80],
    [17.7, 78],
    [16.4, 76],
    [15.1, 74],
    [13.8, 72],
    [12.5, 70],
    [11.2, 68],
    [9.9, 66],
    [8.6, 64],
    [7.3, 62],
    [6.0, 60],
    [5.2, 50],
    [4.4, 40],
    [3.6, 30],
    [2.8, 20],
    [2.0, 10],
  ],
  'F34_reach': [
    [26.3, 100],
    [24.4, 95],
    [22.4, 90],
    [21.0, 85],
    [19.5, 80],
    [18.2, 78],
    [16.9, 76],
    [15.6, 74],
    [14.3, 72],
    [13.0, 70],
    [11.7, 68],
    [10.4, 66],
    [9.1, 64],
    [7.8, 62],
    [6.5, 60],
    [5.7, 50],
    [4.9, 40],
    [4.1, 30],
    [3.3, 20],
    [2.5, 10],
  ],
  'M12_jump': [
    [273, 100],
    [268, 95],
    [263, 90],
    [256, 85],
    [248, 80],
    [244, 78],
    [240, 76],
    [236, 74],
    [232, 72],
    [228, 70],
    [224, 68],
    [220, 66],
    [216, 64],
    [212, 62],
    [208, 60],
    [203, 50],
    [198, 40],
    [193, 30],
    [188, 20],
    [183, 10],
  ],
  'M34_jump': [
    [275, 100],
    [270, 95],
    [265, 90],
    [258, 85],
    [250, 80],
    [246, 78],
    [242, 76],
    [238, 74],
    [234, 72],
    [230, 70],
    [226, 68],
    [222, 66],
    [218, 64],
    [214, 62],
    [210, 60],
    [205, 50],
    [200, 40],
    [195, 30],
    [190, 20],
    [185, 10],
  ],
  'F12_jump': [
    [207, 100],
    [201, 95],
    [195, 90],
    [188, 85],
    [181, 80],
    [178, 78],
    [175, 76],
    [172, 74],
    [169, 72],
    [166, 70],
    [163, 68],
    [160, 66],
    [157, 64],
    [154, 62],
    [151, 60],
    [146, 50],
    [141, 40],
    [136, 30],
    [131, 20],
    [126, 10],
  ],
  'F34_jump': [
    [208, 100],
    [202, 95],
    [196, 90],
    [189, 85],
    [182, 80],
    [179, 78],
    [176, 76],
    [173, 74],
    [170, 72],
    [167, 70],
    [164, 68],
    [161, 66],
    [158, 64],
    [155, 62],
    [152, 60],
    [147, 50],
    [142, 40],
    [137, 30],
    [132, 20],
    [127, 10],
  ],
  // 男引体向上：M12 缺 14(76)、M34 缺 15(76)，已在下方补齐。
  'M12_pu': [
    [19, 100],
    [18, 95],
    [17, 90],
    [16, 85],
    [15, 80],
    [14, 76],
    [13, 72],
    [12, 68],
    [11, 64],
    [10, 60],
    [9, 50],
    [8, 40],
    [7, 30],
    [6, 20],
    [5, 10],
  ],
  'M34_pu': [
    [20, 100],
    [19, 95],
    [18, 90],
    [17, 85],
    [16, 80],
    [15, 76],
    [14, 72],
    [13, 68],
    [12, 64],
    [11, 60],
    [10, 50],
    [9, 40],
    [8, 30],
    [7, 20],
    [6, 10],
  ],
  // 女 1 分钟仰卧起坐
  'F12_pu': [
    [56, 100],
    [54, 95],
    [52, 90],
    [49, 85],
    [46, 80],
    [44, 78],
    [42, 76],
    [40, 74],
    [38, 72],
    [36, 70],
    [34, 68],
    [32, 66],
    [30, 64],
    [28, 62],
    [26, 60],
    [24, 50],
    [22, 40],
    [20, 30],
    [18, 20],
    [16, 10],
  ],
  'F34_pu': [
    [57, 100],
    [55, 95],
    [53, 90],
    [50, 85],
    [47, 80],
    [45, 78],
    [43, 76],
    [41, 74],
    [39, 72],
    [37, 70],
    [35, 68],
    [33, 66],
    [31, 64],
    [29, 62],
    [27, 60],
    [25, 50],
    [23, 40],
    [21, 30],
    [19, 20],
    [17, 10],
  ],
};

const Map<String, List<List<double>>> fitLower = {
  'M12_50': [
    [6.7, 100],
    [6.8, 95],
    [6.9, 90],
    [7.0, 85],
    [7.1, 80],
    [7.3, 78],
    [7.5, 76],
    [7.7, 74],
    [7.9, 72],
    [8.1, 70],
    [8.3, 68],
    [8.5, 66],
    [8.7, 64],
    [8.9, 62],
    [9.1, 60],
    [9.3, 50],
    [9.5, 40],
    [9.7, 30],
    [9.9, 20],
    [10.1, 10],
  ],
  'M34_50': [
    [6.6, 100],
    [6.7, 95],
    [6.8, 90],
    [6.9, 85],
    [7.0, 80],
    [7.2, 78],
    [7.4, 76],
    [7.6, 74],
    [7.8, 72],
    [8.0, 70],
    [8.2, 68],
    [8.4, 66],
    [8.6, 64],
    [8.8, 62],
    [9.0, 60],
    [9.2, 50],
    [9.4, 40],
    [9.6, 30],
    [9.8, 20],
    [10.0, 10],
  ],
  'F12_50': [
    [7.5, 100],
    [7.6, 95],
    [7.7, 90],
    [8.0, 85],
    [8.3, 80],
    [8.5, 78],
    [8.7, 76],
    [8.9, 74],
    [9.1, 72],
    [9.3, 70],
    [9.5, 68],
    [9.7, 66],
    [9.9, 64],
    [10.1, 62],
    [10.3, 60],
    [10.5, 50],
    [10.7, 40],
    [10.9, 30],
    [11.1, 20],
    [11.3, 10],
  ],
  'F34_50': [
    [7.4, 100],
    [7.5, 95],
    [7.6, 90],
    [7.9, 85],
    [8.2, 80],
    [8.4, 78],
    [8.6, 76],
    [8.8, 74],
    [9.0, 72],
    [9.2, 70],
    [9.4, 68],
    [9.6, 66],
    [9.8, 64],
    [10.0, 62],
    [10.2, 60],
    [10.4, 50],
    [10.6, 40],
    [10.8, 30],
    [11.0, 20],
    [11.2, 10],
  ],
  'M12_1000': [
    [197, 100],
    [202, 95],
    [207, 90],
    [214, 85],
    [222, 80],
    [227, 78],
    [232, 76],
    [237, 74],
    [242, 72],
    [247, 70],
    [252, 68],
    [257, 66],
    [262, 64],
    [267, 62],
    [272, 60],
    [292, 50],
    [312, 40],
    [332, 30],
    [352, 20],
    [372, 10],
  ],
  'M34_1000': [
    [195, 100],
    [200, 95],
    [205, 90],
    [212, 85],
    [220, 80],
    [225, 78],
    [230, 76],
    [235, 74],
    [240, 72],
    [245, 70],
    [250, 68],
    [255, 66],
    [260, 64],
    [265, 62],
    [270, 60],
    [290, 50],
    [310, 40],
    [330, 30],
    [350, 20],
    [370, 10],
  ],
  'F12_800': [
    [198, 100],
    [204, 95],
    [210, 90],
    [217, 85],
    [224, 80],
    [229, 78],
    [234, 76],
    [239, 74],
    [244, 72],
    [249, 70],
    [254, 68],
    [259, 66],
    [264, 64],
    [269, 62],
    [274, 60],
    [284, 50],
    [294, 40],
    [304, 30],
    [314, 20],
    [324, 10],
  ],
  'F34_800': [
    [196, 100],
    [202, 95],
    [208, 90],
    [215, 85],
    [222, 80],
    [227, 78],
    [232, 76],
    [237, 74],
    [242, 72],
    [247, 70],
    [252, 68],
    [257, 66],
    [262, 64],
    [267, 62],
    [272, 60],
    [282, 50],
    [292, 40],
    [302, 30],
    [312, 20],
    [322, 10],
  ],
};

/// 根据得分返回等级名（优秀/良好/及格/不及格）。null 返回 '—'。
String scoreLevel(double? s) {
  if (s == null) return '—';
  if (s >= 90) return '优秀';
  if (s >= 80) return '良好';
  if (s >= 60) return '及格';
  return '不及格';
}

/// 根据得分返回等级对应色（与分数色一致：60+ 绿, 50-59 黄, <50 红）。
Color levelColor(BuildContext context, double? s) =>
    _scoreColorStatic(context, s);

Color _scoreColorStatic(BuildContext context, double? s) {
  final colorScheme = Theme.of(context).colorScheme;
  if (s == null) return colorScheme.onSurfaceVariant;
  if (s >= 60) return colorScheme.tertiary;
  if (s >= 50) return colorScheme.primary;
  return colorScheme.error;
}

/// 根据评分表与实测值算单项得分（区间内线性插值）。higherBetter=true 表示越大分越高。
double fitScore(List<List<double>> table, double value, bool higherBetter) {
  if (value.isNaN) return 0;
  if (higherBetter) {
    for (int i = 0; i < table.length; i++) {
      if (value >= table[i][0]) {
        if (i == 0) return table[0][1];
        final hi = table[i - 1];
        final lo = table[i];
        if (value >= hi[0]) return hi[1];
        final t = (value - lo[0]) / (hi[0] - lo[0]);
        return lo[1] + t * (hi[1] - lo[1]);
      }
    }
    // 实测值低于最低阈值（含填 0）：低于最低档不给 10 分保底，记 0 分。
    return 0;
  } else {
    for (int i = 0; i < table.length; i++) {
      if (value <= table[i][0]) {
        if (i == 0) return table[0][1];
        final hi = table[i - 1];
        final lo = table[i];
        if (value <= hi[0]) return hi[1];
        final t = (lo[0] - value) / (lo[0] - hi[0]);
        return lo[1] + t * (hi[1] - lo[1]);
      }
    }
    // 实测值高于最高阈值（含填 0）：高于最高档记 0 分。
    return 0;
  }
}

/// BMI 单项得分（按官方分档，不插值）。
/// 男生：正常 17.9~23.9=100, 低体重 ≤17.8=80, 超重 24.0~27.9=80, 肥胖 ≥28.0=60
/// 女生：正常 17.2~23.9=100, 低体重 ≤17.1=80, 超重 24.0~27.9=80, 肥胖 ≥28.0=60
int bmiScore(double bmi, bool isMale) {
  if (bmi <= 0) return 0;
  // 端点用"半开区间"判定：低体重段含上限，正常段含下限，避免边界值反复。
  // 男生低体重上限 17.8, 女生 17.1；肥胖下限 28.0。
  if (isMale) {
    if (bmi < 17.9) return 80; // 低体重（≤17.8）
    if (bmi <= 23.9) return 100; // 正常 17.9~23.9
    if (bmi < 28.0) return 80; // 超重 24.0~27.9
    return 60; // 肥胖 ≥28.0
  } else {
    if (bmi < 17.2) return 80; // 低体重（≤17.1）
    if (bmi <= 23.9) return 100; // 正常 17.2~23.9
    if (bmi < 28.0) return 80; // 超重 24.0~27.9
    return 60; // 肥胖 ≥28.0
  }
}

class FitnessPage extends StatefulWidget {
  const FitnessPage({super.key});
  @override
  State<FitnessPage> createState() => _FitnessPageState();
}

class _FitItemDef {
  final String key;
  final String label;
  final String unit;
  final double weight;
  final bool higher;
  final bool isRun;
  _FitItemDef(
    this.key,
    this.label,
    this.unit,
    this.weight,
    this.higher, {
    this.isRun = false,
  });
}

class _FitnessPageState extends State<FitnessPage> {
  bool _male = true;
  int _gradeLevel = 1; // 1=大一大二, 2=大三大四
  final _heightCtrl = TextEditingController();
  final _weightCtrl = TextEditingController();
  final _lungCtrl = TextEditingController();
  final _run50Ctrl = TextEditingController();
  final _reachCtrl = TextEditingController();
  final _jumpCtrl = TextEditingController();
  final _puCtrl = TextEditingController();
  final _runMinCtrl = TextEditingController();
  final _runSecCtrl = TextEditingController();

  @override
  void dispose() {
    for (final c in [
      _heightCtrl,
      _weightCtrl,
      _lungCtrl,
      _run50Ctrl,
      _reachCtrl,
      _jumpCtrl,
      _puCtrl,
      _runMinCtrl,
      _runSecCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  double? get _bmi {
    final h = double.tryParse(_heightCtrl.text);
    final w = double.tryParse(_weightCtrl.text);
    if (h == null || w == null || h <= 0) return null;
    final m = h / 100;
    return w / (m * m);
  }

  String get _prefix => '${_male ? 'M' : 'F'}${_gradeLevel == 1 ? '12' : '34'}';

  TextEditingController _ctrlFor(String key) {
    switch (key) {
      case '_lung':
        return _lungCtrl;
      case '_50':
        return _run50Ctrl;
      case '_reach':
        return _reachCtrl;
      case '_jump':
        return _jumpCtrl;
      case '_pu':
        return _puCtrl;
      default:
        return _lungCtrl;
    }
  }

  /// 计算单个项目得分；未填写返回 null。
  double? _itemScore(String key, bool higher, {bool isRun = false}) {
    double? value;
    if (isRun) {
      final m = double.tryParse(_runMinCtrl.text);
      final s = double.tryParse(_runSecCtrl.text);
      if (m == null || s == null) return null;
      value = m * 60 + s;
    } else {
      value = double.tryParse(_ctrlFor(key).text);
    }
    if (value == null) return null;
    // 填 0（或负数）视为未达标/未填，记 0 分；真实体测成绩不会是 0。
    if (value <= 0) return 0;
    final table = (higher ? fitHigher : fitLower)['$_prefix$key'];
    if (table == null) return null;
    return fitScore(table, value, higher);
  }

  /// 体测总成绩（标准分，满分 100）。任一项目未填则返回 null。
  double? get _total {
    final bmi = _bmi;
    if (bmi == null) return null;
    double sum = bmiScore(bmi, _male) * 0.15;
    for (final it in _items) {
      final sc = it.isRun
          ? _itemScore(it.key, it.higher, isRun: true)
          : _itemScore(it.key, it.higher);
      if (sc == null) return null;
      sum += sc * it.weight;
    }
    return sum;
  }

  List<_FitItemDef> get _items {
    if (_male) {
      return [
        _FitItemDef('_lung', '肺活量', 'mL', 0.15, true),
        _FitItemDef('_50', '50米跑', '秒', 0.20, false),
        _FitItemDef('_reach', '坐位体前屈', 'cm', 0.10, true),
        _FitItemDef('_jump', '立定跳远', 'cm', 0.10, true),
        _FitItemDef('_pu', '引体向上', '次', 0.10, true),
        _FitItemDef('_1000', '1000米跑', '分:秒', 0.20, false, isRun: true),
      ];
    }
    return [
      _FitItemDef('_lung', '肺活量', 'mL', 0.15, true),
      _FitItemDef('_50', '50米跑', '秒', 0.20, false),
      _FitItemDef('_reach', '坐位体前屈', 'cm', 0.10, true),
      _FitItemDef('_jump', '立定跳远', 'cm', 0.10, true),
      _FitItemDef('_pu', '1分钟仰卧起坐', '次', 0.10, true),
      _FitItemDef('_800', '800米跑', '分:秒', 0.20, false, isRun: true),
    ];
  }

  Color _scoreColor(BuildContext context, double? s) {
    final colorScheme = Theme.of(context).colorScheme;
    if (s == null) return colorScheme.onSurfaceVariant;
    if (s >= 60) return colorScheme.tertiary;
    if (s >= 50) return colorScheme.primary;
    return colorScheme.error;
  }

  Widget _numField(TextEditingController c, String label, String unit) {
    return TextField(
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        suffixText: unit.isEmpty ? null : unit,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: (_) => setState(() {}),
    );
  }

  Widget _buildItemCard(_FitItemDef it) {
    final score = it.isRun
        ? _itemScore(it.key, it.higher, isRun: true)
        : _itemScore(it.key, it.higher);
    final hasValue = it.isRun
        ? (_runMinCtrl.text.isNotEmpty || _runSecCtrl.text.isNotEmpty)
        : _ctrlFor(it.key).text.isNotEmpty;
    final level = scoreLevel(score);
    final colorScheme = Theme.of(context).colorScheme;
    final scoreCol = _scoreColor(context, score);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    it.label,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (it.isRun)
                    Row(
                      children: [
                        SizedBox(
                          width: 64,
                          child: _numField(_runMinCtrl, '分', ''),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 4),
                          child: Text(':'),
                        ),
                        SizedBox(
                          width: 64,
                          child: _numField(_runSecCtrl, '秒', ''),
                        ),
                      ],
                    )
                  else
                    SizedBox(
                      width: 150,
                      child: _numField(_ctrlFor(it.key), '成绩', it.unit),
                    ),
                ],
              ),
            ),
            // 右侧：得分（上方大）+ 等级（下方小）
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: scoreCol.withAlpha(38),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    hasValue && score != null ? score.toStringAsFixed(0) : '—',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: scoreCol,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  level,
                  style: TextStyle(
                    fontSize: 11,
                    color: scoreCol,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bmi = _bmi;
    final bmiSc = bmi == null ? null : bmiScore(bmi, _male).toDouble();
    final total = _total;
    return Scaffold(
      appBar: AppBar(title: const Text('体测成绩计算器')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '性别',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  ToggleButtons(
                    isSelected: [_male, !_male],
                    onPressed: (i) => setState(() => _male = i == 0),
                    children: const [
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 20),
                        child: Text('男'),
                      ),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 20),
                        child: Text('女'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '年级',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('大一'),
                        selected: _gradeLevel == 1,
                        onSelected: (_) => setState(() => _gradeLevel = 1),
                      ),
                      ChoiceChip(
                        label: const Text('大二'),
                        selected: _gradeLevel == 1,
                        onSelected: (_) => setState(() => _gradeLevel = 1),
                      ),
                      ChoiceChip(
                        label: const Text('大三'),
                        selected: _gradeLevel == 2,
                        onSelected: (_) => setState(() => _gradeLevel = 2),
                      ),
                      ChoiceChip(
                        label: const Text('大四'),
                        selected: _gradeLevel == 2,
                        onSelected: (_) => setState(() => _gradeLevel = 2),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(child: _numField(_heightCtrl, '身高', 'cm')),
                      const SizedBox(width: 10),
                      Expanded(child: _numField(_weightCtrl, '体重', 'kg')),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Text(
                        'BMI：',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        bmi == null ? '—' : bmi.toStringAsFixed(1),
                        style: TextStyle(
                          fontSize: 16,
                          color: _scoreColor(context, bmiSc),
                        ),
                      ),
                      const SizedBox(width: 16),
                      const Text(
                        'BMI得分：',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        bmi == null ? '—' : '${bmiScore(bmi, _male)}',
                        style: TextStyle(
                          fontSize: 16,
                          color: _scoreColor(context, bmiSc),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (bmi != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: _scoreColor(context, bmiSc).withAlpha(38),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            scoreLevel(bmiSc),
                            style: TextStyle(
                              fontSize: 11,
                              color: _scoreColor(context, bmiSc),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '（身高、体重仅用于计算 BMI，不计入体测总分）',
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          for (final it in _items) _buildItemCard(it),
          const SizedBox(height: 12),
          Card(
            color: _scoreColor(context, total).withAlpha(30),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    '体测总成绩',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    total == null ? '待输入完整数据' : total.toStringAsFixed(1),
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: _scoreColor(context, total),
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (total != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: _scoreColor(context, total).withAlpha(51),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '等级 ${scoreLevel(total)}',
                        style: TextStyle(
                          fontSize: 13,
                          color: _scoreColor(context, total),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '评分标准：《国家学生体质健康标准（2014年修订）》大学生组。'
            '总分≥60 绿色，50–59 黄色，<50 红色。单项权重 BMI/肺活量/50米/'
            '坐位体前屈/立定跳远/引体向上(男)或仰卧起坐(女)/1000米(男)或800米(女)'
            ' 分别为 15/15/20/10/10/10/20。',
            style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
