import 'package:flutter/material.dart';

/// Shared semantic tokens. Pages must not hardcode colors or radii.
abstract final class YlSpace {
  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16;
  static const double x5 = 20;
  static const double x6 = 24;
  static const double x8 = 32;
  static const double x10 = 40;
}

abstract final class YlRadius {
  static const double windowsControl = 4;
  static const double windowsPanel = 8;
  static const double androidControl = 12;
  static const double androidCard = 16;
  static const double pill = 999;
}

abstract final class YlSize {
  static const double windowsControl = 34;
  static const double windowsButton = 36;
  static const double androidTouch = 48;
  static const double androidInput = 56;
}

abstract final class YlWindowsColors {
  static const Color accentLight = Color(0xFF0067C0);
  static const Color accentDark = Color(0xFF60CDFF);
  static const Color scaffoldLight = Color(0xFFF3F3F3);
  static const Color scaffoldDark = Color(0xFF202020);
  static const Color surfaceLight = Color(0xFFFFFFFF);
  static const Color surfaceDark = Color(0xFF272727);
  static const Color inputLight = Color(0xFFFBFBFB);
  static const Color inputDark = Color(0xFF2B2B2B);
  static const Color outlineLight = Color(0xFFE5E5E5);
  static const Color outlineDark = Color(0xFF3A3A3A);
  static const Color textLight = Color(0xFF1B1B1B);
  static const Color textDark = Color(0xFFF5F5F5);
  static const Color secondaryTextLight = Color(0xFF5D5D5D);
  static const Color secondaryTextDark = Color(0xFFC8C8C8);
}

abstract final class YlMotion {
  static const Duration fast = Duration(milliseconds: 100);
  static const Duration normal = Duration(milliseconds: 160);
  static const Duration page = Duration(milliseconds: 220);
}

/// Platform-independent semantic status colors; always pair with icon/text.
abstract final class YlStatus {
  static const Color success = Color(0xFF16A34A);
  static const Color warning = Color(0xFFD97706);
  static const Color danger = Color(0xFFDC2626);
  static const Color offline = Color(0xFF8A93A3);
}
