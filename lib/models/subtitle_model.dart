import 'dart:typed_data';

class SubtitleItem {
  final int index;
  final Duration startTime;
  final Duration endTime;
  final String text;
  final Future<Uint8List?> Function()? imageLoader; // Lazy loader for bitmap subtitles (PGS/VobSub)

  SubtitleItem({
    required this.index,
    required this.startTime,
    required this.endTime,
    this.text = "",
    this.imageLoader,
  });

  @override
  String toString() {
    return '[$index] $startTime -> $endTime: ${text.isEmpty ? "[Image]" : text}';
  }
}
