import 'dart:async';

import 'package:flutter/material.dart';

import 'playback_speed_dialog.dart';

class SettingsPanel extends StatefulWidget {
  final double playbackSpeed;
  final bool isPlaybackSpeedLocked;
  final double? lockedPlaybackSpeed;
  final bool showSubtitles;
  final bool isMirroredH;
  final bool isMirroredV;

  final ValueChanged<double> onSpeedChanged;
  final Future<void> Function(double speed, bool locked) onSpeedLockChanged;
  final ValueChanged<bool> onSubtitleToggle;
  final ValueChanged<bool> onMirrorHChanged;
  final ValueChanged<bool> onMirrorVChanged;
  final VoidCallback? onLoadSubtitle;
  final VoidCallback? onOpenSubtitleSettings;
  final VoidCallback onClose;

  final int doubleTapSeekSeconds;
  final ValueChanged<int> onSeekSecondsChanged;
  final bool enableDoubleTapSubtitleSeek;
  final ValueChanged<bool> onDoubleTapSubtitleSeekChanged;
  final double subtitleDelay; // New: 字幕延迟(秒)
  final ValueChanged<double> onSubtitleDelayChanged; // For visual update
  final ValueChanged<double>? onSubtitleDelayChangeEnd; // For saving

  final double longPressSpeed;
  final ValueChanged<double> onLongPressSpeedChanged;
  final bool showLongPressSpeedIndicator;
  final ValueChanged<bool> onShowLongPressSpeedIndicatorChanged;

  // New: Auto Cache
  final bool autoCacheSubtitles;
  final ValueChanged<bool> onAutoCacheSubtitlesChanged;

  final bool splitSubtitleByLine;
  final ValueChanged<bool> onSplitSubtitleByLineChanged;

  final bool continuousSubtitle;
  final ValueChanged<bool> onContinuousSubtitleChanged;
  final bool isAudioMode;
  final bool syncAudioSubtitleStyleWithVideo;
  final ValueChanged<bool>? onSyncAudioSubtitleStyleWithVideoChanged;

  final bool autoPauseOnExit;
  final ValueChanged<bool> onAutoPauseOnExitChanged;

  final bool avoidPlaybackControlsWithSubtitles;
  final ValueChanged<bool> onAvoidPlaybackControlsWithSubtitlesChanged;

  final bool pausePlaybackWhenAppBackgrounded;
  final ValueChanged<bool> onPausePlaybackWhenAppBackgroundedChanged;

  final bool allowConcurrentPlayback;
  final ValueChanged<bool> onAllowConcurrentPlaybackChanged;

  final bool showVideoDecoderSetting;
  final bool useHardwareVideoDecoding;
  final Future<void> Function(bool useHardware) onVideoDecoderChanged;

  final bool enableHeadsetMediaControls;
  final ValueChanged<bool> onEnableHeadsetMediaControlsChanged;

  final bool showMobilePlaybackControls;

  final bool showSkipPortraitPlayerSetting;
  final bool skipPortraitPlayer;
  final ValueChanged<bool> onSkipPortraitPlayerChanged;

  final bool autoPlayNextVideo;
  final ValueChanged<bool> onAutoPlayNextVideoChanged;

  final bool autoPlayOnCompletion;
  final ValueChanged<bool> onAutoPlayOnCompletionChanged;

  final bool autoPlayOnCompletionFromStart;
  final ValueChanged<bool> onAutoPlayOnCompletionFromStartChanged;

  final bool enableSeekPreview;
  final ValueChanged<bool> onEnableSeekPreviewChanged;

  final bool enableHapticFeedback;
  final ValueChanged<bool> onEnableHapticFeedbackChanged;

  final bool isLeftHandedMode;
  final ValueChanged<bool> onLeftHandedModeChanged;

  const SettingsPanel({
    super.key,
    required this.playbackSpeed,
    required this.isPlaybackSpeedLocked,
    this.lockedPlaybackSpeed,
    required this.showSubtitles,
    required this.isMirroredH,
    required this.isMirroredV,
    required this.onSpeedChanged,
    required this.onSpeedLockChanged,
    required this.onSubtitleToggle,
    required this.onMirrorHChanged,
    required this.onMirrorVChanged,
    required this.onClose,
    required this.doubleTapSeekSeconds,
    required this.onSeekSecondsChanged,
    required this.enableDoubleTapSubtitleSeek,
    required this.onDoubleTapSubtitleSeekChanged,
    required this.subtitleDelay,
    required this.onSubtitleDelayChanged,
    this.onSubtitleDelayChangeEnd,
    required this.longPressSpeed,
    required this.onLongPressSpeedChanged,
    required this.showLongPressSpeedIndicator,
    required this.onShowLongPressSpeedIndicatorChanged,
    required this.autoCacheSubtitles,
    required this.onAutoCacheSubtitlesChanged,
    required this.splitSubtitleByLine,
    required this.onSplitSubtitleByLineChanged,
    required this.continuousSubtitle,
    required this.onContinuousSubtitleChanged,
    this.isAudioMode = false,
    this.syncAudioSubtitleStyleWithVideo = true,
    this.onSyncAudioSubtitleStyleWithVideoChanged,
    required this.autoPauseOnExit,
    required this.onAutoPauseOnExitChanged,
    required this.avoidPlaybackControlsWithSubtitles,
    required this.onAvoidPlaybackControlsWithSubtitlesChanged,
    required this.pausePlaybackWhenAppBackgrounded,
    required this.onPausePlaybackWhenAppBackgroundedChanged,
    required this.allowConcurrentPlayback,
    required this.onAllowConcurrentPlaybackChanged,
    required this.showVideoDecoderSetting,
    required this.useHardwareVideoDecoding,
    required this.onVideoDecoderChanged,
    required this.enableHeadsetMediaControls,
    required this.onEnableHeadsetMediaControlsChanged,
    this.showMobilePlaybackControls = false,
    this.showSkipPortraitPlayerSetting = false,
    required this.skipPortraitPlayer,
    required this.onSkipPortraitPlayerChanged,
    required this.autoPlayNextVideo,
    required this.onAutoPlayNextVideoChanged,
    required this.autoPlayOnCompletion,
    required this.onAutoPlayOnCompletionChanged,
    required this.autoPlayOnCompletionFromStart,
    required this.onAutoPlayOnCompletionFromStartChanged,
    required this.enableSeekPreview,
    required this.onEnableSeekPreviewChanged,
    required this.enableHapticFeedback,
    required this.onEnableHapticFeedbackChanged,
    required this.isLeftHandedMode,
    required this.onLeftHandedModeChanged,
    this.onLoadSubtitle,
    this.onOpenSubtitleSettings,
  });

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  late TextEditingController _speedController;
  late TextEditingController _longPressSpeedController;
  late TextEditingController _seekSecondsController;
  bool _speedLockOperationInProgress = false;

  @override
  void initState() {
    super.initState();
    _speedController = TextEditingController(
      text: widget.playbackSpeed.toString(),
    );
    _longPressSpeedController = TextEditingController(
      text: widget.longPressSpeed.toString(),
    );
    _seekSecondsController = TextEditingController(
      text: widget.doubleTapSeekSeconds.toString(),
    );
  }

  @override
  void didUpdateWidget(SettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playbackSpeed != widget.playbackSpeed) {
      if (!_speedController.text.startsWith(widget.playbackSpeed.toString())) {
        _speedController.text = widget.playbackSpeed.toString();
      }
    }
    if (oldWidget.longPressSpeed != widget.longPressSpeed) {
      if (!_longPressSpeedController.text.startsWith(
        widget.longPressSpeed.toString(),
      )) {
        _longPressSpeedController.text = widget.longPressSpeed.toString();
      }
    }
    if (oldWidget.doubleTapSeekSeconds != widget.doubleTapSeekSeconds) {
      if (!_seekSecondsController.text.startsWith(
        widget.doubleTapSeekSeconds.toString(),
      )) {
        _seekSecondsController.text = widget.doubleTapSeekSeconds.toString();
      }
    }
  }

  @override
  void dispose() {
    _speedController.dispose();
    _longPressSpeedController.dispose();
    _seekSecondsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 600;

    final paddingValue = isSmallScreen ? 8.0 : 20.0;
    final spacingValue = isSmallScreen ? 12.0 : 24.0;

    return Container(
      width: double.infinity,
      color: const Color(0xFF1E1E1E),
      child: Column(
        children: [
          // Header
          Container(
            padding: EdgeInsets.fromLTRB(
              paddingValue,
              paddingValue,
              8,
              paddingValue / 2,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  "播放设置",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.close,
                    color: Colors.white70,
                    size: 18,
                  ),
                  onPressed: widget.onClose,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: "关闭",
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white10, height: 1),

          Expanded(
            child: ListView(
              padding: EdgeInsets.symmetric(
                horizontal: paddingValue,
                vertical: 8,
              ),
              children: [
                // Playback behavior is intentionally the first settings group.
                _buildPlaybackBehaviorSection(),
                SizedBox(height: spacingValue),
                if (widget.showVideoDecoderSetting && !widget.isAudioMode) ...[
                  _buildVideoDecoderSection(),
                  SizedBox(height: spacingValue),
                ],
                if (widget.isAudioMode) ...[
                  _buildSectionTitle("音频悬浮字幕", Icons.subtitles_outlined),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: SwitchListTile(
                      title: const Text(
                        "同步视频播放页悬浮字幕样式",
                        style: TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                      subtitle: const Text(
                        "开启后沿用视频页的字体、粗斜体、文本/背景/描边/阴影等样式；字号、间距和位置仍保持音频页独立",
                        style: TextStyle(color: Colors.white30, fontSize: 10),
                      ),
                      value: widget.syncAudioSubtitleStyleWithVideo,
                      onChanged:
                          widget.onSyncAudioSubtitleStyleWithVideoChanged,
                      activeThumbColor: Colors.blueAccent,
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  SizedBox(height: spacingValue),
                ],
                if (widget.showMobilePlaybackControls) ...[
                  _buildSectionTitle("手机端音频控制", Icons.headphones),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Column(
                      children: [
                        SwitchListTile(
                          title: const Text(
                            "离开软件后暂停播放",
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                          subtitle: const Text(
                            "退到后台或锁屏离开应用时自动暂停当前媒体",
                            style: TextStyle(
                              color: Colors.white30,
                              fontSize: 10,
                            ),
                          ),
                          value: widget.pausePlaybackWhenAppBackgrounded,
                          onChanged:
                              widget.onPausePlaybackWhenAppBackgroundedChanged,
                          activeThumbColor: Colors.blueAccent,
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                        SwitchListTile(
                          title: const Text(
                            "允许与其他应用同时播放",
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                          subtitle: const Text(
                            "开启后尽量与其他应用混音并行播放，关闭后优先独占音频",
                            style: TextStyle(
                              color: Colors.white30,
                              fontSize: 10,
                            ),
                          ),
                          value: widget.allowConcurrentPlayback,
                          onChanged: widget.onAllowConcurrentPlaybackChanged,
                          activeThumbColor: Colors.blueAccent,
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                        SwitchListTile(
                          title: const Text(
                            "耳机线控控制",
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                          subtitle: const Text(
                            "允许蓝牙耳机、有线耳机和系统媒体控件控制播放、暂停、上一集、下一集",
                            style: TextStyle(
                              color: Colors.white30,
                              fontSize: 10,
                            ),
                          ),
                          value: widget.enableHeadsetMediaControls,
                          onChanged: widget.onEnableHeadsetMediaControlsChanged,
                          activeThumbColor: Colors.blueAccent,
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: spacingValue),
                ],
                // 1. 播放速度
                _buildSectionTitle("播放速度", Icons.speed),
                Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: _availablePlaybackSpeeds().map((speed) {
                            final isSelected =
                                (speed - widget.playbackSpeed).abs() < 0.001;
                            final isLocked =
                                widget.isPlaybackSpeedLocked &&
                                widget.lockedPlaybackSpeed != null &&
                                (speed - widget.lockedPlaybackSpeed!).abs() <
                                    0.001;
                            return _buildCompactChip(
                              label: "${speed}x",
                              isSelected: isSelected,
                              trailing: isSelected || isLocked
                                  ? _buildSpeedLockCheckbox(speed)
                                  : null,
                              onTap: () => widget.onSpeedChanged(speed),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildCompactTextField(_speedController, (val) {
                      final speed = double.tryParse(val);
                      if (speed != null && speed > 0) {
                        widget.onSpeedChanged(speed);
                      }
                    }),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _playbackSpeedHint(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: 10,
                        height: 1.25,
                      ),
                    ),
                  ),
                ),
                SizedBox(height: spacingValue),

                // 2. 长按倍速
                _buildSectionTitle("长按倍速", Icons.bolt),
                Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [1.5, 2.0, 2.5, 3.0, 4.0, 5.0].map((speed) {
                            return _buildCompactChip(
                              label: "${speed}x",
                              isSelected:
                                  (speed - widget.longPressSpeed).abs() < 0.1,
                              onTap: () =>
                                  widget.onLongPressSpeedChanged(speed),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildCompactTextField(_longPressSpeedController, (val) {
                      final speed = double.tryParse(val);
                      if (speed != null && speed > 0) {
                        widget.onLongPressSpeedChanged(speed);
                      }
                    }),
                  ],
                ),
                SwitchListTile(
                  title: const Text(
                    "显示倍速提示",
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  subtitle: const Text(
                    "长按快进时显示当前倍速",
                    style: TextStyle(color: Colors.white30, fontSize: 10),
                  ),
                  value: widget.showLongPressSpeedIndicator,
                  onChanged: widget.onShowLongPressSpeedIndicatorChanged,
                  activeThumbColor: Colors.blueAccent,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),

                SizedBox(height: spacingValue),

                // 3. 字幕设置
                _buildSectionTitle("字幕设置", Icons.subtitles),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Column(
                    children: [
                      SwitchListTile(
                        title: const Text(
                          "字幕连续显示",
                          style: TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                        subtitle: const Text(
                          "字幕结束时间延后到下一条字幕开始",
                          style: TextStyle(color: Colors.white30, fontSize: 10),
                        ),
                        value: widget.continuousSubtitle,
                        onChanged: widget.onContinuousSubtitleChanged,
                        activeThumbColor: Colors.blueAccent,
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                        ),
                        visualDensity: VisualDensity.compact,
                      ),
                      SwitchListTile(
                        title: const Text(
                          "显示字幕",
                          style: TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                        value: widget.showSubtitles,
                        onChanged: widget.onSubtitleToggle,
                        activeThumbColor: Colors.blueAccent,
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                        ),
                        visualDensity: VisualDensity.compact,
                      ),
                      SwitchListTile(
                        title: const Text(
                          "自动缓存字幕",
                          style: TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                        subtitle: const Text(
                          "导入后自动复制到本地",
                          style: TextStyle(color: Colors.white30, fontSize: 10),
                        ),
                        value: widget.autoCacheSubtitles,
                        onChanged: widget.onAutoCacheSubtitlesChanged,
                        activeThumbColor: Colors.blueAccent,
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                        ),
                        visualDensity: VisualDensity.compact,
                      ),
                      SwitchListTile(
                        title: const Text(
                          "识别第一行为主字幕",
                          style: TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                        subtitle: const Text(
                          "第二行为副字幕。关闭则全部为主字幕",
                          style: TextStyle(color: Colors.white30, fontSize: 10),
                        ),
                        value: widget.splitSubtitleByLine,
                        onChanged: widget.onSplitSubtitleByLineChanged,
                        activeThumbColor: Colors.blueAccent,
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                        ),
                        visualDensity: VisualDensity.compact,
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: _buildActionButton(
                                icon: Icons.file_upload_outlined,
                                label: "加载本地",
                                onTap: widget.onLoadSubtitle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _buildActionButton(
                                icon: Icons.style,
                                label: "样式设置",
                                onTap: widget.onOpenSubtitleSettings,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                SizedBox(height: spacingValue),

                // 4. 字幕同步
                _buildSectionTitle(
                  "字幕同步 (${widget.subtitleDelay > 0 ? '+' : ''}${widget.subtitleDelay.toStringAsFixed(2)}s)",
                  Icons.sync,
                ),
                SizedBox(
                  height: 30,
                  child: Row(
                    children: [
                      const Text(
                        "-5s",
                        style: TextStyle(color: Colors.white38, fontSize: 10),
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 2,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 12,
                            ),
                          ),
                          child: Slider(
                            value: widget.subtitleDelay,
                            min: -5.0,
                            max: 5.0,
                            divisions: 200,
                            activeColor: Colors.orangeAccent,
                            onChanged: widget.onSubtitleDelayChanged,
                            onChangeEnd: widget.onSubtitleDelayChangeEnd,
                          ),
                        ),
                      ),
                      const Text(
                        "+5s",
                        style: TextStyle(color: Colors.white38, fontSize: 10),
                      ),
                    ],
                  ),
                ),

                SizedBox(height: spacingValue),

                // 5.5 双击跳转字幕
                SwitchListTile(
                  title: const Text(
                    "双击跳转上一句/下一句",
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  subtitle: const Text(
                    "开启后，双击左侧跳转上一句字幕，双击右侧跳转下一句",
                    style: TextStyle(color: Colors.white30, fontSize: 10),
                  ),
                  value: widget.enableDoubleTapSubtitleSeek,
                  onChanged: widget.onDoubleTapSubtitleSeekChanged,
                  activeThumbColor: Colors.blueAccent,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),

                // 6. 双击快进
                _buildSectionTitle("双击快进 (秒)", Icons.fast_forward),
                Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [5, 10, 15, 30, 60].map((seconds) {
                            return _buildCompactChip(
                              label: "${seconds}s",
                              isSelected:
                                  seconds == widget.doubleTapSeekSeconds,
                              onTap: () => widget.onSeekSecondsChanged(seconds),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildCompactTextField(_seekSecondsController, (val) {
                      final seconds = int.tryParse(val);
                      if (seconds != null && seconds > 0) {
                        widget.onSeekSecondsChanged(seconds);
                      }
                    }),
                  ],
                ),

                SizedBox(height: spacingValue),

                // 6. 画面调整
                _buildSectionTitle("画面调整", Icons.aspect_ratio),
                Row(
                  children: [
                    Expanded(
                      child: _buildMirrorButton(
                        icon: Icons.flip,
                        label: "水平翻转",
                        isActive: widget.isMirroredH,
                        onTap: () =>
                            widget.onMirrorHChanged(!widget.isMirroredH),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildMirrorButton(
                        icon: Icons.flip_camera_android,
                        label: "垂直翻转",
                        isActive: widget.isMirroredV,
                        onTap: () =>
                            widget.onMirrorVChanged(!widget.isMirroredV),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaybackBehaviorSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionTitle("播放行为", Icons.play_circle_outline),
        Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            children: [
              if (widget.showSkipPortraitPlayerSetting)
                SwitchListTile(
                  title: const Text(
                    "跳过竖屏播放页",
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  subtitle: const Text(
                    "点击媒体卡片后直接进入横屏播放页",
                    style: TextStyle(color: Colors.white30, fontSize: 10),
                  ),
                  value: widget.skipPortraitPlayer,
                  onChanged: widget.onSkipPortraitPlayerChanged,
                  activeThumbColor: Colors.blueAccent,
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  visualDensity: VisualDensity.compact,
                ),
              SwitchListTile(
                title: const Text(
                  "字幕避让播放控件",
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                subtitle: const Text(
                  "播放控件显示时，仅将与进度条或底部按钮重叠的主、副字幕整体上移",
                  style: TextStyle(color: Colors.white30, fontSize: 10),
                ),
                value: widget.avoidPlaybackControlsWithSubtitles,
                onChanged: widget.onAvoidPlaybackControlsWithSubtitlesChanged,
                activeThumbColor: Colors.blueAccent,
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                visualDensity: VisualDensity.compact,
              ),
              SwitchListTile(
                title: const Text(
                  "退出页面自动暂停",
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                subtitle: const Text(
                  "退出播放页面时自动暂停视频",
                  style: TextStyle(color: Colors.white30, fontSize: 10),
                ),
                value: widget.autoPauseOnExit,
                onChanged: widget.onAutoPauseOnExitChanged,
                activeThumbColor: Colors.blueAccent,
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                visualDensity: VisualDensity.compact,
              ),
              SwitchListTile(
                title: const Text(
                  "切换上下集自动播放",
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                subtitle: const Text(
                  "切换到上/下一集时自动开始播放",
                  style: TextStyle(color: Colors.white30, fontSize: 10),
                ),
                value: widget.autoPlayNextVideo,
                onChanged: widget.onAutoPlayNextVideoChanged,
                activeThumbColor: Colors.blueAccent,
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                visualDensity: VisualDensity.compact,
              ),
              SwitchListTile(
                title: const Text(
                  "自动连播",
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                subtitle: const Text(
                  "当前媒体播放完后自动播放下一个；若已到末尾则回到播放列表第一个",
                  style: TextStyle(color: Colors.white30, fontSize: 10),
                ),
                value: widget.autoPlayOnCompletion,
                onChanged: widget.onAutoPlayOnCompletionChanged,
                activeThumbColor: Colors.blueAccent,
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                visualDensity: VisualDensity.compact,
              ),
              SwitchListTile(
                title: const Text(
                  "自动连播时从头开始播放",
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                subtitle: Text(
                  widget.autoPlayOnCompletion
                      ? "开启后目标媒体总是从头开始；关闭则沿用记录的播放点（已播完或接近结尾时仍从头开始）"
                      : "请先开启上方的自动连播",
                  style: const TextStyle(color: Colors.white30, fontSize: 10),
                ),
                value: widget.autoPlayOnCompletionFromStart,
                onChanged: widget.autoPlayOnCompletion
                    ? widget.onAutoPlayOnCompletionFromStartChanged
                    : null,
                activeThumbColor: Colors.blueAccent,
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                visualDensity: VisualDensity.compact,
              ),
              SwitchListTile(
                title: const Text(
                  "进度条拖动预览",
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                subtitle: const Text(
                  "拖动进度条时显示缩略图",
                  style: TextStyle(color: Colors.white30, fontSize: 10),
                ),
                value: widget.enableSeekPreview,
                onChanged: widget.onEnableSeekPreviewChanged,
                activeThumbColor: Colors.blueAccent,
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                visualDensity: VisualDensity.compact,
              ),
              if (widget.showMobilePlaybackControls)
                SwitchListTile(
                  title: const Text(
                    "震动开关",
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  subtitle: const Text(
                    "控制软件内的所有震动反馈",
                    style: TextStyle(color: Colors.white30, fontSize: 10),
                  ),
                  value: widget.enableHapticFeedback,
                  onChanged: widget.onEnableHapticFeedbackChanged,
                  activeThumbColor: Colors.blueAccent,
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  visualDensity: VisualDensity.compact,
                ),
              SwitchListTile(
                title: const Text(
                  "左手模式",
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                subtitle: const Text(
                  "镜像侧栏与控制按钮布局",
                  style: TextStyle(color: Colors.white30, fontSize: 10),
                ),
                value: widget.isLeftHandedMode,
                onChanged: widget.onLeftHandedModeChanged,
                activeThumbColor: Colors.blueAccent,
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildVideoDecoderSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionTitle("解码方式", Icons.memory),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _buildCompactChip(
                      label: "硬件优先（默认）",
                      isSelected: widget.useHardwareVideoDecoding,
                      onTap: () {
                        if (!widget.useHardwareVideoDecoding) {
                          unawaited(widget.onVideoDecoderChanged(true));
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildCompactChip(
                      label: "软件解码",
                      isSelected: !widget.useHardwareVideoDecoding,
                      onTap: () {
                        if (widget.useHardwareVideoDecoding) {
                          unawaited(widget.onVideoDecoderChanged(false));
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                widget.useHardwareVideoDecoding
                    ? "优先使用系统硬件解码器；Android 硬解在首帧前失败时，播放器会以软件解码重新打开一次。"
                    : "强制由 CPU 软件解码。适合排查驱动兼容问题；播放 4K AV1 时可能明显发热或无法实时解码。",
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 10,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSectionTitle(String text, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(icon, size: 14, color: Colors.blueAccent.withValues(alpha: 0.8)),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactChip({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
    Widget? trailing,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.blueAccent
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? Colors.blueAccent : Colors.white10,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.white70,
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 4), trailing],
          ],
        ),
      ),
    );
  }

  List<double> _availablePlaybackSpeeds() {
    final speeds = List<double>.of(kPlaybackSpeedPresets);
    void addIfMissing(double speed) {
      if (!speeds.any((candidate) => (candidate - speed).abs() < 0.001)) {
        speeds.add(speed);
      }
    }

    addIfMissing(widget.playbackSpeed);
    if (widget.isPlaybackSpeedLocked && widget.lockedPlaybackSpeed != null) {
      addIfMissing(widget.lockedPlaybackSpeed!);
    }
    speeds.sort();
    return speeds;
  }

  String _playbackSpeedHint() {
    final lockedSpeed = widget.lockedPlaybackSpeed;
    if (widget.isPlaybackSpeedLocked &&
        lockedSpeed != null &&
        (lockedSpeed - widget.playbackSpeed).abs() >= 0.001) {
      return '当前为临时倍速；全局仍锁定 ${lockedSpeed}x，勾选可切换锁定';
    }
    if (widget.isPlaybackSpeedLocked) return '当前倍速已设为全局倍速';
    return '点击仅调整当前播放；勾选当前倍速后设为全局倍速';
  }

  Widget _buildSpeedLockCheckbox(double speed) {
    final isLocked =
        widget.isPlaybackSpeedLocked &&
        widget.lockedPlaybackSpeed != null &&
        (speed - widget.lockedPlaybackSpeed!).abs() < 0.001;
    return SizedBox(
      width: 24,
      height: 24,
      child: Transform.scale(
        scale: 0.78,
        child: Checkbox(
          value: isLocked,
          onChanged: _speedLockOperationInProgress
              ? null
              : (value) => unawaited(_setSpeedLock(speed, value ?? false)),
          activeColor: Colors.white,
          checkColor: Colors.blueAccent,
          side: const BorderSide(color: Colors.white70, width: 1.5),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }

  Future<void> _setSpeedLock(double speed, bool locked) async {
    if (_speedLockOperationInProgress) return;
    setState(() => _speedLockOperationInProgress = true);
    try {
      await widget.onSpeedLockChanged(speed, locked);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('保存全局倍速失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _speedLockOperationInProgress = false);
    }
  }

  Widget _buildCompactTextField(
    TextEditingController controller,
    ValueChanged<String> onSubmitted,
  ) {
    return SizedBox(
      width: 45,
      height: 28,
      child: TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        style: const TextStyle(color: Colors.white, fontSize: 12),
        textAlign: TextAlign.center,
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 0,
          ),
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.05),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: const BorderSide(color: Colors.white10),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: const BorderSide(color: Colors.blueAccent),
          ),
        ),
        onSubmitted: onSubmitted,
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white24),
            borderRadius: BorderRadius.circular(6),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: Colors.white70),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMirrorButton({
    required IconData icon,
    required String label,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: isActive
              ? Colors.blueAccent.withValues(alpha: 0.2)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isActive ? Colors.blueAccent : Colors.transparent,
            width: 1,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              color: isActive ? Colors.blueAccent : Colors.white70,
              size: 20,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: isActive ? Colors.blueAccent : Colors.white60,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
