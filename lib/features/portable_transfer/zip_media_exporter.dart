import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/media_chapter.dart';
import '../../services/library_service.dart';
import '../../utils/ffmpeg_utils.dart';
import 'portable_transfer_models.dart';
import 'zip_export_plan.dart';

const zipExportScratchDirectoryName = 'fluent_zip_export';

class ZipExportResult {
  final int mediaCount;
  final int skippedOnline;
  final int skippedMissing;
  final int sidecarFallbacks;
  final int keptOriginals;
  final int droppedExtras;

  const ZipExportResult({
    required this.mediaCount,
    required this.skippedOnline,
    required this.skippedMissing,
    required this.sidecarFallbacks,
    required this.keptOriginals,
    required this.droppedExtras,
  });

  String summary(int outputBytes) => buildZipExportSummary(
    mediaCount: mediaCount,
    outputBytes: outputBytes,
    skippedOnline: skippedOnline,
    skippedMissing: skippedMissing,
    sidecarFallbacks: sidecarFallbacks,
    keptOriginals: keptOriginals,
    droppedExtras: droppedExtras,
  );
}

typedef ZipProgressCallback =
    void Function(double progress, String subtitle, int processedBytes, int totalBytes);

class ZipExportHandle {
  void Function()? cancelSession;
  Process? ffmpeg;
  int? ffmpegKitSessionId;

  void cancel() {
    cancelSession?.call();
    ffmpeg?.kill();
    final sessionId = ffmpegKitSessionId;
    if (sessionId != null) {
      unawaited(FFmpegKit.cancel(sessionId));
    }
  }
}

class ZipExportRuntime {
  static final Map<String, ZipExportHandle> _handles = <String, ZipExportHandle>{};

  static void bind(String taskId, ZipExportHandle handle) {
    _handles[taskId] = handle;
  }

  static void unbind(String taskId, ZipExportHandle handle) {
    if (identical(_handles[taskId], handle)) {
      _handles.remove(taskId);
    }
  }

  static void cancel(String taskId) {
    _handles[taskId]?.cancel();
  }
}

class ZipMediaExporter {
  Future<ZipExportResult> run({
    required LibraryService library,
    required List<String> rootIds,
    required String partialPath,
    required PortableExportOptions options,
    required String taskId,
    required bool Function() isCancelled,
    required ZipProgressCallback onProgress,
  }) async {
    final handle = ZipExportHandle();
    ZipExportRuntime.bind(taskId, handle);
    Directory? scratch;
    var finished = false;
    try {
      _throwIfCancelled(isCancelled);
      final draft = enumerateZipCandidates(
        library: library,
        rootIds: rootIds,
        packageName: options.packageName,
      );
      if (draft.candidates.isEmpty) {
        throw StateError('所选项目中没有可导出的本地文件');
      }
      onProgress(0.01, '正在读取 ${draft.candidates.length} 个媒体', 0, 1);
      final facts = await _probeAll(
        draft.candidates,
        options: options,
        isCancelled: isCancelled,
        onProgress: onProgress,
      );
      final media = <ZipResolvedMedia>[
        for (final candidate in draft.candidates)
          resolveZipCandidate(
            candidate: candidate,
            names: draft.names,
            subtitleMode: options.zipSubtitleMode,
            includeDanmaku: options.includeDanmaku,
            facts:
                facts[candidate.item.id] ??
                (zipCandidateNeedsProbe(
                      item: candidate.item,
                      embedTracks: zipEmbedTracks(
                        associated: collectAssociatedSubtitles(candidate.item),
                        danmaku: collectDanmakuTrack(candidate.item),
                        mode: options.zipSubtitleMode,
                        includeDanmaku: options.includeDanmaku,
                      ),
                    )
                    ? const ZipSourceFacts.unknown()
                    : const ZipSourceFacts()),
          ),
      ];
      final totalBytes = media.fold<int>(
        0,
        (sum, item) => sum + item.sourceBytes,
      );
      final temp = await getTemporaryDirectory();
      scratch = Directory(
        p.join(temp.path, zipExportScratchDirectoryName, taskId),
      );
      if (await scratch.exists()) {
        await _deleteTree(scratch);
      }
      await scratch.create(recursive: true);
      final partial = File(partialPath);
      if (await partial.exists()) await _deleteFile(partial);
      await partial.parent.create(recursive: true);

      final session = _ZipPackSession(handle);
      await session.start(
        partialPath: partialPath,
        level: _zipLevel(options.compression),
      );
      var packedBytes = 0;
      var sidecarFallbacks = 0;
      var keptOriginals = 0;
      var droppedExtras = 0;
      for (var index = 0; index < media.length; index++) {
        _throwIfCancelled(isCancelled);
        final item = media[index];
        final prepared = await _prepareItem(
          item: item,
          index: index,
          total: media.length,
          scratch: scratch,
          names: draft.names,
          handle: handle,
          isCancelled: isCancelled,
          onProgress: (fraction, subtitle) {
            final inFile = (item.sourceBytes * fraction).round();
            onProgress(
              totalBytes == 0
                  ? (index + fraction) / media.length
                  : ((packedBytes + inFile) / totalBytes).clamp(0.0, 0.99),
              subtitle,
              packedBytes + inFile,
              totalBytes,
            );
          },
        );
        if (prepared.usedSidecarFallback) sidecarFallbacks++;
        if (prepared.keptOriginal) keptOriginals++;
        if (prepared.droppedExtras) droppedExtras++;
        final members = prepared.members;
        for (final member in members) {
          _throwIfCancelled(isCancelled);
          final before = packedBytes;
          final fileLength = await File(member.sourcePath).length();
          onProgress(
            totalBytes == 0 ? index / media.length : before / totalBytes,
            '正在打包 ${index + 1}/${media.length} · ${item.title}',
            before,
            totalBytes,
          );
          await session.add(
            sourcePath: member.sourcePath,
            archivePath: member.archivePath,
            level: _zipLevel(options.compression),
            onBytes: (written) {
              final grown = written > fileLength ? fileLength : written;
              onProgress(
                totalBytes == 0
                    ? (index + 1) / media.length
                    : ((before + grown) / totalBytes).clamp(0.0, 0.99),
                '正在打包 ${index + 1}/${media.length} · ${item.title}',
                before + grown,
                totalBytes,
              );
            },
            partialPath: partialPath,
          );
          if (member.deleteAfterPack) {
            await _deleteIfInside(scratch, member.sourcePath);
          }
        }
        packedBytes += item.sourceBytes;
        onProgress(
          totalBytes == 0
              ? (index + 1) / media.length
              : (packedBytes / totalBytes).clamp(0.0, 0.99),
          '正在打包 ${index + 1}/${media.length} · ${item.title}',
          packedBytes,
          totalBytes,
        );
      }
      await session.finish();
      finished = true;
      return ZipExportResult(
        mediaCount: media.length,
        skippedOnline: draft.skippedOnline,
        skippedMissing: draft.skippedMissing,
        sidecarFallbacks: sidecarFallbacks,
        keptOriginals: keptOriginals,
        droppedExtras: droppedExtras,
      );
    } on PortableExportCancelled {
      rethrow;
    } finally {
      if (scratch != null) {
        final parent = scratch.parent;
        await _deleteTree(scratch);
        try {
          if (await parent.exists() &&
              await parent.list(followLinks: false).isEmpty) {
            await parent.delete();
          }
        } catch (_) {}
      }
      if (!finished) {
        handle.cancel();
        final partial = File(partialPath);
        if (await partial.exists()) await _deleteFile(partial);
      } else {
        handle.cancel();
      }
      ZipExportRuntime.unbind(taskId, handle);
    }
  }

  Future<Map<String, ZipSourceFacts>> _probeAll(
    List<ZipCandidate> candidates, {
    required PortableExportOptions options,
    required bool Function() isCancelled,
    required ZipProgressCallback onProgress,
  }) async {
    final facts = <String, ZipSourceFacts>{};
    for (var index = 0; index < candidates.length; index++) {
      _throwIfCancelled(isCancelled);
      final item = candidates[index].item;
      final embedTracks = zipEmbedTracks(
        associated: collectAssociatedSubtitles(item),
        danmaku: collectDanmakuTrack(item),
        mode: options.zipSubtitleMode,
        includeDanmaku: options.includeDanmaku,
      );
      if (!zipCandidateNeedsProbe(item: item, embedTracks: embedTracks)) {
        continue;
      }
      onProgress(
        0.02,
        '正在读取媒体信息 ${index + 1}/${candidates.length}',
        0,
        1,
      );
      facts[item.id] = await _probeFacts(item.path);
    }
    return facts;
  }

  Future<_PreparedZipItem> _prepareItem({
    required ZipResolvedMedia item,
    required int index,
    required int total,
    required Directory scratch,
    required ZipNameAllocator names,
    required ZipExportHandle handle,
    required bool Function() isCancelled,
    required void Function(double fraction, String subtitle) onProgress,
  }) async {
    if (!item.remux) {
      return _PreparedZipItem(
        members: <_ZipMember>[
          _ZipMember(item.sourcePath, item.archivePath, deleteAfterPack: false),
          for (final sidecar in item.sidecars)
            _ZipMember(
              sidecar.sourcePath,
              sidecar.archivePath,
              deleteAfterPack: false,
            ),
        ],
      );
    }

    final full = ZipRemuxPlan(
      tracks: item.embedTracks,
      includeCover: item.coverPath != null,
      includeChapters: item.replacementChapters != null,
    );
    var failures = 0;
    while (true) {
      _throwIfCancelled(isCancelled);
      final attempt = zipRemuxAttemptAfterFailures(full, failures);
      if (attempt == null) break;
      final output = File(
        p.join(scratch.path, '${index}_$failures${p.extension(item.archivePath)}'),
      );
      try {
        await _remux(
          item: item,
          plan: attempt,
          output: output,
          scratch: scratch,
          handle: handle,
          isCancelled: isCancelled,
          onProgress: (fraction) {
            onProgress(
              fraction * 0.85,
              '正在封装 ${index + 1}/$total · ${item.title}',
            );
          },
        );
        final degraded = failures >= 2;
        return _PreparedZipItem(
          droppedExtras: degraded,
          members: <_ZipMember>[
            _ZipMember(output.path, item.archivePath, deleteAfterPack: true),
            for (final sidecar in item.sidecars)
              _ZipMember(
                sidecar.sourcePath,
                sidecar.archivePath,
                deleteAfterPack: false,
              ),
          ],
        );
      } catch (error) {
        await _deleteIfInside(scratch, output.path);
        await _deleteIfInside(scratch, '${output.path}.partial');
        if (error is PortableExportCancelled) rethrow;
        failures++;
      }
    }

    final archivePath = reallocateZipCopyPath(media: item, names: names);
    final sidecars = item.sidecars.isNotEmpty
        ? item.sidecars
        : buildZipFallbackSidecars(
            media: item,
            videoArchivePath: archivePath,
            names: names,
          );
    return _PreparedZipItem(
      usedSidecarFallback: item.embedTracks.isNotEmpty,
      keptOriginal: item.embedTracks.isEmpty,
      members: <_ZipMember>[
        _ZipMember(item.sourcePath, archivePath, deleteAfterPack: false),
        for (final sidecar in sidecars)
          if (File(sidecar.sourcePath).existsSync())
            _ZipMember(
              sidecar.sourcePath,
              sidecar.archivePath,
              deleteAfterPack: false,
            ),
      ],
    );
  }

  Future<void> _remux({
    required ZipResolvedMedia item,
    required ZipRemuxPlan plan,
    required File output,
    required Directory scratch,
    required ZipExportHandle handle,
    required bool Function() isCancelled,
    required void Function(double fraction) onProgress,
  }) async {
    String? chapterPath;
    if (plan.includeChapters && item.replacementChapters != null) {
      final file = File(p.join(scratch.path, '${p.basename(output.path)}.ffmeta'));
      await file.writeAsString(
        buildZipChapterMetadata(
          item.replacementChapters!,
          durationMs: item.durationMs,
        ),
      );
      chapterPath = file.path;
    }
    final partial = File('${output.path}.partial');
    await _deleteIfInside(scratch, partial.path);
    final args = buildZipRemuxArguments(
      sourcePath: item.sourcePath,
      outputPath: partial.path,
      tracks: plan.tracks,
      coverPath: plan.includeCover ? item.coverPath : null,
      chapterMetadataPath: chapterPath,
      existingSubtitleStreams: item.existingSubtitleStreams,
      existingVideoStreams: item.existingVideoStreams,
      outputIsMp4Family: item.outputIsMp4Family,
      progressPipe: _useCli,
    );
    if (_useCli) {
      await _remuxWithCli(
        args: args,
        handle: handle,
        durationMs: item.durationMs,
        isCancelled: isCancelled,
        onProgress: onProgress,
      );
    } else {
      await _remuxWithKit(
        args: args,
        handle: handle,
        durationMs: item.durationMs,
        isCancelled: isCancelled,
        onProgress: onProgress,
      );
    }
    _throwIfCancelled(isCancelled);
    if (!await partial.exists() || await partial.length() <= 0) {
      throw StateError('封装没有产生文件');
    }
    if (await output.exists()) await output.delete();
    await partial.rename(output.path);
  }

  Future<void> _remuxWithCli({
    required List<String> args,
    required ZipExportHandle handle,
    required int durationMs,
    required bool Function() isCancelled,
    required void Function(double fraction) onProgress,
  }) async {
    final ffmpeg = await FFmpegUtils.ffmpegPath;
    final process = await Process.start(ffmpeg, args);
    handle.ffmpeg = process;
    final stderr = StringBuffer();
    final stderrDone = process.stderr.transform(utf8.decoder).listen(stderr.write);
    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final fraction = zipFfmpegProgressFraction(line, durationMs);
          if (fraction != null) onProgress(fraction);
        });
    final code = await process.exitCode;
    await stderrDone.cancel();
    await stdoutDone.cancel();
    handle.ffmpeg = null;
    if (isCancelled()) throw const PortableExportCancelled();
    if (code != 0) {
      final text = stderr.toString().trim();
      final line = text.isEmpty ? '退出码 $code' : text.split('\n').last.trim();
      throw StateError(line);
    }
  }

  Future<void> _remuxWithKit({
    required List<String> args,
    required ZipExportHandle handle,
    required int durationMs,
    required bool Function() isCancelled,
    required void Function(double fraction) onProgress,
  }) async {
    final completed = Completer<FFmpegSession>();
    final session = await FFmpegKit.executeWithArgumentsAsync(
      args,
      (finished) {
        if (!completed.isCompleted) completed.complete(finished);
      },
      null,
      (statistics) {
        if (durationMs <= 0) return;
        onProgress((statistics.getTime() / durationMs).clamp(0.0, 0.99));
      },
    );
    handle.ffmpegKitSessionId = session.getSessionId();
    final finished = await completed.future;
    handle.ffmpegKitSessionId = null;
    if (isCancelled()) throw const PortableExportCancelled();
    final code = await finished.getReturnCode();
    if (!ReturnCode.isSuccess(code)) {
      final logs = await finished.getAllLogsAsString();
      final text = (logs ?? '').trim();
      throw StateError(text.isEmpty ? '封装失败' : text.split('\n').last.trim());
    }
  }

  Future<ZipSourceFacts> _probeFacts(String path) async {
    try {
      if (_useCli) return await _probeWithCli(path);
      return await _probeWithKit(path);
    } catch (_) {
      return const ZipSourceFacts.unknown();
    }
  }

  Future<ZipSourceFacts> _probeWithCli(String path) async {
    final ffprobe = await FFmpegUtils.ffprobePath;
    final result = await Process.run(ffprobe, <String>[
      '-v',
      'error',
      '-show_streams',
      '-show_chapters',
      '-of',
      'json',
      path,
    ]).timeout(const Duration(seconds: 20));
    if (result.exitCode != 0) return const ZipSourceFacts.unknown();
    final decoded = jsonDecode(result.stdout.toString());
    if (decoded is! Map) return const ZipSourceFacts.unknown();
    return _factsFromProbeJson(Map<String, dynamic>.from(decoded));
  }

  Future<ZipSourceFacts> _probeWithKit(String path) async {
    final session = await FFprobeKit.getMediaInformation(path);
    final information = session.getMediaInformation();
    if (information == null) return const ZipSourceFacts.unknown();
    final streams = information.getStreams();
    var videos = 0;
    var subtitles = 0;
    var cover = false;
    for (final stream in streams) {
      final type = stream.getType();
      if (type == 'video') videos++;
      if (type == 'subtitle') subtitles++;
      final disposition = stream.getProperty('disposition');
      if (disposition is Map && _isTruthy(disposition['attached_pic'])) {
        cover = true;
      }
    }
    final chapters = information.getChapters().map((chapter) {
      final tags = chapter.getTags();
      return MediaChapter(
        title: (tags?['title'] ?? tags?['TITLE'] ?? '').toString().trim(),
        startMs: _secondsToMs(chapter.getStartTime()),
        endMs: _secondsToMs(chapter.getEndTime()),
      );
    }).toList(growable: false);
    return ZipSourceFacts(
      hasAttachedCover: cover,
      videoStreamCount: videos,
      subtitleStreamCount: subtitles,
      fileChapters: chapters,
    );
  }
}

bool get _useCli =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

ZipSourceFacts _factsFromProbeJson(Map<String, dynamic> json) {
  final streams = json['streams'];
  var videos = 0;
  var subtitles = 0;
  var cover = false;
  if (streams is List) {
    for (final raw in streams.whereType<Map>()) {
      final stream = Map<String, dynamic>.from(raw);
      final type = stream['codec_type']?.toString();
      if (type == 'video') videos++;
      if (type == 'subtitle') subtitles++;
      final disposition = stream['disposition'];
      if (disposition is Map && _isTruthy(disposition['attached_pic'])) {
        cover = true;
      }
    }
  }
  final chapters = <MediaChapter>[];
  final rawChapters = json['chapters'];
  if (rawChapters is List) {
    for (final raw in rawChapters.whereType<Map>()) {
      final chapter = Map<String, dynamic>.from(raw);
      final tags = chapter['tags'] is Map
          ? Map<String, dynamic>.from(chapter['tags'] as Map)
          : const <String, dynamic>{};
      chapters.add(
        MediaChapter(
          title: (tags['title'] ?? tags['TITLE'] ?? '').toString().trim(),
          startMs: _secondsToMs(chapter['start_time']),
          endMs: _secondsToMs(chapter['end_time']),
        ),
      );
    }
  }
  return ZipSourceFacts(
    hasAttachedCover: cover,
    videoStreamCount: videos,
    subtitleStreamCount: subtitles,
    fileChapters: chapters,
  );
}

int _secondsToMs(Object? value) {
  final seconds = value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '');
  return seconds == null ? 0 : (seconds * 1000).round();
}

bool _isTruthy(Object? value) => value == 1 || value == true || value == '1';

int _zipLevel(PortableCompression compression) => switch (compression) {
  PortableCompression.fast => ZipFileEncoder.store,
  PortableCompression.balanced => 3,
  PortableCompression.smallest => 9,
};

void _throwIfCancelled(bool Function() isCancelled) {
  if (isCancelled()) throw const PortableExportCancelled();
}

Future<void> _deleteIfInside(Directory scratch, String path) async {
  final file = File(path);
  if (!p.isWithin(scratch.path, file.path)) return;
  await _deleteFile(file);
}

Future<void> _deleteFile(File file) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      if (await file.exists()) await file.delete();
      return;
    } catch (_) {
      await Future<void>.delayed(Duration(milliseconds: 80 * (attempt + 1)));
    }
  }
}

Future<void> _deleteTree(Directory directory) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
      return;
    } catch (_) {
      await Future<void>.delayed(Duration(milliseconds: 80 * (attempt + 1)));
    }
  }
}

class _PreparedZipItem {
  final List<_ZipMember> members;
  final bool usedSidecarFallback;
  final bool keptOriginal;
  final bool droppedExtras;

  const _PreparedZipItem({
    required this.members,
    this.usedSidecarFallback = false,
    this.keptOriginal = false,
    this.droppedExtras = false,
  });
}

class _ZipMember {
  final String sourcePath;
  final String archivePath;
  final bool deleteAfterPack;

  const _ZipMember(
    this.sourcePath,
    this.archivePath, {
    required this.deleteAfterPack,
  });
}

class _ZipPackSession {
  _ZipPackSession(this.handle);

  final ZipExportHandle handle;
  Isolate? _isolate;
  SendPort? _send;
  ReceivePort? _replies;
  ReceivePort? _errors;
  var _ticket = 0;
  final Map<int, Completer<void>> _waiters = <int, Completer<void>>{};
  var _cancelled = false;

  Future<void> start({required String partialPath, required int level}) async {
    final ready = ReceivePort();
    _replies = ReceivePort();
    _errors = ReceivePort();
    _isolate = await Isolate.spawn<SendPort>(
      _zipPackWorker,
      ready.sendPort,
      onError: _errors!.sendPort,
      errorsAreFatal: true,
      debugName: 'zip-export',
    );
    handle.cancelSession = cancel;
    _send = await ready.first as SendPort;
    ready.close();
    _replies!.listen((dynamic raw) {
      if (raw is! Map) return;
      final message = Map<String, dynamic>.from(raw);
      final id = message['id'];
      if (id is! int) return;
      final waiter = _waiters.remove(id);
      if (waiter == null || waiter.isCompleted) return;
      if (message['ok'] == true) {
        waiter.complete();
      } else if (_cancelled) {
        waiter.completeError(const PortableExportCancelled());
      } else {
        waiter.completeError(
          StateError(message['error']?.toString() ?? '写入 Zip 失败'),
        );
      }
    });
    _errors!.listen((dynamic _) {
      if (_cancelled) {
        _failWaiters(const PortableExportCancelled());
      }
    });
    await _command(<String, dynamic>{
      'type': 'start',
      'path': partialPath,
      'level': level,
    });
  }

  Future<void> add({
    required String sourcePath,
    required String archivePath,
    required int level,
    required void Function(int written) onBytes,
    required String partialPath,
  }) async {
    final partial = File(partialPath);
    final baseline = await partial.exists() ? await partial.length() : 0;
    final timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!partial.existsSync()) return;
      final written = partial.lengthSync() - baseline;
      if (written > 0) onBytes(written);
    });
    try {
      await _command(<String, dynamic>{
        'type': 'add',
        'source': sourcePath,
        'archivePath': archivePath,
        'level': level,
      });
    } finally {
      timer.cancel();
    }
  }

  Future<void> finish() => _command(<String, dynamic>{'type': 'finish'});

  void cancel() {
    _cancelled = true;
    _failWaiters(const PortableExportCancelled());
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _replies?.close();
    _errors?.close();
    _replies = null;
    _errors = null;
  }

  Future<void> _command(Map<String, dynamic> body) {
    if (_cancelled) throw const PortableExportCancelled();
    final send = _send;
    final replies = _replies;
    if (send == null || replies == null) {
      throw StateError('Zip 写入尚未开始');
    }
    final id = _ticket++;
    final completer = Completer<void>();
    _waiters[id] = completer;
    send.send(<String, dynamic>{...body, 'id': id, 'reply': replies.sendPort});
    return completer.future;
  }

  void _failWaiters(Object error) {
    for (final waiter in _waiters.values) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
    _waiters.clear();
  }
}

Future<void> _zipPackWorker(SendPort ready) async {
  final inbox = ReceivePort();
  ready.send(inbox.sendPort);
  ZipFileEncoder? encoder;
  try {
    await for (final raw in inbox) {
      if (raw is! Map) continue;
      final message = Map<String, dynamic>.from(raw);
      final reply = message['reply'] as SendPort;
      final id = message['id'];
      try {
        switch (message['type']) {
          case 'start':
            encoder = ZipFileEncoder()
              ..create(
                message['path'] as String,
                level: message['level'] as int? ?? ZipFileEncoder.store,
              );
            reply.send(<String, dynamic>{'id': id, 'ok': true});
          case 'add':
            final source = File(message['source'] as String);
            if (!await source.exists()) {
              throw StateError('导出源文件已不存在：${source.path}');
            }
            await encoder!.addFile(
              source,
              message['archivePath'] as String,
              message['level'] as int?,
            );
            reply.send(<String, dynamic>{'id': id, 'ok': true});
          case 'finish':
            await encoder?.close();
            encoder = null;
            reply.send(<String, dynamic>{'id': id, 'ok': true});
            inbox.close();
            return;
          default:
            throw StateError('未知的 Zip 指令');
        }
      } catch (error) {
        try {
          await encoder?.close();
        } catch (_) {}
        encoder = null;
        reply.send(<String, dynamic>{
          'id': id,
          'ok': false,
          'error': error.toString(),
        });
        inbox.close();
        return;
      }
    }
  } finally {
    try {
      await encoder?.close();
    } catch (_) {}
  }
}
