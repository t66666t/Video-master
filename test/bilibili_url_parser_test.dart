import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/bilibili_url_parser.dart';

void main() {
  group('BilibiliUrlParser', () {
    test('keeps a b23 short link from shared text for redirect resolution', () {
      final input = BilibiliUrlParser.normalizeInput(
        '【视频标题-哔哩哔哩】 https://b23.tv/PkvvCb4',
      );

      expect(input, isNotNull);
      expect(input?.cleanedInput, 'https://b23.tv/PkvvCb4');
      expect(input?.type, BilibiliUrlType.shortLink);
      expect(input?.id, isNull);
    });

    test('still rejects unsupported links without a Bilibili id', () {
      expect(
        BilibiliUrlParser.normalizeInput('https://example.com/video/123'),
        isNull,
      );
    });
  });
}
