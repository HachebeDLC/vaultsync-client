package com.vaultsync.launcher

import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.MethodChannel

import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class AutomationEngine(private val context: Context, private val channel: MethodChannel) {
    private var lastForegroundApp: String? = null
    private var monitoredPackages: List<String> = emptyList()
    private val automationHandler = Handler(Looper.getMainLooper())
    private var pollingExecutor = Executors.newSingleThreadScheduledExecutor()
    
    private fun checkAppClosure() {
        if (!hasUsageStatsPermission() || monitoredPackages.isEmpty()) return
        
        val usageStatsManager = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val time = System.currentTimeMillis()
        val stats = usageStatsManager.queryUsageStats(UsageStatsManager.INTERVAL_DAILY, time - 15000, time)
        
        val currentApp = stats?.filter { it.lastTimeUsed > time - 15000 }
            ?.maxByOrNull { it.lastTimeUsed }?.packageName
            
        if (currentApp != null && currentApp != lastForegroundApp) {
            if (monitoredPackages.contains(lastForegroundApp) && currentApp != context.packageName) {
                automationHandler.post { 
                    channel.invokeMethod("onEmulatorClosed", lastForegroundApp) 
                }
            }
            lastForegroundApp = currentApp
        }
    }

    fun startMonitoring(packages: List<String>, intervalMs: Long) {
        monitoredPackages = packages
        if (!pollingExecutor.isShutdown && !pollingExecutor.isTerminated) {
            pollingExecutor.shutdownNow()
        }
        if (pollingExecutor.isShutdown || pollingExecutor.isTerminated) {
            pollingExecutor = Executors.newSingleThreadScheduledExecutor()
        }
        pollingExecutor.scheduleAtFixedRate(::checkAppClosure, 0, intervalMs, TimeUnit.MILLISECONDS)
    }

    fun stopMonitoring() {
        if (!pollingExecutor.isShutdown) {
            pollingExecutor.shutdownNow()
        }
        monitoredPackages = emptyList()
        lastForegroundApp = null
    }

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
     * process was dead (e.g. killed by the low-memory killer while a game
     * was running), by replaying [UsageStatsManager.queryEvents] since
     * [sinceMs] instead of relying on the live polling loop in
     * [checkAppClosure].
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
