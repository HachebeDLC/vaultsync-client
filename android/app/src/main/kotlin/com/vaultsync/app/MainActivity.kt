package com.vaultsync.app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import android.os.PowerManager
import android.content.Context
import android.app.usage.UsageStatsManager
import android.app.usage.UsageStats
import android.app.AppOpsManager
import android.provider.Settings
import java.io.InputStream
import java.io.OutputStream
import java.io.RandomAccessFile
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.json.JSONArray
import org.json.JSONObject
import java.nio.charset.Charset
import rikka.shizuku.Shizuku
import android.content.pm.PackageManager
import android.content.ComponentName
import android.content.ServiceConnection
import android.os.IBinder
import android.net.wifi.WifiManager
import java.util.concurrent.ConcurrentHashMap
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import android.os.ParcelFileDescriptor

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.vaultsync.app/launcher"
    private val PICK_DIRECTORY_REQUEST_CODE = 9999
    private var pendingResult: MethodChannel.Result? = null
    
    private val safLock = Any()
    private val safDirCache = ConcurrentHashMap<String, DocumentFile>()

    private var shizukuService: IShizukuService? = null
    private var isBinding = false
    private val shizukuConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            shizukuService = IShizukuService.Stub.asInterface(service)
            isBinding = false; android.util.Log.i("VaultSync", "✅ SHIZUKU: Connected.")
        }
        override fun onServiceDisconnected(name: ComponentName?) {
            shizukuService = null; isBinding = false; android.util.Log.w("VaultSync", "⚠️ SHIZUKU: Disconnected.")
        }
    }

    private val userServiceArgs by lazy {
        Shizuku.UserServiceArgs(ComponentName(packageName, ShizukuService::class.java.name))
            .daemon(false).processNameSuffix("shizuku").debuggable(true).version(4)
    }

    private fun bindShizukuService() {
        if (shizukuService != null || isBinding) return
        try {
            if (Shizuku.pingBinder()) {
                if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
                    isBinding = true; Shizuku.bindUserService(userServiceArgs, shizukuConnection)
                }
            } else { Shizuku.addBinderReceivedListener { bindShizukuService() } }
            Shizuku.addBinderDeadListener { shizukuService = null }
        } catch (e: Exception) { android.util.Log.e("VaultSync", "❌ SHIZUKU: Bind failed: ${e.message}") }
    }

    private fun getShizukuServiceSync(): IShizukuService {
        val current = shizukuService
        if (current != null) return current
        if (!isBinding) bindShizukuService()
        var retries = 30
        while (shizukuService == null && retries > 0) { Thread.sleep(100); retries-- }
        return shizukuService ?: throw Exception("Shizuku connection timeout.")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bindShizukuService()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getAndroidVersion" -> result.success(Build.VERSION.SDK_INT)
                "openSafDirectoryPicker" -> openSafDirectoryPicker(call.argument<String>("initialUri"), result)
                "scanRecursive" -> { safDirCache.clear(); scanRecursive(call.argument<String>("path")!!, call.argument<String>("systemId")!!, call.argument<List<String>>("ignoredFolders") ?: emptyList(), result) }
                "calculateHash" -> calculateHash(call.argument<String>("path")!!, result)
                "calculateBlockHashes" -> calculateBlockHashes(call.argument<String>("path")!!, result)
                "uploadFileNative" -> uploadFileNative(call.argument<String>("url")!!, call.argument<String>("token"), call.argument<String>("masterKey"), call.argument<String>("remotePath")!!, call.argument<String>("uri")!!, call.argument<String>("hash")!!, call.argument<String>("deviceName") ?: "Android", (call.argument<Any>("updatedAt") as? Number)?.toLong() ?: 0L, call.argument<List<Int>>("dirtyIndices"), result)
                "downloadFileNative" -> downloadFileNative(call.argument<String>("url")!!, call.argument<String>("token"), call.argument<String>("masterKey"), call.argument<String>("remoteFilename")!!, call.argument<String>("uri")!!, call.argument<String>("localFilename")!!, call.argument<Number>("updatedAt")?.toLong(), call.argument<List<Int>>("patchIndices"), result)
                "setFileTimestamp" -> setFileTimestamp(call.argument<String>("path")!!, call.argument<Number>("updatedAt")!!.toLong(), result)
                "getFileInfo" -> getFileInfo(call.argument<String>("uri")!!, result)
                "checkPathExists" -> result.success(checkPathExists(call.argument<String>("path")))
                "checkSafPermission" -> result.success(checkSafPermission(call.argument<String>("uri")!!))
                "listSafDirectory" -> listSafDirectory(call.argument<String>("uri")!!, result)
                "hasFilesWithExtensions" -> hasFilesWithExtensions(call.argument<String>("uri")!!, call.argument<List<String>>("extensions")!!, result)
                "hasUsageStatsPermission" -> result.success(hasUsageStatsPermission())
                "openUsageStatsSettings" -> { openUsageStatsSettings(); result.success(true) }
                "getRecentlyClosedEmulator" -> result.success(getRecentlyClosedEmulator(call.argument<List<String>>("packages")!!))
                "checkShizukuStatus" -> result.success(checkShizukuStatus())
                "requestShizukuPermission" -> requestShizukuPermission(result)
                "openShizukuApp" -> { openShizukuApp(); result.success(true) }
                "clearNativeCache" -> { safDirCache.clear(); result.success(true) }
                else -> result.notImplemented()
            }
        }
    }

    private fun openShizukuApp() {
        val intent = packageManager.getLaunchIntentForPackage("rikka.shizuku")
        if (intent != null) { intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK); startActivity(intent) }
        else { val marketIntent = Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=rikka.shizuku")).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }; startActivity(marketIntent) }
    }

    private fun isShizukuPath(path: String?): Boolean = path?.startsWith("shizuku://") == true
    private fun getCleanPath(path: String): String = if (path.startsWith("shizuku://")) path.substring(10) else path

    private fun safFindFileStrict(parent: DocumentFile, name: String): DocumentFile? {
        val cacheKey = "${parent.uri}/$name"
        if (safDirCache.containsKey(cacheKey)) return safDirCache[cacheKey]
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(parent.uri, DocumentsContract.getDocumentId(parent.uri))
        contentResolver.query(childrenUri, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                if (cursor.getString(1) == name) {
                    val id = cursor.getString(0)
                    val found = DocumentFile.fromSingleUri(this, DocumentsContract.buildDocumentUriUsingTree(parent.uri, id))
                    if (found != null) { safDirCache[cacheKey] = found; return found }
                }
            }
        }
        return null
    }

    private fun safGetOrCreateDirectory(parent: DocumentFile, name: String): DocumentFile {
        synchronized(safLock) {
            val existing = safFindFileStrict(parent, name); if (existing != null && existing.isDirectory) return existing
            val created = parent.createDirectory(name) ?: throw Exception("CreateDirectory failed for '$name'")
            if (created.name != name) { created.delete(); return safFindFileStrict(parent, name) ?: throw Exception("SAF Cache Desync: '$name' missing") }
            safDirCache["${parent.uri}/$name"] = created; return created
        }
    }

    private fun safGetOrCreateFile(parent: DocumentFile, name: String, mime: String): DocumentFile {
        synchronized(safLock) {
            val existing = safFindFileStrict(parent, name); if (existing != null && existing.isFile) return existing
            val created = parent.createFile(mime, name) ?: throw Exception("CreateFile failed for '$name'")
            if (created.name != name) { created.delete(); return safFindFileStrict(parent, name) ?: throw Exception("SAF Cache Desync: file '$name' missing") }
            return created
        }
    }
    
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    private fun acquireWakeLock() {
        if (wakeLock == null) { wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "VaultSync::TransferLock") }
        if (wifiLock == null) { wifiLock = (getSystemService(Context.WIFI_SERVICE) as WifiManager).createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "VaultSync::WifiLock") }
        if (wakeLock?.isHeld == false) wakeLock?.acquire(10 * 60 * 1000L); if (wifiLock?.isHeld == false) wifiLock?.acquire()
    }

    private fun releaseWakeLock() { if (wakeLock?.isHeld == true) wakeLock?.release(); if (wifiLock?.isHeld == true) wifiLock?.release() }

    private fun calculateHash(path: String, result: MethodChannel.Result) {
        Thread {
            try {
                val cleanPath = getCleanPath(path)
                if (isShizukuPath(path)) {
                    val hash = getShizukuServiceSync().calculateHash(cleanPath)
                    runOnUiThread { result.success(hash) }; return@Thread
                }
                val input = if (path.startsWith("content://")) contentResolver.openInputStream(Uri.parse(path)) else File(path).inputStream()
                val digest = MessageDigest.getInstance("SHA-256"); input?.use { stream -> val buffer = ByteArray(65536); var read: Int; while (stream.read(buffer).also { read = it } != -1) { digest.update(buffer, 0, read) } }
                runOnUiThread { result.success(digest.digest().joinToString("") { "%02x".format(it) }) }
            } catch (e: Exception) { runOnUiThread { result.error("HASH_ERROR", e.message, null) } }
        }.start()
    }

    private fun calculateBlockHashes(path: String, result: MethodChannel.Result) {
        Thread {
            try {
                val cleanPath = getCleanPath(path)
                if (isShizukuPath(path)) {
                    val hashes = getShizukuServiceSync().calculateBlockHashes(cleanPath, 1024 * 1024)
                    runOnUiThread { result.success(JSONArray(hashes).toString()) }; return@Thread
                }
                val input = if (path.startsWith("content://")) contentResolver.openInputStream(Uri.parse(path)) else File(path).inputStream()
                val blockHashes = JSONArray(); val buffer = ByteArray(1024 * 1024); input?.use { stream -> while (true) { val read = stream.read(buffer); if (read == -1) break; val digest = MessageDigest.getInstance("SHA-256"); digest.update(buffer, 0, read); blockHashes.put(digest.digest().joinToString("") { "%02x".format(it) }) } }
                runOnUiThread { result.success(blockHashes.toString()) }
            } catch (e: Exception) { runOnUiThread { result.error("BLOCK_HASH_ERROR", e.message, null) } }
        }.start()
    }

    private fun uploadFileNative(url: String, token: String?, masterKey: String?, remotePath: String, uriStr: String, hash: String, deviceName: String, updatedAt: Long, dirtyIndices: List<Int>?, result: MethodChannel.Result) {
        acquireWakeLock()
        Thread {
            var pfd: ParcelFileDescriptor? = null
            var channel: FileChannel? = null
            try {
                val utf8 = Charsets.UTF_8; val magic = "VAULTSYNC".toByteArray(utf8); val keyBytes = if (masterKey != null) android.util.Base64.decode(masterKey, android.util.Base64.URL_SAFE).sliceArray(0 until 32) else null
                
                if (isShizukuPath(uriStr)) {
                    pfd = getShizukuServiceSync().openFile(getCleanPath(uriStr), "r") ?: throw Exception("PFD failed")
                    channel = FileInputStream(pfd!!.fileDescriptor).channel
                } else if (uriStr.startsWith("content://")) {
                    pfd = contentResolver.openFileDescriptor(Uri.parse(uriStr), "r") ?: throw Exception("PFD failed")
                    channel = FileInputStream(pfd!!.fileDescriptor).channel
                } else {
                    val raf = RandomAccessFile(File(uriStr), "r")
                    channel = raf.channel
                }

                val fileSizeForFinalize = channel!!.size()
                val blockSize = 1024 * 1024; val totalBlocks = if (fileSizeForFinalize == 0L) 1 else ((fileSizeForFinalize + blockSize - 1) / blockSize).toInt(); val indicesToSync = dirtyIndices ?: (0 until totalBlocks).toList()
                
                for (index in indicesToSync) {
                    val offset = index.toLong() * blockSize
                    val buffer = ByteBuffer.allocate(blockSize)
                    channel!!.position(offset)
                    val bytesRead = channel!!.read(buffer)
                    if (bytesRead == -1 && index != 0) continue
                    val blockData = if (bytesRead <= 0) ByteArray(0) else buffer.array().sliceArray(0 until bytesRead)
                    
                    val finalData: ByteArray = if (keyBytes != null && blockData.isNotEmpty()) {
                        val iv = MessageDigest.getInstance("SHA-256").digest(blockData).sliceArray(0 until 16); val cipher = Cipher.getInstance("AES/CBC/PKCS7Padding").apply { init(Cipher.ENCRYPT_MODE, SecretKeySpec(keyBytes, "AES"), IvParameterSpec(iv)) }
                        val encrypted = cipher.doFinal(blockData); val out = java.io.ByteArrayOutputStream(); out.write(magic); out.write(iv); out.write(encrypted); out.toByteArray()
                    } else { blockData }
                    
                    val connection = (java.net.URL(url).openConnection() as java.net.HttpURLConnection).apply { requestMethod = "POST"; doOutput = true; setFixedLengthStreamingMode(finalData.size.toLong()); setRequestProperty("Content-Type", "application/octet-stream"); setRequestProperty("x-vaultsync-path", remotePath); setRequestProperty("x-vaultsync-index", index.toString()); val overhead = if (keyBytes != null) (9 + 16 + 16) else 0; setRequestProperty("x-vaultsync-offset", (index.toLong() * (blockSize + overhead)).toString()); if (token != null) setRequestProperty("Authorization", "Bearer $token") }
                    connection.outputStream.use { it.write(finalData); it.flush() }; if (connection.responseCode != 200) throw Exception("Block $index: HTTP ${connection.responseCode}"); connection.disconnect()
                }

                val finalizeConn = (java.net.URL(if (url.endsWith("/")) "${url}finalize" else "$url/finalize").openConnection() as java.net.HttpURLConnection).apply { requestMethod = "POST"; doOutput = true; setRequestProperty("Content-Type", "application/json"); if (token != null) setRequestProperty("Authorization", "Bearer $token") }
                finalizeConn.outputStream.use { it.write(JSONObject().apply { put("path", remotePath); put("hash", hash); put("size", fileSizeForFinalize); put("updated_at", updatedAt); put("device_name", deviceName) }.toString().toByteArray(utf8)) }
                if (finalizeConn.responseCode != 200) throw Exception("Finalization failed"); finalizeConn.disconnect(); runOnUiThread { result.success(true) }
            } catch (e: Exception) { android.util.Log.e("VaultSync", "Upload failed: ${e.message}", e); runOnUiThread { result.error("UPLOAD_ERROR", e.message, null) } } 
            finally { 
               try { channel?.close() } catch(_: Exception) {}
               try { pfd?.close() } catch(_: Exception) {}
               releaseWakeLock() 
            }
        }.start()
    }

    private fun setFileTimestamp(path: String, updatedAt: Long, result: MethodChannel.Result? = null) {
        Thread {
            try {
                var success = false
                if (path.startsWith("content://")) { android.util.Log.i("VaultSync", "Note: No touch for SAF.") } 
                else if (isShizukuPath(path)) { success = getShizukuServiceSync().setLastModified(getCleanPath(path), updatedAt) } 
                else { val file = File(path); if (file.exists()) success = file.setLastModified(updatedAt) }
                runOnUiThread { result?.success(success) }
            } catch (e: Exception) { runOnUiThread { result?.success(false) } }
        }.start()
    }

    private fun downloadFileNative(url: String, token: String?, masterKey: String?, remoteFilename: String, uriStr: String, localFilename: String, updatedAt: Long?, patchIndices: List<Int>?, result: MethodChannel.Result) {
        acquireWakeLock()
        Thread {
            var connection: java.net.HttpURLConnection? = null; var parentDir: DocumentFile? = null; var safTmp: DocumentFile? = null
            var channel: FileChannel? = null
            var pfd: ParcelFileDescriptor? = null
            var srcPfd: ParcelFileDescriptor? = null
            try {
                if (localFilename.split("/").any { it == ".." || it == "." }) throw Exception("Invalid path")
                val utf8 = Charsets.UTF_8; val magic = "VAULTSYNC".toByteArray(utf8); val keyBytes = if (masterKey != null) android.util.Base64.decode(masterKey, android.util.Base64.URL_SAFE).sliceArray(0 until 32) else null
                
                val downloadUrl = if (patchIndices != null) (if (url.endsWith("download")) url.replace("download", "blocks/download") else "$url/blocks/download") else url
                connection = (java.net.URL(downloadUrl).openConnection() as java.net.HttpURLConnection).apply { requestMethod = "POST"; doOutput = true; setRequestProperty("Content-Type", "application/json"); if (token != null) setRequestProperty("Authorization", "Bearer $token") }
                val reqBody = JSONObject().put("path", remoteFilename)
                if (patchIndices != null) reqBody.put("indices", JSONArray(patchIndices)) else reqBody.put("filename", remoteFilename)
                connection!!.outputStream.use { it.write(reqBody.toString().toByteArray(utf8)) }
                if (connection!!.responseCode != 200) throw Exception("Download failed: HTTP ${connection!!.responseCode}")
                
                val blockSize = 1024 * 1024; val encryptedBlockSize = blockSize + 9 + 16 + 16
                val targetPath: String?

                if (isShizukuPath(uriStr)) {
                    val cleanBase = getCleanPath(uriStr); targetPath = if (cleanBase.endsWith("/")) "$cleanBase$localFilename" else "$cleanBase/$localFilename"; val tmpPath = "$targetPath.vstmp"
                    val service = getShizukuServiceSync()
                    pfd = service.openFile(tmpPath, "rw") ?: throw Exception("PFD failed")
                    channel = FileOutputStream(pfd!!.fileDescriptor).channel
                    if (patchIndices != null) { srcPfd = service.openFile(targetPath, "r"); if (srcPfd != null) FileInputStream(srcPfd!!.fileDescriptor).use { it.copyTo(FileOutputStream(pfd!!.fileDescriptor)) } }
                } else if (uriStr.startsWith("content://")) {
                    val root = DocumentFile.fromTreeUri(this, Uri.parse(uriStr)) ?: throw Exception("Invalid Root"); var dir = root; val pathParts = localFilename.split("/")
                    for (i in 0 until pathParts.size - 1) { if (pathParts[i].isEmpty()) continue; dir = safGetOrCreateDirectory(dir, pathParts[i]) }
                    parentDir = dir; val finalName = pathParts.last(); safTmp = safGetOrCreateFile(dir, "$finalName.vstmp", "application/octet-stream")
                    pfd = contentResolver.openFileDescriptor(safTmp!!.uri, "rw") ?: throw Exception("PFD failed")
                    channel = FileOutputStream(pfd!!.fileDescriptor).channel; targetPath = null
                    if (patchIndices != null) { val src = safFindFileStrict(dir, finalName); if (src != null) contentResolver.openInputStream(src.uri)?.use { it.copyTo(FileOutputStream(pfd!!.fileDescriptor)) } }
                } else {
                    val base = File(uriStr); val f = File(base, localFilename); if (!f.parentFile.exists()) f.parentFile.mkdirs()
                    val tmpFile = File(base, "$localFilename.vstmp"); targetPath = f.absolutePath
                    if (patchIndices != null && f.exists()) f.copyTo(tmpFile, overwrite = true)
                    channel = RandomAccessFile(tmpFile, "rw").channel
                }

                channel!!.use { output ->
                    connection!!.inputStream.use { input ->
                        val buffer = java.io.ByteArrayOutputStream(); val chunk = ByteArray(65536); var currentIdx = 0
                        while (true) {
                            val r = input.read(chunk); if (r == -1) break; buffer.write(chunk, 0, r)
                            val currentBSize = if (keyBytes != null) encryptedBlockSize else blockSize
                            while (buffer.size() >= currentBSize) {
                                val data = buffer.toByteArray(); val block = data.sliceArray(0 until currentBSize)
                                val decrypted: ByteArray = if (keyBytes != null && block.sliceArray(0..8).contentEquals(magic)) { val iv = block.sliceArray(9..24); val encrypted = block.sliceArray(25 until currentBSize); val cipher = Cipher.getInstance("AES/CBC/PKCS7Padding").apply { init(Cipher.DECRYPT_MODE, SecretKeySpec(keyBytes!!, "AES"), IvParameterSpec(iv)) }; cipher.doFinal(encrypted) } else { block }
                                val offset = (if (patchIndices != null) patchIndices[currentIdx].toLong() else currentIdx.toLong()) * blockSize
                                output.position(offset); output.write(ByteBuffer.wrap(decrypted)); currentIdx++
                                val remaining = data.size - currentBSize; buffer.reset(); if (remaining > 0) buffer.write(data, currentBSize, remaining)
                            }
                        }
                    }
                }
                
                if (isShizukuPath(uriStr)) {
                   getShizukuServiceSync().renameFile("${targetPath}.vstmp", targetPath!!); if (updatedAt != null) setFileTimestamp("shizuku://$targetPath", updatedAt)
                } else if (safTmp != null) {
                   val finalName = localFilename.split("/").last()
                   synchronized(safLock) { if (!safTmp!!.renameTo(finalName)) { val existingFinal = safFindFileStrict(parentDir!!, finalName); existingFinal?.delete(); val newFinal = parentDir!!.createFile("application/octet-stream", finalName) ?: throw Exception("Fallback failed"); contentResolver.openInputStream(safTmp!!.uri)?.use { input -> contentResolver.openOutputStream(newFinal.uri)?.use { out -> input.copyTo(out) } }; safTmp!!.delete() } }
                } else {
                   val f = File(targetPath!!); val tmp = File("$targetPath.vstmp"); if (f.exists()) f.delete(); tmp.renameTo(f); if (updatedAt != null) setFileTimestamp(f.absolutePath, updatedAt)
                }
                runOnUiThread { result.success(true) }
            } catch (e: Exception) { android.util.Log.e("VaultSync", "Download failed", e); runOnUiThread { result.error("DOWNLOAD_ERROR", e.message, null) } }
            finally { 
                connection?.disconnect()
                try { channel?.close() } catch(_: Exception) {}
                try { pfd?.close() } catch(_: Exception) {}
                try { srcPfd?.close() } catch(_: Exception) {}
                releaseWakeLock() 
            }
        }.start()
    }

    private fun scanRecursive(path: String, systemId: String, ignoredFoldersList: List<String>, result: MethodChannel.Result) {
        Thread {
            try {
                val results = JSONArray(); val allowedExts = setOf("srm", "save", "sav", "state", "ps2", "mcd", "dat", "nvmem", "eep", "vms", "vmu", "png", "bin", "db", "sfo", "bak", "bra", "brp", "brps", "brs", "brss", "vfs")
                val combinedIgnores = (setOf("cache", "shaders", "resourcepack", "load", "log", "logs", "temp", "tmp") + ignoredFoldersList.map { it.lowercase() }).toSet()
                fun shouldIgnore(name: String, relPath: String): Boolean = combinedIgnores.contains(name.lowercase()) || ignoredFoldersList.any { i -> relPath.lowercase() == i.lowercase() || relPath.lowercase().endsWith("/${i.lowercase()}") }
                
                if (path.startsWith("content://")) {
                    val uri = Uri.parse(path); val treeUri = if (DocumentsContract.isTreeUri(uri)) DocumentsContract.buildTreeDocumentUri(uri.authority, DocumentsContract.getTreeDocumentId(uri)) else uri; val startDocId = try { DocumentsContract.getTreeDocumentId(uri) } catch (e: Exception) { null }
                    if (startDocId != null) {
                        fun walkSaf(currentDocId: String, currentRelPath: String, depth: Int) {
                            if (depth > 15) return
                            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, currentDocId)
                            contentResolver.query(childrenUri, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_SIZE, DocumentsContract.Document.COLUMN_LAST_MODIFIED), null, null, null)?.use { cursor ->
                                while (cursor.moveToNext()) {
                                    val id = cursor.getString(0); val name = cursor.getString(1) ?: "unknown"; val mime = cursor.getString(2); val relPath = if (currentRelPath.isEmpty()) name else "$currentRelPath/$name"
                                    if (shouldIgnore(name, relPath)) continue
                                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) { results.put(JSONObject().apply { put("name", name); put("relPath", relPath); put("isDirectory", true); put("uri", DocumentsContract.buildDocumentUriUsingTree(treeUri, id).toString()) }); walkSaf(id, relPath, depth + 1) } 
                                    else { if (systemId.lowercase() == "switch" || relPath.contains("nand/user/save") || allowedExts.contains(name.split(".").last().lowercase())) { results.put(JSONObject().apply { put("name", name); put("relPath", relPath); put("isDirectory", false); put("size", cursor.getLong(3)); put("lastModified", cursor.getLong(4)); put("uri", DocumentsContract.buildDocumentUriUsingTree(treeUri, id).toString()) }) } }
                                }
                            }
                        }
                        walkSaf(startDocId, "", 0)
                    }
                } else if (isShizukuPath(path)) {
                    val cleanBase = getCleanPath(path); val service = getShizukuServiceSync()
                    fun walkShizuku(currentPath: String, currentRelPath: String, depth: Int) {
                        if (depth > 15) return
                        val jsonInfo = service.listFileInfo(currentPath)
                        val files = JSONArray(jsonInfo)
                        for (i in 0 until files.length()) {
                            val f = files.getJSONObject(i); val name = f.getString("name"); val relPath = if (currentRelPath.isEmpty()) name else "$currentRelPath/$name"
                            if (shouldIgnore(name, relPath)) continue
                            if (f.getBoolean("isDirectory")) {
                                results.put(JSONObject().apply { put("name", name); put("relPath", relPath); put("isDirectory", true); put("uri", "shizuku://$currentPath/$name") })
                                walkShizuku("$currentPath/$name", relPath, depth + 1)
                            } else {
                                if (systemId.lowercase() == "switch" || relPath.contains("nand/user/save") || allowedExts.contains(name.split(".").last().lowercase())) {
                                    results.put(JSONObject().apply { put("name", name); put("relPath", relPath); put("isDirectory", false); put("size", f.getLong("size")); put("lastModified", f.getLong("lastModified")); put("uri", "shizuku://$currentPath/$name") })
                                }
                            }
                        }
                    }
                    walkShizuku(cleanBase, "", 0)
                } else {
                    fun walkLocal(dir: File, currentRelPath: String) {
                        dir.listFiles()?.forEach { file ->
                            val relPath = if (currentRelPath.isEmpty()) file.name else "$currentRelPath/${file.name}"
                            if (shouldIgnore(file.name, relPath)) return@forEach
                            if (file.isDirectory) { results.put(JSONObject().apply { put("name", file.name); put("relPath", relPath); put("isDirectory", true); put("uri", file.absolutePath) }); walkLocal(file, relPath) } 
                            else { if (systemId.lowercase() == "switch" || relPath.contains("nand/user/save") || allowedExts.contains(file.name.split(".").last().lowercase())) { results.put(JSONObject().apply { put("name", file.name); put("relPath", relPath); put("isDirectory", false); put("size", file.length()); put("lastModified", file.lastModified()); put("uri", file.absolutePath) }) } }
                        }
                    }
                    walkLocal(File(path), "")
                }
                runOnUiThread { result.success(results.toString()) }
            } catch (e: Exception) { runOnUiThread { result.error("SCAN_ERROR", e.message, null) } }
        }.start()
    }

    private fun getFileInfo(uriStr: String, result: MethodChannel.Result) {
        Thread {
            try {
                if (isShizukuPath(uriStr)) {
                    val path = getCleanPath(uriStr); val service = getShizukuServiceSync(); val size = service.getFileSize(path) ?: -1L
                    if (size != -1L) runOnUiThread { result.success(mapOf("size" to size, "lastModified" to (service.getLastModified(path) ?: 0L))) }
                    else runOnUiThread { result.error("NOT_FOUND", "File not found", null) }
                } else {
                    val f = if (uriStr.startsWith("content://")) DocumentFile.fromSingleUri(this, Uri.parse(uriStr)) else DocumentFile.fromFile(File(uriStr))
                    if (f != null && f.exists()) runOnUiThread { result.success(mapOf("size" to f.length(), "lastModified" to f.lastModified())) } else runOnUiThread { result.error("NOT_FOUND", "File not found", null) }
                }
            } catch (e: Exception) { runOnUiThread { result.error("INFO_ERROR", e.message, null) } }
        }.start()
    }

    private fun checkPathExists(path: String?): Boolean {
        if (path == null) return false
        return if (path.startsWith("content://")) { try { DocumentFile.fromTreeUri(this, Uri.parse(path))?.exists() ?: false } catch (e: Exception) { false } } 
        else if (isShizukuPath(path)) (getShizukuServiceSync().getFileSize(getCleanPath(path)) ?: -1L) != -1L 
        else File(path).exists()
    }

    private fun checkSafPermission(uriStr: String): Boolean {
        if (!uriStr.startsWith("content://")) return true
        val targetUriStr = Uri.parse(uriStr).toString(); val permissions = contentResolver.persistedUriPermissions
        for (p in permissions) { if (p.uri.toString() == targetUriStr && p.isWritePermission) return true }
        return false
    }

    private fun listSafDirectory(uriStr: String, result: MethodChannel.Result) {
        Thread {
            try {
                val results = JSONArray()
                if (uriStr.startsWith("content://")) {
                    val rootUri = Uri.parse(uriStr); val treeId = DocumentsContract.getTreeDocumentId(rootUri); val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(rootUri, treeId)
                    contentResolver.query(childrenUri, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE), null, null, null)?.use { cursor ->
                        while (cursor.moveToNext()) {
                            val id = cursor.getString(0); val name = cursor.getString(1); val mime = cursor.getString(2); val isDir = mime == DocumentsContract.Document.MIME_TYPE_DIR; val itemUri = DocumentsContract.buildDocumentUriUsingTree(rootUri, id)
                            results.put(JSONObject().apply { put("name", name); put("uri", itemUri.toString()); put("isDirectory", isDir) })
                        }
                    }
                } else if (isShizukuPath(uriStr)) {
                    val cleanPath = getCleanPath(uriStr); val service = getShizukuServiceSync()
                    val json = service.listFileInfo(cleanPath)
                    val files = JSONArray(json)
                    for (i in 0 until files.length()) {
                        val f = files.getJSONObject(i)
                        results.put(JSONObject().apply { put("name", f.getString("name")); put("uri", "shizuku://$cleanPath/${f.getString("name")}"); put("isDirectory", f.getBoolean("isDirectory")) })
                    }
                } else {
                    val dir = File(uriStr); dir.listFiles()?.forEach { file -> results.put(JSONObject().apply { put("name", file.name); put("uri", file.absolutePath); put("isDirectory", file.isDirectory) }) }
                }
                runOnUiThread { result.success(results.toString()) }
            } catch (e: Exception) { runOnUiThread { result.error("LIST_ERROR", e.message, null) } }
        }.start()
    }

    private fun checkShizukuStatus(): Map<String, Any> {
        val status = mutableMapOf<String, Any>()
        try {
            if (Shizuku.pingBinder()) {
                status["running"] = true; status["authorized"] = Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED; status["version"] = Shizuku.getLatestServiceVersion()
            } else { status["running"] = false; status["authorized"] = false }
        } catch (e: Exception) { status["running"] = false; status["authorized"] = false; status["error"] = e.message ?: "Error" }
        return status
    }

    private fun requestShizukuPermission(result: MethodChannel.Result) {
        if (!Shizuku.pingBinder()) { result.error("SHIZUKU_NOT_RUNNING", "Shizuku is not running", null); return }
        if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) { result.success(true); return }
        val permissionListener = object : Shizuku.OnRequestPermissionResultListener {
            override fun onRequestPermissionResult(requestCode: Int, grantResult: Int) {
                Shizuku.removeRequestPermissionResultListener(this)
                runOnUiThread { result.success(grantResult == PackageManager.PERMISSION_GRANTED) }
            }
        }; Shizuku.addRequestPermissionResultListener(permissionListener); Shizuku.requestPermission(1001)
    }

    private fun hasUsageStatsPermission(): Boolean {
        val appOps = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) appOps.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, android.os.Process.myUid(), packageName) else appOps.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, android.os.Process.myUid(), packageName)
        return mode == AppOpsManager.MODE_ALLOWED
    }

    private fun openUsageStatsSettings() { startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)) }

    private fun getRecentlyClosedEmulator(emulatorPackages: List<String>): String? {
        if (!hasUsageStatsPermission()) return null
        val usageStatsManager = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val time = System.currentTimeMillis(); val stats = usageStatsManager.queryUsageStats(UsageStatsManager.INTERVAL_DAILY, time - 300000, time)
        if (stats == null || stats.isEmpty()) return null
        return stats.filter { emulatorPackages.contains(it.packageName) }.maxByOrNull { it.lastTimeUsed }?.packageName
    }

    private fun hasFilesWithExtensions(uriStr: String, extensions: List<String>, result: MethodChannel.Result) {
        Thread {
            try {
                val rootUri = Uri.parse(uriStr); val docId = DocumentsContract.getDocumentId(rootUri)
                fun checkRecursive(currentDocId: String, depth: Int): Boolean {
                    if (depth > 3) return false
                    val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(rootUri, currentDocId)
                    contentResolver.query(childrenUri, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE), null, null, null)?.use { cursor ->
                        while (cursor.moveToNext()) {
                            val id = cursor.getString(0); val name = cursor.getString(1).lowercase(); val mime = cursor.getString(2)
                            if (mime == DocumentsContract.Document.MIME_TYPE_DIR) { if (checkRecursive(id, depth + 1)) return true } else { if (extensions.any { name.endsWith(".$it") }) return true }
                        }
                    }
                    return false
                }
                runOnUiThread { result.success(checkRecursive(docId, 0)) }
            } catch (e: Exception) { runOnUiThread { result.error("SCAN_ERROR", e.message, null) } }
        }.start()
    }

    private fun openSafDirectoryPicker(initialUriStr: String?, result: MethodChannel.Result) {
        pendingResult = result; val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply { addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION); addCategory(Intent.CATEGORY_DEFAULT) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && initialUriStr != null) { try { intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI, Uri.parse(initialUriStr)) } catch (e: Exception) {} }
        startActivityForResult(intent, PICK_DIRECTORY_REQUEST_CODE)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == PICK_DIRECTORY_REQUEST_CODE && resultCode == Activity.RESULT_OK) { data?.data?.let { uri -> contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION); pendingResult?.success(uri.toString()) } ?: pendingResult?.success(null); pendingResult = null }
    }

    private fun manualSkip(input: InputStream, n: Long): Long {
        var remaining = n; val buffer = ByteArray(16384); while (remaining > 0) { val read = input.read(buffer, 0, Math.min(remaining, buffer.size.toLong()).toInt()); if (read == -1) break; remaining -= read }; return n - remaining
    }
}
