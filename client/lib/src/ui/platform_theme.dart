import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'design_tokens.dart';

/// Builds a Windows Fluent-like theme or an AOSP/Pixel Material 3 theme.
/// Colors, typography, control sizing and interaction density are platform
/// specific; individual pages must not branch on raw colors.
ThemeData buildPlatformTheme(
  Brightness brightness, {
  TargetPlatform? platform,
}) {
  final target = platform ?? defaultTargetPlatform;
  if (target == TargetPlatform.windows) {
    return _windowsTheme(brightness);
  }
  return _androidTheme(brightness);
}

ThemeData _windowsTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final base = ColorScheme.fromSeed(
    seedColor: YlWindowsColors.accentLight,
    brightness: brightness,
  );
  final scheme = base.copyWith(
    primary: dark ? YlWindowsColors.accentDark : YlWindowsColors.accentLight,
    onPrimary: dark ? const Color(0xFF003064) : Colors.white,
    surface: dark ? YlWindowsColors.surfaceDark : YlWindowsColors.surfaceLight,
    onSurface:
        dark ? YlWindowsColors.textDark : YlWindowsColors.textLight,
    surfaceContainerHighest:
        dark ? const Color(0xFF323232) : const Color(0xFFF0F0F0),
    outline: dark ? YlWindowsColors.outlineDark : YlWindowsColors.outlineLight,
    outlineVariant:
        dark ? const Color(0xFF333333) : const Color(0xFFE8E8E8),
  );
  final typography = Typography.material2021(platform: TargetPlatform.windows);
  final textTheme = typography.black.apply(
    bodyColor: scheme.onSurface,
    displayColor: scheme.onSurface,
    fontFamily: 'Segoe UI Variable Text',
    fontFamilyFallback: const ['Segoe UI', 'Microsoft YaHei UI'],
  );
  final sizedText = textTheme.copyWith(
    headlineMedium: textTheme.headlineMedium?.copyWith(
      fontSize: 26,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
      height: 1.25,
    ),
    titleLarge: textTheme.titleLarge?.copyWith(
      fontSize: 20,
      fontWeight: FontWeight.w600,
      height: 1.3,
    ),
    titleMedium: textTheme.titleMedium?.copyWith(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      height: 1.35,
    ),
    bodyLarge: textTheme.bodyLarge?.copyWith(fontSize: 14, height: 1.4),
    bodyMedium: textTheme.bodyMedium?.copyWith(fontSize: 14, height: 1.4),
    bodySmall: textTheme.bodySmall?.copyWith(fontSize: 12, height: 1.35),
    labelLarge: textTheme.labelLarge?.copyWith(
      fontSize: 14,
      fontWeight: FontWeight.w600,
    ),
    labelMedium: textTheme.labelMedium?.copyWith(fontSize: 12),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    fontFamily: 'Segoe UI Variable Text',
    fontFamilyFallback: const ['Segoe UI', 'Microsoft YaHei UI'],
    textTheme: sizedText,
    scaffoldBackgroundColor:
        dark ? YlWindowsColors.scaffoldDark : YlWindowsColors.scaffoldLight,
    canvasColor: dark ? YlWindowsColors.scaffoldDark : YlWindowsColors.scaffoldLight,
    dividerColor: scheme.outlineVariant,
    splashFactory: NoSplash.splashFactory,
    hoverColor: scheme.primary.withValues(alpha: 0.06),
    focusColor: scheme.primary.withValues(alpha: 0.12),
    highlightColor: scheme.primary.withValues(alpha: 0.10),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(YlRadius.windowsPanel),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: dark ? const Color(0xFF2B2B2B) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(YlRadius.windowsPanel),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      titleTextStyle: sizedText.titleLarge,
      contentTextStyle: sizedText.bodyMedium,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: dark ? YlWindowsColors.inputDark : YlWindowsColors.inputLight,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: YlSpace.x3,
        vertical: 10,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(YlRadius.windowsControl),
        borderSide: BorderSide(color: scheme.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(YlRadius.windowsControl),
        borderSide: BorderSide(color: scheme.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(YlRadius.windowsControl),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(YlRadius.windowsControl),
        borderSide: BorderSide(color: scheme.error, width: 1.5),
      ),
      labelStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
      hintStyle: TextStyle(
        color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
        fontSize: 13,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, YlSize.windowsButton),
        padding: const EdgeInsets.symmetric(horizontal: YlSpace.x4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YlRadius.windowsControl),
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        splashFactory: NoSplash.splashFactory,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, YlSize.windowsButton),
        padding: const EdgeInsets.symmetric(horizontal: YlSpace.x4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YlRadius.windowsControl),
        ),
        side: BorderSide(color: scheme.outline),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: YlSpace.x3),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YlRadius.windowsControl),
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(32, 32),
        padding: const EdgeInsets.all(6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YlRadius.windowsControl),
        ),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      thumbVisibility: const WidgetStatePropertyAll(false),
      radius: const Radius.circular(3),
      thumbColor: WidgetStatePropertyAll(
        scheme.onSurfaceVariant.withValues(alpha: 0.45),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 450),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF303030) : const Color(0xFFF2F2F2),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: scheme.outlineVariant),
      ),
      textStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 12,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? const Color(0xFF323232) : const Color(0xFFF2F2F2),
      contentTextStyle: TextStyle(color: scheme.onSurface, fontSize: 13),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
  );
}

ThemeData _androidTheme(Brightness brightness) {
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF2563EB),
      brightness: brightness,
    ),
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
  );
  final scheme = base.colorScheme;
  final textTheme = base.textTheme.copyWith(
    headlineMedium: base.textTheme.headlineMedium?.copyWith(
      fontSize: 28,
      height: 1.28,
      fontWeight: FontWeight.w400,
    ),
    titleLarge: base.textTheme.titleLarge?.copyWith(
      fontSize: 22,
      height: 1.27,
      fontWeight: FontWeight.w500,
    ),
    titleMedium: base.textTheme.titleMedium?.copyWith(
      fontSize: 16,
      height: 1.5,
      fontWeight: FontWeight.w500,
    ),
    bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: 16, height: 1.5),
    bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 14, height: 1.43),
    bodySmall: base.textTheme.bodySmall?.copyWith(fontSize: 12, height: 1.33),
    labelLarge: base.textTheme.labelLarge?.copyWith(fontSize: 14),
  );
  return base.copyWith(
    textTheme: textTheme,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(YlRadius.androidCard),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: false,
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: YlSpace.x4,
        vertical: YlSpace.x4,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(YlRadius.androidControl),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(YlRadius.androidControl),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(YlRadius.androidControl),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(YlRadius.androidControl),
        borderSide: BorderSide(color: scheme.error),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, YlSize.androidTouch),
        padding: const EdgeInsets.symmetric(horizontal: YlSpace.x6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, YlSize.androidTouch),
        padding: const EdgeInsets.symmetric(horizontal: YlSpace.x6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(48, 48),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: TextStyle(color: scheme.onInverseSurface),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 80,
      elevation: 0,
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: scheme.secondaryContainer,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStatePropertyAll(
        textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w500),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: textTheme.titleLarge,
      systemOverlayStyle: brightness == Brightness.dark
          ? SystemUiOverlayStyle.light.copyWith(
              statusBarColor: Colors.transparent,
              systemNavigationBarColor: Colors.transparent,
            )
          : SystemUiOverlayStyle.dark.copyWith(
              statusBarColor: Colors.transparent,
              systemNavigationBarColor: Colors.transparent,
            ),
    ),
  );
}
