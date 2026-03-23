package com.vaultsync.launcher

import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import android.util.Log
import androidx.core.content.ContextCompat

class PowerManagerHelper(private val context: Context) {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    fun acquirePowerLock() {
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

    fun releasePowerLock() {
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
