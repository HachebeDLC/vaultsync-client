package com.vaultsync.launcher

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * Low-importance foreground service that keeps VaultSync's exit-detection
 * loop alive while "sync on game exit" is enabled, and hosts the existing
 * "Synchronization in progress" notification while a sync is running.
 *
 * Declared with `android:process=":monitor"` in the manifest, so it runs in
 * its own lightweight process rather than the main one. The whole point:
 * the Flutter/Dart engine, which lives only in the main process, no longer
 * has to stay resident all day just to keep this 15s detection loop alive —
 * `:monitor` survives on its own, and the main process can die and be
 * restarted (rarely, on an actual exit) without affecting monitoring.
 *
 * Two consequences of running in a separate process, both handled
 * elsewhere:
 *  - `:monitor` must never touch WorkManager or the Flutter method channel
 *    directly (no multi-process WorkManager, and no engine here to own a
 *    channel). When [dispatchExit] detects an exit, it hands off to the main
 *    process via an explicit broadcast to [ExitDispatchReceiver], which does
 *    exactly what this class used to do itself before the split.
 *  - Whether a sync is active is decided in the main process by
 *    [PowerManagerHelper], whose in-memory ref count no longer lives in this
 *    process. That fact crosses the process boundary through the shared,
 *    file-backed [MonitoringPrefs] store (`isSyncActive`/`setSyncActive`)
 *    instead of any static/companion state.
 */
class SyncForegroundService : Service() {
    companion object {
        const val CHANNEL_ID = "vaultsync_background_channel"
        const val NOTIFICATION_ID = 4040
        private const val MONITOR_INTERVAL_MS = 15_000L
    }

    private lateinit var automationEngine: AutomationEngine
    private var monitorExecutor: ScheduledExecutorService? = null

    override fun onCreate() {
        super.onCreate()
        automationEngine = AutomationEngine(applicationContext)
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Always resync the notification with current global state: this
        // handles both a fresh start/refresh poke from PowerManagerHelper
        // (running in the main process) and a system-triggered START_STICKY
        // restart (intent == null) after this (:monitor) process was killed.
        updateNotification()

        if (MonitoringPrefs.isEnabled(applicationContext)) {
            startMonitoringLoopIfNeeded()
        } else {
            stopMonitoringLoop()
            // Nothing here tracks an in-memory sync ref count anymore (that
            // lives in the main process's PowerManagerHelper) — instead,
            // consult the same cross-process syncActive flag the
            // notification uses. If we were restarted with neither
            // monitoring enabled nor a sync actually in flight, there is no
            // reason left to be running — this is the only place that can
            // detect that case, since it's specific to a sticky restart.
            if (!MonitoringPrefs.isSyncActive(applicationContext)) {
                Log.i("VaultSync", "🛡️ SERVICE: Restarted with nothing to do (no monitoring, no sync) — stopping self")
                stopSelf()
            }
        }

        return START_STICKY
    }

    override fun onDestroy() {
        stopMonitoringLoop()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? {
        return null
    }

    // ---- Detection loop -----------------------------------------------

    private fun startMonitoringLoopIfNeeded() {
        if (monitorExecutor != null) return
        Log.i("VaultSync", "👁️ MONITOR: Starting in-service exit detection loop")
        monitorExecutor = Executors.newSingleThreadScheduledExecutor().also { exec ->
            exec.scheduleWithFixedDelay(
                { runDetectionPassSafely() },
                0L,
                MONITOR_INTERVAL_MS,
                TimeUnit.MILLISECONDS
            )
        }
    }

    private fun stopMonitoringLoop() {
        monitorExecutor?.shutdownNow()
        monitorExecutor = null
    }

    private fun runDetectionPassSafely() {
        try {
            runDetectionPass()
        } catch (e: Exception) {
            Log.e("VaultSync", "👁️ MONITOR: Detection pass failed: ${e.message}", e)
        }
    }

    private fun runDetectionPass() {
        val ctx = applicationContext
        if (!MonitoringPrefs.isEnabled(ctx)) return

        val packages = MonitoringPrefs.getPackages(ctx)
        if (packages.isEmpty()) return

        val now = System.currentTimeMillis()
        val sinceMs = MonitoringPrefs.getCheckpointMs(ctx)

        val exits = automationEngine.getEmulatorExitsSince(packages, sinceMs)
        if (exits.isNotEmpty()) {
            Log.i("VaultSync", "👁️ MONITOR: Detected ${exits.size} exit(s) since $sinceMs")
        }
        for (exit in exits) {
            val pkg = exit["package"] as? String ?: continue
            dispatchExit(pkg)
        }

        // Advance unconditionally: dispatch is fire-and-forget (a broadcast
        // to the main process) and idempotent/checkpointed on the Dart
        // side, so re-detecting the same exit next pass would only cause a
        // harmless duplicate trigger, not correctness issues — but leaving
        // the checkpoint behind would cause that every single pass.
        MonitoringPrefs.setCheckpointMs(ctx, now)
    }

    /**
     * Hands a detected exit off to the main process via an explicit,
     * non-exported broadcast to [ExitDispatchReceiver]. `:monitor` itself
     * never calls the method channel or WorkManager directly — see this
     * class's doc and [ExitDispatcher].
     */
    private fun dispatchExit(packageName: String) {
        Log.i("VaultSync", "👁️ MONITOR: Exit detected for $packageName — notifying main process")
        val intent = Intent(applicationContext, ExitDispatchReceiver::class.java).apply {
            putExtra(ExitDispatchReceiver.EXTRA_PACKAGE_NAME, packageName)
        }
        applicationContext.sendBroadcast(intent)
    }

    // ---- Notification ---------------------------------------------------

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                resolveString("notification_channel_name", "VaultSync Background Sync"),
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = resolveString(
                    "notification_channel_description",
                    "Keeps VaultSync running to prevent connection drops"
                )
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    private fun updateNotification() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification())
    }

    private fun buildNotification(): Notification {
        val iconResId = resources.getIdentifier("launcher_icon", "mipmap", packageName)
        val validIcon = if (iconResId != 0) iconResId else android.R.drawable.ic_popup_sync

        val contentText = if (MonitoringPrefs.isSyncActive(applicationContext)) {
            resolveString("notification_content", "Synchronization in progress…")
        } else {
            resolveString("notification_content_monitoring", "Watching for game exits")
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(resolveString("notification_title", "VaultSync"))
            .setContentText(contentText)
            .setSmallIcon(validIcon)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .build()
    }

    /**
     * Resolves a string resource by name with a hardcoded [fallback] so a
     * missing resource (e.g. a locale where a new key wasn't added) can never
     * crash `onCreate`/`onStartCommand` — unlike the previous direct
     * `getString(getIdentifier(...))` calls, which threw on a miss.
     */
    private fun resolveString(key: String, fallback: String): String {
        return try {
            val resId = resources.getIdentifier(key, "string", packageName)
            if (resId != 0) getString(resId) else fallback
        } catch (e: Exception) {
            fallback
        }
    }
}
