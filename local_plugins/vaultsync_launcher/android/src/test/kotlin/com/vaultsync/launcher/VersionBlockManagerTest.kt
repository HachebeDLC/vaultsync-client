package com.vaultsync.launcher

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.RandomAccessFile

class VersionBlockManagerTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    private lateinit var versionStore: File
    private lateinit var liveFile: File
    private lateinit var manager: VersionBlockManager
    private val crypto = CryptoEngine()

    @Before
    fun setup() {
        versionStore = tempFolder.newFolder("versions")
        liveFile = tempFolder.newFile("save.dat")
        manager = VersionBlockManager(versionStore.absolutePath)
    }

    @Test
    fun `extractModifiedBlocks copies only changed blocks to version store`() {
        // Create an 11 MB live file (11 blocks of 1MB)
        val data = ByteArray(11 * 1048576)
        for (i in data.indices) {
            data[i] = ((i % 256) + (i / 1048576)).toByte()
        }
        liveFile.writeBytes(data)

        // Block 0: Modified
        // Block 1: Unchanged
        // Block 2: Modified
        
        val block0Hash = crypto.calculateHash(data.sliceArray(0 until 1048576), 1048576)
        val block2Hash = crypto.calculateHash(data.sliceArray(2 * 1048576 until 3 * 1048576), 1048576)

        // Manifest indicating which blocks changed (true = modified, false = unchanged)
        val changedBlocks = mapOf(
            0 to true,
            1 to false,
            2 to true
        )

        // Extract
        liveFile.inputStream().use { input ->
            manager.extractModifiedBlocks(input, liveFile.length(), changedBlocks)
        }

        // Verify only block 0 and block 2 are in the version store
        val block0File = File(versionStore, block0Hash)
        val block2File = File(versionStore, block2Hash)

        assertTrue("Block 0 should be stored", block0File.exists())
        assertTrue("Block 2 should be stored", block2File.exists())
        assertEquals("Block 0 size should match", 1048576, block0File.length())
        assertEquals("Block 2 size should match", 1048576, block2File.length())

        // Ensure block 1 is NOT stored
        val block1Hash = crypto.calculateHash(data.sliceArray(1048576 until 2 * 1048576), 1048576)
        val block1File = File(versionStore, block1Hash)
        assertTrue("Block 1 should NOT be stored", !block1File.exists())
    }

    @Test
    fun `reconstructFromDeltas builds correct file from live and version store`() {
        // Setup original data (Version 1, 11MB)
        val v1Data = ByteArray(11 * 1048576)
        for (i in v1Data.indices) v1Data[i] = ((i % 256) + (i / 1048576)).toByte()

        // Write V1 data to the live file so we can extract it
        liveFile.writeBytes(v1Data)
        
        // Extract all blocks as if it was a full save initially
        val allChanged = (0 until 11).associateWith { true }
        liveFile.inputStream().use { input ->
            manager.extractModifiedBlocks(input, liveFile.length(), allChanged)
        }

        // Now modify the live file to represent Version 2 (Current)
        val v2Data = v1Data.clone()
        for (i in 0 until 1048576) {
            v2Data[i] = ((i + 1) % 256).toByte() // Modify block 0
        }
        liveFile.writeBytes(v2Data)

        // We want to reconstruct V1.
        val v1LayoutHashes = (0 until 11).map { blockIndex ->
            crypto.calculateHash(v1Data.sliceArray(blockIndex * 1048576 until (blockIndex + 1) * 1048576), 1048576)
        }

        // The target restoration path
        val restoreFile = tempFolder.newFile("restore.dat")

        // Reconstruct V1!
        java.io.FileInputStream(liveFile).channel.use { liveChannel ->
            java.io.FileOutputStream(restoreFile).use { outStream ->
                manager.reconstructFromDeltas(v1LayoutHashes, liveChannel, liveFile.length(), outStream)
            }
        }

        // Verify reconstructed file matches V1 exactly
        val reconstructedData = restoreFile.readBytes()
        assertArrayEquals("Reconstructed file must exactly match Version 1 data", v1Data, reconstructedData)
    }
}
