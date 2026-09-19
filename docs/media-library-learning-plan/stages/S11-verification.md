# S11：整体验收、风险复核与复杂度删减

依赖 S00—S10。先读 PROGRESS 和各阶段validation摘要，只为失败或遗漏定位必要代码，不重新通读整个工程。

## 先做功能串联验收

| 场景 | 必须观察到的结果 |
|---|---|
| 旧库升级 | 媒体/封面/字幕/目录顺序保留；未知时间不伪装今天 |
| 导入单视频 | 最近添加可直接找到，不需要下滚到原目录末尾 |
| 导入多层100项课程 | 一个合理批次，展开是本次新项，章节次序未打乱 |
| 改名/移动/播放/字幕处理 | 入库时间不变，三个入口反映同一ID的当前信息 |
| B站在线/下载、YT-DLP自动入库 | 实际入库才出现；同链接独立卡片策略未变化 |
| FluentPack新旧包 | 新ID与本次时间正确，旧进度/字幕/封面保持既有能力 |
| 交替学习A/B | 各自位置可恢复；搜索/最近入口下一集不跳到另一课程 |
| 只打开/拖动/缓冲 | 不制造有效观看时间 |
| 播完/重看 | 完成归零不误入未完成；实际重看达到门槛后重入 |
| 隐藏/撤销/固定 | 入口操作不删媒体；同次tick不解除隐藏；固定不重复展示 |
| 深层目录查找 | 一次搜索或包含子目录浏览即可直达；面包屑一击回根 |
| 回收/恢复/永久删除 | 祖先回收过滤正确；恢复引用；永久删除无孤儿 |
| 失联/重新定位 | 不丢进度与托管字幕；不影响正在播放的另一媒体 |
| 数据写入失败 | 原失败提示/重试仍有效，新状态未假称已安全保存 |
| 返回/重启/旋转 | 入口、位置、搜索上下文、样式和播放控制权稳定 |
| 导入失败/取消 | 结果符合该入口原事务语义，没有幽灵批次或重复入库 |

## 代码验证

1. 按阶段日志确认新增规则确实由生产入口调用；不能仅有孤立helper测试。
2. 格式化只涉及本任务修改的Dart文件；先查看diff，禁止格式化整个lib。
3. 执行受影响文件的静态分析和所有新增测试；已有核心回归至少覆盖：
   - library_persistence_recovery_test.dart
   - library_subtitle_schema_v2_migration_test.dart
   - search_playback_queue_test.dart / playback_queue_policy_test.dart
   - media_playback_session_state_test.dart / media_playback_request_race_test.dart
   - media_playback_missing_source_test.dart / background_playback_handoff_test.dart
   - media_library_layout_profile_test.dart / media_library_grid_card_test.dart
   - media_library_list_tile_responsive_test.dart / media_library_item_interaction_wrapper_test.dart
   - media_library_selection_drop_targets_test.dart / media_library_top_bar_import_progress_test.dart
   - media_private_import_setting_test.dart / archive_extraction_safety_test.dart
   - portable_local_snapshot_roundtrip_test.dart / portable_bilibili_roundtrip_test.dart / portable_transfer_recovery_test.dart
4. 最终运行一次全量 flutter analyze 和 flutter test，若工具/插件/平台依赖使其无法完成，记录具体失败、基线对比和可执行替代检查，不删除或跳过失败测试来制造绿灯。只有有基线证据的失败才称“既有失败”；首次发现而无法归因的失败标“归因待核实”，不能因文件未改就断言无关。
5. 完成后只对新发现的问题补回归；无新变化不重复运行同一套通过检查。

## 视觉/性能验收

- 用实际运行或widget测试查看约360宽手机、手机横屏、平板和1280宽桌面；至少检查卡片/列表各一次、选择态、批次展开、长标题、多层面包屑、迷你播放器和导入进度同时存在。
- 新版自定义列数/间距/封面文字语义无回退，拖放投放区可用，列表文字不被标签挤没。
- 使用生成的测试库验证千项级元数据滚动、查询和分组；无需创建千个真实大视频。确认惰性渲染、不在build中读磁盘、不每播放tick全库重排/保存。
- 保持原桌面/触控快捷键和后台播放能力；没有设备的端明确NOT RUN。计划作者没有提供运行截图，不得据计划文字声称已目测。

## 最后做一次减法检查

删除本任务引入的：
- 第二套媒体/课程实体、与library.json竞争的另一个写库；
- 重复卡片布局公式或并行样式偏好；
- 为三个入口复制的巨型HomeScreen；
- 未使用的抽象、临时假数据、开发开关和可点击空功能；
- 每帧查询/每秒全库写盘；
- 为本轮顺手增加的标签编辑器、推荐、统计、全文索引、自动全盘找文件；
- 虚拟列表上的拖拽重排和隐式跨课程播放。

保留理由明确的成本：导入批次解决刷屏；实际播放/完成记录解决假续学；新入口状态保留解决重复查找。这些不能为了少写代码砍成假实现。

## 最终交付

更新 PROGRESS 和 validation/S11.md，列出完成的用户行为、实际改动文件范围、真实命令结果、未验证平台与仍需处理的风险。
保留用户原未提交修改；不要自动commit/push。
只有实现和可执行验收完成才写阶段done；设备人工验收不足时单独明确“实现完成，平台验收未完成”，不能声称全面完成。若核心行为仍失败，保持S11 in_progress并记录下一次精确断点。
