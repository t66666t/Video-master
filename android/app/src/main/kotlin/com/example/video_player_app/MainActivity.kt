package com.example.video_player_app

import android.content.Intent
import android.net.Uri
import android.os.Environment
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL = "com.example.video_player_app/file_manager"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "openFileManager") {
                openFileManager()
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
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
}
