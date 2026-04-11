package com.vaultsync.launcher

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

class BinaryHeaderScannerTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    private lateinit var scanner: BinaryHeaderScanner

    @Before
    fun setup() {
        scanner = BinaryHeaderScanner()
    }

    @Test
    fun `parseJksvMeta extracts TitleID correctly`() {
        val metaFile = tempFolder.newFile(".nx_save_meta.bin")
        val titleId = 0x0100ABCD12345678L
        
        // JKSV meta layout (offset 5, 4, or 6 according to Argosy)
        // Let's use offset 5 as primary
        val bytes = ByteArray(32)
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        buffer.position(5)
        buffer.putLong(titleId)
        
        metaFile.writeBytes(bytes)
        
        val result = scanner.parseJksvMeta(metaFile.absolutePath)
        assertEquals("0100ABCD12345678", result)
    }

    @Test
    fun `parseGciHeader extracts GameID and Region correctly`() {
        val gciFile = tempFolder.newFile("save.gci")
        val bytes = ByteArray(64)
        
        // GCI Header: 
        // [0-3] Game ID (e.g. GZLE)
        // [4-5] Maker Code (e.g. 01)
        // [9] Region (0=Japan, 1=USA, 2=Europe)
        
        bytes[0] = 'G'.toByte()
        bytes[1] = 'Z'.toByte()
        bytes[2] = 'L'.toByte()
        bytes[3] = 'E'.toByte()
        bytes[4] = '0'.toByte()
        bytes[5] = '1'.toByte()
        bytes[9] = 1.toByte() // USA
        
        gciFile.writeBytes(bytes)
        
        val result = scanner.parseGciHeader(gciFile.absolutePath)
        assertEquals("GZLE", result?.gameId)
        assertEquals("01", result?.makerCode)
        assertEquals("USA", result?.region)
    }

    @Test
    fun `parseJksvMeta returns null for invalid file`() {
        val metaFile = tempFolder.newFile("invalid.bin")
        metaFile.writeBytes(ByteArray(10))
        
        val result = scanner.parseJksvMeta(metaFile.absolutePath)
        assertNull(result)
    }
}
