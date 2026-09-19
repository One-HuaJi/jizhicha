import 'academic_calendar.dart';
import 'jwxt_client.dart';
import 'schedule_cache_store.dart';
import 'sync_cooldown.dart';
import 'widget_schedule_store.dart';

class OfflineSyncResult {
  final int savedTermCount;
  final int gradeCount;
  final List<String> failedTerms;
  final List<String> failedGradeTerms;
  final bool gradesUpdated;
  final bool schedulesUpdated;
  final bool schedulesSkipped;
  final bool schedulesFetchedAll;
  final bool gradesFetchedAll;

  const OfflineSyncResult({
    required this.savedTermCount,
    required this.gradeCount,
    required this.failedTerms,
    required this.failedGradeTerms,
    required this.gradesUpdated,
    required this.schedulesUpdated,
    required this.schedulesSkipped,
    this.schedulesFetchedAll = false,
    this.gradesFetchedAll = false,
  });
}

/// 教务认证成功后同步离线数据。
///
/// 首次认证会把所有配置学期中能成功返回的课表和成绩都写入本地；
/// 已有本地快照后，普通登录只更新最新成绩，手动更新则可指定一个学期，
/// 或通过 [GradeSyncScope.all] 查询全部成绩。课表首次全量抓取后不再删除
/// 其它学期文件，指定学期更新也只替换对应缓存。
/// 主页只读取这里写下来的本地静态文件，不会因为切换课表或成绩页面再次
/// 访问校园网。
Future<OfflineSyncResult> syncOfflineUserData({
  required String studentId,
  void Function(String message)? onProgress,
  GradeSyncScope gradeSyncScope = GradeSyncScope.latest,
  bool syncSchedules = true,
  bool forceScheduleSync = false,
  bool fetchAllSchedules = false,
  String? scheduleTerm,
  String? gradeTerm,
  bool syncGrades = true,
}) async {
  final client = JwxtClient();
  final htmlByTerm = <String, String>{};
  final failedTerms = <String>[];
  final terms = AcademicCalendar.terms;
  final hadScheduleBefore = await _hasLocalSchedule(studentId);
  final hadGradesBefore = await _hasLocalGrades(studentId);
  final normalizedScheduleTerm = scheduleTerm?.trim();
  final normalizedGradeTerm = gradeTerm?.trim();
  final shouldSyncSchedules =
      syncSchedules &&
      (forceScheduleSync ||
          fetchAllSchedules ||
          normalizedScheduleTerm?.isNotEmpty == true ||
          !hadScheduleBefore);
  final schedulesFetchedAll =
      shouldSyncSchedules &&
      (fetchAllSchedules ||
          (!hadScheduleBefore && normalizedScheduleTerm?.isNotEmpty != true));
  final scheduleQueryTerms = normalizedScheduleTerm?.isNotEmpty == true
      ? <String>[normalizedScheduleTerm!]
      : terms;
  final gradeQueryTerms = normalizedGradeTerm?.isNotEmpty == true
      ? <String>[normalizedGradeTerm!]
      : (gradeSyncScope == GradeSyncScope.all || !hadGradesBefore)
      ? terms
      : <String>[AcademicCalendar.latestAvailableTerm];
  final gradesFetchedAll =
      syncGrades &&
      normalizedGradeTerm?.isNotEmpty != true &&
      (gradeSyncScope == GradeSyncScope.all || !hadGradesBefore);

  final resourcesToSync = <SyncResource>[
    if (shouldSyncSchedules) SyncResource.schedule,
    if (syncGrades) SyncResource.grade,
  ];
  if (!dataSyncCooldown.tryStartAll(resourcesToSync)) {
    final blocked = resourcesToSync.firstWhere(
      dataSyncCooldown.isCooling,
      orElse: () => SyncResource.schedule,
    );
    final label = blocked == SyncResource.schedule ? '课表' : '成绩';
    throw '$label更新冷却中，还需 ${dataSyncCooldown.remainingText(blocked)} 后重试';
  }

  if (shouldSyncSchedules) {
    // 首次认证查询所有配置学期；普通/手动“最新”更新按新旧顺序回退，
    // 新学期未发布时继续尝试第二新的已发布课表；指定学期只查那一学期。
    for (var index = 0; index < scheduleQueryTerms.length; index++) {
      final term = scheduleQueryTerms[index];
      onProgress?.call(
        schedulesFetchedAll
            ? '正在获取课表 ${index + 1}/${scheduleQueryTerms.length}：$term'
            : '正在查找最新课表：$term',
      );
      try {
        final html = await client
            .fetchScheduleHtml(term)
            .timeout(const Duration(seconds: 30));
        if (html.trim().isEmpty) throw '课表响应为空';
        if (parseScheduleHtml(html).isEmpty) {
          // 空表通常表示该学期尚未发布；继续尝试第二新学期。
          continue;
        }
        htmlByTerm[term] = html;
        if (!schedulesFetchedAll) break;
      } catch (_) {
        failedTerms.add(term);
      }
    }
  }

  GradeFetchResult gradeResult;
  if (syncGrades) {
    final gradeTerms = gradeQueryTerms;
    onProgress?.call(
      gradesFetchedAll
          ? '正在更新全部学期成绩…'
          : normalizedGradeTerm?.isNotEmpty == true
          ? '正在更新成绩：$normalizedGradeTerm…'
          : '正在更新最新学期成绩…',
    );
    try {
      gradeResult = await client
          .getAllGrades(terms: gradeTerms)
          .timeout(const Duration(minutes: 2));
    } catch (_) {
      gradeResult = GradeFetchResult(
        grades: const [],
        failedTerms: List<String>.from(gradeTerms),
      );
    }
  } else {
    gradeResult = const GradeFetchResult(
      grades: [],
      failedTerms: [],
      successfulTerms: [],
    );
  }
  if (htmlByTerm.isEmpty &&
      gradeResult.successfulTerms.isEmpty &&
      !hadScheduleBefore &&
      !hadGradesBefore) {
    throw '教务认证成功，但未能获取可保存的课表或成绩，请稍后重新连接更新';
  }

  if (htmlByTerm.isNotEmpty || gradeResult.successfulTerms.isNotEmpty) {
    onProgress?.call('正在写入本地离线主页…');
  }
  await UserDataCacheStore.saveSnapshot(
    studentId: studentId,
    scheduleHtmlByTerm: htmlByTerm,
    grades: gradeResult.grades,
    replaceGrades: syncGrades && gradesFetchedAll && gradeResult.isComplete,
    replaceGradeTerms: gradeResult.successfulTerms,
    replaceSchedules: false,
  );
  // 同步完课表后，顺手刷新桌面小组件要读的 JSON（失败静默）。
  await WidgetScheduleStore.writeCurrentSchedule(studentId);
  return OfflineSyncResult(
    savedTermCount: htmlByTerm.length,
    gradeCount: gradeResult.grades.length,
    failedTerms: failedTerms,
    failedGradeTerms: gradeResult.failedTerms,
    gradesUpdated: syncGrades && gradeResult.isComplete,
    schedulesUpdated: htmlByTerm.isNotEmpty,
    schedulesSkipped: syncSchedules && !shouldSyncSchedules,
    schedulesFetchedAll: schedulesFetchedAll,
    gradesFetchedAll: gradesFetchedAll,
  );
}

/// 判断当前账号是否已经有可展示的课表。兼容早期版本的单学期缓存，
/// 这样普通登录不会因为升级后找不到 profile 而重复抓取全部课表。
Future<bool> _hasLocalSchedule(String studentId) async {
  final profile = await UserDataCacheStore.loadProfile(studentId);
  if (profile != null && profile.scheduleTerms.isNotEmpty) return true;
  return await ScheduleCacheStore.loadLatest(studentId) != null;
}

Future<bool> _hasLocalGrades(String studentId) async {
  final profile = await UserDataCacheStore.loadProfile(studentId);
  if (profile?.hasGrades == true) return true;
  return (await UserDataCacheStore.loadGrades(studentId)).isNotEmpty;
}
