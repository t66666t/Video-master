import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/subtitle_article/article_document.dart';

void main() {
  test('normalizes text and keeps reversible sentence ranges', () {
    final document = ArticleDocument.fromDisplayTexts(
      generation: 7,
      displayTexts: const <String>['  first\nline  ', '', '第二句', 'image'],
    );

    expect(document.text, 'first line  第二句  image');
    expect(document.sentenceForDisplayIndex(0)!.hasText, isTrue);
    expect(document.sentenceForDisplayIndex(1)!.hasText, isFalse);
    expect(document.displayIndexAtOffset(1), 0);
    expect(document.displayIndexAtOffset(document.text.indexOf('第二')), 2);
    expect(document.displayIndexAtOffset(document.text.indexOf('  ')), isNull);
  });

  test('image subtitle gets an explicit readable placeholder', () {
    final document = ArticleDocument.fromDisplayTexts(
      generation: 1,
      displayTexts: const <String>[''],
      imageSubtitleFlags: const <bool>[true],
    );
    expect(document.text, '[图片字幕]');
    expect(document.displayIndexAtOffset(0), 0);
  });
}
