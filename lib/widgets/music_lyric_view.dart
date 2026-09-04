import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../models/subtitle_model.dart';
import 'music_text_optical_alignment.dart';

@visibleForTesting
int musicLyricTapScrollDurationMs(int lineDistance) {
  return (580 + lineDistance.abs() * 42).clamp(580, 820);
}

@visibleForTesting
const Curve musicLyricTapScrollCurve = Cubic(0.32, 0.0, 0.18, 1.0);

/// Sends explicit, repeatable lyric-location commands. Unlike a
/// `ValueNotifier<Duration>`, equal positions are not deduplicated: every scrub
/// release is a real request and a newer request may interrupt the old one.
class MusicLyricPositionController extends ChangeNotifier {
  Duration _position = Duration.zero;

  Duration get position => _position;

  void locate(Duration position) {
    _position = position;
    notifyListeners();
  }
}

/// Apple Music 风格歌词列表视图（响应式 vh 单位）
///
/// 自实现版本（不再依赖 flutter_lyric），修复以下问题：
/// - 鼠标滚轮无法控制歌词上下滚动（原版用 CustomPaint+GestureDetector，无 Scrollable）
/// - 点击某行无法迅速、准确跳转到该行（原版点击后需等待 progress 回流才滚动）
///
/// 核心机制：
/// - 基于 SingleChildScrollView + ScrollController，桌面端鼠标滚轮原生支持
/// - 当前行锚定在视口 30% 处（Apple Music 风格）
/// - 进度变化时自动平滑滚动到当前行
/// - 用户滚动（鼠标滚轮/拖拽）后 3 秒自动恢复跟随当前行
/// - 点击某行立即跳转 seek 并滚动到该行
/// - 顶部/底部渐变遮罩
///
/// === 性能优化 ===
/// 通过 positionListenable（`ValueListenable<Duration>`）驱动进度更新，
/// 只有歌词行在进度变化时重绘，整棵歌词控件不因进度变化重建。
///
/// === 双语歌词排版规范（对标 Apple Music 手机端 UI）===
/// - 主字幕（原文）：大字号 ~4.5vh，英文 800 (ExtraBold)，中文 600 (SemiBold)，纯白高亮
/// - 副字幕（翻译）：小字号 ~2.2vh（约主字幕的 0.48 倍），字重与主字幕完全一致，半透明辅助
/// - 中文字体：Noto Sans SC（思源黑体，SemiBold），英文字体：Inter（ExtraBold）
class MusicLyricView extends StatefulWidget {
  final List<SubtitleItem> subtitles;
  final List<SubtitleItem> secondarySubtitles;
  final ValueChanged<Duration>? onSeek;

  /// 进度通知器 — 每帧由 MediaPlaybackService.positionNotifier 更新，
  /// 歌词视图通过监听此通知器来高亮当前行，无需父组件重建。
  final ValueListenable<Duration>? positionListenable;

  /// Explicit positioning commands, primarily from progress-bar drag end.
  final MusicLyricPositionController? positionController;

  /// 用户滚动方向变化回调。
  ///
  /// Apple Music 手机端交互：用户向下滚动歌词时隐藏底部播放控件，
  /// 向上滚动时重新显示。正值表示向上滚（内容向下移），负值表示向下滚（内容向下移）。
  /// null 表示恢复自动跟随模式（控件应重新显示）。
  final void Function(double? direction)? onScrollDirectionChanged;

  /// Reports the actual manual scroll gesture lifetime. Unlike
  /// [onScrollDirectionChanged], this ends as soon as scrolling stops rather
  /// than when the delayed auto-follow mode resumes.
  final ValueChanged<bool>? onManualScrollActivityChanged;

  /// Called when a lyric row commits a direct tap. This is separate from
  /// [onSeek] so a parent background-tap recognizer can suppress only the same
  /// pointer interaction without treating the seek as a generic page tap.
  final VoidCallback? onDirectLyricTap;

  /// Keeps a directly tapped lyric logically selected across the small native
  /// seek undershoot/overshoot produced by ALAC packet boundaries. Callers must
  /// opt in only after confirming the source codec is ALAC.
  final bool stabilizeAlacDirectSeek;

  /// Whether the shared playback clock is currently advancing.
  final bool isPlaying;

  /// 歌词字号缩放比例（1.0 = 默认中等偏大，0.6 = 小，1.4 = 大）
  final double lyricFontSizeScale;

  /// 是否将第一行识别为主字幕、其余行作为副字幕（与 video_player_screen 一致）。
  /// 仅当没有独立副字幕轨道（secondarySubtitles 为空）时生效。
  final bool splitSubtitleByLine;

  /// 当前行在歌词视口内的纵向锚点。横屏默认沿用原来的 30%，
  /// 竖屏可传入更靠上的值以匹配 Apple Music 手机布局。
  final double anchorFraction;

  /// 歌词左右留白占屏幕宽度的比例。
  final double horizontalPaddingFraction;

  /// 是否在组件内部绘制固定的上下渐隐。竖屏由父层根据控制栏动画
  /// 动态绘制遮罩，因此会关闭这里的固定遮罩。
  final bool applyEdgeFade;

  const MusicLyricView({
    super.key,
    required this.subtitles,
    this.secondarySubtitles = const [],
    this.onSeek,
    this.positionListenable,
    this.positionController,
    this.onScrollDirectionChanged,
    this.onManualScrollActivityChanged,
    this.onDirectLyricTap,
    this.stabilizeAlacDirectSeek = false,
    this.isPlaying = true,
    this.lyricFontSizeScale = 1.0,
    this.splitSubtitleByLine = false,
    this.anchorFraction = 0.30,
    this.horizontalPaddingFraction = 0.05,
    this.applyEdgeFade = true,
  });

  @override
  State<MusicLyricView> createState() => MusicLyricViewState();
}

/// Public State class for MusicLyricView.
///
/// This allows external widgets (e.g., MusicPlayerScreen) to call
/// public methods like [scrollToCurrentIndex] via a [GlobalKey].
// ignore_for_file: library_private_classes
class MusicLyricViewState extends State<MusicLyricView>
    with SingleTickerProviderStateMixin {
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ScrollController _windowsScrollController = ScrollController();
  List<GlobalKey> _windowsLineKeys = <GlobalKey>[];
  final Set<_LyricHitRegionState> _lyricHitRegions = <_LyricHitRegionState>{};

  /// 预计算的副字幕文本列表（与 widget.subtitles 一一对应）。
  /// 在 initState/didUpdateWidget 中预计算一次，构建时 O(1) 查表，
  /// 消除每次歌词树重建时 N 行各调用 _findSecondaryText 的开销。
  List<String> _secondaryTexts = const [];

  /// 当前行索引（基于播放进度计算）
  /// -1 means playback is still before the first timed lyric.
  int _activeIndex = -1;

  /// 当前播放位置（由 positionListenable 驱动，每帧更新）
  Duration _currentPosition = Duration.zero;

  /// Lyrics remain hidden until the target line has been laid out and located.
  /// This prevents a new episode from flashing at line zero before jumping.
  late AnimationController _contentAnimationController;

  /// 用户点击高亮的行索引（点击后到进度追上之前高亮显示）
  int _tappedIndex = -1;
  int? _alacLatchedTapIndex;

  static const int _alacSeekBoundaryToleranceMs = 450;

  /// 手指按下时的短暂背景反馈，与 seek 完成前的文字高亮分离。
  int _pressedIndex = -1;
  Timer? _pressedFeedbackTimer;

  /// 是否已完成过「进入页面时的初始定位」。
  /// 用于保证即使当前索引与初始值相同（例如暂停在 0 秒、当前就是第 0 行），
  /// 也能把该行滚动到锚点位置，而不是停留在自然滚动位置（顶部）。
  bool _initialLocateDone = false;

  /// 鼠标悬停的行索引（-1 表示没有悬停）
  int _hoveredIndex = -1;

  /// 用户是否正在手动滚动（触摸拖拽 / 鼠标拖拽）
  bool _isUserScrolling = false;

  /// 是否正在执行程序化滚动（用于区分用户滚动与自动滚动）
  bool _isProgrammaticScroll = false;

  /// 记录最后一次手动滚动方向的符号（>0 向下滚隐藏控件，<0 向上滚显示控件）
  double? _lastManualScrollDirection;

  Timer? _resumeTimer;
  Timer? _programmaticScrollResetTimer;
  Timer? _tapGuardResetTimer;
  Timer? _seekDispatchTimer;
  bool _disposed = false;
  int _locateRevealRequestId = 0;

  /// Only the newest scroll request may reset the shared interaction guards.
  /// ItemScrollController cancels its previous transition when scrollTo is
  /// called again; this id prevents the canceled Future from cleaning up the
  /// replacement request.
  int _scrollRequestId = 0;
  bool _scrollAnimationInFlight = false;

  /// Raw-pointer tap tracking remains owned by this stable parent State.  The
  /// positioned-list package swaps out its secondary list when an animated
  /// transition is interrupted, which can dispose a row between pointer-down
  /// and pointer-up.  Keeping the gesture here makes that interruption tappable.
  int? _pendingTapPointer;
  int? _pendingTapIndex;
  Offset? _pendingTapOrigin;
  int? _lastCommittedPointer;
  int? _deferredDirectTapPointer;
  VoidCallback? _deferredDirectTapScroll;

  /// Native players should not receive an unbounded burst of seeks. Visual
  /// feedback and scrolling stay immediate while rapid seeks are latest-wins.
  DateTime? _lastSeekDispatchedAt;
  Duration? _pendingSeekPosition;
  static const Duration _minimumSeekInterval = Duration(milliseconds: 120);

  /// While a direct tap owns the scroll, the position notification produced by
  /// that seek may update highlighting but must not start a competing scroll.
  int? _directTapScrollTarget;
  int _directTapRequestId = 0;
  bool _windowsTapScrollCompleted = false;
  bool _windowsTapSeekAcknowledged = false;
  Timer? _windowsTapTransactionTimeout;

  int? _explicitLocateActiveIndex;
  int _explicitLocateRequestId = 0;

  /// 用于 NotificationListener 判断是否为用户拖拽滚动
  bool _isDragScrolling = false;

  /// 是否正在执行点击跳转（用于避免点击跳转时的滚动被误判为用户手动滚动）
  bool _isTappingLine = false;

  /// 用户滚动后恢复自动跟随的延时
  static const Duration _autoResumeDelay = Duration(seconds: 3);

  // ========== Apple Music 风格动画参数 ==========

  /// 正常播放时透明度变化动画时长（ms）— Apple Music 风格：流畅但不过慢
  static const int _normalOpacityDuration = 400;

  /// 大幅度跳转时透明度变化动画时长（ms）— 更快的响应
  static const int _jumpOpacityDuration = 250;

  /// 正常播放时滚动动画时长（ms）
  static const int _normalScrollDuration = 400;

  /// 大幅度跳转时滚动动画时长（ms）— 快速定位
  static const int _jumpScrollDuration = 250;

  /// 判断是否为大幅度跳转的行数阈值
  static const int _largeJumpThreshold = 5;

  // ========== 字体规范（参考竖屏设计文档）==========

  /// 英文字体族：Inter（Apple SF Pro 最佳替代）
  static const String _fontFamilyEng = 'Inter';

  /// 中文字体族：Noto Sans SC（思源黑体，首选）/ MiSans（备选），开源可商用
  /// 思源黑体由 Google 和 Adobe 联合开发，最接近 Apple PingFang SC
  static const String _fontFamilyZh = 'Noto Sans SC';

  /// 检测文本是否包含中文字符（CJK 统一表意文字 U+4E00~U+9FFF）
  /// 用于自动判断原文/翻译应该用哪个字体显示
  static bool _isChineseText(String text) {
    for (final rune in text.runes) {
      if (rune >= 0x4E00 && rune <= 0x9FFF) return true;
    }
    return false;
  }

  /// 原文与翻译的字号比例（中文约为英文的 0.48 倍）
  static const double _zhSizeRatio = 0.48;

  /// 中英文行间距（中文紧贴在英文下方，约 1vh）
  static const double _engZhGapRatio = 0.022;

  /// 段落间距（组与组之间的大间距，约 4.5vh）
  static const double _stanzaGapRatio = 0.045;

  @override
  void initState() {
    super.initState();
    _resetWindowsLineKeys();
    _precomputeSecondaryTexts();

    _contentAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );

    // 监听 positionListenable 以更新歌词高亮
    widget.positionListenable?.addListener(_onPositionChanged);
    widget.positionController?.addListener(_onExplicitLocateRequested);
    _currentPosition = widget.positionListenable?.value ?? Duration.zero;
    _activeIndex = _findActiveIndex(_currentPosition);

    // 首帧布局完成后做一次无动画定位
    _scheduleLocateAndReveal();
  }

  /// 当 positionListenable 变化时更新 _currentPosition 并刷新歌词高亮
  ///
  /// 优化：直接调用 _updateActiveIndex，确保定位响应及时
  /// - 移除 Timer(Duration.zero) 节流，避免不必要的延迟
  /// - _updateActiveIndex 内部会检查索引是否变化，避免不必要的重建
  void _onPositionChanged() {
    if (!mounted) return;

    _currentPosition = widget.positionListenable?.value ?? Duration.zero;

    // 直接调用 _updateActiveIndex，该方法内部会检查索引是否变化
    // 这种方式比 Timer(Duration.zero) 更及时，避免定位延迟
    _updateActiveIndex();
  }

  /// 预计算每行主字幕对应的副字幕文本（与 _findSecondaryText 逻辑完全一致，
  /// 仅提前计算一次并缓存，构建时直接查表，避免每次重建重复计算）。
  void _precomputeSecondaryTexts() {
    final subs = widget.subtitles;
    final result = List<String>.filled(subs.length, '');
    for (int i = 0; i < subs.length; i++) {
      result[i] = _findSecondaryText(subs[i].startTime);
    }
    _secondaryTexts = result;
  }

  @override
  void didUpdateWidget(covariant MusicLyricView oldWidget) {
    super.didUpdateWidget(oldWidget);

    // 检查 subtitles 是否真正变化（不仅比较引用，还比较内容）
    // 避免调节字号等操作时，因引用变化导致误重置用户滚动状态
    if (oldWidget.subtitles != widget.subtitles ||
        oldWidget.secondarySubtitles != widget.secondarySubtitles) {
      final contentChanged =
          _isSubtitlesContentChanged(oldWidget.subtitles, widget.subtitles) ||
          _isSubtitlesContentChanged(
            oldWidget.secondarySubtitles,
            widget.secondarySubtitles,
          );

      if (contentChanged) {
        _contentAnimationController.value = 0;
        _resetWindowsLineKeys();
        _precomputeSecondaryTexts();
        _activeIndex = -1;
        _tappedIndex = -1;
        _alacLatchedTapIndex = null;
        _pressedIndex = -1;
        _isUserScrolling = false;
        _resumeTimer?.cancel();
        _windowsTapTransactionTimeout?.cancel();
        _windowsTapTransactionTimeout = null;
        _windowsTapScrollCompleted = false;
        _windowsTapSeekAcknowledged = false;
        _directTapScrollTarget = null;
        _directTapRequestId++;
        // 字幕数据集变化（含从空到非空、异步加载完成），需要重新做一次初始定位
        _initialLocateDone = false;
        _scheduleLocateAndReveal();
      }
      // 如果内容没变，只是引用变化，则不重置用户滚动状态
    }

    // 处理 positionListenable 变化（父组件传入不同的 listenable 时）
    if (oldWidget.positionListenable != widget.positionListenable) {
      oldWidget.positionListenable?.removeListener(_onPositionChanged);
      widget.positionListenable?.addListener(_onPositionChanged);
      _currentPosition = widget.positionListenable?.value ?? Duration.zero;
      _updateActiveIndex(animate: false);
    }
    if (oldWidget.positionController != widget.positionController) {
      oldWidget.positionController?.removeListener(_onExplicitLocateRequested);
      widget.positionController?.addListener(_onExplicitLocateRequested);
    }
    if (oldWidget.stabilizeAlacDirectSeek != widget.stabilizeAlacDirectSeek ||
        oldWidget.isPlaying != widget.isPlaying) {
      if (!widget.stabilizeAlacDirectSeek) _alacLatchedTapIndex = null;
      _updateActiveIndex(animate: false);
    }
  }

  void _resetWindowsLineKeys() {
    _windowsLineKeys = List<GlobalKey>.generate(
      widget.subtitles.length,
      (index) => GlobalKey(debugLabel: 'windows-music-lyric-$index'),
      growable: false,
    );
  }

  /// 检查字幕列表内容是否真正变化
  bool _isSubtitlesContentChanged(
    List<SubtitleItem> oldSubs,
    List<SubtitleItem> newSubs,
  ) {
    if (oldSubs.length != newSubs.length) return true;
    for (int i = 0; i < oldSubs.length; i++) {
      if (oldSubs[i].startTime != newSubs[i].startTime ||
          oldSubs[i].text != newSubs[i].text) {
        return true;
      }
    }
    return false;
  }

  void _scheduleLocateAndReveal() {
    final requestId = ++_locateRevealRequestId;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_disposed ||
          !mounted ||
          requestId != _locateRevealRequestId ||
          widget.subtitles.isEmpty) {
        return;
      }

      // Read the clock again after the subtitle list has committed. During an
      // episode hand-off it may have changed between widget construction and
      // the first laid-out frame.
      _currentPosition = widget.positionListenable?.value ?? _currentPosition;
      _updateActiveIndex(animate: false);
      await _performInitialLocate();
      if (_disposed || !mounted || requestId != _locateRevealRequestId) return;
      _contentAnimationController.forward(from: 0);
    });
  }

  /// 二分查找当前进度对应的歌词行索引
  int _findActiveIndex(Duration position) {
    final subs = widget.subtitles;
    if (subs.isEmpty || position < subs.first.startTime) return -1;
    int left = 0;
    int right = subs.length - 1;
    int result = -1;
    while (left <= right) {
      final mid = left + ((right - left) >> 1);
      if (position < subs[mid].startTime) {
        right = mid - 1;
      } else {
        result = mid;
        left = mid + 1;
      }
    }
    return result;
  }

  int _findDisplayActiveIndex(Duration position) {
    final normalIndex = _findActiveIndex(position);
    final latchedIndex = _alacLatchedTapIndex;
    if (!widget.stabilizeAlacDirectSeek ||
        latchedIndex == null ||
        latchedIndex < 0 ||
        latchedIndex >= widget.subtitles.length) {
      return normalIndex;
    }

    final targetMs = widget.subtitles[latchedIndex].startTime.inMilliseconds;
    final positionMs = position.inMilliseconds;
    final deltaMs = positionMs - targetMs;
    if (deltaMs.abs() > _alacSeekBoundaryToleranceMs) {
      _alacLatchedTapIndex = null;
      return normalIndex;
    }

    // While paused, the row the user chose remains authoritative throughout
    // the same tolerance that the playback service accepts for native ALAC
    // seek verification. Once playback advances across the requested boundary,
    // the ordinary timeline owns highlighting again.
    if (!widget.isPlaying || deltaMs < 0) return latchedIndex;
    _alacLatchedTapIndex = null;
    return normalIndex;
  }

  void _updateActiveIndex({bool animate = true}) {
    if (!mounted || widget.subtitles.isEmpty) return;

    final newIndex = _findDisplayActiveIndex(_currentPosition);
    final isWindowsTapTransaction =
        Theme.of(context).platform == TargetPlatform.windows &&
        _directTapScrollTarget != null;
    if (isWindowsTapTransaction && newIndex == _directTapScrollTarget) {
      _windowsTapSeekAcknowledged = true;
    }
    if (newIndex != _activeIndex) {
      // 判断是否为大幅度跳转
      final jumpDistance = (newIndex - _activeIndex).abs();
      final isLargeJump = jumpDistance > _largeJumpThreshold;

      // setState 触发所有行重新计算透明度（Apple Music 淡入淡出效果）
      setState(() {
        _activeIndex = newIndex;
        // 当播放进度追上点击行时，清除点击高亮
        if (_tappedIndex >= 0 && newIndex >= _tappedIndex) {
          _tappedIndex = -1;
        }
        // 记录跳转类型，供 AnimatedOpacity 使用
        _isLargeJump = isLargeJump;
      });
      final directTapOwnsScroll = isWindowsTapTransaction
          ? true
          : _directTapScrollTarget == newIndex;
      final explicitLocateOwnsScroll = _explicitLocateActiveIndex == newIndex;
      if (!_isUserScrolling &&
          !directTapOwnsScroll &&
          !explicitLocateOwnsScroll) {
        _scrollToIndex(
          _scrollTargetForActiveIndex(newIndex),
          animate: animate,
          isLargeJump: isLargeJump,
        );
      }

      // 动画完成后重置 _isLargeJump 标志
      // 使用动画时长 + 缓冲时间
      final resetDelay = isLargeJump
          ? _jumpOpacityDuration + 50
          : _normalOpacityDuration + 50;
      Future.delayed(Duration(milliseconds: resetDelay), () {
        if (mounted && _isLargeJump == isLargeJump) {
          setState(() {
            _isLargeJump = false;
          });
        }
      });
    } else {
      // 索引没变，但可能需要更新 _tappedIndex 和 _isLargeJump
      // 优化：只在需要时才 setState
      bool needUpdate = false;

      if (_tappedIndex >= 0 && newIndex >= _tappedIndex) {
        _tappedIndex = -1;
        needUpdate = true;
      }

      if (_isLargeJump) {
        _isLargeJump = false;
        needUpdate = true;
      }

      if (needUpdate && mounted) {
        setState(() {});
      }
    }
    if (isWindowsTapTransaction) {
      _completeWindowsTapTransactionIfReady(_directTapRequestId);
    }
  }

  /// 是否为大幅度跳转（用于控制动画速度）
  bool _isLargeJump = false;

  /// 将指定行滚动到锚点位置（视口 30%）
  ///
  /// Apple Music 风格：优雅的滚动动画，支持正常播放和大幅度跳转两种模式
  Future<void> _scrollToIndex(
    int index, {
    bool animate = true,
    bool isLargeJump = false,
    bool isDirectTap = false,
    int? directTapDistance,
  }) async {
    if (!mounted || index < 0 || index >= widget.subtitles.length) return;
    final requestId = ++_scrollRequestId;
    final isWindows = Theme.of(context).platform == TargetPlatform.windows;
    final windowsTargetContext = isWindows && index < _windowsLineKeys.length
        ? _windowsLineKeys[index].currentContext
        : null;
    final controllerIsReady = isWindows
        ? _windowsScrollController.hasClients && windowsTargetContext != null
        : _itemScrollController.isAttached;
    if (!controllerIsReady) {
      final attachedCompleter = Completer<void>();
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!_disposed && mounted && requestId == _scrollRequestId) {
          await _scrollToIndex(
            index,
            animate: animate,
            isLargeJump: isLargeJump,
            isDirectTap: isDirectTap,
            directTapDistance: directTapDistance,
          );
        }
        if (!attachedCompleter.isCompleted) attachedCompleter.complete();
      });
      return attachedCompleter.future;
    }

    _isProgrammaticScroll = true;
    _scrollAnimationInFlight = true;
    final tapDistance = directTapDistance ?? (index - _activeIndex).abs();
    final tapDurationMs = musicLyricTapScrollDurationMs(tapDistance);
    final duration = !animate
        ? Duration.zero
        : isDirectTap
        ? Duration(milliseconds: tapDurationMs)
        : isLargeJump
        ? const Duration(milliseconds: _jumpScrollDuration)
        : const Duration(milliseconds: _normalScrollDuration);
    final curve = isDirectTap
        ? musicLyricTapScrollCurve
        : isLargeJump
        ? Curves.easeInOutCubic
        : const Cubic(0.25, 0.8, 0.25, 1);
    try {
      if (isWindows) {
        // Windows deliberately uses one ordinary viewport. The same render
        // object supplies both the animated destination and the settled
        // layout, so completing an animation cannot swap in a second list
        // with a slightly different measured offset.
        await _scrollWindowsLineToAnchor(
          targetContext: windowsTargetContext!,
          duration: duration,
          curve: curve,
        );
      } else if (animate) {
        await _itemScrollController.scrollTo(
          index: index,
          alignment: widget.anchorFraction,
          duration: duration,
          curve: curve,
        );
      } else {
        _itemScrollController.jumpTo(
          index: index,
          alignment: widget.anchorFraction,
        );
      }
    } catch (_) {
      // A replacement scroll intentionally cancels the previous transition.
    } finally {
      if (requestId == _scrollRequestId && !_disposed && mounted) {
        _scrollAnimationInFlight = false;
        // 延迟重置标志位，确保滚动动画完全结束，避免 NotificationListener 误判
        // 延迟时间略长于滚动动画，确保所有可能的 ScrollNotification 都已处理完毕
        final resetDelay = animate ? 120 : 50;
        _programmaticScrollResetTimer?.cancel();
        _programmaticScrollResetTimer = Timer(
          Duration(milliseconds: resetDelay),
          () {
            if (mounted && !_disposed) {
              _isProgrammaticScroll = false;
            }
          },
        );
      }
    }
  }

  Future<void> _scrollWindowsLineToAnchor({
    required BuildContext targetContext,
    required Duration duration,
    required Curve curve,
  }) async {
    final targetObject = targetContext.findRenderObject();
    final scrollable = Scrollable.maybeOf(targetContext);
    final scrollableObject = scrollable?.context.findRenderObject();
    if (targetObject is! RenderBox ||
        scrollableObject is! RenderBox ||
        scrollable == null ||
        !scrollable.position.hasPixels) {
      return;
    }

    // Scrollable.ensureVisible aligns the whole row rectangle; because every
    // lyric includes a stanza gap, that places its top above the requested
    // anchor. Align the row's leading edge instead, matching the mobile list.
    final rowTop = scrollableObject
        .globalToLocal(targetObject.localToGlobal(Offset.zero))
        .dy;
    final position = scrollable.position;
    final destination =
        (position.pixels +
                rowTop -
                position.viewportDimension * widget.anchorFraction)
            .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((destination - position.pixels).abs() <= 0.01) return;
    if (duration == Duration.zero) {
      position.jumpTo(destination);
      return;
    }
    await position.animateTo(destination, duration: duration, curve: curve);
  }

  /// 点击某行：立即 seek + 立即滚动到该行
  void _handleTapLine(int index, {int? deferScrollUntilPointerUp}) {
    if (index < 0 || index >= widget.subtitles.length) return;
    final sub = widget.subtitles[index];
    final tapDistance = (index - _activeIndex).abs();
    final isWindowsDirectTap =
        Theme.of(context).platform == TargetPlatform.windows;
    widget.onDirectLyricTap?.call();
    setState(() {
      _tappedIndex = index;
      _alacLatchedTapIndex = widget.stabilizeAlacDirectSeek ? index : null;
      _isUserScrolling = false;
      _isTappingLine = true; // ✅ 标记正在执行点击跳转
    });
    _resumeTimer?.cancel();
    _tapGuardResetTimer?.cancel();
    _directTapScrollTarget = index;
    final tapRequestId = ++_directTapRequestId;
    if (isWindowsDirectTap) {
      _windowsTapScrollCompleted = false;
      _windowsTapSeekAcknowledged =
          widget.positionListenable == null || _activeIndex == index;
      _windowsTapTransactionTimeout?.cancel();
      _windowsTapTransactionTimeout = Timer(const Duration(seconds: 3), () {
        if (_disposed || !mounted || tapRequestId != _directTapRequestId) {
          return;
        }
        _finishWindowsTapTransaction(tapRequestId);
      });
    }
    // ✅ 点击歌词时不再通知父组件显示控件，避免干扰原有的显隐状态
    // widget.onScrollDirectionChanged?.call(-1);
    _dispatchSeek(sub.startTime);

    void startScroll() {
      if (_disposed || !mounted || tapRequestId != _directTapRequestId) return;

      final scrollFuture = _scrollToIndex(
        index,
        animate: true,
        isDirectTap: true,
        directTapDistance: tapDistance,
      );
      scrollFuture.then((_) {
        if (_disposed || !mounted || tapRequestId != _directTapRequestId) {
          return;
        }
        if (isWindowsDirectTap) {
          _windowsTapScrollCompleted = true;
          _completeWindowsTapTransactionIfReady(tapRequestId);
        } else {
          _directTapScrollTarget = null;
          _scheduleTapGuardRelease(tapRequestId);
        }
        // 滚动完成后延迟重置标志位，确保所有滚动通知都已处理
      });
    }

    if (deferScrollUntilPointerUp != null) {
      // ScrollablePositionedList and Flutter's Scrollable both keep processing
      // this pointer after pointer-down. Starting the replacement now lets the
      // same gesture cancel the brand-new animation. Keep the seek immediate,
      // but start positioning only after this pointer has ended.
      _deferredDirectTapPointer = deferScrollUntilPointerUp;
      _deferredDirectTapScroll = startScroll;
    } else {
      startScroll();
    }
  }

  void _completeWindowsTapTransactionIfReady(int requestId) {
    if (requestId != _directTapRequestId ||
        !_windowsTapScrollCompleted ||
        !_windowsTapSeekAcknowledged) {
      return;
    }
    _finishWindowsTapTransaction(requestId);
  }

  void _finishWindowsTapTransaction(int requestId) {
    if (requestId != _directTapRequestId) return;
    _windowsTapTransactionTimeout?.cancel();
    _windowsTapTransactionTimeout = null;
    _windowsTapScrollCompleted = false;
    _windowsTapSeekAcknowledged = false;
    _directTapScrollTarget = null;
    _scheduleTapGuardRelease(requestId);
  }

  void _scheduleTapGuardRelease(int requestId) {
    _tapGuardResetTimer?.cancel();
    _tapGuardResetTimer = Timer(const Duration(milliseconds: 100), () {
      if (mounted && !_disposed && requestId == _directTapRequestId) {
        _isTappingLine = false;
      }
    });
  }

  void _dispatchSeek(Duration position) {
    final callback = widget.onSeek;
    if (callback == null) return;

    final now = DateTime.now();
    final last = _lastSeekDispatchedAt;
    if (last == null || now.difference(last) >= _minimumSeekInterval) {
      _seekDispatchTimer?.cancel();
      _pendingSeekPosition = null;
      _lastSeekDispatchedAt = now;
      callback(position);
      return;
    }

    _pendingSeekPosition = position;
    _seekDispatchTimer?.cancel();
    final remaining = _minimumSeekInterval - now.difference(last);
    _seekDispatchTimer = Timer(remaining, () {
      if (_disposed || !mounted) return;
      final target = _pendingSeekPosition;
      _pendingSeekPosition = null;
      if (target == null) return;
      _lastSeekDispatchedAt = DateTime.now();
      widget.onSeek?.call(target);
    });
  }

  void _onExplicitLocateRequested() {
    if (_disposed || !mounted || widget.subtitles.isEmpty) return;
    final controller = widget.positionController;
    if (controller == null) return;
    _alacLatchedTapIndex = null;

    final activeIndex = _findActiveIndex(controller.position);
    final targetIndex = _scrollTargetForActiveIndex(activeIndex);
    final requestId = ++_explicitLocateRequestId;
    _explicitLocateActiveIndex = activeIndex;
    _resumeTimer?.cancel();
    _isUserScrolling = false;

    final distance = (targetIndex - _activeIndex).abs();
    _scrollToIndex(
      targetIndex,
      animate: true,
      isLargeJump: distance > _largeJumpThreshold,
    ).whenComplete(() {
      if (_disposed || !mounted || requestId != _explicitLocateRequestId) {
        return;
      }
      _explicitLocateActiveIndex = null;
    });
  }

  void _beginLinePointer(PointerDownEvent event, int index) {
    if (_lastCommittedPointer == event.pointer) return;
    if (_pendingTapPointer != null) return;
    _pendingTapPointer = event.pointer;
    _pendingTapIndex = index;
    _pendingTapOrigin = event.position;
    _handleTapDown(index);

    // During a positioned-list transition the package removes the hit-tested
    // row on this very pointer-down. Commit now so the tap cannot disappear
    // with that row; ordinary stationary lists still wait for pointer-up, which
    // preserves normal drag-to-scroll behavior.
    if (_scrollAnimationInFlight) {
      _lastCommittedPointer = event.pointer;
      _pendingTapPointer = null;
      _pendingTapIndex = null;
      _pendingTapOrigin = null;
      _releasePressedLine(index);
      _handleTapLine(index, deferScrollUntilPointerUp: event.pointer);
    }
  }

  void _handleAnimatedPointerDown(PointerDownEvent event) {
    if (!_scrollAnimationInFlight || _lastCommittedPointer == event.pointer) {
      return;
    }
    final index = _hitTestLyricIndex(event.position);
    if (index == null) return;

    _lastCommittedPointer = event.pointer;
    _cancelPendingLinePointer();
    _handleTapDown(index);
    _releasePressedLine(index);
    _handleTapLine(index, deferScrollUntilPointerUp: event.pointer);
  }

  int? _hitTestLyricIndex(Offset globalPosition) {
    final candidates = <int>[];
    for (final region in _lyricHitRegions.toList(growable: false)) {
      final box = region.renderBox;
      if (box == null || !box.attached || !box.hasSize) continue;
      final local = box.globalToLocal(globalPosition);
      final rect = Offset.zero & box.size;
      if (rect.contains(local)) {
        candidates.add(region.index);
      }
    }
    if (candidates.isEmpty) return null;

    // Long-distance positioned-list transitions temporarily render two lists.
    // Prefer the row belonging to the list nearest the latest visual target.
    final reference =
        _directTapScrollTarget ??
        (_tappedIndex >= 0 ? _tappedIndex : _activeIndex);
    candidates.sort(
      (a, b) => (a - reference).abs().compareTo((b - reference).abs()),
    );
    return candidates.first;
  }

  void _handleRootPointerMove(PointerMoveEvent event) {
    if (event.pointer != _pendingTapPointer) return;
    final origin = _pendingTapOrigin;
    if (origin != null && (event.position - origin).distance > kTouchSlop) {
      _cancelPendingLinePointer();
    }
  }

  void _handleRootPointerUp(PointerUpEvent event) {
    _startDeferredDirectTapScroll(event.pointer);
    if (event.pointer != _pendingTapPointer) return;
    final index = _pendingTapIndex;
    _pendingTapPointer = null;
    _pendingTapIndex = null;
    _pendingTapOrigin = null;
    if (index == null) return;
    _releasePressedLine(index);
    _handleTapLine(index);
  }

  void _handleRootPointerCancel(PointerCancelEvent event) {
    _startDeferredDirectTapScroll(event.pointer);
    if (event.pointer == _pendingTapPointer) _cancelPendingLinePointer();
  }

  void _startDeferredDirectTapScroll(int pointer) {
    if (_deferredDirectTapPointer != pointer) return;
    final startScroll = _deferredDirectTapScroll;
    _deferredDirectTapPointer = null;
    _deferredDirectTapScroll = null;
    if (startScroll == null) return;

    // Our stable parent listener receives pointer-up before descendants. Wait
    // until the frame boundary so every inner recognizer has fully released
    // the pointer before beginning the replacement animation.
    WidgetsBinding.instance.addPostFrameCallback((_) => startScroll());
  }

  void _cancelPendingLinePointer() {
    final index = _pendingTapIndex;
    _pendingTapPointer = null;
    _pendingTapIndex = null;
    _pendingTapOrigin = null;
    if (index != null) _releasePressedLine(index);
  }

  void _handleTapDown(int index) {
    _pressedFeedbackTimer?.cancel();
    if (!mounted || _pressedIndex == index) return;
    setState(() => _pressedIndex = index);
  }

  void _releasePressedLine(int index) {
    _pressedFeedbackTimer?.cancel();
    _pressedFeedbackTimer = Timer(const Duration(milliseconds: 90), () {
      if (!mounted || _disposed || _pressedIndex != index) return;
      setState(() => _pressedIndex = -1);
    });
  }

  Widget _wrapTapInteraction(int index, Widget child) {
    return Semantics(
      button: true,
      onTap: () => _handleTapLine(index),
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) => _beginLinePointer(event, index),
        child: child,
      ),
    );
  }

  /// Apple Music 歌词透明度算法（包含点击和悬停效果）
  ///
  /// - 当前行 (offset=0)：完全不透明
  /// - 已播放 (offset<0)：比后续歌词更快融入背景
  /// - 后续行 (offset>0)：保留阅读线索，但远处不与当前行争夺注意力
  /// - 鼠标悬停：该行透明度稍微增加（变亮）
  double _opacityForOffset(int offset, bool isTapped, bool isHovered) {
    // 点击状态：完全不透明
    if (isTapped) return 1.0;

    // 当前行：完全不透明
    if (offset == 0) return 1.0;

    // 计算基础透明度
    double opacity;

    if (offset < 0) {
      // 已播放歌词更快淡出，尤其是 Header 后方的旧歌词。
      final distance = -offset; // 距离当前行的行数
      if (distance == 1) {
        opacity = 0.30;
      } else if (distance == 2) {
        opacity = 0.18;
      } else {
        opacity = 0.10;
      }
    } else {
      // 后续歌词稍亮于已播放歌词，仍可提前浏览。
      if (offset == 1) {
        opacity = 0.34;
      } else if (offset == 2) {
        opacity = 0.23;
      } else {
        opacity = 0.14;
      }
    }

    // 鼠标悬停效果：透明度稍微增加（变亮）
    // Apple Music 效果：悬停时透明度增加 0.15（微妙的变化）
    if (isHovered) {
      opacity = (opacity + 0.15).clamp(0.0, 1.0);
    }

    return opacity;
  }

  @override
  void dispose() {
    _disposed = true;
    _resumeTimer?.cancel();
    _programmaticScrollResetTimer?.cancel();
    _tapGuardResetTimer?.cancel();
    _windowsTapTransactionTimeout?.cancel();
    _seekDispatchTimer?.cancel();
    _pressedFeedbackTimer?.cancel();
    widget.positionListenable?.removeListener(_onPositionChanged);
    widget.positionController?.removeListener(_onExplicitLocateRequested);
    _windowsScrollController.dispose();
    _contentAnimationController.dispose();
    super.dispose();
  }

  /// 暴露给外部的滚动方法：滚动到当前播放位置的字幕
  ///
  /// 用于全屏切换后自动定位到当前字幕，
  /// 也可以在其他需要刷新定位的场景下调用。
  /// [animate] 控制是否有动画，默认有动画。
  void scrollToCurrentIndex({bool animate = true}) {
    if (!mounted || widget.subtitles.isEmpty) return;
    final currentIndex = _findActiveIndex(_currentPosition);
    _scrollToIndex(
      _scrollTargetForActiveIndex(currentIndex),
      animate: animate,
      isLargeJump: true,
    );
  }

  int _scrollTargetForActiveIndex(int activeIndex) {
    if (activeIndex >= 0) return activeIndex;
    return widget.subtitles.isEmpty ? -1 : 0;
  }

  /// 进入页面（或字幕首次就绪）时，把歌词滚动到当前播放位置对应的行。
  ///
  /// 与 [scrollToCurrentIndex] 的区别：本方法会忽略「索引是否变化」的判断，
  /// 即使当前行就是初始的第 0 行（例如视频一直暂停在 0 秒）也会强制把该行
  /// 滚动到锚点（视口约 30%）位置，而不是停留在自然滚动位置（顶部）。
  /// 同时保证在「视频从未播放」的场景下也能完成一次自动定位。
  /// 仅在尚未完成过初始定位时执行一次，避免干扰用户后续的手动滚动。
  Future<void> _performInitialLocate() async {
    if (!mounted || widget.subtitles.isEmpty) return;
    if (_initialLocateDone) return;
    _initialLocateDone = true;
    final index = _findActiveIndex(_currentPosition);
    await _scrollToIndex(
      _scrollTargetForActiveIndex(index),
      animate: false,
      isLargeJump: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width; // ✅ 获取屏幕宽度用于计算边距
    // 统一字号：Apple Music 风格 — 不改变字号，只改变透明度（亮度）
    // 原文（英文）：4.5vh，clamp 20~44；lyricFontSizeScale 控制缩放（1.0=默认中等偏大）
    final engFontSize = (screenHeight * 0.045 * widget.lyricFontSizeScale)
        .clamp(20.0, 44.0);
    // 翻译（中文）：约为原文的 0.48 倍（相对比例不变）
    final zhFontSize = (engFontSize * _zhSizeRatio).clamp(12.0, 22.0);
    // 段落间距（组间）：4.5vh，clamp 16~32
    final stanzaGap = (screenHeight * _stanzaGapRatio).clamp(16.0, 32.0);
    // 中英文间距（行内）：1vh，clamp 4~10
    final engZhGap = (screenHeight * _engZhGapRatio).clamp(4.0, 10.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportHeight = constraints.maxHeight;
        // 顶/底内边距：让首/末行也能滚动到锚点位置
        final topPadding = viewportHeight * widget.anchorFraction;
        final bottomPadding = viewportHeight * (1.0 - widget.anchorFraction);

        final scrollContent = _buildScrollContent(
          screenWidth: screenWidth,
          engFontSize: engFontSize,
          zhFontSize: zhFontSize,
          stanzaGap: stanzaGap,
          engZhGap: engZhGap,
          topPadding: topPadding,
          bottomPadding: bottomPadding,
        );

        final revealedContent = FadeTransition(
          opacity: CurvedAnimation(
            parent: _contentAnimationController,
            curve: Curves.easeOutCubic,
          ),
          child: scrollContent,
        );

        if (!widget.applyEdgeFade) return revealedContent;

        return ShaderMask(
          shaderCallback: (Rect bounds) {
            return const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0x00FFFFFF),
                Color(0xFFFFFFFF),
                Color(0xFFFFFFFF),
                Color(0x00FFFFFF),
              ],
              stops: [0.0, 0.15, 0.85, 1.0],
            ).createShader(bounds);
          },
          blendMode: BlendMode.dstIn,
          child: revealedContent,
        );
      },
    );
  }

  /// 处理 ScrollNotification，精准区分用户手动滚动与程序化滚动
  ///
  /// 核心逻辑：
  /// - 点击跳转时（_isTappingLine == true）完全忽略通知，避免误触发控件显隐
  /// - 程序化滚动（_isProgrammaticScroll == true）时完全忽略通知，避免自动跟随动画干扰控件显隐
  /// - 用户拖拽（dragDetails != null）或鼠标滚轮时记录方向并通知父组件
  /// - 滚动停止后延时恢复自动跟随
  bool _handleScrollNotification(ScrollNotification notification) {
    // ✅ 点击跳转时忽略所有通知（避免点击跳转被误判为用户手动滚动）
    if (_isTappingLine) return false;

    // 程序化滚动时忽略所有通知（自动跟随动画不应触发控件显隐）
    if (_isProgrammaticScroll) return false;

    if (notification is ScrollStartNotification) {
      // dragDetails != null 表示用户通过触摸/鼠标拖拽发起的滚动（非程序化）
      if (notification.dragDetails != null) {
        _isDragScrolling = true;
        _isUserScrolling = true;
        _resumeTimer?.cancel();
        widget.onManualScrollActivityChanged?.call(true);
      }
    }

    if (notification is ScrollUpdateNotification) {
      final scrollDelta = notification.scrollDelta ?? 0.0;
      // 仅处理用户手动滚动（拖拽或鼠标滚轮）
      if (_isUserScrolling && scrollDelta.abs() > 1.0) {
        final delta = -scrollDelta;
        // ✅ 修正方向逻辑（对标 Apple Music）：
        // delta > 0: 内容向下移动（用户向上滑/往前翻字幕）→ 显示控件（direction = 1.0）
        // delta < 0: 内容向上移动（用户向下滑/往后翻字幕）→ 隐藏控件（direction = -1.0）
        final direction = delta > 0 ? 1.0 : -1.0;
        // 仅当方向变化时才通知，避免重复回调
        if (_lastManualScrollDirection == null ||
            (direction > 0 && _lastManualScrollDirection! < 0) ||
            (direction < 0 && _lastManualScrollDirection! > 0)) {
          _lastManualScrollDirection = direction;
          widget.onScrollDirectionChanged?.call(direction);
        }
      }

      // 鼠标滚轮检测：无 dragDetails 但 offset 发生了变化（鼠标滚轮不会设置 dragDetails）
      if (!_isDragScrolling &&
          !_isProgrammaticScroll &&
          scrollDelta.abs() > 1.0) {
        if (!_isUserScrolling) {
          widget.onManualScrollActivityChanged?.call(true);
        }
        _isUserScrolling = true;
        _resumeTimer?.cancel();
        final delta = -scrollDelta;
        // ✅ 修正方向逻辑
        final direction = delta > 0 ? 1.0 : -1.0;
        _lastManualScrollDirection = direction;
        widget.onScrollDirectionChanged?.call(direction);
      }
    }

    if (notification is ScrollEndNotification) {
      if (_isUserScrolling && !_isProgrammaticScroll) {
        widget.onManualScrollActivityChanged?.call(false);
        _scheduleResumeAutoFollow();
      }
      _isDragScrolling = false;
    }

    return false; // 不阻止通知冒泡
  }

  /// 用户停止滚动后延时恢复自动跟随
  void _scheduleResumeAutoFollow() {
    _resumeTimer?.cancel();
    _resumeTimer = Timer(_autoResumeDelay, () {
      if (_disposed || !mounted) return;
      _isUserScrolling = false;
      _lastManualScrollDirection = null;
      _isDragScrolling = false;
      // 通知父组件恢复自动跟随（显示控件）
      widget.onScrollDirectionChanged?.call(null);
      _scrollToIndex(_scrollTargetForActiveIndex(_activeIndex), animate: true);
    });
  }

  Widget _buildScrollContent({
    required double screenWidth, // ✅ 屏幕宽度用于计算左右边距
    required double engFontSize,
    required double zhFontSize,
    required double stanzaGap,
    required double engZhGap,
    required double topPadding,
    required double bottomPadding,
  }) {
    final subs = widget.subtitles;
    if (subs.isEmpty) {
      return const SizedBox.shrink();
    }
    if (_windowsLineKeys.length != subs.length) {
      _resetWindowsLineKeys();
    }
    final padding = EdgeInsets.only(
      top: topPadding,
      bottom: bottomPadding,
      left: screenWidth * widget.horizontalPaddingFraction,
      right: screenWidth * widget.horizontalPaddingFraction,
    );
    const physics = BouncingScrollPhysics(
      parent: RangeMaintainingScrollPhysics(),
    );
    final isWindows = Theme.of(context).platform == TargetPlatform.windows;

    final Widget scrollView;
    if (isWindows) {
      // Windows 始终保留同一棵滚动树。动画终点和静止布局使用同一个
      // RenderViewport，避免可变高度歌词在临时列表切换时重新测量并闪动。
      scrollView = SingleChildScrollView(
        key: const ValueKey<String>('music-lyric-windows-single-scroll'),
        controller: _windowsScrollController,
        padding: padding,
        physics: physics,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: List<Widget>.generate(
            subs.length,
            (i) => KeyedSubtree(
              key: _windowsLineKeys[i],
              child: _buildLyricGroup(
                index: i,
                sub: subs[i],
                engFontSize: engFontSize,
                zhFontSize: zhFontSize,
                stanzaGap: stanzaGap,
                engZhGap: engZhGap,
              ),
            ),
            growable: false,
          ),
        ),
      );
    } else {
      scrollView = ScrollablePositionedList.builder(
        key: const ValueKey<String>('music-lyric-positioned-list'),
        itemScrollController: _itemScrollController,
        padding: padding,
        physics: physics,
        itemCount: subs.length,
        itemBuilder: (context, i) => _buildLyricGroup(
          index: i,
          sub: subs[i],
          engFontSize: engFontSize,
          zhFontSize: zhFontSize,
          stanzaGap: stanzaGap,
          engZhGap: engZhGap,
        ),
      );
    }

    // 用 NotificationListener 包裹，精准区分用户手动滚动与程序化滚动
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handleAnimatedPointerDown,
      onPointerMove: _handleRootPointerMove,
      onPointerUp: _handleRootPointerUp,
      onPointerCancel: _handleRootPointerCancel,
      child: NotificationListener<ScrollNotification>(
        onNotification: _handleScrollNotification,
        child: scrollView,
      ),
    );
  }

  /// 根据时间点查找匹配的副字幕文本
  ///
  /// 返回匹配时间点的副字幕文本，如果未找到则返回空字符串
  String _findSecondaryText(Duration startTime) {
    if (widget.secondarySubtitles.isEmpty) return '';

    // 查找与当前主字幕时间点匹配的副字幕
    // 使用二分查找提高效率
    int left = 0;
    int right = widget.secondarySubtitles.length - 1;

    while (left <= right) {
      final mid = left + ((right - left) >> 1);
      final sub = widget.secondarySubtitles[mid];

      if (startTime.inMilliseconds < sub.startTime.inMilliseconds) {
        right = mid - 1;
      } else if (startTime.inMilliseconds > sub.startTime.inMilliseconds) {
        left = mid + 1;
      } else {
        // 精确匹配
        return sub.text;
      }
    }

    // 如果未精确匹配，查找时间最接近的（允许 100ms 误差）
    for (final sub in widget.secondarySubtitles) {
      if ((sub.startTime.inMilliseconds - startTime.inMilliseconds).abs() <=
          100) {
        return sub.text;
      }
    }

    return '';
  }

  /// 构建双语歌词组（主字幕 + 副字幕）
  ///
  /// Apple Music 风格：不改变字体大小，只通过透明度和颜色区分当前行
  /// 优化：使用 RepaintBoundary 减少重绘
  Widget _buildLyricGroup({
    required int index,
    required SubtitleItem sub,
    required double engFontSize,
    required double zhFontSize,
    required double stanzaGap,
    required double engZhGap,
  }) {
    final isActive = index == _activeIndex;
    final isTapped = index == _tappedIndex;
    final isPressed = index == _pressedIndex;
    final isHovered = index == _hoveredIndex;
    final offset = index - _activeIndex;
    // Apple Music 透明度：基于与当前行的距离 + 悬停效果
    final opacity = _opacityForOffset(offset, isTapped || isPressed, isHovered);
    final highlight = isActive || isTapped;

    // 主字幕文本（原文）
    String mainText = sub.text;
    // 查找匹配的副字幕文本（翻译）— 查预计算表，O(1)，避免每次构建重复计算
    String translatedText = index < _secondaryTexts.length
        ? _secondaryTexts[index]
        : '';

    // 识别第一行为主字幕：当没有独立副字幕轨道且设置开启时，
    // 将第一行作为主字幕，其余行作为副字幕（与 video_player_screen 逻辑一致）
    if (widget.splitSubtitleByLine &&
        widget.secondarySubtitles.isEmpty &&
        mainText.contains('\n')) {
      final lines = mainText.split('\n');
      mainText = lines[0];
      translatedText = lines.sublist(1).join('\n');
    }
    final mainIsChinese = _isChineseText(mainText);
    final translationIsChinese = _isChineseText(translatedText);

    // 优化：对静态行使用 Opacity，对动态行使用 AnimatedOpacity
    // 静态行：距离当前行 > 2，透明度不变，不需要动画
    final isStaticLine = offset.abs() > 2 && !isHovered;

    // 构建歌词内容（复用）
    Widget lyricContent = Container(
      width: double.infinity,
      padding: EdgeInsets.only(bottom: stanzaGap),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: -12,
            right: -12,
            top: -8,
            bottom: -8,
            child: IgnorePointer(
              child: AnimatedScale(
                scale: isPressed ? 1.0 : 0.985,
                duration: Duration(milliseconds: isPressed ? 105 : 720),
                curve: isPressed ? Curves.easeOutCubic : Curves.easeOutBack,
                child: AnimatedOpacity(
                  key: ValueKey<String>('music-lyric-press-$index'),
                  opacity: isPressed ? 1.0 : 0.0,
                  duration: Duration(milliseconds: isPressed ? 90 : 780),
                  curve: isPressed
                      ? Curves.easeOutCubic
                      : const Cubic(0.16, 1.0, 0.30, 1.0),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Colors.white.withValues(alpha: 0.26),
                          Colors.white.withValues(alpha: 0.14),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.10),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.14),
                          blurRadius: 18,
                          offset: const Offset(0, 7),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // === 原文（自动检测语言，中文用思源黑体，其他用 Inter）— 主导视觉 ===
              MusicTextOpticalAlignment(
                applyCjkRaise: mainIsChinese,
                fontSize: engFontSize,
                child: Text(
                  mainText,
                  textAlign: TextAlign.left,
                  softWrap: true,
                  maxLines: null,
                  style: TextStyle(
                    fontFamily: mainIsChinese ? _fontFamilyZh : _fontFamilyEng,
                    fontSize: engFontSize,
                    fontWeight: mainIsChinese
                        ? FontWeight.w600
                        : FontWeight.w800,
                    color: Colors.white,
                    height: 1.3,
                    letterSpacing: -0.5,
                    leadingDistribution: mainIsChinese
                        ? TextLeadingDistribution.even
                        : null,
                  ),
                ),
              ),

              if (translatedText.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(top: engZhGap),
                  child: MusicTextOpticalAlignment(
                    applyCjkRaise: translationIsChinese,
                    fontSize: zhFontSize,
                    child: Text(
                      translatedText,
                      textAlign: TextAlign.left,
                      softWrap: true,
                      maxLines: null,
                      style: TextStyle(
                        fontFamily: _fontFamilyZh,
                        fontSize: zhFontSize,
                        fontWeight: translationIsChinese
                            ? FontWeight.w600
                            : FontWeight.w800,
                        color: Colors.white.withValues(
                          alpha: highlight ? 0.70 : 0.50,
                        ),
                        height: 1.5,
                        leadingDistribution: translationIsChinese
                            ? TextLeadingDistribution.even
                            : null,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );

    // 优化：静态行使用 Opacity，动态行使用 AnimatedOpacity
    Widget opacityWrapper;
    if (isStaticLine) {
      // 静态行：透明度不变，不需要动画
      opacityWrapper = Opacity(opacity: opacity, child: lyricContent);
    } else {
      // 动态行：透明度可能变化，使用动画
      opacityWrapper = AnimatedOpacity(
        key: ValueKey<String>('music-lyric-row-opacity-$index'),
        opacity: opacity,
        // Apple Music 风格：根据跳转类型使用不同的动画时长
        duration: Duration(
          milliseconds: _isLargeJump
              ? _jumpOpacityDuration
              : _normalOpacityDuration,
        ),
        curve: _isLargeJump
            ? Curves.easeInOutCubic
            : const Cubic(0.25, 0.8, 0.25, 1),
        child: lyricContent,
      );
    }

    // 优化：只对动态行使用 RepaintBoundary
    // 静态行不需要独立重绘边界
    Widget repaintWrapper;
    if (isStaticLine) {
      repaintWrapper = opacityWrapper;
    } else {
      repaintWrapper = RepaintBoundary(child: opacityWrapper);
    }

    final feedbackWrapper = AnimatedScale(
      key: ValueKey<String>('music-lyric-row-scale-$index'),
      scale: isPressed ? 0.982 : 1.0,
      duration: Duration(milliseconds: isPressed ? 105 : 680),
      curve: isPressed ? Curves.easeOutCubic : Curves.easeOutBack,
      alignment: Alignment.centerLeft,
      child: repaintWrapper,
    );

    // 优化：只对动态行监听鼠标事件（移动端不启用 MouseRegion）
    Widget interactiveRow;
    if (isStaticLine) {
      // 静态行：不需要鼠标事件监听
      interactiveRow = _wrapTapInteraction(index, feedbackWrapper);
    } else {
      // 动态行：需要鼠标事件监听（只在桌面端启用）
      interactiveRow = MouseRegion(
        onEnter: (_) {
          // 鼠标进入：更新悬停索引
          if (mounted) {
            setState(() {
              _hoveredIndex = index;
            });
          }
        },
        onExit: (_) {
          // 鼠标离开：只有当离开的行是当前悬停的行时，才清除
          Future.delayed(const Duration(milliseconds: 50), () {
            if (_hoveredIndex == index && mounted) {
              setState(() {
                _hoveredIndex = -1;
              });
            }
          });
        },
        child: _wrapTapInteraction(index, feedbackWrapper),
      );
    }

    return _LyricHitRegion(
      index: index,
      onAttach: _lyricHitRegions.add,
      onDetach: _lyricHitRegions.remove,
      child: interactiveRow,
    );
  }
}

class _LyricHitRegion extends StatefulWidget {
  final int index;
  final ValueChanged<_LyricHitRegionState> onAttach;
  final ValueChanged<_LyricHitRegionState> onDetach;
  final Widget child;

  const _LyricHitRegion({
    required this.index,
    required this.onAttach,
    required this.onDetach,
    required this.child,
  });

  @override
  State<_LyricHitRegion> createState() => _LyricHitRegionState();
}

class _LyricHitRegionState extends State<_LyricHitRegion> {
  int get index => widget.index;

  RenderBox? get renderBox {
    final renderObject = context.findRenderObject();
    return renderObject is RenderBox ? renderObject : null;
  }

  @override
  void initState() {
    super.initState();
    widget.onAttach(this);
  }

  @override
  void didUpdateWidget(covariant _LyricHitRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onAttach != widget.onAttach ||
        oldWidget.onDetach != widget.onDetach) {
      oldWidget.onDetach(this);
      widget.onAttach(this);
    }
  }

  @override
  void dispose() {
    widget.onDetach(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
