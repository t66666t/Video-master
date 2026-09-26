import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../models/import_card_placement.dart';
import '../../models/library_activity.dart';
import '../../models/media_source_ref.dart';
import '../../models/video_collection.dart';
import '../../models/video_item.dart';
import '../../services/library_service.dart';
import '../../services/settings_service.dart';
import '../../services/bilibili/bilibili_video_shot_service.dart';
import 'portable_media_selection.dart';
import 'portable_transfer_models.dart';
import 'zip_media_exporter.dart';

class PortableTransferService extends ChangeNotifier {
  PortableTransferService._();

  @visibleForTesting
  PortableTransferService.forTesting();

  static final PortableTransferService instance = PortableTransferService._();
  static const int formatVersion = 2;
  static const String extension = 'fluentpack';
  static const String mimeType = 'application/x-fluent-player-package';
  static const List<String> importPickerExtensions = <String>[
    extension,
    'zip',
    'tar',
    'tgz',
    'gz',
    'tbz',
    'tbz2',
    'bz2',
    'txz',
    'xz',
  ];

  static bool hasPackageExtension(String pathOrName) =>
      p.extension(pathOrName).toLowerCase() == '.$extension';

  final List<PortableTransferTask> _tasks = <PortableTransferTask>[];
  final Map<String, _PortableWorkerControl> _workers =
      <String, _PortableWorkerControl>{};
  final Map<String, _PortableRetrySpec> _retrySpecs =
      <String, _PortableRetrySpec>{};
  Future<void>? _initialization;
  File? _stateFile;
  Timer? _persistTimer;
  Future<void> _persistChain = Future<void>.value();
  List<PortableTransferTask> get tasks => List.unmodifiable(_tasks);

  Future<void> initialize({LibraryService? library}) {
    return _initialization ??= _initializeState(library);
  }

  Future<void> _initializeState(LibraryService? library) async {
    try {
      final support = await getApplicationSupportDirectory();
      final stateDirectory = await Directory(
        p.join(support.path, 'portable_transfer'),
      ).create(recursive: true);
      _stateFile = File(p.join(stateDirectory.path, 'tasks_v1.json'));
      final stateFile = _stateFile!;
      if (await stateFile.exists()) {
        final decoded = jsonDecode(await stateFile.readAsString());
        if (decoded is Map) {
          final rawTasks = decoded['tasks'];
          if (rawTasks is List && _tasks.isEmpty) {
            for (final raw in rawTasks.whereType<Map>()) {
              final task = PortableTransferTask.fromJson(
                Map<String, dynamic>.from(raw),
              );
              if (task.id.isEmpty) continue;
              if (task.isActive) {
                task.status = PortableTransferStatus.failed;
                task.error = '应用在任务完成前退出';
                task.subtitle = '上次运行被中断，可重试';
              }
              _tasks.add(task);
            }
          }
          final rawRetries = decoded['retrySpecs'];
          if (rawRetries is Map) {
            for (final entry in rawRetries.entries) {
              if (entry.value is Map) {
                _retrySpecs[entry.key.toString()] = _PortableRetrySpec.fromJson(
                  Map<String, dynamic>.from(entry.value as Map),
                );
              }
            }
          }
        }
      }
      if (library != null) {
        for (final entry in _retrySpecs.entries) {
          final task = _tasks.where((item) => item.id == entry.key).firstOrNull;
          final rootId = entry.value.transactionRootId;
          if (task?.status == PortableTransferStatus.failed && rootId != null) {
            try {
              await library.deleteFromRecycleBin(<String>[rootId]);
              entry.value.transactionRootId = null;
            } catch (_) {}
          }
          if (task?.status == PortableTransferStatus.failed) {
            await _deleteTrackedAssets(entry.value);
          }
        }
      }
      await _cleanupInterruptedArtifacts();
      await _persistStateNow();
    } catch (_) {
      // Persistence and recovery must never prevent transfers from opening.
    }
    notifyListeners();
  }

  Future<void> _cleanupInterruptedArtifacts() async {
    final referencedSources = _retrySpecs.values
        .where((spec) => spec.kind == PortableTransferKind.import)
        .map((spec) => spec.packagePath)
        .whereType<String>()
        .map(_normalizedTaskPath)
        .toSet();
    final temp = await getTemporaryDirectory();
    final extractionRoot = Directory(p.join(temp.path, 'fluent_transfer'));
    if (await extractionRoot.exists()) {
      try {
        await extractionRoot.delete(recursive: true);
      } catch (_) {}
    }
    final zipScratch = Directory(
      p.join(temp.path, zipExportScratchDirectoryName),
    );
    if (await zipScratch.exists()) {
      try {
        await zipScratch.delete(recursive: true);
      } catch (_) {}
    }
    for (final name in const <String>[
      'fluent_player_portable_imports',
      'picked_fluentpacks',
    ]) {
      final directory = Directory(p.join(temp.path, name));
      if (!await directory.exists()) continue;
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        final normalized = _normalizedTaskPath(entity.path);
        if (entity.path.endsWith('.partial') ||
            !referencedSources.contains(normalized)) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    }
    for (final spec in _retrySpecs.values) {
      if (spec.kind != PortableTransferKind.export || spec.outputPath == null) {
        continue;
      }
      final partial = File('${spec.outputPath}.part');
      if (await partial.exists()) {
        try {
          await partial.delete();
        } catch (_) {}
      }
    }
    try {
      final documents = await getApplicationDocumentsDirectory();
      final exports = Directory(
        p.join(documents.path, 'Fluent Player', 'Exports'),
      );
      if (await exports.exists()) {
        await for (final entity in exports.list(followLinks: false)) {
          if (entity is File && entity.path.endsWith('.part')) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    try {
      final dataRoot = await SettingsService().resolveLargeDataRootDir();
      for (final directory in <Directory>[
        Directory(p.join(dataRoot.path, 'thumbnails')),
        Directory(p.join(dataRoot.path, 'danmaku')),
        Directory(
          p.join(dataRoot.path, BilibiliVideoShotService.directoryName),
        ),
      ]) {
        if (!await directory.exists()) continue;
        await for (final entity in directory.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File && entity.path.endsWith('.partial')) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _deleteTrackedAssets(_PortableRetrySpec spec) async {
    for (final path in spec.createdAssetPaths.toList(growable: false)) {
      final file = File(path);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {
          continue;
        }
      }
      spec.createdAssetPaths.remove(path);
    }
  }

  void _schedulePersist() {
    if (_stateFile == null) return;
    _persistTimer?.cancel();
    _persistTimer = Timer(
      const Duration(milliseconds: 350),
      () => unawaited(_persistStateNow()),
    );
  }

  Future<void> _persistStateNow() {
    final stateFile = _stateFile;
    if (stateFile == null) return Future<void>.value();
    final encoded = jsonEncode(<String, dynamic>{
      'tasks': _tasks.map((task) => task.toJson()).toList(growable: false),
      'retrySpecs': _retrySpecs.map(
        (key, value) => MapEntry(key, value.toJson()),
      ),
    });
    _persistChain = _persistChain
        .then((_) => _writePersistedState(stateFile, encoded))
        .catchError((_) {});
    return _persistChain;
  }

  Future<void> _writePersistedState(File stateFile, String encoded) async {
    final partial = File('${stateFile.path}.partial');
    try {
      await partial.writeAsString(encoded, flush: true);
      if (await stateFile.exists()) await stateFile.delete();
      await partial.rename(stateFile.path);
    } catch (_) {
      if (await partial.exists()) {
        try {
          await partial.delete();
        } catch (_) {}
      }
    }
  }

  PortableTransferTask _newTask(
    PortableTransferKind kind,
    String title,
    String subtitle,
  ) {
    final task = PortableTransferTask(
      id: const Uuid().v4(),
      kind: kind,
      title: title,
      subtitle: subtitle,
      createdAt: DateTime.now(),
    );
    _tasks.insert(0, task);
    notifyListeners();
    return task;
  }

  void cancel(String id) {
    final task = _tasks.where((item) => item.id == id).firstOrNull;
    if (task == null || !task.isActive) return;
    task.cancelRequested = true;
    task.subtitle = '正在安全停止…';
    ZipExportRuntime.cancel(id);
    _workers[task.id]?.cancel();
    _schedulePersist();
    notifyListeners();
  }

  bool canRetry(String id) {
    final task = _tasks.where((item) => item.id == id).firstOrNull;
    return task != null &&
        !task.isActive &&
        task.status != PortableTransferStatus.completed &&
        _retrySpecs.containsKey(id);
  }

  Future<void> retryTask(String id, LibraryService library) async {
    await initialize(library: library);
    final task = _tasks.where((item) => item.id == id).firstOrNull;
    final spec = _retrySpecs[id];
    if (task == null || spec == null || task.isActive) return;
    task
      ..status = PortableTransferStatus.queued
      ..progress = 0
      ..processedBytes = 0
      ..cancelRequested = false
      ..error = null
      ..subtitle = '正在重新准备…';
    await _persistStateNow();
    notifyListeners();
    if (spec.kind == PortableTransferKind.export) {
      unawaited(
        _runExport(
          task,
          library,
          spec.rootIds!,
          spec.outputPath!,
          spec.options!,
        ),
      );
      return;
    }
    if (spec.transactionRootId != null) {
      try {
        await library.deleteFromRecycleBin(<String>[spec.transactionRootId!]);
        spec.transactionRootId = null;
        await _persistStateNow();
      } catch (error) {
        task
          ..status = PortableTransferStatus.failed
          ..subtitle = '清理上次导入失败'
          ..error = error.toString();
        await _persistStateNow();
        notifyListeners();
        return;
      }
    }
    final packagePath = spec.packagePath!;
    if (!await File(packagePath).exists()) {
      task
        ..status = PortableTransferStatus.failed
        ..subtitle = '无法重试'
        ..error = spec.isArchive ? '原始压缩包已不存在' : '原始 FluentPack 文件已不存在';
      await _persistStateNow();
      notifyListeners();
      return;
    }
    if (spec.isArchive) {
      unawaited(
        _runArchiveImport(
          task,
          library,
          packagePath,
          sortOptions: StructuredImportSortOptions(
            field: spec.archiveSortField == 'modifiedTime'
                ? StructuredImportSortField.modifiedTime
                : StructuredImportSortField.fileName,
            direction: spec.archiveSortDirection == 'descending'
                ? StructuredImportSortDirection.descending
                : StructuredImportSortDirection.ascending,
          ),
          deleteArchiveWhenDone: spec.deletePackageWhenDone,
          libraryFolderId: spec.libraryFolderId,
        ),
      );
      return;
    }
    unawaited(
      _runImport(
        task,
        library,
        packagePath,
        deletePackageWhenDone: spec.deletePackageWhenDone,
        libraryFolderId: spec.libraryFolderId,
      ),
    );
  }

  void remove(String id) {
    _tasks.removeWhere((task) => task.id == id && !task.isActive);
    notifyListeners();
  }

  Future<PortableTaskRemovalResult> removeTasks(
    Iterable<String> ids, {
    bool deleteFiles = true,
  }) async {
    final requestedIds = ids.toSet();
    final targets = _tasks
        .where((task) => requestedIds.contains(task.id) && !task.isActive)
        .toList(growable: false);
    if (targets.isEmpty) {
      return const PortableTaskRemovalResult(
        removedTaskCount: 0,
        deletedFileCount: 0,
      );
    }

    final failedPaths = <String>[];
    final failedNormalizedPaths = <String>{};
    var deletedFileCount = 0;
    if (deleteFiles) {
      final paths = targets
          .map((task) => task.filePath?.trim())
          .whereType<String>()
          .where((path) => path.isNotEmpty)
          .toSet();
      for (final path in paths) {
        final normalized = _normalizedTaskPath(path);
        final file = File(path);
        try {
          if (await file.exists()) {
            await file.delete();
            deletedFileCount++;
          }
        } catch (_) {
          failedPaths.add(path);
          failedNormalizedPaths.add(normalized);
        }
      }
    }

    final removableIds = targets
        .where((task) {
          if (!deleteFiles || failedNormalizedPaths.isEmpty) return true;
          final path = task.filePath?.trim();
          return path == null ||
              path.isEmpty ||
              !failedNormalizedPaths.contains(_normalizedTaskPath(path));
        })
        .map((task) => task.id)
        .toSet();
    _tasks.removeWhere((task) => removableIds.contains(task.id));
    for (final id in removableIds) {
      _retrySpecs.remove(id);
    }
    _schedulePersist();
    notifyListeners();
    return PortableTaskRemovalResult(
      removedTaskCount: removableIds.length,
      deletedFileCount: deletedFileCount,
      failedFilePaths: List<String>.unmodifiable(failedPaths),
    );
  }

  void clearFinished() {
    final removedIds = _tasks
        .where((task) => !task.isActive)
        .map((task) => task.id)
        .toList(growable: false);
    _tasks.removeWhere((task) => removedIds.contains(task.id));
    for (final id in removedIds) {
      _retrySpecs.remove(id);
    }
    _schedulePersist();
    notifyListeners();
  }

  static String _normalizedTaskPath(String path) {
    final normalized = p.normalize(File(path).absolute.path);
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  Future<PortableTransferTask> exportSelection({
    required LibraryService library,
    required List<String> rootIds,
    required String outputPath,
    required PortableExportOptions options,
  }) async {
    await initialize(library: library);
    final task = _newTask(
      PortableTransferKind.export,
      options.packageName,
      '正在整理 ${rootIds.length} 个项目…',
    );
    task.filePath = outputPath;
    _retrySpecs[task.id] = _PortableRetrySpec.export(
      rootIds: rootIds,
      outputPath: outputPath,
      options: options,
    );
    await _persistStateNow();
    unawaited(_runExport(task, library, rootIds, outputPath, options));
    return task;
  }

  Future<void> _runExport(
    PortableTransferTask task,
    LibraryService library,
    List<String> rootIds,
    String outputPath,
    PortableExportOptions options,
  ) async {
    if (options.format == PortableExportFormat.zip) {
      await _runZipExport(task, library, rootIds, outputPath, options);
      return;
    }
    final partial = File('$outputPath.part');
    PortableTransferStatus? terminalStatus;
    String? terminalSubtitle;
    String? terminalError;
    try {
      task.status = PortableTransferStatus.preparing;
      notifyListeners();
      final plan = await _buildExportPlan(library, rootIds, options, task);
      task.itemCount = plan.mediaCount;
      task.totalBytes = plan.totalBytes;
      task.subtitle = '准备写入 ${plan.files.length} 个文件';
      notifyListeners();

      if (await partial.exists()) await partial.delete();
      await partial.parent.create(recursive: true);
      final level = switch (options.compression) {
        PortableCompression.fast => ZipFileEncoder.store,
        PortableCompression.balanced => 3,
        PortableCompression.smallest => 9,
      };
      task.status = PortableTransferStatus.running;
      task.subtitle = options.verifyChecksums ? '正在计算完整性校验…' : '开始打包';
      notifyListeners();
      await _runWorker(
        task: task,
        entryPoint: _portableExportWorker,
        payload: <String, dynamic>{
          'partialPath': partial.path,
          'level': level,
          'verifyChecksums': options.verifyChecksums,
          'manifestPath': plan.manifestPath,
          'manifest': plan.manifest,
          'files': plan.files
              .map(
                (entry) => <String, dynamic>{
                  'sourcePath': entry.file.path,
                  'archivePath': entry.archivePath,
                  'size': entry.size,
                },
              )
              .toList(growable: false),
          'totalBytes': plan.totalBytes,
        },
      );
      if (task.cancelRequested) throw const _TransferCancelled();
      final target = File(outputPath);
      if (await target.exists()) await target.delete();
      await partial.rename(outputPath);
      task.progress = 1;
      terminalStatus = PortableTransferStatus.completed;
      terminalSubtitle =
          '${plan.mediaCount} 个媒体 · ${_formatBytes(await target.length())}';
      _retrySpecs.remove(task.id);
    } on _TransferCancelled {
      terminalStatus = PortableTransferStatus.cancelled;
      terminalSubtitle = '已取消，没留下半成品';
    } catch (error) {
      terminalStatus = PortableTransferStatus.failed;
      terminalError = error.toString();
      terminalSubtitle = '导出失败';
    } finally {
      if (terminalStatus != PortableTransferStatus.completed &&
          await partial.exists()) {
        try {
          await partial.delete();
        } catch (_) {}
      }
      task.status = terminalStatus ?? PortableTransferStatus.failed;
      task.subtitle = terminalSubtitle ?? '导出失败';
      task.error = terminalError;
      await _persistStateNow();
      notifyListeners();
    }
  }

  Future<void> _runZipExport(
    PortableTransferTask task,
    LibraryService library,
    List<String> rootIds,
    String outputPath,
    PortableExportOptions options,
  ) async {
    final partial = File('$outputPath.part');
    PortableTransferStatus? terminalStatus;
    String? terminalSubtitle;
    String? terminalError;
    try {
      task.status = PortableTransferStatus.preparing;
      task.progress = 0;
      task.subtitle = '正在整理 ${rootIds.length} 个项目…';
      notifyListeners();
      final result = await ZipMediaExporter().run(
        library: library,
        rootIds: rootIds,
        partialPath: partial.path,
        options: options,
        taskId: task.id,
        isCancelled: () => task.cancelRequested,
        onProgress: (progress, subtitle, processedBytes, totalBytes) {
          if (task.cancelRequested) return;
          task.status = PortableTransferStatus.running;
          task.progress = progress.clamp(0, 0.99);
          task.subtitle = subtitle;
          task.processedBytes = processedBytes;
          task.totalBytes = totalBytes;
          notifyListeners();
        },
      );
      if (task.cancelRequested) throw const PortableExportCancelled();
      if (!await partial.exists()) {
        throw StateError('导出文件没有写完');
      }
      final target = File(outputPath);
      if (await target.exists()) await target.delete();
      await partial.rename(outputPath);
      task
        ..progress = 1
        ..itemCount = result.mediaCount
        ..totalBytes = await target.length();
      terminalStatus = PortableTransferStatus.completed;
      terminalSubtitle = result.summary(task.totalBytes);
      _retrySpecs.remove(task.id);
    } on PortableExportCancelled {
      terminalStatus = PortableTransferStatus.cancelled;
      terminalSubtitle = '已取消，没留下半成品';
    } on _TransferCancelled {
      terminalStatus = PortableTransferStatus.cancelled;
      terminalSubtitle = '已取消，没留下半成品';
    } catch (error) {
      terminalStatus = PortableTransferStatus.failed;
      terminalError = error.toString();
      terminalSubtitle = '导出失败';
    } finally {
      if (terminalStatus != PortableTransferStatus.completed &&
          await partial.exists()) {
        try {
          await partial.delete();
        } catch (_) {}
      }
      task.status = terminalStatus ?? PortableTransferStatus.failed;
      task.subtitle = terminalSubtitle ?? '导出失败';
      task.error = terminalError;
      await _persistStateNow();
      notifyListeners();
    }
  }

  Future<_ExportPlan> _buildExportPlan(
    LibraryService library,
    List<String> rootIds,
    PortableExportOptions options,
    PortableTransferTask task,
  ) async {
    final files = <_PackageFile>[];
    final checksums = <String, String>{};
    final collectionRecords = <Map<String, dynamic>>[];
    final videoRecords = <Map<String, dynamic>>[];
    final usedPaths = <String>{};
    final packagedSourcePaths = <String, String>{};
    var mediaCount = 0;
    var folderCount = 0;
    var totalBytes = 0;
    final rootPrefix = options.wrapInFolder
        ? '${_safeName(options.packageName)}/'
        : '';

    Future<String?> addFile(String sourcePath, String relativePath) async {
      if (task.cancelRequested) throw const _TransferCancelled();
      final source = File(sourcePath);
      if (!await source.exists()) return null;
      final normalizedSource = p.normalize(source.path);
      final sourceKey = Platform.isWindows
          ? normalizedSource.toLowerCase()
          : normalizedSource;
      final existing = packagedSourcePaths[sourceKey];
      if (existing != null) return existing;
      var archivePath = '$rootPrefix${_safeRelativePath(relativePath)}';
      archivePath = _uniqueArchivePath(archivePath, usedPaths);
      final size = await source.length();
      files.add(_PackageFile(source, archivePath, size));
      totalBytes += size;
      packagedSourcePaths[sourceKey] = archivePath;
      return archivePath;
    }

    String? assetReference(String? archivePath) =>
        archivePath == null ? null : '@asset:$archivePath';

    Future<String?> packageAsset(
      String? sourcePath,
      String relativePath,
    ) async {
      if (sourcePath == null || sourcePath.trim().isEmpty) return null;
      return assetReference(await addFile(sourcePath, relativePath));
    }

    Future<Map<String, String>?> packageSubtitleMap(
      Map<String, String>? source,
      String cardAssetPath,
    ) async {
      if (source == null) return null;
      final result = <String, String>{};
      for (final entry in source.entries) {
        final ref = await packageAsset(
          entry.value,
          p.posix.join(cardAssetPath, 'subtitles', p.basename(entry.value)),
        );
        if (ref != null) result[entry.key] = ref;
      }
      return result;
    }

    Future<void> addVideo(
      VideoItem item,
      String? parentExportId,
      String parentPath,
    ) async {
      if (task.cancelRequested) throw const _TransferCancelled();
      final exportId = item.id;
      final isOnline =
          item.sourceRef?.kind == MediaSourceKind.bilibiliStream ||
          item.path.startsWith('bilibili://stream/');
      final videoJson = Map<String, dynamic>.from(item.toJson());
      final cardAssetPath = p.posix.join('assets', 'cards', exportId);
      final mediaName = _safeName(
        p.basename(item.path).isEmpty || isOnline
            ? '${item.title}${item.type == MediaType.audio ? '.m4a' : '.mp4'}'
            : p.basename(item.path),
      );

      if (isOnline) {
        videoJson['path'] = item.path;
      } else {
        final primary = await packageAsset(
          item.path,
          p.posix.join(parentPath, mediaName),
        );
        if (primary == null) return;
        videoJson['path'] = primary;
      }
      mediaCount++;
      videoJson['id'] = exportId;
      videoJson['parentId'] = parentExportId;
      videoJson['isRecycled'] = false;
      videoJson['recycleTime'] = null;
      videoJson['playbackPath'] = null;
      videoJson['sourceFingerprint'] = null;
      videoJson['recycledSelectedSubtitlePaths'] = null;
      videoJson['recycledExtraSubtitles'] = null;
      videoJson['recycledLocalSubtitles'] = null;

      videoJson['thumbnailPath'] = await packageAsset(
        item.thumbnailPath,
        p.posix.join(
          cardAssetPath,
          'cover${p.extension(item.thumbnailPath ?? '').isEmpty ? '.jpg' : p.extension(item.thumbnailPath!)}',
        ),
      );

      if (options.includeSidecars) {
        videoJson['subtitlePath'] = await packageAsset(
          item.subtitlePath,
          p.posix.join(
            cardAssetPath,
            'subtitles',
            p.basename(item.subtitlePath ?? 'primary.srt'),
          ),
        );
        videoJson['secondarySubtitlePath'] = await packageAsset(
          item.secondarySubtitlePath,
          p.posix.join(
            cardAssetPath,
            'subtitles',
            p.basename(item.secondarySubtitlePath ?? 'secondary.srt'),
          ),
        );
        videoJson['danmakuPath'] = await packageAsset(
          item.danmakuPath,
          p.posix.join(
            cardAssetPath,
            'danmaku',
            p.basename(item.danmakuPath ?? 'danmaku.ass'),
          ),
        );
        videoJson['extraSubtitles'] = await packageSubtitleMap(
          item.additionalSubtitles,
          cardAssetPath,
        );
        videoJson['localSubtitles'] = await packageSubtitleMap(
          item.localSubtitles,
          cardAssetPath,
        );

        final managed = <Map<String, dynamic>>[];
        for (final asset in item.managedSubtitleAssets) {
          final ref = await packageAsset(
            asset.path,
            p.posix.join(cardAssetPath, 'subtitles', p.basename(asset.path)),
          );
          if (ref != null) {
            managed.add(<String, dynamic>{...asset.toJson(), 'path': ref});
          }
        }
        videoJson['managedSubtitleAssets'] = managed;

        final shot = item.bilibiliVideoShot;
        if (shot != null) {
          final spriteRefs = <String>[];
          for (var index = 0; index < shot.spritePaths.length; index++) {
            final source = shot.spritePaths[index];
            final ref = await packageAsset(
              source,
              p.posix.join(
                cardAssetPath,
                'videoshot',
                'sprite_${index.toString().padLeft(3, '0')}${p.extension(source)}',
              ),
            );
            if (ref != null) spriteRefs.add(ref);
          }
          videoJson['bilibiliVideoShot'] = spriteRefs.isEmpty
              ? null
              : <String, dynamic>{...shot.toJson(), 'spritePaths': spriteRefs};
        }
      } else {
        videoJson['subtitlePath'] = null;
        videoJson['secondarySubtitlePath'] = null;
        videoJson['danmakuPath'] = null;
        videoJson['extraSubtitles'] = null;
        videoJson['localSubtitles'] = null;
        videoJson['managedSubtitleAssets'] = <dynamic>[];
        videoJson['bilibiliVideoShot'] = null;
      }

      videoRecords.add(<String, dynamic>{
        'exportId': exportId,
        'parentExportId': parentExportId,
        'isOnline': isOnline,
        'video': videoJson,
      });
    }

    final inclusion = PortableMediaSelection(
      rootIds,
    ).resolveAgainstLibrary(library);
    final visited = <String>{};

    Future<void> walk(
      String id,
      String? parentExportId,
      String parentPath,
    ) async {
      if (task.cancelRequested) throw const _TransferCancelled();
      if (!visited.add(id)) return;
      final collection = library.getCollection(id);
      if (collection != null && !collection.isRecycled) {
        if (!inclusion.collectionIds.contains(id)) {
          // Folders above the selection's lowest common ancestor are omitted
          // so a nested export does not recreate unused outer shells. Walk
          // through them without emitting a collection record.
          for (final childId in collection.childrenIds) {
            await walk(childId, parentExportId, parentPath);
          }
          return;
        }
        folderCount++;
        final ownPath = p.posix.join(parentPath, _safeName(collection.name));
        final thumbnailRef = await packageAsset(
          collection.thumbnailPath,
          p.posix.join(
            'assets',
            'collections',
            collection.id,
            'cover${p.extension(collection.thumbnailPath ?? '').isEmpty ? '.jpg' : p.extension(collection.thumbnailPath!)}',
          ),
        );
        collectionRecords.add(<String, dynamic>{
          'exportId': collection.id,
          'parentExportId': parentExportId,
          'name': collection.name,
          'createTime': collection.createTime,
          'thumbnailPath': thumbnailRef,
          'coverLabel': collection.coverLabel,
          'sourceRef': collection.sourceRef?.toJson(),
        });
        for (final childId in collection.childrenIds) {
          await walk(childId, collection.id, ownPath);
        }
        return;
      }
      final video = library.getVideo(id);
      if (video != null &&
          !video.isRecycled &&
          inclusion.videoIds.contains(id)) {
        await addVideo(video, parentExportId, parentPath);
      }
    }

    for (final item in library.getContents(null)) {
      final id = item is VideoCollection ? item.id : (item as VideoItem).id;
      await walk(id, null, '');
    }
    // Orphaned selection roots that are not reachable from the library root
    // still need a chance to be packed at the package root.
    for (final id in [...inclusion.collectionIds, ...inclusion.videoIds]) {
      if (!visited.contains(id)) {
        await walk(id, null, '');
      }
    }
    if (collectionRecords.isEmpty && videoRecords.isEmpty) {
      throw StateError('所选项目中没有可导出的内容');
    }
    final manifestPath = '${rootPrefix}manifest.json';
    final manifest = <String, dynamic>{
      'format': 'fluent-player-portable-package',
      'formatVersion': formatVersion,
      'packageName': options.packageName,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'mediaCount': mediaCount,
      'folderCount': folderCount,
      'fileCount': files.length,
      'totalBytes': totalBytes,
      'wrappedInFolder': options.wrapInFolder,
      'checksums': checksums,
      'snapshot': <String, dynamic>{
        'collections': collectionRecords,
        'videos': videoRecords,
      },
    };
    return _ExportPlan(
      files: files,
      manifest: manifest,
      manifestPath: manifestPath,
      mediaCount: mediaCount,
      totalBytes: totalBytes,
    );
  }

  Future<PortablePackagePreview> inspectPackage(String packagePath) async {
    if (!hasPackageExtension(packagePath)) {
      throw const FormatException('只能导入 .fluentpack 文件');
    }
    final raw = await Isolate.run(
      () => _inspectPortablePackageWorker(<String, dynamic>{
        'packagePath': packagePath,
        'supportedVersion': formatVersion,
      }),
    );
    return PortablePackagePreview(
      packageName: raw['packageName'] as String,
      createdAt: DateTime.parse(raw['createdAt'] as String),
      mediaCount: raw['mediaCount'] as int,
      folderCount: raw['folderCount'] as int,
      fileCount: raw['fileCount'] as int,
      totalBytes: raw['totalBytes'] as int,
      hasChecksums: raw['hasChecksums'] as bool,
      formatVersion: raw['formatVersion'] as int,
    );
  }

  Future<PortableTransferTask> importPackage({
    required LibraryService library,
    required String packagePath,
    required PortablePackagePreview preview,
    bool deletePackageWhenDone = false,
    String? libraryFolderId,
  }) async {
    await initialize(library: library);
    final task = _newTask(
      PortableTransferKind.import,
      preview.packageName,
      '正在检查导出包…',
    );
    task.filePath = packagePath;
    task.itemCount = preview.mediaCount;
    task.totalBytes = preview.totalBytes;
    _retrySpecs[task.id] = _PortableRetrySpec.import(
      packagePath: packagePath,
      preview: preview,
      deletePackageWhenDone: deletePackageWhenDone,
      libraryFolderId: libraryFolderId,
    );
    await _persistStateNow();
    unawaited(
      _runImport(
        task,
        library,
        packagePath,
        deletePackageWhenDone: deletePackageWhenDone,
        libraryFolderId: libraryFolderId,
      ),
    );
    return task;
  }

  Future<PortableTransferTask> importArchive({
    required LibraryService library,
    required String archivePath,
    required String displayName,
    bool deleteArchiveWhenDone = false,
    String? libraryFolderId,
  }) async {
    if (!LibraryService.isSupportedArchivePath(displayName) &&
        !LibraryService.isSupportedArchivePath(archivePath)) {
      throw UnsupportedError('当前仅支持 zip、tar、tar.gz、tar.bz2、tar.xz 压缩包');
    }
    await initialize(library: library);
    final sortOptions = StructuredImportSortOptions.fromSettings(
      SettingsService(),
    );
    final titleSource = displayName.trim().isNotEmpty
        ? displayName
        : archivePath;
    final task = _newTask(
      PortableTransferKind.import,
      LibraryService.archiveRootCollectionName(titleSource),
      '正在准备解压…',
    );
    task.filePath = archivePath;
    final archiveFile = File(archivePath);
    if (await archiveFile.exists()) {
      task.totalBytes = await archiveFile.length();
    }
    _retrySpecs[task.id] = _PortableRetrySpec.archive(
      archivePath: archivePath,
      displayName: displayName,
      sortOptions: sortOptions,
      deleteArchiveWhenDone: deleteArchiveWhenDone,
      libraryFolderId: libraryFolderId,
    );
    await _persistStateNow();
    unawaited(
      _runArchiveImport(
        task,
        library,
        archivePath,
        sortOptions: sortOptions,
        deleteArchiveWhenDone: deleteArchiveWhenDone,
        libraryFolderId: libraryFolderId,
      ),
    );
    return task;
  }

  Future<void> _runArchiveImport(
    PortableTransferTask task,
    LibraryService library,
    String archivePath, {
    required StructuredImportSortOptions sortOptions,
    bool deleteArchiveWhenDone = false,
    String? libraryFolderId,
  }) async {
    VoidCallback? progressListener;
    PortableTransferStatus? terminalStatus;
    String? terminalSubtitle;
    String? terminalError;
    try {
      if (task.cancelRequested) throw const _TransferCancelled();
      task
        ..status = PortableTransferStatus.preparing
        ..progress = 0.4;
      notifyListeners();
      progressListener = () {
        final status = library.importStatus.value.trim();
        final extracting = status.contains('准备解压') || status.contains('后台解压');
        task.status = extracting
            ? PortableTransferStatus.preparing
            : PortableTransferStatus.running;
        task.progress = extracting
            ? 0.4
            : 0.4 + library.importProgress.value * 0.6;
        task.subtitle = status.isEmpty ? '正在解压并导入…' : status;
        notifyListeners();
      };
      library.importProgress.addListener(progressListener);
      library.importStatus.addListener(progressListener);
      final result = await library.importArchiveSelection(
        archivePath,
        libraryFolderId,
        sortOptions: sortOptions,
      );
      task.progress = 1;
      task.itemCount = result.affectedMediaCount;
      terminalStatus = PortableTransferStatus.completed;
      terminalSubtitle = '已导入 ${result.affectedMediaCount} 个媒体';
      _retrySpecs.remove(task.id);
    } on _TransferCancelled {
      terminalStatus = PortableTransferStatus.cancelled;
      terminalSubtitle = '已取消';
    } catch (error) {
      terminalStatus = PortableTransferStatus.failed;
      terminalError = error.toString();
      terminalSubtitle = '导入失败';
    } finally {
      if (progressListener != null) {
        library.importProgress.removeListener(progressListener);
        library.importStatus.removeListener(progressListener);
      }
      if (deleteArchiveWhenDone &&
          terminalStatus == PortableTransferStatus.completed) {
        final materializedArchive = File(archivePath);
        if (await materializedArchive.exists()) {
          try {
            await materializedArchive.delete();
          } catch (_) {}
        }
      }
      task.status = terminalStatus ?? PortableTransferStatus.failed;
      task.subtitle = terminalSubtitle ?? '导入失败';
      task.error = terminalError;
      await _persistStateNow();
      notifyListeners();
    }
  }

  Future<void> _runImport(
    PortableTransferTask task,
    LibraryService library,
    String packagePath, {
    bool deletePackageWhenDone = false,
    String? libraryFolderId,
  }) async {
    Directory? extractDir;
    VoidCallback? progressListener;
    PortableTransferStatus? terminalStatus;
    String? terminalSubtitle;
    String? terminalError;
    try {
      task.status = PortableTransferStatus.preparing;
      notifyListeners();
      final temp = await getTemporaryDirectory();
      extractDir = await Directory(
        p.join(temp.path, 'fluent_transfer', task.id),
      ).create(recursive: true);
      final manifest = await _runWorker(
        task: task,
        entryPoint: _portableImportWorker,
        payload: <String, dynamic>{
          'packagePath': packagePath,
          'extractionPath': extractDir.path,
          'supportedVersion': formatVersion,
        },
      );
      if (task.cancelRequested) throw const _TransferCancelled();
      final snapshot = manifest['snapshot'];
      if (snapshot is Map) {
        final imported = await _importSnapshot(
          library: library,
          extraction: extractDir,
          packageName: task.title,
          snapshot: Map<String, dynamic>.from(snapshot),
          task: task,
          openedFromFolderId: libraryFolderId,
        );
        task.progress = 1;
        task.itemCount = imported;
        terminalStatus = PortableTransferStatus.completed;
        terminalSubtitle = '已导入 $imported 个媒体';
        _retrySpecs.remove(task.id);
        return;
      }
      final contentRoot = await _locateContentRoot(extractDir);
      progressListener = () {
        task.status = PortableTransferStatus.running;
        task.progress = 0.4 + library.importProgress.value * 0.6;
        task.subtitle = library.importStatus.value.isEmpty
            ? '正在写入媒体库…'
            : library.importStatus.value;
        notifyListeners();
      };
      library.importProgress.addListener(progressListener);
      library.importStatus.addListener(progressListener);
      final result = await library.importPortablePackageDirectory(
        contentRoot.path,
        rootCollectionName: task.title,
        mediaEntriesHint: task.itemCount,
        openedFromFolderId: libraryFolderId,
        sortOptions: const StructuredImportSortOptions(
          field: StructuredImportSortField.fileName,
          direction: StructuredImportSortDirection.ascending,
        ),
      );
      final rawMetadata = manifest['mediaMetadata'];
      if (rawMetadata is List && rawMetadata.isNotEmpty) {
        await library.applyPortableMediaMetadata(
          result.importedVideoIds,
          rawMetadata.whereType<Map>().map(
            (record) => Map<String, dynamic>.from(record),
          ),
        );
      }
      task.progress = 1;
      task.itemCount = result.affectedMediaCount;
      terminalStatus = PortableTransferStatus.completed;
      terminalSubtitle = '已导入 ${result.affectedMediaCount} 个媒体';
      _retrySpecs.remove(task.id);
    } on _TransferCancelled {
      terminalStatus = PortableTransferStatus.cancelled;
      terminalSubtitle = '已取消';
    } catch (error) {
      terminalStatus = PortableTransferStatus.failed;
      terminalError = error.toString();
      terminalSubtitle = '导入失败';
    } finally {
      if (progressListener != null) {
        library.importProgress.removeListener(progressListener);
        library.importStatus.removeListener(progressListener);
      }
      if (extractDir != null && await extractDir.exists()) {
        try {
          await extractDir.delete(recursive: true);
        } catch (_) {}
      }
      if (deletePackageWhenDone &&
          terminalStatus == PortableTransferStatus.completed) {
        final materializedPackage = File(packagePath);
        if (await materializedPackage.exists()) {
          try {
            await materializedPackage.delete();
          } catch (_) {}
        }
      }
      task.status = terminalStatus ?? PortableTransferStatus.failed;
      task.subtitle = terminalSubtitle ?? '导入失败';
      task.error = terminalError;
      await _persistStateNow();
      notifyListeners();
    }
  }

  Future<int> _importSnapshot({
    required LibraryService library,
    required Directory extraction,
    required String packageName,
    required Map<String, dynamic> snapshot,
    required PortableTransferTask task,
    String? openedFromFolderId,
  }) async {
    final rawCollections =
        (snapshot['collections'] as List? ?? const <dynamic>[])
            .whereType<Map>()
            .map((value) => Map<String, dynamic>.from(value))
            .toList();
    final rawVideos = (snapshot['videos'] as List? ?? const <dynamic>[])
        .whereType<Map>()
        .map((value) => Map<String, dynamic>.from(value))
        .toList();
    if (rawCollections.isEmpty && rawVideos.isEmpty) {
      throw const FormatException('导出包快照为空');
    }

    final destinationParentId = await library.resolveImportCardParentId(
      feature: ImportCardFeature.fluentPack,
      openedFromFolderId: openedFromFolderId,
    );
    final snapshotBatchId = library.beginImportBatch(
      title: packageName,
      sourceKind: LibraryImportSourceKind.fluentPack,
      targetCollectionId: destinationParentId,
    );

    final dataRoot = await SettingsService().resolveLargeDataRootDir();
    final retrySpec = _retrySpecs[task.id];
    final createdAssetPaths = <String>{};
    Future<String?> copyTrackedAsset({
      required Object? reference,
      required Directory destinationDirectory,
      required String destinationStem,
    }) async {
      final copied = await _copyAssetToManagedStorage(
        extraction: extraction,
        reference: reference,
        destinationDirectory: destinationDirectory,
        destinationStem: destinationStem,
      );
      if (copied != null) {
        createdAssetPaths.add(copied);
        retrySpec?.createdAssetPaths.add(copied);
        if (retrySpec != null) await _persistStateNow();
      }
      return copied;
    }

    final packageRoot = await library.createCollection(
      packageName,
      destinationParentId,
    );
    library.noteImportedCollection(packageRoot.id, batchId: snapshotBatchId);
    if (retrySpec != null) {
      retrySpec.transactionRootId = packageRoot.id;
      await _persistStateNow();
    }
    final idMap = <String, String>{};
    var importedCount = 0;
    var importedCollectionCount = 0;
    try {
      final pending = List<Map<String, dynamic>>.from(rawCollections);
      while (pending.isNotEmpty) {
        var progressed = false;
        for (final record in List<Map<String, dynamic>>.from(pending)) {
          if (task.cancelRequested) throw const _TransferCancelled();
          final exportId = record['exportId']?.toString() ?? '';
          if (exportId.isEmpty) {
            pending.remove(record);
            continue;
          }
          final parentExportId = record['parentExportId']?.toString();
          if (parentExportId != null &&
              parentExportId.isNotEmpty &&
              !idMap.containsKey(parentExportId)) {
            continue;
          }
          final newId = const Uuid().v4();
          final thumbnail = await copyTrackedAsset(
            reference: record['thumbnailPath'],
            destinationDirectory: Directory(
              p.join(dataRoot.path, 'thumbnails'),
            ),
            destinationStem: newId,
          );
          final collection = await library.createCollection(
            record['name']?.toString().trim().isNotEmpty == true
                ? record['name'].toString().trim()
                : '未命名文件夹',
            parentExportId == null || parentExportId.isEmpty
                ? packageRoot.id
                : idMap[parentExportId],
            thumbnailPath: thumbnail,
            coverLabel: record['coverLabel'] is String
                ? record['coverLabel'] as String
                : null,
            sourceRef: MediaSourceRef.fromJsonOrNull(record['sourceRef']),
          );
          idMap[exportId] = collection.id;
          library.noteImportedCollection(
            collection.id,
            batchId: snapshotBatchId,
          );
          pending.remove(record);
          progressed = true;
          importedCollectionCount++;
          if (importedCollectionCount % 16 == 0) {
            task
              ..status = PortableTransferStatus.running
              ..subtitle =
                  '正在恢复文件夹 $importedCollectionCount/${rawCollections.length}';
            notifyListeners();
            await Future<void>.delayed(Duration.zero);
          }
        }
        if (!progressed) {
          throw const FormatException('文件夹层级损坏或存在循环引用');
        }
      }

      for (var index = 0; index < rawVideos.length; index++) {
        if (task.cancelRequested) throw const _TransferCancelled();
        final record = rawVideos[index];
        final rawVideo = record['video'];
        if (rawVideo is! Map) {
          throw const FormatException('媒体卡片数据损坏');
        }
        final videoJson = Map<String, dynamic>.from(rawVideo);
        final newId = const Uuid().v4();
        final parentExportId = record['parentExportId']?.toString();
        videoJson['id'] = newId;
        videoJson['parentId'] = parentExportId == null || parentExportId.isEmpty
            ? packageRoot.id
            : idMap[parentExportId] ?? packageRoot.id;
        videoJson['isRecycled'] = false;
        videoJson['recycleTime'] = null;
        videoJson['playbackPath'] = null;

        final isOnline = record['isOnline'] == true;
        if (!isOnline) {
          final primary = _resolveAssetReference(extraction, videoJson['path']);
          if (primary == null || !await primary.exists()) {
            throw FormatException('媒体文件缺失：${videoJson['title'] ?? newId}');
          }
          videoJson['path'] = primary.path;
          videoJson['sourceFingerprint'] = null;
        } else {
          final source = MediaSourceRef.fromJsonOrNull(videoJson['sourceRef']);
          if (source?.kind != MediaSourceKind.bilibiliStream ||
              source?.bvid?.isNotEmpty != true ||
              source?.cid == null) {
            throw FormatException(
              'Bilibili 在线卡片缺少 bvid/cid：${videoJson['title'] ?? newId}',
            );
          }
          videoJson['path'] =
              'bilibili://stream/${source!.bvid}?cid=${source.cid}';
          videoJson['sourceFingerprint'] = 'bilibili-stream-card:$newId';
        }

        videoJson['thumbnailPath'] = await copyTrackedAsset(
          reference: videoJson['thumbnailPath'],
          destinationDirectory: Directory(p.join(dataRoot.path, 'thumbnails')),
          destinationStem: newId,
        );
        videoJson['danmakuPath'] = await copyTrackedAsset(
          reference: videoJson['danmakuPath'],
          destinationDirectory: Directory(p.join(dataRoot.path, 'danmaku')),
          destinationStem: '${newId}_danmaku',
        );

        final additional = _resolveAssetMap(
          extraction,
          videoJson['extraSubtitles'],
        );
        final local = _resolveAssetMap(extraction, videoJson['localSubtitles']);
        final rawManagedAssets = videoJson['managedSubtitleAssets'];
        if (rawManagedAssets is List) {
          for (final rawAsset in rawManagedAssets.whereType<Map>()) {
            final asset = Map<String, dynamic>.from(rawAsset);
            final file = _resolveAssetReference(extraction, asset['path']);
            if (file != null && await file.exists()) {
              final label = asset['displayName']?.toString().trim();
              local.putIfAbsent(
                label?.isNotEmpty == true ? label! : p.basename(file.path),
                () => file.path,
              );
            }
          }
        }
        final primarySubtitle = _resolveAssetReference(
          extraction,
          videoJson['subtitlePath'],
        );
        final secondarySubtitle = _resolveAssetReference(
          extraction,
          videoJson['secondarySubtitlePath'],
        );
        if (primarySubtitle != null) {
          additional.putIfAbsent(
            p.basename(primarySubtitle.path),
            () => primarySubtitle.path,
          );
          videoJson['subtitlePath'] = primarySubtitle.path;
        } else {
          videoJson['subtitlePath'] = null;
        }
        if (secondarySubtitle != null) {
          local.putIfAbsent(
            p.basename(secondarySubtitle.path),
            () => secondarySubtitle.path,
          );
          videoJson['secondarySubtitlePath'] = secondarySubtitle.path;
        } else {
          videoJson['secondarySubtitlePath'] = null;
        }
        videoJson['extraSubtitles'] = additional.isEmpty ? null : additional;
        videoJson['localSubtitles'] = local.isEmpty ? null : local;
        // addSingleVideo rebuilds card-owned subtitle assets with fresh IDs.
        videoJson['managedSubtitleAssets'] = <dynamic>[];

        final rawShot = videoJson['bilibiliVideoShot'];
        if (rawShot is Map) {
          final shotJson = Map<String, dynamic>.from(rawShot);
          final spriteRefs = shotJson['spritePaths'];
          final copiedSprites = <String>[];
          if (spriteRefs is List) {
            final shotDir = Directory(
              p.join(
                dataRoot.path,
                BilibiliVideoShotService.directoryName,
                newId,
              ),
            );
            for (
              var spriteIndex = 0;
              spriteIndex < spriteRefs.length;
              spriteIndex++
            ) {
              if (task.cancelRequested) throw const _TransferCancelled();
              final copied = await copyTrackedAsset(
                reference: spriteRefs[spriteIndex],
                destinationDirectory: shotDir,
                destinationStem:
                    'sprite_${spriteIndex.toString().padLeft(3, '0')}',
              );
              if (copied != null) copiedSprites.add(copied);
            }
          }
          shotJson['spritePaths'] = copiedSprites;
          videoJson['bilibiliVideoShot'] = copiedSprites.isEmpty
              ? null
              : shotJson;
        }

        final item = VideoItem.fromJson(videoJson);
        final insertedId = await library.addSingleVideo(
          item,
          useOriginalPath: false,
          reuseExistingItem: false,
          activityBatchId: snapshotBatchId,
          sourceKind: LibraryImportSourceKind.fluentPack,
        );
        if (insertedId == null) {
          throw StateError('无法创建媒体卡片：${item.title}');
        }
        importedCount++;
        task.status = PortableTransferStatus.running;
        task.progress = 0.4 + ((index + 1) / rawVideos.length * 0.6);
        task.subtitle = '正在恢复卡片 ${index + 1}/${rawVideos.length}';
        notifyListeners();
        if ((index + 1) % 8 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      if (retrySpec != null) {
        retrySpec
          ..transactionRootId = null
          ..createdAssetPaths.clear();
      }
      if (snapshotBatchId != null) {
        await library.completeImportBatch(snapshotBatchId);
      }
      return importedCount;
    } catch (_) {
      if (snapshotBatchId != null) {
        library.abortImportBatch(snapshotBatchId);
      }
      await library.deleteFromRecycleBin(<String>[packageRoot.id]);
      for (final assetPath in createdAssetPaths) {
        final file = File(assetPath);
        if (await file.exists()) {
          try {
            await file.delete();
          } catch (_) {}
        }
      }
      if (retrySpec != null) {
        retrySpec
          ..transactionRootId = null
          ..createdAssetPaths.clear();
        await _persistStateNow();
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _runWorker({
    required PortableTransferTask task,
    required void Function(Map<String, dynamic>) entryPoint,
    required Map<String, dynamic> payload,
  }) async {
    final messages = ReceivePort();
    final errors = ReceivePort();
    final completer = Completer<Map<String, dynamic>>();
    late final StreamSubscription<dynamic> messageSubscription;
    late final StreamSubscription<dynamic> errorSubscription;
    final isolate = await Isolate.spawn<Map<String, dynamic>>(
      entryPoint,
      <String, dynamic>{...payload, 'sendPort': messages.sendPort},
      onError: errors.sendPort,
      errorsAreFatal: true,
      debugName: 'portable-${task.kind.name}-${task.id}',
    );
    final control = _PortableWorkerControl(isolate, completer);
    _workers[task.id] = control;
    messageSubscription = messages.listen((dynamic raw) {
      if (raw is! Map) return;
      final message = Map<String, dynamic>.from(raw);
      switch (message['type']) {
        case 'progress':
          if (completer.isCompleted) return;
          task.status = PortableTransferStatus.running;
          task.progress = ((message['progress'] as num?)?.toDouble() ?? 0)
              .clamp(0, 0.99);
          task.processedBytes =
              (message['processedBytes'] as num?)?.toInt() ??
              task.processedBytes;
          task.subtitle = message['subtitle']?.toString() ?? task.subtitle;
          notifyListeners();
        case 'done':
          if (!completer.isCompleted) {
            final result = message['result'];
            completer.complete(
              result is Map
                  ? Map<String, dynamic>.from(result)
                  : <String, dynamic>{},
            );
          }
        case 'error':
          if (!completer.isCompleted) {
            final text = message['message']?.toString() ?? '后台处理失败';
            completer.completeError(
              message['format'] == true
                  ? FormatException(text)
                  : StateError(text),
            );
          }
      }
    });
    errorSubscription = errors.listen((dynamic raw) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('后台处理异常：$raw'));
      }
    });
    if (task.cancelRequested) control.cancel();
    try {
      return await completer.future;
    } finally {
      _workers.remove(task.id);
      isolate.kill(priority: Isolate.immediate);
      await messageSubscription.cancel();
      await errorSubscription.cancel();
      messages.close();
      errors.close();
    }
  }

  File? _resolveAssetReference(Directory extraction, Object? reference) {
    final value = reference?.toString() ?? '';
    if (!value.startsWith('@asset:')) return null;
    final relative = value.substring('@asset:'.length).replaceAll('\\', '/');
    final candidate = File(
      p.normalize(p.join(extraction.path, p.joinAll(relative.split('/')))),
    );
    if (!p.isWithin(extraction.path, candidate.path)) {
      throw const FormatException('资产路径越界');
    }
    return candidate;
  }

  Map<String, String> _resolveAssetMap(Directory extraction, Object? rawMap) {
    final result = <String, String>{};
    if (rawMap is! Map) return result;
    for (final entry in rawMap.entries) {
      final file = _resolveAssetReference(extraction, entry.value);
      if (file != null && file.existsSync()) {
        result[entry.key.toString()] = file.path;
      }
    }
    return result;
  }

  Future<String?> _copyAssetToManagedStorage({
    required Directory extraction,
    required Object? reference,
    required Directory destinationDirectory,
    required String destinationStem,
  }) async {
    final source = _resolveAssetReference(extraction, reference);
    if (source == null || !await source.exists()) return null;
    await destinationDirectory.create(recursive: true);
    final extension = p.extension(source.path);
    final destination = File(
      p.join(destinationDirectory.path, '$destinationStem$extension'),
    );
    final partial = File('${destination.path}.partial');
    try {
      if (await partial.exists()) await partial.delete();
      await source.copy(partial.path);
      if (await destination.exists()) await destination.delete();
      await partial.rename(destination.path);
      return destination.path;
    } catch (_) {
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }

  Future<Directory> _locateContentRoot(Directory extraction) async {
    final children = await extraction.list(followLinks: false).toList();
    final dirs = children.whereType<Directory>().toList();
    final mediaAtRoot = children.whereType<File>().any(
      (file) => LibraryService.isSupportedMediaPath(file.path),
    );
    if (!mediaAtRoot && dirs.length == 1) return dirs.single;
    return extraction;
  }

  static String _safeName(String input) {
    final cleaned = input
        .trim()
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '');
    return cleaned.isEmpty ? '未命名' : cleaned;
  }

  static String _safeRelativePath(String value) => value
      .split(RegExp(r'[/\\]+'))
      .where((segment) => segment.isNotEmpty && segment != '..')
      .map(_safeName)
      .join('/');

  static String _uniqueArchivePath(String wanted, Set<String> used) {
    var candidate = wanted;
    var index = 2;
    while (!used.add(candidate.toLowerCase())) {
      final ext = p.posix.extension(wanted);
      final stem = wanted.substring(0, wanted.length - ext.length);
      candidate = '$stem ($index)$ext';
      index++;
    }
    return candidate;
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

class _PackageFile {
  final File file;
  final String archivePath;
  final int size;
  const _PackageFile(this.file, this.archivePath, this.size);
}

class _ExportPlan {
  final List<_PackageFile> files;
  final Map<String, dynamic> manifest;
  final String manifestPath;
  final int mediaCount;
  final int totalBytes;
  const _ExportPlan({
    required this.files,
    required this.manifest,
    required this.manifestPath,
    required this.mediaCount,
    required this.totalBytes,
  });
}

class _TransferCancelled implements Exception {
  const _TransferCancelled();
}

class _PortableWorkerControl {
  final Isolate isolate;
  final Completer<Map<String, dynamic>> completer;

  const _PortableWorkerControl(this.isolate, this.completer);

  void cancel() {
    isolate.kill(priority: Isolate.immediate);
    if (!completer.isCompleted) {
      completer.completeError(const _TransferCancelled());
    }
  }
}

class _PortableRetrySpec {
  final PortableTransferKind kind;
  final List<String>? rootIds;
  final String? outputPath;
  final PortableExportOptions? options;
  final String? packagePath;
  final PortablePackagePreview? preview;
  final bool deletePackageWhenDone;
  final String? libraryFolderId;
  final bool isArchive;
  final String? importDisplayName;
  final String? archiveSortField;
  final String? archiveSortDirection;
  final Set<String> createdAssetPaths;
  String? transactionRootId;

  _PortableRetrySpec._({
    required this.kind,
    this.rootIds,
    this.outputPath,
    this.options,
    this.packagePath,
    this.preview,
    this.deletePackageWhenDone = false,
    this.libraryFolderId,
    this.isArchive = false,
    this.importDisplayName,
    this.archiveSortField,
    this.archiveSortDirection,
    Set<String>? createdAssetPaths,
    this.transactionRootId,
  }) : createdAssetPaths = createdAssetPaths ?? <String>{};

  factory _PortableRetrySpec.export({
    required List<String> rootIds,
    required String outputPath,
    required PortableExportOptions options,
  }) => _PortableRetrySpec._(
    kind: PortableTransferKind.export,
    rootIds: List<String>.unmodifiable(rootIds),
    outputPath: outputPath,
    options: options,
  );

  factory _PortableRetrySpec.import({
    required String packagePath,
    required PortablePackagePreview preview,
    required bool deletePackageWhenDone,
    String? libraryFolderId,
  }) => _PortableRetrySpec._(
    kind: PortableTransferKind.import,
    packagePath: packagePath,
    preview: preview,
    deletePackageWhenDone: deletePackageWhenDone,
    libraryFolderId: libraryFolderId,
  );

  factory _PortableRetrySpec.archive({
    required String archivePath,
    required String displayName,
    required StructuredImportSortOptions sortOptions,
    required bool deleteArchiveWhenDone,
    String? libraryFolderId,
  }) => _PortableRetrySpec._(
    kind: PortableTransferKind.import,
    packagePath: archivePath,
    importDisplayName: displayName,
    isArchive: true,
    archiveSortField: sortOptions.fieldStorageValue,
    archiveSortDirection: sortOptions.directionStorageValue,
    deletePackageWhenDone: deleteArchiveWhenDone,
    libraryFolderId: libraryFolderId,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind.name,
    'rootIds': rootIds,
    'outputPath': outputPath,
    'options': options?.toJson(),
    'packagePath': packagePath,
    'preview': preview?.toJson(),
    'deletePackageWhenDone': deletePackageWhenDone,
    'libraryFolderId': libraryFolderId,
    'isArchive': isArchive,
    'importDisplayName': importDisplayName,
    'archiveSortField': archiveSortField,
    'archiveSortDirection': archiveSortDirection,
    'createdAssetPaths': createdAssetPaths.toList(growable: false),
    'transactionRootId': transactionRootId,
  };

  factory _PortableRetrySpec.fromJson(Map<String, dynamic> json) {
    final kind = PortableTransferKind.values.firstWhere(
      (value) => value.name == json['kind'],
      orElse: () => PortableTransferKind.export,
    );
    final rawOptions = json['options'];
    final rawPreview = json['preview'];
    return _PortableRetrySpec._(
      kind: kind,
      rootIds: (json['rootIds'] as List?)
          ?.map((value) => value.toString())
          .toList(growable: false),
      outputPath: json['outputPath']?.toString(),
      options: rawOptions is Map
          ? PortableExportOptions.fromJson(
              Map<String, dynamic>.from(rawOptions),
            )
          : null,
      packagePath: json['packagePath']?.toString(),
      preview: rawPreview is Map
          ? PortablePackagePreview.fromJson(
              Map<String, dynamic>.from(rawPreview),
            )
          : null,
      deletePackageWhenDone: json['deletePackageWhenDone'] == true,
      libraryFolderId: json['libraryFolderId']?.toString(),
      isArchive: json['isArchive'] == true,
      importDisplayName: json['importDisplayName']?.toString(),
      archiveSortField: json['archiveSortField']?.toString(),
      archiveSortDirection: json['archiveSortDirection']?.toString(),
      createdAssetPaths: (json['createdAssetPaths'] as List?)
          ?.map((value) => value.toString())
          .toSet(),
      transactionRootId: json['transactionRootId']?.toString(),
    );
  }
}

Future<Map<String, dynamic>> _inspectPortablePackageWorker(
  Map<String, dynamic> arguments,
) async {
  final packagePath = arguments['packagePath'] as String;
  final supportedVersion = arguments['supportedVersion'] as int;
  final input = InputFileStream(packagePath);
  Archive? archive;
  try {
    archive = ZipDecoder().decodeStream(input, verify: true);
    final manifests = archive.files.where(
      (entry) => p.posix.basename(entry.name) == 'manifest.json',
    );
    if (manifests.isEmpty) {
      throw const FormatException('这不是 Fluent Player 导出包：缺少清单');
    }
    final decoded = jsonDecode(utf8.decode(manifests.first.content));
    if (decoded is! Map) throw const FormatException('导出包清单损坏');
    final manifest = Map<String, dynamic>.from(decoded);
    _validatePortableManifest(manifest, supportedVersion);
    final version = manifest['formatVersion'] as int? ?? 0;
    return <String, dynamic>{
      'packageName':
          manifest['packageName']?.toString() ??
          p.basenameWithoutExtension(packagePath),
      'createdAt':
          (DateTime.tryParse(manifest['createdAt']?.toString() ?? '') ??
                  DateTime.now())
              .toIso8601String(),
      'mediaCount': manifest['mediaCount'] as int? ?? 0,
      'folderCount': manifest['folderCount'] as int? ?? 0,
      'fileCount': manifest['fileCount'] as int? ?? 0,
      'totalBytes': manifest['totalBytes'] as int? ?? 0,
      'hasChecksums': (manifest['checksums'] as Map?)?.isNotEmpty == true,
      'formatVersion': version,
    };
  } finally {
    archive?.clear();
    await input.close();
  }
}

Future<void> _portableExportWorker(Map<String, dynamic> arguments) async {
  final sendPort = arguments['sendPort'] as SendPort;
  ZipFileEncoder? encoder;
  try {
    final files = (arguments['files'] as List)
        .whereType<Map>()
        .map((value) => Map<String, dynamic>.from(value))
        .toList(growable: false);
    final totalBytes = arguments['totalBytes'] as int? ?? 0;
    final verifyChecksums = arguments['verifyChecksums'] == true;
    final manifest = Map<String, dynamic>.from(arguments['manifest'] as Map);
    final checksums = <String, String>{};
    var processed = 0;
    if (verifyChecksums) {
      for (var index = 0; index < files.length; index++) {
        final record = files[index];
        final source = File(record['sourcePath'] as String);
        if (!await source.exists()) {
          throw StateError('导出源文件已不存在：${source.path}');
        }
        checksums[record['archivePath'] as String] =
            (await sha256.bind(source.openRead()).first).toString();
        processed += record['size'] as int? ?? 0;
        if (index == 0 || (index + 1) % 16 == 0 || index + 1 == files.length) {
          sendPort.send(<String, dynamic>{
            'type': 'progress',
            'progress': totalBytes == 0 ? 0.2 : processed / totalBytes * 0.2,
            'processedBytes': processed,
            'subtitle': '正在校验 ${index + 1}/${files.length}',
          });
        }
      }
    }
    manifest['checksums'] = checksums;

    final partialPath = arguments['partialPath'] as String;
    final level = arguments['level'] as int;
    encoder = ZipFileEncoder()..create(partialPath, level: level);
    encoder.addArchiveFile(
      ArchiveFile.string(
        arguments['manifestPath'] as String,
        jsonEncode(manifest),
      ),
    );
    processed = 0;
    for (var index = 0; index < files.length; index++) {
      final record = files[index];
      final source = File(record['sourcePath'] as String);
      if (!await source.exists()) {
        throw StateError('导出源文件已不存在：${source.path}');
      }
      await encoder.addFile(source, record['archivePath'] as String, level);
      processed += record['size'] as int? ?? 0;
      final ratio = totalBytes == 0
          ? (index + 1) / files.length
          : processed / totalBytes;
      if (index == 0 || (index + 1) % 8 == 0 || index + 1 == files.length) {
        sendPort.send(<String, dynamic>{
          'type': 'progress',
          'progress':
              (verifyChecksums ? 0.2 : 0.02) +
              ratio * (verifyChecksums ? 0.78 : 0.96),
          'processedBytes': processed,
          'subtitle': '正在打包 ${index + 1}/${files.length}',
        });
      }
    }
    await encoder.close();
    encoder = null;
    sendPort.send(<String, dynamic>{
      'type': 'done',
      'result': <String, dynamic>{},
    });
  } catch (error) {
    try {
      await encoder?.close();
    } catch (_) {}
    sendPort.send(<String, dynamic>{
      'type': 'error',
      'message': error.toString(),
      'format': error is FormatException,
    });
  }
}

Future<void> _portableImportWorker(Map<String, dynamic> arguments) async {
  final sendPort = arguments['sendPort'] as SendPort;
  final packagePath = arguments['packagePath'] as String;
  final extractionPath = arguments['extractionPath'] as String;
  final supportedVersion = arguments['supportedVersion'] as int;
  InputFileStream? input;
  Archive? archive;
  try {
    input = InputFileStream(packagePath);
    var entries = 0;
    archive = ZipDecoder().decodeStream(
      input,
      verify: true,
      callback: (_) {
        entries++;
        if (entries == 1 || entries % 16 == 0) {
          sendPort.send(<String, dynamic>{
            'type': 'progress',
            'progress': 0.02 + (entries / (entries + 200)) * 0.12,
            'subtitle': '正在读取 · $entries 个文件',
          });
        }
      },
    );
    if (archive.length > 20000) {
      throw const FormatException('导出包文件数量过多，已拒绝解包');
    }
    var declaredBytes = 0;
    for (final entry in archive) {
      if (entry.isSymbolicLink) {
        throw const FormatException('导出包不应包含符号链接');
      }
      declaredBytes += entry.size;
      if (declaredBytes > 500 * 1024 * 1024 * 1024) {
        throw const FormatException('导出包解压后体积过大');
      }
      final relative = entry.name.replaceAll('\\', '/');
      final candidate = p.normalize(
        p.join(extractionPath, p.joinAll(relative.split('/'))),
      );
      if (p.equals(candidate, extractionPath) ||
          !p.isWithin(extractionPath, candidate)) {
        throw FormatException('导出包包含不安全路径：${entry.name}');
      }
    }
    sendPort.send(<String, dynamic>{
      'type': 'progress',
      'progress': 0.16,
      'subtitle': '正在解包，请稍候…',
    });
    await extractArchiveToDisk(archive, extractionPath);
    archive.clear();
    archive = null;
    await input.close();
    input = null;

    final extraction = Directory(extractionPath);
    final manifests = extraction
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((file) => p.basename(file.path) == 'manifest.json')
        .toList(growable: false);
    if (manifests.isEmpty) throw const FormatException('导出包缺少清单');
    final decoded = jsonDecode(await manifests.first.readAsString());
    if (decoded is! Map) throw const FormatException('导出包清单损坏');
    final manifest = Map<String, dynamic>.from(decoded);
    _validatePortableManifest(manifest, supportedVersion);

    final rawChecksums = manifest['checksums'];
    if (rawChecksums is Map && rawChecksums.isNotEmpty) {
      var checked = 0;
      for (final entry in rawChecksums.entries) {
        final relative = entry.key.toString().replaceAll('\\', '/');
        final candidate = File(
          p.normalize(p.join(extractionPath, p.joinAll(relative.split('/')))),
        );
        if (!p.isWithin(extractionPath, candidate.path) ||
            !await candidate.exists()) {
          throw FormatException('导出包缺少文件：$relative');
        }
        final digest = (await sha256.bind(candidate.openRead()).first)
            .toString();
        if (digest != entry.value.toString()) {
          throw FormatException('文件校验失败：$relative');
        }
        checked++;
        if (checked == 1 ||
            checked % 16 == 0 ||
            checked == rawChecksums.length) {
          sendPort.send(<String, dynamic>{
            'type': 'progress',
            'progress': 0.22 + checked / rawChecksums.length * 0.18,
            'subtitle': '正在校验 $checked/${rawChecksums.length}',
          });
        }
      }
    }
    sendPort.send(<String, dynamic>{'type': 'done', 'result': manifest});
  } catch (error) {
    sendPort.send(<String, dynamic>{
      'type': 'error',
      'message': error.toString(),
      'format': error is FormatException,
    });
  } finally {
    archive?.clear();
    if (input != null) {
      try {
        await input.close();
      } catch (_) {}
    }
  }
}

void _validatePortableManifest(
  Map<String, dynamic> manifest,
  int supportedVersion,
) {
  if (manifest['format'] != 'fluent-player-portable-package') {
    throw const FormatException('无法识别的导出包格式');
  }
  final version = manifest['formatVersion'] as int? ?? 0;
  if (version > supportedVersion) {
    throw FormatException('该文件来自更新版本（格式版本 $version）');
  }
}
