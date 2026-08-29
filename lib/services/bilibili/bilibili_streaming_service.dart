import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../models/bilibili_models.dart';
import '../../models/media_source_ref.dart';
import '../../models/video_item.dart';
import '../settings_service.dart';
import 'bilibili_api_service.dart';
import 'bilibili_video_shot_service.dart';

class BilibiliStreamQuality {
  final int id;
  final String label;

  const BilibiliStreamQuality({required this.id, required this.label});

  @override
  bool operator ==(Object other) =>
      other is BilibiliStreamQuality && other.id == id && other.label == label;

  @override
  int get hashCode => Object.hash(id, label);
}

class BilibiliPreparedPlayback {
  /// A video-only fragmented MP4 exposed through the local media gateway.
  final Uri videoUri;

  /// The matching audio-only fragmented MP4. Native playback attaches this as
  /// an external audio track, so playback does not depend on DASH/MPD support
  /// in the platform backend.
  final Uri audioUri;

  /// Kept as a standards-based fallback and for diagnostics. Native clients
  /// should prefer [videoUri] + [audioUri].
  final Uri manifestUri;
  final List<BilibiliStreamQuality> qualities;
  final BilibiliStreamQuality selectedQuality;

  /// Stable display ratio derived from the video's best available DASH track.
  /// It deliberately does not follow the selected quality: some lower-quality
  /// representations have padded/rounded coded dimensions, which must not make
  /// the Flutter viewport shrink when quality changes.
  final double? displayAspectRatio;

  const BilibiliPreparedPlayback({
    required this.videoUri,
    required this.audioUri,
    required this.manifestUri,
    required this.qualities,
    required this.selectedQuality,
    required this.displayAspectRatio,
  });
}

class BilibiliStreamCacheReport {
  final int bytes;
  final int fileCount;

  const BilibiliStreamCacheReport({this.bytes = 0, this.fileCount = 0});
}

/// Resolves stable Bilibili identities at playback time and exposes a loopback
/// media gateway. CDN URLs remain inside short-lived in-memory sessions and
/// are never persisted into the media library.
class BilibiliStreamingService extends ChangeNotifier {
  static const _preferredQualityPreferenceKey =
      'bilibili_stream_preferred_quality';
  static const _refreshAge = Duration(minutes: 90);
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  static const _referer = 'https://www.bilibili.com/';

  final BilibiliApiService apiService;
  final bool Function(Uri uri)? _mediaUriValidator;
  final _sessions = <String, _GatewaySession>{};
  final _preferredQualityByItem = <String, int>{};
  final _activeCacheFiles = <String>{};
  final _cachePolicyByItem = <String, bool>{};
  final _videoShotLoads = <String, Future<void>>{};
  final _videoShotUnavailableByItem = <String>{};
  final _uuid = const Uuid();
  HttpServer? _server;
  Future<HttpServer>? _serverFuture;
  Directory? _cacheDirectory;
  int _cacheSequence = 0;
  int _cachePolicyRevision = 0;
  int? _preferredQualityId;
  bool _preferredQualityLoaded = false;
  Future<void>? _preferredQualityLoadFuture;

  /// Called after a cache file is closed so LibraryService can invalidate its
  /// filesystem-size cache while the recycle-bin screen is open.
  void Function(String itemId)? onCacheChanged;

  /// Persists lazily backfilled sprite metadata for pre-existing online cards.
  Future<void> Function(VideoItem item)? onVideoShotChanged;

  BilibiliStreamingService(
    this.apiService, {
    @visibleForTesting bool Function(Uri uri)? mediaUriValidator,
    @visibleForTesting Directory? cacheDirectory,
  }) : _mediaUriValidator = mediaUriValidator,
       _cacheDirectory = cacheDirectory;

  Future<BilibiliPreparedPlayback> prepare(
    VideoItem item, {
    int? qualityId,
  }) async {
    final source = item.sourceRef;
    if (source == null ||
        source.kind != MediaSourceKind.bilibiliStream ||
        source.cid == null ||
        (source.bvid?.isEmpty ?? true)) {
      throw const FormatException('媒体库条目缺少 Bilibili 播放身份信息');
    }
    await _ensurePreferredQualityLoaded();
    await _ensureVideoShot(item);
    final server = await _ensureServer();
    final requested =
        qualityId ?? _preferredQualityId ?? _preferredQualityByItem[item.id];
    final session = await _createSession(
      itemId: item.id,
      source: source,
      fallbackDurationMs: item.durationMs,
      requestedQualityId: requested,
    );
    // Direct service callers (including low-level gateway clients) retain the
    // historical cache-enabled behavior until a playback context explicitly
    // supplies a policy. MediaPlaybackService always supplies that policy
    // before calling prepare(), so the app still obeys its visibility rules.
    session.setCachingEnabled(_cachePolicyByItem[item.id] ?? true);
    _sessions[session.token] = session;
    _preferredQualityByItem[item.id] = session.selectedVideo.id;
    _pruneSessions();
    final qualities = _qualitiesFor(session.streamInfo);
    final selected = qualities.firstWhere(
      (quality) => quality.id == session.selectedVideo.id,
      orElse: () => qualities.first,
    );
    return BilibiliPreparedPlayback(
      videoUri: Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        path: '/session/${session.token}/video',
      ),
      audioUri: Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        path: '/session/${session.token}/audio',
      ),
      manifestUri: Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        path: '/session/${session.token}/manifest.mpd',
      ),
      qualities: qualities,
      selectedQuality: selected,
      displayAspectRatio: _displayAspectRatioFor(session.streamInfo),
    );
  }

  double? _displayAspectRatioFor(BilibiliStreamInfo info) {
    final tracks = info.videoStreams.where(_isUsableTrack).toList()
      ..sort(StreamItem.compareVideoQuality);
    for (final track in tracks) {
      if (track.width <= 0 || track.height <= 0) continue;
      final ratio = track.width / track.height;
      if (ratio.isFinite && ratio > 0) return ratio;
    }
    return null;
  }

  void rememberQuality(String itemId, int qualityId) {
    _preferredQualityByItem[itemId] = qualityId;
    _preferredQualityId = qualityId;
    _preferredQualityLoaded = true;
    unawaited(_persistPreferredQuality(qualityId));
  }

  Future<void> _ensurePreferredQualityLoaded() {
    if (_preferredQualityLoaded) return Future.value();
    return _preferredQualityLoadFuture ??= () async {
      try {
        final preferences = await SharedPreferences.getInstance();
        _preferredQualityId ??= preferences.getInt(
          _preferredQualityPreferenceKey,
        );
      } catch (error) {
        debugPrint('Failed to load Bilibili stream quality preference: $error');
      } finally {
        _preferredQualityLoaded = true;
      }
    }();
  }

  Future<void> _persistPreferredQuality(int qualityId) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setInt(_preferredQualityPreferenceKey, qualityId);
    } catch (error) {
      debugPrint('Failed to save Bilibili stream quality preference: $error');
    }
  }

  Future<void> _ensureVideoShot(VideoItem item) {
    if (item.bilibiliVideoShot?.hasLocalSprites == true ||
        _videoShotUnavailableByItem.contains(item.id)) {
      return Future.value();
    }
    return _videoShotLoads[item.id] ??=
        () async {
          final source = item.sourceRef;
          if (source?.bvid?.isNotEmpty != true || source?.cid == null) {
            _videoShotUnavailableByItem.add(item.id);
            return;
          }
          final videoShot = await BilibiliVideoShotService.instance
              .downloadForCard(
                apiService: apiService,
                videoId: item.id,
                bvid: source!.bvid!,
                cid: source.cid!,
              );
          if (videoShot == null) {
            _videoShotUnavailableByItem.add(item.id);
            return;
          }
          item.bilibiliVideoShot = videoShot;
          try {
            await onVideoShotChanged?.call(item);
          } catch (error) {
            debugPrint(
              'Failed to persist Bilibili video-shot metadata: $error',
            );
          }
        }().whenComplete(() {
          _videoShotLoads.remove(item.id);
        });
  }

  Future<BilibiliStreamCacheReport> inspectCache() async {
    final dir = await _resolveCacheDirectory();
    return _inspectCacheDirectory(dir);
  }

  /// Returns only the cache owned by one library card.
  ///
  /// The item id is the ownership boundary. The Bilibili URL, title and
  /// source identity may be shared by multiple cards, but their cache folders
  /// must never be shared.
  Future<BilibiliStreamCacheReport> inspectItemCache(String itemId) async {
    final dir = await _resolveCacheDirectory();
    return inspectCacheForItem(itemId, cacheDirectory: dir);
  }

  /// Filesystem-only variant used by LibraryService when the service instance
  /// is not available (for example during startup or in a unit test).
  static Future<BilibiliStreamCacheReport> inspectCacheForItem(
    String itemId, {
    Directory? cacheDirectory,
  }) async {
    if (itemId.trim().isEmpty) return const BilibiliStreamCacheReport();
    final root = cacheDirectory ?? await _resolveDefaultCacheDirectory();
    final itemDir = Directory(p.join(root.path, _safeNameStatic(itemId)));
    return _inspectCacheDirectoryStatic(itemDir);
  }

  /// Permanently removes every cache file owned by [itemId].
  ///
  /// This deliberately deletes the whole card directory rather than trying to
  /// infer ownership from CDN URLs or ranges. That keeps repeated imports of
  /// the same Bilibili link independent.
  static Future<void> clearCacheForItemOnDisk(
    String itemId, {
    Directory? cacheDirectory,
  }) async {
    if (itemId.trim().isEmpty) return;
    final root = cacheDirectory ?? await _resolveDefaultCacheDirectory();
    final itemDir = Directory(p.join(root.path, _safeNameStatic(itemId)));
    if (!await itemDir.exists()) return;
    try {
      await itemDir.delete(recursive: true);
    } catch (_) {
      // A platform decoder may briefly keep a file handle open. Make a best
      // effort to remove individual files as well; the next size inspection
      // will report only files that genuinely survived the deletion attempt.
      try {
        await for (final entity in itemDir.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      } catch (_) {}
      try {
        if (await itemDir.exists()) await itemDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  static Future<BilibiliStreamCacheReport> _inspectCacheDirectory(
    Directory dir,
  ) async {
    return _inspectCacheDirectoryStatic(dir);
  }

  static Future<BilibiliStreamCacheReport> _inspectCacheDirectoryStatic(
    Directory dir,
  ) async {
    if (!await dir.exists()) return const BilibiliStreamCacheReport();
    var bytes = 0;
    var files = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      try {
        bytes += await entity.length();
        files++;
      } catch (_) {}
    }
    return BilibiliStreamCacheReport(bytes: bytes, fileCount: files);
  }

  static Future<Directory> _resolveDefaultCacheDirectory() async {
    final root = await SettingsService().resolveLargeDataRootDir();
    final dir = Directory(p.join(root.path, 'bilibili_stream_cache'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> clearCache() async {
    // Clearing disk cache must not end the global media session. Disable every
    // current session's cache writers first; the loopback proxy and native
    // player remain usable by the mini player and system media controls.
    await Future.wait<void>([
      for (final session in _sessions.values.toList(growable: false))
        session.disableCaching(),
    ]);
    final dir = await _resolveCacheDirectory();
    if (await dir.exists()) {
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File &&
            !_activeCacheFiles.contains(p.normalize(entity.path))) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    }
    onCacheChanged?.call('');
    notifyListeners();
  }

  /// Disables active writers, closes the card's gateway sessions and then
  /// removes every file belonging to that card.
  Future<void> clearCacheForItem(String itemId) async {
    if (itemId.trim().isEmpty) return;
    _cachePolicyByItem[itemId] = false;
    ++_cachePolicyRevision;
    final sessions = _sessions.values
        .where((session) => session.itemId == itemId)
        .toList(growable: false);
    await Future.wait<void>([
      for (final session in sessions) session.disableCaching(),
    ]);
    await _releaseSessions(sessions);
    final dir = await _resolveCacheDirectory();
    await clearCacheForItemOnDisk(itemId, cacheDirectory: dir);
    _preferredQualityByItem.remove(itemId);
    _notifyCacheChanged(itemId);
  }

  /// Applies the single cache policy for the currently visible playback
  /// context. A page may cache while paused; a mini card/phone notification may
  /// cache only while actively playing.
  void updateCachePolicy({
    required String? itemId,
    required bool isOnlineItem,
    required bool isPlaying,
    required bool playbackPageVisible,
    required bool miniPlaybackCardVisible,
    required bool mediaNotificationVisible,
  }) {
    final allowed =
        itemId != null &&
        isOnlineItem &&
        (playbackPageVisible ||
            ((miniPlaybackCardVisible || mediaNotificationVisible) &&
                isPlaying));
    final revision = ++_cachePolicyRevision;

    for (final id in _cachePolicyByItem.keys.toList(growable: false)) {
      if (id != itemId) _cachePolicyByItem[id] = false;
    }
    if (itemId != null) _cachePolicyByItem[itemId] = allowed;

    for (final session in _sessions.values.toList(growable: false)) {
      if (session.itemId == itemId && allowed) {
        session.setCachingEnabled(true);
      } else {
        unawaited(
          session.disableCaching().whenComplete(() {
            // A newer policy may have enabled this same session while the
            // writer was closing. Re-apply it after the close completes.
            if (revision != _cachePolicyRevision) return;
            if (session.itemId == itemId && allowed) {
              session.setCachingEnabled(true);
            }
          }),
        );
      }
    }
  }

  /// Stops every gateway transfer for [itemId] and invalidates its temporary
  /// CDN sessions. Call this after the native controller has been disposed.
  Future<void> releaseItem(String itemId) async {
    final sessions = _sessions.values
        .where((session) => session.itemId == itemId)
        .toList(growable: false);
    await _releaseSessions(sessions);
  }

  Future<void> _releaseSessions(List<_GatewaySession> sessions) async {
    if (sessions.isEmpty) return;
    for (final session in sessions) {
      _sessions.remove(session.token);
      session.close();
    }
    await Future.wait<void>([
      for (final session in sessions)
        session.waitUntilIdle().timeout(
          const Duration(seconds: 3),
          onTimeout: () {},
        ),
    ]);
  }

  Future<void> shutdown() async {
    final server = _server;
    _server = null;
    _serverFuture = null;
    await _releaseSessions(_sessions.values.toList(growable: false));
    if (server != null) await server.close(force: true);
  }

  Future<HttpServer> _ensureServer() {
    final existing = _server;
    if (existing != null) return Future.value(existing);
    return _serverFuture ??= () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      unawaited(_serve(server));
      return server;
    }();
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      unawaited(_handleRequest(request));
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final segments = request.uri.pathSegments;
      if (segments.length != 3 || segments.first != 'session') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final session = _sessions[segments[1]];
      if (session == null) {
        request.response.statusCode = HttpStatus.gone;
        await request.response.close();
        return;
      }
      switch (segments[2]) {
        case 'manifest.mpd':
          await _serveManifest(request, session);
          return;
        case 'video':
          await _proxyTrack(request, session, video: true);
          return;
        case 'audio':
          await _proxyTrack(request, session, video: false);
          return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } catch (error) {
      debugPrint(
        'Bilibili media gateway request failed '
        '(${request.method} ${request.uri.path}): $error',
      );
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<_GatewaySession> _createSession({
    required String itemId,
    required MediaSourceRef source,
    required int fallbackDurationMs,
    int? requestedQualityId,
    HttpClient? mediaClient,
  }) async {
    final streamInfo = await apiService.fetchPlayUrl(source.bvid!, source.cid!);
    if (streamInfo.videoStreams.isEmpty || streamInfo.audioStreams.isEmpty) {
      throw StateError('当前账号没有可播放的 Bilibili 音视频轨道');
    }
    final video = _selectVideo(streamInfo, requestedQualityId);
    final compatibleAudio =
        streamInfo.audioStreams.where(_hasAllowedMediaUri).toList()..sort((
          a,
          b,
        ) {
          // AAC is the cross-platform baseline. Prefer it over Dolby/FLAC when
          // multiple Bilibili audio classes are returned, then choose bitrate.
          int codecRank(StreamItem item) {
            final codec = item.codecs.toLowerCase();
            if (codec.startsWith('mp4a')) return 0;
            if (codec.contains('opus')) return 1;
            if (codec.contains('ec-3') || codec.contains('eac3')) return 2;
            if (codec.contains('flac')) return 3;
            return 4;
          }

          final codec = codecRank(a).compareTo(codecRank(b));
          return codec != 0 ? codec : b.bandwidth.compareTo(a.bandwidth);
        });
    final audio = compatibleAudio.isEmpty ? null : compatibleAudio.first;
    if (audio == null) throw StateError('Bilibili 未返回可用音轨');
    return _GatewaySession(
      token: _uuid.v4().replaceAll('-', ''),
      itemId: itemId,
      source: source,
      obtainedAt: DateTime.now(),
      streamInfo: streamInfo,
      selectedVideo: video,
      selectedAudio: audio,
      mediaClient: mediaClient ?? _createMediaClient(),
      durationMs: streamInfo.durationMs > 0
          ? streamInfo.durationMs
          : fallbackDurationMs,
    );
  }

  StreamItem _selectVideo(BilibiliStreamInfo info, int? requestedQualityId) {
    final valid = info.videoStreams.where(_isUsableTrack).toList()
      ..sort(StreamItem.compareVideoQuality);
    if (valid.isEmpty) throw StateError('Bilibili 未返回可用视频轨道');
    final ids = valid.map((track) => track.id).toSet().toList()
      ..sort((a, b) {
        final aa = valid.firstWhere((track) => track.id == a).qualitySortScore;
        final bb = valid.firstWhere((track) => track.id == b).qualitySortScore;
        return bb.compareTo(aa);
      });
    var chosenId = ids.first;
    if (requestedQualityId != null) {
      final exact = ids.contains(requestedQualityId);
      if (exact) {
        chosenId = requestedQualityId;
      } else {
        final requestedScore = StreamItem(
          id: requestedQualityId,
          baseUrl: '',
          bandwidth: 0,
          codecs: '',
          codecid: 0,
        ).qualitySortScore;
        chosenId = ids.firstWhere(
          (id) =>
              valid.firstWhere((track) => track.id == id).qualitySortScore <=
              requestedScore,
          orElse: () => ids.last,
        );
      }
    }
    final sameQuality = valid.where((track) => track.id == chosenId).toList();
    // AVC is the safe baseline. HEVC and AV1 are only fallbacks until explicit
    // runtime decoder capability probing is available.
    sameQuality.sort((a, b) {
      int rank(StreamItem item) => switch (item.codecid) {
        7 => 0,
        12 => 1,
        13 => 2,
        _ => 3,
      };
      final codec = rank(a).compareTo(rank(b));
      return codec != 0 ? codec : b.bandwidth.compareTo(a.bandwidth);
    });
    return sameQuality.first;
  }

  bool _isUsableTrack(StreamItem track) {
    return _hasAllowedMediaUri(track) &&
        track.initializationRange.isNotEmpty &&
        track.indexRange.isNotEmpty;
  }

  bool _hasAllowedMediaUri(StreamItem track) {
    return <String>[
      track.baseUrl,
      ...track.backupUrls,
    ].map(Uri.tryParse).whereType<Uri>().any(_isAllowedMediaUri);
  }

  List<BilibiliStreamQuality> _qualitiesFor(BilibiliStreamInfo info) {
    final tracks = info.videoStreams.where(_isUsableTrack).toList()
      ..sort(StreamItem.compareVideoQuality);
    final seen = <int>{};
    return [
      for (final track in tracks)
        if (seen.add(track.id))
          BilibiliStreamQuality(
            id: track.id,
            label:
                track.qualityName ?? info.qualityMap[track.id] ?? '${track.id}',
          ),
    ];
  }

  Future<void> _serveManifest(
    HttpRequest request,
    _GatewaySession session,
  ) async {
    if (DateTime.now().difference(session.obtainedAt) >= _refreshAge) {
      await _refreshSession(session);
    }
    final origin = Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: _server!.port,
      path: '/session/${session.token}/',
    );
    final video = session.selectedVideo;
    final audio = session.selectedAudio;
    final seconds = (session.durationMs.clamp(1, 1 << 31) / 1000)
        .toStringAsFixed(3);
    final xml =
        '''<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT${seconds}S" minBufferTime="PT1.5S">
  <Period start="PT0S">
    <AdaptationSet mimeType="${_xml(video.mimeType ?? 'video/mp4')}" segmentAlignment="true">
      <Representation id="video-${video.id}" bandwidth="${video.bandwidth}" codecs="${_xml(video.codecs)}" width="${video.width}" height="${video.height}"${video.frameRate.isEmpty ? '' : ' frameRate="${_xml(video.frameRate)}"'}>
        <BaseURL>${_xml(origin.resolve('video').toString())}</BaseURL>
        <SegmentBase indexRange="${_xml(video.indexRange)}"><Initialization range="${_xml(video.initializationRange)}"/></SegmentBase>
      </Representation>
    </AdaptationSet>
    <AdaptationSet mimeType="${_xml(audio.mimeType ?? 'audio/mp4')}" segmentAlignment="true">
      <Representation id="audio-${audio.id}" bandwidth="${audio.bandwidth}" codecs="${_xml(audio.codecs)}">
        <BaseURL>${_xml(origin.resolve('audio').toString())}</BaseURL>
        <SegmentBase indexRange="${_xml(audio.indexRange)}"><Initialization range="${_xml(audio.initializationRange)}"/></SegmentBase>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>''';
    request.response.headers.contentType = ContentType(
      'application',
      'dash+xml',
      charset: 'utf-8',
    );
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    request.response.write(xml);
    await request.response.close();
  }

  Future<void> _proxyTrack(
    HttpRequest downstream,
    _GatewaySession session, {
    required bool video,
  }) async {
    session.beginTransfer();
    try {
      await _proxyActiveTrack(downstream, session, video: video);
    } catch (_) {
      if (!session.isClosed) rethrow;
      try {
        await downstream.response.close();
      } catch (_) {}
    } finally {
      session.endTransfer();
    }
  }

  Future<void> _proxyActiveTrack(
    HttpRequest downstream,
    _GatewaySession session, {
    required bool video,
  }) async {
    var track = video ? session.selectedVideo : session.selectedAudio;
    HttpClientResponse? upstream;
    for (var attempt = 0; attempt < 2; attempt++) {
      upstream = await _openUpstream(downstream, track, session.mediaClient);
      if (![
        HttpStatus.unauthorized,
        HttpStatus.forbidden,
        HttpStatus.notFound,
      ].contains(upstream.statusCode)) {
        break;
      }
      await upstream.drain<void>();
      if (attempt == 0 && !session.didRefreshAfterFailure) {
        session.didRefreshAfterFailure = true;
        await _refreshSession(session);
        track = video ? session.selectedVideo : session.selectedAudio;
        continue;
      }
      break;
    }
    if (upstream == null) throw StateError('无法连接 Bilibili 媒体源');
    if (upstream.statusCode >= 200 && upstream.statusCode < 400) {
      // Allow a future CDN expiry to perform its own single bounded refresh.
      session.didRefreshAfterFailure = false;
    }
    downstream.response.statusCode = upstream.statusCode;
    for (final name in const [
      HttpHeaders.contentRangeHeader,
      HttpHeaders.contentLengthHeader,
      HttpHeaders.acceptRangesHeader,
      HttpHeaders.contentTypeHeader,
      HttpHeaders.lastModifiedHeader,
      HttpHeaders.etagHeader,
    ]) {
      final value = upstream.headers.value(name);
      if (value != null) downstream.response.headers.set(name, value);
    }
    if (downstream.method == 'HEAD') {
      await upstream.drain<void>();
      await downstream.response.close();
      return;
    }
    File? cacheFile;
    IOSink? sink;
    var cacheDisabled = false;
    Future<void>? closeCacheFuture;

    Future<void> closeCache({required bool delete}) {
      cacheDisabled = true;
      return closeCacheFuture ??= () async {
        final activeSink = sink;
        sink = null;
        try {
          await activeSink?.flush();
        } catch (_) {}
        try {
          await activeSink?.close();
        } catch (_) {}
        final file = cacheFile;
        if (file == null) return;
        _activeCacheFiles.remove(p.normalize(file.path));
        if (delete) {
          try {
            if (await file.exists()) await file.delete();
          } catch (_) {}
        }
      }();
    }

    Future<void> disableCacheWriter() => closeCache(delete: true);

    if (session.isCachingEnabled &&
        (upstream.statusCode == HttpStatus.ok ||
            upstream.statusCode == HttpStatus.partialContent)) {
      try {
        cacheFile = await _allocateCacheFile(
          session,
          video: video,
          range: downstream.headers.value(HttpHeaders.rangeHeader),
        );
        sink = cacheFile.openWrite();
        _activeCacheFiles.add(p.normalize(cacheFile.path));
        if (!session.registerCacheWriter(disableCacheWriter)) {
          await disableCacheWriter();
        }
      } catch (_) {}
    }
    try {
      await for (final bytes in upstream) {
        downstream.response.add(bytes);
        if (!cacheDisabled) sink?.add(bytes);
      }
    } finally {
      session.unregisterCacheWriter(disableCacheWriter);
      await closeCache(delete: false);
      await downstream.response.close();
      _notifyCacheChanged(session.itemId);
    }
  }

  Future<HttpClientResponse> _openUpstream(
    HttpRequest downstream,
    StreamItem track,
    HttpClient client,
  ) async {
    final candidates = <String>[
      track.baseUrl,
      ...track.backupUrls,
    ].map(Uri.tryParse).whereType<Uri>().where(_isAllowedMediaUri);
    Object? lastError;
    for (final uri in candidates) {
      try {
        final request = downstream.method == 'HEAD'
            ? await client.headUrl(uri)
            : await client.getUrl(uri);
        request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
        request.headers.set(HttpHeaders.refererHeader, _referer);
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        final range = downstream.headers.value(HttpHeaders.rangeHeader);
        if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
        final response = await request.close();
        if (response.statusCode >= 500) {
          await response.drain<void>();
          lastError = HttpException(
            'CDN returned ${response.statusCode}',
            uri: Uri(scheme: uri.scheme, host: uri.host),
          );
          continue;
        }
        return response;
      } catch (error) {
        lastError = error;
      }
    }
    throw StateError('Bilibili 媒体 CDN 不可用: ${lastError.runtimeType}');
  }

  Future<void> _refreshSession(_GatewaySession session) async {
    final refreshed = await _createSession(
      itemId: session.itemId,
      source: session.source,
      fallbackDurationMs: session.durationMs,
      requestedQualityId: session.selectedVideo.id,
      mediaClient: session.mediaClient,
    );
    session
      ..obtainedAt = refreshed.obtainedAt
      ..streamInfo = refreshed.streamInfo
      ..selectedVideo = refreshed.selectedVideo
      ..selectedAudio = refreshed.selectedAudio
      ..durationMs = refreshed.durationMs;
  }

  bool _isAllowedMediaUri(Uri? uri) {
    if (uri != null && _mediaUriValidator?.call(uri) == true) return true;
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return false;
    final host = uri.host.toLowerCase();
    return host == 'bilivideo.com' ||
        host.endsWith('.bilivideo.com') ||
        host == 'bilivideo.cn' ||
        host.endsWith('.bilivideo.cn') ||
        host == 'hdslb.com' ||
        host.endsWith('.hdslb.com') ||
        host.endsWith('.akamaized.net');
  }

  Future<Directory> _resolveCacheDirectory() async {
    final cached = _cacheDirectory;
    if (cached != null) return cached;
    final root = await SettingsService().resolveLargeDataRootDir();
    final dir = Directory(p.join(root.path, 'bilibili_stream_cache'));
    if (!await dir.exists()) await dir.create(recursive: true);
    _cacheDirectory = dir;
    return dir;
  }

  Future<File> _allocateCacheFile(
    _GatewaySession session, {
    required bool video,
    String? range,
  }) async {
    final root = await _resolveCacheDirectory();
    final itemDir = Directory(p.join(root.path, _safeName(session.itemId)));
    if (!await itemDir.exists()) await itemDir.create(recursive: true);
    final normalizedRange = _safeName(range ?? 'full');
    return File(
      p.join(
        itemDir.path,
        '${video ? 'video' : 'audio'}_${normalizedRange}_${_cacheSequence++}.cache',
      ),
    );
  }

  void _pruneSessions() {
    final cutoff = DateTime.now().subtract(const Duration(hours: 3));
    final expired = _sessions.values
        .where((session) => session.obtainedAt.isBefore(cutoff))
        .toList(growable: false);
    for (final session in expired) {
      _sessions.remove(session.token);
      session.close();
    }
  }

  HttpClient _createMediaClient() =>
      HttpClient()..connectionTimeout = const Duration(seconds: 10);

  String _safeName(String input) => _safeNameStatic(input);

  static String _safeNameStatic(String input) {
    final safe = input.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    // Never let a malformed card id resolve to the cache root itself.
    if (safe.isEmpty || safe == '.' || safe == '..') return '_';
    return safe;
  }

  void _notifyCacheChanged(String itemId) {
    onCacheChanged?.call(itemId);
    notifyListeners();
  }

  String _xml(String input) => const HtmlEscape(
    HtmlEscapeMode.element,
  ).convert(input).replaceAll('"', '&quot;');
}

class _GatewaySession {
  final String token;
  final String itemId;
  final MediaSourceRef source;
  DateTime obtainedAt;
  BilibiliStreamInfo streamInfo;
  StreamItem selectedVideo;
  StreamItem selectedAudio;
  final HttpClient mediaClient;
  int durationMs;
  bool didRefreshAfterFailure = false;
  bool _closed = false;
  bool _cachingEnabled = false;
  int _activeTransfers = 0;
  Completer<void>? _idleCompleter;
  final Set<Future<void> Function()> _cacheWriters = {};

  bool get isClosed => _closed;
  bool get isCachingEnabled => _cachingEnabled;

  _GatewaySession({
    required this.token,
    required this.itemId,
    required this.source,
    required this.obtainedAt,
    required this.streamInfo,
    required this.selectedVideo,
    required this.selectedAudio,
    required this.mediaClient,
    required this.durationMs,
  });

  void beginTransfer() {
    if (_closed) throw StateError('Bilibili streaming session is closed');
    _activeTransfers++;
    _idleCompleter ??= Completer<void>();
  }

  void endTransfer() {
    if (_activeTransfers > 0) _activeTransfers--;
    if (_activeTransfers == 0) {
      final completer = _idleCompleter;
      _idleCompleter = null;
      if (completer != null && !completer.isCompleted) completer.complete();
    }
  }

  Future<void> waitUntilIdle() {
    if (_activeTransfers == 0) return Future<void>.value();
    return (_idleCompleter ??= Completer<void>()).future;
  }

  bool registerCacheWriter(Future<void> Function() disable) {
    if (!_cachingEnabled || _closed) return false;
    _cacheWriters.add(disable);
    return true;
  }

  void setCachingEnabled(bool enabled) {
    if (_closed) return;
    _cachingEnabled = enabled;
  }

  void unregisterCacheWriter(Future<void> Function() disable) {
    _cacheWriters.remove(disable);
  }

  Future<void> disableCaching() async {
    if (!_cachingEnabled && _cacheWriters.isEmpty) return;
    _cachingEnabled = false;
    final writers = _cacheWriters.toList(growable: false);
    await Future.wait<void>([for (final disable in writers) disable()]);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    mediaClient.close(force: true);
  }
}
