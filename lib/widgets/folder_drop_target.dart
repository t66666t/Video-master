import 'dart:async';
import 'package:flutter/material.dart';

class FolderDropTarget extends StatefulWidget {
  final Widget child;
  final String folderId;
  final int index;
  final Function(int draggedIndex, String targetFolderId) onMoveToFolder;
  final Function(int draggedIndex, int newIndex) onReorder;

  const FolderDropTarget({
    Key? key,
    required this.child,
    required this.folderId,
    required this.index,
    required this.onMoveToFolder,
    required this.onReorder,
  }) : super(key: key);

  @override
  State<FolderDropTarget> createState() => _FolderDropTargetState();
}

class _FolderDropTargetState extends State<FolderDropTarget> {
  Timer? _hoverTimer;
  bool _isHovering = false;
  bool _isMoveMode = false;

  @override
  void dispose() {
    _hoverTimer?.cancel();
    super.dispose();
  }

  void _handleDragEnter() {
    setState(() {
      _isHovering = true;
    });
    
    _hoverTimer?.cancel();
    _hoverTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted && _isHovering) {
        setState(() {
          _isMoveMode = true;
        });
      }
    });
  }

  void _handleDragLeave() {
    _hoverTimer?.cancel();
    setState(() {
      _isHovering = false;
      _isMoveMode = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<int>(
      onWillAccept: (data) {
        if (data == null || data == widget.index) return false;
        _handleDragEnter();
        return true;
      },
      onLeave: (_) => _handleDragLeave(),
      onAccept: (draggedIndex) {
        _hoverTimer?.cancel();
        
        if (_isMoveMode) {
          widget.onMoveToFolder(draggedIndex, widget.folderId);
        } else {
          widget.onReorder(draggedIndex, widget.index);
        }
        
        setState(() {
          _isHovering = false;
          _isMoveMode = false;
        });
      },
      builder: (context, candidateData, rejectedData) {
        if (!_isHovering || candidateData.isEmpty) {
          return widget.child;
        }

        // Visual Feedback
        return Stack(
          children: [
            widget.child,
            
            // Overlay based on mode
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: _isMoveMode 
                      ? Colors.greenAccent.withOpacity(0.3) 
                      : Colors.transparent, // Reorder is handled by GridView usually, but here we show border
                  border: Border.all(
                    color: _isMoveMode ? Colors.greenAccent : Colors.blueAccent,
                    width: 3,
                  ),
                ),
                child: _isMoveMode 
                    ? const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.move_to_inbox, color: Colors.white, size: 40),
                            SizedBox(height: 8),
                            Text(
                              "移动到此处",
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                shadows: [Shadow(blurRadius: 4, color: Colors.black)],
                              ),
                            ),
                          ],
                        ),
                      )
                    : null,
              ),
            ),
          ],
        );
      },
    );
  }
}
