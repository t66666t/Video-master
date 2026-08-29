import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:lpinyin/lpinyin.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_binary_installer.dart';
import '../models/media_source_ref.dart';
import '../models/video_collection.dart';
import '../utils/media_library_search_query.dart';
import '../models/video_item.dart';
import '../models/managed_subtitle_asset.dart';
import 'thumbnail_cache_service.dart';
import 'audio_playback_compatibility_service.dart';
import 'settings_service.dart';
import 'temporary_storage_cleanup_models.dart';
import '../utils/media_duration_probe.dart';
import '../utils/media_chapter_probe.dart';
import '../utils/serial_task_queue.dart';
import '../utils/subtitle_file_matcher.dart';
import 'subtitle_discovery_service.dart';
import 'task_subtitle_storage_service.dart';
import 'chapter_thumbnail_service.dart';
import 'bilibili/bilibili_streaming_service.dart';
import 'bilibili/bilibili_video_shot_service.dart';

enum StructuredImportSortField { fileName, modifiedTime }

enum StructuredImportSortDirection { ascending, descending }

/// Whether the in-memory media library is durably stored on disk.
///
/// A retry is intentionally represented as a recoverable state instead of an
/// exception: existing callers keep their current behavior while the UI can
/// truthfully tell the user that the latest changes are not durable yet.
enum LibraryPersistenceStatus { healthy, retryScheduled }

class StructuredImportSortOptions {
  final StructuredImportSortField field;
  final StructuredImportSortDirection direction;

  const StructuredImportSortOptions({
    required this.field,
    required this.direction,
  });

  factory StructuredImportSortOptions.fromSettings(SettingsService settings) {
    return StructuredImportSortOptions(
      field: settings.structuredImportSortField == 'modifiedTime'
          ? StructuredImportSortField.modifiedTime
          : StructuredImportSortField.fileName,
      direction: settings.structuredImportSortDirection == 'descending'
          ? StructuredImportSortDirection.descending
          : StructuredImportSortDirection.ascending,
    );
  }

  String get fieldStorageValue {
    return field == StructuredImportSortField.modifiedTime
        ? 'modifiedTime'
        : 'fileName';
  }

  String get directionStorageValue {
    return direction == StructuredImportSortDirection.descending
        ? 'descending'
        : 'ascending';
  }
}

class StructuredImportSelectionSummary {
  final String sourcePath;
  final String sourceName;
  final String rootCollectionName;
  final bool isArchive;
  final int folderCount;
  final int mediaFileCount;
  final bool detailsDeferred;

  const StructuredImportSelectionSummary({
    required this.sourcePath,
    required this.sourceName,
    required this.rootCollectionName,
    required this.isArchive,
    required this.folderCount,
    required this.mediaFileCount,
    this.detailsDeferred = false,
  });
}

class StructuredImportExecutionResult {
  final String rootCollectionId;
  final int createdFolderCount;
  final int importedMediaCount;
  final int restoredMediaCount;

  const StructuredImportExecutionResult({
    required this.rootCollectionId,
    required this.createdFolderCount,
    required this.importedMediaCount,
    required this.restoredMediaCount,
  });

  int get affectedMediaCount => importedMediaCount + restoredMediaCount;
}

class _FileSystemEntrySnapshot {
  final FileSystemEntity entity;
  final String name;
  final bool isDirectory;
  final int modifiedTimeMs;

  const _FileSystemEntrySnapshot({
    required this.entity,
    required this.name,
    required this.isDirectory,
    required this.modifiedTimeMs,
  });
}

class _StructuredImportAccumulator {
  final List<String> newVideoIds = [];
  final List<String> newCollectionIds = [];
  int createdFolderCount = 0;
  int importedMediaCount = 0;
  int restoredMediaCount = 0;
}

class LibraryService extends ChangeNotifier {
  Future<void> _reportDebugEvent(
    String hypothesisId,
    String location,
    String msg, {
    Map<String, Object?>? data,
  }) async {
    if (!kDebugMode) return;
    try {
      final client = HttpClient();
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:7777/event'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'sessionId': 'bilibili-export-crash',
          'runId': 'pre-fix',
          'hypothesisId': hypothesisId,
          'location': location,
          'msg': '[DEBUG] $msg',
          'data': data ?? <String, Object?>{},
          'ts': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      await request.close();
      client.close(force: true);
    } catch (_) {}
  }

  static final LibraryService _instance = LibraryService._internal();
  factory LibraryService() => _instance;
  LibraryService._internal();

  BilibiliStreamingService? _bilibiliStreamingService;

  /// Connects library ownership operations to the live Bilibili gateway.
  ///
  /// The filesystem fallback in [BilibiliStreamingService] keeps recycle-bin
  /// accounting correct during startup/tests, while this live connection also
  /// closes active gateway sessions before a card's cache is deleted.
  void attachBilibiliStreamingService(BilibiliStreamingService? service) {
    if (identical(_bilibiliStreamingService, service)) return;
    _bilibiliStreamingService
      ?..onCacheChanged = null
      ..onVideoShotChanged = null;
    _bilibiliStreamingService = service;
    if (service != null) {
      service.onCacheChanged = notifyOnlineCacheChanged;
      service.onVideoShotChanged = _persistBilibiliVideoShot;
    }
  }

  Future<void> _persistBilibiliVideoShot(VideoItem item) async {
    final stored = _videos[item.id];
    if (stored == null || item.bilibiliVideoShot == null) return;
    stored.bilibiliVideoShot = item.bilibiliVideoShot;
    _invalidateVideoSizeCache(item.id);
    await _saveLibrary();
    notifyListeners();
  }

  static const Set<String> supportedVideoExtensions = {
    '.mp4',
    '.mov',
    '.avi',
    '.mkv',
    '.flv',
    '.webm',
    '.wmv',
    '.3gp',
    '.m4v',
    '.ts',
    '.rmvb',
    '.mpg',
    '.mpeg',
    '.f4v',
    '.m2ts',
    '.mts',
    '.vob',
    '.ogv',
    '.divx',
    '.asf',
    '.mxf',
    '.qt',
    '.y4m',
  };
  static const Set<String> supportedAudioExtensions = {
    '.mp3',
    '.m4a',
    '.wav',
    '.flac',
    '.ogg',
    '.aac',
    '.wma',
    '.opus',
    '.m4b',
    '.aiff',
    '.aif',
    '.aifc',
    '.ape',
    '.alac',
    '.caf',
    '.amr',
    '.ac3',
    '.eac3',
    '.dts',
    '.mka',
    '.mp2',
    '.oga',
    '.ra',
    '.tta',
    '.wv',
    '.dsf',
    '.dff',
    '.au',
    '.snd',
  };
  static const Set<String> supportedMediaExtensions = {
    ...supportedVideoExtensions,
    ...supportedAudioExtensions,
  };
  static const List<String> _supportedArchiveSuffixes = [
    '.zip',
    '.tar',
    '.tgz',
    '.tar.gz',
    '.tbz',
    '.tbz2',
    '.tar.bz2',
    '.txz',
    '.tar.xz',
  ];
  static const String _archiveImportMarkerName = '.import_in_progress.json';
  static const String _importedArchivesDirName = 'imported_archives';
  static const String _pickedArchivesCacheDirName = 'picked_archives';

  // Unified storage: ID -> Object
  Map<String, VideoCollection> _collections = {};
  Map<String, VideoItem> _videos = {};
  final Map<String, Future<String?>> _thumbnailRepairInFlight = {};

  // Root level structure (IDs of collections and videos at root)
  List<String> _rootChildrenIds = [];
  final Map<String, int> _itemSizeCache = {};
  final Map<String, Future<int>> _itemSizeInFlight = {};
  final List<Completer<void>> _sizeCalculationWaitQueue = [];
  int _activeSizeCalculationCount = 0;

  // Legacy getters (backward compatibility) - DO NOT USE FOR NEW LOGIC if possible
  List<VideoCollection> get collections =>
      _collections.values
          .where((c) => c.parentId == null && !c.isRecycled)
          .toList()
        ..sort((a, b) => b.createTime.compareTo(a.createTime)); // Default sort

  // New: Get Recycle Bin Items (Mixed)
  List<dynamic> getRecycleBinContents() {
    final recycledCols = _collections.values
        .where((c) => c.isRecycled)
        .toList();
    final recycledVideos = _videos.values.where((v) => v.isRecycled).toList();

    // Logic: Only show items whose parent is NOT recycled (or has no parent).
    // If a parent is recycled, its children are implicitly recycled and hidden from top-level bin view.
    // However, if we support independent recycling, we need to check parent status.

    // Helper to check if any ancestor is recycled
    bool isAncestorRecycled(String? parentId) {
      if (parentId == null) return false;
      final parentCol = _collections[parentId];
      if (parentCol == null) return false; // Parent missing, treat as root-ish
      if (parentCol.isRecycled) return true;
      return isAncestorRecycled(parentCol.parentId);
    }

    final visibleCols = recycledCols
        .where((c) => !isAncestorRecycled(c.parentId))
        .toList();
    final visibleVideos = recycledVideos
        .where((v) => !isAncestorRecycled(v.parentId))
        .toList();

    return [...visibleCols, ...visibleVideos]..sort((a, b) {
      // Sort by recycle time if available, else updated time
      final timeA =
          (a is VideoCollection
              ? a.recycleTime
              : (a as VideoItem).recycleTime) ??
          0;
      final timeB =
          (b is VideoCollection
              ? b.recycleTime
              : (b as VideoItem).recycleTime) ??
          0;
      return timeB.compareTo(timeA);
    });
  }

  VideoItem? getVideo(String id) => _videos[id];
  VideoCollection? getCollection(String id) => _collections[id];

  /// 获取指定文件夹中的所有视频（不包括回收站中的），并按照正确的顺序排列
  List<VideoItem> getVideosInFolder(String? folderId) {
    List<String> sourceIds;
    if (folderId == null) {
      sourceIds = _rootChildrenIds;
    } else {
      final collection = _collections[folderId];
      if (collection == null) return [];
      sourceIds = collection.childrenIds;
    }

    final List<VideoItem> result = [];
    for (var id in sourceIds) {
      final video = _videos[id];
      if (video != null && !video.isRecycled) {
        result.add(video);
      }
    }
    return result;
  }

  // Helper function to detect media type from file extension
  MediaType _detectMediaType(String path) {
    final ext = p.extension(path).toLowerCase();
    if (supportedAudioExtensions.contains(ext)) {
      return MediaType.audio;
    }
    return MediaType.video;
  }

  String _normalizeImportedName(String value) {
    var name = p.basename(value).trim();
    name = name.replaceFirst(RegExp(r'^incoming_media_\d+_'), '');
    name = name.replaceFirst(RegExp(r'^shared_media_\d+_'), '');
    name = name.replaceFirst(
      RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}_',
      ),
      '',
    );
    return name.isEmpty ? p.basename(value) : name;
  }

  static bool isSupportedMediaPath(String path) {
    return supportedMediaExtensions.contains(p.extension(path).toLowerCase());
  }

  static bool isSupportedArchivePath(String path) {
    final lowerPath = path.toLowerCase();
    for (final suffix in _supportedArchiveSuffixes) {
      if (lowerPath.endsWith(suffix)) {
        return true;
      }
    }
    return false;
  }

  @visibleForTesting
  static Map<String, int> extractArchiveForTesting({
    required String archivePath,
    required String outputPath,
    int? maxEntryCount,
    int? maxTotalBytes,
    int? maxSingleFileBytes,
    int? maxPathDepth,
    int? maxCompressionRatio,
  }) {
    return _extractArchiveToDiskWithParentsSync(
      archivePath: archivePath,
      outputPath: outputPath,
      maxEntryCount: maxEntryCount,
      maxTotalBytes: maxTotalBytes,
      maxSingleFileBytes: maxSingleFileBytes,
      maxPathDepth: maxPathDepth,
      maxCompressionRatio: maxCompressionRatio,
    );
  }

  static String archiveDisplayName(String archivePath) {
    return p.basename(archivePath);
  }

  static String archiveRootCollectionName(String archivePath) {
    final name = p.basename(archivePath);
    final lowerName = name.toLowerCase();
    for (final suffix in _supportedArchiveSuffixes) {
      if (lowerName.endsWith(suffix)) {
        final trimmed = name.substring(0, name.length - suffix.length).trim();
        if (trimmed.isNotEmpty) {
          return trimmed;
        }
      }
    }
    final fallback = p.basenameWithoutExtension(name).trim();
    return fallback.isEmpty ? name : fallback;
  }

  Future<String?> _computeSourceFingerprint(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        return null;
      }
      final length = await file.length();
      final raf = await file.open(mode: FileMode.read);
      try {
        const chunkSize = 64 * 1024;
        final builder = BytesBuilder(copy: false);
        builder.add(utf8.encode('$length|'));
        final headSize = min(chunkSize, length);
        if (headSize > 0) {
          builder.add(await raf.read(headSize));
        }
        if (length > chunkSize) {
          await raf.setPosition(max(0, length - chunkSize));
          builder.add(await raf.read(min(chunkSize, length)));
        }
        final digest = sha256.convert(builder.takeBytes()).toString();
        return 'v1:$length:$digest';
      } finally {
        await raf.close();
      }
    } catch (e) {
      developer.log('Compute fingerprint failed: $path', error: e);
      return null;
    }
  }

  Future<String?> _findExistingVideoIdByPathOrFingerprint(
    String path, {
    String? sourceFingerprint,
    String? originalTitle,
    bool requireInternalMatchForFingerprint = false,
  }) async {
    final normalizedPath = p.normalize(path);
    final normalizedName = _normalizeImportedName(
      originalTitle ?? path,
    ).toLowerCase();
    int? candidateSize;
    try {
      candidateSize = await File(path).length();
    } catch (_) {}

    bool fingerprintBackfilled = false;

    for (final entry in _videos.entries) {
      final existing = entry.value;
      if (_samePath(existing.path, normalizedPath)) {
        return entry.key;
      }
      if (sourceFingerprint != null &&
          existing.sourceFingerprint != null &&
          (!requireInternalMatchForFingerprint ||
              _isInternalPath(existing.path)) &&
          existing.sourceFingerprint == sourceFingerprint) {
        return entry.key;
      }
      if (sourceFingerprint == null || existing.sourceFingerprint != null) {
        continue;
      }

      final existingName = _normalizeImportedName(existing.title).toLowerCase();
      if (existingName != normalizedName) {
        continue;
      }
      if (requireInternalMatchForFingerprint &&
          !_isInternalPath(existing.path)) {
        continue;
      }

      int? existingSize;
      try {
        existingSize = await File(existing.path).length();
      } catch (_) {}
      if (candidateSize == null ||
          existingSize == null ||
          candidateSize != existingSize) {
        continue;
      }

      final existingFingerprint = await _computeSourceFingerprint(
        existing.path,
      );
      if (existingFingerprint == null) {
        continue;
      }
      existing.sourceFingerprint = existingFingerprint;
      fingerprintBackfilled = true;
      if (existingFingerprint == sourceFingerprint) {
        if (fingerprintBackfilled) {
          await _saveLibrary();
        }
        return entry.key;
      }
    }

    if (fingerprintBackfilled) {
      await _saveLibrary();
    }
    return null;
  }

  Future<bool> _restoreExistingVideoToTarget(
    String existingId,
    String? parentId, {
    bool persist = true,
    bool notify = true,
  }) async {
    final existingVideo = _videos[existingId];
    if (existingVideo == null) {
      return false;
    }

    final wasRecycled = existingVideo.isRecycled;
    if (wasRecycled) {
      existingVideo.isRecycled = false;
      existingVideo.recycleTime = null;
    }

    if (existingVideo.parentId != null &&
        _collections.containsKey(existingVideo.parentId)) {
      _collections[existingVideo.parentId]!.childrenIds.remove(existingId);
    } else if (existingVideo.parentId == null) {
      _rootChildrenIds.remove(existingId);
    }

    existingVideo.parentId = parentId;
    if (parentId != null && _collections.containsKey(parentId)) {
      if (!_collections[parentId]!.childrenIds.contains(existingId)) {
        _collections[parentId]!.childrenIds.add(existingId);
      }
    } else {
      if (!_rootChildrenIds.contains(existingId)) {
        _rootChildrenIds.add(existingId);
      }
    }

    if (persist && wasRecycled) {
      await _saveLibrary();
    }
    if (notify) {
      notifyListeners();
    }
    return true;
  }

  // Import Progress
  final ValueNotifier<bool> isImporting = ValueNotifier(false);
  final ValueNotifier<double> importProgress = ValueNotifier(0.0);
  final ValueNotifier<String> importStatus = ValueNotifier("");
  bool _importOperationActive = false;
  bool get hasActiveImport => _importOperationActive;

  bool _initialized = false;
  late Directory _dataRootDir;
  bool _isDurationBackfillRunning = false;
  bool _hasScheduledDurationBackfill = false;
  bool _isChapterBackfillRunning = false;
  bool _hasScheduledChapterBackfill = false;

  /// 当前 library.json 的 schema 版本。
  /// 版本 0 = 旧版（无 schemaVersion 字段），需要执行比例迁移。
  /// 版本 1 = 已执行竖屏比例 1:1 修复迁移。
  /// 版本 2 = 应用管理的字幕按 VideoItem.id 隔离到任务目录。
  static const int _currentLibrarySchemaVersion = 2;
  bool _needsPostLoadSave = false;

  static const List<Duration> _saveRetryDelays = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 10),
    Duration(seconds: 30),
    Duration(minutes: 2),
    Duration(minutes: 5),
  ];
  LibraryPersistenceStatus _persistenceStatus =
      LibraryPersistenceStatus.healthy;
  Object? _lastPersistenceError;
  DateTime? _lastPersistenceFailureAt;
  int _consecutivePersistenceFailures = 0;
  int _persistenceFailureEpisode = 0;
  Timer? _saveRetryTimer;

  @visibleForTesting
  Future<void> Function()? writeLibrarySnapshotOverrideForTesting;
  @visibleForTesting
  List<Duration>? saveRetryDelaysForTesting;

  LibraryPersistenceStatus get persistenceStatus => _persistenceStatus;
  bool get hasPersistenceFailure =>
      _persistenceStatus != LibraryPersistenceStatus.healthy;
  Object? get lastPersistenceError => _lastPersistenceError;
  DateTime? get lastPersistenceFailureAt => _lastPersistenceFailureAt;
  int get consecutivePersistenceFailures => _consecutivePersistenceFailures;

  /// Increases only when a new failure period begins. The UI uses this to
  /// present at most one dismissible notice per period, even if retries fail.
  int get persistenceFailureEpisode => _persistenceFailureEpisode;

  // Initialize and load data
  Future<void> init() async {
    if (_initialized) return;
    final appDocDir = await getApplicationDocumentsDirectory();
    Directory targetDir = appDocDir;
    if (Platform.isWindows) {
      final settings = SettingsService();
      targetDir = await settings.resolveLargeDataRootDir();
    }

    if (Platform.isWindows &&
        p.normalize(targetDir.path) != p.normalize(appDocDir.path)) {
      final targetFile = File(p.join(targetDir.path, 'library.json'));
      final appFile = File(p.join(appDocDir.path, 'library.json'));
      if (!await targetFile.exists() && await appFile.exists()) {
        _dataRootDir = appDocDir;
        await _loadLibrary();
        await _migrateLargeDataRoot(targetDir, updateSettings: true);
      } else {
        _dataRootDir = targetDir;
        await _loadLibrary();
      }
    } else {
      _dataRootDir = targetDir;
      await _loadLibrary();
    }
    await _cleanupIncompleteArchiveImports();
    unawaited(_cleanupOrphanedArchiveSelectionCaches());

    // 如果数据迁移修改了数据，立即保存
    if (_needsPostLoadSave) {
      _needsPostLoadSave = false;
      await _saveLibrary();
    }

    _initialized = true;
    notifyListeners();
    _scheduleDurationBackfill();
    _scheduleChapterBackfill();
  }

  Future<void> clearThumbnailDiskCache() async {
    if (!_initialized) return;
    try {
      final thumbnailDir = Directory(p.join(_dataRootDir.path, 'thumbnails'));
      if (await thumbnailDir.exists()) {
        await thumbnailDir.delete(recursive: true);
      }
    } catch (e) {
      debugPrint('清理缩略图磁盘缓存失败: $e');
    }
  }

  Future<String?> ensureThumbnailForVideo(String videoId) async {
    final item = _videos[videoId];
    if (item == null || item.type != MediaType.video) {
      return null;
    }

    final inFlight = _thumbnailRepairInFlight[videoId];
    if (inFlight != null) {
      return inFlight;
    }

    final future = _ensureThumbnailForVideoInternal(item);
    _thumbnailRepairInFlight[videoId] = future;
    try {
      return await future;
    } finally {
      if (identical(_thumbnailRepairInFlight[videoId], future)) {
        _thumbnailRepairInFlight.remove(videoId);
      }
    }
  }

  Future<String?> _ensureThumbnailForVideoInternal(VideoItem item) async {
    final existingPath = item.thumbnailPath;
    if (existingPath != null && existingPath.isNotEmpty) {
      final existingFile = File(existingPath);
      final requiresRepair = _requiresWindowsThumbnailRepair(existingPath);
      if (await existingFile.exists() &&
          await existingFile.length() > 0 &&
          !requiresRepair) {
        return existingPath;
      }
    }

    final generatedPath = await _generateThumbnail(item.path, videoId: item.id);
    if (generatedPath == null || generatedPath.isEmpty) {
      return null;
    }

    if (item.thumbnailPath != generatedPath) {
      if (_requiresWindowsThumbnailRepair(item.thumbnailPath)) {
        try {
          final previousFile = File(item.thumbnailPath!);
          if (await previousFile.exists()) {
            await previousFile.delete();
          }
        } catch (_) {}
      }
      item.thumbnailPath = generatedPath;
      item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
      await _saveLibrary();
      notifyListeners();
    }

    return generatedPath;
  }

  /// Ensures an imported audio item has a persistent, portable playback file.
  /// The original path is retained for source identity and user-facing details.
  Future<String> ensureCompatiblePlaybackFile(VideoItem item) async {
    return _prepareCompatiblePlaybackFile(item, saveLibrary: true);
  }

  Future<String> _prepareCompatiblePlaybackFile(
    VideoItem item, {
    required bool saveLibrary,
  }) async {
    if (item.type != MediaType.audio) return item.path;
    final playbackFile = await AudioPlaybackCompatibilityService.resolve(
      File(item.path),
      isAudio: true,
      existingPlaybackPath: item.playbackPath,
      persistentDirectory: Directory(
        p.join(_dataRootDir.path, 'compatible_audio'),
      ),
    );
    final resolvedPath = playbackFile.path;
    final newPlaybackPath = _samePath(resolvedPath, item.path)
        ? null
        : resolvedPath;
    if (item.playbackPath != newPlaybackPath) {
      item.playbackPath = newPlaybackPath;
      item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
      if (saveLibrary) {
        await _saveLibrary();
        notifyListeners();
      }
    }
    return resolvedPath;
  }

  void _scheduleDurationBackfill() {
    if (_hasScheduledDurationBackfill) return;
    _hasScheduledDurationBackfill = true;
    Future<void>(() async {
      await _backfillMissingDurations();
    });
  }

  Future<void> _backfillMissingDurations() async {
    if (_isDurationBackfillRunning) return;
    _isDurationBackfillRunning = true;
    try {
      final pendingItems = _videos.values
          .where((item) => item.durationMs <= 0)
          .toList();
      if (pendingItems.isEmpty) {
        return;
      }

      bool changed = false;
      int notifyCounter = 0;
      for (final item in pendingItems) {
        final durationMs = await _probeMediaDurationMs(item.path);
        if (durationMs <= 0 || item.durationMs == durationMs) {
          continue;
        }
        item.durationMs = durationMs;
        item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
        changed = true;
        notifyCounter++;
        if (notifyCounter >= 10) {
          notifyCounter = 0;
          notifyListeners();
        }
      }

      if (changed) {
        await _saveLibrary();
        notifyListeners();
      }
    } finally {
      _isDurationBackfillRunning = false;
    }
  }

  void _scheduleChapterBackfill() {
    if (_hasScheduledChapterBackfill) return;
    _hasScheduledChapterBackfill = true;
    Future<void>(() async {
      // Give startup rendering priority and avoid running a second ffprobe in
      // parallel with the legacy duration migration.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      while (_isDurationBackfillRunning) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await _backfillUnprobedChapters();
    });
  }

  Future<void> _backfillUnprobedChapters() async {
    if (_isChapterBackfillRunning) return;
    _isChapterBackfillRunning = true;
    try {
      final pendingItems = _videos.values
          .where((item) => !item.hasProbedChapters)
          .toList();
      if (pendingItems.isEmpty) return;

      var changed = false;
      var notifyCounter = 0;
      for (final item in pendingItems) {
        if (!await File(item.path).exists()) continue;
        item.chapters = await MediaChapterProbe.probe(
          item.path,
          durationMs: item.durationMs,
        );
        item.hasProbedChapters = true;
        item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
        changed = true;
        notifyCounter++;
        if (notifyCounter >= 4) {
          notifyCounter = 0;
          await _saveLibrary();
          notifyListeners();
        }
        // Chapter migration is deliberately progressive so a large library
        // cannot monopolize ffprobe or the UI isolate at startup.
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      if (changed) {
        await _saveLibrary();
        notifyListeners();
      }
    } finally {
      _isChapterBackfillRunning = false;
    }
  }

  Future<bool> migrateLargeDataRoot(String newPath) async {
    if (!Platform.isWindows) return false;
    final targetDir = Directory(newPath);
    return _migrateLargeDataRoot(targetDir, updateSettings: true);
  }

  Future<bool> _migrateLargeDataRoot(
    Directory targetDir, {
    bool updateSettings = false,
  }) async {
    final oldRoot = _dataRootDir;
    if (p.normalize(oldRoot.path) == p.normalize(targetDir.path)) return true;

    try {
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }
    } catch (_) {
      return false;
    }

    await _moveDirectoryIfExists(
      Directory(p.join(oldRoot.path, 'imported_videos')),
      Directory(p.join(targetDir.path, 'imported_videos')),
    );
    await _moveDirectoryIfExists(
      Directory(p.join(oldRoot.path, 'thumbnails')),
      Directory(p.join(targetDir.path, 'thumbnails')),
    );
    await _moveDirectoryIfExists(
      Directory(p.join(oldRoot.path, 'subtitles')),
      Directory(p.join(targetDir.path, 'subtitles')),
    );
    await _moveDirectoryIfExists(
      Directory(p.join(oldRoot.path, BilibiliVideoShotService.directoryName)),
      Directory(p.join(targetDir.path, BilibiliVideoShotService.directoryName)),
    );

    await _moveFileIfExists(
      File(p.join(oldRoot.path, 'library.json')),
      File(p.join(targetDir.path, 'library.json')),
    );
    await _moveFileIfExists(
      File(p.join(oldRoot.path, 'library.json.bak')),
      File(p.join(targetDir.path, 'library.json.bak')),
    );
    await _moveFileIfExists(
      File(p.join(oldRoot.path, 'library.json.tmp')),
      File(p.join(targetDir.path, 'library.json.tmp')),
    );

    _updatePathsAfterRootChange(oldRoot.path, targetDir.path);
    _dataRootDir = targetDir;
    await _saveLibrary();

    if (updateSettings) {
      final settings = SettingsService();
      await settings.setLargeDataRootPath(targetDir.path);
    }

    return true;
  }

  void _updatePathsAfterRootChange(String oldRoot, String newRoot) {
    for (final col in _collections.values) {
      if (col.thumbnailPath != null) {
        col.thumbnailPath = _replaceRootPath(
          col.thumbnailPath!,
          oldRoot,
          newRoot,
        );
      }
    }

    for (final vid in _videos.values) {
      vid.path = _replaceRootPath(vid.path, oldRoot, newRoot);
      if (vid.playbackPath != null) {
        vid.playbackPath = _replaceRootPath(
          vid.playbackPath!,
          oldRoot,
          newRoot,
        );
      }
      if (vid.thumbnailPath != null) {
        vid.thumbnailPath = _replaceRootPath(
          vid.thumbnailPath!,
          oldRoot,
          newRoot,
        );
      }
      if (vid.subtitlePath != null) {
        vid.subtitlePath = _replaceRootPath(
          vid.subtitlePath!,
          oldRoot,
          newRoot,
        );
      }
      if (vid.secondarySubtitlePath != null) {
        vid.secondarySubtitlePath = _replaceRootPath(
          vid.secondarySubtitlePath!,
          oldRoot,
          newRoot,
        );
      }
      if (vid.danmakuPath != null) {
        vid.danmakuPath = _replaceRootPath(vid.danmakuPath!, oldRoot, newRoot);
      }
      if (vid.bilibiliVideoShot != null) {
        vid.bilibiliVideoShot = vid.bilibiliVideoShot!.replaceRoot(
          oldRoot,
          newRoot,
        );
      }
      if (vid.additionalSubtitles != null) {
        vid.additionalSubtitles = vid.additionalSubtitles!.map(
          (key, value) =>
              MapEntry(key, _replaceRootPath(value, oldRoot, newRoot)),
        );
      }
      if (vid.localSubtitles != null) {
        vid.localSubtitles = vid.localSubtitles!.map(
          (key, value) =>
              MapEntry(key, _replaceRootPath(value, oldRoot, newRoot)),
        );
      }
      vid.managedSubtitleAssets = vid.managedSubtitleAssets
          .map(
            (asset) => asset.copyWith(
              path: _replaceRootPath(asset.path, oldRoot, newRoot),
            ),
          )
          .toList(growable: false);
      if (vid.recycledSelectedSubtitlePaths != null) {
        vid.recycledSelectedSubtitlePaths = vid.recycledSelectedSubtitlePaths!
            .map((e) => _replaceRootPath(e, oldRoot, newRoot))
            .toList();
      }
      if (vid.recycledAdditionalSubtitles != null) {
        vid.recycledAdditionalSubtitles = vid.recycledAdditionalSubtitles!.map(
          (key, value) =>
              MapEntry(key, _replaceRootPath(value, oldRoot, newRoot)),
        );
      }
      if (vid.recycledLocalSubtitles != null) {
        vid.recycledLocalSubtitles = vid.recycledLocalSubtitles!.map(
          (key, value) =>
              MapEntry(key, _replaceRootPath(value, oldRoot, newRoot)),
        );
      }
    }
  }

  String _replaceRootPath(String path, String oldRoot, String newRoot) {
    final normOld = p.normalize(oldRoot);
    final normPath = p.normalize(path);
    if (p.equals(normOld, normPath) || p.isWithin(normOld, normPath)) {
      final rel = p.relative(normPath, from: normOld);
      return p.join(newRoot, rel);
    }
    return path;
  }

  Future<void> _moveFileIfExists(File src, File dest) async {
    if (!await src.exists()) return;
    if (!await dest.parent.exists()) {
      await dest.parent.create(recursive: true);
    }
    try {
      await src.rename(dest.path);
    } catch (_) {
      await src.copy(dest.path);
      try {
        await src.delete();
      } catch (_) {}
    }
  }

  Future<void> _moveDirectoryIfExists(Directory src, Directory dest) async {
    if (!await src.exists()) return;
    if (!await dest.parent.exists()) {
      await dest.parent.create(recursive: true);
    }
    if (!await dest.exists()) {
      try {
        await src.rename(dest.path);
        return;
      } catch (_) {}
    }
    await _copyDirectoryContents(src, dest);
    try {
      await src.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> _copyDirectoryContents(Directory src, Directory dest) async {
    if (!await dest.exists()) {
      await dest.create(recursive: true);
    }
    await for (final entity in src.list(followLinks: false)) {
      final name = p.basename(entity.path);
      final targetPath = p.join(dest.path, name);
      if (entity is File) {
        await entity.copy(targetPath);
      } else if (entity is Directory) {
        await _copyDirectoryContents(entity, Directory(targetPath));
      }
    }
  }

  Future<void> _loadLibrary() async {
    final file = File(p.join(_dataRootDir.path, 'library.json'));
    final backupFile = File(p.join(_dataRootDir.path, 'library.json.bak'));

    if (!await file.exists()) {
      // Try backup if main file missing
      if (await backupFile.exists()) {
        try {
          await _parseLibraryData(await backupFile.readAsString());
          // Restore main file from backup
          await backupFile.copy(file.path);
        } catch (e) {
          developer.log('Error loading backup library', error: e);
        }
      }
      return;
    }

    try {
      final jsonString = await file.readAsString();
      if (jsonString.isEmpty) throw const FormatException("Empty JSON file");
      await _parseLibraryData(jsonString);
    } catch (e) {
      developer.log('Error loading library', error: e);
      // Try backup
      if (await backupFile.exists()) {
        developer.log('Attempting to load from backup...');
        try {
          await _parseLibraryData(await backupFile.readAsString());
          // We don't overwrite the corrupt main file immediately to allow manual inspection if needed,
          // but the next save will overwrite it.
        } catch (e2) {
          developer.log('Error loading backup library', error: e2);
        }
      }
    }
  }

  Future<void> _parseLibraryData(String jsonString) async {
    final data = json.decode(jsonString);

    // Load Collections
    if (data['collections'] != null) {
      final list = (data['collections'] as List)
          .map((e) => VideoCollection.fromJson(e))
          .toList();
      _collections = {for (var c in list) c.id: c};
    }

    // Load Videos
    if (data['videos'] != null) {
      final list = (data['videos'] as List)
          .map((e) => VideoItem.fromJson(e))
          .toList();
      _videos = {for (var v in list) v.id: v};
    }

    // Load Root Children IDs
    if (data['rootChildrenIds'] != null) {
      _rootChildrenIds = (data['rootChildrenIds'] as List)
          .map((e) => e.toString())
          .toList();
    } else {
      // Migration: Populate rootChildrenIds if missing
      final rootCols = _collections.values
          .where((c) => c.parentId == null)
          .map((c) => c.id);
      final rootVids = _videos.values
          .where((v) => v.parentId == null)
          .map((v) => v.id);
      _rootChildrenIds = [...rootCols, ...rootVids];

      // Sort by createTime/lastUpdated as a default
      _rootChildrenIds.sort((a, b) {
        int timeA = _collections.containsKey(a)
            ? _collections[a]!.createTime
            : (_videos[a]?.lastUpdated ?? 0);
        int timeB = _collections.containsKey(b)
            ? _collections[b]!.createTime
            : (_videos[b]?.lastUpdated ?? 0);
        return timeB.compareTo(timeA);
      });
    }

    // Default Folder Creation: If library is completely empty
    if (_collections.isEmpty && _videos.isEmpty) {
      await createCollection("默认收藏夹", null);
    }

    // Migration: Handle Legacy Recycle Bin
    if (data['recycleBin'] != null) {
      final binList = (data['recycleBin'] as List)
          .map((e) => VideoCollection.fromJson(e))
          .toList();
      for (var c in binList) {
        c.isRecycled = true;
        c.recycleTime = DateTime.now().millisecondsSinceEpoch;
        _collections[c.id] = c;
      }
    }

    // Migration: Fix parentId for children
    for (var col in _collections.values) {
      for (var childId in col.childrenIds) {
        if (_collections.containsKey(childId)) {
          _collections[childId]!.parentId = col.id;
        } else if (_videos.containsKey(childId)) {
          _videos[childId]!.parentId = col.id;
        }
      }
    }

    // Schema migration
    final int savedSchemaVersion = data['schemaVersion'] as int? ?? 0;
    if (savedSchemaVersion < _currentLibrarySchemaVersion) {
      await _migratePortraitAspectRatioIfNeeded(savedSchemaVersion);
      await _migrateTaskSubtitleAssetsIfNeeded(savedSchemaVersion);
    }
  }

  /// 数据迁移：修复旧版代码为竖屏视频错误设置的 1:1 比例。
  ///
  /// 旧版 `_applyInitialPortraitDefaultAspectRatioIfNeeded` 对竖屏视频设置了
  /// portraitDisplayAspectRatio = 1.0，并标记 hasPortraitAspectPreferenceInitialized = true。
  /// 当前版本已改为设置 4/3，但旧数据中的 1.0 值因 initialized 标志无法被纠正。
  ///
  /// 此迁移将受影响视频的比例重置为 null、initialized 标志重置为 false，
  /// 使下次打开视频时由当前代码重新评估。
  Future<void> _migratePortraitAspectRatioIfNeeded(int savedVersion) async {
    if (savedVersion >= 1) return;

    bool changed = false;
    for (final item in _videos.values) {
      if (item.type != MediaType.video) continue;

      final ratio = item.portraitDisplayAspectRatio;
      if (ratio == null) continue;
      if ((ratio - 1.0).abs() >= 0.01) continue;
      // 跳过用户通过自定义宽高设置的 1:1（保留用户意图）
      if (item.portraitCustomAspectWidth != null ||
          item.portraitCustomAspectHeight != null) {
        continue;
      }

      item.portraitDisplayAspectRatio = null;
      item.hasPortraitAspectPreferenceInitialized = false;
      changed = true;
    }

    if (changed) {
      _needsPostLoadSave = true;
    }
  }

  // Debounce non-critical saves, while serializing every actual disk write.
  // Each caller receives the Future for its own queued write, so awaiting a
  // save never returns merely because another save is already in progress.
  bool _hasPendingSave = false;
  Timer? _saveDebounceTimer;
  final SerialTaskQueue _saveQueue = SerialTaskQueue();
  final SerialTaskQueue _postImportQueue = SerialTaskQueue();
  static const Duration _saveDebounceDelay = Duration(seconds: 20);

  /// Schedule a debounced save for non-critical updates (e.g. progress).
  /// Multiple calls within the debounce window are coalesced into one save.
  void _scheduleDebouncedSave() {
    _hasPendingSave = true;
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(_saveDebounceDelay, () {
      _saveDebounceTimer = null;
      if (_hasPendingSave) {
        unawaited(
          _saveLibrary().catchError((Object error, StackTrace stackTrace) {
            developer.log(
              'Error saving debounced library update',
              error: error,
              stackTrace: stackTrace,
            );
          }),
        );
      }
    });
  }

  Future<void> _saveLibrary() {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = null;
    _hasPendingSave = false;
    _saveRetryTimer?.cancel();
    _saveRetryTimer = null;

    return _saveQueue.enqueue(_writeLibrarySnapshot);
  }

  /// Lets the user request an immediate retry without exposing storage errors
  /// to every existing library mutation call site.
  Future<void> retryLibraryPersistence() {
    if (!hasPersistenceFailure) return Future<void>.value();
    return _saveLibrary();
  }

  @visibleForTesting
  Future<void> saveLibraryForTesting() => _saveLibrary();

  @visibleForTesting
  void resetPersistenceForTesting() {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = null;
    _saveRetryTimer?.cancel();
    _saveRetryTimer = null;
    _hasPendingSave = false;
    _persistenceStatus = LibraryPersistenceStatus.healthy;
    _lastPersistenceError = null;
    _lastPersistenceFailureAt = null;
    _consecutivePersistenceFailures = 0;
    _persistenceFailureEpisode = 0;
    writeLibrarySnapshotOverrideForTesting = null;
    saveRetryDelaysForTesting = null;
  }

  Future<void> _writeLibrarySnapshot() async {
    try {
      final override = writeLibrarySnapshotOverrideForTesting;
      if (override != null) {
        await override();
      } else {
        await _performLibrarySnapshotWrite();
      }
      _recordPersistenceSuccess();
    } catch (error, stackTrace) {
      developer.log(
        'Error saving library',
        error: error,
        stackTrace: stackTrace,
      );
      _recordPersistenceFailure(error);
    }
  }

  Future<void> _performLibrarySnapshotWrite() async {
    final file = File(p.join(_dataRootDir.path, 'library.json'));
    final tempFile = File(p.join(_dataRootDir.path, 'library.json.tmp'));
    final backupFile = File(p.join(_dataRootDir.path, 'library.json.bak'));

    final data = {
      'collections': _collections.values.map((e) => e.toJson()).toList(),
      'videos': _videos.values.map((e) => e.toJson()).toList(),
      'rootChildrenIds': _rootChildrenIds,
      'schemaVersion': _currentLibrarySchemaVersion,
    };

    // 1. Write to temp file.
    await tempFile.writeAsString(json.encode(data), flush: true);

    // 2. Create a backup of the current valid file.
    if (await file.exists()) {
      await file.copy(backupFile.path);
    }

    // 3. Replace the main file. Windows rename-overwrite is unreliable, so
    // use delete+rename first and fall back to copy if needed.
    try {
      if (await file.exists()) {
        await file.delete();
      }
      await tempFile.rename(file.path);
    } catch (_) {
      await tempFile.copy(file.path);
      await tempFile.delete();
    }
  }

  void _recordPersistenceFailure(Object error) {
    final startsNewEpisode = !hasPersistenceFailure;
    _persistenceStatus = LibraryPersistenceStatus.retryScheduled;
    _lastPersistenceError = error;
    _lastPersistenceFailureAt = DateTime.now();
    _consecutivePersistenceFailures++;
    if (startsNewEpisode) {
      _persistenceFailureEpisode++;
    }
    _schedulePersistenceRetry();
    notifyListeners();
  }

  void _recordPersistenceSuccess() {
    if (!hasPersistenceFailure) return;
    _saveRetryTimer?.cancel();
    _saveRetryTimer = null;
    _persistenceStatus = LibraryPersistenceStatus.healthy;
    _lastPersistenceError = null;
    _lastPersistenceFailureAt = null;
    _consecutivePersistenceFailures = 0;
    notifyListeners();
  }

  void _schedulePersistenceRetry() {
    _saveRetryTimer?.cancel();
    final delays = saveRetryDelaysForTesting ?? _saveRetryDelays;
    if (delays.isEmpty) return;
    final delayIndex = min(
      _consecutivePersistenceFailures - 1,
      delays.length - 1,
    );
    _saveRetryTimer = Timer(delays[delayIndex], () {
      _saveRetryTimer = null;
      unawaited(_saveLibrary());
    });
  }

  // Get contents for a specific folder (null for root)
  List<dynamic> getContents(String? parentId) {
    List<dynamic> results = [];

    List<String> sourceIds;
    if (parentId == null) {
      sourceIds = _rootChildrenIds;
    } else {
      final parent = _collections[parentId];
      if (parent == null) return [];
      sourceIds = parent.childrenIds;
    }

    for (var id in sourceIds) {
      if (_collections.containsKey(id)) {
        final col = _collections[id]!;
        if (!col.isRecycled) results.add(col);
      } else if (_videos.containsKey(id)) {
        final vid = _videos[id]!;
        if (!vid.isRecycled) results.add(vid);
      }
    }

    return results;
  }

  /// Returns a virtual, read-only view of every active folder and media item
  /// whose display text matches [query]. The returned objects are the original
  /// library objects, so actions performed from a search result still mutate
  /// the real item instead of a copy.
  List<dynamic> searchContents(String query) {
    final searchQuery = MediaLibrarySearchQuery(query);
    if (searchQuery.isEmpty) return const <dynamic>[];

    bool hasRecycledAncestor(String? parentId) {
      final visited = <String>{};
      var currentId = parentId;
      while (currentId != null && visited.add(currentId)) {
        final parent = _collections[currentId];
        if (parent == null) return false;
        if (parent.isRecycled) return true;
        currentId = parent.parentId;
      }
      return false;
    }

    String displayText(dynamic item) =>
        item is VideoCollection ? item.name : (item as VideoItem).title;

    // Match every card independently. A matching folder contributes only its
    // own card; its children must match their own rendered titles to appear.
    final results = <dynamic>[
      ..._collections.values.where(
        (collection) =>
            !collection.isRecycled &&
            !hasRecycledAncestor(collection.parentId) &&
            searchQuery.matchesTitle(collection.name),
      ),
      ..._videos.values.where((video) {
        if (video.isRecycled || hasRecycledAncestor(video.parentId)) {
          return false;
        }
        return searchQuery.matchesTitle(video.title);
      }),
    ];

    // Keep folders together, then prefer exact/prefix matches and newer items.
    // This ordering exists only in the virtual result view and is never saved.
    results.sort((left, right) {
      final leftIsFolder = left is VideoCollection;
      final rightIsFolder = right is VideoCollection;
      if (leftIsFolder != rightIsFolder) return leftIsFolder ? -1 : 1;

      final rankComparison = searchQuery
          .rankTitle(displayText(left))
          .compareTo(searchQuery.rankTitle(displayText(right)));
      if (rankComparison != 0) return rankComparison;

      final leftTime = left is VideoCollection
          ? left.createTime
          : (left as VideoItem).lastUpdated;
      final rightTime = right is VideoCollection
          ? right.createTime
          : (right as VideoItem).lastUpdated;
      final timeComparison = rightTime.compareTo(leftTime);
      if (timeComparison != 0) return timeComparison;
      return displayText(left).compareTo(displayText(right));
    });

    return results;
  }

  Future<VideoCollection> createCollection(
    String name,
    String? parentId, {
    String? thumbnailPath,
    MediaSourceRef? sourceRef,
  }) async {
    final collection = VideoCollection(
      id: const Uuid().v4(),
      name: name,
      createTime: DateTime.now().millisecondsSinceEpoch,
      parentId: parentId,
      thumbnailPath: thumbnailPath,
      sourceRef: sourceRef,
    );

    _collections[collection.id] = collection;

    if (parentId != null && _collections.containsKey(parentId)) {
      _collections[parentId]!.childrenIds.add(collection.id);
    } else if (parentId == null) {
      _rootChildrenIds.add(collection.id);
    }

    await _saveLibrary();
    notifyListeners();
    return collection;
  }

  Future<void> updateCollectionSourceRefIfMissing(
    String collectionId,
    MediaSourceRef? sourceRef,
  ) async {
    if (sourceRef == null || sourceRef.value.trim().isEmpty) {
      return;
    }
    final col = _collections[collectionId];
    if (col == null || col.sourceRef != null) {
      return;
    }
    col.sourceRef = sourceRef;
    await _saveLibrary();
    notifyListeners();
  }

  Future<void> updateCollectionThumbnail(
    String collectionId,
    String? thumbnailPath,
  ) async {
    final col = _collections[collectionId];
    if (col == null) return;

    final previousPath = col.thumbnailPath;
    if (previousPath != null &&
        previousPath.isNotEmpty &&
        thumbnailPath != previousPath &&
        p.isWithin(_dataRootDir.path, previousPath)) {
      try {
        final file = File(previousPath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        developer.log('Error deleting previous collection thumbnail', error: e);
      }
    }

    col.thumbnailPath = thumbnailPath;
    ThumbnailCacheService().evictFromCache(collectionId);
    await _saveLibrary();
    notifyListeners();
  }

  Future<StructuredImportSelectionSummary> analyzeFolderSelection(
    String folderPath,
  ) async {
    final rootDir = Directory(folderPath);
    if (!await rootDir.exists()) {
      throw FileSystemException('目录不存在', folderPath);
    }

    // 将递归遍历移入独立 Isolate，避免大文件夹扫描阻塞 UI 线程。
    // 这是 Windows 端"导入文件夹时点击即闪退"的核心根因：
    // UI isolate 被阻塞后 Windows 判定应用无响应并强杀进程。
    final result = await compute(_analyzeFolderSelectionIsolate, folderPath)
        .timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            throw TimeoutException('文件夹扫描超时（30秒），请检查目录是否过大或包含软链接环路');
          },
        );

    final name = p.basename(p.normalize(rootDir.path));
    return StructuredImportSelectionSummary(
      sourcePath: rootDir.path,
      sourceName: name,
      rootCollectionName: name,
      isArchive: false,
      folderCount: result['folderCount'] as int,
      mediaFileCount: result['mediaFileCount'] as int,
    );
  }

  StructuredImportSelectionSummary analyzeArchiveSelection(String archivePath) {
    if (!isSupportedArchivePath(archivePath)) {
      throw UnsupportedError('当前仅支持 zip、tar、tar.gz、tar.bz2、tar.xz 压缩包');
    }
    return StructuredImportSelectionSummary(
      sourcePath: archivePath,
      sourceName: archiveDisplayName(archivePath),
      rootCollectionName: archiveRootCollectionName(archivePath),
      isArchive: true,
      folderCount: 0,
      mediaFileCount: 0,
      detailsDeferred: true,
    );
  }

  Future<StructuredImportExecutionResult> importFolderSelection(
    String folderPath,
    String? parentId, {
    required StructuredImportSortOptions sortOptions,
  }) {
    // Snapshot once: changing the global switch affects the next import
    // immediately, while this folder import remains internally consistent.
    final copyImportedFilesToLibrary =
        SettingsService().copyImportedMediaToPrivateStorage;
    return _runExclusiveImport(() async {
      final rootDir = Directory(folderPath);
      if (!await rootDir.exists()) {
        throw FileSystemException('目录不存在', folderPath);
      }
      final rootName = p.basename(p.normalize(rootDir.path));
      return _importDirectoryTreeIntoLibrary(
        sourceDir: rootDir,
        rootCollectionName: rootName,
        parentId: parentId,
        sortOptions: sortOptions,
        importLabel: '文件夹',
        copyImportedFilesToLibrary: copyImportedFilesToLibrary,
        totalMediaEntriesHint: null,
      );
    });
  }

  Future<T> _runExclusiveImport<T>(Future<T> Function() operation) async {
    if (_importOperationActive) {
      throw StateError('已有导入任务正在运行，请等待完成后再试');
    }
    _importOperationActive = true;
    try {
      return await operation();
    } finally {
      _importOperationActive = false;
    }
  }

  Future<StructuredImportExecutionResult> importArchiveSelection(
    String archivePath,
    String? parentId, {
    required StructuredImportSortOptions sortOptions,
  }) {
    return _runExclusiveImport(
      () => _importArchiveSelectionInternal(
        archivePath,
        parentId,
        sortOptions: sortOptions,
      ),
    );
  }

  Future<StructuredImportExecutionResult> _importArchiveSelectionInternal(
    String archivePath,
    String? parentId, {
    required StructuredImportSortOptions sortOptions,
  }) async {
    if (!isSupportedArchivePath(archivePath)) {
      throw UnsupportedError('当前仅支持 zip、tar、tar.gz、tar.bz2、tar.xz 压缩包');
    }

    final shouldDeleteSourceArchive = await _isAppOwnedArchiveCachePath(
      archivePath,
    );
    final importRootDir = await _createArchiveImportDirectory(archivePath);
    try {
      isImporting.value = true;
      await _setImportProgress(progress: 0.0, status: '正在准备解压压缩包...');
      await _setImportProgress(progress: 0.0, status: '正在后台解压压缩包...');
      final extractionSummary =
          await compute(_extractArchiveToDiskWorker, <String, Object?>{
            'archivePath': archivePath,
            'destDir': importRootDir.path,
            'maxEntryCount': _defaultMaxArchiveEntryCount,
            'maxTotalBytes': _defaultMaxArchiveTotalBytes,
            'maxSingleFileBytes': _defaultMaxArchiveSingleFileBytes,
            'maxPathDepth': _defaultMaxArchivePathDepth,
            'maxCompressionRatio': _defaultMaxArchiveCompressionRatio,
          });
      final extractedMediaEntries =
          extractionSummary['extractedMediaEntries'] ?? 0;
      if (extractedMediaEntries <= 0) {
        throw StateError('压缩包中未解析到可导入的媒体文件');
      }
      await _setImportProgress(
        progress: 0.34,
        status: '解压完成，检测到 $extractedMediaEntries 个媒体，正在导入...',
      );
      return await _importDirectoryTreeIntoLibrary(
        sourceDir: importRootDir,
        rootCollectionName: archiveRootCollectionName(archivePath),
        parentId: parentId,
        sortOptions: sortOptions,
        importLabel: '压缩包',
        moveImportedFilesToLibrary: true,
        totalMediaEntriesHint: extractedMediaEntries,
        deferPostProcessing: true,
      );
    } catch (_) {
      await _deleteDirectoryIfExists(importRootDir);
      rethrow;
    } finally {
      if (await importRootDir.exists()) {
        if (_isImportDirectoryReferenced(importRootDir.path)) {
          await _clearArchiveImportMarker(importRootDir);
        } else {
          await _deleteDirectoryIfExists(importRootDir);
        }
      }
      if (shouldDeleteSourceArchive) {
        await _deleteFileIfExists(archivePath);
      }
      isImporting.value = false;
      importProgress.value = 0.0;
      importStatus.value = '';
    }
  }

  Future<StructuredImportExecutionResult> _importDirectoryTreeIntoLibrary({
    required Directory sourceDir,
    required String rootCollectionName,
    required String? parentId,
    required StructuredImportSortOptions sortOptions,
    required String importLabel,
    bool moveImportedFilesToLibrary = false,
    bool copyImportedFilesToLibrary = false,
    required int? totalMediaEntriesHint,
    bool deferPostProcessing = false,
  }) async {
    await Future.delayed(const Duration(milliseconds: 120));
    if (parentId != null && !_collections.containsKey(parentId)) {
      throw StateError('目标文件夹不存在');
    }

    final accumulator = _StructuredImportAccumulator();
    DateTime lastNotifyTime = DateTime.now();
    late VideoCollection rootCollection;

    try {
      _invalidateSizeCaches();
      isImporting.value = true;
      importProgress.value = 0.0;
      importStatus.value = '正在创建文件夹结构...';

      rootCollection = _createCollectionInMemory(
        rootCollectionName,
        parentId,
        accumulator,
      );
      accumulator.createdFolderCount++;

      await _importDirectoryContentsRecursive(
        sourceDir: sourceDir,
        parentCollectionId: rootCollection.id,
        sortOptions: sortOptions,
        accumulator: accumulator,
        lastNotifyTime: () => lastNotifyTime,
        updateLastNotifyTime: (value) => lastNotifyTime = value,
        moveImportedFilesToLibrary: moveImportedFilesToLibrary,
        copyImportedFilesToLibrary: copyImportedFilesToLibrary,
        totalMediaEntriesHint: totalMediaEntriesHint,
        importLabel: importLabel,
        probeDurationDuringImport: !deferPostProcessing,
      );

      await _saveLibrary();
      notifyListeners();

      if (deferPostProcessing) {
        final postProcessIds = List<String>.from(accumulator.newVideoIds);
        unawaited(
          _postImportQueue
              .enqueue(() => _postProcessImportedIds(postProcessIds))
              .catchError((Object error, StackTrace stackTrace) {
                developer.log(
                  '导入后媒体处理失败',
                  error: error,
                  stackTrace: stackTrace,
                  name: 'library.post_import',
                );
              }),
        );
      } else {
        await _generateThumbnailsForImportedIds(
          accumulator.newVideoIds,
          statusPrefix: importLabel,
        );
        await _saveLibrary();
        notifyListeners();
      }

      return StructuredImportExecutionResult(
        rootCollectionId: rootCollection.id,
        createdFolderCount: accumulator.createdFolderCount,
        importedMediaCount: accumulator.importedMediaCount,
        restoredMediaCount: accumulator.restoredMediaCount,
      );
    } catch (e) {
      await _cleanupStructuredImportArtifacts(accumulator.newVideoIds);
      _rollbackStructuredImportState(accumulator);
      await _saveLibrary();
      notifyListeners();
      rethrow;
    } finally {
      isImporting.value = false;
      importProgress.value = 0.0;
      importStatus.value = '';
    }
  }

  Future<void> _importDirectoryContentsRecursive({
    required Directory sourceDir,
    required String parentCollectionId,
    required StructuredImportSortOptions sortOptions,
    required _StructuredImportAccumulator accumulator,
    required DateTime Function() lastNotifyTime,
    required void Function(DateTime value) updateLastNotifyTime,
    required bool moveImportedFilesToLibrary,
    required bool copyImportedFilesToLibrary,
    required int? totalMediaEntriesHint,
    required String importLabel,
    required bool probeDurationDuringImport,
  }) async {
    final entries = await _collectImportEntries(sourceDir, sortOptions);
    for (final entry in entries) {
      if (entry.isDirectory) {
        final childCollection = _createCollectionInMemory(
          entry.name,
          parentCollectionId,
          accumulator,
        );
        accumulator.createdFolderCount++;
        await _importDirectoryContentsRecursive(
          sourceDir: Directory(entry.entity.path),
          parentCollectionId: childCollection.id,
          sortOptions: sortOptions,
          accumulator: accumulator,
          lastNotifyTime: lastNotifyTime,
          updateLastNotifyTime: updateLastNotifyTime,
          moveImportedFilesToLibrary: moveImportedFilesToLibrary,
          copyImportedFilesToLibrary: copyImportedFilesToLibrary,
          totalMediaEntriesHint: totalMediaEntriesHint,
          importLabel: importLabel,
          probeDurationDuringImport: probeDurationDuringImport,
        );
      } else {
        await _addStructuredMediaFile(
          filePath: entry.entity.path,
          parentId: parentCollectionId,
          accumulator: accumulator,
          moveImportedFilesToLibrary: moveImportedFilesToLibrary,
          copyImportedFilesToLibrary: copyImportedFilesToLibrary,
          probeDuration: probeDurationDuringImport,
        );
        await _updateStructuredImportProgressIfNeeded(
          accumulator: accumulator,
          totalMediaEntriesHint: totalMediaEntriesHint,
          importLabel: importLabel,
          lastNotifyTime: lastNotifyTime,
          updateLastNotifyTime: updateLastNotifyTime,
        );
      }

      if (DateTime.now().difference(lastNotifyTime()).inMilliseconds > 600) {
        notifyListeners();
        updateLastNotifyTime(DateTime.now());
      }
    }
  }

  Future<void> _updateStructuredImportProgressIfNeeded({
    required _StructuredImportAccumulator accumulator,
    required int? totalMediaEntriesHint,
    required String importLabel,
    required DateTime Function() lastNotifyTime,
    required void Function(DateTime value) updateLastNotifyTime,
  }) async {
    if (totalMediaEntriesHint == null || totalMediaEntriesHint <= 0) {
      return;
    }

    final importedCount = accumulator.importedMediaCount;
    if (importedCount <= 0) {
      return;
    }

    final now = DateTime.now();
    final shouldForceUpdate = importedCount >= totalMediaEntriesHint;
    if (!shouldForceUpdate &&
        now.difference(lastNotifyTime()).inMilliseconds <= 160) {
      return;
    }

    final normalizedProgress = (importedCount / totalMediaEntriesHint)
        .clamp(0.0, 1.0)
        .toDouble();
    final progress = 0.34 + (normalizedProgress * 0.36);
    await _setImportProgress(
      progress: shouldForceUpdate
          ? 0.70
          : progress.clamp(0.34, 0.70).toDouble(),
      status: '正在导入$importLabel媒体...($importedCount/$totalMediaEntriesHint)',
    );
    updateLastNotifyTime(now);
  }

  Future<List<_FileSystemEntrySnapshot>> _collectImportEntries(
    Directory sourceDir,
    StructuredImportSortOptions sortOptions,
  ) async {
    final entries = <_FileSystemEntrySnapshot>[];
    await for (final entity in sourceDir.list(followLinks: false)) {
      if (entity is Directory) {
        entries.add(await _snapshotImportEntry(entity, true));
      } else if (entity is File && isSupportedMediaPath(entity.path)) {
        entries.add(await _snapshotImportEntry(entity, false));
      }
    }

    entries.sort((left, right) {
      int comparison;
      if (sortOptions.field == StructuredImportSortField.modifiedTime) {
        comparison = left.modifiedTimeMs.compareTo(right.modifiedTimeMs);
        if (comparison == 0) {
          comparison = compareStructuredImportNames(left.name, right.name);
        }
      } else {
        comparison = compareStructuredImportNames(left.name, right.name);
      }
      if (comparison == 0 && left.isDirectory != right.isDirectory) {
        comparison = left.isDirectory ? -1 : 1;
      }
      if (sortOptions.direction == StructuredImportSortDirection.descending) {
        comparison *= -1;
      }
      return comparison;
    });
    return entries;
  }

  static int compareStructuredImportNames(String left, String right) {
    final leftParts = _splitNaturalSortParts(left);
    final rightParts = _splitNaturalSortParts(right);
    final minLength = leftParts.length < rightParts.length
        ? leftParts.length
        : rightParts.length;

    for (var i = 0; i < minLength; i++) {
      final leftPart = leftParts[i];
      final rightPart = rightParts[i];
      final leftIsNumber = RegExp(r'^\d+$').hasMatch(leftPart);
      final rightIsNumber = RegExp(r'^\d+$').hasMatch(rightPart);

      int comparison;
      if (leftIsNumber && rightIsNumber) {
        comparison = int.parse(leftPart).compareTo(int.parse(rightPart));
      } else {
        comparison = _normalizeSortSegment(
          leftPart,
        ).compareTo(_normalizeSortSegment(rightPart));
      }
      if (comparison != 0) {
        return comparison;
      }
    }

    final lengthComparison = leftParts.length.compareTo(rightParts.length);
    if (lengthComparison != 0) {
      return lengthComparison;
    }

    return left.toLowerCase().compareTo(right.toLowerCase());
  }

  static List<String> _splitNaturalSortParts(String value) {
    return RegExp(
      r'\d+|\D+',
    ).allMatches(value).map((m) => m.group(0)!).toList();
  }

  static String _normalizeSortSegment(String value) {
    if (!_containsChineseCharacters(value)) {
      return value.toLowerCase();
    }

    final pinyin = PinyinHelper.getPinyinE(
      value,
      separator: '',
      defPinyin: '',
      format: PinyinFormat.WITHOUT_TONE,
    );
    return pinyin.toLowerCase();
  }

  static bool _containsChineseCharacters(String value) {
    return RegExp(r'[\u3400-\u9FFF]').hasMatch(value);
  }

  Future<_FileSystemEntrySnapshot> _snapshotImportEntry(
    FileSystemEntity entity,
    bool isDirectory,
  ) async {
    var modifiedTimeMs = 0;
    try {
      modifiedTimeMs = (await entity.stat()).modified.millisecondsSinceEpoch;
    } catch (_) {}
    return _FileSystemEntrySnapshot(
      entity: entity,
      name: p.basename(entity.path),
      isDirectory: isDirectory,
      modifiedTimeMs: modifiedTimeMs,
    );
  }

  Future<void> _addStructuredMediaFile({
    required String filePath,
    required String? parentId,
    required _StructuredImportAccumulator accumulator,
    required bool moveImportedFilesToLibrary,
    required bool copyImportedFilesToLibrary,
    required bool probeDuration,
  }) async {
    final id = const Uuid().v4();

    final shouldManageSidecarSubtitles =
        moveImportedFilesToLibrary || copyImportedFilesToLibrary;
    final discoveredSubtitles = shouldManageSidecarSubtitles
        ? await const SubtitleDiscoveryService().scanVideoDirectory(
            videoPath: filePath,
            rules: SubtitleScanRules(
              prefixMatchMode: SettingsService().desktopSubtitlePrefixMatchMode,
              caseSensitive: SettingsService().desktopSubtitleScanCaseSensitive,
            ),
          )
        : const <DiscoveredSubtitleFile>[];

    var effectivePath = filePath;
    if (moveImportedFilesToLibrary) {
      effectivePath = await _moveStructuredImportFileToLibrary(
        filePath,
        fileNamePrefix: id,
      );
      if (_samePath(effectivePath, filePath)) {
        throw FileSystemException('压缩包媒体移入应用存储失败', filePath);
      }
    } else if (copyImportedFilesToLibrary) {
      effectivePath = await _copyImportedMediaToPrivateStorage(
        filePath,
        fileNamePrefix: id,
      );
    }

    final originalTitle = _normalizeImportedName(p.basename(filePath));
    final sourceFingerprint = await _computeSourceFingerprint(effectivePath);
    final durationMs = probeDuration
        ? await _probeMediaDurationMs(effectivePath)
        : 0;
    final item = VideoItem(
      id: id,
      path: effectivePath,
      title: originalTitle,
      thumbnailPath: null,
      durationMs: durationMs,
      lastUpdated: DateTime.now().millisecondsSinceEpoch,
      parentId: parentId,
      type: _detectMediaType(effectivePath),
      sourceFingerprint: sourceFingerprint,
    );
    try {
      await _adoptStructuredImportSubtitles(item, discoveredSubtitles);
      if (probeDuration) {
        item.chapters = await MediaChapterProbe.probe(
          effectivePath,
          durationMs: durationMs,
        );
        item.hasProbedChapters = true;
      }
      await _prepareCompatiblePlaybackFile(item, saveLibrary: false);
    } catch (_) {
      await TaskSubtitleStorageService(
        dataRootOverride: _dataRootDir,
      ).deleteTaskDirectory(id);
      if ((moveImportedFilesToLibrary || copyImportedFilesToLibrary) &&
          _isInternalPath(effectivePath)) {
        await _deleteFileIfExists(effectivePath);
      }
      rethrow;
    }
    _videos[id] = item;
    if (parentId != null && _collections.containsKey(parentId)) {
      _collections[parentId]!.childrenIds.add(id);
    } else {
      _rootChildrenIds.add(id);
    }
    accumulator.newVideoIds.add(id);
    accumulator.importedMediaCount++;
  }

  Future<void> _adoptStructuredImportSubtitles(
    VideoItem item,
    List<DiscoveredSubtitleFile> subtitles,
  ) async {
    if (subtitles.isEmpty) return;

    final storage = TaskSubtitleStorageService(dataRootOverride: _dataRootDir);
    final localSubtitles = <String, String>{};
    final managedAssets = <ManagedSubtitleAsset>[];
    for (final subtitle in subtitles) {
      final copiedPath = await storage.copyIntoTask(
        item.id,
        subtitle.path,
        preferredFileName: p.basename(subtitle.path),
      );
      var displayName = p.basename(subtitle.path);
      if (localSubtitles.containsKey(displayName)) {
        final baseName = displayName;
        var serial = 2;
        while (localSubtitles.containsKey('$baseName（$serial）')) {
          serial++;
        }
        displayName = '$baseName（$serial）';
      }
      localSubtitles[displayName] = copiedPath;
      managedAssets.add(
        ManagedSubtitleAsset(
          assetId: const Uuid().v4(),
          path: p.normalize(copiedPath),
          kind: ManagedSubtitleAssetKind.imported,
          displayName: displayName,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }

    item.localSubtitles = localSubtitles;
    item.managedSubtitleAssets = managedAssets;
    item.subtitlePath = managedAssets.first.path;
    item.isSubtitleCached = true;
  }

  VideoCollection _createCollectionInMemory(
    String name,
    String? parentId,
    _StructuredImportAccumulator accumulator,
  ) {
    final collection = VideoCollection(
      id: const Uuid().v4(),
      name: name,
      createTime: DateTime.now().millisecondsSinceEpoch,
      parentId: parentId,
    );
    _collections[collection.id] = collection;
    accumulator.newCollectionIds.add(collection.id);
    if (parentId != null && _collections.containsKey(parentId)) {
      _collections[parentId]!.childrenIds.add(collection.id);
    } else {
      _rootChildrenIds.add(collection.id);
    }
    return collection;
  }

  void _rollbackStructuredImportState(
    _StructuredImportAccumulator accumulator,
  ) {
    for (final videoId in accumulator.newVideoIds) {
      final item = _videos.remove(videoId);
      if (item?.parentId != null) {
        _collections[item!.parentId]?.childrenIds.remove(videoId);
      } else {
        _rootChildrenIds.remove(videoId);
      }
    }
    for (final collectionId in accumulator.newCollectionIds.reversed) {
      final collection = _collections.remove(collectionId);
      if (collection?.parentId != null) {
        _collections[collection!.parentId]?.childrenIds.remove(collectionId);
      } else {
        _rootChildrenIds.remove(collectionId);
      }
    }
    _invalidateSizeCaches();
  }

  Future<void> _generateThumbnailsForImportedIds(
    List<String> newIds, {
    required String statusPrefix,
    bool reportProgress = true,
  }) async {
    if (newIds.isEmpty) {
      if (reportProgress) {
        await _setImportProgress(progress: 1.0, status: '$statusPrefix导入完成');
      }
      return;
    }

    if (reportProgress) {
      await _setImportProgress(progress: 0.7, status: '正在生成缩略图...');
    }
    var current = 0;
    // Windows 端每个 _generateThumbnailWindows 最多启动 2 个 ffmpeg 进程，
    // batchSize=4 时峰值可达 8+ 个 ffmpeg.exe 并发，易耗尽内存导致闪退。
    // 降为 2 后峰值约 4 个，内存占用更可控。
    final isDesktop =
        Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    final batchSize = isDesktop ? 2 : 1;
    for (int i = 0; i < newIds.length; i += batchSize) {
      final batch = newIds.sublist(
        i,
        i + batchSize > newIds.length ? newIds.length : i + batchSize,
      );
      await Future.wait(
        batch.map((id) async {
          final item = _videos[id];
          if (item == null || item.type != MediaType.video) {
            return;
          }
          // 独立 try-catch：单个缩略图失败不应中断整批导入
          try {
            item.thumbnailPath = await _generateThumbnail(
              item.path,
              videoId: item.id,
            );
          } catch (e) {
            developer.log(
              '缩略图生成失败: ${item.path}',
              error: e,
              name: 'library.thumbnail',
            );
          }
        }),
      );
      current += batch.length;
      if (reportProgress) {
        final progress = 0.7 + (current / newIds.length) * 0.3;
        await _setImportProgress(
          progress: progress.clamp(0.0, 1.0).toDouble(),
          status: '正在生成缩略图...($current/${newIds.length})',
        );
      }
    }
  }

  Future<void> _postProcessImportedIds(List<String> importedIds) async {
    var changed = false;
    for (final id in importedIds) {
      final item = _videos[id];
      if (item == null) continue;
      if (item.durationMs <= 0) {
        final durationMs = await _probeMediaDurationMs(item.path);
        if (durationMs > 0 && _videos[id] != null) {
          item.durationMs = durationMs;
          item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
          changed = true;
        }
      }
      if (!item.hasProbedChapters && _videos[id] != null) {
        item.chapters = await MediaChapterProbe.probe(
          item.path,
          durationMs: item.durationMs,
        );
        item.hasProbedChapters = true;
        item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
        changed = true;
      }
    }

    await _generateThumbnailsForImportedIds(
      importedIds,
      statusPrefix: '后台',
      reportProgress: false,
    );
    if (changed || importedIds.isNotEmpty) {
      await _saveLibrary();
      notifyListeners();
    }
  }

  Future<void> _setImportProgress({
    required double progress,
    required String status,
  }) async {
    importProgress.value = progress;
    importStatus.value = status;
  }

  Future<void> _cleanupStructuredImportArtifacts(
    Iterable<String> importedVideoIds,
  ) async {
    for (final videoId in importedVideoIds) {
      final item = _videos[videoId];
      if (item == null) {
        continue;
      }
      final candidatePaths = <String>[
        item.path,
        if (item.thumbnailPath != null && item.thumbnailPath!.isNotEmpty)
          item.thumbnailPath!,
      ];

      for (final path in candidatePaths) {
        if (!_isInternalPath(path)) {
          continue;
        }
        try {
          final file = File(path);
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {}
      }
      try {
        await TaskSubtitleStorageService(
          dataRootOverride: _dataRootDir,
        ).deleteTaskDirectory(videoId);
      } catch (_) {}
    }
  }

  Future<Directory> _createArchiveImportDirectory(String archivePath) async {
    final importedArchivesDir = Directory(
      p.join(_dataRootDir.path, _importedArchivesDirName),
    );
    if (!await importedArchivesDir.exists()) {
      await importedArchivesDir.create(recursive: true);
    }

    final safeName = archiveRootCollectionName(
      archivePath,
    ).replaceAll(RegExp(r'[<>:"/\\|?*]+'), '_').trim();
    final baseName = _sanitizeArchivePathSegment(
      safeName.isEmpty ? 'archive' : safeName,
      preserveExtension: false,
      fallbackName: 'archive',
    );
    final importDir = Directory(
      p.join(
        importedArchivesDir.path,
        '${DateTime.now().millisecondsSinceEpoch}_$baseName',
      ),
    );
    await importDir.create(recursive: true);
    await _writeArchiveImportMarker(importDir, archivePath);
    return importDir;
  }

  Future<void> _writeArchiveImportMarker(
    Directory importDir,
    String archivePath,
  ) async {
    final markerFile = File(p.join(importDir.path, _archiveImportMarkerName));
    await markerFile.writeAsString(
      json.encode({
        'archivePath': archivePath,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      }),
      flush: true,
    );
  }

  Future<void> _clearArchiveImportMarker(Directory importDir) async {
    final markerFile = File(p.join(importDir.path, _archiveImportMarkerName));
    if (await markerFile.exists()) {
      await markerFile.delete();
    }
  }

  Future<void> _cleanupIncompleteArchiveImports() async {
    final importedArchivesDir = Directory(
      p.join(_dataRootDir.path, _importedArchivesDirName),
    );
    if (!await importedArchivesDir.exists()) {
      return;
    }

    await for (final entity in importedArchivesDir.list(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }
      final markerFile = File(p.join(entity.path, _archiveImportMarkerName));
      final hasMarker = await markerFile.exists();
      final archivePath = hasMarker
          ? await _readArchivePathFromMarker(markerFile)
          : null;

      if (_isImportDirectoryReferenced(entity.path)) {
        if (hasMarker) {
          await _clearArchiveImportMarker(entity);
        }
      } else {
        await _deleteDirectoryIfExists(entity);
      }

      if (archivePath != null &&
          await _isAppOwnedArchiveCachePath(archivePath)) {
        await _deleteFileIfExists(archivePath);
      }
    }
  }

  Future<void> _cleanupOrphanedArchiveSelectionCaches() async {
    final cacheDirs = <Directory>[];
    try {
      final tempDir = await getTemporaryDirectory();
      cacheDirs.add(
        Directory(p.join(tempDir.path, _pickedArchivesCacheDirName)),
      );
    } catch (_) {}

    if (Platform.isAndroid) {
      try {
        final extCacheDirs = await getExternalCacheDirectories();
        if (extCacheDirs != null) {
          for (final dir in extCacheDirs) {
            cacheDirs.add(
              Directory(p.join(dir.path, _pickedArchivesCacheDirName)),
            );
          }
        }
      } catch (_) {}
    }

    final seen = <String>{};
    for (final dir in cacheDirs) {
      final normalizedPath = p.normalize(dir.path);
      if (!seen.add(
        Platform.isWindows ? normalizedPath.toLowerCase() : normalizedPath,
      )) {
        continue;
      }
      await _deleteDirectoryIfExists(dir);
    }
  }

  Future<TemporaryStorageCategoryReport>
  buildArchiveTemporaryStorageReport() async {
    final stats = await _collectArchiveTemporaryStorageStats();
    return TemporaryStorageCategoryReport(
      id: 'archive_import_temp',
      title: '压缩包导入临时文件',
      description: '压缩包选择缓存与未被媒体库引用的中间导入目录',
      fileCount: stats.fileCount,
      totalBytes: stats.totalBytes,
      canClean: stats.fileCount > 0,
      note: stats.fileCount == 0 ? '未发现可安全清理的压缩包临时文件。' : null,
    );
  }

  Future<void> clearArchiveTemporaryStorageArtifacts() async {
    final stats = await _collectArchiveTemporaryStorageStats(
      includeDirectories: true,
    );
    for (final file in stats.files) {
      await _deleteFileIfExists(file.path);
    }
    for (final dir in stats.directories) {
      await _deleteDirectoryIfExists(dir);
    }
  }

  bool _isImportDirectoryReferenced(String importDirPath) {
    final normalizedImportPath = p.normalize(importDirPath);
    for (final item in _videos.values) {
      final normalizedVideoPath = p.normalize(item.path);
      if (p.equals(normalizedImportPath, normalizedVideoPath) ||
          p.isWithin(normalizedImportPath, normalizedVideoPath)) {
        return true;
      }
    }
    return false;
  }

  Future<_ArchiveTemporaryStorageStats> _collectArchiveTemporaryStorageStats({
    bool includeDirectories = false,
  }) async {
    final files = <File>{};
    final directories = <Directory>{};
    final protectedArchivePaths =
        await _collectProtectedArchiveSelectionPaths();

    final importedArchivesDir = Directory(
      p.join(_dataRootDir.path, _importedArchivesDirName),
    );
    if (await importedArchivesDir.exists()) {
      await for (final entity in importedArchivesDir.list(followLinks: false)) {
        if (entity is! Directory || _isImportDirectoryReferenced(entity.path)) {
          continue;
        }
        if (includeDirectories) {
          directories.add(entity);
        } else {
          await _collectFilesRecursively(entity, files);
        }
      }
    }

    final cacheDirs = await _collectArchiveSelectionCacheDirs();
    for (final cacheDir in cacheDirs) {
      if (!await cacheDir.exists()) {
        continue;
      }
      await for (final entity in cacheDir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          final normalizedPath = _normalizeTemporaryStoragePath(entity.path);
          if (protectedArchivePaths.contains(normalizedPath)) {
            continue;
          }
          files.add(entity);
        } else if (includeDirectories && entity is Directory) {
          directories.add(entity);
        }
      }
      if (includeDirectories) {
        directories.add(cacheDir);
      }
    }

    var totalBytes = 0;
    for (final file in files) {
      totalBytes += await _safeTemporaryStorageFileSize(file);
    }

    return _ArchiveTemporaryStorageStats(
      files: files.toList(),
      directories: directories.toList()
        ..sort((a, b) => b.path.length.compareTo(a.path.length)),
      fileCount: files.length,
      totalBytes: totalBytes,
    );
  }

  Future<List<Directory>> _collectArchiveSelectionCacheDirs() async {
    final cacheDirs = <Directory>[];
    try {
      final tempDir = await getTemporaryDirectory();
      cacheDirs.add(
        Directory(p.join(tempDir.path, _pickedArchivesCacheDirName)),
      );
    } catch (_) {}

    if (Platform.isAndroid) {
      try {
        final extCacheDirs = await getExternalCacheDirectories();
        if (extCacheDirs != null) {
          for (final dir in extCacheDirs) {
            cacheDirs.add(
              Directory(p.join(dir.path, _pickedArchivesCacheDirName)),
            );
          }
        }
      } catch (_) {}
    }

    final seen = <String>{};
    return cacheDirs.where((dir) {
      return seen.add(_normalizeTemporaryStoragePath(dir.path));
    }).toList();
  }

  Future<Set<String>> _collectProtectedArchiveSelectionPaths() async {
    final protected = <String>{};
    final importedArchivesDir = Directory(
      p.join(_dataRootDir.path, _importedArchivesDirName),
    );
    if (!await importedArchivesDir.exists()) {
      return protected;
    }

    await for (final entity in importedArchivesDir.list(followLinks: false)) {
      if (entity is! Directory || !_isImportDirectoryReferenced(entity.path)) {
        continue;
      }
      final markerFile = File(p.join(entity.path, _archiveImportMarkerName));
      final archivePath = await _readArchivePathFromMarker(markerFile);
      if (archivePath == null || archivePath.isEmpty) {
        continue;
      }
      if (await _isAppOwnedArchiveCachePath(archivePath)) {
        protected.add(_normalizeTemporaryStoragePath(archivePath));
      }
    }
    return protected;
  }

  Future<void> _collectFilesRecursively(
    Directory root,
    Set<File> output,
  ) async {
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        output.add(entity);
      }
    }
  }

  String _normalizeTemporaryStoragePath(String path) {
    final normalized = p.normalize(path);
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  Future<int> _safeTemporaryStorageFileSize(File file) async {
    try {
      if (!await file.exists()) {
        return 0;
      }
      return await file.length();
    } catch (_) {
      return 0;
    }
  }

  Future<void> _deleteDirectoryIfExists(Directory dir) async {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  Future<String?> _readArchivePathFromMarker(File markerFile) async {
    try {
      final raw = await markerFile.readAsString();
      final decoded = json.decode(raw);
      if (decoded is Map<String, dynamic>) {
        final archivePath = decoded['archivePath'];
        if (archivePath is String && archivePath.isNotEmpty) {
          return archivePath;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _deleteFileIfExists(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  Future<bool> _isAppOwnedArchiveCachePath(String filePath) async {
    try {
      final normalizedPath = p.normalize(filePath);
      final tempDir = await getTemporaryDirectory();
      final archiveCache = p.normalize(
        p.join(tempDir.path, _pickedArchivesCacheDirName),
      );
      if (p.isWithin(archiveCache, normalizedPath)) {
        return true;
      }

      if (Platform.isAndroid) {
        final extCacheDirs = await getExternalCacheDirectories();
        if (extCacheDirs != null) {
          for (final dir in extCacheDirs) {
            final externalArchiveCache = p.normalize(
              p.join(dir.path, _pickedArchivesCacheDirName),
            );
            if (p.isWithin(externalArchiveCache, normalizedPath)) {
              return true;
            }
          }
        }
      }
    } catch (_) {}
    return false;
  }

  String _sanitizeImportedFileName(String fileName) {
    return _sanitizeArchivePathSegment(
      fileName,
      preserveExtension: true,
      fallbackName: 'file',
    );
  }

  /// Creates a verified app-managed copy without ever exposing a partially
  /// copied file as a playable media source.
  Future<String> _copyImportedMediaToPrivateStorage(
    String sourcePath, {
    required String fileNamePrefix,
  }) async {
    final normalizedSourcePath = p.normalize(sourcePath);
    final importedDir = Directory(p.join(_dataRootDir.path, 'imported_videos'));
    final sourceFile = File(normalizedSourcePath);
    if (!await sourceFile.exists()) {
      throw FileSystemException('导入源文件不存在', normalizedSourcePath);
    }

    await importedDir.create(recursive: true);
    final safeName = _sanitizeImportedFileName(p.basename(sourcePath));
    final targetPath = p.join(importedDir.path, '${fileNamePrefix}_$safeName');
    final partialPath = '$targetPath.partial';
    final partialFile = File(partialPath);
    final targetFile = File(targetPath);

    try {
      await _deleteFileIfExists(partialPath);
      await sourceFile.copy(partialPath);
      final sourceLength = await sourceFile.length();
      final copiedLength = await partialFile.length();
      if (sourceLength != copiedLength) {
        throw FileSystemException('媒体副本校验失败（文件大小不一致）', normalizedSourcePath);
      }
      if (await targetFile.exists()) {
        throw FileSystemException('媒体副本目标已存在', targetPath);
      }
      await partialFile.rename(targetPath);
      return targetPath;
    } catch (_) {
      await _deleteFileIfExists(partialPath);
      rethrow;
    }
  }

  Future<String> _moveStructuredImportFileToLibrary(
    String sourcePath, {
    required String fileNamePrefix,
  }) async {
    try {
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        return sourcePath;
      }

      final importedDir = Directory(
        p.join(_dataRootDir.path, 'imported_videos'),
      );
      if (!await importedDir.exists()) {
        await importedDir.create(recursive: true);
      }

      final targetPath = p.join(
        importedDir.path,
        '${fileNamePrefix}_${_sanitizeImportedFileName(p.basename(sourcePath))}',
      );

      try {
        return (await sourceFile.rename(targetPath)).path;
      } catch (_) {
        await sourceFile.copy(targetPath);
        await _deleteFileIfExists(sourcePath);
        return targetPath;
      }
    } catch (_) {
      return sourcePath;
    }
  }

  // Batch import videos
  // filePaths: 视频文件的内部存储路径列表
  // parentId: 目标文件夹ID
  // shouldCopy: 是否复制文件到内部存储（仅用于外部文件）
  // useOriginalPath: 是否直接使用原始文件路径而不复制到应用内部存储
  // originalTitles: 可选参数，原始文件名列表，用于设置视频标题
  // reuseExistingItem: 是否复用已存在的媒体卡片；默认 false，导入同源文件时也创建新卡片
  Future<void> importVideosBackground(
    List<String> filePaths,
    String? parentId, {
    bool shouldCopy = false,
    bool allowCacheRescue = true,
    bool useOriginalPath = false,
    bool reuseExistingItem = false,
    List<String>? originalTitles,
  }) async {
    int total = filePaths.length;
    if (total == 0) return;
    final copyImportedMediaToPrivateStorage =
        SettingsService().copyImportedMediaToPrivateStorage;

    // Validate parent
    if (parentId != null && !_collections.containsKey(parentId)) {
      return; // Parent not found
    }
    if (_importOperationActive) {
      debugPrint(
        'Ignored overlapping media import while another import is active',
      );
      return;
    }
    _importOperationActive = true;

    // Give UI a chance to render the "Started importing" snackbar.
    await Future.delayed(const Duration(milliseconds: 200));

    try {
      isImporting.value = true;
      importProgress.value = 0.0;
      importStatus.value = reuseExistingItem ? "正在检查现有媒体..." : "正在准备导入文件...";

      List<String> newIds = [];
      DateTime lastNotifyTime = DateTime.now();

      importStatus.value = "正在添加文件...";

      // Prepare for cache rescue
      Directory? tempDir;
      List<Directory>? extCacheDirs;
      try {
        tempDir = await getTemporaryDirectory();
        if (Platform.isAndroid) {
          extCacheDirs = await getExternalCacheDirectories();
        }
      } catch (e) {
        debugPrint("Error getting temp/cache dirs: $e");
      }

      for (int i = 0; i < filePaths.length; i++) {
        var path = filePaths[i];
        final id = const Uuid().v4();
        // 使用原始标题（如果提供了），否则使用路径的文件名
        final originalTitle = _normalizeImportedName(
          (originalTitles != null && i < originalTitles.length)
              ? originalTitles[i]
              : p.basename(path),
        );
        final sourceFingerprint = await _computeSourceFingerprint(path);

        if (reuseExistingItem) {
          final existingId = await _findExistingVideoIdByPathOrFingerprint(
            path,
            sourceFingerprint: sourceFingerprint,
            originalTitle: originalTitle,
          );
          if (existingId != null) {
            await _restoreExistingVideoToTarget(existingId, parentId);
            continue;
          }
        }

        // 0. Cache Rescue (Copy cached files to persistent storage)
        // 如果 useOriginalPath 为 true，则跳过缓存救援和文件复制，直接使用原始路径
        if (!useOriginalPath || copyImportedMediaToPrivateStorage) {
          bool isCached = false;
          if (allowCacheRescue) {
            if (tempDir != null && p.isWithin(tempDir.path, path)) {
              isCached = true;
            } else if (extCacheDirs != null) {
              for (var dir in extCacheDirs) {
                if (p.isWithin(dir.path, path)) {
                  isCached = true;
                  break;
                }
              }
            }
          }

          if ((allowCacheRescue && isCached) ||
              shouldCopy ||
              copyImportedMediaToPrivateStorage) {
            try {
              path = await _copyImportedMediaToPrivateStorage(
                path,
                fileNamePrefix: id,
              );
              debugPrint(
                "Copied video to: $path (Cached: $isCached, Forced: ${shouldCopy || copyImportedMediaToPrivateStorage})",
              );
            } catch (e) {
              developer.log(
                '复制导入媒体到应用私有目录失败',
                error: e,
                name: 'library.import',
              );
              importStatus.value = '复制媒体失败，已跳过：$originalTitle';
              continue;
            }
          }
        } else {
          debugPrint("Using original path (no copy): $path");
        }

        final durationMs = await _probeMediaDurationMs(path);
        final item = VideoItem(
          id: id,
          path: path,
          title: originalTitle,
          thumbnailPath: null,
          durationMs: durationMs,
          lastUpdated: DateTime.now().millisecondsSinceEpoch,
          parentId: parentId,
          type: _detectMediaType(path),
          sourceFingerprint: sourceFingerprint,
        );
        item.chapters = await MediaChapterProbe.probe(
          path,
          durationMs: durationMs,
        );
        item.hasProbedChapters = true;
        await _prepareCompatiblePlaybackFile(item, saveLibrary: false);

        _videos[id] = item;

        if (parentId != null) {
          _collections[parentId]!.childrenIds.add(id);
        } else {
          _rootChildrenIds.add(id);
        }

        newIds.add(id);

        // Debounce notify
        if (DateTime.now().difference(lastNotifyTime).inMilliseconds > 300) {
          notifyListeners();
          lastNotifyTime = DateTime.now();
        }
      }

      if (newIds.isEmpty) {
        importStatus.value = "没有新文件需要导入";
        await Future.delayed(const Duration(seconds: 1));
        return;
      }

      await _saveLibrary();
      notifyListeners();

      // Phase 2: Parallel Thumbnail Generation
      importStatus.value = "正在生成缩略图...";
      int current = 0;
      total = newIds.length; // Update total to actual new items

      // Process in batches to control concurrency
      const int batchSize = 4;
      for (int i = 0; i < newIds.length; i += batchSize) {
        if (!isImporting.value) break;

        final end = (i + batchSize < newIds.length)
            ? i + batchSize
            : newIds.length;
        final batch = newIds.sublist(i, end);

        await Future.wait(
          batch.map((id) async {
            if (!isImporting.value) return;
            try {
              final item = _videos[id];
              if (item == null) return;

              final thumbPath = await _generateThumbnail(
                item.path,
                videoId: item.id,
              );
              item.thumbnailPath = thumbPath;
            } catch (e) {
              debugPrint("Error processing metadata for $id: $e");
            }
          }),
        );

        current += batch.length;
        final progress = current / total;
        importProgress.value = progress;
        importStatus.value = "处理中: ${(progress * 100).toInt()}%";

        if (DateTime.now().difference(lastNotifyTime).inMilliseconds > 300) {
          notifyListeners();
          lastNotifyTime = DateTime.now();
        }
      }

      await _saveLibrary();
      notifyListeners();
    } catch (e) {
      debugPrint("Import error: $e");
      importStatus.value = "导入出错: $e";
    } finally {
      // Reset
      isImporting.value = false;
      importProgress.value = 0.0;
      importStatus.value = "";
      _importOperationActive = false;
    }
  }

  // Unified Recycle Bin Methods
  Future<void> moveToRecycleBin(List<String> ids) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    _invalidateSizeCaches();

    for (var id in ids) {
      String? parentId;
      if (_collections.containsKey(id)) {
        final col = _collections[id]!;
        col.isRecycled = true;
        col.recycleTime = now;
        parentId = col.parentId;
      } else if (_videos.containsKey(id)) {
        final vid = _videos[id]!;
        final selectedPaths = <String>[];
        if (vid.subtitlePath != null) {
          selectedPaths.add(vid.subtitlePath!);
        }
        if (vid.secondarySubtitlePath != null) {
          selectedPaths.add(vid.secondarySubtitlePath!);
        }
        vid.recycledSelectedSubtitlePaths = selectedPaths.isEmpty
            ? null
            : selectedPaths;
        // Preserve origin maps independently. Reconstructing this map from all
        // referenced subtitle paths would wrongly turn selected/local files
        // into download-associated subtitles after recycle-bin restore.
        vid.recycledAdditionalSubtitles = vid.additionalSubtitles == null
            ? null
            : Map<String, String>.from(vid.additionalSubtitles!);
        vid.recycledLocalSubtitles = vid.localSubtitles == null
            ? null
            : Map<String, String>.from(vid.localSubtitles!);
        if (!vid.isBilibiliExported &&
            await _isBilibiliExportedCandidate(vid)) {
          vid.isBilibiliExported = true;
        }
        vid.isRecycled = true;
        vid.recycleTime = now;
        parentId = vid.parentId;
      }

      // Remove from parent's children list so counts update immediately
      if (parentId != null && _collections.containsKey(parentId)) {
        _collections[parentId]!.childrenIds.remove(id);
      } else if (parentId == null) {
        _rootChildrenIds.remove(id);
      }
    }
    await _saveLibrary();
    notifyListeners();
  }

  Future<void> restoreFromRecycleBin(List<String> ids) async {
    _invalidateSizeCaches();
    for (var id in ids) {
      String? parentId;
      bool isItemCollection = false;

      if (_collections.containsKey(id)) {
        final col = _collections[id]!;
        col.isRecycled = false;
        col.recycleTime = null;
        parentId = col.parentId;
        isItemCollection = true;
      } else if (_videos.containsKey(id)) {
        final vid = _videos[id]!;
        vid.isRecycled = false;
        vid.recycleTime = null;
        if (vid.recycledSelectedSubtitlePaths != null) {
          final paths = vid.recycledSelectedSubtitlePaths!;
          vid.subtitlePath = paths.isNotEmpty ? paths[0] : null;
          vid.secondarySubtitlePath = paths.length > 1 ? paths[1] : null;
          vid.recycledSelectedSubtitlePaths = null;
        }
        if (vid.recycledAdditionalSubtitles != null &&
            vid.recycledAdditionalSubtitles!.isNotEmpty) {
          vid.additionalSubtitles = Map<String, String>.from(
            vid.recycledAdditionalSubtitles!,
          );
          vid.recycledAdditionalSubtitles = null;
        }
        if (vid.recycledLocalSubtitles != null) {
          vid.localSubtitles = Map<String, String>.from(
            vid.recycledLocalSubtitles!,
          );
          vid.recycledLocalSubtitles = null;
        }
        parentId = vid.parentId;
      } else {
        continue;
      }

      // Check if parent is valid (exists and is NOT recycled)
      // If parent is missing or recycled, move to root to ensure visibility
      bool parentIsValid = false;
      if (parentId != null && _collections.containsKey(parentId)) {
        if (!_collections[parentId]!.isRecycled) {
          parentIsValid = true;
        }
      } else if (parentId == null) {
        parentIsValid = true; // Already at root
      }

      if (!parentIsValid) {
        // Move to root
        // 1. Update item's parentId
        if (isItemCollection) {
          _collections[id]!.parentId = null;
        } else {
          _videos[id]!.parentId = null;
        }

        // 2. Add to rootChildrenIds
        if (!_rootChildrenIds.contains(id)) {
          _rootChildrenIds.add(id);
        }
      } else {
        // Parent is valid, add back to parent's childrenIds
        if (parentId != null) {
          if (!_collections[parentId]!.childrenIds.contains(id)) {
            _collections[parentId]!.childrenIds.add(id);
          }
        } else {
          if (!_rootChildrenIds.contains(id)) {
            _rootChildrenIds.add(id);
          }
        }
      }
    }
    await _saveLibrary();
    notifyListeners();
  }

  Future<void> deleteFromRecycleBin(List<String> ids) async {
    _invalidateSizeCaches();
    for (var id in ids) {
      if (_collections.containsKey(id)) {
        await _deleteCollectionFilesRecursive(id);
        _deleteCollectionRecursive(id);
      } else if (_videos.containsKey(id)) {
        final vid = _videos[id];
        if (vid != null) await _deleteVideoFiles(vid);
        _deleteVideo(id);
      }
    }
    await _saveLibrary();
    notifyListeners();
  }

  Future<void> _deleteCollectionFilesRecursive(String id) async {
    final col = _collections[id];
    if (col == null) return;

    ThumbnailCacheService().evictFromCache(id);
    if (col.thumbnailPath != null &&
        col.thumbnailPath!.isNotEmpty &&
        p.isWithin(_dataRootDir.path, col.thumbnailPath!)) {
      try {
        final file = File(col.thumbnailPath!);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        developer.log('Error deleting collection thumbnail', error: e);
      }
    }

    for (var childId in col.childrenIds) {
      if (_collections.containsKey(childId)) {
        await _deleteCollectionFilesRecursive(childId);
      } else if (_videos.containsKey(childId)) {
        final vid = _videos[childId];
        if (vid != null) await _deleteVideoFiles(vid);
      }
    }
  }

  Future<void> _deleteVideoFiles(VideoItem vid) async {
    // Online playback has no media file at [vid.path]. Its complete cache is
    // owned by the card id and must be removed with the card itself.
    if (_isBilibiliStreamItem(vid)) {
      try {
        final streaming = _bilibiliStreamingService;
        if (streaming != null) {
          await streaming.clearCacheForItem(vid.id);
        } else {
          await BilibiliStreamingService.clearCacheForItemOnDisk(vid.id);
        }
      } catch (e) {
        developer.log('Error deleting Bilibili stream cache', error: e);
      }
    }

    // 清理缩略图缓存
    ThumbnailCacheService().evictFromCache(vid.id);

    // Managed compatibility copies live with the library until permanent
    // deletion (moving to the recycle bin intentionally keeps them).
    if (vid.playbackPath != null && _isInternalPath(vid.playbackPath!)) {
      try {
        final referencedElsewhere = _videos.values.any(
          (item) =>
              item.id != vid.id &&
              item.playbackPath != null &&
              _samePath(item.playbackPath!, vid.playbackPath!),
        );
        final file = File(vid.playbackPath!);
        if (!referencedElsewhere && await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        developer.log('Error deleting compatible playback file', error: e);
      }
    }

    // 1. Delete Thumbnail
    if (vid.thumbnailPath != null) {
      try {
        final file = File(vid.thumbnailPath!);
        if (await file.exists() &&
            !_isThumbnailPathReferencedByOtherVideo(
              vid.thumbnailPath!,
              vid.id,
            )) {
          await file.delete();
        }
      } catch (e) {
        developer.log('Error deleting thumbnail', error: e);
      }
    }

    // 2. Delete only this card's task-owned subtitles. Archive sidecars are
    // adopted here during import; sidecars next to external media stay external
    // and are never card-owned.
    try {
      final storage = TaskSubtitleStorageService(
        dataRootOverride: _dataRootDir,
      );
      await storage.deleteTaskDirectory(vid.id);
      final danmakuPath = vid.danmakuPath;
      if (danmakuPath != null && _isInternalPath(danmakuPath)) {
        final file = File(danmakuPath);
        if (await file.exists() &&
            !_subtitleReferencesContainPathInOtherVideo(danmakuPath, vid.id)) {
          await file.delete();
        }
      }
    } catch (e) {
      developer.log('Error deleting subtitles', error: e);
    }

    try {
      await ChapterThumbnailService.instance.deleteForVideo(vid.id);
    } catch (e) {
      developer.log('Error deleting chapter thumbnails', error: e);
    }

    try {
      await BilibiliVideoShotService.instance.deleteForVideo(
        vid.id,
        dataRootOverride: _dataRootDir,
      );
    } catch (e) {
      developer.log('Error deleting Bilibili video-shot sprites', error: e);
    }

    // OCR frames are disposable working data and never participate in task
    // recovery. Permanently deleting a video card must also remove any frames
    // left by an interrupted or crashed OCR job for that video.
    try {
      final safeVideoId = vid.id.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final ocrTemp = Directory(
        p.join(_dataRootDir.path, 'ocr_temp', safeVideoId),
      );
      if (await ocrTemp.exists()) await ocrTemp.delete(recursive: true);
    } catch (e) {
      developer.log('Error deleting OCR temporary frames', error: e);
    }

    // 3. Delete Video File (Only if it's inside app storage). Online cards use
    // a URI marker, so their card-owned cache was handled above and must never
    // be passed through local-file cleanup.
    if (!_isBilibiliStreamItem(vid)) {
      try {
        bool shouldDelete = await _isBilibiliExportedCandidate(vid);

        // Check 1: Internal Doc Dir (App Data)
        if (p.isWithin(_dataRootDir.path, vid.path)) {
          shouldDelete = true;
        }

        // Check 2: Internal Temp Dir (Cache)
        if (!shouldDelete) {
          final tempDir = await getTemporaryDirectory();
          if (p.isWithin(tempDir.path, vid.path)) shouldDelete = true;
        }

        // Check 3: Android External Storage (Android/data/pkg/files & cache)
        if (!shouldDelete && Platform.isAndroid) {
          // External Files
          final extDir = await getExternalStorageDirectory();
          if (extDir != null && p.isWithin(extDir.path, vid.path)) {
            shouldDelete = true;
          }

          // External Caches
          if (!shouldDelete) {
            final extCacheDirs = await getExternalCacheDirectories();
            if (extCacheDirs != null) {
              for (var dir in extCacheDirs) {
                if (p.isWithin(dir.path, vid.path)) {
                  shouldDelete = true;
                  break;
                }
              }
            }
          }

          // Check 4: Bilibili Download Directory (User Request)
          // Allow deleting files in Bilibili download directory (e.g., merged files we created)
          if (!shouldDelete && vid.path.contains("tv.danmaku.bili")) {
            shouldDelete = true;
          }
        }

        if (shouldDelete) {
          final file = File(vid.path);
          if (await file.exists() &&
              !_isMediaFilePathReferencedByOtherVideo(vid.path, vid.id)) {
            await file.delete();
            debugPrint("Deleted internal video file: ${vid.path}");
          }
        }
      } catch (e) {
        debugPrint("Error deleting internal video: $e");
      }
    }
  }

  void _deleteCollectionRecursive(String id) {
    final col = _collections[id];
    if (col == null) return;

    // Delete children
    for (var childId in List<String>.from(col.childrenIds)) {
      if (_collections.containsKey(childId)) {
        _deleteCollectionRecursive(childId);
      } else {
        _deleteVideo(childId);
      }
    }

    // Remove from parent
    if (col.parentId != null && _collections.containsKey(col.parentId)) {
      _collections[col.parentId]!.childrenIds.remove(id);
    } else if (col.parentId == null) {
      _rootChildrenIds.remove(id);
    }

    _collections.remove(id);
  }

  void _deleteVideo(String id) {
    final vid = _videos[id];
    if (vid == null) return;

    if (vid.parentId != null && _collections.containsKey(vid.parentId)) {
      _collections[vid.parentId]!.childrenIds.remove(id);
    } else if (vid.parentId == null) {
      _rootChildrenIds.remove(id);
    }
    _videos.remove(id);
  }

  // Move item to another collection (or root if targetCollectionId is null)
  Future<void> moveItemToCollection(
    String itemId,
    String? targetCollectionId,
  ) async {
    if (itemId == targetCollectionId) return;

    // 1. Identify Item
    VideoCollection? col;
    VideoItem? vid;
    String? currentParentId;

    if (_collections.containsKey(itemId)) {
      col = _collections[itemId];
      currentParentId = col!.parentId;

      // Cycle Check: Cannot move a folder into itself or its descendants
      if (targetCollectionId != null &&
          _isDescendant(targetCollectionId, itemId)) {
        return; // Invalid move
      }
    } else if (_videos.containsKey(itemId)) {
      vid = _videos[itemId];
      currentParentId = vid!.parentId;
    } else {
      return; // Item not found
    }

    // Check if already in target
    if (currentParentId == targetCollectionId) return;

    // 2. Remove from old location
    if (currentParentId != null && _collections.containsKey(currentParentId)) {
      _collections[currentParentId]!.childrenIds.remove(itemId);
    } else if (currentParentId == null) {
      _rootChildrenIds.remove(itemId);
    }

    // 3. Add to new location
    if (targetCollectionId != null &&
        _collections.containsKey(targetCollectionId)) {
      final target = _collections[targetCollectionId]!;
      if (!target.childrenIds.contains(itemId)) {
        target.childrenIds.add(itemId);
      }
      // Update item parent pointer
      if (col != null) col.parentId = targetCollectionId;
      if (vid != null) vid.parentId = targetCollectionId;
    } else if (targetCollectionId == null) {
      // Move to Root
      if (!_rootChildrenIds.contains(itemId)) {
        _rootChildrenIds.add(itemId);
      }
      // Update item parent pointer
      if (col != null) col.parentId = null;
      if (vid != null) vid.parentId = null;
    }

    await _saveLibrary();
    notifyListeners();
  }

  // Batch Move
  Future<void> moveItemsToCollection(
    List<String> itemIds,
    String? targetCollectionId,
  ) async {
    bool changed = false;
    for (var itemId in itemIds) {
      if (itemId == targetCollectionId) continue;

      // 1. Identify Item
      VideoCollection? col;
      VideoItem? vid;
      String? currentParentId;

      if (_collections.containsKey(itemId)) {
        col = _collections[itemId];
        currentParentId = col!.parentId;
        // Cycle Check
        if (targetCollectionId != null &&
            _isDescendant(targetCollectionId, itemId)) {
          continue;
        }
      } else if (_videos.containsKey(itemId)) {
        vid = _videos[itemId];
        currentParentId = vid!.parentId;
      } else {
        continue;
      }

      if (currentParentId == targetCollectionId) continue;

      // 2. Remove
      if (currentParentId != null &&
          _collections.containsKey(currentParentId)) {
        _collections[currentParentId]!.childrenIds.remove(itemId);
      } else if (currentParentId == null) {
        _rootChildrenIds.remove(itemId);
      }

      // 3. Add
      if (targetCollectionId != null &&
          _collections.containsKey(targetCollectionId)) {
        final target = _collections[targetCollectionId]!;
        if (!target.childrenIds.contains(itemId)) {
          target.childrenIds.add(itemId);
        }
        if (col != null) col.parentId = targetCollectionId;
        if (vid != null) vid.parentId = targetCollectionId;
      } else if (targetCollectionId == null) {
        if (!_rootChildrenIds.contains(itemId)) {
          _rootChildrenIds.add(itemId);
        }
        if (col != null) col.parentId = null;
        if (vid != null) vid.parentId = null;
      }
      changed = true;
    }

    if (changed) {
      await _saveLibrary();
      notifyListeners();
    }
  }

  bool _isDescendant(String potentialDescendantId, String ancestorId) {
    if (potentialDescendantId == ancestorId) return true;

    final col = _collections[potentialDescendantId];
    if (col == null) {
      return false; // Should not happen if ID is valid collection
    }
    if (col.parentId == null) return false;

    return _isDescendant(col.parentId!, ancestorId);
  }

  // Reorder (Only for manual ordering within a parent)
  Future<void> reorderItems(
    String? parentId,
    int oldIndex,
    int newIndex,
  ) async {
    if (oldIndex == newIndex) return;

    // Logic:
    // 1. Get visible items using getContents(parentId) logic.
    // 2. Identify the item being moved (itemToMove).
    // 3. Identify the target insert position.

    // Step 1: Visible Items
    final visibleItems = getContents(parentId);
    if (oldIndex >= visibleItems.length || newIndex >= visibleItems.length) {
      return;
    }

    final itemToMove = visibleItems[oldIndex];
    final String itemToMoveId = (itemToMove as dynamic).id;

    // Step 2: Determine Insert Before ID
    // If moving down (old < new), we usually want to place AFTER the target.
    // If moving up (old > new), we usually want to place BEFORE the target.

    int targetLookupIndex;
    if (oldIndex < newIndex) {
      targetLookupIndex = newIndex + 1;
    } else {
      targetLookupIndex = newIndex;
    }

    String? insertBeforeId; // If null, insert at end
    if (targetLookupIndex < visibleItems.length) {
      final itemAfter = visibleItems[targetLookupIndex];
      insertBeforeId = (itemAfter as dynamic).id;
    }

    // Master List Reference
    List<String> masterList;
    if (parentId == null) {
      masterList = _rootChildrenIds;
    } else {
      final parent = _collections[parentId];
      if (parent == null) return;
      masterList = parent.childrenIds;
    }

    // Step 3: Remove
    final originalIndex = masterList.indexOf(itemToMoveId);
    if (originalIndex == -1) return;
    masterList.removeAt(originalIndex);

    // Step 4: Insert
    if (insertBeforeId == null) {
      masterList.add(itemToMoveId);
    } else {
      int targetIndex = masterList.indexOf(insertBeforeId);
      if (targetIndex == -1) {
        masterList.add(itemToMoveId);
      } else {
        masterList.insert(targetIndex, itemToMoveId);
      }
    }

    await _saveLibrary();
    notifyListeners();
  }

  // Batch Reorder
  // draggedItemIndex: the index of the item the user is actively dragging
  // targetIndex: the index of the drop target
  Future<void> reorderMultipleItems(
    String? parentId,
    List<String> itemIds,
    int draggedItemIndex,
    int targetIndex,
  ) async {
    if (itemIds.isEmpty) return;

    // 1. Get Visible Items
    final visibleItems = getContents(parentId);

    // 2. Identify Target Insert Position
    // We use the same logic as single reorder:
    // If dragging down (draggedItemIndex < targetIndex), insert AFTER target.
    // If dragging up (draggedItemIndex > targetIndex), insert BEFORE target.

    int targetLookupIndex;
    if (draggedItemIndex < targetIndex) {
      targetLookupIndex = targetIndex + 1;
    } else {
      targetLookupIndex = targetIndex;
    }

    String? insertBeforeId;
    if (targetLookupIndex < visibleItems.length) {
      final itemAfter = visibleItems[targetLookupIndex];
      insertBeforeId = (itemAfter as dynamic).id;
    }

    // Master List Reference
    List<String> masterList;
    if (parentId == null) {
      masterList = _rootChildrenIds;
    } else {
      final parent = _collections[parentId];
      if (parent == null) return;
      masterList = parent.childrenIds;
    }

    // 3. Remove ALL items to be moved
    // We must do this carefully. If we remove items, the indices change.
    // But we are using `insertBeforeId` which is stable (unless it's one of the moving items).
    // If `insertBeforeId` is one of the moving items, our target logic is flawed.
    // However, in a valid drag, you don't drag a selection onto itself.
    // But targetLookupIndex logic might pick a moving item if it's adjacent.

    // Optimization: If we are dragging a block [A, B] and dropping on C.
    // We want to insert [A, B] relative to C.
    // C should not be in itemIds.

    // Filter out itemIds from masterList
    masterList.removeWhere((id) => itemIds.contains(id));

    // 4. Insert
    if (insertBeforeId == null) {
      masterList.addAll(itemIds);
    } else {
      // Find where to insert
      // Note: insertBeforeId might have been removed if it was in itemIds?
      // No, because we can't drag onto a selected item (usually).
      // But if we selected A and B, and dragged A onto B... well, that's a no-op.

      int insertIndex = masterList.indexOf(insertBeforeId);
      if (insertIndex == -1) {
        // Fallback: append
        masterList.addAll(itemIds);
      } else {
        masterList.insertAll(insertIndex, itemIds);
      }
    }

    await _saveLibrary();
    notifyListeners();
  }

  Future<String?> _generateThumbnail(
    String videoPath, {
    String? videoId,
  }) async {
    // Audio: extract embedded cover art (album art)
    if (_detectMediaType(videoPath) == MediaType.audio) {
      return await _extractAudioCoverArt(videoPath, videoId: videoId);
    }

    // Windows Specific Implementation
    if (Platform.isWindows) {
      return await _generateThumbnailWindows(videoPath, videoId: videoId);
    }

    // iOS: Use FFmpeg for better compatibility with gallery videos
    if (Platform.isIOS) {
      return await _generateThumbnailFFmpeg(videoPath, videoId: videoId);
    }

    // Android and other platforms: use the system thumbnail path first. Some
    // Android MediaMetadataRetriever implementations advertise AV1 support but
    // fail while extracting a 4K frame, so Android gets a software FFmpeg
    // fallback below.
    try {
      final thumbDir = Directory(p.join(_dataRootDir.path, 'thumbnails'));
      if (!await thumbDir.exists()) {
        await thumbDir.create(recursive: true);
      }

      final outPath = _thumbnailOutputPath(videoPath, videoId: videoId);
      final outFile = File(outPath);
      if (await outFile.exists() && await outFile.length() > 0) {
        return outPath;
      }

      final tempPath = await VideoThumbnail.thumbnailFile(
        video: videoPath,
        thumbnailPath: thumbDir.path,
        imageFormat: ImageFormat.JPEG,
        maxHeight: 200, // Optimize size
        quality: 75,
      );
      if (tempPath == null) {
        if (Platform.isAndroid) {
          return await _generateThumbnailFFmpeg(videoPath, videoId: videoId);
        }
        return null;
      }

      final tempFile = File(tempPath);
      if (!await tempFile.exists() || await tempFile.length() <= 0) {
        if (Platform.isAndroid) {
          return await _generateThumbnailFFmpeg(videoPath, videoId: videoId);
        }
        return null;
      }

      if (!_samePath(tempPath, outPath)) {
        await tempFile.copy(outPath);
        try {
          await tempFile.delete();
        } catch (_) {}
      }
      return outPath;
    } catch (e) {
      developer.log('Thumbnail error', error: e);
      if (Platform.isAndroid) {
        return await _generateThumbnailFFmpeg(videoPath, videoId: videoId);
      }
      return null;
    }
  }

  /// 使用 FFmpeg 生成缩略图（用于 iOS 和其他平台）
  Future<FFmpegSession?> _executeFfmpegWithTimeout(
    List<String> arguments,
    Duration timeout,
  ) async {
    final completer = Completer<FFmpegSession>();
    FFmpegSession? runningSession;
    var timedOut = false;
    runningSession = await FFmpegKit.executeWithArgumentsAsync(arguments, (
      session,
    ) {
      if (!timedOut && !completer.isCompleted) {
        completer.complete(session);
      }
    });
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      timedOut = true;
      try {
        await runningSession.cancel();
      } catch (_) {}
      developer.log(
        'FFmpeg task timed out after ${timeout.inSeconds}s',
        name: 'library.ffmpeg',
      );
      return null;
    }
  }

  Future<String?> _generateThumbnailFFmpeg(
    String videoPath, {
    String? videoId,
  }) async {
    try {
      final thumbDir = Directory(p.join(_dataRootDir.path, 'thumbnails'));
      if (!await thumbDir.exists()) {
        await thumbDir.create(recursive: true);
      }

      final outPath = _thumbnailOutputPath(videoPath, videoId: videoId);

      // Check if thumbnail already exists
      final outFile = File(outPath);
      if (await outFile.exists() && await outFile.length() > 0) {
        return outPath;
      }

      // Use FFmpeg to extract first frame
      // -y: Overwrite output file
      // -i: Input file
      // -ss 00:00:01: Seek to 1 second (avoid black frames at start)
      // -vframes 1: Extract only 1 frame
      // -vf scale=-1:200: Resize to height 200px maintaining aspect ratio
      // -q:v 2: High quality JPEG
      final session = await _executeFfmpegWithTimeout(<String>[
        '-y',
        '-i',
        videoPath,
        '-ss',
        '00:00:01',
        '-vframes',
        '1',
        '-vf',
        'scale=-1:200',
        '-q:v',
        '2',
        outPath,
      ], const Duration(seconds: 30));

      final returnCode = await session?.getReturnCode();

      if (ReturnCode.isSuccess(returnCode)) {
        if (await outFile.exists() && await outFile.length() > 0) {
          developer.log('FFmpeg thumbnail generated: $outPath');
          return outPath;
        }
      }

      // If failed, try without seek (some videos might be very short)
      final session2 = await _executeFfmpegWithTimeout(<String>[
        '-y',
        '-i',
        videoPath,
        '-vframes',
        '1',
        '-vf',
        'scale=-1:200',
        '-q:v',
        '2',
        outPath,
      ], const Duration(seconds: 20));

      final returnCode2 = await session2?.getReturnCode();

      if (ReturnCode.isSuccess(returnCode2)) {
        if (await outFile.exists() && await outFile.length() > 0) {
          developer.log('FFmpeg thumbnail generated (fallback): $outPath');
          return outPath;
        }
      }

      developer.log('FFmpeg thumbnail generation failed for: $videoPath');
      return null;
    } catch (e) {
      developer.log('FFmpeg thumbnail error', error: e);
      return null;
    }
  }

  /// 提取音频文件的嵌入式封面图（专辑封面）。
  /// 使用 FFmpegKit 提取音频中嵌入的图片流。
  Future<String?> _extractAudioCoverArt(
    String audioPath, {
    String? videoId,
  }) async {
    try {
      final thumbDir = Directory(p.join(_dataRootDir.path, 'thumbnails'));
      if (!await thumbDir.exists()) {
        await thumbDir.create(recursive: true);
      }

      final outPath = _thumbnailOutputPath(audioPath, videoId: videoId);
      final outFile = File(outPath);
      if (await outFile.exists() && await outFile.length() > 0) {
        return outPath;
      }

      // FFmpegKit: extract embedded artwork (attached picture stream)
      // -map 0:v selects video streams (includes attached pictures)
      // -map -0:V excludes "real" video streams (leaving attached pictures only)
      // -vframes 1: extract one frame
      // -q:v 2: high quality JPEG
      final session = await _executeFfmpegWithTimeout(<String>[
        '-y',
        '-i',
        audioPath,
        '-map',
        '0:v:0?',
        '-frames:v',
        '1',
        '-c:v',
        'mjpeg',
        '-q:v',
        '2',
        outPath,
      ], const Duration(seconds: 20));

      final returnCode = await session?.getReturnCode();
      if (ReturnCode.isSuccess(returnCode)) {
        if (await outFile.exists() && await outFile.length() > 0) {
          developer.log('Audio cover art extracted: $outPath');
          return outPath;
        }
      }

      // Fallback: try extracting any first video frame
      final session2 = await _executeFfmpegWithTimeout(<String>[
        '-y',
        '-i',
        audioPath,
        '-map',
        '0:v:0?',
        '-frames:v',
        '1',
        outPath,
      ], const Duration(seconds: 20));
      final returnCode2 = await session2?.getReturnCode();
      if (ReturnCode.isSuccess(returnCode2)) {
        if (await outFile.exists() && await outFile.length() > 0) {
          developer.log('Audio cover art extracted (fallback): $outPath');
          return outPath;
        }
      }

      return null;
    } catch (e) {
      developer.log('Audio cover art extraction error', error: e);
      return null;
    }
  }

  Future<int?> _runCliProcessWithTimeout(
    String executable,
    List<String> arguments,
    Duration timeout,
  ) async {
    final process = await Process.start(executable, arguments);
    final stdoutDrain = process.stdout.drain<void>();
    final stderrDrain = process.stderr.drain<void>();
    try {
      final exitCode = await process.exitCode.timeout(timeout);
      await Future.wait<void>([stdoutDrain, stderrDrain]);
      return exitCode;
    } on TimeoutException {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {}
      try {
        await Future.wait<void>([
          stdoutDrain.timeout(const Duration(seconds: 1)),
          stderrDrain.timeout(const Duration(seconds: 1)),
        ]);
      } catch (_) {}
      return null;
    }
  }

  Future<String?> _generateThumbnailWindows(
    String videoPath, {
    String? videoId,
  }) async {
    try {
      final ffmpegPath =
          await YtDlpBinaryInstaller.resolveInstalledBinaryPath('ffmpeg.exe') ??
          p.join(p.dirname(Platform.resolvedExecutable), 'ffmpeg.exe');
      if (!await File(ffmpegPath).exists()) {
        developer.log("FFmpeg not found at $ffmpegPath");
        return null;
      }

      final thumbDir = Directory(p.join(_dataRootDir.path, 'thumbnails'));
      if (!await thumbDir.exists()) await thumbDir.create(recursive: true);

      final outPath = _thumbnailOutputPath(videoPath, videoId: videoId);

      // 1. Try to extract embedded cover art
      // -map 0:v selects all video streams
      // -map -0:V excludes "real" video streams (leaving attached pictures)
      try {
        await _runCliProcessWithTimeout(ffmpegPath, [
          '-y',
          '-i',
          videoPath,
          '-map',
          '0:v',
          '-map',
          '-0:V',
          '-c',
          'copy',
          outPath,
        ], const Duration(seconds: 5));

        if (await File(outPath).exists() && await File(outPath).length() > 0) {
          return outPath;
        }
      } catch (e) {
        // Continue to fallback
      }

      // 2. Fallback: Extract first frame
      await _runCliProcessWithTimeout(ffmpegPath, [
        '-y',
        '-i',
        videoPath,
        '-ss',
        '0',
        '-vframes',
        '1',
        '-vf',
        'scale=-1:200', // Resize to height 200px to optimize speed and size
        '-q:v',
        '2', // High quality JPEG
        outPath,
      ], const Duration(seconds: 15));

      if (await File(outPath).exists() && await File(outPath).length() > 0) {
        return outPath;
      }
    } catch (e) {
      developer.log('Windows Thumbnail error', error: e);
    }
    return null;
  }

  bool _requiresWindowsThumbnailRepair(String? thumbnailPath) {
    if (!Platform.isWindows) {
      return false;
    }
    final normalized = thumbnailPath?.trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) {
      return false;
    }
    return normalized.endsWith('.webp');
  }

  Future<int> _probeMediaDurationMs(String mediaPath) async {
    // Bulk imports avoid constructing a VideoPlayerController per file. The
    // native probe has its own cancellation and this outer timeout is a final
    // guard against plugin/channel failures.
    try {
      return await MediaDurationProbe.probeDurationMs(
        mediaPath,
        allowVideoPlayerFallback: false,
      ).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          developer.log('媒体时长探测超时: $mediaPath', name: 'library.duration_probe');
          return 0;
        },
      );
    } catch (e) {
      developer.log(
        '媒体时长探测失败: $mediaPath',
        error: e,
        name: 'library.duration_probe',
      );
      return 0;
    }
  }

  /// Lightweight progress update: only updates in-memory value and schedules
  /// a debounced save. Does NOT trigger notifyListeners or full serialization
  /// on every call, which was the primary cause of UI jank during playback.
  Future<void> updateVideoProgress(String id, int positionMs) async {
    final item = _videos[id];
    if (item != null) {
      item.lastPositionMs = positionMs;
      item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
      _scheduleDebouncedSave();
    }
  }

  /// Lightweight duration update: only updates in-memory value and schedules
  /// a debounced save. Does NOT trigger notifyListeners on every call.
  Future<void> updateVideoDuration(String id, int durationMs) async {
    final item = _videos[id];
    if (item != null && item.durationMs != durationMs) {
      item.durationMs = durationMs;
      _scheduleDebouncedSave();
    }
  }

  Future<void> saveProgress() async {
    await _saveLibrary();
  }

  /// Persists the stable sidecar location before a danmaku refresh starts.
  /// A missing file at this path is harmless and lets an interrupted refresh
  /// retry without leaving an unreferenced sidecar behind.
  Future<bool> updateVideoDanmakuPath(
    String videoId,
    String danmakuPath,
  ) async {
    final item = _videos[videoId];
    if (item == null) return false;
    if (item.danmakuPath == danmakuPath) return true;
    item.danmakuPath = danmakuPath;
    item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
    await _saveLibrary();
    notifyListeners();
    return true;
  }

  Future<void> updateVideoSubtitles(
    String videoId,
    String? subtitlePath,
    bool isCached, {
    String? secondarySubtitlePath,
    bool isSecondaryCached = false,
  }) async {
    final item = _videos[videoId];
    if (item != null) {
      final oldPrimaryPath = item.subtitlePath;
      final oldSecondaryPath = item.secondarySubtitlePath;
      final oldPrimaryWasCached = item.isSubtitleCached;
      final oldSecondaryWasCached = item.isSecondarySubtitleCached;
      final shouldCachePrimary =
          subtitlePath != null &&
          isCached &&
          await _shouldCacheSubtitleByCopy(subtitlePath);
      final shouldCacheSecondary =
          secondarySubtitlePath != null &&
          isSecondaryCached &&
          await _shouldCacheSubtitleByCopy(secondarySubtitlePath);
      final storage = TaskSubtitleStorageService(
        dataRootOverride: _dataRootDir,
      );
      final subDir = await storage.taskDirectory(
        videoId,
        create: shouldCachePrimary || shouldCacheSecondary,
      );
      if ((shouldCachePrimary || shouldCacheSecondary) &&
          !await subDir.exists()) {
        await subDir.create(recursive: true);
      }

      // 1. Process Primary Subtitle
      if (subtitlePath != null) {
        String finalPath = subtitlePath;
        var cachedPrimary = false;
        if (shouldCachePrimary) {
          final ext = p.extension(subtitlePath);
          // Use _main suffix to avoid collision with secondary if same extension
          final newFileName = "main$ext";
          final newPath = p.join(subDir.path, newFileName);

          if (subtitlePath != newPath) {
            try {
              await File(subtitlePath).copy(newPath);
              finalPath = newPath;
              cachedPrimary = true;
              _upsertManagedSubtitleAssetInMemory(
                item,
                finalPath,
                ManagedSubtitleAssetKind.cached,
                '主字幕缓存',
              );
            } catch (e) {
              developer.log('Error copying primary subtitle', error: e);
            }
          } else {
            cachedPrimary = true;
          }
        }
        item.subtitlePath = finalPath;
        item.isSubtitleCached = cachedPrimary;
      } else {
        // If null passed (cleared), clear it
        item.subtitlePath = null;
        item.isSubtitleCached = false;
      }

      // 2. Process Secondary Subtitle
      if (secondarySubtitlePath != null) {
        String finalSecPath = secondarySubtitlePath;
        var cachedSecondary = false;
        if (shouldCacheSecondary) {
          final ext = p.extension(secondarySubtitlePath);
          final newFileName = "secondary$ext";
          final newPath = p.join(subDir.path, newFileName);

          if (secondarySubtitlePath != newPath) {
            try {
              await File(secondarySubtitlePath).copy(newPath);
              finalSecPath = newPath;
              cachedSecondary = true;
              _upsertManagedSubtitleAssetInMemory(
                item,
                finalSecPath,
                ManagedSubtitleAssetKind.cached,
                '副字幕缓存',
              );
            } catch (e) {
              developer.log('Error copying secondary subtitle', error: e);
            }
          } else {
            cachedSecondary = true;
          }
        }
        item.secondarySubtitlePath = finalSecPath;
        item.isSecondarySubtitleCached = cachedSecondary;
      } else {
        // If null passed (cleared), clear it
        item.secondarySubtitlePath = null;
        item.isSecondarySubtitleCached = false;
      }

      if (item.isRecycled) {
        final paths = <String>[];
        if (item.subtitlePath != null) {
          paths.add(item.subtitlePath!);
        }
        if (item.secondarySubtitlePath != null) {
          paths.add(item.secondarySubtitlePath!);
        }
        item.recycledSelectedSubtitlePaths = paths;
      }
      item.blockAutoAssociatedSubtitleSelection =
          item.subtitlePath == null && item.secondarySubtitlePath == null;

      await _deleteReplacedManagedSubtitleCache(
        oldPrimaryPath,
        videoId: videoId,
        wasCached: oldPrimaryWasCached,
        currentItem: item,
      );
      await _deleteReplacedManagedSubtitleCache(
        oldSecondaryPath,
        videoId: videoId,
        wasCached: oldSecondaryWasCached,
        currentItem: item,
      );

      _invalidateVideoSizeCache(videoId);
      await _saveLibrary();
    }
  }

  Future<void> _deleteReplacedManagedSubtitleCache(
    String? oldPath, {
    required String videoId,
    required bool wasCached,
    required VideoItem currentItem,
  }) async {
    if (!wasCached || oldPath == null || oldPath.isEmpty) return;
    if (_subtitleReferencesContainPath(currentItem, oldPath)) return;
    final storage = TaskSubtitleStorageService(dataRootOverride: _dataRootDir);
    if (!await storage.isTaskOwnedPath(oldPath, videoId)) return;
    try {
      final file = File(oldPath);
      if (await file.exists()) await file.delete();
      currentItem.managedSubtitleAssets = currentItem.managedSubtitleAssets
          .where((asset) => !_samePath(asset.path, oldPath))
          .toList(growable: false);
    } catch (error) {
      developer.log('Error deleting replaced subtitle cache', error: error);
    }
  }

  void _upsertManagedSubtitleAssetInMemory(
    VideoItem item,
    String path,
    ManagedSubtitleAssetKind kind,
    String displayName, {
    String? sourceAssetId,
    String? language,
  }) {
    if (item.managedSubtitleAssets.any(
      (asset) => _samePath(asset.path, path),
    )) {
      return;
    }
    item.managedSubtitleAssets = <ManagedSubtitleAsset>[
      ...item.managedSubtitleAssets,
      ManagedSubtitleAsset(
        assetId: const Uuid().v4(),
        path: p.normalize(path),
        kind: kind,
        displayName: displayName,
        sourceAssetId: sourceAssetId,
        language: language,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    ];
  }

  Future<bool> _shouldCacheSubtitleByCopy(String subtitlePath) async {
    if (subtitlePath.isEmpty) return false;
    try {
      if (_initialized && p.isWithin(_dataRootDir.path, subtitlePath)) {
        return false;
      }
      final tempDir = await getTemporaryDirectory();
      if (p.isWithin(tempDir.path, subtitlePath)) {
        return true;
      }
      if (Platform.isAndroid) {
        final extCacheDirs = await getExternalCacheDirectories();
        if (extCacheDirs != null) {
          for (final dir in extCacheDirs) {
            if (p.isWithin(dir.path, subtitlePath)) {
              return true;
            }
          }
        }
      }
    } catch (_) {}
    return false;
  }

  Future<void> updateVideoAdditionalSubtitles(
    String videoId,
    Map<String, String>? additionalSubtitles,
  ) async {
    final item = _videos[videoId];
    if (item != null) {
      item.additionalSubtitles = await _adoptSubtitleMapIntoTask(
        item,
        additionalSubtitles,
        ManagedSubtitleAssetKind.downloaded,
      );
      item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
      _invalidateVideoSizeCache(videoId);
      await _saveLibrary();
      notifyListeners();
    }
  }

  Future<void> updateVideoLocalSubtitles(
    String videoId,
    Map<String, String>? localSubtitles,
  ) async {
    final item = _videos[videoId];
    if (item != null) {
      item.localSubtitles = await _adoptSubtitleMapIntoTask(
        item,
        localSubtitles,
        ManagedSubtitleAssetKind.imported,
      );
      item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
      _invalidateVideoSizeCache(videoId);
      await _saveLibrary();
      notifyListeners();
    }
  }

  Future<Map<String, String>?> _adoptSubtitleMapIntoTask(
    VideoItem item,
    Map<String, String>? subtitles,
    ManagedSubtitleAssetKind kind,
  ) async {
    if (subtitles == null) return null;
    if (subtitles.isEmpty) return <String, String>{};
    final storage = TaskSubtitleStorageService(dataRootOverride: _dataRootDir);
    final adoptedBySource = <String, String>{};
    final result = <String, String>{};
    for (final entry in subtitles.entries) {
      final sourcePath = entry.value;
      var ownedPath = sourcePath;
      try {
        final alreadyOwned = await storage.isTaskOwnedPath(sourcePath, item.id);
        if (!alreadyOwned) {
          final sourceKey = _normalizeCachePath(sourcePath);
          ownedPath =
              adoptedBySource[sourceKey] ??
              await storage.copyIntoTask(
                item.id,
                sourcePath,
                preferredFileName: p.basename(sourcePath),
              );
          adoptedBySource[sourceKey] = ownedPath;
          _replaceSubtitleReferences(item, sourcePath, ownedPath);
        }
        if (!await File(ownedPath).exists()) {
          throw FileSystemException('任务字幕文件不存在', ownedPath);
        }
        _upsertManagedSubtitleAssetInMemory(
          item,
          ownedPath,
          kind,
          entry.key.trim().isEmpty ? p.basename(ownedPath) : entry.key,
        );
      } catch (error, stackTrace) {
        // Preserve the old reference if copying fails. A failed adoption must
        // never make an otherwise usable subtitle disappear from the card.
        developer.log(
          'Unable to adopt subtitle into task ${item.id}',
          error: error,
          stackTrace: stackTrace,
        );
      }
      result[entry.key] = ownedPath;
    }
    return result;
  }

  /// Schema v2 migration. Only files with an unambiguous task owner are moved.
  /// Files referenced by multiple cards and filename-only guesses stay in place
  /// and continue to behave as external companion subtitles.
  Future<void> _migrateTaskSubtitleAssetsIfNeeded(int savedVersion) async {
    if (savedVersion >= 2) return;

    final storage = TaskSubtitleStorageService(dataRootOverride: _dataRootDir);
    final ownersByPath = <String, Set<String>>{};
    for (final item in _videos.values) {
      for (final path in _allSubtitleReferencePaths(item)) {
        if (path.trim().isEmpty) continue;
        ownersByPath
            .putIfAbsent(_normalizeCachePath(path), () => <String>{})
            .add(item.id);
      }
    }

    final topLevelFiles = <File>[];
    final legacyDirectory = Directory(p.join(_dataRootDir.path, 'subtitles'));
    if (await legacyDirectory.exists()) {
      try {
        await for (final entity in legacyDirectory.list(followLinks: false)) {
          if (entity is File && _isSupportedSubtitlePath(entity.path)) {
            topLevelFiles.add(entity);
          }
        }
      } on FileSystemException catch (error) {
        developer.log(
          'Unable to enumerate legacy subtitles during schema v2 migration',
          error: error,
        );
      }
    }

    final migratedSourceKeys = <String>{};
    for (final item in _videos.values) {
      final candidates = <String>{..._explicitManagedSubtitlePaths(item)};
      for (final file in topLevelFiles) {
        if (_hasTaskIdFilePrefix(file.path, item.id)) {
          candidates.add(file.path);
        }
      }

      for (final sourcePath in candidates) {
        if (!_isSupportedSubtitlePath(sourcePath)) continue;
        final sourceKey = _normalizeCachePath(sourcePath);
        if (migratedSourceKeys.contains(sourceKey)) continue;

        if (await storage.isTaskOwnedPath(sourcePath, item.id)) {
          if (await File(sourcePath).exists()) {
            _upsertManagedSubtitleAssetInMemory(
              item,
              sourcePath,
              _inferManagedSubtitleKind(sourcePath),
              p.basename(sourcePath),
            );
          }
          continue;
        }

        final owners = ownersByPath[sourceKey] ?? const <String>{};
        if (owners.length > 1 ||
            (owners.isNotEmpty && !owners.contains(item.id))) {
          continue;
        }
        final explicitlyReferenced = _explicitManagedSubtitlePaths(
          item,
        ).any((path) => _samePath(path, sourcePath));
        if (!explicitlyReferenced &&
            !_hasTaskIdFilePrefix(sourcePath, item.id)) {
          continue;
        }

        final source = File(sourcePath);
        if (!await source.exists()) continue;
        try {
          final destinationPath = await storage.allocatePath(
            item.id,
            p.basename(sourcePath),
          );
          final destination = File(destinationPath);
          var availableAtDestination = false;
          try {
            await source.rename(destinationPath);
            availableAtDestination = true;
          } on FileSystemException {
            await source.copy(destinationPath);
            availableAtDestination = await destination.exists();
            if (availableAtDestination) {
              try {
                await source.delete();
              } on FileSystemException {
                // A safe duplicate is preferable to losing either reference.
              }
            }
          }
          if (!availableAtDestination) continue;

          _replaceSubtitleReferences(item, sourcePath, destinationPath);
          _upsertManagedSubtitleAssetInMemory(
            item,
            destinationPath,
            _inferManagedSubtitleKind(sourcePath),
            p.basename(sourcePath),
          );
          migratedSourceKeys.add(sourceKey);
        } catch (error, stackTrace) {
          developer.log(
            'Unable to migrate legacy subtitle for task ${item.id}',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }

      try {
        final existingTaskFiles = await storage.listTaskSubtitles(item.id);
        for (final file in existingTaskFiles) {
          _upsertManagedSubtitleAssetInMemory(
            item,
            file.path,
            _inferManagedSubtitleKind(file.path),
            p.basename(file.path),
          );
        }
      } catch (error) {
        developer.log(
          'Unable to reconcile task subtitles for ${item.id}',
          error: error,
        );
      }
    }

    // Persist schemaVersion=2 even when there were no files to move.
    _needsPostLoadSave = true;
  }

  Iterable<String> _allSubtitleReferencePaths(VideoItem item) sync* {
    if (item.subtitlePath != null) yield item.subtitlePath!;
    if (item.secondarySubtitlePath != null) {
      yield item.secondarySubtitlePath!;
    }
    yield* item.additionalSubtitles?.values ?? const <String>[];
    yield* item.localSubtitles?.values ?? const <String>[];
    yield* item.recycledSelectedSubtitlePaths ?? const <String>[];
    yield* item.recycledAdditionalSubtitles?.values ?? const <String>[];
    yield* item.recycledLocalSubtitles?.values ?? const <String>[];
    for (final asset in item.managedSubtitleAssets) {
      yield asset.path;
    }
  }

  Set<String> _explicitManagedSubtitlePaths(VideoItem item) {
    final paths = <String>{
      ...?item.additionalSubtitles?.values,
      ...?item.localSubtitles?.values,
      ...?item.recycledAdditionalSubtitles?.values,
      ...?item.recycledLocalSubtitles?.values,
      ...item.managedSubtitleAssets.map((asset) => asset.path),
    };
    if (item.isSubtitleCached && item.subtitlePath != null) {
      paths.add(item.subtitlePath!);
    }
    if (item.isSecondarySubtitleCached && item.secondarySubtitlePath != null) {
      paths.add(item.secondarySubtitlePath!);
    }
    for (final path in <String?>[
      item.subtitlePath,
      item.secondarySubtitlePath,
      ...?item.recycledSelectedSubtitlePaths,
    ]) {
      if (path != null && _looksLikeLegacyGeneratedSubtitle(path, item.id)) {
        paths.add(path);
      }
    }
    return paths;
  }

  bool _looksLikeLegacyGeneratedSubtitle(String path, String videoId) {
    final name = p.basename(path).toLowerCase();
    return _hasTaskIdFilePrefix(path, videoId) ||
        name.contains('.ai.') ||
        name.contains('.manual.') ||
        name.contains('.translated.') ||
        name.contains('.stream_') ||
        name.contains('.imported.') ||
        name.endsWith('_main${p.extension(name)}') ||
        name.endsWith('_sec${p.extension(name)}');
  }

  bool _hasTaskIdFilePrefix(String path, String videoId) {
    final name = p.basename(path).toLowerCase();
    final id = videoId.toLowerCase();
    return name.startsWith('$id.') || name.startsWith('${id}_');
  }

  bool _isSupportedSubtitlePath(String path) {
    return SubtitleFileMatcher.supportedExtensions.contains(
      p.extension(path).toLowerCase(),
    );
  }

  ManagedSubtitleAssetKind _inferManagedSubtitleKind(String path) {
    final name = p.basename(path).toLowerCase();
    if (name.contains('.translated.') || name.contains('.translation.')) {
      return ManagedSubtitleAssetKind.translated;
    }
    if (name.contains('.manual.')) return ManagedSubtitleAssetKind.manual;
    if (name.contains('.stream_')) return ManagedSubtitleAssetKind.embedded;
    if (name.contains('.download')) return ManagedSubtitleAssetKind.downloaded;
    if (name.contains('.imported.')) return ManagedSubtitleAssetKind.imported;
    if (name.contains('.ai.')) return ManagedSubtitleAssetKind.ai;
    if (name.contains('.ocr.')) return ManagedSubtitleAssetKind.ocr;
    if (name.startsWith('main.') ||
        name.startsWith('secondary.') ||
        name.contains('_main.') ||
        name.contains('_sec.')) {
      return ManagedSubtitleAssetKind.cached;
    }
    return ManagedSubtitleAssetKind.imported;
  }

  void _replaceSubtitleReferences(
    VideoItem item,
    String oldPath,
    String newPath,
  ) {
    String replace(String value) => _samePath(value, oldPath) ? newPath : value;
    if (item.subtitlePath != null) {
      item.subtitlePath = replace(item.subtitlePath!);
    }
    if (item.secondarySubtitlePath != null) {
      item.secondarySubtitlePath = replace(item.secondarySubtitlePath!);
    }
    item.additionalSubtitles = item.additionalSubtitles?.map(
      (key, value) => MapEntry(key, replace(value)),
    );
    item.localSubtitles = item.localSubtitles?.map(
      (key, value) => MapEntry(key, replace(value)),
    );
    item.recycledSelectedSubtitlePaths = item.recycledSelectedSubtitlePaths
        ?.map(replace)
        .toList(growable: false);
    item.recycledAdditionalSubtitles = item.recycledAdditionalSubtitles?.map(
      (key, value) => MapEntry(key, replace(value)),
    );
    item.recycledLocalSubtitles = item.recycledLocalSubtitles?.map(
      (key, value) => MapEntry(key, replace(value)),
    );
    item.managedSubtitleAssets = item.managedSubtitleAssets
        .map(
          (asset) => _samePath(asset.path, oldPath)
              ? asset.copyWith(path: newPath)
              : asset,
        )
        .toList(growable: false);
  }

  List<ManagedSubtitleAsset> getManagedSubtitleAssets(String videoId) {
    return List<ManagedSubtitleAsset>.unmodifiable(
      _videos[videoId]?.managedSubtitleAssets ?? const <ManagedSubtitleAsset>[],
    );
  }

  ManagedSubtitleAsset? managedSubtitleAssetForPath(
    String videoId,
    String path,
  ) {
    final item = _videos[videoId];
    if (item == null) return null;
    for (final asset in item.managedSubtitleAssets) {
      if (_samePath(asset.path, path)) return asset;
    }
    return null;
  }

  Future<ManagedSubtitleAsset?> registerManagedSubtitleAsset(
    String videoId, {
    required String path,
    required ManagedSubtitleAssetKind kind,
    required String displayName,
    String? sourceAssetId,
    String? language,
  }) async {
    final item = _videos[videoId];
    if (item == null) return null;
    final existing = managedSubtitleAssetForPath(videoId, path);
    if (existing != null) return existing;
    final storage = TaskSubtitleStorageService(dataRootOverride: _dataRootDir);
    if (!await storage.isTaskOwnedPath(path, videoId)) {
      throw StateError('只能登记当前媒体任务目录内的字幕');
    }
    final asset = ManagedSubtitleAsset(
      assetId: const Uuid().v4(),
      path: p.normalize(path),
      kind: kind,
      displayName: displayName.trim().isEmpty
          ? p.basename(path)
          : displayName.trim(),
      sourceAssetId: sourceAssetId,
      language: language,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    item.managedSubtitleAssets = <ManagedSubtitleAsset>[
      ...item.managedSubtitleAssets,
      asset,
    ];
    _invalidateVideoSizeCache(videoId);
    await _saveLibrary();
    notifyListeners();
    return asset;
  }

  Future<ManagedSubtitleAsset?> registerManagedLocalSubtitle(
    String videoId, {
    required String path,
    required ManagedSubtitleAssetKind kind,
    required String displayName,
    String? language,
  }) async {
    final item = _videos[videoId];
    if (item == null) return null;
    final storage = TaskSubtitleStorageService(dataRootOverride: _dataRootDir);
    if (!await storage.isTaskOwnedPath(path, videoId)) {
      throw StateError('只能登记当前媒体任务目录内的字幕');
    }
    var name = displayName.trim().isEmpty
        ? p.basename(path)
        : displayName.trim();
    final local = <String, String>{...?item.localSubtitles};
    if (local.containsKey(name) && !_samePath(local[name]!, path)) {
      final base = name;
      var serial = 2;
      while (local.containsKey('$base（$serial）')) {
        serial++;
      }
      name = '$base（$serial）';
    }
    var asset = managedSubtitleAssetForPath(videoId, path);
    if (asset == null) {
      asset = ManagedSubtitleAsset(
        assetId: const Uuid().v4(),
        path: p.normalize(path),
        kind: kind,
        displayName: name,
        language: language,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      item.managedSubtitleAssets = <ManagedSubtitleAsset>[
        ...item.managedSubtitleAssets,
        asset,
      ];
    }
    local[name] = p.normalize(path);
    item.localSubtitles = local;
    item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
    _invalidateVideoSizeCache(videoId);
    await _saveLibrary();
    notifyListeners();
    return asset;
  }

  Future<void> reconcileManagedSubtitleAssets(
    String videoId,
    Iterable<String> paths,
  ) async {
    final item = _videos[videoId];
    if (item == null) return;
    final storage = TaskSubtitleStorageService(dataRootOverride: _dataRootDir);
    var changed = false;
    for (final path in paths) {
      if (item.managedSubtitleAssets.any(
        (asset) => _samePath(asset.path, path),
      )) {
        continue;
      }
      if (!await storage.isTaskOwnedPath(path, videoId) ||
          !await File(path).exists()) {
        continue;
      }
      _upsertManagedSubtitleAssetInMemory(
        item,
        path,
        _inferManagedSubtitleKind(path),
        p.basename(path),
      );
      changed = true;
    }
    if (!changed) return;
    _invalidateVideoSizeCache(videoId);
    await _saveLibrary();
    notifyListeners();
  }

  List<String> managedSubtitleDeletionPaths(String videoId, String path) {
    final item = _videos[videoId];
    if (item == null) return <String>[path];
    final root = managedSubtitleAssetForPath(videoId, path);
    if (root == null) return <String>[path];
    final ids = <String>{root.assetId};
    var changed = true;
    while (changed) {
      changed = false;
      for (final asset in item.managedSubtitleAssets) {
        if (asset.sourceAssetId != null &&
            ids.contains(asset.sourceAssetId) &&
            ids.add(asset.assetId)) {
          changed = true;
        }
      }
    }
    return item.managedSubtitleAssets
        .where((asset) => ids.contains(asset.assetId))
        .map((asset) => asset.path)
        .toList(growable: false);
  }

  Future<void> removeManagedSubtitleAssetsByPaths(
    String videoId,
    Iterable<String> paths,
  ) async {
    final item = _videos[videoId];
    if (item == null) return;
    final keys = paths.map(_normalizeCachePath).toSet();
    if (keys.isEmpty) return;
    final previousCount = item.managedSubtitleAssets.length;
    item.managedSubtitleAssets = item.managedSubtitleAssets
        .where((asset) => !keys.contains(_normalizeCachePath(asset.path)))
        .toList(growable: false);
    if (item.managedSubtitleAssets.length == previousCount) return;
    _invalidateVideoSizeCache(videoId);
    await _saveLibrary();
    notifyListeners();
  }

  Future<void> updateVideoSubtitleVisibility(
    String videoId,
    bool showFloatingSubtitles,
  ) async {
    final item = _videos[videoId];
    if (item != null) {
      item.showFloatingSubtitles = showFloatingSubtitles;
      item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
      await _saveLibrary();
      notifyListeners();
    }
  }

  Future<void> markAutoEmbeddedSubtitleLoadAttempted(String videoId) async {
    final item = _videos[videoId];
    if (item != null && !item.hasAttemptedAutoEmbeddedSubtitleLoad) {
      item.hasAttemptedAutoEmbeddedSubtitleLoad = true;
      item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
      await _saveLibrary();
      notifyListeners();
    }
  }

  Future<void> updateVideoPortraitDisplayAspectRatio(
    String videoId,
    double? aspectRatio, {
    double? customWidth,
    double? customHeight,
    bool markInitialized = true,
  }) async {
    final item = _videos[videoId];
    if (item == null) return;

    final bool ratioUnchanged =
        (item.portraitDisplayAspectRatio == null && aspectRatio == null) ||
        (item.portraitDisplayAspectRatio != null &&
            aspectRatio != null &&
            (item.portraitDisplayAspectRatio! - aspectRatio).abs() < 0.0001);
    final bool customWidthUnchanged =
        (item.portraitCustomAspectWidth == null && customWidth == null) ||
        (item.portraitCustomAspectWidth != null &&
            customWidth != null &&
            (item.portraitCustomAspectWidth! - customWidth).abs() < 0.0001);
    final bool customHeightUnchanged =
        (item.portraitCustomAspectHeight == null && customHeight == null) ||
        (item.portraitCustomAspectHeight != null &&
            customHeight != null &&
            (item.portraitCustomAspectHeight! - customHeight).abs() < 0.0001);
    final bool initializedUnchanged =
        item.hasPortraitAspectPreferenceInitialized ==
        (item.hasPortraitAspectPreferenceInitialized || markInitialized);

    if (ratioUnchanged &&
        customWidthUnchanged &&
        customHeightUnchanged &&
        initializedUnchanged) {
      return;
    }

    item.portraitDisplayAspectRatio = aspectRatio;
    item.portraitCustomAspectWidth = customWidth;
    item.portraitCustomAspectHeight = customHeight;
    item.hasPortraitAspectPreferenceInitialized =
        item.hasPortraitAspectPreferenceInitialized || markInitialized;

    item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
    await _saveLibrary();
    notifyListeners();
  }

  Future<void> updateVideoDisplayTransform(
    String videoId, {
    bool? isMirroredH,
    bool? isMirroredV,
  }) async {
    final item = _videos[videoId];
    if (item == null) return;

    final bool nextMirroredH = isMirroredH ?? item.isVideoMirroredH;
    final bool nextMirroredV = isMirroredV ?? item.isVideoMirroredV;

    if (item.isVideoMirroredH == nextMirroredH &&
        item.isVideoMirroredV == nextMirroredV) {
      return;
    }

    item.isVideoMirroredH = nextMirroredH;
    item.isVideoMirroredV = nextMirroredV;
    item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
    await _saveLibrary();
    notifyListeners();
  }

  // --- Single Item Management (Exposed for Batch Import) ---

  Future<String?> addSingleVideo(
    VideoItem item, {
    bool useOriginalPath = false,
    bool reuseExistingItem = false,
  }) async {
    final copyImportedMediaToPrivateStorage =
        SettingsService().copyImportedMediaToPrivateStorage;
    // #region debug-point A:add-single-video-enter
    unawaited(
      _reportDebugEvent(
        'A',
        'library_service.dart:addSingleVideo',
        'addSingleVideo entered',
        data: <String, Object?>{
          'id': item.id,
          'path': item.path,
          'useOriginalPath': useOriginalPath,
          'hasThumbnail': item.thumbnailPath != null,
        },
      ),
    );
    // #endregion
    item.title = _normalizeImportedName(item.title);
    item.sourceFingerprint ??= await _computeSourceFingerprint(item.path);
    final isBilibiliStream = _isBilibiliStreamItem(item);

    // Every Bilibili streaming import is an explicit card instance. Its URL
    // identifies the playback source, never whether another card already
    // exists, so path/fingerprint deduplication must not apply here.
    if (reuseExistingItem && !isBilibiliStream) {
      final existingId = await _findExistingVideoIdByPathOrFingerprint(
        item.path,
        sourceFingerprint: item.sourceFingerprint,
        originalTitle: item.title,
      );

      if (existingId != null) {
        await _restoreExistingVideoToTarget(existingId, item.parentId);
        debugPrint(
          "Video with path ${item.path} already exists, skipping import",
        );
        return existingId;
      }
    }

    // 2. Handle file persistence for temp/cache files
    // 如果 useOriginalPath 为 true，则跳过文件持久化处理，直接使用原始路径
    if (!isBilibiliStream) {
      if (copyImportedMediaToPrivateStorage) {
        item.path = await _copyImportedMediaToPrivateStorage(
          item.path,
          fileNamePrefix: item.id,
        );
      } else if (!useOriginalPath) {
        await _ensureFilePersistence(item);
      } else {
        debugPrint(
          "Using original path for single video (no copy): ${item.path}",
        );
      }
    }

    if (!isBilibiliStream && item.durationMs <= 0) {
      item.durationMs = await _probeMediaDurationMs(item.path);
    }
    if (!isBilibiliStream && !item.hasProbedChapters) {
      if (item.chapters.isEmpty) {
        item.chapters = await MediaChapterProbe.probe(
          item.path,
          durationMs: item.durationMs,
        );
      }
      item.hasProbedChapters = true;
    }

    // Downloaded/imported subtitle groups are task assets. Adopt them before
    // publishing the card so no other card can observe their original path as
    // if it were shared state.
    item.additionalSubtitles = await _adoptSubtitleMapIntoTask(
      item,
      item.additionalSubtitles,
      ManagedSubtitleAssetKind.downloaded,
    );
    item.localSubtitles = await _adoptSubtitleMapIntoTask(
      item,
      item.localSubtitles,
      ManagedSubtitleAssetKind.imported,
    );

    // #region debug-point D:add-single-video-after-probe
    unawaited(
      _reportDebugEvent(
        'D',
        'library_service.dart:addSingleVideo',
        'Duration probe completed for imported video',
        data: <String, Object?>{
          'id': item.id,
          'path': item.path,
          'durationMs': item.durationMs,
        },
      ),
    );
    // #endregion

    // 3. Audio cover art / video thumbnail will be generated asynchronously below

    _videos[item.id] = item;

    if (item.parentId != null && _collections.containsKey(item.parentId)) {
      _collections[item.parentId]!.childrenIds.add(item.id);
    } else {
      // Safe-guard: if parent missing or null, add to root
      if (item.parentId != null) {
        item.parentId = null;
      }
      _rootChildrenIds.add(item.id);
    }

    await _saveLibrary();
    notifyListeners();

    // #region debug-point A:add-single-video-notify
    unawaited(
      _reportDebugEvent(
        'A',
        'library_service.dart:addSingleVideo',
        'Library saved and listeners notified for imported video',
        data: <String, Object?>{
          'id': item.id,
          'path': item.path,
          'type': item.type.name,
        },
      ),
    );
    // #endregion

    // Generate thumbnail asynchronously (video thumbnail + audio cover art)
    if ((!isBilibiliStream &&
            item.type == MediaType.video &&
            (item.thumbnailPath == null ||
                _requiresWindowsThumbnailRepair(item.thumbnailPath))) ||
        (item.type == MediaType.audio && item.thumbnailPath == null)) {
      _generateThumbnail(item.path, videoId: item.id).then((thumb) {
        // #region debug-point C:add-single-video-thumb-finished
        unawaited(
          _reportDebugEvent(
            'C',
            'library_service.dart:addSingleVideo',
            'Async thumbnail generation finished',
            data: <String, Object?>{
              'id': item.id,
              'path': item.path,
              'thumbGenerated': thumb != null,
            },
          ),
        );
        // #endregion
        if (thumb != null) {
          item.thumbnailPath = thumb;
          unawaited(
            _saveLibrary().catchError((Object error, StackTrace stackTrace) {
              developer.log(
                'Error saving generated thumbnail',
                error: error,
                stackTrace: stackTrace,
              );
            }),
          );
          notifyListeners();
        }
      });
    }

    return item.id;
  }

  /// Ensures that video and subtitle files are moved to permanent storage
  /// if they are currently in a temporary or cache directory.
  Future<void> _ensureFilePersistence(VideoItem item) async {
    try {
      final importedDir = Directory(
        p.join(_dataRootDir.path, 'imported_videos'),
      );

      // Handle Video File
      item.path = await _moveIfTemporary(item.path, importedDir);

      final taskSubtitleDir = await TaskSubtitleStorageService(
        dataRootOverride: _dataRootDir,
      ).taskDirectory(item.id, create: true);

      // Temporary subtitle picker/download results are owned by this card.
      if (item.subtitlePath != null) {
        final previousPath = item.subtitlePath!;
        item.subtitlePath = await _moveIfTemporary(
          previousPath,
          taskSubtitleDir,
        );
        if (!_samePath(previousPath, item.subtitlePath!)) {
          _upsertManagedSubtitleAssetInMemory(
            item,
            item.subtitlePath!,
            ManagedSubtitleAssetKind.imported,
            p.basename(item.subtitlePath!),
          );
        }
      }

      if (item.secondarySubtitlePath != null) {
        final previousPath = item.secondarySubtitlePath!;
        item.secondarySubtitlePath = await _moveIfTemporary(
          previousPath,
          taskSubtitleDir,
        );
        if (!_samePath(previousPath, item.secondarySubtitlePath!)) {
          _upsertManagedSubtitleAssetInMemory(
            item,
            item.secondarySubtitlePath!,
            ManagedSubtitleAssetKind.imported,
            p.basename(item.secondarySubtitlePath!),
          );
        }
      }
    } catch (e) {
      debugPrint("Error ensuring file persistence: $e");
    }
  }

  Future<String> _moveIfTemporary(
    String currentPath,
    Directory targetDir,
  ) async {
    try {
      final file = File(currentPath);
      if (!await file.exists()) return currentPath;

      bool isTemporary = false;

      // Check 1: System Temp Dir
      final tempDir = await getTemporaryDirectory();
      if (p.isWithin(tempDir.path, currentPath)) {
        isTemporary = true;
      }

      // Check 2: Android Caches
      if (!isTemporary && Platform.isAndroid) {
        final extCacheDirs = await getExternalCacheDirectories();
        if (extCacheDirs != null) {
          for (var dir in extCacheDirs) {
            if (p.isWithin(dir.path, currentPath)) {
              isTemporary = true;
              break;
            }
          }
        }
      }

      // Check 3: App Data Dir (Internal but not library root)
      // Files in app data that are NOT in our 'imported_videos' or 'videos' root
      // are often "batch import cache" files (like unzipped files).
      if (!isTemporary && p.isWithin(_dataRootDir.path, currentPath)) {
        final importedDir = Directory(
          p.join(_dataRootDir.path, 'imported_videos'),
        );
        final subDir = Directory(p.join(_dataRootDir.path, 'subtitles'));
        final thumbDir = Directory(p.join(_dataRootDir.path, 'thumbnails'));
        if (!p.isWithin(importedDir.path, currentPath) &&
            !p.isWithin(subDir.path, currentPath) &&
            !p.isWithin(thumbDir.path, currentPath)) {
          isTemporary = true;
        }
      }

      if (isTemporary) {
        if (!await targetDir.exists()) await targetDir.create(recursive: true);

        // Use a unique name to avoid collisions
        final fileName =
            "${DateTime.now().millisecondsSinceEpoch}_${p.basename(currentPath)}";
        final newPath = p.join(targetDir.path, fileName);

        // Use safe chunked copy to avoid OOM or OS file limits for large files
        try {
          await file.rename(newPath);
        } catch (e) {
          debugPrint(
            "Rename failed in _moveIfTemporary: $e, falling back to chunked copy",
          );
          final rafSource = await file.open(mode: FileMode.read);
          final rafTarget = await File(newPath).open(mode: FileMode.write);
          try {
            final length = await rafSource.length();
            int offset = 0;
            const chunkSize = 1024 * 1024 * 4; // 4MB
            while (offset < length) {
              final bytes = await rafSource.read(chunkSize);
              await rafTarget.writeFrom(bytes);
              offset += bytes.length;
              await Future.delayed(const Duration(milliseconds: 1)); // Yield
            }
          } finally {
            await rafSource.close();
            await rafTarget.close();
          }
        }

        // Delete original if it was temporary
        try {
          if (await file.exists()) {
            await file.delete();
          }
          debugPrint("Deleted temp file after move: $currentPath");

          // Check for empty unzip parent dir
          final parentDir = file.parent;
          if (p.basename(parentDir.path).startsWith('unzip_')) {
            if (await parentDir.list().isEmpty) {
              await parentDir.delete();
              debugPrint("Deleted empty unzip dir: ${parentDir.path}");
            }
          }
        } catch (e) {
          debugPrint("Failed to delete temp file: $e");
        }

        return newPath;
      }
    } catch (e) {
      debugPrint("Error in _moveIfTemporary for $currentPath: $e");
    }
    return currentPath;
  }

  Future<void> removeSingleVideo(String id, {bool keepFile = false}) async {
    if (_videos.containsKey(id)) {
      _invalidateSizeCaches();
      final vid = _videos[id];
      if (vid != null && !keepFile) await _deleteVideoFiles(vid);
      _deleteVideo(id); // Helper handles parent removal
      await _saveLibrary();
      notifyListeners();
    }
  }

  Future<void> renameItem(String id, String newName) async {
    if (_collections.containsKey(id)) {
      _collections[id]!.name = newName;
    } else if (_videos.containsKey(id)) {
      _videos[id]!.title = newName;
    }
    await _saveLibrary();
    notifyListeners();
  }

  // --- Size Calculation Helpers ---

  Future<int> calculateItemSize(dynamic item) async {
    final cacheKey = _itemSizeCacheKey(item);
    if (cacheKey == null) return 0;

    final cachedSize = _itemSizeCache[cacheKey];
    if (cachedSize != null) {
      return cachedSize;
    }

    final inFlight = _itemSizeInFlight[cacheKey];
    if (inFlight != null) {
      return inFlight;
    }

    final future = _calculateAndCacheItemSize(item, cacheKey);
    _itemSizeInFlight[cacheKey] = future;
    return future;
  }

  int? getCachedItemSize(dynamic item) {
    final cacheKey = _itemSizeCacheKey(item);
    if (cacheKey == null) return null;
    return _itemSizeCache[cacheKey];
  }

  Future<int> calculateItemsTotalSize(Iterable<dynamic> items) async {
    var total = 0;
    for (final item in items) {
      total += await calculateItemSize(item);
    }
    return total;
  }

  Future<int> _calculateAndCacheItemSize(dynamic item, String cacheKey) async {
    try {
      int size = 0;
      if (item is VideoItem) {
        size = await _calculateVideoItemSize(item);
      } else if (item is VideoCollection) {
        size = await _calculateCollectionSize(item);
      }
      _itemSizeCache[cacheKey] = size;
      return size;
    } finally {
      _itemSizeInFlight.remove(cacheKey);
    }
  }

  Future<int> _calculateVideoItemSize(VideoItem item) async {
    int size = 0;

    if (_isBilibiliStreamItem(item)) {
      try {
        final report = _bilibiliStreamingService != null
            ? await _bilibiliStreamingService!.inspectItemCache(item.id)
            : await BilibiliStreamingService.inspectCacheForItem(item.id);
        size += report.bytes;
      } catch (e) {
        developer.log('Error calculating Bilibili stream cache size', error: e);
      }
    }

    // Check Video File
    if (!_isBilibiliStreamItem(item) &&
        (_isInternalPath(item.path) ||
            await _isBilibiliExportedCandidate(item))) {
      size += await _getFileSize(item.path);
    }
    if (item.playbackPath != null &&
        !_samePath(item.playbackPath!, item.path) &&
        _isInternalPath(item.playbackPath!)) {
      size += await _getFileSize(item.playbackPath!);
    }
    size += await TaskSubtitleStorageService(
      dataRootOverride: _dataRootDir,
    ).taskDirectorySize(item.id);

    // Check Thumbnail
    if (item.thumbnailPath != null && _isInternalPath(item.thumbnailPath!)) {
      size += await _getFileSize(item.thumbnailPath!);
    }
    size += await ChapterThumbnailService.instance.directorySize(item.id);
    size += await BilibiliVideoShotService.instance.directorySize(
      item.id,
      dataRootOverride: _dataRootDir,
    );

    return size;
  }

  Future<int> _calculateCollectionSize(VideoCollection col) async {
    var size = 0;
    final children = getContents(col.id);

    // 顺序统计，避免进入回收站时对磁盘发起过多并发访问。
    for (final child in children) {
      size += await calculateItemSize(child);
    }
    return size;
  }

  String? _itemSizeCacheKey(dynamic item) {
    if (item is VideoItem) return 'video:${item.id}';
    if (item is VideoCollection) return 'collection:${item.id}';
    return null;
  }

  void _invalidateSizeCaches() {
    _itemSizeCache.clear();
    _itemSizeInFlight.clear();
  }

  void _invalidateVideoSizeCache(String videoId) {
    final videoKey = 'video:$videoId';
    _itemSizeCache.remove(videoKey);
    _itemSizeInFlight.remove(videoKey);
    _itemSizeCache.removeWhere((key, _) => key.startsWith('collection:'));
    _itemSizeInFlight.removeWhere((key, _) => key.startsWith('collection:'));
  }

  /// Invalidates filesystem-derived subtitle data after a subtitle file is
  /// created or deleted outside LibraryService (for example by translation).
  void notifySubtitleFilesChanged({String? videoId}) {
    if (videoId == null || videoId.isEmpty) {
      _invalidateSizeCaches();
    } else {
      _invalidateVideoSizeCache(videoId);
    }
    notifyListeners();
  }

  /// Invalidates recycle-bin size labels when the live online cache changes.
  void notifyOnlineCacheChanged(String videoId) {
    if (videoId.isEmpty) {
      _invalidateSizeCaches();
    } else {
      _invalidateVideoSizeCache(videoId);
    }
    notifyListeners();
  }

  bool _isBilibiliStreamItem(VideoItem item) {
    return item.sourceRef?.kind == MediaSourceKind.bilibiliStream ||
        item.path.startsWith('bilibili://stream/');
  }

  int get _maxConcurrentSizeCalculations => Platform.isWindows ? 3 : 2;

  Future<T> _runWithSizeCalculationPermit<T>(
    Future<T> Function() action,
  ) async {
    while (_activeSizeCalculationCount >= _maxConcurrentSizeCalculations) {
      final completer = Completer<void>();
      _sizeCalculationWaitQueue.add(completer);
      await completer.future;
    }

    _activeSizeCalculationCount++;
    try {
      return await action();
    } finally {
      _activeSizeCalculationCount--;
      if (_sizeCalculationWaitQueue.isNotEmpty) {
        _sizeCalculationWaitQueue.removeAt(0).complete();
      }
    }
  }

  String _normalizeCachePath(String path) {
    final normalized = p.normalize(path);
    if (Platform.isWindows) {
      return normalized.toLowerCase();
    }
    return normalized;
  }

  bool _looksLikeBilibiliExportedFile(String path) {
    final name = p.basenameWithoutExtension(path);
    final reg = RegExp(
      r'_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
    );
    return reg.hasMatch(name);
  }

  Future<String?> _getBilibiliCustomDownloadPath() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString('bilibili_custom_download_path');
    if (path == null || path.isEmpty) return null;
    return path;
  }

  Future<bool> _isBilibiliExportedCandidate(VideoItem item) async {
    if (!Platform.isWindows) return item.isBilibiliExported;
    if (item.isBilibiliExported) return true;
    final customPath = await _getBilibiliCustomDownloadPath();
    if (customPath == null) return false;
    if (!p.isWithin(customPath, item.path)) return false;
    return _looksLikeBilibiliExportedFile(item.path);
  }

  bool _isInternalPath(String path) {
    if (!_initialized) return false;
    return p.isWithin(_dataRootDir.path, path);
  }

  String _thumbnailOutputPath(String videoPath, {String? videoId}) {
    final thumbDir = p.join(_dataRootDir.path, 'thumbnails');
    if (videoId != null && videoId.isNotEmpty) {
      return p.join(thumbDir, "$videoId.jpg");
    }
    final hash = md5.convert(utf8.encode(videoPath)).toString();
    return p.join(thumbDir, "$hash.jpg");
  }

  bool _isMediaFilePathReferencedByOtherVideo(
    String path,
    String currentVideoId,
  ) {
    for (final entry in _videos.entries) {
      if (entry.key == currentVideoId) continue;
      if (_samePath(entry.value.path, path)) {
        return true;
      }
    }
    return false;
  }

  bool _isThumbnailPathReferencedByOtherVideo(
    String path,
    String currentVideoId,
  ) {
    for (final entry in _videos.entries) {
      if (entry.key == currentVideoId) continue;
      final thumbnailPath = entry.value.thumbnailPath;
      if (thumbnailPath != null && _samePath(thumbnailPath, path)) {
        return true;
      }
    }
    return false;
  }

  bool _subtitleReferencesContainPathInOtherVideo(
    String path,
    String currentVideoId,
  ) {
    for (final entry in _videos.entries) {
      if (entry.key == currentVideoId) continue;
      if (_subtitleReferencesContainPath(entry.value, path)) return true;
    }
    return false;
  }

  bool _subtitleReferencesContainPath(VideoItem item, String path) {
    final directPaths = <String?>[
      item.subtitlePath,
      item.secondarySubtitlePath,
      item.danmakuPath,
      ...?item.additionalSubtitles?.values,
      ...?item.localSubtitles?.values,
      ...?item.recycledSelectedSubtitlePaths,
      ...?item.recycledAdditionalSubtitles?.values,
      ...?item.recycledLocalSubtitles?.values,
    ];
    for (final candidate in directPaths) {
      if (candidate != null && _samePath(candidate, path)) {
        return true;
      }
    }
    return false;
  }

  bool _samePath(String a, String b) {
    final left = p.normalize(a);
    final right = p.normalize(b);
    if (Platform.isWindows) {
      return left.toLowerCase() == right.toLowerCase();
    }
    return left == right;
  }

  Future<int> _getFileSize(String path) async {
    try {
      return _runWithSizeCalculationPermit(() async {
        final file = File(path);
        if (await file.exists()) {
          return await file.length();
        }
        return 0;
      });
    } catch (e) {
      // ignore
    }
    return 0;
  }

  static String formatSize(int bytes) {
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB"];
    var i = (log(bytes) / log(1024)).floor();
    return '${(bytes / pow(1024, i)).toStringAsFixed(2)} ${suffixes[i]}';
  }
}

class _ArchiveTemporaryStorageStats {
  final List<File> files;
  final List<Directory> directories;
  final int fileCount;
  final int totalBytes;

  const _ArchiveTemporaryStorageStats({
    required this.files,
    required this.directories,
    required this.fileCount,
    required this.totalBytes,
  });
}

const int _maxArchivePathSegmentLength = 120;
const int _defaultMaxArchiveEntryCount = 20000;
const int _defaultMaxArchivePathDepth = 64;
const int _defaultMaxArchiveCompressionRatio = 1000;
const int _mobileMaxArchiveSingleFileBytes = 4 * 1024 * 1024 * 1024;
const int _mobileMaxArchiveTotalBytes = 16 * 1024 * 1024 * 1024;
const int _desktopMaxArchiveSingleFileBytes = 20 * 1024 * 1024 * 1024;
const int _desktopMaxArchiveTotalBytes = 100 * 1024 * 1024 * 1024;

int get _defaultMaxArchiveSingleFileBytes =>
    Platform.isAndroid || Platform.isIOS
    ? _mobileMaxArchiveSingleFileBytes
    : _desktopMaxArchiveSingleFileBytes;

int get _defaultMaxArchiveTotalBytes => Platform.isAndroid || Platform.isIOS
    ? _mobileMaxArchiveTotalBytes
    : _desktopMaxArchiveTotalBytes;

class _ArchiveWriteBudget {
  final int maxTotalBytes;
  int writtenBytes = 0;

  _ArchiveWriteBudget(this.maxTotalBytes);

  void reserve(int byteCount) {
    if (byteCount < 0 || writtenBytes + byteCount > maxTotalBytes) {
      throw StateError(
        '压缩包解压后的媒体总大小超过安全上限 '
        '(${LibraryService.formatSize(maxTotalBytes)})',
      );
    }
    writtenBytes += byteCount;
  }
}

/// Delegates archive output to disk while enforcing both per-file and global
/// byte limits. Archive headers are untrusted, so checking only entry.size is
/// not sufficient for a forged or malformed compressed stream.
class _BudgetedArchiveOutputStream extends OutputStream {
  final OutputFileStream _delegate;
  final _ArchiveWriteBudget _budget;
  final int _maxFileBytes;
  int _writtenForFile = 0;

  _BudgetedArchiveOutputStream(this._delegate, this._budget, this._maxFileBytes)
    : super(byteOrder: _delegate.byteOrder);

  void _reserve(int count) {
    if (count < 0 || _writtenForFile + count > _maxFileBytes) {
      throw StateError(
        '压缩包内单个媒体超过安全上限 '
        '(${LibraryService.formatSize(_maxFileBytes)})',
      );
    }
    _budget.reserve(count);
    _writtenForFile += count;
  }

  @override
  int get length => _delegate.length;

  @override
  bool get isOpen => _delegate.isOpen;

  @override
  void clear() {
    _delegate.clear();
  }

  @override
  void flush() => _delegate.flush();

  @override
  void closeSync() => _delegate.closeSync();

  @override
  Future<void> close() => _delegate.close();

  @override
  void writeByte(int value) {
    _reserve(1);
    _delegate.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    _reserve(count);
    _delegate.writeBytes(bytes, length: count);
  }

  @override
  void writeStream(InputStream stream) {
    const chunkSize = 1024 * 1024;
    while (!stream.isEOS) {
      final count = min(chunkSize, stream.length);
      if (count <= 0) {
        break;
      }
      final bytes = stream.readBytes(count).toUint8List();
      writeBytes(bytes);
    }
  }

  @override
  Uint8List subset(int start, [int? end]) => _delegate.subset(start, end);
}

String _buildArchiveEntryOutputPath({
  required String outputRoot,
  required String entryName,
  required bool treatAsFile,
}) {
  final rawSegments = entryName
      .split(RegExp(r'[\\/]+'))
      .where((segment) => segment.isNotEmpty)
      .toList();
  if (rawSegments.isEmpty) {
    return outputRoot;
  }

  final sanitizedSegments = <String>[];
  for (var i = 0; i < rawSegments.length; i++) {
    final segment = rawSegments[i];
    if (segment == '.' || segment == '..') {
      continue;
    }
    sanitizedSegments.add(
      _sanitizeArchivePathSegment(
        segment,
        preserveExtension: treatAsFile && i == rawSegments.length - 1,
        fallbackName: treatAsFile && i == rawSegments.length - 1
            ? 'file'
            : 'item',
      ),
    );
  }

  if (sanitizedSegments.isEmpty) {
    sanitizedSegments.add(treatAsFile ? 'file' : 'item');
  }
  return p.normalize(p.join(outputRoot, p.joinAll(sanitizedSegments)));
}

/// 在独立 Isolate 中执行文件夹递归扫描，避免阻塞 UI 线程。
///
/// 使用 listSync 同步遍历（Isolate 内同步不影响 UI），返回仅含原始计数的
/// Map，避免跨 Isolate 传递复杂对象。由 [LibraryService.analyzeFolderSelection]
/// 通过 compute() 调用。
Map<String, dynamic> _analyzeFolderSelectionIsolate(String folderPath) {
  final rootDir = Directory(folderPath);
  var folderCount = 1;
  var mediaFileCount = 0;
  for (final entity in rootDir.listSync(recursive: true, followLinks: false)) {
    if (entity is Directory) {
      folderCount++;
    } else if (entity is File &&
        LibraryService.isSupportedMediaPath(entity.path)) {
      mediaFileCount++;
    }
  }
  return {'folderCount': folderCount, 'mediaFileCount': mediaFileCount};
}

String _sanitizeArchivePathSegment(
  String segment, {
  required bool preserveExtension,
  required String fallbackName,
}) {
  var cleaned = segment
      .replaceAll(RegExp(r'[<>:"/\\|?*\u0000-\u001F]+'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  cleaned = cleaned.replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
    cleaned = fallbackName;
  }
  final windowsBaseName = p.basenameWithoutExtension(cleaned).toUpperCase();
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$',
  ).hasMatch(windowsBaseName)) {
    cleaned = '_$cleaned';
  }
  if (cleaned.length <= _maxArchivePathSegmentLength) {
    return cleaned;
  }

  final hash = md5.convert(utf8.encode(cleaned)).toString().substring(0, 8);
  if (!preserveExtension) {
    final keepLength = _maxArchivePathSegmentLength - hash.length - 1;
    if (keepLength <= 0) {
      return '${fallbackName}_$hash';
    }
    return '${cleaned.substring(0, keepLength)}_$hash';
  }

  final ext = p.extension(cleaned);
  final base = p.basenameWithoutExtension(cleaned);
  final suffix = '_$hash';
  final keepLength = _maxArchivePathSegmentLength - ext.length - suffix.length;
  if (keepLength <= 0) {
    return '$fallbackName$suffix$ext';
  }
  return '${base.substring(0, keepLength)}$suffix$ext';
}

Map<String, int> _extractArchiveToDiskWorker(Map<String, Object?> args) {
  final archivePath = args['archivePath'];
  final destDir = args['destDir'];
  if (archivePath is! String ||
      archivePath.isEmpty ||
      destDir is! String ||
      destDir.isEmpty) {
    throw ArgumentError('missing archivePath or destDir');
  }

  return _extractArchiveToDiskWithParentsSync(
    archivePath: archivePath,
    outputPath: destDir,
    maxEntryCount: args['maxEntryCount'] as int?,
    maxTotalBytes: args['maxTotalBytes'] as int?,
    maxSingleFileBytes: args['maxSingleFileBytes'] as int?,
    maxPathDepth: args['maxPathDepth'] as int?,
    maxCompressionRatio: args['maxCompressionRatio'] as int?,
  );
}

Map<String, int> _extractArchiveToDiskWithParentsSync({
  required String archivePath,
  required String outputPath,
  int? maxEntryCount,
  int? maxTotalBytes,
  int? maxSingleFileBytes,
  int? maxPathDepth,
  int? maxCompressionRatio,
}) {
  Directory? tempDir;
  InputStream? inputToClose;
  Archive? archive;
  final normalizedArchivePath = archivePath.toLowerCase();
  var decodedArchivePath = archivePath;
  var extractedEntries = 0;
  var extractedMediaEntries = 0;
  var extractedSubtitleEntries = 0;
  var skippedNonMediaEntries = 0;
  final effectiveMaxEntryCount = maxEntryCount ?? _defaultMaxArchiveEntryCount;
  final effectiveMaxTotalBytes = maxTotalBytes ?? _defaultMaxArchiveTotalBytes;
  final effectiveMaxSingleFileBytes =
      maxSingleFileBytes ?? _defaultMaxArchiveSingleFileBytes;
  final effectiveMaxPathDepth = maxPathDepth ?? _defaultMaxArchivePathDepth;
  final effectiveMaxCompressionRatio =
      maxCompressionRatio ?? _defaultMaxArchiveCompressionRatio;
  if (effectiveMaxEntryCount <= 0 ||
      effectiveMaxTotalBytes <= 0 ||
      effectiveMaxSingleFileBytes <= 0 ||
      effectiveMaxPathDepth <= 0 ||
      effectiveMaxCompressionRatio <= 0) {
    throw ArgumentError('archive extraction limits must be positive');
  }
  final writeBudget = _ArchiveWriteBudget(effectiveMaxTotalBytes);

  try {
    Directory(outputPath).createSync(recursive: true);

    // 两阶段解压：先将压缩层解压为中间 .tar 文件，再解码 tar 流
    if (normalizedArchivePath.endsWith('tar.gz') ||
        normalizedArchivePath.endsWith('tgz')) {
      tempDir = Directory.systemTemp.createTempSync('dart_archive');
      decodedArchivePath = p.join(tempDir.path, 'temp.tar');
      final input = InputFileStream(archivePath);
      final output = _BudgetedArchiveOutputStream(
        OutputFileStream(decodedArchivePath),
        _ArchiveWriteBudget(effectiveMaxTotalBytes),
        effectiveMaxTotalBytes,
      );
      try {
        GZipDecoder().decodeStream(input, output);
      } finally {
        try {
          input.closeSync();
        } catch (_) {}
        try {
          output.closeSync();
        } catch (_) {}
      }
    } else if (normalizedArchivePath.endsWith('tar.bz2') ||
        normalizedArchivePath.endsWith('tbz') ||
        normalizedArchivePath.endsWith('tbz2')) {
      tempDir = Directory.systemTemp.createTempSync('dart_archive');
      decodedArchivePath = p.join(tempDir.path, 'temp.tar');
      final input = InputFileStream(archivePath);
      final output = _BudgetedArchiveOutputStream(
        OutputFileStream(decodedArchivePath),
        _ArchiveWriteBudget(effectiveMaxTotalBytes),
        effectiveMaxTotalBytes,
      );
      try {
        BZip2Decoder().decodeStream(input, output);
      } finally {
        try {
          input.closeSync();
        } catch (_) {}
        try {
          output.closeSync();
        } catch (_) {}
      }
    } else if (normalizedArchivePath.endsWith('tar.xz') ||
        normalizedArchivePath.endsWith('txz')) {
      tempDir = Directory.systemTemp.createTempSync('dart_archive');
      decodedArchivePath = p.join(tempDir.path, 'temp.tar');
      final input = InputFileStream(archivePath);
      final output = _BudgetedArchiveOutputStream(
        OutputFileStream(decodedArchivePath),
        _ArchiveWriteBudget(effectiveMaxTotalBytes),
        effectiveMaxTotalBytes,
      );
      try {
        XZDecoder().decodeStream(input, output);
      } finally {
        try {
          input.closeSync();
        } catch (_) {}
        try {
          output.closeSync();
        } catch (_) {}
      }
    }

    var decodedEntryCount = 0;
    var declaredImportBytes = 0;
    void validateArchiveEntry(ArchiveFile entry) {
      decodedEntryCount++;
      if (decodedEntryCount > effectiveMaxEntryCount) {
        throw StateError('压缩包文件数量超过安全上限 ($effectiveMaxEntryCount)');
      }

      final pathDepth = entry.name
          .split(RegExp(r'[\\/]+'))
          .where((segment) => segment.isNotEmpty)
          .length;
      if (pathDepth > effectiveMaxPathDepth) {
        throw StateError('压缩包目录层级超过安全上限 ($effectiveMaxPathDepth)');
      }

      final isImportableFile =
          LibraryService.isSupportedMediaPath(entry.name) ||
          SubtitleFileMatcher.supportedExtensions.contains(
            p.extension(entry.name).toLowerCase(),
          );
      if (entry.isSymbolicLink || !entry.isFile || !isImportableFile) {
        return;
      }

      final entrySize = entry.size;
      if (entrySize < 0 || entrySize > effectiveMaxSingleFileBytes) {
        throw StateError(
          '压缩包内可导入文件超过单文件安全上限 '
          '(${LibraryService.formatSize(effectiveMaxSingleFileBytes)})',
        );
      }
      declaredImportBytes += entrySize;
      if (declaredImportBytes > effectiveMaxTotalBytes) {
        throw StateError(
          '压缩包内可导入文件总大小超过安全上限 '
          '(${LibraryService.formatSize(effectiveMaxTotalBytes)})',
        );
      }

      final compressedSize = entry.rawContent?.length ?? entrySize;
      if (entrySize > 0 &&
          (compressedSize <= 0 ||
              entrySize > compressedSize * effectiveMaxCompressionRatio)) {
        throw StateError('压缩包内可导入文件压缩比异常，已停止导入以保护设备存储');
      }
    }

    final normalizedDecodedPath = decodedArchivePath.toLowerCase();
    if (normalizedDecodedPath.endsWith('.tar')) {
      final input = InputFileStream(decodedArchivePath);
      inputToClose = input;
      archive = TarDecoder().decodeStream(
        input,
        callback: validateArchiveEntry,
      );
    } else if (normalizedDecodedPath.endsWith('.zip')) {
      final input = InputFileStream(decodedArchivePath);
      inputToClose = input;
      archive = ZipDecoder().decodeStream(
        input,
        callback: validateArchiveEntry,
      );
    } else {
      throw ArgumentError('当前仅支持 zip、tar、tar.gz、tar.bz2、tar.xz 压缩包');
    }

    final normalizedOutputRoot = p.normalize(outputPath);
    final claimedOutputPaths = <String, String>{};
    for (final entry in archive) {
      // Media imports do not need archive links. Skipping every symbolic link
      // also prevents a later entry from traversing a link whose lexical path
      // appears to remain inside the extraction root.
      if (entry.isSymbolicLink) {
        continue;
      }
      final normalizedEntryName = entry.name.replaceAll('\\', '/').trim();
      if (normalizedEntryName.isEmpty ||
          normalizedEntryName == '.' ||
          normalizedEntryName == '/' ||
          normalizedEntryName == Platform.pathSeparator) {
        continue;
      }

      final filePath = _buildArchiveEntryOutputPath(
        outputRoot: normalizedOutputRoot,
        entryName: normalizedEntryName,
        treatAsFile: entry.isFile,
      );
      final isSafePath =
          p.equals(normalizedOutputRoot, filePath) ||
          p.isWithin(normalizedOutputRoot, filePath);
      if (!isSafePath) {
        continue;
      }

      final claimKey = Platform.isWindows ? filePath.toLowerCase() : filePath;
      final previousEntryName = claimedOutputPaths[claimKey];
      if (previousEntryName != null) {
        if (entry.isDirectory && previousEntryName == normalizedEntryName) {
          continue;
        }
        throw StateError(
          '压缩包内存在清理后重名的路径：$previousEntryName / $normalizedEntryName',
        );
      }
      claimedOutputPaths[claimKey] = normalizedEntryName;

      if (entry.isDirectory) {
        Directory(filePath).createSync(recursive: true);
        continue;
      }

      final parentDir = Directory(p.dirname(filePath));
      if (!parentDir.existsSync()) {
        parentDir.createSync(recursive: true);
      }

      if (!entry.isFile) {
        continue;
      }

      // Keep media and supported sidecar subtitles. Other archive contents are
      // intentionally not inflated into the app-managed import directory.
      final isMedia = LibraryService.isSupportedMediaPath(filePath);
      final isSubtitle = SubtitleFileMatcher.supportedExtensions.contains(
        p.extension(filePath).toLowerCase(),
      );
      if (!isMedia && !isSubtitle) {
        skippedNonMediaEntries++;
        continue;
      }

      final output = _BudgetedArchiveOutputStream(
        OutputFileStream(filePath),
        writeBudget,
        effectiveMaxSingleFileBytes,
      );
      try {
        entry.writeContent(output);
      } on FileSystemException catch (e) {
        throw FileSystemException(
          '解压写入失败，可能是压缩包内文件名或路径过长',
          filePath,
          e.osError,
        );
      } finally {
        try {
          output.closeSync();
        } catch (_) {}
      }

      extractedEntries++;
      if (isMedia) extractedMediaEntries++;
      if (isSubtitle) extractedSubtitleEntries++;
    }

    return <String, int>{
      'extractedEntries': extractedEntries,
      'extractedMediaEntries': extractedMediaEntries,
      'extractedSubtitleEntries': extractedSubtitleEntries,
      'skippedNonMediaEntries': skippedNonMediaEntries,
      'writtenBytes': writeBudget.writtenBytes,
    };
  } finally {
    // 严格按顺序释放资源，每个步骤都有独立 try/catch 确保不中断后续清理
    // 1. 先关闭档案对象的内部流
    try {
      archive?.clear();
    } catch (_) {}
    // 2. 再关闭输入流
    try {
      inputToClose?.closeSync();
    } catch (_) {}
    // 3. 最后删除中间解压临时目录（tar.gz/bz2/xz 场景）
    if (tempDir != null) {
      try {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      } catch (_) {}
    }
  }
}
