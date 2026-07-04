import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/utils/bilibili_url_parser.dart';

void main() {
  group('BilibiliDownloadTask', () {
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

      expect(info.videoStreams.map((stream) => stream.id).toList(), [64, 64, 32, 16]);
      expect(
        info.videoStreams.map((stream) => stream.qualityName).toList(),
        ['720P 高清', '720P 高清', '清晰 480P', '流畅 360P'],
      );
    });
  });
}
