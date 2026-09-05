/// Studio 专属精致浅色主题规范。
library;

import 'package:flutter/material.dart';

abstract final class StudioColors {
  // 背景与表面
  static const Color background = Color(0xFFF8FAFC); // Slate 50
  static const Color surface = Color(0xFFFFFFFF); // Pure White
  static const Color surfaceElevated = Color(0xFFF1F5F9); // Slate 100
  static const Color surfaceSubtle = Color(0xFFF8FAFC); // Slate 50

  // 边界与分割线
  static const Color border = Color(0xFFE2E8F0); // Slate 200
  static const Color borderSubtle = Color(0xFFEDF2F7);
  static const Color borderActive = Color(0xFF93C5FD); // Blue 300

  // 文字与排版
  static const Color textPrimary = Color(0xFF0F172A); // Slate 900
  static const Color textSecondary = Color(0xFF475569); // Slate 600
  static const Color textMuted = Color(0xFF94A3B8); // Slate 400
  static const Color textPlaceholder = Color(0xFFCBD5E1); // Slate 300

  // 品牌强调色 (沉稳专业工程蓝)
  static const Color primary = Color(0xFF2563EB); // Blue 600
  static const Color primaryHover = Color(0xFF1D4ED8); // Blue 700
  static const Color primarySubtle = Color(0xFFEFF6FF); // Blue 50
  static const Color primaryFocus = Color(0xFFDBEAFE); // Blue 100

  // 播放器指示与高亮
  static const Color activeSegmentBg = Color(0xFFF0F7FF); // 高亮浅蓝
  static const Color activeSegmentBorder = Color(0xFF3B82F6); // 高亮边框
  static const Color timelineTrack = Color(0xFFE2E8F0);
  static const Color timelineBuffer = Color(0xFFCBD5E1);

  // 状态语义色 (低饱和度)
  static const Color success = Color(0xFF10B981); // Emerald 500
  static const Color successSubtle = Color(0xFFECFDF5);
  static const Color warning = Color(0xFFF59E0B); // Amber 500
  static const Color warningSubtle = Color(0xFFFFFBEB);
  static const Color error = Color(0xFFEF4444); // Red 500
  static const Color errorSubtle = Color(0xFFFEF2F2);

  // 说话人标签色谱 (柔和低饱和度)
  static const List<Color> speakerPills = <Color>[
    Color(0xFF3B82F6), // 蓝
    Color(0xFF10B981), // 绿
    Color(0xFF8B5CF6), // 紫
    Color(0xFFF59E0B), // 琥珀
    Color(0xFF06B6D4), // 青
    Color(0xFFEC4899), // 粉
  ];
}

class StudioTheme {
  const StudioTheme._();

  static ThemeData get lightTheme {
    final ColorScheme colorScheme = ColorScheme.fromSeed(
      seedColor: StudioColors.primary,
      brightness: Brightness.light,
    ).copyWith(
      surface: StudioColors.surface,
      surfaceContainerLowest: StudioColors.surface,
      surfaceContainerLow: StudioColors.surfaceSubtle,
      surfaceContainer: StudioColors.surfaceElevated,
      surfaceContainerHigh: StudioColors.border,
      surfaceContainerHighest: StudioColors.borderActive,
      onSurface: StudioColors.textPrimary,
      onSurfaceVariant: StudioColors.textSecondary,
      outline: StudioColors.border,
      outlineVariant: StudioColors.borderSubtle,
      primary: StudioColors.primary,
      onPrimary: Colors.white,
      primaryContainer: StudioColors.primarySubtle,
      onPrimaryContainer: StudioColors.primaryHover,
      error: StudioColors.error,
      errorContainer: StudioColors.errorSubtle,
      onErrorContainer: StudioColors.error,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: StudioColors.background,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      dividerColor: StudioColors.border,
      dividerTheme: const DividerThemeData(
        color: StudioColors.border,
        thickness: 1,
        space: 1,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: StudioColors.surface,
        foregroundColor: StudioColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: StudioColors.textPrimary,
          letterSpacing: -0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: StudioColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: StudioColors.border, width: 1),
          borderRadius: BorderRadius.circular(10),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: StudioColors.primary,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: StudioColors.textPrimary,
          side: const BorderSide(color: StudioColors.border, width: 1),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: StudioColors.textSecondary,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          textStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: StudioColors.textSecondary,
          hoverColor: StudioColors.primarySubtle,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: StudioColors.surfaceElevated,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: StudioColors.border, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: StudioColors.border, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: StudioColors.primary, width: 1.5),
        ),
        hintStyle: const TextStyle(
          color: StudioColors.textMuted,
          fontSize: 13,
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: StudioColors.textPrimary,
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: const TextStyle(color: Colors.white, fontSize: 12),
        waitDuration: const Duration(milliseconds: 500),
      ),
    );
  }
}
