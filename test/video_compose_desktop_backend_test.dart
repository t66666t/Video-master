import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('video compose probing never falls back to a desktop PATH link', () {
    final source = File(
      'lib/services/video_compose/video_compose_probe_service.dart',
    ).readAsStringSync();

    expect(source, contains('FFprobeKit.getMediaInformation'));
    expect(source, isNot(contains('FFmpegUtils.ffprobePath')));
    expect(source, isNot(contains('runInShell: true')));
  });

  test('desktop video compose starts the resolved FFmpeg directly', () {
    final executor = File(
      'lib/services/video_compose/video_compose_executor.dart',
    ).readAsStringSync();
    final resolver = File('lib/utils/ffmpeg_utils.dart').readAsStringSync();

    expect(executor, contains('runInShell: false'));
    expect(resolver, contains('Platform.isWindows || Platform.isMacOS'));
    expect(resolver, contains('_resolveDesktopBinaryPath'));
  });
}
