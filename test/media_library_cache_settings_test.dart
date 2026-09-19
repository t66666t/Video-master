import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';
import 'package:video_player_app/widgets/media_library_settings_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('手机按最短边 600dp 使用紧凑缓存操作', () {
    expect(mediaLibraryCacheUsesPhoneLayout(const Size(390, 844)), isTrue);
    expect(mediaLibraryCacheUsesPhoneLayout(const Size(1280, 800)), isFalse);
    expect(
      mediaLibraryCacheActionStyle(compact: true)?.minimumSize?.resolve({}),
      Size.zero,
    );
    expect(mediaLibraryCacheActionStyle(compact: false), isNull);
  });

  testWidgets('紧凑按钮让明细和清除的文字间距更窄', (tester) async {
    Future<({double labelGap, double detailWidth})> metricsFor({
      required bool compact,
    }) async {
      final style = mediaLibraryCacheActionStyle(compact: compact);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  key: const ValueKey('detail'),
                  style: style,
                  onPressed: () {},
                  child: const Text('明细'),
                ),
                TextButton(
                  key: const ValueKey('clear'),
                  style: style,
                  onPressed: () {},
                  child: const Text('清除'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      final detailButton = find.byKey(const ValueKey('detail'));
      final clearButton = find.byKey(const ValueKey('clear'));
      final detailLabel = tester.getRect(
        find.descendant(of: detailButton, matching: find.text('明细')),
      );
      final clearLabel = tester.getRect(
        find.descendant(of: clearButton, matching: find.text('清除')),
      );
      return (
        labelGap: clearLabel.left - detailLabel.right,
        detailWidth: tester.getSize(detailButton).width,
      );
    }

    final phone = await metricsFor(compact: true);
    final desktop = await metricsFor(compact: false);
    expect(phone.labelGap, lessThan(desktop.labelGap));
    expect(phone.detailWidth, lessThan(desktop.detailWidth));
    expect(phone.detailWidth, lessThan(64));
  });

  testWidgets('点击清除后立即在选项内显示进行中，不发全局通知', (tester) async {
    final clear = Completer<void>();
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(390, 844)),
        child: MaterialApp(
          home: Scaffold(
            body: MediaLibraryBilibiliCacheSection(
              inspectCache: () async => const BilibiliStreamCacheReport(),
              clearCache: () => clear.future,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey('bilibili-cache-clear-all-button')),
    );
    await tester.pump();

    expect(find.text('清除中'), findsOneWidget);
    expect(find.text('正在清除...'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.textContaining('已清除'), findsNothing);

    clear.complete();
    await tester.pump();
    expect(find.text('清除中'), findsNothing);
    expect(find.text('正在清除...'), findsNothing);
  });
}
