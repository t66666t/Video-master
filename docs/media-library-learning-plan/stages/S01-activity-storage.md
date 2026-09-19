# S01：最小活动数据、兼容迁移与唯一持久化

依赖 S00。只读公共约定、交接、本文件及下面定位的代码。

## 目标与理由

建立新视图需要的事实记录，不改现有媒体身份、目录顺序和播放器位置来源。数据先稳定，后续 UI 才不会用 lastUpdated 猜用户行为。

## 定向阅读

- lib/models/video_item.dart：字段、toJson/fromJson，仅确认已有位置/时长。
- lib/services/library_service.dart：数据成员、_loadLibrary、_performLibrarySnapshotWrite、_saveLibrary、resetPersistenceForTesting、删除/恢复相关入口。
- lib/services/settings_service.dart：设置注册/更新/迁移的模式，暂不通读全部设置。
- test/library_persistence_recovery_test.dart、test/library_subtitle_schema_v2_migration_test.dart：测试夹具与保存恢复方式。

## 实施

1. 增加小型活动模型与纯查询辅助（建议文件 lib/models/library_activity.dart、lib/services/library_activity_projection.dart；可按现有命名调整）。不要新增数据库或另一个 LibraryService。
2. 将活动元数据纳入原 library.json 快照的单独顶层字段，子结构版本从1开始；不要重复运行原 schema 0/1 的历史迁移。旧文件无新区块就使用空结构，已存在媒体的 addedAt 保持未知。
3. 实现按稳定 ID 维护的媒体活动、导入批次、固定引用。依 CONTRACT 只保存必要信息，不复制标题、路径、封面、进度和媒体清单。
4. 给后续阶段提供小型 API：登记新入库、开始/完成/撤销批次、记录有效播放/完成、固定/隐藏、获取只读投影。API 命名自行确定，准确签名和文件位置写入 PROGRESS；只实现本阶段可验证的持久化与引用操作，播放采样留S06。
5. 活动与媒体变更使用现有串行保存机制；保存失败继续触发现有持久化通知，不因 await 返回就假装已可靠落盘。新增普通活动通知与高频进度通知分离。
6. 不在公开 getter 中按全库检查磁盘。目录可见性检查包含回收祖先，并防循环引用；数据异常不能造成死循环或整库加载失败。
7. 软删除不抹去固定/活动历史，恢复可再次显示；永久删除清理相关活动、固定引用和批次成员，空批次可删除。尽量挂接既有删除入口，不改物理文件删除策略。
8. 活动区坏条目可忽略并保留其他有效条目；未知未来版本不能静默重写为空。保持现有备份/失败恢复策略。
9. 导入 addedAt 和批次属于本机库。不能在 VideoItem.toJson 中顺手塞入一套会无条件泄露进 FluentPack 的重复活动字段。

## 必须验证

新增行为测试覆盖：旧库读入后不虚构时间；往返保存；重复加载不重复迁移；媒体更名/进度更新不改变 addedAt；软删/恢复/永久删的引用；回收祖先过滤；活动区部分损坏隔离；保存失败重试恢复后数据一致。
继续运行已有 library_persistence_recovery_test.dart 与 library_subtitle_schema_v2_migration_test.dart。不要测私有字段字符串或复制生产实现计算期望值。

## 边界

不接下载器，不改播放器，不加可见空页面。小型纯查询代码可以先覆盖排序/分组输入，但本阶段不做组件外观。
验收后交接实际 API 和数据形状，再进入 S02。

