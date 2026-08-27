import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Apple Music 风格播放控制栏（严格对齐 Apple Music 全屏播放页面截图）
///
/// 布局结构（垂直排列，宽度由父组件约束）：
///   1. 进度条行：当前时间 + Slider + 倒计时剩余时间（-mm:ss）
///   2. 控制按钮行：[音量] [字号]  ...  [◀◀] [▶/⏸] [▶▶]  ...  [更多]
///
/// 所有尺寸基于屏幕短边计算，适配不同分辨率和横竖屏。
///
/// 性能优化：进度条区域用 ValueListenableBuilder 监听 positionListenable，
/// 只有进度条叶子节点每帧重绘，整棵控件树不因进度变化而重建。
class MusicPlaybackControls extends StatefulWidget {
  final Duration totalDuration;
  final bool isPlaying;
  final ValueListenable<Duration>? positionListenable;
  final ValueChanged<double>? onProgressChanged;
  final ValueChanged<double>? onProgressChangeStart;
  final ValueChanged<double>? onProgressChangeEnd;
  final VoidCallback? onPlayPause;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  // 字号调节回调
  final VoidCallback? onFontSizeAdjust;
  // 字号调节按钮的 GlobalKey，用于定位字号调节滑块
  final GlobalKey? fontSizeButtonKey;
  // 当前播放位置（当 positionListenable 未提供时的备用）
  final Duration currentPosition;
  // 进度值 0.0~1.0（当 positionListenable 未提供时的备用）
  final double progress;
  // 音量相关参数
  final double volume;
  final bool isMuted;
  final ValueChanged<double>? onVolumeChanged;
  final VoidCallback? onToggleMute;

  const MusicPlaybackControls({
    super.key,
    required this.totalDuration,
    this.isPlaying = false,
    this.positionListenable,
    this.currentPosition = Duration.zero,
    this.progress = 0.0,
    this.onProgressChanged,
    this.onProgressChangeStart,
    this.onProgressChangeEnd,
    this.onPlayPause,
    this.onPrevious,
    this.onNext,
    this.onFontSizeAdjust,
    this.fontSizeButtonKey,
    this.volume = 1.0,
    this.isMuted = false,
    this.onVolumeChanged,
    this.onToggleMute,
  });

  @override
  State<MusicPlaybackControls> createState() => _MusicPlaybackControlsState();
}

class _MusicPlaybackControlsState extends State<MusicPlaybackControls> {
  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  /// 获取音量图标
  IconData _getVolumeIcon() {
    if (widget.isMuted || widget.volume <= 0) {
      return Icons.volume_off_outlined;
    }
    if (widget.volume < 0.3) {
      return Icons.volume_mute_outlined;
    }
    if (widget.volume < 0.7) {
      return Icons.volume_down_outlined;
    }
    return Icons.volume_up_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    final orientation = MediaQuery.of(context).orientation;

    // 基准尺寸：竖屏时使用高度（较长边），横屏时使用宽度（较长边）
    // 这样可以避免细长手机上按钮过小的问题
    final baseDimension = orientation == Orientation.portrait
        ? screenHeight // 竖屏：使用高度（较长边）
        : screenWidth; // 横屏：使用宽度（较长边）

    // 手机判断：基于最短边（适配横竖屏）
    final shortestSide = MediaQuery.of(context).size.shortestSide;
    final isMobile = shortestSide < 600;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildProgressBar(baseDimension, isMobile),
        SizedBox(height: screenHeight * 0.02), // 进度条到控制按钮间距 ~2vh
        _buildControlButtons(baseDimension, screenHeight, isMobile),
      ],
    );
  }

  /// 进度条行：左侧时间 | 滑块 | 右侧倒计时
  ///
  /// 用 ValueListenableBuilder 监听 positionListenable，只有进度条叶子节点
  /// 每帧重绘，整棵 MusicPlaybackControls 不因进度变化而重建。
  /// 如果没有提供 positionListenable，则直接使用 currentPosition 和 progress。
  Widget _buildProgressBar(double baseDim, bool isMobile) {
    // 时间文字字号：手机 ~3.2% clamp(10,13)；桌面 ~3.8% clamp(11,16)
    final timeFontSize = isMobile
        ? (baseDim * 0.032).clamp(10.0, 13.0)
        : (baseDim * 0.038).clamp(11.0, 16.0);
    // 进度条轨道高度：手机 ~0.5% clamp(3,6)；桌面 ~0.6% clamp(4,8)
    final trackH = isMobile
        ? (baseDim * 0.005).clamp(3.0, 6.0)
        : (baseDim * 0.006).clamp(4.0, 8.0);
    // 滑块拇指半径：轨道高度的 1.5~2 倍
    final thumbR = (trackH * 1.8).clamp(5.0, 14.0);
    final timeColor = Colors.white.withValues(alpha: 0.7);

    // 如果没有提供 positionListenable，直接使用 currentPosition 和 progress
    if (widget.positionListenable == null) {
      return _buildProgressContent(
        widget.currentPosition,
        widget.totalDuration,
        widget.progress,
        baseDim,
        isMobile,
        timeFontSize,
        trackH,
        thumbR,
        timeColor,
      );
    }

    // position 和滑块必须来自同一个逐帧状态源。否则 seek 后父组件尚未重建时，
    // 时间文字已经到了新位置，Slider 却仍会短暂使用旧 progress。
    return ValueListenableBuilder<Duration>(
      valueListenable: widget.positionListenable!,
      builder: (context, position, _) => _buildProgressContent(
        position,
        widget.totalDuration,
        widget.totalDuration.inMilliseconds > 0
            ? position.inMilliseconds / widget.totalDuration.inMilliseconds
            : 0.0,
        baseDim,
        isMobile,
        timeFontSize,
        trackH,
        thumbR,
        timeColor,
      ),
    );
  }

  /// 进度条具体内容（抽取出来，供 ValueListenableBuilder 的 builder 调用）
  ///
  /// 进度值（progress）由父组件传入，确保滑块位置与显示时间同步，
  /// 尤其在拖动进度条时能实时跟随手指位置。
  Widget _buildProgressContent(
    Duration currentPosition,
    Duration totalDuration,
    double progress,
    double baseDim,
    bool isMobile,
    double timeFontSize,
    double trackH,
    double thumbR,
    Color timeColor,
  ) {
    final remaining = totalDuration - currentPosition;
    // 使用父组件传入的 progress，确保滑块位置与显示时间一致
    final effectiveProgress = totalDuration.inMilliseconds > 0
        ? progress.clamp(0.0, 1.0)
        : 0.0;

    return Row(
      children: [
        // 当前时间标签
        SizedBox(
          width: 48,
          child: Text(
            _formatDuration(currentPosition),
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: timeFontSize,
              fontWeight: FontWeight.w500,
              color: timeColor,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(width: 8),
        // 进度滑块
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: trackH,
              thumbShape: RoundSliderThumbShape(enabledThumbRadius: thumbR),
              overlayShape: RoundSliderOverlayShape(
                overlayRadius: thumbR * 2.2,
              ),
              activeTrackColor: Colors.white,
              inactiveTrackColor: Colors.white.withValues(alpha: 0.2),
              thumbColor: Colors.white,
              overlayColor: Colors.white.withValues(alpha: 0.1),
              trackShape: CustomSliderTrackShape(),
            ),
            child: Slider(
              value: effectiveProgress,
              onChanged: widget.onProgressChanged,
              onChangeStart: widget.onProgressChangeStart,
              onChangeEnd: widget.onProgressChangeEnd,
            ),
          ),
        ),
        const SizedBox(width: 8),
        // 剩余时间标签（倒计时格式 -mm:ss）
        SizedBox(
          width: 56,
          child: Text(
            '-${_formatDuration(remaining)}',
            textAlign: TextAlign.end,
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: timeFontSize,
              fontWeight: FontWeight.w500,
              color: timeColor,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }

  /// 控制按钮行 — 统一设计风格，适配手机和桌面
  /// 布局：[音量]  ...  [◀◀] [▶/⏸] [▶▶]  ...  [字号]
  Widget _buildControlButtons(
    double baseDim,
    double screenHeight,
    bool isMobile,
  ) {
    // 主控图标（上一曲/播放/下一曲）：
    // 手机 ~5.5% clamp(16,24)；桌面 ~6.5% clamp(20,34)
    final mainIconSize = isMobile
        ? (baseDim * 0.055).clamp(16.0, 24.0)
        : (baseDim * 0.065).clamp(20.0, 34.0);
    // 次要图标（音量/字号）：
    // 手机 ~3.5% clamp(12,18)；桌面 ~4.2% clamp(14,24)
    final secondaryIconSize = isMobile
        ? (baseDim * 0.035).clamp(12.0, 18.0)
        : (baseDim * 0.042).clamp(14.0, 24.0);
    // 播放按钮直径：主图标 * ~1.9
    final playButtonSize = mainIconSize * 1.9;
    // 统一按钮颜色
    final secondaryColor = Colors.white.withValues(alpha: 0.7);
    // 统一按钮触控区域
    final buttonMinSize = isMobile ? 44.0 : 48.0;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // ===== 左侧组：音量按钮（Expanded 占等宽空间，靠左对齐）=====
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              // 音量按钮（直接切换静音/取消静音，不显示悬浮面板）
              IconButton(
                icon: Icon(
                  _getVolumeIcon(),
                  size: secondaryIconSize,
                  color: secondaryColor,
                ),
                onPressed: widget.onToggleMute,
                tooltip: widget.isMuted ? '取消静音' : '静音',
                iconSize: secondaryIconSize,
                padding: const EdgeInsets.all(8),
                constraints: BoxConstraints(
                  minWidth: buttonMinSize,
                  minHeight: buttonMinSize,
                ),
              ),
            ],
          ),
        ),

        // ===== 中央组：上一曲 / 播放暂停 / 下一曲（不 Expanded，自适应宽度，绝对居中）=====
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 上一曲
            IconButton(
              icon: Icon(Icons.skip_previous_rounded, color: Colors.white),
              onPressed: widget.onPrevious,
              tooltip: '上一曲',
              iconSize: mainIconSize,
              padding: const EdgeInsets.all(8),
              constraints: BoxConstraints(
                minWidth: buttonMinSize,
                minHeight: buttonMinSize,
              ),
            ),
            SizedBox(width: mainIconSize * (isMobile ? 0.2 : 0.3)),
            // 播放/暂停（大圆形白色按钮）
            GestureDetector(
              onTap: widget.onPlayPause,
              child: Container(
                width: playButtonSize,
                height: playButtonSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: playButtonSize * 0.22,
                      offset: Offset(0, playButtonSize * 0.06),
                    ),
                  ],
                ),
                child: Icon(
                  widget.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  size: mainIconSize * 1.05,
                  color: const Color(0xFF1C1C1E),
                ),
              ),
            ),
            SizedBox(width: mainIconSize * (isMobile ? 0.2 : 0.3)),
            // 下一曲
            IconButton(
              icon: Icon(Icons.skip_next_rounded, color: Colors.white),
              onPressed: widget.onNext,
              tooltip: '下一曲',
              iconSize: mainIconSize,
              padding: const EdgeInsets.all(8),
              constraints: BoxConstraints(
                minWidth: buttonMinSize,
                minHeight: buttonMinSize,
              ),
            ),
          ],
        ),

        // ===== 右侧组：字号调节按钮（Expanded 占等宽空间，靠右对齐）=====
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              // 字号调节按钮（统一使用 IconButton 风格）
              IconButton(
                key: widget.fontSizeButtonKey, // 用于定位字号调节滑块
                icon: Icon(
                  Icons.format_size,
                  size: secondaryIconSize,
                  color: secondaryColor,
                ),
                onPressed: widget.onFontSizeAdjust,
                tooltip: '调节字号',
                iconSize: secondaryIconSize,
                padding: const EdgeInsets.all(8),
                constraints: BoxConstraints(
                  minWidth: buttonMinSize,
                  minHeight: buttonMinSize,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 自定义圆角轨道形状
class CustomSliderTrackShape extends RoundedRectSliderTrackShape {
  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final trackHeight = sliderTheme.trackHeight ?? 4;
    final thumbSize =
        sliderTheme.thumbShape?.getPreferredSize(isEnabled, isDiscrete) ??
        const Size(20, 20);
    final thumbRadius = thumbSize.width / 2;
    final trackLeft = offset.dx + thumbRadius;
    final trackTop = offset.dy + (parentBox.size.height - trackHeight) / 2;
    final trackWidth = parentBox.size.width - 2 * thumbRadius;
    return Rect.fromLTWH(trackLeft, trackTop, trackWidth, trackHeight);
  }
}
