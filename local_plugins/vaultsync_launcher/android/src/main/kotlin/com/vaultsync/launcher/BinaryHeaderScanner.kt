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
     * Parses .nx_save_meta.bin to extract the 16-character Switch TitleID from an InputStream.
     */
    fun parseJksvMeta(inputStream: java.io.InputStream): String? {
        try {
            val bytes = inputStream.use { it.readBytes() }
            if (bytes.size < 32) return null
            
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
        } catch (e: Exception) {
            android.util.Log.e("VaultSync", "Failed to parse JKSV meta from stream: ${e.message}")
        }
        return null
    }

    /**
     * Parses a GCI file header to extract GameID, Maker Code, and Region from an InputStream.
     */
    fun parseGciHeader(inputStream: java.io.InputStream): GciMetadata? {
        try {
            val header = inputStream.use { 
                val buf = ByteArray(GCI_HEADER_SIZE)
                val read = it.read(buf)
                if (read < GCI_HEADER_SIZE) return null
                buf
            }
            
            val gameId = String(header, 0, 4, Charsets.US_ASCII)
            val makerCode = String(header, 4, 2, Charsets.US_ASCII)
            val regionByte = header[9].toInt()
            
            val region = when (regionByte) {
                0 -> "JAP"
                1 -> "USA"
                2 -> "EUR"
                else -> "Unknown"
            }
            
            if (gameId.all { it.isLetterOrDigit() }) {
                return GciMetadata(gameId, makerCode, region)
            }
        } catch (e: Exception) {
            android.util.Log.e("VaultSync", "Failed to parse GCI header from stream: ${e.message}")
        }
        return null
    }

    /**
     * Parses .nx_save_meta.bin to extract the 16-character Switch TitleID.
     */
    fun parseJksvMeta(filePath: String): String? {
        val file = File(filePath)
        if (!file.exists() || !file.isFile) return null
        return parseJksvMeta(file.inputStream())
    }

    /**
     * Parses a GCI file header to extract GameID, Maker Code, and Region.
     */
    fun parseGciHeader(filePath: String): GciMetadata? {
        val file = File(filePath)
        if (!file.exists() || !file.isFile) return null
        return parseGciHeader(file.inputStream())
    }

    /**
     * Parses PARAM.SFO (PSP metadata) to extract GameID and Title.
     */
    fun parseParamSfo(inputStream: java.io.InputStream): Map<String, String>? {
        try {
            val bytes = inputStream.use { it.readBytes() }
            if (bytes.size < 20) return null

            // PSF Magic: \x00PSF
            if (bytes[0] != 0.toByte() || bytes[1] != 'P'.toByte() || bytes[2] != 'S'.toByte() || bytes[3] != 'F'.toByte()) return null

            val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            val keyTableOffset = buffer.getInt(0x08)
            val dataTableOffset = buffer.getInt(0x0C)
            val entriesCount = buffer.getInt(0x10)

            val result = mutableMapOf<String, String>()

            for (i in 0 until entriesCount) {
                val entryOffset = 0x14 + i * 16
                val keyOffset = keyTableOffset + buffer.getShort(entryOffset).toInt()
                val dataOffset = dataTableOffset + buffer.getInt(entryOffset + 0x0C)
                val dataLen = buffer.getInt(entryOffset + 0x08)

                // Read key string
                var keyEnd = keyOffset
                while (keyEnd < bytes.size && bytes[keyEnd] != 0.toByte()) keyEnd++
                val key = String(bytes, keyOffset, keyEnd - keyOffset, Charsets.US_ASCII)

                // Read value string (assuming UTF-8 for TITLE and ASCII for ID)
                val value = String(bytes, dataOffset, dataLen).trimEnd { it == '\u0000' }

                if (key == "DISC_ID" || key == "TITLE") {
                    result[key] = value
                }
            }
            return if (result.isNotEmpty()) result else null
        } catch (e: Exception) {
            android.util.Log.e("VaultSync", "Failed to parse PARAM.SFO: ${e.message}")
        }
        return null
    }

    /**
     * Parses PARAM.SFO (PSP metadata) from a file.
     */
    fun parseParamSfo(filePath: String): Map<String, String>? {
        val file = File(filePath)
        if (!file.exists() || !file.isFile) return null
        return parseParamSfo(file.inputStream())
    }
}
