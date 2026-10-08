import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/widgets/media_library_entry_switcher.dart';

const _labels = ['继续学习', '文件夹', '最近添加', '哔哩哔哩'];

/// Same top bar geometry as the home page below 600 px: a 40 px leading
/// button, 3 px title spacing and four 36 px actions (search, sleep timer,
/// recycle bin, more).
Widget _homeTopBar({
  required MediaLibraryRootEntry selected,
  required ValueChanged<MediaLibraryRootEntry> onSelected,
  bool reorder = true,
  bool compact = true,
}) {
  return MaterialApp(
    home: Scaffold(
      appBar: AppBar(
        toolbarHeight: compact ? 44 : 48,
        leadingWidth: compact ? 40 : 44,
        titleSpacing: compact ? 3 : 8,
        leading: const SizedBox(width: 40),
        title: MediaLibraryEntrySwitcher(
          selected: selected,
          availableEntries: MediaLibraryRootEntry.values.toSet(),
          compact: compact,
          reorderEnabled: reorder,
          onReorder: reorder ? (_, _) {} : null,
          onSelected: onSelected,
        ),
        actions: [
          for (var i = 0; i < 4; i++) const SizedBox(width: 36, height: 44),
        ],
      ),
    ),
  );
}

Future<void> _setWidth(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Rect _viewport(WidgetTester tester) => tester.getRect(
  find
      .descendant(
        of: find.byType(MediaLibraryEntrySwitcher),
        matching: find.byType(Scrollable),
      )
      .first,
);

bool _fullyInside(Rect inner, Rect outer) =>
    inner.left >= outer.left - 0.5 && inner.right <= outer.right + 0.5;

void _expectReadable(WidgetTester tester) {
  for (final label in _labels) {
    // Titles scrolled out of the row are still laid out at full size.
    final text = find.text(label, skipOffstage: false);
    final paragraph = tester.renderObject<RenderParagraph>(text);
    expect(paragraph.didExceedMaxLines, isFalse, reason: label);
    // Rendered size, transforms included: never scaled below ~12 px.
    expect(
      tester.getRect(text).height,
      greaterThanOrEqualTo(12),
      reason: '$label is shrunk',
    );
    final style = tester.widget<Text>(text).style!;
    expect(style.fontSize, greaterThanOrEqualTo(13), reason: label);
  }
}

void main() {
  for (final width in [320.0, 360.0, 412.0]) {
    testWidgets('home tabs at $width px: no overflow, readable, reachable', (
      tester,
    ) async {
      await _setWidth(tester, width);
      var selected = MediaLibraryRootEntry.folders;
      await tester.pumpWidget(
        _homeTopBar(selected: selected, onSelected: (e) => selected = e),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      _expectReadable(tester);
      final viewport = _viewport(tester);
      expect(viewport.right, lessThanOrEqualTo(width - 4 * 36 + 0.5));

      // The row scrolls to the last tab, which is then whole and tappable.
      await tester.drag(find.text('文件夹'), const Offset(-400, 0));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_fullyInside(tester.getRect(find.text('哔哩哔哩')), viewport), isTrue);
      await tester.tap(find.text('哔哩哔哩'));
      await tester.pumpAndSettle();
      expect(selected, MediaLibraryRootEntry.bilibili);

      // Scrolling back shows the first tab whole.
      await tester.drag(find.text('最近添加'), const Offset(400, 0));
      await tester.pumpAndSettle();
      expect(_fullyInside(tester.getRect(find.text('继续学习')), viewport), isTrue);
    });

    testWidgets('home tabs at $width px keep the selected tab in view', (
      tester,
    ) async {
      await _setWidth(tester, width);
      var selected = MediaLibraryRootEntry.continueLearning;
      late StateSetter setOuter;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            setOuter = setState;
            return _homeTopBar(
              selected: selected,
              onSelected: (e) => setState(() => selected = e),
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      final viewport = _viewport(tester);
      expect(_fullyInside(tester.getRect(find.text('继续学习')), viewport), isTrue);

      // Switching from elsewhere (a page swipe) brings the tab into view.
      setOuter(() => selected = MediaLibraryRootEntry.bilibili);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_fullyInside(tester.getRect(find.text('哔哩哔哩')), viewport), isTrue);
    });

    testWidgets('tabs without reordering at $width px are readable too', (
      tester,
    ) async {
      await _setWidth(tester, width);
      await tester.pumpWidget(
        _homeTopBar(
          selected: MediaLibraryRootEntry.folders,
          onSelected: (_) {},
          reorder: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      _expectReadable(tester);
    });
  }

  testWidgets('wide screens keep the fixed row', (tester) async {
    await _setWidth(tester, 1000);
    await tester.pumpWidget(
      _homeTopBar(
        selected: MediaLibraryRootEntry.folders,
        onSelected: (_) {},
        compact: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final scrollable = tester.widget<Scrollable>(
      find
          .descendant(
            of: find.byType(MediaLibraryEntrySwitcher),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(scrollable.physics, isA<NeverScrollableScrollPhysics>());
    final viewport = _viewport(tester);
    for (final label in _labels) {
      expect(_fullyInside(tester.getRect(find.text(label)), viewport), isTrue);
    }
  });
}
