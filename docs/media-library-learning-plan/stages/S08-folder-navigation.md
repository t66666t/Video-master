# S08：面包屑、跨子目录浏览与搜索上下文

依赖 S07。目标是减少目录点击，不改用户的真实目录和手动排列。
搜索、定位、搜索结果禁止重排已经存在：本阶段不要重建搜索。

## 最小阅读

- `collection_screen.dart`：`build` 顶栏、`_visibleContents`、`_openParentDirectory`、`_showInParentDirectory` 及列表/卡片生成处。当前标题只显示 `collection.name`。
- `library_service.dart`：`getContents`、`getVideosInFolder`、`searchContents`；只读必要遍历与顺序规则。
- `media_library_locate_button.dart`、`media_library_item_interaction_wrapper.dart`、`media_library_selection_drop_targets.dart`。
- `media_library_search_query.dart` 仅确认现有匹配语义；相关 search/locate/search_prompt 测试。

拟新增：小型面包屑 widget，例如 `lib/widgets/media_library_folder_breadcrumb.dart`；跨层浏览可以是 LibraryService 上的只读投影函数，不要写成第二套 getContents。

## 实施

1. 目录页显示可点击的“媒体库 > … > 当前目录”。窄屏保留根入口和当前名，中间祖先可折叠菜单，不能把 `useCompactMediaLibraryTopBar` 的 50px 顶栏撑宽。搜索结果页不显示目录面包屑。
2. 根入口一击回全局文件夹视图，不堆叠多个 HomeScreen；返回上级保留原项位置。搜索定位来的目录仍能返回原搜索结果（现有 `returnToSearchResults`）。
3. 增加当前目录“包含子文件夹内容”开关，默认关闭；同会话对访问过目录可记忆，跨启动只需恢复最后目录开关，不能无限增加设置项。
4. 开启时，遍历当前目录及后代媒体，按既有 children 顺序深度优先展开；每个 ID 最多出现一次，循环/孤儿树安全结束。仅生成只读投影，不改真实 childrenIds。
5. 展示相对目录路径帮助区分“第一课”。目录名匹配搜索不自动让所有后代命中；标题匹配规则保持 `MediaLibrarySearchQuery` 原测试语义。
6. 开启跨层浏览、搜索、最近添加和继续学习时均禁止虚拟重排，不能把虚拟 index 传给原目录 `reorderItems` / `reorderMultipleItems`。批量整理使用定位回真实目录的已有流程（`MediaLibraryLocateButton`）。
7. 搜索全局可达；返回保留关键词、滚动与来源入口。点击结果和跨层媒体仍播放原父目录队列，不沿扁平列表连播。
8. 操作路径基于库内目录名称；不要在普通卡片上暴露冗长绝对系统路径。文件失联等诊断场景另按需提供。

## 测试与体验核对

建立内存目录树：A/章1、A/章2/B、同名目录、回收祖先、损坏环；验证顺序、过滤、去重和不修改原树。
组件验证：面包屑祖先跳转、搜索→定位→返回、切换开关位置恢复、窄屏菜单。
回归 `search_playback_queue_test.dart`、`media_library_search_query_test.dart`、`media_library_search_prompt_test.dart`、`media_library_locate_button_test.dart`、`media_library_selection_drop_targets_test.dart`。
新投影列表不可接受原目录重排拖放，即使键盘快捷键触发也一样。
