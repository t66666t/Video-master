import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../features/portable_transfer/portable_transfer_navigation.dart';
import '../models/video_item.dart';
import '../services/library_service.dart';
import '../services/media_playback_service.dart';
import '../utils/app_toast.dart';
import '../utils/reveal_in_file_manager.dart';
import 'media_library_anchor_menu.dart';

/// Pin / hide / locate / recycle / export / OS-reveal overflow for library cards.
///
/// Hide never stops playback. Recycle and export act on this card
/// only. Move-to-parent is shown only when [onMoveToParent] is set, which is
/// the opened-folder page and not continue, recent, search, or the library root.
/// The visible ⋯ lives on the bottom-right action dock, not on the cover.
class MediaLibraryActivityMenuMetrics {
  /// Visible "⋯" size. Tracks card width so a 3-column phone stays small.
  static double glyphSize(double cardWidth) =>
      (cardWidth * 0.12).clamp(12.0, 20.0);

  /// Layout slot in the title row, matched to the first title line.
  static double layoutSize(double cardWidth) =>
      (cardWidth * 0.14).clamp(14.0, 22.0);

  /// Finger/cursor target. Extra area extends left and down into the info
  /// block, not up onto the cover.
  static double hitSize(double cardWidth) {
    final layout = layoutSize(cardWidth);
    return math.max(layout, math.min(40.0, cardWidth * 0.36));
  }
}

class MediaLibraryActivityMenuButton extends StatefulWidget {
  const MediaLibraryActivityMenuButton({
    super.key,
    required this.targetId,
    required this.isCollection,
    this.allowHide = false,
    this.onLocate,
    this.onHidden,
    this.onMoveToParent,
    this.cardWidth,
    this.fillSlot = false,
  });

  final String targetId;
  final bool isCollection;
  final bool allowHide;
  final VoidCallback? onLocate;
  final VoidCallback? onHidden;

  /// Moves this card to the folder that contains the folder currently open.
  /// Null on continue, recent, search, and the library root.
  final VoidCallback? onMoveToParent;

  /// Grid cell / list cell width used to scale glyph and hit target.
  final double? cardWidth;

  /// Transparent hit layer; the action dock paints the ⋯ glyph.
  final bool fillSlot;

  @override
  State<MediaLibraryActivityMenuButton> createState() =>
      _MediaLibraryActivityMenuButtonState();
}

class _MediaLibraryActivityMenuButtonState
    extends State<MediaLibraryActivityMenuButton> {
  bool _opening = false;

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryService>();
    final pinned = library.activityProjection.isPinned(widget.targetId);
    final ink = Material(
      key: const ValueKey('media-library-activity-menu'),
      color: Colors.transparent,
      child: InkWell(
        onTap: () => unawaited(_openMenu(library, pinned: pinned)),
        child: widget.fillSlot
            ? const SizedBox.expand()
            : _standaloneGlyph(),
      ),
    );
    return Semantics(
      button: true,
      label: '更多',
      child: Tooltip(
        message: '更多',
        child: widget.fillSlot ? ink : _standaloneFrame(ink),
      ),
    );
  }

  Widget _standaloneGlyph() {
    final extent = widget.cardWidth ?? 160;
    final glyph = MediaLibraryActivityMenuMetrics.glyphSize(extent);
    final layout = MediaLibraryActivityMenuMetrics.layoutSize(extent);
    return Align(
      alignment: Alignment.topRight,
      child: SizedBox(
        width: layout,
        height: layout,
        child: Icon(
          Icons.more_horiz,
          color: const Color(0xE6FFFFFF),
          size: glyph,
        ),
      ),
    );
  }

  Widget _standaloneFrame(Widget ink) {
    final extent = widget.cardWidth ?? 160;
    final layout = MediaLibraryActivityMenuMetrics.layoutSize(extent);
    final hit = MediaLibraryActivityMenuMetrics.hitSize(extent);
    return SizedBox(
      width: layout,
      height: layout,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: 0,
            right: 0,
            width: hit,
            height: hit,
            child: ink,
          ),
        ],
      ),
    );
  }

  Future<void> _openMenu(
    LibraryService library, {
    required bool pinned,
  }) async {
    if (_opening || !mounted) return;
    _opening = true;
    final box = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.maybeOf(context, rootOverlay: true)?.context
        .findRenderObject() as RenderBox?;
    if (box == null || overlay == null || !box.hasSize) {
      _opening = false;
      return;
    }
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    final anchor = origin & box.size;
    final VideoItem? localMedia = !widget.isCollection
        ? library.getVideo(widget.targetId)
        : null;
    final bool canRevealInOs = localMedia != null &&
        library.canRelocateLocalMediaSource(localMedia) &&
        _supportsOsFileManagerReveal;
    final items = <MediaLibraryAnchorMenuEntry>[
      MediaLibraryAnchorMenuEntry(
        value: pinned ? 'unpin' : 'pin',
        label: pinned ? '取消「继续学习」置顶' : '置顶到「继续学习」',
        icon: pinned ? CupertinoIcons.pin_slash : CupertinoIcons.pin,
      ),
      if (widget.onLocate != null)
        const MediaLibraryAnchorMenuEntry(
          value: 'locate',
          label: '显示所在目录',
          icon: CupertinoIcons.folder,
        ),
      if (widget.onMoveToParent != null)
        const MediaLibraryAnchorMenuEntry(
          value: 'parent',
          label: '移动到上一级',
          icon: CupertinoIcons.arrow_turn_up_left,
        ),
      const MediaLibraryAnchorMenuEntry(
        value: 'export',
        label: '导出',
        icon: CupertinoIcons.square_arrow_up,
      ),
      const MediaLibraryAnchorMenuEntry(
        value: 'recycle',
        label: '移入回收站',
        icon: CupertinoIcons.trash,
      ),
      if (canRevealInOs)
        const MediaLibraryAnchorMenuEntry(
          value: 'reveal_os',
          label: '在文件管理器中显示',
          icon: CupertinoIcons.folder_open,
          key: ValueKey('reveal-in-file-manager-menu'),
        ),
      if (!widget.isCollection && widget.allowHide)
        const MediaLibraryAnchorMenuEntry(
          value: 'hide',
          label: '从本页移除',
          icon: CupertinoIcons.eye_slash,
        ),
    ];
    try {
      HapticFeedback.selectionClick();
      final action = await MediaLibraryAnchorMenu.show(
        context: context,
        anchor: anchor,
        items: items,
      );
      if (!mounted || action == null) return;
      await _onSelected(library, action, localMedia: localMedia);
    } finally {
      _opening = false;
    }
  }

  static bool get _supportsOsFileManagerReveal {
    if (kIsWeb) return false;
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  }

  Future<void> _onSelected(
    LibraryService library,
    String value, {
    VideoItem? localMedia,
  }) async {
    switch (value) {
      case 'pin':
        await library.pinLibraryItem(widget.targetId);
        return;
      case 'unpin':
        await library.unpinLibraryItem(widget.targetId);
        return;
      case 'locate':
        widget.onLocate?.call();
        return;
      case 'parent':
        widget.onMoveToParent?.call();
        return;
      case 'export':
        await PortableTransferNavigation.openExportSettings(context, [
          widget.targetId,
        ]);
        return;
      case 'recycle':
        await library.moveToRecycleBin([widget.targetId]);
        if (!mounted) return;
        AppToast.show('已移入回收站', type: AppToastType.success);
        return;
      case 'reveal_os':
        await _revealLocalMedia(localMedia);
        return;
      case 'hide':
        // Block the current watch cycle from immediately undoing hide.
        MediaPlaybackService().noteLibraryMediaHidden(widget.targetId);
        await library.hideLibraryMedia(widget.targetId);
        widget.onHidden?.call();
        return;
    }
  }

  Future<void> _revealLocalMedia(VideoItem? item) async {
    final path = item?.path.trim() ?? '';
    if (path.isEmpty) {
      AppToast.show('无法定位本地文件', type: AppToastType.error);
      return;
    }
    final bool opened = await revealInFileManager(path);
    if (!opened) {
      AppToast.show('无法在文件管理器中显示', type: AppToastType.error);
    }
  }
}
