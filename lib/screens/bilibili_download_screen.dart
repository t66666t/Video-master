import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/bilibili_download_list_projection.dart';
import 'package:video_player_app/services/app_haptics.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/playback_navigation_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/subtitle_util.dart';
import 'package:video_player_app/utils/app_toast.dart';

import 'package:video_player_app/widgets/bilibili_login_dialogs.dart';

class BilibiliDownloadScreen extends StatefulWidget {
  final String? initialInput;
  final String? targetFolderId;
  final bool initialStreamingMode;
  const BilibiliDownloadScreen({
    super.key,
    this.initialInput,
    this.targetFolderId,
    this.initialStreamingMode = false,
  });

  @override
  State<BilibiliDownloadScreen> createState() => _BilibiliDownloadScreenState();
}

class _BilibiliDownloadScreenState extends State<BilibiliDownloadScreen>
    with SingleTickerProviderStateMixin {
  static const int _windowsMaxConcurrentDownloadsCap = 2;
  static const Duration _taskCollapseDuration = Duration(milliseconds: 190);
  static const Duration _taskRestoreDuration = Duration(milliseconds: 220);
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _taskListScrollController = ScrollController();
  final GlobalKey _taskListViewportKey = GlobalKey(
    debugLabel: 'BilibiliTaskListViewport',
  );
  int? _previousImageCacheMaxSize;
  int? _previousImageCacheMaxBytes;
  final FocusNode _shortcutFocusNode = FocusNode(
    debugLabel: 'BilibiliDownloadShortcutFocus',
  );
  late final AnimationController _keepAwakeBannerController;
  late final Animation<double> _keepAwakeBannerFade;
  late final Animation<double> _keepAwakeBannerSize;
  late final Animation<Offset> _keepAwakeBannerSlide;
  bool? _keepAwakeBannerVisible;
  bool _cachedKeepAwakeBannerActive = false;
  String? _draggingTaskId;
  int? _taskDragInsertionIndex;
  bool _collapseTaskDescendantsForDrag = false;
  bool _taskDragProjectionCollapsed = false;
  bool _taskDragFinishing = false;
  bool _taskDragRecoveryScheduled = false;
  int? _pendingTaskDropBoundary;
  double _draggedTaskExtent = 90;
  double _taskDragAutoScrollVelocity = 0;
  Timer? _taskDragCollapseTimer;
  Timer? _taskDragAutoScrollTimer;
  int _taskDragSession = 0;
  late bool _streamingMode;

  // Dialog helpers need access to API service, which is now in BilibiliDownloadService

  bool _isRetryCountdownHint(String? error) {
    if (error == null || error.isEmpty) return false;
    return error.startsWith("重试 ") || RegExp(r'^\d+秒后重试 ').hasMatch(error);
  }

  Color _episodeErrorColor(String? error) {
    if (error == "已暂停") return Colors.amber;
    if (error == "恢复中" || error == "链接已刷新，继续下载") {
      return Colors.lightBlueAccent;
    }
    if (error == "断点失效，从头下载") {
      return Colors.orangeAccent;
    }
    if (_isRetryCountdownHint(error)) {
      return Colors.orangeAccent;
    }
    return Colors.redAccent;
  }

  bool _isPausedEpisodeHint(String? error) {
    return error == "已暂停";
  }

  bool _isActiveEpisodeHint(String? error) {
    if (error == null || error.isEmpty) return false;
    return error == "恢复中" ||
        error == "链接已刷新，继续下载" ||
        error == "断点失效，从头下载" ||
        _isRetryCountdownHint(error);
  }

  String? _episodeStatusText(BilibiliDownloadEpisode ep) {
    if (ep.status == DownloadStatus.completed && ep.danmakuError != null) {
      return '弹幕下载失败';
    }
    final error = ep.error?.trim();
    if (error == null || error.isEmpty) return null;

    if (ep.status == DownloadStatus.failed) {
      return error;
    }

    if (_isPausedEpisodeHint(error)) {
      return ep.status == DownloadStatus.pending ||
              ep.status == DownloadStatus.queued
          ? error
          : null;
    }

    if (_isActiveEpisodeHint(error)) {
      return ep.status == DownloadStatus.fetchingInfo ||
              ep.status == DownloadStatus.downloading ||
              ep.status == DownloadStatus.merging ||
              ep.status == DownloadStatus.checking ||
              ep.status == DownloadStatus.repairing
          ? error
          : null;
    }

    return null;
  }

  IconData _episodeActionIcon(BilibiliDownloadEpisode ep) {
    if (ep.status == DownloadStatus.queued) {
      return Icons.hourglass_top;
    }
    if (ep.hasResumeData || ep.error == "已暂停") {
      return Icons.play_arrow;
    }
    if (ep.status == DownloadStatus.failed) {
      return Icons.replay;
    }
    return Icons.download;
  }

  Color _episodeActionColor(BilibiliDownloadEpisode ep) {
    if (ep.hasResumeData || ep.error == "已暂停") {
      return Colors.lightBlueAccent;
    }
    return ep.status == DownloadStatus.failed
        ? Colors.redAccent
        : Colors.white70;
  }

  String _episodeActionTooltip(BilibiliDownloadEpisode ep) {
    if (ep.status == DownloadStatus.queued) {
      return "退出排队";
    }
    if (ep.hasResumeData || ep.error == "已暂停") {
      return "继续下载";
    }
    return "加入排队 / 继续";
  }

  Widget _buildCheckboxWithSmallThumbnail({
    required bool value,
    required ValueChanged<bool?> onChanged,
    required String thumbnailUrl,
    double thumbnailWidth = 44,
    double thumbnailHeight = 28,
  }) {
    return SizedBox(
      width: 56,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(
            value: value,
            activeColor: Colors.pinkAccent,
            onChanged: onChanged,
          ),
          if (thumbnailUrl.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: _buildNetworkThumbnail(
                url: thumbnailUrl,
                width: thumbnailWidth,
                height: thumbnailHeight,
                imageKey: ValueKey(
                  'bb-mini-thumb-$thumbnailUrl-$thumbnailWidth-$thumbnailHeight',
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNetworkThumbnail({
    required String url,
    required double width,
    required double height,
    Key? imageKey,
  }) {
    if (url.isEmpty) {
      return _buildThumbnailPlaceholder(
        width: width,
        height: height,
        icon: Icons.video_library_outlined,
      );
    }
    final media = MediaQuery.of(context);
    final dpr = media.devicePixelRatio;
    final scale = dpr <= 1.0 ? 1.0 : (dpr >= 1.25 ? 1.25 : dpr);
    int cacheWidth = (width * scale).round();
    int cacheHeight = (height * scale).round();
    String processedUrl = url;
    if (!url.contains('@') &&
        (url.contains('hdslb.com') || url.contains('bilivideo.com'))) {
      processedUrl = "$url@${cacheWidth}w_${cacheHeight}h_1c.webp";
    }
    final provider = ResizeImage(
      NetworkImage(processedUrl),
      width: cacheWidth,
      height: cacheHeight,
      allowUpscaling: false,
    );
    return Image(
      key: imageKey,
      image: provider,
      width: width,
      height: height,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.low,
      gaplessPlayback: false,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return _buildThumbnailPlaceholder(
          width: width,
          height: height,
          icon: Icons.image_outlined,
        );
      },
      errorBuilder: (context, error, stackTrace) {
        return _buildThumbnailPlaceholder(
          width: width,
          height: height,
          icon: Icons.broken_image_outlined,
        );
      },
    );
  }

  Widget _buildThumbnailPlaceholder({
    required double width,
    required double height,
    required IconData icon,
  }) {
    return Container(
      width: width,
      height: height,
      color: Colors.grey[850],
      alignment: Alignment.center,
      child: Icon(icon, color: Colors.white30, size: height * 0.45),
    );
  }

  @override
  void initState() {
    super.initState();
    _streamingMode = widget.initialStreamingMode;
    _keepAwakeBannerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      reverseDuration: const Duration(milliseconds: 190),
    );
    _keepAwakeBannerFade = CurvedAnimation(
      parent: _keepAwakeBannerController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _keepAwakeBannerSize = CurvedAnimation(
      parent: _keepAwakeBannerController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _keepAwakeBannerSlide =
        Tween<Offset>(begin: const Offset(0, -0.08), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _keepAwakeBannerController,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          ),
        );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final cache = PaintingBinding.instance.imageCache;
      _previousImageCacheMaxSize = cache.maximumSize;
      _previousImageCacheMaxBytes = cache.maximumSizeBytes;
      cache.maximumSize = 120;
      cache.maximumSizeBytes = 20 * 1024 * 1024;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (Platform.isWindows && mounted) {
        _shortcutFocusNode.requestFocus();
      }
    });
    if (widget.initialInput != null) {
      _inputController.text = widget.initialInput!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final service = Provider.of<BilibiliDownloadService>(
          context,
          listen: false,
        );
        // Inject library service for auto-import
        service.libraryService = Provider.of<LibraryService>(
          context,
          listen: false,
        );
        service.clearSelection();

        _parseVideo(service);
      });
    } else {
      // Inject library service even if no initial input, to ensure background tasks have it
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final service = Provider.of<BilibiliDownloadService>(
          context,
          listen: false,
        );
        service.libraryService = Provider.of<LibraryService>(
          context,
          listen: false,
        );
        service.clearSelection();
      });
    }
  }

  KeyEventResult _handleEscKeyEvent(KeyEvent event) {
    if (!Platform.isWindows) return KeyEventResult.ignored;
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _taskDragCollapseTimer?.cancel();
    _taskDragAutoScrollTimer?.cancel();
    final cache = PaintingBinding.instance.imageCache;
    if (_previousImageCacheMaxSize != null) {
      cache.maximumSize = _previousImageCacheMaxSize!;
    }
    if (_previousImageCacheMaxBytes != null) {
      cache.maximumSizeBytes = _previousImageCacheMaxBytes!;
    }
    _keepAwakeBannerController.dispose();
    _taskListScrollController.dispose();
    _shortcutFocusNode.dispose();
    _inputController.dispose();
    super.dispose();
  }

  Future<void> _showCookieDialog(BilibiliDownloadService service) async {
    await showBilibiliLoginDialog(context, suppressToasts: _streamingMode);
  }

  void _showQrCodeLoginDialog(BilibiliDownloadService service) {
    showBilibiliQrCodeDialog(context, suppressToasts: _streamingMode);
  }

  Future<void> _parseVideo(BilibiliDownloadService service) async {
    final rawInput = _inputController.text;
    if (rawInput.trim().isEmpty) return;

    final hasCookie = await service.apiService.hasCookie();
    if (!hasCookie) {
      if (mounted) {
        if (!_streamingMode) {
          AppToast.show("解析前请先扫码登录 Bilibili", type: AppToastType.error);
        }
        _showQrCodeLoginDialog(service);
      }
      return;
    }

    // Call service to parse
    final success = await service.parseVideo(
      rawInput,
      asStreamingImport: _streamingMode,
      onConfirmCollection: (title) async {
        // Show Dialog
        return await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: const Color(0xFF2C2C2C),
                title: const Text(
                  "发现合集",
                  style: TextStyle(color: Colors.white),
                ),
                content: Text(
                  "此视频属于合集：\n$title\n\n是否识别整个合集？",
                  style: const TextStyle(color: Colors.white70),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text(
                      "仅识别此视频",
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.pinkAccent,
                    ),
                    child: const Text(
                      "识别整个合集",
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ) ??
            false;
      },
    );
    if (!success) {
      // Only clear input if success? Or keep pending?
      // The service doesn't return failed lines nicely yet, but it handles adding valid ones.
      // For now, let's just clear if at least one succeeded, or keep all if failed?
      // The original logic kept pending lines.
      // Let's rely on service state for status message.
    } else {
      // Clear input on success
      _inputController.clear();
    }
  }

  String _formatPath(String path) {
    if (Platform.isMacOS || Platform.isLinux) {
      final home = Platform.environment['HOME'];
      if (home != null && path.startsWith(home)) {
        return path.replaceFirst(home, '~');
      }
    }
    return path;
  }

  Future<void> _showDownloadSettings(BilibiliDownloadService service) async {
    if (_streamingMode) {
      await _showStreamingSettings(service);
      return;
    }
    bool tempDownloadDanmaku = service.downloadDanmaku;
    int tempMax = service.maxConcurrentDownloads;
    int tempVideoConnections = service.maxConnectionsPerVideo;
    int tempQuality = service.preferredQuality;
    String tempSubLang = service.preferredSubtitleLang;
    bool tempAi = service.preferAiSubtitles;
    bool tempAutoImport = service.autoImportToLibrary;
    bool tempAutoDelete = service.autoDeleteTaskAfterImport;
    bool tempSeqExport = service.sequentialExport;
    String defaultDownloadDir;
    if (Platform.isWindows) {
      final dataRootPath = await SettingsService()
          .getDefaultLargeDataRootPath();
      defaultDownloadDir = p.join(dataRootPath, 'imported_videos');
    } else if (Platform.isMacOS) {
      final downloadDir = await getDownloadsDirectory();
      if (downloadDir != null) {
        defaultDownloadDir = p.join(downloadDir.path, 'imported_videos');
      } else {
        final appDir = await getApplicationDocumentsDirectory();
        defaultDownloadDir = p.join(appDir.path, 'imported_videos');
      }
    } else {
      final appDir = await getApplicationDocumentsDirectory();
      defaultDownloadDir = p.join(appDir.path, 'imported_videos');
    }
    String? tempCustomPath = service.customDownloadPath;
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: const Text("下载设置"),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    title: const Text('下载弹幕'),
                    subtitle: const Text('下载后自动绑定到对应的 B 站视频'),
                    value: tempDownloadDanmaku,
                    onChanged: (value) {
                      setState(() => tempDownloadDanmaku = value);
                      unawaited(service.setDownloadDanmaku(value));
                    },
                    contentPadding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text("最大并发下载数: "),
                      DropdownButton<int>(
                        value: tempMax,
                        items:
                            List.generate(
                                  Platform.isWindows
                                      ? _windowsMaxConcurrentDownloadsCap
                                      : 10,
                                  (i) => i + 1,
                                )
                                .map(
                                  (e) => DropdownMenuItem(
                                    value: e,
                                    child: Text("$e"),
                                  ),
                                )
                                .toList(),
                        onChanged: (val) {
                          if (val != null) setState(() => tempMax = val);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Expanded(child: Text('单视频连接数:')),
                      DropdownButton<int>(
                        value: tempVideoConnections,
                        items: const [
                          DropdownMenuItem(value: 1, child: Text('1（稳定）')),
                          DropdownMenuItem(value: 2, child: Text('2（推荐）')),
                          DropdownMenuItem(value: 4, child: Text('4（高速）')),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => tempVideoConnections = value);
                          }
                        },
                      ),
                    ],
                  ),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '按文件大小和任务并发数自动降级；CDN 不支持分片时会回退单连接。',
                      style: TextStyle(fontSize: 10, color: Colors.white54),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Text("首选清晰度: "),
                      DropdownButton<int>(
                        value: tempQuality,
                        items: const [
                          DropdownMenuItem(value: 127, child: Text("8K")),
                          DropdownMenuItem(value: 120, child: Text("4K")),
                          DropdownMenuItem(
                            value: 116,
                            child: Text("1080P 60帧"),
                          ),
                          DropdownMenuItem(value: 80, child: Text("1080P")),
                          DropdownMenuItem(value: 64, child: Text("720P")),
                          DropdownMenuItem(value: 32, child: Text("480P")),
                        ],
                        onChanged: (val) {
                          if (val != null) setState(() => tempQuality = val);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Text("字幕偏好: "),
                      DropdownButton<String>(
                        value: tempSubLang,
                        items: const [
                          DropdownMenuItem(value: "none", child: Text("无")),
                          DropdownMenuItem(value: "zh", child: Text("中文")),
                          DropdownMenuItem(value: "en", child: Text("English")),
                          DropdownMenuItem(value: "ja", child: Text("日本語")),
                        ],
                        onChanged: (val) {
                          if (val != null) setState(() => tempSubLang = val);
                        },
                      ),
                    ],
                  ),
                  CheckboxListTile(
                    title: const Text("AI 字幕优先"),
                    value: tempAi,
                    onChanged: (val) {
                      if (val != null) setState(() => tempAi = val);
                    },
                    contentPadding: EdgeInsets.zero,
                  ),
                  CheckboxListTile(
                    title: const Text("下载完成后自动导入媒体库"),
                    value: tempAutoImport,
                    onChanged: (val) {
                      if (val != null) setState(() => tempAutoImport = val);
                    },
                    contentPadding: EdgeInsets.zero,
                  ),
                  CheckboxListTile(
                    title: const Text("导入媒体库后自动删除任务"),
                    value: tempAutoDelete,
                    onChanged: (val) {
                      if (val != null) setState(() => tempAutoDelete = val);
                    },
                    contentPadding: EdgeInsets.zero,
                  ),
                  CheckboxListTile(
                    title: Text(
                      "批量合成并导出时按顺序导出",
                      style: TextStyle(
                        color: tempAutoImport ? Colors.white : Colors.white38,
                      ),
                    ),
                    subtitle: Text(
                      "等待前置任务导出后再进行当前任务导出",
                      style: TextStyle(
                        fontSize: 10,
                        color: tempAutoImport ? Colors.white54 : Colors.white24,
                      ),
                    ),
                    value: tempSeqExport,
                    onChanged: tempAutoImport
                        ? (val) {
                            if (val != null) {
                              setState(() => tempSeqExport = val);
                            }
                          }
                        : null,
                    contentPadding: EdgeInsets.zero,
                  ),
                  if (!Platform.isAndroid && !Platform.isIOS) ...[
                    const SizedBox(height: 16),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        "下载保存目录",
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _formatPath(
                              tempCustomPath?.isNotEmpty == true
                                  ? tempCustomPath!
                                  : defaultDownloadDir,
                            ),
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white70,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              ElevatedButton(
                                onPressed: () async {
                                  try {
                                    final path = await FilePicker.platform
                                        .getDirectoryPath(
                                          dialogTitle: "选择下载保存目录",
                                          lockParentWindow: true,
                                        );
                                    if (path != null && path.isNotEmpty) {
                                      setState(() => tempCustomPath = path);
                                    }
                                  } catch (e) {
                                    AppToast.show(
                                      "打开目录选择失败，请重试",
                                      type: AppToastType.error,
                                    );
                                  }
                                },
                                child: const Text("选择目录"),
                              ),
                              const SizedBox(width: 8),
                              TextButton(
                                onPressed: () {
                                  setState(
                                    () => tempCustomPath = defaultDownloadDir,
                                  );
                                },
                                child: const Text("使用默认"),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("取消"),
              ),
              ElevatedButton(
                onPressed: () {
                  service.updateSettings(
                    tempMax,
                    tempQuality,
                    tempSubLang,
                    tempAi,
                    tempAutoImport,
                    tempAutoDelete,
                    tempSeqExport,
                    customPath: tempCustomPath,
                    videoConnections: tempVideoConnections,
                  );
                  Navigator.pop(ctx);
                  AppToast.show("设置已保存", type: AppToastType.success);
                },
                child: const Text("保存"),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showStreamingSettings(BilibiliDownloadService service) async {
    var subtitleLanguage = service.preferredSubtitleLang;
    var preferAi = service.preferAiSubtitles;
    var autoDelete = service.autoDeleteTaskAfterImport;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('解析设置'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Expanded(child: Text('默认字幕偏好')),
                  DropdownButton<String>(
                    value: subtitleLanguage,
                    items: const [
                      DropdownMenuItem(value: 'none', child: Text('无')),
                      DropdownMenuItem(value: 'zh', child: Text('中文')),
                      DropdownMenuItem(value: 'en', child: Text('English')),
                      DropdownMenuItem(value: 'ja', child: Text('日本語')),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => subtitleLanguage = value);
                      }
                    },
                  ),
                ],
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('AI 字幕优先'),
                subtitle: const Text('仅影响导出时默认绑定的字幕'),
                value: preferAi,
                onChanged: (value) =>
                    setDialogState(() => preferAi = value ?? false),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('导出后自动删除解析任务'),
                value: autoDelete,
                onChanged: (value) =>
                    setDialogState(() => autoDelete = value ?? false),
              ),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '视频清晰度在播放时选择；这里只解析稳定的 BV/cid 身份、封面、字幕和章节。',
                  style: TextStyle(fontSize: 11, color: Colors.white54),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                service
                  ..preferredSubtitleLang = subtitleLanguage
                  ..preferAiSubtitles = preferAi
                  ..autoDeleteTaskAfterImport = autoDelete;
                unawaited(service.saveSettings());
                Navigator.pop(dialogContext);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _importToLibrary(
    BilibiliDownloadService service, {
    BilibiliDownloadEpisode? episode,
  }) async {
    final library = Provider.of<LibraryService>(context, listen: false);

    AppToast.showLoading("开始导入...");

    final count = await service.importToLibrary(
      library,
      episode: episode,
      targetFolderId: widget.targetFolderId,
    );

    if (!mounted) return;

    AppToast.dismiss();

    if (count > 0) {
      AppToast.show("已导入 $count 个视频", type: AppToastType.success);
    } else {
      AppToast.show("导入失败或无已完成任务", type: AppToastType.error);
    }
  }

  Future<void> _exportStreaming(
    BilibiliDownloadService service, {
    BilibiliDownloadEpisode? episode,
  }) async {
    final library = Provider.of<LibraryService>(context, listen: false);
    await service.importStreamingToLibrary(
      library,
      episode: episode,
      targetFolderId: widget.targetFolderId,
    );
  }

  void _showSubtitlePreview(
    BilibiliDownloadService service,
    BilibiliSubtitle sub,
  ) async {
    showDialog(
      context: context,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final content = await service.apiService.fetchSubtitleContent(sub.url);
      final srt = SubtitleUtil.convertJsonToSrt(content);
      if (!mounted) return;
      Navigator.pop(context); // Dismiss loading

      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text("字幕预览: ${sub.lanDoc}"),
            content: SizedBox(
              width: double.maxFinite,
              height: 400,
              child: SingleChildScrollView(child: Text(srt)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("关闭"),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      if (!_streamingMode) {
        AppToast.show("预览失败", type: AppToastType.error);
      }
    }
  }

  Future<void> _openVideoPlayer(VideoItem videoItem) async {
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    await Navigator.push(
      context,
      PlaybackNavigationService.buildPlaybackEntryRoute(videoItem),
    );
  }

  List<String?> _findMatchingCollectionIds(
    LibraryService library,
    List<String?> parentIds,
    String collectionName,
  ) {
    final matchedIds = <String>{};
    for (final parentId in parentIds) {
      final contents = library.getContents(parentId);
      for (final item in contents) {
        if (item is VideoCollection && item.name == collectionName) {
          matchedIds.add(item.id);
        }
      }
    }
    return matchedIds.toList();
  }

  Future<VideoItem?> _findLatestImportedVideoForEpisode(
    BilibiliDownloadEpisode ep,
  ) async {
    if (ep.outputPath == null ||
        ep.importedVideoIds.isEmpty ||
        ep.importedOutputPath == null) {
      return null;
    }
    if (p.normalize(ep.outputPath!) != p.normalize(ep.importedOutputPath!)) {
      return null;
    }

    final library = Provider.of<LibraryService>(context, listen: false);
    for (final videoId in ep.importedVideoIds.reversed) {
      final item = library.getVideo(videoId);
      if (item != null && !item.isRecycled) {
        return item;
      }
    }
    return null;
  }

  Future<VideoItem?> _findLegacyImportedVideoForEpisode(
    BilibiliDownloadTask task,
    BilibiliVideoItem video,
    BilibiliDownloadEpisode ep,
  ) async {
    if (!ep.isExported) {
      return null;
    }

    final library = Provider.of<LibraryService>(context, listen: false);
    var parentIds = <String?>[widget.targetFolderId];

    if (task.collectionInfo != null) {
      parentIds = _findMatchingCollectionIds(
        library,
        parentIds,
        task.collectionInfo!.title,
      );
      if (parentIds.isEmpty) {
        return null;
      }
    }

    if (video.videoInfo.pages.length > 1) {
      parentIds = _findMatchingCollectionIds(
        library,
        parentIds,
        video.videoInfo.title,
      );
      if (parentIds.isEmpty) {
        return null;
      }
    }

    final expectedTitle = video.videoInfo.pages.length > 1
        ? ep.page.part
        : video.videoInfo.title;
    final candidates = <VideoItem>[];
    for (final parentId in parentIds) {
      for (final item in library.getContents(parentId)) {
        if (item is VideoItem &&
            !item.isRecycled &&
            item.isBilibiliExported &&
            item.title == expectedTitle) {
          candidates.add(item);
        }
      }
    }

    if (candidates.isEmpty) {
      return null;
    }

    candidates.sort((a, b) => b.lastUpdated.compareTo(a.lastUpdated));
    return candidates.first;
  }

  void _previewVideo(
    BilibiliDownloadEpisode ep, {
    BilibiliDownloadTask? task,
    BilibiliVideoItem? video,
  }) async {
    VideoItem? importedVideo = await _findLatestImportedVideoForEpisode(ep);
    if (importedVideo == null && task != null && video != null) {
      importedVideo = await _findLegacyImportedVideoForEpisode(task, video, ep);
      if (!mounted) return;
      if (importedVideo != null && ep.outputPath != null) {
        ep.importedOutputPath = p.normalize(ep.outputPath!);
        ep.importedVideoIds = [importedVideo.id];
        unawaited(
          Provider.of<BilibiliDownloadService>(
            context,
            listen: false,
          ).saveTasks(),
        );
      }
    }
    if (importedVideo != null) {
      await _openVideoPlayer(importedVideo);
      return;
    }

    if (ep.importedVideoIds.isNotEmpty &&
        ep.outputPath != null &&
        ep.importedOutputPath != null &&
        p.normalize(ep.outputPath!) == p.normalize(ep.importedOutputPath!)) {
      if (!_streamingMode) {
        AppToast.show("已导入的视频不存在，可能已被删除或移入回收站", type: AppToastType.error);
      }
      return;
    }

    if (ep.outputPath == null) {
      if (!_streamingMode) {
        AppToast.show("文件路径为空，无法播放", type: AppToastType.error);
      }
      return;
    }

    final file = File(ep.outputPath!);
    if (!await file.exists()) {
      if (!mounted) return;
      if (!_streamingMode) {
        AppToast.show("视频文件不存在，可能已被删除或移动", type: AppToastType.error);
      }
      return;
    }

    final videoItem = VideoItem(
      id: "preview_${ep.bvid}_${ep.page.page}_${DateTime.now().millisecondsSinceEpoch}",
      path: ep.outputPath!,
      title: "预览: ${ep.page.part}",
      durationMs: 0,
      lastUpdated: DateTime.now().millisecondsSinceEpoch,
      subtitlePath: ep.outputPath!.replaceAll(
        RegExp(r'\.[a-zA-Z0-9]+$'),
        '.srt',
      ),
      chapters: ep.chapters,
      hasProbedChapters: true,
    );

    await _openVideoPlayer(videoItem);
  }

  void _deleteAllTasks(BilibiliDownloadService service) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("确认删除"),
        content: const Text("确定要清空所有任务吗？所有未导入的缓存数据将被永久删除。"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              service.deleteAllTasksForMode(_streamingMode);
            },
            child: const Text("删除", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleProcessingKeepAwake(
    BilibiliDownloadService service,
  ) async {
    await service.toggleKeepScreenAwakeDuringProcessing();
  }

  void _syncKeepAwakeBannerVisibility(BilibiliDownloadService service) {
    final bool visible = service.keepScreenAwakeDuringProcessing;
    if (visible) {
      _cachedKeepAwakeBannerActive = service.isProcessingKeepAwakeActive;
    }
    if (_keepAwakeBannerVisible == null) {
      _keepAwakeBannerVisible = visible;
      _keepAwakeBannerController.value = visible ? 1 : 0;
      return;
    }
    if (_keepAwakeBannerVisible == visible) {
      return;
    }
    _keepAwakeBannerVisible = visible;
    if (visible) {
      _keepAwakeBannerController.forward();
    } else {
      _keepAwakeBannerController.reverse();
    }
  }

  Widget _buildProcessingKeepAwakeAction(
    BilibiliDownloadService service, {
    required bool isCompactAppBar,
  }) {
    final bool enabled = service.keepScreenAwakeDuringProcessing;
    final bool active = service.isProcessingKeepAwakeActive;
    final double buttonSize = isCompactAppBar ? 34 : 38;
    const Duration stateTransitionDuration = Duration(milliseconds: 180);
    final Color accent = active
        ? const Color(0xFF7AE7FF)
        : const Color(0xFFA8B9FF);
    final Color background = enabled
        ? const Color(0x4A253551)
        : const Color(0x221C1C1E);
    final List<BoxShadow> shadows = enabled
        ? [
            BoxShadow(
              color: accent.withValues(alpha: active ? 0.08 : 0.05),
              blurRadius: active ? 8 : 6,
              spreadRadius: 0,
              offset: const Offset(0, 2),
            ),
          ]
        : const [];

    return Padding(
      padding: EdgeInsets.only(right: isCompactAppBar ? 2 : 4),
      child: Tooltip(
        message: enabled ? (active ? "下载时保持亮屏模式已开启" : "亮屏模式待命中") : "下载时保持亮屏",
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(buttonSize / 2),
            onTap: () => _toggleProcessingKeepAwake(service),
            child: AnimatedContainer(
              duration: stateTransitionDuration,
              curve: Curves.easeOutCubic,
              width: buttonSize,
              height: buttonSize,
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: enabled
                    ? LinearGradient(
                        colors: [
                          const Color(0x66FAFCFF),
                          background,
                          const Color(0x664475FF),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      )
                    : null,
                color: enabled ? null : const Color(0x221C1C1E),
                border: Border.all(
                  color: enabled
                      ? accent.withValues(alpha: 0.55)
                      : Colors.white.withValues(alpha: 0.08),
                ),
                boxShadow: shadows,
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  AnimatedContainer(
                    duration: stateTransitionDuration,
                    curve: Curves.easeOutCubic,
                    width: double.infinity,
                    height: double.infinity,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: enabled
                          ? Colors.white.withValues(alpha: 0.045)
                          : Colors.white.withValues(alpha: 0.025),
                    ),
                  ),
                  AnimatedScale(
                    duration: stateTransitionDuration,
                    curve: Curves.easeOutCubic,
                    scale: active ? 1.0 : 0.94,
                    child: AnimatedContainer(
                      duration: stateTransitionDuration,
                      curve: Curves.easeOutCubic,
                      width: isCompactAppBar ? 22 : 24,
                      height: isCompactAppBar ? 22 : 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: enabled
                            ? LinearGradient(
                                colors: [
                                  Colors.white.withValues(alpha: 0.96),
                                  accent.withValues(alpha: 0.92),
                                ],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              )
                            : null,
                        color: enabled
                            ? null
                            : Colors.white.withValues(alpha: 0.1),
                        boxShadow: enabled
                            ? [
                                BoxShadow(
                                  color: accent.withValues(
                                    alpha: active ? 0.2 : 0.12,
                                  ),
                                  blurRadius: active ? 7 : 5,
                                  spreadRadius: 0,
                                  offset: const Offset(0, 2),
                                ),
                              ]
                            : const [],
                      ),
                      child: AnimatedSwitcher(
                        duration: stateTransitionDuration,
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) {
                          return FadeTransition(
                            opacity: animation,
                            child: ScaleTransition(
                              scale: animation,
                              child: child,
                            ),
                          );
                        },
                        child: Icon(
                          active
                              ? Icons.wb_sunny_rounded
                              : Icons.light_mode_outlined,
                          key: ValueKey<bool>(active),
                          size: isCompactAppBar ? 13 : 14,
                          color: enabled
                              ? const Color(0xFF10213B)
                              : Colors.white70,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 4,
                    top: 4,
                    child: AnimatedScale(
                      duration: stateTransitionDuration,
                      curve: Curves.easeOutCubic,
                      scale: active ? 1.0 : 0.88,
                      child: AnimatedContainer(
                        duration: stateTransitionDuration,
                        curve: Curves.easeOutCubic,
                        width: active ? 7 : 6,
                        height: active ? 7 : 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: enabled
                              ? accent.withValues(alpha: active ? 0.98 : 0.82)
                              : Colors.white.withValues(alpha: 0.16),
                          boxShadow: enabled
                              ? [
                                  BoxShadow(
                                    color: accent.withValues(
                                      alpha: active ? 0.18 : 0.1,
                                    ),
                                    blurRadius: active ? 5 : 3,
                                    spreadRadius: 0,
                                  ),
                                ]
                              : const [],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProcessingKeepAwakeBanner(BilibiliDownloadService service) {
    if (!service.supportsProcessingKeepAwakeToggle) {
      return const SizedBox.shrink();
    }
    final bool visible =
        _keepAwakeBannerVisible == true ||
        _keepAwakeBannerController.isAnimating ||
        _keepAwakeBannerController.value > 0;
    if (!visible) {
      return const SizedBox.shrink();
    }
    final bool enabled = service.keepScreenAwakeDuringProcessing;
    final bool active = enabled
        ? service.isProcessingKeepAwakeActive
        : _cachedKeepAwakeBannerActive;
    const Duration stateTransitionDuration = Duration(milliseconds: 180);
    final Color accent = active
        ? const Color(0xFF7AE7FF)
        : const Color(0xFFB2BEFF);
    final String title = active ? "下载时保持亮屏模式已开启" : "亮屏模式已待命";
    final String detail = active ? "下载、合成或导出时保持亮屏。" : "仅在下载、合成或导出时生效。";
    final String badgeText = active ? "处理中" : "待命中";

    return ClipRect(
      child: SizeTransition(
        sizeFactor: _keepAwakeBannerSize,
        alignment: Alignment.topCenter,
        child: FadeTransition(
          opacity: _keepAwakeBannerFade,
          child: SlideTransition(
            position: _keepAwakeBannerSlide,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                  child: AnimatedContainer(
                    duration: stateTransitionDuration,
                    curve: Curves.easeOutCubic,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: active
                            ? [
                                const Color(0x662D435E),
                                const Color(0xAA152133),
                                const Color(0x66386384),
                              ]
                            : [
                                const Color(0x442A2F45),
                                const Color(0xAA181B28),
                                const Color(0x44343A5A),
                              ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                        color: accent.withValues(alpha: active ? 0.55 : 0.35),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: accent.withValues(alpha: active ? 0.16 : 0.08),
                          blurRadius: active ? 22 : 16,
                          spreadRadius: active ? 0.5 : 0,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      child: Row(
                        children: [
                          AnimatedScale(
                            duration: stateTransitionDuration,
                            curve: Curves.easeOutCubic,
                            scale: active ? 1.0 : 0.96,
                            child: AnimatedContainer(
                              duration: stateTransitionDuration,
                              curve: Curves.easeOutCubic,
                              width: 42,
                              height: 42,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: LinearGradient(
                                  colors: [
                                    Colors.white.withValues(alpha: 0.92),
                                    accent.withValues(alpha: 0.92),
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: accent.withValues(
                                      alpha: active ? 0.24 : 0.12,
                                    ),
                                    blurRadius: active ? 14 : 8,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: AnimatedSwitcher(
                                duration: stateTransitionDuration,
                                switchInCurve: Curves.easeOutCubic,
                                switchOutCurve: Curves.easeInCubic,
                                transitionBuilder: (child, animation) {
                                  return FadeTransition(
                                    opacity: animation,
                                    child: ScaleTransition(
                                      scale: animation,
                                      child: child,
                                    ),
                                  );
                                },
                                child: Icon(
                                  active
                                      ? Icons.sunny
                                      : Icons.light_mode_outlined,
                                  key: ValueKey<bool>(active),
                                  color: const Color(0xFF10213B),
                                  size: 22,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: AnimatedSwitcher(
                              duration: stateTransitionDuration,
                              switchInCurve: Curves.easeOutCubic,
                              switchOutCurve: Curves.easeInCubic,
                              layoutBuilder: (currentChild, previousChildren) {
                                return Stack(
                                  alignment: Alignment.centerLeft,
                                  children: <Widget>[
                                    ...previousChildren,
                                    ?currentChild,
                                  ],
                                );
                              },
                              transitionBuilder: (child, animation) {
                                return FadeTransition(
                                  opacity: animation,
                                  child: child,
                                );
                              },
                              child: Align(
                                key: ValueKey<bool>(active),
                                alignment: Alignment.centerLeft,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.2,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      detail,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: Colors.white.withValues(
                                          alpha: 0.72,
                                        ),
                                        fontSize: 12,
                                        height: 1.3,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          AnimatedSwitcher(
                            duration: stateTransitionDuration,
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            transitionBuilder: (child, animation) {
                              return FadeTransition(
                                opacity: animation,
                                child: ScaleTransition(
                                  scale: animation,
                                  child: child,
                                ),
                              );
                            },
                            child: Container(
                              key: ValueKey<bool>(active),
                              constraints: const BoxConstraints(minWidth: 58),
                              alignment: Alignment.center,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(999),
                                color: accent.withValues(
                                  alpha: active ? 0.18 : 0.12,
                                ),
                                border: Border.all(
                                  color: accent.withValues(
                                    alpha: active ? 0.5 : 0.3,
                                  ),
                                ),
                              ),
                              child: Text(
                                badgeText,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.9),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.4,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<BilibiliDownloadListRow> _buildVirtualRows(
    BilibiliDownloadService service,
  ) => BilibiliDownloadListProjection.build(
    service
        .taskIdsForMode(_streamingMode)
        .map(service.getTaskById)
        .whereType<BilibiliDownloadTask>(),
    forceTasksCollapsed: _taskDragProjectionCollapsed,
  );

  Key _virtualRowKey(
    BilibiliDownloadService service,
    BilibiliDownloadListRow row,
  ) => switch (row) {
    BilibiliTaskHeaderRow() => ValueKey('bb-task-${row.task.taskId}'),
    BilibiliVideoHeaderRow(:final video) => ValueKey(
      'bb-video-${row.task.taskId}-${video.videoInfo.bvid}',
    ),
    BilibiliEpisodeRow(:final episode) => ValueKey(
      'bb-episode-${row.task.taskId}-${service.episodeKey(episode)}',
    ),
  };

  void _beginTaskDrag(
    BilibiliDownloadService service,
    BilibiliDownloadTask task,
    double measuredExtent,
  ) {
    if (!mounted ||
        _draggingTaskId != null ||
        _taskDragFinishing ||
        service.taskIds.length < 2) {
      return;
    }
    final oldIndex = service.taskIds.indexOf(task.taskId);
    if (oldIndex < 0) return;

    final session = ++_taskDragSession;
    _taskDragCollapseTimer?.cancel();
    setState(() {
      _draggingTaskId = task.taskId;
      _taskDragInsertionIndex = oldIndex;
      _collapseTaskDescendantsForDrag = true;
      _taskDragProjectionCollapsed = false;
      _pendingTaskDropBoundary = null;
      _draggedTaskExtent = measuredExtent.clamp(76.0, 140.0);
    });
    unawaited(AppHaptics.reorderDragStarted(context.read<SettingsService>()));

    // First animate visible descendants to zero. Removing their virtual rows
    // only after that animation prevents the tasks below from snapping upward.
    _taskDragCollapseTimer = Timer(_taskCollapseDuration, () {
      if (!mounted || session != _taskDragSession || _draggingTaskId == null) {
        return;
      }
      setState(() => _taskDragProjectionCollapsed = true);
    });
  }

  void _updateTaskDragInsertionIndex(int boundary) {
    if (_draggingTaskId == null ||
        boundary == _taskDragInsertionIndex ||
        _taskDragFinishing) {
      return;
    }
    setState(() => _taskDragInsertionIndex = boundary);
    unawaited(AppHaptics.reorderTargetChanged(context.read<SettingsService>()));
  }

  int _taskBoundaryForPointer(
    BuildContext targetContext,
    Offset globalPosition,
    int taskIndex,
  ) {
    final renderObject = targetContext.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return taskIndex;
    }
    final local = renderObject.globalToLocal(globalPosition);
    return local.dy < renderObject.size.height / 2 ? taskIndex : taskIndex + 1;
  }

  void _commitTaskDrop(String taskId, int boundary) {
    if (taskId != _draggingTaskId || _taskDragFinishing) return;
    _taskDragInsertionIndex = boundary;
    _pendingTaskDropBoundary = boundary;
  }

  Future<void> _finishTaskDrag(
    BilibiliDownloadService service,
    String taskId,
  ) async {
    if (!mounted || _taskDragFinishing || _draggingTaskId == null) return;
    final session = ++_taskDragSession;
    final pendingBoundary = taskId == _draggingTaskId
        ? _pendingTaskDropBoundary
        : null;
    _taskDragCollapseTimer?.cancel();
    _stopTaskDragAutoScroll();
    setState(() {
      _draggingTaskId = null;
      _taskDragInsertionIndex = null;
      _taskDragFinishing = true;
      _pendingTaskDropBoundary = null;
    });
    // Commit only after Draggable has reached onDragEnd. Reordering from the
    // DragTarget callback itself can dispose the drag source before it receives
    // this cleanup callback, leaving the page permanently folded.
    final didReorder =
        pendingBoundary != null &&
        service.moveTaskToInsertionIndex(taskId, pendingBoundary);
    if (didReorder) {
      unawaited(
        AppHaptics.reorderDragCompleted(context.read<SettingsService>()),
      );
    }

    if (_taskDragProjectionCollapsed) {
      // Reinsert descendants at zero height, wait one frame, then expand them.
      // Their persisted expansion flags were never changed, so each task
      // returns to precisely its pre-drag expanded/collapsed state.
      await Future<void>.delayed(_taskCollapseDuration);
      if (!mounted || session != _taskDragSession) return;
      setState(() => _taskDragProjectionCollapsed = false);
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!mounted || session != _taskDragSession) return;
    setState(() => _collapseTaskDescendantsForDrag = false);
    await Future<void>.delayed(_taskRestoreDuration);
    if (!mounted || session != _taskDragSession) return;
    setState(() => _taskDragFinishing = false);
  }

  void _handleTaskDragUpdate(DragUpdateDetails details) {
    if (_draggingTaskId == null) return;
    final renderObject = _taskListViewportKey.currentContext
        ?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    final local = renderObject.globalToLocal(details.globalPosition);
    final edge = (renderObject.size.height * 0.18).clamp(56.0, 88.0);
    double velocity = 0;
    if (local.dy < edge) {
      final intensity = ((edge - local.dy) / edge).clamp(0.0, 1.0);
      velocity = -720 * intensity;
    } else if (local.dy > renderObject.size.height - edge) {
      final intensity = ((local.dy - (renderObject.size.height - edge)) / edge)
          .clamp(0.0, 1.0);
      velocity = 720 * intensity;
    }
    _taskDragAutoScrollVelocity = velocity;
    if (velocity == 0) {
      _stopTaskDragAutoScroll();
      return;
    }
    if (_taskDragAutoScrollTimer != null) return;
    _taskDragAutoScrollTimer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _tickTaskDragAutoScroll(),
    );
  }

  void _tickTaskDragAutoScroll() {
    if (!mounted ||
        _draggingTaskId == null ||
        !_taskListScrollController.hasClients) {
      _stopTaskDragAutoScroll();
      return;
    }
    final position = _taskListScrollController.position;
    final next = (position.pixels + _taskDragAutoScrollVelocity * 0.016).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((next - position.pixels).abs() > 0.1) {
      _taskListScrollController.jumpTo(next);
    } else {
      _stopTaskDragAutoScroll();
    }
  }

  void _stopTaskDragAutoScroll() {
    _taskDragAutoScrollVelocity = 0;
    _taskDragAutoScrollTimer?.cancel();
    _taskDragAutoScrollTimer = null;
  }

  Widget _buildTaskDragFeedback(BilibiliDownloadTask task, double width) {
    final episodeCount = task.videos.fold<int>(
      0,
      (total, video) => total + video.episodes.length,
    );
    final unitLabel = task.isCollection
        ? '合集 · ${task.videos.length} 个视频'
        : episodeCount > 1
        ? '分P视频 · $episodeCount P'
        : '独立视频';
    return Transform.scale(
      scale: 1.015,
      child: Material(
        color: Colors.transparent,
        elevation: 18,
        shadowColor: Colors.black87,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: width,
          constraints: const BoxConstraints(minHeight: 76),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF383838),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Colors.pinkAccent.withValues(alpha: 0.9),
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              Icon(
                task.isCollection
                    ? Icons.video_collection_outlined
                    : Icons.drag_indicator_rounded,
                color: Colors.pinkAccent,
                size: 26,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        decoration: TextDecoration.none,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      unitLabel,
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 11,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVirtualRow(
    BilibiliDownloadService service,
    BilibiliDownloadListRow row, {
    required int taskIndex,
    required int taskCount,
  }) {
    final child = switch (row) {
      BilibiliTaskHeaderRow() => _buildTaskCard(service, row.task),
      BilibiliVideoHeaderRow(:final video) => _buildVirtualVideoHeader(
        service,
        row.task,
        video,
      ),
      BilibiliEpisodeRow(
        :final video,
        :final episode,
        :final useSingleControls,
      ) =>
        useSingleControls
            ? _buildSingleEpisodeControls(service, episode, video, row.task)
            : _buildEpisodeRow(service, episode, video, row.task),
    };
    final isHeader = row is BilibiliTaskHeaderRow;
    final isVisuallyCollapsedHeader =
        isHeader && _collapseTaskDescendantsForDrag;
    final isLastInTask = row.isLastInTask || isVisuallyCollapsedHeader;
    final content = Container(
      margin: EdgeInsets.fromLTRB(16, 0, 16, isLastInTask ? 16 : 0),
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2C),
        borderRadius: BorderRadius.vertical(
          top: isHeader ? const Radius.circular(12) : Radius.zero,
          bottom: isLastInTask ? const Radius.circular(12) : Radius.zero,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: RepaintBoundary(child: child),
    );

    if (row is BilibiliTaskHeaderRow) {
      return _buildDraggableTaskHeader(
        service,
        row.task,
        content,
        taskIndex: taskIndex,
        taskCount: taskCount,
      );
    }
    return AnimatedSize(
      duration: _collapseTaskDescendantsForDrag
          ? _taskCollapseDuration
          : _taskRestoreDuration,
      curve: _collapseTaskDescendantsForDrag
          ? Curves.easeOutCubic
          : Curves.easeInOutCubic,
      alignment: Alignment.topCenter,
      clipBehavior: Clip.hardEdge,
      child: _collapseTaskDescendantsForDrag
          ? const SizedBox(width: double.infinity)
          : content,
    );
  }

  Widget _buildTaskInsertionSlot(
    BilibiliDownloadService service,
    int boundary,
  ) {
    final isActive =
        _draggingTaskId != null && _taskDragInsertionIndex == boundary;
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) =>
          details.data == _draggingTaskId && service.taskIds.length > 1,
      onAcceptWithDetails: (details) {
        _commitTaskDrop(details.data, boundary);
      },
      builder: (context, candidateData, rejectedData) {
        final highlighted = isActive || candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          height: isActive ? _draggedTaskExtent : 0,
          margin: EdgeInsets.fromLTRB(16, 0, 16, isActive ? 10 : 0),
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(
            color: Colors.pinkAccent.withValues(alpha: highlighted ? 0.10 : 0),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.pinkAccent.withValues(alpha: highlighted ? 0.8 : 0),
              width: 1.5,
            ),
          ),
          alignment: Alignment.center,
          child: isActive
              ? const Text(
                  '释放以放置任务',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                )
              : null,
        );
      },
    );
  }

  Widget _buildDraggableTaskHeader(
    BilibiliDownloadService service,
    BilibiliDownloadTask task,
    Widget header, {
    required int taskIndex,
    required int taskCount,
  }) {
    Widget buildDropTarget(Widget draggable) {
      return Builder(
        builder: (targetContext) => DragTarget<String>(
          onWillAcceptWithDetails: (details) =>
              details.data == _draggingTaskId && taskCount > 1,
          onMove: (details) {
            _updateTaskDragInsertionIndex(
              _taskBoundaryForPointer(targetContext, details.offset, taskIndex),
            );
          },
          onAcceptWithDetails: (details) {
            final boundary = _taskBoundaryForPointer(
              targetContext,
              details.offset,
              taskIndex,
            );
            _commitTaskDrop(details.data, boundary);
          },
          builder: (context, candidateData, rejectedData) {
            final hovering = candidateData.isNotEmpty;
            return AnimatedScale(
              scale: hovering ? 1.008 : 1,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOutCubic,
              child: Stack(
                children: [
                  draggable,
                  if (hovering)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Container(
                          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.pinkAccent,
                              width: 1.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      );
    }

    final canStartDrag =
        taskCount > 1 && _draggingTaskId == null && !_taskDragFinishing;
    final draggable = LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        return AnimatedSize(
          duration: const Duration(milliseconds: 155),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          clipBehavior: Clip.hardEdge,
          child: LongPressDraggable<String>(
            data: task.taskId,
            delay: const Duration(milliseconds: 420),
            maxSimultaneousDrags: canStartDrag ? 1 : 0,
            hapticFeedbackOnStart: false,
            rootOverlay: true,
            feedback: _buildTaskDragFeedback(task, width),
            feedbackOffset: const Offset(0, -8),
            childWhenDragging: SizedBox(width: width),
            onDragStarted: () {
              final renderObject = context.findRenderObject();
              final extent = renderObject is RenderBox && renderObject.hasSize
                  ? renderObject.size.height
                  : 90.0;
              _beginTaskDrag(service, task, extent);
            },
            onDragUpdate: _handleTaskDragUpdate,
            onDragEnd: (_) => unawaited(_finishTaskDrag(service, task.taskId)),
            child: MouseRegion(
              cursor: canStartDrag
                  ? SystemMouseCursors.grab
                  : MouseCursor.defer,
              child: header,
            ),
          ),
        );
      },
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildTaskInsertionSlot(service, taskIndex),
        buildDropTarget(draggable),
        if (taskIndex == taskCount - 1)
          _buildTaskInsertionSlot(service, taskCount),
      ],
    );
  }

  Widget _buildVirtualVideoHeader(
    BilibiliDownloadService service,
    BilibiliDownloadTask task,
    BilibiliVideoItem video,
  ) {
    return InkWell(
      onTap: () => service.setVideoSelected(task, video, !video.isSelected),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            _buildCheckboxWithSmallThumbnail(
              value: video.isSelected,
              onChanged: (value) =>
                  service.setVideoSelected(task, video, value ?? false),
              thumbnailUrl: video.videoInfo.pic,
              thumbnailWidth: 44,
              thumbnailHeight: 28,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                video.videoInfo.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = Provider.of<BilibiliDownloadService>(
      context,
      listen: false,
    );
    return Focus(
      focusNode: _shortcutFocusNode,
      autofocus: Platform.isWindows,
      onKeyEvent: (node, event) => _handleEscKeyEvent(event),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) {
          if (Platform.isWindows && !_shortcutFocusNode.hasFocus) {
            _shortcutFocusNode.requestFocus();
          }
        },
        child: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          child: Builder(
            builder: (context) {
              final media = MediaQuery.of(context);
              final screenWidth = media.size.width;
              final isCompactAppBar =
                  media.orientation == Orientation.portrait &&
                  screenWidth < 600;
              final double appBarIconSize = isCompactAppBar ? 20 : 24;
              final double appBarButtonSize = isCompactAppBar ? 36 : 40;
              final EdgeInsets appBarIconPadding = EdgeInsets.zero;
              final BoxConstraints appBarIconConstraints =
                  BoxConstraints.tightFor(
                    width: appBarButtonSize,
                    height: appBarButtonSize,
                  );
              final double topHorizontalPadding = (screenWidth * 0.02)
                  .clamp(8.0, 24.0)
                  .toDouble();
              final double topVerticalPadding = (screenWidth * 0.01)
                  .clamp(4.0, 12.0)
                  .toDouble();

              // 横向间距：使用更宽的动态范围，在小屏幕上非常紧凑，在大屏幕上也不会过分拉开
              final double inputToActionsGap = (screenWidth * 0.015)
                  .clamp(4.0, 16.0)
                  .toDouble();
              final double actionGap = (screenWidth * 0.005)
                  .clamp(0.0, 8.0)
                  .toDouble();
              final double actionsToParseGap = (screenWidth * 0.012)
                  .clamp(4.0, 12.0)
                  .toDouble();

              // 按钮尺寸与内边距：基于屏幕宽度做微调
              final double iconButtonPadding = (screenWidth * 0.008)
                  .clamp(2.0, 8.0)
                  .toDouble();
              final double actionIconSize = (screenWidth * 0.035)
                  .clamp(14.0, 20.0)
                  .toDouble();
              final double actionButtonExtent = (screenWidth * 0.06)
                  .clamp(24.0, 36.0)
                  .toDouble();
              final double parseButtonHeight = actionButtonExtent;
              final double parseButtonHorizontalPadding = (screenWidth * 0.025)
                  .clamp(12.0, 24.0)
                  .toDouble();
              final double inputContentPadding = (screenWidth * 0.015)
                  .clamp(8.0, 16.0)
                  .toDouble();
              final int inputMinLines = 2;
              final int inputMaxLines = screenWidth < 480 ? 3 : 4;

              return Scaffold(
                backgroundColor: const Color(0xFF121212),
                appBar: AppBar(
                  titleSpacing: isCompactAppBar ? 8 : null,
                  title: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onDoubleTap: () {
                      service.clearSelection();
                      setState(() => _streamingMode = !_streamingMode);
                    },
                    child: Text(
                      _streamingMode ? 'Bilibili 在线导入' : 'BBDown 下载',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: isCompactAppBar ? 16 : 18),
                    ),
                  ),
                  backgroundColor: const Color(0xFF1E1E1E),
                  actions: [
                    if (!_streamingMode)
                      Selector<
                        BilibiliDownloadService,
                        ({bool supported, bool enabled, bool active})
                      >(
                        selector: (_, currentService) => (
                          supported:
                              currentService.supportsProcessingKeepAwakeToggle,
                          enabled:
                              currentService.keepScreenAwakeDuringProcessing,
                          active: currentService.isProcessingKeepAwakeActive,
                        ),
                        builder: (context, state, _) {
                          final currentService = context
                              .read<BilibiliDownloadService>();
                          _syncKeepAwakeBannerVisibility(currentService);
                          if (!state.supported) {
                            return const SizedBox.shrink();
                          }
                          return _buildProcessingKeepAwakeAction(
                            currentService,
                            isCompactAppBar: isCompactAppBar,
                          );
                        },
                      ),
                    IconButton(
                      icon: Icon(Icons.delete_sweep, size: appBarIconSize),
                      tooltip: "清空任务",
                      padding: appBarIconPadding,
                      constraints: appBarIconConstraints,
                      onPressed: () => _deleteAllTasks(service),
                    ),
                    IconButton(
                      icon: Icon(Icons.settings, size: appBarIconSize),
                      tooltip: _streamingMode ? "解析设置" : "下载设置",
                      padding: appBarIconPadding,
                      constraints: appBarIconConstraints,
                      onPressed: () => _showDownloadSettings(service),
                    ),
                    IconButton(
                      icon: Icon(Icons.person, size: appBarIconSize),
                      onPressed: () => _showCookieDialog(service),
                      tooltip: "登录/Cookie",
                      padding: appBarIconPadding,
                      constraints: appBarIconConstraints,
                    ),
                  ],
                ),
                body: Column(
                  children: [
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: topHorizontalPadding,
                        vertical: topVerticalPadding,
                      ),
                      color: const Color(0xFF1E1E1E),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _inputController,
                              maxLines: inputMaxLines,
                              minLines: inputMinLines,
                              expands: false,
                              keyboardType: TextInputType.multiline,
                              textInputAction: TextInputAction.newline,
                              decoration: InputDecoration(
                                labelText:
                                    "输入 BV号 或 视频链接（链接包含视频标题前缀也可输入） (支持多行)",
                                border: const OutlineInputBorder(),
                                contentPadding: EdgeInsets.all(
                                  inputContentPadding,
                                ),
                                hintText: "每行一个链接，自动忽略前缀...",
                                isDense: true,
                              ),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          SizedBox(width: inputToActionsGap),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: Icon(
                                  Icons.paste,
                                  color: Colors.white70,
                                  size: actionIconSize,
                                ),
                                tooltip: "粘贴",
                                padding: EdgeInsets.all(iconButtonPadding),
                                constraints: BoxConstraints.tightFor(
                                  width: actionButtonExtent,
                                  height: actionButtonExtent,
                                ),
                                onPressed: () async {
                                  final data = await Clipboard.getData(
                                    Clipboard.kTextPlain,
                                  );
                                  if (data?.text != null) {
                                    String currentText = _inputController.text;
                                    if (currentText.isNotEmpty &&
                                        !currentText.endsWith('\n')) {
                                      currentText += '\n';
                                    }
                                    _inputController.text =
                                        currentText + data!.text!;
                                  }
                                },
                              ),
                              SizedBox(width: actionGap),
                              IconButton(
                                icon: Icon(
                                  Icons.clear,
                                  color: Colors.white70,
                                  size: actionIconSize,
                                ),
                                tooltip: "清空",
                                padding: EdgeInsets.all(iconButtonPadding),
                                constraints: BoxConstraints.tightFor(
                                  width: actionButtonExtent,
                                  height: actionButtonExtent,
                                ),
                                onPressed: () {
                                  _inputController.clear();
                                },
                              ),
                              SizedBox(width: actionGap),
                              IconButton(
                                icon: Icon(
                                  Icons.keyboard_return,
                                  color: Colors.white70,
                                  size: actionIconSize,
                                ),
                                tooltip: "换行",
                                padding: EdgeInsets.all(iconButtonPadding),
                                constraints: BoxConstraints.tightFor(
                                  width: actionButtonExtent,
                                  height: actionButtonExtent,
                                ),
                                onPressed: () {
                                  final text = _inputController.text;
                                  final selection = _inputController.selection;
                                  final newText = text.replaceRange(
                                    selection.start,
                                    selection.end,
                                    "\n",
                                  );
                                  _inputController.value = TextEditingValue(
                                    text: newText,
                                    selection: TextSelection.collapsed(
                                      offset: selection.start + 1,
                                    ),
                                  );
                                },
                              ),
                              SizedBox(width: actionsToParseGap),
                              Selector<BilibiliDownloadService, bool>(
                                selector: (_, s) => s.isParsing,
                                builder: (context, isParsing, _) {
                                  final service = context
                                      .read<BilibiliDownloadService>();
                                  return ElevatedButton(
                                    onPressed: isParsing
                                        ? null
                                        : () => _parseVideo(service),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.pinkAccent,
                                      foregroundColor: Colors.white,
                                      padding: EdgeInsets.symmetric(
                                        horizontal:
                                            parseButtonHorizontalPadding,
                                        vertical: 0,
                                      ),
                                      minimumSize: Size(64, parseButtonHeight),
                                    ),
                                    child: isParsing
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white,
                                            ),
                                          )
                                        : const Text("解析"),
                                  );
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Selector<BilibiliDownloadService, String?>(
                      selector: (_, s) => s.parsingStatus,
                      builder: (context, parsingStatus, _) {
                        if (parsingStatus == null) {
                          return const SizedBox.shrink();
                        }
                        return Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          color: Colors.black54,
                          child: Text(
                            parsingStatus,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        );
                      },
                    ),
                    if (!_streamingMode)
                      Selector<
                        BilibiliDownloadService,
                        ({bool enabled, bool active})
                      >(
                        selector: (_, service) => (
                          enabled: service.keepScreenAwakeDuringProcessing,
                          active: service.isProcessingKeepAwakeActive,
                        ),
                        builder: (context, _, _) {
                          final service = context
                              .read<BilibiliDownloadService>();
                          _syncKeepAwakeBannerVisibility(service);
                          return _buildProcessingKeepAwakeBanner(service);
                        },
                      ),
                    Expanded(
                      child:
                          Selector<
                            BilibiliDownloadService,
                            ({List<String> ids, int structureRevision})
                          >(
                            selector: (_, service) => (
                              ids: service.taskIdsForMode(_streamingMode),
                              structureRevision: service.listStructureRevision,
                            ),
                            builder: (context, snapshot, _) {
                              if (snapshot.ids.isEmpty) {
                                return const Center(
                                  child: Text(
                                    "请输入链接并解析",
                                    style: TextStyle(color: Colors.white30),
                                  ),
                                );
                              }
                              final service = context
                                  .read<BilibiliDownloadService>();
                              final activeDragTaskId = _draggingTaskId;
                              if (activeDragTaskId != null &&
                                  (snapshot.ids.length < 2 ||
                                      !snapshot.ids.contains(
                                        activeDragTaskId,
                                      )) &&
                                  !_taskDragRecoveryScheduled) {
                                _taskDragRecoveryScheduled = true;
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  _taskDragRecoveryScheduled = false;
                                  if (mounted &&
                                      _draggingTaskId == activeDragTaskId) {
                                    unawaited(
                                      _finishTaskDrag(
                                        service,
                                        activeDragTaskId,
                                      ),
                                    );
                                  }
                                });
                              }
                              final rows = _buildVirtualRows(service);
                              final taskIndexById = <String, int>{
                                for (
                                  var index = 0;
                                  index < snapshot.ids.length;
                                  index++
                                )
                                  snapshot.ids[index]: index,
                              };
                              final rowIndexByKey = <Key, int>{
                                for (
                                  var index = 0;
                                  index < rows.length;
                                  index++
                                )
                                  _virtualRowKey(service, rows[index]): index,
                              };
                              return ListView.builder(
                                key: _taskListViewportKey,
                                controller: _taskListScrollController,
                                padding: const EdgeInsets.only(top: 16),
                                itemCount: rows.length,
                                findChildIndexCallback: (key) =>
                                    rowIndexByKey[key],
                                scrollCacheExtent:
                                    const ScrollCacheExtent.viewport(1),
                                addAutomaticKeepAlives: false,
                                addRepaintBoundaries: true,
                                addSemanticIndexes: false,
                                itemBuilder: (context, index) {
                                  final row = rows[index];
                                  if (row case BilibiliEpisodeRow(
                                    :final episode,
                                  )) {
                                    return Selector<
                                      BilibiliDownloadService,
                                      int
                                    >(
                                      key: _virtualRowKey(service, row),
                                      selector: (_, current) =>
                                          current.episodeRevision(episode),
                                      builder: (context, _, _) =>
                                          _buildVirtualRow(
                                            service,
                                            row,
                                            taskIndex:
                                                taskIndexById[row
                                                    .task
                                                    .taskId] ??
                                                0,
                                            taskCount: snapshot.ids.length,
                                          ),
                                    );
                                  }
                                  return Selector<BilibiliDownloadService, int>(
                                    key: _virtualRowKey(service, row),
                                    selector: (_, current) =>
                                        current.taskRevision(row.task.taskId),
                                    builder: (context, _, _) =>
                                        _buildVirtualRow(
                                          service,
                                          row,
                                          taskIndex:
                                              taskIndexById[row.task.taskId] ??
                                              0,
                                          taskCount: snapshot.ids.length,
                                        ),
                                  );
                                },
                              );
                            },
                          ),
                    ),
                  ],
                ),
                bottomNavigationBar:
                    Selector<
                      BilibiliDownloadService,
                      ({int taskCount, BilibiliSelectionSummary selection})
                    >(
                      selector: (_, service) => (
                        taskCount: service
                            .taskIdsForMode(_streamingMode)
                            .length,
                        selection: service.selectionSummaryForMode(
                          _streamingMode,
                        ),
                      ),
                      builder: (context, summary, _) {
                        final service = context.read<BilibiliDownloadService>();
                        if (summary.taskCount == 0) {
                          return const SizedBox.shrink();
                        }
                        return _buildBottomBar(service, summary.selection);
                      },
                    ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildTaskCard(
    BilibiliDownloadService service,
    BilibiliDownloadTask task,
  ) {
    bool isSingle =
        !task.isCollection &&
        task.videos.length == 1 &&
        task.videos.first.episodes.length == 1;
    final media = MediaQuery.of(context);
    final isCompactTitle =
        media.orientation == Orientation.portrait && media.size.width < 600;

    return Card(
      color: const Color(0xFF2C2C2C),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          InkWell(
            onTap: _collapseTaskDescendantsForDrag
                ? null
                : () {
                    service.setTaskExpanded(task, !task.isExpanded);
                  },
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Checkbox(
                    value: task.isSelected,
                    activeColor: Colors.pinkAccent,
                    onChanged: (val) {
                      service.setTaskSelected(task, val ?? false);
                    },
                  ),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: _buildNetworkThumbnail(
                      url: task.cover,
                      width: 80,
                      height: 50,
                      imageKey: ValueKey(
                        'bb-task-thumb-${task.taskId}-${task.cover}',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: InkWell(
                      onTap:
                          (!_streamingMode &&
                              isSingle &&
                              task.videos.first.episodes.first.status ==
                                  DownloadStatus.completed)
                          ? () => _previewVideo(
                              task.videos.first.episodes.first,
                              task: task,
                              video: task.videos.first,
                            )
                          : null,
                      child: Text(
                        task.title,
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          decoration:
                              (!_streamingMode &&
                                  isSingle &&
                                  task.videos.first.episodes.first.status ==
                                      DownloadStatus.completed)
                              ? TextDecoration.underline
                              : null,
                          fontSize: isCompactTitle ? 13 : 14,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(
                      Icons.drag_handle_rounded,
                      color: Colors.white38,
                      size: 20,
                      semanticLabel: '长按拖动排序',
                    ),
                  ),
                  Icon(
                    task.isExpanded && !_collapseTaskDescendantsForDrag
                        ? Icons.expand_less
                        : Icons.expand_more,
                    color: Colors.white70,
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.refresh,
                      size: 20,
                      color: Colors.white70,
                    ),
                    tooltip: "刷新任务信息",
                    onPressed: () {
                      for (var v in task.videos) {
                        for (var ep in v.episodes) {
                          service.refreshEpisodeInfo(ep);
                        }
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSingleEpisodeControls(
    BilibiliDownloadService service,
    BilibiliDownloadEpisode ep,
    BilibiliVideoItem video,
    BilibiliDownloadTask task,
  ) {
    bool hasInfo = _streamingMode || ep.availableVideoQualities.isNotEmpty;
    final episodeStatusText = _episodeStatusText(ep);
    final media = MediaQuery.of(context);
    final isCompact =
        media.orientation == Orientation.portrait && media.size.width < 600;
    final double compactButtonSize = isCompact ? 26 : 28;
    final double compactIconSize = isCompact ? 19 : 20;
    final EdgeInsets iconPadding = isCompact
        ? EdgeInsets.zero
        : const EdgeInsets.all(4);
    final BoxConstraints iconConstraints = isCompact
        ? BoxConstraints.tightFor(
            width: compactButtonSize,
            height: compactButtonSize,
          )
        : const BoxConstraints(minWidth: 28, minHeight: 28);
    final VisualDensity iconDensity = isCompact
        ? const VisualDensity(horizontal: -4, vertical: -4)
        : VisualDensity.standard;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        children: [
          Row(
            children: [
              if (hasInfo || ep.status == DownloadStatus.completed)
                Expanded(
                  child: Row(
                    mainAxisSize: MainAxisSize.max,
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      // Quality
                      if (!_streamingMode)
                        Flexible(
                          flex: 3,
                          child: Container(
                            height: 28,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.05),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<StreamItem>(
                                value: ep.selectedVideoQuality,
                                isDense: true,
                                isExpanded: true,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white,
                                ),
                                dropdownColor: const Color(0xFF333333),
                                icon: const Icon(
                                  Icons.arrow_drop_down,
                                  size: 16,
                                  color: Colors.white54,
                                ),
                                selectedItemBuilder: (BuildContext context) {
                                  return ep.availableVideoQualities.map<Widget>(
                                    (StreamItem s) {
                                      String label =
                                          s.qualityName?.replaceAll("高清", "") ??
                                          "Q${s.id}";
                                      String codec = "";
                                      if (s.codecs.startsWith("avc1")) {
                                        codec = "AVC";
                                      } else if (s.codecs.startsWith("hev1") ||
                                          s.codecs.contains("hevc")) {
                                        codec = "HEVC";
                                      } else if (s.codecs.startsWith("av01")) {
                                        codec = "AV1";
                                      } else {
                                        codec = s.codecs.split('.')[0];
                                      }
                                      String detailedLabel = "$label ($codec)";
                                      return Container(
                                        alignment: Alignment.centerLeft,
                                        constraints: const BoxConstraints(
                                          minWidth: 50,
                                        ),
                                        child: SingleChildScrollView(
                                          scrollDirection: Axis.horizontal,
                                          child: Text(
                                            detailedLabel,
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ).toList();
                                },
                                items: ep.availableVideoQualities.map((s) {
                                  String label =
                                      s.qualityName?.replaceAll("高清", "") ??
                                      "Q${s.id}";
                                  String codec = "";
                                  if (s.codecs.startsWith("avc1")) {
                                    codec = "AVC";
                                  } else if (s.codecs.startsWith("hev1") ||
                                      s.codecs.contains("hevc")) {
                                    codec = "HEVC";
                                  } else if (s.codecs.startsWith("av01")) {
                                    codec = "AV1";
                                  } else {
                                    codec = s.codecs.split('.')[0];
                                  }
                                  String detailedLabel = "$label ($codec)";
                                  return DropdownMenuItem(
                                    value: s,
                                    child: Text(
                                      detailedLabel,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  );
                                }).toList(),
                                onChanged: (val) {
                                  service.setEpisodeVideoQuality(task, ep, val);
                                },
                                hint: const Text(
                                  "清晰度",
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.white54,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (!_streamingMode) const SizedBox(width: 4),
                      // Subtitle
                      Flexible(
                        flex: 2,
                        child: Container(
                          height: 28,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<BilibiliSubtitle?>(
                              value: ep.selectedSubtitle,
                              isDense: true,
                              isExpanded: true,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.white,
                              ),
                              dropdownColor: const Color(0xFF333333),
                              icon: const Icon(
                                Icons.arrow_drop_down,
                                size: 16,
                                color: Colors.white54,
                              ),
                              items: [
                                const DropdownMenuItem<BilibiliSubtitle?>(
                                  value: null,
                                  child: Text("无字幕"),
                                ),
                                ...ep.availableSubtitles.map(
                                  (s) => DropdownMenuItem(
                                    value: s,
                                    child: Text(
                                      s.lanDoc,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              ],
                              onChanged: (val) {
                                service.setEpisodeSubtitle(task, ep, val);
                              },
                              hint: const Text(
                                "字幕",
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.white54,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 2),
                      // Action Button
                      if (_streamingMode)
                        IconButton(
                          icon: Icon(
                            Icons.file_upload_outlined,
                            size: compactIconSize,
                            color: Colors.white70,
                          ),
                          tooltip: '导出在线播放条目',
                          padding: iconPadding,
                          constraints: iconConstraints,
                          visualDensity: iconDensity,
                          onPressed: () =>
                              _exportStreaming(service, episode: ep),
                        )
                      else if (ep.status == DownloadStatus.downloading)
                        IconButton(
                          icon: Icon(
                            Icons.pause,
                            size: compactIconSize,
                            color: Colors.white70,
                          ),
                          tooltip: "暂停",
                          padding: iconPadding,
                          constraints: iconConstraints,
                          visualDensity: iconDensity,
                          onPressed: () => service.pauseDownload(ep),
                        )
                      else
                        IconButton(
                          icon: Icon(
                            _episodeActionIcon(ep),
                            size: compactIconSize,
                            color: _episodeActionColor(ep),
                          ),
                          tooltip: _episodeActionTooltip(ep),
                          padding: iconPadding,
                          constraints: iconConstraints,
                          visualDensity: iconDensity,
                          onPressed: () {
                            if (ep.status == DownloadStatus.queued) {
                              service.pauseDownload(ep);
                            } else if (ep.status == DownloadStatus.failed) {
                              service.startSingleDownload(ep);
                            } else {
                              service.startSingleDownload(ep);
                            }
                          },
                        ),
                      // More Menu
                      PopupMenuButton<String>(
                        icon: Icon(
                          Icons.more_vert,
                          size: compactIconSize,
                          color: Colors.white70,
                        ),
                        padding: EdgeInsets.zero,
                        offset: Offset(0, compactButtonSize),
                        color: const Color(0xFF333333),
                        onSelected: (value) {
                          switch (value) {
                            case 'top':
                              service.startSingleDownload(ep, toTop: true);
                              break;
                            case 'export':
                              if (_streamingMode) {
                                _exportStreaming(service, episode: ep);
                              } else {
                                _importToLibrary(service, episode: ep);
                              }
                              break;
                            case 'delete':
                              service.removeEpisode(ep, task);
                              break;
                            case 'preview_sub':
                              if (ep.selectedSubtitle != null) {
                                _showSubtitlePreview(
                                  service,
                                  ep.selectedSubtitle!,
                                );
                              }
                              break;
                          }
                        },
                        itemBuilder: (context) => [
                          if (!_streamingMode &&
                              (ep.status == DownloadStatus.pending ||
                                  ep.status == DownloadStatus.failed ||
                                  ep.status == DownloadStatus.queued))
                            const PopupMenuItem(
                              value: 'top',
                              height: 36,
                              child: Row(
                                children: [
                                  Icon(Icons.vertical_align_top, size: 18),
                                  SizedBox(width: 12),
                                  Text("插队", style: TextStyle(fontSize: 14)),
                                ],
                              ),
                            ),
                          if (_streamingMode ||
                              ep.status == DownloadStatus.completed)
                            const PopupMenuItem(
                              value: 'export',
                              height: 36,
                              child: Row(
                                children: [
                                  Icon(Icons.file_upload, size: 18),
                                  SizedBox(width: 12),
                                  Text("导出", style: TextStyle(fontSize: 14)),
                                ],
                              ),
                            ),
                          if (ep.selectedSubtitle != null)
                            const PopupMenuItem(
                              value: 'preview_sub',
                              height: 36,
                              child: Row(
                                children: [
                                  Icon(Icons.description, size: 18),
                                  SizedBox(width: 12),
                                  Text("预览字幕", style: TextStyle(fontSize: 14)),
                                ],
                              ),
                            ),
                          const PopupMenuItem(
                            value: 'delete',
                            height: 36,
                            child: Row(
                              children: [
                                Icon(
                                  Icons.delete,
                                  size: 18,
                                  color: Colors.redAccent,
                                ),
                                SizedBox(width: 12),
                                Text(
                                  "删除任务",
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.redAccent,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                )
              else if (ep.status == DownloadStatus.fetchingInfo)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                TextButton.icon(
                  onPressed: () => service.refreshEpisodeInfo(ep),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text("获取信息"),
                ),
            ],
          ),

          if (ep.status == DownloadStatus.downloading ||
              ep.status == DownloadStatus.merging ||
              ep.status == DownloadStatus.checking ||
              ep.status == DownloadStatus.repairing)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (ep.status == DownloadStatus.checking)
                    const LinearProgressIndicator(
                      backgroundColor: Colors.grey,
                      color: Colors.blueAccent,
                      minHeight: 4,
                    )
                  else if (ep.status == DownloadStatus.repairing)
                    LinearProgressIndicator(
                      value: ep.progress > 0
                          ? ep.progress
                          : null, // Indeterminate if 0
                      backgroundColor: Colors.grey,
                      color: Colors.orangeAccent,
                      minHeight: 4,
                    )
                  else
                    LinearProgressIndicator(
                      value: ep.progress,
                      backgroundColor: Colors.grey[800],
                      color: Colors.orangeAccent,
                      minHeight: 4,
                    ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        (ep.status == DownloadStatus.checking)
                            ? ""
                            : "${(ep.progress * 100).toStringAsFixed(1)}%",
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                      if (ep.downloadSpeed != null)
                        Row(
                          children: [
                            if (ep.downloadSize != null &&
                                ep.status != DownloadStatus.checking &&
                                ep.status != DownloadStatus.repairing)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: Text(
                                  ep.downloadSize!,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            Text(
                              ep.downloadSpeed!,
                              style: TextStyle(
                                color: (ep.status == DownloadStatus.repairing)
                                    ? Colors.orangeAccent
                                    : Colors.white70,
                                fontSize: 12,
                                fontWeight:
                                    (ep.status == DownloadStatus.repairing)
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ],
              ),
            ),

          // Status Text for Completed/Exported
          if (ep.status == DownloadStatus.completed && ep.downloadSpeed != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.check,
                    size: 14,
                    color: ep.isExported
                        ? Colors.blueAccent
                        : Colors.greenAccent,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    ep.downloadSpeed!,
                    style: TextStyle(
                      color: ep.isExported
                          ? Colors.blueAccent
                          : Colors.greenAccent,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),

          if (episodeStatusText != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                episodeStatusText,
                style: TextStyle(
                  color: _episodeErrorColor(episodeStatusText),
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEpisodeRow(
    BilibiliDownloadService service,
    BilibiliDownloadEpisode ep,
    BilibiliVideoItem video,
    BilibiliDownloadTask task,
  ) {
    bool hasInfo = _streamingMode || ep.availableVideoQualities.isNotEmpty;
    bool isCompleted = ep.status == DownloadStatus.completed;
    final episodeStatusText = _episodeStatusText(ep);
    final media = MediaQuery.of(context);
    final isCompact =
        media.orientation == Orientation.portrait && media.size.width < 600;
    final double compactButtonSize = isCompact ? 26 : 28;
    final double compactIconSize = isCompact ? 19 : 20;
    final EdgeInsets iconPadding = isCompact
        ? EdgeInsets.zero
        : const EdgeInsets.all(4);
    final BoxConstraints iconConstraints = isCompact
        ? BoxConstraints.tightFor(
            width: compactButtonSize,
            height: compactButtonSize,
          )
        : const BoxConstraints(minWidth: 28, minHeight: 28);
    final VisualDensity iconDensity = isCompact
        ? const VisualDensity(horizontal: -4, vertical: -4)
        : VisualDensity.standard;

    double leftPadding = 16.0;
    if (task.isCollection) {
      if (video.episodes.length > 1) {
        leftPadding = 32.0;
      } else {
        leftPadding = 16.0;
      }
    }

    return InkWell(
      onTap: () {
        service.setEpisodeSelected(task, video, ep, !ep.isSelected);
      },
      child: Container(
        padding: EdgeInsets.fromLTRB(
          leftPadding,
          8,
          8,
          8,
        ), // Reduce right padding
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
          ),
        ),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (task.isCollection && video.episodes.length == 1)
                  _buildCheckboxWithSmallThumbnail(
                    value: ep.isSelected,
                    onChanged: (val) {
                      service.setEpisodeSelected(task, video, ep, val ?? false);
                    },
                    thumbnailUrl: video.videoInfo.pic,
                    thumbnailWidth: 40,
                    thumbnailHeight: 26,
                  )
                else
                  Checkbox(
                    value: ep.isSelected,
                    activeColor: Colors.pinkAccent,
                    onChanged: (val) {
                      service.setEpisodeSelected(task, video, ep, val ?? false);
                    },
                  ),

                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Title Row with Action Buttons
                      Row(
                        children: [
                          Expanded(
                            child: InkWell(
                              onTap: isCompleted && !_streamingMode
                                  ? () => _previewVideo(
                                      ep,
                                      task: task,
                                      video: video,
                                    )
                                  : null,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                child: Text(
                                  video.episodes.length == 1
                                      ? (task.isCollection
                                            ? video.videoInfo.title
                                            : "P${ep.page.page} ${ep.page.part}")
                                      : "P${ep.page.page} ${ep.page.part}",
                                  style: TextStyle(
                                    color: Colors.white70,
                                    decoration: isCompleted
                                        ? TextDecoration.underline
                                        : null,
                                    decorationColor: Colors.white70,
                                    fontSize: isCompact ? 13 : 14,
                                    height: 1.3,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ),
                          // Refresh Button (always visible if not fetching)
                          SizedBox(
                            width: compactButtonSize,
                            height: compactButtonSize,
                            child: ep.status == DownloadStatus.fetchingInfo
                                ? const Center(
                                    child: SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  )
                                : IconButton(
                                    icon: Icon(
                                      Icons.refresh,
                                      color: Colors.white70,
                                      size: compactIconSize,
                                    ),
                                    tooltip: "刷新信息",
                                    padding: iconPadding,
                                    constraints: iconConstraints,
                                    visualDensity: iconDensity,
                                    onPressed: () =>
                                        service.refreshEpisodeInfo(ep),
                                  ),
                          ),

                          // Action Buttons (Download/Pause/More) moved here
                          if (hasInfo ||
                              ep.status == DownloadStatus.completed) ...[
                            if (_streamingMode)
                              IconButton(
                                icon: Icon(
                                  Icons.file_upload_outlined,
                                  size: compactIconSize,
                                  color: Colors.white70,
                                ),
                                tooltip: '导出在线播放条目',
                                padding: iconPadding,
                                constraints: iconConstraints,
                                visualDensity: iconDensity,
                                onPressed: () =>
                                    _exportStreaming(service, episode: ep),
                              )
                            else if (ep.status == DownloadStatus.downloading)
                              IconButton(
                                icon: Icon(
                                  Icons.pause,
                                  size: compactIconSize,
                                  color: Colors.white70,
                                ),
                                tooltip: "暂停",
                                padding: iconPadding,
                                constraints: iconConstraints,
                                visualDensity: iconDensity,
                                onPressed: () => service.pauseDownload(ep),
                              )
                            else
                              IconButton(
                                icon: Icon(
                                  _episodeActionIcon(ep),
                                  size: compactIconSize,
                                  color: _episodeActionColor(ep),
                                ),
                                tooltip: _episodeActionTooltip(ep),
                                padding: iconPadding,
                                constraints: iconConstraints,
                                visualDensity: iconDensity,
                                onPressed: () {
                                  if (ep.status == DownloadStatus.queued) {
                                    service.pauseDownload(ep);
                                  } else if (ep.status ==
                                      DownloadStatus.failed) {
                                    service.startSingleDownload(ep);
                                  } else {
                                    service.startSingleDownload(ep);
                                  }
                                },
                              ),

                            // More Menu
                            SizedBox(
                              width: compactButtonSize,
                              height: compactButtonSize,
                              child: PopupMenuButton<String>(
                                icon: Icon(
                                  Icons.more_vert,
                                  size: compactIconSize,
                                  color: Colors.white70,
                                ),
                                padding: EdgeInsets.zero,
                                offset: Offset(0, compactButtonSize),
                                color: const Color(0xFF333333),
                                onSelected: (value) {
                                  switch (value) {
                                    case 'top':
                                      service.startSingleDownload(
                                        ep,
                                        toTop: true,
                                      );
                                      break;
                                    case 'export':
                                      if (_streamingMode) {
                                        _exportStreaming(service, episode: ep);
                                      } else {
                                        _importToLibrary(service, episode: ep);
                                      }
                                      break;
                                    case 'delete':
                                      service.removeEpisode(ep, task);
                                      break;
                                    case 'preview_sub':
                                      if (ep.selectedSubtitle != null) {
                                        _showSubtitlePreview(
                                          service,
                                          ep.selectedSubtitle!,
                                        );
                                      }
                                      break;
                                  }
                                },
                                itemBuilder: (context) => [
                                  if (!_streamingMode &&
                                      (ep.status == DownloadStatus.pending ||
                                          ep.status == DownloadStatus.failed ||
                                          ep.status == DownloadStatus.queued))
                                    const PopupMenuItem(
                                      value: 'top',
                                      height: 36,
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.vertical_align_top,
                                            size: 18,
                                          ),
                                          SizedBox(width: 12),
                                          Text(
                                            "插队",
                                            style: TextStyle(fontSize: 14),
                                          ),
                                        ],
                                      ),
                                    ),

                                  if (_streamingMode ||
                                      ep.status == DownloadStatus.completed)
                                    const PopupMenuItem(
                                      value: 'export',
                                      height: 36,
                                      child: Row(
                                        children: [
                                          Icon(Icons.file_upload, size: 18),
                                          SizedBox(width: 12),
                                          Text(
                                            "导出",
                                            style: TextStyle(fontSize: 14),
                                          ),
                                        ],
                                      ),
                                    ),

                                  if (ep.selectedSubtitle != null)
                                    const PopupMenuItem(
                                      value: 'preview_sub',
                                      height: 36,
                                      child: Row(
                                        children: [
                                          Icon(Icons.description, size: 18),
                                          SizedBox(width: 12),
                                          Text(
                                            "预览字幕",
                                            style: TextStyle(fontSize: 14),
                                          ),
                                        ],
                                      ),
                                    ),

                                  const PopupMenuItem(
                                    value: 'delete',
                                    height: 36,
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.delete,
                                          size: 18,
                                          color: Colors.redAccent,
                                        ),
                                        SizedBox(width: 12),
                                        Text(
                                          "删除任务",
                                          style: TextStyle(
                                            fontSize: 14,
                                            color: Colors.redAccent,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),

                      // Settings Row (Quality & Subtitle) - Only show if info available
                      if (hasInfo || ep.status == DownloadStatus.completed)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              // Quality
                              if (!_streamingMode)
                                Flexible(
                                  flex: 3,
                                  child: Container(
                                    height: 28,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(
                                        alpha: 0.05,
                                      ),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: DropdownButtonHideUnderline(
                                      child: DropdownButton<StreamItem>(
                                        value: ep.selectedVideoQuality,
                                        isDense: true,
                                        isExpanded: true,
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: Colors.white,
                                        ),
                                        dropdownColor: const Color(0xFF333333),
                                        icon: const Icon(
                                          Icons.arrow_drop_down,
                                          size: 16,
                                          color: Colors.white54,
                                        ),
                                        selectedItemBuilder:
                                            (BuildContext context) {
                                              return ep.availableVideoQualities
                                                  .map<Widget>((StreamItem s) {
                                                    String label =
                                                        s.qualityName
                                                            ?.replaceAll(
                                                              "高清",
                                                              "",
                                                            ) ??
                                                        "Q${s.id}";
                                                    String codec = "";
                                                    if (s.codecs.startsWith(
                                                      "avc1",
                                                    )) {
                                                      codec = "AVC";
                                                    } else if (s.codecs
                                                            .startsWith(
                                                              "hev1",
                                                            ) ||
                                                        s.codecs.contains(
                                                          "hevc",
                                                        )) {
                                                      codec = "HEVC";
                                                    } else if (s.codecs
                                                        .startsWith("av01")) {
                                                      codec = "AV1";
                                                    } else {
                                                      codec = s.codecs.split(
                                                        '.',
                                                      )[0];
                                                    }
                                                    String detailedLabel =
                                                        "$label ($codec)";
                                                    return Container(
                                                      alignment:
                                                          Alignment.centerLeft,
                                                      constraints:
                                                          const BoxConstraints(
                                                            minWidth: 50,
                                                          ),
                                                      child: SingleChildScrollView(
                                                        scrollDirection:
                                                            Axis.horizontal,
                                                        child: Text(
                                                          detailedLabel,
                                                          style:
                                                              const TextStyle(
                                                                fontSize: 11,
                                                                color: Colors
                                                                    .white,
                                                              ),
                                                        ),
                                                      ),
                                                    );
                                                  })
                                                  .toList();
                                            },
                                        items: ep.availableVideoQualities.map((
                                          s,
                                        ) {
                                          String label =
                                              s.qualityName?.replaceAll(
                                                "高清",
                                                "",
                                              ) ??
                                              "Q${s.id}";
                                          String codec = "";
                                          if (s.codecs.startsWith("avc1")) {
                                            codec = "AVC";
                                          } else if (s.codecs.startsWith(
                                                "hev1",
                                              ) ||
                                              s.codecs.contains("hevc")) {
                                            codec = "HEVC";
                                          } else if (s.codecs.startsWith(
                                            "av01",
                                          )) {
                                            codec = "AV1";
                                          } else {
                                            codec = s.codecs.split('.')[0];
                                          }
                                          String detailedLabel =
                                              "$label ($codec)";

                                          return DropdownMenuItem(
                                            value: s,
                                            child: Text(
                                              detailedLabel,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          );
                                        }).toList(),
                                        onChanged: (val) {
                                          service.setEpisodeVideoQuality(
                                            task,
                                            ep,
                                            val,
                                          );
                                        },
                                        hint: const Text(
                                          "清晰度",
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.white54,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),

                              if (!_streamingMode) const SizedBox(width: 4),

                              // Subtitle
                              Flexible(
                                flex: 2,
                                child: Container(
                                  height: 28,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.05),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: DropdownButtonHideUnderline(
                                    child: DropdownButton<BilibiliSubtitle?>(
                                      value: ep.selectedSubtitle,
                                      isDense: true,
                                      isExpanded: true,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Colors.white,
                                      ),
                                      dropdownColor: const Color(0xFF333333),
                                      icon: const Icon(
                                        Icons.arrow_drop_down,
                                        size: 16,
                                        color: Colors.white54,
                                      ),
                                      items: [
                                        const DropdownMenuItem<
                                          BilibiliSubtitle?
                                        >(value: null, child: Text("无字幕")),
                                        ...ep.availableSubtitles.map(
                                          (s) => DropdownMenuItem(
                                            value: s,
                                            child: Text(
                                              s.lanDoc,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ),
                                      ],
                                      onChanged: (val) {
                                        service.setEpisodeSubtitle(
                                          task,
                                          ep,
                                          val,
                                        );
                                      },
                                      hint: const Text(
                                        "字幕",
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.white54,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),

            // Progress Bar Area (unchanged)
            if (ep.status == DownloadStatus.downloading ||
                ep.status == DownloadStatus.merging ||
                ep.status == DownloadStatus.checking ||
                ep.status == DownloadStatus.repairing)
              Padding(
                padding: const EdgeInsets.only(left: 48, right: 16, top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (ep.status == DownloadStatus.checking)
                      const LinearProgressIndicator(
                        backgroundColor: Colors.grey,
                        color: Colors.blueAccent,
                        minHeight: 2,
                      )
                    else if (ep.status == DownloadStatus.repairing)
                      LinearProgressIndicator(
                        value: ep.progress > 0 ? ep.progress : null,
                        backgroundColor: Colors.grey,
                        color: Colors.orangeAccent,
                        minHeight: 2,
                      )
                    else
                      LinearProgressIndicator(
                        value: ep.progress,
                        backgroundColor: Colors.grey[800],
                        color: Colors.orangeAccent,
                        minHeight: 2,
                      ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          (ep.status == DownloadStatus.checking)
                              ? ""
                              : "${(ep.progress * 100).toStringAsFixed(1)}%",
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 10,
                          ),
                        ),
                        if (ep.downloadSpeed != null)
                          Row(
                            children: [
                              if (ep.downloadSize != null &&
                                  ep.status != DownloadStatus.checking &&
                                  ep.status != DownloadStatus.repairing)
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: Text(
                                    ep.downloadSize!,
                                    style: const TextStyle(
                                      color: Colors.white38,
                                      fontSize: 10,
                                    ),
                                  ),
                                ),
                              Text(
                                ep.downloadSpeed!,
                                style: TextStyle(
                                  color: (ep.status == DownloadStatus.repairing)
                                      ? Colors.orangeAccent
                                      : Colors.white38,
                                  fontSize: 10,
                                  fontWeight:
                                      (ep.status == DownloadStatus.repairing)
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ],
                ),
              ),

            // Status Text for Completed/Exported (Small)
            if (ep.status == DownloadStatus.completed &&
                ep.downloadSpeed != null)
              Padding(
                padding: const EdgeInsets.only(left: 48, top: 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.check,
                      size: 10,
                      color: ep.isExported
                          ? Colors.blueAccent
                          : Colors.greenAccent,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      ep.downloadSpeed!,
                      style: TextStyle(
                        color: ep.isExported
                            ? Colors.blueAccent
                            : Colors.greenAccent,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),

            if (episodeStatusText != null)
              Padding(
                padding: const EdgeInsets.only(left: 48, top: 4),
                child: Text(
                  episodeStatusText,
                  style: TextStyle(
                    color: _episodeErrorColor(episodeStatusText),
                    fontSize: 10,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(
    BilibiliDownloadService service,
    BilibiliSelectionSummary selection,
  ) {
    return BottomAppBar(
      color: const Color(0xFF1E1E1E),
      padding: EdgeInsets.zero,
      child: SizedBox(
        height: 64,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildSelectionAction(
              Icons.select_all,
              "全选",
              () => service.selectAllForMode(_streamingMode),
              selection,
            ),
            if (_streamingMode)
              _buildBottomAction(
                Icons.file_upload_outlined,
                "导出到媒体库",
                () => _exportStreaming(service),
              )
            else ...[
              _buildBottomAction(
                Icons.download,
                "下载并合并",
                service.startDownloadSelected,
              ),
              _buildBottomAction(Icons.pause, "暂停下载", service.pauseSelected),
              _buildBottomAction(
                Icons.file_upload,
                "导入到媒体库",
                () => _importToLibrary(service),
              ),
            ],
            _buildBottomAction(
              Icons.delete,
              "移除",
              service.removeSelected,
              isDestructive: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectionAction(
    IconData icon,
    String label,
    VoidCallback onTap,
    BilibiliSelectionSummary selection,
  ) {
    final isSmallScreen = MediaQuery.sizeOf(context).width < 400;
    final detailText =
        '独立视频 ${selection.standaloneVideoCount} 个\n'
        '分P视频 ${selection.multipartVideoCount} 个，已选 ${selection.multipartPartCount} 个分P\n'
        '合集 ${selection.collectionCount} 个，合集内视频 ${selection.collectionVideoCount} 个'
        '${selection.collectionItemCount == selection.collectionVideoCount ? '' : '，已选 ${selection.collectionItemCount} 项'}';

    return Expanded(
      child: Tooltip(
        message: detailText,
        triggerMode: TooltipTriggerMode.longPress,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: isSmallScreen ? 2 : 4,
              vertical: 4,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: Colors.white, size: isSmallScreen ? 18 : 20),
                const SizedBox(height: 1),
                Text(
                  '$label · ${selection.selectedItemCount}项',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: isSmallScreen ? 9 : 10,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 1),
                Text(
                  '单${selection.standaloneVideoCount}  分P${selection.multipartVideoCount}/${selection.multipartPartCount}',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: isSmallScreen ? 8.5 : 9,
                    height: 1.05,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '合集${selection.collectionCount}/${selection.collectionVideoCount}',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: isSmallScreen ? 8.5 : 9,
                    height: 1.05,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomAction(
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool isDestructive = false,
    String? subtitle,
  }) {
    final isSmallScreen = MediaQuery.of(context).size.width < 400;

    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: isSmallScreen ? 4.0 : 8.0,
            vertical: 8.0,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                color: isDestructive ? Colors.redAccent : Colors.white,
                size: isSmallScreen ? 20 : 24,
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  color: isDestructive ? Colors.redAccent : Colors.white,
                  fontSize: isSmallScreen ? 9 : 10,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: isDestructive
                        ? Colors.redAccent.withValues(alpha: 0.7)
                        : Colors.white70,
                    fontSize: isSmallScreen ? 8 : 9,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
