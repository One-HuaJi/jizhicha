import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A credential saved after a successful authentication.
///
/// The values are only serialized into [FlutterSecureStorage], which uses the
/// platform secure-storage implementation (Windows DPAPI on desktop). They
/// are never written to the normal app settings JSON or printed to logs.
class StoredAccount {
  final String username;
  final String password;

  const StoredAccount({required this.username, required this.password});

  Map<String, String> toJson() => {'username': username, 'password': password};
}

enum StoredAccountKind { vpn, education }

bool isEducationPasswordSafeToStore(String password) {
  return password.length >= 8 &&
      RegExp(r'[A-Za-z]').hasMatch(password) &&
      RegExp(r'\d').hasMatch(password);
}

class CredentialStore {
  static const _vpnKey = 'jizhicha.accounts.vpn.v1';
  static const _educationKey = 'jizhicha.accounts.education.v1';
  static const _educationPasswordResetPendingKey =
      'jizhicha.accounts.education.password_reset_pending.v1';
  static const _maxAccounts = 12;

  static final FlutterSecureStorage _storage = FlutterSecureStorage();

  static String _keyFor(StoredAccountKind kind) {
    return kind == StoredAccountKind.vpn ? _vpnKey : _educationKey;
  }

  static Future<List<StoredAccount>> load(StoredAccountKind kind) async {
    try {
      final encoded = await _storage.read(key: _keyFor(kind));
      if (encoded == null || encoded.isEmpty) return const [];

      final decoded = jsonDecode(encoded);
      if (decoded is! List) return const [];

      final accounts = <StoredAccount>[];
      final usernames = <String>{};
      final resetPending = kind == StoredAccountKind.education
          ? await _loadEducationPasswordResetPending()
          : const <String>{};
      var needsRewrite = false;
      for (final item in decoded) {
        if (item is! Map) {
          needsRewrite = true;
          continue;
        }
        final username = item['username']?.toString().trim() ?? '';
        final password = item['password']?.toString() ?? '';
        if (username.isEmpty || password.isEmpty || !usernames.add(username)) {
          needsRewrite = true;
          continue;
        }
        // Old releases could persist the six-digit temporary password. Also,
        // a valid-looking old password becomes invalid immediately after a
        // school-side reset. Never return either value to an autofill field;
        // purge it while reading so the protection also migrates old installs.
        if (kind == StoredAccountKind.education &&
            (!isEducationPasswordSafeToStore(password) ||
                resetPending.contains(username))) {
          needsRewrite = true;
          continue;
        }
        accounts.add(StoredAccount(username: username, password: password));
      }
      final limited = accounts.take(_maxAccounts).toList(growable: false);
      if (limited.length != accounts.length) needsRewrite = true;
      if (needsRewrite) {
        try {
          final key = _keyFor(kind);
          if (limited.isEmpty) {
            await _storage.delete(key: key);
          } else {
            await _storage.write(
              key: key,
              value: jsonEncode(
                limited.map((account) => account.toJson()).toList(),
              ),
            );
          }
        } catch (_) {
          // Returning only the sanitized in-memory list is still mandatory;
          // the next read will retry the persistent cleanup.
        }
      }
      return limited;
    } catch (_) {
      // A secure-storage read failure must not prevent manual login.
      return const [];
    }
  }

  static Future<bool> save(
    StoredAccountKind kind, {
    required String username,
    required String password,
  }) async {
    final normalizedUsername = username.trim();
    if (normalizedUsername.isEmpty || password.isEmpty) return false;

    // 学校“忘记密码”会把密码临时重置为身份证后六位；最终密码则要求
    // 至少 8 位且同时包含字母和数字。凡是不满足最终规则的教务密码都不
    // 允许进入安全存储，并清除同账号旧值，形成第二道防误保存保护。
    if (kind == StoredAccountKind.education &&
        !isEducationPasswordSafeToStore(password)) {
      await deleteAccount(kind, username: normalizedUsername);
      return false;
    }

    try {
      final existing = await load(kind);
      final account = StoredAccount(
        username: normalizedUsername,
        password: password,
      );
      final updated = <StoredAccount>[
        account,
        ...existing.where((item) => item.username != normalizedUsername),
      ].take(_maxAccounts);
      await _storage.write(
        key: _keyFor(kind),
        value: jsonEncode(updated.map((item) => item.toJson()).toList()),
      );
      return true;
    } catch (_) {
      // The login result remains valid even if the optional local save fails.
      return false;
    }
  }

  /// 删除指定账号已经保存的密码，不影响同类型的其他账号。
  static Future<bool> deleteAccount(
    StoredAccountKind kind, {
    required String username,
  }) async {
    final normalizedUsername = username.trim();
    if (normalizedUsername.isEmpty) return false;
    final key = _keyFor(kind);
    try {
      final existing = await load(kind);
      final remaining = existing
          .where((account) => account.username != normalizedUsername)
          .toList(growable: false);
      if (remaining.isEmpty) {
        await _storage.delete(key: key);
      } else {
        await _storage.write(
          key: key,
          value: jsonEncode(
            remaining.map((account) => account.toJson()).toList(),
          ),
        );
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<Set<String>> _loadEducationPasswordResetPending() async {
    try {
      final encoded = await _storage.read(
        key: _educationPasswordResetPendingKey,
      );
      if (encoded == null || encoded.isEmpty) return <String>{};
      final decoded = jsonDecode(encoded);
      if (decoded is! List) return <String>{};
      return decoded
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Future<bool> _writeEducationPasswordResetPending(
    Set<String> accounts,
  ) async {
    try {
      if (accounts.isEmpty) {
        await _storage.delete(key: _educationPasswordResetPendingKey);
      } else {
        await _storage.write(
          key: _educationPasswordResetPendingKey,
          value: jsonEncode(accounts.toList(growable: false)),
        );
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 标记该账号刚完成“身份证后六位”重置。标记存在期间，登录页不会保存
  /// 临时密码；只有最终强密码设置成功后才会清除。
  static Future<bool> markEducationPasswordResetPending(String username) async {
    final normalized = username.trim();
    if (normalized.isEmpty) return false;
    final accounts = await _loadEducationPasswordResetPending();
    accounts.add(normalized);
    return _writeEducationPasswordResetPending(accounts);
  }

  static Future<bool> isEducationPasswordResetPending(String username) async {
    final normalized = username.trim();
    if (normalized.isEmpty) return false;
    final accounts = await _loadEducationPasswordResetPending();
    return accounts.contains(normalized);
  }

  static Future<bool> clearEducationPasswordResetPending(
    String username,
  ) async {
    final normalized = username.trim();
    if (normalized.isEmpty) return false;
    final accounts = await _loadEducationPasswordResetPending();
    accounts.remove(normalized);
    return _writeEducationPasswordResetPending(accounts);
  }

  /// 密码重置成功后的原子化安全收尾：先删除旧教务密码，再写入“待设置
  /// 最终密码”标记。若按账号删除失败，会尝试清空全部教务凭据作为兜底，
  /// 但不会碰加速器账号。
  static Future<bool> invalidateEducationPassword(String username) async {
    final normalized = username.trim();
    if (normalized.isEmpty) return false;
    var deleted = await deleteAccount(
      StoredAccountKind.education,
      username: normalized,
    );
    if (!deleted) {
      try {
        await _storage.delete(key: _educationKey);
        deleted = true;
      } catch (_) {
        deleted = false;
      }
    }
    final marked = await markEducationPasswordResetPending(normalized);
    return deleted && marked;
  }

  /// 删除所有由本应用保存的账号密码。
  ///
  /// 仅删除 FlutterSecureStorage（Windows 上为 DPAPI）中的 VPN / 教务凭据；
  /// 调用方可按需要同时清理与账号关联的普通本地缓存。
  static Future<bool> deleteAll() async {
    try {
      await _storage.delete(key: _vpnKey);
      await _storage.delete(key: _educationKey);
      await _storage.delete(key: _educationPasswordResetPendingKey);
      return true;
    } catch (_) {
      return false;
    }
  }
}
