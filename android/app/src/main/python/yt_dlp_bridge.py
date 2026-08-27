import io
import importlib
import json
import math
import os
import sys
import time
import traceback
import zipfile
from contextlib import contextmanager

import yt_dlp
from yt_dlp.utils import DownloadError

_BEFORE_DL_MARKER = "__YTDLP_BEFORE_DL__:"
_AFTER_MOVE_MARKER = "__YTDLP_AFTER_MOVE__:"
_ACTIVE_RUNTIME_ARCHIVE = None


def configure_runtime(archive_path=None):
    """Activate a checksummed yt-dlp zipimport archive, or the APK fallback."""
    global yt_dlp, DownloadError, _ACTIVE_RUNTIME_ARCHIVE

    normalized = os.path.abspath(str(archive_path)) if archive_path else None
    if normalized:
        if not os.path.isfile(normalized):
            raise FileNotFoundError(normalized)
        with zipfile.ZipFile(normalized) as archive:
            archive.getinfo("yt_dlp/__init__.py")
    if normalized == _ACTIVE_RUNTIME_ARCHIVE:
        return get_yt_dlp_version()

    previous_archive = _ACTIVE_RUNTIME_ARCHIVE
    previous_module = yt_dlp
    previous_download_error = DownloadError
    previous_modules = {
        name: module
        for name, module in sys.modules.items()
        if name == "yt_dlp" or name.startswith("yt_dlp.")
    }

    try:
        if previous_archive:
            while previous_archive in sys.path:
                sys.path.remove(previous_archive)
        if normalized:
            sys.path.insert(0, normalized)
        for name in list(previous_modules):
            sys.modules.pop(name, None)
        importlib.invalidate_caches()
        yt_dlp = importlib.import_module("yt_dlp")
        DownloadError = importlib.import_module("yt_dlp.utils").DownloadError
        _ACTIVE_RUNTIME_ARCHIVE = normalized
        return get_yt_dlp_version()
    except Exception:
        if normalized:
            while normalized in sys.path:
                sys.path.remove(normalized)
        if previous_archive:
            sys.path.insert(0, previous_archive)
        for name in list(sys.modules):
            if name == "yt_dlp" or name.startswith("yt_dlp."):
                sys.modules.pop(name, None)
        sys.modules.update(previous_modules)
        yt_dlp = previous_module
        DownloadError = previous_download_error
        _ACTIVE_RUNTIME_ARCHIVE = previous_archive
        importlib.invalidate_caches()
        raise


def get_yt_dlp_version():
    return getattr(yt_dlp, "__version__", None) or getattr(yt_dlp.version, "__version__", None)


def resolve_meta(url, session_config_json=None):
    session_config = _load_json(session_config_json)
    args = _build_session_args(session_config)
    args.extend(["--dump-single-json", "--no-warnings", url])

    parsed = yt_dlp.parse_options(args)
    ydl_opts = dict(parsed.ydl_opts)
    ydl_opts["skip_download"] = True
    ydl_opts["quiet"] = True
    ydl_opts["no_warnings"] = True

    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(url, download=False)
        safe_info = _sanitize_for_json(ydl.sanitize_info(info))
        return json.dumps(safe_info, ensure_ascii=False, allow_nan=False)


def download(request_json, callback=None):
    request = _load_json(request_json)
    args = list(request.get("args") or [])
    parsed = yt_dlp.parse_options(args)
    urls = list(parsed.urls) or ([request.get("url")] if request.get("url") else [])
    if not urls:
        raise ValueError("missing download url")

    ydl_opts = dict(parsed.ydl_opts)
    forwarder = _CallbackWriter(callback)
    logger = _CallbackLogger(forwarder)
    result = {
        "exitCode": 1,
        "outputPath": None,
        "producedPaths": [],
    }

    progress_hooks = list(ydl_opts.get("progress_hooks") or [])
    progress_hooks.append(_ProgressHook(callback, request))
    ydl_opts["progress_hooks"] = progress_hooks
    postprocessor_hooks = list(ydl_opts.get("postprocessor_hooks") or [])
    postprocessor_hooks.append(_PostProcessorHook(callback))
    ydl_opts["postprocessor_hooks"] = postprocessor_hooks
    ydl_opts["skip_download"] = False
    ydl_opts["simulate"] = False
    ydl_opts["logger"] = logger

    with _redirect_streams(forwarder):
        try:
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                collected_infos = []
                for url in urls:
                    info = ydl.extract_info(url, download=True)
                    collected_infos.extend(_flatten_download_infos(info))
                result.update(_build_download_result(collected_infos))
            result.update(_supplement_download_result(result, request))
            if not _has_usable_media_artifact(result.get("producedPaths") or []):
                produced_paths = result.get("producedPaths") or []
                detail = (
                    "only subtitle/image sidecars were produced"
                    if produced_paths
                    else "no task output was found on disk"
                )
                forwarder.write(
                    "ERROR: yt-dlp finished without a usable media artifact; "
                    f"{detail}\n"
                )
                return json.dumps(result, ensure_ascii=False, allow_nan=False)
            result["exitCode"] = 0
            return json.dumps(result, ensure_ascii=False, allow_nan=False)
        except DownloadError as exc:
            if callback is not None and callback.isCancelled():
                forwarder.write("ERROR: Interrupted by user\n")
                result["exitCode"] = 130
                return json.dumps(result, ensure_ascii=False, allow_nan=False)
            forwarder.write(f"ERROR: {exc}\n")
            return json.dumps(result, ensure_ascii=False, allow_nan=False)
        except SystemExit as exc:
            result["exitCode"] = exc.code if isinstance(exc.code, int) else 1
            return json.dumps(result, ensure_ascii=False, allow_nan=False)
        except Exception:
            traceback.print_exc(file=forwarder)
            return json.dumps(result, ensure_ascii=False, allow_nan=False)


class _ProgressHook:
    def __init__(self, callback, request=None):
        self.callback = callback
        self._last_emit_at = 0.0
        self._last_output_path = None
        self._last_overall_progress = 0.0
        request = request or {}
        debug_context = request.get("debugContext") or {}
        session_summary = debug_context.get("sessionConfigSummary") or {}
        concurrent_fragments = _positive_int(
            session_summary.get("concurrentFragments")
        ) or 1
        self._concurrent_fragments = max(1, min(16, concurrent_fragments))
        self._tracks = self._build_tracks(request)

    def _build_tracks(self, request):
        debug_context = request.get("debugContext") or {}
        raw_tracks = debug_context.get("expectedDownloadTracks") or []
        tracks = []
        if isinstance(raw_tracks, list):
            for item in raw_tracks:
                if not isinstance(item, dict):
                    continue
                weight = _to_float(item.get("weight"))
                if weight is None or weight <= 0:
                    continue
                tracks.append({
                    "format_id": str(item.get("formatId") or "").strip() or None,
                    "media_kind": str(item.get("mediaKind") or "other").strip(),
                    "file_size": _positive_int(item.get("fileSize")),
                    "weight": weight,
                    "progress": 0.0,
                    "downloaded_bytes": 0,
                    "stable_total_bytes": _positive_int(item.get("fileSize")) or 0,
                })
        if not tracks:
            if debug_context.get("audioOnly") is True:
                kinds_and_weights = [("audio", 1.0)]
            elif debug_context.get("removeAudio") is True:
                kinds_and_weights = [("video", 1.0)]
            else:
                # The request normally carries exact tracks. This fallback is
                # deliberately order-independent: an audio-first download can
                # advance at most 10%, never jump the task to 90%.
                kinds_and_weights = [("video", 0.9), ("audio", 0.1)]
            tracks = [
                {
                    "format_id": None,
                    "media_kind": kind,
                    "file_size": None,
                    "weight": weight,
                    "progress": 0.0,
                    "downloaded_bytes": 0,
                    "stable_total_bytes": 0,
                }
                for kind, weight in kinds_and_weights
            ]
        weight_total = sum(track["weight"] for track in tracks)
        if weight_total <= 0:
            equal_weight = 1.0 / len(tracks)
            for track in tracks:
                track["weight"] = equal_weight
        else:
            for track in tracks:
                track["weight"] /= weight_total
        return tracks

    def _matching_tracks(self, format_id, media_kind):
        if format_id:
            exact = [
                track for track in self._tracks
                if track["format_id"] == format_id
            ]
            if exact:
                return exact
        by_kind = [
            track for track in self._tracks
            if track["media_kind"] == media_kind
        ]
        if by_kind:
            return by_kind[:1]
        if media_kind == "media":
            media_tracks = [
                track for track in self._tracks
                if track["media_kind"] in ("video", "audio")
            ]
            if media_tracks:
                return media_tracks
        unstarted = [track for track in self._tracks if track["progress"] <= 0]
        return unstarted[:1]

    def _estimate_track_progress(
        self,
        track,
        *,
        state,
        downloaded,
        total,
        total_is_estimate,
        fragment_index,
        fragment_count,
        is_hls,
    ):
        if state == "finished":
            track["progress"] = 1.0
            track["downloaded_bytes"] = max(
                track["downloaded_bytes"], downloaded
            )
            return 1.0, "finished"

        previous_progress = track["progress"]
        previous_downloaded = track["downloaded_bytes"]
        observed_downloaded = max(previous_downloaded, downloaded)
        downloaded_delta = max(0, observed_downloaded - previous_downloaded)
        track["downloaded_bytes"] = observed_downloaded
        if total is not None and (
            not total_is_estimate
            or track.get("file_size") is None
            or fragment_count is not None
        ):
            # A validated whole-track estimate may legitimately move in either
            # direction. Replacing the denominator lets later fragment
            # evidence correct an approximate metadata size. Forward progress
            # remains monotonic through the incremental candidate below.
            track["stable_total_bytes"] = max(total, observed_downloaded)

        stable_total = track["stable_total_bytes"]
        if stable_total > 0:
            stable_total = max(stable_total, observed_downloaded)
        candidates = [previous_progress]
        progress_source = "waiting"
        if stable_total > 0:
            # yt-dlp recalculates total_bytes_estimate for fragmented media.
            # A direct downloaded/estimate ratio can therefore move backwards.
            # Integrating newly received bytes against the largest observed
            # denominator guarantees small forward movement without trusting
            # a temporarily low estimate.
            direct_progress = observed_downloaded / stable_total
            incremental_progress = (
                previous_progress + downloaded_delta / stable_total
            )
            candidates.extend((direct_progress, incremental_progress))
            progress_source = "stable_bytes"

        fragment_floor = None
        fragment_ceiling = None
        if fragment_index is not None and fragment_count is not None:
            # HLS commonly reports its initialization section as fragment 1
            # even though fragment_count only describes media fragments.
            normalized_fragment_index = fragment_index - (1 if is_hls else 0)
            completed_fragments = max(
                0,
                min(fragment_count, normalized_fragment_index),
            )
            fragment_floor = completed_fragments / fragment_count
            active_window_end = min(
                fragment_count,
                completed_fragments + self._concurrent_fragments,
            )
            fragment_ceiling = active_window_end / fragment_count
            if stable_total <= 0:
                candidates.append(fragment_floor)
                progress_source = "fragments"
            else:
                progress_source = "hybrid"

        estimated_progress = max(candidates)
        if stable_total <= 0 and fragment_ceiling is not None:
            estimated_progress = min(
                estimated_progress,
                max(fragment_floor, fragment_ceiling),
            )
        # A downloader can exceed an approximate size. Reserve the final step
        # for yt-dlp's explicit finished event.
        estimated_progress = max(
            previous_progress,
            min(0.995, estimated_progress),
        )
        track["progress"] = estimated_progress
        return estimated_progress, progress_source

    def _update_overall_progress(self, status, format_id, media_kind, is_hls):
        state = str(status.get("status") or "")
        downloaded = _to_int(status.get("downloaded_bytes")) or 0
        fragment_index = _to_int(status.get("fragment_index"))
        fragment_count = _positive_int(status.get("fragment_count"))
        exact_total = _positive_int(status.get("total_bytes"))
        estimated_total = _positive_int(status.get("total_bytes_estimate"))
        if fragment_count is not None:
            # FragmentedFD emits two kinds of estimates. During an inner
            # fragment callback total_bytes_estimate commonly equals the bytes
            # downloaded so far and is not the whole media size. Accept only a
            # later estimate backed by at least two completed fragments and a
            # meaningful remaining-byte margin.
            has_mature_track_estimate = (
                fragment_index is not None
                and fragment_index >= 2
                and estimated_total is not None
                and estimated_total > downloaded * 1.02
            )
            total = estimated_total if has_mature_track_estimate else None
            total_is_estimate = total is not None
        else:
            total = exact_total or estimated_total
            total_is_estimate = exact_total is None and estimated_total is not None
        matching_tracks = self._matching_tracks(format_id, media_kind)
        track_progress = 0.0
        progress_source = "waiting"
        for track in matching_tracks:
            current_progress, current_source = self._estimate_track_progress(
                track,
                state=state,
                downloaded=downloaded,
                total=total,
                total_is_estimate=total_is_estimate,
                fragment_index=fragment_index,
                fragment_count=fragment_count,
                is_hls=is_hls,
            )
            track_progress = max(track_progress, current_progress)
            progress_source = current_source

        overall = sum(
            track["weight"] * track["progress"] for track in self._tracks
        )
        overall = max(self._last_overall_progress, min(1.0, overall))
        self._last_overall_progress = overall

        known_sizes = [track["file_size"] for track in self._tracks]
        if known_sizes and all(size is not None for size in known_sizes):
            overall_total = sum(known_sizes)
            overall_downloaded = round(sum(
                size * track["progress"]
                for size, track in zip(known_sizes, self._tracks)
            ))
        else:
            overall_total = None
            overall_downloaded = None
        return track_progress, overall, overall_downloaded, overall_total, progress_source

    def __call__(self, status):
        if self.callback is not None and self.callback.isCancelled():
            raise DownloadError("Cancelled by user")
        if self.callback is None:
            return

        info = status.get("info_dict") or {}
        output_path = status.get("filename") or info.get("filepath") or info.get("_filename")
        format_id = str(info.get("format_id") or "").strip() or None
        media_kind = _classify_media_kind(info)
        protocol = str(info.get("protocol") or "").lower()
        is_hls = "m3u8" in protocol
        (
            track_progress,
            overall_progress,
            overall_downloaded,
            overall_total,
            progress_source,
        ) = self._update_overall_progress(status, format_id, media_kind, is_hls)
        now = time.monotonic()
        if (
            status.get("status") == "downloading"
            and output_path == self._last_output_path
            and now - self._last_emit_at < 0.05
        ):
            return
        self._last_emit_at = now
        self._last_output_path = output_path
        payload = {
            "phase": "download",
            "status": status.get("status"),
            "downloadedBytes": _to_int(status.get("downloaded_bytes")),
            "totalBytes": _to_int(status.get("total_bytes") or status.get("total_bytes_estimate")),
            "trackProgress": track_progress,
            "overallProgress": overall_progress,
            "overallDownloadedBytes": overall_downloaded,
            "overallTotalBytes": overall_total,
            "progressSource": progress_source,
            "speedText": _to_speed_text(status.get("speed")),
            "etaText": _to_eta_text(status.get("eta")),
            "outputPath": output_path,
            "formatId": format_id,
            "mediaKind": media_kind,
            "fragmentIndex": _to_int(status.get("fragment_index")),
            "fragmentCount": _to_int(status.get("fragment_count")),
            "message": status.get("status"),
        }
        self.callback.onProgress(json.dumps(payload, ensure_ascii=False))


class _PostProcessorHook:
    def __init__(self, callback):
        self.callback = callback

    def __call__(self, status):
        if self.callback is not None and self.callback.isCancelled():
            raise DownloadError("Cancelled by user")
        if self.callback is None:
            return

        info = status.get("info_dict") or {}
        payload = {
            "phase": "post_processing",
            "status": status.get("status"),
            "postprocessor": status.get("postprocessor"),
            "outputPath": info.get("filepath") or info.get("_filename"),
            "message": status.get("status"),
        }
        self.callback.onProgress(json.dumps(payload, ensure_ascii=False))


class _CallbackLogger:
    def __init__(self, writer):
        self.writer = writer

    def debug(self, msg):
        if msg:
            self.writer.write(f"{msg}\n")

    def warning(self, msg):
        if msg:
            self.writer.write(f"WARNING: {msg}\n")

    def error(self, msg):
        if msg:
            self.writer.write(f"ERROR: {msg}\n")


class _CallbackWriter(io.TextIOBase):
    def __init__(self, callback):
        super().__init__()
        self.callback = callback
        self._buffer = ""

    def writable(self):
        return True

    def write(self, value):
        if not value:
            return 0
        text = str(value)
        text = _normalize_structured_print_markers(text)
        self._buffer += text
        while True:
            newline_index = self._buffer.find("\n")
            if newline_index < 0:
                break
            line = self._buffer[:newline_index].rstrip("\r")
            self._buffer = self._buffer[newline_index + 1:]
            if self.callback is not None and line:
                self.callback.onOutputLine(line)
        return len(text)

    def flush(self):
        if self.callback is not None and self._buffer.strip():
            self.callback.onOutputLine(self._buffer.rstrip("\r"))
        self._buffer = ""


@contextmanager
def _redirect_streams(writer):
    original_stdout = sys.stdout
    original_stderr = sys.stderr
    sys.stdout = writer
    sys.stderr = writer
    try:
        yield
    finally:
        try:
            writer.flush()
        finally:
            sys.stdout = original_stdout
            sys.stderr = original_stderr


def _build_session_args(session_config):
    if not session_config:
        return []
    args = []

    def read_string(key):
        value = session_config.get(key)
        if value is None:
            return None
        value = str(value).strip()
        return value or None

    def read_int(key):
        value = session_config.get(key)
        if value is None:
            return None
        try:
            return int(value)
        except Exception:
            return None

    def read_bool(key):
        value = session_config.get(key)
        if isinstance(value, bool):
            return value
        if isinstance(value, str):
            return value.lower() == "true"
        return bool(value)

    if read_bool("useCookies") and read_string("cookiesFilePath"):
        args.extend(["--cookies", read_string("cookiesFilePath")])
    if read_bool("useProxy") and read_string("proxy"):
        args.extend(["--proxy", read_string("proxy")])
    if read_bool("useCustomUserAgent") and read_string("userAgent"):
        args.extend(["--add-header", f"User-Agent:{read_string('userAgent')}"])
    if (timeout := read_int("socketTimeoutSeconds")) and timeout > 0:
        args.extend(["--socket-timeout", str(timeout)])
    retries = read_int("retries")
    args.extend(["--retries", str(max(0, min(retries if retries is not None else 2, 2)))])
    fragment_retries = read_int("fragmentRetries")
    args.extend([
        "--fragment-retries",
        str(max(0, min(fragment_retries if fragment_retries is not None else 2, 2))),
    ])
    fragments = read_int("concurrentFragments")
    if fragments is None:
        fragments = 4
    if fragments > 0:
        args.extend(["-N", str(fragments)])
    if read_string("rateLimit"):
        args.extend(["-r", read_string("rateLimit")])
    if read_bool("forceIpv4"):
        args.append("-4")

    extractor_args = _build_youtube_extractor_args(session_config)
    if extractor_args:
        args.extend(["--extractor-args", extractor_args])
    return args


def _flatten_download_infos(info):
    if not isinstance(info, dict):
        return []
    entries = info.get("entries")
    if isinstance(entries, list):
        flattened = []
        for entry in entries:
            flattened.extend(_flatten_download_infos(entry))
        return flattened
    return [info]


def _build_download_result(infos):
    produced_paths = []
    output_path = None
    for info in infos:
        candidates = _collect_info_paths(info)
        for path in candidates:
            normalized = _normalize_path(path)
            if not normalized:
                continue
            if output_path is None and os.path.exists(normalized):
                output_path = normalized
            if normalized not in produced_paths:
                produced_paths.append(normalized)
    if output_path is None:
        for path in produced_paths:
            if os.path.exists(path):
                output_path = path
                break
    return {
        "outputPath": output_path,
        "producedPaths": produced_paths,
    }


def _supplement_download_result(result, request):
    """Recover files which yt-dlp wrote but omitted from its final info dict."""
    produced_paths = []
    for path in list(result.get("producedPaths") or []) + _discover_request_artifacts(request):
        normalized = _normalize_path(path)
        if normalized and normalized not in produced_paths:
            produced_paths.append(normalized)

    output_path = next(
        (path for path in produced_paths if _is_usable_media_artifact(path)),
        None,
    )
    if output_path is None:
        current = _normalize_path(result.get("outputPath"))
        if current and os.path.isfile(current):
            output_path = current
    if output_path is None:
        output_path = next((path for path in produced_paths if os.path.isfile(path)), None)
    return {"outputPath": output_path, "producedPaths": produced_paths}


def _discover_request_artifacts(request):
    output_dir = _normalize_path(request.get("outputDir"))
    if not output_dir or not os.path.isdir(output_dir):
        return []

    output_template = os.path.basename(str(request.get("outputTemplate") or ""))
    static_prefix = output_template.split("%(", 1)[0]
    task_id = str(request.get("taskId") or "").strip()
    task_marker = f"__{task_id}." if task_id else None
    discovered = []
    for root, _, files in os.walk(output_dir):
        for name in files:
            if static_prefix:
                belongs_to_task = name.startswith(static_prefix)
            else:
                belongs_to_task = task_marker is not None and task_marker in name
            if not belongs_to_task or _is_transient_artifact(name):
                continue
            path = os.path.abspath(os.path.join(root, name))
            if path not in discovered:
                discovered.append(path)
    return discovered


def _has_usable_media_artifact(paths):
    return any(_is_usable_media_artifact(path) for path in paths)


def _is_usable_media_artifact(path):
    media_extensions = {
        ".3gp", ".aac", ".avi", ".flac", ".flv", ".m4a", ".m4v",
        ".mka", ".mkv", ".mov", ".mp3", ".mp4", ".mpeg", ".mpg",
        ".oga", ".ogg", ".ogv", ".opus", ".ts", ".wav", ".webm",
        ".wma", ".wmv",
    }
    return (
        isinstance(path, str)
        and not _is_transient_artifact(path)
        and os.path.splitext(path)[1].lower() in media_extensions
        and os.path.isfile(path)
    )


def _is_transient_artifact(path):
    lower = str(path).lower()
    return lower.endswith((".part", ".ytdl", ".tmp", ".temp", ".frag"))


def _classify_media_kind(info):
    video_codec = str(info.get("vcodec") or "none").lower()
    audio_codec = str(info.get("acodec") or "none").lower()
    video_ext = str(info.get("video_ext") or "none").lower()
    audio_ext = str(info.get("audio_ext") or "none").lower()
    resolution = str(info.get("resolution") or "").lower()
    has_video = video_codec != "none" or video_ext != "none"
    has_audio = (
        audio_codec != "none"
        or audio_ext != "none"
        or resolution == "audio only"
    )
    if has_video and not has_audio:
        return "video"
    if has_audio and not has_video:
        return "audio"
    if has_video or has_audio:
        return "media"
    return "other"


def _collect_info_paths(info):
    collected = []
    _append_path_candidate(collected, info.get("filepath"))
    _append_path_candidate(collected, info.get("_filename"))
    _append_path_candidate(collected, info.get("filename"))

    requested_downloads = info.get("requested_downloads") or []
    if isinstance(requested_downloads, list):
        for item in requested_downloads:
            if not isinstance(item, dict):
                continue
            _append_path_candidate(collected, item.get("filepath"))
            _append_path_candidate(collected, item.get("_filename"))
            _append_path_candidate(collected, item.get("filename"))

    requested_formats = info.get("requested_formats") or []
    if isinstance(requested_formats, list):
        for item in requested_formats:
            if not isinstance(item, dict):
                continue
            _append_path_candidate(collected, item.get("filepath"))
            _append_path_candidate(collected, item.get("_filename"))
            _append_path_candidate(collected, item.get("filename"))

    requested_subtitles = info.get("requested_subtitles") or {}
    if isinstance(requested_subtitles, dict):
        for item in requested_subtitles.values():
            if not isinstance(item, dict):
                continue
            _append_path_candidate(collected, item.get("filepath"))

    files_to_move = info.get("__files_to_move") or {}
    if isinstance(files_to_move, dict):
        for old_path, new_path in files_to_move.items():
            _append_path_candidate(collected, old_path)
            _append_path_candidate(collected, new_path)

    return collected


def _append_path_candidate(collected, value):
    if isinstance(value, str):
        normalized = _normalize_path(value)
        if normalized:
            collected.append(normalized)


def _normalize_path(path):
    if not isinstance(path, str):
        return None
    normalized = path.strip().strip('"')
    return normalized or None


def _normalize_structured_print_markers(text):
    if not isinstance(text, str):
        return text
    normalized = text
    for marker in (_BEFORE_DL_MARKER, _AFTER_MOVE_MARKER):
        normalized = normalized.replace(f"[info] {marker}", marker)
        normalized = normalized.replace(f"[debug] {marker}", marker)
    return normalized


def _build_youtube_extractor_args(session_config):
    parts = []
    clients = [str(item).strip() for item in (session_config.get("enabledPlayerClients") or []) if str(item).strip()]
    if clients:
        parts.append(f"player_client={','.join(dict.fromkeys(clients))}")
    visitor_data = session_config.get("visitorData")
    if visitor_data:
        parts.append(f"visitor_data={str(visitor_data).strip()}")

    tokens = []
    for item in session_config.get("poTokens") or []:
        if not isinstance(item, dict):
            continue
        if item.get("enabled", True) is False:
            continue
        client = str(item.get("client", "")).strip()
        context = str(item.get("context", "")).strip()
        token = str(item.get("token", "")).strip()
        if client and context and token:
            tokens.append(f"{client}.{context}+{token}")
    if tokens:
        parts.append(f"po_token={','.join(tokens)}")
    if not parts:
        return None
    return f"youtube:{';'.join(parts)}"


def _load_json(raw):
    if not raw:
        return {}
    if isinstance(raw, str):
        return json.loads(raw)
    return raw


def _sanitize_for_json(value):
    if isinstance(value, dict):
        return {str(key): _sanitize_for_json(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_sanitize_for_json(item) for item in value]
    if isinstance(value, tuple):
        return [_sanitize_for_json(item) for item in value]
    if isinstance(value, float):
        return value if math.isfinite(value) else None
    return value


def _to_int(value):
    if value is None:
        return None
    try:
        return int(value)
    except Exception:
        return None


def _positive_int(value):
    parsed = _to_int(value)
    return parsed if parsed is not None and parsed > 0 else None


def _to_float(value):
    if value is None:
        return None
    try:
        parsed = float(value)
        return parsed if math.isfinite(parsed) else None
    except Exception:
        return None


def _to_speed_text(value):
    if value is None:
        return None
    try:
        return f"{yt_dlp.utils.format_bytes(float(value))}/s"
    except Exception:
        return None


def _to_eta_text(value):
    if value is None:
        return None
    try:
        seconds = int(value)
        minutes, sec = divmod(seconds, 60)
        hours, minutes = divmod(minutes, 60)
        if hours > 0:
            return f"{hours:02d}:{minutes:02d}:{sec:02d}"
        return f"{minutes:02d}:{sec:02d}"
    except Exception:
        return None
