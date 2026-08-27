import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:video_player/video_player.dart';
import '../services/settings_service.dart';
import '../models/subtitle_model.dart';
import '../utils/subtitle_display_resolver.dart';

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

  // 滚动控制器
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener =
      ItemPositionsListener.create();

  // 自动滚动相关
  final ValueNotifier<int> _activeIndexNotifier = ValueNotifier<int>(-1);
  final ValueNotifier<List<int>> _activeIndicesNotifier =
      ValueNotifier<List<int>>(<int>[]);
  final List<int> _subtitleStartMs = <int>[];
  final List<int> _subtitleEffectiveEndMs = <int>[];
  final List<int> _subtitlePrefixMaxEndMs = <int>[];
  int _indexedMediaDurationMs = -1;
  int _lastIndexComputeAtMs = 0;
  int _lastIndexComputePosMs = -1;
  Timer? _autoScrollTimer;
  int _activePointerCount = 0;
  bool _didScrollWhilePointerSession = false;
  int? _pointerDownStartIndex;
  int? _pendingLocateIndex;
  bool _lastKnownIsPlaying = false;
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

  VideoPlayerValue? get _controllerValue => widget.controller?.value;

  Duration get _playbackPosition =>
      widget.positionListenable?.value ??
      _controllerValue?.position ??
      Duration.zero;

  bool get _playbackIsPlaying => _controllerValue?.isPlaying ?? false;

  int get _playbackDurationMs {
    final value = _controllerValue;
    return value != null && value.isInitialized
        ? value.duration.inMilliseconds
        : -1;
  }

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
  final ItemScrollController _articleItemScrollController =
      ItemScrollController();
  final ItemPositionsListener _articleItemPositionsListener =
      ItemPositionsListener.create();

  // Cached matches to avoid O(N^2) or repeated searches
  // Key: Primary Index, Value: Secondary Text
  final Map<int, String> _secondaryTextCache = {};
  final Map<int, int> _primaryToSecondaryIndexCache = {};
  final Map<int, int> _secondaryToPrimaryIndexCache = {};
  final List<String> _displayTextCache = <String>[];
  bool _isBilingualMode = false;

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
    _loadOrientationDisplaySettings();
    _lastKnownIsPlaying = _playbackIsPlaying;
    _attachPlaybackListeners();
    _invalidateDisplaySubtitlesCache();
    _checkBilingualSync();
    _rebuildSubtitleIndex();
  }

  @override
  void didUpdateWidget(SubtitleSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
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
      _invalidateDisplaySubtitlesCache();
      _checkBilingualSync();
      _rebuildSubtitleIndex();
    }
    if (playbackSourceChanged || subtitleContentBecameAvailable) {
      _scheduleLocateAfterMediaOrSubtitleChange();
    }
    if (!oldWidget.isVisible &&
        widget.isVisible &&
        SettingsService().autoScrollSubtitles) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _lastIndexComputeAtMs = 0;
        _lastIndexComputePosMs = -1;
        _updateIndex();
        triggerLocateForAutoFollow();
      });
    }
  }

  void _scheduleLocateAfterMediaOrSubtitleChange() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.isVisible || _displaySubtitles.isEmpty) return;
      locateToCurrentSubtitle(ignorePointer: true);
    });
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
      if (!mounted ||
          !widget.isVisible ||
          !_playbackIsPlaying ||
          !SettingsService().autoScrollSubtitles ||
          _displaySubtitles.isEmpty) {
        return;
      }

      // ScrollablePositionedList preserves the old pixel offset when its
      // viewport is resized. Re-apply the percentage alignment after the new
      // geometry has been painted so entering the portrait player cannot
      // leave the current subtitle visibly lower than the configured target.
      locateToCurrentSubtitle(ignorePointer: true);
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
      _secondaryTextCache[entry.key] = widget
          .secondarySubtitles[entry.value]
          .text
          .replaceAll('\n', ' ');
    }

    final int minimumMatchCount = widget.subtitles.length <= 2
        ? 1
        : ((widget.subtitles.length * 0.2).ceil());
    _isBilingualMode = matchResult.matchCount >= minimumMatchCount;
  }

  @override
  void dispose() {
    _detachPlaybackListeners(widget);
    _activeIndexNotifier.dispose();
    _activeIndicesNotifier.dispose();
    _autoScrollTimer?.cancel();
    super.dispose();
  }

  void _rebuildSubtitleIndex() {
    final subtitles = _displaySubtitles;
    _indexedMediaDurationMs = _playbackDurationMs;
    _subtitleStartMs
      ..clear()
      ..addAll(subtitles.map((e) => e.startTime.inMilliseconds));
    _subtitleEffectiveEndMs.clear();
    _subtitlePrefixMaxEndMs.clear();
    int prefixMaxEndMs = -1;
    for (int i = 0; i < subtitles.length; i++) {
      final SubtitleItem item = subtitles[i];
      int effectiveEndMs = item.endTime.inMilliseconds;
      if (i + 1 < subtitles.length) {
        final int nextStartMs = _subtitleStartMs[i + 1];
        if (nextStartMs > effectiveEndMs) {
          effectiveEndMs = nextStartMs;
        }
      } else if (_indexedMediaDurationMs > effectiveEndMs) {
        effectiveEndMs = _indexedMediaDurationMs;
      }
      _subtitleEffectiveEndMs.add(effectiveEndMs);
      if (effectiveEndMs > prefixMaxEndMs) {
        prefixMaxEndMs = effectiveEndMs;
      }
      _subtitlePrefixMaxEndMs.add(prefixMaxEndMs);
    }
    _displayTextCache
      ..clear()
      ..addAll(
        List<String>.generate(
          subtitles.length,
          _computeDisplayTextForIndex,
          growable: false,
        ),
      );
    _lastIndexComputePosMs = -1;
    if (_pendingLocateIndex != null &&
        (_pendingLocateIndex! < 0 ||
            _pendingLocateIndex! >= subtitles.length)) {
      _pendingLocateIndex = null;
    }
  }

  void _ensureSubtitleIndex() {
    final subtitles = _displaySubtitles;
    final int durationMs = _playbackDurationMs;
    if (_subtitleStartMs.length != subtitles.length ||
        _subtitleEffectiveEndMs.length != subtitles.length ||
        _subtitlePrefixMaxEndMs.length != subtitles.length ||
        _indexedMediaDurationMs != durationMs) {
      _rebuildSubtitleIndex();
    }
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
    final currentPosition = _playbackPosition;
    final int posMs = currentPosition.inMilliseconds;
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    if (!playbackStateChanged && _lastIndexComputePosMs != -1) {
      final int deltaPos = (posMs - _lastIndexComputePosMs).abs();
      final int deltaTime = nowMs - _lastIndexComputeAtMs;
      if (deltaPos < 80 && deltaTime < 80) {
        return;
      }
    }
    _lastIndexComputePosMs = posMs;
    _lastIndexComputeAtMs = nowMs;

    final List<int> activeIndices = _findActiveIndicesMs(
      posMs,
      continuousSubtitleEnabled: true,
    );
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
        SettingsService().autoScrollSubtitles &&
        !isInManualLocateAutoFollowCooldown &&
        !suppressAutoScrollForIndex &&
        !_hasAnyActivePointer) {
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

    final int posMs = target.inMilliseconds;
    final List<int> activeIndices = _findActiveIndicesMs(
      posMs,
      continuousSubtitleEnabled: true,
    );
    if (_isBeforeFirstSubtitleAtMs(posMs)) {
      _cancelPendingAutoScroll();
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

  int _getEffectiveEndTimeMs(int index, bool continuousSubtitleEnabled) {
    final subtitles = _displaySubtitles;
    final item = subtitles[index];
    final int actualEndMs = item.endTime.inMilliseconds;
    if (!continuousSubtitleEnabled) {
      return actualEndMs;
    }
    _ensureSubtitleIndex();
    if (index >= 0 && index < _subtitleEffectiveEndMs.length) {
      return _subtitleEffectiveEndMs[index];
    }
    return actualEndMs;
  }

  int _binarySearchLastStartLE(int posMs) {
    int low = 0;
    int high = _subtitleStartMs.length - 1;
    int ans = -1;
    while (low <= high) {
      final int mid = (low + high) >> 1;
      if (_subtitleStartMs[mid] <= posMs) {
        ans = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return ans;
  }

  List<int> _findActiveIndicesMs(
    int posMs, {
    required bool continuousSubtitleEnabled,
  }) {
    final subtitles = _displaySubtitles;
    if (subtitles.isEmpty) return <int>[];
    _ensureSubtitleIndex();
    final int candidate = _binarySearchLastStartLE(posMs);
    if (candidate < 0 || candidate >= subtitles.length) return <int>[];
    final List<int> indices = <int>[];
    for (int i = candidate; i >= 0; i--) {
      if (_subtitleStartMs[i] > posMs) continue;
      final int endMs = _getEffectiveEndTimeMs(i, continuousSubtitleEnabled);
      if (posMs < endMs) {
        indices.add(i);
      }
      if (i == 0) {
        break;
      }
      final int prefixMaxEndMs = continuousSubtitleEnabled
          ? _subtitlePrefixMaxEndMs[i - 1]
          : _getEffectiveEndTimeMs(i - 1, continuousSubtitleEnabled);
      if (prefixMaxEndMs <= posMs) {
        break;
      }
    }
    if (indices.length <= 1) return indices;
    return indices.reversed.toList(growable: false);
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
      if (_hasAnyActivePointer) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_hasAnyActivePointer) return;
        if (requestId != _autoScrollRequestId) return;
        _scrollToActiveIndex(isAuto: true);
      });
    });
  }

  void triggerLocateForAutoFollow({bool animated = false}) {
    if (!mounted) return;
    if (!widget.isVisible || !SettingsService().autoScrollSubtitles) return;
    if (_hasAnyActivePointer) return;
    if (_displaySubtitles.isEmpty) return;
    if (!_playbackIsPlaying) return;
    if (_isBeforeFirstSubtitleAtMs(_playbackPosition.inMilliseconds)) {
      _locateBeforeFirstSubtitleAtTop();
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _locateToCurrentSubtitleAfterModeSwitch(attempt: 0, animated: animated);
    });
  }

  void _triggerLocateButtonAfterModeSwitch() {
    if (!mounted) return;
    if (!widget.isVisible) return;
    if (_hasAnyActivePointer) return;
    if (_displaySubtitles.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // ItemPositionsListener publishes the geometry from a rebuilt row one
      // frame after the row itself. Waiting for that fresh snapshot prevents
      // a line-height or view-mode change from being positioned with stale
      // pre-switch bounds.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _locateToCurrentSubtitleAfterModeSwitch(attempt: 0, animated: false);
      });
    });
  }

  void _updateArticleChunkSize(int value) {
    final int nextValue = value.clamp(
      _minArticleChunkSize,
      _maxArticleChunkSize,
    );
    if (nextValue == _articleChunkSize) return;

    setState(() => _articleChunkSize = nextValue);
    SettingsService().updateSetting(
      'subtitleArticleSentencesPerParagraph',
      nextValue,
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

  /// 暴露给外部页面（如从音乐播放页切换回视频播放页）的定位方法。
  ///
  /// 与 [triggerLocateForAutoFollow] 不同，本方法不依赖 autoScrollSubtitles
  /// 开关，也不要求当前正在播放，只要字幕文稿区可见即执行定位。
  /// 用于在页面切换完成后将字幕文稿滚动到当前播放位置对应的字幕，
  /// 同时可修复切回页面时列表偶发空白（滚动控制器暂未重新挂载）的问题。
  void locateToCurrentSubtitle({
    bool animated = false,
    bool ignorePointer = false,
  }) {
    if (!mounted) return;
    if (!widget.isVisible) return;
    // 页面切换完成后的自动定位属于「显式请求」，即便切页瞬间仍有一个活动的指针
    // （例如点击返回键抬起前的那一帧）也应执行定位；此时由调用方传入 ignorePointer=true。
    if (!ignorePointer && _hasAnyActivePointer) return;
    if (_displaySubtitles.isEmpty) return;
    _ensureSubtitleIndex();
    if (_isBeforeFirstSubtitleAtMs(_playbackPosition.inMilliseconds)) {
      _locateBeforeFirstSubtitleAtTop();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 确保索引（起始/结束时间、显示文本缓存）是最新的，避免切页后数据陈旧
      _ensureSubtitleIndex();
      _locateToCurrentSubtitleAfterModeSwitch(
        attempt: 0,
        animated: animated,
        ignorePointer: ignorePointer,
      );
    });
  }

  void _locateToCurrentSubtitleAfterModeSwitch({
    required int attempt,
    bool animated = false,
    bool ignorePointer = false,
  }) {
    if (!mounted) return;
    if (!ignorePointer && _hasAnyActivePointer) return;

    const int maxAttempts = 6;
    if (_isArticleMode) {
      if (!_articleItemScrollController.isAttached) {
        if (attempt < maxAttempts) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _locateToCurrentSubtitleAfterModeSwitch(
              attempt: attempt + 1,
              animated: animated,
              ignorePointer: ignorePointer,
            );
          });
        }
        return;
      }
    } else {
      if (!_itemScrollController.isAttached) {
        if (attempt < maxAttempts) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _locateToCurrentSubtitleAfterModeSwitch(
              attempt: attempt + 1,
              animated: animated,
              ignorePointer: ignorePointer,
            );
          });
        }
        return;
      }
    }

    final positions = _isArticleMode
        ? _articleItemPositionsListener.itemPositions.value
        : _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty && attempt < maxAttempts) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _locateToCurrentSubtitleAfterModeSwitch(
          attempt: attempt + 1,
          animated: animated,
          ignorePointer: ignorePointer,
        );
      });
      return;
    }

    final int posMs = _playbackPosition.inMilliseconds;
    final List<int> activeIndices = _findActiveIndicesMs(
      posMs,
      continuousSubtitleEnabled: true,
    );
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
    if (animated) {
      _scrollToActiveIndex();
    } else {
      _jumpToActiveIndexWithAlignment(targetIndex);
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_activePointerCount == 0) {
      _didScrollWhilePointerSession = false;
      _pointerDownStartIndex = _activeIndexNotifier.value;
    }
    _activePointerCount++;
    _cancelPendingAutoScroll();
  }

  void _onPointerUpOrCancel(PointerEvent event) {
    _activePointerCount--;
    if (_activePointerCount < 0) _activePointerCount = 0;
    if (_activePointerCount == 0) {
      final bool shouldAnimateRelocate = _didScrollWhilePointerSession;
      final int? pointerDownStartIndex = _pointerDownStartIndex;
      final int currentIndex = _activeIndexNotifier.value;
      _didScrollWhilePointerSession = false;
      _pointerDownStartIndex = null;
      if (shouldAnimateRelocate) {
        triggerLocateForAutoFollow(animated: true);
      } else if (pointerDownStartIndex != null &&
          pointerDownStartIndex != currentIndex) {
        // A subtitle tap seeks on pointer-down. Depending on how quickly the
        // player reports the new position, the active index may therefore
        // change before pointer-up. Keep this path animated as well; using a
        // jump here made identical taps randomly snap or animate based solely
        // on the seek callback timing. Large timeline seeks still use
        // locateToTime's explicit single-stage jump optimization.
        triggerLocateForAutoFollow(animated: true);
      }
    }
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (_activePointerCount <= 0) return false;
    if (notification is ScrollUpdateNotification ||
        notification is OverscrollNotification) {
      _didScrollWhilePointerSession = true;
    }
    return false;
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
    if (index >= 0 && index < _displayTextCache.length) {
      return _displayTextCache[index];
    }
    return _computeDisplayTextForIndex(index);
  }

  String _computeDisplayTextForIndex(int index) {
    final subtitles = _displaySubtitles;
    if (index < 0 || index >= subtitles.length) return '';
    final String text = subtitles[index].text;
    if (_usesSecondaryTrackForDisplay) {
      return text;
    }
    if (_lineFilterMode == 0) {
      // Dual Mode
      // If we have valid bilingual match, merge them
      if (_isBilingualMode && _secondaryTextCache.containsKey(index)) {
        return "$text ${_secondaryTextCache[index]}";
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
    final lines = text.split('\n');
    if (_lineFilterMode == 1) {
      return lines.isNotEmpty ? lines[0] : '';
    } else if (_lineFilterMode == 2) {
      return lines.length > 1 ? lines[1] : '';
    }
    return text;
  }

  void _handleSubtitleTap(int index) {
    final subtitles = _displaySubtitles;
    if (index < 0 || index >= subtitles.length) return;

    final item = subtitles[index];
    widget.onClearSelection?.call();
    _pendingLocateIndex = index;
    widget.onItemTap?.call(item.startTime);
    Future.microtask(() => widget.focusNode?.requestFocus());
  }

  void _scrollToActiveIndex({bool isAuto = false}) {
    if (_isBeforeFirstSubtitleAtMs(_playbackPosition.inMilliseconds)) {
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
    if (_isArticleMode) {
      final chunkIndex = index ~/ _articleChunkSize;

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
      final int chunkIndex = index ~/ _articleChunkSize;
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
        ? (_displaySubtitles.length / _articleChunkSize).ceil()
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
      final int chunkIndex = targetIndex ~/ _articleChunkSize;
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
              widget.onClearSelection?.call();
              widget.focusNode?.requestFocus();
            },
            behavior: HitTestBehavior.translucent,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _onPointerDown,
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
                                    setState(() {
                                      _lineFilterMode = index;
                                      _invalidateDisplaySubtitlesCache();
                                    });
                                    _rebuildSubtitleIndex();
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
                                onTap: _scrollToActiveIndex,
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

                      // 字幕显示设置面板
                      if (_showFontSettings)
                        Container(
                          color: Colors.white.withValues(alpha: 0.05),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
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
                                              setState(
                                                () =>
                                                    _fontSizeScale = nextScale,
                                              );
                                            },
                                            onCommit: (nextScale) {
                                              final key = widget.isPortrait
                                                  ? 'portraitSidebarFontSizeScale'
                                                  : 'landscapeSidebarFontSizeScale';
                                              SettingsService().updateSetting(
                                                key,
                                                nextScale,
                                              );
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
                                            onChanged:
                                                _updateLocatePositionPercent,
                                          ),
                                        ),
                                      ],
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
                                            child: _SentenceCountInputWidget(
                                              value: _articleChunkSize,
                                              min: _minArticleChunkSize,
                                              max: _maxArticleChunkSize,
                                              onChanged:
                                                  _updateArticleChunkSize,
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
                                            message: _showTimestamps
                                                ? "隐藏时间"
                                                : "显示时间",
                                            child: InkWell(
                                              key: const ValueKey(
                                                'subtitle-show-time-switch',
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                              onTap: () {
                                                final value = !_showTimestamps;
                                                setState(
                                                  () => _showTimestamps = value,
                                                );
                                                final key = widget.isPortrait
                                                    ? 'portraitSidebarShowTimestamps'
                                                    : 'landscapeSidebarShowTimestamps';
                                                SettingsService().updateSetting(
                                                  key,
                                                  value,
                                                );
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
                                                  setState(
                                                    () => _timeColumnRatio =
                                                        nextRatio,
                                                  );
                                                },
                                                onCommit: (nextRatio) {
                                                  final key = widget.isPortrait
                                                      ? 'portraitSidebarTimeColumnRatio'
                                                      : 'landscapeSidebarTimeColumnRatio';
                                                  SettingsService()
                                                      .updateSetting(
                                                        key,
                                                        nextRatio,
                                                      );
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
                        ),
                    ],
                  ),

                  // 2. 内容区
                  Expanded(
                    child: _displaySubtitles.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  widget.showEmbeddedLoadingMessage
                                      ? "已识别到内嵌字幕，\n正在提取中..."
                                      : "暂无字幕",
                                  style: const TextStyle(color: Colors.white54),
                                  textAlign: TextAlign.center,
                                ),
                                if (widget.onOpenSubtitleManager != null) ...[
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
                        : (_isArticleMode
                              ? _buildArticleView(isSmallScreen)
                              : _buildListView(isSmallScreen)),
                  ),
                ],
              ),
            ),
          ),
        ),
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
    required double maxHeight,
    required bool isSmallScreen,
    required int chunkCount,
  }) {
    if (chunkCount <= 1) return true;
    final int lineCount = _lineFilterMode == 0 && _isBilingualMode ? 2 : 1;
    final double fontSize = _subtitleTextFontSize(isSmallScreen);
    final double textHeight = fontSize * 1.6 * lineCount;
    final double estimatedChunkHeight =
        textHeight * _articleChunkSize * 0.75 + (isSmallScreen ? 20 : 32);
    final double estimatedTotalHeight =
        estimatedChunkHeight * chunkCount + (isSmallScreen ? 24 : 40);
    return estimatedTotalHeight <= maxHeight;
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
          child: ScrollablePositionedList.builder(
            itemScrollController: _itemScrollController,
            itemPositionsListener: _itemPositionsListener,
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
              return ValueListenableBuilder<List<int>>(
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
                        onTapDown: (_) => _handleSubtitleTap(index),
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
                                  itemConstraints.maxWidth * _timeColumnRatio;
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (_showTimestamps)
                                    SizedBox(
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
                                                    (isSmallScreen ? 10 : 11) *
                                                    _fontSizeScale,
                                                fontFamily: 'monospace',
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  Expanded(
                                    child: Text(
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
              );
            },
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
          child: ScrollablePositionedList.builder(
            key: ValueKey('subtitle-article-list-$_articleChunkSize'),
            itemScrollController: _articleItemScrollController,
            itemPositionsListener: _articleItemPositionsListener,
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

              return ValueListenableBuilder<List<int>>(
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
                        subtitles: displaySubtitles,
                        displayTexts: _displayTextCache,
                        startIndex: startIndex,
                        endIndex: endIndex,
                        activeIndices: activeIndices.toSet(),
                        fontSizeScale: _fontSizeScale,
                        onSubtitleTap: _handleSubtitleTap,
                        isSmallScreen: isSmallScreen,
                        lineFilterMode: _lineFilterMode,
                        secondaryTextCache: _secondaryTextCache,
                        isBilingualMode: _isBilingualMode,
                        usesSecondaryTrackForDisplay:
                            _usesSecondaryTrackForDisplay,
                      ),
                    ),
                  );
                },
              );
            },
          ),
        );
        return shouldTopAlign
            ? Align(alignment: Alignment.topCenter, child: list)
            : list;
      },
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "$twoDigitMinutes:$twoDigitSeconds";
  }
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
  });

  @override
  State<SubtitleArticleChunk> createState() => _SubtitleArticleChunkState();
}

class _SubtitleArticleChunkState extends State<SubtitleArticleChunk> {
  final Map<int, TapGestureRecognizer> _recognizers =
      <int, TapGestureRecognizer>{};

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
    if (widget.onSubtitleTap == null) return;
    for (int i = widget.startIndex; i < widget.endIndex; i++) {
      _recognizers[i] = TapGestureRecognizer()
        ..onTapDown = (_) => widget.onSubtitleTap!(i);
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

    for (int i = widget.startIndex; i < widget.endIndex; i++) {
      final item = widget.subtitles[i];
      final isCurrent = widget.activeIndices.contains(i);
      String rawText = i >= 0 && i < widget.displayTexts.length
          ? widget.displayTexts[i]
          : '';
      if (rawText.isEmpty && item.imageLoader != null) {
        rawText = "[图片字幕]";
      }
      final text = rawText.replaceAll('\n', ' ').trim();
      if (text.isEmpty) continue;
      if (spans.isNotEmpty) {
        spans.add(const TextSpan(text: '  '));
      }
      spans.add(
        TextSpan(
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
        ),
      );
    }

    return SelectionContainer.disabled(
      child: Text.rich(
        TextSpan(children: spans),
        textAlign: TextAlign.start,
        softWrap: true,
        strutStyle: StrutStyle(
          fontSize: (widget.isSmallScreen ? 12 : 13) * widget.fontSizeScale,
          height: 1.6,
          forceStrutHeight: true,
        ),
      ),
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
