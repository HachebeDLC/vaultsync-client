package com.vaultsync.launcher

import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec
import java.nio.charset.Charset

class CryptoEngine {
    companion object {
        const val MAGIC_HEADER = "NEOSYNC"
        const val BLOCK_SIZE = 1024 * 1024
        const val IV_SIZE = 16
        const val PADDING_SIZE = 16
        const val OVERHEAD = 7 + IV_SIZE + PADDING_SIZE // Magic (7) + IV (16) + Padding (16)
        const val ENCRYPTED_BLOCK_SIZE = BLOCK_SIZE + OVERHEAD
    }

    private val utf8 = Charsets.UTF_8
    private val magicBytes = MAGIC_HEADER.toByteArray(utf8)
    private val cipher = Cipher.getInstance("AES/CBC/PKCS7Padding")
    private val md5Digest = MessageDigest.getInstance("MD5")
    private val sha256Digest = MessageDigest.getInstance("SHA-256")

    fun calculateHash(data: ByteArray, length: Int): String {
        synchronized(sha256Digest) {
            sha256Digest.reset()
            sha256Digest.update(data, 0, length)
            return sha256Digest.digest().joinToString("") { "%02x".format(it) }
        }
    }

    fun calculateMd5(data: ByteArray, length: Int): ByteArray {
        synchronized(md5Digest) {
            md5Digest.reset()
            md5Digest.update(data, 0, length)
            return md5Digest.digest()
        }
    }

    /**
     * Encrypts a data block using AES-256-CBC into a pre-allocated buffer.
     * 
     * Convergent encryption: IV is derived from the block's plaintext (MD5) so that
     * identical blocks produce identical ciphertext, enabling server-side deduplication.
     * 
     * @return Total bytes written to the output buffer.
     */
    fun encryptBlock(blockData: ByteArray, dataLength: Int, secretKey: SecretKeySpec, output: ByteArray): Int {
        val iv = calculateMd5(blockData, dataLength)
        val ivSpec = IvParameterSpec(iv)
        
        synchronized(cipher) {
            cipher.init(Cipher.ENCRYPT_MODE, secretKey, ivSpec)
            
            System.arraycopy(magicBytes, 0, output, 0, 7)
            System.arraycopy(iv, 0, output, 7, IV_SIZE)
            
            val encryptedLength = cipher.doFinal(blockData, 0, dataLength, output, 7 + IV_SIZE)
            return 7 + IV_SIZE + encryptedLength
        }
    }

    /**
     * Decrypts an encrypted block into a pre-allocated buffer.
     * @return Total bytes written to the output buffer.
     */
    fun decryptBlock(encryptedBlock: ByteArray, encryptedLength: Int, secretKey: SecretKeySpec, output: ByteArray): Int {
        if (encryptedLength < 7 || !encryptedBlock.sliceArray(0 until 7).contentEquals(magicBytes)) {
            // Not encrypted or missing magic, copy as-is
            System.arraycopy(encryptedBlock, 0, output, 0, encryptedLength)
            return encryptedLength
        }
        
        val iv = encryptedBlock.sliceArray(7 until 7 + IV_SIZE)
        val ivSpec = IvParameterSpec(iv)
        
        synchronized(cipher) {
            cipher.init(Cipher.DECRYPT_MODE, secretKey, ivSpec)
            return cipher.doFinal(encryptedBlock, 7 + IV_SIZE, encryptedLength - (7 + IV_SIZE), output, 0)
        }
    }
}
