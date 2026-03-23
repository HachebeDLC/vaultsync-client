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
        override fun initialValue() = Cipher.getInstance("AES/CBC/PKCS7Padding")
    }

    private val decryptCipherThreadLocal = object : ThreadLocal<Cipher>() {
        override fun initialValue() = Cipher.getInstance("AES/CBC/PKCS7Padding")
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
    fun decryptBlock(encryptedBlock: ByteArray, encryptedLength: Int, secretKey: SecretKeySpec, output: ByteArray): Int {
        if (encryptedLength < 7) {
            System.arraycopy(encryptedBlock, 0, output, 0, encryptedLength)
            return encryptedLength
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
            System.arraycopy(encryptedBlock, 0, output, 0, encryptedLength)
            return encryptedLength
        }
        
        val iv = ByteArray(IV_SIZE)
        System.arraycopy(encryptedBlock, 7, iv, 0, IV_SIZE)
        val ivSpec = IvParameterSpec(iv)
        
        val cipher = decryptCipherThreadLocal.get() ?: throw IllegalStateException("ThreadLocal decryptCipherThreadLocal.get() returned null")
        cipher.init(Cipher.DECRYPT_MODE, secretKey, ivSpec)
        return cipher.doFinal(encryptedBlock, 7 + IV_SIZE, encryptedLength - (7 + IV_SIZE), output, 0)
    }
}
