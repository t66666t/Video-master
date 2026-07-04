import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../services/media_playback_service.dart';
import '../services/settings_service.dart';
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
  State<SimpleVideoPlayerScreen> createState() => _SimpleVideoPlayerScreenState();
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
  final FocusNode _videoFocusNode = FocusNode();

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
    _restoreSystemUiImmediately();
    _controller?.dispose();
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
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
    ));
  }

  Future<void> _exitPreview() async {
    if (_isExiting) return;
    _isExiting = true;
    _restoreSystemUiImmediately();
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }
    _isExiting = false;
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
      if (playbackService.currentItem != null &&
          playbackService.state != PlaybackState.idle) {
        await playbackService.stop();
      }
      if (!mounted) return;
      final settings = Provider.of<SettingsService>(context, listen: false);
      _controller = VideoPlayerController.file(
        file,
        videoPlayerOptions: MediaPlaybackService.buildVideoPlayerOptions(
          settings: settings,
        ),
      );
      await _controller!.initialize();
      final targetSpeed = settings.effectiveGlobalPlaybackSpeed;
      if (!settings.isSamePlaybackSpeed(
        _controller!.value.playbackSpeed,
        targetSpeed,
      )) {
        await _controller!.setPlaybackSpeed(targetSpeed);
      }
      _controller!.addListener(_onPlayerStateChanged);
      
      if (!mounted) return;
      setState(() {
        _isReady = true;
      });
      _controller!.play();
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

  void _startLongPressSpeed() {
    final controller = _controller;
    if (controller == null) return;
    final settings = Provider.of<SettingsService>(context, listen: false);
    _preLongPressSpeed = controller.value.playbackSpeed;
    setState(() {
      _isLongPressing = true;
      _longPressFeedbackText = "${settings.longPressSpeed}x";
    });
    controller.setPlaybackSpeed(settings.longPressSpeed);
  }

  void _endLongPressSpeed() {
    if (!_isLongPressing) return;
    final controller = _controller;
    setState(() {
      _isLongPressing = false;
    });
    if (controller == null) return;
    controller.setPlaybackSpeed(_preLongPressSpeed);
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
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 64),
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _exitPreview,
                child: const Text("返回"),
              ),
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
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) return;
        _isExiting = false;
        _restoreSystemUiImmediately();
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
              onSpeedUpdate: (speed) {
                _controller!.setPlaybackSpeed(speed);
              },
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
