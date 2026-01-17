import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// 缩略图缓存服务
/// 
/// 使用LRU（最近最少使用）策略管理内存缓存，提供高效的缩略图加载和缓存功能。
/// 单例模式确保全局唯一实例。
class ThumbnailCacheService {
  // 单例实例
  static final ThumbnailCacheService _instance = ThumbnailCacheService._internal();
  
  /// 获取单例实例
  factory ThumbnailCacheService() => _instance;
  
  ThumbnailCacheService._internal();

  /// LRU内存缓存：videoId -> ImageProvider
  /// 使用LinkedHashMap实现LRU，accessOrder=true确保访问顺序
  final LinkedHashMap<String, ImageProvider> _memoryCache = LinkedHashMap<String, ImageProvider>();

  final Map<String, String?> _thumbnailPathById = {};
  
  /// 最大缓存条目数，默认100项
  int _maxCacheSize = 100;
  
  /// 获取当前最大缓存大小
  int get maxCacheSize => _maxCacheSize;
  
  /// 获取当前缓存条目数
  int get cacheSize => _memoryCache.length;
  
  /// 设置最大缓存大小
  /// 
  /// 如果新的大小小于当前缓存条目数，会自动驱逐多余的条目
  void setMaxCacheSize(int size) {
    if (size <= 0) {
      throw ArgumentError('缓存大小必须大于0');
    }
    _maxCacheSize = size;
    _evictIfNeeded();
  }

  /// 获取缩略图
  /// 
  /// 首先检查内存缓存，如果命中则直接返回（并更新LRU顺序）。
  /// 如果未命中且thumbnailPath有效，则从磁盘加载并缓存。
  /// 
  /// [videoId] 视频的唯一标识符
  /// [thumbnailPath] 缩略图文件路径，可为null
  /// 
  /// 返回ImageProvider，如果无法加载则返回null
  Future<ImageProvider?> getThumbnail(String videoId, String? thumbnailPath) async {
    final cached = getThumbnailFromMemory(videoId, thumbnailPath);
    if (cached != null) return cached;
    
    // 2. 如果没有缩略图路径，返回null
    if (thumbnailPath == null || thumbnailPath.isEmpty) {
      return null;
    }
    
    // 3. 检查文件是否存在
    final file = File(thumbnailPath);
    if (!await file.exists()) {
      debugPrint('缩略图文件不存在: $thumbnailPath');
      return null;
    }
    
    // 4. 从磁盘加载并缓存
    try {
      final provider = FileImage(file);
      _addToCache(videoId, provider, thumbnailPath: thumbnailPath);
      return provider;
    } catch (e) {
      debugPrint('加载缩略图失败: $e');
      return null;
    }
  }

  ImageProvider? getThumbnailFromMemory(String videoId, String? thumbnailPath) {
    final provider = _memoryCache[videoId];
    if (provider == null) return null;

    final cachedPath = _thumbnailPathById[videoId];
    if (thumbnailPath != null &&
        thumbnailPath.isNotEmpty &&
        cachedPath != null &&
        cachedPath.isNotEmpty &&
        cachedPath != thumbnailPath) {
      _memoryCache.remove(videoId);
      _thumbnailPathById.remove(videoId);
      return null;
    }

    _memoryCache.remove(videoId);
    _memoryCache[videoId] = provider;
    return provider;
  }

  /// 预加载缩略图到内存缓存
  /// 
  /// 用于后台预加载即将显示的缩略图，不阻塞UI。
  /// 
  /// [videoId] 视频的唯一标识符
  /// [thumbnailPath] 缩略图文件路径
  Future<void> preloadThumbnail(String videoId, String? thumbnailPath) async {
    // 如果已在缓存中，无需重复加载
    if (getThumbnailFromMemory(videoId, thumbnailPath) != null) {
      return;
    }
    
    // 如果没有路径，跳过
    if (thumbnailPath == null || thumbnailPath.isEmpty) {
      return;
    }
    
    // 检查文件是否存在
    final file = File(thumbnailPath);
    if (!await file.exists()) {
      return;
    }
    
    // 加载并缓存
    try {
      final provider = FileImage(file);
      _addToCache(videoId, provider, thumbnailPath: thumbnailPath);
    } catch (e) {
      debugPrint('预加载缩略图失败: $e');
    }
  }

  /// 从缓存中移除指定视频的缩略图
  /// 
  /// 当视频被删除时调用，确保缓存与数据同步。
  /// 
  /// [videoId] 要移除的视频ID
  void evictFromCache(String videoId) {
    final removed = _memoryCache.remove(videoId);
    _thumbnailPathById.remove(videoId);
    if (removed != null) {
      debugPrint('已从缓存移除缩略图: $videoId');
    }
  }

  /// 清空所有内存缓存
  /// 
  /// 在内存紧张或需要完全重置时调用。
  void clearMemoryCache() {
    _memoryCache.clear();
    _thumbnailPathById.clear();
    debugPrint('已清空所有缩略图缓存');
  }

  /// 检查指定视频的缩略图是否在内存缓存中
  /// 
  /// [videoId] 视频的唯一标识符
  /// 
  /// 返回true表示在缓存中，false表示不在
  bool isInMemoryCache(String videoId) {
    return _memoryCache.containsKey(videoId);
  }

  /// 批量预加载缩略图
  /// 
  /// 用于一次性预加载多个缩略图，内部会过滤已缓存的项。
  /// 
  /// [items] 包含videoId和thumbnailPath的Map列表
  Future<void> preloadBatch(List<Map<String, String?>> items) async {
    for (final item in items) {
      final videoId = item['videoId'];
      final thumbnailPath = item['thumbnailPath'];
      if (videoId != null) {
        await preloadThumbnail(videoId, thumbnailPath);
      }
    }
  }

  /// 获取所有缓存的视频ID列表（用于调试）
  List<String> getCachedIds() {
    return _memoryCache.keys.toList();
  }

  /// 添加条目到缓存，并在需要时驱逐旧条目
  void _addToCache(String videoId, ImageProvider provider, {String? thumbnailPath}) {
    // 如果已存在，先移除（更新LRU顺序）
    _memoryCache.remove(videoId);
    _thumbnailPathById.remove(videoId);
    
    // 添加到缓存末尾（最近使用）
    _memoryCache[videoId] = provider;
    _thumbnailPathById[videoId] = thumbnailPath;
    
    // 检查是否需要驱逐
    _evictIfNeeded();
  }

  /// 如果缓存超出限制，驱逐最久未使用的条目
  void _evictIfNeeded() {
    while (_memoryCache.length > _maxCacheSize) {
      // LinkedHashMap的第一个元素是最久未使用的
      final oldestKey = _memoryCache.keys.first;
      _memoryCache.remove(oldestKey);
      _thumbnailPathById.remove(oldestKey);
      debugPrint('LRU驱逐缩略图缓存: $oldestKey');
    }
  }

  /// 减少缓存大小（用于低内存情况）
  /// 
  /// [targetSize] 目标缓存大小，如果为null则减少到当前大小的一半
  void reduceCache({int? targetSize}) {
    final target = targetSize ?? (_memoryCache.length ~/ 2);
    while (_memoryCache.length > target && _memoryCache.isNotEmpty) {
      final oldestKey = _memoryCache.keys.first;
      _memoryCache.remove(oldestKey);
      _thumbnailPathById.remove(oldestKey);
    }
    debugPrint('缓存已减少到 ${_memoryCache.length} 项');
  }
}
