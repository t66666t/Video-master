import 'package:flutter/material.dart';

/// A stable sidebar slot beside a live player. Width includes the splitter,
/// and each panel is laid out at its final width while the slot animates.
/// Retaining the subtitle panel avoids rebuilding its document on every visit.
/// One element per panel key also makes interrupted A -> B -> A transitions safe.
class DesktopPlayerSidebar extends StatefulWidget {
  const DesktopPlayerSidebar({
    super.key,
    required this.panelId,
    required this.panel,
    required this.width,
    required this.retainedId,
    required this.retainedPanel,
    required this.retainedWidth,
    required this.viewportSize,
    this.divider,
    this.dividerWidth = 0,
    this.onLeft = false,
    this.resizing = false,
  });

  final Object? panelId;
  final Widget? panel;
  final double width;
  final Object retainedId;
  final Widget retainedPanel;
  final double retainedWidth;
  final Size viewportSize;
  final Widget? divider;
  final double dividerWidth;
  final bool onLeft;
  final bool resizing;

  @override
  State<DesktopPlayerSidebar> createState() => _DesktopPlayerSidebarState();
}

class _Panel {
  _Panel(this.child, this.width, this.divider, this.dividerWidth);
  Widget child;
  double width;
  Widget? divider;
  double dividerWidth;
}

class _DesktopPlayerSidebarState extends State<DesktopPlayerSidebar> {
  final Map<Object, _Panel> _panels = {};
  bool _viewportChanged = false;

  void _updatePanels() {
    final id = widget.panelId;
    if (id != null) {
      _panels[id] = _Panel(
        id == widget.retainedId ? widget.retainedPanel : widget.panel!,
        widget.width,
        widget.divider,
        widget.dividerWidth,
      );
    }
    final retained = _panels[widget.retainedId];
    if (retained != null) {
      // Even while hidden, deliver new media/subtitles and visibility changes.
      retained.child = widget.retainedPanel;
      retained.width = widget.retainedWidth;
    }
  }

  @override
  void initState() {
    super.initState();
    _updatePanels();
  }

  @override
  void didUpdateWidget(DesktopPlayerSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _viewportChanged = oldWidget.viewportSize != widget.viewportSize;
    _updatePanels();
  }

  void _removeHidden(Object id) {
    if (!mounted || id == widget.panelId || id == widget.retainedId) return;
    setState(() => _panels.remove(id));
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final immediate = disableAnimations || widget.resizing || _viewportChanged;
    final extent = widget.panelId == null
        ? 0.0
        : widget.width + widget.dividerWidth;
    return AnimatedContainer(
      duration: immediate ? Duration.zero : const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      width: extent,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            for (final entry in _panels.entries)
              Positioned.fill(
                key: ValueKey(entry.key),
                child: OverflowBox(
                  alignment: widget.onLeft
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  minWidth: entry.value.width + entry.value.dividerWidth,
                  maxWidth: entry.value.width + entry.value.dividerWidth,
                  child: AnimatedOpacity(
                    opacity: entry.key == widget.panelId ? 1 : 0,
                    duration: disableAnimations
                        ? Duration.zero
                        : const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    onEnd: () => _removeHidden(entry.key),
                    child: IgnorePointer(
                      ignoring: entry.key != widget.panelId,
                      child: ExcludeFocus(
                        excluding: entry.key != widget.panelId,
                        child: ExcludeSemantics(
                          excluding: entry.key != widget.panelId,
                          child: TickerMode(
                            enabled: entry.key == widget.panelId,
                            // Fade runs outside the child's TickerMode so the
                            // outgoing panel can finish without its own tickers.
                            child: RepaintBoundary(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (!widget.onLeft &&
                                      entry.value.divider != null)
                                    SizedBox(
                                      width: entry.value.dividerWidth,
                                      child: entry.value.divider,
                                    ),
                                  SizedBox(
                                    width: entry.value.width,
                                    child: entry.value.child,
                                  ),
                                  if (widget.onLeft &&
                                      entry.value.divider != null)
                                    SizedBox(
                                      width: entry.value.dividerWidth,
                                      child: entry.value.divider,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
