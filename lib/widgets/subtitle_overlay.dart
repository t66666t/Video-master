import 'package:flutter/foundation.dart';
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

/// Small visual gap between the subtitle background and playback controls.
/// It scales with the current player viewport instead of using a device-
/// independent fixed offset that can look excessive on short screens.
double subtitlePlaybackControlsClearance(double viewportHeight) {
  if (!viewportHeight.isFinite || viewportHeight <= 0) return 0;
  return viewportHeight * 0.008;
}

/// Resolves the subtitle group's exact position inside its viewport.
///
/// When [playbackControlsTop] is supplied, the primary and secondary subtitle
/// block is treated as one unit. It only moves when its rendered bottom edge
/// would cross that boundary, and it moves by the minimum required distance.
/// This pure geometry helper also keeps the behavior independently testable.
Offset resolveSubtitleOverlayOffset({
  required Size viewportSize,
  required Size subtitleSize,
  required Alignment alignment,
  double? playbackControlsTop,
  List<Rect> playbackControlRects = const <Rect>[],
}) {
  final double availableX = (viewportSize.width - subtitleSize.width)
      .clamp(0.0, double.infinity)
      .toDouble();
  final double availableY = (viewportSize.height - subtitleSize.height)
      .clamp(0.0, double.infinity)
      .toDouble();
  final double dx = availableX * (alignment.x + 1) / 2;
  double dy = availableY * (alignment.y + 1) / 2;

  final List<Rect> effectiveControlRects = <Rect>[
    ...playbackControlRects.where(
      (rect) =>
          rect.left.isFinite &&
          rect.top.isFinite &&
          rect.right.isFinite &&
          rect.bottom.isFinite &&
          !rect.isEmpty,
    ),
  ];
  if (playbackControlsTop != null && playbackControlsTop.isFinite) {
    final double safeTop = playbackControlsTop
        .clamp(0.0, viewportSize.height)
        .toDouble();
    effectiveControlRects.add(
      Rect.fromLTRB(0, safeTop, viewportSize.width, viewportSize.height),
    );
  }

  // Resolve each genuinely intersecting control region independently. A
  // chapter pill therefore only affects subtitles whose horizontal bounds
  // actually cross that pill, instead of reserving its complete row.
  bool moved;
  do {
    moved = false;
    final Rect subtitleRect = Rect.fromLTWH(
      dx,
      dy,
      subtitleSize.width,
      subtitleSize.height,
    );
    for (final Rect controlRect in effectiveControlRects) {
      if (!subtitleRect.overlaps(controlRect)) continue;
      final double resolvedY = (controlRect.top - subtitleSize.height)
          .clamp(0.0, availableY)
          .toDouble();
      if (resolvedY < dy) {
        dy = resolvedY;
        moved = true;
        break;
      }
    }
  } while (moved);

  return Offset(dx, dy);
}

class SubtitleOverlayGroup extends StatelessWidget {
  final List<SubtitleOverlayEntry> entries;
  final SubtitleStyle style;
  final double? referenceHeight;
  final Alignment alignment;
  final VoidCallback? onLongPress;
  final bool isDragging;
  final bool isGestureOnly;
  final bool isVisualOnly;
  final double itemGap;
  final bool animateAlignment;
  final Duration alignmentDuration;
  final Curve alignmentCurve;
  final ValueListenable<bool>? playbackControlsVisibility;
  final double? playbackControlsTop;
  final List<Rect> Function()? playbackControlRects;
  final bool avoidPlaybackControls;

  const SubtitleOverlayGroup({
    super.key,
    required this.entries,
    required this.style,
    this.referenceHeight,
    required this.alignment,
    this.onLongPress,
    this.isDragging = false,
    this.isGestureOnly = false,
    this.isVisualOnly = false,
    this.itemGap = 6.0,
    this.animateAlignment = false,
    this.alignmentDuration = const Duration(milliseconds: 300),
    this.alignmentCurve = Curves.easeOutCubic,
    this.playbackControlsVisibility,
    this.playbackControlsTop,
    this.playbackControlRects,
    this.avoidPlaybackControls = false,
  });

  @override
  Widget build(BuildContext context) {
    final visibleEntries = entries.where((e) => e.hasContent).toList();
    if (visibleEntries.isEmpty && !isDragging) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final double resolvedReferenceHeight =
            referenceHeight ??
            ((constraints.maxHeight != double.infinity &&
                    constraints.maxHeight > 0)
                ? constraints.maxHeight
                : kSubtitleReferenceHeight);
        final double scale = SubtitleResolvedStyleMetrics.fromStyle(
          style,
          referenceHeight: resolvedReferenceHeight,
        ).scale;
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
                    referenceHeight: resolvedReferenceHeight,
                    onLongPress: onLongPress,
                    isDragging: isDragging,
                    isGestureOnly: isGestureOnly,
                    isVisualOnly: isVisualOnly,
                  ),
                ),
                if (i != visibleEntries.length - 1)
                  SizedBox(height: itemGap * scale),
              ],
            ],
          ),
        );

        Widget buildPositionedContent(bool controlsVisible) {
          final double? effectiveControlsTop =
              avoidPlaybackControls && controlsVisible
              ? playbackControlsTop
              : null;
          final List<Rect> effectiveControlRects =
              avoidPlaybackControls && controlsVisible
              ? playbackControlRects?.call() ?? const <Rect>[]
              : const <Rect>[];
          if (animateAlignment) {
            return _AnimatedSubtitlePosition(
              alignment: alignment,
              duration: alignmentDuration,
              curve: alignmentCurve,
              playbackControlsTop: effectiveControlsTop,
              playbackControlRects: effectiveControlRects,
              child: content,
            );
          }
          return CustomSingleChildLayout(
            delegate: _SubtitlePositionDelegate(
              alignment: alignment,
              playbackControlsTop: effectiveControlsTop,
              playbackControlRects: effectiveControlRects,
            ),
            child: content,
          );
        }

        final Widget alignedChild = playbackControlsVisibility == null
            ? buildPositionedContent(false)
            : ValueListenableBuilder<bool>(
                valueListenable: playbackControlsVisibility!,
                builder: (context, controlsVisible, _) =>
                    buildPositionedContent(controlsVisible),
              );

        return SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: ClipRect(child: alignedChild),
        );
      },
    );
  }
}

class _SubtitlePositionDelegate extends SingleChildLayoutDelegate {
  final Alignment alignment;
  final double? playbackControlsTop;
  final List<Rect> playbackControlRects;

  const _SubtitlePositionDelegate({
    required this.alignment,
    required this.playbackControlsTop,
    this.playbackControlRects = const <Rect>[],
  });

  @override
  Size getSize(BoxConstraints constraints) => constraints.biggest;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) =>
      resolveSubtitleOverlayOffset(
        viewportSize: size,
        subtitleSize: childSize,
        alignment: alignment,
        playbackControlsTop: playbackControlsTop,
        playbackControlRects: playbackControlRects,
      );

  @override
  bool shouldRelayout(_SubtitlePositionDelegate oldDelegate) =>
      alignment != oldDelegate.alignment ||
      playbackControlsTop != oldDelegate.playbackControlsTop ||
      playbackControlRects != oldDelegate.playbackControlRects;
}

class _AnimatedSubtitlePosition extends ImplicitlyAnimatedWidget {
  final Alignment alignment;
  final double? playbackControlsTop;
  final List<Rect> playbackControlRects;
  final Widget child;

  const _AnimatedSubtitlePosition({
    required this.alignment,
    required super.duration,
    required super.curve,
    required this.playbackControlsTop,
    required this.playbackControlRects,
    required this.child,
  });

  @override
  AnimatedWidgetBaseState<_AnimatedSubtitlePosition> createState() =>
      _AnimatedSubtitlePositionState();
}

class _AnimatedSubtitlePositionState
    extends AnimatedWidgetBaseState<_AnimatedSubtitlePosition> {
  AlignmentTween? _alignmentTween;

  @override
  void forEachTween(TweenVisitor<dynamic> visitor) {
    _alignmentTween =
        visitor(
              _alignmentTween,
              widget.alignment,
              (dynamic value) => AlignmentTween(begin: value as Alignment),
            )
            as AlignmentTween?;
  }

  @override
  Widget build(BuildContext context) {
    return CustomSingleChildLayout(
      delegate: _SubtitlePositionDelegate(
        alignment: _alignmentTween?.evaluate(animation) ?? widget.alignment,
        // This value is deliberately not tweened: controls visibility must
        // move or restore subtitles in the same frame with no animation.
        playbackControlsTop: widget.playbackControlsTop,
        playbackControlRects: widget.playbackControlRects,
      ),
      child: widget.child,
    );
  }
}

class SubtitleOverlay extends StatelessWidget {
  final String text; // Primary text (or all text if single file + no split)
  final String? secondaryText; // Explicit secondary text
  final Uint8List? image; // New: Support for bitmap subtitles
  final SubtitleStyle style;
  final double? referenceHeight;
  final VoidCallback? onLongPress;
  final bool isDragging;
  final bool
  isGestureOnly; // If true, renders transparent text but captures gestures
  final bool isVisualOnly; // If true, renders visible text but ignores gestures

  const SubtitleOverlay({
    super.key,
    required this.text,
    this.secondaryText,
    this.image,
    this.style = const SubtitleStyle(),
    this.referenceHeight,
    this.onLongPress,
    this.isDragging = false,
    this.isGestureOnly = false,
    this.isVisualOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty &&
        (secondaryText == null || secondaryText!.isEmpty) &&
        image == null &&
        !isDragging) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final double resolvedReferenceHeight =
            referenceHeight ??
            ((constraints.maxHeight != double.infinity &&
                    constraints.maxHeight > 0)
                ? constraints.maxHeight
                : kSubtitleReferenceHeight);
        final SubtitleResolvedStyleMetrics resolvedMetrics =
            SubtitleResolvedStyleMetrics.fromStyle(
              style,
              referenceHeight: resolvedReferenceHeight,
            );
        final double scale = resolvedMetrics.scale;
        final SubtitleStyle scaledStyle = resolvedMetrics.applyToStyle(style);

        // In drag mode, show placeholder if text is empty and no image
        final displayText = (text.isEmpty && image == null && isDragging)
            ? "字幕位置预览\nSubtitle Preview"
            : text;

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

        Widget content = RepaintBoundary(
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
                  padding: EdgeInsets.symmetric(
                    horizontal: 12 * scale,
                    vertical: 6 * scale,
                  ),
                  decoration: BoxDecoration(
                    color: effectiveStyle.backgroundColor.withValues(
                      alpha: effectiveStyle.backgroundOpacity,
                    ),
                    borderRadius: BorderRadius.circular(8 * scale),
                    border: isDragging
                        ? Border.all(
                            color: Colors.greenAccent,
                            width: 2 * scale,
                          )
                        : null,
                  ),
                  child: effectiveStyle.hasBorder
                      ? Stack(
                          children: [
                            _buildContent(
                              displayText,
                              effectiveStyle,
                              isStroke: true,
                            ),
                            _buildContent(
                              displayText,
                              effectiveStyle,
                              isStroke: false,
                            ),
                          ],
                        )
                      : _buildContent(
                          displayText,
                          effectiveStyle,
                          isStroke: false,
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
      },
    );
  }

  Widget _buildContent(
    String text,
    SubtitleStyle style, {
    required bool isStroke,
  }) {
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
          spans.add(
            TextSpan(
              // Use default line height for primary
              children: _buildSpans(lines[i], style, isStroke: isStroke),
            ),
          );
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
        final double height = SubtitleResolvedStyleMetrics.resolveLineHeight(
          lineSpacing: style.lineSpacing,
          fontSize: secFontSize,
        );

        spans.add(
          TextSpan(
            style: TextStyle(height: height),
            children: _buildSpans(secLines[i], secStyle, isStroke: isStroke),
          ),
        );
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
      spans.add(
        TextSpan(children: _buildSpans(lines[i], style, isStroke: isStroke)),
      );
    }

    return RichText(
      textAlign: TextAlign.center,
      text: TextSpan(children: spans),
    );
  }

  static bool _isCJK(int codeUnit) =>
      (codeUnit >= 0x4e00 && codeUnit <= 0x9fa5) ||
      (codeUnit >= 0x3000 && codeUnit <= 0x303f) ||
      (codeUnit >= 0xff00 && codeUnit <= 0xffef);

  List<TextSpan> _buildSpans(
    String text,
    SubtitleStyle style, {
    required bool isStroke,
  }) {
    List<TextSpan> spans = [];
    StringBuffer currentBuffer = StringBuffer();
    bool? isCurrentChinese;

    for (int i = 0; i < text.length; i++) {
      final String char = text[i];
      final bool isCharChinese = _isCJK(char.codeUnitAt(0));

      if (isCurrentChinese == null) {
        isCurrentChinese = isCharChinese;
        currentBuffer.write(char);
      } else if (isCurrentChinese == isCharChinese) {
        currentBuffer.write(char);
      } else {
        // Flush previous
        spans.add(
          _createSpan(
            currentBuffer.toString(),
            isCurrentChinese,
            style,
            isStroke,
          ),
        );
        currentBuffer.clear();
        currentBuffer.write(char);
        isCurrentChinese = isCharChinese;
      }
    }
    if (currentBuffer.isNotEmpty) {
      spans.add(
        _createSpan(
          currentBuffer.toString(),
          isCurrentChinese ?? false,
          style,
          isStroke,
        ),
      );
    }
    return spans;
  }

  TextSpan _createSpan(
    String text,
    bool isChinese,
    SubtitleStyle style,
    bool isStroke,
  ) {
    TextStyle ts = style.getTextStyle(
      overrideFontFamily: isChinese
          ? style.fontFamilyChinese
          : style.fontFamilyEnglish,
    );

    if (isStroke) {
      final double effectiveBorderWidth = style.effectiveBorderWidth;
      ts = ts.copyWith(
        foreground: Paint()
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..strokeWidth = effectiveBorderWidth
          ..color = style.borderColor,
      );
    } else {
      final Offset effectiveShadowOffset = style.effectiveShadowOffset;
      final double effectiveShadowBlur = style.effectiveShadowBlur;
      if (style.hasShadow) {
        ts = ts.copyWith(
          shadows: [
            Shadow(
              offset: effectiveShadowOffset,
              blurRadius: effectiveShadowBlur,
              color: style.shadowColor,
            ),
          ],
        );
      }
    }
    return TextSpan(text: text, style: ts);
  }
}
