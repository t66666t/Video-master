enum MediaSourceKind { url, bilibiliBv, bilibiliId, bilibiliStream }

class MediaSourceRef {
  final String value;
  final MediaSourceKind kind;
  final String? originalValue;
  final String? bvid;
  final String? aid;
  final int? cid;
  final int? page;

  const MediaSourceRef({
    required this.value,
    required this.kind,
    this.originalValue,
    this.bvid,
    this.aid,
    this.cid,
    this.page,
  });

  Map<String, dynamic> toJson() {
    return {
      'value': value,
      'kind': kind.name,
      'originalValue': originalValue,
      'bvid': bvid,
      'aid': aid,
      'cid': cid,
      'page': page,
    };
  }

  factory MediaSourceRef.fromJson(Map<String, dynamic> json) {
    final value = (json['value'] ?? '').toString().trim();
    return MediaSourceRef(
      value: value,
      kind: MediaSourceKind.values.firstWhere(
        (item) => item.name == json['kind'],
        orElse: () => MediaSourceKind.url,
      ),
      originalValue: _nullableTrimmedString(json['originalValue']),
      bvid: _nullableTrimmedString(json['bvid']),
      aid: _nullableTrimmedString(json['aid']),
      cid: _nullablePositiveInt(json['cid']),
      page: _nullablePositiveInt(json['page']),
    );
  }

  MediaSourceRef copyWith({
    String? value,
    MediaSourceKind? kind,
    Object? originalValue = _unset,
    Object? bvid = _unset,
    Object? aid = _unset,
    Object? cid = _unset,
    Object? page = _unset,
  }) {
    return MediaSourceRef(
      value: value ?? this.value,
      kind: kind ?? this.kind,
      originalValue: identical(originalValue, _unset)
          ? this.originalValue
          : originalValue as String?,
      bvid: identical(bvid, _unset) ? this.bvid : bvid as String?,
      aid: identical(aid, _unset) ? this.aid : aid as String?,
      cid: identical(cid, _unset) ? this.cid : cid as int?,
      page: identical(page, _unset) ? this.page : page as int?,
    );
  }

  static MediaSourceRef? fromJsonOrNull(Object? json) {
    if (json is! Map) {
      return null;
    }
    final parsed = MediaSourceRef.fromJson(Map<String, dynamic>.from(json));
    return parsed.value.isEmpty ? null : parsed;
  }
}

const Object _unset = Object();

String? _nullableTrimmedString(Object? value) {
  if (value == null) {
    return null;
  }
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

int? _nullablePositiveInt(Object? value) {
  final parsed = value is int ? value : int.tryParse(value?.toString() ?? '');
  return parsed != null && parsed > 0 ? parsed : null;
}
