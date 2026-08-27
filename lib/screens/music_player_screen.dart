import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/subtitle_model.dart';
import '../services/media_playback_service.dart';
import '../services/settings_service.dart';
import '../utils/desktop_player_shortcuts.dart';
import '../models/video_item.dart';
import '../widgets/cached_thumbnail_widget.dart';
import '../widgets/music_album_cover.dart';
import '../widgets/music_lyric_view.dart';
import '../widgets/music_playback_controls.dart';

/// Apple Music 风格全屏音乐播放页面（响应式布局）
///
/// 页面布局（严格对标 Apple Music 指导文档）：
/// - Block 1: 全屏背景层（封面高斯模糊 + 半透明黑色遮罩）
/// - Block 2: 右上角窗口控制按钮（最小化 / 关闭）— 仅桌面端
/// - 窄屏竖向布局（< 768px）：
///   - Header: 缩略图 + 歌曲标题/歌手
///   - 中间: 全高同步歌词（与横屏共用 MusicLyricView）
///   - 底部: 进度条 + 控制按钮
/// - 宽屏左右布局（>= 768px）：
///   - 左侧面板: CD 封面 + 歌曲信息 + 进度条 + 控制按钮
///   - 右侧面板: 同步歌词（双语：原文大字+翻译小字）
///
/// 所有尺寸基于 vh/vw 相对单位，适配不同屏幕分辨率。
/// 字体规范：
/// - 英文原文：Inter 字体，ExtraBold (800)，纯白高亮
/// - 中文翻译：Noto Sans SC 字体，Bold (700)，半透明辅助
class MusicPlayerScreen extends StatefulWidget {
  final String? coverImagePath;
  final String title;
  final String artist;
  final String album;
  final Duration totalDuration;
  final ValueChanged<Duration>? onSeek;
  final VoidCallback? onPlayPause;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  const MusicPlayerScreen({
    super.key,
    this.coverImagePath,
    this.title = '',
    this.artist = '',
    this.album = '',
    this.totalDuration = Duration.zero,
    this.onSeek,
    this.onPlayPause,
    this.onPrevious,
    this.onNext,
  });

  @override
  State<MusicPlayerScreen> createState() => _MusicPlayerScreenState();
}

class _MusicPlayerScreenState extends State<MusicPlayerScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  double _dragProgress = 0.0;
  bool _isDragging = false;
  // 用于跟踪 seek 目标位置，避免在 seek 完成前进度条闪烁回旧位置
  double? _seekTargetProgress;
  final FocusNode _focusNode = FocusNode();
  late final MediaPlaybackService _positionMediaService;

  /// 显示位置通知器 — 驱动进度条每帧平滑更新
  /// 正常播放时跟随 service.positionNotifier，拖动时切到拖动位置
  final ValueNotifier<Duration> _displayPosition = ValueNotifier<Duration>(
    Duration.zero,
  );

  /// 集切换过渡动画时长（优雅的淡入淡出效果）
  static const Duration _episodeTransitionDuration = Duration(
    milliseconds: 400,
  );

  /// 竖屏模式下底部播放控件的可见性（Apple Music 手机端交互）
  ///
  /// 交互逻辑：
  /// - 初始显示（true）
  /// - 用户**向下滚**歌词 → 延迟隐藏（false），歌词占满全屏
  /// - 用户**向上滚**歌词 → 立即显示（true）
  /// - 自动跟随恢复 → 显示（true）
  bool _verticalControlsVisible = true;

  /// 隐藏/显示控件的动画时长
  static const Duration _controlsAnimDuration = Duration(milliseconds: 300);

  /// 底部控件显隐动画控制器（实现从下往上出现、从上往下消失）
  late AnimationController _controlsAnimationController;
  late Animation<Offset> _controlsSlideAnimation;

  /// 向下滚动后延迟隐藏的等待时间（避免误触）
  Timer? _hideControlsTimer;

  /// 播放一段时间后自动隐藏控件的定时器（Apple Music 核心逻辑）
  /// 控件显示后，若用户在 _autoHideDelay 时间内没有交互，则自动隐藏
  Timer? _autoHideControlsTimer;

  /// 控件显示后，用户无操作自动隐藏的延时（Apple Music 风格：5秒）
  static const Duration _autoHideDelay = Duration(seconds: 5);

  /// 歌词字号缩放比例（0.6 = 小，1.0 = 默认中等偏大，1.4 = 大）
  /// 竖屏（窄屏）与横屏（宽屏）分别记忆、互不影响。
  double _lyricFontSizeScalePortrait = 1.0;
  double _lyricFontSizeScaleLandscape = 1.0;

  /// 是否显示字号调节滑块
  bool _showFontSizeSlider = false;
  // 字号调节按钮的 GlobalKey，用于定位字号调节滑块
  final GlobalKey _fontSizeButtonKey = GlobalKey();

  MediaPlaybackService get _mediaService =>
      Provider.of<MediaPlaybackService>(context, listen: false);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addEarlyKeyEventHandler(_handleEarlyKeyEvent);

    // 同步读取上次保存的歌词字号（竖屏 / 横屏分别记忆）。
    // 在首帧之前同步读取，可避免进入页面时先显示默认字号再跳变（闪烁）。
    final settings = Provider.of<SettingsService>(context, listen: false);
    _lyricFontSizeScalePortrait = settings.musicLyricFontSizeScalePortrait;
    _lyricFontSizeScaleLandscape = settings.musicLyricFontSizeScaleLandscape;

    // 初始化底部控件显隐动画控制器
    _controlsAnimationController = AnimationController(
      duration: _controlsAnimDuration,
      vsync: this,
    );
    _controlsSlideAnimation =
        Tween<Offset>(
          begin: const Offset(0, 1), // 隐藏位置（向下偏移一个控件高度）
          end: Offset.zero, // 显示位置
        ).animate(
          CurvedAnimation(
            parent: _controlsAnimationController,
            curve: Curves.easeInOutCubic,
          ),
        );
    // 初始状态为显示
    _controlsAnimationController.value = 1.0;

    // 监听 service.positionNotifier，平滑更新 _displayPosition
    _positionMediaService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    _positionMediaService.positionNotifier.addListener(_onPositionNotified);
    _displayPosition.value = _positionMediaService.position;

    // 请求焦点以接收键盘事件
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreKeyboardFocus();
    });

    // 在移动端启用全屏模式，隐藏状态栏和导航栏
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }

    // 启动自动隐藏控件定时器（Apple Music 逻辑：几秒无操作后控件自动隐藏）
    _startAutoHideTimer();
  }

  /// 当 service.positionNotifier 变化时，更新 _displayPosition
  /// - 拖动时（_isDragging）不更新
  /// - seek 过程中（_seekTargetProgress != null）暂时不更新，避免闪烁
  void _onPositionNotified() {
    if (!mounted || _isDragging) return;

    final service = Provider.of<MediaPlaybackService>(context, listen: false);

    // 如果正在 seek，检查是否已经到达目标位置
    if (_seekTargetProgress != null) {
      final duration = service.duration;
      if (duration.inMilliseconds > 0) {
        final targetMs = (_seekTargetProgress! * duration.inMilliseconds)
            .round();
        final currentMs = service.position.inMilliseconds;
        final diff = (targetMs - currentMs).abs();

        // 如果当前位置已经接近目标位置（误差 < 500ms），认为 seek 完成
        if (diff < 500) {
          setState(() => _seekTargetProgress = null);
        } else {
          // seek 还没完成，不要更新 _displayPosition，避免闪烁
          return;
        }
      } else {
        // 如果 duration 为 0，无法计算，直接清除 _seekTargetProgress
        setState(() => _seekTargetProgress = null);
      }
    }

    if (_displayPosition.value != service.positionNotifier.value) {
      _displayPosition.value = service.positionNotifier.value;
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_handleEarlyKeyEvent);
    WidgetsBinding.instance.removeObserver(this);
    _hideControlsTimer?.cancel();
    _autoHideControlsTimer?.cancel();
    _controlsAnimationController.dispose();
    _focusNode.dispose();
    _positionMediaService.positionNotifier.removeListener(_onPositionNotified);
    _displayPosition.dispose();

    // 恢复系统UI显示（仅移动端）
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _scheduleKeyboardFocusRestore();
    }
  }

  bool _isTextInputFocused() {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext == null) return false;
    return focusContext.widget is EditableText ||
        focusContext.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _restoreKeyboardFocus() {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    if (!_isTextInputFocused() && _focusNode.canRequestFocus) {
      _focusNode.requestFocus();
    }
  }

  void _scheduleKeyboardFocusRestore() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreKeyboardFocus();
    });
  }

  KeyEventResult _handleEarlyKeyEvent(KeyEvent event) {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) {
      return KeyEventResult.ignored;
    }
    return _handleKeyEvent(_focusNode, event);
  }

  Future<void> _toggleFullScreen(SettingsService settings) async {
    try {
      await settings.toggleFullScreen();
    } finally {
      // Desktop full-screen transitions can replace Flutter's primary focus.
      // Restore it after the native window operation has completed.
      _scheduleKeyboardFocusRestore();
    }
  }

  /// 统一设置竖屏底部控件的可见性，并触发相应动画
  ///
  /// - visible = true: 立即显示控件 + 从下往上进入动画
  /// - visible = false: 延迟隐藏控件 + 从上往下退出动画
  void _setControlsVisible(bool visible) {
    if (!mounted || _verticalControlsVisible == visible) return;
    setState(() => _verticalControlsVisible = visible);
    if (visible) {
      _controlsAnimationController.forward();
    } else {
      _controlsAnimationController.reverse();
    }
  }

  void _handleExit() {
    Navigator.of(context).pop();
  }

  /// 处理键盘快捷键事件
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    final hasBlockingModifier =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final isSupportedKey =
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.keyF ||
        key == LogicalKeyboardKey.keyM;

    if (!isSupportedKey) return KeyEventResult.ignored;
    if (_isTextInputFocused() || hasBlockingModifier) {
      return KeyEventResult.ignored;
    }

    // Match the video player: one action per physical press, with OS key
    // repeats and the matching key-up consumed instead of leaking downstream.
    if (event is KeyRepeatEvent || event is KeyUpEvent) {
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.handled;

    final mediaService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    final settings = Provider.of<SettingsService>(context, listen: false);

    // 空格键：播放/暂停
    if (key == LogicalKeyboardKey.space) {
      if (widget.onPlayPause != null) {
        widget.onPlayPause!.call();
      } else if (mediaService.isPlaying) {
        unawaited(mediaService.pause());
      } else {
        unawaited(mediaService.resume());
      }
      return KeyEventResult.handled;
    }

    // ESC键：退出
    if (key == LogicalKeyboardKey.escape) {
      _handleExit();
      return KeyEventResult.handled;
    }

    // 左箭头：后退几秒
    if (key == LogicalKeyboardKey.arrowLeft) {
      final seekSeconds = settings.doubleTapSeekSeconds;
      final newPosition =
          mediaService.position - Duration(seconds: seekSeconds);
      _handleSeekTo(newPosition.isNegative ? Duration.zero : newPosition);
      return KeyEventResult.handled;
    }

    // 右箭头：前进几秒
    if (key == LogicalKeyboardKey.arrowRight) {
      final seekSeconds = settings.doubleTapSeekSeconds;
      final newPosition =
          mediaService.position + Duration(seconds: seekSeconds);
      final maxPosition = mediaService.duration;
      _handleSeekTo(newPosition > maxPosition ? maxPosition : newPosition);
      return KeyEventResult.handled;
    }

    // 上箭头：增加音量
    if (key == LogicalKeyboardKey.arrowUp) {
      final newVolume = (mediaService.volume + 0.1).clamp(0.0, 1.0);
      unawaited(mediaService.setVolume(newVolume));
      return KeyEventResult.handled;
    }

    // 下箭头：减少音量
    if (key == LogicalKeyboardKey.arrowDown) {
      final newVolume = (mediaService.volume - 0.1).clamp(0.0, 1.0);
      unawaited(mediaService.setVolume(newVolume));
      return KeyEventResult.handled;
    }

    // F键：进入/退出全屏。复用桌面播放器的统一快捷键配置，
    // 避免界面提示与实际按键处理再次出现不一致。
    if (DesktopPlayerShortcuts.matchAction(key) ==
        DesktopPlayerShortcutAction.toggleFullScreen) {
      unawaited(_toggleFullScreen(settings));
      return KeyEventResult.handled;
    }

    // M键：静音/取消静音
    if (key == LogicalKeyboardKey.keyM) {
      unawaited(mediaService.toggleMute());
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  /// 处理歌词视图的滚动方向变化（Apple Music 手机端控件显隐逻辑）
  ///
  /// 方向定义（与 music_lyric_view.dart 一致）：
  /// - direction > 0: 用户向上滑歌词（内容向下移/往前翻）→ 立即显示底部播放控件
  /// - direction < 0: 用户向下滑歌词（内容向上移/往后翻）→ 延迟隐藏底部播放控件
  /// - null: 恢复自动跟随模式 → 不影响控件显示/隐藏状态（保持当前状态）
  void _handleLyricScrollDirection(double? direction) {
    if (direction == null) {
      // 恢复自动跟随模式 → 不影响控件显示/隐藏状态
      // 如果控件是显示的，重置自动隐藏定时器
      // 如果控件是隐藏的，保持隐藏状态
      _hideControlsTimer?.cancel();
      if (_verticalControlsVisible) {
        _startAutoHideTimer();
      }
      return;
    }

    // direction > 0: 用户向上滑歌词（往前翻）→ 立即显示控件
    // direction < 0: 用户向下滑歌词（往后翻）→ 延迟隐藏控件
    if (direction < 0) {
      // 用户向下滑歌词（往后翻/查看后续）→ 延迟隐藏控件（50ms 足够避免误触，同时提升响应速度）
      if (_verticalControlsVisible) {
        _hideControlsTimer?.cancel();
        _hideControlsTimer = Timer(const Duration(milliseconds: 50), () {
          if (mounted) {
            _setControlsVisible(false);
            // 控件隐藏后取消自动隐藏定时器
            _cancelAutoHideTimer();
          }
        });
      }
    } else {
      // 用户向上滑歌词（往前翻/回到当前行）→ 立即显示控件 + 取消待执行的隐藏 + 重置自动隐藏定时器
      _hideControlsTimer?.cancel();
      _setControlsVisible(true);
      _startAutoHideTimer();
    }
  }

  /// 启动自动隐藏控件定时器（Apple Music 核心逻辑）
  ///
  /// 控件显示后，若用户在 _autoHideDelay 时间内没有交互，则自动隐藏。
  /// 每次用户交互（点击、滚动等）时都应调用此方法重置定时器。
  void _startAutoHideTimer() {
    _cancelAutoHideTimer();
    if (_verticalControlsVisible && mounted) {
      _autoHideControlsTimer = Timer(_autoHideDelay, () {
        _setControlsVisible(false);
        _hideControlsTimer?.cancel();
      });
    }
  }

  /// 取消自动隐藏控件定时器
  void _cancelAutoHideTimer() {
    _autoHideControlsTimer?.cancel();
    _autoHideControlsTimer = null;
  }

  /// 用户与屏幕交互时调用：显示控件并重置自动隐藏定时器
  void _onUserInteraction() {
    _setControlsVisible(true);
    _startAutoHideTimer();
  }

  void _handleSeekTo(Duration position) {
    final onSeek = widget.onSeek;
    if (onSeek != null) {
      onSeek(position);
    } else {
      _mediaService.seekTo(position);
    }
  }

  void _handleProgressChange(double value) {
    setState(() => _dragProgress = value);
    // 拖动时立即更新 _displayPosition，让进度条跟随手指
    if (_isDragging) {
      final totalMs = _mediaService.duration.inMilliseconds;
      if (totalMs > 0) {
        _displayPosition.value = Duration(
          milliseconds: (value * totalMs).round(),
        );
      }
    }
  }

  void _handleProgressChangeStart(double value) {
    // 用户开始拖拽进度条 → 显示控件并重置自动隐藏定时器
    _onUserInteraction();
    setState(() {
      _isDragging = true;
      _dragProgress = value;
    });
    _displayPosition.value = Duration(
      milliseconds: (value * _mediaService.duration.inMilliseconds).round(),
    );
  }

  void _handleProgressChangeEnd(double value) {
    // 用户结束拖拽进度条 → 重置自动隐藏定时器
    _onUserInteraction();
    setState(() {
      _isDragging = false;
      _seekTargetProgress = value; // 记录 seek 目标位置
    });
    final seekPos = Duration(
      milliseconds: (value * _mediaService.duration.inMilliseconds).round(),
    );
    // 立即更新显示位置到目标位置，避免闪烁
    _displayPosition.value = seekPos;
    _handleSeekTo(seekPos);
  }

  double _getEffectiveProgress() {
    if (_isDragging) return _dragProgress;
    final duration = _mediaService.duration;
    if (duration.inMilliseconds == 0) return 0.0;
    return (_mediaService.position.inMilliseconds / duration.inMilliseconds)
        .clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    // 响应式读取"识别第一行为主字幕"设置，变化时自动重建
    final splitSubtitleByLine = context.select<SettingsService, bool>(
      (s) => s.splitSubtitleByLine,
    );
    // 性能优化：用 Selector 精准订阅低频字段，避免每 300ms position notify 触发全屏重建。
    // 快照不含 position（position 由 positionNotifier 逐帧驱动，无需 build 刷新），
    // 故 300ms 定时器的 notifyListeners 不会触发 builder；仅字幕/时长/播放态/音量等
    // 真正变化时才重建子树。mediaService 引用以 listen:false 获取（用于回调与实时读取）。
    return Selector<MediaPlaybackService, _PlayerSnapshot>(
      selector: (context, s) => _PlayerSnapshot(
        itemId: s.currentItem?.id ?? 'null',
        cover: s.currentItem?.thumbnailPath,
        title: s.currentItem?.title ?? widget.title,
        duration: s.duration,
        subtitles: s.subtitles,
        secondarySubtitles: s.secondarySubtitles,
        isPlaying: s.isPlaying,
        volume: s.volume,
        isMuted: s.isMuted,
      ),
      builder: (context, snapshot, child) {
        final mediaService = Provider.of<MediaPlaybackService>(
          context,
          listen: false,
        );

        // 使用实时数据（来自快照，builder 仅在低频字段变化时执行，故数据新鲜）
        final effectiveCover = snapshot.cover;
        final effectiveTitle = snapshot.title;
        // VideoItem 没有 artist 字段，使用 widget.artist（如果有传入）或留空
        final effectiveArtist = widget.artist;
        final effectiveTotalDuration = snapshot.duration;
        final effectiveSubtitles = snapshot.subtitles;
        final effectiveSecondarySubtitles = snapshot.secondarySubtitles;

        // 使用当前播放项 ID 作为 Key，当集切换时 AnimatedSwitcher 自动触发淡入淡出动画
        // 注意：不包含 isPlaying 状态，避免播放/暂停、进度条跳转时误触发切换动画
        final contentKey = ValueKey<String>(snapshot.itemId);

        return Scaffold(
          backgroundColor: Colors.black,
          body: Focus(
            focusNode: _focusNode,
            autofocus: true,
            onKeyEvent: _handleKeyEvent,
            child: Stack(
              children: [
                // Block 1: 背景层（封面高斯模糊 + 半透明黑色遮罩）
                _buildBackgroundLayer(effectiveCover),

                // 主内容区（带集切换淡入淡出过渡动画）
                AnimatedSwitcher(
                  duration: _episodeTransitionDuration,
                  transitionBuilder: (child, animation) {
                    // 创建优雅的淡入淡出 + 轻微缩放动画
                    final curvedAnimation = CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeInOutCubic,
                    );

                    return FadeTransition(
                      opacity: curvedAnimation,
                      child: ScaleTransition(
                        scale: Tween<double>(
                          begin: 0.95,
                          end: 1.0,
                        ).animate(curvedAnimation),
                        child: child,
                      ),
                    );
                  },
                  child: KeyedSubtree(
                    key: contentKey,
                    child: SafeArea(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // 中间内容：占满整个 SafeArea 高度。
                          // 窗口控制按钮已移至 Stack 顶层作为浮层，不再占用布局高度，
                          // 避免挤压字幕/内容区域导致视觉重心偏下。
                          LayoutBuilder(
                            builder: (context, constraints) {
                              // 响应式断点：768px 以下改为上下布局
                              final isNarrow = constraints.maxWidth < 768;
                              if (isNarrow) {
                                return _buildVerticalLayout(
                                  mediaService,
                                  effectiveTitle,
                                  effectiveArtist,
                                  effectiveSubtitles,
                                  effectiveSecondarySubtitles,
                                  splitSubtitleByLine,
                                );
                              } else {
                                return _buildHorizontalLayout(
                                  mediaService,
                                  effectiveTotalDuration,
                                  effectiveTitle,
                                  effectiveArtist,
                                  effectiveSubtitles,
                                  effectiveSecondarySubtitles,
                                  splitSubtitleByLine,
                                );
                              }
                            },
                          ),
                          // Block 2: 右上角窗口控制按钮（浮层，仅宽屏显示）
                          _buildWindowControls(),
                        ],
                      ),
                    ),
                  ),
                ),

                // 字号调节滑块（出现在字号调节按钮附近）
                if (_showFontSizeSlider) _buildFontSizeSliderPositioned(),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 当前是否为竖屏（窄屏）布局：与 build 中 LayoutBuilder 的断点保持一致（<768px）
  bool get _isPortraitLayout => MediaQuery.of(context).size.width < 768;

  /// 当前布局下应使用的歌词字号缩放比例（竖屏 / 横屏分别记忆）
  double get _currentLyricFontSizeScale => _isPortraitLayout
      ? _lyricFontSizeScalePortrait
      : _lyricFontSizeScaleLandscape;

  /// 调节歌词字号并持久化（竖屏 / 横屏分别记忆，互不干扰）
  void _onFontSizeChanged(double value) {
    final settings = Provider.of<SettingsService>(context, listen: false);
    if (_isPortraitLayout) {
      _lyricFontSizeScalePortrait = value;
      settings.updateMusicLyricFontSizeScalePortrait(value);
    } else {
      _lyricFontSizeScaleLandscape = value;
      settings.updateMusicLyricFontSizeScaleLandscape(value);
    }
    setState(() {});
  }

  /// 构建竖/横屏共用的字号调节滑块（滑块显示的值跟随当前布局对应的字号）
  Widget _buildFontSizeSlider() {
    return Container(
      width: 44,
      height: 180,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
      child: RotatedBox(
        quarterTurns: -1,
        child: Slider(
          value: _currentLyricFontSizeScale,
          min: 0.6,
          max: 1.4,
          divisions: 8,
          onChanged: (value) =>
              _onFontSizeChanged(double.parse(value.toStringAsFixed(2))),
          activeColor: Colors.white,
          inactiveColor: Colors.white.withValues(alpha: 0.25),
          thumbColor: Colors.white,
        ),
      ),
    );
  }

  /// 构建字号调节滑块的定位组件（动态计算位置，使其出现在按钮附近）
  Widget _buildFontSizeSliderPositioned() {
    // 尝试获取字号调节按钮的位置
    final buttonContext = _fontSizeButtonKey.currentContext;
    if (buttonContext != null) {
      final renderBox = buttonContext.findRenderObject() as RenderBox?;
      if (renderBox != null) {
        // 获取按钮在屏幕中的位置
        final buttonPosition = renderBox.localToGlobal(Offset.zero);
        final buttonSize = renderBox.size;
        final screenSize = MediaQuery.of(context).size;

        // 滑块尺寸
        final sliderWidth = 44.0;
        final sliderHeight = 180.0;

        // 计算滑块位置（在按钮左侧，垂直居中）
        var left = buttonPosition.dx - sliderWidth - 8; // 按钮左侧 8px
        var top = buttonPosition.dy + (buttonSize.height - sliderHeight) / 2;

        // 如果左侧空间不足，则显示在按钮上方
        if (left < 0) {
          left = buttonPosition.dx + (buttonSize.width - sliderWidth) / 2;
          top = buttonPosition.dy - sliderHeight - 8;
        }

        // 确保滑块不会超出屏幕边界
        left = left.clamp(8.0, screenSize.width - sliderWidth - 8);
        top = top.clamp(8.0, screenSize.height - sliderHeight - 8);

        return Positioned(left: left, top: top, child: _buildFontSizeSlider());
      }
    }

    // 如果无法获取按钮位置，使用默认位置（底部右侧）
    return Positioned(right: 16, bottom: 100, child: _buildFontSizeSlider());
  }

  /// 构建背景层（优化性能：使用缓存的模糊效果）
  Widget _buildBackgroundLayer(String? coverPath) {
    return Positioned.fill(
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 放大的封面图作为背景底纹
            if (coverPath != null && coverPath.isNotEmpty)
              Image.network(
                coverPath,
                width: double.infinity,
                height: double.infinity,
                fit: BoxFit.cover,
                // 移除 scale 参数，它会影响图片质量
                errorBuilder: (context, error, stackTrace) => Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        const Color(0xFF3A3A3C),
                        const Color(0xFF1C1C1E),
                      ],
                    ),
                  ),
                ),
                loadingBuilder: (context, child, loadingProgress) {
                  if (loadingProgress == null) return child;
                  return Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          const Color(0xFF3A3A3C),
                          const Color(0xFF1C1C1E),
                        ],
                      ),
                    ),
                  );
                },
              )
            else
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [const Color(0xFF3A3A3C), const Color(0xFF1C1C1E)],
                  ),
                ),
              ),

            // 优化：降低模糊强度以提高性能（从50降到30）
            // 使用 ImageFilter.blur 的优化版本
            BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
              child: Container(color: Colors.black.withValues(alpha: 0.35)),
            ),
          ],
        ),
      ),
    );
  }

  /// 右上角窗口控制按钮（全屏 / 关闭）— 仅桌面端宽屏时显示
  ///
  /// 以浮层（Positioned）方式悬浮在内容之上，不占用布局高度。
  /// 这样内容区域（CD 封面 + 歌词）可占满整个 SafeArea 高度，
  /// 避免按钮挤压字幕区域导致视觉重心偏下。
  Widget _buildWindowControls() {
    // 仅在宽屏模式（>=768px）显示窗口控制按钮
    // 竖屏手机端由 Header 区域自带关闭按钮
    final isNarrow = MediaQuery.of(context).size.width < 768;
    if (isNarrow) {
      return const SizedBox.shrink();
    }
    return Positioned(
      top: 4,
      right: 8,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 全屏按钮（仅桌面端）
          if (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
            Consumer<SettingsService>(
              builder: (context, settings, child) {
                final isFullScreen = settings.isFullScreen;
                return IconButton(
                  icon: Icon(
                    isFullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
                    size: 18,
                    color: Colors.white.withValues(alpha: 0.55),
                  ),
                  onPressed: () => unawaited(_toggleFullScreen(settings)),
                  iconSize: 18,
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  tooltip: DesktopPlayerShortcuts.buildTooltip(
                    isFullScreen ? '退出全屏' : '全屏',
                    DesktopPlayerShortcutAction.toggleFullScreen,
                  ),
                );
              },
            ),
          IconButton(
            icon: Icon(
              Icons.close,
              size: 18,
              color: Colors.white.withValues(alpha: 0.55),
            ),
            onPressed: _handleExit,
            iconSize: 18,
            padding: const EdgeInsets.all(6),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            tooltip: '关闭',
          ),
        ],
      ),
    );
  }

  /// 宽屏左右布局（>= 768px）
  ///
  /// 桌面端：左侧面板 50% —— 大 CD 封面 + 歌曲信息 + 控制栏（垂直居中）
  /// 手机横屏：左侧面板 45% —— 紧凑封面 + 铺满面板的控制栏 + 更宽的歌词面板
  /// 右侧面板：同步歌词（当前行锚定在 30% 屏幕高度处）
  ///
  /// 响应式适配：使用 LayoutBuilder 获取实际可用高度，
  /// 确保 CD + 信息 + 控制栏的总高度不超过可用空间。
  /// 在横屏手机（高度小）上自动缩小 CD 尺寸，让控制栏横向铺满，
  /// 消除黑边/空旷感，并让视觉重心回到屏幕中心。
  Widget _buildHorizontalLayout(
    MediaPlaybackService mediaService,
    Duration effectiveTotalDuration,
    String effectiveTitle,
    String effectiveArtist,
    List<SubtitleItem> effectiveSubtitles,
    List<SubtitleItem> effectiveSecondarySubtitles,
    bool splitSubtitleByLine,
  ) {
    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;

    final effectiveCover = mediaService.currentItem?.thumbnailPath;

    return LayoutBuilder(
      builder: (context, constraints) {
        // constraints.maxHeight = 整个 SafeArea 高度（窗口控制按钮已改为浮层，不占布局高度）
        final availableHeight = constraints.maxHeight;
        final availableWidth = constraints.maxWidth;

        // === 检测手机横屏：宽但矮，需要更紧凑、更横向铺满的左侧面板 ===
        final isMobileLandscape =
            availableWidth >= 600 && availableHeight < 450;

        // 左右面板比例：手机横屏让歌词区稍宽，桌面端保持 50:50
        final leftFlex = isMobileLandscape ? 45 : 50;
        final rightFlex = isMobileLandscape ? 55 : 50;

        // 左侧面板内边距：手机横屏给内容留呼吸边距，消除贴边/黑边感
        final leftPanelPadding = isMobileLandscape
            ? (availableWidth * 0.03).clamp(12.0, 24.0)
            : 0.0;

        // 左侧面板可用内部宽度
        final leftPanelWidth =
            availableWidth * leftFlex / (leftFlex + rightFlex);
        final leftPanelInnerWidth = leftPanelWidth - leftPanelPadding * 2;

        // === CD 尺寸计算（关键：基于可用高度，确保不溢出）===
        // 手机横屏封面更小，给歌曲信息和控制栏留出更多纵向空间
        final maxByHeight = availableHeight * (isMobileLandscape ? 0.35 : 0.42);
        final maxByWidth = isMobileLandscape
            ? leftPanelInnerWidth * 0.85
            : (availableWidth * 0.5) - 24;
        final cdSize = (screenHeight * 0.48)
            .clamp(120.0, 380.0)
            .clamp(0.0, maxByHeight)
            .clamp(0.0, maxByWidth);

        // 控制栏宽度：手机横屏铺满左侧面板；桌面端稍宽于封面但不超过面板
        final controlsWidth = isMobileLandscape
            ? leftPanelInnerWidth
            : (cdSize * 1.2).clamp(0.0, leftPanelInnerWidth);

        // 歌曲信息宽度：手机横屏与面板基本同宽，避免文字拥挤在封面下方
        final infoWidth = isMobileLandscape
            ? leftPanelInnerWidth * 0.95
            : cdSize;

        // 歌曲信息到进度条间距
        final infoToControlsGap = (screenHeight * 0.025).clamp(6.0, 24.0);

        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // === 左侧面板：CD 封面 + 歌曲信息 + 进度条 + 控制按钮 ===
            Expanded(
              flex: leftFlex,
              child: Center(
                child: SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: leftPanelPadding),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        MusicAlbumCover(
                          coverImagePath: effectiveCover,
                          videoId: mediaService.currentItem?.id,
                          title: effectiveTitle,
                          artist: effectiveArtist,
                          album: widget.album,
                          onExitTrigger: _handleExit,
                          isAudio:
                              mediaService.currentItem?.type == MediaType.audio,
                          coverSize: cdSize,
                          infoWidth: infoWidth,
                        ),
                        SizedBox(height: infoToControlsGap),
                        SizedBox(
                          width: controlsWidth,
                          child: MusicPlaybackControls(
                            positionListenable: _displayPosition,
                            progress: _getEffectiveProgress(),
                            totalDuration: effectiveTotalDuration,
                            isPlaying: mediaService.isPlaying,
                            onProgressChanged: _handleProgressChange,
                            onProgressChangeStart: _handleProgressChangeStart,
                            onProgressChangeEnd: _handleProgressChangeEnd,
                            onPlayPause:
                                widget.onPlayPause ??
                                () {
                                  if (mediaService.isPlaying) {
                                    mediaService.pause();
                                  } else {
                                    mediaService.resume();
                                  }
                                },
                            onPrevious: widget.onPrevious,
                            onNext: widget.onNext,
                            onFontSizeAdjust: () {
                              setState(() {
                                _showFontSizeSlider = !_showFontSizeSlider;
                              });
                            },
                            fontSizeButtonKey: _fontSizeButtonKey,
                            volume: mediaService.volume,
                            isMuted: mediaService.isMuted,
                            onVolumeChanged: (v) => mediaService.setVolume(v),
                            onToggleMute: () => mediaService.toggleMute(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // === 右侧面板（歌词）：手机横屏稍宽，让歌词更舒展 ===
            Expanded(
              flex: rightFlex,
              child: Padding(
                padding: EdgeInsets.only(
                  left: screenWidth * 0.03,
                  right: screenWidth * 0.02,
                ),
                child: MusicLyricView(
                  subtitles: effectiveSubtitles,
                  secondarySubtitles: effectiveSecondarySubtitles,
                  onSeek: _handleSeekTo,
                  positionListenable: mediaService.positionNotifier,
                  lyricFontSizeScale: _lyricFontSizeScaleLandscape,
                  splitSubtitleByLine: splitSubtitleByLine,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 窄屏竖向布局（< 768px）— Apple Music 手机端风格
  ///
  /// 布局结构（参考竖屏设计文档 .codebuddy/竖屏.md）：
  /// - Header（~11vh）: 专辑缩略图 + 歌曲标题/歌手（紧凑横向排列）+ 关闭按钮
  /// - 中间区域：全高同步歌词 — 与横屏共用同一个 MusicLyricView 组件
  /// - 底部（SafeArea）: 进度条 + 播放控制按钮
  ///
  /// 字体统一使用 Noto Sans SC（中文）/ Inter（英文），符合设计文档要求
  Widget _buildVerticalLayout(
    MediaPlaybackService mediaService,
    String effectiveTitle,
    String effectiveArtist,
    List<SubtitleItem> effectiveSubtitles,
    List<SubtitleItem> effectiveSecondarySubtitles,
    bool splitSubtitleByLine,
  ) {
    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;

    final effectiveCover = mediaService.currentItem?.thumbnailPath;
    final effectiveTotalDuration = mediaService.duration;

    // 竖屏 Header 高度：约 10vh~12vh
    final headerHeight = (screenHeight * 0.11).clamp(70.0, 110.0);
    // 缩略图尺寸：约 14vw 或 6vh
    final thumbSize = (screenWidth * 0.14).clamp(36.0, 56.0);

    // 竖屏标题字号：相对封面较小，整体在封面高度内垂直居中（仅针对标题，不含歌手名）
    const double titleLineHeight = 1.2;
    final double titleFontSize = thumbSize * 0.30;

    // 封面解码分辨率需乘设备像素比，否则在 Retina/高分屏上会被放大而模糊
    final int coverCacheSize =
        (thumbSize * MediaQuery.of(context).devicePixelRatio).toInt();

    // 外层 GestureDetector：点击屏幕任何地方都显示控件并重置自动隐藏定时器
    // （Apple Music 风格：控件隐藏后，点击屏幕任意位置可唤出）
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _onUserInteraction,
      child: Stack(
        children: [
          // 主内容：Header + 全高歌词（歌词延伸至屏幕底端，不再为底部控件预留空间）
          Column(
            children: [
              // ========== Header 区域：缩略图 + 歌曲信息 + 关闭按钮 ==========
              SizedBox(
                height: headerHeight,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: screenWidth * 0.05,
                    vertical: screenHeight * 0.015,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // 专辑缩略图（使用 CachedThumbnailWidget 支持缓存，仅显示封面不渲染标题）
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          width: thumbSize,
                          height: thumbSize,
                          child:
                              effectiveCover != null &&
                                  effectiveCover.isNotEmpty
                              ? CachedThumbnailWidget(
                                  videoId: mediaService.currentItem?.id ?? '',
                                  thumbnailPath: effectiveCover,
                                  fit: BoxFit.cover,
                                  cacheWidth: coverCacheSize,
                                  cacheHeight: coverCacheSize,
                                  placeholder: Container(
                                    color: Colors.white.withValues(alpha: 0.15),
                                  ),
                                  errorWidget: Container(
                                    color: Colors.white.withValues(alpha: 0.15),
                                    child: Icon(
                                      Icons.music_note,
                                      size: thumbSize * 0.3,
                                      color: Colors.white.withValues(
                                        alpha: 0.3,
                                      ),
                                    ),
                                  ),
                                )
                              : Container(
                                  color: Colors.white.withValues(alpha: 0.15),
                                  child: Icon(
                                    Icons.music_note,
                                    size: thumbSize * 0.3,
                                    color: Colors.white.withValues(alpha: 0.3),
                                  ),
                                ),
                        ),
                      ),
                      SizedBox(width: screenWidth * 0.03),

                      // 歌曲标题：最多两行，整体在封面高度内垂直居中
                      // （仅针对标题，不含歌手名；字号相对封面较小）
                      Expanded(
                        child: SizedBox(
                          height: thumbSize,
                          // 垂直居中、水平靠左对齐（原来用 Center 会导致水平也居中）
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              effectiveTitle,
                              style: TextStyle(
                                fontFamily: 'Noto Sans SC',
                                fontWeight: FontWeight.w600,
                                fontSize: titleFontSize,
                                color: Colors.white,
                                height: titleLineHeight,
                              ),
                              strutStyle: StrutStyle(
                                fontFamily: 'Noto Sans SC',
                                fontWeight: FontWeight.w600,
                                fontSize: titleFontSize,
                                height: titleLineHeight,
                                leading: 0,
                                forceStrutHeight: true,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ),

                      // 标题右端与关闭按钮之间的紧凑间距：让标题尽量延伸到叉叉按钮左侧
                      SizedBox(width: (screenWidth * 0.006).clamp(2.0, 5.0)),

                      // 右上角关闭按钮：无圆形背景，尺寸随屏幕宽度等比缩放。
                      // 收紧最小点击区域与内边距，避免按钮的透明留白把标题“挤短”。
                      IconButton(
                        icon: Icon(
                          Icons.close,
                          size: (screenWidth * 0.045).clamp(18.0, 26.0),
                          color: Colors.white.withValues(alpha: 0.6),
                        ),
                        onPressed: _handleExit,
                        iconSize: (screenWidth * 0.045).clamp(18.0, 26.0),
                        padding: EdgeInsets.all(
                          (screenWidth * 0.006).clamp(2.0, 4.0),
                        ),
                        constraints: BoxConstraints(
                          minWidth: (screenWidth * 0.05).clamp(30.0, 36.0),
                          minHeight: (screenWidth * 0.05).clamp(30.0, 36.0),
                        ),
                        tooltip: '关闭',
                      ),
                    ],
                  ),
                ),
              ),

              // ========== 中间区域：全高同步歌词 ==========
              // 与横屏共用同一个 MusicLyricView 组件和双语歌词逻辑
              // 包含：主字幕（原文，大字号/粗字重）+ 副字幕（翻译，小字号/常规字重）
              // 通过 onScrollDirectionChanged 回调通知父组件用户滚动方向
              // GestureDetector 包裹：点击歌词区域时显示控件并重置自动隐藏定时器
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _onUserInteraction,
                  child: MusicLyricView(
                    subtitles: effectiveSubtitles,
                    secondarySubtitles: effectiveSecondarySubtitles,
                    onSeek: _handleSeekTo,
                    positionListenable: mediaService.positionNotifier,
                    onScrollDirectionChanged: _handleLyricScrollDirection,
                    lyricFontSizeScale: _lyricFontSizeScalePortrait,
                    splitSubtitleByLine: splitSubtitleByLine,
                  ),
                ),
              ),
            ],
          ),
          // 底部控件浮层：带羽化模糊，跟随显隐动画从下往上出现 / 消失
          _buildVerticalControlsOverlay(mediaService, effectiveTotalDuration),
        ],
      ),
    );
  }

  /// 竖屏底部控件浮层（强模糊 + 暗化遮罩）
  ///
  /// 歌词区已延伸至屏幕底端，本浮层覆盖在歌词之上：
  /// - 使用 BackdropFilter 对背后歌词做高强度高斯模糊（sigma 30），使字幕完全无法辨认
  /// - 叠加较高不透明度的暗色背景，进一步确保控件区域下方的字幕不可见
  /// - 使用 ShaderMask（dstIn + 竖向线性渐变）让遮罩从顶部渐入、到底部达到满强度，
  ///   羽化过渡区更短，避免控件区域上方出现突兀的硬边界
  /// - 整体由 _controlsSlideAnimation 驱动，跟随显隐动画从下往上出现 / 消失
  Widget _buildVerticalControlsOverlay(
    MediaPlaybackService mediaService,
    Duration effectiveTotalDuration,
  ) {
    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;

    // 顶部羽化留白：较短的羽化过渡，约 6vh
    final featherPadding = (screenHeight * 0.06).clamp(40.0, 72.0);

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SlideTransition(
        position: _controlsSlideAnimation,
        child: IgnorePointer(
          ignoring: !_verticalControlsVisible,
          child: ShaderMask(
            // 羽化遮罩：顶部完全透明（歌词可见）→ 底部不透明（强模糊 + 暗化，字幕不可见）
            shaderCallback: (rect) => LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: const [Colors.transparent, Colors.white],
              stops: const [0.0, 0.25],
            ).createShader(rect),
            blendMode: BlendMode.dstIn,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
              child: Container(
                padding: EdgeInsets.only(
                  left: screenWidth * 0.06,
                  right: screenWidth * 0.06,
                  top: featherPadding,
                  bottom: screenHeight * 0.02,
                ),
                // 高不透明度暗色背景：进一步确保控件下方的字幕完全不可见
                color: Colors.black.withValues(alpha: 0.85),
                child: RepaintBoundary(
                  child: MusicPlaybackControls(
                    positionListenable: _displayPosition,
                    progress: _getEffectiveProgress(),
                    totalDuration: effectiveTotalDuration,
                    isPlaying: mediaService.isPlaying,
                    onProgressChanged: _handleProgressChange,
                    onProgressChangeStart: _handleProgressChangeStart,
                    onProgressChangeEnd: _handleProgressChangeEnd,
                    onPlayPause: () {
                      _onUserInteraction();
                      if (widget.onPlayPause != null) {
                        widget.onPlayPause!.call();
                      } else {
                        if (mediaService.isPlaying) {
                          mediaService.pause();
                        } else {
                          mediaService.resume();
                        }
                      }
                    },
                    onPrevious: () {
                      _onUserInteraction();
                      widget.onPrevious?.call();
                    },
                    onNext: () {
                      _onUserInteraction();
                      widget.onNext?.call();
                    },
                    onFontSizeAdjust: () {
                      _onUserInteraction();
                      setState(() {
                        _showFontSizeSlider = !_showFontSizeSlider;
                      });
                    },
                    fontSizeButtonKey: _fontSizeButtonKey,
                    volume: mediaService.volume,
                    isMuted: mediaService.isMuted,
                    onVolumeChanged: (v) {
                      _onUserInteraction();
                      mediaService.setVolume(v);
                    },
                    onToggleMute: () {
                      _onUserInteraction();
                      mediaService.toggleMute();
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 低频数据快照 — Selector 选中值，仅当这些字段变化时才重建 MusicPlayerScreen。
///
/// 关键：快照**不含 position**。position 由 positionNotifier 逐帧驱动（经
/// _displayPosition → 进度条 ValueListenableBuilder），无需 build 刷新。
/// 因此 300ms 定时器的 notifyListeners（仅 position 变化）不会触发 builder，
/// 从根本上消除每 300ms 的全屏重建。
///
/// 字幕列表使用身份比较（identical）：MediaPlaybackService 仅在 setSubtitleState
/// 中整体替换 _subtitles/_secondarySubtitles（新实例），不会原地 mutate，故身份
/// 比较既正确又高效。
class _PlayerSnapshot {
  final String itemId;
  final String? cover;
  final String title;
  final Duration duration;
  final List<SubtitleItem> subtitles;
  final List<SubtitleItem> secondarySubtitles;
  final bool isPlaying;
  final double volume;
  final bool isMuted;

  const _PlayerSnapshot({
    required this.itemId,
    required this.cover,
    required this.title,
    required this.duration,
    required this.subtitles,
    required this.secondarySubtitles,
    required this.isPlaying,
    required this.volume,
    required this.isMuted,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _PlayerSnapshot &&
          itemId == other.itemId &&
          cover == other.cover &&
          title == other.title &&
          duration == other.duration &&
          identical(subtitles, other.subtitles) &&
          identical(secondarySubtitles, other.secondarySubtitles) &&
          isPlaying == other.isPlaying &&
          volume == other.volume &&
          isMuted == other.isMuted;

  @override
  int get hashCode => Object.hash(
    itemId,
    cover,
    title,
    duration,
    subtitles,
    secondarySubtitles,
    isPlaying,
    volume,
    isMuted,
  );
}
