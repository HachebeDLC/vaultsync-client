package com.vaultsync.launcher

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

class BinaryHeaderScanner {
    companion object {
        private const val JKSV_META_FILE = ".nx_save_meta.bin"
        private const val JKSV_MAGIC = "JKSV"
        private val JKSV_TITLE_ID_OFFSETS = listOf(5, 4, 6)
        
        private const val GCI_HEADER_SIZE = 64
    }

    data class GciMetadata(
        val gameId: String,
        val makerCode: String,
        val region: String
    )

    /**
     * Parses .nx_save_meta.bin to extract the 16-character Switch TitleID.
     */
    fun parseJksvMeta(filePath: String): String? {
        val file = File(filePath)
        if (!file.exists() || !file.isFile || file.length() < 32) return null

        try {
            RandomAccessFile(file, "r").use { raf ->
                val bytes = ByteArray(32)
                raf.readFully(bytes)
                
                // Check for JKSV magic at offset 0 (if applicable)
                // Argosy logic doesn't strictly check magic, but we can be safer
                val magic = String(bytes, 0, 4, Charsets.US_ASCII)
                // If JKSV is present, it's definitely a JKSV meta file
                
                for (offset in JKSV_TITLE_ID_OFFSETS) {
                    if (bytes.size < offset + 8) continue
                    
                    val titleIdBytes = bytes.copyOfRange(offset, offset + 8)
                    val titleId = ByteBuffer.wrap(titleIdBytes)
                        .order(ByteOrder.LITTLE_ENDIAN)
                        .getLong()
                    
                    val formatted = String.format("%016X", titleId)
                    if (formatted.startsWith("01")) {
                        return formatted
                    }
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("VaultSync", "Failed to parse JKSV meta: ${e.message}")
        }
        return null
    }

    /**
     * Parses a GCI file header to extract GameID, Maker Code, and Region.
     */
    fun parseGciHeader(filePath: String): GciMetadata? {
        val file = File(filePath)
        if (!file.exists() || !file.isFile || file.length() < GCI_HEADER_SIZE) return null

        try {
            RandomAccessFile(file, "r").use { raf ->
                val header = ByteArray(GCI_HEADER_SIZE)
                raf.readFully(header)
                
                // GCI Header layout:
                // [0-3] Game ID
                // [4-5] Maker Code
                // [9] Region (0=JAP, 1=USA, 2=EUR)
                
                val gameId = String(header, 0, 4, Charsets.US_ASCII)
                val makerCode = String(header, 4, 2, Charsets.US_ASCII)
                val regionByte = header[9].toInt()
                
                val region = when (regionByte) {
                    0 -> "JAP"
                    1 -> "USA"
                    2 -> "EUR"
                    else -> "Unknown"
                }
                
                // Basic validation: GameID should be alphanumeric
                if (gameId.all { it.isLetterOrDigit() }) {
                    return GciMetadata(gameId, makerCode, region)
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("VaultSync", "Failed to parse GCI header: ${e.message}")
        }
        return null
    }
}
