import io
import json
import math
import os
import sys
import traceback
from contextlib import contextmanager

import yt_dlp
from yt_dlp.utils import DownloadError

_BEFORE_DL_MARKER = "__YTDLP_BEFORE_DL__:"
_AFTER_MOVE_MARKER = "__YTDLP_AFTER_MOVE__:"


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
    progress_hooks.append(_ProgressHook(callback))
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
    def __init__(self, callback):
        self.callback = callback

    def __call__(self, status):
        if self.callback is not None and self.callback.isCancelled():
            raise DownloadError("Cancelled by user")
        if self.callback is None:
            return

        payload = {
            "status": status.get("status"),
            "downloadedBytes": _to_int(status.get("downloaded_bytes")),
            "totalBytes": _to_int(status.get("total_bytes") or status.get("total_bytes_estimate")),
            "speedText": _to_speed_text(status.get("speed")),
            "etaText": _to_eta_text(status.get("eta")),
            "outputPath": status.get("filename") or status.get("info_dict", {}).get("_filename"),
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

        payload = {
            "status": status.get("status"),
            "postprocessor": status.get("postprocessor"),
            "infoPath": status.get("info_dict", {}).get("filepath"),
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
    if (retries := read_int("retries")) and retries > 0:
        args.extend(["--retries", str(retries)])
    if (retries := read_int("fragmentRetries")) and retries > 0:
        args.extend(["--fragment-retries", str(retries)])
    if (fragments := read_int("concurrentFragments")) and fragments > 0:
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
