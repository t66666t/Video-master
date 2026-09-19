# S04：在 4.4 UI 上接入三个入口与返回状态

依赖 S03。此阶段只完成小型导航骨架和状态；新内容视图在 S05/S07 接入。尚未可用的入口不暴露为能点击的空功能。
原“整理顶栏动作”已取消：本阶段必须把现有 chrome 当作约束，而不是再设计一套菜单。

## 最小阅读

- `home_screen.dart`：`build`、`_openSearch`、`_buildCompactTopBarActions`、FAB `VideoActionButtons`、`revealItemId` / `returnToSearchResults`、`MediaLibraryOverlayKeys` 使用处。
- `collection_screen.dart`：构造函数、`CollectionScreen.search`、`_showInParentDirectory`、`_openParentDirectory`、返回与搜索入口。
- `media_library_compact_app_bar.dart`、`media_library_search_prompt.dart`、`media_library_layout_profile.dart`、`playback_card_layout.dart`（`MediaLibraryOverlayKeys` / `PlaybackCardOverlayLayout`）。
- `settings_service.dart`：`_createRegisteredSettings`；`main.dart` 仅在启动恢复必须挂接时定位 `HomeScreen` 创建处（`home: const HomeScreen()`）。
- `test/media_library_overlay_identity_test.dart`、`test/media_library_compact_app_bar_test.dart`、`test/media_library_search_prompt_test.dart`。

拟新增：小型入口切换 widget，例如 `lib/widgets/media_library_entry_switcher.dart`。不要新建第二个 HomeScreen。

## 实施约束与理由

1. 根页增加“继续学习 / 最近添加 / 文件夹”的轻量切换区。优先替换或紧挨标题“我的媒体库”，不得新增第二排图标墙。窄屏继续用 `useCompactMediaLibraryTopBar`。目录页、搜索结果页不放切换器。
2. 新装默认最近添加；首次升级旧库默认文件夹。用户已经选过入口则优先恢复选择。旧库判断使用数据迁移/已有内容证据，不把“初始化尚未读完”或 FirstOpenUiWarmup 当空库。
3. 三个入口各保留滚动/展开状态；文件夹入口保留最后真实目录。优先记录稳定项/批次 ID 作为可见锚点及必要偏移，布局变化或内容删除时安全回退，不能只用旧像素值跳进错误项目。跨启动只持久化有限导航状态，不保存整个路由树或全部目录滚动历史。
4. 进入播放器、批次详情、固定目录、搜索后返回，应回到原入口和位置。显式“定位到文件夹”则进入文件夹入口并高亮原项。搜索继续 `showMediaLibrarySearchPrompt` → `buildMediaLibrarySearchResultsRoute(CollectionScreen.search(...))`。
5. 尤其保留 `HomeScreen(revealItemId..., returnToSearchResults...)` 的用途：定位导航必须强制展示真实目录，不被最近使用的全局入口覆盖；返回搜索结果不能绕回错误的主页副本。`returnToSearchResults` 的 HomeScreen 不要再次订阅分享/剪贴板。
6. 初始化完成后再恢复目录；目录已删除/回收时回退到最近有效祖先或根目录，不连续推入多个重复路由。
7. 切换入口前退出旧选择模式并清空其选中 ID，不将目录拖拽索引带进虚拟结果。`MediaLibraryOverlayKeys`、迷你播放卡、导入进度、FAB 避让、选择投放区与底栏必须保持。
8. 现有动作必须仍可达，且走同一函数：搜索、导入表、FluentPack `PortableTransferNavigation`、回收站、卡片样式、媒体库设置、定时关闭、全屏、大文件目录、导出设置、批量管理、B站下载、YT-DLP、批量字幕、范围选择、右键选择。不要把桌面宽屏顶栏收成手机溢出菜单，也不要删除刚加入的 FluentPack 导出底栏。
9. 根据最新版布局组件扩展小块切换 UI。严禁复制 HomeScreen；新视图抽成小型 widget。S05/S07 显露剩余入口；S10 不得留下未接入占位或临时开关。

## 验证

用注入的轻量内容构建器验证导航状态，不用加载全部播放器：

- 入口切换、详情返回、搜索返回、定位真实目录。
- 重启恢复；初始化延迟和缺失目录回退。
- 手机窄屏/横屏切换，顶栏、导入进度和迷你播放卡不覆盖切换区。
- 现有回收投放区与选择态仍显示；切换入口不会误移动旧选择项。
- 用户旧样式设置、封面配置、快捷键和导入表未被新默认值覆盖。
- 搜索提示、overlay identity、compact 顶栏既有测试仍通过。

本阶段可先把导航状态与切换组件通过测试准备好，只挂载已经具备内容的入口。
