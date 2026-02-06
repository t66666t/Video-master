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
import '../utils/app_toast.dart';

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
             onPressed: () => Navigator.push(
               context, 
               MaterialPageRoute(
                 builder: (_) => BilibiliDownloadScreen(targetFolderId: collectionId),
                 settings: const RouteSettings(name: '/bilibili_download'),
               ),
             ),
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
                            onPressed: () => Navigator.push(
                              context, 
                              MaterialPageRoute(
                                builder: (_) => BilibiliDownloadScreen(targetFolderId: collectionId),
                                settings: const RouteSettings(name: '/bilibili_download'),
                              ),
                            ),
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
                  heroTag: "collapse_toggle_${collectionId ?? 'root'}",
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
        pickerConfig: AssetPickerConfig(
          requestType: RequestType.video | RequestType.audio,
          maxAssets: 999,
        ),
      );

      if (assets == null || assets.isEmpty) {
        if (context.mounted) {
          _showTopBanner(context, "未选择任何媒体");
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
          _showTopBanner(
            context,
            "未找到可用的视频文件",
            backgroundColor: const Color(0xFFB00020),
          );
        }
        return;
      }

      if (context.mounted) {
        final library = Provider.of<LibraryService>(context, listen: false);
        _showTopBanner(
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
        _showTopBanner(
          context,
          "相册导入失败: $e",
          backgroundColor: const Color(0xFFB00020),
          autoHideDuration: const Duration(seconds: 3),
        );
      }
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
            _showTopBanner(context, "未选择任何媒体");
          }
          return;
        }

        if (context.mounted) {
          await processImportedFiles(context, pickedPaths, collectionId);
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
          pickerConfig: AssetPickerConfig(
            requestType: RequestType.video | RequestType.audio,
            maxAssets: 999,
          ),
        );

        if (assets == null || assets.isEmpty) {
          if (context.mounted) {
            _showTopBanner(context, "未选择任何媒体");
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
            _showTopBanner(
              context,
              "未找到可用的媒体文件",
              backgroundColor: const Color(0xFFB00020),
            );
          }
          return;
        }

        if (context.mounted) {
          final library = Provider.of<LibraryService>(context, listen: false);
          _showTopBanner(
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
           await processImportedFiles(context, paths, collectionId);
        }
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
