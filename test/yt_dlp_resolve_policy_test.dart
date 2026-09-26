import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/youtube_download/models/youtube_download_models.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_download_service.dart';

void main() {
  group('dumpSingleJsonHasThumbnailKey', () {
    test('matches a thumbnail field and ignores the thumbnails array key', () {
      expect(
        dumpSingleJsonHasThumbnailKey(
          '{"thumbnails":[{"url":"https://i.ytimg.com/vi/abc/hqdefault.jpg"}]}',
        ),
        isFalse,
      );
      expect(
        dumpSingleJsonHasThumbnailKey(
          '{"thumbnail":"https://i.ytimg.com/vi/abc/hqdefault.jpg","thumbnails":[]}',
        ),
        isTrue,
      );
    });
  });

  group('shouldRetryResolveWithSaferConfig', () {
    test('does not retry when the safer session is the same', () {
      expect(
        shouldRetryResolveWithSaferConfig(
          errorText: 'HTTP Error 403: Forbidden',
          sessionConfigsDiffer: false,
        ),
        isFalse,
      );
      expect(
        shouldRetryResolveWithSaferConfig(
          errorText: '已拿到元数据，但没有可用格式',
          sessionConfigsDiffer: false,
          noUsableFormat: true,
        ),
        isFalse,
      );
    });

    test('does not retry timeouts or transport failures', () {
      for (final errorText in [
        'TimeoutException: 桌面端解析超时',
        'yt-dlp resolve timed out',
        'network is unreachable',
        'SocketException: connection failed',
        'proxy connection refused',
      ]) {
        expect(
          shouldRetryResolveWithSaferConfig(
            errorText: errorText,
            sessionConfigsDiffer: true,
            noUsableFormat: errorText.contains('元数据'),
          ),
          isFalse,
          reason: errorText,
        );
      }
    });

    test('does not retry on broad extractor wording', () {
      for (final errorText in [
        'ERROR: Unable to download webpage',
        'youtube extractor failed',
        'requested format is not available',
        'extract info failed',
        'metadata 解析失败',
        '已拿到元数据，但字段不完整',
      ]) {
        expect(
          shouldRetryResolveWithSaferConfig(
            errorText: errorText,
            sessionConfigsDiffer: true,
          ),
          isFalse,
          reason: errorText,
        );
      }
    });

    test('retries player client, visitor data, po token, and auth blocks', () {
      for (final errorText in [
        'player_client android was rejected',
        'Unsupported player client',
        'visitor_data is invalid',
        'bad visitor data',
        'po_token rejected',
        'missing po token',
        'Sign in to confirm you’re not a bot',
        'HTTP Error 403: Forbidden',
        'Unable to extract player response',
      ]) {
        expect(
          shouldRetryResolveWithSaferConfig(
            errorText: errorText,
            sessionConfigsDiffer: true,
          ),
          isTrue,
          reason: errorText,
        );
      }
    });

    test('retries an explicit empty format result', () {
      expect(
        shouldRetryResolveWithSaferConfig(
          errorText: const YtDlpResolveNoFormatException().toString(),
          sessionConfigsDiffer: true,
          noUsableFormat: true,
        ),
        isTrue,
      );
    });

    test('thumbnail requests identify the watch page to signed CDNs', () {
      final headers = ytDlpThumbnailRequestHeaders(
        webpageUrl: 'https://example.com/watch?v=abc',
      );
      expect(headers['User-Agent'], contains('Chrome/'));
      expect(headers['Referer'], 'https://example.com/watch?v=abc');
      expect(
        ytDlpThumbnailRequestHeaders(
          webpageUrl: 'not a url',
        ).containsKey('Referer'),
        isFalse,
      );
    });
  });

  test('resolve placeholders are omitted from persisted task state', () {
    const placeholder = YtDlpTaskRecord(
      taskId: 'resolving',
      sourceUrl: 'https://youtu.be/ajtJvlVCq_U',
      selection: DownloadSelection(),
      createdAtIso: '2026-09-26T00:00:00.000',
      status: YtDlpTaskStatus.resolving,
      statusMessage: '正在获取画质和信息，请稍候',
    );
    const kept = YtDlpTaskRecord(
      taskId: 'pending',
      sourceUrl: 'https://youtu.be/kept',
      selection: DownloadSelection(),
      createdAtIso: '2026-09-26T00:00:00.000',
    );

    final decoded = decodeYtDlpTaskState(
      encodeYtDlpTaskStateV2([placeholder, kept]),
    );

    expect(decoded.map((task) => task.taskId), ['pending']);
  });
}
