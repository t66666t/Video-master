import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player_app/features/youtube_download/models/youtube_download_models.dart';

class YtDlpBinaryStatus {
  final bool ytDlpReady;

  /// Whether FFmpeg functionality is available through either a CLI binary or
  /// an embedded backend such as FFmpegKit.
  final bool ffmpegReady;

  /// Whether yt-dlp can invoke a standalone ffmpeg executable directly.
  final bool ffmpegCliReady;
  final String? ffmpegBackend;
  final String? ytDlpVersion;
  final String? ffmpegVersion;
  final String? ytDlpPath;
  final String? ffmpegPath;
  final String? diagnosticMessage;

  const YtDlpBinaryStatus({
    this.ytDlpReady = false,
    this.ffmpegReady = false,
    this.ffmpegCliReady = false,
    this.ffmpegBackend,
    this.ytDlpVersion,
    this.ffmpegVersion,
    this.ytDlpPath,
    this.ffmpegPath,
    this.diagnosticMessage,
  });

  factory YtDlpBinaryStatus.fromJson(Map<String, dynamic> json) {
    final ffmpegReady = json['ffmpegReady'] == true;
    return YtDlpBinaryStatus(
      ytDlpReady: json['ytDlpReady'] == true,
      ffmpegReady: ffmpegReady,
      ffmpegCliReady: json.containsKey('ffmpegCliReady')
          ? json['ffmpegCliReady'] == true
          : ffmpegReady,
      ffmpegBackend: json['ffmpegBackend']?.toString(),
      ytDlpVersion: json['ytDlpVersion']?.toString(),
      ffmpegVersion: json['ffmpegVersion']?.toString(),
      ytDlpPath: json['ytDlpPath']?.toString(),
      ffmpegPath: json['ffmpegPath']?.toString(),
      diagnosticMessage: json['diagnosticMessage']?.toString(),
    );
  }

  String get ffmpegAvailabilityLabel {
    if (!ffmpegReady) return '不可用';
    final backend = ffmpegBackend?.trim();
    return backend == null || backend.isEmpty ? '可用' : '可用（$backend）';
  }
}

class YtDlpPauseResult {
  final bool accepted;
  final bool stopped;
  final String? reason;

  const YtDlpPauseResult({
    required this.accepted,
    required this.stopped,
    this.reason,
  });

  const YtDlpPauseResult.rejected([this.reason])
    : accepted = false,
      stopped = false;

  factory YtDlpPauseResult.fromPlatform(dynamic value) {
    if (value is bool) {
      return YtDlpPauseResult(accepted: value, stopped: value);
    }
    if (value is Map) {
      return YtDlpPauseResult(
        accepted: value['accepted'] == true,
        stopped: value['stopped'] == true,
        reason: value['reason']?.toString(),
      );
    }
    return const YtDlpPauseResult.rejected('平台未返回暂停结果');
  }
}

class YtDlpNativeBridge {
  static const MethodChannel _methodChannel = MethodChannel(
    'com.example.video_player_app/yt_dlp',
  );
  static const EventChannel _eventChannel = EventChannel(
    'com.example.video_player_app/yt_dlp_events',
  );

  static const String resolveYoutubeMetaMethod = 'resolveYoutubeMeta';
  static const String startYoutubeDownloadMethod = 'startYoutubeDownload';
  static const String pauseYoutubeDownloadMethod = 'pauseYoutubeDownload';
  static const String cancelYoutubeDownloadMethod = 'cancelYoutubeDownload';
  static const String removeYoutubeTaskMethod = 'removeYoutubeTask';
  static const String getYoutubeTaskStatusMethod = 'getYoutubeTaskStatus';
  static const String importYoutubeCookiesMethod = 'importYoutubeCookies';
  static const String saveYoutubeSessionConfigMethod =
      'saveYoutubeSessionConfig';
  static const String loadYoutubeSessionConfigMethod =
      'loadYoutubeSessionConfig';
  static const String getBinaryStatusMethod = 'getYtDlpBinaryStatus';
  static const String configureBinaryPathsMethod = 'configureYtDlpBinaryPaths';
  static const String reloadAndroidRuntimeMethod = 'reloadYtDlpRuntime';

  final StreamController<DownloadTaskEvent> _linuxEvents =
      StreamController<DownloadTaskEvent>.broadcast();
  final Map<String, Process> _linuxProcesses = <String, Process>{};
  final Map<String, int> _linuxProcessGroups = <String, int>{};
  final Map<String, DownloadTaskEvent> _linuxStatuses =
      <String, DownloadTaskEvent>{};
  final Map<String, String> _linuxTerminationReasons = <String, String>{};
  final Map<String, String> _linuxOutputPaths = <String, String>{};
  final Map<String, String> _activeNativeTaskIds = <String, String>{};
  final Map<String, String> _nativeLogicalTaskIds = <String, String>{};
  final Map<String, int> _nativeTaskGenerations = <String, int>{};
  String? _linuxYtDlpPath;
  String? _linuxFfmpegPath;

  Future<bool> configureBinaryPaths({
    required String? ytDlpPath,
    required String? ffmpegPath,
  }) async {
    if (Platform.isLinux) {
      _linuxYtDlpPath = ytDlpPath;
      _linuxFfmpegPath = ffmpegPath ?? await _findLinuxExecutable('ffmpeg');
      return ytDlpPath != null && await File(ytDlpPath).exists();
    }
    try {
      return await _methodChannel.invokeMethod<bool>(
            configureBinaryPathsMethod,
            {'ytDlpPath': ytDlpPath, 'ffmpegPath': ffmpegPath},
          ) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<String?> reloadAndroidRuntime(String archivePath) async {
    try {
      return await _methodChannel.invokeMethod<String>(
        reloadAndroidRuntimeMethod,
        {'archivePath': archivePath},
      );
    } on MissingPluginException {
      return null;
    }
  }

  Stream<DownloadTaskEvent> taskEvents() {
    final source = Platform.isLinux
        ? _linuxEvents.stream
        : _eventChannel.receiveBroadcastStream().map((event) {
            return DownloadTaskEvent.fromJson(
              Map<String, dynamic>.from(event as Map),
            );
          });
    return source.map(_translateTaskEvent);
  }

  DownloadTaskEvent _translateTaskEvent(DownloadTaskEvent event) {
    final nativeTaskId = event.taskId;
    final logicalTaskId = _nativeLogicalTaskIds[nativeTaskId] ?? nativeTaskId;
    final generation = _nativeTaskGenerations[nativeTaskId];
    final translated = DownloadTaskEvent.fromJson({
      ...event.toJson(),
      'taskId': logicalTaskId,
      'generation': generation,
    });
    if (event.type == 'task_paused' ||
        event.type == 'task_completed' ||
        event.type == 'task_failed' ||
        event.type == 'task_cancelled') {
      _nativeLogicalTaskIds.remove(nativeTaskId);
      _nativeTaskGenerations.remove(nativeTaskId);
      if (_activeNativeTaskIds[logicalTaskId] == nativeTaskId) {
        _activeNativeTaskIds.remove(logicalTaskId);
      }
    }
    return translated;
  }

  Future<Map<String, dynamic>?> resolveYoutubeMeta(
    String url,
    DownloadSessionConfig sessionConfig,
  ) async {
    if (Platform.isLinux) {
      return _resolveLinuxYoutubeMeta(url, sessionConfig);
    }
    try {
      final result = await _methodChannel.invokeMapMethod<String, dynamic>(
        resolveYoutubeMetaMethod,
        {'url': url, 'sessionConfig': sessionConfig.toJson()},
      );
      if (result == null) return null;
      return Map<String, dynamic>.from(result);
    } on MissingPluginException {
      return null;
    }
  }

  Future<bool> startYoutubeDownload(
    NativeDownloadRequest request, {
    required int generation,
  }) async {
    final logicalTaskId = request.taskId;
    final nativeTaskId = '${logicalTaskId}__run_$generation';
    final nativeRequest = NativeDownloadRequest(
      taskId: nativeTaskId,
      url: request.url,
      outputDir: request.outputDir,
      outputTemplate: request.outputTemplate,
      args: request.args,
      debugContext: request.debugContext,
    );
    _activeNativeTaskIds[logicalTaskId] = nativeTaskId;
    _nativeLogicalTaskIds[nativeTaskId] = logicalTaskId;
    _nativeTaskGenerations[nativeTaskId] = generation;
    bool started;
    if (Platform.isLinux) {
      started = await _startLinuxYoutubeDownload(nativeRequest);
    } else {
      try {
        started =
            await _methodChannel.invokeMethod<bool>(
              startYoutubeDownloadMethod,
              nativeRequest.toJson(),
            ) ??
            false;
      } on MissingPluginException {
        started = false;
      }
    }
    if (!started) {
      _activeNativeTaskIds.remove(logicalTaskId);
      _nativeLogicalTaskIds.remove(nativeTaskId);
      _nativeTaskGenerations.remove(nativeTaskId);
    }
    return started;
  }

  Future<YtDlpPauseResult> pauseYoutubeDownload(String taskId) async {
    final nativeTaskId = _activeNativeTaskIds[taskId] ?? taskId;
    if (Platform.isLinux) {
      final stopped = await _terminateLinuxTask(nativeTaskId, 'pause');
      return YtDlpPauseResult(
        accepted: stopped,
        stopped: stopped,
        reason: stopped ? null : '找不到正在运行的任务',
      );
    }
    try {
      final result = await _methodChannel.invokeMethod<dynamic>(
        pauseYoutubeDownloadMethod,
        {'taskId': nativeTaskId},
      );
      return YtDlpPauseResult.fromPlatform(result);
    } on MissingPluginException {
      return const YtDlpPauseResult.rejected('当前平台未实现暂停');
    }
  }

  Future<bool> cancelYoutubeDownload(String taskId) async {
    final nativeTaskId = _activeNativeTaskIds[taskId] ?? taskId;
    if (Platform.isLinux) {
      return _terminateLinuxTask(nativeTaskId, 'cancel');
    }
    try {
      return await _methodChannel.invokeMethod<bool>(
            cancelYoutubeDownloadMethod,
            {'taskId': nativeTaskId},
          ) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> removeYoutubeTask(String taskId) async {
    final nativeTaskId = _activeNativeTaskIds[taskId] ?? taskId;
    if (Platform.isLinux) {
      await _terminateLinuxTask(nativeTaskId, 'cancel');
      _linuxStatuses.remove(nativeTaskId);
      _linuxOutputPaths.remove(nativeTaskId);
      return true;
    }
    try {
      return await _methodChannel.invokeMethod<bool>(removeYoutubeTaskMethod, {
            'taskId': nativeTaskId,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<Map<String, dynamic>?> getYoutubeTaskStatus(String taskId) async {
    final nativeTaskId = _activeNativeTaskIds[taskId] ?? taskId;
    if (Platform.isLinux) {
      return _linuxStatuses[nativeTaskId]?.toJson();
    }
    try {
      final result = await _methodChannel.invokeMapMethod<String, dynamic>(
        getYoutubeTaskStatusMethod,
        {'taskId': nativeTaskId},
      );
      if (result == null) return null;
      return Map<String, dynamic>.from(result);
    } on MissingPluginException {
      return null;
    }
  }

  Future<String?> importYoutubeCookies(String filePath) async {
    if (Platform.isLinux) {
      try {
        final source = File(filePath);
        if (!await source.exists()) return null;
        final support = await getApplicationSupportDirectory();
        final target = File(
          p.join(support.path, 'yt_dlp', 'cookies', 'cookies.txt'),
        );
        await target.parent.create(recursive: true);
        await source.copy(target.path);
        return target.path;
      } catch (_) {
        return null;
      }
    }
    try {
      return await _methodChannel.invokeMethod<String>(
        importYoutubeCookiesMethod,
        {'filePath': filePath},
      );
    } on MissingPluginException {
      return null;
    }
  }

  Future<bool> saveYoutubeSessionConfig(DownloadSessionConfig config) async {
    if (Platform.isLinux) return true;
    try {
      return await _methodChannel.invokeMethod<bool>(
            saveYoutubeSessionConfigMethod,
            {'config': config.toJson()},
          ) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<DownloadSessionConfig?> loadYoutubeSessionConfig() async {
    if (Platform.isLinux) return null;
    try {
      final result = await _methodChannel.invokeMapMethod<String, dynamic>(
        loadYoutubeSessionConfigMethod,
      );
      if (result == null) return null;
      return DownloadSessionConfig.fromJson(Map<String, dynamic>.from(result));
    } on MissingPluginException {
      return null;
    }
  }

  Future<YtDlpBinaryStatus> getBinaryStatus() async {
    if (Platform.isLinux) {
      return _getLinuxBinaryStatus();
    }
    try {
      final result = await _methodChannel.invokeMapMethod<String, dynamic>(
        getBinaryStatusMethod,
      );
      if (result == null) {
        return const YtDlpBinaryStatus();
      }
      return YtDlpBinaryStatus.fromJson(Map<String, dynamic>.from(result));
    } on MissingPluginException {
      return const YtDlpBinaryStatus();
    }
  }

  Future<YtDlpBinaryStatus> _getLinuxBinaryStatus() async {
    final ytDlpPath = _linuxYtDlpPath;
    final ffmpegPath = _linuxFfmpegPath;
    final ytDlpVersion = await _readLinuxBinaryVersion(ytDlpPath, const [
      '--version',
    ]);
    final ffmpegVersion = await _readLinuxBinaryVersion(ffmpegPath, const [
      '-version',
    ], firstLineOnly: true);
    return YtDlpBinaryStatus(
      ytDlpReady: ytDlpVersion != null,
      ffmpegReady: ffmpegVersion != null,
      ffmpegCliReady: ffmpegVersion != null,
      ffmpegBackend: ffmpegVersion == null ? null : '独立 CLI',
      ytDlpVersion: ytDlpVersion,
      ffmpegVersion: ffmpegVersion,
      ytDlpPath: ytDlpPath,
      ffmpegPath: ffmpegPath,
      diagnosticMessage: ytDlpVersion == null
          ? 'Linux yt-dlp 文件不可用，请检查路径和执行权限'
          : null,
    );
  }

  Future<String?> _findLinuxExecutable(String name) async {
    try {
      final result = await Process.run('which', [name]);
      if (result.exitCode != 0) return null;
      final path = result.stdout.toString().trim();
      return path.isEmpty ? null : path;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _readLinuxBinaryVersion(
    String? path,
    List<String> arguments, {
    bool firstLineOnly = false,
  }) async {
    if (path == null || path.isEmpty || !await File(path).exists()) return null;
    try {
      final result = await Process.run(
        path,
        arguments,
      ).timeout(const Duration(seconds: 15));
      if (result.exitCode != 0) return null;
      final value = result.stdout.toString().trim();
      return firstLineOnly ? value.split(RegExp(r'[\r\n]')).first : value;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _resolveLinuxYoutubeMeta(
    String url,
    DownloadSessionConfig config,
  ) async {
    final executable = _linuxYtDlpPath;
    if (executable == null || !await File(executable).exists()) return null;
    final args = <String>[
      ..._linuxSessionArgs(config),
      '--dump-single-json',
      '--no-warnings',
      url,
    ];
    final result = await Process.run(
      executable,
      args,
    ).timeout(const Duration(seconds: 90));
    if (result.exitCode != 0) {
      throw PlatformException(
        code: 'YT_DLP_RESOLVE_FAILED',
        message: result.stderr.toString().trim(),
      );
    }
    return {'rawInfoJson': result.stdout.toString()};
  }

  List<String> _linuxSessionArgs(DownloadSessionConfig config) {
    final args = <String>[];
    if (config.useCookies && (config.cookiesFilePath?.isNotEmpty ?? false)) {
      args.addAll(['--cookies', config.cookiesFilePath!]);
    }
    if (config.useProxy && (config.proxy?.isNotEmpty ?? false)) {
      args.addAll(['--proxy', config.proxy!]);
    }
    if (config.useCustomUserAgent && (config.userAgent?.isNotEmpty ?? false)) {
      args.addAll(['--add-header', 'User-Agent:${config.userAgent!}']);
    }
    if ((config.socketTimeoutSeconds ?? 0) > 0) {
      args.addAll(['--socket-timeout', '${config.socketTimeoutSeconds}']);
    }
    final retries = (config.retries ?? 2).clamp(0, 2);
    args.addAll(['--retries', '$retries']);
    final fragmentRetries = (config.fragmentRetries ?? 2).clamp(0, 2);
    args.addAll(['--fragment-retries', '$fragmentRetries']);
    final concurrentFragments = config.concurrentFragments ?? 4;
    if (concurrentFragments > 0) {
      args.addAll(['-N', '$concurrentFragments']);
    }
    if (config.rateLimit?.isNotEmpty ?? false) {
      args.addAll(['-r', config.rateLimit!]);
    }
    if (config.forceIpv4) args.add('-4');
    final extractorParts = <String>[];
    final clients = config.enabledPlayerClients
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet();
    if (clients.isNotEmpty) {
      extractorParts.add('player_client=${clients.join(',')}');
    }
    if (config.visitorData?.isNotEmpty ?? false) {
      extractorParts.add('visitor_data=${config.visitorData}');
    }
    final tokens = config.poTokens
        .where((item) => item.enabled && item.hasValue)
        .map((item) => '${item.client}.${item.context}+${item.token}')
        .toList();
    if (tokens.isNotEmpty) extractorParts.add('po_token=${tokens.join(',')}');
    if (extractorParts.isNotEmpty) {
      args.addAll(['--extractor-args', 'youtube:${extractorParts.join(';')}']);
    }
    return args;
  }

  Future<bool> _startLinuxYoutubeDownload(NativeDownloadRequest request) async {
    final executable = _linuxYtDlpPath;
    if (executable == null || !await File(executable).exists()) return false;
    await Directory(request.outputDir).create(recursive: true);
    final args = <String>[
      if (_linuxFfmpegPath?.isNotEmpty ?? false) ...[
        '--ffmpeg-location',
        _linuxFfmpegPath!,
      ],
      ...request.args,
    ];
    final existing = _linuxProcesses.remove(request.taskId);
    if (existing != null) {
      final groupId = _linuxProcessGroups.remove(request.taskId);
      if (groupId != null) {
        Process.killPid(-groupId, ProcessSignal.sigterm);
      } else {
        existing.kill(ProcessSignal.sigterm);
      }
    }
    final setsidPath = await _findLinuxSetsid();
    final process = await Process.start(
      setsidPath ?? executable,
      setsidPath == null ? args : [executable, ...args],
      workingDirectory: request.outputDir,
    );
    _linuxProcesses[request.taskId] = process;
    if (setsidPath != null) {
      _linuxProcessGroups[request.taskId] = process.pid;
    }
    _emitLinuxEvent(
      DownloadTaskEvent(taskId: request.taskId, type: 'task_started'),
    );
    unawaited(_watchLinuxProcess(request, process));
    return true;
  }

  Future<void> _watchLinuxProcess(
    NativeDownloadRequest request,
    Process process,
  ) async {
    final messages = <String>[];
    Future<void> consume(Stream<List<int>> stream) {
      return stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) {
            final trimmed = line.trim();
            if (trimmed.isEmpty) return;
            messages.add(trimmed);
            if (messages.length > 30) messages.removeAt(0);
            _handleLinuxOutputLine(request.taskId, trimmed);
          });
    }

    final stdoutDone = consume(process.stdout);
    final stderrDone = consume(process.stderr);
    final exitCode = await process.exitCode;
    await Future.wait([stdoutDone, stderrDone]);
    _linuxProcesses.remove(request.taskId);
    _linuxProcessGroups.remove(request.taskId);
    final terminationReason = _linuxTerminationReasons.remove(request.taskId);
    if (terminationReason == 'pause') {
      _emitLinuxEvent(
        DownloadTaskEvent(
          taskId: request.taskId,
          type: 'task_paused',
          message: '任务已暂停',
        ),
      );
      return;
    }
    if (terminationReason == 'cancel') {
      _emitLinuxEvent(
        DownloadTaskEvent(
          taskId: request.taskId,
          type: 'task_cancelled',
          message: '任务已取消',
        ),
      );
      return;
    }
    final producedPaths = await _findLinuxProducedPaths(request);
    final outputPath =
        _linuxOutputPaths.remove(request.taskId) ??
        (producedPaths.isEmpty ? null : producedPaths.first);
    if (exitCode == 0 && producedPaths.isNotEmpty) {
      _emitLinuxEvent(
        DownloadTaskEvent(
          taskId: request.taskId,
          type: 'task_completed',
          progress: 1,
          outputPath: outputPath,
          producedPaths: producedPaths,
        ),
      );
    } else {
      _emitLinuxEvent(
        DownloadTaskEvent(
          taskId: request.taskId,
          type: 'task_failed',
          errorCode: 'YT_DLP_EXIT_$exitCode',
          message: messages.isEmpty ? 'yt-dlp 下载失败' : messages.last,
          outputPath: outputPath,
          producedPaths: producedPaths,
        ),
      );
    }
  }

  void _handleLinuxOutputLine(String taskId, String line) {
    const beforeMarker = '__YTDLP_BEFORE_DL__:';
    const afterMarker = '__YTDLP_AFTER_MOVE__:';
    final marker = line.contains(afterMarker)
        ? afterMarker
        : line.contains(beforeMarker)
        ? beforeMarker
        : null;
    if (marker != null) {
      final path = line.substring(line.indexOf(marker) + marker.length).trim();
      if (path.isNotEmpty) _linuxOutputPaths[taskId] = path;
    }
    final progressMatch = RegExp(
      r'^\[download\]\s+(\d+(?:\.\d+)?)%',
    ).firstMatch(line);
    if (progressMatch != null) {
      final percent = double.tryParse(progressMatch.group(1) ?? '');
      _emitLinuxEvent(
        DownloadTaskEvent(
          taskId: taskId,
          type: 'task_progress',
          progress: percent == null ? null : (percent / 100).clamp(0, 1),
          outputPath: _linuxOutputPaths[taskId],
          message: line,
        ),
      );
      return;
    }
    final postProcessing =
        line.startsWith('[Merger]') ||
        line.startsWith('[ExtractAudio]') ||
        line.startsWith('[VideoConvertor]') ||
        line.startsWith('[EmbedSubtitle]') ||
        line.startsWith('[Metadata]');
    if (postProcessing) {
      _emitLinuxEvent(
        DownloadTaskEvent(
          taskId: taskId,
          type: 'task_post_processing',
          outputPath: _linuxOutputPaths[taskId],
          message: line,
        ),
      );
    }
  }

  Future<List<String>> _findLinuxProducedPaths(
    NativeDownloadRequest request,
  ) async {
    final output = <String>[];
    final directory = Directory(request.outputDir);
    if (!await directory.exists()) return output;
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!name.contains('__${request.taskId}.')) continue;
      final lower = name.toLowerCase();
      if (lower.endsWith('.part') ||
          lower.endsWith('.ytdl') ||
          lower.endsWith('.temp')) {
        continue;
      }
      output.add(entity.path);
    }
    return output;
  }

  Future<bool> _terminateLinuxTask(String taskId, String reason) async {
    final process = _linuxProcesses[taskId];
    if (process == null) return false;
    _linuxTerminationReasons[taskId] = reason;
    final groupId = _linuxProcessGroups[taskId];
    final stopped = groupId != null
        ? Process.killPid(-groupId, ProcessSignal.sigterm)
        : process.kill(ProcessSignal.sigterm);
    if (stopped) {
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 150), () {
          if (!identical(_linuxProcesses[taskId], process)) return;
          if (groupId != null) {
            Process.killPid(-groupId, ProcessSignal.sigkill);
          } else {
            process.kill(ProcessSignal.sigkill);
          }
        }),
      );
    }
    return stopped;
  }

  Future<String?> _findLinuxSetsid() async {
    for (final candidate in const ['/usr/bin/setsid', '/bin/setsid']) {
      if (await File(candidate).exists()) return candidate;
    }
    return null;
  }

  void _emitLinuxEvent(DownloadTaskEvent event) {
    _linuxStatuses[event.taskId] = event;
    if (!_linuxEvents.isClosed) _linuxEvents.add(event);
  }
}
