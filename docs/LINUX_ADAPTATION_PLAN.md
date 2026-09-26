# Video-master Linux 适配 Plan

> 读者：Flutter 代码助手 / 调试助手 / 美化助手  
> 工程：`/workspace/Video-master-src`  
> 基线：GitHub `https://github.com/t66666t/Video-master` `main` @ `5f49c14`（Fluent player v0.5.0）  
> 测试资源：`/workspace/Video-master-test/videos/{en,zh}`  
> 已知问题：`/workspace/Video-master-test/notes/LINUX_KNOWN_ISSUES.md`  
> 硬约束：**只在本仓库改**；不要用旧 Fluent-Learning 副本；每阶段可 `analyze` + `flutter build linux --release`

---

## 0. 产品目标

在 Linux 桌面（GTK）上可安装、可冷启、可导入测试片、可播放中英样片，核心媒体库/播放/字幕路径可用。

### 硬收口（用户补充，2026-09-20）

**改完后所有功能都要能在 Linux 用**，尤其对齐 Windows 已完善的能力：

1. **导入**：单文件 / 多文件 / 文件夹导入、拖放导入（`desktop_drop`）、批量导入相关入口
2. **打开目录**：选目录对话框（`FilePicker.getDirectoryPath`）、下载保存目录、库内「打开所在文件夹」
3. **文件管理**：`revealInFileManager`（Linux：FileManager1.ShowItems → `xdg-open`）、在文件管理器中显示、缓存/导出目录可达

效仿 Windows 行为与入口，不要求像素级 UI 一致；缺能力就补 Linux 分支，禁止 `if (Platform.isWindows)` 把 Linux 永久挡在外（除非上游无 API，则给明确降级提示）。

**非目标（可降级但需说明）**：无声卡听感；部分依赖系统包（`ffmpeg`）的高级转码在未安装时的友好提示。

---


---

## 1. 现状摘要（基于 `5f49c14` 实勘）

| 区域 | 现状 | 风险 |
|------|------|------|
| `linux/` runner + CMake | 有标准 Flutter Linux 工程；已装 yt-dlp 资源拷贝 | 需确认 release bundle 完整 |
| `media_kit` + `media_kit_libs_linux` | 依赖已声明 | 播放主路径优先走 media_kit |
| `path_provider` | `LibraryService.init` 等直接 `getApplicationDocumentsDirectory()` | **阻塞**：`MissingPlatformDirectoryException` |
| `ffmpeg_kit_flutter_new` | 多处 FFmpegKit/FFprobeKit | **阻塞**：`libffmpegkit.so` dlopen 失败 |
| `FFmpegUtils` | Linux 已回落到 PATH 的 `ffmpeg`/`ffprobe` | Kit 与 Utils 双轨，Kit 失败仍炸 |
| `window_manager` | 桌面三端共用 | 窗口最小尺寸/默认尺寸需验 |
| UI | `HomeScreen` 有桌面分支，但仍偏移动密度 | 大屏需美化跟进 |

---

## 2. 总路线图

| 阶段 | 目标 | 负责人 | 验收 |
|------|------|--------|------|
| **L0** | 基线复现与清单冻结 | 调试 | 复现两则阻塞；记录日志摘要 |
| **L1** | Linux 应用数据目录兜底 | 代码 | 冷启不再因 path_provider 崩；库可落盘 |
| **L2** | FFmpeg 策略（Kit 降级 / 系统 ffmpeg） | 代码 | 无 so 也能走探测/转码关键路径或明确禁用并提示 |
| **L3** | 播放与导入冒烟 | 代码+调试 | 导入 test videos；播 en/zh；analyze + linux release |
| **L4** | 桌面 UI 适配 | 美化+代码 | 宽屏可用：Rail/分栏、密度、对话框 |
| **L5** | 次要能力与打包 | 代码 | yt-dlp 资源、文件管理器打开、release bundle 自检 |
| **L6** | 收口 | 架构+调试 | 更新已知问题文档；推 GitHub（如有凭据） |

循环：架构开工单 → 代码实现 → 调试验收 →（UI 阶段）美化过目 → 下一阶段。

---

## 3. Phase L0 — 基线复现（调试先做）

**要做**
1. 在 `/workspace/Video-master-src` 确认 `git rev-parse --short HEAD` = `5f49c14`
2. `flutter analyze`（记 error 数，不求本阶段清零）
3. `flutter build linux --release`（成功或失败都留日志）
4. 跑起来复现：`MissingPlatformDirectoryException`、`libffmpegkit.so`
5. 把复现命令与栈贴群，作为 L1/L2 对照

**验收**：两则阻塞有可复现步骤；不改业务代码也可结束 L0。

---

## 4. Phase L1 — path_provider / 应用数据根（优先）

**问题**：Linux 上 documents 目录异常，拖垮 Library / BatchImport / BilibiliDownload / Materialization。

**要做（仅必要改动）**
1. 抽或扩展「应用数据根」解析（建议新建小工具，如 `lib/utils/app_data_paths.dart`）：
   - 优先 `getApplicationSupportDirectory()` / `getApplicationDocumentsDirectory()`
   - catch `MissingPlatformDirectoryException`（及同类）后回退：  
     `$XDG_DATA_HOME/<app>` 或 `~/.local/share/video_player_app`（与 `APPLICATION_ID`/`BINARY_NAME` 对齐）
   - `Directory.create(recursive: true)`
2. `LibraryService.init` 及同样直接调 documents 的初始化路径改为走统一解析
3. Windows 现有 `SettingsService.resolveLargeDataRootDir` 逻辑保留，不要破坏

**不改**：媒体模型、播放器内核。

**验收**
- 冷启无 path_provider 未处理异常
- 库文件写入回退目录成功
- analyze 无新 error；linux release 可编（若 L2 so 仍失败，至少 Dart 层不因 path 崩）

---

## 5. Phase L2 — FFmpeg：Kit 与系统双轨

**问题**：`ffmpeg_kit_flutter_new` 在 Linux bundle 缺/坏 `libffmpegkit.so`。

**策略（按优先级）**
1. **运行时探测**：Linux 上优先 `FFmpegUtils.ffmpegPath` / `ffprobePath`（PATH 或后续可捆绑的二进制）
2. **调用点分流**：`transcription_manager` / duration·chapter probe / subtitle convert / compose 等：  
   - Linux：Process 调系统 ffmpeg/ffprobe；失败 → 用户可见错误，不崩溃  
   - 其它平台：保持现有 FFmpegKit（除非顺手统一）
3. **打包**：评估是否能把 kit `.so` 正确装进 `bundle/lib`；若上游 Linux 支持差，**明确 Linux 禁用 Kit**，文档写依赖 `ffmpeg` 包
4. 禁止引入第二套巨型 native 栈

**验收**
- 启动不再因 dlopen kit 直接崩（捕获或条件导入）
- 在已安装 `ffmpeg`/`ffprobe` 的环境：时长探测或一条字幕/音频相关路径可跑通其一
- 无 ffmpeg 时：降级提示清晰

---

## 6. Phase L3 — 导入 + 播放冒烟

**要做**
1. 文件/文件夹导入能选中 `/workspace/Video-master-test/videos/en` 与 `zh`
2. `media_kit` 播放样片（有画面；无声卡时允许无音频，不崩）
3. 修 Linux 上阻塞导入/播放的路径、URI、权限问题
4. 冒烟清单写入 `docs/` 或更新 `LINUX_KNOWN_ISSUES.md`「已修复」节

**额外（导入 / 目录，对齐 Windows）**
1. 文件夹导入、文件导入、拖放导入在 Linux 均可完成（用 test videos）
2. 凡 Windows 有「选择目录」的设置/下载/导出入口，Linux 同样可弹出并写回路径
3. 「在文件管理器中显示」对库内本地文件可用（选中或至少打开父目录）

**验收**（调试）
- `flutter build linux --release` 成功
- 冷启 → 文件夹导入 test videos → 列表可见 → 打开播放 en/zh 各至少 1 个
- 至少一条「打开所在目录 / 在文件管理器显示」路径跑通
- analyze 无新 error

---

## 7. Phase L4 — 桌面 UI 适配（美化主导）

**要做**
1. 宽屏：主壳密度、列表/详情分栏或合理最大宽，避免手机底栏思维硬套
2. 窗口：默认尺寸、最小尺寸（`window_manager`）合理
3. 文件对话框/拖放（`desktop_drop`）在 Linux 可用
4. 仅表现层；播放控件布局非必要不动

**验收**：1280×720 与更大分辨率下主要页可完成导入/播放/库浏览；美化过目 + 调试 analyze。

---

## 8. Phase L5 — 次要能力与打包

**要做**
1. 对照 Windows：扫全部 `Platform.isWindows` 挡掉的导入/目录/文件管理分支，能开 Linux 的打开（缩略图可走 ffmpeg 回退，勿只留 Windows 专用）
2. `revealInFileManager` 全入口回归（库、字幕、下载完成、便携传输等）
3. yt-dlp 资源路径与 CMake install 在 release bundle 自检（本阶段不要求下载全绿）
4. AppData / 缓存 / 导出目录说明写入 docs
5. 清理 Linux 启动日志里的致命噪声（ALSA 无卡除外）

**验收**：bundle 完整；导入与文件管理主路径与 Windows 对等可用；已知问题文档更新。

---

## 9. Phase L6 — 收口

1. `LINUX_KNOWN_ISSUES.md`：区分「已修复 / 仍在 / 环境限制」
2. 本 Plan 顶部标各阶段 SHA
3. 有 GitHub 凭据则推 `main`；否则由调试助手/用户推

---

## 10. 给代码助手的约束

1. 工作目录只能是 `/workspace/Video-master-src`，基线 `5f49c14` 之上提交
2. 最小改动；先 L1 再 L2，不要一开头大重构
3. 不重写 `media_kit` 播放核心
4. 不新增悬浮 Toast 体系（沿用现有反馈）
5. 每阶段：说明改动文件 → 实现 → 自测要点 → 交调试
6. Linux 专用代码用 `Platform.isLinux` 守卫，避免回归 Windows/Android

---

## 11. 建议开工顺序

**立刻：L0（调试复现）∥ 架构已出本 Plan**  
然后 **L1 → L2 → L3 → L4 → L5 → L6**。

首个代码开工单默认 **L1**（数据目录兜底）。
