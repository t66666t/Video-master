import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/main.dart';

void main() {
  testWidgets('startup work waits until the lightweight first frame', (
    tester,
  ) async {
    final initialization = Completer<void>();
    var initializationCalls = 0;
    var readyFrameCalls = 0;

    await tester.pumpWidget(
      AppStartupGate(
        initialize: () {
          initializationCalls++;
          return initialization.future;
        },
        onReadyFirstFrame: () => readyFrameCalls++,
        child: const MaterialApp(home: Text('home-ready')),
      ),
    );

    expect(find.byKey(const ValueKey<String>('startup-cover')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('正在准备媒体库…'), findsNothing);
    expect(find.text('home-ready'), findsNothing);
    expect(initializationCalls, 1);
    expect(readyFrameCalls, 0);

    initialization.complete();
    await tester.pump();

    expect(find.text('home-ready'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('startup-cover')), findsNothing);
    expect(initializationCalls, 1);
    expect(readyFrameCalls, 1);
  });

  testWidgets('native-ready startup goes directly to the home first frame', (
    tester,
  ) async {
    var initializationCalls = 0;
    var readyFrameCalls = 0;

    await tester.pumpWidget(
      AppStartupGate(
        initiallyReady: true,
        initialize: () async {
          initializationCalls++;
        },
        onReadyFirstFrame: () => readyFrameCalls++,
        child: const MaterialApp(home: Text('home-first-frame')),
      ),
    );

    expect(find.text('home-first-frame'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('startup-cover')), findsNothing);
    expect(initializationCalls, 0);
    expect(readyFrameCalls, 1);

    await tester.pump();
    expect(readyFrameCalls, 1);
  });
}
