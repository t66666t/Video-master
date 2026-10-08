import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/bilibili_download_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_quick_import.dart';
import 'package:video_player_app/services/bilibili/bilibili_stream_card.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_cards.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playback_navigation_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/utils/app_toast.dart';

bool _cardActionRunning = false;

/// Opens a video from a Bilibili page on the playback page. Pages take one
/// of these so tests can check the tap without starting playback.
typedef BilibiliVideoWatcher =
    Future<void> Function(
      BuildContext context, {
      required String bvid,
      int? page,
      Duration? startAt,
    });

/// The tap on a video in search results, watch history, an uploader's posts,
/// a collection or a pasted link: plays [bvid] right away on the regular
/// playback page.
///
/// By default a watch-only card is used (or the library card when one exists
/// for the BV + part) and nothing is added to the media library; with "auto
/// import on play" on, the library card is reused or created as before. [page]
/// null continues the part saved in the watch history, [startAt] overrides
/// the saved position.
Future<void> watchBilibiliVideo(
  BuildContext context, {
  required String bvid,
  int? page,
  Duration? startAt,
}) async {
  if (_cardActionRunning) return;
  _cardActionRunning = true;
  final service = context.read<BilibiliDownloadService>();
  final library = context.read<LibraryService>();
  final playback = context.read<MediaPlaybackService>();
  final loading = AppToast.showLoading('正在准备播放…');
  BilibiliWatchPlan plan;
  try {
    await service.init();
    plan = await prepareBilibiliWatch(
      service: service,
      library: library,
      bvid: bvid,
      page: page,
      startAt: startAt,
      settings: SettingsService(),
      cards: BilibiliWatchCards.instance,
      playingItemId: playback.currentItem?.id,
    );
  } catch (error, stack) {
    developer.log('Playing $bvid failed', error: error, stackTrace: stack);
    await loading.dismiss(immediate: true);
    AppToast.show(_failureText('播放准备失败', error), type: AppToastType.error);
    return;
  } finally {
    _cardActionRunning = false;
  }
  await loading.dismiss(immediate: true);
  if (!context.mounted) return;
  openLibraryItemPlayback(context, plan.item, queue: plan.queue);
  if (!plan.imported) return;

  final partCount = plan.videoInfo.pages.length;
  if (partCount > 1 && partCount <= kBilibiliAutoFillPartLimit) {
    final playlist = context.read<PlaylistManager>();
    unawaited(
      _fillRemainingParts(
        service,
        library,
        playlist,
        BilibiliStreamCardBatch(
          videoInfo: plan.videoInfo,
          cards: <BilibiliStreamCardResult>[
            BilibiliStreamCardResult(item: plan.item, created: false),
          ],
        ),
        bvid: bvid,
      ),
    );
  } else if (partCount > kBilibiliAutoFillPartLimit) {
    AppToast.show('该视频分P较多，可用「导入」旁的位置按钮选择「全部分P」补全选集');
  }
}

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
    batch = await obtainBilibiliPlaybackCard(
      service,
      library,
      bvid: bvid,
      page: page,
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
  BilibiliWatchCards.instance?.track(batch.cards.first.item);
  if (!context.mounted) return;
  openLibraryItemPlayback(context, batch.cards.first.item);

  final partCount = batch.videoInfo.pages.length;
  if (partCount > 1 && partCount <= kBilibiliAutoFillPartLimit) {
    final playlist = context.read<PlaylistManager>();
    unawaited(
      _fillRemainingParts(service, library, playlist, batch, bvid: bvid),
    );
  } else if (partCount > kBilibiliAutoFillPartLimit) {
    AppToast.show('该视频分P较多，可用「导入」旁的位置按钮选择「全部分P」补全选集');
  }
}

/// Card half of [playBilibiliVideoAsCard]: reuses or creates the online card
/// for [bvid] part [page] and records the watch history entry. Opening the
/// playback page is left to the caller.
Future<BilibiliStreamCardBatch> obtainBilibiliPlaybackCard(
  BilibiliDownloadService service,
  LibraryService library, {
  required String bvid,
  required int page,
  BilibiliHistoryService? history,
}) async {
  final batch = await service.obtainStreamCardsForVideo(
    library,
    bvid: bvid,
    pages: <int>[page],
  );
  final info = batch.videoInfo;
  final card = batch.cards.first.item;
  final playedPage = card.sourceRef?.page ?? page;
  var partTitle = '';
  if (info.pages.length > 1) {
    for (final part in info.pages) {
      if (part.page == playedPage) partTitle = part.part;
    }
  }
  try {
    await (history ?? BilibiliHistoryService.instance).recordWatch(
      BilibiliWatchHistoryEntry(
        bvid: info.bvid.isNotEmpty ? info.bvid : bvid,
        title: info.title,
        ownerName: info.ownerName,
        coverUrl: info.pic,
        page: playedPage,
        partTitle: partTitle,
        watchedAt: DateTime.now(),
      ),
    );
  } catch (error) {
    // History is best effort and never blocks playback.
    developer.log('Watch history not recorded', error: error);
  }
  return batch;
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

/// Opens a card on the regular playback page (portrait or landscape per
/// settings), with its folder as the episode queue, or [queue] when given (a
/// watch-only card has no folder and plays alone).
void openLibraryItemPlayback(
  BuildContext context,
  VideoItem item, {
  List<VideoItem>? queue,
}) {
  final playback = context.read<MediaPlaybackService>();
  final existingController = playback.currentItem?.id == item.id
      ? playback.controller
      : null;
  context.read<PlaylistManager>().prepareLibraryPlayback(
    item,
    searchItems: queue,
    useSearchResultsAsQueue: queue != null,
  );
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
