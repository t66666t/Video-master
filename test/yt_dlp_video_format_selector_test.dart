import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/youtube_download/models/youtube_download_models.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_video_format_selector.dart';

const av1VideoOnly1080 = VideoFormat(
  formatId: '401',
  ext: 'mp4',
  videoCodec: 'av01.0.08M.08',
  height: 1080,
  bitrate: 2200,
);

const h264Muxed720 = VideoFormat(
  formatId: '22',
  ext: 'mp4',
  videoCodec: 'avc1.64001F',
  audioCodec: 'mp4a.40.2',
  height: 720,
  bitrate: 1600,
  hasAudio: true,
);

void main() {
  group('YtDlpVideoFormatSelector', () {
    test('recommended mode prefers broadly compatible H264 MP4', () {
      final formats = <VideoFormat>[
        av1VideoOnly1080,
        h264Muxed720,
        const VideoFormat(
          formatId: '18',
          ext: 'mp4',
          videoCodec: 'avc1.42001E',
          height: 360,
          hasAudio: true,
        ),
      ];

      expect(YtDlpVideoFormatSelector.pickFormatId(formats), '22');
      expect(
        YtDlpVideoFormatSelector.sortForDisplay(
          formats,
        ).map((item) => item.formatId).take(2),
        orderedEquals(<String>['401', '22']),
      );
    });

    test('display order is globally descending by resolution', () {
      final sorted = YtDlpVideoFormatSelector.sortForDisplay(const [
        VideoFormat(
          formatId: '137',
          ext: 'mp4',
          videoCodec: 'avc1.640028',
          height: 1080,
          bitrate: 5000,
        ),
        VideoFormat(
          formatId: '313',
          ext: 'webm',
          videoCodec: 'vp9',
          height: 2160,
          bitrate: 12000,
        ),
        VideoFormat(
          formatId: '271',
          ext: 'webm',
          videoCodec: 'vp9',
          height: 1440,
          bitrate: 8000,
        ),
      ]);

      expect(
        sorted.map((item) => item.formatId),
        orderedEquals(<String>['313', '271', '137']),
      );
    });

    test('same resolution uses audio presence then video bitrate', () {
      final sorted = YtDlpVideoFormatSelector.sortForDisplay(const [
        VideoFormat(formatId: 'low', ext: 'mp4', height: 1080, bitrate: 1500),
        VideoFormat(formatId: 'high', ext: 'webm', height: 1080, bitrate: 3500),
        VideoFormat(
          formatId: 'muxed',
          ext: 'mp4',
          height: 1080,
          bitrate: 1200,
          hasAudio: true,
        ),
      ]);

      expect(
        sorted.map((item) => item.formatId),
        orderedEquals(<String>['muxed', 'high', 'low']),
      );
    });

    test('an explicit quality selects that resolution before codec', () {
      expect(
        YtDlpVideoFormatSelector.pickFormatId(const <VideoFormat>[
          av1VideoOnly1080,
          h264Muxed720,
        ], preferredQuality: '1080p'),
        '401',
      );
      expect(
        YtDlpVideoFormatSelector.pickFormatId(const <VideoFormat>[
          av1VideoOnly1080,
          h264Muxed720,
        ], preferredQuality: '720p'),
        '22',
      );
    });

    test('same-resolution formats prefer H264 MP4', () {
      expect(
        YtDlpVideoFormatSelector.pickFormatId(const <VideoFormat>[
          av1VideoOnly1080,
          VideoFormat(
            formatId: '137',
            ext: 'mp4',
            videoCodec: 'avc1.640028',
            height: 1080,
          ),
        ], preferredQuality: '1080p'),
        '137',
      );
    });

    test('falls back to the nearest lower explicit quality', () {
      expect(
        YtDlpVideoFormatSelector.pickFormatId(const <VideoFormat>[
          h264Muxed720,
          VideoFormat(
            formatId: '135',
            ext: 'mp4',
            videoCodec: 'avc1.4d401f',
            height: 480,
          ),
        ], preferredQuality: '1080p'),
        '22',
      );
    });

    test('uses highest available resolution when no H264 MP4 exists', () {
      expect(
        YtDlpVideoFormatSelector.pickFormatId(const <VideoFormat>[
          av1VideoOnly1080,
          VideoFormat(
            formatId: '247',
            ext: 'webm',
            videoCodec: 'vp9',
            height: 720,
          ),
        ]),
        '401',
      );
    });

    test('does not make an extreme quality downgrade for compatibility', () {
      expect(
        YtDlpVideoFormatSelector.pickFormatId(const <VideoFormat>[
          VideoFormat(
            formatId: '313',
            ext: 'webm',
            videoCodec: 'vp9',
            height: 2160,
          ),
          VideoFormat(
            formatId: '18',
            ext: 'mp4',
            videoCodec: 'avc1.42001E',
            height: 360,
            hasAudio: true,
          ),
        ]),
        '313',
      );
    });
  });
}
