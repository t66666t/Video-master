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

import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../services/batch_import_service.dart';
import '../services/bilibili/bilibili_download_service.dart';
import '../screens/batch_import_screen.dart';
import '../screens/bilibili_download_screen.dart';
import '../utils/app_toast.dart';

class VideoActionButtons extends StatefulWidget {
  final String? collectionId;
  final bool isHorizontal; // For empty state usage if needed, though mostly for FAB

  static const MethodChannel _fileManagerChannel = MethodChannel('com.example.video_player_app/file_manager');

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
    if (actionText != null && onActionPressed != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: backgroundColor ?? const Color(0xFF333333),
          duration: autoHideDuration,
          action: SnackBarAction(
            label: actionText,
            textColor: Colors.white,
            onPressed: onActionPressed,
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      AppToastType type = AppToastType.info;
      if (backgroundColor != null && backgroundColor.toARGB32() == 0xFFB00020) {
        type = AppToastType.error;
      }
      AppToast.show(message, type: type, duration: autoHideDuration);
    }
  }

  static Future<void> processImportedFiles(BuildContext context, List<String> paths, String? collectionId) async {
    final validExtensions = {
      '.mp4', '.mov', '.avi', '.mkv', '.flv', '.webm', '.wmv', '.3gp', '.m4v', '.ts',
      '.rmvb', '.mpg', '.mpeg', '.f4v', '.m2ts', '.mts', '.vob', '.ogv', '.divx',
      '.mp3', '.m4a', '.wav', '.flac', '.ogg', '.aac', '.wma', '.opus', '.m4b', '.aiff'
    };
    
    final validPaths = paths.where((path) => validExtensions.contains(p.extension(path).toLowerCase())).toList();
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

    final originalTitles = validPaths.map((path) => p.basename(path)).toList();
    if (context.mounted) {
      final library = Provider.of<LibraryService>(context, listen: false);
      _showTopBanner(
        context,
        "已开始后台导入 ${validPaths.length} 个媒体文件",
      );
      library.importVideosBackground(
        validPaths,
        collectionId,
        shouldCopy: false,
        originalTitles: originalTitles,
        allowDuplicatePath: true,
        useOriginalPath: true,
        allowCacheRescue: false,
      );
    }
  }

  @override
  State<VideoActionButtons> createState() => _VideoActionButtonsState();
}

class _VideoActionButtonsState extends State<VideoActionButtons> {
  Timer? _cleanupTimer;
  bool _suppressTap = false;

  @override
  void dispose() {
    _cleanupTimer?.cancel();
    super.dispose();
  }

  void _startCleanupTimer(BuildContext context) {
    if (!Platform.isAndroid) return;
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer(const Duration(seconds: 3), () async {
      _cleanupTimer = null;
      _suppressTap = true;
      if (!mounted) return;
      await _showCleanupDialog(context);
      if (mounted) {
        _suppressTap = false;
      }
    });
  }

  void _cancelCleanupTimer() {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
  }

  Future<_CleanupReport> _scanCleanupReport(BuildContext context) async {
    final service = Provider.of<BilibiliDownloadService>(context, listen: false);
    final tempDir = await getTemporaryDirectory();
    if (!await tempDir.exists()) {
      return _CleanupReport([]);
    }

    final activePaths = <String>{};
    try {
      for (var task in service.tasks) {
        for (var video in task.videos) {
          for (var ep in video.episodes) {
            if (ep.outputPath != null) {
              final outputPath = p.normalize(ep.outputPath!);
              activePaths.add(outputPath);
              final sidecar = outputPath.replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), '.srt');
              if (sidecar != outputPath) {
                activePaths.add(p.normalize(sidecar));
              }
            }
          }
        }
      }
    } catch (_) {}

    final categories = <String, _CleanupCategory>{
      'segments': _CleanupCategory('临时分片'),
      'subs': _CleanupCategory('临时字幕'),
      'merged': _CleanupCategory('合成产物'),
      'repaired': _CleanupCategory('修复产物'),
      'others': _CleanupCategory('其他过渡文件'),
      'cache': _CleanupCategory('其他缓存'),
    };

    try {
      await for (final entity in tempDir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        
        // Skip hidden files if necessary, but cache files might be hidden.
        // For now, include everything.
        
        final normalized = p.normalize(entity.path);
        if (activePaths.contains(normalized)) continue;
        
        // Check if file is inside a protected directory? 
        // We only protect specific files in activePaths.
        
        final name = p.basename(entity.path);
        final categoryKey = _matchCleanupCategory(name, entity.path);
        
        if (categoryKey != null) {
          final size = await entity.length();
          categories[categoryKey]!.add(entity.path, size);
        }
      }
    } catch (e) {
      debugPrint("Scan error: $e");
    }

    return _CleanupReport(categories.values.where((c) => c.totalBytes > 0).toList());
  }

  String? _matchCleanupCategory(String name, String fullPath) {
    if (name.startsWith('temp_subtitle_') || (name.startsWith('temp_') && name.endsWith('.srt'))) {
      return 'subs';
    }
    if (name.startsWith('temp_') && name.endsWith('.m4s')) {
      return 'segments';
    }
    if (name.startsWith('merged_')) {
      return 'merged';
    }
    if (name.startsWith('repaired_')) {
      return 'repaired';
    }
    if (name.startsWith('temp_')) {
      return 'others';
    }
    
    // Check for unzip directories
    if (fullPath.contains('${Platform.pathSeparator}unzip_')) {
      return 'others';
    }

    // Default catch-all for anything else in temp dir
    // This is aggressive but requested by user to clear space.
    return 'cache';
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

  Future<void> _deleteCleanupReport(_CleanupReport report) async {
    for (final path in report.allPaths) {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }
  }

  Future<void> _showCleanupDialog(BuildContext context) async {
    if (!Platform.isAndroid) return;
    bool isCleaning = false;
    _CleanupReport? report;

    await showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            Future<void> loadReport() async {
              final result = await _scanCleanupReport(dialogContext);
              if (!mounted) return;
              setState(() {
                report = result;
              });
            }

            if (report == null) {
              loadReport();
            }

            final total = report?.totalBytes ?? 0;
            final categories = report?.categories ?? [];

            return AlertDialog(
              title: const Text('清理过渡文件'),
              content: SizedBox(
                width: 320,
                child: report == null
                    ? const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()))
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('多余文件总大小：${_formatBytes(total)}', style: const TextStyle(fontSize: 13)),
                          const SizedBox(height: 8),
                          if (total == 0)
                            const Text('未发现可清理文件', style: TextStyle(fontSize: 13, color: Colors.white70)),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 220),
                            child: ListView.builder(
                              shrinkWrap: true,
                              itemCount: categories.length,
                              itemBuilder: (context, index) {
                                final item = categories[index];
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 4),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(child: Text(item.label, style: const TextStyle(fontSize: 12))),
                                      const SizedBox(width: 12),
                                      Text(_formatBytes(item.totalBytes), style: const TextStyle(fontSize: 12, color: Colors.white70)),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
              ),
              actions: [
                TextButton(
                  onPressed: isCleaning ? null : () => Navigator.pop(dialogContext),
                  child: const Text('关闭'),
                ),
                TextButton(
                  onPressed: isCleaning || total == 0
                      ? null
                      : () async {
                          setState(() {
                            isCleaning = true;
                          });
                          final current = report;
                          if (current != null) {
                            await _deleteCleanupReport(current);
                          }
                          if (!dialogContext.mounted) return;
                          final refreshed = await _scanCleanupReport(dialogContext);
                          if (!dialogContext.mounted) return;
                          setState(() {
                            report = refreshed;
                            isCleaning = false;
                          });
                        },
                  child: isCleaning ? const Text('清理中...') : const Text('一键清除'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isHorizontal) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ElevatedButton(
            onPressed: () => showCreateCollectionDialog(context, widget.collectionId),
            child: const Text("新建合集"),
          ),
          const SizedBox(width: 16),
          ElevatedButton(
            onPressed: () => importVideos(context, widget.collectionId),
            child: const Text("导入视频或音频"),
          ),
          const SizedBox(width: 16),
          ElevatedButton(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BatchImportScreen(folderId: widget.collectionId))),
            child: const Text("批量导入媒体"),
          ),
           const SizedBox(width: 16),
          Listener(
            onPointerDown: (_) => _startCleanupTimer(context),
            onPointerUp: (_) => _cancelCleanupTimer(),
            onPointerCancel: (_) => _cancelCleanupTimer(),
            child: ElevatedButton(
               onPressed: () {
                 if (_suppressTap) {
                   _suppressTap = false;
                   return;
                 }
                 Navigator.push(
                   context, 
                   MaterialPageRoute(
                     builder: (_) => BilibiliDownloadScreen(targetFolderId: widget.collectionId),
                     settings: const RouteSettings(name: '/bilibili_download'),
                   ),
                 );
               },
               style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFB7299), foregroundColor: Colors.white),
               child: const Text("B站下载"),
            ),
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
                    axisAlignment: 1.0, // Anchor at bottom
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
                            heroTag: "add_folder_${widget.collectionId}",
                            onPressed: () => showCreateCollectionDialog(context, widget.collectionId),
                            tooltip: "新建合集",
                            child: const Icon(Icons.create_new_folder),
                          ),
                          const SizedBox(height: 16),
                          FloatingActionButton(
                            heroTag: "add_video_${widget.collectionId}",
                            onPressed: () => importVideos(context, widget.collectionId),
                            tooltip: "导入视频或音频",
                            child: const Icon(Icons.video_call),
                          ),
                          const SizedBox(height: 16),
                          Listener(
                            onPointerDown: (_) => _startCleanupTimer(context),
                            onPointerUp: (_) => _cancelCleanupTimer(),
                            onPointerCancel: (_) => _cancelCleanupTimer(),
                            child: FloatingActionButton(
                              heroTag: "bbdown_download_${widget.collectionId}",
                              onPressed: () {
                                if (_suppressTap) {
                                  _suppressTap = false;
                                  return;
                                }
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => BilibiliDownloadScreen(targetFolderId: widget.collectionId),
                                    settings: const RouteSettings(name: '/bilibili_download'),
                                  ),
                                );
                              },
                              tooltip: "B站视频下载",
                              backgroundColor: const Color(0xFFFB7299),
                              child: const Icon(Icons.tv, color: Colors.white),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Consumer<BatchImportService>(
                            builder: (context, batch, _) {
                              final count = batch.getPendingCount(widget.collectionId);
                              return Stack(
                                clipBehavior: Clip.none,
                                alignment: Alignment.topRight,
                                children: [
                                  FloatingActionButton(
                                    heroTag: "batch_import_${widget.collectionId}",
                                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BatchImportScreen(folderId: widget.collectionId))),
                                    tooltip: "批量导入媒体及对应字幕",
                                    backgroundColor: Colors.deepPurpleAccent,
                                    child: const Icon(Icons.playlist_add, color: Colors.white),
                                  ),
                                  if (count > 0)
                                    Positioned(
                                      right: -4,
                                      top: -4,
                                      child: Container(
                                        padding: const EdgeInsets.all(6),
                                        decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle),
                                        child: Text("$count", style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                                      ),
                                    ),
                                ],
                              );
                            }
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
                    settings.updateSetting('isActionButtonsCollapsed', !isCollapsed);
                  },
                  tooltip: isCollapsed ? "展开" : "收起",
                  backgroundColor: const Color(0xFF333333),
                  foregroundColor: Colors.white,
                  child: Icon(isCollapsed ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down),
                ),
              ),
            ),
          ],
        );
      }
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
                Provider.of<LibraryService>(context, listen: false)
                    .createCollection(controller.text, parentId);
                Navigator.pop(context);
              }
            },
            child: const Text("创建"),
          ),
        ],
      ),
    );
  }

  Future<void> importVideos(BuildContext context, String? collectionId) async {
    // Desktop: Skip selection dialog, go straight to file manager
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      _pickFromFileManager(context, collectionId);
      return;
    }

    final mainContext = context;

    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
          ],
        ),
      ),
    );
  }

  Future<void> _pickFromGallery(BuildContext context, String? collectionId) async {
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

      AppToast.showLoading("正在处理媒体文件...");

      final List<String> paths = [];
      final List<String> originalTitles = [];

      for (final asset in assets) {
        final File? file = await asset.file;
        if (file == null) continue;
        paths.add(file.path);
        originalTitles.add(asset.title ?? p.basename(file.path));
      }

      AppToast.dismiss();

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
        );
        library.importVideosBackground(
          paths,
          collectionId,
          shouldCopy: false,
          originalTitles: originalTitles,
          allowDuplicatePath: true,
        );
      }
    } catch (e) {
      AppToast.dismiss();
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

  Future<void> _pickFromFileManager(BuildContext context, String? collectionId) async {
    try {
      if (Platform.isAndroid) {
        final hasPermission = await Permission.videos.request().isGranted ||
            await Permission.storage.request().isGranted ||
            await Permission.manageExternalStorage.request().isGranted;
        if (!hasPermission) {
          if (context.mounted) {
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
          return;
        }

        final result = await VideoActionButtons._fileManagerChannel.invokeMethod<List<dynamic>>(
          "pickFiles",
          {
            "mimeTypes": ["video/*", "audio/*"],
            "allowMultiple": true,
          },
        );
        final pickedPaths = result?.whereType<String>().toList() ?? [];
        if (pickedPaths.isEmpty) {
          if (context.mounted) {
            VideoActionButtons._showTopBanner(context, "未选择任何媒体");
          }
          return;
        }

        if (context.mounted) {
          await VideoActionButtons.processImportedFiles(context, pickedPaths, collectionId);
        }
        return;
      }

      if (Platform.isIOS) {
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

        AppToast.showLoading("正在处理媒体文件...");

        final List<String> paths = [];
        // originalTitles are handled inside processImportedFiles if we use it, 
        // but here assets are processed differently (async file retrieval). 
        // So for iOS/Gallery we keep the existing logic or adapt it. 
        // The user request specifically mentioned Windows drag & drop.
        // Let's keep iOS logic as is for now to avoid regression, or minimally touch it.
        // Actually, the iOS part does async `await asset.file`. 
        // Let's NOT refactor iOS part deeply to avoid breaking it.
        
        // ... (Re-pasting existing iOS logic if needed, but I am replacing _pickFromFileManager) ...
        // Wait, the search block is large. I should carefully replace only the Android and Desktop parts
        // or keep the structure and just call processImportedFiles.
        
        final List<String> originalTitles = [];
        for (final asset in assets) {
          final File? file = await asset.file;
          if (file == null) continue;
          paths.add(file.path);
          originalTitles.add(asset.title ?? p.basename(file.path));
        }

        AppToast.dismiss();

        if (paths.isEmpty) {
          if (context.mounted) {
            VideoActionButtons._showTopBanner(
              context,
              "未找到可用的媒体文件",
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
          );
          library.importVideosBackground(
            paths,
            collectionId,
            shouldCopy: false,
            originalTitles: originalTitles,
            allowDuplicatePath: true,
          );
        }
        return;
      }

      if (!context.mounted) return;
      // Desktop file picker
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          // Video formats
          'mp4', 'mov', 'avi', 'mkv', 'flv', 'webm', 'wmv', '3gp', 'm4v', 'ts',
          'rmvb', 'mpg', 'mpeg', 'f4v', 'm2ts', 'mts', 'vob', 'ogv', 'divx',
          // Audio formats
          'mp3', 'm4a', 'wav', 'flac', 'ogg', 'aac', 'wma', 'opus', 'm4b', 'aiff'
        ],
        allowMultiple: true,
        withData: false, 
        withReadStream: false, 
      );

      if (result != null && result.files.isNotEmpty) {
        final paths = result.files.where((f) => f.path != null).map((f) => f.path!).toList();
        if (context.mounted) {
           await VideoActionButtons.processImportedFiles(context, paths, collectionId);
        }
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
}

class _CleanupCategory {
  final String label;
  final List<String> paths = [];
  int totalBytes = 0;

  _CleanupCategory(this.label);

  void add(String path, int bytes) {
    paths.add(path);
    totalBytes += bytes;
  }
}

class _CleanupReport {
  final List<_CleanupCategory> categories;

  _CleanupReport(this.categories);

  int get totalBytes {
    return categories.fold(0, (sum, c) => sum + c.totalBytes);
  }

  List<String> get allPaths {
    return categories.expand((c) => c.paths).toList();
  }
}
