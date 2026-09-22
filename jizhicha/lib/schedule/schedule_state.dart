// 课表页职责：页面共享状态（常量/字段/设置/派生布局缓存）与校园加速器对接。
part of 'schedule_page.dart';

const _latestScheduleTermsValue = '__latest_schedule_term__';
const _allScheduleTermsValue = '__all_schedule_terms__';

mixin _SchedulePageShared on State<SchedulePage>, CampusSyncHelpers<SchedulePage> {
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
  void _refreshCampusEnvironment() {
    if (mounted) setState(() {});
    if (mounted && campusEnvironment.consumeDropDetected()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('校园加速器已断开，请重新连接')),
      );
    }
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
        builder: (_) => VpnSetupPage(mode: AppMode.education),
      ),
    );
    if (mounted) await _detectCampusEnvironment();
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

  /// 应用"按周筛选"：开启时只保留当前周次有课的课程。
  List<Map<String, String>> get _visibleCourses {
    if (!_s.filterByWeek) return _courses;
    final w = _s.currentWeek;
    return _courses.where((c) => weekInWeeks(c['weeks'] ?? '', w)).toList();
  }

  // ==================== 课表派生布局缓存 ====================
  // 这几项是 _buildScheduleTable 的派生数据：按周筛选 → 节次去重排序 →
  // 每门课 parseWeekSpans（旧实现同一门课解析两次）→ 并查集冲突聚类 →
  // 本周视图高亮。旧实现每次 build 全部重跑，大课表上一次要几十毫秒。
  //
  // 缓存失效条件（只有下面 4 项变化才重算，其余 setState 如冷却倒计时、
  // 折叠开关、错误提示都直接复用缓存）：
  //   1) _courses 整体被替换（换学期 / 重新同步 / 读到本地缓存）；
  //   2) filterByWeek —— 按周筛选开关，决定要不要过滤课程；
  //   3) currentWeek —— 当前周次，筛选与高亮都按它算；
  //   4) highlightCurrentWeek —— 本周视图高亮开关，决定是否用 3)。
  // 高亮粒度从"整格"下沉到"每个课块（簇）"之后，这一组条件**依然完备**：
  // 簇级高亮只由 parseWeekSpans(course['weeks'])（随 _courses 一起换）与
  // highlightWeek（= highlightCurrentWeek ? currentWeek : null，由 3)、4) 决定）
  // 算出，没有引入第五个输入 —— 它刻意不读 scheduleTextSize / showWeekend /
  // scheduleTimeMode 这类只影响渲染、不影响派生数据的设置，那些不需要进缓存键。
  // 反过来说：如果将来有人让"某个簇是否高亮"依赖了 1)~4) 之外的任何状态，
  // 必须同时在这里加一个同名的可空键，否则会出现"改了设置但课表不刷新"。
  // 刻意用「可空字段 + 显式比较」而不是 late final：late final 只会算一次、
  // 之后永不刷新，换学期后会显示旧课表。
  List<Map<String, String>>? _layoutCourses;
  bool? _layoutFilterByWeek;
  int? _layoutWeek;
  bool? _layoutHighlightCurrentWeek;
  _ScheduleTableLayout _layout = _ScheduleTableLayout.empty;

  _ScheduleTableLayout _scheduleLayout() {
    final settings = _s;
    if (identical(_layoutCourses, _courses) &&
        _layoutFilterByWeek == settings.filterByWeek &&
        _layoutWeek == settings.currentWeek &&
        _layoutHighlightCurrentWeek == settings.highlightCurrentWeek) {
      return _layout;
    }

    // 按周筛选后的可见课程；本周视图高亮也基于同一"当前周次"。
    final list = _visibleCourses;

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

    // 3) 每个单元格一次性算好冲突簇，以及**每个簇各自**的本周高亮，
    //    渲染时只做查表。highlightWeek 为空表示"不开本周高亮"，此时所有簇
    //    一律不亮（等价于旧的整格标志为 false）。
    final highlightWeek = settings.highlightCurrentWeek
        ? settings.currentWeek
        : null;
    final cells = <String, Map<String, _ScheduleCellData>>{};
    tableData.forEach((time, byDay) {
      final row = <String, _ScheduleCellData>{};
      byDay.forEach((day, courses) {
        row[day] = _ScheduleCellData.compute(courses, highlightWeek);
      });
      cells[time] = row;
    });

    _layoutCourses = _courses;
    _layoutFilterByWeek = settings.filterByWeek;
    _layoutWeek = settings.currentWeek;
    _layoutHighlightCurrentWeek = settings.highlightCurrentWeek;
    _layout = _ScheduleTableLayout(orderedTimes: orderedTimes, cells: cells);
    return _layout;
  }

}
