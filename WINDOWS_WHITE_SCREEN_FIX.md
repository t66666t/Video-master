# Windows白屏问题修复说明

## 问题描述
Windows版本启动时出现白屏,应用无响应。

## 根本原因
应用启动时有多个阻塞操作:

1. **B站登录状态检查** - 网络请求可能超时
2. **剪贴板B站链接解析** - 网络请求可能超时  
3. **播放状态恢复** - 视频播放器初始化可能卡住

这些操作都在主线程同步执行,导致UI无法渲染。

## 修复内容

### 1. lib/screens/home_screen.dart

#### 修复 `_checkBilibiliLogin()` 方法
- 添加5秒超时处理
- 添加完整的try-catch错误处理
- 超时时返回false,不阻塞UI

```dart
final isValid = await service.apiService.checkLoginStatus()
    .timeout(const Duration(seconds: 5), onTimeout: () {
  debugPrint('B站登录状态检查超时');
  return false;
});
```

#### 修复 `_checkClipboard()` 方法
- 为所有网络请求添加超时
- 添加完整的try-catch包裹整个方法
- 确保任何错误都不会影响应用启动

```dart
try {
  final hasCookie = await service.apiService.hasCookie()
      .timeout(const Duration(seconds: 2), onTimeout: () => false);
  // ... 其他代码
  final task = await service.parseSingleLine(content)
      .timeout(const Duration(seconds: 5), onTimeout: () => null);
} catch (e) {
  debugPrint('剪贴板检查失败: $e');
}
```

### 2. lib/main.dart

#### 修复 `_restorePlaybackState()` 调用
- 将await改为非阻塞调用
- 让播放状态恢复在后台异步执行
- 添加错误处理,确保失败不影响应用启动

```dart
// 之前: await _restorePlaybackState(...)
// 现在: 非阻塞调用
_restorePlaybackState(
  mediaPlaybackService: mediaPlaybackService,
  progressTracker: progressTracker,
  playlistManager: playlistManager,
  library: library,
).catchError((e) {
  debugPrint('恢复播放状态失败: $e');
});
```

## 测试方法

1. 断开网络连接
2. 启动应用
3. 应用应该能正常显示主界面,不会白屏
4. 5秒后会在控制台看到超时日志

## 影响范围

- ✅ 不影响Android版本
- ✅ 不影响iOS版本  
- ✅ 只修复Windows启动流程
- ✅ 保留所有原有功能

## 后续建议

1. 考虑将所有网络请求都添加超时处理
2. 考虑在应用启动时显示加载指示器
3. 考虑将B站功能改为懒加载,只在用户需要时初始化
