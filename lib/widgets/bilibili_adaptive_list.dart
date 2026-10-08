import 'package:flutter/widgets.dart';

import 'media_library_layout_profile.dart';

/// Narrowest a Bilibili list row (cover, title, import button) gets before
/// the list drops a column.
const double kBilibiliListMinTileWidth = 460;

/// Most columns a Bilibili list uses, as the media library's widest list
/// default.
const int kBilibiliListMaxColumns = 4;

/// Column gap of a multi-column Bilibili list: the media library's list
/// spacing, as a share of the cell width, with no outer padding (the rows
/// keep their own).
const double kBilibiliListSpacingScale =
    MediaLibraryLayoutDefaults.defaultListSpacingScale;

MediaLibraryWidthDistribution _distribute(double width, int columns) =>
    MediaLibraryLayoutDefaults.distributeWidth(
      availableWidth: width,
      columns: columns,
      spacingScale: kBilibiliListSpacingScale,
      paddingScale: 0,
    );

/// How many columns a Bilibili list [width] wide shows: one on phones and
/// narrow windows (the plain list), more as the window gets wider, each at
/// least [kBilibiliListMinTileWidth] wide.
int bilibiliListColumns(double width) {
  if (!width.isFinite || width <= 0) return 1;
  for (var columns = kBilibiliListMaxColumns; columns > 1; columns--) {
    if (_distribute(width, columns).cellWidth >= kBilibiliListMinTileWidth) {
      return columns;
    }
  }
  return 1;
}

/// A Bilibili result list that turns into a grid of rows on wide windows.
///
/// With one column it is the plain [ListView] the pages always showed. Wider
/// windows lay the same rows out in [bilibiliListColumns] columns, spaced
/// as the media library's list grid, with [footer] (loading more, retry,
/// end of list) across the full width. When the column count changes while
/// the window is resized, the list stays near the rows it showed.
class BilibiliAdaptiveList extends StatefulWidget {
  const BilibiliAdaptiveList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.footer,
    this.controller,
    this.padding = EdgeInsets.zero,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  /// Shown after the last row, across the full width.
  final WidgetBuilder? footer;

  final ScrollController? controller;
  final EdgeInsets padding;

  @override
  State<BilibiliAdaptiveList> createState() => _BilibiliAdaptiveListState();
}

class _BilibiliAdaptiveListState extends State<BilibiliAdaptiveList> {
  ScrollController? _own;
  int? _columns;

  ScrollController get _controller =>
      widget.controller ?? (_own ??= ScrollController());

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  /// Keeps the first rows on screen near the top after the column count
  /// changed: rows are about the same height, so the offset scales with
  /// the number of rows.
  void _columnsChanged(int from, int to) {
    final controller = _controller;
    if (!controller.hasClients) return;
    // Read before the new layout clamps it to the new length.
    final before = controller.position.pixels;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !controller.hasClients) return;
      final position = controller.position;
      final target = (before * from / to).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((target - position.pixels).abs() >= 0.5) {
        controller.jumpTo(target);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - widget.padding.horizontal;
        final columns = bilibiliListColumns(width);
        final before = _columns;
        _columns = columns;
        if (before != null && before != columns) {
          _columnsChanged(before, columns);
        }
        final footer = widget.footer;
        final count = widget.itemCount;
        if (columns == 1) {
          return ListView.builder(
            controller: _controller,
            padding: widget.padding,
            itemCount: count + (footer == null ? 0 : 1),
            itemBuilder: (context, index) => index < count
                ? widget.itemBuilder(context, index)
                : footer!(context),
          );
        }
        final cells = _distribute(width, columns);
        final rows = (count + columns - 1) ~/ columns;
        // The same list as with one column, so the scroll position stays.
        return ListView.builder(
          controller: _controller,
          padding: widget.padding,
          itemCount: rows + (footer == null ? 0 : 1),
          itemBuilder: (context, row) {
            if (row >= rows) return footer!(context);
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var column = 0; column < columns; column++) ...[
                  if (column > 0) SizedBox(width: cells.crossSpacing),
                  SizedBox(
                    width: cells.cellWidth,
                    child: row * columns + column < count
                        ? widget.itemBuilder(context, row * columns + column)
                        : null,
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }
}
