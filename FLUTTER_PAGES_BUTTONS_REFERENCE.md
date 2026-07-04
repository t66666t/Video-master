# Flutter 页面与按钮功能对照文档（Code-English Mapping）

## 1) 页面总览（Class Name）

| Page Class (代码英文) | 中文解释 |
|---|---|
| `HomeScreen` | 主媒体库首页 |
| `CollectionScreen` | 合集详情页 |
| `BatchImportScreen` | 批量导入媒体与字幕页面 |
| `BilibiliDownloadScreen` | Bilibili 下载页面 |
| `RecycleBinScreen` | 回收站页面 |
| `RecycledFolderDetailScreen` | 回收站内文件夹详情页 |
| `PortraitVideoScreen` | 竖屏播放器页面 |
| `VideoPlayerScreen` | 横屏播放器页面 |
| `SubtitlePreviewScreen` | 字幕预览页面 |
| `SimpleVideoPreviewScreen` | 简易视频预览页面 |
| `SimpleVideoPlayerScreen` | 简易视频播放器页面 |

---

## 2) 页面按钮与功能（仅保留名称与用途，不讲实现）

## `HomeScreen`

### AppBar 按钮

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| `IconButton(Icons.close)` | `setState(...)` 清空 `_selectedIds` 并退出 `_isSelectionMode` | 退出批量选择模式 |
| `IconButton(Icons.fullscreen / Icons.fullscreen_exit)` | `settings.toggleFullScreen()` | 切换全屏（桌面） |
| `IconButton(Icons.folder_open)` | `_showLargeDataPathDialog(context)` | 打开大文件目录设置 |
| `IconButton(Icons.file_download)` | `_exportSettingsSnapshot()` | 导出设置快照 |
| `IconButton(Icons.delete_outline)` | `Navigator.push(RecycleBinScreen)` | 打开回收站 |
| `IconButton(Icons.tune)` | `_showCardStyleBottomSheet(...)` | 调整卡片样式 |
| `IconButton(Icons.checklist)` | `setState(_isSelectionMode = true)` | 进入批量管理 |
| `IconButton(Icons.select_all)` | `setState(...)` | 全选/取消全选 |

### 选择模式底部栏

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| `TextButton.icon(Icons.delete)` | `library.moveToRecycleBin(...)` | 将选中项移入回收站 |
| `TextButton.icon(Icons.edit)` | `_showRenameDialog(...)` | 重命名单个选中项 |

### 弹窗按钮

| Dialog (代码英文) | Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|---|
| `_showRenameDialog` | `TextButton("取消")` | `Navigator.pop(context)` | 取消重命名 |
| `_showRenameDialog` | `TextButton("确定")` | `library.renameItem(id, ...)` | 确认重命名 |
| `_showLargeDataPathDialog` | `ElevatedButton("选择目录")` | `FilePicker.platform.getDirectoryPath()` | 选择大文件目录 |
| `_showLargeDataPathDialog` | `TextButton("恢复默认")` | `setState(tempPath = defaultPath)` | 恢复默认目录 |
| `_showLargeDataPathDialog` | `TextButton("取消")` | `Navigator.pop(context)` | 取消目录修改 |
| `_showLargeDataPathDialog` | `ElevatedButton("应用并迁移")` | `library.migrateLargeDataRoot(tempPath)` | 应用并迁移数据目录 |

### 浮动操作区（复用组件）

- 使用 `VideoActionButtons`（见第 3 节 `VideoActionButtons`）。

### 迷你播放卡（复用组件）

- 使用 `MiniPlaybackCard`（见第 3 节 `MiniPlaybackCard`）。

---

## `CollectionScreen`

### AppBar 按钮

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| `IconButton(Icons.close)` | `setState(...)` 清空选择并退出选择模式 | 退出批量选择模式 |
| `BackButton()` | `Navigator.maybePop()` | 返回上一页 |
| `IconButton(Icons.tune)` | `_showCardStyleBottomSheet(...)` | 调整卡片样式 |
| `IconButton(Icons.checklist)` | `setState(_isSelectionMode = true)` | 进入批量管理 |
| `IconButton(Icons.select_all)` | `setState(...)` | 全选/取消全选 |

### 选择模式底部栏

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| `TextButton.icon(Icons.delete)` | `library.moveToRecycleBin(...)` | 将选中项移入回收站 |
| `TextButton.icon(Icons.edit)` | `_showRenameDialog(...)` | 重命名单个选中项 |

### 弹窗按钮

| Dialog (代码英文) | Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|---|
| `_showRenameDialog` | `TextButton("取消")` | `Navigator.pop(context)` | 取消重命名 |
| `_showRenameDialog` | `TextButton("确定")` | `library.renameItem(id, ...)` | 确认重命名 |

### 浮动操作区（复用组件）

- 使用 `VideoActionButtons`（见第 3 节 `VideoActionButtons`）。

### 迷你播放卡（复用组件）

- 使用 `MiniPlaybackCard`（见第 3 节 `MiniPlaybackCard`）。

---

## `BatchImportScreen`

### 顶部按钮

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| `IconButton(Icons.remove)` | `batch.setFontSize(...)` | 缩小列表字号 |
| `IconButton(Icons.add)` | `batch.setFontSize(...)` | 增大列表字号 |
| `ElevatedButton.icon(Icons.video_library)` | `_pickVideos()` | 导入媒体 |
| `ElevatedButton.icon(Icons.subtitles)` | `_pickSubtitles()` | 导入字幕（支持 zip） |
| `IconButton(Icons.help_outline)` | `_showHelpDialog()` | 打开操作说明 |

### 行级操作

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| `IconButton(Icons.merge_type)` | `_handleMerge(videoPath, subtitlePath, ...)` | 合并导入媒体+字幕 |
| `IconButton(Icons.undo)` | `_handleUndo(videoPath)` | 撤销该媒体导入 |
| `IconButton(Icons.delete)` | `batch.removeRow(...)` | 删除该行映射 |
| `InkWell(onTap)` on media row | `Navigator.push(SimpleVideoPreviewScreen)` | 预览媒体 |
| `InkWell(onTap)` on subtitle row | `Navigator.push(SubtitlePreviewScreen)` | 预览字幕 |

### 导入类型弹窗

| Dialog (代码英文) | Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|---|
| `_showImportTypeDialog` | `ListTile(Icons.photo_library)` | `Navigator.pop(context, 'gallery')` | 从相册导入 |
| `_showImportTypeDialog` | `ListTile(Icons.folder_open)` | `Navigator.pop(context, 'file_manager')` | 从文件管理导入 |
| `_showImportTypeDialog` | `TextButton("取消")` | `Navigator.pop(context)` | 取消导入 |

### 帮助弹窗

| Dialog (代码英文) | Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|---|
| `_showHelpDialog` | `TextButton("我知道了")` | `Navigator.pop(context)` | 关闭帮助说明 |

---

## `BilibiliDownloadScreen`

### AppBar 按钮

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| `IconButton(Icons.delete_sweep)` | `_deleteAllTasks(service)` | 清空任务 |
| `IconButton(Icons.settings)` | `_showDownloadSettings(service)` | 打开下载设置 |
| `IconButton(Icons.person)` | `_showCookieDialog(service)` | 打开登录/Cookie 设置 |

### 输入区按钮

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| `IconButton(Icons.paste)` | `Clipboard.getData(...)` | 粘贴文本到输入框 |
| `IconButton(Icons.clear)` | `_inputController.clear()` | 清空输入框 |
| `IconButton(Icons.keyboard_return)` | `TextEditingValue(...)` | 在光标位置插入换行 |
| `ElevatedButton("解析")` | `_parseVideo(service)` | 解析 BV/链接，生成任务 |

### 单集行按钮

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| `IconButton(Icons.refresh)` | `service.fetchEpisodeInfo(ep)` | 刷新该集信息 |
| `IconButton(Icons.pause)` | `service.pauseDownload(ep)` | 暂停该集下载 |
| `IconButton(Icons.download / Icons.replay / Icons.hourglass_top)` | `service.startSingleDownload(ep)` 或 `service.pauseDownload(ep)` | 加入排队/继续/重试/退出排队 |
| `PopupMenuButton<String>` value=`'top'` | `service.startSingleDownload(ep, toTop: true)` | 插队下载 |
| `PopupMenuButton<String>` value=`'export'` | `_importToLibrary(service, episode: ep)` | 导出该集到媒体库 |
| `PopupMenuButton<String>` value=`'preview_sub'` | `_showSubtitlePreview(service, ep.selectedSubtitle!)` | 预览该集字幕 |
| `PopupMenuButton<String>` value=`'delete'` | `service.removeEpisode(ep, task)` | 删除该集任务 |
| `InkWell(onTap)` on completed title | `_previewVideo(ep)` | 预览已完成视频 |

### 底部栏按钮

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| `_buildBottomAction(Icons.select_all)` | `service.selectAll` | 全选任务 |
| `_buildBottomAction(Icons.download)` | `service.startDownloadSelected` | 下载并合并选中任务 |
| `_buildBottomAction(Icons.pause)` | `service.pauseSelected` | 暂停选中任务 |
| `_buildBottomAction(Icons.file_upload)` | `_importToLibrary(service)` | 导入选中任务到媒体库 |
| `_buildBottomAction(Icons.delete)` | `service.removeSelected` | 移除选中任务 |

### 常用弹窗按钮

| Dialog (代码英文) | Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|---|
| delete/confirm dialog | `TextButton("取消")` | `Navigator.pop(...)` | 取消操作 |
| delete/confirm dialog | `TextButton("确定"/"删除")` | 对应确认方法 | 确认执行操作 |
| `_showDownloadSettings` | `TextButton("取消")` | `Navigator.pop(context)` | 取消设置 |
| `_showDownloadSettings` | `TextButton("保存")` | `service.updateSettings(...)` | 保存下载设置 |

---

## `RecycleBinScreen`

### AppBar 按钮

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| `IconButton(Icons.select_all)` | `setState(...)` | 全选/反选 |
| `IconButton(Icons.close)` | `setState(...)` | 退出选择模式 |
| `IconButton(Icons.checklist)` | `setState(_isSelectionMode = true)` | 进入选择模式 |

### 列表项操作

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| `IconButton(Icons.restore)` | `library.restoreFromRecycleBin([id])` | 还原单条 |
| `ListTile.onTap` | `_navigateToFolderDetail(...)` / `_openRecycleBinVideo(...)` | 打开回收站文件夹或播放视频 |

### 选择模式底部栏

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| `TextButton.icon(Icons.restore)` | `library.restoreFromRecycleBin(...)` | 还原选中项 |
| `TextButton.icon(Icons.delete_forever)` | `showDialog(...)` | 打开彻底删除确认弹窗 |
| confirm dialog `TextButton("取消")` | `Navigator.pop(ctx)` | 取消彻底删除 |
| confirm dialog `TextButton("删除")` | `library.deleteFromRecycleBin(...)` | 确认彻底删除 |

---

## `RecycledFolderDetailScreen`

- 主要为只读详情浏览页面，核心交互是列表 `onTap` 打开子文件夹或播放项。
- 无独立业务按钮栏（除系统返回按钮）。

---

## `PortraitVideoScreen`

### 播放工具栏按钮

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| `PopupMenuButton<double>` | `settings.updateSetting('playbackSpeed', speed)` + `_controller.setPlaybackSpeed(speed)` | 设置倍速 |
| `IconButton(Icons.subtitles / Icons.subtitles_off)` | `_setFloatingSubtitles(...)` | 字幕开关 |
| `IconButton(Icons.volume_up / Icons.volume_off)` | `_controller.setVolume(...)` | 静音/取消静音 |

### 外置播放控制按钮

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| `IconButton(Icons.skip_previous)` | `playbackService.playPrevious(...)` | 上一集 |
| `InkWell(Icons.replay)` | `playbackService.seekTo(pos)` / `_controller.seekTo(pos)` | 快退指定秒数 |
| `IconButton(Icons.play_circle_fill / Icons.pause_circle_filled)` | `_togglePlay()` | 播放/暂停 |
| `InkWell(flipped Icons.replay)` | `playbackService.seekTo(pos)` / `_controller.seekTo(pos)` | 快进指定秒数 |
| `IconButton(Icons.skip_next)` | `playbackService.playNext(...)` | 下一集 |
| `IconButton(Icons.fullscreen)` | `_goToLandscape()` | 切换到横屏播放器 |

---

## `VideoPlayerScreen`

- 本页按钮主要由嵌入组件提供，见第 3 节组件按钮总表。
- 页面层关键动作：`_handleBackRequest()`（返回）、`_handleExit()`（退出）、侧栏切换 `SidebarType`。

---

## `SubtitlePreviewScreen`

- 该页无业务按钮（除系统返回按钮），主要用于字幕内容只读预览。

---

## `SimpleVideoPreviewScreen`

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| `ElevatedButton("返回")` | `Navigator.of(context).maybePop()` | 返回上一页 |
| `IconButton(Icons.play_arrow / Icons.pause)` | `playbackService.resume()` / `playbackService.pause()` | 播放/暂停 |

---

## `SimpleVideoPlayerScreen`

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| `ElevatedButton("返回")` | `Navigator.of(context).maybePop()` | 返回上一页 |
| `VideoProgressIndicator(allowScrubbing: true)` | 进度拖拽由组件内置行为处理 | 拖动进度条定位播放 |

---

## 3) 关键复用组件按钮总表（页面内实际可见）

## `VideoActionButtons`

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| `FloatingActionButton heroTag="add_folder_*"` | `showCreateCollectionDialog(...)` | 新建合集 |
| `FloatingActionButton heroTag="add_video_*"` | `importVideos(...)` | 导入视频或音频 |
| `FloatingActionButton heroTag="bbdown_download_*"` | `Navigator.push(BilibiliDownloadScreen)` | 打开 B 站下载页 |
| `FloatingActionButton heroTag="batch_import_*"` | `Navigator.push(BatchImportScreen)` | 打开批量导入页 |
| `FloatingActionButton.small heroTag="collapse_toggle_*"` | `settings.updateSetting('isActionButtonsCollapsed', ...)` | 展开/收起按钮组 |
| `ElevatedButton("新建合集")` | `showCreateCollectionDialog(...)` | 横向模式新建合集 |
| `ElevatedButton("导入视频或音频")` | `importVideos(...)` | 横向模式导入媒体 |
| `ElevatedButton("批量导入媒体")` | `Navigator.push(BatchImportScreen)` | 横向模式批量导入 |
| `ElevatedButton("B站下载")` | `Navigator.push(BilibiliDownloadScreen)` | 横向模式进入 B 站下载 |

## `MiniPlaybackCard`

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| `IconButton(Icons.queue_music)` | `_showPlaylistBottomSheet(context)` | 打开播放列表 |
| `IconButton(Icons.skip_previous)` | `playbackService.playPrevious()` | 上一集 |
| `IconButton(Icons.play_arrow / Icons.pause)` | `playbackService.resume()` / `playbackService.pause()` | 播放/暂停 |
| `IconButton(Icons.skip_next)` | `playbackService.playNext()` | 下一集 |
| `IconButton(Icons.volume_up / Icons.volume_off)` | `playbackService.toggleMute()` | 静音切换 |
| `IconButton(Icons.keyboard_arrow_left_rounded)` | `playbackService.seekToPreviousSubtitle()` | 上一句字幕 |
| `IconButton(Icons.keyboard_arrow_right_rounded)` | `playbackService.seekToNextSubtitle()` | 下一句字幕 |

## `PlaylistBottomSheet`

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| `SwitchListTile` (`_autoPlay`) | `_saveAutoPlayState(value)` | 自动播放开关 |
| `ListTile` on item | `widget.onItemTap(item, _autoPlay)` | 切换到指定播放项 |

## `VideoControlsOverlay`（横屏主控制层）

| Button Identifier (代码英文) | Callback/Action (代码英文) | 中文功能说明 |
|---|---|---|
| `IconButton(Icons.close)` | `widget.onExitPressed ?? widget.onBackPressed` | 关闭播放页（Windows） |
| `IconButton(Icons.arrow_back)` | `widget.onBackPressed()` | 返回 |
| `IconButton(Icons.settings)` | `widget.onOpenSettings()` | 打开设置侧栏 |
| `IconButton(Icons.subtitles)` | `widget.onOpenSubtitleManager()` | 打开字幕管理 |
| `IconButton(Icons.style)` | `widget.onToggleFloatingSubtitleSettings()` | 打开字幕样式侧栏 |
| `IconButton(Icons.open_with)` | `widget.onMoveSubtitles()` | 进入字幕拖动模式 |
| `IconButton(Icons.menu / Icons.menu_open)` | `widget.onToggleSidebar()` | 侧栏显隐切换 |
| `IconButton(Icons.fullscreen / Icons.fullscreen_exit)` | `widget.onToggleFullScreen()` | 桌面全屏切换 |
| `IconButton(Icons.lock / Icons.lock_open)` | `widget.onToggleLock()` | 锁定/解锁控制层 |
| `Slider` | `onChangeEnd -> _seekTo(...)` | 拖动进度定位 |
| `TextButton.icon(Icons.playlist_play)` | `widget.onToggleEpisodePicker()` | 打开/关闭选集面板 |
| `IconButton(Icons.skip_previous)` | `widget.onPlayPrevious()` | 上一集 |
| `InkWell(Icons.replay)` | `_seekTo(...)` | 快退 |
| `IconButton(Icons.play_circle_fill / Icons.pause_circle_filled)` | `widget.onTogglePlay()` | 播放/暂停 |
| `InkWell(flipped Icons.replay)` | `_seekTo(...)` | 快进 |
| `IconButton(Icons.skip_next)` | `widget.onPlayNext()` | 下一集 |
| `PopupMenuButton<double>` | `widget.onSpeedUpdate(speed)` | 倍速切换 |
| `IconButton(Icons.subtitles / Icons.subtitles_off)` | `widget.onToggleSubtitles()` | 字幕开关 |
| `IconButton(Icons.volume_up / Icons.volume_off)` | `widget.controller.setVolume(...)` | 静音切换 |

## `SubtitleSidebar`

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| view mode toggle | `setState(_isArticleMode = ...)` | 列表/文章视图切换 |
| line filter toggle | `setState(_lineFilterMode = ...)` | 双语分行筛选 |
| `IconButton(Icons.format_size)` | `setState(_showFontSettings = !...)` | 字号面板开关 |
| auto-follow toggle | `SettingsService().updateSetting('autoScrollSubtitles', ...)` | 自动跟随字幕 |
| `IconButton(Icons.my_location)` | `_scrollToActiveIndex()` | 定位当前字幕 |
| `IconButton(Icons.youtube_searched_for)` | `widget.onScanEmbeddedSubtitles` | 扫描内嵌字幕 |
| subtitle manager entry | `widget.onOpenSubtitleManager` | 打开字幕库 |
| `IconButton(Icons.style)` | `widget.onOpenSubtitleStyle` | 打开字幕样式设置 |
| `IconButton(Icons.settings)` | `widget.onOpenSettings` | 打开设置面板 |
| `IconButton(Icons.playlist_play)` | `widget.onOpenEpisodePicker` | 打开选集面板 |

## `SettingsPanel`

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| close button | `widget.onClose` | 关闭设置面板 |
| load local subtitle button | `widget.onLoadSubtitle` | 加载本地字幕 |
| subtitle style button | `widget.onOpenSubtitleSettings` | 打开字幕样式设置 |
| speed chips | `widget.onSpeedChanged(...)` | 设置播放倍速 |
| long-press speed chips | `widget.onLongPressSpeedChanged(...)` | 设置长按倍速 |
| seek-seconds chips | `widget.onSeekSecondsChanged(...)` | 设置双击快进快退秒数 |
| mirror H/V toggle | `widget.onMirrorHChanged(...)` / `widget.onMirrorVChanged(...)` | 水平/垂直镜像 |
| multiple switches | 对应 `on...Changed` | 字幕、自动缓存、连续字幕、自动下一集等开关 |

## `SubtitleSettingsSheet`

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| back button | `onBack` | 返回上一级侧栏 |
| close button | `onClose` | 关闭样式设置 |
| ghost help button | `_showGhostModeHelp()` | 打开幽灵模式帮助 |
| font/style chips | `_updateTextStyle(...)` | 修改字体与描边样式 |
| color picker buttons | `onColorChanged(...)` | 修改字幕颜色相关属性 |

## `SubtitlePositionSidebar`

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| confirm button (`Icons.check`) | `widget.onConfirm` | 确认字幕位置 |
| ghost mode switch | `widget.onGhostModeToggle(...)` | 幽灵模式开关 |
| ghost tune button (`Icons.tune`) | `widget.onEnterGhostMode` | 进入幽灵模式位置调节 |
| D-Pad (`up/down/left/right`) | `_move(dx, dy)` | 微调字幕位置 |
| save button (`Icons.save_as`) | `widget.onSavePreset` | 保存位置预设 |
| reset button (`Icons.restart_alt`) | `widget.onReset` | 重置字幕位置 |
| preset chips (`Bottom/Top/Center/Custom`) | `widget.onAlignmentChanged(...)` | 应用预设位置 |

## `SubtitleManagementSheet`

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| close button | `widget.onClose` / `Navigator.pop` | 关闭字幕管理 |
| browse button | `_setCustomDownloadPath()` | 选择字幕下载目录 |
| open download dir button | `_openDownloadDirectory()` | 打开下载目录 |
| download button | `_downloadSubtitleFile(...)` | 下载字幕 |
| delete button | `_deleteSubtitle(...)` | 删除字幕 |
| import subtitle button | `_importSubtitle()` | 导入本地字幕 |
| open AI button | `widget.onOpenAi` | 打开 AI 转录面板 |
| delete confirm cancel | `Navigator.pop(false)` | 取消删除字幕 |
| delete confirm confirm | `Navigator.pop(true)` | 确认删除字幕 |

## `AiTranscriptionPanel`

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| back button | `widget.onBack` | 返回字幕管理 |
| start transcription button | `_startTranscription()` | 开始 AI 转录 |

## `EpisodePickerPanel`

| Button Identifier (代码英文) | Action Method (代码英文) | 中文功能说明 |
|---|---|---|
| close button | `widget.onClose` | 关闭选集面板 |
| previous button | `playbackService.playPrevious(...)` | 上一集 |
| play/pause button | `playbackService.pause()/resume()` | 播放/暂停 |
| next button | `playbackService.playNext(...)` | 下一集 |
| episode item button | `playlistManager.setCurrentIndex(...)` + `playbackService.play(...)` | 切换到指定集 |

---

## 4) 文档使用说明（给后续定向修改）

- 你后续可直接指定：`Page Class + Button Identifier + Action Method`。
- 推荐描述格式：`在 HomeScreen 中修改 IconButton(Icons.tune) -> _showCardStyleBottomSheet`。
- 这样可以直接定位到对应英文代码点，便于精准改动与回归验证。

