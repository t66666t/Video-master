import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player_app/models/bilibili_browse_models.dart';
import 'package:video_player_app/screens/bilibili/bilibili_card_actions.dart';
import 'package:video_player_app/screens/bilibili/bilibili_settings_screen.dart';
import 'package:video_player_app/screens/bilibili/bilibili_video_interactions.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_video_actions.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/utils/bilibili_description_links.dart';
import 'package:video_player_app/utils/bilibili_text.dart';
import 'package:video_player_app/utils/bilibili_url_parser.dart';
import 'package:video_player_app/widgets/bilibili_cover_image.dart';

/// Opens the in-app video detail page for a BV id or av number.
Future<void> openBilibiliVideoDetail(
  BuildContext context, {
  String? bvid,
  int? aid,
  int initialPage = 1,
  BilibiliPublicApiService? api,
  bool replace = false,
}) {
  final route = AppMaterialPageRoute<void>(
    builder: (_) => BilibiliVideoDetailScreen(
      bvid: bvid,
      aid: aid,
      initialPage: initialPage,
      api: api,
    ),
  );
  final navigator = Navigator.of(context);
  return replace ? navigator.pushReplacement(route) : navigator.push(route);
}

class BilibiliVideoDetailScreen extends StatefulWidget {
  const BilibiliVideoDetailScreen({
    super.key,
    this.bvid,
    this.aid,
    this.initialPage = 1,
    this.api,
    this.actions,
  });

  final String? bvid;
  final int? aid;
  final int initialPage;
  final BilibiliPublicApiService? api;

  /// Like / coin / favourite / follow; defaults to the app's Bilibili
  /// service. Without either, those buttons are not shown.
  final BilibiliVideoActions? actions;

  @override
  State<BilibiliVideoDetailScreen> createState() =>
      _BilibiliVideoDetailScreenState();
}

class _BilibiliVideoDetailScreenState extends State<BilibiliVideoDetailScreen> {
  late final BilibiliPublicApiService _api =
      widget.api ?? BilibiliPublicApiService();
  BilibiliVideoDetail? _detail;
  String? _error;
  bool _loading = true;
  int _selectedPage = 1;
  bool _showAllEpisodes = false;
  bool _openingLink = false;
  final SettingsService _settings = SettingsService();
  BilibiliVideoInteractions? _interactions;

  @override
  void initState() {
    super.initState();
    _selectedPage = widget.initialPage < 1 ? 1 : widget.initialPage;
    _settings.addListener(_rebuild);
    unawaited(_load());
  }

  @override
  void dispose() {
    _settings.removeListener(_rebuild);
    _interactions?.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
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

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await _api.fetchVideoDetail(
        bvid: widget.bvid,
        aid: widget.aid,
      );
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
        final maxPage = detail.parts.isEmpty ? 1 : detail.parts.length;
        if (_selectedPage > maxPage) _selectedPage = 1;
      });
      _startInteractions(detail);
    } on BilibiliPublicApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  int get _partCount {
    final parts = _detail?.parts.length ?? 0;
    return parts < 1 ? 1 : parts;
  }

  Future<void> _play() async {
    final bvid = _detail?.bvid;
    if (bvid == null || bvid.isEmpty) return;
    await playBilibiliVideoAsCard(context, bvid: bvid, page: _selectedPage);
  }

  Future<void> _importAsCard() async {
    final bvid = _detail?.bvid;
    if (bvid == null || bvid.isEmpty) return;
    await importBilibiliVideoAsCards(
      context,
      bvid: bvid,
      page: _selectedPage,
      partCount: _partCount,
    );
  }

  Future<void> _download() async {
    final bvid = _detail?.bvid;
    if (bvid == null || bvid.isEmpty) return;
    await openBilibiliVideoDownload(
      context,
      bvid: bvid,
      page: _selectedPage,
      partCount: _partCount,
    );
  }

  Future<void> _openTarget(BilibiliLinkTarget target) async {
    if (_openingLink) return;
    var resolved = target;
    if (target.needsResolve) {
      _openingLink = true;
      try {
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
      } finally {
        _openingLink = false;
      }
    }
    if (!mounted) return;
    if (resolved.bvid != null && resolved.bvid == _detail?.bvid) {
      _selectPage(resolved.pageOrFirst);
      return;
    }
    await openBilibiliVideoDetail(
      context,
      bvid: resolved.bvid,
      aid: resolved.aid,
      initialPage: resolved.pageOrFirst,
      api: _api,
    );
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

  void _selectPage(int page) {
    final parts = _detail?.parts ?? const <BilibiliVideoPart>[];
    if (page < 1 || (parts.isNotEmpty && page > parts.length)) return;
    setState(() => _selectedPage = page);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTokens.bgBase,
      appBar: AppBar(
        backgroundColor: AppTokens.bgBase,
        foregroundColor: AppTokens.text1,
        elevation: 0,
        title: const Text('视频详情', style: TextStyle(fontSize: 16)),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final detail = _detail;
    if (_loading && detail == null) {
      return const Center(
        child: CircularProgressIndicator(color: AppTokens.brandBilibili),
      );
    }
    if (detail == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.cloud_off_outlined,
                size: 40,
                color: AppTokens.text3,
              ),
              const SizedBox(height: 12),
              Text(
                _error ?? '视频详情加载失败',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTokens.text1, fontSize: 14),
              ),
              const SizedBox(height: 8),
              TextButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            AspectRatio(
              aspectRatio: 16 / 10,
              child: BilibiliCoverImage(url: detail.coverUrl, borderRadius: 10),
            ),
            const SizedBox(height: 14),
            SelectableText(
              detail.title,
              style: const TextStyle(
                color: AppTokens.text1,
                fontSize: 17,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 12),
            _buildOwner(detail),
            const SizedBox(height: 12),
            _buildStats(detail),
            if (_interactions case final interactions?) ...[
              const SizedBox(height: 14),
              BilibiliVideoInteractionBar(
                interactions: interactions,
                readOnly: _settings.bilibiliAccountReadOnly,
                onReadOnlyTap: () => unawaited(openBilibiliSettings(context)),
              ),
            ],
            const SizedBox(height: 16),
            _buildActions(),
            if (detail.parts.length > 1) ...[
              const SizedBox(height: 20),
              _buildParts(detail),
            ],
            if (detail.season != null &&
                detail.season!.episodes.isNotEmpty) ...[
              const SizedBox(height: 20),
              _buildSeason(detail),
            ],
            if (detail.tags.isNotEmpty) ...[
              const SizedBox(height: 20),
              _buildTags(detail),
            ],
            const SizedBox(height: 20),
            _sectionTitle('简介'),
            const SizedBox(height: 8),
            BilibiliDescriptionText(
              text: detail.description,
              onLinkTap: _openDescriptionLink,
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) => Text(
    text,
    style: const TextStyle(
      color: AppTokens.text1,
      fontSize: 15,
      fontWeight: FontWeight.w600,
    ),
  );

  Widget _buildOwner(BilibiliVideoDetail detail) {
    final owner = detail.owner;
    final others = detail.staff
        .where((s) => s.mid != owner.mid && s.name.isNotEmpty)
        .map((s) => s.role.isEmpty ? s.name : '${s.name}（${s.role}）')
        .toList();
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => AppToast.show('UP 主主页将在后续版本提供'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            BilibiliAvatar(url: owner.avatarUrl, size: 36),
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
                      fontSize: 14,
                    ),
                  ),
                  if (others.isNotEmpty)
                    Text(
                      '合作：${others.join('、')}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTokens.text3,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
            if (detail.publishedAt != null)
              Text(
                formatBilibiliDate(detail.publishedAt),
                style: const TextStyle(color: AppTokens.text3, fontSize: 12),
              ),
            if (_interactions case final interactions?
                when interactions.hasOwner) ...[
              const SizedBox(width: 10),
              BilibiliFollowButton(interactions: interactions),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStats(BilibiliVideoDetail detail) {
    final stat = detail.stat;
    // Like / coin / favourite counts follow the user's own actions here.
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
      (Icons.share_outlined, '分享', stat.share),
      (Icons.chat_bubble_outline, '评论', stat.reply),
    ];
    return Wrap(
      spacing: 14,
      runSpacing: 8,
      children: [
        for (final (icon, label, value) in items)
          Tooltip(
            message: label,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: AppTokens.text2),
                const SizedBox(width: 4),
                Text(
                  '${formatBilibiliCount(value)} $label',
                  style: const TextStyle(color: AppTokens.text2, fontSize: 12),
                ),
              ],
            ),
          ),
        if (detail.durationSeconds > 0)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.schedule, size: 15, color: AppTokens.text2),
              const SizedBox(width: 4),
              Text(
                formatBilibiliDuration(detail.durationSeconds),
                style: const TextStyle(color: AppTokens.text2, fontSize: 12),
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildActions() {
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      children: [
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: AppTokens.brandBilibili,
            foregroundColor: Colors.white,
          ),
          onPressed: _play,
          icon: const Icon(Icons.play_arrow, size: 18),
          label: const Text('播放'),
        ),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: AppTokens.text1),
          onPressed: _importAsCard,
          icon: const Icon(Icons.library_add_outlined, size: 18),
          label: const Text('导入为卡片'),
        ),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: AppTokens.text1),
          onPressed: _download,
          icon: const Icon(Icons.download_outlined, size: 18),
          label: const Text('下载'),
        ),
      ],
    );
  }

  Widget _buildParts(BilibiliVideoDetail detail) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('分P（${detail.parts.length}）'),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: Material(
            color: AppTokens.bgCard,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: detail.parts.length,
              itemBuilder: (context, index) {
                final part = detail.parts[index];
                final selected = part.page == _selectedPage;
                return ListTile(
                  dense: true,
                  selected: selected,
                  selectedColor: AppTokens.brandBilibili,
                  textColor: AppTokens.text1,
                  onTap: () => _selectPage(part.page),
                  leading: Text(
                    'P${part.page}',
                    style: TextStyle(
                      color: selected
                          ? AppTokens.brandBilibili
                          : AppTokens.text3,
                      fontSize: 12,
                    ),
                  ),
                  title: Text(
                    part.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                  trailing: part.durationSeconds > 0
                      ? Text(
                          formatBilibiliDuration(part.durationSeconds),
                          style: const TextStyle(
                            color: AppTokens.text3,
                            fontSize: 12,
                          ),
                        )
                      : null,
                );
              },
            ),
          ),
        ),
      ],
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
                  dense: true,
                  selected: ep.bvid == detail.bvid,
                  selectedColor: AppTokens.brandBilibili,
                  textColor: AppTokens.text1,
                  onTap: ep.bvid == detail.bvid
                      ? null
                      : () => openBilibiliVideoDetail(
                          context,
                          bvid: ep.bvid,
                          api: _api,
                          replace: true,
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
                    maxLines: 1,
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
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final tag in detail.tags)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppTokens.bgCard,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              tag,
              style: const TextStyle(color: AppTokens.text2, fontSize: 12),
            ),
          ),
      ],
    );
  }
}

/// Description text whose URLs, BV ids and av numbers are tappable.
class BilibiliDescriptionText extends StatefulWidget {
  const BilibiliDescriptionText({
    super.key,
    required this.text,
    required this.onLinkTap,
  });

  final String text;
  final ValueChanged<BilibiliDescriptionSegment> onLinkTap;

  @override
  State<BilibiliDescriptionText> createState() =>
      _BilibiliDescriptionTextState();
}

class _BilibiliDescriptionTextState extends State<BilibiliDescriptionText> {
  List<BilibiliDescriptionSegment> _segments = const [];
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];

  @override
  void initState() {
    super.initState();
    _rebuildSegments();
  }

  @override
  void didUpdateWidget(covariant BilibiliDescriptionText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _rebuildSegments();
  }

  void _rebuildSegments() {
    _disposeRecognizers();
    _segments = splitBilibiliDescription(widget.text);
    for (final segment in _segments) {
      if (!segment.isLink) continue;
      _recognizers.add(
        TapGestureRecognizer()..onTap = () => widget.onLinkTap(segment),
      );
    }
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.text.trim().isEmpty) {
      return const Text(
        '暂无简介',
        style: TextStyle(color: AppTokens.text3, fontSize: 13),
      );
    }
    var linkIndex = 0;
    return SelectableText.rich(
      TextSpan(
        style: const TextStyle(
          color: AppTokens.text2,
          fontSize: 13,
          height: 1.5,
        ),
        children: [
          for (final segment in _segments)
            if (segment.isLink)
              TextSpan(
                text: segment.text,
                style: const TextStyle(color: AppTokens.accent),
                recognizer: _recognizers[linkIndex++],
              )
            else
              TextSpan(text: segment.text),
        ],
      ),
    );
  }
}
