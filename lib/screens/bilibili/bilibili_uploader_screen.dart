import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player_app/models/bilibili_uploader_models.dart';
import 'package:video_player_app/screens/bilibili/bilibili_card_actions.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_uploader_service.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/utils/bilibili_text.dart';
import 'package:video_player_app/widgets/bilibili_cover_image.dart';

/// Opens the read-only uploader (UP 主) page for [mid].
Future<void> openBilibiliUploader(
  BuildContext context, {
  required int mid,
  String name = '',
  BilibiliPublicApiService? api,
}) async {
  if (mid <= 0) return;
  await Navigator.of(context).push(
    AppMaterialPageRoute<void>(
      builder: (_) =>
          BilibiliUploaderScreen(mid: mid, initialName: name, api: api),
    ),
  );
}

/// Web address of an article (专栏). Only https bilibili.com pages are
/// ever opened from the uploader page.
Uri bilibiliArticleUri(int id) => Uri.https('www.bilibili.com', '/read/cv$id');

bool isOpenableBilibiliWebUri(Uri uri) {
  final host = uri.host.toLowerCase();
  return uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443) &&
      (host == 'bilibili.com' || host.endsWith('.bilibili.com'));
}

typedef BilibiliPageFetcher<T> =
    Future<BilibiliUploaderResult<BilibiliUploaderPage<T>>> Function(int page);

/// Page-by-page loading for an uploader list.
///
/// At most one page request is in flight; scroll-triggered loads are ignored
/// while one runs, after a failure (the user retries by hand) and once the
/// list ended: an empty or short page, the reported total, or page
/// [kBilibiliUploaderMaxPages].
class BilibiliUploaderPager<T> extends ChangeNotifier {
  BilibiliUploaderPager(this._fetch, {required this.keyOf});

  BilibiliPageFetcher<T> _fetch;

  /// Identity used to drop duplicates across pages.
  final Object Function(T item) keyOf;

  final List<T> items = <T>[];
  final Set<Object> _keys = <Object>{};
  int page = 0;
  bool hasMore = true;
  bool loading = false;
  bool loadedOnce = false;

  /// The last failed page, shown with a retry button.
  BilibiliUploaderResult<Object?>? failure;

  int _generation = 0;
  bool _disposed = false;

  bool get reachedPageLimit => page >= kBilibiliUploaderMaxPages;

  /// Called from scrolling: loads the next page only when idle and healthy.
  void loadMoreIfIdle() {
    if (loading || failure != null || !hasMore) return;
    unawaited(loadNext());
  }

  /// Loads the next page (also the retry after a failure).
  Future<void> loadNext() async {
    if (loading || !hasMore || reachedPageLimit) return;
    final generation = _generation;
    final next = page + 1;
    loading = true;
    failure = null;
    _changed();
    final result = await _fetch(next);
    if (_disposed || generation != _generation) return;
    loading = false;
    loadedOnce = true;
    if (result.isSuccess) {
      final data = result.data!;
      for (final item in data.items) {
        if (_keys.add(keyOf(item))) items.add(item);
      }
      page = next;
      hasMore =
          next < kBilibiliUploaderMaxPages &&
          data.items.length >= data.pageSize &&
          (data.total <= 0 || next < data.pageCount);
    } else {
      failure = result.cast<Object?>();
    }
    _changed();
  }

  /// Starts over (new sort or keyword); a page still in flight is dropped.
  void reset([BilibiliPageFetcher<T>? fetch]) {
    _generation++;
    if (fetch != null) _fetch = fetch;
    items.clear();
    _keys.clear();
    page = 0;
    hasMore = true;
    loading = false;
    loadedOnce = false;
    failure = null;
    _changed();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class BilibiliUploaderScreen extends StatefulWidget {
  const BilibiliUploaderScreen({
    super.key,
    required this.mid,
    this.initialName = '',
    this.api,
    this.service,
    this.openExternal,
    this.onWatch,
  });

  final int mid;

  /// Shown until the profile has loaded.
  final String initialName;

  /// Cookie-free client of the uploader requests.
  final BilibiliPublicApiService? api;
  final BilibiliUploaderService? service;

  /// Opens an article page outside the app; defaults to the system browser.
  final Future<bool> Function(Uri uri)? openExternal;

  /// Plays a tapped video; defaults to [watchBilibiliVideo].
  final BilibiliVideoWatcher? onWatch;

  @override
  State<BilibiliUploaderScreen> createState() => _BilibiliUploaderScreenState();
}

class _BilibiliUploaderScreenState extends State<BilibiliUploaderScreen>
    with SingleTickerProviderStateMixin {
  late final BilibiliPublicApiService _api =
      widget.api ?? BilibiliPublicApiService();
  late final BilibiliUploaderService _service =
      widget.service ?? BilibiliUploaderService(api: _api);
  late final TabController _tabs = TabController(length: 3, vsync: this);
  final TextEditingController _keywordController = TextEditingController();

  BilibiliUploaderResult<BilibiliUploaderProfile>? _profile;
  bool _profileLoading = true;
  BilibiliUploaderVideoOrder _order = BilibiliUploaderVideoOrder.latest;
  String _keyword = '';

  late final BilibiliUploaderPager<BilibiliUploaderVideo> _videos =
      BilibiliUploaderPager(_fetchVideos, keyOf: (v) => v.bvid);
  late final BilibiliUploaderPager<BilibiliUploaderArticle> _articles =
      BilibiliUploaderPager(
        (page) => _service.fetchArticles(widget.mid, page: page),
        keyOf: (a) => a.id,
      );
  late final BilibiliUploaderPager<BilibiliUploaderCollection> _collections =
      BilibiliUploaderPager(
        (page) => _service.fetchCollections(widget.mid, page: page),
        keyOf: (c) => '${c.isSeason ? 's' : 'r'}${c.id}',
      );

  @override
  void initState() {
    super.initState();
    _tabs.addListener(_onTabChanged);
    unawaited(_loadProfile());
    unawaited(_videos.loadNext());
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    _keywordController.dispose();
    _videos.dispose();
    _articles.dispose();
    _collections.dispose();
    super.dispose();
  }

  Future<BilibiliUploaderResult<BilibiliUploaderPage<BilibiliUploaderVideo>>>
  _fetchVideos(int page) => _service.fetchVideos(
    widget.mid,
    page: page,
    order: _order,
    keyword: _keyword,
  );

  /// Articles and collections load the first time their tab is shown.
  void _onTabChanged() {
    final pager = switch (_tabs.index) {
      1 => _articles,
      2 => _collections,
      _ => null,
    };
    if (pager != null && !pager.loadedOnce && !pager.loading) {
      unawaited(pager.loadNext());
    }
  }

  Future<void> _loadProfile() async {
    setState(() => _profileLoading = true);
    final result = await _service.fetchProfile(widget.mid);
    if (!mounted) return;
    setState(() {
      _profile = result;
      _profileLoading = false;
    });
  }

  void _setOrder(BilibiliUploaderVideoOrder order) {
    if (order == _order) return;
    setState(() => _order = order);
    _videos.reset();
    unawaited(_videos.loadNext());
  }

  void _search(String value) {
    final keyword = value.trim();
    if (keyword == _keyword) return;
    setState(() => _keyword = keyword);
    _videos.reset();
    unawaited(_videos.loadNext());
  }

  Future<void> _openArticle(BilibiliUploaderArticle article) async {
    final uri = bilibiliArticleUri(article.id);
    if (!isOpenableBilibiliWebUri(uri)) return;
    try {
      final open =
          widget.openExternal ??
          ((Uri u) => launchUrl(u, mode: LaunchMode.externalApplication));
      if (!await open(uri)) {
        AppToast.show('无法打开该专栏', type: AppToastType.error);
      }
    } catch (_) {
      AppToast.show('无法打开该专栏', type: AppToastType.error);
    }
  }

  void _openVideo(BilibiliUploaderVideo video) {
    final watch = widget.onWatch ?? watchBilibiliVideo;
    unawaited(watch(context, bvid: video.bvid));
  }

  void _openCollection(BilibiliUploaderCollection collection) {
    unawaited(
      Navigator.of(context).push(
        AppMaterialPageRoute<void>(
          builder: (_) => BilibiliUploaderCollectionScreen(
            mid: widget.mid,
            collection: collection,
            api: _api,
            service: _service,
            onWatch: widget.onWatch,
          ),
        ),
      ),
    );
  }

  String get _title {
    final name = _profile?.data?.name ?? widget.initialName;
    return name.isEmpty ? 'UP 主' : name;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTokens.bgBase,
      body: NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) => [
          SliverAppBar(
            pinned: true,
            backgroundColor: AppTokens.bgBase,
            surfaceTintColor: Colors.transparent,
            foregroundColor: AppTokens.text1,
            elevation: 0,
            expandedHeight: 228,
            title: Text(_title, style: const TextStyle(fontSize: 16)),
            flexibleSpace: FlexibleSpaceBar(
              collapseMode: CollapseMode.pin,
              background: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    16,
                    kToolbarHeight,
                    16,
                    52,
                  ),
                  child: _buildHeader(),
                ),
              ),
            ),
            bottom: TabBar(
              controller: _tabs,
              labelColor: AppTokens.text1,
              unselectedLabelColor: AppTokens.text2,
              indicatorColor: AppTokens.brandBilibili,
              dividerColor: AppTokens.bgCard,
              tabs: const [
                Tab(text: '投稿'),
                Tab(text: '专栏'),
                Tab(text: '合集'),
              ],
            ),
          ),
        ],
        body: TabBarView(
          controller: _tabs,
          children: [
            _buildVideosTab(),
            _buildArticlesTab(),
            _buildCollectionsTab(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final result = _profile;
    final profile = result?.data;
    if (profile == null) {
      if (_profileLoading) {
        return Row(
          children: [
            const BilibiliAvatar(url: null, size: 64),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                widget.initialName.isEmpty ? '正在加载…' : widget.initialName,
                style: const TextStyle(color: AppTokens.text1, fontSize: 17),
              ),
            ),
          ],
        );
      }
      return Row(
        children: [
          const BilibiliAvatar(url: null, size: 64),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              result?.message.isNotEmpty == true
                  ? result!.message
                  : 'UP 主资料加载失败',
              key: const ValueKey('bilibili-uploader-profile-error'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppTokens.text2, fontSize: 13),
            ),
          ),
          TextButton(
            key: const ValueKey('bilibili-uploader-profile-retry'),
            onPressed: _loadProfile,
            child: const Text('重试'),
          ),
        ],
      );
    }
    final counts = <String>[
      if (profile.following != null)
        '关注 ${formatBilibiliCount(profile.following!)}',
      if (profile.follower != null)
        '粉丝 ${formatBilibiliCount(profile.follower!)}',
      if (profile.archiveCount != null)
        '投稿 ${formatBilibiliCount(profile.archiveCount!)}',
    ];
    final badges = <String>[
      if (profile.level > 0) 'Lv${profile.level}',
      if (profile.officialTitle.isNotEmpty) profile.officialTitle,
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        BilibiliAvatar(url: profile.avatarUrl, size: 64),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                profile.name,
                key: const ValueKey('bilibili-uploader-name'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTokens.text1,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (badges.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  badges.join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTokens.brandBilibili,
                    fontSize: 12,
                  ),
                ),
              ],
              if (counts.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  counts.join('   '),
                  key: const ValueKey('bilibili-uploader-counts'),
                  style: const TextStyle(color: AppTokens.text2, fontSize: 12),
                ),
              ],
              const SizedBox(height: 4),
              Text(
                profile.sign.isEmpty ? '这个 UP 主还没有签名' : profile.sign,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTokens.text3,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------- tabs

  Widget _buildVideosTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final order in BilibiliUploaderVideoOrder.values)
                ChoiceChip(
                  key: ValueKey('bilibili-uploader-order-${order.name}'),
                  label: Text(order.label),
                  selected: _order == order,
                  showCheckmark: false,
                  labelStyle: TextStyle(
                    fontSize: 12,
                    color: _order == order ? AppTokens.text1 : AppTokens.text2,
                  ),
                  selectedColor: AppTokens.brandBilibili.withValues(
                    alpha: 0.22,
                  ),
                  onSelected: (_) => _setOrder(order),
                ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: SizedBox(
                  height: 36,
                  child: TextField(
                    key: const ValueKey('bilibili-uploader-search'),
                    controller: _keywordController,
                    textInputAction: TextInputAction.search,
                    onSubmitted: _search,
                    style: const TextStyle(
                      color: AppTokens.text1,
                      fontSize: 13,
                    ),
                    decoration: InputDecoration(
                      hintText: '搜索 TA 的投稿',
                      hintStyle: const TextStyle(
                        color: AppTokens.text3,
                        fontSize: 13,
                      ),
                      isDense: true,
                      filled: true,
                      fillColor: AppTokens.bgCard,
                      prefixIcon: const Icon(
                        Icons.search,
                        size: 18,
                        color: AppTokens.text3,
                      ),
                      suffixIcon: _keyword.isEmpty
                          ? null
                          : IconButton(
                              tooltip: '清除',
                              icon: const Icon(Icons.close, size: 16),
                              onPressed: () {
                                _keywordController.clear();
                                _search('');
                              },
                            ),
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: BilibiliUploaderPagedList<BilibiliUploaderVideo>(
            key: const PageStorageKey('bilibili-uploader-videos'),
            pager: _videos,
            emptyText: _keyword.isEmpty ? '还没有投稿' : '没有找到相关投稿',
            itemBuilder: (video) =>
                BilibiliUploaderVideoTile(video: video, onTap: _openVideo),
          ),
        ),
      ],
    );
  }

  Widget _buildArticlesTab() {
    return BilibiliUploaderPagedList<BilibiliUploaderArticle>(
      key: const PageStorageKey('bilibili-uploader-articles'),
      pager: _articles,
      emptyText: '还没有专栏',
      itemBuilder: (article) => _ArticleTile(
        article: article,
        onTap: () => unawaited(_openArticle(article)),
      ),
    );
  }

  Widget _buildCollectionsTab() {
    return BilibiliUploaderPagedList<BilibiliUploaderCollection>(
      key: const PageStorageKey('bilibili-uploader-collections'),
      pager: _collections,
      emptyText: '还没有合集',
      itemBuilder: (collection) => _CollectionTile(
        collection: collection,
        onTap: () => _openCollection(collection),
      ),
    );
  }
}

/// Videos of one collection, page by page; a tap plays the video.
class BilibiliUploaderCollectionScreen extends StatefulWidget {
  const BilibiliUploaderCollectionScreen({
    super.key,
    required this.mid,
    required this.collection,
    required this.api,
    required this.service,
    this.onWatch,
  });

  final int mid;
  final BilibiliUploaderCollection collection;
  final BilibiliPublicApiService api;
  final BilibiliUploaderService service;

  /// Plays a tapped video; defaults to [watchBilibiliVideo].
  final BilibiliVideoWatcher? onWatch;

  @override
  State<BilibiliUploaderCollectionScreen> createState() =>
      _BilibiliUploaderCollectionScreenState();
}

class _BilibiliUploaderCollectionScreenState
    extends State<BilibiliUploaderCollectionScreen> {
  late final BilibiliUploaderPager<BilibiliUploaderVideo> _videos =
      BilibiliUploaderPager(
        (page) => widget.service.fetchCollectionVideos(
          widget.mid,
          widget.collection,
          page: page,
        ),
        keyOf: (v) => v.bvid,
      );

  @override
  void initState() {
    super.initState();
    unawaited(_videos.loadNext());
  }

  @override
  void dispose() {
    _videos.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.collection;
    return Scaffold(
      backgroundColor: AppTokens.bgBase,
      appBar: AppBar(
        backgroundColor: AppTokens.bgBase,
        foregroundColor: AppTokens.text1,
        elevation: 0,
        title: Text(
          '${c.isSeason ? '合集' : '系列'} · ${c.title}',
          style: const TextStyle(fontSize: 16),
        ),
      ),
      body: BilibiliUploaderPagedList<BilibiliUploaderVideo>(
        pager: _videos,
        emptyText: '这个${c.isSeason ? '合集' : '系列'}还没有视频',
        itemBuilder: (video) => BilibiliUploaderVideoTile(
          video: video,
          onTap: (v) => unawaited(
            (widget.onWatch ?? watchBilibiliVideo)(context, bvid: v.bvid),
          ),
        ),
      ),
    );
  }
}

/// List bound to a [BilibiliUploaderPager]: first-page spinner, failure
/// message with a retry button, empty state, and loading the next page when
/// scrolled near the end (never while a page is loading or after a failure).
class BilibiliUploaderPagedList<T> extends StatelessWidget {
  const BilibiliUploaderPagedList({
    super.key,
    required this.pager,
    required this.itemBuilder,
    required this.emptyText,
  });

  final BilibiliUploaderPager<T> pager;
  final Widget Function(T item) itemBuilder;
  final String emptyText;

  static const double _loadAheadPixels = 480;

  bool _onScroll(ScrollMetrics metrics) {
    if (metrics.axis == Axis.vertical &&
        metrics.extentAfter < _loadAheadPixels) {
      pager.loadMoreIfIdle();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: pager,
      builder: (context, _) {
        if (pager.items.isEmpty) {
          if (pager.loading || !pager.loadedOnce && pager.failure == null) {
            return const Center(
              child: CircularProgressIndicator(color: AppTokens.brandBilibili),
            );
          }
          final failure = pager.failure;
          if (failure != null) {
            return BilibiliUploaderStateHint(
              icon: _iconFor(failure.status),
              title: failure.message,
              action: TextButton(
                key: const ValueKey('bilibili-uploader-retry'),
                onPressed: pager.loadNext,
                child: const Text('重试'),
              ),
            );
          }
          return BilibiliUploaderStateHint(
            icon: Icons.inbox_outlined,
            title: emptyText,
          );
        }
        return NotificationListener<ScrollMetricsNotification>(
          onNotification: (n) => _onScroll(n.metrics),
          child: NotificationListener<ScrollUpdateNotification>(
            onNotification: (n) => _onScroll(n.metrics),
            child: ListView.builder(
              padding: const EdgeInsets.only(top: 4, bottom: 24),
              itemCount: pager.items.length + 1,
              itemBuilder: (context, index) {
                if (index < pager.items.length) {
                  return itemBuilder(pager.items[index]);
                }
                return _buildFooter();
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildFooter() {
    final Widget child;
    final failure = pager.failure;
    if (pager.loading) {
      child = const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: AppTokens.brandBilibili,
        ),
      );
    } else if (failure != null) {
      child = TextButton(
        key: const ValueKey('bilibili-uploader-retry'),
        onPressed: pager.loadNext,
        child: Text('${failure.message}，点此重试'),
      );
    } else if (!pager.hasMore) {
      child = Text(
        pager.reachedPageLimit ? '最多显示 50 页' : '没有更多了',
        style: const TextStyle(color: AppTokens.text3, fontSize: 12),
      );
    } else {
      child = const SizedBox(height: 20);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(child: child),
    );
  }

  static IconData _iconFor(BilibiliUploaderStatus status) => switch (status) {
    BilibiliUploaderStatus.riskControlled => Icons.shield_outlined,
    BilibiliUploaderStatus.notFound => Icons.person_off_outlined,
    BilibiliUploaderStatus.networkError => Icons.cloud_off_outlined,
    _ => Icons.error_outline,
  };
}

class BilibiliUploaderStateHint extends StatelessWidget {
  const BilibiliUploaderStateHint({
    super.key,
    required this.icon,
    required this.title,
    this.action,
  });

  final IconData icon;
  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    // Stays scrollable so the outer header can still collapse.
    return CustomScrollView(
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 40, color: AppTokens.text3),
                  const SizedBox(height: 12),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppTokens.text1,
                      fontSize: 14,
                    ),
                  ),
                  if (action != null) ...[const SizedBox(height: 8), action!],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class BilibiliUploaderVideoTile extends StatelessWidget {
  const BilibiliUploaderVideoTile({
    super.key,
    required this.video,
    required this.onTap,
  });

  final BilibiliUploaderVideo video;
  final ValueChanged<BilibiliUploaderVideo> onTap;

  @override
  Widget build(BuildContext context) {
    final meta = <String>[
      if (video.playCount > 0) '${formatBilibiliCount(video.playCount)} 播放',
      if (video.publishedAt != null) formatBilibiliDate(video.publishedAt),
    ].join(' · ');
    return InkWell(
      key: ValueKey('bilibili-uploader-video-${video.bvid}'),
      onTap: () => onTap(video),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 128,
              height: 80,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: BilibiliCoverImage(url: video.coverUrl),
                  ),
                  if (video.durationSeconds > 0)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          formatBilibiliDuration(video.durationSeconds),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 80,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      video.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTokens.text1,
                        fontSize: 14,
                        height: 1.3,
                      ),
                    ),
                    const Spacer(),
                    if (meta.isNotEmpty)
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTokens.text3,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArticleTile extends StatelessWidget {
  const _ArticleTile({required this.article, required this.onTap});

  final BilibiliUploaderArticle article;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final meta = <String>[
      if (article.viewCount > 0) '${formatBilibiliCount(article.viewCount)} 阅读',
      if (article.likeCount > 0) '${formatBilibiliCount(article.likeCount)} 点赞',
      if (article.publishedAt != null) formatBilibiliDate(article.publishedAt),
    ].join(' · ');
    return InkWell(
      key: ValueKey('bilibili-uploader-article-${article.id}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    article.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTokens.text1,
                      fontSize: 14,
                      height: 1.3,
                    ),
                  ),
                  if (article.summary.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      article.summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTokens.text2,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      meta,
                      style: const TextStyle(
                        color: AppTokens.text3,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (article.coverUrl != null) ...[
              const SizedBox(width: 10),
              BilibiliCoverImage(
                url: article.coverUrl,
                width: 96,
                height: 60,
                icon: Icons.article_outlined,
              ),
            ],
            const Padding(
              padding: EdgeInsets.only(left: 6, top: 2),
              child: Icon(Icons.open_in_new, size: 14, color: AppTokens.text3),
            ),
          ],
        ),
      ),
    );
  }
}

class _CollectionTile extends StatelessWidget {
  const _CollectionTile({required this.collection, required this.onTap});

  final BilibiliUploaderCollection collection;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final kind = collection.isSeason ? '合集' : '系列';
    return InkWell(
      key: ValueKey(
        'bilibili-uploader-collection-${collection.isSeason ? 's' : 'r'}'
        '${collection.id}',
      ),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            BilibiliCoverImage(
              url: collection.coverUrl,
              width: 128,
              height: 80,
              icon: Icons.video_library_outlined,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    collection.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTokens.text1,
                      fontSize: 14,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$kind · ${collection.videoCount} 个视频',
                    style: const TextStyle(
                      color: AppTokens.text3,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: AppTokens.text3),
          ],
        ),
      ),
    );
  }
}
