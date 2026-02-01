import 'package:flutter/material.dart';

/// 字幕文字样式 - 横竖屏共享
/// 包含字体、颜色、描边、阴影等视觉样式属性
class SubtitleTextStyle {
  // Use separate fonts for Chinese and English
  final String fontFamilyChinese;
  final String fontFamilyEnglish;
  final Color textColor;
  final Color backgroundColor;
  final bool hasBorder;
  final Color borderColor;
  final double borderWidth;
  final bool hasShadow;
  final Color shadowColor;
  final double shadowBlur;
  final Offset shadowOffset;
  final double backgroundOpacity;

  final FontWeight fontWeightChinese;
  final FontWeight fontWeightEnglish;
  final bool isItalic;
  final bool isUnderline;

  // Helper getter for backward compatibility or simple UI
  bool get isBold => fontWeightChinese.index >= FontWeight.bold.index || fontWeightEnglish.index >= FontWeight.bold.index;

  // Backward compatibility getter
  String get fontFamily => fontFamilyChinese;
  FontWeight get fontWeight => fontWeightChinese;

  const SubtitleTextStyle({
    this.fontFamilyChinese = 'MiSans',
    this.fontFamilyEnglish = 'Comic Relief',
    this.textColor = Colors.white,
    this.backgroundColor = Colors.black,
    this.hasBorder = true,
    this.borderColor = Colors.black,
    this.borderWidth = 5.5,
    this.hasShadow = true,
    this.shadowColor = Colors.black,
    this.shadowBlur = 2.8,
    this.shadowOffset = const Offset(3.7, 3.7),
    this.backgroundOpacity = 0.85,
    this.fontWeightChinese = FontWeight.w600,
    this.fontWeightEnglish = FontWeight.bold,
    this.isItalic = false,
    this.isUnderline = false,
  });

  SubtitleTextStyle copyWith({
    String? fontFamily, // Sets both
    String? fontFamilyChinese,
    String? fontFamilyEnglish,
    Color? textColor,
    Color? backgroundColor,
    bool? hasBorder,
    Color? borderColor,
    double? borderWidth,
    bool? hasShadow,
    Color? shadowColor,
    double? shadowBlur,
    Offset? shadowOffset,
    double? backgroundOpacity,
    FontWeight? fontWeight, // Sets both
    FontWeight? fontWeightChinese,
    FontWeight? fontWeightEnglish,
    bool? isBold, // kept for convenience, maps to fontWeight (sets both to bold/normal)
    bool? isItalic,
    bool? isUnderline,
  }) {
    // Logic: if specific weights passed, use them.
    // If generic fontWeight passed, use it for both.
    // If isBold passed, override both.

    FontWeight newWeightChinese = fontWeightChinese ?? (fontWeight ?? this.fontWeightChinese);
    FontWeight newWeightEnglish = fontWeightEnglish ?? (fontWeight ?? this.fontWeightEnglish);

    if (isBold != null) {
      newWeightChinese = isBold ? FontWeight.bold : FontWeight.normal;
      newWeightEnglish = isBold ? FontWeight.bold : FontWeight.normal;
    }

    return SubtitleTextStyle(
      fontFamilyChinese: fontFamilyChinese ?? fontFamily ?? this.fontFamilyChinese,
      fontFamilyEnglish: fontFamilyEnglish ?? fontFamily ?? this.fontFamilyEnglish,
      textColor: textColor ?? this.textColor,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      hasBorder: hasBorder ?? this.hasBorder,
      borderColor: borderColor ?? this.borderColor,
      borderWidth: borderWidth ?? this.borderWidth,
      hasShadow: hasShadow ?? this.hasShadow,
      shadowColor: shadowColor ?? this.shadowColor,
      shadowBlur: shadowBlur ?? this.shadowBlur,
      shadowOffset: shadowOffset ?? this.shadowOffset,
      backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
      fontWeightChinese: newWeightChinese,
      fontWeightEnglish: newWeightEnglish,
      isItalic: isItalic ?? this.isItalic,
      isUnderline: isUnderline ?? this.isUnderline,
    );
  }

  // Helper to resolve font family name to actual font family string
  String? _resolveFontFamily(String familyName) {
    switch (familyName) {
      case 'Sans Serif': return 'Arial';
      case 'Serif': return 'Times New Roman';
      case 'Monospace': return 'Courier New';
      case 'Cursive': return 'Comic Sans MS';
      case 'OPPO Sans 4.0': return 'OPPO Sans 4.0';
      case '方正黑体': return '方正黑体';
      case 'MiSans': return 'MiSans';
      case 'Noto Serif CJK SC': return 'Noto Serif CJK SC';
      case 'Swei Gothic CJK SC': return 'Swei Gothic CJK SC';
      case '方正楷体': return '方正楷体';
      case 'Comic Relief': return 'Comic Relief';
      case 'Roboto': return 'Roboto';
      case 'System':
      default:
        return null; // Default system font
    }
  }

  // Helper to get TextStyle with specific font family override
  TextStyle getTextStyle({String? overrideFontFamily, double? fontSize, double? letterSpacing}) {
    final family = _resolveFontFamily(overrideFontFamily ?? fontFamilyChinese);

    // Determine which weight to use based on family
    FontWeight weight;
    if (overrideFontFamily == fontFamilyEnglish) {
       weight = fontWeightEnglish;
    } else {
       weight = fontWeightChinese;
    }

    return TextStyle(
      fontSize: fontSize,
      fontFamily: family,
      color: textColor,
      fontWeight: weight,
      fontStyle: isItalic ? FontStyle.italic : FontStyle.normal,
      decoration: isUnderline ? TextDecoration.underline : TextDecoration.none,
      letterSpacing: letterSpacing ?? 0,
    );
  }

  // JSON Serialization
  Map<String, dynamic> toJson() {
    return {
      'fontFamilyChinese': fontFamilyChinese,
      'fontFamilyEnglish': fontFamilyEnglish,
      'textColor': textColor.toARGB32(),
      'backgroundColor': backgroundColor.toARGB32(),
      'hasBorder': hasBorder,
      'borderColor': borderColor.toARGB32(),
      'borderWidth': borderWidth,
      'hasShadow': hasShadow,
      'shadowColor': shadowColor.toARGB32(),
      'shadowBlur': shadowBlur,
      'shadowOffsetDx': shadowOffset.dx,
      'shadowOffsetDy': shadowOffset.dy,
      'backgroundOpacity': backgroundOpacity,
      'fontWeightChinese': fontWeightChinese.index,
      'fontWeightEnglish': fontWeightEnglish.index,
      'isItalic': isItalic,
      'isUnderline': isUnderline,
    };
  }

  factory SubtitleTextStyle.fromJson(Map<String, dynamic> json) {
    // Handle FontWeight index (0-8) mapping to values
    // Support legacy "fontWeight" field for backward compatibility
    final legacyWeightIndex = json['fontWeight'] as int?;
    final legacyWeight = legacyWeightIndex != null
        ? (FontWeight.values.length > legacyWeightIndex ? FontWeight.values[legacyWeightIndex] : FontWeight.normal)
        : null;

    final wChineseIndex = json['fontWeightChinese'] as int? ?? 3;
    final wEnglishIndex = json['fontWeightEnglish'] as int? ?? 3;

    final fwChinese = legacyWeight ?? (FontWeight.values.length > wChineseIndex ? FontWeight.values[wChineseIndex] : FontWeight.normal);
    final fwEnglish = legacyWeight ?? (FontWeight.values.length > wEnglishIndex ? FontWeight.values[wEnglishIndex] : FontWeight.normal);

    return SubtitleTextStyle(
      fontFamilyChinese: json['fontFamilyChinese'] as String? ?? 'System',
      fontFamilyEnglish: json['fontFamilyEnglish'] as String? ?? 'System',
      textColor: Color(json['textColor'] as int? ?? Colors.white.toARGB32()),
      backgroundColor: Color(json['backgroundColor'] as int? ?? Colors.black54.toARGB32()),
      hasBorder: json['hasBorder'] as bool? ?? true,
      borderColor: Color(json['borderColor'] as int? ?? Colors.black.toARGB32()),
      borderWidth: (json['borderWidth'] as num?)?.toDouble() ?? 3.0,
      hasShadow: json['hasShadow'] as bool? ?? true,
      shadowColor: Color(json['shadowColor'] as int? ?? Colors.black.toARGB32()),
      shadowBlur: (json['shadowBlur'] as num?)?.toDouble() ?? 2.0,
      shadowOffset: Offset(
        (json['shadowOffsetDx'] as num?)?.toDouble() ?? 1.0,
        (json['shadowOffsetDy'] as num?)?.toDouble() ?? 1.0,
      ),
      backgroundOpacity: (json['backgroundOpacity'] as num?)?.toDouble() ?? 0.5,
      fontWeightChinese: fwChinese,
      fontWeightEnglish: fwEnglish,
      isItalic: json['isItalic'] as bool? ?? false,
      isUnderline: json['isUnderline'] as bool? ?? false,
    );
  }
}

/// 字幕布局样式 - 横竖屏独立
/// 包含字体大小、行间距、字间距等布局属性
class SubtitleLayoutStyle {
  final double fontSize;
  final double? secondaryFontSize;
  final double lineSpacing;
  final double letterSpacing;

  const SubtitleLayoutStyle({
    this.fontSize = 39.0,
    this.secondaryFontSize = 28.0,
    this.lineSpacing = 0.0,
    this.letterSpacing = 0.0,
  });

  SubtitleLayoutStyle copyWith({
    double? fontSize,
    double? secondaryFontSize,
    double? lineSpacing,
    double? letterSpacing,
  }) {
    return SubtitleLayoutStyle(
      fontSize: fontSize ?? this.fontSize,
      secondaryFontSize: secondaryFontSize ?? this.secondaryFontSize,
      lineSpacing: lineSpacing ?? this.lineSpacing,
      letterSpacing: letterSpacing ?? this.letterSpacing,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'fontSize': fontSize,
      'secondaryFontSize': secondaryFontSize,
      'lineSpacing': lineSpacing,
      'letterSpacing': letterSpacing,
    };
  }

  factory SubtitleLayoutStyle.fromJson(Map<String, dynamic> json) {
    return SubtitleLayoutStyle(
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 39.0,
      secondaryFontSize: (json['secondaryFontSize'] as num?)?.toDouble(),
      lineSpacing: (json['lineSpacing'] as num?)?.toDouble() ?? 0.0,
      letterSpacing: (json['letterSpacing'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

/// 完整字幕样式 - 组合文字样式和布局样式
/// 用于向后兼容
class SubtitleStyle {
  final SubtitleTextStyle textStyle;
  final SubtitleLayoutStyle layoutStyle;

  // 便捷访问器 - 文字样式属性
  String get fontFamilyChinese => textStyle.fontFamilyChinese;
  String get fontFamilyEnglish => textStyle.fontFamilyEnglish;
  Color get textColor => textStyle.textColor;
  Color get backgroundColor => textStyle.backgroundColor;
  bool get hasBorder => textStyle.hasBorder;
  Color get borderColor => textStyle.borderColor;
  double get borderWidth => textStyle.borderWidth;
  bool get hasShadow => textStyle.hasShadow;
  Color get shadowColor => textStyle.shadowColor;
  double get shadowBlur => textStyle.shadowBlur;
  Offset get shadowOffset => textStyle.shadowOffset;
  double get backgroundOpacity => textStyle.backgroundOpacity;
  FontWeight get fontWeightChinese => textStyle.fontWeightChinese;
  FontWeight get fontWeightEnglish => textStyle.fontWeightEnglish;
  bool get isItalic => textStyle.isItalic;
  bool get isUnderline => textStyle.isUnderline;
  bool get isBold => textStyle.isBold;
  String get fontFamily => textStyle.fontFamily;
  FontWeight get fontWeight => textStyle.fontWeight;

  // 便捷访问器 - 布局样式属性
  double get fontSize => layoutStyle.fontSize;
  double? get secondaryFontSize => layoutStyle.secondaryFontSize;
  double get lineSpacing => layoutStyle.lineSpacing;
  double get letterSpacing => layoutStyle.letterSpacing;

  const SubtitleStyle({
    this.textStyle = const SubtitleTextStyle(),
    this.layoutStyle = const SubtitleLayoutStyle(),
  });

  SubtitleStyle copyWith({
    SubtitleTextStyle? textStyle,
    SubtitleLayoutStyle? layoutStyle,
    // 向后兼容的便捷参数
    double? fontSize,
    double? secondaryFontSize,
    double? lineSpacing,
    String? fontFamily,
    String? fontFamilyChinese,
    String? fontFamilyEnglish,
    Color? textColor,
    Color? backgroundColor,
    bool? hasBorder,
    Color? borderColor,
    double? borderWidth,
    bool? hasShadow,
    Color? shadowColor,
    double? shadowBlur,
    Offset? shadowOffset,
    double? backgroundOpacity,
    double? letterSpacing,
    FontWeight? fontWeight,
    FontWeight? fontWeightChinese,
    FontWeight? fontWeightEnglish,
    bool? isBold,
    bool? isItalic,
    bool? isUnderline,
  }) {
    return SubtitleStyle(
      textStyle: textStyle ?? this.textStyle.copyWith(
        fontFamily: fontFamily,
        fontFamilyChinese: fontFamilyChinese,
        fontFamilyEnglish: fontFamilyEnglish,
        textColor: textColor,
        backgroundColor: backgroundColor,
        hasBorder: hasBorder,
        borderColor: borderColor,
        borderWidth: borderWidth,
        hasShadow: hasShadow,
        shadowColor: shadowColor,
        shadowBlur: shadowBlur,
        shadowOffset: shadowOffset,
        backgroundOpacity: backgroundOpacity,
        fontWeight: fontWeight,
        fontWeightChinese: fontWeightChinese,
        fontWeightEnglish: fontWeightEnglish,
        isBold: isBold,
        isItalic: isItalic,
        isUnderline: isUnderline,
      ),
      layoutStyle: layoutStyle ?? this.layoutStyle.copyWith(
        fontSize: fontSize,
        secondaryFontSize: secondaryFontSize,
        lineSpacing: lineSpacing,
        letterSpacing: letterSpacing,
      ),
    );
  }

  // Helper to get TextStyle with specific font family override
  TextStyle getTextStyle({String? overrideFontFamily}) {
    return textStyle.getTextStyle(
      overrideFontFamily: overrideFontFamily,
      fontSize: layoutStyle.fontSize,
      letterSpacing: layoutStyle.letterSpacing,
    );
  }

  // JSON Serialization - 保持向后兼容
  Map<String, dynamic> toJson() {
    return {
      ...textStyle.toJson(),
      ...layoutStyle.toJson(),
    };
  }

  factory SubtitleStyle.fromJson(Map<String, dynamic> json) {
    return SubtitleStyle(
      textStyle: SubtitleTextStyle.fromJson(json),
      layoutStyle: SubtitleLayoutStyle.fromJson(json),
    );
  }
}
