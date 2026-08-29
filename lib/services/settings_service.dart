import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../models/subtitle_style.dart';
import '../models/subtitle_output_path_strategy.dart';
import '../models/danmaku_style.dart';
import '../models/video_compose_models.dart';
import '../utils/device_form_factor.dart';
import '../utils/subtitle_file_matcher.dart';

enum PlaybackSpeedLockAction { locked, switched, unlocked }

class _RegisteredSetting<T> {
  final String key;
  final T defaultValue;
  final T Function(SharedPreferences prefs, String key, T defaultValue) read;
  final Future<void> Function(SharedPreferences prefs, String key, T value)
  write;
  final T Function(T value) normalize;
  final void Function(SettingsService service, T value) apply;

  const _RegisteredSetting({
    required this.key,
    required this.defaultValue,
    required this.read,
    required this.write,
    required this.normalize,
    required this.apply,
  });

  Future<void> loadInto(
    SettingsService service,
    SharedPreferences prefs,
  ) async {
    final rawValue = read(prefs, key, defaultValue);
    final normalizedValue = normalize(rawValue);
    apply(service, normalizedValue);
    if (rawValue != normalizedValue) {
      await write(prefs, key, normalizedValue);
    }
  }

  Future<void> updateValue(
    SettingsService service,
    SharedPreferences prefs,
    Object value,
  ) {
    final normalizedValue = normalize(value as T);
    // Runtime consumers (including an already-running batch subtitle task)
    // must see the new value immediately. Persistence is deliberately the
    // second step; SharedPreferences I/O must not turn a UI change into a
    // delayed runtime change.
    apply(service, normalizedValue);
    return write(prefs, key, normalizedValue);
  }
}

class SettingsService extends ChangeNotifier {
  static final SettingsService _instance = SettingsService._internal();
  static const String _playbackSpeedLockStateKey = 'playbackSpeedLockStateV2';
  static const int _ghostLayoutCompatibilityVersion = 1;
  static const int _textMetricCompatibilityVersion = 1;
  static const String _ghostLayoutCompatibilityVersionKey =
      'ghostLayoutCompatibilityVersion';
  static const String _textMetricCompatibilityVersionKey =
      'subtitleTextMetricCompatibilityVersion';
  static const String _subtitleAlignmentJsonKey = 'subtitleAlignmentJson';
  static const String _audioSubtitleAlignmentJsonKey =
      'audioSubtitleAlignmentJson';
  static const String _ghostModeAlignmentJsonKey = 'ghostModeAlignmentJson';
  static const SubtitleLayoutStyle _legacyGhostLayout = SubtitleLayoutStyle(
    fontSize: 28.0,
    secondaryFontSize: 17.2,
    lineSpacing: -0.1,
    letterSpacing: 0.0,
  );
  factory SettingsService() => _instance;
  SettingsService._internal();

  late SharedPreferences _prefs;
  bool _initialized = false;
  bool _isPersistingSubtitleAlignment = false;
  bool _isPersistingAudioSubtitleAlignment = false;
  bool _isPersistingGhostModeAlignment = false;
  Alignment? _pendingSubtitleAlignmentPersist;
  Alignment? _pendingAudioSubtitleAlignmentPersist;
  Alignment? _pendingGhostModeAlignmentPersist;

  // Settings Fields
  bool showSubtitles = true;
  bool showBilibiliDanmaku = true;
  bool bilibiliDanmakuOnlyInVideoArea = false;
  double bilibiliDanmakuDisplayArea = 0.5;
  double bilibiliDanmakuOpacity = 0.8;
  double bilibiliDanmakuFontScale = 0.8;
  double bilibiliDanmakuSpeed = 1.0;
  String? bilibiliDanmakuFontFamily;
  int bilibiliDanmakuFontWeight = 600;
  DanmakuOutlineType bilibiliDanmakuOutlineType = DanmakuOutlineType.standard;
  bool isMirroredH = false;
  bool isMirroredV = false;
  double playbackSpeed = 1.0;
  bool isPlaybackSpeedLocked = false;
  bool globalMute = false;
  double longPressSpeed = 2.0;
  bool showLongPressSpeedIndicator = true;
  int doubleTapSeekSeconds = 5;
  bool enableDoubleTapSubtitleSeek = true;
  double userSubtitleSidebarWidth = 262.4;
  bool isLeftHandedMode = false;

  // Subtitle Settings - 新的结构
  // 文字样式 - 横竖屏共享
  SubtitleTextStyle subtitleTextStyle = const SubtitleTextStyle(
    fontFamilyChinese: 'Swei Gothic CJK SC',
    fontFamilyEnglish: 'Swei Gothic CJK SC',
    textColor: Color(0xFFFFFFFF),
    backgroundColor: Color(0xE0000000),
    hasBorder: true,
    borderColor: Color(0xFF000000),
    borderWidth: 2.5,
    hasShadow: true,
    shadowColor: Color(0xFF000000),
    shadowBlur: 2.8,
    shadowOffset: Offset(2.6, 2.6),
    backgroundOpacity: 0.88,
    fontWeightChinese: FontWeight.w600,
    fontWeightEnglish: FontWeight.w700,
    isItalic: false,
    isUnderline: false,
  );

  // 布局样式 - 横竖屏共享
  SubtitleLayoutStyle subtitleLayoutLandscape = const SubtitleLayoutStyle(
    fontSize: 39.7,
    secondaryFontSize: 22.6,
    lineSpacing: -0.1,
    letterSpacing: 0.0,
  );
  SubtitleLayoutStyle subtitleLayoutPortrait = const SubtitleLayoutStyle(
    fontSize: 39.7,
    secondaryFontSize: 22.6,
    lineSpacing: -0.1,
    letterSpacing: 0.0,
  );

  // 幽灵模式布局样式 - 与普通字幕完全独立（仅共享文字样式）
  SubtitleLayoutStyle subtitleLayoutGhostLandscape = const SubtitleLayoutStyle(
    fontSize: 39.7,
    secondaryFontSize: 22.6,
    lineSpacing: -0.1,
    letterSpacing: 0.0,
  );
  SubtitleLayoutStyle subtitleLayoutGhostPortrait = const SubtitleLayoutStyle(
    fontSize: 39.7,
    secondaryFontSize: 22.6,
    lineSpacing: -0.1,
    letterSpacing: 0.0,
  );

  // 音频字幕 - 同样结构
  bool syncAudioSubtitleStyleWithVideo = true;
  SubtitleTextStyle audioSubtitleTextStyle = const SubtitleTextStyle();
  SubtitleLayoutStyle audioSubtitleLayoutLandscape =
      const SubtitleLayoutStyle();
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

  // 便捷访问器 - 视频幽灵字幕完整样式（仅布局独立）
  SubtitleStyle get subtitleStyleGhostLandscape => SubtitleStyle(
    textStyle: subtitleTextStyle,
    layoutStyle: subtitleLayoutGhostLandscape,
  );
  SubtitleStyle get subtitleStyleGhostPortrait => SubtitleStyle(
    textStyle: subtitleTextStyle,
    layoutStyle: subtitleLayoutGhostPortrait,
  );

  // 便捷访问器 - 音频字幕完整样式
  SubtitleTextStyle get effectiveAudioSubtitleTextStyle =>
      syncAudioSubtitleStyleWithVideo
      ? subtitleTextStyle
      : audioSubtitleTextStyle;
  SubtitleStyle get audioSubtitleStyleLandscape => SubtitleStyle(
    textStyle: effectiveAudioSubtitleTextStyle,
    layoutStyle: audioSubtitleLayoutLandscape,
  );
  SubtitleStyle get audioSubtitleStylePortrait => SubtitleStyle(
    textStyle: effectiveAudioSubtitleTextStyle,
    layoutStyle: audioSubtitleLayoutPortrait,
  );

  // Backward compatibility getter/setter (maps to landscape for now)
  SubtitleStyle get subtitleStyle => subtitleStyleLandscape;

  Alignment subtitleAlignment = const Alignment(0.0, 0.8947589131115533);
  Alignment audioSubtitleAlignment = const Alignment(0.0, 0.8947589131115533);
  List<Map<String, double>> subtitlePresets = [];
  Duration subtitleOffset = Duration.zero;

  // New: Auto Cache Subtitles
  bool autoCacheSubtitles = true;

  // Desktop same-folder subtitle discovery. The default accepts exact names
  // and conventional metadata suffixes such as `.zh-CN` or ` [English]`, but
  // avoids broad matches such as `Movie2.srt` for `Movie.mkv`.
  SubtitlePrefixMatchMode desktopSubtitlePrefixMatchMode =
      SubtitlePrefixMatchMode.exactOrDelimited;
  bool desktopSubtitleScanCaseSensitive = false;

  // New: Auto Scroll Subtitles
  bool autoScrollSubtitles = true;
  bool subtitleEditorAutoFollow = true;

  // New: Auto Load Embedded Subtitles
  bool autoLoadEmbeddedSubtitles = false;

  // New: Grid Size Settings
  int homeGridCrossAxisCount = 4;
  int videoCardCrossAxisCount = 4;

  // New: Home Card Style
  double homeCardTitleFontSize = 13.0;
  double homeCardAspectRatio = 0.625;

  // New: Video Card Style
  double videoCardTitleFontSize = 11.0;
  double videoCardAspectRatio = 0.625;

  // Media manager unified view mode (0: grid, 1: list)
  int mediaLibraryViewMode = 0;

  // Unified list mode style settings
  int mediaListCrossAxisCount = 1;
  bool mediaListShowThumbnail = true;
  bool mediaListShowIndex = false;
  double mediaListItemHeightScale = 0.10;
  double mediaListMainSpacingScale = 0.012;
  double mediaListCrossSpacingScale = 0.02;
  double mediaListTitleScale = 0.042;
  double mediaListCoverOffset = 0.0;

  /// Whether newly imported media is copied into app-managed storage.
  ///
  /// This is intentionally opt-in. Import operations snapshot the value when
  /// they start so a multi-file import can never end up with mixed semantics.
  bool copyImportedMediaToPrivateStorage = false;
  String structuredImportSortField = 'fileName';
  String structuredImportSortDirection = 'ascending';

  // New: Subtitle Sidebar Font Scale (Landscape)
  double landscapeSidebarFontSizeScale = 1.0;

  // New: Subtitle Sidebar Font Scale (Portrait)
  double portraitSidebarFontSizeScale = 1.0;

  // Subtitle sidebar list timestamp layout (kept separate per orientation).
  bool landscapeSidebarShowTimestamps = true;
  bool portraitSidebarShowTimestamps = true;
  double landscapeSidebarTimeColumnRatio = 0.18;
  double portraitSidebarTimeColumnRatio = 0.12;

  // Subtitle sidebar locate alignment, as a percentage from the top.
  int landscapeSidebarLocatePositionPercent = 30;
  int portraitSidebarLocatePositionPercent = 30;

  // Global paragraph size used by the subtitle sidebar article view.
  int subtitleArticleSentencesPerParagraph = 4;

  // New: Subtitle Sidebar View Mode (0: List, 1: Article)
  int subtitleViewMode = 0;

  bool isLandscapeSubtitleSidebarVisible = true;

  // New: AI Model Selection
  String lastSelectedModelType = 'base';

  // New: Subtitle Ghost Mode
  bool isGhostModeEnabled = true;
  Alignment ghostModeAlignment = const Alignment(0.0, 0.8856727518593654);

  // 音乐播放器歌词字体缩放比例 - 竖屏（0.6 = 小，1.0 = 默认，1.4 = 大）
  double musicLyricFontSizeScalePortrait = 1.0;

  // 音乐播放器歌词字体缩放比例 - 横屏（0.6 = 小，1.0 = 默认，1.4 = 大）
  double musicLyricFontSizeScaleLandscape = 1.0;

  // New: Split Subtitle by Line
  bool splitSubtitleByLine = true;

  // New: Continuous Subtitle Display
  bool videoContinuousSubtitle = false;
  bool audioContinuousSubtitle = false;

  Alignment _readAlignmentPreference({
    required String jsonKey,
    required String legacyXKey,
    required String legacyYKey,
    required Alignment fallback,
  }) {
    final String? rawJson = _prefs.getString(jsonKey);
    if (rawJson != null && rawJson.isNotEmpty) {
      try {
        final Map<String, dynamic> decoded = Map<String, dynamic>.from(
          json.decode(rawJson),
        );
        return Alignment(
          (decoded['x'] as num?)?.toDouble() ?? fallback.x,
          (decoded['y'] as num?)?.toDouble() ?? fallback.y,
        );
      } catch (e) {
        developer.log('Error loading alignment preference', error: e);
      }
    }
    return Alignment(
      _prefs.getDouble(legacyXKey) ?? fallback.x,
      _prefs.getDouble(legacyYKey) ?? fallback.y,
    );
  }

  Future<void> _persistAlignmentPreference({
    required String jsonKey,
    required String legacyXKey,
    required String legacyYKey,
    required Alignment align,
  }) async {
    await _prefs.setString(jsonKey, json.encode({'x': align.x, 'y': align.y}));
    await _prefs.setDouble(legacyXKey, align.x);
    await _prefs.setDouble(legacyYKey, align.y);
  }

  Future<void> _drainSubtitleAlignmentPersistQueue() async {
    if (_isPersistingSubtitleAlignment) return;
    _isPersistingSubtitleAlignment = true;
    try {
      while (_pendingSubtitleAlignmentPersist != null) {
        final Alignment align = _pendingSubtitleAlignmentPersist!;
        _pendingSubtitleAlignmentPersist = null;
        await _persistAlignmentPreference(
          jsonKey: _subtitleAlignmentJsonKey,
          legacyXKey: 'subtitleAlignX',
          legacyYKey: 'subtitleAlignY',
          align: align,
        );
      }
    } finally {
      _isPersistingSubtitleAlignment = false;
    }
  }

  Future<void> _drainAudioSubtitleAlignmentPersistQueue() async {
    if (_isPersistingAudioSubtitleAlignment) return;
    _isPersistingAudioSubtitleAlignment = true;
    try {
      while (_pendingAudioSubtitleAlignmentPersist != null) {
        final Alignment align = _pendingAudioSubtitleAlignmentPersist!;
        _pendingAudioSubtitleAlignmentPersist = null;
        await _persistAlignmentPreference(
          jsonKey: _audioSubtitleAlignmentJsonKey,
          legacyXKey: 'audioSubtitleAlignX',
          legacyYKey: 'audioSubtitleAlignY',
          align: align,
        );
      }
    } finally {
      _isPersistingAudioSubtitleAlignment = false;
    }
  }

  Future<void> _drainGhostModeAlignmentPersistQueue() async {
    if (_isPersistingGhostModeAlignment) return;
    _isPersistingGhostModeAlignment = true;
    try {
      while (_pendingGhostModeAlignmentPersist != null) {
        final Alignment align = _pendingGhostModeAlignmentPersist!;
        _pendingGhostModeAlignmentPersist = null;
        await _persistAlignmentPreference(
          jsonKey: _ghostModeAlignmentJsonKey,
          legacyXKey: 'ghostModeAlignX',
          legacyYKey: 'ghostModeAlignY',
          align: align,
        );
      }
    } finally {
      _isPersistingGhostModeAlignment = false;
    }
  }

  // New: Auto Pause on Exit
  bool autoPauseOnExit = true;

  // Skip the portrait player on mobile and open the landscape player
  // directly. Tablets default to on, phones to off; desktop always skips
  // regardless of this flag.
  bool skipPortraitPlayer = false;

  // Keep the complete primary/secondary subtitle group clear of visible
  // playback controls. Enabled by default on every platform.
  bool avoidPlaybackControlsWithSubtitles = true;

  // New: Pause playback when app goes to background on mobile.
  bool pausePlaybackWhenAppBackgrounded = true;

  // New: Allow concurrent playback with other apps.
  bool allowConcurrentPlayback = false;

  // Prefer the native platform's hardware video decoder. This controls
  // libmpv's `hwdec` option; GPU texture composition remains enabled in both
  // modes because CPU-rendering a Flutter video texture is prohibitively
  // expensive for high-resolution media.
  bool useHardwareVideoDecoding = true;

  // New: Enable wired/Bluetooth headset and system media controls.
  bool enableHeadsetMediaControls = true;

  // New: Auto Play Next Video
  bool autoPlayNextVideo = true;

  // 预加载下一个视频控制器（进度达 80% 时后台 initialize，切换时热替换）
  // 低端设备可关闭以减少内存占用
  bool enableVideoPreload = true;

  // New: Auto continue playback when current media completes.
  bool autoPlayOnCompletion = false;

  // New: When auto continuing, always restart the target media from zero.
  bool autoPlayOnCompletionFromStart = false;

  // New: Action Buttons Collapsed State
  bool isActionButtonsCollapsed = false;

  String? largeDataRootPath;

  // New: Window Management
  bool isFullScreen = false;

  // New: Seek Preview
  bool enableSeekPreview = true;

  // App-wide haptic feedback. Only surfaced on Android and iOS.
  bool enableHapticFeedback = true;

  // New: Suppress Bilibili Restricted Dialog
  bool suppressBilibiliRestrictedDialog = false;

  int videoComposeResolutionHeight = 1080;
  String videoComposeRenderMode = VideoComposeRenderMode.precise.storageValue;
  bool videoComposeContinuousSubtitle = false;
  bool videoComposeRenderSecondary = true;
  bool videoComposeEmbedSoftSubtitles = false;
  bool videoComposeSoftSubtitleOnly = false;
  bool videoComposeSoftSubtitleUseSourceQuality = true;
  bool videoComposeDeleteOutputOnTaskDelete = true;
  String? videoComposePrimarySubtitlePath;
  String? videoComposeSecondarySubtitlePath;
  String? videoComposeCustomOutputPath;

  String portraitCustomAspectDraftWidthText = '';
  String portraitCustomAspectDraftHeightText = '';

  bool batchSubtitleAutoDelete = false;
  SubtitleOutputPathStrategy batchSubtitleOutputPathStrategy =
      SubtitleOutputPathStrategy.sameAsVideo;
  String? batchSubtitleCustomOutputDir;

  // 外部视频内嵌软字幕设置
  bool batchSubtitleEmbedSoftCopyAndEmbed = false;
  bool batchSubtitleEmbedSoftDeleteOriginal = false;
  bool batchSubtitleEmbedSoftPrefixEnabled = false;
  String batchSubtitleEmbedSoftPrefix = '[AI字幕]';
  bool batchSubtitleEmbedSoftSuffixEnabled = false;
  String batchSubtitleEmbedSoftSuffix = '';
  bool batchSubtitleEmbedAutoDeleteSrt = false;

  // 全局音频竖屏播放页显示比例（null = 默认 1:1）
  // 音频比例是全局共享的，设置一次应用到所有音频
  double? audioPortraitDisplayAspectRatio;
  double? audioPortraitCustomAspectWidth;
  double? audioPortraitCustomAspectHeight;

  late final List<_RegisteredSetting<dynamic>> _registeredSettings =
      _createRegisteredSettings();
  late final Map<String, _RegisteredSetting<dynamic>> _registeredSettingByKey =
      {for (final setting in _registeredSettings) setting.key: setting};

  _RegisteredSetting<bool> _boolSetting({
    required String key,
    required bool defaultValue,
    required void Function(SettingsService service, bool value) apply,
    bool Function(bool value)? normalize,
  }) {
    return _RegisteredSetting<bool>(
      key: key,
      defaultValue: defaultValue,
      read: (prefs, settingKey, fallback) =>
          prefs.getBool(settingKey) ?? fallback,
      write: (prefs, settingKey, value) => prefs.setBool(settingKey, value),
      normalize: normalize ?? (value) => value,
      apply: apply,
    );
  }

  _RegisteredSetting<int> _intSetting({
    required String key,
    required int defaultValue,
    required void Function(SettingsService service, int value) apply,
    int Function(int value)? normalize,
  }) {
    return _RegisteredSetting<int>(
      key: key,
      defaultValue: defaultValue,
      read: (prefs, settingKey, fallback) =>
          prefs.getInt(settingKey) ?? fallback,
      write: (prefs, settingKey, value) => prefs.setInt(settingKey, value),
      normalize: normalize ?? (value) => value,
      apply: apply,
    );
  }

  _RegisteredSetting<double> _doubleSetting({
    required String key,
    required double defaultValue,
    required void Function(SettingsService service, double value) apply,
    double Function(double value)? normalize,
  }) {
    return _RegisteredSetting<double>(
      key: key,
      defaultValue: defaultValue,
      read: (prefs, settingKey, fallback) =>
          prefs.getDouble(settingKey) ?? fallback,
      write: (prefs, settingKey, value) => prefs.setDouble(settingKey, value),
      normalize: normalize ?? (value) => value,
      apply: apply,
    );
  }

  _RegisteredSetting<String> _stringSetting({
    required String key,
    required String defaultValue,
    required void Function(SettingsService service, String value) apply,
    String Function(String value)? normalize,
  }) {
    return _RegisteredSetting<String>(
      key: key,
      defaultValue: defaultValue,
      read: (prefs, settingKey, fallback) =>
          prefs.getString(settingKey) ?? fallback,
      write: (prefs, settingKey, value) => prefs.setString(settingKey, value),
      normalize: normalize ?? (value) => value,
      apply: apply,
    );
  }

  List<_RegisteredSetting<dynamic>> _createRegisteredSettings() {
    return <_RegisteredSetting<dynamic>>[
      _boolSetting(
        key: 'showSubtitles',
        defaultValue: true,
        apply: (service, value) => service.showSubtitles = value,
      ),
      _boolSetting(
        key: 'showBilibiliDanmaku',
        defaultValue: true,
        apply: (service, value) => service.showBilibiliDanmaku = value,
      ),
      _boolSetting(
        key: 'bilibiliDanmakuOnlyInVideoArea',
        defaultValue: false,
        apply: (service, value) =>
            service.bilibiliDanmakuOnlyInVideoArea = value,
      ),
      _doubleSetting(
        key: 'bilibiliDanmakuDisplayArea',
        defaultValue: 0.5,
        normalize: (value) => value
            .clamp(kDanmakuDisplayAreaMin, kDanmakuDisplayAreaMax)
            .toDouble(),
        apply: (service, value) => service.bilibiliDanmakuDisplayArea = value,
      ),
      _doubleSetting(
        key: 'bilibiliDanmakuOpacity',
        defaultValue: 0.8,
        normalize: (value) => value.clamp(0.1, 1.0).toDouble(),
        apply: (service, value) => service.bilibiliDanmakuOpacity = value,
      ),
      _doubleSetting(
        key: 'bilibiliDanmakuFontScale',
        defaultValue: 0.8,
        normalize: (value) =>
            value.clamp(kDanmakuFontScaleMin, kDanmakuFontScaleMax).toDouble(),
        apply: (service, value) => service.bilibiliDanmakuFontScale = value,
      ),
      _doubleSetting(
        key: 'bilibiliDanmakuSpeed',
        defaultValue: 1.0,
        normalize: (value) =>
            value.clamp(kDanmakuSpeedMin, kDanmakuSpeedMax).toDouble(),
        apply: (service, value) => service.bilibiliDanmakuSpeed = value,
      ),
      _stringSetting(
        key: 'bilibiliDanmakuFontFamily',
        defaultValue: '',
        normalize: (value) =>
            kDanmakuFontFamilies.contains(value.isEmpty ? null : value)
            ? value
            : '',
        apply: (service, value) =>
            service.bilibiliDanmakuFontFamily = value.isEmpty ? null : value,
      ),
      _intSetting(
        key: 'bilibiliDanmakuFontWeight',
        defaultValue: 600,
        normalize: (value) => ((value.clamp(100, 900) / 100).round() * 100),
        apply: (service, value) => service.bilibiliDanmakuFontWeight = value,
      ),
      _stringSetting(
        key: 'bilibiliDanmakuOutlineType',
        defaultValue: DanmakuOutlineType.standard.name,
        normalize: (value) => DanmakuOutlineTypeX.fromName(value).name,
        apply: (service, value) => service.bilibiliDanmakuOutlineType =
            DanmakuOutlineTypeX.fromName(value),
      ),
      _boolSetting(
        key: 'isMirroredH',
        defaultValue: false,
        apply: (service, value) => service.isMirroredH = value,
      ),
      _boolSetting(
        key: 'isMirroredV',
        defaultValue: false,
        apply: (service, value) => service.isMirroredV = value,
      ),
      _doubleSetting(
        key: 'playbackSpeed',
        defaultValue: 1.0,
        apply: (service, value) => service.playbackSpeed = value,
      ),
      _boolSetting(
        key: 'isPlaybackSpeedLocked',
        defaultValue: false,
        apply: (service, value) => service.isPlaybackSpeedLocked = value,
      ),
      _boolSetting(
        key: 'globalMute',
        defaultValue: false,
        apply: (service, value) => service.globalMute = value,
      ),
      _doubleSetting(
        key: 'longPressSpeed',
        defaultValue: 2.0,
        // mpv's pitch-preserving scaletempo2 path is defined for 0.25x-8x.
        // Keeping persisted/custom values inside that range guarantees that
        // playback never falls back to pitched resampling or muted audio.
        normalize: (value) => value.clamp(0.25, 8.0).toDouble(),
        apply: (service, value) => service.longPressSpeed = value,
      ),
      _boolSetting(
        key: 'showLongPressSpeedIndicator',
        defaultValue: true,
        apply: (service, value) => service.showLongPressSpeedIndicator = value,
      ),
      _intSetting(
        key: 'doubleTapSeekSeconds',
        defaultValue: 5,
        apply: (service, value) => service.doubleTapSeekSeconds = value,
      ),
      _boolSetting(
        key: 'enableDoubleTapSubtitleSeek',
        defaultValue: true,
        apply: (service, value) => service.enableDoubleTapSubtitleSeek = value,
      ),
      _doubleSetting(
        key: 'userSubtitleSidebarWidth',
        defaultValue: 262.4,
        apply: (service, value) => service.userSubtitleSidebarWidth = value,
      ),
      _boolSetting(
        key: 'isLeftHandedMode',
        defaultValue: false,
        apply: (service, value) => service.isLeftHandedMode = value,
      ),
      _boolSetting(
        key: 'autoCacheSubtitles',
        defaultValue: true,
        apply: (service, value) => service.autoCacheSubtitles = value,
      ),
      _stringSetting(
        key: 'desktopSubtitlePrefixMatchMode',
        defaultValue: SubtitlePrefixMatchMode.exactOrDelimited.name,
        normalize: (value) => SubtitlePrefixMatchMode.fromStorage(value).name,
        apply: (service, value) => service.desktopSubtitlePrefixMatchMode =
            SubtitlePrefixMatchMode.fromStorage(value),
      ),
      _boolSetting(
        key: 'desktopSubtitleScanCaseSensitive',
        defaultValue: false,
        apply: (service, value) =>
            service.desktopSubtitleScanCaseSensitive = value,
      ),
      _boolSetting(
        key: 'autoScrollSubtitles',
        defaultValue: true,
        apply: (service, value) => service.autoScrollSubtitles = value,
      ),
      _boolSetting(
        key: 'subtitleEditorAutoFollow',
        defaultValue: true,
        apply: (service, value) => service.subtitleEditorAutoFollow = value,
      ),
      _boolSetting(
        key: 'autoLoadEmbeddedSubtitles',
        defaultValue: false,
        apply: (service, value) => service.autoLoadEmbeddedSubtitles = value,
      ),
      _boolSetting(
        key: 'splitSubtitleByLine',
        defaultValue: true,
        apply: (service, value) => service.splitSubtitleByLine = value,
      ),
      _boolSetting(
        key: 'videoContinuousSubtitle',
        defaultValue: false,
        apply: (service, value) => service.videoContinuousSubtitle = value,
      ),
      _boolSetting(
        key: 'audioContinuousSubtitle',
        defaultValue: false,
        apply: (service, value) => service.audioContinuousSubtitle = value,
      ),
      _boolSetting(
        key: 'syncAudioSubtitleStyleWithVideo',
        defaultValue: true,
        apply: (service, value) =>
            service.syncAudioSubtitleStyleWithVideo = value,
      ),
      _boolSetting(
        key: 'autoPauseOnExit',
        defaultValue: true,
        apply: (service, value) => service.autoPauseOnExit = value,
      ),
      _boolSetting(
        key: 'skipPortraitPlayer',
        defaultValue:
            !kIsWeb &&
            (Platform.isAndroid || Platform.isIOS) &&
            DeviceFormFactor.isTabletLikeDevice(),
        apply: (service, value) => service.skipPortraitPlayer = value,
      ),
      _boolSetting(
        key: 'avoidPlaybackControlsWithSubtitles',
        defaultValue: true,
        apply: (service, value) =>
            service.avoidPlaybackControlsWithSubtitles = value,
      ),
      _boolSetting(
        key: 'pausePlaybackWhenAppBackgrounded',
        defaultValue: true,
        apply: (service, value) =>
            service.pausePlaybackWhenAppBackgrounded = value,
      ),
      _boolSetting(
        key: 'allowConcurrentPlayback',
        defaultValue: false,
        apply: (service, value) => service.allowConcurrentPlayback = value,
      ),
      _boolSetting(
        key: 'useHardwareVideoDecoding',
        defaultValue: true,
        apply: (service, value) => service.useHardwareVideoDecoding = value,
      ),
      _boolSetting(
        key: 'enableHeadsetMediaControls',
        defaultValue: true,
        apply: (service, value) => service.enableHeadsetMediaControls = value,
      ),
      _boolSetting(
        key: 'autoPlayNextVideo',
        defaultValue: true,
        apply: (service, value) => service.autoPlayNextVideo = value,
      ),
      _boolSetting(
        key: 'enableVideoPreload',
        defaultValue: true,
        apply: (service, value) => service.enableVideoPreload = value,
      ),
      _boolSetting(
        key: 'autoPlayOnCompletion',
        defaultValue: false,
        apply: (service, value) => service.autoPlayOnCompletion = value,
      ),
      _boolSetting(
        key: 'autoPlayOnCompletionFromStart',
        defaultValue: false,
        apply: (service, value) =>
            service.autoPlayOnCompletionFromStart = value,
      ),
      _boolSetting(
        key: 'isActionButtonsCollapsed',
        defaultValue: false,
        apply: (service, value) => service.isActionButtonsCollapsed = value,
      ),
      _boolSetting(
        key: 'enableSeekPreview',
        defaultValue: true,
        apply: (service, value) => service.enableSeekPreview = value,
      ),
      _boolSetting(
        key: 'enableHapticFeedback',
        defaultValue: true,
        apply: (service, value) => service.enableHapticFeedback = value,
      ),
      _boolSetting(
        key: 'suppressBilibiliRestrictedDialog',
        defaultValue: false,
        apply: (service, value) =>
            service.suppressBilibiliRestrictedDialog = value,
      ),
      _intSetting(
        key: 'videoComposeResolutionHeight',
        defaultValue: 1080,
        apply: (service, value) => service.videoComposeResolutionHeight = value,
      ),
      _stringSetting(
        key: 'videoComposeRenderMode',
        defaultValue: VideoComposeRenderMode.precise.storageValue,
        normalize: (value) => VideoComposeRenderMode.fromStorage(
          value,
          fallback: VideoComposeRenderMode.precise,
        ).storageValue,
        apply: (service, value) => service.videoComposeRenderMode = value,
      ),
      _boolSetting(
        key: 'videoComposeContinuousSubtitle',
        defaultValue: false,
        apply: (service, value) =>
            service.videoComposeContinuousSubtitle = value,
      ),
      _boolSetting(
        key: 'videoComposeRenderSecondary',
        defaultValue: true,
        apply: (service, value) => service.videoComposeRenderSecondary = value,
      ),
      _boolSetting(
        key: 'videoComposeEmbedSoftSubtitles',
        defaultValue: false,
        apply: (service, value) =>
            service.videoComposeEmbedSoftSubtitles = value,
      ),
      _boolSetting(
        key: 'videoComposeSoftSubtitleOnly',
        defaultValue: false,
        apply: (service, value) => service.videoComposeSoftSubtitleOnly = value,
      ),
      _boolSetting(
        key: 'videoComposeSoftSubtitleUseSourceQuality',
        defaultValue: true,
        apply: (service, value) =>
            service.videoComposeSoftSubtitleUseSourceQuality = value,
      ),
      _boolSetting(
        key: 'videoComposeDeleteOutputOnTaskDelete',
        defaultValue: true,
        apply: (service, value) =>
            service.videoComposeDeleteOutputOnTaskDelete = value,
      ),
      _intSetting(
        key: 'homeGridCrossAxisCount',
        defaultValue: 4,
        normalize: (value) => value.clamp(1, 15),
        apply: (service, value) => service.homeGridCrossAxisCount = value,
      ),
      _intSetting(
        key: 'videoCardCrossAxisCount',
        defaultValue: 4,
        normalize: (value) => value.clamp(1, 15),
        apply: (service, value) => service.videoCardCrossAxisCount = value,
      ),
      _doubleSetting(
        key: 'homeCardTitleFontSize',
        defaultValue: 13.0,
        apply: (service, value) => service.homeCardTitleFontSize = value,
      ),
      _doubleSetting(
        key: 'homeCardAspectRatio',
        defaultValue: 0.625,
        apply: (service, value) => service.homeCardAspectRatio = value,
      ),
      _doubleSetting(
        key: 'videoCardTitleFontSize',
        defaultValue: 11.0,
        apply: (service, value) => service.videoCardTitleFontSize = value,
      ),
      _doubleSetting(
        key: 'videoCardAspectRatio',
        defaultValue: 0.625,
        apply: (service, value) => service.videoCardAspectRatio = value,
      ),
      _intSetting(
        key: 'mediaLibraryViewMode',
        defaultValue: 0,
        normalize: (value) => value.clamp(0, 1),
        apply: (service, value) => service.mediaLibraryViewMode = value,
      ),
      _intSetting(
        key: 'mediaListCrossAxisCount',
        defaultValue: 1,
        normalize: (value) => value.clamp(1, 15),
        apply: (service, value) => service.mediaListCrossAxisCount = value,
      ),
      _boolSetting(
        key: 'mediaListShowThumbnail',
        defaultValue: true,
        apply: (service, value) => service.mediaListShowThumbnail = value,
      ),
      _boolSetting(
        key: 'mediaListShowIndex',
        defaultValue: false,
        apply: (service, value) => service.mediaListShowIndex = value,
      ),
      _doubleSetting(
        key: 'mediaListItemHeightScale',
        defaultValue: 0.10,
        normalize: (value) => value.clamp(0.001, 0.15),
        apply: (service, value) => service.mediaListItemHeightScale = value,
      ),
      _doubleSetting(
        key: 'mediaListMainSpacingScale',
        defaultValue: 0.012,
        normalize: (value) => value.clamp(0.0, 0.04),
        apply: (service, value) => service.mediaListMainSpacingScale = value,
      ),
      _doubleSetting(
        key: 'mediaListCrossSpacingScale',
        defaultValue: 0.02,
        normalize: (value) => value.clamp(0.0, 0.05),
        apply: (service, value) => service.mediaListCrossSpacingScale = value,
      ),
      _doubleSetting(
        key: 'mediaListTitleScale',
        defaultValue: 0.042,
        normalize: (value) => value.clamp(0.001, 0.065),
        apply: (service, value) => service.mediaListTitleScale = value,
      ),
      _doubleSetting(
        key: 'mediaListCoverOffset',
        defaultValue: 0.0,
        normalize: (value) => value.clamp(-1.0, 1.0),
        apply: (service, value) => service.mediaListCoverOffset = value,
      ),
      _boolSetting(
        key: 'copyImportedMediaToPrivateStorage',
        defaultValue: false,
        apply: (service, value) =>
            service.copyImportedMediaToPrivateStorage = value,
      ),
      _stringSetting(
        key: 'structuredImportSortField',
        defaultValue: 'fileName',
        normalize: (value) =>
            value == 'modifiedTime' ? 'modifiedTime' : 'fileName',
        apply: (service, value) => service.structuredImportSortField = value,
      ),
      _stringSetting(
        key: 'structuredImportSortDirection',
        defaultValue: 'ascending',
        normalize: (value) =>
            value == 'descending' ? 'descending' : 'ascending',
        apply: (service, value) =>
            service.structuredImportSortDirection = value,
      ),
      _doubleSetting(
        key: 'portraitSidebarFontSizeScale',
        defaultValue: 1.0,
        apply: (service, value) => service.portraitSidebarFontSizeScale = value,
      ),
      _boolSetting(
        key: 'landscapeSidebarShowTimestamps',
        defaultValue: true,
        apply: (service, value) =>
            service.landscapeSidebarShowTimestamps = value,
      ),
      _boolSetting(
        key: 'portraitSidebarShowTimestamps',
        defaultValue: true,
        apply: (service, value) =>
            service.portraitSidebarShowTimestamps = value,
      ),
      _doubleSetting(
        key: 'landscapeSidebarTimeColumnRatio',
        defaultValue: 0.18,
        normalize: (value) => value.clamp(0.05, 0.30).toDouble(),
        apply: (service, value) =>
            service.landscapeSidebarTimeColumnRatio = value,
      ),
      _doubleSetting(
        key: 'portraitSidebarTimeColumnRatio',
        defaultValue: 0.12,
        normalize: (value) => value.clamp(0.05, 0.30).toDouble(),
        apply: (service, value) =>
            service.portraitSidebarTimeColumnRatio = value,
      ),
      _intSetting(
        key: 'landscapeSidebarLocatePositionPercent',
        defaultValue: 30,
        normalize: (value) => value.clamp(0, 100),
        apply: (service, value) =>
            service.landscapeSidebarLocatePositionPercent = value,
      ),
      _intSetting(
        key: 'portraitSidebarLocatePositionPercent',
        defaultValue: 30,
        normalize: (value) => value.clamp(0, 100),
        apply: (service, value) =>
            service.portraitSidebarLocatePositionPercent = value,
      ),
      _intSetting(
        key: 'subtitleArticleSentencesPerParagraph',
        defaultValue: 4,
        normalize: (value) => value.clamp(1, 99),
        apply: (service, value) =>
            service.subtitleArticleSentencesPerParagraph = value,
      ),
      _intSetting(
        key: 'subtitleViewMode',
        defaultValue: 0,
        apply: (service, value) => service.subtitleViewMode = value,
      ),
      _stringSetting(
        key: 'lastSelectedModelType',
        defaultValue: 'base',
        apply: (service, value) => service.lastSelectedModelType = value,
      ),
      _boolSetting(
        key: 'landscapeSubtitleSidebarVisible',
        defaultValue: true,
        apply: (service, value) =>
            service.isLandscapeSubtitleSidebarVisible = value,
      ),
      _boolSetting(
        key: 'isGhostModeEnabled',
        defaultValue: true,
        apply: (service, value) => service.isGhostModeEnabled = value,
      ),
      _stringSetting(
        key: 'portraitCustomAspectDraftWidthText',
        defaultValue: '',
        apply: (service, value) =>
            service.portraitCustomAspectDraftWidthText = value,
      ),
      _stringSetting(
        key: 'portraitCustomAspectDraftHeightText',
        defaultValue: '',
        apply: (service, value) =>
            service.portraitCustomAspectDraftHeightText = value,
      ),
      // 音乐播放器歌词字体缩放比例 - 竖屏
      _doubleSetting(
        key: 'musicLyricFontSizeScalePortrait',
        defaultValue: 1.0,
        normalize: (value) => value.clamp(0.6, 1.4),
        apply: (service, value) =>
            service.musicLyricFontSizeScalePortrait = value,
      ),
      // 音乐播放器歌词字体缩放比例 - 横屏
      _doubleSetting(
        key: 'musicLyricFontSizeScaleLandscape',
        defaultValue: 1.0,
        normalize: (value) => value.clamp(0.6, 1.4),
        apply: (service, value) =>
            service.musicLyricFontSizeScaleLandscape = value,
      ),
      _boolSetting(
        key: 'batchSubtitleAutoDelete',
        defaultValue: false,
        apply: (service, value) => service.batchSubtitleAutoDelete = value,
      ),
      _stringSetting(
        key: 'batchSubtitleOutputPathStrategy',
        defaultValue: 'sameAsVideo',
        apply: (service, value) =>
            service.batchSubtitleOutputPathStrategy = value == 'customDirectory'
            ? SubtitleOutputPathStrategy.customDirectory
            : SubtitleOutputPathStrategy.sameAsVideo,
      ),
      _stringSetting(
        key: 'batchSubtitleCustomOutputDir',
        defaultValue: '',
        apply: (service, value) =>
            service.batchSubtitleCustomOutputDir = value.isEmpty ? null : value,
      ),
      // 外部视频内嵌软字幕设置
      _boolSetting(
        key: 'batchSubtitleEmbedSoftCopyAndEmbed',
        defaultValue: false,
        apply: (service, value) =>
            service.batchSubtitleEmbedSoftCopyAndEmbed = value,
      ),
      _boolSetting(
        key: 'batchSubtitleEmbedSoftDeleteOriginal',
        defaultValue: false,
        apply: (service, value) =>
            service.batchSubtitleEmbedSoftDeleteOriginal = value,
      ),
      _boolSetting(
        key: 'batchSubtitleEmbedSoftPrefixEnabled',
        defaultValue: false,
        apply: (service, value) =>
            service.batchSubtitleEmbedSoftPrefixEnabled = value,
      ),
      _stringSetting(
        key: 'batchSubtitleEmbedSoftPrefix',
        defaultValue: '[AI字幕]',
        apply: (service, value) => service.batchSubtitleEmbedSoftPrefix = value,
      ),
      _boolSetting(
        key: 'batchSubtitleEmbedSoftSuffixEnabled',
        defaultValue: false,
        apply: (service, value) =>
            service.batchSubtitleEmbedSoftSuffixEnabled = value,
      ),
      _stringSetting(
        key: 'batchSubtitleEmbedSoftSuffix',
        defaultValue: '',
        apply: (service, value) => service.batchSubtitleEmbedSoftSuffix = value,
      ),
      _boolSetting(
        key: 'batchSubtitleEmbedAutoDeleteSrt',
        defaultValue: false,
        apply: (service, value) =>
            service.batchSubtitleEmbedAutoDeleteSrt = value,
      ),
    ];
  }

  Future<void> _loadRegisteredSettings() async {
    for (final setting in _registeredSettings) {
      await setting.loadInto(this, _prefs);
    }
  }

  Future<bool> _updateRegisteredSetting<T>(
    String key,
    T value, {
    bool notify = true,
  }) async {
    final setting = _registeredSettingByKey[key];
    if (setting == null) {
      return false;
    }
    final persistence = setting.updateValue(this, _prefs, value as Object);
    if (notify) {
      notifyListeners();
    }
    await persistence;
    return true;
  }

  Future<void> _updateRegisteredSettingsAtomically(
    Map<String, Object> values,
  ) async {
    final persistence = <Future<void>>[];
    for (final entry in values.entries) {
      final setting = _registeredSettingByKey[entry.key];
      if (setting == null) {
        throw ArgumentError.value(entry.key, 'key', 'Unsupported setting key');
      }
      // updateValue applies synchronously and persists asynchronously, so all
      // related in-memory values become visible before the single notification.
      persistence.add(setting.updateValue(this, _prefs, entry.value));
    }
    notifyListeners();
    await Future.wait(persistence);
  }

  Future<void> toggleFullScreen() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      isFullScreen = !isFullScreen;
      await windowManager.setFullScreen(isFullScreen);
      if (isFullScreen) {
        await windowManager.focus();
      }
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

  /// 更新音乐播放器歌词字体大小缩放比例 - 竖屏
  Future<void> updateMusicLyricFontSizeScalePortrait(double value) async {
    await _updateRegisteredSetting('musicLyricFontSizeScalePortrait', value);
  }

  /// 更新音乐播放器歌词字体大小缩放比例 - 横屏
  Future<void> updateMusicLyricFontSizeScaleLandscape(double value) async {
    await _updateRegisteredSetting('musicLyricFontSizeScaleLandscape', value);
  }

  Future<void> updateBatchSubtitleAutoDelete(bool value) async {
    await _updateRegisteredSetting('batchSubtitleAutoDelete', value);
  }

  Future<void> updateBatchSubtitleOutputPathStrategy(
    SubtitleOutputPathStrategy strategy,
  ) async {
    await _updateRegisteredSetting(
      'batchSubtitleOutputPathStrategy',
      strategy == SubtitleOutputPathStrategy.customDirectory
          ? 'customDirectory'
          : 'sameAsVideo',
    );
  }

  Future<void> updateBatchSubtitleCustomOutputDir(String? dir) async {
    await _updateRegisteredSetting('batchSubtitleCustomOutputDir', dir ?? '');
  }

  /// Updates the path strategy and its directory as one runtime transaction.
  /// This prevents an active task from observing `customDirectory` paired with
  /// the previous directory while the two preference writes are in flight.
  Future<void> updateBatchSubtitleOutputLocation(
    SubtitleOutputPathStrategy strategy, {
    String? customOutputDir,
  }) async {
    await _updateRegisteredSettingsAtomically({
      'batchSubtitleOutputPathStrategy':
          strategy == SubtitleOutputPathStrategy.customDirectory
          ? 'customDirectory'
          : 'sameAsVideo',
      'batchSubtitleCustomOutputDir': customOutputDir ?? '',
    });
  }

  // 外部视频内嵌软字幕设置更新方法
  Future<void> updateBatchSubtitleEmbedSoftCopyAndEmbed(bool value) async {
    await updateBatchSubtitleEmbedMode(
      copyAndEmbed: value,
      deleteOriginal: value ? false : batchSubtitleEmbedSoftDeleteOriginal,
    );
  }

  Future<void> updateBatchSubtitleEmbedSoftDeleteOriginal(bool value) async {
    await updateBatchSubtitleEmbedMode(
      copyAndEmbed: value ? false : batchSubtitleEmbedSoftCopyAndEmbed,
      deleteOriginal: value,
    );
  }

  /// Applies the two mutually-exclusive embedding modes atomically so a
  /// running task never sees both destructive and non-destructive modes on.
  Future<void> updateBatchSubtitleEmbedMode({
    required bool copyAndEmbed,
    required bool deleteOriginal,
  }) async {
    if (copyAndEmbed && deleteOriginal) {
      throw ArgumentError(
        'Soft-subtitle embedding modes are mutually exclusive.',
      );
    }
    await _updateRegisteredSettingsAtomically({
      'batchSubtitleEmbedSoftCopyAndEmbed': copyAndEmbed,
      'batchSubtitleEmbedSoftDeleteOriginal': deleteOriginal,
    });
  }

  Future<void> updateBatchSubtitleEmbedSoftPrefixEnabled(bool value) async {
    await _updateRegisteredSetting(
      'batchSubtitleEmbedSoftPrefixEnabled',
      value,
    );
  }

  Future<void> updateBatchSubtitleEmbedSoftPrefix(String value) async {
    await _updateRegisteredSetting('batchSubtitleEmbedSoftPrefix', value);
  }

  Future<void> updateBatchSubtitleEmbedSoftSuffixEnabled(bool value) async {
    await _updateRegisteredSetting(
      'batchSubtitleEmbedSoftSuffixEnabled',
      value,
    );
  }

  Future<void> updateBatchSubtitleEmbedSoftSuffix(String value) async {
    await _updateRegisteredSetting('batchSubtitleEmbedSoftSuffix', value);
  }

  Future<void> updateBatchSubtitleEmbedAutoDeleteSrt(bool value) async {
    await _updateRegisteredSetting('batchSubtitleEmbedAutoDeleteSrt', value);
  }

  Future<void> init() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    await _loadRegisteredSettings();
    await _loadPlaybackSpeedLockState();

    largeDataRootPath = _prefs.getString('largeDataRootPath');
    final composePrimaryRaw = _prefs.getString(
      'videoComposePrimarySubtitlePath',
    );
    videoComposePrimarySubtitlePath =
        (composePrimaryRaw == null || composePrimaryRaw.isEmpty)
        ? null
        : composePrimaryRaw;
    final composeSecondaryRaw = _prefs.getString(
      'videoComposeSecondarySubtitlePath',
    );
    videoComposeSecondarySubtitlePath =
        (composeSecondaryRaw == null || composeSecondaryRaw.isEmpty)
        ? null
        : composeSecondaryRaw;
    final composeOutputRaw = _prefs.getString('videoComposeCustomOutputPath');
    videoComposeCustomOutputPath =
        (composeOutputRaw == null || composeOutputRaw.isEmpty)
        ? null
        : composeOutputRaw;

    // Migrate old 'sidebarFontSizeScale' to 'landscapeSidebarFontSizeScale' if present
    // Default 1.1 for Landscape
    landscapeSidebarFontSizeScale =
        _prefs.getDouble('landscapeSidebarFontSizeScale') ??
        _prefs.getDouble('sidebarFontSizeScale') ??
        1.0;
    ghostModeAlignment = _readAlignmentPreference(
      jsonKey: _ghostModeAlignmentJsonKey,
      legacyXKey: 'ghostModeAlignX',
      legacyYKey: 'ghostModeAlignY',
      fallback: const Alignment(0.0, 0.8856727518593654),
    );

    subtitleOffset = Duration(
      milliseconds: _prefs.getInt('subtitleOffset') ?? 0,
    );

    subtitleAlignment = _readAlignmentPreference(
      jsonKey: _subtitleAlignmentJsonKey,
      legacyXKey: 'subtitleAlignX',
      legacyYKey: 'subtitleAlignY',
      fallback: const Alignment(0.0, 0.8947589131115533),
    );

    audioSubtitleAlignment = _readAlignmentPreference(
      jsonKey: _audioSubtitleAlignmentJsonKey,
      legacyXKey: 'audioSubtitleAlignX',
      legacyYKey: 'audioSubtitleAlignY',
      fallback: subtitleAlignment,
    );

    // 加载字幕样式 - 新的结构
    await _loadSubtitleStyles();

    final presetsJson = _prefs.getString('subtitlePresets');
    if (presetsJson != null) {
      try {
        final List<dynamic> decoded = json.decode(presetsJson);
        subtitlePresets = decoded
            .map((e) => Map<String, double>.from(e))
            .toList();
      } catch (e) {
        developer.log('Error loading presets', error: e);
      }
    }

    // 加载全局音频竖屏比例设置
    final audioRatioRaw = _prefs.getDouble('audioPortraitDisplayAspectRatio');
    audioPortraitDisplayAspectRatio =
        (audioRatioRaw != null && audioRatioRaw.isFinite && audioRatioRaw > 0)
        ? audioRatioRaw
        : null;
    final audioWRaw = _prefs.getDouble('audioPortraitCustomAspectWidth');
    audioPortraitCustomAspectWidth =
        (audioWRaw != null && audioWRaw.isFinite && audioWRaw > 0)
        ? audioWRaw
        : null;
    final audioHRaw = _prefs.getDouble('audioPortraitCustomAspectHeight');
    audioPortraitCustomAspectHeight =
        (audioHRaw != null && audioHRaw.isFinite && audioHRaw > 0)
        ? audioHRaw
        : null;

    _initialized = true;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _initialized = false;
  }

  /// 加载字幕样式 - 支持新旧格式迁移
  Future<void> _loadSubtitleStyles() async {
    // 尝试加载新的文字样式格式
    final textStyleJson = _prefs.getString('subtitleTextStyle');
    if (textStyleJson != null) {
      try {
        subtitleTextStyle = SubtitleTextStyle.fromJson(
          json.decode(textStyleJson),
        );
      } catch (e) {
        developer.log('Error loading subtitle text style', error: e);
      }
    } else {
      // 从旧格式迁移
      final legacyStyleJson =
          _prefs.getString('subtitleStyleLandscape') ??
          _prefs.getString('subtitleStyle');
      if (legacyStyleJson != null) {
        try {
          final legacyStyle = SubtitleStyle.fromJson(
            json.decode(legacyStyleJson),
          );
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
        audioSubtitleTextStyle = SubtitleTextStyle.fromJson(
          json.decode(audioTextStyleJson),
        );
      } catch (e) {
        developer.log('Error loading audio subtitle text style', error: e);
      }
    } else {
      // 从旧格式迁移
      final legacyAudioStyleJson = _prefs.getString(
        'audioSubtitleStyleLandscape',
      );
      if (legacyAudioStyleJson != null) {
        try {
          final legacyStyle = SubtitleStyle.fromJson(
            json.decode(legacyAudioStyleJson),
          );
          audioSubtitleTextStyle = legacyStyle.textStyle;
        } catch (e) {
          developer.log(
            'Error migrating legacy audio subtitle style',
            error: e,
          );
        }
      }
    }

    // 加载横屏布局样式
    final layoutLandJson = _prefs.getString('subtitleLayoutLandscape');
    if (layoutLandJson != null) {
      try {
        subtitleLayoutLandscape = SubtitleLayoutStyle.fromJson(
          json.decode(layoutLandJson),
        );
      } catch (e) {
        developer.log('Error loading landscape layout style', error: e);
      }
    } else {
      // 从旧格式迁移
      final legacyStyleJson =
          _prefs.getString('subtitleStyleLandscape') ??
          _prefs.getString('subtitleStyle');
      if (legacyStyleJson != null) {
        try {
          final legacyStyle = SubtitleStyle.fromJson(
            json.decode(legacyStyleJson),
          );
          subtitleLayoutLandscape = legacyStyle.layoutStyle;
        } catch (e) {
          developer.log(
            'Error migrating legacy landscape layout style',
            error: e,
          );
        }
      }
    }

    // 加载竖屏布局样式
    final layoutPortJson = _prefs.getString('subtitleLayoutPortrait');
    if (layoutPortJson != null) {
      try {
        subtitleLayoutPortrait = SubtitleLayoutStyle.fromJson(
          json.decode(layoutPortJson),
        );
      } catch (e) {
        developer.log('Error loading portrait layout style', error: e);
      }
    } else {
      // 从旧格式迁移
      final legacyStyleJson = _prefs.getString('subtitleStylePortrait');
      if (legacyStyleJson != null) {
        try {
          final legacyStyle = SubtitleStyle.fromJson(
            json.decode(legacyStyleJson),
          );
          subtitleLayoutPortrait = legacyStyle.layoutStyle;
        } catch (e) {
          developer.log(
            'Error migrating legacy portrait layout style',
            error: e,
          );
        }
      } else {
        // 默认使用横屏布局
        subtitleLayoutPortrait = subtitleLayoutLandscape;
      }
    }

    // 加载音频横屏布局样式
    final audioLayoutLandJson = _prefs.getString(
      'audioSubtitleLayoutLandscape',
    );
    if (audioLayoutLandJson != null) {
      try {
        audioSubtitleLayoutLandscape = SubtitleLayoutStyle.fromJson(
          json.decode(audioLayoutLandJson),
        );
      } catch (e) {
        developer.log('Error loading audio landscape layout style', error: e);
      }
    } else {
      // 从旧格式迁移
      final legacyStyleJson = _prefs.getString('audioSubtitleStyleLandscape');
      if (legacyStyleJson != null) {
        try {
          final legacyStyle = SubtitleStyle.fromJson(
            json.decode(legacyStyleJson),
          );
          audioSubtitleLayoutLandscape = legacyStyle.layoutStyle;
        } catch (e) {
          developer.log(
            'Error migrating legacy audio landscape layout style',
            error: e,
          );
        }
      }
    }

    // 加载音频竖屏布局样式
    final audioLayoutPortJson = _prefs.getString('audioSubtitleLayoutPortrait');
    if (audioLayoutPortJson != null) {
      try {
        audioSubtitleLayoutPortrait = SubtitleLayoutStyle.fromJson(
          json.decode(audioLayoutPortJson),
        );
      } catch (e) {
        developer.log('Error loading audio portrait layout style', error: e);
      }
    } else {
      // 从旧格式迁移
      final legacyStyleJson = _prefs.getString('audioSubtitleStylePortrait');
      if (legacyStyleJson != null) {
        try {
          final legacyStyle = SubtitleStyle.fromJson(
            json.decode(legacyStyleJson),
          );
          audioSubtitleLayoutPortrait = legacyStyle.layoutStyle;
        } catch (e) {
          developer.log(
            'Error migrating legacy audio portrait layout style',
            error: e,
          );
        }
      } else {
        // 默认使用音频横屏布局
        audioSubtitleLayoutPortrait = audioSubtitleLayoutLandscape;
      }
    }

    // 加载幽灵模式布局样式（与普通布局完全独立）
    final ghostLayoutLandJson = _prefs.getString(
      'subtitleLayoutGhostLandscape',
    );
    final ghostLayoutPortJson = _prefs.getString('subtitleLayoutGhostPortrait');
    if (ghostLayoutLandJson != null) {
      try {
        subtitleLayoutGhostLandscape = SubtitleLayoutStyle.fromJson(
          json.decode(ghostLayoutLandJson),
        );
      } catch (e) {
        developer.log('Error loading ghost landscape layout style', error: e);
      }
    }
    if (ghostLayoutPortJson != null) {
      try {
        subtitleLayoutGhostPortrait = SubtitleLayoutStyle.fromJson(
          json.decode(ghostLayoutPortJson),
        );
      } catch (e) {
        developer.log('Error loading ghost portrait layout style', error: e);
      }
    }

    // 旧版迁移：只有 ghostSubtitleFontSize / ghostSubtitleLetterSpacing（新版本改为完整布局样式）
    final bool hasGhostLayout =
        ghostLayoutLandJson != null || ghostLayoutPortJson != null;
    if (!hasGhostLayout &&
        (_prefs.containsKey('ghostSubtitleFontSize') ||
            _prefs.containsKey('ghostSubtitleLetterSpacing'))) {
      final oldFontSize =
          _prefs.getDouble('ghostSubtitleFontSize') ??
          subtitleLayoutLandscape.fontSize;
      final oldLetterSpacing =
          _prefs.getDouble('ghostSubtitleLetterSpacing') ?? 0.0;
      final base = subtitleLayoutLandscape;
      final baseSecondary = base.secondaryFontSize ?? base.fontSize;
      final fontScale = base.fontSize == 0
          ? 1.0
          : (oldFontSize / base.fontSize);
      final migrated = base.copyWith(
        fontSize: oldFontSize,
        secondaryFontSize: baseSecondary * fontScale,
        letterSpacing: oldLetterSpacing,
      );
      subtitleLayoutGhostLandscape = migrated;
      subtitleLayoutGhostPortrait = migrated;
      await _prefs.setString(
        'subtitleLayoutGhostLandscape',
        json.encode(migrated.toJson()),
      );
      await _prefs.setString(
        'subtitleLayoutGhostPortrait',
        json.encode(migrated.toJson()),
      );
    } else {
      if (ghostLayoutPortJson == null) {
        subtitleLayoutGhostPortrait = subtitleLayoutGhostLandscape;
      }
    }

    await _migrateLegacyGhostLayoutsIfNeeded();
    await _migrateLegacyTextMetricsIfNeeded();
    await _syncSubtitleLayouts();
    await _normalizeSubtitleStyleStorage();
  }

  bool _layoutStyleEquals(SubtitleLayoutStyle a, SubtitleLayoutStyle b) {
    return a.fontSize == b.fontSize &&
        a.secondaryFontSize == b.secondaryFontSize &&
        a.lineSpacing == b.lineSpacing &&
        a.letterSpacing == b.letterSpacing;
  }

  Future<void> _migrateLegacyGhostLayoutsIfNeeded() async {
    final int version = _prefs.getInt(_ghostLayoutCompatibilityVersionKey) ?? 0;
    if (version >= _ghostLayoutCompatibilityVersion) {
      return;
    }

    bool changed = false;
    if (_layoutStyleEquals(subtitleLayoutGhostLandscape, _legacyGhostLayout)) {
      subtitleLayoutGhostLandscape = subtitleLayoutLandscape;
      changed = true;
    }
    if (_layoutStyleEquals(subtitleLayoutGhostPortrait, _legacyGhostLayout)) {
      subtitleLayoutGhostPortrait = subtitleLayoutPortrait;
      changed = true;
    }

    if (changed) {
      await _prefs.setString(
        'subtitleLayoutGhostLandscape',
        json.encode(subtitleLayoutGhostLandscape.toJson()),
      );
      await _prefs.setString(
        'subtitleLayoutGhostPortrait',
        json.encode(subtitleLayoutGhostPortrait.toJson()),
      );
    }

    await _prefs.setInt(
      _ghostLayoutCompatibilityVersionKey,
      _ghostLayoutCompatibilityVersion,
    );
  }

  Future<void> _migrateLegacyTextMetricsIfNeeded() async {
    final int version = _prefs.getInt(_textMetricCompatibilityVersionKey) ?? 0;
    if (version >= _textMetricCompatibilityVersion) {
      return;
    }

    // If legacy absolute metrics were tuned for the old default font size,
    // normalize them to become font-size-relative.
    subtitleTextStyle = subtitleTextStyle.copyWith(
      borderWidth: subtitleTextStyle.normalizeBorderWidthForFontSize(
        subtitleTextStyle.borderWidth,
        kSubtitleTextMetricReferenceFontSize,
      ),
      shadowBlur: subtitleTextStyle.normalizeShadowBlurForFontSize(
        subtitleTextStyle.shadowBlur,
        kSubtitleTextMetricReferenceFontSize,
      ),
      shadowOffset: subtitleTextStyle.normalizeShadowOffsetForFontSize(
        subtitleTextStyle.shadowOffset,
        kSubtitleTextMetricReferenceFontSize,
      ),
    );
    audioSubtitleTextStyle = audioSubtitleTextStyle.copyWith(
      borderWidth: audioSubtitleTextStyle.normalizeBorderWidthForFontSize(
        audioSubtitleTextStyle.borderWidth,
        kSubtitleTextMetricReferenceFontSize,
      ),
      shadowBlur: audioSubtitleTextStyle.normalizeShadowBlurForFontSize(
        audioSubtitleTextStyle.shadowBlur,
        kSubtitleTextMetricReferenceFontSize,
      ),
      shadowOffset: audioSubtitleTextStyle.normalizeShadowOffsetForFontSize(
        audioSubtitleTextStyle.shadowOffset,
        kSubtitleTextMetricReferenceFontSize,
      ),
    );

    await _prefs.setString(
      'subtitleTextStyle',
      json.encode(subtitleTextStyle.toJson()),
    );
    await _prefs.setString(
      'audioSubtitleTextStyle',
      json.encode(audioSubtitleTextStyle.toJson()),
    );
    await _prefs.setInt(
      _textMetricCompatibilityVersionKey,
      _textMetricCompatibilityVersion,
    );
  }

  Future<void> _setStringIfChanged(String key, String value) async {
    if (_prefs.getString(key) == value) return;
    await _prefs.setString(key, value);
  }

  Future<void> _normalizeSubtitleStyleStorage() async {
    // 统一回写当前的共享文字样式和布局样式，确保升级后幽灵模式与普通模式
    // 除字号、行距、字距和位置外，其余视觉样式都指向同一份数据。
    await _setStringIfChanged(
      'subtitleTextStyle',
      json.encode(subtitleTextStyle.toJson()),
    );
    await _setStringIfChanged(
      'subtitleLayoutLandscape',
      json.encode(subtitleLayoutLandscape.toJson()),
    );
    await _setStringIfChanged(
      'subtitleLayoutPortrait',
      json.encode(subtitleLayoutPortrait.toJson()),
    );
    await _setStringIfChanged(
      'subtitleLayoutGhostLandscape',
      json.encode(subtitleLayoutGhostLandscape.toJson()),
    );
    await _setStringIfChanged(
      'subtitleLayoutGhostPortrait',
      json.encode(subtitleLayoutGhostPortrait.toJson()),
    );
    await _setStringIfChanged(
      'subtitleStyleLandscape',
      json.encode(subtitleStyleLandscape.toJson()),
    );
    await _setStringIfChanged(
      'subtitleStylePortrait',
      json.encode(subtitleStylePortrait.toJson()),
    );
    await _setStringIfChanged(
      'subtitleStyle',
      json.encode(subtitleStyleLandscape.toJson()),
    );
    await _setStringIfChanged(
      'audioSubtitleTextStyle',
      json.encode(audioSubtitleTextStyle.toJson()),
    );
    await _setStringIfChanged(
      'audioSubtitleLayoutLandscape',
      json.encode(audioSubtitleLayoutLandscape.toJson()),
    );
    await _setStringIfChanged(
      'audioSubtitleLayoutPortrait',
      json.encode(audioSubtitleLayoutPortrait.toJson()),
    );
    await _setStringIfChanged(
      'audioSubtitleStyleLandscape',
      json.encode(audioSubtitleStyleLandscape.toJson()),
    );
    await _setStringIfChanged(
      'audioSubtitleStylePortrait',
      json.encode(audioSubtitleStylePortrait.toJson()),
    );
    if (_prefs.getBool('syncAudioSubtitleStyleWithVideo') !=
        syncAudioSubtitleStyleWithVideo) {
      await _prefs.setBool(
        'syncAudioSubtitleStyleWithVideo',
        syncAudioSubtitleStyleWithVideo,
      );
    }

    // 清理旧版幽灵模式独立布局遗留键，避免后续再次触发旧迁移分支。
    if (_prefs.containsKey('ghostSubtitleFontSize')) {
      await _prefs.remove('ghostSubtitleFontSize');
    }
    if (_prefs.containsKey('ghostSubtitleLetterSpacing')) {
      await _prefs.remove('ghostSubtitleLetterSpacing');
    }
  }

  Future<void> _syncSubtitleLayouts() async {
    if (!_layoutStyleEquals(subtitleLayoutLandscape, subtitleLayoutPortrait)) {
      subtitleLayoutPortrait = subtitleLayoutLandscape;
      await _prefs.setString(
        'subtitleLayoutPortrait',
        json.encode(subtitleLayoutPortrait.toJson()),
      );
      await _prefs.setString(
        'subtitleStylePortrait',
        json.encode(subtitleStylePortrait.toJson()),
      );
    }

    if (!_layoutStyleEquals(
      subtitleLayoutGhostLandscape,
      subtitleLayoutGhostPortrait,
    )) {
      subtitleLayoutGhostPortrait = subtitleLayoutGhostLandscape;
      await _prefs.setString(
        'subtitleLayoutGhostPortrait',
        json.encode(subtitleLayoutGhostPortrait.toJson()),
      );
    }

    if (!_layoutStyleEquals(
      audioSubtitleLayoutLandscape,
      audioSubtitleLayoutPortrait,
    )) {
      audioSubtitleLayoutPortrait = audioSubtitleLayoutLandscape;
      await _prefs.setString(
        'audioSubtitleLayoutPortrait',
        json.encode(audioSubtitleLayoutPortrait.toJson()),
      );
      await _prefs.setString(
        'audioSubtitleStylePortrait',
        json.encode(audioSubtitleStylePortrait.toJson()),
      );
    }
  }

  Future<void> savePortraitCustomAspectDraftTexts({
    required String widthText,
    required String heightText,
    bool notify = false,
  }) async {
    if (portraitCustomAspectDraftWidthText == widthText &&
        portraitCustomAspectDraftHeightText == heightText) {
      return;
    }

    portraitCustomAspectDraftWidthText = widthText;
    portraitCustomAspectDraftHeightText = heightText;

    await Future.wait([
      _prefs.setString('portraitCustomAspectDraftWidthText', widthText),
      _prefs.setString('portraitCustomAspectDraftHeightText', heightText),
    ]);

    if (notify) {
      notifyListeners();
    }
  }

  /// 保存全局音频竖屏播放页显示比例。
  /// 音频比例是全局共享的，设置一次应用到所有音频媒体。
  Future<void> saveAudioPortraitDisplayAspectRatio(
    double? ratio, {
    double? customWidth,
    double? customHeight,
  }) async {
    audioPortraitDisplayAspectRatio = ratio;
    audioPortraitCustomAspectWidth = customWidth;
    audioPortraitCustomAspectHeight = customHeight;
    notifyListeners();

    if (ratio != null && ratio.isFinite && ratio > 0) {
      await _prefs.setDouble('audioPortraitDisplayAspectRatio', ratio);
    } else {
      await _prefs.remove('audioPortraitDisplayAspectRatio');
    }
    if (customWidth != null && customWidth.isFinite && customWidth > 0) {
      await _prefs.setDouble('audioPortraitCustomAspectWidth', customWidth);
    } else {
      await _prefs.remove('audioPortraitCustomAspectWidth');
    }
    if (customHeight != null && customHeight.isFinite && customHeight > 0) {
      await _prefs.setDouble('audioPortraitCustomAspectHeight', customHeight);
    } else {
      await _prefs.remove('audioPortraitCustomAspectHeight');
    }
  }

  Future<void> updateSetting<T>(String key, T value) async {
    if (await _updateRegisteredSetting<T>(key, value)) {
      return;
    }

    switch (key) {
      case 'videoComposePrimarySubtitlePath':
        final v = value as String;
        await _prefs.setString(key, v);
        videoComposePrimarySubtitlePath = v.isEmpty ? null : v;
        break;
      case 'videoComposeSecondarySubtitlePath':
        final v = value as String;
        await _prefs.setString(key, v);
        videoComposeSecondarySubtitlePath = v.isEmpty ? null : v;
        break;
      case 'videoComposeCustomOutputPath':
        final v = value as String;
        await _prefs.setString(key, v);
        videoComposeCustomOutputPath = v.isEmpty ? null : v;
        break;
      case 'landscapeSidebarFontSizeScale':
        await _prefs.setDouble(key, value as double);
        landscapeSidebarFontSizeScale = value as double;
        break;
      case 'subtitleOffset':
        await _prefs.setInt(key, value as int);
        subtitleOffset = Duration(milliseconds: value as int);
        break;
      default:
        throw ArgumentError.value(key, 'key', 'Unsupported setting key');
    }
    notifyListeners();
  }

  Future<void> saveStructuredImportSortField(String value) async {
    await _updateRegisteredSetting<String>('structuredImportSortField', value);
  }

  Future<void> saveStructuredImportSortDirection(String value) async {
    await _updateRegisteredSetting<String>(
      'structuredImportSortDirection',
      value,
    );
  }

  Future<void> saveStructuredImportSort({
    required String field,
    required String direction,
  }) async {
    await _updateRegisteredSetting<String>(
      'structuredImportSortField',
      field,
      notify: false,
    );
    await _updateRegisteredSetting<String>(
      'structuredImportSortDirection',
      direction,
      notify: false,
    );
    notifyListeners();
  }

  Future<void> saveShowSubtitles(bool value) async {
    await _updateRegisteredSetting<bool>('showSubtitles', value);
  }

  Future<void> saveShowBilibiliDanmaku(bool value) async {
    await _updateRegisteredSetting<bool>('showBilibiliDanmaku', value);
  }

  Future<void> saveBilibiliDanmakuOnlyInVideoArea(bool value) async {
    await _updateRegisteredSetting<bool>(
      'bilibiliDanmakuOnlyInVideoArea',
      value,
    );
  }

  Future<void> saveBilibiliDanmakuDisplayArea(double value) async {
    await _updateRegisteredSetting<double>('bilibiliDanmakuDisplayArea', value);
  }

  Future<void> saveBilibiliDanmakuOpacity(double value) async {
    await _updateRegisteredSetting<double>('bilibiliDanmakuOpacity', value);
  }

  Future<void> saveBilibiliDanmakuFontScale(double value) async {
    await _updateRegisteredSetting<double>('bilibiliDanmakuFontScale', value);
  }

  Future<void> saveBilibiliDanmakuSpeed(double value) async {
    await _updateRegisteredSetting<double>('bilibiliDanmakuSpeed', value);
  }

  Future<void> saveBilibiliDanmakuFontFamily(String? value) async {
    await _updateRegisteredSetting<String>(
      'bilibiliDanmakuFontFamily',
      value ?? '',
    );
  }

  Future<void> saveBilibiliDanmakuFontWeight(int value) async {
    await _updateRegisteredSetting<int>('bilibiliDanmakuFontWeight', value);
  }

  Future<void> saveBilibiliDanmakuOutlineType(DanmakuOutlineType value) async {
    await _updateRegisteredSetting<String>(
      'bilibiliDanmakuOutlineType',
      value.name,
    );
  }

  Future<void> resetBilibiliDanmakuSettings() async {
    await _updateRegisteredSetting<bool>(
      'bilibiliDanmakuOnlyInVideoArea',
      false,
      notify: false,
    );
    await _updateRegisteredSetting<double>(
      'bilibiliDanmakuDisplayArea',
      0.5,
      notify: false,
    );
    await _updateRegisteredSetting<double>(
      'bilibiliDanmakuOpacity',
      0.8,
      notify: false,
    );
    await _updateRegisteredSetting<double>(
      'bilibiliDanmakuFontScale',
      0.8,
      notify: false,
    );
    await _updateRegisteredSetting<double>(
      'bilibiliDanmakuSpeed',
      1.0,
      notify: false,
    );
    await _updateRegisteredSetting<String>(
      'bilibiliDanmakuFontFamily',
      '',
      notify: false,
    );
    await _updateRegisteredSetting<int>(
      'bilibiliDanmakuFontWeight',
      600,
      notify: false,
    );
    await _updateRegisteredSetting<String>(
      'bilibiliDanmakuOutlineType',
      DanmakuOutlineType.standard.name,
      notify: false,
    );
    notifyListeners();
  }

  Future<void> saveMirrorHorizontal(bool value) async {
    await _updateRegisteredSetting<bool>('isMirroredH', value);
  }

  Future<void> saveMirrorVertical(bool value) async {
    await _updateRegisteredSetting<bool>('isMirroredV', value);
  }

  Future<void> saveLongPressSpeed(double value) async {
    await _updateRegisteredSetting<double>('longPressSpeed', value);
  }

  Future<void> saveShowLongPressSpeedIndicator(bool value) async {
    await _updateRegisteredSetting<bool>('showLongPressSpeedIndicator', value);
  }

  Future<void> saveGlobalMute(bool value) async {
    await _updateRegisteredSetting<bool>('globalMute', value);
  }

  Future<void> saveDoubleTapSeekSeconds(int value) async {
    await _updateRegisteredSetting<int>('doubleTapSeekSeconds', value);
  }

  Future<void> saveEnableDoubleTapSubtitleSeek(bool value) async {
    await _updateRegisteredSetting<bool>('enableDoubleTapSubtitleSeek', value);
  }

  Future<void> saveSubtitleOffsetMilliseconds(int value) async {
    await updateSetting('subtitleOffset', value);
  }

  Future<void> saveUserSubtitleSidebarWidth(double value) async {
    await _updateRegisteredSetting<double>('userSubtitleSidebarWidth', value);
  }

  Future<void> saveAutoCacheSubtitles(bool value) async {
    await _updateRegisteredSetting<bool>('autoCacheSubtitles', value);
  }

  Future<void> saveDesktopSubtitleScanSettings({
    required SubtitlePrefixMatchMode prefixMatchMode,
    required bool caseSensitive,
  }) async {
    await _updateRegisteredSetting<String>(
      'desktopSubtitlePrefixMatchMode',
      prefixMatchMode.name,
      notify: false,
    );
    await _updateRegisteredSetting<bool>(
      'desktopSubtitleScanCaseSensitive',
      caseSensitive,
      notify: false,
    );
    notifyListeners();
  }

  Future<void> saveSplitSubtitleByLine(bool value) async {
    await _updateRegisteredSetting<bool>('splitSubtitleByLine', value);
  }

  Future<void> saveAudioContinuousSubtitle(bool value) async {
    await _updateRegisteredSetting<bool>('audioContinuousSubtitle', value);
  }

  Future<void> saveVideoContinuousSubtitle(bool value) async {
    await _updateRegisteredSetting<bool>('videoContinuousSubtitle', value);
  }

  Future<void> saveAutoPauseOnExit(bool value) async {
    await _updateRegisteredSetting<bool>('autoPauseOnExit', value);
  }

  Future<void> saveAvoidPlaybackControlsWithSubtitles(bool value) async {
    await _updateRegisteredSetting<bool>(
      'avoidPlaybackControlsWithSubtitles',
      value,
    );
  }

  Future<void> savePausePlaybackWhenAppBackgrounded(bool value) async {
    await _updateRegisteredSetting<bool>(
      'pausePlaybackWhenAppBackgrounded',
      value,
    );
  }

  Future<void> saveAllowConcurrentPlayback(bool value) async {
    await _updateRegisteredSetting<bool>('allowConcurrentPlayback', value);
  }

  Future<void> saveUseHardwareVideoDecoding(bool value) async {
    await _updateRegisteredSetting<bool>('useHardwareVideoDecoding', value);
  }

  Future<void> saveEnableHeadsetMediaControls(bool value) async {
    await _updateRegisteredSetting<bool>('enableHeadsetMediaControls', value);
  }

  Future<void> saveAutoPlayNextVideo(bool value) async {
    await _updateRegisteredSetting<bool>('autoPlayNextVideo', value);
  }

  Future<void> saveSkipPortraitPlayer(bool value) async {
    await _updateRegisteredSetting<bool>('skipPortraitPlayer', value);
  }

  Future<void> saveEnableVideoPreload(bool value) async {
    await _updateRegisteredSetting<bool>('enableVideoPreload', value);
  }

  Future<void> saveAutoPlayOnCompletion(bool value) async {
    await _updateRegisteredSetting<bool>('autoPlayOnCompletion', value);
  }

  Future<void> saveAutoPlayOnCompletionFromStart(bool value) async {
    await _updateRegisteredSetting<bool>(
      'autoPlayOnCompletionFromStart',
      value,
    );
  }

  Future<void> saveEnableSeekPreview(bool value) async {
    await _updateRegisteredSetting<bool>('enableSeekPreview', value);
  }

  Future<void> saveEnableHapticFeedback(bool value) async {
    await _updateRegisteredSetting<bool>('enableHapticFeedback', value);
  }

  Future<void> saveLeftHandedMode(bool value) async {
    await _updateRegisteredSetting<bool>('isLeftHandedMode', value);
  }

  Future<void> saveGhostModeEnabled(bool value) async {
    await _updateRegisteredSetting<bool>('isGhostModeEnabled', value);
  }

  Future<void> saveLandscapeSubtitleSidebarVisible(bool value) async {
    await _updateRegisteredSetting<bool>(
      'landscapeSubtitleSidebarVisible',
      value,
    );
  }

  bool isSamePlaybackSpeed(double first, double second) {
    return (first - second).abs() < 0.001;
  }

  bool isLockedPlaybackSpeed(double speed) {
    return isPlaybackSpeedLocked && isSamePlaybackSpeed(playbackSpeed, speed);
  }

  double get effectiveGlobalPlaybackSpeed {
    return isPlaybackSpeedLocked ? playbackSpeed : 1.0;
  }

  Future<void> savePlaybackSpeed(double speed) async {
    await setPlaybackSpeedLock(speed, isPlaybackSpeedLocked);
  }

  Future<void> _loadPlaybackSpeedLockState() async {
    final rawState = _prefs.getString(_playbackSpeedLockStateKey);
    if (rawState == null || rawState.isEmpty) return;
    try {
      final decoded = json.decode(rawState);
      if (decoded is! Map<String, dynamic>) return;
      final speedValue = decoded['speed'];
      final lockedValue = decoded['locked'];
      if (speedValue is! num || lockedValue is! bool) return;
      final speed = speedValue.toDouble();
      if (!speed.isFinite || speed <= 0) return;
      playbackSpeed = speed;
      isPlaybackSpeedLocked = lockedValue;
    } catch (error, stackTrace) {
      developer.log(
        'Invalid playback speed lock snapshot; using legacy settings',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Stores the speed and lock flag as one canonical snapshot.
  ///
  /// The legacy keys are still mirrored for compatibility, but startup reads
  /// the snapshot first so an interrupted write can never produce a mixed
  /// speed/lock pair.
  Future<void> setPlaybackSpeedLock(double speed, bool locked) async {
    if (!speed.isFinite || speed <= 0) {
      throw ArgumentError.value(speed, 'speed', 'Must be finite and positive');
    }

    final previousSpeed = playbackSpeed;
    final previousLocked = isPlaybackSpeedLocked;
    playbackSpeed = speed;
    isPlaybackSpeedLocked = locked;
    notifyListeners();

    final snapshot = json.encode({'speed': speed, 'locked': locked});
    try {
      final saved = await _prefs.setString(
        _playbackSpeedLockStateKey,
        snapshot,
      );
      if (!saved) {
        throw StateError('Unable to save playback speed lock snapshot');
      }
    } catch (_) {
      playbackSpeed = previousSpeed;
      isPlaybackSpeedLocked = previousLocked;
      notifyListeners();
      rethrow;
    }

    // These keys are compatibility mirrors only. The single snapshot above is
    // the source of truth and has already been committed successfully.
    await Future.wait([
      _prefs.setDouble('playbackSpeed', playbackSpeed),
      _prefs.setBool('isPlaybackSpeedLocked', isPlaybackSpeedLocked),
    ]);
  }

  Future<PlaybackSpeedLockAction> togglePlaybackSpeedLock(double speed) async {
    final bool wasLocked = isPlaybackSpeedLocked;
    final bool wasLockedAtSpeed = isLockedPlaybackSpeed(speed);

    await setPlaybackSpeedLock(speed, !wasLockedAtSpeed);

    if (wasLockedAtSpeed) {
      return PlaybackSpeedLockAction.unlocked;
    }
    if (wasLocked) {
      return PlaybackSpeedLockAction.switched;
    }
    return PlaybackSpeedLockAction.locked;
  }

  // ========== 新的字幕样式保存方法 ==========

  /// 保存视频字幕文字样式 - 同步到横竖屏
  Future<void> saveSubtitleTextStyle(SubtitleTextStyle style) async {
    subtitleTextStyle = style;
    notifyListeners();
    await _prefs.setString('subtitleTextStyle', json.encode(style.toJson()));
    // 同时更新旧格式以保持兼容
    await _prefs.setString(
      'subtitleStyleLandscape',
      json.encode(subtitleStyleLandscape.toJson()),
    );
    await _prefs.setString(
      'subtitleStylePortrait',
      json.encode(subtitleStylePortrait.toJson()),
    );
    await _prefs.setString(
      'subtitleStyle',
      json.encode(subtitleStyleLandscape.toJson()),
    );
  }

  /// 保存音频字幕文字样式 - 同步到横竖屏
  Future<void> saveAudioSubtitleTextStyle(SubtitleTextStyle style) async {
    audioSubtitleTextStyle = style;
    notifyListeners();
    await _prefs.setString(
      'audioSubtitleTextStyle',
      json.encode(style.toJson()),
    );
    // 同时更新旧格式以保持兼容
    await _prefs.setString(
      'audioSubtitleStyleLandscape',
      json.encode(audioSubtitleStyleLandscape.toJson()),
    );
    await _prefs.setString(
      'audioSubtitleStylePortrait',
      json.encode(audioSubtitleStylePortrait.toJson()),
    );
  }

  /// 保存横屏布局样式
  Future<void> saveSubtitleLayoutLandscape(SubtitleLayoutStyle style) async {
    subtitleLayoutLandscape = style;
    subtitleLayoutPortrait = style;
    notifyListeners();
    await _prefs.setString(
      'subtitleLayoutLandscape',
      json.encode(style.toJson()),
    );
    await _prefs.setString(
      'subtitleLayoutPortrait',
      json.encode(style.toJson()),
    );
    await _prefs.setString(
      'subtitleStyleLandscape',
      json.encode(subtitleStyleLandscape.toJson()),
    );
    await _prefs.setString(
      'subtitleStylePortrait',
      json.encode(subtitleStylePortrait.toJson()),
    );
    await _prefs.setString(
      'subtitleStyle',
      json.encode(subtitleStyleLandscape.toJson()),
    );
  }

  /// 保存竖屏布局样式
  Future<void> saveSubtitleLayoutPortrait(SubtitleLayoutStyle style) async {
    subtitleLayoutPortrait = style;
    subtitleLayoutLandscape = style;
    notifyListeners();
    await _prefs.setString(
      'subtitleLayoutPortrait',
      json.encode(style.toJson()),
    );
    await _prefs.setString(
      'subtitleLayoutLandscape',
      json.encode(style.toJson()),
    );
    await _prefs.setString(
      'subtitleStylePortrait',
      json.encode(subtitleStylePortrait.toJson()),
    );
    await _prefs.setString(
      'subtitleStyleLandscape',
      json.encode(subtitleStyleLandscape.toJson()),
    );
    await _prefs.setString(
      'subtitleStyle',
      json.encode(subtitleStyleLandscape.toJson()),
    );
  }

  /// 保存幽灵模式布局样式（横竖屏同步，但与普通布局完全独立）
  Future<void> saveSubtitleLayoutGhostLandscape(
    SubtitleLayoutStyle style,
  ) async {
    subtitleLayoutGhostLandscape = style;
    subtitleLayoutGhostPortrait = style;
    notifyListeners();
    await _prefs.setString(
      'subtitleLayoutGhostLandscape',
      json.encode(style.toJson()),
    );
    await _prefs.setString(
      'subtitleLayoutGhostPortrait',
      json.encode(style.toJson()),
    );
  }

  Future<void> saveSubtitleLayoutGhostPortrait(
    SubtitleLayoutStyle style,
  ) async {
    subtitleLayoutGhostPortrait = style;
    subtitleLayoutGhostLandscape = style;
    notifyListeners();
    await _prefs.setString(
      'subtitleLayoutGhostPortrait',
      json.encode(style.toJson()),
    );
    await _prefs.setString(
      'subtitleLayoutGhostLandscape',
      json.encode(style.toJson()),
    );
  }

  /// 保存音频横屏布局样式
  Future<void> saveAudioSubtitleLayoutLandscape(
    SubtitleLayoutStyle style,
  ) async {
    audioSubtitleLayoutLandscape = style;
    audioSubtitleLayoutPortrait = style;
    notifyListeners();
    await _prefs.setString(
      'audioSubtitleLayoutLandscape',
      json.encode(style.toJson()),
    );
    await _prefs.setString(
      'audioSubtitleLayoutPortrait',
      json.encode(style.toJson()),
    );
    await _prefs.setString(
      'audioSubtitleStyleLandscape',
      json.encode(audioSubtitleStyleLandscape.toJson()),
    );
    await _prefs.setString(
      'audioSubtitleStylePortrait',
      json.encode(audioSubtitleStylePortrait.toJson()),
    );
  }

  /// 保存音频竖屏布局样式
  Future<void> saveAudioSubtitleLayoutPortrait(
    SubtitleLayoutStyle style,
  ) async {
    audioSubtitleLayoutPortrait = style;
    audioSubtitleLayoutLandscape = style;
    notifyListeners();
    await _prefs.setString(
      'audioSubtitleLayoutPortrait',
      json.encode(style.toJson()),
    );
    await _prefs.setString(
      'audioSubtitleLayoutLandscape',
      json.encode(style.toJson()),
    );
    await _prefs.setString(
      'audioSubtitleStylePortrait',
      json.encode(audioSubtitleStylePortrait.toJson()),
    );
    await _prefs.setString(
      'audioSubtitleStyleLandscape',
      json.encode(audioSubtitleStyleLandscape.toJson()),
    );
  }

  // ========== 向后兼容的旧方法 ==========

  // Legacy saver (maps to landscape)
  Future<void> saveSubtitleStyle(SubtitleStyle style) async {
    await saveSubtitleStyleLandscape(style);
  }

  Future<void> saveSubtitleStyleLandscape(SubtitleStyle style) async {
    subtitleTextStyle = style.textStyle;
    subtitleLayoutLandscape = style.layoutStyle;
    subtitleLayoutPortrait = style.layoutStyle;
    notifyListeners();
    await _prefs.setString(
      'subtitleTextStyle',
      json.encode(style.textStyle.toJson()),
    );
    await _prefs.setString(
      'subtitleLayoutLandscape',
      json.encode(style.layoutStyle.toJson()),
    );
    await _prefs.setString(
      'subtitleLayoutPortrait',
      json.encode(style.layoutStyle.toJson()),
    );
    await _prefs.setString(
      'subtitleStyleLandscape',
      json.encode(style.toJson()),
    );
    await _prefs.setString(
      'subtitleStylePortrait',
      json.encode(subtitleStylePortrait.toJson()),
    );
    await _prefs.setString('subtitleStyle', json.encode(style.toJson()));
  }

  Future<void> saveSubtitleStylePortrait(SubtitleStyle style) async {
    subtitleTextStyle = style.textStyle;
    subtitleLayoutPortrait = style.layoutStyle;
    subtitleLayoutLandscape = style.layoutStyle;
    notifyListeners();
    await _prefs.setString(
      'subtitleLayoutPortrait',
      json.encode(style.layoutStyle.toJson()),
    );
    await _prefs.setString(
      'subtitleLayoutLandscape',
      json.encode(style.layoutStyle.toJson()),
    );
    await _prefs.setString(
      'subtitleTextStyle',
      json.encode(style.textStyle.toJson()),
    );
    await _prefs.setString(
      'subtitleStylePortrait',
      json.encode(subtitleStylePortrait.toJson()),
    );
    await _prefs.setString(
      'subtitleStyleLandscape',
      json.encode(subtitleStyleLandscape.toJson()),
    );
    await _prefs.setString(
      'subtitleStyle',
      json.encode(subtitleStyleLandscape.toJson()),
    );
  }

  // Audio Subtitle Style Savers
  Future<void> saveAudioSubtitleStyleLandscape(SubtitleStyle style) async {
    audioSubtitleTextStyle = style.textStyle;
    audioSubtitleLayoutLandscape = style.layoutStyle;
    audioSubtitleLayoutPortrait = style.layoutStyle;
    notifyListeners();
    await _prefs.setString(
      'audioSubtitleTextStyle',
      json.encode(style.textStyle.toJson()),
    );
    await _prefs.setString(
      'audioSubtitleLayoutLandscape',
      json.encode(style.layoutStyle.toJson()),
    );
    await _prefs.setString(
      'audioSubtitleLayoutPortrait',
      json.encode(style.layoutStyle.toJson()),
    );
    await _prefs.setString(
      'audioSubtitleStyleLandscape',
      json.encode(style.toJson()),
    );
    await _prefs.setString(
      'audioSubtitleStylePortrait',
      json.encode(audioSubtitleStylePortrait.toJson()),
    );
  }

  Future<void> saveAudioSubtitleStylePortrait(SubtitleStyle style) async {
    audioSubtitleTextStyle = style.textStyle;
    audioSubtitleLayoutPortrait = style.layoutStyle;
    audioSubtitleLayoutLandscape = style.layoutStyle;
    notifyListeners();
    await _prefs.setString(
      'audioSubtitleLayoutPortrait',
      json.encode(style.layoutStyle.toJson()),
    );
    await _prefs.setString(
      'audioSubtitleLayoutLandscape',
      json.encode(style.layoutStyle.toJson()),
    );
    await _prefs.setString(
      'audioSubtitleTextStyle',
      json.encode(style.textStyle.toJson()),
    );
    await _prefs.setString(
      'audioSubtitleStylePortrait',
      json.encode(audioSubtitleStylePortrait.toJson()),
    );
    await _prefs.setString(
      'audioSubtitleStyleLandscape',
      json.encode(audioSubtitleStyleLandscape.toJson()),
    );
  }

  Future<void> saveSubtitleAlignment(Alignment align) async {
    subtitleAlignment = align;
    notifyListeners();
    _pendingSubtitleAlignmentPersist = align;
    await _drainSubtitleAlignmentPersistQueue();
  }

  Future<void> saveAudioSubtitleAlignment(Alignment align) async {
    audioSubtitleAlignment = align;
    notifyListeners();
    _pendingAudioSubtitleAlignmentPersist = align;
    await _drainAudioSubtitleAlignmentPersistQueue();
  }

  Future<void> setAudioSubtitleStyleSyncWithVideo(bool value) async {
    syncAudioSubtitleStyleWithVideo = value;
    await _prefs.setBool('syncAudioSubtitleStyleWithVideo', value);
    notifyListeners();
  }

  Future<void> saveGhostModeAlignment(Alignment align) async {
    ghostModeAlignment = align;
    notifyListeners();
    _pendingGhostModeAlignmentPersist = align;
    await _drainGhostModeAlignmentPersistQueue();
  }

  Future<void> saveSubtitlePresets(List<Map<String, double>> presets) async {
    subtitlePresets = presets;
    await _prefs.setString('subtitlePresets', json.encode(presets));
    notifyListeners();
  }

  Map<String, dynamic> exportSettingsSnapshot() {
    return {
      'general': {
        'isLeftHandedMode': isLeftHandedMode,
        'isMirroredH': isMirroredH,
        'isMirroredV': isMirroredV,
      },
      'playback': {
        'playbackSpeed': playbackSpeed,
        'isPlaybackSpeedLocked': isPlaybackSpeedLocked,
        'globalMute': globalMute,
        'longPressSpeed': longPressSpeed,
        'showLongPressSpeedIndicator': showLongPressSpeedIndicator,
        'doubleTapSeekSeconds': doubleTapSeekSeconds,
        'enableDoubleTapSubtitleSeek': enableDoubleTapSubtitleSeek,
        'autoPauseOnExit': autoPauseOnExit,
        'avoidPlaybackControlsWithSubtitles':
            avoidPlaybackControlsWithSubtitles,
        'pausePlaybackWhenAppBackgrounded': pausePlaybackWhenAppBackgrounded,
        'allowConcurrentPlayback': allowConcurrentPlayback,
        'enableHeadsetMediaControls': enableHeadsetMediaControls,
        'autoPlayNextVideo': autoPlayNextVideo,
        'enableVideoPreload': enableVideoPreload,
        'autoPlayOnCompletion': autoPlayOnCompletion,
        'autoPlayOnCompletionFromStart': autoPlayOnCompletionFromStart,
        'enableSeekPreview': enableSeekPreview,
        'enableHapticFeedback': enableHapticFeedback,
        'isActionButtonsCollapsed': isActionButtonsCollapsed,
      },
      'layout': {
        'userSubtitleSidebarWidth': userSubtitleSidebarWidth,
        'landscapeSidebarFontSizeScale': landscapeSidebarFontSizeScale,
        'portraitSidebarFontSizeScale': portraitSidebarFontSizeScale,
        'landscapeSidebarShowTimestamps': landscapeSidebarShowTimestamps,
        'portraitSidebarShowTimestamps': portraitSidebarShowTimestamps,
        'landscapeSidebarTimeColumnRatio': landscapeSidebarTimeColumnRatio,
        'portraitSidebarTimeColumnRatio': portraitSidebarTimeColumnRatio,
        'landscapeSidebarLocatePositionPercent':
            landscapeSidebarLocatePositionPercent,
        'portraitSidebarLocatePositionPercent':
            portraitSidebarLocatePositionPercent,
        'subtitleArticleSentencesPerParagraph':
            subtitleArticleSentencesPerParagraph,
        'subtitleViewMode': subtitleViewMode,
      },
      'home': {
        'homeGridCrossAxisCount': homeGridCrossAxisCount,
        'homeCardTitleFontSize': homeCardTitleFontSize,
        'homeCardAspectRatio': homeCardAspectRatio,
        'mediaLibraryViewMode': mediaLibraryViewMode,
        'mediaListCrossAxisCount': mediaListCrossAxisCount,
        'mediaListShowThumbnail': mediaListShowThumbnail,
        'mediaListShowIndex': mediaListShowIndex,
        'mediaListItemHeightScale': mediaListItemHeightScale,
        'mediaListMainSpacingScale': mediaListMainSpacingScale,
        'mediaListCrossSpacingScale': mediaListCrossSpacingScale,
        'mediaListTitleScale': mediaListTitleScale,
        'mediaListCoverOffset': mediaListCoverOffset,
        'copyImportedMediaToPrivateStorage': copyImportedMediaToPrivateStorage,
        'structuredImportSortField': structuredImportSortField,
        'structuredImportSortDirection': structuredImportSortDirection,
      },
      'videoCard': {
        'videoCardCrossAxisCount': videoCardCrossAxisCount,
        'videoCardTitleFontSize': videoCardTitleFontSize,
        'videoCardAspectRatio': videoCardAspectRatio,
      },
      'subtitles': {
        'showSubtitles': showSubtitles,
        'autoCacheSubtitles': autoCacheSubtitles,
        'autoScrollSubtitles': autoScrollSubtitles,
        'subtitleEditorAutoFollow': subtitleEditorAutoFollow,
        'autoLoadEmbeddedSubtitles': autoLoadEmbeddedSubtitles,
        'splitSubtitleByLine': splitSubtitleByLine,
        'videoContinuousSubtitle': videoContinuousSubtitle,
        'audioContinuousSubtitle': audioContinuousSubtitle,
        'syncAudioSubtitleStyleWithVideo': syncAudioSubtitleStyleWithVideo,
        'isGhostModeEnabled': isGhostModeEnabled,
        'subtitleDelayMs': subtitleOffset.inMilliseconds,
        'subtitleDelaySeconds': subtitleDelay,
        'alignment': {'x': subtitleAlignment.x, 'y': subtitleAlignment.y},
        'audioAlignment': {
          'x': audioSubtitleAlignment.x,
          'y': audioSubtitleAlignment.y,
        },
        'ghostAlignment': {
          'x': ghostModeAlignment.x,
          'y': ghostModeAlignment.y,
        },
        'presets': subtitlePresets,
        'textStyle': subtitleTextStyle.toJson(),
        'layoutLandscape': subtitleLayoutLandscape.toJson(),
        'layoutPortrait': subtitleLayoutPortrait.toJson(),
        'ghostLayoutLandscape': subtitleLayoutGhostLandscape.toJson(),
        'ghostLayoutPortrait': subtitleLayoutGhostPortrait.toJson(),
        'audioTextStyle': audioSubtitleTextStyle.toJson(),
        'audioLayoutLandscape': audioSubtitleLayoutLandscape.toJson(),
        'audioLayoutPortrait': audioSubtitleLayoutPortrait.toJson(),
        'legacy': {
          'subtitleStyleLandscape': subtitleStyleLandscape.toJson(),
          'subtitleStylePortrait': subtitleStylePortrait.toJson(),
          'audioSubtitleStyleLandscape': audioSubtitleStyleLandscape.toJson(),
          'audioSubtitleStylePortrait': audioSubtitleStylePortrait.toJson(),
        },
      },
      'window': {'isFullScreen': isFullScreen},
      'ai': {'lastSelectedModelType': lastSelectedModelType},
    };
  }

  Future<String> getDefaultLargeDataRootPath() async {
    if (Platform.isWindows) {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      return p.join(exeDir, 'VideoPlayerData');
    }
    final appDocDir = await getApplicationDocumentsDirectory();
    return appDocDir.path;
  }

  Future<Directory> resolveLargeDataRootDir() async {
    if (!Platform.isWindows) {
      return getApplicationDocumentsDirectory();
    }
    final defaultPath = await getDefaultLargeDataRootPath();
    final targetPath =
        (largeDataRootPath != null && largeDataRootPath!.isNotEmpty)
        ? largeDataRootPath!
        : defaultPath;
    final dir = Directory(targetPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> setLargeDataRootPath(String? path) async {
    if (path == null || path.isEmpty) {
      largeDataRootPath = null;
      await _prefs.remove('largeDataRootPath');
    } else {
      largeDataRootPath = path;
      await _prefs.setString('largeDataRootPath', path);
    }
    notifyListeners();
  }
}
