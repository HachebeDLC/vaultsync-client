package com.vaultsync.launcher

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Unit tests for [FileScanner.pickBestProfileByMtime], the pure helper
 * extracted from `findSwitchProfileId` so the Switch active-profile
 * selection rule can be tested without Robolectric / SAF.
 *
 * Algorithm parity with VaultSync's Dart
 * `SystemPathService.pickActiveProfileFromZeroUserDir` and Argosy's
 * `SwitchSaveHandler.findActiveProfileFolder` mtime fallback.
 */
class FileScannerProfilePickTest {

    @Test
    fun `empty list returns null`() {
        assertNull(FileScanner.pickBestProfileByMtime(emptyList()))
    }

    @Test
    fun `single candidate is returned regardless of mtime`() {
        val only = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        assertEquals(only, FileScanner.pickBestProfileByMtime(listOf(only to 0L)))
        assertEquals(only, FileScanner.pickBestProfileByMtime(listOf(only to 12345L)))
    }

    @Test
    fun `greatest mtime wins among multiple candidates`() {
        val a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        val b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        val c = "cccccccccccccccccccccccccccccccc"
        val result = FileScanner.pickBestProfileByMtime(
            listOf(a to 100L, b to 500L, c to 200L)
        )
        assertEquals(b, result)
    }

    @Test
    fun `ties resolve to first-encountered candidate`() {
        val a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        val b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        val result = FileScanner.pickBestProfileByMtime(
            listOf(a to 500L, b to 500L)
        )
        assertEquals("tie goes to first-encountered", a, result)
    }

    @Test
    fun `all-zero mtimes still return first candidate, not null`() {
        // If the filesystem can't produce mtimes (unlikely but possible on
        // some SAF providers), we still want a deterministic pick.
        val a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        val b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        val result = FileScanner.pickBestProfileByMtime(
            listOf(a to 0L, b to 0L)
        )
        assertEquals(a, result)
    }
}
