import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../debug/developer_log.dart' as developer;
import '../../models/managed_subtitle_asset.dart';
import '../../models/media_source_ref.dart';
import '../../models/video_item.dart';
import '../../utils/subtitle_util.dart';
import '../library_service.dart';
import '../task_subtitle_storage_service.dart';
import 'bilibili_api_service.dart';
import 'bilibili_download_service.dart';
import 'bilibili_player_video.dart';
import 'bilibili_public_api_service.dart';
import 'bilibili_stream_card.dart';

/// Name of a Bilibili subtitle track: its language name, else its code.
String bilibiliSubtitleLabel(String lanDoc, String lan) {
  final doc = lanDoc.trim();
  if (doc.isNotEmpty) return doc;
  final code = lan.trim();
  if (code.isNotEmpty) return code;
  return '字幕';
}

final RegExp _aiWord = RegExp(r'(^|[^A-Za-z])AI([^A-Za-z]|$)');

/// Whether a track is one of Bilibili's machine-made subtitles: its code
/// starts with `ai-`, or its name says so ("中文（自动生成）", "AI 字幕").
bool isBilibiliAiSubtitle({required String lan, required String label}) {
  if (lan.trim().toLowerCase().startsWith('ai-')) return true;
  return _aiWord.hasMatch(label.toUpperCase()) || label.contains('自动生成');
}

/// One subtitle track of a Bilibili video part. [path] is set once the track
/// is a file of the card; [url] is where it can be downloaded.
@immutable
class BilibiliSubtitleTrack {
  const BilibiliSubtitleTrack({
    required this.lan,
    required this.label,
    required this.isAi,
    this.url = '',
    this.path,
  });

  final String lan;
  final String label;
  final bool isAi;
  final String url;
  final String? path;

  bool get isDownloaded => path != null;

  BilibiliSubtitleTrack withPath(String? path) => BilibiliSubtitleTrack(
    lan: lan,
    label: label,
    isAi: isAi,
    url: url,
    path: path,
  );

  @override
  String toString() => 'BilibiliSubtitleTrack($lan, $label, ai: $isAi)';
}

/// The tracks in `data.subtitle.subtitles` of a player answer
/// (`x/player/wbi/v2`). Tracks without an address are left out, a track
/// listed twice is kept once.
List<BilibiliSubtitleTrack> parseBilibiliSubtitleTracks(Object? data) {
  final subtitle = data is Map ? data['subtitle'] : null;
  final list = subtitle is Map ? subtitle['subtitles'] : null;
  if (list is! List) return const <BilibiliSubtitleTrack>[];
  final seen = <String>{};
  final tracks = <BilibiliSubtitleTrack>[];
  for (final raw in list) {
    if (raw is! Map) continue;
    var url = (raw['subtitle_url'] ?? '').toString().trim();
    if (url.isEmpty) continue;
    if (url.startsWith('//')) url = 'https:$url';
    if (url.startsWith('http://')) url = 'https://${url.substring(7)}';
    if (!seen.add(url)) continue;
    final lan = (raw['lan'] ?? '').toString().trim();
    final label = bilibiliSubtitleLabel((raw['lan_doc'] ?? '').toString(), lan);
    tracks.add(
      BilibiliSubtitleTrack(
        lan: lan,
        label: label,
        isAi: isBilibiliAiSubtitle(lan: lan, label: label),
        url: url,
      ),
    );
  }
  return tracks;
}

/// The Bilibili subtitles already saved as files of [item] (what a card or a
/// download wrote), in the order the card lists them.
List<BilibiliSubtitleTrack> downloadedBilibiliSubtitleTracks(VideoItem item) {
  final tracks = <BilibiliSubtitleTrack>[];
  for (final entry in item.downloadAssociatedSubtitles.entries) {
    ManagedSubtitleAsset? asset;
    for (final candidate in item.managedSubtitleAssets) {
      if (p.equals(p.normalize(candidate.path), p.normalize(entry.value))) {
        asset = candidate;
        break;
      }
    }
    final name = asset?.displayName.trim() ?? '';
    final label = subtitleDisplayLabel(name.isNotEmpty ? name : entry.key);
    final lan = asset?.language?.trim() ?? '';
    tracks.add(
      BilibiliSubtitleTrack(
        lan: lan,
        label: label,
        isAi: isBilibiliAiSubtitle(lan: lan, label: label),
        path: entry.value,
      ),
    );
  }
  return tracks;
}

/// [remote] in its own order, each with the file of the same track when one
/// was saved, then the saved files no remote track names (for example an AI
/// subtitle saved while logged in).
List<BilibiliSubtitleTrack> mergeBilibiliSubtitleTracks(
  List<BilibiliSubtitleTrack> remote,
  List<BilibiliSubtitleTrack> downloaded,
) {
  final left = List<BilibiliSubtitleTrack>.of(downloaded);
  final merged = <BilibiliSubtitleTrack>[];
  for (final track in remote) {
    var index = left.indexWhere(
      (d) => d.lan.isNotEmpty && track.lan.isNotEmpty && d.lan == track.lan,
    );
    if (index < 0) {
      final label = subtitleDisplayLabel(track.label);
      index = left.indexWhere((d) => subtitleDisplayLabel(d.label) == label);
    }
    if (index < 0) {
      merged.add(track);
    } else {
      merged.add(track.withPath(left.removeAt(index).path));
    }
  }
  return <BilibiliSubtitleTrack>[...merged, ...left];
}

/// What the subtitle area shows for the Bilibili tracks of one card.
@immutable
class BilibiliSubtitleTrackList {
  const BilibiliSubtitleTrackList({
    this.tracks = const <BilibiliSubtitleTrack>[],
    this.loading = false,
    this.aiNeedsLogin = false,
    this.listed = false,
    this.loggedIn = false,
    this.savedOnly = false,
    this.networkFailed = false,
  });

  final List<BilibiliSubtitleTrack> tracks;

  /// The track list of an online card is still being asked for.
  final bool loading;

  /// Logged out: only the CC tracks are listed.
  final bool aiNeedsLogin;

  /// Bilibili answered with the track list.
  final bool listed;

  final bool loggedIn;

  /// A downloaded video: only its saved files, nothing is asked.
  final bool savedOnly;

  /// The track list could not be asked for (no network).
  final bool networkFailed;

  /// The line shown when there is no track to pick, or null.
  String? get emptyMessage {
    if (tracks.isNotEmpty || loading) return null;
    if (savedOnly) return '这个视频没有已下载的字幕';
    if (listed) return loggedIn ? '这个视频没有字幕' : '这个视频没有 CC 字幕';
    if (networkFailed) return '联网后可查看 B 站字幕';
    return 'B 站字幕列表暂时拿不到，稍后再打开试试';
  }
}

/// Where the track list and the subtitle files come from. Tests pass fakes.
class BilibiliSubtitleTrackSource {
  const BilibiliSubtitleTrackSource({
    required this.fetchCcTracks,
    required this.fetchAiTracks,
    required this.isLoggedIn,
    required this.fetchContent,
    this.completePending,
  });

  /// The app's sources: CC tracks from the public (cookie-free) player
  /// answer, AI tracks from a second request with the login of [api], the
  /// subtitle files from a cookie-free client.
  factory BilibiliSubtitleTrackSource.app({
    required BilibiliApiService api,
    BilibiliPublicApiService? publicApi,
    Future<bool> Function(String itemId)? completePending,
    Dio? contentClient,
  }) {
    final public = publicApi ?? BilibiliPublicApiService();
    final client =
        contentClient ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 20),
            headers: const {
              'User-Agent': BilibiliPublicApiService.userAgent,
              'Referer': 'https://www.bilibili.com/',
            },
          ),
        );
    return BilibiliSubtitleTrackSource(
      fetchCcTracks: (bvid, cid) async {
        final payload = await public.getPublicJson(
          '/x/player/wbi/v2',
          query: <String, dynamic>{'bvid': bvid, 'cid': cid},
          referer: BilibiliPublicApiService.videoReferer(bvid),
          what: '字幕列表',
          signed: true,
        );
        if (payload['code'] != 0) {
          throw BilibiliPublicApiException('字幕列表暂时拿不到');
        }
        return parseBilibiliSubtitleTracks(payload['data']);
      },
      fetchAiTracks: (bvid, cid) async {
        // The logged-in player answer; its log lines carry only bvid/cid.
        final metadata = await api.fetchPlayerMetadata(bvid, cid);
        return <BilibiliSubtitleTrack>[
          for (final subtitle in metadata.subtitles)
            BilibiliSubtitleTrack(
              lan: subtitle.lan,
              label: bilibiliSubtitleLabel(subtitle.lanDoc, subtitle.lan),
              isAi: isBilibiliAiSubtitle(
                lan: subtitle.lan,
                label: bilibiliSubtitleLabel(subtitle.lanDoc, subtitle.lan),
              ),
              url: subtitle.url,
            ),
        ];
      },
      isLoggedIn: () async {
        await api.init();
        return api.hasCookie();
      },
      fetchContent: (url) async {
        final uri = Uri.tryParse(url);
        final host = uri?.host ?? '';
        if (uri == null ||
            uri.scheme != 'https' ||
            !(host.endsWith('.hdslb.com') || host.endsWith('.bilibili.com'))) {
          throw const FormatException('字幕地址无效');
        }
        final response = await client.getUri<dynamic>(uri);
        return response.data;
      },
      completePending: completePending,
    );
  }

  /// The CC tracks, asked for without the login cookie.
  final Future<List<BilibiliSubtitleTrack>> Function(String bvid, int cid)
  fetchCcTracks;

  /// The tracks of the logged-in answer; only its AI tracks are used.
  final Future<List<BilibiliSubtitleTrack>> Function(String bvid, int cid)
  fetchAiTracks;

  /// Whether a login is stored. Asks nothing over the network.
  final Future<bool> Function() isLoggedIn;

  /// The subtitle file at a track address (Bilibili's JSON subtitle).
  final Future<Object?> Function(String url) fetchContent;

  /// Finishes the player data of a watch-only entry that has none yet and
  /// returns true, or returns false when [itemId] is no such entry.
  final Future<bool> Function(String itemId)? completePending;
}

/// Where a picked track is saved: the card it belongs to.
class BilibiliSubtitleTrackStore {
  const BilibiliSubtitleTrackStore({
    required this.itemOf,
    required this.noteChanged,
    required this.writeSubtitle,
    this.changes,
  });

  factory BilibiliSubtitleTrackStore.library(LibraryService library) =>
      BilibiliSubtitleTrackStore(
        itemOf: library.getVideo,
        noteChanged: library.noteCardDataChanged,
        writeSubtitle: (itemId, label, contents) async {
          final path = await const TaskSubtitleStorageService().allocatePath(
            itemId,
            TaskSubtitleStorageService.readableSubtitleFileName(
              label: label,
              extension: '.srt',
            ),
          );
          await File(path).writeAsString(contents, flush: true);
          return path;
        },
        changes: library,
      );

  final VideoItem? Function(String itemId) itemOf;

  /// Saves the card after its subtitle files changed.
  final Future<void> Function(String itemId) noteChanged;

  /// Writes [contents] as a subtitle file of the card and returns its path.
  final Future<String> Function(String itemId, String label, String contents)
  writeSubtitle;

  /// Notifies when cards changed (for example a part got its player data).
  final Listenable? changes;
}

class _RemoteTracks {
  _RemoteTracks(this.loggedIn);

  final bool loggedIn;
  bool loading = true;
  bool failed = false;
  bool networkFailed = false;
  List<BilibiliSubtitleTrack> tracks = const <BilibiliSubtitleTrack>[];
}

/// The Bilibili subtitle tracks of the cards on the playback page: which
/// tracks a part has, and the subtitle file of a picked track.
///
/// * Online cards ask for the list once per part: CC tracks without the
///   login cookie, AI tracks with a second, logged-in request only when a
///   login is stored. Logged out, the list says AI tracks need a login.
/// * Downloaded videos list only their saved files and ask nothing.
/// * Without a network the saved files are listed, without an error.
///
/// Nothing here selects a subtitle by itself; the caller loads a picked
/// path like any other subtitle.
class BilibiliSubtitleTracks extends ChangeNotifier {
  BilibiliSubtitleTracks({required this.source, required this.store}) {
    store.changes?.addListener(notifyListeners);
  }

  /// The app instance for [download] and [library].
  factory BilibiliSubtitleTracks.forApp({
    required BilibiliDownloadService download,
    required LibraryService library,
  }) {
    final known = _app;
    if (known != null &&
        identical(known.$1, download) &&
        identical(known.$2, library)) {
      return known.$3;
    }
    final tracks = BilibiliSubtitleTracks(
      source: BilibiliSubtitleTrackSource.app(
        api: download.apiService,
        completePending: (itemId) => download.isPendingWatchPart(itemId)
            ? download.completeWatchPart(library, itemId)
            : Future<bool>.value(false),
      ),
      store: BilibiliSubtitleTrackStore.library(library),
    );
    _app = (download, library, tracks);
    return tracks;
  }

  static (BilibiliDownloadService, LibraryService, BilibiliSubtitleTracks)?
  _app;

  /// Used instead of the app instance when set (tests put fakes here).
  static BilibiliSubtitleTracks? overrideForTesting;

  final BilibiliSubtitleTrackSource source;
  final BilibiliSubtitleTrackStore store;

  final Map<String, _RemoteTracks> _remote = <String, _RemoteTracks>{};
  final Map<String, Future<String?>> _loading = <String, Future<String?>>{};
  final Set<String> _failedLoads = <String>{};
  bool _disposed = false;

  /// `bvid#cid` of an online card, or null for anything else.
  static String? onlineKeyOf(VideoItem item) {
    final online =
        item.sourceRef?.kind == MediaSourceKind.bilibiliStream ||
        item.path.startsWith('bilibili://stream/');
    if (!online) return null;
    final bvid = bilibiliStreamCardBvid(item);
    var cid = item.sourceRef?.cid;
    if (cid == null || cid <= 0) {
      final match = RegExp(r'[?&]cid=(\d+)').firstMatch(item.path);
      cid = match == null ? null : int.tryParse(match.group(1)!);
    }
    if (bvid == null || bvid.isEmpty || cid == null || cid <= 0) return null;
    return '$bvid#$cid';
  }

  /// Whether [item] is a Bilibili video whose tracks are listed here.
  static bool covers(VideoItem? item) => bilibiliPlayerVideoOf(item) != null;

  /// Asks for the track list of the card [itemId] unless it is known for the
  /// current login. Downloaded videos ask nothing.
  Future<void> ensureLoaded(String itemId) async {
    final item = store.itemOf(itemId);
    if (item == null) return;
    final key = onlineKeyOf(item);
    if (key == null) return;
    final known = _remote[key];
    if (known != null && known.loading) return;
    final bool loggedIn;
    try {
      loggedIn = await source.isLoggedIn();
    } catch (error) {
      developer.log('Bilibili login check failed', error: error.runtimeType);
      return;
    }
    final again = _remote[key];
    if (again != null &&
        (again.loading || (!again.failed && again.loggedIn == loggedIn))) {
      return;
    }
    final entry = _RemoteTracks(loggedIn);
    _remote[key] = entry;
    _notify();
    final separator = key.indexOf('#');
    final bvid = key.substring(0, separator);
    final cid = int.parse(key.substring(separator + 1));
    try {
      final cc = await source.fetchCcTracks(bvid, cid);
      final ai = <BilibiliSubtitleTrack>[];
      if (loggedIn) {
        try {
          ai.addAll(
            (await source.fetchAiTracks(bvid, cid)).where((t) => t.isAi),
          );
        } catch (error) {
          developer.log(
            'Bilibili AI subtitle list unavailable',
            error: error.runtimeType,
          );
        }
      }
      final seen = <String>{};
      entry.tracks = <BilibiliSubtitleTrack>[
        for (final track in cc)
          if (!track.isAi && seen.add(track.url)) track,
        for (final track in ai)
          if (seen.add(track.url)) track,
      ];
    } catch (error) {
      entry
        ..failed = true
        ..networkFailed = _isNetworkFailure(error);
      developer.log(
        'Bilibili subtitle list unavailable',
        error: error.runtimeType,
      );
    } finally {
      entry.loading = false;
      _notify();
    }
  }

  static bool _isNetworkFailure(Object error) =>
      error is TimeoutException ||
      error is SocketException ||
      (error is BilibiliPublicApiException && error.isNetworkError) ||
      (error is DioException && error.type != DioExceptionType.badResponse);

  /// The tracks to show for the card [itemId] right now.
  BilibiliSubtitleTrackList listFor(String itemId) {
    final item = store.itemOf(itemId);
    if (item == null) return const BilibiliSubtitleTrackList();
    final saved = downloadedBilibiliSubtitleTracks(item);
    final key = onlineKeyOf(item);
    if (key == null) {
      return BilibiliSubtitleTrackList(tracks: saved, savedOnly: true);
    }
    final remote = _remote[key];
    if (remote == null || remote.loading) {
      return BilibiliSubtitleTrackList(tracks: saved, loading: true);
    }
    if (remote.failed) {
      return BilibiliSubtitleTrackList(
        tracks: saved,
        networkFailed: remote.networkFailed,
      );
    }
    return BilibiliSubtitleTrackList(
      tracks: mergeBilibiliSubtitleTracks(remote.tracks, saved),
      listed: true,
      loggedIn: remote.loggedIn,
      aiNeedsLogin: !remote.loggedIn,
    );
  }

  static String _trackKey(String itemId, BilibiliSubtitleTrack track) =>
      '$itemId|${track.lan}|${track.label}|${track.url}';

  /// Whether the file of [track] is being fetched for [itemId].
  bool isLoading(String itemId, BilibiliSubtitleTrack track) =>
      _loading.containsKey(_trackKey(itemId, track));

  /// Whether the last fetch of [track] for [itemId] failed.
  bool hasFailed(String itemId, BilibiliSubtitleTrack track) =>
      _failedLoads.contains(_trackKey(itemId, track));

  /// The subtitle file of [track] for the card [itemId], fetched and saved
  /// with the card when it is not a file yet. Null when it could not be had.
  ///
  /// A watch-only entry still waiting for its player data gets that first
  /// (it saves every track), so the track is not fetched twice.
  Future<String?> load(String itemId, BilibiliSubtitleTrack track) {
    final saved = track.path;
    if (saved != null && File(saved).existsSync()) {
      return Future<String?>.value(saved);
    }
    final key = _trackKey(itemId, track);
    final running = _loading[key];
    if (running != null) return running;
    _failedLoads.remove(key);
    final loading = _load(itemId, track);
    _loading[key] = loading;
    _notify();
    return loading
        .then((path) {
          if (path == null) _failedLoads.add(key);
          return path;
        })
        .whenComplete(() {
          _loading.remove(key);
          _notify();
        });
  }

  Future<String?> _load(String itemId, BilibiliSubtitleTrack track) async {
    try {
      final complete = source.completePending;
      if (complete != null && await complete(itemId)) {
        final item = store.itemOf(itemId);
        if (item != null) {
          final merged = mergeBilibiliSubtitleTracks(<BilibiliSubtitleTrack>[
            track.withPath(null),
          ], downloadedBilibiliSubtitleTracks(item));
          final path = merged.first.path;
          if (path != null && File(path).existsSync()) return path;
        }
      }
      if (track.url.isEmpty) return null;
      final payload = await source.fetchContent(track.url);
      final srt = SubtitleUtil.convertJsonToSrt(payload);
      if (srt.trim().isEmpty) return null;
      final item = store.itemOf(itemId);
      if (item == null) return null;
      final path = await store.writeSubtitle(itemId, track.label, srt);
      final current = store.itemOf(itemId);
      if (current == null) {
        await _deleteQuietly(path);
        return null;
      }
      _addToCard(current, track, path);
      await store.noteChanged(itemId);
      return path;
    } catch (error) {
      developer.log(
        'Bilibili subtitle track not loaded',
        error: error.runtimeType,
      );
      return null;
    }
  }

  static void _addToCard(
    VideoItem item,
    BilibiliSubtitleTrack track,
    String path,
  ) {
    final subtitles = <String, String>{...?item.additionalSubtitles};
    final label = subtitleDisplayLabel(track.label);
    var key = label;
    if (subtitles.containsKey(key)) {
      key = p.basename(path);
      var serial = 2;
      while (subtitles.containsKey(key)) {
        key =
            '${p.basenameWithoutExtension(path)} ($serial)'
            '${p.extension(path)}';
        serial++;
      }
    }
    subtitles[key] = path;
    item
      ..additionalSubtitles = subtitles
      ..usesManagedAssociatedSubtitles = true
      ..managedSubtitleAssets = <ManagedSubtitleAsset>[
        ...item.managedSubtitleAssets,
        ManagedSubtitleAsset(
          assetId: 'bilibili-${DateTime.now().microsecondsSinceEpoch}',
          path: p.normalize(path),
          kind: ManagedSubtitleAssetKind.downloaded,
          displayName: label,
          language: track.lan.isEmpty ? null : track.lan,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ];
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    store.changes?.removeListener(notifyListeners);
    super.dispose();
  }
}
