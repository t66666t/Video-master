import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../services/media_playback_service.dart';
import '../services/settings_service.dart';
import '../platform/windows_video_player_media_kit.dart';
import '../widgets/video_controls_overlay.dart';
import '../models/subtitle_style.dart';

class SimpleVideoPlayerScreen extends StatefulWidget {
  final String videoPath;
  final String title;

  const SimpleVideoPlayerScreen({
    super.key,
    required this.videoPath,
    required this.title,
  });

  @override
  State<SimpleVideoPlayerScreen> createState() =>
      _SimpleVideoPlayerScreenState();
}

class _SimpleVideoPlayerScreenState extends State<SimpleVideoPlayerScreen> {
  VideoPlayerController? _controller;
  String? _errorMessage;
  bool _isReady = false;
  bool _isLocked = false;
  bool _isExiting = false;
  bool _isLongPressing = false;
  String _longPressFeedbackText = '';
  double _preLongPressSpeed = 1.0;
  double _confirmedPlaybackSpeed = 1.0;
  double _lastDispatchedPlaybackSpeed = 1.0;
  int _playbackSpeedRequestId = 0;
  Future<void> _playbackSpeedCommandTail = Future<void>.value();
  final FocusNode _videoFocusNode = FocusNode();
  MediaPlaybackService? _suspendedPlaybackService;
  VideoPlayerController? _suspendedController;
  String? _suspendedItemId;
  bool _resumeOriginalPlayback = false;
  Future<void>? _cleanupFuture;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initPlayer();
    });
  }

  @override
  void dispose() {
    _playbackSpeedRequestId++;
    _restoreSystemUiImmediately();
    unawaited(_cleanupPreviewAndRestorePlayback());
    _videoFocusNode.dispose();
    super.dispose();
  }

  void _restoreSystemUiImmediately() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
    );
  }

  Future<void> _exitPreview() async {
    if (_isExiting) return;
    _isExiting = true;
    _restoreSystemUiImmediately();
    await _cleanupPreviewAndRestorePlayback();
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }
    _isExiting = false;
  }

  Future<void> _cleanupPreviewAndRestorePlayback() {
    return _cleanupFuture ??= _performPreviewCleanup();
  }

  Future<void> _performPreviewCleanup() async {
    final previewController = _controller;
    _controller = null;
    _playbackSpeedRequestId++;
    if (previewController != null) {
      try {
        previewController.removeListener(_onPlayerStateChanged);
      } catch (_) {}
      try {
        await previewController.pause();
      } catch (_) {}
      try {
        await previewController.dispose();
      } catch (_) {}
    }

    final playbackService = _suspendedPlaybackService;
    final originalController = _suspendedController;
    if (_resumeOriginalPlayback &&
        playbackService != null &&
        playbackService.controller == originalController &&
        playbackService.currentItem?.id == _suspendedItemId &&
        originalController?.value.isInitialized == true) {
      await playbackService.resume();
    }
  }

  Future<void> _initPlayer() async {
    final file = File(widget.videoPath);
    if (!await file.exists()) {
      if (!mounted) return;
      setState(() {
        _errorMessage = "媒体文件不存在，可能已被移动或删除";
      });
      return;
    }

    try {
      if (!mounted) return;
      final playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      _suspendedPlaybackService = playbackService;
      _suspendedController = playbackService.controller;
      _suspendedItemId = playbackService.currentItem?.id;
      _resumeOriginalPlayback = playbackService.isPlaying;
      if (_resumeOriginalPlayback) {
        await playbackService.pause();
      }
      if (!mounted || _isExiting) {
        await _cleanupPreviewAndRestorePlayback();
        return;
      }
      final settings = Provider.of<SettingsService>(context, listen: false);
      final previewController = VideoPlayerController.file(
        file,
        videoPlayerOptions: MediaPlaybackService.buildVideoPlayerOptions(
          settings: settings,
        ),
      );
      _controller = previewController;
      await previewController.initialize();
      if (!mounted || _isExiting) {
        await _cleanupPreviewAndRestorePlayback();
        return;
      }
      final targetSpeed = settings.effectiveGlobalPlaybackSpeed;
      if (!settings.isSamePlaybackSpeed(
        previewController.value.playbackSpeed,
        targetSpeed,
      )) {
        await previewController.setPlaybackSpeed(targetSpeed);
      }
      _confirmedPlaybackSpeed = targetSpeed;
      _lastDispatchedPlaybackSpeed = targetSpeed;
      previewController.addListener(_onPlayerStateChanged);

      if (!mounted) return;
      setState(() {
        _isReady = true;
      });
      previewController.play();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = "播放失败：无法加载该媒体 ($e)";
      });
    }
  }

  void _onPlayerStateChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _togglePlayPause() {
    if (_controller == null) return;
    if (_controller!.value.isPlaying) {
      _controller!.pause();
    } else {
      _controller!.play();
    }
  }

  bool _startLongPressSpeed() {
    final controller = _controller;
    if (controller == null) return false;
    final settings = Provider.of<SettingsService>(context, listen: false);
    _preLongPressSpeed = _confirmedPlaybackSpeed;
    _isLongPressing = true;
    _longPressFeedbackText = "${settings.longPressSpeed}x";
    unawaited(_requestPlaybackSpeed(controller, settings.longPressSpeed));
    return true;
  }

  void _endLongPressSpeed() {
    if (!_isLongPressing) return;
    final controller = _controller;
    _isLongPressing = false;
    if (controller == null) return;
    unawaited(_requestPlaybackSpeed(controller, _preLongPressSpeed));
  }

  Future<void> _requestPlaybackSpeed(
    VideoPlayerController controller,
    double speed,
  ) async {
    if (!speed.isFinite || speed <= 0) return;
    final requestId = ++_playbackSpeedRequestId;
    // ignore: invalid_use_of_visible_for_testing_member
    NativeVideoPlayerMediaKit.cancelPendingRateChange(controller.playerId);
    final previousCommand = _playbackSpeedCommandTail;
    final command = () async {
      try {
        await previousCommand;
      } catch (_) {}
      if (requestId != _playbackSpeedRequestId || controller != _controller) {
        return;
      }
      try {
        if ((_lastDispatchedPlaybackSpeed - speed).abs() >= 0.001) {
          _lastDispatchedPlaybackSpeed = speed;
          await controller.setPlaybackSpeed(speed);
        }
        if (requestId != _playbackSpeedRequestId || controller != _controller) {
          return;
        }
        _confirmedPlaybackSpeed = speed;
      } catch (_) {
        _lastDispatchedPlaybackSpeed = _confirmedPlaybackSpeed;
        rethrow;
      }
    }();
    _playbackSpeedCommandTail = command.catchError((Object _) {});
    await command;
  }

  @override
  Widget build(BuildContext context) {
    if (_errorMessage != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                color: Colors.redAccent,
                size: 64,
              ),
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              ElevatedButton(onPressed: _exitPreview, child: const Text("返回")),
            ],
          ),
        ),
      );
    }

    if (!_isReady || _controller == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final settings = Provider.of<SettingsService>(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_exitPreview());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: _controller!.value.aspectRatio,
                child: VideoPlayer(_controller!),
              ),
            ),
            VideoControlsOverlay(
              controller: _controller!,
              isLocked: _isLocked,
              mediaTitle: widget.title,
              isPreviewMode: true,
              focusNode: _videoFocusNode,
              onTogglePlay: _togglePlayPause,
              onBackPressed: _exitPreview,
              onExitPressed: _exitPreview,
              onToggleLock: () {
                setState(() {
                  _isLocked = !_isLocked;
                });
              },
              onToggleSidebar: null,
              isSubtitleSidebarVisible: false,
              onOpenSettings: null,
              onOpenSubtitleManager: null,
              onOpenSubtitleEditor: null,
              onToggleFloatingSubtitleSettings: null,
              onOpenVideoCompose: null,
              onToggleEpisodePicker: null,
              onToggleFullScreen: null,
              onSpeedUpdate: (speed) =>
                  _requestPlaybackSpeed(_controller!, speed),
              doubleTapSeekSeconds: settings.doubleTapSeekSeconds,
              enableDoubleTapSubtitleSeek: false,
              showSubtitles: false,
              onToggleSubtitles: () {},
              onMoveSubtitles: () {},
              subtitles: const [],
              subtitleEntries: const [],
              subtitleStyle: const SubtitleStyle(),
              subtitleAlignment: Alignment.bottomCenter,
              onEnterSubtitleDragMode: () {},
              isLongPressing: _isLongPressing,
              longPressFeedbackText: _longPressFeedbackText,
              onLongPressStart: _startLongPressSpeed,
              onLongPressEnd: _endLongPressSpeed,
              showPlayControls: true,
              showBottomBar: true,
            ),
          ],
        ),
      ),
    );
  }
}
