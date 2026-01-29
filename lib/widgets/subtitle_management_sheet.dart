import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import '../services/embedded_subtitle_service.dart';

class SubtitleManagementSheet extends StatefulWidget {
  final String videoPath;
  final VoidCallback onSubtitleChanged;
  final VoidCallback onOpenAi;
  final Function(List<String> paths)? onSubtitleSelected;
  final Function(String path)? onSubtitlePreview; // New callback
  final VoidCallback? onClose;
  final Map<String, String>? additionalSubtitles;
  final List<String> initialSelectedPaths;

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

  final Map<int, String> _extractedTrackPaths = {}; // Map track index to extracted path

  @override
  void initState() {
    super.initState();
    _selectedPaths = List.from(widget.initialSelectedPaths);
    _loadSubtitles();
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

      // 2. Load Extracted Subtitles from AppDocDir
      final appDocDir = await getApplicationDocumentsDirectory();
      final subDir = Directory(p.join(appDocDir.path, 'subtitles'));
      if (await subDir.exists()) {
        final extractedFiles = subDir.listSync().whereType<File>().where((file) {
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
      }
      
      // 3. Ensure selected paths are in the list (if they exist)
      for (final path in _selectedPaths) {
         final file = File(path);
         if (await file.exists()) {
            final name = p.basename(path);
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
        final service = Provider.of<EmbeddedSubtitleService>(context, listen: false);
        _embeddedTracks = await service.getEmbeddedSubtitles(widget.videoPath);
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
      final appDocDir = await getApplicationDocumentsDirectory();
      final subDir = Directory(p.join(appDocDir.path, 'subtitles'));
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
             
             ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("内嵌字幕提取成功")),
            );

            _handleSelection(path);
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("提取字幕失败，可能格式不支持")),
            );
          }
        }
      }
    } catch (e) {
      debugPrint("Error extracting: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(content: Text("提取出错: $e")),
        );
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
        _loadSubtitles(); // Reload list
        widget.onSubtitleChanged(); // Notify parent
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("删除失败: $e")),
          );
        }
      }
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

  @override
  Widget build(BuildContext context) {
    final shownPaths = <String>{};
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
          const SizedBox(height: 8),
          
          Expanded(
            child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : (_subtitleFiles.isEmpty && _embeddedTracks.isEmpty && _extractedTrackPaths.isEmpty && (widget.additionalSubtitles == null || widget.additionalSubtitles!.isEmpty))
                ? const Center(
                    child: Text("暂无关联字幕文件", 
                      style: TextStyle(color: Colors.white54), textAlign: TextAlign.center),
                  )
                : ListView(
                    children: [
                      // 1. Library/Associated Subtitles (Moved to front)
                      if (widget.additionalSubtitles != null && widget.additionalSubtitles!.isNotEmpty) ...[
                         const Padding(
                          padding: EdgeInsets.only(bottom: 4, top: 4),
                          child: Text("媒体库关联字幕", 
                            style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold)),
                        ),
                        ...widget.additionalSubtitles!.entries.where((entry) => shownPaths.add(entry.value)).map((entry) {
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
                                trailing: null,
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
                      if (_embeddedTracks.isNotEmpty || _extractedTrackPaths.isNotEmpty) ...[
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
                                  "Track $trackIndex",
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
                                trailing: _buildSelectionBadge(path),
                                onTap: exists ? () => _handleSelection(path) : null,
                              ),
                            );
                          }),
                        ],
                        ..._embeddedTracks.map((track) {
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
                                track.title.isNotEmpty && track.title != "未知标题" ? track.title : "Track ${track.index}", 
                                style: const TextStyle(color: Colors.white, fontSize: 13),
                              ),
                              subtitle: Text(
                                "${track.language} • ${track.codecName}",
                                style: const TextStyle(color: Colors.white30, fontSize: 11),
                              ),
                              trailing: _extractedTrackPaths.containsKey(track.index) && _selectedPaths.contains(_extractedTrackPaths[track.index])
                                ? _buildSelectionBadge(_extractedTrackPaths[track.index]!)
                                : const Icon(Icons.download, color: Colors.white70, size: 18),
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
                         ..._subtitleFiles.where((file) => shownPaths.add(file.path)).map((file) {
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
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                                  onPressed: () => _deleteSubtitle(file),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
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
