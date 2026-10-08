// 综测页的数值输入框（只接受数字，含负号与小数点）。
//
// 本文件是 `lib/zongce_page.dart` 的 **part**（不是独立库）：拆分只为缩短巨石
// 文件，**不改变任何符号的可见性** —— `_NumField` 本来就是这个库里私有的类。
// ⚠️ part 文件不能有自己的 import，依赖一律写在 `lib/zongce_page.dart` 根部。
part of '../zongce_page.dart';

/// 只接受数字（含负号与小数点）的输入框。
class _NumField extends StatefulWidget {
  const _NumField({
    super.key,
    required this.value,
    required this.onChanged,
    this.hint,
  });

  final double value;
  final ValueChanged<double?> onChanged;
  final String? hint;

  @override
  State<_NumField> createState() => _NumFieldState();
}

class _NumFieldState extends State<_NumField> {
  late final TextEditingController _c;
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _c = TextEditingController(text: _fmt(widget.value));
  }

  /// 回填外部改动（如「自动计算」写入 base）。
  ///
  /// ⚠️ 用户正在输入时**绝不能**覆盖：输入负数的第一个字符 `-` 会被
  /// `double.tryParse` 解析成 null（视作 0），回填会把刚敲的 `-` 改成 `0`，
  /// 导致根本没法输入负数。
  @override
  void didUpdateWidget(_NumField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value == oldWidget.value) return;
    if (_focus.hasFocus) return;
    final current = double.tryParse(_c.text.trim());
    if (current != widget.value) {
      _c.text = _fmt(widget.value);
    }
  }

  static String _fmt(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toString();
  }

  @override
  void dispose() {
    _focus.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _c,
      focusNode: _focus,
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'^-?\d*\.?\d*')),
      ],
      decoration: InputDecoration(
        hintText: widget.hint,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      style: const TextStyle(fontSize: 13),
      onChanged: (v) => widget.onChanged(double.tryParse(v.trim())),
    );
  }
}
