package com.vaultsync.launcher

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Restarts the monitoring foreground service after a reboot, iff "sync on
 * game exit" was left enabled — read straight from the native
 * [MonitoringPrefs] file, with no Dart engine involved. `RECEIVE_BOOT_COMPLETED`
 * is already declared in the app manifest for other purposes; this receiver
 * is declared alongside [SyncForegroundService] there.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != Intent.ACTION_BOOT_COMPLETED) return

        if (!MonitoringPrefs.isEnabled(context)) {
            Log.i("VaultSync", "🥾 BOOT: Monitoring not enabled, not starting service")
            return
        }

        Log.i("VaultSync", "🥾 BOOT: Monitoring enabled, starting SyncForegroundService")
        try {
            val serviceIntent = Intent(context, SyncForegroundService::class.java)
            ContextCompat.startForegroundService(context, serviceIntent)
        } catch (e: Exception) {
            Log.e("VaultSync", "🥾 BOOT: Failed to start SyncForegroundService: ${e.message}", e)
        }
    }
}
