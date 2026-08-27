package com.example.video_player_app

import android.app.Service
import android.content.Intent
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Process
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import kotlin.concurrent.thread

/**
 * Runs the blocking yt-dlp Python download outside the Flutter process.
 *
 * A pause first exposes a cooperative cancellation token. If Python is stuck
 * in network/native code, the dedicated process is killed after 150 ms. The
 * stable output template and .part files live outside this process, so the next
 * worker can continue the same download.
 */
class YtDlpWorkerService : Service() {
    companion object {
        const val ACTION_START = "com.example.video_player_app.ytdlp.START"
        const val ACTION_PAUSE = "com.example.video_player_app.ytdlp.PAUSE"
        const val ACTION_CANCEL = "com.example.video_player_app.ytdlp.CANCEL"
        const val ACTION_OUTPUT = "com.example.video_player_app.ytdlp.OUTPUT"
        const val ACTION_PROGRESS = "com.example.video_player_app.ytdlp.PROGRESS"
        const val ACTION_RESULT = "com.example.video_player_app.ytdlp.RESULT"
        const val ACTION_ERROR = "com.example.video_player_app.ytdlp.ERROR"
        const val ACTION_PAUSED = "com.example.video_player_app.ytdlp.PAUSED"
        const val ACTION_CANCELLED = "com.example.video_player_app.ytdlp.CANCELLED"

        const val EXTRA_TASK_ID = "taskId"
        const val EXTRA_REQUEST_JSON = "requestJson"
        const val EXTRA_PAYLOAD = "payload"
        const val EXTRA_MESSAGE = "message"
    }

    @Volatile private var activeTaskId: String? = null
    @Volatile private var cancellationReason: String? = null
    @Volatile private var workerRunning = false
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val taskId = intent?.getStringExtra(EXTRA_TASK_ID)?.trim().orEmpty()
        when (intent?.action) {
            ACTION_START -> {
                val requestJson = intent.getStringExtra(EXTRA_REQUEST_JSON).orEmpty()
                if (taskId.isNotEmpty() && requestJson.isNotEmpty()) {
                    startDownload(taskId, requestJson, startId)
                }
            }
            ACTION_PAUSE -> requestStop(taskId, "pause", ACTION_PAUSED)
            ACTION_CANCEL -> requestStop(taskId, "cancel", ACTION_CANCELLED)
        }
        return START_NOT_STICKY
    }

    private fun startDownload(taskId: String, requestJson: String, startId: Int) {
        if (workerRunning) {
            sendEvent(ACTION_ERROR, taskId, EXTRA_MESSAGE, "yt-dlp worker is busy")
            return
        }
        activeTaskId = taskId
        cancellationReason = null
        workerRunning = true
        thread(name = "yt-dlp-worker-$taskId", isDaemon = true) {
            try {
                if (!Python.isStarted()) {
                    Python.start(AndroidPlatform(applicationContext))
                }
                val output = Python.getInstance()
                    .getModule("yt_dlp_bridge")
                    .callAttr("download", requestJson, WorkerCallback(taskId))
                    ?.toJava(String::class.java)
                if (cancellationReason == null) {
                    sendEvent(ACTION_RESULT, taskId, EXTRA_PAYLOAD, output.orEmpty())
                }
            } catch (error: Throwable) {
                if (cancellationReason == null) {
                    sendEvent(
                        ACTION_ERROR,
                        taskId,
                        EXTRA_MESSAGE,
                        error.message ?: error.javaClass.simpleName,
                    )
                }
            } finally {
                workerRunning = false
                activeTaskId = null
                stopSelfResult(startId)
            }
        }
    }

    private fun requestStop(taskId: String, reason: String, eventAction: String) {
        if (taskId.isEmpty() || activeTaskId != taskId) return
        if (cancellationReason != null) return
        cancellationReason = reason
        sendEvent(eventAction, taskId)
        mainHandler.postDelayed({
            if (workerRunning && activeTaskId == taskId && cancellationReason == reason) {
                Process.killProcess(Process.myPid())
            }
        }, 150L)
    }

    private fun sendEvent(
        action: String,
        taskId: String,
        valueKey: String? = null,
        value: String? = null,
    ) {
        val intent = Intent(action)
            .setPackage(packageName)
            .putExtra(EXTRA_TASK_ID, taskId)
        if (valueKey != null) intent.putExtra(valueKey, value)
        sendBroadcast(intent)
    }

    inner class WorkerCallback(private val taskId: String) {
        @Suppress("unused")
        fun onOutputLine(line: String) {
            if (cancellationReason == null) {
                sendEvent(ACTION_OUTPUT, taskId, EXTRA_PAYLOAD, line)
            }
        }

        @Suppress("unused")
        fun onProgress(payload: String) {
            if (cancellationReason == null) {
                sendEvent(ACTION_PROGRESS, taskId, EXTRA_PAYLOAD, payload)
            }
        }

        @Suppress("unused")
        fun isCancelled(): Boolean = cancellationReason != null
    }
}
