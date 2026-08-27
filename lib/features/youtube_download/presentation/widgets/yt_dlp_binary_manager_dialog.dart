import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/youtube_download/services/yt_dlp_binary_location_store.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_binary_updater.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_download_service.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_version.dart';

class YtDlpBinaryManagerDialog extends StatefulWidget {
  final YtDlpDownloadService service;

  const YtDlpBinaryManagerDialog({super.key, required this.service});

  @override
  State<YtDlpBinaryManagerDialog> createState() =>
      _YtDlpBinaryManagerDialogState();
}

class _YtDlpBinaryManagerDialogState extends State<YtDlpBinaryManagerDialog> {
  late final TextEditingController _managedDirectoryController;
  late final TextEditingController _customBinaryController;
  String? _managedActionError;
  String? _customActionError;
  String? _updateActionError;

  YtDlpDownloadService get service => widget.service;

  @override
  void initState() {
    super.initState();
    final locations = service.binaryLocationSettings;
    _managedDirectoryController = TextEditingController(
      text: locations?.managedDirectory ?? '',
    );
    _customBinaryController = TextEditingController(
      text: locations?.customBinaryPath ?? '',
    );
  }

  @override
  void dispose() {
    _managedDirectoryController.dispose();
    _customBinaryController.dispose();
    super.dispose();
  }

  Future<void> _selectSource(YtDlpBinarySource source) async {
    setState(() {
      _managedActionError = null;
      _customActionError = null;
    });
    if (source == YtDlpBinarySource.custom) {
      final applied = await service.applyCustomYtDlpPath(
        _customBinaryController.text,
      );
      if (!applied) return;
    } else {
      final savedDirectory =
          service.binaryLocationSettings?.managedDirectory ?? '';
      final visibleDirectory = _managedDirectoryController.text.trim();
      if (visibleDirectory.isNotEmpty &&
          !p.equals(savedDirectory, visibleDirectory)) {
        final migrated = await service.migrateManagedYtDlpDirectory(
          visibleDirectory,
        );
        if (!migrated) return;
      }
    }
    await service.selectYtDlpBinarySource(source);
  }

  Future<void> _migrateManagedDirectory([String? selectedPath]) async {
    final path = selectedPath ?? _managedDirectoryController.text;
    setState(() => _managedActionError = null);
    final success = await service.migrateManagedYtDlpDirectory(path);
    if (!mounted) return;
    if (success) {
      _managedDirectoryController.text =
          service.binaryLocationSettings?.managedDirectory ?? path;
    }
  }

  Future<void> _pickManagedDirectory() async {
    final selected = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择 yt-dlp 迁移目标文件夹',
      initialDirectory: _managedDirectoryController.text.trim().isEmpty
          ? null
          : _managedDirectoryController.text.trim(),
      lockParentWindow: true,
    );
    if (selected == null || selected.isEmpty) return;
    _managedDirectoryController.text = selected;
    await _migrateManagedDirectory(selected);
  }

  Future<void> _applyCustomBinary([String? selectedPath]) async {
    final path = selectedPath ?? _customBinaryController.text;
    setState(() => _customActionError = null);
    final success = await service.applyCustomYtDlpPath(path);
    if (!mounted || !success) return;
    _customBinaryController.text =
        service.binaryLocationSettings?.customBinaryPath ?? path;
  }

  Future<void> _pickCustomBinary() async {
    final selected = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 yt-dlp 文件',
      type: FileType.any,
      allowMultiple: false,
      lockParentWindow: true,
    );
    final path = selected?.files.single.path;
    if (path == null || path.isEmpty) return;
    _customBinaryController.text = path;
    await _applyCustomBinary(path);
  }

  Future<void> _openFolder({
    required String path,
    required bool pathIsFile,
    required bool managed,
  }) async {
    final target = pathIsFile ? p.dirname(path.trim()) : path.trim();
    void setError(String? value) {
      if (!mounted) return;
      setState(() {
        if (managed) {
          _managedActionError = value;
        } else {
          _customActionError = value;
        }
      });
    }

    if (target.isEmpty || !await Directory(target).exists()) {
      setError('文件夹不存在，无法打开');
      return;
    }
    try {
      final result = Platform.isWindows
          ? await Process.run('explorer', [target])
          : Platform.isMacOS
          ? await Process.run('/usr/bin/open', [target])
          : await Process.run('xdg-open', [target]);
      if (result.exitCode != 0) {
        setError('文件资源管理器未能打开该位置');
      } else {
        setError(null);
      }
    } catch (error) {
      setError('打开文件夹失败：$error');
    }
  }

  Future<void> _updateYtDlp() async {
    setState(() => _updateActionError = null);
    try {
      await service.updateYtDlpToLatest();
    } catch (error) {
      if (!mounted) return;
      setState(() => _updateActionError = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final status = service.binaryStatus;
        final latest =
            service.latestYtDlpRelease?.version ?? service.bundledYtDlpVersion;
        final latestLabel = YtDlpVersions.latestStableLabel(
          latest,
          supportsOnlineUpdate: YtDlpBinaryUpdater.supportsOnlineUpdate,
        );
        final canUpdate =
            service.supportsOnlineYtDlpUpdate &&
            !service.isUpdatingYtDlp &&
            !service.isApplyingYtDlpPath &&
            !service.isResolving &&
            !service.hasProcessingTasks;
        final progress = service.ytDlpUpdateProgress;

        return AlertDialog(
          backgroundColor: const Color(0xFF222326),
          title: const Text('yt-dlp 环境'),
          content: SizedBox(
            width: service.supportsDesktopYtDlpPaths ? 760 : 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 24,
                    runSpacing: 6,
                    children: [
                      Text('当前版本：${status.ytDlpVersion ?? '不可用'}'),
                      Text('最新稳定版：$latestLabel'),
                      Text('ffmpeg：${status.ffmpegAvailabilityLabel}'),
                    ],
                  ),
                  if (service.supportsDesktopYtDlpPaths) ...[
                    const SizedBox(height: 18),
                    _buildManagedRow(),
                    const SizedBox(height: 16),
                    _buildCustomRow(),
                  ],
                  if (service.isUpdatingYtDlp) ...[
                    const SizedBox(height: 16),
                    LinearProgressIndicator(value: progress),
                    const SizedBox(height: 6),
                    Text(
                      service.ytDlpUpdateStage,
                      style: const TextStyle(color: Colors.lightBlueAccent),
                    ),
                  ],
                  ..._errorWidgets([
                    _updateActionError,
                    service.ytDlpUpdateError,
                    if (!status.ytDlpReady) status.diagnosticMessage,
                  ]),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: service.isApplyingYtDlpPath || service.isUpdatingYtDlp
                  ? null
                  : () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
            FilledButton.icon(
              onPressed: canUpdate ? _updateYtDlp : null,
              icon: const Icon(Icons.system_update_alt_rounded),
              label: Text(
                service.isUpdatingYtDlp
                    ? '更新中${progress == null ? '' : ' ${(progress * 100).toStringAsFixed(0)}%'}'
                    : '在线更新 yt-dlp',
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildManagedRow() {
    final selected = service.usesManagedYtDlp;
    return _buildPathRow(
      checkbox: Checkbox(
        value: selected,
        onChanged: service.isApplyingYtDlpPath
            ? null
            : (value) {
                if (value == true && !selected) {
                  _selectSource(YtDlpBinarySource.managed);
                }
              },
      ),
      title: '软件管理的 yt-dlp 文件夹',
      version: service.managedYtDlpVersion,
      controller: _managedDirectoryController,
      onSubmitted: _migrateManagedDirectory,
      error: _managedActionError ?? service.managedYtDlpPathError,
      buttons: [
        OutlinedButton.icon(
          onPressed: service.isApplyingYtDlpPath
              ? null
              : () => _openFolder(
                  path: _managedDirectoryController.text,
                  pathIsFile: false,
                  managed: true,
                ),
          icon: const Icon(Icons.folder_open_rounded, size: 18),
          label: const Text('打开文件夹'),
        ),
        OutlinedButton.icon(
          onPressed: service.isApplyingYtDlpPath ? null : _pickManagedDirectory,
          icon: const Icon(Icons.drive_file_move_rounded, size: 18),
          label: const Text('迁移'),
        ),
        IconButton(
          tooltip: '应用手动输入的路径并迁移',
          onPressed: service.isApplyingYtDlpPath
              ? null
              : _migrateManagedDirectory,
          icon: const Icon(Icons.check_rounded),
        ),
      ],
    );
  }

  Widget _buildCustomRow() {
    final selected = !service.usesManagedYtDlp;
    return _buildPathRow(
      checkbox: Checkbox(
        value: selected,
        onChanged: service.isApplyingYtDlpPath
            ? null
            : (value) {
                if (value == true && !selected) {
                  _selectSource(YtDlpBinarySource.custom);
                }
              },
      ),
      title: '用户指定的 yt-dlp 文件',
      version: service.customYtDlpVersion,
      controller: _customBinaryController,
      onSubmitted: _applyCustomBinary,
      error: _customActionError ?? service.customYtDlpPathError,
      buttons: [
        OutlinedButton.icon(
          onPressed: service.isApplyingYtDlpPath
              ? null
              : () => _openFolder(
                  path: _customBinaryController.text,
                  pathIsFile: true,
                  managed: false,
                ),
          icon: const Icon(Icons.folder_open_rounded, size: 18),
          label: const Text('打开文件夹'),
        ),
        OutlinedButton.icon(
          onPressed: service.isApplyingYtDlpPath ? null : _pickCustomBinary,
          icon: const Icon(Icons.file_open_rounded, size: 18),
          label: const Text('选择文件'),
        ),
        IconButton(
          tooltip: '应用手动输入的文件路径',
          onPressed: service.isApplyingYtDlpPath ? null : _applyCustomBinary,
          icon: const Icon(Icons.check_rounded),
        ),
      ],
    );
  }

  Widget _buildPathRow({
    required Widget checkbox,
    required String title,
    required String? version,
    required TextEditingController controller,
    required ValueChanged<String> onSubmitted,
    required String? error,
    required List<Widget> buttons,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(top: 23), child: checkbox),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(title)),
                  Text('版本：${version ?? '不可用'}'),
                ],
              ),
              const SizedBox(height: 6),
              TextField(
                controller: controller,
                onSubmitted: onSubmitted,
                enabled: !service.isApplyingYtDlpPath,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: buttons),
              if (error != null && error.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                SelectableText(
                  error,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _errorWidgets(List<String?> errors) {
    final unique = errors
        .whereType<String>()
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet();
    if (unique.isEmpty) return const [];
    return [
      const SizedBox(height: 14),
      ...unique.map(
        (error) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: SelectableText(
            error,
            style: const TextStyle(color: Colors.redAccent, fontSize: 12),
          ),
        ),
      ),
    ];
  }
}
