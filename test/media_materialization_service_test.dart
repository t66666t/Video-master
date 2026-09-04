import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/media_materialization_service.dart';

class _FakeApi extends BilibiliApiService {
  BilibiliStreamInfo info;
  int fetchCount = 0;

  _FakeApi(this.info);

  @override
  Future<BilibiliStreamInfo> fetchPlayUrl(String bvid, int cid) async {
    fetchCount++;
    return info;
  }
}

VideoItem _onlineItem([String id = 'material-card']) => VideoItem(
  id: id,
  path: 'bilibili://stream/BV1material?cid=42',
  title: 'online',
  durationMs: 10 * 1000,
  lastUpdated: 0,
  sourceRef: const MediaSourceRef(
    value: 'BV1material',
    kind: MediaSourceKind.bilibiliStream,
    bvid: 'BV1material',
    cid: 42,
  ),
);

StreamItem _video(Uri origin, int id, int height, int bandwidth) => StreamItem(
  id: id,
  baseUrl: origin.resolve('/video-$id.m4s').toString(),
  bandwidth: bandwidth,
  codecs: 'avc1.640028',
  codecid: 7,
  mimeType: 'video/mp4',
  width: height * 16 ~/ 9,
  height: height,
);

StreamItem _audio(Uri origin, {List<String> backups = const []}) => StreamItem(
  id: 30280,
  baseUrl: origin.resolve('/audio.m4s').toString(),
  backupUrls: backups,
  bandwidth: 128000,
  codecs: 'mp4a.40.2',
  codecid: 0,
  mimeType: 'audio/mp4',
);

BilibiliStreamInfo _info(
  Uri origin, {
  List<StreamItem>? videos,
  StreamItem? audio,
}) => BilibiliStreamInfo(
  videoStreams:
      videos ??
      <StreamItem>[
        _video(origin, 16, 360, 400000),
        _video(origin, 64, 720, 1000000),
        _video(origin, 80, 1080, 2000000),
      ],
  audioStreams: <StreamItem>[audio ?? _audio(origin)],
  qualityMap: const <int, String>{16: '360P', 64: '720P', 80: '1080P'},
  durationMs: 10000,
);

void main() {
  late Directory cache;
  late HttpServer server;
  late Uri origin;

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('materialization-test-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = Uri.parse('http://${server.address.address}:${server.port}');
  });

  tearDown(() async {
    await server.close(force: true);
    if (await cache.exists()) await cache.delete(recursive: true);
  });

  test(
    'chooses the smallest adequate quality and falls back to highest',
    () async {
      unawaited(server.forEach((request) => request.response.close()));
      final service = MediaMaterializationService(
        _FakeApi(_info(origin)),
        cacheDirectory: cache,
        mediaUriValidator: (_) => true,
        trackValidator: (_, _) async => true,
      );

      final adequate = await service.estimate(
        _onlineItem(),
        MediaMaterializationRequirement.videoFrames,
        targetHeight: 800,
      );
      final unavailable = await service.estimate(
        _onlineItem(),
        MediaMaterializationRequirement.videoFrames,
        targetHeight: 2160,
      );

      expect(adequate.height, 1080);
      expect(unavailable.height, 1080);
    },
  );

  test(
    'concurrent audio callers share fallback download and reuse result',
    () async {
      final payload = List<int>.generate(32 * 1024, (index) => index % 251);
      var goodRequests = 0;
      var badRequests = 0;
      unawaited(
        server.forEach((request) async {
          if (request.uri.path == '/bad.m4s') {
            badRequests++;
            request.response.statusCode = HttpStatus.badGateway;
          } else {
            goodRequests++;
            request.response.contentLength = payload.length;
            request.response.add(payload);
          }
          await request.response.close();
        }),
      );
      final good = origin.resolve('/good.m4s').toString();
      final api = _FakeApi(
        _info(
          origin,
          audio: _audio(
            origin,
            backups: <String>[good],
          ).copyWithForTest(baseUrl: origin.resolve('/bad.m4s').toString()),
        ),
      );
      final service = MediaMaterializationService(
        api,
        cacheDirectory: cache,
        mediaUriValidator: (_) => true,
        trackValidator: (_, type) async => type == 'audio',
      );

      final leases = await Future.wait(<Future<MaterializedMediaLease>>[
        service.acquire(
          _onlineItem(),
          MediaMaterializationRequirement.audioOnly,
        ),
        service.acquire(
          _onlineItem(),
          MediaMaterializationRequirement.audioOnly,
        ),
      ]);
      final third = await service.acquire(
        _onlineItem(),
        MediaMaterializationRequirement.audioOnly,
      );

      expect(badRequests, 1);
      expect(goodRequests, 1);
      expect(await File(third.requiredAudioPath).length(), payload.length);
      for (final lease in <MaterializedMediaLease>[...leases, third]) {
        await lease.release();
      }
    },
  );

  test('failed truncated downloads leave no part or final file', () async {
    unawaited(
      server.forEach((request) async {
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.write(
          'HTTP/1.1 200 OK\r\nContent-Length: 8192\r\n'
          'Connection: close\r\n\r\n',
        );
        socket.add(List<int>.filled(512, 1));
        await socket.flush();
        socket.destroy();
      }),
    );
    final service = MediaMaterializationService(
      _FakeApi(_info(origin)),
      cacheDirectory: cache,
      mediaUriValidator: (_) => true,
      trackValidator: (_, _) async => true,
    );

    await expectLater(
      service.acquire(_onlineItem(), MediaMaterializationRequirement.audioOnly),
      throwsA(isA<Object>()),
    );
    final card = Directory(
      '${cache.path}${Platform.pathSeparator}material-card',
    );
    final leftovers = await card
        .list()
        .where(
          (entity) =>
              entity.path.endsWith('.part') ||
              entity.path.endsWith('transcription_audio.m4a'),
        )
        .toList();
    expect(leftovers, isEmpty);
  });

  test(
    'adopts legacy transcription audio without resolving a CDN URL',
    () async {
      unawaited(server.forEach((request) => request.response.close()));
      final card = Directory(
        '${cache.path}${Platform.pathSeparator}legacy-card',
      );
      await card.create(recursive: true);
      final legacy = File(
        '${card.path}${Platform.pathSeparator}transcription_audio.m4a',
      );
      await legacy.writeAsBytes(<int>[1, 2, 3, 4], flush: true);
      final api = _FakeApi(_info(origin));
      final service = MediaMaterializationService(
        api,
        cacheDirectory: cache,
        mediaUriValidator: (_) => true,
        trackValidator: (_, _) async => true,
      );

      final lease = await service.acquire(
        _onlineItem('legacy-card'),
        MediaMaterializationRequirement.audioOnly,
      );

      expect(lease.requiredAudioPath, legacy.path);
      expect(api.fetchCount, 0);
      expect(
        await File(
          '${card.path}${Platform.pathSeparator}materialization.json',
        ).exists(),
        isTrue,
      );
      await lease.release();
    },
  );

  test('video cache upgrades and higher quality satisfies lower', () async {
    final requestedPaths = <String>[];
    unawaited(
      server.forEach((request) async {
        requestedPaths.add(request.uri.path);
        final payload = List<int>.filled(4096, request.uri.path.hashCode & 255);
        request.response.contentLength = payload.length;
        request.response.add(payload);
        await request.response.close();
      }),
    );
    final service = MediaMaterializationService(
      _FakeApi(_info(origin)),
      cacheDirectory: cache,
      mediaUriValidator: (_) => true,
      trackValidator: (_, type) async => type == 'video',
    );

    final low = await service.acquire(
      _onlineItem(),
      MediaMaterializationRequirement.videoFrames,
      targetHeight: 720,
    );
    expect(low.height, 720);
    final lowPath = low.requiredVideoPath;
    await low.release();

    final high = await service.acquire(
      _onlineItem(),
      MediaMaterializationRequirement.videoFrames,
      targetHeight: 1080,
    );
    expect(high.height, 1080);
    expect(await File(lowPath).exists(), isFalse);
    await high.release();

    final reused = await service.acquire(
      _onlineItem(),
      MediaMaterializationRequirement.videoFrames,
      targetHeight: 360,
    );
    expect(reused.height, 1080);
    await reused.release();
    expect(requestedPaths, <String>['/video-64.m4s', '/video-80.m4s']);
  });

  test('active lease defers deletion and cleanup removes partials', () async {
    final payload = List<int>.filled(2048, 7);
    unawaited(
      server.forEach((request) async {
        request.response.contentLength = payload.length;
        request.response.add(payload);
        await request.response.close();
      }),
    );
    final service = MediaMaterializationService(
      _FakeApi(_info(origin)),
      cacheDirectory: cache,
      mediaUriValidator: (_) => true,
      trackValidator: (_, type) async => type == 'audio',
    );
    var deferredCallbackCount = 0;
    service.onDeferredClearCompleted = (_) async {
      deferredCallbackCount++;
    };
    final lease = await service.acquire(
      _onlineItem(),
      MediaMaterializationRequirement.audioOnly,
    );
    final audio = File(lease.requiredAudioPath);
    final orphan = File(
      '${audio.parent.path}${Platform.pathSeparator}crashed.part',
    );
    await orphan.writeAsBytes(<int>[1, 2, 3]);

    expect(await service.clearCard('material-card'), isFalse);
    expect(await audio.exists(), isTrue);
    await lease.release();

    expect(await audio.exists(), isFalse);
    expect(deferredCallbackCount, 1);
    await service.cleanupPendingDeletions();
    expect(await orphan.exists(), isFalse);
  });
}

extension on StreamItem {
  StreamItem copyWithForTest({required String baseUrl}) => StreamItem(
    id: id,
    baseUrl: baseUrl,
    backupUrls: backupUrls,
    bandwidth: bandwidth,
    codecs: codecs,
    codecid: codecid,
    mimeType: mimeType,
    qualityName: qualityName,
    width: width,
    height: height,
    frameRate: frameRate,
    initializationRange: initializationRange,
    indexRange: indexRange,
  );
}
