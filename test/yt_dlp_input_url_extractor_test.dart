import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_input_url_extractor.dart';

void main() {
  group('YtDlpInputUrlExtractor', () {
    test('extracts a clean https url from noisy share text', () {
      final urls = YtDlpInputUrlExtractor.extractUrls(
        '快看这个视频： https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=43s ，真的很有意思',
      );

      expect(
        urls,
        ['https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=43s'],
      );
    });

    test('adds https to bare domains without scheme', () {
      final urls = YtDlpInputUrlExtractor.extractUrls(
        'youtube.com/watch?v=dQw4w9WgXcQ',
      );

      expect(
        urls,
        ['https://youtube.com/watch?v=dQw4w9WgXcQ'],
      );
    });

    test('extracts multiple links from mixed multi-line text', () {
      final urls = YtDlpInputUrlExtractor.extractUrls(
        '''
第一条：youtu.be/dQw4w9WgXcQ?t=1
作者主页在这里：www.youtube.com/@GoogleDevelopers/videos
补充说明文字不应该被保留
''',
      );

      expect(
        urls,
        [
          'https://youtu.be/dQw4w9WgXcQ?t=1',
          'https://www.youtube.com/@GoogleDevelopers/videos',
        ],
      );
    });

    test('keeps query strings fragments and balanced parentheses', () {
      final urls = YtDlpInputUrlExtractor.extractUrls(
        '链接在这里(https://example.com/watch/(demo)?a=1&b=two#part)。',
      );

      expect(
        urls,
        ['https://example.com/watch/(demo)?a=1&b=two#part'],
      );
    });

    test('trims unmatched closing wrappers around a url', () {
      final urls = YtDlpInputUrlExtractor.extractUrls(
        '参考：https://m.youtube.com/watch?v=dQw4w9WgXcQ))】',
      );

      expect(
        urls,
        ['https://m.youtube.com/watch?v=dQw4w9WgXcQ'],
      );
    });

    test('deduplicates repeated urls while keeping order', () {
      final urls = YtDlpInputUrlExtractor.extractUrls(
        '''
https://youtu.be/dQw4w9WgXcQ
分享一次：https://youtu.be/dQw4w9WgXcQ
''',
      );

      expect(
        urls,
        ['https://youtu.be/dQw4w9WgXcQ'],
      );
    });
  });
}
