import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_quick_import.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/widgets/library_folder_picker.dart';

/// Runs an import from the import buttons. Pages take one of these so tests
/// can check the taps without the network.
typedef BilibiliQuickImporter =
    Future<void> Function(
      BuildContext context, {
      required String bvid,
      int? page,
      required bool pickPlace,
    });

bool _importRunning = false;

/// The "import" buttons: the main button imports to the default place in
/// one tap; with [pickPlace] the folder picker asks where (and, for a
/// multi-part video, which parts) first.
Future<void> importBilibiliVideoQuick(
  BuildContext context, {
  required String bvid,
  int? page,
  bool pickPlace = false,
  BilibiliVideoInfo? videoInfo,
}) async {
  if (_importRunning) return;
  _importRunning = true;
  final service = context.read<BilibiliDownloadService>();
  final library = context.read<LibraryService>();
  String? playingItemId;
  try {
    playingItemId = context.read<MediaPlaybackService>().currentItem?.id;
  } on ProviderNotFoundException {
    playingItemId = null;
  }
  final settings = SettingsService();
  final history = BilibiliHistoryService.instance;
  try {
    await service.init();
    BilibiliImportTarget? target;
    bool? allParts;
    var remember = false;
    var info = videoInfo;
    if (pickPlace) {
      if (info == null) {
        final loading = AppToast.showLoading('正在读取视频信息…');
        try {
          info = await service.apiService.fetchVideoInfo(bvid);
        } finally {
          await loading.dismiss(immediate: true);
        }
      }
      await history.ensureLoaded();
      if (!context.mounted) return;
      final part =
          page ??
          bilibiliImportPartOf(
            library,
            bvid: bvid,
            history: history,
            playingItemId: playingItemId,
          );
      final pick = await showBilibiliImportPicker(
        context,
        library: library,
        current: BilibiliImportTarget.parse(settings.bilibiliImportTarget),
        partCount: info.pages.length,
        currentPage: part,
      );
      if (pick == null) return;
      target = BilibiliImportTarget.picked(pick.folderId);
      allParts = pick.allParts;
      remember = pick.setAsDefault;
      page = part;
    }
    final loading = AppToast.showLoading('正在导入…');
    BilibiliQuickImportResult result;
    try {
      result = await runBilibiliQuickImport(
        service: service,
        library: library,
        bvid: bvid,
        page: page,
        target: target,
        allParts: allParts,
        rememberTarget: remember,
        videoInfo: info,
        settings: settings,
        history: history,
        playingItemId: playingItemId,
      );
    } finally {
      await loading.dismiss(immediate: true);
    }
    AppToast.show(
      result.message,
      type: result.createdAny && !result.fellBackToRoot
          ? AppToastType.success
          : AppToastType.info,
    );
  } catch (error, stack) {
    developer.log('Import of $bvid failed', error: error, stackTrace: stack);
    AppToast.show(
      error is StateError ? '导入失败：${error.message}' : '导入失败，请检查网络或 B 站登录状态',
      type: AppToastType.error,
    );
  } finally {
    _importRunning = false;
  }
}

/// Choice made in [showBilibiliImportPicker].
class BilibiliImportPick {
  const BilibiliImportPick({
    required this.folderId,
    required this.setAsDefault,
    required this.allParts,
  });

  /// Null is the library root.
  final String? folderId;
  final bool setAsDefault;
  final bool allParts;
}

/// The folder picker of the import buttons. A multi-part video also offers
/// "all parts" / "current part only"; all parts is preselected up to
/// [kBilibiliAutoFillPartLimit] parts, as the one-tap import does.
Future<BilibiliImportPick?> showBilibiliImportPicker(
  BuildContext context, {
  required LibraryService library,
  required BilibiliImportTarget current,
  int partCount = 1,
  int currentPage = 1,
}) async {
  var allParts = partCount > 1 && partCount <= kBilibiliAutoFillPartLimit;
  final pick = await showLibraryFolderPicker(
    context,
    library: library,
    initialFolderId: current.folderId,
    title: '导入到…',
    accent: AppTokens.brandBilibili,
    header: partCount > 1
        ? (context) => StatefulBuilder(
            builder: (context, setHeaderState) => Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  key: const ValueKey('bilibili-import-all-parts'),
                  label: Text('全部分P（$partCount 个）'),
                  selected: allParts,
                  onSelected: (_) => setHeaderState(() => allParts = true),
                ),
                ChoiceChip(
                  key: const ValueKey('bilibili-import-current-part'),
                  label: Text('仅当前 P$currentPage'),
                  selected: !allParts,
                  onSelected: (_) => setHeaderState(() => allParts = false),
                ),
              ],
            ),
          )
        : null,
  );
  if (pick == null) return null;
  return BilibiliImportPick(
    folderId: pick.folderId,
    setAsDefault: pick.setAsDefault,
    allParts: partCount > 1 && allParts,
  );
}

/// "导入" with a small folder button next to it, or "已导入" once the part
/// has a library card. Used on search results, uploader posts, collections,
/// the watch history and the video detail page.
class BilibiliImportButtons extends StatelessWidget {
  const BilibiliImportButtons({
    super.key,
    required this.bvid,
    this.page,
    this.onImport,
    this.library,
    this.history,
    this.large = false,
  });

  final String bvid;

  /// Null: the part being watched or the one in the watch history.
  final int? page;
  final BilibiliQuickImporter? onImport;
  final LibraryService? library;
  final BilibiliHistoryService? history;

  /// Detail page size instead of the compact list size.
  final bool large;

  /// The app's library from the widget tree; pages pumped on their own in
  /// tests have none and simply show the import button.
  static LibraryService? _libraryOf(BuildContext context) {
    try {
      return Provider.of<LibraryService>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final lib = library ?? _libraryOf(context);
    final watchHistory = history ?? BilibiliHistoryService.instance;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[?lib, watchHistory]),
      builder: (context, _) {
        final part =
            page ??
            (lib == null
                ? watchHistory.watchEntryOf(bvid)?.page ?? 1
                : bilibiliImportPartOf(lib, bvid: bvid, history: watchHistory));
        final imported = lib == null
            ? null
            : findImportedBilibiliCard(lib, bvid: bvid, page: part);
        final height = large ? 36.0 : 28.0;
        final fontSize = large ? 14.0 : 12.0;
        final radius = BorderRadius.circular(height / 2);
        if (imported != null) {
          return Material(
            key: ValueKey('bilibili-imported-$bvid'),
            color: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: radius,
              side: const BorderSide(color: AppTokens.text4),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => AppToast.show(
                '已在媒体库中（${bilibiliFolderLabel(lib!, imported.parentId)}），'
                '不会重复导入',
              ),
              child: SizedBox(
                height: height,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: large ? 14 : 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.check_rounded,
                        size: fontSize + 2,
                        color: AppTokens.text2,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '已导入',
                        style: TextStyle(
                          color: AppTokens.text2,
                          fontSize: fontSize,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }
        final run = onImport ?? importBilibiliVideoQuick;
        return Material(
          color: AppTokens.brandBilibili,
          shape: RoundedRectangleBorder(borderRadius: radius),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            height: height,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  key: ValueKey('bilibili-import-$bvid'),
                  onTap: () => unawaited(
                    run(context, bvid: bvid, page: page, pickPlace: false),
                  ),
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: large ? 14 : 10,
                      right: large ? 10 : 8,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.library_add_outlined,
                          size: fontSize + 2,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '导入',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: fontSize,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Container(
                  width: 1,
                  height: height * 0.56,
                  color: Colors.white.withValues(alpha: 0.4),
                ),
                Tooltip(
                  message: '选择导入位置',
                  child: InkWell(
                    key: ValueKey('bilibili-import-pick-$bvid'),
                    onTap: () => unawaited(
                      run(context, bvid: bvid, page: page, pickPlace: true),
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: large ? 10 : 7),
                      child: Icon(
                        Icons.drive_folder_upload_outlined,
                        size: fontSize + 3,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
