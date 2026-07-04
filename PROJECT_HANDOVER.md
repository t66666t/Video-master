# Project Handover Documentation: Flutter Advanced Video Player

**Target Audience:** AI Agents & Developers  
**Version:** 1.0.0+1  
**Last Updated:** 2025-12-15

---

## 1. Project Overview & Architecture

This is a local-first, high-performance video player application built with **Flutter**. It features a custom library management system, advanced subtitle support (auto-scroll, caching), gesture controls, and a persistent "Recycle Bin" feature.

### 1.1 Tech Stack
*   **Framework:** Flutter (Dart)
*   **State Management:** `provider` (MultiProvider pattern at root).
*   **Video Engine:** `video_player` (official plugin).
*   **Persistence:** `shared_preferences` (Settings), JSON file system (Library/Database).
*   **UI Components:** `scrollable_positioned_list` (Subtitles), `file_picker`, `permission_handler`.
*   **Utils:** `video_thumbnail`, `uuid`, `path_provider`.

### 1.2 Directory Structure
```
lib/
├── main.dart                  # Entry point, MultiProvider setup, Theme config.
├── models/                    # Data classes (JSON serialization).
│   ├── subtitle_model.dart    # SubtitleItem (start, end, text).
│   ├── subtitle_style.dart    # SubtitleStyle (color, size, background).
│   ├── video_collection.dart  # Folder/Collection logic.
│   └── video_item.dart        # Core video entity.
├── screens/
│   ├── home_screen.dart       # Grid view of Collections. Drag-to-reorder, Recycle Bin entry.
│   ├── collection_screen.dart # Video Grid within a collection. Import logic here.
│   ├── portrait_video_screen.dart # Vertical player + Subtitle Sidebar.
│   ├── video_player_screen.dart   # Landscape player (immersive).
│   └── recycle_bin_screen.dart    # Restore/Delete permanently logic.
├── services/
│   ├── library_service.dart   # "The Brain". Handles JSON DB, imports, recycle bin.
│   └── settings_service.dart  # "The Config". Handles prefs (toggles, grid sizes).
└── widgets/
    ├── settings_panel.dart    # Bottom sheet for player settings.
    ├── subtitle_overlay.dart  # Renders text on top of video.
    ├── subtitle_sidebar.dart  # The scrolling list of subtitles.
    └── video_controls_overlay.dart # The gesture layer (Seek, Volume, Brightness).
```

---

## 2. Data Models (The Source of Truth)

### 2.1 `VideoItem` (JSON Schema)
The atomic unit of the library.
*   `id` (String): UUID.
*   `path` (String): Absolute file path to the video.
*   `thumbnailPath` (String?): Local path to generated thumbnail (in app cache).
*   `lastPositionMs` (int): Playback memory (resume support).
*   `durationMs` (int): Total duration.
*   `subtitlePath` (String?): Associated subtitle file.
*   `isSubtitleCached` (bool): If true, `subtitlePath` points to app-private storage.

### 2.2 `VideoCollection`
A logical folder containing video IDs.
*   `id` (String): UUID.
*   `name` (String): User-defined name.
*   `videoIds` (List<String>): Ordered list of video IDs belonging to this collection.

### 2.3 `LibraryService` Persistence (`library.json`)
The entire database is stored in `ApplicationDocumentsDirectory/library.json`.
Structure:
```json
{
  "collections": [ ... ],
  "recycleBin": [ ... ],
  "videos": [ ... ] // Flat list of all videos, referenced by ID in collections
}
```

---

## 3. Core Logic & "Magic" Features

### 3.1 The Two-Phase Import System (`LibraryService`)
To prevent UI blocking during large imports:
1.  **Phase 1 (Sync/Quick):** Immediately creates `VideoItem` objects with just the file path and ID. Adds them to the collection and notifies listeners. The UI updates *instantly*.
2.  **Phase 2 (Async/Background):** Iterates through new items to:
    *   Generate thumbnails (`video_thumbnail`).
    *   Extract duration.
    *   Updates the UI in batches (notifyListeners every 5 items) to show progress bars.

### 3.2 Subtitle System (Complex)
*   **Parsing:** Supports SRT/VTT (basic regex parsing in `subtitle_model.dart`).
*   **Auto-Scroll (`SubtitleSidebar.dart`):**
    *   Uses `ItemScrollController` from `scrollable_positioned_list`.
    *   **Logic:** Listens to `videoController` position -> Binary search/Linear search to find active index -> `scrollTo(index)`.
    *   **The "Lock" Feature:** The `autoScrollSubtitles` bool is now in `SettingsService`. If enabled, the list *forces* scrolling to the current line. If disabled, the user can scroll manually without it jumping back.
*   **Auto-Cache:** If enabled in settings, imported subtitles are copied to the app's private directory to prevent loss if the original file is deleted.

### 3.3 Gesture Control System (`VideoControlsOverlay.dart`)
*   **Layering:** A `Stack` sits on top of the video.
*   **Gestures:**
    *   **Double Tap (Left/Right):** Seek backward/forward.
        *   *Customization:* Seek seconds are configurable in Settings (saved to prefs).
        *   *Visuals:* Left tap shows "Rewind" icon, Right tap shows "Fast Forward".
    *   **Horizontal Drag:** Precise seeking.
    *   **Vertical Drag (Left):** Brightness.
    *   **Vertical Drag (Right):** Volume.
    *   **Long Press:** 2x Speed (or custom speed).
*   **Auto-Hide:** Controls (`_showControls`) automatically set to `false` after any drag gesture ends (Seek/Volume/Brightness) for immersion.

### 3.4 Recycle Bin Logic
*   **Deletion:** Deleting a collection moves it from `_collections` to `_recycleBin` in `LibraryService`. It does *not* delete the files.
*   **Restoration:** Moves back to `_collections`.
*   **Permanent Delete:** Removes from `_recycleBin`. (Note: Currently does not delete physical video files, only library references).

---

## 4. State Management Flow

1.  **Root:** `MultiProvider` injects `SettingsService` and `LibraryService`.
2.  **Consumption:**
    *   `Consumer<LibraryService>` wraps the GridViews in `HomeScreen` and `CollectionScreen`.
    *   `Consumer<SettingsService>` is used inside widgets that need reactive config (e.g., changing grid size instantly updates the UI).
3.  **Persistence:**
    *   `LibraryService` calls `_saveLibrary()` (writes JSON) after any structural change.
    *   `SettingsService` calls `SharedPreferences.set...` immediately on change.

---

## 5. Recent Critical Changes (Context for Next AI)

1.  **Grid Size Customization:**
    *   Added `homeGridCrossAxisCount` and `videoCardCrossAxisCount` to `SettingsService`.
    *   UI: Sliders in AppBar actions allow dynamic resizing of cards.

2.  **Tablet/Permission Fix:**
    *   `CollectionScreen` import logic now explicitly checks `Permission.videos` (Android 13+), `Permission.storage` (Old Android), and `Permission.manageExternalStorage` (Scope access) to ensure tablet compatibility.

3.  **Navigation Animation:**
    *   Transition from `PortraitVideoScreen` to `VideoPlayerScreen` (Landscape) uses a custom `PageRouteBuilder` with a **FadeTransition** (300ms) instead of the default Material slide, per user request for "elegance".

4.  **Subtitle Auto-Follow Persistence:**
    *   The state of the "Auto-Scroll" button (A icon in sidebar) is now global in `SettingsService`. It persists across app restarts.

---

## 6. Known "Gotchas" & Implementation Details

*   **Video Aspect Ratio:** The `VideoCard` uses `aspectRatio: 0.8` (taller) to allow 2-3 lines of text for the title.
*   **File Pickers:** The `FilePicker` is configured with `withData: false` and `withReadStream: false` to avoid Out-Of-Memory (OOM) errors on large video files.
*   **Thumbnail Cache:** Thumbnails are stored in `AppDocDir/thumbnails/`. There is currently no auto-cleanup logic for these files if a video is deleted.
*   **Selection Mode:** In `HomeScreen`, a custom `_isSelectionMode` bool toggles the UI between "Navigation" (tap to open) and "Selection" (tap to select).

## 7. Future/Pending Tasks (If any)
*   *None active.* The project is currently stable with all user requests implemented (Recycle Bin, Grid Resizing, Auto-Scroll persistence, Background Import).

---
*End of Handover Document*
