import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/youtube_download/models/youtube_download_models.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_request_builder.dart';

void main() {
  group('YtDlpRequestBuilder', () {
    const builder = YtDlpRequestBuilder();

    const meta = VideoMeta(
      id: 'abc123',
      source: 'youtube',
      webpageUrl: 'https://www.youtube.com/watch?v=abc123',
      title: 'Test Video',
      uploader: 'Uploader',
      durationSeconds: 120,
      videoFormats: [
        VideoFormat(
          formatId: '137',
          ext: 'mp4',
          videoCodec: 'h264',
          width: 1920,
          height: 1080,
        ),
        VideoFormat(
          formatId: '248',
          ext: 'webm',
          videoCodec: 'vp9',
          width: 1920,
          height: 1080,
        ),
      ],
      audioFormats: [
        AudioFormat(
          formatId: '140',
          ext: 'm4a',
          audioCodec: 'aac',
          bitrate: 128,
          isDefaultTrack: true,
          language: 'zh-CN',
        ),
        AudioFormat(
          formatId: '251',
          ext: 'webm',
          audioCodec: 'opus',
          bitrate: 160,
          language: 'en',
        ),
      ],
      subtitles: [SubtitleTrack(languageCode: 'zh-CN', displayName: '中文')],
      recommendedVideoFormatId: '137',
      recommendedAudioFormatId: '140',
      recommendedSubtitleLanguages: ['zh-CN'],
    );

    test('buildYoutubeExtractorArgs composes youtube args', () {
      const config = DownloadSessionConfig(
        enabledPlayerClients: ['tv_embedded', 'mweb'],
        visitorData: 'visitor-123',
        poTokens: [
          PoTokenConfig(client: 'web', context: 'gvs', token: 'token-abc'),
        ],
      );

      final extractorArgs = builder.buildYoutubeExtractorArgs(config);

      expect(extractorArgs, contains('youtube:'));
      expect(extractorArgs, contains('player_client=tv_embedded,mweb'));
      expect(extractorArgs, contains('visitor_data=visitor-123'));
      expect(extractorArgs, contains('po_token=web.gvs+token-abc'));
    });

    test(
      'build request for video download contains common and format args',
      () {
        const selection = DownloadSelection(
          selectedVideoFormatId: '137',
          selectedAudioFormatIds: ['140'],
          selectedSubtitleTrackKeys: ['zh-CN|manual'],
          subtitleLanguages: ['zh-CN'],
          writeSubtitles: true,
          outputContainer: 'mkv',
        );
        const config = DownloadSessionConfig(
          useCookies: true,
          cookiesFilePath: 'C:/cookies.txt',
          useCustomUserAgent: true,
          userAgent: 'UA-123',
          useProxy: true,
          proxy: 'http://127.0.0.1:7890',
          retries: 3,
          fragmentRetries: 5,
          concurrentFragments: 2,
          rateLimit: '2M',
        );

        final request = builder.build(
          taskId: 'task-1',
          url: meta.webpageUrl,
          meta: meta,
          selection: selection,
          sessionConfig: config,
          outputDir: 'C:/downloads',
        );

        expect(request.args, contains('--no-warnings'));
        expect(request.args, contains('--cookies'));
        expect(request.args, contains('C:/cookies.txt'));
        expect(request.args, contains('--proxy'));
        expect(request.args, contains('http://127.0.0.1:7890'));
        expect(request.args, contains('--write-subs'));
        expect(request.args, contains('--sub-langs'));
        expect(request.args, contains('zh-CN'));
        expect(request.args, contains('--embed-subs'));
        expect(request.args, contains('--paths'));
        expect(request.args, contains('C:/downloads'));
        expect(request.args, contains('-f'));
        expect(request.args, contains('137+140'));
        expect(request.debugContext['resolvedVideoFormatId'], '137');
        expect(request.debugContext['resolvedAudioFormatIds'], ['140']);
        expect(request.debugContext['resolvedSubtitleTrackKeys'], [
          'zh-CN|manual',
        ]);
        expect(request.debugContext['outputContainer'], 'mkv');
      },
    );

    test(
      'build request includes path markers and extractor args in debug context',
      () {
        const selection = DownloadSelection(
          selectedVideoFormatId: '137',
          selectedAudioFormatIds: ['140'],
          outputContainer: 'mkv',
        );
        const config = DownloadSessionConfig(
          enabledPlayerClients: ['mweb'],
          visitorData: 'visitor-xyz',
        );

        final request = builder.build(
          taskId: 'task-marker',
          url: meta.webpageUrl,
          meta: meta,
          selection: selection,
          sessionConfig: config,
          outputDir: 'C:/downloads',
        );

        expect(request.args, containsAll(['--print']));
        expect(
          request.args,
          contains('before_dl:__YTDLP_BEFORE_DL__:%(filepath,_filename|)s'),
        );
        expect(
          request.args,
          contains('after_move:__YTDLP_AFTER_MOVE__:%(filepath,_filename|)s'),
        );
        expect(request.args, contains('--extractor-args'));
        expect(
          request.debugContext['extractorArgs'],
          'youtube:player_client=mweb;visitor_data=visitor-xyz',
        );
      },
    );

    test('build request for audio only enables extract audio when needed', () {
      const selection = DownloadSelection(
        audioOnly: true,
        selectedAudioFormatIds: ['140'],
        outputContainer: 'mp3',
      );

      final request = builder.build(
        taskId: 'task-2',
        url: meta.webpageUrl,
        meta: meta,
        selection: selection,
        sessionConfig: DownloadSessionConfig.defaults(),
        outputDir: 'C:/downloads',
      );

      expect(request.args, contains('-f'));
      expect(request.args, contains('140'));
      expect(request.args, contains('--extract-audio'));
      expect(request.args, contains('--audio-format'));
      expect(request.args, contains('mp3'));
    });

    test('build request falls back to recommended formats and subtitles', () {
      final request = builder.build(
        taskId: 'task-3',
        url: meta.webpageUrl,
        meta: meta,
        selection: const DownloadSelection(
          writeSubtitles: true,
          outputContainer: 'mkv',
        ),
        sessionConfig: DownloadSessionConfig.defaults(),
        outputDir: 'C:/downloads',
      );

      expect(request.args, contains('137+140'));
      expect(request.args, contains('--sub-langs'));
      expect(request.args, contains('zh-CN'));
      expect(request.debugContext['resolvedSubtitleLanguages'], ['zh-CN']);
    });

    test(
      'build request prefers direct muxed video when no audio track is explicitly selected',
      () {
        const muxedMeta = VideoMeta(
          id: 'muxed-1',
          source: 'youtube',
          webpageUrl: 'https://www.youtube.com/watch?v=muxed-1',
          title: 'Muxed Video',
          uploader: 'Uploader',
          videoFormats: [
            VideoFormat(
              formatId: '22',
              ext: 'mp4',
              videoCodec: 'h264',
              audioCodec: 'aac',
              height: 720,
              hasAudio: true,
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
          recommendedVideoFormatId: '22',
          recommendedAudioFormatId: '140',
        );

        final request = builder.build(
          taskId: 'task-muxed',
          url: muxedMeta.webpageUrl,
          meta: muxedMeta,
          selection: const DownloadSelection(outputContainer: 'mkv'),
          sessionConfig: DownloadSessionConfig.defaults(),
          outputDir: 'C:/downloads',
        );

        final formatIndex = request.args.indexOf('-f');
        expect(formatIndex, greaterThanOrEqualTo(0));
        expect(request.args[formatIndex + 1], '22');
      },
    );

    test('build request supports compatibility mode and remove audio', () {
      final request = builder.build(
        taskId: 'task-4',
        url: meta.webpageUrl,
        meta: meta,
        selection: const DownloadSelection(
          selectedVideoFormatId: '248',
          selectedAudioFormatIds: ['251'],
          outputContainer: 'mkv',
          enableCompatibilityMode: true,
          removeAudio: true,
        ),
        sessionConfig: DownloadSessionConfig.defaults(),
        outputDir: 'C:/downloads',
      );

      expect(request.args, contains('--merge-output-format'));
      expect(request.args, contains('mkv'));
      expect(request.args, contains('--postprocessor-args'));
      expect(request.args, contains('ffmpeg:-an'));
    });

    test('embed subtitles also enables subtitle writing when available', () {
      final request = builder.build(
        taskId: 'task-5',
        url: meta.webpageUrl,
        meta: meta,
        selection: const DownloadSelection(
          embedSubtitles: true,
          outputContainer: 'mkv',
        ),
        sessionConfig: DownloadSessionConfig.defaults(),
        outputDir: 'C:/downloads',
      );

      expect(request.args, contains('--write-subs'));
      expect(request.args, contains('--embed-subs'));
      expect(request.args, contains('--sub-format'));
    });

    test(
      'selected automatic subtitle tracks enable auto subtitle download',
      () {
        const metaWithAuto = VideoMeta(
          id: 'auto-sub-1',
          source: 'youtube',
          webpageUrl: 'https://www.youtube.com/watch?v=auto-sub-1',
          title: 'Auto Sub Video',
          uploader: 'Uploader',
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
          subtitles: [
            SubtitleTrack(languageCode: 'zh-CN', displayName: '中文'),
            SubtitleTrack(
              languageCode: 'en',
              displayName: 'English (自动)',
              isAutoGenerated: true,
            ),
          ],
          recommendedVideoFormatId: '137',
          recommendedAudioFormatId: '140',
        );

        final request = builder.build(
          taskId: 'task-7',
          url: metaWithAuto.webpageUrl,
          meta: metaWithAuto,
          selection: const DownloadSelection(
            selectedSubtitleTrackKeys: ['zh-CN|manual', 'en|auto'],
            subtitleLanguages: ['zh-CN', 'en'],
            outputContainer: 'mkv',
          ),
          sessionConfig: DownloadSessionConfig.defaults(),
          outputDir: 'C:/downloads',
        );

        expect(request.args, contains('--write-subs'));
        expect(request.args, contains('--write-auto-subs'));
        expect(request.args, contains('--embed-subs'));
        expect(request.debugContext['resolvedSubtitleTrackKeys'], [
          'zh-CN|manual',
          'en|auto',
        ]);
      },
    );

    test('youtube extractor args ignore empty clients and disabled tokens', () {
      const config = DownloadSessionConfig(
        enabledPlayerClients: ['mweb', ' ', 'mweb', 'tv_embedded'],
        visitorData: 'visitor-456',
        poTokens: [
          PoTokenConfig(client: 'web', context: 'gvs', token: 'token-enabled'),
          PoTokenConfig(
            client: 'web',
            context: 'player',
            token: 'token-disabled',
            enabled: false,
          ),
        ],
      );

      final extractorArgs = builder.buildYoutubeExtractorArgs(config);

      expect(
        extractorArgs,
        'youtube:player_client=mweb,tv_embedded;visitor_data=visitor-456;po_token=web.gvs+token-enabled',
      );
    });

    test('non-youtube source does not inject extractor args', () {
      const genericMeta = VideoMeta(
        id: 'vimeo-1',
        source: 'vimeo',
        webpageUrl: 'https://vimeo.com/demo',
        title: 'Generic',
        uploader: 'Uploader',
        videoFormats: [
          VideoFormat(
            formatId: 'hls-1080',
            ext: 'mp4',
            videoCodec: 'h264',
            height: 1080,
          ),
        ],
      );

      final request = builder.build(
        taskId: 'task-6',
        url: genericMeta.webpageUrl,
        meta: genericMeta,
        selection: const DownloadSelection(outputContainer: 'mkv'),
        sessionConfig: const DownloadSessionConfig(
          enabledPlayerClients: ['tv_embedded'],
          visitorData: 'should-not-apply',
        ),
        outputDir: 'C:/downloads',
      );

      expect(request.args, isNot(contains('--extractor-args')));
      expect(request.debugContext['extractorArgs'], isNull);
    });
  });
}
