import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';
import 'package:path/path.dart' as p;

import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../services/batch_import_service.dart';
import '../screens/batch_import_screen.dart';
import '../screens/bilibili_download_screen.dart';

class VideoActionButtons extends StatelessWidget {
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
    Color backgroundColor = const Color(0xFF2C2C2C),
    Duration? autoHideDuration,
    String? actionText,
    VoidCallback? onActionPressed,
  }) {
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.hideCurrentMaterialBanner();
    messenger.showMaterialBanner(
      MaterialBanner(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: backgroundColor,
        actions: [
          if (actionText != null && onActionPressed != null)
            TextButton(
              onPressed: () {
                messenger.hideCurrentMaterialBanner();
                onActionPressed();
              },
              child: Text(actionText, style: const TextStyle(color: Colors.white)),
            ),
          TextButton(
            onPressed: () => messenger.hideCurrentMaterialBanner(),
            child: const Text("关闭", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (autoHideDuration != null) {
      Future.delayed(autoHideDuration, () {
        messenger.hideCurrentMaterialBanner();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isHorizontal) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ElevatedButton(
            onPressed: () => showCreateCollectionDialog(context, collectionId),
            child: const Text("新建合集"),
          ),
          const SizedBox(width: 16),
          ElevatedButton(
            onPressed: () => importVideos(context, collectionId),
            child: const Text("导入视频或音频"),
          ),
          const SizedBox(width: 16),
          ElevatedButton(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BatchImportScreen(folderId: collectionId))),
            child: const Text("批量导入媒体"),
          ),
           const SizedBox(width: 16),
          ElevatedButton(
             onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BilibiliDownloadScreen(targetFolderId: collectionId))),
             style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFB7299), foregroundColor: Colors.white),
             child: const Text("B站下载"),
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
          children: [
            FloatingActionButton.small(
              heroTag: "collapse_toggle_${collectionId ?? 'root'}",
              onPressed: () {
                settings.updateSetting('isActionButtonsCollapsed', !isCollapsed);
              },
              tooltip: isCollapsed ? "展开" : "收起",
              backgroundColor: const Color(0xFF333333),
              foregroundColor: Colors.white,
              child: Icon(isCollapsed ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                height: isCollapsed ? 0 : null,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 16),
                    FloatingActionButton(
                      heroTag: "add_folder_$collectionId",
                      onPressed: () => showCreateCollectionDialog(context, collectionId),
                      tooltip: "新建合集",
                      child: const Icon(Icons.create_new_folder),
                    ),
                    const SizedBox(height: 16),
                    FloatingActionButton(
                      heroTag: "add_video_$collectionId",
                      onPressed: () => importVideos(context, collectionId),
                      tooltip: "导入视频或音频",
                      child: const Icon(Icons.video_call),
                    ),
                    const SizedBox(height: 16),
                    FloatingActionButton(
                      heroTag: "bbdown_download_$collectionId",
                      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BilibiliDownloadScreen(targetFolderId: collectionId))),
                      tooltip: "B站视频下载",
                      backgroundColor: const Color(0xFFFB7299),
                      child: const Icon(Icons.tv, color: Colors.white),
                    ),
                    const SizedBox(height: 16),
                    Consumer<BatchImportService>(
                      builder: (context, batch, _) {
                        final count = batch.getPendingCount(collectionId);
                        return Stack(
                          clipBehavior: Clip.none,
                          alignment: Alignment.topRight,
                          children: [
                            FloatingActionButton(
                              heroTag: "batch_import_$collectionId",
                              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BatchImportScreen(folderId: collectionId))),
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
                  ],
                ),
              ),
            ),
          ],
        );
      }
    );
  }

  // Static methods to be reused if needed, or just kept here.
  
  static void showCreateCollectionDialog(BuildContext context, String? parentId) {
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

  static Future<void> importVideos(BuildContext context, String? collectionId) async {
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

  static Future<void> _pickFromGallery(BuildContext context, String? collectionId) async {
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.isAuth && !permission.isLimited) {
        if (context.mounted) {
          _showTopBanner(
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
        pickerConfig: const AssetPickerConfig(
          requestType: RequestType.video,
          maxAssets: 999,
        ),
      );

      if (assets == null || assets.isEmpty) {
        if (context.mounted) {
          _showTopBanner(
            context,
            "未选择任何媒体",
            autoHideDuration: const Duration(seconds: 2),
          );
        }
        return;
      }

      if (context.mounted) {
        _showTopBanner(context, "正在处理媒体文件...");
      }

      final List<String> paths = [];
      final List<String> originalTitles = [];

      for (final asset in assets) {
        final File? file = await asset.file;
        if (file == null) continue;
        paths.add(file.path);
        originalTitles.add(asset.title ?? p.basename(file.path));
      }

      if (paths.isEmpty) {
        if (context.mounted) {
          _showTopBanner(
            context,
            "未找到可用的视频文件",
            backgroundColor: const Color(0xFFB00020),
            autoHideDuration: const Duration(seconds: 2),
          );
        }
        return;
      }

      if (context.mounted) {
        final library = Provider.of<LibraryService>(context, listen: false);
        _showTopBanner(
          context,
          "已开始后台导入 ${paths.length} 个媒体文件",
          autoHideDuration: const Duration(seconds: 2),
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
      if (context.mounted) {
        _showTopBanner(
          context,
          "相册导入失败: $e",
          backgroundColor: const Color(0xFFB00020),
          autoHideDuration: const Duration(seconds: 3),
        );
      }
    }
  }

  static Future<void> _pickFromFileManager(BuildContext context, String? collectionId) async {
    try {
      if (Platform.isAndroid) {
        final hasPermission = await Permission.videos.request().isGranted ||
            await Permission.storage.request().isGranted ||
            await Permission.manageExternalStorage.request().isGranted;
        if (!hasPermission) {
          if (context.mounted) {
            _showTopBanner(
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

        final result = await _fileManagerChannel.invokeMethod<List<dynamic>>(
          "pickFiles",
          {
            "mimeTypes": ["video/*", "audio/*"],
            "allowMultiple": true,
          },
        );
        final pickedPaths = result?.whereType<String>().toList() ?? [];
        if (pickedPaths.isEmpty) {
          if (context.mounted) {
            _showTopBanner(
              context,
              "未选择任何媒体",
              autoHideDuration: const Duration(seconds: 2),
            );
          }
          return;
        }

        final validExtensions = {
          '.mp4', '.mov', '.avi', '.mkv', '.flv', '.webm', '.wmv', '.3gp', '.m4v', '.ts',
          '.rmvb', '.mpg', '.mpeg', '.f4v', '.m2ts', '.mts', '.vob', '.ogv', '.divx',
          '.mp3', '.m4a', '.wav', '.flac', '.ogg', '.aac', '.wma', '.opus', '.m4b', '.aiff'
        };
        final paths = pickedPaths.where((path) => validExtensions.contains(p.extension(path).toLowerCase())).toList();
        if (paths.isEmpty) {
          if (context.mounted) {
            _showTopBanner(
              context,
              "未找到可用的媒体文件",
              backgroundColor: const Color(0xFFB00020),
              autoHideDuration: const Duration(seconds: 2),
            );
          }
          return;
        }

        final originalTitles = paths.map((path) => p.basename(path)).toList();
        if (context.mounted) {
          final library = Provider.of<LibraryService>(context, listen: false);
          _showTopBanner(
            context,
            "已开始后台导入 ${paths.length} 个媒体文件",
            autoHideDuration: const Duration(seconds: 2),
          );
          library.importVideosBackground(
            paths,
            collectionId,
            shouldCopy: false,
            originalTitles: originalTitles,
            allowDuplicatePath: true,
            useOriginalPath: true,
          );
        }
        return;
      }

      if (Platform.isIOS) {
        final permission = await PhotoManager.requestPermissionExtend();
        if (!permission.isAuth && !permission.isLimited) {
          if (context.mounted) {
            _showTopBanner(
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
          pickerConfig: const AssetPickerConfig(
            requestType: RequestType.all,
            maxAssets: 999,
          ),
        );

        if (assets == null || assets.isEmpty) {
          if (context.mounted) {
            _showTopBanner(
              context,
              "未选择任何媒体",
              autoHideDuration: const Duration(seconds: 2),
            );
          }
          return;
        }

        if (context.mounted) {
          _showTopBanner(context, "正在处理媒体文件...");
        }

        final List<String> paths = [];
        final List<String> originalTitles = [];

        for (final asset in assets) {
          final File? file = await asset.file;
          if (file == null) continue;
          paths.add(file.path);
          originalTitles.add(asset.title ?? p.basename(file.path));
        }

        if (paths.isEmpty) {
          if (context.mounted) {
            _showTopBanner(
              context,
              "未找到可用的媒体文件",
              backgroundColor: const Color(0xFFB00020),
              autoHideDuration: const Duration(seconds: 2),
            );
          }
          return;
        }

        if (context.mounted) {
          final library = Provider.of<LibraryService>(context, listen: false);
          _showTopBanner(
            context,
            "已开始后台导入 ${paths.length} 个媒体文件",
            autoHideDuration: const Duration(seconds: 2),
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
      final library = Provider.of<LibraryService>(context, listen: false);

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
          _showTopBanner(
            context,
            "已开始后台导入 ${paths.length} 个媒体文件",
            autoHideDuration: const Duration(seconds: 2),
          );
        }

        library.importVideosBackground(
          paths,
          collectionId,
          allowCacheRescue: false,
          allowDuplicatePath: true,
          useOriginalPath: true,
        );
      }
    } catch (e) {
      if (context.mounted) {
        _showTopBanner(
          context,
          "导入启动失败: $e",
          backgroundColor: const Color(0xFFB00020),
          autoHideDuration: const Duration(seconds: 3),
        );
      }
    }
  }
}
