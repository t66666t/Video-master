# S00：核对当前基线，不重复实现已有能力

执行前只读 ../CONTRACT.md、../PROGRESS.md 和本文件。本阶段仅核对与记录；除计划交接外不修改业务代码。

## 已观察到的事实

1. Flutter 项目，现有 Provider + ChangeNotifier 服务；计划编写环境可用 Flutter/Dart 位于 D:/FlutterSDK/flutter/bin，但执行时以实际 PATH 为准。
2. 当前工作区有大量有效未提交更新和未跟踪组件。不要用 HEAD 版本替代工作区。
3. home_screen.dart / collection_screen.dart 仍分别承担根目录与目录/搜索页面，卡片和列表已共用新的布局规则。
4. 最新布局模块：media_library_layout_profile.dart（按横竖屏、home/collection 取样式）、media_library_style_sheet.dart、media_library_grid_card.dart、media_library_list_tile.dart。
5. 新增封面模块 folder_placeholder_cover.dart / folder_placeholder_style_dialog.dart；VideoCollection.coverLabel 的 null 表示跟随目录名，空串表示该目录不显示封面文字。
6. 目录选择态已有 media_library_selection_drop_targets.dart、media_library_selection_bottom_bar.dart；已有 library_rename_dialog.dart 和 PortableTransferNavigation。
7. 搜索默认队列已经修复：CollectionScreen._preparePlaybackQueue 调用 PlaylistManager.prepareLibraryPlayback，按视频原父目录队列播放。test/search_playback_queue_test.dart 已存在，不要再把它列成未修复缺陷。
8. LibraryService 的主库 schema 当前为 2，已有串行快照写入、临时文件/备份和失败重试。lastUpdated 会随播放等操作变化，不是入库时间。
9. 结构化目录导入有 importedVideoIds 和 accumulator，失败整批回滚。addSingleVideo 有显式 reuseExistingItem；同链接 B站在线卡片允许独立 ID。
10. MediaPlaybackService 完成处理会保存末尾、再把进度归零；继续学习必须另记完成事件。
11. FluentPack 导入会重映射 ID；不能把来源设备的活动引用当作本地引用。
12. 现有搜索故意只匹配每个卡片自己的标题，不匹配父目录或字幕。

## 最小阅读和执行

- git status --short，git diff --stat，检查各级 AGENTS.md；只检查与当前事实有关的差异片段，禁止输出全部 diff。
- 在 home_screen.dart / collection_screen.dart 搜索 build、MediaLibraryLayoutDefaults、_preparePlaybackQueue；读取相关短片段。
- 读取上述新共享组件的类签名和设置取值；不要展开整个样式实现。
- 在 library_service.dart 定位 _performLibrarySnapshotWrite、_loadLibrary、_importDirectoryTreeIntoLibrary、updateVideoProgress。
- 在 media_playback_service.dart 定位 _handlePlaybackCompleted；读取完成事件与归零的相邻逻辑。
- 若事实一致不再重复探索下载/字幕/原生平台。

运行低成本基线：
flutter test test/search_playback_queue_test.dart test/media_library_layout_profile_test.dart test/media_library_grid_card_test.dart test/media_library_selection_drop_targets_test.dart
必要时分命令运行以定位失败，失败不能先假定由本计划导致。记录工具链版本；不用先跑整库测试。

## 验收与交接

把事实变化、已有失败和后续关键符号位置写入 validation/S00.md。PROGRESS.md 记录基线和下一阶段需要的约束。
不得写“所有现有功能已验证”；本阶段测试只覆盖所执行的部分。
S00 done 后停止。下个阶段 S01。

