---
name: media-notification-episode-switch-fix
overview: 修复手机端媒体通知卡片上一集/下一集切换的加载失败、状态混乱、回前台重新加载问题，使通知卡控制与应用内操作行为完全一致，并保证回前台无缝衔接。
todos:
  - id: readiness-degrade
    content: 使用 [SubAgent:code-explorer] 精读 _awaitPlaybackReadiness 与 _playPlaylistItem 重试逻辑后，重构 media_playback_service.dart：后台时钟超时降级为可恢复状态（不抛异常不 3 次重试），autoPlay=false 严格不开播仅 seek 暂停
    status: completed
  - id: attach-fallback
    content: 为 ensureVisibleVideoOutput 增加 attach 失败后的 reopen 兜底（保留进度与播放意图），改造 playback_navigation_service._waitForPresentableSession 超时先恢复再导航，消除进 app 全量重载
    status: completed
    dependencies:
      - readiness-degrade
  - id: unified-mutex
    content: 将通知卡远程命令、前台恢复 attach、导航等待、切集重试统一纳入 episode 命令队列串行化，并调整开播时序（后台就绪后开播，前台就绪失败回滚为暂停）
    status: completed
    dependencies:
      - readiness-degrade
  - id: ui-reentry-guard
    content: 为 video_player_screen.dart 的 _onPlaybackServiceChange/_initVideo 增加重入守卫，system_media_session_service.dart 如实反映后台 loading/paused 状态
    status: completed
    dependencies:
      - readiness-degrade
  - id: tests-regression
    content: 编写/更新单元测试固化 autoPlay 开关在通知卡与应用内两条链的播放/暂停语义、连播设置行为、attach 失败恢复路径，运行 flutter analyze 与相关测试回归
    status: completed
    dependencies:
      - attach-fallback
      - unified-mutex
      - ui-reentry-guard
---

## 需求概述

修复手机端媒体播放通知卡片控制「上一集/下一集」的严重缺陷，使后台通知卡控制与应用内按钮控制达到 100% 一致，达到成熟播放器的水准。覆盖本地视频、B 站在线视频与音频播放。

## 核心目标

1. **行为一致性**：通知卡切集与应用内按钮走同一套逻辑（代码中已汇合于 `MediaPlaybackService.playNext/playPrevious`，需修复执行层缺陷而非重写架构）。
2. **切换可靠**：切集后目标视频必须能正常加载播放，不再出现“加载不出来”或反复重试导致的状态混乱。
3. **等待就绪再播**：切换后等媒体真正加载就绪再开始播放，消除“卡一下”与进度跳变；autoPlay 关闭时定位到记录时间点并保持暂停。
4. **无缝回前台**：后台能播的内容，回前台（从通知卡点入或任务切换器返回）零重载衔接，消除“进 app 重新加载媒体”。
5. **设置后台生效**：「切换上下集后自动播放」「自动连播」「连播时从头播放」在后台与通知卡场景下与应用内完全一致。

## 排查确认的根因（按严重性）

1. 【高】后台 headless 会话回前台依赖 `ensureVisibleVideoOutput` texture 挂载，attach 两次失败后**无 reopen 兜底**，会话永久卡在 `videoOutputDeferred`；且 `_waitForPresentableSession` 25s 超时后照样导航，页面回退 `play()` 全量重载媒体。
2. 【高】后台 readiness 等 native clock 20s 超时即抛异常 → 状态置 error → **最多 3 次全链重试**（含重开媒体+seek），通知卡长期停留在 loading/error。
3. 【中】乐观开播：`controller.play()` 先于就绪确认，解码未就绪即发声，事后补偿导致黑屏/进度跳变；autoPlay=false 的暂停语义在后台路径不可靠。
4. 【中】远程命令 barrier 与前台恢复 attach、导航等待、重试循环**不互斥**，仅靠事后取消防护，存在竞态窗口。
5. 【低】播放页 `_onPlaybackServiceChange → _initVideo` 无重入守卫，多次 notify 可并发触发初始化。

## 技术方案

### 技术栈

- Flutter（现有项目），audio_service 0.18.18，media_kit 平台层（`windows_video_player_media_kit.dart` 同族平台实现）。
- 不引入新依赖、不重写架构：现有「服务为唯一控制器 owner + 会话 generation + episode 命令队列」的设计方向正确，问题是执行层有失败死角与竞态，做**定点加固**。

### 实施思路

**原则：一切入口收敛到同一条串行命令链，一切失败路径都有兜底恢复，绝不静默重载媒体。**

1. **后台 readiness 降级而非重试风暴**（media_playback_service.dart `_awaitPlaybackReadiness` L944-1001、`_playPlaylistItem` 重试循环 L4366-4391）

- 后台时钟超时不再抛 TimeoutException 触发 error+3 次重试；降级为“已定位、未确认开播”的可恢复状态，保留会话等待前台确认。
- 重试仅保留给真实可重试错误（如 initialize 失败），且最多 1 次；重试必须先彻底取消旧会话。
- autoPlay=false 时后台路径严格不调用 `controller.play()`，仅 seek 到记录时间点后暂停。

2. **attach 失败 reopen 兜底**（`ensureVisibleVideoOutput` L1044-1110）

- texture attach 两次失败后，增加 reopen 兜底：用同一进度（frozenStartPosition）与播放意图（autoPlay）重开媒体，完成后再放行 `canMountControllerFor`。reopen 期间 UI 显示 loading 而非卡死。
- `_waitForPresentableSession`（playback_navigation_service.dart L145-172）超时不再“照样导航”，改为：触发一次 reopen 恢复，恢复完成后再导航，彻底消除进 app 后 `_initVideo` 回退 `play()` 重载的路径。

3. **开播时序修复**

- 后台路径：等待 readiness 确认后再 play，消除“未就绪先出声”。
- 前台路径：保留乐观开播（有意设计，避免 texture 循环等待），但 readiness 失败时回滚为**暂停在目标进度**（而非 error），由前台恢复时确认开播。

4. **入口级互斥**

- 远程命令（skipToNext/Previous/playMediaItem）、前台恢复 `ensureVisibleVideoOutput`、`openCurrentPlaybackSession` 导航等待、切集重试，统一纳入现有 episode 命令队列串行化；`_isCurrentPlayRequest`/generation 事后取消保留为第二道防线。

5. **UI 层加固**：`_initVideo` 增加重入守卫（token/单飞），多次 notifyListeners 只触发一次初始化。

6. **设置语义回归保障**：编写单元测试固化——autoPlayNextVideo 开/关在两条链上的开播/暂停行为；连播（`autoPlayOnCompletion`/`autoPlayOnCompletionFromStart`）行为不变；手动切集不应用“连播从头播”语义维持现状。

### 架构图

```mermaid
flowchart LR
    A[通知卡 skipToNext/Previous] --> C
    B[应用内按钮] --> C
    C["MediaPlaybackService.playNext/Previous<br/>→ episode 命令队列（统一串行化）"] --> D[_executeEpisodeNavigation]
    D --> E[play: seek 到记录时间点<br/>后台: 就绪后开播 / autoPlay=false 保持暂停]
    E --> F{回前台}
    F -->|attach 成功| G[无缝衔接 零重载]
    F -->|attach 失败| H[reopen 兜底<br/>同进度+同播放意图] --> G
```

### 目录结构（仅涉及修改的文件）

```
lib/
├── services/
│   ├── media_playback_service.dart        # [MODIFY] 核心：readiness 降级、autoPlay 暂停语义、attach 失败 reopen 兜底、入口互斥
│   ├── system_media_session_service.dart  # [MODIFY] 远程命令纳入统一队列；后台切集状态如实反映到通知卡（loading/paused）
│   ├── playback_navigation_service.dart   # [MODIFY] _waitForPresentableSession 超时改为先恢复再导航
│   └── playback_behavior_policy.dart      # [MODIFY] 如需补充时间点归一化的后台分支判定
├── screens/
│   └── video_player_screen.dart           # [MODIFY] _initVideo 重入守卫
└── test/
    └── ...                                # [NEW/MODIFY] 后台切集、autoPlay 语义、attach 失败恢复路径的单元测试
```

### 实施注意

- 平台层注释明确：重开媒体会造成可见缓冲与重放，reopen 兜底必须**仅在 attach 失败后**触发，不改变主路径。
- 每项修改保持向后兼容：桌面端（Windows）前台路径行为不变，改动集中在后台/移动端分支。
- 改动后运行 `flutter analyze` 与 test/ 中相关媒体播放测试回归。

## Agent Extensions

### SubAgent

- **code-explorer**
- Purpose: 实施前精确定位待改方法的完整上下文（media_playback_service.dart 的 readiness/play/attach 代码段、playback_navigation_service 的等待逻辑），实施中核对调用点无遗漏
- Expected outcome: 拿到精确行号与调用链，避免修改波及桌面端前台路径