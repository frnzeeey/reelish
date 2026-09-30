package com.example.onfeed

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.os.Build
import android.app.PictureInPictureParams
import android.util.Rational
import android.view.WindowManager
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "onfeed/player"
    private val updateChannelName = "onfeed/app_update"
    private var originalBrightness: Float? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "setBrightness" -> {
                    if (originalBrightness == null) originalBrightness = window.attributes.screenBrightness
                    val brightness = call.argument<Double>("value")?.toFloat()?.coerceIn(0.01f, 1f) ?: 1f
                    val attrs = window.attributes
                    attrs.screenBrightness = brightness
                    window.attributes = attrs
                    result.success(null)
                }
                "resetBrightness" -> {
                    originalBrightness?.let { value ->
                        val attrs = window.attributes
                        attrs.screenBrightness = value
                        window.attributes = attrs
                    }
                    originalBrightness = null
                    result.success(null)
                }
                "enterPip" -> {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                        result.success(false)
                    } else {
                        val ratio = (call.argument<Double>("ratio") ?: 16.0 / 9.0).coerceIn(0.42, 2.39)
                        val width = (ratio * 1000).toInt().coerceAtLeast(420)
                        val height = 1000
                        result.success(enterPictureInPictureMode(PictureInPictureParams.Builder()
                            .setAspectRatio(Rational(width, height)).build()))
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updateChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("invalid_apk", "APK path is missing.", null)
                        return@setMethodCallHandler
                    }
                    val apk = File(path)
                    if (!apk.isFile) {
                        result.error("missing_apk", "Downloaded APK was not found.", null)
                        return@setMethodCallHandler
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                        val settingsIntent = Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:$packageName")
                        )
                        startActivity(settingsIntent)
                        result.success("permission_required")
                        return@setMethodCallHandler
                    }
                    val apkUri = FileProvider.getUriForFile(
                        this,
                        "$packageName.fileprovider",
                        apk
                    )
                    val installIntent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(apkUri, "application/vnd.android.package-archive")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    startActivity(installIntent)
                    result.success("installer_opened")
                }
                else -> result.notImplemented()
            }
        }
    }
}
