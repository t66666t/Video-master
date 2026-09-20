import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_root_surface_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('root host keeps visited surfaces and does not build the rest', (
    tester,
  ) async {
    final inits = <String, int>{};
    var displayed = MediaLibraryRootEntry.continueLearning;

    Widget host() {
      return MediaLibraryRootSurfaceHost(
        displayedEntry: displayed,
        continueBuilder: (_, _) => _InitProbe(id: 'continue', inits: inits),
        recentBuilder: (_, _) => _InitProbe(id: 'recent', inits: inits),
        foldersBuilder: (_, _) => _InitProbe(id: 'folders', inits: inits),
      );
    }

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: host())));
    await tester.pump();

    expect(inits['continue'], 1);
    expect(inits['recent'], isNull);
    expect(inits['folders'], isNull);

    displayed = MediaLibraryRootEntry.recent;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: host())));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(inits['continue'], 1);
    expect(inits['recent'], 1);
    expect(inits['folders'], isNull);

    displayed = MediaLibraryRootEntry.continueLearning;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: host())));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(inits['continue'], 1);
    expect(inits['recent'], 1);
    expect(inits['folders'], isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden surfaces are not rebuilt on later parent ticks', (
    tester,
  ) async {
    var continueBuilds = 0;
    var recentBuilds = 0;
    var displayed = MediaLibraryRootEntry.continueLearning;
    var tick = 0;

    Widget host() {
      return MediaLibraryRootSurfaceHost(
        displayedEntry: displayed,
        continueBuilder: (_, _) {
          continueBuilds++;
          return Text('c$tick');
        },
        recentBuilder: (_, _) {
          recentBuilds++;
          return Text('r$tick');
        },
        foldersBuilder: (_, _) => const SizedBox.shrink(),
      );
    }

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: host())));
    await tester.pump();
    expect(continueBuilds, 1);
    expect(recentBuilds, 0);

    displayed = MediaLibraryRootEntry.recent;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: host())));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(recentBuilds, greaterThanOrEqualTo(1));
    final continueAfterSwitch = continueBuilds;

    tick = 1;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: host())));
    await tester.pump();
    expect(continueBuilds, continueAfterSwitch);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inactive freeze ignores replacement children', (tester) async {
    var builds = 0;
    var active = true;
    var generation = 0;

    Widget tree() {
      return MediaLibraryFrozenWhenInactive(
        active: active,
        child: _BuildProbe(
          generation: generation,
          onBuild: () => builds++,
        ),
      );
    }

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: tree())));
    await tester.pump();
    expect(builds, 1);

    generation = 1;
    active = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: tree())));
    await tester.pump();
    expect(builds, 1);

    generation = 2;
    active = true;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: tree())));
    await tester.pump();
    expect(builds, 2);
  });

  test('saveMediaLibraryRootChoice notifies once and skips anchor notify', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();

    var notifications = 0;
    settings.addListener(() => notifications++);

    await settings.saveMediaLibraryRootChoice('recent');
    expect(notifications, 1);
    expect(settings.mediaLibraryRootEntry, 'recent');
    expect(settings.mediaLibraryRootEntryUserChosen, isTrue);

    await settings.saveMediaLibraryEntryAnchors('{"recent":{"offset":12}}');
    expect(notifications, 1);
    expect(settings.mediaLibraryEntryAnchors, '{"recent":{"offset":12}}');

    await settings.saveMediaLibraryRootChoice('folders', notify: false);
    expect(notifications, 1);
    expect(settings.mediaLibraryRootEntry, 'folders');
  });

  testWidgets('touch fling opens the next tab, mouse drag does not', (
    tester,
  ) async {
    var displayed = MediaLibraryRootEntry.continueLearning;
    MediaLibraryRootEntry? swiped;

    Widget host() {
      return MediaLibraryRootSurfaceHost(
        displayedEntry: displayed,
        onUserSwipe: (entry) {
          swiped = entry;
          displayed = entry;
        },
        continueBuilder: (_, _) => const Center(child: Text('continue')),
        recentBuilder: (_, _) => const Center(child: Text('recent')),
        foldersBuilder: (_, _) => const Center(child: Text('folders')),
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 400, height: 640, child: host()),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('continue'), findsOneWidget);

    final origin = tester.getCenter(find.text('continue'));
    final mouse = await tester.startGesture(
      origin,
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(-220, 0));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(swiped, isNull);
    expect(find.text('recent'), findsNothing);

    await tester.fling(find.text('continue'), const Offset(-240, 0), 1800);
    await tester.pumpAndSettle();
    expect(swiped, MediaLibraryRootEntry.folders);
  });

  testWidgets('a reverse fling during snap is not dropped', (tester) async {
    var displayed = MediaLibraryRootEntry.continueLearning;
    final swiped = <MediaLibraryRootEntry>[];

    Widget host() {
      return MediaLibraryRootSurfaceHost(
        displayedEntry: displayed,
        onUserSwipe: (entry) {
          swiped.add(entry);
          displayed = entry;
        },
        continueBuilder: (_, _) => const Center(child: Text('continue')),
        recentBuilder: (_, _) => const Center(child: Text('recent')),
        foldersBuilder: (_, _) => const Center(child: Text('folders')),
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 400, height: 640, child: host()),
        ),
      ),
    );
    await tester.pump();

    await tester.fling(
      find.byType(MediaLibraryRootSurfaceHost),
      const Offset(-240, 0),
      1800,
    );
    await tester.pump(const Duration(milliseconds: 40));
    await tester.fling(
      find.byType(MediaLibraryRootSurfaceHost),
      const Offset(240, 0),
      1800,
    );
    await tester.pumpAndSettle();
    expect(swiped, isNotEmpty);
    expect(displayed, MediaLibraryRootEntry.continueLearning);
  });

  testWidgets('touch drag publishes a fractional chip highlight', (
    tester,
  ) async {
    final highlight = ValueNotifier<double>(0);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 640,
            child: MediaLibraryRootSurfaceHost(
              displayedEntry: MediaLibraryRootEntry.continueLearning,
              swipeHighlightIndex: highlight,
              continueBuilder: (_, _) => const Center(child: Text('continue')),
              recentBuilder: (_, _) => const Center(child: Text('recent')),
              foldersBuilder: (_, _) => const Center(child: Text('folders')),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final origin = tester.getCenter(find.text('continue'));
    final gesture = await tester.startGesture(
      origin,
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(-160, 0));
    await tester.pump();
    expect(highlight.value, closeTo(0.4, 0.08));
    expect(find.text('folders'), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();
  });
}

class _InitProbe extends StatefulWidget {
  const _InitProbe({required this.id, required this.inits});

  final String id;
  final Map<String, int> inits;

  @override
  State<_InitProbe> createState() => _InitProbeState();
}

class _InitProbeState extends State<_InitProbe> {
  @override
  void initState() {
    super.initState();
    widget.inits[widget.id] = (widget.inits[widget.id] ?? 0) + 1;
  }

  @override
  Widget build(BuildContext context) {
    return Text(widget.id);
  }
}

class _BuildProbe extends StatelessWidget {
  const _BuildProbe({required this.generation, required this.onBuild});

  final int generation;
  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild();
    return Text('g$generation');
  }
}
