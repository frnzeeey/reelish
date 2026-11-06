package com.example.onfeed

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.annotation.Keep
import com.google.firebase.crashlytics.CustomKeysAndValues
import com.google.firebase.crashlytics.FirebaseCrashlytics
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Firebase Crashlytics for the Dart CrashReporter (lib/src/diagnostics/).
 *
 * The SDK is used directly for the same reason as AnalyticsChannel: FlutterFire
 * would build firebase_core into Windows too. The manifest keeps collection
 * off; it turns on only after the viewer agreed.
 */
class CrashReportChannel(private val context: Context) {
    companion object {
        const val NAME = "onfeed/crash_reports"

        /** The key Crashlytics reads to match Dart addresses to symbols. */
        private const val BUILD_ID_KEY = "com.crashlytics.flutter.build-id.0"
    }

    private var crashlytics: FirebaseCrashlytics? = null

    private val preferences
        get() = context.getSharedPreferences("onfeed_crash_reports", Context.MODE_PRIVATE)

    /** Whether collection was on when the app last ran. */
    private var wasEnabled: Boolean
        get() = preferences.getBoolean("enabled", false)
        set(value) = preferences.edit().putBoolean("enabled", value).apply()

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "isConfigured" -> result.success(FirebaseStarter.configured)
                    "configure" -> {
                        val enabled = call.argument<Boolean>("enabled") == true
                        result.success(configure(enabled))
                    }
                    "setKey" -> {
                        val key = call.argument<String>("key")
                        if (key != null) {
                            crashlytics?.setCustomKey(key, call.argument<String>("value") ?: "")
                        }
                        result.success(null)
                    }
                    "log" -> {
                        call.argument<String>("message")?.let { crashlytics?.log(it) }
                        result.success(null)
                    }
                    "record" -> {
                        record(call.arguments as? Map<*, *>)
                        result.success(null)
                    }
                    "testCrash" -> {
                        result.success(null)
                        // False unless the build set REELISH_CRASH_TEST.
                        if (BuildConfig.CRASH_TEST) {
                            Handler(Looper.getMainLooper()).post {
                                throw RuntimeException("Reelish test crash")
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                // Reporting must never break the app.
                result.success(null)
            }
        }
    }

    private fun configure(enabled: Boolean): Boolean {
        if (!FirebaseStarter.configured) return false
        // Refused and never on: Firebase is not started for this.
        if (!enabled && !wasEnabled && crashlytics == null) return true
        FirebaseStarter.start(context)
        val instance = FirebaseCrashlytics.getInstance().also { crashlytics = it }
        if (enabled) {
            // Anything stored while it was off stays unsent.
            if (!wasEnabled) instance.deleteUnsentReports()
            instance.setCrashlyticsCollectionEnabled(true)
        } else {
            instance.setCrashlyticsCollectionEnabled(false)
            instance.deleteUnsentReports()
        }
        wasEnabled = enabled
        return true
    }

    private fun record(report: Map<*, *>?) {
        val instance = crashlytics ?: return
        if (report == null) return
        val keys = CustomKeysAndValues.Builder()
            .putString("error_severity", report["severity"] as? String ?: "")
            .putString("error_category", report["category"] as? String ?: "")
        (report["buildId"] as? String)?.let { keys.putString(BUILD_ID_KEY, it) }
        // Addresses for `flutter symbolize`; release frames carry no names.
        (report["raw"] as? String)?.takeIf { it.isNotEmpty() }?.let { instance.log(it) }
        instance.recordException(dartError(report), keys.build())
    }

    private fun dartError(report: Map<*, *>): DartError {
        val error = DartError(report["type"] as? String ?: "Error", report["message"] as? String ?: "")
        error.stackTrace = (report["frames"] as? List<*>).orEmpty().mapNotNull { item ->
            val frame = item as? Map<*, *> ?: return@mapNotNull null
            StackTraceElement(
                frame["owner"] as? String ?: "dart",
                frame["method"] as? String ?: "?",
                frame["file"] as? String,
                (frame["line"] as? Number)?.toInt() ?: 0,
            )
        }.toTypedArray()
        return error
    }
}

/** A Dart error. Kept by name so reports do not show R8's renamed class. */
@Keep
class DartError(type: String, message: String) :
    Exception(if (message.isEmpty()) type else "$type: $message")
