import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player_app/models/bilibili_browse_models.dart';
import 'package:video_player_app/screens/bilibili/bilibili_write_feedback.dart';
import 'package:video_player_app/services/bilibili/bilibili_video_actions.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/utils/app_toast.dart';

enum BilibiliVideoAction { like, coin, favorite, follow }

/// Like / coin / favourite / follow state of one video on the detail page.
///
/// With a stored login the four states load separately; a failed one stays
/// null ("unknown") and its button still works. Without a login nothing is
/// requested and every state shows its default; a tap then reaches the write
/// gate, which answers "log in first".
class BilibiliVideoInteractions extends ChangeNotifier {
  BilibiliVideoInteractions({required this.actions, required this.detail})
    : likeCount = detail.stat.like,
      coinCount = detail.stat.coin,
      favoriteCount = detail.stat.favorite;

  final BilibiliVideoActions actions;
  final BilibiliVideoDetail detail;

  bool loggedIn = false;
  bool? liked;
  int? coins;
  bool? favorited;
  bool? following;

  int likeCount;
  int coinCount;
  int favoriteCount;

  /// Actions whose flow (check, dialog, request) is running; more taps on
  /// them are ignored.
  final Set<BilibiliVideoAction> _busy = <BilibiliVideoAction>{};

  /// Actions with a write request in flight; their button shows progress.
  final Set<BilibiliVideoAction> _sending = <BilibiliVideoAction>{};
  bool _disposed = false;

  bool isBusy(BilibiliVideoAction action) => _sending.contains(action);

  Future<T> _send<T>(BilibiliVideoAction action, Future<T> request) async {
    _sending.add(action);
    _changed();
    try {
      return await request;
    } finally {
      _sending.remove(action);
      _changed();
    }
  }

  bool get hasOwner => detail.owner.mid > 0;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    loggedIn = await actions.hasLogin();
    if (_disposed) return;
    if (!loggedIn) {
      liked = false;
      coins = 0;
      favorited = false;
      following = false;
      _changed();
      return;
    }
    liked = null;
    coins = null;
    favorited = null;
    following = null;
    _changed();
    Future<void> read<T>(
      Future<T> Function() fetch,
      void Function(T) set,
    ) async {
      try {
        final value = await fetch();
        if (_disposed) return;
        set(value);
        _changed();
      } catch (_) {
        // Stays unknown; the button still works.
      }
    }

    await Future.wait<void>([
      if (detail.bvid.isNotEmpty) ...[
        read(() => actions.fetchLiked(detail.bvid), (v) => liked = v),
        read(() => actions.fetchCoins(detail.bvid), (v) => coins = v),
      ],
      if (detail.aid > 0)
        read(() => actions.fetchFavorited(detail.aid), (v) => favorited = v),
      if (hasOwner)
        read(
          () => actions.fetchFollowing(detail.owner.mid),
          (v) => following = v,
        ),
    ]);
  }

  /// Ignores taps while the same action is still running.
  Future<void> _run(
    BilibiliVideoAction action,
    Future<void> Function() body,
  ) async {
    if (_busy.contains(action)) return;
    _busy.add(action);
    try {
      await body();
    } finally {
      _busy.remove(action);
      _changed();
    }
  }

  Future<void> toggleLike(BuildContext context) =>
      _run(BilibiliVideoAction.like, () async {
        final target = !(liked ?? false);
        final result = await _send(
          BilibiliVideoAction.like,
          actions.setLiked(aid: detail.aid, liked: target),
        );
        if (result.isSuccess) {
          if (liked != target) likeCount += target ? 1 : -1;
          liked = target;
        }
        if (context.mounted) {
          showBilibiliWriteFeedback(
            context,
            result,
            successMessage: target ? '已点赞' : '已取消点赞',
          );
        }
      });

  Future<void> giveCoins(BuildContext context) =>
      _run(BilibiliVideoAction.coin, () async {
        final blocked = await actions.gate.precheck();
        if (!context.mounted) return;
        if (blocked != null) {
          showBilibiliWriteFeedback(context, blocked);
          return;
        }
        final left = BilibiliVideoActions.coinsLeft(coins);
        if (left == 0) {
          AppToast.show('这个视频已经投过 ${BilibiliVideoActions.maxCoins} 枚硬币了');
          return;
        }
        final choice = await showBilibiliCoinDialog(
          context,
          maxCoins: left,
          canAlsoLike: liked != true,
        );
        if (choice == null) return;
        final result = await _send(
          BilibiliVideoAction.coin,
          actions.addCoins(
            aid: detail.aid,
            count: choice.count,
            alsoLike: choice.alsoLike,
          ),
        );
        if (result.isSuccess) {
          coins = (coins ?? 0) + choice.count;
          coinCount += choice.count;
          if (choice.alsoLike && liked != true) {
            liked = true;
            likeCount += 1;
          }
        }
        if (context.mounted) {
          showBilibiliWriteFeedback(
            context,
            result,
            successMessage: '已投出 ${choice.count} 枚硬币',
          );
        }
      });

  Future<void> editFavorites(BuildContext context) =>
      _run(BilibiliVideoAction.favorite, () async {
        final blocked = await actions.gate.precheck();
        if (!context.mounted) return;
        if (blocked != null) {
          showBilibiliWriteFeedback(context, blocked);
          return;
        }
        final choice = await showBilibiliFavoriteDialog(
          context,
          loadFolders: () => actions.fetchFavoriteFolders(detail.aid),
        );
        if (choice == null) return;
        final result = await _send(
          BilibiliVideoAction.favorite,
          actions.updateFavorites(
            aid: detail.aid,
            before: choice.before,
            after: choice.after,
          ),
        );
        if (result == null) return;
        if (result.isSuccess) {
          final was = choice.before.isNotEmpty;
          final now = choice.after.isNotEmpty;
          if (was != now) favoriteCount += now ? 1 : -1;
          favorited = now;
        }
        if (context.mounted) {
          showBilibiliWriteFeedback(context, result, successMessage: '收藏已更新');
        }
      });

  Future<void> toggleFollow(BuildContext context) =>
      _run(BilibiliVideoAction.follow, () async {
        if (!hasOwner) return;
        final target = !(following ?? false);
        if (!target) {
          final blocked = await actions.gate.precheck();
          if (!context.mounted) return;
          if (blocked != null) {
            showBilibiliWriteFeedback(context, blocked);
            return;
          }
          final ok = await _confirmUnfollow(context, detail.owner.name);
          if (!ok) return;
        }
        final result = await _send(
          BilibiliVideoAction.follow,
          actions.setFollowing(mid: detail.owner.mid, following: target),
        );
        if (result.isSuccess) following = target;
        if (context.mounted) {
          showBilibiliWriteFeedback(
            context,
            result,
            successMessage: target ? '已关注' : '已取消关注',
          );
        }
      });

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

Future<bool> _confirmUnfollow(BuildContext context, String name) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('取消关注'),
      content: Text('确定不再关注「$name」吗？'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('再想想'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: AppTokens.brandBilibili,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('取消关注'),
        ),
      ],
    ),
  );
  return ok == true;
}

// ------------------------------------------------------------------ coins

class BilibiliCoinChoice {
  final int count;
  final bool alsoLike;

  const BilibiliCoinChoice({required this.count, required this.alsoLike});
}

/// Coin confirmation. Coins are real and cannot be returned, so only
/// 「确认投币」 returns a choice; cancel, tapping outside and back all return
/// null. One coin is selected by default.
Future<BilibiliCoinChoice?> showBilibiliCoinDialog(
  BuildContext context, {
  required int maxCoins,
  required bool canAlsoLike,
}) {
  return showDialog<BilibiliCoinChoice>(
    context: context,
    builder: (_) =>
        _CoinDialog(maxCoins: maxCoins.clamp(1, 2), canAlsoLike: canAlsoLike),
  );
}

class _CoinDialog extends StatefulWidget {
  const _CoinDialog({required this.maxCoins, required this.canAlsoLike});

  final int maxCoins;
  final bool canAlsoLike;

  @override
  State<_CoinDialog> createState() => _CoinDialogState();
}

class _CoinDialogState extends State<_CoinDialog> {
  int _count = 1;
  bool _alsoLike = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('投币'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            children: [
              for (final n in const [1, 2])
                ChoiceChip(
                  key: ValueKey('bilibili-coin-option-$n'),
                  label: Text('$n 枚'),
                  selected: _count == n,
                  showCheckmark: false,
                  selectedColor: AppTokens.brandBilibili.withValues(
                    alpha: 0.22,
                  ),
                  onSelected: n > widget.maxCoins
                      ? null
                      : (_) => setState(() => _count = n),
                ),
            ],
          ),
          if (widget.maxCoins < 2)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                '这个视频最多还能投 1 枚',
                style: TextStyle(color: AppTokens.text2, fontSize: 12),
              ),
            ),
          if (widget.canAlsoLike)
            CheckboxListTile(
              key: const ValueKey('bilibili-coin-also-like'),
              value: _alsoLike,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              activeColor: AppTokens.brandBilibili,
              title: const Text('同时点赞', style: TextStyle(fontSize: 14)),
              onChanged: (v) => setState(() => _alsoLike = v ?? false),
            ),
          const SizedBox(height: 8),
          Text(
            '将投出 $_count 枚硬币，投出后无法撤回',
            key: const ValueKey('bilibili-coin-warning'),
            style: const TextStyle(
              color: AppTokens.danger,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('bilibili-coin-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: AppTokens.brandBilibili,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.of(
            context,
          ).pop(BilibiliCoinChoice(count: _count, alsoLike: _alsoLike)),
          child: const Text('确认投币'),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------- favourites

class BilibiliFavoriteChoice {
  /// Folders that held the video when the list was loaded.
  final Set<int> before;

  /// Folders ticked when the user confirmed.
  final Set<int> after;

  const BilibiliFavoriteChoice({required this.before, required this.after});
}

Future<BilibiliFavoriteChoice?> showBilibiliFavoriteDialog(
  BuildContext context, {
  required Future<List<BilibiliFavoriteFolder>> Function() loadFolders,
}) {
  return showDialog<BilibiliFavoriteChoice>(
    context: context,
    builder: (_) => _FavoriteDialog(loadFolders: loadFolders),
  );
}

class _FavoriteDialog extends StatefulWidget {
  const _FavoriteDialog({required this.loadFolders});

  final Future<List<BilibiliFavoriteFolder>> Function() loadFolders;

  @override
  State<_FavoriteDialog> createState() => _FavoriteDialogState();
}

class _FavoriteDialogState extends State<_FavoriteDialog> {
  List<BilibiliFavoriteFolder>? _folders;
  final Set<int> _before = <int>{};
  final Set<int> _selected = <int>{};
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _folders = null;
    });
    try {
      final folders = await widget.loadFolders();
      if (!mounted) return;
      setState(() {
        _folders = folders;
        _before
          ..clear()
          ..addAll(folders.where((f) => f.containsVideo).map((f) => f.id));
        _selected
          ..clear()
          ..addAll(_before);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '收藏夹加载失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    final folders = _folders;
    final Widget body;
    if (_error != null) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_error!, style: const TextStyle(color: AppTokens.text2)),
          TextButton(onPressed: _load, child: const Text('重试')),
        ],
      );
    } else if (folders == null) {
      body = const Padding(
        padding: EdgeInsets.all(20),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    } else if (folders.isEmpty) {
      body = const Text(
        '还没有收藏夹，可以先在 B 站创建',
        style: TextStyle(color: AppTokens.text2),
      );
    } else {
      body = ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 360),
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final folder in folders)
              CheckboxListTile(
                key: ValueKey('bilibili-favorite-folder-${folder.id}'),
                value: _selected.contains(folder.id),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                activeColor: AppTokens.brandBilibili,
                title: Text(folder.title, style: const TextStyle(fontSize: 14)),
                subtitle: Text(
                  '${folder.mediaCount} 个内容',
                  style: const TextStyle(fontSize: 12),
                ),
                onChanged: (v) => setState(() {
                  if (v == true) {
                    _selected.add(folder.id);
                  } else {
                    _selected.remove(folder.id);
                  }
                }),
              ),
          ],
        ),
      );
    }
    return AlertDialog(
      title: const Text('收藏到'),
      content: SizedBox(width: 360, child: body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('bilibili-favorite-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: AppTokens.brandBilibili,
            foregroundColor: Colors.white,
          ),
          onPressed: folders == null || folders.isEmpty
              ? null
              : () => Navigator.of(context).pop(
                  BilibiliFavoriteChoice(
                    before: Set<int>.of(_before),
                    after: Set<int>.of(_selected),
                  ),
                ),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- buttons

/// Compact like / coin / favourite / follow button. [active] null means the
/// state could not be read; the button is dimmed but still works.
class BilibiliActionButton extends StatelessWidget {
  const BilibiliActionButton({
    super.key,
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.active,
    required this.busy,
    required this.onPressed,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool? active;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final on = active == true;
    final color = on
        ? AppTokens.brandBilibili
        : active == null
        ? AppTokens.text3
        : AppTokens.text1;
    final button = OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        disabledForegroundColor: color.withValues(alpha: 0.6),
        side: BorderSide(color: on ? AppTokens.brandBilibili : AppTokens.text4),
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
      onPressed: busy ? null : onPressed,
      icon: busy
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(on ? activeIcon : icon, size: 17),
      label: Text(label, style: const TextStyle(fontSize: 13)),
    );
    return active == null
        ? Tooltip(message: '状态暂时无法获取', child: button)
        : button;
  }
}

/// Like / coin / favourite row, with a small read-only mark when writes are
/// blocked.
class BilibiliVideoInteractionBar extends StatelessWidget {
  const BilibiliVideoInteractionBar({
    super.key,
    required this.interactions,
    required this.readOnly,
    required this.onReadOnlyTap,
  });

  final BilibiliVideoInteractions interactions;
  final bool readOnly;
  final VoidCallback onReadOnlyTap;

  @override
  Widget build(BuildContext context) {
    final s = interactions;
    final coins = s.coins;
    final coinLabel = switch (coins) {
      null => '投币',
      0 => '投币',
      >= BilibiliVideoActions.maxCoins => '已投币',
      _ => '已投 $coins',
    };
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        BilibiliActionButton(
          key: const ValueKey('bilibili-action-like'),
          icon: Icons.thumb_up_alt_outlined,
          activeIcon: Icons.thumb_up_alt,
          label: s.liked == true ? '已赞' : '点赞',
          active: s.liked,
          busy: s.isBusy(BilibiliVideoAction.like),
          onPressed: () => unawaited(s.toggleLike(context)),
        ),
        BilibiliActionButton(
          key: const ValueKey('bilibili-action-coin'),
          icon: Icons.monetization_on_outlined,
          activeIcon: Icons.monetization_on,
          label: coinLabel,
          active: coins == null ? null : coins > 0,
          busy: s.isBusy(BilibiliVideoAction.coin),
          onPressed: () => unawaited(s.giveCoins(context)),
        ),
        BilibiliActionButton(
          key: const ValueKey('bilibili-action-favorite'),
          icon: Icons.star_border,
          activeIcon: Icons.star,
          label: s.favorited == true ? '已收藏' : '收藏',
          active: s.favorited,
          busy: s.isBusy(BilibiliVideoAction.favorite),
          onPressed: () => unawaited(s.editFavorites(context)),
        ),
        if (readOnly)
          Tooltip(
            message: '账号只读已开启，点按前往 B站设置',
            child: InkWell(
              key: const ValueKey('bilibili-action-read-only'),
              borderRadius: BorderRadius.circular(10),
              onTap: onReadOnlyTap,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock_outline, size: 13, color: AppTokens.text3),
                    SizedBox(width: 3),
                    Text(
                      '只读',
                      style: TextStyle(color: AppTokens.text3, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Follow / followed button beside the uploader.
class BilibiliFollowButton extends StatelessWidget {
  const BilibiliFollowButton({super.key, required this.interactions});

  final BilibiliVideoInteractions interactions;

  @override
  Widget build(BuildContext context) {
    final following = interactions.following;
    return BilibiliActionButton(
      key: const ValueKey('bilibili-action-follow'),
      icon: Icons.add,
      activeIcon: Icons.check,
      label: following == true ? '已关注' : '关注',
      active: following,
      busy: interactions.isBusy(BilibiliVideoAction.follow),
      onPressed: () => unawaited(interactions.toggleFollow(context)),
    );
  }
}
