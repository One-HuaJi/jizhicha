// 课表页职责：本地课表与学期数据的加载、缓存读取与周日自动跳周。
part of 'schedule_page.dart';

mixin _SchedulePageDataSection on _SchedulePageShared {
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
      // 顺手刷新桌面小组件要读的 JSON（失败静默）。
      WidgetScheduleStore.writeCurrentSchedule(widget.studentId);
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
      _emptyMessage = '暂无本地课表，请连接校园网并认证后保存';
    });
  }

  String _emptyMessageFor(String term) {
    return term == AcademicCalendar.latestTerm &&
            AcademicCalendar.isBeforeLatestTermQueryDate(DateTime.now())
        // 旧版「可能是未开放查询」语气不定，且没给下一步。
        ? '本学期课表还没开放查询，等学校发布后再试'
        : '暂无课程安排';
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
          _emptyMessage = '该学期暂无本地课表，请重新连接校园网并认证后保存';
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
        _error = '本地课表文件无法读取，请重新连接校园网并认证后保存';
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

}
