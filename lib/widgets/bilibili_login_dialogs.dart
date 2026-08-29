import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/app_toast.dart';

Future<void> showBilibiliLoginDialog(
  BuildContext context, {
  bool suppressToasts = false,
}) async {
  final service = context.read<BilibiliDownloadService>();
  final cookieController = TextEditingController();
  try {
    final hasCookie = await service.apiService.hasCookie();
    var loginStatus = BilibiliLoginStatus.loggedOut;
    if (hasCookie) {
      loginStatus = await service.apiService.checkLoginStatusDetailed();
    }
    if (!context.mounted) return;

    final (statusText, statusColor) = switch (loginStatus) {
      BilibiliLoginStatus.loggedIn => ('已登录', Colors.green),
      BilibiliLoginStatus.loggedOut => (
        hasCookie ? '已失效' : '未登录',
        hasCookie ? Colors.orange : Colors.grey,
      ),
      BilibiliLoginStatus.unavailable => ('已保存（当前无法联网验证）', Colors.orange),
    };

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _ResponsiveLoginDialog(
        statusText: statusText,
        statusColor: statusColor,
        cookieController: cookieController,
        onQrLogin: () {
          Navigator.of(dialogContext).pop();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) {
              showBilibiliQrCodeDialog(context, suppressToasts: suppressToasts);
            }
          });
        },
        onSave: () async {
          final sessData = cookieController.text.trim();
          if (sessData.isEmpty) return;
          await service.apiService.setCookie(sessData);
          if (!dialogContext.mounted) return;
          if (!suppressToasts) {
            AppToast.show('Cookie 已更新', type: AppToastType.success);
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

class _ResponsiveLoginDialog extends StatelessWidget {
  final String statusText;
  final Color statusColor;
  final TextEditingController cookieController;
  final VoidCallback onQrLogin;
  final Future<void> Function() onSave;

  const _ResponsiveLoginDialog({
    required this.statusText,
    required this.statusColor,
    required this.cookieController,
    required this.onQrLogin,
    required this.onSave,
  });

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
              hintText: '粘贴你的 SESSDATA',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          );
          final qrButton = ElevatedButton.icon(
            onPressed: onQrLogin,
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
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: onSave,
                        child: const Text('保存'),
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
  String? qrUrl;
  String? qrKey;
  String status = '正在生成二维码…';
  Timer? pollTimer;
  String? errorMessage;

  @override
  void initState() {
    super.initState();
    _generateQrCode();
  }

  @override
  void dispose() {
    pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _generateQrCode() async {
    if (!mounted) return;
    setState(() {
      status = '正在生成二维码…';
      errorMessage = null;
      qrUrl = null;
    });
    final service = context.read<BilibiliDownloadService>();
    try {
      final result = await service.apiService.generateQrCode();
      if (!mounted) return;
      setState(() {
        qrUrl = result['url'];
        qrKey = result['qrcode_key'];
        status = '请使用 Bilibili App 扫码登录';
      });
      _startPolling();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        status = '生成二维码失败';
        errorMessage = '无法获取二维码，请重试';
      });
    }
  }

  void _startPolling() {
    if (qrKey == null) return;
    final service = context.read<BilibiliDownloadService>();
    pollTimer?.cancel();
    pollTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final result = await service.apiService.pollQrCode(qrKey!);
      if (!mounted) return;
      if (result['success'] == true) {
        timer.cancel();
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
      } else if (result['code'] == 86038) {
        timer.cancel();
        setState(() {
          status = '二维码已失效';
          qrUrl = null;
        });
      } else if (result['code'] == 86090) {
        setState(() => status = '已扫码，请在手机上确认');
      }
    });
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
    if (status == '二维码已失效') {
      return ElevatedButton(
        onPressed: _generateQrCode,
        child: const Text('刷新二维码'),
      );
    }
    return const CircularProgressIndicator();
  }
}
