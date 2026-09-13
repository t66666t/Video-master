import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/utils/playback_page_visibility.dart';
import 'package:video_player_app/widgets/playback_speed_dialog.dart';

void main() {
  testWidgets('speed popup preserves visibility; a full page hides playback', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService()..resetForTest();
    await settings.init();
    final service = MediaPlaybackService();
    final key = GlobalKey<_PlaybackPageState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [AppToast.routeObserver],
        home: _PlaybackPage(key: key, settings: settings),
      ),
    );
    await tester.pumpAndSettle();
    expect(service.hasVisiblePlaybackPageForTest, isTrue);

    await tester.tap(find.text('speed'));
    await tester.pumpAndSettle();
    expect(ModalRoute.of(key.currentContext!)!.isCurrent, isFalse);
    expect(service.hasVisiblePlaybackPageForTest, isTrue);
    await tester.tap(find.text('2.0x').first);
    await tester.pumpAndSettle();
    expect(key.currentState!.speed, 2);
    expect(service.hasVisiblePlaybackPageForTest, isTrue);
    Navigator.of(key.currentContext!).pop();
    await tester.pumpAndSettle();
    expect(service.hasVisiblePlaybackPageForTest, isTrue);

    Navigator.of(key.currentContext!).push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('another page')),
      ),
    );
    await tester.pumpAndSettle();
    expect(service.hasVisiblePlaybackPageForTest, isFalse);
    Navigator.of(key.currentContext!).pop();
    await tester.pumpAndSettle();
    expect(service.hasVisiblePlaybackPageForTest, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(service.hasVisiblePlaybackPageForTest, isFalse);
  });
}

/// Exercises the shared production hook and the same PageRoute observer used
/// by both playback pages, without requiring a native texture or network login.
class _PlaybackPage extends StatefulWidget {
  const _PlaybackPage({super.key, required this.settings});
  final SettingsService settings;
  @override
  State<_PlaybackPage> createState() => _PlaybackPageState();
}

class _PlaybackPageState extends State<_PlaybackPage> with RouteAware {
  bool subscribed = false;
  double speed = 1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!subscribed && route is PageRoute) {
      subscribed = true;
      AppToast.routeObserver.subscribe(this, route);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) registerPlaybackPageIfCurrent(context, this);
    });
  }

  @override
  void didPush() => MediaPlaybackService().setPlaybackPageVisible(this, true);
  @override
  void didPopNext() => didPush();
  @override
  void didPushNext() =>
      MediaPlaybackService().setPlaybackPageVisible(this, false);
  @override
  void didPop() => didPushNext();
  @override
  void dispose() {
    AppToast.routeObserver.unsubscribe(this);
    MediaPlaybackService().setPlaybackPageVisible(this, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () => showPlaybackSpeedDialog(
          context: context,
          initialSpeed: speed,
          settings: widget.settings,
          onSpeedSelected: (value) async => setState(() => speed = value),
        ),
        child: const Text('speed'),
      ),
    ),
  );
}
