import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/reveal_in_file_manager.dart';

void main() {
  test(
    'Windows explorer /select keeps the switch and path as two arguments',
    () {
      final List<String> args = windowsExplorerSelectArguments(
        r'C:\Users\My Name\Downloads\movie.en.srt',
      );
      expect(args, hasLength(2));
      expect(args.first, '/select,');
      expect(args.last, isNot(startsWith('/select,')));
      expect(args.last, contains(r'My Name'));
      expect(args.last, isNot(contains('/')));
    },
  );

  test(
    'Windows explorer /select does not swallow a comma inside the file name',
    () {
      final List<String> args = windowsExplorerSelectArguments(
        r'C:\subs\title, part 1.srt',
      );
      expect(args.first, '/select,');
      expect(args.last, endsWith(r'title, part 1.srt'));
    },
  );

  test('Linux FileManager URI percent-encodes spaces', () {
    final String uri = linuxFileManagerItemUri('/home/user/My Videos/clip.mp4');
    expect(uri, startsWith('file://'));
    expect(uri, contains('My%20Videos'));
    expect(uri, isNot(contains(' ')));
  });

  test('Linux dbus ShowItems args keep URI as one array:string token', () {
    final String uri = linuxFileManagerItemUri('/tmp/a b,c.mp4');
    final List<String> args = linuxDbusShowItemsArguments(uri);
    expect(args, contains('org.freedesktop.FileManager1.ShowItems'));
    final String arrayArg = args.firstWhere(
      (a) => a.startsWith('array:string:'),
    );
    // Comma in the path must not create a second array element.
    expect(arrayArg.split(',').length, 1);
    expect(arrayArg, contains('%2C'));
    expect(args.last, 'string:');
  });

  test('reveal fallback directory prefers parent of an existing file', () {
    expect(
      revealFallbackDirectoryPath(
        normalizedPath: '/videos/en/clip.mp4',
        fileExists: true,
        directoryExists: false,
      ),
      '/videos/en',
    );
    expect(
      revealFallbackDirectoryPath(
        normalizedPath: '/videos/en',
        fileExists: false,
        directoryExists: true,
      ),
      '/videos/en',
    );
    expect(
      revealFallbackDirectoryPath(
        normalizedPath: '/videos/en/missing.mp4',
        fileExists: false,
        directoryExists: false,
      ),
      '/videos/en',
    );
  });
}
