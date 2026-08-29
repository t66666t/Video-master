import 'dart:async';

import 'package:flutter/material.dart';

/// 桌面端拖拽启动阈值（逻辑像素）。
///
/// 鼠标按下后位移超过该距离才视为一次「拖拽」，否则保持为一次点击。
/// 使用固定的逻辑像素值（与卡片尺寸、屏幕分辨率/DPI 无关），在任何显示
/// 环境下都能可靠区分「点击」与「拖拽」，同时数值不会过大而导致真正的
/// 拖拽响应迟钝。
const double kDragStartThreshold = 10.0;

/// DropTarget 的轻量包装。
///
/// 之所以需要这层包装，是为了给所有 DropTarget 提供统一、简洁的 API，同时
/// 仍由 Flutter 原生 [DragTarget] 完成候选高亮与落点接收（原生 [Draggable]
/// 通过私有 _DragAvatar 驱动这些交互，外部无法注入，因此拖拽源必须保留
/// [Draggable]）。
class DropZone<T extends Object> extends StatelessWidget {
  const DropZone({
    super.key,
    required this.data,
    required this.builder,
    this.onWillAccept,
    this.onEnter,
    this.onLeave,
    this.onAcceptWithDetails,
  });

  /// 槽位标识（例如卡片 index），供拖拽数据判断是否可接收。
  final T data;

  /// 构建内容。[candidateData] 在拖拽悬停到本槽位且被接受时非空。
  final Widget Function(BuildContext context, List<T?> candidateData) builder;

  /// 拖拽数据尝试进入本槽位时调用，返回是否接受为候选（决定是否高亮）。
  final bool Function(T draggedData)? onWillAccept;

  final VoidCallback? onEnter;
  final VoidCallback? onLeave;

  /// 拖拽数据被释放到本槽位时调用。
  final void Function(T draggedData, Offset position)? onAcceptWithDetails;

  @override
  Widget build(BuildContext context) {
    return DragTarget<T>(
      onWillAcceptWithDetails: (details) {
        final accepted = onWillAccept?.call(details.data) ?? true;
        if (accepted) onEnter?.call();
        return accepted;
      },
      onLeave: (_) => onLeave?.call(),
      onAcceptWithDetails: (details) {
        onAcceptWithDetails?.call(details.data, details.offset);
      },
      builder: (context, candidateData, _) {
        return builder(context, candidateData);
      },
    );
  }
}

/// 位移/时长门控的桌面端拖拽源，替代默认的 [Draggable]。
///
/// Flutter 的 [Draggable] 对鼠标只使用 1 逻辑像素的启动 slop，导致点击时
/// 轻微移动鼠标就会被识别成拖拽（抢占点击、误入选择模式）。本组件保留原生
/// [Draggable]（用于与滚动手势正确竞争、并驱动 [DropZone] 的高亮与接收），
/// 但满足以下任一条件才真正触发 [onDragStarted]（进入选择模式）：
///  - 位移超过 [threshold]（拖动卡片）；
///  - 按住不松开超过 [longPressDuration]（长按卡片）。
///
/// 其余行为：
///  - 平台拖拽的反馈置为透明、拖拽中保持原样，避免点击时出现拖拽残影；
///  - 拖拽视觉反馈由本组件用 [feedback] 自行绘制；
///  - 位移未达阈值但发生过轻微移动（0 < 位移 < [threshold]）时，平台手势
///    已把本次操作判定为非点击，通过 [onTap] 把「点击」语义补回来。
class GatedDraggable<T extends Object> extends StatefulWidget {
  const GatedDraggable({
    super.key,
    required this.data,
    required this.feedback,
    required this.child,
    required this.onDragStarted,
    this.onTap,
    this.threshold = kDragStartThreshold,
    this.longPressDuration = const Duration(milliseconds: 320),
  });

  final T data;
  final Widget feedback;
  final Widget child;
  final VoidCallback onDragStarted;

  /// 点击补偿回调，见类注释。
  final VoidCallback? onTap;

  final double threshold;

  /// 按住超过该时长（且位移未达阈值）也进入选择模式，兼容「长按选中」习惯。
  final Duration longPressDuration;

  @override
  State<GatedDraggable<T>> createState() => _GatedDraggableState<T>();
}

class _GatedDraggableState<T extends Object> extends State<GatedDraggable<T>> {
  Offset? _downPosition;
  bool _armed = false;
  Offset _feedbackPosition = Offset.zero;
  OverlayEntry? _feedbackEntry;
  Timer? _longPressTimer;

  @override
  void dispose() {
    _longPressTimer?.cancel();
    _removeFeedback();
    super.dispose();
  }

  void _onPointerDown(PointerDownEvent event) {
    _downPosition = event.position;
    _armed = false;
    _longPressTimer?.cancel();
    // 长按选中：按住不动超过 longPressDuration 也进入选择模式。
    _longPressTimer = Timer(widget.longPressDuration, () {
      if (!_armed && _downPosition != null && mounted) {
        _arm(event.position);
      }
    });
  }

  void _onPointerMove(PointerMoveEvent event) {
    final down = _downPosition;
    if (down == null) return;
    if (!_armed) {
      final distance = (event.position - down).distance;
      if (distance < widget.threshold) return;
      _longPressTimer?.cancel();
      _arm(event.position);
    } else {
      _updateFeedback(event.position);
    }
  }

  void _arm(Offset position) {
    _armed = true;
    widget.onDragStarted();
    _showFeedback(position);
    if (mounted) setState(() {});
  }

  void _onPointerUp(PointerUpEvent event) {
    _longPressTimer?.cancel();
    final down = _downPosition;
    if (down != null && !_armed) {
      final distance = (event.position - down).distance;
      if (distance > 0 && distance < widget.threshold) {
        // 轻微移动但未达拖拽阈值：平台已取消 InkWell 点击，这里补一次点击。
        widget.onTap?.call();
      }
    }
    _removeFeedback();
    _downPosition = null;
    _armed = false;
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _longPressTimer?.cancel();
    _removeFeedback();
    _downPosition = null;
    _armed = false;
  }

  void _showFeedback(Offset position) {
    _feedbackPosition = position;
    _feedbackEntry?.remove();
    _feedbackEntry = OverlayEntry(
      builder: (context) => Positioned(
        left: _feedbackPosition.dx,
        top: _feedbackPosition.dy,
        child: FractionalTranslation(
          translation: const Offset(-0.5, -0.5),
          child: IgnorePointer(child: widget.feedback),
        ),
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_feedbackEntry!);
  }

  void _updateFeedback(Offset position) {
    _feedbackPosition = position;
    _feedbackEntry?.markNeedsBuild();
  }

  void _removeFeedback() {
    _feedbackEntry?.remove();
    _feedbackEntry = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: Draggable<T>(
        data: widget.data,
        // 平台拖拽反馈置空：位移门控与视觉反馈由本组件负责，避免点击时
        // 1px 启动的 Draggable 显示残影。
        feedback: const SizedBox.shrink(),
        // 拖拽中保持原样，避免轻微移动点击时卡片闪烁。
        childWhenDragging: widget.child,
        child: widget.child,
      ),
    );
  }
}
