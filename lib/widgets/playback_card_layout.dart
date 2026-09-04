import 'package:flutter/material.dart';

/// 播放卡片尺寸数据类
class PlaybackCardDimensions {
  /// 卡片高度
  final double height;

  /// 缩略图尺寸
  final double thumbnailSize;

  /// 标题字体大小
  final double titleFontSize;

  /// 字幕字体大小
  final double subtitleFontSize;

  /// 图标尺寸
  final double iconSize;

  /// 内边距
  final double padding;

  const PlaybackCardDimensions({
    required this.height,
    required this.thumbnailSize,
    required this.titleFontSize,
    required this.subtitleFontSize,
    required this.iconSize,
    required this.padding,
  });
}

/// 响应式布局计算器
class PlaybackCardLayout {
  /// 根据屏幕宽度计算播放卡片的响应式尺寸
  ///
  /// 设备类型判断：
  /// - 手机: 屏幕宽度 < 600dp
  /// - 平板: 600dp <= 屏幕宽度 < 1200dp
  /// - 桌面: 屏幕宽度 >= 1200dp
  static PlaybackCardDimensions calculate(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;

    // 判断设备类型
    final isPhone = screenWidth < 600;
    final isTablet = screenWidth >= 600 && screenWidth < 1200;

    // 根据设备类型返回对应的尺寸
    if (isPhone) {
      // 手机设备
      return const PlaybackCardDimensions(
        height: 124.0,
        thumbnailSize: 40.0,
        titleFontSize: 14.0,
        subtitleFontSize: 13.0,
        iconSize: 22.0,
        padding: 6.0,
      );
    } else if (isTablet) {
      // 平板设备
      return const PlaybackCardDimensions(
        height: 146.0,
        thumbnailSize: 48.0,
        titleFontSize: 15.0,
        subtitleFontSize: 14.0,
        iconSize: 26.0,
        padding: 8.0,
      );
    } else {
      // 桌面设备
      return const PlaybackCardDimensions(
        height: 124.0,
        thumbnailSize: 40.0,
        titleFontSize: 14.0,
        subtitleFontSize: 13.0,
        iconSize: 22.0,
        padding: 6.0,
      );
    }
  }
}

/// Keeps the mini player and its action-button column in one coordinate system.
///
/// System bars can briefly report a zero bottom inset while a playback route is
/// leaving immersive mode. [resolveStableBottomInset] deliberately never lets
/// the reserved inset shrink during the lifetime of the host page, preventing
/// that transient metrics update from moving either overlay.
class PlaybackCardOverlayLayout {
  static const double cardBottomGap = 6.0;
  static const double actionButtonsGap = 16.0;
  static const double actionButtonsEndInset = 16.0;

  static double resolveStableBottomInset(
    MediaQueryData mediaQuery,
    double previousInset,
  ) {
    var resolved = previousInset;
    final candidates = <double>[
      mediaQuery.viewPadding.bottom,
      mediaQuery.padding.bottom,
      mediaQuery.systemGestureInsets.bottom,
    ];
    for (final candidate in candidates) {
      if (candidate > resolved) resolved = candidate;
    }
    return resolved;
  }

  static double cardBottom(double stableBottomInset) {
    return stableBottomInset + cardBottomGap;
  }

  static double actionButtonsBottom({
    required double stableBottomInset,
    required double cardHeight,
    required bool isCardVisible,
  }) {
    if (!isCardVisible) {
      return stableBottomInset + actionButtonsGap;
    }
    return cardBottom(stableBottomInset) + cardHeight + actionButtonsGap;
  }
}

/// Anchors the action-button overlay to the physical bottom-right corner.
/// All safe-area and mini-player offsets are supplied by the child's padding,
/// so Scaffold does not add a second, implicit system-bar displacement.
class PlaybackActionButtonsLocation extends FloatingActionButtonLocation {
  const PlaybackActionButtonsLocation();

  @override
  Offset getOffset(ScaffoldPrelayoutGeometry scaffoldGeometry) {
    return Offset(
      scaffoldGeometry.scaffoldSize.width -
          scaffoldGeometry.floatingActionButtonSize.width -
          PlaybackCardOverlayLayout.actionButtonsEndInset,
      scaffoldGeometry.scaffoldSize.height -
          scaffoldGeometry.floatingActionButtonSize.height,
    );
  }
}
