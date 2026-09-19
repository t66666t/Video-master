import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/folder_placeholder_style.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';

/// Rename a library item. Folders also edit cover text when covers show letters.
Future<void> showLibraryRenameDialog({
  required BuildContext context,
  required String itemId,
  required String currentName,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return _LibraryRenameDialog(
        itemId: itemId,
        currentName: currentName,
      );
    },
  );
}

class _LibraryRenameDialog extends StatefulWidget {
  const _LibraryRenameDialog({
    required this.itemId,
    required this.currentName,
  });

  final String itemId;
  final String currentName;

  @override
  State<_LibraryRenameDialog> createState() => _LibraryRenameDialogState();
}

class _LibraryRenameDialogState extends State<_LibraryRenameDialog> {
  static const Key nameFieldKey = ValueKey<String>('library-rename-name-field');
  static const Key coverFieldKey = ValueKey<String>(
    'library-rename-cover-field',
  );

  late final TextEditingController _nameController;
  late final TextEditingController _coverController;
  late final bool _showCoverField;
  late final int _maxCoverTextLength;
  late bool _followsAuto;
  bool _syncingCover = false;

  @override
  void initState() {
    super.initState();
    final library = Provider.of<LibraryService>(context, listen: false);
    final settings = Provider.of<SettingsService>(context, listen: false);
    final collection = library.getCollection(widget.itemId);
    _showCoverField =
        collection != null &&
        settings.folderPlaceholderSettings.showCoverText;
    _maxCoverTextLength =
        settings.folderPlaceholderSettings.maxCoverTextLength;
    _followsAuto = collection?.coverLabel == null;
    // Seed the second row with whatever the cover currently shows so a rename
    // can edit lettering without first discovering the auto algorithm.
    _nameController = TextEditingController(text: widget.currentName);
    _coverController = TextEditingController(
      text: FolderPlaceholderLook.displayLabel(
        folderName: widget.currentName,
        coverLabel: collection?.coverLabel,
        showCoverText: true,
        maxLength: _maxCoverTextLength,
      ),
    );
    _nameController.addListener(_onNameChanged);
    _coverController.addListener(_onCoverChanged);
  }

  @override
  void dispose() {
    _nameController.removeListener(_onNameChanged);
    _coverController.removeListener(_onCoverChanged);
    _nameController.dispose();
    _coverController.dispose();
    super.dispose();
  }

  void _onNameChanged() {
    if (!_followsAuto) return;
    final next = FolderPlaceholderLook.autoLabelFor(
      _nameController.text,
      maxLength: _maxCoverTextLength,
    );
    if (_coverController.text == next) return;
    _syncingCover = true;
    _coverController.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
    _syncingCover = false;
  }

  void _onCoverChanged() {
    if (_syncingCover) return;
    final clamped = FolderPlaceholderLook.clampLabel(
      _coverController.text,
      maxLength: _maxCoverTextLength,
    );
    // Keep typing in sync with the 4-grapheme cap without fighting empty input.
    if (_coverController.text.trim().isNotEmpty &&
        _coverController.text != clamped) {
      _syncingCover = true;
      _coverController.value = TextEditingValue(
        text: clamped,
        selection: TextSelection.collapsed(offset: clamped.length),
      );
      _syncingCover = false;
    }
    final auto = FolderPlaceholderLook.autoLabelFor(
      _nameController.text,
      maxLength: _maxCoverTextLength,
    );
    final trimmed = _coverController.text.trim();
    setState(() {
      _followsAuto = trimmed.isNotEmpty && trimmed == auto;
    });
  }

  void _confirm() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    String? coverLabel;
    var updateCoverLabel = false;
    if (_showCoverField) {
      updateCoverLabel = true;
      if (_followsAuto) {
        coverLabel = null;
      } else {
        coverLabel = FolderPlaceholderLook.clampLabel(
          _coverController.text,
          maxLength: _maxCoverTextLength,
        );
      }
    }
    Provider.of<LibraryService>(context, listen: false).renameItem(
      widget.itemId,
      name,
      coverLabel: coverLabel,
      updateCoverLabel: updateCoverLabel,
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final autoHint = FolderPlaceholderLook.autoLabelFor(
      _nameController.text,
      maxLength: _maxCoverTextLength,
    );
    return AlertDialog(
      title: const Text('重命名'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: nameFieldKey,
            controller: _nameController,
            decoration: const InputDecoration(hintText: '输入新名称'),
            autofocus: true,
            onSubmitted: (_) {
              if (!_showCoverField) _confirm();
            },
          ),
          if (_showCoverField) ...[
            const SizedBox(height: 12),
            TextField(
              key: coverFieldKey,
              controller: _coverController,
              decoration: InputDecoration(
                labelText: '封面文字',
                hintText: autoHint.isEmpty ? '留空则不显示' : '默认：$autoHint',
                helperText:
                    '最多 $_maxCoverTextLength 个字。留空不显示；与自动值相同则跟随文件夹名。',
                helperMaxLines: 2,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _confirm,
          child: const Text('确定'),
        ),
      ],
    );
  }
}
