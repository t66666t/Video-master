import 'package:flutter/material.dart';

import '../models/video_collection.dart';
import '../services/library_service.dart';
import '../theme/app_tokens.dart';
import 'cached_thumbnail_widget.dart';
import 'folder_placeholder_cover.dart';

/// Screens at least this wide get the picker as a centred dialog; narrower
/// ones get a bottom sheet.
const double kLibraryFolderPickerWideBreakpoint = 600;

/// Result of [showLibraryFolderPicker].
class LibraryFolderPick {
  const LibraryFolderPick({required this.folderId, required this.setAsDefault});

  /// The chosen folder; null is the library root.
  final String? folderId;

  /// "设为默认位置" was ticked.
  final bool setAsDefault;
}

/// Lets the user choose a media library folder: breadcrumb path, folders in
/// the media library's style with their item counts, a search across all
/// levels, "new folder" in the current level and a fixed confirm bar.
///
/// [header] is shown above the folders (for example the parts to import).
Future<LibraryFolderPick?> showLibraryFolderPicker(
  BuildContext context, {
  required LibraryService library,
  String? initialFolderId,
  String title = '选择位置',
  String confirmLabel = '导入到这里',
  bool offerSetAsDefault = true,
  bool setAsDefaultInitially = true,
  Color accent = AppTokens.accent,
  WidgetBuilder? header,
}) {
  Widget picker(BuildContext _) => LibraryFolderPicker(
    library: library,
    initialFolderId: initialFolderId,
    title: title,
    confirmLabel: confirmLabel,
    offerSetAsDefault: offerSetAsDefault,
    setAsDefaultInitially: setAsDefaultInitially,
    accent: accent,
    header: header,
  );

  final size = MediaQuery.sizeOf(context);
  if (size.width >= kLibraryFolderPickerWideBreakpoint) {
    return showDialog<LibraryFolderPick>(
      context: context,
      builder: (dialogContext) => Dialog(
        key: const ValueKey('library-folder-picker-dialog'),
        backgroundColor: AppTokens.bgRaised,
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 520,
          height: (size.height - 48).clamp(320.0, 620.0),
          child: picker(dialogContext),
        ),
      ),
    );
  }
  return showModalBottomSheet<LibraryFolderPick>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppTokens.bgRaised,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    clipBehavior: Clip.antiAlias,
    builder: (sheetContext) => Padding(
      key: const ValueKey('library-folder-picker-sheet'),
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: SizedBox(height: size.height * 0.78, child: picker(sheetContext)),
    ),
  );
}

class LibraryFolderPicker extends StatefulWidget {
  const LibraryFolderPicker({
    super.key,
    required this.library,
    this.initialFolderId,
    this.title = '选择位置',
    this.confirmLabel = '导入到这里',
    this.offerSetAsDefault = true,
    this.setAsDefaultInitially = true,
    this.accent = AppTokens.accent,
    this.header,
  });

  final LibraryService library;
  final String? initialFolderId;
  final String title;
  final String confirmLabel;
  final bool offerSetAsDefault;
  final bool setAsDefaultInitially;
  final Color accent;
  final WidgetBuilder? header;

  @override
  State<LibraryFolderPicker> createState() => _LibraryFolderPickerState();
}

class _LibraryFolderPickerState extends State<LibraryFolderPicker> {
  final TextEditingController _query = TextEditingController();
  final TextEditingController _newName = TextEditingController();
  String? _currentId;
  late bool _setAsDefault = widget.setAsDefaultInitially;
  bool _creating = false;

  LibraryService get _library => widget.library;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialFolderId;
    if (initial != null && _isLiveFolder(initial)) _currentId = initial;
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    _newName.dispose();
    super.dispose();
  }

  bool _isLiveFolder(String id) {
    final folder = _library.getCollection(id);
    return folder != null && !folder.isRecycled;
  }

  /// Folders from the root down to [id], [id] last.
  List<VideoCollection> _pathTo(String? id) {
    final path = <VideoCollection>[];
    final seen = <String>{};
    var cursor = id;
    while (cursor != null && seen.add(cursor)) {
      final folder = _library.getCollection(cursor);
      if (folder == null) break;
      path.insert(0, folder);
      cursor = folder.parentId;
    }
    return path;
  }

  List<VideoCollection> _foldersIn(String? parentId) => <VideoCollection>[
    for (final child in _library.getContents(parentId))
      if (child is VideoCollection && !child.isRecycled) child,
  ];

  int _itemCount(String folderId) => _library.getContents(folderId).length;

  List<VideoCollection> _search(String query) {
    final needle = query.toLowerCase();
    final found = <VideoCollection>[];
    final seen = <String>{};
    void walk(String? parentId) {
      for (final folder in _foldersIn(parentId)) {
        if (!seen.add(folder.id)) continue;
        if (folder.name.toLowerCase().contains(needle)) found.add(folder);
        walk(folder.id);
      }
    }

    walk(null);
    return found;
  }

  void _open(String? folderId) {
    setState(() {
      _currentId = folderId;
      _creating = false;
      _query.clear();
    });
  }

  Future<void> _createFolder() async {
    final name = _newName.text.trim();
    if (name.isEmpty) return;
    final folder = await _library.createCollection(name, _currentId);
    if (!mounted) return;
    _newName.clear();
    _open(folder.id);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _library,
      builder: (context, _) {
        if (_currentId != null && !_isLiveFolder(_currentId!)) {
          _currentId = null;
        }
        final query = _query.text.trim();
        return Material(
          color: AppTokens.bgRaised,
          child: Column(
            children: [
              _buildTitleBar(context),
              _buildBreadcrumb(),
              _buildToolbar(),
              if (_creating) _buildNewFolderRow(),
              if (widget.header != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: widget.header!(context),
                  ),
                ),
              const Divider(height: 1, color: AppTokens.lineSubtle),
              Expanded(
                child: query.isEmpty ? _buildFolders() : _buildResults(query),
              ),
              _buildConfirmBar(context),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTitleBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('folder-picker-up'),
            tooltip: '上一级',
            onPressed: _currentId == null
                ? null
                : () => _open(_library.getCollection(_currentId!)?.parentId),
            icon: const Icon(Icons.arrow_back_rounded),
            color: AppTokens.text1,
            disabledColor: AppTokens.text4,
          ),
          Expanded(
            child: Text(
              widget.title,
              style: const TextStyle(
                color: AppTokens.text1,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded),
            color: AppTokens.text2,
          ),
        ],
      ),
    );
  }

  Widget _buildBreadcrumb() {
    final path = _pathTo(_currentId);
    Widget crumb(String key, String label, String? folderId, bool last) {
      return TextButton(
        key: ValueKey('folder-picker-crumb-$key'),
        onPressed: last ? null : () => _open(folderId),
        style: TextButton.styleFrom(
          foregroundColor: AppTokens.text2,
          disabledForegroundColor: AppTokens.text1,
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontWeight: last ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      );
    }

    const separator = Icon(
      Icons.chevron_right_rounded,
      size: 16,
      color: AppTokens.text3,
    );
    return SizedBox(
      height: 36,
      child: SingleChildScrollView(
        key: const ValueKey('folder-picker-breadcrumb'),
        scrollDirection: Axis.horizontal,
        reverse: true,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            crumb('root', '媒体库', null, path.isEmpty),
            for (var i = 0; i < path.length; i++) ...[
              separator,
              crumb(path[i].id, path[i].name, path[i].id, i == path.length - 1),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 36,
              child: TextField(
                key: const ValueKey('folder-picker-search'),
                controller: _query,
                style: const TextStyle(color: AppTokens.text1, fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '搜索文件夹',
                  hintStyle: const TextStyle(color: AppTokens.text3),
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    size: 18,
                    color: AppTokens.text3,
                  ),
                  filled: true,
                  fillColor: AppTokens.bgCard,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            key: const ValueKey('folder-picker-new'),
            onPressed: () => setState(() => _creating = !_creating),
            style: TextButton.styleFrom(foregroundColor: widget.accent),
            icon: const Icon(Icons.create_new_folder_outlined, size: 18),
            label: const Text('新建文件夹', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _buildNewFolderRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('folder-picker-new-name'),
              controller: _newName,
              autofocus: true,
              style: const TextStyle(color: AppTokens.text1, fontSize: 13),
              onSubmitted: (_) => _createFolder(),
              decoration: InputDecoration(
                isDense: true,
                hintText: '新文件夹名称',
                hintStyle: const TextStyle(color: AppTokens.text3),
                filled: true,
                fillColor: AppTokens.bgCard,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('folder-picker-new-confirm'),
            tooltip: '创建',
            onPressed: _createFolder,
            icon: Icon(Icons.check_rounded, color: widget.accent),
          ),
        ],
      ),
    );
  }

  Widget _buildFolders() {
    final folders = _foldersIn(_currentId);
    if (folders.isEmpty) {
      return const Center(
        child: Text(
          '这里没有子文件夹',
          style: TextStyle(color: AppTokens.text3, fontSize: 13),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      itemCount: folders.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final folder = folders[index];
        return _FolderRow(
          folder: folder,
          subtitle: '${_itemCount(folder.id)} 项',
          onTap: () => _open(folder.id),
        );
      },
    );
  }

  Widget _buildResults(String query) {
    final found = _search(query);
    if (found.isEmpty) {
      return const Center(
        child: Text(
          '没有找到文件夹',
          style: TextStyle(color: AppTokens.text3, fontSize: 13),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      itemCount: found.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final folder = found[index];
        final parents = _pathTo(folder.parentId).map((f) => f.name);
        final location = ['媒体库', ...parents].join(' / ');
        return _FolderRow(
          folder: folder,
          subtitle: '$location · ${_itemCount(folder.id)} 项',
          onTap: () => _open(folder.id),
        );
      },
    );
  }

  Widget _buildConfirmBar(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: AppTokens.bgOverlay,
        border: Border(top: BorderSide(color: AppTokens.lineSubtle)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
          child: Row(
            children: [
              if (widget.offerSetAsDefault)
                InkWell(
                  key: const ValueKey('folder-picker-set-default'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => setState(() => _setAsDefault = !_setAsDefault),
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: _setAsDefault,
                          activeColor: widget.accent,
                          onChanged: (value) =>
                              setState(() => _setAsDefault = value ?? false),
                        ),
                        const Text(
                          '设为默认位置',
                          style: TextStyle(
                            color: AppTokens.text2,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const Spacer(),
              FilledButton.icon(
                key: const ValueKey('folder-picker-confirm'),
                style: FilledButton.styleFrom(
                  backgroundColor: widget.accent,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.of(context).pop(
                  LibraryFolderPick(
                    folderId: _currentId,
                    setAsDefault: widget.offerSetAsDefault && _setAsDefault,
                  ),
                ),
                icon: const Icon(Icons.download_done_rounded, size: 18),
                label: Text(widget.confirmLabel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A folder row in the media library's list style: rounded card with a
/// thin border and a square cover (the folder's cover or its placeholder).
class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.folder,
    required this.subtitle,
    required this.onTap,
  });

  final VideoCollection folder;
  final String subtitle;
  final VoidCallback onTap;

  static const double _extent = 44;

  @override
  Widget build(BuildContext context) {
    final placeholder = FolderPlaceholderCover(
      folderId: folder.id,
      folderName: folder.name,
      coverLabel: folder.coverLabel,
    );
    final thumbnail = folder.thumbnailPath;
    return Material(
      key: ValueKey('folder-picker-folder-${folder.id}'),
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.075)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        hoverColor: Colors.white.withValues(alpha: 0.045),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Row(
            children: [
              SizedBox.square(
                dimension: _extent,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(_extent * 0.14),
                  child: ColoredBox(
                    color: const Color(0xFF17191D),
                    child: thumbnail != null && thumbnail.isNotEmpty
                        ? CachedThumbnailWidget(
                            videoId: folder.id,
                            thumbnailPath: thumbnail,
                            fit: BoxFit.cover,
                            placeholder: placeholder,
                            errorWidget: placeholder,
                          )
                        : placeholder,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      folder.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTokens.text1,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTokens.text3,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                color: AppTokens.text3,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
