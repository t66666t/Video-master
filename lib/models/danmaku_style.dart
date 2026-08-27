import 'package:flutter/material.dart';

/// User-facing adjustment limits for the core danmaku presentation controls.
///
/// Keep these values shared by persistence, the settings UI, and rendering so
/// an extreme value selected by the user is not silently narrowed elsewhere.
const double kDanmakuDisplayAreaMin = 0.01;
const double kDanmakuDisplayAreaMax = 1.0;
const double kDanmakuFontScaleMin = 0.2;
const double kDanmakuFontScaleMax = 4.0;
const double kDanmakuSpeedMin = 0.1;
const double kDanmakuSpeedMax = 8.0;

/// Font families bundled by the application. `null` keeps Flutter's current
/// default font, which is also the historical danmaku appearance.
const List<String?> kDanmakuFontFamilies = <String?>[
  null,
  'OPPO Sans 4.0',
  '方正黑体',
  'MiSans',
  'Noto Sans SC',
  'Noto Serif CJK SC',
  'Swei Gothic CJK SC',
  '方正楷体',
  'Comic Relief',
  'Roboto',
  'Inter',
];

String danmakuFontFamilyLabel(String? family) => family ?? '当前默认字体';

enum DanmakuOutlineType { standard, thin, heavy, projection }

extension DanmakuOutlineTypeX on DanmakuOutlineType {
  String get label => switch (this) {
    DanmakuOutlineType.standard => '标准描边',
    DanmakuOutlineType.thin => '细描边',
    DanmakuOutlineType.heavy => '粗描边',
    DanmakuOutlineType.projection => '45°投影',
  };

  String get description => switch (this) {
    DanmakuOutlineType.standard => '当前样式',
    DanmakuOutlineType.thin => '更轻巧',
    DanmakuOutlineType.heavy => '强对比',
    DanmakuOutlineType.projection => '立体感',
  };

  static DanmakuOutlineType fromName(String value) {
    return DanmakuOutlineType.values.firstWhere(
      (item) => item.name == value,
      orElse: () => DanmakuOutlineType.standard,
    );
  }
}

FontWeight danmakuFontWeight(int value) {
  final normalized = (value.clamp(100, 900) ~/ 100) * 100;
  return FontWeight.values[(normalized ~/ 100) - 1];
}
