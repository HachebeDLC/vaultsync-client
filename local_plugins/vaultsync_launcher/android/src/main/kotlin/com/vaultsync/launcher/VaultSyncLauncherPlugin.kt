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

    // Priority 6: Shared ThreadPools to prevent thread explosion
    private val executor = java.util.concurrent.Executors.newCachedThreadPool()
    private val syncExecutor = java.util.concurrent.Executors.newFixedThreadPool(4)

    // Shizuku logic
    private var shizukuService: IShizukuService? = null
    private var shizukuServiceFuture = java.util.concurrent.CompletableFuture<IShizukuService>()
    private var isBinding = false
    private val shizukuConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            val interf = IShizukuService.Stub.asInterface(service)
            shizukuService = interf
            shizukuServiceFuture.complete(interf)
            isBinding = false
        }
        override fun onServiceDisconnected(name: ComponentName?) {
            shizukuService = null
            shizukuServiceFuture = java.util.concurrent.CompletableFuture<IShizukuService>()
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

    private fun getShizukuServiceSync(): IShizukuService {
        val current = shizukuService
        if (current != null) return current
        if (!isBinding) bindShizukuService()
        return shizukuServiceFuture.get(3, java.util.concurrent.TimeUnit.SECONDS) ?: throw Exception("Shizuku connection timeout.")
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
        android.util.Log.d("VaultSync", "📲 METHOD CALL: ${call.method}")
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
            "openSafDirectoryPicker" -> {
                if (activity == null) {
                    result.error("NO_ACTIVITY", "Activity is not available", null)
                    return
                }
                pendingResult = result
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                activity!!.startActivityForResult(intent, PICK_DIRECTORY_REQUEST_CODE)
            }
            "checkSafPermission" -> {
                val uriStr = call.argument<String>("uri")!!
                val uri = Uri.parse(uriStr)
                val hasPerm = context!!.contentResolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission && it.isWritePermission }
                result.success(hasPerm)
            }
            "hasUsageStatsPermission" -> {
                result.success(automationEngine.hasUsageStatsPermission())
            }
            "openUsageStatsSettings" -> {
                val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
                intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                context!!.startActivity(intent)
                result.success(true)
            }
            "getRecentlyClosedEmulator" -> {
                val packages = call.argument<List<String>>("packages") ?: emptyList()
                result.success(automationEngine.getRecentlyClosedEmulator(packages))
            }
            "checkShizukuStatus" -> {
                val running = Shizuku.pingBinder()
                val auth = if (running) Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED else false
                result.success(mapOf("running" to running, "authorized" to auth))
            }
            "requestShizukuPermission" -> {
                if (Shizuku.pingBinder() && Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) {
                    Shizuku.requestPermission(101)
                    result.success(true)
                } else {
                    result.success(false)
                }
            }
            "openShizukuApp" -> {
                val intent = context!!.packageManager.getLaunchIntentForPackage("moe.shizuku.privileged.api")
                if (intent != null) {
                    intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    context!!.startActivity(intent)
                    result.success(true)
                } else {
                    result.error("SHIZUKU_NOT_FOUND", "Shizuku manager app not installed", null)
                }
            }
            "checkPathExists" -> {
                val uriStr = call.argument<String>("uri")!!
                executor.execute {
                    try {
                        val exists = when {
                            uriStr.startsWith("shizuku://") -> getShizukuServiceSync().getFileSize(getCleanPath(uriStr)) != -1L
                            uriStr.startsWith("content://") -> {
                                val df = DocumentFile.fromSingleUri(context!!, Uri.parse(uriStr))
                                df?.exists() == true
                            }
                            else -> File(uriStr).exists()
                        }
                        mainHandler.post { result.success(exists) }
                    } catch (e: Exception) {
                        mainHandler.post { result.success(false) }
                    }
                }
            }
            "hasFilesWithExtensions" -> {
                val uriStr = call.argument<String>("uri")!!
                val extensions = call.argument<List<String>>("extensions") ?: emptyList()
                executor.execute {
                    try {
                        val uri = Uri.parse(uriStr)
                        val hasExt = fileScanner.checkSafExtensionsRecursive(uri, DocumentsContract.getDocumentId(uri), extensions, 0)
                        mainHandler.post { result.success(hasExt) }
                    } catch (e: Exception) {
                        mainHandler.post { result.success(false) }
                    }
                }
            }
            "scanRecursive" -> handleScanRecursive(call, result)
            "calculateHash" -> handleCalculateHash(call, result)
            "calculateBlockHashes" -> handleCalculateBlockHashes(call, result)
            "uploadFileNative" -> handleUploadFile(call, result)
            "downloadFileNative" -> handleDownloadFile(call, result)
            "setFileTimestamp" -> handleSetFileTimestamp(call, result)
            "getFileInfo" -> handleGetFileInfo(call, result)
            "clearCache" -> {
                fileScanner.clearCache()
                result.success(true)
            }
            "startMonitoring" -> {
                val packages = call.argument<List<String>>("packages") ?: emptyList()
                val interval = call.argument<Number>("interval")?.toLong() ?: 15000L
                automationEngine.startMonitoring(packages, interval)
                result.success(true)
            }
            "stopMonitoring" -> {
                automationEngine.stopMonitoring()
                result.success(true)
            }
            "getSwitchSaveRoot" -> {
                val uriStr = call.argument<String>("uri")!!
                val root = fileScanner.findSwitchSaveRoot(Uri.parse(uriStr))
                result.success(root.toString())
            }
            else -> result.notImplemented()
        }
    }

    private fun handleCalculateHash(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")!!
        executor.execute {
            try {
                val input = when {
                    path.startsWith("shizuku://") -> {
                        getShizukuServiceSync().openFile(getCleanPath(path), "r")?.let { 
                            FileInputStream(it.fileDescriptor)
                        }
                    }
                    path.startsWith("content://") -> context!!.contentResolver.openInputStream(Uri.parse(path))
                    else -> File(path).inputStream()
                }
                
                val digest = java.security.MessageDigest.getInstance("SHA-256")
                val buffer = ByteArray(CryptoEngine.BLOCK_SIZE)
                input?.use { stream ->
                    while (true) {
                        val read = stream.read(buffer)
                        if (read == -1) break
                        digest.update(buffer, 0, read)
                    }
                }
                mainHandler.post { result.success(cryptoEngine.calculateHash(digest.digest(), digest.digest().size)) } // Actually, just convert to hex
            } catch (e: Exception) {
                mainHandler.post { result.error("HASH_ERROR", e.message, null) }
            }
        }
    }

    private fun handleScanRecursive(call: MethodCall, result: MethodChannel.Result) {
        val path           = call.argument<String>("path")!!
        val systemId       = call.argument<String>("systemId")!!
        val ignoredFolders = call.argument<List<String>>("ignoredFolders") ?: emptyList()

        executor.execute {
            try {
                // combinedIgnores: hardcoded noise + per-system ignored_folders from JSON
                val combinedIgnores = (setOf(
                    "cache", "shaders", "resourcepack", "load",
                    "log", "logs", "temp", "tmp", "bios", "covers",
                    "textures", "custom_textures", "game"
                ) + ignoredFolders).toSet()

                val scanResults = when {
                    path.startsWith("shizuku://") ->
                        fileScanner.scanShizukuRecursive(
                            getShizukuServiceSync(), getCleanPath(path),
                            systemId, ignoredFolders,
                            FileScanner.SAVE_EXTENSIONS, combinedIgnores
                        )
                    path.startsWith("content://") ->
                        fileScanner.scanSafRecursive(
                            Uri.parse(path), systemId, ignoredFolders,
                            FileScanner.SAVE_EXTENSIONS, combinedIgnores
                        )
                    else ->
                        fileScanner.scanLocalRecursive(
                            path, systemId, ignoredFolders,
                            FileScanner.SAVE_EXTENSIONS, combinedIgnores
                        )
                }
                android.util.Log.d("VaultSync", "🔍 SCAN: Completed for $systemId. Found ${scanResults.length()} items.")
                mainHandler.post { result.success(scanResults.toString()) }
            } catch (e: Exception) {
                android.util.Log.e("VaultSync", "Scan failed: ${e.message}", e)
                mainHandler.post { result.error("SCAN_ERROR", e.message, null) }
            }
        }
    }

    private fun getCleanPath(path: String): String {
        return path.replace("shizuku://", "")
    }

    private fun handleCalculateBlockHashes(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")!!
        val masterKey = call.argument<String>("masterKey")
        executor.execute {
            try {
                val input = when {
                    path.startsWith("shizuku://") -> {
                        getShizukuServiceSync().openFile(getCleanPath(path), "r")?.let { 
                            FileInputStream(it.fileDescriptor)
                        }
                    }
                    path.startsWith("content://") -> context!!.contentResolver.openInputStream(Uri.parse(path))
                    else -> File(path).inputStream()
                }
                
                val secretKey = masterKey?.let { 
                    val keyBytes = android.util.Base64.decode(it, android.util.Base64.URL_SAFE).sliceArray(0 until 32)
                    javax.crypto.spec.SecretKeySpec(keyBytes, "AES")
                }
                
                val blockHashes = JSONArray()
                val buffer = ByteArray(CryptoEngine.BLOCK_SIZE)
                val encryptedBuffer = ByteArray(CryptoEngine.ENCRYPTED_BLOCK_SIZE)
                
                input?.use { stream ->
                    while (true) {
                        val read = stream.read(buffer)
                        if (read == -1) break
                        
                        if (secretKey != null) {
                            val encryptedLength = cryptoEngine.encryptBlock(buffer, read, secretKey, encryptedBuffer)
                            blockHashes.put(cryptoEngine.calculateHash(encryptedBuffer, encryptedLength))
                        } else {
                            blockHashes.put(cryptoEngine.calculateHash(buffer, read))
                        }
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
        val blockSize = CryptoEngine.getBlockSize(fileSize)
        val encryptedBlockSize = CryptoEngine.getEncryptedBlockSize(fileSize)
        val totalBlocks = if (fileSize == 0L) 1 else ((fileSize + blockSize - 1) / blockSize).toInt()
        val indicesToSync = dirtyIndices ?: (0 until totalBlocks).toList()

        val futures = mutableListOf<java.util.concurrent.Future<*>>()
        
        // Memory Optimization: Reuse large buffers across threads to reduce GC pressure
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
                    postBlock(url, token, remotePath, index, encryptedBuffer, 0, encryptedLength)
                } else {
                    postBlock(url, token, remotePath, index, blockData, 0, dataLength)
                }
            })
        }

        for (f in futures) f.get()
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
                            val rootDoc = DocumentFile.fromTreeUri(context!!, treeUri)!!
                            
                            val pathParts = localFilename.split("/")
                            var currentDir = rootDoc
                            for (i in 0 until pathParts.size - 1) {
                                currentDir = fileScanner.getOrCreateDirectory(currentDir, pathParts[i])
                            }
                            
                            val finalName = pathParts.last()
                            val targetFile = fileScanner.getOrCreateFile(currentDir, finalName, "application/octet-stream")
                            
                            val pfd = context!!.contentResolver.openFileDescriptor(targetFile.uri, "rw")
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
                            
                            RandomAccessFile(finalFile, "rw").use { raf ->
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

        // Zero-Copy Optimization: For unencrypted downloads, use transferFrom to bypass JVM heap
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
                    val decryptedLength = if (secretKey != null) {
                        cryptoEngine.decryptBlock(block, expectedBlockSize, secretKey, decryptedBuffer)
                    } else {
                        System.arraycopy(block, 0, decryptedBuffer, 0, expectedBlockSize)
                        expectedBlockSize
                    }
                    val blockIndex = if (patchIndices != null) patchIndices[currentIdx].toLong() else currentIdx.toLong()
                    val offset = blockIndex * plainBlockSize
                    output.position(offset)
                    output.write(ByteBuffer.wrap(decryptedBuffer, 0, decryptedLength))
                    currentIdx++
                }
                ringBuffer.compact()
            }
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
                val blockIndex = if (patchIndices != null) patchIndices[currentIdx].toLong() else currentIdx.toLong()
                val offset = blockIndex * CryptoEngine.BLOCK_SIZE
                output.position(offset)
                output.write(ByteBuffer.wrap(decryptedBuffer, 0, decryptedLength))
            }
        }
        if (Build.VERSION.SDK_INT >= 30) try { output.force(true) } catch(e: Exception) {}
    }

    private fun handleSetFileTimestamp(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")!!
        val updatedAt = (call.argument<Any>("updatedAt") as? Number)?.toLong() ?: 0L
        executor.execute {
            val success = setFileTimestampInternal(path, updatedAt)
            mainHandler.post { result.success(success) }
        }
    }

    private fun setFileTimestampInternal(path: String, updatedAt: Long): Boolean {
        return try {
            when {
                path.startsWith("content://") -> true 
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
                        mainHandler.post { result.error("NOT_FOUND", "File not found via Shizuku", null) }
                    }
                } else if (uriStr.startsWith("content://")) {
                    val df = DocumentFile.fromSingleUri(context!!, Uri.parse(uriStr))
                    if (df != null && df.exists()) {
                        mainHandler.post { result.success(mapOf("size" to df.length(), "lastModified" to df.lastModified())) }
                    } else {
                        mainHandler.post { result.error("NOT_FOUND", "File not found via SAF", null) }
                    }
                } else {
                    val file = File(uriStr)
                    if (file.exists()) {
                        mainHandler.post { result.success(mapOf("size" to file.length(), "lastModified" to file.lastModified())) }
                    } else {
                        mainHandler.post { result.error("NOT_FOUND", "Local file not found", null) }
                    }
                }
            } catch (e: Exception) {
                mainHandler.post { result.error("FILE_INFO_ERROR", e.message, null) }
            }
        }
    }

    private fun isShizukuPath(path: String): Boolean = path.startsWith("shizuku://")

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == PICK_DIRECTORY_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK && data != null) {
                val uri = data.data
                if (uri != null) {
                    context!!.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                    pendingResult?.success(uri.toString())
                } else {
                    pendingResult?.error("PICK_FAILED", "No URI returned", null)
                }
            } else {
                pendingResult?.error("PICK_CANCELLED", "User cancelled directory pick", null)
            }
            pendingResult = null
            return true
        }
        return false
    }
}
