import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/playback_navigation_service.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every platform uses the full-page zoom transition', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(pageTransitionsTheme: appPageTransitionsTheme),
        home: const Scaffold(body: Text('home')),
      ),
    );
    final builders = Theme.of(
      tester.element(find.text('home')),
    ).pageTransitionsTheme.builders;
    for (final platform in TargetPlatform.values) {
      expect(
        builders[platform],
        isA<ZoomPageTransitionsBuilder>(),
        reason: platform.name,
      );
    }
  });

  testWidgets('a material push zooms in and then settles', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.iOS,
          pageTransitionsTheme: appPageTransitionsTheme,
        ),
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const Scaffold(
                        body: Text('next-page', key: Key('next-page')),
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();

    final next = find.byKey(const Key('next-page'), skipOffstage: false);
    final route = ModalRoute.of(tester.element(next))!;
    expect(route.transitionDuration, const Duration(milliseconds: 300));
    expect(route.animation!.status, AnimationStatus.forward);

    await tester.pump(const Duration(milliseconds: 400));
    expect(route.animation!.status, AnimationStatus.completed);
    expect(find.text('next-page'), findsOneWidget);
  });

  test('playback routes zoom without snapshotting the video page', () {
    final route = PlaybackNavigationService.buildPlaybackPageRoute<void>(
      builder: (_) => const SizedBox(),
    );
    expect(route.allowSnapshotting, isFalse);

    final folder = AppMaterialPageRoute<void>(builder: (_) => const SizedBox());
    expect(folder.allowSnapshotting, isTrue);
  });
}
