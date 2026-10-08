import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/bilibili_browse_models.dart';
import 'package:video_player_app/screens/bilibili/bilibili_video_detail_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/utils/bilibili_image_url.dart';
import 'package:video_player_app/utils/bilibili_text.dart';
import 'package:video_player_app/utils/bilibili_url_parser.dart';
import 'package:video_player_app/widgets/bilibili_cover_image.dart';
import 'package:video_player_app/widgets/bilibili_login_dialogs.dart';

/// Fourth root page: Bilibili search with video/user results.
///
/// Nothing is requested until the user searches; the login avatar is read
/// the first time the page becomes active.
class BilibiliHomePage extends StatefulWidget {
  const BilibiliHomePage({
    super.key,
    required this.isActive,
    this.api,
    this.bottomPadding = 0,
  });

  final bool isActive;
  final BilibiliPublicApiService? api;
  final double bottomPadding;

  @override
  State<BilibiliHomePage> createState() => _BilibiliHomePageState();
}

class _SearchResults<T> {
  final List<T> items = <T>[];
  int page = 0;
  bool hasMore = false;
  bool loading = false;
  String? error;
  bool loadedOnce = false;
  int token = 0;

  void reset() {
    items.clear();
    page = 0;
    hasMore = false;
    loading = false;
    error = null;
    loadedOnce = false;
    token++;
  }
}

class _BilibiliHomePageState extends State<BilibiliHomePage> {
  late final BilibiliPublicApiService _api =
      widget.api ?? BilibiliPublicApiService();
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final ScrollController _videoScroll = ScrollController();
  final ScrollController _userScroll = ScrollController();
  final _SearchResults<BilibiliSearchVideo> _videos = _SearchResults();
  final _SearchResults<BilibiliSearchUser> _users = _SearchResults();

  Timer? _suggestDebounce;
  List<String> _suggestions = const <String>[];
  int _suggestToken = 0;
  String _keyword = '';
  int _tab = 0;
  BilibiliVideoSearchFilter _filter = const BilibiliVideoSearchFilter();
  bool _openingTarget = false;

  bool _accountChecked = false;
  String? _avatarUrl;
  bool _loggedIn = false;

  @override
  void initState() {
    super.initState();
    _videoScroll.addListener(() => _maybeLoadMore(0));
    _userScroll.addListener(() => _maybeLoadMore(1));
    _inputFocus.addListener(_handleFocusChange);
    if (widget.isActive) _scheduleAccountCheck();
  }

  @override
  void didUpdateWidget(covariant BilibiliHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) _scheduleAccountCheck();
    if (!widget.isActive && oldWidget.isActive) {
      _inputFocus.unfocus();
    }
  }

  @override
  void dispose() {
    _suggestDebounce?.cancel();
    _input.dispose();
    _inputFocus.dispose();
    _videoScroll.dispose();
    _userScroll.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- account

  void _scheduleAccountCheck() {
    if (_accountChecked) return;
    _accountChecked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refreshAccount());
    });
  }

  BilibiliDownloadService? _downloadService() {
    try {
      return context.read<BilibiliDownloadService>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  Future<void> _refreshAccount() async {
    final service = _downloadService();
    if (service == null) return;
    try {
      await service.apiService.init();
      final state = await service.apiService.fetchLoginState();
      if (!mounted) return;
      final account = state.account;
      setState(() {
        _loggedIn =
            state.status == BilibiliLoginStatus.loggedIn ||
            (state.status == BilibiliLoginStatus.networkError &&
                account != null);
        _avatarUrl = _loggedIn ? bilibiliAvatarUrl(account?.avatarUrl) : null;
      });
    } catch (_) {
      // The avatar is decorative; the dialog shows the real state.
    }
  }

  Future<void> _openAccount() async {
    if (_downloadService() == null) return;
    _inputFocus.unfocus();
    await showBilibiliLoginDialog(context);
    if (mounted) await _refreshAccount();
  }

  // ------------------------------------------------------------ suggestions

  void _handleFocusChange() {
    if (!_inputFocus.hasFocus && _suggestions.isNotEmpty) {
      // Let a tap on a suggestion land before the list disappears.
      Future<void>.delayed(const Duration(milliseconds: 150), () {
        if (mounted && !_inputFocus.hasFocus) {
          setState(() => _suggestions = const <String>[]);
        }
      });
    }
  }

  void _handleInputChanged(String value) {
    _suggestDebounce?.cancel();
    final token = ++_suggestToken;
    final text = value.trim();
    if (text.isEmpty || (parseBilibiliLink(text)?.isVideo ?? false)) {
      if (_suggestions.isNotEmpty) {
        setState(() => _suggestions = const <String>[]);
      } else {
        setState(() {});
      }
      return;
    }
    setState(() {});
    _suggestDebounce = Timer(const Duration(milliseconds: 300), () async {
      final result = await _api.suggestKeywords(text);
      if (!mounted || token != _suggestToken || !_inputFocus.hasFocus) return;
      setState(() => _suggestions = result);
    });
  }

  void _clearInput() {
    _input.clear();
    _suggestToken++;
    setState(() => _suggestions = const <String>[]);
    _inputFocus.requestFocus();
  }

  // ----------------------------------------------------------------- search

  Future<void> _submit(String raw) async {
    final text = raw.trim();
    _suggestDebounce?.cancel();
    _suggestToken++;
    setState(() => _suggestions = const <String>[]);
    if (text.isEmpty) return;
    _inputFocus.unfocus();

    final target = parseBilibiliLink(text);
    if (target != null && target.isVideo) {
      await _openTarget(target);
      return;
    }
    setState(() {
      _keyword = text;
      _videos.reset();
      _users.reset();
    });
    _jumpToTop();
    unawaited(_load(_tab));
  }

  void _jumpToTop() {
    for (final controller in [_videoScroll, _userScroll]) {
      if (controller.hasClients) controller.jumpTo(0);
    }
  }

  Future<void> _openTarget(BilibiliLinkTarget target) async {
    if (_openingTarget) return;
    var resolved = target;
    if (target.needsResolve) {
      _openingTarget = true;
      final handle = AppToast.show('正在解析链接…');
      try {
        final result = await _api.resolveShortLink(target.shortLink!);
        final next = result.target;
        if (next == null || !next.isVideo) {
          AppToast.show(
            result.message ?? BilibiliShortLinkFailure.noVideo.message,
            type: AppToastType.error,
          );
          return;
        }
        resolved = next;
      } finally {
        _openingTarget = false;
        handle.dismiss();
      }
    }
    if (!mounted) return;
    await openBilibiliVideoDetail(
      context,
      bvid: resolved.bvid,
      aid: resolved.aid,
      initialPage: resolved.pageOrFirst,
      api: _api,
    );
  }

  _SearchResults<Object?> _resultsFor(int tab) =>
      (tab == 0 ? _videos : _users) as _SearchResults<Object?>;

  Future<void> _load(int tab) async {
    final results = tab == 0 ? _videos : _users;
    if (_keyword.isEmpty || results.loading) return;
    if (results.loadedOnce && !results.hasMore) return;
    final token = results.token;
    final page = results.page + 1;
    setState(() {
      results.loading = true;
      results.error = null;
    });
    try {
      if (tab == 0) {
        final result = await _api.searchVideos(
          _keyword,
          page: page,
          filter: _filter,
        );
        if (!mounted || token != _videos.token) return;
        setState(() {
          final seen = _videos.items.map((v) => v.bvid).toSet();
          _videos.items.addAll(result.items.where((v) => seen.add(v.bvid)));
          _applyPage(_videos, result.page, result.hasMore);
        });
      } else {
        final result = await _api.searchUsers(_keyword, page: page);
        if (!mounted || token != _users.token) return;
        setState(() {
          final seen = _users.items.map((u) => u.mid).toSet();
          _users.items.addAll(result.items.where((u) => seen.add(u.mid)));
          _applyPage(_users, result.page, result.hasMore);
        });
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => _fillViewport(tab));
    } on BilibiliPublicApiException catch (e) {
      if (!mounted || token != results.token) return;
      setState(() {
        results.loading = false;
        results.error = e.message;
      });
    }
  }

  void _applyPage(_SearchResults<dynamic> results, int page, bool hasMore) {
    results
      ..page = page
      ..hasMore = hasMore
      ..loading = false
      ..loadedOnce = true;
  }

  /// A short first page cannot be scrolled, so keep loading until it can.
  void _fillViewport(int tab) {
    if (!mounted || tab != _tab) return;
    final controller = tab == 0 ? _videoScroll : _userScroll;
    if (!controller.hasClients) return;
    if (controller.position.maxScrollExtent <= 0) _maybeLoadMore(tab);
  }

  void _maybeLoadMore(int tab) {
    final controller = tab == 0 ? _videoScroll : _userScroll;
    final results = _resultsFor(tab);
    if (!controller.hasClients || results.loading || !results.hasMore) return;
    if (results.error != null) return;
    if (controller.position.extentAfter < 600) unawaited(_load(tab));
  }

  void _selectTab(int tab) {
    if (tab == _tab) return;
    setState(() => _tab = tab);
    final results = _resultsFor(tab);
    if (_keyword.isNotEmpty && !results.loadedOnce && !results.loading) {
      unawaited(_load(tab));
    }
  }

  void _updateFilter(BilibiliVideoSearchFilter next) {
    if (next == _filter) return;
    setState(() {
      _filter = next;
      _videos.reset();
    });
    if (_videoScroll.hasClients) _videoScroll.jumpTo(0);
    if (_keyword.isNotEmpty) unawaited(_load(0));
  }

  // --------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTokens.bgBase,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSearchBar(),
          _buildTabs(),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: IndexedStack(
                    index: _tab,
                    children: [
                      // The hidden tab must not keep a spinner ticking.
                      TickerMode(enabled: _tab == 0, child: _buildVideoTab()),
                      TickerMode(enabled: _tab == 1, child: _buildUserTab()),
                    ],
                  ),
                ),
                if (_suggestions.isNotEmpty && _inputFocus.hasFocus)
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 0,
                    child: _buildSuggestions(),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              focusNode: _inputFocus,
              textInputAction: TextInputAction.search,
              onChanged: _handleInputChanged,
              onSubmitted: _submit,
              style: const TextStyle(color: AppTokens.text1, fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: AppTokens.bgCard,
                hintText: '搜索 B 站视频、UP 主，或粘贴 BV 号/链接',
                hintStyle: const TextStyle(
                  color: AppTokens.text3,
                  fontSize: 14,
                ),
                prefixIcon: const Icon(
                  Icons.search,
                  size: 20,
                  color: AppTokens.text2,
                ),
                suffixIcon: _input.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空',
                        icon: const Icon(
                          Icons.close,
                          size: 18,
                          color: AppTokens.text2,
                        ),
                        onPressed: _clearInput,
                      ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: _loggedIn ? 'B 站账号' : '登录 B 站',
            onPressed: _openAccount,
            icon: _avatarUrl == null
                ? const Icon(
                    Icons.account_circle_outlined,
                    size: 30,
                    color: AppTokens.text2,
                  )
                : BilibiliAvatar(url: _avatarUrl, size: 30),
          ),
        ],
      ),
    );
  }

  Widget _buildTabs() {
    Widget tab(int index, String label) {
      final selected = _tab == index;
      return InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _selectTab(index),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: selected ? AppTokens.text1 : AppTokens.text2,
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                width: 18,
                height: 2,
                decoration: BoxDecoration(
                  color: selected
                      ? AppTokens.brandBilibili
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(children: [tab(0, '视频'), tab(1, '用户')]),
    );
  }

  Widget _buildSuggestions() {
    return Material(
      color: AppTokens.bgOverlay,
      elevation: 6,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final value in _suggestions)
            InkWell(
              onTap: () {
                _input.text = value;
                _input.selection = TextSelection.collapsed(
                  offset: value.length,
                );
                unawaited(_submit(value));
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.search, size: 16, color: AppTokens.text3),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTokens.text1,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    Widget menu<T>({
      required String label,
      required T value,
      required List<T> values,
      required String Function(T) labelOf,
      required ValueChanged<T> onSelected,
    }) {
      return PopupMenuButton<T>(
        tooltip: label,
        initialValue: value,
        color: AppTokens.bgOverlay,
        onSelected: onSelected,
        itemBuilder: (_) => [
          for (final item in values)
            PopupMenuItem<T>(
              value: item,
              child: Text(
                labelOf(item),
                style: TextStyle(
                  color: item == value
                      ? AppTokens.brandBilibili
                      : AppTokens.text1,
                  fontSize: 14,
                ),
              ),
            ),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: AppTokens.bgCard,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                labelOf(value),
                style: const TextStyle(color: AppTokens.text1, fontSize: 12),
              ),
              const Icon(
                Icons.arrow_drop_down,
                size: 16,
                color: AppTokens.text2,
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          menu<BilibiliVideoSearchOrder>(
            label: '排序',
            value: _filter.order,
            values: BilibiliVideoSearchOrder.values,
            labelOf: (v) => v.label,
            onSelected: (v) => _updateFilter(_filter.copyWith(order: v)),
          ),
          menu<BilibiliVideoDurationFilter>(
            label: '时长',
            value: _filter.duration,
            values: BilibiliVideoDurationFilter.values,
            labelOf: (v) => v.label,
            onSelected: (v) => _updateFilter(_filter.copyWith(duration: v)),
          ),
          menu<BilibiliPublishedFilter>(
            label: '发布时间',
            value: _filter.published,
            values: BilibiliPublishedFilter.values,
            labelOf: (v) => v.label,
            onSelected: (v) => _updateFilter(_filter.copyWith(published: v)),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildFilterBar(),
        Expanded(
          child: _buildResultList<BilibiliSearchVideo>(
            results: _videos,
            controller: _videoScroll,
            tab: 0,
            itemBuilder: _buildVideoTile,
          ),
        ),
      ],
    );
  }

  Widget _buildUserTab() {
    return _buildResultList<BilibiliSearchUser>(
      results: _users,
      controller: _userScroll,
      tab: 1,
      itemBuilder: _buildUserTile,
    );
  }

  Widget _buildResultList<T>({
    required _SearchResults<T> results,
    required ScrollController controller,
    required int tab,
    required Widget Function(T item) itemBuilder,
  }) {
    if (_keyword.isEmpty) {
      return _buildHint(
        Icons.travel_explore,
        '输入关键词搜索 B 站内容',
        '也可以直接粘贴 BV 号或视频链接打开详情',
      );
    }
    if (results.items.isEmpty) {
      if (results.loading || !results.loadedOnce && results.error == null) {
        return const Center(
          child: CircularProgressIndicator(color: AppTokens.brandBilibili),
        );
      }
      if (results.error != null) {
        return _buildHint(
          Icons.cloud_off_outlined,
          results.error!,
          '',
          action: TextButton(
            onPressed: () => _load(tab),
            child: const Text('重试'),
          ),
        );
      }
      return _buildHint(Icons.search_off, '没有找到相关结果', '换个关键词试试');
    }
    return ListView.builder(
      controller: controller,
      padding: EdgeInsets.only(bottom: 16 + widget.bottomPadding),
      itemCount: results.items.length + 1,
      itemBuilder: (context, index) {
        if (index < results.items.length) {
          return itemBuilder(results.items[index]);
        }
        return _buildFooter(results, tab);
      },
    );
  }

  Widget _buildFooter(_SearchResults<dynamic> results, int tab) {
    final Widget child;
    if (results.loading) {
      child = const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: AppTokens.brandBilibili,
        ),
      );
    } else if (results.error != null) {
      child = TextButton(
        onPressed: () => _load(tab),
        child: Text('${results.error}，点此重试'),
      );
    } else if (!results.hasMore) {
      child = Text(
        results.page >= kBilibiliSearchMaxPages ? '最多显示 50 页结果' : '没有更多了',
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

  Widget _buildHint(
    IconData icon,
    String title,
    String subtitle, {
    Widget? action,
  }) {
    return Center(
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
              style: const TextStyle(color: AppTokens.text1, fontSize: 14),
            ),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTokens.text3, fontSize: 12),
              ),
            ],
            ?action,
          ],
        ),
      ),
    );
  }

  Widget _buildVideoTile(BilibiliSearchVideo video) {
    final meta = <String>[
      if (video.playCount > 0) '${formatBilibiliCount(video.playCount)} 播放',
      if (video.publishedAt != null) formatBilibiliDate(video.publishedAt),
    ].join(' · ');
    return InkWell(
      onTap: () =>
          openBilibiliVideoDetail(context, bvid: video.bvid, api: _api),
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
                    child: BilibiliCoverImage(
                      url: bilibiliCoverThumbnailUrl(video.coverUrl),
                    ),
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
                    Text(
                      video.author.isEmpty ? '未知 UP 主' : video.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTokens.text2,
                        fontSize: 12,
                      ),
                    ),
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

  Widget _buildUserTile(BilibiliSearchUser user) {
    final meta = <String>[
      if (user.level > 0) 'Lv${user.level}',
      '${formatBilibiliCount(user.fans)} 粉丝',
      '${formatBilibiliCount(user.videos)} 个视频',
    ].join(' · ');
    final subtitle = user.officialDesc.isNotEmpty
        ? user.officialDesc
        : user.sign;
    return InkWell(
      onTap: () => AppToast.show('UP 主主页将在后续版本提供'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            BilibiliAvatar(url: user.avatarUrl, size: 48),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTokens.text1,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    meta,
                    style: const TextStyle(
                      color: AppTokens.text3,
                      fontSize: 11,
                    ),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTokens.text2,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
