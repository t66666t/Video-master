# S00：核对当前基线，不重复实现已有能力

执行前只读 ../CONTRACT.md、../PROGRESS.md 和本文件。本阶段仅核对与记录；除计划交接外不修改业务代码。

计划更新时已静态核对 HEAD `61018752`。本阶段验证这些事实是否仍成立，不要重新探索字幕/下载/原生平台。

## 计划更新时的对照（源码确认，测试未跑）

| 旧计划要求 | 当前源码证据 | 状态 |
|---|---|---|
| 三个入口 / 最近添加 / 继续学习 | 无对应符号 | 仍缺失 |
| 活动元数据 addedAt / lastPlayed / 批次 / 固定 / 隐藏 | 无 `LibraryActivity` 等 | 仍缺失 |
| 共享布局与封面 | `MediaLibraryLayoutDefaults`、grid/list、`FolderPlaceholderCover`、`coverLabel` | 已完成，复用 |
| 搜索默认原目录队列 | `CollectionScreen._preparePlaybackQueue` → `prepareLibraryPlayback` | 已完成；有 `test/search_playback_queue_test.dart`，运行仍待 |
| 内嵌搜索框改造 | 已改为 `showMediaLibrarySearchPrompt` + `CollectionScreen.search` | 旧方案过时，保留 4.4 |
| 面包屑 / 包含子文件夹 | CollectionScreen 标题仅为当前名；无跨层浏览开关 | 仍缺失 |
| 导入批次记录 | `StructuredImportExecutionResult.importedVideoIds` 有成员列表，无活动批次 | 管线已完成，批次记录仍缺失 |
| 去重 / 回滚 / 独占导入 | `reuseExistingItem`、`_rollbackStructuredImportState`、`_runExclusiveImport` | 已完成，复用 |
| FluentPack | `PortableTransferService` ID 重映射、`importPortablePackageDirectory` | 迁入已完成；活动语义仍缺失 |
| 完成事件后进度归零 | `_handlePlaybackCompleted` 保存末尾再归零 | 已完成；续学需另记 |
| 完成确认 | `PlaybackBehaviorPolicy.isConfirmedPlaybackCompletion` | 已完成，S06 复用 |
| 失联重定位 | `isSourceMissing` / `markCurrentSourceMissing`；无改 path API | 缺失态部分完成，重定位仍缺失 |
| 顶栏动作整理 | 导入表 + 紧凑溢出菜单 + `DesktopMediaManagementShortcutAction` | 已完成；原 S09 重建任务取消 |
| 分享入库 | `IncomingShareListener` 与 HomeScreen `_setupIncomingMediaHandling` 都调用 `processIncomingSharedItems` | 入口存在；是否双触发尚未核实 |
| AGENTS.md | 仓库无此文件 | 无 |
| 未提交 4.4 源码 | 已提交，工作区干净 | 旧提醒过时 |

## 最小阅读和执行

- `git status --short`，`git diff --stat`，`git log -5 --oneline`。只看与媒体库相关的差异片段。
- rg：`HomeScreen`、`showMediaLibrarySearchPrompt`、`_preparePlaybackQueue`、`MediaLibraryLayoutDefaults`、`_performLibrarySnapshotWrite`、`_importDirectoryTreeIntoLibrary`、`_handlePlaybackCompleted`、`isSourceMissing`。
- 读取上述符号附近短片段；不要展开样式实现或整个播放器。
- 确认 compact 顶栏是辅助组件而不是整页 AppBar 类。

运行低成本基线（失败不能先假定由本计划导致）：

```
flutter test test/search_playback_queue_test.dart test/media_library_layout_profile_test.dart test/media_library_grid_card_test.dart test/media_library_selection_drop_targets_test.dart test/media_library_search_prompt_test.dart test/media_library_overlay_identity_test.dart
```

必要时分命令运行。记录工具链版本；不用先跑整库测试。

## 验收与交接

把事实变化、已有失败、后续关键符号位置写入 validation/S00.md。PROGRESS.md 记录基线和下一阶段约束。
不得写“所有现有功能已验证”；本阶段测试只覆盖所执行的部分。
S00 done 后停止。下个阶段 S01。
