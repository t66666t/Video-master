import 'dart:async';

import 'package:flutter/services.dart';
import 'package:video_player_app/features/youtube_download/models/youtube_download_models.dart';

class YtDlpBinaryStatus {
  final bool ytDlpReady;
  final bool ffmpegReady;
  final String? ytDlpVersion;
  final String? ffmpegVersion;
  final String? ytDlpPath;
  final String? ffmpegPath;
  final String? diagnosticMessage;

  const YtDlpBinaryStatus({
    this.ytDlpReady = false,
    this.ffmpegReady = false,
    this.ytDlpVersion,
    this.ffmpegVersion,
    this.ytDlpPath,
    this.ffmpegPath,
    this.diagnosticMessage,
  });

  factory YtDlpBinaryStatus.fromJson(Map<String, dynamic> json) {
    return YtDlpBinaryStatus(
      ytDlpReady: json['ytDlpReady'] == true,
      ffmpegReady: json['ffmpegReady'] == true,
      ytDlpVersion: json['ytDlpVersion']?.toString(),
      ffmpegVersion: json['ffmpegVersion']?.toString(),
      ytDlpPath: json['ytDlpPath']?.toString(),
      ffmpegPath: json['ffmpegPath']?.toString(),
      diagnosticMessage: json['diagnosticMessage']?.toString(),
    );
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
  static const String saveYoutubeSessionConfigMethod = 'saveYoutubeSessionConfig';
  static const String loadYoutubeSessionConfigMethod = 'loadYoutubeSessionConfig';
  static const String getBinaryStatusMethod = 'getYtDlpBinaryStatus';

  Stream<DownloadTaskEvent> taskEvents() {
    return _eventChannel.receiveBroadcastStream().map((event) {
      return DownloadTaskEvent.fromJson(
        Map<String, dynamic>.from(event as Map),
      );
    });
  }

  Future<Map<String, dynamic>?> resolveYoutubeMeta(
    String url,
    DownloadSessionConfig sessionConfig,
  ) async {
    try {
      final result = await _methodChannel.invokeMapMethod<String, dynamic>(
        resolveYoutubeMetaMethod,
        {
          'url': url,
          'sessionConfig': sessionConfig.toJson(),
        },
      );
      if (result == null) return null;
      return Map<String, dynamic>.from(result);
    } on MissingPluginException {
      return null;
    }
  }

  Future<bool> startYoutubeDownload(NativeDownloadRequest request) async {
    try {
      return await _methodChannel.invokeMethod<bool>(
            startYoutubeDownloadMethod,
            request.toJson(),
          ) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> pauseYoutubeDownload(String taskId) async {
    try {
      return await _methodChannel.invokeMethod<bool>(
            pauseYoutubeDownloadMethod,
            {'taskId': taskId},
          ) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> cancelYoutubeDownload(String taskId) async {
    try {
      return await _methodChannel.invokeMethod<bool>(
            cancelYoutubeDownloadMethod,
            {'taskId': taskId},
          ) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> removeYoutubeTask(String taskId) async {
    try {
      return await _methodChannel.invokeMethod<bool>(
            removeYoutubeTaskMethod,
            {'taskId': taskId},
          ) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<Map<String, dynamic>?> getYoutubeTaskStatus(String taskId) async {
    try {
      final result = await _methodChannel.invokeMapMethod<String, dynamic>(
        getYoutubeTaskStatusMethod,
        {'taskId': taskId},
      );
      if (result == null) return null;
      return Map<String, dynamic>.from(result);
    } on MissingPluginException {
      return null;
    }
  }

  Future<String?> importYoutubeCookies(String filePath) async {
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
}
