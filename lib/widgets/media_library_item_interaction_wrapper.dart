import 'dart:io';

import 'package:flutter/material.dart';

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
  });

  final T data;
  final Duration delay;
  final Widget feedback;
  final Widget child;
  final Widget childWhenDragging;
  final VoidCallback onDragStarted;

  bool get _usesDesktopPointerGesture {
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  }

  @override
  Widget build(BuildContext context) {
    if (_usesDesktopPointerGesture) {
      return Draggable<T>(
        data: data,
        feedback: feedback,
        childWhenDragging: childWhenDragging,
        onDragStarted: onDragStarted,
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
            : DragTarget<int>(
                onWillAcceptWithDetails: (details) =>
                    allowReorder && details.data != index,
                onAcceptWithDetails: (details) {
                  if (!allowReorder) return;
                  onReorder(details.data, index);
                },
                builder: (context, candidateData, rejectedData) {
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
