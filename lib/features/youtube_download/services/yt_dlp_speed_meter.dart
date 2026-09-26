/// Speed shown on a yt-dlp task.
///
/// yt-dlp reports the last few seconds. A fragment that finishes inside that
/// window looks much faster than the file is actually growing. This meter
/// uses the bytes received over up to 10 seconds, which is the sustained rate.
class YtDlpSpeedMeter {
  static const sampleWindow = Duration(seconds: 10);
  static const minimumSampleAge = Duration(seconds: 2);

  final List<({DateTime at, int bytes})> _bytes = [];
  final List<({DateTime at, double bytesPerSecond})> _rates = [];

  void reset() {
    _bytes.clear();
    _rates.clear();
  }

  /// Bytes per second, or null until two seconds of samples exist.
  ///
  /// [downloadedBytes] is the cumulative file size. When it is missing, the
  /// meter averages [reportedSpeedText] over the same window instead.
  double? record({
    int? downloadedBytes,
    String? reportedSpeedText,
    required DateTime now,
  }) {
    if (downloadedBytes != null && downloadedBytes >= 0) {
      _rates.clear();
      return _recordBytes(downloadedBytes, now);
    }
    final reported = parseYtDlpByteRate(reportedSpeedText);
    if (reported == null) return null;
    return _recordRate(reported, now);
  }

  double? _recordBytes(int bytes, DateTime now) {
    if (_bytes.isNotEmpty && bytes < _bytes.last.bytes) {
      final last = _bytes.last.bytes;
      final drop = last - bytes;
      final roundingNoise =
          drop < 256 * 1024 && (last == 0 || drop < last * 0.005);
      if (roundingNoise) {
        bytes = last;
      } else {
        _bytes.clear();
      }
    }
    _bytes.add((at: now, bytes: bytes));
    final cutoff = now.subtract(sampleWindow);
    while (_bytes.length > 1 && !_bytes[1].at.isAfter(cutoff)) {
      _bytes.removeAt(0);
    }
    final elapsedMs = now.difference(_bytes.first.at).inMilliseconds;
    if (elapsedMs < minimumSampleAge.inMilliseconds) return null;
    final delta = _bytes.last.bytes - _bytes.first.bytes;
    if (delta <= 0) return 0;
    return delta * 1000.0 / elapsedMs;
  }

  double? _recordRate(double bytesPerSecond, DateTime now) {
    _rates.add((at: now, bytesPerSecond: bytesPerSecond));
    final cutoff = now.subtract(sampleWindow);
    while (_rates.length > 1 && !_rates[1].at.isAfter(cutoff)) {
      _rates.removeAt(0);
    }
    if (_rates.length < 2) return null;
    final elapsedMs = now.difference(_rates.first.at).inMilliseconds;
    if (elapsedMs < minimumSampleAge.inMilliseconds) return null;
    var weighted = 0.0;
    var weightMs = 0;
    for (var i = 1; i < _rates.length; i++) {
      final dt = _rates[i].at.difference(_rates[i - 1].at).inMilliseconds;
      if (dt <= 0) continue;
      weighted += _rates[i].bytesPerSecond * dt;
      weightMs += dt;
    }
    if (weightMs <= 0) return _rates.last.bytesPerSecond;
    return weighted / weightMs;
  }
}

class YtDlpProgressAmounts {
  const YtDlpProgressAmounts({this.downloadedBytes, this.totalBytes});

  final int? downloadedBytes;
  final int? totalBytes;
}

/// Bytes implied by a yt-dlp progress line such as
/// `[download]  38.6% of   25.97MiB at    2.79MiB/s ETA 00:05`.
YtDlpProgressAmounts? parseYtDlpProgressAmounts(String line) {
  final percentOf = RegExp(
    r'(\d+(?:\.\d+)?)%\s+of\s+~?\s*(\d+(?:\.\d+)?)\s*([KMGT]?)(i?)B',
    caseSensitive: false,
  ).firstMatch(line);
  if (percentOf != null) {
    final percent = double.tryParse(percentOf.group(1) ?? '');
    final total = _scaledBytes(
      percentOf.group(2),
      percentOf.group(3),
      percentOf.group(4),
    );
    if (percent == null || total == null) return null;
    return YtDlpProgressAmounts(
      downloadedBytes: (total * percent / 100).round(),
      totalBytes: total,
    );
  }
  final bare = RegExp(
    r'\[download\]\s+(\d+(?:\.\d+)?)\s*([KMGT]?)(i?)B\s+at\b',
    caseSensitive: false,
  ).firstMatch(line);
  if (bare == null) return null;
  final downloaded = _scaledBytes(bare.group(1), bare.group(2), bare.group(3));
  if (downloaded == null) return null;
  return YtDlpProgressAmounts(downloadedBytes: downloaded);
}

/// `2.79MiB/s` or `2.79MB/s` as bytes per second.
double? parseYtDlpByteRate(String? raw) {
  final bytes = _scaledBytesFromRate(raw);
  if (bytes == null) return null;
  return bytes.toDouble();
}

String formatYtDlpBytesPerSecond(double bytesPerSecond) {
  if (!bytesPerSecond.isFinite || bytesPerSecond <= 0) return '0B/s';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytesPerSecond;
  var unitIndex = 0;
  while (value >= 1000 && unitIndex < units.length - 1) {
    value /= 1000;
    unitIndex++;
  }
  final digits = unitIndex == 0 || value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)}${units[unitIndex]}/s';
}

int? _scaledBytesFromRate(String? raw) {
  final trimmed = raw?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  final match = RegExp(
    r'^([0-9]+(?:\.[0-9]+)?)\s*([KMGT]?)(i?)B/s$',
    caseSensitive: false,
  ).firstMatch(trimmed);
  if (match == null) return null;
  return _scaledBytes(match.group(1), match.group(2), match.group(3));
}

int? _scaledBytes(String? number, String? prefix, String? binaryMark) {
  final value = double.tryParse(number ?? '');
  if (value == null || !value.isFinite || value < 0) return null;
  final exponent = switch ((prefix ?? '').toUpperCase()) {
    'K' => 1,
    'M' => 2,
    'G' => 3,
    'T' => 4,
    _ => 0,
  };
  final base = (binaryMark ?? '').isEmpty ? 1000.0 : 1024.0;
  var bytes = value;
  for (var i = 0; i < exponent; i++) {
    bytes *= base;
  }
  if (bytes > 1 << 62) return null;
  return bytes.round();
}
