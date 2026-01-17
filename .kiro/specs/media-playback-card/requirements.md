# 需求文档

## 简介

本功能为视频播放器应用添加媒体播放列表管理和底部快捷播放卡片功能。该功能卡片类似于音乐应用（如网易云音乐、Spotify）底部的迷你播放器，允许用户在退出全屏播放页面后继续控制媒体播放，支持后台播放、耳机控制和系统通知栏控制。

## 术语表

- **Playback_Card**: 底部快捷播放功能卡片，显示当前播放媒体的信息和控制按钮
- **Media_Player_Service**: 媒体播放服务，负责后台播放、进度记录和系统媒体控制集成
- **Playlist_Manager**: 播放列表管理器，管理当前播放队列和同文件夹媒体列表
- **Progress_Tracker**: 进度追踪器，负责实时记录和恢复播放进度
- **System_Media_Controller**: 系统媒体控制器，处理耳机按键、通知栏控制和锁屏控制
- **Responsive_Layout**: 响应式布局系统，根据设备类型和屏幕尺寸调整UI

## 需求

### 需求 1：底部播放卡片显示

**用户故事：** 作为用户，我希望在退出媒体播放页面后能看到一个底部播放卡片，以便我可以快速查看当前播放状态并进行控制。

#### 验收标准

1. WHEN 用户从媒体播放页面返回到媒体管理页面 THEN Playback_Card SHALL 以优雅的滑入动画出现在屏幕底部
2. WHEN 用户进入媒体播放页面 THEN Playback_Card SHALL 以优雅的滑出动画消失
3. WHEN 没有正在播放或暂停的媒体 THEN Playback_Card SHALL 不显示
4. THE Playback_Card SHALL 显示在媒体管理页面底部，不遮挡媒体卡片内容
5. THE Playback_Card SHALL 包含媒体缩略图、标题、播放控制栏和列表展开按钮

### 需求 2：播放卡片布局与响应式设计

**用户故事：** 作为用户，我希望播放卡片在不同设备（手机、平板、电脑）上都能正确显示且美观，以便我在任何设备上都有良好的使用体验。

#### 验收标准

1. WHEN 在手机设备上显示 THEN Responsive_Layout SHALL 将卡片高度设置为约80-90dp，字体大小适配小屏幕
2. WHEN 在平板设备上显示 THEN Responsive_Layout SHALL 将卡片高度设置为约90-100dp，字体大小适配中等屏幕
3. WHEN 在桌面设备上显示 THEN Responsive_Layout SHALL 将卡片高度设置为约70-80dp，字体大小适配大屏幕
4. THE Playback_Card SHALL 在第一行从左至右显示：缩略图、标题（宽度不足时循环滚动）、列表展开按钮
5. THE Playback_Card SHALL 在第二行显示：进度条、上一集按钮、播放/暂停按钮、下一集按钮、静音按钮
6. WHEN 标题文本宽度超过可用空间 THEN Playback_Card SHALL 以缓慢循环滚动方式展示完整标题

### 需求 3：播放列表展开功能

**用户故事：** 作为用户，我希望能够展开播放列表查看同文件夹下的所有媒体，以便我可以快速切换到其他媒体。

#### 验收标准

1. WHEN 用户点击列表展开按钮 THEN Playlist_Manager SHALL 显示当前媒体所在文件夹的所有媒体列表
2. THE 展开的列表 SHALL 从上到下依次显示媒体名称
3. WHEN 用户点击列表中的某个媒体 THEN Media_Player_Service SHALL 切换到该媒体并从记忆的播放位置开始播放
4. WHEN 用户再次点击列表展开按钮或点击列表外区域 THEN 列表 SHALL 收起
5. THE 展开列表 SHALL 高亮显示当前正在播放的媒体项

### 需求 4：播放控制功能

**用户故事：** 作为用户，我希望能够通过播放卡片控制媒体播放，以便我无需进入全屏播放页面就能进行基本操作。

#### 验收标准

1. WHEN 用户点击播放/暂停按钮 THEN Media_Player_Service SHALL 切换播放状态
2. WHEN 用户点击上一集按钮 THEN Media_Player_Service SHALL 切换到播放列表中的上一个媒体，并从该媒体记忆的播放位置开始播放
3. WHEN 用户点击下一集按钮 THEN Media_Player_Service SHALL 切换到播放列表中的下一个媒体
4. WHEN 用户拖动进度条 THEN Media_Player_Service SHALL 精确跳转到指定位置
5. WHEN 用户点击静音按钮 THEN Media_Player_Service SHALL 切换静音状态，行为与播放页面内的静音按钮一致
6. THE 进度条 SHALL 与当前媒体播放进度实时同步

### 需求 5：后台播放支持

**用户故事：** 作为用户，我希望媒体能够在后台继续播放，以便我可以在使用其他应用时继续收听/观看。

#### 验收标准

1. WHEN 用户切换到其他应用或锁屏 THEN Media_Player_Service SHALL 继续播放媒体
2. WHEN 媒体在后台播放时 THEN System_Media_Controller SHALL 在系统通知栏显示媒体控制界面
3. THE 通知栏控制界面 SHALL 显示媒体标题、封面、播放/暂停按钮、上一集/下一集按钮
4. WHEN 用户通过通知栏控制媒体 THEN Media_Player_Service SHALL 响应相应操作

### 需求 6：耳机控制支持

**用户故事：** 作为用户，我希望能够通过耳机按键控制媒体播放，以便我在不看屏幕时也能操作。

#### 验收标准

1. WHEN 用户按下耳机播放/暂停键 THEN System_Media_Controller SHALL 切换播放状态
2. WHEN 用户按下耳机下一曲键 THEN System_Media_Controller SHALL 切换到下一个媒体
3. WHEN 用户按下耳机上一曲键 THEN System_Media_Controller SHALL 切换到上一个媒体
4. THE System_Media_Controller SHALL 在Android、iOS和Windows平台上正确响应耳机控制

### 需求 7：播放进度持久化

**用户故事：** 作为用户，我希望播放进度能够被自动保存，以便我在意外退出应用后能够从上次位置继续播放。

#### 验收标准

1. WHILE 媒体正在播放 THEN Progress_Tracker SHALL 定期保存当前播放位置（间隔不超过5秒）
2. WHEN 用户暂停播放 THEN Progress_Tracker SHALL 立即保存当前播放位置
3. WHEN 用户切换媒体 THEN Progress_Tracker SHALL 保存当前媒体的播放位置
4. WHEN 应用意外退出后重新启动 THEN Progress_Tracker SHALL 恢复上次的播放状态和位置
5. THE Progress_Tracker SHALL 使用高效的存储策略，不影响应用性能
6. WHEN 用户选择播放某个媒体 THEN Media_Player_Service SHALL 从该媒体记忆的播放位置开始播放

### 需求 8：动画与性能优化

**用户故事：** 作为用户，我希望播放卡片的动画流畅且不影响应用性能，以便我有良好的使用体验。

#### 验收标准

1. THE Playback_Card 的出现和消失动画 SHALL 在300毫秒内完成
2. THE 动画 SHALL 使用硬件加速以确保流畅性
3. THE 标题滚动动画 SHALL 平滑且不消耗过多CPU资源
4. WHEN 播放卡片显示时 THEN 应用 SHALL 保持60fps的帧率
5. THE Progress_Tracker 的保存操作 SHALL 异步执行，不阻塞UI线程

### 需求 9：视觉设计一致性

**用户故事：** 作为用户，我希望播放卡片的外观与应用整体设计风格一致，以便获得统一的视觉体验。

#### 验收标准

1. THE Playback_Card SHALL 使用与应用一致的深色主题配色（背景色 #1E1E1E 或 #2C2C2C）
2. THE Playback_Card SHALL 使用圆角设计（圆角半径约12-16dp）
3. THE 按钮和图标 SHALL 使用与应用一致的图标风格和颜色
4. THE 进度条 SHALL 使用与播放页面一致的样式
5. THE Playback_Card SHALL 有适当的阴影效果以区分层次

