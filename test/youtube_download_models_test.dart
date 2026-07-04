import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/youtube_download/models/youtube_download_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';

void main() {
  group('youtube download models', () {
    test('DownloadSessionConfig defaults do not force player clients', () {
      final config = DownloadSessionConfig.defaults();

      expect(config.enabledPlayerClients, isEmpty);
    });

    test('DownloadSessionConfig serializes and deserializes', () {
      const config = DownloadSessionConfig(
        useCookies: true,
        cookiesFilePath: 'C:/cookies.txt',
        useCustomUserAgent: true,
        userAgent: 'UA',
        useProxy: true,
        proxy: 'http://127.0.0.1:7890',
        socketTimeoutSeconds: 30,
        retries: 3,
        fragmentRetries: 5,
        concurrentFragments: 2,
        rateLimit: '2M',
        forceIpv4: true,
        enabledPlayerClients: ['tv_embedded', 'mweb'],
        poTokens: [PoTokenConfig(client: 'web', context: 'gvs', token: 'abc')],
        visitorData: 'visitor-data',
        debugLoggingEnabled: true,
        outputDirectory: 'C:/downloads',
      );

      final decoded = DownloadSessionConfig.fromJson(config.toJson());

      expect(decoded.useCookies, isTrue);
      expect(decoded.cookiesFilePath, 'C:/cookies.txt');
      expect(decoded.enabledPlayerClients, ['tv_embedded', 'mweb']);
      expect(decoded.poTokens.single.token, 'abc');
      expect(decoded.outputDirectory, 'C:/downloads');
    });

    test('DownloadSessionConfig copyWith allows clearing nullable fields', () {
      const config = DownloadSessionConfig(
        useCookies: true,
        cookiesFilePath: 'C:/cookies.txt',
        useCustomUserAgent: true,
        userAgent: 'UA',
        useProxy: true,
        proxy: 'http://127.0.0.1:7890',
        socketTimeoutSeconds: 30,
        retries: 3,
        fragmentRetries: 5,
        concurrentFragments: 2,
        rateLimit: '2M',
        visitorData: 'visitor-data',
        outputDirectory: 'C:/downloads',
      );

      final cleared = config.copyWith(
        cookiesFilePath: null,
        userAgent: null,
        proxy: null,
        socketTimeoutSeconds: null,
        retries: null,
        fragmentRetries: null,
        concurrentFragments: null,
        rateLimit: null,
        visitorData: null,
        outputDirectory: null,
      );

      expect(cleared.cookiesFilePath, isNull);
      expect(cleared.userAgent, isNull);
      expect(cleared.proxy, isNull);
      expect(cleared.socketTimeoutSeconds, isNull);
      expect(cleared.retries, isNull);
      expect(cleared.fragmentRetries, isNull);
      expect(cleared.concurrentFragments, isNull);
      expect(cleared.rateLimit, isNull);
      expect(cleared.visitorData, isNull);
      expect(cleared.outputDirectory, isNull);
    });

    test('YtDlpTaskRecord encodes and decodes task list', () {
      const meta = VideoMeta(
        id: 'video-1',
        source: 'youtube',
        webpageUrl: 'https://youtube.com/watch?v=video-1',
        title: 'Video 1',
        uploader: 'Uploader',
        thumbnails: [
          ThumbnailInfo(url: 'https://example.com/thumb.jpg', width: 480),
        ],
        videoFormats: [
          VideoFormat(
            formatId: '137',
            ext: 'mp4',
            videoCodec: 'h264',
            height: 1080,
          ),
        ],
        audioFormats: [
          AudioFormat(
            formatId: '140',
            ext: 'm4a',
            audioCodec: 'aac',
            bitrate: 128,
          ),
        ],
      );

      final task =
          YtDlpTaskRecord.fromMeta(
            taskId: 'task-1',
            sourceUrl: meta.webpageUrl,
            sourceRef: const MediaSourceRef(
              value: 'https://youtube.com/watch?v=video-1',
              kind: MediaSourceKind.url,
            ),
            meta: meta,
            selection: const DownloadSelection(
              selectedVideoFormatId: '137',
              selectedAudioFormatIds: ['140'],
              outputContainer: 'mkv',
            ),
          ).copyWith(
            status: YtDlpTaskStatus.downloading,
            progress: 0.5,
            speedText: '1.2 MB/s',
            etaText: '00:10',
            statusMessage: '[youtube] video-1: Downloading webpage',
            stepMessages: const [
              '已加入下载队列',
              '[youtube] video-1: Downloading webpage',
            ],
            tempArtifactKey: 'video-1_temp_key',
            executionSessionConfig: const DownloadSessionConfig(
              useCookies: true,
              cookiesFilePath: 'C:/cookies.txt',
              enabledPlayerClients: ['mweb'],
            ),
          );

      final encoded = encodeTaskList([task]);
      final decoded = decodeTaskList(encoded);

      expect(decoded, hasLength(1));
      expect(decoded.single.taskId, 'task-1');
      expect(decoded.single.meta?.title, 'Video 1');
      expect(decoded.single.selection.selectedVideoFormatId, '137');
      expect(decoded.single.progress, 0.5);
      expect(decoded.single.speedText, '1.2 MB/s');
      expect(decoded.single.sourceRef?.value, 'https://youtube.com/watch?v=video-1');
      expect(decoded.single.sourceRef?.kind, MediaSourceKind.url);
      expect(
        decoded.single.statusMessage,
        '[youtube] video-1: Downloading webpage',
      );
      expect(decoded.single.stepMessages, [
        '已加入下载队列',
        '[youtube] video-1: Downloading webpage',
      ]);
      expect(decoded.single.tempArtifactKey, 'video-1_temp_key');
      expect(decoded.single.executionSessionConfig?.useCookies, isTrue);
      expect(decoded.single.executionSessionConfig?.enabledPlayerClients, [
        'mweb',
      ]);
    });

    test('YtDlpTaskRecord preserves fallback and failure history fields', () {
      final task = const YtDlpTaskRecord(
        taskId: 'task-fallback',
        sourceUrl: 'https://youtube.com/watch?v=fallback',
        sourceRef: MediaSourceRef(
          value: 'https://youtube.com/watch?v=fallback',
          kind: MediaSourceKind.url,
        ),
        selection: DownloadSelection(outputContainer: 'mkv'),
        createdAtIso: '2026-04-27T10:00:00.000Z',
        status: YtDlpTaskStatus.failed,
        failureType: YtDlpFailureType.authFailed,
        fallbackAttemptCount: 3,
        appliedFallbackSteps: [
          YtDlpFallbackStep.originalRetry,
          YtDlpFallbackStep.switchPlayerClient,
          YtDlpFallbackStep.enableCookies,
        ],
        executionSessionConfig: DownloadSessionConfig(
          useCookies: true,
          cookiesFilePath: 'C:/cookies.txt',
          enabledPlayerClients: ['web'],
        ),
        failureContext: DownloadFailureContext(
          url: 'https://youtube.com/watch?v=fallback',
          extractor: 'youtube',
          selectedPlayerClient: 'web',
          hasCookies: true,
          retryCount: 3,
          stderrTail: 'HTTP Error 403',
          exitCode: 1,
        ),
        completedAtIso: '2026-04-27T10:01:00.000Z',
        lastFailedAtIso: '2026-04-27T10:02:00.000Z',
      );

      final decoded = decodeTaskList(encodeTaskList([task])).single;

      expect(decoded.fallbackAttemptCount, 3);
      expect(decoded.appliedFallbackSteps, [
        YtDlpFallbackStep.originalRetry,
        YtDlpFallbackStep.switchPlayerClient,
        YtDlpFallbackStep.enableCookies,
      ]);
      expect(decoded.executionSessionConfig?.useCookies, isTrue);
      expect(decoded.failureContext?.selectedPlayerClient, 'web');
      expect(decoded.sourceRef?.value, 'https://youtube.com/watch?v=fallback');
      expect(decoded.completedAtIso, '2026-04-27T10:01:00.000Z');
      expect(decoded.lastFailedAtIso, '2026-04-27T10:02:00.000Z');
    });

    test('DownloadTaskEvent parses producedPaths payload', () {
      final event = DownloadTaskEvent.fromJson({
        'taskId': 'task-1',
        'type': 'task_step',
        'outputPath': '/tmp/output.mkv',
        'producedPaths': ['/tmp/output.mkv', '', '   ', '/tmp/subtitles.srt'],
        'message': 'Finalizing',
      });

      expect(event.taskId, 'task-1');
      expect(event.type, 'task_step');
      expect(event.outputPath, '/tmp/output.mkv');
      expect(event.producedPaths, ['/tmp/output.mkv', '/tmp/subtitles.srt']);
      expect(event.message, 'Finalizing');
    });
  });
}
