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

  const MiniPlaybackCard({
    super.key,
    required this.isVisible,
    this.onTap,
  });

  @override
  State<MiniPlaybackCard> createState() => _MiniPlaybackCardState();
}

class _MiniPlaybackCardState extends State<MiniPlaybackCard>
    with TickerProviderStateMixin {
  late AnimationController _slideController;
  late Animation<Offset> _slideAnimation;
  late AnimationController _scrollController;
  late Animation<double> _scrollAnimation;

  @override
  void initState() {
    super.initState();
    
    // 初始化滑入/滑出动画控制器
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 1), // 从底部开始
      end: Offset.zero,           // 滑到正常位置
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeInOut,
    ));
    
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
                child: InkWell(
                  onTap: widget.onTap,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(16.0),
                  ),
                  child: Container(
                    height: dimensions.height.clamp(80.0, 200.0),
                    padding: EdgeInsets.all(dimensions.padding.clamp(8.0, 20.0)),
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
        Expanded(
          child: _buildScrollingTitle(currentItem, dimensions),
        ),
        
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
            ? _buildAudioThumbnail(dimensions)
            : _buildVideoThumbnail(item, dimensions),
      ),
    );
  }

  /// 构建音频缩略图
  Widget _buildAudioThumbnail(PlaybackCardDimensions dimensions) {
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
  Widget _buildVideoThumbnail(VideoItem item, PlaybackCardDimensions dimensions) {
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
  Widget _buildScrollingTitle(VideoItem item, PlaybackCardDimensions dimensions) {
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
            if (!_scrollController.isAnimating && _scrollController.status != AnimationStatus.completed) {
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
  Widget _buildPlaylistButton(BuildContext context, PlaybackCardDimensions dimensions) {
    return IconButton(
      icon: Icon(
        Icons.queue_music,
        size: dimensions.iconSize,
        color: Colors.white,
      ),
      onPressed: () {
        _showPlaylistBottomSheet(context);
      },
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
    );
  }

  /// 显示播放列表弹窗
  void _showPlaylistBottomSheet(BuildContext context) {
    final playlistManager = Provider.of<PlaylistManager>(context, listen: false);
    final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
    
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
          child: _buildProgressBar(playbackService),
        ),
        
        SizedBox(width: dimensions.padding),
        
        // 控制按钮
        _buildControlButtons(context, dimensions, playbackService),
      ],
    );
  }

  /// 构建进度条
  Widget _buildProgressBar(MediaPlaybackService playbackService) {
    final position = playbackService.position;
    final duration = playbackService.duration;
    final progress = duration.inMilliseconds > 0
        ? position.inMilliseconds / duration.inMilliseconds
        : 0.0;
    
    return RepaintBoundary(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 进度条
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 2.0, // 减小轨道高度
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4.0), // 减小滑块半径
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 10.0), // 减小覆盖层半径
              activeTrackColor: Colors.blue,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.blue,
              overlayColor: Colors.blue.withValues(alpha: 0.2),
            ),
            child: Slider(
              value: progress.clamp(0.0, 1.0),
              onChanged: (value) {
                final newPosition = Duration(
                  milliseconds: (value * duration.inMilliseconds).round(),
                );
                playbackService.seekTo(newPosition);
              },
            ),
          ),
          
          // 进度文字说明
          Padding(
            padding: const EdgeInsets.only(left: 8.0, right: 8.0),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                '${_formatDuration(position)} / ${_formatDuration(duration)}',
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
    final playlistManager = Provider.of<PlaylistManager>(context, listen: false);
    
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 上一集按钮
        IconButton(
          icon: Icon(
            Icons.skip_previous,
            size: dimensions.iconSize * 0.9, // 稍微减小图标尺寸
            color: playlistManager.hasPrevious ? Colors.white : Colors.white38,
          ),
          onPressed: playlistManager.hasPrevious
              ? () => playbackService.playPrevious()
              : null,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32), // 减小最小尺寸
        ),
        
        SizedBox(width: dimensions.padding / 2), // 减小间距
        
        // 播放/暂停按钮
        IconButton(
          icon: Icon(
            playbackService.isPlaying ? Icons.pause : Icons.play_arrow,
            size: dimensions.iconSize * 1.1, // 稍微减小播放按钮尺寸
            color: Colors.white,
          ),
          onPressed: () {
            if (playbackService.isPlaying) {
              playbackService.pause();
            } else {
              playbackService.resume();
            }
          },
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36), // 减小最小尺寸
        ),
        
        SizedBox(width: dimensions.padding / 2), // 减小间距
        
        // 下一集按钮
        IconButton(
          icon: Icon(
            Icons.skip_next,
            size: dimensions.iconSize * 0.9, // 稍微减小图标尺寸
            color: playlistManager.hasNext ? Colors.white : Colors.white38,
          ),
          onPressed: playlistManager.hasNext
              ? () => playbackService.playNext()
              : null,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32), // 减小最小尺寸
        ),
        
        SizedBox(width: dimensions.padding / 2), // 减小间距
        
        // 静音按钮
        IconButton(
          icon: Icon(
            playbackService.isMuted ? Icons.volume_off : Icons.volume_up,
            size: dimensions.iconSize * 0.9, // 稍微减小图标尺寸
            color: Colors.white,
          ),
          onPressed: () => playbackService.toggleMute(),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32), // 减小最小尺寸
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
    
    return Container(
      height: 28.0, // 略微增加高度以容纳更大的按钮
      padding: EdgeInsets.symmetric(horizontal: dimensions.padding),
      child: Row(
        children: [
          // 字幕文本（支持横向滚动）
          Expanded(
            child: currentSubtitle != null && currentSubtitle.text.isNotEmpty
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Text(
                      currentSubtitle.text,
                      style: TextStyle(
                        fontSize: dimensions.subtitleFontSize,
                        color: Colors.white70,
                        height: 1.3,
                        fontStyle: FontStyle.normal,
                      ),
                      maxLines: 1,
                    ),
                  )
                : Text(
                    hasSubtitles ? '' : '无字幕',
                    style: TextStyle(
                      fontSize: dimensions.subtitleFontSize,
                      color: Colors.white38,
                      fontStyle: FontStyle.normal,
                    ),
                  ),
          ),
          
          // 字幕导航按钮（仅在有字幕时显示）
          if (hasSubtitles) ...[
            SizedBox(width: dimensions.padding / 3),
            
            // 上一句字幕按钮 - 使用圆形背景和不同图标
            Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: Icon(
                  Icons.keyboard_arrow_left_rounded,
                  size: dimensions.iconSize * 0.95, // 增大图标尺寸
                  color: Colors.white,
                ),
                onPressed: () => playbackService.seekToPreviousSubtitle(),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32), // 增大点按范围
                tooltip: '上一句字幕',
              ),
            ),
            
            SizedBox(width: dimensions.padding / 4),
            
            // 下一句字幕按钮 - 使用圆形背景和不同图标
            Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: Icon(
                  Icons.keyboard_arrow_right_rounded,
                  size: dimensions.iconSize * 0.95, // 增大图标尺寸
                  color: Colors.white,
                ),
                onPressed: () => playbackService.seekToNextSubtitle(),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32), // 增大点按范围
                tooltip: '下一句字幕',
              ),
            ),
          ],
        ],
      ),
    );
  }
}
