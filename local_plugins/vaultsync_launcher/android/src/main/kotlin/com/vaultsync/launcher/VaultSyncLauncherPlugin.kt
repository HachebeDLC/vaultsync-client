package com.vaultsync.launcher

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.Settings
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import rikka.shizuku.Shizuku
import android.content.pm.PackageManager
import android.content.ComponentName
import android.content.ServiceConnection
import android.os.IBinder
import org.json.JSONArray
import org.json.JSONObject
import java.io.*
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.util.concurrent.ConcurrentHashMap

class VaultSyncLauncherPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware, PluginRegistry.ActivityResultListener {
    companion object {
        private const val CHANNEL_NAME = "com.vaultsync.app/launcher"
        private const val PICK_DIRECTORY_REQUEST_CODE = 9999
    }

    private lateinit var methodChannel: MethodChannel
    private var context: Context? = null
    private var activity: Activity? = null

    private lateinit var fileScanner: FileScanner
    private lateinit var cryptoEngine: CryptoEngine
    private lateinit var powerManagerHelper: PowerManagerHelper
    private lateinit var automationEngine: AutomationEngine
    private lateinit var networkClient: NetworkClient

    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingResult: MethodChannel.Result? = null

    // Shizuku logic
    private var shizukuService: IShizukuService? = null
    private var isBinding = false
    private val shizukuConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            shizukuService = IShizukuService.Stub.asInterface(service)
            isBinding = false
        }
        override fun onServiceDisconnected(name: ComponentName?) {
            shizukuService = null
            isBinding = false
        }
    }

    private fun bindShizukuService() {
        if (shizukuService != null || isBinding || context == null) return
        try {
            if (Shizuku.pingBinder()) {
                if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
                    val userServiceArgs = Shizuku.UserServiceArgs(ComponentName(context!!.packageName, ShizukuService::class.java.name))
                        .daemon(false).processNameSuffix("shizuku").debuggable(true).version(4)
                    isBinding = true
                    Shizuku.bindUserService(userServiceArgs, shizukuConnection)
                }
            }
        } catch (e: Exception) {
            isBinding = false
            android.util.Log.e("VaultSync", "Shizuku bind failed: ${e.message}", e)
        }
    }

    private val executor = java.util.concurrent.Executors.newCachedThreadPool()

    private fun getShizukuServiceSync(): IShizukuService {
        val current = shizukuService
        if (current != null) return current
        if (!isBinding) bindShizukuService()
        
        val latch = java.util.concurrent.CountDownLatch(1)
        val tempConnection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
                shizukuService = IShizukuService.Stub.asInterface(service)
                isBinding = false
                latch.countDown()
            }
            override fun onServiceDisconnected(name: ComponentName?) {
                shizukuService = null
                isBinding = false
                latch.countDown()
            }
        }
        
        try {
            val userServiceArgs = Shizuku.UserServiceArgs(ComponentName(context!!.packageName, ShizukuService::class.java.name))
                .daemon(false).processNameSuffix("shizuku").debuggable(true).version(4)
            isBinding = true
            Shizuku.bindUserService(userServiceArgs, tempConnection)
            latch.await(3, java.util.concurrent.TimeUnit.SECONDS)
        } catch (e: Exception) {
            isBinding = false
        }
        
        return shizukuService ?: throw Exception("Shizuku connection timeout.")
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val ctx = binding.applicationContext
        context = ctx
        methodChannel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        methodChannel.setMethodCallHandler(this)
        
        fileScanner = FileScanner(ctx)
        cryptoEngine = CryptoEngine()
        powerManagerHelper = PowerManagerHelper(ctx)
        automationEngine = AutomationEngine(ctx, methodChannel)
        networkClient = NetworkClient()
        
        bindShizukuService()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        automationEngine.stopMonitoring()
        powerManagerHelper.releasePowerLock()
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getAndroidVersion" -> result.success(Build.VERSION.SDK_INT)
            "acquirePowerLock" -> {
                powerManagerHelper.acquirePowerLock()
                result.success(true)
            }
            "releasePowerLock" -> {
                powerManagerHelper.releasePowerLock()
                result.success(true)
            }
            "openSafDirectoryPicker" -> openSafDirectoryPicker(call.argument<String>("initialUri"), result)
            "findSwitchSaveRoot" -> result.success(fileScanner.findSwitchSaveRoot(Uri.parse(call.argument<String>("uri")!!)).toString())
            "scanRecursive" -> handleScanRecursive(call, result)
            "calculateHash" -> handleCalculateHash(call, result)
            "calculateBlockHashes" -> handleCalculateBlockHashes(call, result)
            "uploadFileNative" -> handleUploadFile(call, result)
            "downloadFileNative" -> handleDownloadFile(call, result)
            "setFileTimestamp" -> handleSetFileTimestamp(call, result)
            "getFileInfo" -> handleGetFileInfo(call, result)
            "checkPathExists" -> result.success(checkPathExists(call.argument<String>("path")))
            "checkSafPermission" -> result.success(checkSafPermission(call.argument<String>("uri")!!))
            "listSafDirectory" -> handleListSafDirectory(call, result)
            "hasFilesWithExtensions" -> handleHasFilesWithExtensions(call, result)
            "hasUsageStatsPermission" -> result.success(automationEngine.hasUsageStatsPermission())
            "openUsageStatsSettings" -> {
                activity?.startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
                result.success(true)
            }
            "getRecentlyClosedEmulator" -> result.success(automationEngine.getRecentlyClosedEmulator(call.argument<List<String>>("packages")!!))
            "checkShizukuStatus" -> result.success(checkShizukuStatus())
            "requestShizukuPermission" -> requestShizukuPermission(result)
            "openShizukuApp" -> {
                openShizukuApp()
                result.success(true)
            }
            "startMonitoring" -> {
                automationEngine.startMonitoring(call.argument<List<String>>("packages") ?: emptyList())
                result.success(true)
            }
            "stopMonitoring" -> {
                automationEngine.stopMonitoring()
                result.success(true)
            }
            "clearNativeCache" -> {
                fileScanner.clearCache()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun handleScanRecursive(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")!!
        val systemId = call.argument<String>("systemId")!!
        val ignoredFoldersList = call.argument<List<String>>("ignoredFolders") ?: emptyList()
        
        executor.execute {
            try {
                fileScanner.clearCache()
                val allowedExtensions = setOf("srm", "save", "sav", "state", "ps2", "mcd", "dat", "nvmem", "eep", "vms", "vmu", "png", "bin", "db", "sfo", "bak", "bra", "brp", "brps", "brs", "brss", "vfs")
                val combinedIgnores = (setOf("cache", "shaders", "resourcepack", "load", "log", "logs", "temp", "tmp") + ignoredFoldersList.map { it.lowercase() }).toSet()

                val results: String = when {
                    path.startsWith("content://") -> {
                        fileScanner.scanSafRecursive(Uri.parse(path), systemId, ignoredFoldersList, allowedExtensions, combinedIgnores).toString()
                    }
                    isShizukuPath(path) -> {
                        fileScanner.scanShizukuRecursive(getShizukuServiceSync(), getCleanPath(path), systemId, ignoredFoldersList, allowedExtensions, combinedIgnores).toString()
                    }
                    else -> {
                        fileScanner.scanLocalRecursive(path, systemId, ignoredFoldersList, allowedExtensions, combinedIgnores).toString()
                    }
                }
                mainHandler.post { result.success(results) }
            } catch (e: Exception) {
                mainHandler.post { result.error("SCAN_ERROR", e.message, null) }
            }
        }
    }

    private fun handleCalculateHash(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")!!
        executor.execute {
            try {
                val cleanPath = getCleanPath(path)
                if (isShizukuPath(path)) {
                    val hash = getShizukuServiceSync().calculateHash(cleanPath)
                    mainHandler.post { result.success(hash) }
                    return@execute
                }
                
                val input = when {
                    path.startsWith("content://") -> context!!.contentResolver.openInputStream(Uri.parse(path))
                    else -> File(path).inputStream()
                }
                
                input?.use { stream ->
                    val buffer = ByteArray(65536)
                    val digest = java.security.MessageDigest.getInstance("SHA-256")
                    var read: Int
                    while (stream.read(buffer).also { read = it } != -1) {
                        digest.update(buffer, 0, read)
                    }
                    val hash = digest.digest().toHex()
                    mainHandler.post { result.success(hash) }
                }
            } catch (e: Exception) {
                mainHandler.post { result.error("HASH_ERROR", e.message, null) }
            }
        }
    }

    private fun handleCalculateBlockHashes(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")!!
        executor.execute {
            try {
                val cleanPath = getCleanPath(path)
                if (isShizukuPath(path)) {
                    val hashes = getShizukuServiceSync().calculateBlockHashes(cleanPath, CryptoEngine.BLOCK_SIZE)
                    mainHandler.post { result.success(JSONArray(hashes).toString()) }
                    return@execute
                }
                
                val input = when {
                    path.startsWith("content://") -> context!!.contentResolver.openInputStream(Uri.parse(path))
                    else -> File(path).inputStream()
                }
                
                val blockHashes = JSONArray()
                val buffer = ByteArray(CryptoEngine.BLOCK_SIZE)
                val digest = java.security.MessageDigest.getInstance("SHA-256")
                input?.use { stream ->
                    while (true) {
                        val read = stream.read(buffer)
                        if (read == -1) break
                        digest.reset()
                        digest.update(buffer, 0, read)
                        blockHashes.put(digest.digest().toHex())
                    }
                }
                mainHandler.post { result.success(blockHashes.toString()) }
            } catch (e: Exception) {
                mainHandler.post { result.error("BLOCK_HASH_ERROR", e.message, null) }
            }
        }
    }

    private fun handleUploadFile(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")!!
        val token = call.argument<String>("token")
        val masterKey = call.argument<String>("masterKey")
        val remotePath = call.argument<String>("remotePath")!!
        val uriStr = call.argument<String>("uri")!!
        val hash = call.argument<String>("hash")!!
        val deviceName = call.argument<String>("deviceName") ?: "Android"
        val updatedAt = (call.argument<Any>("updatedAt") as? Number)?.toLong() ?: 0L
        val dirtyIndices = call.argument<List<Int>>("dirtyIndices")

        executor.execute {
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
                        context!!.contentResolver.openFileDescriptor(Uri.parse(uriStr), "r")?.let { pfd ->
                            pfd.use { FileInputStream(it.fileDescriptor).use { fis -> fis.channel.use { channel -> 
                                fileSize = channel.size()
                                processUploadBlocks(channel, fileSize, dirtyIndices, secretKey, url, token, remotePath)
                            }}}
                            true
                        } ?: false
                    }
                    else -> {
                        RandomAccessFile(File(uriStr), "r").use { raf -> raf.channel.use { channel -> 
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
        val totalBlocks = if (fileSize == 0L) 1 else ((fileSize + CryptoEngine.BLOCK_SIZE - 1) / CryptoEngine.BLOCK_SIZE).toInt()
        val indicesToSync = dirtyIndices ?: (0 until totalBlocks).toList()

        val executor = java.util.concurrent.Executors.newFixedThreadPool(4)
        val futures = mutableListOf<java.util.concurrent.Future<*>>()
        
        val encryptedBuffers = object : ThreadLocal<ByteArray>() {
            override fun initialValue() = ByteArray(CryptoEngine.ENCRYPTED_BLOCK_SIZE)
        }

        for (index in indicesToSync) {
            val offset = index.toLong() * CryptoEngine.BLOCK_SIZE
            
            futures.add(executor.submit {
                val readBuffer = ByteBuffer.allocate(CryptoEngine.BLOCK_SIZE)
                val bytesRead = synchronized(fileChannel) {
                    fileChannel.position(offset)
                    var totalRead = 0
                    while (totalRead < CryptoEngine.BLOCK_SIZE) {
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
                    postBlock(url, token, remotePath, index, encryptedBuffer, 0, encryptedLength)
                } else {
                    postBlock(url, token, remotePath, index, blockData, 0, dataLength)
                }
            })
        }

        try {
            for (f in futures) f.get()
        } finally {
            executor.shutdown()
        }
    }

    private fun postBlock(baseUrl: String, token: String?, remotePath: String, index: Int, data: ByteArray, offset: Int, length: Int) {
        val encryptedOffset = index.toLong() * CryptoEngine.ENCRYPTED_BLOCK_SIZE
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

    private fun handleDownloadFile(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")!!
        val token = call.argument<String>("token")
        val masterKey = call.argument<String>("masterKey")
        val remoteFilename = call.argument<String>("remoteFilename")!!
        val uriStr = call.argument<String>("uri")!!
        val localFilename = call.argument<String>("localFilename")!!
        val updatedAt = (call.argument<Number>("updatedAt"))?.toLong()
        val patchIndices = call.argument<List<Int>>("patchIndices")

        executor.execute {
            try {
                if (localFilename.contains("..")) throw Exception("Invalid path")
                
                val secretKey = masterKey?.let { 
                    val keyBytes = android.util.Base64.decode(it, android.util.Base64.URL_SAFE).sliceArray(0 until 32)
                    javax.crypto.spec.SecretKeySpec(keyBytes, "AES")
                }
                
                val reqBody = JSONObject().put("path", remoteFilename)
                if (patchIndices != null) reqBody.put("indices", JSONArray(patchIndices)) else reqBody.put("filename", remoteFilename)
                
                val connection = networkClient.openDownloadConnection(url, token, reqBody)
                if (connection.responseCode != 200) throw Exception("Download failed: HTTP ${connection.responseCode}")

                var targetPath: String? = null
                var safTmp: DocumentFile? = null
                var parentDir: DocumentFile? = null

                when {
                    isShizukuPath(uriStr) -> {
                        val cleanBase = getCleanPath(uriStr)
                        targetPath = if (cleanBase.endsWith("/")) "$cleanBase$localFilename" else "$cleanBase/$localFilename"
                        val tmpPath = "$targetPath.vstmp"
                        val service = getShizukuServiceSync()
                        service.openFile(tmpPath, "rw")?.use { pfd ->
                            FileOutputStream(pfd.fileDescriptor).use { fos -> fos.channel.use { output ->
                                if (patchIndices != null) {
                                    service.openFile(targetPath!!, "r")?.use { srcPfd ->
                                        FileInputStream(srcPfd.fileDescriptor).use { fis -> fis.copyTo(fos) }
                                    }
                                }
                                processDownloadStream(connection.inputStream, output, secretKey, patchIndices)
                            }}
                        }
                    }
                    uriStr.startsWith("content://") -> {
                        val root = DocumentFile.fromTreeUri(context!!, Uri.parse(uriStr)) ?: throw Exception("Invalid Root")
                        var dir = root
                        val pathParts = localFilename.split("/")
                        for (i in 0 until pathParts.size - 1) {
                            if (pathParts[i].isEmpty()) continue
                            dir = fileScanner.getOrCreateDirectory(dir, pathParts[i])
                        }
                        parentDir = dir
                        val finalName = pathParts.last()
                        val tmpName = "$finalName.vstmp"
                        fileScanner.findFileStrict(dir, tmpName)?.delete()
                        safTmp = fileScanner.getOrCreateFile(dir, tmpName, "application/octet-stream")
                        context!!.contentResolver.openFileDescriptor(safTmp!!.uri, "rw")?.use { pfd ->
                            FileOutputStream(pfd.fileDescriptor).use { fos -> fos.channel.use { output ->
                                if (patchIndices != null) {
                                    fileScanner.findFileStrict(dir, finalName)?.let { src ->
                                        context!!.contentResolver.openInputStream(src.uri)?.use { input -> input.copyTo(fos) }
                                    }
                                }
                                processDownloadStream(connection.inputStream, output, secretKey, patchIndices)
                            }}
                        }
                    }
                    else -> {
                        val base = File(uriStr)
                        val f = File(base, localFilename)
                        if (!f.parentFile.exists()) f.parentFile.mkdirs()
                        targetPath = f.absolutePath
                        val tmpFile = File("$targetPath.vstmp")
                        if (patchIndices != null && f.exists()) f.copyTo(tmpFile, overwrite = true)
                        RandomAccessFile(tmpFile, "rw").use { raf -> raf.channel.use { output ->
                            processDownloadStream(connection.inputStream, output, secretKey, patchIndices)
                        }}
                    }
                }
                connection.disconnect()

                // Finalize rename
                when {
                    isShizukuPath(uriStr) -> {
                        getShizukuServiceSync().renameFile("${targetPath}.vstmp", targetPath!!)
                        if (updatedAt != null) setFileTimestampInternal("shizuku://$targetPath", updatedAt)
                    }
                    safTmp != null -> {
                        val finalName = localFilename.split("/").last()
                        val existingFile = fileScanner.findFileStrict(parentDir!!, finalName)
                        
                        // CRITICAL: Delete the existing file explicitly first.
                        // Android's DocumentFile.renameTo() will sometimes create [Name] (1).dat
                        // if we don't clear the path first.
                        existingFile?.delete()
                        
                        if (!safTmp.renameTo(finalName)) {
                            // If rename still fails, do a manual bit-copy
                            val newFinal = parentDir.createFile("application/octet-stream", finalName) ?: throw Exception("Final rename failed")
                            context!!.contentResolver.openInputStream(safTmp.uri)?.use { input ->
                                context!!.contentResolver.openOutputStream(newFinal.uri)?.use { out -> input.copyTo(out) }
                            }
                            safTmp.delete()
                        }
                    }
                    else -> {
                        val f = File(targetPath!!)
                        val tmp = File("$targetPath.vstmp")
                        if (f.exists()) f.delete()
                        tmp.renameTo(f)
                        if (updatedAt != null) setFileTimestampInternal(f.absolutePath, updatedAt)
                    }
                }
                mainHandler.post { result.success(true) }
            } catch (e: Exception) {
                android.util.Log.e("VaultSync", "Download failed", e)
                mainHandler.post { result.error("DOWNLOAD_ERROR", e.message, null) }
            }
        }
    }

    private fun processDownloadStream(inputStream: InputStream, output: FileChannel, secretKey: javax.crypto.spec.SecretKeySpec?, patchIndices: List<Int>?) {
        val expectedBlockSize = if (secretKey != null) CryptoEngine.ENCRYPTED_BLOCK_SIZE else CryptoEngine.BLOCK_SIZE
        
        // Ring buffer to avoid frequent allocations
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
                ringBuffer.flip() // Prepare for reading
                
                // Process accumulated data until we have a complete block
                while (ringBuffer.remaining() >= expectedBlockSize) {
                    ringBuffer.get(block, 0, expectedBlockSize)
                    
                    val decryptedLength = if (secretKey != null) {
                        cryptoEngine.decryptBlock(block, expectedBlockSize, secretKey, decryptedBuffer)
                    } else {
                        System.arraycopy(block, 0, decryptedBuffer, 0, expectedBlockSize)
                        expectedBlockSize
                    }
                    
                    // Determine the destination offset in the file.
                    val blockIndex = if (patchIndices != null) {
                        if (currentIdx >= patchIndices.size) throw Exception("Index out of bounds for patchIndices")
                        patchIndices[currentIdx].toLong()
                    } else {
                        currentIdx.toLong()
                    }
                    
                    val offset = blockIndex * CryptoEngine.BLOCK_SIZE
                    output.position(offset)
                    output.write(ByteBuffer.wrap(decryptedBuffer, 0, decryptedLength))
                    
                    currentIdx++
                }
                
                ringBuffer.compact() // Prepare for writing more data, keeping any remainder
            }
            
            // Process any remaining partial block at EOF
            ringBuffer.flip()
            val remaining = ringBuffer.remaining()
            if (remaining > 0) {
                ringBuffer.get(block, 0, remaining)
                val decryptedLength = if (secretKey != null) {
                    cryptoEngine.decryptBlock(block, remaining, secretKey, decryptedBuffer)
                } else {
                    System.arraycopy(block, 0, decryptedBuffer, 0, remaining)
                    remaining
                }
                
                val blockIndex = if (patchIndices != null) {
                    if (currentIdx >= patchIndices.size) throw Exception("Index out of bounds for patchIndices")
                    patchIndices[currentIdx].toLong()
                } else {
                    currentIdx.toLong()
                }
                
                val offset = blockIndex * CryptoEngine.BLOCK_SIZE
                output.position(offset)
                output.write(ByteBuffer.wrap(decryptedBuffer, 0, decryptedLength))
            }
        }
        if (Build.VERSION.SDK_INT >= 30) try { output.force(true) } catch(e: Exception) {}
    }

    private fun handleSetFileTimestamp(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")!!
        val updatedAt = call.argument<Number>("updatedAt")!!.toLong()
        executor.execute {
            val success = setFileTimestampInternal(path, updatedAt)
            mainHandler.post { result.success(success) }
        }
    }

    private fun setFileTimestampInternal(path: String, updatedAt: Long): Boolean {
        return try {
            when {
                path.startsWith("content://") -> true // No touch for SAF
                isShizukuPath(path) -> getShizukuServiceSync().setLastModified(getCleanPath(path), updatedAt)
                else -> {
                    val file = File(path)
                    if (file.exists()) file.setLastModified(updatedAt) else false
                }
            }
        } catch (e: Exception) {
            android.util.Log.w("VaultSync", "setFileTimestamp failed for $path: ${e.message}")
            false
        }
    }

    private fun handleGetFileInfo(call: MethodCall, result: MethodChannel.Result) {
        val uriStr = call.argument<String>("uri")!!
        executor.execute {
            try {
                if (isShizukuPath(uriStr)) {
                    val path = getCleanPath(uriStr)
                    val service = getShizukuServiceSync()
                    val size = service.getFileSize(path)
                    if (size != -1L) {
                        mainHandler.post { result.success(mapOf("size" to size, "lastModified" to service.getLastModified(path))) }
                    } else {
                        mainHandler.post { result.error("NOT_FOUND", "File not found", null) }
                    }
                } else {
                    val f = if (uriStr.startsWith("content://")) DocumentFile.fromSingleUri(context!!, Uri.parse(uriStr)) else DocumentFile.fromFile(File(uriStr))
                    if (f != null && f.exists()) {
                        mainHandler.post { result.success(mapOf("size" to f.length(), "lastModified" to f.lastModified())) }
                    } else {
                        mainHandler.post { result.error("NOT_FOUND", "File not found", null) }
                    }
                }
            } catch (e: Exception) {
                mainHandler.post { result.error("INFO_ERROR", e.message, null) }
            }
        }
    }

    private fun checkPathExists(path: String?): Boolean {
        if (path == null || context == null) return false
        return when {
            path.startsWith("content://") -> {
                try { DocumentFile.fromTreeUri(context!!, Uri.parse(path))?.exists() ?: false } catch (e: Exception) { false }
            }
            isShizukuPath(path) -> getShizukuServiceSync().getFileSize(getCleanPath(path)) != -1L
            else -> File(path).exists()
        }
    }

    private fun checkSafPermission(uriStr: String): Boolean {
        if (context == null || !uriStr.startsWith("content://")) return true
        val targetUriStr = Uri.parse(uriStr).toString()
        val permissions = context!!.contentResolver.persistedUriPermissions
        return permissions.any { it.uri.toString() == targetUriStr && it.isWritePermission }
    }

    private fun handleListSafDirectory(call: MethodCall, result: MethodChannel.Result) {
        val uriStr = call.argument<String>("uri")!!
        executor.execute {
            try {
                val results: String = when {
                    uriStr.startsWith("content://") -> {
                        fileScanner.listSafDirectory(Uri.parse(uriStr)).toString()
                    }
                    isShizukuPath(uriStr) -> {
                        val cleanPath = getCleanPath(uriStr)
                        val service = getShizukuServiceSync()
                        val files = JSONArray(service.listFileInfo(cleanPath))
                        val shizukuResults = JSONArray()
                        for (i in 0 until files.length()) {
                            val f = files.getJSONObject(i)
                            shizukuResults.put(JSONObject().apply {
                                put("name", f.getString("name"))
                                put("uri", "shizuku://$cleanPath/${f.getString("name")}")
                                put("isDirectory", f.getBoolean("isDirectory"))
                            })
                        }
                        shizukuResults.toString()
                    }
                    else -> {
                        val localResults = JSONArray()
                        File(uriStr).listFiles()?.forEach { file ->
                            localResults.put(JSONObject().apply {
                                put("name", file.name)
                                put("uri", file.absolutePath)
                                put("isDirectory", file.isDirectory)
                            })
                        }
                        localResults.toString()
                    }
                }
                mainHandler.post { result.success(results) }
            } catch (e: Exception) {
                mainHandler.post { result.error("LIST_ERROR", e.message, null) }
            }
        }
    }

    private fun handleHasFilesWithExtensions(call: MethodCall, result: MethodChannel.Result) {
        val uriStr = call.argument<String>("uri")!!
        val extensions = call.argument<List<String>>("extensions")!!
        executor.execute {
            try {
                val success = when {
                    uriStr.startsWith("content://") -> {
                        val rootUri = Uri.parse(uriStr)
                        val docId = try { DocumentsContract.getTreeDocumentId(rootUri) } catch(e: Exception) { DocumentsContract.getDocumentId(rootUri) }
                        fileScanner.checkSafExtensionsRecursive(rootUri, docId, extensions, 0)
                    }
                    else -> false // Simplified for now
                }
                mainHandler.post { result.success(success) }
            } catch (e: Exception) {
                mainHandler.post { result.error("SCAN_ERROR", e.message, null) }
            }
        }
    }

    private fun checkShizukuStatus(): Map<String, Any> {
        val status = mutableMapOf<String, Any>()
        try {
            if (Shizuku.pingBinder()) {
                status["running"] = true
                status["authorized"] = Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
                status["version"] = Shizuku.getLatestServiceVersion()
            } else {
                status["running"] = false
                status["authorized"] = false
            }
        } catch (e: Exception) {
            status["running"] = false
            status["authorized"] = false
            status["error"] = e.message ?: "Error"
        }
        return status
    }

    private fun requestShizukuPermission(result: MethodChannel.Result) {
        if (!Shizuku.pingBinder()) {
            result.error("SHIZUKU_NOT_RUNNING", "Shizuku is not running", null)
            return
        }
        if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        val listener = object : Shizuku.OnRequestPermissionResultListener {
            override fun onRequestPermissionResult(requestCode: Int, grantResult: Int) {
                Shizuku.removeRequestPermissionResultListener(this)
                mainHandler.post { result.success(grantResult == PackageManager.PERMISSION_GRANTED) }
            }
        }
        Shizuku.addRequestPermissionResultListener(listener)
        Shizuku.requestPermission(1001)
    }

    private fun openShizukuApp() {
        context?.let { ctx ->
            val intent = ctx.packageManager.getLaunchIntentForPackage("rikka.shizuku")
            if (intent != null) {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                ctx.startActivity(intent)
            } else {
                val marketIntent = Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=rikka.shizuku")).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                ctx.startActivity(marketIntent)
            }
        }
    }

    private fun openSafDirectoryPicker(initialUriStr: String?, result: MethodChannel.Result) {
        if (activity == null) {
            result.error("NO_ACTIVITY", "Activity not attached", null)
            return
        }
        pendingResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            addCategory(Intent.CATEGORY_DEFAULT)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && initialUriStr != null) {
            try { intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI, Uri.parse(initialUriStr)) } 
            catch (e: Exception) { android.util.Log.w("VaultSync", "Could not set initial URI for picker: ${e.message}") }
        }
        activity!!.startActivityForResult(intent, PICK_DIRECTORY_REQUEST_CODE)
    }

    private fun isShizukuPath(path: String?): Boolean = path?.startsWith("shizuku://") == true
    private fun getCleanPath(path: String): String = if (path.startsWith("shizuku://")) path.substring(10).replace("//", "/") else path.replace("//", "/")

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == PICK_DIRECTORY_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK) {
                data?.data?.let { uri -> 
                    context!!.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                    pendingResult?.success(uri.toString()) 
                } ?: pendingResult?.success(null)
            } else {
                pendingResult?.success(null)
            }
            pendingResult = null
            return true
        }
        return false
    }

    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { 
        activity = binding.activity 
        binding.addActivityResultListener(this)
    }
    override fun onDetachedFromActivity() { activity = null }
}
