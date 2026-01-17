import 'package:dio/dio.dart';
import 'package:video_player_app/models/bilibili_models.dart';

enum DownloadStatus {
  pending,
  queued, // Waiting in queue
  fetchingInfo, // Fetching streams/qualities
  downloading,
  merging,
  checking, // Verifying playback compatibility
  repairing, // Transcoding to fix compatibility
  completed,
  failed,
}

class BilibiliDownloadTask {
  // If collectionInfo is present, it's a Collection (Level 1)
  final BilibiliCollectionInfo? collectionInfo; 
  
  // If not a collection, this is the main video info (Level 2)
  final BilibiliVideoInfo? singleVideoInfo;
  
  // Flattened access to all episodes? No, we need structure.
  // Level 2 Items (Videos).
  // If Single Video Task: this list has 1 item (the single video).
  // If Collection Task: this list has N items (videos in collection).
  final List<BilibiliVideoItem> videos;
  
  bool isExpanded;
  bool isSelected;

  BilibiliDownloadTask({
    this.collectionInfo,
    this.singleVideoInfo,
    required this.videos,
    this.isExpanded = true,
    this.isSelected = false,
  });
  
  bool get isCollection => collectionInfo != null;
  String get title => isCollection ? collectionInfo!.title : (singleVideoInfo?.title ?? "");
  String get cover => isCollection ? collectionInfo!.cover : (singleVideoInfo?.pic ?? "");

  Map<String, dynamic> toJson() {
    return {
      'collectionInfo': collectionInfo?.toJson(),
      'singleVideoInfo': singleVideoInfo?.toJson(),
      'videos': videos.map((v) => v.toJson()).toList(),
      'isExpanded': isExpanded,
      'isSelected': isSelected,
    };
  }

  factory BilibiliDownloadTask.fromJson(Map<String, dynamic> json) {
    return BilibiliDownloadTask(
      collectionInfo: json['collectionInfo'] != null ? BilibiliCollectionInfo.fromMap(json['collectionInfo']) : null,
      singleVideoInfo: json['singleVideoInfo'] != null ? BilibiliVideoInfo.fromMap(json['singleVideoInfo']) : null,
      videos: (json['videos'] as List).map((e) => BilibiliVideoItem.fromJson(e)).toList(),
      isExpanded: json['isExpanded'] ?? true,
      isSelected: json['isSelected'] ?? false,
    );
  }
}

class BilibiliVideoItem {
  final BilibiliVideoInfo videoInfo;
  final List<BilibiliDownloadEpisode> episodes; // Level 3 (Parts)
  
  bool isExpanded;
  bool isSelected;

  BilibiliVideoItem({
    required this.videoInfo,
    required this.episodes,
    this.isExpanded = false,
    this.isSelected = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'videoInfo': videoInfo.toJson(),
      'episodes': episodes.map((e) => e.toJson()).toList(),
      'isExpanded': isExpanded,
      'isSelected': isSelected,
    };
  }

  factory BilibiliVideoItem.fromJson(Map<String, dynamic> json) {
    return BilibiliVideoItem(
      videoInfo: BilibiliVideoInfo.fromMap(json['videoInfo']),
      episodes: (json['episodes'] as List).map((e) => BilibiliDownloadEpisode.fromJson(e)).toList(),
      isExpanded: json['isExpanded'] ?? false,
      isSelected: json['isSelected'] ?? false,
    );
  }
}

class BilibiliDownloadEpisode {
  final BilibiliPage page;
  final String bvid; // Need parent BVID for API calls
  
  // Selection
  bool isSelected;
  
  // Options
  StreamItem? selectedVideoQuality;
  List<StreamItem> availableVideoQualities;
  
  BilibiliSubtitle? selectedSubtitle;
  List<BilibiliSubtitle> availableSubtitles;
  
  // Status
  DownloadStatus status;
  double progress;
  String? downloadSpeed; // New: Formatted speed string (e.g. "2.5 MB/s")
  String? downloadSize; // New: Formatted size string (e.g. "150MB / 200MB")
  bool isExported; // New: Track if exported to library
  String? error;
  String? outputPath; // Final mp4 path

  // Runtime control (not serialized)
  CancelToken? cancelToken;

  BilibiliDownloadEpisode({
    required this.page,
    required this.bvid,
    this.isSelected = false,
    this.selectedVideoQuality,
    this.availableVideoQualities = const [],
    this.selectedSubtitle,
    this.availableSubtitles = const [],
    this.status = DownloadStatus.pending,
    this.progress = 0.0,
    this.downloadSpeed,
    this.downloadSize,
    this.isExported = false,
    this.error,
    this.outputPath,
    this.cancelToken,
  });

  Map<String, dynamic> toJson() {
    return {
      'page': page.toJson(),
      'bvid': bvid,
      'isSelected': isSelected,
      'selectedVideoQuality': selectedVideoQuality?.toJson(),
      'availableVideoQualities': availableVideoQualities.map((e) => e.toJson()).toList(),
      'selectedSubtitle': selectedSubtitle?.toJson(),
      'availableSubtitles': availableSubtitles.map((e) => e.toJson()).toList(),
      'status': status.index,
      'progress': progress,
      'isExported': isExported, // Persist export status
      'error': error,
      'outputPath': outputPath,
    };
  }

  factory BilibiliDownloadEpisode.fromJson(Map<String, dynamic> json) {
    return BilibiliDownloadEpisode(
      page: BilibiliPage.fromJson(json['page']),
      bvid: json['bvid'],
      isSelected: json['isSelected'] ?? false,
      selectedVideoQuality: json['selectedVideoQuality'] != null ? StreamItem.fromJson(json['selectedVideoQuality']) : null,
      availableVideoQualities: (json['availableVideoQualities'] as List?)?.map((e) => StreamItem.fromJson(e)).toList() ?? [],
      selectedSubtitle: json['selectedSubtitle'] != null ? BilibiliSubtitle.fromJson(json['selectedSubtitle']) : null,
      availableSubtitles: (json['availableSubtitles'] as List?)?.map((e) => BilibiliSubtitle.fromJson(e)).toList() ?? [],
      status: DownloadStatus.values[json['status'] ?? 0],
      progress: json['progress'] ?? 0.0,
      isExported: json['isExported'] ?? false,
      error: json['error'],
      outputPath: json['outputPath'],
    );
  }
}

class BilibiliSubtitle {
  final String id;
  final String lan;
  final String lanDoc; // Display name
  final String url;
  final bool isAi;

  BilibiliSubtitle({
    required this.id,
    required this.lan,
    required this.lanDoc,
    required this.url,
    required this.isAi,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'lan': lan,
      'lanDoc': lanDoc,
      'url': url,
      'isAi': isAi,
    };
  }

  factory BilibiliSubtitle.fromJson(Map<String, dynamic> json) {
    return BilibiliSubtitle(
      id: json['id'],
      lan: json['lan'],
      lanDoc: json['lanDoc'],
      url: json['url'],
      isAi: json['isAi'],
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BilibiliSubtitle &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          lan == other.lan;

  @override
  int get hashCode => id.hashCode ^ lan.hashCode;
}
