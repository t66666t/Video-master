import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_library_root_entry.dart';
import '../models/video_item.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../theme/app_tokens.dart';
import '../services/bilibili/bilibili_streaming_service.dart';
import 'package:provider/provider.dart';

String _formatStorageBytes(int bytes) {
  if (bytes <= 0) return '0 KB';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit == 0 ? 0 : (value >= 100 ? 0 : 1);
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// Phone library sheets use the same 600dp shortest-side breakpoint as the rest
/// of the media library, so tablet/desktop keep the roomier trailing actions.
@visibleForTesting
bool mediaLibraryCacheUsesPhoneLayout(Size size) => size.shortestSide < 600;

@visibleForTesting
const Duration mediaLibraryCacheRowCollapseDuration = Duration(
  milliseconds: 220,
);

@visibleForTesting
ButtonStyle? mediaLibraryCacheActionStyle({required bool compact}) {
  if (!compact) return null;
  // Default TextButtons reserve a 64dp minimum width, which pushes 明细/清除
  // far apart on a phone. Shrink only the compact layout.
  return TextButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    minimumSize: Size.zero,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.compact,
  );
}

BilibiliStreamingService? _maybeBilibiliStreamingService(BuildContext context) {
  try {
    return Provider.of<BilibiliStreamingService>(context, listen: false);
  } on ProviderNotFoundException {
    return null;
  }
}

LibraryService? _maybeLibraryService(BuildContext context) {
  try {
    return Provider.of<LibraryService>(context, listen: false);
  } on ProviderNotFoundException {
    return null;
  }
}

class _ItemCacheRow {
  final VideoItem item;
  final BilibiliItemCacheBreakdown breakdown;

  const _ItemCacheRow(this.item, this.breakdown);
}

/// Opens the global media-library settings using the same bottom-sheet
/// presentation as the card-style controls.
void showMediaLibrarySettingsBottomSheet(
  BuildContext context,
  SettingsService settings,
) {
  final streamService = _maybeBilibiliStreamingService(context);
  final library = _maybeLibraryService(context);
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTokens.bgRaised,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
    ),
    builder: (context) {
      var restoreLastPage = settings.mediaLibraryRestoreLastPage;
      var startupEntry =
          MediaLibraryRootEntryX.tryParse(settings.mediaLibraryStartupEntry) ??
          MediaLibraryRootEntry.folders;
      var copyImportedMedia = settings.copyImportedMediaToPrivateStorage;
      var useSearchResultsAsQueue = settings.useSearchResultsAsPlaybackQueue;
      var saveBilibiliBackgroundData = settings.bilibiliBackgroundAudioOnly;
      var skipRepeatedClipboardText = settings.skipRepeatedClipboardText;
      return StatefulBuilder(
        builder: (context, setSheetState) {
          final maxHeight = MediaQuery.sizeOf(context).height * 0.65;
          return ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
              children: [
                const Text(
                  '媒体库设置',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 10),
                Material(
                  color: const Color(0xFF292929),
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      SwitchListTile.adaptive(
                        key: const ValueKey('mediaLibraryRestoreLastPage'),
                        value: restoreLastPage,
                        activeThumbColor: Colors.blueAccent,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 4,
                        ),
                        title: const Text(
                          '打开时回到上次离开的页面',
                          style: TextStyle(color: Colors.white, fontSize: 15),
                        ),
                        subtitle: const Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: Text(
                            '包括上次打开的文件夹。关闭后，每次进入都打开下方选中的页面。',
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),
                        ),
                        onChanged: (value) {
                          setSheetState(() => restoreLastPage = value);
                          unawaited(
                            settings.updateSetting(
                              'mediaLibraryRestoreLastPage',
                              value,
                            ),
                          );
                        },
                      ),
                      if (!restoreLastPage)
                        for (final entry in const [
                          MediaLibraryRootEntry.folders,
                          MediaLibraryRootEntry.continueLearning,
                          MediaLibraryRootEntry.recent,
                        ])
                          ListTile(
                            key: ValueKey(
                              'mediaLibraryStartupEntry-${entry.storageValue}',
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14,
                            ),
                            title: Text(
                              entry.label,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                              ),
                            ),
                            trailing: startupEntry == entry
                                ? const Icon(
                                    Icons.check_rounded,
                                    color: Colors.blueAccent,
                                  )
                                : null,
                            onTap: () {
                              setSheetState(() => startupEntry = entry);
                              unawaited(
                                settings.updateSetting(
                                  'mediaLibraryStartupEntry',
                                  entry.storageValue,
                                ),
                              );
                            },
                          ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Material(
                  color: const Color(0xFF292929),
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: SwitchListTile.adaptive(
                    key: const ValueKey('copyImportedMediaToPrivateStorage'),
                    value: copyImportedMedia,
                    activeThumbColor: Colors.blueAccent,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 4,
                    ),
                    title: const Text(
                      '导入时复制媒体到应用私有目录',
                      style: TextStyle(color: Colors.white, fontSize: 15),
                    ),
                    subtitle: const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        '仅对新导入生效，原文件不变。临时来源仍会保存必要副本。',
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ),
                    onChanged: (value) {
                      // updateSetting applies the runtime value synchronously,
                      // notifies all listeners, then persists it asynchronously.
                      setSheetState(() => copyImportedMedia = value);
                      unawaited(
                        settings.updateSetting(
                          'copyImportedMediaToPrivateStorage',
                          value,
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 10),
                Material(
                  color: const Color(0xFF292929),
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: SwitchListTile.adaptive(
                    key: const ValueKey('useSearchResultsAsPlaybackQueue'),
                    value: useSearchResultsAsQueue,
                    activeThumbColor: Colors.blueAccent,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 4,
                    ),
                    title: const Text(
                      '搜索结果作为播放队列',
                      style: TextStyle(color: Colors.white, fontSize: 15),
                    ),
                    subtitle: const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        '开启后按搜索列表切集，可能跳到其他合集。',
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ),
                    onChanged: (value) {
                      setSheetState(() => useSearchResultsAsQueue = value);
                      unawaited(
                        settings.updateSetting(
                          'useSearchResultsAsPlaybackQueue',
                          value,
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 10),
                Material(
                  color: const Color(0xFF292929),
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: SwitchListTile.adaptive(
                    key: const ValueKey('bilibiliBackgroundAudioOnly'),
                    value: saveBilibiliBackgroundData,
                    activeThumbColor: Colors.blueAccent,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 4,
                    ),
                    title: const Text(
                      '后台播放哔哩哔哩时只加载音频',
                      style: TextStyle(color: Colors.white, fontSize: 15),
                    ),
                    subtitle: const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        '关闭时后台同样加载视频，从 Mini 或通知栏进入播放页可无缝接上画面。开启后仅加载音频以节省流量。',
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ),
                    onChanged: (value) {
                      setSheetState(() => saveBilibiliBackgroundData = value);
                      unawaited(
                        settings.updateSetting(
                          'bilibiliBackgroundAudioOnly',
                          value,
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 10),
                Material(
                  color: const Color(0xFF292929),
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: SwitchListTile.adaptive(
                    key: const ValueKey('skipRepeatedClipboardText'),
                    value: skipRepeatedClipboardText,
                    activeThumbColor: Colors.blueAccent,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 4,
                    ),
                    title: const Text(
                      '相同剪贴板内容只识别一次',
                      style: TextStyle(color: Colors.white, fontSize: 15),
                    ),
                    subtitle: const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        '开启后，同一段文字不会反复解析，关掉软件再打开也一样。换成别的内容再复制回来，仍会识别。关闭后，下次回到软件会再识别一次。',
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ),
                    onChanged: (value) {
                      setSheetState(() => skipRepeatedClipboardText = value);
                      unawaited(
                        settings.updateSetting(
                          'skipRepeatedClipboardText',
                          value,
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 10),
                Material(
                  color: const Color(0xFF292929),
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    key: const ValueKey('clearPlaybackHistory'),
                    title: const Text(
                      '清除播放记录',
                      style: TextStyle(color: Colors.white, fontSize: 15),
                    ),
                    subtitle: const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        '只清观看时间和继续学习资格，不删文件、导入记录、置顶，以及从「继续学习」列表移除的标记。',
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ),
                    onTap: library == null
                        ? null
                        : () async {
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (dialogContext) {
                                return AlertDialog(
                                  title: const Text('清除播放记录？'),
                                  content: const Text(
                                    '继续学习和播放记录会空出来。媒体文件和最近添加不变。',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(dialogContext, false),
                                      child: const Text('取消'),
                                    ),
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(dialogContext, true),
                                      child: const Text('清除'),
                                    ),
                                  ],
                                );
                              },
                            );
                            if (confirmed != true) return;
                            await library.clearPlaybackHistory();
                            if (context.mounted) Navigator.pop(context);
                          },
                  ),
                ),
                if (streamService != null) ...[
                  const SizedBox(height: 10),
                  MediaLibraryBilibiliCacheSection(
                    streamService: streamService,
                    library: library,
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

/// 统一的在线视频缓存管理区块：总量统计 + 按卡片明细（素材文件 / 播放网关
/// 缓存分类）+ 单卡与全局清除。下载中的素材受租约保护，清除时自动转为
/// 延迟删除，不会损坏正在合成/OCR 的任务。
@visibleForTesting
class MediaLibraryBilibiliCacheSection extends StatefulWidget {
  final BilibiliStreamingService? streamService;
  final LibraryService? library;
  final Future<BilibiliStreamCacheReport> Function()? inspectCache;
  final Future<void> Function()? clearCache;

  const MediaLibraryBilibiliCacheSection({
    super.key,
    this.streamService,
    this.library,
    this.inspectCache,
    this.clearCache,
  }) : assert(
         streamService != null || (inspectCache != null && clearCache != null),
       );

  @override
  State<MediaLibraryBilibiliCacheSection> createState() =>
      _MediaLibraryBilibiliCacheSectionState();
}

class _MediaLibraryBilibiliCacheSectionState
    extends State<MediaLibraryBilibiliCacheSection> {
  late Future<BilibiliStreamCacheReport> _reportFuture;
  List<_ItemCacheRow>? _detailRows;
  bool _showDetail = false;
  bool _detailLoading = false;
  bool _clearingAll = false;
  final Set<String> _clearingCardIds = <String>{};
  final Set<String> _collapsingIds = <String>{};

  @override
  void initState() {
    super.initState();
    _reportFuture = _inspectCache();
  }

  Future<BilibiliStreamCacheReport> _inspectCache() {
    return widget.inspectCache?.call() ?? widget.streamService!.inspectCache();
  }

  Future<void> _clearGatewayCache() {
    return widget.clearCache?.call() ?? widget.streamService!.clearCache();
  }

  Future<List<_ItemCacheRow>> _loadRows() async {
    final library = widget.library;
    if (library == null) return const <_ItemCacheRow>[];
    final rows = <_ItemCacheRow>[];
    for (final item in library.bilibiliStreamItems) {
      try {
        final breakdown = await library.inspectOnlineCacheBreakdown(item.id);
        if (breakdown == null || breakdown.isEmpty) continue;
        rows.add(_ItemCacheRow(item, breakdown));
      } catch (_) {}
    }
    rows.sort(
      (a, b) => b.breakdown.totalBytes.compareTo(a.breakdown.totalBytes),
    );
    return rows;
  }

  Future<void> _ensureDetailRows() async {
    if (_detailRows != null || _detailLoading) return;
    setState(() => _detailLoading = true);
    final rows = await _loadRows();
    if (!mounted) return;
    setState(() {
      _detailRows = rows;
      _detailLoading = false;
    });
  }

  void _toggleDetail() {
    final opening = !_showDetail;
    setState(() => _showDetail = opening);
    if (opening) unawaited(_ensureDetailRows());
  }

  void _beginCollapse(String itemId) {
    if (_collapsingIds.contains(itemId)) return;
    setState(() => _collapsingIds.add(itemId));
  }

  void _removeDetailRow(String itemId) {
    _detailRows?.removeWhere((row) => row.item.id == itemId);
    _collapsingIds.remove(itemId);
    _clearingCardIds.remove(itemId);
  }

  Future<void> _clearItemCache(String itemId) async {
    final library = widget.library;
    if (library == null || _clearingAll || _clearingCardIds.contains(itemId)) {
      return;
    }
    setState(() {
      _clearingCardIds.add(itemId);
      _collapsingIds.add(itemId);
    });
    await Future<void>.delayed(mediaLibraryCacheRowCollapseDuration);
    try {
      await library.clearOnlineCacheForItem(itemId);
    } finally {
      if (mounted) {
        setState(() {
          _removeDetailRow(itemId);
          _reportFuture = _inspectCache();
        });
      }
    }
  }

  Future<void> _clearAll() async {
    if (_clearingAll) return;
    // Show inline progress before any disk work so a large cache does not
    // look frozen. Feedback stays on this tile; no global toast.
    setState(() => _clearingAll = true);

    final visible = List<_ItemCacheRow>.from(_detailRows ?? const []);
    if (_showDetail && visible.isNotEmpty) {
      for (var index = 0; index < visible.length; index++) {
        final id = visible[index].item.id;
        final delayMs = 40 * (index < 10 ? index : 10);
        unawaited(
          Future<void>.delayed(Duration(milliseconds: delayMs), () {
            if (!mounted || !_clearingAll) return;
            _beginCollapse(id);
          }),
        );
      }
    }

    final library = widget.library;
    // 逐卡片走租约感知的清除（正在使用的素材转为延迟删除），再整体清扫
    // 剩余的网关缓存与孤儿目录。
    if (library != null) {
      final ids = visible.isNotEmpty
          ? visible.map((row) => row.item.id)
          : library.bilibiliStreamItems.map((item) => item.id);
      for (final id in ids) {
        try {
          await library.clearOnlineCacheForItem(id);
        } catch (_) {}
      }
    }
    await _clearGatewayCache();
    if (!mounted) return;
    setState(() {
      _detailRows = const <_ItemCacheRow>[];
      _collapsingIds.clear();
      _clearingCardIds.clear();
      _clearingAll = false;
      _reportFuture = _inspectCache();
    });
  }

  Widget _buildActions({required bool compact, required bool waiting}) {
    final style = mediaLibraryCacheActionStyle(compact: compact);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.library != null)
          TextButton(
            key: const ValueKey('bilibili-cache-detail-button'),
            style: style,
            onPressed: _clearingAll ? null : _toggleDetail,
            child: Text(_showDetail ? '收起' : '明细'),
          ),
        TextButton(
          key: const ValueKey('bilibili-cache-clear-all-button'),
          style: style,
          onPressed: waiting || _clearingAll
              ? null
              : () => unawaited(_clearAll()),
          child: _clearingAll
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: compact ? 12 : 14,
                      height: compact ? 12 : 14,
                      child: const CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: compact ? 4 : 6),
                    const Text('清除中'),
                  ],
                )
              : const Text('清除'),
        ),
      ],
    );
  }

  Widget _buildHeader({
    required bool waiting,
    required BilibiliStreamCacheReport? report,
  }) {
    final compact = mediaLibraryCacheUsesPhoneLayout(
      MediaQuery.sizeOf(context),
    );
    const titleStyle = TextStyle(color: Colors.white, fontSize: 15);
    const subtitleStyle = TextStyle(color: Colors.white60, fontSize: 12);
    final title = const Text('Bilibili 在线视频缓存', style: titleStyle);
    final subtitle = Text(
      _clearingAll
          ? '正在清除...'
          : waiting
          ? '正在统计...'
          : '${_formatStorageBytes(report?.bytes ?? 0)} · '
                '${report?.fileCount ?? 0} 个文件',
      style: subtitleStyle,
    );
    final actions = _buildActions(compact: compact, waiting: waiting);

    if (compact) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 1),
                  child: Icon(
                    Icons.cloud_download_outlined,
                    color: Colors.white70,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [title, const SizedBox(height: 4), subtitle],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Align(alignment: Alignment.centerRight, child: actions),
          ],
        ),
      );
    }

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      leading: const Icon(Icons.cloud_download_outlined, color: Colors.white70),
      title: title,
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: subtitle,
      ),
      trailing: actions,
    );
  }

  Widget _buildDetailRow(_ItemCacheRow row, {required bool compact}) {
    final collapsing = _collapsingIds.contains(row.item.id);
    final clearing = _clearingCardIds.contains(row.item.id);
    return _CollapsingCacheRow(
      collapsing: collapsing,
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.only(
          left: compact ? 12 : 14,
          right: compact ? 4 : 8,
        ),
        title: Text(
          row.item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            '素材 ${_formatStorageBytes(row.breakdown.materializedBytes)}'
            ' · 播放缓存 ${_formatStorageBytes(row.breakdown.gatewayBytes)}'
            ' · 共 ${_formatStorageBytes(row.breakdown.totalBytes)}',
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ),
        trailing: clearing
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : TextButton(
                style: mediaLibraryCacheActionStyle(compact: compact),
                onPressed: _clearingAll
                    ? null
                    : () => unawaited(_clearItemCache(row.item.id)),
                child: const Text('清除'),
              ),
      ),
    );
  }

  Widget _buildDetailBody({required bool compact}) {
    if (_detailLoading && _detailRows == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    final rows = _detailRows ?? const <_ItemCacheRow>[];
    if (rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(14, 0, 14, 14),
        child: Text(
          '暂无在线视频缓存',
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
      );
    }
    return Column(
      children: [
        for (final row in rows) _buildDetailRow(row, compact: compact),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = mediaLibraryCacheUsesPhoneLayout(
      MediaQuery.sizeOf(context),
    );
    return Material(
      color: const Color(0xFF292929),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          FutureBuilder<BilibiliStreamCacheReport>(
            future: _reportFuture,
            builder: (context, snapshot) {
              return _buildHeader(
                waiting:
                    snapshot.connectionState == ConnectionState.waiting &&
                    !_clearingAll,
                report: snapshot.data,
              );
            },
          ),
          if (_showDetail && widget.library != null)
            _buildDetailBody(compact: compact),
        ],
      ),
    );
  }
}

class _CollapsingCacheRow extends StatelessWidget {
  final bool collapsing;
  final Widget child;

  const _CollapsingCacheRow({required this.collapsing, required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedOpacity(
        duration: mediaLibraryCacheRowCollapseDuration,
        opacity: collapsing ? 0 : 1,
        child: AnimatedSize(
          duration: mediaLibraryCacheRowCollapseDuration,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: collapsing
              ? const SizedBox(width: double.infinity, height: 0)
              : child,
        ),
      ),
    );
  }
}
