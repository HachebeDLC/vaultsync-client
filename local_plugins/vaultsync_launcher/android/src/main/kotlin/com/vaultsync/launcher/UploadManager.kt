package com.vaultsync.launcher

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.util.concurrent.ExecutorService

class UploadManager(
    private val context: android.content.Context,
    private val networkClient: NetworkClient,
    private val cryptoEngine: CryptoEngine,
    private val syncExecutor: ExecutorService,
    private val mainHandler: android.os.Handler,
    private val isShizukuPath: (String) -> Boolean,
    private val getCleanPath: (String) -> String,
    private val getShizukuServiceSync: () -> IShizukuService
) {
    fun handleUploadFile(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")!!
        val token = call.argument<String>("token")
        val masterKey = call.argument<String>("masterKey")
        val remotePath = call.argument<String>("remotePath")!!
        val uriStr = call.argument<String>("uri")!!
        val hash = call.argument<String>("hash")!!
        val deviceName = call.argument<String>("deviceName") ?: "Android"
        val updatedAt = (call.argument<Any>("updatedAt") as? Number)?.toLong() ?: 0L
        val dirtyIndices = call.argument<List<Int>>("dirtyIndices")

        syncExecutor.submit {
            try {
                val secretKey = masterKey?.let { 
                    val keyBytes = android.util.Base64.decode(it, android.util.Base64.URL_SAFE).sliceArray(0 until 32)
                    javax.crypto.spec.SecretKeySpec(keyBytes, "AES")
                }
                
                var fileSize: Long = 0
                val openResult = when {
                    isShizukuPath(uriStr) -> {
                        getShizukuServiceSync().openFile(getCleanPath(uriStr), "r")?.let { pfd ->
                            pfd.use { FileInputStream(it.fileDescriptor).use { fis -> fis.channel.use { channel -> 
                                fileSize = channel.size()
                                processUploadBlocks(channel, fileSize, dirtyIndices, secretKey, url, token, remotePath)
                            }}}
                            true
                        } ?: false
                    }
                    uriStr.startsWith("content://") -> {
                        context.contentResolver.openFileDescriptor(android.net.Uri.parse(uriStr), "r")?.let { pfd ->
                            pfd.use { FileInputStream(it.fileDescriptor).use { fis -> fis.channel.use { channel -> 
                                fileSize = channel.size()
                                processUploadBlocks(channel, fileSize, dirtyIndices, secretKey, url, token, remotePath)
                            }}}
                            true
                        } ?: false
                    }
                    else -> {
                        java.io.RandomAccessFile(File(uriStr), "r").use { raf -> raf.channel.use { channel -> 
                            fileSize = channel.size()
                            processUploadBlocks(channel, fileSize, dirtyIndices, secretKey, url, token, remotePath)
                        }}
                        true
                    }
                }

                if (!openResult) throw Exception("Failed to open file for upload")

                finalizeUpload(url, token, remotePath, hash, fileSize, updatedAt, deviceName)
                mainHandler.post { result.success(true) }
            } catch (e: Exception) {
                android.util.Log.e("VaultSync", "Upload failed: ${e.message}", e)
                mainHandler.post { result.error("UPLOAD_ERROR", e.message, null) }
            }
        }
    }

    private fun processUploadBlocks(fileChannel: FileChannel, fileSize: Long, dirtyIndices: List<Int>?, secretKey: javax.crypto.spec.SecretKeySpec?, url: String, token: String?, remotePath: String) {
        val blockSize = CryptoEngine.getBlockSize(fileSize)
        val encryptedBlockSize = CryptoEngine.getEncryptedBlockSize(fileSize)
        val totalBlocks = if (fileSize == 0L) 1 else ((fileSize + blockSize - 1) / blockSize).toInt()
        val indicesToSync = dirtyIndices ?: (0 until totalBlocks).toList()

        val futures = mutableListOf<java.util.concurrent.Future<*>>()
        
        val readBuffers = object : ThreadLocal<ByteBuffer>() {
            override fun initialValue() = ByteBuffer.allocate(blockSize)
        }
        val encryptedBuffers = object : ThreadLocal<ByteArray>() {
            override fun initialValue() = ByteArray(encryptedBlockSize)
        }

        for (index in indicesToSync) {
            val offset = index.toLong() * blockSize
            
            futures.add(syncExecutor.submit {
                val readBuffer = readBuffers.get()!!
                readBuffer.clear()
                
                val bytesRead = synchronized(fileChannel) {
                    fileChannel.position(offset)
                    var totalRead = 0
                    while (totalRead < blockSize) {
                        val r = fileChannel.read(readBuffer)
                        if (r == -1) break
                        totalRead += r
                    }
                    if (totalRead == 0) -1 else totalRead
                }
                
                if (bytesRead == -1 && index != 0) return@submit
                
                val blockData = readBuffer.array()
                val dataLength = if (bytesRead < 0) 0 else bytesRead
                
                if (secretKey != null && dataLength > 0) {
                    val encryptedBuffer = encryptedBuffers.get()!!
                    val encryptedLength = cryptoEngine.encryptBlock(blockData, dataLength, secretKey, encryptedBuffer)
                    postBlock(url, token, remotePath, index, encryptedBuffer, 0, encryptedLength, encryptedBlockSize)
                } else {
                    postBlock(url, token, remotePath, index, blockData, 0, dataLength, blockSize)
                }
            })
        }

        for (f in futures) f.get()
    }

    private fun postBlock(baseUrl: String, token: String?, remotePath: String, index: Int, data: ByteArray, offset: Int, length: Int, currentBlockSize: Int) {
        val encryptedOffset = index.toLong() * currentBlockSize
        val headers = mapOf(
            "x-vaultsync-path" to remotePath,
            "x-vaultsync-index" to index.toString(),
            "x-vaultsync-offset" to encryptedOffset.toString()
        )
        val responseCode = networkClient.postRaw(baseUrl, token, headers, data, offset, length)
        if (responseCode != 200) throw Exception("Block $index: HTTP $responseCode")
    }

    private fun finalizeUpload(url: String, token: String?, path: String, hash: String, size: Long, updatedAt: Long, deviceName: String) {
        val finalizeUrl = if (url.endsWith("/")) "${url}finalize" else "$url/finalize"
        val body = JSONObject().apply {
            put("path", path)
            put("hash", hash)
            put("size", size)
            put("updated_at", updatedAt)
            put("device_name", deviceName)
        }
        val responseCode = networkClient.postJson(finalizeUrl, token, body)
        if (responseCode != 200) throw Exception("Finalization failed: HTTP $responseCode")
    }
}
