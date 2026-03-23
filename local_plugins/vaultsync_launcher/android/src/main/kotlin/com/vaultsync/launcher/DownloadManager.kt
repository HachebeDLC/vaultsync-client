package com.vaultsync.launcher

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.util.concurrent.ExecutorService

class DownloadManager(
    private val context: Context,
    private val networkClient: NetworkClient,
    private val cryptoEngine: CryptoEngine,
    private val fileScanner: FileScanner,
    private val executor: ExecutorService,
    private val mainHandler: android.os.Handler,
    private val isShizukuPath: (String) -> Boolean,
    private val getCleanPath: (String) -> String,
    private val getShizukuServiceSync: () -> IShizukuService,
    private val setFileTimestampInternal: (String, Long) -> Unit
) {
    fun handleDownloadFile(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")!!
        val token = call.argument<String>("token")
        val masterKey = call.argument<String>("masterKey")
        val remoteFilename = call.argument<String>("remoteFilename")!!
        val uriStr = call.argument<String>("uri")!!
        val localFilename = call.argument<String>("localFilename")!!
        val updatedAt = (call.argument<Any>("updatedAt") as? Number)?.toLong()
        val patchIndices = call.argument<List<Int>>("patchIndices")
        val fileSize = (call.argument<Any>("fileSize") as? Number)?.toLong() ?: 0L

        executor.execute {
            try {
                if (localFilename.contains("..")) throw Exception("Invalid path")
                if (localFilename.isEmpty() || localFilename.endsWith("/")) {
                    android.util.Log.w("VaultSync", "Skipping download of directory path: $localFilename")
                    mainHandler.post { result.success(true) }
                    return@execute
                }
                
                val secretKey = masterKey?.let {
                    val keyBytes = android.util.Base64.decode(it, android.util.Base64.URL_SAFE).sliceArray(0 until 32)
                    javax.crypto.spec.SecretKeySpec(keyBytes, "AES")
                }
                
                val reqBody = JSONObject().put("path", remoteFilename)
                if (patchIndices != null) reqBody.put("indices", JSONArray(patchIndices)) else reqBody.put("filename", remoteFilename)
                
                networkClient.openDownloadConnection(url, token, reqBody).use { connection ->
                    if (connection.responseCode != 200) throw Exception("Download failed: HTTP ${connection.responseCode}")

                    when {
                        isShizukuPath(uriStr) -> {
                            val baseDir = getCleanPath(uriStr)
                            val finalPath = File(baseDir, localFilename).absolutePath
                            val shizukuService = getShizukuServiceSync()
                            
                            val pfd = shizukuService.openFile(finalPath, "rw")
                            if (pfd != null) {
                                pfd.use { descriptor ->
                                    FileOutputStream(descriptor.fileDescriptor).use { fos ->
                                        if (patchIndices == null) fos.channel.truncate(0)
                                        processDownloadStream(connection.inputStream, fos.channel, secretKey, patchIndices, fileSize)
                                    }
                                }
                            } else {
                                throw Exception("Could not open Shizuku file: $finalPath")
                            }
                            if (updatedAt != null) setFileTimestampInternal("shizuku://$finalPath", updatedAt)
                        }
                        uriStr.startsWith("content://") -> {
                            val treeUri = Uri.parse(uriStr)
                            val rootDoc = DocumentFile.fromTreeUri(context, treeUri)!!
                            
                            val pathParts = localFilename.split("/")
                            var currentDir = rootDoc
                            for (i in 0 until pathParts.size - 1) {
                                currentDir = fileScanner.getOrCreateDirectory(currentDir, pathParts[i])
                            }
                            
                            val finalName = pathParts.last()
                            val targetFile = fileScanner.getOrCreateFile(currentDir, finalName, "application/octet-stream")
                            
                            val pfd = context.contentResolver.openFileDescriptor(targetFile.uri, "rw")
                            if (pfd != null) {
                                pfd.use { descriptor ->
                                    FileOutputStream(descriptor.fileDescriptor).use { fos ->
                                        if (patchIndices == null) fos.channel.truncate(0)
                                        processDownloadStream(connection.inputStream, fos.channel, secretKey, patchIndices, fileSize)
                                    }
                                }
                            } else {
                                throw Exception("Could not open SAF file descriptor")
                            }
                            if (updatedAt != null) setFileTimestampInternal(targetFile.uri.toString(), updatedAt)
                        }
                        else -> {
                            val finalFile = File(File(uriStr), localFilename)
                            finalFile.parentFile?.mkdirs()
                            
                            if (finalFile.exists() && finalFile.isDirectory) {
                                finalFile.deleteRecursively()
                            }
                            
                            java.io.RandomAccessFile(finalFile, "rw").use { raf ->
                                if (patchIndices == null) raf.setLength(0)
                                processDownloadStream(connection.inputStream, raf.channel, secretKey, patchIndices, fileSize)
                            }
                            if (updatedAt != null) setFileTimestampInternal(finalFile.absolutePath, updatedAt)
                        }
                    }
                }
                mainHandler.post { result.success(true) }
            } catch (e: Exception) {
                android.util.Log.e("VaultSync", "Download failed: ${e.message}", e)
                mainHandler.post { result.error("DOWNLOAD_ERROR", e.message, null) }
            }
        }
    }

    private fun processDownloadStream(inputStream: InputStream, output: FileChannel, secretKey: javax.crypto.spec.SecretKeySpec?, patchIndices: List<Int>?, fileSize: Long) {
        val plainBlockSize = CryptoEngine.getBlockSize(fileSize)
        val expectedBlockSize = if (secretKey != null) CryptoEngine.getEncryptedBlockSize(fileSize) else plainBlockSize

        if (secretKey == null) {
            java.nio.channels.Channels.newChannel(inputStream).use { source ->
                if (patchIndices == null) {
                    output.transferFrom(source, 0, Long.MAX_VALUE)
                } else {
                    for (index in patchIndices) {
                        val offset = index.toLong() * plainBlockSize
                        var transferred = 0L
                        while (transferred < plainBlockSize) {
                            val r = output.transferFrom(source, offset + transferred, plainBlockSize - transferred)
                            if (r <= 0) break
                            transferred += r
                        }
                    }
                }
            }
            return
        }

        val ringBuffer = ByteBuffer.allocate(expectedBlockSize * 2)
        val block = ByteArray(expectedBlockSize)
        val decryptedBuffer = ByteArray(expectedBlockSize + 32)
        var currentIdx = 0
        
        inputStream.use { input ->
            val chunk = ByteArray(65536)
            while (true) {
                val readCount = input.read(chunk)
                if (readCount == -1) break
                
                ringBuffer.put(chunk, 0, readCount)
                ringBuffer.flip()
                while (ringBuffer.remaining() >= expectedBlockSize) {
                    ringBuffer.get(block, 0, expectedBlockSize)
                    val decryptedLength = cryptoEngine.decryptBlock(block, expectedBlockSize, secretKey, decryptedBuffer)
                    
                    val blockIndex = if (patchIndices != null) patchIndices[currentIdx].toLong() else currentIdx.toLong()
                    val offset = blockIndex * plainBlockSize
                    output.position(offset)
                    output.write(ByteBuffer.wrap(decryptedBuffer, 0, decryptedLength))
                    currentIdx++
                }
                ringBuffer.compact()
            }
        }
    }
}
