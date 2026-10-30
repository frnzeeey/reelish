package com.example.onfeed

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.os.Build
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
import android.graphics.drawable.Icon
import androidx.annotation.RequiresApi
import android.app.UiModeManager
import android.content.res.Configuration
import android.util.Rational
import android.view.WindowManager
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.net.Uri
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import java.security.MessageDigest

/**
 * The app's only activity. Launcher entries are activity aliases of it
 * (AndroidManifest.xml): `.MainActivity` for the default icon, which keeps
 * the component name every earlier release used, and one per icon preset.
 */
class ReelishActivity : FlutterActivity() {
    private val channelName = "onfeed/player"
    private val updateChannelName = "onfeed/app_update"
    private val deviceChannelName = "onfeed/device"
    private var originalBrightness: Float? = null

    /** The player channel, also used to tell the player about picture in picture. */
    private var playerChannel: MethodChannel? = null

    /**
     * What the player last reported: whether leaving the app should continue the
     * video in picture in picture, whether it is playing (for the window's
     * play/pause button) and its shape.
     */
    private var pipAutoEnter = false
    private var pipPlaying = false
    private var pipRatio = Rational(16, 9)

    /** The picture-in-picture play/pause button; only this app can send it. */
    private val pipActionName = "io.github.frnzeeey.reelish.PIP_TOGGLE_PLAY"
    private var pipReceiver: BroadcastReceiver? = null

    private fun supportsPip(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    @RequiresApi(Build.VERSION_CODES.O)
    private fun pipParams(): PictureInPictureParams {
        val intent = Intent(pipActionName).setPackage(packageName)
        val pending = PendingIntent.getBroadcast(
            this,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val action = RemoteAction(
            Icon.createWithResource(
                this,
                if (pipPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
            ),
            if (pipPlaying) "Pause" else "Play",
            if (pipPlaying) "Pause" else "Play",
            pending,
        )
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(pipRatio)
            .setActions(listOf(action))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(pipAutoEnter).setSeamlessResizeEnabled(true)
        }
        return builder.build()
    }

    /** Keeps the system's picture-in-picture settings in step with the player. */
    private fun updatePipParams() {
        if (!supportsPip() || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            setPictureInPictureParams(pipParams())
        } catch (_: IllegalStateException) {
            // Not available in this window state; the next update applies.
        } catch (_: IllegalArgumentException) {
        }
    }

    private fun ratioFor(value: Double?): Rational {
        val ratio = (value ?: 16.0 / 9.0).let { if (it.isFinite() && it > 0) it else 16.0 / 9.0 }
            .coerceIn(0.42, 2.39)
        return Rational((ratio * 1000).toInt().coerceAtLeast(420), 1000)
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Android 12+ enters on its own (setAutoEnterEnabled). Earlier
        // versions are asked when the viewer leaves (Home, Recents).
        if (pipAutoEnter && supportsPip() && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            try {
                enterPictureInPictureMode(pipParams())
            } catch (_: IllegalStateException) {
            }
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        playerChannel?.invokeMethod("pipChanged", isInPictureInPictureMode)
    }

    override fun onStop() {
        super.onStop()
        // A new launcher icon replaces the old one only once the app is in
        // the background: disabling the entry the app was launched from
        // closes its window (see AppIconSwitcher).
        try {
            AppIconSwitcher(applicationContext).applyPending()
        } catch (_: Exception) {
            // Retried the next time the app leaves the foreground.
        }
    }

    override fun onDestroy() {
        pipReceiver?.let { unregisterReceiver(it) }
        pipReceiver = null
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (supportsPip() && pipReceiver == null) {
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    if (intent.action == pipActionName) playerChannel?.invokeMethod("pipTogglePlay", null)
                }
            }
            val filter = IntentFilter(pipActionName)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                registerReceiver(receiver, filter)
            }
            pipReceiver = receiver
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, deviceChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "capabilities" -> result.success(deviceCapabilities())
                else -> result.notImplemented()
            }
        }
        // Launcher icon presets (Settings → Appearance → App icon); phones
        // and tablets only: the TV launcher shows the banner instead.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "onfeed/app_icon").setMethodCallHandler { call, result ->
            val icons = AppIconSwitcher(applicationContext)
            try {
                when (call.method) {
                    "current" -> result.success(icons.current())
                    "select" -> {
                        val id = call.argument<String>("id")
                        if (id == null || id !in AppIconSwitcher.aliases) {
                            result.error("unknown_icon", "Unknown icon", null)
                        } else {
                            result.success(icons.select(id))
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("icon_failed", error.javaClass.simpleName, null)
            }
        }
        val player = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        playerChannel = player
        player.setMethodCallHandler { call, result ->
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
                "keepScreenOn" -> {
                    if (call.argument<Boolean>("value") == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                }
                "isEmulator" -> result.success(isEmulator())
                "enterPip" -> {
                    if (!supportsPip() || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                        result.success(false)
                    } else {
                        pipRatio = ratioFor(call.argument<Double>("ratio"))
                        result.success(
                            try {
                                enterPictureInPictureMode(pipParams())
                            } catch (_: IllegalStateException) {
                                false
                            }
                        )
                    }
                }
                "setPipState" -> {
                    // The player's state: playing (or paused) video it can
                    // continue in picture in picture, or nothing to continue.
                    pipAutoEnter = call.argument<Boolean>("autoEnter") == true
                    pipPlaying = call.argument<Boolean>("playing") == true
                    pipRatio = ratioFor(call.argument<Double>("ratio"))
                    updatePipParams()
                    result.success(null)
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
                    val archive = packageManager.getPackageArchiveInfo(apk.path, signingFlags())
                    if (archive == null) {
                        apk.delete()
                        result.error("invalid_apk", "The downloaded update is not a valid APK.", null)
                        return@setMethodCallHandler
                    }
                    @Suppress("DEPRECATION")
                    val installed = packageManager.getPackageInfo(packageName, signingFlags())
                    val archiveSigners = signerDigests(archive)
                    val installedSigners = signerDigests(installed)
                    result.success(
                        mapOf(
                            "packageName" to archive.packageName,
                            "versionName" to archive.versionName,
                            "versionCode" to versionCodeOf(archive),
                            "installedPackageName" to packageName,
                            "installedVersionCode" to versionCodeOf(installed),
                            // Null when either signer set is unknown.
                            "sameSigner" to if (archiveSigners.isNullOrEmpty() || installedSigners.isNullOrEmpty()) {
                                null
                            } else {
                                archiveSigners.any { it in installedSigners }
                            },
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

    /**
     * The same test media_kit uses (media_kit_video's Utils.isEmulator) to
     * switch libmpv to software decoding, so the app knows when libmpv's
     * OpenGL output would be used on an emulator.
     */
    private fun isEmulator(): Boolean = try {
        (Build.BRAND.startsWith("generic") && Build.DEVICE.startsWith("generic")) ||
            Build.FINGERPRINT.startsWith("generic") ||
            Build.FINGERPRINT.startsWith("unknown") ||
            Build.HARDWARE.contains("goldfish") ||
            Build.HARDWARE.contains("ranchu") ||
            Build.MODEL.contains("google_sdk") ||
            Build.MODEL.contains("Emulator") ||
            Build.MODEL.contains("Android SDK built for x86") ||
            Build.MANUFACTURER.contains("Genymotion") ||
            Build.PRODUCT.contains("sdk") ||
            Build.PRODUCT.contains("vbox86p") ||
            Build.PRODUCT.contains("emulator") ||
            Build.PRODUCT.contains("simulator")
    } catch (_: Throwable) {
        false
    }

    /**
     * What kind of device this is, read once at startup to choose between
     * the mobile and the TV interface. Television is decided by the UI mode
     * Android reports for TVs, or by the leanback feature every Android TV
     * and Google TV device declares; screen size is never used.
     */
    private fun deviceCapabilities(): Map<String, Any> {
        val uiMode = getSystemService(UiModeManager::class.java)
        val televisionMode = uiMode?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
        val leanback = packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
        return mapOf(
            "isTelevision" to (televisionMode || leanback),
            "hasLeanback" to leanback,
            "hasTouchscreen" to packageManager.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN),
            "supportsPictureInPicture" to (
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                    packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
                ),
        )
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

    @Suppress("DEPRECATION")
    private fun signingFlags(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }

    /**
     * SHA-256 digests of the certificates [info] is signed with, including
     * earlier keys in a rotation history, or null when they cannot be read.
     */
    private fun signerDigests(info: PackageInfo): Set<String>? {
        val signatures: Array<Signature>? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signing = info.signingInfo ?: return null
            if (signing.hasMultipleSigners()) signing.apkContentsSigners else signing.signingCertificateHistory
        } else {
            @Suppress("DEPRECATION")
            info.signatures
        }
        if (signatures.isNullOrEmpty()) return null
        val sha256 = MessageDigest.getInstance("SHA-256")
        return signatures.map { signature ->
            sha256.digest(signature.toByteArray()).joinToString("") { "%02x".format(it) }
        }.toSet()
    }

    private fun versionCodeOf(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
}
