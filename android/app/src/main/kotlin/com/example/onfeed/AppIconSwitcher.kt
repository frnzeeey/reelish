package com.example.onfeed

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager

/**
 * Switches the launcher icon between the activity aliases declared in
 * AndroidManifest.xml. The aliases' enabled states are the record of the
 * choice: they survive restarts, reboots and updates.
 *
 * Switching takes two steps. [select] enables the new entry at once.
 * Disabling the old ones waits for [applyPending], called when the app
 * leaves the foreground: Android closes a task whose launching component is
 * disabled, and the running app was launched from one of the old entries.
 * Until then the choice is kept as "pending" and [current] reports it.
 */
class AppIconSwitcher(private val context: Context) {
    companion object {
        /** The default icon: the component name every release before icon
         *  presets launched, so existing home-screen shortcuts keep working. */
        const val DEFAULT = "default"

        /** Preset ids and their alias class names (relative to the package). */
        val aliases = linkedMapOf(
            DEFAULT to ".MainActivity",
            "amber" to ".IconAmber",
            "blue" to ".IconBlue",
            "green" to ".IconGreen",
            "indigo" to ".IconIndigo",
            "lime" to ".IconLime",
            "orange" to ".IconOrange",
            "rose" to ".IconRose",
            "slate" to ".IconSlate",
            "teal" to ".IconTeal",
            "violet" to ".IconViolet",
        )

        private const val PREFS = "reelish_app_icon"
        private const val PENDING = "pending"
    }

    private val pm: PackageManager = context.packageManager
    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun component(alias: String) =
        ComponentName(context.packageName, "com.example.onfeed$alias")

    private fun isEnabled(id: String, alias: String): Boolean =
        when (pm.getComponentEnabledSetting(component(alias))) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED -> false
            // As declared in the manifest: only the default is enabled.
            else -> id == DEFAULT
        }

    private fun pending(): String? =
        prefs.getString(PENDING, null)?.takeIf { it in aliases && isEnabled(it, aliases[it]!!) }

    /** The chosen icon: a pending choice, else the one enabled entry, else
     *  the default. */
    fun current(): String {
        pending()?.let { return it }
        val enabled = aliases.filter { (id, alias) -> isEnabled(id, alias) }.keys
        return if (enabled.size == 1) enabled.first() else DEFAULT
    }

    /**
     * Chooses [id]: enables its launcher entry now (so the app always has
     * one) and leaves the others for [applyPending]. Returns the icon chosen
     * afterwards, read back from the system.
     */
    fun select(id: String): String {
        val target = aliases[id] ?: throw IllegalArgumentException("Unknown icon $id")
        pm.setComponentEnabledSetting(
            component(target),
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP,
        )
        if (!isEnabled(id, target)) return current()
        prefs.edit().putString(PENDING, id).commit()
        return current()
    }

    /** Disables every entry but the chosen one; safe to call at any time
     *  the app is not in the foreground. */
    fun applyPending() {
        val id = prefs.getString(PENDING, null) ?: return
        val target = aliases[id]
        if (target == null || !isEnabled(id, target)) {
            prefs.edit().remove(PENDING).apply()
            return
        }
        for ((otherId, alias) in aliases) {
            if (otherId == id) continue
            pm.setComponentEnabledSetting(
                component(alias),
                // Explicit, so the default's manifest "enabled" no longer applies.
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP,
            )
        }
        prefs.edit().remove(PENDING).apply()
    }
}
