# S09：整理操作入口，保持新版布局和现有功能可达

依赖 S08。本阶段只改入口组织，不改下载/字幕/导出业务逻辑。

## 定向阅读

- home_screen.dart / collection_screen.dart：顶栏动作、floatingActionButton、选择态底栏。
- video_action_buttons.dart：build、importVideos、导入入口枚举、批量字幕/下载导航；不要通读文件扫描逻辑。
- media_library_compact_app_bar.dart、media_library_selection_bottom_bar.dart。
- portable_transfer_navigation.dart：现有统一入口；desktop_media_management_shortcuts.dart：被移动动作的映射。

## 布局决策与理由

1. 常态根页突出搜索、添加、更多；卡片/列表切换仍可快速使用。窄屏按现有compact规则收纳，不为“大而全”新增第二排图标墙。
2. “添加”收纳媒体文件、文件夹、压缩包、B站在线播放链接和FluentPack导入。保留各自实际选择/预览流程，不把不同格式扔进一个不区分来源的解析器。
3. 下载工具继续可进入原任务页。用户能明确区分“添加B站在线播放链接”和“下载”，不把联网/离线行为混成同一个动作。
4. 更多操作收纳下载任务入口、批量字幕工具、回收站、媒体库样式/设置等。大文件目录和导出设置等低频功能保留，平台限制沿用现有代码。
5. 选择态复用已更新的移动到上级/回收投放区、重命名和FluentPack导出底栏；不要复制一套手机底栏，也不要删掉当前刚加入的导出动作。
6. 字幕生成仍能从当前目录带范围进入；通过全局入口进入时明确作用范围。不要因为入口合并而把当前目录批量任务变成全库操作。
7. 导入/下载进行中仍有可见状态入口，任务不会因菜单关闭丢失。保留迷你播放器和顶部导入进度现有避让。
8. 现有快捷键继续调用同一动作。把键盘提示和菜单标签保持一致，不要求用户重新学习所有快捷键。
9. 桌面更多菜单、移动底部菜单复用同一组动作定义即可，不建立抽象插件框架。删掉重复可见入口，但不要删掉业务能力或已保存样式偏好。

## 验收

针对每个原动作列“旧入口→新入口→范围/平台”短表，确认无功能失踪。
手机窄屏、手机横屏、平板、Windows窗口下：弹窗无溢出，媒体卡、进度条、选择态和播放器互不遮挡；触摸长按/桌面拖动原行为仍可用。
运行受影响 compact_app_bar、selection_bottom_bar相关既有测试（有则复用）、selection_drop_targets、item_interaction_wrapper、layout_profile 与 portable_incoming_classification 测试。
简单菜单位置调整不写镜像式测试；重点测错误范围、丢失入口、窄屏溢出和已有导出动作。

