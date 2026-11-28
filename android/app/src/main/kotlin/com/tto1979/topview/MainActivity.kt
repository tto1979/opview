package com.tto1979.topview

import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.tto1979.topview/wake_lock"
    private val DOWNLOAD_CHANNEL = "com.tto1979.topview/download"

    private val downloads: DownloadManager
        get() = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager

    /** queues the download: its id, and the folder it goes to */
    private fun enqueueDownload(url: String, name: String): Map<String, Any> {
        val request = DownloadManager.Request(Uri.parse(url))
            .setTitle(name)
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
        val folder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            request.setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, "topview/$name")
            "${Environment.DIRECTORY_DOWNLOADS}/topview"
        } else {
            // the public Downloads folder needs a storage permission before Android 10: use the app's own
            request.setDestinationInExternalFilesDir(this, Environment.DIRECTORY_DOWNLOADS, name)
            "Android/data/$packageName/files/${Environment.DIRECTORY_DOWNLOADS}"
        }
        return mapOf("id" to downloads.enqueue(request), "folder" to folder)
    }

    /** a download's DownloadManager status and reason (HTTP status or ERROR_*), null once it's removed */
    private fun downloadStatus(id: Long): Map<String, Any>? =
        downloads.query(DownloadManager.Query().setFilterById(id)).use { c ->
            if (!c.moveToFirst()) {
                null
            } else {
                mapOf(
                    "status" to c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)),
                    "reason" to c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON)),
                )
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // TOP: drive downloads through the system download manager (notification, resumes, Downloads folder)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DOWNLOAD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> {
                    val id = call.argument<Number>("id")?.toLong()
                    result.success(if (id == null) null else downloadStatus(id))
                }
                "openDownloads" -> {
                    try {
                        startActivity(Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("open", e.message, null)
                    }
                }
                "download" -> {
                    val url = call.argument<String>("url")
                    val name = call.argument<String>("name")
                    if (url == null || name == null) {
                        result.error("args", "url and name are required", null)
                    } else {
                        try {
                            result.success(enqueueDownload(url, name))
                        } catch (e: Exception) {
                            result.error("download", e.message, null)
                        }
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
