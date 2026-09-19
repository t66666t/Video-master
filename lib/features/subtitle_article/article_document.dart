import 'package:flutter/foundation.dart';

/// A subtitle sentence in the normalized article text.
@immutable
class ArticleSentenceRef {
  const ArticleSentenceRef({
    required this.displayIndex,
    required this.start,
    required this.end,
  });

  final int displayIndex;
  final int start;
  final int end;

  bool get hasText => end > start;
  bool contains(int offset) => offset >= start && offset < end;
}

/// Immutable text and range index used by the continuous article renderer.
@immutable
class ArticleDocument {
  const ArticleDocument._({
    required this.generation,
    required this.text,
    required this.sentences,
  });

  factory ArticleDocument.fromDisplayTexts({
    required int generation,
    required List<String> displayTexts,
    List<bool>? imageSubtitleFlags,
    String sentenceSeparator = '\u0020\u0020',
  }) {
    final buffer = StringBuffer();
    final sentences = <ArticleSentenceRef>[];
    var hasVisibleText = false;

    for (var index = 0; index < displayTexts.length; index++) {
      var text = normalizeArticleSentence(displayTexts[index]);
      if (text.isEmpty &&
          imageSubtitleFlags != null &&
          index < imageSubtitleFlags.length &&
          imageSubtitleFlags[index]) {
        text = '[图片字幕]';
      }

      if (text.isEmpty) {
        sentences.add(
          ArticleSentenceRef(
            displayIndex: index,
            start: buffer.length,
            end: buffer.length,
          ),
        );
        continue;
      }

      if (hasVisibleText) buffer.write(sentenceSeparator);
      final start = buffer.length;
      buffer.write(text);
      sentences.add(
        ArticleSentenceRef(
          displayIndex: index,
          start: start,
          end: buffer.length,
        ),
      );
      hasVisibleText = true;
    }

    return ArticleDocument._(
      generation: generation,
      text: buffer.toString(),
      sentences: List<ArticleSentenceRef>.unmodifiable(sentences),
    );
  }

  final int generation;
  final String text;
  final List<ArticleSentenceRef> sentences;

  ArticleSentenceRef? sentenceForDisplayIndex(int index) {
    if (index < 0 || index >= sentences.length) return null;
    return sentences[index];
  }

  /// Returns null for the single-space separator and for document padding.
  int? displayIndexAtOffset(int offset) {
    var low = 0;
    var high = sentences.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final sentence = sentences[mid];
      if (offset < sentence.start) {
        high = mid - 1;
      } else if (offset >= sentence.end) {
        low = mid + 1;
      } else {
        return sentence.hasText ? sentence.displayIndex : null;
      }
    }
    return null;
  }
}

String normalizeArticleSentence(String text) {
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}
