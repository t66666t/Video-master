import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/ocr_subtitle_models.dart';
import '../models/video_item.dart';
import '../services/ocr_subtitle_manager.dart';
import '../utils/app_toast.dart';
import 'ocr_region_editor.dart';
import 'ocr_region_preview.dart';

class OcrSubtitlePanel extends StatefulWidget {
  final VideoItem videoItem;
  final Duration duration;
  final Duration Function() currentPosition;
  final Future<bool> Function() pauseForRegionSelection;
  final Future<void> Function(bool wasPlaying) restorePlayback;
  final VoidCallback onBack;
  final Future<void> Function(List<String> paths) onCompleted;

  const OcrSubtitlePanel({
    super.key,
    required this.videoItem,
    required this.duration,
    required this.currentPosition,
    required this.pauseForRegionSelection,
    required this.restorePlayback,
    required this.onBack,
    required this.onCompleted,
  });

  @override
  State<OcrSubtitlePanel> createState() => _OcrSubtitlePanelState();
}

class _OcrSubtitlePanelState extends State<OcrSubtitlePanel> {
  late List<OcrSubtitleTrack> _tracks;
  bool _customRange = false;
  late double _startMs;
  late double _endMs;
  bool _modelInstalled = false;
  Duration? _estimate;
  String? _previewPath;
  String? _deliveredPath;
  bool _tracksEditedInThisPanel = false;

  OcrSubtitleManager get _manager => context.read<OcrSubtitleManager>();

  @override
  void initState() {
    super.initState();
    _tracks = List<OcrSubtitleTrack>.from(
      _manager.tracksForVideo(widget.videoItem.id),
    );
    _startMs = 0;
    _endMs = widget.duration.inMilliseconds.toDouble().clamp(
      1,
      double.infinity,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _manager.addListener(_onManagerChanged);
      _refreshModelAndEstimate();
      _onManagerChanged();
    });
  }

  @override
  void didUpdateWidget(covariant OcrSubtitlePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoItem.id != widget.videoItem.id) {
      _startMs = 0;
      _endMs = widget.duration.inMilliseconds.toDouble();
      _deliveredPath = null;
      _tracks = List<OcrSubtitleTrack>.from(
        _manager.tracksForVideo(widget.videoItem.id),
      );
      _tracksEditedInThisPanel = false;
      final previousPath = _previewPath;
      _previewPath = null;
      unawaited(_manager.deletePreview(previousPath));
    }
  }

  @override
  void dispose() {
    _manager.removeListener(_onManagerChanged);
    unawaited(_manager.deletePreview(_previewPath));
    super.dispose();
  }

  void _onManagerChanged() {
    if (!mounted) return;
    final job = _manager.job;
    if (job?.videoId == widget.videoItem.id &&
        job?.status == OcrSubtitleJobStatus.completed &&
        job?.outputPaths.isNotEmpty == true) {
      final completedPaths = _manager.consumeCompletedPaths(
        widget.videoItem.id,
      );
      if (completedPaths != null && completedPaths.isNotEmpty) {
        final deliveryKey = completedPaths.join('|');
        if (_deliveredPath != deliveryKey) {
          _deliveredPath = deliveryKey;
          widget.onCompleted(completedPaths);
        }
      }
    }
    final latestTracks = _manager.tracksForVideo(widget.videoItem.id);
    if (!_tracksEditedInThisPanel) {
      _tracks = List<OcrSubtitleTrack>.from(latestTracks);
    }
    setState(() {});
  }

  Future<void> _refreshModelAndEstimate() async {
    await _manager.initialize();
    final languages = _tracks.map((track) => track.language).toSet();
    final installedStates = await Future.wait(
      languages.map(_manager.isModelInstalled),
    );
    final estimate = await _manager.estimateDuration(
      mediaDuration: widget.duration,
      start: Duration(milliseconds: _startMs.round()),
      end: Duration(milliseconds: _endMs.round()),
      trackCount: _tracks.length,
    );
    if (mounted) {
      setState(() {
        if (!_tracksEditedInThisPanel) {
          _tracks = List<OcrSubtitleTrack>.from(
            _manager.tracksForVideo(widget.videoItem.id),
          );
        }
        _modelInstalled = installedStates.every((installed) => installed);
        _estimate = estimate;
      });
    }
  }

  Future<void> _selectRegion() async {
    final wasPlaying = await widget.pauseForRegionSelection();
    String? capturedPath;
    try {
      final initialPosition = widget.currentPosition();
      final path = await _manager.captureFrame(
        videoId: widget.videoItem.id,
        videoPath: widget.videoItem.path,
        position: initialPosition,
        mirrorHorizontal: widget.videoItem.isVideoMirroredH,
        mirrorVertical: widget.videoItem.isVideoMirroredV,
      );
      capturedPath = path;
      if (!mounted) return;
      final result = await showOcrRegionEditor(
        context,
        framePath: path,
        initialRegions: _tracks.map((track) => track.region).toList(),
        duration: widget.duration,
        initialPosition: initialPosition,
        loadFrameAt: (position) => _manager.captureFrame(
          videoId: widget.videoItem.id,
          videoPath: widget.videoItem.path,
          position: position,
          mirrorHorizontal: widget.videoItem.isVideoMirroredH,
          mirrorVertical: widget.videoItem.isVideoMirroredV,
          maxWidth: 960,
        ),
        loadFastFrameAt: (position) => _manager.captureFrame(
          videoId: widget.videoItem.id,
          videoPath: widget.videoItem.path,
          position: position,
          mirrorHorizontal: widget.videoItem.isVideoMirroredH,
          mirrorVertical: widget.videoItem.isVideoMirroredV,
          maxWidth: 480,
          fastPreview: true,
        ),
        releaseFrame: _manager.deletePreview,
      );
      if (result != null && mounted) {
        final previousPath = _previewPath;
        final updatedTracks = _manualTracksForRegions(result);
        setState(() {
          _tracks = updatedTracks;
          _tracksEditedInThisPanel = true;
          _previewPath = path;
        });
        _manager.rememberTracks(widget.videoItem.id, updatedTracks);
        unawaited(_refreshModelAndEstimate());
        capturedPath = null;
        unawaited(_manager.deletePreview(previousPath));
      }
    } catch (error) {
      if (mounted) AppToast.show('无法打开字幕区域：$error', type: AppToastType.error);
    } finally {
      await _manager.deletePreview(capturedPath);
      await widget.restorePlayback(wasPlaying);
    }
  }

  List<OcrSubtitleTrack> _manualTracksForRegions(
    List<NormalizedOcrRegion> regions,
  ) {
    final available = <int>{
      for (var index = 0; index < _tracks.length; index++) index,
    };
    final fallbackLanguage = _tracks.isEmpty
        ? OcrSubtitleLanguage.chinese
        : _tracks.first.language;
    return <OcrSubtitleTrack>[
      for (var regionIndex = 0; regionIndex < regions.length; regionIndex++)
        () {
          var bestIndex = -1;
          var bestOverlap = 0.0;
          for (final trackIndex in available) {
            final overlap = regions[regionIndex].intersectionOverUnion(
              _tracks[trackIndex].region,
            );
            if (overlap > bestOverlap) {
              bestOverlap = overlap;
              bestIndex = trackIndex;
            }
          }
          if (bestIndex >= 0) available.remove(bestIndex);
          return OcrSubtitleTrack(
            number: regionIndex + 1,
            region: regions[regionIndex],
            language: bestIndex >= 0 && bestOverlap >= 0.12
                ? _tracks[bestIndex].language
                : fallbackLanguage,
          );
        }(),
    ];
  }

  Future<void> _start() async {
    if (_manager.isRunning) {
      AppToast.show('已有 OCR 字幕任务正在运行', type: AppToastType.info);
      return;
    }
    final start = _customRange
        ? Duration(milliseconds: _startMs.round())
        : Duration.zero;
    final end = _customRange
        ? Duration(milliseconds: _endMs.round())
        : widget.duration;
    if (end <= start) {
      AppToast.show('结束时间必须晚于开始时间', type: AppToastType.info);
      return;
    }
    final request = OcrSubtitleJob(
      videoId: widget.videoItem.id,
      videoPath: widget.videoItem.path,
      tracks: _tracks,
      start: start,
      end: end,
      mirrorHorizontal: widget.videoItem.isVideoMirroredH,
      mirrorVertical: widget.videoItem.isVideoMirroredV,
    );
    await _manager.start(request);
  }

  @override
  Widget build(BuildContext context) {
    final managerJob = _manager.job;
    final ownsJob = managerJob?.videoId == widget.videoItem.id;
    final running = managerJob?.isRunning ?? false;
    final job = ownsJob || running ? managerJob : null;
    final runningOtherVideo = running && !ownsJob;
    return Container(
      color: const Color(0xFF17191D),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: widget.onBack,
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                ),
                const SizedBox(width: 4),
                const Expanded(
                  child: Text(
                    'OCR 字幕',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Icon(
                  Icons.document_scanner_outlined,
                  color: Color(0xFF65A2FF),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _card(
              title: '字幕区域',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_previewPath != null && File(_previewPath!).existsSync())
                    SizedBox(
                      height: 118,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _tracks.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (context, index) => SizedBox(
                          width: 190,
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: OcrRegionPreview(
                                    imagePath: _previewPath!,
                                    region: _tracks[index].region,
                                  ),
                                ),
                              ),
                              Positioned(
                                left: 6,
                                top: 6,
                                child: _numberBadge(index + 1),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 9),
                  for (final track in _tracks)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        '区域 ${track.number} · ${_regionSummary(track.region)}',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  const SizedBox(height: 5),
                  const Text(
                    '下方任务会锁定使用这组坐标；切换页面或横竖屏不会恢复默认范围。',
                    style: TextStyle(color: Colors.white38, fontSize: 10),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: running ? null : _selectRegion,
                        icon: const Icon(Icons.crop_free),
                        label: const Text('精确框选字幕区域'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _card(
              title: '识别设置',
              child: Column(
                children: [
                  for (var index = 0; index < _tracks.length; index++) ...[
                    Row(
                      children: [
                        _numberBadge(index + 1),
                        const SizedBox(width: 9),
                        Expanded(
                          child: DropdownButtonFormField<OcrSubtitleLanguage>(
                            key: ValueKey(
                              'ocr_language_${index}_${_tracks[index].language.name}',
                            ),
                            initialValue: _tracks[index].language,
                            dropdownColor: const Color(0xFF252930),
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              labelText: '区域 ${index + 1} 的字幕语言',
                              border: const OutlineInputBorder(),
                              isDense: true,
                            ),
                            items: [
                              for (final language in OcrSubtitleLanguage.values)
                                DropdownMenuItem(
                                  value: language,
                                  child: Text(language.label),
                                ),
                            ],
                            onChanged: running
                                ? null
                                : (value) {
                                    if (value == null) return;
                                    setState(() {
                                      _tracks[index] = _tracks[index].copyWith(
                                        language: value,
                                      );
                                      _tracksEditedInThisPanel = true;
                                    });
                                    _manager.rememberTracks(
                                      widget.videoItem.id,
                                      _tracks,
                                    );
                                    _refreshModelAndEstimate();
                                  },
                          ),
                        ),
                      ],
                    ),
                    if (index != _tracks.length - 1) const SizedBox(height: 10),
                  ],
                  const SizedBox(height: 4),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      '自选时间范围',
                      style: TextStyle(color: Colors.white),
                    ),
                    subtitle: Text(
                      _customRange
                          ? '${_formatMs(_startMs)} — ${_formatMs(_endMs)}'
                          : '整个视频',
                      style: const TextStyle(color: Colors.white54),
                    ),
                    value: _customRange,
                    onChanged: running
                        ? null
                        : (value) => setState(() => _customRange = value),
                  ),
                  if (_customRange) ...[
                    RangeSlider(
                      values: RangeValues(_startMs, _endMs),
                      min: 0,
                      max: widget.duration.inMilliseconds.toDouble().clamp(
                        1,
                        double.infinity,
                      ),
                      labels: RangeLabels(
                        _formatMs(_startMs),
                        _formatMs(_endMs),
                      ),
                      onChanged: running
                          ? null
                          : (value) => setState(() {
                              _startMs = value.start;
                              _endMs = value.end;
                            }),
                      onChangeEnd: (_) => _refreshModelAndEstimate(),
                    ),
                  ],
                  Row(
                    children: [
                      Icon(
                        _modelInstalled
                            ? Icons.offline_pin
                            : Icons.inventory_2_outlined,
                        size: 17,
                        color: _modelInstalled
                            ? Colors.greenAccent
                            : const Color(0xFF65A2FF),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          _modelInstalled
                              ? '所选语言模型均已就绪，可完全离线识别'
                              : '全部模型已内置；首次开始仅复制并校验，无需下载',
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _card(
              title: '处理流程',
              child: Text(
                '内置 ${_manager.totalBundledOnnxModelCount} 个 ONNX 模型，当前有 ${_tracks.length} 个独立字幕区域。\n'
                '① 按编号串行处理各区域  →  ② 每种语言实测 CPU/GPU  →  '
                '③ 首个 5 秒校准 ETA，其后每 15 秒按真实 PTS 提取 10 FPS 候选帧  →  '
                '④ SSIM 变化筛选与双帧 OCR  →  ⑤ 每个区域分别保存一个 SRT。\n'
                '每张图片处理后立即删除；取消、失败、重启或永久删除视频时也会清理。',
                style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 12,
                  height: 1.55,
                ),
              ),
            ),
            const SizedBox(height: 12),
            _card(
              title: running || job != null ? '任务状态' : '准备开始',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    runningOtherVideo
                        ? '正在处理其他视频的 OCR 字幕'
                        : _taskStatusText(job),
                    style: const TextStyle(color: Colors.white70),
                  ),
                  if (job?.error != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      job!.error!,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 11,
                      ),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 10),
                  LinearProgressIndicator(
                    value: job == null ? 0 : job.progress.clamp(0, 1),
                    minHeight: 6,
                  ),
                  const SizedBox(height: 7),
                  Text(
                    running
                        ? '${((job?.progress ?? 0) * 100).round()}%  ·  '
                              '剩余约 ${_formatDuration(job?.remaining)}  ·  '
                              '${_manager.activeBackend}'
                        : '${((job?.progress ?? 0) * 100).round()}%',
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                  const SizedBox(height: 12),
                  if (running)
                    OutlinedButton.icon(
                      onPressed: _manager.cancel,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('取消任务'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: _start,
                      icon: const Icon(Icons.document_scanner_outlined),
                      label: Text(
                        job?.status == OcrSubtitleJobStatus.failed
                            ? '重试 OCR 识别'
                            : '开始 OCR 识别',
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card({required String title, required Widget child}) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFF20242A),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Colors.white10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 12),
        child,
      ],
    ),
  );

  Widget _numberBadge(int number) => Container(
    width: 26,
    height: 26,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: const Color(0xFF65A2FF),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Text(
      '$number',
      style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w800),
    ),
  );

  String _regionSummary(NormalizedOcrRegion region) =>
      'X ${(100 * region.left).toStringAsFixed(1)}% · '
      'Y ${(100 * region.top).toStringAsFixed(1)}% · '
      '宽 ${(100 * region.width).toStringAsFixed(1)}% · '
      '高 ${(100 * region.height).toStringAsFixed(1)}%';

  String _formatMs(double value) =>
      _formatDuration(Duration(milliseconds: value.round()));

  String _taskStatusText(OcrSubtitleJob? job) {
    if (job == null) return '预计耗时 ${_formatDuration(_estimate)}';
    return switch (job.status) {
      OcrSubtitleJobStatus.preparing => '正在准备 OCR 引擎',
      OcrSubtitleJobStatus.downloading => '正在校验内置模型',
      OcrSubtitleJobStatus.extracting ||
      OcrSubtitleJobStatus.recognizing => '正在处理 OCR 字幕',
      OcrSubtitleJobStatus.writing => '正在保存字幕',
      _ => job.statusMessage,
    };
  }

  String _formatDuration(Duration? value) {
    if (value == null) return '计算中';
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60);
    final seconds = value.inSeconds.remainder(60);
    return hours > 0
        ? '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}'
        : '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}
