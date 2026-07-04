# 音频播放功能实现方案

## 📋 概述

为视频播放软件添加一个功能完整、高度可定制的音频播放功能，使用背景特效替代视频画面，保持与视频播放器一致的用户体验。

## 🎯 核心设计理念

1. **最大化代码复用** - 复用字幕解析、样式管理、AI转录等核心逻辑
2. **保持交互一致性** - 控制栏、手势操作、侧边栏与视频播放器完全一致
3. **高度可定制** - 背景和字幕特效支持丰富的自定义选项
4. **流畅美观** - 使用高性能渲染和动画

## 🏗️ 架构设计

```
AudioPlayerScreen (新建)
├── AudioPlayerController (使用 audioplayers 包)
├── AudioBackgroundLayer (新建 - 背景特效层)
│   ├── 静态图片背景
│   ├── 渐变色背景
│   ├── 动态粒子效果
│   └── 音频可视化波形
├── SubtitleOverlay (复用现有组件)
├── VideoControlsOverlay (复用现有组件)
└── Sidebar (复用现有侧边栏系统)
    ├── SubtitleSidebar
    ├── SubtitleSettingsSheet
    ├── SubtitlePositionSidebar
    └── AiTranscriptionPanel
```

## 📝 详细实现计划

### 1. 创建音频播放器页面
**文件**: `lib/screens/audio_player_screen.dart`

**核心功能**:
- 使用 `audioplayers` 包替代 `video_player`
- 保持与 `VideoPlayerScreen` 相同的状态管理
- 支持相同的控制栏和手势操作
- 复用字幕加载、解析、显示逻辑
- 复用 AI 转录功能

**关键差异**:
- 用 `AudioPlayerController` 替代 `VideoPlayerController`
- 添加背景层（替代视频层）
- 音频可视化波形（可选）

### 2. 创建背景特效组件
**文件**: `lib/widgets/audio_background_layer.dart`

**支持的背景类型**:
1. **纯色背景** - 可自定义颜色
2. **渐变背景** - 线性/径向渐变，可自定义颜色和方向
3. **图片背景** - 支持本地图片、网络图片，可调整透明度和模糊
4. **动态粒子效果** - 流畅的粒子动画
5. **音频可视化** - 根据音频波形动态变化的视觉效果

**自定义选项**:
- 背景类型选择
- 颜色配置（主色、副色）
- 渐变方向/角度
- 图片透明度、模糊度
- 粒子数量、速度、颜色
- 可视化样式（波形、柱状图、圆形）

### 3. 创建背景设置面板
**文件**: `lib/widgets/audio_background_settings_sheet.dart`

**设置项**:
- 背景类型切换
- 颜色选择器
- 渐变角度滑块
- 图片选择器
- 透明度/模糊度滑块
- 粒子效果配置
- 音频可视化配置
- 预设方案（如：极简、赛博朋克、自然、音乐等）

### 4. 扩展设置服务
**文件**: `lib/services/settings_service.dart`

**新增配置**:
```dart
// 音频播放器设置
String audioBackgroundType = 'gradient'; // solid, gradient, image, particles, visualizer
List<Color> audioBackgroundColors = [Color(0xFF1A237E), Color(0xFF311B92)];
double audioBackgroundAngle = 45.0;
String? audioBackgroundImagePath;
double audioBackgroundImageOpacity = 0.3;
double audioBackgroundImageBlur = 10.0;

// 粒子效果设置
bool audioParticlesEnabled = true;
int audioParticleCount = 50;
double audioParticleSpeed = 1.0;
Color audioParticleColor = Colors.white70;

// 音频可视化设置
bool audioVisualizerEnabled = false;
String audioVisualizerStyle = 'wave'; // wave, bars, circle
Color audioVisualizerColor = Colors.blueAccent;
```

### 5. 创建音频播放器模型
**文件**: `lib/models/audio_item.dart`

```dart
class AudioItem {
  final String id;
  final String path;
  final String title;
  final String? artist;
  final String? album;
  final String? thumbnailPath;
  final Duration duration;
  final String? subtitlePath;
  final String? secondarySubtitlePath;
  final DateTime createdAt;
}
```

### 6. 修改主入口
**文件**: `lib/main.dart`

- 添加音频文件类型支持到文件选择器
- 在首页添加"音频播放"入口
- 注册音频播放器相关服务

### 7. 创建音频库服务
**文件**: `lib/services/audio_library_service.dart`

- 管理音频文件列表
- 支持导入、删除、收藏
- 支持自动关联字幕文件
- 持久化存储

## 🎨 背景特效详细设计

### 渐变背景
- 支持双色渐变
- 可调整角度（0-360度）
- 支持预设方案（如：日落、海洋、森林等）

### 图片背景
- 支持从相册/文件选择图片
- 可调整透明度（0-100%）
- 可调整模糊度（0-30px）
- 支持图片裁剪/缩放模式

### 粒子效果
- 使用 CustomPainter 绘制
- 粒子数量：10-200
- 粒子大小：2-10px
- 运动速度：0.1-3.0
- 支持粒子连线效果
- 颜色可自定义

### 音频可视化
- 需要使用 `audio_streamer` 或类似包获取音频数据
- 支持三种样式：
  - **波形图** - 经典的示波器效果
  - **柱状图** - 频谱柱状图
  - **圆形** - 径向频谱图
- 可自定义颜色和灵敏度

## 🔧 技术实现要点

### 1. 音频播放器集成
使用 `audioplayers: ^5.2.1` 包：
```dart
final audioPlayer = AudioPlayer();
await audioPlayer.setSource(DeviceFileSource(audioPath));
await audioPlayer.resume();
```

### 2. 字幕同步
- 音频播放器提供 `position` 流
- 与视频播放器相同的字幕更新逻辑
- 支持字幕偏移调整

### 3. 性能优化
- 使用 `RepaintBoundary` 缓存背景层
- 粒子效果使用 `Canvas` 绘制而非大量 Widget
- 可视化使用 `StreamBuilder` 避免过度重建
- 控制栏使用 `AnimatedBuilder` 监听播放状态

### 4. 状态管理
- 复用现有的 Provider 模式
- 音频播放器状态独立管理
- 字幕状态与视频播放器共享

## 📦 需要添加的依赖

在 `pubspec.yaml` 中添加：
```yaml
dependencies:
  audioplayers: ^5.2.1
  audio_streamer: ^1.0.0  # 用于音频可视化（可选）
  flutter_colorpicker: ^1.0.3  # 用于颜色选择
```

## 🎯 实现步骤

### 阶段一：基础框架（核心功能）
1. 创建 `AudioPlayerScreen` 基础结构
2. 集成 `audioplayers` 并实现基本播放控制
3. 复用 `VideoControlsOverlay` 并适配音频播放器
4. 复用 `SubtitleOverlay` 实现字幕显示
5. 实现字幕加载和解析（复用现有逻辑）

### 阶段二：背景系统（视觉效果）
6. 创建 `AudioBackgroundLayer` 组件
7. 实现纯色和渐变背景
8. 实现图片背景（带透明度和模糊）
9. 创建背景设置面板

### 阶段三：高级特效（流畅美观）
10. 实现粒子效果
11. 实现音频可视化（可选）
12. 添加背景预设方案
13. 优化动画性能

### 阶段四：完整集成（功能完善）
14. 复用侧边栏系统（字幕列表、设置等）
15. 复用 AI 转录功能
16. 创建音频库管理
17. 在首页添加音频播放入口
18. 完善设置持久化

### 阶段五：测试优化（严谨验证）
19. 测试字幕同步准确性
20. 测试各种背景效果性能
21. 测试手势操作流畅性
22. 测试 AI 转录功能
23. 优化内存占用和帧率

## 🎨 UI/UX 设计建议

### 背景预设方案
1. **极简** - 纯深色背景，突出字幕。支持各种预设色调，或者让用户自行选择色调，或者输入色号。
2. **日落** - 橙紫渐变
3. **海洋** - 蓝青渐变
4. **森林** - 绿黄渐变
5. **赛博朋克** - 紫粉渐变 + 粒子
6. **音乐** - 音频可视化波形（可以叠加在其他背景上，也可以独立显示。并且会适应背景的配色。）

### 字幕与背景协调
- 浅色背景用深色字幕
- 深色背景用浅色字幕
- 支持自动检测背景亮度并调整字幕颜色

## 🌟 预期效果

- 功能完整的音频播放体验
- 与视频播放器一致的交互方式
- 高度可定制的背景特效
- 流畅美观的动画效果
- 支持丰富的字幕功能
- 支持 AI 智能转录
- 良好的性能和稳定性

## 📌 注意事项

1. **权限管理** - 确保应用有读取音频文件和存储的权限
2. **文件格式支持** - 测试常见音频格式（MP3, WAV, FLAC, AAC等）
3. **性能优化** - 特别是动态背景效果，确保在低配置设备上也能流畅运行
4. **内存管理** - 及时释放不再使用的资源，如图片、粒子效果等
5. **用户体验** - 保持界面简洁，避免过度复杂的设置选项
6. **测试覆盖** - 充分测试各种场景，包括异常情况

## 📄 许可证

本实现方案基于项目现有许可证，遵循开源精神，欢迎贡献和改进。