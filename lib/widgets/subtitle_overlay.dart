import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/subtitle_style.dart';

class SubtitleOverlayEntry {
  final int? index;
  final String text;
  final String? secondaryText;
  final Uint8List? image;

  const SubtitleOverlayEntry({
    this.index,
    required this.text,
    this.secondaryText,
    this.image,
  });

  bool get hasContent {
    if (image != null) return true;
    if (text.isNotEmpty) return true;
    if (secondaryText != null && secondaryText!.isNotEmpty) return true;
    return false;
  }
}

class SubtitleOverlayGroup extends StatelessWidget {
  final List<SubtitleOverlayEntry> entries;
  final SubtitleStyle style;
  final Alignment alignment;
  final VoidCallback? onLongPress;
  final bool isDragging;
  final bool isGestureOnly;
  final bool isVisualOnly;
  final double itemGap;
  final bool animateAlignment;
  final Duration alignmentDuration;
  final Curve alignmentCurve;

  const SubtitleOverlayGroup({
    super.key,
    required this.entries,
    required this.style,
    required this.alignment,
    this.onLongPress,
    this.isDragging = false,
    this.isGestureOnly = false,
    this.isVisualOnly = false,
    this.itemGap = 6.0,
    this.animateAlignment = false,
    this.alignmentDuration = const Duration(milliseconds: 300),
    this.alignmentCurve = Curves.easeOutCubic,
  });

  @override
  Widget build(BuildContext context) {
    final visibleEntries = entries.where((e) => e.hasContent).toList();
    if (visibleEntries.isEmpty && !isDragging) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        double scale = 1.0;
        if (constraints.maxHeight != double.infinity && constraints.maxHeight > 0) {
          scale = constraints.maxHeight / 720.0;
        }
        final childConstraints = BoxConstraints(
          maxWidth: constraints.maxWidth,
          maxHeight: constraints.maxHeight,
        );
        final Widget content = SingleChildScrollView(
          reverse: alignment.y >= 0,
          physics: const NeverScrollableScrollPhysics(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (int i = 0; i < visibleEntries.length; i++) ...[
                ConstrainedBox(
                  constraints: childConstraints,
                  child: SubtitleOverlay(
                    text: visibleEntries[i].text,
                    secondaryText: visibleEntries[i].secondaryText,
                    image: visibleEntries[i].image,
                    style: style,
                    onLongPress: onLongPress,
                    isDragging: isDragging,
                    isGestureOnly: isGestureOnly,
                    isVisualOnly: isVisualOnly,
                  ),
                ),
                if (i != visibleEntries.length - 1) SizedBox(height: itemGap * scale),
              ],
            ],
          ),
        );

        final Widget alignedChild = animateAlignment
            ? AnimatedAlign(
                alignment: alignment,
                duration: alignmentDuration,
                curve: alignmentCurve,
                child: content,
              )
            : Align(
                alignment: alignment,
                child: content,
              );

        return SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: ClipRect(
            child: alignedChild,
          ),
        );
      },
    );
  }
}

class SubtitleOverlay extends StatelessWidget {
  final String text; // Primary text (or all text if single file + no split)
  final String? secondaryText; // Explicit secondary text
  final Uint8List? image; // New: Support for bitmap subtitles
  final SubtitleStyle style;
  final VoidCallback? onLongPress;
  final bool isDragging;
  final bool isGestureOnly; // If true, renders transparent text but captures gestures
  final bool isVisualOnly;  // If true, renders visible text but ignores gestures

  const SubtitleOverlay({
    super.key,
    required this.text,
    this.secondaryText,
    this.image,
    this.style = const SubtitleStyle(),
    this.onLongPress,
    this.isDragging = false,
    this.isGestureOnly = false,
    this.isVisualOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty && (secondaryText == null || secondaryText!.isEmpty) && image == null && !isDragging) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        // Calculate scale relative to a reference height (e.g., 720p)
        // This ensures the subtitle size remains relative to the video size
        double scale = 1.0;
        if (constraints.maxHeight != double.infinity && constraints.maxHeight > 0) {
           scale = constraints.maxHeight / 720.0;
        }

        // Apply scale to style properties
        final scaledStyle = style.copyWith(
          fontSize: style.fontSize * scale,
          secondaryFontSize: (style.secondaryFontSize ?? style.fontSize) * scale,
          lineSpacing: style.lineSpacing * scale,
          borderWidth: style.borderWidth * scale,
          shadowBlur: style.shadowBlur * scale,
          shadowOffset: style.shadowOffset * scale,
        );
        
        // In drag mode, show placeholder if text is empty and no image
        final displayText = (text.isEmpty && image == null && isDragging) ? "字幕位置预览\nSubtitle Preview" : text;
        
        // If Gesture Only, use transparent colors
        final effectiveStyle = isGestureOnly 
            ? scaledStyle.copyWith(
                textColor: Colors.transparent,
                backgroundColor: Colors.transparent,
                borderColor: Colors.transparent,
                shadowColor: Colors.transparent,
                backgroundOpacity: 0,
              )
            : scaledStyle;

        Widget content = AnimatedScale(
          scale: isDragging ? 1.05 : 1.0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutBack,
          child: RepaintBoundary(
            child: image != null
                ? SizedBox(
                    width: constraints.maxWidth,
                    height: constraints.maxHeight,
                    child: Image.memory(
                      image!,
                      gaplessPlayback: true,
                      fit: BoxFit.contain,
                    ),
                  )
                : Container(
                    padding: EdgeInsets.symmetric(horizontal: 12 * scale, vertical: 6 * scale),
                    decoration: BoxDecoration(
                      color: effectiveStyle.backgroundColor.withValues(alpha: effectiveStyle.backgroundOpacity),
                      borderRadius: BorderRadius.circular(8 * scale),
                      border: isDragging ? Border.all(color: Colors.greenAccent, width: 2 * scale) : null,
                    ),
                    child: effectiveStyle.hasBorder
                        ? Stack(
                            children: [
                              _buildContent(displayText, effectiveStyle, isStroke: true),
                              _buildContent(displayText, effectiveStyle, isStroke: false),
                            ],
                          )
                        : _buildContent(displayText, effectiveStyle, isStroke: false),
                  ),
          ),
        );
        
        if (isVisualOnly) {
          return IgnorePointer(child: content);
        }

        return GestureDetector(
          onLongPress: onLongPress,
          behavior: HitTestBehavior.translucent,
          child: content,
        );
      }
    );
  }

  Widget _buildContent(String text, SubtitleStyle style, {required bool isStroke}) {
    // If we have explicit secondary text, we ignore the newline splitting logic for styling
    // and render primary and secondary blocks distinctly.
    if (secondaryText != null && secondaryText!.isNotEmpty) {
      List<InlineSpan> spans = [];
      
      // 1. Primary Block
      if (text.isNotEmpty) {
        // Render all lines of primary text with primary style
        final lines = text.split('\n');
        for (int i = 0; i < lines.length; i++) {
          if (i > 0) spans.add(const TextSpan(text: "\n"));
          spans.add(TextSpan(
             // Use default line height for primary
             children: _buildSpans(lines[i], style, isStroke: isStroke)
          ));
        }
      }

      // 2. Secondary Block
      if (text.isNotEmpty) spans.add(const TextSpan(text: "\n"));
      
      final secLines = secondaryText!.split('\n');
      final secFontSize = style.secondaryFontSize ?? style.fontSize;
      final secStyle = style.copyWith(fontSize: secFontSize);
      
      for (int i = 0; i < secLines.length; i++) {
        if (i > 0) spans.add(const TextSpan(text: "\n"));
        
        // Calculate height for secondary lines (same logic as before)
        double calculatedHeight = 1.2 + (style.lineSpacing / secFontSize);
        double height = calculatedHeight < 0 ? 0 : calculatedHeight;

        spans.add(TextSpan(
          style: TextStyle(height: height),
          children: _buildSpans(secLines[i], secStyle, isStroke: isStroke),
        ));
      }

      return RichText(
        textAlign: TextAlign.center,
        text: TextSpan(children: spans),
      );
    }

    // Legacy Logic (Single text source)
    // We treat it as all primary, UNLESS the caller already split it.
    // However, if the caller passed everything in `text` and `secondaryText` is null,
    // it implies "Single File Mode".
    // In this mode, we render ALL lines as PRIMARY style (per user request: "关闭则所有字母都为主字幕").
    // BUT, if "Split by Line" was enabled, the caller (VideoPlayerScreen) should have passed
    // the split text into `text` and `secondaryText` separately!
    // So if we are here, it means either:
    // 1. Split is OFF -> All text is primary.
    // 2. Split is ON but there was only one line -> Primary.
    // So we just render everything with Primary Style.
    
    // Wait, the existing logic (pre-refactor) enforced splitting by newline here.
    // If I change this, I might break behavior if VideoPlayerScreen doesn't do the splitting.
    // The plan is: VideoPlayerScreen will handle the splitting logic.
    // So `SubtitleOverlay` becomes "dumb" regarding logic, just renders what it gets.
    // If `secondaryText` is null, everything is Primary.
    
    final lines = text.split('\n');
    if (lines.isEmpty) return const SizedBox.shrink();

    // Render all lines as primary
    List<InlineSpan> spans = [];
    for (int i = 0; i < lines.length; i++) {
      if (i > 0) spans.add(const TextSpan(text: "\n"));
      // All lines use primary style (null height override)
      spans.add(TextSpan(
        children: _buildSpans(lines[i], style, isStroke: isStroke),
      ));
    }

    return RichText(
      textAlign: TextAlign.center,
      text: TextSpan(children: spans),
    );
  }

  List<TextSpan> _buildSpans(String text, SubtitleStyle style, {required bool isStroke}) {
    List<TextSpan> spans = [];
    StringBuffer currentBuffer = StringBuffer();
    bool? isCurrentChinese;

    for (int i = 0; i < text.length; i++) {
      String char = text[i];
      // Check if character is CJK (Chinese, Japanese, Korean) or full-width punctuation
      // Range: \u4e00-\u9fa5 (Common CJK)
      // \u3000-\u303f (CJK Symbols and Punctuation)
      // \uff00-\uffef (Full-width ASCII variants)
      bool isCharChinese = RegExp(r'[\u4e00-\u9fa5\u3000-\u303f\uff00-\uffef]').hasMatch(char);

      if (isCurrentChinese == null) {
        isCurrentChinese = isCharChinese;
        currentBuffer.write(char);
      } else if (isCurrentChinese == isCharChinese) {
        currentBuffer.write(char);
      } else {
        // Flush previous
        spans.add(_createSpan(currentBuffer.toString(), isCurrentChinese, style, isStroke));
        currentBuffer.clear();
        currentBuffer.write(char);
        isCurrentChinese = isCharChinese;
      }
    }
    if (currentBuffer.isNotEmpty) {
      spans.add(_createSpan(currentBuffer.toString(), isCurrentChinese ?? false, style, isStroke));
    }
    return spans;
  }

  TextSpan _createSpan(String text, bool isChinese, SubtitleStyle style, bool isStroke) {
    TextStyle ts = style.getTextStyle(
      overrideFontFamily: isChinese ? style.fontFamilyChinese : style.fontFamilyEnglish
    );
    
    if (isStroke) {
      ts = ts.copyWith(
        foreground: Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = style.borderWidth
          ..color = style.borderColor,
      );
    } else {
       if (style.hasShadow) {
         ts = ts.copyWith(
           shadows: [Shadow(
              offset: style.shadowOffset,
              blurRadius: style.shadowBlur,
              color: style.shadowColor
           )]
         );
       }
    }
    return TextSpan(text: text, style: ts);
  }
}
