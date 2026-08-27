import 'package:flutter/material.dart';
import '../models/video_picker_tree_node.dart';
import '../models/video_collection.dart';
import '../models/video_item.dart';
import '../services/library_service.dart';
import '../services/transcription_manager.dart';

class InternalVideoPickerDialog extends StatefulWidget {
  final LibraryService libraryService;
  final TranscriptionManager transcriptionManager;
  final String? defaultCollectionId;
  final void Function(List<VideoPickerTreeNode> selectedNodes) onConfirm;

  const InternalVideoPickerDialog({
    super.key,
    required this.libraryService,
    required this.transcriptionManager,
    this.defaultCollectionId,
    required this.onConfirm,
  });

  @override
  State<InternalVideoPickerDialog> createState() =>
      _InternalVideoPickerDialogState();
}

class _InternalVideoPickerDialogState extends State<InternalVideoPickerDialog> {
  late VideoPickerTree _tree;
  final Set<String> _expandedFolders = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _tree = VideoPickerTree();
    _loadTree();
  }

  void _loadTree() {
    setState(() => _isLoading = true);
    final roots = _buildNodes(null);
    _tree = VideoPickerTree(roots: roots);
    if (widget.defaultCollectionId != null) {
      _expandedFolders.add(widget.defaultCollectionId!);
    }
    _tree.recalculateCounts();
    setState(() => _isLoading = false);
  }

  List<VideoPickerTreeNode> _buildNodes(String? parentId) {
    final contents = widget.libraryService.getContents(parentId);
    final nodes = <VideoPickerTreeNode>[];

    for (final item in contents) {
      if (item is VideoCollection) {
        final children = _buildNodes(item.id);
        nodes.add(
          VideoPickerTreeNode(
            nodeId: item.id,
            name: item.name,
            isFolder: true,
            parentId: parentId,
            children: children,
          ),
        );
      } else if (item is VideoItem) {
        final isQueued =
            widget.transcriptionManager.isVideoQueued(
              item.path,
              videoId: item.id,
            ) ||
            widget.transcriptionManager.isVideoRunning(
              item.path,
              videoId: item.id,
            );
        final duration = _formatDuration(item.durationMs);
        nodes.add(
          VideoPickerTreeNode(
            nodeId: item.id,
            name: item.title,
            isFolder: false,
            parentId: parentId,
            videoId: item.id,
            videoPath: item.path,
            videoDuration: duration,
            isAlreadyInQueue: isQueued,
          ),
        );
      }
    }

    return nodes;
  }

  String _formatDuration(int ms) {
    if (ms <= 0) return '';
    final h = ms ~/ 3600000;
    final m = (ms % 3600000) ~/ 60000;
    final s = (ms % 60000) ~/ 1000;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final selectedLeaves = _tree.getSelectedLeaves();
    final canConfirm = selectedLeaves.isNotEmpty;

    return AlertDialog(
      title: const Text('选择内部视频'),
      content: SizedBox(
        width: MediaQuery.of(context).size.width * 0.85,
        height: MediaQuery.of(context).size.height * 0.65,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _tree.roots.isEmpty
            ? const Center(child: Text('暂无媒体，请先导入视频或音频'))
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Text(
                          '已选择 ${_tree.selectedCount} 个媒体',
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () {
                            setState(() {
                              for (final root in _tree.roots) {
                                _selectAll(root, true);
                              }
                              _tree.recalculateCounts();
                            });
                          },
                          child: const Text('全选'),
                        ),
                        TextButton(
                          onPressed: () {
                            setState(() {
                              for (final root in _tree.roots) {
                                _selectAll(root, false);
                              }
                              _tree.recalculateCounts();
                            });
                          },
                          child: const Text('取消全选'),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      itemCount: _tree.roots.length,
                      itemBuilder: (ctx, index) {
                        return _buildTreeNode(_tree.roots[index], 0);
                      },
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: canConfirm
              ? () {
                  widget.onConfirm(selectedLeaves);
                  Navigator.pop(context);
                }
              : null,
          child: Text('确认 (${selectedLeaves.length})'),
        ),
      ],
    );
  }

  void _selectAll(VideoPickerTreeNode node, bool selected) {
    if (node.isAlreadyInQueue && !node.isFolder) return;
    if (node.isFolder) {
      node.isSelected = false;
      node.isIndeterminate = false;
      for (final child in node.children) {
        _selectAll(child, selected);
      }
    } else {
      node.isSelected = selected;
      node.isIndeterminate = false;
    }
  }

  Widget _buildTreeNode(VideoPickerTreeNode node, int depth) {
    if (node.isFolder) {
      final isExpanded = _expandedFolders.contains(node.nodeId);
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildNodeRow(node, depth),
          if (isExpanded)
            ...node.children.map((child) => _buildTreeNode(child, depth + 1)),
        ],
      );
    }
    return _buildNodeRow(node, depth);
  }

  Widget _buildNodeRow(VideoPickerTreeNode node, int depth) {
    final checkboxValue = node.isSelected
        ? true
        : node.isIndeterminate
        ? null
        : false;

    return InkWell(
      onTap: () {
        if (node.isAlreadyInQueue) return;
        setState(() {
          _tree.updateSelection(node, !node.isSelected);
        });
      },
      child: Padding(
        padding: EdgeInsets.only(left: depth * 24.0 + 8.0),
        child: Row(
          children: [
            if (node.isFolder)
              IconButton(
                icon: Icon(
                  _expandedFolders.contains(node.nodeId)
                      ? Icons.expand_more
                      : Icons.chevron_right,
                  size: 20,
                ),
                onPressed: () {
                  setState(() {
                    if (_expandedFolders.contains(node.nodeId)) {
                      _expandedFolders.remove(node.nodeId);
                    } else {
                      _expandedFolders.add(node.nodeId);
                    }
                  });
                },
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                padding: EdgeInsets.zero,
              ),
            Checkbox(
              value: checkboxValue,
              tristate: true,
              onChanged: node.isAlreadyInQueue
                  ? null
                  : (v) {
                      setState(() {
                        _tree.updateSelection(node, v ?? false);
                      });
                    },
            ),
            Icon(
              node.isFolder ? Icons.folder : Icons.play_circle_outline,
              size: 18,
              color: node.isFolder
                  ? Colors.amber.shade700
                  : Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    node.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: node.isAlreadyInQueue
                          ? Theme.of(context).disabledColor
                          : null,
                    ),
                  ),
                  if (!node.isFolder && node.videoDuration != null)
                    Text(
                      node.videoDuration!,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                ],
              ),
            ),
            if (node.isAlreadyInQueue)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  '已在队列',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
