# Requirements Document

## Introduction

本功能旨在优化视频播放器应用中视频缩略图的加载体验。当用户进入包含大量视频的文件夹时，视频卡片的封面（缩略图）加载缓慢且卡顿，影响用户体验。通过实现多级缓存机制、预加载策略和懒加载优化，使缩略图加载流畅无感。同时确保当视频从回收站永久删除时，对应的缩略图缓存也被正确清理。

## Glossary

- **Thumbnail_Cache_Service**: 缩略图缓存服务，负责管理缩略图的内存缓存、磁盘缓存和预加载
- **Memory_Cache**: 内存缓存，使用LRU策略存储最近访问的缩略图图像数据
- **Disk_Cache**: 磁盘缓存，存储在应用文档目录下的thumbnails文件夹中的缩略图文件
- **Preload_Manager**: 预加载管理器，负责在后台预先加载即将显示的缩略图
- **Thumbnail_Widget**: 缩略图组件，负责显示缩略图并处理加载状态
- **Library_Service**: 视频库服务，管理视频和文件夹的增删改查操作
- **Video_Item**: 视频项数据模型，包含视频路径、缩略图路径等信息

## Requirements

### Requirement 1: 内存缓存机制

**User Story:** As a user, I want thumbnails to load instantly when scrolling through videos, so that I can browse my video library smoothly without waiting.

#### Acceptance Criteria

1. THE Thumbnail_Cache_Service SHALL maintain an in-memory LRU cache for thumbnail images
2. WHEN a thumbnail is requested, THE Thumbnail_Cache_Service SHALL first check the Memory_Cache before accessing disk
3. WHEN the Memory_Cache reaches its maximum capacity, THE Thumbnail_Cache_Service SHALL evict the least recently used entries
4. THE Memory_Cache SHALL have a configurable maximum size limit based on available device memory
5. WHEN a cached thumbnail is accessed, THE Thumbnail_Cache_Service SHALL update its position in the LRU order

### Requirement 2: 预加载策略

**User Story:** As a user, I want thumbnails to be ready before I scroll to them, so that I experience seamless browsing without visible loading delays.

#### Acceptance Criteria

1. WHEN a folder is opened, THE Preload_Manager SHALL begin preloading thumbnails for visible items plus a buffer zone
2. THE Preload_Manager SHALL preload thumbnails in batches to avoid blocking the main thread
3. WHEN the user scrolls, THE Preload_Manager SHALL adjust preload priorities based on scroll direction
4. THE Preload_Manager SHALL cancel pending preload requests for items that are no longer near the viewport
5. THE Preload_Manager SHALL limit concurrent preload operations to prevent resource exhaustion

### Requirement 3: 优化的缩略图组件

**User Story:** As a user, I want to see a smooth transition when thumbnails appear, so that the loading process feels polished and professional.

#### Acceptance Criteria

1. THE Thumbnail_Widget SHALL display a placeholder while the thumbnail is loading
2. WHEN a thumbnail finishes loading, THE Thumbnail_Widget SHALL fade in the image smoothly
3. IF a thumbnail fails to load, THEN THE Thumbnail_Widget SHALL display a fallback icon
4. THE Thumbnail_Widget SHALL use appropriate image sizing to minimize memory usage
5. WHEN the Thumbnail_Widget is disposed, THE Thumbnail_Widget SHALL cancel any pending load operations

### Requirement 4: 缓存清理机制

**User Story:** As a user, I want the app to automatically clean up unused cache data when I permanently delete videos, so that my device storage is not wasted.

#### Acceptance Criteria

1. WHEN a video is permanently deleted from the recycle bin, THE Library_Service SHALL delete its corresponding thumbnail file from Disk_Cache
2. WHEN a video is permanently deleted, THE Thumbnail_Cache_Service SHALL remove its entry from Memory_Cache
3. WHEN a folder is permanently deleted from the recycle bin, THE Library_Service SHALL delete thumbnails for all videos within that folder recursively
4. THE Thumbnail_Cache_Service SHALL provide a method to clear all cached thumbnails
5. IF a thumbnail file is missing from disk, THEN THE Thumbnail_Cache_Service SHALL gracefully handle the error and remove the invalid cache entry

### Requirement 5: 性能优化

**User Story:** As a user, I want the app to remain responsive even when browsing folders with hundreds of videos, so that I can manage large video libraries efficiently.

#### Acceptance Criteria

1. THE Thumbnail_Widget SHALL decode images in an isolate to avoid blocking the UI thread
2. THE Thumbnail_Cache_Service SHALL use efficient image formats and compression for cached thumbnails
3. WHEN loading thumbnails, THE system SHALL prioritize visible items over off-screen items
4. THE Memory_Cache SHALL automatically reduce its size when the system reports low memory conditions
5. THE Preload_Manager SHALL throttle preload operations when the device is under heavy load
