import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_site_urls.dart';

void main() {
  group('YtDlpSiteUrls', () {
    test('leaves ordinary and YouTube links unchanged', () {
      expect(
        YtDlpSiteUrls.xiaohongshuNoteUrl('https://youtu.be/ajtJvlVCq_U'),
        isNull,
      );
      expect(YtDlpSiteUrls.isYoutube('https://youtu.be/ajtJvlVCq_U'), isTrue);
      expect(
        YtDlpSiteUrls.isYoutube('https://www.youtube.com/watch?v=ajtJvlVCq_U'),
        isTrue,
      );
      expect(
        YtDlpSiteUrls.isYoutube('https://www.bilibili.com/video/BV1xx411c7mD'),
        isFalse,
      );
    });

    test('keeps an existing Xiaohongshu note URL', () {
      const note =
          'https://www.xiaohongshu.com/discovery/item/6ab3c7900000000015002920?type=video&xsec_token=abc';
      expect(YtDlpSiteUrls.xiaohongshuNoteUrl(note), note);
    });

    test('unwraps the login redirect back to the note URL', () {
      const note =
          'http://www.xiaohongshu.com/discovery/item/6ab3c7900000000015002920?type=video&xsec_token=abc%3D';
      final login =
          'https://www.xiaohongshu.com/login?redirectPath=${Uri.encodeQueryComponent(note)}';

      expect(
        YtDlpSiteUrls.xiaohongshuNoteUrl(login),
        'https://www.xiaohongshu.com/discovery/item/6ab3c7900000000015002920?type=video&xsec_token=abc%3D',
      );
    });

    test('recognizes Xiaohongshu share hosts', () {
      expect(
        YtDlpSiteUrls.isXiaohongshuShareHost(
          Uri.parse('https://xhslink.cn/o/wlYXJp1Mg'),
        ),
        isTrue,
      );
      expect(
        YtDlpSiteUrls.isXiaohongshuShareHost(
          Uri.parse('https://www.bilibili.com/video/BV1xx411c7mD'),
        ),
        isFalse,
      );
    });

    test('YouTube failures do not get a Xiaohongshu cookie hint', () {
      expect(
        YtDlpSiteUrls.explainResolveFailure(
          '解析失败: Unsupported URL',
          'https://youtu.be/ajtJvlVCq_U',
        ),
        '解析失败: Unsupported URL',
      );
    });

    test('login-wall failures mention web_session cookies', () {
      final message = YtDlpSiteUrls.explainResolveFailure(
        '解析失败: Unsupported URL: https://www.xiaohongshu.com/login?redirectPath=1',
        'https://xhslink.cn/o/example',
      );
      expect(message, contains('web_session'));
    });
  });
}
