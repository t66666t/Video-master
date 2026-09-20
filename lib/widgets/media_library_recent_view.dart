import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/media_library_group_expand_policy.dart';
import '../models/video_item.dart';
import '../services/library_activity_projection.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import 'media_library_browse_grid_cards.dart';
import 'media_library_group_header.dart';
import 'media_library_layout_profile.dart';
import 'media_library_list_tile.dart';
import 'media_list_layout_metrics.dart';

/// Recently-added surface hosted by HomeScreen. Batches are grouping chrome,
/// not folders, and members are built lazily.
class MediaLibraryRecentView extends StatefulWidget {
  const MediaLibraryRecentView({
    super.key,
    required this.scrollController,
    required this.cardBottomPadding,
    required this.onOpenMedia,
    required this.onLocateMedia,
    this.expandBatchId,
    this.isActive = true,
  });

  final ScrollController scrollController;
  final double cardBottomPadding;
  final ValueChanged<VideoItem> onOpenMedia;
  final ValueChanged<VideoItem> onLocateMedia;
  final String? expandBatchId;

  /// Hidden keep-alive copies skip Provider watches and reuse the last tree.
  final bool isActive;

  @override
  State<MediaLibraryRecentView> createState() => _MediaLibraryRecentViewState();
}

class _MediaLibraryRecentViewState extends State<MediaLibraryRecentView> {
  final MediaLibraryGroupExpandMemory _expand = MediaLibraryGroupExpandMemory();
  final Map<String, GlobalKey> _headerKeys = <String, GlobalKey>{};
  String? _topRowId;
  bool _userScrolled = false;
  bool _showNewContentHint = false;
  Widget? _frozenSubtree;
  LibraryService? _library;
  bool _libraryChangedWhileAway = false;
  bool _tryReuseFrozen = false;
  int? _frozenViewMode;
  double? _frozenBottomPadding;

  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_onScroll);
    _expandRequestedBatch();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final library = context.read<LibraryService>();
    if (!identical(library, _library)) {
      _library?.removeListener(_onLibraryQuiet);
      _library = library;
      _library!.addListener(_onLibraryQuiet);
    }
  }

  @override
  void didUpdateWidget(covariant MediaLibraryRecentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController.removeListener(_onScroll);
      widget.scrollController.addListener(_onScroll);
    }
    if (oldWidget.expandBatchId != widget.expandBatchId) {
      _expandRequestedBatch();
      _tryReuseFrozen = false;
    }
    if (widget.isActive && !oldWidget.isActive) {
      _tryReuseFrozen = true;
    }
  }

  @override
  void dispose() {
    _library?.removeListener(_onLibraryQuiet);
    widget.scrollController.removeListener(_onScroll);
    super.dispose();
  }

  void _onLibraryQuiet() {
    if (!mounted || widget.isActive) return;
    _libraryChangedWhileAway = true;
  }

  void _onScroll() {
    if (!widget.scrollController.hasClients) return;
    if (widget.scrollController.offset > 24) {
      _userScrolled = true;
    }
  }

  void _expandRequestedBatch() {
    final batchId = widget.expandBatchId;
    if (batchId == null || batchId.isEmpty) return;
    _expand.forceOpen('batch:$batchId');
  }

  void _syncNewContentHint(List<RecentAddedEntry> entries) {
    final nextTop = entries.isEmpty ? null : entries.first.rowId;
    if (_topRowId == null) {
      _topRowId = nextTop;
      return;
    }
    if (nextTop == _topRowId) return;
    final atTop =
        !widget.scrollController.hasClients ||
        widget.scrollController.offset <= 24;
    if (atTop && !_userScrolled) {
      setState(() {
        _topRowId = nextTop;
        _showNewContentHint = false;
      });
      return;
    }
    if (!_showNewContentHint) {
      setState(() => _showNewContentHint = true);
    }
  }

  Future<void> _jumpToNewContent() async {
    if (!widget.scrollController.hasClients) return;
    await widget.scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
    if (!mounted) return;
    setState(() {
      _showNewContentHint = false;
      _userScrolled = false;
      final library = context.read<LibraryService>();
      final entries = library.activityProjection.recentAddedEntries();
      _topRowId = entries.isEmpty ? null : entries.first.rowId;
    });
  }

  bool _canReuseFrozen(SettingsService settings) {
    return _tryReuseFrozen &&
        _frozenSubtree != null &&
        !_libraryChangedWhileAway &&
        _frozenViewMode == settings.mediaLibraryViewMode &&
        _frozenBottomPadding == widget.cardBottomPadding;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isActive) {
      context.read<LibraryService>();
      context.read<SettingsService>();
      _tryReuseFrozen = false;
      return _frozenSubtree ?? const SizedBox.expand();
    }
    final library = context.watch<LibraryService>();
    final settings = context.watch<SettingsService>();
    if (_canReuseFrozen(settings)) {
      _tryReuseFrozen = false;
      _libraryChangedWhileAway = false;
      return _frozenSubtree!;
    }
    _tryReuseFrozen = false;
    _libraryChangedWhileAway = false;
    final entries = library.activityProjection.recentAddedEntries();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.isActive) return;
      _syncNewContentHint(entries);
    });

    if (entries.isEmpty) {
      _frozenViewMode = settings.mediaLibraryViewMode;
      _frozenBottomPadding = widget.cardBottomPadding;
      _frozenSubtree = const Center(
        child: Text('还没有最近添加', style: TextStyle(color: Colors.white54)),
      );
      return _frozenSubtree!;
    }

    final useList = settings.mediaLibraryViewMode == 1;
    final screenSize = MediaQuery.sizeOf(context);
    // Match 文件夹: first-row inset equals mainSpacing so cards sit off the app bar.
    final double topGap;
    if (useList) {
      final listStyle = settings.listStyleFor(screenSize);
      topGap = MediaListLayoutMetrics.forGrid(
        screenShortestSide: screenSize.shortestSide,
        availableWidth: screenSize.width,
        crossAxisCount: listStyle.crossAxisCount,
        heightSetting: listStyle.heightScale,
        titleSetting: listStyle.titleScale,
        mainSpacingSetting: listStyle.mainSpacingScale,
        crossSpacingSetting: listStyle.crossSpacingScale,
      ).topPadding;
    } else {
      topGap = MediaLibraryLayoutDefaults.cardGrid(
        screenSize: screenSize,
        style: settings.collectionCardStyleFor(screenSize),
      ).topPadding;
    }
    _frozenViewMode = settings.mediaLibraryViewMode;
    _frozenBottomPadding = widget.cardBottomPadding;
    _frozenSubtree = Stack(
      children: [
        CustomScrollView(
          controller: widget.scrollController,
          slivers: [
            SliverToBoxAdapter(child: SizedBox(height: topGap)),
            ..._sliversForEntries(
              context: context,
              library: library,
              settings: settings,
              entries: entries,
              useList: useList,
            ),
            SliverToBoxAdapter(
              child: SizedBox(height: 24 + widget.cardBottomPadding),
            ),
          ],
        ),
        if (_showNewContentHint)
          Positioned(
            top: 12,
            left: 0,
            right: 0,
            child: Center(
              child: Material(
                color: const Color(0xFF2A2A2A),
                borderRadius: BorderRadius.circular(20),
                child: InkWell(
                  onTap: () => unawaitedJump(),
                  borderRadius: BorderRadius.circular(20),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    child: Text(
                      '有新添加内容',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    return _frozenSubtree!;
  }

  void unawaitedJump() {
    // Ignore the Future; scroll completion updates state in [_jumpToNewContent].
    _jumpToNewContent();
  }

  List<Widget> _sliversForEntries({
    required BuildContext context,
    required LibraryService library,
    required SettingsService settings,
    required List<RecentAddedEntry> entries,
    required bool useList,
  }) {
    final slivers = <Widget>[];
    var singles = <String>[];
    void flushSingles() {
      if (singles.isEmpty) return;
      slivers.add(
        _memberGridOrListSliver(
          context: context,
          library: library,
          settings: settings,
          ids: List<String>.from(singles),
          useList: useList,
        ),
      );
      singles = <String>[];
    }

    for (final entry in entries) {
      if (entry.kind == RecentAddedKind.single) {
        final id = entry.mediaId;
        if (id != null && library.getVideo(id) != null) {
          singles.add(id);
        }
        continue;
      }
      flushSingles();
      slivers.addAll(
        _sliversForGroup(
          context: context,
          library: library,
          settings: settings,
          entry: entry,
          entries: entries,
          useList: useList,
        ),
      );
    }
    flushSingles();
    return slivers;
  }

  List<Widget> _sliversForGroup({
    required BuildContext context,
    required LibraryService library,
    required SettingsService settings,
    required RecentAddedEntry entry,
    required List<RecentAddedEntry> entries,
    required bool useList,
  }) {

    final newestBatch = _newestMultiItemBatch(entries);
    final count = entry.visibleCount;
    final flat = MediaLibraryGroupExpandPolicy.alwaysExpanded(count);
    final defaultExpanded = MediaLibraryGroupExpandPolicy.recentDefaultExpanded(
      isNewestMultiItemBatch:
          newestBatch != null && newestBatch.rowId == entry.rowId,
      count: count,
      isUnknownBucket: entry.kind == RecentAddedKind.unknown,
    );
    final expanded =
        flat ||
        _expand.isExpanded(entry.rowId, defaultExpanded: defaultExpanded);
    final covers = _coverItems(library, entry.visibleMediaIds);
    final header = SliverToBoxAdapter(
      key: ValueKey(entry.rowId),
      child: KeyedSubtree(
        key: _headerKey(entry.rowId),
        child: MediaLibraryGroupHeader(
          title: entry.groupHeaderLabel(),
          coverItems: covers,
          expanded: expanded,
          showChevron: !flat,
          remainderCount: expanded ? 0 : count,
          onToggle: flat
              ? null
              : () => _toggleGroup(
                  rowId: entry.rowId,
                  currentlyExpanded: expanded,
                  memberCount: count,
                  siblingCounts: {
                    for (final other in entries)
                      if (other.kind != RecentAddedKind.single)
                        other.rowId: other.visibleCount,
                  },
                ),
        ),
      ),
    );
    if (!expanded) return [header];
    return [
      header,
      _memberGridOrListSliver(
        context: context,
        library: library,
        settings: settings,
        ids: entry.visibleMediaIds,
        useList: useList,
      ),
    ];
  }

  RecentAddedEntry? _newestMultiItemBatch(List<RecentAddedEntry> entries) {
    for (final entry in entries) {
      if (entry.kind == RecentAddedKind.single) return null;
      if (entry.kind == RecentAddedKind.batch) return entry;
      return null;
    }
    return null;
  }

  List<VideoItem> _coverItems(LibraryService library, List<String> ids) {
    final out = <VideoItem>[];
    for (final id in ids) {
      if (out.length >= MediaLibraryGroupExpandPolicy.coverPreviewMax) break;
      final item = library.getVideo(id);
      if (item != null) out.add(item);
    }
    return out;
  }

  GlobalKey _headerKey(String rowId) {
    return _headerKeys.putIfAbsent(rowId, GlobalKey.new);
  }

  void _pinHeader(String rowId) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _headerKeys[rowId]?.currentContext;
      if (ctx == null || !ctx.mounted) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.06,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _toggleGroup({
    required String rowId,
    required bool currentlyExpanded,
    required int memberCount,
    required Map<String, int> siblingCounts,
  }) {
    setState(() {
      _expand.toggle(rowId, currentlyExpanded: currentlyExpanded);
      if (!currentlyExpanded &&
          MediaLibraryGroupExpandPolicy.isHuge(memberCount)) {
        siblingCounts.forEach((id, count) {
          if (id == rowId) return;
          if (MediaLibraryGroupExpandPolicy.isHuge(count)) {
            _expand.collapse(id);
          }
        });
      }
    });
    if (!currentlyExpanded &&
        memberCount >
            MediaLibraryGroupExpandPolicy.recentLatestAutoExpandMaxItems) {
      _pinHeader(rowId);
    }
  }

  Widget _memberGridOrListSliver({
    required BuildContext context,
    required LibraryService library,
    required SettingsService settings,
    required List<String> ids,
    required bool useList,
  }) {
    if (useList) {
      return _memberListSliver(library, settings, ids);
    }
    return _memberGridSliver(context, library, settings, ids);
  }

  Widget _memberListSliver(
    LibraryService library,
    SettingsService settings,
    List<String> ids,
  ) {
    final listStyle = settings.listStyleFor(MediaQuery.sizeOf(context));
    final metrics = MediaListLayoutMetrics.forGrid(
      screenShortestSide: MediaQuery.sizeOf(context).shortestSide,
      availableWidth: MediaQuery.sizeOf(context).width,
      crossAxisCount: listStyle.crossAxisCount,
      heightSetting: listStyle.heightScale,
      titleSetting: listStyle.titleScale,
      mainSpacingSetting: listStyle.mainSpacingScale,
      crossSpacingSetting: listStyle.crossSpacingScale,
    );
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: metrics.outerPadding),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: listStyle.crossAxisCount,
          mainAxisExtent: metrics.rowHeight,
          crossAxisSpacing: metrics.crossSpacing,
          mainAxisSpacing: metrics.mainSpacing,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          final item = library.getVideo(ids[index]);
          if (item == null) return const SizedBox.shrink();
          return _mediaTile(
            context: context,
            library: library,
            settings: settings,
            item: item,
            index: index,
            useList: true,
            listStyle: listStyle,
          );
        }, childCount: ids.length),
      ),
    );
  }

  Widget _memberGridSliver(
    BuildContext context,
    LibraryService library,
    SettingsService settings,
    List<String> ids,
  ) {
    final metrics = MediaLibraryLayoutDefaults.cardGrid(
      screenSize: MediaQuery.sizeOf(context),
      style: settings.collectionCardStyleFor(MediaQuery.sizeOf(context)),
    );
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: metrics.outerPadding),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: metrics.crossAxisCount,
          childAspectRatio: metrics.aspectRatio.clamp(0.1, 5.0),
          crossAxisSpacing: metrics.crossSpacing,
          mainAxisSpacing: metrics.mainSpacing,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          final item = library.getVideo(ids[index]);
          if (item == null) return const SizedBox.shrink();
          return _mediaTile(
            context: context,
            library: library,
            settings: settings,
            item: item,
            index: index,
            useList: false,
          );
        }, childCount: ids.length),
      ),
    );
  }

  Widget _mediaTile({
    required BuildContext context,
    required LibraryService library,
    required SettingsService settings,
    required VideoItem item,
    required int index,
    required bool useList,
    MediaListStyleSettings? listStyle,
  }) {
    if (useList) {
      final style =
          listStyle ?? settings.listStyleFor(MediaQuery.sizeOf(context));
      return MediaLibraryListTile.video(
        item: item,
        index: index,
        showIndex: style.showIndex,
        showThumbnail: style.showThumbnail,
        isSelected: false,
        isSelectionMode: false,
        titleScale: style.titleScale,
        onTap: () => widget.onOpenMedia(item),
        onShowInParentFolder: () => widget.onLocateMedia(item),
        showActivityMenu: true,
        relativePath: MediaLibraryMediaGridCard.pathFromLibraryRoot(
          library,
          item,
        ),
      );
    }
    return MediaLibraryMediaGridCard(
      item: item,
      titleScale: settings
          .collectionCardStyleFor(MediaQuery.sizeOf(context))
          .titleScale,
      onTap: () => widget.onOpenMedia(item),
      onLocate: () => widget.onLocateMedia(item),
      relativePath: MediaLibraryMediaGridCard.pathFromLibraryRoot(
        library,
        item,
      ),
    );
  }
}
