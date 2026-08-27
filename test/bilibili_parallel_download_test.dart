import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/download_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _RealHttpOverrides();

  late Directory tempDirectory;
  final servers = <_RangeTestServer>[];

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'bilibili_parallel_download_test_',
    );
  });

  tearDown(() async {
    for (final server in servers) {
      await server.close();
    }
    servers.clear();
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  Future<_RangeTestServer> startServer({
    bool ignoreRanges = false,
    bool rejectPrimary = false,
    Duration chunkDelay = const Duration(milliseconds: 2),
  }) async {
    final server = await _RangeTestServer.start(
      ignoreRanges: ignoreRanges,
      rejectPrimary: rejectPrimary,
      chunkDelay: chunkDelay,
    );
    servers.add(server);
    return server;
  }

  BilibiliDownloadManager createManager() {
    return BilibiliDownloadManager(
      BilibiliApiService(),
      rangeMinBytesPerConnection: 64 * 1024,
    );
  }

  test('单个视频使用多个严格 Range 请求并正确拼接', () async {
    final server = await startServer();
    final outputPath = '${tempDirectory.path}/parallel_video.m4s';

    final result = await createManager().downloadVideoStreamForTesting(
      stream: server.streamItem('/media'),
      filePath: outputPath,
      maxConnections: 4,
    );

    expect(await File(outputPath).readAsBytes(), server.data);
    expect(result.isComplete, isTrue);
    expect(result.rangeParts, isEmpty);
    expect(result.supportsRange, isTrue);
    expect(server.nonProbeRangeRequests, greaterThanOrEqualTo(4));
    expect(server.maximumActiveRangeRequests, greaterThanOrEqualTo(2));
    expect(
      await tempDirectory
          .list()
          .where((entity) => entity.path.endsWith('.part'))
          .isEmpty,
      isTrue,
    );
  });

  test('CDN 忽略 Range 时自动回退单连接且不损坏文件', () async {
    final server = await startServer(ignoreRanges: true);
    final outputPath = '${tempDirectory.path}/fallback_video.m4s';

    final result = await createManager().downloadVideoStreamForTesting(
      stream: server.streamItem('/media'),
      filePath: outputPath,
      maxConnections: 4,
    );

    expect(await File(outputPath).readAsBytes(), server.data);
    expect(result.isComplete, isTrue);
    expect(result.rangeParts, isEmpty);
    expect(server.ignoredRangeRequests, greaterThan(0));
    expect(server.fullGetRequests, 1);
  });

  test('主 CDN 拒绝访问时按 Range 切换备用 CDN', () async {
    final server = await startServer(rejectPrimary: true);
    final outputPath = '${tempDirectory.path}/backup_video.m4s';

    final result = await createManager().downloadVideoStreamForTesting(
      stream: server.streamItem('/primary', backupPath: '/backup'),
      filePath: outputPath,
      maxConnections: 4,
    );

    expect(await File(outputPath).readAsBytes(), server.data);
    expect(result.isComplete, isTrue);
    expect(server.primaryRejectedRequests, greaterThan(0));
    expect(server.backupRangeRequests, greaterThanOrEqualTo(4));
  });

  test('单连接模式也会切换备用 CDN', () async {
    final server = await startServer(rejectPrimary: true);
    final outputPath = '${tempDirectory.path}/single_backup_video.m4s';

    final result = await createManager().downloadVideoStreamForTesting(
      stream: server.streamItem('/primary', backupPath: '/backup'),
      filePath: outputPath,
      maxConnections: 1,
    );

    expect(result.isComplete, isTrue);
    expect(await File(outputPath).readAsBytes(), server.data);
    expect(server.primaryRejectedRequests, greaterThan(0));
    expect(server.fullGetRequests, 1);
  });

  test('并行下载暂停后按各分片真实长度恢复', () async {
    final server = await startServer(
      chunkDelay: const Duration(milliseconds: 8),
    );
    final outputPath = '${tempDirectory.path}/resume_video.m4s';
    final manager = createManager();
    final cancelToken = CancelToken();
    DownloadPartResumeState? pausedState;

    final interrupted = manager.downloadVideoStreamForTesting(
      stream: server.streamItem('/media'),
      filePath: outputPath,
      maxConnections: 4,
      cancelToken: cancelToken,
      onProgress: (state, _) {
        pausedState = state;
        if (state.downloadedBytes >= 96 * 1024 && !cancelToken.isCancelled) {
          cancelToken.cancel('test pause');
        }
      },
    );

    await expectLater(
      interrupted,
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    expect(pausedState, isNotNull);
    expect(pausedState!.rangeParts, hasLength(4));
    expect(pausedState!.downloadedBytes, greaterThan(0));
    final recoveredStarts = <int, int>{};
    for (final part in pausedState!.rangeParts) {
      final path = part.tempPath!;
      final actualLength = await File(path).length();
      expect(actualLength, part.downloadedBytes);
      if (actualLength < part.length) {
        recoveredStarts[part.start] = part.start + actualLength;
      }
    }

    // Simulate an app process stopping after bytes reached disk but before the
    // throttled JSON state flush. Resume must trust the validated part-file
    // lengths and must not redownload from the stale counters.
    final staleParts = pausedState!.rangeParts
        .map(
          (part) => part.copyWith(
            downloadedBytes: (part.downloadedBytes - 4096).clamp(
              0,
              part.length,
            ),
          ),
        )
        .toList(growable: false);
    final staleState = DownloadPartResumeState(
      tempPath: pausedState!.tempPath,
      url: pausedState!.url,
      downloadedBytes: staleParts.fold<int>(
        0,
        (sum, part) => sum + part.downloadedBytes,
      ),
      totalBytes: pausedState!.totalBytes,
      streamId: pausedState!.streamId,
      codecid: pausedState!.codecid,
      codecs: pausedState!.codecs,
      mimeType: pausedState!.mimeType,
      supportsRange: true,
      rangeParts: staleParts,
    );

    server.requestedRanges.clear();
    final resumed = await manager.downloadVideoStreamForTesting(
      stream: server.streamItem('/media'),
      filePath: outputPath,
      maxConnections: 4,
      initialState: staleState,
    );

    expect(resumed.isComplete, isTrue);
    expect(await File(outputPath).readAsBytes(), server.data);
    expect(
      recoveredStarts.values.every(
        (expectedStart) =>
            server.requestedRanges.any((range) => range.$1 == expectedStart),
      ),
      isTrue,
    );
  });
}

class _RealHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.connectionTimeout = const Duration(seconds: 5);
    return client;
  }
}

class _RangeTestServer {
  _RangeTestServer._(
    this.server,
    this.data, {
    required this.ignoreRanges,
    required this.rejectPrimary,
    required this.chunkDelay,
  });

  final HttpServer server;
  final Uint8List data;
  final bool ignoreRanges;
  final bool rejectPrimary;
  final Duration chunkDelay;
  final List<(int, int)> requestedRanges = <(int, int)>[];
  int _activeRangeRequests = 0;
  int maximumActiveRangeRequests = 0;
  int nonProbeRangeRequests = 0;
  int ignoredRangeRequests = 0;
  int fullGetRequests = 0;
  int primaryRejectedRequests = 0;
  int backupRangeRequests = 0;

  static Future<_RangeTestServer> start({
    required bool ignoreRanges,
    required bool rejectPrimary,
    required Duration chunkDelay,
  }) async {
    final data = Uint8List.fromList(
      List<int>.generate(512 * 1024, (index) => (index * 31 + 7) & 0xff),
    );
    final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final result = _RangeTestServer._(
      httpServer,
      data,
      ignoreRanges: ignoreRanges,
      rejectPrimary: rejectPrimary,
      chunkDelay: chunkDelay,
    );
    httpServer.listen((request) {
      unawaited(result._handle(request));
    });
    return result;
  }

  StreamItem streamItem(String path, {String? backupPath}) {
    return StreamItem(
      id: 80,
      baseUrl: _url(path),
      backupUrls: backupPath == null ? const [] : <String>[_url(backupPath)],
      bandwidth: 1,
      codecs: 'avc1',
      codecid: 7,
      mimeType: 'video/mp4',
    );
  }

  String _url(String path) =>
      'http://${server.address.address}:${server.port}$path';

  Future<void> close() => server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final isPrimary = request.uri.path == '/primary';
    if (rejectPrimary && isPrimary) {
      primaryRejectedRequests++;
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }

    if (request.method == 'HEAD') {
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = data.length
        ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      await request.response.close();
      return;
    }

    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader == null || ignoreRanges) {
      if (rangeHeader == null) {
        fullGetRequests++;
      } else {
        ignoredRangeRequests++;
      }
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = data.length;
      try {
        request.response.add(data);
        await request.response.close();
      } catch (_) {}
      return;
    }

    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(rangeHeader);
    if (match == null) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      await request.response.close();
      return;
    }
    final start = int.parse(match.group(1)!);
    final parsedEnd = int.tryParse(match.group(2) ?? '');
    final end = parsedEnd ?? data.length - 1;
    if (start < 0 ||
        start >= data.length ||
        end < start ||
        end >= data.length) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      await request.response.close();
      return;
    }

    requestedRanges.add((start, end));
    if (!(start == 0 && end == 0)) nonProbeRangeRequests++;
    if (request.uri.path == '/backup' && !(start == 0 && end == 0)) {
      backupRangeRequests++;
    }
    _activeRangeRequests++;
    maximumActiveRangeRequests =
        maximumActiveRangeRequests < _activeRangeRequests
        ? _activeRangeRequests
        : maximumActiveRangeRequests;
    request.response
      ..statusCode = HttpStatus.partialContent
      ..contentLength = end - start + 1
      ..headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${data.length}',
      )
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    try {
      const chunkSize = 16 * 1024;
      var offset = start;
      while (offset <= end) {
        final chunkEnd = (offset + chunkSize - 1).clamp(offset, end);
        request.response.add(data.sublist(offset, chunkEnd + 1));
        await request.response.flush();
        offset = chunkEnd + 1;
        if (chunkDelay > Duration.zero) await Future<void>.delayed(chunkDelay);
      }
      await request.response.close();
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {}
    } finally {
      _activeRangeRequests--;
    }
  }
}
