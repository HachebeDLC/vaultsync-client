package com.vaultsync.launcher

import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Owns the process-wide sync ref count, the actual wake/wifi locks, and the
 * decision of whether [SyncForegroundService] should be running.
 *
 * This class — including its companion state — only ever runs in the
 * **main** process: it's constructed solely by [VaultSyncLauncherPlugin],
 * which only attaches there (see [ProcessGuard]). `SyncForegroundService`,
 * which since the `:monitor` process split is a separate OS process, does
 * NOT hold a `PowerManagerHelper` and never calls it — it does not need the
 * wake/wifi locks (those exist to keep the main process's CPU/network alive
 * while *it* performs sync I/O, which still all happens in the main
 * process), and the one piece of state it does need from here — whether a
 * sync is active, for its notification text and its sticky-restart check —
 * is mirrored into the cross-process [MonitoringPrefs] store below rather
 * than shared via this companion object.
 */
class PowerManagerHelper(private val context: Context) {
    companion object {
        private val lock = Any()
        private val sharedCounter = PowerLockCounter()
        private val serviceLifetime = ServiceLifetime()
        private var wakeLock: PowerManager.WakeLock? = null
        private var wifiLock: WifiManager.WifiLock? = null
        @Volatile private var monitoringRestored = false

        /**
         * The lifetime model is in memory, but the monitoring flag is
         * persisted. After the process dies and the system restarts the
         * service (START_STICKY), the in-memory flag starts out false, so the
         * first sync to finish would stop the service and silently end
         * monitoring. Seeds the model from [MonitoringPrefs] once per process.
         * Must be called while holding [lock].
         */
        private fun restoreMonitoringLocked(context: Context) {
            if (monitoringRestored) return
            serviceLifetime.setMonitoringEnabled(MonitoringPrefs.isEnabled(context))
            monitoringRestored = true
        }

        private fun startService(context: Context) {
            try {
                val serviceIntent = Intent(context, SyncForegroundService::class.java)
                ContextCompat.startForegroundService(context, serviceIntent)
                Log.i("VaultSync", "🛡️ SERVICE: Foreground Service Started")
            } catch (e: Exception) {
                Log.e("VaultSync", "🛡️ SERVICE: Failed to start Foreground Service: ${e.message}")
            }
        }

        private fun stopService(context: Context) {
            try {
                val serviceIntent = Intent(context, SyncForegroundService::class.java)
                context.stopService(serviceIntent)
                Log.i("VaultSync", "🛡️ SERVICE: Foreground Service Stopped")
            } catch (e: Exception) {
                Log.e("VaultSync", "🛡️ SERVICE: Failed to stop Foreground Service: ${e.message}")
            }
        }

        /**
         * Pokes the service (if it should currently be running) so it
         * recomputes its notification text — e.g. switching between
         * "Watching for game exits" and "Synchronization in progress" as
         * syncs start/stop while monitoring stays on. A no-op if the service
         * isn't supposed to be running at all.
         */
        private fun refreshServiceNotification(context: Context) {
            if (serviceLifetime.shouldServiceRun) {
                startService(context)
            }
        }

        /**
         * Persists [enabled], then starts/stops the foreground service
         * through the shared [ServiceLifetime] model. Never touches the
         * wake/wifi locks — those are governed solely by the sync ref count.
         */
        fun setMonitoringEnabled(context: Context, enabled: Boolean) {
            synchronized(lock) {
                restoreMonitoringLocked(context)
                MonitoringPrefs.setEnabled(context, enabled)
                when (serviceLifetime.setMonitoringEnabled(enabled)) {
                    true -> startService(context)
                    false -> stopService(context)
                    null -> refreshServiceNotification(context)
                }
            }
        }
    }

    // How many acquisitions THIS instance has contributed to the shared
    // counter. Used so a dying engine can release only what it owns without
    // touching another engine's (e.g. the WorkManager isolate's) count.
    private var ownedCount = 0

    fun acquirePowerLock() {
        synchronized(lock) {
            restoreMonitoringLocked(context)
            val shouldAcquireLocks = sharedCounter.acquire()
            ownedCount++
            val serviceTransition = serviceLifetime.onSyncCountChanged(sharedCounter.count)

            // SyncForegroundService now runs in :monitor, a separate
            // process from this one, so it can no longer read
            // sharedCounter directly to decide its notification text (or,
            // on a sticky restart, whether it has anything left to do).
            // Persist the fact a sync is active before poking the service,
            // so :monitor's next onStartCommand sees the up-to-date value.
            MonitoringPrefs.setSyncActive(context, sharedCounter.count > 0)

            when (serviceTransition) {
                true -> startService(context)
                false -> stopService(context) // unreachable on an acquire, kept for symmetry
                null -> refreshServiceNotification(context)
            }

            if (!shouldAcquireLocks) {
                Log.i("VaultSync", "🔋 POWER: Locks already held (refCount=${sharedCounter.count}), skipping acquire")
                return
            }

            if (wakeLock == null) {
                val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "VaultSync::GlobalLock")
            }
            if (wifiLock == null) {
                val wm = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "VaultSync::WifiLock")
            }

            if (wakeLock?.isHeld == false) {
                wakeLock?.acquire(30 * 60 * 1000L) // 30 min max
            }
            if (wifiLock?.isHeld == false) {
                wifiLock?.acquire()
            }
            Log.i("VaultSync", "🔋 POWER: Locks acquired (Wake + WiFi High-Perf)")
        }
    }

    fun releasePowerLock() {
        synchronized(lock) {
            restoreMonitoringLocked(context)
            if (ownedCount <= 0) {
                Log.i("VaultSync", "🔋 POWER: releasePowerLock called with no acquisitions owned by this instance, ignoring")
                return
            }

            val shouldReleaseLocks = sharedCounter.release()
            ownedCount--
            val serviceTransition = serviceLifetime.onSyncCountChanged(sharedCounter.count)

            // See the matching comment in acquirePowerLock(): keep the
            // cross-process syncActive flag in lockstep with the ref count
            // before poking (or not poking) the :monitor-hosted service.
            MonitoringPrefs.setSyncActive(context, sharedCounter.count > 0)

            if (shouldReleaseLocks) {
                if (wakeLock?.isHeld == true) {
                    wakeLock?.release()
                }
                if (wifiLock?.isHeld == true) {
                    wifiLock?.release()
                }
                Log.i("VaultSync", "🔋 POWER: Locks released")
            } else {
                Log.i("VaultSync", "🔋 POWER: Locks still held by other owners (refCount=${sharedCounter.count}), skipping release")
            }

            when (serviceTransition) {
                false -> stopService(context)
                true -> startService(context) // unreachable on a release, kept for symmetry
                null -> refreshServiceNotification(context)
            }
        }
    }

    /**
     * Releases every acquisition this instance still owns, without touching
     * the count contributed by other `PowerManagerHelper` instances (e.g. a
     * second plugin instance registered by the WorkManager background
     * isolate). Intended for use in `onDetachedFromEngine`, where the engine
     * going away must not tear down a transfer owned by a different engine.
     */
    fun releaseAllOwnedByThisInstance() {
        // The whole drain runs under `lock` so `ownedCount` is never read
        // outside the monitor; `releasePowerLock` re-entering it is fine.
        synchronized(lock) {
            while (ownedCount > 0) {
                releasePowerLock()
            }
        }
    }
}
