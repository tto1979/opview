package com.tto1979.topview

import android.app.DownloadManager
import android.content.ContentValues
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.tto1979.topview/wake_lock"
    private val DOWNLOAD_CHANNEL = "com.tto1979.topview/download"
    private val DOWNLOAD_FOLDER = "topview"

    /**
     * TOP: puts a file the app downloaded (into its cache) into Download/topview, returns where it went.
     * The app downloads itself rather than through the system's download manager, which runs in another process
     * on its own network choice and stalled on the device's LAN address while the app reached it fine.
     */
    private fun saveToDownloads(file: File, name: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/$DOWNLOAD_FOLDER")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IOException("can't create $name in Downloads")
            try {
                val out = contentResolver.openOutputStream(uri) ?: throw IOException("can't write $name")
                out.use { o -> file.inputStream().use { it.copyTo(o) } }
            } catch (e: Exception) {
                contentResolver.delete(uri, null, null)
                throw e
            }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            // the name it got (a file with the same name already there: "name (1)")
            var saved = name
            contentResolver.query(uri, arrayOf(MediaStore.Downloads.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) saved = c.getString(0) ?: name
            }
            return "${Environment.DIRECTORY_DOWNLOADS}/$DOWNLOAD_FOLDER/$saved"
        }
        // before Android 10 the public Downloads folder needs a storage permission: the app's own
        val dir = File(getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: filesDir, DOWNLOAD_FOLDER)
        dir.mkdirs()
        val dest = File(dir, name)
        file.copyTo(dest, overwrite = true)
        return dest.absolutePath
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // TOP: drive downloads (lib/top/services/downloader.dart)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DOWNLOAD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "cacheDir" -> result.success(cacheDir.absolutePath)
                "saveToDownloads" -> {
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("name")
                    if (path == null || name == null) {
                        result.error("args", "path and name are required", null)
                    } else {
                        // copying tens of MB: not on the UI thread
                        Thread {
                            try {
                                val where = saveToDownloads(File(path), name)
                                runOnUiThread { result.success(where) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("save", e.message, null) }
                            }
                        }.start()
                    }
                }
                "openDownloads" -> {
                    try {
                        startActivity(Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("open", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "setKeepScreenOn") {
                val enabled = call.arguments as? Boolean ?: true
                if (enabled) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }
}
