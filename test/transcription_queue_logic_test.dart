import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/services/bcut_asr_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';

void main() {
  test(
    'batch queue preserves the internal media card title and duration',
    () async {
      final manager = TranscriptionManager();
      addTearDown(manager.dispose);

      await manager.startTranscription(
        r'D:\media-cache\9f28a71c.mp4',
        videoId: 'video-1',
        videoTitle: '媒体卡片中的标题',
        videoDuration: '01:23',
      );

      final task = manager.getQueueSnapshot().single;
      expect(task.videoName, '媒体卡片中的标题');
      expect(task.videoDuration, '01:23');
    },
  );

  test(
    'a queued task can always be removed and no longer blocks the queue',
    () async {
      final manager = TranscriptionManager();
      addTearDown(manager.dispose);

      await manager.startTranscription(
        r'D:\media-cache\first.mp4',
        videoId: 'first',
        videoTitle: '第一个任务',
      );
      await manager.startTranscription(
        r'D:\media-cache\second.mp4',
        videoId: 'second',
        videoTitle: '第二个任务',
      );

      expect(manager.removeFromQueue('id:first'), isTrue);
      expect(manager.getQueueSnapshot().map((task) => task.mediaKey), [
        'id:second',
      ]);
    },
  );

  test(
    'ASR exits immediately when cancellation was already requested',
    () async {
      final cancelToken = CancelToken()..cancel('test cancellation');

      await expectLater(
        BcutAsrService().transcribeAudio(
          r'D:\does-not-need-to-exist.m4a',
          cancelToken: cancelToken,
        ),
        throwsA(
          isA<DioException>().having(
            (error) => CancelToken.isCancel(error),
            'is cancellation',
            isTrue,
          ),
        ),
      );
    },
  );

  test(
    'an interrupted 0 percent task recovers as removable after restart',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'transcription_queue_',
      );
      final originalPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      addTearDown(() async {
        PathProviderPlatform.instance = originalPathProvider;
        if (await root.exists()) await root.delete(recursive: true);
      });

      final cacheFile = File(
        '${root.path}${Platform.pathSeparator}transcription_queue_cache.json',
      );
      await cacheFile.writeAsString(
        jsonEncode({
          'version': 2,
          'queue': <Object>[],
          'active': {
            'videoPath': r'D:\media-cache\stuck.mp4',
            'videoId': 'stuck',
            'mediaKey': 'id:stuck',
            'isExternal': false,
            'createdAt': 1,
            'displayName': '重启前卡住的任务',
            'durationLabel': '02:00',
          },
          'completed': <Object>[],
          'failed': <Object>[],
          'startedKeys': ['id:stuck'],
        }),
      );

      final manager = TranscriptionManager();
      addTearDown(manager.dispose);
      await manager.initialize();

      final recovered = manager.getQueueSnapshot().single;
      expect(recovered.status, TranscriptionStatus.error);
      expect(recovered.statusMessage, contains('上次运行异常中断'));
      expect(manager.removeFromQueue(recovered.mediaKey), isTrue);
      expect(manager.getQueueSnapshot(), isEmpty);
    },
  );

  test(
    'a generated subtitle notification is claimed and persisted once',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'transcription_notification_',
      );
      final originalPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      addTearDown(() async {
        PathProviderPlatform.instance = originalPathProvider;
        if (await root.exists()) await root.delete(recursive: true);
      });

      final srtFile = File(
        '${root.path}${Platform.pathSeparator}generated.srt',
      );
      await srtFile.writeAsString('1\n00:00:00,000 --> 00:00:01,000\nhello\n');
      final cacheFile = File(
        '${root.path}${Platform.pathSeparator}transcription_queue_cache.json',
      );
      await cacheFile.writeAsString(
        jsonEncode({
          'version': 2,
          'queue': <Object>[],
          'active': null,
          'completed': [
            {
              'videoPath': r'D:\media-cache\finished.mp4',
              'videoId': 'finished',
              'mediaKey': 'id:finished',
              'isExternal': false,
              'createdAt': 1,
              'displayName': 'finished.mp4',
              'durationLabel': '00:01',
              'resultSrtPath': srtFile.path,
            },
          ],
          'failed': <Object>[],
          'startedKeys': <Object>[],
        }),
      );

      final manager = TranscriptionManager();
      await manager.initialize();
      expect(
        manager.consumeResultNotificationForVideo(
          r'D:\media-cache\finished.mp4',
          videoId: 'finished',
        ),
        isTrue,
      );
      expect(
        manager.consumeResultNotificationForVideo(
          r'D:\media-cache\finished.mp4',
          videoId: 'finished',
        ),
        isFalse,
      );
      await manager.shutdown();
      manager.dispose();

      final restoredManager = TranscriptionManager();
      await restoredManager.initialize();
      expect(
        restoredManager.consumeResultNotificationForVideo(
          r'D:\media-cache\finished.mp4',
          videoId: 'finished',
        ),
        isFalse,
      );
      await restoredManager.shutdown();
      restoredManager.dispose();
    },
  );
}

class _FakePathProvider extends PathProviderPlatform {
  final String rootPath;

  _FakePathProvider(this.rootPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;

  @override
  Future<String?> getTemporaryPath() async => rootPath;
}
