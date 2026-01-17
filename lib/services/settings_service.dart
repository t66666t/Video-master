import 'dart:convert';
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
  bool isHardwareDecoding = true;
  double playbackSpeed = 1.0;
  double longPressSpeed = 2.0;
  int doubleTapSeekSeconds = 5;
  bool enableDoubleTapSubtitleSeek = true;
  double userSubtitleSidebarWidth = 320.0;
  
  // Subtitle Settings
  SubtitleStyle subtitleStyleLandscape = const SubtitleStyle(); // Default for landscape
  SubtitleStyle subtitleStylePortrait = const SubtitleStyle(); // Default for portrait
  
  // Audio Subtitle Settings (separate from video)
  SubtitleStyle audioSubtitleStyleLandscape = const SubtitleStyle(); // Default for audio landscape
  SubtitleStyle audioSubtitleStylePortrait = const SubtitleStyle(); // Default for audio portrait
  
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
    isHardwareDecoding = _prefs.getBool('isHardwareDecoding') ?? true;
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

    final styleJson = _prefs.getString('subtitleStyle');
    if (styleJson != null) {
      try {
        subtitleStyleLandscape = SubtitleStyle.fromJson(json.decode(styleJson));
      } catch (e) {
        print("Error loading subtitle style: $e");
      }
    }
    
    // Load Landscape Style (if exists, overrides legacy)
    final styleLandJson = _prefs.getString('subtitleStyleLandscape');
    if (styleLandJson != null) {
      try {
        subtitleStyleLandscape = SubtitleStyle.fromJson(json.decode(styleLandJson));
      } catch (e) {
         print("Error loading landscape subtitle style: $e");
      }
    }

    // Load Portrait Style
    final stylePortJson = _prefs.getString('subtitleStylePortrait');
    if (stylePortJson != null) {
      try {
        subtitleStylePortrait = SubtitleStyle.fromJson(json.decode(stylePortJson));
      } catch (e) {
         print("Error loading portrait subtitle style: $e");
      }
    } else {
      // Fallback: Copy from Landscape (or legacy)
      subtitleStylePortrait = subtitleStyleLandscape;
    }

    // Load Audio Landscape Style
    final audioStyleLandJson = _prefs.getString('audioSubtitleStyleLandscape');
    if (audioStyleLandJson != null) {
      try {
        audioSubtitleStyleLandscape = SubtitleStyle.fromJson(json.decode(audioStyleLandJson));
      } catch (e) {
         print("Error loading audio landscape subtitle style: $e");
      }
    }

    // Load Audio Portrait Style
    final audioStylePortJson = _prefs.getString('audioSubtitleStylePortrait');
    if (audioStylePortJson != null) {
      try {
        audioSubtitleStylePortrait = SubtitleStyle.fromJson(json.decode(audioStylePortJson));
      } catch (e) {
         print("Error loading audio portrait subtitle style: $e");
      }
    } else {
      // Fallback: Copy from Audio Landscape
      audioSubtitleStylePortrait = audioSubtitleStyleLandscape;
    }

    final presetsJson = _prefs.getString('subtitlePresets');
    if (presetsJson != null) {
      try {
        final List<dynamic> decoded = json.decode(presetsJson);
        subtitlePresets = decoded.map((e) => Map<String, double>.from(e)).toList();
      } catch (e) {
        print("Error loading presets: $e");
      }
    }
    
    _initialized = true;
    notifyListeners();
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
      case 'isHardwareDecoding': isHardwareDecoding = value as bool; break;
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
      case 'subtitleOffset': 
         subtitleOffset = Duration(milliseconds: value as int); 
         break;
    }
    notifyListeners();
  }

  // Legacy saver (maps to landscape)
  Future<void> saveSubtitleStyle(SubtitleStyle style) async {
    await saveSubtitleStyleLandscape(style);
  }

  Future<void> saveSubtitleStyleLandscape(SubtitleStyle style) async {
    subtitleStyleLandscape = style;
    notifyListeners(); // Notify immediately for UI responsiveness
    await _prefs.setString('subtitleStyleLandscape', json.encode(style.toJson()));
    await _prefs.setString('subtitleStyle', json.encode(style.toJson())); 
  }

  Future<void> saveSubtitleStylePortrait(SubtitleStyle style) async {
    subtitleStylePortrait = style;
    notifyListeners(); // Notify immediately
    await _prefs.setString('subtitleStylePortrait', json.encode(style.toJson()));
  }

  // Audio Subtitle Style Savers
  Future<void> saveAudioSubtitleStyleLandscape(SubtitleStyle style) async {
    audioSubtitleStyleLandscape = style;
    notifyListeners(); // Notify immediately for UI responsiveness
    await _prefs.setString('audioSubtitleStyleLandscape', json.encode(style.toJson()));
  }

  Future<void> saveAudioSubtitleStylePortrait(SubtitleStyle style) async {
    audioSubtitleStylePortrait = style;
    notifyListeners(); // Notify immediately
    await _prefs.setString('audioSubtitleStylePortrait', json.encode(style.toJson()));
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
