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

class CredentialStore {
  static const _vpnKey = 'jizhicha.accounts.vpn.v1';
  static const _educationKey = 'jizhicha.accounts.education.v1';
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
      for (final item in decoded) {
        if (item is! Map) continue;
        final username = item['username']?.toString().trim() ?? '';
        final password = item['password']?.toString() ?? '';
        if (username.isEmpty || password.isEmpty || !usernames.add(username)) {
          continue;
        }
        accounts.add(StoredAccount(username: username, password: password));
      }
      return accounts.take(_maxAccounts).toList(growable: false);
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

  /// 删除所有由本应用保存的账号密码。
  ///
  /// 仅删除 FlutterSecureStorage（Windows 上为 DPAPI）中的 VPN / 教务凭据；
  /// 调用方可按需要同时清理与账号关联的普通本地缓存。
  static Future<bool> deleteAll() async {
    try {
      await _storage.delete(key: _vpnKey);
      await _storage.delete(key: _educationKey);
      return true;
    } catch (_) {
      return false;
    }
  }
}
