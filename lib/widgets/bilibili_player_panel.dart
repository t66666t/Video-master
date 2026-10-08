import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player_app/models/bilibili_browse_models.dart';
import 'package:video_player_app/screens/bilibili/bilibili_card_actions.dart';
import 'package:video_player_app/screens/bilibili/bilibili_description_text.dart';
import 'package:video_player_app/screens/bilibili/bilibili_import_buttons.dart';
import 'package:video_player_app/screens/bilibili/bilibili_settings_screen.dart';
import 'package:video_player_app/screens/bilibili/bilibili_uploader_screen.dart';
import 'package:video_player_app/screens/bilibili/bilibili_video_interactions.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_video_actions.dart';
import 'package:video_player_app/services/bilibili/bilibili_video_detail_cache.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_launch.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/utils/bilibili_description_links.dart';
import 'package:video_player_app/utils/bilibili_text.dart';
import 'package:video_player_app/utils/bilibili_url_parser.dart';
import 'package:video_player_app/widgets/bilibili_cover_image.dart';

/// Plays another video in place of the open playback page.
Future<void> _watchInPlace(
  BuildContext context, {
  required String bvid,
  int? page,
  Duration? startAt,
  BilibiliWatchPreview? preview,
}) => watchBilibiliVideo(
  context,
  bvid: bvid,
  page: page,
  startAt: startAt,
  replaceCurrent: true,
  preview: preview,
);

/// The playback page's Bilibili panel: what the video is (title, UP, counts,
/// tags, description), the account actions (like, coin, favourite, follow),
/// import and download, the part list entry and the collection.
///
/// The detail comes from [BilibiliVideoDetailCache] by BV id. Until it is
/// there, and when it cannot be loaded, the panel shows what the card
/// already knows ([fallbackTitle]) with a retry, never an endless spinner.
class BilibiliPlayerPanel extends StatefulWidget {
  const BilibiliPlayerPanel({
    super.key,
    required this.bvid,
    this.page = 1,
    this.fallbackTitle = '',
    this.onCollapse,
    this.onOpenEpisodes,
    this.onWatchVideo,
    this.cache,
    this.api,
    this.actions,
  });

  final String bvid;

  /// Part being played.
  final int page;

  /// Title of the playing card, shown before the detail is there.
  final String fallbackTitle;

  /// The panel's collapse button; hidden when null.
  final VoidCallback? onCollapse;

  /// Opens the player's own part list; the entry is hidden when null.
  final VoidCallback? onOpenEpisodes;

  /// Plays another video (collection entries, links in the description) in
  /// place of the open playback page.
  final BilibiliVideoWatcher? onWatchVideo;

  final BilibiliVideoDetailCache? cache;

  /// Short links and av numbers in the description, and the uploader page.
  final BilibiliPublicApiService? api;

  /// Like / coin / favourite / follow; defaults to the app's Bilibili
  /// service. Without either, those buttons are not shown.
  final BilibiliVideoActions? actions;

  @override
  State<BilibiliPlayerPanel> createState() => _BilibiliPlayerPanelState();
}

class _BilibiliPlayerPanelState extends State<BilibiliPlayerPanel> {
  late final BilibiliPublicApiService _api =
      widget.api ?? BilibiliPublicApiService();
  final SettingsService _settings = SettingsService();
  BilibiliVideoDetail? _detail;
  bool _failed = false;
  bool _showAllEpisodes = false;
  bool _openingLink = false;
  int _loadGeneration = 0;
  BilibiliVideoInteractions? _interactions;

  BilibiliVideoDetailCache get _cache =>
      widget.cache ?? BilibiliVideoDetailCache.instance;

  @override
  void initState() {
    super.initState();
    _settings.addListener(_rebuild);
    _start();
  }

  @override
  void didUpdateWidget(covariant BilibiliPlayerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bvid != widget.bvid) {
      _showAllEpisodes = false;
      _start();
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    _settings.removeListener(_rebuild);
    _interactions?.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _start() {
    _interactions?.dispose();
    _interactions = null;
    _failed = false;
    _detail = _cache.peek(widget.bvid);
    final kept = _detail;
    if (kept != null) {
      _loadGeneration++;
      _startInteractions(kept);
    } else {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final bvid = widget.bvid;
    if (mounted) setState(() => _failed = false);
    try {
      final detail = await _cache.get(bvid);
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _detail = detail);
      _startInteractions(detail);
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _failed = true);
    }
  }

  BilibiliVideoActions? _resolveActions() {
    final own = widget.actions;
    if (own != null) return own;
    try {
      return BilibiliVideoActions.forService(
        context.read<BilibiliDownloadService>(),
      );
    } on ProviderNotFoundException {
      return null;
    }
  }

  void _startInteractions(BilibiliVideoDetail detail) {
    _interactions?.dispose();
    _interactions = null;
    final actions = _resolveActions();
    if (actions == null) return;
    final interactions = BilibiliVideoInteractions(
      actions: actions,
      detail: detail,
    )..addListener(_rebuild);
    _interactions = interactions;
    unawaited(interactions.load());
  }

  int get _partCount {
    final parts = _detail?.parts.length ?? 0;
    return parts < 1 ? 1 : parts;
  }

  Future<void> _watch(
    String bvid, {
    int? page,
    Duration? startAt,
    BilibiliWatchPreview? preview,
  }) {
    final watch = widget.onWatchVideo ?? _watchInPlace;
    return watch(
      context,
      bvid: bvid,
      page: page,
      startAt: startAt,
      preview: preview,
    );
  }

  Future<void> _download() async {
    await openBilibiliVideoDownload(
      context,
      bvid: widget.bvid,
      page: widget.page,
      partCount: _partCount,
    );
  }

  Future<void> _openTarget(BilibiliLinkTarget target) async {
    if (_openingLink) return;
    _openingLink = true;
    try {
      var resolved = target;
      if (target.needsResolve) {
        final result = await _api.resolveShortLink(target.shortLink!);
        final next = result.target;
        if (next == null || !next.isVideo) {
          if (next != null ||
              result.failure == BilibiliShortLinkFailure.noVideo) {
            await _launchExternal(target.shortLink!);
          } else {
            AppToast.show(result.message!, type: AppToastType.error);
          }
          return;
        }
        resolved = next;
      }
      var bvid = resolved.bvid;
      final aid = resolved.aid;
      if (bvid == null && aid != null) {
        bvid = (await _api.fetchVideoDetail(aid: aid)).bvid;
      }
      if (!mounted || bvid == null || bvid.isEmpty) return;
      if (bvid == widget.bvid && resolved.pageOrFirst == widget.page) {
        return;
      }
      await _watch(
        bvid,
        page: resolved.page ?? (bvid == widget.bvid ? null : 1),
        startAt: resolved.startAt,
      );
    } on BilibiliPublicApiException catch (e) {
      AppToast.show(e.message, type: AppToastType.error);
    } finally {
      _openingLink = false;
    }
  }

  Future<void> _openDescriptionLink(BilibiliDescriptionSegment segment) async {
    switch (segment.kind) {
      case BilibiliDescriptionSegmentKind.text:
        return;
      case BilibiliDescriptionSegmentKind.bvid:
      case BilibiliDescriptionSegmentKind.aid:
        final target = parseBilibiliLink(segment.text);
        if (target != null && target.isVideo) await _openTarget(target);
        return;
      case BilibiliDescriptionSegmentKind.url:
        final target = parseBilibiliLink(segment.text);
        if (target != null && target.isVideo) {
          await _openTarget(target);
          return;
        }
        final uri = Uri.tryParse(segment.text);
        if (uri != null) await _launchExternal(uri);
    }
  }

  Future<void> _launchExternal(Uri uri) async {
    if (uri.scheme != 'https' && uri.scheme != 'http') return;
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) AppToast.show('无法打开该链接', type: AppToastType.error);
    } catch (_) {
      AppToast.show('无法打开该链接', type: AppToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('bilibili-player-panel'),
      color: AppTokens.bgBase,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(),
          const Divider(height: 1, thickness: 1, color: AppTokens.bgCard),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
      child: Row(
        children: [
          const Icon(
            Icons.smart_display_outlined,
            size: 18,
            color: AppTokens.brandBilibili,
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '哔哩哔哩',
              style: TextStyle(
                color: AppTokens.text1,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (widget.onCollapse != null)
            IconButton(
              key: const ValueKey('bilibili-panel-collapse'),
              tooltip: '收起',
              icon: const Icon(Icons.close, size: 18, color: AppTokens.text2),
              onPressed: widget.onCollapse,
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final detail = _detail;
    if (detail == null) return _buildWithoutDetail();
    return ListView(
      key: const ValueKey('bilibili-panel-detail'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
      children: [
        SelectableText(
          detail.title,
          style: const TextStyle(
            color: AppTokens.text1,
            fontSize: 15,
            fontWeight: FontWeight.w600,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 10),
        _buildOwner(detail),
        const SizedBox(height: 10),
        _buildStats(detail),
        if (_interactions case final interactions?) ...[
          const SizedBox(height: 12),
          BilibiliVideoInteractionBar(
            interactions: interactions,
            readOnly: _settings.bilibiliAccountReadOnly,
            onReadOnlyTap: () => unawaited(openBilibiliSettings(context)),
          ),
        ],
        const SizedBox(height: 14),
        _buildActions(),
        if (detail.parts.length > 1 && widget.onOpenEpisodes != null) ...[
          const SizedBox(height: 14),
          _buildEpisodesEntry(detail),
        ],
        if (detail.season != null && detail.season!.episodes.isNotEmpty) ...[
          const SizedBox(height: 18),
          _buildSeason(detail),
        ],
        if (detail.tags.isNotEmpty) ...[
          const SizedBox(height: 18),
          _buildTags(detail),
        ],
        const SizedBox(height: 18),
        _sectionTitle('简介'),
        const SizedBox(height: 8),
        BilibiliDescriptionText(
          text: detail.description,
          onLinkTap: _openDescriptionLink,
        ),
      ],
    );
  }

  /// Before the detail is there: what the card knows, then a short loading
  /// line or, after a failure, a retry.
  Widget _buildWithoutDetail() {
    final title = widget.fallbackTitle.trim();
    return ListView(
      key: const ValueKey('bilibili-panel-pending'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
      children: [
        if (title.isNotEmpty) ...[
          Text(
            title,
            style: const TextStyle(
              color: AppTokens.text1,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (_failed)
          Row(
            key: const ValueKey('bilibili-panel-failed'),
            children: [
              const Icon(
                Icons.cloud_off_outlined,
                size: 16,
                color: AppTokens.text3,
              ),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  '详情暂时加载不了',
                  style: TextStyle(color: AppTokens.text2, fontSize: 13),
                ),
              ),
              TextButton(
                key: const ValueKey('bilibili-panel-retry'),
                onPressed: () => unawaited(_load()),
                child: const Text('重试'),
              ),
            ],
          )
        else
          const Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppTokens.brandBilibili,
                ),
              ),
              SizedBox(width: 8),
              Text(
                '正在加载详情…',
                style: TextStyle(color: AppTokens.text3, fontSize: 13),
              ),
            ],
          ),
      ],
    );
  }

  Widget _sectionTitle(String text) => Text(
    text,
    style: const TextStyle(
      color: AppTokens.text1,
      fontSize: 14,
      fontWeight: FontWeight.w600,
    ),
  );

  Widget _buildOwner(BilibiliVideoDetail detail) {
    final owner = detail.owner;
    return InkWell(
      key: const ValueKey('bilibili-panel-owner'),
      borderRadius: BorderRadius.circular(8),
      onTap: owner.mid > 0
          ? () => openBilibiliUploader(
              context,
              mid: owner.mid,
              name: owner.name,
              api: _api,
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            BilibiliAvatar(url: owner.avatarUrl, size: 32),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    owner.name.isEmpty ? '未知 UP 主' : owner.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTokens.brandBilibili,
                      fontSize: 13,
                    ),
                  ),
                  if (detail.publishedAt != null)
                    Text(
                      formatBilibiliDate(detail.publishedAt),
                      style: const TextStyle(
                        color: AppTokens.text3,
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ),
            if (_interactions case final interactions?
                when interactions.hasOwner) ...[
              const SizedBox(width: 8),
              BilibiliFollowButton(interactions: interactions),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStats(BilibiliVideoDetail detail) {
    final stat = detail.stat;
    final interactions = _interactions;
    final items = <(IconData, String, int)>[
      (Icons.play_circle_outline, '播放', stat.view),
      (Icons.subtitles_outlined, '弹幕', stat.danmaku),
      (Icons.thumb_up_alt_outlined, '点赞', interactions?.likeCount ?? stat.like),
      (
        Icons.monetization_on_outlined,
        '投币',
        interactions?.coinCount ?? stat.coin,
      ),
      (Icons.star_border, '收藏', interactions?.favoriteCount ?? stat.favorite),
      (Icons.chat_bubble_outline, '评论', stat.reply),
    ];
    return Wrap(
      key: const ValueKey('bilibili-panel-stats'),
      spacing: 12,
      runSpacing: 6,
      children: [
        for (final (icon, label, value) in items)
          Tooltip(
            message: label,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: AppTokens.text2),
                const SizedBox(width: 3),
                Text(
                  formatBilibiliCount(value),
                  style: const TextStyle(color: AppTokens.text2, fontSize: 12),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildActions() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        BilibiliImportButtons(bvid: widget.bvid, page: widget.page),
        OutlinedButton.icon(
          key: const ValueKey('bilibili-panel-download'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppTokens.text1,
            visualDensity: VisualDensity.compact,
          ),
          onPressed: _download,
          icon: const Icon(Icons.download_outlined, size: 16),
          label: const Text('下载'),
        ),
      ],
    );
  }

  Widget _buildEpisodesEntry(BilibiliVideoDetail detail) {
    String current = '';
    for (final part in detail.parts) {
      if (part.page == widget.page) current = 'P${part.page} ${part.title}';
    }
    return Material(
      color: AppTokens.bgCard,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        key: const ValueKey('bilibili-panel-episodes'),
        dense: true,
        textColor: AppTokens.text1,
        iconColor: AppTokens.text2,
        leading: const Icon(Icons.playlist_play, size: 20),
        title: Text('选集（${detail.parts.length}）'),
        subtitle: current.isEmpty
            ? null
            : Text(
                current,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppTokens.text3, fontSize: 12),
              ),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: widget.onOpenEpisodes,
      ),
    );
  }

  Widget _buildSeason(BilibiliVideoDetail detail) {
    final season = detail.season!;
    const collapsedCount = 20;
    final episodes =
        _showAllEpisodes || season.episodes.length <= collapsedCount
        ? season.episodes
        : season.episodes.take(collapsedCount).toList();
    return Column(
      key: const ValueKey('bilibili-panel-season'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('合集 · ${season.title}（${season.episodes.length}）'),
        const SizedBox(height: 8),
        Material(
          color: AppTokens.bgCard,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (final (index, ep) in episodes.indexed)
                ListTile(
                  key: ValueKey('bilibili-panel-season-${ep.bvid}'),
                  dense: true,
                  selected: ep.bvid == detail.bvid,
                  selectedColor: AppTokens.brandBilibili,
                  textColor: AppTokens.text1,
                  onTap: ep.bvid == detail.bvid
                      ? null
                      : () => unawaited(
                          _watch(
                            ep.bvid,
                            page: 1,
                            preview: BilibiliWatchPreview(
                              title: ep.title,
                              coverUrl: ep.coverUrl,
                            ),
                          ),
                        ),
                  leading: Text(
                    '${index + 1}',
                    style: const TextStyle(
                      color: AppTokens.text3,
                      fontSize: 12,
                    ),
                  ),
                  title: Text(
                    ep.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                  trailing: ep.durationSeconds > 0
                      ? Text(
                          formatBilibiliDuration(ep.durationSeconds),
                          style: const TextStyle(
                            color: AppTokens.text3,
                            fontSize: 12,
                          ),
                        )
                      : null,
                ),
              if (episodes.length < season.episodes.length)
                TextButton(
                  onPressed: () => setState(() => _showAllEpisodes = true),
                  child: Text('展开全部 ${season.episodes.length} 个'),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTags(BilibiliVideoDetail detail) {
    return Wrap(
      key: const ValueKey('bilibili-panel-tags'),
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final tag in detail.tags)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppTokens.bgCard,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              tag,
              style: const TextStyle(color: AppTokens.text2, fontSize: 11),
            ),
          ),
      ],
    );
  }
}
