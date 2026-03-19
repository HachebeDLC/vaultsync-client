package com.vaultsync.launcher

import android.app.AppOpsManager
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
    private val pollingExecutor = Executors.newSingleThreadScheduledExecutor()
    
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
        pollingExecutor.scheduleAtFixedRate(::checkAppClosure, 0, intervalMs, TimeUnit.MILLISECONDS)
    }

    fun stopMonitoring() {
        pollingExecutor.shutdown()
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
}
