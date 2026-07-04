enum MediaSourceKind { url, bilibiliBv, bilibiliId }

class MediaSourceRef {
  final String value;
  final MediaSourceKind kind;
  final String? originalValue;

  const MediaSourceRef({
    required this.value,
    required this.kind,
    this.originalValue,
  });

  Map<String, dynamic> toJson() {
    return {
      'value': value,
      'kind': kind.name,
      'originalValue': originalValue,
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
    );
  }

  MediaSourceRef copyWith({
    String? value,
    MediaSourceKind? kind,
    Object? originalValue = _unset,
  }) {
    return MediaSourceRef(
      value: value ?? this.value,
      kind: kind ?? this.kind,
      originalValue: identical(originalValue, _unset)
          ? this.originalValue
          : originalValue as String?,
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
