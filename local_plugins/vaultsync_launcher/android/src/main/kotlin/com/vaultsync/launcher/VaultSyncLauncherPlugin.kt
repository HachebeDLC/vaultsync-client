package com.vaultsync.launcher

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
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
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

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
    private lateinit var uploadManager: UploadManager
    private lateinit var downloadManager: DownloadManager
    private lateinit var connectivityMonitor: ConnectivityMonitor

    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingResult: MethodChannel.Result? = null

    private val executor: ExecutorService = Executors.newCachedThreadPool()
    private val syncExecutor: ExecutorService = Executors.newFixedThreadPool(2)

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
        val ctx = context ?: return
        if (shizukuService != null || isBinding) return
        try {
            if (Shizuku.pingBinder()) {
                val hasPermission = Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
                if (hasPermission) {
                    val userServiceArgs = Shizuku.UserServiceArgs(ComponentName(ctx.packageName, ShizukuService::class.java.name))
                        .daemon(false).processNameSuffix("shizuku").debuggable(true).version(4)
                    isBinding = true
                    Shizuku.bindUserService(userServiceArgs, shizukuConnection)
                } else {
                    android.util.Log.w("VaultSync", "Shizuku pinged but PERMISSION_DENIED. User must authorize in Shizuku app.")
                }
            } else {
                android.util.Log.w("VaultSync", "Shizuku service not running or not found (pingBinder failed)")
            }
        } catch (e: Exception) {
            isBinding = false
            android.util.Log.e("VaultSync", "Shizuku bind failed: ${e.message}", e)
        }
    }

    private fun getShizukuServiceSync(): IShizukuService {
        val current = shizukuService
        if (current != null) return current
        
        // Reset future if it was completed or cancelled
        if (shizukuServiceFuture.isDone) {
            shizukuServiceFuture = java.util.concurrent.CompletableFuture<IShizukuService>()
        }
        
        if (!isBinding) bindShizukuService()
        
        return try {
            // Increase timeout to 10s for initial cold start
            shizukuServiceFuture.get(10, java.util.concurrent.TimeUnit.SECONDS) ?: throw Exception("Shizuku connection null")
        } catch (e: java.util.concurrent.TimeoutException) {
            val status = if (Shizuku.pingBinder()) "Running, No Permission" else "Not Running"
            throw Exception("Shizuku connection timeout (Status: $status)")
        } catch (e: Exception) {
            throw Exception("Shizuku connection error: ${e.message}")
        }
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
        connectivityMonitor = ConnectivityMonitor(ctx, methodChannel)
        networkClient = NetworkClient()
        
        uploadManager = UploadManager(
            ctx, networkClient, cryptoEngine, syncExecutor, mainHandler,
            ::isShizukuPath, ::getCleanPath, ::getShizukuServiceSync
        )
        
        downloadManager = DownloadManager(
            ctx, networkClient, cryptoEngine, fileScanner, executor, mainHandler,
            ::isShizukuPath, ::getCleanPath, ::getShizukuServiceSync, ::setFileTimestampInternal
        )
        
        connectivityMonitor.startMonitoring()
        bindShizukuService()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        automationEngine.stopMonitoring()
        connectivityMonitor.stopMonitoring()
        powerManagerHelper.releasePowerLock()
        executor.shutdown()
        syncExecutor.shutdown()
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context ?: return result.error("NO_CONTEXT", "Context is null", null)
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
                val act = activity ?: return result.error("NO_ACTIVITY", "Activity is not available", null)
                pendingResult = result
                val initialUriStr = call.argument<String>("initialUri")
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && initialUriStr != null) {
                    try {
                        val cleanPath = when {
                            initialUriStr.contains("primary%3A") ->
                                initialUriStr.split("primary%3A").last().replace("%2F", "/")
                            initialUriStr.contains("primary:") ->
                                initialUriStr.split("primary:").last()
                            initialUriStr.contains("tree/") ->
                                initialUriStr.split("tree/").last().split(":").last().replace("%2F", "/")
                            else -> null
                        }
                        val hintUri = if (cleanPath != null) {
                            DocumentsContract.buildDocumentUri("com.android.externalstorage.documents", "primary:${cleanPath.trimEnd('/')}")
                        } else {
                            Uri.parse(initialUriStr)
                        }
                        intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI, hintUri)
                        android.util.Log.d("VaultSync", "SAF picker hint URI: $hintUri")
                    } catch (e: Exception) {
                        android.util.Log.w("VaultSync", "Failed to set SAF picker hint: ${e.message}")
                    }
                }
                act.startActivityForResult(intent, PICK_DIRECTORY_REQUEST_CODE)
            }
            "checkSafPermission" -> {
                val uriStr = call.argument<String>("uri") ?: return result.error("ARG_MISSING", "uri missing", null)
                val uri = Uri.parse(uriStr)
                val hasPerm = ctx.contentResolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission && it.isWritePermission }
                result.success(hasPerm)
            }
            "hasUsageStatsPermission" -> {
                result.success(automationEngine.hasUsageStatsPermission())
            }
            "openUsageStatsSettings" -> {
                val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
                intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                ctx.startActivity(intent)
                result.success(true)
            }
            "isOnline" -> {
                result.success(connectivityMonitor.isCurrentlyConnected())
            }
            "isPackageInstalled" -> {
                val packageName = call.argument<String>("packageName") ?: return result.error("ARG_MISSING", "packageName missing", null)
                try {
                    ctx.packageManager.getPackageInfo(packageName, 0)
                    result.success(true)
                } catch (e: PackageManager.NameNotFoundException) {
                    result.success(false)
                }
            }
            "getRecentlyClosedEmulator" -> {
                val packages = call.argument<List<String>>("packages") ?: emptyList()
                result.success(automationEngine.getRecentlyClosedEmulator(packages))
            }
            "listLibraryNative" -> {
                val uriStr = call.argument<String>("uri") ?: return result.error("ARG_MISSING", "uri missing", null)
                executor.execute {
                    try {
                        android.util.Log.d("VaultSync", "listLibraryNative called for $uriStr")
                        val svc = if (isShizukuPath(uriStr)) {
                            try { getShizukuServiceSync() } catch (_: Exception) { null }
                        } else null
                        val list = fileScanner.listLibraryNative(Uri.parse(uriStr), svc)
                        android.util.Log.d("VaultSync", "listLibraryNative returning ${list.length()} items for $uriStr")
                        mainHandler.post { result.success(list.toString()) }
                    } catch (e: Exception) {
                        android.util.Log.e("VaultSync", "listLibraryNative error: ${e.message}")
                        mainHandler.post { result.error("LIST_ERROR", e.message, null) }
                    }
                }
            }
            "checkShizukuStatus" -> {
                try {
                    val running = Shizuku.pingBinder()
                    val auth = if (running) Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED else false
                    result.success(mapOf("running" to running, "authorized" to auth))
                } catch (e: Exception) {
                    android.util.Log.w("VaultSync", "checkShizukuStatus threw: ${e.message}")
                    result.success(mapOf("running" to false, "authorized" to false))
                }
            }
            "requestShizukuPermission" -> {
                try {
                    if (Shizuku.pingBinder() && Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) {
                        Shizuku.requestPermission(101)
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                } catch (e: Exception) {
                    android.util.Log.w("VaultSync", "requestShizukuPermission threw: ${e.message}")
                    result.success(false)
                }
            }
            "openShizukuApp" -> {
                val intent = ctx.packageManager.getLaunchIntentForPackage("moe.shizuku.privileged.api")
                if (intent != null) {
                    intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    ctx.startActivity(intent)
                    result.success(true)
                } else {
                    result.error("SHIZUKU_NOT_FOUND", "Shizuku manager app not installed", null)
                }
            }
            "checkPathExists" -> {
                val uriStr = call.argument<String>("uri") ?: return result.error("ARG_MISSING", "uri missing", null)
                executor.execute {
                    try {
                        val exists = when {
                            uriStr.startsWith("shizuku://") -> getShizukuServiceSync().getFileSize(getCleanPath(uriStr)) != -1L
                            uriStr.startsWith("content://") -> {
                                val uri = Uri.parse(uriStr)
                                // Attempt to parse as tree URI first, fallback to single URI
                                val df = try {
                                    DocumentFile.fromTreeUri(ctx, uri) ?: DocumentFile.fromSingleUri(ctx, uri)
                                } catch (e: Exception) {
                                    DocumentFile.fromSingleUri(ctx, uri)
                                }
                                val res = df?.exists() == true
                                android.util.Log.d("VaultSync", "checkPathExists SAF df.exists() = $res for uri=$uriStr")
                                res
                            }
                            else -> File(uriStr).exists()
                        }
                        android.util.Log.d("VaultSync", "checkPathExists returning $exists for $uriStr")
                        mainHandler.post { result.success(exists) }
                    } catch (e: Exception) {
                        android.util.Log.e("VaultSync", "checkPathExists error: ${e.message}")
                        mainHandler.post { result.success(false) }
                    }
                }
            }
            "hasFilesWithExtensions" -> {
                val uriStr = call.argument<String>("uri") ?: return result.error("ARG_MISSING", "uri missing", null)
                val extensions = call.argument<List<String>>("extensions") ?: emptyList()
                executor.execute {
                    try {
                        val hasExt = when {
                            uriStr.startsWith("shizuku://") -> {
                                val svc = getShizukuServiceSync()
                                val cleanPath = getCleanPath(uriStr)
                                // We can implement a more efficient recursive check if needed,
                                // but for now a simple depth-limited one is enough.
                                checkShizukuExtensionsRecursive(svc, cleanPath, extensions, 0)
                            }
                            uriStr.startsWith("content://") -> {
                                val uri = Uri.parse(uriStr)
                                val docId = fileScanner.getDocIdSafely(uri)
                                fileScanner.checkSafExtensionsRecursive(uri, docId, extensions, 0)
                            }
                            else -> checkLocalExtensionsRecursive(File(uriStr), extensions, 0)
                        }
                        mainHandler.post { result.success(hasExt) }
                    } catch (e: Exception) {
                        mainHandler.post { result.success(false) }
                    }
                }
            }
            "scanRecursive" -> handleScanRecursive(call, result)
            "calculateHash" -> handleCalculateHash(call, result)
            "calculateBlockHashes" -> handleCalculateBlockHashes(call, result)
            "extractModifiedBlocks" -> {
                val path = call.argument<String>("path") ?: return result.error("ARG_MISSING", "path missing", null)
                val versionStorePath = call.argument<String>("versionStorePath") ?: return result.error("ARG_MISSING", "versionStorePath missing", null)
                val changedBlocksMap = call.argument<Map<String, Boolean>>("changedBlocks") ?: emptyMap()
                val changedBlocks = changedBlocksMap.mapKeys { it.key.toInt() }

                executor.execute {
                    try {
                        val manager = VersionBlockManager(versionStorePath)
                        var fileSize = 0L
                        val inputStream = when {
                            isShizukuPath(path) -> {
                                val svc = getShizukuServiceSync()
                                fileSize = svc.getFileSize(getCleanPath(path))
                                svc.openFile(getCleanPath(path), "r")?.let { java.io.FileInputStream(it.fileDescriptor) }
                            }
                            path.startsWith("content://") -> {
                                val uri = Uri.parse(path)
                                DocumentFile.fromSingleUri(ctx, uri)?.let { df ->
                                    fileSize = df.length()
                                }
                                ctx.contentResolver.openInputStream(uri)
                            }
                            else -> {
                                val file = File(path)
                                if (file.exists()) {
                                    fileSize = file.length()
                                    file.inputStream()
                                } else null
                            }
                        }

                        if (inputStream == null) {
                            mainHandler.post { result.error("EXTRACT_ERROR", "Could not open input stream for $path", null) }
                            return@execute
                        }

                        val success = manager.extractModifiedBlocks(inputStream, fileSize, changedBlocks)
                        mainHandler.post { result.success(success) }
                    } catch (e: Exception) {
                        mainHandler.post { result.error("EXTRACT_ERROR", e.message, null) }
                    }
                }
            }
            "reconstructFromDeltas" -> {
                val layoutHashes = call.argument<List<String>>("layoutHashes") ?: emptyList()
                val livePath = call.argument<String>("livePath") ?: return result.error("ARG_MISSING", "livePath missing", null)
                val restorePath = call.argument<String>("restorePath") ?: return result.error("ARG_MISSING", "restorePath missing", null)
                val versionStorePath = call.argument<String>("versionStorePath") ?: return result.error("ARG_MISSING", "versionStorePath missing", null)

                executor.execute {
                    try {
                        val manager = VersionBlockManager(versionStorePath)
                        var liveFileSize = 0L
                        val liveFileChannel = when {
                            isShizukuPath(livePath) -> {
                                val svc = getShizukuServiceSync()
                                liveFileSize = svc.getFileSize(getCleanPath(livePath))
                                svc.openFile(getCleanPath(livePath), "r")?.let { java.io.FileInputStream(it.fileDescriptor).channel }
                            }
                            livePath.startsWith("content://") -> {
                                val uri = Uri.parse(livePath)
                                DocumentFile.fromSingleUri(ctx, uri)?.let { df ->
                                    liveFileSize = df.length()
                                }
                                ctx.contentResolver.openFileDescriptor(uri, "r")?.let { java.io.FileInputStream(it.fileDescriptor).channel }
                            }
                            else -> {
                                val file = File(livePath)
                                if (file.exists()) {
                                    liveFileSize = file.length()
                                    java.io.FileInputStream(file).channel
                                } else null
                            }
                        }

                        val outputStream = when {
                            isShizukuPath(restorePath) -> {
                                val svc = getShizukuServiceSync()
                                svc.openFile(getCleanPath(restorePath), "wt")?.let { java.io.FileOutputStream(it.fileDescriptor) }
                            }
                            restorePath.startsWith("content://") -> {
                                ctx.contentResolver.openFileDescriptor(Uri.parse(restorePath), "wt")?.let { java.io.FileOutputStream(it.fileDescriptor) }
                            }
                            else -> {
                                val file = File(restorePath)
                                file.parentFile?.mkdirs()
                                file.outputStream()
                            }
                        }

                        if (outputStream == null) {
                            liveFileChannel?.close()
                            mainHandler.post { result.error("RECONSTRUCT_ERROR", "Could not open output stream for $restorePath", null) }
                            return@execute
                        }

                        val success = manager.reconstructFromDeltas(layoutHashes, liveFileChannel, liveFileSize, outputStream)
                        liveFileChannel?.close()
                        // outputStream is closed inside reconstructFromDeltas (.use block)
                        mainHandler.post { result.success(success) }
                    } catch (e: Exception) {
                        mainHandler.post { result.error("RECONSTRUCT_ERROR", e.message, null) }
                    }
                }
            }
            "calculateBlockHashesAndHash" -> handleCalculateBlockHashesAndHash(call, result)

            "uploadFileNative" -> uploadManager.handleUploadFile(call, result)
            "downloadFileNative" -> downloadManager.handleDownloadFile(call, result)
            "listLocalBackups" -> {
                val relPath = call.argument<String>("relPath") ?: return result.error("ARG_MISSING", "relPath missing", null)
                result.success(downloadManager.listLocalBackups(relPath))
            }
            "restoreLocalBackup" -> {
                val backupId = call.argument<String>("backupId") ?: return result.error("ARG_MISSING", "backupId missing", null)
                val destPath = call.argument<String>("destPath") ?: return result.error("ARG_MISSING", "destPath missing", null)
                val ok = downloadManager.restoreLocalBackup(backupId, java.io.File(destPath))
                result.success(ok)
            }
            "setFileTimestamp" -> handleSetFileTimestamp(call, result)
            "getFileInfo" -> handleGetFileInfo(call, result)
            "clearCache" -> {
                fileScanner.clearCache()
                result.success(true)
            }
            "mkdirs" -> {
                val path = call.argument<String>("path") ?: return result.error("ARG_MISSING", "path missing", null)
                executor.execute {
                    try {
                        val success = when {
                            path.startsWith("shizuku://") -> getShizukuServiceSync().mkdirs(getCleanPath(path))
                            path.startsWith("content://") -> {
                                // SAF doesn't have a direct 'mkdirs', but we handle it during download
                                true 
                            }
                            else -> File(path).mkdirs()
                        }
                        mainHandler.post { result.success(success) }
                    } catch (e: Exception) {
                        mainHandler.post { result.error("MKDIRS_ERROR", e.message, null) }
                    }
                }
            }
            "renameFile" -> {
                val oldPath = call.argument<String>("oldPath") ?: return result.error("ARG_MISSING", "oldPath missing", null)
                val newPath = call.argument<String>("newPath") ?: return result.error("ARG_MISSING", "newPath missing", null)
                executor.execute {
                    try {
                        val ok = when {
                            isShizukuPath(oldPath) -> getShizukuServiceSync().renameFile(getCleanPath(oldPath), getCleanPath(newPath))
                            oldPath.startsWith("content://") -> {
                                // SAF rename is complex and requires document ID. 
                                // For now, we only support raw and Shizuku for local versioning.
                                false
                            }
                            else -> File(oldPath).renameTo(File(newPath))
                        }
                        mainHandler.post { result.success(ok) }
                    } catch (e: Exception) {
                        mainHandler.post { result.error("RENAME_ERROR", e.message, null) }
                    }
                }
            }
            "deleteFile" -> {
                val path = call.argument<String>("path") ?: return result.error("ARG_MISSING", "path missing", null)
                executor.execute {
                    try {
                        val ok = when {
                            isShizukuPath(path) -> getShizukuServiceSync().deleteFile(getCleanPath(path))
                            path.startsWith("content://") -> false
                            else -> File(path).delete()
                        }
                        mainHandler.post { result.success(ok) }
                    } catch (e: Exception) {
                        mainHandler.post { result.error("DELETE_ERROR", e.message, null) }
                    }
                }
            }
            "startMonitoring" -> {
                val packages = call.argument<List<String>>("packages") ?: emptyList()
                val interval = (call.argument<Any>("interval") as? Number)?.toLong() ?: 15000L
                automationEngine.startMonitoring(packages, interval)
                result.success(true)
            }
            "stopMonitoring" -> {
                automationEngine.stopMonitoring()
                result.success(true)
            }
            "getLocalizedString" -> {
                val key = call.argument<String>("key") ?: return result.error("ARG_MISSING", "key missing", null)
                val resId = ctx.resources.getIdentifier(key, "string", ctx.packageName)
                if (resId != 0) {
                    result.success(ctx.getString(resId))
                } else {
                    result.error("NOT_FOUND", "String resource with key '$key' not found", null)
                }
            }
            "setNativeLocale" -> {
                val lang = call.argument<String>("languageCode") ?: return result.error("ARG_MISSING", "languageCode missing", null)
                try {
                    val locale = java.util.Locale(lang)
                    java.util.Locale.setDefault(locale)
                    val resources = ctx.resources
                    val config = resources.configuration
                    config.setLocale(locale)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        ctx.createConfigurationContext(config)
                    } else {
                        resources.updateConfiguration(config, resources.displayMetrics)
                    }
                    android.util.Log.d("VaultSync", "Native locale updated to: $lang")
                    result.success(true)
                } catch (e: Exception) {
                    result.error("LOCALE_ERROR", e.message, null)
                }
            }
            "getSwitchSaveRoot" -> {
                val uriStr = call.argument<String>("uri") ?: return result.error("ARG_MISSING", "uri missing", null)
                val root = fileScanner.findSwitchSaveRoot(Uri.parse(uriStr))
                result.success(root.toString())
            }
            "readEdenUserId" -> {
                val uriStr = call.argument<String>("uri") ?: return result.error("ARG_MISSING", "uri missing", null)
                val ctx = context ?: return result.error("NO_CONTEXT", "Context is null", null)
                executor.execute {
                    try {
                        // ProfileDataRaw layout (from Eden source):
                        //   [0x00-0x0F] 16-byte header padding
                        //   [0x10+N*0xC8] UserRaw[N].uuid — 16-byte UUID at start of each 200-byte entry
                        val PROFILE_HEADER = 0x10
                        val USER_RAW_SIZE  = 0xC8  // sizeof(UserRaw) per static_assert
                        val MAX_USERS      = 8

                        fun extractUserId(bytes: ByteArray): String? {
                            for (i in 0 until MAX_USERS) {
                                val offset = PROFILE_HEADER + i * USER_RAW_SIZE
                                if (offset + 16 > bytes.size) break
                                val uuidBytes = bytes.sliceArray(offset until offset + 16)
                                if (uuidBytes.any { it != 0.toByte() }) {
                                    // Eden stores the UUID as two little-endian u64s.
                                    // The save folder name is formatted as {uuid[1]}{uuid[0]},
                                    // which equals reversing all 16 raw bytes before hex-encoding.
                                    return uuidBytes.reversedArray().joinToString("") { "%02x".format(it) }.uppercase()
                                }
                            }
                            return null
                        }

                        val PROFILES_SEGMENTS = listOf("nand", "system", "save", "8000000000000010", "su", "avators")

                        val userId = when {
                            uriStr.startsWith("content://") -> {
                                var current: DocumentFile? = DocumentFile.fromTreeUri(ctx, Uri.parse(uriStr))
                                for (segment in PROFILES_SEGMENTS) {
                                    current = current?.let { fileScanner.findFileStrict(it, segment) }
                                    if (current == null) break
                                }
                                val profileFile = current?.let { fileScanner.findFileStrict(it, "profiles.dat") }
                                profileFile?.let { pf ->
                                    ctx.contentResolver.openInputStream(pf.uri)?.use { extractUserId(it.readBytes()) }
                                }
                            }
                            uriStr.startsWith("shizuku://") -> {
                                val cleanPath = getCleanPath(uriStr)
                                val svc = getShizukuServiceSync()
                                val probePaths = listOf(
                                    "$cleanPath/nand/system/save/8000000000000010/su/avators/profiles.dat",
                                    "$cleanPath/files/nand/system/save/8000000000000010/su/avators/profiles.dat"
                                )
                                var found: String? = null
                                for (path in probePaths) {
                                    val pfd = svc.openFile(path, "r") ?: continue
                                    found = pfd.use { FileInputStream(it.fileDescriptor).use { s -> extractUserId(s.readBytes()) } }
                                    if (found != null) break
                                }
                                found
                            }
                            else -> {
                                val cleanPath = getCleanPath(uriStr)
                                val probePaths = listOf(
                                    "$cleanPath/nand/system/save/8000000000000010/su/avators/profiles.dat",
                                    "$cleanPath/files/nand/system/save/8000000000000010/su/avators/profiles.dat"
                                )
                                probePaths.firstNotNullOfOrNull { path ->
                                    val f = File(path)
                                    if (f.exists()) extractUserId(f.readBytes()) else null
                                }
                            }
                        }

                        android.util.Log.i("VaultSync", "🎮 EDEN: User ID probe result: $userId")
                        mainHandler.post { result.success(userId) }
                    } catch (e: Exception) {
                        android.util.Log.e("VaultSync", "readEdenUserId failed", e)
                        mainHandler.post { result.success(null) }
                    }
                }
            }
            "findSwitchProfileId" -> {
                val uriStr = call.argument<String>("uri") ?: return result.error("ARG_MISSING", "uri missing", null)
                executor.execute {
                    try {
                        val profileId = when {
                            uriStr.startsWith("shizuku://") -> {
                                val cleanPath = getCleanPath(uriStr)
                                // Standard probe locations for Shizuku/POSIX
                                val probePaths = listOf(
                                    "$cleanPath/nand/user/save/0000000000000000",
                                    "$cleanPath/files/nand/user/save/0000000000000000"
                                )
                                var found: String? = null
                                val profileRegex = Regex("^[0-9A-Fa-f]{32}$")
                                val svc = getShizukuServiceSync()
                                
                                for (p in probePaths) {
                                    val children = svc.listFiles(p) ?: continue
                                    for (child in children) {
                                        if (profileRegex.matches(child) && child != "00000000000000000000000000000000") {
                                            found = child
                                            break
                                        }
                                    }
                                    if (found != null) break
                                }
                                found
                            }
                            else -> fileScanner.findSwitchProfileId(Uri.parse(uriStr))
                        }
                        android.util.Log.d("VaultSync", "🎮 SWITCH: Probed profile ID: $profileId")
                        mainHandler.post { result.success(profileId) }
                    } catch (e: Exception) {
                        android.util.Log.e("VaultSync", "findSwitchProfileId failed", e)
                        mainHandler.post { result.success(null) }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun handleCalculateHash(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path") ?: return result.error("ARG_MISSING", "path missing", null)
        val ctx = context ?: return result.error("NO_CONTEXT", "Context is null", null)
        executor.execute {
            try {
                val input = when {
                    path.startsWith("shizuku://") -> {
                        getShizukuServiceSync().openFile(getCleanPath(path), "r")?.let { 
                            FileInputStream(it.fileDescriptor)
                        }
                    }
                    path.startsWith("content://") -> ctx.contentResolver.openInputStream(Uri.parse(path))
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
                mainHandler.post { result.success(cryptoEngine.calculateHash(digest.digest(), digest.digest().size)) }
            } catch (e: Exception) {
                mainHandler.post { result.error("HASH_ERROR", e.message, null) }
            }
        }
    }

    private fun handleScanRecursive(call: MethodCall, result: MethodChannel.Result) {
        val path           = call.argument<String>("path") ?: return result.error("ARG_MISSING", "path missing", null)
        val systemId       = call.argument<String>("systemId") ?: return result.error("ARG_MISSING", "systemId missing", null)
        val ignoredFolders = call.argument<List<String>>("ignoredFolders") ?: emptyList()

        executor.execute {
            try {
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

    private fun getCleanPath(path: String): String = path.replace("shizuku://", "")

    private fun checkShizukuExtensionsRecursive(svc: IShizukuService, path: String, extensions: List<String>, depth: Int): Boolean {
        if (depth > FileScanner.MAX_EXTENSION_SCAN_DEPTH) return false
        try {
            val files = JSONArray(svc.listFileInfo(path))
            for (i in 0 until files.length()) {
                val f = files.getJSONObject(i)
                val name = f.getString("name").lowercase()
                if (f.getBoolean("isDirectory")) {
                    val subPath = if (path.endsWith("/")) "$path$name" else "$path/$name"
                    if (checkShizukuExtensionsRecursive(svc, subPath, extensions, depth + 1)) return true
                } else {
                    if (extensions.any { name.endsWith(".$it") }) return true
                }
            }
        } catch (_: Exception) {}
        return false
    }

    private fun checkLocalExtensionsRecursive(dir: File, extensions: List<String>, depth: Int): Boolean {
        if (depth > FileScanner.MAX_EXTENSION_SCAN_DEPTH) return false
        try {
            dir.listFiles()?.forEach { file ->
                val name = file.name.lowercase()
                if (file.isDirectory) {
                    if (checkLocalExtensionsRecursive(file, extensions, depth + 1)) return true
                } else {
                    if (extensions.any { name.endsWith(".$it") }) return true
                }
            }
        } catch (_: Exception) {}
        return false
    }

    private fun handleCalculateBlockHashes(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path") ?: return result.error("ARG_MISSING", "path missing", null)
        val masterKey = call.argument<String>("masterKey")
        val ctx = context ?: return result.error("NO_CONTEXT", "Context is null", null)
        executor.execute {
            try {
                var fileSize = 0L
                val input = when {
                    path.startsWith("shizuku://") -> {
                        getShizukuServiceSync().let { svc ->
                            fileSize = svc.getFileSize(getCleanPath(path))
                            svc.openFile(getCleanPath(path), "r")?.let { FileInputStream(it.fileDescriptor) }
                        }
                    }
                    path.startsWith("content://") -> {
                        val uri = Uri.parse(path)
                        DocumentFile.fromSingleUri(ctx, uri)?.let { df ->
                            fileSize = df.length()
                        }
                        ctx.contentResolver.openInputStream(uri)
                    }
                    else -> {
                        val f = File(path)
                        fileSize = f.length()
                        f.inputStream()
                    }
                }
                
                val secretKey = masterKey?.let { 
                    val keyBytes = android.util.Base64.decode(it, android.util.Base64.URL_SAFE).sliceArray(0 until 32)
                    javax.crypto.spec.SecretKeySpec(keyBytes, "AES")
                }
                
                val blockSize = CryptoEngine.getBlockSize(fileSize)
                val encryptedBlockSize = CryptoEngine.getEncryptedBlockSize(fileSize)
                
                val blockHashes = JSONArray()
                val buffer = ByteArray(blockSize)
                val encryptedBuffer = ByteArray(encryptedBlockSize)
                
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

    private fun handleCalculateBlockHashesAndHash(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path") ?: return result.error("ARG_MISSING", "path missing", null)
        val masterKey = call.argument<String>("masterKey")
        val ctx = context ?: return result.error("NO_CONTEXT", "Context is null", null)
        executor.execute {
            try {
                var fileSize = 0L
                val secretKey = masterKey?.let {
                    val keyBytes = android.util.Base64.decode(it, android.util.Base64.URL_SAFE).sliceArray(0 until 32)
                    javax.crypto.spec.SecretKeySpec(keyBytes, "AES")
                }
                val fileDigest = java.security.MessageDigest.getInstance("SHA-256")
                val blockHashes = JSONArray()
                val resultObj = try {
                    if (path.startsWith("shizuku://")) {
                        getShizukuServiceSync().let { svc ->
                            val cleanPath = getCleanPath(path)
                            fileSize = svc.getFileSize(cleanPath)
                            svc.openFile(cleanPath, "r")?.use { pfd ->
                                java.io.FileInputStream(pfd.fileDescriptor).use { stream ->
                                    processHashingStream(stream, secretKey, fileSize, fileDigest, blockHashes)
                                }
                            }
                        }
                    } else if (path.startsWith("content://")) {
                        val uri = Uri.parse(path)
                        DocumentFile.fromSingleUri(ctx, uri)?.let { df ->
                            fileSize = df.length()
                        }
                        ctx.contentResolver.openInputStream(uri)?.use { stream ->
                            processHashingStream(stream, secretKey, fileSize, fileDigest, blockHashes)
                        }
                    } else {
                        val f = java.io.File(path)
                        fileSize = f.length()
                        f.inputStream().use { stream ->
                            processHashingStream(stream, secretKey, fileSize, fileDigest, blockHashes)
                        }
                    }

                    // Finalize double-hash
                    val firstDigest = fileDigest.digest()
                    val fileHash = cryptoEngine.calculateHash(firstDigest, firstDigest.size)
                    
                    JSONObject().apply {
                        put("blockHashes", blockHashes)
                        put("fileHash", fileHash)
                    }
                } catch (e: Exception) {
                    throw e
                }

                mainHandler.post { result.success(resultObj?.toString()) }
            } catch (e: Exception) {
                mainHandler.post { result.error("COMBINED_HASH_ERROR", e.message, null) }
            }
        }
    }

    private fun handleSetFileTimestamp(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path") ?: return result.error("ARG_MISSING", "path missing", null)
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


    private fun processHashingStream(
        stream: java.io.InputStream,
        secretKey: javax.crypto.spec.SecretKeySpec?,
        fileSize: Long,
        fileDigest: java.security.MessageDigest,
        blockHashes: JSONArray
    ) {
        val blockSize = CryptoEngine.getBlockSize(fileSize)
        val encryptedBlockSize = CryptoEngine.getEncryptedBlockSize(fileSize)
        val buffer = ByteArray(blockSize)
        val encryptedBuffer = ByteArray(encryptedBlockSize)

        while (true) {
            val read = stream.read(buffer)
            if (read == -1) break

            // Feed raw bytes into the file-level digest
            fileDigest.update(buffer, 0, read)

            // Compute encrypted block hash
            if (secretKey != null) {
                val encryptedLength = cryptoEngine.encryptBlock(buffer, read, secretKey, encryptedBuffer)
                blockHashes.put(cryptoEngine.calculateHash(encryptedBuffer, encryptedLength))
            } else {
                blockHashes.put(cryptoEngine.calculateHash(buffer, read))
            }
        }
    }
    private fun handleGetFileInfo(call: MethodCall, result: MethodChannel.Result) {
        val uriStr = call.argument<String>("uri") ?: return result.error("ARG_MISSING", "uri missing", null)
        val ctx = context ?: return result.error("NO_CONTEXT", "Context is null", null)
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
                    val df = DocumentFile.fromSingleUri(ctx, Uri.parse(uriStr))
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

    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }
    override fun onDetachedFromActivity() { activity = null }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val ctx = context ?: return false
        if (requestCode == PICK_DIRECTORY_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK && data != null) {
                val uri = data.data
                if (uri != null) {
                    ctx.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
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
