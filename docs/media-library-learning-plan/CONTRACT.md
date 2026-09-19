# 全阶段产品与工程约定

只读本文件和当前阶段即可理解边界。标识名可以适配项目命名，但行为不能悄悄变化。

## 用户流程与理由

- 同一媒体库提供“继续学习 / 最近添加 / 文件夹”。原有 VideoItem / VideoCollection 身份和父子关系继续有效；新入口不复制媒体、不搬文件。理由：避免维护两套目录。
- HomeScreen 仍是根入口宿主；目录页/搜索结果页继续用 CollectionScreen。三个入口只出现在根页，不在每一级目录或搜索结果重复堆放。理由：4.4 顶栏已经很满，降低导航改造量和窄屏拥挤。
- 新安装默认“最近添加”；旧库首次升级默认“文件夹”，保护既有使用习惯。之后记住最后入口；同会话保留各入口位置，跨启动恢复选中入口、最后目录和主要位置，不持久化无限量目录历史。
- “最近添加”按不可变的本机入库时间倒序；多个新媒体按一次用户导入操作折叠。批次不是目录。单视频直接展示，旧记录未知时间放“更早添加”，不虚构日期。
- “继续学习”顶部为手动固定，下方为未完成记录。按直接父目录折叠，每组最近一条优先，根目录散片各自展示。不推断整套课程，也不自动跨子目录连播。
- 用户能固定媒体或目录；固定目录打开原目录，固定视频沿用现有断点播放。固定不是“已学/想学”状态机，不再新增想学页。
- 短暂预览不入未完成记录。新媒体本轮采用实际播放门槛 min(30秒, 已知总时长的20%)；未知时长用30秒。按实际经过时间累计，倍速不乘倍数，暂停/缓冲/seek/预加载不累计。阈值集中定义和测试，不做用户设置。
- 完成只表示播放到末尾，不表示掌握。必须先走现有 `PlaybackBehaviorPolicy.isConfirmedPlaybackCompletion`，再用完成事件；不用95%猜测。完成记录不能被“播完进度归零”抹掉。重新实际观看达到门槛后才再次进入未完成记录。
- “不再显示”保留媒体和位置；隐藏不能被同一次会话的余下 tick 立即解除。只有隐藏之后新的用户主动播放会话达到门槛才解除。自动预加载、状态恢复、横竖屏切换、画质切换均不算新的主动播放。
- 浏览排序不决定播放顺序。所有新增入口调用现有 `PlaylistManager.prepareLibraryPlayback`，默认回到原父目录队列。现有自动连播、循环、定时关闭设置保留，不为本计划另改播放器末集策略。
- “包含子文件夹”是当前目录的浏览开关。默认关闭；开启后按既有目录顺序深度优先展示媒体，附相对目录路径。虚拟结果不提供拖拽重排。
- 现有搜索仍只匹配媒体自己的标题/目录自己的名称，不扩展为父目录名联想或全文检索；可以显示路径用于区分。同名字幕搜索不在本轮。搜索 UI 必须继续走 `showMediaLibrarySearchPrompt` + `CollectionScreen.search`，不要改回内嵌搜索框。
- 虚拟视图首版支持打开、固定/取消固定、定位、以及适用时隐藏。重命名、批量移动、回收与导出通过“定位到文件夹”复用现有管理流程，不再复制复杂拖放状态机。
- 数据过滤必须排除回收项及位于已回收祖先下的项；本地文件失联保留记录，不自动删除；在线缓存清空不等于媒体删除。

## 4.4 已有能力（禁止重建）

这些已在当前源码中存在。新阶段只复用和做回归，不要平行实现第二套。

- 布局与卡片：`media_library_layout_profile.dart`、`media_library_style_sheet.dart`、`media_library_grid_card.dart`、`media_library_list_tile.dart`、`folder_placeholder_cover.dart`、`folder_placeholder_style_dialog.dart`。
- 顶栏与选择：`useCompactMediaLibraryTopBar` / `MediaLibraryCompactTitle` / `MediaLibraryCompactIconButton` / `MediaLibraryCompactMoreButton`；`MediaLibrarySelectionDropTargets`、`MediaLibrarySelectionBottomBar`、`MediaLibraryRangeSelection`、`MediaLibraryItemInteractionWrapper`。没有名为 MediaLibraryCompactAppBar 的整页组件。
- 搜索：`showMediaLibrarySearchPrompt`、`buildMediaLibrarySearchResultsRoute`、`MediaLibrarySearchQuery`、`MediaLibraryLocateButton`。搜索结果禁止拖拽重排，播放走原父目录队列。
- 导入入口：`VideoActionButtons.showImportMenu` / `ImportSheetShortcutAction`（相册、文件、B站在线、压缩包、文件夹、FluentPack）；FAB `VideoActionButtons`；顶栏 `MediaLibraryTopBarImportProgress`。
- 下载与字幕工具：`VideoActionButtons.openBilibiliDownloadPage`、`openYtDlpDownloadPage`、`openBatchSubtitlePage`；桌面快捷键 `DesktopMediaManagementShortcutAction`。B站在线播放链接与下载页不是同一个动作。
- FluentPack：`PortableTransferNavigation`、`PortableTransferService`、`PortableIncomingClassification`。导入走 `LibraryService.importPortablePackageDirectory`，目标设备重映射新 ID。不要把 FluentPack 再塞进一个不区分来源的解析器。
- 分享/拖入：`IncomingShareListener`（main.dart 根级）和 `VideoActionButtons.processIncomingSharedItems` / `processDroppedPaths`。HomeScreen 仍有一份分享监听，批次只允许登记在实际入库点，禁止在两个 UI 监听器里各记一次。
- 导入事务：结构化目录/压缩包有 `_StructuredImportAccumulator`、`importedVideoIds`、失败 `_rollbackStructuredImportState`；本地文件导入与结构化导入都受 `_importOperationActive` / `_runExclusiveImport` 独占。重叠导入保持现有拒绝/忽略，不改成并发交错调度。
- 去重：`addSingleVideo(reuseExistingItem:)`；B站在线卡片禁止按 URL/指纹合并。
- 持久化：library.json schema 2，`_performLibrarySnapshotWrite` 临时文件/备份/重试；失败提示走 `LibraryPersistenceNotificationBridge`。`lastUpdated` 不是入库时间。
- 播放完成：`MediaPlaybackService._handlePlaybackCompleted` 先确认、再保存末尾、再把进度归零。继续学习必须另记完成事件。
- 封面文字：`VideoCollection.coverLabel` 为 null 表示跟随目录名；自定义字符串为该目录封面文字。全局是否显示由 `FolderPlaceholderSettings.showCoverText` 控制。不要再发明一套封面设置。
- 迷你播放卡与避让：`MediaLibraryOverlayKeys`、`PlaybackCardOverlayLayout`、`PlaybackActionButtonsLocation`。

## 保存什么，放在哪里

优先在现有 library.json 中增加一个有独立版本的活动元数据区，与现有快照一起序列化、备份和重试。可以抽出小模型/纯查询模块，但唯一写入口仍归 LibraryService。不要为本轮引入数据库、第二个媒体库、事件总线或新的状态管理框架。

最小逻辑数据：
- 每媒体 ID：addedAtMs（可空）、lastPlayedAtMs（可空）、当前观看周期已累计的有效时间、完成状态、隐藏状态。现有 lastPositionMs/durationMs 继续是位置/时长来源，不另存一份。
- 导入批次：ID、开始时间、简短标题、来源种类、目标目录 ID（可空）、本次新创建媒体的有序 ID。批次成员关系单点保存，不在多处维护独立可变清单。
- 固定项：有序 ID 列表，引用现有媒体/目录；通过实际对象获取标题和封面。
- 界面偏好：保存在 SettingsService 的 `_createRegisteredSettings` / `updateSetting` 机制中，与媒体数据分离。

旧库缺新字段时安全加载、幂等迁移。无可靠时间的旧进度放“之前未看完”，不伪造 lastPlayedAt；不能凭 lastUpdated 回填导入/播放时间。永久删除走 `deleteFromRecycleBin`，须清理引用；软删除走 `moveToRecycleBin`，恢复走 `restoreFromRecycleBin`，恢复后仍保留原固定顺序。

FluentPack 作为内容迁入：使用目标设备的新 ID 和本次入库时间；保留原来支持的进度、字幕和封面，不自动携带来源设备的批次 ID、固定状态、隐藏状态和最近观看时间。`applyPortableMediaMetadata` 可以继续恢复 lastPositionMs 等已有字段。不改变 FluentPack 格式版本来承载本轮本地活动元数据，也不破坏原有旧包读取。活动数据不得写入 `VideoItem.toJson`，否则会随包泄露。

导入遵守现有去重/独立卡片策略。B站相同链接现在允许建立独立卡片，不可擅自合并。复用/恢复已有 ID 不算新建，不改原 addedAt。取消或回滚不能留下指向未提交媒体的批次。

## 最新 UI 必须保留

新全局视图沿用 home 样式，目录/批次详情沿用 collection 样式。允许增加小型分组标题/信息槽和根页轻量入口切换，不另建一套几何计算或样式设置。
home_screen.dart / collection_screen.dart 已经很大：新视图必须抽成小型 widget 挂到现有宿主，禁止再复制这两个巨型页面，也禁止把整套逻辑继续堆进它们。
保留按横竖屏/首页与目录区分的样式、自定义列数和间距、选择态投放区、FluentPack 选择导出、迷你播放卡、导入进度条、键盘/鼠标/触控、右键进入选择、范围选择。
切换入口前退出旧选择模式并清空其选中 ID，不将目录拖拽索引带进虚拟结果。

## 范围和复杂度

本轮不做：独立学习首页、新课程实体、主题合集/标签体系、智能规则编辑器、全文字幕索引、推荐、打卡、统计、知识图谱、笔记编辑器、自动跨目录关联、后台全盘找文件、顶栏动作体系重做、并发导入调度、固定区拖拽排序。
导入失败沿用当前事务边界：目录/压缩包原有整批回滚继续有效；允许逐项成功的入口才展示部分成功。不为了“重试”新造一套持久任务调度。可安全重试的既有任务只重试失败项，其他入口说明重新选择。
最近批次和继续记录按需构建、惰性展示；不要每个播放 tick 扫描整个库、探测文件系统或重建主页。资料更名、移动、回收后按稳定 ID 更新。
不改原生后端、字幕排版、下载协议/网络重试、压缩包安全策略、媒体资源归属或版权/登录流程。

## 阅读与验证

先读当前阶段定位的函数，再读必要调用者。不得全文读取大型项目介绍或播放器文件来“熟悉架构”。
复用已有测试，再对新增的状态规则、迁移、实际集成路径补必要测试；不以源码字符串存在性代替行为测试。
阶段完成记录真实命令、通过/失败/未运行原因。只格式化改动 Dart 文件；保留既有失败，不顺手大修其他模块。
参考机制仅供解释，不要求执行 AI 再上网： [Reader 的预设视图](https://docs.readwise.io/reader/guides/filtering/default-views)、[Eagle 跨子目录浏览](https://en.eagle.cool/blog/post/subfolder-content-display-efficiency)。
