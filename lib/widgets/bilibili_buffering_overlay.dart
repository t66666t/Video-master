import 'package:flutter/material.dart';

import '../services/media_playback_service.dart';

/// Bilibili-inspired buffering overlay: pink spinner + live gateway speed.
/// No mascot / TV icon and no dim over the video — only the loading ring.
class BilibiliBufferingOverlay extends StatelessWidget {
  const BilibiliBufferingOverlay({
    super.key,
    this.forceVisible = false,
  });

  /// Show even when the service has not yet marked the session as buffering.
  final bool forceVisible;

  static const Color bilibiliPink = Color(0xFFFB7299);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: MediaPlaybackService(),
      builder: (context, _) {
        final service = MediaPlaybackService();
        if (!service.isCurrentItemStreamingBilibiliCard) {
          return const SizedBox.shrink();
        }
        final visible =
            forceVisible || service.isBilibiliBufferingOverlayVisible;
        if (!visible) return const SizedBox.shrink();

        final speedLabel = service.bilibiliGatewaySpeedLabel;
        final statusText = service.bilibiliBufferingStatusText;

        return IgnorePointer(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 42,
                  height: 42,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: bilibiliPink,
                    backgroundColor: Colors.white.withValues(alpha: 0.14),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  speedLabel ?? statusText,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.92),
                    fontSize: speedLabel != null ? 15 : 14,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.15,
                    // Readable on a bright frame without a full-screen dim.
                    shadows: const [
                      Shadow(
                        color: Color(0xCC000000),
                        blurRadius: 8,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
