import 'media_source_ref.dart';

enum MediaType { video, audio }

class VideoItem {
  final String id;
  String path;
  String title;
  String? thumbnailPath;
  int durationMs;
  int lastPositionMs;
  String? subtitlePath;
  bool isSubtitleCached;
  String? secondarySubtitlePath;
  bool isSecondarySubtitleCached;
  int lastUpdated;
  String? parentId;
  bool isRecycled;
  int? recycleTime;
  Map<String, String>? additionalSubtitles;
  String? codec;
  MediaType type;
  bool showFloatingSubtitles;
  List<String>? recycledSelectedSubtitlePaths;
  Map<String, String>? recycledAdditionalSubtitles;
  bool isBilibiliExported;
  bool usesManagedAssociatedSubtitles;
  bool blockAutoAssociatedSubtitleSelection;
  bool hasAttemptedAutoEmbeddedSubtitleLoad;
  double? portraitDisplayAspectRatio;
  double? portraitCustomAspectWidth;
  double? portraitCustomAspectHeight;
  bool hasPortraitAspectPreferenceInitialized;
  bool isVideoMirroredH;
  bool isVideoMirroredV;
  String? sourceFingerprint;
  MediaSourceRef? sourceRef;



  VideoItem({

    required this.id,
    required this.path,
    required this.title,
    this.thumbnailPath,
    required this.durationMs,
    this.lastPositionMs = 0,
    this.subtitlePath,
    this.isSubtitleCached = false,
    this.secondarySubtitlePath,
    this.isSecondarySubtitleCached = false,
    required this.lastUpdated,
    this.parentId,
    this.isRecycled = false,
    this.recycleTime,
    this.additionalSubtitles,
    this.codec,
    this.type = MediaType.video,
    this.showFloatingSubtitles = true,
    this.recycledSelectedSubtitlePaths,
    this.recycledAdditionalSubtitles,
    this.isBilibiliExported = false,
    this.usesManagedAssociatedSubtitles = false,
    this.blockAutoAssociatedSubtitleSelection = false,
    this.hasAttemptedAutoEmbeddedSubtitleLoad = false,
    this.portraitDisplayAspectRatio,
    this.portraitCustomAspectWidth,
    this.portraitCustomAspectHeight,
    this.hasPortraitAspectPreferenceInitialized = false,
    this.isVideoMirroredH = false,
    this.isVideoMirroredV = false,
    this.sourceFingerprint,
    this.sourceRef,
  });


  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'path': path,
      'title': title,
      'thumbnailPath': thumbnailPath,
      'durationMs': durationMs,
      'lastPositionMs': lastPositionMs,
      'subtitlePath': subtitlePath,
      'isSubtitleCached': isSubtitleCached,
      'secondarySubtitlePath': secondarySubtitlePath,
      'isSecondarySubtitleCached': isSecondarySubtitleCached,
      'lastUpdated': lastUpdated,
      'parentId': parentId,
      'isRecycled': isRecycled,
      'recycleTime': recycleTime,
      'extraSubtitles': additionalSubtitles,
      'codec': codec,
      'type': type.name,
      'showFloatingSubtitles': showFloatingSubtitles,
      'recycledSelectedSubtitlePaths': recycledSelectedSubtitlePaths,
      'recycledExtraSubtitles': recycledAdditionalSubtitles,
      'isBilibiliExported': isBilibiliExported,
      'usesManagedAssociatedSubtitles': usesManagedAssociatedSubtitles,
      'blockAutoAssociatedSubtitleSelection': blockAutoAssociatedSubtitleSelection,
      'hasAttemptedAutoEmbeddedSubtitleLoad': hasAttemptedAutoEmbeddedSubtitleLoad,
      'portraitDisplayAspectRatio': portraitDisplayAspectRatio,
      'portraitCustomAspectWidth': portraitCustomAspectWidth,
      'portraitCustomAspectHeight': portraitCustomAspectHeight,
      'hasPortraitAspectPreferenceInitialized': hasPortraitAspectPreferenceInitialized,
      'isVideoMirroredH': isVideoMirroredH,
      'isVideoMirroredV': isVideoMirroredV,
      'sourceFingerprint': sourceFingerprint,
      'sourceRef': sourceRef?.toJson(),

    };
  }

  factory VideoItem.fromJson(Map<String, dynamic> json) {
    return VideoItem(
      id: json['id'] as String,
      path: json['path'] as String,
      title: json['title'] as String,
      thumbnailPath: _normalizeLocalFilePath(json['thumbnailPath'] as String?),
      durationMs: json['durationMs'] as int? ?? 0,
      lastPositionMs: json['lastPositionMs'] as int? ?? 0,
      subtitlePath: json['subtitlePath'] as String?,
      isSubtitleCached: json['isSubtitleCached'] as bool? ?? false,
      secondarySubtitlePath: json['secondarySubtitlePath'] as String?,
      isSecondarySubtitleCached: json['isSecondarySubtitleCached'] as bool? ?? false,
      lastUpdated: json['lastUpdated'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      parentId: json['parentId'] as String?,
      isRecycled: json['isRecycled'] as bool? ?? false,
      recycleTime: json['recycleTime'] as int?,
      additionalSubtitles: (json['extraSubtitles'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(k, v as String)),
      codec: json['codec'] as String?,
      type: json['type'] != null ? MediaType.values.firstWhere((e) => e.name == json['type'], orElse: () => MediaType.video) : MediaType.video,
      showFloatingSubtitles: json['showFloatingSubtitles'] as bool? ?? true,
      recycledSelectedSubtitlePaths: (json['recycledSelectedSubtitlePaths'] as List?)?.map((e) => e.toString()).toList(),
      recycledAdditionalSubtitles: (json['recycledExtraSubtitles'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(k, v as String)),
      isBilibiliExported: json['isBilibiliExported'] as bool? ?? false,
      usesManagedAssociatedSubtitles: json['usesManagedAssociatedSubtitles'] as bool? ?? false,
      blockAutoAssociatedSubtitleSelection: json['blockAutoAssociatedSubtitleSelection'] as bool? ?? false,
      hasAttemptedAutoEmbeddedSubtitleLoad: json['hasAttemptedAutoEmbeddedSubtitleLoad'] as bool? ?? false,
      portraitDisplayAspectRatio: (json['portraitDisplayAspectRatio'] as num?)?.toDouble(),
      portraitCustomAspectWidth: (json['portraitCustomAspectWidth'] as num?)?.toDouble(),
      portraitCustomAspectHeight: (json['portraitCustomAspectHeight'] as num?)?.toDouble(),
      hasPortraitAspectPreferenceInitialized:
          json['hasPortraitAspectPreferenceInitialized'] as bool? ?? false,
      isVideoMirroredH: json['isVideoMirroredH'] as bool? ?? false,
      isVideoMirroredV: json['isVideoMirroredV'] as bool? ?? false,
      sourceFingerprint: json['sourceFingerprint'] as String?,
      sourceRef: MediaSourceRef.fromJsonOrNull(json['sourceRef']),
    );
  }

  bool get prefersManagedAssociatedSubtitles =>
      isBilibiliExported || usesManagedAssociatedSubtitles;
}

String? _normalizeLocalFilePath(String? path) {
  final trimmed = path?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  if (trimmed.startsWith('file://')) {
    try {
      return Uri.parse(trimmed).toFilePath();
    } catch (_) {
      return trimmed.replaceFirst(RegExp(r'^file:/+'), '');
    }
  }
  return trimmed;
}
