import 'dart:async' show Timer;

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter/material.dart';

// ==================== 同步冷却（手动课表/成绩共用） ====================
enum GradeSyncScope { latest, all }

enum SyncResource { schedule, grade }

/// 手动课表/成绩查询共用的短冷却，避免用户连续点击导致教务系统重复
/// 返回同一份页面或触发网关限流。冷却从请求开始计时，失败时也保留，
/// 这样“重试”不会在几秒内形成请求风暴。
class DataSyncCooldownController extends ChangeNotifier {
  static const duration = Duration(seconds: 10);

  DateTime? _scheduleUntil;
  DateTime? _gradeUntil;
  Timer? _timer;

  DateTime? _untilFor(SyncResource resource) =>
      resource == SyncResource.schedule ? _scheduleUntil : _gradeUntil;

  Duration remaining(SyncResource resource, {DateTime? now}) {
    final until = _untilFor(resource);
    if (until == null) return Duration.zero;
    final left = until.difference(now ?? DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  bool isCooling(SyncResource resource) => remaining(resource) > Duration.zero;

  String remainingText(SyncResource resource) {
    final seconds = remaining(resource).inSeconds.ceil();
    return seconds <= 0 ? '' : '${seconds}s';
  }

  bool tryStartAll(Iterable<SyncResource> resources) {
    final unique = resources.toSet();
    if (unique.any(isCooling)) return false;
    final until = DateTime.now().add(duration);
    if (unique.contains(SyncResource.schedule)) _scheduleUntil = until;
    if (unique.contains(SyncResource.grade)) _gradeUntil = until;
    if (unique.isNotEmpty) {
      _ensureTimer();
      notifyListeners();
    }
    return true;
  }

  void _ensureTimer() {
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!isCooling(SyncResource.schedule) && !isCooling(SyncResource.grade)) {
        _timer?.cancel();
        _timer = null;
      }
      notifyListeners();
    });
  }
}

final dataSyncCooldown = DataSyncCooldownController();

/// 显示课表/成绩本次同步的 10 秒冷却状态。
///
/// 指示器**自己**监听 [dataSyncCooldown]（内部 [ListenableBuilder]），所以倒计时
/// 一秒一次的刷新只会重建这一个小部件。此前是两页的 State 监听冷却并 `setState`，
/// 每次同步后 10 秒内整张课表（含按周筛选、parseWeekSpans、冲突聚类）会被重建 10 遍。
/// 没有冷却时不占用额外的布局空间。
class SyncCooldownIndicator extends StatelessWidget {
  final SyncResource resource;

  const SyncCooldownIndicator({required this.resource, super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: dataSyncCooldown,
      builder: (context, _) => _buildIndicator(context),
    );
  }

  Widget _buildIndicator(BuildContext context) {
    final remaining = dataSyncCooldown.remaining(resource);
    if (remaining <= Duration.zero) return const SizedBox.shrink();
    final seconds = remaining.inSeconds.ceil();
    final totalMilliseconds =
        DataSyncCooldownController.duration.inMilliseconds;
    final progress = (1 - remaining.inMilliseconds / totalMilliseconds).clamp(
      0.0,
      1.0,
    );
    final label = resource == SyncResource.schedule ? '课表' : '成绩';
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '$label更新冷却中，还需 $seconds 秒',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(
              value: progress,
              strokeWidth: 3,
              color: colorScheme.primary,
              backgroundColor: colorScheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$label冷却 ${seconds}s',
            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
