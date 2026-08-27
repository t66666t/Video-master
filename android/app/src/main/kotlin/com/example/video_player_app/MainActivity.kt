package com.example.video_player_app

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Bundle
import android.provider.OpenableColumns
import android.provider.DocumentsContract
import android.provider.MediaStore
import androidx.annotation.NonNull
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import android.webkit.MimeTypeMap
import java.io.File
import java.io.FileOutputStream
import java.util.ArrayDeque
import java.util.Collections
import java.util.LinkedHashSet
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.Locale
import kotlin.concurrent.thread
import org.json.JSONArray
import org.json.JSONObject
import com.ryanheise.audioservice.AudioServiceFragmentActivity

class MainActivity : AudioServiceFragmentActivity() {
    private enum class PickerMode {
        MEDIA,
        ARCHIVE,
    }

    private val YTDLP_BEFORE_DL_MARKER = "__YTDLP_BEFORE_DL__:"
    private val YTDLP_AFTER_MOVE_MARKER = "__YTDLP_AFTER_MOVE__:"
    private val CHANNEL = "com.example.video_player_app/file_manager"
    private val SHARE_CHANNEL = "com.example.video_player_app/share_intent"
    private val SHARE_EVENT_CHANNEL = "com.example.video_player_app/share_intent_events"
    private val YT_DLP_CHANNEL = "com.example.video_player_app/yt_dlp"
    private val YT_DLP_EVENT_CHANNEL = "com.example.video_player_app/yt_dlp_events"
    private val REQUEST_CODE_PICK_FILES = 4101
    private var pendingResult: MethodChannel.Result? = null
    private var pendingPickerMode: PickerMode? = null
    private var shareEventSink: EventChannel.EventSink? = null
    private var ytDlpEventSink: EventChannel.EventSink? = null
    private val pendingSharedItems = mutableListOf<Map<String, Any?>>()
    private val mediaExtensions = setOf(
        ".mp4", ".mov", ".avi", ".mkv", ".flv", ".webm", ".wmv", ".3gp", ".m4v", ".ts",
        ".rmvb", ".mpg", ".mpeg", ".f4v", ".m2ts", ".mts", ".vob", ".ogv", ".divx",
        ".mp3", ".m4a", ".wav", ".flac", ".ogg", ".aac", ".wma", ".opus", ".m4b", ".aiff"
    )
    private val archiveExtensions = setOf(
        ".zip",
        ".tar",
        ".tgz",
        ".tar.gz",
        ".tbz",
        ".tbz2",
        ".tar.bz2",
        ".txz",
        ".tar.xz",
    )
    private val ytDlpTasks = ConcurrentHashMap<String, RunningYtDlpTask>()
    private val sharedIntentExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "shared-intent-resolver")
    }
    private var ytDlpWorkerReceiverRegistered = false
    private val ytDlpWorkerReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent != null) handleYtDlpWorkerEvent(intent)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        registerYtDlpWorkerReceiver()
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openFileManager" -> {
                    openFileManager()
                    result.success(null)
                }
                "pickFiles" -> {
                    if (pendingResult != null) {
                        result.error("PICKER_ACTIVE", "File picker is already active", null)
                        return@setMethodCallHandler
                    }
                    pendingResult = result
                    pendingPickerMode = PickerMode.MEDIA
                    val mimeTypes = call.argument<List<String>>("mimeTypes") ?: listOf("video/*", "audio/*")
                    val allowMultiple = call.argument<Boolean>("allowMultiple") ?: true
                    openSystemFilePicker(mimeTypes, allowMultiple)
                }
                "pickArchive" -> {
                    if (pendingResult != null) {
                        result.error("PICKER_ACTIVE", "File picker is already active", null)
                        return@setMethodCallHandler
                    }
                    pendingResult = result
                    pendingPickerMode = PickerMode.ARCHIVE
                    openSystemFilePicker(listOf("*/*"), false)
                }
                "materializeArchiveForImport" -> {
                    val uriString = call.argument<String>("uri")
                    val displayName = call.argument<String>("displayName")
                    if (uriString.isNullOrBlank()) {
                        result.error("INVALID_ARGS", "missing uri", null)
                    } else {
                        // ContentResolver streams can point at multi-gigabyte files. Copying
                        // them in a MethodChannel callback blocks Android's main thread and
                        // can trigger an ANR. Keep all file I/O on a worker thread and only
                        // marshal the result back to Flutter on the UI thread.
                        thread(name = "archive-materialize") {
                            try {
                                val materializedPath = materializeArchiveForImport(
                                    uriString,
                                    displayName,
                                )
                                runOnUiThread {
                                    result.success(materializedPath)
                                }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "ARCHIVE_MATERIALIZE_FAILED",
                                        e.message ?: "archive materialize failed",
                                        null,
                                    )
                                }
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialSharedMedia" -> {
                    result.success(ArrayList(pendingSharedItems))
                    pendingSharedItems.clear()
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    shareEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    shareEventSink = null
                }
            }
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, YT_DLP_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getYtDlpBinaryStatus" -> {
                    thread(name = "yt-dlp-binary-status", start = true) {
                        val status = getYtDlpBinaryStatus()
                        runOnUiThread { result.success(status) }
                    }
                }
                "reloadYtDlpRuntime" -> {
                    val archivePath = call.argument<String>("archivePath")
                    if (archivePath.isNullOrBlank()) {
                        result.error("INVALID_ARGS", "missing yt-dlp archive path", null)
                    } else {
                        thread(name = "yt-dlp-runtime-reload", start = true) {
                            try {
                                val version = reloadYtDlpRuntime(archivePath)
                                runOnUiThread { result.success(version) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "YT_DLP_RUNTIME_INVALID",
                                        e.message ?: "invalid yt-dlp runtime archive",
                                        null,
                                    )
                                }
                            }
                        }
                    }
                }
                "importYoutubeCookies" -> {
                    val filePath = call.argument<String>("filePath")
                    if (filePath.isNullOrEmpty()) {
                        result.success(null)
                    } else {
                        result.success(importYoutubeCookies(filePath))
                    }
                }
                "saveYoutubeSessionConfig" -> {
                    val config = call.argument<Any?>("config")
                    saveYoutubeSessionConfig(config)
                    result.success(true)
                }
                "loadYoutubeSessionConfig" -> {
                    result.success(loadYoutubeSessionConfig())
                }
                "resolveYoutubeMeta" -> {
                    val url = call.argument<String>("url")
                    val sessionConfig = call.argument<Map<String, Any?>>("sessionConfig")
                    if (url.isNullOrBlank()) {
                        result.error("INVALID_ARGS", "missing url", null)
                    } else {
                        thread(name = "yt-dlp-resolve", start = true) {
                            try {
                                val payload = resolveYoutubeMeta(url, sessionConfig)
                                runOnUiThread {
                                    result.success(payload)
                                }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "YT_DLP_RESOLVE_FAILED",
                                        e.message ?: "yt-dlp resolve failed",
                                        null,
                                    )
                                }
                            }
                        }
                    }
                }
                "startYoutubeDownload" -> {
                    val request = call.arguments as? Map<String, Any?>
                    if (request == null) {
                        result.error("INVALID_ARGS", "missing request payload", null)
                    } else {
                        try {
                            result.success(startYoutubeDownload(request))
                        } catch (e: Exception) {
                            result.error(
                                "YT_DLP_START_FAILED",
                                e.message ?: "yt-dlp download start failed",
                                null,
                            )
                        }
                    }
                }
                "pauseYoutubeDownload" -> {
                    val taskId = call.argument<String>("taskId")
                    val stopped = !taskId.isNullOrBlank() && pauseYoutubeDownload(taskId)
                    result.success(
                        mapOf(
                            "accepted" to stopped,
                            "stopped" to stopped,
                            "reason" to if (stopped) null else "running task not found",
                        ),
                    )
                }
                "cancelYoutubeDownload" -> {
                    val taskId = call.argument<String>("taskId")
                    result.success(if (taskId.isNullOrBlank()) false else cancelYoutubeDownload(taskId))
                }
                "removeYoutubeTask" -> {
                    val taskId = call.argument<String>("taskId")
                    result.success(if (taskId.isNullOrBlank()) false else removeYoutubeTask(taskId))
                }
                "getYoutubeTaskStatus" -> {
                    val taskId = call.argument<String>("taskId")
                    result.success(if (taskId.isNullOrBlank()) null else getYoutubeTaskStatus(taskId))
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, YT_DLP_EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    ytDlpEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    ytDlpEventSink = null
                }
            }
        )

        enqueueSharedItemsFromIntent(intent)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_CODE_PICK_FILES) return
        val result = pendingResult
        pendingResult = null
        val pickerMode = pendingPickerMode
        pendingPickerMode = null
        if (result == null) return
        if (resultCode != Activity.RESULT_OK || data == null) {
            when (pickerMode) {
                PickerMode.ARCHIVE -> result.success(null)
                else -> result.success(emptyList<String>())
            }
            return
        }
        val takeFlags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        val uris = mutableListOf<Uri>()
        val clipData = data.clipData
        if (clipData != null) {
            for (i in 0 until clipData.itemCount) {
                uris.add(clipData.getItemAt(i).uri)
            }
        } else {
            data.data?.let { uris.add(it) }
        }
        when (pickerMode) {
            PickerMode.ARCHIVE -> {
                val firstUri = uris.firstOrNull()
                if (firstUri == null) {
                    result.success(null)
                    return
                }
                try {
                    if (takeFlags != 0) {
                        contentResolver.takePersistableUriPermission(firstUri, takeFlags)
                    }
                } catch (_: Exception) {
                }
                result.success(buildArchiveSelectionPayload(firstUri))
            }
            else -> {
                val paths = mutableListOf<String>()
                for (uri in uris) {
                    try {
                        if (takeFlags != 0) {
                            contentResolver.takePersistableUriPermission(uri, takeFlags)
                        }
                    } catch (_: Exception) {
                    }
                    resolveToPath(uri)?.let { paths.add(it) }
                }
                result.success(paths)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        enqueueSharedItemsFromIntent(intent)
    }

    override fun onDestroy() {
        ytDlpTasks.values.forEach { task ->
            task.terminationReason = "cancel"
            sendYtDlpWorkerCommand(YtDlpWorkerService.ACTION_CANCEL, task.taskId)
        }
        ytDlpTasks.clear()
        if (ytDlpWorkerReceiverRegistered) {
            runCatching { unregisterReceiver(ytDlpWorkerReceiver) }
            ytDlpWorkerReceiverRegistered = false
        }
        sharedIntentExecutor.shutdownNow()
        super.onDestroy()
    }

    /**
     * Resolving a shared content URI may query a remote provider or copy a
     * multi-gigabyte media file into the app cache. Doing that from
     * configureFlutterEngine/onNewIntent blocks Android's main thread and
     * delays Flutter's first frame. Resolve serially in the background, then
     * preserve the existing pending-item/event-channel delivery semantics.
     */
    private fun enqueueSharedItemsFromIntent(sourceIntent: Intent?) {
        if (sourceIntent == null) return
        val action = sourceIntent.action
        if (
            action != Intent.ACTION_SEND &&
            action != Intent.ACTION_SEND_MULTIPLE &&
            action != Intent.ACTION_VIEW
        ) return

        val snapshot = Intent(sourceIntent)
        sharedIntentExecutor.execute {
            val sharedItems = extractSharedItemsFromIntent(snapshot)
            if (sharedItems.isEmpty()) return@execute
            runOnUiThread {
                if (isFinishing || (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1 && isDestroyed)) {
                    return@runOnUiThread
                }
                val sink = shareEventSink
                if (sink != null) {
                    sink.success(sharedItems)
                } else {
                    pendingSharedItems.addAll(sharedItems)
                }
            }
        }
    }

    private fun registerYtDlpWorkerReceiver() {
        if (ytDlpWorkerReceiverRegistered) return
        val filter = IntentFilter().apply {
            addAction(YtDlpWorkerService.ACTION_OUTPUT)
            addAction(YtDlpWorkerService.ACTION_PROGRESS)
            addAction(YtDlpWorkerService.ACTION_RESULT)
            addAction(YtDlpWorkerService.ACTION_ERROR)
            addAction(YtDlpWorkerService.ACTION_PAUSED)
            addAction(YtDlpWorkerService.ACTION_CANCELLED)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(ytDlpWorkerReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(ytDlpWorkerReceiver, filter)
        }
        ytDlpWorkerReceiverRegistered = true
    }

    private fun sendYtDlpWorkerCommand(action: String, taskId: String) {
        runCatching {
            startService(
                Intent(this, YtDlpWorkerService::class.java)
                    .setAction(action)
                    .putExtra(YtDlpWorkerService.EXTRA_TASK_ID, taskId),
            )
        }
    }

    private fun handleYtDlpWorkerEvent(intent: Intent) {
        val taskId = intent.getStringExtra(YtDlpWorkerService.EXTRA_TASK_ID)
            ?.trim()
            .orEmpty()
        val task = ytDlpTasks[taskId] ?: return
        when (intent.action) {
            YtDlpWorkerService.ACTION_OUTPUT -> {
                handleYoutubeDownloadOutput(
                    task,
                    intent.getStringExtra(YtDlpWorkerService.EXTRA_PAYLOAD).orEmpty(),
                )
            }
            YtDlpWorkerService.ACTION_PROGRESS -> {
                handlePythonProgress(
                    task,
                    intent.getStringExtra(YtDlpWorkerService.EXTRA_PAYLOAD).orEmpty(),
                )
            }
            YtDlpWorkerService.ACTION_PAUSED -> {
                task.status = "paused"
                task.terminationReason = "pause"
                emitTaskEvent(
                    taskId = taskId,
                    type = "task_paused",
                    progress = task.progress,
                    downloadedBytes = task.downloadedBytes,
                    totalBytes = task.totalBytes,
                    speedText = task.speedText,
                    etaText = task.etaText,
                    outputPath = task.outputPath,
                    producedPaths = snapshotProducedPaths(task),
                    message = "Paused",
                )
                ytDlpTasks.remove(taskId, task)
            }
            YtDlpWorkerService.ACTION_CANCELLED -> {
                task.status = "cancelled"
                task.terminationReason = "cancel"
                emitTaskEvent(
                    taskId = taskId,
                    type = "task_cancelled",
                    progress = task.progress,
                    outputPath = task.outputPath,
                    producedPaths = snapshotProducedPaths(task),
                    errorCode = "USER_CANCELLED",
                    message = "Cancelled",
                )
                cleanupAndroidStagedArtifacts(task)
                ytDlpTasks.remove(taskId, task)
            }
            YtDlpWorkerService.ACTION_RESULT -> {
                val rawResult = intent
                    .getStringExtra(YtDlpWorkerService.EXTRA_PAYLOAD)
                    .orEmpty()
                finishYtDlpWorkerDownload(task, decodeJsonObject(rawResult) ?: emptyMap())
            }
            YtDlpWorkerService.ACTION_ERROR -> {
                task.status = "failed"
                task.errorCode = "RUNTIME_ERROR"
                appendTaskLog(
                    task,
                    intent.getStringExtra(YtDlpWorkerService.EXTRA_MESSAGE)
                        ?: "worker runtime error",
                )
                emitTaskEvent(
                    taskId = taskId,
                    type = "task_failed",
                    progress = task.progress,
                    outputPath = task.outputPath,
                    producedPaths = snapshotProducedPaths(task),
                    errorCode = task.errorCode,
                    message = buildTaskFailureMessage(task, null),
                )
                ytDlpTasks.remove(taskId, task)
            }
        }
    }

    private fun finishYtDlpWorkerDownload(
        task: RunningYtDlpTask,
        downloadResult: Map<String, Any?>,
    ) {
        if (task.terminationReason != null) return
        val exitCode = (downloadResult["exitCode"] as? Number)?.toInt() ?: 1
        applyDownloadArtifacts(task, downloadResult)
        if (exitCode == 0 && hasUsableMediaArtifact(snapshotProducedPaths(task))) {
            task.status = "completed"
            emitTaskEvent(
                taskId = task.taskId,
                type = "task_completed",
                progress = 1.0,
                speedText = task.speedText,
                etaText = "00:00",
                outputPath = task.outputPath,
                producedPaths = snapshotProducedPaths(task),
                message = "Download completed",
            )
        } else {
            task.status = "failed"
            task.errorCode = if (exitCode == 0) "NO_MEDIA_ARTIFACT" else "EXIT_$exitCode"
            emitTaskEvent(
                taskId = task.taskId,
                type = "task_failed",
                progress = task.progress,
                speedText = task.speedText,
                etaText = task.etaText,
                outputPath = task.outputPath,
                producedPaths = snapshotProducedPaths(task),
                errorCode = task.errorCode,
                message = buildTaskFailureMessage(task, exitCode),
            )
        }
        ytDlpTasks.remove(task.taskId, task)
    }

    private fun openSystemFilePicker(mimeTypes: List<String>, allowMultiple: Boolean) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
        intent.addCategory(Intent.CATEGORY_OPENABLE)
        intent.type = "*/*"
        intent.putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toTypedArray())
        intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, allowMultiple)
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        intent.addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        startActivityForResult(intent, REQUEST_CODE_PICK_FILES)
    }

    private fun openFileManager() {
        try {
            // Try to open the specific path if possible, but Android 11+ is strict.
            // We try to open the system file manager (DocumentsUI).
            val uri = Uri.parse("content://com.android.externalstorage.documents/root/primary%3AAndroid%2Fdata%2Ftv.danmaku.bili%2Fdownload")
            val intent = Intent(Intent.ACTION_VIEW)
            intent.setDataAndType(uri, "vnd.android.document/directory")
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        } catch (e: Exception) {
            try {
                // Fallback: Open standard download folder or root
                val intent = Intent(Intent.ACTION_VIEW)
                intent.setDataAndType(Uri.parse(Environment.getExternalStorageDirectory().path), "*/*")
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
            } catch (e2: Exception) {
                // Fallback 2: Open settings? Or just give up gracefully
            }
        }
    }

    private fun extractSharedItemsFromIntent(intent: Intent?): List<Map<String, Any?>> {
        if (intent == null) return emptyList()
        val action = intent.action ?: return emptyList()
        val collectedUris = mutableListOf<Uri>()
        when (action) {
            Intent.ACTION_SEND -> {
                val stream = intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                if (stream != null) {
                    collectedUris.add(stream)
                } else {
                    intent.data?.let { collectedUris.add(it) }
                }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val streams = intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                if (streams != null) {
                    collectedUris.addAll(streams.filterNotNull())
                }
            }
            Intent.ACTION_VIEW -> {
                intent.data?.let { collectedUris.add(it) }
            }
            else -> return emptyList()
        }
        val typeHint = intent.type
        val items = mutableListOf<Map<String, Any?>>()
        for (uri in collectedUris) {
            val item = resolveSharedImportItem(uri, typeHint)
            if (item != null) {
                items.add(item)
            }
        }
        return items
    }

    private fun resolveSharedImportItem(uri: Uri, typeHint: String?): Map<String, Any?>? {
        return try {
            if (isLikelyArchive(uri, typeHint)) {
                val payload = buildArchiveSelectionPayload(uri).toMutableMap()
                payload["kind"] = "archive"
                payload
            } else {
                val path = resolveMediaUriToImportablePath(uri, typeHint)
                if (path.isNullOrEmpty()) {
                    null
                } else {
                    mapOf(
                        "kind" to "media",
                        "path" to path,
                    )
                }
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun resolveMediaUriToImportablePath(uri: Uri, typeHint: String?): String? {
        return try {
            if (!isLikelyMedia(uri, typeHint)) return null
            if ("file" == uri.scheme) {
                val path = uri.path ?: return null
                return if (isMediaPath(path)) path else null
            }
            if (uri.authority == "${packageName}.fileprovider") {
                return copyUriToCache(uri)
            }
            val directPath = resolveToPath(uri)
            if (!directPath.isNullOrEmpty() && isMediaPath(directPath)) {
                return directPath
            }
            copyUriToCache(uri)
        } catch (_: Exception) {
            null
        }
    }

    private fun isLikelyMedia(uri: Uri, typeHint: String?): Boolean {
        val normalizedHint = typeHint?.lowercase(Locale.ROOT)
        if (!normalizedHint.isNullOrEmpty() && normalizedHint != "*/*") {
            if (normalizedHint.startsWith("video/") || normalizedHint.startsWith("audio/")) return true
        }
        val resolverType = contentResolver.getType(uri)?.lowercase(Locale.ROOT)
        if (!resolverType.isNullOrEmpty()) {
            if (resolverType.startsWith("video/") || resolverType.startsWith("audio/")) return true
        }
        val displayName = queryDisplayName(uri)
        if (!displayName.isNullOrEmpty() && isMediaPath(displayName)) return true
        val lastPath = uri.lastPathSegment
        if (!lastPath.isNullOrEmpty() && isMediaPath(lastPath)) return true
        return false
    }

    private fun isLikelyArchive(uri: Uri, typeHint: String?): Boolean {
        val normalizedHint = typeHint?.lowercase(Locale.ROOT)
        if (!normalizedHint.isNullOrEmpty() && normalizedHint != "*/*") {
            if (
                normalizedHint.contains("zip") ||
                normalizedHint.contains("tar") ||
                normalizedHint.contains("gzip") ||
                normalizedHint.contains("bzip") ||
                normalizedHint.contains("xz") ||
                normalizedHint.contains("compressed")
            ) return true
        }
        val resolverType = contentResolver.getType(uri)?.lowercase(Locale.ROOT)
        if (!resolverType.isNullOrEmpty()) {
            if (
                resolverType.contains("zip") ||
                resolverType.contains("tar") ||
                resolverType.contains("gzip") ||
                resolverType.contains("bzip") ||
                resolverType.contains("xz") ||
                resolverType.contains("compressed")
            ) return true
        }
        val displayName = queryDisplayName(uri)
        if (!displayName.isNullOrEmpty() && isArchivePath(displayName)) return true
        val lastPath = uri.lastPathSegment
        if (!lastPath.isNullOrEmpty() && isArchivePath(lastPath)) return true
        return false
    }

    private fun isMediaPath(path: String): Boolean {
        val lower = path.lowercase(Locale.ROOT)
        return mediaExtensions.any { lower.endsWith(it) }
    }

    private fun isArchivePath(path: String): Boolean {
        val lower = path.lowercase(Locale.ROOT)
        return archiveExtensions.any { lower.endsWith(it) }
    }

    private fun queryFileSize(uri: Uri): Long? {
        contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (index >= 0 && !cursor.isNull(index)) {
                    return cursor.getLong(index)
                }
            }
        }
        return null
    }

    private fun buildArchiveSelectionPayload(uri: Uri): Map<String, Any?> {
        val displayName = queryDisplayName(uri)
            ?.takeIf { it.isNotBlank() }
            ?: uri.lastPathSegment
            ?: "archive"
        if (!isArchivePath(displayName)) {
            throw IllegalArgumentException("当前仅支持 zip、tar、tar.gz、tar.bz2、tar.xz 压缩包")
        }

        val directPath = resolveToPath(uri)?.takeIf { isArchivePath(it) }
        return mapOf(
            "displayName" to displayName,
            "sizeBytes" to queryFileSize(uri),
            "path" to directPath,
            "uri" to if (directPath == null) uri.toString() else null,
        )
    }

    private fun queryDisplayName(uri: Uri): String? {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) {
                    val value = cursor.getString(index)
                    if (!value.isNullOrEmpty()) return value
                }
            }
        }
        return null
    }

    private fun materializeArchiveForImport(uriString: String, displayName: String?): String {
        val uri = Uri.parse(uriString)
        val directPath = resolveToPath(uri)?.takeIf { isArchivePath(it) }
        if (!directPath.isNullOrBlank()) {
            return directPath
        }

        val safeName = (displayName ?: queryDisplayName(uri) ?: "archive")
            .replace(Regex("""[^\u4e00-\u9fa5A-Za-z0-9._-]"""), "_")
            .takeIf { it.isNotBlank() }
            ?: "archive_${System.currentTimeMillis()}"
        val finalName = if (isArchivePath(safeName)) {
            safeName
        } else {
            "${safeName}.zip"
        }
        val archiveDir = File(cacheDir, "picked_archives").apply { mkdirs() }
        var outFile = File(archiveDir, finalName)
        if (outFile.exists()) {
            val base = finalName.substringBeforeLast('.', finalName)
            val suffix = finalName.substringAfterLast('.', "")
            val uniqueName = if (suffix.isNotEmpty()) {
                "${base}_${System.currentTimeMillis()}.$suffix"
            } else {
                "${base}_${System.currentTimeMillis()}"
            }
            outFile = File(archiveDir, uniqueName)
        }
        val partialFile = File(outFile.parentFile, "${outFile.name}.partial")
        try {
            if (partialFile.exists()) {
                partialFile.delete()
            }
            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(partialFile).use { output ->
                    input.copyTo(output, bufferSize = 1024 * 1024)
                    output.fd.sync()
                }
            } ?: throw IllegalStateException("无法读取压缩包内容")
            if (partialFile.length() <= 0L || !partialFile.renameTo(outFile)) {
                throw IllegalStateException("无法保存压缩包临时副本")
            }
        } catch (e: Exception) {
            runCatching { partialFile.delete() }
            throw e
        }
        return outFile.absolutePath
    }

    private fun copyUriToCache(uri: Uri): String? {
        return try {
            val resolver = contentResolver
            val displayName = queryDisplayName(uri)
            val mime = resolver.getType(uri)?.lowercase(Locale.ROOT)
            val ext = run {
                val fromName = displayName?.substringAfterLast('.', "")
                if (!fromName.isNullOrEmpty()) fromName.lowercase(Locale.ROOT) else {
                    val fromMime = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
                    fromMime?.lowercase(Locale.ROOT)
                }
            }
            val baseName = displayName?.substringBeforeLast('.', displayName)
                ?.replace(Regex("""[^\u4e00-\u9fa5A-Za-z0-9._-]"""), "_")
                ?.takeIf { it.isNotEmpty() }
                ?: "shared_media_${System.currentTimeMillis()}"
            val fileName = if (!ext.isNullOrEmpty()) "$baseName.$ext" else baseName
            if (!isMediaPath(fileName)) return null
            var outFile = File(cacheDir, fileName)
            if (outFile.exists()) {
                val base = fileName.substringBeforeLast('.', fileName)
                val suffix = fileName.substringAfterLast('.', "")
                val uniqueName = if (suffix.isNotEmpty()) {
                    "${base}_${System.currentTimeMillis()}.$suffix"
                } else {
                    "${base}_${System.currentTimeMillis()}"
                }
                outFile = File(cacheDir, uniqueName)
            }
            resolver.openInputStream(uri)?.use { input ->
                FileOutputStream(outFile).use { output ->
                    input.copyTo(output)
                }
            } ?: return null
            outFile.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    private fun resolveToPath(uri: Uri): String? {
        if ("file" == uri.scheme) {
            return uri.path
        }
        if ("content" == uri.scheme) {
            if (DocumentsContract.isDocumentUri(this, uri)) {
                val docId = DocumentsContract.getDocumentId(uri)
                val split = docId.split(":")
                val type = split.getOrNull(0)
                val relPath = split.getOrNull(1)
                if (isExternalStorageDocument(uri)) {
                    if (type.equals("primary", true)) {
                        val base = Environment.getExternalStorageDirectory().absolutePath
                        return if (relPath.isNullOrEmpty()) base else "$base/$relPath"
                    }
                    val secondary = System.getenv("SECONDARY_STORAGE")?.split(":")?.firstOrNull()
                    if (!secondary.isNullOrEmpty() && !relPath.isNullOrEmpty()) {
                        return "$secondary/$relPath"
                    }
                    return null
                }
                if (isDownloadsDocument(uri)) {
                    if (docId.startsWith("raw:")) {
                        return docId.removePrefix("raw:")
                    }
                    val contentUri = docId.toLongOrNull()?.let {
                        ContentUris.withAppendedId(Uri.parse("content://downloads/public_downloads"), it)
                    }
                    return contentUri?.let { getDataColumn(it, null, null) }
                }
                if (isMediaDocument(uri)) {
                    val mediaType = type ?: return null
                    val contentUri = when (mediaType) {
                        "video" -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                        "audio" -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
                        "image" -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                        else -> null
                    } ?: return null
                    val id = split.getOrNull(1) ?: return null
                    return getDataColumn(contentUri, "_id=?", arrayOf(id))
                }
            }
            return getDataColumn(uri, null, null)
        }
        return null
    }

    private fun getDataColumn(uri: Uri, selection: String?, selectionArgs: Array<String>?): String? {
        return try {
            val projection = arrayOf(MediaStore.MediaColumns.DATA)
            contentResolver.query(uri, projection, selection, selectionArgs, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(MediaStore.MediaColumns.DATA)
                    if (index >= 0) {
                        return cursor.getString(index)
                    }
                }
            }
            null
        } catch (_: Exception) {
            null
        }
    }

    private fun isExternalStorageDocument(uri: Uri): Boolean {
        return "com.android.externalstorage.documents" == uri.authority
    }

    private fun isDownloadsDocument(uri: Uri): Boolean {
        return "com.android.providers.downloads.documents" == uri.authority
    }

    private fun isMediaDocument(uri: Uri): Boolean {
        return "com.android.providers.media.documents" == uri.authority
    }

    private fun ensurePythonRuntimeReady() {
        if (!Python.isStarted()) {
            Python.start(AndroidPlatform(applicationContext))
        }
    }

    @Volatile
    private var activeYtDlpRuntimePath: String? = null

    private fun getYtDlpPythonModule() = Python.getInstance().getModule("yt_dlp_bridge")

    private fun reloadYtDlpRuntime(archivePath: String): String? {
        ensurePythonRuntimeReady()
        val archive = File(archivePath)
        require(archive.isFile) { "yt-dlp runtime archive does not exist" }
        val version = getYtDlpPythonModule()
            .callAttr("configure_runtime", archive.absolutePath)
            ?.toString()
        require(!version.isNullOrBlank()) { "unable to read yt-dlp runtime version" }
        activeYtDlpRuntimePath = archive.absolutePath
        return version
    }

    private fun queryPythonYtDlpVersion(): String? {
        return runCatching {
            ensurePythonRuntimeReady()
            val module = getYtDlpPythonModule()
            val archive = File(filesDir, "yt_dlp/yt-dlp")
            val version = if (archive.isFile) {
                module.callAttr("configure_runtime", archive.absolutePath)?.toString()
            } else {
                module.callAttr("configure_runtime")?.toString()
            }
            activeYtDlpRuntimePath = if (archive.isFile) archive.absolutePath else null
            version
        }.recoverCatching {
            val version = getYtDlpPythonModule().callAttr("configure_runtime")?.toString()
            activeYtDlpRuntimePath = null
            version
        }.getOrNull()
    }

    private fun getYtDlpBinaryStatus(): Map<String, Any?> {
        val ffmpeg = resolveFfmpegBinary()
        val hasCli = ffmpeg.exists()
        val ytDlpVersion = queryPythonYtDlpVersion()
        val ytDlpReady = ytDlpVersion != null
        // 没有独立 CLI 时，FFmpegKit 作为内建后处理引擎始终可用
        val ffmpegVersion = if (hasCli) {
            queryBinaryVersion(ffmpeg, listOf("-version"))
        } else {
            "FFmpegKit (内建可用)"
        }
        val diagnosticMessage = buildString {
            append("yt-dlp runtime: python module (Chaquopy)")
            append('\n')
            append("ffmpeg: ")
            append(if (hasCli) ffmpeg.absolutePath else "FFmpegKit (内建)")
            if (!ytDlpReady) {
                append('\n')
                append("Android Python 运行时或 yt-dlp 模块尚未就绪，请确认构建时已成功安装 Chaquopy 与 yt-dlp 依赖。")
            }
            if (!hasCli) {
                append('\n')
                append("未检测到独立 ffmpeg CLI；下载后处理将使用 FFmpegKit 完成音视频合成。")
            }
        }
        return mapOf(
            "ytDlpReady" to ytDlpReady,
            // FFmpegKit is a complete FFmpeg backend for the app even when
            // yt-dlp cannot invoke a standalone CLI executable directly.
            "ffmpegReady" to true,
            "ffmpegCliReady" to hasCli,
            "ffmpegBackend" to if (hasCli) "独立 CLI" else "FFmpegKit 内置插件",
            "ytDlpVersion" to ytDlpVersion,
            "ffmpegVersion" to ffmpegVersion,
            "ytDlpPath" to if (ytDlpReady) {
                activeYtDlpRuntimePath ?: "python:yt_dlp (APK 内置)"
            } else null,
            "ffmpegPath" to if (hasCli) ffmpeg.absolutePath else "FFmpegKit",
            "diagnosticMessage" to diagnosticMessage,
        )
    }

    private fun importYoutubeCookies(sourcePath: String): String? {
        return try {
            val source = File(sourcePath)
            if (!source.exists()) return null
            val targetDir = File(filesDir, "yt_dlp/cookies")
            if (!targetDir.exists()) {
                targetDir.mkdirs()
            }
            val target = File(targetDir, "cookies.txt")
            source.copyTo(target, overwrite = true)
            target.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    private fun saveYoutubeSessionConfig(config: Any?) {
        val prefs = getSharedPreferences("yt_dlp_bridge", Context.MODE_PRIVATE)
        prefs.edit().putString("session_config_raw", encodeDynamicJson(config)).apply()
    }

    private fun loadYoutubeSessionConfig(): Map<String, Any?>? {
        val prefs = getSharedPreferences("yt_dlp_bridge", Context.MODE_PRIVATE)
        val raw = prefs.getString("session_config_raw", null) ?: return null
        return decodeJsonObject(raw)
    }

    private fun resolveYoutubeMeta(
        url: String,
        sessionConfig: Map<String, Any?>?,
    ): Map<String, Any?> {
        ensurePythonRuntimeReady()
        val output = getYtDlpPythonModule()
            .callAttr("resolve_meta", url, encodeDynamicJson(sessionConfig))
            ?.toString()
            ?.trim()
            .orEmpty()
        if (output.isBlank()) {
            throw IllegalStateException("yt-dlp resolve returned empty result")
        }
        val decoded = decodeJsonObject(output)
        return if (decoded != null) {
            mapOf(
                "rawInfo" to decoded,
                "rawInfoJson" to output,
            )
        } else {
            mapOf("rawInfoJson" to output)
        }
    }

    private fun resolveYtDlpBinary(): File {
        val baseDir = File(filesDir, "yt_dlp")
        val candidates = listOf(
            File(baseDir, "yt-dlp"),
            File(baseDir, "yt-dlp_linux"),
            File(baseDir, "yt-dlp_android"),
        )
        return candidates.firstOrNull { it.exists() } ?: candidates.first()
    }

    private fun resolveFfmpegBinary(): File {
        val baseDir = File(filesDir, "yt_dlp")
        val candidates = listOf(
            File(baseDir, "ffmpeg"),
            File(baseDir, "ffmpeg_android"),
        )
        return candidates.firstOrNull { it.exists() } ?: candidates.first()
    }

    private fun queryBinaryVersion(binary: File, args: List<String>): String? {
        return try {
            val process = ProcessBuilder(listOf(binary.absolutePath) + args)
                .directory(binary.parentFile)
                .redirectErrorStream(true)
                .start()
            val output = process.inputStream.bufferedReader().use { it.readText() }
            process.waitFor(20, TimeUnit.SECONDS)
            output.lineSequence().firstOrNull { it.isNotBlank() }?.trim()
        } catch (_: Exception) {
            null
        }
    }

    private fun buildSessionArgs(sessionConfig: Map<String, Any?>?): List<String> {
        if (sessionConfig == null) return emptyList()
        val args = mutableListOf<String>()

        fun readString(key: String): String? {
            return sessionConfig[key]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        }

        fun readInt(key: String): Int? {
            val value = sessionConfig[key] ?: return null
            return when (value) {
                is Int -> value
                is Long -> value.toInt()
                is Double -> value.toInt()
                is Float -> value.toInt()
                else -> value.toString().toIntOrNull()
            }
        }

        fun readBool(key: String): Boolean {
            val value = sessionConfig[key] ?: return false
            return when (value) {
                is Boolean -> value
                is String -> value.equals("true", ignoreCase = true)
                else -> false
            }
        }

        if (readBool("useCookies")) {
            readString("cookiesFilePath")?.let {
                args.add("--cookies")
                args.add(it)
            }
        }
        if (readBool("useCustomUserAgent")) {
            readString("userAgent")?.let {
                args.add("--add-header")
                args.add("User-Agent:$it")
            }
        }
        if (readBool("useProxy")) {
            readString("proxy")?.let {
                args.add("--proxy")
                args.add(it)
            }
        }
        readInt("socketTimeoutSeconds")?.takeIf { it > 0 }?.let {
            args.add("--socket-timeout")
            args.add(it.toString())
        }
        readInt("retries")?.takeIf { it > 0 }?.let {
            args.add("--retries")
            args.add(it.toString())
        }
        readInt("fragmentRetries")?.takeIf { it > 0 }?.let {
            args.add("--fragment-retries")
            args.add(it.toString())
        }
        readInt("concurrentFragments")?.takeIf { it > 0 }?.let {
            args.add("-N")
            args.add(it.toString())
        }
        readString("rateLimit")?.let {
            args.add("-r")
            args.add(it)
        }
        if (readBool("forceIpv4")) {
            args.add("-4")
        }

        buildYoutubeExtractorArgs(sessionConfig)?.let {
            args.add("--extractor-args")
            args.add(it)
        }
        return args
    }

    private fun buildYoutubeExtractorArgs(sessionConfig: Map<String, Any?>): String? {
        val parts = mutableListOf<String>()
        val clients = (sessionConfig["enabledPlayerClients"] as? List<*>)
            .orEmpty()
            .mapNotNull { it?.toString()?.trim()?.takeIf { value -> value.isNotEmpty() } }
        if (clients.isNotEmpty()) {
            parts.add("player_client=${clients.joinToString(",")}")
        }
        sessionConfig["visitorData"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }?.let {
            parts.add("visitor_data=$it")
        }
        val poTokens = (sessionConfig["poTokens"] as? List<*>)
            .orEmpty()
            .mapNotNull { it as? Map<*, *> }
            .mapNotNull { token ->
                val enabled = token["enabled"] as? Boolean ?: true
                val client = token["client"]?.toString()?.trim().orEmpty()
                val context = token["context"]?.toString()?.trim().orEmpty()
                val value = token["token"]?.toString()?.trim().orEmpty()
                if (!enabled || client.isEmpty() || context.isEmpty() || value.isEmpty()) {
                    null
                } else {
                    "$client.$context+$value"
                }
            }
        if (poTokens.isNotEmpty()) {
            parts.add("po_token=${poTokens.joinToString(",")}")
        }
        return if (parts.isEmpty()) null else "youtube:${parts.joinToString(";")}"
    }

    private fun startYoutubeDownload(request: Map<String, Any?>): Boolean {
        val taskId = request["taskId"]?.toString()?.trim().orEmpty()
        val sourceUrl = request["url"]?.toString()?.trim().orEmpty()
        val outputDir = request["outputDir"]?.toString()?.trim().orEmpty()
        val outputTemplate = request["outputTemplate"]?.toString()?.trim().orEmpty()
        val debugContext = (request["debugContext"] as? Map<*, *>)
            ?.entries
            ?.associate { (key, value) -> key.toString() to value }
            ?: emptyMap()
        val args = (request["args"] as? List<*>)
            .orEmpty()
            .mapNotNull { it?.toString() }
            .toMutableList()

        require(taskId.isNotEmpty()) { "missing taskId" }
        require(sourceUrl.isNotEmpty()) { "missing url" }
        require(outputDir.isNotEmpty()) { "missing outputDir" }
        require(args.isNotEmpty()) { "missing yt-dlp args" }

        val ffmpeg = resolveFfmpegBinary()
        val androidPostProcessMode = debugContext["androidPostProcessMode"] == true
        val sanitizedArgs = sanitizeAndroidDownloadArgs(
            args,
            ffmpeg.exists(),
            androidPostProcessMode,
        )
        val executableArgs = injectFfmpegLocationArg(sanitizedArgs, ffmpeg)

        val outputDirectory = File(outputDir).apply { mkdirs() }
        ytDlpTasks[taskId]?.let { existing ->
            existing.terminationReason = "cancel"
            sendYtDlpWorkerCommand(YtDlpWorkerService.ACTION_CANCEL, taskId)
            ytDlpTasks.remove(taskId)
        }

        val task = RunningYtDlpTask(
            taskId = taskId,
            outputDir = outputDir,
            outputTemplate = outputTemplate,
            sourceUrl = sourceUrl,
            requestPayload = mapOf(
                "taskId" to taskId,
                "url" to sourceUrl,
                "outputDir" to outputDir,
                "outputTemplate" to outputTemplate,
                "args" to executableArgs,
                "debugContext" to debugContext,
            ),
            debugContext = debugContext,
        )
        ytDlpTasks[taskId] = task
        emitTaskEvent(taskId = taskId, type = "task_queued", message = "已加入下载队列")

        task.status = "downloading"
        emitTaskEvent(
            taskId = task.taskId,
            type = "task_started",
            progress = 0.0,
            message = "Starting download",
        )
        val requestJson = encodeDynamicJson(task.requestPayload)
            ?: throw IllegalStateException("failed to encode yt-dlp request")
        startService(
            Intent(this, YtDlpWorkerService::class.java)
                .setAction(YtDlpWorkerService.ACTION_START)
                .putExtra(YtDlpWorkerService.EXTRA_TASK_ID, taskId)
                .putExtra(YtDlpWorkerService.EXTRA_REQUEST_JSON, requestJson),
        )
        return true
    }

    private fun pauseYoutubeDownload(taskId: String): Boolean {
        val task = ytDlpTasks[taskId] ?: return false
        task.terminationReason = "pause"
        task.status = "paused"
        task.message = "已暂停"
        sendYtDlpWorkerCommand(YtDlpWorkerService.ACTION_PAUSE, taskId)
        return true
    }

    private fun cancelYoutubeDownload(taskId: String): Boolean {
        val task = ytDlpTasks[taskId] ?: return false
        task.terminationReason = "cancel"
        task.status = "cancelled"
        task.message = "已取消"
        sendYtDlpWorkerCommand(YtDlpWorkerService.ACTION_CANCEL, taskId)
        return true
    }

    private fun removeYoutubeTask(taskId: String): Boolean {
        val task = ytDlpTasks[taskId]
        if (task != null) {
            task.terminationReason = "cancel"
            task.status = "cancelled"
            task.message = "任务已移除"
            sendYtDlpWorkerCommand(YtDlpWorkerService.ACTION_CANCEL, taskId)
            cleanupAndroidStagedArtifacts(task)
        }
        return true
    }

    private fun getYoutubeTaskStatus(taskId: String): Map<String, Any?>? {
        val task = ytDlpTasks[taskId] ?: return null
        return mapOf(
            "taskId" to task.taskId,
            "status" to task.status,
            "progress" to task.progress,
            "downloadedBytes" to task.downloadedBytes,
            "totalBytes" to task.totalBytes,
            "speedText" to task.speedText,
            "etaText" to task.etaText,
            "outputPath" to task.outputPath,
            "message" to task.message,
            "errorCode" to task.errorCode,
        )
    }

    private fun monitorYoutubeDownload(task: RunningYtDlpTask) {
        try {
            ensurePythonRuntimeReady()
            task.status = "downloading"
            emitTaskEvent(
                taskId = task.taskId,
                type = "task_started",
                progress = 0.0,
                outputPath = task.outputPath,
                producedPaths = snapshotProducedPaths(task),
                message = "开始下载",
            )
            val downloadResult = getYtDlpPythonModule()
                .callAttr(
                    "download",
                    encodeDynamicJson(task.requestPayload),
                    PythonTaskCallback(task),
                )
                ?.toJava(String::class.java)
                ?.let(::decodeJsonObject)
                ?: emptyMap()
            val exitCode = (downloadResult["exitCode"] as? Number)?.toInt() ?: 1
            applyDownloadArtifacts(task, downloadResult)
            when (task.terminationReason) {
                "pause" -> {
                    task.status = "paused"
                    emitTaskEvent(
                        taskId = task.taskId,
                        type = "task_paused",
                        progress = task.progress,
                        downloadedBytes = task.downloadedBytes,
                        totalBytes = task.totalBytes,
                        speedText = task.speedText,
                        etaText = task.etaText,
                        outputPath = task.outputPath,
                        producedPaths = snapshotProducedPaths(task),
                        message = task.message ?: "已暂停",
                    )
                }
                "cancel" -> {
                    task.status = "cancelled"
                    emitTaskEvent(
                        taskId = task.taskId,
                        type = "task_cancelled",
                        progress = task.progress,
                        downloadedBytes = task.downloadedBytes,
                        totalBytes = task.totalBytes,
                        speedText = task.speedText,
                        etaText = task.etaText,
                        outputPath = task.outputPath,
                        producedPaths = snapshotProducedPaths(task),
                        errorCode = "USER_CANCELLED",
                        message = task.message ?: "已取消",
                    )
                }
                else -> {
                    if (exitCode == 0) {
                        val producedPaths = snapshotProducedPaths(task)
                        if (!hasUsableMediaArtifact(producedPaths)) {
                            task.status = "failed"
                            task.errorCode = "NO_MEDIA_ARTIFACT"
                            task.message = "yt-dlp 下载完成但未产出可用媒体文件"
                            emitTaskEvent(
                                taskId = task.taskId,
                                type = "task_failed",
                                progress = task.progress,
                                speedText = task.speedText,
                                etaText = task.etaText,
                                outputPath = task.outputPath,
                                producedPaths = producedPaths,
                                errorCode = task.errorCode,
                                message = buildTaskFailureMessage(task, null),
                            )
                            return
                        }
                        task.status = "completed"
                        emitTaskEvent(
                            taskId = task.taskId,
                            type = "task_completed",
                            progress = 1.0,
                            speedText = task.speedText,
                            etaText = "00:00",
                            outputPath = task.outputPath,
                            producedPaths = snapshotProducedPaths(task),
                            message = task.message ?: "下载完成",
                        )
                    } else {
                        task.status = "failed"
                        task.errorCode = "EXIT_$exitCode"
                        emitTaskEvent(
                            taskId = task.taskId,
                            type = "task_failed",
                            progress = task.progress,
                            speedText = task.speedText,
                            etaText = task.etaText,
                            outputPath = task.outputPath,
                            producedPaths = snapshotProducedPaths(task),
                            errorCode = task.errorCode,
                            message = buildTaskFailureMessage(task, exitCode),
                        )
                    }
                }
            }
        } catch (e: Exception) {
            if (task.terminationReason == "pause") {
                task.status = "paused"
                emitTaskEvent(
                    taskId = task.taskId,
                    type = "task_paused",
                    progress = task.progress,
                    downloadedBytes = task.downloadedBytes,
                    totalBytes = task.totalBytes,
                    speedText = task.speedText,
                    etaText = task.etaText,
                    outputPath = task.outputPath,
                    producedPaths = snapshotProducedPaths(task),
                    message = task.message ?: "已暂停",
                )
            } else if (task.terminationReason == "cancel") {
                task.status = "cancelled"
                emitTaskEvent(
                    taskId = task.taskId,
                    type = "task_cancelled",
                    progress = task.progress,
                    downloadedBytes = task.downloadedBytes,
                    totalBytes = task.totalBytes,
                    outputPath = task.outputPath,
                    producedPaths = snapshotProducedPaths(task),
                    errorCode = "USER_CANCELLED",
                    message = task.message ?: "已取消",
                )
            } else {
                task.status = "failed"
                task.errorCode = "RUNTIME_ERROR"
                appendTaskLog(task, e.message ?: "runtime error")
                emitTaskEvent(
                    taskId = task.taskId,
                    type = "task_failed",
                    progress = task.progress,
                    speedText = task.speedText,
                    etaText = task.etaText,
                    outputPath = task.outputPath,
                    producedPaths = snapshotProducedPaths(task),
                    errorCode = task.errorCode,
                    message = buildTaskFailureMessage(task, null),
                )
            }
        } finally {
            if (task.terminationReason == "cancel") {
                cleanupAndroidStagedArtifacts(task)
            }
            ytDlpTasks.remove(task.taskId)
        }
    }

    private fun sanitizeAndroidDownloadArgs(
        originalArgs: List<String>,
        ffmpegAvailable: Boolean,
        androidPostProcessMode: Boolean,
    ): List<String> {
        if (ffmpegAvailable || androidPostProcessMode) {
            return originalArgs
        }
        val args = originalArgs.toMutableList()
        var index = 0
        while (index < args.size) {
            when (args[index]) {
                "-f" -> {
                    val format = args.getOrNull(index + 1)
                    if (format != null && format.contains("+")) {
                        args[index + 1] = "best"
                    }
                    index += 2
                }
                "--merge-output-format" -> {
                    args.removeAt(index)
                    if (index < args.size) args.removeAt(index)
                }
                "--embed-subs" -> {
                    args.removeAt(index)
                }
                "--postprocessor-args" -> {
                    args.removeAt(index)
                    if (index < args.size) args.removeAt(index)
                }
                "--extract-audio", "--audio-format" -> {
                    throw IllegalStateException(
                        "当前 Android 运行时尚未接入 ffmpeg CLI，所选任务需要音频提取或转码，请先改为直接下载可播放格式。",
                    )
                }
                else -> {
                    index += 1
                }
            }
        }
        return args
    }

    private fun injectFfmpegLocationArg(
        originalArgs: List<String>,
        ffmpeg: File,
    ): List<String> {
        if (!ffmpeg.exists()) {
            return originalArgs
        }
        if (originalArgs.any { it == "--ffmpeg-location" }) {
            return originalArgs
        }
        return originalArgs + listOf("--ffmpeg-location", ffmpeg.absolutePath)
    }

    private fun applyDownloadArtifacts(task: RunningYtDlpTask, result: Map<String, Any?>) {
        trackProducedPath(task, result["outputPath"]?.toString())
        val producedPaths = (result["producedPaths"] as? List<*>) ?: return
        producedPaths.forEach { path ->
            trackProducedPath(task, path?.toString())
        }
    }

    private fun isSubtitleArtifact(path: String): Boolean {
        val lowerPath = path.lowercase(Locale.ROOT)
        return listOf(
            ".srt",
            ".ass",
            ".ssa",
            ".vtt",
            ".lrc",
            ".ttml",
            ".srv1",
            ".srv2",
            ".srv3",
            ".json3",
        ).any(lowerPath::endsWith)
    }

    private fun hasUsableMediaArtifact(paths: List<String>): Boolean {
        return paths.any { path ->
            isMediaPath(path) && File(path).exists()
        }
    }

    private fun handlePythonProgress(task: RunningYtDlpTask, rawPayload: String) {
        val payload = decodeJsonObject(rawPayload) ?: return
        val phase = payload["phase"]?.toString()?.trim().orEmpty()
        val status = payload["status"]?.toString()?.trim().orEmpty()
        val outputPath = payload["outputPath"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        val overallProgress = (payload["overallProgress"] as? Number)?.toDouble()
        val downloadedBytes =
            (payload["overallDownloadedBytes"] as? Number)?.toLong()
                ?: (payload["downloadedBytes"] as? Number)?.toLong()
        val totalBytes =
            (payload["overallTotalBytes"] as? Number)?.toLong()
                ?: (payload["totalBytes"] as? Number)?.toLong()
        trackProducedPath(task, outputPath)
        if (downloadedBytes != null) {
            task.downloadedBytes = downloadedBytes
        }
        if (totalBytes != null) {
            task.totalBytes = totalBytes
        }
        task.speedText = payload["speedText"]?.toString() ?: task.speedText
        task.etaText = payload["etaText"]?.toString() ?: task.etaText

        if (phase == "post_processing") {
            val postprocessor = payload["postprocessor"]?.toString()?.trim()
            task.status = "post_processing"
            task.progress = maxOf(task.progress ?: 0.0, 0.92)
            task.message = buildPostProcessorMessage(postprocessor, status)
            emitTaskEvent(
                taskId = task.taskId,
                type = "task_post_processing",
                progress = task.progress,
                downloadedBytes = task.downloadedBytes,
                totalBytes = task.totalBytes,
                speedText = task.speedText,
                etaText = task.etaText,
                outputPath = task.outputPath,
                producedPaths = snapshotProducedPaths(task),
                message = task.message,
            )
            return
        }

        val mediaKind = payload["mediaKind"]?.toString()?.trim().orEmpty()
        val formatId = payload["formatId"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        val fragmentIndex = (payload["fragmentIndex"] as? Number)?.toInt()
        val fragmentCount = (payload["fragmentCount"] as? Number)?.toInt()
        val stagedProgress = overallProgress?.let {
            mapMediaDownloadProgress(it)
        }

        when (status) {
            "downloading" -> {
                task.status = "downloading"
                if (stagedProgress != null) {
                    task.progress = maxOf(task.progress ?: 0.0, stagedProgress)
                }
                task.message = buildDownloadStageMessage(
                    mediaKind = mediaKind,
                    formatId = formatId,
                    fragmentIndex = fragmentIndex,
                    fragmentCount = fragmentCount,
                )
                emitTaskEvent(
                    taskId = task.taskId,
                    type = "task_progress",
                    progress = task.progress,
                    downloadedBytes = task.downloadedBytes,
                    totalBytes = task.totalBytes,
                    speedText = task.speedText,
                    etaText = task.etaText,
                    outputPath = task.outputPath,
                    producedPaths = snapshotProducedPaths(task),
                    message = task.message,
                )
            }
            "finished" -> {
                if (stagedProgress != null) {
                    task.progress = maxOf(task.progress ?: 0.0, stagedProgress)
                }
                task.message = "${downloadKindLabel(mediaKind)}下载完成，准备下一阶段"
                emitTaskEvent(
                    taskId = task.taskId,
                    type = "task_step",
                    progress = task.progress,
                    downloadedBytes = task.downloadedBytes,
                    totalBytes = task.totalBytes,
                    speedText = task.speedText,
                    etaText = task.etaText,
                    outputPath = task.outputPath,
                    producedPaths = snapshotProducedPaths(task),
                    message = task.message,
                )
            }
        }
    }

    private fun mapMediaDownloadProgress(overallProgress: Double): Double {
        return (overallProgress.coerceIn(0.0, 1.0) * 0.90).coerceIn(0.0, 0.90)
    }

    private fun downloadKindLabel(mediaKind: String): String {
        return when (mediaKind) {
            "video" -> "视频轨道"
            "audio" -> "音频轨道"
            else -> "媒体文件"
        }
    }

    private fun buildDownloadStageMessage(
        mediaKind: String,
        formatId: String?,
        fragmentIndex: Int?,
        fragmentCount: Int?,
    ): String {
        val details = mutableListOf<String>()
        if (!formatId.isNullOrBlank()) {
            details.add("格式 $formatId")
        }
        if (fragmentIndex != null && fragmentCount != null && fragmentCount > 0) {
            details.add("分片 $fragmentIndex/$fragmentCount")
        }
        val suffix = if (details.isEmpty()) "" else " · ${details.joinToString(" · ")}"
        return "正在下载${downloadKindLabel(mediaKind)}$suffix"
    }

    private fun buildPostProcessorMessage(postprocessor: String?, status: String): String {
        val action = when {
            postprocessor?.contains("merger", ignoreCase = true) == true -> "合并音视频"
            postprocessor?.contains("thumbnail", ignoreCase = true) == true -> "处理封面"
            postprocessor?.contains("metadata", ignoreCase = true) == true -> "写入媒体信息"
            postprocessor?.contains("subtitle", ignoreCase = true) == true -> "处理字幕"
            else -> "处理下载产物"
        }
        return if (status == "finished") "$action 已完成" else "正在$action"
    }

    private inner class PythonTaskCallback(
        private val task: RunningYtDlpTask,
    ) {
        @Suppress("unused")
        fun onOutputLine(line: String) {
            handleYoutubeDownloadOutput(task, line)
        }

        @Suppress("unused")
        fun onProgress(payload: String) {
            handlePythonProgress(task, payload)
        }

        @Suppress("unused")
        fun isCancelled(): Boolean {
            return task.terminationReason == "cancel" || task.terminationReason == "pause"
        }
    }

    private fun handleYoutubeDownloadOutput(task: RunningYtDlpTask, rawLine: String) {
        val line = rawLine.trim()
        if (line.isEmpty()) return
        appendTaskLog(task, line)

        val structuredPathEvent = extractStructuredOutputPath(line)
        if (structuredPathEvent != null) {
            val (phase, outputPath) = structuredPathEvent
            trackProducedPath(task, outputPath)
            if (phase == "before_dl") {
                task.status = "downloading"
                task.message = "开始下载媒体资源"
                emitTaskEvent(
                    taskId = task.taskId,
                    type = "task_progress",
                    progress = task.progress,
                    downloadedBytes = task.downloadedBytes,
                    totalBytes = task.totalBytes,
                    speedText = task.speedText,
                    etaText = task.etaText,
                    outputPath = task.outputPath,
                    producedPaths = snapshotProducedPaths(task),
                    message = task.message,
                )
            } else if (phase == "after_move") {
                task.message = "媒体文件已落盘，等待后续处理"
            }
            return
        }

        extractOutputPath(line)?.let { outputPath ->
            trackProducedPath(task, outputPath)
        }

        if (line.startsWith("ERROR:", ignoreCase = true)) {
            task.message = line.removePrefix("ERROR:").trim()
            task.errorCode = "YT_DLP_ERROR"
            return
        }

        val stepMessage = buildTaskStepMessage(line)
        if (stepMessage != null) {
            task.message = stepMessage
            emitTaskEvent(
                taskId = task.taskId,
                type = "task_step",
                progress = task.progress,
                downloadedBytes = task.downloadedBytes,
                totalBytes = task.totalBytes,
                speedText = task.speedText,
                etaText = task.etaText,
                outputPath = task.outputPath,
                producedPaths = snapshotProducedPaths(task),
                message = stepMessage,
            )
        }

        if (line.contains("[Merger]") ||
            line.contains("[ExtractAudio]") ||
            line.contains("Merging formats into") ||
            line.contains("Deleting original file") ||
            line.contains("Post-process", ignoreCase = true)
        ) {
            task.status = "post_processing"
            task.message = line
            emitTaskEvent(
                taskId = task.taskId,
                type = "task_post_processing",
                progress = task.progress,
                speedText = task.speedText,
                etaText = task.etaText,
                outputPath = task.outputPath,
                message = line,
            )
            return
        }

        if (line.startsWith("[download]")) {
            val progress = parseProgress(line)
            val speed = parseSpeed(line)
            val eta = parseEta(line)

            if (progress != null) {
                // Structured Python hooks provide track-aware progress. The
                // textual percentage resets for each stream and would make the
                // overall bar jump backwards or reach 100% before audio/merge.
                task.speedText = speed ?: task.speedText
                task.etaText = eta ?: task.etaText
            } else if (line.contains("has already been downloaded")) {
                task.progress = maxOf(task.progress ?: 0.0, 0.90)
                task.message = "文件已存在，标记为完成"
            }
        }
    }

    private fun buildTaskStepMessage(line: String): String? {
        val lower = line.lowercase()
        if (lower.contains("retrying fragment") ||
            (lower.contains("fragment") && lower.contains("retry"))
        ) {
            return "分片请求暂时失败，正在重试（最多 2 次）"
        }
        if (lower.contains("sleeping") || lower.contains("sleep interval")) {
            return "服务端要求暂时等待，yt-dlp 将自动继续"
        }
        if (lower.contains("timed out") || lower.contains("timeout")) {
            return "网络响应超时，等待 yt-dlp 重试"
        }
        if (line.startsWith("[download]")) {
            if (parseProgress(line) != null) {
                return null
            }
            if (line.contains("has already been downloaded")) {
                return "文件已存在，直接复用"
            }
            val fragmentCount = Regex(
                "Downloading\\s+(\\d+)\\s+fragments?",
                RegexOption.IGNORE_CASE,
            ).find(line)?.groupValues?.getOrNull(1)
            if (fragmentCount != null) {
                return "开始下载 $fragmentCount 个媒体分片"
            }
            if (line.contains("Destination:")) {
                return shortenTaskMessage(line)
            }
        }
        if (line.startsWith("[youtube", ignoreCase = true) ||
            line.startsWith("[info]", ignoreCase = true) ||
            line.contains("Extracting URL", ignoreCase = true) ||
            line.contains("Downloading webpage", ignoreCase = true) ||
            line.contains("Downloading player", ignoreCase = true) ||
            line.contains("Downloading m3u8", ignoreCase = true) ||
            line.contains("Downloading tv client config", ignoreCase = true) ||
            line.contains("Downloading ios player API JSON", ignoreCase = true) ||
            line.contains("Downloading android player API JSON", ignoreCase = true) ||
            line.contains("Downloading web player API JSON", ignoreCase = true) ||
            line.contains("Downloading initial data API JSON", ignoreCase = true) ||
            line.contains("Downloading subtitle", ignoreCase = true)
        ) {
            return shortenTaskMessage(line)
        }
        return null
    }

    private fun shortenTaskMessage(raw: String): String {
        var message = raw.replace(Regex("\\s+"), " ").trim()
        val quotedPathMatch = Regex("\"([^\"]+)\"").find(message)
        if (quotedPathMatch != null) {
            val fullPath = quotedPathMatch.groupValues.getOrNull(1)
            if (!fullPath.isNullOrBlank()) {
                message = message.replace(fullPath, File(fullPath).name)
            }
        }
        return if (message.length <= 96) {
            message
        } else {
            message.take(93) + "..."
        }
    }

    private fun emitTaskEvent(
        taskId: String,
        type: String,
        progress: Double? = null,
        downloadedBytes: Long? = null,
        totalBytes: Long? = null,
        speedText: String? = null,
        etaText: String? = null,
        outputPath: String? = null,
        producedPaths: List<String>? = null,
        errorCode: String? = null,
        message: String? = null,
    ) {
        val payload = mutableMapOf<String, Any?>(
            "taskId" to taskId,
            "type" to type,
            "progress" to progress,
            "downloadedBytes" to downloadedBytes,
            "totalBytes" to totalBytes,
            "speedText" to speedText,
            "etaText" to etaText,
            "outputPath" to outputPath,
            "producedPaths" to producedPaths,
            "errorCode" to errorCode,
            "message" to message,
        )
        runOnUiThread {
            ytDlpEventSink?.success(payload)
        }
    }

    private fun normalizeProducedPath(path: String?): String? {
        return path
            ?.trim()
            ?.trim('"')
            ?.takeIf { it.isNotEmpty() }
    }

    private fun isTransientArtifact(path: String): Boolean {
        val lowerPath = path.lowercase(Locale.ROOT)
        return lowerPath.endsWith(".part") ||
            lowerPath.endsWith(".ytdl") ||
            lowerPath.endsWith(".tmp") ||
            lowerPath.endsWith(".temp") ||
            lowerPath.endsWith(".frag")
    }

    private fun cleanupAndroidStagedArtifacts(task: RunningYtDlpTask) {
        val key = task.debugContext["androidTempArtifactKey"]?.toString()?.trim()
        if (key.isNullOrEmpty()) return
        val safeKey = key.replace(Regex("[^A-Za-z0-9_-]"), "_")
        val prefix = "ytdlp_${safeKey}_"
        val outputDirectory = File(task.outputDir)
        if (!outputDirectory.exists()) return
        outputDirectory.walkTopDown()
            .filter { it.isFile && it.name.startsWith(prefix) }
            .forEach { file -> runCatching { file.delete() } }
    }

    private fun trackProducedPath(task: RunningYtDlpTask, path: String?) {
        val normalized = normalizeProducedPath(path) ?: return
        task.outputPath = normalized
        if (!isTransientArtifact(normalized)) {
            task.producedPaths.add(normalized)
        }
    }

    private fun snapshotProducedPaths(task: RunningYtDlpTask): List<String> {
        val collected = LinkedHashSet<String>()
        synchronized(task.producedPaths) {
            collected.addAll(task.producedPaths)
        }
        normalizeProducedPath(task.outputPath)?.let {
            if (!isTransientArtifact(it)) {
                collected.add(it)
            }
        }

        val outputDirectory = File(task.outputDir)
        if (outputDirectory.exists()) {
            val templatePrefix = task.outputTemplate.substringBefore("%(", "")
            val hintedBaseName = normalizeProducedPath(task.outputPath)
                ?.let { File(it).nameWithoutExtension }
                ?.takeIf { it.isNotEmpty() }
            outputDirectory.listFiles()?.forEach { file ->
                if (!file.isFile) {
                    return@forEach
                }
                val filePath = file.absolutePath
                if (isTransientArtifact(filePath)) {
                    return@forEach
                }
                val fileName = file.name
                val fileBaseName = file.nameWithoutExtension
                val matchesPrefix = templatePrefix.isNotEmpty() && fileName.startsWith(templatePrefix)
                val matchesHint = hintedBaseName != null &&
                    (fileBaseName == hintedBaseName || fileName.startsWith("$hintedBaseName."))
                val isRecent = file.lastModified() >= task.startedAtMillis - 60_000L
                if (matchesPrefix || matchesHint || isRecent) {
                    collected.add(filePath)
                }
            }
        }
        return collected.toList()
    }

    private fun appendTaskLog(task: RunningYtDlpTask, line: String) {
        synchronized(task.logTail) {
            if (task.logTail.size >= 12) {
                task.logTail.removeFirst()
            }
            task.logTail.addLast(line)
        }
    }

    private fun buildTaskFailureMessage(task: RunningYtDlpTask, exitCode: Int?): String {
        val tail = synchronized(task.logTail) {
            task.logTail.joinToString("\n").trim()
        }
        val baseMessage = task.message?.takeIf { it.isNotBlank() }
        val tailMessage = tail.takeIf { it.isNotBlank() }
        val exitLabel = exitCode?.let { "退出码 $it" }
        return listOfNotNull(baseMessage, tailMessage, exitLabel)
            .joinToString("\n")
            .ifBlank { "下载失败" }
    }

    private fun RunningYtDlpTask.usesAndroidPostProcessMode(): Boolean {
        return debugContext["androidPostProcessMode"] == true
    }

    private fun extractOutputPath(line: String): String? {
        val markers = listOf(
            "Destination:",
            "Merging formats into",
            "[ExtractAudio] Destination:",
        )
        for (marker in markers) {
            if (!line.contains(marker)) continue
            return line.substringAfter(marker)
                .trim()
                .trim('"')
                .takeIf { it.isNotEmpty() }
        }
        return null
    }

    private fun extractStructuredOutputPath(line: String): Pair<String, String>? {
        val before = line.substringAfter(YTDLP_BEFORE_DL_MARKER, "").trim()
        if (before.isNotEmpty()) {
            return "before_dl" to before.trim('"')
        }
        val after = line.substringAfter(YTDLP_AFTER_MOVE_MARKER, "").trim()
        if (after.isNotEmpty()) {
            return "after_move" to after.trim('"')
        }
        return null
    }

    private fun parseProgress(line: String): Double? {
        val match = Regex("""(\d+(?:\.\d+)?)%""").find(line) ?: return null
        val value = match.groupValues.getOrNull(1)?.toDoubleOrNull() ?: return null
        return (value / 100.0).coerceIn(0.0, 1.0)
    }

    private fun parseSpeed(line: String): String? {
        val match = Regex("""\bat\s+(.+?)\s+ETA\b""").find(line)
        return match?.groupValues?.getOrNull(1)?.trim()
    }

    private fun parseEta(line: String): String? {
        val match = Regex("""\bETA\s+([0-9:]+)""").find(line)
        return match?.groupValues?.getOrNull(1)?.trim()
    }

    private fun encodeDynamicJson(value: Any?): String? {
        if (value == null) return null
        return when (value) {
            is Map<*, *> -> JSONObject(value).toString()
            is List<*> -> JSONArray(value).toString()
            else -> JSONObject.wrap(value)?.toString()
        }
    }

    private fun decodeJsonObject(raw: String): Map<String, Any?>? {
        return try {
            jsonObjectToMap(JSONObject(raw))
        } catch (_: Exception) {
            null
        }
    }

    private fun jsonObjectToMap(jsonObject: JSONObject): Map<String, Any?> {
        val result = mutableMapOf<String, Any?>()
        val keys = jsonObject.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            result[key] = unwrapJsonValue(jsonObject.opt(key))
        }
        return result
    }

    private fun jsonArrayToList(jsonArray: JSONArray): List<Any?> {
        val result = mutableListOf<Any?>()
        for (index in 0 until jsonArray.length()) {
            result.add(unwrapJsonValue(jsonArray.opt(index)))
        }
        return result
    }

    private fun unwrapJsonValue(value: Any?): Any? {
        return when (value) {
            null, JSONObject.NULL -> null
            is JSONObject -> jsonObjectToMap(value)
            is JSONArray -> jsonArrayToList(value)
            else -> value
        }
    }

    private data class RunningYtDlpTask(
        val taskId: String,
        val outputDir: String,
        val outputTemplate: String,
        val sourceUrl: String,
        val requestPayload: Map<String, Any?>,
        val debugContext: Map<String, Any?> = emptyMap(),
        val startedAtMillis: Long = System.currentTimeMillis(),
        val producedPaths: MutableSet<String> = Collections.synchronizedSet(LinkedHashSet()),
        @Volatile var process: Process? = null,
        @Volatile var status: String = "queued",
        @Volatile var progress: Double? = null,
        @Volatile var downloadedBytes: Long? = null,
        @Volatile var totalBytes: Long? = null,
        @Volatile var speedText: String? = null,
        @Volatile var etaText: String? = null,
        @Volatile var outputPath: String? = null,
        @Volatile var errorCode: String? = null,
        @Volatile var message: String? = null,
        @Volatile var terminationReason: String? = null,
        val logTail: ArrayDeque<String> = ArrayDeque(),
    )

}
