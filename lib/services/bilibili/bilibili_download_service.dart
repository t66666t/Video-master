import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_state_manager.dart';
import 'package:video_player_app/services/bilibili/download_manager.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/utils/bilibili_url_parser.dart';
import 'package:video_player_app/utils/subtitle_util.dart';

class BilibiliDownloadService extends ChangeNotifier {
  final BilibiliApiService apiService = BilibiliApiService();
  late BilibiliDownloadManager _downloadManager;
  
  // State
  List<BilibiliDownloadTask> tasks = [];
  int maxConcurrentDownloads = 1;
  int preferredQuality = 80;
  String preferredSubtitleLang = "zh";
  bool preferAiSubtitles = false;
  bool autoImportToLibrary = true;
  bool autoDeleteTaskAfterImport = false;
  bool sequentialExport = false; // New Setting
  LibraryService? libraryService;
  final List<BilibiliDownloadEpisode> _downloadQueue = [];
  int _activeDownloads = 0;
  
  bool isParsing = false;
  String? parsingStatus;

  BilibiliDownloadService() {
    _downloadManager = BilibiliDownloadManager(apiService);
  }

  Future<void> init() async {
    await apiService.init();
    await _loadTasks();
    await _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    maxConcurrentDownloads = prefs.getInt('bilibili_max_concurrent') ?? 1;
    preferredQuality = prefs.getInt('bilibili_preferred_quality') ?? 80;
    preferredSubtitleLang = prefs.getString('bilibili_preferred_subtitle_lang') ?? "zh";
    preferAiSubtitles = prefs.getBool('bilibili_prefer_ai_subtitles') ?? false;
    autoImportToLibrary = prefs.getBool('bilibili_auto_import') ?? true;
    autoDeleteTaskAfterImport = prefs.getBool('bilibili_auto_delete_import') ?? false;
    sequentialExport = prefs.getBool('bilibili_sequential_export') ?? false;
    notifyListeners();
  }

  Future<void> saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('bilibili_max_concurrent', maxConcurrentDownloads);
    await prefs.setInt('bilibili_preferred_quality', preferredQuality);
    await prefs.setString('bilibili_preferred_subtitle_lang', preferredSubtitleLang);
    await prefs.setBool('bilibili_prefer_ai_subtitles', preferAiSubtitles);
    await prefs.setBool('bilibili_auto_import', autoImportToLibrary);
    await prefs.setBool('bilibili_auto_delete_import', autoDeleteTaskAfterImport);
    await prefs.setBool('bilibili_sequential_export', sequentialExport);
    notifyListeners();
  }
  
  void updateSettings(int maxConcurrent, int quality, String subLang, bool preferAi, bool autoImport, bool autoDelete, bool seqExport) {
    maxConcurrentDownloads = maxConcurrent;
    preferredQuality = quality;
    preferredSubtitleLang = subLang;
    preferAiSubtitles = preferAi;
    autoImportToLibrary = autoImport;
    autoDeleteTaskAfterImport = autoDelete;
    sequentialExport = seqExport;
    saveSettings();
    applyQualitySettingsToPendingTasks();
    processQueue();
  }

  Future<void> _loadTasks() async {
    final loaded = await BilibiliDownloadStateManager.loadTasks();
    if (loaded.isNotEmpty) {
      tasks = loaded;
      notifyListeners();
    }
  }

  Future<void> saveTasks() async {
    await BilibiliDownloadStateManager.saveTasks(tasks);
    notifyListeners();
  }

  // --- Parsing ---

  Future<bool> parseVideo(String rawInput, {Future<bool> Function(String title)? onConfirmCollection}) async {
    if (rawInput.trim().isEmpty) return false;
    
    isParsing = true;
    parsingStatus = "正在解析...";
    notifyListeners();

    final lines = rawInput.split('\n');
    bool hasSuccess = false;
    List<String> failedLines = [];
    List<BilibiliDownloadTask> newTasks = [];

    for (var line in lines) {
      if (line.trim().isEmpty) continue;
      
      try {
        final task = await parseSingleLine(line, onConfirmCollection: onConfirmCollection);
        if (task != null) {
           newTasks.add(task);
           hasSuccess = true;
           // Auto-fetch logic handled by caller or explicit call
        } else {
           failedLines.add(line);
        }
      } catch (e) {
        debugPrint("Parse error for line '$line': $e");
        failedLines.add(line);
      }
    }
    
    // Insert new tasks at the top (index 0)
    if (newTasks.isNotEmpty) {
      tasks.insertAll(0, newTasks);
    }
    
    await saveTasks();

    isParsing = false;
    parsingStatus = hasSuccess ? "解析完成" : "解析失败";
    notifyListeners();
    
    if (hasSuccess) {
       fetchAllInfos();
    }
    
    return hasSuccess;
  }

  Future<BilibiliDownloadTask?> parseSingleLine(String line, {Future<bool> Function(String title)? onConfirmCollection}) async {
    String cleanInput = line.trim();
    
    final linkMatch = RegExp(r'(https?://[^\s]+)').firstMatch(line);
    if (linkMatch != null) {
      cleanInput = linkMatch.group(0)!;
      // Remove common trailing punctuation that might be captured from text
      // e.g. "Check this link: http://...!" -> "http://...!" -> "http://..."
      cleanInput = cleanInput.replaceAll(RegExp(r'[.,!?;:")]*$'), '');
    } else {
       final bvMatch = RegExp(r'(BV[a-zA-Z0-9]{10})', caseSensitive: false).firstMatch(line);
       if (bvMatch != null) {
          cleanInput = bvMatch.group(0)!;
       } else {
          final ssMatch = RegExp(r'(ss[0-9]+)', caseSensitive: false).firstMatch(line);
          if (ssMatch != null) {
             cleanInput = ssMatch.group(0)!;
          } else {
             final epMatch = RegExp(r'(ep[0-9]+)', caseSensitive: false).firstMatch(line);
             if (epMatch != null) {
                cleanInput = epMatch.group(0)!;
             }
          }
       }
    }

    var type = BilibiliUrlParser.determineType(cleanInput);
    
    if (type == BilibiliUrlType.shortLink) {
        final resolvedUrl = await apiService.resolveShortLink(cleanInput);
        cleanInput = resolvedUrl;
        type = BilibiliUrlParser.determineType(cleanInput);
    }
    
    final id = BilibiliUrlParser.extractId(cleanInput, type);
    if (id == null) throw Exception("无法识别 ID");

    if (type == BilibiliUrlType.bangumiEp || type == BilibiliUrlType.bangumiSs) {
        final isSs = type == BilibiliUrlType.bangumiSs;
        final data = await apiService.fetchBangumiInfo(
          epId: isSs ? null : id.substring(2),
          seasonId: isSs ? id.substring(2) : null,
        );
        
        final seasonTitle = data['title'] ?? "Bangumi Season";
        final episodesList = data['episodes'] as List? ?? [];
        
        List<BilibiliVideoItem> videoItems = episodesList.asMap().entries.map((entry) {
           final idx = entry.key;
           final e = entry.value;
           
           final videoInfo = BilibiliVideoInfo(
             title: e['long_title']?.isNotEmpty == true ? e['long_title'] : (e['title'] ?? "EP${idx+1}"),
             desc: '',
             pic: e['cover'] ?? data['cover'] ?? '',
             bvid: e['bvid'] ?? "",
             aid: e['aid']?.toString() ?? "",
             ownerName: "Bangumi",
             ownerMid: "",
             pubDate: 0,
             pages: [
               BilibiliPage(
                 cid: e['cid'] ?? 0,
                 page: 1, 
                 part: "EP${idx+1}",
                 duration: 0,
                 bvid: e['bvid'],
                 aid: e['aid']?.toString(),
               )
             ],
           );
           
           final ep = BilibiliDownloadEpisode(
             page: videoInfo.pages.first,
             bvid: videoInfo.bvid,
             isSelected: true,
           );
           
           return BilibiliVideoItem(
             videoInfo: videoInfo,
             episodes: [ep],
             isSelected: true,
           );
        }).toList();

        final collectionInfo = BilibiliCollectionInfo(
          title: seasonTitle,
          cover: data['cover'] ?? '',
          videos: videoItems.map((v) => v.videoInfo).toList(),
        );

        return BilibiliDownloadTask(
          collectionInfo: collectionInfo,
          videos: videoItems,
          isExpanded: true,
          isSelected: true,
        );

    } else {
       final info = await apiService.fetchVideoInfo(id);
       
       if (info.collectionInfo != null) {
          // Use collection info
          final collection = info.collectionInfo!;
          
          bool useCollection = true;
          if (onConfirmCollection != null) {
             useCollection = await onConfirmCollection(collection.title);
          }

          if (useCollection) {
            List<BilibiliVideoItem> videoItems = collection.videos.map((v) {
               List<BilibiliDownloadEpisode> episodes = v.pages.map((p) => 
                  BilibiliDownloadEpisode(page: p, bvid: v.bvid, isSelected: true)
               ).toList();
               
               return BilibiliVideoItem(
                  videoInfo: v,
                  episodes: episodes,
                  isExpanded: false, // Default collapsed for cleaner UI
                  isSelected: true,
               );
            }).toList();
            
            return BilibiliDownloadTask(
              collectionInfo: collection,
              videos: videoItems,
              isExpanded: true,
              isSelected: true,
            );
          } else {
             // Fallback to single video logic (same as 'else' block below)
             List<BilibiliDownloadEpisode> episodes = info.pages.map((p) => 
               BilibiliDownloadEpisode(page: p, bvid: info.bvid, isSelected: true)
             ).toList();
             
             final videoItem = BilibiliVideoItem(
               videoInfo: info,
               episodes: episodes,
               isExpanded: true,
               isSelected: true,
             );
             
             return BilibiliDownloadTask(
               singleVideoInfo: info,
               videos: [videoItem],
               isExpanded: true,
               isSelected: true,
             );
          }
       } else {
          List<BilibiliDownloadEpisode> episodes = info.pages.map((p) => 
            BilibiliDownloadEpisode(page: p, bvid: info.bvid, isSelected: true)
          ).toList();
          
          final videoItem = BilibiliVideoItem(
            videoInfo: info,
            episodes: episodes,
            isExpanded: true,
            isSelected: true,
          );
          
          return BilibiliDownloadTask(
            singleVideoInfo: info,
            videos: [videoItem],
            isExpanded: true,
            isSelected: true,
          );
       }
    }
  }

  // --- Sequential Export Logic ---
  
  // Check if there are any predecessor episodes that are active (queued, downloading, etc.)
  // or completed but NOT exported yet.
  bool _hasActivePredecessor(BilibiliDownloadEpisode currentEp) {
    // Find the task and video
    BilibiliDownloadTask? parentTask;
    BilibiliVideoItem? parentVideo;
    
    for (var t in tasks) {
      for (var v in t.videos) {
        if (v.episodes.contains(currentEp)) {
          parentTask = t;
          parentVideo = v;
          break;
        }
      }
      if (parentTask != null) break;
    }
    
    if (parentTask == null || parentVideo == null) return false;
    
    // Flatten the relevant episodes in order
    List<BilibiliDownloadEpisode> predecessors = [];
    
    if (parentTask.isCollection) {
       // All episodes in previous videos of the collection
       for (var v in parentTask.videos) {
          if (v == parentVideo) {
             // Add previous episodes in current video
             for (var ep in v.episodes) {
                if (ep == currentEp) break;
                predecessors.add(ep);
             }
             break;
          } else {
             predecessors.addAll(v.episodes);
          }
       }
    } else {
       // Single video task (maybe multi-part)
       for (var ep in parentVideo.episodes) {
          if (ep == currentEp) break;
          predecessors.add(ep);
       }
    }
    
    // Check status of predecessors
    for (var ep in predecessors) {
       // If it is NOT exported, we must wait.
       // Even if it is completed but not exported, we wait.
       // Status check:
       // - If isExported is true, we skip it (it's done).
       // - If isExported is false:
       //   - If status is failed (and stopped), should we block?
       //     User said "wait for it to export". If it failed, it won't export unless user retries.
       //     If we block on failed tasks, the queue stalls.
       //     However, user said "if there is a task queuing or downloading or merging or repairing or retrying".
       //     If it is "failed" (final state), maybe we proceed?
       //     Let's stick to "active" states + "completed but waiting export".
       
       if (ep.isExported) continue;
       
       if (ep.status == DownloadStatus.queued ||
           ep.status == DownloadStatus.fetchingInfo ||
           ep.status == DownloadStatus.downloading ||
           ep.status == DownloadStatus.merging ||
           ep.status == DownloadStatus.checking ||
           ep.status == DownloadStatus.repairing ||
           (ep.status == DownloadStatus.completed && !ep.isExported)) {
             return true;
       }
       
       // Note: If status is 'pending' (paused) or 'failed', we assume it's "stopped" and skip it.
       // Unless user manually resumes it, we don't block.
    }
    
    return false;
  }
  
  // Find and export the next episode if it was waiting
  Future<void> _checkAndExportWaitingSuccessors(BilibiliDownloadEpisode finishedEp) async {
    // Find next episode
    BilibiliDownloadTask? parentTask;
    BilibiliVideoItem? parentVideo;
    
    for (var t in tasks) {
      for (var v in t.videos) {
        if (v.episodes.contains(finishedEp)) {
          parentTask = t;
          parentVideo = v;
          break;
        }
      }
      if (parentTask != null) break;
    }
    
    if (parentTask == null || parentVideo == null) return;
    
    // Scan ALL subsequent episodes in the collection/task to see if any are waiting and now unblocked.
    // While strictly we only need to trigger the *next* one, a broader scan ensures we don't get stuck.
    // But logically, if A finishes, B checks. If B finishes, C checks.
    // The issue might be that B is "completed" but "waiting".
    
    List<BilibiliDownloadEpisode> allEpisodes = [];
    if (parentTask.isCollection) {
       for (var v in parentTask.videos) {
          allEpisodes.addAll(v.episodes);
       }
    } else {
       allEpisodes.addAll(parentVideo.episodes);
    }

    // Find index of finishedEp using CID for reliability
     int currentIndex = -1;
     for (int i = 0; i < allEpisodes.length; i++) {
        // Compare CID (part ID) and BVID to be sure
        if (allEpisodes[i].page.cid == finishedEp.page.cid && allEpisodes[i].bvid == finishedEp.bvid) {
           currentIndex = i;
           // CRITICAL: Ensure the instance in the list is marked as exported
           if (!allEpisodes[i].isExported) {
              debugPrint("Sequential Check: Force updating isExported for ${allEpisodes[i].page.part}");
              allEpisodes[i].isExported = true;
              allEpisodes[i].downloadSpeed = "已导出";
              notifyListeners();
           }
           break;
        }
     }

     if (currentIndex == -1 || currentIndex == allEpisodes.length - 1) return;
 
     // Check the immediately following episode first
     // If it is ready to export, trigger it.
     // We only trigger ONE successor to maintain sequential order.
     
     final nextIndex = currentIndex + 1;
     if (nextIndex >= allEpisodes.length) return;
     
     final nextEp = allEpisodes[nextIndex];
     
     // We are looking for the *first* successor that is "Completed AND Not Exported".
     // If we find one that is NOT completed (e.g. still downloading), we should probably stop?
     // User wants sequential export. If A is done, B is downloading, C is done.
     // Should C export? No, "Sequential". C waits for B.
     // So we only care about the *immediate* next episode.
     // If the immediate next is ready, export it.
     // If the immediate next is NOT ready (downloading/failed/pending), we stop.
     
     if (nextEp.status == DownloadStatus.completed && !nextEp.isExported && nextEp.outputPath != null) {
        debugPrint("Sequential Check: Found candidate successor ${nextEp.page.part}");
        
        // Force a fresh check of predecessors on the LIVE object in the list
        if (!_hasActivePredecessor(nextEp)) {
           debugPrint("Sequential export: Triggering export for ${nextEp.page.part}");
           nextEp.downloadSpeed = "正在导出...";
           notifyListeners(); // Update UI immediately
           
           if (libraryService != null) {
              importToLibrary(libraryService!, episode: nextEp);
           }
        } else {
           debugPrint("Sequential Check: Successor ${nextEp.page.part} still has active predecessors.");
           // If we are blocked, we should probably check WHY.
           // But for now, just logging.
        }
     }
  }

  // Batch Pause
  void pauseSelected() {
    final selectedEpisodes = _getSelectedEpisodes();
    for (var ep in selectedEpisodes) {
       pauseDownload(ep);
    }
  }

  // --- Info Fetching ---

  Future<void> fetchAllInfos() async {
     final episodes = tasks.expand((t) => t.videos).expand((v) => v.episodes)
        .where((e) => e.availableVideoQualities.isEmpty && e.status != DownloadStatus.fetchingInfo && e.status != DownloadStatus.downloading && e.status != DownloadStatus.completed)
        .toList();
        
     if (episodes.isEmpty) return;
     
     for (var ep in episodes) {
        await fetchEpisodeInfo(ep);
        await Future.delayed(const Duration(milliseconds: 200));
     }
     saveTasks();
  }

  BilibiliSubtitle? _selectBestSubtitle(List<BilibiliSubtitle> subtitles) {
    if (subtitles.isEmpty) return null;
    if (preferredSubtitleLang == "none") return null;

    final lang = preferredSubtitleLang.toLowerCase();

    // Match by 'lan' (e.g. zh-CN) OR 'lanDoc' (e.g. 中文)
    final candidates = subtitles.where((s) {
       final sLan = s.lan.toLowerCase();
       final sDoc = s.lanDoc.toLowerCase();
       
       // Check lan code (standard)
       if (sLan.startsWith(lang)) return true;
       
       // Check extended codes
       if (lang == "zh" && (sLan == "zho" || sLan == "chi")) return true;
       if (lang == "en" && (sLan == "eng")) return true;
       if (lang == "ja" && (sLan == "jpn" || sLan == "jap")) return true;
       
       // Check display name map (Case Insensitive)
       if (lang == "zh" && (sDoc.contains("中文") || sDoc.contains("chinese") || sDoc.contains("han"))) return true;
       if (lang == "en" && (sDoc.contains("english") || sDoc.contains("英语") || sDoc.contains("英文"))) return true;
       if (lang == "ja" && (sDoc.contains("日本語") || sDoc.contains("japanese") || sDoc.contains("日语"))) return true;
       
       return false;
    }).toList();

    if (candidates.isEmpty) return null;

    // Create list of (index, subtitle) to ensure stable sort (tie-breaker)
    final candidatesWithIndex = candidates.asMap().entries.toList();

    candidatesWithIndex.sort((a, b) {
      final subA = a.value;
      final subB = b.value;
      
      // 1. AI Preference
      if (preferAiSubtitles) {
        if (subA.isAi && !subB.isAi) return -1;
        if (!subA.isAi && subB.isAi) return 1;
      } else {
        if (!subA.isAi && subB.isAi) return -1;
        if (subA.isAi && !subB.isAi) return 1;
      }
      
      // 2. Tie-breaker: Original Index
      return a.key.compareTo(b.key);
    });

    return candidatesWithIndex.first.value;
  }

  Future<void> fetchEpisodeInfo(BilibiliDownloadEpisode episode) async {
    if (episode.status == DownloadStatus.fetchingInfo) return;
    
    episode.status = DownloadStatus.fetchingInfo;
    notifyListeners();

    try {
      final streamInfo = await apiService.fetchPlayUrl(episode.bvid, episode.page.cid);
      
      final task = tasks.firstWhere((t) => t.videos.any((v) => v.episodes.contains(episode)));
      final video = task.videos.firstWhere((v) => v.episodes.contains(episode));
      
      final subtitles = await apiService.fetchSubtitles(
        episode.bvid, 
        episode.page.cid, 
        aid: episode.page.aid ?? video.videoInfo.aid
      );
      
      episode.availableVideoQualities = streamInfo.videoStreams;
      if (streamInfo.videoStreams.isNotEmpty) {
        try {
           episode.selectedVideoQuality = streamInfo.videoStreams.firstWhere((q) => q.id <= preferredQuality);
        } catch (_) {
           episode.selectedVideoQuality = streamInfo.videoStreams.first;
        }
      }
      
      episode.availableSubtitles = subtitles;
      episode.selectedSubtitle = _selectBestSubtitle(subtitles);
      
      episode.status = DownloadStatus.pending;
    } catch (e) {
      episode.error = "获取信息失败: $e";
      episode.status = DownloadStatus.failed;
    }
    notifyListeners();
  }

  // --- Download Logic ---

  Future<void> startDownloadSelected() async {
    final selectedEpisodes = _getSelectedEpisodes().where((e) => e.status == DownloadStatus.pending || e.status == DownloadStatus.failed).toList();
    
    if (selectedEpisodes.isEmpty) return;

    for (var ep in selectedEpisodes) {
      if (ep.selectedVideoQuality == null) {
        await fetchEpisodeInfo(ep);
        if (ep.selectedVideoQuality == null) continue;
      }
      
      if (!_downloadQueue.contains(ep) && ep.status != DownloadStatus.downloading) {
         ep.status = DownloadStatus.queued;
         _downloadQueue.add(ep);
      }
    }
    notifyListeners();
    processQueue();
  }

  Future<void> startSingleDownload(BilibiliDownloadEpisode ep, {bool toTop = false}) async {
      if (ep.selectedVideoQuality == null) {
        await fetchEpisodeInfo(ep);
        if (ep.selectedVideoQuality == null) return;
      }
      
      // If paused/failed/pending/queued, restart/queue it.
      if (ep.status != DownloadStatus.downloading) {
         ep.status = DownloadStatus.queued;
         if (!_downloadQueue.contains(ep)) {
            if (toTop) {
               _downloadQueue.insert(0, ep);
            } else {
               _downloadQueue.add(ep);
            }
         } else if (toTop) {
            // If already in queue but user wants toTop, move it
            _downloadQueue.remove(ep);
            _downloadQueue.insert(0, ep);
         }
         notifyListeners();
         processQueue();
      }
  }

  Future<void> pauseDownload(BilibiliDownloadEpisode ep) async {
    if (ep.status == DownloadStatus.downloading) {
      ep.cancelToken?.cancel("User paused");
      ep.status = DownloadStatus.pending; 
      // Active download cancellation handled in _processDownload catch
    } else if (_downloadQueue.contains(ep)) {
      _downloadQueue.remove(ep);
      ep.status = DownloadStatus.pending; // Exit queue
      notifyListeners();
    }
  }

  void processQueue() {
    if (_activeDownloads >= maxConcurrentDownloads) return;
    if (_downloadQueue.isEmpty) return;
    
    final ep = _downloadQueue.removeAt(0);
    _activeDownloads++;
    
    _processDownload(ep);
    
    processQueue(); // Try more
  }

  Future<void> _processDownload(BilibiliDownloadEpisode ep) async {
    if (ep.selectedVideoQuality == null) {
       _activeDownloads--; // Release slot immediately if invalid
       processQueue();
       return;
    }
    
    int retryCount = 0;
    bool success = false;
    bool slotReleased = false;

    // Record original choices to restore after refresh
    // Subtitle logic: Index + Name as requested by user
    int? oldSubtitleIndex;
    String? oldSubtitleName;
    bool hadSubtitle = ep.selectedSubtitle != null;
    
    if (hadSubtitle) {
       oldSubtitleName = ep.selectedSubtitle!.lanDoc;
       oldSubtitleIndex = ep.availableSubtitles.indexOf(ep.selectedSubtitle!);
    }

    final oldQualityId = ep.selectedVideoQuality?.id;

    while (retryCount <= 3 && !success) {
      ep.status = DownloadStatus.downloading;
      ep.progress = 0.0;
      ep.error = retryCount > 0 ? "重试中 ($retryCount/3)..." : null;
      ep.cancelToken = CancelToken(); // Create new token
      notifyListeners();

      try {
        final streamInfo = await apiService.fetchPlayUrl(ep.bvid, ep.page.cid);

        // --- Refresh Info & Restore Choices ---
        // Find AID
        String? aid = ep.page.aid;
        if (aid == null) {
           try {
             final task = tasks.firstWhere((t) => t.videos.any((v) => v.episodes.contains(ep)));
             final video = task.videos.firstWhere((v) => v.episodes.contains(ep));
             aid = video.videoInfo.aid;
           } catch (_) {}
        }

        // Fetch Subtitles
        final subtitles = await apiService.fetchSubtitles(
          ep.bvid, 
          ep.page.cid, 
          aid: aid
        );

        // Update Episode Info
        ep.availableVideoQualities = streamInfo.videoStreams;
        ep.availableSubtitles = subtitles;

        // Restore Subtitle Logic
        if (hadSubtitle) {
            BilibiliSubtitle? match;
            
            // 1. Try Index + Name Match (Priority)
            if (oldSubtitleIndex != null && oldSubtitleIndex >= 0 && oldSubtitleIndex < subtitles.length) {
                if (subtitles[oldSubtitleIndex].lanDoc == oldSubtitleName) {
                    match = subtitles[oldSubtitleIndex];
                }
            }
            
            // 2. Try Name Match (Fallback)
            if (match == null && oldSubtitleName != null) {
                try {
                   match = subtitles.firstWhere((s) => s.lanDoc == oldSubtitleName);
                } catch (_) {
                   // Not found
                }
            }
            
            // 3. Fallback to default preference
            ep.selectedSubtitle = match ?? _selectBestSubtitle(subtitles);
        } else {
            ep.selectedSubtitle = null; 
        }

        // Restore Quality (Update reference to new object)
        if (oldQualityId != null) {
           try {
             ep.selectedVideoQuality = streamInfo.videoStreams.firstWhere((q) => q.id == oldQualityId);
           } catch (_) {
             // If old quality gone, fallback logic will handle it below
           }
        }
        // --- END Refresh & Restore ---
        
        StreamItem? videoStream;
        if (ep.selectedVideoQuality != null && streamInfo.videoStreams.any((s) => s.id == ep.selectedVideoQuality!.id)) {
           videoStream = streamInfo.videoStreams.firstWhere((s) => s.id == ep.selectedVideoQuality!.id);
        } else {
           videoStream = streamInfo.videoStreams.firstWhere(
             (s) => s.id <= preferredQuality,
             orElse: () => streamInfo.videoStreams.first
           );
        }
        
        final audioStream = streamInfo.audioStreams.isNotEmpty ? streamInfo.audioStreams.first : null;
        if (audioStream == null) throw Exception("No audio stream");

        // Use a safe, unique filename
        final String safeFileName = "merged_${ep.bvid}_${ep.page.cid}_${DateTime.now().millisecondsSinceEpoch}";
        
        final outputPath = await _downloadManager.downloadAndMerge(
          videoStream: videoStream,
          audioStream: audioStream,
          subtitle: ep.selectedSubtitle,
          fileName: safeFileName,
          cancelToken: ep.cancelToken,
          onProgress: (p) {
              ep.progress = p;
              notifyListeners();
          },
          onSpeedUpdate: (speed) {
              ep.downloadSpeed = speed;
              notifyListeners();
          },
          onSizeUpdate: (size) {
              ep.downloadSize = size;
              notifyListeners();
          },
          onStatusUpdate: (status) {
              ep.status = status;
              saveTasks(); // Persist status change
              notifyListeners();
          },
          onDownloadPhaseFinished: () {
              if (!slotReleased) {
                 slotReleased = true;
                 if (_activeDownloads > 0) _activeDownloads--;
                 processQueue();
              }
          },
        );
        
        ep.status = DownloadStatus.completed;
        ep.outputPath = outputPath;
        ep.progress = 1.0;
        ep.downloadSpeed = "已合成"; 
        ep.downloadSize = null; 
        saveTasks();
        
        // Auto Import
        if (autoImportToLibrary && libraryService != null) {
           // Sequential Export Check
           if (sequentialExport && _hasActivePredecessor(ep)) {
              ep.downloadSpeed = "等待前置导出...";
              saveTasks();
           } else {
              await importToLibrary(libraryService!, episode: ep);
           }
        }
        
        success = true;
        
      } catch (e) {
        if (e is DioException && e.type == DioExceptionType.cancel) {
            ep.status = DownloadStatus.pending; // Reset to pending if cancelled
            ep.error = "已暂停";
            ep.downloadSpeed = null;
            ep.downloadSize = null;
            saveTasks();
            break; // Stop retrying if cancelled
        } else {
            bool isRetryable = false;
            if (e is DioException) {
                isRetryable = e.type == DioExceptionType.connectionTimeout || 
                              e.type == DioExceptionType.receiveTimeout || 
                              e.type == DioExceptionType.sendTimeout ||
                              e.type == DioExceptionType.connectionError ||
                              (e.error is SocketException);
            }
            if (!isRetryable && e.toString().contains("Connection reset")) isRetryable = true;
            
            if (retryCount < 3 && isRetryable) {
                retryCount++;
                ep.error = "下载出错，1秒后自动重试 ($retryCount/3)...";
                notifyListeners();
                
                await Future.delayed(const Duration(seconds: 1));
                
                // Refresh Info
                try {
                   final oldQId = ep.selectedVideoQuality?.id;
                   final oldSId = ep.selectedSubtitle?.id;
                   
                   await fetchEpisodeInfo(ep);
                   
                   // Restore
                   if (oldQId != null) {
                      try { ep.selectedVideoQuality = ep.availableVideoQualities.firstWhere((q) => q.id == oldQId); } catch (_) {}
                   }
                   if (oldSId != null) {
                      try { ep.selectedSubtitle = ep.availableSubtitles.firstWhere((s) => s.id == oldSId); } catch (_) {}
                   }
                } catch (_) {}
                
                continue;
            }

            ep.status = DownloadStatus.failed;
            ep.error = "下载错误，请重试"; // Specific text requested
            ep.downloadSpeed = null;
            ep.downloadSize = null;
            saveTasks();
            break;
        }
      } finally {
         ep.cancelToken = null;
      }
    }
    
    // Ensure slot is released if download failed or finished without triggering callback
    if (!slotReleased) {
       if (_activeDownloads > 0) _activeDownloads--;
       processQueue();
    }
    notifyListeners();
  }

  // --- Management ---

  void removeSelected() async {
    final selectedEpisodes = _getSelectedEpisodes();
    
    // Stop any downloading episodes first
    for (var ep in selectedEpisodes) {
      if (ep.status == DownloadStatus.downloading) {
         ep.cancelToken?.cancel("Task deleted");
         ep.status = DownloadStatus.failed; // Or pending, but it will be removed anyway
      }
      
      // Also remove from queue if pending
      if (_downloadQueue.contains(ep)) {
         _downloadQueue.remove(ep);
      }
    }
    
    // Wait a bit for cancellations to propagate (optional but safer)
    await Future.delayed(const Duration(milliseconds: 50));
    
    for (var ep in selectedEpisodes) {
       if (ep.outputPath != null) {
          final f = File(ep.outputPath!);
          if (await f.exists()) {
             try { await f.delete(); } catch (_) {}
          }
       }
    }

    for (var task in tasks) {
      for (var video in task.videos) {
        video.episodes.removeWhere((e) => e.isSelected);
      }
      task.videos.removeWhere((v) => v.episodes.isEmpty);
    }
    tasks.removeWhere((t) => t.videos.isEmpty);
    
    saveTasks();
    notifyListeners();
  }
  
  void removeEpisode(BilibiliDownloadEpisode ep, BilibiliDownloadTask task) async {
       // Stop if downloading
       if (ep.status == DownloadStatus.downloading) {
          ep.cancelToken?.cancel("Task deleted");
          ep.status = DownloadStatus.failed;
       }
       if (_downloadQueue.contains(ep)) {
          _downloadQueue.remove(ep);
       }
       
       // Wait a bit
       await Future.delayed(const Duration(milliseconds: 50));

       if (ep.outputPath != null) {
          final f = File(ep.outputPath!);
          if (await f.exists()) await f.delete();
       }
       
       for (var v in task.videos) {
          if (v.episodes.contains(ep)) {
             v.episodes.remove(ep);
             break;
          }
       }
       task.videos.removeWhere((v) => v.episodes.isEmpty);
       if (task.videos.isEmpty) {
          tasks.remove(task);
       }
       saveTasks();
       notifyListeners();
  }

  void deleteAllTasks() async {
    // 1. Clear Queue and Cancel All Active
    _downloadQueue.clear();
    
    // We need to cancel active downloads explicitly since _activeDownloads > 0 doesn't give us the tokens directly
    // But we can iterate all tasks to find downloading ones
    for (var task in tasks) {
      for (var video in task.videos) {
        for (var ep in video.episodes) {
           if (ep.status == DownloadStatus.downloading) {
              ep.cancelToken?.cancel("Deleting all tasks");
           }
        }
      }
    }
    
    _activeDownloads = 0; 
    await Future.delayed(const Duration(milliseconds: 100)); // Wait for cancels
    
    for (var task in tasks) {
      for (var video in task.videos) {
        for (var ep in video.episodes) {
          if (ep.outputPath != null) {
            final f = File(ep.outputPath!);
            if (await f.exists()) await f.delete();
          }
        }
      }
    }
    
    try {
       final tempDir = await getTemporaryDirectory();
       if (await tempDir.exists()) {
          final files = tempDir.listSync();
          for (var f in files) {
             if (f is File) {
                final name = f.uri.pathSegments.last;
                if (name.startsWith("temp_") || name.endsWith(".m4s") || name.endsWith(".mp4")) {
                   try { await f.delete(); } catch (_) {}
                }
             }
          }
       }
    } catch (e) {
       debugPrint("Failed to clean temp dir: $e");
    }
    
    tasks.clear();
    saveTasks();
    notifyListeners();
  }

  List<BilibiliDownloadEpisode> _getSelectedEpisodes() {
    return tasks.expand((t) => t.videos).expand((v) => v.episodes).where((e) => e.isSelected).toList();
  }

  void selectAll() {
      bool anyUnselected = tasks.any((t) => !t.isSelected);
      bool target = anyUnselected;
      
      for (var t in tasks) {
        t.isSelected = target;
        for (var v in t.videos) {
           v.isSelected = target;
           for (var e in v.episodes) {
             e.isSelected = target;
           }
        }
      }
      notifyListeners();
  }

  void applyQualitySettingsToPendingTasks() {
     for (var task in tasks) {
       for (var video in task.videos) {
         for (var ep in video.episodes) {
           if (ep.status == DownloadStatus.pending || ep.status == DownloadStatus.failed || (ep.status == DownloadStatus.completed && ep.outputPath == null)) {
               // Update Video Quality
               if (ep.availableVideoQualities.isNotEmpty) {
                  StreamItem? bestMatch;
                  try {
                    bestMatch = ep.availableVideoQualities.firstWhere((q) => q.id <= preferredQuality);
                  } catch (_) {
                    bestMatch = ep.availableVideoQualities.first;
                  }
                  ep.selectedVideoQuality = bestMatch;
               }
               
               // Update Subtitle Selection
               if (ep.availableSubtitles.isNotEmpty) {
                  ep.selectedSubtitle = _selectBestSubtitle(ep.availableSubtitles);
               }
           }
         }
       }
     }
     notifyListeners();
  }

  // --- Helper Methods for Library Import ---

  Future<String?> _findCollectionId(LibraryService library, String name, String? parentId) async {
    final contents = library.getContents(parentId);
    for (var item in contents) {
      if (item is VideoCollection && item.name == name) {
        return item.id;
      }
    }
    return null;
  }

  Future<String> _getOrCreateCollection(LibraryService library, String name, String? parentId) async {
    final existingId = await _findCollectionId(library, name, parentId);
    if (existingId != null) return existingId;
    
    final newCollection = await library.createCollection(name, parentId);
    return newCollection.id;
  }

  // --- Import ---
  
  Future<int> importToLibrary(LibraryService library, {BilibiliDownloadEpisode? episode, String? targetFolderId}) async {
    List<BilibiliDownloadEpisode> completedEpisodes;
    if (episode != null) {
       if (episode.status != DownloadStatus.completed || episode.outputPath == null) {
          return 0;
       }
       completedEpisodes = [episode];
    } else {
       completedEpisodes = _getSelectedEpisodes().where((e) => e.status == DownloadStatus.completed && e.outputPath != null).toList();
    }
    
    if (completedEpisodes.isEmpty) return 0;

    final appDir = await getApplicationDocumentsDirectory();
    final thumbDir = Directory('${appDir.path}/thumbnails');
    if (!await thumbDir.exists()) await thumbDir.create(recursive: true);
    final subDir = Directory('${appDir.path}/subtitles');
    if (!await subDir.exists()) await subDir.create(recursive: true);

    int count = 0;
    
    for (var ep in completedEpisodes) {
      final file = File(ep.outputPath!);
      if (!file.existsSync()) continue;
      
      try {
        if (await file.length() < 1024) continue;
      } catch (e) {
        continue;
      }

      final task = tasks.firstWhere((t) => t.videos.any((v) => v.episodes.contains(ep)));
      final video = task.videos.firstWhere((v) => v.episodes.contains(ep));
      
      // --- Hierarchy Logic ---
      
      // 1. Level 1: Collection/Season
      String? rootCollectionId;
      if (task.collectionInfo != null) {
         rootCollectionId = await _getOrCreateCollection(library, task.collectionInfo!.title, targetFolderId);
      } else {
         rootCollectionId = targetFolderId;
      }
      
      // 2. Level 2: Video Folder (if multi-part)
      String? targetParentId = rootCollectionId;
      if (video.videoInfo.pages.length > 1) {
         // Create a folder for this video inside the root (or root itself)
         targetParentId = await _getOrCreateCollection(library, video.videoInfo.title, rootCollectionId);
      }
      
      // --- End Hierarchy Logic ---
      
      final uuid = const Uuid().v4();
      final extension = file.path.split('.').last;
      
      // Sanitize and truncate for filename to avoid OS limits (max 255 bytes)
      // Use stricter regex to avoid potential issues with special chars in player
      // Allow only alphanumeric, Chinese, dots, dashes, underscores
      String safeTitle = video.videoInfo.title.replaceAll(RegExp(r'[^\w\u4e00-\u9fa5\.-]'), '_');
      if (safeTitle.length > 30) safeTitle = safeTitle.substring(0, 30);
      
      String safePart = ep.page.part.replaceAll(RegExp(r'[^\w\u4e00-\u9fa5\.-]'), '_');
      if (safePart.length > 20) safePart = safePart.substring(0, 20);

      final finalName = "${safeTitle}_${safePart}_$uuid.$extension";
      final finalPath = "${appDir.path}/imported_videos/$finalName";
      
      debugPrint("=== Import Debug Info ===");
      debugPrint("Source path: ${file.path}");
      debugPrint("Target path: $finalPath");
      debugPrint("App dir: ${appDir.path}");
      debugPrint("File exists: ${file.existsSync()}");
      debugPrint("========================");
      
      // Ensure target directory exists
      final targetFile = File(finalPath);
      if (!await targetFile.parent.exists()) {
        await targetFile.parent.create(recursive: true);
      }

      // Copy instead of move to keep source valid for re-import and preview
      if (file.path != finalPath) {
        await file.copy(finalPath);
        debugPrint("File copied successfully");
        debugPrint("Target file exists: ${targetFile.existsSync()}");
        debugPrint("Target file size: ${targetFile.lengthSync()}");
        // Do NOT delete the source file
      }
      
      // Use the original source path for playback to avoid path issues
      // This matches the preview player behavior which works correctly
      final playbackPath = file.path;
      
      String? thumbPath;
      try {
         final coverUrl = video.videoInfo.pic;
         if (coverUrl.isNotEmpty) {
             final resp = await apiService.dio.get(
               coverUrl, 
               options: Options(responseType: ResponseType.bytes)
             );
             final ext = coverUrl.split('.').last.split('?').first;
             final safeExt = (ext.length > 4 || ext.isEmpty) ? 'jpg' : ext;
             thumbPath = "${thumbDir.path}/$uuid.$safeExt";
             await File(thumbPath).writeAsBytes(resp.data);
         }
      } catch (e) {
         debugPrint("Failed to download cover: $e");
      }
      
      Map<String, String> extraSubtitles = {};
      final srtPath = ep.outputPath!.replaceAll(RegExp(r'\.mp4$'), '.srt');
      final srtFile = File(srtPath);
      String? defaultSubtitlePath;
      
      if (await srtFile.exists()) {
         final finalSrtPath = "${subDir.path}/${uuid}_default.srt";
         await srtFile.copy(finalSrtPath);
         // Do NOT delete source subtitle
         defaultSubtitlePath = finalSrtPath;
      }
      
      if (ep.availableSubtitles.isNotEmpty) {
         for (var sub in ep.availableSubtitles) {
            try {
               final lang = sub.lan;
               final url = sub.url;
               final resp = await apiService.dio.get(url);
               final srtContent = SubtitleUtil.convertJsonToSrt(resp.data);
               
               if (srtContent.isNotEmpty) {
                  final subPath = "${subDir.path}/${uuid}_$lang.srt";
                  await File(subPath).writeAsString(srtContent);
                  extraSubtitles[sub.lanDoc] = subPath;
               }
            } catch (e) {
               debugPrint("Failed to download subtitle ${sub.lanDoc}: $e");
            }
         }
      }

      // Determine Display Title
      // If inside a video-specific folder (multi-part), use part name.
      // If standing alone (single-part), use video title.
      String displayTitle;
      if (video.videoInfo.pages.length > 1) {
         displayTitle = ep.page.part;
      } else {
         displayTitle = video.videoInfo.title;
      }

      // Determine Codec
      String? codec;
      if (ep.selectedVideoQuality != null) {
         final c = ep.selectedVideoQuality!.codecs;
         if (c.startsWith("hev1") || c.startsWith("hvc1") || c.contains("hevc")) {
            codec = "hevc";
         } else if (c.startsWith("avc1")) {
            codec = "avc";
         } else {
            codec = c.split('.').first;
         }
      }

      final item = VideoItem(
        id: uuid,
        path: playbackPath,
        title: displayTitle,
        thumbnailPath: thumbPath,
        durationMs: 0,
        lastUpdated: DateTime.now().millisecondsSinceEpoch,
        parentId: targetParentId,
        subtitlePath: defaultSubtitlePath,
        additionalSubtitles: extraSubtitles,
        codec: codec,
      );
      
      await library.addSingleVideo(item);
      count++;
      
      // Update Export Status
      final importedEp = tasks.expand((t) => t.videos).expand((v) => v.episodes).firstWhere((e) => e.outputPath == ep.outputPath, orElse: () => ep);
      if (importedEp.outputPath == ep.outputPath) {
         importedEp.isExported = true;
         importedEp.downloadSpeed = "已导出";
      }

      // Auto Delete Task
      if (autoDeleteTaskAfterImport) {
        removeEpisode(importedEp, task);
      } else {
        // Save state immediately to ensure consistency
        await saveTasks();
        
        // Only check successors if task wasn't deleted
        if (sequentialExport) {
           // Small delay to allow state/UI propagation
           await Future.delayed(const Duration(milliseconds: 500));
           await _checkAndExportWaitingSuccessors(importedEp);
        }
      }
    }
    
    // Final save (redundant if loop ran, but safe)
    if (count > 0 && !autoDeleteTaskAfterImport) saveTasks(); 
    return count;
  }
}
