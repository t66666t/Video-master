import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:video_player_app/screens/bilibili/bilibili_settings_screen.dart';
import 'package:video_player_app/screens/bilibili/bilibili_watch_history_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_qr_login_controller.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/utils/bilibili_image_url.dart';
import 'package:video_player_app/widgets/bilibili_cover_image.dart';

/// Opens the account page. [api] defaults to the app's Bilibili service;
/// [onStateChanged] hears every login state the page shows, so the caller's
/// avatar can follow without waiting for the page to close.
Future<void> openBilibiliAccount(
  BuildContext context, {
  BilibiliApiService? api,
  ValueChanged<BilibiliLoginState>? onStateChanged,
}) {
  return Navigator.of(context).push(
    AppMaterialPageRoute<void>(
      builder: (_) =>
          BilibiliAccountScreen(api: api, onStateChanged: onStateChanged),
    ),
  );
}

/// Bilibili account: QR login when logged out; avatar, name, state and
/// logout when logged in; links to the Bilibili settings and watch history.
class BilibiliAccountScreen extends StatefulWidget {
  const BilibiliAccountScreen({
    super.key,
    this.api,
    this.settings,
    this.onStateChanged,
  });

  final BilibiliApiService? api;
  final SettingsService? settings;
  final ValueChanged<BilibiliLoginState>? onStateChanged;

  @override
  State<BilibiliAccountScreen> createState() => _BilibiliAccountScreenState();
}

class _BilibiliAccountScreenState extends State<BilibiliAccountScreen> {
  late final SettingsService _settings = widget.settings ?? SettingsService();
  late final BilibiliApiService? _api = widget.api ?? _appApi();

  BilibiliLoginState? _state;
  bool _loading = true;
  bool _loggingOut = false;

  /// Expired or network-error login the user chose to replace by scanning.
  bool _relogin = false;
  BilibiliQrLoginController? _qr;

  @override
  void initState() {
    super.initState();
    _settings.addListener(_rebuild);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _settings.removeListener(_rebuild);
    _qr?.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  BilibiliApiService? _appApi() {
    try {
      return context.read<BilibiliDownloadService>().apiService;
    } on ProviderNotFoundException {
      return null;
    }
  }

  Future<void> _refresh() async {
    final api = _api;
    if (api == null) {
      // No Bilibili service (tests, early start): show logged out.
      _state = const BilibiliLoginState(BilibiliLoginStatus.loggedOut);
      _loading = false;
      return;
    }
    setState(() => _loading = true);
    BilibiliLoginState state;
    try {
      await api.init();
      state = await api.fetchLoginState();
    } catch (_) {
      state = const BilibiliLoginState(BilibiliLoginStatus.networkError);
    }
    _apply(state);
  }

  void _apply(BilibiliLoginState state) {
    if (!mounted) return;
    setState(() {
      _state = state;
      _loading = false;
      if (state.status == BilibiliLoginStatus.loggedIn) _relogin = false;
    });
    widget.onStateChanged?.call(state);
    _syncQr();
  }

  bool get _showQr {
    final status = _state?.status;
    if (_loading || status == null) return false;
    return status == BilibiliLoginStatus.loggedOut || _relogin;
  }

  /// Runs the shared QR login only while the QR panel is on screen.
  void _syncQr() {
    final api = _api;
    if (_showQr && api != null) {
      if (_qr != null) return;
      final qr = BilibiliQrLoginController(
        api: api,
        onLoggedIn: (_) => unawaited(_handleLoggedIn()),
      )..addListener(_rebuild);
      _qr = qr;
      unawaited(qr.start());
    } else if (!_showQr && _qr != null) {
      _qr!.dispose();
      _qr = null;
    }
  }

  Future<void> _handleLoggedIn() async {
    unawaited(
      _settings.updateSetting<bool>('suppressBilibiliRestrictedDialog', false),
    );
    AppToast.show('登录成功！', type: AppToastType.success);
    _relogin = false;
    await _refresh();
  }

  Future<void> _logout() async {
    final api = _api;
    if (api == null || _loggingOut) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('会删除本机保存的 B 站登录信息，之后需要重新扫码登录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppTokens.brandBilibili,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _loggingOut = true);
    try {
      await api.logout();
      AppToast.show('已退出 B 站登录', type: AppToastType.success);
    } catch (_) {
      AppToast.show('退出失败，请重试', type: AppToastType.error);
    } finally {
      if (mounted) setState(() => _loggingOut = false);
    }
    _relogin = false;
    await _refresh();
  }

  void _startRelogin() {
    setState(() => _relogin = true);
    _syncQr();
  }

  void _cancelRelogin() {
    setState(() => _relogin = false);
    _syncQr();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTokens.bgBase,
      appBar: AppBar(
        backgroundColor: AppTokens.bgBase,
        foregroundColor: AppTokens.text1,
        elevation: 0,
        title: const Text('B 站账号', style: TextStyle(fontSize: 16)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _card(_loading ? _buildLoading() : _buildAccount()),
          if (_showQr) ...[const SizedBox(height: 12), _card(_buildQr())],
          const SizedBox(height: 18),
          _card(_buildLinks()),
        ],
      ),
    );
  }

  Widget _buildLoading() {
    return const Padding(
      padding: EdgeInsets.all(28),
      child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
    );
  }

  Widget _buildAccount() {
    final state = _state!;
    final account = state.account;
    final (label, color) = switch (state.status) {
      BilibiliLoginStatus.loggedIn => ('已登录', const Color(0xFF4CAF50)),
      BilibiliLoginStatus.loggedOut => ('未登录', AppTokens.text3),
      BilibiliLoginStatus.expired => ('登录已过期', const Color(0xFFFFA726)),
      BilibiliLoginStatus.networkError => (
        '网络错误，暂时无法验证',
        const Color(0xFFFFA726),
      ),
    };
    final name = switch (state.status) {
      BilibiliLoginStatus.loggedIn => account?.name ?? '已登录用户',
      BilibiliLoginStatus.loggedOut => '未登录 B 站',
      BilibiliLoginStatus.expired => '登录已过期',
      BilibiliLoginStatus.networkError => account?.name ?? 'B 站账号',
    };
    final avatar = bilibiliAvatarUrl(account?.avatarUrl);
    final hasLogin = state.status != BilibiliLoginStatus.loggedOut;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              avatar == null
                  ? const Icon(
                      Icons.account_circle_outlined,
                      size: 56,
                      color: AppTokens.text3,
                    )
                  : BilibiliAvatar(url: avatar, size: 56),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      key: const ValueKey('bilibili-account-name'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTokens.text1,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(Icons.circle, size: 8, color: color),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            label,
                            key: const ValueKey('bilibili-account-status'),
                            style: TextStyle(color: color, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (hasLogin) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                if (state.status == BilibiliLoginStatus.expired && !_relogin)
                  FilledButton(
                    key: const ValueKey('bilibili-account-relogin'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTokens.brandBilibili,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _startRelogin,
                    child: const Text('重新登录'),
                  ),
                if (state.status == BilibiliLoginStatus.networkError)
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTokens.text1,
                      side: const BorderSide(color: AppTokens.text4),
                    ),
                    onPressed: () => unawaited(_refresh()),
                    child: const Text('重试'),
                  ),
                OutlinedButton(
                  key: const ValueKey('bilibili-account-logout'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTokens.text1,
                    side: const BorderSide(color: AppTokens.text4),
                  ),
                  onPressed: _loggingOut ? null : _logout,
                  child: Text(_loggingOut ? '正在退出…' : '退出登录'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildQr() {
    final qr = _qr;
    final url = qr?.qrUrl;
    final Widget code;
    if (url != null) {
      code = ColoredBox(
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: QrImageView(data: url, version: QrVersions.auto),
        ),
      );
    } else if (qr == null) {
      code = const Center(
        child: Text('暂时无法登录', style: TextStyle(color: AppTokens.text2)),
      );
    } else if (qr.errorMessage != null || qr.isExpired) {
      code = Center(
        child: FilledButton(
          key: const ValueKey('bilibili-account-qr-refresh'),
          style: FilledButton.styleFrom(
            backgroundColor: AppTokens.brandBilibili,
            foregroundColor: Colors.white,
          ),
          onPressed: () => unawaited(qr.start()),
          child: Text(qr.isExpired ? '刷新二维码' : '重试'),
        ),
      );
    } else {
      code = const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Text(
            _relogin ? '重新扫码登录' : '扫码登录',
            style: const TextStyle(
              color: AppTokens.text1,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox.square(
            key: const ValueKey('bilibili-account-qr'),
            dimension: 200,
            child: code,
          ),
          const SizedBox(height: 12),
          Text(
            qr?.errorMessage ?? qr?.status ?? '',
            key: const ValueKey('bilibili-account-qr-status'),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: qr?.errorMessage == null
                  ? AppTokens.text2
                  : AppTokens.danger,
              fontSize: 13,
            ),
          ),
          if (_relogin) ...[
            const SizedBox(height: 6),
            TextButton(
              onPressed: _cancelRelogin,
              child: const Text('取消', style: TextStyle(color: AppTokens.text2)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLinks() {
    final readOnly = _settings.bilibiliAccountReadOnly;
    return Column(
      children: [
        _linkTile(
          key: const ValueKey('bilibili-account-read-only'),
          icon: Icons.lock_outline,
          title: '账号只读模式',
          trailing: readOnly ? '已开启' : '已关闭',
          onTap: () => unawaited(openBilibiliSettings(context)),
        ),
        const Divider(height: 1, color: AppTokens.lineSubtle),
        _linkTile(
          key: const ValueKey('bilibili-account-settings'),
          icon: Icons.settings_outlined,
          title: 'B 站设置',
          onTap: () => unawaited(openBilibiliSettings(context)),
        ),
        const Divider(height: 1, color: AppTokens.lineSubtle),
        _linkTile(
          key: const ValueKey('bilibili-account-history'),
          icon: Icons.history,
          title: '观看历史',
          onTap: () => unawaited(openBilibiliWatchHistory(context)),
        ),
      ],
    );
  }

  Widget _linkTile({
    required Key key,
    required IconData icon,
    required String title,
    String? trailing,
    required VoidCallback onTap,
  }) {
    return ListTile(
      key: key,
      leading: Icon(icon, size: 20, color: AppTokens.text2),
      title: Text(
        title,
        style: const TextStyle(color: AppTokens.text1, fontSize: 15),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (trailing != null)
            Text(
              trailing,
              style: const TextStyle(color: AppTokens.text2, fontSize: 13),
            ),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right, size: 20, color: AppTokens.text3),
        ],
      ),
      onTap: onTap,
    );
  }

  Widget _card(Widget child) {
    return Material(
      color: AppTokens.bgCard,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}
