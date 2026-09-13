import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/models/subtitle_output_path_strategy.dart';
import 'package:video_player_app/services/bcut_asr_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('HTTP risk control is distinct from a disconnected network', () {
    final risk = BcutAsrService.classifyDioException(
      DioException(
        requestOptions: RequestOptions(path: '/task'),
        response: Response<void>(
          requestOptions: RequestOptions(path: '/task'),
          statusCode: 412,
        ),
      ),
    );
    final offline = BcutAsrService.classifyDioException(
      DioException(
        requestOptions: RequestOptions(path: '/task'),
        type: DioExceptionType.connectionError,
        error: const SocketException('offline'),
      ),
    );

    expect(risk.kind, BcutAsrFailureKind.riskControl);
    expect(risk.isRiskControl, isTrue);
    expect(offline.kind, BcutAsrFailureKind.networkUnavailable);
    expect(offline.isRiskControl, isFalse);
  });

  test(
    'ASR streams chunks and recovers from commit code 139201 with alternate ETags',
    () async {
      final root = await Directory.systemTemp.createTemp('asr_stream_upload_');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final audio = File('${root.path}${Platform.pathSeparator}audio.m4a');
      await audio.writeAsBytes(List<int>.generate(16, (index) => index));

      final dio = Dio();
      Uint8List? uploadedChunk;
      final committedEtags = <Object?>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            Object data;
            var headers = Headers();
            if (options.method == 'PUT') {
              uploadedChunk = options.data as Uint8List;
              data = <String, Object?>{};
              headers = Headers.fromMap({
                'etag': ['"test-etag"'],
              });
            } else if (options.path.endsWith('/resource/create/complete')) {
              final requestData = options.data as Map<String, dynamic>;
              committedEtags.add(requestData['Etags']);
              data = committedEtags.length == 1
                  ? {'code': 139201, 'message': '第三方服务异常'}
                  : {
                      'code': 0,
                      'data': {'download_url': 'https://upload.test/audio'},
                    };
            } else if (options.path.endsWith('/resource/create')) {
              data = {
                'code': 0,
                'data': {
                  'upload_urls': ['https://upload.test/part'],
                  'per_size': 16,
                  'in_boss_key': 'boss',
                  'resource_id': 'resource',
                  'upload_id': 'upload',
                },
              };
            } else if (options.path.endsWith('/task/result')) {
              data = {
                'data': {
                  'state': 4,
                  'result': jsonEncode({
                    'utterances': [
                      {'start_time': 0, 'end_time': 1000, 'transcript': 'ok'},
                    ],
                  }),
                },
              };
            } else {
              data = {
                'code': 0,
                'data': {'task_id': 'task'},
              };
            }
            handler.resolve(
              Response<Object>(
                requestOptions: options,
                data: data,
                headers: headers,
                statusCode: 200,
              ),
            );
          },
        ),
      );

      final subtitles = await BcutAsrService(
        dio: dio,
      ).transcribeAudio(audio.path);
      expect(uploadedChunk, orderedEquals(List<int>.generate(16, (i) => i)));
      expect(committedEtags, ['test-etag', '["test-etag"]']);
      expect(subtitles.single.text, 'ok');
    },
  );

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
    'pausing individual running and waiting tasks leaves others scheduled',
    () async {
      final manager = TranscriptionManager();
      addTearDown(manager.dispose);
      for (final name in ['first', 'second', 'third']) {
        await manager.startExternalTranscription(
          'D:/missing/$name.m4a',
          outputPathStrategy: SubtitleOutputPathStrategy.sameAsVideo,
        );
      }
      final keys = manager.getQueueSnapshot().map((t) => t.mediaKey).toList();
      final running = <String>[];
      manager.addListener(() {
        final active = manager.currentVideoPath;
        if (!manager.isProcessing ||
            active == null ||
            running.contains(active)) {
          return;
        }
        running.add(active);
        manager.pauseTask(
          manager
              .getQueueSnapshot()
              .firstWhere((t) => t.videoPath == active)
              .mediaKey,
        );
      });
      manager.startAllTasks();
      expect(manager.pauseTask(keys[1]), isTrue);
      for (var i = 0; i < 100 && manager.isQueueRunning; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(manager.isQueueRunning, isFalse);
      expect(running, ['D:/missing/first.m4a', 'D:/missing/third.m4a']);
      expect(manager.getQueueSnapshot().map((t) => t.mediaKey), keys);
      expect(
        manager.getQueueSnapshot().every(
          (t) => t.status == TranscriptionStatus.idle && !t.isStarted,
        ),
        isTrue,
      );
      expect(manager.pauseTask('missing'), isFalse);
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
    'start all retries failures together with paused tasks in original order',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'transcription_order_',
      );
      final originalPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      addTearDown(() async {
        PathProviderPlatform.instance = originalPathProvider;
        if (await root.exists()) await root.delete(recursive: true);
      });

      Map<String, Object?> job(String id, int createdAt) => {
        'videoPath': '${root.path}${Platform.pathSeparator}$id.m4a',
        'videoId': id,
        'mediaKey': 'id:$id',
        'isExternal': false,
        'createdAt': createdAt,
        'displayName': id,
        'durationLabel': '00:01',
      };

      final cacheFile = File(
        '${root.path}${Platform.pathSeparator}transcription_queue_cache.json',
      );
      await cacheFile.writeAsString(
        jsonEncode({
          'version': 2,
          'queue': [job('first', 1), job('third', 3)],
          'active': null,
          'completed': <Object>[],
          'failed': [
            {...job('second', 2), 'message': 'failed'},
          ],
          'taskOrder': ['id:first', 'id:second', 'id:third'],
        }),
      );

      final manager = TranscriptionManager();
      addTearDown(manager.dispose);
      await manager.initialize();

      final running = <String>[];
      manager.addListener(() {
        final id = manager.currentVideoId;
        if (!manager.isProcessing || id == null || running.contains(id)) return;
        running.add(id);
        manager.pauseTask('id:$id');
      });
      manager.startAllTasks();
      for (var i = 0; i < 100 && manager.isQueueRunning; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(manager.isQueueRunning, isFalse);
      expect(running, ['first', 'second', 'third']);
      expect(manager.getQueueSnapshot().map((t) => t.mediaKey), [
        'id:first',
        'id:second',
        'id:third',
      ]);
      expect(
        manager.getQueueSnapshot().every(
          (t) => t.status == TranscriptionStatus.idle,
        ),
        isTrue,
      );
    },
  );

  test(
    'failed tasks retain their original row and retry starts immediately',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'transcription_order_',
      );
      final originalPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      addTearDown(() async {
        PathProviderPlatform.instance = originalPathProvider;
        if (await root.exists()) await root.delete(recursive: true);
      });

      Map<String, Object?> job(String id, int createdAt) => {
        'videoPath': '${root.path}${Platform.pathSeparator}$id.m4a',
        'videoId': id,
        'mediaKey': 'id:$id',
        'isExternal': false,
        'createdAt': createdAt,
        'displayName': id,
        'durationLabel': '00:01',
      };

      final cacheFile = File(
        '${root.path}${Platform.pathSeparator}transcription_queue_cache.json',
      );
      await cacheFile.writeAsString(
        jsonEncode({
          'version': 2,
          'queue': [job('first', 1), job('third', 3)],
          'active': null,
          'completed': <Object>[],
          'failed': [
            {...job('second', 2), 'message': 'failed'},
          ],
          'taskOrder': ['id:first', 'id:second', 'id:third'],
        }),
      );

      final manager = TranscriptionManager();
      addTearDown(manager.dispose);
      await manager.initialize();
      expect(manager.getQueueSnapshot().map((task) => task.mediaKey), [
        'id:first',
        'id:second',
        'id:third',
      ]);

      expect(manager.retryTask('id:second'), isTrue);
      expect(
        manager.isTaskStarted('id:second') || manager.isProcessing,
        isTrue,
      );
      expect(manager.getQueueSnapshot().map((task) => task.mediaKey), [
        'id:first',
        'id:second',
        'id:third',
      ]);
      manager.pauseAllTasks();
    },
  );

  test(
    'auto removal works without a page and respects switch cancellation',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({
        'batchSubtitleAutoDelete': false,
      });
      final settings = SettingsService();
      settings.resetForTest();
      await settings.init();
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

      final manager = TranscriptionManager(settings: settings);
      await manager.initialize();
      expect(manager.getQueueSnapshot(), hasLength(1));
      await settings.updateBatchSubtitleAutoDelete(true);
      expect(manager.pendingCompletedRemovals, contains('id:finished'));
      await settings.updateBatchSubtitleAutoDelete(false);
      expect(manager.pendingCompletedRemovals, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      expect(manager.getQueueSnapshot(), hasLength(1));
      await settings.updateBatchSubtitleAutoDelete(true);
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      expect(manager.getQueueSnapshot(), isEmpty);
      expect(
        manager.getGeneratedSrtPathForVideo(
          r'D:\media-cache\finished.mp4',
          videoId: 'finished',
        ),
        srtFile.path,
      );
      expect(await srtFile.exists(), isTrue);
      await manager.shutdown();
      manager.dispose();
      final restored = TranscriptionManager(settings: settings);
      await restored.initialize();
      expect(restored.getQueueSnapshot(), isEmpty);
      await restored.shutdown();
      restored.dispose();
      await settings.updateBatchSubtitleAutoDelete(false);
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
