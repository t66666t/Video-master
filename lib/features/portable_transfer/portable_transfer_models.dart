import 'dart:io';

enum PortableTransferKind { export, import }

enum PortableTransferStatus {
  queued,
  preparing,
  running,
  completed,
  failed,
  cancelled,
}

enum PortableCompression { fast, balanced, smallest }

enum PortableExportFormat { fluentPack, zip }

class PortableExportOptions {
  final String packageName;
  final bool wrapInFolder;
  final bool includeSidecars;
  final bool verifyChecksums;
  final PortableCompression compression;
  final PortableExportFormat format;
  final bool zipEmbedSubtitles;
  final bool zipExternalSubtitles;
  final bool includeDanmaku;

  const PortableExportOptions({
    required this.packageName,
    this.wrapInFolder = true,
    this.includeSidecars = true,
    this.verifyChecksums = true,
    this.compression = PortableCompression.fast,
    this.format = PortableExportFormat.fluentPack,
    this.zipEmbedSubtitles = true,
    this.zipExternalSubtitles = false,
    this.includeDanmaku = false,
  });

  bool get isZip => format == PortableExportFormat.zip;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'packageName': packageName,
    'wrapInFolder': wrapInFolder,
    'includeSidecars': includeSidecars,
    'verifyChecksums': verifyChecksums,
    'compression': compression.name,
    'format': format.name,
    'zipEmbedSubtitles': zipEmbedSubtitles,
    'zipExternalSubtitles': zipExternalSubtitles,
    'includeDanmaku': includeDanmaku,
  };

  factory PortableExportOptions.fromJson(Map<String, dynamic> json) {
    final legacyMode = json['zipSubtitleMode']?.toString();
    final hasEmbed = json.containsKey('zipEmbedSubtitles');
    final hasExternal = json.containsKey('zipExternalSubtitles');
    return PortableExportOptions(
      packageName: json['packageName']?.toString() ?? '未命名导出包',
      wrapInFolder: json['wrapInFolder'] != false,
      includeSidecars: json['includeSidecars'] != false,
      verifyChecksums: json['verifyChecksums'] != false,
      compression: PortableCompression.values.firstWhere(
        (value) => value.name == json['compression'],
        orElse: () => PortableCompression.fast,
      ),
      format: PortableExportFormat.values.firstWhere(
        (value) => value.name == json['format'],
        orElse: () => PortableExportFormat.fluentPack,
      ),
      zipEmbedSubtitles: hasEmbed
          ? json['zipEmbedSubtitles'] == true
          : legacyMode != 'external' && legacyMode != 'none',
      zipExternalSubtitles: hasExternal
          ? json['zipExternalSubtitles'] == true
          : legacyMode == 'external',
      includeDanmaku: json['includeDanmaku'] == true,
    );
  }
}

/// Thrown when the user cancels a portable export before it finishes.
class PortableExportCancelled implements Exception {
  const PortableExportCancelled();
}

class PortableTransferTask {
  final String id;
  final PortableTransferKind kind;
  final DateTime createdAt;
  String title;
  String subtitle;
  PortableTransferStatus status;
  double progress;
  String? filePath;
  String? error;
  int itemCount;
  int processedBytes;
  int totalBytes;
  bool cancelRequested;

  PortableTransferTask({
    required this.id,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.createdAt,
    this.status = PortableTransferStatus.queued,
    this.progress = 0,
    this.filePath,
    this.error,
    this.itemCount = 0,
    this.processedBytes = 0,
    this.totalBytes = 0,
    this.cancelRequested = false,
  });

  bool get isActive =>
      status == PortableTransferStatus.queued ||
      status == PortableTransferStatus.preparing ||
      status == PortableTransferStatus.running;

  bool get canOpen =>
      status == PortableTransferStatus.completed &&
      filePath != null &&
      File(filePath!).existsSync();

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'kind': kind.name,
    'createdAt': createdAt.toIso8601String(),
    'title': title,
    'subtitle': subtitle,
    'status': status.name,
    'progress': progress,
    'filePath': filePath,
    'error': error,
    'itemCount': itemCount,
    'processedBytes': processedBytes,
    'totalBytes': totalBytes,
  };

  factory PortableTransferTask.fromJson(Map<String, dynamic> json) =>
      PortableTransferTask(
        id: json['id']?.toString() ?? '',
        kind: PortableTransferKind.values.firstWhere(
          (value) => value.name == json['kind'],
          orElse: () => PortableTransferKind.export,
        ),
        createdAt:
            DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
            DateTime.now(),
        title: json['title']?.toString() ?? '未命名任务',
        subtitle: json['subtitle']?.toString() ?? '',
        status: PortableTransferStatus.values.firstWhere(
          (value) => value.name == json['status'],
          orElse: () => PortableTransferStatus.failed,
        ),
        progress: (json['progress'] as num?)?.toDouble() ?? 0,
        filePath: json['filePath']?.toString(),
        error: json['error']?.toString(),
        itemCount: (json['itemCount'] as num?)?.toInt() ?? 0,
        processedBytes: (json['processedBytes'] as num?)?.toInt() ?? 0,
        totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      );
}

class PortableTaskRemovalResult {
  final int removedTaskCount;
  final int deletedFileCount;
  final List<String> failedFilePaths;

  const PortableTaskRemovalResult({
    required this.removedTaskCount,
    required this.deletedFileCount,
    this.failedFilePaths = const <String>[],
  });

  bool get hasFailures => failedFilePaths.isNotEmpty;
}

class PortablePackagePreview {
  final String packageName;
  final DateTime createdAt;
  final int mediaCount;
  final int folderCount;
  final int fileCount;
  final int totalBytes;
  final bool hasChecksums;
  final int formatVersion;

  const PortablePackagePreview({
    required this.packageName,
    required this.createdAt,
    required this.mediaCount,
    required this.folderCount,
    required this.fileCount,
    required this.totalBytes,
    required this.hasChecksums,
    required this.formatVersion,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'packageName': packageName,
    'createdAt': createdAt.toIso8601String(),
    'mediaCount': mediaCount,
    'folderCount': folderCount,
    'fileCount': fileCount,
    'totalBytes': totalBytes,
    'hasChecksums': hasChecksums,
    'formatVersion': formatVersion,
  };

  factory PortablePackagePreview.fromJson(Map<String, dynamic> json) =>
      PortablePackagePreview(
        packageName: json['packageName']?.toString() ?? '未命名导出包',
        createdAt:
            DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
            DateTime.now(),
        mediaCount: (json['mediaCount'] as num?)?.toInt() ?? 0,
        folderCount: (json['folderCount'] as num?)?.toInt() ?? 0,
        fileCount: (json['fileCount'] as num?)?.toInt() ?? 0,
        totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
        hasChecksums: json['hasChecksums'] == true,
        formatVersion: (json['formatVersion'] as num?)?.toInt() ?? 0,
      );
}

/// A `.fluentpack` file that should be imported without showing the picker.
class PortableImportSource {
  final String path;
  final String displayName;
  final bool ownedTemporaryCopy;

  const PortableImportSource({
    required this.path,
    required this.displayName,
    this.ownedTemporaryCopy = false,
  });

  factory PortableImportSource.fromPath(
    String path, {
    bool ownedTemporaryCopy = false,
  }) {
    final normalized = path.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    return PortableImportSource(
      path: path,
      displayName: slash < 0 ? path : normalized.substring(slash + 1),
      ownedTemporaryCopy: ownedTemporaryCopy,
    );
  }
}
