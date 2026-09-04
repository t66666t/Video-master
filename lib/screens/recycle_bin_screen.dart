import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/media_playback_service.dart';
import '../services/playlist_manager.dart';
import '../services/library_service.dart';
import '../services/playback_navigation_service.dart';
import '../models/video_collection.dart';
import '../models/video_item.dart';
import '../models/media_source_ref.dart';
import '../utils/app_toast.dart';
import '../widgets/responsive_icon_button.dart';

Future<void> _openRecycleBinVideo(BuildContext context, VideoItem item) async {
  final isOnline =
      item.sourceRef?.kind == MediaSourceKind.bilibiliStream ||
      item.path.startsWith('bilibili://stream/');
  final file = File(item.path);
  if (!isOnline && !await file.exists()) {
    if (!context.mounted) return;
    AppToast.show("媒体文件不存在，可能已被移动或删除", type: AppToastType.error);
    return;
  }
  if (!context.mounted) return;

  final playbackService = Provider.of<MediaPlaybackService>(
    context,
    listen: false,
  );
  final playlistManager = Provider.of<PlaylistManager>(context, listen: false);
  playlistManager.setPlaylist([item], startIndex: 0);
  final existingController = playbackService.currentItem?.id == item.id
      ? playbackService.controller
      : null;

  final Route<void> route = PlaybackNavigationService.buildPlaybackEntryRoute(
    item,
    existingController: existingController,
  );

  Navigator.of(context).push(route);
}

class RecycleBinScreen extends StatefulWidget {
  const RecycleBinScreen({super.key});

  @override
  State<RecycleBinScreen> createState() => _RecycleBinScreenState();
}

class SizeDisplay extends StatefulWidget {
  final dynamic item;
  final LibraryService library;

  const SizeDisplay({super.key, required this.item, required this.library});

  @override
  State<SizeDisplay> createState() => _SizeDisplayState();
}

class _SizeDisplayState extends State<SizeDisplay> {
  Future<int>? _sizeFuture;
  int? _cachedSize;

  @override
  void initState() {
    super.initState();
    widget.library.addListener(_handleLibraryChanged);
    _syncSizeState();
  }

  @override
  void didUpdateWidget(SizeDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != widget.library) {
      oldWidget.library.removeListener(_handleLibraryChanged);
      widget.library.addListener(_handleLibraryChanged);
    }
    if (oldWidget.item != widget.item || oldWidget.library != widget.library) {
      _syncSizeState();
    }
  }

  @override
  void dispose() {
    widget.library.removeListener(_handleLibraryChanged);
    super.dispose();
  }

  void _handleLibraryChanged() {
    if (!mounted) return;
    final nextCachedSize = widget.library.getCachedItemSize(widget.item);
    if (nextCachedSize == _cachedSize) return;
    setState(_syncSizeState);
  }

  void _syncSizeState() {
    _cachedSize = widget.library.getCachedItemSize(widget.item);
    _sizeFuture = _cachedSize == null
        ? widget.library.calculateItemSize(widget.item)
        : null;
  }

  @override
  Widget build(BuildContext context) {
    if (_cachedSize != null) {
      if (_cachedSize == 0) return const SizedBox.shrink();
      return Text(
        " • 可释放: ${LibraryService.formatSize(_cachedSize!)}",
        style: const TextStyle(color: Colors.grey, fontSize: 12),
      );
    }

    if (_sizeFuture == null) return const SizedBox.shrink();

    return FutureBuilder<int>(
      future: _sizeFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();
        final size = snapshot.data!;
        if (size == 0) return const SizedBox.shrink();
        return Text(
          " • 可释放: ${LibraryService.formatSize(size)}",
          style: const TextStyle(color: Colors.grey, fontSize: 12),
        );
      },
    );
  }
}

class _RecycleBinScreenState extends State<RecycleBinScreen> {
  final Set<String> _selectedIds = {};
  bool _isSelectionMode = false;
  final FocusNode _shortcutFocusNode = FocusNode(
    debugLabel: 'RecycleBinShortcutFocus',
  );
  Future<int>? _selectedSizeFuture;
  String _selectedSizeKey = '';

  void _navigateToFolderDetail(
    BuildContext context,
    VideoCollection collection,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) =>
            RecycledFolderDetailScreen(collection: collection),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (Platform.isWindows && mounted) {
        _shortcutFocusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _shortcutFocusNode.dispose();
    super.dispose();
  }

  void _updateSelectedSizeFuture(LibraryService library, List<dynamic> bin) {
    final selectedItems = bin
        .where((item) => _selectedIds.contains(item.id))
        .toList();
    final nextKey = selectedItems.map((item) => item.id as String).join('|');
    if (_selectedSizeKey == nextKey) return;

    _selectedSizeKey = nextKey;
    if (selectedItems.isEmpty) {
      setState(() {
        _selectedSizeFuture = null;
      });
      return;
    }

    setState(() {
      _selectedSizeFuture = library.calculateItemsTotalSize(selectedItems);
    });
  }

  void _clearSelection() {
    _isSelectionMode = false;
    _selectedIds.clear();
    _selectedSizeFuture = null;
    _selectedSizeKey = '';
  }

  String _formatCompactSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    double value = bytes.toDouble();
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < suffixes.length - 1) {
      value /= 1024;
      unitIndex++;
    }

    final decimals = value >= 100 ? 0 : (value >= 10 ? 1 : 2);
    final text = value.toStringAsFixed(decimals);
    final normalized = text.contains('.')
        ? text.replaceFirst(RegExp(r'\.?0+$'), '')
        : text;
    return '$normalized ${suffixes[unitIndex]}';
  }

  double _responsiveTitleFontSize(double width) =>
      (width * 0.048).clamp(15.0, 19.0);

  double _responsiveSubtitleFontSize(double width) =>
      (width * 0.032).clamp(11.0, 13.5);

  double _responsiveToolbarHeight(double width) =>
      (width * 0.16).clamp(58.0, 72.0);

  Widget _buildAppBarTitle(
    BuildContext context,
    int visibleCount,
    int selectedCount,
  ) {
    final width = MediaQuery.of(context).size.width;
    final titleFontSize = _responsiveTitleFontSize(width);
    final subtitleFontSize = _responsiveSubtitleFontSize(width);
    final isSelectionHeader = _isSelectionMode;

    if (!isSelectionHeader) {
      return Text(
        '已显示 $visibleCount 项',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: titleFontSize,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      );
    }

    return FutureBuilder<int>(
      future: _selectedSizeFuture,
      builder: (context, snapshot) {
        final sizeText = snapshot.hasData
            ? _formatCompactSize(snapshot.data!)
            : '正在计算...';
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '已选中 $selectedCount 项',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: titleFontSize,
                fontWeight: FontWeight.w600,
                color: Colors.white,
                height: 1.1,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '可释放 $sizeText',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: subtitleFontSize,
                fontWeight: FontWeight.w400,
                color: Colors.white70,
                height: 1.1,
              ),
            ),
          ],
        );
      },
    );
  }

  KeyEventResult _handleEscKeyEvent(KeyEvent event) {
    if (!Platform.isWindows) return KeyEventResult.ignored;
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      if (_isSelectionMode) {
        setState(() {
          _clearSelection();
        });
      } else {
        Navigator.of(context).maybePop();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _shortcutFocusNode,
      autofocus: Platform.isWindows,
      onKeyEvent: (node, event) => _handleEscKeyEvent(event),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) {
          if (Platform.isWindows && !_shortcutFocusNode.hasFocus) {
            _shortcutFocusNode.requestFocus();
          }
        },
        child: Consumer<LibraryService>(
          builder: (context, library, child) {
            final bin = library.getRecycleBinContents();
            final selectedItems = bin
                .where((item) => _selectedIds.contains(item.id))
                .toList();

            return Scaffold(
              appBar: AppBar(
                toolbarHeight: _isSelectionMode
                    ? _responsiveToolbarHeight(
                        MediaQuery.of(context).size.width,
                      )
                    : null,
                title: _buildAppBarTitle(
                  context,
                  bin.length,
                  selectedItems.length,
                ),
                actions: [
                  if (bin.isNotEmpty) ...[
                    ResponsiveActionButtons(
                      buttons: [
                        if (_isSelectionMode) ...[
                          ResponsiveIconButton(
                            icon: Icons.select_all,
                            onPressed: () {
                              final shouldSelectAll =
                                  _selectedIds.length != bin.length;
                              setState(() {
                                if (!shouldSelectAll) {
                                  _selectedIds.clear();
                                } else {
                                  _selectedIds.addAll(
                                    bin.map((e) => e.id as String),
                                  );
                                }
                              });
                              _updateSelectedSizeFuture(library, bin);
                            },
                            tooltip: "全选/反选",
                          ),
                          ResponsiveIconButton(
                            icon: Icons.close,
                            onPressed: () {
                              setState(() {
                                _clearSelection();
                              });
                            },
                            tooltip: "关闭",
                          ),
                        ] else ...[
                          ResponsiveIconButton(
                            icon: Icons.checklist,
                            onPressed: () {
                              setState(() {
                                _isSelectionMode = true;
                              });
                            },
                            tooltip: "选择",
                          ),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
              body: bin.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.delete_outline,
                            size: 80,
                            color: Colors.white24,
                          ),
                          SizedBox(height: 16),
                          Text(
                            "回收站是空的",
                            style: TextStyle(color: Colors.white54),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: bin.length,
                      itemBuilder: (context, index) {
                        final item = bin[index];
                        // Handle dynamic item type
                        final String id = item.id;
                        final VideoCollection? folder = item is VideoCollection
                            ? item
                            : null;
                        final String name =
                            folder?.name ?? (item as dynamic).title;
                        final bool isFolder = folder != null;
                        final String subtitleText = folder != null
                            ? "${folder.childrenIds.length} 个项目"
                            : (item as dynamic).path ?? "未知路径";

                        final isSelected = _selectedIds.contains(id);

                        return Card(
                          color: isSelected
                              ? Colors.blueAccent.withValues(alpha: 0.2)
                              : const Color(0xFF2C2C2C),
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: _isSelectionMode
                                ? Checkbox(
                                    value: isSelected,
                                    onChanged: (val) {
                                      setState(() {
                                        if (val == true) {
                                          _selectedIds.add(id);
                                        } else {
                                          _selectedIds.remove(id);
                                        }
                                      });
                                      _updateSelectedSizeFuture(library, bin);
                                    },
                                  )
                                : Icon(
                                    isFolder ? Icons.folder : Icons.movie,
                                    color: isFolder
                                        ? Colors.amber
                                        : Colors.blue,
                                  ),
                            title: Text(
                              name,
                              style: const TextStyle(color: Colors.white),
                            ),
                            subtitle: Row(
                              children: [
                                Expanded(
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: Text(
                                      subtitleText,
                                      style: const TextStyle(
                                        color: Colors.white54,
                                        fontSize: 12,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.visible,
                                    ),
                                  ),
                                ),
                                SizeDisplay(item: item, library: library),
                              ],
                            ),
                            trailing: !_isSelectionMode
                                ? IconButton(
                                    icon: const Icon(
                                      Icons.restore,
                                      color: Colors.green,
                                    ),
                                    onPressed: () {
                                      library.restoreFromRecycleBin([id]);
                                      AppToast.show(
                                        "已还原",
                                        type: AppToastType.success,
                                      );
                                    },
                                    tooltip: "还原",
                                  )
                                : null,
                            onTap: () {
                              if (_isSelectionMode) {
                                setState(() {
                                  if (isSelected) {
                                    _selectedIds.remove(id);
                                  } else {
                                    _selectedIds.add(id);
                                  }
                                });
                                _updateSelectedSizeFuture(library, bin);
                              } else if (isFolder) {
                                _navigateToFolderDetail(context, folder);
                              } else {
                                _openRecycleBinVideo(
                                  context,
                                  item as VideoItem,
                                );
                              }
                            },
                            onLongPress: () {
                              if (!_isSelectionMode) {
                                setState(() {
                                  _isSelectionMode = true;
                                  _selectedIds.add(id);
                                });
                                _updateSelectedSizeFuture(library, bin);
                              }
                            },
                          ),
                        );
                      },
                    ),
              bottomNavigationBar: _isSelectionMode && _selectedIds.isNotEmpty
                  ? BottomAppBar(
                      color: const Color(0xFF1E1E1E),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          TextButton.icon(
                            icon: const Icon(
                              Icons.restore,
                              color: Colors.green,
                            ),
                            label: const Text(
                              "还原",
                              style: TextStyle(color: Colors.green),
                            ),
                            onPressed: () {
                              library.restoreFromRecycleBin(
                                _selectedIds.toList(),
                              );
                              setState(() {
                                _clearSelection();
                              });
                              AppToast.show(
                                "已还原选中项",
                                type: AppToastType.success,
                              );
                            },
                          ),
                          TextButton.icon(
                            icon: const Icon(
                              Icons.delete_forever,
                              color: Colors.redAccent,
                            ),
                            label: const Text(
                              "彻底删除",
                              style: TextStyle(color: Colors.redAccent),
                            ),
                            onPressed: () {
                              showDialog(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text("彻底删除"),
                                  content: const Text("删除后无法找回，确定要删除吗？"),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(ctx),
                                      child: const Text("取消"),
                                    ),
                                    TextButton(
                                      onPressed: () async {
                                        Navigator.pop(ctx);
                                        await library.deleteFromRecycleBin(
                                          _selectedIds.toList(),
                                        );
                                        if (context.mounted) {
                                          setState(() {
                                            _clearSelection();
                                          });
                                        }
                                      },
                                      child: const Text(
                                        "删除",
                                        style: TextStyle(color: Colors.red),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    )
                  : null,
            );
          },
        ),
      ),
    );
  }
}

class RecycledFolderDetailScreen extends StatefulWidget {
  final VideoCollection collection;

  const RecycledFolderDetailScreen({super.key, required this.collection});

  @override
  State<RecycledFolderDetailScreen> createState() =>
      _RecycledFolderDetailScreenState();
}

class _RecycledFolderDetailScreenState
    extends State<RecycledFolderDetailScreen> {
  final FocusNode _shortcutFocusNode = FocusNode(
    debugLabel: 'RecycleBinDetailShortcutFocus',
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (Platform.isWindows && mounted) {
        _shortcutFocusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _shortcutFocusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleEscKeyEvent(KeyEvent event) {
    if (!Platform.isWindows) return KeyEventResult.ignored;
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _shortcutFocusNode,
      autofocus: Platform.isWindows,
      onKeyEvent: (node, event) => _handleEscKeyEvent(event),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) {
          if (Platform.isWindows && !_shortcutFocusNode.hasFocus) {
            _shortcutFocusNode.requestFocus();
          }
        },
        child: Consumer<LibraryService>(
          builder: (context, library, child) {
            final contents = library.getContents(widget.collection.id);

            return Scaffold(
              appBar: AppBar(
                title: Text(widget.collection.name),
                backgroundColor: const Color(0xFF1E1E1E),
              ),
              body: Column(
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    color: Colors.orange.withValues(alpha: 0.1),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.info_outline,
                          color: Colors.orange,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            "您正在查看已删除文件夹的内容。\n若要操作这些项目，请先还原该文件夹。",
                            style: TextStyle(
                              color: Colors.orange[300],
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: contents.isEmpty
                        ? const Center(
                            child: Text(
                              "文件夹为空",
                              style: TextStyle(color: Colors.white54),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.all(16),
                            itemCount: contents.length,
                            itemBuilder: (context, index) {
                              final item = contents[index];
                              final String name = item is VideoCollection
                                  ? item.name
                                  : (item as VideoItem).title;
                              final bool isFolder = item is VideoCollection;

                              return Card(
                                color: const Color(
                                  0xFF2C2C2C,
                                ).withValues(alpha: 0.5),
                                margin: const EdgeInsets.only(bottom: 8),
                                child: ListTile(
                                  leading: Icon(
                                    isFolder ? Icons.folder : Icons.movie,
                                    color:
                                        (isFolder ? Colors.amber : Colors.blue)
                                            .withValues(alpha: 0.5),
                                  ),
                                  title: Text(
                                    name,
                                    style: TextStyle(
                                      color: Colors.white.withValues(
                                        alpha: 0.7,
                                      ),
                                    ),
                                  ),
                                  subtitle: Row(
                                    children: [
                                      if (isFolder)
                                        Expanded(
                                          child: Text(
                                            "${item.childrenIds.length} 个项目",
                                            style: const TextStyle(
                                              color: Colors.white38,
                                              fontSize: 12,
                                            ),
                                          ),
                                        )
                                      else
                                        Expanded(
                                          child: SingleChildScrollView(
                                            scrollDirection: Axis.horizontal,
                                            child: Text(
                                              (item as VideoItem).path,
                                              style: const TextStyle(
                                                color: Colors.white38,
                                                fontSize: 12,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.visible,
                                            ),
                                          ),
                                        ),
                                      SizeDisplay(item: item, library: library),
                                    ],
                                  ),
                                  onTap: () {
                                    if (isFolder) {
                                      Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (context) =>
                                              RecycledFolderDetailScreen(
                                                collection: item,
                                              ),
                                        ),
                                      );
                                    } else {
                                      _openRecycleBinVideo(
                                        context,
                                        item as VideoItem,
                                      );
                                    }
                                  },
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
