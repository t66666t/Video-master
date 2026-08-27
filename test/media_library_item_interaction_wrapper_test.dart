import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/media_library_item_interaction_wrapper.dart';

void main() {
  testWidgets('桌面端原地按住再松开仍然执行点击而不进入拖拽', (tester) async {
    var taps = 0;
    var dragStarts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 180,
            height: 48,
            child: MediaLibraryItemInteractionWrapper(
              key: const ValueKey('stationary-source'),
              index: 0,
              dragDelay: const Duration(milliseconds: 100),
              isSelected: false,
              selectedCount: 0,
              onDragStarted: () => dragStarts++,
              onReorder: (_, _) {},
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                child: const ColoredBox(color: Colors.black),
              ),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('stationary-source'))),
    );
    await tester.pump(const Duration(milliseconds: 800));
    await gesture.up();
    await tester.pump();

    expect(taps, 1);
    expect(dragStarts, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面端移动超过系统阈值才启动拖拽入口', (tester) async {
    var dragStarts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 180,
            height: 48,
            child: MediaLibraryItemInteractionWrapper(
              key: const ValueKey('source'),
              index: 0,
              dragDelay: const Duration(milliseconds: 100),
              isSelected: false,
              selectedCount: 0,
              onDragStarted: () => dragStarts++,
              onReorder: (_, _) {},
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('source'))),
    );
    await tester.pump(const Duration(milliseconds: 120));
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();

    expect(dragStarts, 1);
    await gesture.up();
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖到普通列表项会按原索引和目标索引排序', (tester) async {
    int? oldIndex;
    int? newIndex;
    await tester.pumpWidget(
      MaterialApp(
        home: Row(
          children: [
            SizedBox(
              width: 120,
              height: 48,
              child: MediaLibraryItemInteractionWrapper(
                key: const ValueKey('reorder-source'),
                index: 0,
                dragDelay: const Duration(milliseconds: 50),
                isSelected: false,
                selectedCount: 0,
                onDragStarted: () {},
                onReorder: (_, _) {},
                child: const ColoredBox(color: Colors.black),
              ),
            ),
            SizedBox(
              width: 120,
              height: 48,
              child: MediaLibraryItemInteractionWrapper(
                key: const ValueKey('reorder-target'),
                index: 1,
                dragDelay: const Duration(milliseconds: 50),
                isSelected: false,
                selectedCount: 0,
                onDragStarted: () {},
                onReorder: (oldValue, newValue) {
                  oldIndex = oldValue;
                  newIndex = newValue;
                },
                child: const ColoredBox(color: Colors.black),
              ),
            ),
          ],
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('reorder-source'))),
    );
    await tester.pump(const Duration(milliseconds: 70));
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('reorder-target'))),
    );
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(oldIndex, 0);
    expect(newIndex, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('在文件夹上持续悬停后会触发移入而不是排序', (tester) async {
    int? movedIndex;
    String? targetFolder;
    await tester.pumpWidget(
      MaterialApp(
        home: Row(
          children: [
            SizedBox(
              width: 120,
              height: 48,
              child: MediaLibraryItemInteractionWrapper(
                key: const ValueKey('folder-source'),
                index: 0,
                dragDelay: const Duration(milliseconds: 50),
                isSelected: true,
                selectedCount: 2,
                onDragStarted: () {},
                onReorder: (_, _) {},
                child: const ColoredBox(color: Colors.black),
              ),
            ),
            SizedBox(
              width: 120,
              height: 48,
              child: MediaLibraryItemInteractionWrapper(
                key: const ValueKey('folder-target'),
                index: 1,
                dragDelay: const Duration(milliseconds: 50),
                isSelected: false,
                selectedCount: 2,
                onDragStarted: () {},
                onReorder: (_, _) {},
                folderId: 'folder-1',
                onMoveToFolder: (oldValue, folderId) {
                  movedIndex = oldValue;
                  targetFolder = folderId;
                },
                child: const ColoredBox(color: Colors.black),
              ),
            ),
          ],
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('folder-source'))),
    );
    await tester.pump(const Duration(milliseconds: 70));
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('folder-target'))),
    );
    await tester.pump(const Duration(milliseconds: 350));
    await gesture.up();
    await tester.pump();

    expect(movedIndex, 0);
    expect(targetFolder, 'folder-1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索结果禁用排序时拖到文件夹会立即触发移入', (tester) async {
    var reorderCount = 0;
    int? movedIndex;
    String? targetFolder;
    await tester.pumpWidget(
      MaterialApp(
        home: Row(
          children: [
            SizedBox(
              width: 120,
              height: 48,
              child: MediaLibraryItemInteractionWrapper(
                key: const ValueKey('search-source'),
                index: 0,
                dragDelay: const Duration(milliseconds: 50),
                isSelected: false,
                selectedCount: 0,
                onDragStarted: () {},
                onReorder: (_, _) => reorderCount++,
                allowReorder: false,
                child: const ColoredBox(color: Colors.black),
              ),
            ),
            SizedBox(
              width: 120,
              height: 48,
              child: MediaLibraryItemInteractionWrapper(
                key: const ValueKey('search-folder-target'),
                index: 1,
                dragDelay: const Duration(milliseconds: 50),
                isSelected: false,
                selectedCount: 0,
                onDragStarted: () {},
                onReorder: (_, _) => reorderCount++,
                allowReorder: false,
                folderId: 'folder-2',
                onMoveToFolder: (oldValue, folderId) {
                  movedIndex = oldValue;
                  targetFolder = folderId;
                },
                child: const ColoredBox(color: Colors.black),
              ),
            ),
          ],
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('search-source'))),
    );
    await tester.pump(const Duration(milliseconds: 70));
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('search-folder-target'))),
    );
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(movedIndex, 0);
    expect(targetFolder, 'folder-2');
    expect(reorderCount, 0);
    expect(tester.takeException(), isNull);
  });
}
