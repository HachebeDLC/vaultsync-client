package com.vaultsync.launcher

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.ListenableWorker
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.WorkManager
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * Low-importance foreground service that keeps VaultSync's exit-detection
 * loop alive while "sync on game exit" is enabled, and hosts the existing
 * "Synchronization in progress" service while a sync is running.
 *
 * Whether this service should be running at all, and whether the wake/wifi
 * locks should be held, is decided by [PowerManagerHelper]'s shared
 * [ServiceLifetime] — this class only reacts to being started/stopped and
 * owns the detection loop itself, so it survives the owning Flutter engine
 * (and even the whole app process, via `START_STICKY`) going away.
 */
class SyncForegroundService : Service() {
    companion object {
        const val CHANNEL_ID = "vaultsync_background_channel"
        const val NOTIFICATION_ID = 4040
        private const val MONITOR_INTERVAL_MS = 15_000L

        // The workmanager plugin's own worker + input-data key, referenced by
        // name (not by compile-time dependency on its Gradle module) — see
        // dev.fluttercommunity.workmanager.BackgroundWorker in
        // workmanager_android's source.
        private const val WORKMANAGER_WORKER_CLASS = "dev.fluttercommunity.workmanager.BackgroundWorker"
        private const val WORKMANAGER_DART_TASK_KEY = "dev.fluttercommunity.workmanager.DART_TASK"
        private const val EXIT_CATCHUP_DART_TASK = "exitCatchUp"
        private const val EXIT_CATCHUP_UNIQUE_WORK_NAME = "vaultsync-exit-catchup-oneoff"
    }

    private lateinit var automationEngine: AutomationEngine
    private val mainHandler = Handler(Looper.getMainLooper())
    private var monitorExecutor: ScheduledExecutorService? = null

    override fun onCreate() {
        super.onCreate()
        automationEngine = AutomationEngine(applicationContext)
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Always resync the notification with current global state: this
        // handles both a fresh start/refresh poke from PowerManagerHelper and
        // a system-triggered START_STICKY restart (intent == null) after the
        // process was killed.
        PowerManagerHelper.restoreMonitoringFromPrefs(applicationContext)
        updateNotification()

        if (MonitoringPrefs.isEnabled(applicationContext)) {
            startMonitoringLoopIfNeeded()
        } else {
            stopMonitoringLoop()
            // The in-memory sync ref count (PowerLockCounter) does not
            // survive process death. If we were restarted with neither
            // monitoring enabled nor a sync actually in flight, there is no
            // reason left to be running — this is the only place that can
            // detect that case, since it's specific to a sticky restart.
            if (!PowerManagerHelper.isSyncActive()) {
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

        // Advance unconditionally: dispatch is fire-and-forget (channel call
        // or WorkManager job) and both paths are idempotent/checkpointed on
        // the Dart side, so re-detecting the same exit next pass would only
        // cause a harmless duplicate trigger, not correctness issues — but
        // leaving the checkpoint behind would cause that every single pass.
        MonitoringPrefs.setCheckpointMs(ctx, now)
    }

    /**
     * Delivers a detected exit to Dart: directly through the live method
     * channel if a Flutter engine is currently attached, or by enqueuing a
     * one-off WorkManager job that runs the `exitCatchUp` Dart task
     * otherwise. Never both, for the same exit.
     */
    private fun dispatchExit(packageName: String) {
        val channel = VaultSyncLauncherPlugin.currentChannel()
        if (channel != null) {
            Log.i("VaultSync", "👁️ MONITOR: Live engine attached — invoking onEmulatorClosed($packageName) directly")
            mainHandler.post {
                channel.invokeMethod("onEmulatorClosed", packageName)
            }
        } else {
            Log.i("VaultSync", "👁️ MONITOR: No live engine — enqueuing exitCatchUp WorkManager job for $packageName")
            enqueueExitCatchUpWork()
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun enqueueExitCatchUpWork() {
        try {
            val workerClass = Class.forName(WORKMANAGER_WORKER_CLASS) as Class<out ListenableWorker>

            val inputData = Data.Builder()
                .putString(WORKMANAGER_DART_TASK_KEY, EXIT_CATCHUP_DART_TASK)
                .build()

            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()

            val request = OneTimeWorkRequest.Builder(workerClass)
                .setInputData(inputData)
                .setConstraints(constraints)
                .build()

            WorkManager.getInstance(applicationContext).enqueueUniqueWork(
                EXIT_CATCHUP_UNIQUE_WORK_NAME,
                ExistingWorkPolicy.KEEP,
                request
            )
            Log.i("VaultSync", "🧵 WORK: Enqueued one-off exitCatchUp job")
        } catch (e: ClassNotFoundException) {
            Log.e("VaultSync", "🧵 WORK: workmanager BackgroundWorker class not found — is the workmanager plugin installed?", e)
        } catch (e: Exception) {
            Log.e("VaultSync", "🧵 WORK: Failed to enqueue exitCatchUp job: ${e.message}", e)
        }
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

        val contentText = if (PowerManagerHelper.isSyncActive()) {
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
