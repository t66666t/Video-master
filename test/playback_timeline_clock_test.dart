import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/playback_timeline_clock.dart';

void main() {
  test('rate changes alter slope without changing position', () {
    var nowUs = 0;
    final clock = PlaybackTimelineClock(nowMicroseconds: () => nowUs);
    clock.reset(const Duration(seconds: 10), running: true, rate: 1);

    nowUs += 100000;
    expect(clock.position, const Duration(milliseconds: 10100));

    final beforeSpeedUp = clock.position;
    clock.setRate(3);
    expect(clock.position, beforeSpeedUp);
    nowUs += 100000;
    expect(clock.position, const Duration(milliseconds: 10400));

    final beforeSlowDown = clock.position;
    clock.setRate(1);
    expect(clock.position, beforeSlowDown);
    nowUs += 100000;
    expect(clock.position, const Duration(milliseconds: 10500));
  });

  test('pause and resume preserve the same timeline position', () {
    var nowUs = 0;
    final clock = PlaybackTimelineClock(nowMicroseconds: () => nowUs);
    clock.reset(Duration.zero, running: true, rate: 2);
    nowUs += 250000;
    clock.setRunning(false);
    expect(clock.position, const Duration(milliseconds: 500));

    nowUs += 1000000;
    expect(clock.position, const Duration(milliseconds: 500));
    clock.setRunning(true);
    nowUs += 250000;
    expect(clock.position, const Duration(seconds: 1));
  });

  test('explicit reset handles seek without retaining prior interpolation', () {
    var nowUs = 0;
    final clock = PlaybackTimelineClock(nowMicroseconds: () => nowUs);
    clock.reset(Duration.zero, running: true, rate: 1);
    nowUs += 500000;
    clock.reset(const Duration(seconds: 30), running: true, rate: 1);
    expect(clock.position, const Duration(seconds: 30));
  });

  test('a missed display frame samples the full elapsed media time', () {
    var nowUs = 0;
    final clock = PlaybackTimelineClock(nowMicroseconds: () => nowUs);
    clock.reset(Duration.zero, running: true, rate: 1);

    nowUs += 16667;
    expect(clock.position, const Duration(microseconds: 16667));

    // One VSync was missed. The next presented frame must be at the true
    // 50,001 us position, with no delayed catch-up applied to later frames.
    nowUs += 33334;
    expect(clock.position, const Duration(microseconds: 50001));

    nowUs += 16667;
    expect(clock.position, const Duration(microseconds: 66668));
  });

  test('VSync sampling ignores callback execution-time jitter', () {
    var nowUs = 0;
    final clock = PlaybackTimelineClock(nowMicroseconds: () => nowUs);
    clock.reset(
      Duration.zero,
      running: true,
      rate: 1,
      duration: const Duration(minutes: 1),
    );

    expect(clock.sampleFrame(Duration.zero), Duration.zero);
    nowUs = 70000;
    expect(
      clock.sampleFrame(const Duration(microseconds: 16667)),
      const Duration(microseconds: 16667),
    );
    nowUs = 71000;
    expect(
      clock.sampleFrame(const Duration(microseconds: 33334)),
      const Duration(microseconds: 33334),
    );
  });

  test('frame-driven pause and resume never change presented position', () {
    final clock = PlaybackTimelineClock(nowMicroseconds: () => 0);
    clock.reset(
      const Duration(seconds: 10),
      running: true,
      rate: 1,
      duration: const Duration(minutes: 1),
    );

    clock.sampleFrame(Duration.zero);
    final beforePause = clock.sampleFrame(const Duration(microseconds: 16667));
    clock.setRunning(false);
    expect(clock.position, beforePause);
    expect(clock.sampleFrame(const Duration(seconds: 5)), beforePause);

    clock.setRunning(true);
    expect(clock.position, beforePause);
    expect(clock.sampleFrame(const Duration(seconds: 6)), beforePause);
    expect(
      clock.sampleFrame(const Duration(microseconds: 6016667)),
      beforePause + const Duration(microseconds: 16667),
    );
  });

  test('frame-driven rate change changes slope without moving position', () {
    final clock = PlaybackTimelineClock(nowMicroseconds: () => 0);
    clock.reset(
      Duration.zero,
      running: true,
      rate: 1,
      duration: const Duration(minutes: 1),
    );

    clock.sampleFrame(Duration.zero);
    clock.sampleFrame(const Duration(milliseconds: 10));
    final beforeRateChange = clock.position;
    clock.setRate(2);
    expect(clock.position, beforeRateChange);
    expect(
      clock.sampleFrame(const Duration(milliseconds: 20)),
      beforeRateChange + const Duration(milliseconds: 20),
    );
  });

  test('successive native rate changes keep overlay time continuous', () {
    final clock = PlaybackTimelineClock(nowMicroseconds: () => 0);
    clock.reset(
      const Duration(seconds: 8),
      running: true,
      rate: 1,
      duration: const Duration(minutes: 1),
    );
    clock.sampleFrame(Duration.zero);

    const rates = <double>[1.08, 1.28, 1.5, 1.72, 1.92, 2.0];
    var frameTime = Duration.zero;
    var previousPosition = clock.position;
    for (final rate in rates) {
      final beforeRateChange = clock.position;
      clock.setRate(rate);
      expect(clock.position, beforeRateChange);

      frameTime += const Duration(milliseconds: 16);
      final nextPosition = clock.sampleFrame(frameTime);
      final advanceUs = (nextPosition - previousPosition).inMicroseconds;
      expect(advanceUs, closeTo((16000 * rate).round(), 1));
      expect(nextPosition, greaterThan(previousPosition));
      previousPosition = nextPosition;
    }
  });

  test('native drift samples adjust slope without moving current position', () {
    final clock = PlaybackTimelineClock(nowMicroseconds: () => 0);
    clock.reset(
      Duration.zero,
      running: true,
      rate: 1,
      duration: const Duration(minutes: 1),
    );
    clock.sampleFrame(Duration.zero);
    clock.sampleFrame(const Duration(milliseconds: 10));

    for (var i = 0; i < 7; i++) {
      final beforeSample = clock.position;
      clock.observeNativePosition(
        beforeSample + const Duration(milliseconds: 20),
      );
      expect(clock.position, beforeSample);
    }

    final beforeFrame = clock.position;
    final afterFrame = clock.sampleFrame(const Duration(milliseconds: 20));
    final advanceUs = (afterFrame - beforeFrame).inMicroseconds;
    expect(advanceUs, greaterThanOrEqualTo(10000));
    expect(advanceUs, lessThanOrEqualTo(10050));
  });

  test('large native mismatch is never converted into a visible jump', () {
    final clock = PlaybackTimelineClock(nowMicroseconds: () => 0);
    clock.reset(
      const Duration(seconds: 5),
      running: true,
      rate: 1,
      duration: const Duration(minutes: 1),
    );
    clock.sampleFrame(Duration.zero);
    clock.sampleFrame(const Duration(milliseconds: 10));
    final before = clock.position;
    for (var i = 0; i < 8; i++) {
      clock.observeNativePosition(const Duration(seconds: 20));
    }
    expect(clock.position, before);
  });
}
