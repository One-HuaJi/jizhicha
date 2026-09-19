import 'package:flutter/material.dart';

import 'campus_environment.dart';
import 'jwxt_client.dart';
import 'sync_cooldown.dart';

/// 课表页与成绩页共用的样板逻辑。
///
/// ## 为什么需要这个 mixin
///
/// 这两页原本各自复制了一份 `_canReuseEducationSession` / `_showSyncCooldownMessage`
/// / `_formatCachedAt`，而且**副本已经分叉**（2026-09-18 全项目自查发现）：
///
/// - `_showSyncCooldownMessage`：成绩页硬编码 `SyncResource.grade` 与"成绩"文案，
///   课表页已参数化为 `(SyncResource resource)`。
/// - `_canReuseEducationSession`：成绩页直接调 `campusEnvironment.detect()`，
///   课表页调自己的包装 `_detectCampusEnvironment()`（实测两者等价，纯外观差异）。
/// - `_formatCachedAt`：两处逐字相同。
///
/// 分叉本身当时没有造成 bug（成绩页只用一个资源类型，包装方法也只是透传），
/// **但这是典型的腐化起点**：下次改冷却逻辑若只改一边，两页就会静默不一致。
/// 统一到这里后，行为只可能有一份定义。
///
/// 这里采用**参数的广义版本**（课表页那一版），因为它是成绩页版本的严格超集：
/// 成绩页传入 `SyncResource.grade` 即可得到与旧实现完全相同的文案。
mixin CampusSyncHelpers<T extends StatefulWidget> on State<T> {
  /// 当前页面对应的学号。由使用方提供（两页都从 `widget.studentId` 取）。
  String get campusStudentId;

  /// 教务会话是否可以复用（不重新认证直接查询）。
  ///
  /// 判定条件：校园内网在线 + 已登录 + 登录的学号与当前页面一致。
  /// 任一不满足都要重新探测一次，避免拿旧会话去查新用户的数据。
  Future<bool> canReuseEducationSession() async {
    if (campusEnvironment.checking) await campusEnvironment.detect();
    if (campusEnvironment.online != true) {
      await campusEnvironment.detect();
    }
    final client = JwxtClient();
    return campusEnvironment.online == true &&
        client.isLoggedIn &&
        client.authenticatedStudentId == campusStudentId;
  }

  /// 同步冷却中的提示。
  ///
  /// 取广义版本：旧成绩页写死 `SyncResource.grade` + "成绩"，与传入
  /// `SyncResource.grade` 时的行为完全一致，所以这次统一不改变任何现有行为。
  void showSyncCooldownMessage(SyncResource resource) {
    final remaining = dataSyncCooldown.remainingText(resource);
    if (remaining.isEmpty || !mounted) return;
    final label = resource == SyncResource.schedule ? '课表' : '成绩';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$label更新冷却中，还需 $remaining 后重试')));
  }

  /// 本地缓存时间的紧凑显示（`YYYY-MM-DD HH:mm`）。
  String formatCachedAt(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}';
  }
}
