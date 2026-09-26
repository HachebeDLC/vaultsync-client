package com.vaultsync.launcher

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import java.util.concurrent.Executors

/**
 * Runs in the **main** process (no `android:process` override — see
 * AndroidManifest.xml). Receives an explicit broadcast from
 * [SyncForegroundService] (which runs in the separate `:monitor` process)
 * when an emulator exit is detected, and hands it to [ExitDispatcher].
 *
 * This is deliberately the *only* bridge between `:monitor` and the main
 * process: `:monitor` never touches WorkManager or the Flutter method
 * channel directly (see SyncForegroundService's class doc) — it only sends
 * this broadcast. If the main process happens to be dead, delivering an
 * *explicit* broadcast to a manifest-registered receiver starts it, which is
 * fine: exits are rare, so this cold start is not a hot path.
 *
 * Declared `android:exported="false"` in the manifest: only components
 * within this app — including ones in another of its own processes, since
 * they all share the same UID — may deliver to it. No separate
 * signature-level permission is needed on top of that, because
 * [SyncForegroundService] always targets this receiver with an explicit
 * `Intent(context, ExitDispatchReceiver::class.java)`, never an implicit
 * broadcast that some other app could race to intercept.
 */
class ExitDispatchReceiver : BroadcastReceiver() {
    companion object {
        const val EXTRA_PACKAGE_NAME = "packageName"

        // A dedicated single-thread pool rather than the shared main
        // handler: enqueueing the WorkManager job touches disk (Room), and
        // this keeps that off the main thread while still processing
        // dispatches in the order they arrive.
        private val workExecutor = Executors.newSingleThreadExecutor()
    }

    override fun onReceive(context: Context, intent: Intent) {
        val packageName = intent.getStringExtra(EXTRA_PACKAGE_NAME)
        if (packageName == null) {
            Log.w("VaultSync", "👁️ EXIT-DISPATCH: Received broadcast with no packageName extra, ignoring")
            return
        }

        val appContext = context.applicationContext
        // Neither delivery path in ExitDispatcher.dispatch (a WorkManager
        // enqueue, or a post to the main looper for invokeMethod) is
        // guaranteed to complete before onReceive returns. goAsync() tells
        // the system this receiver isn't done yet, so the process isn't torn
        // back down mid-dispatch — important here specifically because,
        // unlike the old in-service dispatch, the main process may have just
        // been cold-started solely to handle this broadcast.
        val pendingResult = goAsync()
        workExecutor.execute {
            try {
                ExitDispatcher.dispatch(appContext, packageName)
            } catch (e: Exception) {
                Log.e("VaultSync", "👁️ EXIT-DISPATCH: dispatch failed: ${e.message}", e)
            } finally {
                pendingResult.finish()
            }
        }
    }
}
