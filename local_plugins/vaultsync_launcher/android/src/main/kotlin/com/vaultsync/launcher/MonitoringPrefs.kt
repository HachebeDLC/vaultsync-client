package com.vaultsync.launcher

import android.content.Context

/**
 * Native (non-Flutter) persistence for "sync on game exit" monitoring state.
 *
 * Deliberately its own SharedPreferences file, separate from Flutter's
 * `shared_preferences` plugin storage: this data must be readable with no
 * Dart engine involved at all, e.g. from a `BOOT_COMPLETED` receiver or a
 * `SyncForegroundService` restarted by the system via `START_STICKY` after
 * being killed — both of which can and do run before any Flutter engine
 * exists in the process.
 */
object MonitoringPrefs {
    private const val PREFS_NAME = "vaultsync_monitoring_prefs"
    private const val KEY_ENABLED = "monitoring_enabled"
    private const val KEY_PACKAGES = "monitored_packages"
    private const val KEY_CHECKPOINT_MS = "native_exit_checkpoint_ms"

    /** Mirrors BackgroundSyncService's Dart-side default lookback. */
    const val DEFAULT_LOOKBACK_MS = 15L * 60L * 1000L

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun isEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_ENABLED, false)

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_ENABLED, enabled).apply()
    }

    fun getPackages(context: Context): List<String> =
        prefs(context).getStringSet(KEY_PACKAGES, emptySet())?.toList() ?: emptyList()

    fun setPackages(context: Context, packages: List<String>) {
        // getStringSet's contract requires a fresh mutable set — mutating a
        // returned set is not allowed, so build a new one here.
        prefs(context).edit().putStringSet(KEY_PACKAGES, HashSet(packages)).apply()
    }

    /** Returns the persisted checkpoint, or `now - DEFAULT_LOOKBACK_MS` if none exists yet. */
    fun getCheckpointMs(context: Context): Long {
        val stored = prefs(context).getLong(KEY_CHECKPOINT_MS, -1L)
        return if (stored >= 0L) stored else System.currentTimeMillis() - DEFAULT_LOOKBACK_MS
    }

    fun setCheckpointMs(context: Context, value: Long) {
        prefs(context).edit().putLong(KEY_CHECKPOINT_MS, value).apply()
    }
}
