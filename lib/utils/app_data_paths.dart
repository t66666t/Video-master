import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Folder name under XDG data home for Linux fallbacks.
///
/// Aligns with `linux/CMakeLists.txt` `BINARY_NAME` and pubspec `name`
/// (`video_player_app`). Application id is `com.example.video_player_app`.
const String kAppDataFolderName = 'video_player_app';

/// Resolves a writable directory for app-owned data (library, batch cache, …).
///
/// **Linux:** prefers [getApplicationSupportDirectory] (stable XDG data home),
/// then [getApplicationDocumentsDirectory]. Documents often throws
/// [MissingPlatformDirectoryException] when XDG user-dirs `DOCUMENTS` is unset.
///
/// **Other platforms:** prefers documents first so existing `library.json` and
/// related files keep their historical location, then support.
///
/// If both path_provider calls fail with [MissingPlatformDirectoryException]
/// (or similar), falls back to `$XDG_DATA_HOME/<app>` or `~/.local/share/<app>`,
/// creating the directory recursively.
Future<Directory> resolveAppDataDirectory() async {
  final preferred = Platform.isLinux
      ? <Future<Directory> Function()>[
          getApplicationSupportDirectory,
          getApplicationDocumentsDirectory,
        ]
      : <Future<Directory> Function()>[
          getApplicationDocumentsDirectory,
          getApplicationSupportDirectory,
        ];

  Object? lastError;
  for (final getter in preferred) {
    try {
      final dir = await getter();
      return dir;
    } on MissingPlatformDirectoryException catch (e, st) {
      lastError = e;
      debugPrint('resolveAppDataDirectory: path_provider unavailable: $e');
      debugPrint('$st');
    } catch (e, st) {
      // Catch-all for platform channel / plugin failures with similar effect.
      lastError = e;
      debugPrint('resolveAppDataDirectory: path_provider failed: $e');
      debugPrint('$st');
    }
  }

  debugPrint(
    'resolveAppDataDirectory: using XDG data-home fallback '
    '(lastError=$lastError)',
  );
  return createXdgDataHomeFallback();
}

/// `$XDG_DATA_HOME/<app>` or `~/.local/share/<app>`, created if missing.
@visibleForTesting
Future<Directory> createXdgDataHomeFallback({
  String appFolderName = kAppDataFolderName,
  Map<String, String>? environment,
}) async {
  final env = environment ?? Platform.environment;
  final xdgDataHome = env['XDG_DATA_HOME'];
  final String base;
  if (xdgDataHome != null && xdgDataHome.trim().isNotEmpty) {
    base = xdgDataHome.trim();
  } else {
    final home = env['HOME'];
    if (home != null && home.isNotEmpty) {
      base = p.join(home, '.local', 'share');
    } else {
      // Extremely constrained environments: keep data next to CWD.
      base = p.join('.local', 'share');
    }
  }

  final dir = Directory(p.join(base, appFolderName));
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}
