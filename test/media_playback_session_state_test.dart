import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';

SubtitleItem _subtitle(String text) {
  return SubtitleItem(
    index: 0,
    startTime: Duration.zero,
    endTime: const Duration(seconds: 1),
    text: text,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'subtitle snapshots are immutable and revision detects same-size edits',
    () {
      final service = MediaPlaybackService();
      service.clearSubtitleState();
      final initialRevision = service.subtitleRevision;
      final source = <SubtitleItem>[_subtitle('before')];

      service.setSubtitleState(
        paths: const <String>['primary.srt'],
        primary: source,
        secondary: const <SubtitleItem>[],
      );
      final firstRevision = service.subtitleRevision;
      expect(firstRevision, greaterThan(initialRevision));
      expect(service.subtitles.single.text, 'before');

      source[0] = _subtitle('mutated outside service');
      expect(service.subtitles.single.text, 'before');
      expect(
        () => service.subtitles.add(_subtitle('not allowed')),
        throwsUnsupportedError,
      );

      service.setSubtitleState(
        paths: const <String>['primary.srt'],
        primary: <SubtitleItem>[_subtitle('after')],
        secondary: const <SubtitleItem>[],
      );
      expect(service.subtitleRevision, greaterThan(firstRevision));
      expect(service.subtitles.single.text, 'after');
    },
  );

  test('subtitle load commits only for the active media item', () async {
    final service = MediaPlaybackService();
    service.clearSubtitleState();
    await service.updateMetadata(
      VideoItem(
        id: 'active',
        path: 'active.mp4',
        title: 'Active',
        durationMs: 0,
        lastUpdated: 0,
      ),
    );
    final revisionBeforeRejectedLoad = service.subtitleRevision;

    final rejected = await service.loadSubtitlePathsForCurrentItem(
      itemId: 'stale',
      paths: const <String>[],
    );
    expect(rejected, isFalse);
    expect(service.subtitleRevision, revisionBeforeRejectedLoad);

    final committed = await service.loadSubtitlePathsForCurrentItem(
      itemId: 'active',
      paths: const <String>[],
    );
    expect(committed, isTrue);
    expect(service.subtitleRevision, greaterThan(revisionBeforeRejectedLoad));
  });
}
