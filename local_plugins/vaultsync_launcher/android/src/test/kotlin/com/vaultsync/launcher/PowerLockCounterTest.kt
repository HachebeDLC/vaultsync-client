package com.vaultsync.launcher

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class PowerLockCounterTest {

    private lateinit var counter: PowerLockCounter

    @Before
    fun setup() {
        counter = PowerLockCounter()
    }

    @Test
    fun `first acquire reports the 0 to 1 transition`() {
        assertTrue("First acquire should report the 0->1 transition", counter.acquire())
        assertEquals(1, counter.count)
    }

    @Test
    fun `second acquire does not report a transition`() {
        counter.acquire()
        assertFalse("Second acquire should not report a transition", counter.acquire())
        assertEquals(2, counter.count)
    }

    @Test
    fun `first release does not report 1 to 0 while another owner remains`() {
        counter.acquire()
        counter.acquire()
        assertFalse("Release with a remaining owner should not report the 1->0 transition", counter.release())
        assertEquals(1, counter.count)
    }

    @Test
    fun `last release reports the 1 to 0 transition`() {
        counter.acquire()
        counter.acquire()
        counter.release()
        assertTrue("Final release should report the 1->0 transition", counter.release())
        assertEquals(0, counter.count)
    }

    @Test
    fun `release at zero is a no-op and does not go negative`() {
        assertFalse("Release at zero should not report a transition", counter.release())
        assertEquals(0, counter.count)

        // Sanity: still behaves correctly for a subsequent real acquire/release cycle.
        assertTrue(counter.acquire())
        assertTrue(counter.release())
        assertEquals(0, counter.count)
    }
}
