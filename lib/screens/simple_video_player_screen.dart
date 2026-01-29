import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../models/video_item.dart';
import '../services/media_playback_service.dart';

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
  bool _requestedPlay = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startPlaybackIfNeeded();
    });
  }

  @override
  void dispose() {
    try {
      final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
      if (playbackService.currentItem?.id == widget.videoPath) {
        playbackService.stop();
      }
    } catch (_) {}
    super.dispose();
  }

  Future<void> _startPlaybackIfNeeded() async {
    if (_requestedPlay) return;
    _requestedPlay = true;

    final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
    final file = File(widget.videoPath);
    if (!await file.exists()) {
      if (!mounted) return;
      setState(() {
        _errorMessage = "媒体文件不存在，可能已被移动或删除";
      });
      return;
    }

    final item = VideoItem(
      id: widget.videoPath,
      path: widget.videoPath,
      title: widget.title,
      durationMs: 0,
      lastUpdated: DateTime.now().millisecondsSinceEpoch,
      type: MediaType.video,
    );

    await playbackService.play(item);
    if (!mounted) return;
    if (playbackService.state == PlaybackState.error || playbackService.controller == null) {
      setState(() {
        _errorMessage = "播放失败：无法加载该媒体";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.title, style: const TextStyle(fontSize: 14)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Center(
        child: Consumer<MediaPlaybackService>(
          builder: (context, playbackService, child) {
            final errorMessage = _errorMessage;
            if (errorMessage != null) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, color: Colors.redAccent, size: 64),
                    const SizedBox(height: 12),
                    Text(
                      errorMessage,
                      style: const TextStyle(color: Colors.white70),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      child: const Text("返回"),
                    ),
                  ],
                ),
              );
            }

            final controller = playbackService.controller;
            final isCurrent = playbackService.currentItem?.id == widget.videoPath;
            final isReady = isCurrent && controller != null && controller.value.isInitialized;

            if (!isReady) return const CircularProgressIndicator();

            return AspectRatio(
              aspectRatio: controller.value.aspectRatio,
              child: VideoPlayer(controller),
            );
          },
        ),
      ),
      bottomSheet: Consumer<MediaPlaybackService>(
        builder: (context, playbackService, child) {
          final controller = playbackService.controller;
          final isCurrent = playbackService.currentItem?.id == widget.videoPath;
          final isReady = isCurrent && controller != null && controller.value.isInitialized;
          if (!isReady) return const SizedBox.shrink();
          return _buildProgressBar(controller);
        },
      ),
    );
  }

  Widget _buildProgressBar(VideoPlayerController controller) {
    return Container(
      color: Colors.black54,
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: VideoProgressIndicator(
        controller,
        allowScrubbing: true,
        colors: const VideoProgressColors(
          playedColor: Colors.pinkAccent,
          bufferedColor: Colors.white24,
          backgroundColor: Colors.grey,
        ),
      ),
    );
  }
}
