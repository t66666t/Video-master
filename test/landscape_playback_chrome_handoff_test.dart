import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/screens/video_player_screen.dart';

void main() {
  test('hidden portrait overlay keeps landscape chrome hidden', () {
    expect(
      landscapePlaybackChromeFromPortrait(
        overlayControlsVisible: false,
        lastIntent: true,
      ),
      isFalse,
    );
  });

  test('visible portrait overlay keeps landscape chrome visible', () {
    expect(
      landscapePlaybackChromeFromPortrait(
        overlayControlsVisible: true,
        lastIntent: false,
      ),
      isTrue,
    );
  });

  test('unmounted overlay falls back to the last chrome intent', () {
    expect(
      landscapePlaybackChromeFromPortrait(
        overlayControlsVisible: null,
        lastIntent: false,
      ),
      isFalse,
    );
    expect(
      landscapePlaybackChromeFromPortrait(
        overlayControlsVisible: null,
        lastIntent: true,
      ),
      isTrue,
    );
  });

  test('landscape screen stores the handed-off chrome intent', () {
    const hidden = VideoPlayerScreen(initialShowControls: false);
    const shown = VideoPlayerScreen();
    expect(hidden.initialShowControls, isFalse);
    expect(shown.initialShowControls, isTrue);
  });
}
