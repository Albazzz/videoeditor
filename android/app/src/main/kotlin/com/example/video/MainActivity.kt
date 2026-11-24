package com.example.video

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build

class MainActivity : FlutterActivity() {
    private var progressChannel: MethodChannel? = null
    private var openedSubtitles = false

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.getBooleanExtra("open_subtitles", false)) {
            progressChannel?.invokeMethod("open", null)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        openedSubtitles = intent?.getBooleanExtra("open_subtitles", false) ?: false
        progressChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vsub/subtitle_progress")
        SubtitleProgressService.bridge = progressChannel
        progressChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "opened" -> { result.success(openedSubtitles); openedSubtitles = false }
                "update" -> {
                    try {
                        val active = call.argument<Boolean>("active") ?: false
                        if (active && Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
                            !getPreferences(MODE_PRIVATE).getBoolean("asked_sub_notifications", false)) {
                            getPreferences(MODE_PRIVATE).edit().putBoolean("asked_sub_notifications", true).apply()
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4217)
                        }
                        val update = Intent(this, SubtitleProgressService::class.java)
                            .putExtra("completed", call.argument<Int>("completed") ?: 0)
                            .putExtra("total", call.argument<Int>("total") ?: 0)
                            .putExtra("progress", call.argument<Int>("progress") ?: 0)
                            .putExtra("active", active)
                        if (active) {
                            SubtitleProgressService.running = true
                            if (Build.VERSION.SDK_INT >= 26) startForegroundService(update) else startService(update)
                        } else if (SubtitleProgressService.running) {
                            startService(update)
                        } else {
                            SubtitleProgressService.showSummary(this, update)
                        }
                        result.success(null)
                    } catch (error: Exception) {
                        result.error("subtitle_progress", "Không hiển thị được thông báo Sub", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vsub/private_audio")
            .setMethodCallHandler { call, result ->
                if (call.method != "directory") {
                    result.notImplemented()
                } else {
                    try {
                        val directory = File(noBackupFilesDir, "retained_audio")
                        check(directory.isDirectory || directory.mkdirs())
                        directory.setReadable(false, false)
                        directory.setWritable(false, false)
                        directory.setExecutable(false, false)
                        check(directory.setReadable(true, true))
                        check(directory.setWritable(true, true))
                        check(directory.setExecutable(true, true))
                        result.success(directory.absolutePath)
                    } catch (error: Exception) {
                        result.error("private_audio", "Không mở được kho âm thanh riêng", null)
                    }
                }
            }
    }
}
