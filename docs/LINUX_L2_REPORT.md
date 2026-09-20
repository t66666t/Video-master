# L2 实现报告 — FFmpeg Kit vs system ffmpeg 双轨

- 工作树：`/workspace/Video-master-src`（基线含 L1 `992aef0`；未 commit）
- 门控：`FFmpegUtils.preferSystemFfmpeg` = Windows \|\| Linux  
  `FFmpegUtils.useDesktopProcessFfmpeg` = Windows \|\| macOS \|\| Linux
- 说明：`docs/LINUX_L2_NOTE.md` + `lib/utils/ffmpeg_utils.dart` 顶部注释

## 改动文件

| 文件 | 作用 |
|------|------|
| `lib/utils/ffmpeg_utils.dart` | 双轨门控、`isAvailable` / `ensureAvailable`、缺二进制用户文案 |
| `lib/utils/subtitle_converter.dart` | Linux/Win → Process |
| `lib/services/transcription_manager.dart` | probe / 提取 / 内嵌软字幕 → CLI |
| `lib/services/video_compose/video_compose_executor.dart` | Linux 走 desktop Process |
| `lib/services/video_compose/video_compose_probe_service.dart` | **仅 Linux** 用系统 ffprobe；Win/mac 仍 Kit |
| `lib/services/ffmpeg_service.dart` | Linux merge → Process |
| `lib/services/bilibili/download_manager.dart` | probe / mux 分流 |
| `lib/services/embedded_subtitle_service.dart` | 探测/提取分流 |
| `lib/services/media_materialization_service.dart` | mux/probe 分流 |
| `lib/services/video_preview_service.dart` | keyframe/帧间隔/抽帧分流 |
| `lib/services/ocr_subtitle_manager.dart` | 预览帧/抽帧分流（powershell 仍仅 Windows） |
| `lib/services/audio_playback_compatibility_service.dart` | codec probe / AAC copy 分流 |
| `lib/services/library_service.dart` | 缩略图 + 封面 → Process；Kit 入口 guard |
| `lib/screens/video_player_screen.dart` | 修复转码 → Process + 可见错误 |
| `test/video_compose_desktop_backend_test.dart` | 允许 Linux ffprobe 路径 |
| `test/ffmpeg_utils_linux_test.dart` | 新测 |
| `docs/LINUX_L2_NOTE.md` | 简短说明 |

已有（未改）：`media_duration_probe` / `media_chapter_probe` 已在 Linux 优先 CLI。

## 分流调用点摘要

- duration / chapter：既有 CLI-first（Linux）
- subtitle convert：`SubtitleConverter`
- transcription / audio prep / embed：`transcription_manager`
- compose execute + Linux probe：`video_compose_*`
- materialization / bilibili / embedded subs / preview / OCR / library thumbs / player repair

Windows/Android Kit 路径保留；Linux 不再调 Kit API（`library` 的 `_executeFfmpegWithTimeout` 直接 return null）。

## 验证

```bash
export PATH="/home/box/flutter/bin:$PATH"
cd /workspace/Video-master-src
flutter test test/ffmpeg_utils_linux_test.dart test/video_compose_desktop_backend_test.dart
# 有 ffmpeg：durationMs > 0（样片 big_buck_bunny.mp4）
# 无 ffmpeg：ensureAvailable / 业务路径抛/展示
#   FFmpegUtils.missingBinaryUserMessage
#   （含「Linux 不使用 FFmpeg Kit」）
```

冷启：`libffmpegkit.so` dlopen 仍可能是 **WARNING**（原生插件注册），Dart 侧不再因 Kit 调用崩；缺包时日志/Toast 用上述文案。

## analyze

对改动文件 `dart analyze`：无 error（既有 warning 与 L2 无关）。
