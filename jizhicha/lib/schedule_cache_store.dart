import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 用本次成功返回的学期成绩替换本地对应学期，同时保留其他学期。
///
/// [replacedTerms] 只应包含服务器返回了有效成绩表的学期；请求失败的学期
/// 不在集合中，因此它们的旧缓存会继续保留。
List<Map<String, String>> mergeGradesByTerms({
  required Iterable<Map<String, String>> previous,
  required Iterable<Map<String, String>> fetched,
  required Iterable<String> replacedTerms,
}) {
  final terms = replacedTerms
      .map((term) => term.trim())
      .where((term) => term.isNotEmpty)
      .toSet();
  final merged = <Map<String, String>>[];
  for (final grade in previous) {
    final term = (grade['term'] ?? '').trim();
    if (!terms.contains(term)) {
      merged.add(Map<String, String>.from(grade));
    }
  }
  for (final grade in fetched) {
    merged.add(Map<String, String>.from(grade));
  }
  return merged;
}

/// 一个账号最近一次成功获取的学期课表。
///
/// 这份缓存只保存课表字段、学号和保存时间；账号密码仍只保存在
/// [CredentialStore] 使用的系统安全存储中，不会写入这个普通 JSON 文件。
class CachedSchedule {
  final String studentId;
  final String term;
  final DateTime savedAt;
  final List<Map<String, String>> courses;

  const CachedSchedule({
    required this.studentId,
    required this.term,
    required this.savedAt,
    required this.courses,
  });

  Map<String, dynamic> toJson() => {
    'studentId': studentId,
    'term': term,
    'savedAt': savedAt.toIso8601String(),
    'courses': courses,
  };

  static CachedSchedule? fromJson(Object? value) {
    if (value is! Map) return null;
    final studentId = value['studentId']?.toString().trim() ?? '';
    final term = value['term']?.toString().trim() ?? '';
    if (studentId.isEmpty || term.isEmpty) return null;

    final rawCourses = value['courses'];
    final courses = <Map<String, String>>[];
    if (rawCourses is List) {
      for (final rawCourse in rawCourses) {
        if (rawCourse is! Map) continue;
        final course = <String, String>{};
        rawCourse.forEach((key, field) {
          if (field != null) course[key.toString()] = field.toString();
        });
        if (course.isNotEmpty) courses.add(course);
      }
    }

    final savedAt =
        DateTime.tryParse(value['savedAt']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    return CachedSchedule(
      studentId: studentId,
      term: term,
      savedAt: savedAt,
      courses: courses,
    );
  }
}

/// 按教务学号保存“最近一次成功读取”的课表。
///
/// 缓存落在用户 APPDATA 下，允许离线查看；它不会触发任何网络请求。
class ScheduleCacheStore {
  static const _fileName = 'jizhicha_schedule_cache.json';
  static const _schemaVersion = 1;

  static Future<File> _file() async {
    // 与 UserDataCacheStore / AppSettings 走同一套平台分支，
    // 避免 Android 上落到只读根目录。
    if (Platform.isWindows) {
      final base =
          Platform.environment['APPDATA'] ??
          Platform.environment['HOME'] ??
          Directory.current.path;
      final folder = Directory(base);
      try {
        if (!await folder.exists()) await folder.create(recursive: true);
      } catch (_) {}
      return File('$base${Platform.pathSeparator}$_fileName');
    }
    final dir = await getApplicationDocumentsDirectory();
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  static Future<Map<String, dynamic>> _readRoot() async {
    try {
      final file = await _file();
      if (!await file.exists()) return <String, dynamic>{};
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // 损坏的课表缓存不能阻止用户重新认证和查询。
    }
    return <String, dynamic>{};
  }

  static Future<void> _writeRoot(Map<String, dynamic> root) async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(root));
    } catch (_) {
      // 缓存写入失败时，在线查询结果仍然可正常展示。
    }
  }

  static Future<CachedSchedule?> loadLatest(String studentId) async {
    final normalized = studentId.trim();
    if (normalized.isEmpty) return null;
    final root = await _readRoot();
    final accounts = root['accounts'];
    if (accounts is! Map) return null;
    return CachedSchedule.fromJson(accounts[normalized]);
  }

  static Future<void> saveLatest({
    required String studentId,
    required String term,
    required List<Map<String, String>> courses,
  }) async {
    final normalized = studentId.trim();
    if (normalized.isEmpty || term.trim().isEmpty) return;

    final root = await _readRoot();
    final rawAccounts = root['accounts'];
    final accounts = rawAccounts is Map
        ? Map<String, dynamic>.from(rawAccounts)
        : <String, dynamic>{};
    accounts[normalized] = CachedSchedule(
      studentId: normalized,
      term: term.trim(),
      savedAt: DateTime.now(),
      courses: courses
          .map((course) => Map<String, String>.from(course))
          .toList(growable: false),
    ).toJson();
    root
      ..['_v'] = _schemaVersion
      ..['accounts'] = accounts;
    await _writeRoot(root);
  }

  static Future<void> deleteForAccount(String studentId) async {
    final normalized = studentId.trim();
    if (normalized.isEmpty) return;
    final root = await _readRoot();
    final rawAccounts = root['accounts'];
    if (rawAccounts is! Map) return;
    final accounts = Map<String, dynamic>.from(rawAccounts);
    accounts.remove(normalized);
    root
      ..['_v'] = _schemaVersion
      ..['accounts'] = accounts;
    await _writeRoot(root);
  }

  static Future<bool> clearAll() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
      return !await file.exists();
    } catch (_) {
      return false;
    }
  }
}

/// 一个教务账号完整的离线快照索引。
class CachedUserData {
  final String studentId;
  final DateTime savedAt;
  final List<String> scheduleTerms;
  final bool hasGrades;

  const CachedUserData({
    required this.studentId,
    required this.savedAt,
    required this.scheduleTerms,
    required this.hasGrades,
  });

  static CachedUserData? fromJson(Object? value) {
    if (value is! Map) return null;
    final studentId = value['studentId']?.toString().trim() ?? '';
    if (studentId.isEmpty) return null;
    final rawTerms = value['scheduleTerms'];
    final terms = rawTerms is List
        ? rawTerms
              .map((term) => term.toString().trim())
              .where((term) => term.isNotEmpty)
              .toList(growable: false)
        : const <String>[];
    return CachedUserData(
      studentId: studentId,
      savedAt:
          DateTime.tryParse(value['savedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      scheduleTerms: terms,
      hasGrades: value['hasGrades'] == true,
    );
  }
}

/// 每个账号各自独立的完整离线数据目录。
///
/// 目录结构：
///
/// ```text
/// %APPDATA%/jizhicha_offline/<账号安全目录名>/
///   profile.json
///   grades.json
///   schedules/<学期安全文件名>.html
/// ```
///
/// 课表保留校园教务返回的原始静态 HTML，展示时再在本机解析；成绩保存为
/// JSON。打开主页不会访问校园网。
class UserDataCacheStore {
  static const _rootFolderName = 'jizhicha_offline';
  static const _profileFileName = 'profile.json';
  static const _gradesFileName = 'grades.json';
  static const _schemaVersion = 1;

  static String _safeName(String value) =>
      base64Url.encode(utf8.encode(value.trim())).replaceAll('=', '');

  static Future<Directory> _root() async {
    final Directory root;
    if (Platform.isWindows) {
      // Windows 沿用 %APPDATA% 路径，保持现有用户数据兼容。
      final base =
          Platform.environment['APPDATA'] ??
          Platform.environment['HOME'] ??
          Directory.current.path;
      root = Directory('$base${Platform.pathSeparator}$_rootFolderName');
    } else {
      // Android / Linux 必须写到应用沙盒目录，
      // 否则会落到只读根目录而报 FileSystemException(Read-only)。
      final dir = await getApplicationDocumentsDirectory();
      root = Directory('${dir.path}${Platform.pathSeparator}$_rootFolderName');
    }
    if (!await root.exists()) await root.create(recursive: true);
    return root;
  }

  static Future<Directory> _accountDirectory(String studentId) async {
    final root = await _root();
    return Directory(
      '${root.path}${Platform.pathSeparator}${_safeName(studentId)}',
    );
  }

  /// Resolve an interrupted recoverable write. `.next` is a fully flushed new
  /// file; `.bak` is the last known-good version retained while it is swapped.
  static Future<File?> _readableFile(File target) async {
    if (await target.exists()) return target;
    final next = File('${target.path}.next');
    final backup = File('${target.path}.bak');
    if (await next.exists()) {
      try {
        await next.rename(target.path);
        if (await backup.exists()) await backup.delete();
        return target;
      } catch (_) {
        // Fall back to the previous snapshot below.
      }
    }
    if (await backup.exists()) {
      try {
        await backup.rename(target.path);
        return target;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Write through a flushed staging file and retain the previous version
  /// until the replacement is complete. This prevents a power loss or forced
  /// process exit from leaving a truncated JSON/HTML cache.
  static Future<void> _writeRecoverably(File target, String contents) async {
    if (!await target.parent.exists()) {
      await target.parent.create(recursive: true);
    }
    final next = File('${target.path}.next');
    final backup = File('${target.path}.bak');
    await next.writeAsString(contents, flush: true);

    if (await backup.exists()) await backup.delete();
    var previousMoved = false;
    try {
      if (await target.exists()) {
        await target.rename(backup.path);
        previousMoved = true;
      }
      await next.rename(target.path);
      if (previousMoved && await backup.exists()) await backup.delete();
    } catch (_) {
      if (!await target.exists() && await backup.exists()) {
        try {
          await backup.rename(target.path);
        } catch (_) {
          // Preserve both recovery files for the next startup if restore fails.
        }
      }
      rethrow;
    } finally {
      if (await next.exists()) {
        try {
          await next.delete();
        } catch (_) {}
      }
    }
  }

  static Future<CachedUserData?> loadProfile(String studentId) async {
    final normalized = studentId.trim();
    if (normalized.isEmpty) return null;
    try {
      final account = await _accountDirectory(normalized);
      final profile = File(
        '${account.path}${Platform.pathSeparator}$_profileFileName',
      );
      final readable = await _readableFile(profile);
      if (readable == null) return null;
      return CachedUserData.fromJson(jsonDecode(await readable.readAsString()));
    } catch (_) {
      return null;
    }
  }

  static Future<String?> loadScheduleHtml(String studentId, String term) async {
    final normalized = studentId.trim();
    final normalizedTerm = term.trim();
    if (normalized.isEmpty || normalizedTerm.isEmpty) return null;
    try {
      final account = await _accountDirectory(normalized);
      final file = File(
        '${account.path}${Platform.pathSeparator}schedules'
        '${Platform.pathSeparator}${_safeName(normalizedTerm)}.html',
      );
      final readable = await _readableFile(file);
      return readable == null ? null : await readable.readAsString();
    } catch (_) {
      return null;
    }
  }

  static Future<List<Map<String, String>>> loadGrades(String studentId) async {
    final normalized = studentId.trim();
    if (normalized.isEmpty) return const [];
    try {
      final account = await _accountDirectory(normalized);
      final file = File(
        '${account.path}${Platform.pathSeparator}$_gradesFileName',
      );
      final readable = await _readableFile(file);
      if (readable == null) return const [];
      final decoded = jsonDecode(await readable.readAsString());
      if (decoded is! List) return const [];
      final grades = <Map<String, String>>[];
      for (final rawGrade in decoded) {
        if (rawGrade is! Map) continue;
        final grade = <String, String>{};
        rawGrade.forEach((key, value) {
          if (value != null) grade[key.toString()] = value.toString();
        });
        if (grade.isNotEmpty) grades.add(grade);
      }
      return grades;
    } catch (_) {
      return const [];
    }
  }

  /// 合并保存本次成功获取的数据。默认保留已有课表；传入
  /// [replaceSchedules] 时，先写入新的最新学期，再清理旧学期文件。
  static Future<void> saveSnapshot({
    required String studentId,
    required Map<String, String> scheduleHtmlByTerm,
    required List<Map<String, String>> grades,
    required bool replaceGrades,
    Iterable<String> replaceGradeTerms = const [],
    bool replaceSchedules = false,
  }) async {
    final normalized = studentId.trim();
    if (normalized.isEmpty) return;

    final account = await _accountDirectory(normalized);
    if (!await account.exists()) await account.create(recursive: true);
    final schedules = Directory(
      '${account.path}${Platform.pathSeparator}schedules',
    );
    if (!await schedules.exists()) await schedules.create(recursive: true);

    final previous = await loadProfile(normalized);
    final terms = <String>{...?previous?.scheduleTerms};
    for (final entry in scheduleHtmlByTerm.entries) {
      final term = entry.key.trim();
      if (term.isEmpty || entry.value.isEmpty) continue;
      final file = File(
        '${schedules.path}${Platform.pathSeparator}${_safeName(term)}.html',
      );
      await _writeRecoverably(file, entry.value);
      terms.add(term);
    }

    // 新的同步策略只保留最新一期已经发布的课表。先把新文件写成功，
    // 再删除其它旧学期，避免网络异常时把原本可离线查看的课表一并删掉。
    if (replaceSchedules && scheduleHtmlByTerm.isNotEmpty) {
      final keepTerms = scheduleHtmlByTerm.keys
          .map((term) => term.trim())
          .where((term) => term.isNotEmpty)
          .toSet();
      final staleFiles = <File>[];
      await for (final entity in schedules.list()) {
        if (entity is! File || !entity.path.endsWith('.html')) continue;
        final name = entity.uri.pathSegments.isEmpty
            ? ''
            : entity.uri.pathSegments.last;
        final stale = !keepTerms.any(
          (term) => entity.path.endsWith('${_safeName(term)}.html'),
        );
        if (stale && name.isNotEmpty) staleFiles.add(entity);
      }
      for (final stale in staleFiles) {
        try {
          await stale.delete();
        } catch (_) {}
      }
      terms
        ..clear()
        ..addAll(keepTerms);
    }

    final gradesFile = File(
      '${account.path}${Platform.pathSeparator}$_gradesFileName',
    );
    var hasGrades = previous?.hasGrades == true;
    if (!hasGrades && await _readableFile(gradesFile) != null) {
      hasGrades = true;
    }
    if (replaceGrades) {
      await _writeRecoverably(
        gradesFile,
        jsonEncode(
          grades
              .map((grade) => Map<String, String>.from(grade))
              .toList(growable: false),
        ),
      );
      hasGrades = true;
    } else if (replaceGradeTerms.isNotEmpty) {
      final previousGrades = await loadGrades(normalized);
      final mergedGrades = mergeGradesByTerms(
        previous: previousGrades,
        fetched: grades,
        replacedTerms: replaceGradeTerms,
      );
      await _writeRecoverably(gradesFile, jsonEncode(mergedGrades));
      hasGrades = true;
    }

    final profile = File(
      '${account.path}${Platform.pathSeparator}$_profileFileName',
    );
    await _writeRecoverably(
      profile,
      jsonEncode({
        '_v': _schemaVersion,
        'studentId': normalized,
        'savedAt': DateTime.now().toIso8601String(),
        'scheduleTerms': terms.toList(growable: false),
        'hasGrades': hasGrades,
      }),
    );
  }

  static Future<bool> clearAll() async {
    try {
      final root = await _root();
      if (await root.exists()) await root.delete(recursive: true);
      return !await root.exists();
    } catch (_) {
      return false;
    }
  }
}
