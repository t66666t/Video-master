# Linux L2 — FFmpeg Kit vs system ffmpeg

Linux **disables FFmpeg Kit** at call sites (`FFmpegUtils.preferSystemFfmpeg`).
The plugin may still emit a non-fatal `dlopen(libffmpegkit.so)` warning at
startup; Dart code must not invoke Kit APIs on Linux.

Use system `ffmpeg` / `ffprobe` on PATH (or resolve via `FFmpegUtils`).
If missing, users see: `FFmpegUtils.missingBinaryUserMessage`.

See `lib/utils/ffmpeg_utils.dart` for the dual-track gate.
