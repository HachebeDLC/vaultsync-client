package com.vaultsync.launcher

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Unit tests for [FileScanner.selectMatchingChild], the pure by-name row
 * selection extracted from `DownloadManager.handleDownloadFile`'s SAF branch.
 *
 * Background: after a SAF download, DownloadManager needs the docId of the
 * file it just wrote so it can build the same document URI
 * `scanSafRecursive` would emit for it (see FileScanner.getTreeUri /
 * DocumentsContract.buildDocumentUriUsingTree, both of which require the real
 * Android framework and are not testable here — this module has no
 * Robolectric setup). The row-selection logic feeding that URI build,
 * however, has no such dependency and is covered here.
 */
class FileScannerSafChildSelectionTest {

    private fun row(docId: String, name: String, size: Long = 0L, lastModified: Long = 0L) =
        SafChildRow(documentId = docId, displayName = name, size = size, lastModified = lastModified)

    @Test
    fun `matches the row whose display name equals the target`() {
        val rows = listOf(
            row("doc1", "other.dat"),
            row("doc2", "rep_gamedata1.dat", size = 4012L, lastModified = 5_000L),
            row("doc3", "another.dat"),
        )

        val match = FileScanner.selectMatchingChild(rows, "rep_gamedata1.dat")

        assertEquals("doc2", match?.documentId)
        assertEquals(4012L, match?.size)
        assertEquals(5_000L, match?.lastModified)
    }

    @Test
    fun `returns null when no row matches`() {
        val rows = listOf(row("doc1", "other.dat"), row("doc2", "another.dat"))

        assertNull(FileScanner.selectMatchingChild(rows, "missing.dat"))
    }

    @Test
    fun `returns null for an empty row list`() {
        assertNull(FileScanner.selectMatchingChild(emptyList(), "anything.dat"))
    }

    @Test
    fun `first match wins when names collide`() {
        // The DocumentsProvider should never emit duplicate display names in one
        // directory, but the selection is defined to be deterministic (first
        // cursor-order match) rather than throwing if it ever does.
        val rows = listOf(
            row("doc1", "dup.dat", size = 100L),
            row("doc2", "dup.dat", size = 200L),
        )

        val match = FileScanner.selectMatchingChild(rows, "dup.dat")

        assertEquals("doc1", match?.documentId)
        assertEquals(100L, match?.size)
    }

    @Test
    fun `match is case-sensitive`() {
        val rows = listOf(row("doc1", "Save.dat"))

        assertNull(FileScanner.selectMatchingChild(rows, "save.dat"))
        assertEquals("doc1", FileScanner.selectMatchingChild(rows, "Save.dat")?.documentId)
    }
}
