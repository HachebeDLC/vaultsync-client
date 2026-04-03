package com.vaultsync.launcher

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.channels.FileChannel
import java.nio.file.StandardOpenOption
import javax.crypto.spec.SecretKeySpec

/**
 * Verifies that [decryptEncryptedStream] produces byte-for-byte identical output
 * to the original plaintext for every block-size boundary condition.
 *
 * These are pure JVM tests — no Android framework needed.
 * Run with: ./gradlew :vaultsync_launcher:testDebugUnitTest
 */
class DownloadStreamTest {

    // 32-byte key, deterministic for tests
    private val secretKey = SecretKeySpec(ByteArray(32) { it.toByte() }, "AES")
    private val crypto = CryptoEngine()

    /**
     * Mirrors the server-side upload: encrypts [plaintext] block by block
     * using the same block size the server would choose for this file size.
     */
    private fun serverSideEncrypt(plaintext: ByteArray): ByteArray {
        val fileSize = plaintext.size.toLong()
        val plainBlockSize = CryptoEngine.getBlockSize(fileSize)
        val encBlockSize = CryptoEngine.getEncryptedBlockSize(fileSize)
        val encBuffer = ByteArray(encBlockSize + 32)
        val out = ByteArrayOutputStream()

        var offset = 0
        while (offset < plaintext.size) {
            val chunkSize = minOf(plainBlockSize, plaintext.size - offset)
            val len = crypto.encryptBlock(plaintext, offset, chunkSize, secretKey, encBuffer)
            out.write(encBuffer, 0, len)
            offset += chunkSize
        }
        return out.toByteArray()
    }

    // CryptoEngine.encryptBlock takes (data, offset, length, key, output) — but the current
    // signature is (blockData: ByteArray, dataLength: Int, ...). We need a slice helper.
    private fun CryptoEngine.encryptBlock(
        src: ByteArray, srcOffset: Int, srcLength: Int,
        key: SecretKeySpec, output: ByteArray
    ): Int {
        val slice = src.copyOfRange(srcOffset, srcOffset + srcLength)
        return encryptBlock(slice, srcLength, key, output)
    }

    private fun verifyRoundtrip(sizeBytes: Int) {
        val original = ByteArray(sizeBytes) { (it % 251).toByte() }
        val encrypted = serverSideEncrypt(original)

        val tmp = File.createTempFile("vs_test_", ".bin")
        try {
            FileChannel.open(tmp.toPath(), StandardOpenOption.READ, StandardOpenOption.WRITE).use { ch ->
                decryptEncryptedStream(
                    inputStream = ByteArrayInputStream(encrypted),
                    output = ch,
                    secretKey = secretKey,
                    cryptoEngine = crypto,
                    patchIndices = null,
                    fileSize = sizeBytes.toLong()
                )
            }
            val result = tmp.readBytes()
            assertEquals("Size mismatch for input of $sizeBytes bytes", sizeBytes, result.size)
            assertArrayEquals("Content mismatch for input of $sizeBytes bytes", original, result)
        } finally {
            tmp.delete()
        }
    }

    // --- Small-block tier (files < 10 MB, blockSize = 256 KB) ---

    @Test
    fun `small tier - exact multiple of block size`() {
        // 4 × 256 KB = 1 MB, no partial block
        verifyRoundtrip(CryptoEngine.SMALL_BLOCK_SIZE * 4)
    }

    @Test
    fun `small tier - partial last block`() {
        // 1 full 256 KB block + 100 KB tail
        verifyRoundtrip(CryptoEngine.SMALL_BLOCK_SIZE + 100_000)
    }

    @Test
    fun `small tier - file smaller than one block`() {
        // Entire file fits in the first partial block
        verifyRoundtrip(77_777)
    }

    @Test
    fun `small tier - one byte file`() {
        verifyRoundtrip(1)
    }

    // --- Large-block tier (files >= 10 MB, blockSize = 1 MB) ---

    @Test
    fun `large tier - exact multiple of block size`() {
        // 10 × 1 MB = 10 MB exactly (at threshold boundary), no partial block
        verifyRoundtrip(CryptoEngine.LARGE_BLOCK_SIZE * 10)
    }

    @Test
    fun `large tier - partial last block`() {
        // 10 full 1 MB blocks + 512 KB tail (crosses the 10 MB threshold)
        verifyRoundtrip(CryptoEngine.LARGE_BLOCK_SIZE * 10 + 512 * 1024)
    }

    @Test
    fun `large tier - Eden save corruption scenario`() {
        // The real-world file size that caused Eden save corruption:
        // 13 full 1 MB blocks + 773 KB tail. The old code dropped the tail silently.
        val size = CryptoEngine.LARGE_BLOCK_SIZE * 13 + 773 * 1024
        verifyRoundtrip(size)
    }
}
