import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as im;
import 'package:onnxruntime_v2/onnxruntime_v2.dart';

import 'ocr_model_manager.dart';

class OcrTextResult {
  final String text;
  final double confidence;
  final List<OcrTextLineResult> lines;
  const OcrTextResult(this.text, this.confidence, [this.lines = const []]);
}

class OcrTextLineResult {
  final String text;
  final double confidence;
  final int left;
  final int top;
  final int right;
  final int bottom;

  const OcrTextLineResult({
    required this.text,
    required this.confidence,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  int get width => right - left;
  int get height => bottom - top;
}

class OcrDetectedBox {
  final int left;
  final int top;
  final int right;
  final int bottom;
  final double score;
  const OcrDetectedBox(
    this.left,
    this.top,
    this.right,
    this.bottom,
    this.score,
  );
}

/// Lightweight PP-OCRv4 ONNX runner. Detection post-processing intentionally
/// uses connected components instead of OpenCV so the same code runs on all
/// Flutter desktop and mobile targets.
class OcrInferenceEngine {
  final OcrModelFiles files;
  final bool preferHardwareAcceleration;
  OrtSession? _detSession;
  OrtSession? _recSession;
  OrtSessionOptions? _sessionOptions;
  List<String> _characters = const [];
  String activeBackend = 'CPU';

  OcrInferenceEngine(this.files, {this.preferHardwareAcceleration = false});

  Future<void> initializeDetectionOnly({int cpuThreads = 1}) async {
    if (_detSession != null) return;
    OrtEnv.instance.init();
    final detectionBytes = await File(files.detection).readAsBytes();
    if (preferHardwareAcceleration &&
        await _tryInitializeDetectionAccelerated(detectionBytes)) {
      return;
    }
    final options = _baseOptions(cpuThreads: math.max(1, cpuThreads));
    try {
      _sessionOptions = options;
      _detSession = OrtSession.fromBuffer(detectionBytes, options);
      activeBackend = 'CPU（${math.max(1, cpuThreads)} 线程）';
    } catch (error) {
      options.release();
      throw StateError('OCR 文字检测模型无法加载（$error）');
    }
  }

  Future<void> initialize() async {
    OrtEnv.instance.init();
    final detectionBytes = await File(files.detection).readAsBytes();
    final recognitionBytes = await File(files.recognition).readAsBytes();
    if (preferHardwareAcceleration) {
      final accelerated = await _tryInitializeAccelerated(
        detectionBytes,
        recognitionBytes,
      );
      if (accelerated) {
        final lines = await File(files.dictionary).readAsLines();
        _characters = <String>[
          '',
          ...lines.where((line) => line.isNotEmpty),
          ' ',
        ];
        return;
      }
    }

    final options = _baseOptions(cpuThreads: _recommendedCpuThreads);
    try {
      _sessionOptions = options;
      _detSession = OrtSession.fromBuffer(detectionBytes, options);
      _recSession = OrtSession.fromBuffer(recognitionBytes, options);
      activeBackend = 'CPU（$_recommendedCpuThreads 线程）';
    } catch (error) {
      options.release();
      throw StateError('OCR 模型无法加载，请删除该语言模型后重新下载（$error）');
    }
    final lines = await File(files.dictionary).readAsLines();
    _characters = <String>['', ...lines.where((line) => line.isNotEmpty), ' '];
  }

  int get _recommendedCpuThreads =>
      math.max(1, math.min(2, Platform.numberOfProcessors - 1));

  OrtSessionOptions _baseOptions({required int cpuThreads}) =>
      OrtSessionOptions()
        ..setIntraOpNumThreads(cpuThreads)
        ..setInterOpNumThreads(1)
        ..setSessionExecutionMode(OrtSessionExecutionMode.ortSequential)
        ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);

  Future<bool> _tryInitializeAccelerated(
    Uint8List detectionBytes,
    Uint8List recognitionBytes,
  ) async {
    OrtSessionOptions? options;
    OrtSession? detection;
    try {
      final providers = OrtEnv.instance.availableProviders();
      options = _baseOptions(cpuThreads: 1);
      String? label;
      if (Platform.isWindows && providers.contains(OrtProvider.directml)) {
        options.appendDirectMLProvider(const {'device_id': '0'});
        label = 'GPU · DirectML';
      } else if ((Platform.isMacOS || Platform.isIOS) &&
          providers.contains(OrtProvider.coreml)) {
        options.appendCoreMLProvider(CoreMLFlags.useNone);
        label = 'GPU/NPU · CoreML';
      } else if (Platform.isAndroid && providers.contains(OrtProvider.nnapi)) {
        options.appendNnapiProvider(NnapiFlags.useNone);
        label = 'GPU/NPU · NNAPI';
      }
      if (label == null) {
        options.release();
        return false;
      }
      detection = OrtSession.fromBuffer(detectionBytes, options);
      final recognition = OrtSession.fromBuffer(recognitionBytes, options);
      _sessionOptions = options;
      _detSession = detection;
      _recSession = recognition;
      activeBackend = label;
      return true;
    } catch (_) {
      await detection?.release();
      options?.release();
      return false;
    }
  }

  Future<bool> _tryInitializeDetectionAccelerated(
    Uint8List detectionBytes,
  ) async {
    OrtSessionOptions? options;
    OrtSession? detection;
    try {
      final providers = OrtEnv.instance.availableProviders();
      options = _baseOptions(cpuThreads: 1);
      String? label;
      if (Platform.isWindows && providers.contains(OrtProvider.directml)) {
        options.appendDirectMLProvider(const {'device_id': '0'});
        label = 'GPU · DirectML';
      } else if ((Platform.isMacOS || Platform.isIOS) &&
          providers.contains(OrtProvider.coreml)) {
        options.appendCoreMLProvider(CoreMLFlags.useNone);
        label = 'GPU/NPU · CoreML';
      } else if (Platform.isAndroid && providers.contains(OrtProvider.nnapi)) {
        options.appendNnapiProvider(NnapiFlags.useNone);
        label = 'GPU/NPU · NNAPI';
      }
      if (label == null) {
        options.release();
        return false;
      }
      detection = OrtSession.fromBuffer(detectionBytes, options);
      _sessionOptions = options;
      _detSession = detection;
      activeBackend = label;
      return true;
    } catch (_) {
      detection?.release();
      options?.release();
      return false;
    }
  }

  Future<OcrTextResult> recognizeFile(String path) async {
    final bytes = await File(path).readAsBytes();
    final image = im.decodeImage(bytes);
    if (image == null) return const OcrTextResult('', 0);
    return recognizeImage(image);
  }

  Future<OcrTextResult> recognizeImage(im.Image source) async {
    if (_detSession == null || _recSession == null) await initialize();
    final boxes = await detectBoxesImage(source);
    if (boxes.isEmpty) return const OcrTextResult('', 0);
    final results =
        <
          ({
            String text,
            double confidence,
            int top,
            int left,
            int right,
            int bottom,
          })
        >[];
    for (final box in boxes) {
      final crop = im.copyCrop(
        source,
        x: box.left,
        y: box.top,
        width: math.max(1, box.right - box.left),
        height: math.max(1, box.bottom - box.top),
      );
      final result = await _recognizeLine(crop);
      final combinedConfidence = result.confidence * box.score;
      if (result.text.trim().isNotEmpty &&
          result.confidence >= 0.40 &&
          combinedConfidence >= 0.32) {
        results.add((
          text: result.text.trim(),
          confidence: combinedConfidence,
          top: box.top,
          left: box.left,
          right: box.right,
          bottom: box.bottom,
        ));
      }
    }
    if (results.isEmpty) return const OcrTextResult('', 0);
    // PP-OCR is deliberately sensitive and also finds watermarks and tiny UI
    // labels inside a manually selected subtitle band. Subtitle glyphs in one
    // band normally share a scale, so reject components that are both tiny in
    // the crop and clear scale outliers before assembling the text. Keep the
    // threshold relative so this remains resolution independent.
    final referenceHeight = results
        .map((item) => item.bottom - item.top)
        .reduce(math.max);
    final minimumHeight = math.max(
      4,
      math.max(
        (source.height * 0.045).round(),
        (referenceHeight * 0.55).round(),
      ),
    );
    results.removeWhere(
      (item) =>
          item.bottom - item.top < minimumHeight ||
          (item.confidence < 0.40 &&
              item.right - item.left < source.width * 0.08),
    );
    if (results.isEmpty) return const OcrTextResult('', 0);
    results.sort((a, b) {
      final dy = a.top - b.top;
      return dy.abs() > source.height * 0.08 ? dy : a.left - b.left;
    });
    final lines =
        <
          List<
            ({
              String text,
              double confidence,
              int top,
              int left,
              int right,
              int bottom,
            })
          >
        >[];
    for (final item in results) {
      if (lines.isEmpty ||
          (item.top - lines.last.first.top).abs() > source.height * 0.08) {
        lines.add([item]);
      } else {
        lines.last.add(item);
      }
    }
    final recognizedLines = lines.map((line) {
      line.sort((a, b) => a.left - b.left);
      return OcrTextLineResult(
        text: line.map((item) => item.text).join(' '),
        confidence:
            line.fold<double>(0, (value, item) => value + item.confidence) /
            line.length,
        left: line.map((item) => item.left).reduce(math.min),
        top: line.map((item) => item.top).reduce(math.min),
        right: line.map((item) => item.right).reduce(math.max),
        bottom: line.map((item) => item.bottom).reduce(math.max),
      );
    }).toList();
    final text = recognizedLines.map((line) => line.text).join('\n');
    final confidence =
        recognizedLines.fold<double>(
          0,
          (value, line) => value + line.confidence,
        ) /
        recognizedLines.length;
    return OcrTextResult(text, confidence, recognizedLines);
  }

  Future<List<OcrDetectedBox>> detectBoxesImage(
    im.Image source, {
    int maxSide = 640,
  }) async {
    if (_detSession == null) await initializeDetectionOnly();
    final limit = math.max(32, maxSide);
    final scale = math.min(1.0, limit / math.max(source.width, source.height));
    final width = math.max(32, ((source.width * scale) / 32).round() * 32);
    final height = math.max(32, ((source.height * scale) / 32).round() * 32);
    final resized = im.copyResize(source, width: width, height: height);
    final data = Float32List(3 * width * height);
    final plane = width * height;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final pixel = resized.getPixel(x, y);
        final i = y * width + x;
        data[i] = (pixel.r / 255.0 - 0.5) / 0.5;
        data[plane + i] = (pixel.g / 255.0 - 0.5) / 0.5;
        data[plane * 2 + i] = (pixel.b / 255.0 - 0.5) / 0.5;
      }
    }
    final input = OrtValueTensor.createTensorWithDataList(data, [
      1,
      3,
      height,
      width,
    ]);
    final runOptions = OrtRunOptions();
    final outputs = _detSession!.run(runOptions, {
      _detSession!.inputNames.first: input,
    });
    input.release();
    runOptions.release();
    if (outputs.isEmpty || outputs.first == null) {
      return const [];
    }
    final raw = outputs.first!.value;
    for (final output in outputs) {
      output?.release();
    }
    final map = _unwrapProbabilityMap(raw);
    if (map.isEmpty || map.first.isEmpty) return const [];
    final mapHeight = map.length;
    final mapWidth = map.first.length;
    final visited = Uint8List(mapWidth * mapHeight);
    final found = <OcrDetectedBox>[];
    for (var sy = 0; sy < mapHeight; sy++) {
      for (var sx = 0; sx < mapWidth; sx++) {
        final startIndex = sy * mapWidth + sx;
        if (visited[startIndex] != 0 || map[sy][sx] < 0.3) continue;
        final queueX = <int>[sx];
        final queueY = <int>[sy];
        visited[startIndex] = 1;
        var cursor = 0;
        var minX = sx;
        var maxX = sx;
        var minY = sy;
        var maxY = sy;
        var score = 0.0;
        var count = 0;
        while (cursor < queueX.length) {
          final x = queueX[cursor];
          final y = queueY[cursor++];
          score += map[y][x];
          count++;
          minX = math.min(minX, x);
          maxX = math.max(maxX, x);
          minY = math.min(minY, y);
          maxY = math.max(maxY, y);
          for (final pair in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
            final nx = x + pair.$1;
            final ny = y + pair.$2;
            if (nx < 0 || ny < 0 || nx >= mapWidth || ny >= mapHeight) continue;
            final index = ny * mapWidth + nx;
            if (visited[index] == 0 && map[ny][nx] >= 0.3) {
              visited[index] = 1;
              queueX.add(nx);
              queueY.add(ny);
            }
          }
        }
        if (count < 8 || score / count < 0.45) continue;
        final padX = math.max(2, ((maxX - minX + 1) * 0.25).round());
        final padY = math.max(2, ((maxY - minY + 1) * 0.35).round());
        final left =
            (((minX - padX).clamp(0, mapWidth - 1)) * source.width / mapWidth)
                .floor();
        final right =
            ((((maxX + padX + 1).clamp(1, mapWidth)) * source.width / mapWidth)
                    .ceil())
                .clamp(left + 1, source.width);
        final top =
            (((minY - padY).clamp(0, mapHeight - 1)) *
                    source.height /
                    mapHeight)
                .floor();
        final bottom =
            ((((maxY + padY + 1).clamp(1, mapHeight)) *
                        source.height /
                        mapHeight)
                    .ceil())
                .clamp(top + 1, source.height);
        found.add(OcrDetectedBox(left, top, right, bottom, score / count));
      }
    }
    return _mergeNearby(found, source.height);
  }

  List<OcrDetectedBox> _mergeNearby(
    List<OcrDetectedBox> input,
    int imageHeight,
  ) {
    final boxes = [...input]..sort((a, b) => a.top - b.top);
    final result = <OcrDetectedBox>[];
    for (final box in boxes) {
      final index = result.indexWhere((other) {
        final verticalOverlap =
            math.min(other.bottom, box.bottom) - math.max(other.top, box.top);
        final minHeight = math.min(
          other.bottom - other.top,
          box.bottom - box.top,
        );
        final maxHeight = math.max(
          other.bottom - other.top,
          box.bottom - box.top,
        );
        final heightRatio = minHeight / math.max(1, maxHeight);
        final gap = math.max(
          0,
          math.max(other.left, box.left) - math.min(other.right, box.right),
        );
        return verticalOverlap > minHeight * 0.55 &&
            heightRatio >= 0.5 &&
            gap <= maxHeight * 2.5;
      });
      if (index < 0) {
        result.add(box);
      } else {
        final other = result[index];
        result[index] = OcrDetectedBox(
          math.min(other.left, box.left),
          math.min(other.top, box.top),
          math.max(other.right, box.right),
          math.max(other.bottom, box.bottom),
          math.max(other.score, box.score),
        );
      }
    }
    return result;
  }

  List<List<double>> _unwrapProbabilityMap(dynamic value) {
    dynamic current = value;
    while (current is List &&
        current.isNotEmpty &&
        current.first is List &&
        current.first.isNotEmpty &&
        current.first.first is List) {
      current = current.first;
    }
    if (current is! List) return const [];
    return current
        .whereType<List>()
        .map((row) => row.map((v) => (v as num).toDouble()).toList())
        .toList();
  }

  Future<OcrTextResult> _recognizeLine(im.Image line) async {
    const targetHeight = 48;
    const targetWidth = 320;
    final contentWidth = math.min(
      targetWidth,
      math.max(
        1,
        (line.width * targetHeight / math.max(1, line.height)).round(),
      ),
    );
    final resized = im.copyResize(
      line,
      width: contentWidth,
      height: targetHeight,
    );
    final data = Float32List(3 * targetWidth * targetHeight);
    final plane = targetWidth * targetHeight;
    for (var y = 0; y < targetHeight; y++) {
      for (var x = 0; x < targetWidth; x++) {
        final i = y * targetWidth + x;
        final pixel = x < contentWidth ? resized.getPixel(x, y) : null;
        data[i] = ((pixel?.r ?? 255) / 255.0 - 0.5) / 0.5;
        data[plane + i] = ((pixel?.g ?? 255) / 255.0 - 0.5) / 0.5;
        data[plane * 2 + i] = ((pixel?.b ?? 255) / 255.0 - 0.5) / 0.5;
      }
    }
    final input = OrtValueTensor.createTensorWithDataList(data, [
      1,
      3,
      targetHeight,
      targetWidth,
    ]);
    final runOptions = OrtRunOptions();
    final outputs = _recSession!.run(runOptions, {
      _recSession!.inputNames.first: input,
    });
    input.release();
    runOptions.release();
    if (outputs.isEmpty || outputs.first == null) {
      return const OcrTextResult('', 0);
    }
    dynamic raw = outputs.first!.value;
    for (final output in outputs) {
      output?.release();
    }
    while (raw is List && raw.length == 1) {
      raw = raw.first;
    }
    if (raw is! List) return const OcrTextResult('', 0);
    final buffer = StringBuffer();
    var previous = -1;
    var confidence = 0.0;
    var count = 0;
    for (final step in raw.whereType<List>()) {
      var bestIndex = 0;
      var bestScore = double.negativeInfinity;
      for (var i = 0; i < step.length; i++) {
        final score = (step[i] as num).toDouble();
        if (score > bestScore) {
          bestScore = score;
          bestIndex = i;
        }
      }
      if (bestIndex != 0 &&
          bestIndex != previous &&
          bestIndex < _characters.length) {
        buffer.write(_characters[bestIndex]);
        confidence += bestScore;
        count++;
      }
      previous = bestIndex;
    }
    return OcrTextResult(
      buffer.toString(),
      count == 0 ? 0 : confidence / count,
    );
  }

  void dispose() {
    _detSession?.release();
    _recSession?.release();
    _sessionOptions?.release();
    _detSession = null;
    _recSession = null;
  }
}
