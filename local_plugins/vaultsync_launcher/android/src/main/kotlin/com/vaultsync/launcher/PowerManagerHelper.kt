package com.vaultsync.launcher

import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import android.util.Log
import androidx.core.content.ContextCompat

class PowerManagerHelper(private val context: Context) {
    companion object {
        private val lock = Any()
        private val sharedCounter = PowerLockCounter()
        private var wakeLock: PowerManager.WakeLock? = null
        private var wifiLock: WifiManager.WifiLock? = null
    }

    // How many acquisitions THIS instance has contributed to the shared
    // counter. Used so a dying engine can release only what it owns without
    // touching another engine's (e.g. the WorkManager isolate's) count.
    private var ownedCount = 0

    fun acquirePowerLock() {
        synchronized(lock) {
            val shouldStart = sharedCounter.acquire()
            ownedCount++

            if (!shouldStart) {
                Log.i("VaultSync", "🔋 POWER: Locks already held (refCount=${sharedCounter.count}), skipping acquire")
                return
            }

            try {
                val serviceIntent = Intent(context, SyncForegroundService::class.java)
                ContextCompat.startForegroundService(context, serviceIntent)
                Log.i("VaultSync", "🛡️ SERVICE: Foreground Service Started")
            } catch (e: Exception) {
                Log.e("VaultSync", "🛡️ SERVICE: Failed to start Foreground Service: ${e.message}")
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
            if (ownedCount <= 0) {
                Log.i("VaultSync", "🔋 POWER: releasePowerLock called with no acquisitions owned by this instance, ignoring")
                return
            }

            val shouldStop = sharedCounter.release()
            ownedCount--

            if (!shouldStop) {
                Log.i("VaultSync", "🔋 POWER: Locks still held by other owners (refCount=${sharedCounter.count}), skipping release")
                return
            }

            try {
                val serviceIntent = Intent(context, SyncForegroundService::class.java)
                context.stopService(serviceIntent)
                Log.i("VaultSync", "🛡️ SERVICE: Foreground Service Stopped")
            } catch (e: Exception) {
                Log.e("VaultSync", "🛡️ SERVICE: Failed to stop Foreground Service: ${e.message}")
            }

            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
            if (wifiLock?.isHeld == true) {
                wifiLock?.release()
            }
            Log.i("VaultSync", "🔋 POWER: Locks released")
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
