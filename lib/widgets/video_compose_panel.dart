import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/subtitle_style.dart';
import '../models/video_compose_models.dart';
import '../models/video_item.dart';
import '../services/settings_service.dart';
import '../services/video_compose_manager.dart';
import '../utils/app_toast.dart';
import 'package:intl/intl.dart';
import '../screens/simple_video_player_screen.dart';

class VideoComposePanel extends StatefulWidget {
  final VideoItem videoItem;
  final List<String> currentSelectedPaths;
  final Map<String, String> availableSubtitleMap;
  final VoidCallback? onBack;
  final VoidCallback? onOpenSubtitleStyle;
  final VoidCallback? onOpenSubtitleManager;

  const VideoComposePanel({
    super.key,
    required this.videoItem,
    required this.currentSelectedPaths,
    required this.availableSubtitleMap,
    this.onBack,
    this.onOpenSubtitleStyle,
    this.onOpenSubtitleManager,
  });

  @override
  State<VideoComposePanel> createState() => _VideoComposePanelState();
}

class _VideoComposePanelState extends State<VideoComposePanel> {
  String? _primaryPath;
  String? _secondaryPath;
  String? _customOutputPath;
  String? _sourceResolutionLabel;
  VideoComposeResolution _resolution = VideoComposeResolution.p1080;
  bool _continuousSubtitle = false;
  bool _renderSecondarySubtitle = true;
  bool _embedSoftSubtitles = false;
  bool _softSubtitleOnly = false;
  bool _softSubtitleUseSourceQuality = true;
  bool _animateVisibility = false;
  bool _deleteOutputOnTaskDelete = true;
  bool get _showCustomOutputDirectory => !Platform.isIOS;

  @override
  void initState() {
    super.initState();
    _loadInitialFromSettings(applyState: false);
    _loadSourceResolution();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _animateVisibility = true;
      });
    });
  }

  Future<void> _loadSourceResolution() async {
    final manager = Provider.of<VideoComposeManager>(context, listen: false);
    final source = await manager.getSourceResolutionLabel(widget.videoItem.path);
    if (!mounted) return;
    setState(() {
      _sourceResolutionLabel = source;
    });
  }

  void _loadInitialFromSettings({bool applyState = true}) {
    final settings = Provider.of<SettingsService>(context, listen: false);
    final List<String> candidates = widget.availableSubtitleMap.keys.toList();
    String? selectedPrimary;
    String? selectedSecondary;

    final String? currentPrimary = widget.currentSelectedPaths.isNotEmpty
        ? widget.currentSelectedPaths.first
        : null;
    final String? currentSecondary = widget.currentSelectedPaths.length > 1
        ? widget.currentSelectedPaths[1]
        : null;

    if (settings.videoComposePrimarySubtitlePath != null &&
        candidates.contains(settings.videoComposePrimarySubtitlePath)) {
      selectedPrimary = settings.videoComposePrimarySubtitlePath;
    } else if (currentPrimary != null && candidates.contains(currentPrimary)) {
      selectedPrimary = currentPrimary;
    } else if (widget.videoItem.subtitlePath != null &&
        candidates.contains(widget.videoItem.subtitlePath)) {
      selectedPrimary = widget.videoItem.subtitlePath;
    } else if (candidates.isNotEmpty) {
      selectedPrimary = candidates.first;
    }

    if (settings.videoComposeSecondarySubtitlePath != null &&
        candidates.contains(settings.videoComposeSecondarySubtitlePath)) {
      selectedSecondary = settings.videoComposeSecondarySubtitlePath;
    } else if (currentSecondary != null &&
        candidates.contains(currentSecondary)) {
      selectedSecondary = currentSecondary;
    } else if (widget.videoItem.secondarySubtitlePath != null &&
        candidates.contains(widget.videoItem.secondarySubtitlePath)) {
      selectedSecondary = widget.videoItem.secondarySubtitlePath;
    }

    void assignState() {
      _primaryPath = selectedPrimary;
      _secondaryPath = selectedSecondary;
      _customOutputPath = _showCustomOutputDirectory
          ? settings.videoComposeCustomOutputPath
          : null;
      if (Platform.isAndroid &&
          (_customOutputPath == null || _customOutputPath!.isEmpty)) {
        _customOutputPath = '/storage/emulated/0/Download/ComposedVideos';
      }
      _resolution = _resolutionFromHeight(
        settings.videoComposeResolutionHeight,
      );
      _continuousSubtitle = settings.videoComposeContinuousSubtitle;
      _renderSecondarySubtitle = settings.videoComposeRenderSecondary;
      _embedSoftSubtitles = settings.videoComposeEmbedSoftSubtitles;
      _softSubtitleOnly =
          settings.videoComposeSoftSubtitleOnly && _embedSoftSubtitles;
      _softSubtitleUseSourceQuality =
          settings.videoComposeSoftSubtitleUseSourceQuality;
      _deleteOutputOnTaskDelete = settings.videoComposeDeleteOutputOnTaskDelete;
    }

    if (applyState) {
      if (!mounted) return;
      setState(assignState);
      return;
    }
    assignState();
  }

  VideoComposeResolution _resolutionFromHeight(int value) {
    return switch (value) {
      360 => VideoComposeResolution.p360,
      480 => VideoComposeResolution.p480,
      720 => VideoComposeResolution.p720,
      1080 => VideoComposeResolution.p1080,
      1440 => VideoComposeResolution.p1440,
      2160 => VideoComposeResolution.p2160,
      _ => VideoComposeResolution.source,
    };
  }

  int _heightFromResolution(VideoComposeResolution value) {
    return switch (value) {
      VideoComposeResolution.source => 0,
      VideoComposeResolution.p360 => 360,
      VideoComposeResolution.p480 => 480,
      VideoComposeResolution.p720 => 720,
      VideoComposeResolution.p1080 => 1080,
      VideoComposeResolution.p1440 => 1440,
      VideoComposeResolution.p2160 => 2160,
    };
  }

  Future<void> _enqueueCompose() async {
    final manager = Provider.of<VideoComposeManager>(context, listen: false);
    final settings = Provider.of<SettingsService>(context, listen: false);
    final bool softOnly = _softSubtitleOnly;
    final bool embedSoftSubtitles = _embedSoftSubtitles || softOnly;
    final List<VideoComposeSoftSubtitleTrack> softTracks = embedSoftSubtitles
        ? widget.availableSubtitleMap.entries
              .where((e) => e.key.trim().isNotEmpty)
              .map(
                (e) => VideoComposeSoftSubtitleTrack(
                  path: e.key,
                  title: e.value.trim().isEmpty ? '字幕' : e.value.trim(),
                ),
              )
              .toList()
        : const <VideoComposeSoftSubtitleTrack>[];
    String? primary = _primaryPath;
    String? secondary = _renderSecondarySubtitle ? _secondaryPath : null;
    if (!softOnly) {
      if ((primary == null || primary.isEmpty) &&
          (secondary == null || secondary.isEmpty)) {
        if (mounted) {
          AppToast.show('请先选择至少一个字幕', type: AppToastType.error);
        }
        return;
      }
      if ((primary == null || primary.isEmpty) &&
          secondary != null &&
          secondary.isNotEmpty) {
        primary = secondary;
        secondary = null;
      }
    }
    String? effectiveOutputPath = _showCustomOutputDirectory
        ? _customOutputPath?.trim()
        : null;
    if (effectiveOutputPath != null && effectiveOutputPath.isEmpty) {
      effectiveOutputPath = null;
    }
    if (Platform.isAndroid && effectiveOutputPath == null) {
      effectiveOutputPath = '/storage/emulated/0/Download/ComposedVideos';
      _customOutputPath = effectiveOutputPath;
      settings.updateSetting('videoComposeCustomOutputPath', effectiveOutputPath);
    }
    if (Platform.isAndroid &&
        effectiveOutputPath != null &&
        effectiveOutputPath.startsWith('/storage/emulated/0/')) {
      final granted = await _ensureAndroidExternalStoragePermission(
        requestFromUser: true,
      );
      if (!granted) return;
    }
    if (effectiveOutputPath != null) {
      try {
        final dir = Directory(effectiveOutputPath);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
      } catch (_) {
        if (mounted) {
          AppToast.show('输出目录不可用，请重新选择', type: AppToastType.error);
        }
        return;
      }
    }
    final SubtitleStyle style = widget.videoItem.type == MediaType.audio
        ? settings.audioSubtitleStylePortrait
        : settings.subtitleStyleLandscape;
    await manager.enqueue(
      videoId: widget.videoItem.id,
      videoPath: widget.videoItem.path,
      title: widget.videoItem.title,
      primarySubtitlePath: primary,
      secondarySubtitlePath: secondary,
      renderSecondarySubtitle: _renderSecondarySubtitle,
      continuousSubtitle: _continuousSubtitle,
      embedSoftSubtitles: embedSoftSubtitles,
      softSubtitleOnly: softOnly,
      softSubtitleUseSourceQuality: _softSubtitleUseSourceQuality,
      softSubtitleTracks: softTracks,
      resolution: _resolution,
      subtitleStyle: style,
      subtitleAlignment: settings.subtitleAlignment,
      customOutputPath: effectiveOutputPath,
    );
  }

  Future<bool> _ensureAndroidExternalStoragePermission({
    required bool requestFromUser,
  }) async {
    if (!Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.isGranted) return true;
    if (!requestFromUser) return false;
    await Permission.manageExternalStorage.request();
    if (await Permission.manageExternalStorage.isGranted) return true;
    if (!mounted) return false;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2C2C2C),
          title: const Text('需要文件管理权限', style: TextStyle(color: Colors.white)),
          content: const Text(
            '要保存到 Download/ComposedVideos，请在系统设置中授予“管理所有文件”权限。',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await openAppSettings();
              },
              child: const Text('去设置'),
            ),
          ],
        );
      },
    );
    return await Permission.manageExternalStorage.isGranted;
  }

  void _showSoftSubtitleHelp() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2C2C2C),
          title: const Text('软字幕内嵌说明', style: TextStyle(color: Colors.white)),
          content: const Text(
            '开启“软字幕内嵌”后，合成完成的视频会额外内置当前选择的主字幕和副字幕轨道，播放器可切换或关闭字幕。\n\n开启“仅合成软字幕”后，将不再把字幕烧录到画面中，只保留可切换的内嵌字幕轨道。',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('我知道了'),
            ),
          ],
        );
      },
    );
  }

  Duration get _fastTransitionDuration =>
      _animateVisibility
      ? const Duration(milliseconds: 140)
      : Duration.zero;

  void _openSubtitleManager() {
    final callback = widget.onOpenSubtitleManager;
    if (callback == null) {
      AppToast.show('字幕管理区暂不可用', type: AppToastType.info);
      return;
    }
    callback();
  }

  void _openQueueDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final size = MediaQuery.of(ctx).size;
        final screenW = size.width;
        final screenH = size.height;
        final shortSide = screenW < screenH ? screenW : screenH;
        final scale = (shortSide / 390).clamp(0.86, 1.22);
        final dialogWidth = (screenW * 0.9).clamp(320.0, 760.0);
        final maxDialogHeight = (screenH * 0.78).clamp(300.0, 780.0);
        final dialogPadding = (14.0 * scale).clamp(12.0, 20.0);
        final sectionGap = (10.0 * scale).clamp(8.0, 16.0);
        final titleSize = (18.0 * scale).clamp(15.0, 22.0);
        final subtitleSize = (13.0 * scale).clamp(11.0, 15.0);
        final timeSize = (11.0 * scale).clamp(9.0, 13.0);
        final iconSize = (19.0 * scale).clamp(16.0, 24.0);
        final actionButtonSize = (34.0 * scale).clamp(30.0, 42.0);
        final itemRadius = (12.0 * scale).clamp(10.0, 16.0);
        final listHeight = (maxDialogHeight - 96.0 * scale).clamp(180.0, 620.0);
        final emptyHeight = (120.0 * scale).clamp(92.0, 150.0);

        return Dialog(
          backgroundColor: const Color(0xFF1E1E1E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14 * scale),
          ),
          insetPadding: EdgeInsets.symmetric(
            horizontal: (screenW * 0.05).clamp(12.0, 40.0),
            vertical: (screenH * 0.04).clamp(12.0, 36.0),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: dialogWidth,
              maxHeight: maxDialogHeight,
            ),
            child: Padding(
              padding: EdgeInsets.all(dialogPadding),
              child: Consumer<VideoComposeManager>(
                builder: (context, manager, child) {
                  final tasks = manager.allTasks;
                  final queuedCount = manager.queuedTasks.length;
                  final runningCount = manager.runningTask == null ? 0 : 1;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                Text(
                                  '视频合成队列',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: titleSize,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                SizedBox(width: (8.0 * scale).clamp(6.0, 12.0)),
                                Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: (8.0 * scale).clamp(6.0, 10.0),
                                    vertical: (3.0 * scale).clamp(2.0, 5.0),
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white10,
                                    borderRadius: BorderRadius.circular(
                                      10 * scale,
                                    ),
                                  ),
                                  child: Text(
                                    '运行$runningCount · 排队$queuedCount',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: timeSize,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(
                            width: actionButtonSize,
                            height: actionButtonSize,
                            child: IconButton(
                              padding: EdgeInsets.zero,
                              iconSize: iconSize,
                              icon: const Icon(Icons.close, color: Colors.white),
                              onPressed: () => Navigator.of(ctx).pop(),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: sectionGap),
                      if (tasks.isEmpty)
                        Container(
                          width: double.infinity,
                          height: emptyHeight,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.03),
                            borderRadius: BorderRadius.circular(itemRadius),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: Center(
                            child: Text(
                              '当前没有合成任务',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: subtitleSize,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        )
                      else
                        SizedBox(
                          height: listHeight,
                          child: ListView.separated(
                            itemCount: tasks.length,
                            separatorBuilder: (context, index) =>
                                SizedBox(height: (8.0 * scale).clamp(6.0, 12.0)),
                            itemBuilder: (context, index) {
                              final task = tasks[index];
                              final isRunning =
                                  manager.runningTask?.taskId == task.taskId;
                              final isCompleted =
                                  task.stage == VideoComposeStage.completed;
                              final double progressValue = isCompleted
                                  ? 1.0
                                  : task.progress.clamp(0, 1).toDouble();
                              final stageColor =
                                  task.stage == VideoComposeStage.failed
                                  ? Colors.redAccent
                                  : (isRunning
                                        ? Colors.blueAccent
                                        : Colors.orangeAccent);
                              final stageText = task.message;
                              final errorText = task.error?.trim();
                              final hasErrorText =
                                  task.stage == VideoComposeStage.failed &&
                                  errorText != null &&
                                  errorText.isNotEmpty;
                              final hasOutputFile =
                                  isCompleted &&
                                  File(task.request.outputPath).existsSync();
                              return Container(
                                padding: EdgeInsets.all(
                                  (10.0 * scale).clamp(8.0, 14.0),
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.04),
                                  borderRadius: BorderRadius.circular(itemRadius),
                                  border: Border.all(color: Colors.white12),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          flex: 5,
                                          child: Text(
                                            task.request.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w600,
                                              fontSize: subtitleSize + 1,
                                            ),
                                          ),
                                        ),
                                        SizedBox(
                                          width: (8.0 * scale).clamp(6.0, 12.0),
                                        ),
                                        Flexible(
                                          flex: 4,
                                          child: Container(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: (7.0 * scale).clamp(
                                                6.0,
                                                10.0,
                                              ),
                                              vertical: (2.0 * scale).clamp(
                                                2.0,
                                                4.0,
                                              ),
                                            ),
                                            decoration: BoxDecoration(
                                              color: stageColor.withValues(
                                                alpha: 0.16,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(
                                                    8 * scale,
                                                  ),
                                            ),
                                            child: Text(
                                              stageText,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              softWrap: true,
                                              style: TextStyle(
                                                color: stageColor,
                                                fontSize: timeSize,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ),
                                        SizedBox(
                                          width: (6.0 * scale).clamp(4.0, 10.0),
                                        ),
                                        SizedBox(
                                          width: actionButtonSize,
                                          height: actionButtonSize,
                                          child: IconButton(
                                            iconSize: iconSize,
                                            padding: EdgeInsets.zero,
                                            tooltip: '删除记录与视频',
                                            icon: const Icon(
                                              Icons.delete_outline,
                                              color: Colors.redAccent,
                                            ),
                                            onPressed: () {
                                              bool shouldDeleteOutput =
                                                  _deleteOutputOnTaskDelete;
                                              final settingsService =
                                                  Provider.of<SettingsService>(
                                                    context,
                                                    listen: false,
                                                  );
                                              showDialog(
                                                context: context,
                                                builder: (dialogContext) => StatefulBuilder(
                                                  builder: (ctx, setDialogState) {
                                                    return AlertDialog(
                                                      backgroundColor: const Color(
                                                        0xFF2C2C2C,
                                                      ),
                                                      title: const Text(
                                                        '确认删除',
                                                        style: TextStyle(
                                                          color: Colors.white,
                                                        ),
                                                      ),
                                                      content: Column(
                                                        mainAxisSize: MainAxisSize.min,
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment.start,
                                                        children: [
                                                          const Text(
                                                            '确定要删除该合成记录吗？',
                                                            style: TextStyle(
                                                              color: Colors.white70,
                                                            ),
                                                          ),
                                                          SizedBox(
                                                            height: (6.0 * scale).clamp(
                                                              4.0,
                                                              10.0,
                                                            ),
                                                          ),
                                                          CheckboxListTile(
                                                            value: shouldDeleteOutput,
                                                            contentPadding:
                                                                EdgeInsets.zero,
                                                            controlAffinity:
                                                                ListTileControlAffinity.leading,
                                                            dense: true,
                                                            title: const Text(
                                                              '同时删除已合成的视频文件',
                                                              style: TextStyle(
                                                                color: Colors.white,
                                                              ),
                                                            ),
                                                            subtitle: const Text(
                                                              '仅删除该任务对应的输出文件',
                                                              style: TextStyle(
                                                                color: Colors.white54,
                                                                fontSize: 12,
                                                              ),
                                                            ),
                                                            onChanged: (v) async {
                                                              final value =
                                                                  v ?? true;
                                                              setDialogState(() {
                                                                shouldDeleteOutput =
                                                                    value;
                                                              });
                                                              if (_deleteOutputOnTaskDelete !=
                                                                  value) {
                                                                setState(() {
                                                                  _deleteOutputOnTaskDelete =
                                                                      value;
                                                                });
                                                                await settingsService
                                                                    .updateSetting(
                                                                      'videoComposeDeleteOutputOnTaskDelete',
                                                                      value,
                                                                    );
                                                              }
                                                            },
                                                          ),
                                                        ],
                                                      ),
                                                      actions: [
                                                        TextButton(
                                                          onPressed: () =>
                                                              Navigator.pop(
                                                                dialogContext,
                                                              ),
                                                          child: const Text(
                                                            '取消',
                                                            style: TextStyle(
                                                              color: Colors.white70,
                                                            ),
                                                          ),
                                                        ),
                                                        TextButton(
                                                          onPressed: () async {
                                                            final outputDeleted =
                                                                await manager
                                                                .deleteTaskAndFile(
                                                                  task.taskId,
                                                                  deleteOutput:
                                                                      shouldDeleteOutput,
                                                                );
                                                            if (dialogContext
                                                                .mounted) {
                                                              Navigator.pop(
                                                                dialogContext,
                                                              );
                                                            }
                                                            if (shouldDeleteOutput &&
                                                                !outputDeleted &&
                                                                mounted) {
                                                              AppToast.show(
                                                                '任务已删除，但视频文件删除失败，文件可能被占用或无权限，请关闭占用后重试',
                                                                type: AppToastType.error,
                                                              );
                                                            }
                                                          },
                                                          child: const Text(
                                                            '删除',
                                                            style: TextStyle(
                                                              color:
                                                                  Colors.redAccent,
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    );
                                                  },
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                      ],
                                    ),
                                    SizedBox(
                                      height: (8.0 * scale).clamp(6.0, 10.0),
                                    ),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              4 * scale,
                                            ),
                                            child: LinearProgressIndicator(
                                              minHeight: (5.0 * scale).clamp(
                                                4.0,
                                                8.0,
                                              ),
                                              value: progressValue,
                                              backgroundColor: Colors.white10,
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                    stageColor,
                                                  ),
                                            ),
                                          ),
                                        ),
                                        SizedBox(
                                          width: (10.0 * scale).clamp(8.0, 14.0),
                                        ),
                                        Text(
                                          '${(progressValue * 100).toStringAsFixed(0)}%',
                                          style: TextStyle(
                                            color: Colors.white70,
                                            fontSize: subtitleSize,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (hasErrorText) ...[
                                      SizedBox(
                                        height: (7.0 * scale).clamp(5.0, 10.0),
                                      ),
                                      Container(
                                        width: double.infinity,
                                        padding: EdgeInsets.symmetric(
                                          horizontal: (7.0 * scale).clamp(
                                            6.0,
                                            10.0,
                                          ),
                                          vertical: (4.0 * scale).clamp(
                                            3.0,
                                            6.0,
                                          ),
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.redAccent.withValues(
                                            alpha: 0.12,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            6 * scale,
                                          ),
                                          border: Border.all(
                                            color: Colors.redAccent.withValues(
                                              alpha: 0.35,
                                            ),
                                          ),
                                        ),
                                        child: SingleChildScrollView(
                                          scrollDirection: Axis.horizontal,
                                          child: SelectableText(
                                            errorText,
                                            maxLines: 1,
                                            style: TextStyle(
                                              color: Colors.redAccent,
                                              fontSize: timeSize,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                    if (task.completedAt != null) ...[
                                      SizedBox(
                                        height: (7.0 * scale).clamp(6.0, 10.0),
                                      ),
                                      Text(
                                        '完成时间: ${DateFormat('yyyy-MM-dd HH:mm:ss').format(task.completedAt!)}',
                                        style: TextStyle(
                                          color: Colors.white54,
                                          fontSize: timeSize,
                                        ),
                                      ),
                                    ],
                                    if (hasOutputFile) ...[
                                      SizedBox(
                                        height: (8.0 * scale).clamp(6.0, 12.0),
                                      ),
                                      Row(
                                        children: [
                                          SizedBox(
                                            height: actionButtonSize,
                                            child: OutlinedButton.icon(
                                              icon: Icon(
                                                Icons.play_circle_outline,
                                                size: iconSize - 1,
                                              ),
                                              label: Text(
                                                '预览',
                                                style: TextStyle(
                                                  fontSize: timeSize + 1,
                                                ),
                                              ),
                                              style: OutlinedButton.styleFrom(
                                                foregroundColor: Colors.white,
                                                side: const BorderSide(
                                                  color: Colors.white24,
                                                ),
                                                padding: EdgeInsets.symmetric(
                                                  horizontal:
                                                      (10.0 * scale).clamp(
                                                        8.0,
                                                        14.0,
                                                      ),
                                                ),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        9 * scale,
                                                      ),
                                                ),
                                              ),
                                              onPressed: () {
                                                Navigator.push(
                                                  context,
                                                  MaterialPageRoute(
                                                    builder: (context) =>
                                                        SimpleVideoPlayerScreen(
                                                          videoPath:
                                                              task.request
                                                                  .outputPath,
                                                          title:
                                                              task.request.title,
                                                        ),
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                                          SizedBox(
                                            width: (8.0 * scale).clamp(
                                              6.0,
                                              12.0,
                                            ),
                                          ),
                                          SizedBox(
                                            height: actionButtonSize,
                                            child: OutlinedButton.icon(
                                              icon: Icon(
                                                Icons.open_in_new_outlined,
                                                size: iconSize - 1,
                                              ),
                                              label: Text(
                                                '用其他应用打开',
                                                style: TextStyle(
                                                  fontSize: timeSize + 1,
                                                ),
                                              ),
                                              style: OutlinedButton.styleFrom(
                                                foregroundColor: Colors.white,
                                                side: const BorderSide(
                                                  color: Colors.white24,
                                                ),
                                                padding: EdgeInsets.symmetric(
                                                  horizontal:
                                                      (10.0 * scale).clamp(
                                                        8.0,
                                                        14.0,
                                                      ),
                                                ),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        9 * scale,
                                                      ),
                                                ),
                                              ),
                                              onPressed: () async {
                                                await _openWithOtherApp(
                                                  task.request.outputPath,
                                                );
                                              },
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTopActionButton({
    required VoidCallback? onPressed,
    required IconData icon,
    required String label,
    required double buttonHeight,
    required double textSize,
  }) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: Size.fromHeight(buttonHeight),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        foregroundColor: Colors.white,
        side: const BorderSide(color: Colors.white30),
        textStyle: TextStyle(fontSize: textSize),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: textSize + 2),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _buildDropdownDecoration(String labelText, double spacing) {
    return InputDecoration(
      isDense: true,
      contentPadding: EdgeInsets.symmetric(
        horizontal: 12,
        vertical: spacing * 0.8,
      ),
      labelText: labelText,
      labelStyle: const TextStyle(color: Colors.white70),
      enabledBorder: const OutlineInputBorder(
        borderSide: BorderSide(color: Colors.white24),
      ),
      focusedBorder: const OutlineInputBorder(
        borderSide: BorderSide(color: Colors.blueAccent),
      ),
    );
  }

  Widget _buildCompactSwitchCard({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    required double textSize,
    required double smallSize,
    required double switchScale,
    Widget? child,
    bool showChild = false,
    bool embedChildInLeading = false,
  }) {
    final Widget? effectiveChild = child == null
        ? null
        : AnimatedSize(
            duration: _fastTransitionDuration,
            curve: Curves.easeOutCubic,
            child: showChild
                ? Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: child,
                  )
                : const SizedBox.shrink(),
          );
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white24),
        borderRadius: BorderRadius.circular(8),
        color: Colors.white.withValues(alpha: 0.03),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: textSize,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: smallSize,
                      ),
                    ),
                    if (embedChildInLeading && effectiveChild != null)
                      effectiveChild,
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Transform.scale(
                scale: switchScale,
                alignment: Alignment.centerRight,
                child: Switch.adaptive(
                  value: value,
                  onChanged: onChanged,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          if (!embedChildInLeading && effectiveChild != null) effectiveChild,
        ],
      ),
    );
  }

  String _resolutionLabel(VideoComposeResolution value) {
    return switch (value) {
      VideoComposeResolution.source => _sourceResolutionLabel == null
          ? '原始分辨率'
          : '原始分辨率 (${_sourceResolutionLabel!})',
      VideoComposeResolution.p360 => '360P',
      VideoComposeResolution.p480 => '480P',
      VideoComposeResolution.p720 => '720P',
      VideoComposeResolution.p1080 => '1080P',
      VideoComposeResolution.p1440 => '1440P',
      VideoComposeResolution.p2160 => '2160P',
    };
  }

  String _stageText(VideoComposeStage stage, String message, String? error) {
    if (stage == VideoComposeStage.failed &&
        error != null &&
        error.trim().isNotEmpty) {
      return '$message: ${error.trim()}';
    }
    return message;
  }

  Future<String> _prepareExternalOpenPath(String sourcePath) async {
    if (!Platform.isAndroid) return sourcePath;
    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) return sourcePath;

    Directory? publicBase;
    final publicDownload = Directory('/storage/emulated/0/Download');
    if (await publicDownload.exists()) {
      publicBase = publicDownload;
    } else {
      final fallback = await getDownloadsDirectory();
      if (fallback != null) {
        publicBase = fallback;
      }
    }
    if (publicBase == null) return sourcePath;

    final targetDir = Directory(p.join(publicBase.path, 'ComposedVideos'));
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }
    final fileName = p.basename(sourcePath);
    var targetPath = p.join(targetDir.path, fileName);
    if (p.normalize(targetPath) == p.normalize(sourcePath)) return sourcePath;

    final targetFile = File(targetPath);
    if (await targetFile.exists()) {
      final srcStat = await sourceFile.stat();
      final dstStat = await targetFile.stat();
      if (srcStat.size == dstStat.size) {
        return targetPath;
      }
      final base = p.basenameWithoutExtension(fileName);
      final ext = p.extension(fileName);
      targetPath = p.join(
        targetDir.path,
        '${base}_${DateTime.now().millisecondsSinceEpoch}$ext',
      );
    }
    await sourceFile.copy(targetPath);
    return targetPath;
  }

  Future<void> _openWithOtherApp(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      if (!mounted) return;
      AppToast.show('文件不存在，无法打开', type: AppToastType.error);
      return;
    }
    String openPath = path;
    try {
      openPath = await _prepareExternalOpenPath(path);
    } catch (_) {}
    var result = await OpenFilex.open(openPath);
    if (result.type != ResultType.done && openPath != path) {
      result = await OpenFilex.open(path);
    }
    if (!mounted) return;
    if (result.type != ResultType.done) {
      AppToast.show('调用其他应用打开失败', type: AppToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.of(context).size.height;
    return LayoutBuilder(
      builder: (context, constraints) {
        final h = constraints.maxHeight.isInfinite ? screenH : constraints.maxHeight;
        final w = constraints.maxWidth;
        
        final pad = (h * 0.012).clamp(6.0, 10.0);
        final titleSize = (h * 0.018).clamp(12.0, 15.0);
        final textSize = (h * 0.0158).clamp(10.0, 13.0);
        final smallSize = (h * 0.0135).clamp(9.0, 11.0);
        final buttonHeight = (h * 0.045).clamp(30.0, 38.0);
        final spacing = (h * 0.0075).clamp(3.0, 8.0);
        final topBarHeight = (h * 0.043).clamp(30.0, 36.0);
        final topIconSize = (h * 0.023).clamp(16.0, 21.0);
        final actionGap = (h * 0.007).clamp(4.0, 8.0);
        final formPairGap = (spacing * 1.5).clamp(8.0, 12.0);
        final useTwoColumnForm = w >= 360;
        final switchScale = (textSize / 13.0).clamp(0.68, 0.86);
        final secondaryDropdownScale = (textSize / 13.0).clamp(0.74, 0.88);

        return Container(
          color: const Color(0xFF1E1E1E),
          padding: EdgeInsets.all(pad),
          child: Consumer2<VideoComposeManager, SettingsService>(
            builder: (context, manager, settings, child) {
              final latest = manager.latestTaskForVideo(widget.videoItem.id);
              final bool isRunningCurrent =
                  manager.runningTask?.request.videoId == widget.videoItem.id;
              return SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                  SizedBox(
                    height: topBarHeight,
                    child: Row(
                      children: [
                        SizedBox(
                          width: topBarHeight,
                          height: topBarHeight,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            onPressed: widget.onBack,
                            iconSize: topIconSize,
                            icon: const Icon(
                              Icons.arrow_back,
                              color: Colors.white,
                            ),
                            tooltip: '返回',
                          ),
                        ),
                        SizedBox(width: spacing),
                        Expanded(
                          child: Text(
                            '视频合成',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: titleSize,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        SizedBox(
                          height: topBarHeight - 2,
                          child: OutlinedButton.icon(
                            onPressed: _openQueueDialog,
                            icon: Icon(
                              Icons.queue_play_next,
                              size: topIconSize - 1,
                            ),
                            label: Text(
                              '队列',
                              style: TextStyle(fontSize: smallSize),
                            ),
                            style: OutlinedButton.styleFrom(
                              padding: EdgeInsets.symmetric(
                                horizontal: (pad * 0.85).clamp(6.0, 10.0),
                              ),
                              foregroundColor: Colors.white70,
                              side: const BorderSide(color: Colors.white30),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: spacing),
                  Text(
                    widget.videoItem.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.white70, fontSize: textSize),
                  ),
                  if (!_softSubtitleOnly) ...[
                    SizedBox(height: spacing),
                    if (useTwoColumnForm)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: AnimatedSwitcher(
                              duration: _fastTransitionDuration,
                              switchInCurve: Curves.easeOutCubic,
                              switchOutCurve: Curves.easeInCubic,
                              child: !(_softSubtitleOnly &&
                                      _softSubtitleUseSourceQuality)
                                  ? DropdownButtonFormField<
                                      VideoComposeResolution>(
                                      key: const ValueKey(
                                        'resolution_dropdown',
                                      ),
                                      initialValue: _resolution,
                                      dropdownColor: const Color(0xFF2C2C2C),
                                      decoration: _buildDropdownDecoration(
                                        _sourceResolutionLabel == null
                                            ? '视频分辨率'
                                            : '视频分辨率（原始: $_sourceResolutionLabel）',
                                        spacing,
                                      ),
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: textSize,
                                      ),
                                      items: VideoComposeResolution.values
                                          .map(
                                            (e) => DropdownMenuItem<
                                                VideoComposeResolution>(
                                                  value: e,
                                                  child: Text(
                                                    _resolutionLabel(e),
                                                  ),
                                                ),
                                          )
                                          .toList(),
                                      onChanged: (v) {
                                        if (v == null) return;
                                        setState(() => _resolution = v);
                                        settings.updateSetting(
                                          'videoComposeResolutionHeight',
                                          _heightFromResolution(v),
                                        );
                                      },
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ),
                          SizedBox(width: formPairGap),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              initialValue: _primaryPath,
                              dropdownColor: const Color(0xFF2C2C2C),
                              decoration: _buildDropdownDecoration(
                                '主字幕渲染',
                                spacing,
                              ),
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: textSize,
                              ),
                              items: widget.availableSubtitleMap.entries
                                  .map(
                                    (e) => DropdownMenuItem<String>(
                                      value: e.key,
                                      child: Text(
                                        e.value,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (v) {
                                setState(() => _primaryPath = v);
                                settings.updateSetting(
                                  'videoComposePrimarySubtitlePath',
                                  v ?? '',
                                );
                              },
                            ),
                          ),
                        ],
                      )
                    else ...[
                      AnimatedSwitcher(
                        duration: _fastTransitionDuration,
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        child: !(_softSubtitleOnly && _softSubtitleUseSourceQuality)
                            ? DropdownButtonFormField<VideoComposeResolution>(
                                key: const ValueKey('resolution_dropdown'),
                                initialValue: _resolution,
                                dropdownColor: const Color(0xFF2C2C2C),
                                decoration: _buildDropdownDecoration(
                                  _sourceResolutionLabel == null
                                      ? '视频分辨率'
                                      : '视频分辨率（原始: $_sourceResolutionLabel）',
                                  spacing,
                                ),
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: textSize,
                                ),
                                items: VideoComposeResolution.values
                                    .map(
                                      (e) => DropdownMenuItem<
                                          VideoComposeResolution>(
                                            value: e,
                                            child: Text(_resolutionLabel(e)),
                                          ),
                                    )
                                    .toList(),
                                onChanged: (v) {
                                  if (v == null) return;
                                  setState(() => _resolution = v);
                                  settings.updateSetting(
                                    'videoComposeResolutionHeight',
                                    _heightFromResolution(v),
                                  );
                                },
                              )
                            : const SizedBox.shrink(),
                      ),
                      SizedBox(height: spacing * 0.5),
                      DropdownButtonFormField<String>(
                        initialValue: _primaryPath,
                        dropdownColor: const Color(0xFF2C2C2C),
                        decoration: _buildDropdownDecoration(
                          '主字幕渲染',
                          spacing,
                        ),
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: textSize,
                        ),
                        items: widget.availableSubtitleMap.entries
                            .map(
                              (e) => DropdownMenuItem<String>(
                                value: e.key,
                                child: Text(
                                  e.value,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (v) {
                          setState(() => _primaryPath = v);
                          settings.updateSetting(
                            'videoComposePrimarySubtitlePath',
                            v ?? '',
                          );
                        },
                      ),
                    ],
                    SizedBox(height: spacing * 0.5),
                    if (useTwoColumnForm)
                      IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: _buildCompactSwitchCard(
                                title: '字幕连续显示',
                                subtitle: '按播放逻辑延长至下一条',
                                value: _continuousSubtitle,
                                onChanged: (v) {
                                  setState(() => _continuousSubtitle = v);
                                  settings.updateSetting(
                                    'videoComposeContinuousSubtitle',
                                    v,
                                  );
                                },
                                textSize: textSize,
                                smallSize: smallSize,
                                switchScale: switchScale,
                              ),
                            ),
                            SizedBox(width: formPairGap),
                            Expanded(
                              child: _buildCompactSwitchCard(
                                title: '渲染副字幕',
                                subtitle: '与主字幕一起烧录',
                                value: _renderSecondarySubtitle,
                                onChanged: (v) {
                                  setState(
                                    () => _renderSecondarySubtitle = v,
                                  );
                                  settings.updateSetting(
                                    'videoComposeRenderSecondary',
                                    v,
                                  );
                                },
                                textSize: textSize,
                                smallSize: smallSize,
                                switchScale: switchScale,
                                showChild: _renderSecondarySubtitle,
                                embedChildInLeading: true,
                                child: Transform.scale(
                                  scale: secondaryDropdownScale,
                                  alignment: Alignment.centerLeft,
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: DropdownButtonFormField<String>(
                                      key: const ValueKey(
                                        'secondary_dropdown',
                                      ),
                                      initialValue: _secondaryPath,
                                      dropdownColor:
                                          const Color(0xFF2C2C2C),
                                      decoration: _buildDropdownDecoration(
                                        '副字幕渲染',
                                        spacing * 0.72,
                                      ),
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: textSize,
                                      ),
                                      items: widget
                                          .availableSubtitleMap
                                          .entries
                                          .map(
                                            (e) =>
                                                DropdownMenuItem<String>(
                                                  value: e.key,
                                                  child: Text(
                                                    e.value,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow
                                                            .ellipsis,
                                                  ),
                                                ),
                                          )
                                          .toList(),
                                      onChanged: (v) {
                                        setState(
                                          () => _secondaryPath = v,
                                        );
                                        settings.updateSetting(
                                          'videoComposeSecondarySubtitlePath',
                                          v ?? '',
                                        );
                                      },
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    else ...[
                      _buildCompactSwitchCard(
                        title: '字幕连续显示',
                        subtitle: '按播放逻辑延长至下一条',
                        value: _continuousSubtitle,
                        onChanged: (v) {
                          setState(() => _continuousSubtitle = v);
                          settings.updateSetting(
                            'videoComposeContinuousSubtitle',
                            v,
                          );
                        },
                        textSize: textSize,
                        smallSize: smallSize,
                        switchScale: switchScale,
                      ),
                      SizedBox(height: spacing * 0.5),
                      _buildCompactSwitchCard(
                        title: '渲染副字幕',
                        subtitle: '与主字幕一起烧录',
                        value: _renderSecondarySubtitle,
                        onChanged: (v) {
                          setState(() => _renderSecondarySubtitle = v);
                          settings.updateSetting(
                            'videoComposeRenderSecondary',
                            v,
                          );
                        },
                        textSize: textSize,
                        smallSize: smallSize,
                        switchScale: switchScale,
                        showChild: _renderSecondarySubtitle,
                        embedChildInLeading: true,
                        child: DropdownButtonFormField<String>(
                          key: const ValueKey('secondary_dropdown'),
                          initialValue: _secondaryPath,
                          dropdownColor: const Color(0xFF2C2C2C),
                          decoration: _buildDropdownDecoration(
                            '副字幕渲染',
                            spacing * 0.72,
                          ),
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: textSize,
                          ),
                          items: widget.availableSubtitleMap.entries
                              .map(
                                (e) => DropdownMenuItem<String>(
                                  value: e.key,
                                  child: Text(
                                    e.value,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            setState(() => _secondaryPath = v);
                            settings.updateSetting(
                              'videoComposeSecondarySubtitlePath',
                              v ?? '',
                            );
                          },
                        ),
                      ),
                    ],
                  ],
                  if (_softSubtitleOnly) ...[
                    SizedBox(height: spacing),
                    AnimatedSwitcher(
                      duration: _fastTransitionDuration,
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      child: !(_softSubtitleOnly && _softSubtitleUseSourceQuality)
                          ? DropdownButtonFormField<VideoComposeResolution>(
                              key: const ValueKey('resolution_dropdown'),
                              initialValue: _resolution,
                              dropdownColor: const Color(0xFF2C2C2C),
                              decoration: _buildDropdownDecoration(
                                _sourceResolutionLabel == null
                                    ? '视频分辨率'
                                    : '视频分辨率（原始: $_sourceResolutionLabel）',
                                spacing,
                              ),
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: textSize,
                              ),
                              items: VideoComposeResolution.values
                                  .map(
                                    (e) => DropdownMenuItem<
                                        VideoComposeResolution>(
                                          value: e,
                                          child: Text(_resolutionLabel(e)),
                                        ),
                                  )
                                  .toList(),
                              onChanged: (v) {
                                if (v == null) return;
                                setState(() => _resolution = v);
                                settings.updateSetting(
                                  'videoComposeResolutionHeight',
                                  _heightFromResolution(v),
                                );
                              },
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                  SizedBox(height: spacing * 0.5),
                  Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white24),
                      borderRadius: BorderRadius.circular(8),
                      color: Colors.white.withValues(alpha: 0.03),
                    ),
                    padding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: spacing * 0.2,
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Padding(
                                padding: EdgeInsets.only(
                                  right: actionGap * 0.5,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '软字幕内嵌',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: textSize,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            '合成后额外内嵌主/副字幕轨道',
                                            style: TextStyle(
                                              color: Colors.white54,
                                              fontSize: smallSize,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Transform.scale(
                                      scale: switchScale,
                                      alignment: Alignment.centerRight,
                                      child: Switch.adaptive(
                                        value: _embedSoftSubtitles,
                                        onChanged: (v) {
                                          setState(() {
                                            _embedSoftSubtitles = v;
                                            if (!v) {
                                              _softSubtitleOnly = false;
                                            }
                                          });
                                          settings.updateSetting(
                                            'videoComposeEmbedSoftSubtitles',
                                            v,
                                          );
                                          if (!v) {
                                            settings.updateSetting(
                                              'videoComposeSoftSubtitleOnly',
                                              false,
                                            );
                                          }
                                        },
                                        materialTapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Text(
                              '字幕 ${widget.availableSubtitleMap.length}',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: smallSize,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            SizedBox(width: actionGap),
                            OutlinedButton.icon(
                              onPressed: _openSubtitleManager,
                              style: OutlinedButton.styleFrom(
                                minimumSize: Size(
                                  0,
                                  (buttonHeight * 0.82).clamp(28.0, 34.0),
                                ),
                                padding: EdgeInsets.symmetric(
                                  horizontal: (pad * 0.6).clamp(5.0, 8.0),
                                ),
                                foregroundColor: Colors.white70,
                                side: const BorderSide(color: Colors.white24),
                                textStyle: TextStyle(fontSize: smallSize),
                              ),
                              icon: Icon(
                                Icons.subtitles_outlined,
                                size: smallSize + 4,
                              ),
                              label: const Text('管理'),
                            ),
                          ],
                        ),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          visualDensity: const VisualDensity(horizontal: 0, vertical: -4),
                          dense: true,
                          value: _softSubtitleOnly,
                          title: Text(
                            '仅合成软字幕',
                            style: TextStyle(
                              color: _embedSoftSubtitles
                                  ? Colors.white
                                  : Colors.white54,
                              fontSize: textSize,
                            ),
                          ),
                          subtitle: Text(
                            '不烧录到画面，仅保留内嵌字幕轨道',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: smallSize,
                            ),
                          ),
                          onChanged: _embedSoftSubtitles
                              ? (v) {
                                  final value = v ?? false;
                                  setState(() => _softSubtitleOnly = value);
                                  settings.updateSetting(
                                    'videoComposeSoftSubtitleOnly',
                                    value,
                                  );
                                }
                              : null,
                        ),
                        AnimatedSwitcher(
                          duration: _fastTransitionDuration,
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          child: _softSubtitleOnly
                              ? CheckboxListTile(
                                  key: const ValueKey('source_quality_checkbox'),
                                  contentPadding: EdgeInsets.zero,
                                  visualDensity: const VisualDensity(horizontal: 0, vertical: -4),
                                  dense: true,
                                  value: _softSubtitleUseSourceQuality,
                                  title: Text(
                                    '采用视频原画质',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: textSize,
                                    ),
                                  ),
                                  subtitle: Text(
                                    '仅封装字幕轨道，不重编码视频',
                                    style: TextStyle(
                                      color: Colors.white54,
                                      fontSize: smallSize,
                                    ),
                                  ),
                                  onChanged: (v) {
                                    final value = v ?? true;
                                    setState(
                                      () => _softSubtitleUseSourceQuality = value,
                                    );
                                    settings.updateSetting(
                                      'videoComposeSoftSubtitleUseSourceQuality',
                                      value,
                                    );
                                  },
                                )
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: spacing),
                  if (_showCustomOutputDirectory) ...[
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '自定义输出目录',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: textSize,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _customOutputPath ?? (Platform.isAndroid ? '/storage/emulated/0/Download/ComposedVideos' : '默认路径'),
                                style: TextStyle(
                                  color: Colors.white54,
                                  fontSize: smallSize,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: const Icon(
                            Icons.folder_open,
                            color: Colors.blueAccent,
                          ),
                          onPressed: () async {
                            if (Platform.isAndroid) {
                              final granted = await _ensureAndroidExternalStoragePermission(
                                requestFromUser: true,
                              );
                              if (!granted) return;
                            }
                            String? selectedDirectory = await FilePicker.platform
                                .getDirectoryPath(dialogTitle: '选择保存目录');
                            if (selectedDirectory != null) {
                              setState(() {
                                _customOutputPath = selectedDirectory;
                              });
                              settings.updateSetting(
                                'videoComposeCustomOutputPath',
                                selectedDirectory,
                              );
                            }
                          },
                        ),
                        if (Platform.isAndroid)
                          IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            icon: const Icon(
                              Icons.security_outlined,
                              color: Colors.orangeAccent,
                            ),
                            onPressed: () async {
                              await _ensureAndroidExternalStoragePermission(
                                requestFromUser: true,
                              );
                            },
                          ),
                      ],
                    ),
                    if (Platform.isAndroid) ...[
                      SizedBox(height: spacing * 0.4),
                      Text(
                        '默认输出目录: /storage/emulated/0/Download/ComposedVideos',
                        style: TextStyle(
                          color: Colors.greenAccent,
                          fontSize: smallSize,
                        ),
                      ),
                    ],
                    SizedBox(height: spacing * 1.5),
                  ] else
                    SizedBox(height: spacing * 0.5),
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: Colors.white.withValues(alpha: 0.035),
                      border: Border.all(color: Colors.white24),
                    ),
                    padding: EdgeInsets.all((pad * 0.45).clamp(4.0, 8.0)),
                    child: Row(
                      children: [
                        Expanded(
                          child: _buildTopActionButton(
                            onPressed: _openSubtitleManager,
                            icon: Icons.subtitles,
                            label: '字幕管理',
                            buttonHeight: buttonHeight,
                            textSize: textSize,
                          ),
                        ),
                        SizedBox(width: actionGap * 0.8),
                        Expanded(
                          child: _buildTopActionButton(
                            onPressed: _showSoftSubtitleHelp,
                            icon: Icons.info_outline,
                            label: '软字幕说明',
                            buttonHeight: buttonHeight,
                            textSize: textSize,
                          ),
                        ),
                        SizedBox(width: actionGap * 0.8),
                        Expanded(
                          child: _buildTopActionButton(
                            onPressed: _softSubtitleOnly
                                ? null
                                : widget.onOpenSubtitleStyle,
                            icon: Icons.style,
                            label: '字幕样式',
                            buttonHeight: buttonHeight,
                            textSize: textSize,
                          ),
                        ),
                        SizedBox(width: actionGap * 0.8),
                        Expanded(
                          child: _buildTopActionButton(
                            onPressed: _openQueueDialog,
                            icon: Icons.queue_play_next,
                            label: '查看队列',
                            buttonHeight: buttonHeight,
                            textSize: textSize,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: spacing),
                  ElevatedButton.icon(
                    onPressed: _enqueueCompose,
                    style: ElevatedButton.styleFrom(
                      minimumSize: Size.fromHeight(buttonHeight),
                      padding: EdgeInsets.zero,
                      backgroundColor: Colors.blueAccent,
                      foregroundColor: Colors.white,
                      textStyle: TextStyle(fontSize: textSize, fontWeight: FontWeight.w600),
                    ),
                    icon: Icon(Icons.movie_creation_outlined, size: textSize + 4),
                    label: const Text('加入合成队列'),
                  ),
                  SizedBox(height: spacing),
                  if (latest != null) ...[
                    LinearProgressIndicator(
                      value: latest.stage == VideoComposeStage.completed
                          ? 1
                          : latest.progress.clamp(0, 1),
                      backgroundColor: Colors.white10,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        latest.stage == VideoComposeStage.failed
                            ? Colors.redAccent
                            : (isRunningCurrent
                                  ? Colors.blueAccent
                                  : Colors.orangeAccent),
                      ),
                    ),
                    SizedBox(height: spacing * 0.6),
                    Text(
                      _stageText(latest.stage, latest.message, latest.error),
                      style: TextStyle(
                        color: latest.stage == VideoComposeStage.failed
                            ? Colors.redAccent
                            : Colors.white70,
                        fontSize: smallSize,
                      ),
                    ),
                    SizedBox(height: spacing * 0.6),
                    if (latest.stage == VideoComposeStage.completed ||
                        latest.stage == VideoComposeStage.failed)
                      SelectableText(
                        latest.stage == VideoComposeStage.completed
                            ? '输出文件: ${latest.request.outputPath}'
                            : '最近一次失败任务输出路径: ${latest.request.outputPath}',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: smallSize,
                        ),
                      ),
                    if (latest.stage == VideoComposeStage.completed &&
                        File(latest.request.outputPath).existsSync()) ...[
                      SizedBox(height: spacing * 0.6),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '可在系统文件管理器中打开 ComposedVideos 目录查看结果',
                              style: TextStyle(
                                color: Colors.greenAccent,
                                fontSize: smallSize,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.play_circle_outline, color: Colors.white),
                            tooltip: '预览',
                            iconSize: 28,
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => SimpleVideoPlayerScreen(
                                    videoPath: latest.request.outputPath,
                                    title: latest.request.title,
                                  ),
                                ),
                              );
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.open_in_new_outlined, color: Colors.white),
                            tooltip: '用其他应用打开',
                            iconSize: 28,
                            onPressed: () async {
                              await _openWithOtherApp(latest.request.outputPath);
                            },
                          ),
                        ],
                      ),
                    ],
                  ],
                ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}
