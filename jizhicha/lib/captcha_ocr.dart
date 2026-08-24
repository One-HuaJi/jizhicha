import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

/// 使用 ddddocr 的轻量 ONNX 模型在本机识别教务验证码。
///
/// 学校验证码固定为 4 位小写字母/数字。模型只在 Android 和 Windows
/// 上运行，不上传图片；其它平台会回退到手动输入。模型来自 ddddocr 的
/// `common_old.onnx`，推理后使用该模型的字符索引做 CTC 解码，并严格
/// 过滤到小写字母和数字，避免把页面中的其它文字填入验证码框。
class CaptchaOcr {
  CaptchaOcr._();

  static const _modelAsset = 'assets/models/ddddocr_common_old.onnx';
  static final _runtime = OnnxRuntime();
  static Future<OrtSession>? _sessionFuture;

  // ddddocr common_old.onnx 的字符表索引。索引 0 是 CTC blank，未列出。
  // 只保留学校验证码允许的 26 个小写字母和 10 个数字。
  static const Map<int, String> _captchaCharset = {
    78: '2',
    409: '7',
    806: 'r',
    1066: 'b',
    1107: 'c',
    1638: 'f',
    1769: 'v',
    2041: 'i',
    2089: 'l',
    2663: 'u',
    2879: '9',
    3072: 'k',
    3466: 's',
    4050: 'n',
    4410: '1',
    4617: 'm',
    4730: 'z',
    5027: 'p',
    5726: 'd',
    5806: '4',
    5961: '6',
    6185: 'j',
    6257: 'e',
    6612: 'y',
    6736: 'x',
    6749: '0',
    6939: 'o',
    6977: '5',
    6979: '8',
    7136: 'w',
    7198: 'a',
    7405: 'q',
    7721: '3',
    7723: 't',
    8119: 'g',
    8196: 'h',
  };

  static Future<String?> recognize(Uint8List bytes) async {
    if (bytes.isEmpty || (!Platform.isAndroid && !Platform.isWindows)) {
      return null;
    }

    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null || decoded.width < 12 || decoded.height < 8) {
        return null;
      }

      final session = await _session();

      // The unmodified image is the authoritative result. Running the model
      // twice and choosing the larger raw logit made a valid `l` from the
      // first pass get replaced by an `i` from a cropped pass, while also
      // doubling the normal recognition time. Only try the borderless image
      // when the primary pass cannot produce a complete four-character code.
      final primary = await _run(session, decoded);
      if (primary != null) return primary.value;

      final borderless = _removeDarkBorder(decoded);
      if (borderless.width == decoded.width &&
          borderless.height == decoded.height) {
        return null;
      }
      return (await _run(session, borderless))?.value;
    } catch (_) {
      // 模型缺失、设备 ABI 不支持或 ONNX Runtime 初始化失败时，OCR
      // 只是便捷功能，不应阻断正常的手动验证码登录流程。
      return null;
    }
  }

  static Future<OrtSession> _session() {
    return _sessionFuture ??= _runtime.createSessionFromAsset(
      _modelAsset,
      options: OrtSessionOptions(
        intraOpNumThreads: 2,
        interOpNumThreads: 1,
        useArena: true,
      ),
    );
  }

  static Future<_CaptchaPrediction?> _run(
    OrtSession session,
    img.Image source,
  ) async {
    final tensor = _toModelInput(source);
    final input = await OrtValue.fromList(tensor.values, [
      1,
      1,
      tensor.height,
      tensor.width,
    ]);
    try {
      final outputs = await session.run({session.inputNames.first: input});
      try {
        if (outputs.isEmpty) return null;
        final output =
            outputs[session.outputNames.first] ?? outputs.values.first;
        final values = await output.asFlattenedList();
        return _decodeLogits(values, output.shape);
      } finally {
        for (final output in outputs.values) {
          await output.dispose();
        }
      }
    } finally {
      await input.dispose();
    }
  }

  /// ddddocr 的默认模型将图片缩放到高度 64、保持宽高比、转灰度并
  /// 归一化到 [0, 1]，输入布局为 NCHW。
  static _CaptchaTensor _toModelInput(img.Image source) {
    const targetHeight = 64;
    final targetWidth = math.max(
      16,
      (source.width * targetHeight / source.height).round(),
    );
    final resized = img.copyResize(
      source,
      width: targetWidth,
      height: targetHeight,
      interpolation: img.Interpolation.cubic,
    );
    final gray = img.grayscale(resized);
    final values = Float32List(targetWidth * targetHeight);
    var offset = 0;
    for (var y = 0; y < targetHeight; y++) {
      for (var x = 0; x < targetWidth; x++) {
        values[offset++] = gray.getPixel(x, y).luminanceNormalized.toDouble();
      }
    }
    return _CaptchaTensor(
      values: values,
      width: targetWidth,
      height: targetHeight,
    );
  }

  /// 将 ONNX 输出 [sequence, 1, classes]（兼容 [1, sequence, classes]）
  /// 做 argmax + CTC 去重，并只接受完整四位结果。
  static _CaptchaPrediction? _decodeLogits(
    List<dynamic> values,
    List<int> shape,
  ) {
    if (shape.length != 3 || shape.contains(0)) return null;

    late final int sequenceLength;
    late final int classCount;
    if (shape[1] == 1) {
      sequenceLength = shape[0];
      classCount = shape[2];
    } else if (shape[0] == 1) {
      sequenceLength = shape[1];
      classCount = shape[2];
    } else {
      return null;
    }
    if (values.length != sequenceLength * classCount) return null;

    final chars = <String>[];
    var previousIndex = -1;
    for (var timestep = 0; timestep < sequenceLength; timestep++) {
      final offset = timestep * classCount;
      var bestIndex = 0;
      var bestLogit = double.negativeInfinity;
      for (var classIndex = 0; classIndex < classCount; classIndex++) {
        final logit = (values[offset + classIndex] as num).toDouble();
        if (logit > bestLogit) {
          bestLogit = logit;
          bestIndex = classIndex;
        }
      }
      if (bestIndex == previousIndex) continue;
      previousIndex = bestIndex;
      if (bestIndex == 0) continue; // CTC blank
      final character = _captchaCharset[bestIndex];
      if (character == null) return null;
      chars.add(character);
      if (chars.length > 4) return null;
    }

    if (chars.length != 4) return null;
    return _CaptchaPrediction(value: chars.join());
  }

  /// 纯逻辑规范化入口，保留给 UI/测试使用；不会把 3 位或 5 位结果
  /// 强行填入验证码输入框。
  static String? normalize(String raw) {
    final tokens = raw
        .split(RegExp(r'[^A-Za-z0-9]+'))
        .map((token) => token.toLowerCase())
        .where((token) => token.length == 4)
        .toList(growable: false);
    if (tokens.isNotEmpty) return tokens.first;

    final compact = raw.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toLowerCase();
    return compact.length == 4 ? compact : null;
  }

  /// 用于回归测试模型字符映射和 CTC 解码，不依赖平台插件。
  static String? decodeCharacterIndices(Iterable<int> indices) {
    final chars = <String>[];
    var previous = -1;
    for (final index in indices) {
      if (index == previous) continue;
      previous = index;
      if (index == 0) continue;
      final character = _captchaCharset[index];
      if (character == null) return null;
      chars.add(character);
    }
    return chars.length == 4 ? chars.join() : null;
  }

  static img.Image _removeDarkBorder(img.Image source) {
    bool dark(num value) => value < 0.35;
    double rowDarkRatio(int y) {
      var count = 0;
      for (var x = 0; x < source.width; x++) {
        if (dark(source.getPixel(x, y).luminanceNormalized)) count++;
      }
      return count / source.width;
    }

    double columnDarkRatio(int x) {
      var count = 0;
      for (var y = 0; y < source.height; y++) {
        if (dark(source.getPixel(x, y).luminanceNormalized)) count++;
      }
      return count / source.height;
    }

    final top = List.generate(
      source.height,
      rowDarkRatio,
    ).indexWhere((ratio) => ratio > 0.55);
    final bottom = List.generate(
      source.height,
      rowDarkRatio,
    ).lastIndexWhere((ratio) => ratio > 0.55);
    final left = List.generate(
      source.width,
      columnDarkRatio,
    ).indexWhere((ratio) => ratio > 0.55);
    final right = List.generate(
      source.width,
      columnDarkRatio,
    ).lastIndexWhere((ratio) => ratio > 0.55);

    final cropLeft = left >= 0 ? left + 2 : 0;
    final cropTop = top >= 0 ? top + 2 : 0;
    final cropRight = right >= 0 ? right - 1 : source.width;
    final cropBottom = bottom >= 0 ? bottom - 1 : source.height;
    final cropWidth = cropRight - cropLeft;
    final cropHeight = cropBottom - cropTop;
    if (cropWidth < 20 || cropHeight < 10) return source;
    return img.copyCrop(
      source,
      x: cropLeft,
      y: cropTop,
      width: cropWidth,
      height: cropHeight,
    );
  }
}

class _CaptchaTensor {
  final Float32List values;
  final int width;
  final int height;

  const _CaptchaTensor({
    required this.values,
    required this.width,
    required this.height,
  });
}

class _CaptchaPrediction {
  final String value;

  const _CaptchaPrediction({required this.value});
}
