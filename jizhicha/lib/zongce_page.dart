// 综测计算器页面：录入五育加减分 → 实时预览 → 导出 Word 版自评表。
//
// 计算口径见 `zongce_model.dart` 顶部注释（总分 = 五育加权，各育 100 分制）。
//
// ── 交互设计要点 ────────────────────────────────────────────────
//  · 每项可加多条「说明 + 分数 + 证明图」记录，而不是只给一个总分输入框：
//    因为自评表要填「个人在该项中的参与情况」，老师要看参加了什么、加了几分、
//    并附证明。录入的记录会**自动生成**描述文字与插图，省去二次编辑。
//  · 细则原文以提示形式展示，但**分值一律手填**——「校级/院级减半」
//    「到梦空间不加分」这类判断依赖人的判断，程序猜错会让分数算错。
//  · 智育学业成绩与体育课成绩从已同步成绩按**所选学期**自动获取。
//  · 体测成绩手填，或从体测成绩表（Excel）按学号姓名强筛选导入。
//
// ── 两个易踩的界面坑（已在代码里避开，勿改回去）────────────────────
//  1. 条目 key 必须用**对象标识**并挂在整个行的最外层。若用列表下标、或把 key
//     放在里层输入框上，删除/新增条目时外层按下标配对会错位，导致整棵子树重建
//     → **输入框失焦**，Flutter 会把焦点交给下一个可聚焦控件（表现为「跳到上面
//     某个没填的输入框」）。
//  2. 数值框要在 `didUpdateWidget` 里回填外部改动（如「自动获取」写入），
//     但**用户正在输入时不能覆盖**，否则输入负数的第一个字符 `-` 会被改成 `0`。

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'academic_calendar.dart';
import 'credential_store.dart';
import 'schedule_cache_store.dart';
import 'zongce_academic.dart';
import 'zongce_docx.dart';
import 'zongce_model.dart';
import 'zongce_share.dart';

class ZongcePage extends StatefulWidget {
  const ZongcePage({super.key, this.initialForm});

  /// 仅用于测试：直接注入表单，跳过 `_load()` 里的平台通道
  /// （`flutter_secure_storage` / `path_provider` 在纯 widget 测试里不可用）。
  /// 生产代码始终传 null。
  final ZongceForm? initialForm;

  @override
  State<ZongcePage> createState() => _ZongcePageState();
}

class _ZongcePageState extends State<ZongcePage> {
  ZongceForm? _form;
  bool _loading = true;
  bool _busy = false;
  String _busyText = '';

  final _collegeCtrl = TextEditingController();
  final _classCtrl = TextEditingController();
  final _studentIdCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();

  bool _dirty = false;
  bool _saving = false;

  /// 已展开的分类名。
  ///
  /// 自己持有而不是交给 `ExpansionTile` / `PageStorageKey`：
  ///  · `ExpansionTile` 内部状态会在元素被卸载时丢失（长截图重排、ListView 回收），
  ///    于是卡片"自动收起"；
  ///  · `PageStorageKey` 又会与 ScrollPosition 的滚动偏移争用同一个键 → 红屏。
  /// 状态放在页面 State 里则两者都避免。
  final Set<String> _expandedCats = {'德育素质', '智育素质'};

  /// 是否高年级（大三大四）——由学号与学期**自动推断**，不让用户手选。
  ///
  /// 推断不出来时按 false（大一大二）处理：那条分支要求填体育课成绩，
  /// 多要一项总比漏算一项安全。
  bool get _isSenior {
    final inferred = inferIsSenior(
      studentId: _studentIdCtrl.text,
      term: _f.term,
    );
    return inferred ?? false;
  }

  /// 本学期的体育课成绩（从已同步成绩自动取，供体育成绩计算用）。
  double? _peCourseScore;

  /// 已同步的全部成绩（缓存，避免每次点按都重新读盘）。
  List<Map<String, String>>? _grades;

  @override
  void initState() {
    super.initState();
    final injected = widget.initialForm;
    if (injected != null) {
      // 测试注入路径：不碰任何平台通道。
      _form = injected;
      _loading = false;
      _collegeCtrl.text = injected.college;
      _classCtrl.text = injected.className;
      _studentIdCtrl.text = injected.studentId;
      _nameCtrl.text = injected.name;
      return;
    }
    _load();
  }

  @override
  void dispose() {
    for (final c in [
      _collegeCtrl,
      _classCtrl,
      _studentIdCtrl,
      _nameCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  // ==================== 载入 ====================

  Future<void> _load() async {
    String prefillId = '';
    try {
      final accounts = await CredentialStore.load(StoredAccountKind.education);
      if (accounts.isNotEmpty) prefillId = accounts.first.username;
    } catch (_) {}

    final form = await ZongceForm.load(defaultTerm: AcademicCalendar.latestTerm);
    if (!mounted) return;
    setState(() {
      _form = form;
      _collegeCtrl.text = form.college;
      _classCtrl.text = form.className;
      _studentIdCtrl.text = form.studentId.isNotEmpty ? form.studentId : prefillId;
      _nameCtrl.text = form.name;
      _loading = false;
    });
    // 载入后自动取一次本学期的体育课成绩。
    //
    // ⚠️ 必须在这里取：否则「体育成绩」那行的提示会一直显示「该学期未取到」，
    // 而用户明明在成绩里有体育课 —— 会误以为数据没读到、进而怀疑算错。
    // （真机实测过这个问题：base 已经按体育课算出来了，提示却写着未取到。）
    unawaited(_refreshPeCourse(silent: true));
  }

  ZongceForm get _f => _form!;

  void _syncHeaderToForm() {
    _f
      ..college = _collegeCtrl.text.trim()
      ..className = _classCtrl.text.trim()
      ..studentId = _studentIdCtrl.text.trim()
      ..name = _nameCtrl.text.trim();
    // term 由下拉维护，不从输入框同步（避免手打出与 AcademicCalendar 不一致的值）。
  }

  /// 读成绩（带缓存）。
  Future<List<Map<String, String>>> _loadGrades() async {
    final cached = _grades;
    if (cached != null) return cached;
    var sid = _studentIdCtrl.text.trim();
    if (sid.isEmpty) {
      try {
        final accounts = await CredentialStore.load(
          StoredAccountKind.education,
        );
        if (accounts.isNotEmpty) sid = accounts.first.username;
      } catch (_) {}
    }
    if (sid.isEmpty) return const [];
    final list = await UserDataCacheStore.loadGrades(sid);
    _grades = list;
    return list;
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    _syncHeaderToForm();
    await _f.save();
    if (!mounted) return;
    setState(() {
      _saving = false;
      _dirty = false;
    });
    _toast('已保存');
  }

  void _markDirty() {
    setState(() => _dirty = true);
  }

  void _toast(String msg, {Duration? dur}) {
    if (!mounted) return;
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(
      SnackBar(content: Text(msg), duration: dur ?? const Duration(seconds: 2)),
    );
  }

  // ==================== 学期切换 ====================

  /// 切换学期后要重取体育课成绩。
  Future<void> _setTerm(String term) async {
    setState(() {
      _f.term = term;
      _dirty = true;
      _peCourseScore = null;
    });
    await _refreshPeCourse(silent: true);
  }

  /// 按当前学期取体育课成绩。
  Future<void> _refreshPeCourse({bool silent = false}) async {
    final term = _f.term;
    if (term.isEmpty) return;
    final grades = await _loadGrades();
    if (grades.isEmpty) {
      if (!silent) _toast('没有本地成绩数据，请先连接校园网同步成绩');
      return;
    }
    final score = peCourseScoreOf(grades, term: term);
    if (!mounted) return;
    setState(() => _peCourseScore = score);
    if (score == null && !silent) {
      final all = allPeCourses(grades);
      _toast(
        all.isEmpty
            ? '成绩里没有体育课记录'
            : '该学期没有体育课（找到：${all.map((e) => '${e.term} ${e.course}').take(3).join('、')}）',
        dur: const Duration(seconds: 4),
      );
    }
  }

  // ==================== 自动获取 ====================

  /// 智育「学业成绩」自动计算。
  Future<void> _autoAcademic() async {
    final row = _f.academic;
    if (row == null) return;
    final grades = await _loadGrades();
    if (!mounted) return;
    if (grades.isEmpty) {
      _toast('没有本地成绩数据，请先连接校园网同步成绩', dur: const Duration(seconds: 3));
      return;
    }
    // 只取当前学期：综测是按学期评的。
    final picked = await showDialog<_AcademicPickResult>(
      context: context,
      builder: (_) => _AcademicPickDialog(grades: grades, term: _f.term),
    );
    if (picked == null || !mounted) return;
    setState(() {
      row.base = picked.score;
      // 记下算式，导出时会写进「参与情况」列，老师能直接看到平均分怎么来的。
      row.detail = picked.detail;
      _dirty = true;
    });
    _toast(
      '已按 ${picked.counted} 门课平均分 ${picked.average.toStringAsFixed(2)} '
      '算出学业成绩 ${picked.score.toStringAsFixed(2)} 分',
      dur: const Duration(seconds: 3),
    );
  }

  /// 体育「体育成绩」自动计算：(体育课×50% + 体测×50%) × 60%。
  Future<void> _autoSports() async {
    final row = _f.sportsScore;
    if (row == null) return;
    await _refreshPeCourse();
    if (!mounted) return;

    final fitScore = _f.fitnessScore;
    if (fitScore == null) {
      _toast('请先填体测成绩（或从体测成绩表导入）');
      return;
    }
    final peScore = _peCourseScore;
    if (!_isSenior && peScore == null) {
      _toast('该学期没有体育课成绩，无法按公式计算；可直接手填体育成绩');
      return;
    }
    final v = _f.computeSportsScore(isSenior: _isSenior, peCourseScore: peScore);
    if (v == null) {
      _toast('参数不足，无法计算');
      return;
    }
    setState(() {
      row.base = v;
      _dirty = true;
    });
    final detail = _isSenior
        ? '体测 ${fmtNum(fitScore)} × 60%'
        : '（体育课 ${fmtNum(peScore!)} × 50% + 体测 ${fmtNum(fitScore)} × 50%）× 60%';
    _toast('体育成绩 = $detail = ${fmtNum(v)}', dur: const Duration(seconds: 4));
  }

  // ==================== 体测成绩表导入 ====================

  Future<void> _importFitnessSheet() async {
    final sid = _studentIdCtrl.text.trim();
    final nm = _nameCtrl.text.trim();
    if (sid.isEmpty || nm.isEmpty) {
      _toast('请先填写学号与姓名，导入时要用它们筛选');
      return;
    }

    // ⚠️ 这里**不要**用 `FileType.custom` + `allowedExtensions: ['xlsx']`。
    //
    // Android 端插件会把扩展名经 `MimeTypeMap.getMimeTypeFromExtension('xlsx')`
    // 转成 MIME 再塞进 `EXTRA_MIME_TYPES`；而很多 ROM（含小米）对 `.xlsx`
    // 返回 **null**，于是系统选择器把所有 Excel 都过滤掉 —— 用户看到的就是
    // 「找不到 excel 表」。`.xls` 通常不受影响，所以这个坑很容易被忽略。
    //
    // 改成 `FileType.any` 让系统列出全部文件，拿到之后再自己校验扩展名 /
    // 文件头。宁可让用户看到一堆文件、也不要让他看不到自己要选的那个。
    List<PlatformFile> picked;
    try {
      picked = await FilePicker.pickFiles(
        dialogTitle: '选择体测成绩表（.xlsx）',
        type: FileType.any,
      );
    } catch (e) {
      _toast('无法打开文件选择器：$e');
      return;
    }
    if (picked.isEmpty) return;

    final file = picked.first;
    // 自己校验：xlsx 是 zip（PK 开头），旧版 xls 是 OLE（D0 CF 11 E0）。
    final lowerName = file.name.toLowerCase();
    final looksXlsx = lowerName.endsWith('.xlsx') || lowerName.endsWith('.xls');
    setState(() {
      _busy = true;
      _busyText = '正在解析体测成绩表…';
    });
    try {
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) throw '读不到文件内容';
      final isZip = bytes.length > 3 &&
          bytes[0] == 0x50 &&
          bytes[1] == 0x4B; // "PK"
      if (!looksXlsx && !isZip) {
        throw '这不是 Excel 文件（选了「${file.name}」）。请选 .xlsx 格式的体测成绩表';
      }
      if (!isZip) {
        throw '只支持 .xlsx（选了「${file.name}」）。'
            '旧版 .xls 请在 Excel/WPS 里另存为 .xlsx 再导入';
      }

      final grid = parseXlsxGrid(bytes);
      if (grid.isEmpty) throw '这个表格里没有读到数据（只支持 .xlsx）';

      final cols = detectColumns(grid);
      if (cols == null) {
        throw '没识别出表头。表格里需要有「学号」和「姓名」两列';
      }
      if (!cols.hasTotal) {
        throw '没找到「总分」列。请确认表头里有「总分」或「总成绩」等字样';
      }

      final matches = matchStudent(cols, sid, nm);
      if (!mounted) return;
      setState(() {
        _busy = false;
      });

      if (matches.isEmpty) {
        await _showImportFailDialog(cols, sid, nm);
        return;
      }

      final chosen = await showDialog<FitnessSheetMatch>(
        context: context,
        builder: (_) => _FitnessImportDialog(
          cols: cols,
          matches: matches,
          studentId: sid,
          name: nm,
        ),
      );
      if (chosen == null || !mounted) return;

      final t = chosen.total;
      if (t == null) {
        _toast('「${chosen.rawTotal}」不是数字，无法作为体测成绩');
        return;
      }
      setState(() {
        _f.fitnessScore = t;
        _dirty = true;
      });
      _toast('已导入体测成绩 $t 分', dur: const Duration(seconds: 3));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('导入失败：$e', dur: const Duration(seconds: 4));
    }
  }

  Future<void> _showImportFailDialog(
    SheetColumns cols,
    String sid,
    String nm,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('没找到你的成绩'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('按「学号 = $sid」且「姓名 = $nm」在表里精确匹配，没有找到。'),
              const SizedBox(height: 10),
              const Text('识别到的表头：', style: TextStyle(fontWeight: FontWeight.w600)),
              Text(cols.headerTexts.where((e) => e.trim().isNotEmpty).join(' | ')),
              const SizedBox(height: 8),
              Text('共 ${cols.rows.length} 行数据。'),
              const SizedBox(height: 10),
              const Text(
                '排查建议：\n'
                '· 确认表里学号/姓名与上面填的完全一致\n'
                '· 确认打开的是体测总成绩表（含「总分」列）\n'
                '· 若表格格式特殊，可先手工填体测成绩',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  // ==================== 导出 ====================

  Future<void> _export() async {
    _syncHeaderToForm();
    setState(() {
      _busy = true;
      _busyText = '正在生成 Word 自评表…';
    });
    try {
      final result = await buildZongceDocx(_f);
      final stamp = _fileStamp();
      final safeName = _nameCtrl.text.trim().isEmpty
          ? ''
          : '_${_nameCtrl.text.trim()}';
      final fileName = '综测加减分自评表$safeName$stamp.docx';

      if (Platform.isAndroid) {
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}${Platform.pathSeparator}$fileName');
        await file.writeAsBytes(result.bytes, flush: true);
        if (!mounted) return;
        setState(() => _busy = false);
        await shareFile(
          path: file.path,
          mimeType:
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
          subject: '综测加减分自评表',
        );
        return;
      }

      final dir = await _exportDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}$fileName');
      await file.writeAsBytes(result.bytes, flush: true);
      await _f.save();
      if (!mounted) return;
      setState(() => _busy = false);
      final imgTip = result.imageCount > 0
          ? '（含 ${result.imageCount} 张证明图）'
          : '';
      _toast('已导出$imgTip：${file.path}', dur: const Duration(seconds: 4));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('导出失败：$e', dur: const Duration(seconds: 4));
    }
  }

  String _fileStamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '_${now.year}${two(now.month)}${two(now.day)}'
        '_${two(now.hour)}${two(now.minute)}';
  }

  Future<Directory> _exportDirectory() async {
    if (Platform.isWindows) {
      final exeDir = File(Platform.resolvedExecutable).parent;
      final dir = Directory('${exeDir.path}${Platform.pathSeparator}screen');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }
    return getApplicationDocumentsDirectory();
  }

  // ==================== 选图片 ====================

  Future<void> _pickImages(ZongceEntry entry) async {
    List<PlatformFile> picked;
    try {
      // 允许多选：证明图常常一次要传好几张。
      // ignore: deprecated_member_use
      picked = await FilePicker.pickFiles(
        dialogTitle: '选择证明图片',
        type: FileType.image,
        allowMultiple: true,
      );
    } catch (e) {
      _toast('无法打开图片选择器：$e');
      return;
    }
    if (picked.isEmpty) return;

    // 图片要长期留在导出时可读的位置：复制到应用文档目录，
    // 不能直接用选择器给的临时路径（系统清缓存后会失效）。
    final dir = await getApplicationDocumentsDirectory();
    final imgDir = Directory(
      '${dir.path}${Platform.pathSeparator}zongce_proofs',
    );
    if (!await imgDir.exists()) await imgDir.create(recursive: true);

    var added = 0;
    for (final f in picked) {
      try {
        final ext = (f.extension ?? 'jpg').toLowerCase();
        final target = File(
          '${imgDir.path}${Platform.pathSeparator}'
          '${DateTime.now().microsecondsSinceEpoch}_${f.name}',
        );
        final data = await f.readAsBytes();
        if (data.isEmpty) continue;
        await target.writeAsBytes(data, flush: true);
        // 校验确实是图片（避免把非图片文件塞进 docx 导致 Word 报错）。
        if (decodeImageSize(data) == (0, 0) &&
            !['png', 'jpg', 'jpeg'].contains(ext)) {
          await target.delete();
          continue;
        }
        entry.images.add(target.path);
        added++;
      } catch (_) {
        // 单张失败不影响其它图片
      }
    }
    if (!mounted) return;
    setState(() => _dirty = true);
    _toast(added == 0 ? '没有添加任何图片' : '已添加 $added 张证明图');
  }

  // ==================== 界面 ====================

  @override
  Widget build(BuildContext context) {
    if (_loading || _form == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            title: const Text('综测计算器'),
            actions: [
              IconButton(
                tooltip: '保存',
                onPressed: _saving ? null : _save,
                icon: Icon(_dirty ? Icons.save : Icons.save_outlined),
              ),
              IconButton(
                tooltip: '导出 Word',
                onPressed: _busy ? null : _export,
                icon: const Icon(Icons.ios_share),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
            children: [
              _buildIntro(),
              const SizedBox(height: 12),
              _buildHeaderCard(),
              const SizedBox(height: 12),
              ..._f.categories.map(_buildCategoryCard),
              const SizedBox(height: 8),
              _buildTotalCard(),
              const SizedBox(height: 16),
              _buildExportButton(),
              const SizedBox(height: 24),
            ],
          ),
        ),
        if (_busy)
          ColoredBox(
            color: Colors.black26,
            child: Center(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 12),
                      Text(_busyText),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildIntro() {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withAlpha(120),
      child: const Padding(
        padding: EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '总分 = 德育×20% + 智育×50% + 体育×10% + 美育×10% + 劳育×10%',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
            SizedBox(height: 6),
            Text(
              '等级：85 分及以上优秀 · 75 分及以上良好 · 60 分及以上合格 · 低于 60 分不合格\n'
              '五育各自满分 100 分。每条加分/减分可单独记一条并附证明图，'
              '导出的表会自动生成描述文字与插图。',
              style: TextStyle(fontSize: 12, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderCard() {
    final terms = AcademicCalendar.terms;
    final termValue = terms.contains(_f.term) ? _f.term : terms.first;
    return Card(
      child: ExpansionTile(
        initiallyExpanded: true,
        title: const Text('基本信息', style: TextStyle(fontWeight: FontWeight.w700)),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          _textField(_classCtrl, '班级', '如：生教2401班'),
          _textField(_collegeCtrl, '学院', '如：化学与生物工程学院'),
          _textField(_studentIdCtrl, '学号', ''),
          _textField(_nameCtrl, '姓名', ''),
          // 学期：下拉选择，不允许手打，保证与 AcademicCalendar 一致。
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: '学期（评优学期）',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: termValue,
                  items: [
                    for (final t in terms)
                      DropdownMenuItem(value: t, child: Text(t)),
                  ],
                  onChanged: (v) {
                    if (v != null && v != _f.term) _setTerm(v);
                  },
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              // 学期会记住上次选过的值（符合"大三上评大二下成绩"的用法），
              // 但若选的不是最新学期，要显眼提醒 —— 否则学期换了、
              // 用户没注意，就会按旧学期取数而算错。
              termValue == AcademicCalendar.latestTerm
                  ? '智育的学业成绩、体育的体育课成绩都按这个学期取数。'
                  : '⚠ 当前选的是「$termValue」，不是最新学期'
                        '（${AcademicCalendar.latestTerm}）。'
                        '智育与体育都按所选学期取数，请确认这是你要评的那一学期。',
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: termValue == AcademicCalendar.latestTerm
                    ? Theme.of(context).colorScheme.onSurfaceVariant
                    : Theme.of(context).colorScheme.error,
              ),
            ),
          ),
          const Divider(height: 20),
          _buildFitnessRow(),
        ],
      ),
    );
  }

  /// 体测成绩：手填 + 从表导入。
  Widget _buildFitnessRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('体测成绩', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            SizedBox(
              width: 84,
              child: _NumField(
                key: const ValueKey('fitness'),
                value: _f.fitnessScore ?? 0,
                hint: '如 80',
                onChanged: (v) {
                  _f.fitnessScore = v;
                  _markDirty();
                },
              ),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: _importFitnessSheet,
              icon: const Icon(Icons.upload_file, size: 18),
              label: const Text('从表导入', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            _isSenior
                // 大三/大四不开体育课，综测用的是上一学期（大二下）那次体测成绩。
                // 不写清楚，用户会以为"本学期没体测所以不用填"。
                ? '大三大四没有体育课，这里填**上一学期（大二下）**的体测成绩；'
                      '体育成绩 = 体测 × 60%。也可从体育委员发的 .xlsx 导入。'
                : '填本学期的体测成绩；体育成绩 =（体育课×50% + 体测×50%）× 60%。'
                      '也可从体育委员发的 .xlsx 按学号姓名导入。',
            style: TextStyle(
              fontSize: 11,
              height: 1.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _textField(TextEditingController ctrl, String label, String hint) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: ctrl,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint.isEmpty ? null : hint,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        onChanged: (_) {
          _grades = null; // 学号变了，成绩缓存失效
          setState(() => _dirty = true);
        },
      ),
    );
  }

  Widget _buildCategoryCard(ZongceCategory cat) {
    final pct = (cat.weight * 100).round();
    // 展开状态**由我们自己持有**（`_expandedCats`），不用 ExpansionTile 的内部状态。
    //
    // 为什么不能用 ExpansionTile 自己记状态：它的状态存在自己的 State 里，
    // 一旦元素被卸载（ListView 回收、长截图重排、系统回收）就丢，
    // 重建时回落到 `initiallyExpanded` —— 表现为「滚回去/截完图后卡片自动收起」。
    // 也不能改回 `PageStorageKey`：那会和 ScrollPosition 的滚动偏移**争用同一个
    // 存储键**，导致 `type 'bool' is not a subtype of type 'double?'` 红屏
    // （见本文件 §9.4.2 的踩坑记录）。
    // 自己持有状态则两个问题都没有。
    final expanded = _expandedCats.contains(cat.name);
    return Card(
      key: ValueKey('cat-${cat.name}'),
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        key: ValueKey('tile-${cat.name}'),
        initiallyExpanded: expanded,
        // 用 onExpansionChanged 把状态同步回我们自己，而不是交给 PageStorage。
        onExpansionChanged: (v) {
          setState(() {
            if (v) {
              _expandedCats.add(cat.name);
            } else {
              _expandedCats.remove(cat.name);
            }
          });
        },
        title: Row(
          children: [
            Expanded(
              child: Text(
                '${cat.name}（$pct%）',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              '${fmtNum(cat.score)} 分',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '→ ${fmtNum(cat.weighted)}',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [for (final r in cat.rows) _buildRowCard(r, cat)],
      ),
    );
  }

  Widget _buildRowCard(ZongceRow r, ZongceCategory cat) {
    // ⚠️ key 必须带**分类名**：`减分项` 在体育素质与劳育素质里各有一行，
    // 只用行名会让两处 `ValueKey('base-减分项')` 撞在一起，触发
    // 「Duplicate keys found ... has multiple children with key」并渲染成
    // 红色 ErrorWidget（用户实测即两处红块：体育一个、劳育一个）。
    final rowKey = '${cat.name}-${r.title}';
    return Container(
      key: ValueKey('rowcard-$rowKey'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  r.cap != null ? '${r.title}（满分${fmtNum(r.cap!)}）' : r.title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                '${fmtNum(r.score)} 分',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  // 减分项为负时用错误色标出来，避免用户以为没生效
                  color: r.score < 0
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ),

          // 减分项：它没有基础分，且分数要并入其它行，界面上要说清楚。
          if (r.isDeduction)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '在「${r.foldedInto ?? '上一行'}」的基础上扣减，'
                '所以这里填负数（如 −5）。本行不计入百分制，只做扣分。',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),

          const SizedBox(height: 6),
          // 减分项不显示「基础分」输入框：它只有扣分记录，给个基础分框
          // 反而让人以为能加分。
          if (!r.isDeduction)
            Row(
              children: [
                const Text('基础分', style: TextStyle(fontSize: 12)),
                const SizedBox(width: 8),
                SizedBox(
                  width: 84,
                  child: _NumField(
                    key: ValueKey('base-$rowKey'),
                    value: r.base,
                    onChanged: (v) {
                      r.base = v ?? 0;
                      // 手动改过就不再显示自动算出的算式，避免文字与分数对不上。
                      r.detail = '';
                      _markDirty();
                    },
                  ),
                ),
                if (r.title == '学业成绩') ...[
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: _autoAcademic,
                    icon: const Icon(Icons.calculate_outlined, size: 18),
                    label: const Text('自动计算', style: TextStyle(fontSize: 12)),
                  ),
                ],
                if (r.title == '体育成绩') ...[
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: _autoSports,
                    icon: const Icon(Icons.calculate_outlined, size: 18),
                    label: const Text('自动计算', style: TextStyle(fontSize: 12)),
                  ),
                ],
            ],
          ),

          if (r.title == '体育成绩') _buildPeHint(),

          // 加减分记录
          //
          // ⚠️ 条目 key 必须**同层唯一且跨重建稳定**（详见 §9.4.2 的踩坑记录）：
          //  · 用 ValueKey + 「分类-行名-identityHashCode(entry)」，不要用
          //    ObjectKey（它按 identical 比较）；
          //  · key 挂在整个 Padding 上，且说明框、分数框各自也要带 key，
          //    否则增删条目时子树被重建 → 输入框失焦。
          ...r.entries.map((entry) => _buildEntry(entry, r, rowKey)),

          Row(
            children: [
              TextButton.icon(
                onPressed: () {
                  setState(() => r.entries.add(ZongceEntry()));
                  _markDirty();
                },
                icon: const Icon(Icons.add, size: 18),
                label: const Text('加分项', style: TextStyle(fontSize: 12)),
              ),
              // 扣分统一走各育专用的「减分项」行，普通行只留加分项。
              //
              // 原因：细则说「体测不及格 −5 分/次，在运动能力基础分 20 分上扣减」，
              // 即扣分应当记在那个独立的减分项行里。若普通行也能加负数，
              // 用户会在两处都记一次（真机实测出现过），虽然总分不一定算错，
              // 但表上会出现两处扣分、老师核对时对不上。
              if (r.isDeduction)
                TextButton.icon(
                  onPressed: () {
                    setState(() => r.entries.add(ZongceEntry(value: -1)));
                    _markDirty();
                  },
                  icon: const Icon(Icons.remove, size: 18),
                  label: const Text('扣分', style: TextStyle(fontSize: 12)),
                ),
              const Spacer(),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '查看细则',
                onPressed: () => _showHint(r),
                icon: const Icon(Icons.help_outline, size: 18),
              ),
            ],
          ),

          // 普通行里若已存在负数记录（老存档可能这样填过），提示用户迁到减分项行。
          if (!r.isDeduction && r.entries.any((e) => e.value < 0))
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '本行有负数记录。扣分建议填到下方「减分项」行，'
                '以免和加分混在一起、老师核对时对不上。',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),

          if (r.isCapped)
            Text(
              '合计 ${fmtNum(r.rawScore)} 分，超过满分 ${fmtNum(r.cap!)}，已按满分计',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          if (r.isFloored)
            Text(
              '合计 ${fmtNum(r.rawScore)} 分，低于 0，已按 0 计',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
        ],
      ),
    );
  }

  /// 单条加减分记录：说明 + 分数 + 证明图。
  ///
  /// 抽成独立方法（原来内联在 `_buildRowCard` 里）是为了让 key 的构造
  /// 集中在一处，避免以后有人又改回不稳定的写法。
  Widget _buildEntry(ZongceEntry entry, ZongceRow row, String rowKey) {
    final entryKey = identityHashCode(entry);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      // key 挂在最外层 Padding：增删条目时 Flutter 按 key 配对，不会错位重建。
      key: ValueKey('entry-$rowKey-$entryKey'),
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  key: ValueKey('note-$rowKey-$entryKey'),
                  initialValue: entry.note,
                  decoration: const InputDecoration(
                    hintText: '说明，如：献血',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(fontSize: 13),
                  onChanged: (v) {
                    entry.note = v;
                    _markDirty();
                  },
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 72,
                child: _NumField(
                  key: ValueKey('val-$rowKey-$entryKey'),
                  value: entry.value,
                  hint: '±分',
                  onChanged: (v) {
                    entry.value = v ?? 0;
                    _markDirty();
                  },
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '删除这条',
                onPressed: () {
                  setState(() => row.entries.remove(entry));
                  _markDirty();
                },
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
          // 证明图
          Row(
            children: [
              TextButton.icon(
                onPressed: () => _pickImages(entry),
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
                label: Text(
                  entry.images.isEmpty
                      ? '上传证明图'
                      : '证明图 ${entry.images.length} 张',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              Expanded(
                child: SizedBox(
                  height: 46,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final p in entry.images)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Stack(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: Image.file(
                                  File(p),
                                  width: 44,
                                  height: 44,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => Container(
                                    width: 44,
                                    height: 44,
                                    color: scheme.surfaceContainerHighest,
                                    child: const Icon(
                                      Icons.broken_image_outlined,
                                      size: 18,
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                right: 0,
                                top: 0,
                                child: InkWell(
                                  onTap: () => setState(
                                    () => entry.images.remove(p),
                                  ),
                                  child: Container(
                                    decoration: const BoxDecoration(
                                      color: Colors.black54,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.close,
                                      size: 13,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 体育成绩那行的换算提示。
  Widget _buildPeHint() {
    final pe = _peCourseScore;
    final fit = _f.fitnessScore;
    final v = _f.computeSportsScore(isSenior: _isSenior, peCourseScore: pe);
    final sb = StringBuffer();
    if (_isSenior) {
      sb.write('公式：体测 × 60%');
    } else {
      sb.write('公式：（体育课 × 50% + 体测 × 50%）× 60%');
    }
    sb.write('\n体育课成绩：${pe == null ? '该学期未取到' : fmtNum(pe)}');
    sb.write('　体测成绩：${fit == null ? '未填' : fmtNum(fit)}');
    if (v != null) sb.write('\n算得：${fmtNum(v)} 分');
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Text(
        sb.toString(),
        style: TextStyle(
          fontSize: 11,
          height: 1.5,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  void _showHint(ZongceRow r) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(r.title),
        content: SingleChildScrollView(
          child: Text(
            r.hint.isEmpty ? '暂无细则说明。' : r.hint,
            style: const TextStyle(fontSize: 13, height: 1.6),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Widget _buildTotalCard() {
    final total = _f.total;
    final level = _f.level;
    final scheme = Theme.of(context).colorScheme;
    final levelColor = switch (level) {
      '优秀' => scheme.primary,
      '良好' => Colors.green.shade700,
      '合格' => scheme.onSurfaceVariant,
      _ => scheme.error,
    };

    return Card(
      color: scheme.primaryContainer.withAlpha(110),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('预览（总分）', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            ..._f.categories.map((c) {
              final pct = (c.weight * 100).round();
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 76,
                      child: Text(
                        '${c.name.replaceAll('素质', '')} $pct%',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        '${fmtNum(c.score)} × $pct%',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    Text(
                      fmtNum(c.weighted),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              );
            }),
            const Divider(),
            Row(
              children: [
                const Text(
                  '总分',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
                const Spacer(),
                Text(
                  total.toStringAsFixed(2),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 22,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: levelColor.withAlpha(38),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: levelColor),
                  ),
                  child: Text(
                    level,
                    style: TextStyle(
                      color: levelColor,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '总分四舍五入保留两位小数',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExportButton() {
    final imgCount = _f.categories
        .expand((c) => c.rows)
        .fold<int>(0, (a, r) => a + r.allImages.length);
    return Column(
      children: [
        FilledButton.icon(
          onPressed: _busy ? null : _export,
          icon: const Icon(Icons.description_outlined),
          label: const Text('导出 Word 自评表'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
        ),
        const SizedBox(height: 6),
        Text(
          (Platform.isAndroid
                  ? '导出后弹出系统分享，可直接发给老师；也可选「保存到文件」'
                  : '导出到程序目录下的 screen 文件夹，可用 Word/WPS 直接编辑') +
              (imgCount > 0 ? '\n将嵌入 $imgCount 张证明图' : ''),
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// 只接受数字（含负号与小数点）的输入框。
class _NumField extends StatefulWidget {
  const _NumField({
    super.key,
    required this.value,
    required this.onChanged,
    this.hint,
  });

  final double value;
  final ValueChanged<double?> onChanged;
  final String? hint;

  @override
  State<_NumField> createState() => _NumFieldState();
}

class _NumFieldState extends State<_NumField> {
  late final TextEditingController _c;
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _c = TextEditingController(text: _fmt(widget.value));
  }

  /// 回填外部改动（如「自动计算」写入 base）。
  ///
  /// ⚠️ 用户正在输入时**绝不能**覆盖：输入负数的第一个字符 `-` 会被
  /// `double.tryParse` 解析成 null（视作 0），回填会把刚敲的 `-` 改成 `0`，
  /// 导致根本没法输入负数。
  @override
  void didUpdateWidget(_NumField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value == oldWidget.value) return;
    if (_focus.hasFocus) return;
    final current = double.tryParse(_c.text.trim());
    if (current != widget.value) {
      _c.text = _fmt(widget.value);
    }
  }

  static String _fmt(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toString();
  }

  @override
  void dispose() {
    _focus.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _c,
      focusNode: _focus,
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'^-?\d*\.?\d*')),
      ],
      decoration: InputDecoration(
        hintText: widget.hint,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      style: const TextStyle(fontSize: 13),
      onChanged: (v) => widget.onChanged(double.tryParse(v.trim())),
    );
  }
}

/// 智育自动计算的选择结果。
class _AcademicPickResult {
  final double score;
  final double average;
  final int counted;

  /// 供导出用的算式说明（「共 x 科，（…）/x = 平均分」）。
  final String detail;

  const _AcademicPickResult({
    required this.score,
    required this.average,
    required this.counted,
    this.detail = '',
  });
}

/// 课程勾选弹窗：列出候选课程，自动勾选、允许手动调整，并标出可疑项。
class _AcademicPickDialog extends StatefulWidget {
  const _AcademicPickDialog({required this.grades, required this.term});

  final List<Map<String, String>> grades;
  final String term;

  @override
  State<_AcademicPickDialog> createState() => _AcademicPickDialogState();
}

class _AcademicPickDialogState extends State<_AcademicPickDialog> {
  late AcademicAutoResult _result;

  @override
  void initState() {
    super.initState();
    // 固定用页面所选学期，不再提供「全部学期」——综测是按学期评的。
    _result = buildAcademicAuto(widget.grades, term: widget.term);
  }

  @override
  Widget build(BuildContext context) {
    final avg = _result.average;
    final score = _result.academicScore;
    final nonNumeric = _result.selectedNonNumeric;

    return AlertDialog(
      title: const Text('从成绩自动计算学业成绩'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '学期：${widget.term.isEmpty ? '未选择' : widget.term}',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              '已勾选 ${_result.countedCount} 门课，平均分 '
              '${avg == null ? '—' : avg.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 13),
            ),
            Text(
              '学业成绩 = 平均分 × 90% = ${score == null ? '—' : score.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 6),
            Text(
              '细则要求排除体育课、网络通识课、公共选修课、等级课程。'
              '已自动判断并预勾选，请**核对**下面的列表——'
              '判断依据是课程名与课程性质，可能与学院口径不同。',
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            if (nonNumeric.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '⚠ 有 ${nonNumeric.length} 门课是文字成绩（如「良」），'
                  '无法参与平均，请取消勾选或手动核算。',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            const Divider(),
            Flexible(
              child: _result.courses.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('该学期没有可取的成绩。'),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _result.courses.length,
                      itemBuilder: (ctx, i) {
                        final c = _result.courses[i];
                        final suspect = !c.hasNumericScore;
                        return CheckboxListTile(
                          dense: true,
                          value: c.selected,
                          onChanged: (v) {
                            setState(() => c.selected = v ?? false);
                          },
                          title: Text(
                            c.course,
                            style: TextStyle(
                              fontSize: 13,
                              color: suspect
                                  ? Theme.of(context).colorScheme.error
                                  : null,
                            ),
                          ),
                          subtitle: Text(
                            [
                              if (c.courseType.isNotEmpty) c.courseType,
                              if (c.rawGrade.isNotEmpty) '成绩 ${c.rawGrade}',
                              if (c.excludedReason.isNotEmpty) c.excludedReason,
                            ].join(' · '),
                            style: const TextStyle(fontSize: 11),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: score == null
              ? null
              : () => Navigator.of(context).pop(
                  _AcademicPickResult(
                    score: score,
                    average: avg!,
                    counted: _result.countedCount,
                    detail: _result.describeCalculation(fmtNum),
                  ),
                ),
          child: const Text('采用这个分数'),
        ),
      ],
    );
  }
}

/// 体测成绩导入确认弹窗：展示识别到的表头与匹配行，让用户确认后再填入。
class _FitnessImportDialog extends StatelessWidget {
  const _FitnessImportDialog({
    required this.cols,
    required this.matches,
    required this.studentId,
    required this.name,
  });

  final SheetColumns cols;
  final List<FitnessSheetMatch> matches;
  final String studentId;
  final String name;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('确认导入体测成绩'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('识别到的表头：', style: TextStyle(fontWeight: FontWeight.w600)),
              Text(
                cols.headerTexts.where((e) => e.trim().isNotEmpty).join(' | '),
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 6),
              Text(
                '筛选条件：学号 = $studentId，姓名 = $name'
                '（两者都必须相同，避免重名误取）',
                style: const TextStyle(fontSize: 12),
              ),
              const Divider(),
              Text(
                matches.length == 1 ? '匹配到 1 行：' : '匹配到 ${matches.length} 行：',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              for (final m in matches)
                Card(
                  margin: const EdgeInsets.only(top: 6),
                  child: ListTile(
                    dense: true,
                    title: Text('${m.studentId}　${m.name}'),
                    subtitle: Text('总分列的值：${m.rawTotal.isEmpty ? '（空）' : m.rawTotal}'),
                    trailing: m.total == null
                        ? const Text('非数字', style: TextStyle(fontSize: 12))
                        : Text(
                            '${m.total}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                '确认无误后点「采用」写入体测成绩；若表里有重复行（如补考记录），'
                '请选总分正确的那条。',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: matches.length == 1
              ? () => Navigator.of(context).pop(matches.first)
              : null,
          child: Text(matches.length == 1 ? '采用' : '多行请改用单条（见下）'),
        ),
        if (matches.length > 1)
          ...matches.asMap().entries.map(
            (e) => TextButton(
              onPressed: () => Navigator.of(context).pop(e.value),
              child: Text('用第 ${e.key + 1} 行（${e.value.rawTotal}）'),
            ),
          ),
      ],
    );
  }
}
