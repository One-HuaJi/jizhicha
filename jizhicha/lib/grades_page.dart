import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'academic_calendar.dart';
import 'app_mode.dart';
import 'app_settings.dart';
import 'auth_pages.dart';
import 'campus_environment.dart';
import 'campus_sync_helpers.dart';
import 'common.dart';
import 'offline_sync.dart';
import 'schedule_cache_store.dart';
import 'sync_cooldown.dart';

// ==================== 成绩页 ====================
class GradesPage extends StatefulWidget {
  final String studentId;

  const GradesPage({required this.studentId, super.key});

  @override
  State<GradesPage> createState() => _GradesPageState();
}

class _GradesPageState extends State<GradesPage>
    with CampusSyncHelpers<GradesPage> {
  /// [CampusSyncHelpers] 需要知道当前页面对应的学号。
  @override
  String get campusStudentId => widget.studentId;
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
    appSettingsRevision.addListener(_reloadDisplaySettings);
    campusEnvironment.addListener(_refreshCampusEnvironment);
    dataSyncCooldown.addListener(_refreshSyncCooldown);
    _loadLocal();
  }

  @override
  void dispose() {
    appSettingsRevision.removeListener(_reloadDisplaySettings);
    campusEnvironment.removeListener(_refreshCampusEnvironment);
    dataSyncCooldown.removeListener(_refreshSyncCooldown);
    super.dispose();
  }

  void _refreshCampusEnvironment() {
    if (mounted) setState(() {});
    if (mounted && campusEnvironment.consumeDropDetected()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('校园加速器已断开，请重新连接')),
      );
    }
  }

  void _refreshSyncCooldown() {
    if (mounted) setState(() {});
  }

  Future<void> _openAcceleratorSetup() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VpnSetupPage(mode: AppMode.education),
      ),
    );
    if (mounted) await campusEnvironment.detect();
  }


  /// 手动刷新成绩默认只请求最新学期；可切换为指定学期或全部已知学期。
  /// 校园内网和当前教务会话都有效时直接请求，不重复打开认证页。
  Future<void> _openGradeUpdate() async {
    if (_loading) return;
    if (dataSyncCooldown.isCooling(SyncResource.grade)) {
      showSyncCooldownMessage(SyncResource.grade);
      return;
    }
    final selected = _selectedGradeUpdateTerm;
    final fetchAll = selected == _allGradeTermsValue;
    final term = fetchAll || selected == null ? null : selected;
    final scope = fetchAll ? GradeSyncScope.all : GradeSyncScope.latest;
    if (await canReuseEducationSession()) {
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

  Future<void> _handleCampusAcceleratorAction() =>
      handleCampusAcceleratorAction(context, openVpnSetup: _openAcceleratorSetup);

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
          onPressed: () => switchToSavedAccount(
            context,
            currentStudentId: widget.studentId,
          ),
          icon: const Icon(Icons.switch_account, size: 18),
          label: const Text('切换用户'),
        ),
        if (!campusEnvironment.checking)
          TextButton.icon(
            onPressed: campusEnvironment.actionLoading ||
                    campusEnvironment.reconnecting
                ? null
                : _handleCampusAcceleratorAction,
            icon: campusEnvironment.actionLoading ||
                    campusEnvironment.reconnecting
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    campusEnvironment.online == true
                        ? Icons.logout
                        : Icons.vpn_lock,
                    size: 18,
                  ),
            label: Text(
              campusEnvironment.reconnecting
                  ? '重连中'
                  : campusEnvironment.actionLoading
                  ? '正在登出…'
                  : campusEnvironment.online == true
                  ? '登出加速器'
                  : '连接校园加速器',
            ),
          ),
      ],
    );
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
            child: SyncCooldownIndicator(resource: SyncResource.grade),
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
                    '${formatCachedAt(_cachedAt!)}',
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
              '${_cachedAt == null ? '' : ' · ${formatCachedAt(_cachedAt!)}'}',
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

  List<MapEntry<String, String>> _gradeDetailEntries(_GradeArchive a) => [
    MapEntry('课程名称', a.course.isEmpty ? '未知课程' : a.course),
    MapEntry('成绩', a.grade.isEmpty ? '-' : a.grade),
    MapEntry('学分', a.credit.isEmpty ? '-' : a.credit),
    MapEntry('课程性质', a.courseType.isEmpty ? '-' : a.courseType),
    MapEntry('课程编码', a.code.isEmpty ? '-' : a.code),
    MapEntry('开课学期', a.term.isEmpty ? '-' : a.term),
  ];

  String _gradeSummary(_GradeArchive a) {
    return [
      if (a.credit.isNotEmpty) '学分 ${a.credit}',
      if (a.courseType.isNotEmpty) a.courseType,
      if (a.code.isNotEmpty) '编码 ${a.code}',
      if (a.term.isNotEmpty) '学期 ${a.term}',
    ].join('  ·  ');
  }

  String _gradeCopyText(_GradeArchive a) => _gradeDetailEntries(
    a,
  ).map((entry) => '${entry.key}：${entry.value}').join('\n');

  Future<void> _copyGradeText(
    String label,
    String value, {
    BuildContext? feedbackContext,
  }) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(feedbackContext ?? context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('已复制$label')));
  }

  Future<void> _showGradeDetails(_GradeArchive a, Color accent) async {
    final colorScheme = Theme.of(context).colorScheme;
    final entries = _gradeDetailEntries(a);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: colorScheme.surface,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.82,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        a.course.isEmpty ? '未知课程' : a.course,
                        style: TextStyle(
                          fontSize: 22,
                          height: 1.25,
                          fontWeight: FontWeight.w700,
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      a.grade.isEmpty ? '-' : a.grade,
                      style: TextStyle(
                        fontSize: 28,
                        height: 1.1,
                        fontWeight: FontWeight.w700,
                        color: a.isFail ? colorScheme.error : accent,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  a.isFail ? '历史补考 / 重修' : '已完成',
                  style: TextStyle(
                    fontSize: 13,
                    color: a.isFail ? colorScheme.error : accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 14),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: colorScheme.outlineVariant),
                  ),
                  child: Column(
                    children: [
                      for (var index = 0; index < entries.length; index++) ...[
                        ListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 2,
                          ),
                          title: Text(
                            entries[index].key,
                            style: TextStyle(
                              fontSize: 13,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: SelectableText(
                              entries[index].value,
                              style: TextStyle(
                                fontSize: 16,
                                height: 1.35,
                                color: colorScheme.onSurface,
                              ),
                            ),
                          ),
                          trailing: IconButton(
                            tooltip: '复制${entries[index].key}',
                            icon: const Icon(Icons.copy, size: 19),
                            onPressed: () => _copyGradeText(
                              entries[index].key,
                              entries[index].value,
                              feedbackContext: sheetContext,
                            ),
                          ),
                        ),
                        if (index < entries.length - 1)
                          Divider(
                            height: 1,
                            indent: 14,
                            endIndent: 14,
                            color: colorScheme.outlineVariant,
                          ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: () => _copyGradeText(
                    '全部成绩信息',
                    _gradeCopyText(a),
                    feedbackContext: sheetContext,
                  ),
                  icon: const Icon(Icons.copy_all),
                  label: const Text('复制全部信息'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 单门课程卡片：第一行显示「课程名称 + 得分」，第二行显示完整摘要。
  /// 手机端摘要会自动换行；点击卡片可以打开更大的可复制详情。
  Widget _buildGradeCard(_GradeArchive a, Color color) {
    final failed = a.isFail;
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        onTap: () => _showGradeDetails(a, color),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      a.course.isEmpty ? '未知课程' : a.course,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.25,
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      width: double.infinity,
                      height: 18,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _gradeSummary(a).isEmpty
                              ? '暂无课程附加信息'
                              : _gradeSummary(a),
                          maxLines: 1,
                          style: TextStyle(
                            fontSize:
                                MediaQuery.sizeOf(context).shortestSide < 600
                                ? 10
                                : 11,
                            height: 1.2,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                a.grade.isEmpty ? '-' : a.grade,
                style: TextStyle(
                  fontSize: 22,
                  height: 1.1,
                  fontWeight: FontWeight.bold,
                  color: failed ? colorScheme.error : color,
                ),
              ),
            ],
          ),
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
