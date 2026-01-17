import 'dart:async';
import 'package:flutter/material.dart';
import '../services/thumbnail_cache_service.dart';

/// 缓存缩略图组件
/// 
/// 提供带占位符、淡入动画和错误处理的缩略图显示功能。
/// 使用 ThumbnailCacheService 进行缓存管理，优化内存使用。
class CachedThumbnailWidget extends StatefulWidget {
  /// 视频的唯一标识符
  final String videoId;
  
  /// 缩略图文件路径，可为null
  final String? thumbnailPath;
  
  /// 图片填充方式
  final BoxFit fit;
  
  /// 加载时显示的占位符组件
  final Widget? placeholder;
  
  /// 加载失败时显示的错误组件
  final Widget? errorWidget;
  
  /// 缩略图目标宽度（用于ResizeImage优化内存）
  final int? cacheWidth;
  
  /// 缩略图目标高度（用于ResizeImage优化内存）
  final int? cacheHeight;
  
  /// 淡入动画持续时间
  final Duration fadeInDuration;
  
  /// 淡入动画曲线
  final Curve fadeInCurve;

  const CachedThumbnailWidget({
    super.key,
    required this.videoId,
    this.thumbnailPath,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.errorWidget,
    this.cacheWidth,
    this.cacheHeight,
    this.fadeInDuration = const Duration(milliseconds: 300),
    this.fadeInCurve = Curves.easeIn,
  });

  @override
  State<CachedThumbnailWidget> createState() => _CachedThumbnailWidgetState();
}

class _CachedThumbnailWidgetState extends State<CachedThumbnailWidget> {
  /// 缓存服务实例
  final ThumbnailCacheService _cacheService = ThumbnailCacheService();
  
  /// 当前加载的ImageProvider
  ImageProvider? _imageProvider;
  
  /// 加载状态
  _LoadingState _loadingState = _LoadingState.loading;
  
  /// 是否已dispose
  bool _isDisposed = false;
  
  /// 当前加载任务的Completer，用于取消操作
  Completer<void>? _loadCompleter;

  @override
  void initState() {
    super.initState();
    final cachedProvider =
        _cacheService.getThumbnailFromMemory(widget.videoId, widget.thumbnailPath);
    if (cachedProvider != null) {
      _imageProvider = _applyResizeOptimization(cachedProvider);
      _loadingState = _LoadingState.loaded;
      return;
    }
    _loadThumbnail();
  }

  @override
  void didUpdateWidget(CachedThumbnailWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 如果videoId或thumbnailPath变化，重新加载
    if (oldWidget.videoId != widget.videoId || 
        oldWidget.thumbnailPath != widget.thumbnailPath) {
      _cancelPendingLoad();
      final cachedProvider =
          _cacheService.getThumbnailFromMemory(widget.videoId, widget.thumbnailPath);
      if (cachedProvider != null) {
        setState(() {
          _imageProvider = _applyResizeOptimization(cachedProvider);
          _loadingState = _LoadingState.loaded;
        });
        return;
      }
      _loadThumbnail();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _cancelPendingLoad();
    super.dispose();
  }

  /// 取消正在进行的加载操作
  void _cancelPendingLoad() {
    _loadCompleter?.complete();
    _loadCompleter = null;
  }

  /// 加载缩略图
  Future<void> _loadThumbnail() async {
    if (_isDisposed) return;
    
    // 创建新的Completer用于跟踪此次加载
    _loadCompleter = Completer<void>();
    final currentCompleter = _loadCompleter;
    
    setState(() {
      _loadingState = _LoadingState.loading;
      _imageProvider = null;
    });

    try {
      final cachedProvider =
          _cacheService.getThumbnailFromMemory(widget.videoId, widget.thumbnailPath);
      if (cachedProvider != null) {
        if (_isDisposed || currentCompleter != _loadCompleter) {
          return;
        }
        final optimizedProvider = _applyResizeOptimization(cachedProvider);
        setState(() {
          _imageProvider = optimizedProvider;
          _loadingState = _LoadingState.loaded;
        });
        return;
      }

      // 从缓存服务获取缩略图
      final provider = await _cacheService.getThumbnail(
        widget.videoId,
        widget.thumbnailPath,
      );
      
      // 检查是否已被取消或dispose
      if (_isDisposed || currentCompleter != _loadCompleter) {
        return;
      }
      
      if (provider != null) {
        // 应用ResizeImage优化内存
        final optimizedProvider = _applyResizeOptimization(provider);
        
        setState(() {
          _imageProvider = optimizedProvider;
          _loadingState = _LoadingState.loaded;
        });
      } else {
        setState(() {
          _loadingState = _LoadingState.error;
        });
      }
    } catch (e) {
      // 检查是否已被取消或dispose
      if (_isDisposed || currentCompleter != _loadCompleter) {
        return;
      }
      
      debugPrint('CachedThumbnailWidget 加载失败: $e');
      setState(() {
        _loadingState = _LoadingState.error;
      });
    }
  }

  /// 应用ResizeImage优化内存使用
  ImageProvider _applyResizeOptimization(ImageProvider provider) {
    if (widget.cacheWidth != null || widget.cacheHeight != null) {
      return ResizeImage(
        provider,
        width: widget.cacheWidth,
        height: widget.cacheHeight,
        allowUpscaling: false,
      );
    }
    return provider;
  }

  @override
  Widget build(BuildContext context) {
    return _buildContent();
  }

  /// 根据加载状态构建内容
  Widget _buildContent() {
    switch (_loadingState) {
      case _LoadingState.loading:
        return _buildPlaceholder();
      case _LoadingState.loaded:
        return _buildImage();
      case _LoadingState.error:
        return _buildErrorWidget();
    }
  }

  /// 构建占位符
  Widget _buildPlaceholder() {
    return widget.placeholder ?? 
      Container(
        key: const ValueKey('placeholder'),
        color: Colors.grey[800],
        child: const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white54),
            ),
          ),
        ),
      );
  }

  /// 构建图片
  Widget _buildImage() {
    if (_imageProvider == null) {
      return _buildErrorWidget();
    }
    
    final placeholder = _buildPlaceholder();

    return Stack(
      fit: StackFit.expand,
      children: [
        placeholder,
        Image(
          key: ValueKey('image_${widget.videoId}'),
          image: _imageProvider!,
          fit: widget.fit,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded) {
              return child;
            }
            return AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: widget.fadeInDuration,
              curve: widget.fadeInCurve,
              child: child,
            );
          },
          errorBuilder: (context, error, stackTrace) {
            debugPrint('图片渲染错误: $error');
            return _buildErrorWidget();
          },
        ),
      ],
    );
  }

  /// 构建错误显示组件
  Widget _buildErrorWidget() {
    return widget.errorWidget ??
      Container(
        key: const ValueKey('error'),
        color: Colors.grey[900],
        child: const Center(
          child: Icon(
            Icons.broken_image_outlined,
            color: Colors.white38,
            size: 32,
          ),
        ),
      );
  }
}

/// 加载状态枚举
enum _LoadingState {
  loading,
  loaded,
  error,
}
