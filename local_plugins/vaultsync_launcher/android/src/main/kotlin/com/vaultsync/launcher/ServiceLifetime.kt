package com.vaultsync.launcher

/**
 * Pure decision logic for [SyncForegroundService]'s lifetime, kept free of
 * Android imports so it can be unit tested without a device/emulator.
 *
 * The service must run iff `monitoringEnabled || syncCount > 0`:
 *  - `monitoringEnabled` is the persisted "Sync on Game Exit" toggle — the
 *    service hosts the exit-detection loop while it's on.
 *  - `syncCount` is [PowerLockCounter]'s ref count of in-flight syncs that
 *    called `acquirePowerLock()`.
 *
 * Wake lock + wifi lock are a separate concern, driven solely by `syncCount`
 * (monitoring alone must never hold them) — that part is unchanged from
 * before this class existed and is not modeled here; see
 * [PowerLockCounter]/[PowerManagerHelper].
 *
 * All mutating methods return a nullable Boolean describing what the caller
 * must do to the service as a *result of this call*:
 *  - `true`  -> the service was not running and must now be started
 *  - `false` -> the service was running and must now be stopped
 *  - `null`  -> no change; the caller must not touch the service
 *
 * Safe under concurrent access: every method is `@Synchronized` on this
 * instance's own monitor.
 */
class ServiceLifetime {
    @Volatile
    private var monitoringEnabled = false

    @Volatile
    private var syncCount = 0

    /** True iff the service should currently be running. */
    val shouldServiceRun: Boolean
        @Synchronized get() = monitoringEnabled || syncCount > 0

    val isMonitoringEnabled: Boolean
        @Synchronized get() = monitoringEnabled

    val currentSyncCount: Int
        @Synchronized get() = syncCount

    /**
     * Records that the monitoring toggle changed to [enabled].
     * Returns the service transition (start/stop/none) this causes.
     */
    @Synchronized
    fun setMonitoringEnabled(enabled: Boolean): Boolean? {
        if (monitoringEnabled == enabled) return null
        val wasRunning = shouldRun()
        monitoringEnabled = enabled
        return transition(wasRunning)
    }

    /**
     * Records the current value of the sync ref count (e.g. from
     * [PowerLockCounter.count] after an acquire/release). Returns the service
     * transition (start/stop/none) this causes.
     */
    @Synchronized
    fun onSyncCountChanged(newCount: Int): Boolean? {
        if (syncCount == newCount) return null
        val wasRunning = shouldRun()
        syncCount = newCount
        return transition(wasRunning)
    }

    private fun shouldRun(): Boolean = monitoringEnabled || syncCount > 0

    private fun transition(wasRunning: Boolean): Boolean? {
        val isRunning = shouldRun()
        return when {
            !wasRunning && isRunning -> true
            wasRunning && !isRunning -> false
            else -> null
        }
    }
}
