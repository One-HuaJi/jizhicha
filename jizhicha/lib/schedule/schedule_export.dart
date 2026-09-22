// 课表页职责：课表导出（JPG/PNG/HTML）、导出目录与 JPG 后台编码。
part of 'schedule_page.dart';

enum _ScheduleExportFormat { jpg, png, html }

mixin _ScheduleExportSection on _SchedulePageDataSection {
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
      // 必须用 **exe 所在目录**，不能用 Directory.current。
      // 双击 exe 时两者碰巧一致，但从快捷方式（"起始位置"不同）、开始菜单、
      // 终端或 IDE 启动时 CWD 会是别处，导出会落到用户找不到的地方；CWD 不可写
      // （如装在 Program Files）时 dir.create() 直接抛异常、导出失败。
      // 与 zongce_page.dart 的 _exportDirectory() 保持同一约定。
      final exeDir = File(Platform.resolvedExecutable).parent;
      final dir = Directory(
        '${exeDir.path}${Platform.pathSeparator}screen',
      );
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
        // PNG 直接落盘；JPG 需要解码 + 重新编码，放到后台 isolate 里做，
        // 否则数兆像素的编解码会把 UI 线程冻住数秒。
        final bytes = format == _ScheduleExportFormat.png
            ? pngBytes
            : await Isolate.run(() => _encodeScheduleJpg(pngBytes));

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
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('导出失败，请重试')),
      );
    }
  }

}

/// 把课表 PNG 解码后重新编码成 JPG（导出流程用）。
///
/// 大课表是数兆像素，解码 + 编码在 UI isolate 上会冻结界面数秒，因此放进
/// [Isolate.run]。`package:image` 的 `Image` 对象不能跨 isolate 传递，所以解码与
/// 编码都留在同一个 isolate 内，只把 `Uint8List` 传进传出。
Uint8List _encodeScheduleJpg(Uint8List pngBytes) {
  final decoded = img.decodePng(pngBytes);
  if (decoded == null) {
    // 旧实现是 `decodePng(...)!`：返回 null 时抛出无信息量的空断言错误。
    // 这里给一个可读错误，由导出流程统一提示"导出失败"，不再静默崩溃。
    throw const FormatException('课表图片解码失败，无法生成 JPG');
  }
  return img.encodeJpg(decoded, quality: 92);
}
