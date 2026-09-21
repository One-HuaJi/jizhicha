import 'dart:convert';
import 'dart:io' show ContentType, HttpClient, InternetAddress, Socket;
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' show parse;

import 'academic_calendar.dart';
import 'credential_store.dart';

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
                error: '无法连接校园内网，请确认已连接校园加速器后重试',
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
      // 用户视角只需要知道"校园网没就绪、要重新连"，不需要"网关身份校验""隧道"
      // 这些实现概念。
      throw '校园网尚未就绪，请先连接校园加速器后重试';
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

  /// 轮询内网可达性，直到成功或超时。
  ///
  /// ⚠️ **预算必须给足。** 真机实测（Redmi K80 Pro / 校园网）：隧道建立后
  /// 教务端点需要 **6～9 秒**才开始响应，个别情况下超过 30 秒。
  /// 期间 `curl` 返回 `000`（连接被网关丢弃），随后突然变成 `200`。
  ///
  /// 这不是"网络不好"，而是**学校网关在为新会话做后端准备**：隧道/TLS 层
  /// 已经通了，但网关到教务系统的转发链路还没就绪。属于必然经历的阶段，
  /// 不该判定为失败。
  ///
  /// 因此这里默认给 **45 秒**（每次探测 5 秒 + 间隔 1 秒，约 7 次机会），
  /// 并允许调用方通过 [onTick] 展示进度 —— 让用户看到"正在等待网关准备"，
  /// 而不是盯着转圈以为卡死了。
  Future<bool> waitForIntranet({
    Duration timeout = const Duration(seconds: 45),
    void Function(int attempt, int maxAttempts)? onTick,
  }) async {
    const perProbe = Duration(seconds: 5);
    const gap = Duration(milliseconds: 1000);
    final deadline = DateTime.now().add(timeout);
    var attempt = 0;
    while (DateTime.now().isBefore(deadline)) {
      attempt += 1;
      if (await checkIntranetReachable(timeout: perProbe)) return true;
      onTick?.call(attempt, 7);
      if (!DateTime.now().add(gap).isBefore(deadline)) break;
      await Future<void>.delayed(gap);
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
        absolute!.host != _hostAddress &&
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
          // 旧版「疑似会话失效」既有"疑似"又是术语，建议直接说结论与做法。
          ? '（登录状态可能已失效，请退出后重新登录）'
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

    // 显式报错，避免静默吞掉。
    // 不把 HTTP 状态码给用户看：普通用户不知道 500/404 意味着什么，
    // 只给"可能要重新登录"这个可执行动作。（状态码仍可从 debug 日志排查。）
    if (res.statusCode != 200) {
      throw '课表查询失败，可能需要重新登录后再试';
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
