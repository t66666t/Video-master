import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../models/batch_subtitle_task_view.dart';
import '../models/subtitle_output_path_strategy.dart';
import '../models/transcription_status.dart';
import '../services/playback_navigation_service.dart';
import '../services/transcription_manager.dart';
import '../services/settings_service.dart';
import '../services/library_service.dart';
import '../utils/app_toast.dart';
import '../utils/media_folder_scanner.dart';
import '../widgets/internal_video_picker_dialog.dart';
import '../widgets/task_queue_table.dart';

class BatchSubtitleScreen extends StatefulWidget {
  final String? collectionId;

  const BatchSubtitleScreen({super.key, this.collectionId});

  @override
  State<BatchSubtitleScreen> createState() => _BatchSubtitleScreenState();
}

class _BatchSubtitleScreenState extends State<BatchSubtitleScreen> {
  List<BatchSubtitleTaskView> _previousTasks = [];
  final Map<String, bool> _autoDeletedKeys = {};
  int _autoDeleteGeneration = 0;

  @override
  Widget build(BuildContext context) {
    final metrics = _BatchLayoutMetrics.from(MediaQuery.of(context));
    // 页面级主题：批量字幕页所有文本（含弹窗/菜单/底部面板，经由
    // capturedThemes 一并继承）统一使用思源黑体。
    return Theme(
      data: _sourceHanSansTheme(context),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('批量字幕生成'),
          centerTitle: metrics.isCompact,
          toolbarHeight: metrics.isCompact ? 50 : 56,
        ),
        body: SafeArea(
          top: false,
          child: Consumer<TranscriptionManager>(
            builder: (context, manager, _) {
              final library = context.read<LibraryService>();
              final tasks = manager.getQueueSnapshot().map((task) {
                if (task.isExternal || task.videoId == null) return task;
                final item = library.getVideo(task.videoId!);
                if (item == null || item.title.trim().isEmpty) return task;
                return task.copyWith(videoName: item.title.trim());
              }).toList();
              _checkForCompletedTasks(manager, tasks);
              final settings = context.watch<SettingsService>();
              return Column(
                children: [
                  _buildTopBar(context, metrics, manager),
                  _buildCustomOutputDirBar(context, settings, metrics),
                  if (tasks.isNotEmpty)
                    _buildQueueStatusBar(
                      context,
                      metrics,
                      manager.processingCount,
                      manager.queuedCount,
                      manager.pendingCount,
                    ),
                  Expanded(
                    child: TaskQueueTable(
                      tasks: tasks,
                      autoDeletedKeys: _autoDeletedKeys,
                      onStart: (mediaKey) => _startTask(manager, mediaKey),
                      onRetry: (mediaKey) => manager.retryTask(mediaKey),
                      onDelete: (mediaKey) => _deleteTask(manager, mediaKey),
                      onReorder: (mediaKey, newIndex) =>
                          manager.reorderTask(mediaKey, newIndex),
                      onTapCompleted: (task) =>
                          _onTapCompletedTask(context, task),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// 思源黑体主题：在应用主题基础上将全部文本字体统一替换为思源黑体
  /// （Noto Sans SC，即思源黑体的 Google 命名）。
  ThemeData _sourceHanSansTheme(BuildContext context) {
    const fontFamily = 'Noto Sans SC';
    final base = Theme.of(context);
    return base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: fontFamily),
    );
  }

  Widget _buildTopBar(
    BuildContext context,
    _BatchLayoutMetrics metrics,
    TranscriptionManager manager,
  ) {
    final settings = context.watch<SettingsService>();
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: metrics.horizontalPadding,
        vertical: metrics.isCompact ? 7 : 9,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: theme.dividerColor, width: 0.5),
        ),
      ),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: metrics.isCompact
            ? _buildCompactToolbar(context, settings, manager, metrics)
            : _buildExpandedToolbar(context, settings, manager, metrics),
      ),
    );
  }

  Widget _buildCompactToolbar(
    BuildContext context,
    SettingsService settings,
    TranscriptionManager manager,
    _BatchLayoutMetrics metrics,
  ) {
    return Row(
      children: [
        Expanded(
          child: _buildCompactAction(
            context: context,
            label: '添加视频',
            icon: Icons.video_library_outlined,
            onPressed: () => _showInternalVideoPicker(context),
          ),
        ),
        SizedBox(width: metrics.gap),
        Expanded(
          child: _buildCompactAction(
            context: context,
            label: '全部开始',
            icon: Icons.play_arrow_rounded,
            color: Colors.green.shade700,
            onPressed: () => _startAll(manager),
          ),
        ),
        SizedBox(width: metrics.gap),
        Expanded(
          child: _buildCompactAction(
            context: context,
            label: '自动移除',
            icon: settings.batchSubtitleAutoDelete
                ? Icons.auto_delete
                : Icons.auto_delete_outlined,
            selected: settings.batchSubtitleAutoDelete,
            onPressed: () => settings.updateBatchSubtitleAutoDelete(
              !settings.batchSubtitleAutoDelete,
            ),
          ),
        ),
        const SizedBox(width: 2),
        PopupMenuButton<_BatchOverflowAction>(
          tooltip: '更多操作',
          icon: const Icon(Icons.more_vert_rounded),
          onSelected: (action) {
            switch (action) {
              case _BatchOverflowAction.pickExternal:
                _pickExternalFiles(context);
                break;
              case _BatchOverflowAction.settings:
                _showBatchSettingsSheet(context);
                break;
              case _BatchOverflowAction.clearCompleted:
                _clearCompleted(manager);
                break;
              case _BatchOverflowAction.clearAll:
                _showClearAllConfirm(context, manager);
                break;
            }
          },
          itemBuilder: (context) => [
            if (Platform.isWindows)
              const PopupMenuItem(
                value: _BatchOverflowAction.pickExternal,
                child: _PopupMenuLabel(
                  icon: Icons.folder_open_outlined,
                  label: '选择外部文件',
                ),
              ),
            if (metrics.isDesktopPlatform)
              const PopupMenuItem(
                value: _BatchOverflowAction.settings,
                child: _PopupMenuLabel(
                  icon: Icons.tune_rounded,
                  label: '外部视频设置',
                ),
              ),
            const PopupMenuItem(
              value: _BatchOverflowAction.clearCompleted,
              child: _PopupMenuLabel(
                icon: Icons.cleaning_services_outlined,
                label: '清除已完成',
              ),
            ),
            PopupMenuItem(
              value: _BatchOverflowAction.clearAll,
              child: _PopupMenuLabel(
                icon: Icons.delete_sweep_outlined,
                label: '清除全部',
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildExpandedToolbar(
    BuildContext context,
    SettingsService settings,
    TranscriptionManager manager,
    _BatchLayoutMetrics metrics,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final useSingleRow =
            constraints.maxWidth >= 1120 && metrics.isDesktopPlatform;
        final actions = <Widget>[
          _buildActionButton(
            context: context,
            label: '选择内部视频',
            icon: Icons.video_library_outlined,
            height: metrics.buttonHeight,
            fontSize: metrics.fontSize,
            onPressed: () => _showInternalVideoPicker(context),
          ),
          if (Platform.isWindows)
            _buildActionButton(
              context: context,
              label: '选择外部文件',
              icon: Icons.folder_open_outlined,
              height: metrics.buttonHeight,
              fontSize: metrics.fontSize,
              onPressed: () => _pickExternalFiles(context),
            ),
          _buildActionButton(
            context: context,
            label: '全部开始',
            icon: Icons.play_arrow_rounded,
            height: metrics.buttonHeight,
            fontSize: metrics.fontSize,
            color: Colors.green.shade700,
            onPressed: () => _startAll(manager),
          ),
        ];

        if (useSingleRow) {
          return Row(
            children: [
              ..._withSpacing(actions, metrics.gap),
              const Spacer(),
              _buildSettingsRow(
                context,
                settings,
                metrics,
                showExternalSettings: true,
                onClearCompleted: () => _clearCompleted(manager),
                onClearAll: () => _showClearAllConfirm(context, manager),
              ),
            ],
          );
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                ..._withSpacing(actions, metrics.gap),
                const Spacer(),
                if (!metrics.isDesktopPlatform)
                  _buildSettingsRow(
                    context,
                    settings,
                    metrics,
                    showExternalSettings: false,
                    onClearCompleted: () => _clearCompleted(manager),
                    onClearAll: () => _showClearAllConfirm(context, manager),
                  ),
              ],
            ),
            if (metrics.isDesktopPlatform) ...[
              const SizedBox(height: 7),
              Align(
                alignment: Alignment.centerRight,
                child: _buildSettingsRow(
                  context,
                  settings,
                  metrics,
                  showExternalSettings: true,
                  onClearCompleted: () => _clearCompleted(manager),
                  onClearAll: () => _showClearAllConfirm(context, manager),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  List<Widget> _withSpacing(List<Widget> children, double spacing) {
    return [
      for (var index = 0; index < children.length; index++) ...[
        if (index > 0) SizedBox(width: spacing),
        children[index],
      ],
    ];
  }

  /// 自定义输出目录提示条（仅当输出策略为「指定目录」且有路径时显示）
  Widget _buildCustomOutputDirBar(
    BuildContext context,
    SettingsService settings,
    _BatchLayoutMetrics metrics,
  ) {
    final isCustom =
        settings.batchSubtitleOutputPathStrategy ==
        SubtitleOutputPathStrategy.customDirectory;
    final dir = settings.batchSubtitleCustomOutputDir;
    if (!isCustom || dir == null || dir.isEmpty) {
      return const SizedBox.shrink();
    }

    if (!metrics.isDesktopPlatform) return const SizedBox.shrink();

    final fontSize = (metrics.shortestSide * 0.021).clamp(10.5, 12.5);
    final padding = (metrics.shortestSide * 0.012).clamp(6.0, 9.0);

    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: padding * 1.6,
        vertical: padding * 0.5,
      ),
      color: Colors.blueGrey.withValues(alpha: 0.08),
      child: Row(
        children: [
          Icon(
            Icons.folder_outlined,
            size: fontSize + 2,
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '外部输出: $dir',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: fontSize,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.65),
              ),
            ),
          ),
          if (metrics.isDesktopPlatform) ...[
            const SizedBox(width: 8),
            Tooltip(
              message: '打开文件夹',
              child: SizedBox(
                width: fontSize + 12,
                height: fontSize + 12,
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: () => _openDirectoryInExplorer(dir),
                    child: Icon(
                      Icons.open_in_new,
                      size: fontSize + 2,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 桌面端用文件管理器打开指定文件夹
  Future<void> _openDirectoryInExplorer(String dirPath) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', [dirPath]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [dirPath]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [dirPath]);
      }
    } catch (e) {
      debugPrint('打开目录失败: $e');
    }
  }

  Widget _buildQueueStatusBar(
    BuildContext context,
    _BatchLayoutMetrics metrics,
    int processingCount,
    int queuedCount,
    int pendingCount,
  ) {
    final theme = Theme.of(context);
    final fontSize = metrics.isCompact ? 10.5 : metrics.fontSize;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: metrics.horizontalPadding,
        vertical: metrics.isCompact ? 6 : 7,
      ),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      child: Row(
        children: [
          Icon(
            Icons.queue_play_next_rounded,
            size: fontSize + 4,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 6),
          if (!metrics.isCompact || metrics.width >= 390)
            Text(
              metrics.isCompact ? '队列' : '后台转录队列',
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
          const Spacer(),
          _QueueCount(
            label: metrics.isCompact ? '处理' : '处理中',
            count: processingCount,
            color: theme.colorScheme.primary,
            fontSize: fontSize - 0.5,
          ),
          SizedBox(width: metrics.isCompact ? 7 : 14),
          _QueueCount(
            label: '排队',
            count: queuedCount,
            color: Colors.orange.shade700,
            fontSize: fontSize - 0.5,
          ),
          SizedBox(width: metrics.isCompact ? 7 : 14),
          _QueueCount(
            label: '总计',
            count: pendingCount,
            color: theme.colorScheme.onSurfaceVariant,
            fontSize: fontSize - 0.5,
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required BuildContext context,
    required String label,
    required IconData icon,
    required double height,
    required double fontSize,
    Color? color,
    required VoidCallback onPressed,
  }) {
    final theme = Theme.of(context);
    final foreground = color ?? theme.colorScheme.onSurface;
    return SizedBox(
      height: height,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: fontSize + 4),
        label: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w500),
        ),
        style: ElevatedButton.styleFrom(
          elevation: 0,
          foregroundColor: foreground,
          backgroundColor:
              color?.withValues(alpha: 0.09) ??
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
          padding: EdgeInsets.symmetric(horizontal: fontSize * 0.85),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    );
  }

  Widget _buildCompactAction({
    required BuildContext context,
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
    Color? color,
    bool selected = false,
  }) {
    final theme = Theme.of(context);
    final foreground =
        color ??
        (selected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface);
    return Material(
      color: selected
          ? theme.colorScheme.primary
          : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.65),
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          height: 38,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 17, color: foreground),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1,
                      fontWeight: FontWeight.w500,
                      color: foreground,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsRow(
    BuildContext context,
    SettingsService settings,
    _BatchLayoutMetrics metrics, {
    required bool showExternalSettings,
    VoidCallback? onClearCompleted,
    VoidCallback? onClearAll,
  }) {
    return Wrap(
      spacing: metrics.gap,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _buildAutoDeleteSetting(context, settings, metrics),
        if (showExternalSettings) ...[
          _buildEmbedSoftSubtitleButton(context, settings, metrics),
          _buildOutputStrategyButton(context, settings, metrics),
        ],
        if (onClearCompleted != null && onClearAll != null)
          _buildCleanupMenu(
            context,
            metrics,
            onClearCompleted: onClearCompleted,
            onClearAll: onClearAll,
          ),
      ],
    );
  }

  Widget _buildAutoDeleteSetting(
    BuildContext context,
    SettingsService settings,
    _BatchLayoutMetrics metrics,
  ) {
    final enabled = settings.batchSubtitleAutoDelete;
    final accent = Theme.of(context).colorScheme.primary;
    return Semantics(
      button: true,
      toggled: enabled,
      label: '完成后移除任务',
      child: _buildToolbarSettingCard(
        context: context,
        metrics: metrics,
        width: 160,
        icon: Icons.auto_delete_outlined,
        title: '完成后移除',
        subtitle: enabled ? '已开启' : '已关闭',
        accent: accent,
        active: enabled,
        tooltip: enabled ? '点击关闭完成后自动移除' : '点击开启完成后自动移除',
        trailing: Icon(
          enabled ? Icons.check_circle_rounded : Icons.circle_outlined,
          size: 15,
          color: enabled
              ? accent
              : Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        onTap: () => settings.updateBatchSubtitleAutoDelete(!enabled),
      ),
    );
  }

  Widget _buildOutputStrategyButton(
    BuildContext context,
    SettingsService settings,
    _BatchLayoutMetrics metrics,
  ) {
    final theme = Theme.of(context);
    final strategy = settings.batchSubtitleOutputPathStrategy;
    final isCustom = strategy == SubtitleOutputPathStrategy.customDirectory;
    final dir = settings.batchSubtitleCustomOutputDir;
    final folderName = dir == null || dir.trim().isEmpty
        ? null
        : p.basename(p.normalize(dir));
    final subtitle = isCustom
        ? folderName == null || folderName.isEmpty
              ? '指定目录'
              : '指定目录 · $folderName'
        : '视频同目录';

    return PopupMenuButton<SubtitleOutputPathStrategy>(
      tooltip: '选择外部视频字幕输出位置',
      position: PopupMenuPosition.under,
      onSelected: (value) => _changeOutputStrategy(settings, value),
      itemBuilder: (context) => [
        _buildOutputMenuItem(
          context,
          value: SubtitleOutputPathStrategy.sameAsVideo,
          selected: !isCustom,
          icon: Icons.video_file_outlined,
          title: '与视频同目录',
          subtitle: '字幕保存在原视频所在文件夹',
        ),
        _buildOutputMenuItem(
          context,
          value: SubtitleOutputPathStrategy.customDirectory,
          selected: isCustom,
          icon: Icons.create_new_folder_outlined,
          title: '选择指定目录',
          subtitle: '为外部视频选择统一输出文件夹',
        ),
      ],
      child: _buildToolbarSettingCard(
        context: context,
        metrics: metrics,
        width: 180,
        icon: Icons.folder_copy_outlined,
        title: '字幕输出位置',
        subtitle: subtitle,
        accent: theme.colorScheme.primary,
        active: isCustom,
        trailing: Icon(
          Icons.keyboard_arrow_down_rounded,
          size: 17,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  PopupMenuItem<SubtitleOutputPathStrategy> _buildOutputMenuItem(
    BuildContext context, {
    required SubtitleOutputPathStrategy value,
    required bool selected,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final theme = Theme.of(context);
    return PopupMenuItem<SubtitleOutputPathStrategy>(
      value: value,
      child: SizedBox(
        width: 260,
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: selected ? theme.colorScheme.primary : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 10,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (selected) ...[
              const SizedBox(width: 8),
              Icon(
                Icons.check_rounded,
                size: 18,
                color: theme.colorScheme.primary,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCleanupMenu(
    BuildContext context,
    _BatchLayoutMetrics metrics, {
    required VoidCallback onClearCompleted,
    required VoidCallback onClearAll,
  }) {
    final theme = Theme.of(context);
    return PopupMenuButton<_BatchOverflowAction>(
      tooltip: '清理任务队列',
      position: PopupMenuPosition.under,
      onSelected: (action) {
        switch (action) {
          case _BatchOverflowAction.clearCompleted:
            onClearCompleted();
            break;
          case _BatchOverflowAction.clearAll:
            onClearAll();
            break;
          case _BatchOverflowAction.pickExternal:
          case _BatchOverflowAction.settings:
            break;
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: _BatchOverflowAction.clearCompleted,
          child: _PopupMenuLabel(icon: Icons.task_alt_rounded, label: '清除已完成'),
        ),
        PopupMenuItem(
          value: _BatchOverflowAction.clearAll,
          child: _PopupMenuLabel(
            icon: Icons.delete_sweep_outlined,
            label: '清除全部任务',
            color: theme.colorScheme.error,
          ),
        ),
      ],
      child: _buildToolbarSettingCard(
        context: context,
        metrics: metrics,
        width: 124,
        icon: Icons.cleaning_services_outlined,
        title: '清理队列',
        subtitle: '已完成 / 全部',
        accent: theme.colorScheme.onSurfaceVariant,
        trailing: Icon(
          Icons.keyboard_arrow_down_rounded,
          size: 17,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildToolbarSettingCard({
    required BuildContext context,
    required _BatchLayoutMetrics metrics,
    required double width,
    required IconData icon,
    required String title,
    required String subtitle,
    required Color accent,
    Widget? trailing,
    VoidCallback? onTap,
    String? tooltip,
    bool active = false,
  }) {
    final theme = Theme.of(context);
    final card = Material(
      color: active
          ? accent.withValues(alpha: 0.1)
          : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.34),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: active
              ? accent.withValues(alpha: 0.48)
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
          width: 0.8,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: width,
          height: metrics.buttonHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9),
            child: Row(
              children: [
                Container(
                  width: 25,
                  height: 25,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: active ? 0.16 : 0.09),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Icon(icon, size: 16, color: accent),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          height: 1.05,
                          fontSize: metrics.fontSize - 1.1,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          // Leave enough line-box space for CJK fallback fonts.
                          // A 1.0 line height clips the bottom of some glyphs on
                          // Windows (notably in the cleanup queue subtitle).
                          height: 1.2,
                          fontSize: metrics.fontSize - 3.2,
                          fontWeight: active
                              ? FontWeight.w500
                              : FontWeight.w400,
                          color: active
                              ? accent
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 5), trailing],
              ],
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? card : Tooltip(message: tooltip, child: card);
  }

  Future<void> _changeOutputStrategy(
    SettingsService settings,
    SubtitleOutputPathStrategy? value,
  ) async {
    if (value == null) return;
    if (value == SubtitleOutputPathStrategy.customDirectory) {
      final dir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择外部视频字幕输出目录',
      );
      if (dir == null) return;
      await settings.updateBatchSubtitleOutputLocation(
        value,
        customOutputDir: dir,
      );
      return;
    }
    await settings.updateBatchSubtitleOutputLocation(value);
  }

  /// 外部视频内嵌软字幕设置按钮
  Widget _buildEmbedSoftSubtitleButton(
    BuildContext context,
    SettingsService settings,
    _BatchLayoutMetrics metrics,
  ) {
    final theme = Theme.of(context);
    final copyAndEmbed = settings.batchSubtitleEmbedSoftCopyAndEmbed;
    final replaceOriginal = settings.batchSubtitleEmbedSoftDeleteOriginal;
    final enabled = copyAndEmbed || replaceOriginal;
    final status = copyAndEmbed
        ? '已开启 · 复制并内嵌'
        : replaceOriginal
        ? '已开启 · 替换原视频'
        : '未启用 · 点击配置';

    return _buildToolbarSettingCard(
      context: context,
      metrics: metrics,
      width: 190,
      icon: Icons.subtitles_outlined,
      title: '外部视频软字幕内嵌',
      subtitle: status,
      accent: enabled ? Colors.green.shade600 : theme.colorScheme.primary,
      active: enabled,
      tooltip: '配置外部视频软字幕内嵌',
      trailing: Icon(
        Icons.chevron_right_rounded,
        size: 17,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      onTap: () => _showEmbedSoftSubtitleDialog(context, settings),
    );
  }

  void _showBatchSettingsSheet(BuildContext context) {
    final metrics = _BatchLayoutMetrics.from(MediaQuery.of(context));
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            metrics.horizontalPadding,
            0,
            metrics.horizontalPadding,
            18,
          ),
          child: Consumer<SettingsService>(
            builder: (context, settings, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '外部视频设置',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 14),
                _buildSettingsRow(
                  context,
                  settings,
                  metrics,
                  showExternalSettings: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 外部视频内嵌软字幕设置弹窗
  void _showEmbedSoftSubtitleDialog(
    BuildContext context,
    SettingsService settings,
  ) {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final theme = Theme.of(ctx);
          return AlertDialog(
            title: Row(
              children: [
                Icon(Icons.closed_caption, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                const Text('外部视频内嵌软字幕'),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── 复制并内嵌软字幕 ──
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('复制并内嵌软字幕'),
                    subtitle: const Text(
                      '生成新文件，保留原视频',
                      style: TextStyle(fontSize: 12),
                    ),
                    value: settings.batchSubtitleEmbedSoftCopyAndEmbed,
                    onChanged: (v) {
                      settings.updateBatchSubtitleEmbedMode(
                        copyAndEmbed: v,
                        deleteOriginal: v
                            ? false
                            : settings.batchSubtitleEmbedSoftDeleteOriginal,
                      );
                      setDialogState(() {});
                    },
                  ),
                  // ── 内嵌软字幕（删除原视频） ──
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('内嵌软字幕（删除原视频）'),
                    subtitle: const Text(
                      '新视频生成成功后删除原视频',
                      style: TextStyle(fontSize: 12),
                    ),
                    value: settings.batchSubtitleEmbedSoftDeleteOriginal,
                    onChanged: (v) {
                      settings.updateBatchSubtitleEmbedMode(
                        copyAndEmbed: v
                            ? false
                            : settings.batchSubtitleEmbedSoftCopyAndEmbed,
                        deleteOriginal: v,
                      );
                      setDialogState(() {});
                    },
                  ),
                  const Divider(),
                  // ── 前缀设置 ──
                  const Text(
                    '视频命名设置',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      SizedBox(
                        width: 50,
                        child: Switch(
                          value: settings.batchSubtitleEmbedSoftPrefixEnabled,
                          onChanged: (v) {
                            settings.updateBatchSubtitleEmbedSoftPrefixEnabled(
                              v,
                            );
                            setDialogState(() {});
                          },
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                      const Text('前缀: '),
                      Expanded(
                        child: TextField(
                          controller: TextEditingController(
                            text: settings.batchSubtitleEmbedSoftPrefix,
                          ),
                          enabled: settings.batchSubtitleEmbedSoftPrefixEnabled,
                          decoration: const InputDecoration(
                            isDense: true,
                            hintText: '例如 [AI字幕]',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                          ),
                          style: TextStyle(fontSize: 13),
                          onChanged: (v) {
                            settings.updateBatchSubtitleEmbedSoftPrefix(v);
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // ── 后缀设置 ──
                  Row(
                    children: [
                      SizedBox(
                        width: 50,
                        child: Switch(
                          value: settings.batchSubtitleEmbedSoftSuffixEnabled,
                          onChanged: (v) {
                            settings.updateBatchSubtitleEmbedSoftSuffixEnabled(
                              v,
                            );
                            setDialogState(() {});
                          },
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                      const Text('后缀: '),
                      Expanded(
                        child: TextField(
                          controller: TextEditingController(
                            text: settings.batchSubtitleEmbedSoftSuffix,
                          ),
                          enabled: settings.batchSubtitleEmbedSoftSuffixEnabled,
                          decoration: const InputDecoration(
                            isDense: true,
                            hintText: '例如 _字幕版',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                          ),
                          style: TextStyle(fontSize: 13),
                          onChanged: (v) {
                            settings.updateBatchSubtitleEmbedSoftSuffix(v);
                          },
                        ),
                      ),
                    ],
                  ),
                  const Divider(),
                  // ── 内嵌后自动删除字幕文件 ──
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('内嵌后自动删除字幕文件'),
                    subtitle: const Text(
                      '流程完成后删除 SRT 字幕文件',
                      style: TextStyle(fontSize: 12),
                    ),
                    value: settings.batchSubtitleEmbedAutoDeleteSrt,
                    onChanged: (v) {
                      settings.updateBatchSubtitleEmbedAutoDeleteSrt(v);
                      setDialogState(() {});
                    },
                  ),
                  const SizedBox(height: 8),
                  // 提示信息
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 16,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '内嵌结果预览: ${_buildPreviewFileName('示例视频.mp4', settings)}',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.7,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

  String _buildPreviewFileName(String fileName, SettingsService settings) {
    final ext = p.extension(fileName);
    final baseName = p.basenameWithoutExtension(fileName);
    String result = baseName;
    if (settings.batchSubtitleEmbedSoftPrefixEnabled &&
        settings.batchSubtitleEmbedSoftPrefix.isNotEmpty) {
      result = '${settings.batchSubtitleEmbedSoftPrefix}$result';
    }
    if (settings.batchSubtitleEmbedSoftSuffixEnabled &&
        settings.batchSubtitleEmbedSoftSuffix.isNotEmpty) {
      result = '$result${settings.batchSubtitleEmbedSoftSuffix}';
    }
    if (settings.batchSubtitleEmbedSoftCopyAndEmbed && result == baseName) {
      result = '${baseName}_AI字幕';
    }
    return '$result$ext';
  }

  void _showInternalVideoPicker(BuildContext context) {
    final library = context.read<LibraryService>();
    final manager = context.read<TranscriptionManager>();
    showDialog(
      context: context,
      builder: (ctx) => InternalVideoPickerDialog(
        libraryService: library,
        transcriptionManager: manager,
        defaultCollectionId: widget.collectionId,
        onConfirm: (selectedNodes) {
          for (final node in selectedNodes) {
            if (node.videoPath != null) {
              manager.startTranscription(
                node.videoPath!,
                videoId: node.videoId,
                videoTitle: node.name,
                videoDuration: node.videoDuration,
                libraryService: library,
                autoCache: context.read<SettingsService>().autoCacheSubtitles,
              );
            }
          }
          if (selectedNodes.isNotEmpty) {
            AppToast.show('已添加 ${selectedNodes.length} 个任务到队列');
          }
        },
      ),
    );
  }

  Future<void> _pickExternalFiles(BuildContext context) async {
    final source = await showDialog<_ExternalPickSource>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择导入来源'),
        content: const Text('请选择要加入转录队列的媒体来源。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_ExternalPickSource.folder),
            child: const Text('导入文件夹'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(_ExternalPickSource.files),
            child: const Text('导入文件'),
          ),
        ],
      ),
    );
    if (source == null || !context.mounted) return;

    switch (source) {
      case _ExternalPickSource.files:
        await _pickExternalFilesImpl(context);
        break;
      case _ExternalPickSource.folder:
        await _pickExternalFolder(context);
        break;
    }
  }

  /// 选择并导入多个外部媒体文件到转录队列。
  Future<void> _pickExternalFilesImpl(BuildContext context) async {
    final manager = context.read<TranscriptionManager>();
    final settings = context.read<SettingsService>();
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: LibraryService.supportedMediaExtensions
          .map((ext) => ext.replaceFirst('.', ''))
          .toList(),
      allowMultiple: true,
    );

    if (result == null || result.files.isEmpty) return;

    int added = 0;

    for (final file in result.files) {
      if (file.path == null) continue;
      try {
        await manager.startExternalTranscription(
          file.path!,
          outputPathStrategy: settings.batchSubtitleOutputPathStrategy,
          customOutputDir: settings.batchSubtitleCustomOutputDir,
        );
        added++;
      } catch (e) {
        debugPrint('添加外部文件失败: ${file.path}, $e');
      }
    }

    if (added > 0) {
      AppToast.show('已添加 $added 个外部文件到队列');
    }
  }

  /// 导入文件夹：递归扫描（文件夹优先 + 每层自然排序）→ 确认框 → 批量加入队列。
  Future<void> _pickExternalFolder(BuildContext context) async {
    final manager = context.read<TranscriptionManager>();
    final settings = context.read<SettingsService>();

    final folderPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择要导入的文件夹',
    );
    if (folderPath == null || folderPath.isEmpty) return;
    if (!context.mounted) return;

    try {
      final mediaPaths = await scanMediaFolderOrdered(folderPath);
      if (!context.mounted) return;

      if (mediaPaths.isEmpty) {
        AppToast.show('所选文件夹中没有可识别的媒体文件');
        return;
      }

      final folderName = p.basename(p.normalize(folderPath));
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('导入文件夹'),
          content: Text(
            '「$folderName」中递归共找到 ${mediaPaths.length} 个媒体文件，确认全部加入转录队列？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('确认添加'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;

      int added = 0;
      for (final path in mediaPaths) {
        try {
          await manager.startExternalTranscription(
            path,
            outputPathStrategy: settings.batchSubtitleOutputPathStrategy,
            customOutputDir: settings.batchSubtitleCustomOutputDir,
          );
          added++;
        } catch (e) {
          debugPrint('添加外部媒体文件失败: $path, $e');
        }
      }
      if (added > 0) {
        AppToast.show('已添加 $added 个媒体文件到队列');
      }
    } catch (e) {
      if (e is FileSystemException) {
        AppToast.show('所选文件夹不存在或无法访问');
      } else if (e is TimeoutException) {
        AppToast.show(e.message ?? '文件夹扫描超时');
      } else {
        debugPrint('扫描文件夹失败: $e');
        AppToast.show('扫描文件夹失败: $e');
      }
    }
  }

  void _checkForCompletedTasks(
    TranscriptionManager manager,
    List<BatchSubtitleTaskView> currentTasks,
  ) {
    final settings = context.read<SettingsService>();
    if (!settings.batchSubtitleAutoDelete) {
      // Turning the switch off also cancels removals already waiting in the
      // two-second animation window.
      if (_autoDeletedKeys.isNotEmpty) {
        _autoDeletedKeys.clear();
        _autoDeleteGeneration++;
      }
      _previousTasks = currentTasks;
      return;
    }

    for (final prev in _previousTasks) {
      if (prev.status == TranscriptionStatus.idle ||
          prev.status == TranscriptionStatus.downloading ||
          prev.status == TranscriptionStatus.extracting ||
          prev.status == TranscriptionStatus.uploading ||
          prev.status == TranscriptionStatus.transcribing ||
          prev.status == TranscriptionStatus.embedding) {
        final current = currentTasks.where((t) => t.mediaKey == prev.mediaKey);
        if (current.isNotEmpty &&
            current.first.status == TranscriptionStatus.completed) {
          if (!_autoDeletedKeys.containsKey(prev.mediaKey)) {
            _autoDeletedKeys[prev.mediaKey] = true;
            final generation = _autoDeleteGeneration;
            Future.delayed(const Duration(seconds: 2), () {
              if (!mounted || generation != _autoDeleteGeneration) return;

              final latestSettings = context.read<SettingsService>();
              BatchSubtitleTaskView? latestTask;
              for (final task in manager.getQueueSnapshot()) {
                if (task.mediaKey == prev.mediaKey) {
                  latestTask = task;
                  break;
                }
              }
              if (latestSettings.batchSubtitleAutoDelete &&
                  latestTask?.status == TranscriptionStatus.completed) {
                final removed = manager.removeFromQueue(prev.mediaKey);
                _autoDeletedKeys.remove(prev.mediaKey);
                if (!removed) setState(() {});
              } else {
                setState(() => _autoDeletedKeys.remove(prev.mediaKey));
              }
            });
          }
        }
      }
    }
    _previousTasks = currentTasks;
  }

  void _startTask(TranscriptionManager manager, String mediaKey) {
    manager.startTask(mediaKey);
    AppToast.show('任务已开始处理');
  }

  void _startAll(TranscriptionManager manager) {
    final tasks = manager.getQueueSnapshot();
    final idleCount = tasks
        .where((t) => t.status == TranscriptionStatus.idle && !t.isStarted)
        .length;
    if (idleCount == 0) {
      AppToast.show('没有待开始的任务');
      return;
    }
    manager.startAllTasks();
    AppToast.show('已开始处理 $idleCount 个任务');
  }

  void _clearCompleted(TranscriptionManager manager) {
    manager.clearAllCompleted();
    AppToast.show('已清除所有已完成任务');
  }

  void _showClearAllConfirm(
    BuildContext context,
    TranscriptionManager manager,
  ) {
    final tasks = manager.getQueueSnapshot();
    final count = tasks.length;
    if (count == 0) {
      AppToast.show('队列中没有任务');
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认清除全部'),
        content: Text('将取消正在处理的任务，并清除队列中所有 $count 个任务，确定继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _clearAll(manager);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('清除全部'),
          ),
        ],
      ),
    );
  }

  void _clearAll(TranscriptionManager manager) {
    manager.clearAllTasks();
    AppToast.show('已清除所有任务');
  }

  void _deleteTask(TranscriptionManager manager, String mediaKey) {
    manager.removeFromQueue(mediaKey);
  }

  /// 点击已完成任务的名称：
  /// - 内部视频：跳转到播放页（桌面端横屏，移动端竖屏）
  /// - 外部视频：桌面端用文件资源管理器定位，移动端触发"用其他应用打开"
  Future<void> _onTapCompletedTask(
    BuildContext context,
    BatchSubtitleTaskView task,
  ) async {
    if (task.status != TranscriptionStatus.completed) return;

    if (!task.isExternal && task.videoId != null) {
      // ── 内部视频：跳转到播放页 ──
      await _openInternalVideo(context, task.videoId!);
    } else {
      // ── 外部视频：桌面端打开文件位置，移动端用其他应用打开 ──
      await _openExternalVideoFile(task.videoPath);
    }
  }

  /// 跳转到内部视频的播放页
  Future<void> _openInternalVideo(BuildContext context, String videoId) async {
    final library = context.read<LibraryService>();
    final item = library.getVideo(videoId);
    if (item == null) {
      AppToast.show('视频已不存在或已被删除');
      return;
    }

    if (!mounted) return;

    final navigator = Navigator.of(context);

    // 桌面端或开启"跳过竖屏播放页"时直入横屏播放页，否则进入竖屏播放页
    await navigator.push(
      PlaybackNavigationService.buildPlaybackEntryRoute(item),
    );
  }

  /// 打开外部视频文件
  Future<void> _openExternalVideoFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      AppToast.show('文件已不存在: $filePath');
      return;
    }

    try {
      if (Platform.isWindows) {
        // Windows：资源管理器定位到文件
        await Process.run('explorer', ['/select,', filePath]);
      } else if (Platform.isMacOS) {
        // macOS：Finder 定位到文件
        await Process.run('open', ['-R', filePath]);
      } else if (Platform.isLinux) {
        // Linux：打开文件所在目录
        await Process.run('xdg-open', [p.dirname(filePath)]);
      } else {
        // 移动端（Android/iOS）：触发系统"用其他应用打开"
        await OpenFilex.open(filePath);
      }
    } catch (e) {
      debugPrint('打开文件失败: $e');
      AppToast.show('打开文件失败');
    }
  }
}

enum _BatchOverflowAction { pickExternal, settings, clearCompleted, clearAll }

/// 「选择外部文件」入口的来源选择。
enum _ExternalPickSource { files, folder }

class _BatchLayoutMetrics {
  final double width;
  final double height;
  final double shortestSide;
  final bool isCompact;
  final bool isDesktopPlatform;
  final double horizontalPadding;
  final double gap;
  final double fontSize;
  final double buttonHeight;

  const _BatchLayoutMetrics({
    required this.width,
    required this.height,
    required this.shortestSide,
    required this.isCompact,
    required this.isDesktopPlatform,
    required this.horizontalPadding,
    required this.gap,
    required this.fontSize,
    required this.buttonHeight,
  });

  factory _BatchLayoutMetrics.from(MediaQueryData mediaQuery) {
    final size = mediaQuery.size;
    final shortestSide = size.shortestSide;
    final isCompact = shortestSide < 600;
    return _BatchLayoutMetrics(
      width: size.width,
      height: size.height,
      shortestSide: shortestSide,
      isCompact: isCompact,
      isDesktopPlatform:
          Platform.isWindows || Platform.isLinux || Platform.isMacOS,
      horizontalPadding: (shortestSide * 0.026).clamp(8.0, 18.0),
      gap: (shortestSide * 0.012).clamp(5.0, 10.0),
      fontSize: (shortestSide * 0.021).clamp(11.5, 13.5),
      buttonHeight: (shortestSide * 0.058).clamp(34.0, 40.0),
    );
  }
}

class _PopupMenuLabel extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;

  const _PopupMenuLabel({required this.icon, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    final foreground = color ?? Theme.of(context).colorScheme.onSurface;
    return Row(
      children: [
        Icon(icon, size: 19, color: foreground),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: foreground, fontSize: 13)),
      ],
    );
  }
}

class _QueueCount extends StatelessWidget {
  final String label;
  final int count;
  final Color color;
  final double fontSize;

  const _QueueCount({
    required this.label,
    required this.count,
    required this.color,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label ',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          TextSpan(
            text: '$count',
            style: TextStyle(color: color, fontWeight: FontWeight.w700),
          ),
        ],
      ),
      maxLines: 1,
      style: TextStyle(fontSize: fontSize, height: 1.2),
    );
  }
}
