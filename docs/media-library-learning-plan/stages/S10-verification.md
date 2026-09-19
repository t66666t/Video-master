# S10：整体验收、风险复核与复杂度删减

依赖 S00—S09。先读 PROGRESS 和各阶段 validation 摘要，只为失败或遗漏定位必要代码，不重新通读整个工程。

## 先做功能串联验收

| 场景 | 必须观察到的结果 |
|---|---|
| 旧库升级 | 媒体/封面/字幕/目录顺序保留；未知时间不伪装今天 |
| 导入单视频 | 最近添加可直接找到，不需要下滚到原目录末尾 |
| 导入多层100项课程 | 一个合理批次，展开是本次新项，章节次序未打乱 |
| 改名/移动/播放/字幕处理 | 入库时间不变，三个入口反映同一 ID 的当前信息 |
| B站在线/下载、YT-DLP 自动入库 | 实际入库才出现；同链接独立卡片策略未变化 |
| FluentPack 新旧包 | 新 ID 与本次时间正确，旧进度/字幕/封面保持既有能力 |
| 交替学习 A/B | 各自位置可恢复；搜索/最近入口下一集不跳到另一课程 |
| 只打开/拖动/缓冲 | 不制造有效观看时间 |
| 播完/重看 | 完成归零不误入未完成；实际重看达到门槛后重入 |
| 隐藏/撤销/固定 | 入口操作不删媒体；同次 tick 不解除隐藏；固定不重复展示 |
| 深层目录查找 | 一次搜索或包含子目录浏览即可直达；面包屑一击回根 |
| 回收/恢复/永久删除 | 祖先回收过滤正确；恢复引用；永久删除无孤儿 |
| 失联/重新定位 | 不丢进度与托管字幕；不影响正在播放的另一媒体 |
| 数据写入失败 | `LibraryPersistenceNotificationBridge` 仍有效，新状态未假称已安全保存 |
| 返回/重启/旋转 | 入口、位置、搜索上下文、样式和播放控制权稳定 |
| 导入失败/取消 | 结果符合该入口原事务语义，没有幽灵批次或重复入库 |
| 4.4 chrome | 搜索提示、导入表、FluentPack、选择投放区/底栏、紧凑顶栏、快捷键仍可达 |

## 代码验证

1. 按阶段日志确认新增规则确实由生产入口调用；不能仅有孤立 helper 测试。
2. 格式化只涉及本任务修改的 Dart 文件；先查看 diff，禁止格式化整个 lib。
3. 执行受影响文件的静态分析和所有新增测试；已有核心回归至少覆盖：
   - `library_persistence_recovery_test.dart`
   - `library_subtitle_schema_v2_migration_test.dart`
   - `search_playback_queue_test.dart` / `playback_queue_policy_test.dart`
   - `media_playback_session_state_test.dart` / `media_playback_request_race_test.dart`
   - `media_playback_missing_source_test.dart` / `background_playback_handoff_test.dart`
   - `playback_behavior_policy_test.dart`
   - `media_library_layout_profile_test.dart` / `media_library_grid_card_test.dart`
   - `media_library_list_tile_responsive_test.dart` / `media_library_item_interaction_wrapper_test.dart`
   - `media_library_selection_drop_targets_test.dart` / `media_library_top_bar_import_progress_test.dart`
   - `media_library_search_prompt_test.dart` / `media_library_overlay_identity_test.dart`
   - `media_private_import_setting_test.dart` / `archive_extraction_safety_test.dart`
   - `portable_local_snapshot_roundtrip_test.dart` / `portable_bilibili_roundtrip_test.dart` / `portable_transfer_recovery_test.dart`
   - `incoming_share_signatures_test.dart` / `portable_incoming_classification_test.dart`
4. 最终运行一次全量 `flutter analyze` 和 `flutter test`，若工具/插件/平台依赖使其无法完成，记录具体失败、基线对比和可执行替代检查，不删除或跳过失败测试来制造绿灯。只有有基线证据的失败才称“既有失败”；首次发现而无法归因的失败标“归因待核实”，不能因文件未改就断言无关。
5. 完成后只对新发现的问题补回归；无新变化不重复运行同一套通过检查。

## 视觉/性能验收

- 用实际运行或 widget 测试查看约 360 宽手机、手机横屏、平板和 1280 宽桌面；至少检查卡片/列表各一次、选择态、批次展开、长标题、多层面包屑、迷你播放器和导入进度同时存在。
- 新版自定义列数/间距/封面文字语义无回退，拖放投放区可用，列表文字不被标签挤没。
- 使用生成的测试库验证千项级元数据滚动、查询和分组；无需创建千个真实大视频。确认惰性渲染、不在 build 中读磁盘、不每播放 tick 全库重排/保存。
- 保持原桌面/触控快捷键和后台播放能力；没有设备的端明确 NOT RUN。计划作者没有提供运行截图，不得据计划文字声称已目测。
- 对照 `DesktopMediaManagementShortcutAction` 与 `ImportSheetShortcutAction`：每个原动作仍有入口且范围未漂到全库。

## 最后做一次减法检查

删除本任务引入的：
- 第二套媒体/课程实体、与 library.json 竞争的另一个写库；
- 重复卡片布局公式或并行样式偏好；
- 为三个入口复制的巨型 HomeScreen；
- 未使用的抽象、临时假数据、开发开关和可点击空功能；
- 每帧查询/每秒全库写盘；
- 为本轮顺手增加的标签编辑器、推荐、统计、全文索引、自动全盘找文件、顶栏动作体系重做；
- 虚拟列表上的拖拽重排和隐式跨课程播放。

保留理由明确的成本：导入批次解决刷屏；实际播放/完成记录解决假续学；新入口状态保留解决重复查找。这些不能为了少写代码砍成假实现。

## 最终交付

更新 PROGRESS 和 validation/S10.md，列出完成的用户行为、实际改动文件范围、真实命令结果、未验证平台与仍需处理的风险。
不要自动 commit/push。
只有实现和可执行验收完成才写阶段 done；设备人工验收不足时单独明确“实现完成，平台验收未完成”，不能声称全面完成。若核心行为仍失败，保持 S10 in_progress 并记录下一次精确断点。
