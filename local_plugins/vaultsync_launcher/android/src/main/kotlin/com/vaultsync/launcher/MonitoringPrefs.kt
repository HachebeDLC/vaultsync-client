package com.vaultsync.launcher

import android.content.Context
import java.io.File

/**
 * Native (non-Flutter) persistence for "sync on game exit" monitoring state.
 *
 * Deliberately its own storage, separate from Flutter's `shared_preferences`
 * plugin storage: this data must be readable with no Dart engine involved at
 * all, e.g. from a `BOOT_COMPLETED` receiver or a `SyncForegroundService`
 * restarted by the system via `START_STICKY` after being killed — both of
 * which can and do run before any Flutter engine exists in the process.
 *
 * Backed by [MonitoringStateStore] (a small file under `filesDir`, not
 * SharedPreferences) rather than a static/cached object, because this state
 * is now genuinely cross-process: `enabled`/`packages` are written by the
 * main process (Dart settings, via VaultSyncLauncherPlugin) and read every
 * ~15s by `SyncForegroundService` running in the separate `:monitor`
 * process; `checkpointMs` is written and read only by `:monitor`;
 * `syncActive` is written by the main process (PowerManagerHelper, mirroring
 * its in-memory sync ref count) and read by `:monitor` to pick the right
 * foreground notification text. See MonitoringStateStore's doc for why a
 * plain file beats SharedPreferences here.
 */
object MonitoringPrefs {
    private const val STORE_FILE_NAME = "vaultsync_monitoring_state"

    /** Mirrors BackgroundSyncService's Dart-side default lookback. */
    const val DEFAULT_LOOKBACK_MS = 15L * 60L * 1000L

    // Where builds up to 71973ba kept this state. Without importing it, an
    // update would read "monitoring off" and neither boot nor
    // MY_PACKAGE_REPLACED would restart the service.
    private const val LEGACY_PREFS_NAME = "vaultsync_monitoring_prefs"

    private fun store(context: Context): MonitoringStateStore {
        val file = File(context.filesDir, STORE_FILE_NAME)
        val store = MonitoringStateStore(file)
        if (!file.exists()) importLegacyPrefs(context, store)
        return store
    }

    private fun importLegacyPrefs(context: Context, store: MonitoringStateStore) {
        val legacy = context.getSharedPreferences(LEGACY_PREFS_NAME, Context.MODE_PRIVATE)
        if (!legacy.contains("monitoring_enabled") && !legacy.contains("monitored_packages")) return
        val checkpoint = legacy.getLong("native_exit_checkpoint_ms", -1L)
        store.importIfAbsent(
            MonitoringStateStore.State(
                enabled = legacy.getBoolean("monitoring_enabled", false),
                packages = legacy.getStringSet("monitored_packages", emptySet())?.toList() ?: emptyList(),
                checkpointMs = if (checkpoint >= 0L) checkpoint else null
            )
        )
    }

    fun isEnabled(context: Context): Boolean =
        store(context).read().enabled

    fun setEnabled(context: Context, enabled: Boolean) {
        store(context).writeEnabled(enabled)
    }

    fun getPackages(context: Context): List<String> =
        store(context).read().packages

    fun setPackages(context: Context, packages: List<String>) {
        store(context).writePackages(packages)
    }

    /** Returns the persisted checkpoint, or `now - DEFAULT_LOOKBACK_MS` if none exists yet. */
    fun getCheckpointMs(context: Context): Long {
        val stored = store(context).read().checkpointMs
        return stored ?: (System.currentTimeMillis() - DEFAULT_LOOKBACK_MS)
    }

    fun setCheckpointMs(context: Context, value: Long) {
        store(context).writeCheckpointMs(value)
    }

    /**
     * Whether a sync is currently in flight, as last reported by
     * [PowerManagerHelper] in the main process. Read by
     * `SyncForegroundService` (in `:monitor`) to choose between the
     * "Synchronization in progress" and "Watching for game exits"
     * notification text — it cannot use `PowerManagerHelper`'s in-memory ref
     * count directly, since that companion state no longer lives in the
     * same process.
     */
    fun isSyncActive(context: Context): Boolean =
        store(context).read().syncActive

    fun setSyncActive(context: Context, active: Boolean) {
        store(context).writeSyncActive(active)
    }
}
