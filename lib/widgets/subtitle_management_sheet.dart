import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import '../services/embedded_subtitle_service.dart';
import '../services/settings_service.dart';
import '../utils/app_toast.dart';

import 'package:shared_preferences/shared_preferences.dart';

class SubtitleManagementSheet extends StatefulWidget {
  final String videoPath;
  final VoidCallback onSubtitleChanged;
  final VoidCallback onOpenAi;
  final Function(List<String> paths)? onSubtitleSelected;
  final Function(String path)? onSubtitlePreview; // New callback
  final VoidCallback? onClose;
  final Map<String, String>? additionalSubtitles;
  final List<String> initialSelectedPaths;
  final bool showEmbeddedSubtitles;

  const SubtitleManagementSheet({
    super.key,
    required this.videoPath,
    required this.onSubtitleChanged,
    required this.onOpenAi,
    this.onSubtitleSelected,
    this.onSubtitlePreview,
    this.onClose,
    this.additionalSubtitles,
    this.initialSelectedPaths = const [],
    this.showEmbeddedSubtitles = true,
  });

  @override
  State<SubtitleManagementSheet> createState() => _SubtitleManagementSheetState();
}

class _SubtitleManagementSheetState extends State<SubtitleManagementSheet> {
  List<File> _subtitleFiles = [];
  List<EmbeddedSubtitleTrack> _embeddedTracks = [];
  bool _isLoading = true;
  int? _extractingTrackIndex; 
  List<String> _selectedPaths = []; // Track selected items
  String? _customDownloadPath;
  String _defaultDownloadPath = "用户/下载";

  final Map<int, String> _extractedTrackPaths = {}; // Map track index to extracted path

  bool _isImageSubtitleCodec(String codecName) {
    final codec = codecName.toLowerCase();
    return codec == 'hdmv_pgs_subtitle' ||
        codec == 'dvd_subtitle' ||
        codec == 'pgs' ||
        codec == 'pgs_subtitle' ||
        codec == 'vobsub' ||
        codec == 'xsub';
  }

  @override
  void initState() {
    super.initState();
    _selectedPaths = List.from(widget.initialSelectedPaths);
    _loadSubtitles();
    _initDefaultPath();
    _loadCustomDownloadPath();
  }

  void _initDefaultPath() {
    if (Platform.isWindows) {
      try {
        final exeDir = p.dirname(Platform.resolvedExecutable);
        _defaultDownloadPath = p.join(exeDir, 'Downloads');
      } catch (e) {
        // Fallback
      }
    }
  }

  Future<void> _loadCustomDownloadPath() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final path = prefs.getString('subtitle_download_path');
      if (mounted) {
        setState(() {
          _customDownloadPath = path;
        });
      }
    } catch (e) {
      debugPrint("Error loading custom download path: $e");
    }
  }

  Future<void> _setCustomDownloadPath() async {
    try {
      final String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
      if (selectedDirectory != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('subtitle_download_path', selectedDirectory);
        if (mounted) {
          setState(() {
            _customDownloadPath = selectedDirectory;
          });
          AppToast.show("默认下载路径已更新", type: AppToastType.success);
        }
      }
    } catch (e) {
      debugPrint("Error setting custom download path: $e");
    }
  }

  Future<void> _openDownloadDirectory() async {
    try {
      final dir = await _resolveDownloadTargetDir();
      final path = dir.path;
      if (Platform.isWindows) {
        await Process.run('explorer', [path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [path]);
      } else {
        // Android fallback (open file manager not easily supported via Intent without plugin)
        // Try OpenFilex if it's a directory? OpenFilex usually opens files.
        // For now, just show toast on mobile if not supported
         AppToast.show("已保存至: $path", type: AppToastType.info);
      }
    } catch (e) {
      AppToast.show("无法打开文件夹", type: AppToastType.error);
    }
  }

  @override
  void didUpdateWidget(SubtitleManagementSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.videoPath != oldWidget.videoPath) {
      setState(() {
        _isLoading = true;
        _subtitleFiles = [];
        _embeddedTracks = [];
        _extractingTrackIndex = null;
        _selectedPaths = List<String>.from(widget.initialSelectedPaths);
        _extractedTrackPaths.clear();
      });
      _loadSubtitles();
      return;
    }
    if (widget.initialSelectedPaths != oldWidget.initialSelectedPaths) {
      // Only update if the lengths or contents differ
      bool changed = widget.initialSelectedPaths.length != oldWidget.initialSelectedPaths.length;
      if (!changed) {
        for (int i = 0; i < widget.initialSelectedPaths.length; i++) {
          if (widget.initialSelectedPaths[i] != oldWidget.initialSelectedPaths[i]) {
            changed = true;
            break;
          }
        }
      }
      
      if (changed) {
        setState(() {
          _selectedPaths = List.from(widget.initialSelectedPaths);
        });
      }
    }
  }

  Future<void> _loadSubtitles() async {
    setState(() => _isLoading = true);
    try {
      _extractedTrackPaths.clear();
      // 1. Load Local Files
      final videoFile = File(widget.videoPath);
      final dir = videoFile.parent;
      final videoName = p.basenameWithoutExtension(widget.videoPath);
      final extractedPrefix = "$videoName.stream_";
      
      if (await dir.exists()) {
        final files = dir.listSync();
        _subtitleFiles = files.whereType<File>().where((file) {
          final name = p.basename(file.path);
          if (!name.startsWith(videoName)) return false;
          if (name.startsWith(extractedPrefix)) return false;
          final ext = p.extension(file.path).toLowerCase();
          return ['.srt', '.vtt', '.ass', '.ssa', '.sup', '.lrc', '.sub', '.idx', '.scc'].contains(ext);
        }).toList();
      }

      // 2. Load Extracted Subtitles and AI Subtitles from AppDocDir
      final dataRoot = await SettingsService().resolveLargeDataRootDir();
      final subDir = Directory(p.join(dataRoot.path, 'subtitles'));
      if (await subDir.exists()) {
        final docFiles = subDir.listSync().whereType<File>();
        
        // Handle Extracted Streams
        final extractedFiles = docFiles.where((file) {
          final name = p.basename(file.path);
          if (!name.startsWith(extractedPrefix)) return false;
          final ext = p.extension(file.path).toLowerCase();
          return ['.srt', '.vtt', '.ass', '.ssa', '.sup', '.lrc', '.sub', '.idx', '.scc'].contains(ext);
        });

        final pattern = RegExp('^${RegExp.escape(videoName)}\\.stream_(\\d+)');
        for (final file in extractedFiles) {
          final name = p.basename(file.path);
          final match = pattern.firstMatch(name);
          if (match == null) continue;
          final index = int.tryParse(match.group(1) ?? '');
          if (index == null) continue;
          _extractedTrackPaths[index] = file.path;
        }

        // Handle AI Subtitles
        final aiFiles = docFiles.where((file) {
          final name = p.basename(file.path);
          // Match videoName.ai.srt
          return name == "$videoName.ai.srt";
        });
        
        for (final file in aiFiles) {
          if (!_subtitleFiles.any((f) => f.path == file.path)) {
             _subtitleFiles.add(file);
          }
        }
      }
      
      // 3. Ensure selected paths are in the list (if they exist)
      for (final path in _selectedPaths) {
         final file = File(path);
         if (await file.exists()) {
            final name = p.basename(path);
            if (name.contains(".stream_")) {
              continue;
            }
            if (name.startsWith(extractedPrefix)) {
              continue;
            }
            if (!_subtitleFiles.any((f) => f.path == path)) {
               _subtitleFiles.add(file);
            }
         }
      }

      // Sort by modification time (newest first)
      _subtitleFiles.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));

      // 4. Load Embedded Tracks
      if (mounted) {
        if (widget.showEmbeddedSubtitles) {
          final service = Provider.of<EmbeddedSubtitleService>(context, listen: false);
          _embeddedTracks = await service.getEmbeddedSubtitles(widget.videoPath);
        } else {
          _embeddedTracks = [];
        }
      }

    } catch (e) {
      debugPrint("Error listing subtitles: $e");
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _handleEmbeddedTrackSelection(EmbeddedSubtitleTrack track) async {
    // Check if already extracted in this session or we can guess the path
    // Actually, we should check if any selected path matches what this track WOULD produce,
    // but the naming might be variable.
    // If we have mapped it:
    if (_extractedTrackPaths.containsKey(track.index)) {
       final path = _extractedTrackPaths[track.index]!;
       _handleSelection(path);
       return;
    }

    if (_extractingTrackIndex != null) return;
    
    setState(() => _extractingTrackIndex = track.index);
    
    try {
      final dataRoot = await SettingsService().resolveLargeDataRootDir();
      final subDir = Directory(p.join(dataRoot.path, 'subtitles'));
      if (!await subDir.exists()) {
        await subDir.create(recursive: true);
      }
      
      if (mounted) {
        final service = Provider.of<EmbeddedSubtitleService>(context, listen: false);
        // Pass codecName to avoid re-probing issues
        final path = await service.extractSubtitle(widget.videoPath, track.index, subDir.path, codecName: track.codecName);
        
        if (path != null) {
          if (mounted) {
             // Store mapping
             _extractedTrackPaths[track.index] = path;
             
             AppToast.show("内嵌字幕提取成功", type: AppToastType.success);
             if (_isImageSubtitleCodec(track.codecName)) {
               AppToast.show("图像字幕无法转为文本，将以位图显示", type: AppToastType.info);
             }

            _handleSelection(path);
          }
        } else {
          if (mounted) {
            AppToast.show("提取字幕失败，可能格式不支持", type: AppToastType.error);
          }
        }
      }
    } catch (e) {
      debugPrint("Error extracting: $e");
      if (mounted) {
        AppToast.show("提取出错", type: AppToastType.error);
      }
    } finally {
      if (mounted) setState(() => _extractingTrackIndex = null);
    }
  }

  Future<void> _deleteSubtitle(File file) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2C),
        title: const Text("删除字幕", style: TextStyle(color: Colors.white)),
        content: Text("确定要删除 ${p.basename(file.path)} 吗？", 
          style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text("删除"),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await file.delete();
        if (_selectedPaths.contains(file.path)) {
          setState(() {
            _selectedPaths.remove(file.path);
          });
          if (widget.onSubtitleSelected != null) {
            widget.onSubtitleSelected!(_selectedPaths);
          }
        }
        _loadSubtitles(); // Reload list
        widget.onSubtitleChanged(); // Notify parent
      } catch (e) {
        if (mounted) {
          AppToast.show("删除失败", type: AppToastType.error);
        }
      }
    }
  }

  Future<Directory> _resolveDownloadTargetDir() async {
    // 1. 优先使用用户自定义路径
    if (_customDownloadPath != null) {
      final customDir = Directory(_customDownloadPath!);
      if (await customDir.exists()) {
        return customDir;
      }
    }

    if (Platform.isAndroid) {
      // 优先使用公共下载目录，方便用户通过 MT 管理器等访问
      final downloadDir = Directory('/storage/emulated/0/Download');
      if (await downloadDir.exists()) {
        return downloadDir;
      }
      final dir = await getExternalStorageDirectory();
      if (dir != null) return dir;
    }
    if (Platform.isWindows) {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final downloadDir = Directory(p.join(exeDir, 'Downloads'));
      if (!await downloadDir.exists()) {
        await downloadDir.create(recursive: true);
      }
      return downloadDir;
    }
    if (Platform.isLinux || Platform.isMacOS) {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) return downloads;
    }
    return getApplicationDocumentsDirectory();
  }

  String? _resolveMimeType(String path) {
    final ext = p.extension(path).toLowerCase();
    if (ext.isEmpty) return null;
    if ([
      '.srt',
      '.vtt',
      '.ass',
      '.ssa',
      '.lrc',
      '.scc',
      '.sub',
      '.idx',
      '.sup',
    ].contains(ext)) {
      return 'text/plain';
    }
    return null;
  }

  Future<void> _downloadSubtitleFile(String path) async {
    try {
      final sourceFile = File(path);
      if (!await sourceFile.exists()) {
        if (mounted) {
          AppToast.show("字幕文件不存在", type: AppToastType.error);
        }
        return;
      }

      Directory targetDir = await _resolveDownloadTargetDir();
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }

      final sourceDir = p.normalize(p.dirname(path));
      final targetDirPath = p.normalize(targetDir.path);
      String targetPath = path;

      if (sourceDir != targetDirPath) {
        final fileName = p.basename(path);
        String destPath = p.join(targetDir.path, fileName);
        if (await File(destPath).exists()) {
          final base = p.basenameWithoutExtension(fileName);
          final ext = p.extension(fileName);
          destPath = p.join(targetDir.path, "$base.downloaded.${DateTime.now().millisecondsSinceEpoch}$ext");
        }
        await sourceFile.copy(destPath);
        targetPath = destPath;
      }

      if (Platform.isWindows) {
        await Process.run('explorer', ['/select,', targetPath]);
        if (mounted) {
          AppToast.show("字幕已保存", type: AppToastType.success);
        }
      } else {
        final result = await OpenFilex.open(targetPath, type: _resolveMimeType(targetPath));
        if (mounted) {
          if (result.type == ResultType.done) {
            AppToast.show("字幕已下载并打开", type: AppToastType.success);
          } else {
            AppToast.show("字幕已保存，但打开失败", type: AppToastType.error);
          }
        }
      }
    } catch (e) {
      if (mounted) {
        AppToast.show("下载字幕失败", type: AppToastType.error);
      }
    }
  }

  Future<void> _downloadEmbeddedTrack(EmbeddedSubtitleTrack track) async {
    if (_extractingTrackIndex != null) return;
    if (_extractedTrackPaths.containsKey(track.index)) {
      await _downloadSubtitleFile(_extractedTrackPaths[track.index]!);
      return;
    }

    setState(() => _extractingTrackIndex = track.index);

    try {
      final dataRoot = await SettingsService().resolveLargeDataRootDir();
      final subDir = Directory(p.join(dataRoot.path, 'subtitles'));
      if (!await subDir.exists()) {
        await subDir.create(recursive: true);
      }

      if (!mounted) return;
      final service = Provider.of<EmbeddedSubtitleService>(context, listen: false);
      final path = await service.extractSubtitle(widget.videoPath, track.index, subDir.path, codecName: track.codecName);

      if (path != null) {
        _extractedTrackPaths[track.index] = path;
        await _downloadSubtitleFile(path);
      } else {
        if (mounted) {
          AppToast.show("提取字幕失败，可能格式不支持", type: AppToastType.error);
        }
      }
    } catch (e) {
      if (mounted) {
        AppToast.show("提取出错", type: AppToastType.error);
      }
    } finally {
      if (mounted) setState(() => _extractingTrackIndex = null);
    }
  }

  Future<void> _importSubtitle() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['srt', 'vtt', 'lrc', 'ass', 'ssa', 'sup', 'sub', 'idx', 'scc'],
    );

    if (result != null && result.files.single.path != null) {
      final srcFile = File(result.files.single.path!);
      final videoFile = File(widget.videoPath);
      final dir = videoFile.parent;
      final videoName = p.basenameWithoutExtension(widget.videoPath);
      final ext = p.extension(srcFile.path).toLowerCase();
      
      // Copy to video dir so it appears in list
      final newName = "$videoName.imported.${DateTime.now().millisecondsSinceEpoch}$ext";
      final destPath = p.join(dir.path, newName);
      
      await srcFile.copy(destPath);
      _loadSubtitles();
      widget.onSubtitleChanged();
    }
  }

  void _handleSelection(String path) {
     setState(() {
        if (_selectedPaths.contains(path)) {
           _selectedPaths.remove(path);
        } else {
           if (_selectedPaths.length >= 2) {
              // Replace the last one if full? 
              // Or user wants "first click is primary, second is secondary".
              // If we have 2, and click 3rd, let's remove the 2nd (secondary) and add new as secondary.
              _selectedPaths.removeLast();
           }
           _selectedPaths.add(path);
        }
     });
     
     if (widget.onSubtitleSelected != null) {
        widget.onSubtitleSelected!(_selectedPaths);
     }
  }

  Widget _buildSelectionBadge(String path) {
     final index = _selectedPaths.indexOf(path);
     if (index == -1) return const SizedBox.shrink();
     
     return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
           color: index == 0 ? Colors.blueAccent : Colors.orangeAccent,
           borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
           index == 0 ? "主" : "副",
           style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
        ),
     );
  }

  bool _looksLikeBbdownDefaultSubtitle(String path) {
     final name = p.basename(path);
     if (!name.endsWith("_default.srt")) return false;
     final prefix = name.substring(0, name.length - "_default.srt".length);
     return RegExp(r'^[0-9a-fA-F-]{32,36}$').hasMatch(prefix);
  }

  MapEntry<String, String>? _buildBbdownDefaultSubtitleEntry() {
     for (final path in _selectedPaths) {
        if (_looksLikeBbdownDefaultSubtitle(path)) {
           return MapEntry("默认字幕", path);
        }
     }
     return null;
  }

  String _displayEmbeddedTitle(EmbeddedSubtitleTrack track) {
     final title = track.title.trim();
     if (title.isNotEmpty && title != "未知标题") return title;
     final language = track.language.trim();
     if (language.isNotEmpty && language != "未知语言") return language;
     return "内嵌字幕 ${track.index}";
  }

  String _displayEmbeddedTitleByIndex(int index) {
     for (final track in _embeddedTracks) {
        if (track.index == index) {
           return _displayEmbeddedTitle(track);
        }
     }
     return "内嵌字幕 $index";
  }

  @override
  Widget build(BuildContext context) {
    final shownPaths = <String>{};
    final associatedSubtitles = <String, String>{};
    if (widget.additionalSubtitles != null) {
      associatedSubtitles.addAll(widget.additionalSubtitles!);
    }
    final bbdownEntry = _buildBbdownDefaultSubtitleEntry();
    if (bbdownEntry != null && !associatedSubtitles.containsValue(bbdownEntry.value)) {
      String label = bbdownEntry.key;
      if (associatedSubtitles.containsKey(label)) {
        int index = 2;
        String nextLabel = "$label ($index)";
        while (associatedSubtitles.containsKey(nextLabel)) {
          index++;
          nextLabel = "$label ($index)";
        }
        label = nextLabel;
      }
      associatedSubtitles[label] = bbdownEntry.value;
    }
    final hasEmbeddedContent = widget.showEmbeddedSubtitles &&
        (_embeddedTracks.isNotEmpty || _extractedTrackPaths.isNotEmpty);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: const BoxDecoration(
        color: Color(0xFF1E1E1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "字幕管理",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white70),
                onPressed: () {
                  if (widget.onClose != null) {
                    widget.onClose!();
                  } else {
                    Navigator.pop(context);
                  }
                },
                constraints: const BoxConstraints(),
                padding: EdgeInsets.zero,
              ),
            ],
          ),
          
          if (Platform.isWindows) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.download_rounded, color: Colors.white54, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Text(
                        _customDownloadPath ?? "默认: $_defaultDownloadPath",
                        style: TextStyle(
                          color: _customDownloadPath != null ? Colors.white : Colors.white38,
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                        maxLines: 1,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _setCustomDownloadPath,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      backgroundColor: Colors.white10,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                    ),
                    child: const Text("浏览", style: TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: "打开下载目录",
                    child: InkWell(
                      onTap: _openDownloadDirectory,
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.white10,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Icon(Icons.folder, color: Colors.amber, size: 16),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 8),
          
          Expanded(
            child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : (_subtitleFiles.isEmpty && !hasEmbeddedContent && associatedSubtitles.isEmpty)
                ? const Center(
                    child: Text("暂无关联字幕文件", 
                      style: TextStyle(color: Colors.white54), textAlign: TextAlign.center),
                  )
                : ListView(
                    children: [
                      // 1. Library/Associated Subtitles (Moved to front)
                      if (associatedSubtitles.isNotEmpty) ...[
                         const Padding(
                          padding: EdgeInsets.only(bottom: 4, top: 4),
                          child: Text("媒体库关联字幕", 
                            style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold)),
                        ),
                        ...associatedSubtitles.entries.where((entry) => shownPaths.add(entry.value)).map((entry) {
                           final label = entry.key;
                           final path = entry.value;
                           final file = File(path);
                           final exists = file.existsSync();
                           
                           return Container(
                              margin: const EdgeInsets.only(bottom: 4),
                              decoration: BoxDecoration(
                                color: Colors.purpleAccent.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: Colors.purpleAccent.withValues(alpha: 0.2)),
                              ),
                              child: ListTile(
                                dense: true,
                                visualDensity: VisualDensity.compact,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                                leading: const Icon(Icons.subtitles, color: Colors.purpleAccent, size: 20),
                                title: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        label, 
                                        style: TextStyle(
                                          color: _selectedPaths.indexOf(path) == 0 ? Colors.blueAccent : 
                                                 (_selectedPaths.indexOf(path) == 1 ? Colors.orangeAccent : Colors.white),
                                          fontSize: 13,
                                          fontWeight: _selectedPaths.contains(path) ? FontWeight.bold : FontWeight.normal
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    _buildSelectionBadge(path),
                                  ],
                                ),
                                subtitle: Text(
                                  exists ? "已就绪" : "文件丢失",
                                  style: TextStyle(color: exists ? Colors.white30 : Colors.redAccent, fontSize: 11),
                                ),
                                selected: _selectedPaths.contains(path),
                                selectedTileColor: Colors.white10,
                              trailing: IconButton(
                                icon: const Icon(Icons.download_outlined, color: Colors.white70, size: 18),
                                onPressed: exists ? () => _downloadSubtitleFile(path) : null,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                              ),
                                onTap: exists ? () => _handleSelection(path) : null,
                              ),
                           );
                        }),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 4),
                          child: Divider(color: Colors.white10, height: 1),
                        ),
                      ],

                      // 2. Embedded Tracks Section
                      if (hasEmbeddedContent) ...[
                        const Padding(
                          padding: EdgeInsets.only(bottom: 4, top: 4),
                          child: Text("内嵌字幕 (点击提取)", 
                            style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold)),
                        ),
                        if (_embeddedTracks.isEmpty) ...[
                          ..._extractedTrackPaths.entries.where((e) => shownPaths.add(e.value)).map((entry) {
                            final trackIndex = entry.key;
                            final path = entry.value;
                            final exists = File(path).existsSync();
                            return Container(
                              margin: const EdgeInsets.only(bottom: 4),
                              decoration: BoxDecoration(
                                color: Colors.blueAccent.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.2)),
                              ),
                              child: ListTile(
                                dense: true,
                                visualDensity: VisualDensity.compact,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                                leading: const Icon(Icons.closed_caption, color: Colors.blueAccent, size: 20),
                                title: Text(
                                  _displayEmbeddedTitleByIndex(trackIndex),
                                  style: TextStyle(
                                    color: _selectedPaths.contains(path) ? Colors.blueAccent : Colors.white,
                                    fontSize: 13,
                                    fontWeight: _selectedPaths.contains(path) ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                                subtitle: Text(
                                  exists ? p.basename(path) : "文件丢失",
                                  style: TextStyle(color: exists ? Colors.white30 : Colors.redAccent, fontSize: 11),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.download_outlined, color: Colors.white70, size: 18),
                                      onPressed: exists ? () => _downloadSubtitleFile(path) : null,
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                    const SizedBox(width: 4),
                                    _buildSelectionBadge(path),
                                  ],
                                ),
                                onTap: exists ? () => _handleSelection(path) : null,
                              ),
                            );
                          }),
                        ],
                        ..._embeddedTracks.map((track) {
                           final isImage = _isImageSubtitleCodec(track.codecName);
                           return Container(
                            margin: const EdgeInsets.only(bottom: 4),
                            decoration: BoxDecoration(
                              color: Colors.blueAccent.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.2)),
                            ),
                            child: ListTile(
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                              leading: (_extractingTrackIndex == track.index)
                                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.closed_caption, color: Colors.blueAccent, size: 20),
                              title: Text(
                                _displayEmbeddedTitle(track),
                                style: const TextStyle(color: Colors.white, fontSize: 13),
                              ),
                              subtitle: Text(
                                "${track.language} • ${track.codecName}${isImage ? " • 图像字幕" : ""}",
                                style: const TextStyle(color: Colors.white30, fontSize: 11),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.download_outlined, color: Colors.white70, size: 18),
                                    onPressed: _extractingTrackIndex == track.index ? null : () => _downloadEmbeddedTrack(track),
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                  ),
                                  const SizedBox(width: 4),
                                  if (_extractedTrackPaths.containsKey(track.index))
                                    _buildSelectionBadge(_extractedTrackPaths[track.index]!),
                                ],
                              ),
                              onTap: () => _handleEmbeddedTrackSelection(track),
                            ),
                          );
                        }),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 4),
                          child: Divider(color: Colors.white10, height: 1),
                        ),
                      ],

                      // 3. Local Files Section
                      if (_subtitleFiles.isNotEmpty) ...[
                         const Padding(
                          padding: EdgeInsets.only(bottom: 4, top: 4),
                          child: Text("本地字幕", 
                            style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold)),
                        ),
                         ..._subtitleFiles.where((file) => !_extractedTrackPaths.containsValue(file.path) && shownPaths.add(file.path)).map((file) {
                            final name = p.basename(file.path);
                            final isAi = name.contains(".ai.");
                            
                            return Container(
                              margin: const EdgeInsets.only(bottom: 4),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.05),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: ListTile(
                                dense: true,
                                visualDensity: VisualDensity.compact,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                                leading: Icon(
                                  isAi ? Icons.auto_awesome : Icons.subtitles,
                                  color: isAi ? Colors.blueAccent : Colors.white70,
                                  size: 20,
                                ),
                                title: Row(
                                   children: [
                                      Expanded(
                                         child: Text(
                                            name, 
                                            style: TextStyle(
                                              color: _selectedPaths.indexOf(file.path) == 0 ? Colors.blueAccent : 
                                                     (_selectedPaths.indexOf(file.path) == 1 ? Colors.orangeAccent : Colors.white),
                                              fontSize: 13,
                                              fontWeight: _selectedPaths.contains(file.path) ? FontWeight.bold : FontWeight.normal
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                         ),
                                      ),
                                      const SizedBox(width: 8),
                                      _buildSelectionBadge(file.path),
                                   ],
                                ),
                                subtitle: Text(
                                  "${(file.lengthSync() / 1024).toStringAsFixed(1)} KB",
                                  style: const TextStyle(color: Colors.white30, fontSize: 11),
                                ),
                                selected: _selectedPaths.contains(file.path),
                                selectedTileColor: Colors.white10,
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.download_outlined, color: Colors.white70, size: 18),
                                      onPressed: () => _downloadSubtitleFile(file.path),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                    const SizedBox(width: 4),
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                                      onPressed: () => _deleteSubtitle(file),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                  ],
                                ),
                                onTap: () => _handleSelection(file.path),
                              ),
                            );
                         }),
                      ],
                    ],
                  ),
          ),
            
          const SizedBox(height: 12),
          
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _importSubtitle,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text("导入字幕", style: TextStyle(fontSize: 13)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white10,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    if (widget.onClose == null) Navigator.pop(context); // Close sheet if dialog
                    widget.onOpenAi(); // Open AI panel
                  },
                  icon: const Icon(Icons.auto_awesome, size: 18),
                  label: const Text("AI 智能字幕", style: TextStyle(fontSize: 13)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
