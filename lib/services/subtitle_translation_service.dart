import 'dart:io';


import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../models/subtitle_model.dart';
import '../utils/subtitle_parser.dart';

class SubtitleTranslationLanguage {
  final String code;
  final String label;

  const SubtitleTranslationLanguage({required this.code, required this.label});
}

enum SubtitleTranslateProvider { google, bing }

class SubtitleTranslationResult {
  final String outputPath;
  final int totalCount;

  const SubtitleTranslationResult({
    required this.outputPath,
    required this.totalCount,
  });
}

class SubtitleTranslationService {
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

  static const String _googleEndpoint = 'https://translate.google.com/m';
  static const String _edgeAuthEndpoint = 'https://edge.microsoft.com/translate/auth';
  static const String _edgeTranslateEndpoint =
      'https://api-edge.cognitive.microsofttranslator.com/translate';

  static const String _googleUserAgent =
      'Mozilla/4.0 (compatible;MSIE 6.0;Windows NT 5.1;SV1;.NET CLR 1.1.4322;.NET CLR 2.0.50727;.NET CLR 3.0.04506.30)';

  static const String _edgeUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0';

  final Dio _dio;
  String? _bingToken;

  SubtitleTranslationService({Dio? dio}) : _dio = dio ?? Dio();

  Future<SubtitleTranslationResult> translateSubtitleFile({
    required String inputPath,
    required String sourceLanguage,
    required String targetLanguage,
    required SubtitleTranslateProvider provider,
    required void Function(double progress) onProgress,
    String? outputDirectory,
    String? outputFilePrefix,
  }) async {
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

    final translatedTexts = await _translateItems(
      items: items,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage,
      provider: provider,
      onProgress: onProgress,
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

    return SubtitleTranslationResult(outputPath: outputPath, totalCount: items.length);
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
      queryParameters: {
        'sl': sl,
        'tl': tl,
        'q': safeText,
      },
      options: Options(
        headers: {
          'User-Agent': _googleUserAgent,
        },
      ),
    );

    final body = response.data?.toString() ?? '';
    final regex = RegExp(r'class="(?:t0|result-container)">(.*?)<', dotAll: true);
    final match = regex.firstMatch(body);
    if (match == null) {
      throw Exception('无法从 Google 翻译响应中提取结果');
    }

    return _htmlUnescape(match.group(1) ?? '').trim();
  }

  Future<String> _getBingToken() async {
    final response = await _dio.get(
      _edgeAuthEndpoint,
      options: Options(
        headers: {
          'User-Agent': _edgeUserAgent,
        },
      ),
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
      translated.addAll(List<String>.filled(expectedLength - translated.length, ''));
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
    final normalizedLang = targetLanguage.replaceAll(RegExp(r'[^a-zA-Z0-9\-]'), '_');

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
      final text = (i < translatedTexts.length ? translatedTexts[i] : '').trim();
      buffer.write('${i + 1}$eol');
      buffer.write('${_formatDuration(item.startTime)} --> ${_formatDuration(item.endTime)}$eol');
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
