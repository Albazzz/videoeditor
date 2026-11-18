package com.example.video

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
