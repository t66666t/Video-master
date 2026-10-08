import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player_app/screens/bilibili/bilibili_account_screen.dart';
import 'package:video_player_app/screens/bilibili/bilibili_settings_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_interaction_gate.dart';
import 'package:video_player_app/utils/app_toast.dart';

/// Tells the user how an account write through [BilibiliInteractionGate]
/// ended. Read-only offers the Bilibili settings, login problems offer the
/// account page. A success only shows a toast when [successMessage] is given.
void showBilibiliWriteFeedback(
  BuildContext context,
  BilibiliWriteResult result, {
  String? successMessage,
}) {
  final navigator = Navigator.maybeOf(context);
  switch (result.outcome) {
    case BilibiliWriteOutcome.success:
      if (successMessage != null) {
        AppToast.show(successMessage, type: AppToastType.success);
      }
    case BilibiliWriteOutcome.readOnly:
      AppToast.show(
        result.message,
        action: navigator == null
            ? null
            : AppToastAction(
                label: '去设置',
                onPressed: () {
                  if (navigator.mounted) {
                    unawaited(openBilibiliSettings(navigator.context));
                  }
                },
              ),
      );
    case BilibiliWriteOutcome.notLoggedIn ||
        BilibiliWriteOutcome.missingCsrf ||
        BilibiliWriteOutcome.loginExpired:
      AppToast.show(
        result.message,
        type: AppToastType.error,
        action: navigator == null
            ? null
            : AppToastAction(
                label: '去登录',
                onPressed: () {
                  if (navigator.mounted) {
                    unawaited(openBilibiliAccount(navigator.context));
                  }
                },
              ),
      );
    case BilibiliWriteOutcome.riskControlled ||
        BilibiliWriteOutcome.failed ||
        BilibiliWriteOutcome.invalidRequest ||
        BilibiliWriteOutcome.networkError:
      AppToast.show(result.message, type: AppToastType.error);
  }
}
