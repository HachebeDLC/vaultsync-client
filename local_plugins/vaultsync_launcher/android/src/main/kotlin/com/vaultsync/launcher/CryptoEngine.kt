package com.vaultsync.launcher

import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec
import java.nio.charset.Charset

private val hexArray = "0123456789abcdef".toCharArray()
fun ByteArray.toHex(): String {
    val hexChars = CharArray(size * 2)
    for (j in indices) {
        val v = this[j].toInt() and 0xFF
        hexChars[j * 2] = hexArray[v ushr 4]
        hexChars[j * 2 + 1] = hexArray[v and 0x0F]
    }
    return String(hexChars)
}

class CryptoEngine {
    companion object {
        const val MAGIC_HEADER = "NEOSYNC"
        const val SMALL_BLOCK_SIZE = 256 * 1024
        const val LARGE_BLOCK_SIZE = 1024 * 1024
        const val BLOCK_THRESHOLD = 10 * 1024 * 1024
        const val IV_SIZE = 16
        const val PADDING_SIZE = 16
        const val OVERHEAD = 7 + IV_SIZE + PADDING_SIZE // Magic (7) + IV (16) + Padding (16)
        
        fun getBlockSize(fileSize: Long): Int {
            return if (fileSize >= BLOCK_THRESHOLD) LARGE_BLOCK_SIZE else SMALL_BLOCK_SIZE
        }
        
        fun getEncryptedBlockSize(fileSize: Long): Int {
            return getBlockSize(fileSize) + OVERHEAD
        }
        
        // Backward compatibility constants if needed elsewhere
        const val BLOCK_SIZE = 1024 * 1024
        const val ENCRYPTED_BLOCK_SIZE = BLOCK_SIZE + OVERHEAD
    }

    private val utf8 = Charsets.UTF_8
    private val magicBytes = MAGIC_HEADER.toByteArray(utf8)
    
    // Performance: Use ThreadLocal to allow lock-free parallel hashing
    private val md5ThreadLocal = object : ThreadLocal<MessageDigest>() {
        override fun initialValue() = MessageDigest.getInstance("MD5")
    }
    private val sha256ThreadLocal = object : ThreadLocal<MessageDigest>() {
        override fun initialValue() = MessageDigest.getInstance("SHA-256")
    }

    fun calculateHash(data: ByteArray, length: Int): String {
        val digest = sha256ThreadLocal.get() ?: throw IllegalStateException("ThreadLocal sha256ThreadLocal.get() returned null")
        digest.reset()
        digest.update(data, 0, length)
        return digest.digest().toHex()
    }

    fun calculateMd5(data: ByteArray, length: Int): ByteArray {
        val digest = md5ThreadLocal.get() ?: throw IllegalStateException("ThreadLocal md5ThreadLocal.get() returned null")
        digest.reset()
        digest.update(data, 0, length)
        return digest.digest()
    }

    private val encryptCipherThreadLocal = object : ThreadLocal<Cipher>() {
        override fun initialValue() = Cipher.getInstance("AES/CBC/PKCS5Padding")
    }

    private val decryptCipherThreadLocal = object : ThreadLocal<Cipher>() {
        override fun initialValue() = Cipher.getInstance("AES/CBC/PKCS5Padding")
    }

    /**
     * Encrypts a data block using AES-256-CBC into a pre-allocated buffer.
     */
    fun encryptBlock(blockData: ByteArray, dataLength: Int, secretKey: SecretKeySpec, output: ByteArray): Int {
        val iv = calculateMd5(blockData, dataLength)
        val ivSpec = IvParameterSpec(iv)
        
        val cipher = encryptCipherThreadLocal.get() ?: throw IllegalStateException("ThreadLocal encryptCipherThreadLocal.get() returned null")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey, ivSpec)
        
        System.arraycopy(magicBytes, 0, output, 0, 7)
        System.arraycopy(iv, 0, output, 7, IV_SIZE)
        
        val encryptedLength = cipher.doFinal(blockData, 0, dataLength, output, 7 + IV_SIZE)
        return 7 + IV_SIZE + encryptedLength
    }

    /**
     * Decrypts an encrypted block into a pre-allocated buffer.
     */
    /**
     * Decrypts one block. The caller only reaches this with a key when the
     * server answered `x-vaultsync-encrypted: true`, so every block must carry
     * the magic header.
     *
     * It used to copy the block through unchanged when the header was missing
     * or the block was too short. That turned a missing master key into silent
     * corruption: the raw ciphertext was written to disk as if it were the
     * save. It went unnoticed for months — PS2 memory cards on one device
     * ended up 39 bytes too long (magic + IV + padding) and unreadable by the
     * emulator, and a delta upload later patched plaintext blocks over
     * encrypted ones, leaving blobs no device could download.
     *
     * Failing here is the point: an unreadable download is recoverable, a
     * silently corrupted save is not.
     */
    fun decryptBlock(encryptedBlock: ByteArray, encryptedLength: Int, secretKey: SecretKeySpec, output: ByteArray): Int {
        // Magic (7) + IV (16) + at least one padded AES block (16).
        val minimumBlock = 7 + IV_SIZE + PADDING_SIZE
        if (encryptedLength < minimumBlock) {
            throw IllegalStateException(
                "Encrypted block too short: got $encryptedLength bytes, need at least $minimumBlock. " +
                "The stream is not VaultSync ciphertext."
            )
        }

        // Zero-allocation magic check
        var match = true
        for (i in 0 until 7) {
            if (encryptedBlock[i] != magicBytes[i]) {
                match = false
                break
            }
        }

        if (!match) {
            throw IllegalStateException(
                "Missing $MAGIC_HEADER header on an encrypted block. Either the master key is " +
                "absent — sign out and back in to re-derive it — or the stored file mixes " +
                "encrypted and plaintext blocks."
            )
        }

        val iv = ByteArray(IV_SIZE)
        System.arraycopy(encryptedBlock, 7, iv, 0, IV_SIZE)
        val ivSpec = IvParameterSpec(iv)
        
        val cipher = decryptCipherThreadLocal.get() ?: throw IllegalStateException("ThreadLocal decryptCipherThreadLocal.get() returned null")
        cipher.init(Cipher.DECRYPT_MODE, secretKey, ivSpec)
        return cipher.doFinal(encryptedBlock, 7 + IV_SIZE, encryptedLength - (7 + IV_SIZE), output, 0)
    }
}
