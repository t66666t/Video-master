package com.example.video_player_app

import android.app.Activity
import android.content.ContentUris
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL = "com.example.video_player_app/file_manager"
    private val REQUEST_CODE_PICK_FILES = 4101
    private var pendingResult: MethodChannel.Result? = null

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
                    val mimeTypes = call.argument<List<String>>("mimeTypes") ?: listOf("video/*", "audio/*")
                    val allowMultiple = call.argument<Boolean>("allowMultiple") ?: true
                    openSystemFilePicker(mimeTypes, allowMultiple)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_CODE_PICK_FILES) return
        val result = pendingResult
        pendingResult = null
        if (result == null) return
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(emptyList<String>())
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
        val projection = arrayOf(MediaStore.MediaColumns.DATA)
        contentResolver.query(uri, projection, selection, selectionArgs, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATA)
                return cursor.getString(index)
            }
        }
        return null
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
}
