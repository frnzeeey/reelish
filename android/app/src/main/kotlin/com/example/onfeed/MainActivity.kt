package com.example.onfeed

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.os.Build
import android.app.PictureInPictureParams
import android.util.Rational
import android.view.WindowManager
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageInfo
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
                "canRequestPackageInstalls" -> result.success(canInstallPackages())
                "openInstallPermissionSettings" -> {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    val settingsIntent = Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:$packageName")
                    )
                    result.success(
                        try {
                            startActivity(settingsIntent)
                            true
                        } catch (_: ActivityNotFoundException) {
                            false
                        }
                    )
                }
                "inspectApk" -> {
                    val apk = downloadedUpdateApk(call.argument<String>("path"))
                    if (apk == null) {
                        result.error("missing_apk", "The downloaded update was not found.", null)
                        return@setMethodCallHandler
                    }
                    @Suppress("DEPRECATION")
                    val archive = packageManager.getPackageArchiveInfo(apk.path, 0)
                    if (archive == null) {
                        apk.delete()
                        result.error("invalid_apk", "The downloaded update is not a valid APK.", null)
                        return@setMethodCallHandler
                    }
                    @Suppress("DEPRECATION")
                    val installed = packageManager.getPackageInfo(packageName, 0)
                    result.success(
                        mapOf(
                            "packageName" to archive.packageName,
                            "versionName" to archive.versionName,
                            "versionCode" to versionCodeOf(archive),
                            "installedPackageName" to packageName,
                            "installedVersionCode" to versionCodeOf(installed),
                        )
                    )
                }
                "installApk" -> {
                    val apk = downloadedUpdateApk(call.argument<String>("path"))
                    if (apk == null) {
                        result.error("missing_apk", "The downloaded update was not found.", null)
                        return@setMethodCallHandler
                    }
                    if (!canInstallPackages()) {
                        result.error(
                            "permission_required",
                            "Allow Reelish to install unknown apps, then try again.",
                            null
                        )
                        return@setMethodCallHandler
                    }
                    try {
                        // content:// URI from FileProvider; file:// URIs are rejected on Android 7+.
                        val apkUri = FileProvider.getUriForFile(this, "$packageName.fileprovider", apk)
                        val installIntent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(apkUri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivity(installIntent)
                        result.success("installer_opened")
                    } catch (_: ActivityNotFoundException) {
                        result.error("installer_unavailable", "Android's package installer is not available.", null)
                    } catch (_: IllegalArgumentException) {
                        result.error("invalid_apk", "The downloaded update could not be opened.", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun canInstallPackages(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()

    /** Only APKs the updater downloaded into cache/updates may be inspected or installed. */
    private fun downloadedUpdateApk(path: String?): File? {
        if (path.isNullOrBlank()) return null
        val updatesDir = File(cacheDir, "updates").canonicalFile
        val apk = File(path).canonicalFile
        return if (apk.parentFile == updatesDir && apk.isFile && apk.name.endsWith(".apk")) apk else null
    }

    private fun versionCodeOf(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
}
