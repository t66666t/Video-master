import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/bilibili_models.dart';
import '../models/media_source_ref.dart';
import '../models/video_item.dart';
import '../utils/ffmpeg_utils.dart';
import 'bilibili/bilibili_api_service.dart';
import 'settings_service.dart';

enum MediaMaterializationRequirement { audioOnly, videoFrames, completeMedia }

enum MediaMaterializationStage {
  resolving,
  downloadingVideo,
  downloadingAudio,
  muxing,
  verifying,
  completed,
}

class MediaMaterializationEstimate {
  final int? estimatedBytes;
  final int? qualityId;
  final int? width;
  final int? height;
  final String qualityLabel;
  final bool alreadyAvailable;
  final bool requiresVideoDownload;
  final bool requiresAudioDownload;

  const MediaMaterializationEstimate({
    required this.estimatedBytes,
    required this.qualityId,
    required this.width,
    required this.height,
    required this.qualityLabel,
    required this.alreadyAvailable,
    required this.requiresVideoDownload,
    required this.requiresAudioDownload,
  });
}

class MediaMaterializationProgress {
  final MediaMaterializationStage stage;
  final double progress;
  final String message;
  final int receivedBytes;
  final int? totalBytes;
  final double bytesPerSecond;
  final Duration? remaining;

  const MediaMaterializationProgress({
    required this.stage,
    required this.progress,
    required this.message,
    this.receivedBytes = 0,
    this.totalBytes,
    this.bytesPerSecond = 0,
    this.remaining,
  });
}

/// Snapshot of one currently running materialization download.
///
/// The registry is intentionally in-memory only: finished assets are already
/// persisted through the per-card manifest, and an interrupted process cannot
/// resume a download anyway. The snapshot exists so that any page (compose,
/// OCR, playback) can re-render the live progress of a download that was
/// started elsewhere — previously the progress died with the page that
/// registered the only listener.
class MaterializationTaskSnapshot {
  final String itemId;
  final MediaMaterializationRequirement requirement;
  final int? targetHeight;
  final MediaMaterializationStage stage;
  final double progress;
  final String message;
  final int receivedBytes;
  final int? totalBytes;
  final double bytesPerSecond;
  final Duration? remaining;
  final DateTime startedAt;
  final DateTime updatedAt;

  const MaterializationTaskSnapshot({
    required this.itemId,
    required this.requirement,
    required this.targetHeight,
    required this.stage,
    required this.progress,
    required this.message,
    this.receivedBytes = 0,
    this.totalBytes,
    this.bytesPerSecond = 0,
    this.remaining,
    required this.startedAt,
    required this.updatedAt,
  });

  MaterializationTaskSnapshot withProgress(
    MediaMaterializationProgress progress,
  ) {
    return MaterializationTaskSnapshot(
      itemId: itemId,
      requirement: requirement,
      targetHeight: targetHeight,
      stage: progress.stage,
      progress: progress.progress,
      message: progress.message,
      receivedBytes: progress.receivedBytes,
      totalBytes: progress.totalBytes,
      bytesPerSecond: progress.bytesPerSecond,
      remaining: progress.remaining,
      startedAt: startedAt,
      updatedAt: DateTime.now(),
    );
  }

  MediaMaterializationProgress toProgress() {
    return MediaMaterializationProgress(
      stage: stage,
      progress: progress,
      message: message,
      receivedBytes: receivedBytes,
      totalBytes: totalBytes,
      bytesPerSecond: bytesPerSecond,
      remaining: remaining,
    );
  }
}

class MaterializedMediaLease {
  final String videoId;
  final String? audioPath;
  final String? videoPath;
  final String? completePath;
  final int? qualityId;
  final int? width;
  final int? height;
  final Future<void> Function() _onRelease;
  bool _released = false;

  MaterializedMediaLease({
    required this.videoId,
    required this.audioPath,
    required this.videoPath,
    required this.completePath,
    required this.qualityId,
    required this.width,
    required this.height,
    required Future<void> Function() onRelease,
  }) : _onRelease = onRelease;

  String get requiredVideoPath {
    final path = completePath ?? videoPath;
    if (path == null || path.isEmpty) {
      throw StateError('本地素材不包含视频轨');
    }
    return path;
  }

  String get requiredAudioPath {
    final path = audioPath;
    if (path == null || path.isEmpty) {
      throw StateError('本地素材不包含音频轨');
    }
    return path;
  }

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _onRelease();
  }
}

class MediaMaterializationService extends ChangeNotifier {
  static const _manifestName = 'materialization.json';
  static const _audioName = 'transcription_audio.m4a';
  static const _videoName = 'materialized_video.m4s';
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  static const _referer = 'https://www.bilibili.com/';
  static const _responseHeaderTimeout = Duration(seconds: 20);
  static const _downloadIdleTimeout = Duration(seconds: 30);

  final BilibiliApiService apiService;
  final bool Function(Uri uri)? _mediaUriValidator;
  final Future<bool> Function(String path, String expectedType)?
  _trackValidator;
  Directory? _cacheDirectory;
  final Map<String, Future<void>> _operations = <String, Future<void>>{};
  final Map<String, List<void Function(MediaMaterializationProgress)>>
  _listeners = {};
  final Map<String, Set<HttpClient>> _clients = {};
  final Map<String, int> _leaseCounts = {};
  final Map<String, int> _waiterCounts = {};
  final Set<String> _cancelledItems = {};
  final Set<String> _deletionRetries = {};
  final Map<String, Process> _activeMuxProcesses = {};
  final Map<String, FFmpegSession> _activeMuxSessions = {};
  // 全局下载任务注册表：itemId -> 当前正在进行的素材任务快照。
  final Map<String, MaterializationTaskSnapshot> _activeTasks = {};
  // 后台“可直接播放文件”构建任务（去重用）。
  final Map<String, Future<bool>> _playbackBuilds = {};
  // 音频轨下载去重：合成与后台播放构建可能同时需要音频轨，共享同一个
  // Future，避免两个流程对同一目标文件并发写入。
  final Map<String, Future<_MaterializationManifest>> _audioDownloads = {};
  // 本地可播放文件构建完成通知（供播放页自动切换本地素材档）。
  final List<void Function(String itemId)> _playbackMaterializedListeners =
      [];

  void Function(String itemId)? onCacheChanged;
  void Function(String itemId)? onPlaybackMaterialized;
  Future<void> Function(String itemId)? onDeferredClearCompleted;
  Future<bool> Function(String itemId)? onRequestPlaybackRelease;

  MediaMaterializationService(
    this.apiService, {
    @visibleForTesting bool Function(Uri uri)? mediaUriValidator,
    @visibleForTesting
    Future<bool> Function(String path, String expectedType)? trackValidator,
    @visibleForTesting Directory? cacheDirectory,
  }) : _mediaUriValidator = mediaUriValidator,
       _trackValidator = trackValidator,
       _cacheDirectory = cacheDirectory;

  Future<MediaMaterializationEstimate> estimate(
    VideoItem item,
    MediaMaterializationRequirement requirement, {
    int? targetHeight,
  }) async {
    if (!_isBilibiliStream(item)) {
      final file = File(item.path);
      return MediaMaterializationEstimate(
        estimatedBytes: await file.exists() ? await file.length() : null,
        qualityId: null,
        width: null,
        height: null,
        qualityLabel: '本地文件',
        alreadyAvailable: await file.exists(),
        requiresVideoDownload: false,
        requiresAudioDownload: false,
      );
    }
    BilibiliStreamInfo? resolvedInfo;
    var resolvedTargetHeight = targetHeight;
    if (resolvedTargetHeight == null &&
        requirement != MediaMaterializationRequirement.audioOnly) {
      resolvedInfo = await _fetchStreamInfo(item);
      resolvedTargetHeight = _selectVideo(resolvedInfo).height;
    }
    final manifest = await _readValidManifest(item);
    if (_manifestSatisfies(manifest, requirement, resolvedTargetHeight)) {
      return MediaMaterializationEstimate(
        estimatedBytes: 0,
        qualityId: manifest!.videoQualityId,
        width: manifest.videoWidth,
        height: manifest.videoHeight,
        qualityLabel: _qualityLabel(manifest.videoHeight),
        alreadyAvailable: true,
        requiresVideoDownload: false,
        requiresAudioDownload: false,
      );
    }
    final info = resolvedInfo ?? await _fetchStreamInfo(item);
    final video = requirement == MediaMaterializationRequirement.audioOnly
        ? null
        : _selectVideo(info, targetHeight: resolvedTargetHeight);
    final audio = requirement == MediaMaterializationRequirement.videoFrames
        ? null
        : _selectAudio(info);
    final videoCached =
        manifest?.videoPath != null &&
        (resolvedTargetHeight == null ||
            (manifest?.videoHeight ?? 0) >= resolvedTargetHeight);
    final audioCached = manifest?.audioPath != null;
    final requiresVideoDownload = video != null && !videoCached;
    final requiresAudioDownload = audio != null && !audioCached;
    int? bytes;
    if (info.durationMs > 0) {
      final bandwidth =
          (requiresVideoDownload ? video.bandwidth : 0) +
          (requiresAudioDownload ? audio.bandwidth : 0);
      if (bandwidth > 0) bytes = (bandwidth * info.durationMs / 8000).ceil();
      if (!requiresVideoDownload && !requiresAudioDownload) bytes = 0;
    }
    return MediaMaterializationEstimate(
      estimatedBytes: bytes,
      qualityId: video?.id,
      width: video?.width,
      height: video?.height,
      qualityLabel: video == null ? '音频' : _qualityLabel(video.height),
      alreadyAvailable: false,
      requiresVideoDownload: requiresVideoDownload,
      requiresAudioDownload: requiresAudioDownload,
    );
  }

  Future<MaterializedMediaLease> acquire(
    VideoItem item,
    MediaMaterializationRequirement requirement, {
    int? targetHeight,
    void Function(MediaMaterializationProgress progress)? onProgress,
    Future<void>? cancelSignal,
  }) async {
    if (!_isBilibiliStream(item)) {
      if (!await File(item.path).exists()) throw StateError('媒体文件不存在');
      return MaterializedMediaLease(
        videoId: item.id,
        audioPath: requirement == MediaMaterializationRequirement.videoFrames
            ? null
            : item.path,
        videoPath: item.path,
        completePath: item.path,
        qualityId: null,
        width: null,
        height: null,
        onRelease: () async {},
      );
    }

    final resolvedTargetHeight = await _resolveTargetHeight(
      item,
      requirement,
      targetHeight,
    );
    _waiterCounts[item.id] = (_waiterCounts[item.id] ?? 0) + 1;
    if (onProgress != null) {
      _listeners.putIfAbsent(item.id, () => []).add(onProgress);
    }
    var callerCancelled = false;
    cancelSignal?.then((_) => callerCancelled = true);
    try {
      while (true) {
        if (callerCancelled) throw StateError('本地素材准备已取消');
        final manifest = await _readValidManifest(item);
        if (_manifestSatisfies(manifest, requirement, resolvedTargetHeight)) {
          _leaseCounts[item.id] = (_leaseCounts[item.id] ?? 0) + 1;
          return _leaseFor(item.id, manifest!, requirement);
        }

        final existing = _operations[item.id];
        if (existing != null) {
          await Future.any<void>([existing, ?cancelSignal]);
          continue;
        }

        _cancelledItems.remove(item.id);
        final operation = _materialize(
          item,
          requirement,
          targetHeight: resolvedTargetHeight,
        );
        _operations[item.id] = operation;
        operation.whenComplete(() {
          if (identical(_operations[item.id], operation)) {
            _operations.remove(item.id);
          }
        }).ignore();
        await Future.any<void>([operation, ?cancelSignal]);
        if (callerCancelled) {
          if ((_waiterCounts[item.id] ?? 1) <= 1) {
            await _cancelOperation(item.id);
          }
          throw StateError('本地素材准备已取消');
        }
        await operation;
      }
    } finally {
      final waiterCount = (_waiterCounts[item.id] ?? 1) - 1;
      if (waiterCount <= 0) {
        _waiterCounts.remove(item.id);
      } else {
        _waiterCounts[item.id] = waiterCount;
      }
      if (onProgress != null) _listeners[item.id]?.remove(onProgress);
      if (_listeners[item.id]?.isEmpty == true) _listeners.remove(item.id);
    }
  }

  Future<File?> getVerifiedPlaybackFile(VideoItem item) async {
    if (!_isBilibiliStream(item)) return null;
    final manifest = await _readValidManifest(item);
    final path = manifest?.completePath;
    if (path == null) return null;
    final file = File(path);
    return await _isNonEmpty(file) ? file : null;
  }

  /// Currently running materialization tasks (one per item at most).
  List<MaterializationTaskSnapshot> get activeTasks =>
      List<MaterializationTaskSnapshot>.unmodifiable(_activeTasks.values);

  MaterializationTaskSnapshot? activeTaskFor(String itemId) =>
      _activeTasks[itemId];

  /// Whether a background "directly playable local file" build is running.
  bool isBuildingPlaybackFile(String itemId) =>
      _playbackBuilds.containsKey(itemId);

  /// Cancels the running materialization for [itemId] from anywhere
  /// (progress cards, cache management UI). Safe to call when idle.
  Future<void> cancelActiveTask(String itemId) => _cancelOperation(itemId);

  /// Notified when a directly playable local file becomes available for an
  /// item (freshly muxed or completed by any feature).
  void addPlaybackMaterializedListener(void Function(String itemId) listener) {
    _playbackMaterializedListeners.add(listener);
  }

  void removePlaybackMaterializedListener(
    void Function(String itemId) listener,
  ) {
    _playbackMaterializedListeners.remove(listener);
  }

  void _notifyPlaybackMaterialized(String itemId) {
    for (final listener in _playbackMaterializedListeners.toList(
      growable: false,
    )) {
      try {
        listener(itemId);
      } catch (_) {}
    }
  }

  Future<MaterializedMediaLease?> acquireExistingPlayback(
    VideoItem item,
  ) async {
    if (!_isBilibiliStream(item)) return null;
    var manifest = await _readValidManifest(item);
    if (manifest == null) return null;
    if (manifest.completePath != null &&
        await _isNonEmpty(File(manifest.completePath!))) {
      if (await _probeHasVideoAndAudio(manifest.completePath!)) {
        _leaseCounts[item.id] = (_leaseCounts[item.id] ?? 0) + 1;
        return _leaseFor(
          item.id,
          manifest,
          MediaMaterializationRequirement.completeMedia,
        );
      }
      final invalidPath = manifest.completePath!;
      manifest = manifest.copyWith(clearComplete: true);
      final root = await _resolveCacheDirectory();
      final dir = Directory(p.join(root.path, _safeName(item.id)));
      await _writeManifest(dir, manifest);
      await _deleteBestEffort(File(invalidPath));
    }
    // 曲目级复用：合成/OCR/转写已经把视频（或音视频）轨落到磁盘上时，
    // 后台把可直接播放的本地文件补齐。构建完成后会发出
    // playback-materialized 通知，播放页随即切到“本地素材”画质；
    // 再次播放时则直接命中本地文件，不再整段在线重播。
    if (manifest.videoPath != null &&
        !_playbackBuilds.containsKey(item.id) &&
        !_operations.containsKey(item.id)) {
      unawaited(ensurePlaybackFileReady(item));
    }
    return null;
  }

  /// Builds (or joins) the directly playable local file from tracks that are
  /// already on disk, downloading the audio track first when it is missing.
  /// Never throws; returns whether a verified playable file is available.
  Future<bool> ensurePlaybackFileReady(VideoItem item) {
    final existing = _playbackBuilds[item.id];
    if (existing != null) return existing;
    final build = _buildPlaybackFile(item);
    _playbackBuilds[item.id] = build;
    unawaited(
      build.whenComplete(() {
        if (identical(_playbackBuilds[item.id], build)) {
          _playbackBuilds.remove(item.id);
        }
      }),
    );
    return build;
  }

  Future<bool> _buildPlaybackFile(VideoItem item) async {
    var taskRegistered = false;
    try {
      var manifest = await _readValidManifest(item);
      if (manifest == null) return false;
      if (manifest.completePath != null &&
          await _isNonEmpty(File(manifest.completePath!)) &&
          await _probeHasVideoAndAudio(manifest.completePath!)) {
        return true;
      }
      if (manifest.videoPath == null) return false;
      // A caller-driven materialization may be running for this item; let it
      // finish instead of racing it on the same manifest and target files.
      if (_operations.containsKey(item.id)) return false;

      _beginTask(
        item,
        MediaMaterializationRequirement.completeMedia,
        manifest.videoHeight,
      );
      taskRegistered = true;

      final root = await _resolveCacheDirectory();
      final itemDir = Directory(p.join(root.path, _safeName(item.id)));
      // 音频轨缺失时下载之。与合成等流程共享同一个按卡片去重的下载
      // Future，避免两个流程对同一目标文件并发写入。
      manifest = await _ensureAudioTrack(
        item,
        itemDir,
        manifest,
        requirement: MediaMaterializationRequirement.completeMedia,
      );
      final audioPath = manifest.audioPath;
      if (audioPath == null) return false;

      final completeName =
          'materialized_playback_q${manifest.videoQualityId ?? 0}.mp4';
      final completePath = p.join(itemDir.path, completeName);
      // 只做流式复制封装：转码对于播放前准备来说太慢，失败时放弃本次构建，
      // 播放页继续在线播放，下次播放再重试。
      await _mux(
        item.id,
        manifest.videoPath!,
        audioPath,
        completePath,
        manifest.durationMs,
        allowTranscodeFallback: false,
      );
      final fresh = await _readValidManifest(item) ?? manifest;
      manifest = fresh.copyWith(
        completePath: completePath,
        completeVideoQualityId: manifest.videoQualityId,
        completeVideoWidth: manifest.videoWidth,
        completeVideoHeight: manifest.videoHeight,
      );
      await _writeManifest(itemDir, manifest);
      onPlaybackMaterialized?.call(item.id);
      _notifyPlaybackMaterialized(item.id);
      _notifyCacheChanged(item.id);
      return true;
    } catch (error) {
      debugPrint('Local playback file build failed for ${item.id}: $error');
      return false;
    } finally {
      if (taskRegistered) _endTask(item.id);
    }
  }

  /// 保证卡片拥有可用的音频轨并返回含 `audioPath` 的最新 manifest。
  ///
  /// 需要音频轨的流程（合成、AI 转写、后台播放文件构建）统一走这里：
  /// - 同一卡片上的并发请求共享同一个下载 Future，杜绝同文件并发写入；
  /// - 下载完成后以磁盘最新 manifest 为基底写入，避免覆盖并发更新的视频轨。
  Future<_MaterializationManifest> _ensureAudioTrack(
    VideoItem item,
    Directory itemDir,
    _MaterializationManifest manifest, {
    required MediaMaterializationRequirement requirement,
    BilibiliStreamInfo? knownInfo,
  }) async {
    if (requirement == MediaMaterializationRequirement.videoFrames) {
      return manifest;
    }
    if (manifest.audioPath != null &&
        await _isNonEmpty(File(manifest.audioPath!))) {
      return manifest;
    }
    final existing = _audioDownloads[item.id];
    if (existing != null) {
      final updated = await existing;
      return await _readValidManifest(item) ?? updated;
    }
    final path = p.join(itemDir.path, _audioName);
    final download = () async {
      final info = knownInfo ?? await _fetchStreamInfo(item);
      final audio = _selectAudio(info);
      final downloadedAudio = await _downloadTrackWithRefresh(
        item,
        item.id,
        audio,
        path,
        refreshedTrack: _selectAudio,
        stage: MediaMaterializationStage.downloadingAudio,
        progressStart: requirement == MediaMaterializationRequirement.audioOnly
            ? 0.03
            : 0.68,
        progressEnd: requirement == MediaMaterializationRequirement.audioOnly
            ? 0.96
            : 0.84,
        label: '音频素材',
      );
      if (!await _probeHasStream(path, 'audio')) {
        await _deleteBestEffort(File(path));
        throw StateError('下载的音频素材没有可解码的音频轨');
      }
      final base = await _readValidManifest(item) ?? manifest;
      final updated = base.copyWith(
        audioPath: path,
        audioCodec: downloadedAudio.codecs,
        durationMs: info.durationMs,
      );
      await _writeManifest(itemDir, updated);
      return updated;
    }();
    _audioDownloads[item.id] = download;
    try {
      return await download;
    } finally {
      if (identical(_audioDownloads[item.id], download)) {
        _audioDownloads.remove(item.id);
      }
    }
  }

  Future<bool> clearCard(String itemId) async {
    if (itemId.trim().isEmpty) return true;
    await _cancelOperation(itemId);
    try {
      await onRequestPlaybackRelease?.call(itemId);
    } catch (_) {
      // If online hand-off is unavailable, the active lease below keeps the
      // file intact and turns this into a deferred deletion.
    }
    final root = await _resolveCacheDirectory();
    final dir = Directory(p.join(root.path, _safeName(itemId)));
    if (!await dir.exists()) return true;
    if ((_leaseCounts[itemId] ?? 0) > 0) {
      await _markPendingDeletion(dir);
      return false;
    }
    final names = <String>{
      _manifestName,
      '$_manifestName.backup',
      _audioName,
      _videoName,
      'materialization.pending_delete',
    };
    var failed = false;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!names.contains(name) &&
          !name.startsWith('materialized_video_') &&
          !name.startsWith('materialized_playback_') &&
          !name.endsWith('.part') &&
          !name.endsWith('.partial')) {
        continue;
      }
      try {
        await entity.delete();
      } catch (_) {
        failed = true;
      }
    }
    if (failed) {
      try {
        await _markPendingDeletion(dir);
      } catch (_) {}
      _scheduleDeletionRetry(itemId);
    }
    _notifyCacheChanged(itemId);
    return !failed;
  }

  void _scheduleDeletionRetry(String itemId) {
    if (!_deletionRetries.add(itemId)) return;
    unawaited(() async {
      try {
        for (var attempt = 0; attempt < 3; attempt++) {
          await Future<void>.delayed(
            Duration(milliseconds: 400 * (attempt + 1)),
          );
          if ((_leaseCounts[itemId] ?? 0) > 0) return;
          final completed = await clearCard(itemId);
          if (completed) {
            await onDeferredClearCompleted?.call(itemId);
            return;
          }
        }
      } finally {
        _deletionRetries.remove(itemId);
      }
    }());
  }

  Future<void> cleanupPendingDeletions() async {
    final root = await _resolveCacheDirectory();
    if (!await root.exists()) return;
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      await for (final file in entity.list(followLinks: false)) {
        if (file is File &&
            (file.path.endsWith('.part') || file.path.endsWith('.partial'))) {
          await _deleteBestEffort(file);
        }
      }
      final marker = File(
        p.join(entity.path, 'materialization.pending_delete'),
      );
      if (await marker.exists()) {
        final itemId = p.basename(entity.path);
        final completed = await clearCard(itemId);
        if (completed) await onDeferredClearCompleted?.call(itemId);
      }
    }
  }

  Future<void> markCardForDeletion(String itemId) async {
    if (itemId.trim().isEmpty) return;
    final root = await _resolveCacheDirectory();
    await _markPendingDeletion(Directory(p.join(root.path, _safeName(itemId))));
  }

  Future<void> shutdown() async {
    for (final id in _operations.keys.toList(growable: false)) {
      await _cancelOperation(id);
    }
  }

  Future<void> _materialize(
    VideoItem item,
    MediaMaterializationRequirement requirement, {
    int? targetHeight,
  }) async {
    // 注册到全局任务表，保证页面退出后其它页面仍能看到下载进度。
    _beginTask(item, requirement, targetHeight);
    try {
      await _materializeBody(item, requirement, targetHeight: targetHeight);
    } finally {
      _endTask(item.id);
    }
  }

  Future<void> _materializeBody(
    VideoItem item,
    MediaMaterializationRequirement requirement, {
    int? targetHeight,
  }) async {
    _emit(
      item.id,
      const MediaMaterializationProgress(
        stage: MediaMaterializationStage.resolving,
        progress: 0.01,
        message: '正在获取 Bilibili 素材信息',
      ),
    );
    final info = await _fetchStreamInfo(item);
    _throwIfCancelled(item.id);
    var manifest =
        await _readValidManifest(item) ?? _MaterializationManifest.empty(item);
    final root = await _resolveCacheDirectory();
    final itemDir = Directory(p.join(root.path, _safeName(item.id)));
    if (!await itemDir.exists()) await itemDir.create(recursive: true);

    StreamItem? video;
    if (requirement != MediaMaterializationRequirement.audioOnly) {
      video = _selectVideo(info, targetHeight: targetHeight);
      final cachedHeight = manifest.videoHeight ?? 0;
      if (manifest.videoPath == null || cachedHeight < video.height) {
        final oldVideoPath = manifest.videoPath;
        final path = p.join(
          itemDir.path,
          'materialized_video_q${video.id}.m4s',
        );
        video = await _downloadTrackWithRefresh(
          item,
          item.id,
          video,
          path,
          refreshedTrack: (fresh) =>
              _selectVideo(fresh, targetHeight: targetHeight),
          stage: MediaMaterializationStage.downloadingVideo,
          progressStart: 0.03,
          progressEnd:
              requirement == MediaMaterializationRequirement.videoFrames
              ? 0.94
              : 0.67,
          label: '视频素材',
        );
        if (!await _probeHasStream(path, 'video')) {
          await _deleteBestEffort(File(path));
          throw StateError('下载的视频素材没有可解码的视频轨');
        }
        manifest = manifest.copyWith(
          videoPath: path,
          videoQualityId: video.id,
          videoWidth: video.width,
          videoHeight: video.height,
          videoCodec: video.codecs,
          durationMs: info.durationMs,
        );
        await _writeManifest(itemDir, manifest);
        if (oldVideoPath != null &&
            oldVideoPath != path &&
            (_leaseCounts[item.id] ?? 0) == 0) {
          await _deleteBestEffort(File(oldVideoPath));
        }
      }
    }

    if (requirement != MediaMaterializationRequirement.videoFrames) {
      // 经共享的音频轨保证方法下载（按卡片去重），避免与后台播放文件构建
      // 对同一目标文件并发写入。
      manifest = await _ensureAudioTrack(
        item,
        itemDir,
        manifest,
        requirement: requirement,
        knownInfo: info,
      );
    }

    if (requirement == MediaMaterializationRequirement.completeMedia) {
      final completeName =
          'materialized_playback_q${manifest.videoQualityId ?? 0}.mp4';
      final completePath = p.join(itemDir.path, completeName);
      final oldCompletePath = manifest.completePath;
      if (manifest.completePath != completePath ||
          !await _isNonEmpty(File(completePath))) {
        await _mux(
          item.id,
          manifest.videoPath!,
          manifest.audioPath!,
          completePath,
          manifest.durationMs,
        );
        manifest = manifest.copyWith(
          completePath: completePath,
          completeVideoQualityId: manifest.videoQualityId,
          completeVideoWidth: manifest.videoWidth,
          completeVideoHeight: manifest.videoHeight,
        );
        await _writeManifest(itemDir, manifest);
        if (oldCompletePath != null &&
            oldCompletePath != completePath &&
            (_leaseCounts[item.id] ?? 0) == 0) {
          await _deleteBestEffort(File(oldCompletePath));
        }
        onPlaybackMaterialized?.call(item.id);
        _notifyPlaybackMaterialized(item.id);
      }
    }

    _emit(
      item.id,
      const MediaMaterializationProgress(
        stage: MediaMaterializationStage.verifying,
        progress: 0.98,
        message: '正在校验本地素材',
      ),
    );
    if (!_manifestSatisfies(manifest, requirement, targetHeight)) {
      throw StateError('本地素材校验失败');
    }
    _emit(
      item.id,
      const MediaMaterializationProgress(
        stage: MediaMaterializationStage.completed,
        progress: 1,
        message: '本地素材已准备完成',
      ),
    );
    _notifyCacheChanged(item.id);
    // 注：素材化完成后不在此处自动补齐“可直接播放文件”。视频轨归属当前
    // 卡片，播放页每次播放时（acquireExistingPlayback）会按需后台补齐，
    // 完整 OCR 任务则在其管理器里主动触发，避免对一次性预览抓帧造成多余的
    // 音频下载。
  }

  Future<void> _downloadTrack(
    String itemId,
    StreamItem track,
    String finalPath, {
    required MediaMaterializationStage stage,
    required double progressStart,
    required double progressEnd,
    required String label,
  }) async {
    final finalFile = File(finalPath);
    final part = File('$finalPath.part');
    await _deleteBestEffort(part);
    Object? lastError;
    for (final uri in <String>[
      track.baseUrl,
      ...track.backupUrls,
    ].map(Uri.tryParse).whereType<Uri>().where(_isAllowedMediaUri)) {
      _throwIfCancelled(itemId);
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 12);
      _clients.putIfAbsent(itemId, () => <HttpClient>{}).add(client);
      IOSink? sink;
      try {
        final request = await client.getUrl(uri);
        request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
        request.headers.set(HttpHeaders.refererHeader, _referer);
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        final response = await request.close().timeout(
          _responseHeaderTimeout,
          onTimeout: () => throw TimeoutException('$label连接响应超时'),
        );
        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>();
          throw HttpException('CDN 返回 ${response.statusCode}');
        }
        final total = response.contentLength > 0
            ? response.contentLength
            : null;
        var received = 0;
        var sampleBytes = 0;
        var sampleAt = DateTime.now();
        sink = part.openWrite();
        await for (final chunk in response.timeout(_downloadIdleTimeout)) {
          _throwIfCancelled(itemId);
          sink.add(chunk);
          received += chunk.length;
          sampleBytes += chunk.length;
          final now = DateTime.now();
          final elapsed = now.difference(sampleAt);
          if (elapsed >= const Duration(milliseconds: 250) ||
              (total != null && received >= total)) {
            final seconds = elapsed.inMicroseconds / 1000000;
            final speed = seconds > 0 ? sampleBytes / seconds : 0.0;
            final fraction = total == null || total <= 0
                ? 0.0
                : (received / total).clamp(0.0, 1.0);
            final remaining = speed > 0 && total != null
                ? Duration(seconds: ((total - received) / speed).ceil())
                : null;
            _emit(
              itemId,
              MediaMaterializationProgress(
                stage: stage,
                progress:
                    progressStart + (progressEnd - progressStart) * fraction,
                message: '正在下载$label',
                receivedBytes: received,
                totalBytes: total,
                bytesPerSecond: speed,
                remaining: remaining,
              ),
            );
            sampleBytes = 0;
            sampleAt = now;
          }
        }
        await sink.flush();
        await sink.close();
        sink = null;
        if (received <= 0 || (total != null && received != total)) {
          throw StateError('$label下载不完整 ($received/${total ?? '?'})');
        }
        await _deleteBestEffort(finalFile);
        await part.rename(finalPath);
        return;
      } catch (error) {
        lastError = error;
        try {
          await sink?.close();
        } catch (_) {}
        await _deleteBestEffort(part);
        _throwIfCancelled(itemId);
      } finally {
        client.close(force: true);
        _clients[itemId]?.remove(client);
      }
    }
    throw StateError('$label下载失败: $lastError');
  }

  Future<StreamItem> _downloadTrackWithRefresh(
    VideoItem item,
    String itemId,
    StreamItem track,
    String finalPath, {
    required StreamItem Function(BilibiliStreamInfo info) refreshedTrack,
    required MediaMaterializationStage stage,
    required double progressStart,
    required double progressEnd,
    required String label,
  }) async {
    try {
      await _downloadTrack(
        itemId,
        track,
        finalPath,
        stage: stage,
        progressStart: progressStart,
        progressEnd: progressEnd,
        label: label,
      );
      return track;
    } catch (firstError) {
      _throwIfCancelled(itemId);
      _emit(
        itemId,
        MediaMaterializationProgress(
          stage: MediaMaterializationStage.resolving,
          progress: progressStart,
          message: '$label地址已失效，正在刷新一次',
        ),
      );
      final freshInfo = await _fetchStreamInfo(item);
      final freshTrack = refreshedTrack(freshInfo);
      try {
        await _downloadTrack(
          itemId,
          freshTrack,
          finalPath,
          stage: stage,
          progressStart: progressStart,
          progressEnd: progressEnd,
          label: label,
        );
        return freshTrack;
      } catch (secondError) {
        throw StateError(
          '$label下载失败（刷新地址后仍失败）: $secondError；首次错误: $firstError',
        );
      }
    }
  }

  Future<void> _mux(
    String itemId,
    String videoPath,
    String audioPath,
    String outputPath,
    int expectedDurationMs, {
    bool allowTranscodeFallback = true,
  }) async {
    final partial = '$outputPath.partial';
    await _deleteBestEffort(File(partial));
    _emit(
      itemId,
      const MediaMaterializationProgress(
        stage: MediaMaterializationStage.muxing,
        progress: 0.86,
        message: '正在封装本地音视频',
      ),
    );
    final copyArgs = <String>[
      '-y',
      '-i',
      videoPath,
      '-i',
      audioPath,
      '-map',
      '0:v:0',
      '-map',
      '1:a:0',
      '-c',
      'copy',
      '-movflags',
      '+faststart',
      '-f',
      'mp4',
      partial,
    ];
    try {
      try {
        await _executeFfmpeg(itemId, copyArgs);
        if (!await _probeHasVideoAndAudio(partial)) {
          throw StateError('直接封装后的文件不可解码');
        }
      } catch (copyError) {
        if (!allowTranscodeFallback) rethrow;
        _throwIfCancelled(itemId);
        await _deleteBestEffort(File(partial));
        final transcodeArgs = <String>[
          '-y',
          '-i',
          videoPath,
          '-i',
          audioPath,
          '-map',
          '0:v:0',
          '-map',
          '1:a:0',
          '-c:v',
          'libx264',
          '-preset',
          'veryfast',
          '-c:a',
          'aac',
          '-movflags',
          '+faststart',
          '-f',
          'mp4',
          partial,
        ];
        await _executeFfmpeg(itemId, transcodeArgs);
      }
      _throwIfCancelled(itemId);
      if (!await _probeHasVideoAndAudio(partial)) {
        throw StateError('封装后的本地视频校验失败');
      }
      final durationMs = await _probeDurationMs(partial);
      if (expectedDurationMs > 0 &&
          (durationMs == null ||
              (durationMs - expectedDurationMs).abs() >
                  (expectedDurationMs * 0.05).clamp(2000, 15000))) {
        throw StateError('封装后的本地视频时长校验失败');
      }
      await _deleteBestEffort(File(outputPath));
      await File(partial).rename(outputPath);
    } finally {
      _activeMuxProcesses.remove(itemId);
      _activeMuxSessions.remove(itemId);
      await _deleteBestEffort(File(partial));
    }
  }

  Future<void> _executeFfmpeg(String itemId, List<String> args) async {
    if (Platform.isWindows) {
      final ffmpeg = await FFmpegUtils.ffmpegPath;
      final process = await Process.start(ffmpeg, args);
      _activeMuxProcesses[itemId] = process;
      final stderr = process.stderr.transform(systemEncoding.decoder).join();
      await process.stdout.drain<void>();
      final code = await process.exitCode;
      final error = await stderr;
      if (code != 0) throw StateError('封装失败: ${_lastLine(error)}');
      return;
    }
    final completed = Completer<FFmpegSession>();
    final session = await FFmpegKit.executeWithArgumentsAsync(args, (finished) {
      if (!completed.isCompleted) completed.complete(finished);
    });
    _activeMuxSessions[itemId] = session;
    final finished = await completed.future;
    final code = await finished.getReturnCode();
    if (!ReturnCode.isSuccess(code)) {
      throw StateError('封装失败: ${await finished.getAllLogsAsString()}');
    }
  }

  Future<bool> _probeHasStream(String path, String expectedType) async {
    final validator = _trackValidator;
    if (validator != null) return validator(path, expectedType);
    if (!await _isNonEmpty(File(path))) return false;
    try {
      if (Platform.isWindows) {
        final ffprobe = await FFmpegUtils.ffprobePath;
        final result = await Process.run(ffprobe, <String>[
          '-v',
          'error',
          '-show_entries',
          'stream=codec_type',
          '-of',
          'csv=p=0',
          path,
        ]).timeout(const Duration(seconds: 30));
        return result.exitCode == 0 &&
            result.stdout.toString().contains(expectedType);
      }
      final session = await FFprobeKit.getMediaInformation(path);
      final streams = session.getMediaInformation()?.getStreams() ?? const [];
      return streams.any((stream) => stream.getType() == expectedType);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _probeHasVideoAndAudio(String path) async {
    if (!await _isNonEmpty(File(path))) return false;
    try {
      if (Platform.isWindows) {
        final ffprobe = await FFmpegUtils.ffprobePath;
        final result = await Process.run(ffprobe, <String>[
          '-v',
          'error',
          '-show_entries',
          'stream=codec_type',
          '-of',
          'csv=p=0',
          path,
        ]).timeout(const Duration(seconds: 30));
        final output = result.stdout.toString();
        return result.exitCode == 0 &&
            output.contains('video') &&
            output.contains('audio');
      }
      final session = await FFprobeKit.getMediaInformation(path);
      final information = session.getMediaInformation();
      final streams = information?.getStreams() ?? const [];
      final types = streams.map((stream) => stream.getType()).toSet();
      return types.contains('video') && types.contains('audio');
    } catch (_) {
      return false;
    }
  }

  Future<int?> _probeDurationMs(String path) async {
    try {
      if (Platform.isWindows) {
        final ffprobe = await FFmpegUtils.ffprobePath;
        final result = await Process.run(ffprobe, <String>[
          '-v',
          'error',
          '-show_entries',
          'format=duration',
          '-of',
          'default=noprint_wrappers=1:nokey=1',
          path,
        ]).timeout(const Duration(seconds: 30));
        if (result.exitCode != 0) return null;
        final seconds = double.tryParse(result.stdout.toString().trim());
        return seconds == null ? null : (seconds * 1000).round();
      }
      final session = await FFprobeKit.getMediaInformation(path);
      final raw = session.getMediaInformation()?.getDuration();
      final seconds = double.tryParse(raw ?? '');
      return seconds == null ? null : (seconds * 1000).round();
    } catch (_) {
      return null;
    }
  }

  Future<void> _cancelOperation(String itemId) async {
    _cancelledItems.add(itemId);
    for (final client in _clients[itemId]?.toList() ?? const <HttpClient>[]) {
      client.close(force: true);
    }
    _activeMuxProcesses[itemId]?.kill();
    await _activeMuxSessions[itemId]?.cancel();
    final operation = _operations[itemId];
    if (operation != null) {
      try {
        await operation.timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    _cancelledItems.remove(itemId);
  }

  MaterializedMediaLease _leaseFor(
    String itemId,
    _MaterializationManifest manifest,
    MediaMaterializationRequirement requirement,
  ) {
    return MaterializedMediaLease(
      videoId: itemId,
      audioPath: manifest.audioPath,
      videoPath: manifest.videoPath,
      completePath: requirement == MediaMaterializationRequirement.completeMedia
          ? manifest.completePath
          : null,
      qualityId: requirement == MediaMaterializationRequirement.completeMedia
          ? manifest.completeVideoQualityId
          : manifest.videoQualityId,
      width: requirement == MediaMaterializationRequirement.completeMedia
          ? manifest.completeVideoWidth
          : manifest.videoWidth,
      height: requirement == MediaMaterializationRequirement.completeMedia
          ? manifest.completeVideoHeight
          : manifest.videoHeight,
      onRelease: () async {
        final count = ((_leaseCounts[itemId] ?? 1) - 1).clamp(0, 1 << 30);
        if (count == 0) {
          _leaseCounts.remove(itemId);
          await _finishIdleCleanup(itemId);
        } else {
          _leaseCounts[itemId] = count;
        }
      },
    );
  }

  Future<BilibiliStreamInfo> _fetchStreamInfo(VideoItem item) {
    final source = item.sourceRef;
    if (source?.bvid?.isNotEmpty != true || source?.cid == null) {
      throw const FormatException('在线视频卡片缺少 BVID 或 CID');
    }
    return apiService.fetchPlayUrl(source!.bvid!, source.cid!);
  }

  Future<int?> _resolveTargetHeight(
    VideoItem item,
    MediaMaterializationRequirement requirement,
    int? targetHeight,
  ) async {
    if (targetHeight != null ||
        requirement == MediaMaterializationRequirement.audioOnly) {
      return targetHeight;
    }
    final info = await _fetchStreamInfo(item);
    return _selectVideo(info).height;
  }

  StreamItem _selectVideo(BilibiliStreamInfo info, {int? targetHeight}) {
    final valid = info.videoStreams.where(_hasAllowedMediaUri).toList();
    if (valid.isEmpty) throw StateError('Bilibili 未返回可下载的视频轨');
    final heights = valid
        .map((track) => track.height)
        .where((h) => h > 0)
        .toSet();
    final adequate =
        heights
            .where((height) => targetHeight != null && height >= targetHeight)
            .toList()
          ..sort();
    final selectedHeight = targetHeight == null
        ? heights.reduce((a, b) => a > b ? a : b)
        : adequate.isNotEmpty
        ? adequate.first
        : heights.reduce((a, b) => a > b ? a : b);
    final sameHeight =
        valid.where((track) => track.height == selectedHeight).toList()
          ..sort((a, b) {
            int rank(StreamItem track) => switch (track.codecid) {
              7 => 0,
              12 => 1,
              13 => 2,
              _ => 3,
            };
            final codec = rank(a).compareTo(rank(b));
            return codec != 0 ? codec : b.bandwidth.compareTo(a.bandwidth);
          });
    return sameHeight.first;
  }

  StreamItem _selectAudio(BilibiliStreamInfo info) {
    final tracks = info.audioStreams.where(_hasAllowedMediaUri).toList()
      ..sort((a, b) {
        int rank(StreamItem track) {
          final codec = track.codecs.toLowerCase();
          if (codec.startsWith('mp4a')) return 0;
          if (codec.contains('opus')) return 1;
          if (codec.contains('ec-3') || codec.contains('eac3')) return 2;
          if (codec.contains('flac')) return 3;
          return 4;
        }

        final codec = rank(a).compareTo(rank(b));
        return codec != 0 ? codec : b.bandwidth.compareTo(a.bandwidth);
      });
    if (tracks.isEmpty) throw StateError('Bilibili 未返回可下载的音频轨');
    return tracks.first;
  }

  bool _hasAllowedMediaUri(StreamItem track) => <String>[
    track.baseUrl,
    ...track.backupUrls,
  ].map(Uri.tryParse).whereType<Uri>().any(_isAllowedMediaUri);

  bool _isAllowedMediaUri(Uri uri) {
    if (_mediaUriValidator?.call(uri) == true) return true;
    if (uri.scheme != 'https' || uri.host.isEmpty) return false;
    final host = uri.host.toLowerCase();
    return host == 'bilivideo.com' ||
        host.endsWith('.bilivideo.com') ||
        host == 'bilivideo.cn' ||
        host.endsWith('.bilivideo.cn') ||
        host == 'hdslb.com' ||
        host.endsWith('.hdslb.com') ||
        host.endsWith('.akamaized.net');
  }

  Future<_MaterializationManifest?> _readValidManifest(VideoItem item) async {
    final root = await _resolveCacheDirectory();
    final dir = Directory(p.join(root.path, _safeName(item.id)));
    final file = File(p.join(dir.path, _manifestName));
    final backup = File('${file.path}.backup');
    if (!await file.exists() && await backup.exists()) {
      try {
        await backup.rename(file.path);
      } catch (_) {}
    }
    if (!await file.exists()) return _adoptLegacyAudio(item, dir);
    try {
      final manifest = _MaterializationManifest.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
      await _deleteBestEffort(backup);
      final source = item.sourceRef;
      if (manifest.bvid != source?.bvid || manifest.cid != source?.cid) {
        await clearCard(item.id);
        return null;
      }
      var normalized = manifest;
      if (manifest.audioPath != null &&
          !await _isNonEmpty(File(manifest.audioPath!))) {
        normalized = normalized.copyWith(clearAudio: true);
      }
      if (manifest.videoPath != null &&
          !await _isNonEmpty(File(manifest.videoPath!))) {
        normalized = normalized.copyWith(clearVideo: true, clearComplete: true);
      }
      if (manifest.completePath != null &&
          !await _isNonEmpty(File(manifest.completePath!))) {
        normalized = normalized.copyWith(clearComplete: true);
      }
      return normalized;
    } catch (_) {
      await _deleteBestEffort(file);
      return _adoptLegacyAudio(item, dir);
    }
  }

  Future<_MaterializationManifest?> _adoptLegacyAudio(
    VideoItem item,
    Directory dir,
  ) async {
    final audio = File(p.join(dir.path, _audioName));
    if (!await _isNonEmpty(audio)) return null;
    final manifest = _MaterializationManifest.empty(
      item,
    ).copyWith(audioPath: audio.path);
    await _writeManifest(dir, manifest);
    return manifest;
  }

  bool _manifestSatisfies(
    _MaterializationManifest? manifest,
    MediaMaterializationRequirement requirement,
    int? targetHeight,
  ) {
    if (manifest == null) return false;
    final videoReady =
        manifest.videoPath != null &&
        (targetHeight == null || (manifest.videoHeight ?? 0) >= targetHeight);
    return switch (requirement) {
      MediaMaterializationRequirement.audioOnly => manifest.audioPath != null,
      MediaMaterializationRequirement.videoFrames => videoReady,
      MediaMaterializationRequirement.completeMedia =>
        videoReady &&
            manifest.audioPath != null &&
            manifest.completePath != null &&
            manifest.completeVideoQualityId == manifest.videoQualityId &&
            (targetHeight == null ||
                (manifest.completeVideoHeight ?? 0) >= targetHeight),
    };
  }

  Future<void> _writeManifest(
    Directory directory,
    _MaterializationManifest manifest,
  ) async {
    final file = File(p.join(directory.path, _manifestName));
    final partial = File('${file.path}.partial');
    final backup = File('${file.path}.backup');
    await partial.writeAsString(jsonEncode(manifest.toJson()), flush: true);
    await _deleteBestEffort(backup);
    if (await file.exists()) await file.rename(backup.path);
    try {
      await partial.rename(file.path);
      await _deleteBestEffort(backup);
    } catch (_) {
      if (await backup.exists() && !await file.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    }
    _notifyCacheChanged(p.basename(directory.path));
  }

  Future<void> _markPendingDeletion(Directory directory) async {
    if (!await directory.exists()) await directory.create(recursive: true);
    await File(
      p.join(directory.path, 'materialization.pending_delete'),
    ).writeAsString(DateTime.now().toIso8601String(), flush: true);
  }

  Future<void> _finishIdleCleanup(String itemId) async {
    final root = await _resolveCacheDirectory();
    final directory = Directory(p.join(root.path, _safeName(itemId)));
    if (!await directory.exists()) return;
    final marker = File(
      p.join(directory.path, 'materialization.pending_delete'),
    );
    if (await marker.exists()) {
      final completed = await clearCard(itemId);
      if (completed) await onDeferredClearCompleted?.call(itemId);
      return;
    }
    final manifestFile = File(p.join(directory.path, _manifestName));
    _MaterializationManifest? manifest;
    try {
      if (await manifestFile.exists()) {
        manifest = _MaterializationManifest.fromJson(
          jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>,
        );
      }
    } catch (_) {}
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      final isVersion =
          name.startsWith('materialized_video_') ||
          name.startsWith('materialized_playback_');
      if (isVersion &&
          entity.path != manifest?.videoPath &&
          entity.path != manifest?.completePath) {
        await _deleteBestEffort(entity);
      }
    }
    _notifyCacheChanged(itemId);
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

  void _emit(String itemId, MediaMaterializationProgress progress) {
    _updateTaskProgress(itemId, progress);
    for (final listener
        in _listeners[itemId]?.toList() ??
            const <void Function(MediaMaterializationProgress)>[]) {
      listener(progress);
    }
  }

  void _beginTask(
    VideoItem item,
    MediaMaterializationRequirement requirement,
    int? targetHeight,
  ) {
    final now = DateTime.now();
    _activeTasks[item.id] = MaterializationTaskSnapshot(
      itemId: item.id,
      requirement: requirement,
      targetHeight: targetHeight,
      stage: MediaMaterializationStage.resolving,
      progress: 0,
      message: '正在准备 Bilibili 本地素材',
      startedAt: now,
      updatedAt: now,
    );
    notifyListeners();
  }

  void _updateTaskProgress(
    String itemId,
    MediaMaterializationProgress progress,
  ) {
    final existing = _activeTasks[itemId];
    if (existing == null) return;
    if (existing.stage == progress.stage &&
        existing.progress == progress.progress &&
        existing.message == progress.message &&
        existing.receivedBytes == progress.receivedBytes &&
        existing.totalBytes == progress.totalBytes) {
      return;
    }
    _activeTasks[itemId] = existing.withProgress(progress);
    notifyListeners();
  }

  void _endTask(String itemId) {
    if (_activeTasks.remove(itemId) != null) {
      notifyListeners();
    }
  }

  void _notifyCacheChanged(String itemId) {
    onCacheChanged?.call(itemId);
    notifyListeners();
  }

  void _throwIfCancelled(String itemId) {
    if (_cancelledItems.contains(itemId)) {
      throw StateError('本地素材准备已取消');
    }
  }

  bool _isBilibiliStream(VideoItem item) =>
      item.sourceRef?.kind == MediaSourceKind.bilibiliStream ||
      item.path.startsWith('bilibili://stream/');

  Future<bool> _isNonEmpty(File file) async =>
      await file.exists() && await file.length() > 0;

  Future<void> _deleteBestEffort(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  String _qualityLabel(int? height) =>
      height == null || height <= 0 ? '视频' : '${height}P';

  String _safeName(String input) {
    final safe = input.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return safe.isEmpty || safe == '.' || safe == '..' ? '_' : safe;
  }

  String _lastLine(String value) {
    final lines = value
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    return lines.isEmpty ? '未知错误' : lines.last;
  }
}

class _MaterializationManifest {
  final int version;
  final String bvid;
  final int cid;
  final String? audioPath;
  final String? audioCodec;
  final String? videoPath;
  final int? videoQualityId;
  final int? videoWidth;
  final int? videoHeight;
  final String? videoCodec;
  final String? completePath;
  final int? completeVideoQualityId;
  final int? completeVideoWidth;
  final int? completeVideoHeight;
  final int durationMs;

  const _MaterializationManifest({
    required this.version,
    required this.bvid,
    required this.cid,
    required this.audioPath,
    required this.audioCodec,
    required this.videoPath,
    required this.videoQualityId,
    required this.videoWidth,
    required this.videoHeight,
    required this.videoCodec,
    required this.completePath,
    required this.completeVideoQualityId,
    required this.completeVideoWidth,
    required this.completeVideoHeight,
    required this.durationMs,
  });

  factory _MaterializationManifest.empty(VideoItem item) {
    return _MaterializationManifest(
      version: 1,
      bvid: item.sourceRef?.bvid ?? '',
      cid: item.sourceRef?.cid ?? 0,
      audioPath: null,
      audioCodec: null,
      videoPath: null,
      videoQualityId: null,
      videoWidth: null,
      videoHeight: null,
      videoCodec: null,
      completePath: null,
      completeVideoQualityId: null,
      completeVideoWidth: null,
      completeVideoHeight: null,
      durationMs: item.durationMs,
    );
  }

  _MaterializationManifest copyWith({
    String? audioPath,
    String? audioCodec,
    String? videoPath,
    int? videoQualityId,
    int? videoWidth,
    int? videoHeight,
    String? videoCodec,
    String? completePath,
    int? completeVideoQualityId,
    int? completeVideoWidth,
    int? completeVideoHeight,
    int? durationMs,
    bool clearAudio = false,
    bool clearVideo = false,
    bool clearComplete = false,
  }) {
    return _MaterializationManifest(
      version: version,
      bvid: bvid,
      cid: cid,
      audioPath: clearAudio ? null : audioPath ?? this.audioPath,
      audioCodec: clearAudio ? null : audioCodec ?? this.audioCodec,
      videoPath: clearVideo ? null : videoPath ?? this.videoPath,
      videoQualityId: clearVideo ? null : videoQualityId ?? this.videoQualityId,
      videoWidth: clearVideo ? null : videoWidth ?? this.videoWidth,
      videoHeight: clearVideo ? null : videoHeight ?? this.videoHeight,
      videoCodec: clearVideo ? null : videoCodec ?? this.videoCodec,
      completePath: clearComplete ? null : completePath ?? this.completePath,
      completeVideoQualityId: clearComplete
          ? null
          : completeVideoQualityId ?? this.completeVideoQualityId,
      completeVideoWidth: clearComplete
          ? null
          : completeVideoWidth ?? this.completeVideoWidth,
      completeVideoHeight: clearComplete
          ? null
          : completeVideoHeight ?? this.completeVideoHeight,
      durationMs: durationMs ?? this.durationMs,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': version,
    'bvid': bvid,
    'cid': cid,
    'audioPath': audioPath,
    'audioCodec': audioCodec,
    'videoPath': videoPath,
    'videoQualityId': videoQualityId,
    'videoWidth': videoWidth,
    'videoHeight': videoHeight,
    'videoCodec': videoCodec,
    'completePath': completePath,
    'completeVideoQualityId': completeVideoQualityId,
    'completeVideoWidth': completeVideoWidth,
    'completeVideoHeight': completeVideoHeight,
    'durationMs': durationMs,
  };

  factory _MaterializationManifest.fromJson(Map<String, dynamic> json) {
    return _MaterializationManifest(
      version: json['version'] as int? ?? 1,
      bvid: json['bvid']?.toString() ?? '',
      cid: json['cid'] as int? ?? 0,
      audioPath: json['audioPath'] as String?,
      audioCodec: json['audioCodec'] as String?,
      videoPath: json['videoPath'] as String?,
      videoQualityId: json['videoQualityId'] as int?,
      videoWidth: json['videoWidth'] as int?,
      videoHeight: json['videoHeight'] as int?,
      videoCodec: json['videoCodec'] as String?,
      completePath: json['completePath'] as String?,
      completeVideoQualityId: json['completeVideoQualityId'] as int?,
      completeVideoWidth: json['completeVideoWidth'] as int?,
      completeVideoHeight: json['completeVideoHeight'] as int?,
      durationMs: json['durationMs'] as int? ?? 0,
    );
  }
}
