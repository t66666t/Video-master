import 'dart:io';

import 'package:flutter/material.dart';

import 'custom_drag.dart';
import 'folder_drop_target.dart';

/// Uses movement-gated desktop dragging while preserving long-press dragging
/// on touch-first mobile platforms. A stationary desktop press therefore stays
/// a click, regardless of how long the mouse button is held.
class MediaLibraryAdaptiveDraggable<T extends Object> extends StatelessWidget {
  const MediaLibraryAdaptiveDraggable({
    super.key,
    required this.data,
    required this.delay,
    required this.feedback,
    required this.child,
    required this.childWhenDragging,
    required this.onDragStarted,
    this.onTap,
  });

  final T data;
  final Duration delay;
  final Widget feedback;
  final Widget child;
  final Widget childWhenDragging;
  final VoidCallback onDragStarted;

  /// 位移未达拖拽阈值时补偿点击的回调（桌面端）。
  final VoidCallback? onTap;

  bool get _usesDesktopPointerGesture {
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  }

  @override
  Widget build(BuildContext context) {
    if (_usesDesktopPointerGesture) {
      return GatedDraggable<T>(
        data: data,
        feedback: feedback,
        onDragStarted: onDragStarted,
        onTap: onTap,
        longPressDuration: delay,
        child: child,
      );
    }
    return LongPressDraggable<T>(
      delay: delay,
      data: data,
      feedback: feedback,
      childWhenDragging: childWhenDragging,
      onDragStarted: onDragStarted,
      child: child,
    );
  }
}

/// Applies the same long-press drag, reorder and folder-drop interaction to
/// any media-library presentation (grid card or proportional list tile).
class MediaLibraryItemInteractionWrapper extends StatelessWidget {
  const MediaLibraryItemInteractionWrapper({
    super.key,
    required this.child,
    required this.index,
    required this.dragDelay,
    required this.isSelected,
    required this.selectedCount,
    required this.onDragStarted,
    required this.onReorder,
    this.folderId,
    this.onMoveToFolder,
    this.onTap,
    this.allowReorder = true,
  });

  final Widget child;
  final int index;
  final Duration dragDelay;
  final bool isSelected;
  final int selectedCount;
  final VoidCallback onDragStarted;
  final void Function(int oldIndex, int newIndex) onReorder;
  final String? folderId;
  final void Function(int draggedIndex, String targetFolderId)? onMoveToFolder;

  /// 位移未达拖拽阈值时补偿点击的回调（桌面端），通常与子项点击行为一致。
  final VoidCallback? onTap;

  final bool allowReorder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final unit = size.shortestSide;
        final target = folderId != null && onMoveToFolder != null
            ? FolderDropTarget(
                folderId: folderId!,
                index: index,
                onMoveToFolder: onMoveToFolder!,
                onReorder: onReorder,
                allowReorder: allowReorder,
                child: child,
              )
            : DropZone<int>(
                data: index,
                onWillAccept: (draggedData) =>
                    allowReorder && draggedData != index,
                onAcceptWithDetails: (draggedData, _) {
                  if (!allowReorder) return;
                  onReorder(draggedData, index);
                },
                builder: (context, candidateData) {
                  if (candidateData.isEmpty) return child;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      child,
                      IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(unit * 0.16),
                            border: Border.all(
                              color: Colors.blueAccent,
                              width: unit * 0.025,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              );

        return MediaLibraryAdaptiveDraggable<int>(
          delay: dragDelay,
          data: index,
          onDragStarted: onDragStarted,
          onTap: onTap,
          feedback: SizedBox(
            width: size.width,
            height: size.height,
            child: Material(
              type: MaterialType.transparency,
              child: Opacity(
                opacity: 0.9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    IgnorePointer(child: child),
                    if (isSelected && selectedCount > 1)
                      Positioned(
                        top: unit * 0.06,
                        right: unit * 0.06,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: unit * 0.12,
                            vertical: unit * 0.05,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.blueAccent,
                            borderRadius: BorderRadius.circular(unit * 0.14),
                          ),
                          child: Text(
                            '$selectedCount',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: unit * 0.16,
                              height: 1,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.3, child: target),
          child: target,
        );
      },
    );
  }
}
