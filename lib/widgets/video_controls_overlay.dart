import '../widgets/subtitle_debug_speed_gateway.dart';
import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:video_player/video_player.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart'; // Added for LogicalKeyboardKey
import 'package:provider/provider.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'experimental_tap_gateway.dart';
import 'package:volume_controller/volume_controller.dart';
import '../models/subtitle_style.dart';
import '../models/subtitle_model.dart';
import '../widgets/subtitle_overlay.dart';
import '../services/media_playback_service.dart';
import '../services/bilibili/bilibili_streaming_service.dart';
import '../services/settings_service.dart';
import '../services/subtitle_hop_seek_policy.dart';
import '../services/app_haptics.dart';
import '../services/video_preview_service.dart';
import '../utils/android_hardware_input_bridge.dart';
import '../utils/tooltip_hover_policy.dart';
import '../utils/desktop_player_shortcuts.dart';
import '../utils/hardware_keyboard_shortcuts.dart';
import '../utils/player_volume_keyboard.dart';
import '../models/media_chapter.dart';
import '../models/bilibili_video_shot.dart';
import '../utils/app_toast.dart';
import 'bilibili_sprite_preview.dart';
import 'chapter_slider_track_shape.dart';
import 'player_control_metrics.dart';
import 'progress_interaction_geometry.dart';
import 'playback_speed_dialog.dart';
import 'stream_quality_picker.dart';

const Color _danmakuControlAccent = Color(0xFFFF6699);

class VideoControlsOverlay extends StatefulWidget {
  final VideoPlayerController? controller;
  final bool isLocked;
  final VoidCallback onTogglePlay;
  final VoidCallback onBackPressed;
  final VoidCallback? onExitPressed; // New: For Windows direct exit
  final VoidCallback? onToggleSidebar;
  final bool isSubtitleSidebarVisible;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onOpenSleepTimer;
  final VoidCallback? onOpenSubtitleManager;
  final VoidCallback? onOpenSubtitleEditor;
  final VoidCallback? onToggleFloatingSubtitleSettings;
  final VoidCallback? onOpenVideoCompose; // New parameter
  final VoidCallback? onOpenOcrSubtitle;
  final VoidCallback onToggleLock;
  final bool showDanmakuControls;
  final bool danmakuEnabled;
  final VoidCallback? onToggleDanmaku;
  final VoidCallback? onOpenDanmakuSettings;
  final VoidCallback? onToggleFullScreen; // New: For desktop full screen toggle
  final ValueChanged<Duration>? onSeekTo;

  /// Double-tap / sentence hops. Falls back to [onSeekTo] when omitted.
  final ValueChanged<Duration>? onHopSeekTo;
  final Future<void> Function(double speed) onSpeedUpdate;
  final int doubleTapSeekSeconds;
  final bool enableDoubleTapSubtitleSeek;
  final List<SubtitleItem> subtitles;
  final double longPressSpeed;
  final bool showSubtitles;
  final bool suppressSubtitleOverlay;
  final VoidCallback onToggleSubtitles;
  final VoidCallback onMoveSubtitles; // New callback for move subtitles
  final bool isLongPressing;
  final String longPressFeedbackText;
  final ValueGetter<bool> onLongPressStart;
  final VoidCallback onLongPressEnd;

  // Subtitle Dragging Passthrough
  final List<SubtitleOverlayEntry> subtitleEntries;
  final SubtitleStyle subtitleStyle;
  final Alignment subtitleAlignment;
  final VoidCallback onEnterSubtitleDragMode;
  final VoidCallback? onClearSelection; // New callback
  final VoidCallback?
  onToggleEpisodePicker; // Callback to toggle episode picker
  final bool showPlayControls;
  final bool showBottomBar;
  final FocusNode? focusNode; // New: External focus node

  // Playlist Navigation
  final VoidCallback? onPlayPrevious;
  final VoidCallback? onPlayNext;
  final bool hasPrevious;
  final bool hasNext;
  final String mediaTitle;
  final bool isPreviewMode; // New parameter for simple preview mode
  final bool showSubtitleEditorButton;
  final VoidCallback? onOpenAspectRatio;
  final String? aspectRatioLabel;
  final bool compactTopRightButtons;
  final bool showResetScreenButton;
  final VoidCallback? onResetScreenTransform;
  final bool suppressPrimaryGestures;
  final bool allowPlayWhenUninitialized;
  final VoidCallback? onExperimentalTrigger;
  final List<MediaChapter> chapters;
  final VoidCallback? onOpenChapters;
  final bool isChapterSidebarVisible;
  final ValueNotifier<bool>? playbackControlsVisibility;
  final bool enableSeekThumbnailPreview;
  final BilibiliVideoShot? bilibiliVideoShot;
  final bool showBufferedProgress;
  // Immediate chrome intent, not the delayed subtitle-avoidance notifier.
  final bool initialShowControls;
  final ValueChanged<bool>? onControlsVisibilityIntent;

  const VideoControlsOverlay({
    super.key,
    required this.controller,
    required this.isLocked,
    required this.onTogglePlay,
    required this.onBackPressed,
    this.onExitPressed,
    this.onToggleSidebar,
    this.isSubtitleSidebarVisible = false,
    this.onOpenSettings,
    this.onOpenSleepTimer,
    this.onOpenSubtitleManager,
    this.onOpenSubtitleEditor,
    this.onToggleFloatingSubtitleSettings,
    this.onOpenVideoCompose,
    this.onOpenOcrSubtitle,
    required this.onToggleLock,
    this.showDanmakuControls = false,
    this.danmakuEnabled = true,
    this.onToggleDanmaku,
    this.onOpenDanmakuSettings,
    this.onToggleFullScreen,
    this.onSeekTo,
    this.onHopSeekTo,
    required this.onSpeedUpdate,
    this.doubleTapSeekSeconds = 5,
    this.enableDoubleTapSubtitleSeek = true,
    this.subtitles = const [],
    this.longPressSpeed = 2.0,
    required this.showSubtitles,
    this.suppressSubtitleOverlay = false,
    required this.onToggleSubtitles,
    required this.onMoveSubtitles,
    required this.isLongPressing,
    required this.longPressFeedbackText,
    required this.onLongPressStart,
    required this.onLongPressEnd,
    required this.subtitleEntries,
    required this.subtitleStyle,
    required this.subtitleAlignment,
    required this.onEnterSubtitleDragMode,
    this.onClearSelection,
    this.onToggleEpisodePicker,
    this.showPlayControls = true,
    this.showBottomBar = true,
    this.focusNode,
    this.onPlayPrevious,
    this.onPlayNext,
    this.hasPrevious = false,
    this.hasNext = false,
    this.mediaTitle = '',
    this.isPreviewMode = false,
    this.showSubtitleEditorButton = true,
    this.onOpenAspectRatio,
    this.aspectRatioLabel,
    this.compactTopRightButtons = false,
    this.showResetScreenButton = false,
    this.onResetScreenTransform,
    this.suppressPrimaryGestures = false,
    this.allowPlayWhenUninitialized = false,
    this.onExperimentalTrigger,
    this.chapters = const <MediaChapter>[],
    this.onOpenChapters,
    this.isChapterSidebarVisible = false,
    this.playbackControlsVisibility,
    this.enableSeekThumbnailPreview = true,
    this.bilibiliVideoShot,
    this.showBufferedProgress = false,
    this.initialShowControls = true,
    this.onControlsVisibilityIntent,
  });

  @override
  State<VideoControlsOverlay> createState() => VideoControlsOverlayState();
}

class VideoControlsOverlayState extends State<VideoControlsOverlay> {
  static const Duration _controlsFadeDuration = Duration(milliseconds: 250);
  static const Duration _subtitleAvoidanceReleaseDelay = Duration(
    milliseconds: 150,
  );

  /// Hold long enough to boost. A shorter physical press is always a tap, even
  /// when a busy UI thread lets this timer run before the key-up is processed.
  static const Duration _keyboardHoldToBoostThreshold = Duration(
    milliseconds: 200,
  );

  final ValueNotifier<VideoPlayerValue> _unavailableControllerValue =
      ValueNotifier<VideoPlayerValue>(VideoPlayerValue.uninitialized());

  VideoPlayerValue get _controllerValue =>
      widget.controller?.value ?? _unavailableControllerValue.value;
  Listenable get _controllerListenable =>
      widget.controller ?? _unavailableControllerValue;

  MediaPlaybackService? _playbackServiceOrNull() {
    try {
      return Provider.of<MediaPlaybackService>(context, listen: false);
    } catch (_) {
      return null;
    }
  }

  /// Non-null when this overlay's controller is the session player. The button
  /// follows that intent instead of the lagging controller flag.
  final ValueNotifier<bool?> _ownedTransportPlaying = ValueNotifier<bool?>(
    null,
  );
  MediaPlaybackService? _transportService;

  void _bindTransportService() {
    final MediaPlaybackService? next = _playbackServiceOrNull();
    if (!identical(next, _transportService)) {
      _transportService?.removeListener(_syncOwnedTransportPlaying);
      _transportService = next;
      _transportService?.addListener(_syncOwnedTransportPlaying);
    }
    _syncOwnedTransportPlaying();
  }

  void _syncOwnedTransportPlaying() {
    final MediaPlaybackService? service = _transportService;
    final VideoPlayerController? controller = widget.controller;
    final bool? next =
        service != null &&
            controller != null &&
            identical(service.controller, controller)
        ? service.desiredPlaying
        : null;
    if (_ownedTransportPlaying.value != next) {
      _ownedTransportPlaying.value = next;
    }
  }

  String get _controllerDataSource => widget.controller?.dataSource ?? '';

  bool _isDraggingProgress = false;
  double _dragProgressValue = 0.0;
  int? _desktopProgressPointer;
  bool _isProgressHovered = false;
  double? _hoverProgressValue;
  int? _dragChapterIndex;
  bool _showControls = true;
  Timer? _subtitleAvoidanceReleaseTimer;

  bool get controlsVisible => _showControls;

  /// Restore chrome after a route or overlay remount without a tap.
  void applyControlsVisibilityIntent(bool visible) {
    if (!mounted || _showControls == visible) return;
    setState(() {
      _setShowControls(visible);
    });
    if (visible) {
      _startAutoHideTimer();
    } else {
      _cancelAutoHideTimer();
    }
  }

  void _setShowControls(bool value) {
    // A quality/speed popover lives on a separate route. Hiding chrome while
    // it is open looks like the menu "ate" the controls.
    if (!value && _isControlDialogOpen) return;
    _showControls = value;
    widget.onControlsVisibilityIntent?.call(value);
    _subtitleAvoidanceReleaseTimer?.cancel();

    // Showing controls must reserve subtitle space before the fade-in starts.
    if (value || !widget.showBottomBar) {
      _publishPlaybackControlsVisibility();
      return;
    }

    // Release slightly before the opacity animation finishes. At this point
    // the controls are already visually faint, so subtitles feel responsive
    // without noticeably overlapping the progress bar.
    _subtitleAvoidanceReleaseTimer = Timer(_subtitleAvoidanceReleaseDelay, () {
      if (mounted && !_showControls) {
        _publishPlaybackControlsVisibility();
      }
    });
  }

  void _publishPlaybackControlsVisibility() {
    final notifier = widget.playbackControlsVisibility;
    if (notifier == null) return;
    final visible = widget.showBottomBar && _showControls;
    if (notifier.value != visible) {
      notifier.value = visible;
    }
  }

  // Gesture Seek
  bool _isGestureSeeking = false;
  Duration _gestureTargetTime = Duration.zero;
  String _gestureDiffText = "";
  bool _isGestureCanceling = false;
  bool _showControlsBeforeGestureSeek = false;
  bool _isProgressDragCanceling = false; // New: For slider drag cancellation
  bool _progressDragWasCancelled = false;

  // Keep transient feedback local so a rate change does not rebuild the
  // entire player page in the same frame as the native player update.
  bool _longPressActive = false;
  String _localLongPressFeedbackText = "";

  // The parent keeps playback-speed state, but this overlay exclusively owns
  // the transient visual. A parent rebuild during a press can otherwise leave
  // widget.isLongPressing stuck at its previous value until another rebuild.
  bool get _isLongPressActive => _longPressActive;

  String get _effectiveLongPressFeedbackText =>
      _localLongPressFeedbackText.isNotEmpty
      ? _localLongPressFeedbackText
      : widget.longPressFeedbackText;

  void cancelLongPressFeedback() {
    if (!_longPressActive || !mounted) return;
    setState(() => _longPressActive = false);
  }

  // Double Tap Feedback (Local)
  bool _showDoubleTapFeedback = false;
  bool _isDoubleTapFeedbackFadingOut = false;
  String _doubleTapFeedbackText = "";
  Timer? _doubleTapFeedbackHideTimer;
  Timer? _doubleTapFeedbackDismissTimer;
  int _doubleTapFeedbackPulse = 0;
  static const Duration _doubleTapFeedbackVisibleDuration = Duration(
    milliseconds: 430,
  );
  static const Duration _doubleTapFeedbackFadeOutDuration = Duration(
    milliseconds: 180,
  );
  static const Duration _doubleTapChainResetDuration = Duration(
    milliseconds: 900,
  );

  Offset? _tapPosition;

  // Volume & Brightness
  bool _isAdjustingVolume = false;
  bool _isAdjustingBrightness = false;
  // Async getVolume/brightness can finish after the swipe already ended.
  int _verticalAdjustmentSession = 0;
  bool _verticalAdjustmentGestureActive = false;
  // bool _showVolumeSlider = false; // Removed
  double _currentVolume = 0.0;
  double _currentBrightness = 0.0;
  // double _preLongPressSpeed = 1.0; // Moved to parent
  double _startDragValue = 0.0; // Value at start of drag
  // double _sliderVolume = 1.0; // Removed

  // Manual Double Tap Detection
  DateTime? _lastTapTime;
  Offset? _lastTapDownPosition;
  Timer? _singleTapTimer;

  // Keyboard Handling
  final FocusNode _focusNode = FocusNode(
    debugLabel: 'VideoControlsOverlayFocus',
  );
  final Map<LogicalKeyboardKey, _KeyboardPressState> _keyboardPressStates =
      <LogicalKeyboardKey, _KeyboardPressState>{};
  LogicalKeyboardKey? _activeSpeedBoostKey;
  bool _isKeyboardLongPressing = false;
  KeyEvent? _lastRoutedKeyEvent;
  KeyEventResult _lastRoutedKeyEventResult = KeyEventResult.ignored;
  final AndroidHardwareKeyDeduplicator _androidKeyDeduplicator =
      AndroidHardwareKeyDeduplicator();
  DesktopPlayerShortcutAction? _lastDispatchedShortcutAction;
  DateTime? _lastDispatchedShortcutAt;
  int _volumeKeyDirection = 0;
  int _volumeKeySessionSerial = 0;
  Timer? _volumeHoldStartTimer;
  Timer? _volumeHoldTickTimer;
  Timer? _volumeFeedbackHideTimer;

  // Mouse and touch share one overlay. The most recently active device owns
  // visibility so a touch gesture cannot be interrupted by stale hover.
  final Set<int> _activeTouchPointers = <int>{};
  bool _lastPointerInputWasTouch = false;
  bool _suppressMouseActivity = false;
  Timer? _mouseActivitySuppressionTimer;
  Timer? _touchReleaseAutoHideTimer;

  Uint8List? _previewImage;
  BilibiliVideoShotFrame? _videoShotFrame;
  int _previewRequestSerial = 0;
  Timer? _seekPreviewRefineTimer;
  Timer? _seekPreviewThrottleTimer;
  DateTime? _lastSeekPreviewRequestAt;
  int? _lastSeekPreviewRequestTimeMs;
  double? _pendingSeekPreviewValue;
  static const Duration _seekPreviewRefineDelay = Duration(milliseconds: 140);
  static const Duration _seekPreviewMinInterval = Duration(milliseconds: 65);
  static const int _seekPreviewMinStepMs = 24;

  bool get _isSeekPreviewInteractionActive =>
      _isDraggingProgress ||
      (_isProgressHovered && _hoverProgressValue != null);

  double? get _activeSeekPreviewValue => _isDraggingProgress
      ? _dragProgressValue
      : (_isProgressHovered ? _hoverProgressValue : null);

  bool _isCurrentSeekPreviewTarget(double value, {double tolerance = 1.0}) {
    final activeValue = _activeSeekPreviewValue;
    return activeValue != null && (activeValue - value).abs() <= tolerance;
  }

  // Auto-hide controls timer
  Timer? _autoHideTimer;
  static const Duration _autoHideDelay = Duration(seconds: 3);
  static const Duration _episodeSwitchMouseSuppression = Duration(
    milliseconds: 600,
  );
  bool _isPlaybackSpeedDialogOpen = false;
  bool _isStreamQualityDialogOpen = false;

  bool get _isControlDialogOpen =>
      _isPlaybackSpeedDialogOpen || _isStreamQualityDialogOpen;
  final GlobalKey _streamQualityPillKey = GlobalKey();
  PlayerControlMetrics? _controlMetrics;

  String? _resolvePreviewFilePath() {
    final path = _controllerDataSource;
    String filePath = path;
    if (path.startsWith('file://')) {
      try {
        filePath = Uri.parse(path).toFilePath();
      } catch (e) {
        // Fallback or ignore
      }
    } else if (path.startsWith('http')) {
      // Skip network streams for performance
      return null;
    }
    return filePath;
  }

  Future<void> _showPlaybackSpeedPicker(
    SettingsService settings,
    BuildContext anchorContext,
  ) async {
    if (_isPlaybackSpeedDialogOpen) return;
    _isPlaybackSpeedDialogOpen = true;
    _singleTapTimer?.cancel();
    _autoHideTimer?.cancel();
    try {
      await showPlaybackSpeedDialog(
        context: context,
        anchorContext: anchorContext,
        initialSpeed: _controllerValue.playbackSpeed,
        settings: settings,
        onSpeedSelected: widget.onSpeedUpdate,
      );
    } finally {
      _isPlaybackSpeedDialogOpen = false;
      if (mounted) _startAutoHideTimer();
    }
  }

  Future<void> _showStreamQualityPicker(
    MediaPlaybackService playbackService,
    BuildContext anchorContext,
  ) async {
    if (_isStreamQualityDialogOpen || playbackService.streamQualities.isEmpty) {
      return;
    }
    _isStreamQualityDialogOpen = true;
    _singleTapTimer?.cancel();
    _autoHideTimer?.cancel();
    try {
      final metrics =
          _controlMetrics ??
          PlayerControlMetrics.fromSize(MediaQuery.sizeOf(context));
      final selectedId = await showStreamQualityPicker(
        context: context,
        anchorContext: _streamQualityPillKey.currentContext ?? anchorContext,
        qualities: playbackService.streamQualities,
        selectedId: playbackService.selectedStreamQuality?.id,
        metrics: metrics,
      );
      if (selectedId != null &&
          selectedId != playbackService.selectedStreamQuality?.id &&
          !playbackService.isSwitchingStreamQuality) {
        final switched = await playbackService.switchBilibiliStreamQuality(
          selectedId,
        );
        if (!switched && mounted) {
          final retainedLabel =
              playbackService.selectedStreamQuality?.label ?? '当前清晰度';
          AppToast.show(
            '清晰度切换失败，已继续播放 $retainedLabel',
            type: AppToastType.error,
          );
        }
      }
    } finally {
      _isStreamQualityDialogOpen = false;
      if (mounted) _startAutoHideTimer();
    }
  }

  TextStyle _progressPillTextStyle(
    BuildContext context,
    PlayerControlMetrics metrics,
  ) {
    return DefaultTextStyle.of(context).style.merge(
      TextStyle(
        color: Colors.white,
        fontSize: metrics.progressPillFontSize,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  Widget _buildStreamQualityProgressPill({
    required PlayerControlMetrics controlMetrics,
    required double maxWidth,
    required TextDirection textDirection,
    required MediaPlaybackService playbackService,
  }) {
    return Selector<
      MediaPlaybackService,
      ({
        bool switching,
        BilibiliStreamQuality? selected,
        List<BilibiliStreamQuality> qualities,
      })
    >(
      selector: (_, service) => (
        switching: service.isSwitchingStreamQuality,
        selected: service.selectedStreamQuality,
        qualities: service.streamQualities,
      ),
      builder: (context, state, _) {
        final qualityTextStyle = _progressPillTextStyle(
          context,
          controlMetrics,
        );
        final qualityLabels = state.qualities.isEmpty
            ? const <String>['清晰度']
            : [for (final quality in state.qualities) quality.label];
        final qualityButtonWidth = controlMetrics.measureProgressPillWidth(
          labels: qualityLabels,
          textStyle: qualityTextStyle,
          textDirection: textDirection,
          textScaler: MediaQuery.textScalerOf(context),
          locale: Localizations.maybeLocaleOf(context),
          maxWidth: maxWidth,
        );
        final selectedLabel = state.selected?.label ?? '清晰度';
        return Tooltip(
          message: _tooltipWithShortcut(
            '清晰度',
            DesktopPlayerShortcutAction.openStreamQuality,
          ),
          child: KeyedSubtree(
            key: const ValueKey('video-controls-quality-button'),
            child: Material(
              key: _streamQualityPillKey,
              color: kStreamQualityPillFill,
              elevation: 2,
              shadowColor: Colors.black.withValues(alpha: 0.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(
                  controlMetrics.chapterButtonHeight / 2,
                ),
                side: BorderSide(
                  color: Colors.white.withValues(alpha: 0.16),
                  width: 0.75,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: state.switching
                    ? null
                    : () {
                        _singleTapTimer?.cancel();
                        unawaited(
                          _showStreamQualityPicker(playbackService, context),
                        );
                      },
                child: SizedBox(
                  width: qualityButtonWidth,
                  height: controlMetrics.chapterButtonHeight,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: controlMetrics.progressPillHorizontalPadding,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: state.switching
                              ? Center(
                                  child: SizedBox(
                                    width: controlMetrics.progressPillIconSize,
                                    height: controlMetrics.progressPillIconSize,
                                    child: const CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : Text(
                                  selectedLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.start,
                                  style: qualityTextStyle,
                                ),
                        ),
                        SizedBox(width: controlMetrics.progressPillContentGap),
                        Icon(
                          Icons.keyboard_arrow_down,
                          color: Colors.white,
                          size: controlMetrics.progressPillIconSize,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _warmSeekPreviewMetadata() {
    if (!widget.enableSeekThumbnailPreview) {
      return;
    }
    if (widget.bilibiliVideoShot?.isUsable == true) {
      return;
    }
    final settings = Provider.of<SettingsService>(context, listen: false);
    if (!settings.enableSeekPreview) {
      return;
    }
    final filePath = _resolvePreviewFilePath();
    if (filePath == null) {
      return;
    }
    VideoPreviewService().warmup(filePath);
  }

  void _schedulePreciseSeekPreview(double value) {
    if (!widget.enableSeekThumbnailPreview) {
      return;
    }
    _seekPreviewRefineTimer?.cancel();
    final int targetTimeMs = value.toInt();
    _seekPreviewRefineTimer = Timer(_seekPreviewRefineDelay, () {
      if (!mounted || !_isSeekPreviewInteractionActive) {
        return;
      }
      if (!_isCurrentSeekPreviewTarget(value)) {
        return;
      }
      _updateSeekPreview(value, precise: true, expectedTimeMs: targetTimeMs);
    });
  }

  void _cancelSeekPreviewRefine() {
    _seekPreviewRefineTimer?.cancel();
    _seekPreviewRefineTimer = null;
  }

  void _cancelSeekPreviewThrottle() {
    _seekPreviewThrottleTimer?.cancel();
    _seekPreviewThrottleTimer = null;
    _pendingSeekPreviewValue = null;
  }

  void _resetSeekPreviewRequestState() {
    _cancelSeekPreviewThrottle();
    _lastSeekPreviewRequestAt = null;
    _lastSeekPreviewRequestTimeMs = null;
  }

  void _scheduleLiveSeekPreview(double value, {bool immediate = false}) {
    if (!widget.enableSeekThumbnailPreview ||
        !_isSeekPreviewInteractionActive) {
      return;
    }
    final now = DateTime.now();
    final targetTimeMs = value.toInt();
    final lastRequestedTimeMs = _lastSeekPreviewRequestTimeMs;
    final lastRequestedAt = _lastSeekPreviewRequestAt;
    final bool changedEnough =
        lastRequestedTimeMs == null ||
        (targetTimeMs - lastRequestedTimeMs).abs() >= _seekPreviewMinStepMs;
    final bool intervalPassed =
        lastRequestedAt == null ||
        now.difference(lastRequestedAt) >= _seekPreviewMinInterval;

    if (immediate ||
        (intervalPassed && (changedEnough || _previewImage == null))) {
      _cancelSeekPreviewThrottle();
      _updateSeekPreview(value);
      return;
    }

    _pendingSeekPreviewValue = value;
    if (_seekPreviewThrottleTimer?.isActive ?? false) {
      return;
    }

    final remaining = lastRequestedAt == null
        ? Duration.zero
        : _seekPreviewMinInterval - now.difference(lastRequestedAt);
    _seekPreviewThrottleTimer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () {
        _seekPreviewThrottleTimer = null;
        final pendingValue = _pendingSeekPreviewValue;
        if (!mounted ||
            !_isSeekPreviewInteractionActive ||
            pendingValue == null) {
          return;
        }
        final pendingTimeMs = pendingValue.toInt();
        final bool shouldRequest =
            _lastSeekPreviewRequestTimeMs == null ||
            pendingTimeMs != _lastSeekPreviewRequestTimeMs! ||
            _previewImage == null;
        if (shouldRequest) {
          _pendingSeekPreviewValue = null;
          _updateSeekPreview(pendingValue);
        }
      },
    );
  }

  void _updateSeekPreview(
    double value, {
    bool precise = false,
    int? expectedTimeMs,
  }) {
    if (!widget.enableSeekThumbnailPreview) {
      _previewImage = null;
      _videoShotFrame = null;
      return;
    }
    final settings = Provider.of<SettingsService>(context, listen: false);
    if (!settings.enableSeekPreview) {
      _previewImage = null;
      _videoShotFrame = null;
      return;
    }

    final requestTimeMs = value.toInt();
    final videoShot = widget.bilibiliVideoShot;
    if (videoShot?.isUsable == true) {
      if (!precise) {
        _lastSeekPreviewRequestAt = DateTime.now();
        _lastSeekPreviewRequestTimeMs = requestTimeMs;
        _pendingSeekPreviewValue = null;
      }
      final frame = videoShot!.frameAt(requestTimeMs);
      if (mounted &&
          _isSeekPreviewInteractionActive &&
          (expectedTimeMs == null ||
              _isCurrentSeekPreviewTarget(
                expectedTimeMs.toDouble(),
                tolerance: 1.0,
              ))) {
        setState(() {
          _previewRequestSerial++;
          _previewImage = null;
          _videoShotFrame = frame;
        });
      }
      return;
    }

    final filePath = _resolvePreviewFilePath();
    if (filePath == null) {
      return;
    }

    final int requestSerial = ++_previewRequestSerial;
    if (!precise) {
      _lastSeekPreviewRequestAt = DateTime.now();
      _lastSeekPreviewRequestTimeMs = requestTimeMs;
      _pendingSeekPreviewValue = null;
    }
    final future = precise
        ? VideoPreviewService().requestPrecisePreview(filePath, requestTimeMs)
        : VideoPreviewService().requestPreview(filePath, requestTimeMs);
    future.then((data) {
      if (mounted &&
          _isSeekPreviewInteractionActive &&
          (expectedTimeMs == null ||
              _isCurrentSeekPreviewTarget(
                expectedTimeMs.toDouble(),
                tolerance: 1.0,
              )) &&
          requestSerial == _previewRequestSerial &&
          (data != null)) {
        setState(() {
          _videoShotFrame = null;
          _previewImage = data;
        });
      }
    });
  }

  void _updateProgressHover({
    required double localDx,
    required Offset globalPosition,
    required double width,
    required double sliderMax,
    required double trackInset,
    required TextDirection textDirection,
  }) {
    // A pressed mouse sends move events through the slider, not through the
    // hover-preview state. Keeping the two paths separate prevents a hover
    // rebuild from replacing the slider while it owns the drag gesture.
    // A finger also owns the preview: a parked cursor must not bring it back.
    if (_shouldIgnoreMouseActivity() ||
        !TooltipHoverPolicy.acceptHover(globalPosition) ||
        _isDraggingProgress ||
        widget.isLocked ||
        sliderMax <= 0) {
      return;
    }
    final value = progressValueFromLocalDx(
      localDx: localDx,
      width: width,
      maxValue: sliderMax,
      trackInset: trackInset,
      textDirection: textDirection,
    );
    final previous = _hoverProgressValue;
    if (!_isProgressHovered ||
        previous == null ||
        (previous - value).abs() > 1) {
      setState(() {
        _isProgressHovered = true;
        _hoverProgressValue = value;
      });
    }
    _cancelAutoHideTimer();
    _scheduleLiveSeekPreview(value, immediate: previous == null);
    _schedulePreciseSeekPreview(value);
  }

  void _endProgressHover() {
    if (!_isProgressHovered && _hoverProgressValue == null) return;
    if (_isDraggingProgress) {
      setState(() {
        _isProgressHovered = false;
        _hoverProgressValue = null;
      });
      return;
    }
    _cancelSeekPreviewRefine();
    _resetSeekPreviewRequestState();
    setState(() {
      _isProgressHovered = false;
      _hoverProgressValue = null;
      if (!_isDraggingProgress) {
        _previewRequestSerial++;
        _previewImage = null;
        _videoShotFrame = null;
      }
    });
    if (!_isDraggingProgress) {
      VideoPreviewService().markInteractionEnded();
      if (!_lastPointerInputWasTouch && !_shouldIgnoreMouseActivity()) {
        _startAutoHideTimer();
      }
    }
  }

  /// Finger contact ends a mouse hover preview. The drag that follows owns the
  /// thumbnail itself, and releasing that drag must not restore the old hover.
  void _dismissHoverPreviewForTouch() {
    if (!_isProgressHovered && _hoverProgressValue == null) return;
    if (_isDraggingProgress) {
      setState(() {
        _isProgressHovered = false;
        _hoverProgressValue = null;
      });
      return;
    }
    _cancelSeekPreviewRefine();
    _resetSeekPreviewRequestState();
    setState(() {
      _isProgressHovered = false;
      _hoverProgressValue = null;
      _previewRequestSerial++;
      _previewImage = null;
      _videoShotFrame = null;
    });
    VideoPreviewService().markInteractionEnded();
  }

  int _chapterIndexAt(double value) {
    if (widget.chapters.isEmpty) return -1;
    final chapter = MediaChapter.atPosition(
      widget.chapters,
      Duration(milliseconds: value.toInt()),
    );
    return chapter == null ? -1 : widget.chapters.indexOf(chapter);
  }

  void _beginProgressDrag(double value) {
    final chapterIndex = _chapterIndexAt(value);
    setState(() {
      _isDraggingProgress = true;
      _progressDragWasCancelled = false;
      _dragProgressValue = value;
      _dragChapterIndex = chapterIndex;
      if (_isProgressHovered) {
        _hoverProgressValue = value;
      }
    });
    final settings = Provider.of<SettingsService>(context, listen: false);
    unawaited(AppHaptics.selectionClick(settings));
    _scheduleLiveSeekPreview(value, immediate: true);
    _schedulePreciseSeekPreview(value);
    _cancelAutoHideTimer();
  }

  void _updateProgressDrag(double value) {
    final chapterIndex = _chapterIndexAt(value);
    final crossedChapter =
        _dragChapterIndex != null &&
        chapterIndex >= 0 &&
        chapterIndex != _dragChapterIndex;
    setState(() {
      _isDraggingProgress = true;
      _dragProgressValue = value;
      _dragChapterIndex = chapterIndex;
      if (_isProgressHovered) {
        _hoverProgressValue = value;
      }
    });
    if (crossedChapter) {
      final settings = Provider.of<SettingsService>(context, listen: false);
      unawaited(AppHaptics.selectionClick(settings));
    }
    _scheduleLiveSeekPreview(value);
    _schedulePreciseSeekPreview(value);
    _cancelAutoHideTimer();
  }

  void _finishProgressDrag(double value) {
    _cancelSeekPreviewRefine();
    _resetSeekPreviewRequestState();
    final cancelSeek = _isProgressDragCanceling || _progressDragWasCancelled;
    if (!cancelSeek) {
      _seekTo(Duration(milliseconds: value.toInt()));
    }
    setState(() {
      _previewRequestSerial++;
      _isDraggingProgress = false;
      _dragChapterIndex = null;
      if (_isProgressHovered) {
        _hoverProgressValue = value;
      } else {
        _previewImage = null;
        _videoShotFrame = null;
      }
      _isProgressDragCanceling = false;
      _progressDragWasCancelled = false;
    });
    if (_isProgressHovered) {
      _scheduleLiveSeekPreview(value, immediate: true);
      _schedulePreciseSeekPreview(value);
    } else {
      VideoPreviewService().markInteractionEnded();
      _startAutoHideTimer();
    }
  }

  void _cancelProgressDrag() {
    if (!_isDraggingProgress) return;
    _cancelSeekPreviewRefine();
    _resetSeekPreviewRequestState();
    setState(() {
      _isDraggingProgress = false;
      _progressDragWasCancelled = true;
      _dragChapterIndex = null;
      if (!_isProgressHovered) {
        _previewRequestSerial++;
        _previewImage = null;
        _videoShotFrame = null;
      }
      _isProgressDragCanceling = false;
    });
    if (_isProgressHovered && _hoverProgressValue != null) {
      _scheduleLiveSeekPreview(_hoverProgressValue!, immediate: true);
      _schedulePreciseSeekPreview(_hoverProgressValue!);
    } else {
      VideoPreviewService().markInteractionEnded();
      _startAutoHideTimer();
    }
  }

  Widget _buildSeekPreviewOverlay({
    required double progressWidth,
    required double sliderMax,
    required double previewValue,
    required double trackInset,
    required TextDirection textDirection,
    required double bottom,
    required bool showThumbnail,
  }) {
    final preferredWidth = (progressWidth * 0.2).clamp(132.0, 180.0);
    final previewWidth = math.min(progressWidth, preferredWidth).toDouble();
    final previewHeight = previewWidth * 9 / 16;
    final anchorX = progressLocalDxFromValue(
      value: previewValue,
      width: progressWidth,
      maxValue: sliderMax,
      trackInset: trackInset,
      textDirection: textDirection,
    );
    final maxLeft = math.max(0.0, progressWidth - previewWidth);
    final left = (anchorX - (previewWidth / 2)).clamp(0.0, maxLeft);

    return Positioned(
      key: const ValueKey('video-controls-seek-preview'),
      left: left,
      bottom: bottom,
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          key: ValueKey<String>(
            _isDraggingProgress ? 'seek-preview-drag' : 'seek-preview-hover',
          ),
          tween: Tween<double>(begin: 0.94, end: 1),
          duration: const Duration(milliseconds: 130),
          curve: Curves.easeOutCubic,
          builder: (context, animation, child) => Opacity(
            opacity: animation,
            child: Transform.scale(
              scale: animation,
              alignment: Alignment.bottomCenter,
              child: child,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (showThumbnail) ...<Widget>[
                Container(
                  width: previewWidth,
                  height: previewHeight,
                  decoration: BoxDecoration(
                    color: const Color(0xFF151515),
                    border: Border.all(color: Colors.white70, width: 1.2),
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(
                        color: Colors.black54,
                        blurRadius: 8,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6.5),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 110),
                      switchInCurve: Curves.easeOut,
                      child:
                          _videoShotFrame != null &&
                              widget.bilibiliVideoShot != null
                          ? _buildBilibiliVideoShotFrame(
                              widget.bilibiliVideoShot!,
                              _videoShotFrame!,
                              previewWidth,
                              previewHeight,
                            )
                          : _previewImage == null
                          ? const ColoredBox(
                              key: ValueKey('seek-preview-loading'),
                              color: Color(0xFF202020),
                              child: Center(
                                child: Icon(
                                  Icons.image_search_rounded,
                                  color: Colors.white38,
                                  size: 24,
                                ),
                              ),
                            )
                          : Image.memory(
                              _previewImage!,
                              key: ValueKey<int>(
                                Object.hash(
                                  _previewImage!.length,
                                  _lastSeekPreviewRequestTimeMs,
                                ),
                              ),
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 5),
              ],
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.78),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  child: Text(
                    _formatDuration(
                      Duration(milliseconds: previewValue.toInt()),
                    ),
                    key: const ValueKey('video-controls-seek-preview-time'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBilibiliVideoShotFrame(
    BilibiliVideoShot videoShot,
    BilibiliVideoShotFrame frame,
    double width,
    double height,
  ) {
    return SizedBox(
      width: width,
      height: height,
      child: BilibiliSpritePreview(
        key: ValueKey<String>('bilibili-sprite-page-${frame.spriteIndex}'),
        cellKey: ValueKey<String>(
          'bilibili-video-shot-${frame.spriteIndex}-${frame.row}-${frame.column}',
        ),
        path: frame.spritePath,
        column: frame.column,
        row: frame.row,
        columns: videoShot.columns,
        rows: videoShot.rows,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    // Episode changes and portrait→landscape handoff unmount this overlay.
    // Restore the chrome that was showing instead of forcing it back on.
    _showControls = widget.initialShowControls;
    widget.onControlsVisibilityIntent?.call(_showControls);
    _publishPlaybackControlsVisibility();
    _effectiveFocusNode.addListener(_handleKeyboardFocusChange);
    HardwareKeyboard.instance.addHandler(_handleGlobalHardwareKeyEvent);
    AndroidHardwareInputBridge.addKeyListener(_handleAndroidHardwareKeyEvent);
    if (Platform.isAndroid) {
      VolumeController.instance.showSystemUI = false;
    }
    _warmSeekPreviewMetadata();
    _initVolumeBrightness();
    _rebuildSubtitleIndex();
    // Auto request focus to enable keyboard listening
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _requestKeyboardFocus();
      }
    });
    if (_showControls) {
      _startAutoHideTimer();
    } else {
      // Remounting MouseRegion synthesizes enter/hover while the pointer is
      // still over the player. That is leftover position, not new activity.
      _suppressMouseActivityFor(_episodeSwitchMouseSuppression);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindTransportService();
  }

  @override
  void didUpdateWidget(VideoControlsOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _syncOwnedTransportPlaying();
    }
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _focusNode).removeListener(
        _handleKeyboardFocusChange,
      );
      _resetKeyboardPressStateAfterBuild();
      _effectiveFocusNode.addListener(_handleKeyboardFocusChange);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _requestKeyboardFocus();
      });
    }
    if (!oldWidget.isLocked && widget.isLocked) {
      _resetKeyboardPressStateAfterBuild();
      VideoPreviewService().markInteractionEnded();
      _cancelSeekPreviewRefine();
      _resetSeekPreviewRequestState();
      _previewRequestSerial++;
      _isDraggingProgress = false;
      _desktopProgressPointer = null;
      _isProgressHovered = false;
      _hoverProgressValue = null;
      _dragChapterIndex = null;
      _previewImage = null;
      _videoShotFrame = null;
      _isProgressDragCanceling = false;
      _progressDragWasCancelled = false;
      _invalidateVerticalAdjustmentSession();
      _isAdjustingVolume = false;
      _isAdjustingBrightness = false;
      // Locked mobile controls still need to disappear after inactivity. Keep
      // the unlock affordance visible briefly, then let the normal timer fade
      // it out; a tap on the player surface will reveal it again.
      if (_autoHideLockedControls) {
        _startAutoHideTimer();
      }
    }
    if (oldWidget.enableSeekThumbnailPreview &&
        !widget.enableSeekThumbnailPreview) {
      VideoPreviewService().markInteractionEnded();
      _cancelSeekPreviewRefine();
      _resetSeekPreviewRequestState();
      _previewRequestSerial++;
      _previewImage = null;
      _videoShotFrame = null;
    }
    if (oldWidget.subtitles != widget.subtitles) {
      _rebuildSubtitleIndex();
    }
    final sourceChanged =
        (oldWidget.controller?.dataSource ?? '') != _controllerDataSource;
    final shotChanged = oldWidget.bilibiliVideoShot != widget.bilibiliVideoShot;
    if (sourceChanged) {
      VideoPreviewService().markInteractionEnded();
      _cancelSeekPreviewRefine();
      _resetSeekPreviewRequestState();
      _previewRequestSerial++;
      _previewImage = null;
      _videoShotFrame = null;
      _isDraggingProgress = false;
      _desktopProgressPointer = null;
      _isProgressHovered = false;
      _hoverProgressValue = null;
      _dragChapterIndex = null;
      _isProgressDragCanceling = false;
      _progressDragWasCancelled = false;
      _warmSeekPreviewMetadata();
    } else if (shotChanged) {
      _previewImage = null;
      _videoShotFrame = null;
      if (_isSeekPreviewInteractionActive) {
        final value = _isDraggingProgress
            ? _dragProgressValue
            : _hoverProgressValue;
        if (value != null) _updateSeekPreview(value);
      }
    }
  }

  @override
  void dispose() {
    VideoPreviewService().markInteractionEnded();
    AndroidHardwareInputBridge.removeKeyListener(
      _handleAndroidHardwareKeyEvent,
    );
    HardwareKeyboard.instance.removeHandler(_handleGlobalHardwareKeyEvent);
    _effectiveFocusNode.removeListener(_handleKeyboardFocusChange);
    _resetKeyboardPressState(notify: false, endSpeedBoost: false);
    _focusNode.dispose();
    _singleTapTimer?.cancel();
    _seekResetTimer?.cancel();
    _seekDebounceTimer?.cancel();
    _cancelSeekPreviewRefine();
    _resetSeekPreviewRequestState();
    _doubleTapFeedbackHideTimer?.cancel();
    _doubleTapFeedbackDismissTimer?.cancel();
    _autoHideTimer?.cancel();
    _mouseActivitySuppressionTimer?.cancel();
    _touchReleaseAutoHideTimer?.cancel();
    _subtitleAvoidanceReleaseTimer?.cancel();
    _stopKeyboardVolumeHold();
    _volumeFeedbackHideTimer?.cancel();
    _transportService?.removeListener(_syncOwnedTransportPlaying);
    _unavailableControllerValue.dispose();
    _ownedTransportPlaying.dispose();
    super.dispose();
  }

  // Start or reset the auto-hide timer
  bool get _autoHideLockedControls =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  void _startAutoHideTimer() {
    _autoHideTimer?.cancel();
    if (_isControlDialogOpen) {
      return;
    }
    _autoHideTimer = Timer(_autoHideDelay, () {
      if (mounted &&
          _showControls &&
          (!widget.isLocked || _autoHideLockedControls) &&
          !_isDraggingProgress &&
          !_isProgressHovered) {
        setState(() {
          _setShowControls(false);
        });
      }
    });
  }

  // Cancel the auto-hide timer
  void _cancelAutoHideTimer() {
    _autoHideTimer?.cancel();
    _autoHideTimer = null;
  }

  // Desktop: The MouseRegion covers the complete player surface, including
  // any black letterbox/pillarbox space around the video.
  void _showControlsForMouseActivity() {
    if (widget.isLocked) return;

    if (!_showControls) {
      setState(() {
        _setShowControls(true);
      });
    }

    // Entering or moving inside the player both count as fresh activity.
    _startAutoHideTimer();
  }

  void _onMouseEnter(PointerEnterEvent event) {
    if (_shouldIgnoreMouseActivity()) return;
    if (!TooltipHoverPolicy.acceptHover(event.position)) return;
    _lastPointerInputWasTouch = false;
    _showControlsForMouseActivity();
  }

  void _onMouseHover(PointerHoverEvent event) {
    if (_shouldIgnoreMouseActivity()) return;
    if (!TooltipHoverPolicy.acceptHover(event.position)) return;
    _lastPointerInputWasTouch = false;
    _showControlsForMouseActivity();
  }

  void _onMouseExit(PointerExitEvent event) {
    if (widget.isLocked) return;
    if (_lastPointerInputWasTouch || _activeTouchPointers.isNotEmpty) return;

    // Do not leave a stale timer running after the pointer has entered a
    // sidebar (or any other non-player area).
    _cancelAutoHideTimer();
    if (_showControls) {
      setState(() {
        _setShowControls(false);
      });
    }
  }

  bool _isTouchLikePointer(PointerDeviceKind kind) {
    return kind == PointerDeviceKind.touch ||
        kind == PointerDeviceKind.stylus ||
        kind == PointerDeviceKind.invertedStylus;
  }

  bool _shouldIgnoreMouseActivity() {
    return _activeTouchPointers.isNotEmpty || _suppressMouseActivity;
  }

  void _suppressMouseActivityFor(Duration duration) {
    _suppressMouseActivity = true;
    _mouseActivitySuppressionTimer?.cancel();
    _mouseActivitySuppressionTimer = Timer(duration, () {
      _suppressMouseActivity = false;
    });
  }

  void _onPlayerPointerDown(PointerDownEvent event) {
    _requestKeyboardFocus();
    if (_isTouchLikePointer(event.kind)) {
      _activeTouchPointers.add(event.pointer);
      _lastPointerInputWasTouch = true;
      _suppressMouseActivityFor(const Duration(milliseconds: 180));
      _touchReleaseAutoHideTimer?.cancel();
      _cancelAutoHideTimer();
      _dismissHoverPreviewForTouch();
    } else if (event.kind == PointerDeviceKind.mouse) {
      if (_shouldIgnoreMouseActivity()) return;
      _lastPointerInputWasTouch = false;
    }
  }

  void _finishPlayerPointer(PointerEvent event) {
    if (!_isTouchLikePointer(event.kind)) return;
    _activeTouchPointers.remove(event.pointer);
    if (_activeTouchPointers.isNotEmpty) return;
    _suppressMouseActivityFor(const Duration(milliseconds: 120));

    // Let the single/double-tap recognizer decide visibility first, then put
    // touch mode back on the normal inactivity timer even after button taps.
    _touchReleaseAutoHideTimer?.cancel();
    _touchReleaseAutoHideTimer = Timer(const Duration(milliseconds: 260), () {
      if (!mounted ||
          _activeTouchPointers.isNotEmpty ||
          !_lastPointerInputWasTouch ||
          !_showControls ||
          _isDraggingProgress ||
          _isGestureSeeking) {
        return;
      }
      _startAutoHideTimer();
    });
  }

  FocusNode get _effectiveFocusNode => widget.focusNode ?? _focusNode;

  void _requestKeyboardFocus() {
    final FocusNode focusNode = _effectiveFocusNode;
    if (mounted && focusNode.canRequestFocus && !focusNode.hasFocus) {
      focusNode.requestFocus();
    }
  }

  void _handleKeyboardFocusChange() {
    if (_effectiveFocusNode.hasFocus) return;
    // Windows can move focus before a character key's key-up arrives. Dropping
    // that press swallows Space. Keep taps that have not become a hold; key-up
    // still commits them. A hold that already started ends with focus.
    _stopKeyboardVolumeHold();
    final pendingTaps = <LogicalKeyboardKey, _KeyboardPressState>{};
    for (final MapEntry<LogicalKeyboardKey, _KeyboardPressState> entry
        in _keyboardPressStates.entries) {
      entry.value.timer?.cancel();
      if (!entry.value.longPressTriggered) {
        pendingTaps[entry.key] = entry.value;
      }
    }
    final bool endedBoost =
        _activeSpeedBoostKey != null &&
        !pendingTaps.containsKey(_activeSpeedBoostKey);
    _keyboardPressStates
      ..clear()
      ..addAll(pendingTaps);
    if (endedBoost) {
      _activeSpeedBoostKey = null;
      _endZoneLongPress();
    }
    if (_isKeyboardLongPressing) {
      _isKeyboardLongPressing = false;
      if (mounted) setState(() {});
    }
  }

  void _resetKeyboardPressState({
    bool notify = true,
    bool endSpeedBoost = true,
  }) {
    final bool shouldEndSpeedBoost = _activeSpeedBoostKey != null;
    for (final _KeyboardPressState state in _keyboardPressStates.values) {
      state.timer?.cancel();
    }
    _keyboardPressStates.clear();
    _activeSpeedBoostKey = null;
    _stopKeyboardVolumeHold();
    if (shouldEndSpeedBoost && endSpeedBoost) {
      _endZoneLongPress();
    }
    if (_isKeyboardLongPressing) {
      _isKeyboardLongPressing = false;
      if (notify && mounted) setState(() {});
    }
  }

  void _resetKeyboardPressStateAfterBuild() {
    final bool shouldEndSpeedBoost = _activeSpeedBoostKey != null;
    _resetKeyboardPressState(endSpeedBoost: false);
    if (shouldEndSpeedBoost) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _endZoneLongPress();
      });
    }
  }

  bool get _supportsPlayerKeyboardShortcuts {
    return supportsNativeHardwareKeyboardShortcuts;
  }

  bool get _showsPointerShortcutHints {
    return !kIsWeb && supportsPlayerPointerHoverOn(defaultTargetPlatform);
  }

  bool _isTextInputFocused() {
    final BuildContext? focusContext =
        FocusManager.instance.primaryFocus?.context;
    if (focusContext == null) return false;
    return focusContext.widget is EditableText ||
        focusContext.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  String _tooltipWithShortcut(
    String label,
    DesktopPlayerShortcutAction action,
  ) {
    final platform = currentNativeTargetPlatform;
    if (!_showsPointerShortcutHints ||
        platform == null ||
        !DesktopPlayerShortcuts.isAvailableOnPlatform(action, platform)) {
      return label;
    }
    return DesktopPlayerShortcuts.buildTooltip(label, action);
  }

  void _dispatchDesktopShortcut(DesktopPlayerShortcutAction action) {
    // Toggle actions (sidebar B, episode picker G, mute, subtitles) cancel
    // themselves if Flutter and the Android Activity bridge both deliver the
    // same physical press a few milliseconds apart.
    final DateTime now = DateTime.now();
    final DateTime? lastAt = _lastDispatchedShortcutAt;
    if (lastAt != null &&
        _lastDispatchedShortcutAction == action &&
        now.difference(lastAt) <
            AndroidHardwareKeyDeduplicator.duplicateArrivalWindow) {
      return;
    }
    _lastDispatchedShortcutAction = action;
    _lastDispatchedShortcutAt = now;
    switch (action) {
      case DesktopPlayerShortcutAction.back:
        _startAutoHideTimer();
        widget.onBackPressed();
        return;
      case DesktopPlayerShortcutAction.playPause:
        if (!_controllerValue.isInitialized &&
            !widget.allowPlayWhenUninitialized) {
          return;
        }
        _startAutoHideTimer();
        widget.onTogglePlay();
        return;
      case DesktopPlayerShortcutAction.seekBackward:
        if (!_controllerValue.isInitialized) return;
        _startAutoHideTimer();
        final Duration target =
            _controllerValue.position -
            Duration(seconds: widget.doubleTapSeekSeconds);
        _seekTo(target < Duration.zero ? Duration.zero : target);
        return;
      case DesktopPlayerShortcutAction.seekForward:
        if (!_controllerValue.isInitialized) return;
        _startAutoHideTimer();
        final Duration target =
            _controllerValue.position +
            Duration(seconds: widget.doubleTapSeekSeconds);
        final Duration duration = _controllerValue.duration;
        _seekTo(target > duration ? duration : target);
        return;
      case DesktopPlayerShortcutAction.openSettings:
        if (widget.onOpenSettings == null) return;
        _startAutoHideTimer();
        widget.onOpenSettings!();
        return;
      case DesktopPlayerShortcutAction.openSubtitleLibrary:
        if (widget.onOpenSubtitleManager == null) return;
        _startAutoHideTimer();
        widget.onOpenSubtitleManager!();
        return;
      case DesktopPlayerShortcutAction.openSubtitleEditor:
        if (widget.onOpenSubtitleEditor == null ||
            !widget.showSubtitleEditorButton) {
          return;
        }
        _startAutoHideTimer();
        widget.onOpenSubtitleEditor!();
        return;
      case DesktopPlayerShortcutAction.openVideoCompose:
        if (widget.onOpenVideoCompose == null) return;
        _startAutoHideTimer();
        widget.onOpenVideoCompose!();
        return;
      case DesktopPlayerShortcutAction.openSubtitleStyle:
        if (widget.onToggleFloatingSubtitleSettings == null) return;
        _startAutoHideTimer();
        widget.onToggleFloatingSubtitleSettings!();
        return;
      case DesktopPlayerShortcutAction.moveSubtitles:
        _startAutoHideTimer();
        widget.onMoveSubtitles();
        return;
      case DesktopPlayerShortcutAction.toggleSubtitleSidebar:
        if (widget.onToggleSidebar == null) return;
        _startAutoHideTimer();
        widget.onToggleSidebar!();
        return;
      case DesktopPlayerShortcutAction.toggleFullScreen:
        if (widget.onToggleFullScreen == null) return;
        _startAutoHideTimer();
        widget.onToggleFullScreen!();
        return;
      case DesktopPlayerShortcutAction.openAspectRatio:
        if (widget.onOpenAspectRatio == null ||
            widget.aspectRatioLabel == null) {
          return;
        }
        _startAutoHideTimer();
        widget.onOpenAspectRatio!();
        return;
      case DesktopPlayerShortcutAction.toggleEpisodePicker:
        if (widget.onToggleEpisodePicker == null) return;
        _startAutoHideTimer();
        widget.onToggleEpisodePicker!();
        return;
      case DesktopPlayerShortcutAction.previousEpisode:
        if (widget.onPlayPrevious == null || !widget.hasPrevious) return;
        widget.onPlayPrevious!();
        return;
      case DesktopPlayerShortcutAction.nextEpisode:
        if (widget.onPlayNext == null || !widget.hasNext) return;
        widget.onPlayNext!();
        return;
      case DesktopPlayerShortcutAction.toggleSubtitles:
        _startAutoHideTimer();
        widget.onToggleSubtitles();
        return;
      case DesktopPlayerShortcutAction.toggleMute:
        final playbackService = Provider.of<MediaPlaybackService>(
          context,
          listen: false,
        );
        _startAutoHideTimer();
        unawaited(playbackService.toggleMute());
        return;
      case DesktopPlayerShortcutAction.volumeUp:
        unawaited(_handleVolumeKeyDown(1));
        return;
      case DesktopPlayerShortcutAction.volumeDown:
        unawaited(_handleVolumeKeyDown(-1));
        return;
      case DesktopPlayerShortcutAction.speedSlower:
        unawaited(_nudgePlaybackSpeedPreset(slower: true));
        return;
      case DesktopPlayerShortcutAction.speedFaster:
        unawaited(_nudgePlaybackSpeedPreset(slower: false));
        return;
      case DesktopPlayerShortcutAction.openChapters:
        if (widget.onOpenChapters == null || widget.chapters.isEmpty) return;
        _startAutoHideTimer();
        widget.onOpenChapters!();
        return;
      case DesktopPlayerShortcutAction.toggleLock:
        _startAutoHideTimer();
        widget.onToggleLock();
        return;
      case DesktopPlayerShortcutAction.toggleDanmaku:
        if (!widget.showDanmakuControls || widget.onToggleDanmaku == null) {
          return;
        }
        _startAutoHideTimer();
        widget.onToggleDanmaku!();
        return;
      case DesktopPlayerShortcutAction.openDanmakuSettings:
        if (!widget.showDanmakuControls ||
            widget.onOpenDanmakuSettings == null) {
          return;
        }
        _startAutoHideTimer();
        widget.onOpenDanmakuSettings!();
        return;
      case DesktopPlayerShortcutAction.openOcrSubtitle:
        if (widget.onOpenOcrSubtitle == null) return;
        _startAutoHideTimer();
        widget.onOpenOcrSubtitle!();
        return;
      case DesktopPlayerShortcutAction.openStreamQuality:
        final playbackService = Provider.of<MediaPlaybackService>(
          context,
          listen: false,
        );
        if (!playbackService.isCurrentItemBilibiliStream ||
            playbackService.streamQualities.isEmpty ||
            playbackService.isSwitchingStreamQuality) {
          return;
        }
        _startAutoHideTimer();
        unawaited(_showStreamQualityPicker(playbackService, context));
        return;
      case DesktopPlayerShortcutAction.resetScreen:
        if (widget.onResetScreenTransform == null ||
            widget.showResetScreenButton == false) {
          return;
        }
        _startAutoHideTimer();
        widget.onResetScreenTransform!();
        return;
      case DesktopPlayerShortcutAction.openSleepTimer:
        if (widget.onOpenSleepTimer == null) return;
        _startAutoHideTimer();
        widget.onOpenSleepTimer!();
        return;
    }
  }

  /// Session-only notch: never writes [SettingsService.setPlaybackSpeedLock].
  Future<void> _nudgePlaybackSpeedPreset({required bool slower}) async {
    if (widget.isLongPressing ||
        _isKeyboardLongPressing ||
        _activeSpeedBoostKey != null) {
      return;
    }
    final next = nextPlaybackSpeedPreset(
      _controllerValue.playbackSpeed,
      direction: slower ? -1 : 1,
    );
    if (next == null) return;
    if (!_showControls) {
      setState(() => _setShowControls(true));
    }
    _startAutoHideTimer();
    await widget.onSpeedUpdate(next);
  }

  // Handle Key Events
  bool _handleGlobalHardwareKeyEvent(KeyEvent event) {
    return handleKeyEvent(_effectiveFocusNode, event) != KeyEventResult.ignored;
  }

  KeyEventResult handleKeyEvent(FocusNode node, KeyEvent event) {
    if (identical(_lastRoutedKeyEvent, event)) {
      return _lastRoutedKeyEventResult;
    }
    _lastRoutedKeyEvent = event;
    _lastRoutedKeyEventResult = _handleKeyEvent(node, event);
    return _lastRoutedKeyEventResult;
  }

  void _handleAndroidHardwareKeyEvent(AndroidHardwareKeyMessage message) {
    _handleKeyEvent(
      _effectiveFocusNode,
      message.toKeyEvent(),
      fromAndroidNativeBridge: true,
      hasBlockingModifierOverride: message.hasBlockingModifier,
      isShiftPressedOverride: message.isShiftPressed,
    );
  }

  @visibleForTesting
  void handleAndroidHardwareKeyEventForTest(AndroidHardwareKeyMessage message) {
    _handleAndroidHardwareKeyEvent(message);
  }

  KeyEventResult _handleKeyEvent(
    FocusNode node,
    KeyEvent event, {
    bool fromAndroidNativeBridge = false,
    bool? hasBlockingModifierOverride,
    bool? isShiftPressedOverride,
  }) {
    if (!_supportsPlayerKeyboardShortcuts) return KeyEventResult.ignored;
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return KeyEventResult.ignored;
    if (Platform.isAndroid &&
        !_androidKeyDeduplicator.shouldDispatch(
          event,
          fromNativeBridge: fromAndroidNativeBridge,
        )) {
      return KeyEventResult.handled;
    }
    final key = event.logicalKey;
    final bool hasBlockingModifier =
        hasBlockingModifierOverride ??
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isAltPressed ||
            HardwareKeyboard.instance.isMetaPressed);
    final bool isShiftPressed =
        isShiftPressedOverride ?? HardwareKeyboard.instance.isShiftPressed;
    final DesktopPlayerShortcutAction? matchedAction = hasBlockingModifier
        ? null
        : DesktopPlayerShortcuts.matchAction(key, shiftPressed: isShiftPressed);
    final platform = currentNativeTargetPlatform;
    final DesktopPlayerShortcutAction? shortcutAction =
        matchedAction != null &&
            platform != null &&
            DesktopPlayerShortcuts.isAvailableOnPlatform(
              matchedAction,
              platform,
            )
        ? matchedAction
        : null;
    final bool isVolumeKey =
        shortcutAction == DesktopPlayerShortcutAction.volumeUp ||
        shortcutAction == DesktopPlayerShortcutAction.volumeDown;
    final bool isSpeedNudgeKey =
        shortcutAction == DesktopPlayerShortcutAction.speedSlower ||
        shortcutAction == DesktopPlayerShortcutAction.speedFaster;
    // Shift+arrows own the speed notches; they must not start seek or hold-boost.
    final bool isTemporarySpeedBoostKey =
        !isSpeedNudgeKey &&
        (key == LogicalKeyboardKey.space ||
            key == LogicalKeyboardKey.arrowRight);
    final bool isLongPressKey =
        isTemporarySpeedBoostKey ||
        (!isSpeedNudgeKey && key == LogicalKeyboardKey.arrowLeft) ||
        (key == LogicalKeyboardKey.escape &&
            shortcutAction == DesktopPlayerShortcutAction.back);

    if (!isLongPressKey &&
        !isVolumeKey &&
        !isSpeedNudgeKey &&
        shortcutAction == null) {
      return KeyEventResult.ignored;
    }

    // If focus is in a TextField, don't intercept player shortcuts.
    if (_isTextInputFocused() || hasBlockingModifier) {
      return KeyEventResult.ignored;
    }

    // Locked mode still allows unlock (K) and volume; other player keys
    // are consumed so they cannot leak to the page underneath.
    if (widget.isLocked) {
      if (shortcutAction == DesktopPlayerShortcutAction.toggleLock) {
        if (event is KeyDownEvent) {
          _dispatchDesktopShortcut(shortcutAction!);
        }
        return KeyEventResult.handled;
      }
      if (isVolumeKey) {
        final int direction =
            shortcutAction == DesktopPlayerShortcutAction.volumeUp ? 1 : -1;
        if (event is KeyRepeatEvent) return KeyEventResult.handled;
        if (event is KeyDownEvent) {
          unawaited(_handleVolumeKeyDown(direction));
          return KeyEventResult.handled;
        }
        if (event is KeyUpEvent) {
          _handleVolumeKeyUp(direction);
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.handled;
    }

    if (isSpeedNudgeKey) {
      if (event is KeyDownEvent) {
        _dispatchDesktopShortcut(shortcutAction!);
      }
      return KeyEventResult.handled;
    }

    if (isVolumeKey) {
      final int direction =
          shortcutAction == DesktopPlayerShortcutAction.volumeUp ? 1 : -1;
      if (event is KeyRepeatEvent) {
        // OS repeats are ignored; hold ticks use a capped timer so volume
        // cannot jump by tens of percent in a single burst.
        return KeyEventResult.handled;
      }
      if (event is KeyDownEvent) {
        unawaited(_handleVolumeKeyDown(direction));
        return KeyEventResult.handled;
      }
      if (event is KeyUpEvent) {
        _handleVolumeKeyUp(direction);
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    // Right-arrow / space holds become a temporary speed boost, so their OS
    // repeats must not also fire seeks. Left-arrow holds keep seeking backward.
    if (event is KeyRepeatEvent) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        final _KeyboardPressState? state = _keyboardPressStates[key];
        if (state != null) {
          state.timer?.cancel();
          state.longPressTriggered = true;
          _handleArrowTap(isLeft: true);
        }
      }
      return KeyEventResult.handled;
    }

    if (event is KeyDownEvent) {
      if (!isLongPressKey && shortcutAction != null) {
        _dispatchDesktopShortcut(shortcutAction);
      } else if (isLongPressKey) {
        _handleLongPressKeyDown(key, event.timeStamp);
      }
      return KeyEventResult.handled;
    } else if (event is KeyUpEvent) {
      if (isLongPressKey) _handleLongPressKeyUp(key, event.timeStamp);
      return KeyEventResult.handled;
    }

    return KeyEventResult.handled;
  }

  void _handleLongPressKeyDown(LogicalKeyboardKey key, Duration timeStamp) {
    final _KeyboardPressState? existing = _keyboardPressStates[key];
    if (existing != null) {
      // A second down means the previous up was lost. An in-progress hold
      // keeps its timer; an uncommitted tap must not block the new press.
      if (existing.longPressTriggered) return;
      existing.timer?.cancel();
      _keyboardPressStates.remove(key);
    }
    final _KeyboardPressState state = _KeyboardPressState()
      ..downStamp = timeStamp;
    _keyboardPressStates[key] = state;
    state.timer = Timer(_keyboardHoldToBoostThreshold, () {
      if (!mounted || _keyboardPressStates[key] != state) return;
      state.longPressTriggered = true;
      if (key == LogicalKeyboardKey.escape) {
        final settings = Provider.of<SettingsService>(context, listen: false);
        if (settings.isFullScreen) widget.onToggleFullScreen?.call();
        return;
      }
      // Left arrow is rewind. Only space and right arrow hold-to-boost.
      if (key == LogicalKeyboardKey.arrowLeft) {
        _handleArrowTap(isLeft: true);
        return;
      }
      if (_activeSpeedBoostKey != null || !_startZoneLongPress()) return;
      _activeSpeedBoostKey = key;
      state.speedBoostStarted = true;
      setState(() => _isKeyboardLongPressing = true);
    });
  }

  void _handleLongPressKeyUp(LogicalKeyboardKey key, Duration timeStamp) {
    final _KeyboardPressState? state = _keyboardPressStates.remove(key);
    if (state == null) return;
    state.timer?.cancel();
    final bool heldLongEnough =
        timeStamp - state.downStamp >= _keyboardHoldToBoostThreshold;
    if (state.longPressTriggered && heldLongEnough) {
      if (state.speedBoostStarted && _activeSpeedBoostKey == key) {
        _activeSpeedBoostKey = null;
        _endZoneLongPress();
        if (mounted) setState(() => _isKeyboardLongPressing = false);
      }
      return;
    }
    // The timer can run first when the UI thread was busy, even though the
    // physical press was a tap. Undo that boost and still commit the tap.
    if (state.speedBoostStarted && _activeSpeedBoostKey == key) {
      _activeSpeedBoostKey = null;
      _endZoneLongPress();
      if (mounted) setState(() => _isKeyboardLongPressing = false);
    }
    if (key == LogicalKeyboardKey.space) {
      widget.onTogglePlay();
    } else if (key == LogicalKeyboardKey.escape) {
      widget.onBackPressed();
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _handleArrowTap(isLeft: false);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _handleArrowTap(isLeft: true);
    }
  }

  void _handleArrowTap({required bool isLeft}) {
    final platform = currentNativeTargetPlatform;
    if (!widget.isPreviewMode &&
        platform != null &&
        DesktopPlayerShortcuts.usesCoordinatedSeekOnPlatform(platform)) {
      final playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      final settings = Provider.of<SettingsService>(context, listen: false);
      playbackService.handleExternalDoubleTapSeek(
        isLeft: isLeft,
        doubleTapSeekSeconds: settings.doubleTapSeekSeconds,
        enableDoubleTapSubtitleSeek: settings.enableDoubleTapSubtitleSeek,
        subtitleOffset: settings.subtitleOffset,
      );
    } else {
      _seekRelative(
        isLeft ? -widget.doubleTapSeekSeconds : widget.doubleTapSeekSeconds,
      );
    }
  }

  // Helper to reuse Zone Long Press Logic
  bool _startZoneLongPress() {
    if (!widget.onLongPressStart()) return false;
    final settings = Provider.of<SettingsService>(context, listen: false);
    unawaited(AppHaptics.longPressStarted(settings));
    final renderObject = context.findRenderObject();
    final size = renderObject is RenderBox ? renderObject.size : Size.zero;
    _showLongPressFeedback(Offset(size.width * 0.75, size.height * 0.5));
    return true;
  }

  void _endZoneLongPress() {
    cancelLongPressFeedback();
    widget.onLongPressEnd();
  }

  // Accumulated Seek Logic
  Timer? _seekResetTimer;
  int _subtitleSeekAccumulator = 0;
  Duration? _initialSeekPosition;
  Timer? _seekDebounceTimer;
  final List<int> _subtitleStartMs = <int>[];

  // -- initState and dispose moved to top of file --

  bool get _shouldBlockPrimaryGestures {
    return widget.suppressPrimaryGestures;
  }

  Future<void> _initVolumeBrightness() async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        _currentBrightness = await ScreenBrightness().application;
      } else {
        _currentBrightness = 1.0;
      }
      final double initialVolume = await _resolveVolumeForAdjustment();
      if (!mounted) return;
      _currentVolume = initialVolume;
    } catch (e) {
      debugPrint("Error initializing controls: $e");
    }
  }

  bool get _usesSystemVolumeAdjustment =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Same source as the left/right vertical swipe: system volume on phones,
  /// in-player volume on desktop.
  Future<double> _resolveVolumeForAdjustment() async {
    if (_usesSystemVolumeAdjustment) {
      try {
        return await VolumeController.instance.getVolume();
      } catch (_) {
        return _currentVolume;
      }
    }
    if (!mounted) return _currentVolume;
    return Provider.of<MediaPlaybackService>(context, listen: false).volume;
  }

  void _stopKeyboardVolumeHold() {
    _volumeKeyDirection = 0;
    _volumeKeySessionSerial++;
    _volumeHoldStartTimer?.cancel();
    _volumeHoldTickTimer?.cancel();
    _volumeHoldStartTimer = null;
    _volumeHoldTickTimer = null;
  }

  Future<void> _handleVolumeKeyDown(int direction) async {
    // Extra KeyDowns for the same held key must not apply another 5% step.
    if (_volumeKeyDirection == direction) return;
    _stopKeyboardVolumeHold();
    _volumeKeyDirection = direction;
    final int session = ++_volumeKeySessionSerial;

    if (!_isAdjustingVolume) {
      if (_usesSystemVolumeAdjustment) {
        _currentVolume = await _resolveVolumeForAdjustment();
      } else if (mounted) {
        _currentVolume = Provider.of<MediaPlaybackService>(
          context,
          listen: false,
        ).volume;
      }
    }
    if (!mounted || session != _volumeKeySessionSerial) return;

    _commitVolumeAdjustment(
      PlayerVolumeKeyboard.applyShortPress(_currentVolume, direction),
    );

    _volumeHoldStartTimer = Timer(PlayerVolumeKeyboard.holdStartDelay, () {
      if (!mounted ||
          session != _volumeKeySessionSerial ||
          _volumeKeyDirection != direction) {
        return;
      }
      _volumeHoldTickTimer = Timer.periodic(
        PlayerVolumeKeyboard.holdTickInterval,
        (_) {
          if (!mounted ||
              session != _volumeKeySessionSerial ||
              _volumeKeyDirection != direction) {
            return;
          }
          _commitVolumeAdjustment(
            PlayerVolumeKeyboard.applyHoldTick(_currentVolume, direction),
          );
        },
      );
      _commitVolumeAdjustment(
        PlayerVolumeKeyboard.applyHoldTick(_currentVolume, direction),
      );
    });
  }

  void _handleVolumeKeyUp(int direction) {
    if (_volumeKeyDirection != direction) return;
    _stopKeyboardVolumeHold();
    _scheduleVolumeFeedbackHide();
  }

  void _commitVolumeAdjustment(double volume) {
    final double clamped = volume.clamp(0.0, 1.0);
    setState(() {
      _isAdjustingVolume = true;
      _currentVolume = clamped;
    });

    if (_usesSystemVolumeAdjustment) {
      VolumeController.instance.setVolume(clamped);
    } else {
      final MediaPlaybackService playbackService =
          Provider.of<MediaPlaybackService>(context, listen: false);
      unawaited(_applyPlaybackVolume(playbackService, clamped));
    }

    _startAutoHideTimer();
    _scheduleVolumeFeedbackHide();
  }

  Future<void> _applyPlaybackVolume(
    MediaPlaybackService playbackService,
    double volume,
  ) async {
    await playbackService.setVolume(volume);
    // Raising or lowering volume should make sound audible again, matching
    // YouTube / VLC arrow-key behavior while muted.
    if (playbackService.isMuted && volume > 0) {
      await playbackService.toggleMute();
    }
  }

  void _scheduleVolumeFeedbackHide([Duration? duration]) {
    _volumeFeedbackHideTimer?.cancel();
    _volumeFeedbackHideTimer = Timer(
      duration ?? PlayerVolumeKeyboard.overlayVisibleDuration,
      () {
        if (!mounted) return;
        if (_volumeKeyDirection != 0) return;
        if (_verticalAdjustmentGestureActive) return;
        setState(() {
          _isAdjustingVolume = false;
          _isAdjustingBrightness = false;
        });
      },
    );
  }

  void _invalidateVerticalAdjustmentSession() {
    _verticalAdjustmentSession++;
    _verticalAdjustmentGestureActive = false;
  }

  /// Drop the center HUD even if the swipe never got an onEnd (arena cancel,
  /// lock, long-press, or a late async volume/brightness read).
  void _hideVolumeBrightnessOverlay({bool hidePlaybackControls = false}) {
    _invalidateVerticalAdjustmentSession();
    if (!mounted) return;
    if (!_isAdjustingVolume &&
        !_isAdjustingBrightness &&
        !hidePlaybackControls) {
      return;
    }
    setState(() {
      _isAdjustingVolume = false;
      _isAdjustingBrightness = false;
      if (hidePlaybackControls) {
        _setShowControls(false);
      }
    });
    if (hidePlaybackControls) {
      _cancelAutoHideTimer();
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    if (duration.inHours > 0) {
      return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
    }
    return "$twoDigitMinutes:$twoDigitSeconds";
  }

  void _rebuildSubtitleIndex() {
    _subtitleStartMs
      ..clear()
      ..addAll(widget.subtitles.map((e) => e.startTime.inMilliseconds));
  }

  void _ensureSubtitleIndexUpToDate() {
    if (widget.subtitles.isEmpty) {
      if (_subtitleStartMs.isNotEmpty) _subtitleStartMs.clear();
      return;
    }

    final int first = widget.subtitles.first.startTime.inMilliseconds;
    final int last = widget.subtitles.last.startTime.inMilliseconds;

    if (_subtitleStartMs.length != widget.subtitles.length) {
      _rebuildSubtitleIndex();
      return;
    }

    if (_subtitleStartMs.isNotEmpty &&
        (_subtitleStartMs.first != first || _subtitleStartMs.last != last)) {
      _rebuildSubtitleIndex();
    }
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

  int _binarySearchFirstStartGT(int posMs) {
    int low = 0;
    int high = _subtitleStartMs.length - 1;
    int ans = _subtitleStartMs.length;
    while (low <= high) {
      final int mid = (low + high) >> 1;
      if (_subtitleStartMs[mid] > posMs) {
        ans = mid;
        high = mid - 1;
      } else {
        low = mid + 1;
      }
    }
    return ans;
  }

  void _cancelDoubleTapFeedbackTimers() {
    _doubleTapFeedbackHideTimer?.cancel();
    _doubleTapFeedbackDismissTimer?.cancel();
  }

  void _triggerDoubleTapFeedback(Offset localPosition) {
    _cancelDoubleTapFeedbackTimers();
    setState(() {
      _showDoubleTapFeedback = true;
      _isDoubleTapFeedbackFadingOut = false;
      _tapPosition = localPosition;
      _doubleTapFeedbackPulse++;
    });

    _doubleTapFeedbackHideTimer = Timer(_doubleTapFeedbackVisibleDuration, () {
      if (!mounted || _isGestureSeeking || _isLongPressActive) return;
      setState(() {
        _isDoubleTapFeedbackFadingOut = true;
      });
      _doubleTapFeedbackDismissTimer = Timer(
        _doubleTapFeedbackFadeOutDuration,
        () {
          if (!mounted) return;
          setState(() {
            _showDoubleTapFeedback = false;
          });
        },
      );
    });
  }

  double _relativePlayerUnit(
    double width,
    double height, {
    required double fraction,
    required double min,
    required double max,
  }) {
    final double base = math.min(width, height);
    return (base * fraction).clamp(min, max).toDouble();
  }

  int _findCurrentSubtitleIndexByPositionMs(int posMs) {
    if (widget.subtitles.isEmpty) return -1;
    _ensureSubtitleIndexUpToDate();
    final int candidate = _binarySearchLastStartLE(posMs);
    if (candidate < 0 || candidate >= widget.subtitles.length) return -1;
    final int endMs = widget.subtitles[candidate].endTime.inMilliseconds;
    if (posMs <= endMs) return candidate;
    return -1;
  }

  void _seekTo(Duration position, {bool hop = false}) {
    final handler = hop
        ? (widget.onHopSeekTo ?? widget.onSeekTo)
        : widget.onSeekTo;
    if (handler != null) {
      handler(position);
      return;
    }
    widget.controller?.seekTo(position);
  }

  // Helper for keyboard seek
  void _seekRelative(int seconds) {
    if (!_controllerValue.isInitialized) return;
    final newPos = _controllerValue.position + Duration(seconds: seconds);
    final total = _controllerValue.duration;
    final clamped = newPos < Duration.zero
        ? Duration.zero
        : (newPos > total ? total : newPos);
    _seekTo(clamped);

    // Show feedback (optional, reusing gesture UI or similar)
    // For now just seek
  }

  // Helper for determining cancel area
  bool _isInCancelArea(Offset globalPosition) {
    if (!mounted) return false;
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null) return false;
    final localOffset = box.globalToLocal(globalPosition);
    // Use absolute top area of the player (25%) for cancel zone
    return localOffset.dy < box.size.height * 0.25;
  }

  // Horizontal Drag for Seeking (Direct Slide)
  Offset? _dragStartPosition;

  void _onHorizontalDragStart(DragStartDetails details, double width) {
    if (_shouldBlockPrimaryGestures) return;
    if (!_controllerValue.isInitialized || widget.isLocked) return;
    // 互斥：如果正在长按加速（或显示双击反馈），则不响应滑动
    if (_isLongPressActive) return;
    // 恢复键盘焦点，确保手势操作后快捷键仍然可用
    _requestKeyboardFocus();

    // Ignore if starting from edges (to avoid conflict with system gestures or volume/brightness)
    // But Volume/Brightness is VerticalDrag, so they shouldn't conflict if direction is clear.
    // However, user might want volume/brightness if they start near edge.
    // VerticalDragGestureRecognizer and HorizontalDragGestureRecognizer compete.
    // We'll let the arena decide.

    // Ignore bottom area (progress bar)
    final screenHeight = MediaQuery.of(context).size.height;
    if (details.globalPosition.dy > screenHeight * 0.85) return;

    _dragStartPosition = details.globalPosition;

    setState(() {
      _showControlsBeforeGestureSeek = _showControls;
      _isGestureSeeking = true;
      _gestureTargetTime = _controllerValue.position;
      _isGestureCanceling = false;
    });

    // Keep the pre-gesture controls visibility stable during gesture seek.
    _cancelAutoHideTimer();
  }

  void _onHorizontalDragUpdate(
    DragUpdateDetails details,
    BuildContext context,
  ) {
    if (_shouldBlockPrimaryGestures) return;
    if (!_isGestureSeeking || widget.isLocked || _dragStartPosition == null) {
      return;
    }
    if (_isLongPressActive) return; // Double check

    final double offsetX = details.globalPosition.dx - _dragStartPosition!.dx;
    final int secondsToAdd = (offsetX / 10).round();

    final Duration newTime =
        _controllerValue.position + Duration(seconds: secondsToAdd);

    final RenderBox box = context.findRenderObject() as RenderBox;
    final localOffset = box.globalToLocal(details.globalPosition);
    // Use absolute top area of the player (25%) for cancel zone
    final bool isInCancelArea = localOffset.dy < box.size.height * 0.25;

    setState(() {
      final totalDuration = _controllerValue.duration;
      final clamped = newTime < Duration.zero
          ? Duration.zero
          : (newTime > totalDuration ? totalDuration : newTime);
      _gestureTargetTime = clamped;

      final diff =
          _gestureTargetTime.inSeconds - _controllerValue.position.inSeconds;
      _gestureDiffText = diff > 0 ? "+${diff}s" : "${diff}s";

      _isGestureCanceling = isInCancelArea;
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (_shouldBlockPrimaryGestures) return;
    if (!_isGestureSeeking) return;

    if (!_isGestureCanceling && !widget.isLocked) {
      _seekTo(_gestureTargetTime);
    }

    setState(() {
      _isGestureSeeking = false;
      _isGestureCanceling = false;
      _setShowControls(_showControlsBeforeGestureSeek);
      _showControlsBeforeGestureSeek = false;
      _dragStartPosition = null;
    });

    if (_showControls) {
      _startAutoHideTimer();
    } else {
      _cancelAutoHideTimer();
    }
  }

  void _handleDoubleTap(Offset localPosition, double width) {
    if (_shouldBlockPrimaryGestures) return;
    if (widget.isLocked) return;

    final dx = localPosition.dx;
    final isLeft = dx < width * 0.2; // 20%
    final isRight = dx > width * 0.8; // 20%
    final settings = Provider.of<SettingsService>(context, listen: false);
    final Duration subtitleOffset = settings.subtitleOffset;

    // Center Double Tap: Play/Pause
    if (!isLeft && !isRight) {
      _cancelDoubleTapFeedbackTimers();
      widget.onTogglePlay();
      // Hide controls immediately after double-tap play/pause
      setState(() {
        _setShowControls(false);
        _showDoubleTapFeedback = false;
        _isDoubleTapFeedbackFadingOut = false;
      });
      return;
    }

    // Side Double Tap: Seek
    final int seconds = widget.doubleTapSeekSeconds;
    final currentPos = _controllerValue.position;
    final duration = _controllerValue.duration;

    Duration target = Duration.zero;

    // Subtitle Seek Logic with Accumulation
    if (!widget.isPreviewMode &&
        widget.enableDoubleTapSubtitleSeek &&
        widget.subtitles.isNotEmpty) {
      _ensureSubtitleIndexUpToDate();
      // Reset or Init Accumulator
      if (_seekResetTimer?.isActive ?? false) {
        _seekResetTimer?.cancel();
      } else {
        // New seek sequence started
        _subtitleSeekAccumulator = 0;
        _initialSeekPosition = currentPos - subtitleOffset;
      }

      // Determine direction
      final bool isSeekLeft = localPosition.dx < width / 2;

      if (isSeekLeft) {
        _subtitleSeekAccumulator--;
      } else {
        _subtitleSeekAccumulator++;
      }

      // Calculate Target based on Initial Position + Accumulator
      // Find the starting index corresponding to _initialSeekPosition
      // Logic to resolve Accumulator to Target Index
      int targetIndex = -1;
      String feedback = "";

      // Re-evaluate base index more robustly
      // We want to find "Current/Next" boundary
      final int initialPosMs = _initialSeekPosition!.inMilliseconds;
      int nextSubIndex = _binarySearchFirstStartGT(initialPosMs);
      if (nextSubIndex < 0) nextSubIndex = 0;
      if (nextSubIndex > widget.subtitles.length) {
        nextSubIndex = widget.subtitles.length;
      }

      int currentSubIndex = _findCurrentSubtitleIndexByPositionMs(initialPosMs);

      // Determine "Pivot" index from which we add accumulator
      // Case A: Inside Subtitle X (currentSubIndex = X)
      //   Tap Left (-1):
      //      If > 500ms in: Go to Start of X.
      //      If < 500ms in: Go to Start of X-1.
      //   Tap Right (+1): Go to Start of X+1.

      // Case B: In Gap between X and X+1
      //   Tap Left (-1): Go to Start of X.
      //   Tap Right (+1): Go to Start of X+1.

      int pivotIndex;
      bool isAtStartOfSub = false;

      if (currentSubIndex != -1) {
        pivotIndex = currentSubIndex;
        if (initialPosMs <
            widget.subtitles[currentSubIndex].startTime.inMilliseconds + 500) {
          isAtStartOfSub = true;
        }
      } else {
        // Gap: prev is nextSubIndex - 1
        pivotIndex = nextSubIndex - 1; // Could be -1
      }

      // Calculate Jump
      // If _subtitleSeekAccumulator is negative (Left)
      if (_subtitleSeekAccumulator < 0) {
        // Count jumps backwards
        int jumps = _subtitleSeekAccumulator.abs();

        if (currentSubIndex != -1 && !isAtStartOfSub) {
          // First jump goes to start of current
          jumps--;
          targetIndex = currentSubIndex;
        } else {
          // First jump goes to start of pivot (which is prev sub)
          targetIndex = pivotIndex;
        }

        // Apply remaining jumps
        targetIndex -= jumps;

        feedback =
            "上一句${_subtitleSeekAccumulator < -1 ? " x${_subtitleSeekAccumulator.abs()}" : ""}";
      } else {
        // Positive (Right)
        // Pivot is usually "Current" or "Prev". Next is pivot + 1?
        // If inside X: Next is X+1.
        // If gap X...X+1: Next is X+1.

        // So if we are at pivotIndex, next start is pivotIndex + 1.
        targetIndex = pivotIndex + _subtitleSeekAccumulator;

        feedback =
            "下一句${_subtitleSeekAccumulator > 1 ? " x$_subtitleSeekAccumulator" : ""}";
      }

      // Clamping
      if (targetIndex < 0) {
        target = Duration.zero;
        feedback = "开头";
      } else if (targetIndex >= widget.subtitles.length) {
        target = duration;
        feedback = "结尾";
      } else {
        target = widget.subtitles[targetIndex].startTime + subtitleOffset;
      }

      _doubleTapFeedbackText = feedback;

      // Start Reset Timer (2 seconds to chain commands)
      _seekResetTimer = Timer(_doubleTapChainResetDuration, () {
        _subtitleSeekAccumulator = 0;
        _initialSeekPosition = null;
      });
    } else {
      // Standard Seek Logic
      if (localPosition.dx < width / 2) {
        target = currentPos - Duration(seconds: seconds);
        _doubleTapFeedbackText = "-${seconds}s";
      } else {
        target = currentPos + Duration(seconds: seconds);
        _doubleTapFeedbackText = "+${seconds}s";
      }
    }

    if (target < Duration.zero) target = Duration.zero;
    if (target > duration) target = duration;

    // Side double-taps are sentence or N-second hops, never slider scrubs.
    // Online hops get a second coalesce in MediaPlaybackService.
    _seekDebounceTimer?.cancel();
    _seekDebounceTimer = Timer(SubtitleHopSeekPolicy.overlayHopDebounce, () {
      _seekTo(target, hop: true);
    });

    unawaited(AppHaptics.doubleTapSeek(settings));
    _triggerDoubleTapFeedback(localPosition);
  }

  void _handleZoneLongPressStart(Offset localPosition, double width) {
    if (_shouldBlockPrimaryGestures) return;
    if (widget.isLocked) return;
    if (!widget.onLongPressStart()) return;
    final settings = Provider.of<SettingsService>(context, listen: false);
    unawaited(AppHaptics.longPressStarted(settings));
    // 恢复键盘焦点，确保手势操作后快捷键仍然可用
    _requestKeyboardFocus();

    // Allow long press anywhere on the screen
    // final dx = localPosition.dx;
    // final isLeft = dx < width * 0.2;
    // final isRight = dx > width * 0.8;

    // if (!isLeft && !isRight) return;

    _showLongPressFeedback(localPosition);
  }

  /// Speed-boost is a watch gesture, not chrome interaction.
  /// A held finger used to cancel auto-hide for the entire press, which left
  /// the progress bar covering the video while the user was trying to watch.
  void _dismissPlaybackControlsForWatchGesture() {
    _cancelAutoHideTimer();
    if (!_showControls) return;
    _setShowControls(false);
  }

  void _showLongPressFeedback(Offset localPosition) {
    if (!mounted) return;
    setState(() {
      _tapPosition = localPosition;
      _longPressActive = true;
      _localLongPressFeedbackText = "${widget.longPressSpeed}x";
      _showDoubleTapFeedback = false;
      _isDoubleTapFeedbackFadingOut = false;
      _cancelDoubleTapFeedbackTimers();

      // 强制结束任何可能存在的滑动状态
      if (_isGestureSeeking) {
        _isGestureSeeking = false;
        _isGestureCanceling = false;
        _showControlsBeforeGestureSeek = false;
        _dragStartPosition = null;
      }
      _isAdjustingBrightness = false;
      _isAdjustingVolume = false;
      _invalidateVerticalAdjustmentSession();
      _dismissPlaybackControlsForWatchGesture();
    });
  }

  void _handleZoneLongPressEnd(LongPressEndDetails details) {
    _endZoneLongPress();
  }

  Widget _buildLongPressFeedbackOverlay(double width, double height) {
    final bool isLeftSide = (_tapPosition?.dx ?? width) <= width / 2;
    final double textSize = _relativePlayerUnit(
      width,
      height,
      fraction: 0.035,
      min: 9,
      max: 18,
    );
    final double iconSize = textSize * 1.35;
    final double edgeInset = (width * 0.035).clamp(8.0, 40.0).toDouble();

    final feedback = _isLongPressActive
        ? Align(
            key: ValueKey(isLeftSide ? 'long-press-left' : 'long-press-right'),
            alignment: isLeftSide
                ? Alignment.centerLeft
                : Alignment.centerRight,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: edgeInset),
              child: Container(
                key: const ValueKey('long-press-speed-feedback'),
                padding: EdgeInsets.symmetric(
                  horizontal: textSize * 0.9,
                  vertical: textSize * 0.45,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.62),
                  borderRadius: BorderRadius.circular(textSize * 0.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.fast_forward,
                      color: Colors.white,
                      size: iconSize,
                    ),
                    SizedBox(width: textSize * 0.45),
                    Text(
                      _effectiveLongPressFeedbackText,
                      key: const ValueKey('long-press-speed-feedback-text'),
                      textScaler: TextScaler.noScaling,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: textSize,
                        fontWeight: FontWeight.bold,
                        height: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
        : const SizedBox.shrink(key: ValueKey('long-press-feedback-idle'));

    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          reverseDuration: const Duration(milliseconds: 110),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) {
            final scale = Tween<double>(begin: 0.94, end: 1).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            );
            return FadeTransition(
              opacity: animation,
              child: ScaleTransition(scale: scale, child: child),
            );
          },
          child: feedback,
        ),
      ),
    );
  }

  Widget _buildDoubleTapFeedbackOverlay(double width, double height) {
    final bool isLeftSide = (_tapPosition?.dx ?? 0) < width / 2;
    final double shortSide = math.min(width, height);
    final double edgeInset = (width * 0.028).clamp(8.0, 20.0).toDouble();
    final double textSize = _relativePlayerUnit(
      width,
      height,
      fraction: 0.022,
      min: 10,
      max: 14,
    );
    final double circleSize = math
        .max(shortSide * 0.18, textSize * 4.8)
        .clamp(72.0, 112.0)
        .toDouble();
    final double horizontalPadding = (circleSize * 0.18)
        .clamp(10.0, 18.0)
        .toDouble();

    return Positioned(
      top: (height - circleSize) / 2,
      left: isLeftSide ? edgeInset : null,
      right: isLeftSide ? null : edgeInset,
      child: IgnorePointer(
        child: AnimatedOpacity(
          duration: _doubleTapFeedbackFadeOutDuration,
          curve: Curves.easeOutCubic,
          opacity: _isDoubleTapFeedbackFadingOut ? 0.0 : 1.0,
          child: AnimatedScale(
            duration: _doubleTapFeedbackFadeOutDuration,
            curve: Curves.easeOutCubic,
            scale: _isDoubleTapFeedbackFadingOut ? 0.94 : 1.0,
            child: TweenAnimationBuilder<double>(
              key: ValueKey(
                '${isLeftSide ? 'left' : 'right'}-$_doubleTapFeedbackPulse',
              ),
              tween: Tween<double>(begin: 0.92, end: 1.0),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              builder: (context, progress, child) {
                final double slideDistance =
                    circleSize * 0.08 * (1.0 - progress);
                return Transform.translate(
                  offset: Offset(
                    isLeftSide ? -slideDistance : slideDistance,
                    0,
                  ),
                  child: Transform.scale(scale: progress, child: child),
                );
              },
              child: Container(
                width: circleSize,
                height: circleSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.grey.shade700.withValues(alpha: 0.9),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 16,
                      spreadRadius: 0.5,
                    ),
                  ],
                ),
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: horizontalPadding,
                    ),
                    child: Text(
                      _doubleTapFeedbackText,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: textSize,
                        fontWeight: FontWeight.w700,
                        height: 1.12,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Vertical Drag for Volume/Brightness
  void _onVerticalDragStart(DragStartDetails details, double width) async {
    if (_shouldBlockPrimaryGestures) return;
    if (widget.isLocked) return; // Prevent global drag if locked
    if (_isLongPressActive) return; // 互斥
    // 恢复键盘焦点，确保手势操作后快捷键仍然可用
    _requestKeyboardFocus();

    final dx = details.localPosition.dx;
    final bool isWindows = !kIsWeb && Platform.isWindows;
    final bool isBrightnessEdge = dx < width * 0.2;
    final bool isVolumeEdge = dx > width * 0.8;
    // Center swipes are not volume/brightness. Leave the keyboard/wheel HUD
    // timer alone or a cancelled vertical recognizer would freeze that card.
    if (!isBrightnessEdge && !isVolumeEdge) return;

    _volumeFeedbackHideTimer?.cancel();
    final int session = ++_verticalAdjustmentSession;
    _verticalAdjustmentGestureActive = true;

    double startValue;
    if (isBrightnessEdge) {
      if (Platform.isAndroid || Platform.isIOS) {
        try {
          startValue = await ScreenBrightness().application;
        } catch (_) {
          startValue = 0.5;
        }
      } else if (isWindows) {
        startValue = _currentBrightness;
      } else {
        _invalidateVerticalAdjustmentSession();
        return;
      }
    } else if (_usesSystemVolumeAdjustment) {
      try {
        startValue = await VolumeController.instance.getVolume();
      } catch (_) {
        startValue = 0.5;
      }
    } else if (isWindows) {
      startValue = _controllerValue.volume;
    } else {
      _invalidateVerticalAdjustmentSession();
      return;
    }

    if (!mounted ||
        session != _verticalAdjustmentSession ||
        !_verticalAdjustmentGestureActive) {
      return;
    }
    if (widget.isLocked || _shouldBlockPrimaryGestures || _isLongPressActive) {
      _hideVolumeBrightnessOverlay();
      return;
    }

    _startDragValue = startValue;
    setState(() {
      if (isBrightnessEdge) {
        _isAdjustingBrightness = true;
        _isAdjustingVolume = false;
        _currentBrightness = _startDragValue;
      } else {
        _isAdjustingVolume = true;
        _isAdjustingBrightness = false;
        _currentVolume = _startDragValue;
      }
    });
    _startAutoHideTimer();
  }

  void _onVerticalDragUpdate(DragUpdateDetails details, double height) {
    if (_shouldBlockPrimaryGestures) return;
    if (widget.isLocked) return;
    if (_isLongPressActive) return; // 互斥
    if (!_isAdjustingBrightness && !_isAdjustingVolume) return;

    // Delta Y is positive when dragging down, negative when dragging up.
    // We want dragging UP to increase value.
    final double delta =
        -details.primaryDelta! / height; // Sensitivity depends on height
    // Multiplier for sensitivity
    final double change = delta * 1.5;
    final bool isWindows = !kIsWeb && Platform.isWindows;

    setState(() {
      if (_isAdjustingBrightness && (Platform.isAndroid || Platform.isIOS)) {
        _currentBrightness = (_currentBrightness + change).clamp(0.0, 1.0);
        ScreenBrightness().setApplicationScreenBrightness(_currentBrightness);
      } else if (_isAdjustingBrightness && isWindows) {
        _currentBrightness = (_currentBrightness + change).clamp(0.0, 1.0);
      } else if (_isAdjustingVolume && (Platform.isAndroid || Platform.isIOS)) {
        // System Volume Control (Gesture)
        _currentVolume = (_currentVolume + change).clamp(0.0, 1.0);
        VolumeController.instance.setVolume(_currentVolume);
        // Do NOT update widget.controller.setVolume (Software Gain)
        // Do NOT update _sliderVolume
      } else if (_isAdjustingVolume && isWindows) {
        _currentVolume = (_currentVolume + change).clamp(0.0, 1.0);
        final playbackService = Provider.of<MediaPlaybackService>(
          context,
          listen: false,
        );
        unawaited(playbackService.setVolume(_currentVolume));
      }
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    // Always drop the HUD. Blocking chrome after the fact used to skip this
    // and leave the card on screen.
    _hideVolumeBrightnessOverlay(
      hidePlaybackControls: !_shouldBlockPrimaryGestures,
    );
  }

  void _onVerticalDragCancel() {
    _hideVolumeBrightnessOverlay();
  }

  // 鼠标滚轮调节音量（桌面端）
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (_shouldBlockPrimaryGestures) return;
    if (widget.isLocked) return;
    // 恢复键盘焦点，确保滚轮操作后快捷键仍然可用
    _requestKeyboardFocus();

    final double scrollDelta = event.scrollDelta.dy;
    debugPrint('[_onPointerSignal] 滚动增量: $scrollDelta');
    if (scrollDelta == 0) return;

    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    final double currentVolume = playbackService.volume;
    debugPrint('[_onPointerSignal] 当前音量: $currentVolume');

    // Wheel notches stay slightly finer than a key tap so scrolling remains
    // smooth, while the HUD is the same overlay as swipe / arrow keys.
    final double step = 0.03;
    final double delta = scrollDelta > 0 ? -step : step;
    final double newVolume = (currentVolume + delta).clamp(0.0, 1.0);
    debugPrint('[_onPointerSignal] 新音量: $newVolume');

    _commitVolumeAdjustment(newVolume);
  }

  void _handleSmartTap(double width) {
    if (_shouldBlockPrimaryGestures) return;
    final now = DateTime.now();
    bool isDoubleTap = false;

    // Re-request focus on any tap within the player area to restore keyboard shortcuts
    _requestKeyboardFocus();

    if (_lastTapTime != null &&
        now.difference(_lastTapTime!) < const Duration(milliseconds: 300)) {
      // Check distance to confirm it's a double tap and not two separate taps far apart
      if (_tapPosition != null &&
          _lastTapDownPosition != null &&
          (_tapPosition! - _lastTapDownPosition!).distance < 100.0) {
        isDoubleTap = true;
      }
    }

    if (isDoubleTap) {
      _singleTapTimer?.cancel(); // Cancel any pending single tap action
      if (_tapPosition != null) {
        _handleDoubleTap(_tapPosition!, width);
      }
      _lastTapTime = null;
      _lastTapDownPosition = null;
    } else {
      // Single Tap Candidate
      // Re-request focus on tap to ensure keyboard shortcuts work
      _requestKeyboardFocus();

      _lastTapTime = now;
      _lastTapDownPosition = _tapPosition;

      // Always delay single tap action to wait for potential double tap (Full Screen Sensitivity)
      _singleTapTimer?.cancel();
      _singleTapTimer = Timer(const Duration(milliseconds: 190), () {
        if (!mounted || _isControlDialogOpen) {
          return;
        }
        // Clear selection when tapping anywhere in the control overlay
        widget.onClearSelection?.call();

        setState(() {
          _setShowControls(!_showControls);
        });

        if (_showControls) {
          _startAutoHideTimer();
        } else {
          _cancelAutoHideTimer();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Use listen: false to avoid rebuilding the entire overlay on every
    // position update (every 300ms during playback). Only the mute icon
    // needs reactive updates, handled by Selector below.
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        final safeBottom = MediaQuery.maybeOf(context)?.padding.bottom ?? 0;
        final controlMetrics = PlayerControlMetrics.fromSize(
          Size(width, height),
          safeBottom: safeBottom,
        );
        _controlMetrics = controlMetrics;
        final isSmallScreen = controlMetrics.isCompact;

        // Scale from the player's actual shortest side and available width.
        final double iconSize = controlMetrics.iconSize;
        final double bigIconSize = controlMetrics.primaryIconSize;
        final double sideControlButtonExtent =
            controlMetrics.sideControlButtonExtent;
        final double sideControlIconSize = controlMetrics.sideControlIconSize;
        final double topActionIconSize = widget.compactTopRightButtons
            ? (20 * controlMetrics.scale).clamp(18.0, 20.0).toDouble()
            : (24 * controlMetrics.scale).clamp(21.0, 24.0).toDouble();
        final EdgeInsets topActionPadding = widget.compactTopRightButtons
            ? EdgeInsets.zero
            : EdgeInsets.all(
                (3 * controlMetrics.scale).clamp(2.0, 3.0).toDouble(),
              );
        final double topActionExtent = widget.compactTopRightButtons
            ? (32 * controlMetrics.scale).clamp(30.0, 32.0).toDouble()
            : (36 * controlMetrics.scale).clamp(32.0, 36.0).toDouble();
        final BoxConstraints topActionConstraints = BoxConstraints.tightFor(
          width: topActionExtent,
          height: topActionExtent,
        );
        final ButtonStyle topIconButtonStyle = IconButton.styleFrom(
          padding: topActionPadding,
          fixedSize: Size.square(topActionExtent),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        );
        final EdgeInsets aspectChipPadding = widget.compactTopRightButtons
            ? EdgeInsets.symmetric(
                horizontal: (7 * controlMetrics.scale)
                    .clamp(5.0, 7.0)
                    .toDouble(),
                vertical: (4 * controlMetrics.scale).clamp(3.0, 4.0).toDouble(),
              )
            : EdgeInsets.symmetric(
                horizontal: (8 * controlMetrics.scale)
                    .clamp(6.0, 8.0)
                    .toDouble(),
                vertical: (5 * controlMetrics.scale).clamp(3.0, 5.0).toDouble(),
              );
        final double aspectChipIconSize = widget.compactTopRightButtons
            ? (14 * controlMetrics.scale).clamp(12.0, 14.0).toDouble()
            : (16 * controlMetrics.scale).clamp(13.0, 16.0).toDouble();
        final double aspectChipTextSize = widget.compactTopRightButtons
            ? (11 * controlMetrics.scale).clamp(9.5, 11.0).toDouble()
            : (12 * controlMetrics.scale).clamp(10.0, 12.0).toDouble();
        final double aspectChipSpacing =
            ((widget.compactTopRightButtons ? 3 : 4) * controlMetrics.scale)
                .clamp(2.0, 4.0)
                .toDouble();
        final double aspectChipRadius =
            ((widget.compactTopRightButtons ? 16 : 20) * controlMetrics.scale)
                .clamp(13.0, 20.0)
                .toDouble();
        final double topBarPadding = (8 * controlMetrics.scale)
            .clamp(4.0, 8.0)
            .toDouble();
        final double bottomBarPadding = controlMetrics.bottomHorizontalPadding;
        final bool hasChapterButton =
            widget.chapters.isNotEmpty && widget.onOpenChapters != null;
        // Rebuild when Bilibili qualities appear so the progress area grows
        // for the right-side capsule, matching the chapter pill.
        final bool hasQualityButton = context
            .select<MediaPlaybackService, bool>(
              (service) =>
                  service.isCurrentItemBilibiliStream &&
                  service.streamQualities.isNotEmpty,
            );
        final double progressTrackInset = math.max(
          controlMetrics.overlayRadius,
          controlMetrics.thumbRadius,
        );
        final ButtonStyle bottomIconButtonStyle = IconButton.styleFrom(
          padding: EdgeInsets.zero,
          fixedSize: Size.square(controlMetrics.bottomButtonExtent),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        );
        final settings = Provider.of<SettingsService>(context);
        final bool isLeftHandedMode = settings.isLeftHandedMode;
        final EdgeInsets viewPadding =
            MediaQuery.maybeOf(context)?.viewPadding ?? EdgeInsets.zero;
        final double controlSafeLeft = math.max(
          bottomBarPadding,
          viewPadding.left,
        );
        final double controlSafeRight = math.max(
          bottomBarPadding,
          viewPadding.right,
        );
        final double sideControlHorizontalInset = math.max(
          controlMetrics.sideControlHorizontalInset,
          isLeftHandedMode ? viewPadding.right : viewPadding.left,
        );
        final Alignment timeAlignment = isLeftHandedMode
            ? Alignment.centerRight
            : Alignment.centerLeft;
        final Alignment toolsAlignment = isLeftHandedMode
            ? Alignment.centerLeft
            : Alignment.centerRight;
        final bool isWindows = !kIsWeb && Platform.isWindows;
        final bool showLockButton = !widget.isPreviewMode;
        final bool showInteractiveDanmakuControls =
            widget.showDanmakuControls && !widget.isLocked;
        final bool hasResetScreenControl =
            widget.showResetScreenButton &&
            widget.onResetScreenTransform != null;
        final bool showResetScreenControl =
            hasResetScreenControl && !widget.isLocked;
        final int visibleSideControlCount =
            (showLockButton ? 1 : 0) + (showInteractiveDanmakuControls ? 2 : 0);
        // Keep the unlocked group's footprint while locked. Centering only the
        // remaining lock button would otherwise make it jump vertically.
        final int reservedSideControlCount =
            (showLockButton ? 1 : 0) + (widget.showDanmakuControls ? 2 : 0);
        final double reservedSideControlGroupHeight =
            reservedSideControlCount == 0
            ? 0
            : sideControlButtonExtent * reservedSideControlCount +
                  controlMetrics.sideControlGap *
                      (reservedSideControlCount - 1);
        final double sideControlGroupTop = math
            .max(
              controlMetrics.sideControlHorizontalInset,
              (height - reservedSideControlGroupHeight) / 2,
            )
            .toDouble();
        // The reset action is overlaid above the original rail. It is not
        // included in either count or height, so appearing/disappearing can
        // never move the lock or danmaku controls.
        final double resetScreenControlTop = math
            .max(
              controlMetrics.sideControlHorizontalInset,
              (reservedSideControlCount > 0
                      ? sideControlGroupTop
                      : (height - sideControlButtonExtent) / 2) -
                  controlMetrics.sideControlGap -
                  sideControlButtonExtent,
            )
            .toDouble();
        final bool hideControlsForGestureSeek =
            _isGestureSeeking && !_showControlsBeforeGestureSeek;
        final double brightnessOverlayAlpha = (1.0 - _currentBrightness)
            .clamp(0.0, 1.0)
            .toDouble();
        final String mediaTitle = widget.mediaTitle.trim();
        final bool isDesktop =
            !kIsWeb &&
            (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
        final bool supportsPointerHover =
            !kIsWeb && supportsPlayerPointerHoverOn(defaultTargetPlatform);
        final List<Widget> topLeading = [
          if (isDesktop)
            IconButton(
              key: const ValueKey('video-controls-close'),
              icon: const Icon(Icons.close, color: Colors.white),
              tooltip: _tooltipWithShortcut(
                "退出播放",
                DesktopPlayerShortcutAction.back,
              ),
              onPressed: () {
                _startAutoHideTimer();
                (widget.onExitPressed ?? widget.onBackPressed)();
              },
              iconSize: iconSize,
              padding: topActionPadding,
              constraints: topActionConstraints,
            )
          else
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              tooltip: _tooltipWithShortcut(
                "返回",
                DesktopPlayerShortcutAction.back,
              ),
              onPressed: () {
                _startAutoHideTimer();
                widget.onBackPressed();
              },
              iconSize: iconSize,
              padding: topActionPadding,
              constraints: topActionConstraints,
            ),
        ];
        final List<Widget> topTrailing = [
          if (!widget.isPreviewMode) ...[
            if (widget.onOpenSettings != null)
              IconButton(
                key: const ValueKey('video-controls-top-settings'),
                icon: const Icon(Icons.settings, color: Colors.white),
                tooltip: _tooltipWithShortcut(
                  "设置",
                  DesktopPlayerShortcutAction.openSettings,
                ),
                onPressed: () {
                  _startAutoHideTimer();
                  widget.onOpenSettings!();
                },
                iconSize: topActionIconSize,
                padding: topActionPadding,
                constraints: topActionConstraints,
              ),
            if (widget.onOpenSubtitleManager != null)
              IconButton(
                key: const ValueKey('video-controls-top-subtitle-library'),
                icon: const Icon(Icons.subtitles, color: Colors.white),
                tooltip: _tooltipWithShortcut(
                  "字幕库",
                  DesktopPlayerShortcutAction.openSubtitleLibrary,
                ),
                onPressed: () {
                  _startAutoHideTimer();
                  widget.onOpenSubtitleManager!();
                },
                iconSize: topActionIconSize,
                padding: topActionPadding,
                constraints: topActionConstraints,
              ),
            if (widget.showSubtitleEditorButton &&
                widget.onOpenSubtitleEditor != null)
              IconButton(
                icon: const Icon(Icons.edit_note, color: Colors.white),
                tooltip: _tooltipWithShortcut(
                  "字幕编辑",
                  DesktopPlayerShortcutAction.openSubtitleEditor,
                ),
                onPressed: () {
                  _startAutoHideTimer();
                  widget.onOpenSubtitleEditor!();
                },
                iconSize: topActionIconSize,
                padding: topActionPadding,
                constraints: topActionConstraints,
              ),
            if (widget.onOpenVideoCompose != null)
              IconButton(
                icon: const Icon(
                  Icons.movie_creation_outlined,
                  color: Colors.white,
                ),
                tooltip: _tooltipWithShortcut(
                  "合成视频",
                  DesktopPlayerShortcutAction.openVideoCompose,
                ),
                onPressed: () {
                  _startAutoHideTimer();
                  widget.onOpenVideoCompose!();
                },
                iconSize: topActionIconSize,
                padding: topActionPadding,
                constraints: topActionConstraints,
              ),
            if (widget.onOpenOcrSubtitle != null)
              IconButton(
                icon: const Icon(
                  Icons.document_scanner_outlined,
                  color: Colors.white,
                ),
                tooltip: _tooltipWithShortcut(
                  'OCR 字幕',
                  DesktopPlayerShortcutAction.openOcrSubtitle,
                ),
                onPressed: () {
                  _startAutoHideTimer();
                  widget.onOpenOcrSubtitle!();
                },
                iconSize: topActionIconSize,
                padding: topActionPadding,
                constraints: topActionConstraints,
              ),
            if (widget.onToggleFloatingSubtitleSettings != null)
              IconButton(
                icon: const Icon(Icons.style, color: Colors.white),
                tooltip: _tooltipWithShortcut(
                  "悬浮字幕设置",
                  DesktopPlayerShortcutAction.openSubtitleStyle,
                ),
                onPressed: () {
                  _startAutoHideTimer();
                  widget.onToggleFloatingSubtitleSettings!();
                },
                iconSize: topActionIconSize,
                padding: topActionPadding,
                constraints: topActionConstraints,
              ),
            IconButton(
              icon: const Icon(Icons.open_with, color: Colors.white),
              tooltip: _tooltipWithShortcut(
                "移动字幕",
                DesktopPlayerShortcutAction.moveSubtitles,
              ),
              onPressed: () {
                _startAutoHideTimer();
                widget.onMoveSubtitles();
              },
              iconSize: topActionIconSize,
              padding: topActionPadding,
              constraints: topActionConstraints,
            ),
          ],
          if (!widget.isPreviewMode &&
              !kIsWeb &&
              (Platform.isWindows || Platform.isMacOS || Platform.isLinux))
            IconButton(
              icon: Icon(
                settings.isFullScreen
                    ? Icons.fullscreen_exit
                    : Icons.fullscreen,
                color: Colors.white,
              ),
              tooltip: _tooltipWithShortcut(
                settings.isFullScreen ? "退出全屏" : "全屏",
                DesktopPlayerShortcutAction.toggleFullScreen,
              ),
              onPressed: () {
                _startAutoHideTimer();
                widget.onToggleFullScreen!();
              },
              iconSize: topActionIconSize,
              padding: topActionPadding,
              constraints: topActionConstraints,
            ),
          if (widget.onToggleSidebar != null)
            IconButton(
              icon: Icon(
                widget.isSubtitleSidebarVisible ? Icons.menu_open : Icons.menu,
                color: Colors.white,
              ),
              tooltip: _tooltipWithShortcut(
                widget.isSubtitleSidebarVisible ? "隐藏字幕边栏" : "显示字幕边栏",
                DesktopPlayerShortcutAction.toggleSubtitleSidebar,
              ),
              onPressed: () {
                _startAutoHideTimer();
                widget.onToggleSidebar!();
              },
              iconSize: topActionIconSize,
              padding: topActionPadding,
              constraints: topActionConstraints,
            ),
          if (!widget.isPreviewMode &&
              widget.onOpenAspectRatio != null &&
              widget.aspectRatioLabel != null)
            Material(
              color: Colors.black45,
              borderRadius: BorderRadius.circular(aspectChipRadius),
              child: Tooltip(
                message: _tooltipWithShortcut(
                  "画面比例",
                  DesktopPlayerShortcutAction.openAspectRatio,
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(aspectChipRadius),
                  onTap: () {
                    _startAutoHideTimer();
                    widget.onOpenAspectRatio!();
                  },
                  child: Padding(
                    padding: aspectChipPadding,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.aspect_ratio,
                          size: aspectChipIconSize,
                          color: Colors.white,
                        ),
                        SizedBox(width: aspectChipSpacing),
                        Text(
                          widget.aspectRatioLabel!,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: aspectChipTextSize,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ];

        Widget focusChild = Focus(
          focusNode: _effectiveFocusNode,
          autofocus: true,
          descendantsAreFocusable: false, // 禁用子控件焦点，确保键盘事件由 Focus 统一处理
          onKeyEvent: handleKeyEvent,
          child: Stack(
            children: [
              // 0. Background Gesture Layer (Lowest Z-Order)
              // This layer handles Double Tap (Seek), Single Tap (Toggle Controls), Long Press (Speed), Vertical Drag (Volume/Brightness).
              // It is BEHIND the control buttons, so buttons will intercept touches first.
              Positioned.fill(
                child: RawGestureDetector(
                  gestures: <Type, GestureRecognizerFactory>{
                    TapGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          TapGestureRecognizer
                        >(() => TapGestureRecognizer(), (
                          TapGestureRecognizer instance,
                        ) {
                          instance.onTapDown = (details) {
                            final RenderBox box =
                                context.findRenderObject() as RenderBox;
                            final localOffset = box.globalToLocal(
                              details.globalPosition,
                            );
                            _tapPosition = localOffset;
                          };
                          instance.onTap = () {
                            _handleSmartTap(width);
                          };
                        }),
                    // DoubleTapGestureRecognizer removed to eliminate delay
                    LongPressGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          LongPressGestureRecognizer
                        >(
                          // Android long press standard is 500ms, user requested "slightly longer than click"
                          // 350ms feels responsive without being too quick to trigger accidentally during slow clicks
                          () => LongPressGestureRecognizer(
                            duration: const Duration(milliseconds: 350),
                          ),
                          (LongPressGestureRecognizer instance) {
                            instance.onLongPressStart = (details) {
                              final RenderBox box =
                                  context.findRenderObject() as RenderBox;
                              final localOffset = box.globalToLocal(
                                details.globalPosition,
                              );

                              // Always trigger long press speed up
                              _handleZoneLongPressStart(localOffset, width);
                            };
                            instance.onLongPressMoveUpdate = (details) {
                              if (_isLongPressActive) return;
                              // Center long press seek removed in favor of Horizontal Drag
                            };
                            instance.onLongPressEnd = (details) {
                              if (_isLongPressActive) {
                                _handleZoneLongPressEnd(details);
                              }
                            };
                            instance.onLongPressCancel = () {
                              if (_isLongPressActive) {
                                // If gesture is canceled (e.g. system interruption), we must clean up
                                // But if we use GlobalKey, we hope it persists.
                                // If it still cancels, we reset. Better safe than stuck.
                                // Note: LongPressEndDetails is required by _handleZoneLongPressEnd but it only uses it for nothing important (just triggers callback).
                                // So we can pass a dummy or change the signature.
                                _endZoneLongPress();
                              }
                            };
                          },
                        ),
                    VerticalDragGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          VerticalDragGestureRecognizer
                        >(() => VerticalDragGestureRecognizer(), (
                          VerticalDragGestureRecognizer instance,
                        ) {
                          instance.onStart = (details) =>
                              _onVerticalDragStart(details, width);
                          instance.onUpdate = (details) =>
                              _onVerticalDragUpdate(details, height);
                          instance.onEnd = (details) =>
                              _onVerticalDragEnd(details);
                          instance.onCancel = _onVerticalDragCancel;
                        }),
                    HorizontalDragGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          HorizontalDragGestureRecognizer
                        >(() => HorizontalDragGestureRecognizer(), (
                          HorizontalDragGestureRecognizer instance,
                        ) {
                          instance.onStart = (details) =>
                              _onHorizontalDragStart(details, width);
                          instance.onUpdate = (details) =>
                              _onHorizontalDragUpdate(details, context);
                          instance.onEnd = (details) =>
                              _onHorizontalDragEnd(details);
                        }),
                  },
                  behavior: HitTestBehavior.translucent,
                  child: Stack(
                    children: [
                      // Transparent container to catch hits in empty areas
                      Container(color: Colors.transparent),
                      if (isWindows)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: Container(
                              color: Colors.black.withValues(
                                alpha: brightnessOverlayAlpha,
                              ),
                            ),
                          ),
                        ),

                      // Subtitles (Gesture Layer for Long Press Drag)
                      // Kept here so it participates in the background gesture arena.
                      // Tapping subtitle -> Hits here -> Parent RawGestureDetector handles Tap -> Toggles controls.
                      // Long Press subtitle -> Child SubtitleOverlay handles Long Press -> Drag mode.
                      if (widget.showSubtitles &&
                          !widget.suppressSubtitleOverlay)
                        Positioned.fill(
                          child: SubtitleOverlayGroup(
                            entries: widget.subtitleEntries,
                            alignment: widget.subtitleAlignment,
                            style: widget.subtitleStyle,
                            onLongPress: widget.suppressPrimaryGestures
                                ? null
                                : widget.onEnterSubtitleDragMode,
                            isGestureOnly: true,
                          ),
                        ),

                      // Visual Feedback Elements (Zone, Seek, Brightness/Volume, Cancel Area)
                      // These are non-interactive visuals driven by state

                      // Zone Feedback (Long Press)
                      if (settings.showLongPressSpeedIndicator &&
                          _tapPosition != null)
                        _buildLongPressFeedbackOverlay(width, height),

                      if (_showDoubleTapFeedback && _tapPosition != null)
                        _buildDoubleTapFeedbackOverlay(width, height),

                      // Gesture Seek Feedback (Center)
                      if (_isGestureSeeking &&
                          !widget.isLocked &&
                          !_isLongPressActive)
                        Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 16,
                            ),
                            decoration: BoxDecoration(
                              color: _isGestureCanceling
                                  ? Colors.red.withValues(alpha: 0.8)
                                  : Colors.black.withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_isGestureCanceling) ...[
                                  const Icon(
                                    Icons.undo,
                                    color: Colors.white,
                                    size: 48,
                                  ),
                                  const SizedBox(height: 8),
                                  const Text(
                                    "松手取消跳转",
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ] else ...[
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _gestureDiffText.startsWith('+')
                                            ? Icons.fast_forward
                                            : Icons.fast_rewind,
                                        color: Colors.white70,
                                        size: 32,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        _gestureDiffText,
                                        style: const TextStyle(
                                          color: Colors.blueAccent,
                                          fontSize: 24,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    "${_formatDuration(_gestureTargetTime)} / ${_formatDuration(_controllerValue.duration)}",
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),

                      // Brightness/Volume Feedback (Center)
                      if ((_isAdjustingBrightness || _isAdjustingVolume) &&
                          !widget.isLocked)
                        Center(
                          child: Container(
                            width: 150,
                            padding: const EdgeInsets.symmetric(vertical: 20),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _isAdjustingBrightness
                                      ? Icons.brightness_6
                                      : Icons.volume_up,
                                  color: Colors.white,
                                  size: 48,
                                ),
                                const SizedBox(height: 12),
                                LinearProgressIndicator(
                                  value: _isAdjustingBrightness
                                      ? _currentBrightness
                                      : _currentVolume,
                                  backgroundColor: Colors.white24,
                                  valueColor:
                                      const AlwaysStoppedAnimation<Color>(
                                        Colors.blueAccent,
                                      ),
                                  minHeight: 6,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  "${((_isAdjustingBrightness ? _currentBrightness : _currentVolume) * 100).toInt()}%",
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                      // Seek Cancel Area Highlight
                      if ((_isGestureSeeking || _isDraggingProgress) &&
                          !widget.isLocked)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          height: height * 0.25,
                          child: Container(
                            color:
                                (_isGestureCanceling ||
                                    _isProgressDragCanceling)
                                ? Colors.red.withValues(alpha: 0.3)
                                : Colors.white.withValues(alpha: 0.1),
                            alignment: Alignment.center,
                            child: Text(
                              (_isGestureCanceling || _isProgressDragCanceling)
                                  ? "松手取消"
                                  : "上滑至此区域取消",
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),

              // 2. Interactive Controls Layer (Highest Z-Order)
              // These buttons are SIBLINGS to the RawGestureDetector, so they intercept touches directly.
              // They do NOT have a DoubleTapGestureRecognizer in their parent chain, so Single Taps fire immediately.

              // Volume Slider Overlay (Removed)
              // if (_showVolumeSlider && !widget.isLocked) ...
              if (showResetScreenControl &&
                  _showControls &&
                  !hideControlsForGestureSeek)
                Positioned(
                  left: isLeftHandedMode ? null : sideControlHorizontalInset,
                  right: isLeftHandedMode ? sideControlHorizontalInset : null,
                  top: resetScreenControlTop,
                  child: _PlayerSideControlButton(
                    key: const ValueKey('player-side-reset-screen'),
                    extent: sideControlButtonExtent,
                    tooltip: _tooltipWithShortcut(
                      '还原屏幕',
                      DesktopPlayerShortcutAction.resetScreen,
                    ),
                    onPressed: () {
                      widget.onResetScreenTransform?.call();
                      _startAutoHideTimer();
                    },
                    child: Icon(
                      Icons.center_focus_strong,
                      color: Colors.white70,
                      size: sideControlIconSize,
                    ),
                  ),
                ),
              if (visibleSideControlCount > 0)
                Positioned(
                  left: isLeftHandedMode ? null : sideControlHorizontalInset,
                  right: isLeftHandedMode ? sideControlHorizontalInset : null,
                  top: sideControlGroupTop,
                  child: AnimatedOpacity(
                    opacity: (widget.isLocked && _autoHideLockedControls)
                        ? (_showControls ? 1.0 : 0.0)
                        : (widget.isLocked ||
                              (_showControls && !hideControlsForGestureSeek))
                        ? 1.0
                        : 0.0,
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeInOut,
                    child: IgnorePointer(
                      ignoring: (widget.isLocked && _autoHideLockedControls)
                          ? !_showControls
                          : !(widget.isLocked ||
                                (_showControls && !hideControlsForGestureSeek)),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (showLockButton)
                            _PlayerSideControlButton(
                              key: const ValueKey('player-side-lock'),
                              extent: sideControlButtonExtent,
                              tooltip: _tooltipWithShortcut(
                                widget.isLocked ? '解锁播放器' : '锁定播放器',
                                DesktopPlayerShortcutAction.toggleLock,
                              ),
                              highlighted: widget.isLocked,
                              onPressed: () {
                                _startAutoHideTimer();
                                widget.onToggleLock();
                              },
                              child: Icon(
                                widget.isLocked
                                    ? Icons.lock_rounded
                                    : Icons.lock_open_rounded,
                                color: widget.isLocked
                                    ? _danmakuControlAccent
                                    : Colors.white70,
                                size: sideControlIconSize,
                              ),
                            ),
                          if (showLockButton && showInteractiveDanmakuControls)
                            SizedBox(height: controlMetrics.sideControlGap),
                          if (showInteractiveDanmakuControls)
                            _PlayerSideControlButton(
                              key: const ValueKey('player-side-danmaku-toggle'),
                              extent: sideControlButtonExtent,
                              tooltip: _tooltipWithShortcut(
                                widget.danmakuEnabled ? '关闭弹幕' : '打开弹幕',
                                DesktopPlayerShortcutAction.toggleDanmaku,
                              ),
                              highlighted: widget.danmakuEnabled,
                              onPressed: () {
                                _startAutoHideTimer();
                                widget.onToggleDanmaku?.call();
                              },
                              child: _DanmakuToggleGlyph(
                                enabled: widget.danmakuEnabled,
                                size: sideControlIconSize,
                              ),
                            ),
                          if (showInteractiveDanmakuControls)
                            SizedBox(height: controlMetrics.sideControlGap),
                          if (showInteractiveDanmakuControls)
                            _PlayerSideControlButton(
                              key: const ValueKey(
                                'player-side-danmaku-settings',
                              ),
                              extent: sideControlButtonExtent,
                              tooltip: _tooltipWithShortcut(
                                '弹幕设置',
                                DesktopPlayerShortcutAction.openDanmakuSettings,
                              ),
                              onPressed: () {
                                _startAutoHideTimer();
                                widget.onOpenDanmakuSettings?.call();
                              },
                              child: Icon(
                                Icons.tune_rounded,
                                color: Colors.white70,
                                size: sideControlIconSize,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),

              // 顶部及底部控制区（淡入淡出动画）
              Positioned.fill(
                child: AnimatedOpacity(
                  opacity:
                      (_showControls &&
                          !widget.isLocked &&
                          !hideControlsForGestureSeek)
                      ? 1.0
                      : 0.0,
                  duration: _controlsFadeDuration,
                  curve: Curves.easeInOut,
                  child: IgnorePointer(
                    ignoring:
                        !(_showControls &&
                            !widget.isLocked &&
                            !hideControlsForGestureSeek),
                    child: Stack(
                      children: [
                        // Top Controls
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTap: () {
                              // Reset auto-hide timer when any control is tapped
                              _startAutoHideTimer();
                            },
                            child: Container(
                              padding: EdgeInsets.fromLTRB(
                                math.max(
                                  isSmallScreen ? 8 : 16,
                                  viewPadding.left,
                                ),
                                topBarPadding,
                                math.max(
                                  isSmallScreen ? 8 : 16,
                                  viewPadding.right,
                                ),
                                topBarPadding,
                              ),
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [Colors.black54, Colors.transparent],
                                ),
                              ),
                              child: IconButtonTheme(
                                data: IconButtonThemeData(
                                  style: topIconButtonStyle,
                                ),
                                child: Row(
                                  children: [
                                    if (isLeftHandedMode)
                                      ...topTrailing
                                    else
                                      ...topLeading,
                                    if (mediaTitle.isNotEmpty) ...[
                                      SizedBox(
                                        width: controlMetrics.controlGap,
                                      ),
                                      Expanded(
                                        child: _buildTopBarTitle(
                                          mediaTitle: mediaTitle,
                                          fontSize: isSmallScreen ? 14 : 16,
                                          alignRight: isLeftHandedMode,
                                        ),
                                      ),
                                      SizedBox(
                                        width: controlMetrics.controlGap,
                                      ),
                                    ] else
                                      const Spacer(),
                                    if (isLeftHandedMode)
                                      ...topLeading
                                    else
                                      ...topTrailing,
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),

                        // Bottom Controls (Progress & Time)
                        if (widget.showBottomBar)
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            child: GestureDetector(
                              onHorizontalDragStart:
                                  (
                                    _,
                                  ) {}, // Consume horizontal drag to prevent conflict
                              onTap: () {
                                // Reset auto-hide timer when bottom controls are tapped
                                _startAutoHideTimer();
                              },
                              child: Container(
                                key: const ValueKey(
                                  'video-controls-bottom-panel',
                                ),
                                padding: EdgeInsets.fromLTRB(
                                  controlSafeLeft,
                                  0,
                                  controlSafeRight,
                                  controlMetrics.bottomPadding,
                                ),
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.bottomCenter,
                                    end: Alignment.topCenter,
                                    colors: [
                                      Colors.black87,
                                      Colors.transparent,
                                    ],
                                  ),
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    AnimatedBuilder(
                                      animation: _controllerListenable,
                                      builder: (context, child) {
                                        final position =
                                            _controllerValue.position;
                                        final duration =
                                            _controllerValue.duration;
                                        final isInitialized =
                                            _controllerValue.isInitialized &&
                                            duration.inMilliseconds > 0;

                                        final currentPosition =
                                            _isDraggingProgress
                                            ? Duration(
                                                milliseconds: _dragProgressValue
                                                    .toInt(),
                                              )
                                            : position;

                                        final sliderMax = isInitialized
                                            ? duration.inMilliseconds.toDouble()
                                            : 1.0;
                                        final sliderValue = isInitialized
                                            ? currentPosition.inMilliseconds
                                                  .toDouble()
                                                  .clamp(0.0, sliderMax)
                                            : 0.0;
                                        final bufferedValue =
                                            isInitialized &&
                                                widget.showBufferedProgress
                                            ? math.max(
                                                sliderValue,
                                                _controllerValue.buffered
                                                    .fold<double>(0, (
                                                      furthest,
                                                      range,
                                                    ) {
                                                      return math.max(
                                                        furthest,
                                                        range.end.inMilliseconds
                                                            .toDouble(),
                                                      );
                                                    })
                                                    .clamp(0.0, sliderMax),
                                              )
                                            : 0.0;

                                        return RepaintBoundary(
                                          // 进度条区域（RepaintBoundary 隔离重绘，避免每帧重绘底部控制栏）
                                          child: LayoutBuilder(
                                            builder: (context, sliderConstraints) {
                                              final progressTextDirection =
                                                  Directionality.of(context);
                                              final trackInset =
                                                  progressTrackInset;
                                              final interactionPreviewValue =
                                                  _activeSeekPreviewValue
                                                      ?.clamp(0.0, sliderMax);
                                              return Stack(
                                                clipBehavior: Clip.none,
                                                alignment: Alignment.bottomLeft,
                                                children: [
                                                  if (hasChapterButton)
                                                    Positioned(
                                                      left: trackInset,
                                                      bottom: controlMetrics
                                                          .chapterButtonBottom,
                                                      child: AnimatedBuilder(
                                                        animation:
                                                            _controllerListenable,
                                                        builder: (context, _) {
                                                          final chapter =
                                                              MediaChapter.atPosition(
                                                                widget.chapters,
                                                                currentPosition,
                                                              ) ??
                                                              widget
                                                                  .chapters
                                                                  .first;
                                                          final chapterTextStyle =
                                                              _progressPillTextStyle(
                                                                context,
                                                                controlMetrics,
                                                              );
                                                          final chapterIconSize =
                                                              controlMetrics
                                                                  .progressPillIconSize;
                                                          final chapterContentGap =
                                                              controlMetrics
                                                                  .progressPillContentGap;
                                                          final chapterHorizontalPadding =
                                                              controlMetrics
                                                                  .progressPillHorizontalPadding;
                                                          final chapterButtonMaxWidth =
                                                              (sliderConstraints
                                                                      .maxWidth -
                                                                  (trackInset *
                                                                      2)) *
                                                              controlMetrics
                                                                  .chapterButtonWidthFactor;
                                                          final chapterButtonWidth = controlMetrics.measureProgressPillWidth(
                                                            labels: [
                                                              chapter.title,
                                                            ],
                                                            textStyle:
                                                                chapterTextStyle,
                                                            textDirection:
                                                                progressTextDirection,
                                                            textScaler:
                                                                MediaQuery.textScalerOf(
                                                                  context,
                                                                ),
                                                            locale:
                                                                Localizations.maybeLocaleOf(
                                                                  context,
                                                                ),
                                                            maxWidth:
                                                                chapterButtonMaxWidth,
                                                          );
                                                          return Tooltip(
                                                            message: _tooltipWithShortcut(
                                                              chapter.title,
                                                              DesktopPlayerShortcutAction
                                                                  .openChapters,
                                                            ),
                                                            child: Material(
                                                              key: const ValueKey(
                                                                'video-controls-chapter-button',
                                                              ),
                                                              color:
                                                                  const Color(
                                                                    0xD9222222,
                                                                  ),
                                                              elevation: 2,
                                                              shadowColor: Colors
                                                                  .black
                                                                  .withValues(
                                                                    alpha: 0.5,
                                                                  ),
                                                              shape: RoundedRectangleBorder(
                                                                borderRadius:
                                                                    BorderRadius.circular(
                                                                      controlMetrics
                                                                              .chapterButtonHeight /
                                                                          2,
                                                                    ),
                                                                side: BorderSide(
                                                                  color: Colors
                                                                      .white
                                                                      .withValues(
                                                                        alpha:
                                                                            0.16,
                                                                      ),
                                                                  width: 0.75,
                                                                ),
                                                              ),
                                                              clipBehavior: Clip
                                                                  .antiAlias,
                                                              child: InkWell(
                                                                onTap: () {
                                                                  _startAutoHideTimer();
                                                                  widget
                                                                      .onOpenChapters!();
                                                                },
                                                                child: SizedBox(
                                                                  width:
                                                                      chapterButtonWidth,
                                                                  height: controlMetrics
                                                                      .chapterButtonHeight,
                                                                  child: Padding(
                                                                    padding: EdgeInsets.symmetric(
                                                                      horizontal:
                                                                          chapterHorizontalPadding,
                                                                    ),
                                                                    child: Row(
                                                                      mainAxisSize:
                                                                          MainAxisSize
                                                                              .min,
                                                                      children: [
                                                                        Expanded(
                                                                          child: AnimatedSwitcher(
                                                                            key: const ValueKey(
                                                                              'video-controls-chapter-title',
                                                                            ),
                                                                            duration: const Duration(
                                                                              milliseconds: 140,
                                                                            ),
                                                                            switchInCurve:
                                                                                Curves.easeOutCubic,
                                                                            switchOutCurve:
                                                                                Curves.easeInCubic,
                                                                            layoutBuilder:
                                                                                (
                                                                                  currentChild,
                                                                                  previousChildren,
                                                                                ) => Stack(
                                                                                  alignment: AlignmentDirectional.centerStart,
                                                                                  children: [
                                                                                    ...previousChildren,
                                                                                    ?currentChild,
                                                                                  ],
                                                                                ),
                                                                            transitionBuilder:
                                                                                (
                                                                                  child,
                                                                                  animation,
                                                                                ) => FadeTransition(
                                                                                  opacity: animation,
                                                                                  child: SlideTransition(
                                                                                    position:
                                                                                        Tween<
                                                                                              Offset
                                                                                            >(
                                                                                              begin: const Offset(
                                                                                                0.035,
                                                                                                0,
                                                                                              ),
                                                                                              end: Offset.zero,
                                                                                            )
                                                                                            .animate(
                                                                                              animation,
                                                                                            ),
                                                                                    child: child,
                                                                                  ),
                                                                                ),
                                                                            child: Text(
                                                                              chapter.title,
                                                                              key:
                                                                                  ValueKey<
                                                                                    int
                                                                                  >(
                                                                                    chapter.startMs,
                                                                                  ),
                                                                              maxLines: 1,
                                                                              overflow: TextOverflow.ellipsis,
                                                                              textAlign: TextAlign.start,
                                                                              style: chapterTextStyle,
                                                                            ),
                                                                          ),
                                                                        ),
                                                                        SizedBox(
                                                                          width:
                                                                              chapterContentGap,
                                                                        ),
                                                                        Icon(
                                                                          widget.isChapterSidebarVisible
                                                                              ? Icons.keyboard_arrow_down
                                                                              : Icons.chevron_right,
                                                                          color:
                                                                              Colors.white,
                                                                          size:
                                                                              chapterIconSize,
                                                                        ),
                                                                      ],
                                                                    ),
                                                                  ),
                                                                ),
                                                              ),
                                                            ),
                                                          );
                                                        },
                                                      ),
                                                    ),

                                                  if (hasQualityButton)
                                                    Positioned(
                                                      right: trackInset,
                                                      bottom: controlMetrics
                                                          .chapterButtonBottom,
                                                      child: _buildStreamQualityProgressPill(
                                                        controlMetrics:
                                                            controlMetrics,
                                                        maxWidth:
                                                            (sliderConstraints
                                                                    .maxWidth -
                                                                (trackInset *
                                                                    2)) *
                                                            controlMetrics
                                                                .chapterButtonWidthFactor,
                                                        textDirection:
                                                            progressTextDirection,
                                                        playbackService:
                                                            playbackService,
                                                      ),
                                                    ),

                                                  if (interactionPreviewValue !=
                                                      null)
                                                    _buildSeekPreviewOverlay(
                                                      progressWidth:
                                                          sliderConstraints
                                                              .maxWidth,
                                                      sliderMax: sliderMax,
                                                      previewValue:
                                                          interactionPreviewValue,
                                                      trackInset: trackInset,
                                                      textDirection:
                                                          progressTextDirection,
                                                      bottom:
                                                          (hasQualityButton
                                                              ? controlMetrics
                                                                    .progressHitHeight
                                                              : controlMetrics.progressAreaHeight(
                                                                  hasChapterButton:
                                                                      hasChapterButton,
                                                                )) +
                                                          6,
                                                      showThumbnail:
                                                          widget
                                                              .enableSeekThumbnailPreview &&
                                                          settings
                                                              .enableSeekPreview,
                                                    ),

                                                  Listener(
                                                    key: const ValueKey(
                                                      'video-controls-progress-interaction',
                                                    ),
                                                    behavior: HitTestBehavior
                                                        .deferToChild,
                                                    onPointerDown:
                                                        supportsPointerHover &&
                                                            isInitialized
                                                        ? (event) {
                                                            final progressAreaHeight =
                                                                controlMetrics.progressAreaHeight(
                                                                  hasChapterButton:
                                                                      hasChapterButton,
                                                                  hasQualityButton:
                                                                      hasQualityButton,
                                                                );
                                                            final progressBandTop =
                                                                progressAreaHeight -
                                                                controlMetrics
                                                                    .progressHitHeight;
                                                            final isPrimaryMouse =
                                                                event.kind ==
                                                                    PointerDeviceKind
                                                                        .mouse &&
                                                                (event.buttons &
                                                                        kPrimaryMouseButton) !=
                                                                    0;
                                                            if (!isPrimaryMouse ||
                                                                event
                                                                        .localPosition
                                                                        .dy <
                                                                    progressBandTop) {
                                                              return;
                                                            }
                                                            _desktopProgressPointer =
                                                                event.pointer;
                                                            _beginProgressDrag(
                                                              progressValueFromLocalDx(
                                                                localDx: event
                                                                    .localPosition
                                                                    .dx,
                                                                width:
                                                                    sliderConstraints
                                                                        .maxWidth,
                                                                maxValue:
                                                                    sliderMax,
                                                                trackInset:
                                                                    trackInset,
                                                                textDirection:
                                                                    progressTextDirection,
                                                              ),
                                                            );
                                                          }
                                                        : null,
                                                    onPointerMove: (event) {
                                                      if (_desktopProgressPointer ==
                                                          event.pointer) {
                                                        _updateProgressDrag(
                                                          progressValueFromLocalDx(
                                                            localDx: event
                                                                .localPosition
                                                                .dx,
                                                            width:
                                                                sliderConstraints
                                                                    .maxWidth,
                                                            maxValue: sliderMax,
                                                            trackInset:
                                                                trackInset,
                                                            textDirection:
                                                                progressTextDirection,
                                                          ),
                                                        );
                                                      }
                                                      if (!_isDraggingProgress ||
                                                          widget.isLocked) {
                                                        return;
                                                      }
                                                      final isInCancelArea =
                                                          _isInCancelArea(
                                                            event.position,
                                                          );
                                                      if (isInCancelArea !=
                                                          _isProgressDragCanceling) {
                                                        setState(() {
                                                          _isProgressDragCanceling =
                                                              isInCancelArea;
                                                        });
                                                      }
                                                    },
                                                    onPointerUp: (event) {
                                                      if (_desktopProgressPointer !=
                                                          event.pointer) {
                                                        return;
                                                      }
                                                      final value =
                                                          progressValueFromLocalDx(
                                                            localDx: event
                                                                .localPosition
                                                                .dx,
                                                            width:
                                                                sliderConstraints
                                                                    .maxWidth,
                                                            maxValue: sliderMax,
                                                            trackInset:
                                                                trackInset,
                                                            textDirection:
                                                                progressTextDirection,
                                                          );
                                                      _updateProgressDrag(
                                                        value,
                                                      );
                                                      _finishProgressDrag(
                                                        value,
                                                      );
                                                      final pointer =
                                                          event.pointer;
                                                      scheduleMicrotask(() {
                                                        if (_desktopProgressPointer ==
                                                            pointer) {
                                                          _desktopProgressPointer =
                                                              null;
                                                        }
                                                      });
                                                    },
                                                    onPointerCancel: (event) {
                                                      if (_desktopProgressPointer !=
                                                              null &&
                                                          _desktopProgressPointer !=
                                                              event.pointer) {
                                                        return;
                                                      }
                                                      _cancelProgressDrag();
                                                      final pointer =
                                                          event.pointer;
                                                      scheduleMicrotask(() {
                                                        if (_desktopProgressPointer ==
                                                            pointer) {
                                                          _desktopProgressPointer =
                                                              null;
                                                        }
                                                      });
                                                    },
                                                    child: SizedBox(
                                                      key: const ValueKey(
                                                        'video-controls-progress-area',
                                                      ),
                                                      height: controlMetrics
                                                          .progressAreaHeight(
                                                            hasChapterButton:
                                                                hasChapterButton,
                                                            hasQualityButton:
                                                                hasQualityButton,
                                                          ),
                                                      child: Align(
                                                        alignment: Alignment
                                                            .bottomCenter,
                                                        child: SizedBox(
                                                          height: controlMetrics
                                                              .progressHitHeight,
                                                          child: MouseRegion(
                                                            key: const ValueKey(
                                                              'video-controls-progress-hover-region',
                                                            ),
                                                            cursor:
                                                                isInitialized
                                                                ? SystemMouseCursors
                                                                      .precise
                                                                : MouseCursor
                                                                      .defer,
                                                            onEnter:
                                                                supportsPointerHover &&
                                                                    isInitialized
                                                                ? (
                                                                    event,
                                                                  ) => _updateProgressHover(
                                                                    localDx: event
                                                                        .localPosition
                                                                        .dx,
                                                                    globalPosition:
                                                                        event
                                                                            .position,
                                                                    width: sliderConstraints
                                                                        .maxWidth,
                                                                    sliderMax:
                                                                        sliderMax,
                                                                    trackInset:
                                                                        trackInset,
                                                                    textDirection:
                                                                        progressTextDirection,
                                                                  )
                                                                : null,
                                                            onHover:
                                                                supportsPointerHover &&
                                                                    isInitialized
                                                                ? (
                                                                    event,
                                                                  ) => _updateProgressHover(
                                                                    localDx: event
                                                                        .localPosition
                                                                        .dx,
                                                                    globalPosition:
                                                                        event
                                                                            .position,
                                                                    width: sliderConstraints
                                                                        .maxWidth,
                                                                    sliderMax:
                                                                        sliderMax,
                                                                    trackInset:
                                                                        trackInset,
                                                                    textDirection:
                                                                        progressTextDirection,
                                                                  )
                                                                : null,
                                                            onExit:
                                                                supportsPointerHover
                                                                ? (_) =>
                                                                      _endProgressHover()
                                                                : null,
                                                            child: TweenAnimationBuilder<double>(
                                                              tween: Tween<double>(
                                                                end:
                                                                    _isDraggingProgress
                                                                    ? 1
                                                                    : (_isProgressHovered
                                                                          ? 0.62
                                                                          : 0),
                                                              ),
                                                              duration:
                                                                  const Duration(
                                                                    milliseconds:
                                                                        135,
                                                                  ),
                                                              curve: Curves
                                                                  .easeOutCubic,
                                                              builder:
                                                                  (
                                                                    context,
                                                                    interaction,
                                                                    child,
                                                                  ) => SliderTheme(
                                                                    data: SliderTheme.of(context).copyWith(
                                                                      activeTrackColor:
                                                                          _isProgressDragCanceling
                                                                          ? Colors.grey
                                                                          : Color.lerp(
                                                                              const Color(
                                                                                0xFF0D47A1,
                                                                              ),
                                                                              const Color(
                                                                                0xFF2196F3,
                                                                              ),
                                                                              interaction,
                                                                            ),
                                                                      inactiveTrackColor: Colors.white.withValues(
                                                                        alpha:
                                                                            0.24 +
                                                                            (interaction *
                                                                                0.12),
                                                                      ),
                                                                      secondaryActiveTrackColor: Colors.white.withValues(
                                                                        alpha:
                                                                            0.48 +
                                                                            (interaction *
                                                                                0.12),
                                                                      ),
                                                                      thumbColor:
                                                                          isInitialized
                                                                          ? (_isProgressDragCanceling
                                                                                ? Colors.grey
                                                                                : Color.lerp(
                                                                                    const Color(
                                                                                      0xFF1565C0,
                                                                                    ),
                                                                                    const Color(
                                                                                      0xFF42A5F5,
                                                                                    ),
                                                                                    interaction,
                                                                                  ))
                                                                          : Colors.grey,
                                                                      overlayColor:
                                                                          const Color(
                                                                            0xFF2196F3,
                                                                          ).withValues(
                                                                            alpha:
                                                                                0.10 +
                                                                                (interaction *
                                                                                    0.08),
                                                                          ),
                                                                      thumbShape: RoundSliderThumbShape(
                                                                        enabledThumbRadius:
                                                                            controlMetrics.thumbRadius *
                                                                            (1 +
                                                                                (interaction *
                                                                                    0.38)),
                                                                      ),
                                                                      trackHeight:
                                                                          controlMetrics
                                                                              .trackHeight *
                                                                          (1 +
                                                                              (interaction *
                                                                                  0.65)),
                                                                      trackShape:
                                                                          widget.chapters.length >
                                                                              1
                                                                          ? ChapterSliderTrackShape(
                                                                              chapters: widget.chapters,
                                                                              durationMs: duration.inMilliseconds,
                                                                            )
                                                                          : const RoundedRectSliderTrackShape(),
                                                                      overlayShape: RoundSliderOverlayShape(
                                                                        overlayRadius:
                                                                            controlMetrics.overlayRadius *
                                                                            (1 +
                                                                                (interaction *
                                                                                    0.18)),
                                                                      ),
                                                                    ),
                                                                    child:
                                                                        child!,
                                                                  ),
                                                              child: Slider(
                                                                min: 0.0,
                                                                max: sliderMax,
                                                                value:
                                                                    sliderValue,
                                                                secondaryTrackValue:
                                                                    bufferedValue,
                                                                onChangeStart:
                                                                    isInitialized
                                                                    ? (value) {
                                                                        if (_desktopProgressPointer !=
                                                                            null) {
                                                                          return;
                                                                        }
                                                                        _beginProgressDrag(
                                                                          value,
                                                                        );
                                                                      }
                                                                    : null,
                                                                onChanged:
                                                                    isInitialized
                                                                    ? (value) {
                                                                        if (_desktopProgressPointer !=
                                                                            null) {
                                                                          return;
                                                                        }
                                                                        _updateProgressDrag(
                                                                          value,
                                                                        );
                                                                      }
                                                                    : null,
                                                                onChangeEnd: (value) {
                                                                  if (_desktopProgressPointer !=
                                                                      null) {
                                                                    return;
                                                                  }
                                                                  _finishProgressDrag(
                                                                    value,
                                                                  );
                                                                },
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                  if (!_isDraggingProgress &&
                                                      interactionPreviewValue !=
                                                          null)
                                                    Positioned(
                                                      left:
                                                          progressLocalDxFromValue(
                                                            value:
                                                                interactionPreviewValue,
                                                            width:
                                                                sliderConstraints
                                                                    .maxWidth,
                                                            maxValue: sliderMax,
                                                            trackInset:
                                                                trackInset,
                                                            textDirection:
                                                                progressTextDirection,
                                                          ) -
                                                          ((controlMetrics
                                                                      .thumbRadius *
                                                                  1.45) /
                                                              2),
                                                      bottom:
                                                          (controlMetrics
                                                                  .progressHitHeight -
                                                              (controlMetrics
                                                                      .thumbRadius *
                                                                  1.45)) /
                                                          2,
                                                      child: IgnorePointer(
                                                        child: TweenAnimationBuilder<double>(
                                                          tween: Tween<double>(
                                                            begin: 0,
                                                            end: 1,
                                                          ),
                                                          duration:
                                                              const Duration(
                                                                milliseconds:
                                                                    110,
                                                              ),
                                                          curve: Curves
                                                              .easeOutBack,
                                                          builder:
                                                              (
                                                                context,
                                                                animation,
                                                                child,
                                                              ) => Transform.scale(
                                                                scale:
                                                                    animation,
                                                                child: child,
                                                              ),
                                                          child: DecoratedBox(
                                                            key: const ValueKey(
                                                              'video-controls-progress-hover-marker',
                                                            ),
                                                            decoration: const BoxDecoration(
                                                              color: Color(
                                                                0xFF42A5F5,
                                                              ),
                                                              shape: BoxShape
                                                                  .circle,
                                                              boxShadow: <BoxShadow>[
                                                                BoxShadow(
                                                                  color: Colors
                                                                      .black45,
                                                                  blurRadius: 3,
                                                                ),
                                                              ],
                                                            ),
                                                            child: SizedBox.square(
                                                              dimension:
                                                                  controlMetrics
                                                                      .thumbRadius *
                                                                  1.45,
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                ],
                                              );
                                            },
                                          ),
                                        ); // 进度条 RepaintBoundary 结束
                                      },
                                    ), // AnimatedBuilder 结束 — 仅包裹进度条，避免每帧重建按钮区域
                                    // 底部控制栏（移出 AnimatedBuilder，仅在控制层显示/隐藏时重建）
                                    RepaintBoundary(
                                      child: SizedBox(
                                        key: const ValueKey(
                                          'video-controls-bottom-row',
                                        ),
                                        height: controlMetrics.bottomRowHeight,
                                        child: Stack(
                                          children: [
                                            // Left: Time and Episode Picker
                                            Align(
                                              alignment: timeAlignment,
                                              child: Padding(
                                                padding: EdgeInsets.only(
                                                  left: isLeftHandedMode
                                                      ? 0
                                                      : progressTrackInset,
                                                  right: isLeftHandedMode
                                                      ? progressTrackInset
                                                      : 0,
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    // 时间文本 — 小范围 AnimatedBuilder，仅重建 Text
                                                    AnimatedBuilder(
                                                      animation:
                                                          _controllerListenable,
                                                      builder: (context, _) {
                                                        final pos =
                                                            _isDraggingProgress
                                                            ? Duration(
                                                                milliseconds:
                                                                    _dragProgressValue
                                                                        .toInt(),
                                                              )
                                                            : _controllerValue
                                                                  .position;
                                                        final dur =
                                                            _controllerValue
                                                                .duration;
                                                        return Text(
                                                          key: const ValueKey(
                                                            'video-controls-time-display',
                                                          ),
                                                          "${_formatDuration(pos)} / ${_formatDuration(dur)}",
                                                          style: TextStyle(
                                                            color: Colors.white,
                                                            fontSize:
                                                                controlMetrics
                                                                    .timeFontSize,
                                                          ),
                                                        );
                                                      },
                                                    ),
                                                    if (widget
                                                            .onToggleEpisodePicker !=
                                                        null) ...[
                                                      SizedBox(
                                                        width: controlMetrics
                                                            .controlGap,
                                                      ),
                                                      Tooltip(
                                                        message: _tooltipWithShortcut(
                                                          "选集",
                                                          DesktopPlayerShortcutAction
                                                              .toggleEpisodePicker,
                                                        ),
                                                        child: TextButton.icon(
                                                          onPressed: () {
                                                            _startAutoHideTimer();
                                                            widget
                                                                .onToggleEpisodePicker
                                                                ?.call();
                                                          },
                                                          style: TextButton.styleFrom(
                                                            foregroundColor:
                                                                Colors.white,
                                                            padding: EdgeInsets.symmetric(
                                                              horizontal:
                                                                  controlMetrics
                                                                      .controlGap,
                                                            ),
                                                            minimumSize: Size(
                                                              0,
                                                              controlMetrics
                                                                  .episodeButtonHeight,
                                                            ),
                                                            tapTargetSize:
                                                                MaterialTapTargetSize
                                                                    .shrinkWrap,
                                                          ),
                                                          icon: Icon(
                                                            Icons.playlist_play,
                                                            size: controlMetrics
                                                                .episodeIconSize,
                                                          ),
                                                          label: Text(
                                                            "选集",
                                                            style: TextStyle(
                                                              fontWeight:
                                                                  FontWeight
                                                                      .bold,
                                                              fontSize:
                                                                  controlMetrics
                                                                      .toolFontSize,
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              ),
                                            ),

                                            // Center: Play Controls (Play/Pause, Seek)
                                            if (widget.showPlayControls)
                                              Align(
                                                alignment: Alignment.center,
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    // Previous Episode
                                                    if (widget.onPlayPrevious !=
                                                        null) ...[
                                                      IconButton(
                                                        iconSize: bigIconSize,
                                                        style:
                                                            bottomIconButtonStyle,
                                                        icon: Icon(
                                                          Icons.skip_previous,
                                                          color:
                                                              widget.hasPrevious
                                                              ? Colors.white
                                                              : Colors.white38,
                                                        ),
                                                        onPressed:
                                                            widget.hasPrevious
                                                            ? () {
                                                                _startAutoHideTimer();
                                                                widget
                                                                    .onPlayPrevious!();
                                                              }
                                                            : null,
                                                        tooltip: _tooltipWithShortcut(
                                                          "上一集",
                                                          DesktopPlayerShortcutAction
                                                              .previousEpisode,
                                                        ),
                                                      ),
                                                      SizedBox(
                                                        width: controlMetrics
                                                            .controlGap,
                                                      ),
                                                    ],

                                                    // Seek Backward Button with Dynamic Number
                                                    Tooltip(
                                                      message: _tooltipWithShortcut(
                                                        "快退 ${widget.doubleTapSeekSeconds} 秒",
                                                        DesktopPlayerShortcutAction
                                                            .seekBackward,
                                                      ),
                                                      child: InkWell(
                                                        onTap: () {
                                                          if (!_controllerValue
                                                              .isInitialized) {
                                                            return;
                                                          }
                                                          _startAutoHideTimer();
                                                          final newPos =
                                                              _controllerValue
                                                                  .position -
                                                              Duration(
                                                                seconds: widget
                                                                    .doubleTapSeekSeconds,
                                                              );
                                                          _seekTo(
                                                            newPos <
                                                                    Duration
                                                                        .zero
                                                                ? Duration.zero
                                                                : newPos,
                                                          );
                                                        },
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              20,
                                                            ),
                                                        child: SizedBox(
                                                          width: controlMetrics
                                                              .bottomButtonExtent,
                                                          height: controlMetrics
                                                              .bottomButtonExtent,
                                                          child: Stack(
                                                            alignment: Alignment
                                                                .center,
                                                            children: [
                                                              Icon(
                                                                Icons.replay,
                                                                color:
                                                                    _controllerValue
                                                                        .isInitialized
                                                                    ? Colors
                                                                          .white
                                                                    : Colors
                                                                          .white38,
                                                                size:
                                                                    bigIconSize *
                                                                    0.75,
                                                              ),
                                                              Text(
                                                                "${widget.doubleTapSeekSeconds}",
                                                                style: TextStyle(
                                                                  color:
                                                                      _controllerValue
                                                                          .isInitialized
                                                                      ? Colors
                                                                            .white
                                                                      : Colors
                                                                            .white38,
                                                                  fontSize:
                                                                      (8 *
                                                                              controlMetrics.scale)
                                                                          .clamp(
                                                                            7.0,
                                                                            8.0,
                                                                          ),
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .bold,
                                                                ),
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                    SizedBox(
                                                      width: controlMetrics
                                                          .controlGap,
                                                    ),
                                                    // 播放/暂停按钮 — 跟播放意图走，不等原生 isPlaying 回执
                                                    AnimatedBuilder(
                                                      animation:
                                                          _ownedTransportPlaying,
                                                      builder: (context, _) {
                                                        return AnimatedBuilder(
                                                          animation:
                                                              _controllerListenable,
                                                          builder: (context, _) {
                                                            final isPlaying =
                                                                _ownedTransportPlaying
                                                                    .value ??
                                                                _controllerValue
                                                                    .isPlaying;
                                                        final isInitialized =
                                                            _controllerValue
                                                                .isInitialized;
                                                        final canTogglePlay =
                                                            isInitialized ||
                                                            widget
                                                                .allowPlayWhenUninitialized;
                                                        return IconButton(
                                                          key: const ValueKey(
                                                            'video-controls-play-pause',
                                                          ),
                                                          iconSize: bigIconSize,
                                                          style:
                                                              bottomIconButtonStyle,
                                                          icon: Icon(
                                                            isPlaying
                                                                ? Icons
                                                                      .pause_circle_filled
                                                                : Icons
                                                                      .play_circle_fill,
                                                            color: canTogglePlay
                                                                ? Colors.white
                                                                : Colors
                                                                      .white38,
                                                          ),
                                                          onPressed:
                                                              canTogglePlay
                                                              ? () {
                                                                  _startAutoHideTimer();
                                                                  widget
                                                                      .onTogglePlay();
                                                                }
                                                              : null,
                                                          tooltip:
                                                              _tooltipWithShortcut(
                                                                isPlaying
                                                                    ? "暂停"
                                                                    : "播放",
                                                                DesktopPlayerShortcutAction
                                                                    .playPause,
                                                              ),
                                                        );
                                                          },
                                                        );
                                                      },
                                                    ),
                                                    SizedBox(
                                                      width: controlMetrics
                                                          .controlGap,
                                                    ),
                                                    // Seek Forward Button with Dynamic Number
                                                    Tooltip(
                                                      message: _tooltipWithShortcut(
                                                        "快进 ${widget.doubleTapSeekSeconds} 秒",
                                                        DesktopPlayerShortcutAction
                                                            .seekForward,
                                                      ),
                                                      child: InkWell(
                                                        onTap: () {
                                                          if (!_controllerValue
                                                              .isInitialized) {
                                                            return;
                                                          }
                                                          _startAutoHideTimer();
                                                          final newPos =
                                                              _controllerValue
                                                                  .position +
                                                              Duration(
                                                                seconds: widget
                                                                    .doubleTapSeekSeconds,
                                                              );
                                                          final duration =
                                                              _controllerValue
                                                                  .duration;
                                                          _seekTo(
                                                            newPos > duration
                                                                ? duration
                                                                : newPos,
                                                          );
                                                        },
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              20,
                                                            ),
                                                        child: SizedBox(
                                                          width: controlMetrics
                                                              .bottomButtonExtent,
                                                          height: controlMetrics
                                                              .bottomButtonExtent,
                                                          child: Stack(
                                                            alignment: Alignment
                                                                .center,
                                                            children: [
                                                              // Transform to flip the replay icon horizontally to make it look like forward
                                                              Transform(
                                                                alignment:
                                                                    Alignment
                                                                        .center,
                                                                transform:
                                                                    Matrix4.rotationY(
                                                                      3.14159,
                                                                    ),
                                                                child: Icon(
                                                                  Icons.replay,
                                                                  color:
                                                                      _controllerValue
                                                                          .isInitialized
                                                                      ? Colors
                                                                            .white
                                                                      : Colors
                                                                            .white38,
                                                                  size:
                                                                      bigIconSize *
                                                                      .75,
                                                                ),
                                                              ),
                                                              Text(
                                                                "${widget.doubleTapSeekSeconds}",
                                                                style: TextStyle(
                                                                  color:
                                                                      _controllerValue
                                                                          .isInitialized
                                                                      ? Colors
                                                                            .white
                                                                      : Colors
                                                                            .white38,
                                                                  fontSize:
                                                                      (8 *
                                                                              controlMetrics.scale)
                                                                          .clamp(
                                                                            7.0,
                                                                            8.0,
                                                                          ),
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .bold,
                                                                ),
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                      ),
                                                    ),

                                                    // Next Episode
                                                    if (widget.onPlayNext !=
                                                        null) ...[
                                                      SizedBox(
                                                        width: controlMetrics
                                                            .controlGap,
                                                      ),
                                                      IconButton(
                                                        iconSize: bigIconSize,
                                                        style:
                                                            bottomIconButtonStyle,
                                                        icon: Icon(
                                                          Icons.skip_next,
                                                          color: widget.hasNext
                                                              ? Colors.white
                                                              : Colors.white38,
                                                        ),
                                                        onPressed:
                                                            widget.hasNext
                                                            ? () {
                                                                _startAutoHideTimer();
                                                                widget
                                                                    .onPlayNext!();
                                                              }
                                                            : null,
                                                        tooltip:
                                                            _tooltipWithShortcut(
                                                              "下一集",
                                                              DesktopPlayerShortcutAction
                                                                  .nextEpisode,
                                                            ),
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              ),

                                            // Right: Tools (Speed, Subtitles, Volume)
                                            Align(
                                              alignment: toolsAlignment,
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  if (!widget
                                                      .isPreviewMode) ...[
                                                    SubtitleDebugSpeedGateway(
                                                      builder:
                                                          (
                                                            speedButtonContext,
                                                            handleSpeedTap,
                                                          ) => Tooltip(
                                                            message:
                                                                _showsPointerShortcutHints
                                                                ? '倍速 (${DesktopPlayerShortcuts.shortcutLabel(DesktopPlayerShortcutAction.speedSlower)} / ${DesktopPlayerShortcuts.shortcutLabel(DesktopPlayerShortcutAction.speedFaster)})'
                                                                : '倍速',
                                                            child: Material(
                                                              color: Colors
                                                                  .transparent,
                                                              child: InkWell(
                                                                borderRadius:
                                                                    BorderRadius.circular(
                                                                      8,
                                                                    ),
                                                                onTap:
                                                                    _controllerValue
                                                                        .isInitialized
                                                                    ? () => handleSpeedTap(
                                                                        () => unawaited(
                                                                          _showPlaybackSpeedPicker(
                                                                            settings,
                                                                            speedButtonContext,
                                                                          ),
                                                                        ),
                                                                      )
                                                                    : null,
                                                                child: AnimatedBuilder(
                                                                  animation:
                                                                      _controllerListenable,
                                                                  builder: (context, _) {
                                                                    final speed =
                                                                        _controllerValue
                                                                            .playbackSpeed;
                                                                    return SizedBox(
                                                                      height: controlMetrics
                                                                          .bottomButtonExtent,
                                                                      child: Padding(
                                                                        padding: EdgeInsets.symmetric(
                                                                          horizontal:
                                                                              controlMetrics.controlGap,
                                                                        ),
                                                                        child: Row(
                                                                          mainAxisSize:
                                                                              MainAxisSize.min,
                                                                          children: [
                                                                            ConstrainedBox(
                                                                              constraints: const BoxConstraints(
                                                                                maxWidth: 52,
                                                                              ),
                                                                              child: FittedBox(
                                                                                fit: BoxFit.scaleDown,
                                                                                child: PlaybackSpeedText(
                                                                                  speed: speed,
                                                                                  style: TextStyle(
                                                                                    color: Colors.white,
                                                                                    fontWeight: FontWeight.bold,
                                                                                    fontSize: controlMetrics.toolFontSize,
                                                                                  ),
                                                                                ),
                                                                              ),
                                                                            ),
                                                                          ],
                                                                        ),
                                                                      ),
                                                                    );
                                                                  },
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                    ),

                                                    if (widget
                                                            .onOpenSleepTimer !=
                                                        null)
                                                      AnimatedBuilder(
                                                        animation:
                                                            playbackService
                                                                .sleepTimer,
                                                        builder: (context, _) {
                                                          final timer =
                                                              playbackService
                                                                  .sleepTimer;
                                                          return IconButton(
                                                            iconSize: iconSize,
                                                            style:
                                                                bottomIconButtonStyle,
                                                            icon: Icon(
                                                              timer.isActive
                                                                  ? Icons
                                                                        .alarm_on_rounded
                                                                  : Icons
                                                                        .schedule_rounded,
                                                              color:
                                                                  timer.isActive
                                                                  ? Colors
                                                                        .blueAccent
                                                                  : Colors
                                                                        .white70,
                                                            ),
                                                            onPressed: () {
                                                              _startAutoHideTimer();
                                                              widget
                                                                  .onOpenSleepTimer!();
                                                            },
                                                            tooltip: _tooltipWithShortcut(
                                                              timer.isActive
                                                                  ? timer
                                                                        .statusText
                                                                  : '定时关闭',
                                                              DesktopPlayerShortcutAction
                                                                  .openSleepTimer,
                                                            ),
                                                          );
                                                        },
                                                      ),

                                                    IconButton(
                                                      iconSize: iconSize,
                                                      style:
                                                          bottomIconButtonStyle,
                                                      icon: Icon(
                                                        widget.showSubtitles
                                                            ? Icons.subtitles
                                                            : Icons
                                                                  .subtitles_off,
                                                        color:
                                                            widget.showSubtitles
                                                            ? Colors.blueAccent
                                                            : Colors.white70,
                                                      ),
                                                      onPressed: () {
                                                        _startAutoHideTimer();
                                                        widget
                                                            .onToggleSubtitles();
                                                      },
                                                      tooltip: _tooltipWithShortcut(
                                                        widget.showSubtitles
                                                            ? "隐藏字幕"
                                                            : "显示字幕",
                                                        DesktopPlayerShortcutAction
                                                            .toggleSubtitles,
                                                      ),
                                                    ),

                                                    Selector<
                                                      MediaPlaybackService,
                                                      bool
                                                    >(
                                                      selector: (_, s) =>
                                                          s.isMuted,
                                                      builder: (context, isMuted, _) {
                                                        return IconButton(
                                                          iconSize: iconSize,
                                                          style:
                                                              bottomIconButtonStyle,
                                                          icon: Icon(
                                                            isMuted
                                                                ? Icons
                                                                      .volume_off
                                                                : Icons
                                                                      .volume_up,
                                                            color: isMuted
                                                                ? Colors
                                                                      .redAccent
                                                                : Colors.white,
                                                          ),
                                                          onPressed: () {
                                                            _startAutoHideTimer();
                                                            unawaited(
                                                              playbackService
                                                                  .toggleMute(),
                                                            );
                                                          },
                                                          tooltip:
                                                              _tooltipWithShortcut(
                                                                isMuted
                                                                    ? "取消静音"
                                                                    : "静音",
                                                                DesktopPlayerShortcutAction
                                                                    .toggleMute,
                                                              ),
                                                        );
                                                      },
                                                    ),
                                                  ],
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ), // 底部控制栏 RepaintBoundary 结束
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
            ],
          ),
        );

        // 桌面端：用 Listener 包裹整个播放器区域，捕获鼠标滚轮事件调节音量
        // 必须在 MouseRegion 之前包裹，确保滚轮事件被优先处理
        focusChild = Listener(
          onPointerDown: _onPlayerPointerDown,
          onPointerUp: _finishPlayerPointer,
          onPointerCancel: _finishPlayerPointer,
          onPointerSignal: supportsPointerHover ? _onPointerSignal : null,
          behavior: HitTestBehavior.translucent,
          child: focusChild,
        );

        // Desktop: Wrap with MouseRegion to show controls on mouse movement
        // and hide cursor when controls are hidden for full immersion
        if (supportsPointerHover) {
          return MouseRegion(
            key: const ValueKey('video-controls-player-mouse-region'),
            onEnter: _onMouseEnter,
            onHover: _onMouseHover,
            onExit: _onMouseExit,
            cursor: _showControls ? MouseCursor.defer : SystemMouseCursors.none,
            child: focusChild,
          );
        }
        return focusChild;
      },
    );
  }

  Widget _buildTopBarTitle({
    required String mediaTitle,
    required double fontSize,
    required bool alignRight,
  }) {
    final Alignment alignment = alignRight
        ? Alignment.centerRight
        : Alignment.centerLeft;
    final TextAlign textAlign = alignRight ? TextAlign.right : TextAlign.left;
    return ClipRect(
      child: Align(
        alignment: alignment,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: alignRight,
          physics: const BouncingScrollPhysics(),
          child: ExperimentalTapGateway(
            onTrigger: () => widget.onExperimentalTrigger?.call(),
            child: Text(
              mediaTitle,
              textAlign: textAlign,
              maxLines: 1,
              overflow: TextOverflow.visible,
              style: TextStyle(
                color: Colors.white,
                fontSize: fontSize,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayerSideControlButton extends StatelessWidget {
  final double extent;
  final String tooltip;
  final bool highlighted;
  final VoidCallback onPressed;
  final Widget child;

  const _PlayerSideControlButton({
    super.key,
    required this.extent,
    required this.tooltip,
    this.highlighted = false,
    required this.onPressed,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(extent * 0.36);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: highlighted
            ? _danmakuControlAccent.withValues(alpha: 0.18)
            : Colors.black.withValues(alpha: 0.52),
        shape: RoundedRectangleBorder(
          borderRadius: borderRadius,
          side: BorderSide(
            color: highlighted
                ? _danmakuControlAccent.withValues(alpha: 0.58)
                : Colors.white.withValues(alpha: 0.13),
            width: 0.8,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          borderRadius: borderRadius,
          splashColor: Colors.white.withValues(alpha: 0.12),
          highlightColor: Colors.white.withValues(alpha: 0.06),
          child: SizedBox.square(
            dimension: extent,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

class _DanmakuToggleGlyph extends StatelessWidget {
  final bool enabled;
  final double size;

  const _DanmakuToggleGlyph({required this.enabled, required this.size});

  @override
  Widget build(BuildContext context) {
    final color = enabled ? _danmakuControlAccent : Colors.white54;
    return SizedBox.square(
      dimension: size * 1.12,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Text(
            '弹',
            style: TextStyle(
              color: color,
              fontSize: size * 0.82,
              height: 1,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (!enabled)
            Transform.rotate(
              angle: -math.pi / 4,
              child: Container(
                width: size * 1.05,
                height: math.max(1.2, size * 0.09),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(size),
                  boxShadow: const [
                    BoxShadow(color: Colors.black54, blurRadius: 1),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _KeyboardPressState {
  Timer? timer;
  Duration downStamp = Duration.zero;
  bool longPressTriggered = false;
  bool speedBoostStarted = false;
}
