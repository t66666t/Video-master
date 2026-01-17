import 'package:flutter/material.dart';

class SettingsPanel extends StatefulWidget {
  final double playbackSpeed;
  final bool showSubtitles;
  final bool isMirroredH;
  final bool isMirroredV;
  
  final ValueChanged<double> onSpeedChanged;
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

  final bool isHardwareDecoding;
  final ValueChanged<bool> onHardwareDecodingChanged;

  final double longPressSpeed;
  final ValueChanged<double> onLongPressSpeedChanged;
  
  // New: Auto Cache
  final bool autoCacheSubtitles;
  final ValueChanged<bool> onAutoCacheSubtitlesChanged;

  final bool splitSubtitleByLine;
  final ValueChanged<bool> onSplitSubtitleByLineChanged;

  final bool continuousSubtitle;
  final ValueChanged<bool> onContinuousSubtitleChanged;

  final bool autoPauseOnExit;
  final ValueChanged<bool> onAutoPauseOnExitChanged;

  final bool autoPlayNextVideo;
  final ValueChanged<bool> onAutoPlayNextVideoChanged;

  const SettingsPanel({
    super.key,
    required this.playbackSpeed,
    required this.showSubtitles,
    required this.isMirroredH,
    required this.isMirroredV,
    required this.onSpeedChanged,
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
    required this.isHardwareDecoding,
    required this.onHardwareDecodingChanged,
    required this.longPressSpeed,
    required this.onLongPressSpeedChanged,
    required this.autoCacheSubtitles,
    required this.onAutoCacheSubtitlesChanged,
    required this.splitSubtitleByLine,
    required this.onSplitSubtitleByLineChanged,
    required this.continuousSubtitle,
    required this.onContinuousSubtitleChanged,
    required this.autoPauseOnExit,
    required this.onAutoPauseOnExitChanged,
    required this.autoPlayNextVideo,
    required this.onAutoPlayNextVideoChanged,
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

  @override
  void initState() {
    super.initState();
    _speedController = TextEditingController(text: widget.playbackSpeed.toString());
    _longPressSpeedController = TextEditingController(text: widget.longPressSpeed.toString());
    _seekSecondsController = TextEditingController(text: widget.doubleTapSeekSeconds.toString());
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
       if (!_longPressSpeedController.text.startsWith(widget.longPressSpeed.toString())) {
          _longPressSpeedController.text = widget.longPressSpeed.toString();
       }
    }
    if (oldWidget.doubleTapSeekSeconds != widget.doubleTapSeekSeconds) {
       if (!_seekSecondsController.text.startsWith(widget.doubleTapSeekSeconds.toString())) {
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
    
    final panelWidth = isSmallScreen 
        ? (screenWidth * 0.75).clamp(240.0, 300.0) 
        : 320.0;
        
    final paddingValue = isSmallScreen ? 8.0 : 20.0;
    final spacingValue = isSmallScreen ? 12.0 : 24.0;

    return Container(
      width: double.infinity, 
      color: const Color(0xFF1E1E1E),
      child: Column(
        children: [
          // Header
          Container(
            padding: EdgeInsets.fromLTRB(paddingValue, paddingValue, 8, paddingValue / 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                 const Text(
                  "播放设置",
                  style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white70, size: 18),
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
              padding: EdgeInsets.symmetric(horizontal: paddingValue, vertical: 8),
              children: [
                // 1. 播放速度
                _buildSectionTitle("播放速度", Icons.speed),
                Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0].map((speed) {
                            return _buildCompactChip(
                              label: "${speed}x",
                              isSelected: (speed - widget.playbackSpeed).abs() < 0.1,
                              onTap: () => widget.onSpeedChanged(speed),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildCompactTextField(_speedController, (val) {
                      final speed = double.tryParse(val);
                      if (speed != null && speed > 0) widget.onSpeedChanged(speed);
                    }),
                  ],
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
                              isSelected: (speed - widget.longPressSpeed).abs() < 0.1,
                              onTap: () => widget.onLongPressSpeedChanged(speed),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildCompactTextField(_longPressSpeedController, (val) {
                      final speed = double.tryParse(val);
                      if (speed != null && speed > 0) widget.onLongPressSpeedChanged(speed);
                    }),
                  ],
                ),

                SizedBox(height: spacingValue),
                
                // 2.5 播放行为
                _buildSectionTitle("播放行为", Icons.play_circle_outline),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.04),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Column(
                    children: [
                      SwitchListTile(
                        title: const Text("退出页面自动暂停", style: TextStyle(color: Colors.white70, fontSize: 13)),
                        subtitle: const Text("退出播放页面时自动暂停视频", style: TextStyle(color: Colors.white30, fontSize: 10)),
                        value: widget.autoPauseOnExit,
                        onChanged: widget.onAutoPauseOnExitChanged,
                        activeColor: Colors.blueAccent,
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                        visualDensity: VisualDensity.compact,
                      ),
                      SwitchListTile(
                        title: const Text("切换上下集自动播放", style: TextStyle(color: Colors.white70, fontSize: 13)),
                        subtitle: const Text("切换到上/下一集时自动开始播放", style: TextStyle(color: Colors.white30, fontSize: 10)),
                        value: widget.autoPlayNextVideo,
                        onChanged: widget.onAutoPlayNextVideoChanged,
                        activeColor: Colors.blueAccent,
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ),
                
                SizedBox(height: spacingValue),
                
                // 3. 字幕设置
                _buildSectionTitle("字幕设置", Icons.subtitles),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.04),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Column(
                    children: [
                      SwitchListTile(
                        title: const Text("字幕连续显示", style: TextStyle(color: Colors.white70, fontSize: 13)),
                        subtitle: const Text("字幕结束时间延后到下一条字幕开始", style: TextStyle(color: Colors.white30, fontSize: 10)),
                        value: widget.continuousSubtitle,
                        onChanged: widget.onContinuousSubtitleChanged,
                        activeColor: Colors.blueAccent,
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                        visualDensity: VisualDensity.compact,
                      ),
                      SwitchListTile(
                        title: const Text("显示字幕", style: TextStyle(color: Colors.white70, fontSize: 13)),
                        value: widget.showSubtitles,
                        onChanged: widget.onSubtitleToggle,
                        activeColor: Colors.blueAccent,
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                        visualDensity: VisualDensity.compact,
                      ),
                      SwitchListTile(
                        title: const Text("自动缓存字幕", style: TextStyle(color: Colors.white70, fontSize: 13)),
                        subtitle: const Text("导入后自动复制到本地", style: TextStyle(color: Colors.white30, fontSize: 10)),
                        value: widget.autoCacheSubtitles,
                        onChanged: widget.onAutoCacheSubtitlesChanged,
                        activeColor: Colors.blueAccent,
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                        visualDensity: VisualDensity.compact,
                      ),
                      SwitchListTile(
                        title: const Text("识别第一行为主字幕", style: TextStyle(color: Colors.white70, fontSize: 13)),
                        subtitle: const Text("第二行为副字幕。关闭则全部为主字幕", style: TextStyle(color: Colors.white30, fontSize: 10)),
                        value: widget.splitSubtitleByLine,
                        onChanged: widget.onSplitSubtitleByLineChanged,
                        activeColor: Colors.blueAccent,
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
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
                _buildSectionTitle("字幕同步 (${widget.subtitleDelay > 0 ? '+' : ''}${widget.subtitleDelay.toStringAsFixed(2)}s)", Icons.sync),
                SizedBox(
                  height: 30,
                  child: Row(
                    children: [
                      const Text("-5s", style: TextStyle(color: Colors.white38, fontSize: 10)),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 2,
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
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
                      const Text("+5s", style: TextStyle(color: Colors.white38, fontSize: 10)),
                    ],
                  ),
                ),
                
                SizedBox(height: spacingValue),

                // 5. 解码方式
                _buildSectionTitle("解码方式", Icons.memory),
                Row(
                  children: [
                    Expanded(
                      child: _buildMirrorButton(
                        icon: Icons.memory,
                        label: "硬件解码 (默认)",
                        isActive: widget.isHardwareDecoding,
                        onTap: () {
                           // Hardware decoding is default, logic handled by OS/player.
                           // Just update state for UI consistency, though it doesn't force player re-init currently.
                           widget.onHardwareDecodingChanged(true);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildMirrorButton(
                        icon: Icons.computer,
                        label: "软件解码",
                        isActive: !widget.isHardwareDecoding,
                        onTap: () {
                           // Software decoding isn't explicitly exposed by video_player package in initialization.
                           // This toggle is mainly a placeholder or for future custom implementations.
                           widget.onHardwareDecodingChanged(false);
                        },
                      ),
                    ),
                  ],
                ),
                Padding(
                   padding: const EdgeInsets.only(top: 8, left: 4),
                   child: Text(
                      "注: 播放器默认自动选择最佳解码方式。如遇播放问题，请尝试转码。",
                      style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 10),
                   ),
                ),
                
                SizedBox(height: spacingValue),
                
                // 5.5 双击跳转字幕
                SwitchListTile(
                  title: const Text("双击跳转上一句/下一句", style: TextStyle(color: Colors.white70, fontSize: 13)),
                  subtitle: const Text("开启后，双击左侧跳转上一句字幕，双击右侧跳转下一句", style: TextStyle(color: Colors.white30, fontSize: 10)),
                  value: widget.enableDoubleTapSubtitleSeek,
                  onChanged: widget.onDoubleTapSubtitleSeekChanged,
                  activeColor: Colors.blueAccent,
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
                              isSelected: seconds == widget.doubleTapSeekSeconds,
                              onTap: () => widget.onSeekSecondsChanged(seconds),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildCompactTextField(_seekSecondsController, (val) {
                      final seconds = int.tryParse(val);
                      if (seconds != null && seconds > 0) widget.onSeekSecondsChanged(seconds);
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
                        onTap: () => widget.onMirrorHChanged(!widget.isMirroredH),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildMirrorButton(
                        icon: Icons.flip_camera_android,
                        label: "垂直翻转",
                        isActive: widget.isMirroredV,
                        onTap: () => widget.onMirrorVChanged(!widget.isMirroredV),
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

  Widget _buildSectionTitle(String text, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(icon, size: 14, color: Colors.blueAccent.withOpacity(0.8)),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactChip({required String label, required bool isSelected, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blueAccent : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: isSelected ? Colors.blueAccent : Colors.white10),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white70,
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildCompactTextField(TextEditingController controller, ValueChanged<String> onSubmitted) {
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
          contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
          filled: true,
          fillColor: Colors.white.withOpacity(0.05),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: const BorderSide(color: Colors.white10)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: const BorderSide(color: Colors.blueAccent)),
        ),
        onSubmitted: onSubmitted,
      ),
    );
  }

  Widget _buildActionButton({required IconData icon, required String label, required VoidCallback? onTap}) {
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
              Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMirrorButton({required IconData icon, required String label, required bool isActive, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: isActive ? Colors.blueAccent.withOpacity(0.2) : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isActive ? Colors.blueAccent : Colors.transparent,
            width: 1,
          ),
        ),
        child: Column(
          children: [
            Icon(icon, color: isActive ? Colors.blueAccent : Colors.white70, size: 20),
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
