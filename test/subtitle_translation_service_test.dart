import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';

/// 360 翻译方向支持逻辑的单元测试（离线，不依赖网络）。
void main() {
  group('SubtitleTranslationService MyMemory 限流保护', () {
    test('批次串行执行并在请求之间等待 1.5 秒', () async {
      final dir = Directory.systemTemp.createTempSync('mymemory_throttle');
      addTearDown(() => dir.deleteSync(recursive: true));
      final inputPath = '${dir.path}/input.srt';
      final text = 'A' * 300;
      File(inputPath).writeAsStringSync(
        '1\r\n00:00:01,000 --> 00:00:02,000\r\n$text\r\n\r\n'
        '2\r\n00:00:03,000 --> 00:00:04,000\r\n$text\r\n\r\n',
      );

      var requestCount = 0;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requestCount++;
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: <String, dynamic>{
                  'responseStatus': 200,
                  'responseData': <String, dynamic>{
                    'translatedText': '译文$requestCount',
                  },
                },
              ),
            );
          },
        ),
      );
      final delays = <Duration>[];
      final service = SubtitleTranslationService(
        dio: dio,
        delay: (duration) async => delays.add(duration),
      );

      await service.translateSubtitleFile(
        inputPath: inputPath,
        sourceLanguage: 'en',
        targetLanguage: 'zh-CN',
        provider: SubtitleTranslateProvider.mymemory,
        onProgress: (_) {},
      );

      expect(requestCount, 2);
      expect(delays, <Duration>[const Duration(milliseconds: 1500)]);
    });

    test('限流响应会退避重试，不会静默写回原文', () async {
      final dir = Directory.systemTemp.createTempSync('mymemory_retry');
      addTearDown(() => dir.deleteSync(recursive: true));
      final inputPath = '${dir.path}/input.srt';
      File(inputPath).writeAsStringSync(
        '1\r\n00:00:01,000 --> 00:00:02,000\r\nHello world\r\n\r\n',
      );

      var requestCount = 0;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requestCount++;
            if (requestCount == 1) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response<dynamic>(
                    requestOptions: options,
                    statusCode: 429,
                  ),
                ),
              );
              return;
            }
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: <String, dynamic>{
                  'responseStatus': 200,
                  'responseData': <String, dynamic>{'translatedText': '你好，世界'},
                },
              ),
            );
          },
        ),
      );
      final delays = <Duration>[];
      final service = SubtitleTranslationService(
        dio: dio,
        delay: (duration) async => delays.add(duration),
      );

      final result = await service.translateSubtitleFile(
        inputPath: inputPath,
        sourceLanguage: 'en',
        targetLanguage: 'zh-CN',
        provider: SubtitleTranslateProvider.mymemory,
        onProgress: (_) {},
      );

      expect(requestCount, 2);
      expect(delays, <Duration>[const Duration(seconds: 2)]);
      expect(File(result.outputPath).readAsStringSync(), contains('你好，世界'));
      expect(
        File(result.outputPath).readAsStringSync(),
        isNot(contains('Hello world')),
      );
    });
  });

  group('SubtitleTranslationService.so360 方向校验', () {
    final service = SubtitleTranslationService();

    test('英语 → 简体中文 支持', () {
      expect(service.isSo360DirectionSupported('en', 'zh-CN'), isTrue);
    });

    test('英语 → 繁体中文 支持', () {
      expect(service.isSo360DirectionSupported('en', 'zh-TW'), isTrue);
    });

    test('简体中文 → 英语 支持', () {
      expect(service.isSo360DirectionSupported('zh-CN', 'en'), isTrue);
    });

    test('繁体中文 → 英语 支持', () {
      expect(service.isSo360DirectionSupported('zh-TW', 'en'), isTrue);
    });

    test('auto 源语言兼容', () {
      expect(service.isSo360DirectionSupported('auto', 'en'), isTrue);
      expect(service.isSo360DirectionSupported('auto', 'zh-CN'), isTrue);
      expect(service.isSo360DirectionSupported('auto', 'zh-TW'), isTrue);
    });

    test('英语 → 日语 不支持', () {
      expect(service.isSo360DirectionSupported('en', 'ja'), isFalse);
    });

    test('日语 → 简体中文 不支持', () {
      expect(service.isSo360DirectionSupported('ja', 'zh-CN'), isFalse);
    });

    test('韩语 → 英语 不支持', () {
      expect(service.isSo360DirectionSupported('ko', 'en'), isFalse);
    });

    test('简体中文 → 法语 不支持', () {
      expect(service.isSo360DirectionSupported('zh-CN', 'fr'), isFalse);
    });

    test('英语 → 英语 不支持', () {
      expect(service.isSo360DirectionSupported('en', 'en'), isFalse);
    });
  });

  group('SubtitleTranslationService.isEnZhDirection 方向判定', () {
    final service = SubtitleTranslationService();

    test('英 → 简中 为中英方向', () {
      expect(service.isEnZhDirection('en', 'zh-CN'), isTrue);
    });

    test('简中 → 英 为中英方向', () {
      expect(service.isEnZhDirection('zh-CN', 'en'), isTrue);
    });

    test('英 → 繁体 为中英方向', () {
      expect(service.isEnZhDirection('en', 'zh-TW'), isTrue);
    });

    test('繁体 → 英 为中英方向', () {
      expect(service.isEnZhDirection('zh-TW', 'en'), isTrue);
    });

    test('auto → 中文 为中英方向', () {
      expect(service.isEnZhDirection('auto', 'zh-CN'), isTrue);
    });

    test('英 → auto 为中英方向', () {
      expect(service.isEnZhDirection('en', 'auto'), isTrue);
    });

    test('日语 → 中文 不是中英方向', () {
      expect(service.isEnZhDirection('ja', 'zh-CN'), isFalse);
    });

    test('中文 → 日语 不是中英方向', () {
      expect(service.isEnZhDirection('zh-CN', 'ja'), isFalse);
    });

    test('英语 → 日语 不是中英方向', () {
      expect(service.isEnZhDirection('en', 'ja'), isFalse);
    });

    test('葡萄牙语 → 中文 不是中英方向', () {
      expect(service.isEnZhDirection('pt', 'zh-CN'), isFalse);
    });

    test('中文 → 法语 不是中英方向', () {
      expect(service.isEnZhDirection('zh-CN', 'fr'), isFalse);
    });

    test('韩语 → 日语 不是中英方向', () {
      expect(service.isEnZhDirection('ko', 'ja'), isFalse);
    });
  });

  group('SubtitleTranslationService 集成测试（需网络）', () {
    // 网络集成测试：真实调用 360 接口翻译 SRT 文件。
    // 通过 --dart-define=SO360_LIVE_TEST=true 启用。
    final runLive = const bool.fromEnvironment(
      'SO360_LIVE_TEST',
      defaultValue: false,
    );

    test('MyMemory 翻译完整 SRT 文件（英 → 简中）', () async {
      if (!runLive) {
        markTestSkipped('未启用在线测试，使用 --dart-define=SO360_LIVE_TEST=true 运行');
        return;
      }

      final dir = Directory.systemTemp.createTempSync('mymemory_test');
      addTearDown(() => dir.deleteSync(recursive: true));

      final inputPath = '${dir.path}/input_en.srt';
      final lines = <String>[];
      for (var i = 0; i < 8; i++) {
        final startSec = i * 3;
        final endSec = startSec + 2;
        lines.add('${i + 1}');
        lines.add(
          '00:00:${startSec.toString().padLeft(2, '0')},000 --> '
          '00:00:${endSec.toString().padLeft(2, '0')},000',
        );
        lines.add('Hello world, this is line number ${i + 1}.');
        lines.add('');
      }
      File(inputPath).writeAsStringSync(lines.join('\r\n'));

      final service = SubtitleTranslationService();
      final result = await service.translateSubtitleFile(
        inputPath: inputPath,
        sourceLanguage: 'en',
        targetLanguage: 'zh-CN',
        provider: SubtitleTranslateProvider.mymemory,
        onProgress: (_) {},
      );

      expect(result.totalCount, 8);
      final content = File(result.outputPath).readAsStringSync();
      final textLines = content
          .split('\r\n')
          .where((l) => l.isNotEmpty)
          .where((l) => !RegExp(r'^\d+$').hasMatch(l))
          .where((l) => !l.contains('-->'))
          .toList();
      expect(textLines.length, 8);
      for (final line in textLines) {
        expect(line.trim().isNotEmpty, isTrue, reason: '译文不应为空: $line');
        final hasCjk = RegExp(r'[\u4e00-\u9fff]').hasMatch(line);
        expect(hasCjk, isTrue, reason: 'MyMemory 英译中应包含中文: $line');
      }
    });

    test('MyMemory 翻译完整 SRT 文件（简中 → 日语）', () async {
      if (!runLive) {
        markTestSkipped('未启用在线测试，使用 --dart-define=SO360_LIVE_TEST=true 运行');
        return;
      }

      final dir = Directory.systemTemp.createTempSync('mymemory_ja_test');
      addTearDown(() => dir.deleteSync(recursive: true));

      final inputPath = '${dir.path}/input_zh.srt';
      final lines = <String>[];
      for (var i = 0; i < 5; i++) {
        final startSec = i * 3;
        final endSec = startSec + 2;
        lines.add('${i + 1}');
        lines.add(
          '00:00:${startSec.toString().padLeft(2, '0')},000 --> '
          '00:00:${endSec.toString().padLeft(2, '0')},000',
        );
        lines.add('你好，我每天喝咖啡。这是第 ${i + 1} 行。');
        lines.add('');
      }
      File(inputPath).writeAsStringSync(lines.join('\r\n'));

      final service = SubtitleTranslationService();
      final result = await service.translateSubtitleFile(
        inputPath: inputPath,
        sourceLanguage: 'zh-CN',
        targetLanguage: 'ja',
        provider: SubtitleTranslateProvider.mymemory,
        onProgress: (_) {},
      );

      expect(result.totalCount, 5);
      final content = File(result.outputPath).readAsStringSync();
      final textLines = content
          .split('\r\n')
          .where((l) => l.isNotEmpty)
          .where((l) => !RegExp(r'^\d+$').hasMatch(l))
          .where((l) => !l.contains('-->'))
          .toList();
      expect(textLines.length, 5);
      for (final line in textLines) {
        expect(line.trim().isNotEmpty, isTrue, reason: '译文不应为空: $line');
        final hasKana = RegExp(r'[\u3040-\u30ff]').hasMatch(line);
        expect(hasKana, isTrue, reason: 'MyMemory 中译日应包含日文假名: $line');
      }
    });

    test('Reverso 翻译完整 SRT 文件（英 → 简中）', () async {
      if (!runLive) {
        markTestSkipped('未启用在线测试，使用 --dart-define=SO360_LIVE_TEST=true 运行');
        return;
      }

      final dir = Directory.systemTemp.createTempSync('reverso_test');
      addTearDown(() => dir.deleteSync(recursive: true));

      final inputPath = '${dir.path}/input_en.srt';
      final lines = <String>[];
      for (var i = 0; i < 5; i++) {
        final startSec = i * 3;
        final endSec = startSec + 2;
        lines.add('${i + 1}');
        lines.add(
          '00:00:${startSec.toString().padLeft(2, '0')},000 --> '
          '00:00:${endSec.toString().padLeft(2, '0')},000',
        );
        lines.add('Hello world, this is line number ${i + 1}.');
        lines.add('');
      }
      File(inputPath).writeAsStringSync(lines.join('\r\n'));

      final service = SubtitleTranslationService();
      final result = await service.translateSubtitleFile(
        inputPath: inputPath,
        sourceLanguage: 'en',
        targetLanguage: 'zh-CN',
        provider: SubtitleTranslateProvider.reverso,
        onProgress: (_) {},
      );

      expect(result.totalCount, 5);
      final content = File(result.outputPath).readAsStringSync();
      final textLines = content
          .split('\r\n')
          .where((l) => l.isNotEmpty)
          .where((l) => !RegExp(r'^\d+$').hasMatch(l))
          .where((l) => !l.contains('-->'))
          .toList();
      expect(textLines.length, 5);
      for (final line in textLines) {
        expect(line.trim().isNotEmpty, isTrue, reason: '译文不应为空: $line');
        final hasCjk = RegExp(r'[\u4e00-\u9fff]').hasMatch(line);
        expect(hasCjk, isTrue, reason: 'Reverso 英译中应包含中文: $line');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('Reverso 翻译完整 SRT 文件（简中 → 日语）', () async {
      if (!runLive) {
        markTestSkipped('未启用在线测试，使用 --dart-define=SO360_LIVE_TEST=true 运行');
        return;
      }

      final dir = Directory.systemTemp.createTempSync('reverso_ja_test');
      addTearDown(() => dir.deleteSync(recursive: true));

      final inputPath = '${dir.path}/input_zh.srt';
      final lines = <String>[];
      for (var i = 0; i < 3; i++) {
        final startSec = i * 3;
        final endSec = startSec + 2;
        lines.add('${i + 1}');
        lines.add(
          '00:00:${startSec.toString().padLeft(2, '0')},000 --> '
          '00:00:${endSec.toString().padLeft(2, '0')},000',
        );
        lines.add('你好，我每天喝咖啡。这是第 ${i + 1} 行。');
        lines.add('');
      }
      File(inputPath).writeAsStringSync(lines.join('\r\n'));

      final service = SubtitleTranslationService();
      final result = await service.translateSubtitleFile(
        inputPath: inputPath,
        sourceLanguage: 'zh-CN',
        targetLanguage: 'ja',
        provider: SubtitleTranslateProvider.reverso,
        onProgress: (_) {},
      );

      expect(result.totalCount, 3);
      final content = File(result.outputPath).readAsStringSync();
      final textLines = content
          .split('\r\n')
          .where((l) => l.isNotEmpty)
          .where((l) => !RegExp(r'^\d+$').hasMatch(l))
          .where((l) => !l.contains('-->'))
          .toList();
      expect(textLines.length, 3);
      for (final line in textLines) {
        expect(line.trim().isNotEmpty, isTrue, reason: '译文不应为空: $line');
        final hasKana = RegExp(r'[\u3040-\u30ff]').hasMatch(line);
        expect(hasKana, isTrue, reason: 'Reverso 中译日应包含日文假名: $line');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('MyMemory 超长字幕行应自动截断而非报错', () async {
      if (!runLive) {
        markTestSkipped('未启用在线测试，使用 --dart-define=SO360_LIVE_TEST=true 运行');
        return;
      }

      final dir = Directory.systemTemp.createTempSync('mymemory_long_test');
      addTearDown(() => dir.deleteSync(recursive: true));

      final inputPath = '${dir.path}/input_long.srt';
      final longText =
          'The quick brown fox jumps over the lazy dog. ' * 20; // >500 字符
      File(inputPath).writeAsStringSync(
        '1\r\n00:00:01,000 --> 00:00:02,000\r\n$longText\r\n\r\n',
      );

      final service = SubtitleTranslationService();
      final result = await service.translateSubtitleFile(
        inputPath: inputPath,
        sourceLanguage: 'en',
        targetLanguage: 'zh-CN',
        provider: SubtitleTranslateProvider.mymemory,
        onProgress: (_) {},
      );

      expect(result.totalCount, 1);
      final content = File(result.outputPath).readAsStringSync();
      expect(content.isNotEmpty, isTrue);
      // 超长行截断后仍应成功翻译（内容非空、非原文）
      expect(
        content.contains('The quick brown fox jumps over the lazy dog. ' * 20),
        isFalse,
      );
    });

    test('MyMemory 批量翻译真实字幕（含歌词符号/中英混合，返回空时保留原文）', () async {
      if (!runLive) {
        markTestSkipped('未启用在线测试，使用 --dart-define=SO360_LIVE_TEST=true 运行');
        return;
      }

      final dir = Directory.systemTemp.createTempSync('mymemory_real');
      addTearDown(() => dir.deleteSync(recursive: true));

      // 模拟用户真实字幕文件：中文 + 英文歌词 + 特殊符号
      final realLines = [
        '♪ Nice nice baby ♪',
        'Take my first blood',
        'Double kill triple',
        '高适的呀',
        '美签可以啊',
        'I can\'t tell you',
        'Yeah',
        '身份证掉了怎么样',
        '开放世界游戏遗忘之海PC端今天上线',
        '首赛季可屯300抽',
        '还有丰富公测福利等你来拿',
      ];
      final srtLines = <String>[];
      for (var i = 0; i < realLines.length; i++) {
        final startSec = i * 3;
        final endSec = startSec + 2;
        srtLines.add('${i + 1}');
        srtLines.add(
          '00:00:${startSec.toString().padLeft(2, '0')},000 --> '
          '00:00:${endSec.toString().padLeft(2, '0')},000',
        );
        srtLines.add(realLines[i]);
        srtLines.add('');
      }
      final inputPath = '${dir.path}/input_real.srt';
      File(inputPath).writeAsStringSync(srtLines.join('\r\n'));

      final service = SubtitleTranslationService();
      final result = await service.translateSubtitleFile(
        inputPath: inputPath,
        sourceLanguage: 'zh-CN',
        targetLanguage: 'en',
        provider: SubtitleTranslateProvider.mymemory,
        onProgress: (_) {},
      );

      expect(result.totalCount, realLines.length);
      final content = File(result.outputPath).readAsStringSync();
      // 输出行数必须与输入一致（不允许因空数据丢失行）
      final textLines = content
          .split('\r\n')
          .where((l) => l.isNotEmpty)
          .where((l) => !RegExp(r'^\d+$').hasMatch(l))
          .where((l) => !l.contains('-->'))
          .toList();
      expect(textLines.length, realLines.length, reason: '输出行数应与输入一致，防止空数据丢行');
    });

    test('360 翻译完整 SRT 文件（英 → 简中）', () async {
      if (!runLive) {
        markTestSkipped('未启用在线测试，使用 --dart-define=SO360_LIVE_TEST=true 运行');
        return;
      }

      final dir = Directory.systemTemp.createTempSync('so360_test');
      addTearDown(() => dir.deleteSync(recursive: true));

      // 构造一个包含 10 条英文字幕的 SRT 文件
      final inputPath = '${dir.path}/input_en.srt';
      final lines = <String>[];
      for (var i = 0; i < 10; i++) {
        final startSec = i * 3;
        final endSec = startSec + 2;
        lines.add('${i + 1}');
        lines.add(
          '00:00:${startSec.toString().padLeft(2, '0')},000 --> '
          '00:00:${endSec.toString().padLeft(2, '0')},000',
        );
        lines.add('Hello world, this is line number ${i + 1}.');
        lines.add('');
      }
      File(inputPath).writeAsStringSync(lines.join('\r\n'));

      final service = SubtitleTranslationService();
      final result = await service.translateSubtitleFile(
        inputPath: inputPath,
        sourceLanguage: 'en',
        targetLanguage: 'zh-CN',
        provider: SubtitleTranslateProvider.so360,
        onProgress: (_) {},
      );

      expect(result.totalCount, 10);
      final out = File(result.outputPath);
      expect(out.existsSync(), isTrue);
      final content = out.readAsStringSync();
      // 每条译文应非空，且包含中文字符
      final textLines = content
          .split('\r\n')
          .where((l) => l.isNotEmpty)
          .where((l) => !RegExp(r'^\d+$').hasMatch(l))
          .where((l) => !l.contains('-->'))
          .toList();
      expect(textLines.length, 10);
      for (final line in textLines) {
        expect(line.trim().isNotEmpty, isTrue, reason: '译文不应为空: $line');
        final hasCjk = RegExp(r'[\u4e00-\u9fff]').hasMatch(line);
        expect(hasCjk, isTrue, reason: '英译中应包含中文: $line');
      }
    });

    test('360 翻译完整 SRT 文件（简中 → 英）', () async {
      if (!runLive) {
        markTestSkipped('未启用在线测试，使用 --dart-define=SO360_LIVE_TEST=true 运行');
        return;
      }

      final dir = Directory.systemTemp.createTempSync('so360_zh_test');
      addTearDown(() => dir.deleteSync(recursive: true));

      final inputPath = '${dir.path}/input_zh.srt';
      final lines = <String>[];
      for (var i = 0; i < 5; i++) {
        final startSec = i * 3;
        final endSec = startSec + 2;
        lines.add('${i + 1}');
        lines.add(
          '00:00:${startSec.toString().padLeft(2, '0')},000 --> '
          '00:00:${endSec.toString().padLeft(2, '0')},000',
        );
        lines.add('你好，世界。这是第 ${i + 1} 行字幕。');
        lines.add('');
      }
      File(inputPath).writeAsStringSync(lines.join('\r\n'));

      final service = SubtitleTranslationService();
      final result = await service.translateSubtitleFile(
        inputPath: inputPath,
        sourceLanguage: 'zh-CN',
        targetLanguage: 'en',
        provider: SubtitleTranslateProvider.so360,
        onProgress: (_) {},
      );

      expect(result.totalCount, 5);
      final content = File(result.outputPath).readAsStringSync();
      final textLines = content
          .split('\r\n')
          .where((l) => l.isNotEmpty)
          .where((l) => !RegExp(r'^\d+$').hasMatch(l))
          .where((l) => !l.contains('-->'))
          .toList();
      expect(textLines.length, 5);
      for (final line in textLines) {
        expect(line.trim().isNotEmpty, isTrue, reason: '译文不应为空: $line');
        final hasAsciiLetters = RegExp(r'[a-zA-Z]').hasMatch(line);
        expect(hasAsciiLetters, isTrue, reason: '中译英应包含英文: $line');
      }
    });

    test('360 翻译不支持的方向应抛出明确错误', () async {
      if (!runLive) {
        markTestSkipped('未启用在线测试，使用 --dart-define=SO360_LIVE_TEST=true 运行');
        return;
      }

      final dir = Directory.systemTemp.createTempSync('so360_bad_dir');
      addTearDown(() => dir.deleteSync(recursive: true));

      final inputPath = '${dir.path}/input_ja.srt';
      File(inputPath).writeAsStringSync(
        '1\r\n00:00:01,000 --> 00:00:02,000\r\nこんにちは、世界。\r\n\r\n',
      );

      final service = SubtitleTranslationService();
      expect(
        () => service.translateSubtitleFile(
          inputPath: inputPath,
          sourceLanguage: 'ja',
          targetLanguage: 'zh-CN',
          provider: SubtitleTranslateProvider.so360,
          onProgress: (_) {},
        ),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('仅支持中英互译'),
          ),
        ),
      );
    });
  });
}
