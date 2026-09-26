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
  static const int localMaterializedId = -1;

  final int id;
  final String label;

  const BilibiliStreamQuality({required this.id, required this.label});

  bool get isLocalMaterialized => id == localMaterializedId;

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

/// Per-card cache breakdown distinguishing materialized assets (tracks and
/// playable files downloaded by compose/OCR/transcription) from the playback
/// gateway cache files written while streaming online.
class BilibiliItemCacheBreakdown {
  final int totalBytes;
  final int gatewayBytes;
  final int gatewayFileCount;
  final int materializedBytes;
  final int materializedFileCount;

  const BilibiliItemCacheBreakdown({
    this.totalBytes = 0,
    this.gatewayBytes = 0,
    this.gatewayFileCount = 0,
    this.materializedBytes = 0,
    this.materializedFileCount = 0,
  });

  bool get isEmpty => totalBytes <= 0;
}

bool _isMaterializedCacheFileName(String name) {
  return name == 'materialization.json' ||
      name == 'materialization.json.backup' ||
      name == 'materialization.json.partial' ||
      name == 'materialization.pending_delete' ||
      name.startsWith('materialized_video_') ||
      name.startsWith('materialized_playback_') ||
      name.startsWith('transcription_audio');
}

/// Rolling throughput estimate for one gateway item while bytes stream through
/// the loopback proxy.
class _GatewayTransferMeter {
  final List<({DateTime at, int bytes})> _samples =
      <({DateTime at, int bytes})>[];

  void record(int bytes) {
    if (bytes <= 0) return;
    final now = DateTime.now();
    _samples.add((at: now, bytes: bytes));
    final cutoff = now.subtract(const Duration(seconds: 1));
    while (_samples.isNotEmpty && _samples.first.at.isBefore(cutoff)) {
      _samples.removeAt(0);
    }
  }

  double get bytesPerSecond {
    return measureGatewayBytesPerSecond(_samples, now: DateTime.now());
  }

  void reset() {
    _samples.clear();
  }
}

/// Bytes in the last [window], divided by the full window — not by the time
/// since the first burst. A 2 MB chunk in 50 ms is 2 MB/s over 1 s, not 40.
@visibleForTesting
double measureGatewayBytesPerSecond(
  Iterable<({DateTime at, int bytes})> samples, {
  required DateTime now,
  Duration window = const Duration(seconds: 1),
}) {
  final windowMs = window.inMilliseconds;
  if (windowMs <= 0) return 0;
  final cutoff = now.subtract(window);
  var totalBytes = 0;
  for (final sample in samples) {
    if (sample.at.isBefore(cutoff)) continue;
    totalBytes += sample.bytes;
  }
  if (totalBytes <= 0) return 0;
  return totalBytes * 1000.0 / windowMs;
}

/// Persisted byte-interval map for one DASH track. libmpv does not replay the
/// same Range boundaries after a process restart, so slices must merge.
class _TrackCacheIndex {
  int? totalBytes;
  List<({int start, int endExclusive})> ranges;
  bool dirty;

  _TrackCacheIndex({
    this.totalBytes,
    List<({int start, int endExclusive})>? ranges,
    this.dirty = false,
  }) : ranges = _mergeCachedRanges(ranges ?? const []);

  bool get isComplete {
    final total = totalBytes;
    return total != null && total > 0 && covers(0, total);
  }

  bool covers(int start, int endExclusive) {
    if (endExclusive <= start) return false;
    for (final range in ranges) {
      if (range.start <= start && endExclusive <= range.endExclusive) {
        return true;
      }
    }
    return false;
  }

  int? contiguousEndExclusive(int start) {
    for (final range in ranges) {
      if (range.start <= start && start < range.endExclusive) {
        return range.endExclusive;
      }
    }
    return null;
  }

  void addRange(int start, int endExclusive, {int? totalBytes}) {
    if (endExclusive <= start) return;
    ranges = _mergeCachedRanges([
      ...ranges,
      (start: start, endExclusive: endExclusive),
    ]);
    if (totalBytes != null && totalBytes > 0) this.totalBytes = totalBytes;
    dirty = true;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'totalBytes': totalBytes,
    'ranges': [
      for (final range in ranges) [range.start, range.endExclusive],
    ],
  };

  factory _TrackCacheIndex.fromJson(Map<String, dynamic> json) {
    final rawRanges = json['ranges'];
    final ranges = <({int start, int endExclusive})>[];
    if (rawRanges is List) {
      for (final entry in rawRanges) {
        if (entry is! List || entry.length < 2) continue;
        final start = (entry[0] as num?)?.toInt();
        final endExclusive = (entry[1] as num?)?.toInt();
        if (start == null || endExclusive == null || endExclusive <= start) {
          continue;
        }
        ranges.add((start: start, endExclusive: endExclusive));
      }
    }
    return _TrackCacheIndex(
      totalBytes: (json['totalBytes'] as num?)?.toInt(),
      ranges: ranges,
    );
  }
}

List<({int start, int endExclusive})> _mergeCachedRanges(
  List<({int start, int endExclusive})> input,
) {
  if (input.isEmpty) return const [];
  final sorted = [...input]..sort((a, b) => a.start.compareTo(b.start));
  final merged = <({int start, int endExclusive})>[sorted.first];
  for (var i = 1; i < sorted.length; i++) {
    final current = sorted[i];
    final last = merged.last;
    if (current.start <= last.endExclusive) {
      merged[merged.length - 1] = (
        start: last.start,
        endExclusive: current.endExclusive > last.endExclusive
            ? current.endExclusive
            : last.endExclusive,
      );
    } else {
      merged.add(current);
    }
  }
  return merged;
}

class BilibiliAudioDownloadProgress {
  final int receivedBytes;
  final int? totalBytes;
  final double bytesPerSecond;

  const BilibiliAudioDownloadProgress({
    required this.receivedBytes,
    required this.totalBytes,
    required this.bytesPerSecond,
  });

  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return (receivedBytes / total).clamp(0.0, 1.0);
  }
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
  final Map<String, Future<String>> _transcriptionAudioDownloads = {};
  final Map<String, HttpClient> _transcriptionAudioClients = {};
  final Set<String> _cancelledTranscriptionAudioItems = {};
  final _uuid = const Uuid();
  final _playUrlCache =
      <String, ({BilibiliStreamInfo info, DateTime obtainedAt})>{};

  /// Next/previous episodes pre-built so a notification skip does not wait on
  /// playurl. Spotify/YouTube/Bilibili all warm the adjacent item this way.
  final _warmPlaybacks = <String, BilibiliPreparedPlayback>{};
  final _warmPrepareFutures = <String, Future<BilibiliPreparedPlayback>>{};

  /// Shared CDN client so episode switches reuse TLS instead of handshaking
  /// bilivideo.com again. Per-session clients made every skip look like a
  /// cold download even on gigabit LAN.
  HttpClient? _sharedMediaClient;
  final _gatewayTransferMeters = <String, _GatewayTransferMeter>{};
  DateTime? _lastGatewayTransferNotifyAt;
  final _cacheIoLocks = <String, Future<void>>{};
  HttpServer? _server;
  Future<HttpServer>? _serverFuture;
  Directory? _cacheDirectory;
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

  @visibleForTesting
  int get activePlaybackSessionCount => _sessions.length;

  /// Bytes copied from a CDN body to a player. Tests use this to see that a
  /// disconnected player stops the read, not merely that the kernel buffer
  /// stopped accepting writes.
  @visibleForTesting
  int relayedBodyBytes = 0;

  /// Rolling download speed for the active gateway session of [itemId].
  double gatewayBytesPerSecondFor(String? itemId) {
    if (itemId == null || itemId.isEmpty) return 0;
    return _gatewayTransferMeters[itemId]?.bytesPerSecond ?? 0;
  }

  void _recordGatewayTransfer(String itemId, int bytes) {
    if (bytes <= 0 || itemId.isEmpty) return;
    relayedBodyBytes += bytes;
    final meter = _gatewayTransferMeters.putIfAbsent(
      itemId,
      () => _GatewayTransferMeter(),
    );
    meter.record(bytes);
    final now = DateTime.now();
    final lastNotify = _lastGatewayTransferNotifyAt;
    if (lastNotify != null &&
        now.difference(lastNotify) < const Duration(milliseconds: 120)) {
      return;
    }
    _lastGatewayTransferNotifyAt = now;
    notifyListeners();
  }

  void _resetGatewayTransferMeter(String itemId) {
    _gatewayTransferMeters.remove(itemId)?.reset();
  }

  /// Warms playurl + a gateway session + the CDN TCP/TLS session for [item]
  /// without opening a native player. Notification/Mini skip then only has to
  /// point libmpv at an already-live loopback URL.
  Future<void> prefetch(VideoItem item) async {
    final source = item.sourceRef;
    if (source?.kind != MediaSourceKind.bilibiliStream ||
        source?.cid == null ||
        (source?.bvid?.isEmpty ?? true)) {
      return;
    }
    try {
      await _warmPrepare(item);
    } catch (error) {
      debugPrint('Bilibili neighbor prefetch failed: $error');
    }
  }

  /// Drop warm sessions that are no longer the next/previous queue neighbors.
  void retainWarmPlaybacks(Set<String> itemIds) {
    final staleIds = _warmPlaybacks.keys
        .where((id) => !itemIds.contains(id))
        .toList(growable: false);
    for (final id in staleIds) {
      final playback = _warmPlaybacks.remove(id);
      if (playback != null) unawaited(releasePlayback(playback));
    }
  }

  Future<BilibiliPreparedPlayback> _warmPrepare(VideoItem item) {
    final existing = _warmPlaybacks[item.id];
    if (existing != null) {
      return Future<BilibiliPreparedPlayback>.value(existing);
    }
    return _warmPrepareFutures[item.id] ??= () async {
      try {
        final playback = await prepare(item, allowWarmReuse: false);
        _warmPlaybacks[item.id] = playback;
        unawaited(_warmCdnConnections(playback));
        return playback;
      } finally {
        _warmPrepareFutures.remove(item.id);
      }
    }();
  }

  Future<BilibiliPreparedPlayback> prepare(
    VideoItem item, {
    int? qualityId,
    bool allowWarmReuse = true,
  }) async {
    if (allowWarmReuse) {
      final warm = _takeWarmPlayback(item.id, qualityId: qualityId);
      if (warm != null) {
        _bindCachePolicy(warm, item.id);
        return warm;
      }
      final inFlight = _warmPrepareFutures[item.id];
      if (inFlight != null) {
        final warmed = await inFlight;
        if (qualityId == null || warmed.selectedQuality.id == qualityId) {
          _warmPlaybacks.remove(item.id);
          _bindCachePolicy(warmed, item.id);
          return warmed;
        }
      }
    }
    final source = item.sourceRef;
    if (source == null ||
        source.kind != MediaSourceKind.bilibiliStream ||
        source.cid == null ||
        (source.bvid?.isEmpty ?? true)) {
      throw const FormatException('媒体库条目缺少 Bilibili 播放身份信息');
    }
    final preferredFuture = _ensurePreferredQualityLoaded();
    // Seek-preview sprites are optional metadata. Do not put their download
    // on the critical media-notification -> playback path.
    unawaited(_ensureVideoShot(item));
    final serverFuture = _ensureServer();
    final playUrlFuture = _playUrlFor(source.bvid!, source.cid!);
    await preferredFuture;
    final requested =
        qualityId ?? _preferredQualityId ?? _preferredQualityByItem[item.id];
    final streamInfo = await playUrlFuture;
    final session = await _createSession(
      itemId: item.id,
      source: source,
      fallbackDurationMs: item.durationMs,
      requestedQualityId: requested,
      streamInfo: streamInfo,
    );
    final server = await serverFuture;
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

  /// Resolves the currently available online qualities without creating a
  /// gateway playback session. This keeps a materialized local file as the
  /// active source while still allowing the quality menu to offer online
  /// alternatives.
  Future<List<BilibiliStreamQuality>> listQualities(VideoItem item) async {
    final source = item.sourceRef;
    if (source?.bvid?.isNotEmpty != true || source?.cid == null) {
      throw const FormatException('媒体库条目缺少 Bilibili 播放身份信息');
    }
    final info = await _playUrlFor(source!.bvid!, source.cid!);
    return List<BilibiliStreamQuality>.unmodifiable(_qualitiesFor(info));
  }

  String _playUrlCacheKey(String bvid, int cid) => '$bvid:$cid';

  BilibiliPreparedPlayback? _takeWarmPlayback(String itemId, {int? qualityId}) {
    final warm = _warmPlaybacks[itemId];
    if (warm == null) return null;
    if (qualityId != null && warm.selectedQuality.id != qualityId) {
      return null;
    }
    _warmPlaybacks.remove(itemId);
    return warm;
  }

  void _bindCachePolicy(BilibiliPreparedPlayback playback, String itemId) {
    final session = _sessionForPlayback(playback);
    session?.setCachingEnabled(_cachePolicyByItem[itemId] ?? true);
  }

  _GatewaySession? _sessionForPlayback(BilibiliPreparedPlayback playback) {
    final segments = playback.videoUri.pathSegments;
    if (segments.length < 3 || segments.first != 'session') return null;
    return _sessions[segments[1]];
  }

  /// Starts the CDN handshake for a playback that is about to be opened.
  ///
  /// Safe to call more than once. The body is only the init+index range and
  /// is discarded, so it never writes the track cache. A short cached prefix
  /// would make the player's open-ended Range return a truncated 206 and end
  /// the audio or video track.
  void primeCdnConnections(BilibiliPreparedPlayback playback) {
    unawaited(_warmCdnConnections(playback));
  }

  /// Pull the DASH init+sidx bytes so the next skip's first Range is a
  /// connection reuse, not a TLS handshake to bilivideo.com.
  Future<void> _warmCdnConnections(BilibiliPreparedPlayback playback) async {
    final session = _sessionForPlayback(playback);
    if (session == null || session.isClosed || session.cdnWarmStarted) return;
    session.cdnWarmStarted = true;
    await Future.wait<void>([
      _warmCdnTrack(session, session.selectedAudio),
      _warmCdnTrack(session, session.selectedVideo),
    ]);
  }

  Future<void> _warmCdnTrack(_GatewaySession session, StreamItem track) async {
    final uri = () {
      for (final candidate in <String>[track.baseUrl, ...track.backupUrls]) {
        final parsed = Uri.tryParse(candidate);
        if (parsed != null && _isAllowedMediaUri(parsed)) return parsed;
      }
      return null;
    }();
    if (uri == null) return;
    HttpClientRequest? request;
    void Function()? unbindAbort;
    try {
      if (session.isClosed) return;
      request = await session.mediaClient.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      request.headers.set(HttpHeaders.refererHeader, _referer);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      request.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=0-${_warmRangeEnd(track)}',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 4),
      );
      final done = Completer<void>();
      late final StreamSubscription<List<int>> subscription;
      var cancelled = false;
      var finished = false;
      void abort() {
        if (cancelled) return;
        cancelled = true;
        // A finished body already returned its socket to the keep-alive pool.
        // Cancelling again would destroy that pooled connection.
        if (!finished) unawaited(subscription.cancel());
        if (!done.isCompleted) done.complete();
      }

      subscription = response.listen(
        (_) {},
        onError: (Object _) {
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          finished = true;
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );
      unbindAbort = session.bindTransferAbort(abort);
      try {
        await done.future.timeout(const Duration(seconds: 4));
      } catch (_) {
        // Leave the keep-alive connection alone when the small range
        // finished. Only tear it down if it is still running.
        abort();
      }
    } catch (_) {
    } finally {
      unbindAbort?.call();
    }
  }

  int _warmRangeEnd(StreamItem track) {
    final match = RegExp(r'-(\d+)\s*$').firstMatch(track.indexRange);
    if (match != null) {
      final end = int.tryParse(match.group(1)!);
      if (end != null && end > 0) return end;
    }
    return 4095;
  }

  /// Bilibili CDN URLs stay valid well past [_refreshAge]. Reusing a fresh
  /// playurl avoids a blocking API round-trip when re-opening the same card.
  Future<BilibiliStreamInfo> _playUrlFor(
    String bvid,
    int cid, {
    bool forceRefresh = false,
  }) async {
    final key = _playUrlCacheKey(bvid, cid);
    if (!forceRefresh) {
      final cached = _playUrlCache[key];
      if (cached != null &&
          DateTime.now().difference(cached.obtainedAt) < _refreshAge) {
        return cached.info;
      }
    }
    final info = await apiService.fetchPlayUrl(bvid, cid);
    _playUrlCache[key] = (info: info, obtainedAt: DateTime.now());
    return info;
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

  Future<void> ensureVideoShot(VideoItem item) => _ensureVideoShot(item);

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

  /// Downloads and atomically caches the complete audio track used by ASR.
  /// The file lives under this card's cache directory, so recycle-bin size
  /// accounting and permanent deletion include it automatically.
  Future<String> downloadAudioForTranscription(
    VideoItem item, {
    void Function(BilibiliAudioDownloadProgress progress)? onProgress,
    Future<void>? cancelSignal,
  }) {
    final source = item.sourceRef;
    if (source == null ||
        source.kind != MediaSourceKind.bilibiliStream ||
        source.bvid?.isNotEmpty != true ||
        source.cid == null) {
      throw const FormatException('媒体库条目缺少有效的 Bilibili 音频身份信息');
    }

    final existing = _transcriptionAudioDownloads[item.id];
    if (existing != null) return existing;
    _cancelledTranscriptionAudioItems.remove(item.id);
    final operation = _downloadAudioForTranscription(
      item,
      onProgress: onProgress,
      cancelSignal: cancelSignal,
    );
    _transcriptionAudioDownloads[item.id] = operation;
    operation.whenComplete(() {
      if (identical(_transcriptionAudioDownloads[item.id], operation)) {
        _transcriptionAudioDownloads.remove(item.id);
      }
    }).ignore();
    return operation;
  }

  Future<String> _downloadAudioForTranscription(
    VideoItem item, {
    void Function(BilibiliAudioDownloadProgress progress)? onProgress,
    Future<void>? cancelSignal,
  }) async {
    final root = await _resolveCacheDirectory();
    final itemDir = Directory(p.join(root.path, _safeName(item.id)));
    if (!await itemDir.exists()) await itemDir.create(recursive: true);
    final finalFile = File(p.join(itemDir.path, 'transcription_audio.m4a'));
    final partialFile = File('${finalFile.path}.part');
    await _deleteFileBestEffort(partialFile);
    if (await finalFile.exists()) {
      final length = await finalFile.length();
      if (length > 0) {
        onProgress?.call(
          BilibiliAudioDownloadProgress(
            receivedBytes: length,
            totalBytes: length,
            bytesPerSecond: 0,
          ),
        );
        return finalFile.path;
      }
      await _deleteFileBestEffort(finalFile);
    }

    final client = _createMediaClient();
    _transcriptionAudioClients[item.id] = client;
    var cancelled = false;
    cancelSignal?.then((_) {
      cancelled = true;
      client.close(force: true);
    });

    Object? lastError;
    try {
      final source = item.sourceRef!;
      final info = await apiService.fetchPlayUrl(source.bvid!, source.cid!);
      final compatibleAudio =
          info.audioStreams.where(_hasAllowedMediaUri).toList()..sort((a, b) {
            int codecRank(StreamItem track) {
              final codec = track.codecs.toLowerCase();
              if (codec.startsWith('mp4a')) return 0;
              if (codec.contains('opus')) return 1;
              if (codec.contains('ec-3') || codec.contains('eac3')) return 2;
              if (codec.contains('flac')) return 3;
              return 4;
            }

            final codec = codecRank(a).compareTo(codecRank(b));
            return codec != 0 ? codec : b.bandwidth.compareTo(a.bandwidth);
          });
      if (compatibleAudio.isEmpty) {
        throw StateError('Bilibili 未返回可下载的音轨');
      }
      final audio = compatibleAudio.first;
      final candidates = <String>[
        audio.baseUrl,
        ...audio.backupUrls,
      ].map(Uri.tryParse).whereType<Uri>().where(_isAllowedMediaUri);

      for (final uri in candidates) {
        if (cancelled || _cancelledTranscriptionAudioItems.contains(item.id)) {
          throw StateError('Bilibili 音频下载已取消');
        }
        await _deleteFileBestEffort(partialFile);
        IOSink? sink;
        try {
          final request = await client.getUrl(uri);
          request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
          request.headers.set(HttpHeaders.refererHeader, _referer);
          request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
          final response = await request.close();
          if (response.statusCode != HttpStatus.ok) {
            await response.drain<void>();
            throw HttpException(
              'CDN returned ${response.statusCode}',
              uri: Uri(scheme: uri.scheme, host: uri.host),
            );
          }

          final expected = response.contentLength > 0
              ? response.contentLength
              : null;
          var received = 0;
          var sampleBytes = 0;
          var sampleStarted = DateTime.now();
          sink = partialFile.openWrite();
          await for (final chunk in response) {
            if (cancelled ||
                _cancelledTranscriptionAudioItems.contains(item.id)) {
              throw StateError('Bilibili 音频下载已取消');
            }
            sink.add(chunk);
            received += chunk.length;
            sampleBytes += chunk.length;
            final now = DateTime.now();
            final elapsed = now.difference(sampleStarted);
            if (elapsed >= const Duration(milliseconds: 250) ||
                (expected != null && received >= expected)) {
              final seconds = elapsed.inMicroseconds / 1000000;
              onProgress?.call(
                BilibiliAudioDownloadProgress(
                  receivedBytes: received,
                  totalBytes: expected,
                  bytesPerSecond: seconds > 0 ? sampleBytes / seconds : 0,
                ),
              );
              sampleBytes = 0;
              sampleStarted = now;
            }
          }
          await sink.flush();
          await sink.close();
          sink = null;
          if (received <= 0 || (expected != null && received != expected)) {
            throw StateError(
              expected == null
                  ? 'Bilibili 返回了空音频文件'
                  : 'Bilibili 音频下载不完整 ($received/$expected)',
            );
          }
          await partialFile.rename(finalFile.path);
          onProgress?.call(
            BilibiliAudioDownloadProgress(
              receivedBytes: received,
              totalBytes: received,
              bytesPerSecond: 0,
            ),
          );
          _notifyCacheChanged(item.id);
          return finalFile.path;
        } catch (error) {
          lastError = error;
          try {
            await sink?.close();
          } catch (_) {}
          await _deleteFileBestEffort(partialFile);
          if (cancelled ||
              _cancelledTranscriptionAudioItems.contains(item.id)) {
            throw StateError('Bilibili 音频下载已取消');
          }
        }
      }
      throw StateError('Bilibili 音频 CDN 不可用: $lastError');
    } finally {
      client.close(force: true);
      if (identical(_transcriptionAudioClients[item.id], client)) {
        _transcriptionAudioClients.remove(item.id);
      }
      _cancelledTranscriptionAudioItems.remove(item.id);
      await _deleteFileBestEffort(partialFile);
    }
  }

  Future<void> _deleteFileBestEffort(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> _cancelTranscriptionAudioDownloads([String? itemId]) async {
    final entries = _transcriptionAudioDownloads.entries
        .where((entry) => itemId == null || entry.key == itemId)
        .toList(growable: false);
    for (final entry in entries) {
      _cancelledTranscriptionAudioItems.add(entry.key);
      _transcriptionAudioClients[entry.key]?.close(force: true);
    }
    for (final entry in entries) {
      try {
        await entry.value;
      } catch (_) {}
    }
  }

  /// True when this card already has readable track bytes that the loopback
  /// gateway can serve after a process restart without hitting the CDN.
  Future<bool> hasReusableTrackCache(String itemId) async {
    final dir = await _resolveCacheDirectory();
    final itemDir = Directory(p.join(dir.path, _safeName(itemId)));
    if (!await itemDir.exists()) return false;
    await for (final entity in itemDir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.endsWith('.track') || name.endsWith('.seg')) return true;
    }
    return false;
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

  /// Filesystem-only breakdown of one card's cache into materialized assets
  /// and playback gateway cache files.
  static Future<BilibiliItemCacheBreakdown> inspectItemCacheBreakdown(
    String itemId, {
    Directory? cacheDirectory,
  }) async {
    if (itemId.trim().isEmpty) return const BilibiliItemCacheBreakdown();
    final root = cacheDirectory ?? await _resolveDefaultCacheDirectory();
    final itemDir = Directory(p.join(root.path, _safeNameStatic(itemId)));
    if (!await itemDir.exists()) return const BilibiliItemCacheBreakdown();
    var gatewayBytes = 0;
    var gatewayFiles = 0;
    var materializedBytes = 0;
    var materializedFiles = 0;
    await for (final entity in itemDir.list(followLinks: false)) {
      if (entity is! File) continue;
      int size;
      try {
        size = await entity.length();
      } catch (_) {
        continue;
      }
      if (_isMaterializedCacheFileName(p.basename(entity.path))) {
        materializedBytes += size;
        materializedFiles++;
      } else {
        gatewayBytes += size;
        gatewayFiles++;
      }
    }
    return BilibiliItemCacheBreakdown(
      totalBytes: gatewayBytes + materializedBytes,
      gatewayBytes: gatewayBytes,
      gatewayFileCount: gatewayFiles,
      materializedBytes: materializedBytes,
      materializedFileCount: materializedFiles,
    );
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
    await _cancelTranscriptionAudioDownloads();
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
    await _cancelTranscriptionAudioDownloads(itemId);
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

  /// Releases only the temporary gateway session represented by [playback].
  ///
  /// Quality hand-off briefly keeps two sessions for the same card alive. In
  /// that window [releaseItem] would also close the newly committed stream, so
  /// the player needs a session-scoped release operation.
  Future<void> releasePlayback(BilibiliPreparedPlayback playback) async {
    final segments = playback.videoUri.pathSegments;
    if (segments.length < 3 || segments.first != 'session') return;
    final session = _sessions[segments[1]];
    if (session == null) return;
    await _releaseSessions(<_GatewaySession>[session]);
  }

  Future<void> _releaseSessions(List<_GatewaySession> sessions) async {
    if (sessions.isEmpty) return;
    for (final session in sessions) {
      _sessions.remove(session.token);
      _resetGatewayTransferMeter(session.itemId);
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
    await _cancelTranscriptionAudioDownloads();
    final server = _server;
    _server = null;
    _serverFuture = null;
    await _releaseSessions(_sessions.values.toList(growable: false));
    _warmPlaybacks.clear();
    _warmPrepareFutures.clear();
    final sharedClient = _sharedMediaClient;
    _sharedMediaClient = null;
    sharedClient?.close(force: true);
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
    BilibiliStreamInfo? streamInfo,
    bool forcePlayUrlRefresh = false,
  }) async {
    final resolvedStreamInfo =
        streamInfo ??
        await _playUrlFor(
          source.bvid!,
          source.cid!,
          forceRefresh: forcePlayUrlRefresh,
        );
    if (resolvedStreamInfo.videoStreams.isEmpty ||
        resolvedStreamInfo.audioStreams.isEmpty) {
      throw StateError('当前账号没有可播放的 Bilibili 音视频轨道');
    }
    final video = _selectVideo(resolvedStreamInfo, requestedQualityId);
    final compatibleAudio =
        resolvedStreamInfo.audioStreams.where(_hasAllowedMediaUri).toList()
          ..sort((a, b) {
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
      streamInfo: resolvedStreamInfo,
      selectedVideo: video,
      selectedAudio: audio,
      mediaClient: mediaClient ?? _sharedMediaClientForSessions(),
      durationMs: resolvedStreamInfo.durationMs > 0
          ? resolvedStreamInfo.durationMs
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
    if (await _tryServeCachedTrack(downstream, session, video: video)) {
      return;
    }

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
    final cachedRange = _byteRangeFromContentRange(
      upstream.headers.value(HttpHeaders.contentRangeHeader),
      fallbackStart: _parseByteRange(
        downstream.headers.value(HttpHeaders.rangeHeader),
      )?.start,
      contentLength: upstream.headers.contentLength,
    );

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
          return;
        }
        final range = cachedRange;
        if (range == null) return;
        try {
          await _commitTrackCacheSegment(
            session,
            video: video,
            start: range.start,
            endExclusive: range.endExclusive,
            totalBytes: range.totalBytes,
            tempFile: file,
          );
        } catch (_) {
          try {
            if (await file.exists()) await file.delete();
          } catch (_) {}
        }
      }();
    }

    Future<void> disableCacheWriter() => closeCache(delete: true);

    if (session.isCachingEnabled &&
        (upstream.statusCode == HttpStatus.ok ||
            upstream.statusCode == HttpStatus.partialContent) &&
        cachedRange != null) {
      try {
        cacheFile = await _allocateTrackCacheTempFile(
          session,
          video: video,
          start: cachedRange.start,
          endExclusive: cachedRange.endExclusive,
        );
        sink = cacheFile.openWrite();
        _activeCacheFiles.add(p.normalize(cacheFile.path));
        if (!session.registerCacheWriter(disableCacheWriter)) {
          await disableCacheWriter();
        }
      } catch (_) {}
    }
    try {
      await _relayUpstreamBody(
        downstream: downstream,
        upstream: upstream,
        session: session,
        onBytes: (bytes) {
          if (!cacheDisabled) sink?.add(bytes);
          _recordGatewayTransfer(session.itemId, bytes.length);
        },
      );
    } finally {
      session.unregisterCacheWriter(disableCacheWriter);
      await closeCache(delete: false);
      try {
        await downstream.response.close();
      } catch (_) {}
      _notifyCacheChanged(session.itemId);
    }
  }

  /// Forwards CDN bytes only as fast as libmpv reads them, and stops the CDN
  /// socket when the player disconnects or the session is released.
  ///
  /// A cancelled body is not a failed playback. [_commitTrackCacheSegment]
  /// drops the temp file unless its length is the full advertised range, so
  /// the next open cannot be served a short 206 that ends the track.
  Future<void> _relayUpstreamBody({
    required HttpRequest downstream,
    required HttpClientResponse upstream,
    required _GatewaySession session,
    required void Function(List<int> bytes) onBytes,
  }) async {
    Object? upstreamError;
    StreamSubscription<List<int>>? subscription;
    var cancelled = false;
    late final StreamController<List<int>> controller;

    Future<void> cancelUpstream() {
      if (cancelled) return Future<void>.value();
      cancelled = true;
      return subscription?.cancel() ?? Future<void>.value();
    }

    void abort() {
      unawaited(cancelUpstream());
      if (!controller.isClosed) controller.close();
    }

    controller = StreamController<List<int>>(
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: cancelUpstream,
    );
    subscription = upstream.listen(
      (bytes) {
        if (controller.isClosed) return;
        onBytes(bytes);
        if (!controller.isClosed) controller.add(bytes);
      },
      onError: (Object error, StackTrace stack) {
        upstreamError ??= error;
        if (!controller.isClosed) controller.addError(error, stack);
      },
      onDone: () {
        if (!controller.isClosed) controller.close();
      },
      cancelOnError: false,
    );
    final unbindAbort = session.bindTransferAbort(abort);
    try {
      await downstream.response.addStream(controller.stream);
    } catch (error) {
      // Player seek/switch closes the loopback socket. That is not a CDN
      // failure; the replacement Range is a new request.
      if (upstreamError != null && !session.isClosed) rethrow;
    } finally {
      unbindAbort();
      await cancelUpstream();
      if (!controller.isClosed) await controller.close();
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
      forcePlayUrlRefresh: true,
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

  Future<File> _allocateTrackCacheTempFile(
    _GatewaySession session, {
    required bool video,
    required int start,
    required int endExclusive,
  }) async {
    final itemDir = await _itemCacheDirectory(session.itemId);
    return File(
      p.join(
        itemDir.path,
        '${_trackCachePrefix(session, video: video)}_$start-$endExclusive.seg.tmp',
      ),
    );
  }

  Future<Directory> _itemCacheDirectory(String itemId) async {
    final root = await _resolveCacheDirectory();
    final itemDir = Directory(p.join(root.path, _safeName(itemId)));
    if (!await itemDir.exists()) await itemDir.create(recursive: true);
    return itemDir;
  }

  String _trackCachePrefix(_GatewaySession session, {required bool video}) {
    final track = video ? session.selectedVideo : session.selectedAudio;
    return '${video ? 'video' : 'audio'}_${track.id}';
  }

  Future<void> _commitTrackCacheSegment(
    _GatewaySession session, {
    required bool video,
    required int start,
    required int endExclusive,
    int? totalBytes,
    required File tempFile,
  }) async {
    final prefix = _trackCachePrefix(session, video: video);
    await _runCacheOp('${session.itemId}:$prefix', () async {
      if (!await tempFile.exists()) return;
      final length = await tempFile.length();
      if (length <= 0 || length != endExclusive - start) {
        await tempFile.delete();
        return;
      }
      final itemDir = await _itemCacheDirectory(session.itemId);
      final store = await _openTrackCacheStore(itemDir, prefix);
      await _writeBytesIntoTrackFile(
        store.file,
        start: start,
        source: tempFile,
      );
      await tempFile.delete();
      store.index.addRange(start, endExclusive, totalBytes: totalBytes);
      await _persistTrackCacheIndex(store);
    });
  }

  /// Serves a Range from the sparse track file when the merged interval map
  /// covers it. Exact filename matches are not required, so a restarted
  /// libmpv that asks for a different window can still hit disk.
  ///
  /// The cache IO lock only covers index lookup. Holding it while copying the
  /// HTTP body serialized the next seek behind whatever readahead Range was
  /// already streaming — even a fully cached timestamp then waited seconds.
  Future<bool> _tryServeCachedTrack(
    HttpRequest downstream,
    _GatewaySession session, {
    required bool video,
  }) async {
    final requested = _parseByteRange(
      downstream.headers.value(HttpHeaders.rangeHeader),
    );
    final prefix = _trackCachePrefix(session, video: video);
    final plan = await _runCacheOp('${session.itemId}:$prefix', () async {
      final itemDir = await _itemCacheDirectory(session.itemId);
      final store = await _openTrackCacheStore(itemDir, prefix);
      if (store.index.dirty) await _persistTrackCacheIndex(store);
      if (!await store.file.exists()) return null;

      int sliceStart;
      int sliceEndInclusive;
      var status = HttpStatus.partialContent;
      if (requested == null) {
        if (!store.index.isComplete || store.index.totalBytes == null) {
          return null;
        }
        sliceStart = 0;
        sliceEndInclusive = store.index.totalBytes! - 1;
        status = HttpStatus.ok;
      } else {
        sliceStart = requested.start;
        if (requested.endInclusive == null) {
          final contiguousEnd = store.index.contiguousEndExclusive(sliceStart);
          if (contiguousEnd == null || contiguousEnd <= sliceStart) {
            return null;
          }
          sliceEndInclusive = contiguousEnd - 1;
        } else {
          sliceEndInclusive = requested.endInclusive!;
          if (!store.index.covers(sliceStart, sliceEndInclusive + 1)) {
            // libmpv often asks for a window larger than any one cached
            // slice. Serve the contiguous prefix so a fully-watched file
            // still seeks from disk instead of waiting on CDN.
            final contiguousEnd = store.index.contiguousEndExclusive(
              sliceStart,
            );
            if (contiguousEnd == null || contiguousEnd <= sliceStart) {
              return null;
            }
            sliceEndInclusive = contiguousEnd - 1;
            if (sliceEndInclusive > requested.endInclusive!) {
              sliceEndInclusive = requested.endInclusive!;
            }
          }
        }
      }
      if (sliceStart < 0 || sliceStart > sliceEndInclusive) return null;
      final sliceLength = sliceEndInclusive - sliceStart + 1;
      final fileLength = await store.file.length();
      if (fileLength < sliceStart + sliceLength) return null;
      return _CachedTrackServePlan(
        file: store.file,
        sliceStart: sliceStart,
        sliceLength: sliceLength,
        status: status,
        video: video,
        totalBytes: store.index.totalBytes,
      );
    });
    if (plan == null) return false;

    final sliceEndInclusive = plan.sliceEndInclusive;
    downstream.response.statusCode = plan.status;
    downstream.response.headers.contentType = ContentType(
      plan.video ? 'video' : 'audio',
      'mp4',
    );
    downstream.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    final total = plan.totalBytes;
    if (plan.status == HttpStatus.partialContent) {
      downstream.response.headers.set(
        HttpHeaders.contentRangeHeader,
        total != null && total > sliceEndInclusive
            ? 'bytes ${plan.sliceStart}-$sliceEndInclusive/$total'
            : 'bytes ${plan.sliceStart}-$sliceEndInclusive/*',
      );
    }
    downstream.response.contentLength = plan.sliceLength;
    if (downstream.method == 'HEAD') {
      await downstream.response.close();
      return true;
    }
    final raf = await plan.file.open();
    var stop = false;
    final unbindAbort = session.bindTransferAbort(() => stop = true);
    try {
      await raf.setPosition(plan.sliceStart);
      var remaining = plan.sliceLength;
      await downstream.response.addStream(() async* {
        while (remaining > 0 && !stop) {
          final chunkSize = remaining < 64 * 1024 ? remaining : 64 * 1024;
          final chunk = await raf.read(chunkSize);
          if (chunk.isEmpty || stop) break;
          remaining -= chunk.length;
          yield chunk;
        }
      }());
    } catch (_) {
      // The player closed the socket. Leave the on-disk range intact.
    } finally {
      unbindAbort();
      await raf.close();
      try {
        await downstream.response.close();
      } catch (_) {}
    }
    return true;
  }

  /// Parses `Range: bytes=start-end` / `bytes=start-`. Open-ended ranges leave
  /// [endInclusive] null so any covering segment that contains [start] matches.
  ({int start, int? endInclusive})? _parseByteRange(String? header) {
    if (header == null || header.isEmpty) return null;
    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(header.trim());
    if (match == null) return null;
    final start = int.parse(match.group(1)!);
    final endText = match.group(2)!;
    return (
      start: start,
      endInclusive: endText.isEmpty ? null : int.parse(endText),
    );
  }

  /// Maps a CDN 206 Content-Range, or a 200 with known length, onto a cache
  /// slice `[start, endExclusive)`. Incomplete headers are not cached.
  ({int start, int endExclusive, int? totalBytes})? _byteRangeFromContentRange(
    String? contentRange, {
    int? fallbackStart,
    int contentLength = -1,
  }) {
    if (contentRange != null && contentRange.isNotEmpty) {
      final match = RegExp(
        r'bytes\s+(\d+)-(\d+)/(\d+|\*)',
      ).firstMatch(contentRange);
      if (match != null) {
        final start = int.parse(match.group(1)!);
        final endInclusive = int.parse(match.group(2)!);
        if (endInclusive < start) return null;
        final totalText = match.group(3)!;
        return (
          start: start,
          endExclusive: endInclusive + 1,
          totalBytes: totalText == '*' ? null : int.parse(totalText),
        );
      }
    }
    if (contentLength > 0) {
      final start = fallbackStart ?? 0;
      return (
        start: start,
        endExclusive: start + contentLength,
        totalBytes: fallbackStart == null ? contentLength : null,
      );
    }
    return null;
  }

  Future<({File file, File indexFile, _TrackCacheIndex index})>
  _openTrackCacheStore(Directory itemDir, String prefix) async {
    await _ingestLegacySegFiles(itemDir, prefix);
    final file = File(p.join(itemDir.path, '$prefix.track'));
    final indexFile = File(p.join(itemDir.path, '$prefix.track.json'));
    return (
      file: file,
      indexFile: indexFile,
      index: await _readTrackCacheIndex(indexFile),
    );
  }

  Future<_TrackCacheIndex> _readTrackCacheIndex(File indexFile) async {
    if (!await indexFile.exists()) return _TrackCacheIndex();
    try {
      final decoded = jsonDecode(await indexFile.readAsString());
      if (decoded is Map<String, dynamic>) {
        return _TrackCacheIndex.fromJson(decoded);
      }
      if (decoded is Map) {
        return _TrackCacheIndex.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {}
    return _TrackCacheIndex();
  }

  Future<void> _persistTrackCacheIndex(
    ({File file, File indexFile, _TrackCacheIndex index}) store,
  ) async {
    if (!store.index.dirty) return;
    await store.indexFile.writeAsString(
      jsonEncode(store.index.toJson()),
      flush: true,
    );
    store.index.dirty = false;
  }

  /// Fold leftover per-Range `.seg` dumps into the sparse track file so a
  /// later, differently aligned libmpv Range can still be served.
  Future<void> _ingestLegacySegFiles(Directory itemDir, String prefix) async {
    if (!await itemDir.exists()) return;
    final indexFile = File(p.join(itemDir.path, '$prefix.track.json'));
    final trackFile = File(p.join(itemDir.path, '$prefix.track'));
    var index = await _readTrackCacheIndex(indexFile);
    var changed = false;
    await for (final entity in itemDir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      final match = RegExp(
        '^${RegExp.escape(prefix)}_(\\d+)-(\\d+)\\.seg\$',
      ).firstMatch(name);
      if (match == null) continue;
      final start = int.parse(match.group(1)!);
      final endExclusive = int.parse(match.group(2)!);
      if (!index.covers(start, endExclusive)) {
        await _writeBytesIntoTrackFile(trackFile, start: start, source: entity);
        index.addRange(start, endExclusive);
      }
      try {
        await entity.delete();
      } catch (_) {}
      changed = true;
    }
    if (changed) {
      index.dirty = true;
      await indexFile.writeAsString(jsonEncode(index.toJson()), flush: true);
    }
  }

  Future<void> _writeBytesIntoTrackFile(
    File trackFile, {
    required int start,
    required File source,
  }) async {
    final length = await source.length();
    if (length <= 0) return;
    final endExclusive = start + length;
    final raf = await trackFile.open(mode: FileMode.append);
    try {
      if (await raf.length() < endExclusive) {
        await raf.truncate(endExclusive);
      }
      await raf.setPosition(start);
      final src = await source.open();
      try {
        var remaining = length;
        while (remaining > 0) {
          final chunkSize = remaining < 64 * 1024 ? remaining : 64 * 1024;
          final chunk = await src.read(chunkSize);
          if (chunk.isEmpty) break;
          await raf.writeFrom(chunk);
          remaining -= chunk.length;
        }
      } finally {
        await src.close();
      }
    } finally {
      await raf.close();
    }
  }

  Future<T> _runCacheOp<T>(String key, Future<T> Function() op) {
    final previous = _cacheIoLocks[key] ?? Future<void>.value();
    final run = previous.catchError((_) {}).then((_) => op());
    _cacheIoLocks[key] = run.then((_) {}, onError: (_) {});
    return run;
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

  HttpClient _sharedMediaClientForSessions() {
    return _sharedMediaClient ??= _createMediaClient();
  }

  HttpClient _createMediaClient() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..idleTimeout = const Duration(seconds: 60)
    ..maxConnectionsPerHost = 8;

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

/// Disk slice to copy to a gateway client. Built under the cache IO lock,
/// then streamed without holding that lock.
class _CachedTrackServePlan {
  const _CachedTrackServePlan({
    required this.file,
    required this.sliceStart,
    required this.sliceLength,
    required this.status,
    required this.video,
    this.totalBytes,
  });

  final File file;
  final int sliceStart;
  final int sliceLength;
  final int status;
  final bool video;
  final int? totalBytes;

  int get sliceEndInclusive => sliceStart + sliceLength - 1;
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
  bool cdnWarmStarted = false;
  int _activeTransfers = 0;
  Completer<void>? _idleCompleter;
  final Set<Future<void> Function()> _cacheWriters = {};
  final List<void Function()> _transferAborts = [];

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

  /// Runs [abort] when the session is released. If it is already closed, runs
  /// it immediately so a late transfer cannot keep the CDN socket.
  void Function() bindTransferAbort(void Function() abort) {
    if (_closed) {
      abort();
      return () {};
    }
    _transferAborts.add(abort);
    return () {
      _transferAborts.remove(abort);
    };
  }

  void close() {
    if (_closed) return;
    _closed = true;
    // The shared CDN client outlives a single episode so the next skip can
    // reuse TLS. Stop this session's sockets now; otherwise a disconnected
    // player keeps downloading until the Range ends and the next episode
    // waits for a free connection.
    final aborts = List<void Function()>.of(_transferAborts);
    _transferAborts.clear();
    for (final abort in aborts) {
      try {
        abort();
      } catch (_) {}
    }
  }
}
