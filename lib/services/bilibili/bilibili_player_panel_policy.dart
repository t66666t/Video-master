/// Which side panel the player shows first and which one it falls back to
/// when a panel closes, for the landscape sidebar and the portrait bottom
/// panel.
///
/// Kept as plain functions so the rules can be tested without a player.
/// Bilibili videos get their own panel (details, comments, parts); every
/// other video keeps the subtitle list rules.
library;

/// What closed in the landscape player.
enum LandscapeSidebarClosing {
  /// A tool panel: settings, chapters, subtitle style or position, subtitle
  /// editor or manager, AI transcription, video compose, OCR.
  toolPanel,

  /// The subtitle style panel opened from video compose, closed with the
  /// back key: it goes back to video compose.
  styleFromCompose,

  /// The close button of the subtitle list itself.
  subtitleList,
}

/// Where the landscape player goes after a panel closed.
enum LandscapeSidebarTarget {
  /// The panel that was open before the one that closed.
  previous,
  subtitles,
  videoCompose,
  bilibili,
  none,
}

/// The landscape panel shown when no other panel is asked for: on entering
/// the player, after a panel closes with nothing open before it, and as the
/// panel to come back to when one is opened over the subtitle position bar.
///
/// * The Bilibili panel, for a Bilibili video whose panel was left open, when
///   the window may open it by itself ([allowAutoOpen] is false on narrow
///   windows and in mobile landscape).
/// * Else the subtitle list when it was left open, else nothing.
LandscapeSidebarTarget landscapeDefaultSidebar({
  required bool subtitleSidebarRemembered,
  bool isBilibiliVideo = false,
  bool bilibiliPanelRemembered = false,
  bool allowAutoOpen = true,
}) {
  if (isBilibiliVideo && bilibiliPanelRemembered && allowAutoOpen) {
    return LandscapeSidebarTarget.bilibili;
  }
  return subtitleSidebarRemembered
      ? LandscapeSidebarTarget.subtitles
      : LandscapeSidebarTarget.none;
}

/// The landscape panel to show after [closing] closed.
///
/// [hasPrevious] tells whether a panel was open before the one closing (the
/// player keeps it as its previous panel); a tool panel goes back to it,
/// else to [landscapeDefaultSidebar].
LandscapeSidebarTarget landscapeSidebarAfterClose({
  required LandscapeSidebarClosing closing,
  required bool hasPrevious,
  required bool subtitleSidebarRemembered,
  bool isBilibiliVideo = false,
  bool bilibiliPanelRemembered = false,
  bool allowAutoOpen = true,
}) {
  LandscapeSidebarTarget fallback() => landscapeDefaultSidebar(
    subtitleSidebarRemembered: subtitleSidebarRemembered,
    isBilibiliVideo: isBilibiliVideo,
    bilibiliPanelRemembered: bilibiliPanelRemembered,
    allowAutoOpen: allowAutoOpen,
  );
  switch (closing) {
    case LandscapeSidebarClosing.styleFromCompose:
      return LandscapeSidebarTarget.videoCompose;
    case LandscapeSidebarClosing.subtitleList:
      return fallback();
    case LandscapeSidebarClosing.toolPanel:
      return hasPrevious ? LandscapeSidebarTarget.previous : fallback();
  }
}

/// What closed in the portrait player.
enum PortraitPanelClosing {
  /// A tool panel: settings, subtitle style, subtitle editor or manager, AI
  /// transcription, part picker, video compose, OCR.
  toolPanel,

  /// The subtitle style panel or the subtitle manager opened from video
  /// compose: it goes back to video compose.
  fromCompose,
}

/// Where the portrait player's bottom panel goes.
enum PortraitPanelTarget { subtitles, videoCompose, bilibili }

/// The tab last picked in the portrait "details | subtitles" switch of
/// Bilibili videos (one choice for all Bilibili videos).
enum PortraitBilibiliTab { details, subtitles }

/// The portrait bottom panel shown when no other panel is asked for: the
/// Bilibili details for a Bilibili video unless the subtitle tab was picked
/// last time, else the subtitle list.
PortraitPanelTarget portraitDefaultPanel({
  bool isBilibiliVideo = false,
  PortraitBilibiliTab rememberedTab = PortraitBilibiliTab.details,
}) {
  if (isBilibiliVideo && rememberedTab == PortraitBilibiliTab.details) {
    return PortraitPanelTarget.bilibili;
  }
  return PortraitPanelTarget.subtitles;
}

/// The portrait bottom panel to show after [closing] closed.
PortraitPanelTarget portraitPanelAfterClose({
  required PortraitPanelClosing closing,
  bool isBilibiliVideo = false,
  PortraitBilibiliTab rememberedTab = PortraitBilibiliTab.details,
}) {
  if (closing == PortraitPanelClosing.fromCompose) {
    return PortraitPanelTarget.videoCompose;
  }
  return portraitDefaultPanel(
    isBilibiliVideo: isBilibiliVideo,
    rememberedTab: rememberedTab,
  );
}
