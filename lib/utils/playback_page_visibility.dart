import 'package:flutter/widgets.dart';

import '../services/media_playback_service.dart';

/// Establishes visibility without treating a popup as leaving the player.
///
/// ModalRoute.isCurrent is false underneath the speed picker too. Passing that
/// value directly to setPlaybackPageVisible deselects Bilibili's video track on
/// mobile while its external audio keeps playing. Only PageRoute-aware exit
/// callbacks (or app backgrounding) should hide the playback page.
void registerPlaybackPageIfCurrent(BuildContext context, Object owner) {
  if (ModalRoute.of(context)?.isCurrent == true) {
    MediaPlaybackService().setPlaybackPageVisible(owner, true);
  }
}
