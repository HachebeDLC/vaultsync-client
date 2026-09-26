package com.vaultsync.launcher

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Covers only [ProcessGuard.isMonitorProcessName], the pure part of the
 * process-name guard used to keep Flutter/WorkManager out of `:monitor`.
 * [ProcessGuard.currentProcessName] needs a real Context/Application and is
 * exercised on device, not here.
 */
class ProcessGuardTest {

    @Test
    fun `null process name is not the monitor process`() {
        assertFalse(ProcessGuard.isMonitorProcessName(null))
    }

    @Test
    fun `empty string is not the monitor process`() {
        assertFalse(ProcessGuard.isMonitorProcessName(""))
    }

    @Test
    fun `the main process name is not the monitor process`() {
        assertFalse(ProcessGuard.isMonitorProcessName("com.vaultsync.app"))
    }

    @Test
    fun `the monitor process name is detected`() {
        assertTrue(ProcessGuard.isMonitorProcessName("com.vaultsync.app:monitor"))
    }

    @Test
    fun `a similarly-named but different suffix is not treated as the monitor process`() {
        assertFalse(ProcessGuard.isMonitorProcessName("com.vaultsync.app:monitors"))
    }

    @Test
    fun `a different process suffix entirely is not the monitor process`() {
        assertFalse(ProcessGuard.isMonitorProcessName("com.vaultsync.app:workmanager"))
    }
}
