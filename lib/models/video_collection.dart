class VideoCollection {
  final String id;
  String name;
  final int createTime;
  
  // New: File System Structure
  List<String> childrenIds; // Can contain VideoItem IDs or VideoCollection IDs
  String? parentId; // null means root
  bool isRecycled;
  int? recycleTime;

  // Deprecated but kept for migration if needed, though we will try to migrate immediately
  // List<String> videoIds; 

  VideoCollection({
    required this.id,
    required this.name,
    required this.createTime,
    List<String>? childrenIds,
    this.parentId,
    this.isRecycled = false,
    this.recycleTime,
  }) : childrenIds = childrenIds ?? [];

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'createTime': createTime,
      'childrenIds': childrenIds,
      'parentId': parentId,
      'isRecycled': isRecycled,
      'recycleTime': recycleTime,
    };
  }

  factory VideoCollection.fromJson(Map<String, dynamic> json) {
    // Migration logic: if videoIds exists but childrenIds doesn't, use videoIds
    List<String> loadedChildren = [];
    if (json['childrenIds'] != null) {
      loadedChildren = (json['childrenIds'] as List<dynamic>).map((e) => e as String).toList();
    } else if (json['videoIds'] != null) {
      loadedChildren = (json['videoIds'] as List<dynamic>).map((e) => e as String).toList();
    }

    return VideoCollection(
      id: json['id'] as String,
      name: json['name'] as String,
      createTime: json['createTime'] as int,
      childrenIds: loadedChildren,
      parentId: json['parentId'] as String?,
      isRecycled: json['isRecycled'] as bool? ?? false,
      recycleTime: json['recycleTime'] as int?,
    );
  }
  
  // Helper to distinguish from VideoItem if needed (though we usually check by ID lookup)
  bool get isCollection => true;
}
