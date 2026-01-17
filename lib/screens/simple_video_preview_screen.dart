import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class SimpleVideoPreviewScreen extends StatefulWidget {
  final String videoPath;

  const SimpleVideoPreviewScreen({super.key, required this.videoPath});

  @override
  State<SimpleVideoPreviewScreen> createState() => _SimpleVideoPreviewScreenState();
}

class _SimpleVideoPreviewScreenState extends State<SimpleVideoPreviewScreen> {
  late VideoPlayerController _controller;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.videoPath))
      ..initialize().then((_) {
        setState(() {
          _initialized = true;
          _controller.play();
        });
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
        child: _initialized
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AspectRatio(
                    aspectRatio: _controller.value.aspectRatio,
                    child: VideoPlayer(_controller),
                  ),
                  const SizedBox(height: 20),
                  VideoProgressIndicator(
                    _controller,
                    allowScrubbing: true,
                    colors: const VideoProgressColors(
                      playedColor: Colors.redAccent,
                      backgroundColor: Colors.white24,
                    ),
                  ),
                  const SizedBox(height: 20),
                  IconButton(
                    icon: Icon(
                      _controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
                      color: Colors.white,
                      size: 48,
                    ),
                    onPressed: () {
                      setState(() {
                        if (_controller.value.isPlaying) {
                          _controller.pause();
                        } else {
                          _controller.play();
                        }
                      });
                    },
                  ),
                ],
              )
            : const CircularProgressIndicator(),
      ),
    );
  }
}
