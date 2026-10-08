// 体测计算器成绩缓存存储：保存最近一次计算出的体测总分，供综测等模块联动使用。

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class FitnessRecord {
  final double totalScore;
  final bool isMale;
  final int gradeLevel; // 1=大一大二, 2=大三大四
  final DateTime calculatedAt;

  const FitnessRecord({
    required this.totalScore,
    required this.isMale,
    required this.gradeLevel,
    required this.calculatedAt,
  });

  Map<String, dynamic> toJson() => {
        'totalScore': totalScore,
        'isMale': isMale,
        'gradeLevel': gradeLevel,
        'calculatedAt': calculatedAt.toIso8601String(),
      };

  factory FitnessRecord.fromJson(Map<String, dynamic> json) {
    return FitnessRecord(
      totalScore: (json['totalScore'] as num).toDouble(),
      isMale: json['isMale'] as bool? ?? true,
      gradeLevel: json['gradeLevel'] as int? ?? 1,
      calculatedAt: DateTime.tryParse(json['calculatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class FitnessStore {
  FitnessStore._();

  static const String _fileName = 'fitness_latest_result.json';

  static Future<File> _getFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  static Future<void> saveLatestRecord(FitnessRecord record) async {
    try {
      final file = await _getFile();
      await file.writeAsString(jsonEncode(record.toJson()), flush: true);
    } catch (_) {}
  }

  static Future<FitnessRecord?> readLatestRecord() async {
    try {
      final file = await _getFile();
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      if (content.trim().isEmpty) return null;
      final json = jsonDecode(content);
      if (json is Map<String, dynamic>) {
        return FitnessRecord.fromJson(json);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear() async {
    try {
      final file = await _getFile();
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}
