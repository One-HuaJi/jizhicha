// 综测（学生综合素质测评）数据模型与计算规则。
//
// ── 规则来源（三份文件，数值已逐条核对一致）──────────────────────────
//   1.《24 级生教综测细则参考.docx》—— 计算口径与加分标准
//   2.《综测加减分自评表.docx》—— **导出模板**，逐字保留其框架
//   3.《附件5.湖南科技学院学生综合评价成绩登记表.xlsx》—— 官方汇总表
//
// ── 核心公式（细则原文）──────────────────────────────────────────
//   总分 = 德育×20% + 智育×50% + 体育×10% + 美育×10% + 劳育×10%
//   等级：≥85 优秀 ｜ ≥75 良好 ｜ ≥60 合格 ｜ <60 不合格
//   ⚠️ 这是**综测**标准，与学生体质健康标准的 90/80/60 是两套阈值，
//      绝不可复用 `fitness.dart` 的 `scoreLevel`。
//
// ── 行结构与导出模板严格一一对应 ──────────────────────────────────
// 官方自评表共 14 行（1 表头 + 12 内容 + 1 汇总），本模型按同一顺序建模，
// 导出时逐行填字，不需要猜测对应关系：
//   行1  德育 / 思想道德修养（基础30，满分50）
//   行2  德育 / 遵章守纪（基础50）
//   行3  智育 / 学业成绩（平均分×90%）
//   行4  智育 / 学习能力（基础4，满分10）
//   行5  体育 / 体育成绩（体育课×50%+体测×50%）×60%
//   行6  体育 / 运动能力（基础20，满分40）
//   行7  体育 / 减分项          ← 模板里是**独立一行**
//   行8  美育 / 美育课程（满分60）
//   行9  美育 / 美育素养（基础20，满分40）
//   行10 劳育 / 劳动课程（满分60）
//   行11 劳育 / 日常劳动（基础20，满分40）
//   行12 劳育 / 减分项          ← 模板里是**独立一行**
//
// ── 设计取舍 ────────────────────────────────────────────────────
// 程序只做「求和 + 按上限截断 + 加权」，**不替用户判断某条活动该加几分**。
// 细则里「校级/院级活动减半」「到梦空间的活动不加分」这类规则依赖人的判断，
// 程序猜错会让学生交上去的分数是错的，风险高于省下的那点输入成本。
// 因此细则原文只作为提示展示，分值一律由用户填写。

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 从学号与学期推断是「大三大四」还是「大一大二」。
///
/// 细则里体育成绩的算法按年级分叉：
///   大一、大二 =（体育课成绩 × 50% + 体测成绩 × 50%）× 60%
///   大三、大四 = 体质测试成绩 × 60%
/// 让用户手选年级容易选错，而这两个信息本来就能算出来：
/// 学号前 4 位是入学年份，学期字符串（如 `2026-2027-1`）的首个年份是学年起始年。
/// 相差 ≥ 2 年即大三及以上。
///
/// 返回 null 表示信息不足（学号或学期不规范），此时按「大一大二」处理更安全
/// （要求填体育课成绩，不会漏算一项）。
bool? inferIsSenior({required String studentId, required String term}) {
  final idMatch = RegExp(r'(\d{4})').firstMatch(studentId.trim());
  final termMatch = RegExp(r'(\d{4})').firstMatch(term.trim());
  if (idMatch == null || termMatch == null) return null;
  final enrollYear = int.tryParse(idMatch.group(1)!);
  final termYear = int.tryParse(termMatch.group(1)!);
  if (enrollYear == null || termYear == null) return null;
  // 学年起始年 - 入学年：0=大一、1=大二、2=大三、3=大四
  final gradeIndex = termYear - enrollYear;
  if (gradeIndex < 0 || gradeIndex > 8) return null; // 明显不合理，别瞎猜
  return gradeIndex >= 2;
}

/// 综测总成绩等级。阈值 85/75/60（勿与体测的 90/80/60 混用）。
String zongceLevel(double total) {
  if (total >= 85) return '优秀';
  if (total >= 75) return '良好';
  if (total >= 60) return '合格';
  return '不合格';
}

/// 一条加减分记录：说明 + 分值 + 证明图片。
///
/// 图片存**文件路径**而不是字节：自评表通常要配好几张证明图，全部读进内存
/// 会让存档 JSON 膨胀且每次读写都慢；导出时按需从磁盘读取。
class ZongceEntry {
  String note;
  double value;

  /// 证明图片的本地文件路径（空列表 = 没传图）。
  final List<String> images;

  ZongceEntry({this.note = '', this.value = 0, List<String>? images})
    : images = images ?? [];

  Map<String, dynamic> toJson() => {
    'note': note,
    'value': value,
    if (images.isNotEmpty) 'images': images,
  };

  factory ZongceEntry.fromJson(Map<String, dynamic> j) => ZongceEntry(
    note: (j['note'] ?? '').toString(),
    // ⚠️ 用 `toDoubleOrNull` 式的宽松解析，**不要**直接 `as num?`：
    // 实测设备上存在早期版本写坏的存档（`"value": true`），
    // `as num?` 会抛 `type 'bool' is not a subtype of type 'double?'`
    // 并让整页渲染成红色 ErrorWidget。坏值一律按 0 处理，不要因此崩页。
    value: ZongceEntry.toDoubleLoose(j['value']) ?? 0,
    images: ((j['images'] as List?) ?? const [])
        .map((e) => e.toString())
        .where((e) => e.isNotEmpty)
        .toList(),
  );

  /// 宽松地把任意 JSON 值转成 double；转不了返回 null（调用方决定默认值）。
  ///
  /// 公开静态方法，供本文件其它 `restore` 路径复用，保证口径一致。
  static double? toDoubleLoose(Object? v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim());
    // bool / List / Map 等一律视为无效，返回 null 由调用方兜底。
    return null;
  }

  /// 丢弃已经不存在的图片路径（用户可能删了文件或清了缓存）。
  void pruneMissingImages() {
    images.removeWhere((p) => !File(p).existsSync());
  }
}

/// 一行计分项，与官方模板的一行严格对应。
class ZongceRow {
  /// 小节名称，同时作为存档与导出时的稳定标识。
  final String title;

  /// 细则原文提示，仅用于界面展示。
  final String hint;

  /// 基础分默认值。
  final double defaultBase;

  /// 满分上限；null 表示不设上限（减分项就是这种）。
  final double? cap;

  /// 基础分。可被用户或「自动计算」修改（如学业成绩、体育成绩）。
  double base;

  /// 该行是否为「减分项」。
  ///
  /// 减分项有两个特殊之处：
  ///  1. 它的数值**允许为负**（其他行都钳到 ≥0）；
  ///  2. 它**不单独计入该育总分**，而是并入 [foldedInto] 指定的那一行。
  ///
  /// 依据细则原文：「体测不及格 −5 分/次……**在运动能力基础分 20 分上进行扣分**」。
  final bool isDeduction;

  /// 作为减分项时并入哪一行（按行名匹配，如「运动能力」「日常劳动」）。
  final String? foldedInto;

  /// 自动计算写回的结果说明（如学业成绩的「共 x 科，（…）/x = 平均分」）。
  ///
  /// 只在导出与界面展示时用；不参与计算。用户手动改分数后会清空，
  /// 避免出现"说明写着 87 分、得分列却是别的数"的不一致。
  String detail;

  final List<ZongceEntry> entries;

  ZongceRow({
    required this.title,
    this.hint = '',
    required this.defaultBase,
    this.cap,
    double? base,
    this.isDeduction = false,
    this.foldedInto,
    this.detail = '',
    List<ZongceEntry>? entries,
  }) : base = base ?? defaultBase,
       entries = entries ?? [];

  /// 加减分合计（可正可负）。
  double get adjustment => entries.fold(0.0, (s, e) => s + e.value);

  /// 截断前的原始分。
  double get rawScore => base + adjustment;

  /// 本行自身的得分。
  ///
  /// 上限对所有行生效；**下限只对非减分项生效** —— 减分项本来就应该显示
  /// 成负数（如 −5），若也钳到 0 就永远扣不了分。
  double get score {
    var v = rawScore;
    if (cap != null && v > cap!) v = cap!;
    if (!isDeduction && v < 0) v = 0;
    return v;
  }

  bool get isCapped => cap != null && rawScore > cap!;

  /// 是否被下限钳制。减分项允许为负，故恒为 false。
  bool get isFloored => !isDeduction && rawScore < 0;

  /// 该项下所有条目的图片路径（导出时用）。
  List<String> get allImages =>
      entries.expand((e) => e.images).toList(growable: false);

  bool get hasImages => entries.any((e) => e.images.isNotEmpty);

  Map<String, dynamic> toJson() => {
    'base': base,
    if (detail.isNotEmpty) 'detail': detail,
    'entries': entries.map((e) => e.toJson()).toList(),
  };

  /// 从存档恢复：保留预定义结构（标题/提示/上限/减分归属），
  /// 只覆盖基础分、自动算出的说明文字与记录。
  void restore(Map<String, dynamic> j) {
    base = ZongceEntry.toDoubleLoose(j['base']) ?? defaultBase;
    detail = (j['detail'] ?? '').toString();
    entries
      ..clear()
      ..addAll(
        ((j['entries'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => ZongceEntry.fromJson(m.cast<String, dynamic>())),
      );
    for (final e in entries) {
      e.pruneMissingImages();
    }
  }
}

/// 一育，例如「德育素质」。对应模板里纵向合并的「考核内容」列。
class ZongceCategory {
  final String name;

  /// 加权系数，如德育 0.2。
  final double weight;

  final List<ZongceRow> rows;

  ZongceCategory({required this.name, required this.weight, required this.rows});

  /// 该育得分（100 分制）。
  ///
  /// ⚠️ 减分项**不单独相加**，而是并入它 [ZongceRow.foldedInto] 指定的那一行。
  /// 依细则原文「体测不及格 −5 分/次……在运动能力基础分 20 分上进行扣分」，
  /// 若把减分项当独立小节相加，会出现「运动能力 20 + 减分项 −5」被算成两行
  /// 各占百分制、总分虚高一截的错误。
  double get score {
    var sum = 0.0;
    for (final r in rows) {
      if (r.isDeduction) continue; // 由下面并入目标行
      var v = r.score;
      // 找出并入本行的所有减分项
      for (final d in rows) {
        if (d.isDeduction && d.foldedInto == r.title) {
          v += d.score; // d.score 允许为负
        }
      }
      if (v < 0) v = 0; // 并入后整体不为负
      if (r.cap != null && v > r.cap!) v = r.cap!;
      sum += v;
    }
    // 兜底：减分项没指定并入目标时，仍计入本育总分（避免静默丢分）
    for (final d in rows) {
      if (!d.isDeduction) continue;
      final target = d.foldedInto;
      final hasTarget = target != null && rows.any((r) => !r.isDeduction && r.title == target);
      if (!hasTarget) sum += d.score;
    }
    return sum < 0 ? 0 : sum;
  }

  /// 加权后计入总分的分数。
  double get weighted => score * weight;

  ZongceRow? row(String title) {
    for (final r in rows) {
      if (r.title == title) return r;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    for (final r in rows) r.title: r.toJson(),
  };

  void restore(Map<String, dynamic> j) {
    for (final r in rows) {
      final m = j[r.title];
      if (m is Map) r.restore(m.cast<String, dynamic>());
    }
  }
}

/// 一整份综测自评表。
class ZongceForm {
  String college;
  String className;
  String studentId;
  String name;

  /// 评优学期，如 `2025-2026-1`。由下拉选择，不允许自由填写，
  /// 以保证与 `AcademicCalendar.terms` 一致（智育/体育都按它取数）。
  String term;

  /// 体测成绩（百分制）。细则里体育成绩要用到它；成绩表里没有这项，
  /// 只能手填或从体测成绩表导入。
  double? fitnessScore;

  final List<ZongceCategory> categories;

  ZongceForm({
    this.college = '',
    this.className = '',
    this.studentId = '',
    this.name = '',
    this.term = '',
    this.fitnessScore,
    required this.categories,
  });

  /// 加权总分。
  double get total => categories.fold(0.0, (s, c) => s + c.weighted);

  String get level => zongceLevel(total);

  ZongceCategory? category(String name) {
    for (final c in categories) {
      if (c.name == name) return c;
    }
    return null;
  }

  // ---- 便捷访问器 ----

  ZongceRow? get moral => category('德育素质')?.row('思想道德修养');
  ZongceRow? get discipline => category('德育素质')?.row('遵章守纪');
  ZongceRow? get academic => category('智育素质')?.row('学业成绩');
  ZongceRow? get learning => category('智育素质')?.row('学习能力');
  ZongceRow? get sportsScore => category('体育素质')?.row('体育成绩');
  ZongceRow? get sportsAbility => category('体育素质')?.row('运动能力');
  ZongceRow? get sportsDeduct => category('体育素质')?.row('减分项');
  ZongceRow? get aestheticCourse => category('美育素质')?.row('美育课程');
  ZongceRow? get aestheticQuality => category('美育素质')?.row('美育素养');
  ZongceRow? get laborCourse => category('劳育素质')?.row('劳动课程');
  ZongceRow? get dailyLabor => category('劳育素质')?.row('日常劳动');
  ZongceRow? get laborDeduct => category('劳育素质')?.row('减分项');

  /// 按细则把「体育成绩」算出来：(体育课×50% + 体测×50%) × 60%。
  ///
  /// [peCourseScore] 为本学期体育课成绩（可从成绩自动获取）。
  /// [isSenior] 为 true 时（大三大四）只用体测成绩×60%。
  /// 返回 null 表示参数不足、算不出来。
  ///
  /// ⚠️ 大三大四**不开体育课**，所以此时填的体测成绩应当是**上一学期（大二下）**
  /// 那一次的结果 —— 综测就是这么规定的。界面上要把这条说清楚，否则用户会以为
  /// "本学期没体测就不用填"。
  double? computeSportsScore({required bool isSenior, double? peCourseScore}) {
    final fit = fitnessScore;
    if (fit == null) return null;
    if (isSenior) return fit * 0.6;
    if (peCourseScore == null) return null;
    return (peCourseScore * 0.5 + fit * 0.5) * 0.6;
  }

  Map<String, dynamic> toJson() => {
    'college': college,
    'className': className,
    'studentId': studentId,
    'name': name,
    'term': term,
    if (fitnessScore != null) 'fitnessScore': fitnessScore,
    'categories': {for (final c in categories) c.name: c.toJson()},
  };

  void restore(Map<String, dynamic> j) {
    college = (j['college'] ?? college).toString();
    className = (j['className'] ?? className).toString();
    studentId = (j['studentId'] ?? studentId).toString();
    name = (j['name'] ?? name).toString();
    term = (j['term'] ?? term).toString();
    fitnessScore = ZongceEntry.toDoubleLoose(j['fitnessScore']) ?? fitnessScore;
    final cats = j['categories'];
    if (cats is Map) {
      for (final c in categories) {
        final m = cats[c.name];
        if (m is Map) c.restore(m.cast<String, dynamic>());
      }
    }
  }

  // ---- 持久化 ----

  static const _fileName = 'zongce_form.json';

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  /// 载入上次填写的内容；没有存档或读取失败时返回空白表单。
  /// 采用「先建默认结构、再覆盖数值」的方式恢复，故以后增删行也不会让旧存档失效。
  static Future<ZongceForm> load({
    String term = '',
    String defaultTerm = '',
  }) async {
    final form = buildDefaultForm(term: term.isEmpty ? defaultTerm : term);
    try {
      final f = await _file();
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        if (j is Map) form.restore(j.cast<String, dynamic>());
      }
    } catch (_) {
      // 存档损坏时静默回到空白表单，不阻断使用。
    }
    return form;
  }

  Future<void> save() async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(toJson()), flush: true);
    } catch (_) {}
  }

  /// 清空所有录入内容（保留预定义结构）。
  void clearAll() {
    for (final c in categories) {
      for (final r in c.rows) {
        r.base = r.defaultBase;
        r.entries.clear();
      }
    }
    fitnessScore = null;
  }
}

/// 构建一份符合化生院综测细则的空白表单。
///
/// 行的顺序、名称、基础分、满分都严格照官方《综测加减分自评表》与细则填写，
/// 导出时按同序逐行填字，因此**不要随意调整这里的顺序**。
ZongceForm buildDefaultForm({String term = ''}) {
  const moralHint =
      '基础分 30 分（默认满分）。加分项（满分 20 分）：\n'
      '1. 参加党校、团校、青马和大骨干培训（如团培、党培），加入党团组织：+5 分/次\n'
      '2. 学院和学校各学生组织主席团成员：+10 分；部长、副部长、会长、班长、团支书：+7 分；'
      '干事、班委会干部：+4 分（任学生干部满一学期且工作合格）\n'
      '3. 团培党培优秀学员、舜德学子、五四评优、学校组织的三下乡：+2 分\n'
      '4. 献血（凭献血证）：+5 分，仅限当学期加分\n'
      '5. 五育之星——德育之星：+2 分，仅限当学期加分';

  const disciplineHint =
      '基础分 50 分（本项只有减分项，请填负数）：\n'
      '1. 受学校或学院通报批评：-5 分/次（玩手机被抓扣 5 分）\n'
      '2. 旷课一学时：-1 分/次\n'
      '3. 违反学生公寓管理规定（如使用违禁电器等，不含寝室卫生）受通报：-5 分/次\n'
      '具体扣分事项详见学生会扣分汇总文件';

  const academicHint =
      '学业成绩 =（除体育成绩、网络通识课、公共选修课、等级课程外的其他课程平均成绩）× 90%。\n'
      '满分 90 分。可用「从成绩自动计算」按所选学期取数，也可手工填写。';

  const learningHint =
      '基础分 4 分。加分项（满分 6 分）：\n'
      '1. 过级考证：通过英语四级或计算机二级、普通话二乙各 +2 分；'
      '通过英语六级或计算机三级、普通话二甲及以上各 +3 分（获证以后各学期均可加分）\n'
      '2. 考取各类职业资格证书（如教师资格证）：每项 +2 分（获证以后各学期均可加分）\n'
      '3. 权威竞赛（如大学生创新创业比赛、化工原理竞赛、师范生技能大赛等）'
      '获校级、省级、国家级奖项：+2 / +4 / +6 分\n'
      '4. 五育之星——智育之星：+0.8 分，仅限当学期加分\n'
      '5. 活动具体加分详见学生会综测汇总文件';

  const sportsHint =
      '体育成绩 =（体育课成绩 × 50% + 体质测试成绩 × 50%）× 60%，满分 60 分。\n'
      '· 大三、大四只用体测成绩 × 60%\n'
      '· 体测免测者体测成绩按 60 分计；免修体育者体育成绩 = 80 × 60% = 48 分\n'
      '体育课成绩按所选学期从成绩里自动获取；体测成绩请手填或从体测成绩表导入。';

  const sportsAbilityHint =
      '基础分 20 分。加分项（满分 20 分）：\n'
      '1. 积极参加体育类竞赛，获省级、国家级奖项：+10 / +20 分\n'
      '2. 五育之星——体育之星：+4 分，仅限当学期加分\n'
      '3. 具体活动加分细则详见学生会综测汇总文件';

  const sportsDeductHint =
      '体育减分项：\n'
      '1. 体测不及格：-5 分/次\n'
      '2. 具体扣分事项详见学生会扣分汇总文件\n'
      '注意：本项在「运动能力」基础分 20 分上扣减，请填负数。';

  const aestheticCourseHint = '美育课程按满分 60 分计，一般无需修改。';

  const aestheticQualityHint =
      '基础分 20 分。加分项（满分 20 分）：\n'
      '1. 五育之星——美育之星：+4 分，仅限当学期加分\n'
      '2. 积极参加美术类竞赛，获省级、国家级奖项：+10 / +20 分\n'
      '3. 具体活动加分细则详见学生会综测汇总文件';

  const laborCourseHint = '劳动课程按满分 60 分计，一般无需修改。';

  const dailyLaborHint =
      '基础分 20 分。加分项（满分 20 分）：\n'
      '1. 五育之星——劳育之星：+4 分，仅限当学期加分\n'
      '2. 除学校组织的三下乡活动外，所有的社会实践：+4 分\n'
      '3. 具体活动加分细则详见学生会综测汇总文件';

  const laborDeductHint = '劳育减分项：具体扣分事项详见学生会扣分汇总文件，请填负数。';

  return ZongceForm(
    term: term,
    categories: [
      ZongceCategory(
        name: '德育素质',
        weight: 0.20,
        rows: [
          ZongceRow(
            title: '思想道德修养',
            hint: moralHint,
            defaultBase: 30,
            cap: 50,
          ),
          ZongceRow(
            title: '遵章守纪',
            hint: disciplineHint,
            defaultBase: 50,
            cap: 50,
          ),
        ],
      ),
      ZongceCategory(
        name: '智育素质',
        weight: 0.50,
        rows: [
          ZongceRow(
            title: '学业成绩',
            hint: academicHint,
            defaultBase: 0,
            cap: 90,
          ),
          ZongceRow(
            title: '学习能力',
            hint: learningHint,
            defaultBase: 4,
            cap: 10,
          ),
        ],
      ),
      ZongceCategory(
        name: '体育素质',
        weight: 0.10,
        rows: [
          ZongceRow(
            title: '体育成绩',
            hint: sportsHint,
            defaultBase: 0,
            cap: 60,
          ),
          ZongceRow(
            title: '运动能力',
            hint: sportsAbilityHint,
            defaultBase: 20,
            cap: 40,
          ),
          // 模板里「减分项」是独立一行，其分值按细则**并入「运动能力」**
          // （原文：在运动能力基础分 20 分上进行扣分）。
          ZongceRow(
            title: '减分项',
            hint: sportsDeductHint,
            defaultBase: 0,
            isDeduction: true,
            foldedInto: '运动能力',
          ),
        ],
      ),
      ZongceCategory(
        name: '美育素质',
        weight: 0.10,
        rows: [
          ZongceRow(
            title: '美育课程',
            hint: aestheticCourseHint,
            defaultBase: 60,
            cap: 60,
          ),
          ZongceRow(
            title: '美育素养',
            hint: aestheticQualityHint,
            defaultBase: 20,
            cap: 40,
          ),
        ],
      ),
      ZongceCategory(
        name: '劳育素质',
        weight: 0.10,
        rows: [
          ZongceRow(
            title: '劳动课程',
            hint: laborCourseHint,
            defaultBase: 60,
            cap: 60,
          ),
          ZongceRow(
            title: '日常劳动',
            hint: dailyLaborHint,
            defaultBase: 20,
            cap: 40,
          ),
          ZongceRow(
            title: '减分项',
            hint: laborDeductHint,
            defaultBase: 0,
            isDeduction: true,
            foldedInto: '日常劳动',
          ),
        ],
      ),
    ],
  );
}
