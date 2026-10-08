import 'package:flutter/material.dart';
import 'package:video_player_app/services/bilibili/bilibili_player_panel_policy.dart';
import 'package:video_player_app/theme/app_tokens.dart';

/// Height of the 「详情 | 字幕」 switch above the portrait panel.
const double kBilibiliPortraitTabBarHeight = 40;

/// The portrait player's area below the video for a Bilibili video: the
/// 「详情 | 字幕」 switch, then the Bilibili details or the subtitle list.
///
/// Both stay built, so switching keeps the subtitle list's place and the
/// loaded details. [onSelect] null shows the switch without taking taps.
/// [details] null (not a Bilibili video) shows only the subtitle list, with
/// no switch; the subtitle list stays the same element either way.
class BilibiliPortraitTabs extends StatelessWidget {
  const BilibiliPortraitTabs({
    super.key,
    required this.tab,
    required this.onSelect,
    required this.details,
    required this.subtitles,
  });

  final PortraitBilibiliTab tab;
  final ValueChanged<PortraitBilibiliTab>? onSelect;
  final Widget? details;
  final Widget subtitles;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppTokens.bgBase,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (details != null)
            BilibiliPortraitTabBar(tab: tab, onSelect: onSelect),
          Expanded(
            child: IndexedStack(
              sizing: StackFit.expand,
              index: details != null && tab == PortraitBilibiliTab.details
                  ? 0
                  : 1,
              children: [details ?? const SizedBox.shrink(), subtitles],
            ),
          ),
        ],
      ),
    );
  }
}

/// The 「详情 | 字幕」 switch itself.
class BilibiliPortraitTabBar extends StatelessWidget {
  const BilibiliPortraitTabBar({
    super.key,
    required this.tab,
    required this.onSelect,
  });

  final PortraitBilibiliTab tab;
  final ValueChanged<PortraitBilibiliTab>? onSelect;

  @override
  Widget build(BuildContext context) {
    Widget item(PortraitBilibiliTab value, String label) {
      final selected = value == tab;
      final select = onSelect;
      return Expanded(
        child: InkWell(
          key: ValueKey('bilibili-portrait-tab-${value.name}'),
          onTap: select == null || selected ? null : () => select(value),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: selected ? AppTokens.brandBilibili : AppTokens.text2,
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  width: 22,
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
        ),
      );
    }

    return Container(
      key: const ValueKey('bilibili-portrait-tab-bar'),
      height: kBilibiliPortraitTabBarHeight,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTokens.bgCard)),
      ),
      child: Row(
        children: [
          item(PortraitBilibiliTab.details, '详情'),
          item(PortraitBilibiliTab.subtitles, '字幕'),
        ],
      ),
    );
  }
}
