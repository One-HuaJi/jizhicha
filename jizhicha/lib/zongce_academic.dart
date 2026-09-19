// 智育「学业成绩」自动计算：从已同步的教务成绩里筛选参与综测平均分的课程。
//
// 细则口径：学业成绩 =（除体育成绩、网络通识课、公共选修课、等级课程外的
// 其他课程平均成绩）× 90%，满分 90 分。
//
// ⚠️ 这里刻意**不做全自动黑盒计算**，因为实测数据里存在会算错的陷阱：
//   - 体育课的真实 `courseType` 是「通识教育课程（必修）」，与 60 余门**必须计入**
//     的通识必修课同类。若按 courseType 含「通识」过滤，会误删大量必修课。
//     → 因此体育课改为按**课程名**识别。
//   - 「公共选修课」才是细则要排除的那类；而「通识教育课程（必修）」绝不能排除。
//   - 成绩里存在文字成绩（实测有「良」），无法参与数值平均。
// 所以本模块只负责**给出候选 + 默认勾选建议 + 标注可疑项**，最终由用户复核确认。

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// 一门参与计算的课程。
class AcademicCourse {
  final String course;
  final String courseType;
  final String term;
  final String rawGrade;

  /// 数值成绩；文字成绩（优/良/合格等）为 null。
  final double? score;

  /// 默认是否勾选。
  bool selected;

  /// 不参与计算的原因（为空表示正常参与）。
  final String excludedReason;

  AcademicCourse({
    required this.course,
    required this.courseType,
    required this.term,
    required this.rawGrade,
    required this.score,
    required this.selected,
    this.excludedReason = '',
  });

  bool get hasNumericScore => score != null;
}

/// 自动计算结果。
class AcademicAutoResult {
  /// 参与计算的全部候选（含被排除的，供用户手动改选）。
  final List<AcademicCourse> courses;

  const AcademicAutoResult(this.courses);

  List<AcademicCourse> get selected =>
      courses.where((c) => c.selected).toList();

  /// 参与计算且成绩为数值的课程数。
  int get countedCount => selected.where((c) => c.hasNumericScore).length;

  /// 被排除的课程数。
  int get excludedCount => courses.where((c) => !c.selected).length;

  /// 文字成绩被勾选但无法计算的课程。
  List<AcademicCourse> get selectedNonNumeric =>
      selected.where((c) => !c.hasNumericScore).toList();

  /// 平均分（仅统计勾选且为数值的成绩）。无有效课程时返回 null。
  double? get average {
    final nums = selected
        .map((c) => c.score)
        .whereType<double>()
        .toList(growable: false);
    if (nums.isEmpty) return null;
    return nums.reduce((a, b) => a + b) / nums.length;
  }

  /// 学业成绩 = 平均分 × 90%（细则口径），上限 90 分。
  double? get academicScore {
    final avg = average;
    if (avg == null) return null;
    final v = avg * 0.9;
    return v > 90 ? 90 : v;
  }

  /// 参与计算且为数值的课程成绩（去重后按课程名排序，便于核对）。
  List<double> get countedScores {
    final list = selected
        .where((c) => c.hasNumericScore)
        .map((c) => c.score!)
        .toList();
    return list;
  }

  /// 生成「参与情况」里要写的那句算式。
  ///
  /// 形如：`共 12 科，（87+92+85+…）/12 = 87.33`
  /// 分数用 [fmtFn] 格式化（由调用方传入，避免本文件依赖格式化实现）。
  /// 无有效课程时返回空串。
  String describeCalculation(String Function(double) fmtFn) {
    final scored = selected.where((c) => c.hasNumericScore).toList();
    if (scored.isEmpty) return '';
    final avg = average!;
    final body = scored.map((c) => fmtFn(c.score!)).join('+');
    final head =
        '共 ${scored.length} 科，（$body）/${scored.length} = ${fmtFn(avg)}';
    // 逐科明细：科目名 + 分数。老师要核对你到底算了哪几门课，
    // 只给一串数字对不上号。
    final detail = scored
        .map((c) => '${c.course} ${fmtFn(c.score!)}')
        .join('、');
    return '$head\n$detail';
  }
}

/// 判断课程名是否为体育课（细则要求排除「体育成绩」）。
///
/// 用课程名而非 courseType：实测体育课的 courseType 是「通识教育课程（必修）」，
/// 与必须计入的通识必修课无法区分。
bool _isSportsCourse(String name) {
  final n = name.replaceAll(' ', '');
  if (n.isEmpty) return false;
  // 「体育」开头或包含，覆盖「体育1」「大学体育」「体育与健康」等；
  // 同时排除「体育」出现在无关词里的极小概率情况由用户复核兜底。
  return n.contains('体育');
}

/// 判断是否属于细则明确要排除的「公共选修课」。
///
/// 只认「公共选修课」这一确切类别。**不**匹配「通识教育课程（必修）」，
/// 也**不**因「通识」二字排除——那会误删必修课。
bool _isPublicElective(String courseType) {
  final t = courseType.replaceAll(' ', '');
  return t.contains('公共选修');
}

/// 从成绩列表构建自动计算结果。
///
/// [rawGrades] 为 `UserDataCacheStore.loadGrades()` 的返回结构，字段：
/// `course` / `credit` / `courseType` / `code` / `term` / `grade`。
///
/// [term] 非空时只统计该学期（综测按学期评）。
AcademicAutoResult buildAcademicAuto(
  List<Map<String, String>> rawGrades, {
  String term = '',
}) {
  // 同一门课可能在多学期重复出现：按「课程名 + 学期」去重，保留最高分。
  final seen = <String, AcademicCourse>{};

  for (final g in rawGrades) {
    final course = (g['course'] ?? '').trim();
    if (course.isEmpty) continue;
    final gTerm = (g['term'] ?? '').trim();
    if (term.isNotEmpty && gTerm != term) continue;
    final courseType = (g['courseType'] ?? '').trim();
    final rawGrade = (g['grade'] ?? '').trim();
    final score = double.tryParse(rawGrade);

    final key = '$course|$gTerm';
    final existing = seen[key];
    if (existing != null) {
      // 同一门课重复记录时取更高分（与成绩页归档口径一致）。
      if (score != null &&
          (existing.score == null || score > existing.score!)) {
        seen[key] = AcademicCourse(
          course: course,
          courseType: courseType,
          term: gTerm,
          rawGrade: rawGrade,
          score: score,
          selected: existing.selected,
          excludedReason: existing.excludedReason,
        );
      }
      continue;
    }

    String reason = '';
    if (_isSportsCourse(course)) {
      reason = '体育课（细则要求排除）';
    } else if (_isPublicElective(courseType)) {
      reason = '公共选修课（细则要求排除）';
    } else if (score == null) {
      reason = rawGrade.isEmpty ? '成绩为空' : '文字成绩「$rawGrade」，无法参与平均';
    }

    seen[key] = AcademicCourse(
      course: course,
      courseType: courseType,
      term: gTerm,
      rawGrade: rawGrade,
      score: score,
      // 默认勾选：无排除原因的课程。文字成绩也默认勾上，让用户自己决定；
      // 但下方 UI 会把它单独标红提示，避免悄悄算错。
      selected: reason.isEmpty || reason.startsWith('文字成绩'),
      excludedReason: reason,
    );
  }

  final list = seen.values.toList()
    ..sort((a, b) {
      final t = b.term.compareTo(a.term);
      if (t != 0) return t;
      return a.course.compareTo(b.course);
    });
  return AcademicAutoResult(list);
}

/// 体育成绩换算助手。
///
/// 细则：
///   大一、大二 =（体育课成绩 × 50% + 体质测试成绩 × 50%）× 60%
///   大三、大四 = 体质测试成绩 × 60%
///   体测免测者体测成绩按 60 分；免修体育者体育成绩 = 80 × 60% = 48 分
///
/// 返回计入综测的体育成绩（满分 60）。
double? computeSportsScore({
  required bool isSenior,
  double? peCourseScore,
  double? fitnessScore,
}) {
  if (isSenior) {
    if (fitnessScore == null) return null;
    return fitnessScore * 0.6;
  }
  if (peCourseScore == null || fitnessScore == null) return null;
  return (peCourseScore * 0.5 + fitnessScore * 0.5) * 0.6;
}

/// 体测免测时按 60 分计。
const double kFitnessExemptScore = 60;

/// 免修体育时的体育成绩：80 × 60% = 48 分。
const double kSportsExemptScore = 48;

/// 从已同步的成绩里取某学期的体育课成绩。
///
/// ⚠️ 体育课必须按**课程名**识别，不能按 `courseType`：实测体育课的性质是
/// 「通识教育课程（必修）」，与几十门必须计入智育的通识必修课同类，
/// 按性质过滤会一起误伤。
///
/// 同一门课可能重复出现（实测每个学期重复 3 条），取**最高分**作为代表，
/// 与成绩页的归档口径保持一致。
///
/// 返回 null 表示该学期没有体育课成绩（如大三以后不再开体育课）。
double? peCourseScoreOf(
  List<Map<String, String>> grades, {
  required String term,
}) {
  double? best;
  for (final g in grades) {
    final course = (g['course'] ?? '').trim();
    if (!course.contains('体育')) continue;
    final gTerm = (g['term'] ?? '').trim();
    if (term.isNotEmpty && gTerm != term) continue;
    final score = double.tryParse((g['grade'] ?? '').trim());
    if (score == null) continue;
    if (best == null || score > best) best = score;
  }
  return best;
}

/// 列出成绩里出现过的所有体育课（供界面展示「本学期没找到体育课」时的排查）。
List<({String course, String term, String grade})> allPeCourses(
  List<Map<String, String>> grades,
) {
  final seen = <String>{};
  final out = <({String course, String term, String grade})>[];
  for (final g in grades) {
    final course = (g['course'] ?? '').trim();
    if (!course.contains('体育')) continue;
    final term = (g['term'] ?? '').trim();
    final key = '$course|$term';
    if (!seen.add(key)) continue;
    out.add((course: course, term: term, grade: (g['grade'] ?? '').trim()));
  }
  out.sort((a, b) => b.term.compareTo(a.term));
  return out;
}

// ==================== 体测成绩表（Excel）导入 ====================
//
// 用户在「体育委员处」拿到的体测总成绩表通常是 .xlsx。这里解析它的
// `xl/worksheets/sheet1.xml` + `xl/sharedStrings.xml`，够用且不引第三方解析库。
//
// 设计：**不写死列位置**。体测表的表头各院系写法不同（「总分」「总成绩」
// 「体测成绩」「最终得分」都见过），所以改为：
//   1. 先在第 1~10 行里找表头行 —— 判定依据是「该行同时含学号类列与姓名类列」；
//   2. 在表头行里定位 学号 / 姓名 / 总分 三列的列号（按关键词匹配）；
//   3. 按用户填的学号姓名**强筛选**出那一行，取总分。
// 界面会把识别到的表头与匹配结果给用户确认，避免猜错。

/// 一张表被识别出的列映射。
class SheetColumns {
  /// 表头所在行号（0 起）。
  final int headerRow;

  /// 「学号」类列的下标；-1 表示没找到。
  final int idCol;

  /// 「姓名」类列的下标。
  final int nameCol;

  /// 「总分」类列的下标。
  final int totalCol;

  /// 表头原文（供界面展示，让用户确认识别对不对）。
  final List<String> headerTexts;

  /// 全部数据行（从表头下一行开始）。
  final List<List<String>> rows;

  const SheetColumns({
    required this.headerRow,
    required this.idCol,
    required this.nameCol,
    required this.totalCol,
    required this.headerTexts,
    required this.rows,
  });

  bool get hasIdentity => idCol >= 0 && nameCol >= 0;
  bool get hasTotal => totalCol >= 0;
}

/// 体测成绩表里匹配到的一行。
class FitnessSheetMatch {
  final String studentId;
  final String name;

  /// 总分原文。
  final String rawTotal;

  /// 解析成数值；解析失败为 null。
  final double? total;

  /// 该行的全部单元格（供界面展示上下文）。
  final List<String> cells;

  const FitnessSheetMatch({
    required this.studentId,
    required this.name,
    required this.rawTotal,
    required this.total,
    required this.cells,
  });
}

/// 关键词判定（忽略空白与大小写）。
bool _hasAny(String s, List<String> keys) {
  final t = s.replaceAll(RegExp(r'\s+'), '');
  return keys.any(t.contains);
}

/// 从二维单元格里识别列映射。
///
/// 表头行的判定：该行**同时**出现学号类与姓名类关键词。这样能跳过标题行、
/// 说明行、空行等干扰。
SheetColumns? detectColumns(List<List<String>> grid) {
  const idKeys = ['学号', '考生号', '编号'];
  const nameKeys = ['姓名', '名字'];
  const totalKeys = ['总分', '总成绩', '总得分', '体测成绩', '体测总分', '成绩'];

  final limit = grid.length < 12 ? grid.length : 12;
  for (var r = 0; r < limit; r++) {
    final row = grid[r];
    var idCol = -1, nameCol = -1, totalCol = -1;
    for (var c = 0; c < row.length; c++) {
      final cell = row[c];
      if (cell.trim().isEmpty) continue;
      if (idCol < 0 && _hasAny(cell, idKeys)) {
        idCol = c;
      } else if (nameCol < 0 && _hasAny(cell, nameKeys)) {
        nameCol = c;
      } else if (totalCol < 0 && _hasAny(cell, totalKeys)) {
        totalCol = c;
      }
    }
    if (idCol >= 0 && nameCol >= 0) {
      return SheetColumns(
        headerRow: r,
        idCol: idCol,
        nameCol: nameCol,
        totalCol: totalCol,
        headerTexts: row,
        rows: grid.sublist(r + 1),
      );
    }
  }
  return null;
}

/// 在数据行里按学号 + 姓名强筛选。
///
/// 匹配规则：学号与姓名都**非空且相等**才算命中（去掉所有空白后再比）。
/// 故意不做「只匹配学号」或「模糊匹配姓名」——体测表常有重名，宽松匹配
/// 会把别人的成绩填进来，这比找不到更糟。
List<FitnessSheetMatch> matchStudent(SheetColumns cols, String studentId, String name) {
  final wantId = studentId.replaceAll(RegExp(r'\s+'), '');
  final wantName = name.replaceAll(RegExp(r'\s+'), '');
  if (wantId.isEmpty || wantName.isEmpty) return const [];

  final out = <FitnessSheetMatch>[];
  for (final row in cols.rows) {
    if (cols.idCol >= row.length || cols.nameCol >= row.length) continue;
    final id = row[cols.idCol].replaceAll(RegExp(r'\s+'), '');
    final nm = row[cols.nameCol].replaceAll(RegExp(r'\s+'), '');
    if (id.isEmpty || nm.isEmpty) continue;
    if (id != wantId || nm != wantName) continue;

    final rawTotal = cols.totalCol >= 0 && cols.totalCol < row.length
        ? row[cols.totalCol].trim()
        : '';
    out.add(
      FitnessSheetMatch(
        studentId: id,
        name: nm,
        rawTotal: rawTotal,
        total: double.tryParse(rawTotal),
        cells: row,
      ),
    );
  }
  return out;
}

/// 解析 xlsx 的单元格引用（如 `C5`）取列号（0 起）。
int _colOf(String ref) {
  var col = 0;
  for (var i = 0; i < ref.length; i++) {
    final c = ref.codeUnitAt(i);
    if (c >= 0x41 && c <= 0x5A) {
      col = col * 26 + (c - 0x40);
    } else if (c >= 0x61 && c <= 0x7A) {
      col = col * 26 + (c - 0x60);
    } else {
      break;
    }
  }
  return col - 1;
}

/// 解析 xlsx 的第一个工作表为二维字符串表。
///
/// 只依赖 `xl/worksheets/sheet1.xml`、`xl/sharedStrings.xml` 与
/// `xl/workbook.xml`（取第一张表的实际文件名）。够读成绩表这类简单表格。
List<List<String>> parseXlsxGrid(Uint8List bytes) {
  final zip = ZipDecoder().decodeBytes(bytes);
  final files = <String, List<int>>{};
  for (final f in zip.files) {
    if (f.isFile) files[f.name] = List<int>.from(f.content as List<int>);
  }

  // 共享字符串表
  final shared = <String>[];
  final ssBytes = files['xl/sharedStrings.xml'];
  if (ssBytes != null) {
    final xml = utf8.decode(ssBytes);
    for (final m in RegExp(r'<si>(.*?)</si>', dotAll: true).allMatches(xml)) {
      final texts = RegExp(
        r'<t[^>]*>(.*?)</t>',
        dotAll: true,
      ).allMatches(m.group(1)!).map((x) => _unescapeXml(x.group(1)!));
      shared.add(texts.join());
    }
  }

  // 第一张工作表：优先按 workbook.xml + rels 找，找不到就退回 sheet1.xml
  var sheetPath = 'xl/worksheets/sheet1.xml';
  final wb = files['xl/workbook.xml'];
  final wbRels = files['xl/_rels/workbook.xml.rels'];
  if (wb != null && wbRels != null) {
    final wbXml = utf8.decode(wb);
    final relsXml = utf8.decode(wbRels);
    final first = RegExp(
      r'<sheet[^>]*r:id="([^"]+)"',
    ).firstMatch(wbXml)?.group(1);
    if (first != null) {
      final target = RegExp(
        '<Relationship[^>]*Id="$first"[^>]*Target="([^"]+)"',
      ).firstMatch(relsXml)?.group(1);
      if (target != null && target.isNotEmpty) {
        sheetPath = target.startsWith('/')
            ? target.substring(1)
            : 'xl/${target.replaceFirst(RegExp(r'^\./'), '')}';
      }
    }
  }
  final sheetBytes = files[sheetPath] ?? files['xl/worksheets/sheet1.xml'];
  if (sheetBytes == null) return const [];

  final sheetXml = utf8.decode(sheetBytes);
  final grid = <List<String>>[];
  var maxCol = 0;

  for (final rowM in RegExp(
    r'<row[^>]*>(.*?)</row>',
    dotAll: true,
  ).allMatches(sheetXml)) {
    final row = <int, String>{};
    for (final cM in RegExp(
      r'<c ([^>]*?)/?>(?:(.*?)</c>)?',
      dotAll: true,
    ).allMatches(rowM.group(1)!)) {
      final attrs = cM.group(1) ?? '';
      final inner = cM.group(2) ?? '';
      final ref = RegExp(r'r="([A-Za-z]+\d+)"').firstMatch(attrs)?.group(1);
      if (ref == null) continue;
      final t = RegExp(r't="([^"]+)"').firstMatch(attrs)?.group(1);
      String value;
      if (t == 's') {
        final idx = int.tryParse(
          RegExp(r'<v>(.*?)</v>', dotAll: true).firstMatch(inner)?.group(1) ?? '',
        );
        value = (idx != null && idx >= 0 && idx < shared.length)
            ? shared[idx]
            : '';
      } else if (t == 'inlineStr') {
        value = RegExp(
          r'<t[^>]*>(.*?)</t>',
          dotAll: true,
        ).allMatches(inner).map((x) => _unescapeXml(x.group(1)!)).join();
      } else {
        final v = RegExp(
          r'<v>(.*?)</v>',
          dotAll: true,
        ).firstMatch(inner)?.group(1);
        value = v == null ? '' : _unescapeXml(v);
      }
      final col = _colOf(ref);
      if (col < 0) continue;
      row[col] = value;
      if (col + 1 > maxCol) maxCol = col + 1;
    }
    if (row.isEmpty) {
      grid.add(<String>[]);
    } else {
      grid.add(List<String>.generate(maxCol, (i) => row[i] ?? ''));
    }
  }
  return grid;
}

String _unescapeXml(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

