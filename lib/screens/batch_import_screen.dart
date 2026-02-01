import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';
import 'package:video_player_app/screens/simple_video_preview_screen.dart';
import 'package:video_player_app/screens/subtitle_preview_screen.dart';
import 'package:video_player_app/services/batch_import_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:path_provider/path_provider.dart';
import 'package:linked_scroll_controller/linked_scroll_controller.dart';
import '../models/video_item.dart';
import '../models/video_item.dart' as vi;
import '../utils/app_toast.dart';

class BatchImportScreen extends StatefulWidget {
  final String? folderId;
  const BatchImportScreen({super.key, this.folderId});

  @override
  State<BatchImportScreen> createState() => _BatchImportScreenState();
}

class _BatchImportScreenState extends State<BatchImportScreen> {
  late LinkedScrollControllerGroup _controllers;
  late ScrollController _videoController;
  late ScrollController _subtitleController;
  late ScrollController _actionController;

  @override
  void initState() {
    super.initState();
    _controllers = LinkedScrollControllerGroup();
    _videoController = _controllers.addAndGet();
    _subtitleController = _controllers.addAndGet();
    _actionController = _controllers.addAndGet();
  }

  @override
  void dispose() {
    _videoController.dispose();
    _subtitleController.dispose();
    _actionController.dispose();
    super.dispose();
  }

  Future<void> _pickVideos() async {
    // 显示导入方式选择对话框
    final importType = await _showImportTypeDialog();
    if (importType == null) return;

    if (importType == 'gallery') {
      await _pickFromGallery();
    } else {
      await _pickFromFileManager();
    }
  }

  Future<String?> _showImportTypeDialog() async {
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2C),
        title: const Text("选择导入方式", style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library, color: Colors.blueAccent),
              title: const Text("从相册导入", style: TextStyle(color: Colors.white)),
              subtitle: const Text("选择手机相册中的媒体文件", style: TextStyle(color: Colors.white70, fontSize: 12)),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            const Divider(color: Colors.white24),
            ListTile(
              leading: const Icon(Icons.folder_open, color: Colors.orangeAccent),
              title: const Text("从文件管理器导入", style: TextStyle(color: Colors.white)),
              subtitle: const Text("浏览文件系统选择媒体文件", style: TextStyle(color: Colors.white70, fontSize: 12)),
              onTap: () => Navigator.pop(context, 'file_manager'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("取消", style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }

  Future<void> _pickFromFileManager() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        // Video formats
        'mp4', 'mov', 'avi', 'mkv', 'flv', 'webm', 'wmv', '3gp', 'm4v', 'ts',
        'rmvb', 'mpg', 'mpeg', 'f4v', 'm2ts', 'mts', 'vob', 'ogv', 'divx',
        // Audio formats
        'mp3', 'm4a', 'wav', 'flac', 'ogg', 'aac', 'wma', 'opus', 'm4b', 'aiff'
      ],
      allowMultiple: true,
    );

    if (result != null) {
      final paths = result.paths.whereType<String>().toList();
      // Filter out non-media files
      final validPaths = paths.where((path) {
        final ext = p.extension(path).toLowerCase();
        final validExtensions = {
          // Video formats
          '.mp4', '.mov', '.avi', '.mkv', '.flv', '.webm', '.wmv', '.3gp', '.m4v', '.ts',
          '.rmvb', '.mpg', '.mpeg', '.f4v', '.m2ts', '.mts', '.vob', '.ogv', '.divx',
          // Audio formats
          '.mp3', '.m4a', '.wav', '.flac', '.ogg', '.aac', '.wma', '.opus', '.m4b', '.aiff'
        };
        return validExtensions.contains(ext);
      }).toList();
      
      if (validPaths.length < paths.length) {
        final skippedCount = paths.length - validPaths.length;
        if (mounted) {
          AppToast.show("已跳过 $skippedCount 个不支持的文件");
        }
      }
      
      if (validPaths.isNotEmpty && mounted) {
        context.read<BatchImportService>().addVideos(widget.folderId, validPaths);
      }
    }
  }

  Future<void> _pickFromGallery() async {
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.isAuth && !permission.isLimited) {
        if (mounted) {
          AppToast.show("未获得相册权限，请在系统设置中开启", type: AppToastType.error);
        }
        return;
      }

      if (!mounted) return;
      final List<AssetEntity>? assets = await AssetPicker.pickAssets(
        context,
        pickerConfig: const AssetPickerConfig(
          requestType: RequestType.video,
          maxAssets: 999,
        ),
      );

      if (assets == null || assets.isEmpty) return;

      if (mounted) {
        AppToast.show("正在处理媒体文件...");
      }

      final List<String> paths = [];
      for (final asset in assets) {
        final File? file = await asset.file;
        if (file == null) continue;
        paths.add(file.path);
      }

      if (paths.isEmpty) {
        if (mounted) {
          AppToast.show("未找到可用的媒体文件", type: AppToastType.error);
        }
        return;
      }

      if (paths.isNotEmpty && mounted) {
        context.read<BatchImportService>().addVideos(widget.folderId, paths);
      }
    } catch (e) {
      debugPrint("Gallery import error: $e");
      if (mounted) {
        AppToast.show("相册导入失败: $e", type: AppToastType.error);
      }
    }
  }

  Future<void> _pickSubtitles() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['srt', 'vtt', 'lrc', 'ass', 'ssa', 'sup', 'zip', 'sub', 'idx', 'scc'],
      allowMultiple: true,
    );

    if (result != null) {
      List<String> finalPaths = [];
      for (var path in result.paths.whereType<String>()) {
        final ext = p.extension(path).toLowerCase();
        if (ext == '.zip') {
          final extracted = await _extractZip(path);
          finalPaths.addAll(extracted);
        } else if (['.srt', '.vtt', '.lrc', '.ass', '.ssa', '.sup', '.sub', '.idx', '.scc'].contains(ext)) {
          finalPaths.add(path);
        }
      }
      
      if (finalPaths.isNotEmpty && mounted) {
        context.read<BatchImportService>().addSubtitles(widget.folderId, finalPaths);
      }
    }
  }

  Future<List<String>> _extractZip(String zipPath) async {
    List<String> extractedPaths = [];
    try {
      final bytes = File(zipPath).readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes);

      final tempDir = await getTemporaryDirectory();
      final destDir = Directory(p.join(tempDir.path, 'unzip_${Uuid().v4()}'));
      await destDir.create(recursive: true);

      for (final file in archive) {
        if (file.isFile) {
          final filename = file.name;
          if (filename.startsWith('__MACOSX') || filename.startsWith('.')) continue;

          final ext = p.extension(filename).toLowerCase();
          if (['.srt', '.vtt', '.lrc', '.ass', '.ssa', '.sup', '.sub', '.idx', '.scc'].contains(ext)) {
             final data = file.content as List<int>;
             final outFile = File(p.join(destDir.path, filename));
             await outFile.create(recursive: true);
             await outFile.writeAsBytes(data);
             extractedPaths.add(outFile.path);
          }
        }
      }
    } catch (e) {
      debugPrint("Error extracting zip: $e");
      if (mounted) {
         AppToast.show("解压失败: ${p.basename(zipPath)}", type: AppToastType.error);
      }
    }
    return extractedPaths;
  }

  Future<void> _handleMerge(String videoPath, String? subtitlePath) async {
    final library = Provider.of<LibraryService>(context, listen: false);
    final batch = Provider.of<BatchImportService>(context, listen: false);

    final id = Uuid().v4();
    final item = VideoItem(
      id: id,
      path: videoPath,
      title: p.basename(videoPath),
      durationMs: 0,
      lastUpdated: DateTime.now().millisecondsSinceEpoch,
      parentId: widget.folderId,
      subtitlePath: subtitlePath,
      type: _detectMediaType(videoPath),
    );

    // 使用原始文件路径，不创建缓存副本
    final resultId = await library.addSingleVideo(item, useOriginalPath: true);
    
    // 如果返回的ID与当前创建的ID不同，说明是重复视频
    final isDuplicate = resultId != null && resultId != id;
    final actualId = resultId ?? id;
    
    // Update Batch Service with new paths (LibraryService modified item.path/item.subtitlePath)
    if (item.path != videoPath) {
       batch.updateItemPath(widget.folderId, videoPath, item.path);
    }
    if (subtitlePath != null && item.subtitlePath != subtitlePath) {
       batch.updateItemPath(widget.folderId, subtitlePath, item.subtitlePath!);
    }

    batch.markImported(widget.folderId, item.path, actualId);
    
    if (mounted) {
      if (isDuplicate) {
        AppToast.show("该视频已存在，已关联到现有卡片", type: AppToastType.info);
      } else {
        AppToast.show("已合成并导入", type: AppToastType.success);
      }
    }
  }

  vi.MediaType _detectMediaType(String path) {
    final ext = p.extension(path).toLowerCase();
    final audioExtensions = {
      '.mp3', '.m4a', '.wav', '.flac', '.ogg', '.aac', '.wma', '.opus', '.m4b', '.aiff'
    };
    
    if (audioExtensions.contains(ext)) {
      return vi.MediaType.audio;
    }
    return vi.MediaType.video;
  }

  Future<void> _handleUndo(String videoPath) async {
    final library = Provider.of<LibraryService>(context, listen: false);
    final batch = Provider.of<BatchImportService>(context, listen: false);

    final importedId = batch.getImportedId(widget.folderId, videoPath);
    if (importedId != null) {
      // Keep the file because it's now in permanent storage and we want to allow re-import.
      // If we delete it, the user loses the file (since original temp was deleted on import).
      await library.removeSingleVideo(importedId, keepFile: true);
      batch.unmarkImported(widget.folderId, videoPath);
      
      if (mounted) {
         AppToast.show("已撤回导入", type: AppToastType.success);
      }
    }
  }

  void _showHelpDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2C),
        title: const Text("操作说明", style: TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHelpItem("1. 导入文件", "• 媒体（视频/音频）：支持批量多选导入。\n• 字幕：支持 srt, vtt, ass, ssa, lrc 格式，支持 zip 压缩包自动解压导入。"),
              const SizedBox(height: 12),
              _buildHelpItem("2. 列表调整", "• 滑动表格视图：二指同时按住列表项并上下滑动可滑动表格。\n• 拖拽：按住列表项可极速拖拽调整顺序。\n• 删除：左右滑动列表项可单独删除该项；点击最右侧红色删除按钮可删除整行。"),
              const SizedBox(height: 12),
              _buildHelpItem("3. 预览内容", "点击媒体或字幕文件名可进入预览页面。"),
              const SizedBox(height: 12),
              _buildHelpItem("4. 合成与撤回", "• 合成：点击\"合并\"图标将当前行的媒体与字幕关联并导入。\n• 撤回：已合成的项显示绿色，点击\"撤回\"图标可取消导入。"),
              const SizedBox(height: 12),
              _buildHelpItem("5. 自动保存", "所有操作自动保存。文件夹外的红色数字表示待处理媒体数。"),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("我知道了", style: TextStyle(color: Colors.blueAccent)),
          ),
        ],
      ),
    );
  }

  Widget _buildHelpItem(String title, String content) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
        const SizedBox(height: 4),
        Text(content, style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final batch = context.watch<BatchImportService>();
    final videoItems = batch.getVideoItems(widget.folderId);
    final subtitleItems = batch.getSubtitleItems(widget.folderId);
    final fontSize = batch.fontSize;
    final rowHeight = 40.0 + fontSize * 1.5;

    final maxLen = max(videoItems.length, subtitleItems.length);

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text("批量导入媒体及对应字幕", style: TextStyle(fontSize: 15)),
        centerTitle: false,
        backgroundColor: const Color(0xFF1E1E1E),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.remove),
            onPressed: () => batch.setFontSize(max(10.0, fontSize - 2)),
          ),
          Center(child: Text("${fontSize.toInt()}", style: const TextStyle(fontSize: 16))),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => batch.setFontSize(min(30.0, fontSize + 2)),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Column(
        children: [
          // Top Buttons
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _pickVideos,
                    icon: const Icon(Icons.video_library),
                    label: const Text('导入媒体'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: Colors.blueAccent,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _pickSubtitles,
                    icon: const Icon(Icons.subtitles),
                    label: const Text('导入字幕\n(支持zip)'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: Colors.orangeAccent,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                IconButton(
                  onPressed: _showHelpDialog,
                  icon: const Icon(Icons.help_outline, color: Colors.white70),
                  tooltip: "操作说明",
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.white10,
                    padding: const EdgeInsets.all(12),
                  ),
                ),
                const SizedBox(width: 16),
              ],
            ),
          ),
          
          // Header Row
          Container(
            color: Colors.white.withValues(alpha: 0.05),
            height: 40,
            child: Row(
              children: [
                Expanded(child: Center(child: Text('媒体列表', style: TextStyle(color: Colors.blueAccent.shade100, fontWeight: FontWeight.bold)))),
                Container(width: 1, color: Colors.white24),
                Expanded(child: Center(child: Text('字幕列表', style: TextStyle(color: Colors.orangeAccent.shade100, fontWeight: FontWeight.bold)))),
                Container(width: 1, color: Colors.white24),
                SizedBox(width: 100, child: Center(child: Text('操作', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)))),
              ],
            ),
          ),

          // Lists
          Expanded(
            child: Row(
              children: [
                // Video Column
                Expanded(
                  child: ReorderableListView.builder(
                    scrollController: _videoController,
                    buildDefaultDragHandles: false,
                    itemCount: videoItems.length,
                    onReorder: (oldIndex, newIndex) {
                      batch.moveVideo(widget.folderId, oldIndex, newIndex);
                    },
                    itemBuilder: (context, index) {
                      final item = videoItems[index];
                      final isImported = item.path != null && batch.isImported(widget.folderId, item.path!);
                      final duration = item.path != null ? batch.getDuration(widget.folderId, item.path!) : null;
                      
                      return ReorderableDragStartListener(
                        key: ValueKey(item.id),
                        index: index,
                        child: Dismissible(
                          key: ValueKey("${item.id}_dismiss"),
                          direction: DismissDirection.horizontal,
                          dismissThresholds: {
                            DismissDirection.startToEnd: 0.8,
                            DismissDirection.endToStart: 0.8,
                          },
                          background: Container(color: Colors.red, alignment: Alignment.centerLeft, padding: const EdgeInsets.only(left: 20), child: const Icon(Icons.delete, color: Colors.white)),
                          secondaryBackground: Container(color: Colors.red, alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 20), child: const Icon(Icons.delete, color: Colors.white)),
                          onDismissed: (_) {
                            batch.removeVideoItem(widget.folderId, index);
                          },
                          child: Container(
                            height: rowHeight,
                            decoration: BoxDecoration(
                              border: Border(bottom: BorderSide(color: Colors.white12)),
                              color: index % 2 == 0 ? Colors.white.withValues(alpha: 0.02) : Colors.transparent,
                            ),
                            child: item.path == null 
                              ? Center(child: Text("--", style: TextStyle(color: Colors.white24, fontSize: fontSize * 0.8)))
                              : InkWell(
                                  onTap: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => SimpleVideoPreviewScreen(videoPath: item.path!),
                                      ),
                                    );
                                  },
                                  child: Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          p.basename(item.path!),
                                          style: TextStyle(
                                            color: isImported ? Colors.green : Colors.white,
                                            fontSize: fontSize,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        if (duration != null)
                                          Text(duration, style: TextStyle(color: Colors.white54, fontSize: fontSize * 0.7)),
                                      ],
                                    ),
                                  ),
                                ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                
                VerticalDivider(width: 1, color: Colors.white24),

                // Subtitle Column
                Expanded(
                  child: ReorderableListView.builder(
                    scrollController: _subtitleController,
                    buildDefaultDragHandles: false,
                    itemCount: subtitleItems.length,
                    onReorder: (oldIndex, newIndex) {
                      batch.moveSubtitle(widget.folderId, oldIndex, newIndex);
                    },
                    itemBuilder: (context, index) {
                      final item = subtitleItems[index];
                      return ReorderableDragStartListener(
                        key: ValueKey(item.id),
                        index: index,
                        child: Dismissible(
                          key: ValueKey("${item.id}_dismiss"),
                          direction: DismissDirection.horizontal,
                          dismissThresholds: {
                            DismissDirection.startToEnd: 0.8,
                            DismissDirection.endToStart: 0.8,
                          },
                          background: Container(color: Colors.red, alignment: Alignment.centerLeft, padding: const EdgeInsets.only(left: 20), child: const Icon(Icons.delete, color: Colors.white)),
                          secondaryBackground: Container(color: Colors.red, alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 20), child: const Icon(Icons.delete, color: Colors.white)),
                          onDismissed: (_) {
                            batch.removeSubtitleItem(widget.folderId, index);
                          },
                          child: Container(
                            height: rowHeight,
                            decoration: BoxDecoration(
                              border: Border(bottom: BorderSide(color: Colors.white12)),
                              color: index % 2 == 0 ? Colors.white.withValues(alpha: 0.02) : Colors.transparent,
                            ),
                            child: item.path == null
                                ? Center(child: Text("--", style: TextStyle(color: Colors.white24, fontSize: fontSize * 0.8)))
                                : InkWell(
                                    onTap: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => SubtitlePreviewScreen(subtitlePath: item.path!),
                                        ),
                                      );
                                    },
                                    child: Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        p.basename(item.path!),
                                        style: TextStyle(color: Colors.white70, fontSize: fontSize),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                      );
                    },
                  ),
                ),

                VerticalDivider(width: 1, color: Colors.white24),

                // Action Column
                SizedBox(
                  width: 100,
                  child: ListView.builder(
                    controller: _actionController,
                    itemCount: maxLen,
                    itemExtent: rowHeight,
                    itemBuilder: (context, index) {
                      final videoItem = index < videoItems.length ? videoItems[index] : null;
                      final subItem = index < subtitleItems.length ? subtitleItems[index] : null;
                      
                      final hasVideo = videoItem?.path != null;
                      final isImported = hasVideo && batch.isImported(widget.folderId, videoItem!.path!);

                      return Container(
                        height: rowHeight,
                        decoration: BoxDecoration(
                          border: Border(bottom: BorderSide(color: Colors.white12)),
                          color: index % 2 == 0 ? Colors.white.withValues(alpha: 0.02) : Colors.transparent,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            if (hasVideo)
                              IconButton(
                                icon: Icon(
                                  isImported ? Icons.undo : Icons.merge_type,
                                  color: isImported ? Colors.orange : (subItem?.path != null ? Colors.blue : Colors.grey),
                                  size: fontSize + 4,
                                ),
                                onPressed: () {
                                   final videoPath = videoItem?.path;
                                   if (videoPath == null) return;
                                   if (isImported) {
                                     _handleUndo(videoPath);
                                   } else {
                                     _handleMerge(videoPath, subItem?.path);
                                   }
                                },
                              ),
                            IconButton(
                              icon: Icon(Icons.delete, color: Colors.red, size: fontSize + 4),
                              onPressed: () {
                                batch.removeRow(widget.folderId, index);
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
