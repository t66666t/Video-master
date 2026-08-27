import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/danmaku_model.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/utils/bilibili_danmaku_ass.dart';
import 'package:video_player_app/utils/danmaku_ass_parser.dart';

void main() {
  test('decodes a deflate-compressed Bilibili XML response', () {
    const xml = '<i><d p="1,1,25,16777215">测试弹幕</d></i>';
    final compressed = zlib.encode(utf8.encode(xml));

    expect(
      decodeBilibiliDanmakuPayload(compressed, contentEncoding: 'deflate'),
      xml,
    );
  });

  test('rejects an unparseable XML that contains danmaku elements', () {
    expect(
      () => BilibiliDanmakuAss.xmlToAss('<i><d>broken</d></i>'),
      throwsFormatException,
    );
  });

  test('converts Bilibili XML to parseable scrolling and fixed danmaku', () {
    const xml = '''
<i>
  <d p="1.25,1,25,16711680,0,0,hash,1">scroll &amp; red</d>
  <d p="2.00,5,25,16777215,0,0,hash,2">top</d>
  <d p="3.00,4,25,16777215,0,0,hash,3">bottom</d>
</i>
''';

    final ass = BilibiliDanmakuAss.xmlToAss(xml);
    final document = DanmakuAssParser.parse(ass);

    expect(document.referenceWidth, 1920);
    expect(document.referenceHeight, 1080);
    expect(document.items, hasLength(3));
    expect(document.items[0].type, DanmakuType.scroll);
    expect(document.items[0].text, 'scroll & red');
    expect(document.items[0].colorValue & 0x00FFFFFF, 0x00FF0000);
    expect(document.items[1].type, DanmakuType.top);
    expect(document.items[2].type, DanmakuType.bottom);
  });

  test('parses moving ASS exported by a Bilibili browser helper', () {
    const ass = r'''
[Script Info]
PlayResX: 1920
PlayResY: 1080
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:06.00,Medium,,0,0,0,,{\move(1935,30,-15,30,0,6000)\c&H1200E7&}测试弹幕
''';

    final document = DanmakuAssParser.parse(ass);

    expect(document.items, hasLength(1));
    expect(document.items.single.type, DanmakuType.scroll);
    expect(document.items.single.sourceY, 30);
    expect(document.items.single.text, '测试弹幕');
  });
}
