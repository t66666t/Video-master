import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/playback_orientation_transition.dart';

void main() {
  test('classifies the real viewport by width and height', () {
    expect(
      PlaybackOrientationTransition.matches(
        const Size(2400, 1080),
        PlaybackViewportOrientation.landscape,
      ),
      isTrue,
    );
    expect(
      PlaybackOrientationTransition.matches(
        const Size(1080, 2400),
        PlaybackViewportOrientation.portrait,
      ),
      isTrue,
    );
    expect(
      PlaybackOrientationTransition.matches(
        Size.zero,
        PlaybackViewportOrientation.portrait,
      ),
      isFalse,
    );
  });

  test('waits for two stable target frames', () async {
    final sizes = <Size>[
      const Size(1080, 2400),
      const Size(2400, 1080),
      const Size(2390, 1080),
      const Size(2400, 1080),
      const Size(2400, 1080),
    ];
    var index = 0;

    final reached = await PlaybackOrientationTransition.waitForViewport(
      readSize: () => sizes[index],
      waitForFrame: () async {
        if (index < sizes.length - 1) index++;
        await Future<void>.delayed(Duration.zero);
      },
      target: PlaybackViewportOrientation.landscape,
      timeout: const Duration(milliseconds: 200),
    );

    expect(reached, isTrue);
    expect(index, sizes.length - 1);
  });

  test('times out when the system refuses the orientation request', () async {
    final reached = await PlaybackOrientationTransition.waitForViewport(
      readSize: () => const Size(1080, 2400),
      waitForFrame: () => Future<void>.delayed(Duration.zero),
      target: PlaybackViewportOrientation.landscape,
      timeout: const Duration(milliseconds: 15),
    );

    expect(reached, isFalse);
  });

  test('waits for system bar metrics to settle after size is stable', () async {
    final signatures = <Object>[
      (const Size(2400, 1080), 0.0),
      (const Size(2400, 1080), 48.0),
      (const Size(2400, 1080), 24.0),
      (const Size(2400, 1080), 24.0),
    ];
    var index = 0;

    final reached = await PlaybackOrientationTransition.waitForViewport(
      readSize: () => const Size(2400, 1080),
      readStabilitySignature: () => signatures[index],
      waitForFrame: () async {
        if (index < signatures.length - 1) index++;
        await Future<void>.delayed(Duration.zero);
      },
      target: PlaybackViewportOrientation.landscape,
      timeout: const Duration(milliseconds: 200),
    );

    expect(reached, isTrue);
    expect(index, signatures.length - 1);
  });
}
