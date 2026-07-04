import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../models/video_collection.dart';
import '../models/video_item.dart';
import '../widgets/folder_drop_target.dart';
import '../widgets/cached_thumbnail_widget.dart';
import '../services/bilibili/bilibili_download_service.dart';
import '../services/thumbnail_preload_manager.dart';
import 'portrait_video_screen.dart';
import '../widgets/mini_playback_card.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'recycle_bin_screen.dart';
import '../widgets/video_action_buttons.dart';
import '../widgets/responsive_icon_button.dart';
import '../services/media_playback_service.dart';
import '../services/playback_navigation_service.dart';
import '../services/playlist_manager.dart';
import 'video_player_screen.dart';
import '../utils/app_toast.dart';
import '../utils/desktop_media_management_shortcuts.dart';

class CollectionScreen extends StatefulWidget {
  final String collectionId;

  const CollectionScreen({super.key, required this.collectionId});

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen> {
  bool _isSelectionMode = false;
  bool _showExportSettingsButton = false;
  final Set<String> _selectedIds = {};
  final FocusNode _shortcutFocusNode = FocusNode(
    debugLabel: 'CollectionShortcutFocus',
  );

  // Pinch to zoom state
  int _baseCrossAxisCount = 2;

  // Selection Logic State
  // 1. Circle Drag Selection (All Platforms)
  int? _dragSelectionStartIndex;
  Set<String> _dragSelectionSnapshot = {};

  // 2. Box Selection (Windows)
  bool _isBoxSelecting = false;
  Offset? _boxStartPos;
  Offset? _boxCurrentPos;

  // File Drag & Drop (Windows)
  bool _isDraggingFiles = false;

  // Track items that have been "touched" by the current box selection session
  final Set<String> _capturedIds = {};

  // Thumbnail preloading
  late ThumbnailPreloadManager _preloadManager;
  final ScrollController _scrollController = ScrollController();
  List<VideoItem> _videoItems = [];
  Timer? _scrollPrecacheTimer;
  bool _didInitialDecodePrecache = false;
  static const double _cardTitleScaleReferenceWidth = 170.0;
  static const double _cardTitleScaleMin = 0.045;
  static const double _cardTitleScaleMax = 0.18;

  double _normalizeCardTitleScale(double value) {
    if (value <= 1.0) {
      return value.clamp(_cardTitleScaleMin, _cardTitleScaleMax);
    }
    return (value / _cardTitleScaleReferenceWidth).clamp(
      _cardTitleScaleMin,
      _cardTitleScaleMax,
    );
  }

  double _resolveCardTitleFontSize(double cardWidth, double settingValue) {
    final scale = _normalizeCardTitleScale(settingValue);
    return (cardWidth * scale).clamp(2.0, 100.0);
  }

  double _resolveCardMetaFontSize(double titleFontSize) {
    return (titleFontSize * 0.82).clamp(2.0, 100.0);
  }

  Duration get _mediaCardLongPressDelay {
    if (Platform.isWindows || Platform.isMacOS) {
      return const Duration(milliseconds: 320);
    }
    return const Duration(milliseconds: 160);
  }

  void _resetSelectionInteractionState() {
    _isBoxSelecting = false;
    _boxStartPos = null;
    _boxCurrentPos = null;
    _capturedIds.clear();
    _dragSelectionStartIndex = null;
    _dragSelectionSnapshot.clear();
  }

  Future<void> _syncSelectionAfterMove(
    LibraryService library, {
    required String? currentParentId,
    required Iterable<String> attemptedItemIds,
  }) async {
    if (!mounted) return;

    final remainingIds = library
        .getContents(currentParentId)
        .map((item) => (item as dynamic).id as String)
        .toSet();
    final movedIds = attemptedItemIds
        .where((id) => !remainingIds.contains(id))
        .toSet();

    if (movedIds.isEmpty) return;

    setState(() {
      _selectedIds.removeAll(movedIds);
      if (_selectedIds.isEmpty) {
        _isSelectionMode = false;
      }
      _resetSelectionInteractionState();
    });
  }

  Future<void> _moveItemsToParentCollection(
    LibraryService library,
    VideoCollection collection, {
    int? draggedIndex,
  }) async {
    final contents = library.getContents(widget.collectionId);
    List<String> itemsToMove = [];

    if (draggedIndex != null) {
      if (draggedIndex < 0 || draggedIndex >= contents.length) return;

      final draggedItem = contents[draggedIndex];
      final draggedId = (draggedItem as dynamic).id;
      if (_selectedIds.contains(draggedId)) {
        itemsToMove = contents
            .where((item) => _selectedIds.contains((item as dynamic).id))
            .map((item) => (item as dynamic).id as String)
            .toList();
      } else {
        itemsToMove = [draggedId];
      }
    } else {
      itemsToMove = contents
          .where((item) => _selectedIds.contains((item as dynamic).id))
          .map((item) => (item as dynamic).id as String)
          .toList();
    }

    if (itemsToMove.isEmpty) return;

    await library.moveItemsToCollection(itemsToMove, collection.parentId);
    await _syncSelectionAfterMove(
      library,
      currentParentId: widget.collectionId,
      attemptedItemIds: itemsToMove,
    );
    AppToast.show("已移出 ${itemsToMove.length} 个项目", type: AppToastType.success);
  }

  double _estimateGridCardWidth(BuildContext context, int columnCount) {
    final safeColumnCount = columnCount.clamp(1, 15);
    final screenWidth = MediaQuery.of(context).size.width;
    const double horizontalPadding = 32.0;
    const double spacing = 16.0;
    final totalSpacing = (safeColumnCount - 1) * spacing + horizontalPadding;
    return ((screenWidth - totalSpacing) / safeColumnCount).clamp(
      36.0,
      screenWidth,
    );
  }

  /// Helper: Get total item count safely
  int _getItemCount() {
    final library = Provider.of<LibraryService>(context, listen: false);
    return library.getContents(widget.collectionId).length;
  }

  /// Helper: Get content ID at index
  String? _getItemId(int index) {
    final library = Provider.of<LibraryService>(context, listen: false);
    final contents = library.getContents(widget.collectionId);
    if (index < 0 || index >= contents.length) return null;
    return (contents[index] as dynamic).id;
  }

  /// Helper: Check if a point (relative to scrollable content) is inside an item
  /// Returns the index of the item, or null if in spacing/padding
  int? _getIndexAt(Offset contentOffset) {
    final settings = Provider.of<SettingsService>(context, listen: false);
    final crossAxisCount = settings.videoCardCrossAxisCount;
    final count = _getItemCount();
    if (crossAxisCount <= 0 || count == 0) return null;

    final mediaQuery = MediaQuery.of(context);
    final screenWidth = mediaQuery.size.width;

    // Grid Parameters (Must match GridView layout)
    const double spacing = 16.0;
    const double hPadding = 16.0;
    const double topPadding = 16.0;

    final double totalSpacing = (crossAxisCount - 1) * spacing + (hPadding * 2);
    final double itemWidth = (screenWidth - totalSpacing) / crossAxisCount;
    final double itemHeight = itemWidth / settings.videoCardAspectRatio;

    // Check horizontal bounds
    if (contentOffset.dx < hPadding ||
        contentOffset.dx > screenWidth - hPadding) {
      return null;
    }

    // Check top bound
    if (contentOffset.dy < topPadding) return null;

    // Calculate Col
    double relativeX = contentOffset.dx - hPadding;
    int col = (relativeX / (itemWidth + spacing)).floor();

    // Check if in horizontal spacing
    double remainderX = relativeX % (itemWidth + spacing);
    if (remainderX > itemWidth) return null;
    if (col >= crossAxisCount) return null;

    // Calculate Row
    double relativeY = contentOffset.dy - topPadding;
    int row = (relativeY / (itemHeight + spacing)).floor();

    // Check if in vertical spacing
    double remainderY = relativeY % (itemHeight + spacing);
    if (remainderY > itemHeight) return null;

    int index = row * crossAxisCount + col;
    if (index >= 0 && index < count) {
      return index;
    }
    return null;
  }

  /// Helper: Get the Rect of an item at [index] relative to the scrollable content area
  Rect? _getItemRect(int index) {
    final settings = Provider.of<SettingsService>(context, listen: false);
    final crossAxisCount = settings.videoCardCrossAxisCount;
    final count = _getItemCount();
    if (crossAxisCount <= 0 || index < 0 || index >= count) return null;

    final mediaQuery = MediaQuery.of(context);
    final screenWidth = mediaQuery.size.width;

    // Grid Parameters
    const double spacing = 16.0;
    const double hPadding = 16.0;
    const double topPadding = 16.0;

    final double totalSpacing = (crossAxisCount - 1) * spacing + (hPadding * 2);
    final double itemWidth = (screenWidth - totalSpacing) / crossAxisCount;
    final double itemHeight = itemWidth / settings.videoCardAspectRatio;

    final int row = index ~/ crossAxisCount;
    final int col = index % crossAxisCount;

    final double x = hPadding + col * (itemWidth + spacing);
    final double y = topPadding + row * (itemHeight + spacing);

    return Rect.fromLTWH(x, y, itemWidth, itemHeight);
  }

  /// Handle Circle Drag Selection Update
  void _updateDragSelection(Offset globalPos) {
    if (_dragSelectionStartIndex == null) return;

    // Convert global to content offset
    final RenderBox? renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final Offset localPos = renderBox.globalToLocal(globalPos);

    // Adjust for AppBar: CollectionScreen is the whole page.
    final double appBarHeight =
        kToolbarHeight + MediaQuery.of(context).padding.top;

    // Offset relative to the Viewport
    final double viewportY = localPos.dy - appBarHeight;

    // Offset relative to Content
    final double contentX = localPos.dx;
    final double contentY = viewportY + _scrollController.offset;

    // Calculate Box for Visualization (Circle Drag)
    // We need start pos relative to viewport?
    // _dragSelectionStartIndex gives us the index. We can get the rect.
    final startRect = _getItemRect(_dragSelectionStartIndex!);
    if (startRect != null) {
      // Start point is center of start item? Or corner?
      // User said "Start from circle". Circle is top right.
      // Let's use the center of the item as anchor for simplicity, or the exact touch point if we had it.
      // We don't have exact touch start point here easily without passing it.
      // But we can estimate from rect.
      // Let's assume start point is the center of the start item.
      final startPoint = startRect.center;

      // Current point is contentOffset.
      // But for drawing _BoxSelectionPainter, we need coordinates relative to the Body (viewport), not content (scroll).
      // Painter is in Stack -> Positioned.fill -> IgnorePointer -> CustomPaint.
      // The Stack is inside Body.
      // So Painter coordinates = (0,0) at top-left of Body.
      // contentOffset includes scroll.
      // So viewportPoint = contentPoint - scrollOffset.

      final viewportStart = startPoint - Offset(0, _scrollController.offset);
      final viewportCurrent =
          Offset(contentX, contentY) - Offset(0, _scrollController.offset);

      _boxStartPos = viewportStart;
      _boxCurrentPos = viewportCurrent;
      _isBoxSelecting = true; // Enable painting
    }

    if (_boxStartPos != null && _boxCurrentPos != null) {
      final rect = Rect.fromPoints(_boxStartPos!, _boxCurrentPos!);
      final contentRect = rect.shift(Offset(0, _scrollController.offset));

      final Set<String> currentInBox = {};
      final count = _getItemCount();

      for (int i = 0; i < count; i++) {
        final itemRect = _getItemRect(i);
        if (itemRect != null && itemRect.overlaps(contentRect)) {
          final id = _getItemId(i);
          if (id != null) currentInBox.add(id);
        }
      }

      // "Higher Level" Logic:
      // 1. Snapshot: Selection state before drag.
      // 2. Captured: Items that have entered the box at any point.
      // 3. Current: Items currently in box.
      // Logic: For any item in Captured, its status is determined by Current.
      //        For items NOT in Captured, they keep Snapshot status.

      _capturedIds.addAll(currentInBox);

      final Set<String> newSelection = {};

      // Add items from Snapshot that were NEVER captured
      for (final id in _dragSelectionSnapshot) {
        if (!_capturedIds.contains(id)) {
          newSelection.add(id);
        }
      }

      // Add items currently in Box
      newSelection.addAll(currentInBox);

      if (newSelection.length != _selectedIds.length ||
          !_selectedIds.containsAll(newSelection)) {
        setState(() {
          _selectedIds.clear();
          _selectedIds.addAll(newSelection);
        });
        if (Platform.isAndroid || Platform.isIOS) {
          HapticFeedback.selectionClick();
        }
      }
    }
  }

  /// 计算播放卡片的底部填充，确保内容不被遮挡
  double _getPlaybackCardBottomPadding() {
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    final isVisible =
        playbackService.currentItem != null &&
        (playbackService.state == PlaybackState.playing ||
            playbackService.state == PlaybackState.paused);

    if (!isVisible) return 0.0;

    // 根据屏幕宽度计算卡片高度（与 PlaybackCardLayout 保持一致）
    final screenWidth = MediaQuery.of(context).size.width;
    final isPhone = screenWidth < 600;
    final isTablet = screenWidth >= 600 && screenWidth < 1200;

    if (isPhone) return 117.0 + _getPlaybackCardVerticalOffset();
    if (isTablet) return 127.0 + _getPlaybackCardVerticalOffset();
    return 107.0 + _getPlaybackCardVerticalOffset();
  }

  double _getPlaybackCardVerticalOffset() {
    return 6.0;
  }

  Route<void> _buildVideoPlayerRoute(
    VideoItem item,
    VideoPlayerController? existingController,
  ) {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) {
          return VideoPlayerScreen(
            videoItem: item,
            existingController: existingController,
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return child;
        },
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        opaque: true,
      );
    }
    return MaterialPageRoute(
      settings: PlaybackNavigationService.portraitRouteSettings(item),
      builder: (context) => PortraitVideoScreen(videoItem: item),
    );
  }

  void _scheduleFolderPlaylistWarmup(VideoItem item) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final playlistManager = Provider.of<PlaylistManager>(
        context,
        listen: false,
      );
      if (playlistManager.matchesFolderPlaylist(widget.collectionId, item.id)) {
        return;
      }
      playlistManager.loadFolderPlaylist(widget.collectionId, item.id);
    });
  }

  void _openPlaybackScreen(
    VideoItem item, {
    VideoPlayerController? existingController,
    bool useRootNavigator = false,
  }) {
    final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
    navigator.push(_buildVideoPlayerRoute(item, existingController));
    _scheduleFolderPlaylistWarmup(item);
  }

  @override
  void initState() {
    super.initState();
    _preloadManager = ThumbnailPreloadManager();
    _scrollController.addListener(_onScroll);
    _startInitialPreload();
    _loadExportButtonPreference();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startInitialDecodePrecache();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_supportsDesktopManagementShortcuts && mounted) {
        _shortcutFocusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _preloadManager.cancelAll();
    _scrollPrecacheTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _shortcutFocusNode.dispose();
    super.dispose();
  }

  bool get _supportsDesktopManagementShortcuts {
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  }

  bool _isTextInputFocused() {
    final BuildContext? focusContext =
        FocusManager.instance.primaryFocus?.context;
    if (focusContext == null) return false;
    return focusContext.widget is EditableText ||
        focusContext.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  String _managementTooltip(
    String label,
    DesktopMediaManagementShortcutAction action,
  ) {
    if (!_supportsDesktopManagementShortcuts) return label;
    return DesktopMediaManagementShortcuts.buildTooltip(label, action);
  }

  void _exitSelectionMode() {
    setState(() {
      _isSelectionMode = false;
      _selectedIds.clear();
      _isBoxSelecting = false;
      _boxStartPos = null;
      _boxCurrentPos = null;
      _capturedIds.clear();
    });
  }

  void _toggleSelectAllInCollection() {
    final library = Provider.of<LibraryService>(context, listen: false);
    final contents = library.getContents(widget.collectionId);
    setState(() {
      if (_selectedIds.length == contents.length) {
        _selectedIds.clear();
      } else {
        _selectedIds.addAll(contents.map((e) => (e as dynamic).id as String));
      }
    });
  }

  KeyEventResult _handleManagementShortcut(
    DesktopMediaManagementShortcutAction action,
  ) {
    final settings = Provider.of<SettingsService>(context, listen: false);
    switch (action) {
      case DesktopMediaManagementShortcutAction.backOrExitSelection:
        if (_isSelectionMode) {
          _exitSelectionMode();
        } else {
          Navigator.of(context).maybePop();
        }
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.toggleViewMode:
        if (_isSelectionMode) return KeyEventResult.ignored;
        final nextMode = settings.mediaLibraryViewMode == 0 ? 1 : 0;
        settings.updateSetting('mediaLibraryViewMode', nextMode);
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.toggleFullScreen:
        if (_isSelectionMode || !_supportsDesktopManagementShortcuts) {
          return KeyEventResult.ignored;
        }
        settings.toggleFullScreen();
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openLargeDataDirectory:
        if (_isSelectionMode || !Platform.isWindows) {
          return KeyEventResult.ignored;
        }
        _showLargeDataPathDialog(context);
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.exportSettings:
        if (_isSelectionMode || !_showExportSettingsButton) {
          return KeyEventResult.ignored;
        }
        _exportSettingsSnapshot();
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openRecycleBin:
        if (_isSelectionMode) return KeyEventResult.ignored;
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const RecycleBinScreen()));
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openCardStyle:
        if (_isSelectionMode) return KeyEventResult.ignored;
        _showCardStyleBottomSheet(context, settings);
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.enterSelectionMode:
        if (_isSelectionMode) return KeyEventResult.ignored;
        setState(() {
          _isSelectionMode = true;
        });
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.toggleSelectAll:
        if (!_isSelectionMode) return KeyEventResult.ignored;
        _toggleSelectAllInCollection();
        return KeyEventResult.handled;
    }
  }

  KeyEventResult _handleShortcutKeyEvent(KeyEvent event) {
    if (!_supportsDesktopManagementShortcuts) return KeyEventResult.ignored;
    if (_isTextInputFocused()) {
      return KeyEventResult.ignored;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    final bool hasBlockingModifier =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (hasBlockingModifier) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final DesktopMediaManagementShortcutAction? managementAction =
        DesktopMediaManagementShortcuts.matchAction(key);
    final isTargetKey =
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.escape;
    if (!isTargetKey && managementAction == null) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.handled;

    if (managementAction != null &&
        managementAction !=
            DesktopMediaManagementShortcutAction.backOrExitSelection) {
      return _handleManagementShortcut(managementAction);
    }

    if (key == LogicalKeyboardKey.escape) {
      if (managementAction != null) {
        return _handleManagementShortcut(managementAction);
      }
      return KeyEventResult.ignored;
    }

    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    final settings = Provider.of<SettingsService>(context, listen: false);
    final canControl =
        playbackService.currentItem != null &&
        (playbackService.state == PlaybackState.playing ||
            playbackService.state == PlaybackState.paused);
    if (!canControl) return KeyEventResult.handled;

    if (key == LogicalKeyboardKey.space) {
      if (playbackService.isPlaying) {
        playbackService.pause();
      } else {
        playbackService.resume();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      playbackService.handleExternalDoubleTapSeek(
        isLeft: true,
        doubleTapSeekSeconds: settings.doubleTapSeekSeconds,
        enableDoubleTapSubtitleSeek: settings.enableDoubleTapSubtitleSeek,
        subtitleOffset: settings.subtitleOffset,
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      playbackService.handleExternalDoubleTapSeek(
        isLeft: false,
        doubleTapSeekSeconds: settings.doubleTapSeekSeconds,
        enableDoubleTapSubtitleSeek: settings.enableDoubleTapSubtitleSeek,
        subtitleOffset: settings.subtitleOffset,
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.handled;
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
    final itemWidth =
        (mediaQuery.size.width - 32 - (16 * (crossAxisCount - 1))) /
        crossAxisCount;
    final itemHeight = itemWidth / settings.videoCardAspectRatio;
    final rowHeight = itemHeight + 16;
    final visibleRows = (mediaQuery.size.height / rowHeight).ceil().clamp(1, 8);
    final precacheCount = (crossAxisCount * (visibleRows + 1)).clamp(
      0,
      _videoItems.length,
    );

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
    final itemWidth =
        (mediaQuery.size.width - 32 - (16 * (crossAxisCount - 1))) /
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

      await Future.wait(
        batch.map((item) async {
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
        }),
      );
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
    final endIndex = (currentIndex + bufferSize * 2).clamp(
      0,
      _videoItems.length,
    );

    // 根据滚动方向更新优先级
    final direction = _scrollController.position.userScrollDirection;

    _preloadManager.updatePriorities(currentIndex, direction);
    _preloadManager.preloadRange(_videoItems, startIndex, endIndex);

    _scrollPrecacheTimer?.cancel();
    _scrollPrecacheTimer = Timer(const Duration(milliseconds: 120), () {
      _precacheVideoRange(startIndex, endIndex);
    });
  }

  Widget _buildMoveOutTarget(
    BuildContext context,
    LibraryService library,
    VideoCollection collection, {
    double height = 60,
    EdgeInsets margin = const EdgeInsets.fromLTRB(16, 16, 16, 0),
  }) {
    return DragTarget<int>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) async {
        await _moveItemsToParentCollection(
          library,
          collection,
          draggedIndex: details.data,
        );
      },
      builder: (context, candidateData, rejectedData) {
        final isHovering = candidateData.isNotEmpty;
        final hasSelectedItems = _selectedIds.isNotEmpty;
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: hasSelectedItems
                ? () => _moveItemsToParentCollection(library, collection)
                : null,
            child: Container(
              width: double.infinity,
              height: height,
              margin: margin,
              decoration: BoxDecoration(
                color: isHovering
                    ? Colors.blueAccent.withValues(alpha: 0.3)
                    : const Color(0xFF2C2C2C),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isHovering ? Colors.blueAccent : Colors.white24,
                  width: 2,
                  style: isHovering ? BorderStyle.solid : BorderStyle.none,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.reply_all,
                    color: isHovering ? Colors.blueAccent : Colors.white70,
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
            ),
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
        final collection =
            library.getCollection(widget.collectionId) ??
            VideoCollection(id: '', name: '未知合集', createTime: 0);

        final contents = library.getContents(widget.collectionId);

        return PopScope(
          canPop: !_isSelectionMode,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            _exitSelectionMode();
          },
          child: Scaffold(
            backgroundColor: const Color(0xFF121212),
            appBar: AppBar(
              title: _isSelectionMode
                  ? _buildMoveOutTarget(
                      context,
                      library,
                      collection,
                      height: kToolbarHeight - 8,
                      margin: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                    )
                  : Row(
                      children: [
                        IconButton(
                          icon: Icon(
                            settings.mediaLibraryViewMode == 0
                                ? Icons.view_list_rounded
                                : Icons.grid_view_rounded,
                            color: settings.mediaLibraryViewMode == 0
                                ? Colors.white70
                                : Colors.blueAccent,
                          ),
                          tooltip: settings.mediaLibraryViewMode == 0
                              ? _managementTooltip(
                                  "切换列表视图",
                                  DesktopMediaManagementShortcutAction
                                      .toggleViewMode,
                                )
                              : _managementTooltip(
                                  "切换卡片视图",
                                  DesktopMediaManagementShortcutAction
                                      .toggleViewMode,
                                ),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 36,
                            height: 36,
                          ),
                          onPressed: () {
                            final nextMode = settings.mediaLibraryViewMode == 0
                                ? 1
                                : 0;
                            settings.updateSetting(
                              'mediaLibraryViewMode',
                              nextMode,
                            );
                          },
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Column(
                            children: [
                              Text(
                                collection.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                              ValueListenableBuilder<bool>(
                                valueListenable: library.isImporting,
                                builder: (context, isImporting, _) {
                                  if (!isImporting) {
                                    return const SizedBox.shrink();
                                  }
                                  return ValueListenableBuilder<String>(
                                    valueListenable: library.importStatus,
                                    builder: (context, status, _) {
                                      return Text(
                                        status,
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: Colors.white70,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      );
                                    },
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
              centerTitle: false,
              leading: _isSelectionMode
                  ? IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: _managementTooltip(
                        "退出选择",
                        DesktopMediaManagementShortcutAction
                            .backOrExitSelection,
                      ),
                      onPressed: () {
                        _exitSelectionMode();
                      },
                    )
                  : IconButton(
                      icon: const Icon(Icons.arrow_back),
                      tooltip: _managementTooltip(
                        "返回上一级",
                        DesktopMediaManagementShortcutAction
                            .backOrExitSelection,
                      ),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
              actions: [
                ResponsiveActionButtons(
                  buttons: [
                    if (!_isSelectionMode) ...[
                      if (Platform.isWindows ||
                          Platform.isLinux ||
                          Platform.isMacOS)
                        ResponsiveIconButton(
                          icon: settings.isFullScreen
                              ? Icons.fullscreen_exit
                              : Icons.fullscreen,
                          tooltip: _managementTooltip(
                            settings.isFullScreen ? "退出全屏" : "全屏",
                            DesktopMediaManagementShortcutAction
                                .toggleFullScreen,
                          ),
                          onPressed: () => settings.toggleFullScreen(),
                        ),
                      if (Platform.isWindows)
                        ResponsiveIconButton(
                          icon: Icons.folder_open,
                          tooltip: _managementTooltip(
                            "大文件目录",
                            DesktopMediaManagementShortcutAction
                                .openLargeDataDirectory,
                          ),
                          onPressed: () => _showLargeDataPathDialog(context),
                        ),
                      if (_showExportSettingsButton)
                        ResponsiveIconButton(
                          icon: Icons.file_download,
                          tooltip: _managementTooltip(
                            "导出设置",
                            DesktopMediaManagementShortcutAction.exportSettings,
                          ),
                          onPressed: _exportSettingsSnapshot,
                        ),
                      ResponsiveIconButton(
                        icon: Icons.delete_outline,
                        tooltip: _managementTooltip(
                          "回收站",
                          DesktopMediaManagementShortcutAction.openRecycleBin,
                        ),
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const RecycleBinScreen(),
                            ),
                          );
                        },
                      ),
                      ResponsiveIconButton(
                        icon: Icons.tune,
                        tooltip: _managementTooltip(
                          "调整卡片样式",
                          DesktopMediaManagementShortcutAction.openCardStyle,
                        ),
                        onPressed: () =>
                            _showCardStyleBottomSheet(context, settings),
                      ),
                      ResponsiveIconButton(
                        icon: Icons.checklist,
                        tooltip: _managementTooltip(
                          "批量管理",
                          DesktopMediaManagementShortcutAction
                              .enterSelectionMode,
                        ),
                        onPressed: () {
                          setState(() {
                            _isSelectionMode = true;
                          });
                        },
                      ),
                    ] else ...[
                      ResponsiveIconButton(
                        icon: Icons.select_all,
                        tooltip: _managementTooltip(
                          "全选",
                          DesktopMediaManagementShortcutAction.toggleSelectAll,
                        ),
                        onPressed: _toggleSelectAllInCollection,
                      ),
                    ],
                  ],
                ),
              ],
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(4),
                child: ValueListenableBuilder<double>(
                  valueListenable: library.importProgress,
                  builder: (context, progress, _) {
                    if (progress <= 0 || progress >= 1) {
                      return const SizedBox.shrink();
                    }
                    return LinearProgressIndicator(
                      value: progress,
                      backgroundColor: Colors.transparent,
                      minHeight: 4,
                    );
                  },
                ),
              ),
            ),
            body: Focus(
              focusNode: _shortcutFocusNode,
              autofocus: _supportsDesktopManagementShortcuts,
              onKeyEvent: (node, event) => _handleShortcutKeyEvent(event),
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) {
                  if (_supportsDesktopManagementShortcuts &&
                      !_shortcutFocusNode.hasFocus) {
                    _shortcutFocusNode.requestFocus();
                  }
                },
                child: DropTarget(
                  onDragDone: (details) {
                    if (ModalRoute.of(context)?.isCurrent != true) return;
                    setState(() {
                      _isDraggingFiles = false;
                    });
                    final paths = details.files.map((f) => f.path).toList();
                    if (paths.isNotEmpty) {
                      VideoActionButtons.processDroppedPaths(
                        context,
                        paths,
                        widget.collectionId,
                      );
                    }
                  },
                  onDragEntered: (_) {
                    if (ModalRoute.of(context)?.isCurrent != true) return;
                    setState(() => _isDraggingFiles = true);
                  },
                  onDragExited: (_) => setState(() => _isDraggingFiles = false),
                  child: Stack(
                    children: [
                      contents.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    Icons.video_collection_outlined,
                                    size: 80,
                                    color: Colors.white24,
                                  ),
                                  const SizedBox(height: 16),
                                  const Text(
                                    "合集是空的",
                                    style: TextStyle(color: Colors.white54),
                                  ),
                                  const SizedBox(height: 16),
                                  VideoActionButtons(
                                    collectionId: widget.collectionId,
                                    isHorizontal: true,
                                  ),
                                ],
                              ),
                            )
                          : GestureDetector(
                              onScaleStart: (details) {
                                // Allow box selection in two cases:
                                // 1. Windows platform (Mouse drag) in non-selection mode (existing logic)
                                // 2. ANY platform in selection mode (User request: "Start position can be non-card area")

                                bool canStartBoxSelection = false;

                                if (_isSelectionMode) {
                                  // In selection mode, any drag on empty space starts a box selection
                                  // But we need to distinguish from scrolling.
                                  // If it's a mouse drag, it's box selection.
                                  // If it's a touch drag? User said "For all versions... start position can be non-card".
                                  // If I touch and drag on phone, usually it scrolls.
                                  // But if I touch empty space?
                                  // Let's check if we hit an item.
                                  // If we hit an item, the item's onTap/onLongPress/onPan handles it.
                                  // If we are here, it means we likely didn't hit an item's interactive area?
                                  // Or the item didn't claim the gesture.
                                  canStartBoxSelection = true;
                                } else if (Platform.isWindows &&
                                    details.pointerCount == 1) {
                                  canStartBoxSelection = true;
                                }

                                if (canStartBoxSelection) {
                                  // Check if we hit an item to avoid conflict?
                                  // In selection mode, if I touch an item, I toggle it (onTap) or drag it (onPan if circle).
                                  // If I touch item body and drag? It should probably scroll or reorder?
                                  // Reorder is handled by LongPressDraggable.
                                  // So if I am here, maybe I hit empty space.

                                  final renderBox =
                                      context.findRenderObject() as RenderBox?;
                                  if (renderBox != null) {
                                    final contentOffset =
                                        details.localFocalPoint +
                                        Offset(0, _scrollController.offset);
                                    if (_getIndexAt(contentOffset) == null) {
                                      // Started on empty area
                                      _isBoxSelecting = true;
                                      _boxStartPos = details.localFocalPoint;
                                      _boxCurrentPos = details.localFocalPoint;
                                      _capturedIds
                                          .clear(); // Clear capture history for new drag

                                      // If in selection mode, we might want to capture current selection as snapshot?
                                      // Logic: "Drag selection level is higher".
                                      // If I start dragging from empty space, do I keep existing selection?
                                      // Usually yes (Add mode) or No (Replace mode).
                                      // Windows default is Replace.
                                      // But user said "For all versions".
                                      // Let's assume Replace for empty space drag in selection mode too?
                                      // Or Union?
                                      // User's description of "Higher level" suggests Union with Capture logic.
                                      // Let's Init snapshot.
                                      if (_isSelectionMode) {
                                        _dragSelectionSnapshot = Set.from(
                                          _selectedIds,
                                        );
                                      } else {
                                        _dragSelectionSnapshot.clear();
                                      }

                                      setState(() {});
                                      return;
                                    }
                                  }
                                }
                                _baseCrossAxisCount =
                                    settings.videoCardCrossAxisCount;
                              },
                              onScaleUpdate: (details) {
                                if (_isBoxSelecting) {
                                  setState(() {
                                    _boxCurrentPos = details.localFocalPoint;
                                  });

                                  // Real-time update for empty space drag
                                  if (_boxStartPos != null &&
                                      _boxCurrentPos != null) {
                                    final rect = Rect.fromPoints(
                                      _boxStartPos!,
                                      _boxCurrentPos!,
                                    );
                                    final contentRect = rect.shift(
                                      Offset(0, _scrollController.offset),
                                    );

                                    final Set<String> currentInBox = {};
                                    final count = _getItemCount();

                                    // Optimization: Only check items in the visible range of the selection box
                                    // Pre-calculate layout parameters to avoid repeated Provider/MediaQuery calls
                                    final double screenWidth = MediaQuery.of(
                                      context,
                                    ).size.width;
                                    const double spacing = 16.0;
                                    const double hPadding = 16.0;
                                    const double topPadding = 16.0;

                                    final double totalSpacing =
                                        (settings.videoCardCrossAxisCount - 1) *
                                            spacing +
                                        (hPadding * 2);
                                    final double itemWidth =
                                        (screenWidth - totalSpacing) /
                                        settings.videoCardCrossAxisCount;
                                    final double itemHeight =
                                        itemWidth /
                                        settings.videoCardAspectRatio;

                                    // Calculate grid range affected by contentRect
                                    int minRow =
                                        ((contentRect.top - topPadding) /
                                                (itemHeight + spacing))
                                            .floor();
                                    int maxRow =
                                        ((contentRect.bottom - topPadding) /
                                                (itemHeight + spacing))
                                            .floor();
                                    int minCol =
                                        ((contentRect.left - hPadding) /
                                                (itemWidth + spacing))
                                            .floor();
                                    int maxCol =
                                        ((contentRect.right - hPadding) /
                                                (itemWidth + spacing))
                                            .floor();

                                    // Clamp ranges
                                    if (minRow < 0) minRow = 0;
                                    if (minCol < 0) minCol = 0;
                                    if (maxCol >=
                                        settings.videoCardCrossAxisCount) {
                                      maxCol =
                                          settings.videoCardCrossAxisCount - 1;
                                    }

                                    // Iterate only through potentially overlapping items
                                    for (
                                      int row = minRow;
                                      row <= maxRow;
                                      row++
                                    ) {
                                      for (
                                        int col = minCol;
                                        col <= maxCol;
                                        col++
                                      ) {
                                        final index =
                                            row *
                                                settings
                                                    .videoCardCrossAxisCount +
                                            col;
                                        if (index >= 0 && index < count) {
                                          final double x =
                                              hPadding +
                                              col * (itemWidth + spacing);
                                          final double y =
                                              topPadding +
                                              row * (itemHeight + spacing);
                                          final itemRect = Rect.fromLTWH(
                                            x,
                                            y,
                                            itemWidth,
                                            itemHeight,
                                          );

                                          if (itemRect.overlaps(contentRect)) {
                                            final id = _getItemId(index);
                                            if (id != null) {
                                              currentInBox.add(id);
                                            }
                                          }
                                        }
                                      }
                                    }

                                    // Logic for Empty Space Drag:
                                    // If not in selection mode -> Replace (Standard Windows)
                                    // If in selection mode -> Union with Capture Logic (User Requirement)

                                    if (!_isSelectionMode) {
                                      // Just visualize, don't select yet?
                                      // Windows behavior: Visual only until release?
                                      // User said: "松开鼠标后...如果选择到了卡片，则进入选择模式"
                                      // So Real-time update is NOT needed for selection state, ONLY visual.
                                      // Correct.
                                    } else {
                                      // In selection mode: Real-time update IS needed.
                                      // Apply Capture Logic
                                      _capturedIds.addAll(currentInBox);

                                      final Set<String> newSelection = {};
                                      for (final id in _dragSelectionSnapshot) {
                                        if (!_capturedIds.contains(id)) {
                                          newSelection.add(id);
                                        }
                                      }
                                      newSelection.addAll(currentInBox);

                                      if (newSelection.length !=
                                              _selectedIds.length ||
                                          !_selectedIds.containsAll(
                                            newSelection,
                                          )) {
                                        _selectedIds.clear();
                                        _selectedIds.addAll(newSelection);
                                        if (Platform.isAndroid ||
                                            Platform.isIOS) {
                                          HapticFeedback.selectionClick();
                                        }
                                      }
                                    }
                                  }
                                  return;
                                }

                                double newScale = details.scale;
                                int newCount = _baseCrossAxisCount;

                                if (newScale > 1.3) {
                                  newCount = (_baseCrossAxisCount - 1).clamp(
                                    1,
                                    15,
                                  );
                                } else if (newScale < 0.7) {
                                  newCount = (_baseCrossAxisCount + 1).clamp(
                                    1,
                                    15,
                                  );
                                }

                                if (newCount !=
                                    settings.videoCardCrossAxisCount) {
                                  settings.updateSetting(
                                    'videoCardCrossAxisCount',
                                    newCount,
                                  );
                                }
                              },
                              onScaleEnd: (details) {
                                if (_isBoxSelecting) {
                                  // Calculate selected items (Only needed if NOT in selection mode, because in selection mode we update real-time)
                                  // Actually, if we are not in selection mode, we need to apply selection now.

                                  if (!_isSelectionMode &&
                                      _boxStartPos != null &&
                                      _boxCurrentPos != null) {
                                    final rect = Rect.fromPoints(
                                      _boxStartPos!,
                                      _boxCurrentPos!,
                                    );
                                    final contentRect = rect.shift(
                                      Offset(0, _scrollController.offset),
                                    );

                                    final Set<String> newSelected = {};
                                    final count = _getItemCount();

                                    for (int i = 0; i < count; i++) {
                                      final itemRect = _getItemRect(i);
                                      if (itemRect != null &&
                                          itemRect.overlaps(contentRect)) {
                                        final id = _getItemId(i);
                                        if (id != null) newSelected.add(id);
                                      }
                                    }

                                    if (newSelected.isNotEmpty) {
                                      setState(() {
                                        _isSelectionMode = true;
                                        _selectedIds.addAll(newSelected);
                                      });
                                    }
                                  }

                                  setState(() {
                                    _isBoxSelecting = false;
                                    _boxStartPos = null;
                                    _boxCurrentPos = null;
                                    _capturedIds.clear();
                                  });
                                  return;
                                }
                              },
                              child: Container(
                                height: MediaQuery.of(context).size.height,
                                color: Colors.transparent,
                                child: _buildMediaGridOrList(
                                  context: context,
                                  library: library,
                                  settings: settings,
                                  contents: contents,
                                ),
                              ),
                            ),
                      // Fill the rest of the screen with a transparent hit target to ensure GestureDetector catches taps in empty space
                      if (contents.length <
                          20) // Only if potentially empty space at bottom
                        Positioned.fill(
                          child: Listener(
                            behavior: HitTestBehavior.translucent,
                            onPointerDown:
                                (
                                  _,
                                ) {}, // Consumes touch to pass to GestureDetector parent? No, Listener doesn't consume.
                            // We need a widget that participates in hit test but lets events bubble up?
                            // GestureDetector with translucent behavior catches it.
                            // But GridView might not fill the height.
                            // So we place this BEHIND GridView? No, GridView is in GestureDetector child.
                            // If GridView shrinks, GestureDetector child shrinks.
                            // So GestureDetector might not cover full screen.
                            // FIX: Wrap GridView in a Container with double.infinity height.
                          ),
                        ),
                      if (_isBoxSelecting &&
                          _boxStartPos != null &&
                          _boxCurrentPos != null &&
                          !_isSelectionMode)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: _BoxSelectionPainter(
                                selectionRect: Rect.fromPoints(
                                  _boxStartPos!,
                                  _boxCurrentPos!,
                                ),
                              ),
                            ),
                          ),
                        ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Consumer<MediaPlaybackService>(
                          builder: (context, playbackService, child) {
                            final isVisible =
                                playbackService.currentItem != null &&
                                (playbackService.state ==
                                        PlaybackState.playing ||
                                    playbackService.state ==
                                        PlaybackState.paused);
                            if (!isVisible) return const SizedBox.shrink();
                            return Container(
                              height: _getPlaybackCardVerticalOffset(),
                              color: const Color(0xFF2C2C2C),
                            );
                          },
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: _getPlaybackCardVerticalOffset(),
                        child: Consumer<MediaPlaybackService>(
                          builder: (context, playbackService, child) {
                            final isVisible =
                                playbackService.currentItem != null &&
                                (playbackService.state ==
                                        PlaybackState.playing ||
                                    playbackService.state ==
                                        PlaybackState.paused);

                            return MiniPlaybackCard(
                              isVisible: isVisible,
                              onTap: () async {
                                final currentItem = playbackService.currentItem;
                                if (currentItem == null) return;
                                if (!File(currentItem.path).existsSync()) {
                                  AppToast.show(
                                    "媒体文件不存在，可能已被移动或删除",
                                    type: AppToastType.error,
                                  );
                                  return;
                                }
                                if (playbackService.controller == null) {
                                  AppToast.show(
                                    "播放器尚未准备好，请稍后重试",
                                    type: AppToastType.error,
                                  );
                                  return;
                                }

                                // 1. 立即触发一次 UI 刷新
                                setState(() {});

                                // 2. 短暂延迟
                                await Future.delayed(
                                  const Duration(milliseconds: 150),
                                );
                                if (!context.mounted) return;

                                // 3. 再次强制刷新
                                setState(() {});

                                Navigator.of(context, rootNavigator: true).push(
                                  _buildVideoPlayerRoute(
                                    currentItem,
                                    playbackService.controller,
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                      if (_isDraggingFiles)
                        Positioned.fill(
                          child: Container(
                            color: Colors.black54,
                            child: const Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.cloud_upload,
                                    size: 80,
                                    color: Colors.blueAccent,
                                  ),
                                  SizedBox(height: 16),
                                  Text(
                                    "松开以导入媒体文件、压缩包或文件夹",
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 24,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            floatingActionButton: !_isSelectionMode
                ? Padding(
                    padding: EdgeInsets.only(
                      bottom: _getPlaybackCardBottomPadding(),
                    ),
                    child: VideoActionButtons(
                      collectionId: widget.collectionId,
                    ),
                  )
                : null,
            bottomNavigationBar: _isSelectionMode && _selectedIds.isNotEmpty
                ? BottomAppBar(
                    color: const Color(0xFF1E1E1E),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        TextButton.icon(
                          icon: const Icon(
                            Icons.delete,
                            color: Colors.redAccent,
                          ),
                          label: const Text(
                            "移入回收站",
                            style: TextStyle(color: Colors.redAccent),
                          ),
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
                            icon: const Icon(
                              Icons.edit,
                              color: Colors.blueAccent,
                            ),
                            label: const Text(
                              "重命名",
                              style: TextStyle(color: Colors.blueAccent),
                            ),
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

  Widget _buildMediaGridOrList({
    required BuildContext context,
    required LibraryService library,
    required SettingsService settings,
    required List<dynamic> contents,
  }) {
    final basePadding = EdgeInsets.only(
      left: 16,
      right: 16,
      top: 16,
      bottom: 16 + _getPlaybackCardBottomPadding(),
    );
    if (settings.mediaLibraryViewMode == 0) {
      return GridView.builder(
        controller: _scrollController,
        padding: basePadding,
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
            return _buildCollectionCard(
              context,
              library,
              item,
              index,
              settings,
              contents,
            );
          } else if (item is VideoItem) {
            return _buildVideoCard(context, item, index, settings, contents);
          }
          return const SizedBox.shrink();
        },
      );
    }

    final size = MediaQuery.of(context).size;
    final crossAxisCount = settings.mediaListCrossAxisCount.clamp(1, 15);
    final rowHeight = (size.width * settings.mediaListItemHeightScale).clamp(
      2.0,
      320.0,
    );
    final mainSpacing = (size.width * settings.mediaListMainSpacingScale).clamp(
      2.0,
      36.0,
    );
    final crossSpacing = (size.width * settings.mediaListCrossSpacingScale)
        .clamp(2.0, 40.0);

    return GridView.builder(
      controller: _scrollController,
      padding: basePadding,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio:
            ((size.width - 32 - (crossAxisCount - 1) * crossSpacing) /
                crossAxisCount) /
            rowHeight,
        crossAxisSpacing: crossSpacing,
        mainAxisSpacing: mainSpacing,
      ),
      itemCount: contents.length,
      itemBuilder: (context, index) {
        final item = contents[index];
        if (item is VideoCollection) {
          return _buildCollectionListCard(
            context: context,
            collection: item,
            index: index,
            settings: settings,
          );
        } else if (item is VideoItem) {
          return _buildVideoListCard(
            context: context,
            item: item,
            index: index,
            settings: settings,
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  Widget _buildCollectionListCard({
    required BuildContext context,
    required VideoCollection collection,
    required int index,
    required SettingsService settings,
  }) {
    final isSelected = _selectedIds.contains(collection.id);
    final titleScale = settings.mediaListTitleScale.clamp(0.0005, 0.2);
    final titleFont = (MediaQuery.of(context).size.width * titleScale).clamp(
      0.6,
      60.0,
    );
    final subFont = (titleFont * 0.84).clamp(0.5, 52.0);
    final coverOffset = settings.mediaListCoverOffset.clamp(-1.0, 1.0);
    final showIndex = settings.mediaListShowIndex;

    return Card(
      clipBehavior: Clip.antiAlias,
      color: isSelected
          ? Colors.blueAccent.withValues(alpha: 0.2)
          : const Color(0xFF2C2C2C),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isSelected
            ? const BorderSide(color: Colors.blueAccent, width: 1.6)
            : BorderSide.none,
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
                builder: (context) =>
                    CollectionScreen(collectionId: collection.id),
              ),
            );
          }
        },
        child: LayoutBuilder(
          builder: (context, rowBox) {
            final minThumbWidth = (rowBox.maxWidth * 0.2).clamp(56.0, 120.0);
            final maxThumbWidth = (rowBox.maxWidth * 0.55).clamp(72.0, 280.0);
            final thumbWidth = (rowBox.maxHeight * (4 / 3)).clamp(
              minThumbWidth,
              maxThumbWidth,
            );
            final thumbShift = settings.mediaListShowThumbnail
                ? coverOffset * (thumbWidth * 0.26)
                : 0.0;
            final indexWidth = showIndex
                ? (rowBox.maxWidth * 0.07).clamp(28.0, 36.0)
                : 0.0;
            final leadingGap = (rowBox.maxWidth * 0.012).clamp(2.0, 6.0);
            final thumbnailBg = isSelected
                ? const Color(0xFF2C2C2C).withValues(alpha: 0.9)
                : const Color(0xFF2C2C2C);
            return Row(
              children: [
                if (showIndex)
                  SizedBox(
                    width: indexWidth,
                    child: Text(
                      '${index + 1}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: subFont,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                if (settings.mediaListShowThumbnail)
                  Transform.translate(
                    offset: Offset(thumbShift, 0),
                    child: SizedBox(
                      width: thumbWidth,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ColoredBox(color: thumbnailBg),
                          collection.thumbnailPath != null &&
                                  collection.thumbnailPath!.isNotEmpty
                              ? CachedThumbnailWidget(
                                  videoId: collection.id,
                                  thumbnailPath: collection.thumbnailPath,
                                  fit: BoxFit.cover,
                                  placeholder: SizedBox.expand(
                                    child: ColoredBox(color: thumbnailBg),
                                  ),
                                  errorWidget: const Icon(
                                    Icons.folder,
                                    color: Colors.blueAccent,
                                  ),
                                )
                              : const Icon(
                                  Icons.folder,
                                  color: Colors.blueAccent,
                                ),
                        ],
                      ),
                    ),
                  ),
                SizedBox(width: leadingGap),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, textBox) {
                      final baseHorizontalPadding = (textBox.maxWidth * 0.024)
                          .clamp(4.0, 12.0);
                      final horizontalPadding =
                          (baseHorizontalPadding + thumbShift).clamp(2.0, 24.0);
                      final verticalPadding = (textBox.maxWidth * 0.018).clamp(
                        3.0,
                        8.0,
                      );
                      return Padding(
                        padding: EdgeInsets.only(
                          left: horizontalPadding,
                          right: baseHorizontalPadding,
                          top: verticalPadding,
                          bottom: verticalPadding,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                collection.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: titleFont,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Align(
                              alignment: Alignment.bottomLeft,
                              child: Text(
                                '${collection.childrenIds.length} 个项目',
                                style: TextStyle(
                                  color: Colors.white54,
                                  fontSize: subFont,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildVideoListCard({
    required BuildContext context,
    required VideoItem item,
    required int index,
    required SettingsService settings,
  }) {
    final isSelected = _selectedIds.contains(item.id);
    final titleScale = settings.mediaListTitleScale.clamp(0.0005, 0.2);
    final titleFont = (MediaQuery.of(context).size.width * titleScale).clamp(
      0.6,
      60.0,
    );
    final subFont = (titleFont * 0.84).clamp(0.5, 52.0);
    final coverOffset = settings.mediaListCoverOffset.clamp(-1.0, 1.0);
    final showIndex = settings.mediaListShowIndex;

    return Card(
      clipBehavior: Clip.antiAlias,
      color: isSelected
          ? Colors.blueAccent.withValues(alpha: 0.2)
          : const Color(0xFF2C2C2C),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isSelected
            ? const BorderSide(color: Colors.blueAccent, width: 1.6)
            : BorderSide.none,
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
            return;
          }

          final playbackService = Provider.of<MediaPlaybackService>(
            context,
            listen: false,
          );

          final file = File(item.path);
          if (!await file.exists()) {
            if (!context.mounted) return;
            AppToast.show("媒体文件不存在，可能已被移动或删除", type: AppToastType.error);
            return;
          }

          final currentController = playbackService.currentItem?.id == item.id
              ? playbackService.controller
              : null;
          _openPlaybackScreen(item, existingController: currentController);
        },
        child: LayoutBuilder(
          builder: (context, rowBox) {
            final minThumbWidth = (rowBox.maxWidth * 0.2).clamp(56.0, 120.0);
            final maxThumbWidth = (rowBox.maxWidth * 0.55).clamp(72.0, 280.0);
            final thumbWidth = (rowBox.maxHeight * (4 / 3)).clamp(
              minThumbWidth,
              maxThumbWidth,
            );
            final thumbShift = settings.mediaListShowThumbnail
                ? coverOffset * (thumbWidth * 0.26)
                : 0.0;
            final indexWidth = showIndex
                ? (rowBox.maxWidth * 0.07).clamp(28.0, 36.0)
                : 0.0;
            final leadingGap = (rowBox.maxWidth * 0.012).clamp(2.0, 6.0);
            final thumbnailBg = isSelected
                ? const Color(0xFF2C2C2C).withValues(alpha: 0.9)
                : const Color(0xFF2C2C2C);
            return Row(
              children: [
                if (showIndex)
                  SizedBox(
                    width: indexWidth,
                    child: Text(
                      '${index + 1}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: subFont,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                if (settings.mediaListShowThumbnail)
                  Transform.translate(
                    offset: Offset(thumbShift, 0),
                    child: SizedBox(
                      width: thumbWidth,
                      child: ColoredBox(
                        color: thumbnailBg,
                        child: item.type == MediaType.audio
                            ? const Icon(
                                Icons.music_note,
                                size: 30,
                                color: Colors.white30,
                              )
                            : CachedThumbnailWidget(
                                videoId: item.id,
                                thumbnailPath: item.thumbnailPath,
                                fit: BoxFit.cover,
                                placeholder: SizedBox.expand(
                                  child: ColoredBox(color: thumbnailBg),
                                ),
                                errorWidget: const Icon(
                                  Icons.movie,
                                  size: 30,
                                  color: Colors.white30,
                                ),
                              ),
                      ),
                    ),
                  ),
                SizedBox(width: leadingGap),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, textBox) {
                      final baseHorizontalPadding = (textBox.maxWidth * 0.024)
                          .clamp(4.0, 12.0);
                      final horizontalPadding =
                          (baseHorizontalPadding + thumbShift).clamp(2.0, 24.0);
                      final verticalPadding = (textBox.maxWidth * 0.018).clamp(
                        3.0,
                        8.0,
                      );
                      return Padding(
                        padding: EdgeInsets.only(
                          left: horizontalPadding,
                          right: baseHorizontalPadding,
                          top: verticalPadding,
                          bottom: verticalPadding,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                item.title,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: titleFont,
                                  fontWeight: FontWeight.w500,
                                  height: 1.15,
                                ),
                              ),
                            ),
                            Selector<
                              MediaPlaybackService,
                              ({bool isCurrent, int positionMs, int durationMs})
                            >(
                              selector: (context, service) {
                                final isCurrent =
                                    service.currentItem?.id == item.id;
                                if (!isCurrent) {
                                  return (
                                    isCurrent: false,
                                    positionMs: item.lastPositionMs,
                                    durationMs: item.durationMs,
                                  );
                                }
                                return (
                                  isCurrent: true,
                                  positionMs: service.position.inMilliseconds,
                                  durationMs:
                                      service.duration.inMilliseconds > 0
                                      ? service.duration.inMilliseconds
                                      : item.durationMs,
                                );
                              },
                              builder: (context, playbackData, _) {
                                final durationMs = playbackData.durationMs;
                                final positionMs = playbackData.positionMs;
                                final shouldShowProgress =
                                    durationMs > 0 &&
                                    (playbackData.isCurrent || positionMs > 0);
                                final progressValue = shouldShowProgress
                                    ? (positionMs / durationMs).clamp(0.0, 1.0)
                                    : 0.0;
                                return Align(
                                  alignment: Alignment.bottomLeft,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _formatMediaDuration(durationMs),
                                        style: TextStyle(
                                          color: Colors.white54,
                                          fontSize: subFont,
                                        ),
                                      ),
                                      if (shouldShowProgress) ...[
                                        const SizedBox(height: 3),
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                          child: SizedBox(
                                            height: 3,
                                            child: LinearProgressIndicator(
                                              value: progressValue,
                                              backgroundColor: Colors.white24,
                                              color: Colors.redAccent,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  String _formatMediaDuration(int durationMs) {
    if (durationMs <= 0) return '--:--';
    final totalSec = durationMs ~/ 1000;
    final min = totalSec ~/ 60;
    final sec = totalSec % 60;
    return '$min:${sec.toString().padLeft(2, '0')}';
  }

  Widget _buildCollectionCard(
    BuildContext context,
    LibraryService library,
    VideoCollection collection,
    int index,
    SettingsService settings,
    List<dynamic> contents,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double cardWidth = constraints.maxWidth;
        final double radius = (cardWidth * 0.09).clamp(4.0, 40.0);
        final double titleFontSize = _resolveCardTitleFontSize(
          cardWidth,
          settings.videoCardTitleFontSize,
        );
        final double metaFontSize = _resolveCardMetaFontSize(titleFontSize);

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
              child: LayoutBuilder(
                builder: (context, iconConstraints) {
                  final iconSize = iconConstraints.maxWidth * 0.15;
                  final iconPadding = iconSize * 0.4;
                  final borderRadius = iconSize * 0.6;
                  final centerIconSize = iconConstraints.maxWidth * 0.55;

                  return Container(
                    color: Colors.black26,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Layer 1: Thumbnail or Placeholder
                        hasThumbnail
                            ? CachedThumbnailWidget(
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
                                    size: centerIconSize,
                                    color: Colors.blueAccent.withValues(
                                      alpha: 0.8,
                                    ),
                                  ),
                                ),
                              )
                            : Center(
                                child: Icon(
                                  Icons.folder,
                                  size: centerIconSize,
                                  color: Colors.blueAccent.withValues(
                                    alpha: 0.8,
                                  ),
                                ),
                              ),
                        // Layer 2: Folder Badge (Top-Left) - Only if has thumbnail
                        if (hasThumbnail)
                          Positioned(
                            left: 0,
                            top: 0,
                            child: Container(
                              padding: EdgeInsets.all(iconPadding),
                              decoration: BoxDecoration(
                                color: Colors.black45,
                                borderRadius: BorderRadius.only(
                                  bottomRight: Radius.circular(borderRadius),
                                ),
                              ),
                              child: Icon(
                                Icons.folder,
                                size: iconSize,
                                color: Colors.blueAccent.withValues(alpha: 0.9),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
            // Info Area
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                color: isSelected
                    ? Colors.blueAccent.withValues(alpha: 0.1)
                    : Colors.transparent,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        collection.name,
                        style: TextStyle(
                          fontSize: titleFontSize,
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
                      style: TextStyle(
                        fontSize: metaFontSize,
                        color: Colors.white54,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );

        // 2. Interaction Wrapper
        Widget interactiveCard = Card(
          color: isSelected
              ? Colors.blueAccent.withValues(alpha: 0.2)
              : const Color(0xFF2C2C2C),
          elevation: isSelected ? 4 : 2,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
            side: isSelected
                ? const BorderSide(color: Colors.blueAccent, width: 2)
                : BorderSide.none,
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
                    builder: (context) =>
                        CollectionScreen(collectionId: collection.id),
                  ),
                );
              }
            },
            child: cardVisual,
          ),
        );

        return Stack(
          children: [
            LongPressDraggable<int>(
              delay: _mediaCardLongPressDelay,
              data: index,
              onDragStarted: () {
                if (!_isSelectionMode) {
                  setState(() {
                    _isSelectionMode = true;
                    if (!_selectedIds.contains(collection.id)) {
                      _selectedIds.add(collection.id);
                    }
                  });
                }
              },
              feedback: SizedBox(
                width: 140,
                height: 160,
                child: Opacity(
                  opacity: 0.9,
                  child: Card(
                    color: const Color(0xFF333333),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(140 * 0.09),
                    ),
                    child: Center(
                      child: _selectedIds.length > 1 && isSelected
                          ? Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.folder,
                                  size: 50,
                                  color: Colors.blueAccent,
                                ),
                                Text(
                                  "${_selectedIds.length} 个项目",
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            )
                          : Icon(
                              Icons.folder,
                              size: 60,
                              color: Colors.blueAccent,
                            ),
                    ),
                  ),
                ),
              ),
              childWhenDragging: Opacity(opacity: 0.3, child: interactiveCard),
              child: FolderDropTarget(
                folderId: collection.id,
                index: index,
                onMoveToFolder: (draggedIndex, targetId) async {
                  if (draggedIndex >= 0 && draggedIndex < contents.length) {
                    final draggedItem = contents[draggedIndex];
                    final draggedId = (draggedItem as dynamic).id;

                    List<String> itemsToMove = [];
                    if (_selectedIds.contains(draggedId)) {
                      itemsToMove = contents
                          .where(
                            (item) =>
                                _selectedIds.contains((item as dynamic).id),
                          )
                          .map((item) => (item as dynamic).id as String)
                          .toList();
                    } else {
                      itemsToMove = [draggedId];
                    }

                    await library.moveItemsToCollection(itemsToMove, targetId);
                    await _syncSelectionAfterMove(
                      library,
                      currentParentId: widget.collectionId,
                      attemptedItemIds: itemsToMove,
                    );
                    AppToast.show("已移动到文件夹", type: AppToastType.success);
                  }
                },
                onReorder: (oldIndex, newIndex) {
                  final draggedItem = contents[oldIndex];
                  final draggedId = (draggedItem as dynamic).id;

                  if (_selectedIds.contains(draggedId)) {
                    final itemsToMove = contents
                        .where(
                          (item) => _selectedIds.contains((item as dynamic).id),
                        )
                        .map((item) => (item as dynamic).id as String)
                        .toList();
                    library.reorderMultipleItems(
                      widget.collectionId,
                      itemsToMove,
                      oldIndex,
                      newIndex,
                    );
                  } else {
                    library.reorderItems(
                      widget.collectionId,
                      oldIndex,
                      newIndex,
                    );
                  }
                },
                child: interactiveCard,
              ),
            ),
            if (_isSelectionMode)
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
                  onPanStart: (details) {
                    setState(() {
                      _dragSelectionStartIndex = index;
                      _dragSelectionSnapshot = Set.from(_selectedIds);
                      _capturedIds.clear();
                      _isBoxSelecting = false;
                      _boxStartPos = null;
                      _boxCurrentPos = null;
                      if (!_selectedIds.contains(collection.id)) {
                        _selectedIds.add(collection.id);
                        _dragSelectionSnapshot.add(collection.id);
                      }
                      _updateDragSelection(details.globalPosition);
                    });
                  },
                  onPanUpdate: (details) {
                    _updateDragSelection(details.globalPosition);
                  },
                  onPanEnd: (details) {
                    setState(() {
                      _dragSelectionStartIndex = null;
                      _dragSelectionSnapshot.clear();
                      _isBoxSelecting = false;
                      _boxStartPos = null;
                      _boxCurrentPos = null;
                      _capturedIds.clear();
                    });
                  },
                  onLongPressStart: (details) {
                    setState(() {
                      _dragSelectionStartIndex = index;
                      _dragSelectionSnapshot = Set.from(_selectedIds);
                      _capturedIds.clear();
                      _isBoxSelecting = false;
                      _boxStartPos = null;
                      _boxCurrentPos = null;
                      if (!_selectedIds.contains(collection.id)) {
                        _selectedIds.add(collection.id);
                        _dragSelectionSnapshot.add(collection.id);
                      }
                      _updateDragSelection(details.globalPosition);
                    });
                  },
                  onLongPressMoveUpdate: (details) {
                    _updateDragSelection(details.globalPosition);
                  },
                  onLongPressEnd: (details) {
                    setState(() {
                      _dragSelectionStartIndex = null;
                      _dragSelectionSnapshot.clear();
                      _isBoxSelecting = false;
                      _boxStartPos = null;
                      _boxCurrentPos = null;
                      _capturedIds.clear();
                    });
                  },
                  behavior: HitTestBehavior
                      .opaque, // Opaque to ensure it captures touches in this area
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
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
    );
  }

  Widget _buildVideoCard(
    BuildContext context,
    VideoItem item,
    int index,
    SettingsService settings,
    List<dynamic> contents,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double cardWidth = constraints.maxWidth;
        final double radius = (cardWidth * 0.09).clamp(4.0, 40.0);
        final double titleFontSize = _resolveCardTitleFontSize(
          cardWidth,
          settings.videoCardTitleFontSize,
        );
        final double metaFontSize = _resolveCardMetaFontSize(titleFontSize);

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
                    item.type == MediaType.audio
                        ? Container(
                            color: Colors.black,
                            child: const Icon(
                              Icons.music_note,
                              size: 50,
                              color: Colors.white24,
                            ),
                          )
                        : LayoutBuilder(
                            builder: (context, constraints) {
                              final dpr = MediaQuery.of(
                                context,
                              ).devicePixelRatio;
                              final cacheWidth = (constraints.maxWidth * dpr)
                                  .round()
                                  .clamp(1, 4096);
                              final cacheHeight = (constraints.maxHeight * dpr)
                                  .round()
                                  .clamp(1, 4096);

                              return CachedThumbnailWidget(
                                videoId: item.id,
                                thumbnailPath: item.thumbnailPath,
                                fit: BoxFit.cover,
                                cacheWidth: cacheWidth,
                                cacheHeight: cacheHeight,
                                placeholder: Container(
                                  color: Colors.black,
                                  child: const Icon(
                                    Icons.movie,
                                    size: 50,
                                    color: Colors.white24,
                                  ),
                                ),
                                errorWidget: const Icon(
                                  Icons.broken_image,
                                  size: 50,
                                ),
                              );
                            },
                          ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child:
                          Selector<
                            MediaPlaybackService,
                            ({bool isCurrent, int positionMs, int durationMs})
                          >(
                            selector: (context, service) {
                              final isCurrent =
                                  service.currentItem?.id == item.id;
                              if (!isCurrent) {
                                return (
                                  isCurrent: false,
                                  positionMs: 0,
                                  durationMs: 0,
                                );
                              }
                              return (
                                isCurrent: true,
                                positionMs: service.position.inMilliseconds,
                                durationMs: service.duration.inMilliseconds,
                              );
                            },
                            builder: (context, data, child) {
                              final bool isCurrent = data.isCurrent;
                              final int durationMs = isCurrent
                                  ? data.durationMs
                                  : item.durationMs;
                              final int positionMs = isCurrent
                                  ? data.positionMs
                                  : item.lastPositionMs;

                              final shouldShow =
                                  durationMs > 0 &&
                                  (isCurrent || positionMs > 0);
                              if (!shouldShow) return const SizedBox.shrink();

                              final value = (positionMs / durationMs).clamp(
                                0.0,
                                1.0,
                              );
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        item.title,
                        style: TextStyle(
                          fontSize: titleFontSize,
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
                              style: TextStyle(
                                fontSize: metaFontSize,
                                color: Colors.white54,
                              ),
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
          color: isSelected
              ? Colors.blueAccent.withValues(alpha: 0.2)
              : const Color(0xFF2C2C2C),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
            side: isSelected
                ? const BorderSide(color: Colors.blueAccent, width: 2)
                : BorderSide.none,
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
                final playbackService = Provider.of<MediaPlaybackService>(
                  context,
                  listen: false,
                );

                final file = File(item.path);
                if (!await file.exists()) {
                  if (!context.mounted) return;
                  AppToast.show("媒体文件不存在，可能已被移动或删除", type: AppToastType.error);
                  return;
                }

                if (!context.mounted) return;

                final currentController =
                    playbackService.currentItem?.id == item.id
                    ? playbackService.controller
                    : null;
                _openPlaybackScreen(
                  item,
                  existingController: currentController,
                );
              }
            },
            child: cardVisual,
          ),
        );

        return Stack(
          children: [
            LongPressDraggable<int>(
              delay: _mediaCardLongPressDelay,
              data: index,
              onDragStarted: () {
                if (!_isSelectionMode) {
                  setState(() {
                    _isSelectionMode = true;
                    if (!_selectedIds.contains(item.id)) {
                      _selectedIds.add(item.id);
                    }
                  });
                }
              },
              feedback: SizedBox(
                width: 140,
                height: 160,
                child: Opacity(
                  opacity: 0.9,
                  child: Card(
                    color: const Color(0xFF333333),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(140 * 0.09),
                    ),
                    child: Center(
                      child: Icon(
                        Icons.movie,
                        size: 60,
                        color: Colors.blueAccent,
                      ),
                    ),
                  ),
                ),
              ),
              childWhenDragging: Opacity(opacity: 0.3, child: interactiveCard),
              child: DragTarget<int>(
                onWillAcceptWithDetails: (details) => details.data != index,
                onAcceptWithDetails: (details) {
                  final oldIndex = details.data;
                  final library = Provider.of<LibraryService>(
                    context,
                    listen: false,
                  );
                  final draggedItem = contents[oldIndex];
                  final draggedId = (draggedItem as dynamic).id;

                  if (_selectedIds.contains(draggedId)) {
                    final itemsToMove = contents
                        .where(
                          (item) => _selectedIds.contains((item as dynamic).id),
                        )
                        .map((item) => (item as dynamic).id as String)
                        .toList();
                    library.reorderMultipleItems(
                      widget.collectionId,
                      itemsToMove,
                      oldIndex,
                      index,
                    );
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
                        borderRadius: BorderRadius.circular(radius),
                      ),
                      child: interactiveCard,
                    );
                  }
                  return targetChild;
                },
              ),
            ),
            if (_isSelectionMode)
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
                  onPanStart: (details) {
                    setState(() {
                      _dragSelectionStartIndex = index;
                      _dragSelectionSnapshot = Set.from(_selectedIds);
                      _capturedIds.clear();
                      _isBoxSelecting = false;
                      _boxStartPos = null;
                      _boxCurrentPos = null;
                      if (!_selectedIds.contains(item.id)) {
                        _selectedIds.add(item.id);
                        _dragSelectionSnapshot.add(item.id);
                      }
                      _updateDragSelection(details.globalPosition);
                    });
                  },
                  onPanUpdate: (details) {
                    _updateDragSelection(details.globalPosition);
                  },
                  onPanEnd: (details) {
                    setState(() {
                      _dragSelectionStartIndex = null;
                      _dragSelectionSnapshot.clear();
                      _isBoxSelecting = false;
                      _boxStartPos = null;
                      _boxCurrentPos = null;
                      _capturedIds.clear();
                    });
                  },
                  onLongPressStart: (details) {
                    setState(() {
                      _dragSelectionStartIndex = index;
                      _dragSelectionSnapshot = Set.from(_selectedIds);
                      _capturedIds.clear();
                      _isBoxSelecting = false;
                      _boxStartPos = null;
                      _boxCurrentPos = null;
                      if (!_selectedIds.contains(item.id)) {
                        _selectedIds.add(item.id);
                        _dragSelectionSnapshot.add(item.id);
                      }
                      _updateDragSelection(details.globalPosition);
                    });
                  },
                  onLongPressMoveUpdate: (details) {
                    _updateDragSelection(details.globalPosition);
                  },
                  onLongPressEnd: (details) {
                    setState(() {
                      _dragSelectionStartIndex = null;
                      _dragSelectionSnapshot.clear();
                      _isBoxSelecting = false;
                      _boxStartPos = null;
                      _boxCurrentPos = null;
                      _capturedIds.clear();
                    });
                  },
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
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
    );
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
                Provider.of<LibraryService>(
                  context,
                  listen: false,
                ).renameItem(id, controller.text);
                Navigator.pop(context);
              }
            },
            child: const Text("确定"),
          ),
        ],
      ),
    );
  }

  Future<void> _loadExportButtonPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getBool('show_export_settings_button') ?? false;
    if (!mounted) {
      _showExportSettingsButton = value;
      return;
    }
    setState(() {
      _showExportSettingsButton = value;
    });
  }

  Future<void> _exportSettingsSnapshot() async {
    try {
      final settings = Provider.of<SettingsService>(context, listen: false);
      final bilibili = Provider.of<BilibiliDownloadService>(
        context,
        listen: false,
      );
      final prefs = await SharedPreferences.getInstance();
      final subtitleDownloadPath = prefs.getString('subtitle_download_path');
      final showExportSettingsButton =
          prefs.getBool('show_export_settings_button') ?? false;

      final exportJson = {
        'schemaVersion': 1,
        'exportedAt': DateTime.now().toIso8601String(),
        'settings': settings.exportSettingsSnapshot(),
        'bilibili': {
          'maxConcurrentDownloads': bilibili.maxConcurrentDownloads,
          'preferredQuality': bilibili.preferredQuality,
          'preferredSubtitleLang': bilibili.preferredSubtitleLang,
          'preferAiSubtitles': bilibili.preferAiSubtitles,
          'autoImportToLibrary': bilibili.autoImportToLibrary,
          'autoDeleteTaskAfterImport': bilibili.autoDeleteTaskAfterImport,
          'sequentialExport': bilibili.sequentialExport,
        },
        'paths': {'subtitleDownloadPath': subtitleDownloadPath},
        'ui': {'showExportSettingsButton': showExportSettingsButton},
      };

      final dir = await _resolveExportDirectory();
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final filePath = p.join(dir.path, 'video_player_settings_export.json');
      final file = File(filePath);
      const encoder = JsonEncoder.withIndent('  ');
      await file.writeAsString(encoder.convert(exportJson));

      if (!mounted) return;
      final result = await OpenFilex.open(filePath, type: 'application/json');
      if (!mounted) return;
      if (result.type == ResultType.done) {
        AppToast.show("设置已导出并打开: $filePath", type: AppToastType.success);
      } else {
        AppToast.show("设置已导出，但打开失败: $filePath", type: AppToastType.error);
      }
    } catch (e) {
      if (!mounted) return;
      AppToast.show("导出失败: $e", type: AppToastType.error);
    }
  }

  Future<Directory> _resolveExportDirectory() async {
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) return downloads;
    }
    if (Platform.isAndroid) {
      final external = await getExternalStorageDirectory();
      if (external != null) return external;
    }
    return getApplicationDocumentsDirectory();
  }

  Future<void> _showLargeDataPathDialog(BuildContext context) async {
    if (!Platform.isWindows) return;
    final settings = Provider.of<SettingsService>(context, listen: false);
    final library = Provider.of<LibraryService>(context, listen: false);
    final defaultPath = await settings.getDefaultLargeDataRootPath();
    String tempPath = settings.largeDataRootPath ?? defaultPath;

    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF2C2C2C),
          title: const Text("大文件数据目录", style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("当前目录", style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 6),
              Text(tempPath, style: const TextStyle(color: Colors.white)),
              const SizedBox(height: 12),
              const Text("默认目录", style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 6),
              Text(defaultPath, style: const TextStyle(color: Colors.white)),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () async {
                        final result = await FilePicker.platform
                            .getDirectoryPath();
                        if (result != null && result.isNotEmpty) {
                          setDialogState(() {
                            tempPath = result;
                          });
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF3A3A3A),
                        foregroundColor: Colors.white,
                      ),
                      child: const Text("选择目录"),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextButton(
                      onPressed: () {
                        setDialogState(() {
                          tempPath = defaultPath;
                        });
                      },
                      child: const Text(
                        "恢复默认",
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                "修改后会迁移媒体库视频、缩略图和字幕到新目录。",
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("取消", style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () async {
                final ok = await library.migrateLargeDataRoot(tempPath);
                if (!context.mounted) return;
                if (ok) {
                  AppToast.show("迁移完成", type: AppToastType.success);
                  Navigator.pop(context);
                } else {
                  AppToast.show("迁移失败，请检查目录权限", type: AppToastType.error);
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4F7BF5),
                foregroundColor: Colors.white,
              ),
              child: const Text("应用并迁移"),
            ),
          ],
        ),
      ),
    );
  }

  void _showCardStyleBottomSheet(
    BuildContext context,
    SettingsService settings,
  ) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        double tempFontScale = _normalizeCardTitleScale(
          settings.videoCardTitleFontSize,
        );
        double tempHeightScale = 1.0 / settings.videoCardAspectRatio;
        double tempColumnCount = settings.videoCardCrossAxisCount.toDouble();
        double tempListColumnCount = settings.mediaListCrossAxisCount
            .toDouble();
        bool tempShowThumb = settings.mediaListShowThumbnail;
        bool tempShowIndex = settings.mediaListShowIndex;
        double tempListHeight = settings.mediaListItemHeightScale;
        double tempListMainSpacing = settings.mediaListMainSpacingScale;
        double tempListCrossSpacing = settings.mediaListCrossSpacingScale;
        double tempListTitle = settings.mediaListTitleScale;
        double tempListCoverOffset = settings.mediaListCoverOffset;

        return StatefulBuilder(
          builder: (context, setSheetState) {
            final maxHeight = MediaQuery.of(context).size.height * 0.5;
            final isListMode = settings.mediaLibraryViewMode == 1;
            return ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
                children: [
                  Text(
                    isListMode ? "列表样式调整" : "卡片样式调整",
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (!isListMode) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "每行卡片数量",
                          style: TextStyle(color: Colors.white70),
                        ),
                        Text(
                          "${tempColumnCount.toInt()} 列",
                          style: const TextStyle(
                            color: Colors.blueAccent,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: tempColumnCount,
                      min: 1,
                      max: 15,
                      divisions: 14,
                      label: tempColumnCount.toInt().toString(),
                      onChanged: (val) {
                        setSheetState(() {
                          tempColumnCount = val;
                        });
                      },
                      onChangeEnd: (val) {
                        if (val.round() != settings.videoCardCrossAxisCount) {
                          settings.updateSetting(
                            'videoCardCrossAxisCount',
                            val.round(),
                          );
                        }
                      },
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "标题字号",
                          style: TextStyle(color: Colors.white70),
                        ),
                        Text(
                          "${(tempFontScale * 100).toStringAsFixed(1)}%",
                          style: const TextStyle(
                            color: Colors.blueAccent,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: tempFontScale,
                      min: _cardTitleScaleMin,
                      max: _cardTitleScaleMax,
                      divisions: 270,
                      label: "${(tempFontScale * 100).toStringAsFixed(1)}%",
                      onChanged: (val) {
                        setSheetState(() {
                          tempFontScale = val;
                        });
                        settings.updateSetting('videoCardTitleFontSize', val);
                      },
                    ),
                    Text(
                      "预览字号 ${_resolveCardTitleFontSize(_estimateGridCardWidth(context, tempColumnCount.round()), tempFontScale).toStringAsFixed(1)}",
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "卡片高度",
                          style: TextStyle(color: Colors.white70),
                        ),
                        Text(
                          tempHeightScale.toStringAsFixed(2),
                          style: const TextStyle(
                            color: Colors.blueAccent,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: tempHeightScale.clamp(0.8, 2.0),
                      min: 0.8,
                      max: 2.0,
                      divisions: 240,
                      label: tempHeightScale.toStringAsFixed(2),
                      onChanged: (val) {
                        setSheetState(() {
                          tempHeightScale = val;
                        });
                        settings.updateSetting(
                          'videoCardAspectRatio',
                          1.0 / val,
                        );
                      },
                    ),
                  ] else ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "每行数量",
                          style: TextStyle(color: Colors.white70),
                        ),
                        Text(
                          "${tempListColumnCount.toInt()} 列",
                          style: const TextStyle(color: Colors.blueAccent),
                        ),
                      ],
                    ),
                    Slider(
                      value: tempListColumnCount,
                      min: 1,
                      max: 15,
                      divisions: 14,
                      onChanged: (val) {
                        setSheetState(() => tempListColumnCount = val);
                        settings.updateSetting(
                          'mediaListCrossAxisCount',
                          val.round(),
                        );
                      },
                    ),
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: tempShowThumb,
                      activeThumbColor: Colors.blueAccent,
                      title: const Text(
                        "显示缩略图",
                        style: TextStyle(color: Colors.white70),
                      ),
                      onChanged: (v) {
                        setSheetState(() => tempShowThumb = v);
                        settings.updateSetting('mediaListShowThumbnail', v);
                      },
                    ),
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: tempShowIndex,
                      activeThumbColor: Colors.blueAccent,
                      title: const Text(
                        "显示序号",
                        style: TextStyle(color: Colors.white70),
                      ),
                      onChanged: (v) {
                        setSheetState(() => tempShowIndex = v);
                        settings.updateSetting('mediaListShowIndex', v);
                      },
                    ),
                    _buildListSliderRow(
                      title: "卡片高度",
                      valueText: tempListHeight.toStringAsFixed(3),
                      slider: Slider(
                        value: tempListHeight,
                        min: 0.0005,
                        max: 0.6,
                        divisions: 1200,
                        onChanged: (v) {
                          setSheetState(() => tempListHeight = v);
                          settings.updateSetting('mediaListItemHeightScale', v);
                        },
                      ),
                    ),
                    _buildListSliderRow(
                      title: "纵向间距",
                      valueText: tempListMainSpacing.toStringAsFixed(3),
                      slider: Slider(
                        value: tempListMainSpacing,
                        min: 0.0,
                        max: 0.1,
                        divisions: 200,
                        onChanged: (v) {
                          setSheetState(() => tempListMainSpacing = v);
                          settings.updateSetting(
                            'mediaListMainSpacingScale',
                            v,
                          );
                        },
                      ),
                    ),
                    _buildListSliderRow(
                      title: "横向间距",
                      valueText: tempListCrossSpacing.toStringAsFixed(3),
                      slider: Slider(
                        value: tempListCrossSpacing,
                        min: 0.0,
                        max: 0.1,
                        divisions: 200,
                        onChanged: (v) {
                          setSheetState(() => tempListCrossSpacing = v);
                          settings.updateSetting(
                            'mediaListCrossSpacingScale',
                            v,
                          );
                        },
                      ),
                    ),
                    _buildListSliderRow(
                      title: "标题字号",
                      valueText: tempListTitle.toStringAsFixed(3),
                      slider: Slider(
                        value: tempListTitle,
                        min: 0.0005,
                        max: 0.2,
                        divisions: 1600,
                        onChanged: (v) {
                          setSheetState(() => tempListTitle = v);
                          settings.updateSetting('mediaListTitleScale', v);
                        },
                      ),
                    ),
                    _buildListSliderRow(
                      title: "封面水平偏移",
                      valueText: tempListCoverOffset.toStringAsFixed(2),
                      slider: Slider(
                        value: tempListCoverOffset,
                        min: -1.0,
                        max: 1.0,
                        divisions: 200,
                        onChanged: (v) {
                          setSheetState(() => tempListCoverOffset = v);
                          settings.updateSetting('mediaListCoverOffset', v);
                        },
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildListSliderRow({
    required String title,
    required String valueText,
    required Widget slider,
  }) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title, style: const TextStyle(color: Colors.white70)),
            Text(valueText, style: const TextStyle(color: Colors.blueAccent)),
          ],
        ),
        slider,
      ],
    );
  }
}

class _BoxSelectionPainter extends CustomPainter {
  final Rect? selectionRect;

  _BoxSelectionPainter({this.selectionRect});

  @override
  void paint(Canvas canvas, Size size) {
    if (selectionRect == null) return;

    final paint = Paint()
      ..color = Colors.blueAccent.withValues(alpha: 0.1)
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = Colors.blueAccent.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    canvas.drawRect(selectionRect!, paint);
    canvas.drawRect(selectionRect!, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _BoxSelectionPainter oldDelegate) {
    return oldDelegate.selectionRect != selectionRect;
  }
}
