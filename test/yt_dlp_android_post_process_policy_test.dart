import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_android_post_process_policy.dart';

void main() {
  group('YtDlpAndroidPostProcessPolicy', () {
    test('does not treat yt-dlp thumbnails as media artifacts', () {
      for (final extension in <String>['webp', 'png', 'jpg']) {
        expect(
          YtDlpAndroidPostProcessPolicy.isMediaContainerPath(
            '/tmp/ytdlp_task_f137.$extension',
          ),
          isFalse,
          reason: extension,
        );
      }
    });

    test('accepts common Android audio and video containers', () {
      for (final extension in <String>['mp4', 'webm', 'mkv', 'm4a', 'opus']) {
        expect(
          YtDlpAndroidPostProcessPolicy.isMediaContainerPath(
            '/tmp/ytdlp_task_f137.$extension',
          ),
          isTrue,
          reason: extension,
        );
      }
    });

    test('uses a stream specifier that excludes attached cover pictures', () {
      expect(
        YtDlpAndroidPostProcessPolicy.primaryVideoStreamSpecifier,
        '0:V:0',
      );
    });

    test('removes thumbnail download and conversion arguments on Android', () {
      expect(
        YtDlpAndroidPostProcessPolicy.withoutThumbnailOutputArgs(<String>[
          '--no-warnings',
          '--write-thumbnail',
          '--convert-thumbnails',
          'png',
          '--embed-metadata',
          'https://example.com/video',
        ]),
        <String>[
          '--no-warnings',
          '--embed-metadata',
          'https://example.com/video',
        ],
      );
    });
  });
}
