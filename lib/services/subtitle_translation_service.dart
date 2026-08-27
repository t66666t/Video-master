import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/subtitle_model.dart';
import '../utils/subtitle_parser.dart';

class SubtitleTranslationLanguage {
  final String code;
  final String label;

  const SubtitleTranslationLanguage({required this.code, required this.label});
}

enum SubtitleTranslateProvider { google, bing, so360, mymemory, reverso }

class SubtitleTranslationResult {
  final String outputPath;
  final int totalCount;

  const SubtitleTranslationResult({
    required this.outputPath,
    required this.totalCount,
  });
}

/// 翻译完成事件（成功或失败）。
class SubtitleTranslationCompletion {
  final String videoPath;
  final SubtitleTranslationResult? result;
  final Object? error;

  const SubtitleTranslationCompletion({
    required this.videoPath,
    this.result,
    this.error,
  });

  bool get isSuccess => result != null && error == null;
}

/// 翻译任务完成回调签名。
typedef SubtitleTranslationCompletionCallback =
    void Function(SubtitleTranslationCompletion completion);

class SubtitleTranslationService extends ChangeNotifier {
  static const List<SubtitleTranslationLanguage> popularLanguages = [
    SubtitleTranslationLanguage(code: 'en', label: '英语'),
    SubtitleTranslationLanguage(code: 'zh-CN', label: '简体中文'),
    SubtitleTranslationLanguage(code: 'zh-TW', label: '繁体中文'),
    SubtitleTranslationLanguage(code: 'ja', label: '日语'),
    SubtitleTranslationLanguage(code: 'ko', label: '韩语'),
    SubtitleTranslationLanguage(code: 'fr', label: '法语'),
    SubtitleTranslationLanguage(code: 'de', label: '德语'),
    SubtitleTranslationLanguage(code: 'es', label: '西班牙语'),
    SubtitleTranslationLanguage(code: 'ru', label: '俄语'),
    SubtitleTranslationLanguage(code: 'it', label: '意大利语'),
    SubtitleTranslationLanguage(code: 'pt', label: '葡萄牙语'),
  ];

  static const Map<String, String> _googleLangMap = {
    'auto': 'auto',
    'zh-CN': 'zh-CN',
    'zh-TW': 'zh-TW',
    'en': 'en',
    'ja': 'ja',
    'ko': 'ko',
    'fr': 'fr',
    'de': 'de',
    'es': 'es',
    'ru': 'ru',
    'it': 'it',
    'pt': 'pt',
  };

  static const Map<String, String> _bingLangMap = {
    'auto': '',
    'zh-CN': 'zh-Hans',
    'zh-TW': 'zh-Hant',
    'en': 'en',
    'ja': 'ja',
    'ko': 'ko',
    'fr': 'fr',
    'de': 'de',
    'es': 'es',
    'ru': 'ru',
    'it': 'it',
    'pt': 'pt',
  };

  /// 360 翻译仅支持中英互译（eng=0 中译英，eng=1 英译中）。
  /// 与微软/谷歌不同，无法指定日语、韩语、法语等目标语言。
  /// key 为 "源语言|目标语言"（使用软件语言代码），value 为 360 的 eng 参数。
  static const Map<String, int> _so360DirectionMap = {
    'zh-CN|en': 0, // 简体中文 -> 英语
    'zh-TW|en': 0, // 繁体中文 -> 英语
    'auto|en': 0,
    'en|zh-CN': 1, // 英语 -> 简体中文
    'en|zh-TW': 1, // 英语 -> 繁体中文
    'en|auto': 1,
  };

  static const String _googleEndpoint = 'https://translate.google.com/m';
  static const String _edgeAuthEndpoint =
      'https://edge.microsoft.com/translate/auth';
  static const String _edgeTranslateEndpoint =
      'https://api-edge.cognitive.microsofttranslator.com/translate';
  static const String _so360Endpoint = 'https://fanyi.so.com/index/search';
  static const String _myMemoryEndpoint =
      'https://api.mymemory.translated.net/get';

  static const String _googleUserAgent =
      'Mozilla/4.0 (compatible;MSIE 6.0;Windows NT 5.1;SV1;.NET CLR 1.1.4322;.NET CLR 2.0.50727;.NET CLR 3.0.04506.30)';

  static const String _edgeUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0';

  /// auth 端点会拒绝带 `Edg/` 的 Edge 浏览器 UA（返回 400），
  /// 改用通用 Chrome UA 取 Token；翻译端点仍用 [_edgeUserAgent]。
  static const String _authUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  /// 360 翻译请求头：`pro: fanyi` 是关键请求头（缺失时接口返回空响应）。
  static const String _so360UserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  /// MyMemory 语言代码映射（软件代码 -> MyMemory 代码）。
  /// MyMemory 使用标准 ISO 639-1 代码（如 en/ja/ko/fr/de/es/ru/it/pt），
  /// 中文使用 zh-CN / zh-TW。
  static const Map<String, String> _myMemoryLangMap = {
    'zh-CN': 'zh-CN',
    'zh-TW': 'zh-TW',
    'en': 'en',
    'ja': 'ja',
    'ko': 'ko',
    'fr': 'fr',
    'de': 'de',
    'es': 'es',
    'ru': 'ru',
    'it': 'it',
    'pt': 'pt',
  };

  /// MyMemory 单次查询最大字符数（超限返回
  /// `QUERY LENGTH LIMIT EXCEEDED. MAX ALLOWED QUERY : 500 CHARS`）。
  /// 字幕行通常较短，但需防御超长行。
  static const int _myMemoryMaxQueryLength = 500;

  /// MyMemory's anonymous endpoint starts returning degraded responses when
  /// requests arrive in bursts. Keep it deliberately conservative: one batch
  /// at a time, with a pause between batches and exponential retry backoff.
  static const Duration _myMemoryRequestInterval = Duration(milliseconds: 1500);
  static const List<Duration> _myMemoryRetryDelays = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 4),
  ];

  /// Reverso 语言代码映射（软件代码 -> Reverso 代码）。
  /// Reverso 使用 ISO 639-1 代码（en/ja/ko/fr/de/es/ru/it/pt），
  /// 中文统一为 `chi`（繁体中文作为源文本可识别，目标为 zh-TW 时输出简体）。
  static const Map<String, String> _reversoLangMap = {
    'auto': 'chi',
    'zh-CN': 'chi',
    'zh-TW': 'chi',
    'en': 'en',
    'ja': 'ja',
    'ko': 'ko',
    'fr': 'fr',
    'de': 'de',
    'es': 'es',
    'ru': 'ru',
    'it': 'it',
    'pt': 'pt',
  };

  static const String _reversoEndpoint =
      'https://api.reverso.net/translate/v1/translation';

  static const String _reversoUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  /// Reverso 的 Cloudflare 会拦截 Dart 内置 HTTP 栈（BoringSSL TLS 指纹），
  /// 因此通过系统 `curl`（Schannel/OpenSSL TLS）发起请求。
  /// Windows 10+ 自带 curl.exe；macOS/Linux 自带 curl。
  static String get _reversoCurlCommand =>
      Platform.isWindows ? 'curl.exe' : 'curl';

  final Dio _dio;
  final Future<void> Function(Duration) _delay;
  String? _bingToken;

  SubtitleTranslationService._internal({Dio? dio})
    : _dio = dio ?? Dio(),
      _delay = Future<void>.delayed;

  /// 全局单例。翻译任务的生命周期跨越 UI 重建，必须使用单例持有状态。
  static final SubtitleTranslationService instance =
      SubtitleTranslationService._internal();

  /// 仅供测试注入使用；UI 层应使用 [instance]。
  SubtitleTranslationService({
    Dio? dio,
    @visibleForTesting Future<void> Function(Duration)? delay,
  }) : _dio = dio ?? Dio(),
       _delay = delay ?? Future<void>.delayed;

  // ===== 活跃任务状态（跨 UI 重建保留） =====
  bool _isTranslating = false;
  double _progress = 0;
  String? _activeInputPath;
  String? _activeVideoPath;
  SubtitleTranslateProvider? _activeProvider;
  String? _activeSourceLanguage;
  String? _activeTargetLanguage;

  bool get isTranslating => _isTranslating;
  double get progress => _progress;
  String? get activeInputPath => _activeInputPath;
  String? get activeVideoPath => _activeVideoPath;
  SubtitleTranslateProvider? get activeProvider => _activeProvider;
  String? get activeSourceLanguage => _activeSourceLanguage;
  String? get activeTargetLanguage => _activeTargetLanguage;

  /// Whether the current task belongs to [videoPath].
  ///
  /// UI pages can be rebuilt while a translation is running.  Paths obtained
  /// from a fresh directory scan may differ only in normalization (and on
  /// Windows, letter case), so raw string equality would lose the task state.
  bool isTranslatingForVideo(String videoPath) {
    return _isTranslating &&
        _activeVideoPath != null &&
        _samePath(_activeVideoPath!, videoPath);
  }

  /// Whether the current task translates [inputPath] for [videoPath].
  bool isTranslatingPathForVideo({
    required String videoPath,
    required String inputPath,
  }) {
    return isTranslatingForVideo(videoPath) &&
        _activeInputPath != null &&
        _samePath(_activeInputPath!, inputPath);
  }

  bool _samePath(String first, String second) {
    final left = p.normalize(first);
    final right = p.normalize(second);
    return Platform.isWindows
        ? left.toLowerCase() == right.toLowerCase()
        : left == right;
  }

  /// 翻译完成回调列表。UI 在 initState 注册、dispose 移除。
  /// 即便发起翻译的 UI 已销毁，只要重开后重新注册即可接收后续完成事件。
  final List<SubtitleTranslationCompletionCallback> _completionCallbacks = [];

  void addCompletionCallback(SubtitleTranslationCompletionCallback cb) {
    _completionCallbacks.add(cb);
  }

  void removeCompletionCallback(SubtitleTranslationCompletionCallback cb) {
    _completionCallbacks.remove(cb);
  }

  void _notifyCompletion(SubtitleTranslationCompletion completion) {
    for (final cb in List.of(_completionCallbacks)) {
      try {
        cb(completion);
      } catch (_) {}
    }
  }

  Future<SubtitleTranslationResult> translateSubtitleFile({
    required String inputPath,
    required String sourceLanguage,
    required String targetLanguage,
    required SubtitleTranslateProvider provider,
    required void Function(double progress) onProgress,
    String? outputDirectory,
    String? outputFilePrefix,
    String? videoPath,
  }) async {
    if (_isTranslating) {
      throw StateError('已有字幕翻译任务正在进行，请等待当前任务完成');
    }
    // 设置活跃任务状态，通知 UI（含重开后的新 UI）能恢复进度显示
    _isTranslating = true;
    _progress = 0;
    _activeInputPath = inputPath;
    _activeVideoPath = videoPath;
    _activeProvider = provider;
    _activeSourceLanguage = sourceLanguage;
    _activeTargetLanguage = targetLanguage;
    notifyListeners();

    try {
      final file = File(inputPath);
      if (!await file.exists()) {
        throw Exception('字幕文件不存在');
      }

      final bytes = await file.readAsBytes();
      final content = SubtitleParser.decodeBytes(bytes);
      final items = SubtitleParser.parse(content);

      if (items.isEmpty) {
        throw Exception('字幕内容为空或格式不支持');
      }

      // 合并外部回调与内部进度更新
      void combinedProgress(double p) {
        _progress = p;
        notifyListeners();
        try {
          onProgress(p);
        } catch (_) {}
      }

      final translatedTexts = await _translateItems(
        items: items,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        provider: provider,
        onProgress: combinedProgress,
      );

      final outputPath = _buildOutputPath(
        inputPath: inputPath,
        targetLanguage: targetLanguage,
        outputDirectory: outputDirectory,
        outputFilePrefix: outputFilePrefix,
      );
      final outputDir = Directory(p.dirname(outputPath));
      if (!await outputDir.exists()) {
        await outputDir.create(recursive: true);
      }
      final srtContent = _buildSrt(items, translatedTexts);
      await File(outputPath).writeAsString(srtContent, flush: true);

      final result = SubtitleTranslationResult(
        outputPath: outputPath,
        totalCount: items.length,
      );
      _notifyCompletion(
        SubtitleTranslationCompletion(
          videoPath: videoPath ?? '',
          result: result,
        ),
      );
      return result;
    } catch (e) {
      _notifyCompletion(
        SubtitleTranslationCompletion(videoPath: videoPath ?? '', error: e),
      );
      rethrow;
    } finally {
      _isTranslating = false;
      _progress = 0;
      _activeInputPath = null;
      _activeVideoPath = null;
      _activeProvider = null;
      _activeSourceLanguage = null;
      _activeTargetLanguage = null;
      notifyListeners();
    }
  }

  Future<List<String>> _translateItems({
    required List<SubtitleItem> items,
    required String sourceLanguage,
    required String targetLanguage,
    required SubtitleTranslateProvider provider,
    required void Function(double progress) onProgress,
  }) async {
    final result = List<String>.filled(items.length, '');

    if (provider == SubtitleTranslateProvider.google) {
      for (int i = 0; i < items.length; i++) {
        final text = items[i].text.trim();
        if (text.isEmpty) {
          result[i] = '';
          onProgress((i + 1) / items.length);
          continue;
        }
        result[i] = await _translateWithGoogle(
          text: text,
          sourceLanguage: sourceLanguage,
          targetLanguage: targetLanguage,
        );
        onProgress((i + 1) / items.length);
        await Future.delayed(const Duration(milliseconds: 180));
      }
      return result;
    }

    if (provider == SubtitleTranslateProvider.so360) {
      _ensureSo360DirectionSupported(
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
      );
      // 360 接口无法换行批量（会把多行合并成一段），
      // 但无 Cloudflare 风控，实测并发 20 请求全部成功，
      // 因此采用并发请求加速（每波 8 个并发）。
      const int concurrency = 8;
      int done = 0;
      for (int i = 0; i < items.length; i += concurrency) {
        final end = (i + concurrency > items.length)
            ? items.length
            : i + concurrency;
        final batch = items.sublist(i, end);

        final futures = <Future<String>>[];
        for (final item in batch) {
          final text = item.text.trim();
          if (text.isEmpty) {
            futures.add(Future.value(''));
            continue;
          }
          futures.add(
            _translateWithSo360(
              text: text,
              sourceLanguage: sourceLanguage,
              targetLanguage: targetLanguage,
            ).catchError((e) => text),
          ); // 失败保留原文
        }

        final translated = await Future.wait(futures);
        for (int j = 0; j < batch.length; j++) {
          result[i + j] = translated[j];
        }
        done += batch.length;
        onProgress(done / items.length);
      }
      return result;
    }

    if (provider == SubtitleTranslateProvider.mymemory) {
      // MyMemory 的匿名接口对突发流量很敏感。按 500 字符切批后严格串行，
      // 并在批次间停顿；失败由下层退避重试，不能静默伪装成“翻译完成”。
      int done = 0;

      // 先按 500 字符上限将全部条目切分成批次（记录每个条目在 items 中的位置）
      final batches = <List<SubtitleItem>>[];
      final batchPositions = <List<int>>[];
      var currentBatch = <SubtitleItem>[];
      var currentPositions = <int>[];
      var charCount = 0;
      for (int k = 0; k < items.length; k++) {
        final item = items[k];
        final text = item.text.trim();
        if (text.isEmpty) {
          currentBatch.add(item);
          currentPositions.add(k);
          continue;
        }
        if (currentBatch.isNotEmpty &&
            charCount + text.length + 1 > _myMemoryMaxQueryLength) {
          batches.add(currentBatch);
          batchPositions.add(currentPositions);
          currentBatch = [];
          currentPositions = [];
          charCount = 0;
        }
        currentBatch.add(item);
        currentPositions.add(k);
        charCount += text.length + 1;
      }
      if (currentBatch.isNotEmpty) {
        batches.add(currentBatch);
        batchPositions.add(currentPositions);
      }

      for (int i = 0; i < batches.length; i++) {
        if (i > 0) {
          await _delay(_myMemoryRequestInterval);
        }
        final batch = batches[i];
        final positions = batchPositions[i];
        final batchTexts = batch.map((e) => e.text.trim()).toList();
        final translated = await _translateBatchWithMyMemoryRetry(
          texts: batchTexts,
          sourceLanguage: sourceLanguage,
          targetLanguage: targetLanguage,
        );
        for (int j = 0; j < batch.length; j++) {
          result[positions[j]] = translated[j];
        }
        done += batch.length;
        onProgress(done / items.length);
      }
      return result;
    }

    if (provider == SubtitleTranslateProvider.reverso) {
      // Reverso 依赖系统 curl 命令（安卓/iOS 无此命令），
      // 在移动端直接提示改用 MyMemory 等可用服务。
      if (Platform.isAndroid || Platform.isIOS) {
        throw Exception(
          'Reverso 翻译仅支持桌面端（需要系统 curl），'
          '请改用 MyMemory 翻译或 360 翻译',
        );
      }
      for (int i = 0; i < items.length; i++) {
        final text = items[i].text.trim();
        if (text.isEmpty) {
          result[i] = '';
          onProgress((i + 1) / items.length);
          continue;
        }
        // 逐条翻译失败时保留原文继续，避免单句失败中断整个流程
        try {
          result[i] = await _translateWithReverso(
            text: text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
          );
        } catch (e) {
          result[i] = text;
        }
        onProgress((i + 1) / items.length);
        // Reverso 的 Cloudflare 对连续快速请求会触发质询页，
        // 保持 2 秒间隔避免被临时拦截
        await Future.delayed(const Duration(milliseconds: 2000));
      }
      return result;
    }

    const int batchSize = 15;
    int done = 0;
    for (int i = 0; i < items.length; i += batchSize) {
      final end = (i + batchSize > items.length) ? items.length : i + batchSize;
      final batch = items.sublist(i, end);
      final batchTexts = batch.map((e) => e.text.trim()).toList();

      final translated = await _translateBatchWithBing(
        texts: batchTexts,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
      );

      for (int j = 0; j < translated.length; j++) {
        result[i + j] = translated[j];
      }
      done += batch.length;
      onProgress(done / items.length);
    }

    return result;
  }

  Future<String> _translateWithGoogle({
    required String text,
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    final sl = _googleLangMap[sourceLanguage] ?? sourceLanguage;
    final tl = _googleLangMap[targetLanguage] ?? targetLanguage;

    final safeText = _safeText(text);
    final response = await _dio.get(
      _googleEndpoint,
      queryParameters: {'sl': sl, 'tl': tl, 'q': safeText},
      options: Options(headers: {'User-Agent': _googleUserAgent}),
    );

    final body = response.data?.toString() ?? '';
    final regex = RegExp(
      r'class="(?:t0|result-container)">(.*?)<',
      dotAll: true,
    );
    final match = regex.firstMatch(body);
    if (match == null) {
      throw Exception('无法从 Google 翻译响应中提取结果');
    }

    return _htmlUnescape(match.group(1) ?? '').trim();
  }

  /// 360 翻译是否支持指定的源/目标语言方向（仅中英互译）。
  bool isSo360DirectionSupported(String sourceLanguage, String targetLanguage) {
    return _so360EngValue(sourceLanguage, targetLanguage) != null;
  }

  /// 是否为中英方向（源/目标中任意一方为中文、另一方为英文，
  /// 或包含 auto 自动检测）。用于自动选择翻译服务：
  /// 中英方向默认用 360，其他语言方向默认用 MyMemory。
  bool isEnZhDirection(String sourceLanguage, String targetLanguage) {
    final sourceIsZh =
        sourceLanguage == 'zh-CN' ||
        sourceLanguage == 'zh-TW' ||
        sourceLanguage == 'zh';
    final sourceIsEn = sourceLanguage == 'en';
    final targetIsZh =
        targetLanguage == 'zh-CN' ||
        targetLanguage == 'zh-TW' ||
        targetLanguage == 'zh';
    final targetIsEn = targetLanguage == 'en';
    if (sourceLanguage == 'auto' || targetLanguage == 'auto') {
      // auto 方向：若另一端是中文或英文，按中英方向处理
      return targetIsZh || targetIsEn || sourceIsZh || sourceIsEn;
    }
    return (sourceIsEn && targetIsZh) || (sourceIsZh && targetIsEn);
  }

  /// 校验 360 翻译的语言方向是否受支持。
  /// 360 免费接口仅支持中英互译；其他语言组合直接抛出明确错误。
  void _ensureSo360DirectionSupported({
    required String sourceLanguage,
    required String targetLanguage,
  }) {
    if (_so360EngValue(sourceLanguage, targetLanguage) != null) return;
    throw Exception(
      '360 翻译仅支持中英互译（英语⇄简体/繁体中文）。'
      '当前方向 $sourceLanguage → $targetLanguage 不受支持，请改用 Google 翻译。',
    );
  }

  /// 根据源/目标语言返回 360 的 eng 参数（0=中译英，1=英译中），
  /// 不支持的组合返回 null。
  int? _so360EngValue(String sourceLanguage, String targetLanguage) {
    final direct = _so360DirectionMap['$sourceLanguage|$targetLanguage'];
    if (direct != null) return direct;
    // auto 源语言兼容：中文内容（zh-CN/zh-TW）→ en、英文内容 → 中文
    if (sourceLanguage == 'auto') {
      if (targetLanguage == 'en') return 0;
      if (targetLanguage == 'zh-CN' || targetLanguage == 'zh-TW') return 1;
    }
    if (targetLanguage == 'auto') {
      if (sourceLanguage == 'zh-CN' || sourceLanguage == 'zh-TW') return 0;
      if (sourceLanguage == 'en') return 1;
    }
    return null;
  }

  Future<String> _translateWithSo360({
    required String text,
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    final eng = _so360EngValue(sourceLanguage, targetLanguage);
    if (eng == null) {
      _ensureSo360DirectionSupported(
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
      );
      throw Exception('360 翻译不支持该语言方向');
    }

    final response = await _dio.post(
      _so360Endpoint,
      data: <String, dynamic>{
        'query': _safeText(text),
        'eng': '$eng',
        'ignore_trans': '0',
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        headers: {
          'pro': 'fanyi',
          'User-Agent': _so360UserAgent,
          'Referer': 'https://fanyi.so.com/',
          'Origin': 'https://fanyi.so.com',
        },
      ),
    );

    final data = response.data;
    if (data is! Map) {
      throw Exception('360 翻译返回格式异常');
    }
    final error = data['error'];
    if (error != 0) {
      throw Exception('360 翻译返回错误: ${data['msg'] ?? error}');
    }
    final inner = data['data'];
    final fanyi = inner is Map ? inner['fanyi'] : null;
    final translated = fanyi?.toString().trim() ?? '';
    if (translated.isEmpty) {
      throw Exception('360 翻译返回为空');
    }
    return translated;
  }

  /// MyMemory 批量翻译：用换行符 `\n` 分隔多条文本一次请求。
  /// MyMemory 免费接口单次查询上限 500 字符，因此需按字符数分批。
  Future<List<String>> _translateBatchWithMyMemoryRetry({
    required List<String> texts,
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    Object? lastError;
    for (int attempt = 0; attempt <= _myMemoryRetryDelays.length; attempt++) {
      try {
        return await _translateBatchWithMyMemory(
          texts: texts,
          sourceLanguage: sourceLanguage,
          targetLanguage: targetLanguage,
        );
      } catch (error) {
        lastError = error;
        if (attempt >= _myMemoryRetryDelays.length) break;
        await _delay(_myMemoryRetryDelays[attempt]);
      }
    }
    throw Exception('MyMemory 翻译连续失败，已停止任务以避免用原文冒充译文: $lastError');
  }

  Future<List<String>> _translateBatchWithMyMemory({
    required List<String> texts,
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    final from = _myMemoryLangMap[sourceLanguage] ?? sourceLanguage;
    final to = _myMemoryLangMap[targetLanguage] ?? targetLanguage;

    final result = List<String>.filled(texts.length, '');
    final batchIndices = <int>[];
    final batchTexts = <String>[];
    for (int i = 0; i < texts.length; i++) {
      final text = texts[i].trim();
      if (text.isEmpty) continue;
      batchIndices.add(i);
      batchTexts.add(
        text.length > _myMemoryMaxQueryLength
            ? text.substring(0, _myMemoryMaxQueryLength)
            : text,
      );
    }
    if (batchTexts.isEmpty) return result;
    final query = batchTexts.join('\n');
    if (query.length > _myMemoryMaxQueryLength) {
      throw StateError('MyMemory 内部批次超过 500 字符限制');
    }

    final response = await _dio.get(
      _myMemoryEndpoint,
      queryParameters: <String, dynamic>{'q': query, 'langpair': '$from|$to'},
      options: Options(headers: {'User-Agent': _so360UserAgent}),
    );

    final data = response.data;
    if (data is! Map) {
      throw Exception('MyMemory 翻译返回格式异常');
    }
    final responseStatus = data['responseStatus'];
    if (responseStatus != 200) {
      final detail = data['responseDetails']?.toString() ?? '';
      if (detail.toUpperCase().contains('LIMIT') ||
          detail.toUpperCase().contains('QUOTA')) {
        throw Exception('MyMemory 翻译超出限额: $detail');
      }
      throw Exception('MyMemory 翻译返回错误: $detail');
    }
    final responseData = data['responseData'];
    final raw =
        (responseData is Map ? responseData['translatedText'] : null)
            ?.toString()
            .trim() ??
        '';
    if (raw.isEmpty || raw == query.trim()) {
      throw Exception('MyMemory 未返回有效译文（可能触发临时风控）');
    }

    final translatedLines = raw.split('\n');
    if (translatedLines.length != batchIndices.length) {
      throw Exception(
        'MyMemory 返回的译文行数不匹配（期望 ${batchIndices.length}，'
        '实际 ${translatedLines.length}）',
      );
    }
    for (int j = 0; j < batchIndices.length; j++) {
      final translated = translatedLines[j].trim();
      if (translated.isEmpty) {
        throw Exception('MyMemory 返回了空译文');
      }
      result[batchIndices[j]] = translated;
    }
    return result;
  }

  /// 通过系统 curl 调用 Reverso 翻译。
  ///
  /// 为什么不用 dio/dart:io：Reverso 的 Cloudflare 风控会拦截 Dart 内置
  /// HTTP 栈的 TLS 指纹（BoringSSL + HTTP/1.1 稳定返回 403 质询页），
  /// 而系统 curl（Schannel/OpenSSL TLS）实测可用。请求体写入临时文件、
  /// 以 `--data @file` 传参，可避免 Windows 命令行内联中文导致编码错乱。
  Future<String> _translateWithReverso({
    required String text,
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    final from = _reversoLangMap[sourceLanguage] ?? sourceLanguage;
    final to = _reversoLangMap[targetLanguage] ?? targetLanguage;

    final body = jsonEncode(<String, dynamic>{
      'format': 'text',
      'from': from,
      'to': to,
      'input': _safeText(text),
      'options': {
        'sentenceSplitter': 'false',
        'origin': 'translation.web',
        'contextResults': 'false',
        'languageDetection': 'false',
      },
    });

    // 写入临时文件（UTF-8 无 BOM），避免命令行内联中文转义问题
    final tmpFile = File(
      '${Directory.systemTemp.path}/reverso_body_${DateTime.now().microsecondsSinceEpoch}.json',
    );
    try {
      await tmpFile.writeAsString(body, encoding: utf8);

      final args = <String>[
        '-sS',
        '--max-time',
        '20',
        '-X',
        'POST',
        _reversoEndpoint,
        '-H',
        'Content-Type: application/json',
        '-H',
        'User-Agent: $_reversoUserAgent',
        '-H',
        'Referer: https://www.reverso.net/',
        '--data',
        '@${tmpFile.path}',
      ];

      // 偶发失败（网络抖动/Cloudflare 质询）时自动重试，最多 3 次。
      // 命中 Cloudflare 质询页时等待更长时间（10 秒）再重试。
      String out = '';
      for (var attempt = 0; attempt < 3; attempt++) {
        if (attempt > 0) {
          final wait = out.contains('Just a moment')
              ? const Duration(seconds: 10)
              : const Duration(seconds: 2);
          await Future.delayed(wait);
        }
        final result = await Process.run(
          _reversoCurlCommand,
          args,
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        out = (result.stdout as String).trim();
        if (result.exitCode == 0 &&
            out.isNotEmpty &&
            !out.contains('Just a moment')) {
          break;
        }
        out = 'curl 退出码 ${result.exitCode}: $out';
      }

      if (out.startsWith('curl 退出码') || out.contains('Just a moment')) {
        throw Exception('Reverso 翻译失败(触发 Cloudflare 风控，请稍后重试)');
      }

      try {
        final data = jsonDecode(out);
        if (data is! Map) {
          throw Exception('Reverso 翻译返回格式异常');
        }
        final translation = data['translation'];
        final translated = translation is List
            ? translation.join().toString().trim()
            : (translation?.toString() ?? '').trim();
        if (translated.isEmpty) {
          // 可能是限流/风控响应，给出更明确的错误
          final status = data['statusCode'];
          final message = data['error'] ?? data['message'];
          throw Exception(
            'Reverso 翻译返回为空'
            '${status != null ? '(statusCode=$status)' : ''}'
            '${message != null ? ' $message' : ''}',
          );
        }
        return translated;
      } on FormatException {
        throw Exception(
          'Reverso 翻译返回格式异常: ${out.substring(0, out.length.clamp(0, 120))}',
        );
      }
    } finally {
      if (await tmpFile.exists()) {
        await tmpFile.delete();
      }
    }
  }

  Future<String> _getBingToken() async {
    final response = await _dio.get(
      _edgeAuthEndpoint,
      options: Options(headers: {'User-Agent': _authUserAgent}),
    );
    final token = (response.data?.toString() ?? '').trim();
    if (token.isEmpty) {
      throw Exception('无法获取微软翻译 Token');
    }
    _bingToken = token;
    return token;
  }

  Future<List<String>> _translateBatchWithBing({
    required List<String> texts,
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    if (_bingToken == null || _bingToken!.isEmpty) {
      await _getBingToken();
    }

    Future<Response<dynamic>> request() {
      final to = _bingLangMap[targetLanguage] ?? targetLanguage;
      final from = _bingLangMap[sourceLanguage] ?? sourceLanguage;
      final query = <String, String>{
        'to': to,
        'api-version': '3.0',
        'includeSentenceLength': 'true',
      };
      if (from.isNotEmpty) {
        query['from'] = from;
      }

      final body = texts
          .map((text) => {'Text': _safeText(text)})
          .toList(growable: false);

      return _dio.post(
        _edgeTranslateEndpoint,
        queryParameters: query,
        data: body,
        options: Options(
          headers: {
            'Authorization': 'Bearer $_bingToken',
            'User-Agent': _edgeUserAgent,
            'Content-Type': 'application/json',
          },
        ),
      );
    }

    try {
      final response = await request();
      return _parseBingResponse(response.data, texts.length);
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) {
        await _getBingToken();
        final response = await request();
        return _parseBingResponse(response.data, texts.length);
      }
      rethrow;
    }
  }

  List<String> _parseBingResponse(dynamic data, int expectedLength) {
    if (data is! List) {
      throw Exception('微软翻译返回格式异常');
    }

    final translated = <String>[];
    for (final item in data) {
      if (item is! Map<String, dynamic>) {
        translated.add('');
        continue;
      }
      final translations = item['translations'];
      if (translations is List && translations.isNotEmpty) {
        final first = translations.first;
        if (first is Map<String, dynamic>) {
          translated.add((first['text']?.toString() ?? '').trim());
          continue;
        }
      }
      translated.add('');
    }

    if (translated.length < expectedLength) {
      translated.addAll(
        List<String>.filled(expectedLength - translated.length, ''),
      );
    }

    return translated.take(expectedLength).toList(growable: false);
  }

  String _safeText(String text) {
    final normalized = text.trim();
    if (normalized.isEmpty) return '';
    if (normalized.length <= 5000) return normalized;
    return normalized.substring(0, 5000);
  }

  String _buildOutputPath({
    required String inputPath,
    required String targetLanguage,
    String? outputDirectory,
    String? outputFilePrefix,
  }) {
    final dir = outputDirectory?.trim().isNotEmpty == true
        ? p.normalize(outputDirectory!.trim())
        : p.dirname(inputPath);
    final base = (outputFilePrefix?.trim().isNotEmpty == true)
        ? outputFilePrefix!.trim()
        : p.basenameWithoutExtension(inputPath);
    final ext = '.srt';
    final normalizedLang = targetLanguage.replaceAll(
      RegExp(r'[^a-zA-Z0-9\-]'),
      '_',
    );

    var candidate = p.join(dir, '$base.translated.$normalizedLang$ext');
    if (!File(candidate).existsSync()) {
      return candidate;
    }

    candidate = p.join(
      dir,
      '$base.translated.$normalizedLang.${DateTime.now().millisecondsSinceEpoch}$ext',
    );
    return candidate;
  }

  String _buildSrt(List<SubtitleItem> items, List<String> translatedTexts) {
    final eol = Platform.isWindows ? '\r\n' : '\n';
    final buffer = StringBuffer();

    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      final text = (i < translatedTexts.length ? translatedTexts[i] : '')
          .trim();
      buffer.write('${i + 1}$eol');
      buffer.write(
        '${_formatDuration(item.startTime)} --> ${_formatDuration(item.endTime)}$eol',
      );
      buffer.write('$text$eol$eol');
    }

    return buffer.toString();
  }

  String _formatDuration(Duration duration) {
    final h = duration.inHours.toString().padLeft(2, '0');
    final m = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final s = (duration.inSeconds % 60).toString().padLeft(2, '0');
    final ms = (duration.inMilliseconds % 1000).toString().padLeft(3, '0');
    return '$h:$m:$s,$ms';
  }

  String _htmlUnescape(String input) {
    if (input.isEmpty) return input;

    String out = input
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ');

    out = out.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
      final code = int.tryParse(m.group(1)!);
      if (code == null) return m.group(0)!;
      return String.fromCharCode(code);
    });

    out = out.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
      final code = int.tryParse(m.group(1)!, radix: 16);
      if (code == null) return m.group(0)!;
      return String.fromCharCode(code);
    });

    return out;
  }
}
