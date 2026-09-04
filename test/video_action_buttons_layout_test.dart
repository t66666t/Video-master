import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/services/batch_import_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/video_action_buttons.dart';

void main() {
  testWidgets('tablet action group stays inside its available top boundary', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1024, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final settings = SettingsService()..resetForTest();
    settings.isActionButtonsCollapsed = false;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<BatchImportService>.value(
            value: BatchImportService(),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomRight,
              child: VideoActionButtons(maxExpandedHeight: 250),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final group = find.byType(VideoActionButtons);
    expect(tester.getSize(group).height, lessThanOrEqualTo(250));
    expect(tester.getSize(group).width, lessThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });
}
