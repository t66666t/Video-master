import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

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
        title: Text(widget.title, style: const TextStyle(fontSize: 14)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Center(
        child: _initialized
            ? AspectRatio(
                aspectRatio: _controller.value.aspectRatio,
                child: VideoPlayer(_controller),
              )
            : const CircularProgressIndicator(),
      ),
      bottomSheet: _initialized ? _buildProgressBar() : null,
    );
  }

  Widget _buildProgressBar() {
    return Container(
      color: Colors.black54,
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: VideoProgressIndicator(
        _controller,
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
