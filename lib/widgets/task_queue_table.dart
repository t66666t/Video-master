import 'package:flutter/material.dart';
import '../models/batch_subtitle_task_view.dart';
import '../models/transcription_status.dart';

/// Converts Flutter's final displayed-list index into the task's final
/// position in the pending queue.
///
/// The table also contains active, failed, and completed rows, while the
/// manager's queue contains only idle rows.  Deriving the destination from
/// the reordered display list keeps those non-queue rows from shifting the
/// queue index.
@visibleForTesting
int calculateBatchSubtitleQueueIndex({
  required List<BatchSubtitleTaskView> displayedTasks,
  required int oldIndex,
  required int newIndex,
  required bool isDescending,
}) {
  if (oldIndex < 0 || oldIndex >= displayedTasks.length) return -1;

  final draggedTask = displayedTasks[oldIndex];
  if (draggedTask.status != TranscriptionStatus.idle) return -1;

  final reordered = List<BatchSubtitleTaskView>.from(displayedTasks);
  reordered.removeAt(oldIndex);

  // onReorderItem (unlike the deprecated onReorder callback) has already
  // adjusted newIndex for the removal at oldIndex.
  final insertionIndex = newIndex.clamp(0, reordered.length);
  reordered.insert(insertionIndex, draggedTask);

  final displayedQueue = reordered
      .where((task) => task.status == TranscriptionStatus.idle)
      .toList(growable: false);
  final displayedQueueIndex = displayedQueue.indexWhere(
    (task) => task.mediaKey == draggedTask.mediaKey,
  );
  if (displayedQueueIndex < 0) return -1;

  return isDescending
      ? displayedQueue.length - 1 - displayedQueueIndex
      : displayedQueueIndex;
}

class TaskQueueTable extends StatefulWidget {
  final List<BatchSubtitleTaskView> tasks;
  final Map<String, bool> autoDeletedKeys;
  final void Function(String mediaKey) onStart;
  final void Function(String mediaKey) onRetry;
  final void Function(String mediaKey) onDelete;
  final void Function(String mediaKey, int newIndex) onReorder;
  final void Function(BatchSubtitleTaskView task)? onTapCompleted;

  const TaskQueueTable({
    super.key,
    required this.tasks,
    required this.autoDeletedKeys,
    required this.onStart,
    required this.onRetry,
    required this.onDelete,
    required this.onReorder,
    this.onTapCompleted,
  });

  @override
  State<TaskQueueTable> createState() => _TaskQueueTableState();
}

class _TaskQueueTableState extends State<TaskQueueTable> {
  bool _isDescending = false;
  int? _dragIndex;
  int? _hoverIndex;

  List<BatchSubtitleTaskView> get _sortedTasks {
    final list = List<BatchSubtitleTaskView>.from(widget.tasks);
    if (_isDescending) {
      return list.reversed.toList();
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _sortedTasks;

    if (tasks.isEmpty) {
      return LayoutBuilder(
        builder: (context, constraints) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.65),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.subtitles_outlined,
                    size: 27,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  '还没有字幕任务',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 5),
                Text(
                  constraints.maxWidth < 600
                      ? '点击上方“添加视频”开始'
                      : '选择内部视频或外部文件添加到队列',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final mediaSize = MediaQuery.sizeOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact =
            mediaSize.shortestSide < 600 || constraints.maxWidth < 560;
        final isWide = !isCompact && constraints.maxWidth >= 840;
        final btnSize = isCompact
            ? (mediaSize.shortestSide * 0.09).clamp(31.0, 36.0)
            : (mediaSize.shortestSide * 0.04).clamp(30.0, 38.0);

        return Column(
          children: [
            _buildHeader(isWide, isCompact, btnSize, tasks.length),
            const Divider(height: 1),
            Expanded(
              child: ReorderableListView.builder(
                padding: isCompact
                    ? const EdgeInsets.only(bottom: 8)
                    : EdgeInsets.zero,
                buildDefaultDragHandles: false,
                itemCount: tasks.length,
                onReorderStart: (index) {
                  setState(() => _dragIndex = index);
                },
                onReorderEnd: (_) {
                  setState(() {
                    _dragIndex = null;
                    _hoverIndex = null;
                  });
                },
                onReorderItem: (oldIndex, newIndex) {
                  final task = tasks[oldIndex];
                  if (task.status != TranscriptionStatus.idle) return;
                  final queueIndex = calculateBatchSubtitleQueueIndex(
                    displayedTasks: tasks,
                    oldIndex: oldIndex,
                    newIndex: newIndex,
                    isDescending: _isDescending,
                  );
                  if (queueIndex < 0) return;
                  widget.onReorder(task.mediaKey, queueIndex);
                },
                proxyDecorator: (child, index, animation) {
                  return AnimatedBuilder(
                    animation: animation,
                    builder: (context, _) {
                      final t = Curves.easeOutCubic.transform(animation.value);
                      return Transform.scale(
                        scale: 1.0 + t * 0.018,
                        child: Opacity(opacity: 0.9, child: child),
                      );
                    },
                  );
                },
                itemBuilder: (context, index) {
                  final task = tasks[index];
                  final isAutoDeleting = widget.autoDeletedKeys.containsKey(
                    task.mediaKey,
                  );
                  final canDrag = task.status == TranscriptionStatus.idle;

                  final row = _TaskRow(
                    key: ValueKey(task.mediaKey),
                    index: _isDescending ? tasks.length - index : index + 1,
                    task: task,
                    isWide: isWide,
                    isCompact: isCompact,
                    isAutoDeleting: isAutoDeleting,
                    canDrag: canDrag,
                    isDragging: _dragIndex == index,
                    isHoverTarget: _hoverIndex == index,
                    btnSize: btnSize,
                    onStart: () => widget.onStart(task.mediaKey),
                    onRetry: () => widget.onRetry(task.mediaKey),
                    onDelete: () => widget.onDelete(task.mediaKey),
                    onTapCompleted: widget.onTapCompleted != null
                        ? () => widget.onTapCompleted!(task)
                        : null,
                  );

                  if (canDrag) {
                    return ReorderableDelayedDragStartListener(
                      key: ValueKey(task.mediaKey),
                      index: index,
                      child: row,
                    );
                  }
                  return row;
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHeader(
    bool isWide,
    bool isCompact,
    double btnSize,
    int taskCount,
  ) {
    if (isCompact) {
      final actionWidth = btnSize * 2;
      final headerStyle = TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      );
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
        child: Row(
          children: [
            Tooltip(
              message: _isDescending ? '按创建顺序升序' : '按创建顺序降序',
              child: InkWell(
                onTap: () => setState(() => _isDescending = !_isDescending),
                borderRadius: BorderRadius.circular(5),
                child: SizedBox(
                  width: 26,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('#', style: headerStyle),
                      Icon(
                        _isDescending
                            ? Icons.arrow_downward_rounded
                            : Icons.arrow_upward_rounded,
                        size: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '任务名称  $taskCount',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: headerStyle,
              ),
            ),
            SizedBox(
              width: 72,
              child: Text(
                '状态',
                textAlign: TextAlign.center,
                style: headerStyle,
              ),
            ),
            SizedBox(
              width: actionWidth,
              child: Text(
                '操作',
                textAlign: TextAlign.center,
                style: headerStyle,
              ),
            ),
          ],
        ),
      );
    }

    final actionWidth = btnSize * 2 + 4;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          GestureDetector(
            onTap: () => setState(() => _isDescending = !_isDescending),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('#', style: const TextStyle(fontWeight: FontWeight.bold)),
                Icon(
                  _isDescending ? Icons.arrow_downward : Icons.arrow_upward,
                  size: 14,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            flex: 3,
            child: Text('名称', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          if (isWide)
            const SizedBox(
              width: 60,
              child: Text('类型', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          const SizedBox(
            width: 120,
            child: Text('进度', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          SizedBox(
            width: actionWidth,
            child: const Text(
              '操作',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  final int index;
  final BatchSubtitleTaskView task;
  final bool isWide;
  final bool isCompact;
  final bool isAutoDeleting;
  final bool canDrag;
  final bool isDragging;
  final bool isHoverTarget;
  final double btnSize;
  final VoidCallback onStart;
  final VoidCallback onRetry;
  final VoidCallback onDelete;
  final VoidCallback? onTapCompleted;

  const _TaskRow({
    super.key,
    required this.index,
    required this.task,
    required this.isWide,
    required this.isCompact,
    required this.isAutoDeleting,
    required this.canDrag,
    required this.isDragging,
    required this.isHoverTarget,
    required this.btnSize,
    required this.onStart,
    required this.onRetry,
    required this.onDelete,
    this.onTapCompleted,
  });

  @override
  Widget build(BuildContext context) {
    if (isCompact) {
      return _CompactTaskTableRow(
        index: index,
        task: task,
        isAutoDeleting: isAutoDeleting,
        isDragging: isDragging,
        isHoverTarget: isHoverTarget,
        btnSize: btnSize,
        onStart: onStart,
        onRetry: onRetry,
        onDelete: onDelete,
        onTapCompleted: onTapCompleted,
      );
    }

    final isProcessing =
        task.status != TranscriptionStatus.idle &&
        task.status != TranscriptionStatus.completed &&
        task.status != TranscriptionStatus.error;
    final isCompleted = task.status == TranscriptionStatus.completed;
    final isError = task.status == TranscriptionStatus.error;
    final isIdle = task.status == TranscriptionStatus.idle;

    final iconSize = btnSize * 0.5;

    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        opacity: isAutoDeleting ? 0.0 : 1.0,
        child: Container(
          margin: EdgeInsets.symmetric(
            horizontal: isDragging ? 4 : 0,
            vertical: 1,
          ),
          decoration: BoxDecoration(
            color: isDragging
                ? Theme.of(context).colorScheme.surfaceContainerHighest
                : isHoverTarget
                ? Theme.of(context).hoverColor
                : null,
            borderRadius: BorderRadius.circular(isDragging ? 8 : 0),
            boxShadow: isDragging
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Text(
                  '$index',
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    color: Theme.of(context).hintColor,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: isCompleted && onTapCompleted != null
                                ? GestureDetector(
                                    onTap: onTapCompleted,
                                    child: Text(
                                      task.videoName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13,
                                        decoration: TextDecoration.underline,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurface,
                                      ),
                                    ),
                                  )
                                : Text(
                                    task.videoName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                          ),
                          if (!isWide)
                            Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: _TypeBadge(
                                isExternal: task.isExternal,
                                compact: true,
                              ),
                            ),
                        ],
                      ),
                      if (task.videoDuration.isNotEmpty)
                        Text(
                          task.videoDuration,
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).hintColor,
                          ),
                        ),
                    ],
                  ),
                ),
                if (isWide)
                  SizedBox(
                    width: 60,
                    child: _TypeBadge(
                      isExternal: task.isExternal,
                      compact: false,
                    ),
                  ),
                SizedBox(
                  width: 120,
                  child: _ProgressIndicator(
                    status: task.status,
                    progress: task.progress,
                    statusMessage: task.statusMessage,
                    videoName: task.videoName,
                  ),
                ),
                SizedBox(
                  width: btnSize * 2 + 6,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isIdle && !task.isStarted)
                        _CompactIconButton(
                          icon: Icons.play_arrow,
                          size: btnSize,
                          iconSize: iconSize,
                          color: Theme.of(context).colorScheme.primary,
                          tooltip: '开始',
                          onPressed: onStart,
                        ),
                      if (isIdle && task.isStarted)
                        _CompactIconButton(
                          icon: Icons.hourglass_bottom,
                          size: btnSize,
                          iconSize: iconSize,
                          color: Colors.amber.shade700,
                          tooltip: '等待处理',
                          onPressed: null,
                        ),
                      if (isProcessing)
                        _CompactIconButton(
                          icon: Icons.play_arrow,
                          size: btnSize,
                          iconSize: iconSize,
                          color: Theme.of(context).disabledColor,
                          tooltip: '处理中',
                          onPressed: null,
                        ),
                      if (isCompleted)
                        _CompactIconButton(
                          icon: Icons.check_circle,
                          size: btnSize,
                          iconSize: iconSize,
                          color: Colors.green,
                          tooltip: '已完成',
                          onPressed: null,
                        ),
                      if (isError)
                        _CompactIconButton(
                          icon: Icons.refresh,
                          size: btnSize,
                          iconSize: iconSize,
                          color: Colors.orange,
                          tooltip: '重试',
                          onPressed: onRetry,
                        ),
                      const SizedBox(width: 2),
                      _CompactIconButton(
                        icon: Icons.close,
                        size: btnSize,
                        iconSize: iconSize,
                        color: Theme.of(context).colorScheme.error,
                        tooltip: isProcessing ? '取消并删除' : '删除',
                        onPressed: onDelete,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CompactTaskTableRow extends StatelessWidget {
  final int index;
  final BatchSubtitleTaskView task;
  final bool isAutoDeleting;
  final bool isDragging;
  final bool isHoverTarget;
  final double btnSize;
  final VoidCallback onStart;
  final VoidCallback onRetry;
  final VoidCallback onDelete;
  final VoidCallback? onTapCompleted;

  const _CompactTaskTableRow({
    required this.index,
    required this.task,
    required this.isAutoDeleting,
    required this.isDragging,
    required this.isHoverTarget,
    required this.btnSize,
    required this.onStart,
    required this.onRetry,
    required this.onDelete,
    this.onTapCompleted,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isProcessing =
        task.status != TranscriptionStatus.idle &&
        task.status != TranscriptionStatus.completed &&
        task.status != TranscriptionStatus.error;
    final isCompleted = task.status == TranscriptionStatus.completed;
    final isError = task.status == TranscriptionStatus.error;
    final isIdle = task.status == TranscriptionStatus.idle;
    final iconSize = btnSize * 0.52;

    Widget stateButton;
    if (isIdle && !task.isStarted) {
      stateButton = _CompactIconButton(
        icon: Icons.play_arrow_rounded,
        size: btnSize,
        iconSize: iconSize,
        color: theme.colorScheme.primary,
        tooltip: '开始',
        onPressed: onStart,
      );
    } else if (isError) {
      stateButton = _CompactIconButton(
        icon: Icons.refresh_rounded,
        size: btnSize,
        iconSize: iconSize,
        color: Colors.orange.shade700,
        tooltip: '重试',
        onPressed: onRetry,
      );
    } else {
      stateButton = _CompactIconButton(
        icon: isCompleted
            ? Icons.check_circle_rounded
            : isProcessing
            ? Icons.graphic_eq_rounded
            : Icons.hourglass_bottom_rounded,
        size: btnSize,
        iconSize: iconSize,
        color: isCompleted ? Colors.green : Colors.amber.shade700,
        tooltip: isCompleted
            ? '已完成'
            : isProcessing
            ? '处理中'
            : '等待处理',
        onPressed: null,
      );
    }

    final title = Text(
      task.videoName,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12.2,
        height: 1.15,
        fontWeight: FontWeight.w500,
        decoration: isCompleted && onTapCompleted != null
            ? TextDecoration.underline
            : null,
        color: theme.colorScheme.onSurface,
      ),
    );

    return AnimatedSize(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        opacity: isAutoDeleting ? 0 : 1,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          margin: EdgeInsets.symmetric(
            horizontal: isDragging ? 4 : 0,
            vertical: isDragging ? 2 : 0,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: isDragging
                ? theme.colorScheme.primaryContainer.withValues(alpha: 0.4)
                : isHoverTarget
                ? theme.hoverColor
                : Colors.transparent,
            borderRadius: BorderRadius.circular(isDragging ? 8 : 0),
            border: Border(
              bottom: BorderSide(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.42),
                width: 0.7,
              ),
            ),
            boxShadow: isDragging
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 26,
                child: Text(
                  '$index',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isCompleted && onTapCompleted != null)
                      GestureDetector(onTap: onTapCompleted, child: title)
                    else
                      title,
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _TypeBadge(isExternal: task.isExternal, compact: true),
                        if (task.videoDuration.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              task.videoDuration,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 9.5,
                                height: 1,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 72,
                child: _CompactTableStatus(
                  status: task.status,
                  progress: task.progress,
                  statusMessage: task.statusMessage,
                  videoName: task.videoName,
                ),
              ),
              SizedBox(
                width: btnSize * 2,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    stateButton,
                    _CompactIconButton(
                      icon: Icons.close_rounded,
                      size: btnSize,
                      iconSize: iconSize,
                      color: theme.colorScheme.error,
                      tooltip: isProcessing ? '取消并删除' : '删除',
                      onPressed: onDelete,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactTableStatus extends StatelessWidget {
  final TranscriptionStatus status;
  final double progress;
  final String statusMessage;
  final String videoName;

  const _CompactTableStatus({
    required this.status,
    required this.progress,
    required this.statusMessage,
    required this.videoName,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (status == TranscriptionStatus.completed) {
      return Tooltip(
        message: statusMessage.isEmpty
            ? '$videoName - 转录完成'
            : '$videoName - $statusMessage',
        child: _buildLabel(
          icon: Icons.check_circle_rounded,
          label: '完成',
          color: Colors.green.shade500,
        ),
      );
    }

    if (status == TranscriptionStatus.error) {
      return Tooltip(
        message: statusMessage.isEmpty ? '$videoName - 转录失败' : statusMessage,
        child: _buildLabel(
          icon: Icons.error_rounded,
          label: '失败',
          color: theme.colorScheme.error,
        ),
      );
    }

    if (status == TranscriptionStatus.idle) {
      final label = taskQueueLabel(statusMessage);
      return Tooltip(
        message: statusMessage.isEmpty ? '等待处理' : statusMessage,
        child: _buildLabel(
          icon: Icons.schedule_rounded,
          label: label,
          color: Colors.amber.shade700,
        ),
      );
    }

    final statusText = switch (status) {
      TranscriptionStatus.extracting => '提取',
      TranscriptionStatus.uploading => '上传',
      TranscriptionStatus.transcribing => '转录',
      TranscriptionStatus.embedding => '内嵌',
      _ => '处理',
    };
    final percentage = (progress.clamp(0.0, 1.0) * 100).round();
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              statusText,
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w500,
                color: theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(width: 3),
            Text(
              '$percentage%',
              style: TextStyle(
                fontSize: 8.5,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 3,
            ),
          ),
        ),
      ],
    );
    return statusMessage.isEmpty
        ? content
        : Tooltip(message: '$videoName - $statusMessage', child: content);
  }

  String taskQueueLabel(String message) {
    if (message.isEmpty) return '排队';
    if (message.length <= 4) return message;
    return '等待';
  }

  Widget _buildLabel({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 3),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}

class _CompactIconButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final double iconSize;
  final Color color;
  final String tooltip;
  final VoidCallback? onPressed;

  const _CompactIconButton({
    required this.icon,
    required this.size,
    required this.iconSize,
    required this.color,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: size,
        height: size,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(size * 0.25),
            child: Center(
              child: Icon(
                icon,
                size: iconSize,
                color: onPressed == null
                    ? Theme.of(context).disabledColor
                    : color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TypeBadge extends StatelessWidget {
  final bool isExternal;
  final bool compact;

  const _TypeBadge({required this.isExternal, required this.compact});

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: isExternal
              ? Colors.orange.withValues(alpha: 0.15)
              : Colors.blue.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          isExternal ? '外部' : '内部',
          style: TextStyle(
            fontSize: 10,
            color: isExternal ? Colors.orange.shade800 : Colors.blue.shade800,
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: isExternal
            ? Colors.orange.withValues(alpha: 0.15)
            : Colors.blue.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        isExternal ? '外部视频' : '内部视频',
        style: TextStyle(
          fontSize: 11,
          color: isExternal ? Colors.orange.shade800 : Colors.blue.shade800,
        ),
      ),
    );
  }
}

class _ProgressIndicator extends StatelessWidget {
  final TranscriptionStatus status;
  final double progress;
  final String statusMessage;
  final String videoName;

  const _ProgressIndicator({
    required this.status,
    required this.progress,
    this.statusMessage = '',
    this.videoName = '',
  });

  @override
  Widget build(BuildContext context) {
    if (status == TranscriptionStatus.completed) {
      final msg = statusMessage.isNotEmpty ? statusMessage : '转录完成，可直接使用生成字幕';
      return Tooltip(
        message: '$videoName - $msg',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.check_circle,
                  size: 16,
                  color: Colors.green.shade600,
                ),
                const SizedBox(width: 4),
                Text(
                  '已完成',
                  style: TextStyle(fontSize: 11, color: Colors.green.shade600),
                ),
              ],
            ),
            if (statusMessage.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                msg,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 9, color: Colors.green.shade300),
              ),
            ],
          ],
        ),
      );
    }

    if (status == TranscriptionStatus.error) {
      final msg = statusMessage.isNotEmpty ? statusMessage : '转录失败';
      return Tooltip(
        message: '$videoName - $msg',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error, size: 16, color: Colors.red.shade400),
                const SizedBox(width: 4),
                const Text(
                  '失败',
                  style: TextStyle(fontSize: 11, color: Colors.red),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              msg,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 9, color: Colors.red.shade300),
            ),
          ],
        ),
      );
    }

    if (status == TranscriptionStatus.idle) {
      if (statusMessage.isNotEmpty) {
        // Show queue position for started tasks
        return Tooltip(
          message: statusMessage,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.hourglass_bottom,
                size: 14,
                color: Colors.amber.shade700,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  statusMessage,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, color: Colors.amber.shade700),
                ),
              ),
            ],
          ),
        );
      }
      return const Text(
        '排队中',
        style: TextStyle(fontSize: 11, color: Colors.grey),
      );
    }

    // Processing states: extracting / uploading / transcribing
    final statusText = switch (status) {
      TranscriptionStatus.extracting => '提取中',
      TranscriptionStatus.uploading => '上传中',
      TranscriptionStatus.transcribing => '转录中',
      TranscriptionStatus.embedding => '内嵌中',
      _ => '处理中',
    };

    final bool hasDetailMessage = statusMessage.isNotEmpty;

    final widget = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(statusText, style: const TextStyle(fontSize: 10)),
            const SizedBox(width: 4),
            Text(
              '${(progress * 100).round()}%',
              style: const TextStyle(fontSize: 9, color: Colors.grey),
            ),
          ],
        ),
        const SizedBox(height: 2),
        SizedBox(
          width: 100,
          child: LinearProgressIndicator(value: progress.clamp(0.0, 1.0)),
        ),
        if (hasDetailMessage) ...[
          const SizedBox(height: 3),
          Text(
            statusMessage,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 9, color: Colors.grey),
          ),
        ],
      ],
    );
    return hasDetailMessage
        ? Tooltip(message: '$videoName - $statusMessage', child: widget)
        : widget;
  }
}
