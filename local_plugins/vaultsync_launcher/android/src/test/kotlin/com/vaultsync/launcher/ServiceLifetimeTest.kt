package com.vaultsync.launcher

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class ServiceLifetimeTest {

    private lateinit var lifetime: ServiceLifetime

    @Before
    fun setup() {
        lifetime = ServiceLifetime()
    }

    @Test
    fun `initially the service should not run`() {
        assertFalse(lifetime.shouldServiceRun)
    }

    @Test
    fun `enabling monitoring with no syncs starts the service`() {
        assertEquals(true, lifetime.setMonitoringEnabled(true))
        assertTrue(lifetime.shouldServiceRun)
    }

    @Test
    fun `enabling monitoring twice reports no further transition`() {
        lifetime.setMonitoringEnabled(true)
        assertNull(lifetime.setMonitoringEnabled(true))
    }

    @Test
    fun `disabling monitoring with no syncs stops the service`() {
        lifetime.setMonitoringEnabled(true)
        assertEquals(false, lifetime.setMonitoringEnabled(false))
        assertFalse(lifetime.shouldServiceRun)
    }

    @Test
    fun `disabling monitoring while a sync is active does not stop the service`() {
        lifetime.setMonitoringEnabled(true)
        lifetime.onSyncCountChanged(1)
        assertNull(lifetime.setMonitoringEnabled(false))
        assertTrue("Service should stay up because a sync is still running", lifetime.shouldServiceRun)
    }

    @Test
    fun `a sync starting with monitoring off starts the service`() {
        assertEquals(true, lifetime.onSyncCountChanged(1))
        assertTrue(lifetime.shouldServiceRun)
    }

    @Test
    fun `a sync starting while monitoring is already on reports no transition`() {
        lifetime.setMonitoringEnabled(true)
        assertNull(lifetime.onSyncCountChanged(1))
        assertTrue(lifetime.shouldServiceRun)
    }

    @Test
    fun `a sync ending with monitoring off stops the service`() {
        lifetime.onSyncCountChanged(1)
        assertEquals(false, lifetime.onSyncCountChanged(0))
        assertFalse(lifetime.shouldServiceRun)
    }

    @Test
    fun `a sync ending while monitoring stays on does not stop the service`() {
        lifetime.setMonitoringEnabled(true)
        lifetime.onSyncCountChanged(1)
        assertNull(lifetime.onSyncCountChanged(0))
        assertTrue("Service should stay up because monitoring is still on", lifetime.shouldServiceRun)
    }

    @Test
    fun `multiple concurrent syncs only transition once on each edge`() {
        assertEquals(true, lifetime.onSyncCountChanged(1))
        assertNull(lifetime.onSyncCountChanged(2))
        assertNull(lifetime.onSyncCountChanged(1))
        assertEquals(false, lifetime.onSyncCountChanged(0))
    }

    @Test
    fun `monitoring on then off then on again with no syncs toggles the service each time`() {
        assertEquals(true, lifetime.setMonitoringEnabled(true))
        assertEquals(false, lifetime.setMonitoringEnabled(false))
        assertEquals(true, lifetime.setMonitoringEnabled(true))
    }

    @Test
    fun `reporting the same sync count twice is a no-op`() {
        assertNull(lifetime.onSyncCountChanged(0))
    }

    @Test
    fun `state accessors reflect the latest values`() {
        lifetime.setMonitoringEnabled(true)
        lifetime.onSyncCountChanged(3)
        assertTrue(lifetime.isMonitoringEnabled)
        assertEquals(3, lifetime.currentSyncCount)
    }
}
