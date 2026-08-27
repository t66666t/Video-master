import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../../models/subtitle_model.dart';
import '../../models/subtitle_style.dart';
import '../../widgets/subtitle_overlay.dart';

typedef PreciseRenderProgress = void Function(double progress);
typedef PreciseRenderArtifact = void Function(String path);

class PreciseSubtitleAssets {
  final String concatPath;
  final int frameCount;

  const PreciseSubtitleAssets({
    required this.concatPath,
    required this.frameCount,
  });
}

class VideoComposePreciseRenderer {
  bool _cancelled = false;

  void resetCancellation() => _cancelled = false;
  void cancel() => _cancelled = true;

  Future<PreciseSubtitleAssets> render({
    required Directory outputDirectory,
    required int width,
    required int height,
    required Duration duration,
    required List<SubtitleItem> primary,
    required List<SubtitleItem> secondary,
    required SubtitleStyle style,
    required Alignment alignment,
    required bool splitSubtitleByLine,
    required double itemGap,
    required PreciseRenderProgress onProgress,
    required PreciseRenderArtifact onArtifact,
  }) async {
    resetCancellation();
    await outputDirectory.create(recursive: true);
    onArtifact(outputDirectory.path);
    final List<_SubtitleSceneSegment> segments = _buildSegments(
      duration: duration,
      primary: primary,
      secondary: secondary,
      splitSubtitleByLine: splitSubtitleByLine,
    );
    if (segments.isEmpty) {
      throw StateError('无法生成精确字幕时间线');
    }

    final Map<String, String> renderedFrames = <String, String>{};
    final StringBuffer concat = StringBuffer('ffconcat version 1.0\n');
    for (int i = 0; i < segments.length; i++) {
      _throwIfCancelled();
      final _SubtitleSceneSegment segment = segments[i];
      final List<SubtitleOverlayEntry> entries = await _loadEntries(
        segment.entries,
      );
      _throwIfCancelled();
      final String signature = _sceneSignature(segment.entries);
      String? framePath = renderedFrames[signature];
      if (framePath == null) {
        framePath = p.join(
          outputDirectory.path,
          'frame_${renderedFrames.length.toString().padLeft(6, '0')}.png',
        );
        final Uint8List png;
        try {
          png = await _renderWidgetToPng(
            width: width,
            height: height,
            entries: entries,
            style: style,
            alignment: alignment,
            itemGap: itemGap,
          );
        } catch (error) {
          throw StateError('精确字幕场景 ${i + 1}/${segments.length} 渲染失败：$error');
        }
        await File(framePath).writeAsBytes(png, flush: true);
        onArtifact(framePath);
        renderedFrames[signature] = framePath;
      }
      concat.writeln("file '${_escapeConcatPath(framePath)}'");
      concat.writeln('duration ${(segment.endMs - segment.startMs) / 1000.0}');
      onProgress((i + 1) / segments.length);
      await Future<void>.delayed(Duration.zero);
    }
    // concat demuxer 需要重复最后一帧，才能应用最后一个 duration。
    final String? lastPath =
        renderedFrames[_sceneSignature(segments.last.entries)];
    if (lastPath == null) {
      throw StateError('精确字幕时间线缺少最后一帧');
    }
    concat.writeln("file '${_escapeConcatPath(lastPath)}'");

    final String concatPath = p.join(
      outputDirectory.path,
      'subtitles.ffconcat',
    );
    await File(concatPath).writeAsString(concat.toString(), flush: true);
    onArtifact(concatPath);
    return PreciseSubtitleAssets(
      concatPath: concatPath,
      frameCount: renderedFrames.length,
    );
  }

  List<_SubtitleSceneSegment> _buildSegments({
    required Duration duration,
    required List<SubtitleItem> primary,
    required List<SubtitleItem> secondary,
    required bool splitSubtitleByLine,
  }) {
    final int maxSubtitleEnd = <SubtitleItem>[...primary, ...secondary]
        .fold<int>(
          0,
          (value, item) => item.endTime.inMilliseconds > value
              ? item.endTime.inMilliseconds
              : value,
        );
    final int endMs = duration.inMilliseconds > 0
        ? duration.inMilliseconds
        : maxSubtitleEnd;
    if (endMs <= 0) return const <_SubtitleSceneSegment>[];
    final Set<int> boundaries = <int>{0, endMs};
    for (final SubtitleItem item in <SubtitleItem>[...primary, ...secondary]) {
      boundaries.add(item.startTime.inMilliseconds.clamp(0, endMs));
      boundaries.add(item.endTime.inMilliseconds.clamp(0, endMs));
    }
    final List<int> times = boundaries.toList()..sort();
    final List<_SubtitleSceneSegment> result = <_SubtitleSceneSegment>[];
    for (int i = 0; i < times.length - 1; i++) {
      final int start = times[i];
      final int end = times[i + 1];
      if (end <= start) continue;
      final List<SubtitleItem> activePrimary = primary
          .where(
            (item) =>
                item.startTime.inMilliseconds <= start &&
                item.endTime.inMilliseconds > start,
          )
          .toList();
      final List<SubtitleItem> activeSecondary = secondary
          .where(
            (item) =>
                item.startTime.inMilliseconds <= start &&
                item.endTime.inMilliseconds > start,
          )
          .toList();
      final List<_PendingOverlayEntry> entries = <_PendingOverlayEntry>[];
      if (activePrimary.isNotEmpty) {
        for (final SubtitleItem item in activePrimary) {
          String text = item.imageLoader == null ? item.text : '';
          String? secondaryText;
          if (item.imageLoader == null) {
            if (activeSecondary.isNotEmpty) {
              final List<SubtitleItem> sorted =
                  List<SubtitleItem>.from(activeSecondary)..sort(
                    (a, b) =>
                        (a.startTime.inMilliseconds -
                                item.startTime.inMilliseconds)
                            .abs()
                            .compareTo(
                              (b.startTime.inMilliseconds -
                                      item.startTime.inMilliseconds)
                                  .abs(),
                            ),
                  );
              secondaryText = sorted.first.text;
            } else if (splitSubtitleByLine && text.contains('\n')) {
              final List<String> lines = text.split('\n');
              text = lines.first;
              secondaryText = lines.skip(1).join('\n');
            }
          }
          entries.add(
            _PendingOverlayEntry(
              index: item.index,
              text: text,
              secondaryText: secondaryText,
              imageLoader: item.imageLoader,
            ),
          );
        }
      } else {
        for (final SubtitleItem item in activeSecondary) {
          entries.add(
            _PendingOverlayEntry(
              index: item.index,
              text: '',
              secondaryText: item.text,
              imageLoader: item.imageLoader,
            ),
          );
        }
      }
      final String signature = _sceneSignature(entries);
      if (result.isNotEmpty &&
          _sceneSignature(result.last.entries) == signature &&
          result.last.endMs == start) {
        result[result.length - 1] = _SubtitleSceneSegment(
          startMs: result.last.startMs,
          endMs: end,
          entries: entries,
        );
      } else {
        result.add(
          _SubtitleSceneSegment(startMs: start, endMs: end, entries: entries),
        );
      }
    }
    return result;
  }

  Future<List<SubtitleOverlayEntry>> _loadEntries(
    List<_PendingOverlayEntry> entries,
  ) async {
    final List<SubtitleOverlayEntry> loaded = <SubtitleOverlayEntry>[];
    for (final _PendingOverlayEntry entry in entries) {
      _throwIfCancelled();
      loaded.add(
        SubtitleOverlayEntry(
          index: entry.index,
          text: entry.text,
          secondaryText: entry.secondaryText,
          image: await entry.imageLoader?.call(),
        ),
      );
    }
    return loaded;
  }

  Future<Uint8List> _renderWidgetToPng({
    required int width,
    required int height,
    required List<SubtitleOverlayEntry> entries,
    required SubtitleStyle style,
    required Alignment alignment,
    required double itemGap,
  }) async {
    final ui.FlutterView view =
        WidgetsBinding.instance.platformDispatcher.views.first;
    // 按当前视图的 DPR 超采样渲染，使阴影/模糊的采样密度与屏幕上
    // 的悬浮字幕一致。之前固定 1.0 倍率会导致烧录字幕的阴影比软件里
    // 看到的更锐利、更黑（文字边缘也更糙）。
    //
    // 超采样后的渲染尺寸上限约 8192 像素（与 ffmpeg 常用安全上限一致），
    // 仅在超大分辨率（如 4K/8K 视频）时才可能压缩倍率，避免内存/性能问题。
    final double dpr = view.devicePixelRatio > 0 ? view.devicePixelRatio : 1.0;
    double supersample = dpr;
    final double maxAllowed = 8192.0 / math.max(width, height);
    if (supersample > maxAllowed) supersample = maxAllowed;
    if (supersample < 1.0) supersample = 1.0;
    final Size size = Size(width.toDouble(), height.toDouble());
    final Size renderSize = Size(
      width * supersample,
      height * supersample,
    );
    final PipelineOwner pipelineOwner = PipelineOwner();
    final BuildOwner buildOwner = BuildOwner(focusManager: FocusManager());
    final RenderRepaintBoundary boundary = RenderRepaintBoundary();
    final RenderView renderView = RenderView(
      view: view,
      configuration: ViewConfiguration(
        logicalConstraints: BoxConstraints.tight(size),
        physicalConstraints: BoxConstraints.tight(renderSize),
        devicePixelRatio: supersample,
      ),
      child: boundary,
    );
    renderView.attach(pipelineOwner);
    renderView.prepareInitialFrame();
    ui.Image? image;
    ui.Image? outputImage;
    RenderObjectToWidgetElement<RenderBox>? rootElement;
    try {
      final Widget rootWidget = Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: MediaQueryData(
            size: size,
            devicePixelRatio: supersample,
          ),
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: SubtitleOverlayGroup(
              entries: entries,
              style: style,
              referenceHeight: size.height,
              alignment: alignment,
              itemGap: itemGap,
              isVisualOnly: true,
            ),
          ),
        ),
      );
      final RenderObjectToWidgetElement<RenderBox> root = rootElement =
          RenderObjectToWidgetAdapter<RenderBox>(
            container: boundary,
            child: rootWidget,
          ).attachToRenderTree(buildOwner);
      buildOwner.buildScope(root);
      for (final SubtitleOverlayEntry entry in entries) {
        final Uint8List? bytes = entry.image;
        if (bytes != null) {
          await precacheImage(MemoryImage(bytes), root);
        }
      }
      buildOwner.buildScope(root);
      pipelineOwner.flushLayout();
      pipelineOwner.flushCompositingBits();
      pipelineOwner.flushPaint();
      buildOwner.finalizeTree();
      image = boundary.toImageSync(pixelRatio: supersample);
      if (supersample > 1.0001) {
        // 高分辨率帧缩小回目标分辨率，阴影边缘经过高质量重采样，
        // 视觉上与屏幕渲染一致。
        outputImage = await _downscaleImage(
          image,
          targetWidth: width,
          targetHeight: height,
        );
      } else {
        outputImage = image;
      }
      final ByteData? data = await outputImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (data == null) throw StateError('精确字幕图像编码失败');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      if (outputImage != null && !identical(outputImage, image)) {
        outputImage.dispose();
      }
      image?.dispose();
      if (rootElement != null) {
        rootElement = RenderObjectToWidgetAdapter<RenderBox>(
          container: boundary,
        ).attachToRenderTree(buildOwner, rootElement);
        buildOwner.buildScope(rootElement);
        buildOwner.finalizeTree();
      }
      renderView.detach();
      buildOwner.focusManager.dispose();
    }
  }

  /// 将超采样渲染的高分辨率帧缩回目标分辨率。
  /// 使用 [ui.FilterQuality.high] 重采样，保证阴影边缘的平滑过渡。
  Future<ui.Image> _downscaleImage(
    ui.Image source, {
    required int targetWidth,
    required int targetHeight,
  }) {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      source,
      Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      Rect.fromLTWH(0, 0, targetWidth.toDouble(), targetHeight.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    return recorder.endRecording().toImage(targetWidth, targetHeight);
  }

  String _sceneSignature(List<_PendingOverlayEntry> entries) => entries
      .map(
        (entry) =>
            '${entry.index}|${entry.text}|${entry.secondaryText}|${entry.imageLoader != null}',
      )
      .join('\u001e');

  String _escapeConcatPath(String path) =>
      path.replaceAll('\\', '/').replaceAll("'", r"'\''");

  void _throwIfCancelled() {
    if (_cancelled) throw StateError('视频合成已取消');
  }
}

class _SubtitleSceneSegment {
  final int startMs;
  final int endMs;
  final List<_PendingOverlayEntry> entries;

  const _SubtitleSceneSegment({
    required this.startMs,
    required this.endMs,
    required this.entries,
  });
}

class _PendingOverlayEntry {
  final int? index;
  final String text;
  final String? secondaryText;
  final Future<Uint8List?> Function()? imageLoader;

  const _PendingOverlayEntry({
    required this.index,
    required this.text,
    required this.secondaryText,
    required this.imageLoader,
  });
}
