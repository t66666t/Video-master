import 'package:flutter/material.dart';
import 'subtitle_style.dart';

enum VideoComposeStage {
  queued,
  preparing,
  rendering,
  finalizing,
  completed,
  failed,
}

enum VideoComposeResolution { source, p360, p480, p720, p1080, p1440, p2160 }

class VideoComposeSoftSubtitleTrack {
  final String path;
  final String title;

  const VideoComposeSoftSubtitleTrack({
    required this.path,
    required this.title,
  });

  Map<String, dynamic> toJson() {
    return {
      'path': path,
      'title': title,
    };
  }

  factory VideoComposeSoftSubtitleTrack.fromJson(Map<String, dynamic> json) {
    return VideoComposeSoftSubtitleTrack(
      path: json['path'] as String? ?? '',
      title: json['title'] as String? ?? '',
    );
  }
}

class VideoComposeRequest {
  final String videoId;
  final String videoPath;
  final String title;
  final String? primarySubtitlePath;
  final String? secondarySubtitlePath;
  final bool renderSecondarySubtitle;
  final bool continuousSubtitle;
  final bool embedSoftSubtitles;
  final bool softSubtitleOnly;
  final bool softSubtitleUseSourceQuality;
  final List<VideoComposeSoftSubtitleTrack> softSubtitleTracks;
  final VideoComposeResolution resolution;
  final SubtitleStyle subtitleStyle;
  final Alignment subtitleAlignment;
  final String outputPath;

  const VideoComposeRequest({
    required this.videoId,
    required this.videoPath,
    required this.title,
    this.primarySubtitlePath,
    this.secondarySubtitlePath,
    required this.renderSecondarySubtitle,
    required this.continuousSubtitle,
    required this.embedSoftSubtitles,
    required this.softSubtitleOnly,
    required this.softSubtitleUseSourceQuality,
    required this.softSubtitleTracks,
    required this.resolution,
    required this.subtitleStyle,
    required this.subtitleAlignment,
    required this.outputPath,
  });

  Map<String, dynamic> toJson() {
    return {
      'videoId': videoId,
      'videoPath': videoPath,
      'title': title,
      'primarySubtitlePath': primarySubtitlePath,
      'secondarySubtitlePath': secondarySubtitlePath,
      'renderSecondarySubtitle': renderSecondarySubtitle,
      'continuousSubtitle': continuousSubtitle,
      'embedSoftSubtitles': embedSoftSubtitles,
      'softSubtitleOnly': softSubtitleOnly,
      'softSubtitleUseSourceQuality': softSubtitleUseSourceQuality,
      'softSubtitleTracks': softSubtitleTracks.map((e) => e.toJson()).toList(),
      'resolution': resolution.index,
      'subtitleStyle': subtitleStyle.toJson(),
      'subtitleAlignmentX': subtitleAlignment.x,
      'subtitleAlignmentY': subtitleAlignment.y,
      'outputPath': outputPath,
    };
  }

  factory VideoComposeRequest.fromJson(Map<String, dynamic> json) {
    return VideoComposeRequest(
      videoId: json['videoId'] as String? ?? '',
      videoPath: json['videoPath'] as String? ?? '',
      title: json['title'] as String? ?? 'Unknown',
      primarySubtitlePath: json['primarySubtitlePath'] as String?,
      secondarySubtitlePath: json['secondarySubtitlePath'] as String?,
      renderSecondarySubtitle: json['renderSecondarySubtitle'] as bool? ?? true,
      continuousSubtitle: json['continuousSubtitle'] as bool? ?? false,
      embedSoftSubtitles: json['embedSoftSubtitles'] as bool? ?? false,
      softSubtitleOnly: json['softSubtitleOnly'] as bool? ?? false,
      softSubtitleUseSourceQuality:
          json['softSubtitleUseSourceQuality'] as bool? ?? true,
      softSubtitleTracks:
          (json['softSubtitleTracks'] as List<dynamic>? ?? const <dynamic>[])
              .map(
                (e) => VideoComposeSoftSubtitleTrack.fromJson(
                  e as Map<String, dynamic>,
                ),
              )
              .toList(),
      resolution: VideoComposeResolution.values[(json['resolution'] as int?) ?? 0],
      subtitleStyle: json['subtitleStyle'] != null ? SubtitleStyle.fromJson(json['subtitleStyle']) : const SubtitleStyle(),
      subtitleAlignment: Alignment(
        (json['subtitleAlignmentX'] as num?)?.toDouble() ?? 0.0,
        (json['subtitleAlignmentY'] as num?)?.toDouble() ?? 0.8,
      ),
      outputPath: json['outputPath'] as String? ?? '',
    );
  }
}

class VideoComposeTaskState {
  final String taskId;
  final VideoComposeRequest request;
  final DateTime createdAt;
  final DateTime? completedAt;
  final VideoComposeStage stage;
  final double progress;
  final String message;
  final String? error;

  const VideoComposeTaskState({
    required this.taskId,
    required this.request,
    required this.createdAt,
    this.completedAt,
    required this.stage,
    required this.progress,
    required this.message,
    this.error,
  });

  VideoComposeTaskState copyWith({
    VideoComposeStage? stage,
    double? progress,
    String? message,
    String? error,
    DateTime? completedAt,
  }) {
    return VideoComposeTaskState(
      taskId: taskId,
      request: request,
      createdAt: createdAt,
      completedAt: completedAt ?? this.completedAt,
      stage: stage ?? this.stage,
      progress: progress ?? this.progress,
      message: message ?? this.message,
      error: error,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'taskId': taskId,
      'request': request.toJson(),
      'createdAt': createdAt.millisecondsSinceEpoch,
      'completedAt': completedAt?.millisecondsSinceEpoch,
      'stage': stage.index,
      'progress': progress,
      'message': message,
      'error': error,
    };
  }

  factory VideoComposeTaskState.fromJson(Map<String, dynamic> json) {
    return VideoComposeTaskState(
      taskId: json['taskId'] as String? ?? '',
      request: VideoComposeRequest.fromJson(json['request'] as Map<String, dynamic>? ?? {}),
      createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int? ?? 0),
      completedAt: json['completedAt'] != null ? DateTime.fromMillisecondsSinceEpoch(json['completedAt'] as int) : null,
      stage: VideoComposeStage.values[(json['stage'] as int?) ?? 0],
      progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
      message: json['message'] as String? ?? '',
      error: json['error'] as String?,
    );
  }
}
