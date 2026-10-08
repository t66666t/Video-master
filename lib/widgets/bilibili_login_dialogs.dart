import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_qr_login_controller.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/app_toast.dart';

Future<void> showBilibiliLoginDialog(
  BuildContext context, {
  bool suppressToasts = false,
}) async {
  final service = context.read<BilibiliDownloadService>();
  final cookieController = TextEditingController();
  try {
    final loginState = await service.apiService.fetchLoginState();
    if (!context.mounted) return;

    final account = loginState.account;
    final (statusText, statusColor) = switch (loginState.status) {
      BilibiliLoginStatus.loggedIn => (
        account == null ? '已登录' : '已登录：${account.name}',
        Colors.green,
      ),
      BilibiliLoginStatus.loggedOut => ('未登录', Colors.grey),
      BilibiliLoginStatus.expired => ('已过期，请重新登录', Colors.orange),
      BilibiliLoginStatus.networkError => ('已保存（当前无法联网验证）', Colors.orange),
    };
    final canLogout = loginState.status != BilibiliLoginStatus.loggedOut;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _ResponsiveLoginDialog(
        statusText: statusText,
        statusColor: statusColor,
        avatarUrl: account?.avatarUrl ?? '',
        cookieController: cookieController,
        onLogout: canLogout
            ? () async {
                await service.apiService.logout();
                if (!dialogContext.mounted) return;
                if (!suppressToasts) {
                  AppToast.show('已退出 B 站登录', type: AppToastType.success);
                }
                Navigator.of(dialogContext).pop();
              }
            : null,
        onQrLogin: () {
          Navigator.of(dialogContext).pop();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) {
              showBilibiliQrCodeDialog(context, suppressToasts: suppressToasts);
            }
          });
        },
        onSave: () async {
          final input = cookieController.text.trim();
          if (input.isEmpty) return;
          try {
            // Verified with nav first; only saved when Bilibili confirms.
            await service.apiService.loginWithCookieInput(input);
          } on BilibiliAuthException catch (error) {
            AppToast.show(error.message, type: AppToastType.error);
            return;
          }
          if (!dialogContext.mounted) return;
          if (!suppressToasts) {
            AppToast.show('登录成功，Cookie 已安全保存', type: AppToastType.success);
          }
          unawaited(
            dialogContext.read<SettingsService>().updateSetting(
              'suppressBilibiliRestrictedDialog',
              false,
            ),
          );
          Navigator.of(dialogContext).pop();
        },
      ),
    );
  } finally {
    cookieController.dispose();
  }
}

class _ResponsiveLoginDialog extends StatefulWidget {
  final String statusText;
  final Color statusColor;
  final String avatarUrl;
  final TextEditingController cookieController;
  final VoidCallback onQrLogin;
  final Future<void> Function() onSave;
  final Future<void> Function()? onLogout;

  const _ResponsiveLoginDialog({
    required this.statusText,
    required this.statusColor,
    required this.avatarUrl,
    required this.cookieController,
    required this.onQrLogin,
    required this.onSave,
    required this.onLogout,
  });

  @override
  State<_ResponsiveLoginDialog> createState() => _ResponsiveLoginDialogState();
}

class _ResponsiveLoginDialogState extends State<_ResponsiveLoginDialog> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get statusText => widget.statusText;
  Color get statusColor => widget.statusColor;
  TextEditingController get cookieController => widget.cookieController;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight < 430;
          final wide = constraints.maxWidth >= 500;
          final gap = compact ? 8.0 : 14.0;
          final cookieField = TextField(
            controller: cookieController,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'SESSDATA',
              hintText: '粘贴 SESSDATA 或完整 Cookie',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          );
          final qrButton = ElevatedButton.icon(
            onPressed: _busy ? null : widget.onQrLogin,
            icon: const Icon(Icons.qr_code_rounded),
            label: const Text('扫码登录'),
          );

          return ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: EdgeInsets.fromLTRB(20, compact ? 12 : 18, 12, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Bilibili 登录',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                  SizedBox(height: compact ? 2 : 6),
                  Row(
                    children: [
                      if (widget.avatarUrl.isNotEmpty) ...[
                        CircleAvatar(
                          radius: 12,
                          backgroundImage: NetworkImage(widget.avatarUrl),
                          onBackgroundImageError: (_, _) {},
                        ),
                        const SizedBox(width: 8),
                      ],
                      const Text('状态：'),
                      Flexible(
                        child: Text(
                          statusText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: statusColor,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: gap),
                  if (wide)
                    Row(
                      children: [
                        qrButton,
                        SizedBox(width: gap),
                        Expanded(child: cookieField),
                      ],
                    )
                  else ...[
                    Align(alignment: Alignment.centerLeft, child: qrButton),
                    SizedBox(height: gap),
                    cookieField,
                  ],
                  SizedBox(height: gap),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (widget.onLogout != null) ...[
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _run(widget.onLogout!),
                          child: const Text('退出登录'),
                        ),
                        const Spacer(),
                      ],
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _busy ? null : () => _run(widget.onSave),
                        child: Text(_busy ? '验证中…' : '保存'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

void showBilibiliQrCodeDialog(
  BuildContext context, {
  bool suppressToasts = false,
}) {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => BilibiliQrCodeDialog(suppressToasts: suppressToasts),
  );
}

class BilibiliQrCodeDialog extends StatefulWidget {
  const BilibiliQrCodeDialog({super.key, this.suppressToasts = false});

  final bool suppressToasts;

  @override
  State<BilibiliQrCodeDialog> createState() => _BilibiliQrCodeDialogState();
}

class _BilibiliQrCodeDialogState extends State<BilibiliQrCodeDialog> {
  late final BilibiliQrLoginController _qr = BilibiliQrLoginController(
    api: context.read<BilibiliDownloadService>().apiService,
    onLoggedIn: (_) => _handleLoggedIn(),
  )..addListener(_handleQrChanged);

  String? get qrUrl => _qr.qrUrl;
  String get status => _qr.status;
  String? get errorMessage => _qr.errorMessage;

  @override
  void initState() {
    super.initState();
    unawaited(_qr.start());
  }

  @override
  void dispose() {
    _qr.dispose();
    super.dispose();
  }

  void _handleQrChanged() {
    if (mounted) setState(() {});
  }

  void _generateQrCode() => unawaited(_qr.start());

  void _handleLoggedIn() {
    if (!mounted) return;
    unawaited(
      context.read<SettingsService>().updateSetting(
        'suppressBilibiliRestrictedDialog',
        false,
      ),
    );
    if (!widget.suppressToasts) {
      AppToast.show('登录成功！', type: AppToastType.success);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight < 420;
          final horizontal =
              compact && constraints.maxWidth >= constraints.maxHeight * 1.25;
          final reservedHeight = horizontal ? 44.0 : (compact ? 112.0 : 132.0);
          final qrSize = math.min(
            horizontal
                ? constraints.maxWidth * 0.42
                : constraints.maxWidth - 48,
            (constraints.maxHeight - reservedHeight).clamp(88.0, 220.0),
          );
          final qr = SizedBox.square(
            dimension: qrSize,
            child: qrUrl != null
                ? ColoredBox(
                    color: Colors.white,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: QrImageView(
                        data: qrUrl!,
                        version: QrVersions.auto,
                      ),
                    ),
                  )
                : Center(child: _buildQrPlaceholder()),
          );
          final details = Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                errorMessage ?? status,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: errorMessage == null ? null : Colors.red,
                ),
              ),
              SizedBox(height: compact ? 6 : 12),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
            ],
          );

          return ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: EdgeInsets.all(compact ? 10 : 18),
              child: horizontal
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        qr,
                        const SizedBox(width: 16),
                        Flexible(child: details),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          '扫码登录',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(height: compact ? 6 : 12),
                        qr,
                        SizedBox(height: compact ? 6 : 12),
                        details,
                      ],
                    ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildQrPlaceholder() {
    if (errorMessage != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 34),
          const SizedBox(height: 6),
          ElevatedButton(onPressed: _generateQrCode, child: const Text('重试')),
        ],
      );
    }
    if (_qr.isExpired) {
      return ElevatedButton(
        onPressed: _generateQrCode,
        child: const Text('刷新二维码'),
      );
    }
    return const CircularProgressIndicator();
  }
}
