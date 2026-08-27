import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/video_item.dart';
import '../services/media_playback_service.dart';
import '../services/playlist_manager.dart';
import 'playback_card_layout.dart';
import 'playlist_bottom_sheet.dart';
import 'cached_thumbnail_widget.dart';

/// 底部播放卡片组件
class MiniPlaybackCard extends StatefulWidget {
  /// 是否显示卡片
  final bool isVisible;

  /// 点击卡片回调（用于进入全屏播放）
  final VoidCallback? onTap;

  const MiniPlaybackCard({super.key, required this.isVisible, this.onTap});

  @override
  State<MiniPlaybackCard> createState() => _MiniPlaybackCardState();
}

class _MiniPlaybackCardState extends State<MiniPlaybackCard>
    with TickerProviderStateMixin {
  late AnimationController _slideController;
  late Animation<Offset> _slideAnimation;
  late AnimationController _scrollController;
  late Animation<double> _scrollAnimation;

  // 进度条拖动状态
  bool _isDraggingProgress = false;
  bool _isProgressDragCanceling = false;
  double _dragProgressValue = 0.0;

  static const Duration _tooltipWaitDuration = Duration(milliseconds: 450);

  @override
  void initState() {
    super.initState();

    // 初始化滑入/滑出动画控制器
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    _slideAnimation =
        Tween<Offset>(
          begin: const Offset(0, 1), // 从底部开始
          end: Offset.zero, // 滑到正常位置
        ).animate(
          CurvedAnimation(parent: _slideController, curve: Curves.easeInOut),
        );

    // 初始化标题滚动动画控制器
    _scrollController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    );

    _scrollAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(_scrollController);

    // 根据初始可见性状态设置动画
    if (widget.isVisible) {
      _slideController.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(MiniPlaybackCard oldWidget) {
    super.didUpdateWidget(oldWidget);

    // 当可见性改变时触发动画
    if (widget.isVisible != oldWidget.isVisible) {
      if (widget.isVisible) {
        _slideController.forward();
      } else {
        _slideController.reverse();
      }
    }
  }

  @override
  void dispose() {
    _slideController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 判断拖动是否处于取消区域
  bool _isInCancelArea(Offset globalPosition) {
    if (!mounted) return false;
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null) return false;
    final localOffset = box.globalToLocal(globalPosition);
    // 向上滑动超出卡片顶部 30 像素时视为取消
    return localOffset.dy < -30.0;
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SlideTransition(
        position: _slideAnimation,
        child: Consumer<MediaPlaybackService>(
          builder: (context, playbackService, child) {
            final currentItem = playbackService.currentItem;

            // 如果没有当前播放项，返回空容器
            if (currentItem == null) {
              return const SizedBox.shrink();
            }

            // 获取响应式布局尺寸
            final dimensions = PlaybackCardLayout.calculate(context);

            return Container(
              constraints: BoxConstraints(
                maxHeight: dimensions.height.clamp(80.0, 200.0),
              ),
              decoration: BoxDecoration(
                color: const Color(0xFF2C2C2C),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(16.0),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 12.0,
                    offset: const Offset(0, -4),
                    spreadRadius: 0,
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: Tooltip(
                  message: '打开播放器',
                  waitDuration: _tooltipWaitDuration,
                  child: InkWell(
                    onTap: widget.onTap,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(16.0),
                    ),
                    child: Stack(
                      children: [
                        Container(
                          height: dimensions.height.clamp(80.0, 200.0),
                          padding: EdgeInsets.all(
                            dimensions.padding.clamp(8.0, 20.0),
                          ),
                          child: Column(
                            children: [
                              // 第一行：缩略图、标题、列表展开按钮
                              Expanded(
                                flex: 3,
                                child: _buildFirstRow(
                                  context,
                                  currentItem,
                                  dimensions,
                                  playbackService,
                                ),
                              ),

                              SizedBox(height: dimensions.padding / 3),

                              // 新增：字幕显示行
                              _buildSubtitleRow(
                                context,
                                dimensions,
                                playbackService,
                              ),

                              SizedBox(height: dimensions.padding / 3),

                              // 第二行：进度条、控制按钮
                              Expanded(
                                flex: 2,
                                child: _buildSecondRow(
                                  context,
                                  dimensions,
                                  playbackService,
                                ),
                              ),
                            ],
                          ),
                        ),

                        // 取消拖动提示遮罩层
                        if (_isDraggingProgress && _isProgressDragCanceling)
                          Positioned.fill(
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.75),
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(16.0),
                                ),
                              ),
                              child: const Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.undo,
                                      color: Colors.white,
                                      size: 36,
                                    ),
                                    SizedBox(height: 8),
                                    Text(
                                      "松手取消跳转",
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
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
            );
          },
        ),
      ),
    );
  }

  /// 构建第一行：缩略图、标题、列表展开按钮
  Widget _buildFirstRow(
    BuildContext context,
    VideoItem currentItem,
    PlaybackCardDimensions dimensions,
    MediaPlaybackService playbackService,
  ) {
    return Row(
      children: [
        // 缩略图
        _buildThumbnail(currentItem, dimensions),

        SizedBox(width: dimensions.padding),

        // 标题（带滚动动画）
        Expanded(child: _buildScrollingTitle(currentItem, dimensions)),

        SizedBox(width: dimensions.padding),

        // 列表展开按钮
        _buildPlaylistButton(context, dimensions),
      ],
    );
  }

  /// 构建缩略图
  Widget _buildThumbnail(VideoItem item, PlaybackCardDimensions dimensions) {
    return Container(
      width: dimensions.thumbnailSize,
      height: dimensions.thumbnailSize,
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12.0),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 4.0,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12.0),
        child: item.type == MediaType.audio
            ? _buildAudioThumbnail(item, dimensions)
            : _buildVideoThumbnail(item, dimensions),
      ),
    );
  }

  /// 构建音频缩略图（优先显示封面图，无封面则显示占位图标）
  Widget _buildAudioThumbnail(
    VideoItem item,
    PlaybackCardDimensions dimensions,
  ) {
    if (item.thumbnailPath != null && item.thumbnailPath!.isNotEmpty) {
      return CachedThumbnailWidget(
        videoId: item.id,
        thumbnailPath: item.thumbnailPath,
        fit: BoxFit.cover,
        cacheWidth: (dimensions.thumbnailSize * 2).toInt(),
        cacheHeight: (dimensions.thumbnailSize * 2).toInt(),
        placeholder: _buildAudioThumbnailPlaceholder(dimensions),
        errorWidget: _buildAudioThumbnailPlaceholder(dimensions),
      );
    }
    return _buildAudioThumbnailPlaceholder(dimensions);
  }

  Widget _buildAudioThumbnailPlaceholder(PlaybackCardDimensions dimensions) {
    return Container(
      color: const Color(0xFF1E1E1E),
      child: Icon(
        Icons.music_note,
        size: dimensions.thumbnailSize * 0.5,
        color: Colors.blue,
      ),
    );
  }

  /// 构建视频缩略图
  Widget _buildVideoThumbnail(
    VideoItem item,
    PlaybackCardDimensions dimensions,
  ) {
    if (item.thumbnailPath != null && item.thumbnailPath!.isNotEmpty) {
      return CachedThumbnailWidget(
        videoId: item.id,
        thumbnailPath: item.thumbnailPath,
        fit: BoxFit.cover,
        cacheWidth: (dimensions.thumbnailSize * 2).toInt(),
        cacheHeight: (dimensions.thumbnailSize * 2).toInt(),
        placeholder: _buildThumbnailPlaceholder(dimensions),
        errorWidget: _buildThumbnailPlaceholder(dimensions),
      );
    }
    return _buildThumbnailPlaceholder(dimensions);
  }

  /// 构建缩略图占位符
  Widget _buildThumbnailPlaceholder(PlaybackCardDimensions dimensions) {
    return Container(
      color: const Color(0xFF1E1E1E),
      child: Icon(
        Icons.video_library,
        size: dimensions.thumbnailSize * 0.5,
        color: Colors.white54,
      ),
    );
  }

  /// 构建滚动标题
  Widget _buildScrollingTitle(
    VideoItem item,
    PlaybackCardDimensions dimensions,
  ) {
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 测量文本宽度
          final textPainter = TextPainter(
            text: TextSpan(
              text: item.title,
              style: TextStyle(
                fontSize: dimensions.titleFontSize,
                color: Colors.white,
              ),
            ),
            maxLines: 1,
            textDirection: TextDirection.ltr,
          )..layout();

          final textWidth = textPainter.width;
          final containerWidth = constraints.maxWidth;

          // 如果文本宽度超过容器宽度，启用滚动
          if (textWidth > containerWidth && widget.isVisible) {
            // 启动滚动动画
            if (!_scrollController.isAnimating &&
                _scrollController.status != AnimationStatus.completed) {
              _scrollController.repeat();
            }

            return ClipRect(
              child: AnimatedBuilder(
                animation: _scrollAnimation,
                builder: (context, child) {
                  final offset = _scrollAnimation.value * (textWidth + 50);

                  return Transform.translate(
                    offset: Offset(-offset, 0),
                    transformHitTests: false,
                    child: Row(
                      children: [
                        // 第一个文本实例
                        Text(
                          item.title,
                          style: TextStyle(
                            fontSize: dimensions.titleFontSize,
                            color: Colors.white,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.visible,
                        ),
                        const SizedBox(width: 50),
                        // 第二个文本实例（用于循环）
                        Text(
                          item.title,
                          style: TextStyle(
                            fontSize: dimensions.titleFontSize,
                            color: Colors.white,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.visible,
                        ),
                      ],
                    ),
                  );
                },
              ),
            );
          } else {
            // 文本宽度未超过容器，停止滚动动画
            if (_scrollController.isAnimating) {
              _scrollController.stop();
              _scrollController.reset();
            }

            return Text(
              item.title,
              style: TextStyle(
                fontSize: dimensions.titleFontSize,
                color: Colors.white,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            );
          }
        },
      ),
    );
  }

  /// 构建播放列表按钮
  Widget _buildPlaylistButton(
    BuildContext context,
    PlaybackCardDimensions dimensions,
  ) {
    return _buildActionButton(
      icon: Icons.queue_music,
      tooltip: '播放列表',
      onPressed: () {
        _showPlaylistBottomSheet(context);
      },
      iconSize: dimensions.iconSize,
      buttonSize: _resolveButtonSize(dimensions),
    );
  }

  /// 显示播放列表弹窗
  void _showPlaylistBottomSheet(BuildContext context) {
    final playlistManager = Provider.of<PlaylistManager>(
      context,
      listen: false,
    );
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return PlaylistBottomSheet(
              playlist: playlistManager.playlist,
              currentItemId: playbackService.currentItem?.id,
              scrollController: scrollController,
              onItemTap: (item) {
                Navigator.pop(context);
                final index = playlistManager.indexOfItem(item.id);
                if (index >= 0) {
                  playlistManager.setCurrentIndex(index);
                }
                playbackService.play(item);
              },
            );
          },
        );
      },
    );
  }

  /// 构建第二行：进度条、控制按钮
  Widget _buildSecondRow(
    BuildContext context,
    PlaybackCardDimensions dimensions,
    MediaPlaybackService playbackService,
  ) {
    return Row(
      children: [
        // 进度条
        Expanded(
          child: ValueListenableBuilder<Duration>(
            valueListenable: playbackService.coarsePositionNotifier,
            builder: (_, position, _) =>
                _buildProgressBar(playbackService, position),
          ),
        ),

        SizedBox(width: dimensions.padding),

        // 控制按钮
        _buildControlButtons(context, dimensions, playbackService),
      ],
    );
  }

  /// 构建进度条
  Widget _buildProgressBar(
    MediaPlaybackService playbackService,
    Duration position,
  ) {
    final duration = playbackService.duration;

    // 如果正在拖动，使用拖动的进度
    final currentProgress = _isDraggingProgress
        ? _dragProgressValue
        : (duration.inMilliseconds > 0
              ? position.inMilliseconds / duration.inMilliseconds
              : 0.0);

    final displayPosition = _isDraggingProgress
        ? Duration(
            milliseconds: (_dragProgressValue * duration.inMilliseconds)
                .round(),
          )
        : position;

    return RepaintBoundary(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 进度条
          Listener(
            behavior: HitTestBehavior.translucent,
            onPointerMove: (event) {
              if (!_isDraggingProgress) return;
              final isInCancelArea = _isInCancelArea(event.position);
              if (isInCancelArea != _isProgressDragCanceling) {
                setState(() {
                  _isProgressDragCanceling = isInCancelArea;
                });
              }
            },
            onPointerCancel: (event) {
              if (!_isDraggingProgress) return;
              setState(() {
                _isDraggingProgress = false;
                _isProgressDragCanceling = false;
              });
            },
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 2.0, // 减小轨道高度
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 4.0,
                ), // 减小滑块半径
                overlayShape: const RoundSliderOverlayShape(
                  overlayRadius: 10.0,
                ), // 减小覆盖层半径
                activeTrackColor: _isProgressDragCanceling
                    ? Colors.grey
                    : Colors.blue,
                inactiveTrackColor: Colors.white24,
                thumbColor: _isProgressDragCanceling
                    ? Colors.grey
                    : Colors.blue,
                overlayColor: _isProgressDragCanceling
                    ? Colors.grey.withValues(alpha: 0.2)
                    : Colors.blue.withValues(alpha: 0.2),
              ),
              child: Slider(
                value: currentProgress.clamp(0.0, 1.0),
                onChanged: (value) {
                  setState(() {
                    _isDraggingProgress = true;
                    _dragProgressValue = value;
                  });
                },
                onChangeEnd: (value) {
                  if (!_isProgressDragCanceling) {
                    final newPosition = Duration(
                      milliseconds: (value * duration.inMilliseconds).round(),
                    );
                    playbackService.seekTo(newPosition);
                  }
                  setState(() {
                    _isDraggingProgress = false;
                    _isProgressDragCanceling = false;
                  });
                },
              ),
            ),
          ),

          // 进度文字说明
          Padding(
            padding: const EdgeInsets.only(left: 8.0, right: 8.0),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                '${_formatDuration(displayPosition)} / ${_formatDuration(duration)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 9.0,
                  height: 1.0,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 格式化时长
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

  /// 构建控制按钮
  Widget _buildControlButtons(
    BuildContext context,
    PlaybackCardDimensions dimensions,
    MediaPlaybackService playbackService,
  ) {
    final playlistManager = Provider.of<PlaylistManager>(
      context,
      listen: false,
    );
    final buttonSize = _resolveControlButtonSize(dimensions);
    final primaryButtonSize = (buttonSize + 4.0).clamp(46.0, 56.0);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 上一集按钮
        _buildActionButton(
          icon: Icons.skip_previous,
          tooltip: '上一项',
          onPressed: playlistManager.hasPrevious
              ? () => playbackService.playPrevious()
              : null,
          iconSize: dimensions.iconSize * 0.9,
          buttonSize: buttonSize,
        ),

        SizedBox(width: dimensions.padding / 4), // 减小间距
        // 播放/暂停按钮
        _buildActionButton(
          icon: playbackService.isPlaying ? Icons.pause : Icons.play_arrow,
          tooltip: playbackService.isPlaying ? '暂停' : '播放',
          onPressed: () {
            if (playbackService.isPlaying) {
              playbackService.pause();
            } else {
              playbackService.resume();
            }
          },
          iconSize: dimensions.iconSize * 1.1,
          buttonSize: primaryButtonSize,
        ),

        SizedBox(width: dimensions.padding / 4), // 减小间距
        // 下一集按钮
        _buildActionButton(
          icon: Icons.skip_next,
          tooltip: '下一项',
          onPressed: playlistManager.hasNext
              ? () => playbackService.playNext()
              : null,
          iconSize: dimensions.iconSize * 0.9,
          buttonSize: buttonSize,
        ),

        SizedBox(width: dimensions.padding / 4), // 减小间距
        // 静音按钮
        _buildActionButton(
          icon: playbackService.isMuted ? Icons.volume_off : Icons.volume_up,
          tooltip: playbackService.isMuted ? '取消静音' : '静音',
          onPressed: () => playbackService.toggleMute(),
          iconSize: dimensions.iconSize * 0.9,
          buttonSize: _resolveButtonSize(dimensions),
        ),
      ],
    );
  }

  /// 构建字幕显示行
  Widget _buildSubtitleRow(
    BuildContext context,
    PlaybackCardDimensions dimensions,
    MediaPlaybackService playbackService,
  ) {
    final currentSubtitle = playbackService.currentSubtitle;
    final hasSubtitles = playbackService.subtitles.isNotEmpty;
    final bool isImageSubtitle =
        currentSubtitle != null &&
        currentSubtitle.text.isEmpty &&
        currentSubtitle.imageLoader != null;
    final String subtitleLabel = currentSubtitle != null
        ? (currentSubtitle.text.isNotEmpty
              ? currentSubtitle.text
              : (isImageSubtitle ? '[图片字幕]' : '当前时刻无字幕'))
        : (hasSubtitles ? '当前时刻无字幕' : '无字幕');
    final bool usePlaceholderStyle =
        currentSubtitle == null || currentSubtitle.text.isEmpty;

    return Container(
      height: 28.0, // 略微增加高度以容纳更大的按钮
      padding: EdgeInsets.symmetric(horizontal: dimensions.padding),
      child: Row(
        children: [
          // 字幕文本（支持横向滚动）
          Expanded(
            child: subtitleLabel.isNotEmpty
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Text(
                      subtitleLabel,
                      style: TextStyle(
                        fontSize: dimensions.subtitleFontSize,
                        color: usePlaceholderStyle
                            ? Colors.white38
                            : Colors.white70,
                        height: 1.3,
                        fontStyle: FontStyle.normal,
                      ),
                      maxLines: 1,
                    ),
                  )
                : const SizedBox.shrink(),
          ),

          // 字幕导航按钮（仅在有字幕时显示）
          if (hasSubtitles) ...[
            SizedBox(width: dimensions.padding / 3),

            // 上一句字幕按钮 - 使用圆形背景和不同图标
            _buildActionButton(
              icon: Icons.keyboard_arrow_left_rounded,
              tooltip: '上一句字幕',
              onPressed: () => playbackService.seekToPreviousSubtitle(),
              iconSize: dimensions.iconSize * 0.95,
              buttonSize: _resolveSubtitleButtonSize(dimensions),
              backgroundColor: Colors.white.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),

            SizedBox(width: dimensions.padding / 4),

            // 下一句字幕按钮 - 使用圆形背景和不同图标
            _buildActionButton(
              icon: Icons.keyboard_arrow_right_rounded,
              tooltip: '下一句字幕',
              onPressed: () => playbackService.seekToNextSubtitle(),
              iconSize: dimensions.iconSize * 0.95,
              buttonSize: _resolveSubtitleButtonSize(dimensions),
              backgroundColor: Colors.white.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
          ],
        ],
      ),
    );
  }

  double _resolveButtonSize(PlaybackCardDimensions dimensions) {
    return (dimensions.iconSize + 20.0).clamp(40.0, 50.0);
  }

  double _resolveControlButtonSize(PlaybackCardDimensions dimensions) {
    return (dimensions.iconSize + 28.0).clamp(48.0, 56.0);
  }

  double _resolveSubtitleButtonSize(PlaybackCardDimensions dimensions) {
    return (dimensions.iconSize + 12.0).clamp(36.0, 44.0);
  }

  Widget _buildActionButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    required double iconSize,
    required double buttonSize,
    Color? backgroundColor,
    BoxShape shape = BoxShape.circle,
  }) {
    final bool enabled = onPressed != null;
    final Color resolvedBackgroundColor =
        backgroundColor ??
        (enabled
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.white.withValues(alpha: 0.02));
    final Color iconColor = enabled ? Colors.white : Colors.white38;

    return Tooltip(
      message: tooltip,
      waitDuration: _tooltipWaitDuration,
      child: SizedBox(
        width: buttonSize,
        height: buttonSize,
        child: Material(
          color: resolvedBackgroundColor,
          shape: shape == BoxShape.circle
              ? const CircleBorder()
              : RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(buttonSize * 0.28),
                ),
          clipBehavior: Clip.antiAlias,
          child: InkResponse(
            onTap: onPressed,
            containedInkWell: true,
            highlightShape: shape == BoxShape.circle
                ? BoxShape.circle
                : BoxShape.rectangle,
            radius: buttonSize / 2,
            child: Center(
              child: Icon(icon, size: iconSize, color: iconColor),
            ),
          ),
        ),
      ),
    );
  }
}
