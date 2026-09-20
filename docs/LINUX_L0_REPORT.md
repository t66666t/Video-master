# L0 复现报告（Linux）

- 源码：`/workspace/Video-master-src` @ `d824719`（Plan 提交 d824719；功能基线 5f49c14）
- 运行：`/workspace/Video-master-test/app/linux/bundle/video_player_app`（上一轮 release 产物，用于症状复现）
- 日志：`L0_repro_rerun.log`
- analyze：`L0_analyze.txt`

## 结论

| 现象 | 复现 |
|------|------|
| MissingPlatformDirectoryException | 是 |
| LibraryService / BatchImport / Bilibili 等 init failed | 是 |
| libffmpegkit.so dlopen 失败 | 是 |
| 窗口能起来（进程存活） | 是 |
| ALSA 无声卡 | 环境噪声 |

## 关键摘录

```
7:** (com.example.video_player_app:1209606): WARNING **: 06:57:18.829: ffmpeg_kit: dlopen(libffmpegkit.so) failed: libffmpegkit.so: cannot open shared object file: No such file or directory
19:[ERROR:flutter/runtime/dart_vm_initializer.cc(40)] Unhandled Exception: MissingPlatformDirectoryException(Unable to get application documents directory)
27:Failed to load compose tasks: MissingPlatformDirectoryException(Unable to get application documents directory)
29:LibraryService init failed: MissingPlatformDirectoryException(Unable to get application documents directory)
30:BatchImportService init failed: MissingPlatformDirectoryException(Unable to get application documents directory)
31:BilibiliDownloadService init failed: MissingPlatformDirectoryException(Unable to get application documents directory)
32:B站登录状态检查失败: MissingPlatformDirectoryException(Unable to get application documents directory)
33:剪贴板检查失败: MissingPlatformDirectoryException(Unable to get application documents directory)
35:OCR stale temporary cleanup failed: MissingPlatformDirectoryException(Unable to get application documents directory)
36:初始化持久化目录失败: MissingPlatformDirectoryException(Unable to get application documents directory)
37:恢复 yt-dlp 任务缩略图失败: MissingPlatformDirectoryException(Unable to get application documents directory)
```

## L0 验收

- [x] 两则阻塞可复现并落盘
- [x] analyze 已跑（见 L0_analyze.txt；本阶段不要求清零）
- [ ] linux release 重建：交给 L1 合并后做（本轮用既有 bundle 复现症状即可对照）

L1（数据目录）/ L2（FFmpeg）可对照本报告。
