import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/desktop_player_sidebar.dart';

void main() {
  for (final left in [false, true]) {
    testWidgets('continuous transitions and retained state, left=$left', (
      tester,
    ) async {
      final subtitleKey = GlobalKey();
      final settingsKey = GlobalKey();
      final playerKey = GlobalKey();
      var layouts = 0;
      Widget host(
        String? id, {
        double width = 200,
        bool resizing = false,
        Size viewport = const Size(800, 600),
      }) {
        final sidebar = DesktopPlayerSidebar(
          key: const ValueKey('sidebar'),
          panelId: id,
          panel: id == 'settings' ? SizedBox(key: settingsKey) : null,
          width: width,
          retainedId: 'subtitles',
          retainedPanel: LayoutBuilder(
            key: subtitleKey,
            builder: (context, constraints) {
              layouts++;
              return const Text('subtitles');
            },
          ),
          retainedWidth: width,
          viewportSize: viewport,
          divider: id == 'subtitles'
              ? const ColoredBox(color: Colors.grey)
              : null,
          dividerWidth: id == 'subtitles' ? 8 : 0,
          onLeft: left,
          resizing: resizing,
        );
        return MaterialApp(
          home: Row(
            children: [
              if (left) sidebar,
              Expanded(
                key: const ValueKey('player'),
                child: SizedBox(key: playerKey),
              ),
              if (!left) sidebar,
            ],
          ),
        );
      }

      double extent() =>
          tester.getSize(find.byType(DesktopPlayerSidebar)).width;
      await tester.pumpWidget(host('subtitles'));
      expect(extent(), 208);
      final subtitleElement = subtitleKey.currentContext;
      final playerElement = playerKey.currentContext;
      await tester.pumpWidget(host(null));
      expect(extent(), 208); // Removing the divider must not jump the width.
      final beforeAnimation = layouts;
      var previous = extent();
      for (var frame = 0; frame < 30; frame++) {
        await tester.pump(const Duration(microseconds: 8333));
        expect(extent(), lessThanOrEqualTo(previous));
        previous = extent();
      }
      expect(extent(), 0);
      expect(layouts, beforeAnimation); // Content is not laid out each frame.
      expect(subtitleKey.currentContext, same(subtitleElement));
      expect(TickerMode.valuesOf(subtitleKey.currentContext!).enabled, isFalse);
      await tester.pumpWidget(host('settings', width: 280));
      await tester.pump(const Duration(milliseconds: 70));
      final interruptedWidth = extent();
      await tester.pumpWidget(host('subtitles'));
      expect(extent(), closeTo(interruptedWidth, 0.001));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pumpWidget(host('settings', width: 280));
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pumpWidget(host('subtitles'));
      await tester.pumpAndSettle();
      expect(extent(), 208);
      expect(settingsKey.currentContext, isNull);
      expect(subtitleKey.currentContext, same(subtitleElement));
      expect(playerKey.currentContext, same(playerElement));
      expect(TickerMode.valuesOf(subtitleKey.currentContext!).enabled, isTrue);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(host('subtitles', width: 250, resizing: true));
      await tester.pump();
      expect(extent(), 258);
      await tester.pumpWidget(
        host('subtitles', width: 300, viewport: const Size(1920, 1080)),
      );
      await tester.pump();
      expect(extent(), 308); // Fullscreen metrics do not start a second tween.
      expect(playerKey.currentContext, same(playerElement));
      expect(subtitleKey.currentContext, same(subtitleElement));
    });
  }
}
