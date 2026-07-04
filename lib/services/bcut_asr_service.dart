import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:video_player_app/models/subtitle_model.dart';

class BcutAsrService {
  static const String _baseUrl = "https://member.bilibili.com/x/bcut/rubick-interface";
  final Dio _dio = Dio(BaseOptions(
    headers: {
      "User-Agent": "Bilibili/1.0.0 (https://www.bilibili.com)",
      "Content-Type": "application/json",
    },
    // 增加超时时间，因为上传可能较慢
    sendTimeout: const Duration(minutes: 5),
    receiveTimeout: const Duration(minutes: 5),
  ));

  // 音频转字幕主方法
  Future<List<SubtitleItem>> transcribeAudio(String audioPath, {
    bool needWordTimestamp = false,
    Function(double progress, String status)? onProgress,
  }) async {
    try {
      onProgress?.call(0.0, "准备音频文件...");
      
      // 1. 读取音频文件
      final File audioFile = File(audioPath);
      if (!await audioFile.exists()) {
        throw Exception("音频文件不存在: $audioPath");
      }
      final List<int> audioBytes = await audioFile.readAsBytes();
      
      onProgress?.call(0.1, "请求上传授权...");
      
      // 2. 请求上传授权
      final uploadAuth = await _requestUploadAuth(audioBytes.length);
      
      onProgress?.call(0.2, "上传音频文件...");
      
      // 3. 分块上传音频
      final etags = await _uploadAudioChunks(audioBytes, uploadAuth, (uploaded, total) {
        // 上传进度占 20% - 50%
        final p = 0.2 + (uploaded / total) * 0.3;
        onProgress?.call(p, "上传音频中 ${(p * 100).toStringAsFixed(0)}%...");
      });
      
      onProgress?.call(0.5, "提交上传...");
      
      // 4. 提交上传
      final downloadUrl = await _commitUpload(uploadAuth, etags);
      
      onProgress?.call(0.6, "创建转录任务...");
      
      // 5. 创建ASR任务
      final taskId = await _createTask(downloadUrl);
      
      onProgress?.call(0.7, "等待转录结果...");
      
      // 6. 查询任务结果
      final result = await _queryTaskResult(taskId, (retryCount, maxRetries) {
        // 等待进度占 70% - 90%
        final p = 0.7 + (retryCount / maxRetries) * 0.2;
        onProgress?.call(p, "转录处理中...");
      });
      
      onProgress?.call(0.9, "解析字幕结果...");
      
      // 7. 解析结果
      return _parseSubtitleResult(result, needWordTimestamp);
      
    } catch (e) {
      // 简单的错误处理
      if (e is DioException) {
         throw Exception("网络请求失败: ${e.message} [${e.response?.statusCode}]");
      }
      rethrow;
    }
  }

  // 请求上传授权
  Future<Map<String, dynamic>> _requestUploadAuth(int fileSize) async {
    final response = await _dio.post(
      "$_baseUrl/resource/create",
      data: jsonEncode({
        "type": 2,
        "name": "audio.m4a",
        "size": fileSize,
        "ResourceFileType": "m4a",
        "model_id": "8",
      }),
    );
    
    if (response.data['code'] != 0) {
      throw Exception("请求上传授权失败: ${response.data['message']}");
    }
    return response.data['data'];
  }

  // 分块上传音频
  Future<List<String>> _uploadAudioChunks(
      List<int> audioBytes, 
      Map<String, dynamic> uploadAuth,
      Function(int uploaded, int total) onProgress
  ) async {
    final int clips = uploadAuth['upload_urls'].length;
    final int perSize = uploadAuth['per_size'];
    final List<String> uploadUrls = List<String>.from(uploadAuth['upload_urls']);
    
    int totalUploaded = 0;
    List<String> etags = [];

    for (int i = 0; i < clips; i++) {
      final int start = i * perSize;
      final int end = (i + 1) * perSize;
      final List<int> chunk = audioBytes.sublist(
        start, 
        end > audioBytes.length ? audioBytes.length : end
      );
      
      final response = await _dio.put(
        uploadUrls[i],
        data: chunk,
        options: Options(
          contentType: 'application/octet-stream',
          headers: {
            'Content-Length': chunk.length,
          },
        ),
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
      onProgress(totalUploaded, audioBytes.length);
      
      // 稍微延迟一下，避免短时间内过快请求
      await Future.delayed(const Duration(milliseconds: 100));
    }
    
    if (etags.length != clips) {
      throw Exception("上传校验失败: 分块数量不匹配 (${etags.length}/$clips)");
    }
    
    return etags;
  }

  // 提交上传
  Future<String> _commitUpload(Map<String, dynamic> uploadAuth, List<String> etags) async {
    // 某些版本的接口要求 Etags 是 JSON 数组字符串，某些要求是逗号分隔
    // 我们先尝试 JSON 数组字符串，但确保没有多余的转义
    final response = await _dio.post(
      "$_baseUrl/resource/create/complete",
      data: {
        "InBossKey": uploadAuth['in_boss_key'],
        "ResourceId": uploadAuth['resource_id'],
        "Etags": jsonEncode(etags), 
        "UploadId": uploadAuth['upload_id'],
        "model_id": "8",
      },
    );
    
    if (response.data['code'] != 0) {
      // 如果失败，尝试另一种 Etags 格式 (某些接口版本要求逗号分隔的字符串)
      if (response.data['message']?.contains('异常') ?? false || response.data['code'] != 0) {
         final retryResponse = await _dio.post(
          "$_baseUrl/resource/create/complete",
          data: {
            "InBossKey": uploadAuth['in_boss_key'],
            "ResourceId": uploadAuth['resource_id'],
            "Etags": etags.join(','), 
            "UploadId": uploadAuth['upload_id'],
            "model_id": "8",
          },
        );
        if (retryResponse.data['code'] == 0) {
          return retryResponse.data['data']['download_url'];
        }
      }
      throw Exception("提交上传失败: ${response.data['message']} (Code: ${response.data['code']})");
    }
    
    return response.data['data']['download_url'];
  }

  // 创建ASR任务
  Future<String> _createTask(String downloadUrl) async {
    final response = await _dio.post(
      "$_baseUrl/task",
      data: {
        "resource": downloadUrl,
        "model_id": "8",
      },
    );
    
    if (response.data['code'] != 0) {
      throw Exception("创建任务失败: ${response.data['message']} (Code: ${response.data['code']})");
    }
    
    return response.data['data']['task_id'];
  }

  // 查询任务结果
  Future<Map<String, dynamic>> _queryTaskResult(
      String taskId, 
      Function(int retryCount, int maxRetries) onRetry
  ) async {
    int retryCount = 0;
    const maxRetries = 120; // 增加重试次数，避免长音频超时
    const retryDelay = Duration(seconds: 2); // 增加间隔
    
    while (retryCount < maxRetries) {
      final response = await _dio.get(
        "$_baseUrl/task/result",
        queryParameters: {
          "model_id": "8", // 统一使用 "8"
          "task_id": taskId,
        },
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
      await Future.delayed(retryDelay);
    }
    
    throw Exception("转录超时");
  }

  // 解析字幕结果
  List<SubtitleItem> _parseSubtitleResult(Map<String, dynamic> result, bool needWordTimestamp) {
    final List<SubtitleItem> subtitles = [];
    int index = 0;
    
    if (needWordTimestamp) {
      // 解析字级时间戳
      for (var utterance in result['utterances']) {
        for (var word in utterance['words']) {
            final startSec = word['start_time'] / 1000.0;
            final endSec = word['end_time'] / 1000.0;
            
            subtitles.add(SubtitleItem(
                index: ++index,
                startTime: Duration(milliseconds: (startSec * 1000).toInt()),
                endTime: Duration(milliseconds: (endSec * 1000).toInt()),
                text: word['label'].toString().trim(),
            ));
        }
      }
    } else {
      // 解析句级时间戳
      for (var utterance in result['utterances']) {
        final startSec = utterance['start_time'] / 1000.0;
        final endSec = utterance['end_time'] / 1000.0;
        
        subtitles.add(SubtitleItem(
            index: ++index,
            startTime: Duration(milliseconds: (startSec * 1000).toInt()),
            endTime: Duration(milliseconds: (endSec * 1000).toInt()),
            text: utterance['transcript'].toString(),
        ));
      }
    }
    
    return subtitles;
  }
}
