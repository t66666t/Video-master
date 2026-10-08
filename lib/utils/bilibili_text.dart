/// Text helpers for Bilibili API payloads.
library;

final RegExp _htmlTag = RegExp(r'<[^>]*>');
final RegExp _numericEntity = RegExp(r'&#(x?[0-9a-fA-F]+);');

const Map<String, String> _namedEntities = <String, String>{
  '&amp;': '&',
  '&quot;': '"',
  '&#39;': "'",
  '&apos;': "'",
  '&lt;': '<',
  '&gt;': '>',
  '&nbsp;': ' ',
};

/// Removes search highlight markup such as `<em class="keyword">` and decodes
/// common HTML entities.
String stripBilibiliHighlight(String? raw) {
  if (raw == null || raw.isEmpty) return '';
  var text = raw.replaceAll(_htmlTag, '');
  text = text.replaceAllMapped(_numericEntity, (match) {
    final body = match.group(1)!;
    final code = body.startsWith('x') || body.startsWith('X')
        ? int.tryParse(body.substring(1), radix: 16)
        : int.tryParse(body);
    if (code == null || code <= 0 || code > 0x10FFFF) return match.group(0)!;
    return String.fromCharCode(code);
  });
  // &amp; last so "&amp;lt;" stays "&lt;" instead of turning into "<".
  for (final entry in _namedEntities.entries) {
    if (entry.key == '&amp;') continue;
    text = text.replaceAll(entry.key, entry.value);
  }
  text = text.replaceAll('&amp;', '&');
  return text.trim();
}

/// 12345 -> 1.2万, 123456789 -> 1.2亿.
String formatBilibiliCount(int value) {
  if (value < 0) return '0';
  if (value >= 100000000) {
    return '${_oneDecimal(value / 100000000)}亿';
  }
  if (value >= 10000) {
    return '${_oneDecimal(value / 10000)}万';
  }
  return value.toString();
}

String _oneDecimal(double value) {
  final text = value.toStringAsFixed(1);
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

/// 75 -> 01:15, 3725 -> 1:02:05.
String formatBilibiliDuration(int seconds) {
  if (seconds <= 0) return '--:--';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// "1:02:05" / "12:34" / "75" -> seconds. Invalid text -> 0.
int parseBilibiliDurationText(String? raw) {
  final text = raw?.trim() ?? '';
  if (text.isEmpty) return 0;
  final parts = text.split(':').map((p) => int.tryParse(p.trim())).toList();
  if (parts.any((p) => p == null || p < 0)) return 0;
  var total = 0;
  for (final part in parts) {
    total = total * 60 + part!;
  }
  return total;
}

String formatBilibiliDate(DateTime? time) {
  if (time == null) return '';
  final local = time.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}';
}
