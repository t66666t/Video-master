import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image_lib;
import 'package:video_player_app/services/music_artwork_backdrop_cache.dart';

void main() {
  test('backdrop is blurred off-thread and reused from memory', () async {
    final cache = MusicArtworkBackdropCache.instance..clearForTest();
    final tempDirectory = await Directory.systemTemp.createTemp(
      'music_backdrop_cache_test_',
    );
    addTearDown(() async {
      cache.clearForTest();
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    final source = image_lib.Image(width: 64, height: 64);
    for (var y = 0; y < source.height; y++) {
      for (var x = 0; x < source.width; x++) {
        source.setPixelRgb(x, y, x * 4, y * 4, 180);
      }
    }
    final sourceFile = File(
      '${tempDirectory.path}${Platform.pathSeparator}cover.png',
    );
    await sourceFile.writeAsBytes(image_lib.encodePng(source), flush: true);

    final generated = await cache.warm(sourceFile.path);
    final reused = cache.peek(sourceFile.path);

    expect(generated, isNotNull);
    expect(identical(generated, reused), isTrue);
    final decoded = image_lib.decodeImage(generated!);
    expect(decoded, isNotNull);
    expect(decoded!.width, 144);
    expect(decoded.height, 144);
  });
}
