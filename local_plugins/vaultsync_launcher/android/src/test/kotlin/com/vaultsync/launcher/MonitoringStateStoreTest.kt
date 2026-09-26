package com.vaultsync.launcher

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * These tests simulate the cross-process read/write pattern by pointing two
 * separate [MonitoringStateStore] instances at the same underlying file —
 * standing in for the main process and `:monitor`, which really are two
 * different JVMs/processes but share the same on-disk file. Since
 * [MonitoringStateStore] does no in-memory caching, a second instance seeing
 * a first instance's write (with no explicit hand-off between them) is
 * exactly the property that makes it safe to use across real OS processes.
 */
class MonitoringStateStoreTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    private lateinit var storeFile: File

    @Before
    fun setup() {
        storeFile = File(tempFolder.newFolder("monitoring"), "state")
    }

    private fun newStore() = MonitoringStateStore(storeFile)

    @Test
    fun `importIfAbsent writes the legacy state when the store is new`() {
        val imported = newStore().importIfAbsent(
            MonitoringStateStore.State(enabled = true, packages = listOf("dev.eden.eden_emulator"), checkpointMs = 42L)
        )
        assertTrue(imported)
        val state = newStore().read()
        assertTrue(state.enabled)
        assertEquals(listOf("dev.eden.eden_emulator"), state.packages)
        assertEquals(42L, state.checkpointMs)
    }

    @Test
    fun `importIfAbsent never overwrites a value already written`() {
        newStore().writeEnabled(false)
        val imported = newStore().importIfAbsent(MonitoringStateStore.State(enabled = true))
        assertFalse(imported)
        assertFalse(newStore().read().enabled)
    }

    @Test
    fun `read returns defaults when no file exists yet`() {
        val state = newStore().read()
        assertFalse(state.enabled)
        assertTrue(state.packages.isEmpty())
        assertNull(state.checkpointMs)
        assertFalse(state.syncActive)
    }

    @Test
    fun `a write from one instance is visible from a separate instance on the same file`() {
        newStore().writeEnabled(true)

        // A fresh instance, as :monitor would construct on its own read —
        // no shared object, no cache, with the first instance's write.
        val reader = newStore()
        assertTrue(reader.read().enabled)
    }

    @Test
    fun `writePackages persists the list and preserves other fields`() {
        val writer = newStore()
        writer.writeEnabled(true)
        writer.writeCheckpointMs(1234L)

        writer.writePackages(listOf("com.nintendo.a", "com.sony.b"))

        val state = newStore().read()
        assertEquals(listOf("com.nintendo.a", "com.sony.b"), state.packages)
        // The read-modify-write must not clobber fields set by earlier calls.
        assertTrue(state.enabled)
        assertEquals(1234L, state.checkpointMs)
    }

    @Test
    fun `writeCheckpointMs persists and round-trips an exact value`() {
        newStore().writeCheckpointMs(9_999_999_999L)
        assertEquals(9_999_999_999L, newStore().read().checkpointMs)
    }

    @Test
    fun `writeSyncActive is independent of enabled`() {
        val writer = newStore()
        writer.writeEnabled(false)
        writer.writeSyncActive(true)

        val state = newStore().read()
        assertTrue(state.syncActive)
        assertFalse(state.enabled)
    }

    @Test
    fun `an empty package list round-trips as empty, not a list with one blank entry`() {
        val writer = newStore()
        writer.writePackages(listOf("com.example.a"))
        writer.writePackages(emptyList())

        assertTrue(newStore().read().packages.isEmpty())
    }

    @Test
    fun `interleaved writes from two instances both survive`() {
        val processA = newStore()
        val processB = newStore()

        processA.writeEnabled(true)
        processB.writePackages(listOf("com.example.a"))
        processA.writeCheckpointMs(42L)
        processB.writeSyncActive(true)

        val finalState = newStore().read()
        assertTrue(finalState.enabled)
        assertEquals(listOf("com.example.a"), finalState.packages)
        assertEquals(42L, finalState.checkpointMs)
        assertTrue(finalState.syncActive)
    }
}
