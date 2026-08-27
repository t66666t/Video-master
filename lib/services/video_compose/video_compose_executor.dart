import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

import '../../models/video_compose_models.dart';
import '../../utils/ffmpeg_utils.dart';
import 'video_compose_types.dart';

typedef VideoComposeProgressCallback = void Function(double ratio);

class VideoComposeExecutor {
  Process? _activeDesktopComposeProcess;

  Future<void> execute({
    required VideoComposeRequest request,
    required String filter,
    String? preciseSubtitleConcatPath,
    required List<ComposeSubtitleInput> softSubtitleInputs,
    required Duration duration,
    required bool transcodeVideo,
    required VideoComposeProgressCallback onProgress,
  }) async {
    Future<void> run(String currentFilter) async {
      if (Platform.isWindows || Platform.isMacOS) {
        await _executeDesktopCompose(
          request: request,
          filter: currentFilter,
          preciseSubtitleConcatPath: preciseSubtitleConcatPath,
          softSubtitleInputs: softSubtitleInputs,
          duration: duration,
          transcodeVideo: transcodeVideo,
          onProgress: onProgress,
        );
        return;
      }
      await _executeMobileCompose(
        request: request,
        filter: currentFilter,
        preciseSubtitleConcatPath: preciseSubtitleConcatPath,
        softSubtitleInputs: softSubtitleInputs,
        duration: duration,
        transcodeVideo: transcodeVideo,
        onProgress: onProgress,
      );
    }

    try {
      await run(filter);
    } catch (error) {
      if (!transcodeVideo) {
        rethrow;
      }
      final String errorText = error.toString();
      final bool allowFontsDirFallback =
          (Platform.isAndroid || Platform.isIOS) &&
          _isFontsDirRelatedError(errorText);
      if (filter.contains(':fontsdir=') && allowFontsDirFallback) {
        final String fallbackFilter = removeFontsDirOption(filter);
        if (fallbackFilter != filter) {
          final File outputFile = File(request.outputPath);
          if (await outputFile.exists()) {
            await outputFile.delete();
          }
          try {
            await run(fallbackFilter);
            return;
          } catch (_) {
            throw error;
          }
        }
      }
      rethrow;
    }
  }

  Future<void> cancel() async {
    final Process? process = _activeDesktopComposeProcess;
    if (process != null) {
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {
        try {
          process.kill();
        } catch (_) {}
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        FFmpegKit.cancel();
      } catch (_) {}
    }
  }

  String buildVideoFilter({
    required int sourceWidth,
    required int sourceHeight,
    required int targetWidth,
    required int targetHeight,
    String? assPath,
    String? fontsDir,
  }) {
    if (targetWidth <= 0 || targetHeight <= 0) {
      return '';
    }
    const String padding =
        'force_original_aspect_ratio=decrease,pad=TARGET_W:TARGET_H:(ow-iw)/2:(oh-ih)/2,setsar=1';
    final String base =
        'scale=$targetWidth:$targetHeight:${padding.replaceAll('TARGET_W', '$targetWidth').replaceAll('TARGET_H', '$targetHeight')}';
    if (assPath == null || assPath.isEmpty) {
      return base;
    }
    final String escapedAss = escapeFilterPath(assPath);
    final String fontsDirArg = fontsDir == null
        ? ''
        : ":fontsdir='${escapeFilterPath(fontsDir)}'";
    final String assFilter = "ass=filename='$escapedAss'$fontsDirArg";
    return '$base,$assFilter';
  }

  String removeFontsDirOption(String filter) {
    return filter.replaceAll(RegExp(r":fontsdir='[^']*'"), '');
  }

  String escapeFilterPath(String path) {
    return path
        .replaceAll(r'\', '/')
        .replaceAll(':', r'\:')
        .replaceAll("'", r"\'");
  }

  bool _isFontsDirRelatedError(String text) {
    final String lowered = text.toLowerCase();
    return lowered.contains('fontsdir') ||
        lowered.contains('fontconfig') ||
        lowered.contains('no such filter') ||
        lowered.contains('unable to open') ||
        lowered.contains('cannot open');
  }

  Future<void> _executeDesktopCompose({
    required VideoComposeRequest request,
    required String filter,
    String? preciseSubtitleConcatPath,
    required List<ComposeSubtitleInput> softSubtitleInputs,
    required Duration duration,
    required bool transcodeVideo,
    required VideoComposeProgressCallback onProgress,
  }) async {
    final String ffmpegPath = await FFmpegUtils.ffmpegPath;
    final bool hasSoftSubtitles = softSubtitleInputs.isNotEmpty;
    final List<String> args = <String>['-y', '-i', request.videoPath];
    final bool hasPreciseOverlay =
        preciseSubtitleConcatPath != null &&
        preciseSubtitleConcatPath.isNotEmpty;
    if (hasPreciseOverlay) {
      args.addAll(<String>[
        '-f',
        'concat',
        '-safe',
        '0',
        '-i',
        preciseSubtitleConcatPath,
      ]);
    }
    for (final ComposeSubtitleInput softInput in softSubtitleInputs) {
      args.addAll(<String>['-i', softInput.path]);
    }
    if (transcodeVideo) {
      if (hasPreciseOverlay) {
        args.addAll(<String>[
          '-filter_complex',
          '[0:v]$filter[base];[1:v]format=rgba,setpts=PTS-STARTPTS[sub];'
              '[base][sub]overlay=0:0:eof_action=pass:repeatlast=1[outv]',
          '-map',
          '[outv]',
        ]);
      } else {
        args.addAll(<String>['-vf', filter]);
      }
      args.addAll(<String>[
        '-c:v',
        'libx264',
        '-preset',
        'veryfast',
        '-crf',
        '20',
        '-pix_fmt',
        'yuv420p',
        '-c:a',
        'copy',
      ]);
    } else {
      args.addAll(<String>['-c:v', 'copy', '-c:a', 'copy']);
    }
    if (hasSoftSubtitles) {
      if (!hasPreciseOverlay) {
        args.addAll(<String>['-map', '0:v?']);
      }
      args.addAll(<String>['-map', '0:a?']);
      final int softInputOffset = hasPreciseOverlay ? 2 : 1;
      for (int i = 0; i < softSubtitleInputs.length; i++) {
        args.addAll(<String>['-map', '${i + softInputOffset}:0']);
      }
      args.addAll(<String>['-c:s', 'mov_text']);
      _appendSoftSubtitleMetadataArgs(args, softSubtitleInputs);
    } else if (!transcodeVideo) {
      args.addAll(<String>['-map', '0']);
    } else if (hasPreciseOverlay) {
      args.addAll(<String>['-map', '0:a?']);
    }
    args.add(request.outputPath);
    final Process process = await Process.start(
      ffmpegPath,
      args,
      runInShell: true,
    );
    _activeDesktopComposeProcess = process;
    final Completer<void> completer = Completer<void>();
    final StringBuffer buffer = StringBuffer();
    final double totalSeconds = duration.inMilliseconds <= 0
        ? 1.0
        : duration.inMilliseconds / 1000.0;

    void onLine(String line) {
      buffer.writeln(line);
      final Match? match = RegExp(
        r'time=(\d{2}):(\d{2}):(\d{2}(?:\.\d+)?)',
      ).firstMatch(line);
      if (match != null) {
        final double h = double.tryParse(match.group(1) ?? '') ?? 0;
        final double m = double.tryParse(match.group(2) ?? '') ?? 0;
        final double s = double.tryParse(match.group(3) ?? '') ?? 0;
        final double current = h * 3600 + m * 60 + s;
        final double ratio = (current / totalSeconds).clamp(0.0, 1.0);
        onProgress(ratio);
      }
    }

    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(onLine);
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(onLine);

    process.exitCode.then((int code) {
      if (code == 0) {
        completer.complete();
      } else {
        completer.completeError(StateError(buffer.toString()));
      }
    });
    try {
      return await completer.future;
    } finally {
      if (identical(_activeDesktopComposeProcess, process)) {
        _activeDesktopComposeProcess = null;
      }
    }
  }

  Future<void> _executeMobileCompose({
    required VideoComposeRequest request,
    required String filter,
    String? preciseSubtitleConcatPath,
    required List<ComposeSubtitleInput> softSubtitleInputs,
    required Duration duration,
    required bool transcodeVideo,
    required VideoComposeProgressCallback onProgress,
  }) async {
    final int totalMs = duration.inMilliseconds <= 0
        ? 1
        : duration.inMilliseconds;
    final bool hasSoftSubtitles = softSubtitleInputs.isNotEmpty;
    final List<String> args = <String>['-y', '-i', request.videoPath];
    final bool hasPreciseOverlay =
        preciseSubtitleConcatPath != null &&
        preciseSubtitleConcatPath.isNotEmpty;
    if (hasPreciseOverlay) {
      args.addAll(<String>[
        '-f',
        'concat',
        '-safe',
        '0',
        '-i',
        preciseSubtitleConcatPath,
      ]);
    }
    for (final ComposeSubtitleInput softInput in softSubtitleInputs) {
      args.addAll(<String>['-i', softInput.path]);
    }
    if (transcodeVideo) {
      if (hasPreciseOverlay) {
        args.addAll(<String>[
          '-filter_complex',
          '[0:v]$filter[base];[1:v]format=rgba,setpts=PTS-STARTPTS[sub];'
              '[base][sub]overlay=0:0:eof_action=pass:repeatlast=1[outv]',
          '-map',
          '[outv]',
        ]);
      } else {
        args.addAll(<String>['-vf', filter]);
      }
      args.addAll(<String>[
        '-c:v',
        'libx264',
        '-preset',
        'veryfast',
        '-crf',
        '20',
        '-pix_fmt',
        'yuv420p',
        '-c:a',
        'copy',
      ]);
    } else {
      args.addAll(<String>['-c:v', 'copy', '-c:a', 'copy']);
    }
    if (hasSoftSubtitles) {
      if (!hasPreciseOverlay) {
        args.addAll(<String>['-map', '0:v?']);
      }
      args.addAll(<String>['-map', '0:a?']);
      final int softInputOffset = hasPreciseOverlay ? 2 : 1;
      for (int i = 0; i < softSubtitleInputs.length; i++) {
        args.addAll(<String>['-map', '${i + softInputOffset}:0']);
      }
      args.addAll(<String>['-c:s', 'mov_text']);
      _appendSoftSubtitleMetadataArgs(args, softSubtitleInputs);
    } else if (!transcodeVideo) {
      args.addAll(<String>['-map', '0']);
    } else if (hasPreciseOverlay) {
      args.addAll(<String>['-map', '0:a?']);
    }
    args.add(request.outputPath);
    final String command = args.map(_quoteFFmpegArg).join(' ');
    final Completer<void> completer = Completer<void>();
    await FFmpegKit.executeAsync(
      command,
      (dynamic session) async {
        final dynamic code = await session.getReturnCode();
        if (ReturnCode.isSuccess(code)) {
          completer.complete();
        } else {
          final String? logs = await session.getAllLogsAsString();
          completer.completeError(StateError(logs ?? 'FFmpeg 执行失败'));
        }
      },
      (_) {},
      (dynamic statistics) {
        final int time = statistics.getTime();
        final double ratio = (time / totalMs).clamp(0.0, 1.0);
        onProgress(ratio);
      },
    );
    return completer.future;
  }

  void _appendSoftSubtitleMetadataArgs(
    List<String> args,
    List<ComposeSubtitleInput> softSubtitleInputs,
  ) {
    for (int i = 0; i < softSubtitleInputs.length; i++) {
      final ComposeSubtitleInput softInput = softSubtitleInputs[i];
      final String title = softInput.title.trim().isEmpty
          ? '字幕 ${i + 1}'
          : softInput.title.trim();
      args.addAll(<String>['-metadata:s:s:$i', 'title=$title']);
      args.addAll(<String>['-metadata:s:s:$i', 'handler_name=$title']);
      args.addAll(<String>[
        '-metadata:s:s:$i',
        'language=${softInput.language}',
      ]);
    }
  }

  String _quoteFFmpegArg(String arg) {
    final String escaped = arg.replaceAll('"', r'\"');
    return '"$escaped"';
  }
}
