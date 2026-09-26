/// Whether startup and resume clipboard parsing should skip [content].
///
/// Only the latest handled text is remembered. While [skipRepeated] is on,
/// that text is not parsed again, including after the process restarts.
/// Copying different text and then copying this text back is treated as new.
///
/// Turning the switch off allows one more parse. Later checks in that same
/// session stay quiet until the process starts again or the switch changes,
/// so leaving and returning to the app does not stack the same prompt.
bool shouldSkipClipboardParse({
  required String content,
  required bool skipRepeated,
  required String? persistedText,
  required String? sessionText,
  required bool? sessionSkipRepeated,
}) {
  final identity = content.trim();
  if (identity.isEmpty) return false;
  if (sessionText != null &&
      identity == sessionText &&
      skipRepeated == sessionSkipRepeated) {
    return true;
  }
  if (!skipRepeated) return false;
  final persisted = persistedText?.trim();
  return persisted != null && persisted.isNotEmpty && identity == persisted;
}
