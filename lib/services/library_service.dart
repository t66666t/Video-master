import 'dart:convert';
import 'dart:math';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter/return_code.dart';
import '../models/video_collection.dart';
import '../models/video_item.dart';
import 'thumbnail_cache_service.dart';

class LibraryService extends ChangeNotifier {
  static final LibraryService _instance = LibraryService._internal();
  factory LibraryService() => _instance;
  LibraryService._internal();

  // Unified storage: ID -> Object
  Map<String, VideoCollection> _collections = {}; 
  Map<String, VideoItem> _videos = {};
  
  // Root level structure (IDs of collections and videos at root)
  List<String> _rootChildrenIds = [];

  // Legacy getters (backward compatibility) - DO NOT USE FOR NEW LOGIC if possible
  List<VideoCollection> get collections => _collections.values
      .where((c) => c.parentId == null && !c.isRecycled)
      .toList()
      ..sort((a, b) => b.createTime.compareTo(a.createTime)); // Default sort

  // New: Get Recycle Bin Items (Mixed)
  List<dynamic> getRecycleBinContents() {
    final recycledCols = _collections.values.where((c) => c.isRecycled).toList();
    final recycledVideos = _videos.values.where((v) => v.isRecycled).toList();
    
    // Logic: Only show items whose parent is NOT recycled (or has no parent).
    // If a parent is recycled, its children are implicitly recycled and hidden from top-level bin view.
    // However, if we support independent recycling, we need to check parent status.
    
    // Helper to check if any ancestor is recycled
    bool isAncestorRecycled(String? parentId) {
      if (parentId == null) return false;
      final parentCol = _collections[parentId];
      if (parentCol == null) return false; // Parent missing, treat as root-ish
      if (parentCol.isRecycled) return true;
      return isAncestorRecycled(parentCol.parentId);
    }

    final visibleCols = recycledCols.where((c) => !isAncestorRecycled(c.parentId)).toList();
    final visibleVideos = recycledVideos.where((v) => !isAncestorRecycled(v.parentId)).toList();

    return [...visibleCols, ...visibleVideos]..sort((a, b) {
      // Sort by recycle time if available, else updated time
      final timeA = (a is VideoCollection ? a.recycleTime : (a as VideoItem).recycleTime) ?? 0;
      final timeB = (b is VideoCollection ? b.recycleTime : (b as VideoItem).recycleTime) ?? 0;
      return timeB.compareTo(timeA);
    });
  }
  
  VideoItem? getVideo(String id) => _videos[id];
  VideoCollection? getCollection(String id) => _collections[id];
  
  /// 获取指定文件夹中的所有视频（不包括回收站中的），并按照正确的顺序排列
  List<VideoItem> getVideosInFolder(String? folderId) {
    List<String> sourceIds;
    if (folderId == null) {
      sourceIds = _rootChildrenIds;
    } else {
      final collection = _collections[folderId];
      if (collection == null) return [];
      sourceIds = collection.childrenIds;
    }

    final List<VideoItem> result = [];
    for (var id in sourceIds) {
      final video = _videos[id];
      if (video != null && !video.isRecycled) {
        result.add(video);
      }
    }
    return result;
  }
  
  // Helper function to detect media type from file extension
  MediaType _detectMediaType(String path) {
    final ext = p.extension(path).toLowerCase();
    final audioExtensions = {
      '.mp3', '.m4a', '.wav', '.flac', '.ogg', '.aac', '.wma', '.opus', '.m4b', '.aiff'
    };
    
    if (audioExtensions.contains(ext)) {
      return MediaType.audio;
    }
    return MediaType.video;
  }
  
  // Import Progress
  final ValueNotifier<bool> isImporting = ValueNotifier(false);
  final ValueNotifier<double> importProgress = ValueNotifier(0.0);
  final ValueNotifier<String> importStatus = ValueNotifier("");
  
  bool _initialized = false;
  late Directory _appDocDir;
  
  // Initialize and load data
  Future<void> init() async {
    if (_initialized) return;
    
    _appDocDir = await getApplicationDocumentsDirectory();
    await _loadLibrary();
    
    _initialized = true;
    notifyListeners();
  }

  Future<void> _loadLibrary() async {
    final file = File(p.join(_appDocDir.path, 'library.json'));
    final backupFile = File(p.join(_appDocDir.path, 'library.json.bak'));

    if (!await file.exists()) {
      // Try backup if main file missing
      if (await backupFile.exists()) {
        try {
          await _parseLibraryData(await backupFile.readAsString());
          // Restore main file from backup
          await backupFile.copy(file.path);
        } catch (e) {
          developer.log('Error loading backup library', error: e);
        }
      }
      return;
    }

    try {
      final jsonString = await file.readAsString();
      if (jsonString.isEmpty) throw const FormatException("Empty JSON file");
      await _parseLibraryData(jsonString);
    } catch (e) {
      developer.log('Error loading library', error: e);
      // Try backup
      if (await backupFile.exists()) {
        developer.log('Attempting to load from backup...');
        try {
          await _parseLibraryData(await backupFile.readAsString());
          // We don't overwrite the corrupt main file immediately to allow manual inspection if needed,
          // but the next save will overwrite it.
        } catch (e2) {
          developer.log('Error loading backup library', error: e2);
        }
      }
    }
  }

  Future<void> _parseLibraryData(String jsonString) async {
    final data = json.decode(jsonString);
    
    // Load Collections
    if (data['collections'] != null) {
      final list = (data['collections'] as List).map((e) => VideoCollection.fromJson(e)).toList();
      _collections = {for (var c in list) c.id: c};
    }
    
    // Load Videos
    if (data['videos'] != null) {
      final list = (data['videos'] as List).map((e) => VideoItem.fromJson(e)).toList();
      _videos = {for (var v in list) v.id: v};
    }

    // Load Root Children IDs
    if (data['rootChildrenIds'] != null) {
      _rootChildrenIds = (data['rootChildrenIds'] as List).map((e) => e.toString()).toList();
    } else {
      // Migration: Populate rootChildrenIds if missing
      final rootCols = _collections.values.where((c) => c.parentId == null).map((c) => c.id);
      final rootVids = _videos.values.where((v) => v.parentId == null).map((v) => v.id);
      _rootChildrenIds = [...rootCols, ...rootVids];
      
      // Sort by createTime/lastUpdated as a default
      _rootChildrenIds.sort((a, b) {
         int timeA = _collections.containsKey(a) ? _collections[a]!.createTime : (_videos[a]?.lastUpdated ?? 0);
         int timeB = _collections.containsKey(b) ? _collections[b]!.createTime : (_videos[b]?.lastUpdated ?? 0);
         return timeB.compareTo(timeA);
      });
    }

    // Default Folder Creation: If library is completely empty
    if (_collections.isEmpty && _videos.isEmpty) {
      await createCollection("默认收藏夹", null);
    }

    // Migration: Handle Legacy Recycle Bin
    if (data['recycleBin'] != null) {
      final binList = (data['recycleBin'] as List).map((e) => VideoCollection.fromJson(e)).toList();
      for (var c in binList) {
        c.isRecycled = true;
        c.recycleTime = DateTime.now().millisecondsSinceEpoch;
        _collections[c.id] = c;
      }
    }

    // Migration: Fix parentId for children
    for (var col in _collections.values) {
      for (var childId in col.childrenIds) {
        if (_collections.containsKey(childId)) {
          _collections[childId]!.parentId = col.id;
        } else if (_videos.containsKey(childId)) {
          _videos[childId]!.parentId = col.id;
        }
      }
    }
  }

  // Debounce saving
  bool _isSaving = false;
  bool _hasPendingSave = false;

  Future<void> _saveLibrary() async {
    if (_isSaving) {
      _hasPendingSave = true;
      return;
    }

    _isSaving = true;
    _hasPendingSave = false;

    try {
      final file = File(p.join(_appDocDir.path, 'library.json'));
      final tempFile = File(p.join(_appDocDir.path, 'library.json.tmp'));
      final backupFile = File(p.join(_appDocDir.path, 'library.json.bak'));

      final data = {
        'collections': _collections.values.map((e) => e.toJson()).toList(),
        'videos': _videos.values.map((e) => e.toJson()).toList(),
        'rootChildrenIds': _rootChildrenIds,
      };

      // 1. Write to temp file
      await tempFile.writeAsString(json.encode(data), flush: true);

      // 2. Create backup of current valid file
      if (await file.exists()) {
        await file.copy(backupFile.path);
      }

      // 3. Rename temp to main (Atomic operation)
      await tempFile.rename(file.path);

    } catch (e) {
      debugPrint("Error saving library: $e");
    } finally {
      _isSaving = false;
      if (_hasPendingSave) {
        // Trigger another save if requested during this save
        _saveLibrary();
      }
    }
    // Only notify if needed, but usually save is triggered by data change which already notifies
  }

  // Get contents for a specific folder (null for root)
  List<dynamic> getContents(String? parentId) {
    List<dynamic> results = [];
    
    List<String> sourceIds;
    if (parentId == null) {
      sourceIds = _rootChildrenIds;
    } else {
      final parent = _collections[parentId];
      if (parent == null) return [];
      sourceIds = parent.childrenIds;
    }

    for (var id in sourceIds) {
      if (_collections.containsKey(id)) {
        final col = _collections[id]!;
        if (!col.isRecycled) results.add(col);
      } else if (_videos.containsKey(id)) {
        final vid = _videos[id]!;
        if (!vid.isRecycled) results.add(vid);
      }
    }
    
    return results;
  }

  Future<VideoCollection> createCollection(String name, String? parentId, {String? thumbnailPath}) async {
    final collection = VideoCollection(
      id: const Uuid().v4(),
      name: name,
      createTime: DateTime.now().millisecondsSinceEpoch,
      parentId: parentId,
      thumbnailPath: thumbnailPath,
    );
    
    _collections[collection.id] = collection;
    
    if (parentId != null && _collections.containsKey(parentId)) {
      _collections[parentId]!.childrenIds.add(collection.id);
    } else if (parentId == null) {
      _rootChildrenIds.add(collection.id);
    }
    
    await _saveLibrary();
    notifyListeners();
    return collection;
  }

  Future<void> updateCollectionThumbnail(String collectionId, String? thumbnailPath) async {
    final col = _collections[collectionId];
    if (col == null) return;

    final previousPath = col.thumbnailPath;
    if (previousPath != null &&
        previousPath.isNotEmpty &&
        thumbnailPath != previousPath &&
        p.isWithin(_appDocDir.path, previousPath)) {
      try {
        final file = File(previousPath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        developer.log('Error deleting previous collection thumbnail', error: e);
      }
    }

    col.thumbnailPath = thumbnailPath;
    ThumbnailCacheService().evictFromCache(collectionId);
    await _saveLibrary();
    notifyListeners();
  }

  // Batch import videos
  // filePaths: 视频文件的内部存储路径列表
  // parentId: 目标文件夹ID
  // shouldCopy: 是否复制文件到内部存储（仅用于外部文件）
  // useOriginalPath: 是否直接使用原始文件路径而不复制到应用内部存储
  // originalTitles: 可选参数，原始文件名列表，用于设置视频标题
  Future<void> importVideosBackground(
    List<String> filePaths,
    String? parentId, {
    bool shouldCopy = false,
    bool allowCacheRescue = true,
    bool allowDuplicatePath = false,
    bool useOriginalPath = false,
    List<String>? originalTitles,
  }) async {
    // Give UI a chance to render the "Started importing" snackbar
    await Future.delayed(const Duration(milliseconds: 200));

    int total = filePaths.length;
    if (total == 0) return;
    
    // Validate parent
    if (parentId != null && !_collections.containsKey(parentId)) {
       return; // Parent not found
    }

    try {
      isImporting.value = true;
      importProgress.value = 0.0;
      importStatus.value = "正在检查重复文件...";
      
      List<String> newIds = [];
      DateTime lastNotifyTime = DateTime.now();
      
      importStatus.value = "正在添加文件...";

      // Prepare for cache rescue
      Directory? tempDir;
      List<Directory>? extCacheDirs;
      try {
        tempDir = await getTemporaryDirectory();
        if (Platform.isAndroid) {
          extCacheDirs = await getExternalCacheDirectories();
        }
      } catch (e) {
        debugPrint("Error getting temp/cache dirs: $e");
      }
      
      final importedDir = Directory(p.join(_appDocDir.path, 'imported_videos'));
      if (!await importedDir.exists()) {
        await importedDir.create(recursive: true);
      }

      for (int i = 0; i < filePaths.length; i++) {
        var path = filePaths[i];
        // 使用原始标题（如果提供了），否则使用路径的文件名
        final originalTitle = (originalTitles != null && i < originalTitles.length) 
            ? originalTitles[i] 
            : p.basename(path);
        
        // 0. Cache Rescue (Copy cached files to persistent storage)
        // 如果 useOriginalPath 为 true，则跳过缓存救援和文件复制，直接使用原始路径
        if (!useOriginalPath) {
          bool isCached = false;
          if (allowCacheRescue) {
            if (tempDir != null && p.isWithin(tempDir.path, path)) {
              isCached = true;
            } else if (extCacheDirs != null) {
              for (var dir in extCacheDirs) {
                if (p.isWithin(dir.path, path)) {
                  isCached = true;
                  break;
                }
              }
            }
          }

          if ((allowCacheRescue && isCached) || shouldCopy) {
             try {
               final originalFile = File(path);
               if (await originalFile.exists()) {
                 final fileName = p.basename(path);
                 // Use timestamp to prevent name collision
                 final newPath = p.join(importedDir.path, "${DateTime.now().millisecondsSinceEpoch}_$fileName");
                 
                 await originalFile.copy(newPath);
                 path = newPath; // Use the new permanent path
                 debugPrint("Copied video to: $path (Cached: $isCached, Forced: $shouldCopy)");
               }
             } catch (e) {
               debugPrint("Error copying file: $e");
               // If copy fails but we must copy, we might want to skip or try continuing with original?
               // For now, continue with original path if copy fails, though it might be broken later.
             }
          }
        } else {
          debugPrint("Using original path (no copy): $path");
        }

        if (!allowDuplicatePath) {
          // 1. Duplicate Check
          // Check if it's already in _videos (by path)
          String? existingId;
          for (var v in _videos.values) {
            if (v.path == path) {
              existingId = v.id;
              break;
            }
          }

          if (existingId != null) {
            final existingVideo = _videos[existingId]!;
            if (existingVideo.isRecycled) {
               // Restore from recycle bin
               existingVideo.isRecycled = false;
               existingVideo.recycleTime = null;
               
               // Move to current target folder
               // 1. Remove from old parent (if any) - implicitly done by not adding to old parent's list? 
               // No, we need to ensure it's in the NEW parent's list and NOT in the old one if we want to "move" it.
               // But simpler: just restore it to where it was? 
               // User expects "Import" to put it in CURRENT folder.
               
               // Remove from old parent's children list if different
               if (existingVideo.parentId != null && _collections.containsKey(existingVideo.parentId)) {
                 _collections[existingVideo.parentId]!.childrenIds.remove(existingId);
               } else if (existingVideo.parentId == null) {
                 _rootChildrenIds.remove(existingId);
               }

               // Set new parent
               existingVideo.parentId = parentId;

               // Add to new parent's children list
               if (parentId != null && _collections.containsKey(parentId)) {
                 if (!_collections[parentId]!.childrenIds.contains(existingId)) {
                   _collections[parentId]!.childrenIds.add(existingId);
                 }
               } else {
                 if (!_rootChildrenIds.contains(existingId)) {
                   _rootChildrenIds.add(existingId);
                 }
               }
               
               notifyListeners();
            }
            continue;
          }
        }
        
        final id = Uuid().v4();
        final item = VideoItem(
          id: id,
          path: path,
          title: originalTitle,
          thumbnailPath: null,
          durationMs: 0,
          lastUpdated: DateTime.now().millisecondsSinceEpoch,
          parentId: parentId,
          type: _detectMediaType(path),
        );
        
        _videos[id] = item;
        
        if (parentId != null) {
          _collections[parentId]!.childrenIds.add(id);
        } else {
          _rootChildrenIds.add(id);
        }
        
        newIds.add(id);
        
        // Debounce notify
        if (DateTime.now().difference(lastNotifyTime).inMilliseconds > 300) {
           notifyListeners();
           lastNotifyTime = DateTime.now();
        }
      }
      
      if (newIds.isEmpty) {
        importStatus.value = "没有新文件需要导入";
        await Future.delayed(const Duration(seconds: 1));
        return;
      }

      await _saveLibrary();
      notifyListeners();

      // Phase 2: Parallel Thumbnail Generation
      importStatus.value = "正在生成缩略图...";
      int current = 0;
      total = newIds.length; // Update total to actual new items
      
      // Process in batches to control concurrency
      const int batchSize = 4;
      for (int i = 0; i < newIds.length; i += batchSize) {
        if (!isImporting.value) break;

        final end = (i + batchSize < newIds.length) ? i + batchSize : newIds.length;
        final batch = newIds.sublist(i, end);

        await Future.wait(batch.map((id) async {
          if (!isImporting.value) return;
          try {
            final item = _videos[id];
            if (item == null) return;

            final thumbPath = await _generateThumbnail(item.path);
            item.thumbnailPath = thumbPath;
          } catch (e) {
            debugPrint("Error processing metadata for $id: $e");
          }
        }));

        current += batch.length;
        final progress = current / total;
        importProgress.value = progress;
        importStatus.value = "处理中: ${(progress * 100).toInt()}%";

        if (DateTime.now().difference(lastNotifyTime).inMilliseconds > 300) {
           notifyListeners();
           lastNotifyTime = DateTime.now();
        }
      }
      
      await _saveLibrary();
      notifyListeners();
    } catch (e) {
      debugPrint("Import error: $e");
      importStatus.value = "导入出错: $e";
    } finally {
      // Reset
      isImporting.value = false;
      importProgress.value = 0.0;
      importStatus.value = "";
    }
  }

  // Unified Recycle Bin Methods
  Future<void> moveToRecycleBin(List<String> ids) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    
    for (var id in ids) {
      String? parentId;
      if (_collections.containsKey(id)) {
        final col = _collections[id]!;
        col.isRecycled = true;
        col.recycleTime = now;
        parentId = col.parentId;
      } else if (_videos.containsKey(id)) {
        final vid = _videos[id]!;
        final selectedPaths = <String>[];
        if (vid.subtitlePath != null) selectedPaths.add(vid.subtitlePath!);
        if (vid.secondarySubtitlePath != null) selectedPaths.add(vid.secondarySubtitlePath!);
        vid.recycledSelectedSubtitlePaths = selectedPaths.isEmpty ? null : selectedPaths;
        final snapshotPaths = await _collectAssociatedSubtitlePaths(vid);
        if (snapshotPaths.isNotEmpty) {
          vid.recycledAdditionalSubtitles = {
            for (final path in snapshotPaths) p.basename(path): path,
          };
        } else {
          vid.recycledAdditionalSubtitles = null;
        }
        vid.isRecycled = true;
        vid.recycleTime = now;
        parentId = vid.parentId;
      }

      // Remove from parent's children list so counts update immediately
      if (parentId != null && _collections.containsKey(parentId)) {
        _collections[parentId]!.childrenIds.remove(id);
      } else if (parentId == null) {
        _rootChildrenIds.remove(id);
      }
    }
    await _saveLibrary();
    notifyListeners();
  }

  Future<void> restoreFromRecycleBin(List<String> ids) async {
    for (var id in ids) {
      String? parentId;
      bool isItemCollection = false;

      if (_collections.containsKey(id)) {
        final col = _collections[id]!;
        col.isRecycled = false;
        col.recycleTime = null;
        parentId = col.parentId;
        isItemCollection = true;
      } else if (_videos.containsKey(id)) {
        final vid = _videos[id]!;
        vid.isRecycled = false;
        vid.recycleTime = null;
        if (vid.recycledSelectedSubtitlePaths != null) {
          final paths = vid.recycledSelectedSubtitlePaths!;
          vid.subtitlePath = paths.isNotEmpty ? paths[0] : null;
          vid.secondarySubtitlePath = paths.length > 1 ? paths[1] : null;
          vid.recycledSelectedSubtitlePaths = null;
        }
        if (vid.recycledAdditionalSubtitles != null && vid.recycledAdditionalSubtitles!.isNotEmpty) {
          vid.additionalSubtitles = Map<String, String>.from(vid.recycledAdditionalSubtitles!);
          vid.recycledAdditionalSubtitles = null;
        }
        parentId = vid.parentId;
      } else {
        continue;
      }

      // Check if parent is valid (exists and is NOT recycled)
      // If parent is missing or recycled, move to root to ensure visibility
      bool parentIsValid = false;
      if (parentId != null && _collections.containsKey(parentId)) {
        if (!_collections[parentId]!.isRecycled) {
          parentIsValid = true;
        }
      } else if (parentId == null) {
        parentIsValid = true; // Already at root
      }

      if (!parentIsValid) {
        // Move to root
        // 1. Update item's parentId
        if (isItemCollection) {
          _collections[id]!.parentId = null;
        } else {
          _videos[id]!.parentId = null;
        }

        // 2. Add to rootChildrenIds
        if (!_rootChildrenIds.contains(id)) {
          _rootChildrenIds.add(id);
        }
      } else {
        // Parent is valid, add back to parent's childrenIds
        if (parentId != null) {
           if (!_collections[parentId]!.childrenIds.contains(id)) {
             _collections[parentId]!.childrenIds.add(id);
           }
        } else {
           if (!_rootChildrenIds.contains(id)) {
             _rootChildrenIds.add(id);
           }
        }
      }
    }
    await _saveLibrary();
    notifyListeners();
  }
  
  Future<void> deleteFromRecycleBin(List<String> ids) async {
    for (var id in ids) {
      if (_collections.containsKey(id)) {
        await _deleteCollectionFilesRecursive(id);
        _deleteCollectionRecursive(id);
      } else if (_videos.containsKey(id)) {
        final vid = _videos[id];
        if (vid != null) await _deleteVideoFiles(vid);
        _deleteVideo(id);
      }
    }
    await _saveLibrary();
    notifyListeners();
  }

  Future<void> _deleteCollectionFilesRecursive(String id) async {
    final col = _collections[id];
    if (col == null) return;

    ThumbnailCacheService().evictFromCache(id);
    if (col.thumbnailPath != null &&
        col.thumbnailPath!.isNotEmpty &&
        p.isWithin(_appDocDir.path, col.thumbnailPath!)) {
      try {
        final file = File(col.thumbnailPath!);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        developer.log('Error deleting collection thumbnail', error: e);
      }
    }
    
    for (var childId in col.childrenIds) {
      if (_collections.containsKey(childId)) {
        await _deleteCollectionFilesRecursive(childId);
      } else if (_videos.containsKey(childId)) {
        final vid = _videos[childId];
        if (vid != null) await _deleteVideoFiles(vid);
      }
    }
  }

  Future<void> _deleteVideoFiles(VideoItem vid) async {
    // 清理缩略图缓存
    ThumbnailCacheService().evictFromCache(vid.id);
    
    // 1. Delete Thumbnail
    if (vid.thumbnailPath != null) {
      try {
        final file = File(vid.thumbnailPath!);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        developer.log('Error deleting thumbnail', error: e);
      }
    }
    
    // 2. Delete Cached Subtitles
    if (vid.isSubtitleCached && vid.subtitlePath != null) {
       try {
         final file = File(vid.subtitlePath!);
         if (await file.exists()) {
           await file.delete();
         }
       } catch (e) {
         developer.log('Error deleting subtitle', error: e);
       }
    }
    if (vid.isSecondarySubtitleCached && vid.secondarySubtitlePath != null) {
       try {
         final file = File(vid.secondarySubtitlePath!);
         if (await file.exists()) {
           await file.delete();
         }
       } catch (e) {
         developer.log('Error deleting secondary subtitle', error: e);
       }
    }

    // 3. Delete Video File (Only if it's inside app storage)
    // This handles the "cache" user mentioned if the video was copied internally.
    try {
      bool shouldDelete = false;

      // Check 1: Internal Doc Dir (App Data)
      if (p.isWithin(_appDocDir.path, vid.path)) {
        shouldDelete = true;
      }
      
      // Check 2: Internal Temp Dir (Cache)
      if (!shouldDelete) {
        final tempDir = await getTemporaryDirectory();
        if (p.isWithin(tempDir.path, vid.path)) shouldDelete = true;
      }
      
      // Check 3: Android External Storage (Android/data/pkg/files & cache)
      if (!shouldDelete && Platform.isAndroid) {
         // External Files
         final extDir = await getExternalStorageDirectory();
         if (extDir != null && p.isWithin(extDir.path, vid.path)) shouldDelete = true;

         // External Caches
         if (!shouldDelete) {
            final extCacheDirs = await getExternalCacheDirectories();
            if (extCacheDirs != null) {
                for (var dir in extCacheDirs) {
                    if (p.isWithin(dir.path, vid.path)) {
                        shouldDelete = true;
                        break;
                    }
                }
            }
         }

         // Check 4: Bilibili Download Directory (User Request)
         // Allow deleting files in Bilibili download directory (e.g., merged files we created)
         if (!shouldDelete && vid.path.contains("tv.danmaku.bili")) {
           shouldDelete = true;
         }
      }

      if (shouldDelete) {
        final file = File(vid.path);
        if (await file.exists()) {
          await file.delete();
          debugPrint("Deleted internal video file: ${vid.path}");
        }
      }
    } catch (e) {
      debugPrint("Error deleting internal video: $e");
    }
  }

  void _deleteCollectionRecursive(String id) {
    final col = _collections[id];
    if (col == null) return;
    
    // Delete children
    for (var childId in List<String>.from(col.childrenIds)) {
      if (_collections.containsKey(childId)) {
        _deleteCollectionRecursive(childId);
      } else {
        _deleteVideo(childId);
      }
    }
    
    // Remove from parent
    if (col.parentId != null && _collections.containsKey(col.parentId)) {
      _collections[col.parentId]!.childrenIds.remove(id);
    } else if (col.parentId == null) {
      _rootChildrenIds.remove(id);
    }
    
    _collections.remove(id);
  }

  void _deleteVideo(String id) {
    final vid = _videos[id];
    if (vid == null) return;
    
    if (vid.parentId != null && _collections.containsKey(vid.parentId)) {
      _collections[vid.parentId]!.childrenIds.remove(id);
    } else if (vid.parentId == null) {
      _rootChildrenIds.remove(id);
    }
    _videos.remove(id);
  }

  // Move item to another collection (or root if targetCollectionId is null)
  Future<void> moveItemToCollection(String itemId, String? targetCollectionId) async {
    if (itemId == targetCollectionId) return;

    // 1. Identify Item
    VideoCollection? col;
    VideoItem? vid;
    String? currentParentId;

    if (_collections.containsKey(itemId)) {
      col = _collections[itemId];
      currentParentId = col!.parentId;
      
      // Cycle Check: Cannot move a folder into itself or its descendants
      if (targetCollectionId != null && _isDescendant(targetCollectionId, itemId)) {
        return; // Invalid move
      }
    } else if (_videos.containsKey(itemId)) {
      vid = _videos[itemId];
      currentParentId = vid!.parentId;
    } else {
      return; // Item not found
    }

    // Check if already in target
    if (currentParentId == targetCollectionId) return;

    // 2. Remove from old location
    if (currentParentId != null && _collections.containsKey(currentParentId)) {
      _collections[currentParentId]!.childrenIds.remove(itemId);
    } else if (currentParentId == null) {
      _rootChildrenIds.remove(itemId);
    }

    // 3. Add to new location
    if (targetCollectionId != null && _collections.containsKey(targetCollectionId)) {
      final target = _collections[targetCollectionId]!;
      if (!target.childrenIds.contains(itemId)) {
        target.childrenIds.add(itemId);
      }
      // Update item parent pointer
      if (col != null) col.parentId = targetCollectionId;
      if (vid != null) vid.parentId = targetCollectionId;
    } else if (targetCollectionId == null) {
      // Move to Root
      if (!_rootChildrenIds.contains(itemId)) {
        _rootChildrenIds.add(itemId);
      }
      // Update item parent pointer
      if (col != null) col.parentId = null;
      if (vid != null) vid.parentId = null;
    }

    await _saveLibrary();
    notifyListeners();
  }

  // Batch Move
  Future<void> moveItemsToCollection(List<String> itemIds, String? targetCollectionId) async {
    bool changed = false;
    for (var itemId in itemIds) {
      if (itemId == targetCollectionId) continue;

      // 1. Identify Item
      VideoCollection? col;
      VideoItem? vid;
      String? currentParentId;

      if (_collections.containsKey(itemId)) {
        col = _collections[itemId];
        currentParentId = col!.parentId;
        // Cycle Check
        if (targetCollectionId != null && _isDescendant(targetCollectionId, itemId)) {
          continue; 
        }
      } else if (_videos.containsKey(itemId)) {
        vid = _videos[itemId];
        currentParentId = vid!.parentId;
      } else {
        continue; 
      }

      if (currentParentId == targetCollectionId) continue;

      // 2. Remove
      if (currentParentId != null && _collections.containsKey(currentParentId)) {
        _collections[currentParentId]!.childrenIds.remove(itemId);
      } else if (currentParentId == null) {
        _rootChildrenIds.remove(itemId);
      }

      // 3. Add
      if (targetCollectionId != null && _collections.containsKey(targetCollectionId)) {
        final target = _collections[targetCollectionId]!;
        if (!target.childrenIds.contains(itemId)) {
          target.childrenIds.add(itemId);
        }
        if (col != null) col.parentId = targetCollectionId;
        if (vid != null) vid.parentId = targetCollectionId;
      } else if (targetCollectionId == null) {
        if (!_rootChildrenIds.contains(itemId)) {
          _rootChildrenIds.add(itemId);
        }
        if (col != null) col.parentId = null;
        if (vid != null) vid.parentId = null;
      }
      changed = true;
    }

    if (changed) {
      await _saveLibrary();
      notifyListeners();
    }
  }

  bool _isDescendant(String potentialDescendantId, String ancestorId) {
    if (potentialDescendantId == ancestorId) return true;
    
    final col = _collections[potentialDescendantId];
    if (col == null) return false; // Should not happen if ID is valid collection
    if (col.parentId == null) return false;
    
    return _isDescendant(col.parentId!, ancestorId);
  }

  // Reorder (Only for manual ordering within a parent)
  Future<void> reorderItems(String? parentId, int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;

    // Logic: 
    // 1. Get visible items using getContents(parentId) logic.
    // 2. Identify the item being moved (itemToMove).
    // 3. Identify the target insert position.
    
    // Step 1: Visible Items
    final visibleItems = getContents(parentId);
    if (oldIndex >= visibleItems.length || newIndex >= visibleItems.length) return;
    
    final itemToMove = visibleItems[oldIndex];
    final String itemToMoveId = (itemToMove as dynamic).id;
    
    // Step 2: Determine Insert Before ID
    // If moving down (old < new), we usually want to place AFTER the target.
    // If moving up (old > new), we usually want to place BEFORE the target.
    
    int targetLookupIndex;
    if (oldIndex < newIndex) {
      targetLookupIndex = newIndex + 1;
    } else {
      targetLookupIndex = newIndex;
    }

    String? insertBeforeId; // If null, insert at end
    if (targetLookupIndex < visibleItems.length) {
      final itemAfter = visibleItems[targetLookupIndex];
      insertBeforeId = (itemAfter as dynamic).id;
    }
    
    // Master List Reference
    List<String> masterList;
    if (parentId == null) {
      masterList = _rootChildrenIds;
    } else {
      final parent = _collections[parentId];
      if (parent == null) return;
      masterList = parent.childrenIds;
    }
    
    // Step 3: Remove
    final originalIndex = masterList.indexOf(itemToMoveId);
    if (originalIndex == -1) return; 
    masterList.removeAt(originalIndex);
    
    // Step 4: Insert
    if (insertBeforeId == null) {
      masterList.add(itemToMoveId);
    } else {
      int targetIndex = masterList.indexOf(insertBeforeId);
      if (targetIndex == -1) {
        masterList.add(itemToMoveId);
      } else {
        masterList.insert(targetIndex, itemToMoveId);
      }
    }
    
    await _saveLibrary();
    notifyListeners();
  }

  // Batch Reorder
  // draggedItemIndex: the index of the item the user is actively dragging
  // targetIndex: the index of the drop target
  Future<void> reorderMultipleItems(String? parentId, List<String> itemIds, int draggedItemIndex, int targetIndex) async {
    if (itemIds.isEmpty) return;
    
    // 1. Get Visible Items
    final visibleItems = getContents(parentId);
    
    // 2. Identify Target Insert Position
    // We use the same logic as single reorder: 
    // If dragging down (draggedItemIndex < targetIndex), insert AFTER target.
    // If dragging up (draggedItemIndex > targetIndex), insert BEFORE target.
    
    int targetLookupIndex;
    if (draggedItemIndex < targetIndex) {
      targetLookupIndex = targetIndex + 1;
    } else {
      targetLookupIndex = targetIndex;
    }
    
    String? insertBeforeId; 
    if (targetLookupIndex < visibleItems.length) {
       final itemAfter = visibleItems[targetLookupIndex];
       insertBeforeId = (itemAfter as dynamic).id;
    }
    
    // Master List Reference
    List<String> masterList;
    if (parentId == null) {
      masterList = _rootChildrenIds;
    } else {
      final parent = _collections[parentId];
      if (parent == null) return;
      masterList = parent.childrenIds;
    }
    
    // 3. Remove ALL items to be moved
    // We must do this carefully. If we remove items, the indices change.
    // But we are using `insertBeforeId` which is stable (unless it's one of the moving items).
    // If `insertBeforeId` is one of the moving items, our target logic is flawed.
    // However, in a valid drag, you don't drag a selection onto itself.
    // But targetLookupIndex logic might pick a moving item if it's adjacent.
    
    // Optimization: If we are dragging a block [A, B] and dropping on C.
    // We want to insert [A, B] relative to C.
    // C should not be in itemIds.
    
    // Filter out itemIds from masterList
    masterList.removeWhere((id) => itemIds.contains(id));
    
    // 4. Insert
    if (insertBeforeId == null) {
      masterList.addAll(itemIds);
    } else {
      // Find where to insert
      // Note: insertBeforeId might have been removed if it was in itemIds? 
      // No, because we can't drag onto a selected item (usually). 
      // But if we selected A and B, and dragged A onto B... well, that's a no-op.
      
      int insertIndex = masterList.indexOf(insertBeforeId);
      if (insertIndex == -1) {
        // Fallback: append
        masterList.addAll(itemIds);
      } else {
        masterList.insertAll(insertIndex, itemIds);
      }
    }
    
    await _saveLibrary();
    notifyListeners();
  }

  Future<String?> _generateThumbnail(String videoPath) async {
    // Skip thumbnail generation for audio files
    if (_detectMediaType(videoPath) == MediaType.audio) {
      return null;
    }
    
    // Windows Specific Implementation
    if (Platform.isWindows) {
      return await _generateThumbnailWindows(videoPath);
    }
    
    // iOS: Use FFmpeg for better compatibility with gallery videos
    if (Platform.isIOS) {
      return await _generateThumbnailFFmpeg(videoPath);
    }
    
    // Android and other platforms: Use video_thumbnail plugin
    try {
      final thumbDir = Directory(p.join(_appDocDir.path, 'thumbnails'));
      if (!await thumbDir.exists()) {
        await thumbDir.create(recursive: true);
      }
      
      final fileName = await VideoThumbnail.thumbnailFile(
        video: videoPath,
        thumbnailPath: thumbDir.path,
        imageFormat: ImageFormat.JPEG,
        maxHeight: 200, // Optimize size
        quality: 75,
      );
      return fileName;
    } catch (e) {
      developer.log('Thumbnail error', error: e);
      return null;
    }
  }

  /// 使用 FFmpeg 生成缩略图（用于 iOS 和其他平台）
  Future<String?> _generateThumbnailFFmpeg(String videoPath) async {
    try {
      final thumbDir = Directory(p.join(_appDocDir.path, 'thumbnails'));
      if (!await thumbDir.exists()) {
        await thumbDir.create(recursive: true);
      }
      
      // Generate deterministic filename based on video path
      final hash = md5.convert(utf8.encode(videoPath)).toString();
      final outPath = p.join(thumbDir.path, "$hash.jpg");
      
      // Check if thumbnail already exists
      final outFile = File(outPath);
      if (await outFile.exists() && await outFile.length() > 0) {
        return outPath;
      }
      
      // Use FFmpeg to extract first frame
      // -y: Overwrite output file
      // -i: Input file
      // -ss 00:00:01: Seek to 1 second (avoid black frames at start)
      // -vframes 1: Extract only 1 frame
      // -vf scale=-1:200: Resize to height 200px maintaining aspect ratio
      // -q:v 2: High quality JPEG
      final session = await FFmpegKit.execute(
        '-y -i "$videoPath" -ss 00:00:01 -vframes 1 -vf scale=-1:200 -q:v 2 "$outPath"'
      );
      
      final returnCode = await session.getReturnCode();
      
      if (ReturnCode.isSuccess(returnCode)) {
        if (await outFile.exists() && await outFile.length() > 0) {
          developer.log('FFmpeg thumbnail generated: $outPath');
          return outPath;
        }
      }
      
      // If failed, try without seek (some videos might be very short)
      final session2 = await FFmpegKit.execute(
        '-y -i "$videoPath" -vframes 1 -vf scale=-1:200 -q:v 2 "$outPath"'
      );
      
      final returnCode2 = await session2.getReturnCode();
      
      if (ReturnCode.isSuccess(returnCode2)) {
        if (await outFile.exists() && await outFile.length() > 0) {
          developer.log('FFmpeg thumbnail generated (fallback): $outPath');
          return outPath;
        }
      }
      
      developer.log('FFmpeg thumbnail generation failed for: $videoPath');
      return null;
    } catch (e) {
      developer.log('FFmpeg thumbnail error', error: e);
      return null;
    }
  }

  Future<String?> _generateThumbnailWindows(String videoPath) async {
     try {
       // Locate FFmpeg
       final exeDir = p.dirname(Platform.resolvedExecutable);
       final ffmpegPath = p.join(exeDir, 'ffmpeg.exe');
       
       if (!await File(ffmpegPath).exists()) {
         developer.log("FFmpeg not found at $ffmpegPath");
         return null;
       }
       
       final thumbDir = Directory(p.join(_appDocDir.path, 'thumbnails'));
       if (!await thumbDir.exists()) await thumbDir.create(recursive: true);
       
       // Generate deterministic filename based on video path
       final hash = md5.convert(utf8.encode(videoPath)).toString();
       final outPath = p.join(thumbDir.path, "$hash.jpg");
       
       // 1. Try to extract embedded cover art
       // -map 0:v selects all video streams
       // -map -0:V excludes "real" video streams (leaving attached pictures)
       try {
         await Process.run(ffmpegPath, [
           '-y', 
           '-i', videoPath, 
           '-map', '0:v', 
           '-map', '-0:V', 
           '-c', 'copy', 
           outPath
         ]).timeout(const Duration(seconds: 5)); // Add timeout to prevent hanging
         
         if (await File(outPath).exists() && await File(outPath).length() > 0) {
           return outPath;
         }
       } catch (e) {
         // Continue to fallback
       }
       
       // 2. Fallback: Extract first frame
       await Process.run(ffmpegPath, [
         '-y', 
         '-i', videoPath, 
         '-ss', '0', 
         '-vframes', '1', 
         '-vf', 'scale=-1:200', // Resize to height 200px to optimize speed and size
         '-q:v', '2', // High quality JPEG
         outPath
       ]).timeout(const Duration(seconds: 15));
       
       if (await File(outPath).exists() && await File(outPath).length() > 0) {
         return outPath;
       }
     } catch (e) {
       developer.log('Windows Thumbnail error', error: e);
     }
     return null;
  }

  Future<void> updateVideoProgress(String id, int positionMs) async {
    final item = _videos[id];
    if (item != null) {
      item.lastPositionMs = positionMs;
      item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
      await _saveLibrary();
      notifyListeners();
    }
  }

  Future<void> updateVideoDuration(String id, int durationMs) async {
    final item = _videos[id];
    if (item != null && item.durationMs != durationMs) {
      item.durationMs = durationMs;
      await _saveLibrary();
      notifyListeners();
    }
  }
  
  Future<void> saveProgress() async {
    await _saveLibrary();
  }

  Future<void> updateVideoSubtitles(String videoId, String? subtitlePath, bool isCached, {String? secondarySubtitlePath, bool isSecondaryCached = false}) async {
    final item = _videos[videoId];
    if (item != null) {
      final subDir = Directory(p.join(_appDocDir.path, 'subtitles'));
      if ((isCached || isSecondaryCached) && !await subDir.exists()) {
        await subDir.create(recursive: true);
      }

      // 1. Process Primary Subtitle
      if (subtitlePath != null) {
        String finalPath = subtitlePath;
        if (isCached) {
          final ext = p.extension(subtitlePath);
          // Use _main suffix to avoid collision with secondary if same extension
          final newFileName = "${videoId}_main$ext"; 
          final newPath = p.join(subDir.path, newFileName);
          
          if (subtitlePath != newPath) {
            try {
               await File(subtitlePath).copy(newPath);
               finalPath = newPath;
            } catch (e) {
              developer.log('Error copying primary subtitle', error: e);
            }
          }
        }
        item.subtitlePath = finalPath;
        item.isSubtitleCached = isCached;
      } else {
        // If null passed (cleared), clear it
        item.subtitlePath = null;
        item.isSubtitleCached = false;
      }

      // 2. Process Secondary Subtitle
      if (secondarySubtitlePath != null) {
        String finalSecPath = secondarySubtitlePath;
        if (isSecondaryCached) {
          final ext = p.extension(secondarySubtitlePath);
          final newFileName = "${videoId}_sec$ext"; 
          final newPath = p.join(subDir.path, newFileName);
          
          if (secondarySubtitlePath != newPath) {
            try {
               await File(secondarySubtitlePath).copy(newPath);
               finalSecPath = newPath;
            } catch (e) {
              developer.log('Error copying secondary subtitle', error: e);
            }
          }
        }
        item.secondarySubtitlePath = finalSecPath;
        item.isSecondarySubtitleCached = isSecondaryCached;
      } else {
        // If null passed (cleared), clear it
        item.secondarySubtitlePath = null;
        item.isSecondarySubtitleCached = false;
      }

      if (item.isRecycled) {
        final paths = <String>[];
        if (item.subtitlePath != null) paths.add(item.subtitlePath!);
        if (item.secondarySubtitlePath != null) paths.add(item.secondarySubtitlePath!);
        item.recycledSelectedSubtitlePaths = paths;
      }

      await _saveLibrary();
    }
  }

  Future<void> updateVideoSubtitleVisibility(String videoId, bool showFloatingSubtitles) async {
    final item = _videos[videoId];
    if (item != null) {
      item.showFloatingSubtitles = showFloatingSubtitles;
      item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
      await _saveLibrary();
      notifyListeners();
    }
  }

  // --- Single Item Management (Exposed for Batch Import) ---

  Future<String?> addSingleVideo(VideoItem item, {bool useOriginalPath = false}) async {
    // 1. Duplicate Check - Check if a video with the same path already exists
    String? existingId;
    for (var v in _videos.values) {
      if (v.path == item.path) {
        existingId = v.id;
        break;
      }
    }

    if (existingId != null) {
      final existingVideo = _videos[existingId]!;
      if (existingVideo.isRecycled) {
        // Restore from recycle bin
        existingVideo.isRecycled = false;
        existingVideo.recycleTime = null;
        
        // Remove from old parent's children list if different
        if (existingVideo.parentId != null && _collections.containsKey(existingVideo.parentId)) {
          _collections[existingVideo.parentId]!.childrenIds.remove(existingId);
        } else if (existingVideo.parentId == null) {
          _rootChildrenIds.remove(existingId);
        }

        // Set new parent
        existingVideo.parentId = item.parentId;

        // Add to new parent's children list
        if (item.parentId != null && _collections.containsKey(item.parentId)) {
          if (!_collections[item.parentId]!.childrenIds.contains(existingId)) {
            _collections[item.parentId]!.childrenIds.add(existingId);
          }
        } else {
          if (!_rootChildrenIds.contains(existingId)) {
            _rootChildrenIds.add(existingId);
          }
        }
        
        await _saveLibrary();
        notifyListeners();
        return existingId;
      } else {
        // Video already exists and is not recycled, skip adding
        debugPrint("Video with path ${item.path} already exists, skipping import");
        return existingId;
      }
    }

    // 2. Handle file persistence for temp/cache files
    // 如果 useOriginalPath 为 true，则跳过文件持久化处理，直接使用原始路径
    if (!useOriginalPath) {
      await _ensureFilePersistence(item);
    } else {
      debugPrint("Using original path for single video (no copy): ${item.path}");
    }

    // 3. For audio files, ensure thumbnailPath is null
    if (item.type == MediaType.audio) {
      item.thumbnailPath = null;
    }

    _videos[item.id] = item;
    
    if (item.parentId != null && _collections.containsKey(item.parentId)) {
      _collections[item.parentId]!.childrenIds.add(item.id);
    } else {
      // Safe-guard: if parent missing or null, add to root
      if (item.parentId != null) {
         item.parentId = null;
      }
      _rootChildrenIds.add(item.id);
    }
    
    await _saveLibrary();
    notifyListeners();

    // Generate thumbnail asynchronously (only for video files)
    if (item.type == MediaType.video && item.thumbnailPath == null) {
       _generateThumbnail(item.path).then((thumb) {
         if (thumb != null) {
           item.thumbnailPath = thumb;
           _saveLibrary(); // Save again with thumbnail
           notifyListeners();
         }
       });
    }
    
    return item.id;
  }

  /// Ensures that video and subtitle files are moved to permanent storage 
  /// if they are currently in a temporary or cache directory.
  Future<void> _ensureFilePersistence(VideoItem item) async {
    try {
      final importedDir = Directory(p.join(_appDocDir.path, 'imported_videos'));
      
      // Handle Video File
      item.path = await _moveIfTemporary(item.path, importedDir);
      
      // Handle Subtitle File
      if (item.subtitlePath != null) {
        item.subtitlePath = await _moveIfTemporary(item.subtitlePath!, importedDir);
      }

      // Handle Secondary Subtitle
      if (item.secondarySubtitlePath != null) {
        item.secondarySubtitlePath = await _moveIfTemporary(item.secondarySubtitlePath!, importedDir);
      }
    } catch (e) {
      debugPrint("Error ensuring file persistence: $e");
    }
  }

  Future<String> _moveIfTemporary(String currentPath, Directory targetDir) async {
    try {
      final file = File(currentPath);
      if (!await file.exists()) return currentPath;

      bool isTemporary = false;
      
      // Check 1: System Temp Dir
      final tempDir = await getTemporaryDirectory();
      if (p.isWithin(tempDir.path, currentPath)) {
        isTemporary = true;
      }
      
      // Check 2: Android Caches
      if (!isTemporary && Platform.isAndroid) {
        final extCacheDirs = await getExternalCacheDirectories();
        if (extCacheDirs != null) {
          for (var dir in extCacheDirs) {
            if (p.isWithin(dir.path, currentPath)) {
              isTemporary = true;
              break;
            }
          }
        }
      }

      // Check 3: App Data Dir (Internal but not library root)
      // Files in app data that are NOT in our 'imported_videos' or 'videos' root
      // are often "batch import cache" files (like unzipped files).
      if (!isTemporary && p.isWithin(_appDocDir.path, currentPath)) {
        final importedDir = Directory(p.join(_appDocDir.path, 'imported_videos'));
        // If it's in app doc dir but NOT in our permanent folder, treat as temporary for library
        if (!p.isWithin(importedDir.path, currentPath)) {
          isTemporary = true;
        }
      }

      if (isTemporary) {
        if (!await targetDir.exists()) await targetDir.create(recursive: true);
        
        // Use a unique name to avoid collisions
        final fileName = "${DateTime.now().millisecondsSinceEpoch}_${p.basename(currentPath)}";
        final newPath = p.join(targetDir.path, fileName);
        
        await file.copy(newPath);
        
        // Delete original if it was temporary
        try {
          await file.delete();
          debugPrint("Deleted temp file after move: $currentPath");
          
          // Check for empty unzip parent dir
          final parentDir = file.parent;
          if (p.basename(parentDir.path).startsWith('unzip_')) {
             if (await parentDir.list().isEmpty) {
               await parentDir.delete();
               debugPrint("Deleted empty unzip dir: ${parentDir.path}");
             }
          }
        } catch (e) {
          debugPrint("Failed to delete temp file: $e");
        }

        return newPath;
      }
    } catch (e) {
      debugPrint("Error in _moveIfTemporary for $currentPath: $e");
    }
    return currentPath;
  }


  Future<void> removeSingleVideo(String id, {bool keepFile = false}) async {
    if (_videos.containsKey(id)) {
      final vid = _videos[id];
      if (vid != null && !keepFile) await _deleteVideoFiles(vid);
      _deleteVideo(id); // Helper handles parent removal
      await _saveLibrary();
      notifyListeners();
    }
  }

  Future<void> renameItem(String id, String newName) async {
    if (_collections.containsKey(id)) {
      _collections[id]!.name = newName;
    } else if (_videos.containsKey(id)) {
      _videos[id]!.title = newName;
    }
    await _saveLibrary();
    notifyListeners();
  }

  // --- Size Calculation Helpers ---

  Future<int> calculateItemSize(dynamic item) async {
    if (item is VideoItem) {
      return _calculateVideoItemSize(item);
    } else if (item is VideoCollection) {
      return _calculateCollectionSize(item);
    }
    return 0;
  }

  Future<int> _calculateVideoItemSize(VideoItem item) async {
    int size = 0;
    
    // Check Video File
    if (_isInternalPath(item.path)) {
      size += await _getFileSize(item.path);
    }
    final subtitlePaths = await _collectAssociatedSubtitlePaths(item);
    for (final path in subtitlePaths) {
      if (_isInternalPath(path)) {
        size += await _getFileSize(path);
      }
    }
    
    // Check Thumbnail
    if (item.thumbnailPath != null && _isInternalPath(item.thumbnailPath!)) {
      size += await _getFileSize(item.thumbnailPath!);
    }
    
    return size;
  }

  Future<Set<String>> _collectAssociatedSubtitlePaths(VideoItem item) async {
    final paths = <String>{};
    if (item.subtitlePath != null) {
      paths.add(item.subtitlePath!);
    }
    if (item.secondarySubtitlePath != null) {
      paths.add(item.secondarySubtitlePath!);
    }
    if (item.additionalSubtitles != null) {
      paths.addAll(item.additionalSubtitles!.values);
    }

    final videoName = p.basenameWithoutExtension(item.path);
    final extractedPrefix = "$videoName.stream_";
    try {
      final videoFile = File(item.path);
      final dir = videoFile.parent;
      if (await dir.exists()) {
        final files = dir.listSync().whereType<File>();
        for (final file in files) {
          final name = p.basename(file.path);
          if (!name.startsWith(videoName)) continue;
          if (name.startsWith(extractedPrefix)) continue;
          final ext = p.extension(file.path).toLowerCase();
          if (['.srt', '.vtt', '.ass', '.ssa', '.sup', '.lrc', '.sub', '.idx', '.scc'].contains(ext)) {
            paths.add(file.path);
          }
        }
      }
    } catch (_) {}

    if (_initialized) {
      try {
        final subDir = Directory(p.join(_appDocDir.path, 'subtitles'));
        if (await subDir.exists()) {
          final docFiles = subDir.listSync().whereType<File>();
          for (final file in docFiles) {
            final name = p.basename(file.path);
            if (name.startsWith(extractedPrefix) || name == "$videoName.ai.srt") {
              paths.add(file.path);
            }
          }
        }
      } catch (_) {}
    }

    return paths;
  }

  Future<int> _calculateCollectionSize(VideoCollection col) async {
    int size = 0;
    // Recursively calculate children
    final children = getContents(col.id); 
    
    // Run in parallel for speed
    final sizes = await Future.wait(children.map((child) => calculateItemSize(child)));
    for (var s in sizes) {
      size += s;
    }
    return size;
  }

  bool _isInternalPath(String path) {
    if (!_initialized) return false;
    return p.isWithin(_appDocDir.path, path);
  }

  Future<int> _getFileSize(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        return await file.length();
      }
    } catch (e) {
      // ignore
    }
    return 0;
  }

  static String formatSize(int bytes) {
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB"];
    var i = (log(bytes) / log(1024)).floor();
    return '${(bytes / pow(1024, i)).toStringAsFixed(2)} ${suffixes[i]}';
  }
}
