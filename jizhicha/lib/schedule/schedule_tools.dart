// 课表页职责：学期/周次/更新范围等课表操作区与手动保存课表入口。
part of 'schedule_page.dart';

mixin _ScheduleToolsSection on _SchedulePageDataSection, _ScheduleExportSection {
  /// 自动认证教务系统是否正在进行。
  ///
  /// `_loading` 要等认证成功之后才置位，所以自动认证这段时间必须另有一个标记
  /// 来挡连点：否则两次并发登录会连着打学校网关，有风控风险。
  bool _educationAutoLoginBusy = false;

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


  Future<void> _openManualScheduleSave() async {
    final remaining = dataSyncCooldown.remaining(SyncResource.schedule);
    if (remaining > Duration.zero) {
      showSyncCooldownMessage(SyncResource.schedule);
      return;
    }
    final selected = _selectedScheduleUpdateTerm;
    final fetchAll = selected == _allScheduleTermsValue;
    final term = fetchAll ? null : selected;
    final scopeNotice = fetchAll
        ? '本次更新所有已知学期课表'
        : term == null
        ? '本次仅手动保存最新一期已发布课表'
        : '本次仅更新 $term 课表';

    // 需求 3：刷新课表时才认证教务系统，而且先试一次**静默的自动认证**
    // （本机保存的凭据 + 本机 OCR 识别验证码）。成功就继续原来的同步流程，
    // 用户完全无感；只有确实做不到时才跳手动认证页，并把原因带过去。
    if (_educationAutoLoginBusy) return;
    _educationAutoLoginBusy = true;
    var sessionReady = false;
    String? autoLoginNotice;
    try {
      sessionReady = await canReuseEducationSession();
      if (!sessionReady) {
        final result = await tryAutoEducationLogin(studentId: widget.studentId);
        switch (result) {
          case AutoLoginSuccess():
            sessionReady = true;
          case AutoLoginFailure(:final message):
            autoLoginNotice = message;
        }
      }
    } finally {
      _educationAutoLoginBusy = false;
    }

    if (sessionReady) {
      // 自动认证比原来多花几秒，用户可能已经离开这一页；离开后不能 setState。
      if (!mounted) return;
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
        builder: (_) => VpnSetupPage(
          mode: AppMode.education,
          forceScheduleSync: true,
          fetchAllSchedules: fetchAll,
          scheduleTerm: term,
          syncGrades: false,
          // 自动认证的失败原因放在最前面：用户最需要知道"为什么还要手动登录"。
          initialNotice: autoLoginNotice == null
              ? scopeNotice
              : '$autoLoginNotice；$scopeNotice',
        ),
      ),
    );
    if (mounted) {
      await _initialize();
      await _detectCampusEnvironment();
    }
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
                  // 冷却状态只影响这个按钮的可用性，用 ListenableBuilder 局部重建，
                  // 避免冷却倒计时每秒 setState 触发整页（含课表派生计算）重建。
                  ListenableBuilder(
                    listenable: dataSyncCooldown,
                    builder: (context, _) => OutlinedButton.icon(
                      onPressed:
                          _loading ||
                              dataSyncCooldown.isCooling(SyncResource.schedule)
                          ? null
                          : _openManualScheduleSave,
                      icon: const Icon(Icons.sync, size: 16),
                      label: Text(compact ? '更新' : '更新课表'),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        minimumSize: const Size(
                          0,
                          AppDimens.toolsButtonMinHeight,
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
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
                // 同上：冷却倒计时只重建这个按钮。
                ListenableBuilder(
                  listenable: dataSyncCooldown,
                  builder: (context, _) => FilledButton.icon(
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
                  // AnimatedSwitcher 的 key 含剩余秒数：包在 ListenableBuilder 里，
                  // 让每秒变化的 key 只驱动这一小段动画，而不是整页重建。
                  ListenableBuilder(
                    listenable: dataSyncCooldown,
                    builder: (context, _) => AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: SyncCooldownIndicator(
                        key: ValueKey(
                          dataSyncCooldown.remainingText(SyncResource.schedule),
                        ),
                        resource: SyncResource.schedule,
                      ),
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
}
