import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/bilibili/media_probe_result.dart';

void main() {
  group('BilibiliMediaProbeResult', () {
    test('parses ffprobe JSON used by FFprobeKit and desktop ffprobe', () {
      final result = BilibiliMediaProbeResult.fromFfprobeJson('''
        {
          "streams": [
            {"codec_name": "h264", "codec_type": "video"},
            {"codec_name": "aac", "codec_type": "audio"}
          ],
          "format": {"duration": "62.375"}
        }
      ''');

      expect(result, isNotNull);
      expect(result!.duration, const Duration(milliseconds: 62375));
      expect(result.videoCodec, 'h264');
      expect(result.hasVideo, isTrue);
      expect(result.hasAudio, isTrue);
    });

    test('parses the Windows ffmpeg header fallback', () {
      final result = BilibiliMediaProbeResult.fromFfmpegHeader('''
Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'video.mp4':
  Duration: 01:02:03.45, start: 0.000000, bitrate: 1500 kb/s
  Stream #0:0[0x1](und): Video: hevc (Main), yuv420p, 1920x1080
  Stream #0:1[0x2](und): Audio: aac (LC), 48000 Hz, stereo
At least one output file must be specified
''');

      expect(result, isNotNull);
      expect(result!.duration, const Duration(milliseconds: 3723450));
      expect(result.videoCodec, 'hevc');
      expect(result.hasVideo, isTrue);
      expect(result.hasAudio, isTrue);
    });

    test('rejects incomplete output on every platform parser', () {
      expect(
        BilibiliMediaProbeResult.fromFfprobeJson(
          '{"streams": [], "format": {"duration": "0"}}',
        ),
        isNull,
      );
      expect(
        BilibiliMediaProbeResult.fromFfmpegHeader('Stream #0:0: Video: h264'),
        isNull,
      );
    });
  });
}
