/// Arbitrates the player gestures that are recognized outside a shared
/// Flutter gesture arena.
///
/// A touch long-press and a raw two-finger transform must never own the same
/// pointer sequence. The winner keeps ownership until all fingers involved in
/// that sequence have left the player.
class VideoGestureSessionGate {
  final Set<int> _activePointers = <int>{};
  bool _longPressActive = false;
  bool _blocksTransforms = false;

  bool get blocksTransforms => _blocksTransforms;

  void pointerDown(int pointer) {
    _activePointers.add(pointer);
  }

  void pointerUp(int pointer) {
    _activePointers.remove(pointer);
    _releaseTransformBlockIfSessionEnded();
  }

  /// Returns false when a multi-touch transform session already owns the
  /// sequence. Otherwise long-press becomes the exclusive owner.
  bool tryStartLongPress({
    required bool transformActive,
    required int transformPointerCount,
  }) {
    if (_blocksTransforms ||
        transformActive ||
        transformPointerCount >= 2 ||
        _activePointers.length > 1) {
      return false;
    }
    _longPressActive = true;
    _blocksTransforms = true;
    return true;
  }

  void endLongPress() {
    _longPressActive = false;
    _releaseTransformBlockIfSessionEnded();
  }

  void reset() {
    _activePointers.clear();
    _longPressActive = false;
    _blocksTransforms = false;
  }

  void _releaseTransformBlockIfSessionEnded() {
    if (!_longPressActive && _activePointers.isEmpty) {
      _blocksTransforms = false;
    }
  }
}
