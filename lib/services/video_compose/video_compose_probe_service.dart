import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';

import '../../models/video_compose_models.dart';
import 'video_compose_types.dart';

class VideoComposeProbeService {
  const VideoComposeProbeService();

  Future<VideoProbeInfo> probeVideoInfo(String videoPath) async {
    // Use the embedded FFprobe implementation on every platform. In
    // particular, do not resolve `ffprobe` through PATH on desktop: Windows
    // app launches commonly inherit stale WinGet links, while GUI apps on
    // macOS do not reliably inherit the user's shell PATH.
    return _probeByFfmpegKit(videoPath);
  }

  TargetResolution targetResolution({
    required int sourceWidth,
    required int sourceHeight,
    required VideoComposeResolution resolution,
  }) {
    final int safeSourceWidth = sourceWidth <= 0 ? 1920 : sourceWidth;
    final int safeSourceHeight = sourceHeight <= 0 ? 1080 : sourceHeight;
    if (resolution == VideoComposeResolution.source) {
      return TargetResolution(
        width: ensureEven(safeSourceWidth),
        height: ensureEven(safeSourceHeight),
      );
    }
    final int targetHeight = switch (resolution) {
      VideoComposeResolution.p360 => 360,
      VideoComposeResolution.p480 => 480,
      VideoComposeResolution.p720 => 720,
      VideoComposeResolution.p1080 => 1080,
      VideoComposeResolution.p1440 => 1440,
      VideoComposeResolution.p2160 => 2160,
      VideoComposeResolution.source => safeSourceHeight,
    };
    final double ratio = safeSourceWidth / safeSourceHeight;
    final int width = ensureEven((targetHeight * ratio).round());
    return TargetResolution(width: width, height: targetHeight);
  }

  int ensureEven(int value) {
    final int safe = value <= 0 ? 2 : value;
    return safe.isEven ? safe : safe + 1;
  }

  Future<VideoProbeInfo> _probeByFfmpegKit(String videoPath) async {
    final dynamic session = await FFprobeKit.getMediaInformation(
      videoPath,
    ).timeout(const Duration(seconds: 15));
    final dynamic mediaInfo = session.getMediaInformation();
    if (mediaInfo == null) {
      final String? logs = await session.getAllLogsAsString();
      throw StateError(
        logs?.trim().isNotEmpty == true ? logs!.trim() : '无法读取视频信息',
      );
    }
    final double durationSec =
        double.tryParse(mediaInfo.getDuration() ?? '') ?? 0;
    int width = 0;
    int height = 0;
    int rotation = 0;
    String? sar;
    final List<dynamic> streams = mediaInfo.getStreams();
    for (final dynamic stream in streams) {
      if (stream.getType() == 'video') {
        width = _toInt(stream.getWidth());
        height = _toInt(stream.getHeight());
        sar = stream.getSampleAspectRatio()?.toString();
        final dynamic properties = stream.getAllProperties();
        if (properties is Map) {
          rotation = _parseRotationFromStream(properties);
        }
        break;
      }
    }
    final int safeWidth = width <= 0 ? 1920 : width;
    final int safeHeight = height <= 0 ? 1080 : height;
    final DisplaySize display = _resolveDisplaySize(
      width: safeWidth,
      height: safeHeight,
      sar: sar,
      rotation: rotation,
    );
    return VideoProbeInfo(
      width: safeWidth,
      height: safeHeight,
      displayWidth: display.width,
      displayHeight: display.height,
      rotation: rotation,
      duration: Duration(milliseconds: (durationSec * 1000).round()),
    );
  }

  int _toInt(Object? value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is double) return value.round();
    return int.tryParse(value.toString()) ?? 0;
  }

  int _parseRotationFromStream(Map<dynamic, dynamic> stream) {
    int normalize(int raw) {
      final int value = raw % 360;
      if (value < 0) return value + 360;
      return value;
    }

    final dynamic tags = stream['tags'];
    if (tags is Map) {
      final int? fromTag = int.tryParse(tags['rotate']?.toString() ?? '');
      if (fromTag != null) return normalize(fromTag);
    }
    final dynamic sideDataList = stream['side_data_list'];
    if (sideDataList is List) {
      for (final dynamic item in sideDataList) {
        if (item is! Map) continue;
        final dynamic rotationValue = item['rotation'];
        final int? rotation = rotationValue is int
            ? rotationValue
            : int.tryParse(rotationValue?.toString() ?? '');
        if (rotation != null) {
          return normalize(rotation);
        }
      }
    }
    return 0;
  }

  DisplaySize _resolveDisplaySize({
    required int width,
    required int height,
    required String? sar,
    required int rotation,
  }) {
    final List<String> sarParts = (sar ?? '')
        .split(':')
        .where((String e) => e.isNotEmpty)
        .toList();
    int sarNum = 1;
    int sarDen = 1;
    if (sarParts.length == 2) {
      sarNum = int.tryParse(sarParts[0]) ?? 1;
      sarDen = int.tryParse(sarParts[1]) ?? 1;
      if (sarNum <= 0 || sarDen <= 0) {
        sarNum = 1;
        sarDen = 1;
      }
    }
    int displayWidth = ((width * sarNum) / sarDen).round();
    int displayHeight = height;
    if (displayWidth <= 0) {
      displayWidth = width;
    }
    if (displayHeight <= 0) {
      displayHeight = height;
    }
    final bool rotate90 = rotation == 90 || rotation == 270;
    if (rotate90) {
      final int swappedWidth = displayHeight;
      final int swappedHeight = displayWidth;
      displayWidth = swappedWidth;
      displayHeight = swappedHeight;
    }
    return DisplaySize(
      width: ensureEven(displayWidth),
      height: ensureEven(displayHeight),
    );
  }
}
