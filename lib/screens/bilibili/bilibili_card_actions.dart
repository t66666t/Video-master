import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/bilibili_download_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_stream_card.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playback_navigation_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/utils/app_toast.dart';

/// Multi-part videos up to this size get every part as a card in the
/// background after "play", so the player's episode list is complete. Larger
/// ones only get the played part, to keep request volume reasonable.
const int kBilibiliAutoFillPartLimit = 50;

bool _cardActionRunning = false;

/// "Play" on an in-app Bilibili page: reuse or create the online card for
/// [bvid] part [page], then open it on the regular playback page.
Future<void> playBilibiliVideoAsCard(
  BuildContext context, {
  required String bvid,
  required int page,
}) async {
  if (_cardActionRunning) return;
  _cardActionRunning = true;
  final service = context.read<BilibiliDownloadService>();
  final library = context.read<LibraryService>();
  final loading = AppToast.showLoading('正在准备在线播放…');
  BilibiliStreamCardBatch batch;
  try {
    await service.init();
    batch = await service.obtainStreamCardsForVideo(
      library,
      bvid: bvid,
      pages: <int>[page],
    );
  } catch (error, stack) {
    developer.log(
      'Online play for $bvid failed',
      error: error,
      stackTrace: stack,
    );
    await loading.dismiss(immediate: true);
    AppToast.show(_failureText('在线播放准备失败', error), type: AppToastType.error);
    return;
  } finally {
    _cardActionRunning = false;
  }
  await loading.dismiss(immediate: true);
  if (!context.mounted) return;
  openLibraryItemPlayback(context, batch.cards.first.item);

  final partCount = batch.videoInfo.pages.length;
  if (partCount > 1 && partCount <= kBilibiliAutoFillPartLimit) {
    final playlist = context.read<PlaylistManager>();
    unawaited(
      _fillRemainingParts(service, library, playlist, batch, bvid: bvid),
    );
  } else if (partCount > kBilibiliAutoFillPartLimit) {
    AppToast.show('该视频分P较多，可用「导入为卡片」→「全部分P」补全选集');
  }
}

Future<void> _fillRemainingParts(
  BilibiliDownloadService service,
  LibraryService library,
  PlaylistManager playlist,
  BilibiliStreamCardBatch batch, {
  required String bvid,
}) async {
  try {
    final filled = await service.obtainStreamCardsForVideo(
      library,
      bvid: bvid,
      pages: [for (final part in batch.videoInfo.pages) part.page],
      videoInfo: batch.videoInfo,
    );
    if (filled.createdCount > 0) playlist.reloadPlaylist();
  } catch (error, stack) {
    developer.log(
      'Filling parts of $bvid failed',
      error: error,
      stackTrace: stack,
    );
  }
}

/// Opens a library card on the regular playback page (portrait or landscape
/// per settings), with its folder as the episode queue.
void openLibraryItemPlayback(BuildContext context, VideoItem item) {
  final playback = context.read<MediaPlaybackService>();
  final existingController = playback.currentItem?.id == item.id
      ? playback.controller
      : null;
  context.read<PlaylistManager>().prepareLibraryPlayback(item);
  PlaybackNavigationService.instance.primeLibraryPlaybackEntry(
    playbackService: playback,
    item: item,
    existingController: existingController,
  );
  Navigator.of(context).push(
    PlaybackNavigationService.buildPlaybackEntryRoute(
      item,
      existingController: existingController,
    ),
  );
}

/// "Import as card": asks where to put the cards (and which parts), then
/// reuses or creates them without starting playback.
Future<void> importBilibiliVideoAsCards(
  BuildContext context, {
  required String bvid,
  required int page,
  required int partCount,
}) async {
  if (_cardActionRunning) return;
  final library = context.read<LibraryService>();
  final service = context.read<BilibiliDownloadService>();
  final choice = await showBilibiliCardImportDialog(
    context,
    library: library,
    page: page,
    partCount: partCount,
  );
  if (choice == null || _cardActionRunning) return;
  _cardActionRunning = true;
  final loading = AppToast.showLoading('正在导入为卡片…');
  try {
    await service.init();
    final batch = await service.obtainStreamCardsForVideo(
      library,
      bvid: bvid,
      pages: choice.allParts
          ? List<int>.generate(partCount, (index) => index + 1)
          : <int>[page],
      useDefaultLocation: choice.useDefaultLocation,
      targetFolderId: choice.folderId,
    );
    await loading.dismiss(immediate: true);
    AppToast.show(
      describeBilibiliCardImport(batch),
      type: batch.createdCount > 0 ? AppToastType.success : AppToastType.info,
    );
  } catch (error, stack) {
    developer.log(
      'Card import for $bvid failed',
      error: error,
      stackTrace: stack,
    );
    await loading.dismiss(immediate: true);
    AppToast.show(_failureText('导入失败', error), type: AppToastType.error);
  } finally {
    _cardActionRunning = false;
  }
}

/// Toast text summarising an import.
String describeBilibiliCardImport(BilibiliStreamCardBatch batch) {
  final created = batch.createdCount;
  final reused = batch.reusedCount;
  final failed = batch.failedPages.length;
  final parts = <String>[
    if (created > 0) '已导入 $created 张在线卡片',
    if (created == 0 && reused > 0) '已在媒体库中，未重复创建',
    if (created > 0 && reused > 0) '$reused 张已存在',
    if (failed > 0) '$failed 个分P失败',
  ];
  return parts.isEmpty ? '没有可导入的分P' : parts.join('，');
}

/// "Download": hands the BV + part to the existing Bilibili download page.
Future<void> openBilibiliVideoDownload(
  BuildContext context, {
  required String bvid,
  required int page,
  required int partCount,
}) {
  final input = partCount > 1
      ? 'https://www.bilibili.com/video/$bvid?p=$page'
      : 'https://www.bilibili.com/video/$bvid';
  return Navigator.of(context).push(
    AppMaterialPageRoute<void>(
      builder: (_) =>
          BilibiliDownloadScreen(initialInput: input, initialPage: page),
    ),
  );
}

String _failureText(String prefix, Object error) {
  if (error is StateError) return '$prefix：${error.message}';
  return '$prefix，请检查网络或 B 站登录状态';
}

/// Result of [showBilibiliCardImportDialog].
class BilibiliCardImportChoice {
  /// Use the import location configured for online cards.
  final bool useDefaultLocation;

  /// Explicit folder when [useDefaultLocation] is false; null = library root.
  final String? folderId;
  final bool allParts;

  const BilibiliCardImportChoice({
    required this.useDefaultLocation,
    this.folderId,
    this.allParts = false,
  });
}

typedef _FolderEntry = ({VideoCollection folder, int depth});

List<_FolderEntry> _folderTree(LibraryService library) {
  final entries = <_FolderEntry>[];
  final visited = <String>{};
  void walk(String? parentId, int depth) {
    for (final child in library.getContents(parentId)) {
      if (child is! VideoCollection || child.isRecycled) continue;
      if (!visited.add(child.id)) continue;
      entries.add((folder: child, depth: depth));
      walk(child.id, depth + 1);
    }
  }

  walk(null, 0);
  return entries;
}

const String _defaultTarget = '\u0000default';
const String _rootTarget = '\u0000root';

Future<BilibiliCardImportChoice?> showBilibiliCardImportDialog(
  BuildContext context, {
  required LibraryService library,
  required int page,
  required int partCount,
}) {
  final folders = _folderTree(library);
  var target = _defaultTarget;
  var allParts = false;
  return showDialog<BilibiliCardImportChoice>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) {
        Widget option({
          required String value,
          required String label,
          IconData icon = Icons.folder_outlined,
          int depth = 0,
        }) {
          final selected = target == value;
          return ListTile(
            key: ValueKey<String>('bilibili-import-target-$value'),
            dense: true,
            contentPadding: EdgeInsets.only(left: 8.0 + depth * 16, right: 8),
            leading: Icon(
              icon,
              size: 20,
              color: selected ? AppTokens.brandBilibili : AppTokens.text2,
            ),
            title: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? AppTokens.brandBilibili : AppTokens.text1,
                fontSize: 14,
              ),
            ),
            trailing: selected
                ? const Icon(
                    Icons.check,
                    size: 18,
                    color: AppTokens.brandBilibili,
                  )
                : null,
            onTap: () => setDialogState(() => target = value),
          );
        }

        return AlertDialog(
          title: const Text('导入为卡片'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (partCount > 1) ...[
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: Text('当前分P（P$page）'),
                        selected: !allParts,
                        onSelected: (_) =>
                            setDialogState(() => allParts = false),
                      ),
                      ChoiceChip(
                        label: Text('全部分P（$partCount 个）'),
                        selected: allParts,
                        onSelected: (_) =>
                            setDialogState(() => allParts = true),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                const Text(
                  '导入到',
                  style: TextStyle(color: AppTokens.text2, fontSize: 13),
                ),
                const SizedBox(height: 4),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      option(
                        value: _defaultTarget,
                        label: '默认导入位置',
                        icon: Icons.auto_awesome_outlined,
                      ),
                      option(
                        value: _rootTarget,
                        label: '媒体库根目录',
                        icon: Icons.home_outlined,
                      ),
                      for (final entry in folders)
                        option(
                          value: entry.folder.id,
                          label: entry.folder.name,
                          depth: entry.depth + 1,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppTokens.brandBilibili,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(
                BilibiliCardImportChoice(
                  useDefaultLocation: target == _defaultTarget,
                  folderId: target == _defaultTarget || target == _rootTarget
                      ? null
                      : target,
                  allParts: allParts,
                ),
              ),
              child: const Text('导入'),
            ),
          ],
        );
      },
    ),
  );
}
