// 课表页职责：课表页背景图的渲染层（`AppSettings.scheduleBackgroundPath`）。
//
// 只做渲染，选图与落盘在 `lib/schedule_background_setting.dart`（设置页侧，已就绪）。
//
// 三条硬口径：
//  1. **绝不影响导出**：导出走的是 `_scheduleTableRepaintKey`（表格卡片自身，
//     见 `schedule_export.dart`），而这一层的图片与遮罩都在**所有**
//     RepaintBoundary 之外 ⇒ 导出图里永远没有背景图；
//  2. **文件缺失静默回退**：路径为空 / 文件不存在 / 不是普通文件 / 零字节
//     都当作"没设背景"，回落到主题底色，不抛异常、不弹提示；
//  3. **要一层遮罩**：照片直接垫在下面会让深色课块 / 副文字糊成一片，所以
//     图片之上再盖一层主题色的半透明纱（[scrimAlpha]），保证任何照片上
//     正文都可读。
import 'dart:io';

import 'package:flutter/material.dart';

import '../theme.dart';

/// 解析背景图路径。返回 null 表示"没有可用的背景图"（静默回退）。
///
/// 抽成公开函数是为了让单测能直接验四种回退（空串 / 不存在 / 目录 / 零字节），
/// 不必真的把一张图 pump 进 widget 树里才能确认"不会抛异常"。
File? resolveScheduleBackgroundFile(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return null;
  try {
    final file = File(trimmed);
    if (!file.existsSync()) return null;
    final stat = file.statSync();
    if (stat.type != FileSystemEntityType.file) return null;
    // 0 字节多半是用户删了内容或复制中断：当没有背景处理，别去解码它。
    if (stat.size <= 0) return null;
    return file;
  } catch (_) {
    // 权限、路径非法、盘符掉了…… 一律按"没有背景图"处理。
    return null;
  }
}

/// 背景图之上的可读性遮罩（主题色 + 这个 alpha）。
///
/// 0.72：照片还剩约 28% 的可见度——既看得出是用户选的图，又不至于让
/// 账号状态行 / 周次进度条 / 工具行 的文字掉到不可读。
const int scheduleBackgroundScrimAlpha = 184;

/// 遮罩色：跟随主题的底色（浅色=米白 / 深色=暖黑），而不是固定的黑/白，
/// 这样深色主题下不会出现"一块发灰的亮纱"。
Color scheduleBackgroundScrimColor(Brightness brightness) =>
    (brightness == Brightness.dark ? AppColors.darkBg : AppColors.cream)
        .withAlpha(scheduleBackgroundScrimAlpha);

/// 课表页的底板：背景图 + 遮罩 + 内容。
///
/// [child] 必须**自身透明**（调用方传的是 `ColoredBox(Colors.transparent)` 包住的
/// RepaintBoundary），底色由这一层负责画；否则照片会被 child 的底色盖掉。
class ScheduleBackgroundLayer extends StatelessWidget {
  const ScheduleBackgroundLayer({
    super.key,
    required this.path,
    required this.child,
  });

  /// 背景图绝对路径（`AppSettings.scheduleBackgroundPath`）。
  final String path;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final file = resolveScheduleBackgroundFile(path);
    if (file == null) {
      // 没设背景 / 文件没了：与改造前完全一致的一层主题底色。
      return Stack(
        fit: StackFit.expand,
        children: [ColoredBox(color: scheme.surface), child],
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: Image.file(
            file,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            // 文件在 resolve 之后被删 / 解码失败：同样静默回退主题底色。
            errorBuilder: (context, error, stackTrace) =>
                ColoredBox(color: scheme.surface),
          ),
        ),
        Positioned.fill(
          child: ColoredBox(
            color: scheduleBackgroundScrimColor(scheme.brightness),
          ),
        ),
        child,
      ],
    );
  }
}
