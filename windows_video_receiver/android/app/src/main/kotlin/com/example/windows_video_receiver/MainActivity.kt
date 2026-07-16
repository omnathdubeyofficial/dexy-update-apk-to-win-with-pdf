package com.example.windows_video_receiver

import android.content.res.AssetManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "com.dexy.receiver/assets"
        private const val BUFFER_SIZE = 8 * 1024 * 1024 // 8 MB chunks
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "copyAsset" -> {
                        val assetPath = call.argument<String>("assetPath")
                        val destPath  = call.argument<String>("destPath")
                        if (assetPath == null || destPath == null) {
                            result.error("INVALID_ARGS", "assetPath and destPath required", null)
                            return@setMethodCallHandler
                        }
                        // Run on a background thread to avoid blocking the main thread
                        Thread {
                            try {
                                copyAssetNative(assetPath, destPath)
                                result.success(destPath)
                            } catch (e: Exception) {
                                result.error("COPY_FAILED", e.message, null)
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Copies a Flutter asset to [destPath] using native Java I/O,
     * completely bypassing the Dart heap.  Safe for files > 2 GB.
     *
     * Flutter packages assets under "flutter_assets/" inside the APK's
     * assets directory, so we strip the leading "assets/" prefix if present
     * and look under "flutter_assets/…".
     */
    private fun copyAssetNative(flutterAssetKey: String, destPath: String) {
        val am: AssetManager = assets

        // Flutter stores assets as:  flutter_assets/<relative-path>
        // The Dart side passes the full key, e.g. "assets/video/foo.mp4"
        // so we convert it to "flutter_assets/video/foo.mp4"
        val nativeKey = if (flutterAssetKey.startsWith("assets/")) {
            "flutter_assets/" + flutterAssetKey.removePrefix("assets/")
        } else {
            "flutter_assets/$flutterAssetKey"
        }

        val inputStream: InputStream = am.open(nativeKey, AssetManager.ACCESS_STREAMING)
        val outFile = File(destPath)
        outFile.parentFile?.mkdirs()

        FileOutputStream(outFile).use { fos ->
            val buffer = ByteArray(BUFFER_SIZE)
            var bytesRead: Int
            while (inputStream.read(buffer).also { bytesRead = it } != -1) {
                fos.write(buffer, 0, bytesRead)
            }
            fos.flush()
        }
        inputStream.close()
    }
}
