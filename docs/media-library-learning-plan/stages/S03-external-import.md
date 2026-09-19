# S03：B站、YT-DLP、FluentPack 的入库语义

依赖 S02。先读交接中的批次API，不需要重新读整个本地导入实现。

## 定向入口

- lib/services/bilibili/bilibili_download_service.dart：importStreamingToLibrary、importParsedStreamingTaskToLibrary、_importStreamingToLibrary、importToLibrary 和 addSingleVideo 调用附近。
- lib/features/youtube_download/services/yt_dlp_download_service.dart：importToLibrary、_handleCompletedTaskAutomation。
- lib/features/portable_transfer/portable_transfer_service.dart：导入清单、ID重映射、_importSnapshot/相关实际函数；先 rg 定位，不读整个文件。
- lib/features/portable_transfer/portable_transfer_navigation.dart：只确认共享导航与输入分类，不重写。
- LibraryService.importPortablePackageDirectory / addSingleVideo 的必要参数扩展。

## 要完成的规则

1. B站在线播放导入、已下载媒体导入、YT-DLP 手动导入和自动完成后入库都登记事实；“下载完成”与“真正入库”不是同一事件。
2. 一次显式多选导入调用为一批。后台任务各自独立完成并自动入库时，按各自真实任务调用分批，不强求把数小时的任务绑在一批。
3. 同链接 B站卡片仍可拥有不同 ID；不得新引入 URL/指纹合并。已有卡片缓存填充、清空缓存、切换在线/本地播放资源不算重新入库。
4. 便携包在目标库重映射后的新 ID 才进入批次。新增媒体使用本次本机 addedAt，原包播放位置、字幕资产、目录封面文字按已有功能保留。
5. 不携带来源设备固定/隐藏/最近播放时间。若包里有新字段但当前版本不使用，应安全忽略本地活动部分，不因此丢媒体、进度或拒绝旧包。
6. 便携包失败/取消遵守原回滚，活动引用同样撤销。恢复/reuse已有记录不误报为新媒体。
7. 登录、下载队列、自动化开关、网络重试、临时素材清理不属于本阶段。不要从 UI 再添加一套旁路登记。
8. 更新交接“入库来源覆盖表”，每个入口写来源→批次边界→实际提交点；自动化中缺失某个来源不能写完整覆盖。

## 验收

运行/按变化扩展：
- test/bilibili_streaming_import_progress_test.dart
- test/bilibili_streaming_models_test.dart
- test/portable_local_snapshot_roundtrip_test.dart
- test/portable_bilibili_roundtrip_test.dart
- test/portable_nested_selection_roundtrip_test.dart
- test/portable_transfer_recovery_test.dart

新增针对 YT-DLP 手动/自动入库边界的局部测试，以及同链接独立卡片各自入库的测试。模拟网络/任务结果，不要求真实登录和下载。
确认旧包能读、新旧包的媒体与原有进度不受影响；活动数据不会引用源设备 ID。

