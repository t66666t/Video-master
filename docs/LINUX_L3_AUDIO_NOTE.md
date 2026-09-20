# Linux L3 — Silent host (no sound card)

## Requirement
Hosts without an ALSA/Pulse sound card must still play video. Missing audio
is a **warning**, not a fatal `PlaybackState.error`.

## How silence is ensured
1. **libmpv fallback (before open):** on Linux, set
   `audio-fallback-to-null=yes` via `NativePlayer.setProperty` so AO init can
   fall through to the null audio output instead of aborting the graph.
2. **Error degrade:** `NativeVideoPlayerMediaKit.isRecoverableMissingAudioDeviceError`
   matches messages containing `Could not open/initialize audio device` / `no sound`
   (case-insensitive). The `player.stream.error` listener `debugPrint`s a warning
   and **does not** call `emitPlayerError`, even before the controller is initialized.

Windows / Android audio paths are unchanged (property is Linux-only).

## Verify
```bash
export PATH="/home/box/flutter/bin:$PATH"
cd /workspace/Video-master-src
flutter test test/video_playback_performance_settings_test.dart
```
