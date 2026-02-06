import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import '../services/transcription_manager.dart';

class AiTranscriptionPanel extends StatefulWidget {
  final String videoPath;
  final Function(String path) onCompleted;

  final String? videoId;
  final VoidCallback? onBack;

  const AiTranscriptionPanel({
    super.key,
    required this.videoPath,
    required this.onCompleted,
    this.videoId,
    this.onBack,
  });

  @override
  State<AiTranscriptionPanel> createState() => _AiTranscriptionPanelState();
}

class _AiTranscriptionPanelState extends State<AiTranscriptionPanel> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final manager = Provider.of<TranscriptionManager>(context, listen: false);
      manager.addListener(_onManagerUpdate);
      _checkCompletion(manager);
    });
  }

  @override
  void dispose() {
    final manager = Provider.of<TranscriptionManager>(context, listen: false);
    manager.removeListener(_onManagerUpdate);
    super.dispose();
  }

  void _onManagerUpdate() {
    if (!mounted) return;
    final manager = Provider.of<TranscriptionManager>(context, listen: false);
    _checkCompletion(manager);
  }

  void _checkCompletion(TranscriptionManager manager) {
    if (manager.currentVideoPath == widget.videoPath && 
        manager.status == TranscriptionStatus.completed && 
        manager.lastGeneratedSrtPath != null) {
      // 只有当状态刚好是 completed 时才回调
      // 这里的逻辑可能需要防抖，或者由 manager 提供一个一次性的事件流
      // 不过由于 UI 刷新频率，这里简单判重即可
      // 实际上 onCompleted 可能会导致父组件 setState，从而重建这个组件
      // 所以我们最好只触发一次。
      // 但这里为了简单，交给父组件去处理重复加载的问题。
      widget.onCompleted(manager.lastGeneratedSrtPath!);
    }
  }

  Future<void> _startTranscription() async {
    final manager = Provider.of<TranscriptionManager>(context, listen: false);
    final settings = Provider.of<SettingsService>(context, listen: false);
    final library = Provider.of<LibraryService>(context, listen: false);
    
    try {
      await manager.startTranscription(
        widget.videoPath,
        videoId: widget.videoId,
        libraryService: library,
        autoCache: settings.autoCacheSubtitles
      );
    } catch (e) {
      // Error is handled in manager state
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<TranscriptionManager>(
      builder: (context, manager, child) {
        final bool isJobForThisVideo = manager.currentVideoPath == widget.videoPath;
        final bool isBusyWithOther = manager.isProcessing && !isJobForThisVideo;
        final bool isProcessing = manager.isProcessing && isJobForThisVideo;

        return Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            if (event is KeyRepeatEvent) return KeyEventResult.handled;
            if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
              widget.onBack?.call();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              color: Color(0xFF1E1E1E),
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      tooltip: "返回",
                      onPressed: widget.onBack,
                    ),
                    const SizedBox(width: 4),
                    const Expanded(
                      child: Text(
                        "AI 智能字幕 (B接口)",
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                    ),
                    if (isProcessing)
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blueAccent),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                if (isBusyWithOther) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.orange.withValues(alpha: 0.5)),
                    ),
                    child: Column(
                      children: [
                        const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 32),
                        const SizedBox(height: 8),
                        const Text(
                          "后台正在转录另一个视频",
                          style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ] else if (isProcessing) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      children: [
                        LinearProgressIndicator(
                          value: manager.progress,
                          backgroundColor: Colors.white10,
                          valueColor: const AlwaysStoppedAnimation<Color>(Colors.blueAccent),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          manager.statusMessage,
                          style: const TextStyle(color: Colors.white),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          "${(manager.progress * 100).toInt()}%",
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    "转录将在后台进行，您可以关闭此面板继续观看视频。",
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ] else ...[
                  const Text(
                    "使用 Bilibili 接口进行云端语音转文字。\n支持中英文识别，速度快，准确率高。",
                    style: TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 20),
                  if (manager.status == TranscriptionStatus.error && isJobForThisVideo)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: Text(
                        manager.statusMessage,
                        style: const TextStyle(color: Colors.redAccent),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  if (manager.status == TranscriptionStatus.completed && isJobForThisVideo)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(Icons.check_circle, color: Colors.green),
                          SizedBox(width: 8),
                          Text(
                            "转录完成！",
                            style: TextStyle(color: Colors.green),
                          ),
                        ],
                      ),
                    ),
                  ElevatedButton.icon(
                    onPressed: _startTranscription,
                    icon: const Icon(Icons.auto_awesome),
                    label: Text(
                      manager.status == TranscriptionStatus.completed && isJobForThisVideo
                          ? "重新转录"
                          : "开始智能转录",
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
