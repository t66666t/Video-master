import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';

Future<void> showBilibiliLoginDialog(BuildContext context) async {
  final service = Provider.of<BilibiliDownloadService>(context, listen: false);
  final TextEditingController cookieController = TextEditingController();

  // Check if we already have cookies
  final hasCookie = await service.apiService.hasCookie();
  // Double check with online validation if hasCookie is true
  bool isValid = false;
  if (hasCookie) {
     isValid = await service.apiService.checkLoginStatus();
  }
  
  String statusText = isValid ? "已登录" : (hasCookie ? "已失效" : "未登录");
  Color statusColor = isValid ? Colors.green : (hasCookie ? Colors.orange : Colors.grey);

  if (!context.mounted) return;

  await showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text("Bilibili 登录"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Text("状态: "),
              Text(statusText, style: TextStyle(color: statusColor, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            icon: const Icon(Icons.qr_code),
            label: const Text("扫码登录"),
            onPressed: () {
              Navigator.pop(context);
              showBilibiliQrCodeDialog(context);
            },
          ),
          const SizedBox(height: 20),
          const Divider(),
          const Text("或手动输入 SESSDATA:", style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 10),
          TextField(
            controller: cookieController,
            decoration: const InputDecoration(
              labelText: "SESSDATA",
              border: OutlineInputBorder(),
              hintText: "粘贴你的 SESSDATA...",
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("取消"),
        ),
        ElevatedButton(
          onPressed: () async {
            final sessData = cookieController.text.trim();
            if (sessData.isNotEmpty) {
              await service.apiService.setCookie(sessData);
              if (context.mounted) {
                ScaffoldMessenger.of(context).clearSnackBars();
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Cookie 已更新")));
                Navigator.pop(context);
              }
            }
          },
          child: const Text("保存"),
        ),
      ],
    ),
  );
}

void showBilibiliQrCodeDialog(BuildContext context) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => const BilibiliQrCodeDialog(),
  );
}

class BilibiliQrCodeDialog extends StatefulWidget {
  const BilibiliQrCodeDialog({super.key});

  @override
  State<BilibiliQrCodeDialog> createState() => _BilibiliQrCodeDialogState();
}

class _BilibiliQrCodeDialogState extends State<BilibiliQrCodeDialog> {
  String? qrUrl;
  String? qrKey;
  String status = "正在生成二维码...";
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
      status = "正在生成二维码...";
      errorMessage = null;
      qrUrl = null;
    });

    final service = Provider.of<BilibiliDownloadService>(context, listen: false);
    try {
      final result = await service.apiService.generateQrCode();
      if (!mounted) return;
      setState(() {
        qrUrl = result['url'];
        qrKey = result['qrcode_key'];
        status = "请使用 Bilibili App 扫码登录";
      });
      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        status = "生成二维码失败";
        errorMessage = e.toString();
      });
    }
  }

  void _startPolling() {
    if (qrKey == null) return;
    final service = Provider.of<BilibiliDownloadService>(context, listen: false);
    
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
        Navigator.pop(context); // Close dialog
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("登录成功！")));
      } else if (result['code'] == 86038) { // Expired
        timer.cancel();
        setState(() {
          status = "二维码已失效";
          qrUrl = null;
        });
      } else if (result['code'] == 86090) { // Scanned
        setState(() => status = "已扫码，请在手机上确认");
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("扫码登录"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 200,
            width: 200,
            child: qrUrl != null
                ? Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(8),
                    child: QrImageView(
                      data: qrUrl!,
                      version: QrVersions.auto,
                      size: 200,
                    ),
                  )
                : Center(
                    child: errorMessage != null
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.error_outline, color: Colors.red, size: 40),
                            const SizedBox(height: 8),
                            ElevatedButton(
                              onPressed: _generateQrCode,
                              child: const Text("重试"),
                            )
                          ],
                        )
                      : (status == "二维码已失效" 
                          ? ElevatedButton(
                              onPressed: _generateQrCode,
                              child: const Text("刷新二维码"),
                            )
                          : const CircularProgressIndicator()),
                  ),
          ),
          const SizedBox(height: 16),
          Text(errorMessage ?? status, 
               style: TextStyle(fontSize: 14, color: errorMessage != null ? Colors.red : null), 
               textAlign: TextAlign.center),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("取消"),
        ),
      ],
    );
  }
}
