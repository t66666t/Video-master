import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/media_library_group_expand_policy.dart';
import '../models/video_collection.dart';
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
    this.onOpenFolder,
    this.onLocateFolder,
    this.expandBatchId,
    this.isActive = true,
  });

  final ScrollController scrollController;
  final double cardBottomPadding;
  final ValueChanged<VideoItem> onOpenMedia;
  final ValueChanged<VideoItem> onLocateMedia;
  final ValueChanged<VideoCollection>? onOpenFolder;
  final ValueChanged<VideoCollection>? onLocateFolder;
  final String? expandBatchId;

  /// Hidden keep-alive copies skip Provider watches and reuse the last tree.
  final bool isActive;

  @override
  State<MediaLibraryRecentView> createState() => _MediaLibraryRecentViewState();
}

class _MediaLibraryRecentViewState extends State<MediaLibraryRecentView> {
  final MediaLibraryGroupExpandMemory _expand = MediaLibraryGroupExpandMemory();
  final Map<String, GlobalKey> _headerKeys = <String, GlobalKey>{};
  String? _appliedExpandBatchId;
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
      _appliedExpandBatchId = null;
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

  void _expandRequestedBatch(List<RecentAddedEntry> entries) {
    final batchId = widget.expandBatchId;
    if (batchId == null || batchId.isEmpty) return;
    if (_appliedExpandBatchId == batchId) return;
    _appliedExpandBatchId = batchId;
    for (final entry in entries) {
      if (entry.sourceBatchId == batchId || entry.rowId == 'batch:$batchId') {
        _expand.forceOpen(entry.rowId);
      }
    }
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
    _expandRequestedBatch(entries);
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
    final flow = _flowSpacing(settings, screenSize, useList);
    _frozenViewMode = settings.mediaLibraryViewMode;
    _frozenBottomPadding = widget.cardBottomPadding;
    _frozenSubtree = Stack(
      children: [
        CustomScrollView(
          controller: widget.scrollController,
          slivers: [
            if (flow.gap(flow.leading) case final leading?) leading,
            ..._sliversForEntries(
              context: context,
              library: library,
              settings: settings,
              entries: entries,
              useList: useList,
              flow: flow,
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
    required MediaLibraryFlowSpacing flow,
  }) {
    final slivers = <Widget>[];
    var singles = <RecentAddedChild>[];
    void startRegion() {
      if (slivers.isNotEmpty) flow.addGap(slivers, flow.section);
    }

    void flushSingles() {
      if (singles.isEmpty) return;
      startRegion();
      slivers.add(
        _memberGridOrListSliver(
          context: context,
          library: library,
          settings: settings,
          children: List<RecentAddedChild>.from(singles),
          useList: useList,
        ),
      );
      singles = <RecentAddedChild>[];
    }

    for (final entry in entries) {
      if (entry.kind == RecentAddedKind.single) {
        final id = entry.mediaId;
        if (id != null && library.getVideo(id) != null) {
          singles.add(RecentAddedChild.media(id));
        }
        continue;
      }
      flushSingles();
      startRegion();
      slivers.addAll(
        _sliversForGroup(
          context: context,
          library: library,
          settings: settings,
          entry: entry,
          entries: entries,
          useList: useList,
          flow: flow,
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
    required MediaLibraryFlowSpacing flow,
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
    final covers = _coverItems(library, entry);
    final header = SliverToBoxAdapter(
      key: ValueKey(entry.rowId),
      child: KeyedSubtree(
        key: _headerKey(entry.rowId),
        child: MediaLibraryGroupHeader(
          title: entry.groupHeaderLabel(),
          coverItems: covers,
          expanded: expanded,
          padding: EdgeInsets.symmetric(horizontal: flow.outer),
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
      if (flow.gap(flow.attached) case final attached?) attached,
      _memberGridOrListSliver(
        context: context,
        library: library,
        settings: settings,
        children: entry.children,
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

  List<VideoItem> _coverItems(LibraryService library, RecentAddedEntry entry) {
    final out = <VideoItem>[];
    void takeMedia(String id) {
      if (out.length >= MediaLibraryGroupExpandPolicy.coverPreviewMax) return;
      final item = library.getVideo(id);
      if (item != null) out.add(item);
    }

    void takeFolder(String id) {
      final collection = library.getCollection(id);
      if (collection == null) return;
      for (final childId in collection.childrenIds) {
        if (out.length >= MediaLibraryGroupExpandPolicy.coverPreviewMax) return;
        final item = library.getVideo(childId);
        if (item != null) {
          out.add(item);
          continue;
        }
        if (library.getCollection(childId) != null) takeFolder(childId);
      }
    }

    for (final child in entry.children) {
      if (out.length >= MediaLibraryGroupExpandPolicy.coverPreviewMax) break;
      if (child.kind == RecentAddedChildKind.media) {
        takeMedia(child.id);
      } else {
        takeFolder(child.id);
      }
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

  MediaLibraryFlowSpacing _flowSpacing(
    SettingsService settings,
    Size screenSize,
    bool useList,
  ) {
    return mediaLibraryFlowSpacingFor(
      screenSize: screenSize,
      useList: useList,
      cardStyle: settings.collectionCardStyleFor(screenSize),
      listStyle: settings.listStyleFor(screenSize),
    );
  }

  Widget _memberGridOrListSliver({
    required BuildContext context,
    required LibraryService library,
    required SettingsService settings,
    required List<RecentAddedChild> children,
    required bool useList,
  }) {
    if (useList) {
      return _memberListSliver(library, settings, children);
    }
    return _memberGridSliver(context, library, settings, children);
  }

  Widget _memberListSliver(
    LibraryService library,
    SettingsService settings,
    List<RecentAddedChild> children,
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
          return _childTile(
            context: context,
            library: library,
            settings: settings,
            child: children[index],
            index: index,
            useList: true,
            listStyle: listStyle,
          );
        }, childCount: children.length),
      ),
    );
  }

  Widget _memberGridSliver(
    BuildContext context,
    LibraryService library,
    SettingsService settings,
    List<RecentAddedChild> children,
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
          return _childTile(
            context: context,
            library: library,
            settings: settings,
            child: children[index],
            index: index,
            useList: false,
          );
        }, childCount: children.length),
      ),
    );
  }

  Widget _childTile({
    required BuildContext context,
    required LibraryService library,
    required SettingsService settings,
    required RecentAddedChild child,
    required int index,
    required bool useList,
    MediaListStyleSettings? listStyle,
  }) {
    if (child.kind == RecentAddedChildKind.folder) {
      final collection = library.getCollection(child.id);
      if (collection == null) return const SizedBox.shrink();
      return _folderTile(
        context: context,
        settings: settings,
        collection: collection,
        useList: useList,
        listStyle: listStyle,
      );
    }
    final item = library.getVideo(child.id);
    if (item == null) return const SizedBox.shrink();
    return _mediaTile(
      context: context,
      library: library,
      settings: settings,
      item: item,
      index: index,
      useList: useList,
      listStyle: listStyle,
    );
  }

  Widget _folderTile({
    required BuildContext context,
    required SettingsService settings,
    required VideoCollection collection,
    required bool useList,
    MediaListStyleSettings? listStyle,
  }) {
    final open = widget.onOpenFolder;
    final locate = widget.onLocateFolder;
    if (useList) {
      final style =
          listStyle ?? settings.listStyleFor(MediaQuery.sizeOf(context));
      return MediaLibraryListTile.collection(
        collection: collection,
        index: 0,
        showIndex: false,
        showThumbnail: style.showThumbnail,
        isSelected: false,
        isSelectionMode: false,
        titleScale: style.titleScale,
        onTap: () => open?.call(collection),
        onShowInParentFolder: locate == null
            ? null
            : () => locate(collection),
        showActivityMenu: true,
        allowHide: false,
      );
    }
    return MediaLibraryFolderGridCard(
      collection: collection,
      titleScale: settings
          .collectionCardStyleFor(MediaQuery.sizeOf(context))
          .titleScale,
      onTap: () => open?.call(collection),
      onLocate: locate == null ? null : () => locate(collection),
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
