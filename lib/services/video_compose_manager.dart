import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/subtitle_style.dart';
import '../models/video_compose_models.dart';
import 'video_compose/video_compose_artifact_cleaner.dart';
import 'video_compose/video_compose_ass_renderer.dart';
import 'video_compose/video_compose_executor.dart';
import 'video_compose/video_compose_font_service.dart';
import 'video_compose/video_compose_orchestrator.dart';
import 'video_compose/video_compose_output_path_service.dart';
import 'video_compose/video_compose_probe_service.dart';
import 'video_compose/video_compose_precise_renderer.dart';
import 'video_compose/video_compose_subtitle_service.dart';
import 'video_compose/video_compose_task_store.dart';

class VideoComposeManager extends ChangeNotifier {
  final List<String> _queueTaskIds = <String>[];
  final Map<String, VideoComposeTaskState> _taskMap =
      <String, VideoComposeTaskState>{};
  final VideoComposeTaskStore _taskStore;
  final VideoComposeArtifactCleaner _artifactCleaner;
  final VideoComposeOutputPathService _outputPathService;
  final VideoComposeOrchestrator _orchestrator;

  String? _runningTaskId;
  bool _isProcessing = false;

  factory VideoComposeManager({
    VideoComposeTaskStore? taskStore,
    VideoComposeArtifactCleaner? artifactCleaner,
    VideoComposeOutputPathService? outputPathService,
    VideoComposeProbeService? probeService,
    VideoComposeSubtitleService? subtitleService,
    VideoComposeFontService? fontService,
    VideoComposeExecutor? executor,
    VideoComposeOrchestrator? orchestrator,
  }) {
    final VideoComposeFontService resolvedFontService =
        fontService ?? VideoComposeFontService();
    return VideoComposeManager._internal(
      taskStore: taskStore ?? const VideoComposeTaskStore(),
      artifactCleaner: artifactCleaner ?? VideoComposeArtifactCleaner(),
      outputPathService:
          outputPathService ?? const VideoComposeOutputPathService(),
      orchestrator:
          orchestrator ??
          VideoComposeOrchestrator(
            probeService: probeService ?? const VideoComposeProbeService(),
            subtitleService:
                subtitleService ?? const VideoComposeSubtitleService(),
            assRenderer: VideoComposeAssRenderer(resolvedFontService),
            preciseRenderer: VideoComposePreciseRenderer(),
            fontService: resolvedFontService,
            executor: executor ?? VideoComposeExecutor(),
            outputPathService:
                outputPathService ?? const VideoComposeOutputPathService(),
          ),
    );
  }

  VideoComposeManager._internal({
    required VideoComposeTaskStore taskStore,
    required VideoComposeArtifactCleaner artifactCleaner,
    required VideoComposeOutputPathService outputPathService,
    required VideoComposeOrchestrator orchestrator,
  }) : _taskStore = taskStore,
       _artifactCleaner = artifactCleaner,
       _outputPathService = outputPathService,
       _orchestrator = orchestrator {
    _loadTasks();
  }

  Future<void> _loadTasks() async {
    final List<VideoComposeTaskState> storedTasks = await _taskStore
        .loadTasks();
    for (final VideoComposeTaskState state in storedTasks) {
      if (_isIncompleteStage(state.stage)) {
        _taskMap[state.taskId] = state.copyWith(
          stage: VideoComposeStage.failed,
          message: '应用重启，任务已中断',
          completedAt: DateTime.now(),
        );
      } else {
        _taskMap[state.taskId] = state;
      }
    }
    notifyListeners();
  }

  bool _isIncompleteStage(VideoComposeStage stage) {
    return stage == VideoComposeStage.queued ||
        stage == VideoComposeStage.preparing ||
        stage == VideoComposeStage.rendering ||
        stage == VideoComposeStage.finalizing;
  }

  Future<void> _saveTasks() {
    return _taskStore.saveTasks(_taskMap.values);
  }

  Future<bool> deleteTaskAndFile(
    String taskId, {
    bool deleteOutput = true,
  }) async {
    final VideoComposeTaskState? task = _taskMap[taskId];
    if (task == null) return !deleteOutput;
    final bool isRunningTask = _runningTaskId == taskId;
    _queueTaskIds.remove(taskId);
    if (isRunningTask) {
      await _orchestrator.cancelRunningCompose();
    }
    final bool outputDeleted = await _artifactCleaner.cleanupTaskArtifacts(
      taskId,
      deleteOutput: deleteOutput,
      outputPath: task.request.outputPath,
    );
    if (deleteOutput && !outputDeleted) {
      if (isRunningTask) {
        _runningTaskId = null;
      }
      notifyListeners();
      await _saveTasks();
      if (!_isProcessing && _queueTaskIds.isNotEmpty) {
        unawaited(_processQueue());
      }
      return false;
    }
    _taskMap.remove(taskId);
    if (isRunningTask) {
      _runningTaskId = null;
    }
    notifyListeners();
    await _saveTasks();
    if (!_isProcessing && _queueTaskIds.isNotEmpty) {
      unawaited(_processQueue());
    }
    return outputDeleted;
  }

  List<VideoComposeTaskState> get allTasks {
    final List<VideoComposeTaskState> list = _taskMap.values.toList()
      ..sort(
        (VideoComposeTaskState a, VideoComposeTaskState b) =>
            b.createdAt.compareTo(a.createdAt),
      );
    return List.unmodifiable(list);
  }

  List<VideoComposeTaskState> get queuedTasks {
    final List<VideoComposeTaskState> list = _queueTaskIds
        .map((String id) => _taskMap[id])
        .whereType<VideoComposeTaskState>()
        .toList();
    return List.unmodifiable(list);
  }

  VideoComposeTaskState? get runningTask {
    if (_runningTaskId == null) return null;
    return _taskMap[_runningTaskId!];
  }

  int get pendingCount =>
      _queueTaskIds.length + (_runningTaskId == null ? 0 : 1);

  VideoComposeTaskState? latestTaskForVideo(String videoId) {
    VideoComposeTaskState? hit;
    for (final task in _taskMap.values) {
      if (task.request.videoId != videoId) continue;
      if (hit == null || task.createdAt.isAfter(hit.createdAt)) {
        hit = task;
      }
    }
    return hit;
  }

  Future<String?> getSourceResolutionLabel(String videoPath) async {
    return _orchestrator.getSourceResolutionLabel(videoPath);
  }

  Future<VideoComposeTaskState> enqueue({
    required String videoId,
    required String videoPath,
    required String title,
    required String? primarySubtitlePath,
    required String? secondarySubtitlePath,
    required bool renderSecondarySubtitle,
    required bool continuousSubtitle,
    required bool embedSoftSubtitles,
    required bool softSubtitleOnly,
    required bool softSubtitleUseSourceQuality,
    required List<VideoComposeSoftSubtitleTrack> softSubtitleTracks,
    required VideoComposeResolution resolution,
    required VideoComposeRenderMode renderMode,
    required SubtitleStyle subtitleStyle,
    required SubtitleStyle subtitleStylePortrait,
    required Alignment subtitleAlignment,
    required bool splitSubtitleByLine,
    String? customOutputPath,
  }) async {
    final String outputPath;
    if (customOutputPath != null && customOutputPath.isNotEmpty) {
      final String fileName = _outputPathService.buildOutputFileName(title);
      outputPath = p.join(customOutputPath, fileName);
    } else {
      outputPath = await _outputPathService.buildOutputPath(title);
    }
    final VideoComposeRequest request = VideoComposeRequest(
      videoId: videoId,
      videoPath: videoPath,
      title: title,
      primarySubtitlePath: primarySubtitlePath,
      secondarySubtitlePath: secondarySubtitlePath,
      renderSecondarySubtitle: renderSecondarySubtitle,
      continuousSubtitle: continuousSubtitle,
      embedSoftSubtitles: embedSoftSubtitles,
      softSubtitleOnly: softSubtitleOnly,
      softSubtitleUseSourceQuality: softSubtitleUseSourceQuality,
      softSubtitleTracks: softSubtitleTracks,
      resolution: resolution,
      renderMode: renderMode,
      subtitleStyle: subtitleStyle,
      subtitleStylePortrait: subtitleStylePortrait,
      subtitleAlignment: subtitleAlignment,
      splitSubtitleByLine: splitSubtitleByLine,
      outputPath: outputPath,
    );
    return _enqueueRequest(request: request);
  }

  Future<VideoComposeTaskState> retryFailedTask({
    required String taskId,
    required SubtitleStyle subtitleStyle,
    required Alignment subtitleAlignment,
  }) async {
    final VideoComposeTaskState? old = _taskMap[taskId];
    if (old == null) {
      throw StateError('任务不存在');
    }
    final String newOutput = await _outputPathService.buildOutputPath(
      old.request.title,
    );
    final VideoComposeRequest request = VideoComposeRequest(
      videoId: old.request.videoId,
      videoPath: old.request.videoPath,
      title: old.request.title,
      primarySubtitlePath: old.request.primarySubtitlePath,
      secondarySubtitlePath: old.request.secondarySubtitlePath,
      renderSecondarySubtitle: old.request.renderSecondarySubtitle,
      continuousSubtitle: old.request.continuousSubtitle,
      embedSoftSubtitles: old.request.embedSoftSubtitles,
      softSubtitleOnly: old.request.softSubtitleOnly,
      softSubtitleUseSourceQuality: old.request.softSubtitleUseSourceQuality,
      softSubtitleTracks: old.request.softSubtitleTracks,
      resolution: old.request.resolution,
      renderMode: old.request.renderMode,
      subtitleStyle: subtitleStyle,
      subtitleStylePortrait: old.request.subtitleStylePortrait,
      subtitleAlignment: subtitleAlignment,
      splitSubtitleByLine: old.request.splitSubtitleByLine,
      subtitleItemGap: old.request.subtitleItemGap,
      subtitleRendererVersion: old.request.subtitleRendererVersion,
      outputPath: newOutput,
    );
    return _enqueueRequest(request: request);
  }

  Future<VideoComposeTaskState> _enqueueRequest({
    required VideoComposeRequest request,
  }) async {
    final String taskId =
        '${request.videoId}_${DateTime.now().millisecondsSinceEpoch}';
    const String stageMessage = '排队中';
    final VideoComposeTaskState state = VideoComposeTaskState(
      taskId: taskId,
      request: request,
      createdAt: DateTime.now(),
      stage: VideoComposeStage.queued,
      progress: 0,
      message: stageMessage,
    );
    _taskMap[taskId] = state;
    _queueTaskIds.add(taskId);
    notifyListeners();
    _saveTasks();
    unawaited(_processQueue());
    return state;
  }

  Future<void> _processQueue() async {
    if (_isProcessing) return;
    _isProcessing = true;
    try {
      while (_queueTaskIds.isNotEmpty) {
        final String taskId = _queueTaskIds.removeAt(0);
        final VideoComposeTaskState? task = _taskMap[taskId];
        if (task == null) {
          continue;
        }
        _runningTaskId = taskId;
        _setTask(
          taskId,
          stage: VideoComposeStage.preparing,
          progress: 0.02,
          message: '准备中',
        );
        try {
          await _runTask(taskId: taskId, request: task.request);
          _setTask(
            taskId,
            stage: VideoComposeStage.completed,
            progress: 1,
            message: '已完成',
            error: null,
          );
        } catch (e) {
          _setTask(
            taskId,
            stage: VideoComposeStage.failed,
            progress: 0,
            message: '处理失败',
            error: e.toString(),
          );
        } finally {
          _runningTaskId = null;
          notifyListeners();
        }
      }
    } finally {
      _isProcessing = false;
      notifyListeners();
    }
  }

  void _setTask(
    String taskId, {
    VideoComposeStage? stage,
    double? progress,
    String? message,
    String? error,
  }) {
    final VideoComposeTaskState? old = _taskMap[taskId];
    if (old == null) return;

    DateTime? completedAt = old.completedAt;
    if (stage != null &&
        (stage == VideoComposeStage.completed ||
            stage == VideoComposeStage.failed)) {
      completedAt = DateTime.now();
    }

    _taskMap[taskId] = old.copyWith(
      stage: stage,
      progress: progress,
      message: message,
      error: error,
      completedAt: completedAt,
    );
    notifyListeners();

    if (stage != null && stage != old.stage) {
      unawaited(_saveTasks());
    }
  }

  Future<void> _runTask({
    required String taskId,
    required VideoComposeRequest request,
  }) async {
    try {
      await _orchestrator.run(
        taskId: taskId,
        request: request,
        onArtifact: (String filePath) {
          _artifactCleaner.trackTaskArtifact(taskId, filePath);
        },
        onStatus:
            ({
              VideoComposeStage? stage,
              double? progress,
              String? message,
              String? error,
            }) {
              _setTask(
                taskId,
                stage: stage,
                progress: progress,
                message: message,
                error: error,
              );
            },
      );
    } finally {
      await _artifactCleaner.cleanupTaskArtifacts(taskId);
    }
  }
}
