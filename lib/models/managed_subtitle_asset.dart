enum ManagedSubtitleAssetKind {
  ai,
  translated,
  imported,
  manual,
  embedded,
  downloaded,
  ocr,
  cached;

  static ManagedSubtitleAssetKind fromStorage(String? value) {
    return ManagedSubtitleAssetKind.values.firstWhere(
      (kind) => kind.name == value,
      orElse: () => ManagedSubtitleAssetKind.imported,
    );
  }
}

class ManagedSubtitleAsset {
  final String assetId;
  final String path;
  final ManagedSubtitleAssetKind kind;
  final String displayName;
  final String? sourceAssetId;
  final String? language;
  final int createdAt;

  const ManagedSubtitleAsset({
    required this.assetId,
    required this.path,
    required this.kind,
    required this.displayName,
    this.sourceAssetId,
    this.language,
    required this.createdAt,
  });

  ManagedSubtitleAsset copyWith({
    String? path,
    String? displayName,
    String? sourceAssetId,
    String? language,
  }) {
    return ManagedSubtitleAsset(
      assetId: assetId,
      path: path ?? this.path,
      kind: kind,
      displayName: displayName ?? this.displayName,
      sourceAssetId: sourceAssetId ?? this.sourceAssetId,
      language: language ?? this.language,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'assetId': assetId,
    'path': path,
    'kind': kind.name,
    'displayName': displayName,
    'sourceAssetId': sourceAssetId,
    'language': language,
    'createdAt': createdAt,
  };

  factory ManagedSubtitleAsset.fromJson(Map<String, dynamic> json) {
    return ManagedSubtitleAsset(
      assetId: json['assetId']?.toString() ?? '',
      path: json['path']?.toString() ?? '',
      kind: ManagedSubtitleAssetKind.fromStorage(json['kind']?.toString()),
      displayName: json['displayName']?.toString() ?? '',
      sourceAssetId: json['sourceAssetId']?.toString(),
      language: json['language']?.toString(),
      createdAt: json['createdAt'] as int? ?? 0,
    );
  }
}
