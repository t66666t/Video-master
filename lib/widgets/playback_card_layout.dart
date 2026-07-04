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
        height: 117.0, // 略微增加高度以容纳更大的字幕按钮
        thumbnailSize: 50.0,
        titleFontSize: 14.0,
        subtitleFontSize: 13.0,
        iconSize: 24.0,
        padding: 12.0,
      );
    } else if (isTablet) {
      // 平板设备
      return const PlaybackCardDimensions(
        height: 127.0, // 略微增加高度以容纳更大的字幕按钮
        thumbnailSize: 60.0,
        titleFontSize: 15.0,
        subtitleFontSize: 14.0,
        iconSize: 28.0,
        padding: 16.0,
      );
    } else {
      // 桌面设备
      return const PlaybackCardDimensions(
        height: 107.0, // 略微增加高度以容纳更大的字幕按钮
        thumbnailSize: 50.0,
        titleFontSize: 14.0,
        subtitleFontSize: 13.0,
        iconSize: 24.0,
        padding: 12.0,
      );
    }
  }
}
