import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/video_collection.dart';
import '../models/video_item.dart';
import '../services/media_playback_service.dart';
import 'cached_thumbnail_widget.dart';
import 'media_list_layout_metrics.dart';
import 'media_library_locate_button.dart';

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
    this.onSelectionTap,
    this.onSelectionPanStart,
    this.onSelectionPanUpdate,
    this.onSelectionPanEnd,
    this.onSelectionLongPressStart,
    this.onSelectionLongPressMoveUpdate,
    this.onSelectionLongPressEnd,
    this.onShowInParentFolder,
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
    this.onSelectionTap,
    this.onSelectionPanStart,
    this.onSelectionPanUpdate,
    this.onSelectionPanEnd,
    this.onSelectionLongPressStart,
    this.onSelectionLongPressMoveUpdate,
    this.onSelectionLongPressEnd,
    this.onShowInParentFolder,
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
  final double titleScale;
  final GestureTapCallback? onSelectionTap;
  final GestureDragStartCallback? onSelectionPanStart;
  final GestureDragUpdateCallback? onSelectionPanUpdate;
  final GestureDragEndCallback? onSelectionPanEnd;
  final GestureLongPressStartCallback? onSelectionLongPressStart;
  final GestureLongPressMoveUpdateCallback? onSelectionLongPressMoveUpdate;
  final GestureLongPressEndCallback? onSelectionLongPressEnd;
  final VoidCallback? onShowInParentFolder;

  bool get _isCollection => _collection != null;

  double _resolveLocateButtonHeight({
    required BuildContext context,
    required BoxConstraints constraints,
    required MediaListLayoutMetrics metrics,
    required double thumbnailExtent,
  }) {
    final leadingWidth = showThumbnail
        ? thumbnailExtent + metrics.thumbnailInset * 2
        : showIndex
        ? metrics.indexWidth
        : 0.0;
    final informationWidth = math.max(0.0, constraints.maxWidth - leadingWidth);
    final titleWidth = math.max(
      0.0,
      informationWidth -
          (showThumbnail ? 0 : metrics.horizontalPadding) -
          metrics.horizontalPadding,
    );
    final titlePainter = TextPainter(
      text: TextSpan(
        text: _isCollection ? _collection!.name : _video!.title,
        style: DefaultTextStyle.of(context).style.merge(
          TextStyle(
            fontSize: metrics.titleSize,
            height: 1.08,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      maxLines: 2,
      ellipsis: '…',
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: titleWidth);

    final metadataHeight = math.max(
      metrics.metadataSize,
      metrics.metadataIconSize,
    );
    final innerHeight = math.max(
      0.0,
      constraints.maxHeight - metrics.verticalPadding * 2,
    );
    final maximumTitleHeight = math.max(
      0.0,
      innerHeight - metrics.informationGap - metadataHeight,
    );
    final renderedTitleHeight = math.min(
      titlePainter.height,
      maximumTitleHeight,
    );
    final usedInformationHeight =
        renderedTitleHeight + metrics.informationGap + metadataHeight;
    final centeredTopSpace = math.max(
      0.0,
      (innerHeight - usedInformationHeight) / 2,
    );
    final titleBottom =
        metrics.verticalPadding + centeredTopSpace + renderedTitleHeight;
    final availableBelowTitle = math.max(
      0.0,
      constraints.maxHeight - titleBottom,
    );
    final minimumMetadataBand =
        metrics.verticalPadding + metrics.informationGap + metadataHeight;
    final desiredHeight = constraints.maxHeight * 0.50;
    final safeMaximum = math.max(minimumMetadataBand, availableBelowTitle);
    return math.min(safeMaximum, math.max(desiredHeight, minimumMetadataBand));
  }

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
        final locateButtonHeight = _resolveLocateButtonHeight(
          context: context,
          constraints: constraints,
          metrics: metrics,
          thumbnailExtent: thumbnailExtent,
        );
        final locateButtonWidth = math.min(
          constraints.maxWidth * 0.24,
          math.max(locateButtonHeight * 2.15, metrics.visualShortSide * 0.78),
        );
        final metadataTrailingPadding = showLocateButton
            ? math.max(0.0, locateButtonWidth - metrics.horizontalPadding)
            : 0.0;

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
                          metadataTrailingPadding: metadataTrailingPadding,
                        ),
                      ),
                    ),
                    if (!showLocateButton)
                      Padding(
                        padding: EdgeInsets.only(
                          right: metrics.trailingPadding,
                        ),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 160),
                          child: isSelectionMode
                              ? GestureDetector(
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
                                )
                              : Icon(
                                  _isCollection
                                      ? Icons.chevron_right_rounded
                                      : Icons.play_arrow_rounded,
                                  key: ValueKey(_isCollection),
                                  color: Colors.white38,
                                  size: metrics.trailingSize,
                                ),
                        ),
                      ),
                  ],
                ),
                if (showLocateButton)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: MediaLibraryLocateButton(
                      cardWidth: constraints.maxWidth,
                      width: locateButtonWidth,
                      height: locateButtonHeight,
                      iconSize: locateButtonHeight * 0.60,
                      onPressed: onShowInParentFolder!,
                    ),
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
    final placeholderIcon = _isCollection
        ? Icons.folder_rounded
        : _video!.type == MediaType.audio
        ? Icons.music_note_rounded
        : Icons.movie_rounded;
    final placeholderColor = _isCollection ? Colors.blueAccent : Colors.white30;
    final path = _isCollection
        ? _collection!.thumbnailPath
        : _video!.thumbnailPath;
    final id = _isCollection ? _collection!.id : _video!.id;

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
                  placeholder: Icon(
                    placeholderIcon,
                    color: placeholderColor,
                    size: extent * 0.42,
                  ),
                  errorWidget: Icon(
                    placeholderIcon,
                    color: placeholderColor,
                    size: extent * 0.42,
                  ),
                )
              : Icon(
                  placeholderIcon,
                  color: placeholderColor,
                  size: extent * 0.42,
                ),
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
    double metadataTrailingPadding = 0,
  }) {
    final title = _isCollection ? _collection!.name : _video!.title;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(
          fit: FlexFit.loose,
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
        SizedBox(height: metrics.informationGap),
        if (_isCollection)
          Padding(
            padding: EdgeInsets.only(right: metadataTrailingPadding),
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
            trailingPadding: metadataTrailingPadding,
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
