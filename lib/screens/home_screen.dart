import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import 'collection_screen.dart';
import 'recycle_bin_screen.dart';
import '../models/video_collection.dart';
import '../models/video_item.dart';
import '../widgets/folder_drop_target.dart';
import 'package:flutter/services.dart';
import '../services/bilibili/bilibili_download_service.dart';
import '../models/bilibili_download_task.dart';
import 'portrait_video_screen.dart';
import 'video_player_screen.dart';

import '../services/batch_import_service.dart';
import 'batch_import_screen.dart';
import 'bilibili_download_screen.dart';
import 'package:video_player_app/widgets/bilibili_login_dialogs.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../widgets/mini_playback_card.dart';
import '../widgets/video_action_buttons.dart';
import '../services/media_playback_service.dart';
import '../services/playlist_manager.dart';
import 'dart:convert';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  bool _isSelectionMode = false;
  final Set<String> _selectedIds = {};

  // Pinch to zoom state
  double _baseScale = 1.0;
  int _baseCrossAxisCount = 2;

  // Clipboard
  String? _lastProcessedClipboard;

  // 是否有待恢复的播放状态（用于首次启动时预留空间）
  bool _hasPendingPlaybackState = false;

  /// 计算播放卡片的底部填充，确保内容不被遮挡
  double _getPlaybackCardBottomPadding() {
    final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
    final isVisible = playbackService.currentItem != null &&
        (playbackService.state == PlaybackState.playing ||
         playbackService.state == PlaybackState.paused);
    
    if (!isVisible) {
      // 如果有待恢复的播放状态，预留空间避免首次启动时遮挡
      if (_hasPendingPlaybackState) {
        final screenWidth = MediaQuery.of(context).size.width;
        final isPhone = screenWidth < 600;
        final isTablet = screenWidth >= 600 && screenWidth < 1200;
        
        if (isPhone) return 117.0;
        if (isTablet) return 127.0;
        return 107.0;
      }
      return 0.0;
    }
    
    // 根据屏幕宽度计算卡片高度（与 PlaybackCardLayout 保持一致）
    final screenWidth = MediaQuery.of(context).size.width;
    final isPhone = screenWidth < 600;
    final isTablet = screenWidth >= 600 && screenWidth < 1200;
    
    if (isPhone) return 117.0;
    if (isTablet) return 127.0;
    return 107.0;
  }

  /// 检查是否有待恢复的播放状态（用于首次启动时预留空间）
  Future<void> _checkPendingPlaybackState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString('playback_state_snapshot');
      if (jsonString != null && jsonString.isNotEmpty) {
        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        final currentItemId = json['currentItemId'] as String?;
        _hasPendingPlaybackState = currentItemId != null;
      }
    } catch (e) {
      debugPrint('检查播放状态失败: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 使用非阻塞方式调用,避免卡住UI
      _checkBilibiliLogin();
      _checkClipboard();
      _checkPendingPlaybackState();
    });
    
    // 监听播放服务状态，当播放状态恢复完成后清除待恢复标志
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
      playbackService.addListener(_onPlaybackServiceChanged);
    });
  }
  
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
    playbackService.removeListener(_onPlaybackServiceChanged);
    super.dispose();
  }
  
  /// 播放服务状态变化监听器
  void _onPlaybackServiceChanged() {
    if (_hasPendingPlaybackState) {
      final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
      // 当播放状态恢复完成（currentItem 被设置）后，清除待恢复标志
      if (playbackService.currentItem != null) {
        setState(() {
          _hasPendingPlaybackState = false;
        });
      }
    }
  }

  Future<void> _checkBilibiliLogin() async {
    if (!mounted) return;
    
    try {
      final service = Provider.of<BilibiliDownloadService>(context, listen: false);
      
      // Check if login is valid (calls Bilibili API)
      // We only check this on startup to avoid spamming the user
      // 添加超时处理,避免网络请求卡住UI
      final isValid = await service.apiService.checkLoginStatus()
          .timeout(const Duration(seconds: 5), onTimeout: () {
        debugPrint('B站登录状态检查超时');
        return false;
      });
    
      if (!isValid) {
        if (!mounted) return;
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: const Color(0xFF2C2C2C),
            title: const Text("B站功能受限提示", style: TextStyle(color: Colors.white)),
            content: const Text(
              "检测到您尚未登录或Cookie已过期。\n\n不扫码就无法使用剪贴板识别b站视频与B站视频解析功能。",
              style: TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("暂不登录", style: TextStyle(color: Colors.grey)),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  showBilibiliLoginDialog(context);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFB7299),
                  foregroundColor: Colors.white,
                ),
                child: const Text("去扫码"),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      // 静默处理错误,不影响应用启动
      debugPrint('B站登录状态检查失败: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
       _checkClipboard();
    }
  }

  Future<void> _checkClipboard() async {
    try {
      // 1. Check Login
      if (!mounted) return;
      final service = Provider.of<BilibiliDownloadService>(context, listen: false);
      
      // 添加超时处理
      final hasCookie = await service.apiService.hasCookie()
          .timeout(const Duration(seconds: 2), onTimeout: () => false);
      if (!hasCookie) return;

      // 2. Get Clipboard
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final content = data?.text;
      if (content == null || content.trim().isEmpty) return;
      
      // 3. Avoid duplicate checks
      if (content == _lastProcessedClipboard) return;
      
      // 4. Try Parse
      if (!content.contains("bilibili.com") && 
          !content.contains("b23.tv") && 
          !content.contains("BV") && 
          !content.contains("av") && 
          !content.contains("ss") && 
          !content.contains("ep")) {
         return;
      }

      final task = await service.parseSingleLine(content)
          .timeout(const Duration(seconds: 5), onTimeout: () => null);
      if (task != null) {
        _lastProcessedClipboard = content;
        if (mounted) {
           _showClipboardDialog(content, task);
        }
      }
    } catch (e) {
      // Ignore - 不影响应用启动
      debugPrint('剪贴板检查失败: $e');
    }
  }

  void _showClipboardDialog(String content, BilibiliDownloadTask task) {
    final title = task.singleVideoInfo?.title ?? task.collectionInfo?.title ?? "未知标题";
    final cover = task.singleVideoInfo?.pic ?? task.collectionInfo?.cover ?? "";
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2C),
        contentPadding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (cover.isNotEmpty)
              ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                child: Image.network(
                  cover,
                  height: 160,
                  fit: BoxFit.cover,
                  errorBuilder: (_,__,___) => Container(height: 160, color: Colors.grey[800], child: const Icon(Icons.broken_image)),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                   const Text("检测到 Bilibili 视频", style: TextStyle(fontSize: 12, color: Colors.blueAccent, fontWeight: FontWeight.bold)),
                   const SizedBox(height: 8),
                   Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white), maxLines: 2, overflow: TextOverflow.ellipsis),
                   const SizedBox(height: 12),
                   const Text("是否前往下载页导入该视频？", style: TextStyle(fontSize: 13, color: Colors.white70)),
                ],
              ),
            )
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("忽略", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.push(
                context, 
                MaterialPageRoute(builder: (_) => BilibiliDownloadScreen(initialInput: content))
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blueAccent,
              foregroundColor: Colors.white,
            ),
            child: const Text("导入"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsService>(context);

    return PopScope(
      canPop: !_isSelectionMode,
      onPopInvoked: (didPop) {
        if (didPop) return;
        setState(() {
          _isSelectionMode = false;
          _selectedIds.clear();
        });
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF121212),
        appBar: AppBar(
        title: _isSelectionMode 
            ? Text("已选择 ${_selectedIds.length} 项") 
            : const Text('我的视频库'),
        centerTitle: true,
        leading: _isSelectionMode 
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() {
                    _isSelectionMode = false;
                    _selectedIds.clear();
                  });
                },
              )
            : null,
        actions: [
          if (!_isSelectionMode) ...[
            if (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
              IconButton(
                icon: Icon(settings.isFullScreen ? Icons.fullscreen_exit : Icons.fullscreen),
                tooltip: settings.isFullScreen ? "退出全屏" : "全屏",
                onPressed: () => settings.toggleFullScreen(),
              ),
             IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: "回收站",
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const RecycleBinScreen()),
                );
              },
            ),
             IconButton(
              icon: const Icon(Icons.tune),
              tooltip: "调整卡片样式",
              onPressed: () => _showCardStyleBottomSheet(context, settings),
            ),
            IconButton(
              icon: const Icon(Icons.checklist),
              tooltip: "批量管理",
              onPressed: () {
                setState(() {
                  _isSelectionMode = true;
                });
              },
            ),
          ] else ...[
            IconButton(
              icon: const Icon(Icons.select_all),
              tooltip: "全选",
              onPressed: () {
                final library = Provider.of<LibraryService>(context, listen: false);
                final contents = library.getContents(null);
                setState(() {
                  if (_selectedIds.length == contents.length) {
                    _selectedIds.clear();
                  } else {
                    _selectedIds.addAll(contents.map((e) => (e as dynamic).id as String));
                  }
                });
              },
            ),
          ],
        ],
      ),
      body: Stack(
        children: [
          Consumer<LibraryService>(
            builder: (context, library, child) {
              final contents = library.getContents(null);

              if (contents.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.folder_open, size: 80, color: Colors.white24),
                      const SizedBox(height: 16),
                      const Text("还没有内容", style: TextStyle(color: Colors.white54)),
                      const SizedBox(height: 16),
                      const VideoActionButtons(collectionId: null, isHorizontal: true),
                    ],
                  ),
                );
              }

              return GestureDetector(
                onScaleStart: (details) {
                  _baseCrossAxisCount = settings.homeGridCrossAxisCount;
                  _baseScale = 1.0;
                },
                onScaleUpdate: (details) {
                  // Pinch to Zoom Logic
                  // We use a sensitivity factor to make it feel more "natural"
                  // Scale > 1 means zooming in (fewer columns)
                  // Scale < 1 means zooming out (more columns)
                  
                  double newScale = details.scale;
                  int newCount = _baseCrossAxisCount;
                  
                  if (newScale > 1.3) {
                     newCount = (_baseCrossAxisCount - 1).clamp(1, 5);
                  } else if (newScale < 0.7) {
                     newCount = (_baseCrossAxisCount + 1).clamp(1, 5);
                  }
                  
                  // Only update if changed to avoid unnecessary rebuilds
                  if (newCount != settings.homeGridCrossAxisCount) {
                    // HapticFeedback.selectionClick(); // Optional: feedback
                    settings.updateSetting('homeGridCrossAxisCount', newCount);
                  }
                },
                child: GridView.builder(
                  padding: EdgeInsets.only(
                    left: 16,
                    right: 16,
                    top: 16,
                    bottom: 16 + _getPlaybackCardBottomPadding(),
                  ),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: settings.homeGridCrossAxisCount.clamp(1, 10),
                    childAspectRatio: settings.homeCardAspectRatio.clamp(0.1, 5.0), 
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                  ),
                  itemCount: contents.length,
                  itemBuilder: (context, index) {
                    final item = contents[index];
                    if (item is VideoCollection) {
                      return _buildCollectionCard(context, library, item, index, settings, contents);
                    } else if (item is VideoItem) {
                      return _buildVideoCard(context, item, index, settings, contents);
                    }
                    return const SizedBox.shrink();
                  },
                ),
              );
            },
          ),
          // 底部播放卡片
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Consumer<MediaPlaybackService>(
              builder: (context, playbackService, child) {
                final isVisible = playbackService.currentItem != null &&
                    (playbackService.state == PlaybackState.playing ||
                     playbackService.state == PlaybackState.paused);
                
                return MiniPlaybackCard(
                  isVisible: isVisible,
                  onTap: () {
                    // 点击卡片进入全屏播放页面
                    if (playbackService.currentItem != null) {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) {
                            if (Platform.isWindows) {
                              return VideoPlayerScreen(
                                videoItem: playbackService.currentItem,
                                existingController: playbackService.controller,
                              );
                            }
                            return PortraitVideoScreen(videoItem: playbackService.currentItem!);
                          },
                        ),
                      );
                    }
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: !_isSelectionMode 
          ? Padding(
              padding: EdgeInsets.only(bottom: _getPlaybackCardBottomPadding()),
              child: const VideoActionButtons(collectionId: null),
            )
          : null,
      bottomNavigationBar: _isSelectionMode && _selectedIds.isNotEmpty
          ? BottomAppBar(
              color: const Color(0xFF1E1E1E),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.delete, color: Colors.redAccent),
                    label: const Text("移入回收站", style: TextStyle(color: Colors.redAccent)),
                    onPressed: () {
                      final library = Provider.of<LibraryService>(context, listen: false);
                      library.moveToRecycleBin(_selectedIds.toList());
                      setState(() {
                        _selectedIds.clear();
                        _isSelectionMode = false;
                      });
                      ScaffoldMessenger.of(context).clearSnackBars();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("已移入回收站")),
                      );
                    },
                  ),
                  if (_selectedIds.length == 1)
                    TextButton.icon(
                      icon: const Icon(Icons.edit, color: Colors.blueAccent),
                      label: const Text("重命名", style: TextStyle(color: Colors.blueAccent)),
                      onPressed: () {
                        final library = Provider.of<LibraryService>(context, listen: false);
                        final id = _selectedIds.first;
                        // Find item name
                        final col = library.getCollection(id);
                        final vid = library.getVideo(id);
                        final name = col?.name ?? vid?.title ?? "";
                        
                        _showRenameDialog(context, id, name);
                      },
                    ),
                ],
              ),
            )
          : null,
      ),
    );
  }

  Widget _buildCollectionCard(
      BuildContext context, 
      LibraryService library, 
      VideoCollection collection, 
      int index,
      SettingsService settings,
      List<dynamic> contents
  ) {
    final isSelected = _selectedIds.contains(collection.id);
    
    // 1. The Visual Content of the Card
    Widget cardVisual = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Thumbnail Area (Fixed Folder Icon)
        AspectRatio(
          aspectRatio: 4 / 3,
          child: Container(
            color: Colors.black26,
            child: Center(
              child: Icon(
                Icons.folder, 
                size: 64, 
                color: Colors.blueAccent.withOpacity(0.8)
              ),
            ),
          ),
        ),
        // Info Area
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            color: isSelected ? Colors.blueAccent.withOpacity(0.1) : Colors.transparent,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    collection.name,
                    style: TextStyle(
                      fontSize: settings.homeCardTitleFontSize, 
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                    maxLines: 10, 
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  "${collection.childrenIds.length} 个项目",
                  style: const TextStyle(fontSize: 11, color: Colors.white54),
                ),
              ],
            ),
          ),
        ),
      ],
    );

    // 2. Interaction Wrapper
    Widget interactiveCard = Card(
      color: isSelected ? Colors.blueAccent.withOpacity(0.2) : const Color(0xFF2C2C2C),
      elevation: isSelected ? 4 : 2,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: isSelected ? const BorderSide(color: Colors.blueAccent, width: 2) : BorderSide.none,
      ),
      child: InkWell(
        onTap: () {
          if (_isSelectionMode) {
            setState(() {
              if (isSelected) {
                _selectedIds.remove(collection.id);
              } else {
                _selectedIds.add(collection.id);
              }
            });
          } else {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => CollectionScreen(collectionId: collection.id),
              ),
            );
          }
        },
        onLongPress: _isSelectionMode ? null : () {
          setState(() {
            _isSelectionMode = true;
            _selectedIds.add(collection.id);
          });
        },
        child: cardVisual,
      ),
    );

    // 3. Selection Mode Wrapper (Draggable + Drop Target)
    if (_isSelectionMode) {
      return LongPressDraggable<int>(
        delay: const Duration(milliseconds: 200),
        data: index,
        feedback: SizedBox(
          width: 140,
          height: 160,
          child: Opacity(
            opacity: 0.9, 
            child: Card(
              color: const Color(0xFF333333),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Center(
                child: _selectedIds.length > 1 && isSelected
                    ? Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.folder, size: 50, color: Colors.blueAccent),
                          Text(
                            "${_selectedIds.length} 个项目",
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          )
                        ],
                      )
                    : Icon(Icons.folder, size: 60, color: Colors.blueAccent),
              ),
            )
          ),
        ),
        childWhenDragging: Opacity(
          opacity: 0.3,
          child: interactiveCard,
        ),
        child: FolderDropTarget(
          folderId: collection.id,
          index: index,
          onMoveToFolder: (draggedIndex, targetId) {
            if (draggedIndex >= 0 && draggedIndex < contents.length) {
              final draggedItem = contents[draggedIndex];
              final draggedId = (draggedItem as dynamic).id;
              
              List<String> itemsToMove = [];
              if (_selectedIds.contains(draggedId)) {
                 itemsToMove = contents
                     .where((item) => _selectedIds.contains((item as dynamic).id))
                     .map((item) => (item as dynamic).id as String)
                     .toList();
              } else {
                 itemsToMove = [draggedId];
              }

              library.moveItemsToCollection(itemsToMove, targetId);
              
              ScaffoldMessenger.of(context).clearSnackBars();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("已移动到文件夹")),
              );
            }
          },
          onReorder: (oldIndex, newIndex) {
            final draggedItem = contents[oldIndex];
            final draggedId = (draggedItem as dynamic).id;

            if (_selectedIds.contains(draggedId)) {
               final itemsToMove = contents
                    .where((item) => _selectedIds.contains((item as dynamic).id))
                    .map((item) => (item as dynamic).id as String)
                    .toList();
               library.reorderMultipleItems(null, itemsToMove, oldIndex, newIndex);
            } else {
               library.reorderItems(null, oldIndex, newIndex);
            }
          },
          child: Stack(
            children: [
              interactiveCard,
              Positioned(
                top: 0,
                right: 0,
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      if (isSelected) {
                        _selectedIds.remove(collection.id);
                      } else {
                        _selectedIds.add(collection.id);
                      }
                    });
                  },
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Icon(
                      isSelected ? Icons.check_circle : Icons.circle_outlined,
                      color: isSelected ? Colors.blueAccent : Colors.white70,
                      size: 24,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 4. Default Mode (Just the card)
    return interactiveCard;
  }


  Widget _buildVideoCard(
      BuildContext context, 
      VideoItem item, 
      int index,
      SettingsService settings,
      List<dynamic> contents
  ) {
    final isSelected = _selectedIds.contains(item.id);
    
    // 1. Visual Content
    Widget cardVisual = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Thumbnail Area
        AspectRatio(
          aspectRatio: 4 / 3,
          child: Container(
            color: Colors.black26,
            child: Stack(
              fit: StackFit.expand,
              children: [
                item.thumbnailPath != null && File(item.thumbnailPath!).existsSync()
                    ? Image.file(
                        File(item.thumbnailPath!),
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, size: 50),
                      )
                    : Container(
                        color: Colors.black,
                        child: Icon(
                          item.type == MediaType.audio ? Icons.music_note : Icons.movie,
                          size: 50,
                          color: Colors.white24,
                        ),
                      ),
                // Progress Bar
                if (item.durationMs > 0 && item.lastPositionMs > 0)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      height: 4,
                      child: LinearProgressIndicator(
                        value: (item.lastPositionMs / item.durationMs).clamp(0.0, 1.0),
                        backgroundColor: Colors.white24,
                        color: Colors.redAccent,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    item.title,
                    style: TextStyle(
                      fontSize: settings.homeCardTitleFontSize, 
                      fontWeight: FontWeight.w500,
                      color: Colors.white,
                    ),
                    maxLines: 10, 
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (item.durationMs > 0) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                           "${(item.durationMs / 1000 / 60).floor()}:${((item.durationMs / 1000) % 60).floor().toString().padLeft(2, '0')}",
                           style: const TextStyle(fontSize: 10, color: Colors.white54),
                        ),
                      ),

                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );

    // 2. Interaction Wrapper
    Widget interactiveCard = Card(
      clipBehavior: Clip.antiAlias,
      color: isSelected ? Colors.blueAccent.withOpacity(0.2) : const Color(0xFF2C2C2C),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: isSelected ? const BorderSide(color: Colors.blueAccent, width: 2) : BorderSide.none,
      ),
      child: InkWell(
        onTap: () async {
          if (_isSelectionMode) {
            setState(() {
              if (isSelected) {
                _selectedIds.remove(item.id);
              } else {
                _selectedIds.add(item.id);
              }
            });
          } else {
            // 通过 MediaPlaybackService 开始播放
            final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
            final playlistManager = Provider.of<PlaylistManager>(context, listen: false);
            
            // 加载播放列表（同文件夹的所有媒体）
            playlistManager.loadFolderPlaylist(item.parentId, item.id);
            
            // 开始播放
            await playbackService.play(item);
            
            // 进入播放页面
            if (mounted) {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) {
                    if (Platform.isWindows) {
                      return VideoPlayerScreen(
                        videoItem: item,
                        existingController: playbackService.controller,
                      );
                    }
                    return PortraitVideoScreen(videoItem: item);
                  },
                ),
              );
            }
          }
        },
        onLongPress: _isSelectionMode ? null : () {
          setState(() {
            _isSelectionMode = true;
            _selectedIds.add(item.id);
          });
        },
        child: cardVisual,
      ),
    );

    // 3. Selection Mode Wrapper (Draggable + Checkmark)
    if (_isSelectionMode) {
      return LongPressDraggable<int>(
        delay: const Duration(milliseconds: 200),
        data: index,
        feedback: SizedBox(
          width: 140,
          height: 160,
          child: Opacity(
            opacity: 0.9, 
            child: Card(
              color: const Color(0xFF333333),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Center(
                child: _selectedIds.length > 1 && isSelected
                    ? Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.movie, size: 50, color: Colors.blueAccent),
                          Text(
                            "${_selectedIds.length} 个项目",
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          )
                        ],
                      )
                    : Icon(Icons.movie, size: 60, color: Colors.blueAccent),
              ),
            )
          ),
        ),
        childWhenDragging: Opacity(
          opacity: 0.3,
          child: interactiveCard,
        ),
        child: DragTarget<int>(
          onWillAccept: (data) => data != null && data != index,
          onAccept: (oldIndex) {
            final library = Provider.of<LibraryService>(context, listen: false);
            final draggedItem = contents[oldIndex];
            final draggedId = (draggedItem as dynamic).id;

            if (_selectedIds.contains(draggedId)) {
               final itemsToMove = contents
                    .where((item) => _selectedIds.contains((item as dynamic).id))
                    .map((item) => (item as dynamic).id as String)
                    .toList();
               library.reorderMultipleItems(null, itemsToMove, oldIndex, index);
            } else {
               library.reorderItems(null, oldIndex, index);
            }
          },
          builder: (context, candidateData, rejectedData) {
            Widget targetChild = interactiveCard;
            if (candidateData.isNotEmpty) {
               targetChild = Container(
                 decoration: BoxDecoration(
                   border: Border.all(color: Colors.blueAccent, width: 2),
                   borderRadius: BorderRadius.circular(16),
                 ),
                 child: interactiveCard,
               );
            }
            return Stack(
              children: [
                targetChild,
                Positioned(
                  top: 0,
                  right: 0,
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        if (isSelected) {
                          _selectedIds.remove(item.id);
                        } else {
                          _selectedIds.add(item.id);
                        }
                      });
                    },
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Icon(
                        isSelected ? Icons.check_circle : Icons.circle_outlined,
                        color: isSelected ? Colors.blueAccent : Colors.white70,
                        size: 24,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      );
    }
    
    // 4. Default Mode
    return interactiveCard;
  }









  void _showRenameDialog(BuildContext context, String id, String currentName) {
    final controller = TextEditingController(text: currentName);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("重命名"),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: "输入新名称"),
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
                    .renameItem(id, controller.text);
                Navigator.pop(context);
                
                // Exit selection mode or just clear selection?
                // User might want to rename multiple items one by one.
                // But usually rename is a single item action.
                // Let's keep selection mode but maybe update the name in the UI is automatic.
              }
            },
            child: const Text("确定"),
          ),
        ],
      ),
    );
  }

  void _showCardStyleBottomSheet(BuildContext context, SettingsService settings) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        // Initialize local state from settings
        double tempFontSize = settings.homeCardTitleFontSize;
        // Invert Aspect Ratio for "Height Scale": Value = 1 / AspectRatio
        // Higher Value = Taller Card
        double tempHeightScale = 1.0 / settings.homeCardAspectRatio;
        double tempColumnCount = settings.homeGridCrossAxisCount.toDouble();

        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              height: 450,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("卡片样式调整", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                  const SizedBox(height: 24),

                  // 1. Grid Columns Slider
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("每行卡片数量", style: TextStyle(color: Colors.white70)),
                      Text("${tempColumnCount.toInt()} 列", style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: Colors.blueAccent,
                      thumbColor: Colors.blueAccent,
                      overlayColor: Colors.blueAccent.withOpacity(0.2),
                      trackHeight: 4,
                    ),
                    child: Slider(
                      value: tempColumnCount,
                      min: 1,
                      max: 8,
                      divisions: 7,
                      label: tempColumnCount.toInt().toString(),
                      onChanged: (val) {
                        setSheetState(() {
                          tempColumnCount = val;
                        });
                      },
                      onChangeEnd: (val) {
                         if (val.round() != settings.homeGridCrossAxisCount) {
                           settings.updateSetting('homeGridCrossAxisCount', val.round());
                         }
                      },
                    ),
                  ),

                  const SizedBox(height: 16),
                  
                  // 2. Font Size Slider
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("标题字号", style: TextStyle(color: Colors.white70)),
                      Text("${tempFontSize.toInt()}", style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: Colors.blueAccent,
                      thumbColor: Colors.blueAccent,
                      overlayColor: Colors.blueAccent.withOpacity(0.2),
                      trackHeight: 4,
                    ),
                    child: Slider(
                      value: tempFontSize,
                      min: 8,
                      max: 34,
                      divisions: 26,
                      label: tempFontSize.toInt().toString(),
                      onChanged: (val) {
                        setSheetState(() {
                          tempFontSize = val;
                        });
                        settings.updateSetting('homeCardTitleFontSize', val);
                      },
                    ),
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // 3. Card Height Slider (Inverted Logic)
                  // Min: 0.8 (Short, Ratio ~1.25)
                  // Max: 2.0 (Tall, Ratio ~0.5)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("卡片高度", style: TextStyle(color: Colors.white70)),
                      Text(tempHeightScale.toStringAsFixed(2), style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: Colors.blueAccent,
                      thumbColor: Colors.blueAccent,
                      overlayColor: Colors.blueAccent.withOpacity(0.2),
                      trackHeight: 4,
                    ),
                    child: Slider(
                      value: tempHeightScale.clamp(0.8, 2.0),
                      min: 0.8,
                      max: 2.0,
                      divisions: 12,
                      label: tempHeightScale.toStringAsFixed(2),
                      onChanged: (val) {
                         setSheetState(() {
                           tempHeightScale = val;
                         });
                         // Convert "Height Scale" back to Aspect Ratio
                         // AspectRatio = 1 / HeightScale
                         settings.updateSetting('homeCardAspectRatio', 1.0 / val);
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
