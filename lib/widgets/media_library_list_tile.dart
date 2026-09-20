import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/video_collection.dart';
import '../models/video_item.dart';
import '../services/media_playback_service.dart';
import 'cached_thumbnail_widget.dart';
import 'folder_placeholder_cover.dart';
import 'media_list_layout_metrics.dart';
import 'media_library_locate_button.dart';
import 'media_library_activity_menu.dart';
import 'media_library_action_dock.dart';

/// Shared, information-dense row used by both media-library screens.
class MediaLibraryListTile extends StatelessWidget {
  const MediaLibraryListTile.video({
    super.key,
    required VideoItem item,
    required this.index,
    required this.showIndex,
    required this.showThumbnail,
    required this.isSelected,
    required this.isSelectionMode,
    required this.onTap,
    required this.titleScale,
    this.onSecondaryTap,
    this.onSelectionTap,
    this.onSelectionPanStart,
    this.onSelectionPanUpdate,
    this.onSelectionPanEnd,
    this.onSelectionLongPressStart,
    this.onSelectionLongPressMoveUpdate,
    this.onSelectionLongPressEnd,
    this.onShowInParentFolder,
    this.showActivityMenu = false,
    this.allowHide = false,
    this.relativePath,
  }) : _video = item,
       _collection = null;

  const MediaLibraryListTile.collection({
    super.key,
    required VideoCollection collection,
    required this.index,
    required this.showIndex,
    required this.showThumbnail,
    required this.isSelected,
    required this.isSelectionMode,
    required this.onTap,
    required this.titleScale,
    this.onSecondaryTap,
    this.onSelectionTap,
    this.onSelectionPanStart,
    this.onSelectionPanUpdate,
    this.onSelectionPanEnd,
    this.onSelectionLongPressStart,
    this.onSelectionLongPressMoveUpdate,
    this.onSelectionLongPressEnd,
    this.onShowInParentFolder,
    this.showActivityMenu = false,
    this.allowHide = false,
    this.relativePath,
  }) : _collection = collection,
       _video = null;

  final VideoItem? _video;
  final VideoCollection? _collection;
  final int index;
  final bool showIndex;
  final bool showThumbnail;
  final bool isSelected;
  final bool isSelectionMode;
  final VoidCallback onTap;

  /// 键鼠右击：进入选择并选中/取消该项，不走左键打开或播放。
  final VoidCallback? onSecondaryTap;
  final double titleScale;
  final GestureTapCallback? onSelectionTap;
  final GestureDragStartCallback? onSelectionPanStart;
  final GestureDragUpdateCallback? onSelectionPanUpdate;
  final GestureDragEndCallback? onSelectionPanEnd;
  final GestureLongPressStartCallback? onSelectionLongPressStart;
  final GestureLongPressMoveUpdateCallback? onSelectionLongPressMoveUpdate;
  final GestureLongPressEndCallback? onSelectionLongPressEnd;
  final VoidCallback? onShowInParentFolder;
  final bool showActivityMenu;
  final bool allowHide;
  final String? relativePath;

  bool get _isCollection => _collection != null;

  @override
  Widget build(BuildContext context) {
    final accent = Colors.blueAccent;
    return LayoutBuilder(
      builder: (context, constraints) {
        final metrics = MediaListLayoutMetrics.forTile(
          screenShortestSide: MediaQuery.sizeOf(context).shortestSide,
          cellWidth: constraints.maxWidth,
          rowHeight: constraints.maxHeight,
          titleSetting: titleScale,
        );
        final thumbnailExtent = metrics.thumbnailExtent(constraints.maxWidth);
        final showLocateButton =
            onShowInParentFolder != null && !isSelectionMode;
        final showMenu = showActivityMenu && !isSelectionMode;
        final chipSize = MediaLibraryActionDockMetrics.listChipSize(
          constraints.maxHeight,
        );
        final textInset = MediaLibraryActionDockMetrics.textInset(
          chipSize: chipSize,
          showMore: showMenu,
          showLocate: showLocateButton,
          existingPadding: metrics.horizontalPadding,
        );

        return Material(
          key: const ValueKey('media-list-card'),
          color: isSelected
              ? accent.withValues(alpha: 0.14)
              : const Color(0xFF272A2F),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(metrics.radius),
            side: BorderSide(
              color: isSelected
                  ? accent.withValues(alpha: 0.9)
                  : Colors.white.withValues(alpha: 0.075),
              width: isSelected
                  ? metrics.selectedBorderWidth
                  : metrics.borderWidth,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onSecondaryTap: onSecondaryTap,
            hoverColor: Colors.white.withValues(alpha: 0.045),
            splashColor: accent.withValues(alpha: 0.12),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Row(
                  children: [
                    if (showIndex && !showThumbnail)
                      SizedBox(
                        width: metrics.indexWidth,
                        child: Text(
                          '${index + 1}'.padLeft(2, '0'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white38,
                            fontSize: metrics.indexFontSize,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    if (showThumbnail)
                      Padding(
                        padding: EdgeInsets.only(
                          left: metrics.thumbnailInset,
                          right: metrics.thumbnailInset,
                          top: metrics.thumbnailInset,
                          bottom: metrics.thumbnailInset,
                        ),
                        child: SizedBox.square(
                          key: const ValueKey('media-list-thumbnail'),
                          dimension: thumbnailExtent,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(
                              thumbnailExtent * 0.14,
                            ),
                            child: _buildThumbnail(
                              context,
                              thumbnailExtent,
                              metrics.progressThickness,
                              indexLabel: showIndex
                                  ? '${index + 1}'.padLeft(2, '0')
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(
                          left: showThumbnail ? 0 : metrics.horizontalPadding,
                          right: metrics.horizontalPadding,
                          top: metrics.verticalPadding,
                          bottom: metrics.verticalPadding,
                        ),
                        child: _buildInformation(
                          metrics,
                          textInset: textInset,
                        ),
                      ),
                    ),
                    if (isSelectionMode)
                      Padding(
                        padding: EdgeInsets.only(
                          right: metrics.trailingPadding,
                        ),
                        child: GestureDetector(
                          key: const ValueKey(
                            'media-list-selection-handle',
                          ),
                          behavior: HitTestBehavior.opaque,
                          onTap: onSelectionTap,
                          onPanStart: onSelectionPanStart,
                          onPanUpdate: onSelectionPanUpdate,
                          onPanEnd: onSelectionPanEnd,
                          onLongPressStart: onSelectionLongPressStart,
                          onLongPressMoveUpdate:
                              onSelectionLongPressMoveUpdate,
                          onLongPressEnd: onSelectionLongPressEnd,
                          child: Icon(
                            isSelected
                                ? Icons.check_circle_rounded
                                : Icons.radio_button_unchecked_rounded,
                            key: ValueKey(isSelected),
                            color: isSelected ? accent : Colors.white30,
                            size: metrics.trailingSize,
                          ),
                        ),
                      )
                    else if (!showLocateButton && !showMenu)
                      Padding(
                        padding: EdgeInsets.only(
                          right: metrics.trailingPadding,
                        ),
                        child: Icon(
                          _isCollection
                              ? Icons.chevron_right_rounded
                              : Icons.play_arrow_rounded,
                          key: ValueKey(_isCollection),
                          color: Colors.white38,
                          size: metrics.trailingSize,
                        ),
                      ),
                  ],
                ),
                if (showMenu || showLocateButton)
                  MediaLibraryActionDock(
                    chipSize: chipSize,
                    more: showMenu
                        ? MediaLibraryActivityMenuButton(
                            targetId: _video?.id ?? _collection!.id,
                            isCollection: _isCollection,
                            allowHide: allowHide && !_isCollection,
                            onLocate: onShowInParentFolder,
                            fillSlot: true,
                          )
                        : null,
                    locate: showLocateButton
                        ? MediaLibraryLocateButton(
                            onPressed: onShowInParentFolder!,
                          )
                        : null,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildThumbnail(
    BuildContext context,
    double extent,
    double progressThickness, {
    String? indexLabel,
  }) {
    final collection = _collection;
    final video = _video;
    final placeholderIcon = collection != null
        ? Icons.folder_rounded
        : video!.type == MediaType.audio
        ? Icons.music_note_rounded
        : Icons.movie_rounded;
    final placeholderColor = collection != null
        ? Colors.blueAccent
        : Colors.white30;
    final path = collection != null
        ? collection.thumbnailPath
        : video!.thumbnailPath;
    final id = collection != null ? collection.id : video!.id;
    final folderPlaceholder = collection != null
        ? FolderPlaceholderCover(
            folderId: collection.id,
            folderName: collection.name,
            coverLabel: collection.coverLabel,
          )
        : null;
    final mediaPlaceholder = Icon(
      placeholderIcon,
      color: placeholderColor,
      size: extent * 0.42,
    );
    final fallback = folderPlaceholder ?? mediaPlaceholder;

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: const Color(0xFF17191D),
          child: path != null && path.isNotEmpty
              ? CachedThumbnailWidget(
                  videoId: id,
                  thumbnailPath: path,
                  fit: BoxFit.cover,
                  placeholder: fallback,
                  errorWidget: fallback,
                )
              : fallback,
        ),
        if (_video != null) _buildThumbnailProgress(context, progressThickness),
        if (indexLabel != null)
          Positioned(
            left: extent * 0.06,
            top: extent * 0.06,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.58),
                borderRadius: BorderRadius.circular(extent * 0.08),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: extent * 0.07,
                  vertical: extent * 0.025,
                ),
                child: Text(
                  indexLabel,
                  key: const ValueKey('media-list-thumbnail-index'),
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: extent * 0.22,
                    height: 1,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildThumbnailProgress(
    BuildContext context,
    double progressThickness,
  ) {
    final video = _video!;
    return Selector<MediaPlaybackService, ({bool current, int duration})>(
      selector: (_, service) {
        final current = service.currentItem?.id == video.id;
        return (
          current: current,
          duration: current && service.duration.inMilliseconds > 0
              ? service.duration.inMilliseconds
              : video.durationMs,
        );
      },
      builder: (_, data, _) {
        Widget buildProgress(int position) {
          if (data.duration <= 0 || (!data.current && position <= 0)) {
            return const SizedBox.shrink();
          }
          return Align(
            alignment: Alignment.bottomCenter,
            child: LinearProgressIndicator(
              minHeight: progressThickness,
              value: (position / data.duration).clamp(0.0, 1.0),
              backgroundColor: Colors.black45,
              color: Colors.redAccent,
            ),
          );
        }

        if (!data.current) return buildProgress(video.lastPositionMs);
        final service = context.read<MediaPlaybackService>();
        return ValueListenableBuilder<Duration>(
          valueListenable: service.coarsePositionNotifier,
          builder: (_, position, _) => buildProgress(position.inMilliseconds),
        );
      },
    );
  }

  Widget _buildInformation(
    MediaListLayoutMetrics metrics, {
    double textInset = 0,
  }) {
    final title = _isCollection ? _collection!.name : _video!.title;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(
          fit: FlexFit.loose,
          child: Padding(
            padding: EdgeInsets.only(right: textInset),
            child: Text(
              title,
              key: const ValueKey('media-list-title'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.94),
                fontSize: metrics.titleSize,
                height: 1.08,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        if (relativePath != null && relativePath!.isNotEmpty) ...[
          SizedBox(height: metrics.informationGap),
          Padding(
            padding: EdgeInsets.only(right: textInset),
            child: Text(
              relativePath!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white38,
                fontSize: metrics.metadataSize,
              ),
            ),
          ),
        ],
        SizedBox(height: metrics.informationGap),
        if (_isCollection)
          Padding(
            padding: EdgeInsets.only(right: textInset),
            child: _buildMetaLine(
              icon: Icons.folder_open_rounded,
              label: '${_collection!.childrenIds.length} 个项目',
              metrics: metrics,
              accent: true,
            ),
          )
        else
          _VideoMetaLine(
            video: _video!,
            metrics: metrics,
            trailingPadding: textInset,
          ),
      ],
    );
  }

  Widget _buildMetaLine({
    required IconData icon,
    required String label,
    required MediaListLayoutMetrics metrics,
    bool accent = false,
  }) {
    return Row(
      key: const ValueKey('media-list-metadata'),
      children: [
        Icon(
          icon,
          size: metrics.metadataIconSize,
          color: accent
              ? Colors.blueAccent
              : Colors.white.withValues(alpha: 0.46),
        ),
        SizedBox(width: metrics.metadataIconGap),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: accent ? Colors.blueAccent.shade100 : Colors.white54,
              fontSize: metrics.metadataSize,
              height: 1,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

class _VideoMetaLine extends StatelessWidget {
  const _VideoMetaLine({
    required this.video,
    required this.metrics,
    this.trailingPadding = 0,
  });

  final VideoItem video;
  final MediaListLayoutMetrics metrics;
  final double trailingPadding;

  @override
  Widget build(BuildContext context) {
    return Selector<MediaPlaybackService, ({bool current, int duration})>(
      selector: (_, service) {
        final current = service.currentItem?.id == video.id;
        return (
          current: current,
          duration: current && service.duration.inMilliseconds > 0
              ? service.duration.inMilliseconds
              : video.durationMs,
        );
      },
      builder: (_, data, _) {
        Widget buildMetadata(int position) {
          final pieces = <String>[
            video.type == MediaType.audio ? '音频' : '视频',
            _formatDuration(data.duration),
          ];
          if (data.duration > 0 && position > 0) {
            pieces.add(
              '已播放 ${(position / data.duration * 100).clamp(0, 100).round()}%',
            );
          }
          return Row(
            key: const ValueKey('media-list-metadata'),
            children: [
              Icon(
                video.type == MediaType.audio
                    ? Icons.graphic_eq_rounded
                    : Icons.smart_display_rounded,
                size: metrics.metadataIconSize,
                color: Colors.white.withValues(alpha: 0.46),
              ),
              SizedBox(width: metrics.metadataIconGap),
              Flexible(
                child: Text(
                  pieces.join('  ·  '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: metrics.metadataSize,
                    height: 1,
                    fontWeight: FontWeight.w500,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              if (trailingPadding > 0) SizedBox(width: trailingPadding),
            ],
          );
        }

        if (!data.current) return buildMetadata(video.lastPositionMs);
        final service = context.read<MediaPlaybackService>();
        return ValueListenableBuilder<Duration>(
          valueListenable: service.coarsePositionNotifier,
          builder: (_, livePosition, _) =>
              buildMetadata(livePosition.inMilliseconds),
        );
      },
    );
  }
}

String _formatDuration(int durationMs) {
  if (durationMs <= 0) return '--:--';
  final totalSeconds = durationMs ~/ 1000;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
