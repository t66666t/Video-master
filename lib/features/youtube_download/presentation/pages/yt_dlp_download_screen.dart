import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:video_player_app/features/youtube_download/models/youtube_download_models.dart';
import 'package:video_player_app/features/youtube_download/presentation/widgets/yt_dlp_binary_manager_dialog.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_binary_updater.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_download_service.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_input_url_extractor.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_meta_parser.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_version.dart';
import 'package:video_player_app/utils/app_toast.dart';

class YtDlpDownloadScreen extends StatefulWidget {
  final String? initialInput;
  final String? targetFolderId;

  const YtDlpDownloadScreen({
    super.key,
    this.initialInput,
    this.targetFolderId,
  });

  @override
  State<YtDlpDownloadScreen> createState() => _YtDlpDownloadScreenState();
}

class _YtDlpDownloadScreenState extends State<YtDlpDownloadScreen> {
  final TextEditingController _inputController = TextEditingController();
  final FocusNode _shortcutFocusNode = FocusNode(
    debugLabel: 'YtDlpDownloadShortcutFocus',
  );
  final Map<String, bool> _taskExpansionOverrides = <String, bool>{};
  bool _isCheckingBinaryStatus = false;
  late final YtDlpDownloadService _service;

  @override
  void initState() {
    super.initState();
    _service = context.read<YtDlpDownloadService>();
    if (widget.initialInput != null) {
      _inputController.text = widget.initialInput!;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_service.activatePage());
      if (Platform.isWindows && mounted) {
        _shortcutFocusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    unawaited(_service.deactivatePage());
    _shortcutFocusNode.dispose();
    _inputController.dispose();
    super.dispose();
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

  Future<void> _resolveInput(YtDlpDownloadService service) async {
    final lines = _extractResolvableInputs(_inputController.text);
    if (lines.isEmpty) return;

    // Resolve URLs in parallel for better responsiveness
    final results = await Future.wait(
      lines.map((line) => service.resolveUrl(line)),
    );
    final successCount = results.whereType<VideoMeta>().length;

    if (!mounted) return;
    if (successCount > 0) {
      AppToast.show('已创建 $successCount 个任务', type: AppToastType.success);
      _inputController.clear();
    } else {
      AppToast.show(
        service.resolvingStatus ?? '解析失败',
        type: AppToastType.error,
      );
    }
  }

  Future<void> _importToLibrary(
    YtDlpDownloadService service, {
    YtDlpTaskRecord? task,
  }) async {
    final exportToast = AppToast.showLoading('开始导出...');
    try {
      final count = await service.importToLibrary(
        task: task,
        targetFolderId: widget.targetFolderId,
      );
      if (!mounted) {
        await exportToast.dismiss(immediate: true);
        return;
      }
      // show() 会自动替换当前的 loading toast，无需额外 dismiss
      if (count > 0) {
        AppToast.show('已导出 $count 个视频到媒体库', type: AppToastType.success);
      } else {
        AppToast.show('没有可导出的已完成任务', type: AppToastType.error);
      }
    } catch (e) {
      if (!mounted) {
        await exportToast.dismiss(immediate: true);
        return;
      }
      AppToast.show('导出失败: $e', type: AppToastType.error);
    } finally {
      await exportToast.dismiss(immediate: true);
    }
  }

  Future<void> _openOutputLocation(String path) async {
    final normalized = p.normalize(path);
    final file = File(normalized);
    final directory = Directory(normalized);
    final exists = await file.exists() || await directory.exists();
    if (!exists) {
      if (!mounted) return;
      AppToast.show('目标路径不存在', type: AppToastType.error);
      return;
    }

    try {
      if (Platform.isWindows) {
        if (await file.exists()) {
          await Process.run('explorer', ['/select,', normalized]);
        } else {
          await Process.run('explorer', [normalized]);
        }
      } else {
        final openTarget = await directory.exists()
            ? normalized
            : p.dirname(normalized);
        final result = await OpenFilex.open(openTarget);
        if (result.type != ResultType.done && mounted) {
          AppToast.show('打开位置失败', type: AppToastType.error);
        }
      }
    } catch (_) {
      if (!mounted) return;
      AppToast.show('打开位置失败', type: AppToastType.error);
    }
  }

  Future<void> _showBinaryManager(YtDlpDownloadService service) async {
    if (_isCheckingBinaryStatus) return;
    _isCheckingBinaryStatus = true;
    try {
      await service.refreshBinaryStatus();
      if (service.supportsDesktopYtDlpPaths) {
        await service.refreshDesktopYtDlpPaths();
      }
      if (service.supportsLatestYtDlpReleaseCheck) {
        try {
          await service.refreshLatestYtDlpRelease();
        } catch (_) {}
      }
    } catch (_) {
      // The manager renders runtime and network errors inline.
    } finally {
      _isCheckingBinaryStatus = false;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => YtDlpBinaryManagerDialog(service: service),
    );
  }

  // ignore: unused_element
  Future<void> _showBinaryStatusDialogLegacy(
    YtDlpDownloadService service,
  ) async {
    if (_isCheckingBinaryStatus) return;
    _isCheckingBinaryStatus = true;
    try {
      await service.refreshBinaryStatus();
      if (service.supportsLatestYtDlpReleaseCheck) {
        try {
          await service.refreshLatestYtDlpRelease();
        } catch (_) {
          // Keep the dialog usable even if release check fails.
        }
      }
    } catch (_) {
      // 静默处理检查失败，对话框仍会展示当前状态
    } finally {
      _isCheckingBinaryStatus = false;
    }

    if (!mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return ListenableBuilder(
          listenable: service,
          builder: (context, _) {
            final status = service.binaryStatus;
            final currentVersion = status.ytDlpVersion ?? 'unknown';
            final latestVersion = service.latestYtDlpRelease?.version;
            final canResolve = status.ytDlpReady;
            final hasFullPostProcessing = Platform.isAndroid
                ? status.ytDlpReady
                : status.ytDlpReady && status.ffmpegReady;
            final canUpdate =
                service.supportsOnlineYtDlpUpdate &&
                !service.isUpdatingYtDlp &&
                !service.isResolving &&
                !service.hasProcessingTasks;
            final updateProgress = service.ytDlpUpdateProgress;
            final progressLabel = updateProgress == null
                ? null
                : '${(updateProgress * 100).clamp(0, 100).toStringAsFixed(updateProgress >= 0.995 ? 0 : 1)}%';
            final latestVersionLabel = YtDlpVersions.latestStableLabel(
              latestVersion ?? service.bundledYtDlpVersion,
              supportsOnlineUpdate: service.supportsOnlineYtDlpUpdate,
            );
            final updateHint = service.supportsOnlineYtDlpUpdate
                ? service.hasProcessingTasks || service.isResolving
                      ? '请先等待当前解析或下载任务结束'
                      : service.hasNewerYtDlpRelease
                      ? '发现新的稳定版，可直接更新'
                      : '当前已是最新稳定版，仍可手动重装'
                : 'Android 内嵌 yt-dlp 将随应用升级一并更新';
            final diagnostic = status.diagnosticMessage?.trim();
            final updateError = service.ytDlpUpdateError?.trim();

            return AlertDialog(
              backgroundColor: const Color(0xFF222326),
              title: const Text('yt-dlp 环境状态'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hasFullPostProcessing
                          ? '解析与后处理环境均已就绪'
                          : canResolve
                          ? 'yt-dlp 已就绪，后处理能力受限'
                          : 'yt-dlp 尚未就绪',
                    ),
                    const SizedBox(height: 12),
                    SelectableText(
                      '当前版本: $currentVersion\n'
                      '内置版本: ${service.bundledYtDlpVersion}\n'
                      '最新稳定版: $latestVersionLabel\n'
                      '安装位置: ${status.ytDlpPath ?? '未找到'}\n'
                      'ffmpeg: ${status.ffmpegVersion ?? 'unknown'}',
                      style: const TextStyle(fontSize: 13, height: 1.45),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      service.isUpdatingYtDlp
                          ? '${service.ytDlpUpdateStage}${progressLabel == null ? '' : ' ($progressLabel)'}'
                          : updateHint,
                      style: TextStyle(
                        color: service.isUpdatingYtDlp
                            ? Colors.lightBlueAccent
                            : service.hasNewerYtDlpRelease
                            ? Colors.amberAccent
                            : Colors.white60,
                        fontSize: 12,
                      ),
                    ),
                    if (updateError != null && updateError.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      SelectableText(
                        '更新检查错误:\n$updateError',
                        style: const TextStyle(
                          color: Colors.orangeAccent,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ],
                    if (diagnostic != null && diagnostic.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      SelectableText(
                        diagnostic,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('关闭'),
                ),
                if (service.supportsOnlineYtDlpUpdate)
                  FilledButton.icon(
                    onPressed: canUpdate
                        ? () async {
                            Navigator.of(dialogContext).pop();
                            final updateToast = AppToast.showProgress(
                              '正在检查最新稳定版...',
                              progress: 0,
                            );
                            void syncUpdateToast() {
                              final progress = service.ytDlpUpdateProgress;
                              final stage = service.ytDlpUpdateStage;
                              final progressText = progress == null
                                  ? ''
                                  : ' ${(progress * 100).clamp(0, 100).toStringAsFixed(progress >= 0.995 ? 0 : 1)}%';
                              updateToast.updateProgress(
                                message: '$stage$progressText',
                                progress: progress,
                              );
                            }

                            service.addListener(syncUpdateToast);
                            try {
                              final result = await service
                                  .updateYtDlpToLatest();
                              if (!mounted) {
                                return;
                              }
                              await updateToast.dismiss();
                              final message =
                                  result.status ==
                                      YtDlpBinaryUpdateStatus.alreadyUpToDate
                                  ? 'yt-dlp 已是最新版本 ${result.currentVersion}'
                                  : 'yt-dlp 已更新到 ${result.currentVersion}';
                              AppToast.show(
                                message,
                                type:
                                    result.status ==
                                        YtDlpBinaryUpdateStatus.alreadyUpToDate
                                    ? AppToastType.info
                                    : AppToastType.success,
                              );
                            } catch (error) {
                              if (!mounted) {
                                return;
                              }
                              await updateToast.dismiss();
                              AppToast.show(
                                '更新 yt-dlp 失败: $error',
                                type: AppToastType.error,
                              );
                            } finally {
                              service.removeListener(syncUpdateToast);
                              await updateToast.dismiss();
                            }
                          }
                        : null,
                    icon: Icon(
                      service.isUpdatingYtDlp
                          ? Icons.sync
                          : Icons.system_update_alt_rounded,
                    ),
                    label: Text(
                      service.isUpdatingYtDlp
                          ? '更新中${progressLabel == null ? '' : ' $progressLabel'}'
                          : '更新 yt-dlp',
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showSettings(YtDlpDownloadService service) async {
    var temp = service.sessionConfig;
    var tempPreferences = service.downloadPreferences;
    var showAdvancedSettings = false;
    var titleTapCount = 0;
    final showOutputDirectoryControls = !Platform.isAndroid;
    final defaultOutputDir = showOutputDirectoryControls
        ? await service.resolveEffectiveOutputDirectoryPath(
            temp.copyWith(outputDirectory: null),
          )
        : '';
    final clientsController = TextEditingController(
      text: temp.enabledPlayerClients.join(','),
    );
    final visitorDataController = TextEditingController(
      text: temp.visitorData ?? '',
    );
    final userAgentController = TextEditingController(
      text: temp.userAgent ?? '',
    );
    final proxyController = TextEditingController(text: temp.proxy ?? '');
    final outputDirController = TextEditingController(
      text: temp.outputDirectory ?? '',
    );
    final timeoutController = TextEditingController(
      text: temp.socketTimeoutSeconds?.toString() ?? '30',
    );
    final retriesController = TextEditingController(
      text: temp.retries?.toString() ?? '2',
    );
    final fragmentRetriesController = TextEditingController(
      text: temp.fragmentRetries?.toString() ?? '2',
    );
    final fragmentsController = TextEditingController(
      text: temp.concurrentFragments?.toString() ?? '4',
    );
    final rateLimitController = TextEditingController(
      text: temp.rateLimit ?? '',
    );
    final cookiesController = TextEditingController(
      text: temp.cookiesFilePath ?? '',
    );
    final poTokenControllers = temp.poTokens.isEmpty
        ? <_PoTokenDraft>[_PoTokenDraft()]
        : temp.poTokens
              .map(
                (item) => _PoTokenDraft(
                  client: item.client,
                  context: item.context,
                  token: item.token,
                  enabled: item.enabled,
                ),
              )
              .toList();

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            Future<void> pickCookies() async {
              final result = await FilePicker.platform.pickFiles(
                dialogTitle: '选择 cookies.txt',
                type: FileType.custom,
                allowedExtensions: const ['txt'],
                lockParentWindow: true,
              );
              final filePath = result?.files.single.path;
              if (filePath != null && filePath.isNotEmpty) {
                final imported = await service.importCookiesFile(filePath);
                if (imported != null && imported.isNotEmpty) {
                  cookiesController.text = imported;
                  temp = temp.copyWith(
                    useCookies: true,
                    cookiesFilePath: imported,
                  );
                  if (!mounted) return;
                  AppToast.show('Cookies 已导入到私有目录', type: AppToastType.success);
                }
              }
            }

            Future<void> pickOutputDir() async {
              if (!showOutputDirectoryControls) {
                return;
              }
              final selected = await FilePicker.platform.getDirectoryPath(
                dialogTitle: '选择 yt-dlp 下载目录',
                lockParentWindow: true,
              );
              if (selected != null && selected.isNotEmpty) {
                outputDirController.text = selected;
              }
            }

            return AlertDialog(
              backgroundColor: const Color(0xFF222326),
              title: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  setState(() {
                    titleTapCount += 1;
                    if (titleTapCount >= 5) {
                      showAdvancedSettings = !showAdvancedSettings;
                      titleTapCount = 0;
                    }
                  });
                  if (titleTapCount == 0) {
                    AppToast.show(
                      showAdvancedSettings ? '已显示高级设置' : '已隐藏高级设置',
                      type: AppToastType.info,
                    );
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('YT-DLP 下载设置'),
                      const SizedBox(height: 4),
                      Text(
                        showAdvancedSettings
                            ? '连续点击 5 次标题可隐藏高级设置'
                            : '连续点击 5 次标题可显示高级设置',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              content: SizedBox(
                width: 680,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSettingsSectionTitle('默认下载偏好'),
                      _buildSettingsDropdownRow(
                        leftLabel: '首选清晰度',
                        leftValue: tempPreferences.preferredQuality,
                        leftItems: const [
                          DropdownMenuItem(
                            value: 'best',
                            child: Text('推荐（兼容优先）'),
                          ),
                          DropdownMenuItem(
                            value: '2160p',
                            child: Text('2160p'),
                          ),
                          DropdownMenuItem(
                            value: '1440p',
                            child: Text('1440p'),
                          ),
                          DropdownMenuItem(
                            value: '1080p',
                            child: Text('1080p'),
                          ),
                          DropdownMenuItem(value: '720p', child: Text('720p')),
                          DropdownMenuItem(value: '480p', child: Text('480p')),
                          DropdownMenuItem(value: '360p', child: Text('360p')),
                        ],
                        onLeftChanged: (value) {
                          if (value == null) return;
                          setState(() {
                            tempPreferences = tempPreferences.copyWith(
                              preferredQuality: value,
                            );
                          });
                        },
                        rightLabel: '字幕语言选择',
                        rightValue: _formatPreferredSubtitleLanguageSummary(
                          tempPreferences.preferredSubtitleLanguages,
                        ),
                        rightAsText: true,
                        onRightTap: () async {
                          final selected =
                              await _showPreferredSubtitleLanguagesDialog(
                                tempPreferences.preferredSubtitleLanguages,
                              );
                          if (selected == null) {
                            return;
                          }
                          setState(() {
                            tempPreferences = tempPreferences.copyWith(
                              preferredSubtitleLanguages: selected,
                            );
                          });
                        },
                      ),
                      _buildLabeledField(
                        label: '分片并发数',
                        controller: fragmentsController,
                        hintText: '1–16，建议 4',
                        keyboardType: TextInputType.number,
                      ),
                      SwitchListTile(
                        title: const Text('下载完成自动导入媒体库'),
                        value: tempPreferences.autoImportToLibrary,
                        onChanged: (value) {
                          setState(() {
                            tempPreferences = tempPreferences.copyWith(
                              autoImportToLibrary: value,
                              autoDeleteTaskAfterImport: value
                                  ? tempPreferences.autoDeleteTaskAfterImport
                                  : false,
                            );
                          });
                        },
                        contentPadding: EdgeInsets.zero,
                      ),
                      SwitchListTile(
                        title: const Text('任务下拉选项默认展开'),
                        subtitle: const Text(
                          '默认开启。进入页面时会自动展开所有任务，但手动收起的任务会保持收起，以你的操作为准。',
                          style: TextStyle(fontSize: 11),
                        ),
                        value: tempPreferences.autoExpandTaskOptions,
                        onChanged: (value) async {
                          final updatedPreferences = tempPreferences.copyWith(
                            autoExpandTaskOptions: value,
                          );
                          setState(() {
                            tempPreferences = updatedPreferences;
                          });
                          await service.saveDownloadPreferences(
                            updatedPreferences,
                          );
                        },
                        contentPadding: EdgeInsets.zero,
                      ),
                      SwitchListTile(
                        title: Text(
                          '导入媒体库后自动删除任务',
                          style: TextStyle(
                            color: tempPreferences.autoImportToLibrary
                                ? Colors.white
                                : Colors.white38,
                          ),
                        ),
                        subtitle: Text(
                          '只移除下载任务记录，不删除已导入媒体库的视频文件',
                          style: TextStyle(
                            color: tempPreferences.autoImportToLibrary
                                ? Colors.white54
                                : Colors.white24,
                            fontSize: 11,
                          ),
                        ),
                        value: tempPreferences.autoDeleteTaskAfterImport,
                        onChanged: tempPreferences.autoImportToLibrary
                            ? (value) {
                                setState(() {
                                  tempPreferences = tempPreferences.copyWith(
                                    autoDeleteTaskAfterImport: value,
                                  );
                                });
                              }
                            : null,
                        contentPadding: EdgeInsets.zero,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        tempPreferences.preferredSubtitleLanguages.isEmpty
                            ? '未设置字幕语言偏好时，将按解析结果的默认推荐选择。'
                            : '被选中的所有字幕语言都会下载；命中的自带字幕和自动生成字幕都会参与下载与封装。',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (showAdvancedSettings) ...[
                        const Divider(height: 24),
                        _buildSettingsSectionTitle('高级设置'),
                        SwitchListTile(
                          title: const Text('启用 Cookies'),
                          value: temp.useCookies,
                          onChanged: (value) {
                            setState(() {
                              temp = temp.copyWith(useCookies: value);
                            });
                          },
                          contentPadding: EdgeInsets.zero,
                        ),
                        _buildLabeledField(
                          label: 'Cookies 文件',
                          controller: cookiesController,
                          trailing: TextButton(
                            onPressed: pickCookies,
                            child: const Text('选择'),
                          ),
                        ),
                        SwitchListTile(
                          title: const Text('启用自定义 User-Agent'),
                          value: temp.useCustomUserAgent,
                          onChanged: (value) {
                            setState(() {
                              temp = temp.copyWith(useCustomUserAgent: value);
                            });
                          },
                          contentPadding: EdgeInsets.zero,
                        ),
                        _buildLabeledField(
                          label: 'User-Agent',
                          controller: userAgentController,
                        ),
                        SwitchListTile(
                          title: const Text('启用代理'),
                          value: temp.useProxy,
                          onChanged: (value) {
                            setState(() {
                              temp = temp.copyWith(useProxy: value);
                            });
                          },
                          contentPadding: EdgeInsets.zero,
                        ),
                        _buildLabeledField(
                          label: '代理地址',
                          controller: proxyController,
                        ),
                        if (showOutputDirectoryControls)
                          _buildLabeledField(
                            label: '输出目录',
                            controller: outputDirController,
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TextButton(
                                  onPressed: pickOutputDir,
                                  child: const Text('选择'),
                                ),
                                TextButton(
                                  onPressed: outputDirController.clear,
                                  child: const Text('默认'),
                                ),
                              ],
                            ),
                          ),
                        if (showOutputDirectoryControls)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                '留空时默认保存到: $defaultOutputDir',
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ),
                        _buildNumericRow(
                          leftLabel: '超时秒数',
                          leftController: timeoutController,
                          rightLabel: '重试次数',
                          rightController: retriesController,
                        ),
                        _buildLabeledField(
                          label: '分片重试',
                          controller: fragmentRetriesController,
                          keyboardType: TextInputType.number,
                        ),
                        _buildLabeledField(
                          label: '限速',
                          controller: rateLimitController,
                          hintText: '例如 2M 或 500K',
                        ),
                        _buildLabeledField(
                          label: 'Player Clients',
                          controller: clientsController,
                          hintText: '例如 android,visionos',
                        ),
                        _buildLabeledField(
                          label: 'Visitor Data',
                          controller: visitorDataController,
                        ),
                        SwitchListTile(
                          title: const Text('强制 IPv4'),
                          value: temp.forceIpv4,
                          onChanged: (value) {
                            setState(() {
                              temp = temp.copyWith(forceIpv4: value);
                            });
                          },
                          contentPadding: EdgeInsets.zero,
                        ),
                        SwitchListTile(
                          title: const Text('记录脱敏调试日志'),
                          value: temp.debugLoggingEnabled,
                          onChanged: (value) {
                            setState(() {
                              temp = temp.copyWith(debugLoggingEnabled: value);
                            });
                          },
                          contentPadding: EdgeInsets.zero,
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'PO Token 列表',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        const SizedBox(height: 6),
                        ...poTokenControllers.map((draft) {
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.04),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Column(
                              children: [
                                SwitchListTile(
                                  title: const Text('启用该 Token'),
                                  value: draft.enabled,
                                  onChanged: (value) {
                                    setState(() {
                                      draft.enabled = value;
                                    });
                                  },
                                  contentPadding: EdgeInsets.zero,
                                ),
                                _buildInlineTextField(
                                  label: 'Client',
                                  initialValue: draft.client,
                                  onChanged: (value) => draft.client = value,
                                ),
                                _buildInlineTextField(
                                  label: 'Context',
                                  initialValue: draft.context,
                                  onChanged: (value) => draft.context = value,
                                ),
                                _buildInlineTextField(
                                  label: 'Token',
                                  initialValue: draft.token,
                                  onChanged: (value) => draft.token = value,
                                ),
                              ],
                            ),
                          );
                        }),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () {
                              setState(() {
                                poTokenControllers.add(_PoTokenDraft());
                              });
                            },
                            icon: const Icon(Icons.add),
                            label: const Text('添加 PO Token'),
                          ),
                        ),
                      ] else
                        const Text(
                          '高级设置已隐藏，连续点击标题 5 次后会在底部显示原先的 Cookies、代理、UA、Player Clients 等设置。',
                          style: TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                            height: 1.35,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('取消'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final normalizedPreferences = tempPreferences.copyWith(
                      autoDeleteTaskAfterImport:
                          tempPreferences.autoImportToLibrary
                          ? tempPreferences.autoDeleteTaskAfterImport
                          : false,
                    );
                    final updated = temp.copyWith(
                      cookiesFilePath: cookiesController.text.trim().isEmpty
                          ? null
                          : cookiesController.text.trim(),
                      userAgent: userAgentController.text.trim().isEmpty
                          ? null
                          : userAgentController.text.trim(),
                      proxy: proxyController.text.trim().isEmpty
                          ? null
                          : proxyController.text.trim(),
                      socketTimeoutSeconds: int.tryParse(
                        timeoutController.text.trim(),
                      ),
                      retries: int.tryParse(retriesController.text.trim()),
                      fragmentRetries: int.tryParse(
                        fragmentRetriesController.text.trim(),
                      ),
                      concurrentFragments: int.tryParse(
                        fragmentsController.text.trim(),
                      )?.clamp(1, 16),
                      rateLimit: rateLimitController.text.trim().isEmpty
                          ? null
                          : rateLimitController.text.trim(),
                      enabledPlayerClients: clientsController.text
                          .split(',')
                          .map((item) => item.trim())
                          .where((item) => item.isNotEmpty)
                          .toList(),
                      visitorData: visitorDataController.text.trim().isEmpty
                          ? null
                          : visitorDataController.text.trim(),
                      outputDirectory: showOutputDirectoryControls
                          ? outputDirController.text.trim().isEmpty
                                ? null
                                : outputDirController.text.trim()
                          : null,
                      poTokens: poTokenControllers
                          .where((draft) => draft.token.trim().isNotEmpty)
                          .map(
                            (draft) => PoTokenConfig(
                              client: draft.client.trim(),
                              context: draft.context.trim(),
                              token: draft.token.trim(),
                              enabled: draft.enabled,
                            ),
                          )
                          .toList(),
                    );
                    await service.saveDownloadPreferences(
                      normalizedPreferences,
                    );
                    await service.saveSessionConfig(updated);
                    if (dialogContext.mounted) {
                      Navigator.pop(dialogContext);
                    }
                    if (!mounted) return;
                    AppToast.show('设置已保存', type: AppToastType.success);
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _deleteAllTasks(YtDlpDownloadService service) async {
    final shouldDelete =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              title: const Text('确认清空任务'),
              content: const Text('确定要移除所有 YT-DLP 任务吗？'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text(
                    '清空',
                    style: TextStyle(color: Colors.redAccent),
                  ),
                ),
              ],
            );
          },
        ) ??
        false;

    if (!shouldDelete) return;
    await service.clearAllTasks();
  }

  Future<void> _pasteInput() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text == null) return;
    final extracted = YtDlpInputUrlExtractor.extractUrls(data!.text!);
    final pastedText = extracted.isEmpty ? data.text! : extracted.join('\n');
    final current = _inputController.text.trim();
    _inputController.text = current.isEmpty
        ? pastedText
        : '$current\n$pastedText';
  }

  List<String> _extractResolvableInputs(String rawInput) {
    final extractedUrls = YtDlpInputUrlExtractor.extractUrls(rawInput);
    if (extractedUrls.isNotEmpty) {
      return extractedUrls;
    }
    return rawInput
        .split('\n')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }

  void _insertNewLine() {
    final selection = _inputController.selection;
    final text = _inputController.text;
    final start = selection.start < 0 ? text.length : selection.start;
    final end = selection.end < 0 ? text.length : selection.end;
    final newText = text.replaceRange(start, end, '\n');
    _inputController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + 1),
    );
  }

  void _dismissActiveInput() {
    FocusManager.instance.primaryFocus?.unfocus();
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  }

  Widget _buildInputField({
    required int minLines,
    required int maxLines,
    required double contentPadding,
  }) {
    return TextField(
      controller: _inputController,
      minLines: minLines,
      maxLines: maxLines,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      decoration: InputDecoration(
        labelText: '输入 YouTube 或其他 yt-dlp 链接（支持多行）',
        border: const OutlineInputBorder(),
        hintText: '支持整段文本自动提取链接',
        contentPadding: EdgeInsets.all(contentPadding),
        isDense: true,
      ),
      style: const TextStyle(color: Colors.white, fontSize: 13),
    );
  }

  Widget _buildCompactActionButton({
    required String tooltip,
    required IconData icon,
    required double iconSize,
    required double extent,
    required double padding,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.all(padding),
      constraints: BoxConstraints.tightFor(width: extent, height: extent),
      icon: Icon(icon, size: iconSize, color: Colors.white70),
    );
  }

  Widget _buildKeepAwakeBanner({
    required bool supported,
    required bool enabled,
    required bool active,
  }) {
    if (!supported || !enabled) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E2430),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: (active ? Colors.lightBlueAccent : Colors.white38).withValues(
            alpha: 0.35,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            active ? Icons.wb_sunny_rounded : Icons.light_mode_outlined,
            color: active ? Colors.lightBlueAccent : Colors.white70,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              active
                  ? '下载时保持亮屏已生效，当前处理中的任务会保持屏幕常亮。'
                  : '下载时保持亮屏已开启，待任务进入下载或后处理阶段后自动生效。',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskSummaryBanner(YtDlpDownloadService service) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _buildInfoChip('任务 ${service.tasks.length}', Colors.white70),
          _buildInfoChip('处理中 ${service.activeCount}', const Color(0xFFFF5A5F)),
          _buildInfoChip('队列中 ${service.queuedCount}', Colors.orangeAccent),
          _buildInfoChip('已完成 ${service.completedCount}', Colors.greenAccent),
          _buildInfoChip('失败 ${service.failedCount}', Colors.redAccent),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = _service;
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
              final isNarrowLayout = screenWidth < 760;
              final double topHorizontalPadding = (screenWidth * 0.02)
                  .clamp(8.0, 24.0)
                  .toDouble();
              final double topVerticalPadding = (screenWidth * 0.01)
                  .clamp(4.0, 12.0)
                  .toDouble();
              final double inputToActionsGap = (screenWidth * 0.015)
                  .clamp(4.0, 16.0)
                  .toDouble();
              final double actionGap = (screenWidth * 0.005)
                  .clamp(0.0, 8.0)
                  .toDouble();
              final double actionsToParseGap = (screenWidth * 0.012)
                  .clamp(4.0, 12.0)
                  .toDouble();
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
                  title: Text(
                    'YT-DLP 下载',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: isCompactAppBar ? 16 : 18),
                  ),
                  backgroundColor: const Color(0xFF1E1E1E),
                  actions: [
                    Selector<
                      YtDlpDownloadService,
                      ({bool canResolve, bool full, bool newer})
                    >(
                      selector: (_, currentService) => (
                        canResolve: currentService.binaryStatus.ytDlpReady,
                        full: Platform.isAndroid
                            ? currentService.binaryStatus.ytDlpReady
                            : currentService.binaryStatus.ytDlpReady &&
                                  currentService.binaryStatus.ffmpegReady,
                        newer: currentService.hasNewerYtDlpRelease,
                      ),
                      builder: (context, runtime, _) {
                        final currentService = context
                            .read<YtDlpDownloadService>();
                        final canResolve = runtime.canResolve;
                        final hasFullPostProcessing = runtime.full;
                        final tooltip = canResolve
                            ? hasFullPostProcessing
                                  ? runtime.newer
                                        ? 'yt-dlp 与 ffmpeg 已就绪，发现新版本'
                                        : 'yt-dlp 与 ffmpeg 已就绪'
                                  : 'yt-dlp 已就绪，后处理能力受限'
                            : '检查执行环境与更新';
                        return IconButton(
                          tooltip: tooltip,
                          onPressed: () => _showBinaryManager(currentService),
                          icon: Icon(
                            runtime.newer
                                ? Icons.system_update_alt_rounded
                                : hasFullPostProcessing
                                ? Icons.verified
                                : canResolve
                                ? Icons.info_outline
                                : Icons.warning_amber_rounded,
                            color: runtime.newer
                                ? Colors.amberAccent
                                : hasFullPostProcessing
                                ? Colors.greenAccent
                                : canResolve
                                ? Colors.lightBlueAccent
                                : Colors.amber,
                          ),
                          iconSize: appBarIconSize,
                          padding: appBarIconPadding,
                          constraints: appBarIconConstraints,
                        );
                      },
                    ),
                    Selector<
                      YtDlpDownloadService,
                      ({bool supported, bool enabled, bool active})
                    >(
                      selector: (_, currentService) => (
                        supported:
                            currentService.supportsProcessingKeepAwakeToggle,
                        enabled: currentService.keepScreenAwakeDuringProcessing,
                        active: currentService.isProcessingKeepAwakeActive,
                      ),
                      builder: (context, keepAwake, _) {
                        if (!keepAwake.supported) {
                          return const SizedBox.shrink();
                        }
                        final currentService = context
                            .read<YtDlpDownloadService>();
                        return IconButton(
                          tooltip: keepAwake.active ? '下载时保持亮屏已开启' : '下载时保持亮屏',
                          onPressed: currentService
                              .toggleKeepScreenAwakeDuringProcessing,
                          icon: Icon(
                            keepAwake.enabled
                                ? Icons.wb_sunny_rounded
                                : Icons.light_mode_outlined,
                            color: keepAwake.enabled
                                ? const Color(0xFFFF5A5F)
                                : Colors.white70,
                          ),
                          iconSize: appBarIconSize,
                          padding: appBarIconPadding,
                          constraints: appBarIconConstraints,
                        );
                      },
                    ),
                    IconButton(
                      icon: Icon(Icons.delete_sweep, size: appBarIconSize),
                      tooltip: '清空任务',
                      padding: appBarIconPadding,
                      constraints: appBarIconConstraints,
                      onPressed: () => _deleteAllTasks(service),
                    ),
                    IconButton(
                      icon: Icon(Icons.settings, size: appBarIconSize),
                      tooltip: '下载设置',
                      padding: appBarIconPadding,
                      constraints: appBarIconConstraints,
                      onPressed: () => _showSettings(service),
                    ),
                  ],
                ),
                body: Column(
                  children: [
                    Container(
                      color: const Color(0xFF1E1E1E),
                      padding: EdgeInsets.symmetric(
                        horizontal: topHorizontalPadding,
                        vertical: topVerticalPadding,
                      ),
                      child: isNarrowLayout
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _buildInputField(
                                  minLines: inputMinLines,
                                  maxLines: inputMaxLines,
                                  contentPadding: inputContentPadding,
                                ),
                                SizedBox(height: actionGap + 6),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Wrap(
                                        spacing: actionGap,
                                        runSpacing: actionGap,
                                        children: [
                                          _buildCompactActionButton(
                                            tooltip: '粘贴',
                                            icon: Icons.paste,
                                            iconSize: actionIconSize,
                                            extent: actionButtonExtent,
                                            padding: iconButtonPadding,
                                            onPressed: _pasteInput,
                                          ),
                                          _buildCompactActionButton(
                                            tooltip: '清空',
                                            icon: Icons.clear,
                                            iconSize: actionIconSize,
                                            extent: actionButtonExtent,
                                            padding: iconButtonPadding,
                                            onPressed: _inputController.clear,
                                          ),
                                          _buildCompactActionButton(
                                            tooltip: '换行',
                                            icon: Icons.keyboard_return,
                                            iconSize: actionIconSize,
                                            extent: actionButtonExtent,
                                            padding: iconButtonPadding,
                                            onPressed: _insertNewLine,
                                          ),
                                        ],
                                      ),
                                    ),
                                    SizedBox(width: actionsToParseGap),
                                    Selector<YtDlpDownloadService, bool>(
                                      selector: (_, s) => s.isResolving,
                                      builder: (context, isResolving, _) {
                                        final svc = context
                                            .read<YtDlpDownloadService>();
                                        return ElevatedButton(
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: const Color(
                                              0xFFFF4040,
                                            ),
                                            foregroundColor: Colors.white,
                                            padding: EdgeInsets.symmetric(
                                              horizontal:
                                                  parseButtonHorizontalPadding,
                                              vertical: 0,
                                            ),
                                            minimumSize: Size(
                                              64,
                                              parseButtonHeight,
                                            ),
                                          ),
                                          onPressed: isResolving
                                              ? null
                                              : () => _resolveInput(svc),
                                          child: isResolving
                                              ? const SizedBox(
                                                  width: 18,
                                                  height: 18,
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        color: Colors.white,
                                                      ),
                                                )
                                              : const Text('解析'),
                                        );
                                      },
                                    ),
                                  ],
                                ),
                              ],
                            )
                          : Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: _buildInputField(
                                    minLines: inputMinLines,
                                    maxLines: inputMaxLines,
                                    contentPadding: inputContentPadding,
                                  ),
                                ),
                                SizedBox(width: inputToActionsGap),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _buildCompactActionButton(
                                      tooltip: '粘贴',
                                      icon: Icons.paste,
                                      iconSize: actionIconSize,
                                      extent: actionButtonExtent,
                                      padding: iconButtonPadding,
                                      onPressed: _pasteInput,
                                    ),
                                    SizedBox(width: actionGap),
                                    _buildCompactActionButton(
                                      tooltip: '清空',
                                      icon: Icons.clear,
                                      iconSize: actionIconSize,
                                      extent: actionButtonExtent,
                                      padding: iconButtonPadding,
                                      onPressed: _inputController.clear,
                                    ),
                                    SizedBox(width: actionGap),
                                    _buildCompactActionButton(
                                      tooltip: '换行',
                                      icon: Icons.keyboard_return,
                                      iconSize: actionIconSize,
                                      extent: actionButtonExtent,
                                      padding: iconButtonPadding,
                                      onPressed: _insertNewLine,
                                    ),
                                  ],
                                ),
                                SizedBox(width: actionsToParseGap),
                                Selector<YtDlpDownloadService, bool>(
                                  selector: (_, s) => s.isResolving,
                                  builder: (context, isResolving, _) {
                                    final svc = context
                                        .read<YtDlpDownloadService>();
                                    return ElevatedButton(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(
                                          0xFFFF4040,
                                        ),
                                        foregroundColor: Colors.white,
                                        padding: EdgeInsets.symmetric(
                                          horizontal:
                                              parseButtonHorizontalPadding,
                                          vertical: 0,
                                        ),
                                        minimumSize: Size(
                                          64,
                                          parseButtonHeight,
                                        ),
                                      ),
                                      onPressed: isResolving
                                          ? null
                                          : () => _resolveInput(svc),
                                      child: isResolving
                                          ? const SizedBox(
                                              width: 18,
                                              height: 18,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Colors.white,
                                              ),
                                            )
                                          : const Text('解析'),
                                    );
                                  },
                                ),
                              ],
                            ),
                    ),
                    Selector<YtDlpDownloadService, String?>(
                      selector: (_, s) => s.resolvingStatus,
                      builder: (context, resolvingStatus, _) {
                        if (resolvingStatus == null) {
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
                            resolvingStatus,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        );
                      },
                    ),
                    Selector<
                      YtDlpDownloadService,
                      ({bool supported, bool enabled, bool active})
                    >(
                      selector: (_, currentService) => (
                        supported:
                            currentService.supportsProcessingKeepAwakeToggle,
                        enabled: currentService.keepScreenAwakeDuringProcessing,
                        active: currentService.isProcessingKeepAwakeActive,
                      ),
                      builder: (context, keepAwake, _) => _buildKeepAwakeBanner(
                        supported: keepAwake.supported,
                        enabled: keepAwake.enabled,
                        active: keepAwake.active,
                      ),
                    ),
                    Selector<
                      YtDlpDownloadService,
                      ({
                        int taskCount,
                        int activeCount,
                        int queuedCount,
                        int completedCount,
                        int failedCount,
                      })
                    >(
                      selector: (_, currentService) => (
                        taskCount: currentService.tasks.length,
                        activeCount: currentService.activeCount,
                        queuedCount: currentService.queuedCount,
                        completedCount: currentService.completedCount,
                        failedCount: currentService.failedCount,
                      ),
                      builder: (context, summary, _) {
                        if (summary.taskCount == 0) {
                          return const SizedBox.shrink();
                        }
                        return _buildTaskSummaryBanner(
                          context.read<YtDlpDownloadService>(),
                        );
                      },
                    ),
                    Expanded(
                      child: Selector<YtDlpDownloadService, List<String>>(
                        selector: (_, currentService) => currentService.taskIds,
                        builder: (context, taskIds, _) {
                          final currentService = context
                              .read<YtDlpDownloadService>();
                          if (!currentService.isInitialized &&
                              taskIds.isEmpty) {
                            return _buildInitialLoadingState();
                          }
                          if (taskIds.isEmpty) {
                            return const Center(
                              child: Padding(
                                padding: EdgeInsets.symmetric(horizontal: 32),
                                child: Text(
                                  '请输入链接并点击解析，任务创建后可在此调整格式、查看错误与批量操作。',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: Colors.white30),
                                ),
                              ),
                            );
                          }
                          return ListView.builder(
                            padding: const EdgeInsets.all(16),
                            itemCount: taskIds.length,
                            scrollCacheExtent: const ScrollCacheExtent.pixels(
                              800,
                            ),
                            addAutomaticKeepAlives: false,
                            addRepaintBoundaries: true,
                            addSemanticIndexes: false,
                            itemBuilder: (context, index) {
                              final taskId = taskIds[index];
                              return Selector<
                                YtDlpDownloadService,
                                YtDlpTaskRecord?
                              >(
                                selector: (_, service) =>
                                    service.getTaskById(taskId),
                                builder: (context, task, _) {
                                  if (task == null) {
                                    return const SizedBox.shrink();
                                  }
                                  return RepaintBoundary(
                                    key: ValueKey(task.taskId),
                                    child: _buildTaskCard(currentService, task),
                                  );
                                },
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
                      YtDlpDownloadService,
                      ({
                        int taskCount,
                        int selectedCount,
                        int selectedRunnableCount,
                        int selectedPrioritizableCount,
                        int selectedPausableCount,
                        int selectedCancellableCount,
                        int selectedRetryableCount,
                        int selectedCompletedCount,
                      })
                    >(
                      selector: (_, currentService) => (
                        taskCount: currentService.tasks.length,
                        selectedCount: currentService.selectedCount,
                        selectedRunnableCount:
                            currentService.selectedRunnableCount,
                        selectedPrioritizableCount:
                            currentService.selectedPrioritizableCount,
                        selectedPausableCount:
                            currentService.selectedPausableCount,
                        selectedCancellableCount:
                            currentService.selectedCancellableCount,
                        selectedRetryableCount:
                            currentService.selectedRetryableCount,
                        selectedCompletedCount:
                            currentService.selectedCompletedCount,
                      ),
                      builder: (context, summary, _) {
                        final currentService = context
                            .read<YtDlpDownloadService>();
                        if (summary.taskCount == 0) {
                          return const SizedBox.shrink();
                        }
                        return BottomAppBar(
                          color: const Color(0xFF1E1E1E),
                          child: SizedBox(
                            height: 64,
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              children: [
                                _buildBottomAction(
                                  icon: Icons.select_all,
                                  label: '全选',
                                  subtitle: '已选 ${summary.selectedCount} 项',
                                  onTap: currentService.selectAll,
                                ),
                                _buildBottomAction(
                                  icon: Icons.download,
                                  label: '开始',
                                  subtitle:
                                      '可运行 ${summary.selectedRunnableCount}',
                                  onTap: summary.selectedRunnableCount > 0
                                      ? currentService.startSelected
                                      : null,
                                ),
                                _buildBottomAction(
                                  icon: Icons.priority_high,
                                  label: '插队',
                                  subtitle:
                                      '可优先 ${summary.selectedPrioritizableCount}',
                                  onTap: summary.selectedPrioritizableCount > 0
                                      ? currentService.prioritizeSelected
                                      : null,
                                ),
                                _buildBottomAction(
                                  icon: Icons.pause,
                                  label: '暂停',
                                  subtitle:
                                      '可暂停 ${summary.selectedPausableCount}',
                                  onTap: summary.selectedPausableCount > 0
                                      ? currentService.pauseSelected
                                      : null,
                                ),
                                _buildBottomAction(
                                  icon: Icons.stop_circle_outlined,
                                  label: '取消',
                                  subtitle:
                                      '可取消 ${summary.selectedCancellableCount}',
                                  onTap: summary.selectedCancellableCount > 0
                                      ? currentService.cancelSelected
                                      : null,
                                ),
                                _buildBottomAction(
                                  icon: Icons.refresh,
                                  label: '重试',
                                  subtitle:
                                      '可重试 ${summary.selectedRetryableCount}',
                                  onTap: summary.selectedRetryableCount > 0
                                      ? currentService.retrySelected
                                      : null,
                                ),
                                _buildBottomAction(
                                  icon: Icons.video_library_outlined,
                                  label: '导出',
                                  subtitle:
                                      '可导出 ${summary.selectedCompletedCount}',
                                  onTap: summary.selectedCompletedCount > 0
                                      ? () => _importToLibrary(currentService)
                                      : null,
                                ),
                                _buildBottomAction(
                                  icon: Icons.delete,
                                  label: '移除',
                                  subtitle: summary.selectedCount > 0
                                      ? '移除 ${summary.selectedCount} 项'
                                      : '未选择',
                                  isDestructive: true,
                                  onTap: summary.selectedCount > 0
                                      ? currentService.removeSelected
                                      : null,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildTaskCard(YtDlpDownloadService service, YtDlpTaskRecord task) {
    final meta = task.meta;
    final failureTypeText = task.failureType == YtDlpFailureType.none
        ? null
        : _failureTypeText(task.failureType);
    final failureDetail = _buildFailureDetail(task);
    final hasExpandableDetails = _taskHasExpandableDetails(task);
    final isExpanded = hasExpandableDetails && _isTaskExpanded(task);
    final canPause = task.canPause;
    final isPausing = task.status == YtDlpTaskStatus.pausing;
    final canPrioritize =
        task.canStart || task.status == YtDlpTaskStatus.queued;
    return Card(
      color: const Color(0xFF232427),
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isCompactCard = constraints.maxWidth < 620;
          final double thumbnailWidth = isCompactCard ? 76 : 82;
          final double thumbnailHeight = isCompactCard ? 48 : 52;
          final double actionButtonSize = isCompactCard ? 28 : 30;
          final double actionIconSize = isCompactCard ? 18 : 19;
          final bool shouldShowCollapsedTaskMessage =
              task.status == YtDlpTaskStatus.failed ||
              task.status == YtDlpTaskStatus.cancelled ||
              task.status == YtDlpTaskStatus.paused;
          final String? collapsedFailureText =
              shouldShowCollapsedTaskMessage &&
                  task.errorMessage?.isNotEmpty == true
              ? task.errorMessage
              : task.fallbackAttemptCount > 0
              ? '已自动回退 ${task.fallbackAttemptCount} 次'
              : null;

          return Column(
            children: [
              InkWell(
                onTap: hasExpandableDetails
                    ? () => _toggleTaskExpanded(task)
                    : null,
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    isCompactCard ? 10 : 12,
                    10,
                    isCompactCard ? 10 : 12,
                    isExpanded ? 8 : 10,
                  ),
                  child: Column(
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 30,
                            child: Checkbox(
                              value: task.isSelected,
                              activeColor: const Color(0xFFFF4040),
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              onChanged: (value) {
                                service.updateTaskSelection(
                                  task.taskId,
                                  value ?? false,
                                );
                              },
                            ),
                          ),
                          const SizedBox(width: 6),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: _buildThumbnail(
                              task,
                              width: thumbnailWidth,
                              height: thumbnailHeight,
                              imageKey: ValueKey(
                                'yt-task-thumb-${task.taskId}-${task.localThumbnailPath ?? task.thumbnailUrl}',
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  task.title,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: isCompactCard ? 13 : 14,
                                    height: 1.25,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _buildTaskSubtitle(meta, task.sourceUrl),
                                  style: const TextStyle(
                                    color: Colors.white60,
                                    fontSize: 11,
                                    height: 1.25,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    _buildStatusChip(task.status),
                                    if (failureTypeText != null)
                                      _buildInfoChip(
                                        failureTypeText,
                                        Colors.redAccent,
                                      ),
                                    if (task.fallbackAttemptCount > 0)
                                      _buildInfoChip(
                                        '回退 ${task.fallbackAttemptCount} 次',
                                        Colors.orangeAccent,
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (task.canStart)
                                _buildTaskHeaderActionButton(
                                  tooltip:
                                      task.status ==
                                              YtDlpTaskStatus.completed ||
                                          task.status ==
                                              YtDlpTaskStatus.exported
                                      ? '重新下载'
                                      : '开始',
                                  icon: Icons.play_arrow,
                                  color: const Color(0xFFFF5A5F),
                                  size: actionButtonSize,
                                  iconSize: actionIconSize,
                                  onPressed: () => service.startTask(task),
                                )
                              else if (canPause)
                                _buildTaskHeaderActionButton(
                                  tooltip: '暂停',
                                  icon: Icons.pause,
                                  color: Colors.amber,
                                  size: actionButtonSize,
                                  iconSize: actionIconSize,
                                  onPressed: () => service.pauseTask(task),
                                )
                              else if (isPausing)
                                SizedBox(
                                  width: actionButtonSize,
                                  height: actionButtonSize,
                                  child: const Padding(
                                    padding: EdgeInsets.all(6),
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.amber,
                                    ),
                                  ),
                                )
                              else
                                SizedBox(
                                  width: actionButtonSize,
                                  height: actionButtonSize,
                                ),
                              SizedBox(
                                width: actionButtonSize,
                                height: actionButtonSize,
                                child: PopupMenuButton<String>(
                                  color: const Color(0xFF303134),
                                  padding: EdgeInsets.zero,
                                  icon: Icon(
                                    Icons.more_vert,
                                    size: actionIconSize,
                                    color: Colors.white70,
                                  ),
                                  onSelected: (value) {
                                    switch (value) {
                                      case 'start':
                                        service.startTask(task);
                                        break;
                                      case 'pause':
                                        service.pauseTask(task);
                                        break;
                                      case 'priority':
                                        service.prioritizeTask(task);
                                        break;
                                      case 'cancel':
                                        service.cancelTask(task);
                                        break;
                                      case 'retry':
                                        service.retryTask(task);
                                        break;
                                      case 'remove':
                                        service.removeTask(task);
                                        break;
                                      case 'open_path':
                                        if ((task.outputPath?.isNotEmpty ??
                                            false)) {
                                          _openOutputLocation(task.outputPath!);
                                        }
                                        break;
                                      case 'copy_path':
                                        if ((task.outputPath?.isNotEmpty ??
                                            false)) {
                                          Clipboard.setData(
                                            ClipboardData(
                                              text: task.outputPath!,
                                            ),
                                          );
                                          AppToast.show(
                                            '输出路径已复制',
                                            type: AppToastType.success,
                                          );
                                        }
                                        break;
                                      case 'export_library':
                                        _importToLibrary(service, task: task);
                                        break;
                                    }
                                  },
                                  itemBuilder: (context) => [
                                    if (task.canStart)
                                      PopupMenuItem<String>(
                                        value: 'start',
                                        child: Text(
                                          task.status ==
                                                      YtDlpTaskStatus
                                                          .completed ||
                                                  task.status ==
                                                      YtDlpTaskStatus.exported
                                              ? '重新下载'
                                              : '开始下载',
                                        ),
                                      ),
                                    if (canPause)
                                      const PopupMenuItem<String>(
                                        value: 'pause',
                                        child: Text('暂停任务'),
                                      ),
                                    if (canPrioritize)
                                      PopupMenuItem<String>(
                                        value: 'priority',
                                        child: Text(
                                          task.status == YtDlpTaskStatus.queued
                                              ? '插队到最前'
                                              : '优先开始',
                                        ),
                                      ),
                                    if (task.canCancel)
                                      const PopupMenuItem<String>(
                                        value: 'cancel',
                                        child: Text('取消下载'),
                                      ),
                                    if (task.canRetry)
                                      const PopupMenuItem<String>(
                                        value: 'retry',
                                        child: Text('重试'),
                                      ),
                                    const PopupMenuItem<String>(
                                      value: 'remove',
                                      child: Text('删除任务'),
                                    ),
                                    if (!Platform.isAndroid &&
                                        (task.outputPath?.isNotEmpty ?? false))
                                      const PopupMenuItem<String>(
                                        value: 'open_path',
                                        child: Text('打开所在位置'),
                                      ),
                                    if (!Platform.isAndroid &&
                                        (task.outputPath?.isNotEmpty ?? false))
                                      const PopupMenuItem<String>(
                                        value: 'copy_path',
                                        child: Text('复制输出路径'),
                                      ),
                                    if (task.status ==
                                            YtDlpTaskStatus.completed &&
                                        (task.outputPath?.isNotEmpty ?? false))
                                      const PopupMenuItem<String>(
                                        value: 'export_library',
                                        child: Text('导出到媒体库'),
                                      ),
                                  ],
                                ),
                              ),
                              if (hasExpandableDetails)
                                _buildTaskHeaderActionButton(
                                  tooltip: isExpanded ? '收起选项' : '展开选项',
                                  icon: isExpanded
                                      ? Icons.expand_less
                                      : Icons.expand_more,
                                  size: actionButtonSize,
                                  iconSize: actionIconSize,
                                  onPressed: () => _toggleTaskExpanded(task),
                                ),
                            ],
                          ),
                        ],
                      ),
                      if (_shouldShowTaskProgress(task)) ...[
                        const SizedBox(height: 8),
                        _buildTaskProgressSection(task),
                      ],
                      if (!isExpanded && collapsedFailureText != null) ...[
                        const SizedBox(height: 6),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            collapsedFailureText,
                            style: TextStyle(
                              color: task.status == YtDlpTaskStatus.failed
                                  ? Colors.redAccent
                                  : Colors.white54,
                              fontSize: 11,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (isExpanded)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                  child: Column(
                    children: [
                      Divider(
                        height: 1,
                        color: Colors.white.withValues(alpha: 0.06),
                      ),
                      const SizedBox(height: 10),
                      if (failureDetail != null) ...[
                        failureDetail,
                        const SizedBox(height: 10),
                      ],
                      if (meta != null) ...[
                        _buildTaskSettingsSection(service, task),
                        if (!Platform.isAndroid &&
                            (task.outputPath?.isNotEmpty ?? false))
                          const SizedBox(height: 10),
                      ],
                      if (!Platform.isAndroid &&
                          (task.outputPath?.isNotEmpty ?? false))
                        _buildTaskOutputPath(task.outputPath!),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  bool _isTaskExpanded(YtDlpTaskRecord task) {
    final override = _taskExpansionOverrides[task.taskId];
    if (override != null) {
      return override;
    }
    return _service.downloadPreferences.autoExpandTaskOptions;
  }

  void _toggleTaskExpanded(YtDlpTaskRecord task) {
    final taskId = task.taskId;
    final defaultExpanded = _service.downloadPreferences.autoExpandTaskOptions;
    final nextExpanded = !_isTaskExpanded(task);
    setState(() {
      if (nextExpanded == defaultExpanded) {
        _taskExpansionOverrides.remove(taskId);
      } else {
        _taskExpansionOverrides[taskId] = nextExpanded;
      }
    });
  }

  bool _taskHasExpandableDetails(YtDlpTaskRecord task) {
    return task.meta != null ||
        (!Platform.isAndroid && (task.outputPath?.isNotEmpty ?? false)) ||
        (task.errorMessage?.isNotEmpty ?? false) ||
        task.fallbackAttemptCount > 0 ||
        task.failureContext != null;
  }

  bool _shouldShowTaskProgress(YtDlpTaskRecord task) {
    return task.status == YtDlpTaskStatus.queued ||
        task.status == YtDlpTaskStatus.pausing ||
        task.status == YtDlpTaskStatus.downloading ||
        task.status == YtDlpTaskStatus.postProcessing ||
        task.status == YtDlpTaskStatus.completed ||
        task.status == YtDlpTaskStatus.exported ||
        task.progress > 0;
  }

  String _buildTaskSubtitle(VideoMeta? meta, String sourceUrl) {
    if (meta == null) {
      return sourceUrl;
    }
    final parts = <String>[
      if (meta.uploader.isNotEmpty) meta.uploader,
      _formatDuration(meta.durationSeconds),
    ];
    return parts.join('  ·  ');
  }

  double _normalizedTaskProgress(YtDlpTaskRecord task) {
    if (task.status == YtDlpTaskStatus.completed ||
        task.status == YtDlpTaskStatus.exported) {
      return 1;
    }
    if (task.progress < 0) {
      return 0;
    }
    if (task.progress > 1) {
      return 1;
    }
    return task.progress;
  }

  String _taskProgressTrailingText(YtDlpTaskRecord task) {
    switch (task.status) {
      case YtDlpTaskStatus.queued:
        return '等待开始';
      case YtDlpTaskStatus.pausing:
        return '正在暂停';
      case YtDlpTaskStatus.postProcessing:
        return '后处理中';
      case YtDlpTaskStatus.completed:
        return '已完成';
      case YtDlpTaskStatus.exported:
        return '已导出';
      case YtDlpTaskStatus.paused:
        return '已暂停';
      case YtDlpTaskStatus.failed:
        return '失败';
      case YtDlpTaskStatus.cancelled:
        return '已取消';
      case YtDlpTaskStatus.resolving:
        return '解析中';
      case YtDlpTaskStatus.pending:
        return '待开始';
      case YtDlpTaskStatus.downloading:
        return task.etaText ?? '--:--';
    }
  }

  Widget _buildTaskProgressSection(YtDlpTaskRecord task) {
    final progress = _normalizedTaskProgress(task);
    final showIndeterminate =
        task.status == YtDlpTaskStatus.pausing && task.progress <= 0;
    final effectiveProgress =
        task.status == YtDlpTaskStatus.queued && progress <= 0 ? 0.0 : progress;
    final stageText = task.statusMessage?.trim();
    final shouldShowStage =
        stageText != null &&
        stageText.isNotEmpty &&
        task.status != YtDlpTaskStatus.completed &&
        task.status != YtDlpTaskStatus.exported;
    final sizeText = _taskSizeText(task);
    final speedText = _displayTaskSpeedText(task.speedText);
    return Column(
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: effectiveProgress),
          duration: const Duration(milliseconds: 120),
          curve: Curves.linear,
          builder: (context, animatedProgress, _) => ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: showIndeterminate ? null : animatedProgress,
              minHeight: 3,
              backgroundColor: Colors.grey[800],
              color: const Color(0xFFFF5A5F),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(
              '${(progress * 100).toStringAsFixed(2)}%',
              style: const TextStyle(color: Colors.white38, fontSize: 10),
            ),
            const Spacer(),
            if (speedText != null)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Text(
                  speedText,
                  style: const TextStyle(color: Colors.white38, fontSize: 10),
                ),
              ),
            if (sizeText != null)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Text(
                  sizeText,
                  style: const TextStyle(color: Colors.white38, fontSize: 10),
                ),
              ),
            Text(
              _taskProgressTrailingText(task),
              style: const TextStyle(color: Colors.white38, fontSize: 10),
            ),
          ],
        ),
        if (shouldShowStage) ...[
          const SizedBox(height: 5),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              stageText,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 10,
                height: 1.35,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    );
  }

  String? _taskSizeText(YtDlpTaskRecord task) {
    final downloaded = task.downloadedBytes;
    final total = task.totalBytes;
    if (downloaded == null && total == null) {
      return null;
    }
    if (downloaded != null && total != null) {
      return '${_formatBytes(downloaded)}/${_formatBytes(total)}';
    }
    if (downloaded != null) {
      return _formatBytes(downloaded);
    }
    return '总计 ${_formatBytes(total!)}';
  }

  Widget _buildTaskHeaderActionButton({
    required String tooltip,
    required IconData icon,
    required double size,
    required double iconSize,
    required VoidCallback onPressed,
    Color color = Colors.white70,
  }) {
    return SizedBox(
      width: size,
      height: size,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
        icon: Icon(icon, size: iconSize, color: color),
      ),
    );
  }

  Widget _buildTaskSectionLabel(IconData icon, String label) {
    return Row(
      children: [
        Icon(icon, size: 14, color: Colors.white54),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildTaskSettingsSection(
    YtDlpDownloadService service,
    YtDlpTaskRecord task,
  ) {
    final meta = task.meta;
    final selection = task.selection;
    if (meta == null) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTaskSectionLabel(Icons.tune_rounded, '下载选项'),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final isNarrowCard = constraints.maxWidth < 620;
              final videoDropdown = _buildDropdownCard<String>(
                label: '视频流',
                value:
                    selection.selectedVideoFormatId ??
                    _firstOrNull(
                      meta.videoFormats.map((item) => item.formatId).toList(),
                    ),
                items: meta.videoFormats
                    .map(
                      (item) => DropdownMenuItem<String>(
                        value: item.formatId,
                        child: Text(
                          item.displayLabel,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: selection.audioOnly
                    ? null
                    : (value) {
                        service.updateTaskSelectionModel(
                          task.taskId,
                          selection.copyWith(selectedVideoFormatId: value),
                        );
                      },
              );
              final audioDropdown = _buildDropdownCard<String>(
                label: '音频流',
                value:
                    _firstOrNull(selection.selectedAudioFormatIds) ??
                    _firstOrNull(
                      meta.audioFormats.map((item) => item.formatId).toList(),
                    ),
                items: meta.audioFormats
                    .map(
                      (item) => DropdownMenuItem<String>(
                        value: item.formatId,
                        child: Text(
                          item.displayLabel,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value == null) return;
                  service.updateTaskSelectionModel(
                    task.taskId,
                    selection.copyWith(selectedAudioFormatIds: [value]),
                  );
                },
              );
              return isNarrowCard
                  ? Column(
                      children: [
                        videoDropdown,
                        const SizedBox(height: 8),
                        audioDropdown,
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(child: videoDropdown),
                        const SizedBox(width: 8),
                        Expanded(child: audioDropdown),
                      ],
                    );
            },
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final isNarrowCard = constraints.maxWidth < 620;
              final outputControl = selection.audioOnly
                  ? _buildDropdownCard<String>(
                      label: '音频格式',
                      value: _normalizeAudioTaskOutputContainer(
                        selection.outputContainer,
                      ),
                      items: const [
                        DropdownMenuItem(value: 'm4a', child: Text('m4a')),
                        DropdownMenuItem(value: 'mp3', child: Text('mp3')),
                        DropdownMenuItem(value: 'aac', child: Text('aac')),
                        DropdownMenuItem(value: 'wav', child: Text('wav')),
                        DropdownMenuItem(value: 'opus', child: Text('opus')),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        service.updateTaskSelectionModel(
                          task.taskId,
                          selection.copyWith(outputContainer: value),
                        );
                      },
                    )
                  : _buildReadonlyInfoCard(label: '视频容器', value: 'mkv');
              final subtitleSelector = _buildSubtitleSelectorCard(
                meta: meta,
                selection: selection,
                onTap: meta.subtitles.isEmpty
                    ? null
                    : () => _showSubtitleTrackPicker(
                        service,
                        task,
                        meta,
                        selection,
                      ),
              );
              return isNarrowCard
                  ? Column(
                      children: [
                        outputControl,
                        const SizedBox(height: 8),
                        subtitleSelector,
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(child: outputControl),
                        const SizedBox(width: 8),
                        Expanded(child: subtitleSelector),
                      ],
                    );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildTaskOutputPath(String outputPath) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(
              Icons.folder_open_outlined,
              size: 14,
              color: Colors.white54,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _formatPath(outputPath),
              style: const TextStyle(color: Colors.white54, fontSize: 12),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: '打开所在位置',
            onPressed: () => _openOutputLocation(outputPath),
            icon: const Icon(
              Icons.folder_open_outlined,
              size: 16,
              color: Colors.white60,
            ),
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            tooltip: '复制路径',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: outputPath));
              AppToast.show('输出路径已复制', type: AppToastType.success);
            },
            icon: const Icon(
              Icons.copy_outlined,
              size: 16,
              color: Colors.white60,
            ),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildBottomAction({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool isDestructive = false,
    String? subtitle,
  }) {
    final isSmallScreen = MediaQuery.of(context).size.width < 400;
    final isEnabled = onTap != null;
    final baseColor = isDestructive ? Colors.redAccent : Colors.white;
    final contentColor = isEnabled
        ? baseColor
        : baseColor.withValues(alpha: 0.38);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: isSmallScreen ? 4 : 8,
          vertical: 8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: contentColor, size: isSmallScreen ? 20 : 24),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: contentColor,
                fontSize: isSmallScreen ? 9 : 10,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (subtitle != null)
              Text(
                subtitle,
                style: TextStyle(
                  color: isEnabled
                      ? (isDestructive
                            ? Colors.redAccent.withValues(alpha: 0.7)
                            : Colors.white70)
                      : Colors.white38,
                  fontSize: isSmallScreen ? 8 : 9,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
    );
  }

  String _failureTypeText(YtDlpFailureType type) {
    switch (type) {
      case YtDlpFailureType.none:
        return '正常';
      case YtDlpFailureType.networkTimeout:
        return '网络超时';
      case YtDlpFailureType.extractionFailed:
        return '提取失败';
      case YtDlpFailureType.authFailed:
        return '鉴权失败';
      case YtDlpFailureType.proxyFailed:
        return '代理失败';
      case YtDlpFailureType.postProcessingFailed:
        return '后处理失败';
      case YtDlpFailureType.noFormatAvailable:
        return '无可用格式';
      case YtDlpFailureType.fileWriteFailed:
        return '写入失败';
      case YtDlpFailureType.userCancelled:
        return '用户取消';
      case YtDlpFailureType.unsupported:
        return '当前平台不支持';
      case YtDlpFailureType.unknown:
        return '未知错误';
    }
  }

  Widget? _buildFailureDetail(YtDlpTaskRecord task) {
    final isFailureState =
        task.status == YtDlpTaskStatus.failed ||
        task.status == YtDlpTaskStatus.cancelled;
    if ((!isFailureState || !(task.errorMessage?.isNotEmpty ?? false)) &&
        task.fallbackAttemptCount <= 0 &&
        task.failureContext == null) {
      return null;
    }
    final context = task.failureContext;
    final summaryParts = <String>[
      if (context?.selectedPlayerClient != null)
        'client: ${context!.selectedPlayerClient}',
      if (context?.hasCookies == true) 'cookies',
      if (context?.hasProxy == true) 'proxy',
      if (context?.hasUserAgent == true) 'UA',
      if (context?.hasVisitorData == true) 'visitor',
      if (context?.hasPoToken == true) 'PO token',
      if (context?.exitCode != null) 'exit ${context!.exitCode}',
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.redAccent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if ((task.errorMessage?.isNotEmpty ?? false))
            Text(
              task.errorMessage!,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                height: 1.35,
              ),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          if (task.fallbackAttemptCount > 0) ...[
            const SizedBox(height: 6),
            Text(
              '已自动回退 ${task.fallbackAttemptCount} 次'
              '${task.appliedFallbackSteps.isNotEmpty ? ' · 最近一步 ${_fallbackStepText(task.appliedFallbackSteps.last)}' : ''}',
              style: const TextStyle(color: Colors.orangeAccent, fontSize: 11),
            ),
          ],
          if (summaryParts.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              summaryParts.join(' · '),
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  String _fallbackStepText(YtDlpFallbackStep step) {
    switch (step) {
      case YtDlpFallbackStep.originalRetry:
        return '原始配置重试';
      case YtDlpFallbackStep.reduceConcurrentFragments:
        return '降低分片并发';
      case YtDlpFallbackStep.increaseTimeout:
        return '增加超时';
      case YtDlpFallbackStep.applyRateLimit:
        return '附加限速';
      case YtDlpFallbackStep.switchPlayerClient:
        return '切换 Player Client';
      case YtDlpFallbackStep.enableCookies:
        return '启用 Cookies';
      case YtDlpFallbackStep.applyCustomUserAgent:
        return '附加 User-Agent';
      case YtDlpFallbackStep.injectVisitorData:
        return '注入 Visitor Data';
      case YtDlpFallbackStep.injectPoToken:
        return '注入 PO Token';
      case YtDlpFallbackStep.switchProxy:
        return '切换代理';
    }
  }

  Widget _buildInitialLoadingState() {
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: 4,
      itemBuilder: (context, index) => _buildTaskSkeletonCard(),
      separatorBuilder: (context, index) => const SizedBox(height: 12),
    );
  }

  Widget _buildTaskSkeletonCard() {
    return Card(
      color: const Color(0xFF232427),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(width: 30),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: _buildThumbnailPlaceholder(
                width: 82,
                height: 52,
                icon: Icons.image_outlined,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSkeletonBar(width: double.infinity, height: 14),
                  const SizedBox(height: 8),
                  _buildSkeletonBar(width: 220, height: 11),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _buildSkeletonBar(width: 64, height: 22, radius: 11),
                      const SizedBox(width: 8),
                      _buildSkeletonBar(width: 78, height: 22, radius: 11),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSkeletonBar({
    required double width,
    required double height,
    double radius = 6,
  }) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFF2E3034),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }

  Widget _buildThumbnail(
    YtDlpTaskRecord task, {
    double width = 88,
    double height = 56,
    Key? imageKey,
  }) {
    final localPath = _normalizeLocalThumbnailPath(task.localThumbnailPath);
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1;
    final cacheWidth = (width * dpr).round().clamp(1, 4096);
    final cacheHeight = (height * dpr).round().clamp(1, 4096);
    final thumbnailUrls = task.thumbnailCandidateUrls
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
    if (localPath != null && localPath.isNotEmpty) {
      return Image(
        key: imageKey,
        image: ResizeImage(
          FileImage(File(localPath)),
          width: cacheWidth,
          height: cacheHeight,
        ),
        width: width,
        height: height,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.low,
        gaplessPlayback: false,
        errorBuilder: (context, error, stackTrace) {
          if (thumbnailUrls.isNotEmpty) {
            return _buildNetworkThumbnail(
              thumbnailUrls,
              width: width,
              height: height,
              cacheWidth: cacheWidth,
              cacheHeight: cacheHeight,
              imageKey: imageKey,
            );
          }
          return _buildThumbnailPlaceholder(width: width, height: height);
        },
      );
    }
    if (thumbnailUrls.isEmpty) {
      return _buildThumbnailPlaceholder(width: width, height: height);
    }
    return _buildNetworkThumbnail(
      thumbnailUrls,
      width: width,
      height: height,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
      imageKey: imageKey,
    );
  }

  Widget _buildNetworkThumbnail(
    List<String> urls, {
    required double width,
    required double height,
    required int cacheWidth,
    required int cacheHeight,
    Key? imageKey,
  }) {
    final url = urls.first;
    return Image(
      key: imageKey,
      image: ResizeImage(
        NetworkImage(url),
        width: cacheWidth,
        height: cacheHeight,
      ),
      width: width,
      height: height,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.low,
      gaplessPlayback: false,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) {
          return child;
        }
        return _buildThumbnailPlaceholder(
          width: width,
          height: height,
          icon: Icons.image_outlined,
        );
      },
      errorBuilder: (context, error, stackTrace) {
        if (urls.length > 1) {
          return _buildNetworkThumbnail(
            urls.sublist(1),
            width: width,
            height: height,
            cacheWidth: cacheWidth,
            cacheHeight: cacheHeight,
            imageKey: imageKey,
          );
        }
        return _buildThumbnailPlaceholder(
          width: width,
          height: height,
          icon: Icons.broken_image,
        );
      },
    );
  }

  String? _normalizeLocalThumbnailPath(String? path) {
    final trimmed = path?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    if (trimmed.startsWith('file://')) {
      try {
        return p.normalize(Uri.parse(trimmed).toFilePath());
      } catch (_) {
        return p.normalize(trimmed.replaceFirst(RegExp(r'^file:/+'), ''));
      }
    }
    final normalized = p.normalize(trimmed);
    if (Platform.isWindows &&
        p.extension(normalized).toLowerCase() == '.webp') {
      return null;
    }
    return normalized;
  }

  Widget _buildThumbnailPlaceholder({
    required double width,
    required double height,
    IconData icon = Icons.video_library,
  }) {
    return Container(
      width: width,
      height: height,
      color: Colors.grey[850],
      alignment: Alignment.center,
      child: Icon(icon, color: Colors.white30),
    );
  }

  Widget _buildStatusChip(YtDlpTaskStatus status) {
    late final Color color;
    late final String label;
    switch (status) {
      case YtDlpTaskStatus.pending:
        color = Colors.white38;
        label = '待开始';
        break;
      case YtDlpTaskStatus.queued:
        color = Colors.orangeAccent;
        label = '队列中';
        break;
      case YtDlpTaskStatus.resolving:
        color = Colors.lightBlueAccent;
        label = '解析中';
        break;
      case YtDlpTaskStatus.pausing:
        color = Colors.amberAccent;
        label = '暂停中';
        break;
      case YtDlpTaskStatus.downloading:
        color = const Color(0xFFFF5A5F);
        label = '下载中';
        break;
      case YtDlpTaskStatus.postProcessing:
        color = Colors.purpleAccent;
        label = '后处理中';
        break;
      case YtDlpTaskStatus.paused:
        color = Colors.amber;
        label = '已暂停';
        break;
      case YtDlpTaskStatus.completed:
        color = Colors.greenAccent;
        label = '已完成';
        break;
      case YtDlpTaskStatus.exported:
        color = Colors.cyanAccent;
        label = '已导出';
        break;
      case YtDlpTaskStatus.failed:
        color = Colors.redAccent;
        label = '失败';
        break;
      case YtDlpTaskStatus.cancelled:
        color = Colors.grey;
        label = '已取消';
        break;
    }

    return _buildInfoChip(label, color);
  }

  Widget _buildInfoChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 11)),
    );
  }

  Widget _buildDropdownCard<T>({
    required String label,
    required T? value,
    required List<DropdownMenuItem<T>> items,
    ValueChanged<T?>? onChanged,
  }) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: items.any((item) => item.value == value) ? value : null,
          isExpanded: true,
          isDense: true,
          style: const TextStyle(fontSize: 12, color: Colors.white),
          dropdownColor: const Color(0xFF333333),
          hint: Text(
            label,
            style: const TextStyle(fontSize: 12, color: Colors.white54),
            overflow: TextOverflow.ellipsis,
          ),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildReadonlyInfoCard({
    required String label,
    required String value,
  }) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontSize: 11, color: Colors.white54),
                ),
                Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _buildSettingsDropdownRow({
    required String leftLabel,
    required String leftValue,
    required List<DropdownMenuItem<String>> leftItems,
    required ValueChanged<String?> onLeftChanged,
    required String rightLabel,
    required String rightValue,
    List<DropdownMenuItem<String>> rightItems = const [],
    ValueChanged<String?>? onRightChanged,
    VoidCallback? onRightTap,
    bool rightAsText = false,
  }) {
    final left = _buildDropdownField(
      label: leftLabel,
      value: leftValue,
      items: leftItems,
      onChanged: onLeftChanged,
    );
    final right = rightAsText
        ? _buildTextActionField(
            label: rightLabel,
            value: rightValue,
            onTap: onRightTap,
          )
        : _buildDropdownField(
            label: rightLabel,
            value: rightValue,
            items: rightItems,
            onChanged: onRightChanged,
          );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 520) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [left, const SizedBox(height: 10), right],
            );
          }
          return Row(
            children: [
              Expanded(child: left),
              const SizedBox(width: 10),
              Expanded(child: right),
            ],
          );
        },
      ),
    );
  }

  Widget _buildDropdownField({
    required String label,
    required String value,
    required List<DropdownMenuItem<String>> items,
    ValueChanged<String?>? onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
        _buildDropdownCard<String>(
          label: label,
          value: value,
          items: items,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildTextActionField({
    required String label,
    required String value,
    VoidCallback? onTap,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: onTap == null ? Colors.white38 : Colors.white,
                      fontSize: 12,
                    ),
                  ),
                ),
                Icon(
                  Icons.arrow_forward_ios_rounded,
                  size: 12,
                  color: onTap == null ? Colors.white24 : Colors.white70,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _normalizeAudioTaskOutputContainer(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'mp3':
      case 'aac':
      case 'm4a':
      case 'wav':
      case 'opus':
        return raw.trim().toLowerCase();
      default:
        return 'm4a';
    }
  }

  List<SubtitleTrack> _resolveSelectedSubtitleTracks(
    VideoMeta meta,
    DownloadSelection selection,
  ) {
    if (selection.selectedSubtitleTrackKeys.isNotEmpty) {
      final byKey = {
        for (final track in meta.subtitles) track.selectionKey: track,
      };
      return selection.selectedSubtitleTrackKeys
          .map((item) => byKey[item])
          .whereType<SubtitleTrack>()
          .toList();
    }
    if (selection.subtitleLanguages.isNotEmpty) {
      final tracks = <SubtitleTrack>[];
      final used = <String>{};
      for (final language in selection.subtitleLanguages) {
        for (final track in meta.subtitles) {
          if (!YtDlpMetaParser.matchesPreferenceLanguage(
            language,
            track.languageCode,
          )) {
            continue;
          }
          if (used.add(track.selectionKey)) {
            tracks.add(track);
          }
        }
      }
      return tracks;
    }
    return const [];
  }

  String _formatPreferredSubtitleLanguageSummary(List<String> languages) {
    if (languages.isEmpty) {
      return '未选择';
    }
    final labels = languages
        .map(YtDlpMetaParser.resolvePreferenceLanguageLabel)
        .toList();
    if (labels.length <= 3) {
      return labels.join('、');
    }
    return '${labels.take(3).join('、')} 等 ${labels.length} 项';
  }

  String _buildSubtitleSelectionSummary(
    VideoMeta meta,
    DownloadSelection selection,
  ) {
    final selectedTracks = _resolveSelectedSubtitleTracks(meta, selection);
    if (selectedTracks.isEmpty) {
      return meta.subtitles.isEmpty ? '无可用字幕' : '未选择';
    }
    if (selectedTracks.length == 1) {
      return selectedTracks.first.displayName;
    }
    final firstTwo = selectedTracks
        .take(2)
        .map((item) => item.displayName)
        .join('、');
    if (selectedTracks.length <= 2) {
      return firstTwo;
    }
    return '$firstTwo 等 ${selectedTracks.length} 项';
  }

  Widget _buildSubtitleSelectorCard({
    required VideoMeta meta,
    required DownloadSelection selection,
    VoidCallback? onTap,
  }) {
    final summary = _buildSubtitleSelectionSummary(meta, selection);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '字幕选择',
                    style: TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                  Text(summary, maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            Icon(
              Icons.arrow_drop_down_rounded,
              color: onTap == null ? Colors.white24 : Colors.white70,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSubtitleTrackPicker(
    YtDlpDownloadService service,
    YtDlpTaskRecord task,
    VideoMeta meta,
    DownloadSelection selection,
  ) async {
    _dismissActiveInput();
    final initialKeys = _resolveSelectedSubtitleTracks(
      meta,
      selection,
    ).map((item) => item.selectionKey).toSet();
    final result = await showDialog<List<String>>(
      context: context,
      builder: (dialogContext) {
        final tempSelected = Set<String>.from(initialKeys);
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF171717),
              title: const Text('选择字幕'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '支持多选；这里只显示 yt-dlp 可直接下载的字幕轨道，YouTube 自动翻译语言不在此列',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.72),
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final track in meta.subtitles)
                            CheckboxListTile(
                              dense: true,
                              value: tempSelected.contains(track.selectionKey),
                              activeColor: Colors.redAccent,
                              controlAffinity: ListTileControlAffinity.leading,
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                track.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                track.languageCode,
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 11,
                                ),
                              ),
                              onChanged: (checked) {
                                setState(() {
                                  if (checked == true) {
                                    tempSelected.add(track.selectionKey);
                                  } else {
                                    tempSelected.remove(track.selectionKey);
                                  }
                                });
                              },
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    _dismissActiveInput();
                    setState(tempSelected.clear);
                  },
                  child: const Text('清空'),
                ),
                TextButton(
                  onPressed: () {
                    _dismissActiveInput();
                    Navigator.of(dialogContext).pop();
                  },
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    _dismissActiveInput();
                    Navigator.of(dialogContext).pop(
                      meta.subtitles
                          .where(
                            (item) => tempSelected.contains(item.selectionKey),
                          )
                          .map((item) => item.selectionKey)
                          .toList(),
                    );
                  },
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
      },
    );
    _dismissActiveInput();
    if (!mounted || result == null) {
      return;
    }
    final selectedTracks = meta.subtitles
        .where((item) => result.contains(item.selectionKey))
        .toList();
    final subtitleLanguages = selectedTracks
        .map((item) => item.languageCode)
        .toSet()
        .toList();
    await service.updateTaskSelectionModel(
      task.taskId,
      selection.copyWith(
        selectedSubtitleTrackKeys: result,
        subtitleLanguages: subtitleLanguages,
        writeSubtitles: selectedTracks.any((item) => !item.isAutoGenerated),
        writeAutoSubtitles: selectedTracks.any((item) => item.isAutoGenerated),
        embedSubtitles: selectedTracks.isNotEmpty,
      ),
    );
  }

  Future<List<String>?> _showPreferredSubtitleLanguagesDialog(
    List<String> initialLanguages,
  ) async {
    final result = await showDialog<List<String>>(
      context: context,
      builder: (dialogContext) {
        final availableLanguages = <String>[
          'zh',
          'en',
          'ja',
          'ko',
          'fr',
          'de',
          'es',
          'ru',
        ];
        final selected = [...initialLanguages];
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF171717),
              title: const Text('字幕语言偏好'),
              content: SizedBox(
                width: 460,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '支持多选并排序，排在前面的语言会优先显示在任务卡片中；命中的所有字幕都会下载。',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.72),
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final language in availableLanguages)
                            _buildPreferredSubtitleLanguageTile(
                              language: language,
                              selected: selected,
                              onChanged: (checked) {
                                setState(() {
                                  if (checked) {
                                    if (!selected.contains(language)) {
                                      selected.add(language);
                                    }
                                  } else {
                                    selected.remove(language);
                                  }
                                });
                              },
                              onMoveUp: selected.contains(language)
                                  ? () {
                                      setState(() {
                                        final index = selected.indexOf(
                                          language,
                                        );
                                        if (index > 0) {
                                          final item = selected.removeAt(index);
                                          selected.insert(index - 1, item);
                                        }
                                      });
                                    }
                                  : null,
                              onMoveDown: selected.contains(language)
                                  ? () {
                                      setState(() {
                                        final index = selected.indexOf(
                                          language,
                                        );
                                        if (index >= 0 &&
                                            index < selected.length - 1) {
                                          final item = selected.removeAt(index);
                                          selected.insert(index + 1, item);
                                        }
                                      });
                                    }
                                  : null,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(const []),
                  child: const Text('清空'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(selected),
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
      },
    );
    return result;
  }

  Widget _buildPreferredSubtitleLanguageTile({
    required String language,
    required List<String> selected,
    required ValueChanged<bool> onChanged,
    VoidCallback? onMoveUp,
    VoidCallback? onMoveDown,
  }) {
    final isSelected = selected.contains(language);
    final currentIndex = selected.indexOf(language);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Checkbox(
            value: isSelected,
            activeColor: Colors.redAccent,
            onChanged: (value) => onChanged(value == true),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(YtDlpMetaParser.resolvePreferenceLanguageLabel(language)),
                Text(
                  isSelected ? '优先级 ${currentIndex + 1}' : '未选择',
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '上移',
            onPressed: onMoveUp,
            icon: const Icon(Icons.arrow_upward_rounded, size: 18),
            color: onMoveUp == null ? Colors.white24 : Colors.white70,
          ),
          IconButton(
            tooltip: '下移',
            onPressed: onMoveDown,
            icon: const Icon(Icons.arrow_downward_rounded, size: 18),
            color: onMoveDown == null ? Colors.white24 : Colors.white70,
          ),
        ],
      ),
    );
  }

  Widget _buildLabeledField({
    required String label,
    required TextEditingController controller,
    Widget? trailing,
    String? hintText,
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final field = TextField(
            controller: controller,
            keyboardType: keyboardType,
            decoration: InputDecoration(
              hintText: hintText,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          );
          if (constraints.maxWidth < 460) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    label,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
                Row(
                  children: [
                    Expanded(child: field),
                    ?trailing,
                  ],
                ),
              ],
            );
          }
          return Row(
            children: [
              SizedBox(width: 110, child: Text(label)),
              Expanded(child: field),
              ?trailing,
            ],
          );
        },
      ),
    );
  }

  Widget _buildNumericRow({
    required String leftLabel,
    required TextEditingController leftController,
    required String rightLabel,
    required TextEditingController rightController,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final left = _buildLabeledField(
            label: leftLabel,
            controller: leftController,
            keyboardType: TextInputType.number,
          );
          final right = _buildLabeledField(
            label: rightLabel,
            controller: rightController,
            keyboardType: TextInputType.number,
          );
          if (constraints.maxWidth < 560) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [left, right],
            );
          }
          return Row(
            children: [
              Expanded(child: left),
              const SizedBox(width: 8),
              Expanded(child: right),
            ],
          );
        },
      ),
    );
  }

  Widget _buildInlineTextField({
    required String label,
    required String initialValue,
    required ValueChanged<String> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextFormField(
        initialValue: initialValue,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        onChanged: onChanged,
      ),
    );
  }

  String _formatDuration(int? seconds) {
    if (seconds == null || seconds <= 0) return '--:--';
    final duration = Duration(seconds: seconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final secs = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$minutes:$secs';
    }
    return '$minutes:$secs';
  }

  String _formatPath(String path) {
    if (Platform.isMacOS || Platform.isLinux) {
      final home = Platform.environment['HOME'];
      if (home != null && path.startsWith(home)) {
        return path.replaceFirst(home, '~');
      }
    }
    if (Platform.isWindows) {
      return path.replaceAll('/', p.separator);
    }
    return path;
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) {
      return '0B';
    }
    return _formatByteAmount(bytes.toDouble());
  }

  String? _displayTaskSpeedText(String? raw) {
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    final match = RegExp(
      r'^([0-9]+(?:\.[0-9]+)?)\s*([KMGT]?)(i?)B/s$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (match == null) {
      return trimmed;
    }
    final value = double.tryParse(match.group(1) ?? '');
    if (value == null || !value.isFinite || value < 0) {
      return trimmed;
    }
    final unitPrefix = (match.group(2) ?? '').toUpperCase();
    final usesBinaryUnit = (match.group(3) ?? '').isNotEmpty;
    final exponent = switch (unitPrefix) {
      'K' => 1,
      'M' => 2,
      'G' => 3,
      'T' => 4,
      _ => 0,
    };
    final base = usesBinaryUnit ? 1024.0 : 1000.0;
    var bytesPerSecond = value;
    for (var i = 0; i < exponent; i++) {
      bytesPerSecond *= base;
    }
    return '${_formatByteAmount(bytesPerSecond)}/s';
  }

  String _formatByteAmount(double bytes) {
    if (!bytes.isFinite || bytes <= 0) {
      return '0B';
    }
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes;
    var unitIndex = 0;
    while (value >= 1000 && unitIndex < units.length - 1) {
      value /= 1000;
      unitIndex++;
    }
    final digits = unitIndex == 0 || value >= 100 ? 0 : 1;
    return '${value.toStringAsFixed(digits)}${units[unitIndex]}';
  }

  T? _firstOrNull<T>(List<T> items) {
    if (items.isEmpty) return null;
    return items.first;
  }
}

class _PoTokenDraft {
  String client;
  String context;
  String token;
  bool enabled;

  _PoTokenDraft({
    this.client = 'web',
    this.context = 'gvs',
    this.token = '',
    this.enabled = true,
  });
}
