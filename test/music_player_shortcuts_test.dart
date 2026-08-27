import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/screens/music_player_screen.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const windowManagerChannel = MethodChannel('window_manager');
  final windowManagerCalls = <MethodCall>[];

  setUp(() {
    windowManagerCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowManagerChannel, (call) async {
          windowManagerCalls.add(call);
          if (call.method == 'getBounds') {
            return <String, double>{
              'x': 0,
              'y': 0,
              'width': 1280,
              'height': 720,
            };
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowManagerChannel, null);
  });

  testWidgets('music shortcuts survive focus loss after full screen changes', (
    tester,
  ) async {
    final settings = SettingsService()..resetForTest();
    final mediaPlayback = MediaPlaybackService();
    var playPauseCount = 0;
    final seekRequests = <Duration>[];

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<MediaPlaybackService>.value(
            value: mediaPlayback,
          ),
        ],
        child: MaterialApp(
          home: MusicPlayerScreen(
            onPlayPause: () => playPauseCount++,
            onSeek: seekRequests.add,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pump();

    expect(settings.isFullScreen, isTrue);
    expect(
      windowManagerCalls.any(
        (call) =>
            call.method == 'setFullScreen' &&
            (call.arguments as Map<Object?, Object?>)['isFullScreen'] == true,
      ),
      isTrue,
    );

    // A native full-screen transition can clear Flutter's primary focus.
    // The music player must continue receiving shortcuts just like the video
    // player, even before a user clicks the page again.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pump();

    expect(settings.isFullScreen, isFalse);
    expect(
      windowManagerCalls.any(
        (call) =>
            call.method == 'setFullScreen' &&
            (call.arguments as Map<Object?, Object?>)['isFullScreen'] == false,
      ),
      isTrue,
    );

    final wasMuted = mediaPlayback.isMuted;
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(mediaPlayback.isMuted, !wasMuted);

    // Restore the singleton playback service for other tests.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(mediaPlayback.isMuted, wasMuted);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    expect(playPauseCount, 1);
    expect(seekRequests, hasLength(2));

    final initialVolume = mediaPlayback.volume;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(mediaPlayback.volume, (initialVolume - 0.1).clamp(0.0, 1.0));
    await mediaPlayback.setVolume(initialVolume);

    // Keep the providers mounted for the frame in which MusicPlayerScreen is
    // disposed because the screen detaches its playback listener in dispose().
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<MediaPlaybackService>.value(
            value: mediaPlayback,
          ),
        ],
        child: const SizedBox.shrink(),
      ),
    );
  });
}
