import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_speed_meter.dart';

void main() {
  test('progress line percent is converted with binary units', () {
    final amounts = parseYtDlpProgressAmounts(
      '[download]  50.0% of   10.00MiB at    2.00MiB/s ETA 00:05',
    );
    expect(amounts?.totalBytes, 10 * 1024 * 1024);
    expect(amounts?.downloadedBytes, 5 * 1024 * 1024);
  });

  test('estimated fragment line still yields downloaded bytes', () {
    final amounts = parseYtDlpProgressAmounts(
      '[download]  10.0% of ~ 100.00MiB at    8.00MiB/s ETA 00:10 (frag 2/20)',
    );
    expect(amounts?.downloadedBytes, 10 * 1024 * 1024);
  });

  test('size-only progress line uses the leading amount', () {
    final amounts = parseYtDlpProgressAmounts(
      '[download]  12.00MiB at  1.50MiB/s (00:08)',
    );
    expect(amounts?.downloadedBytes, 12 * 1024 * 1024);
    expect(amounts?.totalBytes, isNull);
  });

  test('a short burst is not treated as the sustained speed', () {
    final meter = YtDlpSpeedMeter();
    final start = DateTime(2026, 9, 26, 20, 0, 0);
    // 20 MiB landing in 50 ms would be about 400 MB/s if divided by that gap.
    expect(
      meter.record(
        downloadedBytes: 0,
        now: start,
      ),
      isNull,
    );
    expect(
      meter.record(
        downloadedBytes: 20 * 1024 * 1024,
        now: start.add(const Duration(milliseconds: 50)),
      ),
      isNull,
    );
    final settled = meter.record(
      downloadedBytes: 20 * 1024 * 1024,
      now: start.add(const Duration(seconds: 10)),
    );
    expect(settled, closeTo(20 * 1024 * 1024 / 10, 1));
  });

  test('steady growth over the window is the sustained MB/s', () {
    final meter = YtDlpSpeedMeter();
    final start = DateTime(2026, 9, 26, 20, 0, 0);
    const bytesPerSecond = 5 * 1000 * 1000;
    double? rate;
    for (var second = 0; second <= 10; second++) {
      rate = meter.record(
        downloadedBytes: bytesPerSecond * second,
        now: start.add(Duration(seconds: second)),
      );
    }
    expect(rate, closeTo(bytesPerSecond.toDouble(), 1));
    expect(formatYtDlpBytesPerSecond(rate!), '5.0MB/s');
  });

  test('a new smaller file starts a fresh window', () {
    final meter = YtDlpSpeedMeter();
    final start = DateTime(2026, 9, 26, 20, 0, 0);
    meter.record(downloadedBytes: 0, now: start);
    meter.record(
      downloadedBytes: 50 * 1024 * 1024,
      now: start.add(const Duration(seconds: 10)),
    );
    expect(
      meter.record(
        downloadedBytes: 1024 * 1024,
        now: start.add(const Duration(seconds: 11)),
      ),
      isNull,
    );
    final rate = meter.record(
      downloadedBytes: 3 * 1024 * 1024,
      now: start.add(const Duration(seconds: 13)),
    );
    expect(rate, closeTo(2 * 1024 * 1024 / 2, 1));
  });

  test('reported speeds are averaged across the window', () {
    final meter = YtDlpSpeedMeter();
    final start = DateTime(2026, 9, 26, 20, 0, 0);
    meter.record(reportedSpeedText: '40.00MiB/s', now: start);
    meter.record(
      reportedSpeedText: '40.00MiB/s',
      now: start.add(const Duration(seconds: 1)),
    );
    final rate = meter.record(
      reportedSpeedText: '4.00MiB/s',
      now: start.add(const Duration(seconds: 2)),
    );
    final fast = 40 * 1024 * 1024;
    final slow = 4 * 1024 * 1024;
    expect(rate, closeTo((fast + slow) / 2, 1));
  });
}
