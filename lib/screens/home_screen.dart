import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:open_filex/open_filex.dart';
import 'package:file_picker/file_picker.dart';
import 'package:video_player/video_player.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../services/app_haptics.dart';
import 'collection_screen.dart';
import 'recycle_bin_screen.dart';
import '../models/video_collection.dart';
import '../models/video_item.dart';
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
import '../widgets/media_library_entry_switcher.dart';
import '../widgets/media_library_recent_intent.dart';
import '../widgets/media_library_recent_view.dart';
import '../widgets/media_library_continue_view.dart';
import '../widgets/media_library_root_surface_host.dart';
import '../models/media_library_root_entry.dart';
import '../models/media_library_root_entry_order.dart';
import '../services/media_library_navigation.dart';
import '../widgets/media_library_selection_bottom_bar.dart';
import '../widgets/media_library_selection_drop_targets.dart';
import '../widgets/media_library_top_bar_import_progress.dart';
import '../features/portable_transfer/portable_transfer_navigation.dart';
import 'package:flutter/services.dart';
import '../services/bilibili/bilibili_api_service.dart';
import '../services/bilibili/bilibili_download_service.dart';
import '../models/bilibili_download_task.dart';
import '../models/bilibili_models.dart';

import 'bilibili_download_screen.dart';
import 'package:video_player_app/widgets/bilibili_login_dialogs.dart';
import '../widgets/mini_playback_card.dart';
import '../widgets/playback_card_layout.dart';
import 'package:desktop_drop/desktop_drop.dart';
import '../widgets/video_action_buttons.dart';
import '../widgets/responsive_icon_button.dart';
import '../widgets/sleep_timer_dialog.dart';
import '../services/media_playback_service.dart';
import '../services/playback_navigation_service.dart';
import '../services/playlist_manager.dart';
import '../services/system_media_session_service.dart';
import 'dart:convert';
import '../utils/app_toast.dart';
import '../utils/reveal_in_file_manager.dart';
import '../utils/media_library_range_selection.dart';
import '../utils/bilibili_url_parser.dart';
import '../utils/desktop_media_management_shortcuts.dart';
import '../utils/android_hardware_input_bridge.dart';
import '../utils/hardware_keyboard_shortcuts.dart';
import '../utils/page_shortcut_keys.dart';

import 'package:permission_handler/permission_handler.dart';

class _ClipboardDisplayInfo {
  final String title;
  final String cover;
  final String? collectionTitle;
  final String? collectionCover;
  final bool showCollectionBadge;
  final BilibiliVideoItem? targetVideo;
  final BilibiliDownloadEpisode? targetEpisode;

  const _ClipboardDisplayInfo({
    required this.title,
    required this.cover,
    required this.collectionTitle,
    required this.collectionCover,
    required this.showCollectionBadge,
    required this.targetVideo,
    required this.targetEpisode,
  });
}

class _ClipboardBilibiliTarget {
  final String? id;
  final int page;

  const _ClipboardBilibiliTarget({this.id, this.page = 1});
}

class _BoxSelectionPainter extends CustomPainter {
  final Rect selectionRect;

  _BoxSelectionPainter({required this.selectionRect});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.blueAccent.withValues(alpha: 0.2)
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = Colors.blueAccent.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    canvas.drawRect(selectionRect, paint);
    canvas.drawRect(selectionRect, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _BoxSelectionPainter oldDelegate) {
    return selectionRect != oldDelegate.selectionRect;
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.revealItemId,
    this.returnToSearchResults = false,
  });

  final String? revealItemId;
  final bool returnToSearchResults;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  bool _isSelectionMode = false;
  final Set<String> _selectedIds = {};
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

  // Clipboard
  String? _lastProcessedClipboard;
  bool _isCheckingClipboard = false;
  bool _isClipboardDialogVisible = false;
  bool _isClipboardExporting = false;

  // Added variables for missing definitions
  bool _hasPendingPlaybackState = false;
  double _stablePlaybackBottomInset = 0.0;
  bool _showExportSettingsButton = false;
  final FocusNode _shortcutFocusNode = FocusNode();
  bool? _lastIsFullScreen;
  bool _bilibiliLoginCheckQueued = false;
  late final AnimationController _revealHighlightController;
  Timer? _revealHighlightTimer;
  bool _didScheduleReveal = false;
  bool _didPersistRootEntryDefault = false;
  bool _didRestoreLastFolderRoute = false;
  bool _libraryNavigationScheduled = false;
  final ScrollController _recentScrollController = ScrollController();
  final ScrollController _continueScrollController = ScrollController();
  final ValueNotifier<MediaLibraryRootEntry?> _rootEntryOverride =
      ValueNotifier<MediaLibraryRootEntry?>(null);
  final ValueNotifier<double> _rootSwipeHighlight = ValueNotifier<double>(0);
  final ValueNotifier<bool> _rootSwipeSettled = ValueNotifier<bool>(true);
  final ValueNotifier<List<MediaLibraryRootEntry>> _rootEntryOrder =
      ValueNotifier<List<MediaLibraryRootEntry>>(
        List<MediaLibraryRootEntry>.of(MediaLibraryRootEntryOrder.defaults),
      );
  final GlobalKey _rootSurfaceHostKey = GlobalKey();
  String? _pendingRecentBatchId;

  static const Set<MediaLibraryRootEntry> _mountedRootEntries = {
    MediaLibraryRootEntry.continueLearning,
    MediaLibraryRootEntry.recent,
    MediaLibraryRootEntry.folders,
  };

  Future<void> _openSearch() async {
    final query = await showMediaLibrarySearchPrompt(context);
    if (!mounted || query == null) return;
    await Navigator.of(context).push(
      buildMediaLibrarySearchResultsRoute(
        CollectionScreen.search(query: query),
      ),
    );
    if (mounted && _supportsDesktopManagementShortcuts) {
      _shortcutFocusNode.requestFocus();
    }
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
          onPressed: _toggleSelectAllOnHome,
        ),
        const SizedBox(width: 2),
      ];
    }

    return [
      MediaLibraryCompactIconButton(
        icon: Icons.search_rounded,
        tooltip: _managementTooltip(
          '搜索媒体库',
          DesktopMediaManagementShortcutAction.openSearch,
        ),
        onPressed: _openSearch,
        width: 36,
      ),
      _buildCompactSleepTimerButton(),
      MediaLibraryCompactIconButton(
        icon: Icons.delete_outline,
        tooltip: _managementTooltip(
          '回收站',
          DesktopMediaManagementShortcutAction.openRecycleBin,
        ),
        // Long-press is the hidden export-settings toggle; a short tap still
        // opens the recycle bin so everyday navigation cannot unlock it.
        onLongPress: _toggleExportButtonVisibility,
        onPressed: () {
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const RecycleBinScreen()));
        },
        width: 36,
      ),
      SizedBox(
        width: 36,
        height: 48,
        child: MediaLibraryCompactMoreButton(
          itemBuilder: (menuContext) => [
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

  Widget _buildCompactSleepTimerButton() {
    final timer = MediaPlaybackService().sleepTimer;
    return AnimatedBuilder(
      animation: timer,
      builder: (context, _) => MediaLibraryCompactIconButton(
        icon: timer.isActive ? Icons.alarm_on_rounded : Icons.schedule_rounded,
        tooltip: _managementTooltip(
          timer.isActive ? timer.statusText : '定时关闭',
          DesktopMediaManagementShortcutAction.openSleepTimer,
        ),
        color: timer.isActive ? Colors.blueAccent : null,
        width: 36,
        onPressed: () => unawaited(showSleepTimerDialog(context)),
      ),
    );
  }

  // ... (existing code)

  final ScrollController _scrollController =
      ScrollController(); // Need scroll controller for calculation
  static const double _mediaCardCoverAspectRatio = 16 / 9;

  double _resolveCardTitleFontSize(double cardWidth, double settingValue) {
    return MediaLibraryLayoutDefaults.titleFontSize(cardWidth, settingValue);
  }

  double _resolveCardMetaFontSize(double titleFontSize) {
    return MediaLibraryLayoutDefaults.metaFontSize(titleFontSize);
  }

  void _openCardStyleSheet() {
    unawaited(
      MediaLibraryStyleSheet.show(
        context: context,
        scope: MediaLibraryCardStyleScope.home,
      ),
    );
  }

  MediaCardStyleSettings _homeCardStyle() {
    return Provider.of<SettingsService>(
      context,
      listen: false,
    ).homeCardStyleFor(MediaQuery.sizeOf(context));
  }

  MediaListStyleSettings _listStyle() {
    return Provider.of<SettingsService>(
      context,
      listen: false,
    ).listStyleFor(MediaQuery.sizeOf(context));
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

  /// Helper: Get total item count safely
  int _getItemCount() {
    final library = Provider.of<LibraryService>(context, listen: false);
    return library.getContents(null).length;
  }

  /// Helper: Get content ID at index
  String? _getItemId(int index) {
    final library = Provider.of<LibraryService>(context, listen: false);
    final contents = library.getContents(null);
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
      style: settings.homeCardStyleFor(mediaSize),
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
    final settings = Provider.of<SettingsService>(context, listen: false);
    final library = Provider.of<LibraryService>(context, listen: false);
    final plan = _rootNavigationPlan(library, settings);
    if (!plan.forceFoldersForLocate &&
        (plan.displayedEntry == MediaLibraryRootEntry.recent ||
            plan.displayedEntry == MediaLibraryRootEntry.continueLearning)) {
      return false;
    }
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
    // Keep next/previous inside the item's original folder, not the current view.
    Provider.of<PlaylistManager>(
      context,
      listen: false,
    ).prepareLibraryPlayback(item);
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

  Future<void> _loadExportButtonPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getBool('show_export_settings_button') ?? false;
    if (mounted) {
      setState(() {
        _showExportSettingsButton = value;
      });
    } else {
      _showExportSettingsButton = value;
    }
  }

  /// Hidden entry: long-press the recycle-bin icon on the media-library app bar.
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

  void _openPortableTransfer() {
    unawaited(PortableTransferNavigation.open(context));
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

      if (mounted) {
        final result = await OpenFilex.open(filePath, type: 'application/json');
        if (result.type == ResultType.done) {
          AppToast.show("设置已导出并打开: $filePath", type: AppToastType.success);
        } else {
          AppToast.show("设置已导出，但打开失败: $filePath", type: AppToastType.error);
        }
      }
    } catch (e) {
      if (mounted) {
        AppToast.show("导出失败: $e", type: AppToastType.error);
      }
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

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    AndroidHardwareInputBridge.addKeyListener(_handleAndroidHardwareKeyEvent);
    HardwareKeyboard.instance.addHandler(_handleGlobalHardwareKeyEvent);
    MediaLibraryRecentIntent.pendingBatchId.addListener(
      _onRecentBatchViewRequested,
    );
    _revealHighlightController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
      reverseDuration: const Duration(milliseconds: 560),
    );
    if (!widget.returnToSearchResults) {
      WidgetsBinding.instance.addObserver(this);
      _requestNotificationPermission();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_supportsDesktopManagementShortcuts && mounted) {
        _shortcutFocusNode.requestFocus();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadExportButtonPreference();
      if (!widget.returnToSearchResults) {
        // 使用非阻塞方式调用,避免卡住UI
        _checkBilibiliLogin();
        _checkClipboard();
        _checkPendingPlaybackState();
      }
    });

    // 监听播放服务状态，当播放状态恢复完成后清除待恢复标志
    if (!widget.returnToSearchResults) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final playbackService = Provider.of<MediaPlaybackService>(
          context,
          listen: false,
        );
        playbackService.addListener(_onPlaybackServiceChanged);
      });
    }
  }

  @override
  void dispose() {
    if (!widget.returnToSearchResults) {
      WidgetsBinding.instance.removeObserver(this);
    }
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    if (!widget.returnToSearchResults) {
      playbackService.removeListener(_onPlaybackServiceChanged);
    }
    AndroidHardwareInputBridge.removeKeyListener(
      _handleAndroidHardwareKeyEvent,
    );
    HardwareKeyboard.instance.removeHandler(_handleGlobalHardwareKeyEvent);
    _revealHighlightTimer?.cancel();
    _revealHighlightController.dispose();
    _shortcutFocusNode.dispose();
    _recentScrollController.dispose();
    _continueScrollController.dispose();
    _rootEntryOverride.dispose();
    _rootSwipeHighlight.dispose();
    _rootSwipeSettled.dispose();
    _rootEntryOrder.dispose();
    MediaLibraryRecentIntent.pendingBatchId.removeListener(
      _onRecentBatchViewRequested,
    );
    _selectionAutoScroller?.dispose();
    super.dispose();
  }

  bool get _supportsDesktopManagementShortcuts {
    return supportsNativeHardwareKeyboardShortcuts;
  }

  bool get _isDesktopPlatform {
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  }

  bool _isTextInputFocused() => isEditableTextFocused();

  bool _handleGlobalHardwareKeyEvent(KeyEvent event) {
    // Focus already consumes the event when it owns the node; this catches
    // desktop keys after a click stole focus without going through Focus.
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

  String _managementTooltip(
    String label,
    DesktopMediaManagementShortcutAction action,
  ) {
    final platform = currentNativeTargetPlatform;
    if (platform == null ||
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

  MediaLibraryNavigationPlan _rootNavigationPlan(
    LibraryService library,
    SettingsService settings,
  ) {
    return MediaLibraryNavigation.plan(
      libraryInitialized: library.isInitialized,
      hasExistingLibraryContent: library.hasExistingLibraryContent,
      storedEntry: settings.mediaLibraryRootEntry,
      userChosen: settings.mediaLibraryRootEntryUserChosen,
      lastFolderId: settings.mediaLibraryLastFolderId,
      availableEntries: _mountedRootEntries,
      revealItemId: widget.revealItemId,
      returnToSearchResults: widget.returnToSearchResults,
      isActiveFolder: (id) {
        final collection = library.getCollection(id);
        return collection != null && !collection.isRecycled;
      },
      parentIdOf: (id) => library.getCollection(id)?.parentId,
    );
  }

  void _persistScrollForEntry(
    MediaLibraryRootEntry displayed,
    SettingsService settings,
  ) {
    final library = Provider.of<LibraryService>(context, listen: false);
    final visibleIds = library
        .getContents(null)
        .map((item) => (item as dynamic).id as String)
        .toSet();
    final previous = Map<MediaLibraryRootEntry, MediaLibraryScrollAnchor>.from(
      MediaLibraryNavigation.decodeAnchors(settings.mediaLibraryEntryAnchors),
    );
    final previousAnchor =
        previous[displayed] ?? const MediaLibraryScrollAnchor();
    final sanitized = MediaLibraryNavigation.sanitizeAnchor(
      anchor: previousAnchor,
      visibleItemIds: visibleIds,
    );
    final controller = _scrollControllerFor(displayed);
    final offset = controller.hasClients
        ? controller.offset
        : sanitized.offset;
    previous[displayed] = MediaLibraryScrollAnchor(
      itemId:
          sanitized.itemId ?? (visibleIds.isEmpty ? null : visibleIds.first),
      offset: offset,
    );
    unawaited(
      settings.saveMediaLibraryEntryAnchors(
        MediaLibraryNavigation.encodeAnchors(previous),
      ),
    );
  }

  ScrollController _scrollControllerFor(MediaLibraryRootEntry entry) {
    switch (entry) {
      case MediaLibraryRootEntry.continueLearning:
        return _continueScrollController;
      case MediaLibraryRootEntry.recent:
        return _recentScrollController;
      case MediaLibraryRootEntry.folders:
        return _scrollController;
    }
  }

  MediaLibraryRootEntry _effectiveRootEntry(MediaLibraryNavigationPlan plan) {
    if (plan.forceFoldersForLocate) return MediaLibraryRootEntry.folders;
    return _rootEntryOverride.value ?? plan.displayedEntry;
  }

  void _syncRootEntryOrder(SettingsService settings) {
    final parsed = MediaLibraryRootEntryOrder.parse(
      settings.mediaLibraryRootEntryOrder,
    );
    if (listEquals(_rootEntryOrder.value, parsed)) return;
    _rootEntryOrder.value = parsed;
  }

  void _onRootEntryReorder(
    int oldIndex,
    int newIndex,
    SettingsService settings,
    MediaLibraryNavigationPlan plan,
  ) {
    if (!_rootSwipeSettled.value) return;
    final next = MediaLibraryRootEntryOrder.moved(
      _rootEntryOrder.value,
      oldIndex: oldIndex,
      newIndex: newIndex,
    );
    if (listEquals(next, _rootEntryOrder.value)) return;
    _rootEntryOrder.value = next;
    final selected = _effectiveRootEntry(plan);
    final index = next.indexOf(selected);
    if (index >= 0) {
      _rootSwipeHighlight.value = index.toDouble();
    }
    unawaited(
      settings.saveMediaLibraryRootEntryOrder(
        MediaLibraryRootEntryOrder.encode(next),
      ),
    );
  }

  void _selectRootEntry(MediaLibraryRootEntry entry, SettingsService settings) {
    if (!_mountedRootEntries.contains(entry)) return;
    final library = Provider.of<LibraryService>(context, listen: false);
    final plan = _rootNavigationPlan(library, settings);
    final leaving = _effectiveRootEntry(plan);
    if (leaving == entry) return;
    if (_isSelectionMode) {
      _exitSelectionMode();
    }
    _rootEntryOverride.value = entry;
    final orderIndex = _rootEntryOrder.value.indexOf(entry);
    _rootSwipeHighlight.value = (orderIndex < 0 ? entry.index : orderIndex)
        .toDouble();
    unawaited(
      settings.saveMediaLibraryRootChoice(entry.storageValue, notify: false),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _persistScrollForEntry(leaving, settings);
    });
  }

  void _onRecentBatchViewRequested() {
    final batchId = MediaLibraryRecentIntent.pendingBatchId.value;
    if (batchId == null || !mounted) return;
    MediaLibraryRecentIntent.pendingBatchId.value = null;
    final settings = Provider.of<SettingsService>(context, listen: false);
    setState(() => _pendingRecentBatchId = batchId);
    _selectRootEntry(MediaLibraryRootEntry.recent, settings);
  }

  void _locateLibraryItem(VideoItem item) {
    final parentId = item.parentId;
    final Widget page = parentId == null
        ? HomeScreen(revealItemId: item.id, returnToSearchResults: true)
        : CollectionScreen(
            collectionId: parentId,
            revealItemId: item.id,
            returnToSearchResults: true,
          );
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  void _applyLibraryNavigationAfterInit(
    LibraryService library,
    SettingsService settings,
  ) {
    final plan = _rootNavigationPlan(library, settings);
    if (plan.persistPreferred && !_didPersistRootEntryDefault) {
      _didPersistRootEntryDefault = true;
      unawaited(
        settings.updateSetting(
          'mediaLibraryRootEntry',
          plan.preferredEntry.storageValue,
        ),
      );
    }
    if (_didRestoreLastFolderRoute) return;
    _didRestoreLastFolderRoute = true;
    final folderId = plan.folderToOpen;
    if (folderId == null ||
        widget.revealItemId != null ||
        widget.returnToSearchResults) {
      return;
    }
    unawaited(
      Navigator.of(context)
          .push(
            MaterialPageRoute<void>(
              builder: (context) => CollectionScreen(collectionId: folderId),
            ),
          )
          .then((_) {
            if (!mounted) return;
            unawaited(settings.updateSetting('mediaLibraryLastFolderId', ''));
          }),
    );
  }

  /// Root library has no parent folder, so drop-target payload is recycle-only.
  List<String> _idsForSelectionDrop({int? draggedIndex}) {
    final library = Provider.of<LibraryService>(context, listen: false);
    return resolveMediaLibrarySelectionDropIds(
      contents: library.getContents(null),
      selectedIds: _selectedIds,
      draggedIndex: draggedIndex,
    );
  }

  Future<void> _moveItemsToRecycleBin({int? draggedIndex}) async {
    final itemsToMove = _idsForSelectionDrop(draggedIndex: draggedIndex);
    if (itemsToMove.isEmpty) return;

    final library = Provider.of<LibraryService>(context, listen: false);
    await library.moveToRecycleBin(itemsToMove);
    if (!mounted) return;
    setState(() {
      _selectedIds.removeAll(itemsToMove);
      if (_selectedIds.isEmpty) {
        _isSelectionMode = false;
      }
    });
    AppToast.show("已移入回收站", type: AppToastType.success);
  }

  void _toggleSelectAllOnHome() {
    final library = Provider.of<LibraryService>(context, listen: false);
    final contents = library.getContents(null);
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
          return KeyEventResult.handled;
        }
        if (widget.returnToSearchResults) {
          Navigator.of(context).maybePop();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
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
        if (_isSelectionMode ||
            !(Platform.isWindows || Platform.isLinux)) {
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
        _toggleSelectAllOnHome();
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
            final library = Provider.of<LibraryService>(context, listen: false);
            final id = _selectedIds.first;
            final name =
                library.getCollection(id)?.name ??
                library.getVideo(id)?.title ??
                '';
            _showRenameDialog(context, id, name);
          }
          return KeyEventResult.handled;
        }
        VideoActionButtons.openCreateCollectionDialog(context, null);
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.importMedia:
        if (_isSelectionMode) return KeyEventResult.handled;
        unawaited(VideoActionButtons.showImportMenu(context, null));
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openBilibiliDownload:
        if (_isSelectionMode) return KeyEventResult.handled;
        VideoActionButtons.openBilibiliDownloadPage(context);
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openYtDlpDownload:
        if (_isSelectionMode) return KeyEventResult.handled;
        VideoActionButtons.openYtDlpDownloadPage(context);
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openBatchSubtitle:
        if (_isSelectionMode) return KeyEventResult.handled;
        VideoActionButtons.openBatchSubtitlePage(context);
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openBatchImport:
        if (_isSelectionMode) return KeyEventResult.handled;
        VideoActionButtons.openBatchImportPage(context);
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.moveToParent:
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
        unawaited(PortableTransferNavigation.openExportSettings(context, ids));
        return KeyEventResult.handled;
    }
  }

  KeyEventResult _handleShortcutKeyEvent(
    KeyEvent event, {
    bool fromAndroidNativeBridge = false,
    bool? hasBlockingModifierOverride,
  }) {
    if (!_supportsDesktopManagementShortcuts) return KeyEventResult.ignored;
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
        hasBlockingModifierOverride ?? hasBlockingKeyboardModifier();
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

  /// 播放服务状态变化监听器
  void _onPlaybackServiceChanged() {
    if (_hasPendingPlaybackState) {
      final playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      // 当播放状态恢复完成（currentItem 被设置）后，清除待恢复标志
      if (playbackService.currentItem != null) {
        setState(() {
          _hasPendingPlaybackState = false;
        });
      }
    }
  }

  Future<void> _requestNotificationPermission() async {
    if (!Platform.isAndroid) return;
    final status = await Permission.notification.status;
    debugPrint('HomeScreen: notification permission status=$status');
    if (status.isGranted || status.isLimited || status.isProvisional) {
      if (MediaPlaybackService().currentItem != null) {
        await SystemMediaSessionService.instance.refreshNow(
          ensureNotificationVisible: true,
        );
      }
      return;
    }
    if (status.isDenied) {
      final result = await Permission.notification.request();
      debugPrint('HomeScreen: notification permission request result=$result');
      if (result.isGranted || result.isLimited || result.isProvisional) {
        await SystemMediaSessionService.instance.refreshNow(
          ensureNotificationVisible: true,
        );
      }
      return;
    }
    if (status.isPermanentlyDenied) {
      debugPrint(
        'HomeScreen: notification permission permanently denied, media notification may be hidden',
      );
    }
  }

  Future<void> _checkBilibiliLogin() async {
    if (!mounted) return;

    try {
      final service = Provider.of<BilibiliDownloadService>(
        context,
        listen: false,
      );
      bool initReady = true;
      final initFuture = service.init();
      await initFuture.timeout(
        const Duration(milliseconds: 800),
        onTimeout: () {
          initReady = false;
        },
      );
      if (!initReady) {
        if (!_bilibiliLoginCheckQueued) {
          _bilibiliLoginCheckQueued = true;
          initFuture.then((_) {
            if (!mounted) return;
            _bilibiliLoginCheckQueued = false;
            _checkBilibiliLogin();
          });
        }
        return;
      }
      if (!mounted) return;
      final settings = Provider.of<SettingsService>(context, listen: false);

      if (settings.suppressBilibiliRestrictedDialog) return;

      // Check if login is valid (calls Bilibili API)
      // We only check this on startup to avoid spamming the user
      // 添加超时处理,避免网络请求卡住UI
      final loginStatus = await service.apiService
          .checkLoginStatusDetailed()
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              debugPrint('B站登录状态检查超时');
              return BilibiliLoginStatus.unavailable;
            },
          );

      // Offline, timeout and Bilibili service failures cannot prove that the
      // persisted login has expired. Keep the cookie and do not disturb users
      // who only want to use local/offline features.
      if (loginStatus == BilibiliLoginStatus.unavailable) {
        debugPrint('暂时无法验证B站登录状态，保留本地登录信息并跳过提示');
        return;
      }

      if (loginStatus == BilibiliLoginStatus.loggedOut) {
        if (!mounted) return;

        bool dontShowAgain = false;

        await showDialog(
          context: context,
          builder: (context) => StatefulBuilder(
            builder: (context, setState) => AlertDialog(
              backgroundColor: const Color(0xFF2C2C2C),
              title: const Text(
                "B站功能受限提示",
                style: TextStyle(color: Colors.white),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "检测到您尚未登录或Cookie已过期。\n\n不扫码就无法使用剪贴板识别b站视频与B站视频解析功能。",
                    style: TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        dontShowAgain = !dontShowAgain;
                      });
                    },
                    child: Row(
                      children: [
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: Checkbox(
                            value: dontShowAgain,
                            onChanged: (val) {
                              setState(() {
                                dontShowAgain = val ?? false;
                              });
                            },
                            fillColor: WidgetStateProperty.resolveWith(
                              (states) => states.contains(WidgetState.selected)
                                  ? const Color(0xFFFB7299)
                                  : Colors.grey,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          "之后不显示",
                          style: TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    if (dontShowAgain) {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          backgroundColor: const Color(0xFF2C2C2C),
                          title: const Text(
                            "确认不再提示",
                            style: TextStyle(color: Colors.white),
                          ),
                          content: const Text(
                            "您选择了不再提示。\n\n后续如需登录B站账号以解锁完整功能（如剪贴板识别、视频解析），请前往：\n\n设置页 -> B站下载设置 -> 点击头像登录",
                            style: TextStyle(color: Colors.white70),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text(
                                "取消",
                                style: TextStyle(color: Colors.grey),
                              ),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text(
                                "确认",
                                style: TextStyle(color: Color(0xFFFB7299)),
                              ),
                            ),
                          ],
                        ),
                      );

                      if (confirm == true) {
                        if (context.mounted) {
                          Provider.of<SettingsService>(
                            context,
                            listen: false,
                          ).updateSetting(
                            'suppressBilibiliRestrictedDialog',
                            true,
                          );
                          Navigator.pop(context);
                        }
                      }
                    } else {
                      Navigator.pop(context);
                    }
                  },
                  child: const Text(
                    "暂不登录",
                    style: TextStyle(color: Colors.grey),
                  ),
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
    if (_isCheckingClipboard ||
        _isClipboardDialogVisible ||
        _isClipboardExporting) {
      return;
    }
    _isCheckingClipboard = true;
    try {
      // 1. Check Login
      if (!mounted) return;
      final service = Provider.of<BilibiliDownloadService>(
        context,
        listen: false,
      );

      // Cold starts can reach the first frame before the deferred Bilibili
      // service has restored its cookie jar. Reuse the existing initialization
      // future so the startup clipboard check sees the persisted login state.
      await service.init();
      if (!mounted) return;

      // 添加超时处理
      final hasCookie = await service.apiService.hasCookie().timeout(
        const Duration(seconds: 2),
        onTimeout: () => false,
      );
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

      final task = await service
          .parseSingleLine(content)
          .timeout(const Duration(seconds: 5), onTimeout: () => null);
      if (task != null) {
        _lastProcessedClipboard = content;
        if (mounted) {
          final displayInfo = await _buildClipboardDisplayInfo(content, task);
          if (!mounted) return;
          await _showClipboardDialog(content, task, displayInfo);
        }
      }
    } catch (e) {
      // Ignore - 不影响应用启动
      debugPrint('剪贴板检查失败: $e');
    } finally {
      _isCheckingClipboard = false;
    }
  }

  Future<_ClipboardDisplayInfo> _buildClipboardDisplayInfo(
    String content,
    BilibiliDownloadTask task,
  ) async {
    final collectionTitle = task.collectionInfo?.title;
    final collectionCover = task.collectionInfo?.cover;
    BilibiliVideoItem? targetVideo;
    final linkTarget = await _extractBilibiliTargetFromContent(content);
    if (task.singleVideoInfo != null) {
      targetVideo = task.videos.isEmpty ? null : task.videos.first;
    } else if (task.collectionInfo != null) {
      final id = linkTarget.id;
      if (id != null) {
        final lowerId = id.toLowerCase();
        final normalizedAid = lowerId.startsWith('av')
            ? lowerId.substring(2)
            : lowerId;
        for (final video in task.videos) {
          final bvid = video.videoInfo.bvid.toLowerCase();
          final aid = video.videoInfo.aid.toLowerCase();
          if (bvid == lowerId || aid == normalizedAid) {
            targetVideo = video;
            break;
          }
        }
      }
      targetVideo ??= task.videos.length == 1 ? task.videos.first : null;
    }
    BilibiliDownloadEpisode? targetEpisode;
    if (targetVideo != null && targetVideo.episodes.isNotEmpty) {
      targetEpisode = targetVideo.episodes.firstWhere(
        (episode) => episode.page.page == linkTarget.page,
        orElse: () => targetVideo!.episodes.first,
      );
    }
    final title =
        targetVideo?.videoInfo.title ??
        task.singleVideoInfo?.title ??
        task.collectionInfo?.title ??
        "未知标题";
    final cover =
        targetVideo?.videoInfo.pic ??
        task.singleVideoInfo?.pic ??
        task.collectionInfo?.cover ??
        "";
    final showCollectionBadge =
        task.collectionInfo != null && targetVideo != null;
    return _ClipboardDisplayInfo(
      title: title,
      cover: cover,
      collectionTitle: collectionTitle,
      collectionCover: collectionCover,
      showCollectionBadge: showCollectionBadge,
      targetVideo: targetVideo,
      targetEpisode: targetEpisode,
    );
  }

  Future<_ClipboardBilibiliTarget> _extractBilibiliTargetFromContent(
    String content,
  ) async {
    try {
      String cleanInput = content.trim();
      final linkMatch = RegExp(r'(https?://[^\s]+)').firstMatch(content);
      if (linkMatch != null) {
        cleanInput = linkMatch.group(0)!;
        cleanInput = cleanInput.replaceAll(RegExp(r'[.,!?;:")]*$'), '');
      } else {
        final bvMatch = RegExp(
          r'(BV[a-zA-Z0-9]{10})',
          caseSensitive: false,
        ).firstMatch(content);
        if (bvMatch != null) {
          cleanInput = bvMatch.group(0)!;
        } else {
          final ssMatch = RegExp(
            r'(ss[0-9]+)',
            caseSensitive: false,
          ).firstMatch(content);
          if (ssMatch != null) {
            cleanInput = ssMatch.group(0)!;
          } else {
            final epMatch = RegExp(
              r'(ep[0-9]+)',
              caseSensitive: false,
            ).firstMatch(content);
            if (epMatch != null) {
              cleanInput = epMatch.group(0)!;
            }
          }
        }
      }
      var type = BilibiliUrlParser.determineType(cleanInput);
      if (type == BilibiliUrlType.shortLink) {
        final service = Provider.of<BilibiliDownloadService>(
          context,
          listen: false,
        );
        final resolvedUrl = await service.apiService.resolveShortLink(
          cleanInput,
        );
        cleanInput = resolvedUrl;
        type = BilibiliUrlParser.determineType(cleanInput);
      }
      final uri = Uri.tryParse(cleanInput);
      final page = int.tryParse(uri?.queryParameters['p'] ?? '') ?? 1;
      return _ClipboardBilibiliTarget(
        id: BilibiliUrlParser.extractId(cleanInput, type),
        page: page > 0 ? page : 1,
      );
    } catch (_) {
      return const _ClipboardBilibiliTarget();
    }
  }

  Future<void> _showClipboardDialog(
    String content,
    BilibiliDownloadTask task,
    _ClipboardDisplayInfo displayInfo,
  ) async {
    if (_isClipboardDialogVisible || !mounted) return;
    final title = displayInfo.title;
    final cover = displayInfo.cover;

    final parentContext = context;
    _isClipboardDialogVisible = true;
    try {
      await showDialog<void>(
        context: parentContext,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: const Color(0xFF2C2C2C),
          contentPadding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (cover.isNotEmpty)
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(16),
                  ),
                  child: Image.network(
                    cover,
                    height: 160,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Container(
                      height: 160,
                      color: Colors.grey[800],
                      child: const Icon(Icons.broken_image),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "检测到 Bilibili 视频",
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.blueAccent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (displayInfo.showCollectionBadge) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          if ((displayInfo.collectionCover ?? '').isNotEmpty)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: Image.network(
                                displayInfo.collectionCover!,
                                width: 22,
                                height: 16,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) =>
                                    Container(
                                      width: 22,
                                      height: 16,
                                      color: Colors.grey[800],
                                    ),
                              ),
                            )
                          else
                            Container(
                              width: 22,
                              height: 16,
                              color: Colors.grey[800],
                            ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              "来自合集：${displayInfo.collectionTitle ?? ''}",
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.white54,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 12),
                    const Text(
                      "请选择添加方式",
                      style: TextStyle(fontSize: 13, color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          actionsOverflowButtonSpacing: 6,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text(
                "忽略",
                style: TextStyle(
                  color: Colors.white54,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(dialogContext);
                unawaited(
                  _exportClipboardTaskAsStreamingCard(task, displayInfo),
                );
              },
              style: FilledButton.styleFrom(
                backgroundColor: Colors.pinkAccent.withValues(alpha: 0.16),
                foregroundColor: Colors.pinkAccent.shade100,
                minimumSize: const Size(0, 42),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                elevation: 0,
                side: BorderSide(
                  color: Colors.pinkAccent.withValues(alpha: 0.4),
                ),
              ),
              icon: const Icon(Icons.play_circle_outline_rounded, size: 17),
              label: const FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  "添加为在线播放卡片",
                  maxLines: 1,
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                final playbackService = Provider.of<MediaPlaybackService>(
                  parentContext,
                  listen: false,
                );
                final navigator = Navigator.of(parentContext);
                Navigator.pop(dialogContext);
                if (playbackService.isPlaying) {
                  await playbackService.pause();
                }
                if (!mounted || !navigator.mounted) return;
                const routeName = '/bilibili_download';
                if (AppToast.isCurrentRoute(routeName)) {
                  navigator.pushReplacement(
                    MaterialPageRoute(
                      builder: (_) =>
                          BilibiliDownloadScreen(initialInput: content),
                      settings: const RouteSettings(name: routeName),
                    ),
                  );
                } else {
                  navigator.push(
                    MaterialPageRoute(
                      builder: (_) =>
                          BilibiliDownloadScreen(initialInput: content),
                      settings: const RouteSettings(name: routeName),
                    ),
                  );
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent,
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 42),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                elevation: 0,
              ),
              icon: const Icon(Icons.download_outlined, size: 17),
              label: const FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  "导入下载页",
                  maxLines: 1,
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
            ),
          ],
        ),
      );
    } finally {
      _isClipboardDialogVisible = false;
    }
  }

  Future<bool?> _showClipboardExportScopeDialog({
    required String title,
    required String message,
    required String singleLabel,
    required String allLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2C),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          message,
          style: const TextStyle(color: Colors.white70, height: 1.45),
        ),
        actionsOverflowButtonSpacing: 6,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(
              singleLabel,
              style: const TextStyle(
                color: Colors.pinkAccent,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blueAccent,
              foregroundColor: Colors.white,
              elevation: 0,
            ),
            child: Text(
              allLabel,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  BilibiliVideoItem? _findClipboardTargetVideo(
    BilibiliDownloadTask task,
    BilibiliVideoItem target,
  ) {
    final targetBvid = target.videoInfo.bvid.toLowerCase();
    final targetAid = target.videoInfo.aid.toLowerCase();
    for (final video in task.videos) {
      if ((targetBvid.isNotEmpty &&
              video.videoInfo.bvid.toLowerCase() == targetBvid) ||
          (targetAid.isNotEmpty &&
              video.videoInfo.aid.toLowerCase() == targetAid)) {
        return video;
      }
    }
    return null;
  }

  Future<BilibiliDownloadTask?> _chooseClipboardStreamingTask(
    BilibiliDownloadTask task,
    _ClipboardDisplayInfo displayInfo,
  ) async {
    final clonedTask = BilibiliDownloadTask.fromJson(task.toJson());
    BilibiliVideoItem? targetVideo;

    if (task.collectionInfo != null) {
      if (displayInfo.targetVideo == null) {
        final addWholeCollection = await _showClipboardExportScopeDialog(
          title: '发现合集',
          message:
              '当前链接属于合集“${task.collectionInfo!.title}”，但无法准确定位合集中的当前视频。\n\n是否添加整个合集？',
          singleLabel: '返回',
          allLabel: '添加整个合集',
        );
        return addWholeCollection == true ? clonedTask : null;
      }

      final addWholeCollection = await _showClipboardExportScopeDialog(
        title: '发现合集',
        message:
            '此视频属于合集：\n${task.collectionInfo!.title}\n\n请选择添加当前视频，还是添加整个合集。',
        singleLabel: '仅添加此视频',
        allLabel: '添加整个合集',
      );
      if (addWholeCollection == null) return null;
      if (addWholeCollection) return clonedTask;
      targetVideo = _findClipboardTargetVideo(
        clonedTask,
        displayInfo.targetVideo!,
      );
    } else if (clonedTask.videos.isNotEmpty) {
      targetVideo = clonedTask.videos.first;
    }

    if (targetVideo == null) return null;
    var scopedTask = BilibiliDownloadTask(
      singleVideoInfo: targetVideo.videoInfo,
      videos: <BilibiliVideoItem>[targetVideo],
      sourceRef: targetVideo.sourceRef ?? clonedTask.sourceRef,
      isStreamingImport: true,
      isSelected: true,
    );
    if (targetVideo.episodes.length <= 1) return scopedTask;

    final addAllParts = await _showClipboardExportScopeDialog(
      title: '发现分P视频',
      message:
          '“${targetVideo.videoInfo.title}”包含 ${targetVideo.episodes.length} 个分P。\n\n请选择仅添加当前分P，还是添加全部分P。',
      singleLabel: '仅添加当前分P',
      allLabel: '添加全部分P',
    );
    if (addAllParts == null) return null;
    if (addAllParts) return scopedTask;

    final requestedPage = displayInfo.targetEpisode?.page.page ?? 1;
    final targetEpisode = targetVideo.episodes.firstWhere(
      (episode) => episode.page.page == requestedPage,
      orElse: () => targetVideo!.episodes.first,
    );
    final originalInfo = targetVideo.videoInfo;
    final partTitle = targetEpisode.page.part.trim();
    final partInfo = BilibiliVideoInfo(
      title: partTitle.isEmpty ? originalInfo.title : partTitle,
      desc: originalInfo.desc,
      pic: originalInfo.pic,
      bvid: originalInfo.bvid,
      aid: originalInfo.aid,
      ownerName: originalInfo.ownerName,
      ownerMid: originalInfo.ownerMid,
      pubDate: originalInfo.pubDate,
      pages: <BilibiliPage>[targetEpisode.page],
    );
    final partVideo = BilibiliVideoItem(
      videoInfo: partInfo,
      episodes: <BilibiliDownloadEpisode>[targetEpisode],
      sourceRef: targetVideo.sourceRef,
      isExpanded: true,
      isSelected: true,
    );
    scopedTask = BilibiliDownloadTask(
      singleVideoInfo: partInfo,
      videos: <BilibiliVideoItem>[partVideo],
      sourceRef: targetVideo.sourceRef ?? clonedTask.sourceRef,
      isStreamingImport: true,
      isSelected: true,
    );
    return scopedTask;
  }

  Future<void> _exportClipboardTaskAsStreamingCard(
    BilibiliDownloadTask task,
    _ClipboardDisplayInfo displayInfo,
  ) async {
    if (_isClipboardExporting || !mounted) return;
    _isClipboardExporting = true;
    try {
      // Let the preview dialog finish popping before pushing the scope dialog
      // on the same Navigator.
      await Future<void>.delayed(Duration.zero);
      if (!mounted) return;
      final scopedTask = await _chooseClipboardStreamingTask(task, displayInfo);
      if (scopedTask == null || !mounted) return;
      final service = Provider.of<BilibiliDownloadService>(
        context,
        listen: false,
      );
      final library = Provider.of<LibraryService>(context, listen: false);
      await service.importParsedStreamingTaskToLibrary(library, scopedTask);
    } catch (error) {
      debugPrint('剪贴板 Bilibili 在线播放卡片添加失败: $error');
    } finally {
      _isClipboardExporting = false;
      unawaited(
        Future<void>.delayed(Duration.zero, () {
          if (mounted) return _checkClipboard();
        }),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsService>(context);
    final library = Provider.of<LibraryService>(context);
    _syncRootEntryOrder(settings);
    final useCompactTopBar = useCompactMediaLibraryTopBar(context);
    final rootNavPlan = _rootNavigationPlan(library, settings);
    if (library.isInitialized && !_libraryNavigationScheduled) {
      _libraryNavigationScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _applyLibraryNavigationAfterInit(library, settings);
      });
    }
    _stablePlaybackBottomInset =
        PlaybackCardOverlayLayout.resolveStableBottomInset(
          MediaQuery.of(context),
          _stablePlaybackBottomInset,
        );
    final playbackCardBottom = PlaybackCardOverlayLayout.cardBottom(
      _stablePlaybackBottomInset,
    );
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      if (_lastIsFullScreen != settings.isFullScreen) {
        _lastIsFullScreen = settings.isFullScreen;
        if (_lastIsFullScreen == true) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_shortcutFocusNode.hasFocus) {
              _shortcutFocusNode.requestFocus();
            }
          });
        }
      }
    }

    return PopScope(
      canPop: !_isSelectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        setState(() {
          _isSelectionMode = false;
          _selectedIds.clear();
          _isBoxSelecting = false;
          _boxStartPos = null;
          _boxCurrentPos = null;
          _capturedIds.clear();
        });
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF121212),
        // Search owns its keyboard avoidance inside the dialog route. Keeping
        // the library viewport fixed prevents Android IME animation from
        // relaying out every visible media card behind that dialog.
        resizeToAvoidBottomInset: false,
        // 关键：设置 extendBody 为 true，让 body 延伸到底部导航栏后面
        // 避免 MiniPlaybackCard 位置偏下
        extendBody: true,
        appBar: AppBar(
          toolbarHeight: useCompactTopBar ? 50 : kToolbarHeight,
          leadingWidth: useCompactTopBar ? 40 : 44,
          titleSpacing: useCompactTopBar ? 3 : 8,
          title: _isSelectionMode
              ? MediaLibrarySelectionDropTargets(
                  hasSelectedItems: _selectedIds.isNotEmpty,
                  onMoveToRecycleBin: (draggedIndex) {
                    unawaited(
                      _moveItemsToRecycleBin(draggedIndex: draggedIndex),
                    );
                  },
                )
              : rootNavPlan.hideSwitcher
              ? const MediaLibraryCompactTitle(text: '我的媒体库')
              : ValueListenableBuilder<MediaLibraryRootEntry?>(
                  valueListenable: _rootEntryOverride,
                  builder: (context, selectedOverride, child) {
                    return ValueListenableBuilder<List<MediaLibraryRootEntry>>(
                      valueListenable: _rootEntryOrder,
                      builder: (context, order, child) {
                        return ValueListenableBuilder<bool>(
                          valueListenable: _rootSwipeSettled,
                          builder: (context, settled, child) {
                            return ValueListenableBuilder<double>(
                              valueListenable: _rootSwipeHighlight,
                              builder: (context, highlight, child) {
                                return MediaLibraryEntrySwitcher(
                                  selected: _effectiveRootEntry(rootNavPlan),
                                  highlightIndex: highlight,
                                  entries: order,
                                  availableEntries: _mountedRootEntries,
                                  compact: useCompactTopBar,
                                  reorderEnabled:
                                      settled && !_isSelectionMode,
                                  onReorder: (oldIndex, newIndex) =>
                                      _onRootEntryReorder(
                                        oldIndex,
                                        newIndex,
                                        settings,
                                        rootNavPlan,
                                      ),
                                  onSelected: (entry) =>
                                      _selectRootEntry(entry, settings),
                                );
                              },
                            );
                          },
                        );
                      },
                    );
                  },
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
                        onPressed: _exitSelectionMode,
                        tooltip: _managementTooltip(
                          "退出选择",
                          DesktopMediaManagementShortcutAction
                              .backOrExitSelection,
                        ),
                      ))
              : widget.returnToSearchResults
              ? (useCompactTopBar
                    ? MediaLibraryCompactIconButton(
                        icon: Icons.arrow_back,
                        tooltip: '返回搜索结果',
                        onPressed: () => Navigator.of(context).maybePop(),
                      )
                    : IconButton(
                        icon: const Icon(Icons.arrow_back),
                        tooltip: '返回搜索结果',
                        onPressed: () => Navigator.of(context).maybePop(),
                      ))
              : (useCompactTopBar
                    ? MediaLibraryCompactIconButton(
                        icon: settings.mediaLibraryViewMode == 0
                            ? Icons.view_list_rounded
                            : Icons.grid_view_rounded,
                        color: settings.mediaLibraryViewMode == 0
                            ? Colors.white70
                            : Colors.blueAccent,
                        tooltip: settings.mediaLibraryViewMode == 0
                            ? '切换列表视图'
                            : '切换卡片视图',
                        onPressed: () {
                          final nextMode = settings.mediaLibraryViewMode == 0
                              ? 1
                              : 0;
                          settings.updateSetting(
                            'mediaLibraryViewMode',
                            nextMode,
                          );
                        },
                      )
                    : IconButton(
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
                      )),
          actions: useCompactTopBar
              ? _buildCompactTopBarActions(settings)
              : [
                  ResponsiveActionButtons(
                    spacing: 2,
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
                        if (Platform.isWindows || Platform.isLinux)
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
                        ResponsiveIconButton(
                          icon: Icons.search_rounded,
                          tooltip: _managementTooltip(
                            "搜索媒体库",
                            DesktopMediaManagementShortcutAction.openSearch,
                          ),
                          onPressed: _openSearch,
                        ),
                        AnimatedBuilder(
                          animation: MediaPlaybackService().sleepTimer,
                          builder: (context, _) {
                            final timer = MediaPlaybackService().sleepTimer;
                            return ResponsiveIconButton(
                              icon: timer.isActive
                                  ? Icons.alarm_on_rounded
                                  : Icons.schedule_rounded,
                              color: timer.isActive ? Colors.blueAccent : null,
                              tooltip: _managementTooltip(
                                timer.isActive ? timer.statusText : '定时关闭',
                                DesktopMediaManagementShortcutAction
                                    .openSleepTimer,
                              ),
                              onPressed: () =>
                                  unawaited(showSleepTimerDialog(context)),
                            );
                          },
                        ),
                        ResponsiveIconButton(
                          icon: Icons.delete_outline,
                          tooltip: _managementTooltip(
                            "回收站",
                            DesktopMediaManagementShortcutAction.openRecycleBin,
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
                            DesktopMediaManagementShortcutAction.openCardStyle,
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
                          onPressed: () => showMediaLibrarySettingsBottomSheet(
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
                          onPressed: _toggleSelectAllOnHome,
                        ),
                      ],
                    ],
                  ),
                ],
          bottom: const MediaLibraryTopBarImportProgress(),
        ),
        // 使用 MediaQuery.removePadding 移除底部 padding，
        // 避免退出横屏播放页后 MiniPlaybackCard 位置偏下
        body: MediaQuery.removePadding(
          context: context,
          removeBottom: true,
          child: Focus(
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
              child: Consumer<LibraryService>(
                builder: (context, library, child) {
                  final contents = library.getContents(null);
                  _scheduleRevealIfNeeded(contents);

                  return DropTarget(
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
                          null,
                        );
                      }
                    },
                    onDragEntered: (_) {
                      if (ModalRoute.of(context)?.isCurrent != true) return;
                      setState(() => _isDraggingFiles = true);
                    },
                    onDragExited: (_) =>
                        setState(() => _isDraggingFiles = false),
                    child: ValueListenableBuilder<MediaLibraryRootEntry?>(
                      valueListenable: _rootEntryOverride,
                      builder: (context, selectedOverride, child) {
                        final displayed = _effectiveRootEntry(rootNavPlan);
                        final showingVirtual =
                            !rootNavPlan.forceFoldersForLocate &&
                            displayed != MediaLibraryRootEntry.folders;
                        return Stack(
                      children: [
                        if (!showingVirtual && contents.isEmpty)
                          Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.folder_open,
                                  size: 80,
                                  color: Colors.white24,
                                ),
                                const SizedBox(height: 16),
                                const Text(
                                  "还没有内容",
                                  style: TextStyle(color: Colors.white54),
                                ),
                              ],
                            ),
                          )
                        else ...[
                          Listener(
                            onPointerDown: (event) {
                              _activePointerKind = event.kind;
                            },
                            child: RawGestureDetector(
                              gestures: {
                                _MouseOrPinchScaleRecognizer:
                                    GestureRecognizerFactoryWithHandlers<
                                      _MouseOrPinchScaleRecognizer
                                    >(
                                      () => _MouseOrPinchScaleRecognizer(),
                                      (recognizer) {
                                        recognizer
                                          ..onStart = (details) {
                                            if (_tryStartMouseBoxSelection(
                                              pointerCount: details.pointerCount,
                                              globalPos: details.focalPoint,
                                            )) {
                                              return;
                                            }
                                            _baseCrossAxisCount =
                                                settings.mediaLibraryViewMode ==
                                                    1
                                                ? _listStyle().crossAxisCount
                                                : _homeCardStyle()
                                                      .crossAxisCount;
                                          }
                                          ..onUpdate = (details) {
                                            if (_isBoxSelecting) {
                                              _applyMouseBoxSelectionAt(
                                                details.focalPoint,
                                              );
                                              _syncSelectionAutoScroll(
                                                details.focalPoint,
                                              );
                                              return;
                                            }
                                            if (details.pointerCount < 2) {
                                              return;
                                            }

                                            double newScale = details.scale;
                                            int newCount = _baseCrossAxisCount;

                                            if (newScale > 1.3) {
                                              newCount =
                                                  (_baseCrossAxisCount - 1)
                                                      .clamp(1, 20);
                                            } else if (newScale < 0.7) {
                                              newCount =
                                                  (_baseCrossAxisCount + 1)
                                                      .clamp(1, 20);
                                            }

                                            final currentCount =
                                                settings.mediaLibraryViewMode ==
                                                    1
                                                ? _listStyle().crossAxisCount
                                                : _homeCardStyle()
                                                      .crossAxisCount;
                                            if (newCount != currentCount) {
                                              final size = MediaQuery.sizeOf(
                                                context,
                                              );
                                              if (settings
                                                      .mediaLibraryViewMode ==
                                                  1) {
                                                unawaited(
                                                  settings.updateListStyleFor(
                                                    size,
                                                    crossAxisCount: newCount,
                                                  ),
                                                );
                                              } else {
                                                unawaited(
                                                  settings
                                                      .updateHomeCardStyleFor(
                                                    size,
                                                    crossAxisCount: newCount,
                                                  ),
                                                );
                                              }
                                            }
                                          }
                                          ..onEnd = (details) {
                                            if (_isBoxSelecting) {
                                              _finishMouseBoxSelection();
                                            }
                                          };
                                      },
                                    ),
                              },
                              child: Selector<MediaPlaybackService, bool>(
                                selector: (_, playbackService) =>
                                    playbackService.shouldShowMiniPlaybackCard,
                                builder: (context, isCardVisible, child) {

                                  double cardBottomPadding = 0.0;
                                  if (isCardVisible ||
                                      _hasPendingPlaybackState) {
                                    final cardHeight =
                                        PlaybackCardLayout.calculate(
                                          context,
                                        ).height;
                                    cardBottomPadding =
                                        playbackCardBottom + cardHeight;
                                  }

                                  return ValueListenableBuilder<
                                    List<MediaLibraryRootEntry>
                                  >(
                                    valueListenable: _rootEntryOrder,
                                    builder: (context, order, child) {
                                      return MediaLibraryRootSurfaceHost(
                                    key: _rootSurfaceHostKey,
                                    displayedEntry: displayed,
                                    entryOrder: order,
                                    swipeEnabled: !_isSelectionMode,
                                    swipeHighlightIndex: _rootSwipeHighlight,
                                    swipeSettled: _rootSwipeSettled,
                                    onUserSwipe: (entry) =>
                                        _selectRootEntry(entry, settings),
                                    continueBuilder: (context, active) {
                                      return MediaLibraryContinueView(
                                        isActive: active,
                                        scrollController:
                                            _continueScrollController,
                                        cardBottomPadding: cardBottomPadding,
                                        onOpenMedia: (item) {
                                          final playback =
                                              Provider.of<
                                                MediaPlaybackService
                                              >(context, listen: false);
                                          final controller =
                                              playback.currentItem?.id ==
                                                  item.id
                                              ? playback.controller
                                              : null;
                                          _openPlaybackScreen(
                                            item,
                                            existingController: controller,
                                          );
                                        },
                                        onOpenFolder: (collection) {
                                          Navigator.of(context).push(
                                            MaterialPageRoute<void>(
                                              builder: (_) => CollectionScreen(
                                                collectionId: collection.id,
                                              ),
                                            ),
                                          );
                                        },
                                        onLocateMedia: _locateLibraryItem,
                                        onGoRecent: () => _selectRootEntry(
                                          MediaLibraryRootEntry.recent,
                                          settings,
                                        ),
                                        onGoFolders: () => _selectRootEntry(
                                          MediaLibraryRootEntry.folders,
                                          settings,
                                        ),
                                      );
                                    },
                                    recentBuilder: (context, active) {
                                      return MediaLibraryRecentView(
                                        isActive: active,
                                        scrollController:
                                            _recentScrollController,
                                        cardBottomPadding: cardBottomPadding,
                                        expandBatchId: _pendingRecentBatchId,
                                        onOpenMedia: (item) {
                                          final playback =
                                              Provider.of<
                                                MediaPlaybackService
                                              >(context, listen: false);
                                          final controller =
                                              playback.currentItem?.id ==
                                                  item.id
                                              ? playback.controller
                                              : null;
                                          _openPlaybackScreen(
                                            item,
                                            existingController: controller,
                                          );
                                        },
                                        onLocateMedia: _locateLibraryItem,
                                      );
                                    },
                                    foldersBuilder: (context, active) {
                                      return _buildMediaGridOrList(
                                        context: context,
                                        library: library,
                                        settings: settings,
                                        contents: contents,
                                        cardBottomPadding: cardBottomPadding,
                                        isActive: active,
                                      );
                                    },
                                  );
                                    },
                                  );
                                },
                              ),
                            ),
                          ),
                          if (!showingVirtual && contents.length < 20)
                            Positioned.fill(
                              key: MediaLibraryOverlayKeys.emptySpaceHitTarget,
                              child: Listener(
                                behavior: HitTestBehavior.translucent,
                                onPointerDown: (_) {},
                              ),
                            ),
                          if (!showingVirtual &&
                              _isBoxSelecting &&
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
                                return IgnorePointer(
                                  ignoring: true,
                                  child: Container(
                                    height: playbackCardBottom,
                                    color: const Color(0xFF2C2C2C),
                                  ),
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
                                  onTap: () {
                                    // 点击卡片进入全屏播放页面
                                    unawaited(
                                      PlaybackNavigationService.instance
                                          .openCurrentPlaybackSession(
                                            playbackService,
                                            expectedGeneration: playbackService
                                                .sessionGeneration,
                                          ),
                                    );
                                  },
                                );
                              },
                            ),
                          ),
                        ],
                        if (_isDraggingFiles)
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
                    );
                      },
                    ),
                  );
                },
              ),
            ),
          ), // 关闭 MediaQuery.removePadding 的 child
        ), // 关闭 body: MediaQuery.removePadding(...)
        floatingActionButtonLocation: const PlaybackActionButtonsLocation(),
        floatingActionButton: !_isSelectionMode
            ? Consumer<MediaPlaybackService>(
                builder: (context, playbackService, child) {
                  final isCardVisible =
                      _hasPendingPlaybackState ||
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
                      collectionId: null,
                      maxExpandedHeight: maxExpandedHeight,
                    ),
                  );
                },
              )
            : null,
        bottomNavigationBar: _isSelectionMode && _selectedIds.isNotEmpty
            ? MediaLibrarySelectionBottomBar(
                onMoveToRecycleBin: () {
                  unawaited(_moveItemsToRecycleBin());
                },
                onExportFluentPack: () {
                  final ids = _selectedIds.toList();
                  setState(() {
                    _selectedIds.clear();
                    _isSelectionMode = false;
                  });
                  unawaited(
                    PortableTransferNavigation.openExportSettings(context, ids),
                  );
                },
                onRename: _selectedIds.length == 1
                    ? () {
                        final library = Provider.of<LibraryService>(
                          context,
                          listen: false,
                        );
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
    );
  }

  Widget _buildMediaGridOrList({
    required BuildContext context,
    required LibraryService library,
    required SettingsService settings,
    required List<dynamic> contents,
    required double cardBottomPadding,
    required bool isActive,
  }) {
    if (settings.mediaLibraryViewMode == 0) {
      final metrics = MediaLibraryLayoutDefaults.cardGrid(
        screenSize: MediaQuery.sizeOf(context),
        style: settings.homeCardStyleFor(MediaQuery.sizeOf(context)),
      );
      return MediaLibraryFrozenWhenInactive(
        active: isActive,
        child: GridView.builder(
        controller: _scrollController,
        padding: EdgeInsets.only(
          left: metrics.outerPadding,
          right: metrics.outerPadding,
          top: metrics.topPadding,
          bottom: metrics.outerPadding + cardBottomPadding,
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
      ),
    );
    }

    return MediaLibraryFrozenWhenInactive(
      active: isActive,
      child: LayoutBuilder(
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
            bottom: metrics.outerPadding + cardBottomPadding,
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
      ),
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
        setState(() {
          if (_selectedIds.contains(collection.id)) {
            _selectedIds.remove(collection.id);
          } else {
            _selectedIds.add(collection.id);
          }
        });
      } else {
        Navigator.of(context)
            .push(
              MaterialPageRoute(
                builder: (context) =>
                    CollectionScreen(collectionId: collection.id),
              ),
            )
            .then((_) {
              if (!mounted) return;
              unawaited(
                Provider.of<SettingsService>(
                  context,
                  listen: false,
                ).updateSetting('mediaLibraryLastFolderId', ''),
              );
            });
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
      onReorder: (oldIndex, newIndex) {
        _reorderMediaItems(library, contents, null, oldIndex, newIndex);
      },
      folderId: collection.id,
      onMoveToFolder: (draggedIndex, targetId) async {
        await _moveMediaItemsToFolder(
          library,
          contents,
          currentParentId: null,
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
        setState(() {
          if (_selectedIds.contains(item.id)) {
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
      onReorder: (oldIndex, newIndex) {
        _reorderMediaItems(library, contents, null, oldIndex, newIndex);
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
        final textInset = MediaLibraryActionDockMetrics.textInset(
          chipSize: chipSize,
          showMore: showMenu,
          showLocate: false,
          existingPadding:
              MediaListLayoutMetrics.cardGridContentPadding(cardWidth).right,
        );
        final double radius = (cardWidth * 0.09).clamp(4.0, 40.0);
        final double titleFontSize = _resolveCardTitleFontSize(
          cardWidth,
          settings.homeCardStyleFor(MediaQuery.sizeOf(context)).titleScale,
        );
        final double metaFontSize = _resolveCardMetaFontSize(titleFontSize);
        final isSelected = _selectedIds.contains(collection.id);
        final thumbnailPath = collection.thumbnailPath;
        final hasThumbnail = thumbnailPath != null && thumbnailPath.isNotEmpty;

        // 1. The Visual Content of the Card
        Widget cardVisual = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Thumbnail Area (Fixed Folder Icon)
            AspectRatio(
              aspectRatio: _mediaCardCoverAspectRatio,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final iconSize = constraints.maxWidth * 0.15;
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
            setState(() {
              if (isSelected) {
                _selectedIds.remove(collection.id);
              } else {
                _selectedIds.add(collection.id);
              }
            });
          } else {
            Navigator.of(context)
                .push(
                  MaterialPageRoute(
                    builder: (context) =>
                        CollectionScreen(collectionId: collection.id),
                  ),
                )
                .then((_) {
                  if (!mounted) return;
                  unawaited(
                    Provider.of<SettingsService>(
                      context,
                      listen: false,
                    ).updateSetting('mediaLibraryLastFolderId', ''),
                  );
                });
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
                      currentParentId: null,
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
                      null,
                      itemsToMove,
                      oldIndex,
                      newIndex,
                    );
                  } else {
                    library.reorderItems(null, oldIndex, newIndex);
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
        final textInset = MediaLibraryActionDockMetrics.textInset(
          chipSize: chipSize,
          showMore: showMenu,
          showLocate: false,
          existingPadding:
              MediaListLayoutMetrics.cardGridContentPadding(cardWidth).right,
        );
        final double radius = (cardWidth * 0.09).clamp(4.0, 40.0);
        final double titleFontSize = _resolveCardTitleFontSize(
          cardWidth,
          settings.homeCardStyleFor(MediaQuery.sizeOf(context)).titleScale,
        );
        final double metaFontSize = _resolveCardMetaFontSize(titleFontSize);
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
            setState(() {
              if (isSelected) {
                _selectedIds.remove(item.id);
              } else {
                _selectedIds.add(item.id);
              }
            });
          } else {
            // 通过 MediaPlaybackService 开始播放
            final playbackService = Provider.of<MediaPlaybackService>(
              context,
              listen: false,
            );
            // 进入播放页面
            if (!mounted) return;

            // 仅当当前播放的视频与点击的视频一致时，才复用控制器
            // 否则传入 null，让 VideoPlayerScreen 自行处理初始化（它会调用 MediaPlaybackService.play）
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
                      child: _selectedIds.length > 1 && isSelected
                          ? Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.movie,
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
                      null,
                      itemsToMove,
                      oldIndex,
                      index,
                    );
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

  Future<void> _showLargeDataPathDialog(BuildContext context) async {
    if (!(Platform.isWindows || Platform.isLinux)) return;
    final settings = Provider.of<SettingsService>(context, listen: false);
    final library = Provider.of<LibraryService>(context, listen: false);
    final defaultPath = await settings.getDefaultLargeDataRootPath();
    // Linux uses app-data root (migrate stays Windows-only); still show path.
    String tempPath = Platform.isWindows
        ? (settings.largeDataRootPath ?? defaultPath)
        : (await settings.resolveLargeDataRootDir()).path;

    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
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
              if (Platform.isWindows)
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          try {
                            final result = await FilePicker.platform
                                .getDirectoryPath();
                            if (result != null && result.isNotEmpty) {
                              if (mounted) {
                                setState(() => tempPath = result);
                              }
                            }
                          } catch (e) {
                            debugPrint('选择目录失败: $e');
                            if (mounted) {
                              AppToast.show(
                                '选择目录失败: $e',
                                type: AppToastType.error,
                              );
                            }
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
                        onPressed: () => setState(() => tempPath = defaultPath),
                        child: const Text(
                          "恢复默认",
                          style: TextStyle(color: Colors.white70),
                        ),
                      ),
                    ),
                  ],
                ),
              if (Platform.isWindows) const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () async {
                    final opened = await revealInFileManager(tempPath);
                    if (!opened && mounted) {
                      AppToast.show(
                        '无法在文件管理器中显示',
                        type: AppToastType.error,
                      );
                    }
                  },
                  child: const Text(
                    "在文件管理器中显示",
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              ),
              if (Platform.isWindows) ...[
                const SizedBox(height: 8),
                const Text(
                  "修改后会迁移媒体库视频、缩略图和字幕到新目录。",
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
              if (Platform.isLinux) ...[
                const SizedBox(height: 8),
                const Text(
                  "Linux 使用应用数据目录；此处可在文件管理器中打开当前路径。目录迁移仍仅支持 Windows。",
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("取消", style: TextStyle(color: Colors.grey)),
            ),
            if (Platform.isWindows)
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
              )
            else
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4F7BF5),
                  foregroundColor: Colors.white,
                ),
                child: const Text("关闭"),
              ),
          ],
        ),
      ),
    );
  }
}

/// One-finger touch must not become a scale pan: that would steal vertical
/// scrolling and the adjacent-tab swipe. Mouse still uses one pointer for
/// box select; pinch still needs two fingers.
class _MouseOrPinchScaleRecognizer extends ScaleGestureRecognizer {
  int _touchPointers = 0;

  bool _isTouchLike(PointerDeviceKind kind) {
    return kind == PointerDeviceKind.touch || kind == PointerDeviceKind.stylus;
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (_isTouchLike(event.kind)) {
      _touchPointers++;
    }
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (_isTouchLike(event.kind) &&
        (event is PointerUpEvent || event is PointerCancelEvent) &&
        _touchPointers > 0) {
      _touchPointers--;
    }
    if (event is PointerMoveEvent &&
        _isTouchLike(event.kind) &&
        _touchPointers < 2) {
      return;
    }
    super.handleEvent(event);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _touchPointers = 0;
    super.didStopTrackingLastPointer(pointer);
  }
}
