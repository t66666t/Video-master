import importlib.util
import json
import pathlib
import sys
import types
import unittest


if importlib.util.find_spec("yt_dlp") is None:
    fake_yt_dlp = types.ModuleType("yt_dlp")
    fake_yt_dlp.__version__ = "test"
    fake_utils = types.ModuleType("yt_dlp.utils")

    class DownloadError(Exception):
        pass

    fake_utils.DownloadError = DownloadError
    fake_utils.format_bytes = lambda value: str(value)
    fake_yt_dlp.utils = fake_utils
    sys.modules["yt_dlp"] = fake_yt_dlp
    sys.modules["yt_dlp.utils"] = fake_utils


PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT / "android" / "app" / "src" / "main" / "python"))
import yt_dlp_bridge  # noqa: E402


class _Callback:
    def __init__(self):
        self.events = []

    def isCancelled(self):
        return False

    def onProgress(self, value):
        self.events.append(json.loads(value))


def _status(
    downloaded,
    *,
    total=None,
    estimate=None,
    fragment_index=None,
    fragment_count=None,
    state="downloading",
    format_id="v",
    filename="video.webm",
    protocol=None,
):
    return {
        "status": state,
        "downloaded_bytes": downloaded,
        "total_bytes": total,
        "total_bytes_estimate": estimate,
        "fragment_index": fragment_index,
        "fragment_count": fragment_count,
        "filename": filename,
        "info_dict": {
            "format_id": format_id,
            "vcodec": "vp9",
            "acodec": "none",
            "protocol": protocol,
        },
    }


class ProgressHookTest(unittest.TestCase):
    def _hook(self, tracks, concurrent_fragments=4):
        callback = _Callback()
        hook = yt_dlp_bridge._ProgressHook(callback, {
            "debugContext": {
                "expectedDownloadTracks": tracks,
                "sessionConfigSummary": {
                    "concurrentFragments": concurrent_fragments,
                },
            },
        })
        # Disable emission throttling so synthetic events can be consecutive.
        hook._last_emit_at = -100
        return hook, callback

    def test_growing_total_estimate_keeps_moving_forward(self):
        hook, callback = self._hook([
            {"formatId": "v", "mediaKind": "video", "weight": 1.0},
        ])

        hook(_status(100, estimate=1000))
        hook._last_emit_at = -100
        hook(_status(200, estimate=5000))
        hook._last_emit_at = -100
        hook(_status(300, estimate=5000))

        progress = [event["overallProgress"] for event in callback.events]
        self.assertAlmostEqual(progress[0], 0.1)
        self.assertAlmostEqual(progress[1], 0.12)
        self.assertAlmostEqual(progress[2], 0.14)

    def test_metadata_size_is_stable_against_estimate_changes(self):
        hook, callback = self._hook([
            {
                "formatId": "v",
                "mediaKind": "video",
                "fileSize": 1000,
                "weight": 1.0,
            },
        ])

        hook(_status(100, estimate=5000))
        hook._last_emit_at = -100
        hook(_status(200, estimate=9000))

        progress = [event["overallProgress"] for event in callback.events]
        self.assertAlmostEqual(progress[0], 0.1)
        self.assertAlmostEqual(progress[1], 0.2)

    def test_fragment_local_estimate_is_not_treated_as_track_total(self):
        hook, callback = self._hook([
            {"formatId": "v", "mediaKind": "video", "weight": 1.0},
        ], concurrent_fragments=4)

        hook(_status(500, estimate=500, fragment_index=0, fragment_count=100))
        hook._last_emit_at = -100
        hook(_status(600, estimate=5000, fragment_index=1, fragment_count=100))
        hook._last_emit_at = -100
        hook(_status(700, estimate=6000, fragment_index=2, fragment_count=100))

        progress = [event["overallProgress"] for event in callback.events]
        self.assertAlmostEqual(progress[0], 0.0)
        self.assertAlmostEqual(progress[1], 0.01)
        self.assertAlmostEqual(progress[2], 0.11666666666666667)

    def test_audio_first_only_advances_its_weight(self):
        hook, callback = self._hook([
            {"formatId": "v", "mediaKind": "video", "weight": 0.9},
            {"formatId": "a", "mediaKind": "audio", "weight": 0.1},
        ])

        audio_status = _status(
            100,
            total=100,
            state="finished",
            format_id="a",
            filename="audio.m4a",
        )
        audio_status["info_dict"].update({"vcodec": "none", "acodec": "aac"})
        hook(audio_status)

        self.assertAlmostEqual(callback.events[-1]["overallProgress"], 0.1)

    def test_real_hls_callback_shape_does_not_jump_on_init_fragment(self):
        hook, callback = self._hook([
            {
                "formatId": "v",
                "mediaKind": "video",
                "fileSize": 174000,
                "weight": 1.0,
            },
        ])
        samples = [
            (712, 712, 0),
            (712, 4272, 1),
            (15824, 15824, 1),
            (15824, 46404, 2),
            (31933, 31933, 2),
            (31933, 48042, 3),
            (52754, 52754, 3),
        ]
        for downloaded, estimate, fragment_index in samples:
            hook._last_emit_at = -100
            hook(_status(
                downloaded,
                estimate=estimate,
                fragment_index=fragment_index,
                fragment_count=3,
                protocol="m3u8_native",
            ))
        hook._last_emit_at = -100
        hook(_status(52754, total=52754, state="finished"))

        progress = [event["overallProgress"] for event in callback.events]
        self.assertLess(progress[0], 0.01)
        self.assertLess(progress[1], 0.01)
        self.assertGreater(progress[4], 0.65)
        self.assertTrue(all(b >= a for a, b in zip(progress, progress[1:])))
        self.assertEqual(progress[-1], 1.0)


if __name__ == "__main__":
    unittest.main()
