// 认证相关页面共用的小组件（跨页共享的密码可见性切换按钮）。
import 'package:flutter/material.dart';

class AuthPasswordVisibilityButton extends StatelessWidget {
  final bool visible;
  final VoidCallback onPressed;

  const AuthPasswordVisibilityButton({
    super.key,
    required this.visible,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: visible ? '隐藏密码' : '显示密码',
      onPressed: onPressed,
      icon: Icon(
        visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        size: 18,
      ),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      visualDensity: VisualDensity.compact,
    );
  }
}
