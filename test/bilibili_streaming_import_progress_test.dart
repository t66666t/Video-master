import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'streaming import reports coarse stages and always clears active state',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      SettingsService().resetForTest();
      final root = await Directory.systemTemp.createTemp(
        'bilibili_streaming_import_progress_',
      );
      final originalPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      SettingsService().largeDataRootPath = root.path;
      addTearDown(() async {
        PathProviderPlatform.instance = originalPathProvider;
        SettingsService().resetForTest();
        if (await root.exists()) await root.delete(recursive: true);
      });

      final library = LibraryService();
      await library.init();
      final api = _ControlledMetadataApi();
      final service = BilibiliDownloadService(apiService: api);
      addTearDown(service.shutdown);
      final task = _streamingTask(cid: 101);
      final episode = task.videos.single.episodes.single;
      final observedStages = <String>[];
      service.addListener(() {
        final status = episode.downloadSpeed;
        if (status != null && !observedStages.contains(status)) {
          observedStages.add(status);
        }
      });

      final import = service.importParsedStreamingTaskToLibrary(library, task);
      await api.requestStarted.future;

      expect(service.isStreamingImporting(episode), isTrue);
      expect(episode.downloadSpeed, '正在准备视频信息...');

      final duplicateCount = await service.importParsedStreamingTaskToLibrary(
        library,
        task,
      );
      expect(duplicateCount, 0);

      api.metadata.complete(const BilibiliPlayerMetadata());
      expect(await import, 1);
      expect(
        observedStages,
        containsAllInOrder(<String>[
          '正在准备视频信息...',
          '正在导出附加内容...',
          '正在写入媒体库...',
          '已导出在线播放条目',
        ]),
      );
      expect(service.isStreamingImporting(episode), isFalse);
      expect(episode.status, DownloadStatus.completed);
      expect(episode.downloadSpeed, '已导出在线播放条目');

      final failingApi = _ControlledMetadataApi();
      final failingService = BilibiliDownloadService(apiService: failingApi);
      addTearDown(failingService.shutdown);
      final failingTask = _streamingTask(cid: 202);
      final failingEpisode = failingTask.videos.single.episodes.single;
      final failingImport = failingService.importParsedStreamingTaskToLibrary(
        library,
        failingTask,
      );
      await failingApi.requestStarted.future;
      failingApi.metadata.completeError(StateError('metadata failed'));

      expect(await failingImport, 0);
      expect(failingService.isStreamingImporting(failingEpisode), isFalse);
      expect(failingEpisode.status, DownloadStatus.failed);
      expect(failingEpisode.downloadSpeed, isNull);
      expect(failingEpisode.error, contains('metadata failed'));
    },
  );
}

BilibiliDownloadTask _streamingTask({required int cid}) {
  final page = BilibiliPage(
    cid: cid,
    page: 1,
    part: 'Part $cid',
    duration: 60,
    bvid: 'BV1xx411c7mD',
    aid: '123',
  );
  final info = BilibiliVideoInfo(
    title: 'Video $cid',
    desc: '',
    pic: '',
    bvid: 'BV1xx411c7mD',
    aid: '123',
    ownerName: '',
    ownerMid: '',
    pubDate: 0,
    pages: <BilibiliPage>[page],
  );
  return BilibiliDownloadTask(
    singleVideoInfo: info,
    isStreamingImport: true,
    videos: <BilibiliVideoItem>[
      BilibiliVideoItem(
        videoInfo: info,
        episodes: <BilibiliDownloadEpisode>[
          BilibiliDownloadEpisode(
            page: page,
            bvid: info.bvid,
            isSelected: true,
          ),
        ],
      ),
    ],
  );
}

class _ControlledMetadataApi extends BilibiliApiService {
  final Completer<void> requestStarted = Completer<void>();
  final Completer<BilibiliPlayerMetadata> metadata =
      Completer<BilibiliPlayerMetadata>();

  @override
  Future<BilibiliPlayerMetadata> fetchPlayerMetadata(
    String bvid,
    int cid, {
    String? aid,
    bool skipAiSubtitles = false,
    int durationSeconds = 0,
  }) {
    if (!requestStarted.isCompleted) requestStarted.complete();
    return metadata.future;
  }

  @override
  Future<String> fetchDanmakuXml(int cid) async => '<i></i>';

  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async =>
      null;
}

class _FakePathProvider extends PathProviderPlatform {
  final String rootPath;

  _FakePathProvider(this.rootPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;

  @override
  Future<String?> getTemporaryPath() async => rootPath;
}
