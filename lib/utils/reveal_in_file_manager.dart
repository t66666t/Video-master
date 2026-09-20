import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

/// Arguments for `explorer.exe /select, <file>`.
///
/// `/select,` and the path MUST be separate argv entries. Merging them into
/// `/select,$path` makes Dart quote the whole token when the path has spaces:
/// `"/select,C:\Users\My Name\file.srt"`. Explorer then fails to parse it and
/// opens some other folder. The subtitle file body is never read here.
List<String> windowsExplorerSelectArguments(String filePath) {
  return <String>['/select,', p.windows.normalize(filePath)];
}

/// Opens the OS file manager on [path] and selects the file when possible.
///
/// Windows: Explorer `/select`.
/// macOS: Finder `open -R`.
/// Linux: FileManager1.ShowItems, then the parent folder.
/// Android/iOS: open the parent folder, then the file as a last resort.
Future<bool> revealInFileManager(String path) async {
  if (kIsWeb) return false;
  final String normalized = p.normalize(path);
  final File file = File(normalized);
  final bool fileExists = await file.exists();
  final String directoryPath = fileExists
      ? p.dirname(normalized)
      : (await Directory(normalized).exists()
            ? normalized
            : p.dirname(normalized));

  if (Platform.isWindows) {
    final String windowsPath = p.windows.normalize(
      fileExists ? file.absolute.path : normalized,
    );
    if (fileExists) {
      // Exit code 1 is normal for explorer.exe even when the window opened.
      await Process.run(
        'explorer.exe',
        windowsExplorerSelectArguments(windowsPath),
      );
      return true;
    }
    await Process.run('explorer.exe', <String>[
      p.windows.normalize(directoryPath),
    ]);
    return true;
  }

  if (Platform.isMacOS) {
    if (fileExists) {
      final ProcessResult result = await Process.run('open', <String>[
        '-R',
        normalized,
      ]);
      return result.exitCode == 0;
    }
    final ProcessResult result = await Process.run('open', <String>[
      directoryPath,
    ]);
    return result.exitCode == 0;
  }

  if (Platform.isLinux) {
    if (fileExists && await _linuxShowItem(normalized)) {
      return true;
    }
    final ProcessResult result = await Process.run('xdg-open', <String>[
      directoryPath,
    ]);
    return result.exitCode == 0;
  }

  final String openTarget = await Directory(directoryPath).exists()
      ? directoryPath
      : normalized;
  final result = await OpenFilex.open(openTarget);
  if (result.type == ResultType.done) return true;
  if (openTarget == normalized) return false;
  final fallback = await OpenFilex.open(normalized);
  return fallback.type == ResultType.done;
}

Future<bool> _linuxShowItem(String filePath) async {
  final String uri = Uri.file(filePath).toString();
  try {
    final ProcessResult dbus = await Process.run('dbus-send', <String>[
      '--session',
      '--type=method_call',
      '--dest=org.freedesktop.FileManager1',
      '/org/freedesktop/FileManager1',
      'org.freedesktop.FileManager1.ShowItems',
      'array:string:$uri',
      'string:',
    ]);
    if (dbus.exitCode == 0) return true;
  } catch (_) {}
  return false;
}
