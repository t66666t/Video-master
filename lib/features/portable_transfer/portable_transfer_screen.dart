import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/library_service.dart';
import '../../utils/app_toast.dart';
import '../../utils/reveal_in_file_manager.dart';
import '../../utils/android_hardware_input_bridge.dart';
import '../../utils/batch_tool_shortcuts.dart';
import '../../utils/hardware_keyboard_shortcuts.dart';
import '../../utils/page_shortcut_keys.dart';
import 'portable_media_selection.dart';
import 'portable_selection_page.dart';
import 'portable_transfer_models.dart';
import 'portable_transfer_service.dart';

class PortableTransferScreen extends StatefulWidget {
  const PortableTransferScreen({
    super.key,
    this.initialTab = PortableTransferKind.export,
    this.pendingImportSources,
    this.pendingExportRootIds,
  });

  final PortableTransferKind initialTab;
  final List<PortableImportSource>? pendingImportSources;
  final List<String>? pendingExportRootIds;

  @override
  State<PortableTransferScreen> createState() => _PortableTransferScreenState();
}

class _PortableTransferScreenState extends State<PortableTransferScreen> {
  static const MethodChannel _androidFileManagerChannel = MethodChannel(
    'com.example.video_player_app/file_manager',
  );
  final PortableTransferService _service = PortableTransferService.instance;
  late PortableTransferKind _tab;
  bool _picking = false;
  bool _managingTasks = false;
  bool _serviceInitialized = false;
  bool _consumedPendingLaunch = false;
  final Set<String> _selectedTaskIds = <String>{};
  final FocusNode _shortcutFocusNode = FocusNode();
  final AndroidHardwareKeyDeduplicator _androidKeyDeduplicator =
      AndroidHardwareKeyDeduplicator();

  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  @override
  void initState() {
    super.initState();
    AndroidHardwareInputBridge.addKeyListener(_handleAndroidHardwareKeyEvent);
    HardwareKeyboard.instance.addHandler(_handleGlobalHardwareKeyEvent);
    _tab = widget.initialTab;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_consumePendingLaunch());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_serviceInitialized) return;
    _serviceInitialized = true;
    unawaited(_service.initialize(library: context.read<LibraryService>()));
  }

  /// Consume one-shot launch args after the first frame so the import tab or
  /// export-settings sheet appears on top of a fully built page.
  Future<void> _consumePendingLaunch() async {
    if (_consumedPendingLaunch || !mounted) return;
    _consumedPendingLaunch = true;
    final sources = widget.pendingImportSources;
    final exportIds = widget.pendingExportRootIds;
    if (sources != null && sources.isNotEmpty) {
      await _startImportFromSources(sources);
      return;
    }
    if (exportIds != null && exportIds.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (!mounted) return;
      await _prepareExport(exportIds.toSet());
    }
  }

  bool _handleGlobalHardwareKeyEvent(KeyEvent event) {
    if (_shortcutFocusNode.hasFocus) return false;
    return _handleShortcutKeyEvent(event) != KeyEventResult.ignored;
  }

  void _handleAndroidHardwareKeyEvent(AndroidHardwareKeyMessage message) {
    _handleShortcutKeyEvent(
      message.toKeyEvent(),
      fromAndroidNativeBridge: true,
      hasBlockingModifierOverride: message.hasBlockingModifier,
    );
  }

  String _ptTooltip(String label, PortableTransferShortcutAction action) {
    return hoverAwareShortcutTooltip(
      label,
      PortableTransferShortcuts.defaults[action]!,
    );
  }

  KeyEventResult _handleShortcutKeyEvent(
    KeyEvent event, {
    bool fromAndroidNativeBridge = false,
    bool? hasBlockingModifierOverride,
  }) {
    if (!supportsNativeHardwareKeyboardShortcuts) {
      return KeyEventResult.ignored;
    }
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return KeyEventResult.ignored;
    if (Platform.isAndroid &&
        !_androidKeyDeduplicator.shouldDispatch(
          event,
          fromNativeBridge: fromAndroidNativeBridge,
        )) {
      return KeyEventResult.handled;
    }
    if (isEditableTextFocused()) return KeyEventResult.ignored;
    final bool hasBlockingModifier =
        hasBlockingModifierOverride ?? hasBlockingKeyboardModifier();
    if (hasBlockingModifier) return KeyEventResult.ignored;
    final PortableTransferShortcutAction? action =
        PortableTransferShortcuts.matchAction(event.logicalKey);
    final platform = currentNativeTargetPlatform;
    if (action == null ||
        platform == null ||
        !PortableTransferShortcuts.isAvailableOnPlatform(action, platform)) {
      return KeyEventResult.ignored;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    switch (action) {
      case PortableTransferShortcutAction.backOrExitManagement:
        if (_managingTasks) {
          _leaveTaskManagement();
        } else {
          Navigator.of(context).maybePop();
        }
        return KeyEventResult.handled;
      case PortableTransferShortcutAction.exportTab:
        _switchTab(PortableTransferKind.export);
        return KeyEventResult.handled;
      case PortableTransferShortcutAction.importTab:
        _switchTab(PortableTransferKind.import);
        return KeyEventResult.handled;
      case PortableTransferShortcutAction.primaryAction:
        if (_managingTasks) return KeyEventResult.handled;
        if (_tab == PortableTransferKind.export) {
          unawaited(_startExport());
        } else {
          unawaited(_startImport());
        }
        return KeyEventResult.handled;
      case PortableTransferShortcutAction.enterManagement:
        if (!_managingTasks && _manageableTasks.isNotEmpty) {
          _enterTaskManagement();
        }
        return KeyEventResult.handled;
      case PortableTransferShortcutAction.selectAll:
        if (_managingTasks) _toggleSelectAll(_manageableTasks);
        return KeyEventResult.handled;
      case PortableTransferShortcutAction.deleteSelected:
        if (_managingTasks && _selectedTaskIds.isNotEmpty) {
          unawaited(_deleteSelectedTasks());
        }
        return KeyEventResult.handled;
    }
  }

  @override
  void dispose() {
    AndroidHardwareInputBridge.removeKeyListener(
      _handleAndroidHardwareKeyEvent,
    );
    HardwareKeyboard.instance.removeHandler(_handleGlobalHardwareKeyEvent);
    _shortcutFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inheritedTheme = Theme.of(context);
    return Theme(
      data: inheritedTheme.copyWith(
        textTheme: inheritedTheme.textTheme.apply(fontFamily: 'Noto Sans SC'),
        primaryTextTheme: inheritedTheme.primaryTextTheme.apply(
          fontFamily: 'Noto Sans SC',
        ),
        scaffoldBackgroundColor: const Color(0xFF0F1014),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C8CFF),
          brightness: Brightness.dark,
        ),
      ),
      child: Focus(
        focusNode: _shortcutFocusNode,
        autofocus: supportsNativeHardwareKeyboardShortcuts,
        onKeyEvent: (node, event) => _handleShortcutKeyEvent(event),
        child: Scaffold(
          appBar: AppBar(
            backgroundColor: const Color(0xFF0F1014),
            surfaceTintColor: Colors.transparent,
            leading: _managingTasks
                ? IconButton(
                    onPressed: _leaveTaskManagement,
                    tooltip: _ptTooltip(
                      '退出管理',
                      PortableTransferShortcutAction.backOrExitManagement,
                    ),
                    icon: const Icon(Icons.close_rounded),
                  )
                : null,
            title: Text(
              _managingTasks ? '已选择 ${_selectedTaskIds.length} 项' : '导入与导出',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            actions: [
              AnimatedBuilder(
                animation: _service,
                builder: (context, _) {
                  final manageable = _manageableTasks;
                  if (manageable.isEmpty) return const SizedBox.shrink();
                  if (!_managingTasks) {
                    return IconButton(
                      onPressed: _enterTaskManagement,
                      tooltip: _ptTooltip(
                        '批量管理',
                        PortableTransferShortcutAction.enterManagement,
                      ),
                      icon: const Icon(Icons.checklist_rounded),
                    );
                  }
                  final allSelected = manageable.every(
                    (task) => _selectedTaskIds.contains(task.id),
                  );
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        onPressed: () => _toggleSelectAll(manageable),
                        tooltip: _ptTooltip(
                          allSelected ? '取消全选' : '全选',
                          PortableTransferShortcutAction.selectAll,
                        ),
                        icon: Icon(
                          allSelected
                              ? Icons.deselect_rounded
                              : Icons.select_all_rounded,
                        ),
                      ),
                      IconButton(
                        onPressed: _selectedTaskIds.isEmpty
                            ? null
                            : _deleteSelectedTasks,
                        tooltip: _ptTooltip(
                          '删除所选任务',
                          PortableTransferShortcutAction.deleteSelected,
                        ),
                        icon: const Icon(Icons.delete_outline_rounded),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Column(
              children: [
                _buildHeader(),
                Expanded(
                  child: AnimatedBuilder(
                    animation: _service,
                    builder: (context, _) {
                      final tasks = _service.tasks
                          .where((task) => task.kind == _tab)
                          .toList();
                      return AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: tasks.isEmpty
                            ? _EmptyTransferState(
                                key: ValueKey(_tab),
                                kind: _tab,
                                onPressed: _tab == PortableTransferKind.export
                                    ? _startExport
                                    : _startImport,
                              )
                            : ListView.separated(
                                key: ValueKey('list-$_tab'),
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  12,
                                  16,
                                  120,
                                ),
                                itemCount: tasks.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(height: 10),
                                itemBuilder: (context, index) =>
                                    TweenAnimationBuilder<double>(
                                      tween: Tween(begin: 0, end: 1),
                                      duration: Duration(
                                        milliseconds:
                                            180 + index.clamp(0, 4) * 45,
                                      ),
                                      curve: Curves.easeOutCubic,
                                      builder: (context, value, child) =>
                                          Opacity(
                                            opacity: value,
                                            child: Transform.translate(
                                              offset: Offset(
                                                0,
                                                10 * (1 - value),
                                              ),
                                              child: child,
                                            ),
                                          ),
                                      child: _TransferTaskCard(
                                        task: tasks[index],
                                        isDesktop: _isDesktop,
                                        selectionMode: _managingTasks,
                                        selected: _selectedTaskIds.contains(
                                          tasks[index].id,
                                        ),
                                        onCancel: () =>
                                            _service.cancel(tasks[index].id),
                                        onMore: () =>
                                            _showTaskActions(tasks[index]),
                                        onToggleSelection: () =>
                                            _toggleTaskSelection(tasks[index]),
                                        onLongPress: () =>
                                            _enterTaskManagement(tasks[index]),
                                        onOpen: () =>
                                            _openTaskFile(tasks[index]),
                                        onReveal: () =>
                                            _revealTaskFile(tasks[index]),
                                        onShare: () =>
                                            _shareTaskFile(tasks[index]),
                                      ),
                                    ),
                              ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          floatingActionButton: AnimatedBuilder(
            animation: _service,
            builder: (context, _) {
              final hasTasks = _service.tasks.any((task) => task.kind == _tab);
              if (!hasTasks || _managingTasks) return const SizedBox.shrink();
              return FloatingActionButton.extended(
                onPressed: _picking
                    ? null
                    : (_tab == PortableTransferKind.export
                          ? _startExport
                          : _startImport),
                icon: Icon(
                  _tab == PortableTransferKind.export
                      ? Icons.add_rounded
                      : Icons.file_open_outlined,
                ),
                label: Text(
                  _ptTooltip(
                    _tab == PortableTransferKind.export ? '新建导出' : '选择文件',
                    PortableTransferShortcutAction.primaryAction,
                  ),
                ),
              );
            },
          ),
          bottomNavigationBar: _managingTasks
              ? _TaskManagementBar(
                  selectedCount: _selectedTaskIds.length,
                  onDelete: _selectedTaskIds.isEmpty
                      ? null
                      : _deleteSelectedTasks,
                )
              : null,
        ),
      ),
    );
  }

  List<PortableTransferTask> get _manageableTasks => _service.tasks
      .where((task) => task.kind == _tab && !task.isActive)
      .toList(growable: false);

  void _switchTab(PortableTransferKind kind) {
    if (_tab == kind) return;
    setState(() {
      _tab = kind;
      _managingTasks = false;
      _selectedTaskIds.clear();
    });
  }

  void _enterTaskManagement([PortableTransferTask? initiallySelected]) {
    if (initiallySelected?.isActive == true) return;
    setState(() {
      _managingTasks = true;
      if (initiallySelected != null) {
        _selectedTaskIds.add(initiallySelected.id);
      }
    });
  }

  void _leaveTaskManagement() {
    setState(() {
      _managingTasks = false;
      _selectedTaskIds.clear();
    });
  }

  void _toggleTaskSelection(PortableTransferTask task) {
    if (task.isActive) return;
    setState(() {
      if (!_selectedTaskIds.add(task.id)) {
        _selectedTaskIds.remove(task.id);
      }
    });
  }

  void _toggleSelectAll(List<PortableTransferTask> manageable) {
    setState(() {
      final allSelected = manageable.every(
        (task) => _selectedTaskIds.contains(task.id),
      );
      if (allSelected) {
        _selectedTaskIds.removeAll(manageable.map((task) => task.id));
      } else {
        _selectedTaskIds.addAll(manageable.map((task) => task.id));
      }
    });
  }

  Future<void> _showTaskActions(PortableTransferTask task) async {
    if (task.isActive) return;
    final action = await showModalBottomSheet<_TaskAction>(
      context: context,
      backgroundColor: const Color(0xFF1A1C24),
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      task.filePath == null
                          ? task.subtitle
                          : '${task.subtitle}\n${task.filePath}',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.checklist_rounded),
                title: const Text('进入批量管理'),
                subtitle: const Text('可继续勾选其他任务'),
                onTap: () => Navigator.pop(sheetContext, _TaskAction.select),
              ),
              if (_service.canRetry(task.id))
                ListTile(
                  leading: const Icon(Icons.refresh_rounded),
                  title: const Text('重试任务'),
                  subtitle: const Text('会先清理上次中断留下的半成品'),
                  onTap: () => Navigator.pop(sheetContext, _TaskAction.retry),
                ),
              ListTile(
                iconColor: const Color(0xFFFF8490),
                textColor: const Color(0xFFFF9AA4),
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('删除任务…'),
                subtitle: const Text('下一步可选择是否同时删除文件'),
                onTap: () => Navigator.pop(sheetContext, _TaskAction.delete),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case _TaskAction.select:
        _enterTaskManagement(task);
      case _TaskAction.delete:
        await _confirmAndDeleteTasks(<PortableTransferTask>[task]);
      case _TaskAction.retry:
        await _service.retryTask(task.id, context.read<LibraryService>());
      case null:
        break;
    }
  }

  Future<void> _deleteSelectedTasks() async {
    final selected = _manageableTasks
        .where((task) => _selectedTaskIds.contains(task.id))
        .toList(growable: false);
    if (selected.isEmpty) return;
    await _confirmAndDeleteTasks(selected);
  }

  Future<void> _confirmAndDeleteTasks(List<PortableTransferTask> tasks) async {
    final existingPaths = tasks
        .map((task) => task.filePath)
        .whereType<String>()
        .where((path) => path.isNotEmpty && File(path).existsSync())
        .toSet();
    var deleteFiles = true;
    final decision = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            tasks.length == 1 ? '删除这条任务？' : '删除 ${tasks.length} 条任务？',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                existingPaths.isEmpty
                    ? '只会移除任务记录，没有找到仍然存在的关联文件。'
                    : '将移除任务记录，并处理 ${existingPaths.length} 个关联文件。',
                style: const TextStyle(color: Colors.white70, height: 1.4),
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: existingPaths.isNotEmpty && deleteFiles,
                onChanged: existingPaths.isEmpty
                    ? null
                    : (value) =>
                          setDialogState(() => deleteFiles = value ?? true),
                title: const Text('同时删除文件'),
                subtitle: Text(
                  tasks.any((task) => task.kind == PortableTransferKind.import)
                      ? '默认开启；导入任务可能指向你选择的原始 .fluentpack 文件。'
                      : '默认开启；关闭后只删除记录，导出包仍会保留。',
                ),
              ),
              if (existingPaths.isNotEmpty && deleteFiles)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    '文件删除后无法从应用内恢复。',
                    style: TextStyle(color: Color(0xFFFF9AA4), fontSize: 12),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFD9515D),
              ),
              onPressed: () => Navigator.pop(
                dialogContext,
                existingPaths.isNotEmpty && deleteFiles,
              ),
              child: const Text('删除'),
            ),
          ],
        ),
      ),
    );
    if (decision == null || !mounted) return;

    final result = await _service.removeTasks(
      tasks.map((task) => task.id),
      deleteFiles: decision,
    );
    if (!mounted) return;
    setState(() {
      _selectedTaskIds.removeAll(tasks.map((task) => task.id));
      if (_manageableTasks.isEmpty) {
        _managingTasks = false;
        _selectedTaskIds.clear();
      }
    });
    if (result.hasFailures) {
      AppToast.show(
        '${result.failedFilePaths.length} 个文件删除失败，对应任务已保留',
        type: AppToastType.error,
      );
    }
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF191B22),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: PortableTransferKind.values.map((kind) {
            final selected = _tab == kind;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: InkWell(
                  borderRadius: BorderRadius.circular(11),
                  onTap: () => _switchTab(kind),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    height: 42,
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color(0xFF292D3B)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    alignment: Alignment.center,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          kind == PortableTransferKind.export
                              ? Icons.north_east_rounded
                              : Icons.south_west_rounded,
                          size: 18,
                          color: selected
                              ? const Color(0xFFAEB8FF)
                              : Colors.white54,
                        ),
                        const SizedBox(width: 7),
                        Text(
                          kind == PortableTransferKind.export
                              ? '导出 (E)'
                              : '导入 (I)',
                          style: TextStyle(
                            color: selected ? Colors.white : Colors.white60,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Future<void> _startExport() async {
    if (_picking) return;
    final library = context.read<LibraryService>();
    final selected = await Navigator.of(context).push<Set<String>>(
      MaterialPageRoute(
        builder: (_) => PortableSelectionPage(library: library),
      ),
    );
    if (selected == null || selected.isEmpty || !mounted) return;
    await _prepareExport(selected);
  }

  /// Same as tapping "新建导出" after the media tree selection is already known.
  Future<void> _prepareExport(Set<String> selected) async {
    if (_picking || selected.isEmpty) return;
    final library = context.read<LibraryService>();
    final inclusion = PortableMediaSelection(
      selected,
    ).resolveAgainstLibrary(library);
    if (inclusion.isEmpty) {
      AppToast.show('没有可导出的媒体', type: AppToastType.error);
      return;
    }
    final options = await showModalBottomSheet<PortableExportOptions>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ExportOptionsSheet(
        selectedCount: inclusion.mediaCount,
        folderCount: inclusion.folderCount,
      ),
    );
    if (options == null || !mounted) return;

    setState(() => _picking = true);
    try {
      var fileName =
          '${_safeFileName(options.packageName)}.${PortableTransferService.extension}';
      final outputPath = await _chooseExportPath(fileName);
      if (outputPath == null || !mounted) return;
      final normalized =
          outputPath.toLowerCase().endsWith(
            '.${PortableTransferService.extension}',
          )
          ? outputPath
          : '$outputPath.${PortableTransferService.extension}';
      await _service.exportSelection(
        library: library,
        rootIds: selected.toList(),
        outputPath: normalized,
        options: options,
      );
      if (mounted) setState(() => _tab = PortableTransferKind.export);
    } catch (error) {
      AppToast.show('无法开始导出：$error', type: AppToastType.error);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _startImport() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final package = await _pickPortablePackage();
      if (package == null) return;
      if (!mounted) {
        await package.disposeIfOwned();
        return;
      }
      await _importPickedPackage(package, showPreview: true);
    } catch (error) {
      AppToast.show('无法导入：$error', type: AppToastType.error);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// External drop / share already chose the files, so skip picker + preview
  /// and create import tasks immediately so they show up on the import tab.
  Future<void> _startImportFromSources(
    List<PortableImportSource> sources,
  ) async {
    if (_picking || sources.isEmpty) return;
    setState(() => _picking = true);
    try {
      for (final source in sources) {
        if (!mounted) return;
        final package = _PickedPortablePackage(
          source.path,
          displayName: source.displayName,
          ownedTemporaryCopy: source.ownedTemporaryCopy,
        );
        try {
          await _importPickedPackage(package, showPreview: false);
        } catch (error) {
          AppToast.show(
            '无法导入 ${source.displayName}：$error',
            type: AppToastType.error,
          );
          await package.disposeIfOwned();
        }
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _importPickedPackage(
    _PickedPortablePackage package, {
    required bool showPreview,
  }) async {
    var handedToService = false;
    try {
      final preview = await _service.inspectPackage(package.path);
      if (!mounted) return;
      if (showPreview) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (_) => _ImportPreviewDialog(
            preview: preview,
            fileName: package.displayName,
          ),
        );
        if (confirmed != true || !mounted) return;
      }
      await _service.importPackage(
        library: context.read<LibraryService>(),
        packagePath: package.path,
        preview: preview,
        deletePackageWhenDone: package.ownedTemporaryCopy,
      );
      handedToService = true;
      if (mounted) setState(() => _tab = PortableTransferKind.import);
    } finally {
      if (!handedToService) await package.disposeIfOwned();
    }
  }

  Future<void> _openTaskFile(PortableTransferTask task) async {
    if (task.filePath == null) return;
    await OpenFilex.open(
      task.filePath!,
      type: Platform.isAndroid
          ? 'application/zip'
          : PortableTransferService.mimeType,
    );
  }

  Future<void> _shareTaskFile(PortableTransferTask task) async {
    if (task.filePath == null) return;
    final size = MediaQuery.sizeOf(context);
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile(
            task.filePath!,
            // Android cannot globally register a private extension-to-MIME
            // mapping. Advertising the ZIP container lets Files/Downloads
            // index saved packages as archives and surface new ones in Recents.
            mimeType: Platform.isAndroid
                ? 'application/zip'
                : PortableTransferService.mimeType,
          ),
        ],
        subject: task.title,
        // iPad presents sharing as a popover and requires a valid anchor.
        sharePositionOrigin: Rect.fromLTWH(
          size.width / 2,
          size.height / 2,
          1,
          1,
        ),
      ),
    );
  }

  Future<void> _revealTaskFile(PortableTransferTask task) async {
    final path = task.filePath;
    if (path == null) return;
    await revealInFileManager(path);
  }

  Future<String?> _chooseExportPath(String fileName) async {
    if (_isDesktop) {
      return FilePicker.platform.saveFile(
        dialogTitle: '保存 Fluent Player 导出包',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: const [PortableTransferService.extension],
      );
    }

    // file_picker's Android/iOS save API accepts only complete byte buffers.
    // Portable packages may be many gigabytes, so buffering one in RAM is not
    // viable. Generate it as a stream in app storage, then let the task card
    // hand the finished file to the platform share / Files UI.
    final documents = await getApplicationDocumentsDirectory();
    final exportDirectory = Directory(
      p.join(documents.path, 'Fluent Player', 'Exports'),
    );
    await exportDirectory.create(recursive: true);
    return _nextAvailablePath(exportDirectory, fileName);
  }

  Future<_PickedPortablePackage?> _pickPortablePackage() async {
    if (Platform.isAndroid) {
      final selection = await _androidFileManagerChannel
          .invokeMapMethod<String, dynamic>('pickFluentPack');
      if (selection == null) return null;
      final displayName = selection['displayName']?.toString() ?? '';
      if (!PortableTransferService.hasPackageExtension(displayName)) {
        throw const FormatException('只能选择 .fluentpack 文件');
      }
      final directPath = selection['path']?.toString();
      if (directPath != null &&
          directPath.isNotEmpty &&
          await File(directPath).exists()) {
        return _PickedPortablePackage(
          directPath,
          displayName: displayName,
          ownedTemporaryCopy: false,
        );
      }
      final uri = selection['uri']?.toString();
      if (uri == null || uri.isEmpty) {
        throw const FileSystemException('系统文件选择器没有提供可读取的文件');
      }
      final materializedPath = await _androidFileManagerChannel
          .invokeMethod<String>('materializeFluentPackForImport', {
            'uri': uri,
            'displayName': displayName,
          });
      if (materializedPath == null || materializedPath.isEmpty) {
        throw const FileSystemException('无法读取所选 FluentPack 文件');
      }
      return _PickedPortablePackage(
        materializedPath,
        displayName: displayName,
        ownedTemporaryCopy: true,
      );
    }

    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 Fluent Player 导出包',
      type: FileType.custom,
      allowedExtensions: const [PortableTransferService.extension],
      allowMultiple: false,
      withReadStream: true,
    );
    if (picked == null) return null;
    final pickedFile = picked.files.single;
    final validName = PortableTransferService.hasPackageExtension(
      pickedFile.name,
    );
    final validPath =
        pickedFile.path != null &&
        PortableTransferService.hasPackageExtension(pickedFile.path!);
    if (!validName && !validPath) {
      throw const FormatException('只能选择 .fluentpack 文件');
    }
    return _materializePickedPackage(pickedFile);
  }

  Future<_PickedPortablePackage> _materializePickedPackage(
    PlatformFile picked,
  ) async {
    final pickedPath = picked.path;
    if (pickedPath != null && pickedPath.isNotEmpty) {
      final file = File(pickedPath);
      if (await file.exists()) {
        return _PickedPortablePackage(
          file.path,
          displayName: picked.name,
          ownedTemporaryCopy: false,
        );
      }
    }

    final tempRoot = await getTemporaryDirectory();
    final importDirectory = Directory(
      p.join(tempRoot.path, 'fluent_player_portable_imports'),
    );
    await importDirectory.create(recursive: true);
    var fileName = _safeFileName(picked.name);
    if (fileName.isEmpty) {
      fileName = 'import.${PortableTransferService.extension}';
    }
    final target = File(_nextAvailablePath(importDirectory, fileName));
    final sink = target.openWrite();
    try {
      final stream = picked.readStream;
      if (stream != null) {
        await sink.addStream(stream);
      } else if (picked.bytes != null) {
        sink.add(picked.bytes!);
      } else {
        throw const FileSystemException('系统文件选择器没有提供可读取的文件内容');
      }
      await sink.flush();
      await sink.close();
    } catch (_) {
      await sink.close();
      if (await target.exists()) await target.delete();
      rethrow;
    }
    return _PickedPortablePackage(
      target.path,
      displayName: picked.name,
      ownedTemporaryCopy: true,
    );
  }

  static String _nextAvailablePath(Directory directory, String fileName) {
    final extension = p.extension(fileName);
    final stem = p.basenameWithoutExtension(fileName);
    var candidate = p.join(directory.path, fileName);
    var suffix = 2;
    while (File(candidate).existsSync()) {
      candidate = p.join(directory.path, '$stem ($suffix)$extension');
      suffix++;
    }
    return candidate;
  }

  static String _safeFileName(String value) => value
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '');
}

class _PickedPortablePackage {
  final String path;
  final String displayName;
  final bool ownedTemporaryCopy;

  const _PickedPortablePackage(
    this.path, {
    required this.displayName,
    required this.ownedTemporaryCopy,
  });

  Future<void> disposeIfOwned() async {
    if (!ownedTemporaryCopy) return;
    final file = File(path);
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }
}

class _ExportOptionsSheet extends StatefulWidget {
  final int selectedCount;
  final int folderCount;
  const _ExportOptionsSheet({
    required this.selectedCount,
    this.folderCount = 0,
  });

  @override
  State<_ExportOptionsSheet> createState() => _ExportOptionsSheetState();
}

class _ExportOptionsSheetState extends State<_ExportOptionsSheet> {
  late final TextEditingController _nameController;
  bool _wrap = true;
  bool _sidecars = true;
  bool _checksums = true;
  PortableCompression _compression = PortableCompression.fast;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text:
          'Fluent Player ${DateFormat('yyyy-MM-dd HH-mm').format(DateTime.now())}',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inheritedTheme = Theme.of(context);
    return Theme(
      data: inheritedTheme.copyWith(
        textTheme: inheritedTheme.textTheme.apply(fontFamily: 'Noto Sans SC'),
        primaryTextTheme: inheritedTheme.primaryTextTheme.apply(
          fontFamily: 'Noto Sans SC',
        ),
      ),
      child: Material(
        color: const Color(0xFF181A21),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              20,
              12,
              20,
              20 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  '导出设置',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.selectedCount == 0
                      ? '${widget.folderCount} 个文件夹将合并为一个跨平台文件'
                      : widget.folderCount == 0
                      ? '${widget.selectedCount} 个媒体将合并为一个跨平台文件'
                      : '${widget.selectedCount} 个媒体、${widget.folderCount} 个文件夹将合并为一个跨平台文件',
                  style: const TextStyle(color: Colors.white54),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF222532),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.cloud_done_outlined,
                        size: 19,
                        color: Color(0xFFAEB8FF),
                      ),
                      SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          'Bilibili 在线卡片会保留来源、封面、字幕、弹幕和预览图，不携带视频分片、转录音频或物化媒体缓存。',
                          style: TextStyle(
                            color: Colors.white60,
                            fontSize: 12,
                            height: 1.45,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (Platform.isAndroid || Platform.isIOS) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF222532),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.mobile_friendly_rounded,
                          size: 19,
                          color: Color(0xFF70D8A4),
                        ),
                        SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            '移动端会流式生成文件，避免大文件撑爆内存。完成后可在任务卡片中分享、存储到“文件”或用其他应用打开。',
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                              height: 1.45,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                TextField(
                  controller: _nameController,
                  onChanged: (_) => setState(() {}),
                  autofocus: false,
                  decoration: const InputDecoration(
                    labelText: '导出包名称',
                    prefixIcon: Icon(Icons.drive_file_rename_outline),
                  ),
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<PortableCompression>(
                  initialValue: _compression,
                  decoration: const InputDecoration(
                    labelText: '压缩策略',
                    prefixIcon: Icon(Icons.compress_rounded),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: PortableCompression.fast,
                      child: Text('极速 · 推荐给视频'),
                    ),
                    DropdownMenuItem(
                      value: PortableCompression.balanced,
                      child: Text('均衡 · 稍省空间'),
                    ),
                    DropdownMenuItem(
                      value: PortableCompression.smallest,
                      child: Text('最小体积 · 耐心模式'),
                    ),
                  ],
                  onChanged: (value) => setState(() => _compression = value!),
                ),
                const SizedBox(height: 10),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _wrap,
                  onChanged: (value) => setState(() => _wrap = value),
                  title: const Text('最外层包一层文件夹'),
                  subtitle: const Text('解压后桌面不会突然“下文件雨”'),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _sidecars,
                  onChanged: (value) => setState(() => _sidecars = value),
                  title: const Text('包含字幕与附属文件'),
                  subtitle: const Text('保留外挂字幕、弹幕和已管理字幕'),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _checksums,
                  onChanged: (value) => setState(() => _checksums = value),
                  title: const Text('生成完整性校验'),
                  subtitle: const Text('导出前多看一眼，跨设备更安心'),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _nameController.text.trim().isEmpty
                      ? null
                      : () => Navigator.pop(
                          context,
                          PortableExportOptions(
                            packageName: _nameController.text.trim(),
                            wrapInFolder: _wrap,
                            includeSidecars: _sidecars,
                            verifyChecksums: _checksums,
                            compression: _compression,
                          ),
                        ),
                  icon: const Icon(Icons.save_alt_rounded),
                  label: Text(
                    Platform.isAndroid || Platform.isIOS ? '开始导出' : '选择保存位置',
                  ),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
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

class _ImportPreviewDialog extends StatefulWidget {
  final PortablePackagePreview preview;
  final String fileName;
  const _ImportPreviewDialog({required this.preview, required this.fileName});

  @override
  State<_ImportPreviewDialog> createState() => _ImportPreviewDialogState();
}

class _ImportPreviewDialogState extends State<_ImportPreviewDialog> {
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleGlobalHardwareKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalHardwareKeyEvent);
    _focusNode.dispose();
    super.dispose();
  }

  bool _handleGlobalHardwareKeyEvent(KeyEvent event) {
    if (_focusNode.hasFocus) return false;
    return _handleKey(event) != KeyEventResult.ignored;
  }

  KeyEventResult _handleKey(KeyEvent event) {
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (hasBlockingKeyboardModifier()) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      Navigator.pop(context, false);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      Navigator.pop(context, true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final inheritedTheme = Theme.of(context);
    final preview = widget.preview;
    final fileName = widget.fileName;
    return Theme(
      data: inheritedTheme.copyWith(
        textTheme: inheritedTheme.textTheme.apply(fontFamily: 'Noto Sans SC'),
        primaryTextTheme: inheritedTheme.primaryTextTheme.apply(
          fontFamily: 'Noto Sans SC',
        ),
      ),
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (node, event) => _handleKey(event),
        child: AlertDialog(
          icon: const Icon(Icons.inventory_2_outlined, size: 34),
          title: Text(
            preview.packageName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(fileName, style: const TextStyle(color: Colors.white54)),
              const SizedBox(height: 18),
              _PreviewRow(
                icon: Icons.movie_outlined,
                label: '媒体',
                value: '${preview.mediaCount} 个',
              ),
              _PreviewRow(
                icon: Icons.folder_outlined,
                label: '文件夹',
                value: '${preview.folderCount} 个',
              ),
              _PreviewRow(
                icon: Icons.data_usage_rounded,
                label: '原始大小',
                value: _prettyBytes(preview.totalBytes),
              ),
              _PreviewRow(
                icon: preview.hasChecksums
                    ? Icons.verified_user_outlined
                    : Icons.gpp_maybe_outlined,
                label: '完整性清单',
                value: preview.hasChecksums ? '有' : '无',
              ),
              const SizedBox(height: 10),
              const Text(
                '内容将复制到应用管理目录，原文件不会被修改。',
                style: TextStyle(color: Colors.white60, height: 1.4),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消 (Esc)'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('开始导入 (Enter)'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _PreviewRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        Icon(icon, size: 18, color: const Color(0xFFAEB8FF)),
        const SizedBox(width: 10),
        Expanded(child: Text(label)),
        Text(value, style: const TextStyle(color: Colors.white70)),
      ],
    ),
  );
}

class _EmptyTransferState extends StatelessWidget {
  final PortableTransferKind kind;
  final VoidCallback onPressed;
  const _EmptyTransferState({
    super.key,
    required this.kind,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final exporting = kind == PortableTransferKind.export;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 92,
              height: 92,
              decoration: BoxDecoration(
                color: const Color(0xFF202431),
                borderRadius: BorderRadius.circular(28),
              ),
              child: Icon(
                exporting
                    ? Icons.move_to_inbox_outlined
                    : Icons.unarchive_outlined,
                size: 42,
                color: const Color(0xFFAEB8FF),
              ),
            ),
            const SizedBox(height: 22),
            Text(
              exporting ? '把喜欢的东西打成一包' : '把熟悉的东西搬回来',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              exporting
                  ? '选择媒体和文件夹，导出为一个跨平台文件。'
                  : '只接受 .fluentpack 文件，选择后会先验证再导入。',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, height: 1.5),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onPressed,
              icon: Icon(
                exporting ? Icons.add_rounded : Icons.file_open_outlined,
              ),
              label: Text(exporting ? '新建导出 (N)' : '选择导出包 (N)'),
            ),
          ],
        ),
      ),
    );
  }
}

enum _TaskAction { select, retry, delete }

class _TransferTaskCard extends StatelessWidget {
  final PortableTransferTask task;
  final bool isDesktop;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onCancel;
  final VoidCallback onMore;
  final VoidCallback onToggleSelection;
  final VoidCallback onLongPress;
  final VoidCallback onOpen;
  final VoidCallback onReveal;
  final VoidCallback onShare;

  const _TransferTaskCard({
    required this.task,
    required this.isDesktop,
    required this.selectionMode,
    required this.selected,
    required this.onCancel,
    required this.onMore,
    required this.onToggleSelection,
    required this.onLongPress,
    required this.onOpen,
    required this.onReveal,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    final accent = switch (task.status) {
      PortableTransferStatus.completed => const Color(0xFF70D8A4),
      PortableTransferStatus.failed => const Color(0xFFFF8490),
      PortableTransferStatus.cancelled => Colors.white38,
      _ => const Color(0xFF9CA9FF),
    };
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(17),
        onTap: selectionMode && !task.isActive ? onToggleSelection : null,
        onLongPress: task.isActive ? null : onLongPress,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF242838) : const Color(0xFF181A21),
            borderRadius: BorderRadius.circular(17),
            border: Border.all(
              color: selected
                  ? const Color(0xFF9CA9FF).withValues(alpha: 0.72)
                  : Colors.white.withValues(alpha: 0.055),
              width: selected ? 1.4 : 1,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(17),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(15, 15, 10, 11),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: Icon(
                          task.kind == PortableTransferKind.export
                              ? Icons.outbox_outlined
                              : Icons.move_to_inbox_outlined,
                          color: accent,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              task.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              task.error == null
                                  ? task.subtitle
                                  : '${task.subtitle} · ${task.error}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color:
                                    task.status == PortableTransferStatus.failed
                                    ? accent
                                    : Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (selectionMode && !task.isActive)
                        Checkbox(
                          value: selected,
                          onChanged: (_) => onToggleSelection(),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(5),
                          ),
                        )
                      else if (task.isActive &&
                          (task.kind == PortableTransferKind.export ||
                              task.progress < 0.4))
                        IconButton(
                          onPressed: onCancel,
                          tooltip: '取消',
                          icon: const Icon(Icons.close_rounded, size: 20),
                        )
                      else if (task.isActive)
                        const SizedBox(
                          width: 48,
                          height: 48,
                          child: Center(
                            child: SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        )
                      else
                        IconButton(
                          onPressed: onMore,
                          tooltip: '更多操作',
                          icon: const Icon(Icons.more_horiz_rounded),
                        ),
                    ],
                  ),
                ),
                if (task.isActive)
                  LinearProgressIndicator(
                    minHeight: 3,
                    value: task.status == PortableTransferStatus.preparing
                        ? null
                        : task.progress.clamp(0, 1),
                    color: accent,
                    backgroundColor: Colors.white10,
                  )
                else if (task.status == PortableTransferStatus.completed)
                  Container(height: 3, color: accent)
                else
                  const SizedBox(height: 3),
                if (!selectionMode && !task.isActive && task.canOpen)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
                    child: Row(
                      children: [
                        if (isDesktop)
                          TextButton.icon(
                            onPressed: onReveal,
                            icon: const Icon(
                              Icons.folder_open_outlined,
                              size: 17,
                            ),
                            label: const Text('在文件管理器中选中'),
                          )
                        else
                          TextButton.icon(
                            onPressed: onShare,
                            icon: const Icon(Icons.ios_share_rounded, size: 17),
                            label: const Text('分享'),
                          ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: onOpen,
                          icon: const Icon(Icons.open_in_new_rounded, size: 17),
                          label: Text(isDesktop ? '打开' : '其他应用'),
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

class _TaskManagementBar extends StatelessWidget {
  final int selectedCount;
  final VoidCallback? onDelete;

  const _TaskManagementBar({
    required this.selectedCount,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: const BoxDecoration(
        color: Color(0xFF181A21),
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              selectedCount == 0 ? '点按任务进行选择' : '已选择 $selectedCount 项',
              style: const TextStyle(color: Colors.white70),
            ),
          ),
          FilledButton.icon(
            onPressed: onDelete,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFD9515D),
              disabledBackgroundColor: Colors.white10,
            ),
            icon: const Icon(Icons.delete_outline_rounded, size: 19),
            label: const Text('删除 (R)'),
          ),
        ],
      ),
    ),
  );
}

String _prettyBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
