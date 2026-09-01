import 'dart:io' show Directory, File, Platform;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import 'academic_calendar.dart';
import 'app_mode.dart';
import 'app_settings.dart';
import 'campus_environment.dart';
import 'common.dart';
import 'jwxt_client.dart';
import 'offline_sync.dart';
import 'schedule_cache_store.dart';
import 'schedule_time.dart';
import 'sync_cooldown.dart';
import 'ui_constants.dart';

// ==================== 课表页（带学期选择） ====================
enum _ScheduleExportFormat { jpg, png, html }

class SchedulePage extends StatefulWidget {
  final String studentId;

  const SchedulePage({required this.studentId, super.key});

  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage> {
  static const _latestScheduleTermsValue = '__latest_schedule_term__';
  static const _allScheduleTermsValue = '__all_schedule_terms__';
  final _scheduleRepaintKey = GlobalKey();
  final _scheduleTableRepaintKey = GlobalKey();
  List<String> _terms = const [];
  String _selectedTerm = AcademicCalendar.latestTerm;
  List<Map<String, String>> _courses = [];
  bool _loading = true;
  String? _error;
  String? _emptyMessage;
  String? _debugHtmlPath; // 本次抓到的原始 HTML 落盘路径（解析失败时填，用于排查）
  String _lastRawHtml = ''; // 解析失败时也保留在内存里，便于"显示 HTML 预览"
  bool _showHtmlPreview = false;
  bool _showDiagnostics = false;
  bool _loadedFromCache = false;
  DateTime? _cachedAt;
  String? _selectedScheduleUpdateTerm;
  bool _scheduleToolsExpanded = false;

  // 设置（本地持久化）：本周视图高亮 + 按周筛选，均基于手动选定的"当前周次"。
  AppSettings? _settings;
  @override
  void initState() {
    super.initState();
    appSettingsRevision.addListener(_reloadSettings);
    campusEnvironment.addListener(_refreshCampusEnvironment);
    dataSyncCooldown.addListener(_refreshSyncCooldown);
    _initialize();
  }

  @override
  void dispose() {
    appSettingsRevision.removeListener(_reloadSettings);
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

  void _reloadSettings() {
    AppSettings.load().then((settings) {
      if (mounted) setState(() => _settings = settings);
    });
  }

  Future<void> _saveSettingsAndRefresh() async {
    await _settings?.save();
    notifyAppSettingsChanged();
  }

  Future<void> _detectCampusEnvironment() async {
    await campusEnvironment.detect();
  }

  Future<void> _openVpnSetup() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => buildVpnSetupPage!(mode: AppMode.education),
      ),
    );
    if (mounted) await _detectCampusEnvironment();
  }

  List<String> _scheduleUpdateTerms() {
    final terms = <String>{...AcademicCalendar.terms, ..._terms}.toList();
    terms.sort((a, b) {
      final aIndex = AcademicCalendar.terms.indexOf(a);
      final bIndex = AcademicCalendar.terms.indexOf(b);
      if (aIndex >= 0 && bIndex >= 0) return aIndex.compareTo(bIndex);
      if (aIndex >= 0) return -1;
      if (bIndex >= 0) return 1;
      return b.compareTo(a);
    });
    return terms;
  }

  Future<bool> _canReuseEducationSession() async {
    if (campusEnvironment.checking) await _detectCampusEnvironment();
    if (campusEnvironment.online != true) {
      await _detectCampusEnvironment();
    }
    final client = JwxtClient();
    return campusEnvironment.online == true &&
        client.isLoggedIn &&
        client.authenticatedStudentId == widget.studentId;
  }

  Future<void> _openManualScheduleSave() async {
    final remaining = dataSyncCooldown.remaining(SyncResource.schedule);
    if (remaining > Duration.zero) {
      _showSyncCooldownMessage(SyncResource.schedule);
      return;
    }
    final selected = _selectedScheduleUpdateTerm;
    final fetchAll = selected == _allScheduleTermsValue;
    final term = fetchAll ? null : selected;
    if (await _canReuseEducationSession()) {
      setState(() {
        _loading = true;
        _error = null;
      });
      try {
        final result = await syncOfflineUserData(
          studentId: widget.studentId,
          syncSchedules: true,
          forceScheduleSync: true,
          fetchAllSchedules: fetchAll,
          scheduleTerm: term,
          syncGrades: false,
          onProgress: (message) {
            if (mounted) setState(() => _emptyMessage = message);
          },
        );
        await _initialize();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                result.schedulesFetchedAll
                    ? '已保存 ${result.savedTermCount} 个学期课表'
                    : term == null
                    ? '已更新最新一期课表'
                    : '已更新 $term 课表',
              ),
            ),
          );
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
        builder: (_) => buildVpnSetupPage!(
          mode: AppMode.education,
          forceScheduleSync: true,
          fetchAllSchedules: fetchAll,
          scheduleTerm: term,
          syncGrades: false,
          initialNotice: fetchAll
              ? '本次更新所有已知学期课表'
              : term == null
              ? '本次仅手动保存最新一期已发布课表'
              : '本次仅更新 $term 课表',
        ),
      ),
    );
    if (mounted) {
      await _initialize();
      await _detectCampusEnvironment();
    }
  }

  void _showSyncCooldownMessage(SyncResource resource) {
    final remaining = dataSyncCooldown.remainingText(resource);
    if (remaining.isEmpty || !mounted) return;
    final label = resource == SyncResource.schedule ? '课表' : '成绩';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$label更新冷却中，还需 $remaining 后重试')));
  }

  Future<void> _handleCampusAcceleratorAction() =>
      handleCampusAcceleratorAction(context, openVpnSetup: _openVpnSetup);

  Future<void> _initialize() async {
    final settings = await AppSettings.load();
    // 根据开学日期自动计算当前周次；尚未开始或已超过20周则保留用户上次选择。
    final startDate = DateTime.tryParse(settings.semesterStartDate);
    if (startDate != null) {
      final w = AcademicCalendar.weekNumberFor(startDate, DateTime.now());
      if (w >= 1 && w <= AcademicCalendar.weeksPerAcademicYear) {
        settings.currentWeek = w;
      }
    }
    final profile = await UserDataCacheStore.loadProfile(widget.studentId);
    if (!mounted) return;

    if (profile != null && profile.scheduleTerms.isNotEmpty) {
      final knownTerms = AcademicCalendar.terms
          .where(profile.scheduleTerms.contains)
          .toList(growable: true);
      final unknownTerms =
          profile.scheduleTerms
              .where((term) => !AcademicCalendar.terms.contains(term))
              .toList(growable: false)
            ..sort((a, b) => b.compareTo(a));
      knownTerms.addAll(unknownTerms);
      final selectedTerm = knownTerms.contains(AcademicCalendar.latestTerm)
          ? AcademicCalendar.latestTerm
          : knownTerms.first;
      setState(() {
        _settings = settings;
        _terms = knownTerms;
        _selectedTerm = selectedTerm;
        _loadedFromCache = true;
        _cachedAt = profile.savedAt;
      });
      await _loadLocalTerm(selectedTerm);
      _applySundayAdjustment();
      return;
    }

    // 兼容旧版仅保存“最新学期解析结果”的缓存。新认证完成后会自动迁移到
    // 每学期一份静态 HTML 的完整离线目录。
    final legacy = await ScheduleCacheStore.loadLatest(widget.studentId);
    if (!mounted) return;
    if (legacy != null) {
      setState(() {
        _settings = settings;
        _terms = [legacy.term];
        _selectedTerm = legacy.term;
        _courses = legacy.courses
            .map((course) => Map<String, String>.from(course))
            .toList(growable: false);
        _emptyMessage = legacy.courses.isEmpty
            ? _emptyMessageFor(legacy.term)
            : null;
        _loading = false;
        _loadedFromCache = true;
        _cachedAt = legacy.savedAt;
      });
      _applySundayAdjustment();
      return;
    }

    setState(() {
      _settings = settings;
      _loading = false;
      _emptyMessage = '暂无本地课表，请连接校园加速器后认证并保存';
    });
  }

  // 设置未加载完成时的兜底：两功能都关、周次 1。
  AppSettings get _s => _settings ?? AppSettings();

  /// 当前日期是否已经超过本学期的 20 周范围。
  bool get _semesterEnded {
    final start = DateTime.tryParse(_s.semesterStartDate);
    if (start == null) return false;
    return AcademicCalendar.weekNumberFor(start, DateTime.now()) >
        AcademicCalendar.weeksPerAcademicYear;
  }

  /// 学期已结束的提示条。
  Widget _buildSemesterEndedBanner(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 6, 14, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            Icons.event_busy,
            size: 18,
            color: colorScheme.onTertiaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '预设学期已结束，请手动更改开学日期',
              style: TextStyle(
                fontSize: 13,
                color: colorScheme.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 应用"按周筛选"：开启时只保留当前周次有课的课程。
  List<Map<String, String>> get _visibleCourses {
    if (!_s.filterByWeek) return _courses;
    final w = _s.currentWeek;
    return _courses.where((c) => weekInWeeks(c['weeks'] ?? '', w)).toList();
  }

  String _emptyMessageFor(String term) {
    return term == AcademicCalendar.latestTerm &&
            AcademicCalendar.isBeforeLatestTermQueryDate(DateTime.now())
        ? '课表为空，可能是未开放查询'
        : '暂无课程安排';
  }

  String _formatCachedAt(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}';
  }

  Future<void> _loadLocalTerm(String term) async {
    setState(() {
      _selectedTerm = term;
      _loading = true;
      _error = null;
      _emptyMessage = null;
      _courses = [];
      _debugHtmlPath = null;
      _showHtmlPreview = false;
      _lastRawHtml = '';
    });
    try {
      final rawHtml = await UserDataCacheStore.loadScheduleHtml(
        widget.studentId,
        term,
      );
      if (!mounted) return;
      if (rawHtml == null) {
        setState(() {
          _emptyMessage = '该学期暂无本地课表，请重新连接校园加速器后认证并保存';
          _loading = false;
        });
        return;
      }
      final courses = parseScheduleHtml(rawHtml);
      setState(() {
        _lastRawHtml = rawHtml;
        _courses = courses;
        _emptyMessage = courses.isEmpty ? _emptyMessageFor(term) : null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '本地课表文件无法读取，请重新连接校园加速器后认证并保存';
        _emptyMessage = null;
        _loading = false;
      });
    }
  }

  /// 周日特殊处理：今天若是周日，且本周周日没有课，则自动跳到下一周并提示一次。
  void _applySundayAdjustment() {
    if (_settings == null) return;
    final now = DateTime.now();
    if (now.weekday != DateTime.sunday) return;
    final current = _settings!.currentWeek;
    if (current < 1 || current >= AcademicCalendar.weeksPerAcademicYear) {
      return;
    }
    final sundayHasCourse = _courses.any(
      (c) =>
          (c['day'] ?? '') == '周日' &&
          weekInWeeks(c['weeks'] ?? '', current),
    );
    if (sundayHasCourse) return;
    setState(() => _settings!.currentWeek = current + 1);
    _saveSettingsAndRefresh();
    _showSundayPrompt();
  }

  void _showSundayPrompt() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          "今日为周日，为您显示下周课表，不要看错了- ̗̀ ෆ( ˶'ᵕ'˶)ෆ ̖́-",
          style: TextStyle(fontSize: 13),
        ),
        duration: Duration(seconds: 5),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _scheduleAccountSummary() {
    if (_loadedFromCache) {
      return '账号 ${widget.studentId} · 本地课表'
          '${_cachedAt == null ? '' : ' · ${_formatCachedAt(_cachedAt!)}'}';
    }
    return '账号 ${widget.studentId} 暂无本地课表';
  }

  String _campusModeSummary() => campusEnvironment.statusSummary;

  Widget _buildScheduleAcceleratorAction(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final online = campusEnvironment.online == true;
    final busy =
        campusEnvironment.actionLoading || campusEnvironment.reconnecting;
    return OutlinedButton.icon(
      onPressed: busy ? null : _handleCampusAcceleratorAction,
      icon: busy
          ? const SizedBox.square(
              dimension: 15,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(online ? Icons.logout : Icons.vpn_lock, size: 16),
      label: Text(
        campusEnvironment.reconnecting
            ? '重连中'
            : campusEnvironment.actionLoading
            ? '处理中…'
            : online
            ? '登出加速器'
            : '连接校园加速器',
      ),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        foregroundColor: online ? colorScheme.tertiary : colorScheme.primary,
      ),
    );
  }

  Widget _buildScheduleAccountStatus(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final online = campusEnvironment.online == true;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colorScheme.outlineVariant.withAlpha(150)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          child: Row(
            children: [
              Expanded(
                child: Tooltip(
                  message: '点击切换账号',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => switchToSavedAccount(
                      context,
                      currentStudentId: widget.studentId,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Icon(
                                Icons.person_outline,
                                size: 19,
                                color: colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _scheduleAccountSummary(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: colorScheme.onSurface,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '当前查看：${_selectedTerm.isEmpty ? '未选择学期' : _selectedTerm}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _buildScheduleAcceleratorAction(context),
              const SizedBox(width: 8),
              Tooltip(
                message: '点击重新检测是否为校内环境',
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: campusEnvironment.checking
                      ? null
                      : _detectCampusEnvironment,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 7,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        campusEnvironment.checking
                            ? SizedBox.square(
                                dimension: 15,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: colorScheme.primary,
                                ),
                              )
                            : Icon(
                                online ? Icons.wifi : Icons.cloud_off,
                                size: 17,
                                color: online
                                    ? colorScheme.tertiary
                                    : colorScheme.onSurfaceVariant,
                              ),
                        const SizedBox(width: 6),
                        Text(
                          campusEnvironment.statusShort,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: online
                                ? colorScheme.tertiary
                                : colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          Icons.refresh,
                          size: 14,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCompactScheduleStatus(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final online = campusEnvironment.online == true;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Tooltip(
              message: '点击切换账号',
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => switchToSavedAccount(
                  context,
                  currentStudentId: widget.studentId,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _scheduleAccountSummary(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${_selectedTerm.isEmpty ? '未选择学期' : _selectedTerm} · ${_campusModeSummary()}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: online
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          _buildCompactWeekChip(context),
          IconButton(
            tooltip: campusEnvironment.reconnecting
                ? '重连中'
                : campusEnvironment.online == true
                ? '登出校园加速器'
                : '连接校园加速器',
            onPressed: campusEnvironment.actionLoading ||
                    campusEnvironment.reconnecting
                ? null
                : _handleCampusAcceleratorAction,
            icon: campusEnvironment.actionLoading ||
                    campusEnvironment.reconnecting
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    campusEnvironment.online == true
                        ? Icons.logout
                        : Icons.vpn_lock,
                    size: 20,
                  ),
          ),
          IconButton(
            tooltip: '重新检测校园内网',
            onPressed: campusEnvironment.checking
                ? null
                : _detectCampusEnvironment,
            icon: campusEnvironment.checking
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(online ? Icons.wifi : Icons.cloud_off, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _buildScheduleTermSelector({bool embedded = false}) {
    final selector = DropdownButtonFormField<String>(
      key: ValueKey(_selectedTerm),
      decoration: const InputDecoration(
        labelText: '查看学期',
        labelStyle: TextStyle(fontSize: 12),
        border: OutlineInputBorder(),
        prefixIcon: Icon(Icons.calendar_month, size: 18),
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),
      initialValue: _terms.contains(_selectedTerm) ? _selectedTerm : null,
      isExpanded: true,
      items: _terms
          .map(
            (term) => DropdownMenuItem(
              value: term,
              child: Text(
                term,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          )
          .toList(),
      onChanged: _loading
          ? null
          : (value) {
              if (value == null || value == _selectedTerm) return;
              _loadLocalTerm(value);
            },
    );
    if (embedded) return selector;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: selector,
    );
  }

  Widget _buildScheduleViewControls(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final weekFilter = (_s.highlightCurrentWeek || _s.filterByWeek)
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _s.filterByWeek && _s.highlightCurrentWeek
                    ? '高亮+筛选'
                    : _s.filterByWeek
                    ? '按周筛选'
                    : '本周视图',
                style: TextStyle(fontSize: 12, color: colorScheme.onSurface),
              ),
              const SizedBox(width: 4),
              DropdownButton<int>(
                value: _s.currentWeek,
                isDense: true,
                items: List.generate(
                  AcademicCalendar.weeksPerAcademicYear,
                  (index) => DropdownMenuItem(
                    value: index + 1,
                    child: Text('第${index + 1}周'),
                  ),
                ),
                onChanged: _settings == null
                    ? null
                    : (value) {
                        if (value == null) return;
                        setState(() => _settings!.currentWeek = value);
                        _saveSettingsAndRefresh();
                      },
              ),
            ],
          )
        : Text(
            '未启用周视图',
            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: Row(children: [weekFilter, const Spacer()]),
    );
  }

  /// 紧凑的周次选择按钮：内嵌进顶部状态栏，不额外占一整行。
  /// 点击"第N周"弹出完整周次选择，避免顶部越堆越高。
  /// 学期进度条：以 15 周（教学周）为结束；超过 15 周时左侧仍显示实际周次，
  /// 进度条保持满格，避免越界报错。
  Widget _buildWeekProgressBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final week = _s.currentWeek;
    const total = AppDimens.progressBarWeeks;
    final progress = (week / total).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
      child: Row(
        children: [
          Text(
            '第 $week 周',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: AppDimens.progressBarHeight,
                backgroundColor: colorScheme.surfaceContainerHighest,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '共 $total 周',
            style: TextStyle(
              fontSize: 11,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactWeekChip(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final week = _s.currentWeek;
    return Tooltip(
      message: '切换查看周次',
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: _openWeekPicker,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.view_week_outlined,
                size: 15,
                color: colorScheme.onPrimaryContainer,
              ),
              const SizedBox(width: 4),
              Text(
                '第$week周',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onPrimaryContainer,
                ),
              ),
              Icon(
                Icons.arrow_drop_down,
                size: 16,
                color: colorScheme.onPrimaryContainer,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openWeekPicker() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '选择查看周次',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: List.generate(
                    AcademicCalendar.weeksPerAcademicYear,
                    (index) {
                      final week = index + 1;
                      final selected = week == _s.currentWeek;
                      return ChoiceChip(
                        label: Text('第$week周'),
                        selected: selected,
                        onSelected: (_) {
                          Navigator.of(sheetContext).pop();
                          if (!mounted || _settings == null) return;
                          setState(() => _settings!.currentWeek = week);
                          _saveSettingsAndRefresh();
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildScheduleUpdateControls(
    BuildContext context, {
    required List<String> updateTerms,
    required String selectedUpdateValue,
    required bool compact,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final selector = _buildScheduleUpdateSelector(
            updateTerms: updateTerms,
            selectedUpdateValue: selectedUpdateValue,
          );
          final selectorBox = compact
              ? Expanded(child: selector)
              : SizedBox(width: 300, child: selector);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  selectorBox,
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed:
                        _loading ||
                            dataSyncCooldown.isCooling(SyncResource.schedule)
                        ? null
                        : _openManualScheduleSave,
                    icon: const Icon(Icons.sync, size: 16),
                    label: Text(compact ? '更新' : '更新课表'),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(0, AppDimens.toolsButtonMinHeight),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                  ),
                  if (!compact) const Spacer(),
                ],
              ),
              const SizedBox(height: 6),
              SyncCooldownIndicator(resource: SyncResource.schedule),
              const SizedBox(height: 2),
              OutlinedButton.icon(
                onPressed: _lastRawHtml.isEmpty ? null : _chooseScheduleExport,
                icon: const Icon(Icons.save_alt, size: 15),
                label: const Text('导出课表'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildScheduleUpdateSelector({
    required List<String> updateTerms,
    required String selectedUpdateValue,
  }) {
    return DropdownButtonFormField<String>(
      key: ValueKey(
        'schedule-update-$selectedUpdateValue-${updateTerms.join('|')}',
      ),
      initialValue:
          updateTerms.contains(selectedUpdateValue) ||
              selectedUpdateValue == _latestScheduleTermsValue ||
              selectedUpdateValue == _allScheduleTermsValue
          ? selectedUpdateValue
          : _latestScheduleTermsValue,
      decoration: const InputDecoration(
        labelText: '更新范围',
        labelStyle: TextStyle(fontSize: 12),
        prefixIcon: Icon(Icons.sync, size: 18),
        border: OutlineInputBorder(),
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),
      isExpanded: true,
      items: [
        const DropdownMenuItem(
          value: _latestScheduleTermsValue,
          child: Text(
            '最新一期',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12),
          ),
        ),
        const DropdownMenuItem(
          value: _allScheduleTermsValue,
          child: Text(
            '所有已知学期',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12),
          ),
        ),
        ...updateTerms.map(
          (term) => DropdownMenuItem(
            value: term,
            child: Text(
              term,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ),
      ],
      onChanged: _loading
          ? null
          : (value) {
              if (value == null) return;
              setState(() {
                _selectedScheduleUpdateTerm = value == _latestScheduleTermsValue
                    ? null
                    : value;
              });
            },
    );
  }

  Widget _buildDesktopWeekSelector(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DropdownButtonFormField<int>(
      key: ValueKey('schedule-week-${_s.currentWeek}'),
      initialValue: _s.currentWeek,
      decoration: InputDecoration(
        labelText: _s.filterByWeek ? '按周筛选' : '当前周视图',
        prefixIcon: const Icon(Icons.view_week_outlined),
        border: const OutlineInputBorder(),
        isDense: true,
        helperStyle: TextStyle(color: colorScheme.onSurfaceVariant),
      ),
      isExpanded: true,
      items: List.generate(
        AcademicCalendar.weeksPerAcademicYear,
        (index) =>
            DropdownMenuItem(value: index + 1, child: Text('第${index + 1}周')),
      ),
      onChanged: _settings == null
          ? null
          : (value) {
              if (value == null) return;
              setState(() => _settings!.currentWeek = value);
              _saveSettingsAndRefresh();
            },
    );
  }

  Widget _buildDesktopScheduleTools(
    BuildContext context, {
    required List<String> updateTerms,
    required String selectedUpdateValue,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: colorScheme.outlineVariant.withAlpha(150)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 1160;
              final fields = [
                SizedBox(
                  width: narrow ? 190 : 240,
                  child: _buildScheduleTermSelector(embedded: true),
                ),
                SizedBox(
                  width: narrow ? 150 : 175,
                  child: _buildDesktopWeekSelector(context),
                ),
                SizedBox(
                  width: narrow ? 270 : 320,
                  child: _buildScheduleUpdateSelector(
                    updateTerms: updateTerms,
                    selectedUpdateValue: selectedUpdateValue,
                  ),
                ),
                FilledButton.icon(
                  onPressed:
                      _loading ||
                          dataSyncCooldown.isCooling(SyncResource.schedule)
                      ? null
                      : _openManualScheduleSave,
                  icon: _loading
                      ? const SizedBox.square(
                          dimension: 17,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync, size: 18),
                  label: const Text('更新课表'),
                ),
                OutlinedButton.icon(
                  onPressed: _lastRawHtml.isEmpty
                      ? null
                      : _chooseScheduleExport,
                  icon: const Icon(Icons.more_horiz, size: 18),
                  label: const Text('更多'),
                ),
              ];
              final content = narrow
                  ? Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: fields,
                    )
                  : Row(
                      children: [
                        for (var i = 0; i < fields.length; i++) ...[
                          if (i > 0) const SizedBox(width: 10),
                          fields[i],
                        ],
                      ],
                    );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  content,
                  const SizedBox(height: 8),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: SyncCooldownIndicator(
                      key: ValueKey(
                        dataSyncCooldown.remainingText(SyncResource.schedule),
                      ),
                      resource: SyncResource.schedule,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildScheduleTools(
    BuildContext context, {
    required List<String> updateTerms,
    required String selectedUpdateValue,
    required bool compact,
  }) {
    return Column(
      children: [
        _buildScheduleTermSelector(),
        _buildScheduleViewControls(context),
        _buildScheduleUpdateControls(
          context,
          updateTerms: updateTerms,
          selectedUpdateValue: selectedUpdateValue,
          compact: compact,
        ),
      ],
    );
  }

  Widget _buildCompactScheduleTools(
    BuildContext context, {
    required List<String> updateTerms,
    required String selectedUpdateValue,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        child: Column(
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () => setState(
                () => _scheduleToolsExpanded = !_scheduleToolsExpanded,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 9, 10, 9),
                child: Row(
                  children: [
                    Icon(Icons.tune, size: 19, color: colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _scheduleToolsExpanded ? '收起课表操作' : '课表操作',
                        style: TextStyle(
                          fontSize: AppDimens.toolsTitleFont,
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ),
                    Text(
                      _scheduleToolsExpanded ? '点击收起' : '学期 / 导出 / 更新',
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      _scheduleToolsExpanded
                          ? Icons.expand_less
                          : Icons.expand_more,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: _scheduleToolsExpanded
                  ? _buildScheduleTools(
                      context,
                      updateTerms: updateTerms,
                      selectedUpdateValue: selectedUpdateValue,
                      compact: true,
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final updateTerms = _scheduleUpdateTerms();
    final selectedUpdateValue = _selectedScheduleUpdateTerm == null
        ? _latestScheduleTermsValue
        : _selectedScheduleUpdateTerm!;
    final compact = MediaQuery.sizeOf(context).shortestSide < 600;
    final pure =
        compact &&
        MediaQuery.orientationOf(context) == Orientation.landscape;
    return Scaffold(
      // 课表页没有 AppBar，必须自己避开 Android 状态栏；否则账号摘要
      // 会从屏幕顶部开始绘制，被时间、电量和网络图标覆盖。
      body: SafeArea(
        top: !pure,
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final contentWidth = constraints.maxWidth;
            final tableContent = RepaintBoundary(
              key: _scheduleRepaintKey,
              child: ColoredBox(
                color: Theme.of(context).scaffoldBackgroundColor,
                child: _error != null
                    ? _buildErrorView(context)
                    : _courses.isEmpty
                    ? Center(
                        child: Text(
                          _loading
                              ? '正在读取本地课表…'
                              : (_emptyMessage ?? '暂无本地课表数据'),
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : _buildScheduleTable(),
              ),
            );
            if (pure) {
              return Center(
                child: SizedBox(width: contentWidth, child: tableContent),
              );
            }
            final header = compact
                ? Column(
                    children: [
                      _buildCompactScheduleStatus(context),
                      _buildWeekProgressBar(context),
                      _buildCompactScheduleTools(
                        context,
                        updateTerms: updateTerms,
                        selectedUpdateValue: selectedUpdateValue,
                      ),
                    ],
                  )
                : Column(
                    children: [
                      _buildScheduleAccountStatus(context),
                      _buildWeekProgressBar(context),
                      _buildDesktopScheduleTools(
                        context,
                        updateTerms: updateTerms,
                        selectedUpdateValue: selectedUpdateValue,
                      ),
                    ],
                  );
            return Column(
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight * 0.5,
                  ),
                  child: SingleChildScrollView(
                    child: Center(
                      child: SizedBox(width: contentWidth, child: header),
                    ),
                  ),
                ),
                if (_semesterEnded)
                  Center(
                    child: SizedBox(
                      width: contentWidth,
                      child: _buildSemesterEndedBanner(context),
                    ),
                  ),
                const Divider(),
                Expanded(
                  child: Center(
                    child: SizedBox(
                      width: contentWidth,
                      child: tableContent,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildErrorView(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colorScheme.error.withAlpha(140)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.error_outline, color: colorScheme.error),
                    const SizedBox(width: 8),
                    Text(
                      '本地课表读取失败',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.error,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: colorScheme.onErrorContainer),
                ),
                if (_debugHtmlPath != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    '已把本次响应的原始 HTML 保存到本地，便于排查：',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: colorScheme.surface,
                      border: Border.all(color: colorScheme.outlineVariant),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: SelectableText(
                      _debugHtmlPath!,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('复制路径'),
                        onPressed: () async {
                          await _copyToClipboard(_debugHtmlPath!);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('路径已复制')),
                          );
                        },
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.table_chart, size: 16),
                        label: const Text('复制课表表格'),
                        onPressed: () async {
                          final tables = extractTableBlocks(_lastRawHtml);
                          final text = tables.isEmpty
                              ? '(本页未找到任何 <table>，课表可能是 JS/AJAX 动态加载，请把"结构自检"内容发来)'
                              : tables.join('\n\n');
                          await _copyToClipboard(text);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                tables.isEmpty
                                    ? '未找到表格'
                                    : '已复制 ${tables.length} 个表格',
                              ),
                            ),
                          );
                        },
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.grid_view, size: 16),
                        label: const Text('复制 timetable 表'),
                        onPressed: () async {
                          final tt = extractTableById(
                            _lastRawHtml,
                            'timetable',
                          );
                          if (tt == null) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('未找到 #timetable')),
                            );
                            return;
                          }
                          await _copyToClipboard(tt);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已复制 #timetable')),
                          );
                        },
                      ),
                      OutlinedButton.icon(
                        icon: Icon(
                          _showHtmlPreview
                              ? Icons.expand_less
                              : Icons.expand_more,
                          size: 16,
                        ),
                        label: Text(
                          _showHtmlPreview ? '收起 HTML 预览' : '展开 HTML 预览',
                        ),
                        onPressed: () => setState(
                          () => _showHtmlPreview = !_showHtmlPreview,
                        ),
                      ),
                      OutlinedButton.icon(
                        icon: Icon(
                          _showDiagnostics
                              ? Icons.expand_less
                              : Icons.expand_more,
                          size: 16,
                        ),
                        label: Text(_showDiagnostics ? '收起结构自检' : '结构自检'),
                        onPressed: () => setState(
                          () => _showDiagnostics = !_showDiagnostics,
                        ),
                      ),
                    ],
                  ),
                  if (_showHtmlPreview) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        border: Border.all(color: colorScheme.outlineVariant),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: SelectableText(
                        _lastRawHtml.length > 4096
                            ? '${_lastRawHtml.substring(0, 4096)}\n\n… (已截断，共 ${_lastRawHtml.length} 字符)'
                            : _lastRawHtml,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                  if (_showDiagnostics) ...[
                    const SizedBox(height: 12),
                    _buildDiagnosticsView(),
                  ],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _copyToClipboard(String text) async {
    // 避免对 flutter/services 的硬依赖，调用方式与项目其它地方一致
    await Clipboard.setData(ClipboardData(text: text));
  }

  Widget _buildDiagnosticsView() {
    final diag = scheduleDiagnostics(_lastRawHtml);
    final lines = diag.entries.map((e) => '${e.key}: ${e.value}').join('\n');
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colorScheme.tertiaryContainer,
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('复制自检'),
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  await _copyToClipboard(lines);
                  if (!context.mounted) return;
                  messenger.showSnackBar(
                    const SnackBar(content: Text('自检内容已复制')),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            lines,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ],
      ),
    );
  }

  // ==================== 课表表格 ====================

  /// 把课表渲染成 8 列表格：节次(行) × 周一~周日(列)。
  /// 同一格内若有多个课程（如同一时间多门课），会纵向堆叠。
  Widget _buildScheduleTable() {
    const dayOrder = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

    // 按周筛选后的可见课程；本周视图高亮也基于同一"当前周次"。
    final list = _visibleCourses;
    if (list.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _s.filterByWeek ? '第${_s.currentWeek}周暂无课程安排' : '暂无课程数据',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 14,
            ),
          ),
        ),
      );
    }

    // 1) 按出现顺序收集去重的时间节次（解析器已按行顺序输出，保持原顺序）
    final orderedTimes = <String>[];
    final seen = <String>{};
    for (final c in list) {
      final t = c['time'] ?? '';
      if (!seen.add(t)) continue;
      orderedTimes.add(t);
    }

    // 2) 按 (time, day) 分组，方便填表
    final tableData = <String, Map<String, List<Map<String, String>>>>{};
    for (final c in list) {
      final t = c['time'] ?? '';
      final d = c['day'] ?? '';
      tableData
          .putIfAbsent(t, () => <String, List<Map<String, String>>>{})
          .putIfAbsent(d, () => <Map<String, String>>[])
          .add(c);
    }

    // 3) 表体：本周视图开启时，把"当前周次"传下去做高亮
    final highlightWeek = _s.highlightCurrentWeek ? _s.currentWeek : null;

    // 4) 渲染：宽屏宽列；窄屏缩列让周一~周五可见，周六日横向滑动
    final widthCtx = context;
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = constraints.maxWidth;
        final isNarrow = MediaQuery.sizeOf(context).shortestSide < 600;
        final pure =
            isNarrow &&
            MediaQuery.orientationOf(context) == Orientation.landscape;

        // 列宽：按实际可用宽度均分，让 7 天始终撑满（横屏也撑满，不再靠左）。
        // 手机竖屏且关闭七天时才只显示 5 天（周六日横向滑动）。
        const timeWidth = 34.0;
        final showWeekend = _s.showWeekend;
        final visibleDays = (isNarrow && !showWeekend && !pure) ? 5 : 7;
        final timeCol = isNarrow ? timeWidth : 96.0;
        final dayWidth = ((screenWidth - timeCol - 8) / visibleDays).clamp(
          isNarrow ? (visibleDays == 7 ? 40.0 : 48.0) : 70.0,
          500.0,
        );
        final tPad = isNarrow ? 4.0 : 8.0;
        final fSize = isNarrow
            ? AppDimens.scheduleHeaderNarrow
            : AppDimens.scheduleHeaderWide;
        final startDate = DateTime.tryParse(_s.semesterStartDate);
        final weekOffsetDays = (_s.currentWeek - 1) * 7;
        final numRows = orderedTimes.length + 1;
        final cellHeight = pure && numRows > 0
            ? (constraints.maxHeight - 2) / numRows
            : null;

        final tableRows = <TableRow>[];
        for (var rowIndex = 0; rowIndex < orderedTimes.length; rowIndex++) {
          final time = orderedTimes[rowIndex];
          tableRows.add(
            TableRow(
              decoration: BoxDecoration(
                color: rowIndex.isEven
                    ? Theme.of(widthCtx).colorScheme.surface
                    : Theme.of(
                        widthCtx,
                      ).colorScheme.surfaceContainerLowest.withAlpha(100),
              ),
              children: [
                _buildTimeCell(time, cellHeight, isNarrow),
                for (final d in dayOrder)
                  _buildDayCell(
                    tableData[time]?[d] ?? const [],
                    highlightWeek,
                    isNarrow,
                    cellHeight,
                  ),
              ],
            ),
          );
        }

        return SingleChildScrollView(
          scrollDirection: Axis.vertical,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Padding(
              padding: pure
                  ? EdgeInsets.zero
                  : EdgeInsets.fromLTRB(tPad, 8, tPad, 16),
              child: RepaintBoundary(
                key: _scheduleTableRepaintKey,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(widthCtx).colorScheme.surface,
                    borderRadius: pure ? null : BorderRadius.circular(16),
                    border: pure
                        ? null
                        : Border.all(
                            color: Theme.of(
                              widthCtx,
                            ).colorScheme.outlineVariant.withAlpha(180),
                          ),
                    boxShadow: pure
                        ? null
                        : [
                            BoxShadow(
                              color: Theme.of(
                                widthCtx,
                              ).colorScheme.shadow.withAlpha(18),
                              blurRadius: 16,
                              offset: const Offset(0, 4),
                            ),
                          ],
                  ),
                child: ClipRRect(
                  borderRadius: pure
                      ? BorderRadius.zero
                      : BorderRadius.circular(16),
                  child: Table(
                    defaultColumnWidth: FixedColumnWidth(dayWidth),
                    columnWidths: {0: FixedColumnWidth(timeCol)},
                    border: TableBorder(
                      horizontalInside: BorderSide(
                        color: Theme.of(
                          widthCtx,
                        ).colorScheme.outlineVariant.withAlpha(120),
                        width: 0.6,
                      ),
                      verticalInside: BorderSide(
                        color: Theme.of(
                          widthCtx,
                        ).colorScheme.outlineVariant.withAlpha(100),
                        width: 0.6,
                      ),
                    ),
                    children: [
                      TableRow(
                        decoration: BoxDecoration(
                          color: Theme.of(
                            widthCtx,
                          ).colorScheme.surfaceContainerHighest.withAlpha(180),
                        ),
                        children: [
                          _buildHeaderCell('节', fontSize: fSize, cellHeight: cellHeight),
                          for (var i = 0; i < dayOrder.length; i++)
                            _buildHeaderCell(
                              isNarrow ? dayOrder[i][1] : dayOrder[i],
                              fontSize: fSize,
                              sub: _dayDateLabel(
                                startDate,
                                weekOffsetDays + i,
                              ),
                              cellHeight: cellHeight,
                            ),
                        ],
                      ),
                      ...tableRows,
                    ],
                  ),
                ),
              ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeaderCell(
    String text, {
    double fontSize = 13,
    String? sub,
    double? cellHeight,
  }) {
    return Container(
      height: cellHeight,
      padding: EdgeInsets.symmetric(
        vertical: cellHeight == null ? 8 : 0,
        horizontal: 4,
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            text,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: fontSize,
              letterSpacing: 0.2,
            ),
          ),
          if (sub != null)
            Text(
              sub,
              style: TextStyle(
                fontSize: fontSize - 2,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  String? _dayDateLabel(DateTime? startDate, int offsetDays) {
    if (startDate == null) return null;
    final d = startDate.add(Duration(days: offsetDays));
    return d.month.toString() + '/' + d.day.toString();
  }

  Widget _buildTimeCell(String time, [double? cellHeight, bool isNarrow = false]) {
    // 例 "第一大节 (01,02小节)" / "第一节 (01,02小节)" → 主行 + 小节行
    final match = RegExp(
      r'^(第[一二三四五六七八九十]+(?:大)?节)(?:\s*[（(]([^）)]*)[）)])?',
    ).firstMatch(time);
    final main = match?.group(1) ?? time;
    final legacySub = match?.group(2) ?? '';
    final sub = ScheduleTimeTable.formatSublessonLines(
      time,
      _s.scheduleTimeMode,
      includeLabels: false,
    );
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      height: cellHeight,
      padding: EdgeInsets.symmetric(
        vertical: cellHeight == null ? 8 : 0,
        horizontal: 4,
      ),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withAlpha(150),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            main,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: isNarrow
                  ? AppDimens.timeCellMainNarrow
                  : AppDimens.timeCellMainWide,
              color: colorScheme.onSurface,
            ),
          ),
          if (cellHeight == null && (sub.isNotEmpty || legacySub.isNotEmpty)) ...[
            const SizedBox(height: 2),
            Text(
              sub.isNotEmpty ? sub : legacySub,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: isNarrow
                    ? AppDimens.timeCellSubNarrow
                    : AppDimens.timeCellSubWide,
                height: 1.25,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDayCell(
    List<Map<String, String>> courses, [
    int? highlightWeek,
    bool isNarrow = false,
    double? cellHeight,
  ]) {
    if (courses.isEmpty) {
      return Container(
        height: cellHeight ?? AppDimens.scheduleCellMinHeight,
        alignment: Alignment.center,
        child: Text(
          '-',
          style: TextStyle(
            color: Theme.of(context).colorScheme.outline,
            fontSize: 15,
          ),
        ),
      );
    }

    // 本周视图高亮：当周落在任意课程周次区间内，则该格高亮（淡黄底色）。
    // 用 parseWeekSpans 覆盖所有逗号分段，避免"1-4,9-12(周)"在第11周不亮。
    // 本周视图高亮：当周落在任意课程周次区间内，则该格高亮（淡黄底色）。
    // 用 parseWeekSpans 覆盖所有逗号分段，避免"1-4,9-12(周)"在第11周不亮。
    final w = highlightWeek;
    final bool inCurrentWeek =
        w != null &&
        courses.any((c) {
          return parseWeekSpans(
            c['weeks'] ?? '',
          ).any((s) => s['start']! <= w && w <= s['end']!);
        });

    // 按"周次是否重叠"把同格课程分组：
    //  - 周次重叠的多门课 → 归为一个"冲突簇"，渲染成可点击的冲突块；
    //  - 周次不重叠（如 1-10 周与 11-12 周）→ 各自单独正常显示。
    final spans = courses.map((c) => parseWeekSpans(c['weeks'] ?? '')).toList();
    final n = courses.length;
    final parent = List.generate(n, (i) => i);
    int find(int x) => parent[x] == x ? x : parent[x] = find(parent[x]);
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        if (spans[i].isEmpty || spans[j].isEmpty) continue;
        if (weekSpansOverlap(spans[i], spans[j])) {
          parent[find(i)] = find(j);
        }
      }
    }
    final clusters = <int, List<int>>{};
    for (var i = 0; i < n; i++) {
      clusters.putIfAbsent(find(i), () => <int>[]).add(i);
    }

    final children = <Widget>[];
    var first = true;
    for (final idxs in clusters.values) {
      if (!first) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Divider(
              height: 1,
              thickness: 0.5,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        );
      }
      first = false;

      if (idxs.length == 1) {
        children.add(_buildCourseEntry(courses[idxs.first], isNarrow));
      } else {
        children.add(
          _buildConflictCell(idxs.map((i) => courses[i]).toList()),
        );
      }
    }

    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.all(cellHeight == null ? 6 : 2),
      height: cellHeight,
      constraints: cellHeight == null
          ? BoxConstraints(minHeight: AppDimens.scheduleCellMinHeight)
          : null,
      decoration: inCurrentWeek
          ? BoxDecoration(
              color: colorScheme.primaryContainer.withAlpha(120),
              border: Border(
                left: BorderSide(color: colorScheme.primary, width: 3),
              ),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }

  /// 同一节次、周次重叠的多门课——冲突块，点击可查看详情。
  Widget _buildConflictCell(List<Map<String, String>> courses) {
    final names = courses.map((c) {
      final n = (c['name'] ?? '').trim();
      return n.isNotEmpty ? n : '(未知课程)';
    }).toList();
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: () => _showConflictDialog(courses),
        child: Container(
          padding: const EdgeInsets.fromLTRB(7, 7, 6, 7),
          decoration: BoxDecoration(
            color: colorScheme.errorContainer.withAlpha(72),
            borderRadius: BorderRadius.circular(9),
            border: Border(
              left: BorderSide(color: colorScheme.error, width: 3),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final n in names)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '· $n',
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _chooseScheduleExport() async {
    if (_lastRawHtml.isEmpty || !mounted) return;
    final format = await showDialog<_ScheduleExportFormat>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择课表导出格式'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, _ScheduleExportFormat.jpg),
            child: const ListTile(
              leading: Icon(Icons.photo, color: Colors.deepOrange),
              title: Text('JPG（默认）'),
              subtitle: Text('适合手机相册与分享，按当前窗口尺寸导出'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, _ScheduleExportFormat.png),
            child: const ListTile(
              leading: Icon(Icons.image),
              title: Text('PNG'),
              subtitle: Text('无损图片，保留当前窗口尺寸'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, _ScheduleExportFormat.html),
            child: const ListTile(
              leading: Icon(Icons.code),
              title: Text('HTML'),
              subtitle: Text('导出教务系统返回的原始课表页面'),
            ),
          ),
        ],
      ),
    );
    if (format == null || !mounted) return;
    await _exportSchedule(format);
  }

  Future<Directory> _scheduleExportDirectory() async {
    if (Platform.isWindows) {
      final current = Directory.current.path;
      final sep = Platform.pathSeparator;
      final dir = Directory('$current$sep' + 'screen');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }
    return getApplicationDocumentsDirectory();
  }

  String _scheduleFileStamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final y = now.year;
    final mo = two(now.month);
    final d = two(now.day);
    final h = two(now.hour);
    final mi = two(now.minute);
    final s = two(now.second);
    return '$y$mo$d' + '_' + '$h$mi$s';
  }

  /// 导出课表：Windows 存到 exe 同级 screen/ 目录；Android 存到系统相册；
  /// 文件名按截图时间精确到秒。
  Future<void> _exportSchedule(_ScheduleExportFormat format) async {
    if (_lastRawHtml.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final stamp = _scheduleFileStamp();
      final term = _selectedTerm;
      final baseName = 'jizhicha_schedule_' + term + '_' + stamp;
      final extension = switch (format) {
        _ScheduleExportFormat.jpg => 'jpg',
        _ScheduleExportFormat.png => 'png',
        _ScheduleExportFormat.html => 'html',
      };
      final fileName = baseName + '.' + extension;

      if (format == _ScheduleExportFormat.html) {
        final dir = await _scheduleExportDirectory();
        final file = File(dir.path + Platform.pathSeparator + fileName);
        await file.writeAsString(_lastRawHtml, flush: true);
        messenger.showSnackBar(SnackBar(content: Text('已导出：' + file.path)));
        return;
      }

      if (_courses.isEmpty) throw '当前学期没有可导出的课程';
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final renderObject = _scheduleTableRepaintKey.currentContext
          ?.findRenderObject();
      if (renderObject is! RenderRepaintBoundary) {
        throw '课表尚未完成渲染，请稍后再试';
      }
      final media = MediaQuery.of(context);
      final ratio = media.devicePixelRatio.clamp(1.0, 3.0).toDouble();
      final image = await renderObject.toImage(pixelRatio: ratio);
      try {
        final byteData = await image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (byteData == null) throw '无法生成课表图片';
        final pngBytes = byteData.buffer.asUint8List();
        final bytes = format == _ScheduleExportFormat.png
            ? pngBytes
            : img.encodeJpg(img.decodePng(pngBytes)!, quality: 92);

        if (Platform.isAndroid) {
          final tmpDir = await getTemporaryDirectory();
          final tmp = File(tmpDir.path + Platform.pathSeparator + fileName);
          await tmp.writeAsBytes(bytes, flush: true);
          await Gal.putImage(tmp.path, album: '稽之查');
          messenger.showSnackBar(
            const SnackBar(content: Text('已保存到手机相册')),
          );
        } else {
          final dir = await _scheduleExportDirectory();
          final file = File(dir.path + Platform.pathSeparator + fileName);
          await file.writeAsBytes(bytes, flush: true);
          messenger.showSnackBar(SnackBar(content: Text('已导出：' + file.path)));
        }
      } finally {
        image.dispose();
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导出失败：$e')));
    }
  }

  /// 冲突弹窗：逐条列出每门课的完整安排，由用户自行判断去上哪门。
  void _showConflictDialog(List<Map<String, String>> courses) {
    showDialog(
      context: context,
      builder: (ctx) {
        final colorScheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                color: colorScheme.error,
                size: 20,
              ),
              const SizedBox(width: 8),
              const Text('课程冲突', style: TextStyle(fontSize: 16)),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: courses.length,
              itemBuilder: (ctx2, i) {
                final c = courses[i];
                final name = (c['name'] ?? '').trim();
                final teacher = (c['teacher'] ?? '').trim();
                final room = (c['room'] ?? '').trim();
                final weeks = (c['weeks'] ?? '').trim();
                return Padding(
                  padding: EdgeInsets.only(
                    bottom: i < courses.length - 1 ? 12 : 0,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${i + 1}. ${name.isNotEmpty ? name : '(未知课程)'}',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '时间：${c['day'] ?? ''} ${c['time'] ?? ''}',
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (teacher.isNotEmpty)
                        Text(
                          '教师：$teacher',
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      if (room.isNotEmpty)
                        Text(
                          '地点：$room',
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      if (weeks.isNotEmpty)
                        Text(
                          '周次：$weeks',
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      if (i < courses.length - 1)
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: Divider(),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('知道了'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCourseEntry(Map<String, String> c, [bool isNarrow = false]) {
    final name = (c['name'] ?? '').trim();
    final teacher = (c['teacher'] ?? '').trim();
    final room = (c['room'] ?? '').trim();
    final pure =
        MediaQuery.sizeOf(context).shortestSide < 600 &&
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final colorScheme = Theme.of(context).colorScheme;
    final textDelta = (_s.scheduleTextSize - 1).toDouble();
    final nameSize = (isNarrow
            ? AppDimens.courseNameNarrow
            : AppDimens.courseNameWide) +
        textDelta;
    final subSize = (isNarrow
            ? AppDimens.courseSubNarrow
            : AppDimens.courseSubWide) +
        textDelta;
    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      padding: EdgeInsets.fromLTRB(7, pure ? 3 : 6, 6, pure ? 3 : 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withAlpha(112),
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(color: colorScheme.primary.withAlpha(170), width: 2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            name.isNotEmpty ? name : '(未知课程)',
            softWrap: !pure,
            maxLines: pure ? 1 : null,
            overflow: pure ? TextOverflow.ellipsis : null,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: nameSize,
              height: 1.25,
              color: name.isNotEmpty
                  ? colorScheme.onSurface
                  : colorScheme.onSurfaceVariant,
            ),
          ),
          if (teacher.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: pure ? 1 : 2),
              child: Text(
                '@$teacher',
                softWrap: !pure,
                maxLines: pure ? 1 : null,
                overflow: pure ? TextOverflow.ellipsis : null,
                style: TextStyle(
                  fontSize: subSize,
                  height: 1.2,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (room.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: pure ? 1 : 2),
              child: Text(
                '$room',
                softWrap: !pure,
                maxLines: pure ? 1 : null,
                overflow: pure ? TextOverflow.ellipsis : null,
                style: TextStyle(
                  fontSize: subSize,
                  height: 1.2,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
