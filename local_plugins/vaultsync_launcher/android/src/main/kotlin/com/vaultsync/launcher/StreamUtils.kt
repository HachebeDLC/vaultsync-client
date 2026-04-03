package com.vaultsync.launcher

import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import javax.crypto.spec.SecretKeySpec

/**
 * Decrypts an AES-CBC encrypted stream written in NEOSYNC block format into [output].
 *
 * Each block in the stream is: MAGIC(7) + IV(16) + AES-CBC-ciphertext.
 * The final block is almost always a partial block (smaller than [expectedBlockSize]),
 * and MUST be flushed after the stream ends — that is what this function guarantees.
 *
 * Extracted from DownloadManager so it can be tested with plain JUnit (no Android deps).
 */
internal fun decryptEncryptedStream(
    inputStream: InputStream,
    output: FileChannel,
    secretKey: SecretKeySpec,
    cryptoEngine: CryptoEngine,
    patchIndices: List<Int>?,
    fileSize: Long
) {
    val plainBlockSize = CryptoEngine.getBlockSize(fileSize)
    val expectedBlockSize = CryptoEngine.getEncryptedBlockSize(fileSize)

    val ringBuffer = ByteBuffer.allocate(expectedBlockSize * 2)
    val block = ByteArray(expectedBlockSize)
    val decryptedBuffer = ByteArray(expectedBlockSize + 32)
    var currentIdx = 0

    val chunk = ByteArray(65536)
    while (true) {
        val readCount = inputStream.read(chunk)
        if (readCount == -1) break

        ringBuffer.put(chunk, 0, readCount)
        ringBuffer.flip()
        while (ringBuffer.remaining() >= expectedBlockSize) {
            ringBuffer.get(block, 0, expectedBlockSize)
            val decryptedLength = cryptoEngine.decryptBlock(block, expectedBlockSize, secretKey, decryptedBuffer)
            val blockIndex = if (patchIndices != null) patchIndices[currentIdx].toLong() else currentIdx.toLong()
            output.position(blockIndex * plainBlockSize)
            output.write(ByteBuffer.wrap(decryptedBuffer, 0, decryptedLength))
            currentIdx++
        }
        ringBuffer.compact()
    }

    // Flush the final partial block — this is the fix for the Eden save corruption bug.
    // The main loop only fires when a full expectedBlockSize chunk is available.
    // The last block is almost always smaller; without this flush it would be silently dropped.
    ringBuffer.flip()
    if (ringBuffer.hasRemaining() && (patchIndices == null || currentIdx < patchIndices.size)) {
        val remaining = ringBuffer.remaining()
        val lastBlock = ByteArray(remaining)
        ringBuffer.get(lastBlock, 0, remaining)
        val decryptedLength = cryptoEngine.decryptBlock(lastBlock, remaining, secretKey, decryptedBuffer)
        val blockIndex = if (patchIndices != null) patchIndices[currentIdx].toLong() else currentIdx.toLong()
        output.position(blockIndex * plainBlockSize)
        output.write(ByteBuffer.wrap(decryptedBuffer, 0, decryptedLength))
    }
}
