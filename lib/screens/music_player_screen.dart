import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/subtitle_model.dart';
import '../services/media_playback_service.dart';
import '../services/audio_playback_compatibility_service.dart';
import '../services/music_artwork_backdrop_cache.dart';
import '../services/settings_service.dart';
import '../utils/desktop_player_shortcuts.dart';
import '../models/video_item.dart';
import '../widgets/cached_thumbnail_widget.dart';
import '../widgets/music_album_cover.dart';
import '../widgets/music_lyric_view.dart';
import '../widgets/music_playback_controls.dart';
import '../widgets/music_text_optical_alignment.dart';

/// Prepares the already-blurred artwork while the source playback page is
/// still visible. This moves image decoding and blur work out of the route's
/// first frame, where it would otherwise interrupt the page transition.
Future<void> prepareMusicPlayerArtwork(
  BuildContext context,
  String? coverPath,
) async {
  final bytes = await MusicArtworkBackdropCache.instance.warm(coverPath);
  if (bytes == null || !context.mounted) return;
  await precacheImage(MemoryImage(bytes), context);
}

Route<T> buildMusicPlayerRoute<T>({required WidgetBuilder builder}) {
  return PageRouteBuilder<T>(
    settings: const RouteSettings(name: 'music-player'),
    fullscreenDialog: true,
    opaque: true,
    transitionDuration: const Duration(milliseconds: 280),
    reverseTransitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.018),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

@visibleForTesting
SystemUiMode musicPlayerSystemUiModeForSize(Size viewportSize) {
  return viewportSize.width > viewportSize.height
      ? SystemUiMode.immersiveSticky
      : SystemUiMode.edgeToEdge;
}

@visibleForTesting
double musicControlsLyricMaskProgress(double controllerValue) {
  return const Interval(
    0.0,
    0.18,
    curve: Curves.easeOutCubic,
  ).transform(controllerValue.clamp(0.0, 1.0));
}

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
  final bool restoreSystemUiOnExit;

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
    this.restoreSystemUiOnExit = true,
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
  bool? _lastSystemUiLandscape;

  /// 显示位置通知器 — 驱动进度条每帧平滑更新
  /// 正常播放时跟随 service.positionNotifier，拖动时切到拖动位置
  final ValueNotifier<Duration> _displayPosition = ValueNotifier<Duration>(
    Duration.zero,
  );

  /// The lyric clock follows playback normally, but receives the scrub target
  /// explicitly on drag end so a seek into the prelude can still reposition
  /// the list while keeping the active lyric index at -1.
  final ValueNotifier<Duration> _lyricPosition = ValueNotifier<Duration>(
    Duration.zero,
  );
  final MusicLyricPositionController _lyricPositionController =
      MusicLyricPositionController();

  /// 竖屏模式下底部播放控件的可见性（Apple Music 手机端交互）
  ///
  /// 交互逻辑：
  /// - 初始显示（true）
  /// - 用户**向下滚**歌词 → 延迟隐藏（false），歌词占满全屏
  /// - 用户**向上滚**歌词 → 立即显示（true）
  /// - 自动跟随恢复 → 显示（true）
  bool _verticalControlsVisible = true;

  /// 隐藏/显示控件的动画时长
  static const Duration _controlsAnimDuration = Duration(milliseconds: 380);

  /// 底部控件显隐动画控制器（实现从下往上出现、从上往下消失）
  late AnimationController _controlsAnimationController;
  late Animation<Offset> _controlsSlideAnimation;

  /// 向下滚动后延迟隐藏的等待时间（避免误触）
  Timer? _hideControlsTimer;

  /// 播放一段时间后自动隐藏控件的定时器（Apple Music 核心逻辑）
  /// 控件显示后，若用户在 _autoHideDelay 时间内没有交互，则自动隐藏
  Timer? _autoHideControlsTimer;

  bool _suppressNextBackgroundTap = false;
  bool _isLyricScrollActive = false;
  int _audioCodecProbeGeneration = 0;
  String? _audioCodecProbePath;

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
      reverseDuration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _controlsSlideAnimation =
        Tween<Offset>(
          // Apple Music 的控制区更接近淡出和轻微下沉，而不是整块滑出屏幕。
          begin: const Offset(0, 0.08),
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
    _lyricPosition.value = _positionMediaService.position;

    // 请求焦点以接收键盘事件
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreKeyboardFocus();
    });

    // 手机竖屏显示状态栏和手势/导航栏；横屏保持沉浸式播放。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncMobileSystemUiForOrientation(force: true);
    });

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
    if (_lyricPosition.value != service.positionNotifier.value) {
      _lyricPosition.value = service.positionNotifier.value;
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
    _lyricPosition.dispose();
    _lyricPositionController.dispose();

    // Music 页是播放页的子页时，退出后底下仍然是播放页，
    // 不能先恢复系统栏，否则路由切换期间会发生一次视口抖动。
    if (widget.restoreSystemUiOnExit) {
      _restoreSystemUIMode();
    }

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _scheduleKeyboardFocusRestore();
      if (ModalRoute.of(context)?.isCurrent == true) {
        _syncMobileSystemUiForOrientation(force: true);
      }
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        _syncMobileSystemUiForOrientation();
      }
    });
  }

  bool get _isMobilePlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  void _syncMobileSystemUiForOrientation({bool force = false}) {
    if (!_isMobilePlatform) return;
    final viewportSize = MediaQuery.sizeOf(context);
    final mode = musicPlayerSystemUiModeForSize(viewportSize);
    final isLandscape = mode == SystemUiMode.immersiveSticky;
    if (!force && _lastSystemUiLandscape == isLandscape) return;
    _lastSystemUiLandscape = isLandscape;

    if (isLandscape) {
      unawaited(SystemChrome.setEnabledSystemUIMode(mode));
      return;
    }

    _restoreSystemUIMode();
  }

  void _restoreSystemUIMode() {
    if (_isMobilePlatform) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarDividerColor: Colors.transparent,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
      );
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
      _hideControlsTimer?.cancel();
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
      if (!_isLyricScrollActive) _startAutoHideTimer();
    }
  }

  void _handleLyricScrollActivity(bool active) {
    _isLyricScrollActive = active;
    if (active) {
      _cancelAutoHideTimer();
    } else if (_verticalControlsVisible) {
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

  void _handlePortraitBackgroundTap() {
    if (_suppressNextBackgroundTap) {
      _suppressNextBackgroundTap = false;
      return;
    }
    _onUserInteraction();
  }

  void _handleDirectLyricTap() {
    _suppressNextBackgroundTap = true;
    // A semantics action has no enclosing pointer tap. Bound suppression to
    // the current event/frame so it cannot consume a later background tap.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _suppressNextBackgroundTap = false;
    });
  }

  bool _isConfirmedAlacItem(VideoItem? item) {
    if (item == null || item.type != MediaType.audio) return false;
    final declaredCodec = item.codec?.trim().toLowerCase();
    if (declaredCodec == 'alac') return true;
    final cachedCodec = AudioPlaybackCompatibilityService.cachedAudioCodec(
      item.path,
    );
    if (cachedCodec != null) return cachedCodec.toLowerCase() == 'alac';

    final extension = item.path.toLowerCase();
    if (extension.endsWith('.alac')) return true;
    if (!extension.endsWith('.m4a') && !extension.endsWith('.m4b')) {
      return false;
    }
    _scheduleAudioCodecProbe(item);
    return false;
  }

  void _scheduleAudioCodecProbe(VideoItem item) {
    if (_audioCodecProbePath == item.path) return;
    _audioCodecProbePath = item.path;
    final generation = ++_audioCodecProbeGeneration;
    unawaited(
      AudioPlaybackCompatibilityService.probeAudioCodec(item.path).then((_) {
        if (!mounted || generation != _audioCodecProbeGeneration) return;
        if (_mediaService.currentItem?.path != item.path) return;
        setState(() {});
      }),
    );
  }

  void _handleSeekTo(Duration position) {
    final onSeek = widget.onSeek;
    if (onSeek != null) {
      onSeek(position);
    } else {
      unawaited(_mediaService.seekTo(position, source: 'music-player'));
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
    _cancelAutoHideTimer();
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
    _lyricPositionController.locate(seekPos);
    _lyricPosition.value = seekPos;
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
        final effectiveCover = snapshot.cover ?? widget.coverImagePath;
        final effectiveTitle = snapshot.title;
        // VideoItem 没有 artist 字段，使用 widget.artist（如果有传入）或留空
        final effectiveArtist = widget.artist;
        final effectiveTotalDuration = snapshot.duration;
        final effectiveSubtitles = snapshot.subtitles;
        final effectiveSecondarySubtitles = snapshot.secondarySubtitles;

        return Scaffold(
          backgroundColor: Colors.black,
          body: Focus(
            focusNode: _focusNode,
            autofocus: true,
            onKeyEvent: _handleKeyEvent,
            child: Stack(
              children: [
                // Block 1: 背景层（封面高斯模糊 + 半透明黑色遮罩）
                _buildBackgroundLayer(snapshot.itemId, effectiveCover),

                // 页面骨架在切集时保持原位。仅封面背景与歌词内容自行过渡，
                // 避免标题、进度条和控制按钮随整页缩放或闪动。
                SafeArea(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final isNarrow = constraints.maxWidth < 768;
                          if (isNarrow) {
                            return _buildVerticalLayout(
                              mediaService,
                              snapshot.itemId,
                              effectiveTitle,
                              effectiveArtist,
                              effectiveSubtitles,
                              effectiveSecondarySubtitles,
                              splitSubtitleByLine,
                            );
                          }
                          return _buildHorizontalLayout(
                            mediaService,
                            snapshot.itemId,
                            effectiveTotalDuration,
                            effectiveTitle,
                            effectiveArtist,
                            effectiveSubtitles,
                            effectiveSecondarySubtitles,
                            splitSubtitleByLine,
                          );
                        },
                      ),
                      _buildWindowControls(),
                    ],
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
    _onUserInteraction();
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
          onChangeStart: (_) {
            _onUserInteraction();
            _cancelAutoHideTimer();
          },
          onChangeEnd: (_) => _startAutoHideTimer(),
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
  Widget _buildBackgroundLayer(String itemId, String? coverPath) {
    return Positioned.fill(
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF343338), Color(0xFF111113)],
                ),
              ),
            ),

            // 本地封面在后台 isolate 中预先缩小并强模糊。进入页面后这里只
            // 拉伸一张缓存位图，不再对全屏纹理执行实时高斯模糊。
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 520),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: coverPath != null && coverPath.isNotEmpty
                  ? RepaintBoundary(
                      key: ValueKey<String>('music-backdrop-$coverPath'),
                      child: _MusicBackdropArtwork(
                        itemId: itemId,
                        coverPath: coverPath,
                      ),
                    )
                  : const SizedBox.expand(
                      key: ValueKey<String>('music-backdrop-fallback'),
                    ),
            ),

            // 保留封面色相，同时稳定白色歌词的对比度和上下层次。
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x5C000000),
                    Color(0x2E000000),
                    Color(0x52000000),
                    Color(0x8A000000),
                  ],
                  stops: [0.0, 0.30, 0.68, 1.0],
                ),
              ),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(0.45, -0.35),
                  radius: 1.25,
                  colors: [Color(0x00FFFFFF), Color(0x59000000)],
                  stops: [0.36, 1.0],
                ),
              ),
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
    String itemId,
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
                child: _buildEpisodeLyricTransition(
                  itemId: itemId,
                  child: MusicLyricView(
                    key: ValueKey<String>('music-lyric-view-$itemId'),
                    subtitles: effectiveSubtitles,
                    secondarySubtitles: effectiveSecondarySubtitles,
                    onSeek: _handleSeekTo,
                    positionListenable: _lyricPosition,
                    positionController: _lyricPositionController,
                    stabilizeAlacDirectSeek: _isConfirmedAlacItem(
                      mediaService.currentItem,
                    ),
                    isPlaying: mediaService.isPlaying,
                    lyricFontSizeScale: _lyricFontSizeScaleLandscape,
                    splitSubtitleByLine: splitSubtitleByLine,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Only the transcript surface participates in an episode transition.
  /// Keeping the layout builder outside this switcher guarantees that the
  /// cover, metadata, progress bar, and playback buttons never move.
  Widget _buildEpisodeLyricTransition({
    required String itemId,
    required Widget child,
  }) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 160),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        fit: StackFit.expand,
        children: <Widget>[...previousChildren, ?currentChild],
      ),
      transitionBuilder: (transitionChild, animation) =>
          FadeTransition(opacity: animation, child: transitionChild),
      child: KeyedSubtree(
        key: ValueKey<String>('music-lyric-episode-$itemId'),
        child: child,
      ),
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
    String itemId,
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

    // 标题字号继续使用旧版封面尺寸作为基准，避免本次视觉改造改变字体大小。
    final titleSizeReference = (screenWidth * 0.14).clamp(36.0, 56.0);
    // Apple Music 的 Header 封面更大，但独立于标题字号计算。
    final thumbSize = (screenWidth * 0.16).clamp(48.0, 68.0);
    // 竖屏标题字号：相对封面较小，整体在封面高度内垂直居中（仅针对标题，不含歌手名）
    const double titleLineHeight = 1.2;
    final double titleFontSize = titleSizeReference * 0.30;

    // 封面解码分辨率需乘设备像素比，否则在 Retina/高分屏上会被放大而模糊
    final int coverCacheSize =
        (thumbSize * MediaQuery.of(context).devicePixelRatio).toInt();

    // 外层 GestureDetector：点击屏幕任何地方都显示控件并重置自动隐藏定时器
    // （Apple Music 风格：控件隐藏后，点击屏幕任意位置可唤出）
    final lyricView = _buildEpisodeLyricTransition(
      itemId: itemId,
      child: MusicLyricView(
        key: ValueKey<String>('music-lyric-view-$itemId'),
        subtitles: effectiveSubtitles,
        secondarySubtitles: effectiveSecondarySubtitles,
        onSeek: _handleSeekTo,
        positionListenable: _lyricPosition,
        positionController: _lyricPositionController,
        onScrollDirectionChanged: _handleLyricScrollDirection,
        onManualScrollActivityChanged: _handleLyricScrollActivity,
        onDirectLyricTap: _handleDirectLyricTap,
        stabilizeAlacDirectSeek: _isConfirmedAlacItem(mediaService.currentItem),
        isPlaying: mediaService.isPlaying,
        lyricFontSizeScale: _lyricFontSizeScalePortrait,
        splitSubtitleByLine: splitSubtitleByLine,
        anchorFraction: 0.215,
        horizontalPaddingFraction: 0.082,
        applyEdgeFade: false,
      ),
    );

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _handlePortraitBackgroundTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 只裁切歌词层：背景、封面、标题与播放控件完全不参与遮罩。
          // 顶部在标题栏下方才羽化显现；底部在进度条上方开始羽化消失，
          // 到达进度条时已经完全透明，并随控件显隐动画恢复。
          AnimatedBuilder(
            key: const ValueKey('music-portrait-lyric-mask'),
            animation: _controlsAnimationController,
            child: RepaintBoundary(child: lyricView),
            builder: (context, child) {
              final controlsMaskProgress = musicControlsLyricMaskProgress(
                _controlsAnimationController.value,
              );
              return ShaderMask(
                key: const ValueKey('music-portrait-lyric-visibility-mask'),
                blendMode: BlendMode.dstIn,
                shaderCallback: (bounds) {
                  final height = bounds.height;
                  final topHiddenEnd = screenHeight * 0.014 + thumbSize + 6.0;
                  final topFeatherEnd =
                      topHiddenEnd + (screenHeight * 0.085).clamp(58.0, 82.0);

                  final timeFontSize = (screenHeight * 0.032).clamp(10.0, 13.0);
                  final progressBlockHeight = 25.0 + timeFontSize * 1.35;
                  final controlsGap = (screenHeight * 0.05).clamp(34.0, 54.0);
                  const controlRowHeight = 55.0;
                  final controlsBottomPadding = (screenHeight * 0.035).clamp(
                    20.0,
                    34.0,
                  );
                  final bottomHiddenStart =
                      height -
                      controlsBottomPadding -
                      progressBlockHeight -
                      controlsGap -
                      controlRowHeight;
                  final bottomFeatherStart =
                      bottomHiddenStart -
                      (screenHeight * 0.10).clamp(70.0, 96.0);
                  final bottomAlpha = ((1.0 - controlsMaskProgress) * 255)
                      .round();

                  double stop(double value) => (value / height).clamp(0.0, 1.0);

                  return LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      const Color(0x00FFFFFF),
                      const Color(0x00FFFFFF),
                      const Color(0xFFFFFFFF),
                      const Color(0xFFFFFFFF),
                      Color.fromARGB(bottomAlpha, 255, 255, 255),
                      Color.fromARGB(bottomAlpha, 255, 255, 255),
                    ],
                    stops: [
                      0.0,
                      stop(topHiddenEnd),
                      stop(topFeatherEnd),
                      stop(bottomFeatherStart),
                      stop(bottomHiddenStart),
                      1.0,
                    ],
                  ).createShader(bounds);
                },
                child: child,
              );
            },
          ),

          // 顶部元数据保持原有背景；经过其后的歌词由上面的 alpha mask 隐藏。
          Positioned(
            left: screenWidth * 0.082,
            right: screenWidth * 0.082,
            top: screenHeight * 0.014,
            child: SizedBox(
              key: const ValueKey('music-portrait-header'),
              height: thumbSize,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // 专辑缩略图（使用 CachedThumbnailWidget 支持缓存，仅显示封面不渲染标题）
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: thumbSize,
                      height: thumbSize,
                      child: effectiveCover != null && effectiveCover.isNotEmpty
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
                                  color: Colors.white.withValues(alpha: 0.3),
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
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            MusicTextOpticalAlignment(
                              applyCjkRaise: musicTextContainsCjk(
                                effectiveTitle,
                              ),
                              fontSize: titleFontSize,
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
                                maxLines: effectiveArtist.isEmpty ? 2 : 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (effectiveArtist.isNotEmpty)
                              MusicTextOpticalAlignment(
                                applyCjkRaise: musicTextContainsCjk(
                                  effectiveArtist,
                                ),
                                fontSize: titleFontSize,
                                child: Text(
                                  effectiveArtist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: 'Noto Sans SC',
                                    fontWeight: FontWeight.w500,
                                    fontSize: titleFontSize,
                                    height: titleLineHeight,
                                    color: Colors.white.withValues(alpha: 0.58),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // 标题右端与关闭按钮之间的紧凑间距：让标题尽量延伸到叉叉按钮左侧
                  SizedBox(width: (screenWidth * 0.006).clamp(2.0, 5.0)),

                  // 可见圆形缩小，但 IconButton 仍保留系统的舒适触控热区。
                  IconButton(
                    icon: DecoratedBox(
                      key: const ValueKey('music-portrait-close-background'),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.16),
                      ),
                      child: SizedBox.square(
                        dimension: (screenWidth * 0.088).clamp(32.0, 38.0),
                        child: Icon(
                          Icons.close_rounded,
                          size: (screenWidth * 0.043).clamp(17.0, 20.0),
                          color: Colors.white.withValues(alpha: 0.88),
                        ),
                      ),
                    ),
                    onPressed: _handleExit,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    tooltip: '关闭',
                  ),
                ],
              ),
            ),
          ),
          // 底部控件浮层只承载控件，不再修改背景。
          _buildVerticalControlsOverlay(mediaService, effectiveTotalDuration),
        ],
      ),
    );
  }

  /// 竖屏底部控件浮层。
  ///
  /// 歌词区已延伸至屏幕底端，本浮层只负责控件自身的淡入与轻微位移。
  /// 歌词的上下遮挡由歌词层自己的 alpha mask 完成，背景始终保持原样。
  Widget _buildVerticalControlsOverlay(
    MediaPlaybackService mediaService,
    Duration effectiveTotalDuration,
  ) {
    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;

    // 只覆盖进度条与按钮所需的播放区；底部对齐不变，因此不会移动控件。
    final overlayHeight = (screenHeight * 0.29).clamp(220.0, 330.0);
    final controlsBottomPadding = (screenHeight * 0.035).clamp(20.0, 34.0);

    return Positioned(
      key: const ValueKey('music-portrait-controls-overlay'),
      left: 0,
      right: 0,
      bottom: 0,
      height: overlayHeight,
      child: IgnorePointer(
        ignoring: !_verticalControlsVisible,
        child: FadeTransition(
          opacity: CurvedAnimation(
            parent: _controlsAnimationController,
            curve: const Interval(0.18, 1.0, curve: Curves.easeOutCubic),
          ),
          child: SlideTransition(
            position: _controlsSlideAnimation,
            child: Padding(
              padding: EdgeInsets.only(
                left: screenWidth * 0.082,
                right: screenWidth * 0.082,
                bottom: controlsBottomPadding,
              ),
              child: Align(
                alignment: Alignment.bottomCenter,
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

class _MusicBackdropArtwork extends StatefulWidget {
  final String itemId;
  final String coverPath;

  const _MusicBackdropArtwork({required this.itemId, required this.coverPath});

  @override
  State<_MusicBackdropArtwork> createState() => _MusicBackdropArtworkState();
}

class _MusicBackdropArtworkState extends State<_MusicBackdropArtwork> {
  Uint8List? _blurredBytes;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _MusicBackdropArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coverPath != widget.coverPath) _load();
  }

  void _load() {
    final requestId = ++_requestId;
    final cached = MusicArtworkBackdropCache.instance.peek(widget.coverPath);
    if (cached != null) {
      _blurredBytes = cached;
      return;
    }
    _blurredBytes = null;
    MusicArtworkBackdropCache.instance.warm(widget.coverPath).then((bytes) {
      if (!mounted || requestId != _requestId || bytes == null) return;
      setState(() => _blurredBytes = bytes);
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _blurredBytes;
    return SizedBox.expand(
      child: Transform.scale(
        scale: 1.28,
        child: ColorFiltered(
          colorFilter: const ColorFilter.matrix(<double>[
            1.14,
            -0.05,
            -0.05,
            0,
            0,
            -0.05,
            1.12,
            -0.05,
            0,
            0,
            -0.05,
            -0.05,
            1.14,
            0,
            0,
            0,
            0,
            0,
            1,
            0,
          ]),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 360),
            layoutBuilder: (currentChild, previousChildren) {
              return Stack(
                fit: StackFit.expand,
                children: <Widget>[...previousChildren, ?currentChild],
              );
            },
            child: bytes != null
                ? Image.memory(
                    bytes,
                    key: ValueKey<String>(
                      'music-backdrop-memory-${widget.coverPath}',
                    ),
                    width: double.infinity,
                    height: double.infinity,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.low,
                  )
                : ImageFiltered(
                    key: ValueKey<String>(
                      'music-backdrop-fallback-${widget.coverPath}',
                    ),
                    imageFilter: ImageFilter.blur(
                      sigmaX: 24,
                      sigmaY: 24,
                      tileMode: TileMode.decal,
                    ),
                    child: SizedBox.expand(
                      child: CachedThumbnailWidget(
                        videoId: widget.itemId,
                        thumbnailPath: widget.coverPath,
                        fit: BoxFit.cover,
                        cacheWidth: 144,
                        cacheHeight: 144,
                        fadeInDuration: const Duration(milliseconds: 180),
                        placeholder: const SizedBox.expand(),
                        errorWidget: const SizedBox.expand(),
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
