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

/// Dark chrome used by the remote viewport. The remote image itself is not
/// themed: these tokens only cover toolbars, overlays and status text around
/// the captured picture so both platforms look identical while controlling.
abstract final class YlRemoteColors {
  static const Color background = Color(0xFF0A0C0F);
  static const Color chrome = Color(0xFF14171C);
  static const Color chromeRaised = Color(0xFF1D222A);
  static const Color chromeOutline = Color(0xFF232831);
  static const Color statusBar = Color(0xFF101318);
  static const Color statusOutline = Color(0xFF1E232B);
  static const Color panel = Color(0xFF171B21);
  static const Color panelOutline = Color(0xFF2A303A);
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xB3FFFFFF);
  static const Color textTertiary = Color(0x8AFFFFFF);
  static const Color textDisabled = Color(0x61FFFFFF);
  static const Color iconDisabled = Color(0x40FFFFFF);
  static const Color frameOutline = Color(0x22FFFFFF);
  static const Color overlay = Color(0x88000000);
  static const Color overlayStrong = Color(0xB3000000);
  static const Color accent = Color(0xFF2563EB);
  static const Color accentIcon = Color(0xFF7EA6FF);
  static const Color connected = Color(0xFF4ADE80);
  static const Color viewOnly = Color(0xFFFBBF24);
  static const Color viewing = Color(0xFF60A5FA);
  static const Color danger = Color(0xFFF87171);
  static const Color dangerSurface = Color(0xFF3A1D22);
  static const Color dangerText = Color(0xFFFCA5A5);
  static const Color dangerOutline = Color(0xFF3A2A2D);
  static const Color bannerSurface = Color(0xFF2A2416);
  static const Color bannerText = Color(0xFFFDE68A);
  static const Color cursorOutline = Colors.black;
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
  static const Color folder = Color(0xFFD9A441);
}
