import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/subtitle_debug_session.dart';
import 'package:video_player_app/widgets/subtitle_debug_speed_gateway.dart';

void main() {
  testWidgets(
    'hidden entry is available without a private release build flag',
    (tester) async {
      expect(SubtitleDebugSession.available, isTrue);
      SharedPreferences.setMockInitialValues({});
      final session = SubtitleDebugSession.instance;
      session.resetForTest();
      await session.initialize();
      addTearDown(session.resetForTest);
      int opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SubtitleDebugSpeedGateway(
              builder: (context, tap) => TextButton(
                onPressed: () => tap(() => opened++),
                child: const Text('倍速'),
              ),
            ),
          ),
        ),
      );
      for (int i = 0; i < 3; i++) {
        await tester.tap(find.text('倍速'));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(session.enabled, isTrue);
      expect(opened, 0);
    },
  );
}
