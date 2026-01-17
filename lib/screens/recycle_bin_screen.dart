import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/library_service.dart';
import '../models/video_collection.dart';
import '../models/video_item.dart';

class RecycleBinScreen extends StatefulWidget {
  const RecycleBinScreen({super.key});

  @override
  State<RecycleBinScreen> createState() => _RecycleBinScreenState();
}

class _RecycleBinScreenState extends State<RecycleBinScreen> {
  final Set<String> _selectedIds = {};
  bool _isSelectionMode = false;

  void _navigateToFolderDetail(BuildContext context, VideoCollection collection) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => RecycledFolderDetailScreen(collection: collection),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<LibraryService>(
      builder: (context, library, child) {
        final bin = library.getRecycleBinContents();

        return Scaffold(
          appBar: AppBar(
            title: _isSelectionMode 
              ? Text("已选择 ${_selectedIds.length} 项") 
              : const Text("回收站"),
            actions: [
              if (bin.isNotEmpty) ...[
                if (_isSelectionMode) ...[
                  IconButton(
                    icon: const Icon(Icons.select_all),
                    onPressed: () {
                      setState(() {
                        if (_selectedIds.length == bin.length) {
                          _selectedIds.clear();
                        } else {
                          _selectedIds.addAll(bin.map((e) => e.id as String));
                        }
                      });
                    },
                    tooltip: "全选/反选",
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      setState(() {
                        _isSelectionMode = false;
                        _selectedIds.clear();
                      });
                    },
                  ),
                ] else ...[
                   IconButton(
                    icon: const Icon(Icons.checklist),
                    onPressed: () {
                      setState(() {
                        _isSelectionMode = true;
                      });
                    },
                    tooltip: "选择",
                  ),
                ],
              ]
            ],
          ),
          body: bin.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.delete_outline, size: 80, color: Colors.white24),
                      SizedBox(height: 16),
                      Text("回收站是空的", style: TextStyle(color: Colors.white54)),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: bin.length,
                  itemBuilder: (context, index) {
                    final item = bin[index];
                    // Handle dynamic item type
                    final String id = item.id;
                    final String name = item is VideoCollection ? item.name : (item as dynamic).title;
                    final bool isFolder = item is VideoCollection;
                    
                    final isSelected = _selectedIds.contains(id);
                    
                    return Card(
                      color: isSelected ? Colors.blueAccent.withOpacity(0.2) : const Color(0xFF2C2C2C),
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: _isSelectionMode 
                          ? Checkbox(
                              value: isSelected,
                              onChanged: (val) {
                                setState(() {
                                  if (val == true) {
                                    _selectedIds.add(id);
                                  } else {
                                    _selectedIds.remove(id);
                                  }
                                });
                              },
                            )
                          : Icon(isFolder ? Icons.folder : Icons.movie, color: isFolder ? Colors.amber : Colors.blue),
                        title: Text(name, style: const TextStyle(color: Colors.white)),
                        subtitle: Text(
                          isFolder 
                            ? "${(item as VideoCollection).childrenIds.length} 个项目" 
                            : (item as dynamic).path ?? "未知路径", 
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: !_isSelectionMode 
                          ? IconButton(
                              icon: const Icon(Icons.restore, color: Colors.green),
                              onPressed: () {
                                library.restoreFromRecycleBin([id]);
                                ScaffoldMessenger.of(context).clearSnackBars();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text("已还原")),
                                );
                              },
                              tooltip: "还原",
                            )
                          : null,
                        onTap: () {
                          if (_isSelectionMode) {
                            setState(() {
                              if (isSelected) {
                                _selectedIds.remove(id);
                              } else {
                                _selectedIds.add(id);
                              }
                            });
                          } else if (isFolder) {
                             _navigateToFolderDetail(context, item as VideoCollection);
                          }
                        },
                        onLongPress: () {
                          if (!_isSelectionMode) {
                            setState(() {
                              _isSelectionMode = true;
                              _selectedIds.add(id);
                            });
                          }
                        },
                      ),
                    );
                  },
                ),
          bottomNavigationBar: _isSelectionMode && _selectedIds.isNotEmpty
            ? BottomAppBar(
                color: const Color(0xFF1E1E1E),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.restore, color: Colors.green),
                      label: const Text("还原", style: TextStyle(color: Colors.green)),
                      onPressed: () {
                        library.restoreFromRecycleBin(_selectedIds.toList());
                        setState(() {
                          _selectedIds.clear();
                          _isSelectionMode = false;
                        });
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("已还原选中项")),
                        );
                      },
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.delete_forever, color: Colors.redAccent),
                      label: const Text("彻底删除", style: TextStyle(color: Colors.redAccent)),
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text("彻底删除"),
                            content: const Text("删除后无法找回，确定要删除吗？"),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx),
                                child: const Text("取消"),
                              ),
                              TextButton(
                                onPressed: () async {
                                  Navigator.pop(ctx);
                                  await library.deleteFromRecycleBin(_selectedIds.toList());
                                  if (context.mounted) {
                                    setState(() {
                                      _selectedIds.clear();
                                      _isSelectionMode = false;
                                    });
                                  }
                                },
                                child: const Text("删除", style: TextStyle(color: Colors.red)),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
              )
            : null,
        );
      },
    );
  }
}

class RecycledFolderDetailScreen extends StatelessWidget {
  final VideoCollection collection;

  const RecycledFolderDetailScreen({super.key, required this.collection});

  @override
  Widget build(BuildContext context) {
    return Consumer<LibraryService>(
      builder: (context, library, child) {
        // Use standard getContents because items inside are NOT marked as recycled
        final contents = library.getContents(collection.id);

        return Scaffold(
          appBar: AppBar(
            title: Text(collection.name),
            backgroundColor: const Color(0xFF1E1E1E),
          ),
          body: Column(
            children: [
              // Info Banner
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                color: Colors.orange.withOpacity(0.1),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, color: Colors.orange, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "您正在查看已删除文件夹的内容。\n若要操作这些项目，请先还原该文件夹。",
                        style: TextStyle(color: Colors.orange[300], fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: contents.isEmpty
                    ? const Center(
                        child: Text("文件夹为空", style: TextStyle(color: Colors.white54)),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: contents.length,
                        itemBuilder: (context, index) {
                          final item = contents[index];
                          final String name = item is VideoCollection ? item.name : (item as VideoItem).title;
                          final bool isFolder = item is VideoCollection;

                          return Card(
                            color: const Color(0xFF2C2C2C).withOpacity(0.5), // Dimmed
                            margin: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              leading: Icon(
                                isFolder ? Icons.folder : Icons.movie, 
                                color: (isFolder ? Colors.amber : Colors.blue).withOpacity(0.5)
                              ),
                              title: Text(
                                name, 
                                style: TextStyle(color: Colors.white.withOpacity(0.7))
                              ),
                              subtitle: isFolder 
                                  ? Text("${item.childrenIds.length} 个项目", style: const TextStyle(color: Colors.white38, fontSize: 12))
                                  : null,
                              onTap: isFolder 
                                  ? () {
                                      Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (context) => RecycledFolderDetailScreen(collection: item),
                                        ),
                                      );
                                    }
                                  : null, // Disable tapping videos
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
