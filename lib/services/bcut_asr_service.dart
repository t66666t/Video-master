import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:video_player_app/models/subtitle_model.dart';

enum BcutAsrFailureKind { riskControl, networkUnavailable, transient, rejected }

class BcutAsrException implements Exception {
  final BcutAsrFailureKind kind;
  final String message;
  final int? statusCode;

  const BcutAsrException(this.kind, this.message, {this.statusCode});

  bool get isRiskControl => kind == BcutAsrFailureKind.riskControl;

  @override
  String toString() => message;
}

class BcutAsrService {
  static const String _baseUrl =
      "https://member.bilibili.com/x/bcut/rubick-interface";
  // 必剪接口受 B 站风控保护，伪造 UA 会被拦截返回 412，必须使用真实浏览器 UA
  static const String _userAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

  late final Dio _dio;

  BcutAsrService({Dio? dio}) {
    _dio =
        dio ??
        Dio(
          BaseOptions(
            headers: {
              "User-Agent": _userAgent,
              "Content-Type": "application/json",
            },
            // 增加超时时间，因为上传可能较慢
            sendTimeout: const Duration(minutes: 5),
            connectTimeout: const Duration(seconds: 20),
            receiveTimeout: const Duration(minutes: 5),
          ),
        );
  }

  // 音频转字幕主方法
  Future<List<SubtitleItem>> transcribeAudio(
    String audioPath, {
    bool needWordTimestamp = false,
    Function(double progress, String status)? onProgress,
    CancelToken? cancelToken,
  }) async {
    try {
      _throwIfCancelled(cancelToken);
      onProgress?.call(0.0, "准备音频文件...");

      // 1. 读取音频文件
      final File audioFile = File(audioPath);
      if (!await audioFile.exists()) {
        throw Exception("音频文件不存在: $audioPath");
      }
      final int audioLength = await audioFile.length();
      if (audioLength <= 0) {
        throw const BcutAsrException(BcutAsrFailureKind.rejected, '待识别音频为空文件');
      }
      _throwIfCancelled(cancelToken);

      onProgress?.call(0.1, "请求上传授权...");

      // 2. 请求上传授权
      final uploadAuth = await _requestUploadAuth(
        audioLength,
        cancelToken: cancelToken,
      );

      onProgress?.call(0.2, "上传音频文件...");

      // 3. 分块上传音频
      final etags = await _uploadAudioChunks(
        audioFile,
        audioLength,
        uploadAuth,
        (uploaded, total) {
          // 上传进度占 20% - 50%
          final p = 0.2 + (uploaded / total) * 0.3;
          onProgress?.call(p, "上传音频中 ${(p * 100).toStringAsFixed(0)}%...");
        },
        cancelToken: cancelToken,
      );

      onProgress?.call(0.5, "提交上传...");

      // 4. 提交上传
      final downloadUrl = await _commitUpload(
        uploadAuth,
        etags,
        cancelToken: cancelToken,
      );

      onProgress?.call(0.6, "创建转录任务...");

      // 5. 创建ASR任务
      final taskId = await _createTask(downloadUrl, cancelToken: cancelToken);

      onProgress?.call(0.7, "等待转录结果...");

      // 6. 查询任务结果
      final result = await _queryTaskResult(taskId, (retryCount, maxRetries) {
        // 等待进度占 70% - 90%
        final p = 0.7 + (retryCount / maxRetries) * 0.2;
        onProgress?.call(p, "转录处理中...");
      }, cancelToken: cancelToken);

      onProgress?.call(0.9, "解析字幕结果...");

      // 7. 解析结果
      return _parseSubtitleResult(result, needWordTimestamp);
    } catch (e) {
      // 简单的错误处理
      if (e is DioException && CancelToken.isCancel(e)) {
        rethrow;
      }
      if (e is DioException) throw classifyDioException(e);
      rethrow;
    }
  }

  static BcutAsrException classifyDioException(DioException error) {
    final status = error.response?.statusCode;
    final responseText = error.response?.data?.toString() ?? '';
    if (status == 412 || status == 429 || _looksLikeRiskControl(responseText)) {
      return BcutAsrException(
        BcutAsrFailureKind.riskControl,
        '请求被服务端风控拦截${status == null ? '' : ' ($status)'}，请稍后重试',
        statusCode: status,
      );
    }
    if (error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout ||
        error.error is SocketException) {
      return const BcutAsrException(
        BcutAsrFailureKind.networkUnavailable,
        '当前网络不可用或无法连接到字幕服务，请检查网络后重试',
      );
    }
    final kind = status != null && status >= 500
        ? BcutAsrFailureKind.transient
        : BcutAsrFailureKind.rejected;
    return BcutAsrException(
      kind,
      '字幕服务请求失败: ${error.message}${status == null ? '' : ' ($status)'}',
      statusCode: status,
    );
  }

  static bool _looksLikeRiskControl(String value) {
    final normalized = value.toLowerCase();
    return normalized.contains('风控') ||
        normalized.contains('请求频繁') ||
        normalized.contains('访问频繁') ||
        normalized.contains('too many requests') ||
        normalized.contains('rate limit');
  }

  Never _throwApiFailure(String operation, Object? code, Object? message) {
    final text = message?.toString() ?? '未知错误';
    if (_looksLikeRiskControl(text) ||
        code == -412 ||
        code == 412 ||
        code == 429) {
      throw BcutAsrException(
        BcutAsrFailureKind.riskControl,
        '$operation被服务端风控拦截：$text',
      );
    }
    if (code == 139201 || text.contains('第三方服务异常')) {
      throw BcutAsrException(
        BcutAsrFailureKind.transient,
        '$operation时第三方存储服务暂时异常，请稍后重试'
        '${code == null ? '' : ' (Code: $code)'}',
      );
    }
    throw BcutAsrException(
      BcutAsrFailureKind.rejected,
      '$operation失败：$text${code == null ? '' : ' (Code: $code)'}',
    );
  }

  // 请求上传授权
  Future<Map<String, dynamic>> _requestUploadAuth(
    int fileSize, {
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.post(
      "$_baseUrl/resource/create",
      data: jsonEncode({
        "type": 2,
        "name": "audio.m4a",
        "size": fileSize,
        "ResourceFileType": "m4a",
        "model_id": "8",
      }),
      cancelToken: cancelToken,
    );

    if (response.data['code'] != 0) {
      _throwApiFailure(
        '请求上传授权',
        response.data['code'],
        response.data['message'],
      );
    }
    return response.data['data'];
  }

  // 分块上传音频
  Future<List<String>> _uploadAudioChunks(
    File audioFile,
    int audioLength,
    Map<String, dynamic> uploadAuth,
    Function(int uploaded, int total) onProgress, {
    CancelToken? cancelToken,
  }) async {
    final int clips = uploadAuth['upload_urls'].length;
    final int perSize = uploadAuth['per_size'];
    final List<String> uploadUrls = List<String>.from(
      uploadAuth['upload_urls'],
    );
    if (clips <= 0 || perSize <= 0 || uploadUrls.length != clips) {
      throw const BcutAsrException(
        BcutAsrFailureKind.rejected,
        '服务端返回了无效的分块上传参数',
      );
    }

    int totalUploaded = 0;
    final List<String> etags = [];
    final reader = await audioFile.open();

    try {
      for (int i = 0; i < clips; i++) {
        _throwIfCancelled(cancelToken);
        final remaining = audioLength - totalUploaded;
        if (remaining <= 0) {
          throw const BcutAsrException(
            BcutAsrFailureKind.rejected,
            '服务端分块数量与音频大小不匹配',
          );
        }
        final chunkSize = remaining < perSize ? remaining : perSize;
        final Uint8List chunk = await reader.read(chunkSize);
        if (chunk.isEmpty && chunkSize > 0) {
          throw const BcutAsrException(
            BcutAsrFailureKind.rejected,
            '读取待上传音频时提前到达文件末尾',
          );
        }

        final response = await _dio.put(
          uploadUrls[i],
          data: chunk,
          options: Options(
            contentType: 'application/octet-stream',
            headers: {'Content-Length': chunk.length},
          ),
          cancelToken: cancelToken,
        );

        String? etag = response.headers.value('etag');
        if (etag != null) {
          // 去掉引号，Bcut 接口要求纯哈希值
          etag = etag.replaceAll('"', '');
          etags.add(etag);
        } else {
          throw Exception("分块 ${i + 1} 上传失败: 未获取到 ETag");
        }

        totalUploaded += chunk.length;
        onProgress(totalUploaded, audioLength);

        // 稍微延迟一下，避免短时间内过快请求
        await _cancelableDelay(const Duration(milliseconds: 250), cancelToken);
      }
    } finally {
      await reader.close();
    }

    if (etags.length != clips || totalUploaded != audioLength) {
      throw Exception("上传校验失败: 分块数量不匹配 (${etags.length}/$clips)");
    }

    return etags;
  }

  // 提交上传
  Future<String> _commitUpload(
    Map<String, dynamic> uploadAuth,
    List<String> etags, {
    CancelToken? cancelToken,
  }) async {
    // 当前可用的必剪上传实现以及旧版应用都以逗号分隔字符串提交
    // ETags。之前改为优先发送 JSON 数组字符串，会触发 139201。
    final primary = await _commitUploadAttempt(
      uploadAuth,
      etags.join(','),
      cancelToken: cancelToken,
    );
    if (primary.data['code'] == 0) {
      return primary.data['data']['download_url'];
    }

    final firstCode = primary.data['code'];
    final firstMessage = primary.data['message']?.toString() ?? '';
    if (!_shouldTryAlternateEtags(firstCode, firstMessage)) {
      _throwApiFailure('提交上传', firstCode, firstMessage);
    }

    // 给对象存储的分片状态一点传播时间，然后只做一次格式兼容重试。
    // 取消信号在等待期间仍然有效，不会阻塞“暂停全部”。
    await _cancelableDelay(const Duration(milliseconds: 800), cancelToken);
    final fallback = await _commitUploadAttempt(
      uploadAuth,
      jsonEncode(etags),
      cancelToken: cancelToken,
    );
    if (fallback.data['code'] == 0) {
      return fallback.data['data']['download_url'];
    }
    _throwApiFailure('提交上传', fallback.data['code'], fallback.data['message']);
  }

  Future<Response<dynamic>> _commitUploadAttempt(
    Map<String, dynamic> uploadAuth,
    String etags, {
    CancelToken? cancelToken,
  }) {
    return _dio.post(
      "$_baseUrl/resource/create/complete",
      data: {
        "InBossKey": uploadAuth['in_boss_key'],
        "ResourceId": uploadAuth['resource_id'],
        "Etags": etags,
        "UploadId": uploadAuth['upload_id'],
        "model_id": "8",
      },
      cancelToken: cancelToken,
    );
  }

  bool _shouldTryAlternateEtags(Object? code, String message) {
    if (code == 139201) return true;
    if (code == -412 || code == 412 || code == 429) return false;
    final normalized = message.toLowerCase();
    if (_looksLikeRiskControl(normalized)) return false;
    return normalized.contains('etag') ||
        normalized.contains('参数') ||
        normalized.contains('格式') ||
        normalized.contains('第三方服务异常');
  }

  // 创建ASR任务
  Future<String> _createTask(
    String downloadUrl, {
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.post(
      "$_baseUrl/task",
      data: {"resource": downloadUrl, "model_id": "8"},
      cancelToken: cancelToken,
    );

    if (response.data['code'] != 0) {
      _throwApiFailure(
        '创建转录任务',
        response.data['code'],
        response.data['message'],
      );
    }

    return response.data['data']['task_id'];
  }

  // 查询任务结果
  Future<Map<String, dynamic>> _queryTaskResult(
    String taskId,
    Function(int retryCount, int maxRetries) onRetry, {
    CancelToken? cancelToken,
  }) async {
    int retryCount = 0;
    const maxRetries = 120; // 增加重试次数，避免长音频超时
    while (retryCount < maxRetries) {
      _throwIfCancelled(cancelToken);
      final response = await _dio.get(
        "$_baseUrl/task/result",
        queryParameters: {
          "model_id": "8", // 统一使用 "8"
          "task_id": taskId,
        },
        cancelToken: cancelToken,
      );

      final data = response.data['data'];
      // state: 1: waiting, 2: processing, 3: ? , 4: success, 5: failed
      if (data['state'] == 4) {
        // 任务完成
        return jsonDecode(data['result']);
      } else if (data['state'] == 5) {
        throw Exception("转录任务失败");
      }

      retryCount++;
      onRetry(retryCount, maxRetries);
      // 逐步降低轮询频率，长任务不再持续每两秒轰击接口。
      final delaySeconds = 2 + (retryCount ~/ 10).clamp(0, 4);
      await _cancelableDelay(Duration(seconds: delaySeconds), cancelToken);
    }

    throw Exception("转录超时");
  }

  void _throwIfCancelled(CancelToken? cancelToken) {
    if (cancelToken?.isCancelled == true) {
      throw DioException(
        requestOptions: RequestOptions(path: ''),
        type: DioExceptionType.cancel,
        error: cancelToken?.cancelError,
      );
    }
  }

  Future<void> _cancelableDelay(
    Duration duration,
    CancelToken? cancelToken,
  ) async {
    if (cancelToken == null) {
      await Future<void>.delayed(duration);
      return;
    }
    _throwIfCancelled(cancelToken);
    await Future.any<void>([
      Future<void>.delayed(duration),
      cancelToken.whenCancel.then<void>((_) => _throwIfCancelled(cancelToken)),
    ]);
  }

  // 解析字幕结果
  List<SubtitleItem> _parseSubtitleResult(
    Map<String, dynamic> result,
    bool needWordTimestamp,
  ) {
    final List<SubtitleItem> subtitles = [];
    int index = 0;

    if (needWordTimestamp) {
      // 解析字级时间戳
      for (var utterance in result['utterances']) {
        for (var word in utterance['words']) {
          final startSec = word['start_time'] / 1000.0;
          final endSec = word['end_time'] / 1000.0;

          subtitles.add(
            SubtitleItem(
              index: ++index,
              startTime: Duration(milliseconds: (startSec * 1000).toInt()),
              endTime: Duration(milliseconds: (endSec * 1000).toInt()),
              text: word['label'].toString().trim(),
            ),
          );
        }
      }
    } else {
      // 解析句级时间戳
      for (var utterance in result['utterances']) {
        final startSec = utterance['start_time'] / 1000.0;
        final endSec = utterance['end_time'] / 1000.0;

        subtitles.add(
          SubtitleItem(
            index: ++index,
            startTime: Duration(milliseconds: (startSec * 1000).toInt()),
            endTime: Duration(milliseconds: (endSec * 1000).toInt()),
            text: utterance['transcript'].toString(),
          ),
        );
      }
    }

    return subtitles;
  }
}
