import 'dart:async';
import 'package:flutter/material.dart';
import '../services/subtitle_debug_session.dart';
import '../utils/app_toast.dart';

/// Defers the speed popup until the sequence ends, so it cannot swallow taps.
class SubtitleDebugSpeedGateway extends StatefulWidget {
  final Widget Function(BuildContext, void Function(VoidCallback)) builder;
  const SubtitleDebugSpeedGateway({super.key, required this.builder});
  static const interval = Duration(milliseconds: 350);
  @override
  State<SubtitleDebugSpeedGateway> createState() => _GatewayState();
}

class _GatewayState extends State<SubtitleDebugSpeedGateway> {
  Timer? _timer;
  int _taps = 0;
  void _tap(VoidCallback openSpeed) {
    if (!SubtitleDebugSession.available) {
      openSpeed();
      return;
    }
    _timer?.cancel();
    if (++_taps == 3) {
      _taps = 0;
      SubtitleDebugSession.instance.toggle();
      AppToast.show(
        SubtitleDebugSession.instance.enabled
            ? '字幕预设入口已开启 · 状态会自动保存'
            : '已切回原字幕模式 · 状态已保存',
      );
      return;
    }
    _timer = Timer(SubtitleDebugSpeedGateway.interval, () {
      _taps = 0;
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) openSpeed();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _tap);
}
