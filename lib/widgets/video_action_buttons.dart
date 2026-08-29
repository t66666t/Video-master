import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player_app/features/youtube_download/presentation/pages/yt_dlp_download_screen.dart';

import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../services/batch_import_service.dart';
import '../services/bilibili/bilibili_download_service.dart';
import '../services/temporary_storage_cleanup_models.dart';
import '../services/temporary_storage_cleanup_service.dart';
import '../services/transcription_manager.dart';
import '../screens/batch_import_screen.dart';
import '../screens/bilibili_download_screen.dart';
import '../screens/batch_subtitle_screen.dart';
import '../utils/app_toast.dart';

class VideoActionButtons extends StatefulWidget {
  final String? collectionId;
  final bool
  isHorizontal; // For empty state usage if needed, though mostly for FAB

  static const MethodChannel _fileManagerChannel = MethodChannel(
    'com.example.video_player_app/file_manager',
  );

  static String _cleanImportedTitle(String path) {
    final name = p.basename(path);
    final cleaned = name
        .replaceFirst(RegExp(r'^incoming_media_\d+_'), '')
        .replaceFirst(RegExp(r'^shared_media_\d+_'), '')
        .replaceFirst(
          RegExp(
            r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}_',
          ),
          '',
        );
    return cleaned.isEmpty ? name : cleaned;
  }

  const VideoActionButtons({
    super.key,
    this.collectionId,
    this.isHorizontal = false,
  });

  static void _showTopBanner(
    BuildContext context,
    String message, {
    Color? backgroundColor,
    String? actionText,
    VoidCallback? onActionPressed,
    Duration autoHideDuration = const Duration(milliseconds: 2000),
  }) {
    AppToastType type = AppToastType.info;
    if (backgroundColor != null && backgroundColor.toARGB32() == 0xFFB00020) {
      type = AppToastType.error;
    }

    if (actionText != null && onActionPressed != null) {
      AppToast.show(
        message,
        type: type,
        duration: autoHideDuration,
        action: AppToastAction(label: actionText, onPressed: onActionPressed),
      );
    } else {
      AppToast.show(message, type: type, duration: autoHideDuration);
    }
  }

  static Future<void> processImportedFiles(
    BuildContext context,
    List<String> paths,
    String? collectionId,
  ) async {
    const validExtensions = LibraryService.supportedMediaExtensions;

    final validPaths = paths
        .where(
          (path) => validExtensions.contains(p.extension(path).toLowerCase()),
        )
        .toList();
    if (validPaths.isEmpty) {
      if (context.mounted) {
        _showTopBanner(
          context,
          "未找到可用的媒体文件",
          backgroundColor: const Color(0xFFB00020),
        );
      }
      return;
    }

    final originalTitles = validPaths
        .map((path) => _cleanImportedTitle(path))
        .toList();
    if (!context.mounted) return;
    final library = Provider.of<LibraryService>(context, listen: false);
    if (library.hasActiveImport) {
      _showTopBanner(
        context,
        '已有导入任务正在运行，请等待完成后再试',
        backgroundColor: const Color(0xFFB00020),
      );
      return;
    }
    _showTopBanner(
      context,
      "已开始后台导入 ${validPaths.length} 个媒体文件",
      autoHideDuration: const Duration(seconds: 2),
    );
    library.importVideosBackground(
      validPaths,
      collectionId,
      shouldCopy: false,
      originalTitles: originalTitles,
      useOriginalPath: false,
      allowCacheRescue: true,
    );
  }

  static const List<String> _structuredArchiveExtensions = [
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

  static Future<void> processDroppedPaths(
    BuildContext context,
    List<String> paths,
    String? collectionId,
  ) async {
    final normalizedPaths = <String>[];
    final seen = <String>{};
    for (final rawPath in paths) {
      final trimmed = rawPath.trim();
      if (trimmed.isEmpty) continue;
      final normalized = p.normalize(trimmed);
      final dedupeKey = Platform.isWindows
          ? normalized.toLowerCase()
          : normalized;
      if (seen.add(dedupeKey)) {
        normalizedPaths.add(normalized);
      }
    }

    if (normalizedPaths.isEmpty) {
      if (context.mounted) {
        _showTopBanner(
          context,
          "未找到可导入的内容",
          backgroundColor: const Color(0xFFB00020),
        );
      }
      return;
    }

    final mediaPaths = <String>[];
    final archivePaths = <String>[];
    final folderPaths = <String>[];

    for (final path in normalizedPaths) {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        folderPaths.add(path);
        continue;
      }
      if (type != FileSystemEntityType.file) {
        continue;
      }
      if (LibraryService.isSupportedMediaPath(path)) {
        mediaPaths.add(path);
        continue;
      }
      if (LibraryService.isSupportedArchivePath(path)) {
        archivePaths.add(path);
      }
    }

    if (!context.mounted) {
      return;
    }

    final structuredItemCount = archivePaths.length + folderPaths.length;
    if (structuredItemCount > 0) {
      if (structuredItemCount > 1 || mediaPaths.isNotEmpty) {
        if (context.mounted) {
          _showTopBanner(
            context,
            "拖拽压缩包或文件夹时请一次只拖入一个，并且不要与媒体文件混拖",
            backgroundColor: const Color(0xFFB00020),
            autoHideDuration: const Duration(seconds: 3),
          );
        }
        return;
      }

      if (folderPaths.isNotEmpty) {
        await processDroppedFolder(context, folderPaths.single, collectionId);
        return;
      }

      await processDroppedArchive(context, archivePaths.single, collectionId);
      return;
    }

    await processImportedFiles(context, mediaPaths, collectionId);
  }

  static Future<void> processIncomingSharedItems(
    BuildContext context,
    List<dynamic> items,
    String? collectionId,
  ) async {
    final mediaPaths = <String>[];
    final archiveSelections = <_ArchiveSelection>[];

    for (final item in items) {
      if (item is String) {
        final path = item.trim();
        if (path.isNotEmpty) {
          mediaPaths.add(path);
        }
        continue;
      }
      if (item is! Map) {
        continue;
      }

      final rawKind = item['kind'];
      final kind = rawKind is String ? rawKind.trim().toLowerCase() : '';
      if (kind == 'archive') {
        archiveSelections.add(_ArchiveSelection.fromNativeMap(item));
        continue;
      }
      final rawPath = item['path'];
      if (kind == 'media' && rawPath is String && rawPath.trim().isNotEmpty) {
        mediaPaths.add(rawPath.trim());
      }
    }

    if (archiveSelections.isNotEmpty) {
      if (archiveSelections.length > 1 || mediaPaths.isNotEmpty) {
        if (context.mounted) {
          _showTopBanner(
            context,
            '系统分享压缩包时请一次只选择一个，且不要与媒体文件混合分享',
            backgroundColor: const Color(0xFFB00020),
            autoHideDuration: const Duration(seconds: 3),
          );
        }
        return;
      }
      await _processSelectedArchive(
        context,
        archiveSelections.single,
        collectionId,
      );
      return;
    }

    await processImportedFiles(context, mediaPaths, collectionId);
  }

  static Future<void> processDroppedArchive(
    BuildContext context,
    String archivePath,
    String? collectionId,
  ) async {
    final selection = _ArchiveSelection.fromResolvedPath(archivePath);
    await _processSelectedArchive(context, selection, collectionId);
  }

  static Future<void> _processSelectedArchive(
    BuildContext context,
    _ArchiveSelection selection,
    String? collectionId,
  ) async {
    try {
      if (!context.mounted) return;
      if (ModalRoute.of(context)?.isCurrent != true) return;

      if (!context.mounted) {
        await AppToast.dismiss(immediate: true);
        await _cleanupTemporaryArchiveSelection(selection.resolvedPath);
        return;
      }
      if (ModalRoute.of(context)?.isCurrent != true) {
        await AppToast.dismiss(immediate: true);
        await _cleanupTemporaryArchiveSelection(selection.resolvedPath);
        return;
      }

      final library = Provider.of<LibraryService>(context, listen: false);
      if (library.hasActiveImport) {
        _showTopBanner(
          context,
          '已有导入任务正在运行，请等待完成后再试',
          backgroundColor: const Color(0xFFB00020),
        );
        return;
      }
      final summary = await _prepareArchiveSelectionSummary(selection, library);
      await AppToast.dismiss();
      if (!context.mounted || ModalRoute.of(context)?.isCurrent != true) {
        await _cleanupTemporaryArchiveSelection(selection.resolvedPath);
        return;
      }

      final action = await _showStructuredImportDialog(context, summary);
      if (!context.mounted ||
          action == null ||
          action == _StructuredImportDialogAction.cancel) {
        await _cleanupTemporaryArchiveSelection(selection.resolvedPath);
        return;
      }

      if (action == _StructuredImportDialogAction.preview) {
        await _cleanupTemporaryArchiveSelection(selection.resolvedPath);
        if (!context.mounted || ModalRoute.of(context)?.isCurrent != true) {
          return;
        }
        _showTopBanner(context, "压缩包预览功能暂未开放");
        return;
      }

      final settings = Provider.of<SettingsService>(context, listen: false);
      final sortOptions = StructuredImportSortOptions.fromSettings(settings);
      final archivePath = await _ensureArchivePathForImport(selection);
      final toastBridge = _ArchiveImportToastBridge(library);
      toastBridge.start(initialMessage: '正在准备导入压缩包：${summary.sourceName}');
      final resultSummary = await library
          .importArchiveSelection(
            archivePath,
            collectionId,
            sortOptions: sortOptions,
          )
          .whenComplete(toastBridge.dispose);
      await AppToast.dismiss();
      if (!context.mounted) return;
      if (ModalRoute.of(context)?.isCurrent != true) return;
      _showTopBanner(
        context,
        "压缩包导入完成：新增 ${resultSummary.importedMediaCount} 个媒体，创建 ${resultSummary.createdFolderCount} 个文件夹",
        autoHideDuration: const Duration(milliseconds: 1200),
      );
    } catch (e) {
      await AppToast.dismiss(immediate: true);
      await _cleanupTemporaryArchiveSelection(selection.resolvedPath);
      if (context.mounted) {
        _showTopBanner(
          context,
          "压缩包导入失败: $e",
          backgroundColor: const Color(0xFFB00020),
          autoHideDuration: const Duration(seconds: 3),
        );
      }
    }
  }

  static Future<void> processDroppedFolder(
    BuildContext context,
    String folderPath,
    String? collectionId,
  ) async {
    try {
      if (!context.mounted) return;
      if (ModalRoute.of(context)?.isCurrent != true) return;
      final library = Provider.of<LibraryService>(context, listen: false);
      if (library.hasActiveImport) {
        _showTopBanner(
          context,
          '已有导入任务正在运行，请等待完成后再试',
          backgroundColor: const Color(0xFFB00020),
        );
        return;
      }
      final summary = await library.analyzeFolderSelection(folderPath);
      if (!context.mounted) return;
      if (ModalRoute.of(context)?.isCurrent != true) return;

      final action = await _showStructuredImportDialog(context, summary);
      if (!context.mounted ||
          action == null ||
          action == _StructuredImportDialogAction.cancel) {
        return;
      }

      if (action == _StructuredImportDialogAction.preview) {
        _showTopBanner(context, "文件夹预览功能暂未开放");
        return;
      }

      final settings = Provider.of<SettingsService>(context, listen: false);
      final sortOptions = StructuredImportSortOptions.fromSettings(settings);
      _showTopBanner(context, "已开始导入文件夹：${summary.sourceName}");
      final resultSummary = await library.importFolderSelection(
        folderPath,
        collectionId,
        sortOptions: sortOptions,
      );
      if (!context.mounted) return;
      if (ModalRoute.of(context)?.isCurrent != true) return;
      _showTopBanner(
        context,
        "文件夹导入完成：新增 ${resultSummary.importedMediaCount} 个媒体，创建 ${resultSummary.createdFolderCount} 个文件夹",
        autoHideDuration: const Duration(milliseconds: 1200),
      );
    } catch (e) {
      if (context.mounted) {
        _showTopBanner(
          context,
          "文件夹导入失败: $e",
          backgroundColor: const Color(0xFFB00020),
          autoHideDuration: const Duration(seconds: 3),
        );
      }
    }
  }

  static Future<bool> _isTemporarySelectionPath(String path) async {
    try {
      final normalizedPath = p.normalize(path);
      final tempDir = await getTemporaryDirectory();
      final archiveCache = p.normalize(p.join(tempDir.path, 'picked_archives'));
      if (p.isWithin(archiveCache, normalizedPath)) {
        return true;
      }

      if (Platform.isAndroid) {
        final extCacheDirs = await getExternalCacheDirectories();
        if (extCacheDirs != null) {
          for (final dir in extCacheDirs) {
            final externalArchiveCache = p.normalize(
              p.join(dir.path, 'picked_archives'),
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

  static Future<void> _cleanupTemporaryArchiveSelection(String? path) async {
    if (path == null || path.isEmpty) {
      return;
    }
    if (!await _isTemporarySelectionPath(path)) {
      return;
    }
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  static Future<StructuredImportSelectionSummary>
  _prepareArchiveSelectionSummary(
    _ArchiveSelection selection,
    LibraryService library,
  ) async {
    final sourceName = selection.displayName;
    final sizeLabel = selection.sizeLabel;

    AppToast.showProgress(
      sizeLabel == null
          ? '正在准备压缩包：$sourceName'
          : '正在准备压缩包：$sourceName\n文件大小：$sizeLabel',
      progress: 0.12,
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));

    AppToast.updateProgress(
      message: selection.hasResolvedPath
          ? '正在校验压缩包并生成导入确认信息...'
          : '已获取压缩包引用，正在生成导入确认信息...',
      progress: 0.48,
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));

    final summary = selection.toSelectionSummary(library);
    AppToast.updateProgress(message: '压缩包信息已就绪，正在打开确认窗口...', progress: 0.95);
    await Future<void>.delayed(const Duration(milliseconds: 90));
    return summary;
  }

  static Future<String> _ensureArchivePathForImport(
    _ArchiveSelection selection,
  ) async {
    if (selection.hasResolvedPath) {
      return selection.resolvedPath!;
    }
    if (!Platform.isAndroid || selection.uri == null) {
      throw StateError('无法获取压缩包文件路径');
    }

    AppToast.updateProgress(
      message: '正在准备压缩包文件，确认导入后才开始必要的文件落盘...',
      progress: 0.02,
    );
    final result = await _fileManagerChannel.invokeMethod<Object?>(
      "materializeArchiveForImport",
      {"uri": selection.uri, "displayName": selection.displayName},
    );
    if (result is! String || result.isEmpty) {
      throw StateError('无法准备压缩包文件');
    }
    selection.resolvedPath = result;
    return result;
  }

  static Future<_StructuredImportDialogAction?> _showStructuredImportDialog(
    BuildContext context,
    StructuredImportSelectionSummary summary,
  ) async {
    final settings = Provider.of<SettingsService>(context, listen: false);
    String sortField = settings.structuredImportSortField;
    String sortDirection = settings.structuredImportSortDirection;

    return showDialog<_StructuredImportDialogAction>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            Future<void> updateSortSetting({
              String? field,
              String? direction,
            }) async {
              if (field != null && direction != null) {
                await settings.saveStructuredImportSort(
                  field: field,
                  direction: direction,
                );
              } else if (field != null) {
                await settings.saveStructuredImportSortField(field);
              } else if (direction != null) {
                await settings.saveStructuredImportSortDirection(direction);
              } else {
                return;
              }
              if (!dialogContext.mounted) {
                return;
              }
              setState(() {
                sortField = field ?? sortField;
                sortDirection = direction ?? sortDirection;
              });
            }

            return AlertDialog(
              title: Text(summary.isArchive ? '确认导入压缩包' : '确认导入文件夹'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('名称：${summary.sourceName}'),
                    const SizedBox(height: 8),
                    Text(
                      summary.isArchive
                          ? '导入后外层文件夹名称：${summary.rootCollectionName}'
                          : '最外层文件夹名称：${summary.rootCollectionName}',
                    ),
                    const SizedBox(height: 8),
                    Text('位置：${summary.sourcePath}'),
                    const SizedBox(height: 12),
                    if (summary.detailsDeferred)
                      const Text(
                        '压缩包将在点击“直接导入”后再解析与解压，当前不会触发解压操作。',
                        style: TextStyle(fontSize: 12, color: Colors.white70),
                      )
                    else
                      Text(
                        '检测到 ${summary.folderCount} 个文件夹，${summary.mediaFileCount} 个可导入媒体文件。',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white70,
                        ),
                      ),
                    const SizedBox(height: 16),
                    const Text(
                      '导入顺序',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: sortField,
                      items: const [
                        DropdownMenuItem(
                          value: 'fileName',
                          child: Text('按文件名排序'),
                        ),
                        DropdownMenuItem(
                          value: 'modifiedTime',
                          child: Text('按修改时间排序'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        updateSortSetting(field: value);
                      },
                      decoration: const InputDecoration(labelText: '排序方式'),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: sortDirection,
                      items: [
                        DropdownMenuItem(
                          value: 'ascending',
                          child: Text(
                            sortField == 'modifiedTime' ? '从旧到新' : '正序',
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'descending',
                          child: Text(
                            sortField == 'modifiedTime' ? '从新到旧' : '倒序',
                          ),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        updateSortSetting(direction: value);
                      },
                      decoration: const InputDecoration(labelText: '顺序方向'),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      '以上排序会永久保存，下次导入时会自动沿用。',
                      style: TextStyle(fontSize: 12, color: Colors.white70),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(
                      dialogContext,
                      _StructuredImportDialogAction.cancel,
                    );
                  },
                  child: const Text('取消导入'),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(
                      dialogContext,
                      _StructuredImportDialogAction.preview,
                    );
                  },
                  child: const Text('预览'),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.pop(
                      dialogContext,
                      _StructuredImportDialogAction.confirm,
                    );
                  },
                  child: const Text('直接导入'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  State<VideoActionButtons> createState() => _VideoActionButtonsState();
}

class _VideoActionButtonsState extends State<VideoActionButtons> {
  Timer? _hiddenCleanupTapResetTimer;
  int _hiddenCleanupTapCount = 0;
  bool _isHiddenCleanupDialogOpen = false;

  @override
  void dispose() {
    _hiddenCleanupTapResetTimer?.cancel();
    super.dispose();
  }

  void _resetHiddenCleanupTapState() {
    _hiddenCleanupTapResetTimer?.cancel();
    _hiddenCleanupTapResetTimer = null;
    _hiddenCleanupTapCount = 0;
  }

  void _registerHiddenCleanupTap(BuildContext context) {
    if (widget.collectionId != null) {
      return;
    }
    _hiddenCleanupTapCount += 1;
    _hiddenCleanupTapResetTimer?.cancel();
    _hiddenCleanupTapResetTimer = Timer(
      const Duration(seconds: 2),
      _resetHiddenCleanupTapState,
    );
    if (_hiddenCleanupTapCount < 5) {
      return;
    }
    _resetHiddenCleanupTapState();
    unawaited(_showTemporaryStorageCleanupDialog(context));
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    double value = bytes.toDouble();
    int i = 0;
    while (value >= 1024 && i < units.length - 1) {
      value /= 1024;
      i++;
    }
    return '${value.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
  }

  Future<void> _showTemporaryStorageCleanupDialog(BuildContext context) async {
    if (_isHiddenCleanupDialogOpen) {
      return;
    }

    final cleanupService = TemporaryStorageCleanupService(
      transcriptionManager: Provider.of<TranscriptionManager>(
        context,
        listen: false,
      ),
      libraryService: Provider.of<LibraryService>(context, listen: false),
      bilibiliDownloadService: Provider.of<BilibiliDownloadService>(
        context,
        listen: false,
      ),
      ytDlpDownloadService: Provider.of(context, listen: false),
    );

    _isHiddenCleanupDialogOpen = true;
    var isLoading = true;
    var isCleaning = false;
    var hasStartedLoading = false;
    String? errorMessage;
    TemporaryStorageScanReport? report;

    Future<void> loadReport(StateSetter setState) async {
      setState(() {
        isLoading = true;
        errorMessage = null;
      });
      try {
        final result = await cleanupService.scan();
        if (!mounted) {
          return;
        }
        setState(() {
          report = result;
          isLoading = false;
        });
      } catch (e) {
        if (!mounted) {
          return;
        }
        setState(() {
          errorMessage = '扫描临时文件失败：$e';
          isLoading = false;
        });
      }
    }

    try {
      await showDialog(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (context, setState) {
              if (!hasStartedLoading) {
                hasStartedLoading = true;
                unawaited(loadReport(setState));
              }

              final currentReport = report;
              final categories = currentReport?.categories ?? const [];
              final totalBytes = currentReport?.totalBytes ?? 0;

              return AlertDialog(
                title: const Text('临时文件清理'),
                content: SizedBox(
                  width: 380,
                  child: isLoading
                      ? const SizedBox(
                          height: 140,
                          child: Center(child: CircularProgressIndicator()),
                        )
                      : errorMessage != null
                      ? Text(
                          errorMessage!,
                          style: const TextStyle(fontSize: 13),
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '可识别占用：${_formatBytes(totalBytes)}',
                              style: const TextStyle(fontSize: 13),
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              '仅统计应用明确管理的临时文件；正在运行或可继续的任务会自动跳过，不会误删。',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.white70,
                              ),
                            ),
                            const SizedBox(height: 12),
                            if (categories.isEmpty)
                              const Text(
                                '未发现可统计的临时文件。',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.white70,
                                ),
                              )
                            else
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxHeight: 280,
                                ),
                                child: ListView.separated(
                                  shrinkWrap: true,
                                  itemCount: categories.length,
                                  separatorBuilder: (_, _) =>
                                      const Divider(height: 12),
                                  itemBuilder: (context, index) {
                                    final item = categories[index];
                                    return _TemporaryStorageCategoryTile(
                                      report: item,
                                      sizeText: _formatBytes(item.totalBytes),
                                    );
                                  },
                                ),
                              ),
                          ],
                        ),
                ),
                actions: [
                  TextButton(
                    onPressed: isCleaning
                        ? null
                        : () => Navigator.pop(dialogContext),
                    child: const Text('关闭'),
                  ),
                  TextButton(
                    onPressed:
                        isLoading ||
                            isCleaning ||
                            errorMessage != null ||
                            !(currentReport?.hasClearableContent ?? false)
                        ? null
                        : () async {
                            setState(() {
                              isCleaning = true;
                              errorMessage = null;
                            });
                            try {
                              final refreshed = await cleanupService.clearAll();
                              if (!dialogContext.mounted) {
                                return;
                              }
                              setState(() {
                                report = refreshed;
                                isCleaning = false;
                              });
                            } catch (e) {
                              if (!dialogContext.mounted) {
                                return;
                              }
                              setState(() {
                                errorMessage = '清理临时文件失败：$e';
                                isCleaning = false;
                              });
                            }
                          },
                    child: Text(isCleaning ? '清理中...' : '一键清理'),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      _isHiddenCleanupDialogOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isHorizontal) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ElevatedButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      BatchSubtitleScreen(collectionId: widget.collectionId),
                  settings: const RouteSettings(name: '/batch_subtitle'),
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.teal,
              foregroundColor: Colors.white,
            ),
            child: const Text("批量字幕生成"),
          ),
          const SizedBox(width: 16),
          ElevatedButton(
            onPressed: () =>
                showCreateCollectionDialog(context, widget.collectionId),
            child: const Text("新建合集"),
          ),
          const SizedBox(width: 16),
          ElevatedButton(
            onPressed: () => importVideos(context, widget.collectionId),
            child: const Text("导入视频或音频"),
          ),
          const SizedBox(width: 16),
          ElevatedButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    BatchImportScreen(folderId: widget.collectionId),
              ),
            ),
            child: const Text("批量导入媒体"),
          ),
          const SizedBox(width: 16),
          ElevatedButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => BilibiliDownloadScreen(
                    targetFolderId: widget.collectionId,
                  ),
                  settings: const RouteSettings(name: '/bilibili_download'),
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFB7299),
              foregroundColor: Colors.white,
            ),
            child: const Text("B站下载"),
          ),
          const SizedBox(width: 16),
          ElevatedButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const YtDlpDownloadScreen(),
                settings: const RouteSettings(name: '/yt_dlp_download'),
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF4040),
              foregroundColor: Colors.white,
            ),
            child: const Text("YT-DLP下载"),
          ),
        ],
      );
    }

    return Consumer<SettingsService>(
      builder: (context, settings, _) {
        final isCollapsed = settings.isActionButtonsCollapsed;

        return Column(
          mainAxisAlignment: MainAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            SizedBox(
              width: 56, // Enforce width to align with standard FAB
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                reverseDuration: const Duration(milliseconds: 300),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (Widget child, Animation<double> animation) {
                  return SizeTransition(
                    sizeFactor: animation,
                    alignment: AlignmentDirectional.bottomStart,
                    child: FadeTransition(opacity: animation, child: child),
                  );
                },
                // Use default layoutBuilder (Stack with Alignment.center)
                // Since we constrained width to 56, center alignment is effectively same as left/right
                child: isCollapsed
                    ? const SizedBox.shrink(key: ValueKey('collapsed'))
                    : Column(
                        key: const ValueKey('expanded'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FloatingActionButton(
                            heroTag: "batch_subtitle_${widget.collectionId}",
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => BatchSubtitleScreen(
                                    collectionId: widget.collectionId,
                                  ),
                                  settings: const RouteSettings(
                                    name: '/batch_subtitle',
                                  ),
                                ),
                              );
                            },
                            tooltip: "批量字幕生成",
                            backgroundColor: Colors.teal,
                            child: const Icon(
                              Icons.closed_caption,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 16),
                          FloatingActionButton(
                            heroTag: "add_folder_${widget.collectionId}",
                            onPressed: () => showCreateCollectionDialog(
                              context,
                              widget.collectionId,
                            ),
                            tooltip: "新建合集",
                            child: const Icon(Icons.create_new_folder),
                          ),
                          const SizedBox(height: 16),
                          FloatingActionButton(
                            heroTag: "add_video_${widget.collectionId}",
                            onPressed: () =>
                                importVideos(context, widget.collectionId),
                            tooltip: "导入视频或音频",
                            child: const Icon(Icons.video_call),
                          ),
                          const SizedBox(height: 16),
                          FloatingActionButton(
                            heroTag: "bbdown_download_${widget.collectionId}",
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => BilibiliDownloadScreen(
                                    targetFolderId: widget.collectionId,
                                  ),
                                  settings: const RouteSettings(
                                    name: '/bilibili_download',
                                  ),
                                ),
                              );
                            },
                            tooltip: "B站视频下载",
                            backgroundColor: const Color(0xFFFB7299),
                            child: const Icon(Icons.tv, color: Colors.white),
                          ),
                          const SizedBox(height: 16),
                          FloatingActionButton(
                            heroTag: "yt_dlp_download_${widget.collectionId}",
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const YtDlpDownloadScreen(),
                                  settings: const RouteSettings(
                                    name: '/yt_dlp_download',
                                  ),
                                ),
                              );
                            },
                            tooltip: "YT-DLP 视频下载",
                            backgroundColor: const Color(0xFFFF4040),
                            child: const Icon(
                              Icons.ondemand_video,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Consumer<BatchImportService>(
                            builder: (context, batch, _) {
                              final count = batch.getPendingCount(
                                widget.collectionId,
                              );
                              return Stack(
                                clipBehavior: Clip.none,
                                alignment: Alignment.topRight,
                                children: [
                                  FloatingActionButton(
                                    heroTag:
                                        "batch_import_${widget.collectionId}",
                                    onPressed: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => BatchImportScreen(
                                          folderId: widget.collectionId,
                                        ),
                                      ),
                                    ),
                                    tooltip: "批量导入媒体及对应字幕",
                                    backgroundColor: Colors.deepPurpleAccent,
                                    child: const Icon(
                                      Icons.playlist_add,
                                      color: Colors.white,
                                    ),
                                  ),
                                  if (count > 0)
                                    Positioned(
                                      right: -4,
                                      top: -4,
                                      child: Container(
                                        padding: const EdgeInsets.all(6),
                                        decoration: const BoxDecoration(
                                          color: Colors.redAccent,
                                          shape: BoxShape.circle,
                                        ),
                                        child: Text(
                                          "$count",
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 16),
                        ],
                      ),
              ),
            ),
            SizedBox(
              width: 56,
              child: Align(
                alignment: Alignment.center,
                child: FloatingActionButton.small(
                  heroTag: "collapse_toggle_${widget.collectionId ?? 'root'}",
                  onPressed: () {
                    _registerHiddenCleanupTap(context);
                    settings.updateSetting(
                      'isActionButtonsCollapsed',
                      !isCollapsed,
                    );
                  },
                  tooltip: isCollapsed ? "展开" : "收起",
                  backgroundColor: const Color(0xFF333333),
                  foregroundColor: Colors.white,
                  child: Icon(
                    isCollapsed
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void showCreateCollectionDialog(BuildContext context, String? parentId) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("新建合集"),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: "合集名称"),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                Provider.of<LibraryService>(
                  context,
                  listen: false,
                ).createCollection(controller.text, parentId);
                Navigator.pop(context);
              }
            },
            child: const Text("创建"),
          ),
        ],
      ),
    );
  }

  Future<bool> _requestStoragePermissionIfNeeded(BuildContext context) async {
    if (!Platform.isAndroid) {
      return true;
    }
    final hasPermission =
        await Permission.videos.request().isGranted ||
        await Permission.storage.request().isGranted ||
        await Permission.manageExternalStorage.request().isGranted;
    if (!hasPermission && context.mounted) {
      VideoActionButtons._showTopBanner(
        context,
        "未获得存储权限，请在系统设置中开启",
        backgroundColor: const Color(0xFFB00020),
        actionText: "去设置",
        onActionPressed: () {
          openAppSettings();
        },
      );
    }
    return hasPermission;
  }

  Future<void> importVideos(BuildContext context, String? collectionId) async {
    final mainContext = context;
    await showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS)
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('从相册导入'),
                onTap: () {
                  Navigator.pop(context);
                  _pickFromGallery(mainContext, collectionId);
                },
              ),
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('从文件管理导入'),
              onTap: () {
                Navigator.pop(context);
                _pickFromFileManager(mainContext, collectionId);
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.live_tv_outlined,
                color: Color(0xFFFB7299),
              ),
              title: const Text('导入 Bilibili 链接（在线播放）'),
              subtitle: const Text('仅导入播放链接；下载请使用小电视按钮'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  mainContext,
                  MaterialPageRoute(
                    builder: (_) => BilibiliDownloadScreen(
                      targetFolderId: collectionId,
                      initialStreamingMode: true,
                    ),
                    settings: const RouteSettings(
                      name: '/bilibili_stream_import',
                    ),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: const Text('从文件管理导入压缩包'),
              onTap: () {
                Navigator.pop(context);
                _pickArchiveFromFileManager(mainContext, collectionId);
              },
            ),
            if (!Platform.isIOS)
              ListTile(
                leading: const Icon(Icons.create_new_folder_outlined),
                title: const Text('从文件管理导入文件夹'),
                onTap: () {
                  Navigator.pop(context);
                  _pickFolderFromFileManager(mainContext, collectionId);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickFromGallery(
    BuildContext context,
    String? collectionId,
  ) async {
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.isAuth && !permission.isLimited) {
        if (context.mounted) {
          VideoActionButtons._showTopBanner(
            context,
            "未获得相册权限，请在系统设置中开启",
            backgroundColor: const Color(0xFFB00020),
            actionText: "去设置",
            onActionPressed: () {
              openAppSettings();
            },
          );
        }
        return;
      }

      if (!context.mounted) return;
      final List<AssetEntity>? assets = await AssetPicker.pickAssets(
        context,
        pickerConfig: AssetPickerConfig(
          requestType: RequestType.video | RequestType.audio,
          maxAssets: 999,
        ),
      );

      if (assets == null || assets.isEmpty) {
        if (context.mounted) {
          VideoActionButtons._showTopBanner(context, "未选择任何媒体");
        }
        return;
      }

      final List<String> paths = [];
      final List<String> originalTitles = [];

      final processingToast = AppToast.showLoading("正在处理媒体文件...");
      try {
        for (final asset in assets) {
          final File? file = await asset.file;
          if (file == null) continue;
          paths.add(file.path);

          String title = asset.title ?? '';
          if (title.isEmpty || title.trim().isEmpty) {
            final date = asset.createDateTime;
            final prefix = asset.type == AssetType.video
                ? "Video"
                : (asset.type == AssetType.audio ? "Audio" : "Media");
            title =
                "${prefix}_${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}_${date.hour.toString().padLeft(2, '0')}${date.minute.toString().padLeft(2, '0')}${date.second.toString().padLeft(2, '0')}";
          }
          originalTitles.add(title);
        }
      } finally {
        await processingToast.dismiss(immediate: true);
      }

      if (paths.isEmpty) {
        if (context.mounted) {
          VideoActionButtons._showTopBanner(
            context,
            "未找到可用的视频文件",
            backgroundColor: const Color(0xFFB00020),
          );
        }
        return;
      }

      if (context.mounted) {
        final library = Provider.of<LibraryService>(context, listen: false);
        VideoActionButtons._showTopBanner(
          context,
          "已开始后台导入 ${paths.length} 个媒体文件",
          autoHideDuration: const Duration(seconds: 2),
        );
        library.importVideosBackground(
          paths,
          collectionId,
          shouldCopy: false,
          originalTitles: originalTitles,
        );
      }
    } catch (e) {
      if (context.mounted) {
        VideoActionButtons._showTopBanner(
          context,
          "相册导入失败: $e",
          backgroundColor: const Color(0xFFB00020),
          autoHideDuration: const Duration(seconds: 3),
        );
      }
    }
  }

  Future<void> _pickFromFileManager(
    BuildContext context,
    String? collectionId,
  ) async {
    try {
      if (!await _requestStoragePermissionIfNeeded(context)) {
        return;
      }

      if (Platform.isAndroid) {
        final result = await VideoActionButtons._fileManagerChannel
            .invokeMethod<List<dynamic>>("pickFiles", {
              "mimeTypes": ["video/*", "audio/*"],
              "allowMultiple": true,
            });
        final pickedPaths = result?.whereType<String>().toList() ?? [];
        if (pickedPaths.isEmpty) {
          if (context.mounted) {
            VideoActionButtons._showTopBanner(context, "未选择任何媒体");
          }
          return;
        }

        if (context.mounted) {
          await VideoActionButtons.processImportedFiles(
            context,
            pickedPaths,
            collectionId,
          );
        }
        return;
      }

      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: LibraryService.supportedMediaExtensions
            .map((ext) => ext.replaceFirst('.', ''))
            .toList(),
        allowMultiple: true,
        withData: false,
        withReadStream: false,
      );

      if (result == null || result.files.isEmpty) {
        return;
      }

      final paths = result.files
          .where((f) => f.path != null)
          .map((f) => f.path!)
          .toList();
      if (paths.isEmpty) {
        if (context.mounted) {
          VideoActionButtons._showTopBanner(context, "未选择任何媒体");
        }
        return;
      }

      if (context.mounted) {
        await VideoActionButtons.processImportedFiles(
          context,
          paths,
          collectionId,
        );
      }
    } catch (e) {
      if (context.mounted) {
        VideoActionButtons._showTopBanner(
          context,
          "导入启动失败: $e",
          backgroundColor: const Color(0xFFB00020),
          autoHideDuration: const Duration(seconds: 3),
        );
      }
    }
  }

  Future<void> _pickArchiveFromFileManager(
    BuildContext context,
    String? collectionId,
  ) async {
    String? archivePath;
    try {
      if (!await _requestStoragePermissionIfNeeded(context)) {
        return;
      }

      if (Platform.isAndroid) {
        final result = await VideoActionButtons._fileManagerChannel
            .invokeMethod<Map<dynamic, dynamic>?>("pickArchive");
        if (result == null) {
          if (context.mounted) {
            VideoActionButtons._showTopBanner(context, "未选择压缩包");
          }
          return;
        }
        final selection = _ArchiveSelection.fromNativeMap(result);
        archivePath = selection.resolvedPath;
        if (context.mounted) {
          await VideoActionButtons._processSelectedArchive(
            context,
            selection,
            collectionId,
          );
        }
        return;
      }

      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: VideoActionButtons._structuredArchiveExtensions,
        allowMultiple: false,
        withData: false,
        withReadStream: false,
      );
      archivePath = result?.files.singleOrNull?.path;
      if (archivePath == null || archivePath.isEmpty) {
        if (context.mounted) {
          VideoActionButtons._showTopBanner(context, "未选择压缩包");
        }
        return;
      }

      if (!context.mounted) {
        return;
      }
      await VideoActionButtons.processDroppedArchive(
        context,
        archivePath,
        collectionId,
      );
    } catch (e) {
      await AppToast.dismiss(immediate: true);
      await VideoActionButtons._cleanupTemporaryArchiveSelection(archivePath);
      if (context.mounted) {
        VideoActionButtons._showTopBanner(
          context,
          "压缩包导入失败: $e",
          backgroundColor: const Color(0xFFB00020),
          autoHideDuration: const Duration(seconds: 3),
        );
      }
    }
  }

  Future<void> _pickFolderFromFileManager(
    BuildContext context,
    String? collectionId,
  ) async {
    try {
      if (!await _requestStoragePermissionIfNeeded(context)) {
        return;
      }

      final folderPath = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择要导入的文件夹',
      );
      if (folderPath == null || folderPath.isEmpty) {
        if (context.mounted) {
          VideoActionButtons._showTopBanner(context, "未选择文件夹");
        }
        return;
      }

      if (!context.mounted) return;
      await VideoActionButtons.processDroppedFolder(
        context,
        folderPath,
        collectionId,
      );
    } catch (e) {
      if (context.mounted) {
        VideoActionButtons._showTopBanner(
          context,
          "文件夹导入失败: $e",
          backgroundColor: const Color(0xFFB00020),
          autoHideDuration: const Duration(seconds: 3),
        );
      }
    }
  }
}

class _TemporaryStorageCategoryTile extends StatelessWidget {
  final TemporaryStorageCategoryReport report;
  final String sizeText;

  const _TemporaryStorageCategoryTile({
    required this.report,
    required this.sizeText,
  });

  @override
  Widget build(BuildContext context) {
    final note = report.note?.trim();
    final metaParts = <String>[
      '${report.fileCount} 个文件',
      sizeText,
      report.canClean ? '可清理' : '仅提示',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                report.title,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              sizeText,
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          report.description,
          style: const TextStyle(fontSize: 12, color: Colors.white70),
        ),
        const SizedBox(height: 2),
        Text(
          metaParts.join('  ·  '),
          style: const TextStyle(fontSize: 11, color: Colors.white54),
        ),
        if (note != null && note.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            note,
            style: const TextStyle(fontSize: 11, color: Colors.amberAccent),
          ),
        ],
      ],
    );
  }
}

enum _StructuredImportDialogAction { cancel, preview, confirm }

class _ArchiveImportToastBridge {
  final LibraryService library;
  bool _disposed = false;
  String _lastMessage = '';
  double? _lastProgress;

  _ArchiveImportToastBridge(this.library);

  void start({required String initialMessage}) {
    AppToast.showProgress(initialMessage, progress: 0.01);
    library.isImporting.addListener(_sync);
    library.importProgress.addListener(_sync);
    library.importStatus.addListener(_sync);
    _sync();
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    library.isImporting.removeListener(_sync);
    library.importProgress.removeListener(_sync);
    library.importStatus.removeListener(_sync);
  }

  void _sync() {
    if (_disposed) {
      return;
    }

    final isImporting = library.isImporting.value;
    final status = library.importStatus.value.trim();
    if (!isImporting && status.isEmpty) {
      return;
    }

    final progress = library.importProgress.value.clamp(0.0, 1.0).toDouble();
    final effectiveMessage = status.isNotEmpty ? status : '正在导入压缩包...';
    final effectiveProgress = _isIndeterminateArchiveStage(status)
        ? null
        : (progress > 0 ? progress : 0.01);
    if (_lastMessage == effectiveMessage &&
        _sameProgress(_lastProgress, effectiveProgress)) {
      return;
    }

    _lastMessage = effectiveMessage;
    _lastProgress = effectiveProgress;
    AppToast.updateProgress(
      message: effectiveMessage,
      progress: effectiveProgress,
    );
  }

  bool _isIndeterminateArchiveStage(String status) {
    return status.contains('准备解压压缩包') || status.contains('后台解压压缩包');
  }

  bool _sameProgress(double? left, double? right) {
    if (left == null || right == null) {
      return left == right;
    }
    return (left - right).abs() < 0.001;
  }
}

class _ArchiveSelection {
  final String displayName;
  final String? uri;
  final int? sizeBytes;
  String? resolvedPath;

  _ArchiveSelection({
    required this.displayName,
    required this.uri,
    required this.sizeBytes,
    required this.resolvedPath,
  });

  factory _ArchiveSelection.fromResolvedPath(String path) {
    int? sizeBytes;
    try {
      final file = File(path);
      if (file.existsSync()) {
        sizeBytes = file.lengthSync();
      }
    } catch (_) {}
    return _ArchiveSelection(
      displayName: p.basename(path),
      uri: null,
      sizeBytes: sizeBytes,
      resolvedPath: path,
    );
  }

  factory _ArchiveSelection.fromNativeMap(Map<dynamic, dynamic> raw) {
    final displayName = (raw['displayName'] as String?)?.trim();
    final uri = (raw['uri'] as String?)?.trim();
    final path = (raw['path'] as String?)?.trim();
    final sizeValue = raw['sizeBytes'];
    int? sizeBytes;
    if (sizeValue is int) {
      sizeBytes = sizeValue;
    } else if (sizeValue is num) {
      sizeBytes = sizeValue.toInt();
    }
    return _ArchiveSelection(
      displayName: (displayName == null || displayName.isEmpty)
          ? (path == null || path.isEmpty ? 'archive' : p.basename(path))
          : displayName,
      uri: uri == null || uri.isEmpty ? null : uri,
      sizeBytes: sizeBytes,
      resolvedPath: path == null || path.isEmpty ? null : path,
    );
  }

  bool get hasResolvedPath => resolvedPath != null && resolvedPath!.isNotEmpty;

  String? get sizeLabel {
    if (sizeBytes == null || sizeBytes! <= 0) {
      return null;
    }
    return LibraryService.formatSize(sizeBytes!);
  }

  StructuredImportSelectionSummary toSelectionSummary(LibraryService library) {
    // App-owned temporary copies may have UUID/timestamp prefixes. The
    // original display name is the stable source for validation and the root
    // collection title.
    final archiveNameOrPath = displayName;
    if (!LibraryService.isSupportedArchivePath(archiveNameOrPath)) {
      throw UnsupportedError('当前仅支持 zip、tar、tar.gz、tar.bz2、tar.xz 压缩包');
    }
    final sourcePath = hasResolvedPath
        ? resolvedPath!
        : 'Android 系统文件管理器已选中：$displayName';
    return StructuredImportSelectionSummary(
      sourcePath: sourcePath,
      sourceName: displayName,
      rootCollectionName: LibraryService.archiveRootCollectionName(
        archiveNameOrPath,
      ),
      isArchive: true,
      folderCount: 0,
      mediaFileCount: 0,
      detailsDeferred: true,
    );
  }
}
