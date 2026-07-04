import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../models/video_item.dart';
import '../services/media_playback_service.dart';

class SimpleVideoPreviewScreen extends StatefulWidget {
  final String videoPath;

  const SimpleVideoPreviewScreen({super.key, required this.videoPath});

  @override
  State<SimpleVideoPreviewScreen> createState() => _SimpleVideoPreviewScreenState();
}

class _SimpleVideoPreviewScreenState extends State<SimpleVideoPreviewScreen> {
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
    final title = p.basename(widget.videoPath);

    final item = VideoItem(
      id: widget.videoPath,
      path: widget.videoPath,
      title: title,
      durationMs: 0,
      lastUpdated: DateTime.now().millisecondsSinceEpoch,
      type: MediaType.video,
    );

    if (!await file.exists()) {
      if (!mounted) return;
      setState(() {
        _errorMessage = "媒体文件不存在，可能已被移动或删除";
      });
      return;
    }
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
        title: const Text("视频预览"),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
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

            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AspectRatio(
                  aspectRatio: controller.value.aspectRatio,
                  child: VideoPlayer(controller),
                ),
                const SizedBox(height: 20),
                VideoProgressIndicator(
                  controller,
                  allowScrubbing: true,
                  colors: const VideoProgressColors(
                    playedColor: Colors.redAccent,
                    backgroundColor: Colors.white24,
                  ),
                ),
                const SizedBox(height: 20),
                IconButton(
                  icon: Icon(
                    controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                    size: 48,
                  ),
                  onPressed: () async {
                    if (controller.value.isPlaying) {
                      await playbackService.pause();
                    } else {
                      await playbackService.resume();
                    }
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
