package com.vaultsync.launcher

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import android.system.Os
import androidx.documentfile.provider.DocumentFile
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
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
    // -------------------------------------------------------------------
    // Local pre-download backup
    // -------------------------------------------------------------------

    private val backupRoot: File get() = File(context.filesDir, "local_backups")
    private val maxLocalBackups = 3

    private fun backupToLocalStore(source: InputStream, relPath: String, size: Long): File? {
        if (size <= 0L) return null
        backupRoot.mkdirs()
        val safeName = relPath.replace("/", "_").replace("\\", "_")
        val timestamp = System.currentTimeMillis()
        val dest = File(backupRoot, "${safeName}~${timestamp}")
        return try {
            dest.outputStream().use { out -> source.copyTo(out) }
            if (dest.length() != size) {
                throw Exception("Backup size mismatch: expected $size bytes, got ${dest.length()}")
            }
            rotateLocalBackups(safeName)
            dest
        } catch (e: Exception) {
            dest.delete()
            android.util.Log.w("VaultSync", "Local backup failed for $relPath: ${e.message}")
            null
        }
    }

    private fun isSafeRelativePath(path: String): Boolean {
        if (path.isBlank() || path.startsWith("/") || path.startsWith("\\") || path.endsWith("/")) {
            return false
        }
        if (path.contains("\\")) return false
        return path.split("/").all { it.isNotEmpty() && it != "." && it != ".." }
    }

    private fun rotateLocalBackups(safeName: String) {
        val entries = backupRoot.listFiles { f -> f.name.startsWith("${safeName}~") }
            ?.sortedBy { it.lastModified() } ?: return
        entries.dropLast(maxLocalBackups).forEach { it.delete() }
    }

    fun handleDownloadFile(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url") ?: return result.error("ARG_MISSING", "url is missing", null)
        val token = call.argument<String>("token")
        val masterKey = call.argument<String>("masterKey")
        val remoteFilename = call.argument<String>("remoteFilename") ?: return result.error("ARG_MISSING", "remoteFilename is missing", null)
        val uriStr = call.argument<String>("uri") ?: return result.error("ARG_MISSING", "uri is missing", null)
        val localFilename = call.argument<String>("localFilename") ?: return result.error("ARG_MISSING", "localFilename is missing", null)
        val updatedAt = (call.argument<Any>("updatedAt") as? Number)?.toLong()
        val patchIndices = call.argument<List<Int>>("patchIndices")
        val versionId = call.argument<String>("versionId")
        val fileSize = (call.argument<Any>("fileSize") as? Number)?.toLong()
            ?: return result.error("ARG_MISSING", "fileSize is missing", null)
        if (fileSize < 0L) return result.error("ARG_INVALID", "fileSize cannot be negative", null)

        executor.execute {
            var rollback: (() -> Unit)? = null
            try {
                if (!isSafeRelativePath(localFilename)) throw Exception("Invalid relative path")
                
                var secretKey = masterKey?.let {
                    val keyBytes = android.util.Base64.decode(it, android.util.Base64.URL_SAFE).sliceArray(0 until 32)
                    javax.crypto.spec.SecretKeySpec(keyBytes, "AES")
                }
                
                val reqBody = JSONObject().put("path", remoteFilename)
                if (versionId != null) reqBody.put("version_id", versionId)
                if (patchIndices != null) reqBody.put("indices", JSONArray(patchIndices))
                else reqBody.put("filename", remoteFilename)
                
                var boundShizuku: IShizukuService? = null

                networkClient.openDownloadConnection(url, token, reqBody).use { connection ->
                    if (connection.responseCode != 200) throw Exception("Download failed: HTTP ${connection.responseCode}")

                    val isEncryptedHeader = connection.getHeaderField("x-vaultsync-encrypted")
                    if (isEncryptedHeader == "false") {
                        secretKey = null
                    }

                    when {
                        isShizukuPath(uriStr) -> {
                            val baseDir = getCleanPath(uriStr)
                            val finalPath = File(baseDir, localFilename).absolutePath
                            
                            // Bind ONCE and reuse
                            val svc = getShizukuServiceSync()
                            boundShizuku = svc

                            // Snapshot existing file before overwrite or patch.
                            val existingSize = try { svc.getFileSize(finalPath) } catch (_: Exception) { -1L }
                            if (patchIndices != null && existingSize < 0L) {
                                throw Exception("Refusing to patch missing file: $localFilename")
                            }
                            val backup = if (existingSize > 0L) {
                                svc.openFile(finalPath, "r")?.use { pfd ->
                                    FileInputStream(pfd.fileDescriptor).use { fis ->
                                        backupToLocalStore(fis, localFilename, existingSize)
                                    }
                                }
                            } else null
                            if (existingSize > 0L && backup == null) {
                                throw Exception("Refusing to overwrite $localFilename without a verified local backup")
                            }
                            rollback = {
                                if (backup != null) {
                                    val restorePfd = svc.openFile(finalPath, "rwt")
                                        ?: throw Exception("Could not reopen Shizuku file for rollback: $finalPath")
                                    restorePfd.use { descriptor ->
                                        FileOutputStream(descriptor.fileDescriptor).use { out ->
                                            backup.inputStream().use { input -> input.copyTo(out) }
                                        }
                                        if (svc.getFileSize(finalPath) != backup.length()) {
                                            throw Exception("Shizuku rollback size mismatch for $localFilename")
                                        }
                                    }
                                } else if (existingSize < 0L) {
                                    svc.deleteFile(finalPath)
                                } else {
                                    svc.openFile(finalPath, "rwt")?.close()
                                }
                            }

                            val pfd = svc.openFile(finalPath, "rw")
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
                            val downloadedSize = svc.getFileSize(finalPath)
                            if (downloadedSize != fileSize) {
                                throw Exception("Incomplete Shizuku download for $localFilename: expected $fileSize bytes, got $downloadedSize")
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
                            val existingTarget = fileScanner.findFileStrict(currentDir, pathParts.last())
                            if (patchIndices != null && existingTarget == null) {
                                throw Exception("Refusing to patch missing file: $localFilename")
                            }
                            val targetFile = existingTarget
                                ?: fileScanner.getOrCreateFile(currentDir, pathParts.last(), "application/octet-stream")
                            if (!targetFile.isFile) {
                                throw Exception("Refusing to replace SAF directory with file: $localFilename")
                            }

                            val existingSize = targetFile.length()
                            val backup = if (existingSize > 0L) {
                                context.contentResolver.openInputStream(targetFile.uri)?.use { ins ->
                                    backupToLocalStore(ins, localFilename, existingSize)
                                }
                            } else null
                            if (existingSize > 0L && backup == null) {
                                throw Exception("Refusing to overwrite $localFilename without a verified local backup")
                            }
                            rollback = {
                                context.contentResolver.openFileDescriptor(targetFile.uri, "rwt")?.use { descriptor ->
                                    FileOutputStream(descriptor.fileDescriptor).use { out ->
                                        if (backup != null) {
                                            backup.inputStream().use { input -> input.copyTo(out) }
                                        }
                                    }
                                } ?: throw Exception("Could not reopen SAF file for rollback: ${targetFile.uri}")
                                if (backup != null && targetFile.length() != backup.length()) {
                                    throw Exception("SAF rollback size mismatch for $localFilename")
                                }
                            }

                            context.contentResolver.openFileDescriptor(targetFile.uri, "rw")?.use { descriptor ->
                                FileOutputStream(descriptor.fileDescriptor).use { fos ->
                                    if (patchIndices == null) fos.channel.truncate(0)
                                    processDownloadStream(connection.inputStream, fos.channel, secretKey, patchIndices, fileSize)
                                }
                            } ?: throw Exception("Could not open SAF file descriptor")
                            
                            val downloadedSize = targetFile.length()
                            if (downloadedSize != fileSize) {
                                throw Exception("Incomplete SAF download for $localFilename: expected $fileSize bytes, got $downloadedSize")
                            }
                            if (updatedAt != null) setFileTimestampInternal(targetFile.uri.toString(), updatedAt)
                        }
                        else -> {
                            val finalFile = File(File(uriStr), localFilename)
                            finalFile.parentFile?.mkdirs()
                            if (finalFile.exists() && finalFile.isDirectory) {
                                throw Exception("Refusing to replace directory with downloaded file: ${finalFile.absolutePath}")
                            }

                            val existed = finalFile.exists()
                            if (patchIndices != null && !existed) {
                                throw Exception("Refusing to patch missing file: $localFilename")
                            }
                            val backup = if (existed && finalFile.length() > 0L) {
                                FileInputStream(finalFile).use { fis ->
                                    backupToLocalStore(fis, localFilename, finalFile.length())
                                }
                            } else null
                            if (existed && finalFile.length() > 0L && backup == null) {
                                throw Exception("Refusing to overwrite $localFilename without a verified local backup")
                            }
                            rollback = {
                                when {
                                    backup != null -> {
                                        backup.copyTo(finalFile, overwrite = true)
                                        if (finalFile.length() != backup.length()) {
                                            throw Exception("Filesystem rollback size mismatch for $localFilename")
                                        }
                                    }
                                    !existed -> finalFile.delete()
                                    else -> java.io.RandomAccessFile(finalFile, "rw").use { it.setLength(0) }
                                }
                            }

                            java.io.RandomAccessFile(finalFile, "rw").use { raf ->
                                if (patchIndices == null) raf.setLength(0)
                                processDownloadStream(connection.inputStream, raf.channel, secretKey, patchIndices, fileSize)
                            }
                            if (finalFile.length() != fileSize) {
                                throw Exception("Incomplete download for $localFilename: expected $fileSize bytes, got ${finalFile.length()}")
                            }
                            if (updatedAt != null) setFileTimestampInternal(finalFile.absolutePath, updatedAt)
                        }
                    }
                    rollback = null
                }
                
                // Return ACTUAL metadata
                try {
                    val finalInfo = when {
                        isShizukuPath(uriStr) -> {
                            val baseDir = getCleanPath(uriStr)
                            val finalPath = File(baseDir, localFilename).absolutePath
                            val svc = boundShizuku ?: getShizukuServiceSync()
                            // "shizuku://" + File(baseDir, localFilename).absolutePath is
                            // byte-identical to what scanShizukuRecursive emits for this file:
                            // it walks from the same getCleanPath(uriStr) base, joining path
                            // segments with '/' the same way File's parent+child join does.
                            mapOf(
                                "size" to svc.getFileSize(finalPath),
                                "lastModified" to svc.getLastModified(finalPath),
                                "uri" to "shizuku://$finalPath"
                            )
                        }
                        uriStr.startsWith("content://") -> {
                            // Fetch from content resolver (omitted for brevity, assume similar to original)
                            val treeUri = Uri.parse(uriStr)
                            val rootDoc = DocumentFile.fromTreeUri(context, treeUri)
                            var currentDir = rootDoc
                            val pathParts = localFilename.split("/")
                            for (i in 0 until pathParts.size - 1) {
                                currentDir = currentDir?.let { fileScanner.findFileStrict(it, pathParts[i]) }
                            }
                            var finalSize = 0L; var finalTs = 0L; var finalUri: String? = null
                            if (currentDir != null) {
                                val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(currentDir.uri, DocumentsContract.getDocumentId(currentDir.uri))
                                context.contentResolver.query(
                                    childrenUri,
                                    arrayOf(
                                        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                                        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                                        DocumentsContract.Document.COLUMN_SIZE,
                                        DocumentsContract.Document.COLUMN_LAST_MODIFIED
                                    ),
                                    null, null, null
                                )?.use { cursor ->
                                    val targetName = pathParts.last()
                                    val rows = mutableListOf<SafChildRow>()
                                    while (cursor.moveToNext()) {
                                        rows.add(
                                            SafChildRow(
                                                documentId = cursor.getString(0),
                                                displayName = cursor.getString(1),
                                                size = cursor.getLong(2),
                                                lastModified = cursor.getLong(3)
                                            )
                                        )
                                    }
                                    val match = FileScanner.selectMatchingChild(rows, targetName)
                                    if (match != null) {
                                        val docId = match.documentId
                                        finalSize = match.size
                                        finalTs = match.lastModified

                                        // Build the tree part EXACTLY the way the scanner
                                        // builds it for this same root (FileScanner.getTreeUri),
                                        // so this string is byte-identical to what
                                        // scanSafRecursive would emit for this file on the
                                        // next scan — otherwise the state row is keyed by a
                                        // URI the scanner never produces (see the sync
                                        // desync this fixes).
                                        val scannerTreeUri = fileScanner.getTreeUri(treeUri)
                                        val docUri = DocumentsContract.buildDocumentUriUsingTree(scannerTreeUri, docId)

                                        // The SAF cursor's SIZE/LAST_MODIFIED are unreliable
                                        // under Android/data (see
                                        // FileScanner.resolveScannedSizeAndMtime and the
                                        // batched fstat pass in scanSafRecursive); correct
                                        // them the same way here so the recorded state
                                        // matches what the next scan will report.
                                        try {
                                            context.contentResolver.openFileDescriptor(docUri, "r")?.use { pfd ->
                                                val stat = Os.fstat(pfd.fileDescriptor)
                                                val fstatMtime = if (stat.st_mtime > 0L) stat.st_mtime * 1000L else null
                                                val (resolvedSize, resolvedMtime) = FileScanner.resolveScannedSizeAndMtime(
                                                    cursorSize = finalSize,
                                                    cursorLastModified = finalTs,
                                                    fstatMtime = fstatMtime,
                                                    fstatSize = stat.st_size,
                                                )
                                                finalSize = resolvedSize
                                                finalTs = resolvedMtime
                                            }
                                        } catch (_: Exception) {}

                                        finalUri = docUri.toString()
                                    }
                                }
                            }
                            val resultUri = finalUri
                            if (resultUri != null) {
                                mapOf("size" to finalSize, "lastModified" to finalTs, "uri" to resultUri)
                            } else {
                                mapOf("size" to finalSize, "lastModified" to finalTs)
                            }
                        }
                        else -> {
                            val finalFile = File(File(uriStr), localFilename)
                            // finalFile.absolutePath is byte-identical to what
                            // scanLocalRecursive emits: it walks File(path) with the same
                            // root (uriStr == the scan's `path`) and joins the same segments.
                            mapOf(
                                "size" to finalFile.length(),
                                "lastModified" to finalFile.lastModified(),
                                "uri" to finalFile.absolutePath
                            )
                        }
                    }
                    mainHandler.post { result.success(finalInfo) }
                } catch (e: Exception) {
                    mainHandler.post { result.success(true) }
                }
            } catch (e: Exception) {
                try {
                    rollback?.invoke()
                    if (rollback != null) {
                        android.util.Log.w("VaultSync", "Download failed; restored previous $localFilename")
                    }
                } catch (rollbackError: Exception) {
                    android.util.Log.e("VaultSync", "Download rollback failed for $localFilename: ${rollbackError.message}", rollbackError)
                }
                android.util.Log.e("VaultSync", "Download failed: ${e.message}", e)
                mainHandler.post { result.error("DOWNLOAD_ERROR", e.message, null) }
            }
        }
    }

    fun listLocalBackups(relPath: String): List<Map<String, Any>> {
        val safeName = relPath.replace("/", "_").replace("\\", "_")
        val files = backupRoot.listFiles { f -> f.name.startsWith("${safeName}~") }
            ?.sortedByDescending { it.lastModified() } ?: return emptyList()
        return files.map { f ->
            val timestamp = f.name.substringAfterLast("~").toLongOrNull() ?: f.lastModified()
            mapOf(
                "id" to f.name,
                "timestamp" to timestamp,
                "backup_id" to f.name,
                "updated_at" to timestamp,
                "size" to f.length()
            )
        }
    }

    fun restoreLocalBackup(backupId: String, basePath: String, relPath: String): Boolean {
        // Guard against path traversal
        if (backupId.contains("/") || backupId.contains("\\") || backupId.contains("..")) return false
        if (!isSafeRelativePath(relPath)) return false
        val src = File(backupRoot, backupId)
        if (!src.exists() || !src.isFile) return false
        return try {
            when {
                isShizukuPath(basePath) -> {
                    val finalPath = File(getCleanPath(basePath), relPath).absolutePath
                    val svc = getShizukuServiceSync()
                    val pfd = svc.openFile(finalPath, "rwt") ?: return false
                    pfd.use { descriptor ->
                        FileOutputStream(descriptor.fileDescriptor).use { out ->
                            src.inputStream().use { input -> input.copyTo(out) }
                        }
                    }
                    svc.getFileSize(finalPath) == src.length()
                }
                basePath.startsWith("content://") -> {
                    val rootDoc = DocumentFile.fromTreeUri(context, Uri.parse(basePath)) ?: return false
                    val pathParts = relPath.split("/")
                    var currentDir = rootDoc
                    for (i in 0 until pathParts.size - 1) {
                        currentDir = fileScanner.getOrCreateDirectory(currentDir, pathParts[i])
                    }
                    val target = fileScanner.getOrCreateFile(
                        currentDir,
                        pathParts.last(),
                        "application/octet-stream"
                    )
                    context.contentResolver.openFileDescriptor(target.uri, "rwt")?.use { descriptor ->
                        FileOutputStream(descriptor.fileDescriptor).use { out ->
                            src.inputStream().use { input -> input.copyTo(out) }
                        }
                    } ?: return false
                    target.length() == src.length()
                }
                else -> {
                    val dest = File(basePath, relPath)
                    if (dest.exists() && dest.isDirectory) return false
                    dest.parentFile?.mkdirs()
                    src.copyTo(dest, overwrite = true)
                    dest.length() == src.length()
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("VaultSync", "restoreLocalBackup failed: ${e.message}", e)
            false
        }
    }

    private fun processDownloadStream(inputStream: InputStream, output: FileChannel, secretKey: javax.crypto.spec.SecretKeySpec?, patchIndices: List<Int>?, fileSize: Long) {
        if (secretKey == null) {
            java.nio.channels.Channels.newChannel(inputStream).use { source ->
                if (patchIndices == null) output.transferFrom(source, 0, Long.MAX_VALUE)
                else {
                    val plainBlockSize = CryptoEngine.getBlockSize(fileSize)
                    for (index in patchIndices) {
                        val offset = index.toLong() * plainBlockSize
                        val expectedBytes = minOf(plainBlockSize.toLong(), fileSize - offset)
                        if (expectedBytes <= 0L) {
                            throw java.io.EOFException("Invalid patch block index $index for $fileSize-byte file")
                        }
                        var transferred = 0L
                        while (transferred < expectedBytes) {
                            val r = output.transferFrom(source, offset + transferred, expectedBytes - transferred)
                            if (r <= 0L) {
                                throw java.io.EOFException(
                                    "Incomplete plaintext patch block $index: received $transferred of $expectedBytes bytes"
                                )
                            }
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
