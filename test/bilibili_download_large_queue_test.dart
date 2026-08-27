import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/screens/bilibili_download_list_projection.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';

BilibiliVideoItem _video(String bvid, int episodeCount) {
  final pages = List.generate(
    episodeCount,
    (index) => BilibiliPage(
      cid: index + 1,
      page: index + 1,
      part: 'P${index + 1}',
      duration: 60,
      bvid: bvid,
      aid: bvid,
    ),
  );
  return BilibiliVideoItem(
    videoInfo: BilibiliVideoInfo(
      title: bvid,
      desc: '',
      pic: '',
      bvid: bvid,
      aid: bvid,
      ownerName: 'up',
      ownerMid: '1',
      pubDate: 0,
      pages: pages,
    ),
    episodes: [
      for (final page in pages) BilibiliDownloadEpisode(page: page, bvid: bvid),
    ],
  );
}

BilibiliDownloadTask _standaloneTask(int index) {
  final video = _video('BV$index', 1);
  return BilibiliDownloadTask(
    singleVideoInfo: video.videoInfo,
    videos: [video],
  );
}

void main() {
  test('500 个独立任务生成稳定的扁平行投影', () {
    final tasks = List.generate(500, _standaloneTask);

    final rows = BilibiliDownloadListProjection.build(tasks);

    expect(rows, hasLength(1000));
    expect(rows.whereType<BilibiliTaskHeaderRow>(), hasLength(500));
    expect(rows.whereType<BilibiliEpisodeRow>(), hasLength(500));
    expect(rows.last.isLastInTask, isTrue);
  });

  test('含 500 个视频的合集连续展开且折叠后只保留任务头', () {
    final videos = List.generate(500, (index) => _video('COL$index', 1));
    final task = BilibiliDownloadTask(
      collectionInfo: BilibiliCollectionInfo(
        title: '大型合集',
        cover: '',
        videos: videos.map((video) => video.videoInfo).toList(),
      ),
      videos: videos,
    );

    final expandedRows = BilibiliDownloadListProjection.build([task]);
    expect(expandedRows, hasLength(501));
    expect(expandedRows.first, isA<BilibiliTaskHeaderRow>());
    expect(expandedRows.last, isA<BilibiliEpisodeRow>());
    expect(expandedRows.last.isLastInTask, isTrue);

    task.isExpanded = false;
    final collapsedRows = BilibiliDownloadListProjection.build([task]);
    expect(collapsedRows, hasLength(1));
    expect(collapsedRows.single.isLastInTask, isTrue);
  });

  test('拖动投影会临时折叠全部顶层任务但不修改原展开状态', () {
    final first = _standaloneTask(1)..isExpanded = true;
    final second = _standaloneTask(2)..isExpanded = false;

    final rows = BilibiliDownloadListProjection.build([
      first,
      second,
    ], forceTasksCollapsed: true);

    expect(rows, hasLength(2));
    expect(rows, everyElement(isA<BilibiliTaskHeaderRow>()));
    expect(first.isExpanded, isTrue);
    expect(second.isExpanded, isFalse);
  });

  test('分P任务删除到只剩一P后按独立视频投影', () {
    final video = _video('BV-MULTIPART', 3);
    video.episodes.removeRange(1, video.episodes.length);
    final task = BilibiliDownloadTask(
      singleVideoInfo: video.videoInfo,
      videos: [video],
    );

    final rows = BilibiliDownloadListProjection.build([task]);

    expect(rows, hasLength(2));
    final episodeRow = rows.last as BilibiliEpisodeRow;
    expect(episodeRow.useSingleControls, isTrue);
  });

  test('单个分P进度更新不会改变其他分P或任务结构版本', () {
    final service = BilibiliDownloadService();
    addTearDown(service.dispose);
    final first = _standaloneTask(1);
    final second = _standaloneTask(2);
    service.replaceTasksForTesting([first, second]);
    final firstEpisode = first.videos.single.episodes.single;
    final secondEpisode = second.videos.single.episodes.single;
    final structureRevision = service.listStructureRevision;
    final firstTaskRevision = service.taskRevision(first.taskId);
    final secondTaskRevision = service.taskRevision(second.taskId);
    final firstEpisodeRevision = service.episodeRevision(firstEpisode);
    final secondEpisodeRevision = service.episodeRevision(secondEpisode);

    firstEpisode.progress = 0.5;
    service.markEpisodeProgressChangedForTesting(firstEpisode);

    expect(service.episodeRevision(firstEpisode), isNot(firstEpisodeRevision));
    expect(service.episodeRevision(secondEpisode), secondEpisodeRevision);
    expect(service.taskRevision(first.taskId), firstTaskRevision);
    expect(service.taskRevision(second.taskId), secondTaskRevision);
    expect(service.listStructureRevision, structureRevision);
  });

  test('选择和展开操作只更新对应任务并维护汇总状态', () {
    final service = BilibiliDownloadService();
    addTearDown(service.dispose);
    final first = _standaloneTask(1);
    final second = _standaloneTask(2);
    service.replaceTasksForTesting([first, second]);
    final secondRevision = service.taskRevision(second.taskId);
    final structureRevision = service.listStructureRevision;

    service.setTaskSelected(first, true);
    expect(first.isSelected, isTrue);
    expect(first.videos.single.episodes.single.isSelected, isTrue);
    expect(service.selectedEpisodeCount, 1);
    expect(service.taskRevision(second.taskId), secondRevision);

    service.setTaskExpanded(first, false);
    expect(service.listStructureRevision, structureRevision + 1);
    expect(service.taskRevision(second.taskId), secondRevision);
  });

  test('持久化快照只重新转换脏任务并保留完整任务顺序', () {
    final service = BilibiliDownloadService();
    addTearDown(service.dispose);
    final first = _standaloneTask(1);
    final second = _standaloneTask(2);
    service.replaceTasksForTesting([first, second]);

    expect(service.refreshDirtyTaskSnapshotsForTesting(), 2);
    expect(service.refreshDirtyTaskSnapshotsForTesting(), 0);

    service.setTaskSelected(first, true);
    expect(service.refreshDirtyTaskSnapshotsForTesting(), 1);
    expect(service.taskSnapshotForTesting(first.taskId)?['isSelected'], isTrue);
    expect(
      service.taskSnapshotForTesting(second.taskId)?['isSelected'],
      isFalse,
    );
    expect(service.taskIds, [first.taskId, second.taskId]);
  });

  test('顶层任务拖动按插入边界稳定排序并保留展开状态', () {
    final service = BilibiliDownloadService();
    addTearDown(service.dispose);
    final tasks = List.generate(4, _standaloneTask);
    tasks[0].isExpanded = true;
    tasks[1].isExpanded = false;
    tasks[2].isExpanded = true;
    tasks[3].isExpanded = false;
    final first = tasks[0];
    final second = tasks[1];
    final third = tasks[2];
    final fourth = tasks[3];
    final expansionById = <String, bool>{
      for (final task in tasks) task.taskId: task.isExpanded,
    };
    service.replaceTasksForTesting(tasks);
    service.refreshDirtyTaskSnapshotsForTesting();
    final structureRevision = service.listStructureRevision;

    expect(service.moveTaskToInsertionIndex(first.taskId, 4), isTrue);
    expect(service.taskIds, [
      second.taskId,
      third.taskId,
      fourth.taskId,
      first.taskId,
    ]);
    expect(service.listStructureRevision, structureRevision + 1);
    expect({
      for (final task in tasks) task.taskId: task.isExpanded,
    }, expansionById);
    expect(service.refreshDirtyTaskSnapshotsForTesting(), 0);

    // Dropping immediately before its current successor is a no-op and must
    // not create another structure revision.
    expect(service.moveTaskToInsertionIndex(third.taskId, 2), isFalse);
    expect(service.listStructureRevision, structureRevision + 1);

    expect(service.moveTaskToInsertionIndex(first.taskId, 0), isTrue);
    expect(service.taskIds.first, first.taskId);
    expect(service.taskIds.toSet(), hasLength(4));
  });

  test('500 个顶层任务多次首尾拖动后无重复、丢失或顺序回跳', () {
    final service = BilibiliDownloadService();
    addTearDown(service.dispose);
    final tasks = List.generate(500, _standaloneTask);
    final idsInOriginalOrder = tasks.map((task) => task.taskId).toList();
    final originalIds = idsInOriginalOrder.toSet();
    service.replaceTasksForTesting(tasks);

    for (var iteration = 0; iteration < 50; iteration++) {
      final firstId = service.taskIds.first;
      expect(
        service.moveTaskToInsertionIndex(firstId, service.taskIds.length),
        isTrue,
      );
    }

    expect(service.taskIds, hasLength(500));
    expect(service.taskIds.toSet(), originalIds);
    expect(service.taskIds.first, idsInOriginalOrder[50]);
    expect(service.taskIds.last, idsInOriginalOrder[49]);
  });

  test('单视频连接数随任务并发自动降级以限制连接总量', () {
    final service = BilibiliDownloadService();
    addTearDown(service.dispose);
    service.maxConnectionsPerVideo = 4;

    service.maxConcurrentDownloads = 1;
    expect(service.effectiveMaxConnectionsPerVideo, 4);
    service.maxConcurrentDownloads = 3;
    expect(service.effectiveMaxConnectionsPerVideo, 2);
    service.maxConcurrentDownloads = 8;
    expect(service.effectiveMaxConnectionsPerVideo, 1);
  });

  test('单视频连接数设置会持久化', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final service = BilibiliDownloadService();
    addTearDown(service.dispose);
    service.maxConnectionsPerVideo = 4;

    await service.saveSettings();

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getInt('bilibili_connections_per_video'), 4);
  });
}
