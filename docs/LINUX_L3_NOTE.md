# Linux L3 — Import + playback smoke + file-manager reveal

## Scope
- Import parity (file / folder / drag-drop) with Windows for local media.
- media_kit plays en/zh samples without crashing (no sound card OK).
- Library overflow menu: **在文件管理器中显示** → `revealInFileManager`.
- Unblock Linux-safe directory / reveal gates that were `Platform.isWindows`-only.

## Smoke checklist (manual Debug)
1. Cold start Linux debug/release build.
2. Import folder `/workspace/Video-master-test/videos/en` (and/or `zh`) via:
   - Import menu → folder
   - Multi-file pick
   - Drag-drop onto library (paths may arrive as `file://…`; normalizer strips URI)
3. Library lists new items; open `en_dialogue_practice.mp4` and `zh_dialogue_practice.mp4`.
4. On a local item ⋯ menu → **在文件管理器中显示** (DBus ShowItems, else `xdg-open` parent).
5. Optional: toolbar **大文件目录** on Linux shows app-data path + reveal (migrate remains Windows-only).

## Automated
```bash
export PATH="/home/box/flutter/bin:$PATH"
cd /workspace/Video-master-src
flutter test test/reveal_in_file_manager_test.dart \
  test/local_filesystem_path_test.dart \
  test/linux_l3_import_path_smoke_test.dart \
  test/media_library_activity_menu_test.dart
```

## Residual risks
- Headless / no DBus session: ShowItems fails; xdg-open parent should still work if a file manager is installed.
- ALSA “no sound card” warnings are environment noise, not a playback crash.
- Large-data **migrate** intentionally stays Windows-only (`resolveLargeDataRootDir` ignores custom root on Linux).
- Full GUI cold-start → import → play still needs a manual Debug pass on a display session.
