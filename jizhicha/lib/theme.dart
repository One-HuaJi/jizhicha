// ==================== 米黄/护眼主题系统 ====================
//
// 本文件集中管理应用配色与主题模式（浅色/深色）。
// - 浅色：以米黄、暖白、淡咖为主，降低蓝光刺激，长时间使用更养眼。
// - 深色：暖调暗色，避免纯白文字与纯黑背景的高对比刺眼。
// - 认证前后页面使用同一套 ColorScheme，保证色调统一。

import 'dart:io' show Directory, File, Platform;

import 'package:path_provider/path_provider.dart';
import 'dart:convert' show json;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;

/// 全局主题模式通知器，任何页面修改它都会触发整应用重建。
final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier<ThemeMode>(
  ThemeMode.system,
);

/// 主题持久化服务。
class ThemeService {
  static File? _file;

  static Future<File> _settingsFile() async {
    if (_file != null) return _file!;
    final dir = await _appConfigDir();
    final folder = Directory(dir);
    if (!folder.existsSync()) folder.createSync(recursive: true);
    _file = File('$dir${Platform.pathSeparator}theme.json');
    return _file!;
  }

  static Future<String> _appConfigDir() async {
    // 与 AppSettings 保持一致的本地配置目录偏好。
    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null && localAppData.isNotEmpty) {
        return '$localAppData${Platform.pathSeparator}jizhicha';
      }
    }
    // Android / Linux 走 path_provider 沙盒目录，
    // 否则会落到只读根目录而抛 FileSystemException。
    final docs = await getApplicationDocumentsDirectory();
    return docs.path;
  }

  static Future<void> load() async {
    try {
      final file = await _settingsFile();
      if (!file.existsSync()) return;
      final map =
          json.decode(await file.readAsString()) as Map<String, dynamic>;
      final modeName = map['themeMode'] as String?;
      themeNotifier.value = _parseMode(modeName);
    } catch (_) {
      themeNotifier.value = ThemeMode.system;
    }
  }

  static Future<void> save(ThemeMode mode) async {
    try {
      final file = await _settingsFile();
      await file.writeAsString(json.encode({'themeMode': mode.name}));
    } catch (_) {
      // 主题偏好写入失败不应阻塞主流程。
    }
  }

  static ThemeMode _parseMode(String? value) {
    switch (value) {
      case 'dark':
        return ThemeMode.dark;
      case 'light':
        return ThemeMode.light;
      default:
        return ThemeMode.system;
    }
  }

  /// 根据当前系统设置解析实际应使用的深浅模式。
  static ThemeMode resolveEffectiveMode(ThemeMode mode) {
    if (mode != ThemeMode.system) return mode;
    final brightness =
        SchedulerBinding.instance.platformDispatcher.platformBrightness;
    return brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light;
  }
}

/// 应用配色常量，便于在 widget 中直接引用统一语义化的颜色。
class AppColors {
  AppColors._();

  // 浅色模式主色板（米黄/暖咖）
  static const cream = Color(0xFFFDF8F0);
  static const creamDark = Color(0xFFF5EFE4);
  static const beige = Color(0xFFE8DCC4);
  static const beigeMedium = Color(0xFFD8C8A8);
  static const warmBrown = Color(0xFF5D4E37);
  static const softBrown = Color(0xFF8B7355);
  static const mutedBrown = Color(0xFFA08E72);
  static const espresso = Color(0xFF3D3226);

  // 强调色（柔和琥珀/赭石）
  static const amberSoft = Color(0xFFD69E2E);
  static const amberLight = Color(0xFFF6E05E);
  static const terracotta = Color(0xFFC65D3B);
  static const sage = Color(0xFF6B8E6B);
  static const softBlue = Color(0xFF6B8EAF);

  // 深色模式主色板（暖调暗色）
  static const darkBg = Color(0xFF1E1A16);
  static const darkSurface = Color(0xFF2A2520);
  static const darkSurfaceVariant = Color(0xFF3A332B);
  static const darkText = Color(0xFFF2E8D5);
  static const darkTextMuted = Color(0xFFB8A98F);
  static const darkDivider = Color(0xFF4A433A);
}

/// 应用主题构造器。
abstract class AppTheme {
  AppTheme._();

  static ThemeData _baseTheme(ColorScheme scheme) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerHighest,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        margin: EdgeInsets.zero,
      ),
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primaryContainer,
          foregroundColor: scheme.onPrimaryContainer,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          elevation: 0,
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.primary,
          side: BorderSide(color: scheme.outlineVariant),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.error, width: 1.2),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.error, width: 1.5),
        ),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        hintStyle: TextStyle(color: scheme.onSurfaceVariant.withAlpha(160)),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withAlpha(120),
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(color: scheme.onInverseSurface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHighest,
        selectedColor: scheme.primaryContainer,
        labelStyle: TextStyle(color: scheme.onSurface),
        selectedShadowColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.primary,
        textColor: scheme.onSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: scheme.surface,
        selectedItemColor: scheme.primary,
        unselectedItemColor: scheme.onSurfaceVariant,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerHighest,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(10),
        ),
        textStyle: TextStyle(color: scheme.onInverseSurface),
      ),
    );
  }

  /// 浅色主题：米黄护眼风格。
  static ThemeData get light {
    const scheme = ColorScheme.light(
      brightness: Brightness.light,
      primary: AppColors.amberSoft,
      onPrimary: AppColors.espresso,
      primaryContainer: AppColors.beige,
      onPrimaryContainer: AppColors.warmBrown,
      secondary: AppColors.softBrown,
      onSecondary: Colors.white,
      secondaryContainer: AppColors.creamDark,
      onSecondaryContainer: AppColors.warmBrown,
      tertiary: AppColors.sage,
      onTertiary: Colors.white,
      tertiaryContainer: Color(0xFFE3EEDF),
      onTertiaryContainer: Color(0xFF3D4F3D),
      surface: AppColors.cream,
      onSurface: AppColors.espresso,
      surfaceContainerHighest: AppColors.creamDark,
      onSurfaceVariant: AppColors.softBrown,
      outline: AppColors.beigeMedium,
      outlineVariant: AppColors.beige,
      error: AppColors.terracotta,
      onError: Colors.white,
      errorContainer: Color(0xFFFFE4DC),
      onErrorContainer: Color(0xFF7A2E1D),
      inverseSurface: AppColors.warmBrown,
      onInverseSurface: AppColors.cream,
      shadow: Color(0x3F5D4E37),
    );
    return _baseTheme(scheme).copyWith(
      textTheme: _textTheme(scheme),
      appBarTheme: _baseTheme(
        scheme,
      ).appBarTheme.copyWith(backgroundColor: scheme.surface),
    );
  }

  /// 深色主题：暖调暗色，避免高对比刺眼。
  static ThemeData get dark {
    const scheme = ColorScheme.dark(
      brightness: Brightness.dark,
      primary: AppColors.amberLight,
      onPrimary: AppColors.espresso,
      primaryContainer: Color(0xFF5C4D2A),
      onPrimaryContainer: AppColors.darkText,
      secondary: AppColors.darkTextMuted,
      onSecondary: AppColors.darkBg,
      secondaryContainer: AppColors.darkSurfaceVariant,
      onSecondaryContainer: AppColors.darkText,
      tertiary: AppColors.sage,
      onTertiary: Colors.white,
      tertiaryContainer: Color(0xFF3A4A3A),
      onTertiaryContainer: Color(0xFFD8E8D4),
      surface: AppColors.darkBg,
      onSurface: AppColors.darkText,
      surfaceContainerHighest: AppColors.darkSurface,
      onSurfaceVariant: AppColors.darkTextMuted,
      outline: AppColors.darkDivider,
      outlineVariant: AppColors.darkSurfaceVariant,
      error: Color(0xFFFF8A7A),
      onError: AppColors.darkBg,
      errorContainer: Color(0xFF5C2E26),
      onErrorContainer: Color(0xFFFFD4CC),
      inverseSurface: AppColors.darkText,
      onInverseSurface: AppColors.darkBg,
      shadow: Color(0x7F000000),
    );
    return _baseTheme(scheme).copyWith(
      textTheme: _textTheme(scheme),
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: _baseTheme(
        scheme,
      ).appBarTheme.copyWith(backgroundColor: scheme.surface),
    );
  }

  static TextTheme _textTheme(ColorScheme scheme) {
    return TextTheme(
      titleLarge: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: scheme.onSurface,
      ),
      titleMedium: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      titleSmall: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      bodyLarge: TextStyle(fontSize: 16, color: scheme.onSurface),
      bodyMedium: TextStyle(fontSize: 14, color: scheme.onSurface),
      bodySmall: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: scheme.primary,
      ),
    );
  }
}

/// 常用渐变/装饰小工具，统一认证前后卡片质感。
class AppDecorations {
  AppDecorations._();

  static BoxDecoration cardGradient(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [scheme.surfaceContainerHighest, scheme.surface],
      ),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: scheme.outlineVariant.withAlpha(140)),
      boxShadow: [
        BoxShadow(
          color: scheme.shadow.withAlpha(40),
          blurRadius: 18,
          offset: const Offset(0, 6),
        ),
      ],
    );
  }
}
