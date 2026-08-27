import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Creates a transparent playback copy for codecs which are not consistently
/// decoded by every video_player backend. The original library file is never
/// modified and the existing controller/UI remains in charge of playback.
class AudioPlaybackCompatibilityService {
  AudioPlaybackCompatibilityService._();

  static final Map<String, Future<File>> _inFlight = <String, Future<File>>{};
  static const Set<String> _portableCodecs = <String>{'aac', 'mp3'};

  static Future<File> resolve(
    File source, {
    required bool isAudio,
    String? existingPlaybackPath,
    Directory? persistentDirectory,
  }) async {
    if (!isAudio || kIsWeb) return source;
    // All native builds ship media_kit's FFmpeg/libmpv decoder. It can decode
    // PCM WAV, FLAC, ALAC, Opus, WMA and the other supported library formats
    // directly. Avoid the old eager AAC conversion: it delayed first play,
    // consumed extra storage and made lossless sources lossy.
    if (supportsDirectNativePlayback) return source;
    if (existingPlaybackPath != null) {
      final existing = File(existingPlaybackPath);
      if (await existing.exists() && await existing.length() > 0) {
        return existing;
      }
    }
    final codec = await _audioCodec(source.path);
    if (!needsCompatibilityCopy(codec)) return source;
    final future = _inFlight.putIfAbsent(
      source.path,
      () => _createAacCopy(source, persistentDirectory: persistentDirectory),
    );
    try {
      return await future;
    } finally {
      if (identical(_inFlight[source.path], future)) {
        _inFlight.remove(source.path);
      }
    }
  }

  @visibleForTesting
  static bool needsCompatibilityCopy(String? codec) =>
      codec != null && !_portableCodecs.contains(codec.toLowerCase());

  /// Kept explicit so tests document why compatibility copies are bypassed.
  /// Web does not use local [File] playback and is handled before this check.
  @visibleForTesting
  static bool get supportsDirectNativePlayback =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isWindows ||
      Platform.isLinux;

  static Future<String?> _audioCodec(String path) async {
    try {
      final session = await FFprobeKit.getMediaInformation(
        path,
      ).timeout(const Duration(seconds: 12));
      final information = session.getMediaInformation();
      if (information == null) return null;
      for (final stream in information.getStreams()) {
        if (stream.getType() == 'audio') {
          return stream.getCodec()?.toLowerCase();
        }
      }
    } catch (error) {
      debugPrint('Audio compatibility probe failed: $error');
    }
    return null;
  }

  static Future<File> _createAacCopy(
    File source, {
    Directory? persistentDirectory,
  }) async {
    final stat = await source.stat();
    final directory =
        persistentDirectory ??
        Directory(
          p.join(
            (await getApplicationDocumentsDirectory()).path,
            'playback_audio_compat',
          ),
        );
    await directory.create(recursive: true);
    final key = sha256
        .convert(
          '${source.path}|${stat.size}|${stat.modified.millisecondsSinceEpoch}'
              .codeUnits,
        )
        .toString();
    final output = File(p.join(directory.path, '$key.m4a'));
    if (await output.exists() && await output.length() > 0) return output;

    final partial = File('${output.path}.partial.m4a');
    if (await partial.exists()) await partial.delete();
    final session = await FFmpegKit.executeWithArguments(<String>[
      '-y',
      '-i',
      source.path,
      '-map',
      '0:a:0',
      '-vn',
      '-c:a',
      'aac',
      '-b:a',
      '256k',
      '-movflags',
      '+faststart',
      partial.path,
    ]).timeout(const Duration(minutes: 5));
    final returnCode = await session.getReturnCode();
    if (!ReturnCode.isSuccess(returnCode) || !await partial.exists()) {
      final logs = await session.getAllLogsAsString();
      throw StateError('Unable to prepare compatible audio: $logs');
    }
    await partial.rename(output.path);
    return output;
  }
}
