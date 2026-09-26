import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/youtube_download/models/youtube_download_models.dart';
import 'package:video_player_app/features/youtube_download/services/x_post_media_fallback.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_meta_parser.dart';

void main() {
  const statusId = '1001';
  const pageUrl = 'https://x.com/example/status/$statusId';

  test('reads a status id only from X hosts', () {
    expect(XPostMediaFallback.statusIdFromUrl(pageUrl), statusId);
    expect(
      XPostMediaFallback.statusIdFromUrl(
        'https://twitter.com/example/status/$statusId',
      ),
      statusId,
    );
    expect(
      XPostMediaFallback.statusIdFromUrl(
        'https://example.com/status/$statusId',
      ),
      isNull,
    );
  });

  test('attempts the public endpoint only after a missing-video failure', () {
    expect(
      XPostMediaFallback.shouldAttempt(
        pageUrl,
        Exception('[twitter] $statusId: No video could be found in this tweet'),
      ),
      isTrue,
    );
    expect(
      XPostMediaFallback.shouldAttempt(
        'https://example.com/watch',
        Exception('No video could be found in this tweet'),
      ),
      isFalse,
    );
    expect(
      XPostMediaFallback.shouldAttempt(pageUrl, Exception('timed out')),
      isFalse,
    );
  });

  test('builds downloadable formats from a public status payload', () {
    final info = XPostMediaFallback.infoFromPayload(
      {
        'tweet': {
          'text': 'A short post',
          'author': {'name': 'Example'},
          'media': {
            'videos': [
              {
                'duration': 12.4,
                'width': 1280,
                'height': 720,
                'thumbnail_url': 'https://cdn.example/thumb.jpg',
                'variants': [
                  {
                    'bitrate': 832000,
                    'content_type': 'video/mp4',
                    'url': 'https://cdn.example/low.mp4',
                  },
                  {
                    'bitrate': 2176000,
                    'content_type': 'video/mp4',
                    'url': 'https://cdn.example/high.mp4',
                  },
                ],
              },
            ],
          },
        },
      },
      pageUrl: pageUrl,
      statusId: statusId,
    );

    expect(info, isNotNull);
    final meta = const YtDlpMetaParser().parse(info!);
    expect(meta.videoFormats, hasLength(2));
    expect(meta.videoFormats.every((format) => format.hasAudio), isTrue);
    expect(
      XPostMediaFallback.downloadUrlForFormat(meta, 'x-0-1'),
      'https://cdn.example/high.mp4',
    );
    expect(
      XPostMediaFallback.downloadUrlForFormat(meta, null),
      'https://cdn.example/high.mp4',
    );
  });
}
