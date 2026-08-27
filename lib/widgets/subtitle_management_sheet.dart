import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import '../services/embedded_subtitle_service.dart';
import '../models/subtitle_source_type.dart';
import '../models/subtitle_classification.dart';
import '../services/settings_service.dart';
import '../services/library_service.dart';
import '../services/task_subtitle_storage_service.dart';
import '../models/managed_subtitle_asset.dart';
import '../services/subtitle_translation_service.dart';
import '../services/subtitle_discovery_service.dart';
import '../utils/app_toast.dart';
import '../utils/subtitle_parser.dart';
import '../utils/subtitle_file_matcher.dart';

import 'package:shared_preferences/shared_preferences.dart';

@visibleForTesting
Future<bool> showSubtitleDeletionConfirmationDialog(
  BuildContext context, {
  required String fileName,
  required bool isSidecar,
  required bool isExternal,
  required int dependentAssetCount,
}) async {
  return await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: const Color(0xFF2C2C2C),
          title: Text(
            isExternal ? '删除外部字幕文件' : '删除字幕',
            style: const TextStyle(color: Colors.white),
          ),
          content: Text(
            isSidecar
                ? '这是视频同目录下的伴随字幕。删除磁盘文件后，所有使用该视频的任务都将无法再看到它。\n\n确定删除 $fileName 吗？'
                : isExternal
                ? '这是任务目录之外的外部字幕。删除会直接移除原始磁盘文件，其他引用该文件的地方也会受影响。\n\n确定删除 $fileName 吗？'
                : dependentAssetCount == 0
                ? '确定要删除 $fileName 吗？'
                : '确定要删除 $fileName 吗？\n同时会删除 $dependentAssetCount 个由它生成的任务字幕。',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: const Text('删除'),
            ),
          ],
        ),
      ) ??
      false;
}

class SubtitleManagementSheet extends StatefulWidget {
  final String videoPath;
  final String? videoId;
  final VoidCallback onSubtitleChanged;
  final VoidCallback onOpenAi;
  final Function(List<String> paths)? onSubtitleSelected;
  final Function(String path)? onSubtitlePreview; // New callback
  final VoidCallback? onClose;
  final Map<String, String>? associatedSubtitles;
  final Map<String, String>? localSubtitles;
  final List<String> initialSelectedPaths;
  final bool showEmbeddedSubtitles;

  const SubtitleManagementSheet({
    super.key,
    required this.videoPath,
    this.videoId,
    required this.onSubtitleChanged,
    required this.onOpenAi,
    this.onSubtitleSelected,
    this.onSubtitlePreview,
    this.onClose,
    this.associatedSubtitles,
    this.localSubtitles,
    this.initialSelectedPaths = const [],
    this.showEmbeddedSubtitles = true,
  });

  @override
  State<SubtitleManagementSheet> createState() =>
      _SubtitleManagementSheetState();
}

class _SubtitleManagementSheetState extends State<SubtitleManagementSheet> {
  static final RegExp _extractedTrackPattern = RegExp(
    r'\.stream_(\d+)(?:\.[^.]+)?$',
    caseSensitive: false,
  );
  List<File> _subtitleFiles = [];
  List<EmbeddedSubtitleTrack> _embeddedTracks = [];
  bool _isScanningFiles = true;
  bool _isScanningEmbedded = false;
  int _scanGeneration = 0;
  final Map<String, int> _subtitleFileSizes = <String, int>{};
  final Set<String> _sidecarSubtitlePaths = <String>{};
  final Set<String> _taskSubtitlePaths = <String>{};
  int? _extractingTrackIndex;
  List<String> _selectedPaths = []; // Track selected items
  String? _customDownloadPath;
  String _defaultDownloadPath = "用户/下载";

  final Map<int, String> _extractedTrackPaths =
      {}; // Map track index to extracted path

  final SubtitleTranslationService _subtitleTranslationService =
      SubtitleTranslationService.instance;
  String? _expandedTranslatePath;
  // 翻译状态由服务（单例）持有，UI 通过监听器刷新，跨页面重建可恢复进度。
  // _translateSourceLanguage / _translateTargetLanguage / _translateProvider
  // 仅是 UI 选择器偏好，保留在本地。
  String _translateSourceLanguage = 'en';
  String _translateTargetLanguage = 'zh-CN';
  SubtitleTranslateProvider _translateProvider =
      SubtitleTranslateProvider.mymemory;

  /// 中英方向的翻译服务（默认 MyMemory）。
  SubtitleTranslateProvider _translateProviderEnZh =
      SubtitleTranslateProvider.mymemory;

  /// 其他语言方向的翻译服务（默认 MyMemory）。
  SubtitleTranslateProvider _translateProviderOther =
      SubtitleTranslateProvider.mymemory;

  /// 当前是否有针对 [path] 的翻译任务在进行。
  bool _isPathTranslating(String? path) {
    return path != null &&
        _subtitleTranslationService.isTranslatingPathForVideo(
          videoPath: widget.videoPath,
          inputPath: path,
        );
  }

  bool _isActiveTranslationForCurrentVideo() {
    return _subtitleTranslationService.isTranslatingForVideo(widget.videoPath);
  }

  bool _isTranslationPanelExpandedFor(String path) {
    final expandedPath = _expandedTranslatePath;
    return expandedPath != null &&
        _normalizePath(expandedPath) == _normalizePath(path);
  }

  void _restoreActiveTranslationUi() {
    if (!_isActiveTranslationForCurrentVideo()) return;
    final activeInputPath = _subtitleTranslationService.activeInputPath;
    if (activeInputPath == null || activeInputPath.isEmpty) return;

    // Restore the panel as well as the service state so progress is visible as
    // soon as the fresh subtitle scan renders the active source file.
    _expandedTranslatePath = p.normalize(activeInputPath);
    final sourceLanguage = _subtitleTranslationService.activeSourceLanguage;
    final targetLanguage = _subtitleTranslationService.activeTargetLanguage;
    final provider = _subtitleTranslationService.activeProvider;
    if (sourceLanguage != null && _containsSourceLanguage(sourceLanguage)) {
      _translateSourceLanguage = sourceLanguage;
    }
    if (targetLanguage != null && _containsTargetLanguage(targetLanguage)) {
      _translateTargetLanguage = targetLanguage;
    }
    if (provider != null) {
      _translateProvider = provider;
    }
  }

  bool _manualTranslateMode = false;
  bool _manualPromptSubtitleFirst = true;
  bool _isLoadingManualSource = false;
  String? _manualLoadedSourcePath;

  static const String _manualPromptEditableDefault =
      '你是一名专业字幕翻译与本地化编辑。\n'
      '严格要求：\n'
      '1) 保持原有序号、时间轴行、空行结构完全一致。千万不要删除原文本中的空白行。保留原有格式。\n'
      '2) 仅翻译字幕文本行；不要改动时间戳格式与顺序。\n'
      '3) 不要输出解释、注释、前言、后记、Markdown、代码块标记。\n'
      '4) 仅输出“可直接保存为字幕文件”的纯文本内容。\n'
      '5) 保留专有名词可读性；必要时采用约定术语。\n'
      '6) 如遇无语义内容（如音乐提示），按目标语言自然表达。';

  final TextEditingController _manualSourceController = TextEditingController();
  final TextEditingController _manualPromptController = TextEditingController(
    text: _manualPromptEditableDefault,
  );

  Timer? _translatePrefsSaveDebounce;
  bool _isApplyingTranslatePrefs = false;

  static const String _prefKeyTranslateMode =
      'subtitle_translate_manual_mode_enabled';
  static const String _prefKeyTranslateProvider = 'subtitle_translate_provider';
  static const String _prefKeyTranslateProviderEnZh =
      'subtitle_translate_provider_enzh';
  static const String _prefKeyTranslateProviderOther =
      'subtitle_translate_provider_other';
  static const String _prefKeyManualPromptOrder =
      'subtitle_translate_manual_prompt_first';
  static const String _prefKeyManualPromptEditable =
      'subtitle_translate_manual_prompt_editable';

  String _normalizePath(String path) {
    final normalized = p.normalize(path);
    if (Platform.isWindows) {
      return normalized.toLowerCase();
    }
    return normalized;
  }

  int _selectedIndexOf(String path) {
    final key = _normalizePath(path);
    for (int i = 0; i < _selectedPaths.length; i++) {
      if (_normalizePath(_selectedPaths[i]) == key) {
        return i;
      }
    }
    return -1;
  }

  bool _selectedContains(String path) => _selectedIndexOf(path) != -1;

  List<String> _normalizeSelectedPaths(List<String> input) {
    final keys = <String>{};
    final output = <String>[];
    for (final item in input) {
      if (item.isEmpty) continue;
      final normalized = p.normalize(item);
      final key = _normalizePath(normalized);
      if (keys.add(key)) {
        output.add(normalized);
      }
    }
    return output;
  }

  int? _streamIndexFromExtractedPath(String path) {
    final match = _extractedTrackPattern.firstMatch(p.basename(path));
    if (match == null) return null;
    return int.tryParse(match.group(1) ?? '');
  }

  bool _matchesCurrentVideoExtractedFile(String path, Set<String> prefixes) {
    final fileName = p.basename(path);
    if (!fileName.contains('.stream_')) {
      return false;
    }
    for (final prefix in prefixes) {
      if (prefix.isNotEmpty && fileName.startsWith('$prefix.stream_')) {
        return true;
      }
    }
    return false;
  }

  void _registerExtractedTrackPath(
    String path, {
    required Set<String> extractedPrefixes,
  }) {
    final normalized = p.normalize(path);
    if (!_matchesCurrentVideoExtractedFile(normalized, extractedPrefixes)) {
      return;
    }
    final index = _streamIndexFromExtractedPath(normalized);
    if (index == null) return;
    _extractedTrackPaths[index] = normalized;
  }

  bool _isImageSubtitleCodec(String codecName) {
    final codec = codecName.toLowerCase();
    return codec == 'hdmv_pgs_subtitle' ||
        codec == 'dvd_subtitle' ||
        codec == 'pgs' ||
        codec == 'pgs_subtitle' ||
        codec == 'vobsub' ||
        codec == 'xsub';
  }

  @override
  void initState() {
    super.initState();
    _selectedPaths = _normalizeSelectedPaths(widget.initialSelectedPaths);
    _manualPromptController.addListener(_onManualPromptChanged);
    _subtitleTranslationService.addListener(_onTranslationChanged);
    _subtitleTranslationService.addCompletionCallback(_onTranslationComplete);
    _restoreActiveTranslationUi();
    _loadSubtitles();
    _initDefaultPath();
    _loadCustomDownloadPath();
    _loadTranslatePanelPreferences();
  }

  @override
  void dispose() {
    _translatePrefsSaveDebounce?.cancel();
    _saveTranslatePanelPreferences();
    _subtitleTranslationService.removeListener(_onTranslationChanged);
    _subtitleTranslationService.removeCompletionCallback(
      _onTranslationComplete,
    );
    _manualPromptController.removeListener(_onManualPromptChanged);
    _manualSourceController.dispose();
    _manualPromptController.dispose();
    super.dispose();
  }

  void _onTranslationChanged() {
    if (!mounted) return;
    setState(() {});
  }

  /// 翻译完成回调。即便发起翻译的 UI 已销毁，只要重开后重新注册即可接收。
  void _onTranslationComplete(SubtitleTranslationCompletion completion) {
    if (!mounted) return;
    if (!_sameVideoPath(completion.videoPath)) return;
    // A previous player route can remain mounted underneath the video that is
    // currently being watched. Refresh its data, but never let that hidden
    // route publish a global toast over the new video.
    final routeIsCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    if (completion.isSuccess && completion.result != null) {
      _loadSubtitles();
      _notifySubtitleFilesChanged();
      setState(() {
        _expandedTranslatePath = null;
      });
      if (routeIsCurrent) {
        AppToast.show(
          "翻译完成：${p.basename(completion.result!.outputPath)}\n保存位置：${completion.result!.outputPath}",
          type: AppToastType.success,
        );
      }
    } else if (completion.error != null && routeIsCurrent) {
      AppToast.show("翻译失败：${completion.error}", type: AppToastType.error);
    }
  }

  bool _sameVideoPath(String path) =>
      _normalizePath(path) == _normalizePath(widget.videoPath);

  void _notifySubtitleFilesChanged() {
    try {
      Provider.of<LibraryService>(
        context,
        listen: false,
      ).notifySubtitleFilesChanged(videoId: widget.videoId);
    } catch (_) {
      // Isolated previews/tests may host the sheet without LibraryService.
    }
    widget.onSubtitleChanged();
  }

  String _requireVideoId() {
    final videoId = widget.videoId?.trim() ?? '';
    if (videoId.isEmpty) {
      throw StateError('当前媒体没有任务 ID，无法创建任务字幕');
    }
    return videoId;
  }

  Future<void> _registerManagedSubtitle(
    String path,
    ManagedSubtitleAssetKind kind,
    String displayName, {
    String? sourcePath,
    String? language,
  }) async {
    final videoId = _requireVideoId();
    final library = Provider.of<LibraryService>(context, listen: false);
    final sourceAssetId = sourcePath == null
        ? null
        : library.managedSubtitleAssetForPath(videoId, sourcePath)?.assetId;
    await library.registerManagedSubtitleAsset(
      videoId,
      path: path,
      kind: kind,
      displayName: displayName,
      sourceAssetId: sourceAssetId,
      language: language,
    );
  }

  void _initDefaultPath() {
    if (Platform.isWindows) {
      try {
        final exeDir = p.dirname(Platform.resolvedExecutable);
        _defaultDownloadPath = p.join(exeDir, 'Downloads');
      } catch (e) {
        // Fallback
      }
    }
  }

  Future<void> _loadCustomDownloadPath() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final path = prefs.getString('subtitle_download_path');
      if (mounted) {
        setState(() {
          _customDownloadPath = path;
        });
      }
    } catch (e) {
      debugPrint("Error loading custom download path: $e");
    }
  }

  Future<void> _setCustomDownloadPath() async {
    try {
      final String? selectedDirectory = await FilePicker.platform
          .getDirectoryPath();
      if (selectedDirectory != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('subtitle_download_path', selectedDirectory);
        if (mounted) {
          setState(() {
            _customDownloadPath = selectedDirectory;
          });
          AppToast.show("默认下载路径已更新", type: AppToastType.success);
        }
      }
    } catch (e) {
      debugPrint("Error setting custom download path: $e");
    }
  }

  bool _containsSourceLanguage(String code) {
    for (final lang in _sourceLanguageOptions) {
      if (lang.code == code) return true;
    }
    return false;
  }

  bool _containsTargetLanguage(String code) {
    for (final lang in _targetLanguageOptions) {
      if (lang.code == code) return true;
    }
    return false;
  }

  String? _detectLanguageFromFileName(String path) {
    final name = p.basename(path).toLowerCase();

    bool has(RegExp regExp) => regExp.hasMatch(name);

    if (name.contains('中文') ||
        name.contains('汉语') ||
        name.contains('简体') ||
        name.contains('繁体') ||
        has(
          RegExp(r'(^|[._\-\s])(zh|zho|chi|chs|cht|cn|chinese)([._\-\s]|$)'),
        )) {
      return 'zh-CN';
    }
    if (name.contains('日本語') ||
        name.contains('日语') ||
        has(RegExp(r'(^|[._\-\s])(ja|jpn|jp|japanese)([._\-\s]|$)'))) {
      return 'ja';
    }
    if (name.contains('한국어') ||
        name.contains('韩语') ||
        has(RegExp(r'(^|[._\-\s])(ko|kor|kr|korean)([._\-\s]|$)'))) {
      return 'ko';
    }
    if (has(RegExp(r'(^|[._\-\s])(en|eng|english)([._\-\s]|$)'))) {
      return 'en';
    }
    if (has(
      RegExp(r'(^|[._\-\s])(pt|por|portuguese|pt-br|pt-pt)([._\-\s]|$)'),
    )) {
      return 'pt';
    }
    if (has(RegExp(r'(^|[._\-\s])(fr|fra|french)([._\-\s]|$)'))) {
      return 'fr';
    }
    if (has(RegExp(r'(^|[._\-\s])(de|ger|deu|german)([._\-\s]|$)'))) {
      return 'de';
    }
    if (has(RegExp(r'(^|[._\-\s])(es|spa|spanish)([._\-\s]|$)'))) {
      return 'es';
    }
    if (has(RegExp(r'(^|[._\-\s])(it|ita|italian)([._\-\s]|$)'))) {
      return 'it';
    }
    if (has(RegExp(r'(^|[._\-\s])(ru|rus|russian)([._\-\s]|$)'))) {
      return 'ru';
    }
    if (has(RegExp(r'(^|[._\-\s])(th|tha|thai)([._\-\s]|$)'))) {
      return 'th';
    }
    if (has(RegExp(r'(^|[._\-\s])(ar|ara|arabic)([._\-\s]|$)'))) {
      return 'ar';
    }

    return null;
  }

  Future<String?> _detectLanguageFromSubtitleContent(String path) async {
    try {
      final text = await File(path).readAsString();
      final sample = text.length > 8000 ? text.substring(0, 8000) : text;
      final lower = sample.toLowerCase();

      // ===== 非拉丁文字系检测 =====
      final chinese = RegExp(r'[\u4E00-\u9FFF]').allMatches(sample).length;
      final kana = RegExp(r'[\u3040-\u30FF]').allMatches(sample).length;
      final hangul = RegExp(r'[\uAC00-\uD7AF]').allMatches(sample).length;
      final cyrillic = RegExp(r'[\u0400-\u04FF]').allMatches(sample).length;
      final thai = RegExp(r'[\u0E00-\u0E7F]').allMatches(sample).length;
      final arabic = RegExp(r'[\u0600-\u06FF]').allMatches(sample).length;

      if (chinese >= 8 && chinese >= kana && chinese >= hangul) {
        return 'zh-CN';
      }
      if (kana >= chinese && kana >= 8) {
        return 'ja';
      }
      if (hangul >= chinese && hangul >= 8) {
        return 'ko';
      }
      if (cyrillic >= 8) {
        return 'ru';
      }
      if (thai >= 8) {
        return 'th';
      }
      if (arabic >= 8) {
        return 'ar';
      }

      final latin = RegExp(r'[A-Za-z]').allMatches(sample).length;
      if (latin < 12) return null;

      // ===== 拉丁文字系检测（综合评分法）=====
      // 每种语言一组「特征字符(权重) + 高频词」，总分最高者为结果。
      // 特征字符：葡萄牙语鼻元音 ã/õ、德语变音 äöüß、西班牙语 ñ 权重最高；
      // 法语/意大利语重音字符区分度较弱，辅以高频词。
      final features = <String, (RegExp, int, RegExp)>{
        'pt': (
          RegExp(r'[ãõ]'),
          3,
          RegExp(r'\b(de|que|o|a|em|para|um|não|os|as|do|da|uma|com|você)\b'),
        ),
        'de': (
          RegExp(r'[äöüß]'),
          3,
          RegExp(r'\b(der|die|das|und|ist|ein|nicht|mit|sie|ich|zu|wir)\b'),
        ),
        'es': (
          RegExp(r'[ñ¿¡]'),
          3,
          RegExp(r'\b(el|la|los|las|que|con|para|por|es|una|y|en|no)\b'),
        ),
        'fr': (
          RegExp(r'[çéèêëàâîïôûùœ]'),
          1,
          RegExp(
            r'\b(le|de|la|et|les|des|en|un|une|que|est|pour|avec|vous|nous)\b',
          ),
        ),
        'it': (
          RegExp(r'[àèéìíîòóùú]'),
          1,
          RegExp(r'\b(il|lo|la|di|che|e|in|un|per|sono|è|non|mi|ci)\b'),
        ),
        'en': (
          RegExp(r'[qxz]k'),
          0,
          RegExp(r'\b(the|and|of|to|is|in|that|it|you|for|this|with|we|she)\b'),
        ),
      };

      final scores = <String, int>{};
      features.forEach((lang, feat) {
        final (charRe, charWeight, stopRe) = feat;
        var score = 0;
        score += charRe.allMatches(lower).length * charWeight;
        score += stopRe.allMatches(lower).length;
        scores[lang] = score;
      });

      // 取非英语语言中的最高分
      String? best;
      int bestScore = 0;
      scores.forEach((lang, score) {
        if (lang != 'en' && score > bestScore) {
          best = lang;
          bestScore = score;
        }
      });
      final enScore = scores['en'] ?? 0;
      // 非英语语言得分必须 >= 4 且显著高于英语（1.3 倍）才判定为对应语言
      if (best != null && bestScore >= 4 && bestScore > enScore * 1.3) {
        return best;
      }
      return 'en';
    } catch (_) {
      return null;
    }
  }

  bool _isChineseLanguageCode(String code) {
    final normalized = code.toLowerCase();
    return normalized.startsWith('zh') || normalized.contains('chinese');
  }

  Future<void> _applySmartLanguageDefaultsForPath(String path) async {
    final fromName = _detectLanguageFromFileName(path);
    final detectedSource =
        fromName ?? await _detectLanguageFromSubtitleContent(path);

    final source = detectedSource ?? 'auto';
    final target = _isChineseLanguageCode(source) ? 'en' : 'zh-CN';

    if (!mounted) return;
    setState(() {
      _translateSourceLanguage = _containsSourceLanguage(source)
          ? source
          : 'auto';
      _translateTargetLanguage = _containsTargetLanguage(target)
          ? target
          : 'zh-CN';
      // 语言自动检测后同步切换对应的翻译服务
      _syncProviderWithDirection();
    });
  }

  SubtitleTranslateProvider _providerFromName(String? name) {
    if (name == null || name.isEmpty) return _translateProvider;
    for (final provider in SubtitleTranslateProvider.values) {
      if (provider.name == name) return provider;
    }
    return _translateProvider;
  }

  /// 根据当前语言方向自动切换 UI 上显示的翻译服务：
  /// 中英方向显示 [_translateProviderEnZh]，其他语言方向显示 [_translateProviderOther]。
  void _syncProviderWithDirection() {
    final isEnZh = _subtitleTranslationService.isEnZhDirection(
      _translateSourceLanguage,
      _translateTargetLanguage,
    );
    _translateProvider = isEnZh
        ? _translateProviderEnZh
        : _translateProviderOther;
  }

  void _onManualPromptChanged() {
    if (_isApplyingTranslatePrefs) return;
    _scheduleTranslatePrefsSave();
  }

  void _scheduleTranslatePrefsSave() {
    _translatePrefsSaveDebounce?.cancel();
    _translatePrefsSaveDebounce = Timer(const Duration(milliseconds: 260), () {
      _saveTranslatePanelPreferences();
    });
  }

  Future<void> _saveTranslatePanelPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKeyTranslateMode, _manualTranslateMode);
      // 保存当前方向对应的服务（同时保存旧键兼容，及双方向键）
      await prefs.setString(_prefKeyTranslateProvider, _translateProvider.name);
      await prefs.setString(
        _prefKeyTranslateProviderEnZh,
        _translateProviderEnZh.name,
      );
      await prefs.setString(
        _prefKeyTranslateProviderOther,
        _translateProviderOther.name,
      );
      await prefs.setBool(
        _prefKeyManualPromptOrder,
        _manualPromptSubtitleFirst,
      );
      await prefs.setString(
        _prefKeyManualPromptEditable,
        _manualPromptController.text,
      );
    } catch (e) {
      debugPrint('Error saving translate panel preferences: $e');
    }
  }

  Future<void> _loadTranslatePanelPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final savedEnZhStr = prefs.getString(_prefKeyTranslateProviderEnZh);
      final savedOtherStr = prefs.getString(_prefKeyTranslateProviderOther);
      final savedEnZh = _providerFromName(savedEnZhStr);
      final savedOther = _providerFromName(savedOtherStr);
      final hasSavedEnZh = savedEnZhStr != null;
      final hasSavedOther = savedOtherStr != null;
      final savedManualMode =
          prefs.getBool(_prefKeyTranslateMode) ?? _manualTranslateMode;
      final savedPromptOrder =
          prefs.getBool(_prefKeyManualPromptOrder) ??
          _manualPromptSubtitleFirst;
      final savedEditablePrompt =
          prefs.getString(_prefKeyManualPromptEditable) ??
          _manualPromptEditableDefault;

      if (!mounted) return;
      setState(() {
        // 双方向服务默认均为 MyMemory；
        // 仅当用户在 UI 中手动改过对应方向时才沿用其保存值。
        _translateProviderEnZh = hasSavedEnZh
            ? savedEnZh
            : SubtitleTranslateProvider.mymemory;
        _translateProviderOther = hasSavedOther
            ? savedOther
            : SubtitleTranslateProvider.mymemory;
        // UI 当前显示的服务 = 根据当前语言方向自动选择
        _translateProvider =
            _subtitleTranslationService.isEnZhDirection(
              _translateSourceLanguage,
              _translateTargetLanguage,
            )
            ? _translateProviderEnZh
            : _translateProviderOther;
        _manualTranslateMode = savedManualMode;
        _manualPromptSubtitleFirst = savedPromptOrder;
      });

      _isApplyingTranslatePrefs = true;
      _manualPromptController.text = savedEditablePrompt;
      _isApplyingTranslatePrefs = false;
    } catch (e) {
      debugPrint('Error loading translate panel preferences: $e');
    }
  }

  Future<void> _openDownloadDirectory() async {
    try {
      final dir = await _resolveDownloadTargetDir();
      final path = dir.path;
      if (Platform.isWindows) {
        await Process.run('explorer', [path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [path]);
      } else {
        // Android fallback (open file manager not easily supported via Intent without plugin)
        // Try OpenFilex if it's a directory? OpenFilex usually opens files.
        // For now, just show toast on mobile if not supported
        AppToast.show("已保存至: $path", type: AppToastType.info);
      }
    } catch (e) {
      AppToast.show("无法打开文件夹", type: AppToastType.error);
    }
  }

  @override
  void didUpdateWidget(SubtitleManagementSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.videoPath != oldWidget.videoPath) {
      setState(() {
        _isScanningFiles = true;
        _isScanningEmbedded = widget.showEmbeddedSubtitles;
        _subtitleFiles = [];
        _subtitleFileSizes.clear();
        _sidecarSubtitlePaths.clear();
        _embeddedTracks = [];
        _extractingTrackIndex = null;
        _selectedPaths = _normalizeSelectedPaths(widget.initialSelectedPaths);
        _extractedTrackPaths.clear();
      });
      _loadSubtitles();
      return;
    }
    if (widget.initialSelectedPaths != oldWidget.initialSelectedPaths) {
      // Only update if the lengths or contents differ
      bool changed =
          widget.initialSelectedPaths.length !=
          oldWidget.initialSelectedPaths.length;
      if (!changed) {
        for (int i = 0; i < widget.initialSelectedPaths.length; i++) {
          if (widget.initialSelectedPaths[i] !=
              oldWidget.initialSelectedPaths[i]) {
            changed = true;
            break;
          }
        }
      }

      if (changed) {
        setState(() {
          _selectedPaths = _normalizeSelectedPaths(widget.initialSelectedPaths);
        });
      }
    }
  }

  Future<void> _loadSubtitles() async {
    final generation = ++_scanGeneration;
    final settings = SettingsService();
    final embeddedService = Provider.of<EmbeddedSubtitleService>(
      context,
      listen: false,
    );
    if (mounted) {
      setState(() {
        _isScanningFiles = true;
        _isScanningEmbedded = widget.showEmbeddedSubtitles;
      });
    }
    unawaited(_loadEmbeddedTracks(generation, embeddedService));

    try {
      _extractedTrackPaths.clear();
      _taskSubtitlePaths.clear();
      final videoName = p.basenameWithoutExtension(widget.videoPath);
      final extractedPrefixes = <String>{
        videoName,
        if (widget.videoId != null && widget.videoId!.trim().isNotEmpty)
          widget.videoId!.trim(),
      };

      final discovered = await const SubtitleDiscoveryService()
          .scanVideoDirectory(
            videoPath: widget.videoPath,
            rules: SubtitleScanRules(
              prefixMatchMode: settings.desktopSubtitlePrefixMatchMode,
              caseSensitive: settings.desktopSubtitleScanCaseSensitive,
            ),
          );
      if (!mounted || generation != _scanGeneration) return;

      final filesByPath = <String, File>{};
      final modifiedByPath = <String, DateTime>{};
      for (final entry in discovered) {
        final key = _normalizePath(entry.path);
        filesByPath[key] = File(entry.path);
        modifiedByPath[key] = entry.modifiedAt;
        _subtitleFileSizes[key] = entry.length;
      }
      setState(() {
        _sidecarSubtitlePaths
          ..clear()
          ..addAll(
            discovered
                .where(
                  (entry) => entry.sourceType == SubtitleSourceType.sidecar,
                )
                .map((entry) => _normalizePath(entry.path)),
          );
        _subtitleFiles = discovered.map((entry) => File(entry.path)).toList();
      });

      final videoId = widget.videoId?.trim() ?? '';
      if (videoId.isNotEmpty) {
        final taskFiles = await const TaskSubtitleStorageService()
            .listTaskSubtitles(videoId);
        if (!mounted || generation != _scanGeneration) return;
        _taskSubtitlePaths.addAll(
          taskFiles.map((file) => _normalizePath(file.path)),
        );
        await Provider.of<LibraryService>(
          context,
          listen: false,
        ).reconcileManagedSubtitleAssets(
          videoId,
          taskFiles.map((file) => file.path),
        );
        if (!mounted || generation != _scanGeneration) return;
        for (final file in taskFiles) {
          _registerExtractedTrackPath(
            file.path,
            extractedPrefixes: extractedPrefixes,
          );
          await _addFileWithMetadata(file, filesByPath, modifiedByPath);
        }
      }

      for (final path in _selectedPaths) {
        final file = File(path);
        if (await file.exists()) {
          _registerExtractedTrackPath(
            path,
            extractedPrefixes: extractedPrefixes,
          );
          if (_streamIndexFromExtractedPath(path) != null) continue;
          await _addFileWithMetadata(file, filesByPath, modifiedByPath);
        }
      }

      // Locally created/managed groups are explicit local subtitles. They may
      // live outside both the video folder and the standard subtitles folder.
      for (final path in widget.localSubtitles?.values ?? const <String>[]) {
        final file = File(path);
        if (!await file.exists()) continue;
        _registerExtractedTrackPath(path, extractedPrefixes: extractedPrefixes);
        if (_streamIndexFromExtractedPath(path) != null) continue;
        await _addFileWithMetadata(file, filesByPath, modifiedByPath);
      }

      if (!mounted || generation != _scanGeneration) return;
      final allFiles = filesByPath.values.toList()
        ..sort((first, second) {
          final firstTime = modifiedByPath[_normalizePath(first.path)];
          final secondTime = modifiedByPath[_normalizePath(second.path)];
          if (firstTime == null || secondTime == null) return 0;
          return secondTime.compareTo(firstTime);
        });
      setState(() {
        _subtitleFiles = allFiles;
        _isScanningFiles = false;
      });
    } catch (e) {
      debugPrint("Error listing subtitles: $e");
      if (mounted && generation == _scanGeneration) {
        setState(() => _isScanningFiles = false);
      }
    }
  }

  bool get _isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  Future<void> _showScanSettingsDialog() async {
    final settings = SettingsService();
    var matchMode = settings.desktopSubtitlePrefixMatchMode;
    var caseSensitive = settings.desktopSubtitleScanCaseSensitive;

    final shouldApply = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF252525),
          title: const Row(
            children: [
              Icon(Icons.manage_search, color: Colors.lightBlueAccent),
              SizedBox(width: 10),
              Text('同文件夹字幕扫描设置'),
            ],
          ),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '前缀匹配要求',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<SubtitlePrefixMatchMode>(
                  initialValue: matchMode,
                  dropdownColor: const Color(0xFF303030),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: SubtitlePrefixMatchMode.exactOrDelimited,
                      child: Text('同名或分隔后缀（推荐）'),
                    ),
                    DropdownMenuItem(
                      value: SubtitlePrefixMatchMode.exactOnly,
                      child: Text('仅完全同名（最严格）'),
                    ),
                    DropdownMenuItem(
                      value: SubtitlePrefixMatchMode.startsWith,
                      child: Text('任意相同前缀（兼容旧逻辑）'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setDialogState(() => matchMode = value);
                  },
                ),
                const SizedBox(height: 8),
                Text(switch (matchMode) {
                  SubtitlePrefixMatchMode.exactOrDelimited =>
                    '匹配 Movie.srt、Movie.zh-CN.srt；排除 Movie2.srt。',
                  SubtitlePrefixMatchMode.exactOnly =>
                    '只匹配 Movie.srt，不匹配带语言或版本后缀的字幕。',
                  SubtitlePrefixMatchMode.startsWith =>
                    '匹配所有以 Movie 开头的字幕，也可能包含 Movie2.srt。',
                }, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 12),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('区分文件名大小写'),
                  subtitle: const Text(
                    '默认关闭，更符合 Windows 和 macOS 的文件使用习惯。',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  value: caseSensitive,
                  onChanged: (value) {
                    setDialogState(() => caseSensitive = value);
                  },
                ),
                const SizedBox(height: 4),
                const Text(
                  '扫描只读取视频所在文件夹的第一层；所有符合规则的字幕都会显示在管理区。',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                setDialogState(() {
                  matchMode = SubtitleScanRules.defaults.prefixMatchMode;
                  caseSensitive = SubtitleScanRules.defaults.caseSensitive;
                });
              },
              child: const Text('恢复默认'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('保存并重新扫描'),
            ),
          ],
        ),
      ),
    );

    if (shouldApply != true) return;
    await settings.saveDesktopSubtitleScanSettings(
      prefixMatchMode: matchMode,
      caseSensitive: caseSensitive,
    );
    if (!mounted) return;
    AppToast.show('扫描设置已保存', type: AppToastType.success);
    await _loadSubtitles();
  }

  Future<void> _addFileWithMetadata(
    File file,
    Map<String, File> filesByPath,
    Map<String, DateTime> modifiedByPath,
  ) async {
    final key = _normalizePath(file.path);
    if (filesByPath.containsKey(key)) return;
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) return;
      filesByPath[key] = file;
      modifiedByPath[key] = stat.modified;
      _subtitleFileSizes[key] = stat.size;
    } on FileSystemException {
      // A file can disappear while its directory is being scanned.
    }
  }

  Future<void> _loadEmbeddedTracks(
    int generation,
    EmbeddedSubtitleService service,
  ) async {
    if (!widget.showEmbeddedSubtitles) {
      if (mounted && generation == _scanGeneration) {
        setState(() {
          _embeddedTracks = [];
          _isScanningEmbedded = false;
        });
      }
      return;
    }
    try {
      final tracks = await service.getEmbeddedSubtitles(widget.videoPath);
      if (!mounted || generation != _scanGeneration) return;
      setState(() {
        _embeddedTracks = tracks;
        _isScanningEmbedded = false;
      });
    } catch (e) {
      debugPrint('Error probing embedded subtitles: $e');
      if (mounted && generation == _scanGeneration) {
        setState(() => _isScanningEmbedded = false);
      }
    }
  }

  Future<void> _handleEmbeddedTrackSelection(
    EmbeddedSubtitleTrack track,
  ) async {
    // Check if already extracted in this session or we can guess the path
    // Actually, we should check if any selected path matches what this track WOULD produce,
    // but the naming might be variable.
    // If we have mapped it:
    if (_extractedTrackPaths.containsKey(track.index)) {
      final path = _extractedTrackPaths[track.index]!;
      _handleSelection(path);
      return;
    }

    if (_extractingTrackIndex != null) return;

    setState(() => _extractingTrackIndex = track.index);

    try {
      final videoId = _requireVideoId();
      final subDir = await const TaskSubtitleStorageService().taskDirectory(
        videoId,
        create: true,
      );

      if (mounted) {
        final service = Provider.of<EmbeddedSubtitleService>(
          context,
          listen: false,
        );
        // Pass codecName to avoid re-probing issues
        final path = await service.extractSubtitle(
          widget.videoPath,
          track.index,
          subDir.path,
          codecName: track.codecName,
          videoId: widget.videoId,
        );

        if (path != null) {
          await _registerManagedSubtitle(
            path,
            ManagedSubtitleAssetKind.embedded,
            _displayEmbeddedTitle(track),
          );
          if (mounted) {
            // Store mapping
            _extractedTrackPaths[track.index] = path;

            AppToast.show("内嵌字幕提取成功", type: AppToastType.success);
            if (_isImageSubtitleCodec(track.codecName)) {
              AppToast.show("图像字幕无法转为文本，将以位图显示", type: AppToastType.info);
            }

            _handleSelection(path);
          }
        } else {
          if (mounted) {
            AppToast.show("提取字幕失败，可能格式不支持", type: AppToastType.error);
          }
        }
      }
    } catch (e) {
      debugPrint("Error extracting: $e");
      if (mounted) {
        AppToast.show("提取出错", type: AppToastType.error);
      }
    } finally {
      if (mounted) setState(() => _extractingTrackIndex = null);
    }
  }

  Future<void> _deleteSubtitle(File file) async {
    LibraryService? library;
    try {
      library = Provider.of<LibraryService>(context, listen: false);
    } catch (_) {}

    final normalizedPath = _normalizePath(file.path);
    final isSidecar = _sidecarSubtitlePaths.contains(normalizedPath);
    final isTaskOwned = _taskSubtitlePaths.contains(normalizedPath);
    final isExternal = !isTaskOwned;
    final videoId = widget.videoId?.trim() ?? '';
    final deletionPaths = isTaskOwned && library != null && videoId.isNotEmpty
        ? library.managedSubtitleDeletionPaths(videoId, file.path)
        : <String>[file.path];

    final confirm = await showSubtitleDeletionConfirmationDialog(
      context,
      fileName: p.basename(file.path),
      isSidecar: isSidecar,
      isExternal: isExternal,
      dependentAssetCount: deletionPaths.length - 1,
    );

    if (confirm) {
      try {
        final deletedPathKeys = <String>{};
        final successfullyDeletedPaths = <String>[];
        final failedPaths = <String>[];
        final storage = const TaskSubtitleStorageService();
        for (final path in deletionPaths) {
          try {
            if (isTaskOwned && !await storage.isTaskOwnedPath(path, videoId)) {
              failedPaths.add(path);
              continue;
            }
            final target = File(path);
            if (await target.exists()) await target.delete();
            deletedPathKeys.add(_normalizePath(path));
            successfullyDeletedPaths.add(path);
          } on FileSystemException {
            failedPaths.add(path);
          }
        }
        if (isTaskOwned && library != null && videoId.isNotEmpty) {
          await library.removeManagedSubtitleAssetsByPaths(
            videoId,
            successfullyDeletedPaths,
          );
        }
        final hadDeletedSelection = _selectedPaths.any(
          (path) => deletedPathKeys.contains(_normalizePath(path)),
        );
        if (hadDeletedSelection) {
          setState(() {
            _selectedPaths.removeWhere(
              (path) => deletedPathKeys.contains(_normalizePath(path)),
            );
          });
          if (widget.onSubtitleSelected != null) {
            widget.onSubtitleSelected!(_selectedPaths);
          }
        }
        _loadSubtitles(); // Reload list
        _notifySubtitleFilesChanged();
        if (failedPaths.isNotEmpty && mounted) {
          AppToast.show(
            '有 ${failedPaths.length} 个字幕文件删除失败，请稍后重试',
            type: AppToastType.error,
          );
        }
      } catch (e) {
        if (mounted) {
          AppToast.show("删除失败", type: AppToastType.error);
        }
      }
    }
  }

  Future<Directory> _resolveDownloadTargetDir() async {
    // 1. 优先使用用户自定义路径
    if (_customDownloadPath != null) {
      final customDir = Directory(_customDownloadPath!);
      if (await customDir.exists()) {
        return customDir;
      }
    }

    if (Platform.isAndroid) {
      // 优先使用公共下载目录，方便用户通过 MT 管理器等访问
      final downloadDir = Directory('/storage/emulated/0/Download');
      if (await downloadDir.exists()) {
        return downloadDir;
      }
      final dir = await getExternalStorageDirectory();
      if (dir != null) return dir;
    }
    if (Platform.isWindows) {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final downloadDir = Directory(p.join(exeDir, 'Downloads'));
      if (!await downloadDir.exists()) {
        await downloadDir.create(recursive: true);
      }
      return downloadDir;
    }
    if (Platform.isLinux || Platform.isMacOS) {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) return downloads;
    }
    return getApplicationDocumentsDirectory();
  }

  String? _resolveMimeType(String path) {
    final ext = p.extension(path).toLowerCase();
    if (ext.isEmpty) return null;
    if ([
      '.srt',
      '.vtt',
      '.ass',
      '.ssa',
      '.lrc',
      '.scc',
      '.sub',
      '.idx',
      '.sup',
    ].contains(ext)) {
      return 'text/plain';
    }
    return null;
  }

  Future<void> _downloadSubtitleFile(String path) async {
    try {
      final sourceFile = File(path);
      if (!await sourceFile.exists()) {
        if (mounted) {
          AppToast.show("字幕文件不存在", type: AppToastType.error);
        }
        return;
      }

      Directory targetDir = await _resolveDownloadTargetDir();
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }

      final sourceDir = p.normalize(p.dirname(path));
      final targetDirPath = p.normalize(targetDir.path);
      String targetPath = path;

      if (sourceDir != targetDirPath) {
        final fileName = p.basename(path);
        String destPath = p.join(targetDir.path, fileName);
        if (await File(destPath).exists()) {
          final base = p.basenameWithoutExtension(fileName);
          final ext = p.extension(fileName);
          destPath = p.join(
            targetDir.path,
            "$base.downloaded.${DateTime.now().millisecondsSinceEpoch}$ext",
          );
        }
        await sourceFile.copy(destPath);
        targetPath = destPath;
      }

      if (Platform.isWindows) {
        // 将 /select, 和路径合并为单个参数，避免路径含空格/特殊字符时出错
        bool opened = false;
        try {
          await Process.run('explorer', ['/select,$targetPath']);
          opened = true;
        } catch (e) {
          debugPrint('explorer 打开失败，尝试 OpenFilex: $e');
        }
        if (!opened) {
          try {
            await OpenFilex.open(
              targetPath,
              type: _resolveMimeType(targetPath),
            );
          } catch (e) {
            debugPrint('OpenFilex 也失败: $e');
          }
        }
        if (mounted) {
          AppToast.show("字幕已保存", type: AppToastType.success);
        }
      } else if (Platform.isLinux || Platform.isMacOS) {
        // 桌面 Linux/macOS 优先用系统命令打开所在文件夹
        bool opened = false;
        try {
          if (Platform.isLinux) {
            await Process.run('xdg-open', [p.dirname(targetPath)]);
          } else {
            await Process.run('open', [p.dirname(targetPath)]);
          }
          opened = true;
        } catch (e) {
          debugPrint('系统命令打开失败，尝试 OpenFilex: $e');
        }
        if (!opened) {
          final result = await OpenFilex.open(
            targetPath,
            type: _resolveMimeType(targetPath),
          );
          if (mounted) {
            if (result.type == ResultType.done) {
              AppToast.show("字幕已下载并打开", type: AppToastType.success);
            } else {
              AppToast.show("字幕已保存，但打开失败", type: AppToastType.error);
            }
          }
        } else {
          if (mounted) {
            AppToast.show("字幕已保存", type: AppToastType.success);
          }
        }
      } else {
        // Android/iOS 等移动平台
        final result = await OpenFilex.open(
          targetPath,
          type: _resolveMimeType(targetPath),
        );
        if (mounted) {
          if (result.type == ResultType.done) {
            AppToast.show("字幕已下载并打开", type: AppToastType.success);
          } else {
            AppToast.show("字幕已保存，但打开失败", type: AppToastType.error);
          }
        }
      }
    } catch (e) {
      debugPrint("下载字幕失败: $e");
      if (mounted) {
        AppToast.show("下载字幕失败", type: AppToastType.error);
      }
    }
  }

  Future<void> _downloadEmbeddedTrack(EmbeddedSubtitleTrack track) async {
    if (_extractingTrackIndex != null) return;
    if (_extractedTrackPaths.containsKey(track.index)) {
      await _downloadSubtitleFile(_extractedTrackPaths[track.index]!);
      return;
    }

    setState(() => _extractingTrackIndex = track.index);

    try {
      final videoId = _requireVideoId();
      final subDir = await const TaskSubtitleStorageService().taskDirectory(
        videoId,
        create: true,
      );

      if (!mounted) return;
      final service = Provider.of<EmbeddedSubtitleService>(
        context,
        listen: false,
      );
      final path = await service.extractSubtitle(
        widget.videoPath,
        track.index,
        subDir.path,
        codecName: track.codecName,
        videoId: widget.videoId,
      );

      if (path != null) {
        await _registerManagedSubtitle(
          path,
          ManagedSubtitleAssetKind.embedded,
          _displayEmbeddedTitle(track),
        );
        _extractedTrackPaths[track.index] = path;
        await _downloadSubtitleFile(path);
      } else {
        if (mounted) {
          AppToast.show("提取字幕失败，可能格式不支持", type: AppToastType.error);
        }
      }
    } catch (e) {
      if (mounted) {
        AppToast.show("提取出错", type: AppToastType.error);
      }
    } finally {
      if (mounted) setState(() => _extractingTrackIndex = null);
    }
  }

  Future<void> _importSubtitle() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2C),
        title: const Text(
          '导入字幕',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: const Text(
          '请选择导入方式：',
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
          ),
          TextButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _importSubtitleFromFile();
            },
            icon: const Icon(
              Icons.folder_open,
              size: 18,
              color: Colors.white70,
            ),
            label: const Text('从文件导入', style: TextStyle(color: Colors.white)),
          ),
          TextButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _showManualSubtitleInputDialog();
            },
            icon: const Icon(
              Icons.edit_note,
              size: 18,
              color: Colors.blueAccent,
            ),
            label: const Text(
              '手动输入文本',
              style: TextStyle(color: Colors.blueAccent),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _importSubtitleFromFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        'srt',
        'vtt',
        'lrc',
        'ass',
        'ssa',
        'sup',
        'sub',
        'idx',
        'scc',
      ],
    );

    if (result != null && result.files.single.path != null) {
      final srcFile = File(result.files.single.path!);
      final videoId = _requireVideoId();
      final ext = p.extension(srcFile.path).toLowerCase();
      final destPath = await const TaskSubtitleStorageService().copyIntoTask(
        videoId,
        srcFile.path,
        preferredFileName:
            'imported.${DateTime.now().millisecondsSinceEpoch}$ext',
      );
      await _registerManagedSubtitle(
        destPath,
        ManagedSubtitleAssetKind.imported,
        p.basenameWithoutExtension(srcFile.path),
      );
      _loadSubtitles();
      _notifySubtitleFilesChanged();
    }
  }

  /// 生成默认手动字幕名称 (S1, S2, S3...)
  String _generateDefaultManualSubtitleName() {
    final videoName = p.basenameWithoutExtension(widget.videoPath);
    final videoId = (widget.videoId ?? '').trim();
    final prefixes = <String>{
      '$videoName.manual.',
      if (videoId.isNotEmpty) '$videoId.manual.',
    };
    int maxNum = 0;
    final reg = RegExp(r'\.manual\.S(\d+)\.');
    for (final file in _subtitleFiles) {
      final name = p.basename(file.path);
      if (!prefixes.any(name.startsWith)) continue;
      final match = reg.firstMatch(name);
      if (match != null) {
        final n = int.tryParse(match.group(1)!) ?? 0;
        if (n > maxNum) maxNum = n;
      }
    }
    return 'S${maxNum + 1}';
  }

  /// 手动输入字幕文本对话框
  Future<void> _showManualSubtitleInputDialog() async {
    final nameController = TextEditingController(
      text: _generateDefaultManualSubtitleName(),
    );
    final textController = TextEditingController();
    SubtitleFormat? detectedFormat;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final screenWidth = MediaQuery.of(ctx).size.width;
            final screenHeight = MediaQuery.of(ctx).size.height;
            final dialogWidth = (screenWidth * 0.85).clamp(320.0, 600.0);
            final dialogHeight = (screenHeight * 0.75).clamp(360.0, 640.0);

            return AlertDialog(
              backgroundColor: const Color(0xFF2C2C2C),
              contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              content: SizedBox(
                width: dialogWidth,
                height: dialogHeight,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 标题
                    const Text(
                      '手动输入字幕',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // 名称输入框
                    Row(
                      children: [
                        const Text(
                          '名称：',
                          style: TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: SizedBox(
                            height: 36,
                            child: TextField(
                              controller: nameController,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                              ),
                              decoration: InputDecoration(
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                                filled: true,
                                fillColor: Colors.white10,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(6),
                                  borderSide: BorderSide.none,
                                ),
                                hintText: '输入字幕名称',
                                hintStyle: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // 格式检测提示行 + 粘贴/清除按钮
                    Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 14,
                          color: detectedFormat != null
                              ? Colors.greenAccent
                              : Colors.white38,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          textController.text.isEmpty
                              ? '输入文本后自动识别格式'
                              : '识别格式: ${detectedFormat?.displayName ?? 'SRT'}',
                          style: TextStyle(
                            color: textController.text.isEmpty
                                ? Colors.white38
                                : (detectedFormat != null
                                      ? Colors.greenAccent
                                      : Colors.orangeAccent),
                            fontSize: 11,
                          ),
                        ),
                        const Spacer(),
                        InkWell(
                          onTap: () async {
                            await _pasteIntoController(
                              textController,
                              successMessage: '已粘贴',
                            );
                            final fmt = SubtitleParser.detectFormat(
                              textController.text,
                            );
                            setDialogState(() {
                              detectedFormat = fmt;
                            });
                          },
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.content_paste,
                                  size: 14,
                                  color: Colors.blueAccent,
                                ),
                                SizedBox(width: 2),
                                Text(
                                  '粘贴',
                                  style: TextStyle(
                                    color: Colors.blueAccent,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        InkWell(
                          onTap: () {
                            textController.clear();
                            setDialogState(() {
                              detectedFormat = null;
                            });
                          },
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.clear_all,
                                  size: 14,
                                  color: Colors.orangeAccent,
                                ),
                                SizedBox(width: 2),
                                Text(
                                  '清除',
                                  style: TextStyle(
                                    color: Colors.orangeAccent,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),

                    // 文本输入区
                    Expanded(
                      child: TextField(
                        controller: textController,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: Colors.black26,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.all(10),
                          hintText:
                              '在此粘贴或输入字幕文本...\n\n'
                              '支持 SRT / VTT / ASS / LRC 格式，将自动识别',
                          hintStyle: const TextStyle(
                            color: Colors.white24,
                            fontSize: 12,
                          ),
                        ),
                        onChanged: (value) {
                          final fmt = SubtitleParser.detectFormat(value);
                          setDialogState(() {
                            detectedFormat = fmt;
                          });
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text(
                    '取消',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
                ElevatedButton(
                  onPressed: textController.text.trim().isEmpty
                      ? null
                      : () async {
                          final name = nameController.text.trim();
                          final content = textController.text;
                          Navigator.pop(ctx);
                          await _importManualSubtitleText(
                            name.isEmpty ? 'S1' : name,
                            content,
                          );
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                  ),
                  child: const Text('导入', style: TextStyle(fontSize: 13)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 将手动输入的字幕文本保存为本地文件并刷新列表
  Future<void> _importManualSubtitleText(String name, String content) async {
    try {
      final format = SubtitleParser.detectFormat(content);
      final videoId = _requireVideoId();

      // 文件名安全处理
      final safeName = name.replaceAll(RegExp(r'[^\w\u4e00-\u9fff\-]'), '_');
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'manual.$safeName.$timestamp${format.extension}';
      final outputPath = await const TaskSubtitleStorageService().allocatePath(
        videoId,
        fileName,
      );

      await File(outputPath).writeAsString(content, flush: true);
      await _registerManagedSubtitle(
        outputPath,
        ManagedSubtitleAssetKind.manual,
        name,
      );
      await _loadSubtitles();
      _notifySubtitleFilesChanged();

      if (mounted) {
        AppToast.show(
          '字幕已导入：$name（${format.displayName}）',
          type: AppToastType.success,
        );
      }
    } catch (e) {
      if (mounted) {
        AppToast.show('导入失败：$e', type: AppToastType.error);
      }
    }
  }

  void _handleSelection(String path) {
    final normalizedPath = p.normalize(path);
    setState(() {
      final existingIndex = _selectedIndexOf(normalizedPath);
      if (existingIndex != -1) {
        _selectedPaths.removeAt(existingIndex);
      } else {
        if (_selectedPaths.length >= 2) {
          _selectedPaths.removeLast();
        }
        _selectedPaths.add(normalizedPath);
      }
    });

    if (widget.onSubtitleSelected != null) {
      widget.onSubtitleSelected!(_selectedPaths);
    }
  }

  Widget _buildSelectionBadge(String path) {
    final index = _selectedIndexOf(path);
    if (index == -1) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: index == 0 ? Colors.blueAccent : Colors.orangeAccent,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        index == 0 ? "主" : "副",
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  String _displayEmbeddedTitle(EmbeddedSubtitleTrack track) {
    final title = track.title.trim();
    if (title.isNotEmpty && title != "未知标题") return title;
    final language = track.language.trim();
    if (language.isNotEmpty && language != "未知语言") return language;
    return "内嵌字幕 ${track.index}";
  }

  String _displayEmbeddedTitleByIndex(int index) {
    for (final track in _embeddedTracks) {
      if (track.index == index) {
        return _displayEmbeddedTitle(track);
      }
    }
    return "内嵌字幕 $index";
  }

  bool _isTranslatedSubtitlePath(String path) {
    final name = p.basename(path).toLowerCase();
    return name.contains('.translated.');
  }

  String? _extractTranslatedLanguageCode(String path) {
    final name = p.basename(path);
    final match = RegExp(
      r'\.translated\.([^.]+)(?:\.\d+)?\.[^.]+$',
      caseSensitive: false,
    ).firstMatch(name);
    if (match == null) return null;
    return match.group(1);
  }

  String _translatedLanguageBadgeText(String path) {
    final code = (_extractTranslatedLanguageCode(path) ?? '').toLowerCase();
    if (code.startsWith('zh')) return '中';
    if (code.startsWith('en')) return '英';
    if (code.startsWith('ja')) return '日';
    if (code.startsWith('ko')) return '韩';
    if (code.startsWith('fr')) return '法';
    if (code.startsWith('de')) return '德';
    if (code.startsWith('es')) return '西';
    if (code.startsWith('ru')) return '俄';
    if (code.startsWith('it')) return '意';
    if (code.startsWith('pt')) return '葡';
    if (code.startsWith('ar')) return '阿';
    return '译';
  }

  Widget _buildTranslatedLanguageBadge(String path) {
    if (!_isTranslatedSubtitlePath(path)) {
      return const SizedBox.shrink();
    }
    final badge = _translatedLanguageBadgeText(path);
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.lightBlueAccent.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: Colors.lightBlueAccent.withValues(alpha: 0.5),
        ),
      ),
      child: Text(
        badge,
        style: const TextStyle(
          color: Colors.lightBlueAccent,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }

  Widget _buildSubtitleSourceBadge(String path) {
    if (!_sidecarSubtitlePaths.contains(_normalizePath(path))) {
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.greenAccent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.42)),
      ),
      child: Text(
        SubtitleSourceType.sidecar.displayName,
        style: const TextStyle(
          color: Colors.greenAccent,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }

  Widget _buildOcrBadge(ManagedSubtitleAsset? asset) {
    if (asset?.kind != ManagedSubtitleAssetKind.ocr) {
      return const SizedBox.shrink();
    }
    final language = switch (asset?.language) {
      'zh-Hans' => '中',
      'en' => '英',
      'ja' => '日',
      'ko' => '韩',
      'latin' => '拉丁',
      _ => null,
    };
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.lightBlueAccent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: Colors.lightBlueAccent.withValues(alpha: 0.45),
        ),
      ),
      child: Text(
        language == null ? 'OCR' : 'OCR · $language',
        style: const TextStyle(
          color: Colors.lightBlueAccent,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }

  List<SubtitleTranslationLanguage> get _sourceLanguageOptions => const [
    SubtitleTranslationLanguage(code: 'auto', label: '自动检测'),
    ...SubtitleTranslationService.popularLanguages,
  ];

  List<SubtitleTranslationLanguage> get _targetLanguageOptions =>
      SubtitleTranslationService.popularLanguages;

  String _languageLabelByCode(String code) {
    for (final lang in _sourceLanguageOptions) {
      if (lang.code == code) return lang.label;
    }
    for (final lang in _targetLanguageOptions) {
      if (lang.code == code) return lang.label;
    }
    return code;
  }

  String _manualPromptLockedPrefix() {
    final source = _languageLabelByCode(_translateSourceLanguage);
    final target = _languageLabelByCode(_translateTargetLanguage);
    return '任务：将字幕从【$source】翻译为【$target】。\n'
        '输出必须是纯净字幕文本（仅字幕文件内容），禁止输出任何解释或额外回复。\n\n';
  }

  String _manualFullPromptText() {
    final editable = _manualPromptController.text.trim();
    final locked = _manualPromptLockedPrefix();
    if (editable.isEmpty) return locked.trimRight();
    return '$locked$editable';
  }

  String _singleLinePreview(String value) {
    final compact = value.replaceAll('\r\n', '\n').replaceAll('\n', ' ').trim();
    if (compact.isEmpty) return '（空）';
    if (compact.length <= 80) return compact;
    return '${compact.substring(0, 80)}...';
  }

  Future<void> _copyText(String text, {String successMessage = '已复制'}) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      AppToast.show(successMessage, type: AppToastType.success);
    }
  }

  bool get _isDesktopPlatform =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  Future<void> _pasteIntoController(
    TextEditingController controller, {
    String successMessage = '已粘贴',
    bool showToast = true,
  }) async {
    final data = await Clipboard.getData('text/plain');
    final pastedText = data?.text ?? '';
    if (pastedText.isEmpty) {
      if (showToast && mounted) {
        AppToast.show('剪贴板为空', type: AppToastType.info);
      }
      return;
    }

    final currentText = controller.text;
    var start = controller.selection.start;
    var end = controller.selection.end;

    if (start < 0 || end < 0) {
      start = currentText.length;
      end = currentText.length;
    }
    if (start > end) {
      final temp = start;
      start = end;
      end = temp;
    }

    final nextText = currentText.replaceRange(start, end, pastedText);
    final caret = start + pastedText.length;

    controller.value = controller.value.copyWith(
      text: nextText,
      selection: TextSelection.collapsed(offset: caret),
      composing: TextRange.empty,
    );

    if (showToast && mounted) {
      AppToast.show(successMessage, type: AppToastType.success);
    }
  }

  Future<void> _prepareManualSource(String path) async {
    final normalized = p.normalize(path);
    if (_manualLoadedSourcePath == normalized &&
        _manualSourceController.text.isNotEmpty) {
      return;
    }
    if (mounted) {
      setState(() {
        _isLoadingManualSource = true;
      });
    }
    try {
      final content = await File(path).readAsString();
      if (!mounted) return;
      setState(() {
        _manualSourceController.text = content;
        _manualLoadedSourcePath = normalized;
      });
    } catch (e) {
      if (mounted) {
        AppToast.show('读取字幕内容失败：$e', type: AppToastType.error);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingManualSource = false;
        });
      }
    }
  }

  Future<void> _showManualSourceEditor() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      enableDrag: true,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.55,
          minChildSize: 0.35,
          maxChildSize: 0.85,
          expand: false,
          builder: (context, scrollController) {
            return Padding(
              padding: EdgeInsets.only(
                left: 12,
                right: 12,
                top: 12,
                bottom: MediaQuery.of(context).viewInsets.bottom + 12,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '字幕全文（可复制）',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: TextField(
                      controller: _manualSourceController,
                      readOnly: true,
                      maxLines: null,
                      expands: true,
                      scrollController: scrollController,
                      style: const TextStyle(
                        color: Colors.white,
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: '字幕内容为空',
                        hintStyle: TextStyle(color: Colors.white38),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showManualPromptEditor() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      enableDrag: true,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.65,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            final source = _languageLabelByCode(_translateSourceLanguage);
            final target = _languageLabelByCode(_translateTargetLanguage);
            return Padding(
              padding: EdgeInsets.only(
                left: 12,
                right: 12,
                top: 12,
                bottom: MediaQuery.of(context).viewInsets.bottom + 12,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '提示词（前缀锁定）',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: RichText(
                      text: TextSpan(
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          height: 1.45,
                        ),
                        children: [
                          const TextSpan(text: '任务：将字幕从【'),
                          TextSpan(
                            text: source,
                            style: const TextStyle(
                              color: Colors.lightBlueAccent,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const TextSpan(text: '】翻译为【'),
                          TextSpan(
                            text: target,
                            style: const TextStyle(
                              color: Colors.amberAccent,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const TextSpan(
                            text: '】。\n输出必须是纯净字幕文本（仅字幕文件内容），禁止输出任何解释或额外回复。\n\n',
                          ),
                          const TextSpan(
                            text: '（以上为锁定前缀，随语言自动更新，不可编辑）',
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: TextField(
                      controller: _manualPromptController,
                      maxLines: null,
                      expands: true,
                      scrollController: scrollController,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: '可编辑提示词',
                        alignLabelWithHint: true,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showManualHelpDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2C),
        title: const Text('手动翻译帮助', style: TextStyle(color: Colors.white)),
        content: const Text(
          '建议先复制“字幕全文 + 提示词”，粘贴到你的 AI 助手中。\n\n'
          '你可以在提示词中手动补充：\n'
          '1) 希望 AI 扮演的角色（如影视本地化译审）。\n'
          '2) 特殊术语、专有名词、人名地名的固定译法。\n'
          '3) 语气风格要求（口语化/正式/简洁等）。\n\n'
          '请始终要求 AI 仅返回纯字幕文本，避免任何解释性内容。',
          style: TextStyle(color: Colors.white70, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _showManualResultInputDialog(String sourcePath) async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final screenWidth = MediaQuery.of(ctx).size.width;
            final screenHeight = MediaQuery.of(ctx).size.height;
            final dialogWidth = (screenWidth * 0.85).clamp(320.0, 600.0);
            final dialogHeight = (screenHeight * 0.75).clamp(360.0, 640.0);

            return AlertDialog(
              backgroundColor: const Color(0xFF2C2C2C),
              contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              content: SizedBox(
                width: dialogWidth,
                height: dialogHeight,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 标题
                    const Text(
                      '输入翻译结果',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // 提示行 + 粘贴/清除按钮
                    Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 14,
                          color: controller.text.isEmpty
                              ? Colors.white38
                              : Colors.greenAccent,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          controller.text.isEmpty
                              ? '在此粘贴 AI 返回的完整字幕文本'
                              : '已输入 ${controller.text.length} 字符',
                          style: TextStyle(
                            color: controller.text.isEmpty
                                ? Colors.white38
                                : Colors.greenAccent,
                            fontSize: 11,
                          ),
                        ),
                        const Spacer(),
                        InkWell(
                          onTap: () async {
                            await _pasteIntoController(
                              controller,
                              successMessage: '已粘贴翻译结果',
                            );
                            setDialogState(() {});
                          },
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.content_paste,
                                  size: 14,
                                  color: Colors.blueAccent,
                                ),
                                SizedBox(width: 2),
                                Text(
                                  '粘贴',
                                  style: TextStyle(
                                    color: Colors.blueAccent,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        InkWell(
                          onTap: () {
                            controller.clear();
                            setDialogState(() {});
                          },
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.clear_all,
                                  size: 14,
                                  color: Colors.orangeAccent,
                                ),
                                SizedBox(width: 2),
                                Text(
                                  '清除',
                                  style: TextStyle(
                                    color: Colors.orangeAccent,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),

                    // 文本输入区
                    Expanded(
                      child: GestureDetector(
                        onSecondaryTapDown: _isDesktopPlatform
                            ? (_) {
                                _pasteIntoController(
                                  controller,
                                  showToast: false,
                                );
                                setDialogState(() {});
                              }
                            : null,
                        child: TextField(
                          controller: controller,
                          maxLines: null,
                          expands: true,
                          textAlignVertical: TextAlignVertical.top,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: Colors.black26,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(6),
                              borderSide: BorderSide.none,
                            ),
                            contentPadding: const EdgeInsets.all(10),
                            hintText: '在此粘贴 AI 返回的完整字幕文本...',
                            hintStyle: const TextStyle(
                              color: Colors.white24,
                              fontSize: 12,
                            ),
                          ),
                          onChanged: (_) => setDialogState(() {}),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text(
                    '取消',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
                ElevatedButton(
                  onPressed: controller.text.trim().isEmpty
                      ? null
                      : () => Navigator.pop(ctx, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                  ),
                  child: const Text('确认导入', style: TextStyle(fontSize: 13)),
                ),
              ],
            );
          },
        );
      },
    );

    final text = controller.text;
    controller.dispose();

    if (confirmed != true) return;
    if (text.trim().isEmpty) {
      if (mounted) {
        AppToast.show('请输入翻译结果', type: AppToastType.error);
      }
      return;
    }

    await _importManualTranslatedSubtitle(sourcePath, text);
  }

  Future<void> _importManualTranslatedSubtitle(
    String sourcePath,
    String content,
  ) async {
    try {
      final videoId = _requireVideoId();
      final sourceName = p.basenameWithoutExtension(sourcePath);
      final sourceExt = p.extension(sourcePath).toLowerCase();
      final ext = sourceExt.isEmpty ? '.srt' : sourceExt;
      final safeTarget = _translateTargetLanguage.replaceAll(
        RegExp(r'[^a-zA-Z0-9_-]'),
        '-',
      );
      final outputName =
          '$sourceName.manual.translated.$safeTarget.${DateTime.now().millisecondsSinceEpoch}$ext';
      final outputPath = await const TaskSubtitleStorageService().allocatePath(
        videoId,
        outputName,
      );

      await File(outputPath).writeAsString(content, flush: true);
      await _registerManagedSubtitle(
        outputPath,
        ManagedSubtitleAssetKind.translated,
        '$sourceName（手动翻译）',
        sourcePath: sourcePath,
        language: _translateTargetLanguage,
      );
      await _loadSubtitles();
      _notifySubtitleFilesChanged();

      if (mounted) {
        setState(() {
          _expandedTranslatePath = null;
        });
      }

      if (Platform.isWindows) {
        try {
          await Process.run('explorer', ['/select,', outputPath]);
        } catch (_) {}
      }

      if (mounted) {
        AppToast.show(
          '手动翻译字幕已导入：${p.basename(outputPath)}',
          type: AppToastType.success,
        );
      }
    } catch (e) {
      if (mounted) {
        AppToast.show('导入失败：$e', type: AppToastType.error);
      }
    }
  }

  Widget _buildManualInputRow({
    required String title,
    required String preview,
    required VoidCallback onTap,
    required VoidCallback onCopy,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(
              Icons.copy_all_rounded,
              color: Colors.white70,
              size: 17,
            ),
            tooltip: '复制',
            onPressed: onCopy,
          ),
        ],
      ),
    );
  }

  void _toggleTranslatePanel(String path) {
    if (_isActiveTranslationForCurrentVideo()) {
      return;
    }
    final nextPath = _isTranslationPanelExpandedFor(path) ? null : path;
    setState(() {
      _expandedTranslatePath = nextPath;
    });
    if (nextPath != null) {
      _prepareManualSource(nextPath);
      _applySmartLanguageDefaultsForPath(nextPath);
    }
  }

  Future<void> _translateSubtitle(String path) async {
    // 防止对同一视频重复发起翻译。
    if (_isPathTranslating(path)) return;

    // 翻译状态由服务（单例）持有并在内部管理；
    // 完成后的刷新/toast 由 _onTranslationComplete 回调统一处理，
    // 因此即便本页面中途销毁，重开后仍能恢复进度并在完成时收到事件。
    try {
      final videoId = _requireVideoId();
      final library = Provider.of<LibraryService>(context, listen: false);
      final sourceAssetId = library
          .managedSubtitleAssetForPath(videoId, path)
          ?.assetId;
      final taskDirectory = await const TaskSubtitleStorageService()
          .taskDirectory(videoId, create: true);
      // 根据源/目标语言方向自动选择翻译服务：
      // 中英方向用 _translateProviderEnZh，其他语言方向用 _translateProviderOther
      final effectiveProvider =
          _subtitleTranslationService.isEnZhDirection(
            _translateSourceLanguage,
            _translateTargetLanguage,
          )
          ? _translateProviderEnZh
          : _translateProviderOther;
      final result = await _subtitleTranslationService.translateSubtitleFile(
        inputPath: path,
        sourceLanguage: _translateSourceLanguage,
        targetLanguage: _translateTargetLanguage,
        provider: effectiveProvider,
        videoPath: widget.videoPath,
        outputDirectory: taskDirectory.path,
        outputFilePrefix: p.basenameWithoutExtension(path),
        onProgress: (_) {
          // 进度由服务统一通过 ChangeNotifier 通知，这里无需额外处理。
        },
      );
      await library.registerManagedSubtitleAsset(
        videoId,
        path: result.outputPath,
        kind: ManagedSubtitleAssetKind.translated,
        displayName: '${p.basenameWithoutExtension(path)}（翻译）',
        sourceAssetId: sourceAssetId,
        language: _translateTargetLanguage,
      );
      if (mounted) {
        await _loadSubtitles();
      }
      // 完成事件由 _onTranslationComplete 处理，无需在此重复。
    } catch (_) {
      // 失败事件由 _onTranslationComplete 处理。
    }
  }

  Widget _buildTranslateAction({required String path, required bool enabled}) {
    return IconButton(
      icon: const Icon(
        Icons.translate,
        color: Colors.lightBlueAccent,
        size: 18,
      ),
      tooltip: "翻译字幕",
      onPressed: enabled ? () => _toggleTranslatePanel(path) : null,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
    );
  }

  // 构建内嵌字幕的翻译按钮
  Widget _buildEmbeddedTranslateButton(EmbeddedSubtitleTrack track) {
    final isExtracted = _extractedTrackPaths.containsKey(track.index);
    final isExtracting = _extractingTrackIndex == track.index;

    return IconButton(
      icon: const Icon(
        Icons.translate,
        color: Colors.lightBlueAccent,
        size: 18,
      ),
      tooltip: isExtracted ? "翻译字幕" : "提取并翻译字幕",
      onPressed: isExtracting ? null : () => _handleEmbeddedTranslate(track),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
    );
  }

  // 处理内嵌字幕的翻译：已提取则直接翻译，未提取则先提取再翻译
  Future<void> _handleEmbeddedTranslate(EmbeddedSubtitleTrack track) async {
    // 如果已经提取过，直接打开翻译面板
    if (_extractedTrackPaths.containsKey(track.index)) {
      _toggleTranslatePanel(_extractedTrackPaths[track.index]!);
      return;
    }

    // 否则先提取，再打开翻译面板
    await _extractAndTranslate(track);
  }

  // 提取字幕并打开翻译面板
  Future<void> _extractAndTranslate(EmbeddedSubtitleTrack track) async {
    if (_extractingTrackIndex != null) return;

    setState(() => _extractingTrackIndex = track.index);

    try {
      final videoId = _requireVideoId();
      final subDir = await const TaskSubtitleStorageService().taskDirectory(
        videoId,
        create: true,
      );

      if (!mounted) return;
      final service = Provider.of<EmbeddedSubtitleService>(
        context,
        listen: false,
      );
      final path = await service.extractSubtitle(
        widget.videoPath,
        track.index,
        subDir.path,
        codecName: track.codecName,
        videoId: widget.videoId,
      );

      if (path != null && mounted) {
        await _registerManagedSubtitle(
          path,
          ManagedSubtitleAssetKind.embedded,
          _displayEmbeddedTitle(track),
        );
        // 保存提取路径
        setState(() {
          _extractedTrackPaths[track.index] = path;
        });

        AppToast.show("内嵌字幕提取成功，正在打开翻译面板...", type: AppToastType.success);

        // 打开翻译面板
        _toggleTranslatePanel(path);
      } else {
        if (mounted) {
          AppToast.show("提取字幕失败，可能格式不支持", type: AppToastType.error);
        }
      }
    } catch (e) {
      if (mounted) {
        AppToast.show("提取出错: $e", type: AppToastType.error);
      }
    } finally {
      if (mounted) setState(() => _extractingTrackIndex = null);
    }
  }

  Widget _buildTranslationPanel({required String path, required bool enabled}) {
    // 即使面板未展开，若该字幕正在翻译（含重开页面后恢复的进度），也显示精简进度条。
    if (!_isTranslationPanelExpandedFor(path)) {
      if (_isPathTranslating(path)) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          child: Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: LinearProgressIndicator(
                  value: _subtitleTranslationService.progress,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${(100 * _subtitleTranslationService.progress).toStringAsFixed(0)}%',
                style: const TextStyle(color: Colors.white60, fontSize: 11),
              ),
            ],
          ),
        );
      }
      return const SizedBox.shrink();
    }

    final busy = _isPathTranslating(path);

    final sourcePreview = _isLoadingManualSource
        ? '正在读取字幕全文...'
        : _singleLinePreview(_manualSourceController.text);
    final promptPreview = _singleLinePreview(_manualFullPromptText());

    final orderedRows = _manualPromptSubtitleFirst
        ? [
            _buildManualInputRow(
              title: '提示词（点击展开）',
              preview: promptPreview,
              onTap: _showManualPromptEditor,
              onCopy: () =>
                  _copyText(_manualFullPromptText(), successMessage: '提示词已复制'),
            ),
            _buildManualInputRow(
              title: '字幕全文（点击展开）',
              preview: sourcePreview,
              onTap: _showManualSourceEditor,
              onCopy: () => _copyText(
                _manualSourceController.text,
                successMessage: '字幕全文已复制',
              ),
            ),
          ]
        : [
            _buildManualInputRow(
              title: '字幕全文（点击展开）',
              preview: sourcePreview,
              onTap: _showManualSourceEditor,
              onCopy: () => _copyText(
                _manualSourceController.text,
                successMessage: '字幕全文已复制',
              ),
            ),
            _buildManualInputRow(
              title: '提示词（点击展开）',
              preview: promptPreview,
              onTap: _showManualPromptEditor,
              onCopy: () =>
                  _copyText(_manualFullPromptText(), successMessage: '提示词已复制'),
            ),
          ];

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '字幕翻译',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Text(
                '自动',
                style: TextStyle(color: Colors.white60, fontSize: 11),
              ),
              Switch(
                value: _manualTranslateMode,
                onChanged: busy
                    ? null
                    : (v) {
                        setState(() {
                          _manualTranslateMode = v;
                        });
                        _scheduleTranslatePrefsSave();
                      },
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              const Text(
                '手动',
                style: TextStyle(color: Colors.white60, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 4),
          DropdownButtonFormField<String>(
            initialValue: _translateSourceLanguage,
            decoration: const InputDecoration(
              labelText: '当前字幕语言',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            dropdownColor: const Color(0xFF2A2A2A),
            style: const TextStyle(color: Colors.white, fontSize: 12),
            items: _sourceLanguageOptions
                .map(
                  (lang) => DropdownMenuItem<String>(
                    value: lang.code,
                    child: Text(
                      lang.label,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                )
                .toList(),
            onChanged: busy
                ? null
                : (value) {
                    if (value == null) return;
                    setState(() {
                      _translateSourceLanguage = value;
                      _syncProviderWithDirection();
                    });
                  },
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _translateTargetLanguage,
            decoration: const InputDecoration(
              labelText: '翻译字幕语言',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            dropdownColor: const Color(0xFF2A2A2A),
            style: const TextStyle(color: Colors.white, fontSize: 12),
            items: _targetLanguageOptions
                .map(
                  (lang) => DropdownMenuItem<String>(
                    value: lang.code,
                    child: Text(
                      lang.label,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                )
                .toList(),
            onChanged: busy
                ? null
                : (value) {
                    if (value == null) return;
                    setState(() {
                      _translateTargetLanguage = value;
                      _syncProviderWithDirection();
                    });
                  },
          ),
          const SizedBox(height: 8),
          if (!_manualTranslateMode &&
              _translateProvider == SubtitleTranslateProvider.so360 &&
              !_subtitleTranslationService.isSo360DirectionSupported(
                _translateSourceLanguage,
                _translateTargetLanguage,
              )) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.orange, width: 0.5),
              ),
              child: const Text(
                '360 翻译仅支持中英互译（英语⇄简体/繁体中文），当前语言方向请改用 Reverso 或 MyMemory 翻译',
                style: TextStyle(color: Colors.orange, fontSize: 11),
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (!_manualTranslateMode &&
              _translateProvider == SubtitleTranslateProvider.reverso &&
              (Platform.isAndroid || Platform.isIOS)) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.orange, width: 0.5),
              ),
              child: const Text(
                'Reverso 翻译仅支持桌面端（依赖系统 curl），移动端请改用 MyMemory 翻译',
                style: TextStyle(color: Colors.orange, fontSize: 11),
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (!_manualTranslateMode) ...[
            DropdownButtonFormField<SubtitleTranslateProvider>(
              initialValue: _translateProvider,
              decoration: const InputDecoration(
                labelText: '翻译服务',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              dropdownColor: const Color(0xFF2A2A2A),
              style: const TextStyle(color: Colors.white, fontSize: 12),
              items: const [
                DropdownMenuItem(
                  value: SubtitleTranslateProvider.mymemory,
                  child: Text('MyMemory 翻译', style: TextStyle(fontSize: 12)),
                ),
                DropdownMenuItem(
                  value: SubtitleTranslateProvider.so360,
                  child: Text('360 翻译（中英）', style: TextStyle(fontSize: 12)),
                ),
                DropdownMenuItem(
                  value: SubtitleTranslateProvider.reverso,
                  child: Text('Reverso 翻译', style: TextStyle(fontSize: 12)),
                ),
                DropdownMenuItem(
                  value: SubtitleTranslateProvider.google,
                  child: Text('Google 翻译', style: TextStyle(fontSize: 12)),
                ),
                DropdownMenuItem(
                  value: SubtitleTranslateProvider.bing,
                  child: Text('微软翻译', style: TextStyle(fontSize: 12)),
                ),
              ],
              onChanged: busy
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() {
                        _translateProvider = value;
                        // 将修改保存到当前语言方向对应的服务键
                        if (_subtitleTranslationService.isEnZhDirection(
                          _translateSourceLanguage,
                          _translateTargetLanguage,
                        )) {
                          _translateProviderEnZh = value;
                        } else {
                          _translateProviderOther = value;
                        }
                      });
                      _scheduleTranslatePrefsSave();
                    },
            ),
            const SizedBox(height: 10),
            if (busy) ...[
              LinearProgressIndicator(
                value: _subtitleTranslationService.progress,
              ),
              const SizedBox(height: 6),
              Text(
                '翻译中 ${(100 * _subtitleTranslationService.progress).toStringAsFixed(0)}%',
                style: const TextStyle(color: Colors.white60, fontSize: 11),
              ),
              const SizedBox(height: 8),
            ],
            ElevatedButton.icon(
              onPressed: (!enabled || busy)
                  ? null
                  : () => _translateSubtitle(path),
              icon: const Icon(Icons.translate, size: 16),
              label: Text(
                '翻译为 ${_languageLabelByCode(_translateTargetLanguage)}',
                style: const TextStyle(fontSize: 12),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.lightBlueAccent,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ] else ...[
            ...orderedRows,
            Row(
              children: [
                TextButton.icon(
                  onPressed: () {
                    setState(() {
                      _manualPromptSubtitleFirst = !_manualPromptSubtitleFirst;
                    });
                    _scheduleTranslatePrefsSave();
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white70,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                  ),
                  icon: const Icon(Icons.swap_vert, size: 16),
                  label: const Text('切换顺序', style: TextStyle(fontSize: 11)),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _showManualHelpDialog,
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.lightBlueAccent,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                  ),
                  icon: const Icon(Icons.help_outline, size: 16),
                  label: const Text('帮助', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ElevatedButton.icon(
                  onPressed: () {
                    final first = _manualPromptSubtitleFirst
                        ? _manualFullPromptText()
                        : _manualSourceController.text;
                    final second = _manualPromptSubtitleFirst
                        ? _manualSourceController.text
                        : _manualFullPromptText();
                    _copyText(
                      '$first\n\n$second',
                      successMessage: '已按当前顺序复制全部内容',
                    );
                  },
                  icon: const Icon(Icons.copy_all, size: 15),
                  label: const Text('复制全部', style: TextStyle(fontSize: 11)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white10,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: enabled
                      ? () => _showManualResultInputDialog(path)
                      : null,
                  icon: const Icon(Icons.edit_note, size: 15),
                  label: const Text('输入翻译结果', style: TextStyle(fontSize: 11)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.lightBlueAccent,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shownPaths = <String>{};
    final associatedSubtitles = <String, String>{
      ...?widget.associatedSubtitles,
    };
    final classification = SubtitleClassificationIndex(
      downloadAssociatedPaths: associatedSubtitles.values,
      extractedEmbeddedPaths: _extractedTrackPaths.values,
    );
    final localSubtitleFiles = _subtitleFiles.where((file) {
      if (classification.categoryForPath(file.path) != SubtitleCategory.local) {
        return false;
      }
      return !_extractedTrackPaths.values.any(
        (path) => _normalizePath(path) == _normalizePath(file.path),
      );
    }).toList();
    final hasEmbeddedContent =
        widget.showEmbeddedSubtitles &&
        (_embeddedTracks.isNotEmpty || _extractedTrackPaths.isNotEmpty);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: const BoxDecoration(
        color: Color(0xFF1E1E1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "字幕管理",
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const Spacer(),
              if (_isDesktop)
                Tooltip(
                  message: '扫描设置',
                  child: IconButton(
                    icon: const Icon(
                      Icons.manage_search,
                      color: Colors.white70,
                    ),
                    onPressed: _showScanSettingsDialog,
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white70),
                onPressed: () {
                  if (widget.onClose != null) {
                    widget.onClose!();
                  } else {
                    Navigator.pop(context);
                  }
                },
                constraints: const BoxConstraints(),
                padding: EdgeInsets.zero,
              ),
            ],
          ),

          if (Platform.isWindows) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.download_rounded,
                    color: Colors.white54,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Text(
                        _customDownloadPath ?? "默认: $_defaultDownloadPath",
                        style: TextStyle(
                          color: _customDownloadPath != null
                              ? Colors.white
                              : Colors.white38,
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                        maxLines: 1,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _setCustomDownloadPath,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      backgroundColor: Colors.white10,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    child: const Text("浏览", style: TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: "打开下载目录",
                    child: InkWell(
                      onTap: _openDownloadDirectory,
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.white10,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Icon(
                          Icons.folder,
                          color: Colors.amber,
                          size: 16,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 8),

          Expanded(
            child:
                (_subtitleFiles.isEmpty &&
                    !hasEmbeddedContent &&
                    associatedSubtitles.isEmpty &&
                    !_isScanningFiles &&
                    !_isScanningEmbedded)
                ? const Center(
                    child: Text(
                      "暂无关联字幕文件",
                      style: TextStyle(color: Colors.white54),
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView(
                    children: [
                      if (_isScanningFiles || _isScanningEmbedded)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.8,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _isScanningFiles
                                      ? '正在后台扫描同文件夹字幕…'
                                      : '正在后台检测内嵌字幕…',
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      // 1. Subtitles created and bound by a download task.
                      if (associatedSubtitles.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.only(bottom: 4, top: 4),
                          child: Text(
                            "媒体库关联字幕",
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        ...associatedSubtitles.entries
                            .where(
                              (entry) =>
                                  shownPaths.add(_normalizePath(entry.value)),
                            )
                            .map((entry) {
                              final label = entry.key;
                              final path = entry.value;
                              final file = File(path);
                              final exists = file.existsSync();

                              return Container(
                                margin: const EdgeInsets.only(bottom: 4),
                                decoration: BoxDecoration(
                                  color: Colors.purpleAccent.withValues(
                                    alpha: 0.1,
                                  ),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: Colors.purpleAccent.withValues(
                                      alpha: 0.2,
                                    ),
                                  ),
                                ),
                                child: Column(
                                  children: [
                                    ListTile(
                                      dense: true,
                                      visualDensity: VisualDensity.compact,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 0,
                                          ),
                                      leading: const Icon(
                                        Icons.subtitles,
                                        color: Colors.purpleAccent,
                                        size: 20,
                                      ),
                                      title: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              label,
                                              style: TextStyle(
                                                color:
                                                    _selectedIndexOf(path) == 0
                                                    ? Colors.blueAccent
                                                    : (_selectedIndexOf(path) ==
                                                              1
                                                          ? Colors.orangeAccent
                                                          : Colors.white),
                                                fontSize: 13,
                                                fontWeight:
                                                    _selectedContains(path)
                                                    ? FontWeight.bold
                                                    : FontWeight.normal,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          _buildSelectionBadge(path),
                                        ],
                                      ),
                                      subtitle: Text(
                                        exists ? "已就绪" : "文件丢失",
                                        style: TextStyle(
                                          color: exists
                                              ? Colors.white30
                                              : Colors.redAccent,
                                          fontSize: 11,
                                        ),
                                      ),
                                      selected: _selectedContains(path),
                                      selectedTileColor: Colors.white10,
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            icon: const Icon(
                                              Icons.download_outlined,
                                              color: Colors.white70,
                                              size: 18,
                                            ),
                                            onPressed: exists
                                                ? () => _downloadSubtitleFile(
                                                    path,
                                                  )
                                                : null,
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(),
                                          ),
                                          const SizedBox(width: 6),
                                          _buildTranslateAction(
                                            path: path,
                                            enabled: exists,
                                          ),
                                        ],
                                      ),
                                      onTap: exists
                                          ? () => _handleSelection(path)
                                          : null,
                                    ),
                                    _buildTranslationPanel(
                                      path: path,
                                      enabled: exists,
                                    ),
                                  ],
                                ),
                              );
                            }),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 4),
                          child: Divider(color: Colors.white10, height: 1),
                        ),
                      ],

                      // 2. Embedded Tracks Section
                      if (hasEmbeddedContent) ...[
                        const Padding(
                          padding: EdgeInsets.only(bottom: 4, top: 4),
                          child: Text(
                            "内嵌字幕 (点击提取)",
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        if (_embeddedTracks.isEmpty) ...[
                          ..._extractedTrackPaths.entries
                              .where(
                                (e) => shownPaths.add(_normalizePath(e.value)),
                              )
                              .where(
                                (e) =>
                                    classification.categoryForPath(e.value) ==
                                    SubtitleCategory.embedded,
                              )
                              .map((entry) {
                                final trackIndex = entry.key;
                                final path = entry.value;
                                final exists = File(path).existsSync();
                                return Container(
                                  margin: const EdgeInsets.only(bottom: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.blueAccent.withValues(
                                      alpha: 0.1,
                                    ),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: Colors.blueAccent.withValues(
                                        alpha: 0.2,
                                      ),
                                    ),
                                  ),
                                  child: Column(
                                    children: [
                                      ListTile(
                                        dense: true,
                                        visualDensity: VisualDensity.compact,
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 0,
                                            ),
                                        leading: const Icon(
                                          Icons.closed_caption,
                                          color: Colors.blueAccent,
                                          size: 20,
                                        ),
                                        title: Text(
                                          _displayEmbeddedTitleByIndex(
                                            trackIndex,
                                          ),
                                          style: TextStyle(
                                            color: _selectedContains(path)
                                                ? Colors.blueAccent
                                                : Colors.white,
                                            fontSize: 13,
                                            fontWeight: _selectedContains(path)
                                                ? FontWeight.bold
                                                : FontWeight.normal,
                                          ),
                                        ),
                                        subtitle: Text(
                                          exists ? p.basename(path) : "文件丢失",
                                          style: TextStyle(
                                            color: exists
                                                ? Colors.white30
                                                : Colors.redAccent,
                                            fontSize: 11,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            IconButton(
                                              icon: const Icon(
                                                Icons.download_outlined,
                                                color: Colors.white70,
                                                size: 18,
                                              ),
                                              onPressed: exists
                                                  ? () => _downloadSubtitleFile(
                                                      path,
                                                    )
                                                  : null,
                                              padding: EdgeInsets.zero,
                                              constraints:
                                                  const BoxConstraints(),
                                            ),
                                            const SizedBox(width: 6),
                                            _buildTranslateAction(
                                              path: path,
                                              enabled: exists,
                                            ),
                                            const SizedBox(width: 6),
                                            _buildSelectionBadge(path),
                                          ],
                                        ),
                                        onTap: exists
                                            ? () => _handleSelection(path)
                                            : null,
                                      ),
                                      _buildTranslationPanel(
                                        path: path,
                                        enabled: exists,
                                      ),
                                    ],
                                  ),
                                );
                              }),
                        ],
                        ..._embeddedTracks.map((track) {
                          final isImage = _isImageSubtitleCodec(
                            track.codecName,
                          );
                          // 获取提取后的路径（如果已提取）
                          final extractedPath =
                              _extractedTrackPaths[track.index];
                          final exists =
                              extractedPath != null &&
                              File(extractedPath).existsSync();

                          return Container(
                            margin: const EdgeInsets.only(bottom: 4),
                            decoration: BoxDecoration(
                              color: Colors.blueAccent.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: Colors.blueAccent.withValues(alpha: 0.2),
                              ),
                            ),
                            child: Column(
                              children: [
                                ListTile(
                                  dense: true,
                                  visualDensity: VisualDensity.compact,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 0,
                                  ),
                                  leading:
                                      (_extractingTrackIndex == track.index)
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(
                                          Icons.closed_caption,
                                          color: Colors.blueAccent,
                                          size: 20,
                                        ),
                                  title: Text(
                                    _displayEmbeddedTitle(track),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                    ),
                                  ),
                                  subtitle: Text(
                                    "${track.language} • ${track.codecName}${isImage ? " • 图像字幕" : ""}",
                                    style: const TextStyle(
                                      color: Colors.white30,
                                      fontSize: 11,
                                    ),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        icon: const Icon(
                                          Icons.download_outlined,
                                          color: Colors.white70,
                                          size: 18,
                                        ),
                                        onPressed:
                                            _extractingTrackIndex == track.index
                                            ? null
                                            : () =>
                                                  _downloadEmbeddedTrack(track),
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                      ),
                                      const SizedBox(width: 4),
                                      // 翻译按钮：已提取则直接翻译，未提取则先提取再翻译
                                      _buildEmbeddedTranslateButton(track),
                                      const SizedBox(width: 4),
                                      if (extractedPath != null)
                                        _buildSelectionBadge(extractedPath),
                                    ],
                                  ),
                                  onTap: () =>
                                      _handleEmbeddedTrackSelection(track),
                                ),
                                // 添加翻译面板（如果已展开）
                                if (extractedPath != null)
                                  _buildTranslationPanel(
                                    path: extractedPath,
                                    enabled: exists,
                                  ),
                              ],
                            ),
                          );
                        }),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 4),
                          child: Divider(color: Colors.white10, height: 1),
                        ),
                      ],

                      // 3. All non-download, non-embedded subtitle files.
                      if (localSubtitleFiles.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.only(bottom: 4, top: 4),
                          child: Text(
                            "本地字幕",
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        ...localSubtitleFiles
                            .where(
                              (file) =>
                                  shownPaths.add(_normalizePath(file.path)),
                            )
                            .map((file) {
                              final name = p.basename(file.path);
                              final isAi = name.contains(".ai.");
                              final isManual = name.contains(".manual.");
                              ManagedSubtitleAsset? managedAsset;
                              final videoId = widget.videoId;
                              if (videoId != null && videoId.isNotEmpty) {
                                try {
                                  managedAsset =
                                      Provider.of<LibraryService>(
                                        context,
                                        listen: false,
                                      ).managedSubtitleAssetForPath(
                                        videoId,
                                        file.path,
                                      );
                                } catch (_) {}
                              }
                              final isOcr =
                                  managedAsset?.kind ==
                                  ManagedSubtitleAssetKind.ocr;
                              // 从手动字幕文件名中提取自定义名称
                              // 格式: {prefix}.manual.{customName}.{timestamp}.{ext}
                              String displayName = name;
                              if (managedAsset != null &&
                                  managedAsset.displayName.trim().isNotEmpty) {
                                displayName = managedAsset.displayName.trim();
                              }
                              if (isManual) {
                                final parts = name.split('.manual.');
                                if (parts.length > 1) {
                                  final afterManual = parts
                                      .sublist(1)
                                      .join('.manual.');
                                  // 去掉末尾的 timestamp.ext 部分
                                  final dotIdx = afterManual.lastIndexOf('.');
                                  if (dotIdx > 0) {
                                    final withoutExt = afterManual.substring(
                                      0,
                                      dotIdx,
                                    );
                                    final lastDot = withoutExt.lastIndexOf('.');
                                    if (lastDot > 0) {
                                      displayName = withoutExt.substring(
                                        0,
                                        lastDot,
                                      );
                                    } else {
                                      displayName = withoutExt;
                                    }
                                  }
                                }
                              }

                              return Container(
                                margin: const EdgeInsets.only(bottom: 4),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.05),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Column(
                                  children: [
                                    ListTile(
                                      dense: true,
                                      visualDensity: VisualDensity.compact,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 0,
                                          ),
                                      leading: Icon(
                                        isOcr
                                            ? Icons.document_scanner_outlined
                                            : isAi
                                            ? Icons.auto_awesome
                                            : (isManual
                                                  ? Icons.edit_note
                                                  : Icons.subtitles),
                                        color: isOcr
                                            ? Colors.lightBlueAccent
                                            : isAi
                                            ? Colors.blueAccent
                                            : (isManual
                                                  ? Colors.tealAccent
                                                  : Colors.white70),
                                        size: 20,
                                      ),
                                      title: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              displayName,
                                              style: TextStyle(
                                                color:
                                                    _selectedIndexOf(
                                                          file.path,
                                                        ) ==
                                                        0
                                                    ? Colors.blueAccent
                                                    : (_selectedIndexOf(
                                                                file.path,
                                                              ) ==
                                                              1
                                                          ? Colors.orangeAccent
                                                          : Colors.white),
                                                fontSize: 13,
                                                fontWeight:
                                                    _selectedContains(file.path)
                                                    ? FontWeight.bold
                                                    : FontWeight.normal,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          _buildSelectionBadge(file.path),
                                          _buildSubtitleSourceBadge(file.path),
                                          _buildOcrBadge(managedAsset),
                                          _buildTranslatedLanguageBadge(
                                            file.path,
                                          ),
                                        ],
                                      ),
                                      subtitle: Text(
                                        _subtitleFileSizes[_normalizePath(
                                                  file.path,
                                                )] !=
                                                null
                                            ? "${(_subtitleFileSizes[_normalizePath(file.path)]! / 1024).toStringAsFixed(1)} KB"
                                            : '字幕文件',
                                        style: const TextStyle(
                                          color: Colors.white30,
                                          fontSize: 11,
                                        ),
                                      ),
                                      selected: _selectedContains(file.path),
                                      selectedTileColor: Colors.white10,
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            icon: const Icon(
                                              Icons.download_outlined,
                                              color: Colors.white70,
                                              size: 18,
                                            ),
                                            onPressed: () =>
                                                _downloadSubtitleFile(
                                                  file.path,
                                                ),
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(),
                                          ),
                                          const SizedBox(width: 6),
                                          _buildTranslateAction(
                                            path: file.path,
                                            enabled: true,
                                          ),
                                          const SizedBox(width: 6),
                                          IconButton(
                                            icon: const Icon(
                                              Icons.delete_outline,
                                              color: Colors.redAccent,
                                              size: 18,
                                            ),
                                            onPressed: () =>
                                                _deleteSubtitle(file),
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(),
                                          ),
                                        ],
                                      ),
                                      onTap: () => _handleSelection(file.path),
                                    ),
                                    _buildTranslationPanel(
                                      path: file.path,
                                      enabled: true,
                                    ),
                                  ],
                                ),
                              );
                            }),
                      ],
                    ],
                  ),
          ),

          const SizedBox(height: 12),

          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _importSubtitle,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text("导入字幕", style: TextStyle(fontSize: 13)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white10,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    if (widget.onClose == null) {
                      Navigator.pop(context); // Close sheet if dialog
                    }
                    widget.onOpenAi(); // Open AI panel
                  },
                  icon: const Icon(Icons.auto_awesome, size: 18),
                  label: const Text("AI 智能字幕", style: TextStyle(fontSize: 13)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
