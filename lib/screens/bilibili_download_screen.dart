import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/video_player_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/subtitle_util.dart';
import 'package:video_player_app/utils/app_toast.dart';

import 'package:video_player_app/widgets/bilibili_login_dialogs.dart';

class BilibiliDownloadScreen extends StatefulWidget {
  final String? initialInput;
  final String? targetFolderId;
  const BilibiliDownloadScreen({super.key, this.initialInput, this.targetFolderId});

  @override
  State<BilibiliDownloadScreen> createState() => _BilibiliDownloadScreenState();
}

class _BilibiliDownloadScreenState extends State<BilibiliDownloadScreen> {
  final TextEditingController _inputController = TextEditingController();
  int? _previousImageCacheMaxSize;
  int? _previousImageCacheMaxBytes;
  final FocusNode _shortcutFocusNode = FocusNode(debugLabel: 'BilibiliDownloadShortcutFocus');
  
  // Dialog helpers need access to API service, which is now in BilibiliDownloadService

  Widget _buildCheckboxWithSmallThumbnail({
    required bool value,
    required ValueChanged<bool?> onChanged,
    required String thumbnailUrl,
    double thumbnailWidth = 44,
    double thumbnailHeight = 28,
  }) {
    return SizedBox(
      width: 56,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(
            value: value,
            activeColor: Colors.pinkAccent,
            onChanged: onChanged,
          ),
          if (thumbnailUrl.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: _buildNetworkThumbnail(
                url: thumbnailUrl,
                width: thumbnailWidth,
                height: thumbnailHeight,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNetworkThumbnail({
    required String url,
    required double width,
    required double height,
  }) {
    if (url.isEmpty) {
      return Container(width: width, height: height, color: Colors.grey);
    }
    final media = MediaQuery.of(context);
    final dpr = media.devicePixelRatio;
    final scale = dpr <= 1.0 ? 1.0 : (dpr >= 1.25 ? 1.25 : dpr);
    int cacheWidth = (width * scale).round();
    int cacheHeight = (height * scale).round();
    String processedUrl = url;
    if (!url.contains('@') && (url.contains('hdslb.com') || url.contains('bilivideo.com'))) {
      processedUrl = "$url@${cacheWidth}w_${cacheHeight}h_1c.webp";
    }
    final provider = ResizeImage(
      NetworkImage(processedUrl),
      width: cacheWidth,
      height: cacheHeight,
      allowUpscaling: false,
    );
    return Image(
      image: provider,
      width: width,
      height: height,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.low,
      gaplessPlayback: true,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return Container(width: width, height: height, color: Colors.grey);
      },
      errorBuilder: (context, error, stackTrace) {
        return Container(width: width, height: height, color: Colors.grey);
      },
    );
  }
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final cache = PaintingBinding.instance.imageCache;
      _previousImageCacheMaxSize = cache.maximumSize;
      _previousImageCacheMaxBytes = cache.maximumSizeBytes;
      cache.maximumSize = 120;
      cache.maximumSizeBytes = 20 * 1024 * 1024;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (Platform.isWindows && mounted) {
        _shortcutFocusNode.requestFocus();
      }
    });
    if (widget.initialInput != null) {
      _inputController.text = widget.initialInput!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
         final service = Provider.of<BilibiliDownloadService>(context, listen: false);
         // Inject library service for auto-import
         service.libraryService = Provider.of<LibraryService>(context, listen: false);
         
         _parseVideo(service);
      });
    } else {
      // Inject library service even if no initial input, to ensure background tasks have it
      WidgetsBinding.instance.addPostFrameCallback((_) {
         final service = Provider.of<BilibiliDownloadService>(context, listen: false);
         service.libraryService = Provider.of<LibraryService>(context, listen: false);
      });
    }
  }

  KeyEventResult _handleEscKeyEvent(KeyEvent event) {
    if (!Platform.isWindows) return KeyEventResult.ignored;
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    final cache = PaintingBinding.instance.imageCache;
    if (_previousImageCacheMaxSize != null) {
      cache.maximumSize = _previousImageCacheMaxSize!;
    }
    if (_previousImageCacheMaxBytes != null) {
      cache.maximumSizeBytes = _previousImageCacheMaxBytes!;
    }
    _shortcutFocusNode.dispose();
    _inputController.dispose();
    super.dispose();
  }

  Future<void> _showCookieDialog(BilibiliDownloadService service) async {
    await showBilibiliLoginDialog(context);
  }

  void _showQrCodeLoginDialog(BilibiliDownloadService service) {
    showBilibiliQrCodeDialog(context);
  }

  Future<void> _parseVideo(BilibiliDownloadService service) async {
    final rawInput = _inputController.text;
    if (rawInput.trim().isEmpty) return;
    
    final hasCookie = await service.apiService.hasCookie();
    if (!hasCookie) {
      if (mounted) {
        AppToast.show("解析前请先扫码登录 Bilibili", type: AppToastType.error);
        _showQrCodeLoginDialog(service);
      }
      return;
    }

    // Call service to parse
    final success = await service.parseVideo(
      rawInput,
      onConfirmCollection: (title) async {
         // Show Dialog
         return await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
               backgroundColor: const Color(0xFF2C2C2C),
               title: const Text("发现合集", style: TextStyle(color: Colors.white)),
               content: Text("此视频属于合集：\n$title\n\n是否识别整个合集？", style: const TextStyle(color: Colors.white70)),
               actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false), 
                    child: const Text("仅识别此视频", style: TextStyle(color: Colors.grey))
                  ),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true), 
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.pinkAccent),
                    child: const Text("识别整个合集", style: TextStyle(color: Colors.white))
                  ),
               ]
            )
         ) ?? false;
      }
    );
    if (!success) {
       // Only clear input if success? Or keep pending?
       // The service doesn't return failed lines nicely yet, but it handles adding valid ones.
       // For now, let's just clear if at least one succeeded, or keep all if failed?
       // The original logic kept pending lines.
       // Let's rely on service state for status message.
    } else {
       // Clear input on success
       _inputController.clear();
    }
  }

  String _formatPath(String path) {
    if (Platform.isMacOS || Platform.isLinux) {
      final home = Platform.environment['HOME'];
      if (home != null && path.startsWith(home)) {
        return path.replaceFirst(home, '~');
      }
    }
    return path;
  }

  Future<void> _showDownloadSettings(BilibiliDownloadService service) async {
     int tempMax = service.maxConcurrentDownloads;
     int tempQuality = service.preferredQuality;
     String tempSubLang = service.preferredSubtitleLang;
     bool tempAi = service.preferAiSubtitles;
     bool tempAutoImport = service.autoImportToLibrary;
     bool tempAutoDelete = service.autoDeleteTaskAfterImport;
     bool tempSeqExport = service.sequentialExport;
    String defaultDownloadDir;
    if (Platform.isWindows) {
      final dataRootPath = await SettingsService().getDefaultLargeDataRootPath();
      defaultDownloadDir = p.join(dataRootPath, 'imported_videos');
    } else if (Platform.isMacOS) {
      final downloadDir = await getDownloadsDirectory();
      if (downloadDir != null) {
        defaultDownloadDir = p.join(downloadDir.path, 'imported_videos');
      } else {
        final appDir = await getApplicationDocumentsDirectory();
        defaultDownloadDir = p.join(appDir.path, 'imported_videos');
      }
    } else {
      final appDir = await getApplicationDocumentsDirectory();
      defaultDownloadDir = p.join(appDir.path, 'imported_videos');
    }
     String? tempCustomPath = service.customDownloadPath;
    if (!mounted) return;
     await showDialog(
       context: context,
       builder: (ctx) => StatefulBuilder(
         builder: (context, setState) {
           return AlertDialog(
             title: const Text("下载设置"),
             content: Column(
               mainAxisSize: MainAxisSize.min,
               children: [
                 Row(
                   children: [
                     const Text("最大并发下载数: "),
                     DropdownButton<int>(
                       value: tempMax,
                       items: List.generate(10, (i) => i + 1).map((e) => DropdownMenuItem(value: e, child: Text("$e"))).toList(),
                       onChanged: (val) {
                         if (val != null) setState(() => tempMax = val);
                       },
                     ),
                   ],
                 ),
                 const SizedBox(height: 16),
                 Row(
                   children: [
                     const Text("首选清晰度: "),
                     DropdownButton<int>(
                       value: tempQuality,
                       items: const [
                         DropdownMenuItem(value: 127, child: Text("8K")),
                         DropdownMenuItem(value: 120, child: Text("4K")),
                         DropdownMenuItem(value: 116, child: Text("1080P 60帧")),
                         DropdownMenuItem(value: 80, child: Text("1080P")),
                         DropdownMenuItem(value: 64, child: Text("720P")),
                         DropdownMenuItem(value: 32, child: Text("480P")),
                       ],
                       onChanged: (val) {
                         if (val != null) setState(() => tempQuality = val);
                       },
                     ),
                   ],
                 ),
                 const SizedBox(height: 16),
                 Row(
                   children: [
                     const Text("字幕偏好: "),
                     DropdownButton<String>(
                       value: tempSubLang,
                       items: const [
                         DropdownMenuItem(value: "none", child: Text("无")),
                         DropdownMenuItem(value: "zh", child: Text("中文")),
                         DropdownMenuItem(value: "en", child: Text("English")),
                         DropdownMenuItem(value: "ja", child: Text("日本語")),
                       ],
                       onChanged: (val) {
                         if (val != null) setState(() => tempSubLang = val);
                       },
                     ),
                   ],
                 ),
                 CheckboxListTile(
                   title: const Text("AI 字幕优先"),
                   value: tempAi,
                   onChanged: (val) {
                      if (val != null) setState(() => tempAi = val);
                   },
                   contentPadding: EdgeInsets.zero,
                 ),
                 CheckboxListTile(
                   title: const Text("下载完成后自动导入媒体库"),
                   value: tempAutoImport,
                   onChanged: (val) {
                      if (val != null) setState(() => tempAutoImport = val);
                   },
                   contentPadding: EdgeInsets.zero,
                 ),
                 CheckboxListTile(
                   title: const Text("导入媒体库后自动删除任务"),
                   value: tempAutoDelete,
                   onChanged: (val) {
                      if (val != null) setState(() => tempAutoDelete = val);
                   },
                   contentPadding: EdgeInsets.zero,
                 ),
                 CheckboxListTile(
                   title: Text("批量合成并导出时按顺序导出", style: TextStyle(color: tempAutoImport ? Colors.white : Colors.white38)),
                   subtitle: Text("等待前置任务导出后再进行当前任务导出", style: TextStyle(fontSize: 10, color: tempAutoImport ? Colors.white54 : Colors.white24)),
                   value: tempSeqExport,
                   onChanged: tempAutoImport ? (val) {
                      if (val != null) setState(() => tempSeqExport = val);
                   } : null,
                   contentPadding: EdgeInsets.zero,
                 ),
                  if (!Platform.isAndroid && !Platform.isIOS) ...[
                    const SizedBox(height: 16),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text("下载保存目录", style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _formatPath(tempCustomPath?.isNotEmpty == true ? tempCustomPath! : defaultDownloadDir),
                            style: const TextStyle(fontSize: 12, color: Colors.white70),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              ElevatedButton(
                                onPressed: () async {
                                  try {
                                    final path = await FilePicker.platform.getDirectoryPath(
                                      dialogTitle: "选择下载保存目录",
                                      lockParentWindow: true,
                                    );
                                    if (path != null && path.isNotEmpty) {
                                      setState(() => tempCustomPath = path);
                                    }
                                  } catch (e) {
                                    AppToast.show("打开目录选择失败，请重试", type: AppToastType.error);
                                  }
                                },
                                child: const Text("选择目录"),
                              ),
                              const SizedBox(width: 8),
                              TextButton(
                                onPressed: () {
                                  setState(() => tempCustomPath = defaultDownloadDir);
                                },
                                child: const Text("使用默认"),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
               ],
             ),
             actions: [
               TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
               ElevatedButton(
                 onPressed: () {
                    service.updateSettings(tempMax, tempQuality, tempSubLang, tempAi, tempAutoImport, tempAutoDelete, tempSeqExport, customPath: tempCustomPath);
                    Navigator.pop(ctx);
                    AppToast.show("设置已保存", type: AppToastType.success);
                 }, 
                 child: const Text("保存")
               ),
             ],
           );
         }
       ),
     );
  }
  
  Future<void> _importToLibrary(BilibiliDownloadService service, {BilibiliDownloadEpisode? episode}) async {
    final library = Provider.of<LibraryService>(context, listen: false);
    
    AppToast.showLoading("开始导入...");
    
    final count = await service.importToLibrary(library, episode: episode, targetFolderId: widget.targetFolderId);
    
    if (!mounted) return;
    
    AppToast.dismiss();
    
    if (count > 0) {
       AppToast.show("已导入 $count 个视频", type: AppToastType.success);
    } else {
       AppToast.show("导入失败或无已完成任务", type: AppToastType.error);
    }
  }

  void _showSubtitlePreview(BilibiliDownloadService service, BilibiliSubtitle sub) async {
    showDialog(
      context: context,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );
    
    try {
      final content = await service.apiService.fetchSubtitleContent(sub.url);
      final srt = SubtitleUtil.convertJsonToSrt(content);
      if (!mounted) return;
      Navigator.pop(context); // Dismiss loading
      
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text("字幕预览: ${sub.lanDoc}"),
            content: SizedBox(
              width: double.maxFinite,
              height: 400,
              child: SingleChildScrollView(
                child: Text(srt),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("关闭")),
            ],
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      AppToast.show("预览失败", type: AppToastType.error);
    }
  }

  void _previewVideo(BilibiliDownloadEpisode ep) async {
     if (ep.outputPath == null) {
        AppToast.show("文件路径为空，无法播放", type: AppToastType.error);
        return;
     }
     
     final file = File(ep.outputPath!);
     if (!await file.exists()) {
        if (!mounted) return;
        AppToast.show("视频文件不存在，可能已被删除或移动", type: AppToastType.error);
        return;
     }
     
     final videoItem = VideoItem(
        id: "preview_${ep.bvid}_${ep.page.page}_${DateTime.now().millisecondsSinceEpoch}",
        path: ep.outputPath!,
        title: "预览: ${ep.page.part}",
        durationMs: 0,
        lastUpdated: DateTime.now().millisecondsSinceEpoch,
        // Replace extension with .srt (case insensitive, handling mp4/mkv/etc)
        subtitlePath: ep.outputPath!.replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), '.srt'),
     );
     
     if (mounted) {
       // Unfocus before navigating to prevent keyboard from popping up when returning
       FocusScope.of(context).unfocus();
       Navigator.push(context, MaterialPageRoute(builder: (context) => VideoPlayerScreen(videoItem: videoItem)));
     }
  }

  void _deleteAllTasks(BilibiliDownloadService service) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("确认删除"),
        content: const Text("确定要清空所有任务吗？所有未导入的缓存数据将被永久删除。"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
          TextButton(
             onPressed: () {
                Navigator.pop(ctx);
                service.deleteAllTasks();
             }, 
             child: const Text("删除", style: TextStyle(color: Colors.red))
          ),
        ],
      )
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = Provider.of<BilibiliDownloadService>(context, listen: false);
    return Focus(
      focusNode: _shortcutFocusNode,
      autofocus: Platform.isWindows,
      onKeyEvent: (node, event) => _handleEscKeyEvent(event),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) {
          if (Platform.isWindows && !_shortcutFocusNode.hasFocus) {
            _shortcutFocusNode.requestFocus();
          }
        },
        child: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          child: Builder(
            builder: (context) {
              final media = MediaQuery.of(context);
          final isCompactAppBar = media.orientation == Orientation.portrait && media.size.width < 600;
          final double appBarIconSize = isCompactAppBar ? 20 : 24;
          final double appBarButtonSize = isCompactAppBar ? 36 : 40;
          final EdgeInsets appBarIconPadding = EdgeInsets.zero;
          final BoxConstraints appBarIconConstraints = BoxConstraints.tightFor(width: appBarButtonSize, height: appBarButtonSize);

              return Scaffold(
                backgroundColor: const Color(0xFF121212),
                appBar: AppBar(
                  titleSpacing: isCompactAppBar ? 8 : null,
                  title: Text(
                    "BBDown 下载",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: isCompactAppBar ? 16 : 18),
                  ),
                  backgroundColor: const Color(0xFF1E1E1E),
                  actions: [
                IconButton(
                  icon: Icon(Icons.select_all, size: appBarIconSize),
                  tooltip: "全选",
                  padding: appBarIconPadding,
                  constraints: appBarIconConstraints,
                  onPressed: service.selectAll,
                ),
                IconButton(
                  icon: Icon(Icons.delete_sweep, size: appBarIconSize),
                  tooltip: "清空任务",
                  padding: appBarIconPadding,
                  constraints: appBarIconConstraints,
                  onPressed: () => _deleteAllTasks(service),
                ),
                IconButton(
                  icon: Icon(Icons.settings, size: appBarIconSize),
                  tooltip: "下载设置",
                  padding: appBarIconPadding,
                  constraints: appBarIconConstraints,
                  onPressed: () => _showDownloadSettings(service),
                ),
                IconButton(
                  icon: Icon(Icons.person, size: appBarIconSize),
                  onPressed: () => _showCookieDialog(service),
                  tooltip: "登录/Cookie",
                  padding: appBarIconPadding,
                  constraints: appBarIconConstraints,
                ),
              ],
            ),
                body: Column(
                  children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  color: const Color(0xFF1E1E1E),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _inputController,
                          maxLines: 5,
                          minLines: 3,
                          expands: false,
                          keyboardType: TextInputType.multiline,
                          textInputAction: TextInputAction.newline,
                          decoration: const InputDecoration(
                            labelText: "输入 BV号 或 视频链接（链接包含视频标题前缀也可输入） (支持多行)",
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.all(12),
                            hintText: "每行一个链接，自动忽略前缀...",
                            isDense: true,
                          ),
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Column(
                         mainAxisAlignment: MainAxisAlignment.start,
                         children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.paste, color: Colors.white70, size: 20),
                                  tooltip: "粘贴",
                                  padding: const EdgeInsets.all(8),
                                  constraints: const BoxConstraints(),
                                  onPressed: () async {
                                     final data = await Clipboard.getData(Clipboard.kTextPlain);
                                     if (data?.text != null) {
                                       String currentText = _inputController.text;
                                       if (currentText.isNotEmpty && !currentText.endsWith('\n')) {
                                         currentText += '\n';
                                       }
                                       _inputController.text = currentText + data!.text!;
                                     }
                                  },
                                ),
                                const SizedBox(width: 4),
                                IconButton(
                                  icon: const Icon(Icons.clear, color: Colors.white70, size: 20),
                                  tooltip: "清空",
                                  padding: const EdgeInsets.all(8),
                                  constraints: const BoxConstraints(),
                                  onPressed: () {
                                     _inputController.clear();
                                  },
                                ),
                                const SizedBox(width: 4),
                                IconButton(
                                  icon: const Icon(Icons.keyboard_return, color: Colors.white70, size: 20),
                                  tooltip: "换行",
                                  padding: const EdgeInsets.all(8),
                                  constraints: const BoxConstraints(),
                                  onPressed: () {
                                     final text = _inputController.text;
                                     final selection = _inputController.selection;
                                     final newText = text.replaceRange(selection.start, selection.end, "\n");
                                     _inputController.value = TextEditingValue(
                                       text: newText,
                                       selection: TextSelection.collapsed(offset: selection.start + 1),
                                     );
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Consumer<BilibiliDownloadService>(
                              builder: (context, service, _) {
                                return ElevatedButton(
                                  onPressed: service.isParsing ? null : () => _parseVideo(service),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.pinkAccent,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                    minimumSize: const Size(64, 36),
                                  ),
                                  child: service.isParsing 
                                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) 
                                    : const Text("解析"),
                                );
                              },
                            ),
                         ],
                      ),
                    ],
                  ),
                ),
                Consumer<BilibiliDownloadService>(
                  builder: (context, service, _) {
                    if (service.parsingStatus == null) {
                      return const SizedBox.shrink();
                    }
                    return Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      color: Colors.black54,
                      child: Text(service.parsingStatus!, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    );
                  },
                ),
                Expanded(
                  child: Consumer<BilibiliDownloadService>(
                    builder: (context, service, _) {
                      if (service.tasks.isEmpty) {
                        return const Center(child: Text("请输入链接并解析", style: TextStyle(color: Colors.white30)));
                      }
                      return ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: service.tasks.length,
                        cacheExtent: 600,
                        addAutomaticKeepAlives: false,
                        addSemanticIndexes: false,
                        itemBuilder: (context, index) {
                          return RepaintBoundary(
                            child: _buildTaskCard(service, service.tasks[index]),
                          );
                        },
                      );
                    },
                  ),
                ),
                  ],
                ),
                bottomNavigationBar: Consumer<BilibiliDownloadService>(
                  builder: (context, service, _) {
                    final selectedCount = service.tasks
                        .expand((t) => t.videos)
                        .expand((v) => v.episodes)
                        .where((e) => e.isSelected)
                        .length;
                    return selectedCount > 0 ? _buildBottomBar(service) : const SizedBox.shrink();
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildTaskCard(BilibiliDownloadService service, BilibiliDownloadTask task) {
   bool isSingle = !task.isCollection && task.videos.length == 1 && task.videos.first.episodes.length == 1;
   final media = MediaQuery.of(context);
   final isCompactTitle = media.orientation == Orientation.portrait && media.size.width < 600;
    
    return Card(
      color: const Color(0xFF2C2C2C),
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          InkWell(
            onTap: () {
               task.isExpanded = !task.isExpanded;
               service.saveTasks(); // Persist UI state
            },
            onLongPress: () {
               bool newVal = !task.isSelected;
               task.isSelected = newVal;
               for (var v in task.videos) {
                  v.isSelected = newVal;
                  for (var e in v.episodes) {
                    e.isSelected = newVal;
                  }
               }
               service.saveTasks();
            },
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                   Checkbox(
                      value: task.isSelected,
                      activeColor: Colors.pinkAccent,
                      onChanged: (val) {
                        task.isSelected = val ?? false;
                        for (var video in task.videos) {
                          video.isSelected = task.isSelected;
                          for (var ep in video.episodes) {
                             ep.isSelected = task.isSelected;
                          }
                        }
                        service.saveTasks();
                      },
                   ),
                   ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: _buildNetworkThumbnail(
                        url: task.cover,
                        width: 80,
                        height: 50,
                      ),
                   ),
                   const SizedBox(width: 12),
                   Expanded(
                     child: InkWell(
                       onTap: (isSingle && task.videos.first.episodes.first.status == DownloadStatus.completed)
                           ? () => _previewVideo(task.videos.first.episodes.first)
                           : null,
                       child: Text(
                         task.title,
                        style: TextStyle(
                          color: Colors.white, 
                          fontWeight: FontWeight.bold,
                          decoration: (isSingle && task.videos.first.episodes.first.status == DownloadStatus.completed) ? TextDecoration.underline : null,
                          fontSize: isCompactTitle ? 13 : 14,
                        ),
                         maxLines: 2,
                         overflow: TextOverflow.ellipsis,
                       ),
                     ),
                   ),
                   Icon(
                     task.isExpanded ? Icons.expand_less : Icons.expand_more,
                     color: Colors.white70,
                   ),
                   IconButton(
                      icon: const Icon(Icons.refresh, size: 20, color: Colors.white70),
                      tooltip: "刷新任务信息",
                      onPressed: () {
                         for (var v in task.videos) {
                            for (var ep in v.episodes) {
                               service.fetchEpisodeInfo(ep);
                            }
                         }
                      },
                   ),
                ],
              ),
            ),
          ),
          
          if (task.isExpanded)
             isSingle 
                ? _buildSingleEpisodeControls(service, task.videos.first.episodes.first, task.videos.first, task)
                : Column(children: task.videos.map((v) => _buildVideoItem(service, v, task)).toList())
        ],
      ),
    );
  }

  Widget _buildSingleEpisodeControls(BilibiliDownloadService service, BilibiliDownloadEpisode ep, BilibiliVideoItem video, BilibiliDownloadTask task) {
     bool hasInfo = ep.availableVideoQualities.isNotEmpty;
     final media = MediaQuery.of(context);
     final isCompact = media.orientation == Orientation.portrait && media.size.width < 600;
     final double compactButtonSize = isCompact ? 26 : 28;
     final double compactIconSize = isCompact ? 19 : 20;
     final EdgeInsets iconPadding = isCompact ? EdgeInsets.zero : const EdgeInsets.all(4);
     final BoxConstraints iconConstraints = isCompact
         ? BoxConstraints.tightFor(width: compactButtonSize, height: compactButtonSize)
         : const BoxConstraints(minWidth: 28, minHeight: 28);
     final VisualDensity iconDensity = isCompact ? const VisualDensity(horizontal: -4, vertical: -4) : VisualDensity.standard;
     
     return Container(
       padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
       child: Column(
         children: [
           Row(
             children: [
                if (hasInfo || ep.status == DownloadStatus.completed)
                   Expanded(
                     child: Row(
                       mainAxisSize: MainAxisSize.max,
                       mainAxisAlignment: MainAxisAlignment.start,
                       children: [
                          // Quality
                          Flexible(
                            flex: 3,
                            child: Container(
                              height: 28,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.05),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<StreamItem>(
                                  value: ep.selectedVideoQuality,
                                  isDense: true,
                                  isExpanded: true,
                                  style: const TextStyle(fontSize: 11, color: Colors.white),
                                  dropdownColor: const Color(0xFF333333),
                                  icon: const Icon(Icons.arrow_drop_down, size: 16, color: Colors.white54),
                                  selectedItemBuilder: (BuildContext context) {
                                     return ep.availableVideoQualities.map<Widget>((StreamItem s) {
                                        String label = s.qualityName?.replaceAll("高清", "") ?? "Q${s.id}";
                                        String codec = "";
                                       if (s.codecs.startsWith("avc1")) {
                                         codec = "AVC";
                                       } else if (s.codecs.startsWith("hev1") || s.codecs.contains("hevc")) {
                                         codec = "HEVC";
                                       } else if (s.codecs.startsWith("av01")) {
                                         codec = "AV1";
                                       } else {
                                         codec = s.codecs.split('.')[0];
                                       }
                                        String detailedLabel = "$label ($codec)";
                                        return Container(
                                           alignment: Alignment.centerLeft,
                                           constraints: const BoxConstraints(minWidth: 50),
                                           child: SingleChildScrollView(
                                              scrollDirection: Axis.horizontal,
                                              child: Text(detailedLabel, style: const TextStyle(fontSize: 11, color: Colors.white)),
                                           ),
                                        );
                                     }).toList();
                                  },
                                  items: ep.availableVideoQualities.map((s) {
                                    String label = s.qualityName?.replaceAll("高清", "") ?? "Q${s.id}";
                                    String codec = "";
                                   if (s.codecs.startsWith("avc1")) {
                                     codec = "AVC";
                                   } else if (s.codecs.startsWith("hev1") || s.codecs.contains("hevc")) {
                                     codec = "HEVC";
                                   } else if (s.codecs.startsWith("av01")) {
                                     codec = "AV1";
                                   } else {
                                     codec = s.codecs.split('.')[0];
                                   }
                                    String detailedLabel = "$label ($codec)";
                                    return DropdownMenuItem(
                                      value: s, 
                                      child: Text(detailedLabel, overflow: TextOverflow.ellipsis)
                                    );
                                  }).toList(),
                                  onChanged: (val) {
                                     ep.selectedVideoQuality = val;
                                     service.saveTasks();
                                  },
                                  hint: const Text("清晰度", style: TextStyle(fontSize: 11, color: Colors.white54)),
                                ),
                              ),
                            ),
                          ),
                           const SizedBox(width: 4),
                          // Subtitle
                          Flexible(
                            flex: 2,
                            child: Container(
                              height: 28,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.05),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<BilibiliSubtitle?>(
                                  value: ep.selectedSubtitle,
                                  isDense: true,
                                  isExpanded: true,
                                  style: const TextStyle(fontSize: 11, color: Colors.white),
                                  dropdownColor: const Color(0xFF333333),
                                  icon: const Icon(Icons.arrow_drop_down, size: 16, color: Colors.white54),
                                  items: [
                                    const DropdownMenuItem<BilibiliSubtitle?>(value: null, child: Text("无字幕")),
                                    ...ep.availableSubtitles.map(
                                      (s) => DropdownMenuItem(
                                        value: s,
                                        child: Text(s.lanDoc, overflow: TextOverflow.ellipsis),
                                      ),
                                    ),
                                  ],
                                  onChanged: (val) {
                                     ep.selectedSubtitle = val;
                                     service.saveTasks();
                                  },
                                  hint: const Text("字幕", style: TextStyle(fontSize: 11, color: Colors.white54)),
                                ),
                              ),
                            ),
                          ),
                           const SizedBox(width: 2),
                          // Action Button
                           if (ep.status == DownloadStatus.downloading)
                              IconButton(
                                 icon: Icon(Icons.pause, size: compactIconSize, color: Colors.white70),
                                 tooltip: "暂停",
                                 padding: iconPadding,
                                 constraints: iconConstraints,
                                 visualDensity: iconDensity,
                                 onPressed: () => service.pauseDownload(ep),
                              )
                           else
                              IconButton(
                                 icon: Icon(
                                    ep.status == DownloadStatus.failed ? Icons.replay : 
                                    ep.status == DownloadStatus.queued ? Icons.hourglass_top : Icons.download,
                                    size: compactIconSize,
                                    color: ep.status == DownloadStatus.failed ? Colors.redAccent : Colors.white70
                                 ),
                                 tooltip: ep.status == DownloadStatus.queued ? "退出排队" : "加入排队 / 继续",
                                 padding: iconPadding,
                                 constraints: iconConstraints,
                                 visualDensity: iconDensity,
                                 onPressed: () {
                                    if (ep.status == DownloadStatus.queued) {
                                        service.pauseDownload(ep);
                                    } else if (ep.status == DownloadStatus.failed) {
                                        service.startSingleDownload(ep); 
                                    } else {
                                        service.startSingleDownload(ep);
                                    }
                                 },
                              ),
                           // More Menu
                           PopupMenuButton<String>(
                              icon: Icon(Icons.more_vert, size: compactIconSize, color: Colors.white70),
                              padding: EdgeInsets.zero,
                              offset: Offset(0, compactButtonSize),
                              color: const Color(0xFF333333),
                              onSelected: (value) {
                                 switch (value) {
                                   case 'top':
                                     service.startSingleDownload(ep, toTop: true);
                                     break;
                                   case 'export':
                                     _importToLibrary(service, episode: ep);
                                     break;
                                   case 'delete':
                                     service.removeEpisode(ep, task);
                                     break;
                                   case 'preview_sub':
                                      if (ep.selectedSubtitle != null) {
                                         _showSubtitlePreview(service, ep.selectedSubtitle!);
                                      }
                                      break;
                                 }
                              },
                              itemBuilder: (context) => [
                                 if (ep.status == DownloadStatus.pending || ep.status == DownloadStatus.failed || ep.status == DownloadStatus.queued)
                                   const PopupMenuItem(
                                     value: 'top',
                                     height: 36,
                                     child: Row(children: [Icon(Icons.vertical_align_top, size: 18), SizedBox(width: 12), Text("插队", style: TextStyle(fontSize: 14))]),
                                   ),
                                 if (ep.status == DownloadStatus.completed)
                                   const PopupMenuItem(
                                     value: 'export',
                                     height: 36,
                                     child: Row(children: [Icon(Icons.file_upload, size: 18), SizedBox(width: 12), Text("导出", style: TextStyle(fontSize: 14))]),
                                   ),
                                 if (ep.selectedSubtitle != null)
                                    const PopupMenuItem(
                                      value: 'preview_sub',
                                      height: 36,
                                      child: Row(children: [Icon(Icons.description, size: 18), SizedBox(width: 12), Text("预览字幕", style: TextStyle(fontSize: 14))]),
                                    ),
                                 const PopupMenuItem(
                                   value: 'delete',
                                   height: 36,
                                   child: Row(children: [Icon(Icons.delete, size: 18, color: Colors.redAccent), SizedBox(width: 12), Text("删除任务", style: TextStyle(fontSize: 14, color: Colors.redAccent))]),
                                 ),
                              ],
                           ),
                        ],
                      ),
                    )
                 else if (ep.status == DownloadStatus.fetchingInfo)
                   const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                 else 
                   TextButton.icon(
                     onPressed: () => service.fetchEpisodeInfo(ep),
                     icon: const Icon(Icons.refresh, size: 16),
                     label: const Text("获取信息"),
                   ),
              ],
            ),
            
            if (ep.status == DownloadStatus.downloading || ep.status == DownloadStatus.merging || ep.status == DownloadStatus.checking || ep.status == DownloadStatus.repairing)
               Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Column(
                     crossAxisAlignment: CrossAxisAlignment.start,
                     children: [
                       if (ep.status == DownloadStatus.checking)
                         const LinearProgressIndicator(
                            backgroundColor: Colors.grey,
                            color: Colors.blueAccent, 
                            minHeight: 4,
                         )
                       else if (ep.status == DownloadStatus.repairing)
                          LinearProgressIndicator(
                            value: ep.progress > 0 ? ep.progress : null, // Indeterminate if 0
                            backgroundColor: Colors.grey,
                            color: Colors.orangeAccent,
                            minHeight: 4,
                          )
                       else
                         LinearProgressIndicator(
                            value: ep.progress,
                            backgroundColor: Colors.grey[800],
                            color: Colors.orangeAccent,
                            minHeight: 4,
                         ),
                       const SizedBox(height: 4),
                       Row(
                         mainAxisAlignment: MainAxisAlignment.spaceBetween,
                         children: [
                           Text(
                              (ep.status == DownloadStatus.checking)
                                 ? "" 
                                 : "${(ep.progress * 100).toStringAsFixed(1)}%",
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                           ),
                           if (ep.downloadSpeed != null)
                              Row(
                                children: [
                                  if (ep.downloadSize != null && ep.status != DownloadStatus.checking && ep.status != DownloadStatus.repairing)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: Text(
                                         ep.downloadSize!,
                                         style: const TextStyle(color: Colors.white70, fontSize: 12),
                                      ),
                                    ),
                                  Text(
                                     ep.downloadSpeed!,
                                     style: TextStyle(
                                        color: (ep.status == DownloadStatus.repairing) ? Colors.orangeAccent : Colors.white70,
                                        fontSize: 12,
                                        fontWeight: (ep.status == DownloadStatus.repairing) ? FontWeight.bold : FontWeight.normal
                                     ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ],
                   )
                ),
             
             // Status Text for Completed/Exported
             if (ep.status == DownloadStatus.completed && ep.downloadSpeed != null)
               Padding(
                 padding: const EdgeInsets.only(top: 8),
                 child: Row(
                   children: [
                     Icon(
                       Icons.check, 
                       size: 14, 
                       color: ep.isExported ? Colors.blueAccent : Colors.greenAccent
                     ),
                     const SizedBox(width: 4),
                     Text(
                       ep.downloadSpeed!, 
                       style: TextStyle(
                         color: ep.isExported ? Colors.blueAccent : Colors.greenAccent, 
                         fontSize: 12
                       )
                     ),
                   ],
                 ),
               ),

             if (ep.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  ep.error!, 
                  style: TextStyle(
                    color: ep.error == "已暂停" ? Colors.amber : Colors.redAccent, 
                    fontSize: 12
                  )
                ),
              ),
         ],
       ),
     );
  }

  Widget _buildVideoItem(BilibiliDownloadService service, BilibiliVideoItem video, BilibiliDownloadTask task) {
    // Determine if we should show a flat list or a grouped list
    // If it's a collection, we want to show all videos clearly.
    // If a video has only 1 episode, we can just show that episode row (simplification).
    // If a video has multiple episodes, we show a header + episodes.
    
    // The user requested: "I don't want to click to see function keys."
    // So we avoid ExpansionTile which hides content by default.
    // We will render everything expanded.

    // FIX: Avoid redundant header if it's a single video task
    // If task is NOT a collection, the Task Header already shows the video info.
    bool showHeader = task.isCollection;

    if (video.episodes.length == 1) {
       // Single episode video: Just render the episode row.
       // Note: We need to ensure the checkbox logic in _buildEpisodeRow handles the video selection state too.
       // _buildEpisodeRow already does: video.isSelected = video.episodes.every(...)
       return _buildEpisodeRow(service, video.episodes.first, video, task);
    } else {
       // Multi-episode video: Show Header + List of Episodes
       return Column(
         crossAxisAlignment: CrossAxisAlignment.start,
         children: [
            // Video Header (Select All for this video)
            if (showHeader)
              InkWell(
                onTap: () {
                   // Toggle all episodes
                   bool newVal = !video.isSelected;
                   video.isSelected = newVal;
                   for (var ep in video.episodes) {
                      ep.isSelected = newVal;
                   }
                   service.saveTasks();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                       _buildCheckboxWithSmallThumbnail(
                         value: video.isSelected,
                         onChanged: (val) {
                           video.isSelected = val ?? false;
                           for (var ep in video.episodes) {
                             ep.isSelected = video.isSelected;
                           }
                           service.saveTasks();
                         },
                         thumbnailUrl: video.videoInfo.pic,
                         thumbnailWidth: 44,
                         thumbnailHeight: 28,
                       ),
                       const SizedBox(width: 8),
                       Expanded(
                          child: Text(
                            video.videoInfo.title,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                       ),
                    ],
                  ),
                ),
              ),
            // Episodes
            Column(
              children: video.episodes.map((ep) => _buildEpisodeRow(service, ep, video, task)).toList(),
            ),
         ],
       );
    }
  }

  Widget _buildEpisodeRow(BilibiliDownloadService service, BilibiliDownloadEpisode ep, BilibiliVideoItem video, BilibiliDownloadTask task) {
    bool hasInfo = ep.availableVideoQualities.isNotEmpty;
    bool isCompleted = ep.status == DownloadStatus.completed;
    final media = MediaQuery.of(context);
    final isCompact = media.orientation == Orientation.portrait && media.size.width < 600;
    final double compactButtonSize = isCompact ? 26 : 28;
    final double compactIconSize = isCompact ? 19 : 20;
    final EdgeInsets iconPadding = isCompact ? EdgeInsets.zero : const EdgeInsets.all(4);
    final BoxConstraints iconConstraints = isCompact
        ? BoxConstraints.tightFor(width: compactButtonSize, height: compactButtonSize)
        : const BoxConstraints(minWidth: 28, minHeight: 28);
    final VisualDensity iconDensity = isCompact ? const VisualDensity(horizontal: -4, vertical: -4) : VisualDensity.standard;
    
    double leftPadding = 16.0;
    if (task.isCollection) {
       if (video.episodes.length > 1) {
          leftPadding = 32.0; 
       } else {
          leftPadding = 16.0;
       }
    }

    return InkWell(
      onTap: () {
         ep.isSelected = !ep.isSelected;
         video.isSelected = video.episodes.every((e) => e.isSelected);
         if (!task.isCollection) {
            task.isSelected = video.isSelected;
         }
         service.saveTasks();
      },
      child: Container(
        padding: EdgeInsets.fromLTRB(leftPadding, 8, 8, 8), // Reduce right padding
        decoration: BoxDecoration(
           border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.05))),
        ),
        child: Column(
          children: [
             Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                   if (task.isCollection && video.episodes.length == 1)
                     _buildCheckboxWithSmallThumbnail(
                       value: ep.isSelected,
                       onChanged: (val) {
                         ep.isSelected = val ?? false;
                         video.isSelected = video.episodes.every((e) => e.isSelected);
                         service.saveTasks();
                       },
                       thumbnailUrl: video.videoInfo.pic,
                       thumbnailWidth: 40,
                       thumbnailHeight: 26,
                     )
                   else
                     Checkbox(
                       value: ep.isSelected,
                       activeColor: Colors.pinkAccent,
                       onChanged: (val) {
                         ep.isSelected = val ?? false;
                         video.isSelected = video.episodes.every((e) => e.isSelected);
                         if (!task.isCollection) {
                           task.isSelected = video.isSelected;
                         }
                         service.saveTasks();
                       },
                     ),
                   
                   Expanded(
                     child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Title Row with Action Buttons
                          Row(
                            children: [
                              Expanded(
                                child: InkWell(
                                   onTap: isCompleted ? () => _previewVideo(ep) : null,
                                   child: Padding(
                                     padding: const EdgeInsets.symmetric(vertical: 8),
                                     child: Text(
                                       video.episodes.length == 1 
                                          ? (task.isCollection ? video.videoInfo.title : "P${ep.page.page} ${ep.page.part}")
                                          : "P${ep.page.page} ${ep.page.part}",
                                       style: TextStyle(
                                          color: Colors.white70,
                                          decoration: isCompleted ? TextDecoration.underline : null,
                                          decorationColor: Colors.white70,
                                          fontSize: isCompact ? 13 : 14,
                                          height: 1.3,
                                       ),
                                       maxLines: 2,
                                       overflow: TextOverflow.ellipsis,
                                     ),
                                   ),
                                ),
                              ),
                              // Refresh Button (always visible if not fetching)
                              SizedBox(
                                width: compactButtonSize,
                                height: compactButtonSize,
                                child: ep.status == DownloadStatus.fetchingInfo
                                  ? const Center(
                                      child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                                    )
                                  : IconButton(
                                     icon: Icon(Icons.refresh, color: Colors.white70, size: compactIconSize),
                                     tooltip: "刷新信息",
                                     padding: iconPadding,
                                     constraints: iconConstraints,
                                     visualDensity: iconDensity,
                                     onPressed: () => service.fetchEpisodeInfo(ep),
                                  ),
                              ),

                              // Action Buttons (Download/Pause/More) moved here
                              if (hasInfo || ep.status == DownloadStatus.completed) ...[
                                 if (ep.status == DownloadStatus.downloading)
                                    IconButton(
                                       icon: Icon(Icons.pause, size: compactIconSize, color: Colors.white70),
                                       tooltip: "暂停",
                                       padding: iconPadding,
                                       constraints: iconConstraints,
                                       visualDensity: iconDensity,
                                       onPressed: () => service.pauseDownload(ep),
                                    )
                                 else
                                    IconButton(
                                       icon: Icon(
                                          ep.status == DownloadStatus.failed ? Icons.replay : 
                                          ep.status == DownloadStatus.queued ? Icons.hourglass_top : Icons.download,
                                          size: compactIconSize,
                                          color: ep.status == DownloadStatus.failed ? Colors.redAccent : Colors.white70
                                       ),
                                       tooltip: ep.status == DownloadStatus.queued ? "退出排队" : "加入排队 / 继续",
                                       padding: iconPadding,
                                       constraints: iconConstraints,
                                       visualDensity: iconDensity,
                                       onPressed: () {
                                          if (ep.status == DownloadStatus.queued) {
                                              service.pauseDownload(ep);
                                          } else if (ep.status == DownloadStatus.failed) {
                                              service.startSingleDownload(ep); 
                                          } else {
                                              service.startSingleDownload(ep);
                                          }
                                       },
                                    ),
                                 
                                 // More Menu
                                 SizedBox(
                                   width: compactButtonSize,
                                   height: compactButtonSize,
                                   child: PopupMenuButton<String>(
                                      icon: Icon(Icons.more_vert, size: compactIconSize, color: Colors.white70),
                                      padding: EdgeInsets.zero,
                                      offset: Offset(0, compactButtonSize),
                                      color: const Color(0xFF333333),
                                      onSelected: (value) {
                                         switch (value) {
                                           case 'top':
                                             service.startSingleDownload(ep, toTop: true);
                                             break;
                                           case 'export':
                                             _importToLibrary(service, episode: ep);
                                             break;
                                           case 'delete':
                                             service.removeEpisode(ep, task);
                                             break;
                                           case 'preview_sub':
                                              if (ep.selectedSubtitle != null) {
                                                 _showSubtitlePreview(service, ep.selectedSubtitle!);
                                              }
                                              break;
                                         }
                                      },
                                      itemBuilder: (context) => [
                                         if (ep.status == DownloadStatus.pending || ep.status == DownloadStatus.failed || ep.status == DownloadStatus.queued)
                                           const PopupMenuItem(
                                             value: 'top',
                                             height: 36,
                                             child: Row(children: [Icon(Icons.vertical_align_top, size: 18), SizedBox(width: 12), Text("插队", style: TextStyle(fontSize: 14))]),
                                           ),
                                         
                                         if (ep.status == DownloadStatus.completed)
                                           const PopupMenuItem(
                                             value: 'export',
                                             height: 36,
                                             child: Row(children: [Icon(Icons.file_upload, size: 18), SizedBox(width: 12), Text("导出", style: TextStyle(fontSize: 14))]),
                                           ),
                                         
                                         if (ep.selectedSubtitle != null)
                                            const PopupMenuItem(
                                              value: 'preview_sub',
                                              height: 36,
                                              child: Row(children: [Icon(Icons.description, size: 18), SizedBox(width: 12), Text("预览字幕", style: TextStyle(fontSize: 14))]),
                                            ),

                                         const PopupMenuItem(
                                           value: 'delete',
                                           height: 36,
                                           child: Row(children: [Icon(Icons.delete, size: 18, color: Colors.redAccent), SizedBox(width: 12), Text("删除任务", style: TextStyle(fontSize: 14, color: Colors.redAccent))]),
                                         ),
                                      ],
                                   ),
                                 ),
                              ]
                            ],
                          ),
                          
                          // Settings Row (Quality & Subtitle) - Only show if info available
                          if (hasInfo || ep.status == DownloadStatus.completed)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                children: [
                                  // Quality
                                  Flexible(
                                    flex: 3,
                                    child: Container(
                                      height: 28,
                                      padding: const EdgeInsets.symmetric(horizontal: 8),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(alpha: 0.05),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: DropdownButtonHideUnderline(
                                        child: DropdownButton<StreamItem>(
                                          value: ep.selectedVideoQuality,
                                          isDense: true,
                                          isExpanded: true,
                                          style: const TextStyle(fontSize: 11, color: Colors.white),
                                          dropdownColor: const Color(0xFF333333),
                                          icon: const Icon(Icons.arrow_drop_down, size: 16, color: Colors.white54),
                                          selectedItemBuilder: (BuildContext context) {
                                             return ep.availableVideoQualities.map<Widget>((StreamItem s) {
                                                String label = s.qualityName?.replaceAll("高清", "") ?? "Q${s.id}";
                                                String codec = "";
                                               if (s.codecs.startsWith("avc1")) {
                                                 codec = "AVC";
                                               } else if (s.codecs.startsWith("hev1") || s.codecs.contains("hevc")) {
                                                 codec = "HEVC";
                                               } else if (s.codecs.startsWith("av01")) {
                                                 codec = "AV1";
                                               } else {
                                                 codec = s.codecs.split('.')[0];
                                               }
                                                String detailedLabel = "$label ($codec)";
                                                return Container(
                                                   alignment: Alignment.centerLeft,
                                                   constraints: const BoxConstraints(minWidth: 50),
                                                   child: SingleChildScrollView(
                                                      scrollDirection: Axis.horizontal,
                                                      child: Text(detailedLabel, style: const TextStyle(fontSize: 11, color: Colors.white)),
                                                   ),
                                                );
                                             }).toList();
                                          },
                                          items: ep.availableVideoQualities.map((s) {
                                            String label = s.qualityName?.replaceAll("高清", "") ?? "Q${s.id}";
                                            String codec = "";
                                           if (s.codecs.startsWith("avc1")) {
                                             codec = "AVC";
                                           } else if (s.codecs.startsWith("hev1") || s.codecs.contains("hevc")) {
                                             codec = "HEVC";
                                           } else if (s.codecs.startsWith("av01")) {
                                             codec = "AV1";
                                           } else {
                                             codec = s.codecs.split('.')[0];
                                           }
                                            String detailedLabel = "$label ($codec)";
                                            
                                            return DropdownMenuItem(
                                              value: s, 
                                              child: Text(detailedLabel, overflow: TextOverflow.ellipsis)
                                            );
                                          }).toList(),
                                          onChanged: (val) {
                                             ep.selectedVideoQuality = val;
                                             service.saveTasks();
                                          },
                                          hint: const Text("清晰度", style: TextStyle(fontSize: 11, color: Colors.white54)),
                                        ),
                                      ),
                                    ),
                                  ),
                                  
                                  const SizedBox(width: 4),
                                  
                                  // Subtitle
                                  Flexible(
                                    flex: 2,
                                    child: Container(
                                      height: 28,
                                      padding: const EdgeInsets.symmetric(horizontal: 8),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(alpha: 0.05),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: DropdownButtonHideUnderline(
                                        child: DropdownButton<BilibiliSubtitle?>(
                                          value: ep.selectedSubtitle,
                                          isDense: true,
                                          isExpanded: true,
                                          style: const TextStyle(fontSize: 11, color: Colors.white),
                                          dropdownColor: const Color(0xFF333333),
                                          icon: const Icon(Icons.arrow_drop_down, size: 16, color: Colors.white54),
                                          items: [
                                            const DropdownMenuItem<BilibiliSubtitle?>(value: null, child: Text("无字幕")),
                                            ...ep.availableSubtitles.map(
                                              (s) => DropdownMenuItem(
                                                value: s,
                                                child: Text(s.lanDoc, overflow: TextOverflow.ellipsis),
                                              ),
                                            ),
                                          ],
                                          onChanged: (val) {
                                             ep.selectedSubtitle = val;
                                             service.saveTasks();
                                          },
                                          hint: const Text("字幕", style: TextStyle(fontSize: 11, color: Colors.white54)),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                     ),
                   ),
                ],
             ),
             
             // Progress Bar Area (unchanged)
             if (ep.status == DownloadStatus.downloading || ep.status == DownloadStatus.merging || ep.status == DownloadStatus.checking || ep.status == DownloadStatus.repairing)
                Padding(
                   padding: const EdgeInsets.only(left: 48, right: 16, top: 4),
                   child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (ep.status == DownloadStatus.checking)
                          const LinearProgressIndicator(
                             backgroundColor: Colors.grey,
                             color: Colors.blueAccent,
                             minHeight: 2,
                          )
                        else if (ep.status == DownloadStatus.repairing)
                           LinearProgressIndicator(
                             value: ep.progress > 0 ? ep.progress : null,
                             backgroundColor: Colors.grey,
                             color: Colors.orangeAccent,
                             minHeight: 2,
                           )
                        else
                          LinearProgressIndicator(
                             value: ep.progress,
                             backgroundColor: Colors.grey[800],
                             color: Colors.orangeAccent,
                             minHeight: 2,
                          ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                               (ep.status == DownloadStatus.checking) 
                                  ? ""
                                  : "${(ep.progress * 100).toStringAsFixed(1)}%",
                               style: const TextStyle(color: Colors.white38, fontSize: 10),
                            ),
                            if (ep.downloadSpeed != null)
                              Row(
                                children: [
                                  if (ep.downloadSize != null && ep.status != DownloadStatus.checking && ep.status != DownloadStatus.repairing)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: Text(
                                         ep.downloadSize!,
                                         style: const TextStyle(color: Colors.white38, fontSize: 10),
                                      ),
                                    ),
                                  Text(
                                     ep.downloadSpeed!,
                                     style: TextStyle(
                                        color: (ep.status == DownloadStatus.repairing) ? Colors.orangeAccent : Colors.white38,
                                        fontSize: 10,
                                        fontWeight: (ep.status == DownloadStatus.repairing) ? FontWeight.bold : FontWeight.normal
                                     ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ],
                   )
                ),
             
             // Status Text for Completed/Exported (Small)
             if (ep.status == DownloadStatus.completed && ep.downloadSpeed != null)
               Padding(
                 padding: const EdgeInsets.only(left: 48, top: 4),
                 child: Row(
                   children: [
                     Icon(
                       Icons.check, 
                       size: 10, 
                       color: ep.isExported ? Colors.blueAccent : Colors.greenAccent
                     ),
                     const SizedBox(width: 4),
                     Text(
                       ep.downloadSpeed!, 
                       style: TextStyle(
                         color: ep.isExported ? Colors.blueAccent : Colors.greenAccent, 
                         fontSize: 10
                       )
                     ),
                   ],
                 ),
               ),

             if (ep.error != null)
               Padding(
                 padding: const EdgeInsets.only(left: 48, top: 4),
                 child: Text(ep.error!, style: const TextStyle(color: Colors.redAccent, fontSize: 10)),
               ),
          ],
        ),
      ),
    );
  }



  Widget _buildBottomBar(BilibiliDownloadService service) {
    return BottomAppBar(
      color: const Color(0xFF1E1E1E),
      child: SizedBox(
        height: 60,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildBottomAction(Icons.download, "下载并合并字幕", service.startDownloadSelected),
            _buildBottomAction(Icons.pause, "暂停下载", service.pauseSelected),
            _buildBottomAction(Icons.file_upload, "导入到媒体库", () => _importToLibrary(service)),
            _buildBottomAction(Icons.delete, "移除", service.removeSelected, isDestructive: true),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomAction(IconData icon, String label, VoidCallback onTap, {bool isDestructive = false}) {
    final isSmallScreen = MediaQuery.of(context).size.width < 400;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: isSmallScreen ? 8.0 : 16.0, vertical: 8.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: isDestructive ? Colors.redAccent : Colors.white, size: isSmallScreen ? 20 : 24),
            const SizedBox(height: 2),
            Text(
              label, 
              style: TextStyle(
                color: isDestructive ? Colors.redAccent : Colors.white, 
                fontSize: isSmallScreen ? 9 : 10
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
