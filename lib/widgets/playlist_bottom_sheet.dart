import 'package:flutter/material.dart';
import '../models/video_item.dart';
import 'cached_thumbnail_widget.dart';

/// 播放列表底部弹窗组件
class PlaylistBottomSheet extends StatelessWidget {
  /// 播放列表
  final List<VideoItem> playlist;
  
  /// 当前播放项ID
  final String? currentItemId;
  
  /// 点击列表项回调
  final Function(VideoItem) onItemTap;
  
  /// 滚动控制器（用于 DraggableScrollableSheet）
  final ScrollController? scrollController;

  const PlaylistBottomSheet({
    super.key,
    required this.playlist,
    this.currentItemId,
    required this.onItemTap,
    this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2C),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16.0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 16.0,
            offset: const Offset(0, -4),
            spreadRadius: 0,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 顶部拖动指示器
          _buildDragHandle(),
          
          // 标题栏
          _buildHeader(),
          
          // 播放列表
          _buildPlaylist(context),
        ],
      ),
    );
  }

  /// 构建拖动指示器
  Widget _buildDragHandle() {
    return Container(
      margin: const EdgeInsets.only(top: 12.0),
      width: 40.0,
      height: 4.0,
      decoration: BoxDecoration(
        color: Colors.white24,
        borderRadius: BorderRadius.circular(2.0),
      ),
    );
  }

  /// 构建标题栏
  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        children: [
          const Icon(
            Icons.queue_music,
            color: Colors.white,
            size: 24.0,
          ),
          const SizedBox(width: 12.0),
          Text(
            '播放列表 (${playlist.length})',
            style: const TextStyle(
              fontSize: 18.0,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  /// 构建播放列表
  Widget _buildPlaylist(BuildContext context) {
    if (playlist.isEmpty) {
      return _buildEmptyState();
    }

    return Flexible(
      child: ListView.builder(
        controller: scrollController,
        shrinkWrap: true,
        itemCount: playlist.length,
        padding: const EdgeInsets.only(bottom: 16.0),
        itemBuilder: (context, index) {
          final item = playlist[index];
          final isCurrent = item.id == currentItemId;
          
          return _buildPlaylistItem(context, item, isCurrent, index);
        },
      ),
    );
  }

  /// 构建播放列表项
  Widget _buildPlaylistItem(
    BuildContext context,
    VideoItem item,
    bool isCurrent,
    int index,
  ) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          onItemTap(item);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 16.0,
            vertical: 12.0,
          ),
          decoration: BoxDecoration(
            color: isCurrent ? Colors.blue.withValues(alpha: 0.1) : Colors.transparent,
            border: Border(
              left: BorderSide(
                color: isCurrent ? Colors.blue : Colors.transparent,
                width: 4.0,
              ),
            ),
          ),
          child: Row(
            children: [
              // 序号或播放图标
              _buildLeadingIcon(isCurrent, index),
              
              const SizedBox(width: 12.0),
              
              // 缩略图
              _buildThumbnail(item),
              
              const SizedBox(width: 12.0),
              
              // 标题和时长信息
              Expanded(
                child: _buildItemInfo(item, isCurrent),
              ),
              
              // 当前播放指示器
              if (isCurrent) _buildCurrentIndicator(),
            ],
          ),
        ),
      ),
    );
  }

  /// 构建前导图标
  Widget _buildLeadingIcon(bool isCurrent, int index) {
    if (isCurrent) {
      return Container(
        width: 32.0,
        height: 32.0,
        decoration: BoxDecoration(
          color: Colors.blue,
          borderRadius: BorderRadius.circular(16.0),
        ),
        child: const Icon(
          Icons.play_arrow,
          color: Colors.white,
          size: 20.0,
        ),
      );
    }
    
    return SizedBox(
      width: 32.0,
      height: 32.0,
      child: Center(
        child: Text(
          '${index + 1}',
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 14.0,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  /// 构建缩略图
  Widget _buildThumbnail(VideoItem item) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12.0),
      child: Container(
        width: 60.0,
        height: 45.0,
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 4.0,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: item.type == MediaType.audio
            ? _buildAudioThumbnail()
            : _buildVideoThumbnail(item),
      ),
    );
  }

  /// 构建音频缩略图
  Widget _buildAudioThumbnail() {
    return Container(
      color: const Color(0xFF1E1E1E),
      child: const Icon(
        Icons.music_note,
        size: 24.0,
        color: Colors.blue,
      ),
    );
  }

  /// 构建视频缩略图
  Widget _buildVideoThumbnail(VideoItem item) {
    if (item.thumbnailPath != null && item.thumbnailPath!.isNotEmpty) {
      return CachedThumbnailWidget(
        videoId: item.id,
        thumbnailPath: item.thumbnailPath,
        fit: BoxFit.cover,
        cacheWidth: 120,
        cacheHeight: 90,
        placeholder: _buildThumbnailPlaceholder(),
        errorWidget: _buildThumbnailPlaceholder(),
      );
    }
    return _buildThumbnailPlaceholder();
  }

  /// 构建缩略图占位符
  Widget _buildThumbnailPlaceholder() {
    return Container(
      color: const Color(0xFF1E1E1E),
      child: const Icon(
        Icons.video_library,
        size: 24.0,
        color: Colors.white54,
      ),
    );
  }

  /// 构建项目信息
  Widget _buildItemInfo(VideoItem item, bool isCurrent) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题
        Text(
          item.title,
          style: TextStyle(
            color: isCurrent ? Colors.blue : Colors.white,
            fontSize: 14.0,
            fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        
        const SizedBox(height: 4.0),
        
        // 时长信息
        Text(
          _formatDuration(Duration(milliseconds: item.durationMs)),
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 12.0,
          ),
        ),
      ],
    );
  }

  /// 构建当前播放指示器
  Widget _buildCurrentIndicator() {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 8.0,
        vertical: 4.0,
      ),
      decoration: BoxDecoration(
        color: Colors.blue,
        borderRadius: BorderRadius.circular(12.0),
      ),
      child: const Text(
        '播放中',
        style: TextStyle(
          color: Colors.white,
          fontSize: 10.0,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  /// 构建空状态
  Widget _buildEmptyState() {
    return Container(
      padding: const EdgeInsets.all(32.0),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.queue_music,
            size: 64.0,
            color: Colors.white24,
          ),
          SizedBox(height: 16.0),
          Text(
            '播放列表为空',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 16.0,
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
}
