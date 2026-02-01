import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/subtitle_style.dart';
import '../services/settings_service.dart';

/// 字幕设置面板
/// 文字样式（字体、颜色、描边、阴影等）会同步到横竖屏
/// 布局样式（字号、行间距、字间距等）只影响当前方向
class SubtitleSettingsSheet extends StatelessWidget {
  /// 当前完整样式（包含文字样式和布局样式）
  final SubtitleStyle style;

  /// 是否是横屏模式
  final bool isLandscape;

  /// 是否是音频模式
  final bool isAudio;

  /// 当文字样式改变时的回调
  final ValueChanged<SubtitleTextStyle>? onTextStyleChanged;

  /// 当布局样式改变时的回调
  final ValueChanged<SubtitleLayoutStyle>? onLayoutStyleChanged;

  /// 当完整样式改变时的回调（向后兼容）
  final ValueChanged<SubtitleStyle>? onStyleChanged;

  final VoidCallback onClose;
  final VoidCallback? onBack;

  const SubtitleSettingsSheet({
    super.key,
    required this.style,
    this.isLandscape = true,
    this.isAudio = false,
    this.onTextStyleChanged,
    this.onLayoutStyleChanged,
    this.onStyleChanged,
    required this.onClose,
    this.onBack,
  });

  void _showGhostModeHelp(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2C),
        title: const Text("幽灵模式说明", style: TextStyle(color: Colors.white)),
        content: const Text(
          "开启后，当字幕边栏处于打开状态时，悬浮字幕可以在屏幕上自由拖动。\n"
          "该模式适合在对照阅读或需要腾出字幕区域时使用。",
          style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("我知道了", style: TextStyle(color: Colors.blueAccent)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 600;
    final paddingValue = isSmallScreen ? 6.0 : 20.0;

    // Adaptive sizes
    final double titleFontSize = isSmallScreen ? 11 : 12;

    final fonts = ['System', 'OPPO Sans 4.0', '方正黑体', 'MiSans', 'Noto Serif CJK SC', 'Swei Gothic CJK SC', '方正楷体', 'Comic Relief', 'Roboto'];

    return Container(
      color: const Color(0xFF1E1E1E), // 深色背景
      child: Column(
        children: [
          // Header
          Container(
            padding: EdgeInsets.fromLTRB(paddingValue, paddingValue, 8, paddingValue / 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (onBack != null)
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white70, size: 18),
                        onPressed: onBack,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        tooltip: "返回",
                      ),
                    if (onBack != null) const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        isAudio ? "音频字幕样式" : "视频字幕样式",
                        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70, size: 18),
                      onPressed: onClose,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      tooltip: "关闭",
                    ),
                  ],
                ),
                if (!isAudio)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Consumer<SettingsService>(
                      builder: (context, settings, child) {
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (!isSmallScreen)
                              const Text("幽灵模式", style: TextStyle(color: Colors.white70, fontSize: 12)),
                            if (!isSmallScreen) const SizedBox(width: 6),
                            Switch(
                              value: settings.isGhostModeEnabled,
                              onChanged: (val) => settings.updateSetting('isGhostModeEnabled', val),
                              activeThumbColor: Colors.blueAccent,
                            ),
                            IconButton(
                              icon: const Icon(Icons.help_outline, color: Colors.white70, size: 18),
                              onPressed: () => _showGhostModeHelp(context),
                              tooltip: "幽灵模式说明",
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          const Divider(color: Colors.white10, height: 1),

          Expanded(
            child: ListView(
              padding: EdgeInsets.symmetric(horizontal: paddingValue, vertical: 8),
              children: [
                // Preview Section
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: style.backgroundColor.withValues(alpha: style.backgroundOpacity),
                    borderRadius: BorderRadius.circular(8),
                    border: style.hasBorder ? Border.all(color: style.borderColor, width: style.borderWidth) : null,
                  ),
                  child: Center(
                    child: RichText(
                      textAlign: TextAlign.center,
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: "预览 Preview: ",
                            style: style.textStyle.getTextStyle(fontSize: isSmallScreen ? 12 : 14, letterSpacing: 0).copyWith(color: Colors.white70)
                          ),
                          TextSpan(
                            text: "中文字体演示 ",
                            style: style.textStyle.getTextStyle(
                              overrideFontFamily: style.fontFamilyChinese,
                              fontSize: style.fontSize * (isSmallScreen ? 0.3 : 0.4),
                              letterSpacing: style.letterSpacing,
                            )
                          ),
                          TextSpan(
                            text: "English Font Demo 123",
                            style: style.textStyle.getTextStyle(
                              overrideFontFamily: style.fontFamilyEnglish,
                              fontSize: style.fontSize * (isSmallScreen ? 0.3 : 0.4),
                              letterSpacing: style.letterSpacing,
                            )
                          ),
                        ]
                      ),
                    ),
                  ),
                ),

                // 1. Layout Settings (Size & Spacing) - 仅影响当前方向
                _buildSectionTitle(context, "${isLandscape ? '横屏' : '竖屏'}布局 (仅当前方向)", Icons.format_size, color: Colors.orangeAccent),
                // Main Font Size
                Row(
                  children: [
                    Text("主字号", style: TextStyle(color: Colors.white60, fontSize: titleFontSize)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildSlider(
                        context,
                        value: style.fontSize,
                        min: 10,
                        max: 100,
                        label: style.fontSize.toInt().toString(),
                        onChanged: (val) => _updateLayoutStyle(style.layoutStyle.copyWith(fontSize: val)),
                      ),
                    ),
                  ],
                ),
                // Secondary Font Size
                Row(
                  children: [
                    Text("副字号", style: TextStyle(color: Colors.white60, fontSize: titleFontSize)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildSlider(
                        context,
                        value: style.secondaryFontSize ?? style.fontSize,
                        min: 10,
                        max: 100,
                        label: (style.secondaryFontSize ?? style.fontSize).toInt().toString(),
                        onChanged: (val) => _updateLayoutStyle(style.layoutStyle.copyWith(secondaryFontSize: val)),
                      ),
                    ),
                  ],
                ),
                // Line Spacing
                Row(
                  children: [
                    Text("行间距", style: TextStyle(color: Colors.white60, fontSize: titleFontSize)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildSlider(
                        context,
                        value: style.lineSpacing,
                        min: -10,
                        max: 100,
                        label: style.lineSpacing.toInt().toString(),
                        onChanged: (val) => _updateLayoutStyle(style.layoutStyle.copyWith(lineSpacing: val)),
                      ),
                    ),
                  ],
                ),
                // Letter Spacing
                Row(
                  children: [
                    Text("字间距", style: TextStyle(color: Colors.white60, fontSize: titleFontSize)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildSlider(
                        context,
                        value: style.letterSpacing,
                        min: -5,
                        max: 20,
                        label: style.letterSpacing.toStringAsFixed(1),
                        onChanged: (val) => _updateLayoutStyle(style.layoutStyle.copyWith(letterSpacing: val)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                if (!isAudio) ...[
                  _buildSectionTitle(context, "幽灵模式字幕", Icons.visibility),
                  Consumer<SettingsService>(
                    builder: (context, settings, child) {
                      return Column(
                        children: [
                          Row(
                            children: [
                              Text("字幕大小", style: TextStyle(color: Colors.white60, fontSize: titleFontSize)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _buildSlider(
                                  context,
                                  value: settings.ghostSubtitleFontSize,
                                  min: 10,
                                  max: 100,
                                  label: settings.ghostSubtitleFontSize.toInt().toString(),
                                  onChanged: (val) => settings.updateSetting('ghostSubtitleFontSize', val),
                                ),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              Text("字间距", style: TextStyle(color: Colors.white60, fontSize: titleFontSize)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _buildSlider(
                                  context,
                                  value: settings.ghostSubtitleLetterSpacing,
                                  min: -5,
                                  max: 20,
                                  label: settings.ghostSubtitleLetterSpacing.toStringAsFixed(1),
                                  onChanged: (val) => settings.updateSetting('ghostSubtitleLetterSpacing', val),
                                ),
                              ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                ],

                const Divider(color: Colors.white10, height: 24),

                // 2. Text Style Settings - 同步到横竖屏
                _buildSectionTitle(context, "文字样式 (横竖屏同步)", Icons.text_fields, color: Colors.greenAccent),

                // 2. Font Family
                _buildSectionTitle(context, "中文字体 (Chinese Font)", Icons.font_download),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: fonts.map((f) {
                    final isSelected = style.fontFamilyChinese == f || (f == 'System' && style.fontFamilyChinese == 'System');
                    return _buildCompactChip(
                      context,
                      label: f,
                      isSelected: isSelected,
                      onTap: () => _updateTextStyle(style.textStyle.copyWith(fontFamilyChinese: f)),
                    );
                  }).toList(),
                ),

                // Chinese Weight Selector (if applicable)
                if (_hasMultipleWeights(style.fontFamilyChinese)) ...[
                  const SizedBox(height: 12),
                  _buildSectionTitle(context, "中文字重 (Chinese Weight)", Icons.line_weight),
                  _buildWeightSelector(
                    context,
                    fontFamily: style.fontFamilyChinese,
                    currentWeight: style.fontWeightChinese,
                    onChanged: (w) => _updateTextStyle(style.textStyle.copyWith(fontWeightChinese: w)),
                  ),
                ] else ...[
                   const SizedBox(height: 8),
                   Row(
                     children: [
                        const Text("粗体 (Bold)", style: TextStyle(color: Colors.white70, fontSize: 12)),
                        const Spacer(),
                        Switch(
                          value: style.fontWeightChinese == FontWeight.bold,
                          onChanged: (val) => _updateTextStyle(style.textStyle.copyWith(fontWeightChinese: val ? FontWeight.bold : FontWeight.normal)),
                          activeThumbColor: Colors.blueAccent,
                        )
                     ],
                   ),
                ],

                const SizedBox(height: 16),
                _buildSectionTitle(context, "英文字体 (English Font)", Icons.abc),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: fonts.map((f) {
                    final isSelected = style.fontFamilyEnglish == f || (f == 'System' && style.fontFamilyEnglish == 'System');
                    return _buildCompactChip(
                      context,
                      label: f,
                      isSelected: isSelected,
                      onTap: () => _updateTextStyle(style.textStyle.copyWith(fontFamilyEnglish: f)),
                    );
                  }).toList(),
                ),

                // English Weight Selector (if applicable)
                if (_hasMultipleWeights(style.fontFamilyEnglish)) ...[
                  const SizedBox(height: 12),
                  _buildSectionTitle(context, "英文字重 (English Weight)", Icons.line_weight),
                  _buildWeightSelector(
                    context,
                    fontFamily: style.fontFamilyEnglish,
                    currentWeight: style.fontWeightEnglish,
                    onChanged: (w) => _updateTextStyle(style.textStyle.copyWith(fontWeightEnglish: w)),
                  ),
                ] else ...[
                   const SizedBox(height: 8),
                   Row(
                     children: [
                        const Text("粗体 (Bold)", style: TextStyle(color: Colors.white70, fontSize: 12)),
                        const Spacer(),
                        Switch(
                          value: style.fontWeightEnglish == FontWeight.bold,
                          onChanged: (val) => _updateTextStyle(style.textStyle.copyWith(fontWeightEnglish: val ? FontWeight.bold : FontWeight.normal)),
                          activeThumbColor: Colors.blueAccent,
                        )
                     ],
                   ),
                ],

                const SizedBox(height: 16),

                // 3. Font Style
                _buildSectionTitle(context, "样式", Icons.format_paint),
                Row(
                  children: [
                    _buildStyleToggle(
                      context,
                      icon: Icons.format_italic,
                      isActive: style.isItalic,
                      onTap: () => _updateTextStyle(style.textStyle.copyWith(isItalic: !style.isItalic)),
                    ),
                    const SizedBox(width: 8),
                    _buildStyleToggle(
                      context,
                      icon: Icons.format_underlined,
                      isActive: style.isUnderline,
                      onTap: () => _updateTextStyle(style.textStyle.copyWith(isUnderline: !style.isUnderline)),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // 4. Text Color
                _buildSectionTitle(context, "文本颜色", Icons.color_lens),
                _buildColorPicker(
                  context,
                  selectedColor: style.textColor,
                  onColorChanged: (c) => _updateTextStyle(style.textStyle.copyWith(textColor: c)),
                ),
                const SizedBox(height: 16),

                // 5. Background
                _buildSectionTitle(context, "背景颜色", Icons.format_color_fill),
                _buildColorPicker(
                  context,
                  selectedColor: style.backgroundColor.withValues(alpha: 1.0),
                  onColorChanged: (c) => _updateTextStyle(style.textStyle.copyWith(
                    backgroundColor: c.withValues(alpha: style.backgroundOpacity),
                  )),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text("透明度", style: TextStyle(color: Colors.white60, fontSize: titleFontSize)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildSlider(
                        context,
                        value: style.backgroundOpacity,
                        min: 0,
                        max: 1,
                        label: "${(style.backgroundOpacity * 100).round()}%",
                        onChanged: (val) => _updateTextStyle(style.textStyle.copyWith(
                          backgroundOpacity: val,
                          backgroundColor: style.backgroundColor.withValues(alpha: val),
                        )),
                      ),
                    ),
                  ],
                ),

                const Divider(color: Colors.white10, height: 24),

                // 6. Border & Shadow
                _buildSwitchSection(
                  context,
                  "描边 (Outline)",
                  style.hasBorder,
                  (val) => _updateTextStyle(style.textStyle.copyWith(hasBorder: val)),
                  children: [
                    _buildColorPicker(
                      context,
                      selectedColor: style.borderColor,
                      onColorChanged: (c) => _updateTextStyle(style.textStyle.copyWith(borderColor: c)),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text("宽度", style: TextStyle(color: Colors.white60, fontSize: titleFontSize)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _buildSlider(
                            context,
                            value: style.borderWidth,
                            min: 0,
                            max: 10,
                            label: style.borderWidth.toStringAsFixed(1),
                            onChanged: (val) => _updateTextStyle(style.textStyle.copyWith(borderWidth: val)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                _buildSwitchSection(
                  context,
                  "阴影 (Shadow)",
                  style.hasShadow,
                  (val) => _updateTextStyle(style.textStyle.copyWith(hasShadow: val)),
                  children: [
                    _buildColorPicker(
                      context,
                      selectedColor: style.shadowColor,
                      onColorChanged: (c) => _updateTextStyle(style.textStyle.copyWith(shadowColor: c)),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text("模糊", style: TextStyle(color: Colors.white60, fontSize: titleFontSize)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _buildSlider(
                            context,
                            value: style.shadowBlur,
                            min: 0,
                            max: 10,
                            label: style.shadowBlur.toStringAsFixed(1),
                            onChanged: (val) => _updateTextStyle(style.textStyle.copyWith(shadowBlur: val)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text("距离", style: TextStyle(color: Colors.white60, fontSize: titleFontSize)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _buildSlider(
                            context,
                            value: style.shadowOffset.dx,
                            min: 0,
                            max: 10,
                            label: style.shadowOffset.dx.toStringAsFixed(1),
                            onChanged: (val) => _updateTextStyle(style.textStyle.copyWith(
                              shadowOffset: Offset(val, val),
                            )),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),

                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 更新文字样式 - 会同步到横竖屏
  void _updateTextStyle(SubtitleTextStyle newTextStyle) {
    onTextStyleChanged?.call(newTextStyle);
    // 同时触发完整样式回调以保持兼容
    onStyleChanged?.call(SubtitleStyle(
      textStyle: newTextStyle,
      layoutStyle: style.layoutStyle,
    ));
  }

  /// 更新布局样式 - 只影响当前方向
  void _updateLayoutStyle(SubtitleLayoutStyle newLayoutStyle) {
    onLayoutStyleChanged?.call(newLayoutStyle);
    // 同时触发完整样式回调以保持兼容
    onStyleChanged?.call(SubtitleStyle(
      textStyle: style.textStyle,
      layoutStyle: newLayoutStyle,
    ));
  }

  bool _hasMultipleWeights(String fontFamily) {
    if (fontFamily == 'MiSans') return true;
    if (fontFamily == 'Roboto') return true;
    // Comic Relief has Regular and Bold (implied), but user might want to choose between them explicitly if we treat them as weights.
    // However, our UI strategy is: If >2 weights, use Slider. If 2 weights (Normal/Bold), use Toggle.
    // So _hasMultipleWeights returns true ONLY for >2 weights (Slider UI).
    // Actually, let's keep it simple: MiSans is the only one needing a slider.
    return false;
  }

  Widget _buildWeightSelector(BuildContext context, {
    required String fontFamily,
    required FontWeight currentWeight,
    required ValueChanged<FontWeight> onChanged,
  }) {
    List<FontWeight> weights;
    List<String> labels;

    if (fontFamily == 'MiSans') {
      weights = [
        FontWeight.w100,
        FontWeight.w200,
        FontWeight.w300,
        FontWeight.w400,
        FontWeight.w500,
        FontWeight.w600,
        FontWeight.w700,
        FontWeight.w900,
      ];
      labels = ["Thin", "X-Light", "Light", "Regular", "Medium", "SemiBold", "Bold", "Heavy"];
    } else if (fontFamily == 'Roboto') {
      weights = [
        FontWeight.w100,
        FontWeight.w200,
        FontWeight.w300,
        FontWeight.w400,
        FontWeight.w500,
        FontWeight.w600,
        FontWeight.w700,
        FontWeight.w800,
        FontWeight.w900,
      ];
      labels = ["Thin", "ExtraLight", "Light", "Regular", "Medium", "SemiBold", "Bold", "ExtraBold", "Black"];
    } else {
      // Fallback (shouldn't happen given logic)
      weights = [FontWeight.normal, FontWeight.bold];
      labels = ["Regular", "Bold"];
    }

    // Find current index (approximate match)
    int currentIndex = -1;
    // Try exact match
    currentIndex = weights.indexOf(currentWeight);

    // If no exact match, try to find closest
    if (currentIndex == -1) {
       // ... logic to find closest ...
       // For now, default to Regular (w400) index
       if (fontFamily == 'MiSans') {
         currentIndex = 3;
       } else if (fontFamily == 'Roboto') {
         currentIndex = 3;
       } else {
         currentIndex = 0;
       }
    }

    return Column(
      children: [
        SizedBox(
          height: 30,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              activeTickMarkColor: Colors.blueAccent,
              inactiveTickMarkColor: Colors.white24,
            ),
            child: Slider(
              value: currentIndex.toDouble(),
              min: 0,
              max: (weights.length - 1).toDouble(),
              divisions: weights.length - 1,
              activeColor: Colors.blueAccent,
              onChanged: (val) {
                onChanged(weights[val.round()]);
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(labels[0], style: const TextStyle(color: Colors.white38, fontSize: 10)),
              Text(labels[currentIndex], style: const TextStyle(color: Colors.blueAccent, fontSize: 11, fontWeight: FontWeight.bold)),
              Text(labels.last, style: const TextStyle(color: Colors.white38, fontSize: 10)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSectionTitle(BuildContext context, String text, IconData icon, {Color? color}) {
    final isSmallScreen = MediaQuery.of(context).size.width < 600;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: isSmallScreen ? 12 : 14, color: (color ?? Colors.blueAccent).withValues(alpha: 0.8)),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(color: color ?? Colors.white70, fontSize: isSmallScreen ? 11 : 12, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _buildSlider(BuildContext context, {
    required double value,
    required double min,
    required double max,
    required String label,
    required ValueChanged<double> onChanged,
  }) {
    final isSmallScreen = MediaQuery.of(context).size.width < 600;
    return SizedBox(
      height: isSmallScreen ? 24 : 30,
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 2,
          thumbShape: RoundSliderThumbShape(enabledThumbRadius: isSmallScreen ? 4 : 6),
          overlayShape: RoundSliderOverlayShape(overlayRadius: isSmallScreen ? 8 : 12),
          valueIndicatorShape: const PaddleSliderValueIndicatorShape(),
          valueIndicatorTextStyle: TextStyle(fontSize: isSmallScreen ? 10 : 12),
        ),
        child: Slider(
          value: value,
          min: min,
          max: max,
          divisions: 100,
          label: label,
          activeColor: Colors.blueAccent,
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildCompactChip(BuildContext context, {required String label, required bool isSelected, required VoidCallback onTap}) {
    final isSmallScreen = MediaQuery.of(context).size.width < 600;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: isSmallScreen ? 8 : 12, vertical: isSmallScreen ? 4 : 6),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blueAccent : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: isSelected ? Colors.blueAccent : Colors.white10),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white70,
            fontSize: isSmallScreen ? 11 : 12,
            fontWeight: isSelected ? FontWeight.w500 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildStyleToggle(BuildContext context, {
    required IconData icon,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    final isSmallScreen = MediaQuery.of(context).size.width < 600;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(isSmallScreen ? 6 : 8),
        decoration: BoxDecoration(
          color: isActive ? Colors.blueAccent : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: isActive ? Colors.blueAccent : Colors.white10),
        ),
        child: Icon(icon, color: isActive ? Colors.white : Colors.white60, size: isSmallScreen ? 16 : 18),
      ),
    );
  }

  Widget _buildColorPicker(BuildContext context, {required Color selectedColor, required ValueChanged<Color> onColorChanged}) {
    final isSmallScreen = MediaQuery.of(context).size.width < 600;
    final colors = [
      Colors.white, Colors.black, Colors.redAccent, Colors.blueAccent,
      Colors.greenAccent, Colors.amberAccent, Colors.cyanAccent, Colors.purpleAccent,
      Colors.grey, Colors.brown,
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: colors.map((color) {
          final isSelected = color.toARGB32() == selectedColor.toARGB32();
          return GestureDetector(
            onTap: () => onColorChanged(color),
            child: Container(
              margin: EdgeInsets.only(right: isSmallScreen ? 8 : 12),
              width: isSmallScreen ? 24 : 28,
              height: isSmallScreen ? 24 : 28,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected ? Colors.white : Colors.white24,
                  width: isSelected ? 2 : 1,
                ),
                boxShadow: isSelected ? [
                  BoxShadow(color: Colors.white.withValues(alpha: 0.3), blurRadius: 4, spreadRadius: 1)
                ] : null,
              ),
              child: isSelected
                  ? Icon(Icons.check, size: isSmallScreen ? 14 : 16, color: color.computeLuminance() > 0.5 ? Colors.black : Colors.white)
                  : null,
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildSwitchSection(BuildContext context, String title, bool value, ValueChanged<bool> onChanged, {required List<Widget> children}) {
    final isSmallScreen = MediaQuery.of(context).size.width < 600;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title, style: TextStyle(color: Colors.white70, fontSize: isSmallScreen ? 12 : 13, fontWeight: FontWeight.w500)),
            SizedBox(
              height: 24,
              child: Transform.scale(
                scale: isSmallScreen ? 0.8 : 1.0,
                child: Switch(
                  value: value,
                  onChanged: onChanged,
                  activeThumbColor: Colors.blueAccent,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
        ),
        if (value) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(children: children),
          ),
        ],
      ],
    );
  }
}
