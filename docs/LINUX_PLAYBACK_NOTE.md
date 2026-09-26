# Linux playback notes (soft video / silent host)

## Blue / solid-color video mitigation

On Linux the media_kit `VideoController` is created with:

- `enableHardwareAcceleration: false` (always)
- `hwdec: no` (always via `decoderOptionFor`, even if the settings toggle prefers HW)

Helpers (unit-tested):

- `NativeVideoPlayerMediaKit.shouldEnableHardwareVideoOutput` → `false` on Linux
- `NativeVideoPlayerMediaKit.linuxHasDriDevices` (optional `/dev/dri` probe; Linux already forces software)

Root cause context: hosts without working CUDA (`Cannot load libcuda.so.1`) plus
media_kit HW rendering on Impeller OpenGLES often show a solid/blue frame while
`PlaybackState.playing`. System `mpv` with software VO works; this change mirrors
that path inside the app.

## Impeller (residual)

Flutter Linux Impeller can still contribute to GLES blue-screen symptoms on
GPU-less VMs. This change prioritizes the Dart/media_kit software VO path.
Disabling Impeller via engine switch (`--no-enable-impeller` /
`--enable-impeller=false`) was **not** wired into `linux/runner` for this
Flutter version (engine switches are not the same as Dart entrypoint args).
If blue frames remain after soft VO, launch with:

```bash
flutter run -d linux --no-enable-impeller
# or ship a wrapper that passes --no-enable-impeller to the runner binary
```

## No sound card UX

`LinuxAudioDevice.hasLinuxAudioOutput` reads `/proc/asound/cards`. When empty /
missing / no usable card lines, `maybeShowNoAudioDeviceHint` shows a once-per-
session toast:

> 本机未检测到音频设备，画面可播但无声音（环境限制）

Hooked from player screen open and first `MediaPlaybackService.play`.

## Empty ASR messages

- No audio stream: `媒体无音轨，无法生成字幕`
- Empty ASR after success: `识别结果为空，无法生成字幕（可能为无声或静音）`
- Linux + no ALSA: `本机无音频设备，抽音频/识别可能失败`

## Residual risks

GPU-less VMs may still be limited (CPU decode cost, Impeller residual, missing
ALSA → silent audio by design after L3 degrade).

## Library covers / seek thumbnails

`video_thumbnail` has **no Linux implementation** (`MissingPluginException` on
`plugins.justsoft.xyz/video_thumbnail`). On Linux (and whenever
`FFmpegUtils.preferSystemFfmpeg`):

- Library covers (`LibraryService._generateThumbnail`) skip the plugin and use
  system `ffmpeg` via the Process path (`_generateThumbnailWindows`).
- Seek/scrub previews (`VideoPreviewService`) prefer system ffmpeg first
  (accurate + simple `-ss` extract) so logs are not flooded with MissingPlugin.
- OCR preview frames already used native thumbnail only on Android/iOS and
  system ffmpeg on desktop.

Requires a working system `ffmpeg` on `PATH` (same L2 binary expectation).
