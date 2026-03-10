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

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.vaultsync.app/launcher"
    private val PICK_DIRECTORY_REQUEST_CODE = 9999
    private var pendingResult: MethodChannel.Result? = null
    
    // Shizuku Service
    private var shizukuService: IShizukuService? = null
    private val shizukuConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            shizukuService = IShizukuService.Stub.asInterface(service)
            android.util.Log.d("VaultSync", "Shizuku Service Connected")
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            shizukuService = null
            android.util.Log.d("VaultSync", "Shizuku Service Disconnected")
        }
    }

    private val userServiceArgs by lazy {
        Shizuku.UserServiceArgs(ComponentName(packageName, ShizukuService::class.java.name))
            .daemon(false)
            .processNameSuffix("shizuku")
            .debuggable(true)
            .version(1)
    }

    private fun bindShizukuService() {
        if (shizukuService != null) return
        try {
            if (Shizuku.pingBinder()) {
                Shizuku.bindUserService(userServiceArgs, shizukuConnection)
            }
        } catch (e: Exception) {
            android.util.Log.e("VaultSync", "Shizuku bind failed", e)
        }
    }
    
    // Power Management
    private var wakeLock: PowerManager.WakeLock? = null

    private fun acquireWakeLock() {
        if (wakeLock == null) {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "VaultSync::TransferLock")
        }
        if (wakeLock?.isHeld == false) {
            wakeLock?.acquire(10 * 60 * 1000L /* 10 minutes max fallback */)
            android.util.Log.d("VaultSync", "WakeLock Acquired")
        }
    }

    private fun releaseWakeLock() {
        if (wakeLock?.isHeld == true) {
            wakeLock?.release()
            android.util.Log.d("VaultSync", "WakeLock Released")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // Initialize Shizuku binding if possible
        bindShizukuService()

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openSafDirectoryPicker" -> openSafDirectoryPicker(call.argument<String>("initialUri"), result)
                "scanRecursive" -> {
                    val path = call.argument<String>("path")!!
                    val systemId = call.argument<String>("systemId")!!
                    val ignoredFolders = call.argument<List<String>>("ignoredFolders") ?: emptyList()
                    scanRecursive(path, systemId, ignoredFolders, result)
                }
                "calculateHash" -> calculateHash(call.argument<String>("path")!!, result)
                "calculateBlockHashes" -> calculateBlockHashes(call.argument<String>("path")!!, result)
                "uploadFileNative" -> {
                    val url = call.argument<String>("url")!!
                    val token = call.argument<String>("token")
                    val masterKey = call.argument<String>("masterKey")
                    val remotePath = call.argument<String>("remotePath")!!
                    val uri = call.argument<String>("uri")!!
                    val hash = call.argument<String>("hash")!!
                    val device = call.argument<String>("deviceName") ?: "Android"
                    val updated = (call.argument<Any>("updatedAt") as? Number)?.toLong() ?: 0L
                    val dirtyIndices = call.argument<List<Int>>("dirtyIndices")
                    uploadFileNative(url, token, masterKey, remotePath, uri, hash, device, updated, dirtyIndices, result)
                }
                "downloadFileNative" -> {
                    val url = call.argument<String>("url")!!
                    val token = call.argument<String>("token")
                    val masterKey = call.argument<String>("masterKey")
                    val remoteFilename = call.argument<String>("remoteFilename")!!
                    val uri = call.argument<String>("uri")!!
                    val localFilename = call.argument<String>("localFilename")!!
                    val updatedAt = call.argument<Number>("updatedAt")?.toLong()
                    downloadFileNative(url, token, masterKey, remoteFilename, uri, localFilename, updatedAt, result)
                }
                "setFileTimestamp" -> {
                    val path = call.argument<String>("path")!!
                    val updatedAt = call.argument<Number>("updatedAt")!!.toLong()
                    setFileTimestamp(path, updatedAt, result)
                }
                "getFileInfo" -> getFileInfo(call.argument<String>("uri")!!, result)
                "checkPathExists" -> result.success(checkPathExists(call.argument<String>("path")))
                "checkSafPermission" -> result.success(checkSafPermission(call.argument<String>("uri")!!))
                "listSafDirectory" -> listSafDirectory(call.argument<String>("uri")!!, result)
                "hasFilesWithExtensions" -> {
                    val uri = call.argument<String>("uri")!!
                    val exts = call.argument<List<String>>("extensions")!!
                    hasFilesWithExtensions(uri, exts, result)
                }
                "hasUsageStatsPermission" -> result.success(hasUsageStatsPermission())
                "openUsageStatsSettings" -> {
                    openUsageStatsSettings()
                    result.success(true)
                }
                "getRecentlyClosedEmulator" -> {
                    val packages = call.argument<List<String>>("packages")!!
                    result.success(getRecentlyClosedEmulator(packages))
                }
                "checkShizukuStatus" -> result.success(checkShizukuStatus())
                "requestShizukuPermission" -> requestShizukuPermission(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun isShizukuPath(path: String?): Boolean {
        return path?.startsWith("shizuku://") == true
    }

    private fun getCleanPath(path: String): String {
        return if (path.startsWith("shizuku://")) path.substring(10) else path
    }

    private fun checkShizukuStatus(): Map<String, Any> {
        android.util.Log.d("VaultSync", "Checking Shizuku status...")
        val status = mutableMapOf<String, Any>()
        try {
            if (Shizuku.pingBinder()) {
                val isAuthorized = Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
                status["running"] = true
                status["authorized"] = isAuthorized
                status["version"] = Shizuku.getLatestServiceVersion()
                android.util.Log.d("VaultSync", "Shizuku is RUNNING (Auth: $isAuthorized)")
            } else {
                status["running"] = false
                status["authorized"] = false
                android.util.Log.d("VaultSync", "Shizuku is NOT running")
            }
        } catch (e: Exception) {
            android.util.Log.e("VaultSync", "Shizuku status check failed", e)
            status["running"] = false
            status["authorized"] = false
            status["error"] = e.message ?: "Unknown error"
        }
        return status
    }

    private fun requestShizukuPermission(result: MethodChannel.Result) {
        if (!Shizuku.pingBinder()) {
            result.error("SHIZUKU_NOT_RUNNING", "Shizuku is not running", null)
            return
        }
        
        val isAuthorized = Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
        if (isAuthorized) {
            result.success(true)
            return
        }

        val permissionListener = object : Shizuku.OnRequestPermissionResultListener {
            override fun onRequestPermissionResult(requestCode: Int, grantResult: Int) {
                Shizuku.removeRequestPermissionResultListener(this)
                runOnUiThread {
                    result.success(grantResult == PackageManager.PERMISSION_GRANTED)
                }
            }
        }
        
        Shizuku.addRequestPermissionResultListener(permissionListener)
        Shizuku.requestPermission(1001)
    }

    private fun hasUsageStatsPermission(): Boolean {
        val appOps = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, android.os.Process.myUid(), packageName)
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, android.os.Process.myUid(), packageName)
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    private fun openUsageStatsSettings() {
        startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
    }

    private fun getRecentlyClosedEmulator(emulatorPackages: List<String>): String? {
        if (!hasUsageStatsPermission()) return null
        
        val usageStatsManager = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val time = System.currentTimeMillis()
        // Check last 5 minutes to be safe
        val stats = usageStatsManager.queryUsageStats(UsageStatsManager.INTERVAL_DAILY, time - 300000, time)
        
        if (stats == null || stats.isEmpty()) return null
        
        // Return the package name of the most recently used emulator from the list
        return stats.filter { emulatorPackages.contains(it.packageName) }
                    .maxByOrNull { it.lastTimeUsed }
                    ?.packageName
    }

    private fun hasFilesWithExtensions(uriStr: String, extensions: List<String>, result: MethodChannel.Result) {
        Thread {
            try {
                val rootUri = Uri.parse(uriStr)
                val docId = DocumentsContract.getDocumentId(rootUri)
                
                fun checkRecursive(currentDocId: String, depth: Int): Boolean {
                    if (depth > 3) return false
                    
                    val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(rootUri, currentDocId)
                    contentResolver.query(childrenUri, arrayOf(
                        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                        DocumentsContract.Document.COLUMN_MIME_TYPE
                    ), null, null, null)?.use { cursor ->
                        while (cursor.moveToNext()) {
                            val id = cursor.getString(0)
                            val name = cursor.getString(1).lowercase()
                            val mime = cursor.getString(2)
                            
                            if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                                if (checkRecursive(id, depth + 1)) return true
                            } else {
                                if (name.endsWith(".txt") || name.endsWith(".png") || name.endsWith(".jpg") || name.endsWith(".nomedia")) continue
                                if (extensions.any { name.endsWith(".$it") }) return true
                            }
                        }
                    }
                    return false
                }

                val found = checkRecursive(docId, 0)
                runOnUiThread { result.success(found) }
            } catch (e: Exception) {
                runOnUiThread { result.error("SCAN_ERROR", e.message, null) }
            }
        }.start()
    }

    private fun listSafDirectory(uriStr: String, result: MethodChannel.Result) {
        Thread {
            try {
                val rootUri = Uri.parse(uriStr)
                val treeId = DocumentsContract.getTreeDocumentId(rootUri)
                val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(rootUri, treeId)
                val results = JSONArray()

                contentResolver.query(childrenUri, arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE
                ), null, null, null)?.use { cursor ->
                    while (cursor.moveToNext()) {
                        val id = cursor.getString(0)
                        val name = cursor.getString(1)
                        val mime = cursor.getString(2)
                        val isDir = mime == DocumentsContract.Document.MIME_TYPE_DIR
                        val itemUri = DocumentsContract.buildDocumentUriUsingTree(rootUri, id)

                        results.put(JSONObject().apply {
                            put("name", name)
                            put("uri", itemUri.toString())
                            put("isDirectory", isDir)
                        })
                    }
                }
                runOnUiThread { result.success(results.toString()) }
            } catch (e: Exception) {
                runOnUiThread { result.error("LIST_ERROR", e.message, null) }
            }
        }.start()
    }

    private fun checkSafPermission(uriStr: String): Boolean {
        if (!uriStr.startsWith("content://")) return true
        val targetUriStr = Uri.parse(uriStr).toString()
        val permissions = contentResolver.persistedUriPermissions
        for (p in permissions) {
            if (p.uri.toString() == targetUriStr && p.isWritePermission) return true
        }
        return false
    }

    private fun manualSkip(input: InputStream, n: Long): Long {
        var remaining = n
        val buffer = ByteArray(16384)
        while (remaining > 0) {
            val read = input.read(buffer, 0, Math.min(remaining, buffer.size.toLong()).toInt())
            if (read == -1) break
            remaining -= read
        }
        return n - remaining
    }

    private fun calculateBlockHashes(path: String, result: MethodChannel.Result) {
        Thread {
            try {
                val blockHashes = JSONArray()
                val blockSize = 1024 * 1024
                
                if (isShizukuPath(path)) {
                    val cleanPath = getCleanPath(path)
                    val service = shizukuService ?: throw Exception("Shizuku service not available")
                    
                    var offset = 0L
                    while (true) {
                        val chunk = service.readFile(cleanPath, offset, blockSize)
                        if (chunk.isEmpty()) break
                        
                        val digest = MessageDigest.getInstance("SHA-256")
                        digest.update(chunk)
                        blockHashes.put(digest.digest().joinToString("") { "%02x".format(it) })
                        
                        offset += chunk.size
                        if (chunk.size < blockSize) break
                    }
                } else {
                    val inputStream = if (path.startsWith("content://")) contentResolver.openInputStream(Uri.parse(path)) else File(path).inputStream()
                    val buffer = ByteArray(blockSize)
                    inputStream?.use { input ->
                        while (true) {
                            val read = input.read(buffer)
                            if (read == -1) break
                            // Using SHA-256 for block-level integrity
                            val digest = MessageDigest.getInstance("SHA-256")
                            digest.update(buffer, 0, read)
                            blockHashes.put(digest.digest().joinToString("") { "%02x".format(it) })
                        }
                    }
                }
                runOnUiThread { result.success(blockHashes.toString()) }
            } catch (e: Exception) { runOnUiThread { result.error("BLOCK_HASH_ERROR", e.message, null) } }
        }.start()
    }

    private fun uploadFileNative(url: String, token: String?, masterKey: String?, remotePath: String, uriStr: String, hash: String, deviceName: String, updatedAt: Long, dirtyIndices: List<Int>?, result: MethodChannel.Result) {
        acquireWakeLock()
        Thread {
            try {
                val utf8 = Charsets.UTF_8
                val magic = "VAULTSYNC".toByteArray(utf8)
                val keyBytes = if (masterKey != null) android.util.Base64.decode(masterKey, android.util.Base64.URL_SAFE).sliceArray(0 until 32) else null
                
                val plainSize = if (isShizukuPath(uriStr)) {
                    File(getCleanPath(uriStr)).length()
                } else if (uriStr.startsWith("content://")) {
                    DocumentFile.fromSingleUri(this, Uri.parse(uriStr))?.length() ?: 0L
                } else File(uriStr).length()

                val blockSize = 1024 * 1024
                val totalBlocks = if (plainSize == 0L) 1 else ((plainSize + blockSize - 1) / blockSize).toInt()
                val indicesToSync = dirtyIndices ?: (0 until totalBlocks).toList()

                for (index in indicesToSync) {
                    val offset = index.toLong() * blockSize
                    
                    val blockData: ByteArray = if (isShizukuPath(uriStr)) {
                        val service = shizukuService ?: throw Exception("Shizuku service not available")
                        service.readFile(getCleanPath(uriStr), offset, blockSize)
                    } else {
                        val currentInputStream = if (uriStr.startsWith("content://")) contentResolver.openInputStream(Uri.parse(uriStr)) else File(uriStr).inputStream()
                        currentInputStream?.use { input ->
                            if (offset > 0) {
                                val skipped = manualSkip(input, offset)
                                if (skipped < offset) throw Exception("Manual skip failed at block $index")
                            }
                            val buffer = ByteArray(blockSize)
                            val bytesRead = if (plainSize > 0) input.read(buffer) else 0
                            if (bytesRead == -1) ByteArray(0)
                            else if (bytesRead == blockSize) buffer
                            else if (bytesRead > 0) buffer.sliceArray(0 until bytesRead)
                            else ByteArray(0)
                        } ?: ByteArray(0)
                    }

                    if (blockData.isNotEmpty() || (plainSize == 0L && index == 0)) {
                        val finalData: ByteArray = if (keyBytes != null && blockData.isNotEmpty()) {
                                // Deterministic IV is required for convergent encryption
                                val iv = MessageDigest.getInstance("SHA-256").digest(blockData).sliceArray(0 until 16)
                                val cipher = Cipher.getInstance("AES/CBC/PKCS7Padding").apply {
                                    init(Cipher.ENCRYPT_MODE, SecretKeySpec(keyBytes, "AES"), IvParameterSpec(iv))
                                }
                                val encrypted = cipher.doFinal(blockData)
                                val output = java.io.ByteArrayOutputStream()
                                output.write(magic); output.write(iv); output.write(encrypted)
                                output.toByteArray()
                            } else { blockData }

                            val connection = (java.net.URL(url).openConnection() as java.net.HttpURLConnection).apply {
                                requestMethod = "POST"
                                doOutput = true
                                setFixedLengthStreamingMode(finalData.size.toLong())
                                setRequestProperty("Content-Type", "application/octet-stream")
                                setRequestProperty("x-vaultsync-path", remotePath)
                                setRequestProperty("x-vaultsync-index", index.toString())
                                // Overhead for VAULTSYNC: 9 (magic) + 16 (IV) + 16 (padding max)
                                val overhead = if (keyBytes != null) (9 + 16 + 16) else 0
                                setRequestProperty("x-vaultsync-offset", (index.toLong() * (blockSize + overhead)).toString())
                                if (token != null) setRequestProperty("Authorization", "Bearer $token")
                            }
                            connection.outputStream.use { it.write(finalData); it.flush() }
                            if (connection.responseCode != 200) throw Exception("Block $index: HTTP ${connection.responseCode}")
                            connection.disconnect()
                    }
                }

                val finalizeUrl = if (url.endsWith("/")) "${url}finalize" else "$url/finalize"
                val finalizeConn = (java.net.URL(finalizeUrl).openConnection() as java.net.HttpURLConnection).apply {
                    requestMethod = "POST"
                    doOutput = true
                    setRequestProperty("Content-Type", "application/json")
                    if (token != null) setRequestProperty("Authorization", "Bearer $token")
                }
                finalizeConn.outputStream.use { it.write(JSONObject().apply {
                    put("path", remotePath); put("hash", hash); put("size", plainSize); put("updated_at", updatedAt); put("device_name", deviceName)
                }.toString().toByteArray(utf8)) }
                if (finalizeConn.responseCode != 200) throw Exception("Finalization failed")
                finalizeConn.disconnect()

                runOnUiThread { result.success(true) }
            } catch (e: Exception) { 
                android.util.Log.e("VaultSync", "Upload failed", e)
                runOnUiThread { result.error("UPLOAD_ERROR", e.message, null) } 
            } finally { releaseWakeLock() }
        }.start()
    }

    private fun setFileTimestamp(path: String, updatedAt: Long, result: MethodChannel.Result? = null) {
        Thread {
            try {
                var success = false
                if (path.startsWith("content://")) {
                    android.util.Log.i("VaultSync", "Note: Cannot touch SAF timestamp for $path")
                } else {
                    val cleanPath = getCleanPath(path)
                    val file = File(cleanPath)
                    if (file.exists()) {
                        success = file.setLastModified(updatedAt)
                    }
                }
                runOnUiThread { result?.success(success) }
            } catch (e: Exception) {
                runOnUiThread { result?.success(false) }
            }
        }.start()
    }

    private fun downloadFileNative(url: String, token: String?, masterKey: String?, remoteFilename: String, uriStr: String, localFilename: String, updatedAt: Long?, result: MethodChannel.Result) {
        acquireWakeLock()
        Thread {
            var connection: java.net.HttpURLConnection? = null
            var output: OutputStream? = null
            var targetUri: Uri? = null
            var targetFile: File? = null
            var tempFile: File? = null

            try {
                val pathParts = localFilename.split("/")
                if (pathParts.any { it == ".." || it == "." }) {
                    throw Exception("Invalid path detected")
                }

                val utf8 = Charsets.UTF_8
                val magic = "VAULTSYNC".toByteArray(utf8)
                val keyBytes = if (masterKey != null) android.util.Base64.decode(masterKey, android.util.Base64.URL_SAFE).sliceArray(0 until 32) else null

                val urlObj = java.net.URL(url)
                connection = (urlObj.openConnection() as java.net.HttpURLConnection).apply {
                    requestMethod = "POST"
                    doOutput = true
                    setRequestProperty("Content-Type", "application/json")
                    if (token != null) setRequestProperty("Authorization", "Bearer $token")
                }
                
                connection!!.outputStream.use { it.write(JSONObject().put("filename", remoteFilename).toString().toByteArray(utf8)) }
                if (connection!!.responseCode != 200) throw Exception("Download failed: HTTP ${connection!!.responseCode}")

                if (isShizukuPath(uriStr)) {
                    val cleanBase = getCleanPath(uriStr)
                    val service = shizukuService ?: throw Exception("Shizuku service not available")
                    val targetPath = if (cleanBase.endsWith("/")) "$cleanBase$localFilename" else "$cleanBase/$localFilename"
                    val tmpPath = "$targetPath.vstmp"
                    
                    connection!!.inputStream.use { input ->
                        val buffer = java.io.ByteArrayOutputStream()
                        val chunk = ByteArray(65536)
                        val encryptedBlockSize = 1048576 + 9 + 16 + 16
                        var currentOffset = 0L
                        
                        while (true) {
                            val r = input.read(chunk)
                            if (r == -1) break
                            buffer.write(chunk, 0, r)
                            
                            while (buffer.size() >= encryptedBlockSize) {
                                val data = buffer.toByteArray()
                                val block = data.sliceArray(0 until encryptedBlockSize)
                                if (block.sliceArray(0..8).contentEquals(magic)) {
                                    val iv = block.sliceArray(9..24)
                                    val encrypted = block.sliceArray(25 until encryptedBlockSize)
                                    val cipher = Cipher.getInstance("AES/CBC/PKCS7Padding").apply {
                                        init(Cipher.DECRYPT_MODE, SecretKeySpec(keyBytes!!, "AES"), IvParameterSpec(iv))
                                    }
                                    val decrypted = cipher.doFinal(encrypted)
                                    service.writeFile(tmpPath, decrypted, currentOffset)
                                    currentOffset += decrypted.size
                                }
                                val remaining = data.size - encryptedBlockSize
                                buffer.reset()
                                if (remaining > 0) buffer.write(data, encryptedBlockSize, remaining)
                            }
                        }
                        val last = buffer.toByteArray()
                        if (last.isNotEmpty()) {
                            if (last.size > 25 && last.sliceArray(0..8).contentEquals(magic)) {
                                val iv = last.sliceArray(9..24); val enc = last.sliceArray(25 until last.size)
                                val cipher = Cipher.getInstance("AES/CBC/PKCS7Padding").apply {
                                    init(Cipher.DECRYPT_MODE, SecretKeySpec(keyBytes!!, "AES"), IvParameterSpec(iv))
                                }
                                val decrypted = cipher.doFinal(enc)
                                service.writeFile(tmpPath, decrypted, currentOffset)
                            } else {
                                service.writeFile(tmpPath, last, currentOffset)
                            }
                        }
                    }
                    
                    val fTmp = File(tmpPath)
                    val fTarget = File(targetPath)
                    if (fTarget.exists()) fTarget.delete()
                    if (!fTmp.renameTo(fTarget)) throw Exception("Atomic rename failed via Shizuku")
                    if (updatedAt != null) setFileTimestamp("shizuku://$targetPath", updatedAt)

                } else if (uriStr.startsWith("content://")) {
                    val root = DocumentFile.fromTreeUri(this, Uri.parse(uriStr))!!
                    var dir = root
                    for (i in 0 until pathParts.size - 1) { 
                        if (pathParts[i].isEmpty()) continue
                        dir = dir.findFile(pathParts[i]) ?: dir.createDirectory(pathParts[i])!! 
                    }
                    val tmpName = "${pathParts.last()}.vstmp"
                    val targetTmp = dir.findFile(tmpName) ?: dir.createFile("application/octet-stream", tmpName)!!
                    targetUri = targetTmp.uri
                    output = contentResolver.openOutputStream(targetTmp.uri, "wt")
                    connection!!.inputStream.use { input ->
                        if (keyBytes != null) {
                            val buffer = java.io.ByteArrayOutputStream()
                            val chunk = ByteArray(65536)
                            val encryptedBlockSize = 1048576 + 9 + 16 + 16
                            while (true) {
                                val r = input.read(chunk)
                                if (r == -1) break
                                buffer.write(chunk, 0, r)
                                while (buffer.size() >= encryptedBlockSize) {
                                    val data = buffer.toByteArray()
                                    val block = data.sliceArray(0 until encryptedBlockSize)
                                    if (block.sliceArray(0..8).contentEquals(magic)) {
                                        val iv = block.sliceArray(9..24)
                                        val encrypted = block.sliceArray(25 until encryptedBlockSize)
                                        val cipher = Cipher.getInstance("AES/CBC/PKCS7Padding").apply {
                                            init(Cipher.DECRYPT_MODE, SecretKeySpec(keyBytes, "AES"), IvParameterSpec(iv))
                                        }
                                        output?.write(cipher.doFinal(encrypted))
                                    }
                                    val remaining = data.size - encryptedBlockSize
                                    buffer.reset()
                                    if (remaining > 0) buffer.write(data, encryptedBlockSize, remaining)
                                }
                            }
                        } else { input.copyTo(output!!) }
                    }
                } else {
                    val base = File(uriStr)
                    val f = File(base, localFilename)
                    if (!f.parentFile.exists()) f.parentFile.mkdirs()
                    tempFile = File(base, "$localFilename.vstmp")
                    targetFile = f
                    output = tempFile!!.outputStream()
                    connection!!.inputStream.use { input ->
                        if (keyBytes != null) {
                            val buffer = java.io.ByteArrayOutputStream()
                            val chunk = ByteArray(65536)
                            val encryptedBlockSize = 1048576 + 9 + 16 + 16
                            while (true) {
                                val r = input.read(chunk)
                                if (r == -1) break
                                buffer.write(chunk, 0, r)
                                while (buffer.size() >= encryptedBlockSize) {
                                    val data = buffer.toByteArray()
                                    val block = data.sliceArray(0 until encryptedBlockSize)
                                    if (block.sliceArray(0..8).contentEquals(magic)) {
                                        val iv = block.sliceArray(9..24)
                                        val encrypted = block.sliceArray(25 until encryptedBlockSize)
                                        val cipher = Cipher.getInstance("AES/CBC/PKCS7Padding").apply {
                                            init(Cipher.DECRYPT_MODE, SecretKeySpec(keyBytes, "AES"), IvParameterSpec(iv))
                                        }
                                        output?.write(cipher.doFinal(encrypted))
                                    }
                                    val remaining = data.size - encryptedBlockSize
                                    buffer.reset()
                                    if (remaining > 0) buffer.write(data, encryptedBlockSize, remaining)
                                }
                            }
                        } else { input.copyTo(output!!) }
                    }
                }
                
                output?.close()
                output = null
                
                if (targetUri != null) {
                    val file = DocumentFile.fromSingleUri(this, targetUri)!!
                    val finalName = pathParts.last()
                    file.parentFile?.findFile(finalName)?.delete()
                    file.renameTo(finalName)
                } else if (tempFile != null && targetFile != null) {
                    if (targetFile!!.exists()) targetFile!!.delete()
                    if (!tempFile!!.renameTo(targetFile!!)) throw Exception("Atomic rename failed")
                }

                if (updatedAt != null && !isShizukuPath(uriStr)) {
                    val finalPath = if (uriStr.startsWith("content://")) {
                         val root = DocumentFile.fromTreeUri(this, Uri.parse(uriStr))!!
                         var dir = root
                         for (i in 0 until pathParts.size - 1) { dir = dir.findFile(pathParts[i]) ?: dir }
                         dir.findFile(pathParts.last())?.uri?.toString() ?: ""
                    } else targetFile!!.absolutePath
                    if (finalPath.isNotEmpty()) setFileTimestamp(finalPath, updatedAt)
                }

                runOnUiThread { result.success(true) }
            } catch (e: Exception) { 
                android.util.Log.e("VaultSync", "Download failed", e)
                runOnUiThread { result.error("DOWNLOAD_ERROR", e.message, null) } 
            } finally { 
                try { output?.close() } catch(e: Exception) {}
                connection?.disconnect()
                releaseWakeLock()
            }
        }.start()
    }


    private fun calculateHash(path: String, result: MethodChannel.Result) {
        Thread {
            try {
                val cleanPath = getCleanPath(path)
                val input = if (isShizukuPath(path)) {
                    val service = shizukuService ?: throw Exception("Shizuku service not available")
                    // We don't have a stream for Shizuku, so we read in chunks via service
                    val digest = MessageDigest.getInstance("SHA-256")
                    var offset = 0L
                    while (true) {
                        val chunk = service.readFile(cleanPath, offset, 1024 * 1024)
                        if (chunk.isEmpty()) break
                        digest.update(chunk)
                        offset += chunk.size
                    }
                    runOnUiThread { result.success(digest.digest().joinToString("") { "%02x".format(it) }) }
                    return@Thread
                } else if (path.startsWith("content://")) contentResolver.openInputStream(Uri.parse(path)) 
                else File(path).inputStream()
                
                val digest = MessageDigest.getInstance("SHA-256")
                input?.use { stream ->
                    val buffer = ByteArray(65536)
                    var read: Int
                    while (stream.read(buffer).also { read = it } != -1) { digest.update(buffer, 0, read) }
                }
                runOnUiThread { result.success(digest.digest().joinToString("") { "%02x".format(it) }) }
            } catch (e: Exception) { runOnUiThread { result.error("HASH_ERROR", e.message, null) } }
        }.start()
    }

    private fun scanRecursive(path: String, systemId: String, ignoredFoldersList: List<String>, result: MethodChannel.Result) {
        Thread {
            try {
                val results = JSONArray()
                val allowedExts = setOf("srm", "save", "sav", "state", "ps2", "mcd", "dat", "nvmem", "eep", "vms", "vmu", "png", "bin", "db", "sfo", "bak", "bra", "brp", "brps", "brs", "brss", "vfs")
                val isSwitch = systemId.lowercase() == "switch"
                val globalIgnores = setOf("cache", "shaders", "resourcepack", "load", "log", "logs", "temp", "tmp")
                val combinedIgnores = (globalIgnores + ignoredFoldersList.map { it.lowercase() }).toSet()

                fun shouldIgnore(name: String, relPath: String): Boolean {
                    val lowerName = name.lowercase()
                    if (combinedIgnores.contains(lowerName)) return true
                    val lowerPath = relPath.lowercase()
                    return ignoredFoldersList.any { ignore -> lowerPath == ignore.lowercase() || lowerPath.endsWith("/${ignore.lowercase()}") }
                }

                if (path.startsWith("content://")) {
                    val uri = Uri.parse(path)
                    val treeUri = if (DocumentsContract.isTreeUri(uri)) DocumentsContract.buildTreeDocumentUri(uri.authority, DocumentsContract.getTreeDocumentId(uri)) else uri
                    val startDocId = try { DocumentsContract.getTreeDocumentId(uri) } catch (e: Exception) { null }
                    if (startDocId != null) {
                        fun walkSaf(currentDocId: String, currentRelPath: String, depth: Int) {
                            if (depth > 15) return
                            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, currentDocId)
                            contentResolver.query(childrenUri, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_SIZE, DocumentsContract.Document.COLUMN_LAST_MODIFIED), null, null, null)?.use { cursor ->
                                while (cursor.moveToNext()) {
                                    val id = cursor.getString(0)
                                    val name = cursor.getString(1) ?: "unknown"
                                    val mime = cursor.getString(2)
                                    val relPath = if (currentRelPath.isEmpty()) name else "$currentRelPath/$name"
                                    if (shouldIgnore(name, relPath)) continue
                                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                                        results.put(JSONObject().apply { put("name", name); put("relPath", relPath); put("isDirectory", true); put("uri", DocumentsContract.buildDocumentUriUsingTree(treeUri, id).toString()) })
                                        walkSaf(id, relPath, depth + 1)
                                    } else {
                                        if (isSwitch || relPath.contains("nand/user/save") || allowedExts.contains(name.split(".").last().lowercase())) {
                                            results.put(JSONObject().apply { put("name", name); put("relPath", relPath); put("size", cursor.getLong(3)); put("lastModified", cursor.getLong(4)); put("uri", DocumentsContract.buildDocumentUriUsingTree(treeUri, id).toString()) })
                                        }
                                    }
                                }
                            }
                        }
                        walkSaf(startDocId, "", 0)
                    }
                } else if (isShizukuPath(path)) {
                    val cleanBase = getCleanPath(path)
                    val service = shizukuService ?: throw Exception("Shizuku service not available")
                    fun walkShizuku(currentPath: String, currentRelPath: String, depth: Int) {
                        if (depth > 15) return
                        service.listFiles(currentPath).forEach { name ->
                            val fullPath = if (currentPath.endsWith("/")) "$currentPath$name" else "$currentPath/$name"
                            val relPath = if (currentRelPath.isEmpty()) name else "$currentRelPath/$name"
                            if (shouldIgnore(name, relPath)) return@forEach
                            val f = File(fullPath)
                            if (f.isDirectory) {
                                results.put(JSONObject().apply { put("name", name); put("relPath", relPath); put("isDirectory", true); put("uri", "shizuku://$fullPath") })
                                walkShizuku(fullPath, relPath, depth + 1)
                            } else {
                                if (isSwitch || relPath.contains("nand/user/save") || allowedExts.contains(name.split(".").last().lowercase())) {
                                    results.put(JSONObject().apply { put("name", name); put("relPath", relPath); put("size", f.length()); put("lastModified", f.lastModified()); put("uri", "shizuku://$fullPath") })
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
                            if (file.isDirectory) {
                                results.put(JSONObject().apply { put("name", file.name); put("relPath", relPath); put("isDirectory", true); put("uri", file.absolutePath) })
                                walkLocal(file, relPath)
                            } else {
                                if (isSwitch || relPath.contains("nand/user/save") || allowedExts.contains(file.name.split(".").last().lowercase())) {
                                    results.put(JSONObject().apply { put("name", file.name); put("relPath", relPath); put("size", file.length()); put("lastModified", file.lastModified()); put("uri", file.absolutePath) })
                                }
                            }
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
                    val f = File(getCleanPath(uriStr))
                    if (f.exists()) runOnUiThread { result.success(mapOf("size" to f.length(), "lastModified" to f.lastModified())) }
                    else runOnUiThread { result.error("NOT_FOUND", "File not found via Shizuku", null) }
                } else {
                    val f = if (uriStr.startsWith("content://")) DocumentFile.fromSingleUri(this, Uri.parse(uriStr)) else DocumentFile.fromFile(File(uriStr))
                    if (f != null && f.exists()) runOnUiThread { result.success(mapOf("size" to f.length(), "lastModified" to f.lastModified())) }
                    else runOnUiThread { result.error("NOT_FOUND", "File not found", null) }
                }
            } catch (e: Exception) { runOnUiThread { result.error("INFO_ERROR", e.message, null) } }
        }.start()
    }

    private fun checkPathExists(path: String?): Boolean {
        if (path == null) return false
        return if (path.startsWith("content://")) {
            try { DocumentFile.fromTreeUri(this, Uri.parse(path))?.exists() ?: false } catch (e: Exception) { false }
        } else if (isShizukuPath(path)) File(getCleanPath(path)).exists()
        else File(path).exists()
    }

    private fun openSafDirectoryPicker(initialUriStr: String?, result: MethodChannel.Result) {
        pendingResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            addCategory(Intent.CATEGORY_DEFAULT)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && initialUriStr != null) {
            try {
                val uri = Uri.parse(initialUriStr)
                intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI, uri)
            } catch (e: Exception) {}
        }
        startActivityForResult(intent, PICK_DIRECTORY_REQUEST_CODE)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == PICK_DIRECTORY_REQUEST_CODE && resultCode == Activity.RESULT_OK) {
            data?.data?.let { uri ->
                contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                pendingResult?.success(uri.toString())
            } ?: pendingResult?.success(null)
            pendingResult = null
        }
    }
}
