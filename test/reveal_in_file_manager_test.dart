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
}
