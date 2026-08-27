import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/media_chapter.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/utils/bilibili_url_parser.dart';

void main() {
  group('BilibiliDownloadTask', () {
    BilibiliVideoItem videoItem({
      required String bvid,
      required int episodeCount,
      required Set<int> selectedEpisodes,
    }) {
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
          for (var index = 0; index < pages.length; index++)
            BilibiliDownloadEpisode(
              page: pages[index],
              bvid: bvid,
              isSelected: selectedEpisodes.contains(index),
            ),
        ],
      );
    }

    test('episode round trip keeps chapter times in milliseconds', () {
      final episode = BilibiliDownloadEpisode(
        page: BilibiliPage(
          cid: 40391282161,
          page: 1,
          part: 'P1',
          duration: 941,
          bvid: 'BV1Zx3k6yEFn',
          aid: '1',
        ),
        bvid: 'BV1Zx3k6yEFn',
        chapters: const <MediaChapter>[
          MediaChapter(title: '前言', startMs: 0, endMs: 99000),
          MediaChapter(title: '第二章', startMs: 99000, endMs: 152000),
        ],
      );

      final decoded = BilibiliDownloadEpisode.fromJson(episode.toJson());

      expect(decoded.chapters, hasLength(2));
      expect(decoded.chapters.first.endMs, 99000);
      expect(decoded.chapters.last.startMs, 99000);
      expect(decoded.chapters.last.endMs, 152000);
    });

    test('并行分片断点状态可完整序列化并兼容数字字符串', () {
      const state = DownloadPartResumeState(
        tempPath: r'D:\temp\video.m4s',
        url: 'https://cdn.example/video',
        downloadedBytes: 75,
        totalBytes: 200,
        streamId: 80,
        codecid: 7,
        codecs: 'avc1',
        mimeType: 'video/mp4',
        supportsRange: true,
        rangeParts: <DownloadRangePartState>[
          DownloadRangePartState(
            start: 0,
            endInclusive: 99,
            downloadedBytes: 75,
            tempPath: r'D:\temp\video.m4s.range_0_99.part',
          ),
          DownloadRangePartState(
            start: 100,
            endInclusive: 199,
            tempPath: r'D:\temp\video.m4s.range_100_199.part',
          ),
        ],
      );

      final json = state.toJson()
        ..['downloadedBytes'] = '75'
        ..['totalBytes'] = '200';
      final decoded = DownloadPartResumeState.fromJson(json);

      expect(decoded.downloadedBytes, 75);
      expect(decoded.totalBytes, 200);
      expect(decoded.rangeParts, hasLength(2));
      expect(decoded.rangeParts.first.downloadedBytes, 75);
      expect(decoded.rangeParts.first.tempPath, contains('range_0_99'));
    });

    test('选择摘要准确区分独立视频、分P视频和合集层级', () {
      final standalone = videoItem(
        bvid: 'standalone',
        episodeCount: 1,
        selectedEpisodes: {0},
      );
      final multipart = videoItem(
        bvid: 'multipart',
        episodeCount: 3,
        selectedEpisodes: {0, 2},
      );
      final collectionVideoA = videoItem(
        bvid: 'collection-a',
        episodeCount: 1,
        selectedEpisodes: {0},
      );
      final collectionVideoB = videoItem(
        bvid: 'collection-b',
        episodeCount: 2,
        selectedEpisodes: {1},
      );
      final unselectedCollectionVideo = videoItem(
        bvid: 'collection-c',
        episodeCount: 1,
        selectedEpisodes: {},
      );

      final summary = BilibiliSelectionSummary.fromTasks([
        BilibiliDownloadTask(
          singleVideoInfo: standalone.videoInfo,
          videos: [standalone],
        ),
        BilibiliDownloadTask(
          singleVideoInfo: multipart.videoInfo,
          videos: [multipart],
        ),
        BilibiliDownloadTask(
          collectionInfo: BilibiliCollectionInfo(
            title: '合集',
            cover: '',
            videos: [
              collectionVideoA.videoInfo,
              collectionVideoB.videoInfo,
              unselectedCollectionVideo.videoInfo,
            ],
          ),
          videos: [
            collectionVideoA,
            collectionVideoB,
            unselectedCollectionVideo,
          ],
        ),
      ]);

      expect(summary.selectedItemCount, 5);
      expect(summary.standaloneVideoCount, 1);
      expect(summary.multipartVideoCount, 1);
      expect(summary.multipartPartCount, 2);
      expect(summary.collectionCount, 1);
      expect(summary.collectionVideoCount, 2);
      expect(summary.collectionItemCount, 2);
    });

    test('fromJson 为旧任务补齐 taskId 且可再次序列化', () {
      final legacyJson = {
        'singleVideoInfo': {
          'title': '示例视频',
          'desc': 'desc',
          'pic': 'https://example.com/cover.jpg',
          'bvid': 'BV1xx411c7mD',
          'aid': '123456',
          'ownerName': 'up',
          'ownerMid': '1',
          'pubDate': 0,
          'pages': [
            {
              'cid': 1001,
              'page': 1,
              'part': 'P1',
              'duration': 60,
              'bvid': 'BV1xx411c7mD',
              'aid': '123456',
            },
          ],
        },
        'videos': [
          {
            'videoInfo': {
              'title': '示例视频',
              'desc': 'desc',
              'pic': 'https://example.com/cover.jpg',
              'bvid': 'BV1xx411c7mD',
              'aid': '123456',
              'ownerName': 'up',
              'ownerMid': '1',
              'pubDate': 0,
              'pages': [
                {
                  'cid': 1001,
                  'page': 1,
                  'part': 'P1',
                  'duration': 60,
                  'bvid': 'BV1xx411c7mD',
                  'aid': '123456',
                },
              ],
            },
            'episodes': [
              {
                'page': {
                  'cid': 1001,
                  'page': 1,
                  'part': 'P1',
                  'duration': 60,
                  'bvid': 'BV1xx411c7mD',
                  'aid': '123456',
                },
                'bvid': 'BV1xx411c7mD',
                'isSelected': true,
                'availableVideoQualities': const [],
                'availableSubtitles': const [],
                'status': DownloadStatus.pending.index,
                'progress': 0.0,
                'isExported': false,
                'importedVideoIds': const [],
                'resumeVersion': 1,
                'canResume': false,
              },
            ],
            'isExpanded': true,
            'isSelected': true,
          },
        ],
        'isExpanded': true,
        'isSelected': true,
      };

      final task = BilibiliDownloadTask.fromJson(legacyJson);

      expect(task.taskId, isNotEmpty);

      final encoded = task.toJson();
      expect(encoded['taskId'], task.taskId);

      final decodedAgain = BilibiliDownloadTask.fromJson(encoded);
      expect(decodedAgain.taskId, task.taskId);
      expect(decodedAgain.title, '示例视频');
      expect(decodedAgain.sourceRef, isNull);
      expect(decodedAgain.videos.single.sourceRef, isNull);
      expect(decodedAgain.videos.single.episodes.single.page.cid, 1001);
    });

    test('新建任务默认生成稳定 taskId', () {
      final task = BilibiliDownloadTask(
        sourceRef: const MediaSourceRef(
          value: 'BV1xx411c7mD',
          kind: MediaSourceKind.bilibiliBv,
        ),
        singleVideoInfo: BilibiliVideoInfo(
          title: '新任务',
          desc: '',
          pic: '',
          bvid: 'BV1xx411c7mD',
          aid: '123456',
          ownerName: 'up',
          ownerMid: '1',
          pubDate: 0,
          pages: [
            BilibiliPage(
              cid: 1001,
              page: 1,
              part: 'P1',
              duration: 60,
              bvid: 'BV1xx411c7mD',
              aid: '123456',
            ),
          ],
        ),
        videos: [
          BilibiliVideoItem(
            videoInfo: BilibiliVideoInfo(
              title: '新任务',
              desc: '',
              pic: '',
              bvid: 'BV1xx411c7mD',
              aid: '123456',
              ownerName: 'up',
              ownerMid: '1',
              pubDate: 0,
              pages: [
                BilibiliPage(
                  cid: 1001,
                  page: 1,
                  part: 'P1',
                  duration: 60,
                  bvid: 'BV1xx411c7mD',
                  aid: '123456',
                ),
              ],
            ),
            episodes: [
              BilibiliDownloadEpisode(
                page: BilibiliPage(
                  cid: 1001,
                  page: 1,
                  part: 'P1',
                  duration: 60,
                  bvid: 'BV1xx411c7mD',
                  aid: '123456',
                ),
                bvid: 'BV1xx411c7mD',
              ),
            ],
            sourceRef: const MediaSourceRef(
              value: 'BV1xx411c7mD',
              kind: MediaSourceKind.bilibiliBv,
            ),
          ),
        ],
      );

      expect(task.taskId, isNotEmpty);
      expect(task.toJson()['taskId'], task.taskId);
      expect(task.toJson()['sourceRef'], isNotNull);
      expect(task.toJson()['videos'][0]['sourceRef'], isNotNull);
    });

    test('normalizeInput 能从杂文本中提取纯 BV 或纯链接', () {
      final bvInput = BilibiliUrlParser.normalizeInput(
        '标题：看看这个 BV1xx411c7mD ！',
      );
      final linkInput = BilibiliUrlParser.normalizeInput(
        '前缀 https://www.bilibili.com/video/BV1xx411c7mD?p=2 ，后缀',
      );

      expect(bvInput, isNotNull);
      expect(bvInput?.cleanedInput, 'BV1xx411c7mD');
      expect(bvInput?.type, BilibiliUrlType.videoBv);
      expect(linkInput, isNotNull);
      expect(
        linkInput?.cleanedInput,
        'https://www.bilibili.com/video/BV1xx411c7mD?p=2',
      );
      expect(linkInput?.type, BilibiliUrlType.videoBv);
    });
  });

  group('BilibiliStreamInfo', () {
    test('视频流按分辨率等级优先排序而不是按文案前缀或码率排序', () {
      final info = BilibiliStreamInfo.fromJson({
        'data': {
          'accept_quality': [64, 32, 16],
          'accept_description': ['720P 高清', '清晰 480P', '流畅 360P'],
          'dash': {
            'video': [
              {
                'id': 32,
                'base_url': 'https://example.com/480-avc',
                'backup_url': const [],
                'bandwidth': 2000000,
                'codecs': 'avc1.64001F',
                'codecid': 7,
              },
              {
                'id': 16,
                'base_url': 'https://example.com/360-avc',
                'backup_url': const [],
                'bandwidth': 1800000,
                'codecs': 'avc1.64001E',
                'codecid': 7,
              },
              {
                'id': 64,
                'base_url': 'https://example.com/720-hevc',
                'backup_url': const [],
                'bandwidth': 900000,
                'codecs': 'hev1.1.6.L120.90',
                'codecid': 12,
              },
              {
                'id': 64,
                'base_url': 'https://example.com/720-av1',
                'backup_url': const [],
                'bandwidth': 850000,
                'codecs': 'av01.0.08M.08',
                'codecid': 13,
              },
            ],
            'audio': const [],
          },
        },
      });

      expect(info.videoStreams.map((stream) => stream.id).toList(), [
        64,
        64,
        32,
        16,
      ]);
      expect(info.videoStreams.map((stream) => stream.qualityName).toList(), [
        '720P 高清',
        '720P 高清',
        '清晰 480P',
        '流畅 360P',
      ]);
    });
  });
}
