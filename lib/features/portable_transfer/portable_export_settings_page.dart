import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../services/library_service.dart';
import '../../utils/app_toast.dart';
import 'portable_export_format_page.dart';
import 'portable_transfer_models.dart';
import 'portable_transfer_service.dart';

class PortableExportSettingsPage extends StatefulWidget {
  const PortableExportSettingsPage({
    super.key,
    required this.library,
    required this.rootIds,
    required this.format,
    required this.mediaCount,
    required this.folderCount,
  });

  final LibraryService library;
  final List<String> rootIds;
  final PortableExportFormatChoice format;
  final int mediaCount;
  final int folderCount;

  @override
  State<PortableExportSettingsPage> createState() =>
      _PortableExportSettingsPageState();
}

class _PortableExportSettingsPageState extends State<PortableExportSettingsPage> {
  late final TextEditingController _nameController;
  var _wrap = true;
  var _sidecars = true;
  var _checksums = true;
  var _includeDanmaku = false;
  var _embedSubtitles = true;
  var _externalSubtitles = false;
  var _starting = false;
  PortableCompression _compression = PortableCompression.fast;

  bool get _zip => widget.format == PortableExportFormatChoice.zip;

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

  Future<void> _start() async {
    if (_starting) return;
    final packageName = _nameController.text.trim();
    if (packageName.isEmpty) return;
    setState(() => _starting = true);
    try {
      final extension = _zip ? 'zip' : PortableTransferService.extension;
      final outputPath = await _chooseOutputPath(
        fileName: '${_safeFileName(packageName)}.$extension',
        extension: extension,
        zip: _zip,
      );
      if (outputPath == null || !mounted) return;
      await PortableTransferService.instance.exportSelection(
        library: widget.library,
        rootIds: widget.rootIds,
        outputPath: outputPath,
        options: PortableExportOptions(
          packageName: packageName,
          wrapInFolder: _zip ? false : _wrap,
          includeSidecars: _zip ? false : _sidecars,
          verifyChecksums: _zip ? false : _checksums,
          compression: _compression,
          format: _zip
              ? PortableExportFormat.zip
              : PortableExportFormat.fluentPack,
          zipEmbedSubtitles: _embedSubtitles,
          zipExternalSubtitles: _externalSubtitles,
          includeDanmaku: _includeDanmaku,
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      AppToast.show('无法开始导出：$error', type: AppToastType.error);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inheritedTheme = Theme.of(context);
    final mobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    return PortableExportEscapeScope(
      child: Theme(
        data: inheritedTheme.copyWith(
          textTheme: inheritedTheme.textTheme.apply(fontFamily: 'Noto Sans SC'),
          primaryTextTheme: inheritedTheme.primaryTextTheme.apply(
            fontFamily: 'Noto Sans SC',
          ),
        ),
        child: Scaffold(
          backgroundColor: const Color(0xFF0F1014),
          appBar: AppBar(
            title: Text(_zip ? 'Zip 导出设置' : 'Fluent Pack 导出设置'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              Text(
                _summary(widget.mediaCount, widget.folderCount),
                style: const TextStyle(color: Colors.white54, height: 1.4),
              ),
              const SizedBox(height: 12),
              _note(
                icon: _zip
                    ? Icons.folder_zip_outlined
                    : Icons.cloud_done_outlined,
                text: _zip
                    ? '视频按卡片标题命名，同一层重名会自动加上序号。文件夹只保留选中媒体之间需要的层级，不再额外套一层导出包名称。软字幕和外挂字幕可以同时打开。封面和章节只在需要时写入，不会重新编码。需要写入时会占用大约等于这些视频大小的临时空间，完成后会删掉。在线卡片会跳过。'
                    : 'Bilibili 在线卡片会保留来源、封面、字幕、弹幕和预览图，不携带视频分片、转录音频或物化媒体缓存。',
              ),
              if (mobile) ...[
                const SizedBox(height: 10),
                _note(
                  icon: Icons.mobile_friendly_rounded,
                  color: const Color(0xFF70D8A4),
                  text: '移动端会流式生成文件，避免大文件撑爆内存。完成后可在任务卡片中分享、存储到“文件”或用其他应用打开。',
                ),
              ],
              const SizedBox(height: 20),
              TextField(
                controller: _nameController,
                onChanged: (_) => setState(() {}),
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
                onChanged: _starting
                    ? null
                    : (value) => setState(() => _compression = value!),
              ),
              if (_zip) ...[
                const SizedBox(height: 18),
                const Text('字幕', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                const Text(
                  '范围是这张卡片上已经关联的全部字幕。两个都可以打开。文件里原来就有的字幕会保留，从成片里拆出来的副本不会再嵌一遍。',
                  style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.4),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _embedSubtitles,
                  onChanged: _starting
                      ? null
                      : (value) => setState(() => _embedSubtitles = value),
                  title: const Text('软字幕内嵌'),
                  subtitle: const Text('写进视频，播放器里可以切换。多数播放器一次显示一条。'),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _externalSubtitles,
                  onChanged: _starting
                      ? null
                      : (value) => setState(() => _externalSubtitles = value),
                  title: const Text('外挂字幕'),
                  subtitle: const Text('在视频旁边再放一份字幕文件。只有一条时使用同名文件。'),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _includeDanmaku,
                  onChanged: _starting
                      ? null
                      : (value) => setState(() => _includeDanmaku = value),
                  title: const Text('包含弹幕'),
                  subtitle: Text(_danmakuSubtitle(_embedSubtitles, _externalSubtitles)),
                ),
              ] else ...[
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _wrap,
                  onChanged: _starting
                      ? null
                      : (value) => setState(() => _wrap = value),
                  title: const Text('最外层包一层文件夹'),
                  subtitle: const Text('解压后桌面不会突然“下文件雨”'),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _sidecars,
                  onChanged: _starting
                      ? null
                      : (value) => setState(() => _sidecars = value),
                  title: const Text('包含字幕与附属文件'),
                  subtitle: const Text('保留外挂字幕、弹幕和已管理字幕'),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _checksums,
                  onChanged: _starting
                      ? null
                      : (value) => setState(() => _checksums = value),
                  title: const Text('生成完整性校验'),
                  subtitle: const Text('导出前多看一眼，跨设备更安心'),
                ),
              ],
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _nameController.text.trim().isEmpty || _starting
                    ? null
                    : _start,
                icon: const Icon(Icons.save_alt_rounded),
                label: Text(mobile ? '开始导出' : '选择保存位置'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _note({
  required IconData icon,
  required String text,
  Color color = const Color(0xFFAEB8FF),
}) {
  return Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFF222532),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 19, color: color),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: Colors.white60,
              fontSize: 12,
              height: 1.45,
            ),
          ),
        ),
      ],
    ),
  );
}

String _danmakuSubtitle(bool embed, bool external) {
  if (embed && external) {
    return '嵌进视频，并另存为旁边的「标题.弹幕.ass」。播放器里需要手动打开那条轨道。';
  }
  if (external) return '保存为旁边的「标题.弹幕.ass」。';
  return '作为一条不自动打开的软字幕嵌进视频。支持 ASS 的播放器里可以手动打开，看到滚动弹幕。';
}

String _summary(int mediaCount, int folderCount) {
  if (mediaCount == 0) {
    return '$folderCount 个文件夹将合并为一个文件';
  }
  if (folderCount == 0) return '$mediaCount 个媒体将合并为一个文件';
  return '$mediaCount 个媒体、$folderCount 个文件夹将合并为一个文件';
}

Future<String?> _chooseOutputPath({
  required String fileName,
  required String extension,
  required bool zip,
}) async {
  final desktop = !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
  if (desktop) {
    final picked = await FilePicker.platform.saveFile(
      dialogTitle: zip ? '保存 Zip' : '保存 Fluent Pack',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: <String>[extension],
    );
    if (picked == null || picked.trim().isEmpty) return null;
    return picked.toLowerCase().endsWith('.$extension')
        ? picked
        : '$picked.$extension';
  }
  final documents = await getApplicationDocumentsDirectory();
  final exportDirectory = Directory(
    p.join(documents.path, 'Fluent Player', 'Exports'),
  );
  await exportDirectory.create(recursive: true);
  return _nextAvailablePath(exportDirectory, fileName);
}

String _nextAvailablePath(Directory directory, String fileName) {
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

String _safeFileName(String value) => value
    .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
    .replaceAll(RegExp(r'[. ]+$'), '');
