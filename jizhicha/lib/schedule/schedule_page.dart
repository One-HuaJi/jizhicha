// 课表页库根：State 骨架、生命周期、页面 build；其余成员按职责拆到同级 part 文件。
import 'dart:io' show Directory, File, Platform;
import 'dart:isolate' show Isolate;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../academic_calendar.dart';
import '../app_mode.dart';
import '../app_settings.dart';
import '../auth_pages.dart';
import '../campus_environment.dart';
import '../campus_sync_helpers.dart';
import '../common.dart';
// 教务自动重新认证：part 文件（schedule_tools.dart）不能有自己的 import，
// 必须由库根引入，part 才能看到这几个名字。
import '../education_auto_login.dart';
import '../jwxt_client.dart';
import '../offline_sync.dart';
import '../schedule_cache_store.dart';
import '../schedule_time.dart';
import '../sync_cooldown.dart';
import '../ui_constants.dart';
import '../widget_schedule_store.dart';
import '../zongce_share.dart';
import 'schedule_background_layer.dart';
import 'schedule_cell_layout.dart';
import 'schedule_course_block.dart';
import 'schedule_fit_layout.dart';
import 'schedule_ics.dart';
import 'schedule_peak_style.dart';

part 'schedule_data.dart';
part 'schedule_diagnostics.dart';
part 'schedule_export.dart';
part 'schedule_state.dart';
part 'schedule_status.dart';
part 'schedule_table.dart';
part 'schedule_tools.dart';

// ==================== 课表页（带学期选择） ====================
class SchedulePage extends StatefulWidget {
  final String studentId;

  const SchedulePage({required this.studentId, super.key});

  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage>
    with
        CampusSyncHelpers<SchedulePage>,
        _SchedulePageShared,
        _SchedulePageDataSection,
        _ScheduleExportSection,
        _ScheduleStatusSection,
        _ScheduleToolsSection,
        _ScheduleTableSection,
        _ScheduleDiagnosticsSection {
  /// [CampusSyncHelpers] 需要知道当前页面对应的学号。
  @override
  String get campusStudentId => widget.studentId;

  @override
  void initState() {
    super.initState();
    appSettingsRevision.addListener(_reloadSettings);
    campusEnvironment.addListener(_refreshCampusEnvironment);
    // 冷却倒计时不再由整页监听：只有「更新按钮 + 冷却指示器」那一小块重建，
    // 见 SyncCooldownIndicator 与下面包住按钮的 ListenableBuilder。
    _initialize();
  }

  @override
  void dispose() {
    appSettingsRevision.removeListener(_reloadSettings);
    campusEnvironment.removeListener(_refreshCampusEnvironment);
    super.dispose();
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
            // 背景图（设置项 scheduleBackgroundPath）铺在**所有 RepaintBoundary
            // 之外**：导出截图取的是 `_scheduleTableRepaintKey`（表格卡片自身，
            // 见 schedule_export.dart），而这一层在它之外的更外层，
            // 因此导出的图片里永远没有背景图（作者明确要求）。
            // 细节见 schedule_background_layer.dart。
            final tableContent = ScheduleBackgroundLayer(
              path: _s.scheduleBackgroundPath,
              child: RepaintBoundary(
                key: _scheduleRepaintKey,
                child: ColoredBox(
                  // 刻意透明：底板（背景图 + 可读性遮罩，或"没设背景"时的
                  // 主题底色）由 ScheduleBackgroundLayer 负责画，
                  // 这一层只承载内容，避免把照片盖掉。
                  color: Colors.transparent,
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
                      : MediaQuery.withClampedTextScaling(
                          // 课表是密集网格：系统"最大字体"会把课表内 10px 的基础
                          // 字号放大到挤成竖排单字。这里只限制课表区域的放大上限，
                          // 其它页面仍完全跟随系统字号。
                          maxScaleFactor: 1.3,
                          child: _buildScheduleTable(),
                        ),
                ),
              ),
            );
            if (pure) {
              return Center(
                child: SizedBox(width: contentWidth, child: tableContent),
              );
            }
            final header = _buildScheduleHeader(
              context,
              compact: compact,
              updateTerms: updateTerms,
              selectedUpdateValue: selectedUpdateValue,
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

  /// 顶部三行（账号状态 / 周次进度条 / 工具行）的**可折叠**外壳。
  ///
  /// 作者口径（「一屏显示」配套）：这三行可以折叠，把高度让给课表。
  /// 折叠后留一行摘要（当前周次 + 学期）加一个展开按钮——不是全隐藏，
  /// 否则用户不知道现在看的是第几周、也不知道去哪展开。
  /// 状态刻意**不持久化**：它是"临时看一眼整表"的开关，重启回到展开态，
  /// 没有进 AppSettings（也就没有多出一个需要迁移的字段）。
  Widget _buildScheduleHeader(
    BuildContext context, {
    required bool compact,
    required List<String> updateTerms,
    required String selectedUpdateValue,
  }) {
    final collapsed = _headerCollapsed;
    final rows = compact
        ? <Widget>[
            _buildCompactScheduleStatus(context),
            _buildWeekProgressBar(context),
            _buildCompactScheduleTools(
              context,
              updateTerms: updateTerms,
              selectedUpdateValue: selectedUpdateValue,
            ),
          ]
        : <Widget>[
            _buildScheduleAccountStatus(context),
            _buildWeekProgressBar(context),
            _buildDesktopScheduleTools(
              context,
              updateTerms: updateTerms,
              selectedUpdateValue: selectedUpdateValue,
            ),
          ];
    return Column(
      children: [
        Row(
          children: [
            if (collapsed)
              Expanded(child: _buildScheduleHeaderSummary(context))
            else
              const Spacer(),
            _buildScheduleHeaderToggle(context),
          ],
        ),
        if (!collapsed) ...rows,
      ],
    );
  }

  /// 折叠态下的摘要行：当前周次 + 学期。
  Widget _buildScheduleHeaderSummary(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Text(
        '第${_s.currentWeek}周 · $_selectedTerm',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
    );
  }

  /// 折叠 / 展开的小按钮（图标 + 文案，命中区 32px 高）。
  Widget _buildScheduleHeaderToggle(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final collapsed = _headerCollapsed;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => setState(() => _headerCollapsed = !collapsed),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              collapsed ? '展开' : '收起',
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
            ),
            Icon(
              collapsed ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

}

