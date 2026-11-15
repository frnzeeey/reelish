package com.example.onfeed

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Shares or saves a Reelish Wrapped card (lib/src/wrapped/wrapped_export.dart).
 *
 * Share writes the PNG to cache/shares (exposed only through the app's
 * FileProvider, see res/xml/update_file_paths.xml) and opens the system
 * chooser with a read grant for that one file. Save adds it to
 * Pictures/Reelish through MediaStore, which needs no permission on
 * Android 10 and later; older versions offer Share only.
 */
class ShareChannel(private val activity: Activity) {
    companion object {
        const val NAME = "onfeed/share"
        private const val MAX_BYTES = 20 * 1024 * 1024
        private val SAFE_NAME = Regex("^[A-Za-z0-9-]{1,80}$")
    }

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "canSave" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                    "shareImage" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        val name = call.argument<String>("name")
                        if (bytes == null || name == null || !valid(bytes, name)) {
                            result.success(false)
                        } else {
                            result.success(share(bytes, name, call.argument<String>("text")))
                        }
                    }
                    "saveImage" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        val name = call.argument<String>("name")
                        if (bytes == null || name == null || !valid(bytes, name)) {
                            result.success(false)
                        } else {
                            result.success(save(bytes, name))
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                result.success(false)
            }
        }
    }

    private fun valid(bytes: ByteArray, name: String) =
        bytes.isNotEmpty() && bytes.size <= MAX_BYTES && SAFE_NAME.matches(name)

    private fun share(bytes: ByteArray, name: String, text: String?): Boolean {
        val dir = File(activity.cacheDir, "shares").apply { mkdirs() }
        // One card at a time: older ones are not kept.
        dir.listFiles()?.forEach { it.delete() }
        val file = File(dir, "$name.png")
        file.writeBytes(bytes)
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.fileprovider", file)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "image/png"
            putExtra(Intent.EXTRA_STREAM, uri)
            if (!text.isNullOrBlank()) putExtra(Intent.EXTRA_TEXT, text.take(500))
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        activity.startActivity(Intent.createChooser(send, null))
        return true
    }

    private fun save(bytes: ByteArray, name: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        val resolver = activity.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "$name.png")
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/Reelish")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) ?: return false
        try {
            resolver.openOutputStream(uri)?.use { it.write(bytes) } ?: throw IllegalStateException()
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return true
        } catch (_: Exception) {
            resolver.delete(uri, null, null)
            return false
        }
    }
}
