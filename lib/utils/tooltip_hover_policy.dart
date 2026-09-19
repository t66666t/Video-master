import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

/// App-wide hover-tooltip timing. Material 3 defaults to zero delay, which
/// makes labels pop the instant a pointer crosses a button.
const Duration kAppTooltipWaitDuration = Duration(milliseconds: 700);

/// Tracks whether a finger/stylus is currently down so leftover mouse hover
/// cannot keep driving Tooltips or the Android synthetic-hover fallback.
class TooltipHoverPolicy {
  TooltipHoverPolicy._();

  static final Set<int> _touchPointers = <int>{};

  static bool get suppressSyntheticHover => _touchPointers.isNotEmpty;

  static bool isTouchLike(PointerDeviceKind kind) {
    return kind == PointerDeviceKind.touch ||
        kind == PointerDeviceKind.stylus ||
        kind == PointerDeviceKind.invertedStylus;
  }

  static void observe(PointerEvent event) {
    if (!isTouchLike(event.kind)) return;
    if (event is PointerDownEvent) {
      _touchPointers.add(event.pointer);
      return;
    }
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _touchPointers.remove(event.pointer);
    }
  }

  static void clear() {
    _touchPointers.clear();
  }

  @visibleForTesting
  static void resetForTesting() => clear();
}
