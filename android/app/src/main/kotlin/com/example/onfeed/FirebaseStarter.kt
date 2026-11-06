package com.example.onfeed

import android.content.Context
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions

/**
 * Starts Firebase from BuildConfig.FIREBASE_*, which come from the
 * REELISH_FIREBASE_* build settings. Used by AnalyticsChannel and
 * CrashReportChannel, each only after the viewer agreed to that feature.
 */
object FirebaseStarter {
    val configured: Boolean
        get() = BuildConfig.FIREBASE_APP_ID.isNotBlank() &&
            BuildConfig.FIREBASE_API_KEY.isNotBlank() &&
            BuildConfig.FIREBASE_PROJECT_ID.isNotBlank()

    fun start(context: Context) {
        if (FirebaseApp.getApps(context).isNotEmpty()) return
        val options = FirebaseOptions.Builder()
            .setApplicationId(BuildConfig.FIREBASE_APP_ID)
            .setApiKey(BuildConfig.FIREBASE_API_KEY)
            .setProjectId(BuildConfig.FIREBASE_PROJECT_ID)
            .apply {
                if (BuildConfig.FIREBASE_SENDER_ID.isNotBlank()) {
                    setGcmSenderId(BuildConfig.FIREBASE_SENDER_ID)
                }
            }
            .build()
        FirebaseApp.initializeApp(context, options)
    }
}
