import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:video_player_app/models/subtitle_debug_preset.dart';
import 'package:video_player_app/models/video_compose_models.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/subtitle_debug_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'mode, hidden entry and per-preset edits survive a fresh session',
    () async {
      final a = SubtitleDebugSession();
      await a.initialize();
      await a.toggle();
      await a.select(subtitleDebugPresets[36]);
      final edited = a.preset!.copyWith(
        textScale: 1.4,
        box: .73,
        color: Colors.amber,
        secondaryColor: Colors.cyan,
        shadowBlur: 4,
        shadowOffset: const Offset(2, 3),
        outline: 4,
      );
      await a.updatePreset(edited);
      final b = SubtitleDebugSession();
      await b.initialize();
      expect(b.enabled, isTrue);
      expect(b.catalogVisible, isTrue);
      expect(b.preset!.toJson(), edited.toJson());
      expect(b.resolved(subtitleDebugPresets[0].id).textScale, 1);
      await b.useOriginal();
      final c = SubtitleDebugSession();
      await c.initialize();
      expect(c.enabled, isTrue);
      expect(c.catalogVisible, isFalse);
      expect(c.preset, isNull);
      await c.openCatalog();
      await c.select(subtitleDebugPresets[36]);
      expect(c.preset!.textScale, 1.4);
      await c.close();
      final d = SubtitleDebugSession();
      await d.initialize();
      expect(d.enabled, isFalse);
      await d.toggle();
      expect(d.preset!.toJson(), edited.toJson());
      await d.resetPreset(edited.id);
      expect(d.preset!.toJson(), subtitleDebugPresets[36].toJson());
      for (final s in [a, b, c, d]) {
        s.dispose();
      }
    },
  );
  test(
    'rapid writes finish in order and preserve the last slider value',
    () async {
      final s = SubtitleDebugSession();
      await s.initialize();
      await s.toggle();
      await s.select(subtitleDebugPresets.first);
      for (int i = 0; i < 40; i++) {
        s.updatePreset(s.preset!.copyWith(textScale: 1 + i / 100));
      }
      await s.flush();
      final reloaded = SubtitleDebugSession();
      await reloaded.initialize();
      expect(reloaded.preset!.textScale, closeTo(1.39, .000001));
      s.dispose();
      reloaded.dispose();
    },
  );
  test(
    'all presets retain ratio and immutable background geometry after tweaks',
    () {
      for (final p in subtitleDebugPresets) {
        final changed = p.copyWith(
          textScale: 1.5,
          box: .8,
          backgroundColor: Colors.blue,
        );
        final restored = SubtitleDebugPreset.restore(changed.toJson())!;
        expect(restored.toJson(), changed.toJson());
        expect(restored.backgroundPadding, p.backgroundPadding);
        expect(
          restored.styleFor(secondary: true).fontSize /
              restored.styleFor().fontSize,
          closeTo(p.ratio, .0001),
        );
        expect(
          restored.styleFor().backgroundColor.toARGB32(),
          Colors.blue.toARGB32(),
        );
      }
    },
  );
  test(
    'damaged preferences safely fall back, and invalid values are clamped',
    () async {
      SharedPreferences.setMockInitialValues({
        SubtitleDebugSession.storageKey: '{broken',
      });
      final s = SubtitleDebugSession();
      await s.initialize();
      expect(s.enabled, isFalse);
      final raw = subtitleDebugPresets.first.toJson()
        ..['textScale'] = 90
        ..['box'] = -1;
      final p = SubtitleDebugPreset.restore(raw)!;
      expect(p.textScale, 1.8);
      expect(p.box, 0);
      expect(SubtitleDebugPreset.restore({'id': 'missing'}), isNull);
      s.dispose();
    },
  );
  test(
    'queue serialization and materialization keep the exact preset snapshot',
    () {
      final preset = subtitleDebugPresets[18].copyWith(textScale: 1.3, box: .4);
      final request = VideoComposeRequest(
        videoId: 'v',
        videoPath: 'input.mp4',
        title: 'sample',
        renderSecondarySubtitle: true,
        continuousSubtitle: false,
        embedSoftSubtitles: false,
        softSubtitleOnly: false,
        softSubtitleUseSourceQuality: true,
        softSubtitleTracks: const [],
        resolution: VideoComposeResolution.p720,
        subtitleStyle: const SubtitleStyle(),
        subtitleAlignment: Alignment.bottomCenter,
        subtitlePreset: preset,
        outputPath: 'output.mp4',
      );
      final restored = VideoComposeRequest.fromJson(
        request.toJson(),
      ).copyWith(videoPath: 'local.mp4');
      expect(restored.subtitlePreset!.toJson(), preset.toJson());
      final legacy = request.toJson()..remove('subtitlePreset');
      expect(VideoComposeRequest.fromJson(legacy).subtitlePreset, isNull);
    },
  );
}
