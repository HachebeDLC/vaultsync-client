package com.vaultsync.launcher

import java.io.File
import java.io.InputStream
import java.io.FileOutputStream
import java.nio.channels.FileChannel

class VersionBlockManager(private val versionStorePath: String) {
    private val crypto = CryptoEngine()

    init {
        File(versionStorePath).mkdirs()
    }

    /**
     * Extracts blocks that are marked as true (changed) in the manifest.
     * The extracted blocks are saved to the version store named by their SHA-256 hash.
     */
    fun extractModifiedBlocks(inputStream: InputStream, fileSize: Long, changedBlocks: Map<Int, Boolean>): Boolean {
        try {
            val blockSize = CryptoEngine.getBlockSize(fileSize)
            val buffer = ByteArray(blockSize)

            inputStream.use { fis ->
                var blockIndex = 0
                while (true) {
                    val bytesRead = fis.read(buffer)
                    if (bytesRead == -1) break

                    val isChanged = changedBlocks[blockIndex] ?: false
                    if (isChanged) {
                        val hash = crypto.calculateHash(buffer, bytesRead)
                        val targetFile = File(versionStorePath, hash)
                        
                        if (!targetFile.exists()) {
                            FileOutputStream(targetFile).use { fos ->
                                fos.write(buffer, 0, bytesRead)
                            }
                        }
                    }
                    blockIndex++
                }
            }
            return true
        } catch (e: Exception) {
            android.util.Log.e("VaultSync", "Error in extractModifiedBlocks: ${e.message}")
            return false
        }
    }

    /**
     * Reconstructs a full file given a list of block hashes representing the target layout.
     * It will search for each block first in the version store. If not found, it assumes
     * the block is unchanged and exists in the current live file.
     */
    fun reconstructFromDeltas(layoutHashes: List<String>, liveFileChannel: FileChannel?, liveFileSize: Long, outputStream: java.io.OutputStream): Boolean {
        try {
            val liveBlockSize = if (liveFileSize > 0) CryptoEngine.getBlockSize(liveFileSize) else CryptoEngine.LARGE_BLOCK_SIZE
            
            outputStream.use { fos ->
                val outChannel = (fos as? java.io.FileOutputStream)?.channel 
                    ?: throw IllegalArgumentException("OutputStream must be a FileOutputStream to access channel")

                for ((index, hash) in layoutHashes.withIndex()) {
                    val blockFile = File(versionStorePath, hash)
                    
                    if (blockFile.exists()) {
                        // Fast path: block is in version store
                        java.io.FileInputStream(blockFile).channel.use { inChannel ->
                            inChannel.transferTo(0, inChannel.size(), outChannel)
                        }
                    } else if (liveFileChannel != null) {
                        // Slow path: block must be in the live file (unchanged)
                        val offset = index * liveBlockSize.toLong()
                        
                        var bytesToRead = liveBlockSize.toLong()
                        if (offset + bytesToRead > liveFileSize) {
                            bytesToRead = liveFileSize - offset
                        }
                        
                        if (bytesToRead > 0) {
                            liveFileChannel.transferTo(offset, bytesToRead, outChannel)
                        }
                    } else {
                        throw IllegalStateException("Missing block $hash for reconstruction and no live file available")
                    }
                }
            }
            return true
        } catch (e: Exception) {
            android.util.Log.e("VaultSync", "Error in reconstructFromDeltas: ${e.message}")
            return false
        }
    }
}
