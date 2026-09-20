import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
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
import '../services/app_haptics.dart';
import '../models/video_collection.dart';
import '../models/video_item.dart';
import '../models/media_library_root_entry.dart';
import '../widgets/folder_drop_target.dart';
import '../widgets/cached_thumbnail_widget.dart';
import '../widgets/folder_placeholder_cover.dart';
import '../widgets/library_rename_dialog.dart';
import '../widgets/media_library_list_tile.dart';
import '../widgets/media_library_item_interaction_wrapper.dart';
import '../widgets/media_library_grid_card.dart';
import '../widgets/media_library_activity_menu.dart';
import '../widgets/media_library_action_dock.dart';
import '../widgets/media_library_layout_profile.dart';
import '../widgets/media_library_style_sheet.dart';
import '../widgets/media_list_layout_metrics.dart';
import '../widgets/media_library_settings_sheet.dart';
import '../widgets/media_library_search_prompt.dart';
import '../widgets/media_library_compact_app_bar.dart';
import '../widgets/media_library_selection_bottom_bar.dart';
import '../widgets/media_library_selection_drop_targets.dart';
import '../widgets/media_library_top_bar_import_progress.dart';
import '../widgets/media_library_locate_button.dart';
import '../widgets/media_library_folder_breadcrumb.dart';
import '../services/media_library_folder_walk.dart';
import '../services/bilibili/bilibili_download_service.dart';
import '../services/thumbnail_preload_manager.dart';
import '../widgets/mini_playback_card.dart';
import '../widgets/playback_card_layout.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'recycle_bin_screen.dart';
import '../widgets/video_action_buttons.dart';
import '../widgets/responsive_icon_button.dart';
import '../services/media_playback_service.dart';
import '../services/playback_navigation_service.dart';
import '../services/playlist_manager.dart';
import 'home_screen.dart';
import '../utils/app_toast.dart';
import '../utils/media_library_range_selection.dart';
import '../utils/android_hardware_input_bridge.dart';
import '../utils/desktop_media_management_shortcuts.dart';
import '../utils/hardware_keyboard_shortcuts.dart';
import '../widgets/sleep_timer_dialog.dart';
import '../features/portable_transfer/portable_transfer_navigation.dart';

class CollectionScreen extends StatefulWidget {
  final String collectionId;
  final String? searchQuery;
  final String? revealItemId;
  final bool returnToSearchResults;

  const CollectionScreen({
    super.key,
    required this.collectionId,
    this.revealItemId,
    this.returnToSearchResults = false,
  }) : searchQuery = null;

  const CollectionScreen.search({super.key, required String query})
    : collectionId = '',
      searchQuery = query,
      revealItemId = null,
      returnToSearchResults = false;

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen>
    with SingleTickerProviderStateMixin {
  bool _isSelectionMode = false;
  bool _showExportSettingsButton = false;
  double _stablePlaybackBottomInset = 0.0;
  final Set<String> _selectedIds = {};
  final FocusNode _shortcutFocusNode = FocusNode(
    debugLabel: 'CollectionShortcutFocus',
  );
  final AndroidHardwareKeyDeduplicator _androidKeyDeduplicator =
      AndroidHardwareKeyDeduplicator();

  // Pinch to zoom state
  int _baseCrossAxisCount = 2;

  // Selection Logic State
  // 1. Circle Drag Selection (All Platforms)
  int? _dragSelectionStartIndex;
  Set<String> _dragSelectionSnapshot = {};

  // 2. Box Selection
  bool _isBoxSelecting = false;
  Offset? _boxStartPos;
  Offset? _boxCurrentPos;
  Offset? _boxStartContentPos;
  PointerDeviceKind? _activePointerKind;

  // File Drag & Drop (Windows)
  bool _isDraggingFiles = false;

  // Track items that have been "touched" by the current box selection session
  final Set<String> _capturedIds = {};
  Offset? _lastDragSelectionGlobalPos;
  MediaLibrarySelectionAutoScroller? _selectionAutoScroller;

  // Thumbnail preloading
  late ThumbnailPreloadManager _preloadManager;
  final ScrollController _scrollController = ScrollController();
  List<VideoItem> _videoItems = [];
  Timer? _scrollPrecacheTimer;
  bool _didInitialDecodePrecache = false;
  late final AnimationController _revealHighlightController;
  Timer? _revealHighlightTimer;
  bool _didScheduleReveal = false;
  bool get _isSearchResults => widget.searchQuery != null;

  bool _includeDescendantsNow() {
    if (_isSearchResults || widget.collectionId.isEmpty) return false;
    final settings = Provider.of<SettingsService>(context, listen: false);
    return MediaLibraryFolderBrowseMemory.includeFor(
      folderId: widget.collectionId,
      lastFolderId: settings.mediaLibraryLastFolderId,
      persistedLast: settings.mediaLibraryLastFolderIncludeDescendants,
    );
  }

  bool _allowsFolderReorder() =>
      !_isSearchResults && !_includeDescendantsNow();

  bool _showParentLocate() =>
      _isSearchResults || _includeDescendantsNow();

  List<dynamic> _visibleContents(LibraryService library) {
    if (_isSearchResults) {
      return library.searchContents(widget.searchQuery!);
    }
    if (_includeDescendantsNow()) {
      return library.mediaInFolderTree(widget.collectionId);
    }
    return library.getContents(widget.collectionId);
  }

  String? _relativePathFor(LibraryService library, VideoItem item) {
    if (!_includeDescendantsNow()) return null;
    final path = library.relativeFolderPath(widget.collectionId, item.parentId);
    return path.isEmpty ? null : path;
  }

  Future<void> _toggleIncludeDescendants() async {
    if (_isSearchResults || widget.collectionId.isEmpty) return;
    final settings = Provider.of<SettingsService>(context, listen: false);
    final next = !_includeDescendantsNow();
    MediaLibraryFolderBrowseMemory.remember(widget.collectionId, next);
    if (widget.collectionId == settings.mediaLibraryLastFolderId ||
        settings.mediaLibraryLastFolderId.isEmpty) {
      await settings.updateSetting(
        'mediaLibraryLastFolderIncludeDescendants',
        next,
      );
    }
    if (mounted) setState(() {});
  }

  void _openBreadcrumbTarget(String? folderId) {
    if (folderId == widget.collectionId) return;
    final settings = Provider.of<SettingsService>(context, listen: false);
    if (folderId == null) {
      unawaited(
        settings.updateSetting(
          'mediaLibraryRootEntry',
          MediaLibraryRootEntry.folders.storageValue,
        ),
      );
      unawaited(
        settings.updateSetting('mediaLibraryRootEntryUserChosen', true),
      );
      Navigator.of(context).popUntil((route) => route.isFirst);
      return;
    }
    final current = Provider.of<LibraryService>(
      context,
      listen: false,
    ).getCollection(widget.collectionId);
    Navigator.of(context).pushReplacement(
      _buildDirectoryLocationRoute(
        CollectionScreen(
          collectionId: folderId,
          revealItemId: current?.id,
          returnToSearchResults: widget.returnToSearchResults,
        ),
      ),
    );
  }

  List<MediaLibraryBreadcrumbCrumb> _folderCrumbs(LibraryService library) {
    final trail = <MediaLibraryBreadcrumbCrumb>[];
    final visited = <String>{};
    var id = widget.collectionId;
    while (id.isNotEmpty && visited.add(id)) {
      final folder = library.getCollection(id);
      if (folder == null) break;
      trail.add(
        MediaLibraryBreadcrumbCrumb(folderId: folder.id, label: folder.name),
      );
      id = folder.parentId ?? '';
    }
    return [
      const MediaLibraryBreadcrumbCrumb(folderId: null, label: '媒体库'),
      ...trail.reversed,
    ];
  }

  Future<void> _openSearch() async {
    final query = await showMediaLibrarySearchPrompt(context);
    if (!mounted || query == null) return;
    await Navigator.of(context).push(
      buildMediaLibrarySearchResultsRoute(
        CollectionScreen.search(query: query),
      ),
    );
    if (mounted && _supportsManagementKeyboardShortcuts) {
      _shortcutFocusNode.requestFocus();
    }
  }

  void _openPortableTransfer() {
    unawaited(PortableTransferNavigation.open(context));
  }

  Route<void> _buildDirectoryLocationRoute(Widget page) {
    return PageRouteBuilder<void>(
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionDuration: const Duration(milliseconds: 280),
      reverseTransitionDuration: const Duration(milliseconds: 240),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final eased = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: eased,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.018, 0),
              end: Offset.zero,
            ).animate(eased),
            child: child,
          ),
        );
      },
    );
  }

  void _showInParentDirectory(dynamic item) {
    final itemId = (item as dynamic).id as String;
    final parentId = (item as dynamic).parentId as String?;
    final Widget page = parentId == null
        ? HomeScreen(revealItemId: itemId, returnToSearchResults: true)
        : CollectionScreen(
            collectionId: parentId,
            revealItemId: itemId,
            returnToSearchResults: true,
          );
    Navigator.of(context).push(_buildDirectoryLocationRoute(page));
  }

  void _openParentDirectory(VideoCollection currentCollection) {
    final Widget page = currentCollection.parentId == null
        ? HomeScreen(
            revealItemId: currentCollection.id,
            returnToSearchResults: true,
          )
        : CollectionScreen(
            collectionId: currentCollection.parentId!,
            revealItemId: currentCollection.id,
            returnToSearchResults: true,
          );
    Navigator.of(context).pushReplacement(_buildDirectoryLocationRoute(page));
  }

  void _scheduleRevealIfNeeded(List<dynamic> contents) {
    final targetId = widget.revealItemId;
    if (_didScheduleReveal || targetId == null) return;
    final targetIndex = contents.indexWhere(
      (item) => (item as dynamic).id == targetId,
    );
    if (targetIndex < 0) return;
    _didScheduleReveal = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final targetRect = _getItemRect(targetIndex);
      if (targetRect == null) return;

      final position = _scrollController.position;
      final viewportTop = position.pixels;
      final viewportBottom = viewportTop + position.viewportDimension;
      final isFullyVisible =
          targetRect.top >= viewportTop && targetRect.bottom <= viewportBottom;

      if (!isFullyVisible) {
        final desiredOffset =
            targetRect.center.dy - position.viewportDimension / 2;
        final targetOffset = desiredOffset.clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        final distance = (targetOffset - position.pixels).abs();
        final durationMs = (280 + distance * 0.22).round().clamp(280, 620);
        unawaited(
          _scrollController.animateTo(
            targetOffset,
            duration: Duration(milliseconds: durationMs),
            curve: Curves.easeOutCubic,
          ),
        );
      }

      _revealHighlightController.forward(from: 0);
      _revealHighlightTimer?.cancel();
      _revealHighlightTimer = Timer(const Duration(milliseconds: 1700), () {
        if (mounted) _revealHighlightController.reverse();
      });
    });
  }

  Widget _buildRevealHighlight(String itemId, Widget child) {
    if (widget.revealItemId != itemId) return child;
    return AnimatedBuilder(
      animation: _revealHighlightController,
      child: child,
      builder: (context, highlightedChild) {
        final value = Curves.easeOut.transform(
          _revealHighlightController.value,
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            highlightedChild!,
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(
                    0xFF6EA8FF,
                  ).withValues(alpha: 0.09 * value),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(
                      0xFF8DBBFF,
                    ).withValues(alpha: 0.72 * value),
                    width: 1 + value,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  List<Widget> _buildCompactTopBarActions(SettingsService settings) {
    if (_isSelectionMode) {
      return [
        MediaLibraryCompactIconButton(
          icon: Icons.select_all,
          tooltip: _managementTooltip(
            '全选',
            DesktopMediaManagementShortcutAction.toggleSelectAll,
          ),
          onPressed: _toggleSelectAllInCollection,
        ),
        const SizedBox(width: 2),
      ];
    }

    return [
      if (widget.returnToSearchResults)
        MediaLibraryCompactIconButton(
          icon: Icons.drive_folder_upload_outlined,
          tooltip: '上一级目录',
          onPressed: () {
            final library = Provider.of<LibraryService>(context, listen: false);
            final current = library.getCollection(widget.collectionId);
            if (current != null) _openParentDirectory(current);
          },
        ),
      MediaLibraryCompactIconButton(
        icon: Icons.search_rounded,
        tooltip: _managementTooltip(
          '搜索媒体库',
          DesktopMediaManagementShortcutAction.openSearch,
        ),
        onPressed: _openSearch,
      ),
      MediaLibraryCompactIconButton(
        icon: Icons.delete_outline,
        tooltip: _managementTooltip(
          '回收站',
          DesktopMediaManagementShortcutAction.openRecycleBin,
        ),
        onLongPress: _toggleExportButtonVisibility,
        onPressed: () {
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const RecycleBinScreen()));
        },
      ),
      SizedBox(
        width: 40,
        height: 48,
        child: MediaLibraryCompactMoreButton(
          itemBuilder: (menuContext) => [
            if (!_isSearchResults)
              mediaLibraryCompactMenuItem(
                icon: _includeDescendantsNow()
                    ? Icons.account_tree
                    : Icons.account_tree_outlined,
                label: _includeDescendantsNow()
                    ? '仅显示当前目录'
                    : '包含子文件夹内容',
                onSelected: () {
                  unawaited(_toggleIncludeDescendants());
                },
              ),
            mediaLibraryCompactMenuItem(
              icon: settings.mediaLibraryViewMode == 0
                  ? Icons.view_list_rounded
                  : Icons.grid_view_rounded,
              label: settings.mediaLibraryViewMode == 0 ? '切换列表视图' : '切换卡片视图',
              onSelected: () {
                final nextMode = settings.mediaLibraryViewMode == 0 ? 1 : 0;
                settings.updateSetting('mediaLibraryViewMode', nextMode);
              },
            ),
            if (_showExportSettingsButton)
              mediaLibraryCompactMenuItem(
                icon: Icons.file_download,
                label: _managementTooltip(
                  '导出设置',
                  DesktopMediaManagementShortcutAction.exportSettings,
                ),
                onSelected: _exportSettingsSnapshot,
              ),
            mediaLibraryCompactMenuItem(
              icon: Icons.swap_vert_circle_outlined,
              label: _managementTooltip(
                '导入与导出',
                DesktopMediaManagementShortcutAction.exportFluentPack,
              ),
              onSelected: _openPortableTransfer,
            ),
            mediaLibraryCompactMenuItem(
              icon: Icons.tune,
              label: _managementTooltip(
                '调整卡片样式',
                DesktopMediaManagementShortcutAction.openCardStyle,
              ),
              onSelected: () => _openCardStyleSheet(),
            ),
            mediaLibraryCompactMenuItem(
              icon: Icons.settings_outlined,
              label: _managementTooltip(
                '媒体库设置',
                DesktopMediaManagementShortcutAction.openLibrarySettings,
              ),
              onSelected: () =>
                  showMediaLibrarySettingsBottomSheet(context, settings),
            ),
            mediaLibraryCompactMenuItem(
              icon: Icons.checklist,
              label: _managementTooltip(
                '批量管理',
                DesktopMediaManagementShortcutAction.enterSelectionMode,
              ),
              onSelected: () {
                if (!mounted) return;
                setState(() => _isSelectionMode = true);
              },
            ),
          ],
        ),
      ),
      const SizedBox(width: 2),
    ];
  }

  static const double _mediaCardCoverAspectRatio = 16 / 9;

  double _resolveCardTitleFontSize(double cardWidth, double settingValue) {
    return MediaLibraryLayoutDefaults.titleFontSize(cardWidth, settingValue);
  }

  double _resolveCardMetaFontSize(double titleFontSize) {
    return MediaLibraryLayoutDefaults.metaFontSize(titleFontSize);
  }

  /// Portrait and landscape styles are stored separately for this collection.
  void _openCardStyleSheet() {
    unawaited(
      MediaLibraryStyleSheet.show(
        context: context,
        scope: MediaLibraryCardStyleScope.collection,
      ),
    );
  }

  MediaCardStyleSettings _collectionCardStyle() {
    return Provider.of<SettingsService>(
      context,
      listen: false,
    ).collectionCardStyleFor(MediaQuery.sizeOf(context));
  }

  MediaListStyleSettings _listStyle() {
    return Provider.of<SettingsService>(
      context,
      listen: false,
    ).listStyleFor(MediaQuery.sizeOf(context));
  }

  Duration get _mediaCardLongPressDelay {
    if (Platform.isWindows || Platform.isMacOS) {
      return const Duration(milliseconds: 320);
    }
    return const Duration(milliseconds: 160);
  }

  void _resetSelectionInteractionState() {
    _stopSelectionAutoScroll();
    _isBoxSelecting = false;
    _boxStartPos = null;
    _boxCurrentPos = null;
    _boxStartContentPos = null;
    _capturedIds.clear();
    _dragSelectionStartIndex = null;
    _dragSelectionSnapshot.clear();
    _lastDragSelectionGlobalPos = null;
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

  List<String> _idsForSelectionDrop({int? draggedIndex}) {
    final library = Provider.of<LibraryService>(context, listen: false);
    return resolveMediaLibrarySelectionDropIds(
      contents: _visibleContents(library),
      selectedIds: _selectedIds,
      draggedIndex: draggedIndex,
    );
  }

  Future<void> _moveItemsToParentCollection(
    LibraryService library,
    VideoCollection collection, {
    int? draggedIndex,
  }) async {
    final itemsToMove = _idsForSelectionDrop(draggedIndex: draggedIndex);
    if (itemsToMove.isEmpty) return;

    await library.moveItemsToCollection(itemsToMove, collection.parentId);
    await _syncSelectionAfterMove(
      library,
      currentParentId: widget.collectionId,
      attemptedItemIds: itemsToMove,
    );
    AppToast.show("已移出 ${itemsToMove.length} 个项目", type: AppToastType.success);
  }

  Future<void> _moveItemsToRecycleBin({int? draggedIndex}) async {
    final itemsToMove = _idsForSelectionDrop(draggedIndex: draggedIndex);
    if (itemsToMove.isEmpty) return;

    final library = Provider.of<LibraryService>(context, listen: false);
    await library.moveToRecycleBin(itemsToMove);
    await _syncSelectionAfterMove(
      library,
      currentParentId: widget.collectionId,
      attemptedItemIds: itemsToMove,
    );
    AppToast.show("已移入回收站", type: AppToastType.success);
  }

  Widget _scaledThumbnailIcon({
    required double extent,
    required IconData icon,
    Color color = Colors.white24,
  }) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Icon(
          icon,
          size: MediaListLayoutMetrics.cardGridThumbnailIconSize(extent),
          color: color,
        ),
      ),
    );
  }

  /// Helper: Get total item count safely
  int _getItemCount() {
    final library = Provider.of<LibraryService>(context, listen: false);
    return _visibleContents(library).length;
  }

  /// Helper: Get content ID at index
  String? _getItemId(int index) {
    final library = Provider.of<LibraryService>(context, listen: false);
    final contents = _visibleContents(library);
    if (index < 0 || index >= contents.length) return null;
    return (contents[index] as dynamic).id;
  }

  /// Helper: Check if a point (relative to scrollable content) is inside an item
  /// Returns the index of the item, or null if in spacing/padding
  int? _getIndexAt(Offset contentOffset) {
    final settings = Provider.of<SettingsService>(context, listen: false);
    final count = _getItemCount();
    return _getMediaGridGeometry(settings).indexAt(contentOffset, count);
  }

  /// Helper: Get the Rect of an item at [index] relative to the scrollable content area
  Rect? _getItemRect(int index) {
    final settings = Provider.of<SettingsService>(context, listen: false);
    final count = _getItemCount();
    if (index < 0 || index >= count) return null;
    return _getMediaGridGeometry(settings).rectForIndex(index);
  }

  MediaLibraryGridGeometry _getMediaGridGeometry(SettingsService settings) {
    final mediaSize = MediaQuery.sizeOf(context);
    if (settings.mediaLibraryViewMode == 1) {
      final listStyle = settings.listStyleFor(mediaSize);
      final metrics = MediaListLayoutMetrics.forGrid(
        screenShortestSide: mediaSize.shortestSide,
        availableWidth: mediaSize.width,
        crossAxisCount: listStyle.crossAxisCount,
        heightSetting: listStyle.heightScale,
        titleSetting: listStyle.titleScale,
        mainSpacingSetting: listStyle.mainSpacingScale,
        crossSpacingSetting: listStyle.crossSpacingScale,
      );
      return MediaLibraryGridGeometry(
        crossAxisCount: listStyle.crossAxisCount,
        itemWidth: metrics.cellWidth,
        itemHeight: metrics.rowHeight,
        horizontalSpacing: metrics.crossSpacing,
        verticalSpacing: metrics.mainSpacing,
        horizontalPadding: metrics.outerPadding,
        topPadding: metrics.topPadding,
      );
    }

    final metrics = MediaLibraryLayoutDefaults.cardGrid(
      screenSize: mediaSize,
      style: settings.collectionCardStyleFor(mediaSize),
    );
    return MediaLibraryGridGeometry(
      crossAxisCount: metrics.crossAxisCount,
      itemWidth: metrics.cellWidth,
      itemHeight: metrics.cellHeight,
      horizontalSpacing: metrics.crossSpacing,
      verticalSpacing: metrics.mainSpacing,
      horizontalPadding: metrics.outerPadding,
      topPadding: metrics.topPadding,
    );
  }

  /// Handle checkbox drag: select a contiguous reading-order range.
  void _updateDragSelection(Offset globalPos) {
    _lastDragSelectionGlobalPos = globalPos;
    _applyDragSelectionAt(globalPos);
    _syncSelectionAutoScroll(globalPos);
  }

  Offset? _contentOffsetFromGlobal(Offset globalPos) {
    if (!_scrollController.hasClients) return null;
    final scrollContext =
        _scrollController.position.context.notificationContext;
    final box = scrollContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final local = box.globalToLocal(globalPos);
    return Offset(local.dx, local.dy + _scrollController.offset);
  }

  ({double top, double bottom})? _selectionViewportGlobalY() {
    if (!_scrollController.hasClients) return null;
    final scrollContext =
        _scrollController.position.context.notificationContext;
    final box = scrollContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final top = box.localToGlobal(Offset.zero).dy;
    var bottom = top + box.size.height;
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    if (playbackService.shouldShowMiniPlaybackCard) {
      final cardHeight = PlaybackCardLayout.calculate(context).height;
      final cardBottom = PlaybackCardOverlayLayout.cardBottom(
        _stablePlaybackBottomInset,
      );
      bottom -= MediaLibraryRangeSelection.miniPlayerOverlayHeight(
        visible: true,
        cardHeight: cardHeight,
        cardBottomInset: cardBottom,
      );
    }
    return (top: top, bottom: bottom);
  }

  void _applyDragSelectionAt(Offset globalPos) {
    final startIndex = _dragSelectionStartIndex;
    if (startIndex == null) return;
    final contentOffset = _contentOffsetFromGlobal(globalPos);
    if (contentOffset == null) return;

    final settings = Provider.of<SettingsService>(context, listen: false);
    final count = _getItemCount();
    final currentIndex = _getMediaGridGeometry(
      settings,
    ).indexForDragSelection(contentOffset, count);
    if (currentIndex == null) return;

    final newSelection = MediaLibraryRangeSelection.mergeSnapshotWithIndexRange(
      snapshot: _dragSelectionSnapshot,
      startIndex: startIndex,
      currentIndex: currentIndex,
      itemCount: count,
      idAt: _getItemId,
    );

    if (newSelection.length != _selectedIds.length ||
        !_selectedIds.containsAll(newSelection)) {
      setState(() {
        _selectedIds
          ..clear()
          ..addAll(newSelection);
      });
      unawaited(AppHaptics.selectionClick(settings));
    }
  }

  MediaLibrarySelectionAutoScroller _ensureSelectionAutoScroller() {
    return _selectionAutoScroller ??= MediaLibrarySelectionAutoScroller(
      scrollController: _scrollController,
      onScrolled: () {
        final pos = _lastDragSelectionGlobalPos;
        if (pos == null) return;
        if (_dragSelectionStartIndex != null) {
          _applyDragSelectionAt(pos);
        } else if (_isBoxSelecting) {
          _applyMouseBoxSelectionAt(pos);
        }
      },
    );
  }

  void _syncSelectionAutoScroll(Offset globalPos) {
    if (_dragSelectionStartIndex == null && !_isBoxSelecting) {
      _stopSelectionAutoScroll();
      return;
    }
    final bounds = _selectionViewportGlobalY();
    if (bounds == null) {
      _stopSelectionAutoScroll();
      return;
    }
    _ensureSelectionAutoScroller().update(
      pointerY: globalPos.dy,
      viewportTop: bounds.top,
      viewportBottom: bounds.bottom,
    );
  }

  void _stopSelectionAutoScroll() {
    _selectionAutoScroller?.stop();
  }

  bool _tryStartMouseBoxSelection({
    required int pointerCount,
    required Offset globalPos,
  }) {
    if (!MediaLibraryRangeSelection.isMouseBoxGesture(
      pointerKind: _activePointerKind,
      pointerCount: pointerCount,
    )) {
      return false;
    }
    final contentOffset = _contentOffsetFromGlobal(globalPos);
    if (contentOffset == null || _getIndexAt(contentOffset) != null) {
      return false;
    }
    _isBoxSelecting = true;
    _boxStartContentPos = contentOffset;
    _lastDragSelectionGlobalPos = globalPos;
    _capturedIds.clear();
    _dragSelectionSnapshot = _isSelectionMode
        ? Set<String>.from(_selectedIds)
        : <String>{};
    _applyMouseBoxSelectionAt(globalPos);
    _syncSelectionAutoScroll(globalPos);
    return true;
  }

  void _applyMouseBoxSelectionAt(Offset globalPos) {
    if (!_isBoxSelecting || _boxStartContentPos == null) return;
    _lastDragSelectionGlobalPos = globalPos;
    final currentContent = _contentOffsetFromGlobal(globalPos);
    if (currentContent == null) return;
    final scroll = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;
    final settings = Provider.of<SettingsService>(context, listen: false);
    final geometry = _getMediaGridGeometry(settings);
    final contentRect = Rect.fromPoints(_boxStartContentPos!, currentContent);
    final currentInBox = <String>{};
    for (final index in geometry.indicesOverlapping(
      contentRect,
      _getItemCount(),
    )) {
      final id = _getItemId(index);
      if (id != null) currentInBox.add(id);
    }

    setState(() {
      _boxStartPos = _boxStartContentPos! - Offset(0, scroll);
      _boxCurrentPos = currentContent - Offset(0, scroll);
      if (!_isSelectionMode) return;
      _capturedIds.addAll(currentInBox);
      final newSelection = <String>{};
      for (final id in _dragSelectionSnapshot) {
        if (!_capturedIds.contains(id)) newSelection.add(id);
      }
      newSelection.addAll(currentInBox);
      if (newSelection.length != _selectedIds.length ||
          !_selectedIds.containsAll(newSelection)) {
        _selectedIds
          ..clear()
          ..addAll(newSelection);
        unawaited(AppHaptics.selectionClick(settings));
      }
    });
  }

  void _finishMouseBoxSelection() {
    _stopSelectionAutoScroll();
    if (!_isSelectionMode &&
        _boxStartContentPos != null &&
        _lastDragSelectionGlobalPos != null) {
      final currentContent = _contentOffsetFromGlobal(
        _lastDragSelectionGlobalPos!,
      );
      if (currentContent != null) {
        final settings = Provider.of<SettingsService>(context, listen: false);
        final geometry = _getMediaGridGeometry(settings);
        final contentRect = Rect.fromPoints(
          _boxStartContentPos!,
          currentContent,
        );
        final newSelected = <String>{};
        for (final index in geometry.indicesOverlapping(
          contentRect,
          _getItemCount(),
        )) {
          final id = _getItemId(index);
          if (id != null) newSelected.add(id);
        }
        if (newSelected.isNotEmpty) {
          setState(() {
            _isSelectionMode = true;
            _selectedIds.addAll(newSelected);
            _isBoxSelecting = false;
            _boxStartPos = null;
            _boxCurrentPos = null;
            _boxStartContentPos = null;
            _capturedIds.clear();
          });
          return;
        }
      }
    }
    setState(() {
      _isBoxSelecting = false;
      _boxStartPos = null;
      _boxCurrentPos = null;
      _boxStartContentPos = null;
      _capturedIds.clear();
    });
  }

  /// 计算播放卡片的底部填充，确保内容不被遮挡
  double _getPlaybackCardBottomPadding() {
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    final isVisible = playbackService.shouldShowMiniPlaybackCard;

    if (!isVisible) return 0.0;

    final stableBottomInset =
        PlaybackCardOverlayLayout.resolveStableBottomInset(
          MediaQuery.of(context),
          _stablePlaybackBottomInset,
        );
    return PlaybackCardOverlayLayout.cardBottom(stableBottomInset) +
        PlaybackCardLayout.calculate(context).height;
  }

  Route<void> _buildVideoPlayerRoute(
    VideoItem item,
    VideoPlayerController? existingController,
  ) {
    // 桌面端或开启"跳过竖屏播放页"时直入横屏播放页，否则进入竖屏播放页
    return PlaybackNavigationService.buildPlaybackEntryRoute(
      item,
      existingController: existingController,
    );
  }

  void _preparePlaybackQueue(VideoItem item) {
    if (!mounted) return;
    final playlistManager = Provider.of<PlaylistManager>(
      context,
      listen: false,
    );
    // Search is only a locator. The queue still follows the video's original
    // folder order, matching collection/home open behavior.
    playlistManager.prepareLibraryPlayback(item);
  }

  void _openPlaybackScreen(
    VideoItem item, {
    VideoPlayerController? existingController,
    bool useRootNavigator = false,
  }) {
    _preparePlaybackQueue(item);
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    PlaybackNavigationService.instance.primeLibraryPlaybackEntry(
      playbackService: playbackService,
      item: item,
      existingController: existingController,
    );
    final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
    navigator.push(_buildVideoPlayerRoute(item, existingController));
  }

  @override
  void initState() {
    super.initState();
    AndroidHardwareInputBridge.addKeyListener(_handleAndroidHardwareKeyEvent);
    HardwareKeyboard.instance.addHandler(_handleGlobalHardwareKeyEvent);
    _revealHighlightController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
      reverseDuration: const Duration(milliseconds: 560),
    );
    _preloadManager = ThumbnailPreloadManager();
    _scrollController.addListener(_onScroll);
    _startInitialPreload();
    _loadExportButtonPreference();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.searchQuery != null) return;
      final settings = Provider.of<SettingsService>(context, listen: false);
      unawaited(
        settings.updateSetting(
          'mediaLibraryLastFolderId',
          widget.collectionId,
        ),
      );
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startInitialDecodePrecache();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_supportsManagementKeyboardShortcuts && mounted) {
        _shortcutFocusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    AndroidHardwareInputBridge.removeKeyListener(
      _handleAndroidHardwareKeyEvent,
    );
    HardwareKeyboard.instance.removeHandler(_handleGlobalHardwareKeyEvent);
    _preloadManager.cancelAll();
    _scrollPrecacheTimer?.cancel();
    _revealHighlightTimer?.cancel();
    _revealHighlightController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _shortcutFocusNode.dispose();
    _selectionAutoScroller?.dispose();
    super.dispose();
  }

  bool get _supportsManagementKeyboardShortcuts {
    return supportsNativeHardwareKeyboardShortcuts;
  }

  bool get _isDesktopPlatform {
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
    final platform = currentNativeTargetPlatform;
    if (platform == null ||
        !supportsPlayerPointerHoverOn(platform) ||
        !DesktopMediaManagementShortcuts.isAvailableOnPlatform(
          action,
          platform,
        )) {
      return label;
    }
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
    final contents = _visibleContents(library);
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
    final library = Provider.of<LibraryService>(context, listen: false);
    switch (action) {
      case DesktopMediaManagementShortcutAction.backOrExitSelection:
        if (_isSelectionMode) {
          _exitSelectionMode();
        } else {
          Navigator.of(context).maybePop();
        }
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.toggleViewMode:
        final nextMode = settings.mediaLibraryViewMode == 0 ? 1 : 0;
        settings.updateSetting('mediaLibraryViewMode', nextMode);
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.toggleFullScreen:
        if (!_isDesktopPlatform) {
          return KeyEventResult.ignored;
        }
        settings.toggleFullScreen();
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openLargeDataDirectory:
        if (_isSelectionMode || !Platform.isWindows) {
          return KeyEventResult.handled;
        }
        _showLargeDataPathDialog(context);
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.exportSettings:
        if (_isSelectionMode || !_showExportSettingsButton) {
          return KeyEventResult.handled;
        }
        _exportSettingsSnapshot();
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openRecycleBin:
        if (_isSelectionMode) {
          unawaited(_moveItemsToRecycleBin());
          return KeyEventResult.handled;
        }
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const RecycleBinScreen()));
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openCardStyle:
        if (_isSelectionMode) return KeyEventResult.handled;
        _openCardStyleSheet();
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.enterSelectionMode:
        if (_isSelectionMode) return KeyEventResult.handled;
        setState(() {
          _isSelectionMode = true;
        });
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.toggleSelectAll:
        if (!_isSelectionMode) return KeyEventResult.handled;
        _toggleSelectAllInCollection();
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openSearch:
        if (_isSelectionMode) return KeyEventResult.handled;
        unawaited(_openSearch());
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openLibrarySettings:
        if (_isSelectionMode) return KeyEventResult.handled;
        showMediaLibrarySettingsBottomSheet(context, settings);
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openSleepTimer:
        unawaited(showSleepTimerDialog(context));
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.createCollection:
        if (_isSelectionMode) {
          if (_selectedIds.length == 1) {
            final id = _selectedIds.first;
            final name =
                library.getCollection(id)?.name ??
                library.getVideo(id)?.title ??
                '';
            _showRenameDialog(context, id, name);
          }
          return KeyEventResult.handled;
        }
        VideoActionButtons.openCreateCollectionDialog(
          context,
          widget.collectionId,
        );
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.importMedia:
        if (_isSelectionMode) return KeyEventResult.handled;
        unawaited(
          VideoActionButtons.showImportMenu(context, widget.collectionId),
        );
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openBilibiliDownload:
        if (_isSelectionMode) return KeyEventResult.handled;
        VideoActionButtons.openBilibiliDownloadPage(
          context,
          collectionId: widget.collectionId,
        );
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openYtDlpDownload:
        if (_isSelectionMode) return KeyEventResult.handled;
        VideoActionButtons.openYtDlpDownloadPage(context);
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openBatchSubtitle:
        if (_isSelectionMode) return KeyEventResult.handled;
        VideoActionButtons.openBatchSubtitlePage(
          context,
          collectionId: widget.collectionId,
        );
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openBatchImport:
        if (_isSelectionMode) return KeyEventResult.handled;
        VideoActionButtons.openBatchImportPage(
          context,
          collectionId: widget.collectionId,
        );
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.moveToParent:
        if (!_isSelectionMode || _isSearchResults) {
          return KeyEventResult.handled;
        }
        final collection = library.getCollection(widget.collectionId);
        if (collection == null) return KeyEventResult.handled;
        unawaited(_moveItemsToParentCollection(library, collection));
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.exportFluentPack:
        // Same letter as the toolbar button: browse mode opens the page,
        // selection mode exports the current pick as FluentPack.
        if (!_isSelectionMode) {
          _openPortableTransfer();
          return KeyEventResult.handled;
        }
        if (_selectedIds.isEmpty) {
          return KeyEventResult.handled;
        }
        final ids = _selectedIds.toList();
        setState(() {
          _selectedIds.clear();
          _isSelectionMode = false;
        });
        unawaited(
          PortableTransferNavigation.openExportSettings(context, ids),
        );
        return KeyEventResult.handled;
    }
  }

  bool _handleGlobalHardwareKeyEvent(KeyEvent event) {
    if (_shortcutFocusNode.hasFocus) return false;
    return _handleShortcutKeyEvent(event) != KeyEventResult.ignored;
  }

  void _handleAndroidHardwareKeyEvent(AndroidHardwareKeyMessage message) {
    _handleShortcutKeyEvent(
      message.toKeyEvent(),
      fromAndroidNativeBridge: true,
      hasBlockingModifierOverride: message.hasBlockingModifier,
    );
  }

  KeyEventResult _handleShortcutKeyEvent(
    KeyEvent event, {
    bool fromAndroidNativeBridge = false,
    bool? hasBlockingModifierOverride,
  }) {
    if (!_supportsManagementKeyboardShortcuts) return KeyEventResult.ignored;
    // 当视频播放页或其他子页面活跃时，不处理键盘事件，避免与播放器快捷键冲突
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return KeyEventResult.ignored;
    if (Platform.isAndroid &&
        !_androidKeyDeduplicator.shouldDispatch(
          event,
          fromNativeBridge: fromAndroidNativeBridge,
        )) {
      return KeyEventResult.handled;
    }
    if (_isTextInputFocused()) {
      return KeyEventResult.ignored;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    final bool hasBlockingModifier =
        hasBlockingModifierOverride ??
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isAltPressed ||
            HardwareKeyboard.instance.isMetaPressed);
    if (hasBlockingModifier) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final DesktopMediaManagementShortcutAction? managementAction =
        DesktopMediaManagementShortcuts.matchAction(key);
    final platform = currentNativeTargetPlatform;
    final bool isManagementActionAvailable =
        managementAction != null &&
        platform != null &&
        DesktopMediaManagementShortcuts.isAvailableOnPlatform(
          managementAction,
          platform,
        );
    final isTargetKey =
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.escape;
    if (!isTargetKey && !isManagementActionAvailable) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent) return KeyEventResult.handled;

    if (isManagementActionAvailable &&
        managementAction !=
            DesktopMediaManagementShortcutAction.backOrExitSelection) {
      return _handleManagementShortcut(managementAction);
    }

    if (key == LogicalKeyboardKey.escape) {
      if (isManagementActionAvailable) {
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
    final contents = _visibleContents(library);
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
    final geometry = _getMediaGridGeometry(settings);
    final crossAxisCount = geometry.crossAxisCount;
    if (crossAxisCount <= 0 || _videoItems.isEmpty) return;

    final mediaQuery = MediaQuery.of(context);
    final rowHeight = geometry.itemHeight + geometry.verticalSpacing;
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
    final geometry = _getMediaGridGeometry(settings);

    startIndex = startIndex.clamp(0, _videoItems.length);
    endIndex = endIndex.clamp(0, _videoItems.length);
    if (startIndex >= endIndex) return;

    final mediaQuery = MediaQuery.of(context);
    final tileMetrics = MediaListLayoutMetrics.forTile(
      screenShortestSide: mediaQuery.size.shortestSide,
      cellWidth: geometry.itemWidth,
      rowHeight: geometry.itemHeight,
      titleSetting: settings.listStyleFor(mediaQuery.size).titleScale,
    );
    final thumbWidth = settings.mediaLibraryViewMode == 1
        ? tileMetrics.thumbnailExtent(geometry.itemWidth)
        : geometry.itemWidth;
    final thumbHeight = settings.mediaLibraryViewMode == 1
        ? thumbWidth
        : thumbWidth * 3 / 4;
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
    final geometry = _getMediaGridGeometry(settings);
    final crossAxisCount = geometry.crossAxisCount;

    // 估算当前滚动位置对应的索引
    final scrollOffset = _scrollController.offset;
    final rowHeight = geometry.itemHeight + geometry.verticalSpacing;

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

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsService>(context);
    final useCompactTopBar = useCompactMediaLibraryTopBar(context);
    _stablePlaybackBottomInset =
        PlaybackCardOverlayLayout.resolveStableBottomInset(
          MediaQuery.of(context),
          _stablePlaybackBottomInset,
        );
    final playbackCardBottom = PlaybackCardOverlayLayout.cardBottom(
      _stablePlaybackBottomInset,
    );

    return Consumer<LibraryService>(
      builder: (context, library, child) {
        final collection = _isSearchResults
            ? VideoCollection(
                id: '',
                name: '搜索：“${widget.searchQuery}”',
                createTime: 0,
              )
            : library.getCollection(widget.collectionId) ??
                  VideoCollection(id: '', name: '未知合集', createTime: 0);

        final contents = _visibleContents(library);
        _scheduleRevealIfNeeded(contents);
        final baseTheme = Theme.of(context);

        return Theme(
          data: _isSearchResults
              ? baseTheme.copyWith(
                  textTheme: baseTheme.textTheme.apply(
                    fontFamily: 'Noto Sans SC',
                  ),
                  primaryTextTheme: baseTheme.primaryTextTheme.apply(
                    fontFamily: 'Noto Sans SC',
                  ),
                )
              : baseTheme,
          child: PopScope(
            canPop: !_isSelectionMode,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop) return;
              _exitSelectionMode();
            },
            child: Scaffold(
              backgroundColor: const Color(0xFF121212),
              extendBody: true,
              // Only the search prompt follows the Android keyboard. The
              // folder/search-result grid stays at its original dimensions
              // underneath the IME to avoid a full card-grid relayout.
              resizeToAvoidBottomInset: false,
              appBar: AppBar(
                clipBehavior: Clip.hardEdge,
                toolbarHeight: useCompactTopBar ? 50 : kToolbarHeight,
                leadingWidth: useCompactTopBar ? 40 : 44,
                titleSpacing: useCompactTopBar ? 3 : 8,
                title: _isSelectionMode
                    ? (_isSearchResults
                          ? (useCompactTopBar
                                ? MediaLibraryCompactTitle(
                                    text: '已选择 ${_selectedIds.length} 项',
                                  )
                                : Text('已选择 ${_selectedIds.length} 项'))
                          : MediaLibrarySelectionDropTargets(
                              showMoveToParent: true,
                              hasSelectedItems: _selectedIds.isNotEmpty,
                              onMoveToParent: (draggedIndex) {
                                unawaited(
                                  _moveItemsToParentCollection(
                                    library,
                                    collection,
                                    draggedIndex: draggedIndex,
                                  ),
                                );
                              },
                              onMoveToRecycleBin: (draggedIndex) {
                                unawaited(
                                  _moveItemsToRecycleBin(
                                    draggedIndex: draggedIndex,
                                  ),
                                );
                              },
                            ))
                    : useCompactTopBar
                    ? (_isSearchResults
                          ? MediaLibraryCompactTitle(text: collection.name)
                          : MediaLibraryFolderBreadcrumb(
                              crumbs: _folderCrumbs(library),
                              compact: true,
                              onSelected: _openBreadcrumbTarget,
                            ))
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
                              final nextMode =
                                  settings.mediaLibraryViewMode == 0 ? 1 : 0;
                              settings.updateSetting(
                                'mediaLibraryViewMode',
                                nextMode,
                              );
                            },
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: _isSearchResults
                                      ? MediaLibraryCompactTitle(
                                          text: collection.name,
                                        )
                                      : MediaLibraryFolderBreadcrumb(
                                          crumbs: _folderCrumbs(library),
                                          onSelected: _openBreadcrumbTarget,
                                        ),
                                ),
                                if (!_isSearchResults)
                                  ValueListenableBuilder<bool>(
                                    valueListenable: library.isImporting,
                                    builder: (context, isImporting, _) {
                                      if (!isImporting) {
                                        return const SizedBox.shrink();
                                      }
                                      return ValueListenableBuilder<String>(
                                        valueListenable: library.importStatus,
                                        builder: (context, status, _) {
                                          return Align(
                                            alignment: Alignment.centerLeft,
                                            child: Text(
                                              status,
                                              style: const TextStyle(
                                                fontSize: 10,
                                                color: Colors.white70,
                                                height: 1.0,
                                                leadingDistribution:
                                                    TextLeadingDistribution.even,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
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
                    ? (useCompactTopBar
                          ? MediaLibraryCompactIconButton(
                              icon: Icons.close,
                              tooltip: '退出选择',
                              onPressed: _exitSelectionMode,
                            )
                          : IconButton(
                              icon: const Icon(Icons.close),
                              tooltip: _managementTooltip(
                                "退出选择",
                                DesktopMediaManagementShortcutAction
                                    .backOrExitSelection,
                              ),
                              onPressed: _exitSelectionMode,
                            ))
                    : (useCompactTopBar
                          ? MediaLibraryCompactIconButton(
                              icon: Icons.arrow_back,
                              tooltip: widget.returnToSearchResults
                                  ? '返回搜索结果'
                                  : '返回上一级',
                              onPressed: () => Navigator.of(context).maybePop(),
                            )
                          : IconButton(
                              icon: const Icon(Icons.arrow_back),
                              tooltip: widget.returnToSearchResults
                                  ? '返回搜索结果'
                                  : _managementTooltip(
                                      "返回上一级",
                                      DesktopMediaManagementShortcutAction
                                          .backOrExitSelection,
                                    ),
                              onPressed: () => Navigator.of(context).maybePop(),
                            )),
                actions: useCompactTopBar
                    ? _buildCompactTopBarActions(settings)
                    : [
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
                                  onPressed: () =>
                                      _showLargeDataPathDialog(context),
                                ),
                              if (_showExportSettingsButton)
                                ResponsiveIconButton(
                                  icon: Icons.file_download,
                                  tooltip: _managementTooltip(
                                    "导出设置",
                                    DesktopMediaManagementShortcutAction
                                        .exportSettings,
                                  ),
                                  onPressed: _exportSettingsSnapshot,
                                ),
                              ResponsiveIconButton(
                                icon: Icons.swap_vert_circle_outlined,
                                tooltip: _managementTooltip(
                                  "导入与导出",
                                  DesktopMediaManagementShortcutAction
                                      .exportFluentPack,
                                ),
                                onPressed: _openPortableTransfer,
                              ),
                              if (widget.returnToSearchResults)
                                ResponsiveIconButton(
                                  icon: Icons.drive_folder_upload_outlined,
                                  tooltip: '上一级目录',
                                  onPressed: () =>
                                      _openParentDirectory(collection),
                                ),
                              if (!_isSearchResults)
                                ResponsiveIconButton(
                                  icon: _includeDescendantsNow()
                                      ? Icons.account_tree
                                      : Icons.account_tree_outlined,
                                  tooltip: _includeDescendantsNow()
                                      ? '仅显示当前目录'
                                      : '包含子文件夹内容',
                                  onPressed: () {
                                    unawaited(_toggleIncludeDescendants());
                                  },
                                ),
                              ResponsiveIconButton(
                                icon: Icons.search_rounded,
                                tooltip: _managementTooltip(
                                  '搜索媒体库',
                                  DesktopMediaManagementShortcutAction
                                      .openSearch,
                                ),
                                onPressed: _openSearch,
                              ),
                              ResponsiveIconButton(
                                icon: Icons.delete_outline,
                                tooltip: _managementTooltip(
                                  "回收站",
                                  DesktopMediaManagementShortcutAction
                                      .openRecycleBin,
                                ),
                                onLongPress: _toggleExportButtonVisibility,
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
                                  DesktopMediaManagementShortcutAction
                                      .openCardStyle,
                                ),
                                onPressed: _openCardStyleSheet,
                              ),
                              ResponsiveIconButton(
                                icon: Icons.settings_outlined,
                                tooltip: _managementTooltip(
                                  "媒体库设置",
                                  DesktopMediaManagementShortcutAction
                                      .openLibrarySettings,
                                ),
                                onPressed: () =>
                                    showMediaLibrarySettingsBottomSheet(
                                      context,
                                      settings,
                                    ),
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
                                  DesktopMediaManagementShortcutAction
                                      .toggleSelectAll,
                                ),
                                onPressed: _toggleSelectAllInCollection,
                              ),
                            ],
                          ],
                        ),
                      ],
                bottom: const MediaLibraryTopBarImportProgress(),
              ),
              body: Focus(
                focusNode: _shortcutFocusNode,
                autofocus: _supportsManagementKeyboardShortcuts,
                onKeyEvent: (node, event) => _handleShortcutKeyEvent(event),
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (_) {
                    if (_supportsManagementKeyboardShortcuts &&
                        !_shortcutFocusNode.hasFocus) {
                      _shortcutFocusNode.requestFocus();
                    }
                  },
                  child: DropTarget(
                    onDragDone: (details) {
                      if (ModalRoute.of(context)?.isCurrent != true) return;
                      if (_isSearchResults) return;
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
                      if (_isSearchResults) return;
                      setState(() => _isDraggingFiles = true);
                    },
                    onDragExited: (_) =>
                        setState(() => _isDraggingFiles = false),
                    child: Stack(
                      children: [
                        contents.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      _isSearchResults
                                          ? Icons.search_off_rounded
                                          : Icons.video_collection_outlined,
                                      size: 80,
                                      color: Colors.white24,
                                    ),
                                    const SizedBox(height: 16),
                                    Text(
                                      _isSearchResults ? "没有找到匹配项目" : "合集是空的",
                                      style: const TextStyle(
                                        color: Colors.white54,
                                      ),
                                    ),
                                    if (!_isSearchResults) ...[
                                      const SizedBox(height: 16),
                                      VideoActionButtons(
                                        collectionId: widget.collectionId,
                                        isHorizontal: true,
                                      ),
                                    ],
                                  ],
                                ),
                              )
                            : Listener(
                                onPointerDown: (event) {
                                  _activePointerKind = event.kind;
                                },
                                child: GestureDetector(
                                onScaleStart: (details) {
                                  if (_tryStartMouseBoxSelection(
                                    pointerCount: details.pointerCount,
                                    globalPos: details.focalPoint,
                                  )) {
                                    return;
                                  }
                                  _baseCrossAxisCount =
                                      settings.mediaLibraryViewMode == 1
                                      ? _listStyle().crossAxisCount
                                      : _collectionCardStyle().crossAxisCount;
                                },
                                onScaleUpdate: (details) {
                                  if (_isBoxSelecting) {
                                    _applyMouseBoxSelectionAt(details.focalPoint);
                                    _syncSelectionAutoScroll(details.focalPoint);
                                    return;
                                  }

                                  double newScale = details.scale;
                                  int newCount = _baseCrossAxisCount;

                                  if (newScale > 1.3) {
                                    newCount = (_baseCrossAxisCount - 1).clamp(
                                      1,
                                      20,
                                    );
                                  } else if (newScale < 0.7) {
                                    newCount = (_baseCrossAxisCount + 1).clamp(
                                      1,
                                      20,
                                    );
                                  }

                                  final currentCount =
                                      settings.mediaLibraryViewMode == 1
                                      ? _listStyle().crossAxisCount
                                      : _collectionCardStyle().crossAxisCount;
                                  if (newCount != currentCount) {
                                    final size = MediaQuery.sizeOf(context);
                                    if (settings.mediaLibraryViewMode == 1) {
                                      unawaited(
                                        settings.updateListStyleFor(
                                          size,
                                          crossAxisCount: newCount,
                                        ),
                                      );
                                    } else {
                                      unawaited(
                                        settings.updateCollectionCardStyleFor(
                                          size,
                                          crossAxisCount: newCount,
                                        ),
                                      );
                                    }
                                  }
                                },
                                onScaleEnd: (details) {
                                  if (_isBoxSelecting) {
                                    _finishMouseBoxSelection();
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
                            ),
                        // Fill the rest of the screen with a transparent hit target to ensure GestureDetector catches taps in empty space
                        if (contents.length <
                            20) // Only if potentially empty space at bottom
                          Positioned.fill(
                            key: MediaLibraryOverlayKeys.emptySpaceHitTarget,
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
                            _boxCurrentPos != null)
                          Positioned.fill(
                            key: MediaLibraryOverlayKeys.boxSelection,
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
                          key: MediaLibraryOverlayKeys.playbackBottomFill,
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Consumer<MediaPlaybackService>(
                            builder: (context, playbackService, child) {
                              final isVisible =
                                  playbackService.shouldShowMiniPlaybackCard;
                              if (!isVisible) return const SizedBox.shrink();
                              return Container(
                                height: playbackCardBottom,
                                color: const Color(0xFF2C2C2C),
                              );
                            },
                          ),
                        ),
                        Positioned(
                          key: MediaLibraryOverlayKeys.miniPlaybackCard,
                          left: 0,
                          right: 0,
                          bottom: playbackCardBottom,
                          child: Consumer<MediaPlaybackService>(
                            builder: (context, playbackService, child) {
                              final isVisible =
                                  playbackService.shouldShowMiniPlaybackCard;

                              return MiniPlaybackCard(
                                isVisible: isVisible,
                                onTap: () async {
                                  final currentItem =
                                      playbackService.currentItem;
                                  if (currentItem == null) return;
                                  if (playbackService.controller == null &&
                                      !playbackService.isSourceMissing) {
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

                                  Navigator.of(
                                    context,
                                    rootNavigator: true,
                                  ).push(
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
                        if (_isDraggingFiles && !_isSearchResults)
                          Positioned.fill(
                            key: MediaLibraryOverlayKeys.fileDrop,
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
              floatingActionButtonLocation:
                  const PlaybackActionButtonsLocation(),
              floatingActionButton: !_isSelectionMode && !_isSearchResults
                  ? Consumer<MediaPlaybackService>(
                      builder: (context, playbackService, child) {
                        final isCardVisible =
                            playbackService.shouldShowMiniPlaybackCard;
                        final cardHeight = PlaybackCardLayout.calculate(
                          context,
                        ).height;
                        final actionBottom =
                            PlaybackCardOverlayLayout.actionButtonsBottom(
                              stableBottomInset: _stablePlaybackBottomInset,
                              cardHeight: cardHeight,
                              isCardVisible: isCardVisible,
                            );
                        final topBoundary =
                            MediaQuery.of(context).viewPadding.top +
                            (useCompactTopBar ? 50.0 : kToolbarHeight) +
                            8.0;
                        final maxExpandedHeight =
                            MediaQuery.sizeOf(context).height -
                            topBoundary -
                            actionBottom;
                        return AnimatedPadding(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                          padding: EdgeInsets.only(bottom: actionBottom),
                          child: VideoActionButtons(
                            collectionId: widget.collectionId,
                            maxExpandedHeight: maxExpandedHeight,
                          ),
                        );
                      },
                    )
                  : null,
              bottomNavigationBar: _isSelectionMode && _selectedIds.isNotEmpty
                  ? MediaLibrarySelectionBottomBar(
                      onMoveToRecycleBin: () {
                        library.moveToRecycleBin(_selectedIds.toList());
                        setState(() {
                          _selectedIds.clear();
                          _isSelectionMode = false;
                        });
                        AppToast.show("已移入回收站", type: AppToastType.success);
                      },
                      onExportFluentPack: () {
                        final ids = _selectedIds.toList();
                        setState(() {
                          _selectedIds.clear();
                          _isSelectionMode = false;
                        });
                        unawaited(
                          PortableTransferNavigation.openExportSettings(
                            context,
                            ids,
                          ),
                        );
                      },
                      onRename: _selectedIds.length == 1
                          ? () {
                              final id = _selectedIds.first;
                              final col = library.getCollection(id);
                              final vid = library.getVideo(id);
                              final name = col?.name ?? vid?.title ?? "";
                              _showRenameDialog(context, id, name);
                            }
                          : null,
                    )
                  : null,
            ),
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
    if (settings.mediaLibraryViewMode == 0) {
      final metrics = MediaLibraryLayoutDefaults.cardGrid(
        screenSize: MediaQuery.sizeOf(context),
        style: settings.collectionCardStyleFor(MediaQuery.sizeOf(context)),
      );
      return GridView.builder(
        controller: _scrollController,
        padding: EdgeInsets.only(
          left: metrics.outerPadding,
          right: metrics.outerPadding,
          top: metrics.topPadding,
          bottom: metrics.outerPadding + _getPlaybackCardBottomPadding(),
        ),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: metrics.crossAxisCount,
          childAspectRatio: metrics.aspectRatio.clamp(0.1, 5.0),
          crossAxisSpacing: metrics.crossSpacing,
          mainAxisSpacing: metrics.mainSpacing,
        ),
        itemCount: contents.length,
        itemBuilder: (context, index) {
          final item = contents[index];
          if (item is VideoCollection) {
            return _buildRevealHighlight(
              item.id,
              _buildCollectionCard(
                context,
                library,
                item,
                index,
                settings,
                contents,
              ),
            );
          } else if (item is VideoItem) {
            return _buildRevealHighlight(
              item.id,
              _buildVideoCard(context, item, index, settings, contents),
            );
          }
          return const SizedBox.shrink();
        },
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final listStyle = settings.listStyleFor(MediaQuery.sizeOf(context));
        final metrics = MediaListLayoutMetrics.forGrid(
          screenShortestSide: MediaQuery.sizeOf(context).shortestSide,
          availableWidth: constraints.maxWidth,
          crossAxisCount: listStyle.crossAxisCount,
          heightSetting: listStyle.heightScale,
          titleSetting: listStyle.titleScale,
          mainSpacingSetting: listStyle.mainSpacingScale,
          crossSpacingSetting: listStyle.crossSpacingScale,
        );

        return GridView.builder(
          controller: _scrollController,
          padding: EdgeInsets.only(
            left: metrics.outerPadding,
            right: metrics.outerPadding,
            top: metrics.topPadding,
            bottom: metrics.outerPadding + _getPlaybackCardBottomPadding(),
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: listStyle.crossAxisCount,
            mainAxisExtent: metrics.rowHeight,
            crossAxisSpacing: metrics.crossSpacing,
            mainAxisSpacing: metrics.mainSpacing,
          ),
          itemCount: contents.length,
          itemBuilder: (context, index) {
            final item = contents[index];
            if (item is VideoCollection) {
              return _buildRevealHighlight(
                item.id,
                _buildCollectionListCard(
                  context: context,
                  library: library,
                  collection: item,
                  index: index,
                  settings: settings,
                  contents: contents,
                ),
              );
            } else if (item is VideoItem) {
              return _buildRevealHighlight(
                item.id,
                _buildVideoListCard(
                  context: context,
                  library: library,
                  item: item,
                  index: index,
                  settings: settings,
                  contents: contents,
                ),
              );
            }
            return const SizedBox.shrink();
          },
        );
      },
    );
  }

  Widget _buildCollectionListCard({
    required BuildContext context,
    required LibraryService library,
    required VideoCollection collection,
    required int index,
    required SettingsService settings,
    required List<dynamic> contents,
  }) {
    final isSelected = _selectedIds.contains(collection.id);
    void handleTap() {
      if (_isSelectionMode) {
        _toggleListSelection(collection.id);
      } else {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => CollectionScreen(collectionId: collection.id),
          ),
        );
      }
    }

    final listStyle = settings.listStyleFor(MediaQuery.sizeOf(context));
    final tile = MediaLibraryListTile.collection(
      collection: collection,
      index: index,
      showIndex: listStyle.showIndex,
      showThumbnail: listStyle.showThumbnail,
      isSelected: isSelected,
      isSelectionMode: _isSelectionMode,
      titleScale: listStyle.titleScale,
      onShowInParentFolder: _isSearchResults
          ? () => _showInParentDirectory(collection)
          : null,
      onSelectionTap: () => _toggleListSelection(collection.id),
      onSelectionPanStart: (details) => _startListSelectionGesture(
        index,
        collection.id,
        details.globalPosition,
      ),
      onSelectionPanUpdate: (details) {
        _updateDragSelection(details.globalPosition);
      },
      onSelectionPanEnd: (_) => _endListSelectionGesture(),
      onSelectionLongPressStart: (details) => _startListSelectionGesture(
        index,
        collection.id,
        details.globalPosition,
      ),
      onSelectionLongPressMoveUpdate: (details) {
        _updateDragSelection(details.globalPosition);
      },
      onSelectionLongPressEnd: (_) => _endListSelectionGesture(),
      onTap: handleTap,
      onSecondaryTap: () => _handleCardSecondaryTap(collection.id),
      showActivityMenu: !_isSelectionMode,
    );
    return MediaLibraryItemInteractionWrapper(
      index: index,
      dragDelay: _mediaCardLongPressDelay,
      isSelected: isSelected,
      selectedCount: _selectedIds.length,
      onDragStarted: () => _enterSelectionFromDrag(collection.id),
      onTap: handleTap,
      allowReorder: _allowsFolderReorder(),
      onReorder: (oldIndex, newIndex) {
        if (!_allowsFolderReorder()) return;
        _reorderMediaItems(
          library,
          contents,
          widget.collectionId,
          oldIndex,
          newIndex,
        );
      },
      folderId: collection.id,
      onMoveToFolder: (draggedIndex, targetId) async {
        await _moveMediaItemsToFolder(
          library,
          contents,
          currentParentId: widget.collectionId,
          draggedIndex: draggedIndex,
          targetId: targetId,
        );
      },
      child: tile,
    );
  }

  Widget _buildVideoListCard({
    required BuildContext context,
    required LibraryService library,
    required VideoItem item,
    required int index,
    required SettingsService settings,
    required List<dynamic> contents,
  }) {
    final isSelected = _selectedIds.contains(item.id);
    void handleTap() {
      if (_isSelectionMode) {
        _toggleListSelection(item.id);
        return;
      }
      final playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      if (!mounted) return;
      final controller = playbackService.currentItem?.id == item.id
          ? playbackService.controller
          : null;
      _openPlaybackScreen(item, existingController: controller);
    }

    final listStyle = settings.listStyleFor(MediaQuery.sizeOf(context));
    final tile = MediaLibraryListTile.video(
      item: item,
      index: index,
      showIndex: listStyle.showIndex,
      showThumbnail: listStyle.showThumbnail,
      isSelected: isSelected,
      isSelectionMode: _isSelectionMode,
      titleScale: listStyle.titleScale,
      relativePath: _relativePathFor(library, item),
      onShowInParentFolder: _showParentLocate()
          ? () => _showInParentDirectory(item)
          : null,
      onSelectionTap: () => _toggleListSelection(item.id),
      onSelectionPanStart: (details) =>
          _startListSelectionGesture(index, item.id, details.globalPosition),
      onSelectionPanUpdate: (details) {
        _updateDragSelection(details.globalPosition);
      },
      onSelectionPanEnd: (_) => _endListSelectionGesture(),
      onSelectionLongPressStart: (details) =>
          _startListSelectionGesture(index, item.id, details.globalPosition),
      onSelectionLongPressMoveUpdate: (details) {
        _updateDragSelection(details.globalPosition);
      },
      onSelectionLongPressEnd: (_) => _endListSelectionGesture(),
      onTap: handleTap,
      onSecondaryTap: () => _handleCardSecondaryTap(item.id),
      showActivityMenu: !_isSelectionMode,
    );
    return MediaLibraryItemInteractionWrapper(
      index: index,
      dragDelay: _mediaCardLongPressDelay,
      isSelected: isSelected,
      selectedCount: _selectedIds.length,
      onDragStarted: () => _enterSelectionFromDrag(item.id),
      onTap: handleTap,
      allowReorder: _allowsFolderReorder(),
      onReorder: (oldIndex, newIndex) {
        if (!_allowsFolderReorder()) return;
        _reorderMediaItems(
          library,
          contents,
          widget.collectionId,
          oldIndex,
          newIndex,
        );
      },
      child: tile,
    );
  }

  void _toggleListSelection(String itemId) {
    setState(() {
      if (_selectedIds.contains(itemId)) {
        _selectedIds.remove(itemId);
      } else {
        _selectedIds.add(itemId);
      }
    });
  }

  /// 键鼠右击卡片：未在选择模式则进入并选中；已在选择模式则切换该项。
  void _handleCardSecondaryTap(String itemId) {
    if (!_isSelectionMode) {
      setState(() {
        _isSelectionMode = true;
        _selectedIds.add(itemId);
      });
      return;
    }
    _toggleListSelection(itemId);
  }

  void _enterSelectionFromDrag(String itemId) {
    // 已在选择模式时不要把未选中项强行加入选区：用户可能只是想单独拖动这一项。
    if (_isSelectionMode) return;
    setState(() {
      _isSelectionMode = true;
      _selectedIds.add(itemId);
    });
  }

  void _startListSelectionGesture(
    int index,
    String itemId,
    Offset globalPosition,
  ) {
    setState(() {
      _dragSelectionStartIndex = index;
      _dragSelectionSnapshot = Set.from(_selectedIds);
      _capturedIds.clear();
      _isBoxSelecting = false;
      _boxStartPos = null;
      _boxCurrentPos = null;
      if (!_selectedIds.contains(itemId)) {
        _selectedIds.add(itemId);
        _dragSelectionSnapshot.add(itemId);
      }
      _updateDragSelection(globalPosition);
    });
  }

  void _endListSelectionGesture() {
    _stopSelectionAutoScroll();
    _lastDragSelectionGlobalPos = null;
    setState(() {
      _dragSelectionStartIndex = null;
      _dragSelectionSnapshot.clear();
      _isBoxSelecting = false;
      _boxStartPos = null;
      _boxCurrentPos = null;
      _capturedIds.clear();
    });
  }

  void _reorderMediaItems(
    LibraryService library,
    List<dynamic> contents,
    String? parentId,
    int oldIndex,
    int newIndex,
  ) {
    if (!_allowsFolderReorder()) return;
    if (oldIndex < 0 || oldIndex >= contents.length) return;
    final draggedId = (contents[oldIndex] as dynamic).id as String;
    if (_selectedIds.contains(draggedId)) {
      final itemIds = contents
          .where((item) => _selectedIds.contains((item as dynamic).id))
          .map((item) => (item as dynamic).id as String)
          .toList();
      library.reorderMultipleItems(parentId, itemIds, oldIndex, newIndex);
    } else {
      library.reorderItems(parentId, oldIndex, newIndex);
    }
  }

  Future<void> _moveMediaItemsToFolder(
    LibraryService library,
    List<dynamic> contents, {
    required String? currentParentId,
    required int draggedIndex,
    required String targetId,
  }) async {
    if (draggedIndex < 0 || draggedIndex >= contents.length) return;
    final draggedId = (contents[draggedIndex] as dynamic).id as String;
    final itemIds = _selectedIds.contains(draggedId)
        ? contents
              .where((item) => _selectedIds.contains((item as dynamic).id))
              .map((item) => (item as dynamic).id as String)
              .toList()
        : <String>[draggedId];
    await library.moveItemsToCollection(itemIds, targetId);
    await _syncSelectionAfterMove(
      library,
      currentParentId: currentParentId,
      attemptedItemIds: itemIds,
    );
    AppToast.show("已移动到文件夹", type: AppToastType.success);
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
        final chipSize = MediaLibraryActionDockMetrics.gridChipSize(cardWidth);
        final showMenu = !_isSelectionMode;
        final showLocate = _isSearchResults && !_isSelectionMode;
        final textInset = MediaLibraryActionDockMetrics.textInset(
          chipSize: chipSize,
          showMore: showMenu,
          showLocate: showLocate,
          existingPadding:
              MediaListLayoutMetrics.cardGridContentPadding(cardWidth).right,
        );
        final double radius = (cardWidth * 0.09).clamp(4.0, 40.0);
        final double titleFontSize = _resolveCardTitleFontSize(
          cardWidth,
          settings.collectionCardStyleFor(MediaQuery.sizeOf(context)).titleScale,
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
              aspectRatio: _mediaCardCoverAspectRatio,
              child: LayoutBuilder(
                builder: (context, iconConstraints) {
                  final iconSize = iconConstraints.maxWidth * 0.15;
                  final iconPadding = iconSize * 0.4;
                  final borderRadius = iconSize * 0.6;
                  final placeholder = FolderPlaceholderCover(
                    folderId: collection.id,
                    folderName: collection.name,
                    coverLabel: collection.coverLabel,
                  );

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
                                cacheHeight: 288,
                                placeholder: const SizedBox.expand(
                                  child: ColoredBox(color: Colors.black26),
                                ),
                                errorWidget: placeholder,
                              )
                            : placeholder,
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
                padding: MediaListLayoutMetrics.cardGridContentPadding(
                  cardWidth,
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
                    Padding(
                      padding: EdgeInsets.only(right: textInset),
                      child: Text(
                        "${collection.childrenIds.length} 个项目",
                        style: TextStyle(
                          fontSize: metaFontSize,
                          color: Colors.white54,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );

        // 2. Interaction Wrapper
        void handleTap() {
          if (_isSelectionMode) {
            _toggleListSelection(collection.id);
          } else {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) =>
                    CollectionScreen(collectionId: collection.id),
              ),
            );
          }
        }

        Widget interactiveCard = MediaLibraryGridCard(
          radius: radius,
          isSelected: isSelected,
          onTap: handleTap,
          onSecondaryTap: () => _handleCardSecondaryTap(collection.id),
          elevation: isSelected ? 3 : 0,
          child: Stack(
            fit: StackFit.expand,
            children: [
              cardVisual,
              MediaLibraryActionDock(
                chipSize: chipSize,
                more: showMenu
                    ? MediaLibraryActivityMenuButton(
                        targetId: collection.id,
                        isCollection: true,
                        allowHide: false,
                        fillSlot: true,
                      )
                    : null,
                locate: showLocate
                    ? MediaLibraryLocateButton(
                        onPressed: () => _showInParentDirectory(collection),
                      )
                    : null,
              ),
            ],
          ),
        );

        return Stack(
          children: [
            MediaLibraryAdaptiveDraggable<int>(
              delay: _mediaCardLongPressDelay,
              data: index,
              onTap: handleTap,
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
                allowReorder: _allowsFolderReorder(),
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
                  if (!_allowsFolderReorder()) return;
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
                  onTap: () => _toggleListSelection(collection.id),
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
                  onPanEnd: (_) => _endListSelectionGesture(),
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
                  onLongPressEnd: (_) => _endListSelectionGesture(),
                  behavior: HitTestBehavior
                      .opaque, // Opaque to ensure it captures touches in this area
                  child: Padding(
                    padding: EdgeInsets.all(
                      MediaListLayoutMetrics.gridSelectionHitPadding(cardWidth),
                    ),
                    child: Icon(
                      isSelected ? Icons.check_circle : Icons.circle_outlined,
                      color: isSelected ? Colors.blueAccent : Colors.white70,
                      size: MediaListLayoutMetrics.gridSelectionIconSize(
                        cardWidth,
                      ),
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
        final chipSize = MediaLibraryActionDockMetrics.gridChipSize(cardWidth);
        final showMenu = !_isSelectionMode;
        final showLocate = _showParentLocate() && !_isSelectionMode;
        final textInset = MediaLibraryActionDockMetrics.textInset(
          chipSize: chipSize,
          showMore: showMenu,
          showLocate: showLocate,
          existingPadding:
              MediaListLayoutMetrics.cardGridContentPadding(cardWidth).right,
        );
        final double radius = (cardWidth * 0.09).clamp(4.0, 40.0);
        final double titleFontSize = _resolveCardTitleFontSize(
          cardWidth,
          settings.collectionCardStyleFor(MediaQuery.sizeOf(context)).titleScale,
        );
        final double metaFontSize = _resolveCardMetaFontSize(titleFontSize);
        final library = Provider.of<LibraryService>(context, listen: false);
        final relativePath = _relativePathFor(library, item);

        final isSelected = _selectedIds.contains(item.id);

        // 1. Visual Content
        Widget cardVisual = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Thumbnail Area
            AspectRatio(
              aspectRatio: _mediaCardCoverAspectRatio,
              child: Container(
                color: Colors.black26,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    item.type == MediaType.audio
                        ? LayoutBuilder(
                            builder: (context, thumbConstraints) {
                              final icon = _scaledThumbnailIcon(
                                extent: thumbConstraints.biggest.shortestSide,
                                icon: Icons.music_note,
                              );
                              if (item.thumbnailPath != null &&
                                  item.thumbnailPath!.isNotEmpty) {
                                return CachedThumbnailWidget(
                                  videoId: item.id,
                                  thumbnailPath: item.thumbnailPath,
                                  fit: BoxFit.cover,
                                  placeholder: icon,
                                  errorWidget: icon,
                                );
                              }
                              return icon;
                            },
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
                              final icon = _scaledThumbnailIcon(
                                extent: constraints.biggest.shortestSide,
                                icon: Icons.movie,
                              );

                              return CachedThumbnailWidget(
                                videoId: item.id,
                                thumbnailPath: item.thumbnailPath,
                                fit: BoxFit.cover,
                                cacheWidth: cacheWidth,
                                cacheHeight: cacheHeight,
                                placeholder: icon,
                                errorWidget: icon,
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
                            ({bool isCurrent, int durationMs})
                          >(
                            selector: (context, service) {
                              final isCurrent =
                                  service.currentItem?.id == item.id;
                              if (!isCurrent) {
                                return (isCurrent: false, durationMs: 0);
                              }
                              return (
                                isCurrent: true,
                                durationMs: service.duration.inMilliseconds,
                              );
                            },
                            builder: (context, data, child) {
                              final bool isCurrent = data.isCurrent;
                              final int durationMs = isCurrent
                                  ? data.durationMs
                                  : item.durationMs;
                              Widget buildProgress(int positionMs) {
                                final shouldShow =
                                    durationMs > 0 &&
                                    (isCurrent || positionMs > 0);
                                if (!shouldShow) {
                                  return const SizedBox.shrink();
                                }
                                return SizedBox(
                                  height: 4,
                                  child: LinearProgressIndicator(
                                    value: (positionMs / durationMs).clamp(
                                      0.0,
                                      1.0,
                                    ),
                                    backgroundColor: Colors.white24,
                                    color: Colors.redAccent,
                                  ),
                                );
                              }

                              if (!isCurrent) {
                                return buildProgress(item.lastPositionMs);
                              }
                              final service = context
                                  .read<MediaPlaybackService>();
                              return ValueListenableBuilder<Duration>(
                                valueListenable: service.coarsePositionNotifier,
                                builder: (_, position, _) =>
                                    buildProgress(position.inMilliseconds),
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
                padding: MediaListLayoutMetrics.cardGridContentPadding(
                  cardWidth,
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
                    if (relativePath != null)
                      Padding(
                        padding: EdgeInsets.only(right: textInset),
                        child: Text(
                          relativePath,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: metaFontSize,
                            color: Colors.white38,
                          ),
                        ),
                      ),
                    if (item.durationMs > 0) ...[
                      const SizedBox(height: 4),
                      Padding(
                        padding: EdgeInsets.only(right: textInset),
                        child: Text(
                          "${(item.durationMs / 1000 / 60).floor()}:${((item.durationMs / 1000) % 60).floor().toString().padLeft(2, '0')}",
                          style: TextStyle(
                            fontSize: metaFontSize,
                            color: Colors.white54,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );

        // 2. Interaction Wrapper
        void handleTap() {
          if (_isSelectionMode) {
            _toggleListSelection(item.id);
          } else {
            final playbackService = Provider.of<MediaPlaybackService>(
              context,
              listen: false,
            );

            if (!context.mounted) return;

            final currentController = playbackService.currentItem?.id == item.id
                ? playbackService.controller
                : null;
            _openPlaybackScreen(item, existingController: currentController);
          }
        }

        Widget interactiveCard = MediaLibraryGridCard(
          radius: radius,
          isSelected: isSelected,
          onTap: handleTap,
          onSecondaryTap: () => _handleCardSecondaryTap(item.id),
          child: Stack(
            fit: StackFit.expand,
            children: [
              cardVisual,
              MediaLibraryActionDock(
                chipSize: chipSize,
                more: showMenu
                    ? MediaLibraryActivityMenuButton(
                        targetId: item.id,
                        isCollection: false,
                        fillSlot: true,
                      )
                    : null,
                locate: showLocate
                    ? MediaLibraryLocateButton(
                        onPressed: () => _showInParentDirectory(item),
                      )
                    : null,
              ),
            ],
          ),
        );

        return Stack(
          children: [
            MediaLibraryAdaptiveDraggable<int>(
              delay: _mediaCardLongPressDelay,
              data: index,
              onTap: handleTap,
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
                onWillAcceptWithDetails: (details) =>
                    _allowsFolderReorder() && details.data != index,
                onAcceptWithDetails: (details) {
                  if (!_allowsFolderReorder()) return;
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
                  onTap: () => _toggleListSelection(item.id),
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
                  onPanEnd: (_) => _endListSelectionGesture(),
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
                  onLongPressEnd: (_) => _endListSelectionGesture(),
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: EdgeInsets.all(
                      MediaListLayoutMetrics.gridSelectionHitPadding(cardWidth),
                    ),
                    child: Icon(
                      isSelected ? Icons.check_circle : Icons.circle_outlined,
                      color: isSelected ? Colors.blueAccent : Colors.white70,
                      size: MediaListLayoutMetrics.gridSelectionIconSize(
                        cardWidth,
                      ),
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
    showLibraryRenameDialog(
      context: context,
      itemId: id,
      currentName: currentName,
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

  /// Hidden entry: long-press the recycle-bin icon on the collection app bar.
  Future<void> _toggleExportButtonVisibility() async {
    final newValue = !_showExportSettingsButton;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('show_export_settings_button', newValue);
    if (!mounted) return;
    setState(() {
      _showExportSettingsButton = newValue;
    });
    AppToast.show(newValue ? "导出按钮已显示" : "导出按钮已隐藏", type: AppToastType.info);
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
                        try {
                          final result = await FilePicker.platform
                              .getDirectoryPath();
                          if (result != null && result.isNotEmpty) {
                            setDialogState(() {
                              tempPath = result;
                            });
                          }
                        } catch (e) {
                          debugPrint('选择目录失败: $e');
                          AppToast.show('选择目录失败: $e', type: AppToastType.error);
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
