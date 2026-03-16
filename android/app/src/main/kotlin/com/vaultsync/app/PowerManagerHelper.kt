package com.vaultsync.app

import android.content.Context
import android.net.wifi.WifiManager
import android.os.PowerManager
import android.util.Log

class PowerManagerHelper(private val context: Context) {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    fun acquirePowerLock() {
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
        if (wakeLock?.isHeld == true) {
            wakeLock?.release()
        }
        if (wifiLock?.isHeld == true) {
            wifiLock?.release()
        }
        Log.i("VaultSync", "🔋 POWER: Locks released")
    }
}
