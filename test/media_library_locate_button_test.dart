import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/widgets/media_library_list_tile.dart';
import 'package:video_player_app/widgets/media_library_locate_button.dart';

void main() {
  testWidgets('定位按钮的图标按照卡片宽度等比例缩放', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Row(
          children: [
            MediaLibraryLocateButton(
              key: const ValueKey('small-locate'),
              cardWidth: 100,
              onPressed: () {},
            ),
            MediaLibraryLocateButton(
              key: const ValueKey('large-locate'),
              cardWidth: 200,
              onPressed: () {},
            ),
          ],
        ),
      ),
    );

    final icons = tester
        .widgetList<Icon>(find.byIcon(Icons.folder_open_rounded))
        .toList();
    expect(icons, hasLength(2));
    expect(icons[1].size, closeTo(icons[0].size! * 2, 0.01));

    final smallSurface = find.descendant(
      of: find.byKey(const ValueKey('small-locate')),
      matching: find.byKey(
        const ValueKey('show-in-parent-folder-button-surface'),
      ),
    );
    final largeSurface = find.descendant(
      of: find.byKey(const ValueKey('large-locate')),
      matching: find.byKey(
        const ValueKey('show-in-parent-folder-button-surface'),
      ),
    );
    expect(tester.getSize(smallSurface).height, closeTo(19, 0.01));
    expect(
      tester.getSize(largeSurface).height,
      closeTo(tester.getSize(smallSurface).height * 2, 0.01),
    );
  });

  testWidgets('点击定位按钮不会穿透并触发媒体卡片播放', (tester) async {
    var cardTapCount = 0;
    var locateTapCount = 0;
    final item = VideoItem(
      id: 'video-1',
      path: 'video.mp4',
      title: '测试媒体',
      durationMs: 60000,
      lastUpdated: 0,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<MediaPlaybackService>.value(
        value: MediaPlaybackService(),
        child: MaterialApp(
          home: Center(
            child: SizedBox(
              width: 420,
              height: 64,
              child: MediaLibraryListTile.video(
                item: item,
                index: 0,
                showIndex: false,
                showThumbnail: false,
                isSelected: false,
                isSelectionMode: false,
                titleScale: 0.065,
                onTap: () => cardTapCount++,
                onShowInParentFolder: () => locateTapCount++,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('show-in-parent-folder-button')),
    );
    await tester.pump();
    expect(locateTapCount, 1);
    expect(cardTapCount, 0);

    await tester.tap(find.text('测试媒体'));
    await tester.pump();
    expect(cardTapCount, 1);
  });

  testWidgets('列表定位按钮贴合右下角且不会挤窄标题', (tester) async {
    final item = VideoItem(
      id: 'video-2',
      path: 'video-2.mp4',
      title: '定位按钮不会挤压标题显示宽度',
      durationMs: 60000,
      lastUpdated: 0,
    );

    Widget buildTile({required bool showLocateButton}) {
      return SizedBox(
        width: 420,
        height: 64,
        child: MediaLibraryListTile.video(
          item: item,
          index: 0,
          showIndex: false,
          showThumbnail: false,
          isSelected: false,
          isSelectionMode: false,
          titleScale: 0.065,
          onTap: () {},
          onShowInParentFolder: showLocateButton ? () {} : null,
        ),
      );
    }

    await tester.pumpWidget(
      ChangeNotifierProvider<MediaPlaybackService>.value(
        value: MediaPlaybackService(),
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                KeyedSubtree(
                  key: const ValueKey('plain-list-tile'),
                  child: buildTile(showLocateButton: false),
                ),
                KeyedSubtree(
                  key: const ValueKey('located-list-tile'),
                  child: buildTile(showLocateButton: true),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final plainTitle = find.descendant(
      of: find.byKey(const ValueKey('plain-list-tile')),
      matching: find.byKey(const ValueKey('media-list-title')),
    );
    final locatedTitle = find.descendant(
      of: find.byKey(const ValueKey('located-list-tile')),
      matching: find.byKey(const ValueKey('media-list-title')),
    );
    expect(
      tester.getSize(locatedTitle).width,
      greaterThanOrEqualTo(tester.getSize(plainTitle).width),
    );

    final surface = find.byKey(
      const ValueKey('show-in-parent-folder-button-surface'),
    );
    final locatedCard = find.descendant(
      of: find.byKey(const ValueKey('located-list-tile')),
      matching: find.byKey(const ValueKey('media-list-card')),
    );
    final surfaceRect = tester.getRect(surface);
    final cardRect = tester.getRect(locatedCard);
    final locatedTitleRect = tester.getRect(locatedTitle);
    expect(surfaceRect.right, closeTo(cardRect.right, 0.001));
    expect(surfaceRect.bottom, closeTo(cardRect.bottom, 0.001));
    expect(surfaceRect.top, greaterThanOrEqualTo(locatedTitleRect.bottom));
    expect(surfaceRect.width, greaterThan(50));
    expect(surfaceRect.height, greaterThan(28));
    expect(tester.takeException(), isNull);
  });
}
