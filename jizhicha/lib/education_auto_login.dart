// 教务系统「自动重新认证」：课表页与成绩页共用的一份实现。
//
// 需求来源：只有在刷新课表 / 刷新成绩时才认证教务系统，并且尽量让用户无感。
// 做法：用本机已保存的教务凭据，配合本机 OCR 识别验证码，直接完成一次登录；
// 任何环节没法自动完成时，返回一个带原因的结果，由调用方回落到手动认证页。
//
// 隐私：本模块不写任何日志；密码与验证码只存在于函数局部变量里，不落盘、
// 不外发，也不会出现在返回给用户的文案中。
import 'dart:async' show TimeoutException;
import 'dart:io' show Platform;
import 'dart:typed_data' show Uint8List;

import 'package:dio/dio.dart' show DioException;

import 'app_settings.dart';
import 'captcha_ocr.dart';
import 'credential_store.dart';
import 'jwxt_client.dart';

/// 一次自动登录里最多提交几次。
///
/// 刻意压到 3 次：学校网关对连续失败登录有风控，而验证码识别失败本身就是
/// 常态，不能靠"多试几次"去换成功率。3 次之内不成功就交给用户手动处理。
const int _maxAutoLoginAttempts = 3;

/// 取验证码的超时（与教务登录页手动取图的超时保持一致）。
const Duration _captchaTimeout = Duration(seconds: 10);

/// 提交登录的超时。学校网关偶发慢，这里给足时间；真超时也只是回落到手动页。
const Duration _loginTimeout = Duration(seconds: 30);

/// 自动重新认证的失败原因。
///
/// 调用方只需要用 [AutoLoginFailure.message] 做提示；分出枚举是为了让
/// "为什么必须手动登录"这件事可判定、可回归，而不是靠文案猜。
enum AutoLoginFailureReason {
  /// 本机没有保存该学号的教务密码。
  noSavedCredential,

  /// 该学号的教务密码正处于「忘记密码」重置流程（只有临时密码）。
  passwordResetPending,

  /// 用户在设置里关闭了「验证码自动识别」。
  ocrDisabled,

  /// 当前平台没有 OCR 实现（目前只有 Android / Windows 有）。
  ocrUnsupportedPlatform,

  /// 校园网（加速器隧道）尚未就绪。
  campusNotReady,

  /// 连续多次都没能把验证码识别成完整四位。
  captchaUnrecognized,

  /// 验证码被学校判为错误，换新图重试后仍然失败。
  captchaRejected,

  /// 学校拒绝了账号密码，或返回了无法识别为登录成功的页面。
  loginRejected,

  /// 学校要求先设置新密码（临时密码的既有规则）。
  passwordChangeRequired,

  /// 网络层失败（超时等）。
  networkError,
}

/// [tryAutoEducationLogin] 的结果。
sealed class AutoLoginResult {
  const AutoLoginResult();
}

/// 自动登录成功：教务会话已经可以复用，调用方按原流程继续同步即可。
final class AutoLoginSuccess extends AutoLoginResult {
  const AutoLoginSuccess();
}

/// 无法自动登录，需要用户手动介入。
final class AutoLoginFailure extends AutoLoginResult {
  final AutoLoginFailureReason reason;

  /// 可直接展示给用户的中文原因，不含账号、密码、验证码等隐私信息。
  final String message;

  const AutoLoginFailure(this.reason, this.message);
}

/// 尝试用本机保存的教务凭据自动重新登录。
///
/// 返回 [AutoLoginSuccess] 表示教务会话已经可用；返回 [AutoLoginFailure]
/// 表示需要用户手动介入，其中 `message` 可以直接作为
/// `VpnSetupPage(initialNotice: ...)` 的文案。
///
/// 约束（调用方需要知道）：
///   - 本函数**不会**断开校园网，也不影响已经建立的加速器隧道；
///   - 本函数不抛异常，任何意外都会变成一个 [AutoLoginFailure]；
///   - 每轮都用**新**验证码图，最多提交 [_maxAutoLoginAttempts] 次。
Future<AutoLoginResult> tryAutoEducationLogin({
  required String studentId,
}) async {
  final normalizedId = studentId.trim();
  if (normalizedId.isEmpty) {
    return const AutoLoginFailure(
      AutoLoginFailureReason.noSavedCredential,
      '本机没有该学号的教务密码，请手动登录教务系统',
    );
  }

  // 1) 先看用户设置：关掉「验证码自动识别」就等于关掉了自动登录。自动登录
  //    必须靠 OCR 读验证码，没有它就只能手动，绝不能绕过用户的显式选择。
  final settings = await AppSettings.load();
  if (!settings.captchaOcrEnabled) {
    return const AutoLoginFailure(
      AutoLoginFailureReason.ocrDisabled,
      '已关闭验证码自动识别，请手动登录教务系统',
    );
  }

  // 2) OCR 只有 Android / Windows 有实现，其它平台不必白发一次验证码请求。
  if (!Platform.isAndroid && !Platform.isWindows) {
    return const AutoLoginFailure(
      AutoLoginFailureReason.ocrUnsupportedPlatform,
      '当前平台不支持验证码自动识别，请手动登录教务系统',
    );
  }

  // 3) 「忘记密码」重置期间本机只可能留着身份证后六位的临时密码。沿用
  //    CredentialStore 的既有闸门：既不把它当成可用凭据，也先给一个明确
  //    原因，让用户知道要做什么。
  if (await CredentialStore.isEducationPasswordResetPending(normalizedId)) {
    return const AutoLoginFailure(
      AutoLoginFailureReason.passwordResetPending,
      '教务密码正在重置，请手动登录并设置新密码',
    );
  }

  // 4) 取本机保存的凭据。load() 内部已经剔除了不合规密码和"待重设"账号，
  //    所以这里拿到的密码一定是规则合法的最终密码；取不到就不能自动登录。
  final accounts = await CredentialStore.load(StoredAccountKind.education);
  StoredAccount? account;
  for (final candidate in accounts) {
    if (candidate.username == normalizedId) {
      account = candidate;
      break;
    }
  }
  if (account == null) {
    return const AutoLoginFailure(
      AutoLoginFailureReason.noSavedCredential,
      '本机没有保存该学号的教务密码，请手动登录教务系统',
    );
  }

  final client = JwxtClient();
  // 用干净的教务会话开始，避免把上一个账号的 Cookie 带进这次登录。
  // resetSession() 只清教务 Cookie，**不会**断开校园加速器（见其文档注释），
  // 因此不影响"全程保持校园网连接"。
  try {
    await client.resetSession();
  } catch (_) {
    // 清会话失败不影响后续登录尝试，继续。
  }

  var sawCaptchaRejection = false;
  for (var attempt = 0; attempt < _maxAutoLoginAttempts; attempt++) {
    // 关键：每一轮都重新取一张**新**验证码图。学校在提交后会作废旧验证码，
    // 拿同一张图重复提交既不可能成功，也容易触发风控。
    final Uint8List captchaBytes;
    try {
      captchaBytes = await client.getCaptcha().timeout(_captchaTimeout);
    } on TimeoutException {
      return const AutoLoginFailure(
        AutoLoginFailureReason.networkError,
        '获取教务验证码超时，请手动登录教务系统',
      );
    } catch (error) {
      return _failureFrom(error);
    }

    String? code;
    try {
      code = await CaptchaOcr.recognize(captchaBytes);
    } catch (_) {
      // OCR 只是便捷能力：模型缺失、设备 ABI 不支持、原生运行时异常，都按
      // "这次没识别出来"处理，换下一张图继续，绝不因此把错误抛给用户。
      code = null;
    }
    if (code == null || code.isEmpty) continue;

    final JwxtLoginResult loginResult;
    try {
      loginResult = await client
          .login(normalizedId, account.password, code)
          .timeout(_loginTimeout);
    } on TimeoutException {
      return const AutoLoginFailure(
        AutoLoginFailureReason.networkError,
        '登录教务系统超时，请手动重试',
      );
    } catch (error) {
      if (_looksLikeCaptchaProblem(_describeError(error))) {
        // 学校判验证码错：换一张新图再来（下一轮开头会重新取图）。
        sawCaptchaRejection = true;
        continue;
      }
      return _failureFrom(error);
    }

    switch (loginResult.status) {
      case JwxtLoginStatus.success:
        return const AutoLoginSuccess();
      case JwxtLoginStatus.passwordChangeRequired:
        // 学校要求设置最终密码，必须由用户操作，自动流程到此为止。
        return const AutoLoginFailure(
          AutoLoginFailureReason.passwordChangeRequired,
          '教务系统要求先设置新密码，请手动完成',
        );
    }
  }

  // 次数用尽。区分"没识别出来"和"识别出来但学校不认"，两种给用户的
  // 下一步其实一样（手动输入），但原因不同，便于排查。
  if (sawCaptchaRejection) {
    return const AutoLoginFailure(
      AutoLoginFailureReason.captchaRejected,
      '验证码多次未通过校验，请手动登录教务系统',
    );
  }
  return const AutoLoginFailure(
    AutoLoginFailureReason.captchaUnrecognized,
    '验证码自动识别未成功，请手动输入验证码',
  );
}

/// 从异常里取出**可以安全展示**的原因文本，取不到就返回空串。
///
/// `JwxtClient` 主动抛出的中文说明是写给用户看的；其余异常（Socket /
/// Dio 原始错误）可能带内部地址或英文堆栈，一律不外显。
String _describeError(Object error) {
  if (error is String) return error;
  if (error is DioException) {
    final inner = error.error;
    if (inner is String) return inner;
  }
  return '';
}

/// 判断这句话是不是"验证码被学校判错"。
///
/// 学校会在 showMsg 里写"验证码错误"之类；而通用兜底文案
/// 「教务登录失败：请检查教务密码和验证码」同时含"密码"，那更像账号密码
/// 问题，不能拿它当验证码错误去反复重试。
bool _looksLikeCaptchaProblem(String text) =>
    text.contains('验证码') && !text.contains('密码');

/// 把一次异常翻译成带原因的失败结果。
AutoLoginFailure _failureFrom(Object error) {
  final text = _describeError(error);
  if (text.contains('校园网尚未就绪') || text.contains('无法连接校园网')) {
    return const AutoLoginFailure(
      AutoLoginFailureReason.campusNotReady,
      '校园网尚未就绪，请先连接校园加速器',
    );
  }
  if (_looksLikeCaptchaProblem(text)) {
    return const AutoLoginFailure(
      AutoLoginFailureReason.captchaRejected,
      '验证码未通过校验，请手动输入验证码',
    );
  }
  if (text.isEmpty) {
    return const AutoLoginFailure(
      AutoLoginFailureReason.networkError,
      '连接教务系统失败，请检查校园网后重试',
    );
  }
  return const AutoLoginFailure(
    AutoLoginFailureReason.loginRejected,
    '自动登录教务系统未成功，请手动确认账号密码',
  );
}
