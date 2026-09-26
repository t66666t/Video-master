import 'package:flutter/material.dart';

/// Home-library colors from docs/design/design-tokens.md.
///
/// Covers, placeholders, and playback artwork do not use these.
class AppTokens {
  const AppTokens._();

  static const Color bgBase = Color(0xFF191919);
  static const Color bgCard = Color(0xFF2C2C2C);
  static const Color bgRaised = Color(0xFF202020);
  static const Color bgOverlay = Color(0xFF252525);

  static const Color text1 = Color(0xFFE3E2E0);
  static const Color text2 = Color(0xFF9B9A97);
  static const Color text3 = Color(0xFF6F6E6B);
  static const Color text4 = Color(0xFF4A4A48);

  static const Color accent = Color(0xFF4B8EF0);
  static const Color danger = Color(0xFFE5625C);

  static const Color brandBilibili = Color(0xFFFB7299);
  static const Color brandYtDlp = Color(0xFFFF5A52);
  static const Color brandBatch = Color(0xFFA98BF2);

  static const Color lineSubtle = Color(0x0EFFFFFF);

  static Color get accentSoft => accent.withValues(alpha: 0.16);
}
