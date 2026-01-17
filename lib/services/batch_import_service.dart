import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:ffmpeg_kit_flutter_min_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/return_code.dart';
import 'package:uuid/uuid.dart';

class BatchItem {
  String id;
  String? path;

  BatchItem({required this.id, this.path});

  Map<String, dynamic> toJson() => {'id': id, 'path': path};

  factory BatchItem.fromJson(Map<String, dynamic> json) {
    return BatchItem(
      id: json['id'] ?? Uuid().v4(),
      path: json['path'],
    );
  }
}

class FolderBatchState {
  List<BatchItem> videoItems = [];
  List<BatchItem> subtitleItems = [];
  Map<String, String> importedVideoIds = {}; // videoPath -> libraryId
  Map<String, String> videoDurations = {}; // videoPath -> formatted duration (e.g. 12:34)

  FolderBatchState();

  FolderBatchState.fromJson(Map<String, dynamic> json) {
    if (json['videoPaths'] != null) {
      // Migration from old List<String>
      final paths = List<String>.from(json['videoPaths']);
      videoItems = paths.map((p) => BatchItem(id: Uuid().v4(), path: p)).toList();
    } else if (json['videoItems'] != null) {
      videoItems = (json['videoItems'] as List)
          .map((e) => BatchItem.fromJson(e))
          .toList();
    }

    if (json['subtitlePaths'] != null) {
      // Migration
      final paths = List<String>.from(json['subtitlePaths']);
      subtitleItems = paths.map((p) => BatchItem(id: Uuid().v4(), path: p)).toList();
    } else if (json['subtitleItems'] != null) {
      subtitleItems = (json['subtitleItems'] as List)
          .map((e) => BatchItem.fromJson(e))
          .toList();
    }

    if (json['importedVideoIds'] != null) {
      importedVideoIds = Map<String, String>.from(json['importedVideoIds']);
    }
    if (json['videoDurations'] != null) {
      videoDurations = Map<String, String>.from(json['videoDurations']);
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'videoItems': videoItems.map((e) => e.toJson()).toList(),
      'subtitleItems': subtitleItems.map((e) => e.toJson()).toList(),
      'importedVideoIds': importedVideoIds,
      'videoDurations': videoDurations,
    };
  }
}

class BatchImportService extends ChangeNotifier {
  static final BatchImportService _instance = BatchImportService._internal();
  factory BatchImportService() => _instance;
  BatchImportService._internal();

  Map<String, FolderBatchState> _folderStates = {};
  bool _initialized = false;
  late Directory _appDocDir;
  
  // Font Size Persistence
  double _fontSize = 14.0;
  double get fontSize => _fontSize;

  Future<void> init() async {
    if (_initialized) return;
    _appDocDir = await getApplicationDocumentsDirectory();
    await _loadState();
    _initialized = true;
    notifyListeners();
  }

  // --- Persistence ---

  Future<void> _loadState() async {
    final file = File(p.join(_appDocDir.path, 'batch_import_cache.json'));
    if (!await file.exists()) return;

    try {
      final jsonString = await file.readAsString();
      if (jsonString.isEmpty) return;
      final data = json.decode(jsonString) as Map<String, dynamic>;
      
      _folderStates = {};
      if (data['folders'] != null) {
        // New format
        (data['folders'] as Map<String, dynamic>).forEach((key, value) {
          _folderStates[key] = FolderBatchState.fromJson(value);
        });
        if (data['fontSize'] != null) {
          _fontSize = (data['fontSize'] as num).toDouble();
        }
      } else {
        // Old format (just map of folders)
        data.forEach((key, value) {
          _folderStates[key] = FolderBatchState.fromJson(value);
        });
      }
    } catch (e) {
      debugPrint("Error loading batch import state: $e");
    }
  }

  Future<void> _saveState() async {
    try {
      final file = File(p.join(_appDocDir.path, 'batch_import_cache.json'));
      final foldersData = _folderStates.map((key, value) => MapEntry(key, value.toJson()));
      
      final data = {
        'folders': foldersData,
        'fontSize': _fontSize,
      };
      
      await file.writeAsString(json.encode(data));
    } catch (e) {
      debugPrint("Error saving batch import state: $e");
    }
  }

  void setFontSize(double size) {
    _fontSize = size;
    _saveState();
    notifyListeners();
  }

  // --- Getters ---

  FolderBatchState _getState(String? folderId) {
    final key = folderId ?? "root";
    if (!_folderStates.containsKey(key)) {
      _folderStates[key] = FolderBatchState();
    }
    return _folderStates[key]!;
  }

  List<BatchItem> getVideoItems(String? folderId) {
    _normalizeLists(folderId);
    return _getState(folderId).videoItems;
  }
  
  List<BatchItem> getSubtitleItems(String? folderId) {
    _normalizeLists(folderId);
    return _getState(folderId).subtitleItems;
  }

  // Ensure both lists are same length by padding with empty items
  void _normalizeLists(String? folderId) {
    final state = _getState(folderId);
    int maxLen = state.videoItems.length > state.subtitleItems.length 
        ? state.videoItems.length 
        : state.subtitleItems.length;
    
    // Minimum length for empty state or to allow some drag space? 
    // Maybe not needed, just strictly equal length.
    
    while (state.videoItems.length < maxLen) {
      state.videoItems.add(BatchItem(id: Uuid().v4(), path: null));
    }
    while (state.subtitleItems.length < maxLen) {
      state.subtitleItems.add(BatchItem(id: const Uuid().v4(), path: null));
    }
  }
  
  bool isImported(String? folderId, String videoPath) {
    return _getState(folderId).importedVideoIds.containsKey(videoPath);
  }

  String? getImportedId(String? folderId, String videoPath) {
    return _getState(folderId).importedVideoIds[videoPath];
  }

  String? getDuration(String? folderId, String videoPath) {
    return _getState(folderId).videoDurations[videoPath];
  }

  int getPendingCount(String? folderId) {
    final state = _getState(folderId);
    return state.videoItems
        .where((item) => item.path != null && !state.importedVideoIds.containsKey(item.path!))
        .length;
  }

  // --- Task Queue ---
  final List<Map<String, String?>> _durationTaskQueue = [];
  bool _isProcessingQueue = false;

  // --- Actions ---

  Future<void> addVideos(String? folderId, List<String> paths) async {
    final state = _getState(folderId);
    bool listChanged = false;
    
    // Find first empty slot to fill, or append
    for (var path in paths) {
      // Check if already exists
      if (state.videoItems.any((item) => item.path == path)) continue;

      int emptyIndex = state.videoItems.indexWhere((item) => item.path == null);
      if (emptyIndex != -1) {
        state.videoItems[emptyIndex].path = path;
      } else {
        state.videoItems.add(BatchItem(id: const Uuid().v4(), path: path));
      }
      
      listChanged = true;
      _durationTaskQueue.add({'folderId': folderId, 'path': path});
      notifyListeners();
    }
    
    if (listChanged) {
      _normalizeLists(folderId);
      await _saveState();
      _processDurationQueue();
    }
  }

  Future<void> _processDurationQueue() async {
    if (_isProcessingQueue) return;
    _isProcessingQueue = true;

    while (_durationTaskQueue.isNotEmpty) {
      final task = _durationTaskQueue.removeAt(0);
      final folderId = task['folderId'];
      final path = task['path'];

      if (path != null) {
        await _fetchDuration(folderId, path);
        // Small delay to prevent choking the UI thread if many tasks are queued
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }

    // Save all duration updates at once when queue is empty
    await _saveState();
    _isProcessingQueue = false;
  }

  Future<void> _fetchDuration(String? folderId, String path) async {
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final info = session.getMediaInformation();
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode) && info != null) {
        final durationStr = info.getDuration();
        if (durationStr != null) {
          final durationSeconds = double.tryParse(durationStr);
          if (durationSeconds != null) {
            final formatted = _formatDuration(durationSeconds);
            final state = _getState(folderId);
            state.videoDurations[path] = formatted;
            
            // Notify UI update for this specific item's duration
            notifyListeners();
          }
        }
      }
    } catch (e) {
      debugPrint("Error fetching duration for $path: $e");
    }
  }

  String _formatDuration(double totalSeconds) {
    final duration = Duration(milliseconds: (totalSeconds * 1000).round());
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    String twoDigits(int n) => n.toString().padLeft(2, "0");
    if (hours > 0) {
      return "$hours:${twoDigits(minutes)}:${twoDigits(seconds)}";
    } else {
      return "${twoDigits(minutes)}:${twoDigits(seconds)}";
    }
  }

  Future<void> addSubtitles(String? folderId, List<String> paths) async {
    final state = _getState(folderId);
    bool listChanged = false;

    for (var path in paths) {
      if (state.subtitleItems.any((item) => item.path == path)) continue;

      int emptyIndex = state.subtitleItems.indexWhere((item) => item.path == null);
      if (emptyIndex != -1) {
        state.subtitleItems[emptyIndex].path = path;
      } else {
        state.subtitleItems.add(BatchItem(id: Uuid().v4(), path: path));
      }
      listChanged = true;
    }

    if (listChanged) {
      _normalizeLists(folderId);
      await _saveState();
      notifyListeners();
    }
  }

  Future<void> moveVideo(String? folderId, int oldIndex, int newIndex) async {
    final state = _getState(folderId);
    if (oldIndex < 0 || oldIndex >= state.videoItems.length) return;
    if (newIndex < 0 || newIndex > state.videoItems.length) return;

    if (oldIndex < newIndex) {
      newIndex -= 1;
    }

    final item = state.videoItems.removeAt(oldIndex);
    state.videoItems.insert(newIndex, item);
    
    // We don't need to normalize here because we just swapped positions, length is same
    await _saveState();
    notifyListeners();
  }

  Future<void> moveSubtitle(String? folderId, int oldIndex, int newIndex) async {
    final state = _getState(folderId);
    if (oldIndex < 0 || oldIndex >= state.subtitleItems.length) return;
    if (newIndex < 0 || newIndex > state.subtitleItems.length) return;

    if (oldIndex < newIndex) {
      newIndex -= 1;
    }

    final item = state.subtitleItems.removeAt(oldIndex);
    state.subtitleItems.insert(newIndex, item);
    
    await _saveState();
    notifyListeners();
  }

  Future<void> removeRow(String? folderId, int index) async {
    final state = _getState(folderId);
    if (index < 0 || index >= state.videoItems.length) return;
    
    // 1. Remove Video
    final videoItem = state.videoItems[index];
    if (videoItem.path != null) {
      final bool alreadyImported = state.importedVideoIds.containsKey(videoItem.path!);
      
      // Remove imported marker
      if (alreadyImported) {
         state.importedVideoIds.remove(videoItem.path!);
      }
      
      // Delete file if internal
      // User requested to clear "batch import cache" even if merged,
      // because LibraryService now makes its own persistent copy for merged items.
      await _deleteFileIfInternal(videoItem.path!);
    }
    
    // 2. Remove Subtitle
    if (index < state.subtitleItems.length) {
       final subItem = state.subtitleItems[index];
       if (subItem.path != null) {
         await _deleteFileIfInternal(subItem.path!);
       }
       state.subtitleItems.removeAt(index);
    }
    
    state.videoItems.removeAt(index);

    _normalizeLists(folderId);
    await _saveState();
    notifyListeners();
  }

  Future<void> removeVideoItem(String? folderId, int index) async {
    final state = _getState(folderId);
    if (index < 0 || index >= state.videoItems.length) return;

    final item = state.videoItems[index];
    if (item.path != null) {
      if (state.importedVideoIds.containsKey(item.path!)) {
         state.importedVideoIds.remove(item.path!);
         // If it was imported, we assume Library owns it now, so don't delete file?
         // Or does user want to delete even if imported? 
         // User: "没有合并...删掉了...希望他删除的时候会连着他的视频内存一起删除"
         // This implies only unmerged ones.
      } else {
         // Not imported -> Delete file
         await _deleteFileIfInternal(item.path!);
      }
    }
    
    state.videoItems.removeAt(index);
    _normalizeLists(folderId);
    await _saveState();
    notifyListeners();
  }

  Future<void> removeSubtitleItem(String? folderId, int index) async {
    final state = _getState(folderId);
    if (index < 0 || index >= state.subtitleItems.length) return;
    
    final item = state.subtitleItems[index];
    if (item.path != null) {
      await _deleteFileIfInternal(item.path!);
    }

    state.subtitleItems.removeAt(index);
    _normalizeLists(folderId);
    await _saveState();
    notifyListeners();
  }
  
  // Helper to delete file if it is in app internal directories
  Future<void> _deleteFileIfInternal(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return;

      // Check if inside App Doc Dir
      final appDocDir = await getApplicationDocumentsDirectory();
      if (p.isWithin(appDocDir.path, path)) {
        await file.delete();
        debugPrint("Deleted internal batch file: $path");
        return;
      }

      // Check if inside Temp Dir
      final tempDir = await getTemporaryDirectory();
      if (p.isWithin(tempDir.path, path)) {
        await file.delete();
        debugPrint("Deleted temp batch file: $path");
        return;
      }
      
      // We do NOT delete external files (e.g. in Gallery)
    } catch (e) {
      debugPrint("Error deleting batch file: $e");
    }
  }

  Future<void> markImported(String? folderId, String videoPath, String libraryId) async {
    final state = _getState(folderId);
    state.importedVideoIds[videoPath] = libraryId;
    await _saveState();
    notifyListeners();
  }

  Future<void> unmarkImported(String? folderId, String videoPath) async {
    final state = _getState(folderId);
    state.importedVideoIds.remove(videoPath);
    await _saveState();
    notifyListeners();
  }
}
