import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/media_library_group_expand_policy.dart';
import '../models/video_collection.dart';
import '../models/video_item.dart';
import '../services/app_haptics.dart';
import '../services/library_activity_projection.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import 'media_library_browse_grid_cards.dart';
import 'media_library_anchor_menu.dart';
import 'media_library_continue_policy_sheet.dart';
import 'media_library_group_header.dart';
import 'media_library_item_interaction_wrapper.dart';
import 'media_library_layout_profile.dart';
import 'media_library_list_tile.dart';
import 'media_list_layout_metrics.dart';

/// Continue-learning surface: pins on top, then in-progress groups.
class MediaLibraryContinueView extends StatefulWidget {
  const MediaLibraryContinueView({
    super.key,
    required this.scrollController,
    required this.cardBottomPadding,
    required this.onOpenMedia,
    required this.onOpenFolder,
    required this.onLocateMedia,
    required this.onLocateFolder,
    required this.onGoRecent,
    required this.onGoFolders,
    this.isActive = true,
  });

  final ScrollController scrollController;
  final double cardBottomPadding;
  final ValueChanged<VideoItem> onOpenMedia;
  final ValueChanged<VideoCollection> onOpenFolder;
  final ValueChanged<VideoItem> onLocateMedia;
  final ValueChanged<VideoCollection> onLocateFolder;
  final VoidCallback onGoRecent;
  final VoidCallback onGoFolders;

  /// Hidden keep-alive copies skip Provider watches and reuse the last tree.
  final bool isActive;

  @override
  State<MediaLibraryContinueView> createState() =>
      _MediaLibraryContinueViewState();
}

class _MediaLibraryContinueViewState extends State<MediaLibraryContinueView> {
  final MediaLibraryGroupExpandMemory _expand = MediaLibraryGroupExpandMemory();
  final Map<String, GlobalKey> _headerKeys = <String, GlobalKey>{};
  List<String> _frozenRecentKeys = <String>[];
  List<String> _frozenUnknownKeys = <String>[];
  List<String> _frozenHistoryDayKeys = <String>[];
  bool _wasRouteCurrent = true;
  Widget? _frozenSubtree;
  LibraryService? _library;
  bool _libraryChangedWhileAway = false;
  bool _tryReuseFrozen = false;
  int? _frozenViewMode;
  double? _frozenBottomPadding;
  bool? _frozenSeriousOnly;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final library = context.read<LibraryService>();
    if (!identical(library, _library)) {
      _library?.removeListener(_onLibraryQuiet);
      _library = library;
      _library!.addListener(_onLibraryQuiet);
    }
    final isCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    if (isCurrent && !_wasRouteCurrent) {
      _frozenRecentKeys = <String>[];
      _frozenUnknownKeys = <String>[];
      _frozenHistoryDayKeys = <String>[];
      _expand.clear();
      _tryReuseFrozen = false;
    }
    _wasRouteCurrent = isCurrent;
  }

  @override
  void didUpdateWidget(covariant MediaLibraryContinueView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _tryReuseFrozen = true;
    }
  }

  @override
  void dispose() {
    _library?.removeListener(_onLibraryQuiet);
    super.dispose();
  }

  void _onLibraryQuiet() {
    if (!mounted || widget.isActive) return;
    _libraryChangedWhileAway = true;
  }

  List<ContinueLearningGroup> _stabilize(
    List<String> frozen,
    List<ContinueLearningGroup> live,
  ) {
    final liveMap = <String, ContinueLearningGroup>{
      for (final group in live) group.rowId: group,
    };
    final out = <ContinueLearningGroup>[];
    for (final key in frozen) {
      final group = liveMap.remove(key);
      if (group != null) out.add(group);
    }
    for (final group in live) {
      if (liveMap.containsKey(group.rowId)) out.add(group);
    }
    return out;
  }

  List<PlaybackHistoryDayGroup> _stabilizeDays(
    List<String> frozen,
    List<PlaybackHistoryDayGroup> live,
  ) {
    final liveMap = <String, PlaybackHistoryDayGroup>{
      for (final group in live) group.rowId: group,
    };
    final out = <PlaybackHistoryDayGroup>[];
    for (final key in frozen) {
      final group = liveMap.remove(key);
      if (group != null) out.add(group);
    }
    for (final group in live) {
      if (liveMap.containsKey(group.rowId)) out.add(group);
    }
    return out;
  }

  String _folderTitle(LibraryService library, ContinueLearningGroup group) {
    if (group.parentId == null) return '根目录';
    return library.getCollection(group.parentId!)?.name ?? '未知目录';
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
    if (_tryReuseFrozen &&
        _frozenSubtree != null &&
        !_libraryChangedWhileAway &&
        _frozenViewMode == settings.mediaLibraryViewMode &&
        _frozenBottomPadding == widget.cardBottomPadding &&
        _frozenSeriousOnly == settings.mediaLibraryContinueSeriousOnly) {
      _tryReuseFrozen = false;
      _libraryChangedWhileAway = false;
      return _frozenSubtree!;
    }
    _tryReuseFrozen = false;
    _libraryChangedWhileAway = false;
    final projection = library.activityProjection;
    final seriousOnly = settings.mediaLibraryContinueSeriousOnly;
    final pins = projection.visiblePinnedIds();
    final sections = projection.continueLearningSections(
      policy: settings.continueWatchPolicy,
    );
    final recent = _stabilize(_frozenRecentKeys, sections.recent);
    final unknown = _stabilize(_frozenUnknownKeys, sections.unknown);
    final historyDays = _stabilizeDays(
      _frozenHistoryDayKeys,
      projection.playbackHistoryDayGroups(),
    );
    _frozenRecentKeys = recent.map((group) => group.rowId).toList();
    _frozenUnknownKeys = unknown.map((group) => group.rowId).toList();
    _frozenHistoryDayKeys = historyDays.map((group) => group.rowId).toList();
    final recordsEmpty = seriousOnly
        ? recent.isEmpty && unknown.isEmpty
        : historyDays.isEmpty;

    final useList = settings.mediaLibraryViewMode == 1;
    final flow = _flowSpacing(settings, useList);
    _frozenViewMode = settings.mediaLibraryViewMode;
    _frozenBottomPadding = widget.cardBottomPadding;
    _frozenSeriousOnly = seriousOnly;
    _frozenSubtree = Material(
      color: Colors.transparent,
      child: CustomScrollView(
        controller: widget.scrollController,
        slivers: [
          SliverToBoxAdapter(child: _filterTile(settings, flow)),
          if (pins.isEmpty && recordsEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _emptyBody(seriousOnly, historyDays.isNotEmpty),
            )
          else ...[
            if (pins.isNotEmpty) ...[
              ..._sectionSlivers(
                flow,
                title: '置顶',
                beforeTitle: flow.attached,
                body: [
                  _idGridOrListSliver(
                    library: library,
                    settings: settings,
                    ids: pins,
                    useList: useList,
                    pinMode: true,
                  ),
                ],
              ),
            ],
            if (seriousOnly) ...[
              if (recent.isNotEmpty)
                ..._sectionSlivers(
                  flow,
                  title: '最近在看',
                  beforeTitle: pins.isEmpty ? flow.attached : flow.section,
                  body: _seriousGroupSlivers(
                    library,
                    settings,
                    recent,
                    useList,
                    flow,
                  ),
                ),
              if (unknown.isNotEmpty)
                ..._sectionSlivers(
                  flow,
                  title: '之前未看完',
                  beforeTitle: pins.isEmpty && recent.isEmpty
                      ? flow.attached
                      : flow.section,
                  body: _seriousGroupSlivers(
                    library,
                    settings,
                    unknown,
                    useList,
                    flow,
                  ),
                ),
            ] else ...[
              for (var i = 0; i < historyDays.length; i++)
                ..._daySlivers(
                  library,
                  settings,
                  historyDays[i],
                  historyDays,
                  useList,
                  flow,
                  beforeHeader: i == 0 && pins.isEmpty
                      ? flow.attached
                      : flow.section,
                ),
            ],
            SliverToBoxAdapter(
              child: SizedBox(height: 24 + widget.cardBottomPadding),
            ),
          ],
        ],
      ),
    );
    return _frozenSubtree!;
  }

  MediaLibraryFlowSpacing _flowSpacing(SettingsService settings, bool useList) {
    final screenSize = MediaQuery.sizeOf(context);
    return mediaLibraryFlowSpacingFor(
      screenSize: screenSize,
      useList: useList,
      cardStyle: settings.collectionCardStyleFor(screenSize),
      listStyle: settings.listStyleFor(screenSize),
    );
  }

  List<Widget> _sectionSlivers(
    MediaLibraryFlowSpacing flow, {
    required String title,
    required double beforeTitle,
    required List<Widget> body,
  }) {
    return [
      if (flow.gap(beforeTitle) case final gap?) gap,
      SliverToBoxAdapter(
        child: _SectionHeader(title: title, horizontalPadding: flow.outer),
      ),
      if (flow.gap(flow.attached) case final gap?) gap,
      ...body,
    ];
  }

  Widget _filterTile(SettingsService settings, MediaLibraryFlowSpacing flow) {
    final on = settings.mediaLibraryContinueSeriousOnly;
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.fromLTRB(flow.outer, flow.leading, flow.outer, 0),
        child: _ContinueFilterPill(
          active: on,
          onToggleSeriousOnly: () {
            setState(() {
              _frozenRecentKeys = <String>[];
              _frozenUnknownKeys = <String>[];
              _frozenHistoryDayKeys = <String>[];
              _expand.clear();
            });
            unawaited(
              settings.updateSetting('mediaLibraryContinueSeriousOnly', !on),
            );
          },
          onOpenPolicy: () {
            unawaited(MediaLibraryContinuePolicySheet.show(context));
          },
        ),
      ),
    );
  }

  Widget _emptyBody(bool seriousOnly, bool hasHistory) {
    final text = seriousOnly
        ? (hasHistory ? '没有符合当前门槛的未完成。取消筛选可看全部记录。' : '还没有符合门槛的未完成。')
        : '播放过的媒体会出现在这里。';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54),
          ),
          const SizedBox(height: 16),
          TextButton(onPressed: widget.onGoRecent, child: const Text('前往最近添加')),
          TextButton(onPressed: widget.onGoFolders, child: const Text('前往文件夹')),
        ],
      ),
    );
  }

  List<Widget> _seriousGroupSlivers(
    LibraryService library,
    SettingsService settings,
    List<ContinueLearningGroup> groups,
    bool useList,
    MediaLibraryFlowSpacing flow,
  ) {
    final slivers = <Widget>[];
    final rootIds = <String>[];
    void flushRoot() {
      if (rootIds.isEmpty) return;
      if (slivers.isNotEmpty) flow.addGap(slivers, flow.block);
      slivers.add(
        _idGridOrListSliver(
          library: library,
          settings: settings,
          ids: List<String>.from(rootIds),
          useList: useList,
        ),
      );
      rootIds.clear();
    }

    for (final group in groups) {
      if (group.parentId == null) {
        rootIds.addAll(group.mediaIds);
        continue;
      }
      flushRoot();
      if (slivers.isNotEmpty) flow.addGap(slivers, flow.block);
      slivers.addAll(
        _groupSlivers(library, settings, group, groups, useList, flow),
      );
    }
    flushRoot();
    return slivers;
  }

  List<Widget> _daySlivers(
    LibraryService library,
    SettingsService settings,
    PlaybackHistoryDayGroup day,
    List<PlaybackHistoryDayGroup> siblings,
    bool useList,
    MediaLibraryFlowSpacing flow, {
    required double beforeHeader,
  }) {
    final count = day.mediaIds.length;
    final flat = MediaLibraryGroupExpandPolicy.alwaysExpanded(count);
    final expanded =
        flat ||
        _expand.isExpanded(
          day.rowId,
          defaultExpanded: MediaLibraryGroupExpandPolicy.historyDefaultExpanded(
            count: count,
            dayStartMs: day.dayStartMs,
          ),
        );
    final covers = _coverItems(library, day.mediaIds);
    final header = SliverToBoxAdapter(
      key: ValueKey(day.rowId),
      child: KeyedSubtree(
        key: _headerKey(day.rowId),
        child: MediaLibraryGroupHeader(
          title: '${day.label}·$count项',
          coverItems: covers,
          expanded: expanded,
          padding: EdgeInsets.symmetric(horizontal: flow.outer),
          showChevron: !flat,
          remainderCount: expanded ? 0 : count,
          onToggle: flat
              ? null
              : () => _toggleGroup(
                  rowId: day.rowId,
                  currentlyExpanded: expanded,
                  memberCount: count,
                  siblingCounts: {
                    for (final other in siblings)
                      other.rowId: other.mediaIds.length,
                  },
                ),
        ),
      ),
    );
    if (!expanded) {
      return [if (flow.gap(beforeHeader) case final gap?) gap, header];
    }
    return [
      if (flow.gap(beforeHeader) case final gap?) gap,
      header,
      if (flow.gap(flow.attached) case final attached?) attached,
      _idGridOrListSliver(
        library: library,
        settings: settings,
        ids: day.mediaIds,
        useList: useList,
      ),
    ];
  }

  Widget _idGridOrListSliver({
    required LibraryService library,
    required SettingsService settings,
    required List<String> ids,
    required bool useList,
    bool pinMode = false,
  }) {
    if (ids.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());
    if (useList) {
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
            return _pinTile(
              library,
              settings,
              ids[index],
              true,
              allowHide: !pinMode,
              pinIndex: pinMode ? index : null,
              pinCount: pinMode ? ids.length : 0,
            );
          }, childCount: ids.length),
        ),
      );
    }
    final cardMetrics = MediaLibraryLayoutDefaults.cardGrid(
      screenSize: MediaQuery.sizeOf(context),
      style: settings.collectionCardStyleFor(MediaQuery.sizeOf(context)),
    );
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: cardMetrics.outerPadding),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cardMetrics.crossAxisCount,
          childAspectRatio: cardMetrics.aspectRatio.clamp(0.1, 5.0),
          crossAxisSpacing: cardMetrics.crossSpacing,
          mainAxisSpacing: cardMetrics.mainSpacing,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          return _pinTile(
            library,
            settings,
            ids[index],
            false,
            allowHide: !pinMode,
            pinIndex: pinMode ? index : null,
            pinCount: pinMode ? ids.length : 0,
          );
        }, childCount: ids.length),
      ),
    );
  }

  Duration get _pinDragDelay {
    if (Platform.isWindows || Platform.isMacOS) {
      return const Duration(milliseconds: 320);
    }
    return const Duration(milliseconds: 160);
  }

  Widget _pinTile(
    LibraryService library,
    SettingsService settings,
    String id,
    bool useList, {
    bool allowHide = true,
    int? pinIndex,
    int pinCount = 0,
  }) {
    final collection = library.getCollection(id);
    late final Widget tile;
    late final VoidCallback onOpen;
    if (collection != null) {
      tile = _folderPin(library, settings, collection, useList);
      onOpen = () => widget.onOpenFolder(collection);
    } else {
      final item = library.getVideo(id);
      if (item == null) return const SizedBox.shrink();
      tile = _mediaCard(library, settings, item, useList, allowHide: allowHide);
      onOpen = () => widget.onOpenMedia(item);
    }
    if (pinIndex == null || pinCount < 2) return tile;
    return MediaLibraryPinnedReorderWrapper(
      key: ValueKey('continue-pin-$id'),
      visibleIndex: pinIndex,
      dragDelay: _pinDragDelay,
      onTap: onOpen,
      onDragStarted: () {
        unawaited(AppHaptics.reorderDragStarted(settings));
      },
      onReorder: (from, to) {
        unawaited(library.reorderVisiblePinnedLibraryItems(from, to));
      },
      child: tile,
    );
  }

  Widget _folderPin(
    LibraryService library,
    SettingsService settings,
    VideoCollection collection,
    bool useList,
  ) {
    if (useList) {
      return SizedBox(
        height: 72,
        child: MediaLibraryListTile.collection(
          collection: collection,
          index: 0,
          showIndex: false,
          showThumbnail: true,
          isSelected: false,
          isSelectionMode: false,
          titleScale: settings
              .listStyleFor(MediaQuery.sizeOf(context))
              .titleScale,
          onTap: () => widget.onOpenFolder(collection),
          onShowInParentFolder: () => widget.onLocateFolder(collection),
          showActivityMenu: true,
          allowHide: false,
        ),
      );
    }
    return MediaLibraryFolderGridCard(
      collection: collection,
      titleScale: settings
          .collectionCardStyleFor(MediaQuery.sizeOf(context))
          .titleScale,
      onTap: () => widget.onOpenFolder(collection),
      onLocate: () => widget.onLocateFolder(collection),
    );
  }

  List<Widget> _groupSlivers(
    LibraryService library,
    SettingsService settings,
    ContinueLearningGroup group,
    List<ContinueLearningGroup> siblings,
    bool useList,
    MediaLibraryFlowSpacing flow,
  ) {
    final ids = group.mediaIds;
    final count = ids.length;
    final flat = MediaLibraryGroupExpandPolicy.alwaysExpanded(count);
    final expanded =
        flat || _expand.isExpanded(group.rowId, defaultExpanded: false);
    final featured = library.getVideo(group.featuredMediaId);
    final rest = ids.skip(1).toList(growable: false);
    final collection = group.parentId == null
        ? null
        : library.getCollection(group.parentId!);
    final header = SliverToBoxAdapter(
      key: ValueKey(group.rowId),
      child: KeyedSubtree(
        key: _headerKey(group.rowId),
        child: MediaLibraryGroupHeader(
          title: '${_folderTitle(library, group)}·当前$count项',
          subtitle: _resumeSubtitle(featured),
          coverItems: _coverItems(library, ids),
          expanded: expanded,
          padding: EdgeInsets.symmetric(horizontal: flow.outer),
          showChevron: !flat && rest.isNotEmpty,
          remainderCount: rest.length,
          progress: _progressOf(featured),
          onOpenFolder: collection == null
              ? null
              : () => widget.onOpenFolder(collection),
          onToggle: flat || rest.isEmpty
              ? null
              : () => _toggleGroup(
                  rowId: group.rowId,
                  currentlyExpanded: expanded,
                  memberCount: count,
                  siblingCounts: {
                    for (final other in siblings)
                      other.rowId: other.mediaIds.length,
                  },
                ),
        ),
      ),
    );
    if (flat) {
      return [
        header,
        if (flow.gap(flow.attached) case final attached?) attached,
        _idGridOrListSliver(
          library: library,
          settings: settings,
          ids: ids,
          useList: useList,
        ),
      ];
    }
    return [
      header,
      if (flow.gap(flow.attached) case final attached?) attached,
      _idGridOrListSliver(
        library: library,
        settings: settings,
        ids: <String>[group.featuredMediaId],
        useList: useList,
      ),
      if (expanded && rest.isNotEmpty) ...[
        if (flow.gap(flow.row) case final rowGap?) rowGap,
        _idGridOrListSliver(
          library: library,
          settings: settings,
          ids: rest,
          useList: useList,
        ),
      ],
    ];
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

  String? _resumeSubtitle(VideoItem? item) {
    if (item == null) return null;
    if (item.lastPositionMs <= 0) return item.title;
    return '${item.title} · ${MediaLibraryMediaGridCard.durationLabel(item.lastPositionMs)}';
  }

  double? _progressOf(VideoItem? item) {
    if (item == null || item.durationMs <= 0 || item.lastPositionMs <= 0) {
      return null;
    }
    return item.lastPositionMs / item.durationMs;
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

  Widget _mediaCard(
    LibraryService library,
    SettingsService settings,
    VideoItem item,
    bool useList, {
    bool allowHide = true,
  }) {
    final listStyle = settings.listStyleFor(MediaQuery.sizeOf(context));
    if (useList) {
      return MediaLibraryListTile.video(
        item: item,
        index: 0,
        showIndex: listStyle.showIndex,
        showThumbnail: listStyle.showThumbnail,
        isSelected: false,
        isSelectionMode: false,
        titleScale: listStyle.titleScale,
        onTap: () => widget.onOpenMedia(item),
        onShowInParentFolder: () => widget.onLocateMedia(item),
        showActivityMenu: true,
        allowHide: allowHide,
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
      allowHide: allowHide,
      relativePath: MediaLibraryMediaGridCard.pathFromLibraryRoot(
        library,
        item,
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.horizontalPadding});

  final String title;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: Text(
        title,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Compact filter pill. Options open beside it, same popover as card ⋯.
class _ContinueFilterPill extends StatefulWidget {
  const _ContinueFilterPill({
    required this.active,
    required this.onToggleSeriousOnly,
    required this.onOpenPolicy,
  });

  static const Color _accent = Color(0xFF0A84FF);

  final bool active;
  final VoidCallback onToggleSeriousOnly;
  final VoidCallback onOpenPolicy;

  @override
  State<_ContinueFilterPill> createState() => _ContinueFilterPillState();
}

class _ContinueFilterPillState extends State<_ContinueFilterPill> {
  bool _opening = false;

  Future<void> _openMenu() async {
    if (_opening || !mounted) return;
    _opening = true;
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.maybeOf(context, rootOverlay: true)?.context.findRenderObject()
            as RenderBox?;
    if (box == null || overlay == null || !box.hasSize) {
      _opening = false;
      return;
    }
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    final anchor = origin & box.size;
    try {
      final choice = await MediaLibraryAnchorMenu.show(
        context: context,
        anchor: anchor,
        alignStart: true,
        items: [
          MediaLibraryAnchorMenuEntry(
            key: const ValueKey('continueFilterSeriousOnly'),
            value: 'toggle',
            label: '只看未完成',
            icon: widget.active
                ? Icons.check_box_outlined
                : Icons.check_box_outline_blank,
            checked: widget.active,
          ),
          const MediaLibraryAnchorMenuEntry(
            key: ValueKey('continueFilterPolicy'),
            value: 'policy',
            label: '门槛设置',
            icon: Icons.tune,
          ),
        ],
      );
      if (!mounted || choice == null) return;
      if (choice == 'toggle') widget.onToggleSeriousOnly();
      if (choice == 'policy') widget.onOpenPolicy();
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    final label = active ? '继续观看' : '全部记录';
    final accent = active
        ? _ContinueFilterPill._accent
        : const Color(0xFFEBEBF5);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey('continueFilterMenu'),
        borderRadius: BorderRadius.circular(20),
        onTap: () => unawaited(_openMenu()),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFF3A3A3C).withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.filter_list,
                      size: 14,
                      color: accent.withValues(alpha: active ? 1 : 0.62),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.2,
                        color: accent.withValues(alpha: active ? 1 : 0.72),
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      Icons.arrow_drop_down,
                      size: 16,
                      color: accent.withValues(alpha: 0.45),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
