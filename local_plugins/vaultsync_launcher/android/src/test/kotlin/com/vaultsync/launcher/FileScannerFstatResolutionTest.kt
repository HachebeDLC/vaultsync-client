package com.vaultsync.launcher

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Unit tests for [FileScanner.resolveScannedSizeAndMtime], the pure helper
 * extracted from `scanSafRecursive`'s batched `Os.fstat()` post-processing
 * so the size/mtime selection rule can be tested without SAF / Robolectric.
 *
 * Background: the SAF cursor's COLUMN_SIZE (like its LAST_MODIFIED) is
 * unreliable under Android/data. A device scan reported 0 bytes for Switch
 * saves that genuinely held content, which then let a stale zero-size
 * cache/journal entry mask an unsynced file. fstat() is already performed
 * to fix mtime there; this resolves size from the same stat struct.
 */
class FileScannerFstatResolutionTest {

    @Test
    fun `fstat size and mtime both used when present`() {
        val (size, mtime) = FileScanner.resolveScannedSizeAndMtime(
            cursorSize = 0L,
            cursorLastModified = 1_000L,
            fstatMtime = 5_000L,
            fstatSize = 4012L,
        )
        assertEquals(4012L, size)
        assertEquals(5_000L, mtime)
    }

    @Test
    fun `cursor size kept when fstat size is null (fstat failed)`() {
        val (size, mtime) = FileScanner.resolveScannedSizeAndMtime(
            cursorSize = 777L,
            cursorLastModified = 1_000L,
            fstatMtime = null,
            fstatSize = null,
        )
        assertEquals(777L, size)
        assertEquals(1_000L, mtime)
    }

    @Test
    fun `fstat size of zero is trusted over a stale non-zero cursor size`() {
        // A genuinely-emptied file: fstat is the real kernel stat and wins even
        // though it disagrees with (and is lower than) the cursor's stale value.
        val (size, mtime) = FileScanner.resolveScannedSizeAndMtime(
            cursorSize = 4012L,
            cursorLastModified = 1_000L,
            fstatMtime = 5_000L,
            fstatSize = 0L,
        )
        assertEquals(0L, size)
        assertEquals(5_000L, mtime)
    }

    @Test
    fun `mtime falls back to cursor value when fstat mtime is non-positive`() {
        // Caller (scanSafRecursive) maps a non-positive st_mtime to null before
        // calling in; verify the fallback path independently of that mapping.
        val (size, mtime) = FileScanner.resolveScannedSizeAndMtime(
            cursorSize = 500L,
            cursorLastModified = 2_000L,
            fstatMtime = null,
            fstatSize = 500L,
        )
        assertEquals(500L, size)
        assertEquals(2_000L, mtime)
    }

    @Test
    fun `size and mtime fallbacks are independent of each other`() {
        // fstat mtime present but size absent: mtime should still update while
        // size falls back to the cursor value.
        val (size, mtime) = FileScanner.resolveScannedSizeAndMtime(
            cursorSize = 300L,
            cursorLastModified = 1_000L,
            fstatMtime = 9_999L,
            fstatSize = null,
        )
        assertEquals(300L, size)
        assertEquals(9_999L, mtime)
    }
}
