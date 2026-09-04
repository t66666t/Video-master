import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'cached_thumbnail_widget.dart';
import 'music_text_optical_alignment.dart';

/// Apple Music 风格专辑封面卡片组件（响应式 vh 单位）
///
/// 视觉层次（从外到内）：
/// 1. 圆角封面容器（显示实际封面图片 或 音符占位符）
/// 2. 封面下方：歌曲信息（歌名 + 艺术家—专辑）
///
/// 替代原 CD 碟片设计，严格对齐 Apple Music 全屏播放页面截图布局。
/// 所有尺寸基于屏幕高度 (vh) 计算。
/// 交互：双击封面区域触发 [onDoubleTap] 回调（仅视频媒体）
class MusicAlbumCover extends StatefulWidget {
  final String? coverImagePath;
  final String title;
  final String artist;
  final String album;

  /// 双击封面回调（仅视频媒体有效）
  final VoidCallback? onDoubleTap;

  /// 是否为音频媒体（音频媒体无封面时显示音符占位符）
  final bool isAudio;

  /// 媒体唯一标识符（用于通过 ThumbnailCacheService 加载本地封面文件）
  final String? videoId;

  /// 是否以视频画面替代静态封面（双击封面切换）。仅对视频媒体有效。
  final bool showVideo;

  /// 视频控制器（双击封面后用于渲染实际视频画面）。
  /// 直接复用播放服务的控制器，保证与播放进度/状态完全同步。
  final VideoPlayerController? videoController;

  /// 封面卡片尺寸（可选）。若不传则基于屏幕高度自动计算。
  /// 由父组件传入可确保在横屏小屏上不超出可用空间。
  final double? coverSize;

  /// 歌曲信息文本区域宽度（可选）。手机横屏下可大于封面宽度，避免文字拥挤。
  final double? infoWidth;

  /// 是否显示歌曲信息（标题/艺术家）。默认 true。
  /// 设为 false 时仅显示封面图片，不显示下方歌曲信息，
  /// 用于横屏布局中歌曲信息独立显示的场景。
  final bool showSongInfo;

  const MusicAlbumCover({
    super.key,
    this.coverImagePath,
    required this.title,
    this.artist = '',
    this.album = '',
    this.onDoubleTap,
    this.isAudio = false,
    this.videoId,
    this.coverSize,
    this.infoWidth,
    this.showVideo = false,
    this.videoController,
    this.showSongInfo = true,
    required void Function() onExitTrigger,
  });

  @override
  State<MusicAlbumCover> createState() => _MusicAlbumCoverState();
}

class _MusicAlbumCoverState extends State<MusicAlbumCover>
    with TickerProviderStateMixin {
  late AnimationController _scaleController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _scaleAnimation = CurvedAnimation(
      parent: _scaleController,
      curve: Curves.easeOutBack,
    );
    _scaleController.forward();
  }

  @override
  void dispose() {
    _scaleController.dispose();
    super.dispose();
  }

  /// 判断文本是否包含中文（与字幕逻辑一致）
  bool _isChineseText(String text) {
    return RegExp(r'[\u4e00-\u9fff]').hasMatch(text);
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    // 封面尺寸：优先使用父组件传入的值，否则基于 48vh 自动计算
    final size = widget.coverSize ?? (screenHeight * 0.48).clamp(120.0, 380.0);
    // 圆角半径 ~2%
    final borderRadius = size * 0.02;
    // 封面到歌曲信息间距：~4vh
    final infoGap = (screenHeight * 0.04).clamp(12.0, 32.0);
    // 歌曲名字号：~2.5vh
    final titleSize = (screenHeight * 0.025).clamp(13.0, 22.0);
    // 艺术家字号：~2vh
    final artistSize = (screenHeight * 0.02).clamp(11.0, 18.0);

    return ScaleTransition(
      scale: _scaleAnimation,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildCoverImage(size, borderRadius),
          if (widget.showSongInfo) ...[
            SizedBox(height: infoGap),
            _buildSongInfo(size, titleSize, artistSize),
          ],
        ],
      ),
    );
  }

  /// 构建封面图片（或音频占位符）
  Widget _buildCoverImage(double size, double borderRadius) {
    return GestureDetector(
      onDoubleTap: widget.isAudio ? null : widget.onDoubleTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFFE8E8ED), // 浅灰底色（与Apple Music一致）
          borderRadius: BorderRadius.circular(borderRadius),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: size * 0.12,
              offset: Offset(0, size * 0.03),
            ),
          ],
        ),
        clipBehavior: Clip.hardEdge,
        child: _buildCoverContent(size, borderRadius),
      ),
    );
  }

  /// 封面内容：有 videoId→CachedThumbnailWidget 加载本地封面；
  /// 无路径且音频→音符占位符；否则空白
  Widget _buildCoverContent(double size, double borderRadius) {
    final path = widget.coverImagePath;
    final videoId = widget.videoId;

    // 双击封面切换为视频：showVideo 开启且控制器已初始化时，显示实际视频画面。
    // 视频与播放服务共用同一控制器，因此画面、进度、播放/暂停状态完全同步。
    if (widget.showVideo &&
        widget.videoController != null &&
        widget.videoController!.value.isInitialized) {
      final controller = widget.videoController!;
      // 用 cover 方式填充方形封面区域，避免视频被拉伸变形
      return ClipRect(
        child: SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            child: AspectRatio(
              aspectRatio: controller.value.aspectRatio,
              child: VideoPlayer(controller),
            ),
          ),
        ),
      );
    }

    // 有 videoId 和缩略图路径：使用 CachedThumbnailWidget 加载本地文件封面
    if (videoId != null &&
        videoId.isNotEmpty &&
        path != null &&
        path.isNotEmpty) {
      return CachedThumbnailWidget(
        videoId: videoId,
        thumbnailPath: path,
        fit: BoxFit.cover,
        placeholder: _buildMusicNotePlaceholder(size),
        errorWidget: _buildMusicNotePlaceholder(size),
      );
    }
    // 无封面路径但为音频媒体：显示音符占位符
    if (widget.isAudio) {
      return _buildMusicNotePlaceholder(size);
    }
    // 无封面路径且非音频：显示音符占位符作为通用占位
    return _buildMusicNotePlaceholder(size);
  }

  /// 音频媒体的音符占位符（与媒体管理页面的网格视图风格一致）
  Widget _buildMusicNotePlaceholder(double size) {
    final noteSize = size * 0.22; // 网格视图中50px/200px ≈ 25%
    return Container(
      width: size,
      height: size,
      color: Colors.black,
      child: Icon(
        Icons.music_note,
        size: noteSize.clamp(30.0, 70.0),
        color: Colors.white.withValues(alpha: 0.24),
      ),
    );
  }

  /// 2 行歌曲信息（Apple Music 截图风格）
  /// 第1行：歌曲名 — 白色, 居中
  /// 第2行：艺术家 — 专辑名 — 半透明白色, 居中
  Widget _buildSongInfo(double size, double titleSize, double artistSize) {
    final screenHeight = MediaQuery.of(context).size.height;
    // 歌曲名到艺术家间距：~0.8vh
    final lineGap = (screenHeight * 0.008).clamp(4.0, 10.0);
    final titleHeight = titleSize * 1.3 * 2;
    final artistHeight = artistSize * 1.4;
    final artistText = [
      widget.artist,
      widget.album,
    ].where((s) => s.isNotEmpty).join(' \u2014 ');
    final displayTitle = widget.title.isNotEmpty ? widget.title : '未知曲目';
    return SizedBox(
      width: widget.infoWidth ?? size,
      height: titleHeight + lineGap + artistHeight,
      child: Column(
        children: [
          SizedBox(
            height: titleHeight,
            child: Align(
              alignment: Alignment.topCenter,
              child: MusicTextOpticalAlignment(
                applyCjkRaise: musicTextContainsCjk(displayTitle),
                fontSize: titleSize,
                child: Text(
                  displayTitle,
                  style: TextStyle(
                    fontFamily: _isChineseText(displayTitle)
                        ? 'Noto Sans SC'
                        : 'Inter',
                    fontSize: titleSize,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                    height: 1.3,
                    letterSpacing: 0.05,
                  ),
                  strutStyle: StrutStyle(
                    fontSize: titleSize,
                    height: 1.3,
                    forceStrutHeight: true,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          SizedBox(height: lineGap),
          SizedBox(
            height: artistHeight,
            child: MusicTextOpticalAlignment(
              applyCjkRaise: musicTextContainsCjk(artistText),
              fontSize: artistSize,
              child: Text(
                artistText,
                style: TextStyle(
                  fontFamily: _isChineseText(artistText)
                      ? 'Noto Sans SC'
                      : 'Inter',
                  fontSize: artistSize,
                  fontWeight: FontWeight.w400,
                  color: Colors.white.withValues(alpha: 0.7),
                  height: 1.4,
                  letterSpacing: 0.03,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
