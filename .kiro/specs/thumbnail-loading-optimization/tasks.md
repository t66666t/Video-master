# Implementation Plan: Thumbnail Loading Optimization

## Overview

实现视频缩略图的多级缓存和预加载系统，使用Dart/Flutter。按照以下顺序实现：先创建核心缓存服务，然后是预加载管理器，接着是UI组件，最后集成到现有代码中。

## Tasks

- [-] 1. 创建ThumbnailCacheService核心服务
  - [x] 1.1 创建 `lib/services/thumbnail_cache_service.dart` 文件
    - 实现单例模式
    - 实现LRU内存缓存（使用LinkedHashMap）
    - 实现 `getThumbnail`、`preloadThumbnail`、`evictFromCache`、`clearMemoryCache`、`isInMemoryCache` 方法
    - 配置默认缓存大小为100项
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5_

  - [x] 1.2 编写LRU缓存行为的属性测试
    - **Property 1: LRU Cache Eviction**
    - 测试：对于任意访问序列，当缓存满时，最久未访问的条目应被驱逐
    - **Validates: Requirements 1.1, 1.3, 1.5**

  - [x] 1.3 编写缓存命中测试
    - **Property 2: Cache Hit Returns Same Provider**
    - 测试：对于已缓存的视频ID，连续调用getThumbnail应返回相同的ImageProvider
    - **Validates: Requirements 1.2**

- [x] 2. 创建ThumbnailPreloadManager预加载管理器
  - [x] 2.1 创建 `lib/services/thumbnail_preload_manager.dart` 文件
    - 实现预加载队列和优先级管理
    - 实现并发控制（最大4个并发预加载）
    - 实现 `preloadRange`、`cancelAll`、`updatePriorities` 方法
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5_

  - [x] 2.2 编写并发限制的属性测试
    - **Property 4: Preload Respects Concurrency Limit**
    - 测试：对于任意数量的预加载请求，并发操作数不应超过配置的最大值
    - **Validates: Requirements 2.5**

- [x] 3. 创建CachedThumbnailWidget组件
  - [x] 3.1 创建 `lib/widgets/cached_thumbnail_widget.dart` 文件
    - 实现带占位符的缩略图加载
    - 实现淡入动画效果
    - 实现错误处理和fallback显示
    - 使用ResizeImage优化内存
    - 在dispose时取消pending操作
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5_

- [x] 4. 集成缓存清理到LibraryService
  - [x] 4.1 修改 `lib/services/library_service.dart`
    - 在 `_deleteVideoFiles` 方法中添加 `ThumbnailCacheService().evictFromCache(vid.id)` 调用
    - 确保递归删除文件夹时清理所有子视频的缓存
    - _Requirements: 4.1, 4.2, 4.3_

  - [x] 4.2 编写缓存清理同步的属性测试
    - **Property 3: Eviction Removes Entry Completely**
    - 测试：对于任意视频ID，调用evictFromCache后，isInMemoryCache应返回false
    - **Validates: Requirements 4.2, 4.5**

  - [x] 4.3 编写删除同步的属性测试
    - **Property 5: Thumbnail Deletion Synchronization**
    - 测试：对于任意从回收站永久删除的视频，其磁盘缩略图文件和内存缓存条目都应被移除
    - **Validates: Requirements 4.1, 4.2, 4.3**

- [x] 5. 集成到CollectionScreen
  - [x] 5.1 修改 `lib/screens/collection_screen.dart`
    - 将 `_buildVideoCard` 中的 `Image.file` 替换为 `CachedThumbnailWidget`
    - 在页面初始化时启动预加载
    - 监听滚动事件更新预加载优先级
    - _Requirements: 2.1, 2.3, 3.1, 5.3_

- [x] 6. Checkpoint - 确保所有测试通过
  - 运行所有单元测试和属性测试
  - 验证缩略图加载流畅性
  - 验证删除视频后缓存正确清理
  - 如有问题请询问用户

## Notes

- 所有任务均为必需任务，包括属性测试
- 每个任务都引用了具体的需求以便追溯
- 属性测试使用 `glados` 或 `dart_check` 库
- Checkpoint确保增量验证
