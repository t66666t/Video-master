import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import '../models/transcription_status.dart';

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
  bool _hasRequestedForCurrentVideo = false;
  TranscriptionStatus? _terminalStatusForCurrentVideo;
  String _terminalMessageForCurrentVideo = "";

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
    final srtPath = manager.getGeneratedSrtPathForVideo(
      widget.videoPath,
      videoId: widget.videoId,
    );
    if (srtPath != null &&
        manager.consumeResultNotificationForVideo(
          widget.videoPath,
          videoId: widget.videoId,
        )) {
      _terminalStatusForCurrentVideo = TranscriptionStatus.completed;
      _terminalMessageForCurrentVideo = "转录完成";
      widget.onCompleted(srtPath);
    }
  }

  Future<void> _startTranscription() async {
    final manager = Provider.of<TranscriptionManager>(context, listen: false);
    final settings = Provider.of<SettingsService>(context, listen: false);
    final library = Provider.of<LibraryService>(context, listen: false);

    try {
      if (mounted) {
        setState(() {
          _hasRequestedForCurrentVideo = true;
          _terminalStatusForCurrentVideo = null;
          _terminalMessageForCurrentVideo = "";
        });
      }
      await manager.startTranscription(
        widget.videoPath,
        videoId: widget.videoId,
        libraryService: library,
        autoCache: settings.autoCacheSubtitles,
        autoStart: true,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _terminalStatusForCurrentVideo = TranscriptionStatus.error;
          _terminalMessageForCurrentVideo = "启动转录失败: $e";
        });
      }
      // Error is handled in manager state
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<TranscriptionManager>(
      builder: (context, manager, child) {
        final bool samePath = manager.currentVideoPath == widget.videoPath;
        final String? trimmedVideoId = widget.videoId?.trim();
        final bool sameVideoId =
            trimmedVideoId == null ||
            trimmedVideoId.isEmpty ||
            manager.currentVideoId == trimmedVideoId;
        final bool isJobForThisVideo = samePath && sameVideoId;
        final bool isProcessing = manager.isVideoRunning(
          widget.videoPath,
          videoId: widget.videoId,
        );
        final bool isQueued = manager.isVideoQueued(
          widget.videoPath,
          videoId: widget.videoId,
        );
        final bool isBusyWithOther = manager.isProcessing && !isJobForThisVideo;
        final bool hasGeneratedSrt =
            manager.getGeneratedSrtPathForVideo(
              widget.videoPath,
              videoId: widget.videoId,
            ) !=
            null;
        final int pendingCount = manager.pendingCount;
        final int processingCount = manager.processingCount;
        final int queueCount = manager.queuedCount;
        final int queuePosition = manager.queuePositionForVideo(
          widget.videoPath,
          videoId: widget.videoId,
        );
        final bool canQueueCurrentVideo = !isProcessing && !isQueued;
        final String actionLabel = isProcessing
            ? "转录中..."
            : isQueued
            ? "已加入队列"
            : (manager.status == TranscriptionStatus.completed &&
                      isJobForThisVideo
                  ? "重新转录"
                  : (isBusyWithOther ? "加入队列" : "开始智能转录"));

        return Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            if (event is KeyRepeatEvent) return KeyEventResult.handled;
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.escape) {
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
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    if (isProcessing)
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.blueAccent,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blueGrey.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.blueGrey.withValues(alpha: 0.45),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        "后台转录队列",
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        "处理中 $processingCount / 排队 $queueCount / 总计 $pendingCount",
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  "使用 Bilibili 接口进行云端语音转文字。\n支持中英文识别，速度快，准确率高。",
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 14),
                ElevatedButton.icon(
                  onPressed: canQueueCurrentVideo ? _startTranscription : null,
                  icon: const Icon(Icons.auto_awesome),
                  label: Text(actionLabel),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
                const SizedBox(height: 12),
                _buildInlineProgressSection(
                  manager: manager,
                  isJobForThisVideo: isJobForThisVideo,
                  isProcessing: isProcessing,
                  isQueued: isQueued,
                  hasGeneratedSrt: hasGeneratedSrt,
                  queuePosition: queuePosition,
                  canQueueCurrentVideo: canQueueCurrentVideo,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildInlineProgressSection({
    required TranscriptionManager manager,
    required bool isJobForThisVideo,
    required bool isProcessing,
    required bool isQueued,
    required bool hasGeneratedSrt,
    required int queuePosition,
    required bool canQueueCurrentVideo,
  }) {
    if (isQueued) {
      final String queueText = queuePosition > 0
          ? "已加入队列，当前顺位：$queuePosition"
          : "已加入队列，等待处理中";
      return _buildStatusCard(
        icon: Icons.queue,
        borderColor: Colors.orange.withValues(alpha: 0.5),
        bgColor: Colors.orange.withValues(alpha: 0.12),
        title: "排队中",
        message: queueText,
      );
    }

    if (isProcessing && isJobForThisVideo) {
      final double progress = manager.progress.clamp(0.0, 1.0);
      final String message = manager.statusMessage.trim().isEmpty
          ? "正在处理，请稍候..."
          : manager.statusMessage;
      return _buildProgressCard(progress: progress, statusMessage: message);
    }

    if (manager.status == TranscriptionStatus.error && isJobForThisVideo) {
      _terminalStatusForCurrentVideo = TranscriptionStatus.error;
      _terminalMessageForCurrentVideo = manager.statusMessage.trim().isEmpty
          ? "转录失败"
          : manager.statusMessage;
    }

    if (hasGeneratedSrt) {
      _terminalStatusForCurrentVideo = TranscriptionStatus.completed;
      if (_terminalMessageForCurrentVideo.trim().isEmpty) {
        _terminalMessageForCurrentVideo = "转录完成，可直接使用生成字幕";
      }
    }

    if (_terminalStatusForCurrentVideo == TranscriptionStatus.completed) {
      return _buildStatusCard(
        icon: Icons.check_circle,
        borderColor: Colors.green.withValues(alpha: 0.5),
        bgColor: Colors.green.withValues(alpha: 0.12),
        title: "处理完成",
        message: _terminalMessageForCurrentVideo,
      );
    }

    if (_terminalStatusForCurrentVideo == TranscriptionStatus.error) {
      return _buildStatusCard(
        icon: Icons.error,
        borderColor: Colors.redAccent.withValues(alpha: 0.5),
        bgColor: Colors.redAccent.withValues(alpha: 0.12),
        title: "处理失败",
        message: _terminalMessageForCurrentVideo,
      );
    }

    if (_hasRequestedForCurrentVideo && !canQueueCurrentVideo) {
      return _buildStatusCard(
        icon: Icons.info_outline,
        borderColor: Colors.blueGrey.withValues(alpha: 0.5),
        bgColor: Colors.blueGrey.withValues(alpha: 0.15),
        title: "任务状态",
        message: "任务状态同步中，请稍候...",
      );
    }

    return _buildStatusCard(
      icon: Icons.tips_and_updates_outlined,
      borderColor: Colors.blueGrey.withValues(alpha: 0.35),
      bgColor: Colors.blueGrey.withValues(alpha: 0.1),
      title: "提示",
      message: "点击“开始智能转录”后，将在此处持续显示处理进度与状态。",
    );
  }

  Widget _buildProgressCard({
    required double progress,
    required String statusMessage,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.sync, size: 16, color: Colors.blueAccent),
              const SizedBox(width: 6),
              const Text(
                "处理中",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                "${(progress * 100).toStringAsFixed(0)}%",
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: progress,
            minHeight: 6,
            backgroundColor: Colors.white10,
            valueColor: const AlwaysStoppedAnimation<Color>(Colors.blueAccent),
            borderRadius: BorderRadius.circular(999),
          ),
          const SizedBox(height: 10),
          Text(
            statusMessage,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard({
    required IconData icon,
    required Color borderColor,
    required Color bgColor,
    required String title,
    required String message,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.white70, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
