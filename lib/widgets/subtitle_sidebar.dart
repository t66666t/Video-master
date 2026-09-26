import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:video_player/video_player.dart';
import '../services/settings_service.dart';
import '../services/subtitle_timeline_resolver.dart';
import '../models/subtitle_copy_format.dart';
import '../models/subtitle_model.dart';
import '../utils/subtitle_copy_formatter.dart';
import '../utils/subtitle_display_resolver.dart';
import 'subtitle_copy_format_popover.dart';
import '../features/subtitle_article/article_document.dart';
import '../features/subtitle_article/article_layout_engine.dart';
import '../features/subtitle_article/article_layout_model.dart';
import '../features/subtitle_article/continuous_article_view.dart';

class SubtitleSidebar extends StatefulWidget {
  final List<SubtitleItem> subtitles;
  final List<SubtitleItem> secondarySubtitles; // New
  /// The player is intentionally optional: subtitle text and settings remain
  /// usable while the native media backend is still creating its controller.
  final VideoPlayerController? controller;

  /// A controller-independent playback clock. Playback pages pass the global
  /// media clock so the sidebar can keep its position across controller swaps.
  final ValueListenable<Duration>? positionListenable;
  final ValueChanged<Duration>? onItemTap;
  final VoidCallback? onClose;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onLoadSubtitle;
  final VoidCallback? onOpenSubtitleStyle;
  final VoidCallback? onOpenSubtitleManager;
  final VoidCallback? onClearSelection;
  final VoidCallback? onScanEmbeddedSubtitles;
  final VoidCallback? onOpenEpisodePicker;
  final VoidCallback? onOpenVideoCompose;
  final VoidCallback? onOpenOcrSubtitle;
  final VoidCallback? onOpenSubtitleEditor;
  final bool isCompact;
  final bool isPortrait;

  /// 与画面字幕一致：音频/视频各自使用独立的「连续字幕」设置。
  final bool isAudio;
  final FocusNode? focusNode; // New
  final bool isVisible;
  final bool showEmbeddedLoadingMessage;

  const SubtitleSidebar({
    super.key,
    required this.subtitles,
    this.secondarySubtitles = const [], // Default empty
    this.controller,
    this.positionListenable,
    this.onItemTap,
    this.onClose,
    this.onOpenSettings,
    this.onLoadSubtitle,
    this.onOpenSubtitleStyle,
    this.onOpenSubtitleManager,
    this.onClearSelection,
    this.onScanEmbeddedSubtitles,
    this.onOpenEpisodePicker,
    this.onOpenVideoCompose,
    this.onOpenOcrSubtitle,
    this.onOpenSubtitleEditor,
    this.isCompact = false,
    this.isPortrait = false,
    this.isAudio = false,
    this.focusNode,
    this.isVisible = true,
    this.showEmbeddedLoadingMessage = false,
  });

  @override
  State<SubtitleSidebar> createState() => SubtitleSidebarState();
}

class SubtitleSidebarState extends State<SubtitleSidebar> {
  bool _isArticleMode = false; // 默认为列表模式
  int _lineFilterMode = 0; // 0: 全部, 1: 第一行, 2: 第二行
  // bool _isAutoScroll = false; // Moved to SettingsService
  double _fontSizeScale = 1.0; // 字体缩放比例
  bool _showFontSettings = false; // 是否显示字体设置
  bool _showTimestamps = true;
  double _timeColumnRatio = 0.18;
  int _locatePositionPercent = 30;

  /// 最近一次「点击字幕后滚到该句」的目标索引；关闭自动跟随时为 null。
  @visibleForTesting
  int? lastTappedLocateScrollIndex;

  // 滚动控制器
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener =
      ItemPositionsListener.create();
  final ScrollOffsetController _listScrollOffsetController =
      ScrollOffsetController();
  final ScrollOffsetController _articleScrollOffsetController =
      ScrollOffsetController();
  final GlobalKey<SelectionAreaState> _textSelectionKey =
      GlobalKey<SelectionAreaState>();
  final FocusNode _textSelectionFocusNode = FocusNode(
    debugLabel: 'SubtitleSidebarTextSelection',
  );
  bool _hasTextSelection = false;
  String _selectedTranscriptText = '';

  /// True after Ctrl/Cmd+A or the menu's Select all. Flutter's selectAll only
  /// covers currently mounted virtualized rows; copy/format then uses the
  /// canonical cache instead of that partial `plainText`.
  bool _fullTranscriptSelected = false;
  Timer? _touchSelectionEdgeScrollTimer;
  int? _touchSelectionEdgePointer;
  bool _selectionViewportCorrectionInFlight = false;
  ScrollableState? _selectionScrollable;
  OverlayEntry? _persistentSelectionToolbarEntry;
  bool _persistentSelectionToolbarInsertScheduled = false;
  bool _usesPersistentTouchSelectionToolbar = false;
  Offset? _persistentSelectionToolbarAnchor;
  TextSelectionToolbarAnchors? _persistentSelectionToolbarAnchors;
  OverlayEntry? _desktopSelectionToolbarEntry;
  Offset? _desktopSelectionToolbarAnchor;
  OverlayEntry? _copyFormatPopoverEntry;
  Offset? _selectionShieldTapDownPosition;
  Drag? _selectionPreservingPanDrag;

  // Flutter's tap recognizer intentionally allows normal finger jitter. That
  // tolerance is too generous for a destructive "dismiss selection" action:
  // the first few pixels of an intended scroll could otherwise count as a
  // tap. Keep dismissal much stricter than kTouchSlop.
  static const double _selectionDismissTapSlop = 3;

  /// Signed pixel delta for edge auto-scroll: negative toward the start.
  double _touchSelectionEdgeScrollPixels = 0;
  int _touchSelectionEdgeTickCount = 0;

  /// Pointer currently extending the selection, either the initial long-press
  /// or a later gesture that has been confirmed by the selection-status scope.
  int? _selectionGesturePointer;
  bool _selectionGestureUsesHandle = false;
  int? _latestDownTouchPointer;
  final Set<int> _downTouchPointers = <int>{};
  final Map<int, Offset> _downTouchPointerPositions = <int, Offset>{};
  bool _selectionHandleBindCheckScheduled = false;
  SelectableRegionSelectionStatus _selectionRegionStatus =
      SelectableRegionSelectionStatus.finalized;

  /// Enter/exit hysteresis keeps a jittering finger from flipping between
  /// "hold still" and "edge scroll" on every move.
  // Start before the finger reaches the physical screen edge. On gesture-nav
  // Android devices the last few pixels may belong to the system, so requiring
  // the handle to cross the viewport boundary makes downward scrolling either
  // very slow or impossible.
  static const double _touchSelectionEdgeEnterZone = 56;

  // Hysteresis is deliberately wider than the entry band: once scrolling has
  // started, small finger movements must not repeatedly stop/restart it.
  static const double _touchSelectionEdgeExitZone = 72;
  static const Duration _touchSelectionEdgeScrollInterval = Duration(
    milliseconds: 16,
  );
  static const double _touchSelectionMinPixelsPerTick = 2;
  static const double _touchSelectionMaxPixelsPerTick = 6.5;
  static const int _touchSelectionAccelerationDelayTicks = 8;
  static const int _touchSelectionAccelerationTicks = 64;

  // 自动滚动相关
  final ValueNotifier<int> _activeIndexNotifier = ValueNotifier<int>(-1);
  final ValueNotifier<List<int>> _activeIndicesNotifier =
      ValueNotifier<List<int>>(<int>[]);
  SubtitleTimelineResolver? _timelineResolver;
  List<SubtitleItem> _timelineResolverSubtitles = const <SubtitleItem>[];
  Timer? _autoScrollTimer;
  int _activePointerCount = 0;
  bool _pointerSessionStartedWithTextSelection = false;
  bool _didScrollWhilePointerSession = false;
  int? _pointerDownStartIndex;
  int? _pointerDownSubtitleIndex;

  // ===== 拖拽会话中的「副指针双击跳转」=====
  // 背景：手指按住不放时自动跟随被抑制，用户可以一边按住一边翻阅上下文。
  // 本机制允许在这个状态下用另一根手指在某句字幕上快速点两下，立刻把媒体
  // seek 到该句，但不滚动文稿；文稿的定位统一推迟到所有手指抬起之后。
  //
  // 误判防线（缺一不可，详见 [_evaluateDragDoubleTap]）：
  //   1. 只认触摸设备，鼠标/触控笔走各自既有交互；
  //   2. 只认落在字幕列表区的指针，顶部工具栏按钮不参与，也不能充当锚点；
  //   3. 按下瞬间列表区必须已有其他手指按住，单指点击一律走原有逻辑；
  //   4. 两次轻点必须共享同一根「一直没抬起」的锚定手指，杜绝「全松手后
  //      换手再点」被误拼成双击；
  //   5. 两次轻点必须都是干净轻点（位移 < slop 且时长 < 300ms）、命中同一行、
  //      落点接近、间隔 <= 300ms。
  /// 当前按在侧边栏内的每根手指的按下快照，key 为 pointer id。
  final Map<int, _SidebarPointerRecord> _pointerRecords =
      <int, _SidebarPointerRecord>{};

  /// 落点位于字幕列表区（而非顶部工具栏）的指针 id。
  final Set<int> _listAreaPointerIds = <int>{};

  /// 列表区 [Listener] 在指针按下瞬间解析出的「pointer id → 字幕行号」。
  ///
  /// 行号只能靠几何反查，不能依赖列表内部的任何回调：
  ///   - onTapDown 不行。列表已经在滚动时，Scrollable 的 [DragGestureRecognizer]
  ///     会在新手指按下的瞬间直接赢下该指针的手势竞技场，行上的
  ///     TapGestureRecognizer 被判负，onTapDown 根本不会触发。
  ///   - 行级 Listener 也不行。拖拽期间 Scrollable 会把整个视口包进
  ///     `IgnorePointer`（`DragScrollActivity.shouldIgnorePointer == true`），
  ///     视口内部收不到任何指针事件。
  /// 而「拖着不松手」恰恰就是这两种屏蔽同时生效的状态，所以只能在视口外面，
  /// 用 [ItemPositionsListener] 的几何信息自己算落点落在哪一行。
  final Map<int, int> _pendingRowIndexByPointer = <int, int>{};

  /// 指向当前挂载的 [ScrollablePositionedList]，用于把全局坐标换算成视口比例。
  final GlobalKey _listViewportKey = GlobalKey();

  /// 文章模式下每个段落的 key，用于把落点进一步定位到段落内的具体某一句。
  final Map<int, GlobalKey<State<SubtitleArticleChunk>>> _articleChunkKeys =
      <int, GlobalKey<State<SubtitleArticleChunk>>>{};
  final GlobalKey<ContinuousArticleViewState> _continuousArticleViewKey =
      GlobalKey<ContinuousArticleViewState>();

  /// 等待凑成双击的候选轻点；超时/换会话即作废。
  _SidebarTapRecord? _pendingDragDoubleTap;

  /// 最近一根抬起的副指针记录，只存活到下一个指针事件为止。
  ///
  /// 快速轻点时手势竞技场要等抬起事件派发完才裁决，也就是说 onTap
  /// 会晚于 [_onPointerUpOrCancel]；留着这条记录，才能在那一刻认出
  /// 「这次点击已经被双击识别器接管了」。
  _SidebarPointerRecord? _recentlyLiftedSecondaryTap;

  /// 最近一次指针抬起的快照，供 [_isConfirmedSubtitleClick] 在 onTap
  /// 里核对「这是不是一次短单击」。
  ///
  /// Listener 先于手势竞技场收到 PointerUp，所以 onTap 触发时这里一定
  /// 已经写好。下一根手指按下时清空，避免串到下一次点击。
  _SidebarPointerRecord? _lastLiftedPointer;
  int _lastLiftedHeldMs = 0;

  /// 已被双击识别接管、因而必须屏蔽常规 onTap 落地的字幕行号。
  int? _suppressedRowTapIndex;

  /// 本次按压会话内是否发生过双击 seek；决定松手后是否强制补一次定位。
  bool _didDoubleTapSeekWhilePointerSession = false;

  /// 单次轻点允许的最长按住时长；超过即视为长按/拖拽，不参与双击。
  static const int _dragTapMaxDurationMs = 300;

  /// 常规「点某一句就跳转」允许的最长按住时长。
  ///
  /// 对齐 [kLongPressTimeout]：超过它就应当进入选字/长按语义，而不是单击。
  /// 比 [_dragTapMaxDurationMs] 更宽，避免把略慢的单击误杀掉。
  static const int _rowTapMaxDurationMs = 500;

  /// 两次轻点之间允许的最大间隔（第一次抬起 → 第二次按下），对齐
  /// Flutter 的 [kDoubleTapTimeout]。
  static const int _dragDoubleTapIntervalMs = 300;

  /// 单次轻点允许的最大位移，超过即认为手指在滑动而不是点击。
  static const double _dragTapMaxTravel = kDoubleTapTouchSlop;

  /// 两次轻点落点之间允许的最大距离，用于确认「是同一根手指点的」。
  /// 比 [kDoubleTapSlop] 更严，配合「同一行」判定进一步压低误判率。
  static const double _dragDoubleTapSlop = 72.0;
  int? _pendingLocateIndex;
  bool _lastKnownIsPlaying = false;
  int _lastSubtitleOffsetMs = 0;
  int? _suppressAutoScrollTargetIndex;
  int _suppressAutoScrollUntilMs = 0;
  int? _manualLocateLockIndex;
  int _manualLocateLockUntilMs = 0;
  int _autoScrollRequestId = 0;
  int _manualLocateAutoFollowCooldownUntilMs = 0;
  int? _manualAnimationFreezeIndex;
  int _manualAnimationFreezeUntilMs = 0;
  Size? _lastScrollableViewportSize;
  bool _viewportAlignmentRestoreScheduled = false;

  // 统一定位流水线。
  // 「切页后的修复定位」与「自动跟随」是两套独立触发源：过去它们各自投递
  // post-frame 任务、各自重试，于是出现两类竞争：
  //   1. 后发起的修复请求会被更早发起、但仍在重试中的旧请求覆盖落点；
  //   2. 自动跟随的动画（含远距离两段式滚动）晚于修复跳转落地，把文稿又拖
  //      回旧位置；被横屏页覆盖时动画还会被静音挂起，回到前台集中补帧。
  // 下面用单调递增的请求号把它们串成一条流水线：只有最新请求能落地，旧请求
  // 的延迟回调全部作废；修复请求必须等列表真正有布局才会执行，失败会保留
  // 请求并由视口变化/回到前台重新驱动，落地后还会校验一次列表是否真的可见。
  int _locateRequestId = 0;
  int _locateAttempts = 0;
  bool _locateAnimated = false;
  bool _locateIsRepair = false;
  bool _repairRequestPending = false;
  bool _locateVerificationScheduled = false;
  int _locateVerificationRounds = 0;

  // 侧边栏所在路由是否位于前台。被横屏播放页/音乐播放页覆盖时，列表既不
  // 布局也不走帧，此期间启动的滚动动画会和切页修复定位抢同一个落点。
  bool _isHostRouteCurrent = true;
  bool _routeRestorePending = false;

  static const int _maxLocateAttempts = 30;
  static const int _maxLocateVerificationRounds = 3;
  static const double _collapsedViewportHeight = 4.0;

  VideoPlayerValue? get _controllerValue => widget.controller?.value;

  /// 高亮/定位用播放器真实位置，与画面字幕 [_updateSubtitle] 保持一致。
  ///
  /// [positionListenable] 是每帧插值的平滑时钟，可能略超前 native
  /// position；若用它判定当前句，文稿高亮会比实际听到的内容提前切换。
  /// positionListenable 仅在 controller 尚未就绪时作为回退。
  Duration get _subtitleTimingPosition {
    final controller = widget.controller;
    if (controller != null && controller.value.isInitialized) {
      return controller.value.position;
    }
    return widget.positionListenable?.value ?? Duration.zero;
  }

  /// 字幕延迟（subtitleOffset）：正值表示字幕整体延后出现。
  int get _subtitleOffsetMs => SettingsService().subtitleOffset.inMilliseconds;

  /// 画面字幕用「播放位置 - subtitleOffset」判定当前句，侧边栏的高亮与
  /// 定位必须换算到同一条字幕时间轴，否则调整「字幕同步」后两侧会整体
  /// 错开（offset > 0 时高亮比画面字幕提前）。
  int get _subtitleTimelinePositionMs =>
      _subtitleTimingPosition.inMilliseconds - _subtitleOffsetMs;

  bool get _playbackIsPlaying => _controllerValue?.isPlaying ?? false;

  void _attachPlaybackListeners() {
    widget.controller?.addListener(_updateIndex);
    widget.positionListenable?.addListener(_updateIndex);
  }

  void _detachPlaybackListeners(SubtitleSidebar source) {
    source.controller?.removeListener(_updateIndex);
    source.positionListenable?.removeListener(_updateIndex);
  }

  bool get _hasAnyActivePointer => _activePointerCount > 0;

  bool _shouldSuppressAutoScrollForIndex(int index) {
    if (_suppressAutoScrollTargetIndex == null) return false;
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs > _suppressAutoScrollUntilMs) {
      _suppressAutoScrollTargetIndex = null;
      _suppressAutoScrollUntilMs = 0;
      return false;
    }
    return _suppressAutoScrollTargetIndex == index;
  }

  void _markAutoScrollSuppressedForIndex(int index) {
    _suppressAutoScrollTargetIndex = index;
    _suppressAutoScrollUntilMs = DateTime.now().millisecondsSinceEpoch + 900;
  }

  void _clearAutoScrollSuppression() {
    _suppressAutoScrollTargetIndex = null;
    _suppressAutoScrollUntilMs = 0;
  }

  bool _hasManualLocateLock(int nowMs) {
    final int? index = _manualLocateLockIndex;
    if (index == null) return false;
    if (nowMs > _manualLocateLockUntilMs) {
      _manualLocateLockIndex = null;
      _manualLocateLockUntilMs = 0;
      return false;
    }
    return true;
  }

  void _markManualLocateLock(int index) {
    _manualLocateLockIndex = index;
    _manualLocateLockUntilMs = DateTime.now().millisecondsSinceEpoch + 1200;
  }

  void _clearManualLocateLock() {
    _manualLocateLockIndex = null;
    _manualLocateLockUntilMs = 0;
  }

  void _cancelPendingAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _autoScrollRequestId++;
  }

  void _markManualLocateAutoFollowCooldown() {
    _manualLocateAutoFollowCooldownUntilMs =
        DateTime.now().millisecondsSinceEpoch + 700;
  }

  bool _isInManualLocateAutoFollowCooldown(int nowMs) {
    return nowMs <= _manualLocateAutoFollowCooldownUntilMs;
  }

  void _markManualAnimationFreeze(int index, {required bool animated}) {
    if (!animated) {
      _manualAnimationFreezeIndex = null;
      _manualAnimationFreezeUntilMs = 0;
      return;
    }
    _manualAnimationFreezeIndex = index;
    _manualAnimationFreezeUntilMs = DateTime.now().millisecondsSinceEpoch + 280;
  }

  bool _hasManualAnimationFreeze(int nowMs) {
    final int? index = _manualAnimationFreezeIndex;
    if (index == null) return false;
    if (nowMs > _manualAnimationFreezeUntilMs) {
      _manualAnimationFreezeIndex = null;
      _manualAnimationFreezeUntilMs = 0;
      return false;
    }
    return true;
  }

  // Article Mode Scroll Controller
  static const int _minArticleChunkSize = 1;
  static const int _maxArticleChunkSize = 99;
  int _articleChunkSize = 4;
  bool _articleParagraphModeEnabled = true;
  final ItemScrollController _articleItemScrollController =
      ItemScrollController();
  final ItemPositionsListener _articleItemPositionsListener =
      ItemPositionsListener.create();

  // Cached matches to avoid O(N^2) or repeated searches
  // Key: Primary Index, Value: Secondary Text
  final Map<int, String> _secondaryTextCache = {};
  final Map<int, int> _primaryToSecondaryIndexCache = {};
  final Map<int, int> _secondaryToPrimaryIndexCache = {};
  final List<String> _selectionTextCache = <String>[];
  final List<SubtitleCueCopyParts> _cueCopyPartsCache =
      <SubtitleCueCopyParts>[];
  bool _isBilingualMode = false;
  int _articleDocumentGeneration = 0;
  ArticleDocument? _continuousArticleDocument;
  ArticleLayout? _continuousArticleLayout;
  ArticleLayoutKey? _continuousArticleLayoutKey;
  Future<ArticleLayout?>? _continuousArticleLayoutFuture;
  ArticleLayoutKey? _continuousArticlePendingKey;
  int _continuousArticleLayoutRequestId = 0;

  bool get _isContinuousArticleMode =>
      _isArticleMode && !_articleParagraphModeEnabled;

  void _invalidateContinuousArticleLayout() {
    _continuousArticleLayoutRequestId++;
    _continuousArticleLayout = null;
    _continuousArticleLayoutKey = null;
    _continuousArticleLayoutFuture = null;
    _continuousArticlePendingKey = null;
  }

  // Cached display subtitles to avoid repeated computation
  late List<SubtitleItem> _cachedDisplaySubtitles;

  void _invalidateDisplaySubtitlesCache() {
    _cachedDisplaySubtitles = resolveSubtitleDisplaySelection(
      lineFilterMode: _lineFilterMode,
      primarySubtitles: widget.subtitles,
      secondarySubtitles: widget.secondarySubtitles,
    ).subtitles;
  }

  List<SubtitleItem> get _displaySubtitles => _cachedDisplaySubtitles;

  bool get _usesSecondaryTrackForDisplay =>
      _lineFilterMode == 2 && widget.secondarySubtitles.isNotEmpty;

  double _clampFontSizeScale(double value) {
    return value.clamp(0.5, 3.0).toDouble();
  }

  double _clampTimeColumnRatio(double value) {
    return value.clamp(0.05, 0.30).toDouble();
  }

  int _clampLocatePositionPercent(int value) {
    return value.clamp(0, 100);
  }

  double get _locateAlignment => _locatePositionPercent / 100.0;

  void _loadOrientationDisplaySettings() {
    final settings = SettingsService();
    if (widget.isPortrait) {
      _fontSizeScale = _clampFontSizeScale(
        settings.portraitSidebarFontSizeScale,
      );
      _showTimestamps = settings.portraitSidebarShowTimestamps;
      _timeColumnRatio = _clampTimeColumnRatio(
        settings.portraitSidebarTimeColumnRatio,
      );
      _locatePositionPercent = _clampLocatePositionPercent(
        settings.portraitSidebarLocatePositionPercent,
      );
    } else {
      _fontSizeScale = _clampFontSizeScale(
        settings.landscapeSidebarFontSizeScale,
      );
      _showTimestamps = settings.landscapeSidebarShowTimestamps;
      _timeColumnRatio = _clampTimeColumnRatio(
        settings.landscapeSidebarTimeColumnRatio,
      );
      _locatePositionPercent = _clampLocatePositionPercent(
        settings.landscapeSidebarLocatePositionPercent,
      );
    }
  }

  @override
  void initState() {
    super.initState();
    // Load persisted settings
    final settings = SettingsService();
    _isArticleMode = settings.subtitleViewMode == 1;
    _articleChunkSize = settings.subtitleArticleSentencesPerParagraph.clamp(
      _minArticleChunkSize,
      _maxArticleChunkSize,
    );
    _articleParagraphModeEnabled = settings.subtitleArticleParagraphModeEnabled;
    _loadOrientationDisplaySettings();
    _lastKnownIsPlaying = _playbackIsPlaying;
    _lastSubtitleOffsetMs = settings.subtitleOffset.inMilliseconds;
    settings.addListener(_handleSubtitleOffsetChanged);
    _attachPlaybackListeners();
    GestureBinding.instance.pointerRouter.addGlobalRoute(
      _handleGlobalSelectionPointerEvent,
    );
    // Sidebar-owned Ctrl/Cmd chords, including a hardware keyboard on a phone.
    // SelectionArea's own Actions only cover currently mounted virtualized rows.
    _textSelectionFocusNode.onKeyEvent = (FocusNode node, KeyEvent event) {
      return handleTranscriptShortcut(event);
    };
    _invalidateDisplaySubtitlesCache();
    _checkBilingualSync();
    _rebuildTimelineResolver();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ModalRoute.of 会建立对路由状态的依赖：isCurrent 变化（被横屏播放页/
    // 音乐播放页/弹窗覆盖，或重新回到前台）时会重新进入本方法。
    _handleRouteVisibilityChanged(ModalRoute.of(context)?.isCurrent ?? true);
  }

  /// 路由从「被覆盖」回到前台时，列表恢复布局，被静音挂起的自动跟随动画会
  /// 集中补帧。这里主动补一次修复定位，避免文稿停在切页时的旧位置或空白状态。
  /// 反过来，被覆盖时立刻取消待执行的自动跟随，避免它与修复定位抢落点。
  void _handleRouteVisibilityChanged(bool isCurrent) {
    if (isCurrent == _isHostRouteCurrent) return;
    _isHostRouteCurrent = isCurrent;
    if (!isCurrent) {
      _cancelPendingAutoScroll();
      _routeRestorePending = true;
      return;
    }
    if (!_routeRestorePending && !_repairRequestPending) return;
    _routeRestorePending = false;
    if (!mounted || !widget.isVisible || _displaySubtitles.isEmpty) return;
    // 自动跟随打开时，回到前台主动补一次定位；自动跟随关闭时只在页面之前
    // 显式请求过的修复仍悬空时才补，避免把用户手动滚动的位置强行拉回。
    if (!_repairRequestPending && !SettingsService().autoScrollSubtitles) {
      return;
    }
    locateToCurrentSubtitle(ignorePointer: true);
  }

  bool get _isSubtitleSidebarRouteCurrent => _isHostRouteCurrent;

  @override
  void didUpdateWidget(SubtitleSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isVisible && !widget.isVisible) {
      _invalidateContinuousArticleLayout();
    }
    final bool playbackSourceChanged =
        widget.controller != oldWidget.controller ||
        widget.positionListenable != oldWidget.positionListenable;
    final bool subtitleContentBecameAvailable =
        oldWidget.subtitles.isEmpty &&
        oldWidget.secondarySubtitles.isEmpty &&
        (widget.subtitles.isNotEmpty || widget.secondarySubtitles.isNotEmpty);
    if (widget.isPortrait != oldWidget.isPortrait) {
      _loadOrientationDisplaySettings();
    }
    if (playbackSourceChanged) {
      _detachPlaybackListeners(oldWidget);
      _attachPlaybackListeners();
      _lastKnownIsPlaying = _playbackIsPlaying;
    }
    if (widget.subtitles != oldWidget.subtitles ||
        widget.secondarySubtitles != oldWidget.secondarySubtitles) {
      _clearTextSelection(resumeAutoFollow: false);
      _invalidateDisplaySubtitlesCache();
      _checkBilingualSync();
      _rebuildTimelineResolver();
    }
    if (playbackSourceChanged || subtitleContentBecameAvailable) {
      _scheduleLocateAfterMediaOrSubtitleChange();
    }
    if (!oldWidget.isVisible &&
        widget.isVisible &&
        SettingsService().autoScrollSubtitles) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _updateIndex();
        triggerLocateForAutoFollow();
      });
      _ensureFrameScheduled();
    }
  }

  void _scheduleLocateAfterMediaOrSubtitleChange() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.isVisible || _displaySubtitles.isEmpty) return;
      locateToCurrentSubtitle(ignorePointer: true);
    });
    _ensureFrameScheduled();
  }

  void _handleScrollableViewportLayout(BoxConstraints constraints) {
    if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) return;
    final Size nextSize = Size(constraints.maxWidth, constraints.maxHeight);
    final Size? previousSize = _lastScrollableViewportSize;
    _lastScrollableViewportSize = nextSize;
    if (previousSize == null ||
        ((previousSize.width - nextSize.width).abs() < 0.5 &&
            (previousSize.height - nextSize.height).abs() < 0.5) ||
        _viewportAlignmentRestoreScheduled) {
      return;
    }

    _viewportAlignmentRestoreScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewportAlignmentRestoreScheduled = false;
      if (!mounted || !widget.isVisible || _displaySubtitles.isEmpty) return;
      // ScrollablePositionedList preserves the old pixel offset when its
      // viewport is resized. Re-apply the percentage alignment after the new
      // geometry has been painted so entering the portrait player cannot
      // leave the current subtitle visibly lower than the configured target.
      // 只要还有未落地的修复请求（例如切页时视口被压缩、位置又发生变化），
      // 这里也必须重新驱动，否则该请求会一直悬空、文稿停留在空白状态。
      final bool autoFollowRepair =
          _playbackIsPlaying && SettingsService().autoScrollSubtitles;
      if (!autoFollowRepair && !_repairRequestPending) return;
      if (_hasTextSelection) return;
      // 被不透明路由覆盖时列表没有布局，定位会被丢弃，等回到前台重新驱动。
      if (!_isSubtitleSidebarRouteCurrent) return;
      _beginLocateRequest(animated: false, repair: true);
    });
  }

  void _checkBilingualSync() {
    _secondaryTextCache.clear();
    _primaryToSecondaryIndexCache.clear();
    _secondaryToPrimaryIndexCache.clear();
    _isBilingualMode = false;

    if (widget.secondarySubtitles.isEmpty) return;
    if (widget.subtitles.isEmpty) return;

    final matchResult = matchSubtitleTracks(
      primarySubtitles: widget.subtitles,
      secondarySubtitles: widget.secondarySubtitles,
    );

    _primaryToSecondaryIndexCache.addAll(matchResult.primaryToSecondary);
    _secondaryToPrimaryIndexCache.addAll(matchResult.secondaryToPrimary);

    for (final entry in matchResult.primaryToSecondary.entries) {
      _secondaryTextCache[entry.key] = _normalizeTranscriptText(
        widget.secondarySubtitles[entry.value].text,
      );
    }

    final int minimumMatchCount = widget.subtitles.length <= 2
        ? 1
        : ((widget.subtitles.length * 0.2).ceil());
    _isBilingualMode = matchResult.matchCount >= minimumMatchCount;
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(
      _handleGlobalSelectionPointerEvent,
    );
    _stopTouchSelectionEdgeScroll();
    _clearSelectionGesture();
    _cancelSelectionPreservingPan();
    _removePersistentSelectionToolbar();
    _removeDesktopSelectionToolbar();
    _removeCopyFormatPopover();
    _continuousArticleLayoutRequestId++;
    _detachPlaybackListeners(widget);
    SettingsService().removeListener(_handleSubtitleOffsetChanged);
    _activeIndexNotifier.dispose();
    _activeIndicesNotifier.dispose();
    _textSelectionFocusNode.dispose();
    _autoScrollTimer?.cancel();
    super.dispose();
  }

  void _rebuildTimelineResolver() {
    final subtitles = _displaySubtitles;
    _timelineResolverSubtitles = subtitles;
    _timelineResolver = subtitles.isEmpty
        ? null
        : SubtitleTimelineResolver(subtitles);
    _rebuildSelectionTextCache();
    _rebuildContinuousArticleDocument();
    if (_pendingLocateIndex != null &&
        (_pendingLocateIndex! < 0 ||
            _pendingLocateIndex! >= subtitles.length)) {
      _pendingLocateIndex = null;
    }
  }

  String _normalizeTranscriptText(String text) {
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  void _rebuildSelectionTextCache() {
    final subtitles = _displaySubtitles;
    final parts = List<SubtitleCueCopyParts>.generate(
      subtitles.length,
      _computeCueCopyPartsForIndex,
      growable: false,
    );
    _cueCopyPartsCache
      ..clear()
      ..addAll(parts);
    _selectionTextCache
      ..clear()
      ..addAll(parts.map(SubtitleCopyFormatter.displayText));
  }

  bool _hasSelectableTextAfter(int index) {
    for (int next = index + 1; next < _selectionTextCache.length; next++) {
      if (_selectionTextCache[next].isNotEmpty) return true;
    }
    return false;
  }

  bool get _selectionBlocksAutoFollow =>
      _hasAnyActivePointer || _hasTextSelection;

  void _handleTextSelectionChanged(SelectedContent? content) {
    final String nextText = content?.plainText ?? '';
    final bool hasSelection = nextText.isNotEmpty;

    if (_fullTranscriptSelected) {
      // Handle drags are a real user edit of the range. Everything else is
      // Flutter reporting a virtualized subset or an empty selectAll result.
      if (_selectionGestureUsesHandle && hasSelection) {
        _fullTranscriptSelected = false;
      } else {
        _selectedTranscriptText = _canonicalTranscriptText;
        if (!_hasTextSelection) {
          setState(() => _hasTextSelection = true);
        }
        _persistentSelectionToolbarEntry?.markNeedsBuild();
        _desktopSelectionToolbarEntry?.markNeedsBuild();
        _copyFormatPopoverEntry?.markNeedsBuild();
        return;
      }
    }

    final bool textChanged = nextText != _selectedTranscriptText;
    _selectedTranscriptText = nextText;

    if (hasSelection && !_hasTextSelection) {
      _fullTranscriptSelected = false;
      final int? touchPointer = _activeTouchPointerForSelection();
      if (touchPointer != null) {
        _usesPersistentTouchSelectionToolbar = true;
        _persistentSelectionToolbarAnchor =
            _downTouchPointerPositions[touchPointer];
      } else if (_isMobileSelectionPlatform) {
        // iOS/Android can confirm a selection after the pointer tracking
        // window; still take ownership so Flutter never attaches a geometry
        // menu that later dies off-screen.
        _usesPersistentTouchSelectionToolbar = true;
      }
      setState(() => _hasTextSelection = true);
      _hideNativeSelectionToolbars();
      if (_usesPersistentTouchSelectionToolbar) {
        _schedulePersistentSelectionToolbar();
      }
      _cancelPendingAutoScroll();
      _invalidateLocateRequests();
      // The long-press pointer is already down; bind the gesture to it.
      if (_selectionGesturePointer == null) {
        _selectionGesturePointer = _activeTouchPointerForSelection();
        _selectionGestureUsesHandle = false;
      }
      return;
    }

    if (hasSelection && textChanged) {
      _hideNativeSelectionToolbars();
      _persistentSelectionToolbarEntry?.markNeedsBuild();
      _desktopSelectionToolbarEntry?.markNeedsBuild();
      _copyFormatPopoverEntry?.markNeedsBuild();
      _tryBindCurrentSelectionHandlePointer();
      // Keep the existing pointer; the helper only rebinds when Flutter has
      // confirmed an active selection-changing gesture.
      return;
    }

    if (hasSelection == _hasTextSelection) return;
    setState(() => _hasTextSelection = hasSelection);
    _removePersistentSelectionToolbar();
    _removeDesktopSelectionToolbar();
    _removeCopyFormatPopover();
    _stopTouchSelectionEdgeScroll();
    _clearSelectionGesture();
    _resumeAutoFollowAfterSelection();
  }

  void _resumeAutoFollowAfterSelection() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _hasTextSelection) return;
      triggerLocateForAutoFollow(animated: true);
    });
    _ensureFrameScheduled();
  }

  void _clearTextSelection({bool resumeAutoFollow = true}) {
    final bool wasSelected = _hasTextSelection;
    if (_hasTextSelection && mounted) {
      setState(() => _hasTextSelection = false);
    } else {
      _hasTextSelection = false;
    }
    _selectedTranscriptText = '';
    _fullTranscriptSelected = false;
    _cancelSelectionPreservingPan();
    _removePersistentSelectionToolbar();
    _removeDesktopSelectionToolbar();
    _removeCopyFormatPopover();
    _stopTouchSelectionEdgeScroll();
    _clearSelectionGesture();
    _textSelectionKey.currentState?.selectableRegion.clearSelection();
    _textSelectionFocusNode.unfocus();
    if (wasSelected && resumeAutoFollow) {
      _resumeAutoFollowAfterSelection();
    }
  }

  /// Clears the sidebar's independent transcript selection region.
  ///
  /// Playback pages call this when the user taps outside the sidebar so a
  /// selection cannot remain stranded after the page-level selection clears.
  void clearTextSelection() => _clearTextSelection();

  @visibleForTesting
  String get selectedTranscriptText => _selectedTranscriptText;

  @visibleForTesting
  bool get isFullTranscriptSelected => _fullTranscriptSelected;

  String get _canonicalTranscriptText =>
      SubtitleCopyFormatter.joinedDisplayText(_cueCopyPartsCache);

  @visibleForTesting
  bool get hasTextSelection => _hasTextSelection;

  @visibleForTesting
  bool get isTouchSelectionEdgeScrolling =>
      _touchSelectionEdgeScrollTimer != null;

  @visibleForTesting
  bool get isSelectionGestureActive => _selectionGesturePointer != null;

  @visibleForTesting
  bool get hasOwnedSelectionToolbar =>
      _persistentSelectionToolbarEntry != null ||
      _desktopSelectionToolbarEntry != null;

  /// Touch selection follows a text-editor model:
  ///   1. While the extending pointer stays inside the document, leave the
  ///      viewport entirely to Flutter's selection gesture.
  ///   2. When that pointer reaches the top or bottom edge, pixel-scroll in
  ///      that direction through the list's public relative-offset API.
  ///   3. After lift, stop the fallback so the user can pan the transcript.
  ///
  /// Listen globally because selection handles live in the overlay rather than
  /// this sidebar's render subtree. Mouse is unchanged.
  void _handleGlobalSelectionPointerEvent(PointerEvent event) {
    if (event.kind != PointerDeviceKind.touch &&
        event.kind != PointerDeviceKind.stylus &&
        event.kind != PointerDeviceKind.invertedStylus) {
      return;
    }
    if (event is PointerDownEvent) {
      _downTouchPointers.add(event.pointer);
      _downTouchPointerPositions[event.pointer] = event.position;
      _latestDownTouchPointer = event.pointer;
      return;
    }
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _downTouchPointers.remove(event.pointer);
      _downTouchPointerPositions.remove(event.pointer);
      if (_latestDownTouchPointer == event.pointer) {
        _latestDownTouchPointer = _downTouchPointers.isEmpty
            ? null
            : _downTouchPointers.last;
      }
      if (_selectionGesturePointer == event.pointer) {
        _stopTouchSelectionEdgeScroll();
        _clearSelectionGesture();
      } else if (_touchSelectionEdgePointer == event.pointer) {
        _stopTouchSelectionEdgeScroll();
      }
      return;
    }
    if (event is! PointerMoveEvent || !_hasTextSelection) return;
    _downTouchPointerPositions[event.pointer] = event.position;

    // A real mobile handle drag is a second gesture: long-press, lift, then
    // press one of the handles.  The original long-press pointer has already
    // been cleared by that point.  Bind the new pointer only after Flutter's
    // selection overlay confirms that it is dragging a handle, so an ordinary
    // one-finger transcript pan remains a normal scroll gesture.
    if (_selectionGesturePointer == null && _isSelectionChangeGestureActive) {
      _selectionGesturePointer = event.pointer;
      _selectionGestureUsesHandle = true;
    }
    if (_selectionGesturePointer == null) {
      _scheduleSelectionHandlePointerBindCheck();
    }
    if (event.pointer != _selectionGesturePointer) {
      return;
    }

    _updateTouchSelectionEdgeForPointer(event.pointer, event.position);
  }

  void _scheduleSelectionHandlePointerBindCheck() {
    if (_selectionHandleBindCheckScheduled) return;
    _selectionHandleBindCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _selectionHandleBindCheckScheduled = false;
      if (!mounted) return;
      _tryBindCurrentSelectionHandlePointer();
    });
    _ensureFrameScheduled();
  }

  void _tryBindCurrentSelectionHandlePointer() {
    if (!_hasTextSelection ||
        _selectionGesturePointer != null ||
        !_isSelectionChangeGestureActive) {
      return;
    }
    final int? pointer = _latestDownTouchPointer;
    if (pointer == null || !_downTouchPointers.contains(pointer)) return;
    final Offset? position = _downTouchPointerPositions[pointer];
    if (position == null) return;
    _selectionGesturePointer = pointer;
    _selectionGestureUsesHandle = true;
    _updateTouchSelectionEdgeForPointer(pointer, position);
  }

  void _updateTouchSelectionEdgeForPointer(int pointer, Offset position) {
    if (pointer != _selectionGesturePointer) return;

    final RenderObject? object = _listViewportKey.currentContext
        ?.findRenderObject();
    if (object is! RenderBox || !object.hasSize || object.size.height <= 0) {
      return;
    }
    final Offset local = object.globalToLocal(position);
    final bool wasEdgeScrolling = _touchSelectionEdgePointer == pointer;
    final double edgeZone = wasEdgeScrolling
        ? _touchSelectionEdgeExitZone
        : _touchSelectionEdgeEnterZone;
    final bool horizontallyNearViewport =
        local.dx >= -_touchSelectionEdgeEnterZone &&
        local.dx <= object.size.width + _touchSelectionEdgeEnterZone;
    final double topPenetration = edgeZone - local.dy;
    final double bottomPenetration = local.dy - (object.size.height - edgeZone);

    double? signedPixels;
    if (horizontallyNearViewport &&
        bottomPenetration > 0 &&
        local.dy > _touchSelectionEdgeEnterZone) {
      signedPixels = _edgeScrollPixelsForPenetration(
        local.dy - (object.size.height - _touchSelectionEdgeEnterZone),
      );
    } else if (horizontallyNearViewport &&
        topPenetration > 0 &&
        local.dy < object.size.height - _touchSelectionEdgeEnterZone) {
      signedPixels = -_edgeScrollPixelsForPenetration(
        _touchSelectionEdgeEnterZone - local.dy,
      );
    }

    if (signedPixels == null) {
      if (wasEdgeScrolling) {
        _stopTouchSelectionEdgeScroll();
      }
      return;
    }

    final int previousDirection = _touchSelectionEdgeScrollPixels.sign.toInt();
    final int nextDirection = signedPixels.sign.toInt();
    if (!wasEdgeScrolling || previousDirection != nextDirection) {
      _touchSelectionEdgeTickCount = 0;
    }
    _touchSelectionEdgePointer = pointer;
    _touchSelectionEdgeScrollPixels = signedPixels;
    final bool startedTimer = _touchSelectionEdgeScrollTimer == null;
    _touchSelectionEdgeScrollTimer ??= Timer.periodic(
      _touchSelectionEdgeScrollInterval,
      (_) => _tickTouchSelectionEdgeScroll(),
    );
    if (startedTimer) {
      _tickTouchSelectionEdgeScroll();
    }
  }

  bool get _isSelectionChangeGestureActive =>
      _selectionRegionStatus == SelectableRegionSelectionStatus.changing;

  void _handleSelectionRegionStatusChanged(
    SelectableRegionSelectionStatus status,
  ) {
    _selectionRegionStatus = status;
    if (status == SelectableRegionSelectionStatus.changing) {
      _tryBindCurrentSelectionHandlePointer();
    }
  }

  double _edgeScrollPixelsForPenetration(double penetration) {
    final double strength = (penetration / _touchSelectionEdgeEnterZone).clamp(
      0.0,
      1.0,
    );
    return (_touchSelectionMinPixelsPerTick + 1.5 * strength).clamp(
      _touchSelectionMinPixelsPerTick,
      _touchSelectionMaxPixelsPerTick,
    );
  }

  double get _acceleratedTouchSelectionPixelsPerTick {
    final double progress =
        ((_touchSelectionEdgeTickCount -
                    _touchSelectionAccelerationDelayTicks) /
                _touchSelectionAccelerationTicks)
            .clamp(0.0, 1.0);
    // Smoothstep gives a gentle start and reaches full speed without requiring
    // any additional travel beyond the phone's physical bottom edge.
    final double eased = progress * progress * (3 - 2 * progress);
    final double dwellSpeed =
        _touchSelectionMinPixelsPerTick +
        (_touchSelectionMaxPixelsPerTick - _touchSelectionMinPixelsPerTick) *
            eased;
    final double requestedSpeed = _touchSelectionEdgeScrollPixels.abs();
    return requestedSpeed > dwellSpeed ? requestedSpeed : dwellSpeed;
  }

  void _tickTouchSelectionEdgeScroll() {
    if (!mounted ||
        !_hasTextSelection ||
        _touchSelectionEdgePointer == null ||
        _selectionGesturePointer == null) {
      return;
    }
    final ScrollableState? scrollable = _selectionScrollable;
    if (scrollable == null || !scrollable.mounted) return;
    try {
      final position = scrollable.position;
      _touchSelectionEdgeTickCount++;
      final double direction = _touchSelectionEdgeScrollPixels.sign;
      final double delta = direction * _acceleratedTouchSelectionPixelsPerTick;
      final double target = (position.pixels + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((target - position.pixels).abs() < precisionErrorTolerance) {
        _stopTouchSelectionEdgeScroll();
        return;
      }
      // Mature document editors keep one stable scroll position and apply
      // small, velocity-limited deltas every frame. Never re-anchor the list:
      // doing so makes the viewport race and disposes selection endpoints.
      position.jumpTo(target);
    } catch (_) {
      // The scrollable may detach while switching mode or media.
    }
  }

  void _handleSelectionScrollableChanged(ScrollableState scrollable) {
    if (!mounted) return;
    _selectionScrollable = scrollable;
  }

  Widget _keepSelectionNodeAlive(Widget child) {
    return _SelectionKeepAlive(
      keepAlive: _hasTextSelection,
      child: _TranscriptScrollableObserver(
        onScrollableChanged: _handleSelectionScrollableChanged,
        child: child,
      ),
    );
  }

  void _clearSelectionGesture() {
    _selectionGesturePointer = null;
    _selectionGestureUsesHandle = false;
  }

  void _stopTouchSelectionEdgeScroll() {
    _touchSelectionEdgeScrollTimer?.cancel();
    _touchSelectionEdgeScrollTimer = null;
    _touchSelectionEdgePointer = null;
    _touchSelectionEdgeScrollPixels = 0;
    _touchSelectionEdgeTickCount = 0;
  }

  bool get _isMobileSelectionPlatform {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return true;
      default:
        return false;
    }
  }

  Widget _buildTextSelectionContextMenu(
    BuildContext context,
    SelectableRegionState selectableRegionState,
  ) {
    // The sidebar owns every visible transcript menu. Flutter's geometry-
    // anchored toolbar is what turned into ErrorWidget once virtualized
    // glyphs scrolled off-screen; empty right-click would also open a second
    // "Select all" menu from the ancestor SelectionArea.
    return const SizedBox.shrink();
  }

  void _schedulePersistentSelectionToolbar() {
    if (_persistentSelectionToolbarEntry != null ||
        _persistentSelectionToolbarInsertScheduled) {
      _persistentSelectionToolbarEntry?.markNeedsBuild();
      return;
    }
    _persistentSelectionToolbarInsertScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _persistentSelectionToolbarInsertScheduled = false;
      if (!mounted ||
          !_hasTextSelection ||
          !_usesPersistentTouchSelectionToolbar ||
          _persistentSelectionToolbarEntry != null) {
        return;
      }
      final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
      if (overlay == null) return;
      final entry = OverlayEntry(builder: _buildPersistentSelectionToolbar);
      _persistentSelectionToolbarEntry = entry;
      overlay.insert(entry);
    });
    _ensureFrameScheduled();
  }

  Widget _buildPersistentSelectionToolbar(BuildContext context) {
    if (!mounted ||
        !_hasTextSelection ||
        !_usesPersistentTouchSelectionToolbar) {
      return const SizedBox.shrink();
    }
    final SelectionAreaState? selectionArea = _textSelectionKey.currentState;
    final RenderObject? viewportObject = _listViewportKey.currentContext
        ?.findRenderObject();
    if (selectionArea == null ||
        viewportObject is! RenderBox ||
        !viewportObject.hasSize) {
      return const SizedBox.shrink();
    }

    final Offset topLeft = viewportObject.localToGlobal(Offset.zero);
    final Rect viewport = topLeft & viewportObject.size;
    final TextSelectionToolbarAnchors stableAnchors =
        _persistentSelectionToolbarAnchors ??=
            _resolvePersistentTouchToolbarAnchors(selectionArea, viewport);
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: stableAnchors,
      buttonItems: _buildReliableSelectionToolbarItems(forTouch: true),
    );
  }

  TextSelectionToolbarAnchors _resolvePersistentTouchToolbarAnchors(
    SelectionAreaState selectionArea,
    Rect viewport,
  ) {
    TextSelectionToolbarAnchors? nativeAnchors;
    try {
      final TextSelectionToolbarAnchors candidate =
          selectionArea.selectableRegion.contextMenuAnchors;
      if (_isFiniteOffset(candidate.primaryAnchor) &&
          (candidate.secondaryAnchor == null ||
              _isFiniteOffset(candidate.secondaryAnchor!))) {
        nativeAnchors = candidate;
      }
    } catch (_) {
      // Selection geometry can be between layout passes while virtualized
      // transcript children are mounting. The touch position is a safe
      // one-frame fallback and remains stable afterwards.
    }

    final Offset requested =
        _persistentSelectionToolbarAnchor ?? viewport.center;
    final Offset rawAbove =
        nativeAnchors?.primaryAnchor ?? requested - const Offset(0, 24);
    final Offset rawBelow =
        nativeAnchors?.secondaryAnchor ?? requested + const Offset(0, 24);
    final double horizontalInset = viewport.width < 32 ? 0 : 16;
    double clampX(double dx) => dx
        .clamp(
          viewport.left + horizontalInset,
          viewport.right - horizontalInset,
        )
        .toDouble();

    // Give the toolbar two genuinely different anchors. It is first laid out
    // above the first selected glyph; if that does not fit, it goes below the
    // last selected glyph. Using one anchor for both directions is what made
    // the old toolbar cover the selected word.
    return TextSelectionToolbarAnchors(
      primaryAnchor: Offset(clampX(rawAbove.dx), rawAbove.dy - 6),
      secondaryAnchor: Offset(clampX(rawBelow.dx), rawBelow.dy + 6),
    );
  }

  bool _isFiniteOffset(Offset value) => value.dx.isFinite && value.dy.isFinite;

  List<ContextMenuButtonItem> _buildReliableSelectionToolbarItems({
    required bool forTouch,
  }) {
    final List<ContextMenuButtonItem> items = <ContextMenuButtonItem>[];
    if (_selectedTranscriptText.isNotEmpty) {
      items.add(
        ContextMenuButtonItem(
          type: ContextMenuButtonType.copy,
          onPressed: () => _copySelectedTranscript(forTouch: forTouch),
        ),
      );
    }
    items.add(
      ContextMenuButtonItem(
        type: ContextMenuButtonType.selectAll,
        onPressed: () {
          // Native desktop: Select all dismisses the menu, then Ctrl+C copies.
          _selectEntireTranscript(cause: SelectionChangedCause.toolbar);
          if (!forTouch) {
            _removeDesktopSelectionToolbar();
          }
        },
      ),
    );
    // Settings entry, not a copy action — always available on right-click.
    items.add(
      ContextMenuButtonItem(
        type: ContextMenuButtonType.custom,
        label: '格式',
        onPressed: () => _openCopyFormatPopover(forTouch: forTouch),
      ),
    );
    if (_selectedTranscriptText.isNotEmpty &&
        forTouch &&
        defaultTargetPlatform == TargetPlatform.android) {
      items.add(
        ContextMenuButtonItem(
          type: ContextMenuButtonType.share,
          onPressed: () {
            final String text = _formattedSelectedTranscriptText();
            if (text.isEmpty) return;
            unawaited(
              SystemChannels.platform.invokeMethod<void>('Share.invoke', text),
            );
            _removeCopyFormatPopover();
            clearTextSelection();
          },
        ),
      );
    }
    return items;
  }

  String _formattedSelectedTranscriptText() {
    return SubtitleCopyFormatter.format(
      selectedText: _selectedTranscriptText,
      cues: List<SubtitleCueCopyParts>.unmodifiable(_cueCopyPartsCache),
      format: SettingsService().subtitleCopyFormat,
    );
  }

  /// Live preview for the format popover. Uses the current selection when
  /// there is one; otherwise the first few cues so the panel still works as
  /// a settings entry from an empty right-click.
  String _copyFormatPreviewText() {
    if (_selectedTranscriptText.isNotEmpty) {
      return _formattedSelectedTranscriptText();
    }
    final List<SubtitleCueCopyParts> sample = _cueCopyPartsCache
        .take(3)
        .toList(growable: false);
    if (sample.isEmpty) return '';
    return SubtitleCopyFormatter.format(
      selectedText: SubtitleCopyFormatter.joinedDisplayText(sample),
      cues: sample,
      format: SettingsService().subtitleCopyFormat,
    );
  }

  @visibleForTesting
  String get formattedSelectedTranscriptText =>
      _formattedSelectedTranscriptText();

  void _copySelectedTranscript({
    required bool forTouch,
    bool fromShortcut = false,
  }) {
    final String text = _formattedSelectedTranscriptText();
    if (text.isEmpty) return;
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    if (fromShortcut) return;
    _removeCopyFormatPopover();
    if (forTouch &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.fuchsia)) {
      clearTextSelection();
    } else if (!forTouch) {
      _removeDesktopSelectionToolbar();
    }
  }

  /// Ctrl/Cmd+A and Ctrl/Cmd+C/X, including a hardware keyboard on a phone.
  ///
  /// Player shortcuts ignore modifier chords, so these never reach the
  /// SelectionArea unless the page forwards them here. The SelectionArea's
  /// own select-all also cannot see unmounted virtualized cues.
  KeyEventResult handleTranscriptShortcut(KeyEvent event) {
    if (!mounted || !widget.isVisible) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final bool modifierPressed =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (!modifierPressed || HardwareKeyboard.instance.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.keyA) {
      _selectEntireTranscript(cause: SelectionChangedCause.keyboard);
      return KeyEventResult.handled;
    }
    final bool isCopyKey =
        key == LogicalKeyboardKey.keyC ||
        key == LogicalKeyboardKey.keyX ||
        key == LogicalKeyboardKey.insert;
    if (isCopyKey) {
      if (_selectedTranscriptText.isEmpty) return KeyEventResult.ignored;
      _copySelectedTranscript(forTouch: false, fromShortcut: true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _selectEntireTranscript({
    SelectionChangedCause cause = SelectionChangedCause.keyboard,
  }) {
    final String full = _canonicalTranscriptText;
    if (full.isEmpty) return;
    _fullTranscriptSelected = true;
    _selectedTranscriptText = full;
    if (_isMobileSelectionPlatform) {
      _usesPersistentTouchSelectionToolbar = true;
    }
    if (!_hasTextSelection) {
      setState(() => _hasTextSelection = true);
    } else {
      setState(() {});
    }
    _hideNativeSelectionToolbars();
    if (_usesPersistentTouchSelectionToolbar) {
      _schedulePersistentSelectionToolbar();
    }
    _cancelPendingAutoScroll();
    _invalidateLocateRequests();
    // Focus first so Flutter's visual selectAll has a primary focus. Defer
    // the visual pass a frame: the copy payload is already the full cache
    // and must not wait on mounted-row geometry.
    if (_textSelectionFocusNode.canRequestFocus) {
      _textSelectionFocusNode.requestFocus();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_fullTranscriptSelected) return;
      _textSelectionKey.currentState?.selectableRegion.selectAll(cause);
    });
  }

  void _persistCopyFormat(SubtitleCopyFormat format) {
    unawaited(
      SettingsService().updateSetting(
        'subtitleCopyFormat',
        format.toJsonString(),
      ),
    );
  }

  Offset _copyFormatPopoverAnchor({required bool forTouch}) {
    if (forTouch) {
      return _persistentSelectionToolbarAnchors?.secondaryAnchor ??
          _persistentSelectionToolbarAnchor ??
          Offset.zero;
    }
    return _desktopSelectionToolbarAnchor ?? Offset.zero;
  }

  void _openCopyFormatPopover({required bool forTouch}) {
    if (_copyFormatPopoverEntry != null) {
      _removeCopyFormatPopover();
      return;
    }
    final Offset anchor = _copyFormatPopoverAnchor(forTouch: forTouch);
    if (!forTouch) {
      _removeDesktopSelectionToolbar();
    }
    if (!mounted || _copyFormatPopoverEntry != null) return;
    final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final OverlayEntry entry = OverlayEntry(
      builder: (BuildContext context) {
        if (!mounted) return const SizedBox.shrink();
        final bool canCopy = _selectedTranscriptText.isNotEmpty;
        return SizedBox.expand(
          child: SubtitleCopyFormatPopover(
            anchor: anchor,
            format: SettingsService().subtitleCopyFormat,
            previewText: _copyFormatPreviewText(),
            showBilingualOptions: _cueCopyPartsCache.any(
              (SubtitleCueCopyParts parts) => parts.hasSecondary,
            ),
            onFormatChanged: _persistCopyFormat,
            onCopy: canCopy
                ? () => _copySelectedTranscript(forTouch: forTouch)
                : null,
            onReset: () => _persistCopyFormat(SubtitleCopyFormat.defaults),
          ),
        );
      },
    );
    _copyFormatPopoverEntry = entry;
    overlay.insert(entry);
  }

  void _removeCopyFormatPopover() {
    _copyFormatPopoverEntry?.remove();
    _copyFormatPopoverEntry?.dispose();
    _copyFormatPopoverEntry = null;
  }

  void _removePersistentSelectionToolbar() {
    _persistentSelectionToolbarInsertScheduled = false;
    _persistentSelectionToolbarEntry?.remove();
    _persistentSelectionToolbarEntry?.dispose();
    _persistentSelectionToolbarEntry = null;
    _usesPersistentTouchSelectionToolbar = false;
    _persistentSelectionToolbarAnchor = null;
    _persistentSelectionToolbarAnchors = null;
  }

  void _onTranscriptContextMenuPointer(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse &&
        event.kind != PointerDeviceKind.trackpad) {
      return;
    }
    if (event.buttons != kSecondaryMouseButton) return;
    _showDesktopSelectionToolbar(event.position);
  }

  void _showDesktopSelectionToolbar(Offset anchor) {
    if (_usesPersistentTouchSelectionToolbar) return;
    if (!_isFiniteOffset(anchor)) return;
    _removeCopyFormatPopover();
    _desktopSelectionToolbarAnchor = anchor;
    _hideNativeSelectionToolbars();
    if (_desktopSelectionToolbarEntry != null) {
      _desktopSelectionToolbarEntry!.markNeedsBuild();
      _scheduleHideNativeSelectionToolbars();
      return;
    }
    final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final OverlayEntry entry = OverlayEntry(
      builder: (BuildContext context) {
        if (!mounted ||
            _usesPersistentTouchSelectionToolbar ||
            _desktopSelectionToolbarAnchor == null) {
          return const SizedBox.shrink();
        }
        final Offset menuAnchor = _desktopSelectionToolbarAnchor!;
        if (!_isFiniteOffset(menuAnchor)) {
          return const SizedBox.shrink();
        }
        // Tap outside dismisses the menu without eating the click, so the
        // selection shield and list still receive it. Flutter's geometry
        // menu is never used — that path becomes ErrorWidget off-screen.
        return TapRegion(
          onTapOutside: (PointerDownEvent event) {
            if (event.buttons == kSecondaryMouseButton) return;
            _removeDesktopSelectionToolbar();
          },
          child: AdaptiveTextSelectionToolbar.buttonItems(
            anchors: TextSelectionToolbarAnchors(primaryAnchor: menuAnchor),
            buttonItems: _buildReliableSelectionToolbarItems(forTouch: false),
          ),
        );
      },
    );
    _desktopSelectionToolbarEntry = entry;
    overlay.insert(entry);
    _scheduleHideNativeSelectionToolbars();
  }

  void _scheduleHideNativeSelectionToolbars() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _desktopSelectionToolbarEntry == null) return;
      _hideNativeSelectionToolbars();
    });
  }

  void _hideNativeSelectionToolbars() {
    // Keep selection handles. The default hideToolbar() also drops handles,
    // which iOS needs in order to extend a selection after long-press.
    ContextMenuController.removeAny();
    _textSelectionKey.currentState?.selectableRegion.hideToolbar(false);
    context.visitAncestorElements((Element element) {
      if (element is StatefulElement) {
        final State<StatefulWidget> state = element.state;
        if (state is SelectableRegionState) {
          state.hideToolbar(false);
        } else if (state is SelectionAreaState) {
          state.selectableRegion.hideToolbar(false);
        }
      }
      return true;
    });
  }

  void _removeDesktopSelectionToolbar() {
    _desktopSelectionToolbarEntry?.remove();
    _desktopSelectionToolbarEntry?.dispose();
    _desktopSelectionToolbarEntry = null;
    _desktopSelectionToolbarAnchor = null;
  }

  void _startSelectionPreservingPan(DragStartDetails details) {
    _stopTouchSelectionEdgeScroll();
    _cancelPendingAutoScroll();
    // Desktop context menus dismiss on scroll. Do not hand the menu back to
    // Flutter's endpoint-anchored toolbar — that is the ErrorWidget path.
    _removeDesktopSelectionToolbar();
    _hideNativeSelectionToolbars();
    _selectionPreservingPanDrag?.cancel();
    final ScrollableState? scrollable = _selectionScrollable;
    if (scrollable == null || !scrollable.mounted) return;
    try {
      _selectionPreservingPanDrag = scrollable.position.drag(details, () {
        _selectionPreservingPanDrag = null;
      });
    } catch (_) {
      _selectionPreservingPanDrag = null;
    }
  }

  void _updateSelectionPreservingPan(DragUpdateDetails details) {
    _selectionPreservingPanDrag?.update(details);
  }

  void _endSelectionPreservingPan(DragEndDetails details) {
    final Drag? drag = _selectionPreservingPanDrag;
    _selectionPreservingPanDrag = null;
    drag?.end(details);
  }

  void _cancelSelectionPreservingPan() {
    final Drag? drag = _selectionPreservingPanDrag;
    _selectionPreservingPanDrag = null;
    drag?.cancel();
  }

  Widget _buildSelectionPreservingScrollShield() {
    return Positioned.fill(
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerSignal: (PointerSignalEvent event) {
          if (event is! PointerScrollEvent) return;
          final ScrollableState? scrollable = _selectionScrollable;
          if (scrollable == null || !scrollable.mounted) return;
          _removeDesktopSelectionToolbar();
          _hideNativeSelectionToolbars();
          scrollable.position.pointerScroll(event.scrollDelta.dy);
        },
        child: GestureDetector(
          key: const ValueKey('subtitle-selection-scroll-shield'),
          behavior: HitTestBehavior.opaque,
          onTapDown: (TapDownDetails details) {
            _selectionShieldTapDownPosition = details.globalPosition;
          },
          onTapUp: (TapUpDetails details) {
            final Offset? down = _selectionShieldTapDownPosition;
            _selectionShieldTapDownPosition = null;
            if (down == null ||
                (details.globalPosition - down).distance >
                    _selectionDismissTapSlop) {
              return;
            }
            clearTextSelection();
            widget.onClearSelection?.call();
            widget.focusNode?.requestFocus();
          },
          onTapCancel: () => _selectionShieldTapDownPosition = null,
          onSecondaryTapDown: (TapDownDetails details) {
            _selectionShieldTapDownPosition = null;
            _showDesktopSelectionToolbar(details.globalPosition);
          },
          onVerticalDragStart: _startSelectionPreservingPan,
          onVerticalDragUpdate: _updateSelectionPreservingPan,
          onVerticalDragEnd: _endSelectionPreservingPan,
          onVerticalDragCancel: _cancelSelectionPreservingPan,
        ),
      ),
    );
  }

  void _ensureTimelineResolver() {
    final subtitles = _displaySubtitles;
    if (_timelineResolverSubtitles != subtitles) {
      _rebuildTimelineResolver();
    }
  }

  List<int> _activeIndicesAtMs(int posMs) {
    _ensureTimelineResolver();
    final resolver = _timelineResolver;
    if (resolver == null || resolver.isEmpty) return const <int>[];
    // 侧栏高亮是阅读光标：上一句保持点亮直到下一句开始。画面「字幕连续
    // 显示」只决定悬浮字幕要不要填空隙，不能把这套粘滞高亮关掉。
    return resolver.activeIndicesAtMs(posMs, extendToNextStart: true);
  }

  /// 暂停时播放位置不再变化，调整「字幕同步」不会触发 controller 回调；
  /// 这里主动重算一次高亮，避免侧边栏停留在换算前的索引。
  void _handleSubtitleOffsetChanged() {
    _copyFormatPopoverEntry?.markNeedsBuild();
    final settings = SettingsService();
    final bool nextParagraphMode = settings.subtitleArticleParagraphModeEnabled;
    if (nextParagraphMode != _articleParagraphModeEnabled && mounted) {
      _clearTextSelection(resumeAutoFollow: false);
      setState(() {
        _articleParagraphModeEnabled = nextParagraphMode;
        _invalidateContinuousArticleLayout();
      });
      _triggerLocateButtonAfterModeSwitch();
    }
    final int offsetMs = settings.subtitleOffset.inMilliseconds;
    if (offsetMs == _lastSubtitleOffsetMs) return;
    _lastSubtitleOffsetMs = offsetMs;
    if (!mounted) return;
    _updateIndex();
  }

  void _rebuildContinuousArticleDocument() {
    _articleDocumentGeneration++;
    final subtitles = _displaySubtitles;
    _continuousArticleDocument = ArticleDocument.fromDisplayTexts(
      generation: _articleDocumentGeneration,
      displayTexts: _selectionTextCache,
      sentenceSeparator: ' ',
      imageSubtitleFlags: List<bool>.generate(
        subtitles.length,
        (index) => subtitles[index].imageLoader != null,
        growable: false,
      ),
    );
    _invalidateContinuousArticleLayout();
  }

  bool _isBeforeFirstSubtitleAtMs(int positionMs) {
    final subtitles = _displaySubtitles;
    return subtitles.isNotEmpty &&
        positionMs < subtitles.first.startTime.inMilliseconds;
  }

  void _locateBeforeFirstSubtitleAtTop() {
    if (_displaySubtitles.isEmpty) return;
    _pendingLocateIndex = null;
    _clearManualLocateLock();
    _markManualAnimationFreeze(0, animated: false);
    _clearAutoScrollSuppression();
    _activeIndexNotifier.value = 0;
    if (_activeIndicesNotifier.value.isNotEmpty) {
      _activeIndicesNotifier.value = const <int>[];
    }
    _jumpToIndexTopInternal(targetIndex: 0, attempt: 0);
  }

  void _updateIndex() {
    final subtitles = _displaySubtitles;
    if (!mounted || subtitles.isEmpty) return;

    final bool isPlaying = _playbackIsPlaying;
    final bool playbackStateChanged = isPlaying != _lastKnownIsPlaying;
    _lastKnownIsPlaying = isPlaying;
    final int posMs = _subtitleTimelinePositionMs;
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    // 高亮必须跟悬浮字幕用同一帧播放位置切句。按 80ms 节流会跨过句界，
    // 侧栏会比画面晚一拍；解析器查询本身很便宜，不必为省这一点而延迟。
    final List<int> activeIndices = _activeIndicesAtMs(posMs);
    final bool isBeforeFirstSubtitle = _isBeforeFirstSubtitleAtMs(posMs);
    if (isBeforeFirstSubtitle) {
      _pendingLocateIndex = null;
      _clearManualLocateLock();
      _markManualAnimationFreeze(0, animated: false);
      _clearAutoScrollSuppression();
    }
    final bool hasManualAnimationFreeze = _hasManualAnimationFreeze(nowMs);
    final int? manualAnimationFreezeIndex = _manualAnimationFreezeIndex;
    if (hasManualAnimationFreeze &&
        manualAnimationFreezeIndex != null &&
        manualAnimationFreezeIndex >= 0 &&
        manualAnimationFreezeIndex < subtitles.length) {
      if (_activeIndexNotifier.value != manualAnimationFreezeIndex) {
        _activeIndexNotifier.value = manualAnimationFreezeIndex;
      }
      final List<int> frozenActiveIndices = <int>[manualAnimationFreezeIndex];
      if (!_isSameIndices(frozenActiveIndices, _activeIndicesNotifier.value)) {
        _activeIndicesNotifier.value = frozenActiveIndices;
      }
      return;
    }
    final bool hasManualLocateLock = _hasManualLocateLock(nowMs);
    final int? manualLocateLockIndex = _manualLocateLockIndex;
    if (hasManualLocateLock &&
        manualLocateLockIndex != null &&
        !activeIndices.contains(manualLocateLockIndex)) {
      if (_activeIndexNotifier.value != manualLocateLockIndex) {
        _activeIndexNotifier.value = manualLocateLockIndex;
      }
      const List<int> emptyActiveIndices = <int>[];
      final List<int> lockedActiveIndices = manualLocateLockIndex >= 0
          ? <int>[manualLocateLockIndex]
          : emptyActiveIndices;
      if (!_isSameIndices(lockedActiveIndices, _activeIndicesNotifier.value)) {
        _activeIndicesNotifier.value = lockedActiveIndices;
      }
      return;
    }
    if (hasManualLocateLock) {
      _clearManualLocateLock();
    }
    int index = activeIndices.isNotEmpty
        ? activeIndices.first
        : (isBeforeFirstSubtitle ? 0 : -1);
    final int? pendingIndex = _pendingLocateIndex;
    if (pendingIndex != null && activeIndices.contains(pendingIndex)) {
      index = pendingIndex;
    }
    final bool suppressAutoScrollForIndex =
        index >= 0 && _shouldSuppressAutoScrollForIndex(index);
    if (index >= 0 && index == _pendingLocateIndex) {
      _pendingLocateIndex = null;
    }
    if (suppressAutoScrollForIndex) {
      _clearAutoScrollSuppression();
    }
    final bool activeIndicesChanged = !_isSameIndices(
      activeIndices,
      _activeIndicesNotifier.value,
    );
    if (activeIndicesChanged) {
      _activeIndicesNotifier.value = activeIndices;
    }

    final bool indexChanged = index != _activeIndexNotifier.value;
    if (indexChanged) {
      _activeIndexNotifier.value = index;
    }

    final bool isInManualLocateAutoFollowCooldown =
        _isInManualLocateAutoFollowCooldown(nowMs);
    if ((indexChanged ||
            playbackStateChanged ||
            (isBeforeFirstSubtitle && activeIndicesChanged)) &&
        isPlaying &&
        widget.isVisible &&
        _isSubtitleSidebarRouteCurrent &&
        SettingsService().autoScrollSubtitles &&
        !isInManualLocateAutoFollowCooldown &&
        !suppressAutoScrollForIndex &&
        !_selectionBlocksAutoFollow) {
      _scheduleAutoScroll();
    }
  }

  void locateToTime(
    Duration target, {
    int? preferredIndex,
    bool animated = true,
    bool preferSingleStage = true,
  }) {
    if (!mounted) return;
    if (!widget.isVisible) return;
    final subtitles = _displaySubtitles;
    if (subtitles.isEmpty) return;

    // 调用方传入的是视频时间（用于 seek），先换算到字幕时间轴再定位。
    final int posMs = target.inMilliseconds - _subtitleOffsetMs;
    final List<int> activeIndices = _activeIndicesAtMs(posMs);
    if (_isBeforeFirstSubtitleAtMs(posMs)) {
      _cancelPendingAutoScroll();
      _invalidateLocateRequests();
      _markManualLocateAutoFollowCooldown();
      _locateBeforeFirstSubtitleAtTop();
      return;
    }

    int index = -1;
    if (preferredIndex != null &&
        preferredIndex >= 0 &&
        preferredIndex < subtitles.length) {
      index = preferredIndex;
    } else if (activeIndices.isNotEmpty) {
      index = activeIndices.first;
    }
    if (index < 0 || index >= subtitles.length) return;

    _invalidateLocateRequests();
    _cancelPendingAutoScroll();
    _pendingLocateIndex = index;
    _markManualLocateLock(index);
    _markManualLocateAutoFollowCooldown();
    _markManualAnimationFreeze(index, animated: animated);
    _activeIndexNotifier.value = index;
    final List<int> nextActiveIndices = activeIndices.isNotEmpty
        ? activeIndices
        : <int>[index];
    if (!_isSameIndices(nextActiveIndices, _activeIndicesNotifier.value)) {
      _activeIndicesNotifier.value = nextActiveIndices;
    }
    _markAutoScrollSuppressedForIndex(index);
    if (animated) {
      _scrollToIndex(
        index,
        isAuto: false,
        preferSingleStage: preferSingleStage,
      );
    } else {
      _jumpToActiveIndexWithAlignment(index);
    }
  }

  bool _isSameIndices(List<int> next, List<int> prev) {
    if (next.length != prev.length) return false;
    for (int i = 0; i < next.length; i++) {
      if (next[i] != prev[i]) return false;
    }
    return true;
  }

  void _scheduleAutoScroll() {
    _autoScrollTimer?.cancel();
    final int requestId = ++_autoScrollRequestId;
    _autoScrollTimer = Timer(Duration.zero, () {
      if (!mounted) return;
      if (_selectionBlocksAutoFollow) return;
      if (!_isSubtitleSidebarRouteCurrent) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_selectionBlocksAutoFollow) return;
        if (requestId != _autoScrollRequestId) return;
        if (!_isSubtitleSidebarRouteCurrent) return;
        _scrollToActiveIndex(isAuto: true);
      });
      _ensureFrameScheduled();
    });
  }

  void triggerLocateForAutoFollow({bool animated = false}) {
    if (!mounted) return;
    if (!widget.isVisible || !SettingsService().autoScrollSubtitles) return;
    if (_selectionBlocksAutoFollow) return;
    if (_displaySubtitles.isEmpty) return;
    if (!_playbackIsPlaying) return;
    if (!_isSubtitleSidebarRouteCurrent) return;
    _ensureTimelineResolver();
    if (_isBeforeFirstSubtitleAtMs(_subtitleTimelinePositionMs)) {
      _locateBeforeFirstSubtitleAtTop();
      return;
    }

    _beginLocateRequest(animated: animated, repair: false);
  }

  void _triggerLocateButtonAfterModeSwitch() {
    if (!mounted) return;
    if (!widget.isVisible) return;
    if (_selectionBlocksAutoFollow) return;
    if (_displaySubtitles.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // ItemPositionsListener publishes the geometry from a rebuilt row one
      // frame after the row itself. Waiting for that fresh snapshot prevents
      // a line-height or view-mode change from being positioned with stale
      // pre-switch bounds.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _beginLocateRequest(animated: false, repair: true, immediate: true);
      });
      _ensureFrameScheduled();
    });
    _ensureFrameScheduled();
  }

  void _updateArticleChunkSize(int value) {
    final int nextValue = value.clamp(
      _minArticleChunkSize,
      _maxArticleChunkSize,
    );
    if (nextValue == _articleChunkSize) return;

    _clearTextSelection(resumeAutoFollow: false);
    setState(() => _articleChunkSize = nextValue);
    SettingsService().updateSetting(
      'subtitleArticleSentencesPerParagraph',
      nextValue,
    );
    _triggerLocateButtonAfterModeSwitch();
  }

  void _updateArticleParagraphMode(bool enabled) {
    if (enabled == _articleParagraphModeEnabled) return;
    _invalidateLocateRequests();
    _cancelPendingAutoScroll();
    setState(() {
      _articleParagraphModeEnabled = enabled;
      _invalidateContinuousArticleLayout();
    });
    SettingsService().updateSetting(
      'subtitleArticleParagraphModeEnabled',
      enabled,
    );
    _triggerLocateButtonAfterModeSwitch();
  }

  void _updateLocatePositionPercent(int value) {
    final int nextValue = _clampLocatePositionPercent(value);
    if (nextValue == _locatePositionPercent) return;

    setState(() => _locatePositionPercent = nextValue);
    final key = widget.isPortrait
        ? 'portraitSidebarLocatePositionPercent'
        : 'landscapeSidebarLocatePositionPercent';
    SettingsService().updateSetting(key, nextValue);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollToActiveIndex();
    });
  }

  /// 暴露给外部页面（如从横屏/音乐播放页切换回视频播放页）的定位方法。
  ///
  /// 与 [triggerLocateForAutoFollow] 不同，本方法不依赖 autoScrollSubtitles
  /// 开关，也不要求当前正在播放，只要字幕文稿区可见即执行定位。
  /// 用于在页面切换完成后将字幕文稿滚动到当前播放位置对应的字幕，
  /// 同时修复切回页面时列表偶发空白（滚动控制器暂未重新挂载）的问题。
  ///
  /// 返回 false 表示本次请求暂时无法受理（面板不可见、无字幕、指针仍按下），
  /// 调用方可以稍后重试；返回 true 表示已受理，列表一旦完成布局就会落地，
  /// 且落地后会自动校验，必要时再补一次跳转。
  bool locateToCurrentSubtitle({
    bool animated = false,
    bool ignorePointer = false,
  }) {
    if (!mounted) return false;
    if (!widget.isVisible) return false;
    // 页面切换完成后的自动定位属于「显式请求」，即便切页瞬间仍有一个活动的指针
    // （例如点击返回键抬起前的那一帧）也应执行定位；此时由调用方传入 ignorePointer=true。
    if (_hasTextSelection) return false;
    if (!ignorePointer && _hasAnyActivePointer) return false;
    if (_displaySubtitles.isEmpty) return false;
    _ensureTimelineResolver();
    // 修复定位必须压过自动跟随：先取消待执行的自动滚动并进入冷却时间，
    // 否则自动跟随的动画会在修复跳转之后落地，把文稿又拖回旧位置。
    _cancelPendingAutoScroll();
    _markManualLocateAutoFollowCooldown();
    _beginLocateRequest(animated: animated, repair: true);
    return true;
  }

  /// 登记一次定位请求。只有最新请求会落地，旧请求的延迟回调会因请求号变化失效。
  ///
  /// [immediate] 用于调用方已经等过一帧（例如视图模式切换）的场景，直接在
  /// 当前回调里尝试落地，避免多引入一帧的位置漂移。
  void _beginLocateRequest({
    required bool animated,
    required bool repair,
    bool keepVerificationBudget = false,
    bool immediate = false,
  }) {
    if (_hasTextSelection) return;
    final int requestId = ++_locateRequestId;
    _locateAttempts = 0;
    _locateAnimated = animated;
    _locateIsRepair = repair;
    _locateVerificationScheduled = false;
    if (!keepVerificationBudget) {
      _locateVerificationRounds = 0;
    }
    if (repair) {
      _repairRequestPending = true;
    }
    if (immediate) {
      _driveLocateRequest(requestId);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _driveLocateRequest(requestId);
    });
    _ensureFrameScheduled();
  }

  /// post-frame 回调只有在「有帧被调度」时才会执行。播放暂停或界面静止时
  /// （例如横屏退出后停在暂停状态）没有任何东西会调度帧，仅注册回调会让
  /// 修复定位悬空、文稿停留在切页时的空白状态。这里显式确保下一帧会发生。
  void _ensureFrameScheduled() {
    if (!mounted) return;
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// 手动操作（点击字幕、时间轴定位等）会接管定位：作废所有在途请求，
  /// 避免自动补位把用户的选择覆盖掉。
  void _invalidateLocateRequests() {
    _locateRequestId++;
    _repairRequestPending = false;
    _locateVerificationScheduled = false;
  }

  Iterable<ItemPosition> _currentItemPositions() {
    return _isArticleMode
        ? _articleItemPositionsListener.itemPositions.value
        : _itemPositionsListener.itemPositions.value;
  }

  int _articleItemIndexForSubtitle(int subtitleIndex) {
    if (_isContinuousArticleMode) {
      return _continuousArticleLayout?.lineForSentence(subtitleIndex) ?? -1;
    }
    return subtitleIndex ~/ _articleChunkSize;
  }

  int get _articleItemCount {
    if (_isContinuousArticleMode) {
      return _continuousArticleLayout?.lines.length ?? 0;
    }
    return (_displaySubtitles.length / _articleChunkSize).ceil();
  }

  /// 列表是否已经产出可用的几何信息。控制器未挂载或没有任何可见行时，
  /// 任何 jump/scroll 都会被直接丢弃（这正是切页后文稿空白的形态）。
  bool _hasLocateGeometry() {
    final bool attached = _isArticleMode
        ? _articleItemScrollController.isAttached
        : _itemScrollController.isAttached;
    if (!attached) return false;
    return _currentItemPositions().isNotEmpty;
  }

  /// 视口是否具有可用高度（切页瞬间面板可能被压缩为 0，此时无法定位）。
  bool _isScrollableViewportUsable() {
    final Size? size = _lastScrollableViewportSize;
    return size == null || size.height > _collapsedViewportHeight;
  }

  void _driveLocateRequest(int requestId) {
    if (!mounted || requestId != _locateRequestId) return;
    if (!widget.isVisible || _displaySubtitles.isEmpty) {
      _repairRequestPending = false;
      return;
    }
    // 被不透明路由覆盖时列表不参与布局，滚动会被丢弃；保持请求挂起，
    // 回到前台（didChangeDependencies）或视口变化时会重新驱动。
    if (!_isSubtitleSidebarRouteCurrent) return;
    if (!_locateIsRepair &&
        (!_playbackIsPlaying || !SettingsService().autoScrollSubtitles)) {
      return;
    }

    if (!_hasLocateGeometry() || !_isScrollableViewportUsable()) {
      // 视口被压缩时不再空转重试，交给视口尺寸变化重新驱动。
      if (_isScrollableViewportUsable() &&
          _locateAttempts < _maxLocateAttempts) {
        _locateAttempts++;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _driveLocateRequest(requestId);
        });
        _ensureFrameScheduled();
      }
      return;
    }

    _ensureTimelineResolver();
    _applyLocateRequest();
    if (_locateIsRepair) {
      _repairRequestPending = false;
    }
    _scheduleLocateVerification(requestId);
  }

  void _applyLocateRequest() {
    final int posMs = _subtitleTimelinePositionMs;
    final List<int> activeIndices = _activeIndicesAtMs(posMs);
    if (_isBeforeFirstSubtitleAtMs(posMs)) {
      _locateBeforeFirstSubtitleAtTop();
      return;
    }
    final int currentIndex = activeIndices.isNotEmpty
        ? activeIndices.first
        : -1;
    final int index = _resolveLocateTargetIndex(currentIndex);
    // 若当前位置没有「正在显示」的字幕（例如视频一直暂停在 0 秒、尚未到第一条字幕），
    // 则回退定位到第一条字幕。这样既能满足「切换完成后定位到当前字幕」的诉求
    // （暂停在开始处时把文稿滚动到开头），也能强制列表重新渲染、修复切页后偶发的空白。
    final int targetIndex = (index >= 0 && index < _displaySubtitles.length)
        ? index
        : (_displaySubtitles.isNotEmpty ? 0 : -1);
    if (targetIndex < 0 || targetIndex >= _displaySubtitles.length) return;
    if (!_isSameIndices(activeIndices, _activeIndicesNotifier.value)) {
      if (currentIndex >= 0) {
        _activeIndicesNotifier.value = activeIndices;
      } else {
        _activeIndicesNotifier.value = <int>[targetIndex];
      }
    }

    _activeIndexNotifier.value = targetIndex;
    if (_locateAnimated && !_locateIsRepair) {
      _scrollToActiveIndex();
    } else {
      _jumpToActiveIndexWithAlignment(targetIndex);
    }
  }

  /// 落地后校验：列表已挂载、视口高度正常，但一帧后仍然没有任何可见行，
  /// 说明这次定位没有真正生效（例如列表刚刚重建，或修复跳转被挂起的自动
  /// 跟随动画覆盖）。此时再补一次跳转，确保文稿不会停在空白状态。
  void _scheduleLocateVerification(int requestId) {
    if (_locateVerificationScheduled) return;
    if (_locateVerificationRounds >= _maxLocateVerificationRounds) return;
    _locateVerificationScheduled = true;
    final int round = ++_locateVerificationRounds;
    _waitFramesThenVerify(requestId, round == 1 ? 2 : 10);
  }

  void _waitFramesThenVerify(int requestId, int framesLeft) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ensureFrameScheduled();
      if (framesLeft > 1) {
        _waitFramesThenVerify(requestId, framesLeft - 1);
        return;
      }
      _locateVerificationScheduled = false;
      if (requestId != _locateRequestId) return;
      if (!widget.isVisible || _displaySubtitles.isEmpty) return;
      if (!_isSubtitleSidebarRouteCurrent) return;
      if (!_isScrollableViewportUsable()) return;
      if (_currentItemPositions().isNotEmpty) return;
      // 列表仍然没有任何可见行：再补一次修复跳转（沿用本轮校验预算，
      // 避免与持续空白互相触发造成死循环）。
      _beginLocateRequest(
        animated: false,
        repair: true,
        keepVerificationBudget: true,
      );
    });
  }

  /// 字幕列表区（不含顶部工具栏）的指针登记。
  ///
  /// 命中测试结果自内向外派发，本回调一定早于外层的 [_onPointerDown]，
  /// 因此 [_onPointerDown] 建记录时可以直接读到这里写下的结果。
  void _onListAreaPointerDown(PointerDownEvent event) {
    _listAreaPointerIds.add(event.pointer);
    final int? rowIndex = _resolveRowIndexAt(event.position);
    if (rowIndex != null) {
      _pendingRowIndexByPointer[event.pointer] = rowIndex;
    }
  }

  /// 把全局坐标反查成字幕行号；落在行间空隙或列表之外时返回 null。
  ///
  /// [ItemPosition] 的 leading/trailing edge 是相对视口主轴长度的比例，所以
  /// 先把坐标换算进 [_listViewportKey] 对应的视口，再按比例查表。
  int? _resolveRowIndexAt(Offset globalPosition) {
    final RenderObject? object = _listViewportKey.currentContext
        ?.findRenderObject();
    if (object is! RenderBox || !object.hasSize) return null;
    final Size size = object.size;
    if (size.height <= 0) return null;
    final Offset local = object.globalToLocal(globalPosition);
    if (!(Offset.zero & size).contains(local)) return null;

    final double fraction = local.dy / size.height;
    int? targetIndex;
    for (final ItemPosition position in _currentItemPositions()) {
      if (fraction >= position.itemLeadingEdge &&
          fraction < position.itemTrailingEdge) {
        targetIndex = position.index;
        break;
      }
    }
    if (targetIndex == null) return null;

    if (!_isArticleMode) {
      return targetIndex >= 0 && targetIndex < _displaySubtitles.length
          ? targetIndex
          : null;
    }
    if (_isContinuousArticleMode) {
      return _continuousArticleViewKey.currentState
          ?.subtitleIndexAtGlobalPosition(globalPosition, targetIndex);
    }
    // 文章模式一个 item 是一整段，还要再问段落自己命中了段内哪一句。
    final State<SubtitleArticleChunk>? chunkState =
        _articleChunkKeys[targetIndex]?.currentState;
    if (chunkState is! _SubtitleArticleChunkState) return null;
    return chunkState.subtitleIndexAtGlobalPosition(globalPosition);
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_activePointerCount == 0) {
      _pointerSessionStartedWithTextSelection = _hasTextSelection;
      _didScrollWhilePointerSession = false;
      _didDoubleTapSeekWhilePointerSession = false;
      _pointerDownStartIndex = _activeIndexNotifier.value;
      _pointerDownSubtitleIndex = null;
      _pendingDragDoubleTap = null;
      _suppressedRowTapIndex = null;
    }
    _recentlyLiftedSecondaryTap = null;
    _lastLiftedPointer = null;
    _lastLiftedHeldMs = 0;
    _activePointerCount++;
    _pointerRecords[event.pointer] = _SidebarPointerRecord(
      downPosition: event.position,
      downTimeMs: event.timeStamp.inMilliseconds,
      kind: event.kind,
      inListArea: _listAreaPointerIds.contains(event.pointer),
      anchorPointerIds: _currentListAreaAnchorIds(event.pointer),
      rowIndex: _pendingRowIndexByPointer.remove(event.pointer),
    );
    _cancelPendingAutoScroll();
  }

  /// 本指针按下瞬间，列表区内已经按住的其他指针 id。
  /// 非空即表示它是一次「拖拽会话中的副指针」。
  Set<int> _currentListAreaAnchorIds(int selfPointer) {
    return _pointerRecords.keys
        .where(
          (int id) => id != selfPointer && _listAreaPointerIds.contains(id),
        )
        .toSet();
  }

  void _onPointerMove(PointerMoveEvent event) {
    final _SidebarPointerRecord? record = _pointerRecords[event.pointer];
    if (record == null) return;
    // 累计「离落点的最远距离」而不是逐帧位移：来回抖动同样会被正确放大，
    // 避免手指画圈却被当成原地轻点。
    final double travel = (event.position - record.downPosition).distance;
    if (travel > record.maxTravel) record.maxTravel = travel;
  }

  void _onPointerUpOrCancel(PointerEvent event) {
    final _SidebarPointerRecord? record = _pointerRecords.remove(event.pointer);
    _listAreaPointerIds.remove(event.pointer);
    // PointerCancel 表示手势被系统/上层接管（来电浮层、返回手势等），
    // 绝不能当成一次有效轻点。
    _recentlyLiftedSecondaryTap = null;
    _pendingRowIndexByPointer.remove(event.pointer);
    // 先记下这次抬起的位移/时长，再交给随后才会裁决的 onTap 去核对。
    // PointerCancel 不能当单击：手势被系统接管时绝不能 seek。
    if (record != null && event is PointerUpEvent) {
      _lastLiftedPointer = record;
      _lastLiftedHeldMs = event.timeStamp.inMilliseconds - record.downTimeMs;
    } else {
      _lastLiftedPointer = null;
      _lastLiftedHeldMs = 0;
    }
    if (record != null &&
        event is PointerUpEvent &&
        _isDragDoubleTapCandidate(record, event)) {
      // 留给随后才会裁决出的 onTap 认领，见 [_shouldDeferRowTap]。
      _recentlyLiftedSecondaryTap = record;
      _evaluateDragDoubleTap(record, event.timeStamp.inMilliseconds);
    }
    _activePointerCount--;
    if (_activePointerCount < 0) _activePointerCount = 0;
    if (_activePointerCount == 0) {
      // 兜底清理：极端情况下（如事件在路由切换中丢失）残留的记录会让下一次
      // 单指点击被误判成副指针，这里按会话边界强制归零。
      _pointerRecords.clear();
      _listAreaPointerIds.clear();
      _pendingRowIndexByPointer.clear();
      final bool shouldAnimateRelocate = _didScrollWhilePointerSession;
      final bool didDoubleTapSeek = _didDoubleTapSeekWhilePointerSession;
      final int? pointerDownStartIndex = _pointerDownStartIndex;
      final int? tappedSubtitleIndex = _pointerDownSubtitleIndex;
      final int currentIndex = _activeIndexNotifier.value;
      _didScrollWhilePointerSession = false;
      _didDoubleTapSeekWhilePointerSession = false;
      _pointerDownStartIndex = null;
      _pointerDownSubtitleIndex = null;
      _pendingDragDoubleTap = null;
      _suppressedRowTapIndex = null;
      if (didDoubleTapSeek) {
        // 拖拽期间的双击只做了 seek，定位被刻意推迟到这一刻。
        // 目标是「此刻的当前句」（媒体可能已经从双击那句继续播了过去），
        // 由 locateToCurrentSubtitle 按实时播放位置解析，而不是记住双击行号。
        // 用它而不是 triggerLocateForAutoFollow：双击是显式意图，暂停时也该
        // 对齐，只保留「自动跟随开关」这一层约束。
        if (SettingsService().autoScrollSubtitles) {
          locateToCurrentSubtitle(animated: true);
        }
      } else if (shouldAnimateRelocate && tappedSubtitleIndex == null) {
        triggerLocateForAutoFollow(animated: true);
      } else if (tappedSubtitleIndex == null &&
          pointerDownStartIndex != null &&
          pointerDownStartIndex != currentIndex) {
        // Playback can advance while a non-row pointer gesture is held. Keep
        // the regular auto-follow behavior for that case.
        triggerLocateForAutoFollow(animated: true);
      }
    }
  }

  /// 这次抬起是不是「拖拽会话中副指针的一次干净轻点」。
  ///
  ///  - [PointerDeviceKind.touch]：鼠标双击、触控笔在桌面端另有语义；
  ///  - [_SidebarPointerRecord.inListArea]：点在顶部工具栏上不算；
  ///  - `anchorPointerIds` 非空：单指点击必须保持原有的「点一下就跳并定位」；
  ///  - `rowIndex != null`：必须真的命中了某一行字幕；
  ///  - 干净轻点：位移 <= slop 且时长 <= 300ms，滑动与长按都被排除。
  bool _isDragDoubleTapCandidate(
    _SidebarPointerRecord record,
    PointerUpEvent event,
  ) {
    // 关闭自动跟随时，单指点击本来就只 seek 不滚动，没有需要规避的副作用，
    // 保持原有交互即可，不启用本机制。
    if (!SettingsService().autoScrollSubtitles) return false;
    if (record.kind != PointerDeviceKind.touch) return false;
    if (!record.inListArea) return false;
    if (record.rowIndex == null) return false;
    if (record.anchorPointerIds.isEmpty) return false;
    if (record.maxTravel > _dragTapMaxTravel) return false;
    final int heldMs = event.timeStamp.inMilliseconds - record.downTimeMs;
    return heldMs <= _dragTapMaxDurationMs;
  }

  /// 判定刚抬起的这根手指是否凑成了一次「拖拽中的副指针双击」。
  ///
  /// 前置条件已由 [_isDragDoubleTapCandidate] 过滤，这里只补上需要跨两次
  /// 轻点才能判的部分：同一行、落点接近、间隔 <= 300ms，且两次轻点共享至少
  /// 一根「从第一次点之前就按着、到现在仍没抬起」的锚定手指。
  void _evaluateDragDoubleTap(_SidebarPointerRecord record, int upTimeMs) {
    final int rowIndex = record.rowIndex!;
    final _SidebarTapRecord? pending = _pendingDragDoubleTap;
    if (pending != null &&
        pending.rowIndex == rowIndex &&
        (record.downPosition - pending.downPosition).distance <=
            _dragDoubleTapSlop &&
        (record.downTimeMs - pending.upTimeMs) <= _dragDoubleTapIntervalMs &&
        // 这一条同时挡掉了「中途全部松手后重新落指」和「另一处的无关连点」。
        pending.anchorPointerIds.any(
          (int id) =>
              record.anchorPointerIds.contains(id) &&
              _pointerRecords.containsKey(id),
        )) {
      _pendingDragDoubleTap = null;
      _handleDragDoubleTapSeek(rowIndex);
      return;
    }

    _pendingDragDoubleTap = _SidebarTapRecord(
      rowIndex: rowIndex,
      downPosition: record.downPosition,
      upTimeMs: upTimeMs,
      anchorPointerIds: record.anchorPointerIds,
    );
  }

  /// 第 [index] 行的常规点击是否应该让位给「拖拽中双击」识别器。
  ///
  /// 只有在列表尚未进入滚动状态时，行上的 TapGestureRecognizer 才可能赢下
  /// 竞技场并触发 onTap（列表一旦在滚动，新指针会被 Scrollable 的
  /// DragGestureRecognizer 直接判给自己）。所以这里要覆盖两种时序：
  ///   1. 手指仍按着（副指针还在 [_pointerRecords] 里）；
  ///   2. 手指刚抬起（快速轻点，竞技场在抬起事件派发完之后才裁决），对应记录
  ///      暂存在 [_recentlyLiftedSecondaryTap]。
  bool _shouldDeferRowTap(int index) {
    if (!SettingsService().autoScrollSubtitles) return false;
    final _SidebarPointerRecord? lifted = _recentlyLiftedSecondaryTap;
    if (lifted != null && lifted.rowIndex == index) return true;
    for (final _SidebarPointerRecord record in _pointerRecords.values) {
      if (record.kind != PointerDeviceKind.touch) continue;
      if (record.anchorPointerIds.isEmpty) continue;
      if (record.rowIndex != index) continue;
      return true;
    }
    return false;
  }

  /// 拖拽会话中的双击：只把媒体 seek 到该句的时间点，绝不滚动文稿。
  ///
  /// 播放/暂停状态交由播放页的 seek 通路原样保持（seekTo 不会 pause/play），
  /// 因此双击前在播放的，双击后继续播放。
  void _handleDragDoubleTapSeek(int index) {
    final subtitles = _displaySubtitles;
    if (index < 0 || index >= subtitles.length) return;

    final item = subtitles[index];
    widget.onClearSelection?.call();
    // 作废在途的自动/修复定位并进入冷却，否则它们会在 seek 之后落地，
    // 把用户正在浏览的位置拖走——这正是本机制要避免的。
    _invalidateLocateRequests();
    _cancelPendingAutoScroll();
    _markManualLocateAutoFollowCooldown();
    // 高亮立刻跟到被双击的那一行；加锁是为了扛住 seek 真正生效前的那几帧
    // 仍在上报旧位置的回调，避免高亮来回闪。
    _markManualLocateLock(index);
    _activeIndexNotifier.value = index;
    final List<int> tappedIndices = <int>[index];
    if (!_isSameIndices(tappedIndices, _activeIndicesNotifier.value)) {
      _activeIndicesNotifier.value = tappedIndices;
    }
    _didDoubleTapSeekWhilePointerSession = true;
    // 与常规点击一致：接收方把参数当作视频时间直接 seek，字幕时间需加上
    // 延迟换算，才能让画面字幕与双击项一致。
    widget.onItemTap?.call(
      item.startTime + Duration(milliseconds: _subtitleOffsetMs),
    );
    // 手指仍压在屏幕上、文稿又刻意不滚动，缺少视觉位移反馈，用轻微震动补上。
    HapticFeedback.selectionClick();
  }

  int? _activeTouchPointerForSelection() {
    // Only pointers that are still down. Leftover list-area records would
    // re-bind a later pan as a selection gesture and freeze the viewport.
    if (_latestDownTouchPointer != null) return _latestDownTouchPointer;
    if (_downTouchPointers.isNotEmpty) return _downTouchPointers.first;
    return null;
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    // A long-press drag inside the text can emit a spurious programmatic
    // scroll even before reaching an edge. Correct that narrow case. Never
    // counter-scroll a real selection-handle drag: doing so races the overlay
    // geometry and was the source of the Android full-screen ErrorWidget.
    if (_selectionGesturePointer != null &&
        !_selectionGestureUsesHandle &&
        _touchSelectionEdgePointer == null &&
        !_selectionViewportCorrectionInFlight &&
        notification is ScrollUpdateNotification &&
        notification.dragDetails == null) {
      final double delta = notification.scrollDelta ?? 0;
      if (delta.abs() >= 0.5) {
        unawaited(_correctInitialSelectionViewportOffset(-delta));
      }
    }
    if (_activePointerCount <= 0) return false;
    if (notification is ScrollUpdateNotification ||
        notification is OverscrollNotification) {
      _didScrollWhilePointerSession = true;
    }
    return false;
  }

  Future<void> _correctInitialSelectionViewportOffset(double offset) async {
    _selectionViewportCorrectionInFlight = true;
    final ScrollOffsetController controller = _isArticleMode
        ? _articleScrollOffsetController
        : _listScrollOffsetController;
    try {
      await controller.animateScroll(
        offset: offset,
        duration: const Duration(milliseconds: 1),
        curve: Curves.linear,
      );
    } catch (_) {
      // The list may detach while switching mode or media.
    } finally {
      _selectionViewportCorrectionInFlight = false;
    }
  }

  int _resolveLocateTargetIndex(int currentIndex) {
    final subtitles = _displaySubtitles;
    if (currentIndex >= 0 && currentIndex < subtitles.length) {
      _pendingLocateIndex = null;
      return currentIndex;
    }

    final int? pendingIndex = _pendingLocateIndex;
    if (pendingIndex != null &&
        pendingIndex >= 0 &&
        pendingIndex < subtitles.length) {
      _pendingLocateIndex = null;
      return pendingIndex;
    }

    return -1;
  }

  String _getFilteredText(String text, int index) {
    if (index >= 0 && index < _selectionTextCache.length) {
      return _selectionTextCache[index];
    }
    return _normalizeTranscriptText(_computeDisplayTextForIndex(index));
  }

  String _computeDisplayTextForIndex(int index) {
    final subtitles = _displaySubtitles;
    if (index < 0 || index >= subtitles.length) return '';
    final String text = _normalizeTranscriptText(subtitles[index].text);
    if (_usesSecondaryTrackForDisplay) {
      return text;
    }
    if (_lineFilterMode == 0) {
      // Dual Mode
      // If we have valid bilingual match, merge them
      if (_isBilingualMode && _secondaryTextCache.containsKey(index)) {
        final String secondary = _secondaryTextCache[index]!;
        if (text.isEmpty) return secondary;
        if (secondary.isEmpty) return text;
        return '$text $secondary';
      }
      return text;
    }

    // Line Split Mode (Legacy or Forced)
    // If we have secondary file but mode is 1 or 2, we might want to toggle files?
    // User logic: "If mode is 1, show Primary. If mode is 2, show Secondary."
    if (widget.secondarySubtitles.isNotEmpty) {
      if (_lineFilterMode == 1) return text;
      if (_lineFilterMode == 2) {
        if (_secondaryTextCache.containsKey(index)) {
          return _secondaryTextCache[index]!;
        }
        return ""; // No match found for this line
      }
    }

    // Fallback to split-by-newline logic (Single File)
    final lines = subtitles[index].text.split(RegExp(r'\r?\n'));
    if (_lineFilterMode == 1) {
      return lines.isNotEmpty ? _normalizeTranscriptText(lines[0]) : '';
    } else if (_lineFilterMode == 2) {
      return lines.length > 1 ? _normalizeTranscriptText(lines[1]) : '';
    }
    return text;
  }

  /// Structured primary/secondary text for copy formatting.
  ///
  /// Mirrors [_computeDisplayTextForIndex] so the joined display string stays
  /// identical to the SelectionArea `plainText`, while still exposing the
  /// bilingual boundary that a flattened copy cannot recover.
  SubtitleCueCopyParts _computeCueCopyPartsForIndex(int index) {
    final subtitles = _displaySubtitles;
    if (index < 0 || index >= subtitles.length) {
      return SubtitleCueCopyParts.empty;
    }
    final SubtitleItem item = subtitles[index];
    final String text = _normalizeTranscriptText(item.text);
    SubtitleCueCopyParts parts;
    if (_usesSecondaryTrackForDisplay) {
      parts = SubtitleCueCopyParts(primary: text, secondary: '');
    } else if (_lineFilterMode == 0) {
      if (_isBilingualMode && _secondaryTextCache.containsKey(index)) {
        parts = SubtitleCueCopyParts(
          primary: text,
          secondary: _secondaryTextCache[index]!,
        );
      } else {
        parts = SubtitleCueCopyParts(primary: text, secondary: '');
      }
    } else if (widget.secondarySubtitles.isNotEmpty) {
      if (_lineFilterMode == 1) {
        parts = SubtitleCueCopyParts(primary: text, secondary: '');
      } else {
        parts = SubtitleCueCopyParts(
          primary: _secondaryTextCache[index] ?? '',
          secondary: '',
        );
      }
    } else {
      final List<String> lines = item.text.split(RegExp(r'\r?\n'));
      if (_lineFilterMode == 1) {
        parts = SubtitleCueCopyParts(
          primary: lines.isNotEmpty ? _normalizeTranscriptText(lines[0]) : '',
          secondary: '',
        );
      } else {
        parts = SubtitleCueCopyParts(
          primary: lines.length > 1 ? _normalizeTranscriptText(lines[1]) : '',
          secondary: '',
        );
      }
    }
    if (parts.isEmpty && item.imageLoader != null) {
      return const SubtitleCueCopyParts(primary: '[图片字幕]', secondary: '');
    }
    return parts;
  }

  /// 这次 onTap 是不是「确认的短单击」，只有这时才允许 seek。
  ///
  /// 过去把 seek 放在 onTapDown：TapGestureRecognizer 按住约 100ms
  /// （[kPressTimeout]）就会触发，于是长按、按住再滑、鼠标拖选用字都会先跳转。
  /// 现在只在手势竞技场确认这是一次 tap 之后，再拿 Listener 记下的时长/位移
  /// 做一次核对：
  ///   - 副指针 / 已交给双击识别器的轻点：不 seek；
  ///   - 按住超过 [_rowTapMaxDurationMs]：长按/选字，不 seek；
  ///   - 位移超过设备对应 slop：滑动浏览或拖选用字，不 seek。
  bool _isConfirmedSubtitleClick(int index) {
    if (_shouldDeferRowTap(index)) return false;
    if (_suppressedRowTapIndex == index) return false;
    final _SidebarPointerRecord? lifted = _lastLiftedPointer;
    if (lifted == null) {
      // Listener 没看到这次抬起时，仍信任手势竞技场判出的 onTap。
      return true;
    }
    if (lifted.anchorPointerIds.isNotEmpty) return false;
    if (_lastLiftedHeldMs >= _rowTapMaxDurationMs) return false;
    if (lifted.maxTravel > _rowTapMaxTravelFor(lifted.kind)) return false;
    return true;
  }

  /// 鼠标/触控板用更紧的 slop：拖选用字通常只有几个像素，也必须跟单击分开。
  double _rowTapMaxTravelFor(PointerDeviceKind kind) {
    switch (kind) {
      case PointerDeviceKind.mouse:
      case PointerDeviceKind.trackpad:
        return kPrecisePointerHitSlop;
      default:
        return kTouchSlop;
    }
  }

  /// 确认是单击之后才 seek，并（在自动跟随开启时）把文稿滚到那一句。
  void _completeSubtitleTap(int index) {
    if (_hasTextSelection || _pointerSessionStartedWithTextSelection) {
      _pointerSessionStartedWithTextSelection = false;
      clearTextSelection();
      widget.onClearSelection?.call();
      _suppressedRowTapIndex = null;
      return;
    }
    // 拖拽会话中的副指针轻点、长按、滑动选字都不能落地常规 seek。
    if (!_isConfirmedSubtitleClick(index)) {
      _suppressedRowTapIndex = null;
      return;
    }
    _suppressedRowTapIndex = null;
    _commitConfirmedSubtitleTap(index);
  }

  void _commitConfirmedSubtitleTap(int index) {
    final subtitles = _displaySubtitles;
    if (index < 0 || index >= subtitles.length) return;

    final item = subtitles[index];
    widget.onClearSelection?.call();
    // onItemTap 的接收方把参数当作视频时间直接 seek，字幕时间需加上
    // 延迟换算，才能让画面字幕与点击项一致。
    widget.onItemTap?.call(
      item.startTime + Duration(milliseconds: _subtitleOffsetMs),
    );
    Future.microtask(() => widget.focusNode?.requestFocus());
    _pointerDownSubtitleIndex = null;
    _locateTappedSubtitle(index);
  }

  void _locateTappedSubtitle(int index) {
    if (index < 0 || index >= _displaySubtitles.length) return;
    _invalidateLocateRequests();
    _cancelPendingAutoScroll();
    _pendingLocateIndex = index;
    _markManualLocateLock(index);
    _markManualLocateAutoFollowCooldown();
    _markManualAnimationFreeze(index, animated: true);
    _markAutoScrollSuppressedForIndex(index);
    _activeIndexNotifier.value = index;
    final List<int> tappedIndices = <int>[index];
    if (!_isSameIndices(tappedIndices, _activeIndicesNotifier.value)) {
      _activeIndicesNotifier.value = tappedIndices;
    }
    // 关闭自动跟随时，点击只负责 seek，不把文稿滚到当前句，
    // 避免打断用户正在浏览的字幕列表。手动「定位」按钮仍可随时对齐。
    if (!SettingsService().autoScrollSubtitles) return;
    lastTappedLocateScrollIndex = index;
    _scrollToIndex(index, isAuto: false, preferSingleStage: true);
  }

  void _scrollToActiveIndex({bool isAuto = false}) {
    if (_isBeforeFirstSubtitleAtMs(_subtitleTimelinePositionMs)) {
      _locateBeforeFirstSubtitleAtTop();
      return;
    }
    final index = _activeIndexNotifier.value;
    if (index < 0 || index >= _displaySubtitles.length) return;
    _scrollToIndex(index, isAuto: isAuto);
  }

  void _scrollToIndex(
    int index, {
    bool isAuto = false,
    bool preferSingleStage = false,
  }) {
    if (index < 0 || index >= _displaySubtitles.length) return;
    if (!widget.isVisible ||
        !_isSubtitleSidebarRouteCurrent ||
        !_isScrollableViewportUsable()) {
      return;
    }
    final controller = _isArticleMode
        ? _articleItemScrollController
        : _itemScrollController;
    if (!controller.isAttached) return;
    final targetIndex = _isArticleMode
        ? _articleItemIndexForSubtitle(index)
        : index;
    if (targetIndex < 0) return;
    // scrollable_positioned_list 0.3.8 uses a second list and a deferred
    // opacity animation when the target has not been laid out. A repair jump
    // can remove that second list before its post-mount callback runs. The
    // callback then fades the remaining list to zero permanently, even though
    // ItemPositions still reports visible rows. Request IDs cannot cancel
    // callbacks owned by the package. Only animate targets with known geometry
    // so every animation uses its single-list animateTo path.
    if (!_currentItemPositions().any(
      (position) => position.index == targetIndex,
    )) {
      _jumpToActiveIndexWithAlignment(index);
      return;
    }
    if (_isArticleMode) {
      final chunkIndex = _articleItemIndexForSubtitle(index);
      if (chunkIndex < 0) return;

      if (preferSingleStage &&
          _shouldPreferJumpForManualLocate(
            targetIndex: chunkIndex,
            isArticleMode: true,
          )) {
        _jumpToActiveIndexWithAlignment(index);
        return;
      }

      final double effectiveAlignment = _resolveReachableAlignment(
        targetIndex: chunkIndex,
        isArticleMode: true,
        requestedAlignment: _locateAlignment,
      );
      if (_shouldSkipScrollAnimation(
        targetIndex: chunkIndex,
        isArticleMode: true,
        alignment: effectiveAlignment,
      )) {
        return;
      }

      _articleItemScrollController.scrollTo(
        index: chunkIndex,
        duration: isAuto
            ? const Duration(milliseconds: 200)
            : const Duration(milliseconds: 220),
        curve: Curves.easeInOut,
        alignment: effectiveAlignment,
      );
    } else {
      if (preferSingleStage &&
          _shouldPreferJumpForManualLocate(
            targetIndex: index,
            isArticleMode: false,
          )) {
        _jumpToActiveIndexWithAlignment(index);
        return;
      }

      final double effectiveAlignment = _resolveReachableAlignment(
        targetIndex: index,
        isArticleMode: false,
        requestedAlignment: _locateAlignment,
      );
      if (_shouldSkipScrollAnimation(
        targetIndex: index,
        isArticleMode: false,
        alignment: effectiveAlignment,
      )) {
        return;
      }
      _itemScrollController.scrollTo(
        index: index,
        duration: isAuto
            ? const Duration(milliseconds: 200)
            : const Duration(milliseconds: 220),
        curve: Curves.easeInOut,
        alignment: effectiveAlignment,
      );
    }
  }

  bool _shouldPreferJumpForManualLocate({
    required int targetIndex,
    required bool isArticleMode,
  }) {
    final positions = isArticleMode
        ? _articleItemPositionsListener.itemPositions.value
        : _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return false;

    int minIndex = 1 << 30;
    int maxIndex = -1;
    for (final pos in positions) {
      if (pos.index < minIndex) minIndex = pos.index;
      if (pos.index > maxIndex) maxIndex = pos.index;
    }
    if (maxIndex < 0) return false;

    final int distance;
    if (targetIndex < minIndex) {
      distance = minIndex - targetIndex;
    } else if (targetIndex > maxIndex) {
      distance = targetIndex - maxIndex;
    } else {
      distance = 0;
    }

    final int jumpThreshold = isArticleMode ? 1 : 6;
    return distance > jumpThreshold;
  }

  void _jumpToActiveIndexWithAlignment(int index) {
    if (index < 0 || index >= _displaySubtitles.length) return;

    if (_isArticleMode) {
      final int chunkIndex = _articleItemIndexForSubtitle(index);
      if (chunkIndex < 0) return;
      if (!_articleItemScrollController.isAttached) return;
      final double effectiveAlignment = _resolveReachableAlignment(
        targetIndex: chunkIndex,
        isArticleMode: true,
        requestedAlignment: _locateAlignment,
      );
      if (_shouldSkipScrollAnimation(
        targetIndex: chunkIndex,
        isArticleMode: true,
        alignment: effectiveAlignment,
      )) {
        return;
      }
      _articleItemScrollController.jumpTo(
        index: chunkIndex,
        alignment: effectiveAlignment,
      );
      return;
    }

    if (!_itemScrollController.isAttached) return;
    final double effectiveAlignment = _resolveReachableAlignment(
      targetIndex: index,
      isArticleMode: false,
      requestedAlignment: _locateAlignment,
    );
    if (_shouldSkipScrollAnimation(
      targetIndex: index,
      isArticleMode: false,
      alignment: effectiveAlignment,
    )) {
      return;
    }
    _itemScrollController.jumpTo(index: index, alignment: effectiveAlignment);
  }

  double _resolveReachableAlignment({
    required int targetIndex,
    required bool isArticleMode,
    required double requestedAlignment,
  }) {
    final positions = isArticleMode
        ? _articleItemPositionsListener.itemPositions.value
        : _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return requestedAlignment;

    final int itemCount = isArticleMode
        ? _articleItemCount
        : _displaySubtitles.length;
    if (itemCount <= 0) return requestedAlignment;

    ItemPosition? targetPosition;
    ItemPosition? firstPosition;
    ItemPosition? lastPosition;
    for (final position in positions) {
      if (position.index == targetIndex) targetPosition = position;
      if (position.index == 0) firstPosition = position;
      if (position.index == itemCount - 1) lastPosition = position;
    }
    if (targetPosition == null) return requestedAlignment;

    double minimumAlignment = 0.0;
    double maximumAlignment = 1.0;
    if (lastPosition != null) {
      final double extentFromTargetThroughBottom =
          lastPosition.itemTrailingEdge - targetPosition.itemLeadingEdge;
      minimumAlignment = (1.0 - extentFromTargetThroughBottom).clamp(0.0, 1.0);
    }
    if (firstPosition != null) {
      final double extentFromTopThroughTarget =
          targetPosition.itemLeadingEdge - firstPosition.itemLeadingEdge;
      maximumAlignment = extentFromTopThroughTarget.clamp(0.0, 1.0);
    }

    // When the entire document fits in the viewport there is no scrollable
    // range. Its only stable position is the natural top-aligned layout.
    if (minimumAlignment > maximumAlignment) return maximumAlignment;
    return requestedAlignment.clamp(minimumAlignment, maximumAlignment);
  }

  bool _shouldSkipScrollAnimation({
    required int targetIndex,
    required bool isArticleMode,
    required double alignment,
  }) {
    final positions = isArticleMode
        ? _articleItemPositionsListener.itemPositions.value
        : _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return false;

    double? targetLeading;

    for (final pos in positions) {
      if (pos.index == targetIndex) {
        targetLeading = pos.itemLeadingEdge;
        break;
      }
    }

    if (targetLeading == null) return false;

    const double epsilon = 0.0001;
    return (targetLeading - alignment).abs() <= epsilon;
  }

  void jumpToFirstSubtitleTop() {
    if (_displaySubtitles.isEmpty) return;
    _activeIndexNotifier.value = 0;
    _jumpToIndexTopInternal(targetIndex: 0, attempt: 0);
  }

  void _jumpToIndexTopInternal({
    required int targetIndex,
    required int attempt,
  }) {
    if (!mounted) return;
    const int maxAttempts = 6;
    if (_isArticleMode) {
      if (!_articleItemScrollController.isAttached) {
        if (attempt < maxAttempts) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _jumpToIndexTopInternal(
              targetIndex: targetIndex,
              attempt: attempt + 1,
            );
          });
        }
        return;
      }
      final int chunkIndex = _articleItemIndexForSubtitle(targetIndex);
      if (chunkIndex < 0) return;
      _articleItemScrollController.jumpTo(index: chunkIndex, alignment: 0.0);
    } else {
      if (!_itemScrollController.isAttached) {
        if (attempt < maxAttempts) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _jumpToIndexTopInternal(
              targetIndex: targetIndex,
              attempt: attempt + 1,
            );
          });
        }
        return;
      }
      _itemScrollController.jumpTo(index: targetIndex, alignment: 0.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Spacing logic
    final double spacing = 0.0; // Zero spacing for compactness
    final bool isSmallScreen = MediaQuery.sizeOf(context).width < 600;
    final settings = SettingsService();

    return Focus(
      canRequestFocus: false,
      descendantsAreFocusable: true,
      child: Container(
        width: double.infinity,
        color: const Color(0xFF1E1E1E), // 深色背景
        child: Material(
          color: Colors.transparent,
          child: GestureDetector(
            onTap: () {
              clearTextSelection();
              widget.onClearSelection?.call();
              widget.focusNode?.requestFocus();
            },
            behavior: HitTestBehavior.translucent,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: _onPointerUpOrCancel,
              onPointerCancel: _onPointerUpOrCancel,
              child: Column(
                children: [
                  // 1. 顶部栏 (切换模式 + 过滤 + 关闭)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment
                        .stretch, // Ensure content stretches or aligns start
                    children: [
                      Container(
                        // Reduced vertical padding significantly
                        padding: const EdgeInsets.symmetric(
                          horizontal: 0,
                          vertical: 0,
                        ),
                        decoration: const BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: Colors.white10),
                          ),
                        ),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            mainAxisAlignment:
                                MainAxisAlignment.start, // Left aligned
                            children: [
                              // 视图模式切换
                              Tooltip(
                                message: "切换列表/文章视图",
                                child: _buildCompactToggle(
                                  isSmallScreen: isSmallScreen,
                                  children: [
                                    _buildToggleItem(
                                      Icons.list,
                                      _isArticleMode == false,
                                    ),
                                    _buildToggleItem(
                                      Icons.article,
                                      _isArticleMode == true,
                                    ),
                                  ],
                                  onTap: (index) {
                                    final isArticle = index == 1;
                                    _clearTextSelection(
                                      resumeAutoFollow: false,
                                    );
                                    setState(() => _isArticleMode = isArticle);
                                    SettingsService().updateSetting(
                                      'subtitleViewMode',
                                      isArticle ? 1 : 0,
                                    );
                                    _triggerLocateButtonAfterModeSwitch();
                                  },
                                  selectedIndex: _isArticleMode ? 1 : 0,
                                ),
                              ),

                              SizedBox(width: spacing),

                              // 语言/行过滤
                              Tooltip(
                                message: "切换双语/单行显示",
                                child: _buildCompactToggle(
                                  isSmallScreen: isSmallScreen,
                                  children: [
                                    const Text(
                                      "双",
                                      style: TextStyle(fontSize: 9),
                                    ), // Larger
                                    const Text(
                                      "1",
                                      style: TextStyle(fontSize: 9),
                                    ), // Larger
                                    const Text(
                                      "2",
                                      style: TextStyle(fontSize: 9),
                                    ), // Larger
                                  ],
                                  onTap: (index) {
                                    _clearTextSelection(
                                      resumeAutoFollow: false,
                                    );
                                    setState(() {
                                      _lineFilterMode = index;
                                      _invalidateDisplaySubtitlesCache();
                                    });
                                    _rebuildTimelineResolver();
                                    _triggerLocateButtonAfterModeSwitch();
                                  },
                                  selectedIndex: _lineFilterMode,
                                ),
                              ),

                              SizedBox(width: spacing),

                              // 字体设置按钮
                              _buildCompactIconButton(
                                icon: Icons.format_size,
                                isActive: _showFontSettings,
                                onTap: () {
                                  setState(() {
                                    _showFontSettings = !_showFontSettings;
                                  });
                                },
                                tooltip: "设置",
                              ),

                              SizedBox(width: spacing),

                              // 自动跟随按钮 (带 'A' 徽标)
                              Tooltip(
                                message: "自动跟随字幕",
                                child: InkWell(
                                  canRequestFocus: false,
                                  onTap: () {
                                    final newValue =
                                        !settings.autoScrollSubtitles;
                                    settings
                                        .updateSetting(
                                          'autoScrollSubtitles',
                                          newValue,
                                        )
                                        .then((_) {
                                          if (mounted) {
                                            setState(() {}); // Refresh UI
                                          }
                                          if (newValue) {
                                            _scrollToActiveIndex();
                                          }
                                        });
                                  },
                                  child: Container(
                                    width: widget.isPortrait ? 24 : 15,
                                    height: widget.isPortrait
                                        ? 40
                                        : 35, // Slightly larger
                                    alignment: Alignment.center,
                                    child: Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        Icon(
                                          settings.autoScrollSubtitles
                                              ? Icons.gps_fixed
                                              : Icons.gps_not_fixed,
                                          color: settings.autoScrollSubtitles
                                              ? Colors.blueAccent
                                              : Colors.white70,
                                          size: widget.isPortrait
                                              ? 18
                                              : 18, // Slightly larger
                                        ),
                                        if (settings.autoScrollSubtitles)
                                          Positioned(
                                            right: widget.isPortrait ? 0 : 2,
                                            bottom: widget.isPortrait ? 0 : 2,
                                            child: Text(
                                              "A",
                                              style: TextStyle(
                                                fontSize: widget.isPortrait
                                                    ? 6
                                                    : 6, // Slightly larger
                                                fontWeight: FontWeight.bold,
                                                color: Colors.blueAccent,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),

                              SizedBox(width: spacing),

                              // 定位按钮
                              _buildCompactIconButton(
                                icon: Icons.my_location,
                                onTap: () {
                                  clearTextSelection();
                                  _scrollToActiveIndex();
                                },
                                tooltip: "定位到当前字幕",
                              ),

                              SizedBox(width: spacing),

                              // Scan Embedded
                              if (widget.onScanEmbeddedSubtitles != null)
                                _buildCompactIconButton(
                                  icon: Icons.youtube_searched_for,
                                  onTap: widget.onScanEmbeddedSubtitles,
                                  tooltip: "扫描内嵌字幕",
                                ),

                              if (widget.onScanEmbeddedSubtitles != null)
                                SizedBox(width: spacing),

                              // AI 转录按钮 (已移除，移至字幕管理)

                              // 字幕管理按钮 (替代原有的 AI 按钮和导入按钮，或者作为新入口)
                              if (widget.onOpenSubtitleManager != null) ...[
                                Tooltip(
                                  message: "字幕管理 (AI/导入/列表)",
                                  child: InkWell(
                                    canRequestFocus: false,
                                    onTap: widget.onOpenSubtitleManager,
                                    borderRadius: BorderRadius.circular(4),
                                    child: Container(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: widget.isPortrait
                                            ? 4
                                            : (widget.isCompact ? 2 : 4),
                                        vertical: widget.isPortrait ? 4 : 3,
                                      ),
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: Colors.purpleAccent.withValues(
                                            alpha: 0.5,
                                          ),
                                        ),
                                        borderRadius: BorderRadius.circular(4),
                                        color: Colors.purpleAccent.withValues(
                                          alpha: 0.1,
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.subtitles,
                                            size: widget.isPortrait ? 16 : 14,
                                            color: Colors.purpleAccent,
                                          ), // Distinct icon
                                          if (!widget.isPortrait)
                                            SizedBox(width: 4),
                                          if (!widget.isPortrait)
                                            Text(
                                              "字幕库",
                                              style: TextStyle(
                                                color: Colors.purpleAccent,
                                                fontSize: 8,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                SizedBox(width: spacing),
                              ],

                              // 加载本地字幕 (保留作为快捷方式，或者隐藏?)
                              /*
                        Tooltip(
                          message: "导入本地字幕文件",
                          child: GestureDetector(
                            onTap: widget.onLoadSubtitle,
                            child: Container(
                              padding: EdgeInsets.symmetric(horizontal: widget.isPortrait ? 4 : (widget.isCompact ? 2 : 4), vertical: widget.isPortrait ? 4 : 3),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.white30),
                                borderRadius: BorderRadius.circular(4),
                                color: Colors.white10,
                              ),
                              child: widget.isPortrait 
                                ? Icon(Icons.folder_open, size: 16, color: Colors.white)
                                : Text(
                                    widget.isCompact ? "导入" : "导入本地字幕",
                                    style: TextStyle(
                                      color: Colors.white, 
                                      fontSize: 8, 
                                      fontWeight: FontWeight.w500
                                    ),
                                  ),
                            ),
                          ),
                        ),

                        SizedBox(width: spacing),
                        */

                              // 字幕样式设置
                              Tooltip(
                                message: "字幕样式设置",
                                child: InkWell(
                                  canRequestFocus: false,
                                  onTap: widget.onOpenSubtitleStyle,
                                  borderRadius: BorderRadius.circular(4),
                                  child: Container(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: widget.isPortrait
                                          ? 4
                                          : (widget.isCompact ? 2 : 4),
                                      vertical: widget.isPortrait
                                          ? 4
                                          : (widget.isCompact ? 1 : 1),
                                    ),
                                    decoration: BoxDecoration(
                                      border: Border.all(color: Colors.white30),
                                      borderRadius: BorderRadius.circular(4),
                                      color: Colors.white10,
                                    ),
                                    child:
                                        (widget.isCompact || widget.isPortrait)
                                        ? Icon(
                                            Icons.style,
                                            color: Colors.white,
                                            size: widget.isPortrait ? 16 : 14,
                                          )
                                        : const Text(
                                            "字幕设置",
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 8,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                  ),
                                ),
                              ),

                              SizedBox(width: spacing),

                              if (widget.onOpenSubtitleEditor != null) ...[
                                Tooltip(
                                  message: "字幕编辑",
                                  child: InkWell(
                                    canRequestFocus: false,
                                    onTap: widget.onOpenSubtitleEditor,
                                    borderRadius: BorderRadius.circular(4),
                                    child: Container(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: widget.isPortrait
                                            ? 4
                                            : (widget.isCompact ? 2 : 4),
                                        vertical: widget.isPortrait
                                            ? 4
                                            : (widget.isCompact ? 1 : 1),
                                      ),
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: Colors.blueAccent.withValues(
                                            alpha: 0.5,
                                          ),
                                        ),
                                        borderRadius: BorderRadius.circular(4),
                                        color: Colors.blueAccent.withValues(
                                          alpha: 0.1,
                                        ),
                                      ),
                                      child:
                                          (widget.isCompact ||
                                              widget.isPortrait)
                                          ? Icon(
                                              Icons.edit_note,
                                              color: Colors.blueAccent,
                                              size: widget.isPortrait ? 16 : 14,
                                            )
                                          : const Text(
                                              "字幕编辑",
                                              style: TextStyle(
                                                color: Colors.blueAccent,
                                                fontSize: 8,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                    ),
                                  ),
                                ),
                                SizedBox(width: spacing),
                              ],

                              if (widget.onOpenVideoCompose != null) ...[
                                Tooltip(
                                  message: "合成视频",
                                  child: InkWell(
                                    canRequestFocus: false,
                                    onTap: widget.onOpenVideoCompose,
                                    borderRadius: BorderRadius.circular(4),
                                    child: Container(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: widget.isPortrait
                                            ? 4
                                            : (widget.isCompact ? 2 : 4),
                                        vertical: widget.isPortrait
                                            ? 4
                                            : (widget.isCompact ? 1 : 1),
                                      ),
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: Colors.orangeAccent.withValues(
                                            alpha: 0.5,
                                          ),
                                        ),
                                        borderRadius: BorderRadius.circular(4),
                                        color: Colors.orangeAccent.withValues(
                                          alpha: 0.1,
                                        ),
                                      ),
                                      child:
                                          (widget.isCompact ||
                                              widget.isPortrait)
                                          ? Icon(
                                              Icons.movie_creation_outlined,
                                              color: Colors.orangeAccent,
                                              size: widget.isPortrait ? 16 : 14,
                                            )
                                          : const Text(
                                              "合成视频",
                                              style: TextStyle(
                                                color: Colors.orangeAccent,
                                                fontSize: 8,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                    ),
                                  ),
                                ),
                                SizedBox(width: spacing),
                              ],

                              if (widget.onOpenOcrSubtitle != null) ...[
                                Tooltip(
                                  message: "OCR 字幕",
                                  child: InkWell(
                                    canRequestFocus: false,
                                    onTap: widget.onOpenOcrSubtitle,
                                    borderRadius: BorderRadius.circular(4),
                                    child: Container(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: widget.isPortrait
                                            ? 4
                                            : (widget.isCompact ? 2 : 4),
                                        vertical: widget.isPortrait ? 4 : 1,
                                      ),
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: Colors.lightBlueAccent
                                              .withValues(alpha: 0.5),
                                        ),
                                        borderRadius: BorderRadius.circular(4),
                                        color: Colors.lightBlueAccent
                                            .withValues(alpha: 0.1),
                                      ),
                                      child:
                                          (widget.isCompact ||
                                              widget.isPortrait)
                                          ? Icon(
                                              Icons.document_scanner_outlined,
                                              color: Colors.lightBlueAccent,
                                              size: widget.isPortrait ? 16 : 14,
                                            )
                                          : const Text(
                                              "OCR 字幕",
                                              style: TextStyle(
                                                color: Colors.lightBlueAccent,
                                                fontSize: 8,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                    ),
                                  ),
                                ),
                                SizedBox(width: spacing),
                              ],

                              // 设置按钮 (Removed Spacer, added directly)
                              SizedBox(width: spacing),

                              _buildCompactIconButton(
                                icon: Icons.settings,
                                onTap: widget.onOpenSettings,
                                tooltip: "设置",
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),

                  // 2. 内容区。设置面板悬浮在文稿之上，不参与高度分配。
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _displaySubtitles.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      widget.showEmbeddedLoadingMessage
                                          ? "已识别到内嵌字幕，\n正在提取中..."
                                          : "暂无字幕",
                                      style: const TextStyle(
                                        color: Colors.white54,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                    if (widget.onOpenSubtitleManager !=
                                        null) ...[
                                      const SizedBox(height: 16),
                                      InkWell(
                                        canRequestFocus: false,
                                        onTap: widget.onOpenSubtitleManager,
                                        borderRadius: BorderRadius.circular(4),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 16,
                                            vertical: 8,
                                          ),
                                          decoration: BoxDecoration(
                                            border: Border.all(
                                              color: Colors.purpleAccent
                                                  .withValues(alpha: 0.5),
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                            color: Colors.purpleAccent
                                                .withValues(alpha: 0.1),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: const [
                                              Icon(
                                                Icons.subtitles,
                                                size: 18,
                                                color: Colors.purpleAccent,
                                              ),
                                              SizedBox(width: 8),
                                              Text(
                                                "查看字幕管理",
                                                style: TextStyle(
                                                  color: Colors.purpleAccent,
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              )
                            // 只给字幕列表区再套一层指针登记：顶部工具栏按钮上的
                            // 手指既不能充当双击的锚点，也不会被当成候选轻点。
                            : Stack(
                                fit: StackFit.expand,
                                children: [
                                  Listener(
                                    behavior: HitTestBehavior.translucent,
                                    onPointerDown:
                                        _onTranscriptContextMenuPointer,
                                    child: SelectionArea(
                                      key: _textSelectionKey,
                                      focusNode: _textSelectionFocusNode,
                                      contextMenuBuilder:
                                          _buildTextSelectionContextMenu,
                                      onSelectionChanged:
                                          _handleTextSelectionChanged,
                                      child: _SelectionStatusObserver(
                                        onStatusChanged:
                                            _handleSelectionRegionStatusChanged,
                                        child: Listener(
                                          behavior: HitTestBehavior.translucent,
                                          onPointerDown: _onListAreaPointerDown,
                                          child: _isArticleMode
                                              ? _buildArticleView(isSmallScreen)
                                              : _buildListView(isSmallScreen),
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (_hasTextSelection)
                                    _buildSelectionPreservingScrollShield(),
                                ],
                              ),
                        if (_showFontSettings)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: _buildFloatingDisplaySettings(),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFloatingDisplaySettings() {
    return Container(
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          Colors.white.withValues(alpha: 0.05),
          const Color(0xFF1E1E1E),
        ),
        border: const Border(bottom: BorderSide(color: Colors.white10)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isVeryNarrow = constraints.maxWidth < 180;
          final labelWidth = isVeryNarrow ? 24.0 : 52.0;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 28,
                child: Row(
                  children: [
                    SizedBox(
                      width: labelWidth,
                      child: Text(
                        isVeryNarrow ? "字" : "字体",
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                    Expanded(
                      child: _FontSizeSliderWidget(
                        fontSizeScale: _fontSizeScale,
                        showValue: !isVeryNarrow,
                        onChanged: (nextScale) {
                          setState(() => _fontSizeScale = nextScale);
                        },
                        onCommit: (nextScale) {
                          final key = widget.isPortrait
                              ? 'portraitSidebarFontSizeScale'
                              : 'landscapeSidebarFontSizeScale';
                          SettingsService().updateSetting(key, nextScale);
                        },
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 28,
                child: Row(
                  children: [
                    SizedBox(
                      width: labelWidth,
                      child: Text(
                        isVeryNarrow ? "定位" : "定位位置",
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                    Expanded(
                      child: _LocatePositionInputWidget(
                        key: ValueKey(
                          'subtitle-locate-position-editor-${widget.isPortrait ? 'portrait' : 'landscape'}',
                        ),
                        value: _locatePositionPercent,
                        onChanged: _updateLocatePositionPercent,
                      ),
                    ),
                  ],
                ),
              ),
              if (_isArticleMode)
                SizedBox(
                  height: 32,
                  child: Semantics(
                    toggled: _articleParagraphModeEnabled,
                    button: true,
                    label: '段落模式',
                    hint: '关闭后连续显示全部字幕',
                    onTap: () => _updateArticleParagraphMode(
                      !_articleParagraphModeEnabled,
                    ),
                    child: GestureDetector(
                      key: const ValueKey('subtitle-paragraph-mode-control'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _updateArticleParagraphMode(
                        !_articleParagraphModeEnabled,
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: labelWidth,
                            child: Text(
                              isVeryNarrow ? "段" : "段落模式",
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.white70,
                              ),
                            ),
                          ),
                          Tooltip(
                            message: "关闭后连续显示全部字幕",
                            child: SizedBox(
                              width: 44,
                              height: 30,
                              child: FittedBox(
                                fit: BoxFit.contain,
                                child: Switch(
                                  key: const ValueKey(
                                    'subtitle-paragraph-mode-switch',
                                  ),
                                  value: _articleParagraphModeEnabled,
                                  onChanged: _updateArticleParagraphMode,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                              ),
                            ),
                          ),
                          if (!isVeryNarrow)
                            const Expanded(
                              child: Text(
                                "关闭后连续显示全部字幕",
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.white54,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (_isArticleMode)
                SizedBox(
                  height: 28,
                  child: Row(
                    children: [
                      SizedBox(
                        width: labelWidth,
                        child: Text(
                          isVeryNarrow ? "句" : "每段",
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                      Expanded(
                        child: IgnorePointer(
                          ignoring: !_articleParagraphModeEnabled,
                          child: Opacity(
                            opacity: _articleParagraphModeEnabled ? 1 : 0.45,
                            child: _SentenceCountInputWidget(
                              value: _articleChunkSize,
                              min: _minArticleChunkSize,
                              max: _maxArticleChunkSize,
                              onChanged: _updateArticleChunkSize,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (!_isArticleMode)
                SizedBox(
                  height: 28,
                  child: Row(
                    children: [
                      SizedBox(
                        width: labelWidth,
                        child: Text(
                          isVeryNarrow ? "时" : "时间",
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                      Tooltip(
                        message: _showTimestamps ? "隐藏时间" : "显示时间",
                        child: InkWell(
                          key: const ValueKey('subtitle-show-time-switch'),
                          borderRadius: BorderRadius.circular(10),
                          onTap: () {
                            final value = !_showTimestamps;
                            setState(() => _showTimestamps = value);
                            final key = widget.isPortrait
                                ? 'portraitSidebarShowTimestamps'
                                : 'landscapeSidebarShowTimestamps';
                            SettingsService().updateSetting(key, value);
                          },
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: Icon(
                              _showTimestamps
                                  ? Icons.circle
                                  : Icons.circle_outlined,
                              size: 12,
                              color: _showTimestamps
                                  ? Colors.blueAccent
                                  : Colors.white38,
                            ),
                          ),
                        ),
                      ),
                      if (_showTimestamps) ...[
                        const SizedBox(width: 4),
                        if (!isVeryNarrow)
                          const SizedBox(
                            width: 36,
                            child: Text(
                              "宽度",
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.white70,
                              ),
                            ),
                          ),
                        Expanded(
                          child: _TimeColumnRatioSliderWidget(
                            ratio: _timeColumnRatio,
                            showValue: !isVeryNarrow,
                            onChanged: (nextRatio) {
                              setState(() => _timeColumnRatio = nextRatio);
                            },
                            onCommit: (nextRatio) {
                              final key = widget.isPortrait
                                  ? 'portraitSidebarTimeColumnRatio'
                                  : 'landscapeSidebarTimeColumnRatio';
                              SettingsService().updateSetting(key, nextRatio);
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildCompactToggle({
    required List<Widget> children,
    required Function(int) onTap,
    required int selectedIndex,
    required bool isSmallScreen,
  }) {
    // Portrait mode: larger touch targets
    final double height = widget.isPortrait ? 28.0 : (isSmallScreen ? 20 : 22);

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(children.length, (index) {
          final isSelected = selectedIndex == index;
          return InkWell(
            canRequestFocus: false,
            onTap: () => onTap(index),
            borderRadius: BorderRadius.circular(3),
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: widget.isPortrait ? 6 : (isSmallScreen ? 4 : 6),
              ),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isSelected ? Colors.blueAccent : Colors.transparent,
                borderRadius: BorderRadius.circular(3),
              ),
              child: DefaultTextStyle(
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.white60,
                  fontSize: widget.isPortrait ? 11 : (isSmallScreen ? 10 : 11),
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
                child: IconTheme(
                  data: IconThemeData(
                    size: widget.isPortrait ? 14 : (isSmallScreen ? 12 : 13),
                    color: isSelected ? Colors.white : Colors.white60,
                  ),
                  child: children[index],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildToggleItem(IconData icon, bool isSelected) {
    return Icon(icon);
  }

  Widget _buildCompactIconButton({
    required IconData icon,
    VoidCallback? onTap,
    String? tooltip,
    bool isActive = false,
  }) {
    // Portrait mode: larger touch targets
    final double size = widget.isPortrait ? 28.0 : 28.0;
    final double iconSize = widget.isPortrait ? 18.0 : 18.0;

    final child = InkWell(
      canRequestFocus: false,
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        child: Icon(
          icon,
          color: isActive ? Colors.blueAccent : Colors.white70,
          size: iconSize,
        ),
      ),
    );

    if (tooltip != null && tooltip.isNotEmpty) {
      return Tooltip(message: tooltip, child: child);
    }

    return child;
  }

  double _subtitleTextFontSize(bool isSmallScreen) {
    return (isSmallScreen ? 12.0 : 13.0) * _fontSizeScale;
  }

  double _listItemLayoutScale() {
    return _fontSizeScale < 1.0 ? _fontSizeScale : _fontSizeScale * 0.9;
  }

  double _subtitleTextHorizontalInset(bool isSmallScreen) {
    final double outerInset = isSmallScreen ? 2.0 : 6.0;
    const double listItemBorderWidth = 1.0;
    final double innerInset =
        (isSmallScreen ? 6.0 : 8.0) * _listItemLayoutScale();
    return outerInset + listItemBorderWidth + innerInset;
  }

  bool _shouldTopAlignList({
    required double maxHeight,
    required bool isSmallScreen,
    required double innerV,
    required double itemGap,
  }) {
    final displaySubtitles = _displaySubtitles;
    if (displaySubtitles.isEmpty) return true;
    final int lineCount = _lineFilterMode == 0 && _isBilingualMode ? 2 : 1;
    final double fontSize = _subtitleTextFontSize(isSmallScreen);
    final double textHeight = fontSize * 1.6 * lineCount;
    final double estimatedItemHeight =
        textHeight + innerV * 2 + itemGap + (isSmallScreen ? 6 : 8);
    final double estimatedTotalHeight =
        estimatedItemHeight * displaySubtitles.length + itemGap * 2;
    return estimatedTotalHeight <= maxHeight;
  }

  bool _shouldTopAlignArticle({
    required BuildContext context,
    required double maxWidth,
    required double maxHeight,
    required bool isSmallScreen,
    required int chunkCount,
  }) {
    if (chunkCount == 0) return true;

    final double fontSize = _subtitleTextFontSize(isSmallScreen);
    final double horizontalInset = _subtitleTextHorizontalInset(isSmallScreen);
    final double contentWidth = maxWidth - horizontalInset * 2;
    if (contentWidth <= 0) return false;

    final TextStyle defaultTextStyle = DefaultTextStyle.of(context).style;
    final TextStyle articleTextStyle = const TextStyle().copyWith(
      fontSize: fontSize,
      height: 1.6,
      fontWeight: FontWeight.normal,
    );
    final StrutStyle strutStyle = StrutStyle(
      fontSize: fontSize,
      height: 1.6,
      forceStrutHeight: true,
    );
    double laidOutHeight = (isSmallScreen ? 12 : 20) * 2;

    for (int chunkIndex = 0; chunkIndex < chunkCount; chunkIndex++) {
      final int startIndex = chunkIndex * _articleChunkSize;
      final int endIndex = (startIndex + _articleChunkSize).clamp(
        0,
        _displaySubtitles.length,
      );
      final List<InlineSpan> spans = <InlineSpan>[];
      for (int index = startIndex; index < endIndex; index++) {
        final SubtitleItem item = _displaySubtitles[index];
        String text = index < _selectionTextCache.length
            ? _selectionTextCache[index]
            : '';
        if (text.isEmpty && item.imageLoader != null) {
          text = '[图片字幕]';
        }
        text = text.replaceAll(RegExp(r'\s+'), ' ');
        if (text.isEmpty) continue;
        if (spans.isNotEmpty) {
          spans.add(const TextSpan(text: ' '));
        }
        spans.add(TextSpan(text: text, style: articleTextStyle));
      }

      final TextPainter painter = TextPainter(
        text: TextSpan(style: defaultTextStyle, children: spans),
        strutStyle: strutStyle,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.maybeLocaleOf(context),
      )..layout(maxWidth: contentWidth);
      laidOutHeight += painter.height;
      painter.dispose();

      if (laidOutHeight + precisionErrorTolerance > maxHeight) return false;
    }
    return laidOutHeight + precisionErrorTolerance <= maxHeight;
  }

  // 列表模式视图
  Widget _buildListView(bool isSmallScreen) {
    final displaySubtitles = _displaySubtitles;

    // 动态计算间距，随字体大小缩放，使小字体模式更紧凑
    final double scale = _listItemLayoutScale();
    final double innerH = (isSmallScreen ? 6 : 8) * scale; // 内部水平间距
    final double innerV = (isSmallScreen ? 4 : 6) * scale; // 内部垂直间距
    final double itemGap = (isSmallScreen ? 2 : 4) * scale; // 列表项间距
    final double timeGap = (isSmallScreen ? 6 : 8) * scale; // 时间戳和文本的间距

    return LayoutBuilder(
      builder: (context, constraints) {
        _handleScrollableViewportLayout(constraints);
        final bool shouldTopAlign = _shouldTopAlignList(
          maxHeight: constraints.maxHeight,
          isSmallScreen: isSmallScreen,
          innerV: innerV,
          itemGap: itemGap,
        );
        // 当字幕数量不足时，强制从顶部开始显示，忽略当前索引
        final int currentIndex = _activeIndexNotifier.value;
        final int effectiveInitialIndex = shouldTopAlign
            ? 0
            : (currentIndex >= 0 ? currentIndex : 0);
        final double effectiveInitialAlignment = shouldTopAlign
            ? 0.0
            : _locateAlignment;

        final list = NotificationListener<ScrollNotification>(
          onNotification: _handleScrollNotification,
          // KeyedSubtree 不产生 RenderObject，findRenderObject 会直接拿到列表
          // 自身的盒子（正好等于视口），供 [_resolveRowIndexAt] 做比例换算。
          child: KeyedSubtree(
            key: _listViewportKey,
            child: ScrollablePositionedList.builder(
              itemScrollController: _itemScrollController,
              itemPositionsListener: _itemPositionsListener,
              scrollOffsetController: _listScrollOffsetController,
              initialScrollIndex: effectiveInitialIndex,
              initialAlignment: effectiveInitialAlignment,
              itemCount: displaySubtitles.length,
              shrinkWrap: shouldTopAlign,
              physics: shouldTopAlign
                  ? const NeverScrollableScrollPhysics()
                  : null,
              itemBuilder: (context, index) {
                final item = displaySubtitles[index];
                final timeText = _formatDuration(item.startTime);
                final subtitleText =
                    (item.text.isEmpty && item.imageLoader != null)
                    ? "[图片字幕]"
                    : _getFilteredText(item.text, index);
                return _keepSelectionNodeAlive(
                  ValueListenableBuilder<List<int>>(
                    valueListenable: _activeIndicesNotifier,
                    builder: (context, activeIndices, _) {
                      final isCurrent = activeIndices.contains(index);

                      return RepaintBoundary(
                        child: Padding(
                          padding: EdgeInsets.only(
                            left: isSmallScreen ? 2 : 6,
                            right: isSmallScreen ? 2 : 6,
                            bottom: itemGap,
                          ),
                          child: InkWell(
                            // 不能用 onTapDown：按住约 100ms 就会触发，长按/
                            // 滑动浏览/拖选用字都会被误判成单击并 seek。
                            onTap: () => _completeSubtitleTap(index),
                            canRequestFocus: false,
                            borderRadius: BorderRadius.circular(4),
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: innerH,
                                vertical: innerV,
                              ),
                              decoration: BoxDecoration(
                                color: isCurrent
                                    ? Colors.blueAccent.withValues(alpha: 0.15)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: isCurrent
                                      ? Colors.blueAccent.withValues(alpha: 0.3)
                                      : Colors.transparent,
                                ),
                              ),
                              child: LayoutBuilder(
                                builder: (context, itemConstraints) {
                                  final timeColumnWidth =
                                      itemConstraints.maxWidth *
                                      _timeColumnRatio;
                                  return Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (_showTimestamps)
                                        SelectionContainer.disabled(
                                          child: SizedBox(
                                            key: ValueKey(
                                              'subtitle-time-column-$index',
                                            ),
                                            width: timeColumnWidth,
                                            child: Padding(
                                              padding: EdgeInsets.only(
                                                top: 2 * scale,
                                                right: timeGap,
                                              ),
                                              child: Align(
                                                alignment: Alignment.topLeft,
                                                child: FittedBox(
                                                  fit: BoxFit.scaleDown,
                                                  alignment: Alignment.topLeft,
                                                  child: Text(
                                                    timeText,
                                                    key: ValueKey(
                                                      'subtitle-time-$index',
                                                    ),
                                                    maxLines: 1,
                                                    style: TextStyle(
                                                      color: isCurrent
                                                          ? Colors.blueAccent
                                                          : Colors.white30,
                                                      fontSize:
                                                          (isSmallScreen
                                                              ? 10
                                                              : 11) *
                                                          _fontSizeScale,
                                                      fontFamily: 'monospace',
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      Expanded(
                                        child: Stack(
                                          clipBehavior: Clip.none,
                                          children: [
                                            Text(
                                              subtitleText,
                                              strutStyle: StrutStyle(
                                                fontSize: _subtitleTextFontSize(
                                                  isSmallScreen,
                                                ),
                                                height: 1.3,
                                                forceStrutHeight: true,
                                              ),
                                              style: TextStyle(
                                                color: isCurrent
                                                    ? Colors.white
                                                    : Colors.white70,
                                                fontSize: _subtitleTextFontSize(
                                                  isSmallScreen,
                                                ),
                                                height: 1.3,
                                                fontWeight: FontWeight.normal,
                                              ),
                                            ),
                                            if (_hasSelectableTextAfter(index))
                                              Positioned(
                                                right: 0,
                                                bottom: 0,
                                                child: Text(
                                                  ' ',
                                                  key: ValueKey(
                                                    'subtitle-separator-$index',
                                                  ),
                                                  // This selectable spacer keeps
                                                  // copied cues separated without
                                                  // painting an isolated blue
                                                  // selection bar at the far edge
                                                  // of the row.
                                                  selectionColor:
                                                      Colors.transparent,
                                                  style: TextStyle(
                                                    fontSize:
                                                        _subtitleTextFontSize(
                                                          isSmallScreen,
                                                        ),
                                                    height: 1.3,
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        );
        return shouldTopAlign
            ? Align(alignment: Alignment.topCenter, child: list)
            : list;
      },
    );
  }

  // 文章模式视图
  Widget _buildArticleView(bool isSmallScreen) {
    if (_isContinuousArticleMode) {
      return _buildContinuousArticleView(isSmallScreen);
    }
    final displaySubtitles = _displaySubtitles;
    final int chunkCount = (displaySubtitles.length / _articleChunkSize).ceil();
    final int activeIndex = _activeIndexNotifier.value;
    final int initialChunkIndex = (activeIndex >= 0
        ? (activeIndex ~/ _articleChunkSize)
        : 0);

    return LayoutBuilder(
      builder: (context, constraints) {
        _handleScrollableViewportLayout(constraints);
        final bool shouldTopAlign = _shouldTopAlignArticle(
          context: context,
          maxWidth: constraints.maxWidth,
          maxHeight: constraints.maxHeight,
          isSmallScreen: isSmallScreen,
          chunkCount: chunkCount,
        );
        // 当字幕数量不足时，强制从顶部开始显示，忽略当前索引
        final int effectiveInitialChunkIndex = shouldTopAlign
            ? 0
            : (initialChunkIndex < chunkCount ? initialChunkIndex : 0);
        final double effectiveInitialAlignment = shouldTopAlign
            ? 0.0
            : _locateAlignment;

        final list = NotificationListener<ScrollNotification>(
          onNotification: _handleScrollNotification,
          child: KeyedSubtree(
            key: _listViewportKey,
            child: ScrollablePositionedList.builder(
              key: ValueKey('subtitle-article-list-$_articleChunkSize'),
              itemScrollController: _articleItemScrollController,
              itemPositionsListener: _articleItemPositionsListener,
              scrollOffsetController: _articleScrollOffsetController,
              initialScrollIndex: effectiveInitialChunkIndex,
              initialAlignment: effectiveInitialAlignment,
              itemCount: chunkCount,
              padding: EdgeInsets.symmetric(
                horizontal: _subtitleTextHorizontalInset(isSmallScreen),
              ),
              shrinkWrap: shouldTopAlign,
              physics: shouldTopAlign
                  ? const NeverScrollableScrollPhysics()
                  : null,
              itemBuilder: (context, chunkIndex) {
                final int startIndex = chunkIndex * _articleChunkSize;
                final int endIndex =
                    (startIndex + _articleChunkSize) > displaySubtitles.length
                    ? displaySubtitles.length
                    : startIndex + _articleChunkSize;

                return _keepSelectionNodeAlive(
                  ValueListenableBuilder<List<int>>(
                    valueListenable: _activeIndicesNotifier,
                    builder: (context, activeIndices, child) {
                      final double verticalInset = isSmallScreen ? 12 : 20;
                      return RepaintBoundary(
                        child: Padding(
                          padding: EdgeInsets.only(
                            top: chunkIndex == 0 ? verticalInset : 0,
                            bottom: chunkIndex == chunkCount - 1
                                ? verticalInset
                                : 0,
                          ),
                          child: SubtitleArticleChunk(
                            key: _articleChunkKeys.putIfAbsent(
                              chunkIndex,
                              () => GlobalKey<State<SubtitleArticleChunk>>(),
                            ),
                            subtitles: displaySubtitles,
                            displayTexts: _selectionTextCache,
                            startIndex: startIndex,
                            endIndex: endIndex,
                            activeIndices: activeIndices.toSet(),
                            fontSizeScale: _fontSizeScale,
                            onSubtitleTap: _completeSubtitleTap,
                            isSmallScreen: isSmallScreen,
                            lineFilterMode: _lineFilterMode,
                            secondaryTextCache: _secondaryTextCache,
                            isBilingualMode: _isBilingualMode,
                            usesSecondaryTrackForDisplay:
                                _usesSecondaryTrackForDisplay,
                            appendTrailingSeparator: _hasSelectableTextAfter(
                              endIndex - 1,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        );
        return shouldTopAlign
            ? Align(alignment: Alignment.topCenter, child: list)
            : list;
      },
    );
  }

  Widget _buildContinuousArticleView(bool isSmallScreen) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _handleScrollableViewportLayout(constraints);
        final double horizontalInset = _subtitleTextHorizontalInset(
          isSmallScreen,
        );
        final double contentWidth = (constraints.maxWidth - horizontalInset * 2)
            .clamp(1.0, double.infinity)
            .toDouble();
        final double fontSize = (isSmallScreen ? 12 : 13) * _fontSizeScale;
        final TextStyle style = TextStyle(
          color: Colors.white70,
          fontSize: fontSize,
          height: 1.6,
          fontWeight: FontWeight.normal,
        );
        final document = _continuousArticleDocument;
        if (document == null) return const SizedBox.shrink();
        final layoutKey = ArticleLayoutKey(
          documentGeneration: document.generation,
          width: contentWidth,
          style: style,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        );
        final ArticleLayout? cachedLayout = _continuousArticleLayout;
        if (cachedLayout != null && _continuousArticleLayoutKey == layoutKey) {
          return _buildResolvedContinuousArticleView(
            document: document,
            layout: cachedLayout,
            style: style,
            horizontalInset: horizontalInset,
            isSmallScreen: isSmallScreen,
          );
        }
        if (_continuousArticleLayoutFuture == null ||
            _continuousArticlePendingKey != layoutKey) {
          final int requestId = ++_continuousArticleLayoutRequestId;
          _continuousArticlePendingKey = layoutKey;
          _continuousArticleLayoutFuture = const ArticleLayoutEngine()
              .layoutIncrementally(
                document: document,
                key: layoutKey,
                isCancelled: () =>
                    !mounted ||
                    requestId != _continuousArticleLayoutRequestId ||
                    !_isContinuousArticleMode ||
                    !widget.isVisible,
              );
        }
        return FutureBuilder<ArticleLayout?>(
          future: _continuousArticleLayoutFuture,
          builder: (context, snapshot) {
            final ArticleLayout? layout = snapshot.data;
            if (layout == null || layout.key != layoutKey) {
              return const Center(
                child: Text(
                  '正在准备文章…',
                  key: ValueKey('subtitle-continuous-article-preparing'),
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              );
            }
            final bool isNewLayout = _continuousArticleLayoutKey != layoutKey;
            _continuousArticleLayout = layout;
            _continuousArticleLayoutKey = layoutKey;
            if (isNewLayout) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted || !_isContinuousArticleMode) return;
                _triggerLocateButtonAfterModeSwitch();
              });
            }
            return _buildResolvedContinuousArticleView(
              document: document,
              layout: layout,
              style: style,
              horizontalInset: horizontalInset,
              isSmallScreen: isSmallScreen,
            );
          },
        );
      },
    );
  }

  Widget _buildResolvedContinuousArticleView({
    required ArticleDocument document,
    required ArticleLayout layout,
    required TextStyle style,
    required double horizontalInset,
    required bool isSmallScreen,
  }) {
    final activeIndex = _activeIndexNotifier.value;
    final initialIndex = activeIndex >= 0 ? activeIndex : 0;
    final double verticalInset = isSmallScreen ? 12 : 20;
    return NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: KeyedSubtree(
        key: _listViewportKey,
        child: ContinuousArticleView(
          key: _continuousArticleViewKey,
          document: document,
          layout: layout,
          style: style,
          highlightStyle: style.copyWith(
            color: Colors.blueAccent,
            backgroundColor: Colors.blueAccent.withValues(alpha: 0.1),
          ),
          activeIndices: _activeIndicesNotifier,
          itemScrollController: _articleItemScrollController,
          itemPositionsListener: _articleItemPositionsListener,
          scrollOffsetController: _articleScrollOffsetController,
          keepSelectionAlive: _hasTextSelection,
          onScrollableChanged: _handleSelectionScrollableChanged,
          onSubtitleTap: _completeSubtitleTap,
          initialSentenceIndex: initialIndex,
          initialAlignment: _locateAlignment,
          padding: EdgeInsets.fromLTRB(
            horizontalInset,
            verticalInset,
            horizontalInset,
            verticalInset,
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "$twoDigitMinutes:$twoDigitSeconds";
  }
}

class _SelectionKeepAlive extends StatefulWidget {
  const _SelectionKeepAlive({required this.keepAlive, required this.child});

  final bool keepAlive;
  final Widget child;

  @override
  State<_SelectionKeepAlive> createState() => _SelectionKeepAliveState();
}

class _SelectionKeepAliveState extends State<_SelectionKeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => widget.keepAlive;

  @override
  void didUpdateWidget(covariant _SelectionKeepAlive oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keepAlive != widget.keepAlive) updateKeepAlive();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class _TranscriptScrollableObserver extends StatefulWidget {
  const _TranscriptScrollableObserver({
    required this.onScrollableChanged,
    required this.child,
  });

  final ValueChanged<ScrollableState> onScrollableChanged;
  final Widget child;

  @override
  State<_TranscriptScrollableObserver> createState() =>
      _TranscriptScrollableObserverState();
}

class _TranscriptScrollableObserverState
    extends State<_TranscriptScrollableObserver> {
  ScrollableState? _scrollable;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = Scrollable.maybeOf(context);
    if (next == null || identical(next, _scrollable)) return;
    _scrollable = next;
    widget.onScrollableChanged(next);
  }

  @override
  void didUpdateWidget(covariant _TranscriptScrollableObserver oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onScrollableChanged != widget.onScrollableChanged &&
        _scrollable != null) {
      widget.onScrollableChanged(_scrollable!);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _SelectionStatusObserver extends StatefulWidget {
  const _SelectionStatusObserver({
    required this.onStatusChanged,
    required this.child,
  });

  final ValueChanged<SelectableRegionSelectionStatus> onStatusChanged;
  final Widget child;

  @override
  State<_SelectionStatusObserver> createState() =>
      _SelectionStatusObserverState();
}

class _SelectionStatusObserverState extends State<_SelectionStatusObserver> {
  ValueListenable<SelectableRegionSelectionStatus>? _notifier;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = SelectableRegionSelectionStatusScope.maybeOf(context);
    if (identical(next, _notifier)) return;
    _notifier?.removeListener(_notifyParent);
    _notifier = next;
    _notifier?.addListener(_notifyParent);
    _notifyParent();
  }

  void _notifyParent() {
    final status = _notifier?.value;
    if (status != null) widget.onStatusChanged(status);
  }

  @override
  void didUpdateWidget(covariant _SelectionStatusObserver oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onStatusChanged != widget.onStatusChanged) {
      _notifyParent();
    }
  }

  @override
  void dispose() {
    _notifier?.removeListener(_notifyParent);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 侧边栏内一根手指按下时的快照，服务于「拖拽中副指针双击」判定。
class _SidebarPointerRecord {
  _SidebarPointerRecord({
    required this.downPosition,
    required this.downTimeMs,
    required this.kind,
    required this.inListArea,
    required this.anchorPointerIds,
    required this.rowIndex,
  });

  /// 落点（全局坐标），用于位移判定与「两次点是否同一根手指」判定。
  final Offset downPosition;

  /// 取自事件时间戳而非墙上时钟，和后续的抬起事件同源，不受帧调度抖动影响。
  final int downTimeMs;

  final PointerDeviceKind kind;

  /// 落点是否在字幕列表区（而非顶部工具栏）。
  final bool inListArea;

  /// 本指针按下瞬间，列表区内已按住的其他指针 id。非空即表示它是副指针。
  final Set<int> anchorPointerIds;

  /// 落点命中的字幕行号；null 表示没落在任何一行上（行间空隙、空白区等）。
  final int? rowIndex;

  /// 离落点的最远距离；超过 slop 即认为这根手指在滑动而非点击。
  double maxTravel = 0;
}

/// 一次已被接受的候选轻点，等待在 300ms 内被第二次轻点凑成双击。
class _SidebarTapRecord {
  const _SidebarTapRecord({
    required this.rowIndex,
    required this.downPosition,
    required this.upTimeMs,
    required this.anchorPointerIds,
  });

  final int rowIndex;
  final Offset downPosition;
  final int upTimeMs;

  /// 第一次轻点时按住的锚定手指；第二次轻点必须与其中至少一根仍然重合。
  final Set<int> anchorPointerIds;
}

class SubtitleArticleChunk extends StatefulWidget {
  final List<SubtitleItem> subtitles;
  final List<String> displayTexts;
  final int startIndex;
  final int endIndex;
  final Set<int> activeIndices;
  final double fontSizeScale;
  final ValueChanged<int>? onSubtitleTap;
  final bool isSmallScreen;
  final int lineFilterMode;
  final Map<int, String> secondaryTextCache;
  final bool isBilingualMode;
  final bool usesSecondaryTrackForDisplay;
  final bool appendTrailingSeparator;

  const SubtitleArticleChunk({
    super.key,
    required this.subtitles,
    required this.displayTexts,
    required this.startIndex,
    required this.endIndex,
    required this.activeIndices,
    required this.fontSizeScale,
    this.onSubtitleTap,
    required this.isSmallScreen,
    required this.lineFilterMode,
    this.secondaryTextCache = const {},
    this.isBilingualMode = false,
    this.usesSecondaryTrackForDisplay = false,
    this.appendTrailingSeparator = false,
  });

  @override
  State<SubtitleArticleChunk> createState() => _SubtitleArticleChunkState();
}

class _SubtitleArticleChunkState extends State<SubtitleArticleChunk> {
  final Map<int, TapGestureRecognizer> _recognizers =
      <int, TapGestureRecognizer>{};

  /// 段落文本的 key，用于把全局坐标换算进 [RenderParagraph]。
  final GlobalKey _paragraphKey = GlobalKey();

  /// 每个 span 对应的字幕行号；[InlineSpan] 用身份相等，可直接做 key。
  final Map<InlineSpan, int> _spanSubtitleIndex = <InlineSpan, int>{};

  /// 把全局坐标定位到本段落内的字幕行号；不在本段落内则返回 null。
  ///
  /// 拖拽期间 Scrollable 会用 IgnorePointer 屏蔽视口内部，span 上的
  /// [TapGestureRecognizer] 收不到事件，只能这样直接问排版结果。
  int? subtitleIndexAtGlobalPosition(Offset globalPosition) {
    final RenderObject? root = _paragraphKey.currentContext?.findRenderObject();
    final RenderParagraph? paragraph = root == null
        ? null
        : _findParagraph(root);
    if (paragraph == null || !paragraph.hasSize) return null;
    final Offset local = paragraph.globalToLocal(globalPosition);
    if (!(Offset.zero & paragraph.size).contains(local)) return null;
    final InlineSpan? span = paragraph.text.getSpanForPosition(
      paragraph.getPositionForOffset(local),
    );
    return span == null ? null : _spanSubtitleIndex[span];
  }

  /// [Text.rich] 外层可能还套着 Semantics 等包装，这里向下找到真正的段落。
  RenderParagraph? _findParagraph(RenderObject object) {
    if (object is RenderParagraph) return object;
    RenderParagraph? found;
    object.visitChildren((RenderObject child) {
      found ??= _findParagraph(child);
    });
    return found;
  }

  @override
  void initState() {
    super.initState();
    _syncRecognizers();
  }

  @override
  void didUpdateWidget(covariant SubtitleArticleChunk oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 仅在索引范围变化时重建 recognizer，回调引用变化不触发重建
    if (oldWidget.startIndex != widget.startIndex ||
        oldWidget.endIndex != widget.endIndex) {
      _disposeRecognizers();
      _syncRecognizers();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _syncRecognizers() {
    if (widget.onSubtitleTap == null) {
      return;
    }
    for (int i = widget.startIndex; i < widget.endIndex; i++) {
      // 只认 onTap：onTapDown 会在按住约 100ms 时触发，长按选字会被误 seek。
      _recognizers[i] = TapGestureRecognizer()
        ..onTap = () {
          widget.onSubtitleTap?.call(i);
        };
    }
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers.values) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    final List<InlineSpan> spans = <InlineSpan>[];
    _spanSubtitleIndex.clear();

    for (int i = widget.startIndex; i < widget.endIndex; i++) {
      final item = widget.subtitles[i];
      final isCurrent = widget.activeIndices.contains(i);
      String rawText = i >= 0 && i < widget.displayTexts.length
          ? widget.displayTexts[i]
          : '';
      if (rawText.isEmpty && item.imageLoader != null) {
        rawText = "[图片字幕]";
      }
      final text = rawText.replaceAll(RegExp(r'\s+'), ' ');
      if (text.isEmpty) continue;
      if (spans.isNotEmpty) {
        spans.add(const TextSpan(text: ' '));
      }
      final TextSpan span = TextSpan(
        text: text,
        recognizer: _recognizers[i],
        style: TextStyle(
          color: isCurrent ? Colors.blueAccent : Colors.white70,
          backgroundColor: isCurrent
              ? Colors.blueAccent.withValues(alpha: 0.1)
              : Colors.transparent,
          fontSize: (widget.isSmallScreen ? 12 : 13) * widget.fontSizeScale,
          height: 1.6,
          // Keep weight stable in article mode to avoid paragraph reflow.
          fontWeight: FontWeight.normal,
        ),
      );
      _spanSubtitleIndex[span] = i;
      spans.add(span);
    }

    final TextStyle separatorStyle = TextStyle(
      fontSize: (widget.isSmallScreen ? 12 : 13) * widget.fontSizeScale,
      height: 1.6,
    );
    return Stack(
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: [
        Text.rich(
          key: _paragraphKey,
          TextSpan(children: spans),
          textAlign: TextAlign.start,
          softWrap: true,
          strutStyle: StrutStyle(
            fontSize: (widget.isSmallScreen ? 12 : 13) * widget.fontSizeScale,
            height: 1.6,
            forceStrutHeight: true,
          ),
        ),
        if (widget.appendTrailingSeparator)
          Positioned(
            right: 0,
            bottom: 0,
            child: Text(
              ' ',
              key: ValueKey('subtitle-article-separator-${widget.startIndex}'),
              selectionColor: Colors.transparent,
              style: separatorStyle,
            ),
          ),
      ],
    );
  }
}

class _LocatePositionInputWidget extends StatefulWidget {
  final int value;
  final ValueChanged<int> onChanged;

  const _LocatePositionInputWidget({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  State<_LocatePositionInputWidget> createState() =>
      _LocatePositionInputWidgetState();
}

class _LocatePositionInputWidgetState
    extends State<_LocatePositionInputWidget> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value.toString());
    _focusNode = FocusNode()..addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _LocatePositionInputWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focusNode.hasFocus && widget.value != oldWidget.value) {
      _setText(widget.value);
    }
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_handleFocusChanged)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    if (!_focusNode.hasFocus) {
      _commitText();
    }
  }

  void _setText(int value) {
    final text = value.toString();
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _handleTextChanged(String text) {
    if (text.isEmpty) return;
    final parsed = int.tryParse(text);
    if (parsed == null) return;
    final value = parsed.clamp(0, 100);
    if (value != parsed) {
      _setText(value);
    }
    widget.onChanged(value);
  }

  void _commitText() {
    final parsed = int.tryParse(_controller.text);
    final value = (parsed ?? widget.value).clamp(0, 100);
    _setText(value);
    widget.onChanged(value);
  }

  void _step(int delta) {
    final parsed = int.tryParse(_controller.text) ?? widget.value;
    final value = (parsed + delta).clamp(0, 100);
    _setText(value);
    widget.onChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    const borderColor = Colors.white24;
    return SizedBox(
      key: const ValueKey('subtitle-locate-position-input'),
      height: 28,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: borderColor),
          borderRadius: BorderRadius.circular(4),
          color: Colors.black.withValues(alpha: 0.16),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('subtitle-locate-position-text-field'),
                controller: _controller,
                focusNode: _focusNode,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(3),
                ],
                maxLines: 1,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, color: Colors.white70),
                cursorColor: Colors.blueAccent,
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: 4),
                ),
                onChanged: _handleTextChanged,
                onSubmitted: (_) => _commitText(),
              ),
            ),
            const Text(
              '%',
              key: ValueKey('subtitle-locate-position-percent-unit'),
              style: TextStyle(fontSize: 11, color: Colors.white60),
            ),
            const SizedBox(width: 4),
            Container(width: 1, color: borderColor),
            SizedBox(
              width: 28,
              child: Column(
                children: [
                  _buildStepButton(
                    key: const ValueKey('subtitle-locate-position-increment'),
                    icon: Icons.keyboard_arrow_up,
                    onTap: () => _step(10),
                  ),
                  _buildStepButton(
                    key: const ValueKey('subtitle-locate-position-decrement'),
                    icon: Icons.keyboard_arrow_down,
                    onTap: () => _step(-10),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStepButton({
    required Key key,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      key: key,
      width: 28,
      height: 14,
      child: InkWell(
        onTap: onTap,
        child: Icon(icon, size: 11, color: Colors.white60),
      ),
    );
  }
}

class _SentenceCountInputWidget extends StatefulWidget {
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  const _SentenceCountInputWidget({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  State<_SentenceCountInputWidget> createState() =>
      _SentenceCountInputWidgetState();
}

class _SentenceCountInputWidgetState extends State<_SentenceCountInputWidget> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value.toString());
    _focusNode = FocusNode()..addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _SentenceCountInputWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focusNode.hasFocus && widget.value != oldWidget.value) {
      _setText(widget.value);
    }
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_handleFocusChanged)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    if (!_focusNode.hasFocus) {
      _commitText();
    }
  }

  void _setText(int value) {
    final text = value.toString();
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _handleTextChanged(String text) {
    if (text.isEmpty) return;
    final parsed = int.tryParse(text);
    if (parsed == null) return;
    final value = parsed.clamp(widget.min, widget.max);
    if (value != parsed) {
      _setText(value);
    }
    widget.onChanged(value);
  }

  void _commitText() {
    final parsed = int.tryParse(_controller.text);
    final value = (parsed ?? widget.value).clamp(widget.min, widget.max);
    _setText(value);
    widget.onChanged(value);
  }

  void _step(int delta) {
    final parsed = int.tryParse(_controller.text) ?? widget.value;
    final value = (parsed + delta).clamp(widget.min, widget.max);
    _setText(value);
    widget.onChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    const borderColor = Colors.white24;
    return SizedBox(
      key: const ValueKey('subtitle-sentences-per-paragraph-input'),
      height: 28,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: borderColor),
          borderRadius: BorderRadius.circular(4),
          color: Colors.black.withValues(alpha: 0.16),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey(
                  'subtitle-sentences-per-paragraph-text-field',
                ),
                controller: _controller,
                focusNode: _focusNode,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                maxLines: 1,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, color: Colors.white70),
                cursorColor: Colors.blueAccent,
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: 4),
                ),
                onChanged: _handleTextChanged,
                onSubmitted: (_) => _commitText(),
              ),
            ),
            Container(width: 1, color: borderColor),
            SizedBox(
              width: 28,
              child: Column(
                children: [
                  _buildStepButton(
                    key: const ValueKey(
                      'subtitle-sentences-per-paragraph-increment',
                    ),
                    icon: Icons.keyboard_arrow_up,
                    onTap: () => _step(1),
                  ),
                  _buildStepButton(
                    key: const ValueKey(
                      'subtitle-sentences-per-paragraph-decrement',
                    ),
                    icon: Icons.keyboard_arrow_down,
                    onTap: () => _step(-1),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStepButton({
    required Key key,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      key: key,
      width: 28,
      height: 14,
      child: InkWell(
        onTap: onTap,
        child: Icon(icon, size: 11, color: Colors.white60),
      ),
    );
  }
}

/// 独立的字体缩放滑块 Widget
///
/// 将 Slider 提取为独立 StatefulWidget，拖动过程中仅自身内部重建，
/// 不触发父级 SubtitleSidebar 的完整 build，降低大列表场景下的帧率抖动。
class _FontSizeSliderWidget extends StatefulWidget {
  /// 当前字体缩放比例（由父级传入，用于外部同步时刷新）
  final double fontSizeScale;

  /// 拖动过程中实时回调
  final ValueChanged<double> onChanged;

  /// 拖动结束后的持久化回调
  final ValueChanged<double> onCommit;
  final bool showValue;

  const _FontSizeSliderWidget({
    required this.fontSizeScale,
    required this.onChanged,
    required this.onCommit,
    this.showValue = true,
  });

  @override
  State<_FontSizeSliderWidget> createState() => _FontSizeSliderWidgetState();
}

class _FontSizeSliderWidgetState extends State<_FontSizeSliderWidget> {
  /// 拖动中的临时滑块值（仅影响 Slider 显示）
  double? _dragValue;

  // 字体缩放比例与滑块值的转换（与父级保持一致）
  double _fontScaleToSliderValue(double scale) {
    final double clamped = scale.clamp(0.5, 3.0).toDouble();
    if (clamped <= 0.7) {
      return ((clamped - 0.5) / 0.2) * 10.0;
    }
    if (clamped <= 1.0) {
      return 10.0 + ((clamped - 0.7) / 0.3) * 60.0;
    }
    return 70.0 + ((clamped - 1.0) / 2.0) * 30.0;
  }

  double _sliderValueToFontScale(double sliderValue) {
    final double clamped = sliderValue.clamp(0.0, 100.0).toDouble();
    if (clamped <= 10.0) {
      return 0.5 + (clamped / 10.0) * 0.2;
    }
    if (clamped <= 70.0) {
      return 0.7 + ((clamped - 10.0) / 60.0) * 0.3;
    }
    return 1.0 + ((clamped - 70.0) / 30.0) * 2.0;
  }

  @override
  Widget build(BuildContext context) {
    final displayScale = _dragValue != null
        ? _sliderValueToFontScale(_dragValue!)
        : widget.fontSizeScale;

    return SizedBox(
      height: 28,
      child: Row(
        children: [
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 9),
                showValueIndicator: ShowValueIndicator.never,
              ),
              child: Slider(
                key: const ValueKey('subtitle-font-size-slider'),
                value: _fontScaleToSliderValue(displayScale),
                min: 0.0,
                max: 100.0,
                activeColor: Colors.blueAccent,
                inactiveColor: Colors.white24,
                onChangeStart: (value) {
                  setState(() => _dragValue = value);
                },
                onChanged: (value) {
                  setState(() => _dragValue = value);
                  widget.onChanged(_sliderValueToFontScale(value));
                },
                onChangeEnd: (value) {
                  setState(() => _dragValue = null);
                  widget.onCommit(_sliderValueToFontScale(value));
                },
              ),
            ),
          ),
          if (widget.showValue)
            SizedBox(
              width: 34,
              child: Text(
                "${(displayScale * 100).round()}%",
                style: const TextStyle(fontSize: 10, color: Colors.white60),
                textAlign: TextAlign.right,
              ),
            ),
        ],
      ),
    );
  }
}

/// 独立的时间列比例滑块，拖动期间仅重建滑块自身。
class _TimeColumnRatioSliderWidget extends StatefulWidget {
  final double ratio;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onCommit;
  final bool showValue;

  const _TimeColumnRatioSliderWidget({
    required this.ratio,
    required this.onChanged,
    required this.onCommit,
    this.showValue = true,
  });

  @override
  State<_TimeColumnRatioSliderWidget> createState() =>
      _TimeColumnRatioSliderWidgetState();
}

class _TimeColumnRatioSliderWidgetState
    extends State<_TimeColumnRatioSliderWidget> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final displayRatio = (_dragValue ?? widget.ratio)
        .clamp(0.05, 0.30)
        .toDouble();

    return SizedBox(
      height: 28,
      child: Row(
        children: [
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 9),
                showValueIndicator: ShowValueIndicator.never,
              ),
              child: Slider(
                key: const ValueKey('subtitle-time-column-slider'),
                value: displayRatio,
                min: 0.05,
                max: 0.30,
                activeColor: Colors.blueAccent,
                inactiveColor: Colors.white24,
                onChangeStart: (value) {
                  setState(() => _dragValue = value);
                },
                onChanged: (value) {
                  setState(() => _dragValue = value);
                  widget.onChanged(value);
                },
                onChangeEnd: (value) {
                  setState(() => _dragValue = null);
                  widget.onCommit(value);
                },
              ),
            ),
          ),
          if (widget.showValue)
            SizedBox(
              width: 34,
              child: Text(
                "${(displayRatio * 100).round()}%",
                style: const TextStyle(fontSize: 10, color: Colors.white60),
                textAlign: TextAlign.right,
              ),
            ),
        ],
      ),
    );
  }
}
