import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../services/batch_import_service.dart';
import '../screens/batch_import_screen.dart';
import '../screens/bilibili_download_screen.dart';

class VideoActionButtons extends StatelessWidget {
  final String? collectionId;
  final bool isHorizontal; // For empty state usage if needed, though mostly for FAB

  const VideoActionButtons({
    super.key,
    this.collectionId,
    this.isHorizontal = false,
  });

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
      // Ensure permissions on Android
      if (Platform.isAndroid) {
        if (await Permission.videos.request().isGranted) {
        } else if (await Permission.storage.request().isGranted) {
        } else if (await Permission.manageExternalStorage.request().isGranted) {
        }
      }

      final ImagePicker picker = ImagePicker();
      List<XFile> medias = [];

      if (Platform.isAndroid) {
        // On Android, use pickMedia to support both video and audio
        final XFile? media = await picker.pickMedia();
        if (media != null) {
          medias = [media];
        }
      } else {
        medias = await picker.pickMultipleMedia();
      }
      
      if (medias.isNotEmpty) {
         if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
               const SnackBar(content: Text("正在处理媒体文件...")),
            );
         }

         // Prepare application storage
         final appDir = await getApplicationDocumentsDirectory();
         final importedDir = Directory(p.join(appDir.path, 'imported_videos'));
         if (!await importedDir.exists()) {
           await importedDir.create(recursive: true);
         }

         final List<String> savedPaths = [];
         final List<String> originalTitles = [];
         
         // Process and copy files
         for (var f in medias) {
            // Check if it's a video or audio (relaxed check)
            if (!Platform.isAndroid) {
               final videoExtensions = {
                 '.mp4', '.mov', '.avi', '.mkv', '.flv', '.webm', '.wmv', '.3gp', '.m4v', '.ts',
                 '.rmvb', '.mpg', '.mpeg', '.f4v', '.m2ts', '.mts', '.vob', '.ogv', '.divx'
               };
               final audioExtensions = {
                 '.mp3', '.m4a', '.wav', '.flac', '.ogg', '.aac', '.wma', '.opus', '.m4b', '.aiff'
               };
               final ext = p.extension(f.path).toLowerCase();
               final isVideoExt = videoExtensions.contains(ext);
               final isAudioExt = audioExtensions.contains(ext);
               final isVideoMime = f.mimeType != null && f.mimeType!.startsWith('video/');
               final isAudioMime = f.mimeType != null && f.mimeType!.startsWith('audio/');
               if (!isVideoExt && !isAudioExt && !isVideoMime && !isAudioMime) continue;
            }

            try {
                // 保存原始文件名，用于设置视频标题
                final sourceFileName = f.name ?? p.basename(f.path);
                originalTitles.add(sourceFileName);
                
                // 复制到内部存储时使用原始文件名
                var savedFileName = sourceFileName;
                var savedPath = p.join(importedDir.path, savedFileName);
                
                // 检查文件是否已存在，如果存在则添加后缀
                int counter = 1;
                while (await File(savedPath).exists()) {
                  final ext = p.extension(savedFileName);
                  final baseName = p.basenameWithoutExtension(savedFileName);
                  savedFileName = "${baseName}_$counter$ext";
                  savedPath = p.join(importedDir.path, savedFileName);
                  counter++;
                }
                
                // 使用更可靠的文件复制方式
                final bytes = await f.readAsBytes();
                final file = File(savedPath);
                await file.writeAsBytes(bytes);
                
                if (await file.exists() && await file.length() > 0) {
                  savedPaths.add(savedPath);
                }
            } catch (e) {
              debugPrint("Failed to save file ${f.path}: $e");
            }
         }
         
         if (savedPaths.isEmpty) {
             if (context.mounted) {
                ScaffoldMessenger.of(context).clearSnackBars();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("未找到支持的媒体文件或保存失败")),
                );
             }
             return;
         }
         
         if (context.mounted) {
            final library = Provider.of<LibraryService>(context, listen: false);
            ScaffoldMessenger.of(context).clearSnackBars();
            ScaffoldMessenger.of(context).showSnackBar(
               SnackBar(content: Text("已开始后台导入 ${savedPaths.length} 个媒体文件")),
            );
            // 传递原始标题列表，使用相册源文件的原始名称
            library.importVideosBackground(savedPaths, collectionId, shouldCopy: false, originalTitles: originalTitles);
         }
      } else {
        if (context.mounted) {
           ScaffoldMessenger.of(context).showSnackBar(
             const SnackBar(content: Text("未选择任何媒体")),
           );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("相册导入失败: $e")),
        );
      }
    }
  }

  static Future<void> _pickFromFileManager(BuildContext context, String? collectionId) async {
    try {
      if (Platform.isAndroid) {
        if (await Permission.videos.request().isGranted) {
        } else if (await Permission.storage.request().isGranted) {
        } else if (await Permission.manageExternalStorage.request().isGranted) {
        }
      }

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
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("已开始后台导入 ${paths.length} 个媒体文件")),
          );
        }

        library.importVideosBackground(paths, collectionId);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("导入启动失败: $e")),
        );
      }
    }
  }
}
