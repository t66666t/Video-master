import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/pgs_parser.dart';
import 'package:video_player_app/utils/subtitle_parser.dart';

List<int> _toUtf16LeBytes(String value, {bool withBom = false}) {
  final codeUnits = value.codeUnits;
  final bytes = <int>[];
  if (withBom) {
    bytes.addAll([0xFF, 0xFE]);
  }
  for (final unit in codeUnits) {
    bytes.add(unit & 0xFF);
    bytes.add((unit >> 8) & 0xFF);
  }
  return bytes;
}

void main() {
  test('decodeBytes handles utf8 bom', () {
    final content = '1\n00:00:01,000 --> 00:00:02,000\nHello\n\n';
    final bytes = [0xEF, 0xBB, 0xBF, ...content.codeUnits];
    final decoded = SubtitleParser.decodeBytes(bytes);
    final parsed = SubtitleParser.parse(decoded);
    expect(parsed.length, 1);
    expect(parsed.first.text, 'Hello');
    expect(parsed.first.startTime.inMilliseconds, 1000);
  });

  test('decodeBytes handles utf16le bom', () {
    final content = '1\n00:00:03,000 --> 00:00:04,000\nWorld\n\n';
    final bytes = _toUtf16LeBytes(content, withBom: true);
    final decoded = SubtitleParser.decodeBytes(bytes);
    final parsed = SubtitleParser.parse(decoded);
    expect(parsed.length, 1);
    expect(parsed.first.text, 'World');
    expect(parsed.first.startTime.inMilliseconds, 3000);
  });

  test('parseSrt supports dot milliseconds', () {
    final content = '1\n00:00:05.5 --> 00:00:06.75\nDot\n\n';
    final parsed = SubtitleParser.parse(content);
    expect(parsed.length, 1);
    expect(parsed.first.startTime.inMilliseconds, 5500);
    expect(parsed.first.endTime.inMilliseconds, 6750);
  });

  test('parseSrt strips brace style tokens', () {
    final content = '1\n00:00:07,000 --> 00:00:08,000\n{\\fs16\\an2\\b0}字幕\n\n';
    final parsed = SubtitleParser.parse(content);
    expect(parsed.length, 1);
    expect(parsed.first.text, '字幕');
  });

  test('parse sup file yields image data when available', () async {
    final file = File(r'd:\1spbfq\字幕示例\58c06d2d-608c-435c-9af4-1dc77ae18ae5_main.sup');
    if (!file.existsSync()) return;
    final parsed = await PgsParser.parse(file.path);
    expect(parsed.isNotEmpty, true);
    final itemWithImage = parsed.firstWhere((item) => item.imageLoader != null, orElse: () => parsed.first);
    final image = await itemWithImage.imageLoader?.call();
    expect(image != null && image.isNotEmpty, true);
  });
}
