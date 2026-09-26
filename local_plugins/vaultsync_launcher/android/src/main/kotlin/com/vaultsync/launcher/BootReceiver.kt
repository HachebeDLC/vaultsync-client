package com.vaultsync.launcher

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Restarts the monitoring foreground service after a reboot or an app
 * update, iff "sync on game exit" was left enabled — read straight from the
 * native [MonitoringPrefs] file, with no Dart engine involved.
 *
 * Handles two actions:
 *  - `BOOT_COMPLETED`: `RECEIVE_BOOT_COMPLETED` is declared in the app
 *    manifest for other purposes; this receiver is declared alongside
 *    [SyncForegroundService] there.
 *  - `MY_PACKAGE_REPLACED`: sent to the app itself right after
 *    `adb install -r`/a Play Store update replaces it. Android kills the
 *    foreground service on update (see `dumpsys activity services` showing
 *    `Destroy ServiceRecord{... SyncForegroundService}`), and it otherwise
 *    stays down until the user manually reopens the app. This action is
 *    exempt from Android's implicit-broadcast manifest restrictions, so a
 *    plain manifest-declared receiver (no permission, no dynamic
 *    registration) is enough to catch it — no extra `uses-permission` is
 *    needed for it either.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (!shouldStartService(intent?.action)) return

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

    companion object {
        /**
         * Pure action-matching logic (a plain String comparison, no method
         * calls into the Android framework), so it's unit testable without
         * a device/emulator/Robolectric.
         */
        fun shouldStartService(action: String?): Boolean =
            action == Intent.ACTION_BOOT_COMPLETED || action == Intent.ACTION_MY_PACKAGE_REPLACED
    }
}
