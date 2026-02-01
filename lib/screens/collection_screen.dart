import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../models/video_collection.dart';
import '../models/video_item.dart';
import '../widgets/folder_drop_target.dart';
import '../widgets/cached_thumbnail_widget.dart';
import '../services/thumbnail_preload_manager.dart';
import 'portrait_video_screen.dart';
import '../widgets/mini_playback_card.dart';
import '../widgets/video_action_buttons.dart';
import '../services/media_playback_service.dart';
import '../services/playlist_manager.dart';
import 'video_player_screen.dart';
import '../utils/app_toast.dart';

class CollectionScreen extends StatefulWidget {
  final String collectionId;

  const CollectionScreen({super.key, required this.collectionId});

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen> {
  bool _isSelectionMode = false;
  final Set<String> _selectedIds = {};

  // Pinch to zoom state
  int _baseCrossAxisCount = 2;

  // Thumbnail preloading
  late ThumbnailPreloadManager _preloadManager;
  final ScrollController _scrollController = ScrollController();
  List<VideoItem> _videoItems = [];
  Timer? _scrollPrecacheTimer;
  bool _didInitialDecodePrecache = false;

  /// 计算播放卡片的底部填充，确保内容不被遮挡
  double _getPlaybackCardBottomPadding() {
    final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
    final isVisible = playbackService.currentItem != null &&
        (playbackService.state == PlaybackState.playing ||
         playbackService.state == PlaybackState.paused);
    
    if (!isVisible) return 0.0;
    
    // 根据屏幕宽度计算卡片高度（与 PlaybackCardLayout 保持一致）
    final screenWidth = MediaQuery.of(context).size.width;
    final isPhone = screenWidth < 600;
    final isTablet = screenWidth >= 600 && screenWidth < 1200;
    
    if (isPhone) return 117.0; // 与新的卡片高度保持一致
    if (isTablet) return 127.0; // 与新的卡片高度保持一致
    return 107.0; // 与新的卡片高度保持一致
  }

  @override
  void initState() {
    super.initState();
    _preloadManager = ThumbnailPreloadManager();
    _scrollController.addListener(_onScroll);
    _startInitialPreload();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startInitialDecodePrecache();
    });
  }

  @override
  void dispose() {
    _preloadManager.cancelAll();
    _scrollPrecacheTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _startInitialPreload() {
    final library = Provider.of<LibraryService>(context, listen: false);
    final contents = library.getContents(widget.collectionId);
    _videoItems = contents.whereType<VideoItem>().toList();
    
    if (_videoItems.isNotEmpty) {
      // 预加载前20个视频的缩略图
      final endIndex = (_videoItems.length < 20) ? _videoItems.length : 20;
      _preloadManager.preloadRange(_videoItems, 0, endIndex);
    }
  }

  void _startInitialDecodePrecache() {
    if (_didInitialDecodePrecache || !mounted) return;
    _didInitialDecodePrecache = true;

    final settings = Provider.of<SettingsService>(context, listen: false);
    final crossAxisCount = settings.videoCardCrossAxisCount;
    if (crossAxisCount <= 0 || _videoItems.isEmpty) return;

    final mediaQuery = MediaQuery.of(context);
    final itemWidth = (mediaQuery.size.width - 32 - (16 * (crossAxisCount - 1))) /
        crossAxisCount;
    final itemHeight = itemWidth / settings.videoCardAspectRatio;
    final rowHeight = itemHeight + 16;
    final visibleRows = (mediaQuery.size.height / rowHeight).ceil().clamp(1, 8);
    final precacheCount = (crossAxisCount * (visibleRows + 1))
        .clamp(0, _videoItems.length);

    _precacheVideoRange(0, precacheCount);
  }

  Future<void> _precacheVideoRange(int startIndex, int endIndex) async {
    if (!mounted) return;
    if (_videoItems.isEmpty) return;

    final settings = Provider.of<SettingsService>(context, listen: false);
    final crossAxisCount = settings.videoCardCrossAxisCount;
    if (crossAxisCount <= 0) return;

    startIndex = startIndex.clamp(0, _videoItems.length);
    endIndex = endIndex.clamp(0, _videoItems.length);
    if (startIndex >= endIndex) return;

    final mediaQuery = MediaQuery.of(context);
    final itemWidth = (mediaQuery.size.width - 32 - (16 * (crossAxisCount - 1))) /
        crossAxisCount;
    final thumbWidth = itemWidth;
    final thumbHeight = thumbWidth * 3 / 4;
    final dpr = mediaQuery.devicePixelRatio;

    final cacheWidth = (thumbWidth * dpr).round().clamp(1, 4096);
    final cacheHeight = (thumbHeight * dpr).round().clamp(1, 4096);

    const batchSize = 4;
    for (int i = startIndex; i < endIndex; i += batchSize) {
      if (!mounted) return;

      final batchEnd = (i + batchSize).clamp(startIndex, endIndex);
      final batch = _videoItems.sublist(i, batchEnd);

      await Future.wait(batch.map((item) async {
        final path = item.thumbnailPath;
        if (path == null || path.isEmpty) return;

        final provider = ResizeImage(
          FileImage(File(path)),
          width: cacheWidth,
          height: cacheHeight,
          allowUpscaling: false,
        );

        try {
          await precacheImage(provider, context);
        } catch (_) {}
      }));
    }
  }

  void _onScroll() {
    if (_videoItems.isEmpty) return;
    
    // 计算当前可见的视频索引范围
    final settings = Provider.of<SettingsService>(context, listen: false);
    final crossAxisCount = settings.videoCardCrossAxisCount;
    
    // 估算当前滚动位置对应的索引
    final scrollOffset = _scrollController.offset;
    final itemHeight = 200.0; // 估算的卡片高度
    final rowHeight = itemHeight + 16; // 包含间距
    
    final currentRow = (scrollOffset / rowHeight).floor();
    final currentIndex = currentRow * crossAxisCount;
    
    // 预加载当前位置前后的缩略图
    final bufferSize = crossAxisCount * 3; // 前后各3行
    final startIndex = (currentIndex - bufferSize).clamp(0, _videoItems.length);
    final endIndex = (currentIndex + bufferSize * 2).clamp(0, _videoItems.length);
    
    // 根据滚动方向更新优先级
    final direction = _scrollController.position.userScrollDirection;
    
    _preloadManager.updatePriorities(currentIndex, direction);
    _preloadManager.preloadRange(_videoItems, startIndex, endIndex);

    _scrollPrecacheTimer?.cancel();
    _scrollPrecacheTimer = Timer(const Duration(milliseconds: 120), () {
      _precacheVideoRange(startIndex, endIndex);
    });
  }

  Widget _buildMoveOutTarget(BuildContext context, LibraryService library, VideoCollection collection) {
    return DragTarget<int>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) {
        final draggedIndex = details.data;
         final contents = library.getContents(widget.collectionId);
         if (draggedIndex >= 0 && draggedIndex < contents.length) {
            final draggedItem = contents[draggedIndex];
            final draggedId = (draggedItem as dynamic).id;
            
            List<String> itemsToMove = [];
            if (_selectedIds.contains(draggedId)) {
               // Move all selected items, preserving their original order in current list
               itemsToMove = contents
                   .where((item) => _selectedIds.contains((item as dynamic).id))
                   .map((item) => (item as dynamic).id as String)
                   .toList();
            } else {
               itemsToMove = [draggedId];
            }
            
            library.moveItemsToCollection(itemsToMove, collection.parentId);
            AppToast.show("已移出 ${itemsToMove.length} 个项目", type: AppToastType.success);
         }
      },
      builder: (context, candidateData, rejectedData) {
        final isHovering = candidateData.isNotEmpty;
        return Container(
          width: double.infinity,
          height: 60,
          margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          decoration: BoxDecoration(
            color: isHovering ? Colors.blueAccent.withValues(alpha: 0.3) : const Color(0xFF2C2C2C),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isHovering ? Colors.blueAccent : Colors.white24,
              width: 2,
              style: isHovering ? BorderStyle.solid : BorderStyle.none, // Solid when hovering
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.reply_all, 
                color: isHovering ? Colors.blueAccent : Colors.white70
              ),
              const SizedBox(width: 8),
              Text(
                "移动到上一级",
                style: TextStyle(
                  color: isHovering ? Colors.blueAccent : Colors.white70,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsService>(context);

    return Consumer<LibraryService>(
      builder: (context, library, child) {
        final collection = library.getCollection(widget.collectionId) ?? 
            VideoCollection(id: '', name: '未知合集', createTime: 0);
        
        final contents = library.getContents(widget.collectionId);

        return PopScope(
          canPop: !_isSelectionMode,
          onPopInvokedWithResult: (didPop, _) {
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
              : Column(
                  children: [
                    Text(collection.name),
                    ValueListenableBuilder<bool>(
                      valueListenable: library.isImporting,
                      builder: (context, isImporting, _) {
                        if (!isImporting) return const SizedBox.shrink();
                        return ValueListenableBuilder<String>(
                          valueListenable: library.importStatus,
                          builder: (context, status, _) {
                             return Text(
                               status, 
                               style: const TextStyle(fontSize: 10, color: Colors.white70)
                             );
                          },
                        );
                      },
                    ),
                  ],
                ),
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
                : const BackButton(),
            actions: [
              if (!_isSelectionMode) ...[
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
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(4),
              child: ValueListenableBuilder<double>(
                valueListenable: library.importProgress,
                builder: (context, progress, _) {
                  if (progress <= 0 || progress >= 1) return const SizedBox.shrink();
                  return LinearProgressIndicator(
                    value: progress, 
                    backgroundColor: Colors.transparent,
                    minHeight: 4,
                  );
                },
              ),
            ),
          ),
          body: Stack(
            children: [
              contents.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.video_collection_outlined, size: 80, color: Colors.white24),
                          const SizedBox(height: 16),
                          const Text("合集是空的", style: TextStyle(color: Colors.white54)),
                          const SizedBox(height: 16),
                          VideoActionButtons(collectionId: widget.collectionId, isHorizontal: true),
                        ],
                      ),
                    )
                  : Column(
                      children: [
                        if (_isSelectionMode) _buildMoveOutTarget(context, library, collection),
                        Expanded(
                          child: GestureDetector(
                            onScaleStart: (details) {
                              _baseCrossAxisCount = settings.videoCardCrossAxisCount;
                            },
                            onScaleUpdate: (details) {
                              double newScale = details.scale;
                              int newCount = _baseCrossAxisCount;
                              
                              if (newScale > 1.3) {
                                 newCount = (_baseCrossAxisCount - 1).clamp(1, 5);
                              } else if (newScale < 0.7) {
                                 newCount = (_baseCrossAxisCount + 1).clamp(1, 5);
                              }
                              
                              if (newCount != settings.videoCardCrossAxisCount) {
                                settings.updateSetting('videoCardCrossAxisCount', newCount);
                              }
                            },
                            child: GridView.builder(
                              controller: _scrollController,
                              padding: EdgeInsets.only(
                                left: 16,
                                right: 16,
                                top: 16,
                                bottom: 16 + _getPlaybackCardBottomPadding(),
                              ),
                              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: settings.videoCardCrossAxisCount,
                                childAspectRatio: settings.videoCardAspectRatio, 
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
                          ),
                        ),
                      ],
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
                        final currentItem = playbackService.currentItem;
                        if (currentItem == null) return;
                        if (!File(currentItem.path).existsSync()) {
                          AppToast.show("媒体文件不存在，可能已被移动或删除", type: AppToastType.error);
                          return;
                        }
                        if (playbackService.controller == null) {
                          AppToast.show("播放器尚未准备好，请稍后重试", type: AppToastType.error);
                          return;
                        }
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (context) {
                              if (Platform.isWindows) {
                                return VideoPlayerScreen(
                                  videoItem: currentItem,
                                  existingController: playbackService.controller,
                                );
                              }
                              return PortraitVideoScreen(videoItem: currentItem);
                            },
                          ),
                        );
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
                  child: VideoActionButtons(collectionId: widget.collectionId),
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
                          library.moveToRecycleBin(_selectedIds.toList());
                          setState(() {
                            _selectedIds.clear();
                            _isSelectionMode = false;
                          });
                          AppToast.show("已移入回收站", type: AppToastType.success);
                        },
                      ),
                      if (_selectedIds.length == 1)
                        TextButton.icon(
                          icon: const Icon(Icons.edit, color: Colors.blueAccent),
                          label: const Text("重命名", style: TextStyle(color: Colors.blueAccent)),
                          onPressed: () {
                            final id = _selectedIds.first;
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
      },
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
    final thumbnailPath = collection.thumbnailPath;
    final hasThumbnail = thumbnailPath != null && thumbnailPath.isNotEmpty;
    
    // 1. Visual Content
    Widget cardVisual = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Thumbnail Area (Fixed Folder Icon)
        AspectRatio(
          aspectRatio: 4 / 3,
          child: Container(
            color: Colors.black26,
            child: hasThumbnail
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      CachedThumbnailWidget(
                        videoId: collection.id,
                        thumbnailPath: thumbnailPath,
                        cacheWidth: 512,
                        cacheHeight: 384,
                        placeholder: const SizedBox.expand(
                          child: ColoredBox(color: Colors.black26),
                        ),
                        errorWidget: Center(
                          child: Icon(
                            Icons.folder,
                            size: 64,
                            color: Colors.blueAccent.withValues(alpha: 0.8),
                          ),
                        ),
                      ),
                      Positioned(
                        right: 6,
                        bottom: 6,
                        child: Icon(
                          Icons.folder,
                          size: 28,
                          color: Colors.blueAccent.withValues(alpha: 0.9),
                        ),
                      ),
                    ],
                  )
                : Center(
                    child: Icon(
                      Icons.folder,
                      size: 64,
                      color: Colors.blueAccent.withValues(alpha: 0.8),
                    ),
                  ),
          ),
        ),
        // Info Area
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            color: isSelected ? Colors.blueAccent.withValues(alpha: 0.1) : Colors.transparent,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    collection.name,
                    style: TextStyle(
                      fontSize: settings.videoCardTitleFontSize, 
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
      color: isSelected ? Colors.blueAccent.withValues(alpha: 0.2) : const Color(0xFF2C2C2C),
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

    // 3. Selection Mode Wrapper
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
              AppToast.show("已移动到文件夹", type: AppToastType.success);
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
                library.reorderMultipleItems(widget.collectionId, itemsToMove, oldIndex, newIndex);
             } else {
                library.reorderItems(widget.collectionId, oldIndex, newIndex);
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

    // 4. Default Mode
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
                LayoutBuilder(
                  builder: (context, constraints) {
                    final dpr = MediaQuery.of(context).devicePixelRatio;
                    final cacheWidth =
                        (constraints.maxWidth * dpr).round().clamp(1, 4096);
                    final cacheHeight =
                        (constraints.maxHeight * dpr).round().clamp(1, 4096);

                    return CachedThumbnailWidget(
                      videoId: item.id,
                      thumbnailPath: item.thumbnailPath,
                      fit: BoxFit.cover,
                      cacheWidth: cacheWidth,
                      cacheHeight: cacheHeight,
                      placeholder: Container(
                        color: Colors.black,
                        child: Icon(
                          item.type == MediaType.audio
                              ? Icons.music_note
                              : Icons.movie,
                          size: 50,
                          color: Colors.white24,
                        ),
                      ),
                      errorWidget: const Icon(Icons.broken_image, size: 50),
                    );
                  },
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Selector<MediaPlaybackService, ({bool isCurrent, int positionMs, int durationMs})>(
                    selector: (context, service) {
                      final isCurrent = service.currentItem?.id == item.id;
                      if (!isCurrent) {
                        return (isCurrent: false, positionMs: 0, durationMs: 0);
                      }
                      return (
                        isCurrent: true,
                        positionMs: service.position.inMilliseconds,
                        durationMs: service.duration.inMilliseconds,
                      );
                    },
                    builder: (context, data, child) {
                      final bool isCurrent = data.isCurrent;
                      final int durationMs = isCurrent ? data.durationMs : item.durationMs;
                      final int positionMs = isCurrent ? data.positionMs : item.lastPositionMs;

                      final shouldShow = durationMs > 0 && (isCurrent || positionMs > 0);
                      if (!shouldShow) return const SizedBox.shrink();

                      final value = (positionMs / durationMs).clamp(0.0, 1.0);
                      return SizedBox(
                        height: 4,
                        child: LinearProgressIndicator(
                          value: value,
                          backgroundColor: Colors.white24,
                          color: Colors.redAccent,
                        ),
                      );
                    },
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
                      fontSize: settings.videoCardTitleFontSize, 
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
      color: isSelected ? Colors.blueAccent.withValues(alpha: 0.2) : const Color(0xFF2C2C2C),
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
            
            final file = File(item.path);
            if (!await file.exists()) {
              if (!context.mounted) return;
              AppToast.show("媒体文件不存在，可能已被移动或删除", type: AppToastType.error);
              return;
            }

            // 加载播放列表（同文件夹的所有媒体）
            playlistManager.loadFolderPlaylist(widget.collectionId, item.id);
            
            // 开始播放
            await playbackService.play(item);

            if (!context.mounted) return;
            if (playbackService.state == PlaybackState.error || playbackService.controller == null) {
              AppToast.show("播放失败：无法加载该媒体", type: AppToastType.error);
              return;
            }
            
            // 进入播放页面
            if (!context.mounted) return;
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

    // 3. Selection Mode Wrapper
    if (_isSelectionMode) {
      return LongPressDraggable<int>(
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
                child: Icon(Icons.movie, size: 60, color: Colors.blueAccent),
              ),
            )
          ),
        ),
        childWhenDragging: Opacity(
          opacity: 0.3,
          child: interactiveCard,
        ),
        child: DragTarget<int>(
          onWillAcceptWithDetails: (details) => details.data != index,
          onAcceptWithDetails: (details) {
            final oldIndex = details.data;
            final library = Provider.of<LibraryService>(context, listen: false);
            final draggedItem = contents[oldIndex];
            final draggedId = (draggedItem as dynamic).id;

            if (_selectedIds.contains(draggedId)) {
               final itemsToMove = contents
                    .where((item) => _selectedIds.contains((item as dynamic).id))
                    .map((item) => (item as dynamic).id as String)
                    .toList();
               library.reorderMultipleItems(widget.collectionId, itemsToMove, oldIndex, index);
            } else {
               library.reorderItems(widget.collectionId, oldIndex, index);
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
        double tempFontSize = settings.videoCardTitleFontSize;
        double tempHeightScale = 1.0 / settings.videoCardAspectRatio;
        double tempColumnCount = settings.videoCardCrossAxisCount.toDouble();

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
                      overlayColor: Colors.blueAccent.withValues(alpha: 0.2),
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
                         if (val.round() != settings.videoCardCrossAxisCount) {
                           settings.updateSetting('videoCardCrossAxisCount', val.round());
                         }
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
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
                      overlayColor: Colors.blueAccent.withValues(alpha: 0.2),
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
                        settings.updateSetting('videoCardTitleFontSize', val);
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
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
                      overlayColor: Colors.blueAccent.withValues(alpha: 0.2),
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
                         settings.updateSetting('videoCardAspectRatio', 1.0 / val);
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
