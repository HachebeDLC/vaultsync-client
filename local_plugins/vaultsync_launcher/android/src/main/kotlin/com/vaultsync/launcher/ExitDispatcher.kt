package com.vaultsync.launcher

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.ListenableWorker
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.WorkManager

/** Which delivery path an exit notification should take. See [ExitDispatcher.decideAction]. */
enum class DispatchAction {
    /** A Flutter engine is currently attached — invoke its method channel directly. */
    INVOKE_CHANNEL,

    /** No engine is attached — enqueue a one-off WorkManager job instead. */
    ENQUEUE_WORK
}

/**
 * What the **main process** does when `:monitor` (see [SyncForegroundService])
 * detects an emulator exit and hands it off via [ExitDispatchReceiver]:
 * deliver it to Dart directly through the live method channel if a Flutter
 * engine is currently attached, or by enqueuing a one-off WorkManager job
 * that runs the `exitCatchUp` Dart task otherwise. Never both, for the same
 * exit.
 *
 * This logic — and the WorkManager/method-channel dependencies it needs —
 * used to live inside `SyncForegroundService` itself. It moved here, to a
 * main-process-only object, when the service moved to its own `:monitor`
 * process: per the design, WorkManager and the method channel must stay out
 * of `:monitor` entirely (no multi-process WorkManager, and no Flutter
 * engine there to own a channel in the first place).
 */
object ExitDispatcher {
    // The workmanager plugin's own worker + input-data key, referenced by
    // name (not by compile-time dependency on its Gradle module) — see
    // dev.fluttercommunity.workmanager.BackgroundWorker in
    // workmanager_android's source.
    private const val WORKMANAGER_WORKER_CLASS = "dev.fluttercommunity.workmanager.BackgroundWorker"
    private const val WORKMANAGER_DART_TASK_KEY = "dev.fluttercommunity.workmanager.DART_TASK"
    private const val EXIT_CATCHUP_DART_TASK = "exitCatchUp"
    private const val EXIT_CATCHUP_UNIQUE_WORK_NAME = "vaultsync-exit-catchup-oneoff"

    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

    /**
     * Pure decision of which delivery path to take, kept free of Android
     * types so it's unit testable without a device/emulator.
     */
    fun decideAction(channelAttached: Boolean): DispatchAction =
        if (channelAttached) DispatchAction.INVOKE_CHANNEL else DispatchAction.ENQUEUE_WORK

    /** Delivers a detected exit for [packageName], run from [ExitDispatchReceiver]. */
    fun dispatch(context: Context, packageName: String) {
        val channel = VaultSyncLauncherPlugin.currentChannel()
        when (decideAction(channelAttached = channel != null)) {
            DispatchAction.INVOKE_CHANNEL -> {
                Log.i("VaultSync", "👁️ EXIT-DISPATCH: Live engine attached — invoking onEmulatorClosed($packageName) directly")
                mainHandler.post {
                    channel?.invokeMethod("onEmulatorClosed", packageName)
                }
            }
            DispatchAction.ENQUEUE_WORK -> {
                Log.i("VaultSync", "👁️ EXIT-DISPATCH: No live engine — enqueuing exitCatchUp WorkManager job for $packageName")
                enqueueExitCatchUpWork(context)
            }
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun enqueueExitCatchUpWork(context: Context) {
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

            WorkManager.getInstance(context).enqueueUniqueWork(
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
}
