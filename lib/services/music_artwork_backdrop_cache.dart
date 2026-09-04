import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image_lib;

/// Produces a small, heavily blurred artwork bitmap off the UI isolate.
///
/// Stretching this cached bitmap behind the player is substantially cheaper
/// than applying a large real-time blur to a full-screen layer. The small
/// source also creates a stronger Apple Music-like colour wash.
class MusicArtworkBackdropCache {
  MusicArtworkBackdropCache._();

  static final MusicArtworkBackdropCache instance =
      MusicArtworkBackdropCache._();

  static const int _maxEntries = 12;
  static const int _targetSize = 144;
  static const int _blurRadius = 22;

  final LinkedHashMap<String, Uint8List> _memory =
      LinkedHashMap<String, Uint8List>();
  final Map<String, Future<Uint8List?>> _inFlight =
      <String, Future<Uint8List?>>{};

  Uint8List? peek(String? rawPath) {
    final path = _normalizePath(rawPath);
    if (path == null) return null;
    final bytes = _memory.remove(path);
    if (bytes != null) _memory[path] = bytes;
    return bytes;
  }

  Future<Uint8List?> warm(String? rawPath) {
    final path = _normalizePath(rawPath);
    if (path == null) return Future<Uint8List?>.value(null);

    final cached = peek(path);
    if (cached != null) return Future<Uint8List?>.value(cached);

    final running = _inFlight[path];
    if (running != null) return running;

    final future = _build(path);
    _inFlight[path] = future;
    future.whenComplete(() => _inFlight.remove(path));
    return future;
  }

  Future<Uint8List?> _build(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;

    try {
      final bytes = await compute<Map<String, Object>, Uint8List?>(
        _decodeBlurredArtwork,
        <String, Object>{
          'path': path,
          'targetSize': _targetSize,
          'blurRadius': _blurRadius,
        },
        debugLabel: 'music-artwork-backdrop',
      );
      if (bytes == null) return null;

      _memory[path] = bytes;
      while (_memory.length > _maxEntries) {
        _memory.remove(_memory.keys.first);
      }
      return bytes;
    } catch (error) {
      debugPrint('Music artwork backdrop generation failed: $error');
      return null;
    }
  }

  static String? _normalizePath(String? rawPath) {
    if (rawPath == null || rawPath.trim().isEmpty) return null;
    final value = rawPath.trim();
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return null;
    }
    if (value.startsWith('file://')) {
      try {
        return Uri.parse(value).toFilePath(windows: Platform.isWindows);
      } catch (_) {
        return null;
      }
    }
    return value;
  }

  @visibleForTesting
  void clearForTest() {
    _memory.clear();
    _inFlight.clear();
  }

  @visibleForTesting
  void seedForTest(String rawPath, Uint8List bytes) {
    final path = _normalizePath(rawPath);
    if (path != null) _memory[path] = bytes;
  }
}

Uint8List? _decodeBlurredArtwork(Map<String, Object> request) {
  final path = request['path']! as String;
  final targetSize = request['targetSize']! as int;
  final blurRadius = request['blurRadius']! as int;

  final sourceBytes = File(path).readAsBytesSync();
  final decoded = image_lib.decodeImage(sourceBytes);
  if (decoded == null) return null;

  final resized = image_lib.copyResize(
    decoded,
    width: targetSize,
    height: targetSize,
    interpolation: image_lib.Interpolation.average,
  );
  final blurred = image_lib.gaussianBlur(resized, radius: blurRadius);
  return image_lib.encodeJpg(blurred, quality: 88);
}
