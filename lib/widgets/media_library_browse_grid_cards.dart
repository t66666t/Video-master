import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/video_collection.dart';
import '../models/video_item.dart';
import '../services/media_library_folder_walk.dart';
import '../services/media_playback_service.dart';
import '../services/library_service.dart';
import 'cached_thumbnail_widget.dart';
import 'folder_placeholder_cover.dart';
import 'media_library_activity_menu.dart';
import 'media_library_action_dock.dart';
import 'media_library_grid_card.dart';
import 'media_library_layout_profile.dart';
import 'media_library_locate_button.dart';
import 'media_list_layout_metrics.dart';

/// Same 16:9 + info-block grid card used by search results.
class MediaLibraryMediaGridCard extends StatelessWidget {
  const MediaLibraryMediaGridCard({
    super.key,
    required this.item,
    required this.titleScale,
    required this.onTap,
    required this.onLocate,
    this.showLocate = true,
    this.showActivityMenu = true,
    this.allowHide = false,
    this.relativePath,
  });

  static const double coverAspectRatio = 16 / 9;

  final VideoItem item;
  final double titleScale;
  final VoidCallback onTap;
  final VoidCallback onLocate;
  final bool showLocate;
  final bool showActivityMenu;
  final bool allowHide;
  final String? relativePath;

  /// Folder names from library root to the file's parent.
  static String? pathFromLibraryRoot(LibraryService library, VideoItem item) {
    final path = MediaLibraryFolderWalk.relativePath(
      rootId: '',
      parentId: item.parentId,
      folderOf: library.getCollection,
    );
    return path.isEmpty ? null : path;
  }

  static String durationLabel(int durationMs) {
    final total = (durationMs / 1000).floor();
    final m = total ~/ 60;
    final s = total % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  static Widget scaledThumbnailIcon({
    required double extent,
    required IconData icon,
    Color color = Colors.white24,
  }) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Icon(
          icon,
          size: MediaListLayoutMetrics.cardGridThumbnailIconSize(extent),
          color: color,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = constraints.maxWidth;
        final chipSize = MediaLibraryActionDockMetrics.gridChipSize(cardWidth);
        final showMenu = showActivityMenu;
        final textInset = MediaLibraryActionDockMetrics.textInset(
          chipSize: chipSize,
          showMore: showMenu,
          showLocate: showLocate,
          existingPadding:
              MediaListLayoutMetrics.cardGridContentPadding(cardWidth).right,
        );
        final radius = (cardWidth * 0.09).clamp(4.0, 40.0);
        final titleFontSize = MediaLibraryLayoutDefaults.titleFontSize(
          cardWidth,
          titleScale,
        );
        final metaFontSize = MediaLibraryLayoutDefaults.metaFontSize(
          titleFontSize,
        );

        final cardVisual = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: coverAspectRatio,
              child: ColoredBox(
                color: Colors.black26,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    item.type == MediaType.audio
                        ? LayoutBuilder(
                            builder: (context, thumbConstraints) {
                              final icon = scaledThumbnailIcon(
                                extent: thumbConstraints.biggest.shortestSide,
                                icon: Icons.music_note,
                              );
                              if (item.thumbnailPath != null &&
                                  item.thumbnailPath!.isNotEmpty) {
                                return CachedThumbnailWidget(
                                  videoId: item.id,
                                  thumbnailPath: item.thumbnailPath,
                                  fit: BoxFit.cover,
                                  placeholder: icon,
                                  errorWidget: icon,
                                );
                              }
                              return icon;
                            },
                          )
                        : LayoutBuilder(
                            builder: (context, thumbConstraints) {
                              final dpr = MediaQuery.devicePixelRatioOf(
                                context,
                              );
                              final cacheWidth =
                                  (thumbConstraints.maxWidth * dpr)
                                      .round()
                                      .clamp(1, 4096);
                              final cacheHeight =
                                  (thumbConstraints.maxHeight * dpr)
                                      .round()
                                      .clamp(1, 4096);
                              final icon = scaledThumbnailIcon(
                                extent: thumbConstraints.biggest.shortestSide,
                                icon: Icons.movie,
                              );
                              return CachedThumbnailWidget(
                                videoId: item.id,
                                thumbnailPath: item.thumbnailPath,
                                fit: BoxFit.cover,
                                cacheWidth: cacheWidth,
                                cacheHeight: cacheHeight,
                                placeholder: icon,
                                errorWidget: icon,
                              );
                            },
                          ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: _WatchProgressBar(item: item),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: MediaListLayoutMetrics.cardGridContentPadding(
                  cardWidth,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        item.title,
                        style: TextStyle(
                          fontSize: titleFontSize,
                          fontWeight: FontWeight.w500,
                          color: Colors.white,
                        ),
                        maxLines: 10,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (relativePath != null)
                      Padding(
                        padding: EdgeInsets.only(right: textInset),
                        child: Text(
                          relativePath!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: metaFontSize,
                            color: Colors.white38,
                          ),
                        ),
                      ),
                    if (item.durationMs > 0) ...[
                      const SizedBox(height: 4),
                      Padding(
                        padding: EdgeInsets.only(right: textInset),
                        child: Text(
                          durationLabel(item.durationMs),
                          style: TextStyle(
                            fontSize: metaFontSize,
                            color: Colors.white54,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );

        return MediaLibraryGridCard(
          radius: radius,
          isSelected: false,
          onTap: onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              cardVisual,
              MediaLibraryActionDock(
                chipSize: chipSize,
                more: showMenu
                    ? MediaLibraryActivityMenuButton(
                        targetId: item.id,
                        isCollection: false,
                        allowHide: allowHide,
                        onLocate: onLocate,
                        fillSlot: true,
                      )
                    : null,
                locate: showLocate
                    ? MediaLibraryLocateButton(onPressed: onLocate)
                    : null,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Folder pin that uses the same 16:9 + info-block chrome as search folders.
class MediaLibraryFolderGridCard extends StatelessWidget {
  const MediaLibraryFolderGridCard({
    super.key,
    required this.collection,
    required this.titleScale,
    required this.onTap,
    this.showActivityMenu = true,
  });

  final VideoCollection collection;
  final double titleScale;
  final VoidCallback onTap;
  final bool showActivityMenu;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = constraints.maxWidth;
        final chipSize = MediaLibraryActionDockMetrics.gridChipSize(cardWidth);
        final showMenu = showActivityMenu;
        final textInset = MediaLibraryActionDockMetrics.textInset(
          chipSize: chipSize,
          showMore: showMenu,
          showLocate: false,
          existingPadding:
              MediaListLayoutMetrics.cardGridContentPadding(cardWidth).right,
        );
        final radius = (cardWidth * 0.09).clamp(4.0, 40.0);
        final titleFontSize = MediaLibraryLayoutDefaults.titleFontSize(
          cardWidth,
          titleScale,
        );
        final metaFontSize = MediaLibraryLayoutDefaults.metaFontSize(
          titleFontSize,
        );
        final thumbnailPath = collection.thumbnailPath;
        final hasThumbnail =
            thumbnailPath != null && thumbnailPath.isNotEmpty;

        return MediaLibraryGridCard(
          radius: radius,
          isSelected: false,
          onTap: onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AspectRatio(
                    aspectRatio: MediaLibraryMediaGridCard.coverAspectRatio,
                    child: LayoutBuilder(
                      builder: (context, thumbConstraints) {
                        final iconSize = thumbConstraints.maxWidth * 0.15;
                        final iconPadding = iconSize * 0.4;
                        final borderRadius = iconSize * 0.6;
                        final placeholder = FolderPlaceholderCover(
                          folderId: collection.id,
                          folderName: collection.name,
                          coverLabel: collection.coverLabel,
                        );
                        return ColoredBox(
                          color: Colors.black26,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              hasThumbnail
                                  ? CachedThumbnailWidget(
                                      videoId: collection.id,
                                      thumbnailPath: thumbnailPath,
                                      cacheWidth: 512,
                                      cacheHeight: 288,
                                      placeholder: const SizedBox.expand(
                                        child: ColoredBox(
                                          color: Colors.black26,
                                        ),
                                      ),
                                      errorWidget: placeholder,
                                    )
                                  : placeholder,
                              if (hasThumbnail)
                                Positioned(
                                  left: 0,
                                  top: 0,
                                  child: Container(
                                    padding: EdgeInsets.all(iconPadding),
                                    decoration: BoxDecoration(
                                      color: Colors.black45,
                                      borderRadius: BorderRadius.only(
                                        bottomRight: Radius.circular(
                                          borderRadius,
                                        ),
                                      ),
                                    ),
                                    child: Icon(
                                      Icons.folder,
                                      size: iconSize,
                                      color: Colors.blueAccent.withValues(
                                        alpha: 0.9,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: MediaListLayoutMetrics.cardGridContentPadding(
                        cardWidth,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              collection.name,
                              style: TextStyle(
                                fontSize: titleFontSize,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                              maxLines: 10,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Padding(
                            padding: EdgeInsets.only(right: textInset),
                            child: Text(
                              '${collection.childrenIds.length} 个项目',
                              style: TextStyle(
                                fontSize: metaFontSize,
                                color: Colors.white54,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              MediaLibraryActionDock(
                chipSize: chipSize,
                more: showMenu
                    ? MediaLibraryActivityMenuButton(
                        targetId: collection.id,
                        isCollection: true,
                        allowHide: false,
                        fillSlot: true,
                      )
                    : null,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _WatchProgressBar extends StatelessWidget {
  const _WatchProgressBar({required this.item});

  final VideoItem item;

  @override
  Widget build(BuildContext context) {
    return Selector<MediaPlaybackService, ({bool isCurrent, int durationMs})>(
      selector: (context, service) {
        final isCurrent = service.currentItem?.id == item.id;
        if (!isCurrent) {
          return (isCurrent: false, durationMs: 0);
        }
        return (
          isCurrent: true,
          durationMs: service.duration.inMilliseconds,
        );
      },
      builder: (context, data, child) {
        final isCurrent = data.isCurrent;
        final durationMs = isCurrent ? data.durationMs : item.durationMs;
        Widget buildProgress(int positionMs) {
          final shouldShow = durationMs > 0 && (isCurrent || positionMs > 0);
          if (!shouldShow) return const SizedBox.shrink();
          return SizedBox(
            height: 4,
            child: LinearProgressIndicator(
              value: (positionMs / durationMs).clamp(0.0, 1.0),
              backgroundColor: Colors.white24,
              color: Colors.redAccent,
            ),
          );
        }

        if (!isCurrent) return buildProgress(item.lastPositionMs);
        final service = context.read<MediaPlaybackService>();
        return ValueListenableBuilder<Duration>(
          valueListenable: service.coarsePositionNotifier,
          builder: (_, position, _) =>
              buildProgress(position.inMilliseconds),
        );
      },
    );
  }
}
