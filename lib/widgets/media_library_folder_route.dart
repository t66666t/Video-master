import 'package:flutter/material.dart';

import '../theme/app_page_transitions.dart';

/// Route name for one library folder. Breadcrumbs pop back to this name.
@visibleForTesting
String mediaLibraryFolderRouteName(String folderId) =>
    'media-library-folder:$folderId';

/// Opens a media-library folder with the app-wide zoom page transition.
///
/// Enter and exit both wait until after the first frame, same as every other
/// [AppMaterialPageRoute]. A folder is heavy enough that a zoom started during
/// the navigation is already finished when that frame is painted.
///
/// [restored] is the cold-start reopen of the last folder: the page is shown
/// immediately, with no entrance zoom.
class MediaLibraryFolderRoute<T> extends AppMaterialPageRoute<T> {
  MediaLibraryFolderRoute({
    required super.builder,
    super.settings,
    this.restored = false,
  });

  final bool restored;

  @override
  bool get delayPushOneFrame => !restored;

  @override
  Duration get transitionDuration =>
      restored ? Duration.zero : super.transitionDuration;

  @override
  Duration get reverseTransitionDuration => restored
      ? const Duration(milliseconds: 300)
      : super.reverseTransitionDuration;
}

Route<T> buildMediaLibraryFolderRoute<T>({
  required WidgetBuilder builder,
  String? folderId,
  bool restored = false,
}) {
  return MediaLibraryFolderRoute<T>(
    builder: builder,
    restored: restored,
    settings: RouteSettings(
      name: folderId == null ? null : mediaLibraryFolderRouteName(folderId),
    ),
  );
}

/// Drops every folder above [folderId] in one turn, without playing each exit.
///
/// [Navigator.popUntil] keeps a route present while its exit animation runs, so
/// a deep jump paints the page underneath (often the library home) before the
/// target. Removing those routes outright leaves the tapped folder on screen.
///
/// Returns whether [folderId] was found. When it was not, the navigator is
/// already on the first route and the caller can place that folder directly.
bool popMediaLibraryToFolder(NavigatorState navigator, {String? folderId}) {
  final target = folderId == null
      ? null
      : mediaLibraryFolderRouteName(folderId);
  final foundRoot = folderId == null;
  for (var guard = 0; guard < 64; guard++) {
    Route<dynamic>? top;
    navigator.popUntil((route) {
      top = route;
      return true;
    });
    final route = top;
    if (route == null) return foundRoot;
    if (target != null && route.settings.name == target) return true;
    if (route.isFirst) return foundRoot;
    navigator.removeRoute(route);
  }
  return foundRoot;
}
