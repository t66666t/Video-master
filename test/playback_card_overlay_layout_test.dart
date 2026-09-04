import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/playback_card_layout.dart';

void main() {
  group('PlaybackCardOverlayLayout', () {
    test('keeps the bottom inset when immersive mode reports zero', () {
      final normal = PlaybackCardOverlayLayout.resolveStableBottomInset(
        const MediaQueryData(
          viewPadding: EdgeInsets.only(bottom: 24),
          padding: EdgeInsets.only(bottom: 24),
          systemGestureInsets: EdgeInsets.only(bottom: 16),
        ),
        0,
      );
      final immersive = PlaybackCardOverlayLayout.resolveStableBottomInset(
        const MediaQueryData(),
        normal,
      );

      expect(normal, 24);
      expect(immersive, 24);
    });

    test('uses gesture inset when view padding is temporarily unavailable', () {
      final inset = PlaybackCardOverlayLayout.resolveStableBottomInset(
        const MediaQueryData(systemGestureInsets: EdgeInsets.only(bottom: 18)),
        0,
      );

      expect(inset, 18);
    });

    test('keeps action toggle at a fixed gap above the mini player', () {
      const stableInset = 24.0;
      const cardHeight = 124.0;
      final cardBottom = PlaybackCardOverlayLayout.cardBottom(stableInset);
      final actionBottom = PlaybackCardOverlayLayout.actionButtonsBottom(
        stableBottomInset: stableInset,
        cardHeight: cardHeight,
        isCardVisible: true,
      );

      expect(
        actionBottom - (cardBottom + cardHeight),
        PlaybackCardOverlayLayout.actionButtonsGap,
      );
    });

    test('custom FAB location anchors to the physical bottom-right', () {
      const geometry = ScaffoldPrelayoutGeometry(
        bottomSheetSize: Size.zero,
        contentBottom: 800,
        contentTop: 80,
        floatingActionButtonSize: Size(56, 400),
        minInsets: EdgeInsets.zero,
        scaffoldSize: Size(400, 800),
        snackBarSize: Size.zero,
        materialBannerSize: Size.zero,
        textDirection: TextDirection.ltr,
        minViewPadding: EdgeInsets.zero,
      );

      expect(
        const PlaybackActionButtonsLocation().getOffset(geometry),
        const Offset(328, 400),
      );
    });
  });
}
