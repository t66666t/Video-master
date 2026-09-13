import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/sleep_timer_controller.dart';

class _FakePlayback extends ChangeNotifier {
  bool playing = false;

  void setPlaying(bool value) {
    playing = value;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('wall-clock countdown continues while playback is paused', () async {
    var now = DateTime(2026, 9, 7, 22);
    var expirationCount = 0;
    final playback = _FakePlayback();
    final timer = SleepTimerController(now: () => now);
    await timer.initialize(
      playbackListenable: playback,
      isPlaybackRunning: () => playback.playing,
      onExpired: () async => expirationCount++,
    );

    await timer.scheduleAfter(const Duration(minutes: 30));
    now = now.add(const Duration(minutes: 29));
    timer.checkNow();
    expect(timer.isActive, isTrue);

    now = now.add(const Duration(minutes: 1));
    timer.checkNow();
    await Future<void>.delayed(Duration.zero);
    expect(timer.isActive, isFalse);
    expect(expirationCount, 1);
    timer.dispose();
  });

  test('effective-playback countdown stops while paused', () async {
    var now = DateTime(2026, 9, 7, 22);
    var expirationCount = 0;
    final playback = _FakePlayback()..playing = true;
    final timer = SleepTimerController(now: () => now);
    await timer.initialize(
      playbackListenable: playback,
      isPlaybackRunning: () => playback.playing,
      onExpired: () async => expirationCount++,
    );

    await timer.scheduleAfter(
      const Duration(minutes: 30),
      countOnlyWhilePlaying: true,
    );
    now = now.add(const Duration(minutes: 10));
    playback.setPlaying(false);
    now = now.add(const Duration(hours: 2));
    timer.checkNow();
    expect(timer.remaining, const Duration(minutes: 20));
    expect(expirationCount, 0);

    playback.setPlaying(true);
    now = now.add(const Duration(minutes: 20));
    timer.checkNow();
    await Future<void>.delayed(Duration.zero);
    expect(timer.isActive, isFalse);
    expect(expirationCount, 1);
    timer.dispose();
  });

  test('item and queue completion rules prevent unwanted auto-play', () async {
    final playback = _FakePlayback();
    final timer = SleepTimerController(now: () => DateTime(2026, 9, 7));
    await timer.initialize(
      playbackListenable: playback,
      isPlaybackRunning: () => playback.playing,
      onExpired: () async {},
    );

    await timer.scheduleAtEndOfCurrentItem();
    expect(timer.consumeItemCompletion(hasNextItem: true), isTrue);
    expect(timer.isActive, isFalse);

    await timer.scheduleAtEndOfQueue();
    expect(timer.consumeItemCompletion(hasNextItem: true), isFalse);
    expect(timer.consumeItemCompletion(hasNextItem: false), isTrue);

    await timer.scheduleAfterItems(3);
    expect(timer.consumeItemCompletion(hasNextItem: true), isFalse);
    expect(timer.remainingItemCount, 2);
    expect(timer.consumeItemCompletion(hasNextItem: true), isFalse);
    expect(timer.consumeItemCompletion(hasNextItem: true), isTrue);
    timer.dispose();
  });

  test('absolute countdown survives restart without being extended', () async {
    var now = DateTime(2026, 9, 7, 22);
    final playback = _FakePlayback();
    final first = SleepTimerController(now: () => now);
    await first.initialize(
      playbackListenable: playback,
      isPlaybackRunning: () => playback.playing,
      onExpired: () async {},
    );
    await first.scheduleAfter(const Duration(minutes: 45));
    first.dispose();

    now = now.add(const Duration(minutes: 15));
    final restored = SleepTimerController(now: () => now);
    await restored.initialize(
      playbackListenable: playback,
      isPlaybackRunning: () => playback.playing,
      onExpired: () async {},
    );
    expect(restored.mode, SleepTimerMode.afterDuration);
    expect(restored.remaining, const Duration(minutes: 30));
    restored.dispose();
  });

  test('latest command wins when persistence operations overlap', () async {
    final playback = _FakePlayback();
    final timer = SleepTimerController(now: () => DateTime(2026, 9, 7, 22));
    await timer.initialize(
      playbackListenable: playback,
      isPlaybackRunning: () => playback.playing,
      onExpired: () async {},
    );

    final schedule = timer.scheduleAfter(const Duration(minutes: 30));
    final cancel = timer.cancel();
    await Future.wait([schedule, cancel]);
    final preferences = await SharedPreferences.getInstance();
    expect(timer.isActive, isFalse);
    expect(preferences.containsKey('sleepTimer.mode'), isFalse);
    expect(preferences.containsKey('sleepTimer.deadlineMs'), isFalse);
    timer.dispose();
  });
}
