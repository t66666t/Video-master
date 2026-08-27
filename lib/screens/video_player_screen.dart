import 'dart:async';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:math' as math;
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:cross_file/cross_file.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path/path.dart' as p;
import '../services/embedded_subtitle_service.dart';
import '../services/audio_playback_compatibility_service.dart';
import '../services/media_playback_service.dart';
import '../services/playback_navigation_service.dart';
import '../services/playback_orientation_transition.dart';
import '../services/playlist_manager.dart';
import '../services/system_media_session_service.dart';
import '../services/subtitle_timeline_resolver.dart';
import '../models/subtitle_model.dart';
import '../models/subtitle_style.dart';
import '../models/video_item.dart';
import '../models/media_chapter.dart';
import '../models/managed_subtitle_asset.dart';
import '../models/ocr_subtitle_models.dart';
import 'music_player_screen.dart'; // Experimental Apple Music page
import '../services/settings_service.dart';
import '../services/library_service.dart';
import '../services/task_subtitle_storage_service.dart';
import '../widgets/subtitle_overlay.dart';
import '../widgets/subtitle_display_layer.dart';
import '../models/subtitle_display_state.dart';
import '../widgets/video_controls_overlay.dart';
import '../widgets/player_control_metrics.dart';
import '../widgets/danmaku_overlay.dart';
import '../widgets/danmaku_settings_dialog.dart';
import '../widgets/episode_picker_panel.dart';
import '../widgets/settings_panel.dart';
import '../widgets/subtitle_settings_sheet.dart';
import '../widgets/subtitle_sidebar.dart';
import '../widgets/subtitle_position_sidebar.dart';
import '../widgets/landscape_subtitle_editor_sidebar.dart';
import '../widgets/subtitle_management_sheet.dart';
import '../widgets/ai_transcription_panel.dart';
import '../widgets/video_compose_panel.dart';
import '../widgets/ocr_subtitle_panel.dart';
import '../widgets/chapter_sidebar.dart';
import '../services/transcription_manager.dart';
import '../services/ocr_subtitle_manager.dart';
import '../services/subtitle_discovery_service.dart';
import '../services/video_compose/video_compose_preview_controller.dart';
import '../utils/app_toast.dart';
import '../utils/subtitle_drag_snap.dart';
import '../utils/subtitle_file_matcher.dart';
import '../utils/subtitle_file_picker.dart';
import '../utils/video_gesture_session_gate.dart';

enum SidebarType {
  none,
  chapters,
  subtitles,
  settings,
  subtitleStyle,
  subtitlePosition,
  subtitleManager,
  subtitleEditor,
  aiTranscription,
  videoCompose,
  ocrSubtitle,
}

class VideoPlayerScreen extends StatefulWidget {
  final XFile? videoFile; // Optional now
  final VideoPlayerController? existingController; // New
  final VideoItem? videoItem; // New
  final bool skipAutoPauseOnExit;

  const VideoPlayerScreen({
    super.key,
    this.videoFile,
    this.existingController,
    this.videoItem,
    this.skipAutoPauseOnExit = false,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey<SelectableRegionState> _selectionKey =
      GlobalKey<SelectableRegionState>();
  final FocusNode _selectionFocusNode = FocusNode();
  final FocusNode _videoFocusNode =
      FocusNode(); // New: Dedicated focus node for video controls
  final FocusNode _playbackPageFocusNode = FocusNode(
    debugLabel: 'PlaybackPageShortcutFocus',
  );
  final GlobalKey<VideoControlsOverlayState> _controlsKey =
      GlobalKey<VideoControlsOverlayState>();
  final GlobalKey _videoTextureKey = GlobalKey(
    debugLabel: 'LandscapePlaybackVideoTexture',
  );
  final ValueNotifier<bool> _playbackControlsVisibility = ValueNotifier(true);
  final GlobalKey<SubtitleSidebarState> _subtitleSidebarKey =
      GlobalKey<SubtitleSidebarState>();
  late VideoPlayerController _controller;
  bool _controllerAssigned = false;
  bool _initialized = false;
  bool _isSourceMissing = false;
  bool _isPlaying = false;
  bool _isControllerOwner = true; // Track ownership
  bool _isSubtitleSidebarVisible = true;
  bool _initialControllerConsumed = false;
  bool _isLandscapeViewportReady = true;
  bool _isOrientationTransitioning = false;
  bool get _supportsOcrSubtitle =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isWindows ||
      Platform.isMacOS;

  // Local UI State
  bool _isLocked = false;
  bool _isLongPressing = false;
  String _longPressFeedbackText = "";
  double _preLongPressSpeed = 1.0;
  MediaPlaybackService? _longPressPlaybackService;

  // Sidebar
  SidebarType _activeSidebar = SidebarType.none;
  SidebarType _previousSidebarType = SidebarType.none;
  bool get _isSidebarOpen => _activeSidebar != SidebarType.none;
  bool get _suppressSubtitleOverlayForOcr =>
      _activeSidebar == SidebarType.ocrSubtitle;
  bool _isResizingSidebar = false;
  double? _subtitleSidebarWidthOverride;
  bool _forceExit = false;
  bool _iosBackSwipeActive = false;
  double _iosBackSwipeDistance = 0.0;
  static const double _iosBackSwipeEdgeWidth = 20.0;
  static const double _iosBackSwipeTriggerDistance = 60.0;
  static const double _subtitleSidebarResizerLayoutWidth = 12.0;
  static const double _subtitleSidebarResizerHitWidth = 28.0;
  static const double _subtitleSidebarResizerVisualWidth = 4.0;
  static const double _subtitleSidebarMinWidth = 100.0;
  static const double _subtitleSidebarMinRemainingPlayerWidth = 24.0;

  bool _isCurrentPhysicalLandscape() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isNotEmpty) {
      final Size physicalSize = views.first.physicalSize;
      if (physicalSize.height > 0) {
        return physicalSize.width > physicalSize.height;
      }
    }
    final mediaQuery = MediaQuery.maybeOf(context);
    if (mediaQuery != null) {
      return mediaQuery.orientation == Orientation.landscape;
    }
    return true;
  }

  bool get _usesAndroidPhoneOrientationBridge {
    if (kIsWeb || !Platform.isAndroid || !mounted) return false;
    if (widget.existingController == null) return false;
    final display = View.of(context).display;
    final pixelRatio = display.devicePixelRatio;
    return pixelRatio > 0 && display.size.shortestSide / pixelRatio < 600;
  }

  Future<bool> _waitForPlaybackViewport(PlaybackViewportOrientation target) {
    final view = View.of(context);
    return PlaybackOrientationTransition.waitForViewport(
      readSize: () => view.physicalSize,
      waitForFrame: () => WidgetsBinding.instance.endOfFrame,
      target: target,
      readStabilitySignature: () =>
          PlaybackOrientationTransition.metricsSignature(view),
    );
  }

  Future<void> _showOrientationBridge() async {
    if (!_usesAndroidPhoneOrientationBridge || !mounted) return;
    setState(() {
      _isOrientationTransitioning = true;
    });
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<void> _returnToPortrait({bool saveExitState = true}) async {
    if (_isOrientationTransitioning) return;
    final navigator = Navigator.of(context);
    final useOrientationBridge = _usesAndroidPhoneOrientationBridge;
    if (useOrientationBridge) {
      await _showOrientationBridge();
      if (!mounted) return;
    }

    try {
      if (saveExitState) {
        await _cancelPendingPlaybackIfNeeded();
        await _handleExit();
        if (!mounted) return;
      }
    } catch (error) {
      debugPrint('Saving landscape exit state failed: $error');
    }

    try {
      if (widget.existingController == null) {
        await SystemChrome.setPreferredOrientations(<DeviceOrientation>[]);
      } else {
        await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
        if (useOrientationBridge) {
          final reachedPortrait = await _waitForPlaybackViewport(
            PlaybackViewportOrientation.portrait,
          );
          if (!reachedPortrait) {
            debugPrint(
              'Playback orientation transition: portrait viewport timed out.',
            );
          }
        }
      }
    } catch (error) {
      debugPrint(
        'Playback orientation transition: portrait request failed: $error',
      );
    }
    if (mounted) navigator.pop();
  }

  Future<void> _forceExitPlayer() async {
    if (_isOrientationTransitioning) return;
    _forceExit = true;
    await _returnToPortrait();
  }

  double _getMaxResizableSidebarWidth(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final double maxWidth =
        screenWidth -
        _subtitleSidebarResizerLayoutWidth -
        _subtitleSidebarMinRemainingPlayerWidth;
    return maxWidth.clamp(_subtitleSidebarMinWidth, screenWidth);
  }

  double _clampResizableSidebarWidth(BuildContext context, double width) {
    return width.clamp(
      _subtitleSidebarMinWidth,
      _getMaxResizableSidebarWidth(context),
    );
  }

  double _getSidebarWidth(BuildContext context, SettingsService settings) {
    final effectiveSubtitleSidebarWidth = _clampResizableSidebarWidth(
      context,
      _subtitleSidebarWidthOverride ?? settings.userSubtitleSidebarWidth,
    );
    final bool canEditGhostStyle = _canUseGhostSidebarEditing(
      context,
      settings,
    );
    if (_activeSidebar == SidebarType.subtitles ||
        _activeSidebar == SidebarType.subtitleEditor) {
      return effectiveSubtitleSidebarWidth;
    }
    if (_activeSidebar == SidebarType.subtitlePosition && _isGhostDragMode) {
      // Add the visible resizer lane to match the total occupied width.
      return effectiveSubtitleSidebarWidth + _subtitleSidebarResizerLayoutWidth;
    }
    if (_activeSidebar == SidebarType.subtitleStyle && canEditGhostStyle) {
      return effectiveSubtitleSidebarWidth + _subtitleSidebarResizerLayoutWidth;
    }
    final screenWidth = MediaQuery.of(context).size.width;
    if (_activeSidebar == SidebarType.chapters) {
      return screenWidth < 600
          ? screenWidth * 0.78
          : (screenWidth * 0.3).clamp(300.0, 440.0);
    }
    final isSmallScreen = screenWidth < 600;
    return isSmallScreen ? (screenWidth * 0.75).clamp(240.0, 300.0) : 320.0;
  }

  void _startSidebarResize(SettingsService settings, BuildContext context) {
    setState(() {
      _isResizingSidebar = true;
      _subtitleSidebarWidthOverride = _clampResizableSidebarWidth(
        context,
        _subtitleSidebarWidthOverride ?? settings.userSubtitleSidebarWidth,
      );
    });
  }

  void _updateSidebarResize(
    SettingsService settings,
    BuildContext context,
    bool isLeftHandedMode,
    DragUpdateDetails details,
  ) {
    final currentWidth =
        _subtitleSidebarWidthOverride ?? settings.userSubtitleSidebarWidth;
    final nextWidth = isLeftHandedMode
        ? currentWidth + details.delta.dx
        : currentWidth - details.delta.dx;
    final clampedWidth = _clampResizableSidebarWidth(context, nextWidth);
    if (_subtitleSidebarWidthOverride == clampedWidth) {
      return;
    }
    setState(() {
      _subtitleSidebarWidthOverride = clampedWidth;
    });
  }

  Future<void> _endSidebarResize(SettingsService settings) async {
    final widthToPersist = _subtitleSidebarWidthOverride;
    if (mounted) {
      setState(() {
        _isResizingSidebar = false;
      });
    }
    if (widthToPersist != null &&
        (widthToPersist - settings.userSubtitleSidebarWidth).abs() > 0.01) {
      await settings.saveUserSubtitleSidebarWidth(widthToPersist);
    }
    if (mounted) {
      setState(() {
        _subtitleSidebarWidthOverride = null;
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _subtitleSidebarKey.currentState?.triggerLocateForAutoFollow();
    });
  }

  bool _canShowGhostSidebarControls(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    return !_isAudio && _isSubtitleSidebarVisible && isLandscape;
  }

  bool _canUseGhostSidebarEditing(
    BuildContext context,
    SettingsService settings,
  ) {
    return _canShowGhostSidebarControls(context) && settings.isGhostModeEnabled;
  }

  SidebarType _normalizedSidebarForRestore(SidebarType sidebar) {
    if (sidebar == SidebarType.subtitlePosition) {
      return _isSubtitleSidebarVisible
          ? SidebarType.subtitles
          : SidebarType.none;
    }
    return sidebar;
  }

  bool get _canUseVideoTransformGestures {
    return _initialized &&
        !_isAudio &&
        !_isLocked &&
        !_isLongPressing &&
        !_videoGestureSession.blocksTransforms &&
        !_isSubtitleDragMode &&
        !_isGhostDragMode &&
        !_isStyleSidebarDragMode;
  }

  bool get _hasCustomVideoTransform {
    return (_videoUserScale - 1.0).abs() > 0.001 ||
        _videoUserRotation.abs() > 0.001 ||
        _videoUserOffsetNormalized.distance > 0.001;
  }

  void _setScreenLock(bool locked) {
    if (_isLocked == locked) return;
    _cancelVideoTransformAnimation();
    setState(() {
      _isLocked = locked;
      if (locked) {
        _activeVideoTransformPointers.clear();
        _isVideoTransformGestureActive = false;
      }
    });
  }

  bool _resolvedVideoMirrorH(SettingsService settings) {
    return _currentItem?.isVideoMirroredH ?? _fallbackVideoMirroredH;
  }

  bool _resolvedVideoMirrorV(SettingsService settings) {
    return _currentItem?.isVideoMirroredV ?? _fallbackVideoMirroredV;
  }

  Offset _denormalizeVideoOffset(Offset normalizedOffset, Size viewportSize) {
    if (viewportSize.width <= 0 || viewportSize.height <= 0) {
      return Offset.zero;
    }
    return Offset(
      normalizedOffset.dx * (viewportSize.width / 2),
      normalizedOffset.dy * (viewportSize.height / 2),
    );
  }

  Offset _normalizeOffsetInViewport(Offset pixelOffset, Size viewportSize) {
    if (viewportSize.width <= 0 || viewportSize.height <= 0) {
      return Offset.zero;
    }
    return Offset(
      pixelOffset.dx / (viewportSize.width / 2),
      pixelOffset.dy / (viewportSize.height / 2),
    );
  }

  Size _computeContainedVideoSize(Size viewportSize, double aspectRatio) {
    if (viewportSize.width <= 0 || viewportSize.height <= 0) {
      return Size.zero;
    }
    final double safeAspectRatio = aspectRatio > 0 ? aspectRatio : 16 / 9;
    final double viewportAspectRatio = viewportSize.width / viewportSize.height;
    double width = viewportSize.width;
    double height = viewportSize.height;

    if (safeAspectRatio > viewportAspectRatio) {
      height = width / safeAspectRatio;
    } else {
      width = height * safeAspectRatio;
    }

    return Size(width, height);
  }

  List<Rect> _playbackControlAvoidanceRects({
    required BuildContext context,
    required Size playerSize,
    required PlayerControlMetrics metrics,
    required double clearance,
  }) {
    final double baseControlsTop =
        playerSize.height -
        metrics.bottomControlsHeight(hasChapterButton: false) -
        clearance;
    final rects = <Rect>[
      Rect.fromLTRB(0, baseControlsTop, playerSize.width, playerSize.height),
    ];

    final chapters = _currentItem?.chapters ?? const <MediaChapter>[];
    if (chapters.isEmpty) return rects;

    final Duration position = _controllerAssigned
        ? _controller.value.position
        : Duration.zero;
    final MediaChapter chapter =
        MediaChapter.atPosition(chapters, position) ?? chapters.first;
    final TextDirection textDirection = Directionality.of(context);
    final TextStyle chapterTextStyle = DefaultTextStyle.of(context).style.merge(
      TextStyle(
        color: Colors.white,
        fontSize: (13 * metrics.scale).clamp(10.0, 13.0).toDouble(),
        fontWeight: FontWeight.w600,
      ),
    );
    final double iconSize = (18 * metrics.scale).clamp(16.0, 18.0).toDouble();
    final double contentGap = (5 * metrics.scale).clamp(3.0, 5.0).toDouble();
    final double horizontalPadding = (12 * metrics.scale)
        .clamp(9.0, 12.0)
        .toDouble();
    final double measurementSlack = (4 * metrics.scale)
        .clamp(3.0, 4.0)
        .toDouble();
    final TextPainter painter = TextPainter(
      text: TextSpan(text: chapter.title, style: chapterTextStyle),
      maxLines: 1,
      textDirection: textDirection,
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
      textWidthBasis: TextWidthBasis.longestLine,
    )..layout();

    final double trackInset = math.max(
      metrics.overlayRadius,
      metrics.thumbRadius,
    );
    final double sliderWidth = math
        .max(0, playerSize.width - (metrics.bottomHorizontalPadding * 2))
        .toDouble();
    final double maxButtonWidth = math
        .max(
          0,
          (sliderWidth - (trackInset * 2)) * metrics.chapterButtonWidthFactor,
        )
        .toDouble();
    final double measuredButtonWidth =
        (horizontalPadding * 2) +
        contentGap +
        iconSize +
        painter.width +
        measurementSlack;
    final double buttonWidth = math.min(maxButtonWidth, measuredButtonWidth);
    final double buttonLeft = metrics.bottomHorizontalPadding + trackInset;
    final double buttonTop =
        playerSize.height -
        metrics.bottomPadding -
        metrics.bottomRowHeight -
        metrics.progressHitHeight -
        metrics.chapterButtonHeight -
        clearance;
    final double buttonBottom =
        playerSize.height -
        metrics.bottomPadding -
        metrics.bottomRowHeight -
        metrics.progressHitHeight;
    rects.add(
      Rect.fromLTRB(
        buttonLeft,
        buttonTop,
        buttonLeft + buttonWidth,
        buttonBottom,
      ),
    );
    return rects;
  }

  double _normalizeVideoRotation(double radians) {
    final double fullTurn = math.pi * 2;
    double normalized = radians % fullTurn;
    if (normalized > math.pi) normalized -= fullTurn;
    if (normalized < -math.pi) normalized += fullTurn;
    return normalized;
  }

  double _applyRotationSnap(double radians) {
    final double quarterTurn = math.pi / 2;
    final double target = (radians / quarterTurn).round() * quarterTurn;
    if ((radians - target).abs() <= _videoRotationSnapThreshold) {
      return _normalizeVideoRotation(target);
    }
    return _normalizeVideoRotation(radians);
  }

  Offset _rotateVector(Offset vector, double radians) {
    final double cosValue = math.cos(radians);
    final double sinValue = math.sin(radians);
    return Offset(
      vector.dx * cosValue - vector.dy * sinValue,
      vector.dx * sinValue + vector.dy * cosValue,
    );
  }

  double _angleDeltaBetween(double startAngle, double currentAngle) {
    return _normalizeVideoRotation(currentAngle - startAngle);
  }

  double _movementDirectionCosine(Offset first, Offset second) {
    final double firstDistance = first.distance;
    final double secondDistance = second.distance;
    if (firstDistance <= 0.0001 || secondDistance <= 0.0001) {
      return 1.0;
    }
    final double dotProduct = first.dx * second.dx + first.dy * second.dy;
    final num clampedCosine = (dotProduct / (firstDistance * secondDistance))
        .clamp(-1.0, 1.0);
    return clampedCosine.toDouble();
  }

  Offset _contentVectorForFocalPoint({
    required Offset focalPoint,
    required Rect viewportRect,
    required double scale,
    required double rotation,
    required Offset normalizedOffset,
  }) {
    final Offset pixelOffset = _denormalizeVideoOffset(
      normalizedOffset,
      viewportRect.size,
    );
    final double safeScale = scale
        .clamp(_minVideoUserScale, _maxVideoUserScale)
        .toDouble();
    final Offset centeredVector =
        focalPoint - viewportRect.center - pixelOffset;
    return _rotateVector(centeredVector / safeScale, -rotation);
  }

  Offset _normalizedOffsetForContentVector({
    required Offset contentVector,
    required Offset focalPoint,
    required Rect viewportRect,
    required double scale,
    required double rotation,
  }) {
    final double safeScale = scale
        .clamp(_minVideoUserScale, _maxVideoUserScale)
        .toDouble();
    final Offset transformedVector = _rotateVector(
      contentVector * safeScale,
      rotation,
    );
    final Offset pixelOffset =
        focalPoint - viewportRect.center - transformedVector;
    return _normalizeOffsetInViewport(pixelOffset, viewportRect.size);
  }

  double _filteredVideoGestureRotationDelta({
    required double rawRotationDelta,
    required double startDistance,
    required double distanceDelta,
    required double focalTranslationDistance,
    required double pointerDirectionCosine,
  }) {
    final double deltaMagnitude = rawRotationDelta.abs();
    if (deltaMagnitude <= 0.0001) {
      return 0.0;
    }
    final double rotationArcDistance = (startDistance * deltaMagnitude) / 2;
    final bool likelyPanGesture =
        pointerDirectionCosine > 0.82 &&
        focalTranslationDistance > 10.0 &&
        focalTranslationDistance > rotationArcDistance * 1.2;
    if (likelyPanGesture) {
      return 0.0;
    }
    final bool likelyScaleGesture =
        pointerDirectionCosine < -0.35 &&
        distanceDelta > 8.0 &&
        distanceDelta > rotationArcDistance * 1.35 &&
        focalTranslationDistance < distanceDelta * 0.75;
    if (likelyScaleGesture &&
        deltaMagnitude <= _videoRotationScaleBiasThreshold) {
      return 0.0;
    }
    final double rotationDeadZone = likelyScaleGesture
        ? _videoRotationScaleBiasThreshold
        : (pointerDirectionCosine > 0.6
              ? _videoRotationPanBiasThreshold
              : _videoRotationIntentThreshold);
    if (deltaMagnitude <= rotationDeadZone) {
      return 0.0;
    }
    final double preservedMagnitude = deltaMagnitude - rotationDeadZone;
    return rawRotationDelta.isNegative
        ? -preservedMagnitude
        : preservedMagnitude;
  }

  Matrix4 _buildVideoTransformMatrix(
    Size viewportSize,
    SettingsService settings,
  ) {
    final Offset pixelOffset = _denormalizeVideoOffset(
      _videoUserOffsetNormalized,
      viewportSize,
    );
    final Matrix4 transform = Matrix4.identity()
      ..setEntry(0, 3, pixelOffset.dx)
      ..setEntry(1, 3, pixelOffset.dy)
      ..multiply(Matrix4.rotationZ(_videoUserRotation))
      ..multiply(Matrix4.diagonal3Values(_videoUserScale, _videoUserScale, 1.0))
      ..multiply(
        Matrix4.diagonal3Values(
          _resolvedVideoMirrorH(settings) ? -1.0 : 1.0,
          _resolvedVideoMirrorV(settings) ? -1.0 : 1.0,
          1.0,
        ),
      );
    return transform;
  }

  Widget _buildVideoBoundSubtitleOverlay({
    required Size videoSize,
    required Alignment alignment,
    required SubtitleStyle style,
    bool isDragging = false,
    bool isGestureOnly = false,
    bool isVisualOnly = false,
    bool animateAlignment = false,
    bool enablePanUpdate = false,
    ValueListenable<SubtitleDisplayState>? displayNotifier,
    ValueListenable<bool>? playbackControlsVisibility,
    double? playbackControlsTop,
    List<Rect> Function()? playbackControlRects,
    bool avoidPlaybackControls = false,
  }) {
    if (videoSize.width <= 0 || videoSize.height <= 0) {
      return const SizedBox.shrink();
    }

    Widget overlay = SizedBox(
      width: videoSize.width,
      height: videoSize.height,
      child: SubtitleDisplayLayer(
        notifier: displayNotifier ?? subtitleDisplayNotifier,
        alignment: alignment,
        style: style,
        isDragging: isDragging,
        isGestureOnly: isGestureOnly,
        isVisualOnly: isVisualOnly,
        animateAlignment: animateAlignment,
        playbackControlsVisibility: playbackControlsVisibility,
        playbackControlsTop: playbackControlsTop,
        playbackControlRects: playbackControlRects,
        avoidPlaybackControls: avoidPlaybackControls,
      ),
    );

    if (enablePanUpdate) {
      final overlayConstraints = BoxConstraints.tight(videoSize);
      overlay = GestureDetector(
        onPanUpdate: (details) =>
            _updateSubtitlePosition(details, overlayConstraints),
        child: overlay,
      );
    }

    return Positioned.fill(
      child: ClipRect(child: Center(child: overlay)),
    );
  }

  Widget _buildVideoBoundDanmakuOverlay({
    required Size videoSize,
    required double playerHeight,
    required SettingsService settings,
  }) {
    final item = _currentItem;
    final path = item?.danmakuPath;
    if (item == null ||
        !item.isBilibiliExported ||
        path == null ||
        path.isEmpty ||
        !settings.showBilibiliDanmaku ||
        videoSize.isEmpty ||
        !File(path).existsSync()) {
      return const SizedBox.shrink();
    }
    final position = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    ).positionNotifier;
    final overlay = DanmakuOverlay(
      path: path,
      position: position,
      displayArea: settings.bilibiliDanmakuDisplayArea,
      opacity: settings.bilibiliDanmakuOpacity,
      fontScale: settings.bilibiliDanmakuFontScale,
      speed: settings.bilibiliDanmakuSpeed,
      fontFamily: settings.bilibiliDanmakuFontFamily,
      fontWeight: settings.bilibiliDanmakuFontWeight,
      outlineType: settings.bilibiliDanmakuOutlineType,
      playerHeight: playerHeight,
    );
    return Positioned.fill(
      child: ClipRect(
        child: settings.bilibiliDanmakuOnlyInVideoArea
            ? Center(
                child: SizedBox(
                  width: videoSize.width,
                  height: videoSize.height,
                  child: overlay,
                ),
              )
            : overlay,
      ),
    );
  }

  Widget _buildFreeSubtitleOverlay({
    required Alignment alignment,
    required SubtitleStyle style,
    bool isDragging = false,
    bool isGestureOnly = false,
    bool isVisualOnly = false,
    bool animateAlignment = false,
    bool enablePanUpdate = false,
    bool isGhost = false,
    ValueListenable<SubtitleDisplayState>? displayNotifier,
    ValueListenable<bool>? playbackControlsVisibility,
    double? playbackControlsTop,
    List<Rect> Function()? playbackControlRects,
    bool avoidPlaybackControls = false,
  }) {
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          Widget overlay = SizedBox.expand(
            child: SubtitleDisplayLayer(
              notifier: displayNotifier ?? subtitleDisplayNotifier,
              alignment: alignment,
              style: style,
              isDragging: isDragging,
              isGestureOnly: isGestureOnly,
              isVisualOnly: isVisualOnly,
              animateAlignment: animateAlignment,
              playbackControlsVisibility: playbackControlsVisibility,
              playbackControlsTop: playbackControlsTop,
              playbackControlRects: playbackControlRects,
              avoidPlaybackControls: avoidPlaybackControls,
            ),
          );

          if (enablePanUpdate) {
            final overlayConstraints = BoxConstraints.tightFor(
              width: constraints.maxWidth,
              height: constraints.maxHeight,
            );
            overlay = GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanUpdate: (details) => _updateSubtitlePosition(
                details,
                overlayConstraints,
                isGhost: isGhost,
              ),
              child: overlay,
            );
          }

          return ClipRect(child: overlay);
        },
      ),
    );
  }

  void _setVideoTransformValues({
    required double scale,
    required double rotation,
    required Offset normalizedOffset,
  }) {
    _videoUserScale = scale.clamp(_minVideoUserScale, _maxVideoUserScale);
    _videoUserRotation = _normalizeVideoRotation(rotation);
    _videoUserOffsetNormalized = normalizedOffset;
  }

  void _cancelVideoTransformAnimation() {
    if (_videoTransformAnimationController.isAnimating) {
      _videoTransformAnimationController.stop();
    }
  }

  void _animateVideoTransformTo({
    required double scale,
    required double rotation,
    required Offset normalizedOffset,
    Duration duration = const Duration(milliseconds: 180),
    Curve curve = Curves.easeOutCubic,
  }) {
    _cancelVideoTransformAnimation();
    final Animation<double> progress = CurvedAnimation(
      parent: _videoTransformAnimationController,
      curve: curve,
    );
    _videoScaleAnimation = Tween<double>(
      begin: _videoUserScale,
      end: scale.clamp(_minVideoUserScale, _maxVideoUserScale),
    ).animate(progress);
    _videoRotationAnimation = Tween<double>(
      begin: _videoUserRotation,
      end: _normalizeVideoRotation(rotation),
    ).animate(progress);
    _videoOffsetAnimation = Tween<Offset>(
      begin: _videoUserOffsetNormalized,
      end: normalizedOffset,
    ).animate(progress);
    _videoTransformAnimationController.duration = duration;
    _videoTransformAnimationController.forward(from: 0);
  }

  /// 实验性功能：五连击标题进入 Apple Music 风格播放页面
  Future<void> _navigateToMusicPlayer() async {
    final service = Provider.of<MediaPlaybackService>(context, listen: false);
    final settings = Provider.of<SettingsService>(context, listen: false);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MusicPlayerScreen(
          coverImagePath: _currentItem?.thumbnailPath,
          title: _currentItem?.title ?? '',
          onSeek: (pos) => service.seekTo(pos),
          onPlayPause: () {
            if (service.isPlaying) {
              service.pause();
            } else {
              service.resume();
            }
          },
          onPrevious: () =>
              service.playPrevious(autoPlay: settings.autoPlayNextVideo),
          onNext: () => service.playNext(autoPlay: settings.autoPlayNextVideo),
        ),
        fullscreenDialog: true,
      ),
    );
    // 从音乐播放页切回视频播放页完成：将字幕文稿自动定位到当前字幕，
    // 同时修复切回时字幕文稿显示区偶发空白的问题。
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _subtitleSidebarKey.currentState?.locateToCurrentSubtitle(
        ignorePointer: true,
      );
    });
  }

  void _resetVideoUserTransform({bool animated = true}) {
    if (animated) {
      _animateVideoTransformTo(
        scale: 1.0,
        rotation: 0.0,
        normalizedOffset: Offset.zero,
      );
      return;
    }
    _cancelVideoTransformAnimation();
    setState(() {
      _setVideoTransformValues(
        scale: 1.0,
        rotation: 0.0,
        normalizedOffset: Offset.zero,
      );
    });
  }

  List<MapEntry<int, Offset>> _activeVideoTransformPair() {
    final List<MapEntry<int, Offset>> entries =
        _activeVideoTransformPointers.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));
    return entries.take(2).toList();
  }

  double _distanceBetween(Offset a, Offset b) {
    return (a - b).distance;
  }

  double _angleBetween(Offset a, Offset b) {
    final Offset vector = b - a;
    return math.atan2(vector.dy, vector.dx);
  }

  void _rebaseVideoTransformGesture() {
    final List<MapEntry<int, Offset>> pair = _activeVideoTransformPair();
    if (pair.length < 2) return;
    _gestureStartPointerA = pair[0].value;
    _gestureStartPointerB = pair[1].value;
    _gestureStartFocalPoint = Offset.lerp(pair[0].value, pair[1].value, 0.5)!;
    _gestureCurrentFocalPoint = _gestureStartFocalPoint;
    _gestureStartDistance = _distanceBetween(
      pair[0].value,
      pair[1].value,
    ).clamp(1.0, double.infinity);
    _gestureStartAngle = _angleBetween(pair[0].value, pair[1].value);
    _gestureBaseScale = _videoUserScale;
    _gestureBaseRotation = _videoUserRotation;
    _gestureBaseOffsetNormalized = _videoUserOffsetNormalized;
    _gestureBaseContentVector = _contentVectorForFocalPoint(
      focalPoint: _gestureStartFocalPoint,
      viewportRect: _lastVideoViewportRect,
      scale: _gestureBaseScale,
      rotation: _gestureBaseRotation,
      normalizedOffset: _gestureBaseOffsetNormalized,
    );
  }

  bool _isWithinVideoViewport(Offset localPosition) {
    return _lastVideoViewportRect.contains(localPosition);
  }

  void _beginVideoTransformGesture() {
    if (!_canUseVideoTransformGestures) return;
    final List<MapEntry<int, Offset>> pair = _activeVideoTransformPair();
    if (pair.length < 2) return;
    if (!_isWithinVideoViewport(pair[0].value) &&
        !_isWithinVideoViewport(pair[1].value)) {
      return;
    }
    _cancelVideoTransformAnimation();
    _rebaseVideoTransformGesture();
    if (!_isVideoTransformGestureActive) {
      setState(() {
        _isVideoTransformGestureActive = true;
      });
    }
  }

  void _updateVideoTransformGesture() {
    if (!_canUseVideoTransformGestures || !_isVideoTransformGestureActive) {
      return;
    }
    final List<MapEntry<int, Offset>> pair = _activeVideoTransformPair();
    if (pair.length < 2 || _lastVideoViewportRect.isEmpty) return;

    final Offset focalPoint = Offset.lerp(pair[0].value, pair[1].value, 0.5)!;
    final double distance = _distanceBetween(pair[0].value, pair[1].value);
    final double angle = _angleBetween(pair[0].value, pair[1].value);
    final double distanceDelta = (distance - _gestureStartDistance).abs();
    final double nextScale =
        (_gestureBaseScale *
                (distance / _gestureStartDistance).clamp(
                  0.0001,
                  double.infinity,
                ))
            .clamp(_minVideoUserScale, _maxVideoUserScale)
            .toDouble();
    final Offset pointerMoveA = pair[0].value - _gestureStartPointerA;
    final Offset pointerMoveB = pair[1].value - _gestureStartPointerB;
    final double pointerDirectionCosine = _movementDirectionCosine(
      pointerMoveA,
      pointerMoveB,
    );
    final double effectiveRotationDelta = _filteredVideoGestureRotationDelta(
      rawRotationDelta: _angleDeltaBetween(_gestureStartAngle, angle),
      startDistance: _gestureStartDistance,
      distanceDelta: distanceDelta,
      focalTranslationDistance: (focalPoint - _gestureStartFocalPoint).distance,
      pointerDirectionCosine: pointerDirectionCosine,
    );
    final double nextRotation = _gestureBaseRotation + effectiveRotationDelta;
    final Offset normalizedOffset = _normalizedOffsetForContentVector(
      contentVector: _gestureBaseContentVector,
      focalPoint: focalPoint,
      viewportRect: _lastVideoViewportRect,
      scale: nextScale,
      rotation: nextRotation,
    );

    setState(() {
      _gestureCurrentFocalPoint = focalPoint;
      _setVideoTransformValues(
        scale: nextScale,
        rotation: nextRotation,
        normalizedOffset: normalizedOffset,
      );
    });
  }

  void _endVideoTransformGesture() {
    if (!_isVideoTransformGestureActive) return;
    final double snappedRotation = _applyRotationSnap(_videoUserRotation);
    final Offset snapFocalPoint =
        _lastVideoViewportRect.contains(_gestureCurrentFocalPoint)
        ? _gestureCurrentFocalPoint
        : _lastVideoViewportRect.center;
    final Offset snapContentVector = _contentVectorForFocalPoint(
      focalPoint: snapFocalPoint,
      viewportRect: _lastVideoViewportRect,
      scale: _videoUserScale,
      rotation: _videoUserRotation,
      normalizedOffset: _videoUserOffsetNormalized,
    );
    final Offset snappedOffset = _normalizedOffsetForContentVector(
      contentVector: snapContentVector,
      focalPoint: snapFocalPoint,
      viewportRect: _lastVideoViewportRect,
      scale: _videoUserScale,
      rotation: snappedRotation,
    );
    setState(() {
      _isVideoTransformGestureActive = false;
    });
    if ((snappedRotation - _videoUserRotation).abs() > 0.0001) {
      _animateVideoTransformTo(
        scale: _videoUserScale,
        rotation: snappedRotation,
        normalizedOffset: snappedOffset,
      );
    }
  }

  void _handleVideoTransformPointerDown(PointerDownEvent event) {
    // Keep an independent view of every pointer in this player. This is also
    // updated while transform gestures are locked so that a finger left on
    // screen after long-press ends cannot start a new transform session.
    _videoGestureSession.pointerDown(event.pointer);
    if (!_canUseVideoTransformGestures ||
        !_isWithinVideoViewport(event.localPosition)) {
      return;
    }
    _activeVideoTransformPointers[event.pointer] = event.localPosition;
    if (_activeVideoTransformPointers.length == 2) {
      _beginVideoTransformGesture();
    } else if (_isVideoTransformGestureActive &&
        _activeVideoTransformPointers.length > 2) {
      _rebaseVideoTransformGesture();
    }
  }

  void _handleVideoTransformPointerMove(PointerMoveEvent event) {
    if (!_canUseVideoTransformGestures) {
      _activeVideoTransformPointers.clear();
      if (_isVideoTransformGestureActive) {
        setState(() {
          _isVideoTransformGestureActive = false;
        });
      }
      return;
    }
    if (!_activeVideoTransformPointers.containsKey(event.pointer)) return;
    _activeVideoTransformPointers[event.pointer] = event.localPosition;
    if (_activeVideoTransformPointers.length >= 2 &&
        !_isVideoTransformGestureActive) {
      _beginVideoTransformGesture();
    }
    _updateVideoTransformGesture();
  }

  void _handleVideoTransformPointerEnd(int pointer) {
    _videoGestureSession.pointerUp(pointer);

    if (_videoGestureSession.blocksTransforms) {
      _activeVideoTransformPointers.remove(pointer);
      return;
    }

    final bool wasTracking =
        _activeVideoTransformPointers.remove(pointer) != null;
    if (!wasTracking) return;
    if (_activeVideoTransformPointers.length >= 2) {
      _rebaseVideoTransformGesture();
      return;
    }
    _endVideoTransformGesture();
  }

  // Subtitles
  List<SubtitleItem> _subtitles = [];
  List<SubtitleItem> _secondarySubtitles = []; // New: Secondary subtitle list
  List<String> _currentSubtitlePaths = []; // Track loaded paths
  int _subtitleRevision = -1;
  String _currentSubtitleText = "";
  String? _currentSecondaryText; // New: Secondary text state
  Uint8List? _currentSubtitleImage;
  int _currentSubtitleIndex = -1;
  int _currentSecondarySubtitleIndex = -1;
  List<int> _currentSubtitleIndices = [];
  List<int> _currentSecondarySubtitleIndices = [];
  List<SubtitleOverlayEntry> _currentSubtitleEntries = [];
  final Map<int, Uint8List?> _currentSubtitleImages = <int, Uint8List?>{};

  /// 字幕显示状态通知器 — 字幕更新时仅重建字幕叠加层，不触发整页 setState。
  final ValueNotifier<SubtitleDisplayState> subtitleDisplayNotifier =
      ValueNotifier<SubtitleDisplayState>(SubtitleDisplayState.empty);
  final VideoComposePreviewController _videoComposePreviewController =
      VideoComposePreviewController();
  bool _videoComposePreviewActive = false;
  int _subtitleImageRequestId = 0;
  SubtitleTimelineResolver _subtitleTimeline = SubtitleTimelineResolver(
    const <SubtitleItem>[],
  );
  SubtitleTimelineResolver _secondarySubtitleTimeline =
      SubtitleTimelineResolver(const <SubtitleItem>[]);
  Timer? _subtitleSeekTimer;
  bool _isParsingSubtitles = false;
  bool _userRequestedSubtitles = false;

  // Subtitle Positioning Mode
  bool _isSubtitleDragMode = false;
  bool _isGhostDragMode = false;
  bool _isSubtitleSnappedX = false;
  bool _isSubtitleSnappedY = false;
  bool _isSubtitleNearCenterX = false;
  bool _isSubtitleNearCenterY = false;
  bool _isStyleSidebarDragMode = false;
  bool _showEpisodePicker = false; // Add state for episode picker

  // Temporary user transform state for landscape video surface
  static const double _minVideoUserScale = 0.02;
  static const double _maxVideoUserScale = 1000.0;
  static const double _videoRotationSnapThreshold = 8 * math.pi / 180;
  static const double _videoRotationIntentThreshold = 10 * math.pi / 180;
  static const double _videoRotationPanBiasThreshold = 14 * math.pi / 180;
  static const double _videoRotationScaleBiasThreshold = 18 * math.pi / 180;
  double _videoUserScale = 1.0;
  double _videoUserRotation = 0.0;
  Offset _videoUserOffsetNormalized = Offset.zero;
  bool _fallbackVideoMirroredH = false;
  bool _fallbackVideoMirroredV = false;
  bool _isVideoTransformGestureActive = false;
  Rect _lastVideoViewportRect = Rect.zero;
  final Map<int, Offset> _activeVideoTransformPointers = <int, Offset>{};
  // Once touch long-press wins a gesture session, transform gestures stay
  // suppressed until every finger from that session has left the screen.
  // Merely clearing this when the primary long-press finger lifts would let a
  // remaining second finger accidentally zoom or rotate the video.
  final VideoGestureSessionGate _videoGestureSession =
      VideoGestureSessionGate();
  Offset _gestureStartFocalPoint = Offset.zero;
  Offset _gestureCurrentFocalPoint = Offset.zero;
  Offset _gestureStartPointerA = Offset.zero;
  Offset _gestureStartPointerB = Offset.zero;
  double _gestureStartDistance = 0.0;
  double _gestureStartAngle = 0.0;
  double _gestureBaseScale = 1.0;
  double _gestureBaseRotation = 0.0;
  Offset _gestureBaseOffsetNormalized = Offset.zero;
  Offset _gestureBaseContentVector = Offset.zero;
  late final AnimationController _videoTransformAnimationController;
  Animation<double>? _videoScaleAnimation;
  Animation<double>? _videoRotationAnimation;
  Animation<Offset>? _videoOffsetAnimation;
  final ValueNotifier<double> _keyboardInsetBottom = ValueNotifier<double>(0);

  // Repair state
  bool _isRepairing = false;
  double _repairProgress = 0.0;

  // Audio state
  bool _isAudio = false;
  String? _fatalErrorMessage;

  // Embedded subtitle loading state
  bool _isLoadingEmbeddedSubtitle = false;
  String? _autoEmbeddedAttemptedForItemId;
  bool _embeddedSubtitleDetected = false;
  bool _suppressAutoEmbeddedForCurrentItem = false;

  bool _isImageSubtitleCodec(String codecName) {
    final codec = codecName.toLowerCase();
    return codec == 'hdmv_pgs_subtitle' ||
        codec == 'dvd_subtitle' ||
        codec == 'pgs' ||
        codec == 'pgs_subtitle' ||
        codec == 'vobsub' ||
        codec == 'xsub';
  }

  TranscriptionManager? _transcriptionManager;
  OcrSubtitleManager? _ocrSubtitleManager;
  VideoItem? _currentItem;
  SettingsService? _settingsService;
  bool? _lastShowSubtitles;
  Duration? _lastSubtitleOffset;
  bool? _lastSplitSubtitleByLine;
  bool? _lastVideoContinuousSubtitle;
  bool? _lastAudioContinuousSubtitle;
  bool? _lastGhostModeEnabled;
  int _subtitleRefreshToken = 0;
  int _postInitWorkToken = 0;

  @override
  void initState() {
    super.initState();
    _videoTransformAnimationController = AnimationController(vsync: this)
      ..addListener(() {
        final Animation<double>? scaleAnimation = _videoScaleAnimation;
        final Animation<double>? rotationAnimation = _videoRotationAnimation;
        final Animation<Offset>? offsetAnimation = _videoOffsetAnimation;
        if (!mounted ||
            scaleAnimation == null ||
            rotationAnimation == null ||
            offsetAnimation == null) {
          return;
        }
        setState(() {
          _setVideoTransformValues(
            scale: scaleAnimation.value,
            rotation: rotationAnimation.value,
            normalizedOffset: offsetAnimation.value,
          );
        });
      });
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addEarlyKeyEventHandler(_handlePlaybackEarlyKeyEvent);
    _keyboardInsetBottom.value = _readBottomViewInset();
    _currentItem = widget.videoItem;
    _isLandscapeViewportReady =
        kIsWeb ||
        !(Platform.isAndroid || Platform.isIOS) ||
        _isCurrentPhysicalLandscape();
    // A handed-off controller means the source page already completed the
    // physical orientation change. Repeating the platform request here can
    // make some OEMs start a second window transition after the route appears.
    if (!kIsWeb &&
        (Platform.isAndroid || Platform.isIOS) &&
        widget.existingController == null) {
      unawaited(
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]),
      );
    }
    _enterImmersiveMode();
    final settings = Provider.of<SettingsService>(context, listen: false);
    _isSubtitleSidebarVisible = settings.isLandscapeSubtitleSidebarVisible;
    _activeSidebar = _isSubtitleSidebarVisible
        ? SidebarType.subtitles
        : SidebarType.none;
    if (Platform.isAndroid) {
      unawaited(_requestNotificationPermissionForMediaSession());
    }

    _initVideo();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_videoFocusNode.canRequestFocus) {
        _videoFocusNode.requestFocus();
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final playbackService = Provider.of<MediaPlaybackService>(
          context,
          listen: false,
        );
        playbackService.addListener(_onPlaybackServiceChange);
        // 横屏播放页禁用自动播放下一集，视频播放完成后暂停
        playbackService.autoPlayNextEnabled = false;
        // Re-sync subtitles from the service to catch any subtitle changes
        // that occurred between _initVideo and listener registration.
        // This fixes the race condition where the portrait page finishes
        // loading subtitles (and calls setSubtitleState → notifyListeners)
        // after _initVideo already read the old state but before this
        // listener was registered, causing the notification to be missed.
        _syncSubtitlesFromService(playbackService);
        _onPlaybackServiceChange();
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final settings = Provider.of<SettingsService>(context, listen: false);
      _settingsService = settings;
      _lastShowSubtitles = settings.showSubtitles;
      _lastSubtitleOffset = settings.subtitleOffset;
      _lastSplitSubtitleByLine = settings.splitSubtitleByLine;
      _lastVideoContinuousSubtitle = settings.videoContinuousSubtitle;
      _lastAudioContinuousSubtitle = settings.audioContinuousSubtitle;
      _lastGhostModeEnabled = settings.isGhostModeEnabled;
      settings.addListener(_onSettingsChanged);
      _onSettingsChanged();
    });

    // 自动跟随字幕开启时，进入横屏后自动定位
    // 等待转场动画完成 (约300ms)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final settings = Provider.of<SettingsService>(context, listen: false);
      if (settings.autoScrollSubtitles) {
        Future.delayed(const Duration(milliseconds: 400), () {
          if (mounted) {
            _subtitleSidebarKey.currentState?.triggerLocateForAutoFollow();
          }
        });
      }
    });
  }

  Future<void> _requestNotificationPermissionForMediaSession() async {
    final status = await Permission.notification.status;
    debugPrint(
      'VideoPlayerScreen: notification permission status=$status for media session',
    );
    if (status.isGranted || status.isLimited || status.isProvisional) {
      if (MediaPlaybackService().currentItem != null) {
        await SystemMediaSessionService.instance.refreshNow(
          ensureNotificationVisible: true,
        );
      }
      return;
    }
    if (status.isDenied) {
      final result = await Permission.notification.request();
      debugPrint(
        'VideoPlayerScreen: notification permission request result=$result',
      );
      if (result.isGranted || result.isLimited || result.isProvisional) {
        await SystemMediaSessionService.instance.refreshNow(
          ensureNotificationVisible: true,
        );
      }
      return;
    }
    if (status.isPermanentlyDenied) {
      debugPrint(
        'VideoPlayerScreen: notification permission permanently denied, Android media notification may be suppressed',
      );
    }
  }

  void _onSettingsChanged() {
    final settings = _settingsService;
    if (settings == null) return;

    final bool showSubtitlesBecameTrue =
        (_lastShowSubtitles == false || _lastShowSubtitles == null) &&
        settings.showSubtitles;

    final bool changed =
        _lastShowSubtitles != settings.showSubtitles ||
        _lastSubtitleOffset != settings.subtitleOffset ||
        _lastSplitSubtitleByLine != settings.splitSubtitleByLine ||
        _lastVideoContinuousSubtitle != settings.videoContinuousSubtitle ||
        _lastAudioContinuousSubtitle != settings.audioContinuousSubtitle;

    final bool ghostModeChanged =
        _lastGhostModeEnabled != settings.isGhostModeEnabled;

    if (!changed && !ghostModeChanged) return;

    _lastShowSubtitles = settings.showSubtitles;
    _lastSubtitleOffset = settings.subtitleOffset;
    _lastSplitSubtitleByLine = settings.splitSubtitleByLine;
    _lastVideoContinuousSubtitle = settings.videoContinuousSubtitle;
    _lastAudioContinuousSubtitle = settings.audioContinuousSubtitle;
    _lastGhostModeEnabled = settings.isGhostModeEnabled;

    if (ghostModeChanged &&
        (_isSubtitleDragMode ||
            _isGhostDragMode ||
            _isStyleSidebarDragMode ||
            _activeSidebar == SidebarType.subtitlePosition)) {
      final shouldGhost = _canUseGhostSidebarEditing(context, settings);
      setState(() {
        _isGhostDragMode = shouldGhost;
        _isSubtitleDragMode = !shouldGhost;
        _isSubtitleSnappedX = false;
        _isSubtitleSnappedY = false;
        _isSubtitleNearCenterX = false;
        _isSubtitleNearCenterY = false;
      });
    }

    if (_initialized) {
      _updateSubtitle();
    }

    if (showSubtitlesBecameTrue) {
      unawaited(_maybeLoadSubtitlesForCurrentItem(force: true));
    }
  }

  void _applyItemSubtitlePreference(VideoItem item, {bool force = false}) {
    final settings =
        _settingsService ??
        Provider.of<SettingsService>(context, listen: false);
    if (force || item.showFloatingSubtitles != settings.showSubtitles) {
      item.showFloatingSubtitles = settings.showSubtitles;
    }
  }

  void _setFloatingSubtitles(bool value) {
    final settings =
        _settingsService ??
        Provider.of<SettingsService>(context, listen: false);
    settings.saveShowSubtitles(value);
    final currentItem = _currentItem;
    if (currentItem != null) {
      currentItem.showFloatingSubtitles = value;
    }
  }

  Future<void> _updateCurrentVideoDisplayTransform({
    bool? isMirroredH,
    bool? isMirroredV,
  }) async {
    final currentItem = _currentItem;
    final bool nextMirroredH =
        isMirroredH ?? currentItem?.isVideoMirroredH ?? _fallbackVideoMirroredH;
    final bool nextMirroredV =
        isMirroredV ?? currentItem?.isVideoMirroredV ?? _fallbackVideoMirroredV;

    setState(() {
      if (currentItem != null) {
        currentItem.isVideoMirroredH = nextMirroredH;
        currentItem.isVideoMirroredV = nextMirroredV;
      } else {
        _fallbackVideoMirroredH = nextMirroredH;
        _fallbackVideoMirroredV = nextMirroredV;
      }
    });

    if (currentItem == null) {
      return;
    }

    final library = Provider.of<LibraryService>(context, listen: false);
    await library.updateVideoDisplayTransform(
      currentItem.id,
      isMirroredH: nextMirroredH,
      isMirroredV: nextMirroredV,
    );
  }

  bool _shouldLoadSubtitlesNow(SettingsService settings) {
    if (settings.showSubtitles) return true;
    if (_userRequestedSubtitles) return true;
    return false;
  }

  String? _resolveFirstAssociatedSubtitlePath(VideoItem item) {
    final associated = item.downloadAssociatedSubtitles;
    if (associated.isEmpty) return null;
    for (final path in associated.values) {
      if (path.isEmpty) continue;
      final normalized = p.normalize(path);
      if (File(normalized).existsSync()) {
        return normalized;
      }
    }
    return null;
  }

  Future<void> _persistPrimarySubtitlePathIfNeeded(
    String subtitlePath, {
    String? secondarySubtitlePath,
  }) async {
    final currentItem = _currentItem;
    if (currentItem == null) return;
    final normalizedPrimary = p.normalize(subtitlePath);
    final currentPrimary = currentItem.subtitlePath == null
        ? null
        : p.normalize(currentItem.subtitlePath!);
    if (currentPrimary == normalizedPrimary) return;
    try {
      final settings = Provider.of<SettingsService>(context, listen: false);
      final library = Provider.of<LibraryService>(context, listen: false);
      await library.updateVideoSubtitles(
        currentItem.id,
        normalizedPrimary,
        settings.autoCacheSubtitles,
        secondarySubtitlePath: secondarySubtitlePath,
        isSecondaryCached: settings.autoCacheSubtitles,
      );
      if (mounted) {
        final updated = library.getVideo(currentItem.id);
        if (updated != null) {
          setState(() {
            _currentItem = updated;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _maybeLoadSubtitlesForCurrentItem({bool force = false}) async {
    if (!mounted) return;
    final currentItem = _currentItem;
    if (currentItem == null) return;
    final settings =
        _settingsService ??
        Provider.of<SettingsService>(context, listen: false);
    if (_isParsingSubtitles && !force) return;
    if (_currentSubtitlePaths.isNotEmpty) return;

    if (currentItem.subtitlePath != null) {
      final List<String> paths = <String>[currentItem.subtitlePath!];
      if (currentItem.secondarySubtitlePath != null) {
        paths.add(currentItem.secondarySubtitlePath!);
      }
      await _loadSubtitles(paths, autoEnableSubtitles: true);
      return;
    }
    final associatedPath = _resolveFirstAssociatedSubtitlePath(currentItem);
    if (!force &&
        !currentItem.blockAutoAssociatedSubtitleSelection &&
        associatedPath != null) {
      await _persistPrimarySubtitlePathIfNeeded(
        associatedPath,
        secondarySubtitlePath: currentItem.secondarySubtitlePath,
      );
      if (!mounted) return;
      final refreshedItem = _currentItem ?? currentItem;
      final primaryPath = refreshedItem.subtitlePath ?? associatedPath;
      final List<String> paths = <String>[primaryPath];
      final secondaryPath = refreshedItem.secondarySubtitlePath;
      if (secondaryPath != null &&
          secondaryPath.isNotEmpty &&
          secondaryPath != primaryPath) {
        paths.add(secondaryPath);
      }
      await _loadSubtitles(paths, autoEnableSubtitles: true);
      return;
    }
    if (!force && !_shouldLoadSubtitlesNow(settings)) return;
    _maybeAutoLoadEmbeddedSubtitle();
  }

  void _triggerSubtitleRefreshBurst() {
    final int token = ++_subtitleRefreshToken;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && token == _subtitleRefreshToken) {
        _updateSubtitle();
      }
    });
    Future.delayed(const Duration(milliseconds: 250), () {
      if (mounted &&
          token == _subtitleRefreshToken &&
          _initialized &&
          _currentSubtitleText.isEmpty &&
          _currentSecondaryText == null) {
        _updateSubtitle();
      }
    });
  }

  void _scheduleDeferredPostInitWork(VideoItem? item) {
    if (item == null) return;
    final int token = ++_postInitWorkToken;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || token != _postInitWorkToken) return;
      _checkAndLoadAiSubtitle(item);
      unawaited(_maybeLoadSubtitlesForCurrentItem());
    });
  }

  void _bindControllerListener() {
    try {
      _controller.removeListener(_videoListener);
    } catch (_) {}
    _controller.addListener(_videoListener);
  }

  void _showMissingSource(VideoItem item) {
    if (_isSourceMissing && _controllerAssigned) {
      return;
    }

    VideoPlayerController? previousController;
    final bool disposePrevious = _controllerAssigned && _isControllerOwner;
    if (_controllerAssigned) {
      previousController = _controller;
      try {
        previousController.removeListener(_videoListener);
      } catch (_) {}
    }

    _controller = VideoPlayerController.file(
      File(item.path),
      videoPlayerOptions: MediaPlaybackService.buildVideoPlayerOptions(
        settings: _settingsService ?? SettingsService(),
      ),
    );
    _controllerAssigned = true;
    _isControllerOwner = true;
    _bindControllerListener();

    if (disposePrevious && previousController != null) {
      unawaited(previousController.dispose());
    }

    if (!mounted) return;
    setState(() {
      _currentItem = item;
      _isAudio = item.type == MediaType.audio;
      _isSourceMissing = true;
      _initialized = false;
      _isPlaying = false;
      _fatalErrorMessage = null;
    });
  }

  void _onPlaybackServiceChange() {
    if (!mounted) return;
    final service = Provider.of<MediaPlaybackService>(context, listen: false);

    // Debug Log
    debugPrint(
      "VideoPlayerScreen: _onPlaybackServiceChange. Service Item: ${service.currentItem?.title}, State: ${service.state}",
    );

    if (service.currentItem?.id == _currentItem?.id &&
        service.isSourceMissing) {
      _showMissingSource(service.currentItem!);
      _syncSubtitlesFromService(service);
      return;
    }
    if (service.currentItem?.id == _currentItem?.id &&
        service.state == PlaybackState.loading &&
        _isSourceMissing) {
      setState(() => _isSourceMissing = false);
    }

    if (service.currentItem?.id == _currentItem?.id &&
        service.state == PlaybackState.error &&
        _fatalErrorMessage == null) {
      _setFatalError("媒体加载失败");
      return;
    }

    // 如果服务中的 currentItem 发生变化，且不是当前播放的项
    if (service.currentItem != null &&
        (_currentItem == null || service.currentItem!.id != _currentItem!.id)) {
      debugPrint(
        "VideoPlayerScreen: Detected video change. New: ${service.currentItem!.title}",
      );

      // 先移除旧控制器的监听器，防止状态冲突
      VideoPlayerController? ownedControllerToDispose;
      if (_controllerAssigned) {
        try {
          _controller.removeListener(_videoListener);
        } catch (_) {}
        if (_isControllerOwner) {
          ownedControllerToDispose = _controller;
        }
      }

      setState(() {
        _currentItem = service.currentItem;
        _isSourceMissing = false;
        _initialized = false;
        _isPlaying = false; // Reset play state until init
        _fatalErrorMessage = null;
        _subtitles = [];
        _secondarySubtitles = [];
        _currentSubtitlePaths = [];
        _currentSubtitleText = "";
        _currentSecondaryText = null;
        _currentSubtitleImage = null;
        _currentSubtitleIndex = -1;
        _currentSecondarySubtitleIndex = -1;
        _currentSubtitleIndices = [];
        _currentSecondarySubtitleIndices = [];
        _currentSubtitleEntries = [];
        _currentSubtitleImages.clear();
        subtitleDisplayNotifier.value = SubtitleDisplayState.empty;
        _autoEmbeddedAttemptedForItemId = null;
        _suppressAutoEmbeddedForCurrentItem = false;
        _isParsingSubtitles = false;
        _embeddedSubtitleDetected = false;
        _userRequestedSubtitles = false;
        _rebuildSubtitleIndex();
        // 重置控制器相关状态，让 _initVideo 重新设置
        _controllerAssigned = false;
        _isControllerOwner = false;
      });

      if (ownedControllerToDispose != null) {
        unawaited(ownedControllerToDispose.dispose());
      }

      _applyItemSubtitlePreference(service.currentItem!, force: true);

      // 直接调用 _initVideo 来处理控制器的初始化和同步
      // 避免在这里直接设置 _controller，让 _initVideo 统一处理
      _initVideo();
    } else if (service.currentItem?.id == _currentItem?.id &&
        service.state != PlaybackState.loading &&
        service.controller != null &&
        (!_initialized ||
            !_controllerAssigned ||
            !identical(_controller, service.controller))) {
      debugPrint(
        "VideoPlayerScreen: Service ready for current video. Re-initializing.",
      );
      if (_controllerAssigned && !identical(_controller, service.controller)) {
        final previousController = _controller;
        final shouldDisposePrevious = _isControllerOwner;
        try {
          previousController.removeListener(_videoListener);
        } catch (_) {}
        setState(() {
          _controllerAssigned = false;
          _isControllerOwner = false;
          _initialized = false;
        });
        if (shouldDisposePrevious) {
          unawaited(previousController.dispose());
        }
      }
      // ID 没变，但之前因为 Loading 等待了，现在 Service 准备好了 -> 重试初始化
      _initVideo();
    } else if (service.currentItem?.id == _currentItem?.id) {
      _syncSubtitlesFromService(service);
    }
  }

  /// Sync subtitle state from [MediaPlaybackService] to local state if the
  /// service's subtitle data differs from the local copy. This is called both
  /// from [_onPlaybackServiceChange] (for live updates) and from the post-frame
  /// callback in [initState] (to catch any subtitle changes that occurred
  /// between [_initVideo] and listener registration — e.g. when the portrait
  /// page finishes loading subtitles after the landscape page is already
  /// created but before the listener is registered).
  void _syncSubtitlesFromService(MediaPlaybackService service) {
    if (!mounted) return;
    if (service.currentItem?.id != _currentItem?.id) return;

    if (_subtitleRevision == service.subtitleRevision) return;

    setState(() {
      _subtitleRevision = service.subtitleRevision;
      _subtitles = List<SubtitleItem>.from(service.subtitles);
      _secondarySubtitles = List<SubtitleItem>.from(service.secondarySubtitles);
      _currentSubtitlePaths = List<String>.from(service.subtitlePaths);
      _currentSubtitleText = "";
      _currentSecondaryText = null;
      _currentSubtitleImage = null;
      _currentSubtitleIndex = -1;
      _currentSecondarySubtitleIndex = -1;
      _currentSubtitleIndices = [];
      _currentSecondarySubtitleIndices = [];
      _currentSubtitleEntries = [];
      _currentSubtitleImages.clear();
      subtitleDisplayNotifier.value = SubtitleDisplayState.empty;
    });
    _rebuildSubtitleIndex();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateSubtitle();
    });
  }

  void _setFatalError(String message) {
    if (!mounted) return;
    setState(() {
      _fatalErrorMessage = message;
      _initialized = false;
      _isPlaying = false;
    });
  }

  void _maybeAutoLoadEmbeddedSubtitle() {
    final currentId = _currentItem?.id ?? widget.videoFile?.path;
    if (currentId == null) return;
    if (_currentItem?.blockAutoAssociatedSubtitleSelection ?? false) return;
    if (_currentItem?.prefersManagedAssociatedSubtitles ?? false) return;
    if (_currentItem?.hasAttemptedAutoEmbeddedSubtitleLoad ?? false) return;
    if (_suppressAutoEmbeddedForCurrentItem) return;
    if (_autoEmbeddedAttemptedForItemId == currentId) return;
    if (_currentItem?.subtitlePath != null) return;
    if (_currentSubtitlePaths.isNotEmpty) return;
    if (_subtitles.isNotEmpty || _secondarySubtitles.isNotEmpty) return;
    try {
      final service = Provider.of<MediaPlaybackService>(context, listen: false);
      if (service.subtitlePaths.isNotEmpty ||
          service.subtitles.isNotEmpty ||
          service.secondarySubtitles.isNotEmpty) {
        return;
      }
    } catch (_) {}

    final currentItem = _currentItem;
    if (currentItem != null) {
      currentItem.hasAttemptedAutoEmbeddedSubtitleLoad = true;
      _persistAutoEmbeddedAttemptedFlag(currentItem.id);
    }
    _autoEmbeddedAttemptedForItemId = currentId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _checkAndLoadEmbeddedSubtitle(showLoadingIndicator: false);
    });
  }

  Future<void> _persistAutoEmbeddedAttemptedFlag(String videoId) async {
    try {
      final library = Provider.of<LibraryService>(context, listen: false);
      await library.markAutoEmbeddedSubtitleLoadAttempted(videoId);
      if (!mounted) return;
      final refreshed = library.getVideo(videoId);
      if (refreshed != null) {
        setState(() {
          _currentItem = refreshed;
        });
      }
    } catch (_) {}
  }

  Future<void> _handleExit() async {
    try {
      final settings = Provider.of<SettingsService>(context, listen: false);
      final playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      await settings.saveLandscapeSubtitleSidebarVisible(
        _isSubtitleSidebarVisible,
      );
      if (!_controllerAssigned) return;

      final shouldSkipAutoPause = widget.skipAutoPauseOnExit && !_forceExit;
      if (!PlaybackNavigationService.instance.suppressAutoPauseOnRouteCleanup &&
          !shouldSkipAutoPause &&
          settings.autoPauseOnExit &&
          _controller.value.isPlaying) {
        if (playbackService.controller == _controller) {
          await playbackService.pause();
        } else {
          await _controller.pause();
        }
      }

      // Force sync state
      if (!_isControllerOwner) {
        playbackService.updatePlaybackStateFromController();
      }
    } catch (e) {
      debugPrint("Exit sync error: $e");
    }
  }

  @override
  void dispose() {
    if (_isLongPressing) {
      _isLongPressing = false;
      _videoGestureSession.endLongPress();
      final playbackService = _longPressPlaybackService;
      _longPressPlaybackService = null;
      if (playbackService != null) {
        unawaited(playbackService.endTemporaryPlaybackSpeed());
      }
    }
    FocusManager.instance.removeEarlyKeyEventHandler(
      _handlePlaybackEarlyKeyEvent,
    );
    // Try to sync one last time (fire and forget)
    _handleExit();

    _transcriptionManager?.removeListener(_onTranscriptionUpdate);
    _ocrSubtitleManager?.removeListener(_onOcrSubtitleUpdate);
    _settingsService?.removeListener(_onSettingsChanged);
    if (widget.existingController == null) {
      SystemChrome.setPreferredOrientations([]);
    }
    _restoreSystemUIMode();

    _selectionFocusNode.dispose();
    _videoFocusNode.dispose();
    _playbackPageFocusNode.dispose();
    subtitleDisplayNotifier.dispose();
    _playbackControlsVisibility.dispose();
    _videoComposePreviewController.dispose();
    _subtitleSeekTimer?.cancel();
    _videoTransformAnimationController.dispose();
    _keyboardInsetBottom.dispose();
    WidgetsBinding.instance.removeObserver(this);

    if (_controllerAssigned) {
      try {
        _controller.removeListener(_videoListener);
      } catch (_) {}
      if (_isControllerOwner) {
        // 告诉 Service 清理对该控制器的引用，防止持有已销毁的控制器
        try {
          final playbackService = Provider.of<MediaPlaybackService>(
            context,
            listen: false,
          );
          if (playbackService.controller == _controller) {
            playbackService.clearController();
          }
          // 恢复自动播放下一集的默认设置
          playbackService.autoPlayNextEnabled = true;
        } catch (e) {
          debugPrint("Error clearing controller from service: $e");
        }
        try {
          _controller.dispose();
        } catch (_) {}
      }
    }

    super.dispose();
  }

  KeyEventResult _handlePlaybackEarlyKeyEvent(KeyEvent event) {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) {
      return KeyEventResult.ignored;
    }
    final BuildContext? focusContext =
        FocusManager.instance.primaryFocus?.context;
    final bool isEditingText =
        focusContext?.widget is EditableText ||
        focusContext?.findAncestorWidgetOfExactType<EditableText>() != null;
    if (isEditingText) return KeyEventResult.ignored;
    return _controlsKey.currentState?.handleKeyEvent(
          _playbackPageFocusNode,
          event,
        ) ??
        KeyEventResult.ignored;
  }

  void _enterImmersiveMode() {
    if (kIsWeb) return;
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  void _restoreSystemUIMode() {
    if (kIsWeb) return;
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarDividerColor: Colors.transparent,
          systemNavigationBarIconBrightness: Brightness.light,
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
        ),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // A platform interruption may consume pointer-up events. Explicitly
      // release both gesture ownership and temporary speed so neither can be
      // left stuck when the app resumes.
      if (_isLongPressing) {
        _endLongPressSpeed();
      }
      _videoGestureSession.reset();
      _activeVideoTransformPointers.clear();
      if (_isVideoTransformGestureActive && mounted) {
        setState(() {
          _isVideoTransformGestureActive = false;
        });
      }
      _saveProgress();
    } else if (state == AppLifecycleState.resumed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
        final BuildContext? focusContext =
            FocusManager.instance.primaryFocus?.context;
        final bool isEditingText =
            focusContext?.widget is EditableText ||
            focusContext?.findAncestorWidgetOfExactType<EditableText>() != null;
        if (!isEditingText && _videoFocusNode.canRequestFocus) {
          _videoFocusNode.requestFocus();
        }
      });
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    final double nextInset = _readBottomViewInset();
    final bool nextLandscapeReady =
        kIsWeb ||
        !(Platform.isAndroid || Platform.isIOS) ||
        _isCurrentPhysicalLandscape();
    final bool insetChanged =
        (_keyboardInsetBottom.value - nextInset).abs() >= 0.5;
    final bool landscapeReadyChanged =
        _isLandscapeViewportReady != nextLandscapeReady;

    if (!insetChanged && !landscapeReadyChanged) {
      return;
    }

    if (insetChanged) {
      _keyboardInsetBottom.value = nextInset;
    }
    if (landscapeReadyChanged && mounted) {
      setState(() {
        _isLandscapeViewportReady = nextLandscapeReady;
      });
    }
  }

  double _readBottomViewInset() {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    return view.viewInsets.bottom / view.devicePixelRatio;
  }

  bool get _shouldUseSmoothVideoKeyboardAvoidance =>
      !kIsWeb &&
      (Platform.isAndroid || Platform.isIOS) &&
      _activeSidebar == SidebarType.subtitleEditor;

  double _resolveVideoKeyboardShift(double keyboardInsetBottom) {
    if (!_shouldUseSmoothVideoKeyboardAvoidance || keyboardInsetBottom <= 0) {
      return 0;
    }
    // Keep the original "上移避让" feel while avoiding Scaffold-driven relayout.
    return -(keyboardInsetBottom / 2);
  }

  @override
  void deactivate() {
    _saveProgress();
    super.deactivate();
  }

  Future<void> _saveProgress() async {
    if (!_initialized || _currentItem == null) return;
    if (!_controller.value.isInitialized) return;
    final position = _controller.value.position.inMilliseconds;
    await Provider.of<LibraryService>(
      context,
      listen: false,
    ).updateVideoProgress(_currentItem!.id, position);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Listen to TranscriptionManager
    final manager = Provider.of<TranscriptionManager>(context, listen: false);
    if (_transcriptionManager != manager) {
      _transcriptionManager?.removeListener(_onTranscriptionUpdate);
      _transcriptionManager = manager;
      _transcriptionManager?.addListener(_onTranscriptionUpdate);

      // Check immediately in case it completed while we were away
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _onTranscriptionUpdate();
      });
    }

    final ocrManager = Provider.of<OcrSubtitleManager>(context, listen: false);
    if (_ocrSubtitleManager != ocrManager) {
      _ocrSubtitleManager?.removeListener(_onOcrSubtitleUpdate);
      _ocrSubtitleManager = ocrManager;
      _ocrSubtitleManager?.addListener(_onOcrSubtitleUpdate);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _onOcrSubtitleUpdate();
      });
    }
  }

  void _onOcrSubtitleUpdate() {
    if (!mounted || _ocrSubtitleManager == null) return;
    final job = _ocrSubtitleManager!.job;
    if (job?.status != OcrSubtitleJobStatus.completed) return;
    final paths = _ocrSubtitleManager!.consumeCompletedPaths(job!.videoId);
    if (paths == null || paths.isEmpty) return;
    if (_currentItem?.id == job.videoId) {
      unawaited(_applyCompletedOcrSubtitles(paths));
    } else {
      AppToast.show('OCR 字幕已生成并保存到字幕管理', type: AppToastType.success);
    }
  }

  void _onTranscriptionUpdate() {
    if (!mounted || _transcriptionManager == null) return;

    final currentPath = widget.videoFile?.path ?? widget.videoItem?.path;
    if (currentPath == null) return;

    final currentVideoId = _currentItem?.id ?? widget.videoItem?.id;
    final path = _transcriptionManager!.getGeneratedSrtPathForVideo(
      currentPath,
      videoId: currentVideoId,
    );
    if (path != null &&
        _transcriptionManager!.consumeResultNotificationForVideo(
          currentPath,
          videoId: currentVideoId,
        )) {
      // 如果当前字幕已经是这个，就不重复加载
      if (_currentSubtitlePaths.isNotEmpty &&
          _currentSubtitlePaths[0] == path) {
        return;
      }

      // 保留当前已加载的副字幕（如果有）
      List<String> pathsToLoad = [path];
      if (_currentSubtitlePaths.length > 1) {
        pathsToLoad.add(_currentSubtitlePaths[1]);
      }

      _loadSubtitles(pathsToLoad);

      // 不需要在这里保存，TranscriptionManager 已经保存了

      AppToast.show("AI 字幕转录完成并已自动加载", type: AppToastType.success);
    }
  }

  void _checkAndLoadAiSubtitle(VideoItem? currentItem) {
    if (currentItem == null) return;

    final currentPath = currentItem.path;
    if (currentPath.isEmpty) return;

    try {
      final manager = Provider.of<TranscriptionManager>(context, listen: false);

      final srtPath = manager.getGeneratedSrtPathForVideo(
        currentPath,
        videoId: currentItem.id,
      );
      if (srtPath != null) {
        if (File(srtPath).existsSync()) {
          debugPrint("检测到AI字幕已完成，自动加载: $srtPath");

          List<String> pathsToLoad = [srtPath];
          if (currentItem.secondarySubtitlePath != null) {
            pathsToLoad.add(currentItem.secondarySubtitlePath!);
          }

          _loadSubtitles(pathsToLoad);

          // 仅在转录完成后第一次进入该视频时提示一次“AI 字幕已自动加载”，
          // 之后切换/重新进入不再重复弹出。
          if (mounted &&
              manager.consumeResultNotificationForVideo(
                currentPath,
                videoId: currentItem.id,
              )) {
            AppToast.show("AI 字幕已自动加载", type: AppToastType.success);
          }
        }
      }
    } catch (e) {
      debugPrint("检查AI字幕失败: $e");
    }
  }

  // --- Auto Load External Subtitles (Windows) ---
  Future<void> _tryLoadFirstExternalSubtitle() async {
    // 简单的重试机制，因为Windows下文件扫描可能稍有延迟
    int attempts = 0;
    const maxAttempts = 3;

    while (attempts < maxAttempts) {
      if (!mounted) return;
      // 如果用户在重试期间已经手动加载了字幕，则停止
      if (_subtitles.isNotEmpty) return;

      bool found = await _scanAndLoadExternalSubtitle();
      if (found) return;

      attempts++;
      if (attempts < maxAttempts) {
        // 间隔一定时间重试
        await Future.delayed(const Duration(milliseconds: 1500));
      }
    }
  }

  Future<bool> _scanAndLoadExternalSubtitle() async {
    final path = _currentItem?.path ?? widget.videoFile?.path;
    if (path == null) return false;

    try {
      final settings = Provider.of<SettingsService>(context, listen: false);
      final subtitleEntries = await const SubtitleDiscoveryService()
          .scanVideoDirectory(
            videoPath: path,
            rules: SubtitleScanRules(
              prefixMatchMode: settings.desktopSubtitlePrefixMatchMode,
              caseSensitive: settings.desktopSubtitleScanCaseSensitive,
            ),
          );
      if (subtitleEntries.isEmpty) return false;
      final fileToLoad = File(subtitleEntries.first.path);

      // 加载字幕
      if (mounted) {
        debugPrint("Auto loading external subtitle: ${fileToLoad.path}");
        final library = Provider.of<LibraryService>(context, listen: false);
        List<String> pathsToLoad = [fileToLoad.path];
        if (_currentSubtitlePaths.length > 1) {
          pathsToLoad.add(_currentSubtitlePaths[1]);
        }
        await _loadSubtitles(pathsToLoad);

        // 更新媒体库记录（持久化）
        try {
          if (_currentItem != null) {
            final String? currentSecondary = _currentSubtitlePaths.length > 1
                ? _currentSubtitlePaths[1]
                : _currentItem!.secondarySubtitlePath;
            library.updateVideoSubtitles(
              _currentItem!.id,
              fileToLoad.path,
              settings.autoCacheSubtitles,
              secondarySubtitlePath: currentSecondary,
              isSecondaryCached: settings.autoCacheSubtitles,
            );
          }
        } catch (_) {}

        return true;
      }
    } catch (e) {
      debugPrint("Error scanning external subtitles: $e");
    }
    return false;
  }

  // --- Auto Load Embedded Subtitles ---
  Future<void> _checkAndLoadEmbeddedSubtitle({
    bool showLoadingIndicator = true,
  }) async {
    // If we already have subtitles loaded (e.g. from file), don't override
    if (_subtitles.isNotEmpty) return;

    // Prevent multiple concurrent checks
    if (_isLoadingEmbeddedSubtitle) return;

    // Determine video path
    String? path;
    if (_currentItem != null) {
      path = _currentItem!.path;
    } else if (widget.videoFile != null) {
      path = widget.videoFile!.path;
    }

    if (path == null) return;

    // Check embedded
    bool loadingShown = false;
    try {
      _isLoadingEmbeddedSubtitle = true;
      final SettingsService settings = Provider.of<SettingsService>(
        context,
        listen: false,
      );
      final LibraryService library = Provider.of<LibraryService>(
        context,
        listen: false,
      );

      // Show loading indicator if requested
      if (showLoadingIndicator && mounted) {
        loadingShown = true;
        AppToast.showLoading("正在检测内嵌字幕...");
      }

      final service = Provider.of<EmbeddedSubtitleService>(
        context,
        listen: false,
      );
      // Note: getEmbeddedSubtitles is fast (probe only)
      final tracks = await service.getEmbeddedSubtitles(path);

      if (tracks.isNotEmpty && mounted && _subtitles.isEmpty) {
        setState(() {
          _embeddedSubtitleDetected = true;
        });
        final EmbeddedSubtitleTrack track = tracks.firstWhere(
          (t) => !_isImageSubtitleCodec(t.codecName),
          orElse: () => tracks.first,
        );
        if (_isImageSubtitleCodec(track.codecName)) {
          setState(() {
            _embeddedSubtitleDetected = false;
          });
          if (loadingShown) AppToast.dismiss();
          AppToast.show("当前播放器不支持图像字幕，请转换为文本字幕", type: AppToastType.info);
          return;
        }

        final itemId = _currentItem!.id;
        final subDir = await const TaskSubtitleStorageService().taskDirectory(
          itemId,
          create: true,
        );

        // Extract
        final extractedPath = await service.extractSubtitle(
          path,
          track.index,
          subDir.path,
          codecName: track.codecName,
          videoId: itemId,
        );

        if (extractedPath != null) {
          await library.registerManagedSubtitleAsset(
            itemId,
            path: extractedPath,
            kind: ManagedSubtitleAssetKind.embedded,
            displayName: track.title,
          );
        }

        if (extractedPath != null && mounted) {
          // Check again if user loaded something while we were extracting
          if (_subtitles.isNotEmpty) return;

          List<String> pathsToLoad = [extractedPath];
          if (_currentSubtitlePaths.length > 1) {
            pathsToLoad.add(_currentSubtitlePaths[1]);
          }
          await _loadSubtitles(pathsToLoad);
          if (mounted) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _subtitleSidebarKey.currentState?.jumpToFirstSubtitleTop();
            });
          }

          if (_currentItem != null) {
            try {
              final String? currentSecondary = _currentSubtitlePaths.length > 1
                  ? _currentSubtitlePaths[1]
                  : _currentItem!.secondarySubtitlePath;
              await library.updateVideoSubtitles(
                _currentItem!.id,
                extractedPath,
                settings.autoCacheSubtitles,
                secondarySubtitlePath: currentSecondary,
                isSecondaryCached: settings.autoCacheSubtitles,
              );
              final updated = library.getVideo(_currentItem!.id);
              if (updated != null && mounted) {
                setState(() {
                  _currentItem = updated;
                });
              }
            } catch (_) {}
          }

          if (!mounted) return;

          if (loadingShown) AppToast.dismiss();
          final isImage = _isImageSubtitleCodec(track.codecName);
          AppToast.show(
            isImage ? "已加载内嵌图像字幕: ${track.title}" : "已加载内嵌字幕: ${track.title}",
            type: AppToastType.success,
          );
          if (isImage) {
            AppToast.show("图像字幕无法转为文本，将以位图渲染", type: AppToastType.info);
          }
        } else if (mounted && extractedPath == null) {
          // Extraction failed
          if (loadingShown) AppToast.dismiss();
          AppToast.show("内嵌字幕提取失败", type: AppToastType.error);
        }
      } else if (mounted && tracks.isEmpty) {
        // No embedded subtitles found
        if (_embeddedSubtitleDetected) {
          setState(() {
            _embeddedSubtitleDetected = false;
          });
        }
        if (loadingShown) AppToast.dismiss();

        // Windows/Mac端：如果没有内嵌字幕，尝试自动加载本地文件夹中的第一个外挂字幕
        if ((Platform.isWindows || Platform.isMacOS) && _subtitles.isEmpty) {
          _tryLoadFirstExternalSubtitle();
        }
      }
    } catch (e) {
      debugPrint("Auto load embedded subtitle failed: $e");
      if (loadingShown) AppToast.dismiss();
      if (_embeddedSubtitleDetected && mounted) {
        setState(() {
          _embeddedSubtitleDetected = false;
        });
      }
      if (mounted) AppToast.show("内嵌字幕检测失败", type: AppToastType.error);
    } finally {
      _isLoadingEmbeddedSubtitle = false;
    }
  }

  Future<void> _initVideo() async {
    if (_fatalErrorMessage != null && mounted) {
      setState(() {
        _fatalErrorMessage = null;
      });
    }

    // Refresh video item from library to ensure we have latest subtitle settings
    VideoItem? currentItem = _currentItem;
    if (currentItem != null) {
      try {
        final libItem = Provider.of<LibraryService>(
          context,
          listen: false,
        ).getVideo(currentItem.id);
        if (libItem != null && libItem.lastUpdated >= currentItem.lastUpdated) {
          currentItem = libItem;
        }
      } catch (e) {
        debugPrint("Error refreshing video item: $e");
      }
    }

    _currentItem = currentItem;

    if (currentItem != null) {
      _applyItemSubtitlePreference(currentItem, force: true);
    }

    // Check if this is audio
    _isAudio = currentItem?.type == MediaType.audio;

    // 检查是否是从竖屏页传递过来的控制器（首次进入横屏）
    // 这种情况下，视频ID应该与传入的videoItem一致
    bool isInitialEntryFromPortrait =
        widget.existingController != null &&
        widget.videoItem != null &&
        _currentItem?.id == widget.videoItem!.id &&
        !_controllerAssigned &&
        !_initialControllerConsumed;
    if (isInitialEntryFromPortrait) {
      try {
        final playbackService = Provider.of<MediaPlaybackService>(
          context,
          listen: false,
        );
        if (playbackService.controller != widget.existingController) {
          isInitialEntryFromPortrait = false;
        }
      } catch (_) {}
    }

    if (isInitialEntryFromPortrait) {
      _controller = widget.existingController!;
      _controllerAssigned = true;
      _isControllerOwner = false;
      _initialized = true;
      _initialControllerConsumed = true;

      // 从 MediaPlaybackService 获取正确的播放状态，而不是直接从 controller
      // 这样可以确保状态同步（例如用户在快捷播放卡片暂停后进入播放页面）
      try {
        final playbackService = Provider.of<MediaPlaybackService>(
          context,
          listen: false,
        );
        _isPlaying = playbackService.isPlaying;

        // 强制同步 controller 状态与 MediaPlaybackService 一致
        playbackService.updatePlaybackStateFromController();
        if (_isPlaying) {
          if (!_controller.value.isPlaying) playbackService.resume();
        } else {
          if (_controller.value.isPlaying) playbackService.pause();
        }

        final existingSubtitles = playbackService.subtitles;
        final existingSecondary = playbackService.secondarySubtitles;
        final existingPaths = playbackService.subtitlePaths;
        if (existingSubtitles.isNotEmpty ||
            existingSecondary.isNotEmpty ||
            existingPaths.isNotEmpty) {
          setState(() {
            _subtitles = existingSubtitles;
            _secondarySubtitles = existingSecondary;
            _currentSubtitlePaths = List<String>.from(existingPaths);
            _currentSubtitleText = "";
            _currentSecondaryText = null;
            _currentSubtitleImage = null;
            _currentSubtitleIndex = -1;
            _currentSecondarySubtitleIndex = -1;
            _currentSubtitleIndices = [];
            _currentSecondarySubtitleIndices = [];
            _currentSubtitleEntries = [];
            _currentSubtitleImages.clear();
            subtitleDisplayNotifier.value = SubtitleDisplayState.empty;
          });
          _rebuildSubtitleIndex();
        }
      } catch (e) {
        // 如果无法获取 MediaPlaybackService，回退到使用 controller 的状态
        debugPrint("无法获取 MediaPlaybackService 状态: $e");
        _isPlaying = _controller.value.isPlaying;
      }

      _bindControllerListener();
      _triggerSubtitleRefreshBurst();
      _scheduleDeferredPostInitWork(currentItem);
    } else {
      // 尝试从 MediaPlaybackService 获取 controller (适用于视频切换或未传递 controller 的情况)
      bool usedService = false;
      if (currentItem != null) {
        try {
          final playbackService = Provider.of<MediaPlaybackService>(
            context,
            listen: false,
          );

          if (playbackService.currentItem?.id == currentItem.id &&
              playbackService.isSourceMissing) {
            _showMissingSource(currentItem);
            _syncSubtitlesFromService(playbackService);
            return;
          }

          // 如果 Service 正在加载此视频，等待它完成
          if (playbackService.currentItem?.id == currentItem.id &&
              playbackService.state == PlaybackState.loading) {
            debugPrint(
              "VideoPlayerScreen: Waiting for service to load ${currentItem.title}",
            );
            setState(() {
              _initialized = false;
              // Clear old controller if we owned it? No, keep it until new one ready or just show loading.
            });
            return;
          }

          bool canReuseController = false;
          if (playbackService.currentItem?.id == currentItem.id &&
              playbackService.controller != null) {
            try {
              // 测试控制器是否存活
              void noOp() {}
              playbackService.controller!.addListener(noOp);
              playbackService.controller!.removeListener(noOp);
              canReuseController = true;
            } catch (_) {
              playbackService.clearController();
            }
          }

          if (canReuseController) {
            // 如果之前持有本地 controller，先释放
            if (_controllerAssigned && _isControllerOwner) {
              try {
                _controller.removeListener(_videoListener);
                _controller.dispose();
              } catch (e) {
                debugPrint("Error disposing old controller: $e");
              }
            }

            _controller = playbackService.controller!;
            _controllerAssigned = true;
            _isControllerOwner = false;

            if (mounted) {
              setState(() {
                _isSourceMissing = false;
                _initialized = _controller.value.isInitialized;
                _isPlaying = playbackService.isPlaying; // 同时更新播放状态
              });
            }

            usedService = true;

            // Sync state logic
            if (_controller.value.isInitialized) {
              playbackService.updatePlaybackStateFromController();
              if (_isPlaying) {
                if (!_controller.value.isPlaying) playbackService.resume();
              } else {
                if (_controller.value.isPlaying) playbackService.pause();
              }
            }

            final existingSubtitles = playbackService.subtitles;
            final existingSecondarySubtitles =
                playbackService.secondarySubtitles;
            final existingPaths = playbackService.subtitlePaths;
            if (existingSubtitles.isNotEmpty ||
                existingSecondarySubtitles.isNotEmpty ||
                existingPaths.isNotEmpty) {
              setState(() {
                _subtitles = existingSubtitles;
                _secondarySubtitles = existingSecondarySubtitles;
                _currentSubtitlePaths = List<String>.from(existingPaths);
                _currentSubtitleText = "";
                _currentSecondaryText = null;
                _currentSubtitleImage = null;
                _currentSubtitleIndex = -1;
                _currentSecondarySubtitleIndex = -1;
                _currentSubtitleIndices = [];
                _currentSecondarySubtitleIndices = [];
                _currentSubtitleEntries = [];
                _currentSubtitleImages.clear();
                subtitleDisplayNotifier.value = SubtitleDisplayState.empty;
              });
              _rebuildSubtitleIndex();
            }

            _bindControllerListener();
            _triggerSubtitleRefreshBurst();
            _scheduleDeferredPostInitWork(currentItem);
          }
        } catch (e) {
          debugPrint("Check MediaPlaybackService failed: $e");
        }
      }

      if (!usedService && (widget.videoFile != null || currentItem != null)) {
        if (currentItem != null) {
          try {
            final playbackService = Provider.of<MediaPlaybackService>(
              context,
              listen: false,
            );
            if (playbackService.currentItem?.id != currentItem.id ||
                playbackService.controller == null) {
              if (mounted) {
                setState(() {
                  _initialized = false;
                  _isPlaying = false;
                });
              }
              playbackService.play(currentItem);
              return;
            }
          } catch (_) {}
        }

        _isControllerOwner = true;
        String path = widget.videoFile?.path ?? currentItem!.path;
        final file = File(path);
        if (!kIsWeb && !file.existsSync()) {
          if (currentItem != null) {
            _showMissingSource(currentItem);
          } else {
            _setFatalError("媒体文件不存在，可能已被移动或删除");
          }
          return;
        }

        debugPrint("=== Video Player Debug Info ===");
        debugPrint("Platform: ${Platform.operatingSystem}");
        debugPrint("Video path: $path");
        debugPrint("File exists: ${file.existsSync()}");
        int? fileSize;
        try {
          fileSize = file.lengthSync();
        } catch (_) {}
        debugPrint("File size: ${fileSize ?? -1}");
        debugPrint("Is Windows: ${Platform.isWindows}");
        debugPrint("Is Audio: $_isAudio");
        debugPrint("===============================");

        if (kIsWeb) {
          _controller = VideoPlayerController.networkUrl(
            Uri.parse(path),
            videoPlayerOptions: MediaPlaybackService.buildVideoPlayerOptions(),
          );
        } else {
          final library = Provider.of<LibraryService>(context, listen: false);
          final playbackPath = currentItem != null
              ? await library.ensureCompatiblePlaybackFile(currentItem)
              : (await AudioPlaybackCompatibilityService.resolve(
                  file,
                  isAudio: _isAudio,
                )).path;
          final playbackFile = File(playbackPath);
          if (!mounted) return;
          _controller = VideoPlayerController.file(
            playbackFile,
            videoPlayerOptions: MediaPlaybackService.buildVideoPlayerOptions(),
          );
        }
        _controllerAssigned = true;
        _controller
            .initialize()
            .then((_) async {
              if (!mounted) return;
              setState(() {
                _isSourceMissing = false;
                _initialized = true;
              });

              await _applyInitialPlaybackSpeedToController();
              if (!mounted) return;

              // 注册控制器到 MediaPlaybackService，确保通知栏控制生效
              try {
                final playbackService = Provider.of<MediaPlaybackService>(
                  context,
                  listen: false,
                );
                await playbackService.setController(_controller);

                VideoItem itemToSync =
                    currentItem ??
                    VideoItem(
                      id: path,
                      path: path,
                      title: p.basename(path),
                      durationMs: _controller.value.duration.inMilliseconds,
                      lastUpdated: DateTime.now().millisecondsSinceEpoch,
                      type: _isAudio ? MediaType.audio : MediaType.video,
                    );
                await playbackService.updateMetadata(itemToSync);
                await playbackService.resume();
                if (mounted) {
                  setState(() {
                    _isPlaying = true;
                  });
                }
              } catch (e) {
                debugPrint("Failed to register controller with service: $e");
              }

              debugPrint("Video initialized successfully!");
              debugPrint("Duration: ${_controller.value.duration}");
              debugPrint("Size: ${_controller.value.size}");

              _scheduleDeferredPostInitWork(currentItem);
            })
            .catchError((error) {
              debugPrint("Error initializing video: $error");
              debugPrint("Error stack trace: ${StackTrace.current}");
              if (!mounted) return;
              if (currentItem != null && !File(currentItem.path).existsSync()) {
                try {
                  Provider.of<MediaPlaybackService>(
                    context,
                    listen: false,
                  ).markCurrentSourceMissing(expectedItemId: currentItem.id);
                } catch (_) {}
                _showMissingSource(currentItem);
              } else {
                _setFatalError("视频初始化失败");
              }
            });
        _bindControllerListener();
        _triggerSubtitleRefreshBurst();
      }
    }
  }

  void _videoListener() {
    if (!mounted) return;
    if (!_controllerAssigned) return;

    try {
      if (!_initialized && _controller.value.isInitialized) {
        setState(() {
          _initialized = true;
        });
        _triggerSubtitleRefreshBurst();
      }
    } catch (_) {
      return;
    }

    // Check for errors
    if (_controller.value.hasError && !_isRepairing) {
      final errorMsg = _controller.value.errorDescription ?? "";
      final lower = errorMsg.toLowerCase();
      if (_fatalErrorMessage == null &&
          (lower.contains("no such file") ||
              lower.contains("file not found") ||
              lower.contains("cannot open") ||
              lower.contains("filesystemexception"))) {
        final item = _currentItem;
        if (item != null) {
          try {
            Provider.of<MediaPlaybackService>(
              context,
              listen: false,
            ).markCurrentSourceMissing(expectedItemId: item.id);
          } catch (_) {}
          _showMissingSource(item);
        } else {
          _setFatalError("媒体文件已不存在或无法访问");
        }
        return;
      }
      // Specific check for HevcConfig or ExoPlaybackException: Source error
      if (errorMsg.contains("HevcConfig") ||
          errorMsg.contains("Source error") ||
          errorMsg.contains("VideoError")) {
        // Remove listener to prevent loop
        _controller.removeListener(_videoListener);
        _showRepairDialog();
        return;
      }
    }

    final isPlaying = _controller.value.isPlaying;
    if (isPlaying != _isPlaying) {
      setState(() {
        _isPlaying = isPlaying;
      });

      // 始终同步播放状态到 MediaPlaybackService
      // 确保通知栏和快捷控制卡片显示正确的播放/暂停状态
      try {
        final playbackService = Provider.of<MediaPlaybackService>(
          context,
          listen: false,
        );
        // 使用新的同步方法，避免状态检查导致的同步失败
        playbackService.updatePlaybackStateFromController();
      } catch (e) {
        debugPrint("同步播放状态失败: $e");
      }
    }

    // 检测视频播放完成，在末尾暂停而不是自动播放下一集
    if (_controller.value.isInitialized &&
        !_controller.value.isPlaying &&
        _controller.value.position >= _controller.value.duration) {
      // 视频已播放到末尾，暂停播放（不自动播放下一集）
      try {
        final playbackService = Provider.of<MediaPlaybackService>(
          context,
          listen: false,
        );
        // 保存播放进度
        playbackService.updatePlaybackStateFromController();
      } catch (e) {
        debugPrint("保存播放进度失败: $e");
      }
    }

    _updateSubtitle();
  }

  void _showRepairDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text("播放失败"),
        content: const Text(
          "检测到视频格式兼容性问题（HEVC配置错误）。\n是否尝试自动修复（转码为H.264）？\n注意：修复过程可能需要几分钟。",
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pop(context); // Exit player
            },
            child: const Text("退出播放"),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _repairVideo();
            },
            child: const Text("尝试修复"),
          ),
        ],
      ),
    );
  }

  Future<void> _repairVideo() async {
    setState(() {
      _isRepairing = true;
      _repairProgress = 0.0;
    });

    String? path;
    if (_currentItem != null) {
      path = _currentItem!.path;
    } else if (widget.videoFile != null) {
      path = widget.videoFile!.path;
    }

    if (path == null) return;
    final String videoPath = path;

    final file = File(videoPath);
    final dir = file.parent;
    final filename = p.basenameWithoutExtension(videoPath);
    final ext = p.extension(videoPath);
    final outputPath = p.join(dir.path, "${filename}_repaired$ext");

    // Transcode to H.264 (AVC) which is widely supported
    // -preset ultrafast for speed
    // -crf 23 for decent quality
    // -c:a copy to keep audio untouched
    final command =
        "-y -i \"$videoPath\" -c:v libx264 -preset ultrafast -crf 23 -c:a copy \"$outputPath\"";

    debugPrint("Starting repair: $command");

    // Estimate duration for progress calculation (if available)
    int durationMs = 0;
    if (_controller.value.isInitialized) {
      durationMs = _controller.value.duration.inMilliseconds;
    } else if (_currentItem != null && _currentItem!.durationMs > 0) {
      durationMs = _currentItem!.durationMs;
    }

    // Fallback: Use FFprobe if duration is unknown
    if (durationMs == 0) {
      debugPrint("Duration unknown, probing...");
      try {
        final session = await FFprobeKit.getMediaInformation(videoPath);
        final info = session.getMediaInformation();
        if (info != null) {
          final durationStr = info.getDuration();
          if (durationStr != null) {
            final double d = double.tryParse(durationStr) ?? 0.0;
            durationMs = (d * 1000).toInt();
          }
        }
      } catch (e) {
        debugPrint("Probe failed: $e");
      }
    }

    await FFmpegKit.executeAsync(
      command,
      (session) async {
        final returnCode = await session.getReturnCode();

        if (ReturnCode.isSuccess(returnCode)) {
          debugPrint("Repair success!");

          try {
            final originalBackup = p.join(dir.path, "${filename}_backup$ext");
            if (await File(originalBackup).exists()) {
              await File(originalBackup).delete();
            }
            await file.rename(originalBackup);
            await File(outputPath).rename(videoPath);

            // Delete backup if successful rename
            await File(originalBackup).delete();

            if (mounted) {
              AppToast.show("修复成功，正在重新加载...", type: AppToastType.success);
              setState(() => _isRepairing = false);
              // Re-init video
              _controller.dispose();
              _initVideo();
            }
          } catch (e) {
            debugPrint("File op failed: $e");
            if (mounted) {
              setState(() => _isRepairing = false);
              AppToast.show("文件替换失败", type: AppToastType.error);
            }
          }
        } else {
          debugPrint("Repair failed");
          final logs = await session.getAllLogsAsString();
          final logContent = logs ?? "无日志信息";
          debugPrint("FFmpeg logs: $logContent");

          if (mounted) {
            setState(() => _isRepairing = false);
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text("修复失败"),
                content: Text(
                  "转码过程中出错。\n\n日志片段:\n${logContent.length > 500 ? logContent.substring(logContent.length - 500) : logContent}",
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text("关闭"),
                  ),
                ],
              ),
            );
          }
        }
      },
      (log) {},
      (statistics) {
        final time = statistics.getTime(); // time in ms
        if (mounted) {
          setState(() {
            if (durationMs > 0) {
              _repairProgress = (time / durationMs).clamp(0.0, 1.0);
            } else {
              // If duration is still unknown, we can't show percentage,
              // but we can use _repairProgress to store a dummy value or just update UI elsewhere.
              // Let's use negative value to indicate "unknown percentage" or handle in UI.
              // For now, let's just update the timestamp so UI can show something if we change it.
              // But wait, _repairProgress is double.
              // Let's just keep it 0.0 if duration is 0, but maybe update a separate string?
              // Or we can hack it: if duration is 0, _repairProgress = time / 60000.0 (just to show movement?) - No, that's confusing.

              // Better: Store the raw time string?
              // Let's modify the UI to show raw time if progress is 0.0 and we have time.
              // But I only have _repairProgress state.

              // Let's just ensure durationMs is found.
              // If FFprobe fails, durationMs is 0.
              // Then _repairProgress stays 0.0.
            }
          });
        }
      },
    );
  }

  void _updateSubtitle() {
    if (!_initialized) return;
    final settings = Provider.of<SettingsService>(context, listen: false);
    if (_videoComposePreviewActive) {
      _videoComposePreviewController.update(_controller.value.position);
    }

    if (!settings.showSubtitles) {
      if (_currentSubtitleText.isNotEmpty ||
          _currentSecondaryText != null ||
          _currentSubtitleImage != null ||
          _currentSubtitleIndex != -1 ||
          _currentSecondarySubtitleIndex != -1 ||
          _currentSubtitleEntries.isNotEmpty) {
        _currentSubtitleText = "";
        _currentSecondaryText = null;
        _currentSubtitleImage = null;
        _currentSubtitleIndex = -1;
        _currentSecondarySubtitleIndex = -1;
        _currentSubtitleIndices = [];
        _currentSecondarySubtitleIndices = [];
        _currentSubtitleEntries = [];
        _currentSubtitleImages.clear();
        subtitleDisplayNotifier.value = SubtitleDisplayState.empty;
      }
      return;
    }

    final position = _controller.value.position;
    final adjustedPosition = position - settings.subtitleOffset;
    final int posMs = adjustedPosition.inMilliseconds;
    final continuousSubtitleEnabled = _isAudio
        ? settings.audioContinuousSubtitle
        : settings.videoContinuousSubtitle;

    if (_subtitleTimeline.length != _subtitles.length ||
        _secondarySubtitleTimeline.length != _secondarySubtitles.length) {
      _rebuildSubtitleIndex();
    }

    final List<int> primaryIndices = _subtitles.isEmpty
        ? <int>[]
        : _subtitleTimeline.activeIndicesAtMs(
            posMs,
            extendToNextStart: continuousSubtitleEnabled,
          );

    final List<int> secondaryIndices = _secondarySubtitles.isEmpty
        ? <int>[]
        : _secondarySubtitleTimeline.activeIndicesAtMs(
            posMs,
            extendToNextStart: continuousSubtitleEnabled,
          );

    final List<SubtitleItem> secondaryOverlapItems = secondaryIndices
        .map((i) => _secondarySubtitles[i])
        .toList();
    final List<SubtitleOverlayEntry> entries = <SubtitleOverlayEntry>[];

    if (primaryIndices.isNotEmpty) {
      for (final int index in primaryIndices) {
        final SubtitleItem item = _subtitles[index];
        String text = item.text;
        String? secondaryText;
        final Uint8List? image = _currentSubtitleImages[index];

        if (_secondarySubtitles.isEmpty && settings.splitSubtitleByLine) {
          if (text.contains('\n')) {
            final lines = text.split('\n');
            text = lines[0];
            secondaryText = lines.sublist(1).join('\n');
          }
        } else if (secondaryOverlapItems.isNotEmpty) {
          SubtitleItem? best;
          int bestDelta = 1 << 30;
          for (final sec in secondaryOverlapItems) {
            final int delta =
                (sec.startTime.inMilliseconds - item.startTime.inMilliseconds)
                    .abs();
            if (delta < bestDelta) {
              bestDelta = delta;
              best = sec;
            }
          }
          secondaryText = best?.text;
        }

        final bool hasImage = item.imageLoader != null;
        if (hasImage) {
          text = "";
          secondaryText = null;
        }

        entries.add(
          SubtitleOverlayEntry(
            index: index,
            text: text,
            secondaryText: secondaryText,
            image: image,
          ),
        );
      }
    } else if (secondaryIndices.isNotEmpty) {
      for (final int index in secondaryIndices) {
        final SubtitleItem item = _secondarySubtitles[index];
        entries.add(
          SubtitleOverlayEntry(
            index: null,
            text: "",
            secondaryText: item.text,
            image: null,
          ),
        );
      }
    }

    final int anchorPrimaryIndex = primaryIndices.isNotEmpty
        ? primaryIndices.first
        : -1;
    final int anchorSecondaryIndex = secondaryIndices.isNotEmpty
        ? secondaryIndices.first
        : -1;
    final SubtitleOverlayEntry? anchorEntry = entries.isNotEmpty
        ? entries.first
        : null;
    final bool indicesChanged =
        !listEquals(primaryIndices, _currentSubtitleIndices) ||
        !listEquals(secondaryIndices, _currentSecondarySubtitleIndices);
    final bool entriesChanged = !_areSubtitleEntryListsEqual(
      entries,
      _currentSubtitleEntries,
    );
    final bool anchorChanged =
        anchorPrimaryIndex != _currentSubtitleIndex ||
        anchorSecondaryIndex != _currentSecondarySubtitleIndex;

    if (!indicesChanged && !entriesChanged && !anchorChanged) return;

    _currentSubtitleIndices = primaryIndices;
    _currentSecondarySubtitleIndices = secondaryIndices;
    _currentSubtitleEntries = entries;
    _currentSubtitleIndex = anchorPrimaryIndex;
    _currentSecondarySubtitleIndex = anchorSecondaryIndex;
    _currentSubtitleImage = anchorPrimaryIndex >= 0
        ? _currentSubtitleImages[anchorPrimaryIndex]
        : null;
    _currentSubtitleText = anchorEntry?.text ?? "";
    _currentSecondaryText = anchorEntry?.secondaryText;
    subtitleDisplayNotifier.value = SubtitleDisplayState(entries: entries);

    if (primaryIndices.isNotEmpty) {
      _loadSubtitleImages(primaryIndices);
    }
  }

  void _seekPlaybackPosition(
    Duration target, {
    bool syncSubtitleSidebar = false,
  }) {
    if (!_initialized || !_controller.value.isInitialized) return;
    final duration = _controller.value.duration;
    Duration clamped = target;
    if (clamped < Duration.zero) clamped = Duration.zero;
    if (duration > Duration.zero && clamped > duration) clamped = duration;

    _subtitleSeekTimer?.cancel();
    _subtitleSeekTimer = null;
    if (syncSubtitleSidebar &&
        _activeSidebar == SidebarType.subtitles &&
        _isSubtitleSidebarVisible) {
      _subtitleSidebarKey.currentState?.locateToTime(clamped);
    }
    try {
      final playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      if (playbackService.controller == _controller) {
        playbackService.seekTo(clamped);
      } else {
        _controller.seekTo(clamped);
      }
    } catch (_) {
      _controller.seekTo(clamped);
    }
  }

  void _seekToSubtitleFast(Duration target) {
    _seekPlaybackPosition(target);
  }

  void _togglePlay() async {
    MediaPlaybackService? playbackService;
    try {
      playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
    } catch (_) {}

    if (_isSourceMissing) {
      if (playbackService != null) {
        await playbackService.resume();
      }
      return;
    }

    if (playbackService != null && playbackService.controller == _controller) {
      playbackService.updatePlaybackStateFromController();
      if (_controller.value.isPlaying) {
        await playbackService.pause();
      } else {
        await playbackService.resume();
      }
      return;
    }

    if (_controller.value.isPlaying) {
      await _controller.pause();
    } else {
      await _controller.play();
    }

    if (playbackService != null && playbackService.controller == _controller) {
      playbackService.updatePlaybackStateFromController();
    }
  }

  bool _startLongPressSpeed() {
    if (_isSourceMissing) return false;
    // The raw two-finger transform listener and Flutter's long-press
    // recognizer use different arbitration paths. Resolve that race here:
    // an established multi-touch/transform session owns this pointer sequence,
    // while an established long-press locks transforms for the whole sequence.
    if (!_videoGestureSession.tryStartLongPress(
      transformActive: _isVideoTransformGestureActive,
      transformPointerCount: _activeVideoTransformPointers.length,
    )) {
      return false;
    }

    final settings = Provider.of<SettingsService>(context, listen: false);
    MediaPlaybackService? playbackService;
    try {
      final candidate = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      if (candidate.controller == _controller) playbackService = candidate;
    } catch (_) {}
    _longPressPlaybackService = playbackService;
    _preLongPressSpeed =
        playbackService?.confirmedPlaybackSpeed ??
        _controller.value.playbackSpeed;
    _activeVideoTransformPointers.clear();
    _isVideoTransformGestureActive = false;
    _isLongPressing = true;
    _longPressFeedbackText = "${settings.longPressSpeed}x";
    unawaited(
      playbackService?.beginTemporaryPlaybackSpeed(settings.longPressSpeed) ??
          _controller.setPlaybackSpeed(settings.longPressSpeed),
    );
    return true;
  }

  void _endLongPressSpeed() {
    if (!_isLongPressing) return;
    _videoGestureSession.endLongPress();
    _isLongPressing = false;
    _controlsKey.currentState?.cancelLongPressFeedback();
    final playbackService = _longPressPlaybackService;
    _longPressPlaybackService = null;
    unawaited(
      playbackService?.endTemporaryPlaybackSpeed() ??
          _controller.setPlaybackSpeed(_preLongPressSpeed),
    );
  }

  Future<void> _syncPlaybackSpeedToCurrentController(double speed) async {
    if (_isSourceMissing) return;
    try {
      final playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      if (playbackService.controller == _controller) {
        await playbackService.setPlaybackSpeed(speed);
        return;
      }
    } catch (_) {}
    await _controller.setPlaybackSpeed(speed);
  }

  Future<void> _applyInitialPlaybackSpeedToController() async {
    if (!_controllerAssigned || !_controller.value.isInitialized) return;
    final settings = Provider.of<SettingsService>(context, listen: false);
    final targetSpeed = settings.effectiveGlobalPlaybackSpeed;
    if (settings.isSamePlaybackSpeed(
      _controller.value.playbackSpeed,
      targetSpeed,
    )) {
      return;
    }
    await _syncPlaybackSpeedToCurrentController(targetSpeed);
  }

  Future<void> _handlePlaybackSpeedSelected(double speed) async {
    await _syncPlaybackSpeedToCurrentController(speed);
  }

  Future<void> _handlePlaybackSpeedLockChanged(
    double speed,
    bool locked,
  ) async {
    final settings = Provider.of<SettingsService>(context, listen: false);
    await settings.setPlaybackSpeedLock(speed, locked);
    await _syncPlaybackSpeedToCurrentController(speed);
  }

  Future<void> _pickSubtitle() async {
    try {
      final settings = Provider.of<SettingsService>(context, listen: false);
      final library = Provider.of<LibraryService>(context, listen: false);

      final pickedSubtitle = await pickSubtitleFile(
        allowedExtensions: [
          'srt',
          'lrc',
          'vtt',
          'ass',
          'ssa',
          'sup',
          'sub',
          'idx',
          'scc',
        ],
      );

      if (!mounted) return;

      if (pickedSubtitle != null) {
        final path = pickedSubtitle.path;
        final shouldCacheSubtitle =
            settings.autoCacheSubtitles || pickedSubtitle.requiresPersistence;

        // Auto Cache Logic
        if (_currentItem != null) {
          // Preserve secondary subtitle if it exists
          String? currentSecondary;
          if (_currentSubtitlePaths.length > 1) {
            currentSecondary = _currentSubtitlePaths[1];
          }

          await library.updateVideoSubtitles(
            _currentItem!.id,
            path,
            shouldCacheSubtitle,
            secondarySubtitlePath: currentSecondary,
            isSecondaryCached: settings.autoCacheSubtitles,
          );
        }

        // Load with preservation of secondary
        final storedItem = _currentItem == null
            ? null
            : library.getVideo(_currentItem!.id);
        final pathsToLoad = <String>[storedItem?.subtitlePath ?? path];
        final storedSecondary = storedItem?.secondarySubtitlePath;
        if (storedSecondary != null && storedSecondary.isNotEmpty) {
          pathsToLoad.add(storedSecondary);
        }
        await _loadSubtitles(pathsToLoad);

        if (mounted) {
          AppToast.show(
            "已加载字幕: ${pickedSubtitle.displayName}",
            type: AppToastType.success,
          );
        }
      }
    } catch (e) {
      developer.log('Error picking subtitle', error: e);
    }
  }

  void _showSubtitleManager() {
    setState(() {
      _previousSidebarType = _normalizedSidebarForRestore(_activeSidebar);
      _activeSidebar = SidebarType.subtitleManager;
    });
    _userRequestedSubtitles = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_maybeLoadSubtitlesForCurrentItem(force: true));
    });
  }

  String _subtitlePathKey(String path) {
    final normalized = p.normalize(path);
    if (Platform.isWindows) {
      return normalized.toLowerCase();
    }
    return normalized;
  }

  Future<void> _prepareEmbeddedSubtitlesForCompose() async {
    final item = _currentItem;
    if (item == null || item.path.isEmpty) return;
    try {
      final embeddedService = Provider.of<EmbeddedSubtitleService>(
        context,
        listen: false,
      );
      final library = Provider.of<LibraryService>(context, listen: false);
      final tracks = await embeddedService.getEmbeddedSubtitles(item.path);
      if (tracks.isEmpty) return;
      final subDir = await const TaskSubtitleStorageService().taskDirectory(
        item.id,
        create: true,
      );
      for (final track in tracks) {
        final extractedPath = await embeddedService.extractSubtitle(
          item.path,
          track.index,
          subDir.path,
          codecName: track.codecName,
          videoId: item.id,
        );
        if (extractedPath == null || extractedPath.isEmpty) {
          continue;
        }
        await library.registerManagedSubtitleAsset(
          item.id,
          path: extractedPath,
          kind: ManagedSubtitleAssetKind.embedded,
          displayName: track.title,
        );
      }
    } catch (e) {
      debugPrint('Prepare embedded subtitles for compose failed: $e');
    }
  }

  void _showVideoCompose() async {
    await _prepareEmbeddedSubtitlesForCompose();
    if (!mounted) return;
    setState(() {
      _previousSidebarType = _normalizedSidebarForRestore(_activeSidebar);
      _activeSidebar = SidebarType.videoCompose;
    });
  }

  void _showOcrSubtitle() {
    if (!_supportsOcrSubtitle || _currentItem == null || _isAudio) return;
    setState(() {
      _previousSidebarType = _normalizedSidebarForRestore(_activeSidebar);
      _activeSidebar = SidebarType.ocrSubtitle;
    });
  }

  Future<void> _applyCompletedOcrSubtitles(List<String> paths) async {
    final item = _currentItem;
    if (item == null) return;
    final available = <String>[];
    for (final path in paths) {
      if (await File(path).exists()) available.add(path);
    }
    if (available.isEmpty) return;
    final primary = available.first;
    final secondary = available.length > 1
        ? available[1]
        : (_currentSubtitlePaths.length > 1
              ? _currentSubtitlePaths[1]
              : item.secondarySubtitlePath);
    await _loadSubtitles([primary, ?secondary]);
    if (!mounted || _currentItem?.id != item.id) return;
    final settings = Provider.of<SettingsService>(context, listen: false);
    final library = Provider.of<LibraryService>(context, listen: false);
    await library.updateVideoSubtitles(
      item.id,
      primary,
      settings.autoCacheSubtitles,
      secondarySubtitlePath: secondary,
      isSecondaryCached: settings.autoCacheSubtitles,
    );
    if (mounted) {
      AppToast.show(
        '已生成 ${available.length} 条 OCR 字幕轨，并自动加载前两条',
        type: AppToastType.success,
      );
    }
  }

  void _applyVideoComposePreview(VideoComposePreviewConfig config) {
    if (!mounted) return;
    if (!_videoComposePreviewActive) {
      setState(() => _videoComposePreviewActive = true);
    }
    unawaited(
      _videoComposePreviewController.configure(config).then((_) {
        if (_initialized && _controllerAssigned) {
          _videoComposePreviewController.update(_controller.value.position);
        }
      }),
    );
  }

  void _clearVideoComposePreview() {
    _videoComposePreviewController.clear();
    if (mounted && _videoComposePreviewActive) {
      setState(() => _videoComposePreviewActive = false);
    } else {
      _videoComposePreviewActive = false;
    }
  }

  Future<void> _loadSubtitles(
    List<String> paths, {
    bool autoEnableSubtitles = true,
  }) async {
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );

    final String? itemIdAtStart = _currentItem?.id;

    if (mounted) {
      setState(() {
        _isParsingSubtitles = true;
      });
    } else {
      _isParsingSubtitles = true;
    }

    try {
      if (itemIdAtStart == null) return;
      final bool committed = await playbackService
          .loadSubtitlePathsForCurrentItem(itemId: itemIdAtStart, paths: paths);
      if (!committed || !mounted || _currentItem?.id != itemIdAtStart) {
        return;
      }

      final primaryList = List<SubtitleItem>.from(playbackService.subtitles);
      final secondaryList = List<SubtitleItem>.from(
        playbackService.secondarySubtitles,
      );

      setState(() {
        _subtitleRevision = playbackService.subtitleRevision;
        _suppressAutoEmbeddedForCurrentItem = paths.isEmpty;
        _subtitles = primaryList;
        _secondarySubtitles = secondaryList;
        _currentSubtitlePaths = List<String>.from(
          playbackService.subtitlePaths,
        );
        _currentSubtitleText = "";
        _currentSecondaryText = null;
        _currentSubtitleImage = null;
        _currentSubtitleIndex = -1;
        _currentSecondarySubtitleIndex = -1;
        _currentSubtitleIndices = [];
        _currentSecondarySubtitleIndices = [];
        _currentSubtitleEntries = [];
        _currentSubtitleImages.clear();
        subtitleDisplayNotifier.value = SubtitleDisplayState.empty;
      });
      _rebuildSubtitleIndex();

      if (autoEnableSubtitles &&
          (primaryList.isNotEmpty || secondaryList.isNotEmpty)) {
        final currentItem = _currentItem;
        if (currentItem != null) {
          // Keep the per-item snapshot aligned with the persisted global toggle
          // without overriding the user's current floating subtitle preference.
          _applyItemSubtitlePreference(currentItem, force: true);
        }
      }
      _updateSubtitle();
      _triggerSubtitleRefreshBurst();
    } finally {
      if (!mounted) {
        _isParsingSubtitles = false;
      } else {
        setState(() {
          _isParsingSubtitles = false;
        });
      }
    }
  }

  void _rebuildSubtitleIndex() {
    _subtitleTimeline = SubtitleTimelineResolver(_subtitles);
    _secondarySubtitleTimeline = SubtitleTimelineResolver(_secondarySubtitles);
  }

  void _pruneSubtitleImages(Set<int> keepIndices) {
    if (_currentSubtitleImages.isEmpty) return;
    final keysToRemove = _currentSubtitleImages.keys
        .where((k) => !keepIndices.contains(k))
        .toList();
    for (final key in keysToRemove) {
      _currentSubtitleImages.remove(key);
    }
  }

  bool _areSubtitleEntryListsEqual(
    List<SubtitleOverlayEntry> a,
    List<SubtitleOverlayEntry> b,
  ) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      final entryA = a[i];
      final entryB = b[i];
      if (entryA.index != entryB.index) return false;
      if (entryA.text != entryB.text) return false;
      if (entryA.secondaryText != entryB.secondaryText) return false;
      final bool hasImageA = entryA.image != null;
      final bool hasImageB = entryB.image != null;
      if (hasImageA != hasImageB) return false;
    }
    return true;
  }

  void _loadSubtitleImages(List<int> indices) {
    final Set<int> indexSet = indices.toSet();
    _pruneSubtitleImages(indexSet);
    if (indexSet.isEmpty) return;

    final int requestId = ++_subtitleImageRequestId;
    for (final int index in indexSet) {
      final SubtitleItem item = _subtitles[index];
      final imageLoader = item.imageLoader;
      if (imageLoader == null) continue;
      if (_currentSubtitleImages.containsKey(index)) continue;

      imageLoader().then((image) {
        if (!mounted) return;
        if (requestId != _subtitleImageRequestId) return;
        if (!indexSet.contains(index)) return;

        _currentSubtitleImages[index] = image;
        _currentSubtitleEntries = _currentSubtitleEntries
            .map(
              (entry) => entry.index == index
                  ? SubtitleOverlayEntry(
                      index: entry.index,
                      text: entry.text,
                      secondaryText: entry.secondaryText,
                      image: image,
                    )
                  : entry,
            )
            .toList();
        if (_currentSubtitleIndex == index) {
          _currentSubtitleImage = image;
        }
        subtitleDisplayNotifier.value = SubtitleDisplayState(
          entries: _currentSubtitleEntries,
        );
      });
    }
  }

  // --- Drag Logic ---
  void _enterSubtitleDragMode() {
    setState(() {
      _previousSidebarType = _normalizedSidebarForRestore(_activeSidebar);
      _isSubtitleDragMode = true;
      _isGhostDragMode = false;
      _activeSidebar = SidebarType.subtitlePosition;
      _isSubtitleSnappedX = false;
      _isSubtitleSnappedY = false;
      _isSubtitleNearCenterX = false;
      _isSubtitleNearCenterY = false;
    });
  }

  void _enterGhostDragMode() {
    setState(() {
      _previousSidebarType = _normalizedSidebarForRestore(_activeSidebar);
      _isGhostDragMode = true;
      _isSubtitleDragMode = false;
      _activeSidebar = SidebarType.subtitlePosition;
      _isSubtitleSnappedX = false;
      _isSubtitleSnappedY = false;
      _isSubtitleNearCenterX = false;
      _isSubtitleNearCenterY = false;
    });
  }

  void _exitSubtitleDragMode() {
    setState(() {
      if (_previousSidebarType != SidebarType.none) {
        _activeSidebar = _previousSidebarType;
      } else {
        _activeSidebar = _isSubtitleSidebarVisible
            ? SidebarType.subtitles
            : SidebarType.none;
      }
      _previousSidebarType = SidebarType.none;
      _isSubtitleDragMode = false;
      _isGhostDragMode = false;
      _isSubtitleSnappedX = false;
      _isSubtitleSnappedY = false;
      _isSubtitleNearCenterX = false;
      _isSubtitleNearCenterY = false;
    });
  }

  void _enableStyleSidebarDragMode({required bool isGhost}) {
    setState(() {
      _isStyleSidebarDragMode = true;
      _isSubtitleDragMode = !isGhost;
      _isGhostDragMode = isGhost;
      _isSubtitleSnappedX = false;
      _isSubtitleSnappedY = false;
      _isSubtitleNearCenterX = false;
      _isSubtitleNearCenterY = false;
    });
  }

  bool _subtitleStyleFromCompose = false;

  void _toggleFloatingSubtitleSettingsSidebar({bool fromCompose = false}) {
    final bool isClosing = _activeSidebar == SidebarType.subtitleStyle;
    if (isClosing) {
      setState(() {
        _isStyleSidebarDragMode = false;
        _isSubtitleDragMode = false;
        _isGhostDragMode = false;
        _isSubtitleSnappedX = false;
        _isSubtitleSnappedY = false;
        _isSubtitleNearCenterX = false;
        _isSubtitleNearCenterY = false;
        _subtitleStyleFromCompose = false;
        if (_previousSidebarType != SidebarType.none) {
          _activeSidebar = _previousSidebarType;
        } else {
          _activeSidebar = _isSubtitleSidebarVisible
              ? SidebarType.subtitles
              : SidebarType.none;
        }
        _previousSidebarType = SidebarType.none;
      });
      return;
    }

    setState(() {
      _previousSidebarType = _normalizedSidebarForRestore(_activeSidebar);
      _activeSidebar = SidebarType.subtitleStyle;
      _subtitleStyleFromCompose = fromCompose;
    });

    final settings = Provider.of<SettingsService>(context, listen: false);
    final isGhost = fromCompose
        ? false
        : _canUseGhostSidebarEditing(context, settings);
    if (_initialized) {
      _enableStyleSidebarDragMode(isGhost: isGhost);
    }
  }

  void _updateSubtitlePosition(
    DragUpdateDetails details,
    BoxConstraints constraints, {
    bool isGhost = false,
  }) {
    final settings = Provider.of<SettingsService>(context, listen: false);
    final currentAlign = isGhost
        ? settings.ghostModeAlignment
        : (_isAudio
              ? settings.audioSubtitleAlignment
              : settings.subtitleAlignment);
    final snapResult = resolveSubtitleDragSnap(
      currentAlignment: currentAlign,
      dragDelta: details.delta,
      dragBounds: Size(constraints.maxWidth, constraints.maxHeight),
      wasSnappedX: _isSubtitleSnappedX,
      wasSnappedY: _isSubtitleSnappedY,
    );

    if (isGhost) {
      settings.saveGhostModeAlignment(snapResult.alignment);
    } else {
      if (_isAudio) {
        settings.saveAudioSubtitleAlignment(snapResult.alignment);
      } else {
        settings.saveSubtitleAlignment(snapResult.alignment);
      }
    }

    setState(() {
      _isSubtitleSnappedX = snapResult.snappedX;
      _isSubtitleSnappedY = snapResult.snappedY;
      _isSubtitleNearCenterX = snapResult.guideX;
      _isSubtitleNearCenterY = snapResult.guideY;
    });
  }

  Future<void> _handleBackRequest() async {
    if (_isOrientationTransitioning) return;
    if (_forceExit) {
      await _returnToPortrait();
      return;
    }

    if (_isRepairing) return;

    if ((_isSubtitleDragMode || _isGhostDragMode) && !_isStyleSidebarDragMode) {
      _exitSubtitleDragMode();
      return;
    }

    if (_isSidebarOpen) {
      if (!mounted) return;
      if (_activeSidebar == SidebarType.subtitleStyle) {
        setState(() {
          _isStyleSidebarDragMode = false;
          _isSubtitleDragMode = false;
          _isGhostDragMode = false;
          _isSubtitleSnappedX = false;
          _isSubtitleSnappedY = false;
          _isSubtitleNearCenterX = false;
          _isSubtitleNearCenterY = false;
          if (_subtitleStyleFromCompose) {
            _activeSidebar = SidebarType.videoCompose;
            _subtitleStyleFromCompose = false;
          } else if (_previousSidebarType != SidebarType.none) {
            _activeSidebar = _previousSidebarType;
          } else {
            _activeSidebar = _isSubtitleSidebarVisible
                ? SidebarType.subtitles
                : SidebarType.none;
          }
          _previousSidebarType = SidebarType.none;
        });
        return;
      }
      if (_activeSidebar != SidebarType.subtitles) {
        if (_activeSidebar == SidebarType.videoCompose) {
          _clearVideoComposePreview();
        }
        setState(() {
          if (_previousSidebarType != SidebarType.none) {
            _activeSidebar = _previousSidebarType;
          } else {
            _activeSidebar = _isSubtitleSidebarVisible
                ? SidebarType.subtitles
                : SidebarType.none;
          }
          _previousSidebarType = SidebarType.none;
        });
        return;
      }
    }

    await _returnToPortrait();
  }

  Widget _buildOrientationBridge(SettingsService settings) {
    return ColoredBox(
      color: Colors.black,
      child: IgnorePointer(
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (_isSourceMissing) {
              return const Center(
                child: Text(
                  '没有源媒体',
                  style: TextStyle(color: Colors.white70, fontSize: 20),
                ),
              );
            }
            if (_initialized && _isAudio) {
              return const Center(
                child: Icon(Icons.music_note, size: 80, color: Colors.white24),
              );
            }
            if (!_initialized || !_controllerAssigned) {
              final thumbnailPath = _currentItem?.thumbnailPath;
              if (thumbnailPath != null && File(thumbnailPath).existsSync()) {
                return Image.file(File(thumbnailPath), fit: BoxFit.cover);
              }
              return const SizedBox.expand();
            }

            final viewportSize = Size(
              constraints.maxWidth,
              constraints.maxHeight,
            );
            final aspectRatio = _controller.value.aspectRatio > 0
                ? _controller.value.aspectRatio
                : 16 / 9;
            final videoSize = _computeContainedVideoSize(
              viewportSize,
              aspectRatio,
            );
            return ClipRect(
              child: Center(
                child: Transform(
                  alignment: Alignment.center,
                  transform: _buildVideoTransformMatrix(viewportSize, settings),
                  child: SizedBox(
                    width: videoSize.width,
                    height: videoSize.height,
                    child: VideoPlayer(_controller, key: _videoTextureKey),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _onIosBackSwipeStart(DragStartDetails details) {
    if (!Platform.isIOS) return;
    _iosBackSwipeActive = true;
    _iosBackSwipeDistance = 0.0;
  }

  void _onIosBackSwipeUpdate(DragUpdateDetails details) {
    if (!_iosBackSwipeActive) return;
    _iosBackSwipeDistance += details.delta.dx;
    if (_iosBackSwipeDistance >= _iosBackSwipeTriggerDistance) {
      _iosBackSwipeActive = false;
      _iosBackSwipeDistance = 0.0;
      _handleBackRequest();
    }
  }

  void _onIosBackSwipeEnd(DragEndDetails details) {
    _iosBackSwipeActive = false;
    _iosBackSwipeDistance = 0.0;
  }

  Future<void> _cancelPendingPlaybackIfNeeded() async {
    if (_controllerAssigned || _initialized) {
      return;
    }
    final currentItem = _currentItem;
    if (currentItem == null) {
      return;
    }
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    await playbackService.cancelPendingPlay(expectedItemId: currentItem.id);
  }

  KeyEventResult _handleLoadingKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      unawaited(_handleBackRequest());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _buildLoadingState(BuildContext context) {
    final theme = Theme.of(context);
    final thumbnailPath = _currentItem?.thumbnailPath;
    final bool hasThumbnail =
        thumbnailPath != null && File(thumbnailPath).existsSync();

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_videoFocusNode.canRequestFocus) {
          _videoFocusNode.requestFocus();
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            color: Colors.black,
            child: hasThumbnail
                ? Image.file(
                    File(thumbnailPath),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        const ColoredBox(color: Colors.black),
                  )
                : const ColoredBox(color: Colors.black),
          ),
          // 简单的半透明遮罩，确保加载圈和顶部栏可见
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.4),
            ),
          ),
          Positioned(
            top: 16,
            left: 16,
            child: SafeArea(
              bottom: false,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!kIsWeb &&
                      (Platform.isWindows ||
                          Platform.isMacOS ||
                          Platform.isLinux))
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      tooltip: "退出播放 (Esc)",
                      onPressed: () {
                        _forceExit = true;
                        unawaited(_handleExit());
                      },
                    )
                  else
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      tooltip: "返回",
                      onPressed: () => unawaited(_handleBackRequest()),
                    ),
                  const SizedBox(width: 8),
                  Text(
                    _currentItem?.title ?? "加载中...",
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Center(
            child: SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: Colors.white.withValues(alpha: 0.8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Consume SettingsService
    return Consumer<SettingsService>(
      builder: (context, settings, child) {
        final bool isLeftHandedMode = settings.isLeftHandedMode;
        final Widget sidebarResizer = Container(
          width: _subtitleSidebarResizerLayoutWidth,
          color: _isResizingSidebar ? Colors.blueAccent : Colors.black12,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            child: Center(
              child: VerticalDivider(
                color: Colors.white24,
                width: _subtitleSidebarResizerVisualWidth,
                thickness: _subtitleSidebarResizerVisualWidth,
                indent: 40,
                endIndent: 40,
              ),
            ),
          ),
        );
        // 缓存 sidebarWidth，避免单次 build 调用 3 次 _getSidebarWidth
        final double sidebarWidth = _getSidebarWidth(context, settings);
        // 侧边栏动画面板：RepaintBoundary 隔离重绘，内容保持开启状态以支持淡出效果
        final Widget sidebarPanel = AnimatedContainer(
          duration: _isResizingSidebar
              ? Duration.zero
              : const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          width: _isSidebarOpen ? sidebarWidth : 0,
          child: RepaintBoundary(
            child: ClipRect(
              child: OverflowBox(
                minWidth: sidebarWidth,
                maxWidth: sidebarWidth,
                alignment: isLeftHandedMode
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: AnimatedOpacity(
                  opacity: _isSidebarOpen ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  child: _buildSidebarContent(settings),
                ),
              ),
            ),
          ),
        );
        final bool showResizer =
            _isSidebarOpen &&
            (_activeSidebar == SidebarType.subtitles ||
                _activeSidebar == SidebarType.subtitleEditor);
        final double sidebarResizeOverlayInset =
            (_subtitleSidebarResizerHitWidth -
                _subtitleSidebarResizerLayoutWidth) /
            2;
        final double resizableSidebarWidth = _clampResizableSidebarWidth(
          context,
          _subtitleSidebarWidthOverride ?? settings.userSubtitleSidebarWidth,
        );

        final List<Widget> sidebarWidgets = [
          if (showResizer && isLeftHandedMode) ...[
            sidebarPanel,
            sidebarResizer,
          ] else if (showResizer) ...[
            sidebarResizer,
            sidebarPanel,
          ] else
            sidebarPanel,
        ];
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            _handleBackRequest();
          },
          child: Focus(
            focusNode: _playbackPageFocusNode,
            onKeyEvent: (node, event) =>
                _controlsKey.currentState?.handleKeyEvent(node, event) ??
                KeyEventResult.ignored,
            child: Scaffold(
              key: _scaffoldKey,
              backgroundColor: _isLandscapeViewportReady
                  ? Colors.black
                  : Colors.transparent,
              resizeToAvoidBottomInset: false,
              body: _isOrientationTransitioning
                  ? _buildOrientationBridge(settings)
                  : !_isLandscapeViewportReady
                  ? GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {},
                      child: const SizedBox.expand(),
                    )
                  : SelectableRegion(
                      key: _selectionKey,
                      selectionControls: materialTextSelectionControls,
                      focusNode: _selectionFocusNode,
                      child: GestureDetector(
                        onTap: () {
                          // 点击空白区域取消文字选择，仅清除选择焦点，
                          // 不调用 unfocus() 避免清除视频控制焦点的键盘快捷键
                          _selectionKey.currentState?.clearSelection();
                          _selectionFocusNode.unfocus();
                          // 恢复焦点到视频控制 FocusNode，确保快捷键持续可用
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted && _videoFocusNode.canRequestFocus) {
                              _videoFocusNode.requestFocus();
                            }
                          });
                        },
                        behavior: HitTestBehavior.translucent,
                        child: SafeArea(
                          top: true,
                          bottom: false,
                          left: false,
                          right: false,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Row(
                                children: [
                                  if (isLeftHandedMode) ...sidebarWidgets,
                                  Expanded(
                                    child: ValueListenableBuilder<double>(
                                      valueListenable: _keyboardInsetBottom,
                                      builder:
                                          (
                                            context,
                                            keyboardInsetBottom,
                                            child,
                                          ) {
                                            return Transform.translate(
                                              offset: Offset(
                                                0,
                                                _resolveVideoKeyboardShift(
                                                  keyboardInsetBottom,
                                                ),
                                              ),
                                              child: child,
                                            );
                                          },
                                      child: LayoutBuilder(
                                        builder: (context, screenConstraints) {
                                          final Size playerSurfaceSize = Size(
                                            screenConstraints.maxWidth,
                                            screenConstraints.maxHeight,
                                          );
                                          final Rect videoViewportRect =
                                              Rect.fromLTWH(
                                                0,
                                                0,
                                                playerSurfaceSize.width,
                                                playerSurfaceSize.height,
                                              );
                                          _lastVideoViewportRect =
                                              videoViewportRect;
                                          // Ghost Mode Logic
                                          final isLandscape =
                                              MediaQuery.of(
                                                context,
                                              ).orientation ==
                                              Orientation.landscape;
                                          final canEditGhostStyle =
                                              _canUseGhostSidebarEditing(
                                                context,
                                                settings,
                                              );
                                          final isGhostActive =
                                              canEditGhostStyle &&
                                              !_subtitleStyleFromCompose &&
                                              ((_activeSidebar ==
                                                      SidebarType.subtitles) ||
                                                  _isGhostDragMode ||
                                                  _activeSidebar ==
                                                      SidebarType
                                                          .subtitleStyle);
                                          final SubtitleStyle
                                          activeSubtitleStyle = _isAudio
                                              ? (isLandscape
                                                    ? settings
                                                          .audioSubtitleStyleLandscape
                                                    : settings
                                                          .audioSubtitleStylePortrait)
                                              : (isLandscape
                                                    ? settings
                                                          .subtitleStyleLandscape
                                                    : settings
                                                          .subtitleStylePortrait);
                                          // 守卫：当从 MediaPlaybackService 异步加载视频时，
                                          // _initVideo 会在 service 处于 loading 时提前 return，
                                          // 不给 _controller（late 变量）赋值。此时访问
                                          // _controller.value 会抛 LateInitializationError，
                                          // 在 Release 下 ErrorWidget 渲染为空白 → 白屏。
                                          // 加载期间用 16:9 占位（此时仅渲染 loading 态，不渲染视频）。
                                          final double videoAspectRatio =
                                              (_controllerAssigned &&
                                                  _controller
                                                          .value
                                                          .aspectRatio >
                                                      0)
                                              ? _controller.value.aspectRatio
                                              : 16 / 9;
                                          final Size containedVideoSize =
                                              _computeContainedVideoSize(
                                                playerSurfaceSize,
                                                videoAspectRatio,
                                              );
                                          final PlayerControlMetrics
                                          playbackControlMetrics =
                                              PlayerControlMetrics.fromSize(
                                                playerSurfaceSize,
                                                safeBottom:
                                                    MediaQuery.maybeOf(
                                                      context,
                                                    )?.padding.bottom ??
                                                    0,
                                              );
                                          final double controlsClearance =
                                              subtitlePlaybackControlsClearance(
                                                playerSurfaceSize.height,
                                              );
                                          final double videoViewportTop =
                                              (playerSurfaceSize.height -
                                                  containedVideoSize.height) /
                                              2;
                                          final double videoViewportLeft =
                                              (playerSurfaceSize.width -
                                                  containedVideoSize.width) /
                                              2;
                                          List<Rect>
                                          playerPlaybackControlRects() =>
                                              _playbackControlAvoidanceRects(
                                                context: context,
                                                playerSize: playerSurfaceSize,
                                                metrics: playbackControlMetrics,
                                                clearance: controlsClearance,
                                              );
                                          List<Rect>
                                          videoPlaybackControlRects() =>
                                              playerPlaybackControlRects()
                                                  .map(
                                                    (rect) => rect.translate(
                                                      -videoViewportLeft,
                                                      -videoViewportTop,
                                                    ),
                                                  )
                                                  .toList(growable: false);

                                          return Listener(
                                            behavior:
                                                HitTestBehavior.translucent,
                                            onPointerDown:
                                                _handleVideoTransformPointerDown,
                                            onPointerMove:
                                                _handleVideoTransformPointerMove,
                                            onPointerUp: (event) =>
                                                _handleVideoTransformPointerEnd(
                                                  event.pointer,
                                                ),
                                            onPointerCancel: (event) =>
                                                _handleVideoTransformPointerEnd(
                                                  event.pointer,
                                                ),
                                            child: Stack(
                                              alignment: Alignment.center,
                                              children: [
                                                // 1. Video Layer
                                                Center(
                                                  child: _isSourceMissing
                                                      ? const ColoredBox(
                                                          color: Colors.black,
                                                          child: Center(
                                                            child: Text(
                                                              "没有原媒体",
                                                              style: TextStyle(
                                                                color: Colors
                                                                    .white70,
                                                                fontSize: 20,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w500,
                                                              ),
                                                            ),
                                                          ),
                                                        )
                                                      : _fatalErrorMessage !=
                                                            null
                                                      ? Container(
                                                          color: Colors.black,
                                                          padding:
                                                              const EdgeInsets.all(
                                                                24,
                                                              ),
                                                          child: Center(
                                                            child: ConstrainedBox(
                                                              constraints:
                                                                  const BoxConstraints(
                                                                    maxWidth:
                                                                        520,
                                                                  ),
                                                              child: Column(
                                                                mainAxisSize:
                                                                    MainAxisSize
                                                                        .min,
                                                                children: [
                                                                  const Icon(
                                                                    Icons
                                                                        .error_outline,
                                                                    color: Colors
                                                                        .redAccent,
                                                                    size: 64,
                                                                  ),
                                                                  const SizedBox(
                                                                    height: 16,
                                                                  ),
                                                                  const Text(
                                                                    "无法播放该媒体",
                                                                    style: TextStyle(
                                                                      color: Colors
                                                                          .white,
                                                                      fontSize:
                                                                          18,
                                                                      fontWeight:
                                                                          FontWeight
                                                                              .w600,
                                                                    ),
                                                                  ),
                                                                  const SizedBox(
                                                                    height: 8,
                                                                  ),
                                                                  Text(
                                                                    _fatalErrorMessage!,
                                                                    style: const TextStyle(
                                                                      color: Colors
                                                                          .white70,
                                                                    ),
                                                                    textAlign:
                                                                        TextAlign
                                                                            .center,
                                                                  ),
                                                                  const SizedBox(
                                                                    height: 24,
                                                                  ),
                                                                  ElevatedButton(
                                                                    onPressed: () =>
                                                                        unawaited(
                                                                          _forceExitPlayer(),
                                                                        ),
                                                                    child:
                                                                        const Text(
                                                                          "返回",
                                                                        ),
                                                                  ),
                                                                ],
                                                              ),
                                                            ),
                                                          ),
                                                        )
                                                      : _isRepairing
                                                      ? Column(
                                                          mainAxisAlignment:
                                                              MainAxisAlignment
                                                                  .center,
                                                          children: [
                                                            const CircularProgressIndicator(),
                                                            const SizedBox(
                                                              height: 16,
                                                            ),
                                                            const Text(
                                                              "正在修复视频...",
                                                              style: TextStyle(
                                                                color: Colors
                                                                    .white,
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                              height: 8,
                                                            ),
                                                            Text(
                                                              "进度: ${(_repairProgress * 100).toStringAsFixed(1)}%",
                                                              style: const TextStyle(
                                                                color: Colors
                                                                    .white,
                                                                fontSize: 16,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold,
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                              height: 8,
                                                            ),
                                                            const Text(
                                                              "转码为 H.264 (兼容模式)",
                                                              style: TextStyle(
                                                                color: Colors
                                                                    .white70,
                                                                fontSize: 12,
                                                              ),
                                                            ),
                                                          ],
                                                        )
                                                      : _initialized
                                                      ? RepaintBoundary(
                                                          child: SizedBox.expand(
                                                            child: Stack(
                                                              fit: StackFit
                                                                  .expand,
                                                              children: [
                                                                if (_isAudio)
                                                                  Container(
                                                                    color: Colors
                                                                        .black,
                                                                    child: const Center(
                                                                      child: Icon(
                                                                        Icons
                                                                            .music_note,
                                                                        size:
                                                                            80,
                                                                        color: Colors
                                                                            .white24,
                                                                      ),
                                                                    ),
                                                                  )
                                                                else
                                                                  ClipRect(
                                                                    child: Stack(
                                                                      fit: StackFit
                                                                          .expand,
                                                                      children: [
                                                                        RepaintBoundary(
                                                                          child: Center(
                                                                            child: Transform(
                                                                              alignment: Alignment.center,
                                                                              transform: _buildVideoTransformMatrix(
                                                                                videoViewportRect.size,
                                                                                settings,
                                                                              ),
                                                                              child: SizedBox(
                                                                                width: containedVideoSize.width,
                                                                                height: containedVideoSize.height,
                                                                                child: ColoredBox(
                                                                                  color: Colors.black,
                                                                                  child: VideoPlayer(
                                                                                    _controller,
                                                                                    key: _videoTextureKey,
                                                                                  ),
                                                                                ),
                                                                              ),
                                                                            ),
                                                                          ),
                                                                        ),
                                                                      ],
                                                                    ),
                                                                  ),
                                                                if (!_isAudio)
                                                                  _buildVideoBoundDanmakuOverlay(
                                                                    videoSize:
                                                                        containedVideoSize,
                                                                    playerHeight:
                                                                        playerSurfaceSize
                                                                            .height,
                                                                    settings:
                                                                        settings,
                                                                  ),
                                                              ],
                                                            ),
                                                          ),
                                                        )
                                                      : Focus(
                                                          focusNode:
                                                              _videoFocusNode,
                                                          autofocus: true,
                                                          onKeyEvent:
                                                              (node, event) =>
                                                                  _handleLoadingKeyEvent(
                                                                    event,
                                                                  ),
                                                          child:
                                                              _buildLoadingState(
                                                                context,
                                                              ),
                                                        ),
                                                ),

                                                if (_initialized &&
                                                    _activeSidebar ==
                                                        SidebarType
                                                            .subtitleStyle)
                                                  Positioned.fill(
                                                    child: GestureDetector(
                                                      behavior: HitTestBehavior
                                                          .translucent,
                                                      onDoubleTap: _isLocked
                                                          ? null
                                                          : _togglePlay,
                                                    ),
                                                  ),

                                                // 2. Controls Layer
                                                if ((_initialized ||
                                                        _isSourceMissing) &&
                                                    _controllerAssigned &&
                                                    !_isSubtitleDragMode &&
                                                    !_isGhostDragMode)
                                                  RepaintBoundary(
                                                    child: VideoControlsOverlay(
                                                      key: _controlsKey,
                                                      playbackControlsVisibility:
                                                          _playbackControlsVisibility,
                                                      controller: _controller,
                                                      isLocked: _isLocked,
                                                      onTogglePlay: _togglePlay,
                                                      onBackPressed: () =>
                                                          _handleBackRequest(),
                                                      onSeekTo: (position) {
                                                        _seekPlaybackPosition(
                                                          position,
                                                        );
                                                      },
                                                      onExitPressed: () async {
                                                        await _forceExitPlayer();
                                                      },
                                                      onOpenSettings: () =>
                                                          setState(() {
                                                            _previousSidebarType =
                                                                _normalizedSidebarForRestore(
                                                                  _activeSidebar,
                                                                );
                                                            _activeSidebar =
                                                                SidebarType
                                                                    .settings;
                                                          }),
                                                      onOpenSubtitleManager:
                                                          _showSubtitleManager,
                                                      onOpenSubtitleEditor:
                                                          _showSubtitleEditor,
                                                      showSubtitleEditorButton:
                                                          kIsWeb ||
                                                          !(Platform
                                                                  .isAndroid ||
                                                              Platform.isIOS),
                                                      onOpenVideoCompose:
                                                          _showVideoCompose,
                                                      onOpenOcrSubtitle:
                                                          _supportsOcrSubtitle
                                                          ? _showOcrSubtitle
                                                          : null,
                                                      onToggleFloatingSubtitleSettings:
                                                          _toggleFloatingSubtitleSettingsSidebar,
                                                      onToggleSidebar: () {
                                                        final settings =
                                                            Provider.of<
                                                              SettingsService
                                                            >(
                                                              context,
                                                              listen: false,
                                                            );
                                                        setState(() {
                                                          if (_isSubtitleSidebarVisible) {
                                                            if (_activeSidebar ==
                                                                SidebarType
                                                                    .subtitles) {
                                                              _isSubtitleSidebarVisible =
                                                                  false;
                                                              _activeSidebar =
                                                                  SidebarType
                                                                      .none;
                                                            } else {
                                                              _activeSidebar =
                                                                  SidebarType
                                                                      .subtitles;
                                                            }
                                                          } else {
                                                            _isSubtitleSidebarVisible =
                                                                true;
                                                            _activeSidebar =
                                                                SidebarType
                                                                    .subtitles;
                                                          }
                                                        });
                                                        settings.saveLandscapeSubtitleSidebarVisible(
                                                          _isSubtitleSidebarVisible,
                                                        );
                                                        WidgetsBinding.instance.addPostFrameCallback((
                                                          _,
                                                        ) {
                                                          if (!mounted) {
                                                            return;
                                                          }
                                                          if (_isSubtitleSidebarVisible &&
                                                              _activeSidebar ==
                                                                  SidebarType
                                                                      .subtitles) {
                                                            _userRequestedSubtitles =
                                                                true;
                                                            unawaited(
                                                              _maybeLoadSubtitlesForCurrentItem(
                                                                force: true,
                                                              ),
                                                            );
                                                          }
                                                        });
                                                      },
                                                      isSubtitleSidebarVisible:
                                                          _isSubtitleSidebarVisible,
                                                      onToggleFullScreen: () =>
                                                          settings
                                                              .toggleFullScreen(),
                                                      onToggleLock: () =>
                                                          _setScreenLock(
                                                            !_isLocked,
                                                          ),
                                                      showDanmakuControls:
                                                          _currentItem
                                                              ?.isBilibiliExported ==
                                                          true,
                                                      danmakuEnabled: settings
                                                          .showBilibiliDanmaku,
                                                      onToggleDanmaku: () => unawaited(
                                                        settings.saveShowBilibiliDanmaku(
                                                          !settings
                                                              .showBilibiliDanmaku,
                                                        ),
                                                      ),
                                                      onOpenDanmakuSettings:
                                                          () => unawaited(
                                                            showDanmakuSettingsDialog(
                                                              context,
                                                            ),
                                                          ),
                                                      onSpeedUpdate:
                                                          _handlePlaybackSpeedSelected,
                                                      doubleTapSeekSeconds: settings
                                                          .doubleTapSeekSeconds,
                                                      enableDoubleTapSubtitleSeek:
                                                          settings
                                                              .enableDoubleTapSubtitleSeek,
                                                      subtitles: _subtitles,
                                                      longPressSpeed: settings
                                                          .longPressSpeed,
                                                      showSubtitles: settings
                                                          .showSubtitles,
                                                      suppressSubtitleOverlay:
                                                          _suppressSubtitleOverlayForOcr,
                                                      onToggleSubtitles: () =>
                                                          _setFloatingSubtitles(
                                                            !settings
                                                                .showSubtitles,
                                                          ),
                                                      onMoveSubtitles: () {
                                                        final useGhostDrag =
                                                            _canUseGhostSidebarEditing(
                                                              context,
                                                              settings,
                                                            );
                                                        if (useGhostDrag) {
                                                          _enterGhostDragMode();
                                                        } else {
                                                          _enterSubtitleDragMode();
                                                        }
                                                      },
                                                      isLongPressing:
                                                          _isLongPressing,
                                                      longPressFeedbackText:
                                                          _longPressFeedbackText,
                                                      onLongPressStart:
                                                          _startLongPressSpeed,
                                                      onLongPressEnd:
                                                          _endLongPressSpeed,
                                                      subtitleEntries:
                                                          _currentSubtitleEntries,
                                                      subtitleStyle:
                                                          activeSubtitleStyle,
                                                      subtitleAlignment:
                                                          _isAudio
                                                          ? settings
                                                                .audioSubtitleAlignment
                                                          : settings
                                                                .subtitleAlignment,
                                                      onEnterSubtitleDragMode:
                                                          _enterSubtitleDragMode,
                                                      onClearSelection: () =>
                                                          _selectionKey
                                                              .currentState
                                                              ?.clearSelection(),
                                                      onToggleEpisodePicker:
                                                          () => setState(
                                                            () => _showEpisodePicker =
                                                                !_showEpisodePicker,
                                                          ),
                                                      focusNode:
                                                          _videoFocusNode,
                                                      onPlayPrevious: () =>
                                                          Provider.of<
                                                                MediaPlaybackService
                                                              >(
                                                                context,
                                                                listen: false,
                                                              )
                                                              .playPrevious(
                                                                autoPlay: settings
                                                                    .autoPlayNextVideo,
                                                              ),
                                                      onPlayNext: () =>
                                                          Provider.of<
                                                                MediaPlaybackService
                                                              >(
                                                                context,
                                                                listen: false,
                                                              )
                                                              .playNext(
                                                                autoPlay: settings
                                                                    .autoPlayNextVideo,
                                                              ),
                                                      hasPrevious:
                                                          Provider.of<
                                                                PlaylistManager
                                                              >(context)
                                                              .hasPrevious,
                                                      hasNext:
                                                          Provider.of<
                                                                PlaylistManager
                                                              >(context)
                                                              .hasNext,
                                                      mediaTitle:
                                                          _currentItem?.title ??
                                                          '',
                                                      chapters:
                                                          _currentItem
                                                              ?.chapters ??
                                                          const <
                                                            MediaChapter
                                                          >[],
                                                      onOpenChapters:
                                                          _currentItem
                                                                  ?.chapters
                                                                  .isNotEmpty ==
                                                              true
                                                          ? _toggleChapterSidebar
                                                          : null,
                                                      isChapterSidebarVisible:
                                                          _activeSidebar ==
                                                          SidebarType.chapters,
                                                      onExperimentalTrigger:
                                                          _navigateToMusicPlayer,
                                                      showResetScreenButton:
                                                          !_isAudio &&
                                                          _hasCustomVideoTransform,
                                                      onResetScreenTransform: () =>
                                                          _resetVideoUserTransform(),
                                                      suppressPrimaryGestures:
                                                          _isVideoTransformGestureActive ||
                                                          _videoGestureSession
                                                              .blocksTransforms,
                                                      allowPlayWhenUninitialized:
                                                          _isSourceMissing,
                                                    ),
                                                  ),

                                                // 3. Standard Subtitle Layer
                                                // Keep ordinary subtitles above the controls, just
                                                // like the ghost layer below. The subtitle widget is
                                                // intentionally left interactive in non-ghost mode.
                                                if (_initialized &&
                                                    (((settings.showSubtitles &&
                                                            !_suppressSubtitleOverlayForOcr) ||
                                                        _videoComposePreviewActive)) &&
                                                    !isGhostActive)
                                                  _isAudio
                                                      ? _buildFreeSubtitleOverlay(
                                                          alignment: settings
                                                              .audioSubtitleAlignment,
                                                          style:
                                                              activeSubtitleStyle,
                                                          isDragging:
                                                              _isSubtitleDragMode,
                                                          displayNotifier:
                                                              _videoComposePreviewActive
                                                              ? _videoComposePreviewController
                                                                    .displayNotifier
                                                              : null,
                                                          playbackControlsVisibility:
                                                              _playbackControlsVisibility,
                                                          playbackControlRects:
                                                              playerPlaybackControlRects,
                                                          avoidPlaybackControls:
                                                              settings
                                                                  .avoidPlaybackControlsWithSubtitles &&
                                                              !_isLocked &&
                                                              !_isSubtitleDragMode,
                                                        )
                                                      : _buildVideoBoundSubtitleOverlay(
                                                          videoSize:
                                                              containedVideoSize,
                                                          alignment: settings
                                                              .subtitleAlignment,
                                                          style:
                                                              activeSubtitleStyle,
                                                          isDragging:
                                                              _isSubtitleDragMode,
                                                          displayNotifier:
                                                              _videoComposePreviewActive
                                                              ? _videoComposePreviewController
                                                                    .displayNotifier
                                                              : null,
                                                          playbackControlsVisibility:
                                                              _playbackControlsVisibility,
                                                          playbackControlRects:
                                                              videoPlaybackControlRects,
                                                          avoidPlaybackControls:
                                                              settings
                                                                  .avoidPlaybackControlsWithSubtitles &&
                                                              !_isLocked &&
                                                              !_isSubtitleDragMode,
                                                        ),

                                                // 4. Drag Mode Layer (Standard)
                                                if (settings.showSubtitles &&
                                                    !_suppressSubtitleOverlayForOcr &&
                                                    _initialized &&
                                                    _isSubtitleDragMode)
                                                  _isAudio
                                                      ? _buildFreeSubtitleOverlay(
                                                          alignment: settings
                                                              .audioSubtitleAlignment,
                                                          style:
                                                              activeSubtitleStyle,
                                                          isDragging: true,
                                                          isGestureOnly: true,
                                                          enablePanUpdate: true,
                                                        )
                                                      : _buildVideoBoundSubtitleOverlay(
                                                          videoSize:
                                                              containedVideoSize,
                                                          alignment: settings
                                                              .subtitleAlignment,
                                                          style:
                                                              activeSubtitleStyle,
                                                          isDragging: true,
                                                          isGestureOnly: true,
                                                          enablePanUpdate: true,
                                                        ),

                                                // 5. Drag Hints
                                                if (_isSubtitleDragMode ||
                                                    _isGhostDragMode) ...[
                                                  if (_isSubtitleNearCenterX)
                                                    Positioned.fill(
                                                      child: Center(
                                                        child: Container(
                                                          width:
                                                              _isSubtitleSnappedX
                                                              ? 2
                                                              : 1,
                                                          height:
                                                              double.infinity,
                                                          color: Colors.white
                                                              .withValues(
                                                                alpha:
                                                                    _isSubtitleSnappedX
                                                                    ? 0.52
                                                                    : 0.22,
                                                              ),
                                                        ),
                                                      ),
                                                    ),
                                                  if (_isSubtitleNearCenterY)
                                                    Positioned.fill(
                                                      child: Center(
                                                        child: Container(
                                                          width:
                                                              double.infinity,
                                                          height:
                                                              _isSubtitleSnappedY
                                                              ? 2
                                                              : 1,
                                                          color: Colors.white
                                                              .withValues(
                                                                alpha:
                                                                    _isSubtitleSnappedY
                                                                    ? 0.52
                                                                    : 0.22,
                                                              ),
                                                        ),
                                                      ),
                                                    ),
                                                  Positioned(
                                                    top: 20,
                                                    child: Container(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 16,
                                                            vertical: 8,
                                                          ),
                                                      decoration: BoxDecoration(
                                                        color: Colors.black54,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              20,
                                                            ),
                                                      ),
                                                      child: Text(
                                                        _isGhostDragMode
                                                            ? "拖拽调整幽灵模式位置"
                                                            : "拖拽调整位置",
                                                        style: const TextStyle(
                                                          color: Colors.white,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ],

                                                // 6. Ghost Mode Subtitle Layer
                                                if (settings.showSubtitles &&
                                                    !_suppressSubtitleOverlayForOcr &&
                                                    isGhostActive)
                                                  Positioned.fill(
                                                    child: IgnorePointer(
                                                      ignoring:
                                                          !_isGhostDragMode,
                                                      child: GestureDetector(
                                                        onPanUpdate:
                                                            _isGhostDragMode
                                                            ? (
                                                                details,
                                                              ) => _updateSubtitlePosition(
                                                                details,
                                                                screenConstraints,
                                                                isGhost: true,
                                                              )
                                                            : null,
                                                        child: SubtitleDisplayLayer(
                                                          notifier:
                                                              subtitleDisplayNotifier,
                                                          alignment: settings
                                                              .ghostModeAlignment,
                                                          style: settings
                                                              .subtitleStyleGhostLandscape,
                                                          referenceHeight:
                                                              containedVideoSize
                                                                  .height,
                                                          isDragging:
                                                              _isGhostDragMode,
                                                          isVisualOnly:
                                                              !_isGhostDragMode,
                                                          animateAlignment:
                                                              true,
                                                          playbackControlsVisibility:
                                                              _playbackControlsVisibility,
                                                          playbackControlRects:
                                                              playerPlaybackControlRects,
                                                          avoidPlaybackControls:
                                                              settings
                                                                  .avoidPlaybackControlsWithSubtitles &&
                                                              !_isLocked &&
                                                              !_isGhostDragMode,
                                                        ),
                                                      ),
                                                    ),
                                                  ),

                                                // 7. Episode Picker Layer
                                                Positioned.fill(
                                                  child: _showEpisodePicker
                                                      ? GestureDetector(
                                                          behavior:
                                                              HitTestBehavior
                                                                  .opaque,
                                                          onTap: () {
                                                            setState(() {
                                                              _showEpisodePicker =
                                                                  false;
                                                            });
                                                          },
                                                          child: Container(
                                                            color: Colors
                                                                .transparent,
                                                          ),
                                                        )
                                                      : const SizedBox.shrink(),
                                                ),
                                                Align(
                                                  alignment: Alignment.center,
                                                  child: AnimatedSwitcher(
                                                    duration: const Duration(
                                                      milliseconds: 250,
                                                    ),
                                                    switchInCurve:
                                                        Curves.easeOutBack,
                                                    switchOutCurve:
                                                        Curves.easeIn,
                                                    transitionBuilder:
                                                        (
                                                          Widget child,
                                                          Animation<double>
                                                          animation,
                                                        ) {
                                                          return SlideTransition(
                                                            position:
                                                                Tween<Offset>(
                                                                  begin:
                                                                      const Offset(
                                                                        0,
                                                                        0.05,
                                                                      ),
                                                                  end: Offset
                                                                      .zero,
                                                                ).animate(
                                                                  animation,
                                                                ),
                                                            child:
                                                                FadeTransition(
                                                                  opacity:
                                                                      animation,
                                                                  child: child,
                                                                ),
                                                          );
                                                        },
                                                    child: _showEpisodePicker
                                                        ? EpisodePickerPanel(
                                                            key: const ValueKey(
                                                              "EpisodePickerPanel",
                                                            ),
                                                            panelWidth:
                                                                (screenConstraints
                                                                            .maxWidth *
                                                                        0.65)
                                                                    .clamp(
                                                                      280.0,
                                                                      800.0,
                                                                    ),
                                                            panelHeight:
                                                                (screenConstraints
                                                                            .maxHeight *
                                                                        0.75)
                                                                    .clamp(
                                                                      240.0,
                                                                      700.0,
                                                                    ),
                                                            onClose: () => setState(
                                                              () =>
                                                                  _showEpisodePicker =
                                                                      false,
                                                            ),
                                                          )
                                                        : const SizedBox.shrink(
                                                            key: ValueKey(
                                                              "EpisodePickerPanel_Empty",
                                                            ),
                                                          ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                  if (!isLeftHandedMode) ...sidebarWidgets,
                                ],
                              ),
                              if (showResizer)
                                Positioned(
                                  top: 0,
                                  bottom: 0,
                                  left: isLeftHandedMode
                                      ? resizableSidebarWidth -
                                            sidebarResizeOverlayInset
                                      : null,
                                  right: isLeftHandedMode
                                      ? null
                                      : resizableSidebarWidth -
                                            sidebarResizeOverlayInset,
                                  width: _subtitleSidebarResizerHitWidth,
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.translucent,
                                    onHorizontalDragStart: (_) =>
                                        _startSidebarResize(settings, context),
                                    onHorizontalDragUpdate: (details) =>
                                        _updateSidebarResize(
                                          settings,
                                          context,
                                          isLeftHandedMode,
                                          details,
                                        ),
                                    onHorizontalDragEnd: (_) =>
                                        _endSidebarResize(settings),
                                  ),
                                ),
                              if (Platform.isIOS)
                                Positioned(
                                  left: 0,
                                  top: 0,
                                  bottom: 0,
                                  width: _iosBackSwipeEdgeWidth,
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.translucent,
                                    onHorizontalDragStart: _onIosBackSwipeStart,
                                    onHorizontalDragUpdate:
                                        _onIosBackSwipeUpdate,
                                    onHorizontalDragEnd: _onIosBackSwipeEnd,
                                  ),
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

  Timer? _manualSubtitleWriteTimer;

  Map<String, String> _buildSubtitleEditorGroups() {
    final Map<String, String> groups = <String, String>{};
    final currentItem = _currentItem;
    if (currentItem != null) {
      groups.addAll(currentItem.downloadAssociatedSubtitles);
      groups.addAll(currentItem.localSubtitleGroups);
    }
    if (_currentItem?.subtitlePath != null &&
        _currentItem!.subtitlePath!.isNotEmpty) {
      groups.putIfAbsent('主字幕', () => _currentItem!.subtitlePath!);
    }
    if (_currentSubtitlePaths.isNotEmpty &&
        _currentSubtitlePaths.first.isNotEmpty) {
      groups.putIfAbsent('当前主字幕', () => _currentSubtitlePaths.first);
    }
    if (_currentItem?.secondarySubtitlePath != null &&
        _currentItem!.secondarySubtitlePath!.isNotEmpty) {
      groups.putIfAbsent('副字幕', () => _currentItem!.secondarySubtitlePath!);
    }
    return groups;
  }

  String? _resolveActiveSubtitleEditorPath() {
    if (_currentSubtitlePaths.isNotEmpty &&
        _currentSubtitlePaths.first.isNotEmpty) {
      return _currentSubtitlePaths.first;
    }
    if (_currentItem?.subtitlePath != null &&
        _currentItem!.subtitlePath!.isNotEmpty) {
      return _currentItem!.subtitlePath;
    }
    return null;
  }

  String _normalizeGroupName(String name) {
    final String normalized = name.trim();
    return normalized.isEmpty ? '手动字幕' : normalized;
  }

  Future<String> _createManualSubtitleGroup(String desiredName) async {
    if (_currentItem == null) return '';
    final String groupName = _normalizeGroupName(desiredName);
    final library = Provider.of<LibraryService>(context, listen: false);
    final String filePath = await const TaskSubtitleStorageService()
        .allocatePath(
          _currentItem!.id,
          'manual.${DateTime.now().millisecondsSinceEpoch}.srt',
        );
    await _writeSubtitlesToSrt(filePath, _subtitles);
    await library.registerManagedSubtitleAsset(
      _currentItem!.id,
      path: filePath,
      kind: ManagedSubtitleAssetKind.manual,
      displayName: groupName,
    );

    final Map<String, String> local = Map<String, String>.from(
      _currentItem!.localSubtitles ?? <String, String>{},
    );
    String unique = groupName;
    int serial = 2;
    while (local.containsKey(unique)) {
      unique = '$groupName $serial';
      serial++;
    }
    local[unique] = filePath;
    _currentItem!.localSubtitles = local;
    await library.updateVideoLocalSubtitles(_currentItem!.id, local);
    await _applyPrimarySubtitlePath(filePath);
    return filePath;
  }

  Future<void> _renameSubtitleGroup(String oldName, String newName) async {
    if (_currentItem == null) return;
    final String normalized = _normalizeGroupName(newName);
    final library = Provider.of<LibraryService>(context, listen: false);
    final associated = Map<String, String>.from(
      _currentItem!.additionalSubtitles ?? const <String, String>{},
    );
    final downloadAssociated = _currentItem!.downloadAssociatedSubtitles;
    final local = Map<String, String>.from(
      _currentItem!.localSubtitles ?? <String, String>{},
    );
    if (downloadAssociated.containsKey(oldName)) {
      final path = associated.remove(oldName)!;
      if (associated.containsKey(normalized) || local.containsKey(normalized)) {
        return;
      }
      associated[normalized] = path;
      _currentItem!.additionalSubtitles = associated;
      await library.updateVideoAdditionalSubtitles(
        _currentItem!.id,
        associated,
      );
    } else if (!local.containsKey(oldName)) {
      final String? currentPath = _resolveActiveSubtitleEditorPath();
      if (currentPath == null || currentPath.isEmpty) return;
      if (associated.containsKey(normalized) || local.containsKey(normalized)) {
        return;
      }
      local[normalized] = currentPath;
    } else {
      final String path = local.remove(oldName)!;
      if (associated.containsKey(normalized) || local.containsKey(normalized)) {
        return;
      }
      local[normalized] = path;
    }
    _currentItem!.localSubtitles = local;
    await library.updateVideoLocalSubtitles(_currentItem!.id, local);
    if (mounted) setState(() {});
  }

  Future<void> _writeSubtitlesToSrt(
    String path,
    List<SubtitleItem> subtitles,
  ) async {
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < subtitles.length; i++) {
      final SubtitleItem item = subtitles[i];
      final int index = i + 1;
      buffer.writeln(index.toString());
      buffer.writeln(
        '${_formatSrtTime(item.startTime)} --> ${_formatSrtTime(item.endTime)}',
      );
      buffer.writeln(item.text);
      buffer.writeln();
    }
    await File(path).writeAsString(buffer.toString(), flush: true);
  }

  String _formatSrtTime(Duration duration) {
    String two(int value) => value.toString().padLeft(2, '0');
    final int hours = duration.inHours;
    final int minutes = duration.inMinutes.remainder(60);
    final int seconds = duration.inSeconds.remainder(60);
    final int milliseconds = duration.inMilliseconds.remainder(1000);
    return '${two(hours)}:${two(minutes)}:${two(seconds)},${milliseconds.toString().padLeft(3, '0')}';
  }

  Future<void> _applyPrimarySubtitlePath(String path) async {
    if (path.isEmpty || _currentItem == null) return;
    final settings = Provider.of<SettingsService>(context, listen: false);
    final library = Provider.of<LibraryService>(context, listen: false);
    String? secondaryPath;
    if (_currentSubtitlePaths.length > 1) {
      secondaryPath = _currentSubtitlePaths[1];
    } else {
      secondaryPath = _currentItem!.secondarySubtitlePath;
    }
    final List<String> paths = <String>[path];
    if (secondaryPath != null &&
        secondaryPath.isNotEmpty &&
        secondaryPath != path) {
      paths.add(secondaryPath);
    }
    await _loadSubtitles(paths);
    await library.updateVideoSubtitles(
      _currentItem!.id,
      path,
      settings.autoCacheSubtitles,
      secondarySubtitlePath: secondaryPath,
      isSecondaryCached: settings.autoCacheSubtitles,
    );
  }

  Future<void> _onSubtitleEditorSubtitlesChanged(
    List<SubtitleItem> subtitles,
  ) async {
    if (!mounted) return;
    setState(() {
      _subtitles = List<SubtitleItem>.from(subtitles);
    });
    _rebuildSubtitleIndex();
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    playbackService.setSubtitleState(
      paths: _currentSubtitlePaths,
      primary: _subtitles,
      secondary: _secondarySubtitles,
    );
    _updateSubtitle();
    final String? primaryPath = _resolveActiveSubtitleEditorPath();
    if (primaryPath == null || primaryPath.isEmpty) return;
    final library = Provider.of<LibraryService>(context, listen: false);
    final videoId = _currentItem?.id;
    final writablePath = await _ensureWritableSubtitleEditorPath(
      primaryPath,
      subtitles,
    );
    if (writablePath == null) return;
    _manualSubtitleWriteTimer?.cancel();
    _manualSubtitleWriteTimer = Timer(const Duration(milliseconds: 150), () {
      unawaited(
        _writeSubtitlesToSrt(writablePath, subtitles).then((_) {
          library.notifySubtitleFilesChanged(videoId: videoId);
        }),
      );
    });
  }

  Future<String?> _ensureWritableSubtitleEditorPath(
    String sourcePath,
    List<SubtitleItem> subtitles,
  ) async {
    final item = _currentItem;
    if (item == null) return null;
    final storage = const TaskSubtitleStorageService();
    final library = Provider.of<LibraryService>(context, listen: false);
    final isOwned = await storage.isTaskOwnedPath(sourcePath, item.id);
    if (isOwned && p.extension(sourcePath).toLowerCase() == '.srt') {
      return sourcePath;
    }

    final sourceAssetId = library
        .managedSubtitleAssetForPath(item.id, sourcePath)
        ?.assetId;
    final outputPath = await storage.allocatePath(
      item.id,
      'edited.${DateTime.now().millisecondsSinceEpoch}.srt',
    );
    await _writeSubtitlesToSrt(outputPath, subtitles);
    final baseLabel = '${p.basenameWithoutExtension(sourcePath)}（编辑副本）';
    await library.registerManagedSubtitleAsset(
      item.id,
      path: outputPath,
      kind: ManagedSubtitleAssetKind.manual,
      displayName: baseLabel,
      sourceAssetId: sourceAssetId,
    );
    final local = Map<String, String>.from(
      item.localSubtitles ?? const <String, String>{},
    );
    var label = baseLabel;
    var serial = 2;
    while (local.containsKey(label)) {
      label = '$baseLabel $serial';
      serial++;
    }
    local[label] = outputPath;
    item.localSubtitles = local;
    await library.updateVideoLocalSubtitles(item.id, local);
    await _applyPrimarySubtitlePath(outputPath);
    return outputPath;
  }

  void _showSubtitleEditor() {
    setState(() {
      _previousSidebarType = _normalizedSidebarForRestore(_activeSidebar);
      _activeSidebar = SidebarType.subtitleEditor;
    });
  }

  void _toggleChapterSidebar() {
    setState(() {
      if (_activeSidebar == SidebarType.chapters) {
        _activeSidebar = _previousSidebarType != SidebarType.none
            ? _previousSidebarType
            : (_isSubtitleSidebarVisible
                  ? SidebarType.subtitles
                  : SidebarType.none);
        _previousSidebarType = SidebarType.none;
      } else {
        _previousSidebarType = _normalizedSidebarForRestore(_activeSidebar);
        _activeSidebar = SidebarType.chapters;
      }
    });
  }

  Widget? _buildSidebarContent(SettingsService settings) {
    if (!_isSidebarOpen) return null;

    switch (_activeSidebar) {
      case SidebarType.chapters:
        final item = _currentItem;
        if (item == null) return null;
        if (!_controllerAssigned || !_initialized) {
          return const Center(
            child: Text(
              '播放器加载完成后可查看章节',
              style: TextStyle(color: Colors.white54),
            ),
          );
        }
        return ChapterSidebar(
          videoItem: item,
          controller: _controller,
          onSeek: _seekPlaybackPosition,
          onClose: _toggleChapterSidebar,
          playerFocusNode: _videoFocusNode,
        );

      case SidebarType.subtitles:
        return SubtitleSidebar(
          key: _subtitleSidebarKey,
          subtitles: _subtitles,
          secondarySubtitles: _secondarySubtitles,
          controller: _controllerAssigned ? _controller : null,
          positionListenable: MediaPlaybackService().positionNotifier,
          onItemTap: _seekToSubtitleFast,
          onOpenSettings: () => setState(() {
            _previousSidebarType = SidebarType.subtitles;
            _activeSidebar = SidebarType.settings;
          }),
          onClose: () => setState(
            () => _activeSidebar = _isSubtitleSidebarVisible
                ? SidebarType.subtitles
                : SidebarType.none,
          ),
          onLoadSubtitle: _pickSubtitle,
          onOpenSubtitleStyle: _toggleFloatingSubtitleSettingsSidebar,
          onOpenSubtitleManager: _showSubtitleManager,
          onOpenSubtitleEditor: _showSubtitleEditor,
          onOpenVideoCompose: _showVideoCompose,
          onOpenOcrSubtitle: _supportsOcrSubtitle ? _showOcrSubtitle : null,
          onClearSelection: () => _selectionKey.currentState?.clearSelection(),
          onScanEmbeddedSubtitles: _checkAndLoadEmbeddedSubtitle,
          isCompact: true,
          isPortrait: false,
          focusNode: _videoFocusNode, // Pass focus node
          isVisible:
              _isSubtitleSidebarVisible &&
              _activeSidebar == SidebarType.subtitles,
          showEmbeddedLoadingMessage:
              _embeddedSubtitleDetected &&
              _isLoadingEmbeddedSubtitle &&
              _subtitles.isEmpty &&
              _secondarySubtitles.isEmpty,
        );

      case SidebarType.subtitleStyle:
        final isLandscape =
            MediaQuery.of(context).orientation == Orientation.landscape;
        final canShowGhostControls = _canShowGhostSidebarControls(context);
        final isGhostEditing =
            !_subtitleStyleFromCompose &&
            _canUseGhostSidebarEditing(context, settings);
        final SubtitleStyle sheetStyle = _isAudio
            ? (isLandscape
                  ? settings.audioSubtitleStyleLandscape
                  : settings.audioSubtitleStylePortrait)
            : (isGhostEditing
                  ? settings.subtitleStyleGhostLandscape
                  : (isLandscape
                        ? settings.subtitleStyleLandscape
                        : settings.subtitleStylePortrait));
        return SubtitleSettingsSheet(
          style: sheetStyle,
          isLandscape: isLandscape,
          isAudio: _isAudio,
          syncAudioSubtitleStyleWithVideo:
              settings.syncAudioSubtitleStyleWithVideo,
          onSyncAudioSubtitleStyleWithVideoChanged: _isAudio
              ? (value) => settings.setAudioSubtitleStyleSyncWithVideo(value)
              : null,
          hideGhostModeToggle:
              _subtitleStyleFromCompose || !canShowGhostControls,
          // 文字样式改变时同步到横竖屏
          onTextStyleChanged: (newTextStyle) {
            if (_isAudio) {
              if (settings.syncAudioSubtitleStyleWithVideo) {
                settings.saveSubtitleTextStyle(newTextStyle);
              } else {
                settings.saveAudioSubtitleTextStyle(newTextStyle);
              }
            } else {
              settings.saveSubtitleTextStyle(newTextStyle);
            }
          },
          // 布局样式改变时同步到横竖屏
          onLayoutStyleChanged: (newLayoutStyle) {
            if (_isAudio) {
              if (isLandscape) {
                settings.saveAudioSubtitleLayoutLandscape(newLayoutStyle);
              } else {
                settings.saveAudioSubtitleLayoutPortrait(newLayoutStyle);
              }
            } else {
              if (isGhostEditing) {
                settings.saveSubtitleLayoutGhostLandscape(newLayoutStyle);
              } else if (isLandscape) {
                settings.saveSubtitleLayoutLandscape(newLayoutStyle);
              } else {
                settings.saveSubtitleLayoutPortrait(newLayoutStyle);
              }
            }
          },
          // 向后兼容的回调
          onStyleChanged: (newStyle) {
            if (_isAudio) {
              if (settings.syncAudioSubtitleStyleWithVideo) {
                settings.saveSubtitleTextStyle(newStyle.textStyle);
                if (isLandscape) {
                  settings.saveAudioSubtitleLayoutLandscape(
                    newStyle.layoutStyle,
                  );
                } else {
                  settings.saveAudioSubtitleLayoutPortrait(
                    newStyle.layoutStyle,
                  );
                }
              } else {
                settings.saveAudioSubtitleStyleLandscape(newStyle);
              }
            } else {
              settings.saveSubtitleStyleLandscape(newStyle);
            }
          },
          onClose: () => setState(() {
            _isStyleSidebarDragMode = false;
            _isSubtitleDragMode = false;
            _isGhostDragMode = false;
            _isSubtitleSnappedX = false;
            _isSubtitleSnappedY = false;
            if (_previousSidebarType != SidebarType.none) {
              _activeSidebar = _previousSidebarType;
            } else {
              _activeSidebar = _isSubtitleSidebarVisible
                  ? SidebarType.subtitles
                  : SidebarType.none;
            }
            _previousSidebarType = SidebarType.none;
          }),
          onBack: () => setState(() {
            _isStyleSidebarDragMode = false;
            _isSubtitleDragMode = false;
            _isGhostDragMode = false;
            _isSubtitleSnappedX = false;
            _isSubtitleSnappedY = false;
            if (_previousSidebarType != SidebarType.none) {
              _activeSidebar = _previousSidebarType;
            } else {
              _activeSidebar = _isSubtitleSidebarVisible
                  ? SidebarType.subtitles
                  : SidebarType.none;
            }
            _previousSidebarType = SidebarType.none;
          }),
        );

      case SidebarType.subtitleEditor:
        final Map<String, String> groups = _buildSubtitleEditorGroups();
        String? activePath = _resolveActiveSubtitleEditorPath();
        if (activePath == null && groups.isNotEmpty) {
          activePath = groups.values.first;
        }
        return LandscapeSubtitleEditorSidebar(
          groups: groups,
          activeGroupPath: activePath,
          subtitles: _subtitles,
          currentSubtitleIndex: _currentSubtitleIndex,
          currentPlaybackPosition:
              _controllerAssigned && _controller.value.isInitialized
              ? _controller.value.position
              : Duration.zero,
          onSelectGroupPath: _applyPrimarySubtitlePath,
          onCreateGroup: (name) async {
            await _createManualSubtitleGroup(name);
            if (mounted) setState(() {});
          },
          onRenameGroup: (oldName, newName) async {
            await _renameSubtitleGroup(oldName, newName);
          },
          onSubtitlesChanged: _onSubtitleEditorSubtitlesChanged,
          onSeekTo: _seekToSubtitleFast,
          onClose: () => setState(() {
            if (_previousSidebarType != SidebarType.none) {
              _activeSidebar = _previousSidebarType;
            } else {
              _activeSidebar = _isSubtitleSidebarVisible
                  ? SidebarType.subtitles
                  : SidebarType.none;
            }
            _previousSidebarType = SidebarType.none;
          }),
        );

      case SidebarType.settings:
        final displayedPlaybackSpeed =
            _controllerAssigned && _controller.value.isInitialized
            ? _controller.value.playbackSpeed
            : settings.effectiveGlobalPlaybackSpeed;
        final bool showMobilePlaybackControls =
            !kIsWeb && (Platform.isAndroid || Platform.isIOS);
        return SettingsPanel(
          playbackSpeed: displayedPlaybackSpeed,
          isAudioMode: _isAudio,
          syncAudioSubtitleStyleWithVideo:
              settings.syncAudioSubtitleStyleWithVideo,
          onSyncAudioSubtitleStyleWithVideoChanged: _isAudio
              ? (value) => settings.setAudioSubtitleStyleSyncWithVideo(value)
              : null,
          showSubtitles: settings.showSubtitles,
          isMirroredH: _resolvedVideoMirrorH(settings),
          isMirroredV: _resolvedVideoMirrorV(settings),
          onLoadSubtitle: () async {
            await _pickSubtitle();
          },
          onOpenSubtitleSettings: _toggleFloatingSubtitleSettingsSidebar,
          onClose: () => setState(() {
            if (_previousSidebarType != SidebarType.none) {
              _activeSidebar = _previousSidebarType;
            } else {
              _activeSidebar = _isSubtitleSidebarVisible
                  ? SidebarType.subtitles
                  : SidebarType.none;
            }
            _previousSidebarType = SidebarType.none;
          }),
          isPlaybackSpeedLocked: settings.isPlaybackSpeedLocked,
          lockedPlaybackSpeed: settings.isPlaybackSpeedLocked
              ? settings.playbackSpeed
              : null,
          onSpeedChanged: (speed) =>
              unawaited(_handlePlaybackSpeedSelected(speed)),
          onSpeedLockChanged: _handlePlaybackSpeedLockChanged,
          longPressSpeed: settings.longPressSpeed,
          onLongPressSpeedChanged: (speed) =>
              settings.saveLongPressSpeed(speed),
          showLongPressSpeedIndicator: settings.showLongPressSpeedIndicator,
          onShowLongPressSpeedIndicatorChanged: (value) =>
              settings.saveShowLongPressSpeedIndicator(value),
          onSubtitleToggle: (value) => _setFloatingSubtitles(value),
          onMirrorHChanged: (value) => unawaited(
            _updateCurrentVideoDisplayTransform(isMirroredH: value),
          ),
          onMirrorVChanged: (value) => unawaited(
            _updateCurrentVideoDisplayTransform(isMirroredV: value),
          ),
          doubleTapSeekSeconds: settings.doubleTapSeekSeconds,
          onSeekSecondsChanged: (seconds) =>
              settings.saveDoubleTapSeekSeconds(seconds),
          enableDoubleTapSubtitleSeek: settings.enableDoubleTapSubtitleSeek,
          onDoubleTapSubtitleSeekChanged: (val) =>
              settings.saveEnableDoubleTapSubtitleSeek(val),
          subtitleDelay: settings.subtitleOffset.inMilliseconds / 1000.0,
          onSubtitleDelayChanged: (delay) =>
              settings.saveSubtitleOffsetMilliseconds((delay * 1000).round()),
          onSubtitleDelayChangeEnd: (_) {},

          // New: Auto Cache Toggle
          autoCacheSubtitles: settings.autoCacheSubtitles,
          onAutoCacheSubtitlesChanged: (value) =>
              settings.saveAutoCacheSubtitles(value),

          // New: Split Subtitle Toggle
          splitSubtitleByLine: settings.splitSubtitleByLine,
          onSplitSubtitleByLineChanged: (val) =>
              settings.saveSplitSubtitleByLine(val),

          // New: Continuous Subtitle Toggle
          continuousSubtitle: _isAudio
              ? settings.audioContinuousSubtitle
              : settings.videoContinuousSubtitle,
          onContinuousSubtitleChanged: (value) {
            if (_isAudio) {
              settings.saveAudioContinuousSubtitle(value);
            } else {
              settings.saveVideoContinuousSubtitle(value);
            }
          },

          // New: Auto Pause on Exit
          autoPauseOnExit: settings.autoPauseOnExit,
          onAutoPauseOnExitChanged: (value) =>
              settings.saveAutoPauseOnExit(value),
          avoidPlaybackControlsWithSubtitles:
              settings.avoidPlaybackControlsWithSubtitles,
          onAvoidPlaybackControlsWithSubtitlesChanged: (value) =>
              settings.saveAvoidPlaybackControlsWithSubtitles(value),
          pausePlaybackWhenAppBackgrounded:
              settings.pausePlaybackWhenAppBackgrounded,
          onPausePlaybackWhenAppBackgroundedChanged: (value) =>
              settings.savePausePlaybackWhenAppBackgrounded(value),
          allowConcurrentPlayback: settings.allowConcurrentPlayback,
          onAllowConcurrentPlaybackChanged: (value) =>
              settings.saveAllowConcurrentPlayback(value),
          showVideoDecoderSetting:
              !kIsWeb &&
              (Platform.isAndroid ||
                  Platform.isIOS ||
                  Platform.isMacOS ||
                  Platform.isWindows ||
                  Platform.isLinux),
          useHardwareVideoDecoding: settings.useHardwareVideoDecoding,
          onVideoDecoderChanged: (useHardware) async {
            await settings.saveUseHardwareVideoDecoding(useHardware);
            await MediaPlaybackService().reloadCurrentVideoDecoder();
          },
          enableHeadsetMediaControls: settings.enableHeadsetMediaControls,
          onEnableHeadsetMediaControlsChanged: (value) =>
              settings.saveEnableHeadsetMediaControls(value),
          showMobilePlaybackControls: showMobilePlaybackControls,

          // New: Auto Play Next Video
          autoPlayNextVideo: settings.autoPlayNextVideo,
          onAutoPlayNextVideoChanged: (value) =>
              settings.saveAutoPlayNextVideo(value),
          autoPlayOnCompletion: settings.autoPlayOnCompletion,
          onAutoPlayOnCompletionChanged: (value) =>
              settings.saveAutoPlayOnCompletion(value),
          autoPlayOnCompletionFromStart: settings.autoPlayOnCompletionFromStart,
          onAutoPlayOnCompletionFromStartChanged: (value) =>
              settings.saveAutoPlayOnCompletionFromStart(value),

          // Seek Preview
          enableSeekPreview: settings.enableSeekPreview,
          onEnableSeekPreviewChanged: (value) =>
              settings.saveEnableSeekPreview(value),
          enableHapticFeedback: settings.enableHapticFeedback,
          onEnableHapticFeedbackChanged: (value) =>
              settings.saveEnableHapticFeedback(value),
          isLeftHandedMode: settings.isLeftHandedMode,
          onLeftHandedModeChanged: (value) =>
              settings.saveLeftHandedMode(value),
        );

      case SidebarType.subtitlePosition:
        final canShowGhostControls = _canShowGhostSidebarControls(context);
        final canEditGhostStyle = _canUseGhostSidebarEditing(context, settings);
        final isGhost = canEditGhostStyle && _isGhostDragMode;
        final currentAlign = isGhost
            ? settings.ghostModeAlignment
            : (_isAudio
                  ? settings.audioSubtitleAlignment
                  : settings.subtitleAlignment);

        return SubtitlePositionSidebar(
          currentAlignment: currentAlign,
          onAlignmentChanged: (align) => isGhost
              ? settings.saveGhostModeAlignment(align)
              : (_isAudio
                    ? settings.saveAudioSubtitleAlignment(align)
                    : settings.saveSubtitleAlignment(align)),
          presets: settings.subtitlePresets,
          onSavePreset: () {
            final newPresets = List<Map<String, double>>.from(
              settings.subtitlePresets,
            );
            newPresets.insert(0, {'x': currentAlign.x, 'y': currentAlign.y});
            if (newPresets.length > 10) newPresets.removeLast();
            settings.saveSubtitlePresets(newPresets);
          },
          onReset: () => isGhost
              ? settings.saveGhostModeAlignment(const Alignment(0.0, 0.9))
              : (_isAudio
                    ? settings.saveAudioSubtitleAlignment(
                        const Alignment(0.0, 0.9),
                      )
                    : settings.saveSubtitleAlignment(
                        const Alignment(0.0, 0.9),
                      )),
          onConfirm: _exitSubtitleDragMode,
          isGhostModeEnabled: settings.isGhostModeEnabled,
          onGhostModeToggle: (val) {
            settings.saveGhostModeEnabled(val);
            // Force rebuild to update UI state
            setState(() {});
          },
          onEnterGhostMode: _enterGhostDragMode,
          isGhostModeActive: isGhost,
          hideGhostModeControls: !canShowGhostControls,
        );

      case SidebarType.subtitleManager:
        String path = _currentItem?.path ?? widget.videoFile?.path ?? "";
        if (path.isEmpty) return null;
        final List<String> selectedPathsForSheet =
            _currentSubtitlePaths.isNotEmpty
            ? List<String>.from(_currentSubtitlePaths)
            : <String>[
                if (_currentItem?.subtitlePath != null &&
                    _currentItem!.subtitlePath!.isNotEmpty)
                  _currentItem!.subtitlePath!,
                if (_currentItem?.secondarySubtitlePath != null &&
                    _currentItem!.secondarySubtitlePath!.isNotEmpty)
                  _currentItem!.secondarySubtitlePath!,
              ];
        final associatedSubtitlesForSheet =
            _currentItem?.downloadAssociatedSubtitles ??
            const <String, String>{};
        final localSubtitlesForSheet =
            _currentItem?.localSubtitleGroups ?? const <String, String>{};

        return SubtitleManagementSheet(
          key: ValueKey(path),
          videoPath: path,
          videoId: _currentItem?.id,
          showEmbeddedSubtitles: true,
          associatedSubtitles: associatedSubtitlesForSheet,
          localSubtitles: localSubtitlesForSheet,
          initialSelectedPaths: selectedPathsForSheet,
          onSubtitleChanged: () {
            // Logic to refresh if needed
          },
          onSubtitleSelected: (paths) async {
            final settings = Provider.of<SettingsService>(
              context,
              listen: false,
            );
            final library = Provider.of<LibraryService>(context, listen: false);

            await _loadSubtitles(paths);
            if (_currentItem != null) {
              String? path0;
              String? path1;

              if (paths.isNotEmpty) path0 = paths[0];
              if (paths.length > 1) path1 = paths[1];

              await library.updateVideoSubtitles(
                _currentItem!.id,
                path0,
                settings.autoCacheSubtitles,
                secondarySubtitlePath: path1,
                isSecondaryCached: settings.autoCacheSubtitles,
              );
              final updated = library.getVideo(_currentItem!.id);
              if (updated != null && mounted) {
                setState(() {
                  _currentItem = updated;
                });
              }
            }
          },
          onSubtitlePreview: (path) async {
            List<String> pathsToLoad = [path];
            if (_currentSubtitlePaths.length > 1) {
              pathsToLoad.add(_currentSubtitlePaths[1]);
            }
            await _loadSubtitles(pathsToLoad);
          },
          onOpenAi: () {
            setState(() {
              _previousSidebarType = SidebarType.subtitleManager;
              _activeSidebar = SidebarType.aiTranscription;
            });
          },
          onClose: () => setState(() {
            if (_previousSidebarType != SidebarType.none) {
              _activeSidebar = _previousSidebarType;
            } else {
              _activeSidebar = _isSubtitleSidebarVisible
                  ? SidebarType.subtitles
                  : SidebarType.none;
            }
            _previousSidebarType = SidebarType.none;
          }),
        );

      case SidebarType.aiTranscription:
        String pathAi = _currentItem?.path ?? widget.videoFile?.path ?? "";
        if (pathAi.isEmpty) return null;

        return AiTranscriptionPanel(
          videoPath: pathAi,
          videoId: _currentItem?.id,
          onBack: () => setState(() {
            if (_previousSidebarType != SidebarType.none) {
              _activeSidebar = _previousSidebarType;
            } else {
              _activeSidebar = _isSubtitleSidebarVisible
                  ? SidebarType.subtitles
                  : SidebarType.none;
            }
            _previousSidebarType = SidebarType.none;
          }),
          onCompleted: (srtPath) async {
            // 只负责UI刷新，数据持久化已由 TranscriptionManager 处理
            List<String> pathsToLoad = [srtPath];
            if (_currentSubtitlePaths.length > 1) {
              pathsToLoad.add(_currentSubtitlePaths[1]);
            }
            await _loadSubtitles(pathsToLoad);

            if (mounted) {
              AppToast.show("AI 字幕已加载", type: AppToastType.success);
            }
          },
        );

      case SidebarType.videoCompose:
        if (_currentItem == null) return const SizedBox.shrink();
        return VideoComposePanel(
          key: ValueKey('video_compose_${_currentItem!.id}'),
          videoItem: _currentItem!,
          currentSelectedPaths: List<String>.from(_currentSubtitlePaths),
          availableSubtitleMap: _buildAvailableSubtitleMap(),
          onBack: () {
            _clearVideoComposePreview();
            setState(() {
              _activeSidebar = _previousSidebarType != SidebarType.none
                  ? _previousSidebarType
                  : (_isSubtitleSidebarVisible
                        ? SidebarType.subtitles
                        : SidebarType.none);
              _previousSidebarType = SidebarType.none;
            });
          },
          onOpenSubtitleStyle: () =>
              _toggleFloatingSubtitleSettingsSidebar(fromCompose: true),
          onOpenSubtitleManager: _showSubtitleManager,
          onPreviewChanged: _applyVideoComposePreview,
        );

      case SidebarType.ocrSubtitle:
        if (_currentItem == null || _isAudio) return const SizedBox.shrink();
        if (!_controllerAssigned || !_initialized) {
          return const Center(
            child: Text(
              '播放器加载完成后可使用 OCR 字幕',
              style: TextStyle(color: Colors.white54),
            ),
          );
        }
        return OcrSubtitlePanel(
          key: ValueKey('ocr_subtitle_${_currentItem!.id}'),
          videoItem: _currentItem!,
          duration: _controller.value.duration,
          currentPosition: () => _controller.value.position,
          pauseForRegionSelection: () async {
            final wasPlaying = _controller.value.isPlaying;
            await _controller.pause();
            return wasPlaying;
          },
          restorePlayback: (wasPlaying) async {
            if (wasPlaying && mounted) await _controller.play();
          },
          onBack: () => setState(() {
            _activeSidebar = _previousSidebarType != SidebarType.none
                ? _previousSidebarType
                : (_isSubtitleSidebarVisible
                      ? SidebarType.subtitles
                      : SidebarType.none);
            _previousSidebarType = SidebarType.none;
          }),
          onCompleted: _applyCompletedOcrSubtitles,
        );

      default:
        return null;
    }
  }

  Map<String, String> _buildAvailableSubtitleMap() {
    final Map<String, String> map = <String, String>{};
    if (_currentItem == null) return map;
    final additional = <String, String>{
      ..._currentItem!.downloadAssociatedSubtitles,
      ..._currentItem!.localSubtitleGroups,
    };
    final Map<String, String> nameByPath = <String, String>{};
    if (additional.isNotEmpty) {
      for (final entry in additional.entries) {
        if (entry.value.isEmpty) continue;
        nameByPath[_subtitlePathKey(entry.value)] = entry.key;
      }
    }
    String embeddedFallbackName(String path, String fallback) {
      final normalized = p.basename(path);
      final match = RegExp(r'\.stream_(\d+)').firstMatch(normalized);
      if (match != null) {
        final index = match.group(1);
        if (index != null && index.isNotEmpty) {
          return '内嵌字幕 $index';
        }
      }
      // 回退到文件名，避免显示"主字幕（主字幕）"这类冗余文本
      final base = p.basenameWithoutExtension(path).trim();
      return base.isNotEmpty ? base : fallback;
    }

    String nameForPath(String path, {String fallback = '未命名字幕'}) {
      final name = nameByPath[_subtitlePathKey(path)];
      if (name != null && name.trim().isNotEmpty) {
        return name;
      }
      return embeddedFallbackName(path, fallback);
    }

    final String? primary = _currentItem!.subtitlePath;
    if (primary != null && primary.isNotEmpty) {
      map[primary] = '主字幕（${nameForPath(primary, fallback: '主字幕')}）';
    }
    final String? secondary = _currentItem!.secondarySubtitlePath;
    if (secondary != null && secondary.isNotEmpty) {
      map[secondary] = '副字幕（${nameForPath(secondary, fallback: '副字幕')}）';
    }
    if (_currentSubtitlePaths.isNotEmpty) {
      for (int i = 0; i < _currentSubtitlePaths.length; i++) {
        final String path = _currentSubtitlePaths[i];
        if (path.isEmpty) continue;
        final String role = i == 0 ? '当前主字幕' : '当前副字幕';
        map[path] = '$role（${nameForPath(path, fallback: role)}）';
      }
    }
    if (additional.isNotEmpty) {
      for (final entry in additional.entries) {
        if (!map.containsKey(entry.value)) {
          map[entry.value] = entry.key;
        }
      }
    }
    return map;
  }
}
