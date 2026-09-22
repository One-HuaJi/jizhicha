// 课表页职责：顶部账号/校园加速器状态栏、周次进度条与周次选择入口。
part of 'schedule_page.dart';

mixin _ScheduleStatusSection on _SchedulePageDataSection {
  Future<void> _handleCampusAcceleratorAction() =>
      handleCampusAcceleratorAction(context, openVpnSetup: _openVpnSetup);

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
              // 补上"去哪里改"：设置页里那个字段就叫「开学日期」。
              '预设学期已结束。若本学期还没结束，请到设置里更新「开学日期」',
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

  String _scheduleAccountSummary() {
    if (_loadedFromCache) {
      return '账号 ${widget.studentId} · 本地课表'
          '${_cachedAt == null ? '' : ' · ${formatCachedAt(_cachedAt!)}'}';
    }
    return '账号 ${widget.studentId} 暂无本地课表';
  }

  String _campusModeSummary() => campusEnvironment.statusSummary;

  Widget _buildScheduleAcceleratorAction(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // ⚠️ 展示层"已连接"判据：online（最强）**或**仅 acceleratorUp（隧道已建立、
    // 校园网还在确认）。它与 `_handleCampusAcceleratorAction` 里的门禁**用的是
    // 同一套**判据（那边是 `online != true && acceleratorUp != true` 才去认证页），
    // 所以不会出现「按钮写着登出、点下去却跳认证页」。
    final online = campusEnvironment.online == true;
    final connected = online || campusEnvironment.acceleratorUp;
    final busy =
        campusEnvironment.actionLoading || campusEnvironment.reconnecting;
    return OutlinedButton.icon(
      onPressed: busy ? null : _handleCampusAcceleratorAction,
      icon: busy
          ? const SizedBox.square(
              dimension: 15,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(connected ? Icons.logout : Icons.vpn_lock, size: 16),
      label: Text(
        campusEnvironment.reconnecting
            ? '重连中'
            : campusEnvironment.actionLoading
            ? '处理中…'
            : connected
            ? '登出校园加速器'
            : '连接校园网',
      ),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        // 语义色沿用原设计：完全可用=tertiary(绿)，其余(已连接待确认/断开)=primary(琥珀)。
        foregroundColor: online ? colorScheme.tertiary : colorScheme.primary,
      ),
    );
  }

  Widget _buildScheduleAccountStatus(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final online = campusEnvironment.online == true;
    // 展示层三态（与 statusShort 的四分支文案对齐）：
    //   绿 tertiary  = online，完全可用（最强）；
    //   琥珀 primary = 仅 acceleratorUp，已连接但校园网仍在确认；
    //   灰 onSurfaceVariant = 无隧道，真离线。
    // 三者都只影响图标/颜色，不参与任何"能不能发请求"的门禁判断。
    final connected = online || campusEnvironment.acceleratorUp;
    final statusColor = online
        ? colorScheme.tertiary
        : connected
        ? colorScheme.primary
        : colorScheme.onSurfaceVariant;
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
                                // 只要"已连接"就显示 wifi，绝不与
                                // "加速器已连接" 的文案自相矛盾。
                                connected ? Icons.wifi : Icons.cloud_off,
                                size: 17,
                                color: statusColor,
                              ),
                        const SizedBox(width: 6),
                        Text(
                          campusEnvironment.statusShort,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: statusColor,
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
    // 与 _buildScheduleAccountStatus 同一套展示层三态（见那里的注释）。
    final connected = online || campusEnvironment.acceleratorUp;
    final statusColor = online
        ? colorScheme.tertiary
        : connected
        ? colorScheme.primary
        : colorScheme.onSurfaceVariant;
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
                          color: connected
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
                : connected
                ? '登出校园加速器'
                : '连接校园网',
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
                    connected ? Icons.logout : Icons.vpn_lock,
                    size: 20,
                    // IconButton 默认色是 onSurfaceVariant（灰），会在
                    // "加速器已连接" 时读成断开，所以"已连接"时显式给语义色。
                    // 断开时保持 null（默认灰），外观与改动前完全一致，
                    // 于是与左侧检测图标的三态配色整齐对齐。
                    color: connected
                        ? (online ? colorScheme.tertiary : colorScheme.primary)
                        : null,
                  ),
          ),
          IconButton(
            tooltip: '重新检测校园网',
            onPressed: campusEnvironment.checking
                ? null
                : _detectCampusEnvironment,
            icon: campusEnvironment.checking
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    connected ? Icons.wifi : Icons.cloud_off,
                    size: 20,
                    color: statusColor,
                  ),
          ),
        ],
      ),
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

}
