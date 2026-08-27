import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as im;

import 'ocr_inference_engine.dart';
import 'ocr_model_manager.dart';

class OcrFrameAnalysis {
  final bool candidate;
  final String text;
  final double confidence;
  final double difference;
  final int boundaryMs;
  final String backend;

  const OcrFrameAnalysis({
    required this.candidate,
    required this.text,
    required this.confidence,
    required this.difference,
    required this.boundaryMs,
    required this.backend,
  });
}

class OcrProcessingWorker {
  final Isolate _isolate;
  final ReceivePort _responses;
  final Completer<void> _ready = Completer<void>();
  SendPort? _commands;
  final Map<int, Completer<Map<Object?, Object?>>> _pending = {};
  late final StreamSubscription<dynamic> _subscription;
  int _nextId = 1;
  bool _closed = false;

  OcrProcessingWorker._(this._isolate, this._responses) {
    _subscription = _responses.listen((dynamic message) {
      if (message is SendPort && _commands == null) {
        _commands = message;
        _ready.complete();
        return;
      }
      if (message is! Map) return;
      final map = Map<Object?, Object?>.from(message);
      if (!_ready.isCompleted && map['error'] != null) {
        _ready.completeError(StateError(map['error'].toString()));
        return;
      }
      final id = map['id'];
      if (id is! int) return;
      final completer = _pending.remove(id);
      if (completer == null) return;
      if (map['error'] != null) {
        completer.completeError(StateError(map['error'].toString()));
      } else {
        completer.complete(map);
      }
    });
  }

  static Future<OcrProcessingWorker> start(OcrModelFiles files) async {
    final bootstrap = ReceivePort();
    final isolate = await Isolate.spawn<Map<String, Object?>>(
      _ocrWorkerMain,
      <String, Object?>{
        'reply': bootstrap.sendPort,
        'detection': files.detection,
        'recognition': files.recognition,
        'dictionary': files.dictionary,
      },
      debugName: 'ocr-subtitle-worker',
    );
    final worker = OcrProcessingWorker._(isolate, bootstrap);
    try {
      await worker._ready.future.timeout(const Duration(seconds: 45));
      return worker;
    } catch (_) {
      await worker._subscription.cancel();
      bootstrap.close();
      isolate.kill(priority: Isolate.immediate);
      rethrow;
    }
  }

  Future<OcrFrameAnalysis> analyzeFrame(String path, int atMs) async {
    final response = await _request(<String, Object?>{
      'type': 'frame',
      'path': path,
      'atMs': atMs,
    });
    return OcrFrameAnalysis(
      candidate: response['candidate'] == true,
      text: response['text']?.toString() ?? '',
      confidence: (response['confidence'] as num?)?.toDouble() ?? 0,
      difference: (response['difference'] as num?)?.toDouble() ?? 0,
      boundaryMs: response['boundaryMs'] as int? ?? atMs,
      backend: response['backend']?.toString() ?? 'CPU',
    );
  }

  Future<void> resetFrameHistory() async {
    await _request(<String, Object?>{'type': 'reset'});
  }

  Future<Map<Object?, Object?>> _request(Map<String, Object?> command) {
    if (_closed) throw StateError('OCR 工作线程已经关闭');
    final id = _nextId++;
    final completer = Completer<Map<Object?, Object?>>();
    _pending[id] = completer;
    _commands!.send(<String, Object?>{...command, 'id': id});
    return completer.future;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final id = _nextId++;
    final completer = Completer<Map<Object?, Object?>>();
    _pending[id] = completer;
    _commands!.send(<String, Object?>{'type': 'close', 'id': id});
    try {
      await completer.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      // Killing below is the final cleanup fallback.
    }
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('OCR 工作线程已经关闭'));
      }
    }
    _pending.clear();
    await _subscription.cancel();
    _responses.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

@pragma('vm:entry-point')
Future<void> _ocrWorkerMain(Map<String, Object?> bootstrap) async {
  final reply = bootstrap['reply']! as SendPort;
  final commands = ReceivePort();
  OcrInferenceEngine? cpu;
  OcrInferenceEngine? accelerated;
  try {
    final files = OcrModelFiles(
      detection: bootstrap['detection']! as String,
      recognition: bootstrap['recognition']! as String,
      dictionary: bootstrap['dictionary']! as String,
    );
    cpu = OcrInferenceEngine(files);
    await cpu.initialize();
    final candidate = OcrInferenceEngine(
      files,
      preferHardwareAcceleration: true,
    );
    await candidate.initialize();
    if (!candidate.activeBackend.startsWith('CPU')) {
      accelerated = candidate;
    } else {
      candidate.dispose();
    }
    reply.send(commands.sendPort);
  } catch (error) {
    cpu?.dispose();
    accelerated?.dispose();
    commands.close();
    reply.send(<String, Object?>{'error': error.toString()});
    return;
  }

  Uint8List? previousSignature;
  var lastForcedMs = -100000;
  var lastCandidateMs = -100000;
  var lastChangeMs = 0;
  var pendingChange = false;
  ({String text, double confidence, int boundaryMs})? pendingRecognition;
  OcrInferenceEngine? selected;
  final subtitleStyle = OcrSubtitleStyleFilter();

  await for (final dynamic raw in commands) {
    if (raw is! Map) continue;
    final message = Map<Object?, Object?>.from(raw);
    final id = message['id'];
    if (id is! int) continue;
    if (message['type'] == 'close') {
      cpu?.dispose();
      accelerated?.dispose();
      reply.send(<String, Object?>{'id': id});
      commands.close();
      return;
    }
    if (message['type'] == 'reset') {
      previousSignature = null;
      lastForcedMs = -100000;
      lastCandidateMs = -100000;
      lastChangeMs = 0;
      pendingChange = false;
      pendingRecognition = null;
      subtitleStyle.reset();
      reply.send(<String, Object?>{'id': id});
      continue;
    }
    if (message['type'] != 'frame') continue;
    try {
      final path = message['path']! as String;
      final atMs = message['atMs']! as int;
      final image = im.decodeImage(await File(path).readAsBytes());
      if (image == null) throw StateError('无法解码 OCR 临时帧');
      final signature = _signature(image);
      final difference = previousSignature == null
          ? 1.0
          : _signatureDifference(previousSignature, signature);
      previousSignature = signature;
      final forced = atMs - lastForcedMs >= 2000;
      final changed = difference >= 0.08;
      if (changed) {
        lastChangeMs = atMs;
        pendingChange = true;
      }
      final candidateIntervalElapsed = atMs - lastCandidateMs >= 300;
      final isNewCandidate =
          forced || (pendingChange && candidateIntervalElapsed);
      final candidateBoundaryMs = pendingChange ? lastChangeMs : atMs;
      if (forced) lastForcedMs = atMs;
      if (isNewCandidate) {
        lastCandidateMs = atMs;
        pendingChange = false;
      }

      var result = const OcrTextResult('', 0);
      final shouldRecognize = isNewCandidate || pendingRecognition != null;
      if (shouldRecognize) {
        if (selected == null && accelerated != null) {
          // Warm both providers once, then compare the same frame. Small mobile
          // OCR models can be faster on CPU than on a discrete GPU because of
          // transfer overhead, so the choice is measured rather than guessed.
          await cpu!.recognizeImage(image);
          await accelerated.recognizeImage(image);
          final cpuWatch = Stopwatch()..start();
          final cpuResult = await cpu.recognizeImage(image);
          cpuWatch.stop();
          final gpuWatch = Stopwatch()..start();
          final gpuResult = await accelerated.recognizeImage(image);
          gpuWatch.stop();
          if (gpuWatch.elapsedMicroseconds < cpuWatch.elapsedMicroseconds) {
            selected = accelerated;
            result = gpuResult;
            cpu.dispose();
            cpu = null;
          } else {
            selected = cpu;
            result = cpuResult;
            accelerated.dispose();
          }
          accelerated = null;
        } else {
          selected ??= cpu!;
          result = await selected.recognizeImage(image);
        }
        result = subtitleStyle.filter(result, image.width, image.height);
      }
      var emitCandidate = false;
      var emittedText = '';
      var emittedConfidence = 0.0;
      var emittedBoundaryMs = candidateBoundaryMs;
      final previousRecognition = pendingRecognition;
      if (previousRecognition != null && shouldRecognize) {
        final agrees = _roughlySameText(previousRecognition.text, result.text);
        if (agrees) {
          final preferred = result.confidence >= previousRecognition.confidence
              ? (text: result.text, confidence: result.confidence)
              : (
                  text: previousRecognition.text,
                  confidence: previousRecognition.confidence,
                );
          // Empty text is a valid, confirmed subtitle end. Non-empty text must
          // also clear a modest confidence floor so textured backgrounds do
          // not become one-frame garbage subtitles.
          if (preferred.text.trim().isEmpty || preferred.confidence >= 0.38) {
            emitCandidate = true;
            emittedText = preferred.text;
            emittedConfidence = preferred.confidence;
            emittedBoundaryMs = previousRecognition.boundaryMs;
          }
          pendingRecognition = null;
        } else {
          // Two disagreeing readings used to keep OCR running on every frame
          // until something matched. On textured backgrounds that could become
          // effectively unbounded. Keep only the stronger reading when it is
          // trustworthy; otherwise discard this transition.
          final preferred = result.confidence >= previousRecognition.confidence
              ? (text: result.text, confidence: result.confidence)
              : (
                  text: previousRecognition.text,
                  confidence: previousRecognition.confidence,
                );
          if (preferred.confidence >= 0.55) {
            emitCandidate = true;
            emittedText = preferred.text;
            emittedConfidence = preferred.confidence;
            emittedBoundaryMs = previousRecognition.boundaryMs;
          }
          pendingRecognition = null;
        }
      } else if (isNewCandidate) {
        pendingRecognition = (
          text: result.text,
          confidence: result.confidence,
          boundaryMs: candidateBoundaryMs,
        );
      }
      reply.send(<String, Object?>{
        'id': id,
        'candidate': emitCandidate,
        'text': emittedText,
        'confidence': emittedConfidence,
        'difference': difference,
        'boundaryMs': emittedBoundaryMs,
        'backend':
            selected?.activeBackend ??
            (accelerated == null ? cpu?.activeBackend ?? 'CPU' : 'CPU/GPU 测速中'),
      });
    } catch (error) {
      reply.send(<String, Object?>{'id': id, 'error': error.toString()});
    }
  }
}

/// Learns the dominant geometry independently for each user-selected OCR
/// region. This removes small logos/UI labels that happen to be inside the
/// region while still allowing one- and two-line subtitles.
class OcrSubtitleStyleFilter {
  static const _historyLimit = 32;
  final List<double> _heights = <double>[];
  final List<double> _centers = <double>[];

  void reset() {
    _heights.clear();
    _centers.clear();
  }

  OcrTextResult filter(OcrTextResult result, int width, int height) {
    if (result.lines.isEmpty || width <= 0 || height <= 0) return result;
    var accepted = result.lines;
    if (_heights.length >= 4) {
      final expectedHeight = _median(_heights);
      final expectedCenter = _median(_centers);
      accepted = result.lines.where((line) {
        final normalizedHeight = line.height / height;
        final normalizedCenter = (line.top + line.bottom) / (2 * height);
        final heightRatio = normalizedHeight / math.max(0.001, expectedHeight);
        final centerTolerance = math.max(0.14, expectedHeight * 2.5);
        return heightRatio >= 0.55 &&
            heightRatio <= 1.80 &&
            (normalizedCenter - expectedCenter).abs() <= centerTolerance;
      }).toList();
      if (accepted.isEmpty) return const OcrTextResult('', 0);
    }

    // Update with the strongest line(s), not every detector fragment. The
    // inference layer has already merged words sharing the same baseline.
    // Do not let a tiny always-on watermark seen before the first subtitle
    // become the learned style. With the default/tight user ROI, real subtitle
    // rows are normally comfortably above this conservative bootstrap floor.
    final profileLines = accepted
        .where((line) => line.height / height >= 0.07)
        .toList();
    for (final line in profileLines) {
      _heights.add(line.height / height);
      _centers.add((line.top + line.bottom) / (2 * height));
    }
    while (_heights.length > _historyLimit) {
      _heights.removeAt(0);
      _centers.removeAt(0);
    }
    final confidence =
        accepted.fold<double>(0, (value, line) => value + line.confidence) /
        accepted.length;
    return OcrTextResult(
      accepted.map((line) => line.text).join('\n'),
      confidence,
      accepted,
    );
  }

  double _median(List<double> values) {
    final sorted = [...values]..sort();
    final middle = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[middle];
    return (sorted[middle - 1] + sorted[middle]) / 2;
  }
}

bool _roughlySameText(String a, String b) {
  final left = a.replaceAll(RegExp(r'\s+'), '').toLowerCase();
  final right = b.replaceAll(RegExp(r'\s+'), '').toLowerCase();
  if (left == right) return true;
  if (left.isEmpty || right.isEmpty) return false;
  final longest = math.max(left.length, right.length);
  var previous = List<int>.generate(right.length + 1, (index) => index);
  for (var i = 0; i < left.length; i++) {
    final current = List<int>.filled(right.length + 1, 0)..[0] = i + 1;
    for (var j = 0; j < right.length; j++) {
      current[j + 1] = math.min(
        math.min(current[j] + 1, previous[j + 1] + 1),
        previous[j] + (left.codeUnitAt(i) == right.codeUnitAt(j) ? 0 : 1),
      );
    }
    previous = current;
  }
  return 1 - previous.last / longest >= 0.78;
}

Uint8List _signature(im.Image image) {
  final small = im.copyResize(image, width: 48, height: 16);
  return Uint8List.fromList(<int>[
    for (final pixel in small)
      ((pixel.r * 299 + pixel.g * 587 + pixel.b * 114) / 1000).round(),
  ]);
}

double _signatureDifference(Uint8List a, Uint8List b) {
  final length = math.min(a.length, b.length);
  if (length == 0) return 1;
  var meanA = 0.0;
  var meanB = 0.0;
  for (var i = 0; i < length; i++) {
    meanA += a[i];
    meanB += b[i];
  }
  meanA /= length;
  meanB /= length;
  var varianceA = 0.0;
  var varianceB = 0.0;
  var covariance = 0.0;
  for (var i = 0; i < length; i++) {
    final da = a[i] - meanA;
    final db = b[i] - meanB;
    varianceA += da * da;
    varianceB += db * db;
    covariance += da * db;
  }
  final divisor = math.max(1, length - 1);
  varianceA /= divisor;
  varianceB /= divisor;
  covariance /= divisor;
  const c1 = 6.5025;
  const c2 = 58.5225;
  final numerator = (2 * meanA * meanB + c1) * (2 * covariance + c2);
  final denominator =
      (meanA * meanA + meanB * meanB + c1) * (varianceA + varianceB + c2);
  if (denominator <= 0) return 1;
  return (1 - numerator / denominator).clamp(0.0, 1.0);
}
