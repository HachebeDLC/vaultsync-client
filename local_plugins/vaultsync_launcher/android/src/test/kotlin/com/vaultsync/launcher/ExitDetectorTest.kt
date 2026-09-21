package com.vaultsync.launcher

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ExitDetectorTest {

    private val monitored = setOf("com.retroarch", "org.yuzu.yuzu_emu")

    @Test
    fun `single exit is reported at its background timestamp`() {
        val events = listOf(
            UsageEvent("com.retroarch", UsageEventType.FOREGROUND, 1000L),
            UsageEvent("com.retroarch", UsageEventType.BACKGROUND, 5000L)
        )

        val exits = ExitDetector.findExits(events, monitored)

        assertEquals(mapOf("com.retroarch" to 5000L), exits)
    }

    @Test
    fun `exit followed by a later reopen is not reported as an exit`() {
        val events = listOf(
            UsageEvent("com.retroarch", UsageEventType.FOREGROUND, 1000L),
            UsageEvent("com.retroarch", UsageEventType.BACKGROUND, 5000L),
            UsageEvent("com.retroarch", UsageEventType.FOREGROUND, 6000L)
        )

        val exits = ExitDetector.findExits(events, monitored)

        assertTrue("Still-foreground package should not be reported as an exit", exits.isEmpty())
    }

    @Test
    fun `multiple exits for the same package return only the last one`() {
        val events = listOf(
            UsageEvent("com.retroarch", UsageEventType.FOREGROUND, 1000L),
            UsageEvent("com.retroarch", UsageEventType.BACKGROUND, 2000L),
            UsageEvent("com.retroarch", UsageEventType.FOREGROUND, 3000L),
            UsageEvent("com.retroarch", UsageEventType.BACKGROUND, 4000L)
        )

        val exits = ExitDetector.findExits(events, monitored)

        assertEquals(mapOf("com.retroarch" to 4000L), exits)
    }

    @Test
    fun `events for unmonitored packages are ignored`() {
        val events = listOf(
            UsageEvent("com.some.other.app", UsageEventType.FOREGROUND, 1000L),
            UsageEvent("com.some.other.app", UsageEventType.BACKGROUND, 2000L),
            UsageEvent("org.yuzu.yuzu_emu", UsageEventType.FOREGROUND, 1500L),
            UsageEvent("org.yuzu.yuzu_emu", UsageEventType.BACKGROUND, 2500L)
        )

        val exits = ExitDetector.findExits(events, monitored)

        assertEquals(mapOf("org.yuzu.yuzu_emu" to 2500L), exits)
    }

    @Test
    fun `empty event list reports no exits`() {
        val exits = ExitDetector.findExits(emptyList(), monitored)

        assertTrue(exits.isEmpty())
    }
}
