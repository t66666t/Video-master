import 'package:flutter/material.dart';

class SubtitleStyle {
  final double fontSize;
  final double? secondaryFontSize; // Nullable, falls back to fontSize if not set
  final double lineSpacing; // Vertical space between lines
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

  const SubtitleStyle({
    this.fontSize = 39.0,
    this.secondaryFontSize = 28.0,
    this.lineSpacing = 0.0,
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

  SubtitleStyle copyWith({
    double? fontSize,
    double? secondaryFontSize,
    double? lineSpacing,
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

    return SubtitleStyle(
      fontSize: fontSize ?? this.fontSize,
      secondaryFontSize: secondaryFontSize ?? this.secondaryFontSize,
      lineSpacing: lineSpacing ?? this.lineSpacing,
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
      case 'System':
      default:
        return null; // Default system font
    }
  }

  // Helper to get TextStyle with specific font family override
  TextStyle getTextStyle({String? overrideFontFamily}) {
    final family = _resolveFontFamily(overrideFontFamily ?? fontFamilyChinese);
    
    // Determine which weight to use based on family
    // This is a bit tricky since we don't know if we are rendering Chinese or English just by font family name alone
    // But usually overrideFontFamily is passed by the renderer which knows the zone.
    
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
    );
  }

  // JSON Serialization
  Map<String, dynamic> toJson() {
    return {
      'fontSize': fontSize,
      'secondaryFontSize': secondaryFontSize,
      'lineSpacing': lineSpacing,
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

  factory SubtitleStyle.fromJson(Map<String, dynamic> json) {
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

    return SubtitleStyle(
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 20.0,
      secondaryFontSize: (json['secondaryFontSize'] as num?)?.toDouble(),
      lineSpacing: (json['lineSpacing'] as num?)?.toDouble() ?? 0.0,
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
