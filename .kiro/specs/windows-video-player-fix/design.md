# 设计文档

## 概述

本设计文档描述了如何修复 Windows 端视频播放器的问题。核心方案是将 Windows 平台的视频播放实现从 `video_player_win` 切换到 `video_player_media_kit`，后者基于 `media_kit` 库，使用 libmpv 作为底层播放引擎。

这个方案的优势在于：
1. `video_player_media_kit` 作为 `video_player` 的平台实现，可以无缝替换现有实现
2. 不需要修改任何使用 `VideoPlayerController` 的业务代码
3. 对 iOS 和 Android 平台完全没有影响

## 架构

### 当前架构

```
┌─────────────────────────────────────────────────────────────┐
│                    应用层 (Dart)                             │
│  VideoPlayerScreen / VideoControlsOverlay                   │
│                         │                                    │
│                         ▼                                    │
│              VideoPlayerController                           │
└─────────────────────────────────────────────────────────────┘
                          │
          ┌───────────────┼───────────────┐
          ▼               ▼               ▼
    ┌──────────┐   ┌──────────┐   ┌──────────────┐
    │   iOS    │   │ Android  │   │   Windows    │
    │ AVPlayer │   │ExoPlayer │   │video_player  │
    │          │   │          │   │    _win      │
    └──────────┘   └──────────┘   └──────────────┘
                                        │
                                        ▼
                                  ┌──────────────┐
                                  │Media Found-  │
                                  │ation API    │
                                  │(编解码器受限)│
                                  └──────────────┘
```

### 目标架构

```
┌─────────────────────────────────────────────────────────────┐
│                    应用层 (Dart)                             │
│  VideoPlayerScreen / VideoControlsOverlay                   │
│                         │                                    │
│                         ▼                                    │
│              VideoPlayerController                           │
└─────────────────────────────────────────────────────────────┘
                          │
          ┌───────────────┼───────────────┐
          ▼               ▼               ▼
    ┌──────────┐   ┌──────────┐   ┌──────────────┐
    │   iOS    │   │ Android  │   │   Windows    │
    │ AVPlayer │   │ExoPlayer │   │video_player  │
    │(不变)    │   │(不变)    │   │ _media_kit   │
    └──────────┘   └──────────┘   └──────────────┘
                                        │
                                        ▼
                                  ┌──────────────┐
                                  │  media_kit   │
                                  │   (libmpv)   │
                                  │(支持所有格式)│
                                  └──────────────┘
```

## 组件和接口

### 1. 依赖配置 (pubspec.yaml)

需要添加以下依赖：

```yaml
dependencies:
  # 保留现有的 video_player
  video_player: ^2.10.1
  
  # 移除 video_player_win（或保留但不使用）
  # video_player_win: ^1.1.6  # 注释掉或删除
  
  # 添加 media_kit 相关依赖
  media_kit: ^1.1.11
  media_kit_video: ^1.2.5
  media_kit_libs_windows_video: ^1.0.10
  video_player_media_kit: ^1.0.5
```

### 2. 初始化配置 (main.dart)

在应用启动时初始化 `video_player_media_kit`：

```dart
import 'dart:io';
import 'package:video_player_media_kit/video_player_media_kit.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 仅在 Windows 平台上使用 media_kit 作为 video_player 的实现
  if (Platform.isWindows) {
    VideoPlayerMediaKit.ensureInitialized(
      // 不影响 iOS 和 Android
      android: false,
      iOS: false,
      macOS: false,
      windows: true,
      linux: true,
    );
  }
  
  runApp(const MyApp());
}
```

### 3. 现有代码兼容性

由于 `video_player_media_kit` 是 `video_player` 的平台实现，所有现有的 `VideoPlayerController` 代码无需修改：

```dart
// 这些代码保持不变
_controller = VideoPlayerController.file(File(path));
await _controller.initialize();
_controller.play();
_controller.pause();
_controller.seekTo(position);
_controller.setPlaybackSpeed(speed);
```

## 数据模型

本次修复不涉及数据模型的变更。所有现有的数据模型（`VideoItem`、`SubtitleModel` 等）保持不变。

## 正确性属性

*正确性属性是一种特征或行为，应该在系统的所有有效执行中保持为真——本质上是关于系统应该做什么的正式声明。属性作为人类可读规范和机器可验证正确性保证之间的桥梁。*

### 属性 1：错误处理健壮性

*对于任意* 无效的视频文件路径或损坏的视频文件，Video_Player 初始化应当返回错误状态而不是抛出未捕获的异常。

**验证: 需求 1.4**

### 属性 2：播放速度往返一致性

*对于任意* 初始播放速度和目标播放速度，设置目标速度后再恢复到初始速度，播放器的速度值应当等于初始速度。

**验证: 需求 2.1, 2.2**

### 属性 3：播放速度范围验证

*对于任意* 在 0.5 到 3.0 范围内的播放速度值，setPlaybackSpeed 调用应当成功，且播放器报告的速度值应当等于设置的值。

**验证: 需求 2.4**

### 属性 4：播放器控制操作一致性

*对于任意* 播放器状态，调用 play() 后 isPlaying 应为 true，调用 pause() 后 isPlaying 应为 false。

**验证: 需求 4.1**

### 属性 5：跳转位置准确性

*对于任意* 有效的视频时间点（在 0 到 duration 范围内），seekTo 调用后播放器的 position 应当接近目标时间点（允许合理的误差范围）。

**验证: 需求 4.2**

### 属性 6：音量控制范围验证

*对于任意* 在 0.0 到 1.0 范围内的音量值，setVolume 调用应当成功，且播放器报告的音量值应当等于设置的值。

**验证: 需求 4.3**

### 属性 7：视频属性有效性

*对于任意* 成功初始化的视频，duration 应当大于 0，aspectRatio 应当大于 0。

**验证: 需求 4.4, 4.5**

## 错误处理

### 初始化错误

当视频初始化失败时，`VideoPlayerController` 会设置 `hasError` 为 true，并在 `errorDescription` 中提供错误信息。现有的错误处理逻辑（如 `_videoListener` 中的 HEVC 修复对话框）应当继续工作。

### 平台检测

使用 `dart:io` 的 `Platform.isWindows` 进行平台检测，确保初始化代码仅在 Windows 平台上执行。

## 测试策略

### 单元测试

1. **平台检测测试**：验证初始化代码仅在 Windows 平台上执行
2. **API 兼容性测试**：验证所有 `VideoPlayerController` 方法签名保持不变

### 属性测试

使用 Dart 的 `test` 包配合 `faker` 或自定义生成器进行属性测试：

1. **错误处理属性测试**：生成各种无效输入，验证错误处理
2. **播放速度属性测试**：生成随机速度值，验证设置和恢复
3. **跳转位置属性测试**：生成随机时间点，验证跳转准确性

### 集成测试

1. **Windows 平台测试**：在 Windows 设备上测试各种视频格式的播放
2. **长按快进测试**：验证变速播放时音频的平滑性
3. **回归测试**：在 iOS 和 Android 设备上验证现有功能不受影响

### 测试框架

- 单元测试和属性测试：`flutter_test` + `test`
- 属性测试生成器：自定义 Dart 生成器
- 每个属性测试至少运行 100 次迭代
