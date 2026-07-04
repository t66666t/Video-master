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
import '../services/settings_service.dart';
import '../services/subtitle_translation_service.dart';
import '../utils/app_toast.dart';

import 'package:shared_preferences/shared_preferences.dart';

class SubtitleManagementSheet extends StatefulWidget {
  final String videoPath;
  final String? videoId;
  final VoidCallback onSubtitleChanged;
  final VoidCallback onOpenAi;
  final Function(List<String> paths)? onSubtitleSelected;
  final Function(String path)? onSubtitlePreview; // New callback
  final VoidCallback? onClose;
  final Map<String, String>? additionalSubtitles;
  final List<String> initialSelectedPaths;
  final bool showEmbeddedSubtitles;
  final bool preferAssociatedSubtitlesOnly;

  const SubtitleManagementSheet({
    super.key,
    required this.videoPath,
    this.videoId,
    required this.onSubtitleChanged,
    required this.onOpenAi,
    this.onSubtitleSelected,
    this.onSubtitlePreview,
    this.onClose,
    this.additionalSubtitles,
    this.initialSelectedPaths = const [],
    this.showEmbeddedSubtitles = true,
    this.preferAssociatedSubtitlesOnly = false,
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
  bool _isLoading = true;
  int? _extractingTrackIndex;
  List<String> _selectedPaths = []; // Track selected items
  String? _customDownloadPath;
  String _defaultDownloadPath = "用户/下载";

  final Map<int, String> _extractedTrackPaths =
      {}; // Map track index to extracted path

  final SubtitleTranslationService _subtitleTranslationService =
      SubtitleTranslationService();
  String? _expandedTranslatePath;
  String? _translatingPath;
  bool _isTranslating = false;
  double _translateProgress = 0;
  String _translateSourceLanguage = 'en';
  String _translateTargetLanguage = 'zh-CN';
  SubtitleTranslateProvider _translateProvider = SubtitleTranslateProvider.bing;

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
    _loadSubtitles();
    _initDefaultPath();
    _loadCustomDownloadPath();
    _loadTranslatePanelPreferences();
  }

  @override
  void dispose() {
    _translatePrefsSaveDebounce?.cancel();
    _saveTranslatePanelPreferences();
    _manualPromptController.removeListener(_onManualPromptChanged);
    _manualSourceController.dispose();
    _manualPromptController.dispose();
    super.dispose();
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

    return null;
  }

  Future<String?> _detectLanguageFromSubtitleContent(String path) async {
    try {
      final text = await File(path).readAsString();
      final sample = text.length > 8000 ? text.substring(0, 8000) : text;

      final chinese = RegExp(r'[\u4E00-\u9FFF]').allMatches(sample).length;
      final kana = RegExp(r'[\u3040-\u30FF]').allMatches(sample).length;
      final hangul = RegExp(r'[\uAC00-\uD7AF]').allMatches(sample).length;
      final latin = RegExp(r'[A-Za-z]').allMatches(sample).length;

      final maxCount = [
        chinese,
        kana,
        hangul,
        latin,
      ].reduce((a, b) => a > b ? a : b);
      if (maxCount < 12) return null;

      if (kana >= chinese && kana >= hangul && kana >= latin ~/ 2) {
        return 'ja';
      }
      if (hangul >= chinese && hangul >= kana && hangul >= latin ~/ 2) {
        return 'ko';
      }
      if (chinese >= latin && chinese >= 12) {
        return 'zh-CN';
      }
      if (latin >= 16) {
        return 'en';
      }

      return null;
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
    });
  }

  SubtitleTranslateProvider _providerFromName(String? name) {
    if (name == null || name.isEmpty) return _translateProvider;
    for (final provider in SubtitleTranslateProvider.values) {
      if (provider.name == name) return provider;
    }
    return _translateProvider;
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
      await prefs.setString(_prefKeyTranslateProvider, _translateProvider.name);
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

      final savedProvider = _providerFromName(
        prefs.getString(_prefKeyTranslateProvider),
      );
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
        _translateProvider = savedProvider;
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
        _isLoading = true;
        _subtitleFiles = [];
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
    setState(() => _isLoading = true);
    try {
      _extractedTrackPaths.clear();
      // 1. Load Local Files
      final videoFile = File(widget.videoPath);
      final dir = videoFile.parent;
      final videoName = p.basenameWithoutExtension(widget.videoPath);
      final extractedPrefix = "$videoName.stream_";
      final extractedPrefixes = <String>{
        videoName,
        if (widget.videoId != null && widget.videoId!.trim().isNotEmpty)
          widget.videoId!.trim(),
      };

      if (await dir.exists()) {
        final files = dir.listSync();
        _subtitleFiles = files.whereType<File>().where((file) {
          final name = p.basename(file.path);
          if (!name.startsWith(videoName)) return false;
          if (name.startsWith(extractedPrefix)) return false;
          final ext = p.extension(file.path).toLowerCase();
          return [
            '.srt',
            '.vtt',
            '.ass',
            '.ssa',
            '.sup',
            '.lrc',
            '.sub',
            '.idx',
            '.scc',
          ].contains(ext);
        }).toList();
      }

      // 2. Load Extracted Subtitles and AI Subtitles from AppDocDir
      final dataRoot = await SettingsService().resolveLargeDataRootDir();
      final subDir = Directory(p.join(dataRoot.path, 'subtitles'));
      if (await subDir.exists()) {
        final docFiles = subDir.listSync().whereType<File>();

        // Handle Extracted Streams
        final extractedFiles = docFiles.where((file) {
          final ext = p.extension(file.path).toLowerCase();
          return _matchesCurrentVideoExtractedFile(
                file.path,
                extractedPrefixes,
              ) &&
              [
                '.srt',
                '.vtt',
                '.ass',
                '.ssa',
                '.sup',
                '.lrc',
                '.sub',
                '.idx',
                '.scc',
              ].contains(ext);
        });

        for (final file in extractedFiles) {
          _registerExtractedTrackPath(
            file.path,
            extractedPrefixes: extractedPrefixes,
          );
        }

        // Handle AI Subtitles
        final aiFileNames = <String>{
          "$videoName.ai.srt",
          if (widget.videoId != null && widget.videoId!.trim().isNotEmpty)
            "${widget.videoId!.trim()}.ai.srt",
        };
        final aiFiles = docFiles.where((file) {
          final name = p.basename(file.path);
          return aiFileNames.contains(name);
        });

        for (final file in aiFiles) {
          if (!_subtitleFiles.any((f) => f.path == file.path)) {
            _subtitleFiles.add(file);
          }
        }
      }

      final legacyDocDir = await getApplicationDocumentsDirectory();
      final legacySubDir = Directory(p.join(legacyDocDir.path, 'subtitles'));
      if (p.normalize(legacySubDir.path) != p.normalize(subDir.path) &&
          await legacySubDir.exists()) {
        final legacyFiles = legacySubDir.listSync().whereType<File>();
        for (final file in legacyFiles) {
          _registerExtractedTrackPath(
            file.path,
            extractedPrefixes: extractedPrefixes,
          );
        }
      }

      // 3. Ensure selected paths are in the list (if they exist)
      for (final path in _selectedPaths) {
        final file = File(path);
        if (await file.exists()) {
          _registerExtractedTrackPath(
            path,
            extractedPrefixes: extractedPrefixes,
          );
          final name = p.basename(path);
          if (name.contains(".stream_")) {
            continue;
          }
          if (name.startsWith(extractedPrefix)) {
            continue;
          }
          if (!_subtitleFiles.any((f) => f.path == path)) {
            _subtitleFiles.add(file);
          }
        }
      }

      // Sort by modification time (newest first)
      _subtitleFiles.sort(
        (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
      );

      // 4. Load Embedded Tracks
      if (mounted) {
        if (widget.showEmbeddedSubtitles) {
          final service = Provider.of<EmbeddedSubtitleService>(
            context,
            listen: false,
          );
          _embeddedTracks = await service.getEmbeddedSubtitles(
            widget.videoPath,
          );
        } else {
          _embeddedTracks = [];
        }
      }
    } catch (e) {
      debugPrint("Error listing subtitles: $e");
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
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
      final dataRoot = await SettingsService().resolveLargeDataRootDir();
      final subDir = Directory(p.join(dataRoot.path, 'subtitles'));
      if (!await subDir.exists()) {
        await subDir.create(recursive: true);
      }

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
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2C),
        title: const Text("删除字幕", style: TextStyle(color: Colors.white)),
        content: Text(
          "确定要删除 ${p.basename(file.path)} 吗？",
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text("删除"),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await file.delete();
        final selectedIndex = _selectedIndexOf(file.path);
        if (selectedIndex != -1) {
          setState(() {
            _selectedPaths.removeAt(selectedIndex);
          });
          if (widget.onSubtitleSelected != null) {
            widget.onSubtitleSelected!(_selectedPaths);
          }
        }
        _loadSubtitles(); // Reload list
        widget.onSubtitleChanged(); // Notify parent
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
        await Process.run('explorer', ['/select,', targetPath]);
        if (mounted) {
          AppToast.show("字幕已保存", type: AppToastType.success);
        }
      } else {
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
      final dataRoot = await SettingsService().resolveLargeDataRootDir();
      final subDir = Directory(p.join(dataRoot.path, 'subtitles'));
      if (!await subDir.exists()) {
        await subDir.create(recursive: true);
      }

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
      final videoFile = File(widget.videoPath);
      final dir = videoFile.parent;
      final videoName = p.basenameWithoutExtension(widget.videoPath);
      final ext = p.extension(srcFile.path).toLowerCase();

      // Copy to video dir so it appears in list
      final newName =
          "$videoName.imported.${DateTime.now().millisecondsSinceEpoch}$ext";
      final destPath = p.join(dir.path, newName);

      await srcFile.copy(destPath);
      _loadSubtitles();
      widget.onSubtitleChanged();
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
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2C),
        title: const Text('输入翻译结果', style: TextStyle(color: Colors.white)),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => _pasteIntoController(
                    controller,
                    successMessage: '已粘贴翻译结果',
                  ),
                  icon: const Icon(Icons.content_paste_rounded, size: 16),
                  label: const Text('粘贴', style: TextStyle(fontSize: 12)),
                ),
              ),
              GestureDetector(
                onSecondaryTapDown: _isDesktopPlatform
                    ? (_) {
                        _pasteIntoController(controller, showToast: false);
                      }
                    : null,
                child: TextField(
                  controller: controller,
                  minLines: 8,
                  maxLines: 16,
                  style: const TextStyle(
                    color: Colors.white,
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    hintText: '在此粘贴 AI 返回的完整字幕文本',
                    hintStyle: const TextStyle(color: Colors.white38),
                    suffixIcon: IconButton(
                      tooltip: '粘贴',
                      onPressed: () => _pasteIntoController(
                        controller,
                        successMessage: '已粘贴翻译结果',
                      ),
                      icon: const Icon(Icons.paste_rounded),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认导入'),
          ),
        ],
      ),
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
      final videoFile = File(widget.videoPath);
      final outputDir = videoFile.parent.path;
      final videoName = p.basenameWithoutExtension(widget.videoPath);
      final sourceExt = p.extension(sourcePath).toLowerCase();
      final ext = sourceExt.isEmpty ? '.srt' : sourceExt;
      final safeTarget = _translateTargetLanguage.replaceAll(
        RegExp(r'[^a-zA-Z0-9_-]'),
        '-',
      );
      final outputName =
          '$videoName.manual.translated.$safeTarget.${DateTime.now().millisecondsSinceEpoch}$ext';
      final outputPath = p.join(outputDir, outputName);

      await File(outputPath).writeAsString(content, flush: true);
      await _loadSubtitles();
      widget.onSubtitleChanged();

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
    if (_isTranslating) return;
    final nextPath = _expandedTranslatePath == path ? null : path;
    setState(() {
      _expandedTranslatePath = nextPath;
    });
    if (nextPath != null) {
      _prepareManualSource(nextPath);
      _applySmartLanguageDefaultsForPath(nextPath);
    }
  }

  Future<void> _translateSubtitle(String path) async {
    if (_isTranslating) return;

    setState(() {
      _isTranslating = true;
      _translatingPath = path;
      _translateProgress = 0;
    });

    try {
      final videoFile = File(widget.videoPath);
      final outputDir = videoFile.parent.path;
      final outputPrefix = p.basenameWithoutExtension(widget.videoPath);

      final result = await _subtitleTranslationService.translateSubtitleFile(
        inputPath: path,
        sourceLanguage: _translateSourceLanguage,
        targetLanguage: _translateTargetLanguage,
        provider: _translateProvider,
        outputDirectory: outputDir,
        outputFilePrefix: outputPrefix,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _translateProgress = progress;
          });
        },
      );

      await _loadSubtitles();
      widget.onSubtitleChanged();

      if (!mounted) return;
      setState(() {
        _expandedTranslatePath = null;
      });
      if (Platform.isWindows) {
        try {
          await Process.run('explorer', ['/select,', result.outputPath]);
        } catch (_) {}
      }
      AppToast.show(
        "翻译完成：${p.basename(result.outputPath)}\n保存位置：${result.outputPath}",
        type: AppToastType.success,
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.show("翻译失败：$e", type: AppToastType.error);
    } finally {
      if (mounted) {
        setState(() {
          _isTranslating = false;
          _translatingPath = null;
          _translateProgress = 0;
        });
      }
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

  Widget _buildTranslationPanel({required String path, required bool enabled}) {
    if (_expandedTranslatePath != path) {
      return const SizedBox.shrink();
    }

    final busy = _isTranslating && _translatingPath == path;

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
                    });
                  },
          ),
          const SizedBox(height: 8),
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
                      });
                    },
            ),
            const SizedBox(height: 10),
            if (busy) ...[
              LinearProgressIndicator(value: _translateProgress),
              const SizedBox(height: 6),
              Text(
                '翻译中 ${(100 * _translateProgress).toStringAsFixed(0)}%',
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
    final associatedSubtitles = <String, String>{};
    if (widget.additionalSubtitles != null) {
      associatedSubtitles.addAll(widget.additionalSubtitles!);
    }
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
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : (_subtitleFiles.isEmpty &&
                      !hasEmbeddedContent &&
                      associatedSubtitles.isEmpty)
                ? const Center(
                    child: Text(
                      "暂无关联字幕文件",
                      style: TextStyle(color: Colors.white54),
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView(
                    children: [
                      // 1. Library/Associated Subtitles (Moved to front)
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
                          return Container(
                            margin: const EdgeInsets.only(bottom: 4),
                            decoration: BoxDecoration(
                              color: Colors.blueAccent.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: Colors.blueAccent.withValues(alpha: 0.2),
                              ),
                            ),
                            child: ListTile(
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 0,
                              ),
                              leading: (_extractingTrackIndex == track.index)
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
                                        : () => _downloadEmbeddedTrack(track),
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                  ),
                                  const SizedBox(width: 4),
                                  if (_extractedTrackPaths.containsKey(
                                    track.index,
                                  ))
                                    _buildSelectionBadge(
                                      _extractedTrackPaths[track.index]!,
                                    ),
                                ],
                              ),
                              onTap: () => _handleEmbeddedTrackSelection(track),
                            ),
                          );
                        }),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 4),
                          child: Divider(color: Colors.white10, height: 1),
                        ),
                      ],

                      // 3. Local Files Section
                      if (_subtitleFiles.isNotEmpty) ...[
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
                        ..._subtitleFiles
                            .where(
                              (file) =>
                                  !_extractedTrackPaths.values.any(
                                    (v) =>
                                        _normalizePath(v) ==
                                        _normalizePath(file.path),
                                  ) &&
                                  shownPaths.add(_normalizePath(file.path)),
                            )
                            .map((file) {
                              final name = p.basename(file.path);
                              final isAi = name.contains(".ai.");

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
                                        isAi
                                            ? Icons.auto_awesome
                                            : Icons.subtitles,
                                        color: isAi
                                            ? Colors.blueAccent
                                            : Colors.white70,
                                        size: 20,
                                      ),
                                      title: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              name,
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
                                          _buildTranslatedLanguageBadge(
                                            file.path,
                                          ),
                                        ],
                                      ),
                                      subtitle: Text(
                                        "${(file.lengthSync() / 1024).toStringAsFixed(1)} KB",
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
                    if (widget.onClose == null)
                      Navigator.pop(context); // Close sheet if dialog
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
