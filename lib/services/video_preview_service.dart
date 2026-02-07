import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:video_player_app/utils/ffmpeg_utils.dart';

class VideoPreviewService {
  static final VideoPreviewService _instance = VideoPreviewService._internal();
  factory VideoPreviewService() => _instance;
  VideoPreviewService._internal();

  // Cache: key = "path_timeMs", value = bytes
  // Using LinkedHashMap for LRU (Least Recently Used) cache
  final LinkedHashMap<String, Uint8List> _cache = LinkedHashMap<String, Uint8List>();
  final int _maxCacheSize = 100; // Keep last 100 previews in memory
  final Map<String, List<int>> _keyframeIndexCache = {};
  final Map<String, Future<List<int>>> _keyframeIndexLoads = {};
  final Map<String, double> _frameIntervalMsCache = {};
  final Map<String, Future<double?>> _frameIntervalLoads = {};

  bool _isGenerating = false;
  _PreviewRequest? _nextRequest;
  
  // Callback for when a new preview is ready
  // (Optional: can be used if we want to push updates, but Future return is usually easier)

  /// Requests a preview image for the given video at the specified timestamp.
  /// Returns null if generation fails or is skipped/debounced.
  /// 
  /// This method implements a "latest-wins" throttling mechanism to avoid
  /// overwhelming the system with thumbnail generation tasks during rapid scrubbing.
  Future<Uint8List?> requestPreview(String videoPath, int timeMs) async {
    final keyframes = _keyframeIndexCache[videoPath];
    if (keyframes == null) {
      _warmKeyframeIndex(videoPath);
    }

    final frameInterval = _frameIntervalMsCache[videoPath];
    if (frameInterval == null) {
      _warmFrameInterval(videoPath);
    }

    final mappedTimeMs = frameInterval == null ? timeMs : _alignToFrameTimeMs(timeMs, frameInterval);
    final anchorTimeMs = keyframes == null || keyframes.isEmpty
        ? mappedTimeMs
        : _nearestKeyframeAtOrBefore(keyframes, mappedTimeMs);
    final key = _generateKey(videoPath, mappedTimeMs);
    
    // 1. Check memory cache first
    if (_cache.containsKey(key)) {
      // Move to end (mark as recently used)
      final data = _cache.remove(key)!;
      _cache[key] = data;
      return data;
    }

    // 2. If already generating, queue this request as the next one to process
    if (_isGenerating) {
      _nextRequest = _PreviewRequest(videoPath, mappedTimeMs, anchorTimeMs);
      return null; // Return null to indicate "not ready yet / skipped"
    }

    // 3. Start generation
    return _processRequest(videoPath, mappedTimeMs, anchorTimeMs);
  }

  Future<Uint8List?> _processRequest(String videoPath, int timeMs, int anchorTimeMs) async {
    _isGenerating = true;
    Uint8List? result;

    try {
      // Check cache again just in case
      final key = _generateKey(videoPath, timeMs);
      if (_cache.containsKey(key)) {
        result = _cache[key];
      } else {
        result = await _extractFrameAccurate(videoPath, timeMs, anchorTimeMs);
        result ??= await VideoThumbnail.thumbnailData(
            video: videoPath,
            imageFormat: ImageFormat.JPEG,
            maxWidth: 200,
            timeMs: timeMs,
            quality: 50,
          );
        if (result != null) {
          _addToCache(key, result);
        }
      }
    } catch (e) {
      debugPrint("VideoPreviewService: Error generating thumbnail: $e");
    } finally {
      // Check if there is a pending request
      if (_nextRequest != null) {
        final next = _nextRequest!;
        _nextRequest = null;
        // We don't await the next one here, just trigger it.
        // But we need to keep _isGenerating true? 
        // No, recursively calling _processRequest will handle _isGenerating flag logic 
        // if we structured it that way. 
        // Ideally, we want to run the loop until queue is empty.
        
        // Let's trigger the next one asynchronously to unblock the current stack
        Future.microtask(() => _processRequest(next.videoPath, next.timeMs, next.anchorTimeMs).then((val) {
           // We can't easily return this value to the original caller of requestPreview
           // because that caller already got 'null'.
           // This implies the UI needs a way to be notified or poll.
           // However, for drag preview, the UI usually keeps asking "give me preview for X".
           // If requestPreview returns null, the UI keeps showing old one or loading.
           // When the user stops dragging or drags slowly, eventually requestPreview returns data.
        }));
      } else {
        _isGenerating = false;
      }
    }

    return result;
  }

  void _addToCache(String key, Uint8List data) {
    if (_cache.length >= _maxCacheSize) {
      _cache.remove(_cache.keys.first); // Remove least recently used
    }
    _cache[key] = data;
  }

  String _generateKey(String path, int timeMs) => "${path}_$timeMs";

  /// Clears the memory cache
  void clearCache() {
    _cache.clear();
  }

  void _warmKeyframeIndex(String videoPath) {
    if (_keyframeIndexCache.containsKey(videoPath)) return;
    if (_keyframeIndexLoads.containsKey(videoPath)) return;
    _keyframeIndexLoads[videoPath] = _loadKeyframeIndex(videoPath).then((list) {
      _keyframeIndexCache[videoPath] = list;
      _keyframeIndexLoads.remove(videoPath);
      return list;
    });
  }

  Future<List<int>> _loadKeyframeIndex(String videoPath) async {
    try {
      if (Platform.isWindows) {
        final ffprobePath = await FFmpegUtils.ffprobePath;
        final result = await Process.run(ffprobePath, [
          '-v', 'error',
          '-select_streams', 'v:0',
          '-skip_frame', 'nokey',
          '-show_entries', 'frame=pkt_pts_time',
          '-of', 'csv=p=0',
          videoPath
        ]);
        if (result.exitCode == 0) {
          return _parseKeyframeTimes(result.stdout.toString());
        }
      } else {
        final session = await FFprobeKit.execute(
          '-v error -select_streams v:0 -skip_frame nokey -show_entries frame=pkt_pts_time -of csv=p=0 "$videoPath"'
        );
        final returnCode = await session.getReturnCode();
        if (ReturnCode.isSuccess(returnCode)) {
          final output = await session.getOutput();
          return _parseKeyframeTimes(output ?? '');
        }
      }
    } catch (_) {}
    return [];
  }

  List<int> _parseKeyframeTimes(String output) {
    final List<int> times = [];
    for (final line in output.split(RegExp(r'[\r\n]+'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final seconds = double.tryParse(trimmed);
      if (seconds == null) continue;
      times.add((seconds * 1000).round());
    }
    times.sort();
    return times;
  }

  int _nearestKeyframeAtOrBefore(List<int> keyframes, int timeMs) {
    if (keyframes.isEmpty) return timeMs;
    if (timeMs <= keyframes.first) return keyframes.first;
    if (timeMs >= keyframes.last) return keyframes.last;

    int left = 0;
    int right = keyframes.length - 1;
    while (left <= right) {
      final mid = (left + right) >> 1;
      final midVal = keyframes[mid];
      if (midVal == timeMs) return midVal;
      if (midVal < timeMs) {
        left = mid + 1;
      } else {
        right = mid - 1;
      }
    }
    return keyframes[right];
  }

  void _warmFrameInterval(String videoPath) {
    if (_frameIntervalMsCache.containsKey(videoPath)) return;
    if (_frameIntervalLoads.containsKey(videoPath)) return;
    _frameIntervalLoads[videoPath] = _loadFrameIntervalMs(videoPath).then((value) {
      if (value != null && value > 0) {
        _frameIntervalMsCache[videoPath] = value;
      }
      _frameIntervalLoads.remove(videoPath);
      return value;
    });
  }

  Future<double?> _loadFrameIntervalMs(String videoPath) async {
    try {
      if (Platform.isWindows) {
        final ffprobePath = await FFmpegUtils.ffprobePath;
        final result = await Process.run(ffprobePath, [
          '-v', 'error',
          '-select_streams', 'v:0',
          '-show_entries', 'stream=avg_frame_rate,r_frame_rate,time_base',
          '-of', 'json',
          videoPath
        ]);
        if (result.exitCode == 0) {
          final data = jsonDecode(result.stdout.toString());
          final streams = data['streams'] as List?;
          if (streams != null && streams.isNotEmpty) {
            final stream = streams.first as Map<dynamic, dynamic>;
            final fpsStr = stream['avg_frame_rate']?.toString() ?? stream['r_frame_rate']?.toString();
            final fps = _parseFraction(fpsStr);
            if (fps != null && fps > 0) {
              return 1000.0 / fps;
            }
            final timeBaseStr = stream['time_base']?.toString();
            final timeBase = _parseFraction(timeBaseStr);
            if (timeBase != null && timeBase > 0) {
              return timeBase * 1000.0;
            }
          }
        }
      } else {
        final session = await FFprobeKit.getMediaInformation(videoPath);
        final info = session.getMediaInformation();
        if (info != null) {
          final streams = info.getStreams();
          for (final stream in streams) {
            if (stream.getType() != 'video') continue;
            final fpsStr = stream.getAverageFrameRate() ?? stream.getRealFrameRate();
            final fps = _parseFraction(fpsStr);
            if (fps != null && fps > 0) {
              return 1000.0 / fps;
            }
            final timeBaseStr = stream.getTimeBase();
            final timeBase = _parseFraction(timeBaseStr);
            if (timeBase != null && timeBase > 0) {
              return timeBase * 1000.0;
            }
            break;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  double? _parseFraction(String? value) {
    if (value == null || value.isEmpty) return null;
    if (!value.contains('/')) {
      return double.tryParse(value);
    }
    final parts = value.split('/');
    if (parts.length != 2) return null;
    final num = double.tryParse(parts[0]);
    final den = double.tryParse(parts[1]);
    if (num == null || den == null || den == 0) return null;
    return num / den;
  }

  int _alignToFrameTimeMs(int timeMs, double frameIntervalMs) {
    if (frameIntervalMs <= 0) return timeMs;
    final index = (timeMs / frameIntervalMs).round();
    final aligned = (index * frameIntervalMs).round();
    return aligned < 0 ? 0 : aligned;
  }

  Future<Uint8List?> _extractFrameAccurate(String videoPath, int targetTimeMs, int anchorTimeMs) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final outputPath = p.join(tempDir.path, "seek_preview_${DateTime.now().microsecondsSinceEpoch}.jpg");
      final safeAnchor = anchorTimeMs <= targetTimeMs ? anchorTimeMs : targetTimeMs;
      final offsetMs = targetTimeMs - safeAnchor;
      final anchorSec = (safeAnchor / 1000.0).toStringAsFixed(3);
      final offsetSec = (offsetMs / 1000.0).toStringAsFixed(3);
      final args = [
        '-hide_banner',
        '-loglevel', 'error',
        '-ss', anchorSec,
        '-i', videoPath,
        '-ss', offsetSec,
        '-frames:v', '1',
        '-vf', 'scale=200:-1',
        '-q:v', '4',
        '-y',
        outputPath
      ];

      if (Platform.isWindows) {
        final ffmpegPath = await FFmpegUtils.ffmpegPath;
        final result = await Process.run(ffmpegPath, args);
        if (result.exitCode != 0) return null;
      } else {
        final session = await FFmpegKit.executeWithArguments(args);
        final returnCode = await session.getReturnCode();
        if (!ReturnCode.isSuccess(returnCode)) return null;
      }

      final file = File(outputPath);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        await file.delete();
        if (bytes.isEmpty) return null;
        return bytes;
      }
    } catch (_) {}
    return null;
  }
}

class _PreviewRequest {
  final String videoPath;
  final int timeMs;
  final int anchorTimeMs;
  _PreviewRequest(this.videoPath, this.timeMs, this.anchorTimeMs);
}
