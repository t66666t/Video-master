class VideoPickerTreeNode {
  final String nodeId;
  final String name;
  final bool isFolder;
  final String? parentId;
  final List<VideoPickerTreeNode> children;
  bool isSelected;
  bool isIndeterminate;
  bool isAlreadyInQueue;
  final String? videoId;
  final String? videoPath;
  final String? videoDuration;

  VideoPickerTreeNode({
    required this.nodeId,
    required this.name,
    required this.isFolder,
    this.parentId,
    List<VideoPickerTreeNode>? children,
    this.isSelected = false,
    this.isIndeterminate = false,
    this.isAlreadyInQueue = false,
    this.videoId,
    this.videoPath,
    this.videoDuration,
  }) : children = children ?? [];

  VideoPickerTreeNode copyWith({
    String? nodeId,
    String? name,
    bool? isFolder,
    String? parentId,
    List<VideoPickerTreeNode>? children,
    bool? isSelected,
    bool? isIndeterminate,
    bool? isAlreadyInQueue,
    String? videoId,
    String? videoPath,
    String? videoDuration,
  }) {
    return VideoPickerTreeNode(
      nodeId: nodeId ?? this.nodeId,
      name: name ?? this.name,
      isFolder: isFolder ?? this.isFolder,
      parentId: parentId ?? this.parentId,
      children: children ?? this.children,
      isSelected: isSelected ?? this.isSelected,
      isIndeterminate: isIndeterminate ?? this.isIndeterminate,
      isAlreadyInQueue: isAlreadyInQueue ?? this.isAlreadyInQueue,
      videoId: videoId ?? this.videoId,
      videoPath: videoPath ?? this.videoPath,
      videoDuration: videoDuration ?? this.videoDuration,
    );
  }
}

class VideoPickerTree {
  List<VideoPickerTreeNode> roots;
  int selectedCount;
  int totalCount;

  VideoPickerTree({
    List<VideoPickerTreeNode>? roots,
    this.selectedCount = 0,
    this.totalCount = 0,
  }) : roots = roots ?? [];

  void updateSelection(VideoPickerTreeNode node, bool selected) {
    if (node.isFolder) {
      _setFolderSelection(node, selected);
    } else {
      node.isSelected = selected;
      node.isIndeterminate = false;
    }
    _bubbleUpIndeterminate(node);
    recalculateCounts();
  }

  void _setFolderSelection(VideoPickerTreeNode folder, bool selected) {
    folder.isSelected = selected;
    folder.isIndeterminate = false;
    for (final child in folder.children) {
      if (child.isAlreadyInQueue) continue;
      if (child.isFolder) {
        _setFolderSelection(child, selected);
      } else {
        child.isSelected = selected;
        child.isIndeterminate = false;
      }
    }
  }

  void _bubbleUpIndeterminate(VideoPickerTreeNode node) {
    if (node.parentId == null) return;
    for (final root in roots) {
      final parent = _findNodeById(root, node.parentId!);
      if (parent != null) {
        _updateParentState(parent);
        _bubbleUpIndeterminate(parent);
        break;
      }
    }
  }

  void _updateParentState(VideoPickerTreeNode parent) {
    final selectableChildren =
        parent.children.where((c) => !c.isAlreadyInQueue).toList();
    if (selectableChildren.isEmpty) {
      parent.isSelected = false;
      parent.isIndeterminate = false;
      return;
    }
    final selectedCount =
        selectableChildren.where((c) => c.isSelected).length;
    final indeterminateCount =
        selectableChildren.where((c) => c.isIndeterminate).length;
    if (selectedCount == selectableChildren.length) {
      parent.isSelected = true;
      parent.isIndeterminate = false;
    } else if (selectedCount == 0 && indeterminateCount == 0) {
      parent.isSelected = false;
      parent.isIndeterminate = false;
    } else {
      parent.isSelected = false;
      parent.isIndeterminate = true;
    }
  }

  VideoPickerTreeNode? _findNodeById(VideoPickerTreeNode root, String id) {
    if (root.nodeId == id) return root;
    for (final child in root.children) {
      final found = _findNodeById(child, id);
      if (found != null) return found;
    }
    return null;
  }

  void recalculateCounts() {
    int selected = 0;
    int total = 0;
    for (final root in roots) {
      final counts = _countNodes(root);
      selected += counts.$1;
      total += counts.$2;
    }
    selectedCount = selected;
    totalCount = total;
  }

  (int, int) _countNodes(VideoPickerTreeNode node) {
    if (!node.isFolder) {
      return (node.isSelected ? 1 : 0, 1);
    }
    int sel = 0;
    int tot = 0;
    for (final child in node.children) {
      final counts = _countNodes(child);
      sel += counts.$1;
      tot += counts.$2;
    }
    return (sel, tot);
  }

  List<VideoPickerTreeNode> getSelectedLeaves() {
    final result = <VideoPickerTreeNode>[];
    for (final root in roots) {
      _collectSelectedLeaves(root, result);
    }
    return result;
  }

  void _collectSelectedLeaves(
    VideoPickerTreeNode node,
    List<VideoPickerTreeNode> result,
  ) {
    if (!node.isFolder && node.isSelected) {
      result.add(node);
    }
    for (final child in node.children) {
      _collectSelectedLeaves(child, result);
    }
  }
}