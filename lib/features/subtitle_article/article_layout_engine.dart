import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';

import 'article_document.dart';
import 'article_layout_model.dart';

/// Produces natural-line records without ever laying out the entire article as
/// one native paragraph. The final line of each bounded window is carried into
/// the next window, so an internal batch boundary cannot become a visual line.
class ArticleLayoutEngine {
  const ArticleLayoutEngine({this.windowCodeUnits = 2048});

  final int windowCodeUnits;

  ArticleLayout layout({
    required ArticleDocument document,
    required ArticleLayoutKey key,
  }) {
    final builder = _IncrementalArticleLayoutBuilder(
      document: document,
      key: key,
      windowCodeUnits: windowCodeUnits,
    );
    while (builder.layoutNextWindow()) {}
    return builder.finish();
  }

  /// Performs the same exact layout as [layout], but returns to the frame
  /// scheduler between bounded native paragraph layouts. This lets the mode
  /// switch paint immediately even for long subtitle documents.
  Future<ArticleLayout?> layoutIncrementally({
    required ArticleDocument document,
    required ArticleLayoutKey key,
    bool Function()? isCancelled,
    Duration frameBudget = const Duration(milliseconds: 2),
  }) async {
    final builder = _IncrementalArticleLayoutBuilder(
      document: document,
      key: key,
      windowCodeUnits: windowCodeUnits,
    );
    final stopwatch = Stopwatch()..start();
    while (builder.layoutNextWindow()) {
      if (isCancelled?.call() ?? false) return null;
      if (stopwatch.elapsed >= frameBudget) {
        stopwatch.reset();
        SchedulerBinding.instance.ensureVisualUpdate();
        await SchedulerBinding.instance.endOfFrame;
        if (isCancelled?.call() ?? false) return null;
      }
    }
    if (isCancelled?.call() ?? false) return null;
    return builder.finish();
  }
}

class _IncrementalArticleLayoutBuilder {
  _IncrementalArticleLayoutBuilder({
    required this.document,
    required this.key,
    required this.windowCodeUnits,
  });

  final ArticleDocument document;
  final ArticleLayoutKey key;
  final int windowCodeUnits;
  final List<ArticleLineRecord> lines = <ArticleLineRecord>[];
  int cursor = 0;

  bool layoutNextWindow() {
    if (document.text.isEmpty ||
        key.width <= 0 ||
        cursor >= document.text.length) {
      return false;
    }
    var windowEnd = _safeBoundary(
      document.text,
      math.min(document.text.length, cursor + windowCodeUnits),
    );
    if (windowEnd <= cursor) windowEnd = document.text.length;

    late List<TextRange> ranges;
    late TextPainter painter;
    while (true) {
      painter = TextPainter(
        text: TextSpan(
          text: document.text.substring(cursor, windowEnd),
          style: key.style,
        ),
        textDirection: key.textDirection,
        textScaler: key.textScaler,
      )..layout(maxWidth: key.width);
      ranges = _lineRanges(painter, windowEnd - cursor);
      final hasCommittedLine =
          windowEnd == document.text.length || ranges.length > 1;
      if (hasCommittedLine) break;
      painter.dispose();
      final nextEnd = _safeBoundary(
        document.text,
        math.min(document.text.length, cursor + (windowEnd - cursor) * 2),
      );
      windowEnd = nextEnd <= windowEnd ? document.text.length : nextEnd;
    }

    final metrics = painter.computeLineMetrics();
    final commitCount = windowEnd == document.text.length
        ? ranges.length
        : ranges.length - 1;
    for (var i = 0; i < commitCount; i++) {
      final range = ranges[i];
      final start = cursor + range.start;
      final end = cursor + range.end;
      if (end <= start) continue;
      var paintStart = start;
      while (paintStart < end && document.text.codeUnitAt(paintStart) == 0x20) {
        paintStart++;
      }
      lines.add(
        ArticleLineRecord(
          start: start,
          paintStart: paintStart,
          end: end,
          height: i < metrics.length ? metrics[i].height : painter.height,
          sentenceIndices: _sentencesIntersecting(document, start, end),
        ),
      );
    }
    final nextCursor = cursor + ranges[commitCount - 1].end;
    painter.dispose();
    if (nextCursor <= cursor) {
      cursor = document.text.length;
      return false;
    }
    cursor = nextCursor;
    return cursor < document.text.length;
  }

  ArticleLayout finish() {
    final sentenceToLine = List<int>.filled(document.sentences.length, -1);
    for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
      for (final sentenceIndex in lines[lineIndex].sentenceIndices) {
        if (sentenceToLine[sentenceIndex] < 0) {
          sentenceToLine[sentenceIndex] = lineIndex;
        }
      }
    }
    var nextVisibleLine = -1;
    for (var i = sentenceToLine.length - 1; i >= 0; i--) {
      if (sentenceToLine[i] >= 0) nextVisibleLine = sentenceToLine[i];
      if (sentenceToLine[i] < 0) sentenceToLine[i] = nextVisibleLine;
    }
    var previousVisibleLine = -1;
    for (var i = 0; i < sentenceToLine.length; i++) {
      if (sentenceToLine[i] >= 0) previousVisibleLine = sentenceToLine[i];
      if (sentenceToLine[i] < 0) sentenceToLine[i] = previousVisibleLine;
    }
    return ArticleLayout(
      key: key,
      lines: List<ArticleLineRecord>.unmodifiable(lines),
      sentenceToLine: List<int>.unmodifiable(sentenceToLine),
    );
  }

  List<TextRange> _lineRanges(TextPainter painter, int textLength) {
    final result = <TextRange>[];
    var offset = 0;
    while (offset < textLength) {
      final range = painter.getLineBoundary(TextPosition(offset: offset));
      if (range.end <= offset) break;
      result.add(range);
      offset = range.end;
    }
    return result;
  }

  List<int> _sentencesIntersecting(
    ArticleDocument document,
    int start,
    int end,
  ) {
    final result = <int>[];
    var low = 0;
    var high = document.sentences.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (document.sentences[mid].end <= start) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    for (var i = low; i < document.sentences.length; i++) {
      final sentence = document.sentences[i];
      if (sentence.start >= end) break;
      if (!sentence.hasText) continue;
      result.add(sentence.displayIndex);
    }
    return List<int>.unmodifiable(result);
  }
}

int _safeBoundary(String text, int offset) {
  if (offset <= 0 || offset >= text.length) return offset;
  return CharacterRange.at(text, offset).stringBeforeLength;
}
