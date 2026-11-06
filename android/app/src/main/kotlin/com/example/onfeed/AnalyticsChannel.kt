package com.example.onfeed

import android.content.Context
import android.os.Bundle
import com.google.firebase.analytics.FirebaseAnalytics
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Firebase Analytics for the Dart AnalyticsService (lib/src/analytics/).
 *
 * Firebase starts only when the viewer has agreed and this build carries a
 * Firebase configuration (BuildConfig.FIREBASE_*, from the REELISH_FIREBASE_*
 * build settings). Without either, nothing is initialized and nothing is
 * sent. The manifest keeps collection off by default, and advertising ids
 * and personalization off always.
 */
class AnalyticsChannel(private val context: Context) {
    companion object {
        const val NAME = "onfeed/analytics"
    }

    private var analytics: FirebaseAnalytics? = null

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "isConfigured" -> result.success(FirebaseStarter.configured)
                    "configure" -> {
                        val enabled = call.argument<Boolean>("enabled") == true
                        val reset = call.argument<Boolean>("reset") == true
                        result.success(configure(enabled, reset))
                    }
                    "logEvent" -> {
                        val name = call.argument<String>("name")
                        if (name != null) {
                            analytics?.logEvent(name, bundleOf(call.argument("parameters")))
                        }
                        result.success(null)
                    }
                    "setUserProperty" -> {
                        val name = call.argument<String>("name")
                        if (name != null) analytics?.setUserProperty(name, call.argument("value"))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                // Analytics must never break the app.
                result.success(null)
            }
        }
    }

    private fun configure(enabled: Boolean, reset: Boolean): Boolean {
        if (!FirebaseStarter.configured) return false
        // Off and nothing to erase: Firebase is not started at all.
        if (!enabled && !reset && analytics == null) return true
        val instance = analytics ?: start()
        instance.setConsent(
            mapOf(
                FirebaseAnalytics.ConsentType.ANALYTICS_STORAGE to
                    if (enabled) FirebaseAnalytics.ConsentStatus.GRANTED else FirebaseAnalytics.ConsentStatus.DENIED,
                FirebaseAnalytics.ConsentType.AD_STORAGE to FirebaseAnalytics.ConsentStatus.DENIED,
                FirebaseAnalytics.ConsentType.AD_USER_DATA to FirebaseAnalytics.ConsentStatus.DENIED,
                FirebaseAnalytics.ConsentType.AD_PERSONALIZATION to FirebaseAnalytics.ConsentStatus.DENIED,
            )
        )
        instance.setAnalyticsCollectionEnabled(enabled)
        if (reset) instance.resetAnalyticsData()
        return true
    }

    private fun start(): FirebaseAnalytics {
        FirebaseStarter.start(context)
        return FirebaseAnalytics.getInstance(context).also { analytics = it }
    }

    /** Strings and numbers only, as Firebase accepts. */
    private fun bundleOf(parameters: Map<String, Any?>?): Bundle = Bundle().apply {
        parameters?.forEach { (key, value) ->
            when (value) {
                is String -> putString(key, value)
                is Int -> putLong(key, value.toLong())
                is Long -> putLong(key, value)
                is Double -> putDouble(key, value)
                is Boolean -> putLong(key, if (value) 1 else 0)
            }
        }
    }
}
