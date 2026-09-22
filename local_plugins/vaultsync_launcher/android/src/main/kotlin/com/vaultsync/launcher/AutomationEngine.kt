package com.vaultsync.launcher

import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.os.Build

/**
 * Usage-stats-based emulator exit detection.
 *
 * The live polling loop that used to live here (`checkAppClosure` /
 * `startMonitoring` / `stopMonitoring`, a `queryUsageStats` poll every N
 * seconds) has been replaced: exit detection while "sync on game exit" is
 * enabled now runs inside [SyncForegroundService] itself (so it survives the
 * owning Flutter engine going away), reusing [getEmulatorExitsSince] below on
 * a timer instead of a separate polling mechanism here. This class now only
 * exposes the stateless usage-stats queries the service, the plugin's method
 * channel, and Dart's catch-up path all rely on.
 */
class AutomationEngine(private val context: Context) {

    fun hasUsageStatsPermission(): Boolean {
        val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, android.os.Process.myUid(), context.packageName)
        } else {
            appOps.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, android.os.Process.myUid(), context.packageName)
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    fun getRecentlyClosedEmulator(emulatorPackages: List<String>): String? {
        if (!hasUsageStatsPermission()) return null
        val usageStatsManager = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val time = System.currentTimeMillis()
        val stats = usageStatsManager.queryUsageStats(UsageStatsManager.INTERVAL_DAILY, time - 300000, time)

        if (stats == null || stats.isEmpty()) return null
        return stats.filter { emulatorPackages.contains(it.packageName) }
            .maxByOrNull { it.lastTimeUsed }?.packageName
    }

    /**
     * Catches up on emulator exits that may have happened while the app
     * process (or the monitoring loop in [SyncForegroundService]) was dead
     * — e.g. killed by the low-memory killer while a game was running — by
     * replaying [UsageStatsManager.queryEvents] since [sinceMs].
     *
     * Only MOVE_TO_FOREGROUND / MOVE_TO_BACKGROUND are available since API 21
     * (minSdk here is 24) — deliberately not using the richer, API-29-only
     * event constants (e.g. ACTIVITY_RESUMED/ACTIVITY_PAUSED).
     *
     * Returns a list of `{"package": String, "closedAt": Long}` maps, one per
     * monitored package that exited in the window. Returns an empty list if
     * usage-stats permission is missing or no packages were given.
     */
    fun getEmulatorExitsSince(packages: List<String>, sinceMs: Long): List<Map<String, Any>> {
        if (!hasUsageStatsPermission() || packages.isEmpty()) return emptyList()

        val monitoredSet = packages.toSet()
        val usageStatsManager = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val now = System.currentTimeMillis()

        val events = ArrayList<UsageEvent>()
        val usageEvents = usageStatsManager.queryEvents(sinceMs, now)
        val event = UsageEvents.Event()
        while (usageEvents.hasNextEvent()) {
            usageEvents.getNextEvent(event)
            val packageName = event.packageName ?: continue
            if (packageName !in monitoredSet) continue
            val type = when (event.eventType) {
                UsageEvents.Event.MOVE_TO_FOREGROUND -> UsageEventType.FOREGROUND
                UsageEvents.Event.MOVE_TO_BACKGROUND -> UsageEventType.BACKGROUND
                else -> null
            } ?: continue
            events.add(UsageEvent(packageName, type, event.timeStamp))
        }

        return ExitDetector.findExits(events, monitoredSet)
            .map { (pkg, closedAt) -> mapOf("package" to pkg, "closedAt" to closedAt) }
    }
}
