package com.vaultsync.launcher

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Covers only the pure dispatch decision ([ExitDispatcher.decideAction]),
 * which is the part of the main-process receiver's behavior that's testable
 * without a Context/MethodChannel/WorkManager. [ExitDispatcher.dispatch]
 * itself needs a real Android environment (it touches
 * VaultSyncLauncherPlugin's channel and WorkManager) and is exercised on
 * device, not here.
 */
class ExitDispatcherTest {

    @Test
    fun `a live channel is dispatched via invokeMethod, not WorkManager`() {
        assertEquals(DispatchAction.INVOKE_CHANNEL, ExitDispatcher.decideAction(channelAttached = true))
    }

    @Test
    fun `no live channel falls back to enqueuing WorkManager`() {
        assertEquals(DispatchAction.ENQUEUE_WORK, ExitDispatcher.decideAction(channelAttached = false))
    }
}
