import 'subtitle_output_path_strategy.dart';
import 'transcription_status.dart';

class BatchSubtitleTaskView {
  final String mediaKey;
  final String videoPath;
  final String? videoId;
  final String videoName;
  final String videoDuration;
  final bool isExternal;
  final TranscriptionStatus status;
  final double progress;
  final String statusMessage;
  final int createdAt;
  final SubtitleOutputPathStrategy? outputPathStrategy;
  final String? customOutputDir;
  final bool isStarted;

  const BatchSubtitleTaskView({
    required this.mediaKey,
    required this.videoPath,
    this.videoId,
    required this.videoName,
    required this.videoDuration,
    required this.isExternal,
    required this.status,
    required this.progress,
    this.statusMessage = '',
    required this.createdAt,
    this.outputPathStrategy,
    this.customOutputDir,
    this.isStarted = false,
  });

  BatchSubtitleTaskView copyWith({
    String? mediaKey,
    String? videoPath,
    String? videoId,
    String? videoName,
    String? videoDuration,
    bool? isExternal,
    TranscriptionStatus? status,
    double? progress,
    String? statusMessage,
    int? createdAt,
    SubtitleOutputPathStrategy? outputPathStrategy,
    String? customOutputDir,
    bool? isStarted,
  }) {
    return BatchSubtitleTaskView(
      mediaKey: mediaKey ?? this.mediaKey,
      videoPath: videoPath ?? this.videoPath,
      videoId: videoId ?? this.videoId,
      videoName: videoName ?? this.videoName,
      videoDuration: videoDuration ?? this.videoDuration,
      isExternal: isExternal ?? this.isExternal,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      statusMessage: statusMessage ?? this.statusMessage,
      createdAt: createdAt ?? this.createdAt,
      outputPathStrategy: outputPathStrategy ?? this.outputPathStrategy,
      customOutputDir: customOutputDir ?? this.customOutputDir,
      isStarted: isStarted ?? this.isStarted,
    );
  }
}