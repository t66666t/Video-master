import 'dart:async';

import 'package:flutter/material.dart';

import '../models/video_item.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
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
    backgroundColor: const Color(0xFF1E1E1E),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) {
      var copyImportedMedia = settings.copyImportedMediaToPrivateStorage;
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
                  child: SwitchListTile.adaptive(
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
                        '开启后，新导入的媒体会先完整复制到软件管理的目录，并直接使用副本播放。原文件不会被修改。',
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
                if (streamService != null) ...[
                  const SizedBox(height: 10),
                  _OnlineCacheSection(
                    streamService: streamService,
                    library: library,
                  ),
                ],
                const SizedBox(height: 10),
                const Text(
                  '仅影响开关变更后新开始的导入任务；不会搬迁已有媒体。副本会占用额外空间，移入回收站后仍会保留并计入占用空间，永久删除卡片时一并删除。',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  '即使关闭，若系统只提供临时文件地址，软件仍会保存必要副本，以避免媒体在缓存清理后失效。',
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 11,
                    height: 1.4,
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

/// 统一的在线视频缓存管理区块：总量统计 + 按卡片明细（素材文件 / 播放网关
/// 缓存分类）+ 单卡与全局清除。下载中的素材受租约保护，清除时自动转为
/// 延迟删除，不会损坏正在合成/OCR 的任务。
class _OnlineCacheSection extends StatefulWidget {
  final BilibiliStreamingService streamService;
  final LibraryService? library;

  const _OnlineCacheSection({required this.streamService, this.library});

  @override
  State<_OnlineCacheSection> createState() => _OnlineCacheSectionState();
}

class _OnlineCacheSectionState extends State<_OnlineCacheSection> {
  late Future<BilibiliStreamCacheReport> _reportFuture;
  Future<List<_ItemCacheRow>>? _rowsFuture;
  bool _showDetail = false;
  final Set<String> _clearingCardIds = <String>{};

  @override
  void initState() {
    super.initState();
    _reportFuture = widget.streamService.inspectCache();
  }

  void _refresh() {
    setState(() {
      _reportFuture = widget.streamService.inspectCache();
      _rowsFuture = _loadRows();
    });
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

  Future<void> _clearItemCache(String itemId) async {
    final library = widget.library;
    if (library == null || _clearingCardIds.contains(itemId)) return;
    setState(() => _clearingCardIds.add(itemId));
    try {
      await library.clearOnlineCacheForItem(itemId);
    } finally {
      if (mounted) {
        setState(() => _clearingCardIds.remove(itemId));
        _refresh();
      }
    }
  }

  Future<void> _clearAll() async {
    final library = widget.library;
    // 逐卡片走租约感知的清除（正在使用的素材转为延迟删除），再整体清扫
    // 剩余的网关缓存与孤儿目录。
    if (library != null) {
      for (final item in library.bilibiliStreamItems) {
        try {
          await library.clearOnlineCacheForItem(item.id);
        } catch (_) {}
      }
    }
    await widget.streamService.clearCache();
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF292929),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          FutureBuilder<BilibiliStreamCacheReport>(
            future: _reportFuture,
            builder: (context, snapshot) {
              final report = snapshot.data;
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 4,
                ),
                leading: const Icon(
                  Icons.cloud_download_outlined,
                  color: Colors.white70,
                ),
                title: const Text(
                  'Bilibili 在线视频缓存',
                  style: TextStyle(color: Colors.white, fontSize: 15),
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    snapshot.connectionState == ConnectionState.waiting
                        ? '正在统计...'
                        : '${_formatStorageBytes(report?.bytes ?? 0)} · '
                              '${report?.fileCount ?? 0} 个文件（含已下载的离线素材）',
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.library != null)
                      TextButton(
                        onPressed: () =>
                            setState(() => _showDetail = !_showDetail),
                        child: Text(_showDetail ? '收起' : '明细'),
                      ),
                    TextButton(
                      onPressed:
                          snapshot.connectionState == ConnectionState.waiting
                          ? null
                          : () => unawaited(_clearAll()),
                      child: const Text('清除'),
                    ),
                  ],
                ),
              );
            },
          ),
          if (_showDetail && widget.library != null)
            FutureBuilder<List<_ItemCacheRow>>(
              future: _rowsFuture ??= _loadRows(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
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
                final rows = snapshot.data ?? const <_ItemCacheRow>[];
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
                    for (final row in rows)
                      ListTile(
                        dense: true,
                        contentPadding: const EdgeInsets.only(
                          left: 14,
                          right: 8,
                        ),
                        title: Text(
                          row.item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                          ),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            '素材 ${_formatStorageBytes(row.breakdown.materializedBytes)}'
                            ' · 播放缓存 ${_formatStorageBytes(row.breakdown.gatewayBytes)}'
                            ' · 共 ${_formatStorageBytes(row.breakdown.totalBytes)}',
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                        ),
                        trailing: _clearingCardIds.contains(row.item.id)
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : TextButton(
                                onPressed: () => unawaited(
                                  _clearItemCache(row.item.id),
                                ),
                                child: const Text('清除'),
                              ),
                      ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}
