import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/media_library_continue_policy.dart';
import '../services/settings_service.dart';

/// Bottom sheet for tuning continue-watching gates. Changes apply live.
class MediaLibraryContinuePolicySheet {
  const MediaLibraryContinuePolicySheet._();

  static const Color groupedBackground = Color(0xFF1C1C1E);
  static const Color groupedCard = Color(0xFF2C2C2E);
  static const Color iosBlue = Color(0xFF0A84FF);
  static const Color secondaryLabel = Color(0x99EBEBF5);
  static const Color tertiaryLabel = Color(0x4DEBEBF5);

  static Future<void> show(BuildContext context) {
    return showCupertinoModalPopup<void>(
      context: context,
      builder: (context) => const _ContinuePolicySheetBody(),
    );
  }
}

class _ContinuePolicySheetBody extends StatelessWidget {
  const _ContinuePolicySheetBody();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final policy = settings.continueWatchPolicy;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.78;
    // UI only has two stories: easier-of-two vs both. Stored `either` is the
    // same math as `shorter` once both numbers are set.
    final combineForUi = policy.combineMode == ContinueWatchCombineMode.both
        ? ContinueWatchCombineMode.both
        : ContinueWatchCombineMode.shorter;

    return CupertinoTheme(
      data: const CupertinoThemeData(brightness: Brightness.dark),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Material(
          color: Colors.transparent,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: DecoratedBox(
              decoration: const BoxDecoration(
                color: MediaLibraryContinuePolicySheet.groupedBackground,
                borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 8),
                  Container(
                    width: 36,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.28),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 8, 4),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '继续观看门槛',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.4,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        CupertinoButton(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          onPressed: () => Navigator.pop(context),
                          child: const Text(
                            '完成',
                            style: TextStyle(
                              color: MediaLibraryContinuePolicySheet.iosBlue,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                      children: [
                        const Text(
                          '只影响「只看未完成」列表：点开预览不会出现，实际看够一段时间才会进来。暂停、拖进度、缓冲不累计；倍速按真实经过的时间算。',
                          style: TextStyle(
                            color: MediaLibraryContinuePolicySheet.secondaryLabel,
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '当前：${policy.compactLabel}',
                          style: const TextStyle(
                            color: MediaLibraryContinuePolicySheet.tertiaryLabel,
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                        const _SectionLabel('认真看过多久才算数'),
                        _GroupedCard(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                CupertinoSlidingSegmentedControl<
                                  ContinueWatchCombineMode
                                >(
                                  groupValue: combineForUi,
                                  thumbColor: const Color(0xFF636366),
                                  backgroundColor: const Color(0xFF1C1C1E),
                                  children: const {
                                    ContinueWatchCombineMode.shorter: Text(
                                      '取更容易的',
                                      style: TextStyle(fontSize: 13),
                                    ),
                                    ContinueWatchCombineMode.both: Text(
                                      '两项都要',
                                      style: TextStyle(fontSize: 13),
                                    ),
                                  },
                                  onValueChanged: (mode) {
                                    if (mode == null) return;
                                    _save(
                                      settings,
                                      policy.copyWith(combineMode: mode),
                                    );
                                  },
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  combineForUi == ContinueWatchCombineMode.both
                                      ? '秒数和比例都达到，才算认真看过。'
                                      : '短片按「占片长」、长片按「最少看满」，用更容易达到的那个。',
                                  style: const TextStyle(
                                    color: MediaLibraryContinuePolicySheet
                                        .tertiaryLabel,
                                    fontSize: 12,
                                    height: 1.35,
                                  ),
                                ),
                                _SteppedDurationSlider(
                                  title: '最少看满',
                                  hint: '真实经过的观看时间，不是进度条位置。',
                                  stepsMs: ContinueWatchSliderSteps.minWatchMs,
                                  valueMs: policy.minWatchMs,
                                  onChanged: (ms) => _save(
                                    settings,
                                    policy.copyWith(minWatchMs: ms),
                                  ),
                                ),
                                _PercentSlider(
                                  title: '占片长',
                                  hint: '实际观看 ÷ 片子总时长。10 分钟片子的 20% 是 2 分钟。',
                                  valueLabel: policy.minDurationFraction <= 0
                                      ? '不限'
                                      : '${(policy.minDurationFraction * 100).round()}%',
                                  sliderValue:
                                      policy.minDurationFraction /
                                      ContinueWatchPolicy
                                          .minDurationFractionMax,
                                  divisions:
                                      (ContinueWatchPolicy
                                                  .minDurationFractionMax *
                                              100)
                                          .round(),
                                  onChanged: (t) {
                                    final fraction =
                                        (t *
                                                ContinueWatchPolicy
                                                    .minDurationFractionMax)
                                            .clamp(
                                              ContinueWatchPolicy
                                                  .minDurationFractionMin,
                                              ContinueWatchPolicy
                                                  .minDurationFractionMax,
                                            );
                                    _save(
                                      settings,
                                      policy.copyWith(
                                        minDurationFraction:
                                            (fraction * 100).round() / 100,
                                      ),
                                    );
                                  },
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  _examples(policy),
                                  key: const ValueKey('continuePolicyExamples'),
                                  style: const TextStyle(
                                    color: MediaLibraryContinuePolicySheet
                                        .secondaryLabel,
                                    fontSize: 12,
                                    height: 1.45,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const _SectionLabel('不想看到的'),
                        _GroupedCard(
                          child: Column(
                            children: [
                              _IosSwitchRow(
                                title: '排除已看完',
                                subtitle: '播到结尾的片子不再出现在未完成里。',
                                value: policy.excludeCompleted,
                                onChanged: (value) => _save(
                                  settings,
                                  policy.copyWith(excludeCompleted: value),
                                ),
                              ),
                              const _Hairline(),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  4,
                                  12,
                                  10,
                                ),
                                child: Column(
                                  children: [
                                    _PercentSlider(
                                      title: '播放进度不到就不列',
                                      hint: '看进度条走到哪里，和上面「实际看了多久」不是一回事。',
                                      valueLabel:
                                          policy.minProgressFraction <= 0
                                          ? '不限'
                                          : '${(policy.minProgressFraction * 100).round()}%',
                                      sliderValue:
                                          policy.minProgressFraction /
                                          ContinueWatchPolicy
                                              .minProgressFractionMax,
                                      divisions:
                                          (ContinueWatchPolicy
                                                      .minProgressFractionMax *
                                                  100)
                                              .round(),
                                      onChanged: (t) {
                                        final fraction =
                                            (t *
                                                    ContinueWatchPolicy
                                                        .minProgressFractionMax)
                                                .clamp(
                                                  ContinueWatchPolicy
                                                      .minProgressFractionMin,
                                                  ContinueWatchPolicy
                                                      .minProgressFractionMax,
                                                );
                                        _save(
                                          settings,
                                          policy.copyWith(
                                            minProgressFraction:
                                                (fraction * 100).round() / 100,
                                          ),
                                        );
                                      },
                                    ),
                                    _SteppedDurationSlider(
                                      title: '还剩这么短就隐藏',
                                      hint: '快看完的片子从列表里拿掉。',
                                      stepsMs: ContinueWatchSliderSteps
                                          .remainingOrItemMs,
                                      valueMs: policy.hideRemainingBelowMs,
                                      onChanged: (ms) => _save(
                                        settings,
                                        policy.copyWith(
                                          hideRemainingBelowMs: ms,
                                        ),
                                      ),
                                    ),
                                    _SteppedDurationSlider(
                                      title: '片子太短不列入',
                                      hint: '总时长短于这个数的不进未完成。',
                                      stepsMs: ContinueWatchSliderSteps
                                          .remainingOrItemMs,
                                      valueMs: policy.minItemDurationMs,
                                      onChanged: (ms) => _save(
                                        settings,
                                        policy.copyWith(minItemDurationMs: ms),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const _SectionLabel('只看最近'),
                        _GroupedCard(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final days
                                    in ContinueWatchPolicy.maxAgeDayChoices)
                                  _IosChoiceChip(
                                    label: days == 0
                                        ? '不限'
                                        : (days == 365 ? '1年' : '$days天'),
                                    selected: policy.maxAgeDays == days,
                                    onTap: () => _save(
                                      settings,
                                      policy.copyWith(maxAgeDays: days),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 22),
                        _GroupedCard(
                          child: _IosSwitchRow(
                            title: '旧记录用播放位置代替',
                            subtitle: '升级前只记下进度条、没有观看时钟的条目。',
                            value: policy.useProgressIfNoWatchClock,
                            onChanged: (value) => _save(
                              settings,
                              policy.copyWith(
                                useProgressIfNoWatchClock: value,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Center(
                          child: CupertinoButton(
                            onPressed: () => _save(
                              settings,
                              ContinueWatchPolicy.defaults,
                            ),
                            child: const Text(
                              '恢复默认',
                              style: TextStyle(
                                color: MediaLibraryContinuePolicySheet.iosBlue,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _examples(ContinueWatchPolicy policy) {
    const tenMin = 10 * 60 * 1000;
    const thirtySec = 30 * 1000;
    final longNeed = ContinueWatchPolicy.formatDurationMs(
      policy.watchNeedMsForDuration(tenMin),
    );
    final shortNeed = ContinueWatchPolicy.formatDurationMs(
      policy.watchNeedMsForDuration(thirtySec),
    );
    if (policy.minWatchMs <= 0 && policy.minDurationFraction <= 0) {
      return '举例：现在不限制观看时长，点开过就会进入未完成（仍受下面的过滤影响）。';
    }
    return '举例：10 分钟的片子要实际看满 $longNeed；30 秒的短片要实际看满 $shortNeed。';
  }

  static void _save(SettingsService settings, ContinueWatchPolicy policy) {
    unawaited(
      settings.updateSetting(
        'mediaLibraryContinuePolicy',
        policy.toJsonString(),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 8),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: MediaLibraryContinuePolicySheet.tertiaryLabel,
          fontSize: 13,
          fontWeight: FontWeight.w400,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _GroupedCard extends StatelessWidget {
  const _GroupedCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: ColoredBox(
        color: MediaLibraryContinuePolicySheet.groupedCard,
        child: child,
      ),
    );
  }
}

class _Hairline extends StatelessWidget {
  const _Hairline();

  @override
  Widget build(BuildContext context) {
    return const Divider(
      height: 0.5,
      thickness: 0.5,
      color: Color(0x33FFFFFF),
      indent: 16,
    );
  }
}

class _IosSwitchRow extends StatelessWidget {
  const _IosSwitchRow({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontSize: 17),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      color: MediaLibraryContinuePolicySheet.secondaryLabel,
                      fontSize: 13,
                    ),
                  ),
                ],
              ],
            ),
          ),
          CupertinoSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _IosChoiceChip extends StatelessWidget {
  const _IosChoiceChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? MediaLibraryContinuePolicySheet.iosBlue
              : const Color(0xFF3A3A3C),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : const Color(0xFFEBEBF5),
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

class _SteppedDurationSlider extends StatelessWidget {
  const _SteppedDurationSlider({
    required this.title,
    required this.hint,
    required this.stepsMs,
    required this.valueMs,
    required this.onChanged,
  });

  final String title;
  final String hint;
  final List<int> stepsMs;
  final int valueMs;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final label = valueMs <= 0
        ? '不限'
        : ContinueWatchPolicy.formatDurationMs(valueMs);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
            Text(
              label,
              style: const TextStyle(
                color: MediaLibraryContinuePolicySheet.secondaryLabel,
                fontSize: 15,
              ),
            ),
          ],
        ),
        Text(
          hint,
          style: const TextStyle(
            color: MediaLibraryContinuePolicySheet.tertiaryLabel,
            fontSize: 11,
            height: 1.3,
          ),
        ),
        CupertinoSlider(
          value: ContinueWatchSliderSteps.sliderOf(valueMs, stepsMs),
          divisions: stepsMs.length - 1,
          activeColor: MediaLibraryContinuePolicySheet.iosBlue,
          onChanged: (t) => onChanged(ContinueWatchSliderSteps.msOf(t, stepsMs)),
        ),
      ],
    );
  }
}

class _PercentSlider extends StatelessWidget {
  const _PercentSlider({
    required this.title,
    required this.hint,
    required this.valueLabel,
    required this.sliderValue,
    required this.divisions,
    required this.onChanged,
  });

  final String title;
  final String hint;
  final String valueLabel;
  final double sliderValue;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
            Text(
              valueLabel,
              style: const TextStyle(
                color: MediaLibraryContinuePolicySheet.secondaryLabel,
                fontSize: 15,
              ),
            ),
          ],
        ),
        Text(
          hint,
          style: const TextStyle(
            color: MediaLibraryContinuePolicySheet.tertiaryLabel,
            fontSize: 11,
            height: 1.3,
          ),
        ),
        CupertinoSlider(
          value: sliderValue.clamp(0.0, 1.0),
          divisions: divisions,
          activeColor: MediaLibraryContinuePolicySheet.iosBlue,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
