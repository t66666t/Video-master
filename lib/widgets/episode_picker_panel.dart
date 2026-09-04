import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/video_item.dart';
import '../services/media_playback_service.dart';
import '../services/playlist_manager.dart';
import 'cached_thumbnail_widget.dart';

class EpisodePickerPanel extends StatefulWidget {
  final double panelWidth;
  final double panelHeight;
  final VoidCallback onClose;
  final bool isPortrait;

  const EpisodePickerPanel({
    super.key,
    required this.panelWidth,
    required this.panelHeight,
    required this.onClose,
    this.isPortrait = false,
  });

  @override
  State<EpisodePickerPanel> createState() => _EpisodePickerPanelState();
}

class _EpisodePickerPanelState extends State<EpisodePickerPanel> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _listViewKey = GlobalKey();
  final GlobalKey _currentItemKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // 弹窗打开时，定位到当前播放视频
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToCurrentItem();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToCurrentItem() {
    if (!mounted) return;
    final playlistManager = Provider.of<PlaylistManager>(
      context,
      listen: false,
    );
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    final currentItemId = playbackService.currentItem?.id;
    if (currentItemId == null || playlistManager.playlist.isEmpty) return;

    final int index = playlistManager.indexOfItem(currentItemId);
    if (index >= 0) {
      final totalCount = playlistManager.playlist.length;
      _jumpToRoughOffset(index, totalCount);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _alignCurrentItemPrecisely(index, totalCount, 0);
      });
    }
  }

  void _jumpToRoughOffset(int index, int totalCount) {
    if (!_scrollController.hasClients) return;
    if (totalCount <= 1) {
      _scrollController.jumpTo(0);
      return;
    }
    final maxExtent = _scrollController.position.maxScrollExtent;
    final roughOffset = (index / (totalCount - 1)) * maxExtent;
    _scrollController.jumpTo(roughOffset.clamp(0.0, maxExtent));
  }

  void _alignCurrentItemPrecisely(int index, int totalCount, int retryCount) {
    if (!mounted) return;
    if (!_scrollController.hasClients) {
      if (retryCount < 6) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _alignCurrentItemPrecisely(index, totalCount, retryCount + 1);
        });
      }
      return;
    }
    final itemContext = _currentItemKey.currentContext;
    final listContext = _listViewKey.currentContext;
    if (itemContext == null || listContext == null) {
      if (retryCount < 6) {
        _jumpToRoughOffset(index, totalCount);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _alignCurrentItemPrecisely(index, totalCount, retryCount + 1);
        });
      }
      return;
    }

    final itemBox = itemContext.findRenderObject() as RenderBox?;
    final listBox = listContext.findRenderObject() as RenderBox?;
    if (itemBox == null || listBox == null) return;

    final itemTop = itemBox.localToGlobal(Offset.zero, ancestor: listBox).dy;
    final itemHeight = itemBox.size.height;
    final viewportHeight = listBox.size.height;
    final targetItemCenterY = viewportHeight * 0.35;
    final currentItemCenterY = itemTop + itemHeight / 2;
    final delta = currentItemCenterY - targetItemCenterY;
    final maxExtent = _scrollController.position.maxScrollExtent;
    final targetOffset = (_scrollController.offset + delta).clamp(
      0.0,
      maxExtent,
    );
    _scrollController.jumpTo(targetOffset);
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    } else {
      return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
  }

  Widget _buildEpisodeThumbnail({
    required VideoItem item,
    required double width,
    required double height,
    required double iconSize,
  }) {
    if (item.type == MediaType.audio) {
      return Container(
        width: width,
        height: height,
        color: const Color(0xFF1E1E1E),
        alignment: Alignment.center,
        child: Icon(Icons.music_note, size: iconSize, color: Colors.blueAccent),
      );
    }
    if (item.thumbnailPath != null && item.thumbnailPath!.isNotEmpty) {
      return SizedBox(
        width: width,
        height: height,
        child: CachedThumbnailWidget(
          videoId: item.id,
          thumbnailPath: item.thumbnailPath,
          fit: BoxFit.cover,
          cacheWidth: 108,
          cacheHeight: 80,
          placeholder: _buildEpisodeThumbnailPlaceholder(
            width,
            height,
            iconSize,
          ),
          errorWidget: _buildEpisodeThumbnailPlaceholder(
            width,
            height,
            iconSize,
          ),
        ),
      );
    }
    return _buildEpisodeThumbnailPlaceholder(width, height, iconSize);
  }

  Widget _buildEpisodeThumbnailPlaceholder(
    double width,
    double height,
    double iconSize,
  ) {
    return Container(
      width: width,
      height: height,
      color: const Color(0xFF1E1E1E),
      alignment: Alignment.center,
      child: Icon(
        Icons.video_library,
        size: iconSize * 0.8,
        color: Colors.white54,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final playbackService = Provider.of<MediaPlaybackService>(context);
    final playlistManager = Provider.of<PlaylistManager>(context);
    final playlist = playlistManager.playlist;
    final currentItemId = playbackService.currentItem?.id;

    final double panelWidth = widget.panelWidth;
    final double panelHeight = widget.panelHeight;
    final double panelRadius = (panelWidth * 0.03).clamp(12.0, 24.0);
    final double headerHorizontalPadding = (panelWidth * 0.04).clamp(
      14.0,
      24.0,
    );
    final double headerVerticalPadding = (panelHeight * 0.03).clamp(10.0, 16.0);
    final double rowHorizontalPadding = (panelWidth * 0.04).clamp(14.0, 24.0);
    final double rowVerticalPadding = (panelHeight * 0.02).clamp(7.0, 12.0);

    // 增加字号限制，不至于太大，但更清晰
    final double titleFontSize = (panelWidth * 0.033).clamp(13.0, 15.0);
    final double subFontSize = (panelWidth * 0.026).clamp(10.5, 12.0);
    final double currentTagFontSize = (panelWidth * 0.023).clamp(9.5, 11.0);

    final double headerIconSize = (panelWidth * 0.043).clamp(18.0, 24.0);
    final double itemIndexWidth = (panelWidth * 0.048).clamp(24.0, 36.0);
    final double thumbWidth = (panelWidth * 0.13).clamp(56.0, 100.0);
    final double thumbHeight = thumbWidth * 0.65;
    final double itemGap = (panelWidth * 0.018).clamp(8.0, 16.0);
    final double actionIconSize = (panelWidth * 0.038).clamp(18.0, 24.0);

    return GestureDetector(
      onTap: () {}, // 阻止点击穿透
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: panelWidth,
          height: panelHeight,
          decoration: widget.isPortrait
              ? const BoxDecoration(color: Color(0xFF1E1E1E))
              : BoxDecoration(
                  color: const Color(0xEB1E1E1E), // 苹果风格的深色半透明
                  borderRadius: BorderRadius.circular(panelRadius),
                  border: Border.all(color: Colors.white12, width: 0.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 30.0,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
          child: ClipRRect(
            borderRadius: widget.isPortrait
                ? BorderRadius.zero
                : BorderRadius.circular(panelRadius),
            child: Column(
              children: [
                // Header
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: headerHorizontalPadding,
                    vertical: headerVerticalPadding,
                  ),
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: Colors.white10, width: 0.5),
                    ),
                    color: Colors.transparent,
                  ),
                  child: Row(
                    children: [
                      if (widget.isPortrait) ...[
                        IconButton(
                          icon: Icon(
                            Icons.arrow_back_ios_new,
                            color: Colors.white,
                            size: headerIconSize * 0.8,
                          ),
                          tooltip: "返回",
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                          constraints: BoxConstraints.tightFor(
                            width: actionIconSize * 1.8,
                            height: actionIconSize * 1.8,
                          ),
                          onPressed: widget.onClose,
                        ),
                        SizedBox(width: itemGap * 0.5),
                      ] else ...[
                        Icon(
                          Icons.playlist_play,
                          color: Colors.white,
                          size: headerIconSize,
                        ),
                        SizedBox(width: itemGap),
                      ],
                      Expanded(
                        child: Text(
                          "播放列表 (${playlist.length})",
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: titleFontSize,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.skip_previous,
                          color: playlistManager.hasPrevious
                              ? Colors.white
                              : Colors.white38,
                          size: actionIconSize,
                        ),
                        tooltip: "上一集",
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: BoxConstraints.tightFor(
                          width: actionIconSize * 1.8,
                          height: actionIconSize * 1.8,
                        ),
                        onPressed: playlistManager.hasPrevious
                            ? () {
                                playbackService.playPrevious();
                              }
                            : null,
                      ),
                      IconButton(
                        icon: Icon(
                          playbackService.isPlaying
                              ? Icons.pause
                              : Icons.play_arrow,
                          color: Colors.white,
                          size: actionIconSize * 1.2,
                        ),
                        tooltip: playbackService.isPlaying ? "暂停" : "播放",
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: BoxConstraints.tightFor(
                          width: actionIconSize * 1.8,
                          height: actionIconSize * 1.8,
                        ),
                        onPressed: () {
                          if (playbackService.isPlaying) {
                            playbackService.pause();
                          } else {
                            playbackService.resume();
                          }
                        },
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.skip_next,
                          color: playlistManager.hasNext
                              ? Colors.white
                              : Colors.white38,
                          size: actionIconSize,
                        ),
                        tooltip: "下一集",
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: BoxConstraints.tightFor(
                          width: actionIconSize * 1.8,
                          height: actionIconSize * 1.8,
                        ),
                        onPressed: playlistManager.hasNext
                            ? () {
                                playbackService.playNext();
                              }
                            : null,
                      ),
                    ],
                  ),
                ),
                if (playlist.isEmpty)
                  Expanded(
                    child: Center(
                      child: Text(
                        "播放列表为空",
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: titleFontSize,
                        ),
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: ListView.builder(
                      key: _listViewKey,
                      controller: _scrollController,
                      itemCount: playlist.length,
                      padding: EdgeInsets.symmetric(
                        vertical: (panelHeight * 0.02).clamp(8.0, 16.0),
                      ),
                      itemBuilder: (context, index) {
                        final item = playlist[index];
                        final isCurrent = item.id == currentItemId;
                        return Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () {
                              if (!isCurrent) {
                                final targetIndex = playlistManager.indexOfItem(
                                  item.id,
                                );
                                if (targetIndex >= 0) {
                                  playlistManager.setCurrentIndex(targetIndex);
                                }
                                playbackService.playPlaylistItem(item);
                              }
                              // 保持弹窗开启
                            },
                            child: Container(
                              key: isCurrent ? _currentItemKey : null,
                              padding: EdgeInsets.symmetric(
                                horizontal: rowHorizontalPadding,
                                vertical: rowVerticalPadding,
                              ),
                              decoration: BoxDecoration(
                                color: isCurrent
                                    ? Colors.white.withValues(alpha: 0.08)
                                    : Colors.transparent,
                              ),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: itemIndexWidth,
                                    child: Center(
                                      child: isCurrent
                                          ? Icon(
                                              Icons.play_arrow,
                                              color: Colors.white,
                                              size: (panelWidth * 0.035).clamp(
                                                16.0,
                                                22.0,
                                              ),
                                            )
                                          : Text(
                                              "${index + 1}",
                                              style: TextStyle(
                                                color: Colors.white54,
                                                fontSize: subFontSize,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                    ),
                                  ),
                                  SizedBox(width: itemGap),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(
                                      (panelRadius * 0.4).clamp(4.0, 8.0),
                                    ),
                                    child: Stack(
                                      children: [
                                        _buildEpisodeThumbnail(
                                          item: item,
                                          width: thumbWidth,
                                          height: thumbHeight,
                                          iconSize: actionIconSize,
                                        ),
                                        if (item.durationMs > 0)
                                          Positioned(
                                            left: 0,
                                            right: 0,
                                            bottom: 0,
                                            child: SizedBox(
                                              height: 2.5,
                                              child: isCurrent
                                                  ? ValueListenableBuilder<
                                                      Duration
                                                    >(
                                                      valueListenable:
                                                          playbackService
                                                              .coarsePositionNotifier,
                                                      builder: (_, position, _) =>
                                                          LinearProgressIndicator(
                                                            value:
                                                                (position.inMilliseconds /
                                                                        item.durationMs)
                                                                    .clamp(
                                                                      0.0,
                                                                      1.0,
                                                                    ),
                                                            backgroundColor:
                                                                Colors.white24,
                                                            color: Colors
                                                                .redAccent,
                                                          ),
                                                    )
                                                  : item.lastPositionMs > 0
                                                  ? LinearProgressIndicator(
                                                      value:
                                                          (item.lastPositionMs /
                                                                  item.durationMs)
                                                              .clamp(0.0, 1.0),
                                                      backgroundColor:
                                                          Colors.white24,
                                                      color: Colors.redAccent,
                                                    )
                                                  : const SizedBox.shrink(),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  SizedBox(width: itemGap * 1.2),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          item.title,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: isCurrent
                                                ? Colors.white
                                                : Colors.white70,
                                            fontWeight: isCurrent
                                                ? FontWeight.w600
                                                : FontWeight.w400,
                                            fontSize: titleFontSize,
                                            height: 1.3,
                                          ),
                                        ),
                                        SizedBox(
                                          height: (panelHeight * 0.008).clamp(
                                            2.0,
                                            6.0,
                                          ),
                                        ),
                                        Text(
                                          _formatDuration(
                                            Duration(
                                              milliseconds: item.durationMs,
                                            ),
                                          ),
                                          style: TextStyle(
                                            color: Colors.white38,
                                            fontSize: subFontSize,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (isCurrent)
                                    Container(
                                      margin: EdgeInsets.only(left: itemGap),
                                      padding: EdgeInsets.symmetric(
                                        horizontal: (panelWidth * 0.02).clamp(
                                          8.0,
                                          12.0,
                                        ),
                                        vertical: (panelHeight * 0.008).clamp(
                                          3.0,
                                          6.0,
                                        ),
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(
                                          alpha: 0.15,
                                        ),
                                        borderRadius: BorderRadius.circular(
                                          (panelRadius * 0.8).clamp(8.0, 14.0),
                                        ),
                                      ),
                                      child: Text(
                                        "播放中",
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w600,
                                          fontSize: currentTagFontSize,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
