package com.vaultsync.launcher

import android.app.Application
import android.content.Context
import android.os.Build
import java.io.File

/**
 * Guards against Flutter (and, transitively, WorkManager) ever initializing
 * in the `:monitor` process. `SyncForegroundService` and `BootReceiver` are
 * the only two components declared to run there (see AndroidManifest.xml);
 * nothing in either of them touches Flutter or WorkManager, and this object
 * is a defense-in-depth check for [VaultSyncLauncherPlugin] — the one place
 * a Flutter engine could ever attach — in case a future manifest change or
 * plugin registration accidentally did so in `:monitor` anyway.
 *
 * Split into a pure string check ([isMonitorProcessName], unit tested) and
 * an Android-dependent lookup ([currentProcessName], exercised only at
 * runtime) so the decision logic itself needs no device/emulator to verify.
 */
object ProcessGuard {
    /** Matches the `android:process=":monitor"` suffix declared in the manifest. */
    private const val MONITOR_PROCESS_SUFFIX = ":monitor"

    fun isMonitorProcessName(processName: String?): Boolean =
        processName != null && processName.endsWith(MONITOR_PROCESS_SUFFIX)

    /**
     * Best-effort current process name (e.g. "com.vaultsync.app" or
     * "com.vaultsync.app:monitor"). Uses the direct API on API 28+; falls
     * back to reading `/proc/self/cmdline` below that — no permission
     * required, and reliable on every API level this app supports (minSdk
     * 21).
     */
    fun currentProcessName(context: Context): String? {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                Application.getProcessName()
            } else {
                File("/proc/self/cmdline").readText()
                    .trim { it == '\u0000' || it.isWhitespace() }
            }
        } catch (e: Exception) {
            null
        }
    }
}
