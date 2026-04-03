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
        val url = call.argument<String>("url") ?: return result.error("ARG_MISSING", "url is missing", null)
        val token = call.argument<String>("token")
        val masterKey = call.argument<String>("masterKey")
        val remoteFilename = call.argument<String>("remoteFilename") ?: return result.error("ARG_MISSING", "remoteFilename is missing", null)
        val uriStr = call.argument<String>("uri") ?: return result.error("ARG_MISSING", "uri is missing", null)
        val localFilename = call.argument<String>("localFilename") ?: return result.error("ARG_MISSING", "localFilename is missing", null)
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
                            val rootDoc = DocumentFile.fromTreeUri(context, treeUri) ?: throw Exception("Invalid tree URI")
                            
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
                
                // CRITICAL: Return the ACTUAL metadata from the file on disk.
                // This bypasses the need for Dart to call getFileInfo separately,
                // which often fails on SAF with "Unsupported Uri" errors.
                try {
                    val finalInfo = when {
                        isShizukuPath(uriStr) -> {
                            val baseDir = getCleanPath(uriStr)
                            val finalPath = File(baseDir, localFilename).absolutePath
                            val svc = getShizukuServiceSync()
                            mapOf("size" to svc.getFileSize(finalPath), "lastModified" to svc.getLastModified(finalPath))
                        }
                        uriStr.startsWith("content://") -> {
                            val treeUri = Uri.parse(uriStr)
                            val rootDoc = DocumentFile.fromTreeUri(context, treeUri)
                            var currentDir = rootDoc
                            val pathParts = localFilename.split("/")
                            for (i in 0 until pathParts.size - 1) {
                                currentDir = currentDir?.let { fileScanner.findFileStrict(it, pathParts[i]) }
                            }
                            
                            // Force a fresh query by bypassing the cache for the specific file
                            // so we get the ACTUAL size after the stream is closed.
                            var finalSize = 0L
                            var finalTs = 0L
                            if (currentDir != null) {
                                val childrenUri = android.provider.DocumentsContract.buildChildDocumentsUriUsingTree(currentDir.uri, android.provider.DocumentsContract.getDocumentId(currentDir.uri))
                                context.contentResolver.query(
                                    childrenUri,
                                    arrayOf(android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME, android.provider.DocumentsContract.Document.COLUMN_SIZE, android.provider.DocumentsContract.Document.COLUMN_LAST_MODIFIED),
                                    null, null, null
                                )?.use { cursor ->
                                    val targetName = pathParts.last()
                                    while (cursor.moveToNext()) {
                                        val name = cursor.getString(0) ?: continue
                                        if (name == targetName) {
                                            finalSize = cursor.getLong(1)
                                            finalTs = cursor.getLong(2)
                                            break
                                        }
                                    }
                                }
                            }
                            mapOf("size" to finalSize, "lastModified" to finalTs)
                        }
                        else -> {
                            val finalFile = File(File(uriStr), localFilename)
                            mapOf("size" to finalFile.length(), "lastModified" to finalFile.lastModified())
                        }
                    }
                    mainHandler.post { result.success(finalInfo) }
                } catch (e: Exception) {
                    // Fallback to simple success if metadata retrieval fails
                    mainHandler.post { result.success(true) }
                }
            } catch (e: Exception) {
                android.util.Log.e("VaultSync", "Download failed: ${e.message}", e)
                mainHandler.post { result.error("DOWNLOAD_ERROR", e.message, null) }
            }
        }
    }

    private fun processDownloadStream(inputStream: InputStream, output: FileChannel, secretKey: javax.crypto.spec.SecretKeySpec?, patchIndices: List<Int>?, fileSize: Long) {
        val plainBlockSize = CryptoEngine.getBlockSize(fileSize)
        val expectedBlockSize = if (secretKey != null) CryptoEngine.getEncryptedBlockSize(fileSize) else plainBlockSize

        // Zero-Copy Optimization: For unencrypted downloads, use transferFrom to bypass JVM heap
        if (secretKey == null) {
            java.nio.channels.Channels.newChannel(inputStream).use { source ->
                if (patchIndices == null) {
                    output.transferFrom(source, 0, Long.MAX_VALUE)
                } else {
                    for (index in patchIndices) {
                        val offset = index.toLong() * plainBlockSize
                        var transferred = 0L
                        while (transferred < plainBlockSize.toLong()) {
                            val r = output.transferFrom(source, offset + transferred, plainBlockSize.toLong() - transferred)
                            if (r <= 0) break
                            transferred += r
                        }
                    }
                }
            }
            return
        }

        inputStream.use { input ->
            decryptEncryptedStream(input, output, secretKey, cryptoEngine, patchIndices, fileSize)
        }
    }
}
