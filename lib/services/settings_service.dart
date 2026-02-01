import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import '../models/subtitle_style.dart';

class SettingsService extends ChangeNotifier {
  static final SettingsService _instance = SettingsService._internal();
  factory SettingsService() => _instance;
  SettingsService._internal();

  late SharedPreferences _prefs;
  bool _initialized = false;

  // Settings Fields
  bool showSubtitles = true;
  bool isMirroredH = false;
  bool isMirroredV = false;
  double playbackSpeed = 1.0;
  double longPressSpeed = 2.0;
  int doubleTapSeekSeconds = 5;
  bool enableDoubleTapSubtitleSeek = true;
  double userSubtitleSidebarWidth = 320.0;

  // Subtitle Settings - 新的结构
  // 文字样式 - 横竖屏共享
  SubtitleTextStyle subtitleTextStyle = const SubtitleTextStyle();

  // 布局样式 - 横竖屏独立
  SubtitleLayoutStyle subtitleLayoutLandscape = const SubtitleLayoutStyle();
  SubtitleLayoutStyle subtitleLayoutPortrait = const SubtitleLayoutStyle();

  // 音频字幕 - 同样结构
  SubtitleTextStyle audioSubtitleTextStyle = const SubtitleTextStyle();
  SubtitleLayoutStyle audioSubtitleLayoutLandscape = const SubtitleLayoutStyle();
  SubtitleLayoutStyle audioSubtitleLayoutPortrait = const SubtitleLayoutStyle();

  // 便捷访问器 - 视频字幕完整样式
  SubtitleStyle get subtitleStyleLandscape => SubtitleStyle(
    textStyle: subtitleTextStyle,
    layoutStyle: subtitleLayoutLandscape,
  );
  SubtitleStyle get subtitleStylePortrait => SubtitleStyle(
    textStyle: subtitleTextStyle,
    layoutStyle: subtitleLayoutPortrait,
  );

  // 便捷访问器 - 音频字幕完整样式
  SubtitleStyle get audioSubtitleStyleLandscape => SubtitleStyle(
    textStyle: audioSubtitleTextStyle,
    layoutStyle: audioSubtitleLayoutLandscape,
  );
  SubtitleStyle get audioSubtitleStylePortrait => SubtitleStyle(
    textStyle: audioSubtitleTextStyle,
    layoutStyle: audioSubtitleLayoutPortrait,
  );

  // Backward compatibility getter/setter (maps to landscape for now)
  SubtitleStyle get subtitleStyle => subtitleStyleLandscape;

  Alignment subtitleAlignment = const Alignment(0.0, 0.9);
  List<Map<String, double>> subtitlePresets = [];
  Duration subtitleOffset = Duration.zero;

  // New: Auto Cache Subtitles
  bool autoCacheSubtitles = true;

  // New: Auto Scroll Subtitles
  bool autoScrollSubtitles = false;

  // New: Auto Load Embedded Subtitles
  bool autoLoadEmbeddedSubtitles = false;

  // New: Grid Size Settings
  int homeGridCrossAxisCount = 2;
  int videoCardCrossAxisCount = 2;

  // New: Home Card Style
  double homeCardTitleFontSize = 14.0;
  double homeCardAspectRatio = 0.8;

  // New: Video Card Style
  double videoCardTitleFontSize = 14.0;
  double videoCardAspectRatio = 0.8;

  // New: Subtitle Sidebar Font Scale (Landscape)
  double landscapeSidebarFontSizeScale = 1.0;

  // New: Subtitle Sidebar Font Scale (Portrait)
  double portraitSidebarFontSizeScale = 1.0;

  // New: Subtitle Sidebar View Mode (0: List, 1: Article)
  int subtitleViewMode = 0;

  // New: AI Model Selection
  String lastSelectedModelType = 'base';

  // New: Subtitle Ghost Mode
  bool isGhostModeEnabled = false;
  Alignment ghostModeAlignment = const Alignment(0.0, 0.9);
  double ghostSubtitleFontSize = 39.0;
  double ghostSubtitleLetterSpacing = 0.0;

  // New: Split Subtitle by Line
  bool splitSubtitleByLine = true;

  // New: Continuous Subtitle Display
  bool videoContinuousSubtitle = false;
  bool audioContinuousSubtitle = false;

  // New: Auto Pause on Exit
  bool autoPauseOnExit = true;

  // New: Auto Play Next Video
  bool autoPlayNextVideo = true;

  // New: Action Buttons Collapsed State
  bool isActionButtonsCollapsed = false;

  // New: Window Management
  bool isFullScreen = false;

  // New: Seek Preview
  bool enableSeekPreview = true;

  Future<void> toggleFullScreen() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      isFullScreen = !isFullScreen;
      await windowManager.setFullScreen(isFullScreen);
      notifyListeners();
    }
  }

  // Helpers for subtitle delay (seconds <-> duration)
  double get subtitleDelay => subtitleOffset.inMilliseconds / 1000.0;

  void setSubtitleDelay(double seconds) {
    subtitleOffset = Duration(milliseconds: (seconds * 1000).round());
    notifyListeners();
  }

  Future<void> saveSubtitleDelay(double seconds) async {
    setSubtitleDelay(seconds);
    await _prefs.setInt('subtitleOffset', subtitleOffset.inMilliseconds);
  }

  Future<void> init() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();

    // Determine Device Type for Defaults
    // Threshold: 600 logical pixels width
    final physicalSize = PlatformDispatcher.instance.views.first.physicalSize;
    final devicePixelRatio = PlatformDispatcher.instance.views.first.devicePixelRatio;
    final logicalWidth = physicalSize.width / devicePixelRatio;
    final bool isTablet = logicalWidth >= 600;

    showSubtitles = _prefs.getBool('showSubtitles') ?? true;
    isMirroredH = _prefs.getBool('isMirroredH') ?? false;
    isMirroredV = _prefs.getBool('isMirroredV') ?? false;
    playbackSpeed = _prefs.getDouble('playbackSpeed') ?? 1.0;
    longPressSpeed = _prefs.getDouble('longPressSpeed') ?? 2.0;
    doubleTapSeekSeconds = _prefs.getInt('doubleTapSeekSeconds') ?? 5;
    enableDoubleTapSubtitleSeek = _prefs.getBool('enableDoubleTapSubtitleSeek') ?? true;
    userSubtitleSidebarWidth = _prefs.getDouble('userSubtitleSidebarWidth') ?? 320.0;
    autoCacheSubtitles = _prefs.getBool('autoCacheSubtitles') ?? true;
    autoScrollSubtitles = _prefs.getBool('autoScrollSubtitles') ?? true;
    autoLoadEmbeddedSubtitles = _prefs.getBool('autoLoadEmbeddedSubtitles') ?? false;
    splitSubtitleByLine = _prefs.getBool('splitSubtitleByLine') ?? true;
    videoContinuousSubtitle = _prefs.getBool('videoContinuousSubtitle') ?? false;
    audioContinuousSubtitle = _prefs.getBool('audioContinuousSubtitle') ?? false;
    autoPauseOnExit = _prefs.getBool('autoPauseOnExit') ?? true;
    autoPlayNextVideo = _prefs.getBool('autoPlayNextVideo') ?? true;
    isActionButtonsCollapsed = _prefs.getBool('isActionButtonsCollapsed') ?? false;
    enableSeekPreview = _prefs.getBool('enableSeekPreview') ?? true;

    // Tablet vs Phone Defaults
    homeGridCrossAxisCount = (_prefs.getInt('homeGridCrossAxisCount') ?? (isTablet ? 6 : 2)).clamp(1, 10);
    videoCardCrossAxisCount = (_prefs.getInt('videoCardCrossAxisCount') ?? (isTablet ? 6 : 2)).clamp(1, 10);

    homeCardTitleFontSize = _prefs.getDouble('homeCardTitleFontSize') ?? (isTablet ? 13.0 : 14.0);
    homeCardAspectRatio = _prefs.getDouble('homeCardAspectRatio') ?? (isTablet ? 0.8 : 0.66); // 1.25 height vs 1.50 height

    videoCardTitleFontSize = _prefs.getDouble('videoCardTitleFontSize') ?? (isTablet ? 13.0 : 14.0);
    videoCardAspectRatio = _prefs.getDouble('videoCardAspectRatio') ?? (isTablet ? 0.8 : 0.66);

    // Migrate old 'sidebarFontSizeScale' to 'landscapeSidebarFontSizeScale' if present
    // Default 1.1 for Landscape
    landscapeSidebarFontSizeScale = _prefs.getDouble('landscapeSidebarFontSizeScale') ??
                                   _prefs.getDouble('sidebarFontSizeScale') ?? 1.1;
    portraitSidebarFontSizeScale = _prefs.getDouble('portraitSidebarFontSizeScale') ?? 1.0;
    subtitleViewMode = _prefs.getInt('subtitleViewMode') ?? 0;
    lastSelectedModelType = _prefs.getString('lastSelectedModelType') ?? 'base';

    isGhostModeEnabled = _prefs.getBool('isGhostModeEnabled') ?? false;
    final ghostAlignX = _prefs.getDouble('ghostModeAlignX') ?? 0.0;
    final ghostAlignY = _prefs.getDouble('ghostModeAlignY') ?? 0.9;
    ghostModeAlignment = Alignment(ghostAlignX, ghostAlignY);

    subtitleOffset = Duration(milliseconds: _prefs.getInt('subtitleOffset') ?? 0);

    final alignX = _prefs.getDouble('subtitleAlignX') ?? 0.0;
    final alignY = _prefs.getDouble('subtitleAlignY') ?? 0.9;
    subtitleAlignment = Alignment(alignX, alignY);

    // 加载字幕样式 - 新的结构
    await _loadSubtitleStyles();

    final presetsJson = _prefs.getString('subtitlePresets');
    if (presetsJson != null) {
      try {
        final List<dynamic> decoded = json.decode(presetsJson);
        subtitlePresets = decoded.map((e) => Map<String, double>.from(e)).toList();
      } catch (e) {
        developer.log('Error loading presets', error: e);
      }
    }

    _initialized = true;
    notifyListeners();
  }

  /// 加载字幕样式 - 支持新旧格式迁移
  Future<void> _loadSubtitleStyles() async {
    // 尝试加载新的文字样式格式
    final textStyleJson = _prefs.getString('subtitleTextStyle');
    if (textStyleJson != null) {
      try {
        subtitleTextStyle = SubtitleTextStyle.fromJson(json.decode(textStyleJson));
      } catch (e) {
        developer.log('Error loading subtitle text style', error: e);
      }
    } else {
      // 从旧格式迁移
      final legacyStyleJson = _prefs.getString('subtitleStyleLandscape') ?? _prefs.getString('subtitleStyle');
      if (legacyStyleJson != null) {
        try {
          final legacyStyle = SubtitleStyle.fromJson(json.decode(legacyStyleJson));
          subtitleTextStyle = legacyStyle.textStyle;
        } catch (e) {
          developer.log('Error migrating legacy subtitle style', error: e);
        }
      }
    }

    // 加载音频文字样式
    final audioTextStyleJson = _prefs.getString('audioSubtitleTextStyle');
    if (audioTextStyleJson != null) {
      try {
        audioSubtitleTextStyle = SubtitleTextStyle.fromJson(json.decode(audioTextStyleJson));
      } catch (e) {
        developer.log('Error loading audio subtitle text style', error: e);
      }
    } else {
      // 从旧格式迁移
      final legacyAudioStyleJson = _prefs.getString('audioSubtitleStyleLandscape');
      if (legacyAudioStyleJson != null) {
        try {
          final legacyStyle = SubtitleStyle.fromJson(json.decode(legacyAudioStyleJson));
          audioSubtitleTextStyle = legacyStyle.textStyle;
        } catch (e) {
          developer.log('Error migrating legacy audio subtitle style', error: e);
        }
      }
    }

    // 加载横屏布局样式
    final layoutLandJson = _prefs.getString('subtitleLayoutLandscape');
    if (layoutLandJson != null) {
      try {
        subtitleLayoutLandscape = SubtitleLayoutStyle.fromJson(json.decode(layoutLandJson));
      } catch (e) {
        developer.log('Error loading landscape layout style', error: e);
      }
    } else {
      // 从旧格式迁移
      final legacyStyleJson = _prefs.getString('subtitleStyleLandscape') ?? _prefs.getString('subtitleStyle');
      if (legacyStyleJson != null) {
        try {
          final legacyStyle = SubtitleStyle.fromJson(json.decode(legacyStyleJson));
          subtitleLayoutLandscape = legacyStyle.layoutStyle;
        } catch (e) {
          developer.log('Error migrating legacy landscape layout style', error: e);
        }
      }
    }

    // 加载竖屏布局样式
    final layoutPortJson = _prefs.getString('subtitleLayoutPortrait');
    if (layoutPortJson != null) {
      try {
        subtitleLayoutPortrait = SubtitleLayoutStyle.fromJson(json.decode(layoutPortJson));
      } catch (e) {
        developer.log('Error loading portrait layout style', error: e);
      }
    } else {
      // 从旧格式迁移
      final legacyStyleJson = _prefs.getString('subtitleStylePortrait');
      if (legacyStyleJson != null) {
        try {
          final legacyStyle = SubtitleStyle.fromJson(json.decode(legacyStyleJson));
          subtitleLayoutPortrait = legacyStyle.layoutStyle;
        } catch (e) {
          developer.log('Error migrating legacy portrait layout style', error: e);
        }
      } else {
        // 默认使用横屏布局
        subtitleLayoutPortrait = subtitleLayoutLandscape;
      }
    }

    // 加载音频横屏布局样式
    final audioLayoutLandJson = _prefs.getString('audioSubtitleLayoutLandscape');
    if (audioLayoutLandJson != null) {
      try {
        audioSubtitleLayoutLandscape = SubtitleLayoutStyle.fromJson(json.decode(audioLayoutLandJson));
      } catch (e) {
        developer.log('Error loading audio landscape layout style', error: e);
      }
    } else {
      // 从旧格式迁移
      final legacyStyleJson = _prefs.getString('audioSubtitleStyleLandscape');
      if (legacyStyleJson != null) {
        try {
          final legacyStyle = SubtitleStyle.fromJson(json.decode(legacyStyleJson));
          audioSubtitleLayoutLandscape = legacyStyle.layoutStyle;
        } catch (e) {
          developer.log('Error migrating legacy audio landscape layout style', error: e);
        }
      }
    }

    // 加载音频竖屏布局样式
    final audioLayoutPortJson = _prefs.getString('audioSubtitleLayoutPortrait');
    if (audioLayoutPortJson != null) {
      try {
        audioSubtitleLayoutPortrait = SubtitleLayoutStyle.fromJson(json.decode(audioLayoutPortJson));
      } catch (e) {
        developer.log('Error loading audio portrait layout style', error: e);
      }
    } else {
      // 从旧格式迁移
      final legacyStyleJson = _prefs.getString('audioSubtitleStylePortrait');
      if (legacyStyleJson != null) {
        try {
          final legacyStyle = SubtitleStyle.fromJson(json.decode(legacyStyleJson));
          audioSubtitleLayoutPortrait = legacyStyle.layoutStyle;
        } catch (e) {
          developer.log('Error migrating legacy audio portrait layout style', error: e);
        }
      } else {
        // 默认使用音频横屏布局
        audioSubtitleLayoutPortrait = audioSubtitleLayoutLandscape;
      }
    }

    // 加载幽灵字幕设置
    if (_prefs.containsKey('ghostSubtitleFontSize')) {
      ghostSubtitleFontSize = _prefs.getDouble('ghostSubtitleFontSize') ?? subtitleLayoutLandscape.fontSize;
    } else {
      ghostSubtitleFontSize = subtitleLayoutLandscape.fontSize;
    }

    if (_prefs.containsKey('ghostSubtitleLetterSpacing')) {
      ghostSubtitleLetterSpacing = _prefs.getDouble('ghostSubtitleLetterSpacing') ?? 0.0;
    } else {
      ghostSubtitleLetterSpacing = 0.0;
    }
  }

  Future<void> updateSetting<T>(String key, T value) async {
    if (value is bool) {
      await _prefs.setBool(key, value);
    } else if (value is double) {
      await _prefs.setDouble(key, value);
    } else if (value is int) {
      await _prefs.setInt(key, value);
    } else if (value is String) {
      await _prefs.setString(key, value);
    }

    // Update local state reflection (simplified mapping)
    switch (key) {
      case 'showSubtitles': showSubtitles = value as bool; break;
      case 'isMirroredH': isMirroredH = value as bool; break;
      case 'isMirroredV': isMirroredV = value as bool; break;
      case 'playbackSpeed': playbackSpeed = value as double; break;
      case 'longPressSpeed': longPressSpeed = value as double; break;
      case 'doubleTapSeekSeconds': doubleTapSeekSeconds = value as int; break;
      case 'enableDoubleTapSubtitleSeek': enableDoubleTapSubtitleSeek = value as bool; break;
      case 'userSubtitleSidebarWidth': userSubtitleSidebarWidth = value as double; break;
      case 'autoCacheSubtitles': autoCacheSubtitles = value as bool; break;
      case 'autoScrollSubtitles': autoScrollSubtitles = value as bool; break;
      case 'autoLoadEmbeddedSubtitles': autoLoadEmbeddedSubtitles = value as bool; break;
      case 'splitSubtitleByLine': splitSubtitleByLine = value as bool; break;
      case 'videoContinuousSubtitle': videoContinuousSubtitle = value as bool; break;
      case 'audioContinuousSubtitle': audioContinuousSubtitle = value as bool; break;
      case 'autoPauseOnExit': autoPauseOnExit = value as bool; break;
      case 'autoPlayNextVideo': autoPlayNextVideo = value as bool; break;
      case 'isActionButtonsCollapsed': isActionButtonsCollapsed = value as bool; break;
      case 'enableSeekPreview': enableSeekPreview = value as bool; break;
      case 'homeGridCrossAxisCount': homeGridCrossAxisCount = (value as int).clamp(1, 10); break;
      case 'homeCardTitleFontSize': homeCardTitleFontSize = value as double; break;
      case 'homeCardAspectRatio': homeCardAspectRatio = value as double; break;

      case 'videoCardCrossAxisCount': videoCardCrossAxisCount = (value as int).clamp(1, 10); break;
      case 'videoCardTitleFontSize': videoCardTitleFontSize = value as double; break;
      case 'videoCardAspectRatio': videoCardAspectRatio = value as double; break;
      case 'landscapeSidebarFontSizeScale': landscapeSidebarFontSizeScale = value as double; break;
      case 'portraitSidebarFontSizeScale': portraitSidebarFontSizeScale = value as double; break;
      case 'subtitleViewMode': subtitleViewMode = value as int; break;
      case 'lastSelectedModelType': lastSelectedModelType = value as String; break;
      case 'isGhostModeEnabled': isGhostModeEnabled = value as bool; break;
      case 'ghostSubtitleFontSize': ghostSubtitleFontSize = value as double; break;
      case 'ghostSubtitleLetterSpacing': ghostSubtitleLetterSpacing = value as double; break;
      case 'subtitleOffset':
         subtitleOffset = Duration(milliseconds: value as int);
         break;
    }
    notifyListeners();
  }

  // ========== 新的字幕样式保存方法 ==========

  /// 保存视频字幕文字样式 - 同步到横竖屏
  Future<void> saveSubtitleTextStyle(SubtitleTextStyle style) async {
    subtitleTextStyle = style;
    notifyListeners();
    await _prefs.setString('subtitleTextStyle', json.encode(style.toJson()));
    // 同时更新旧格式以保持兼容
    await _prefs.setString('subtitleStyleLandscape', json.encode(subtitleStyleLandscape.toJson()));
    await _prefs.setString('subtitleStylePortrait', json.encode(subtitleStylePortrait.toJson()));
    await _prefs.setString('subtitleStyle', json.encode(subtitleStyleLandscape.toJson()));
  }

  /// 保存音频字幕文字样式 - 同步到横竖屏
  Future<void> saveAudioSubtitleTextStyle(SubtitleTextStyle style) async {
    audioSubtitleTextStyle = style;
    notifyListeners();
    await _prefs.setString('audioSubtitleTextStyle', json.encode(style.toJson()));
    // 同时更新旧格式以保持兼容
    await _prefs.setString('audioSubtitleStyleLandscape', json.encode(audioSubtitleStyleLandscape.toJson()));
    await _prefs.setString('audioSubtitleStylePortrait', json.encode(audioSubtitleStylePortrait.toJson()));
  }

  /// 保存横屏布局样式
  Future<void> saveSubtitleLayoutLandscape(SubtitleLayoutStyle style) async {
    subtitleLayoutLandscape = style;
    notifyListeners();
    await _prefs.setString('subtitleLayoutLandscape', json.encode(style.toJson()));
    // 同时更新旧格式以保持兼容
    await _prefs.setString('subtitleStyleLandscape', json.encode(subtitleStyleLandscape.toJson()));
    await _prefs.setString('subtitleStyle', json.encode(subtitleStyleLandscape.toJson()));
  }

  /// 保存竖屏布局样式
  Future<void> saveSubtitleLayoutPortrait(SubtitleLayoutStyle style) async {
    subtitleLayoutPortrait = style;
    notifyListeners();
    await _prefs.setString('subtitleLayoutPortrait', json.encode(style.toJson()));
    // 同时更新旧格式以保持兼容
    await _prefs.setString('subtitleStylePortrait', json.encode(subtitleStylePortrait.toJson()));
  }

  /// 保存音频横屏布局样式
  Future<void> saveAudioSubtitleLayoutLandscape(SubtitleLayoutStyle style) async {
    audioSubtitleLayoutLandscape = style;
    notifyListeners();
    await _prefs.setString('audioSubtitleLayoutLandscape', json.encode(style.toJson()));
    // 同时更新旧格式以保持兼容
    await _prefs.setString('audioSubtitleStyleLandscape', json.encode(audioSubtitleStyleLandscape.toJson()));
  }

  /// 保存音频竖屏布局样式
  Future<void> saveAudioSubtitleLayoutPortrait(SubtitleLayoutStyle style) async {
    audioSubtitleLayoutPortrait = style;
    notifyListeners();
    await _prefs.setString('audioSubtitleLayoutPortrait', json.encode(style.toJson()));
    // 同时更新旧格式以保持兼容
    await _prefs.setString('audioSubtitleStylePortrait', json.encode(audioSubtitleStylePortrait.toJson()));
  }

  // ========== 向后兼容的旧方法 ==========

  // Legacy saver (maps to landscape)
  Future<void> saveSubtitleStyle(SubtitleStyle style) async {
    await saveSubtitleStyleLandscape(style);
  }

  Future<void> saveSubtitleStyleLandscape(SubtitleStyle style) async {
    subtitleTextStyle = style.textStyle;
    subtitleLayoutLandscape = style.layoutStyle;
    notifyListeners();
    await _prefs.setString('subtitleTextStyle', json.encode(style.textStyle.toJson()));
    await _prefs.setString('subtitleLayoutLandscape', json.encode(style.layoutStyle.toJson()));
    await _prefs.setString('subtitleStyleLandscape', json.encode(style.toJson()));
    await _prefs.setString('subtitleStyle', json.encode(style.toJson()));
  }

  Future<void> saveSubtitleStylePortrait(SubtitleStyle style) async {
    // 注意：这里只更新布局样式，文字样式保持共享
    subtitleLayoutPortrait = style.layoutStyle;
    notifyListeners();
    await _prefs.setString('subtitleLayoutPortrait', json.encode(style.layoutStyle.toJson()));
    await _prefs.setString('subtitleStylePortrait', json.encode(subtitleStylePortrait.toJson()));
  }

  // Audio Subtitle Style Savers
  Future<void> saveAudioSubtitleStyleLandscape(SubtitleStyle style) async {
    audioSubtitleTextStyle = style.textStyle;
    audioSubtitleLayoutLandscape = style.layoutStyle;
    notifyListeners();
    await _prefs.setString('audioSubtitleTextStyle', json.encode(style.textStyle.toJson()));
    await _prefs.setString('audioSubtitleLayoutLandscape', json.encode(style.layoutStyle.toJson()));
    await _prefs.setString('audioSubtitleStyleLandscape', json.encode(style.toJson()));
  }

  Future<void> saveAudioSubtitleStylePortrait(SubtitleStyle style) async {
    // 注意：这里只更新布局样式，文字样式保持共享
    audioSubtitleLayoutPortrait = style.layoutStyle;
    notifyListeners();
    await _prefs.setString('audioSubtitleLayoutPortrait', json.encode(style.layoutStyle.toJson()));
    await _prefs.setString('audioSubtitleStylePortrait', json.encode(audioSubtitleStylePortrait.toJson()));
  }

  Future<void> saveSubtitleAlignment(Alignment align) async {
    subtitleAlignment = align;
    await _prefs.setDouble('subtitleAlignX', align.x);
    await _prefs.setDouble('subtitleAlignY', align.y);
    notifyListeners();
  }

  Future<void> saveGhostModeAlignment(Alignment align) async {
    ghostModeAlignment = align;
    await _prefs.setDouble('ghostModeAlignX', align.x);
    await _prefs.setDouble('ghostModeAlignY', align.y);
    notifyListeners();
  }

  Future<void> saveSubtitlePresets(List<Map<String, double>> presets) async {
    subtitlePresets = presets;
    await _prefs.setString('subtitlePresets', json.encode(presets));
    notifyListeners();
  }
}
