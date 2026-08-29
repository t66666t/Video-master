import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';

class _FakeBilibiliApiService extends BilibiliApiService {
  final Uri? mediaOrigin;

  _FakeBilibiliApiService({this.mediaOrigin});

  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async =>
      null;

  @override
  Future<BilibiliStreamInfo> fetchPlayUrl(String bvid, int cid) async {
    StreamItem video(int id, int codecid, String codecs) => StreamItem(
      id: id,
      baseUrl:
          mediaOrigin?.resolve('/video-$id-$codecid.m4s').toString() ??
          'https://upos-test.bilivideo.com/video-$id-$codecid.m4s',
      bandwidth: id * 1000 + codecid,
      codecs: codecs,
      codecid: codecid,
      mimeType: 'video/mp4',
      qualityName: id == 80 ? '1080P 高清' : '720P 高清',
      width: id == 80 ? 1920 : 1280,
      height: id == 80 ? 1080 : 720,
      frameRate: '30',
      initializationRange: '0-999',
      indexRange: '1000-1999',
    );

    return BilibiliStreamInfo(
      durationMs: 120000,
      qualityMap: const {80: '1080P 高清', 64: '720P 高清'},
      videoStreams: [
        video(80, 12, 'hev1.1.6.L120.90'),
        video(80, 7, 'avc1.640028'),
        video(64, 7, 'avc1.64001f'),
      ],
      audioStreams: [
        StreamItem(
          id: 30280,
          baseUrl:
              mediaOrigin?.resolve('/audio.m4s').toString() ??
              'https://upos-test.bilivideo.com/audio.m4s',
          bandwidth: 128000,
          codecs: 'mp4a.40.2',
          codecid: 0,
          mimeType: 'audio/mp4',
          initializationRange: '0-899',
          indexRange: '900-1799',
        ),
      ],
    );
  }
}

class _BackupOnlyQualityApiService extends BilibiliApiService {
  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async =>
      null;

  @override
  Future<BilibiliStreamInfo> fetchPlayUrl(String bvid, int cid) async {
    StreamItem video({
      required int id,
      required String baseUrl,
      List<String> backupUrls = const [],
    }) => StreamItem(
      id: id,
      baseUrl: baseUrl,
      backupUrls: backupUrls,
      bandwidth: id * 1000,
      codecs: 'avc1.640028',
      codecid: 7,
      mimeType: 'video/mp4',
      qualityName: id == 120 ? '超清 4K' : '高清 1080P',
      width: id == 120 ? 3840 : 1920,
      height: id == 120 ? 2160 : 1080,
      initializationRange: '0-999',
      indexRange: '1000-1999',
    );

    return BilibiliStreamInfo(
      qualityMap: const {120: '超清 4K', 80: '高清 1080P'},
      videoStreams: [
        video(id: 120, baseUrl: 'https://upos-test.bilivideo.com/4k.m4s'),
        video(
          id: 80,
          baseUrl: 'https://edge.mountaintoys.cn/1080p.m4s',
          backupUrls: const ['https://upos-test.bilivideo.com/1080p.m4s'],
        ),
      ],
      audioStreams: [
        StreamItem(
          id: 30280,
          baseUrl: 'https://upos-test.bilivideo.com/audio.m4s',
          bandwidth: 128000,
          codecs: 'mp4a.40.2',
          codecid: 0,
          mimeType: 'audio/mp4',
          initializationRange: '0-899',
          indexRange: '900-1799',
        ),
      ],
    );
  }
}

VideoItem _streamItem(String id) => VideoItem(
  id: id,
  path: 'bilibili://stream/BV1xx411c7mD?cid=456',
  title: 'stream',
  durationMs: 120000,
  lastUpdated: 0,
  sourceRef: const MediaSourceRef(
    value: 'BV1xx411c7mD',
    kind: MediaSourceKind.bilibiliStream,
    bvid: 'BV1xx411c7mD',
    cid: 456,
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('stream media identity persists without a temporary CDN URL', () {
    const source = MediaSourceRef(
      value: 'BV1xx411c7mD',
      kind: MediaSourceKind.bilibiliStream,
      originalValue: 'https://www.bilibili.com/video/BV1xx411c7mD',
      bvid: 'BV1xx411c7mD',
      aid: '123',
      cid: 456,
      page: 2,
    );

    final restored = MediaSourceRef.fromJson(source.toJson());

    expect(restored.kind, MediaSourceKind.bilibiliStream);
    expect(restored.bvid, 'BV1xx411c7mD');
    expect(restored.aid, '123');
    expect(restored.cid, 456);
    expect(restored.page, 2);
    expect(restored.toJson().values, isNot(contains('https://cdn.example')));
  });

  test('DASH aliases and SegmentBase are normalized for streaming', () {
    final info = BilibiliStreamInfo.fromJson({
      'data': {
        'timelength': 123456,
        'accept_quality': [80],
        'accept_description': ['1080P 高清'],
        'dash': {
          'duration': 123.456,
          'video': [
            {
              'id': 80,
              'baseUrl': 'https://upos.example.bilivideo.com/video.m4s',
              'backupUrl': ['https://backup.bilivideo.com/video.m4s'],
              'bandwidth': 1000,
              'codecs': 'avc1.640028',
              'codecid': 7,
              'mimeType': 'video/mp4',
              'width': 1920,
              'height': 1080,
              'frameRate': '30',
              'SegmentBase': {
                'Initialization': '0-999',
                'indexRange': '1000-1999',
              },
            },
          ],
          'audio': [
            {
              'id': 30280,
              'base_url': 'https://upos.example.bilivideo.com/audio.m4s',
              'bandwidth': 128000,
              'codecs': 'mp4a.40.2',
              'codecid': 0,
              'mime_type': 'audio/mp4',
              'segment_base': {
                'initialization': '0-899',
                'index_range': '900-1799',
              },
            },
          ],
        },
      },
    });

    expect(info.durationMs, 123456);
    expect(info.videoStreams.single.qualityName, '1080P 高清');
    expect(info.videoStreams.single.initializationRange, '0-999');
    expect(info.videoStreams.single.indexRange, '1000-1999');
    expect(info.videoStreams.single.width, 1920);
    expect(info.audioStreams.single.indexRange, '900-1799');
  });

  test('streaming task mode survives task persistence', () {
    final task = BilibiliDownloadTask(
      isStreamingImport: true,
      videos: [
        BilibiliVideoItem(
          videoInfo: BilibiliVideoInfo(
            title: 'title',
            desc: '',
            pic: '',
            bvid: 'BV1xx411c7mD',
            aid: '123',
            ownerName: '',
            ownerMid: '',
            pubDate: 0,
            pages: const [],
          ),
          episodes: const [],
        ),
      ],
    );

    final restored = BilibiliDownloadTask.fromJson(task.toJson());
    expect(restored.isStreamingImport, isTrue);
  });

  test(
    'loopback manifest keeps video and audio on one DASH timeline',
    () async {
      final service = BilibiliStreamingService(_FakeBilibiliApiService());
      addTearDown(service.shutdown);
      final item = VideoItem(
        id: 'stream-item',
        path: 'bilibili://stream/BV1xx411c7mD?cid=456',
        title: 'stream',
        durationMs: 120000,
        lastUpdated: 0,
        sourceRef: const MediaSourceRef(
          value: 'BV1xx411c7mD',
          kind: MediaSourceKind.bilibiliStream,
          bvid: 'BV1xx411c7mD',
          cid: 456,
        ),
      );

      final prepared = await service.prepare(item);
      expect(prepared.qualities.map((quality) => quality.id), [80, 64]);
      expect(prepared.selectedQuality.id, 80);
      expect(prepared.displayAspectRatio, closeTo(16 / 9, 0.0001));

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final response = await (await client.getUrl(
        prepared.manifestUri,
      )).close();
      final manifest = await response.transform(const Utf8Decoder()).join();

      expect(response.statusCode, HttpStatus.ok);
      expect(manifest, contains('mediaPresentationDuration="PT120.000S"'));
      expect(manifest, contains('/video</BaseURL>'));
      expect(manifest, contains('/audio</BaseURL>'));
      expect(manifest, contains('codecs="avc1.640028"'));
      expect(manifest, contains('indexRange="1000-1999"'));
    },
  );

  test('stream quality preference persists globally across cards', () async {
    final firstService = BilibiliStreamingService(_FakeBilibiliApiService());
    firstService.rememberQuality('first-card', 64);
    await Future<void>.delayed(Duration.zero);
    await firstService.shutdown();

    final secondService = BilibiliStreamingService(_FakeBilibiliApiService());
    addTearDown(secondService.shutdown);
    final prepared = await secondService.prepare(_streamItem('second-card'));

    expect(prepared.selectedQuality.id, 64);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getInt('bilibili_stream_preferred_quality'), 64);
  });

  test(
    'missing preferred quality falls back to the highest lower quality',
    () async {
      SharedPreferences.setMockInitialValues({
        'bilibili_stream_preferred_quality': 116,
      });
      final service = BilibiliStreamingService(_FakeBilibiliApiService());
      addTearDown(service.shutdown);

      final prepared = await service.prepare(_streamItem('fallback-card'));

      expect(prepared.selectedQuality.id, 80);
    },
  );

  test(
    'quality remains available when only its backup CDN is allowed',
    () async {
      final service = BilibiliStreamingService(_BackupOnlyQualityApiService());
      addTearDown(service.shutdown);

      final prepared = await service.prepare(_streamItem('backup-card'));

      expect(prepared.qualities.map((quality) => quality.id), [120, 80]);
    },
  );

  test('loopback dual-track gateway proxies HEAD and byte ranges', () async {
    final videoBytes = List<int>.generate(
      2 * 1024 * 1024,
      (index) => index % 251,
    );
    final audioBytes = List<int>.generate(2048, (index) => (index * 3) % 251);
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upstreamTask = () async {
      await for (final request in upstream) {
        final source = request.uri.path.contains('audio')
            ? audioBytes
            : videoBytes;
        final range = request.headers.value(HttpHeaders.rangeHeader);
        var start = 0;
        var end = source.length - 1;
        if (range != null) {
          final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
          if (match != null) {
            start = int.parse(match.group(1)!);
            if (match.group(2)!.isNotEmpty) {
              end = int.parse(match.group(2)!);
            }
            end = end.clamp(start, source.length - 1);
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-$end/${source.length}',
            );
          }
        }
        final selected = source.sublist(start, end + 1);
        request.response.headers.contentType = ContentType('video', 'mp4');
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        request.response.contentLength = selected.length;
        try {
          if (request.method != 'HEAD') {
            const chunkSize = 8 * 1024;
            for (
              var offset = 0;
              offset < selected.length;
              offset += chunkSize
            ) {
              final end = (offset + chunkSize).clamp(0, selected.length);
              request.response.add(selected.sublist(offset, end));
              await request.response.flush();
              if (selected.length > chunkSize) {
                await Future<void>.delayed(const Duration(milliseconds: 2));
              }
            }
          }
          await request.response.close();
        } catch (_) {
          // Expected when clearCache force-closes an in-flight media request.
        }
      }
    }();
    addTearDown(() async {
      await upstream.close(force: true);
      await upstreamTask;
    });

    final tempCache = await Directory.systemTemp.createTemp(
      'bilibili-stream-test-',
    );
    addTearDown(() => tempCache.delete(recursive: true));
    final origin = Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: upstream.port,
    );
    final service = BilibiliStreamingService(
      _FakeBilibiliApiService(mediaOrigin: origin),
      mediaUriValidator: (uri) => uri.host == origin.host,
      cacheDirectory: tempCache,
    );
    addTearDown(service.shutdown);
    final prepared = await service.prepare(
      VideoItem(
        id: 'gateway-item',
        path: 'bilibili://stream/BV1xx411c7mD?cid=456',
        title: 'stream',
        durationMs: 120000,
        lastUpdated: 0,
        sourceRef: const MediaSourceRef(
          value: 'BV1xx411c7mD',
          kind: MediaSourceKind.bilibiliStream,
          bvid: 'BV1xx411c7mD',
          cid: 456,
        ),
      ),
    );

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final head = await (await client.headUrl(prepared.audioUri)).close();
    expect(head.statusCode, HttpStatus.ok);
    expect(head.contentLength, audioBytes.length);
    await head.drain<void>();

    final rangeRequest = await client.getUrl(prepared.videoUri);
    rangeRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=100-299');
    final rangeResponse = await rangeRequest.close();
    final payload = await rangeResponse.fold<List<int>>(
      <int>[],
      (buffer, chunk) => buffer..addAll(chunk),
    );
    expect(rangeResponse.statusCode, HttpStatus.partialContent);
    expect(
      rangeResponse.headers.value(HttpHeaders.contentRangeHeader),
      'bytes 100-299/${videoBytes.length}',
    );
    expect(payload, videoBytes.sublist(100, 300));

    final cache = await service.inspectCache();
    expect(cache.bytes, payload.length);
    expect(cache.fileCount, 1);

    final activeResponse = await (await client.getUrl(
      prepared.videoUri,
    )).close();
    final activeDrain = activeResponse.drain<void>().catchError((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect((await service.inspectCache()).bytes, greaterThan(payload.length));

    await service.clearCache();
    await activeDrain.timeout(const Duration(seconds: 3), onTimeout: () {});
    final cleared = await service.inspectCache();
    expect(cleared.bytes, 0);
    expect(cleared.fileCount, 0);

    // Clearing cache keeps the gateway session alive for the mini player and
    // Android media notification, while this existing session no longer
    // recreates disk cache files.
    final afterClearRequest = await client.getUrl(prepared.videoUri);
    afterClearRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=400-599');
    final afterClearResponse = await afterClearRequest.close();
    final afterClearPayload = await afterClearResponse.fold<List<int>>(
      <int>[],
      (buffer, chunk) => buffer..addAll(chunk),
    );
    expect(afterClearResponse.statusCode, HttpStatus.partialContent);
    expect(afterClearPayload, videoBytes.sublist(400, 600));
    expect((await service.inspectCache()).bytes, 0);
  });
}
