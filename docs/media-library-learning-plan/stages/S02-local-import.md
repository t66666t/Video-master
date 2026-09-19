# S02：本地导入和批次记录

依赖 S01。目标是记录真实成功的新入库项，不改导入所有权、安全和事务策略。

## 按需阅读

先看 LibraryService.importVideosBackground、importFolderSelection、importArchiveSelection、_importDirectoryTreeIntoLibrary、_StructuredImportAccumulator、addSingleVideo 的实际插入点。
再看 lib/widgets/video_action_buttons.dart 的 processDroppedPaths、processIncomingSharedItems 与本地选择入口；批量媒体字幕配对的实际提交需定位 lib/screens/batch_import_screen.dart 的 _handleMerge / addSingleVideo，lib/services/batch_import_service.dart 主要维护待处理行与markImported，不要误把添加待处理行当成媒体已入库。只追踪这些调用链。
复用 test/media_folder_scanner_test.dart、test/archive_extraction_safety_test.dart、test/media_private_import_setting_test.dart、test/incoming_share_signatures_test.dart。

## 行为与实现要求

1. 每次用户导入动作分配独立批次上下文，显式传给必要下层。不要用单个可变 currentBatch 全局字段；并发/排队导入不能串组。
2. 一次多选文件为一批；一次选择多个目录/压缩包，按每个目录/压缩包分批，沿用已有选择边界。拖拽、系统分享与文件选择都走同样记录规则，不在 UI 和服务各登记一次。
3. addedAt 只在实际创建新媒体时赋值。复用/恢复已有 ID 保持原时间，不成为“新建”成员。新媒体的批次内顺序沿用导入确定的顺序，不能每完成一个异步任务就按回调顺序洗牌。
4. 结构化导入利用已有 accumulator/importedVideoIds；事务成功才把可见批次发布出来。发生既有整批回滚时，活动记录随媒体一起回滚。新增媒体与其addedAt必须进入同一快照；进程中断导致媒体已提交而批次尚未完成时，S05仍能按单项显示它，不能让它从最近添加消失。
5. 普通文件逐项导入按真实结果记录成功、复用/恢复、失败。若既有流程不能返回逐项详情，可加小型结果对象，不改成全新任务调度。不要为了统一统计把整批回滚改成部分保留。
6. 下载字幕、补缩略图、探测章节、复制到私有存储都是同一次入库的后处理，不生成第二个批次、不重写 addedAt。媒体字幕配对页只有实际合并提交才记录；撤销该次入库时清理其新增活动引用，不因markImported状态变化生成重复记录。
7. 为后续 UI 提供不可变的批次 ID / 新增 ID / 实际结果摘要。保留原进度条和通知频率，不每处理一项就整库序列化或刷新主页。
8. 用户取消预览/文件选择不创建空批次；只有失败或全部复用的操作给真实提示，不造一条“新增0”的历史。
9. 界面可安全重新执行失败源时只重试失败项并继续原操作上下文；结构化回滚则沿用整批重试。需要重新选择来源时直说，不宣称支持跨重启自动恢复。

## 测试

- 多选视频按一个批次、单个媒体直接可投影。
- 目录/压缩包保留章节次序；失败回滚后没有孤儿批次。
- 文件选择、拖拽、分享只记录一次。
- 已有项复用/恢复不改 addedAt；用户显式创建的新 ID 仍按新项登记。
- 两个导入交错完成不串批次；后处理失败不伪造二次入库。
- 私有存储、压缩包安全、字幕关联的既有测试仍通过。

使用临时测试目录与伪造媒体探测，避免依赖真实大文件、真实网络或用户媒体。
完成后记录各本地入口实际接入位置；S03只需补其他来源，不再次重写本地管线。
