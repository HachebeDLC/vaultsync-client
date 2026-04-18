package com.vaultsync.launcher

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import android.system.Os
import androidx.documentfile.provider.DocumentFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Callable
import kotlin.math.min

class FileScanner(private val context: Context) {
    private val headerScanner = BinaryHeaderScanner()

    companion object {
        const val MAX_EXTENSION_SCAN_DEPTH = 3
        const val MAX_SCAN_DEPTH = 15

        // Systems whose user-configured path is already narrowed to
        // a save-only directory (SAVEDATA/, nand/user/save/ etc.)
        // — safe to sync every file found, no extension check needed.
        private val SYNC_EVERYTHING_SIDS = setOf("switch", "eden")

        // Systems that use a structural scope guard (relPath must
        // contain a known anchor) instead of extension matching.
        // Files inside are typically extensionless binary blobs.
        private val SCOPE_GUARDED_SIDS = setOf(
            "wii",                          // guard: Wii/title/00010000/
            "3ds", "citra", "azahar"        // guard: sdmc/ or nand/
        )

        // Extension whitelist for all other systems.
        // Deliberately excludes: ".save", ".bin" (too generic),
        // ".dat" (used by covers/config on several emulators).
        val SAVE_EXTENSIONS = setOf(
            // RetroArch universal
            "srm", "state",
            // RetroArch auto-save states (bare extension is 'auto' after substringAfterLast)
            "auto",
            // PS1 (DuckStation standalone, ePSXe, FPse)
            "mcd", "mcr",
            // PS2 (AetherSX2/NetherSX2/PCSX2 standalone)
            "ps2",
            // GameCube (Dolphin individual slot saves & raw memcard images)
            "gci", "raw",
            // Nintendo DS / DSi (Drastic, MelonDS standalone)
            "dsv", "dss",
            // Dreamcast (Redream, Flycast)
            "vms", "vmu",
            // N64 (Mupen64Plus FZ — SRAM, FlashRAM, MemPak, EEPROM)
            "eep", "sra", "fla", "mpk",
            // Saturn (YabaSanshiro standalone)
            "bcr",
            // NeoGeo Pocket (NGP.emu)
            "ngf", "ngs",
            // DS saves used by some RetroArch cores
            "sav",
            // RetroArch save-state screenshot thumbnails
            "png",
            // Generic backup/export formats used by several emulators
            "bak", "vfs",
            // N64 EEPROM (some RetroArch core variants)
            "nv",
            // Real-time clock data (GB/GBC emulators)
            "rtc",
            // Alternative PS1 memory cards (DuckStation/ePSXe)
            "mcx", "mc",
            // DSi saves
            "dsx"
        )

        /**
         * Picks the candidate with the greatest mtime from a list of
         * (name, mtime) pairs. Returns null if the list is empty. On ties,
         * first-encountered wins (stable).
         *
         * Extracted as a pure helper from `findSwitchProfileId` so the
         * selection rule can be unit-tested without SAF / DocumentFile.
         */
        fun pickBestProfileByMtime(candidates: List<Pair<String, Long>>): String? {
            return candidates.maxByOrNull { it.second }?.first
        }
    }

    private val safLock = Any()
    private val safDirectoryCache = ConcurrentHashMap<String, DocumentFile>()
    // parentUri -> Map<FileName, DocumentFile>
    private val directoryContentCache = ConcurrentHashMap<String, Map<String, DocumentFile>>()

    fun clearCache() {
        safDirectoryCache.clear()
        directoryContentCache.clear()
    }

    private fun getTreeUri(uri: Uri): Uri {
        return try {
            val treeId = DocumentsContract.getTreeDocumentId(uri)
            DocumentsContract.buildTreeDocumentUri(uri.authority, treeId)
        } catch (e: Exception) {
            uri
        }
    }

    fun getDocIdSafely(uri: Uri): String {
        return try {
            if (DocumentsContract.isDocumentUri(context, uri)) {
                DocumentsContract.getDocumentId(uri)
            } else {
                DocumentsContract.getTreeDocumentId(uri)
            }
        } catch (e: Exception) {
            val paths = uri.pathSegments
            if (paths.size >= 4 && paths[0] == "tree" && paths[2] == "document") {
                paths[3]
            } else if (paths.size >= 2 && paths[0] == "tree") {
                paths[1]
            } else {
                uri.lastPathSegment ?: ""
            }
        }
    }

    fun findFileStrict(parent: DocumentFile, name: String): DocumentFile? {
        val parentUriStr = parent.uri.toString()
        
        val cached = directoryContentCache[parentUriStr]?.get(name)
        if (cached != null) return cached

        // Standard SAF iterate (Bypasses caching and name filtering bugs)
        val existingMap = mutableMapOf<String, DocumentFile>()
        parent.listFiles().forEach { file ->
            val fileName = file.name
            if (fileName != null) {
                existingMap[fileName] = file
            }
        }
        directoryContentCache[parentUriStr] = existingMap
        return existingMap[name]
    }

    fun findSwitchSaveRoot(baseUri: Uri): Uri {
        var current = DocumentFile.fromTreeUri(context, baseUri) ?: return baseUri
        val segments = listOf("nand", "user", "save", "0000000000000000")
        
        val filesDir = findFileStrict(current, "files")
        if (filesDir != null) current = filesDir

        for (segment in segments) {
            val next = findFileStrict(current, segment)
            if (next != null && next.isDirectory) {
                current = next
            } else {
                break
            }
        }
        
        // Try to dive one level deeper into the 32-character Profile ID folder
        val profileRegex = Regex("^[0-9A-Fa-f]{32}$")
        for (child in current.listFiles()) {
            if (child.isDirectory) {
                val name = child.name ?: continue
                if (profileRegex.matches(name)) {
                    current = child
                    break
                }
            }
        }
        return current.uri
    }

    fun findSwitchProfileId(baseUri: Uri): String? {
        val profileRegex = Regex("^[0-9A-Fa-f]{32}$")
        var current = DocumentFile.fromTreeUri(context, baseUri) ?: return null

        // Navigate into 'files/' if it exists at the root
        val filesDir = findFileStrict(current, "files")
        if (filesDir != null) current = filesDir

        // Walk down to nand/user/save/0000000000000000
        for (segment in listOf("nand", "user", "save", "0000000000000000")) {
            val next = findFileStrict(current, segment)
            if (next != null && next.isDirectory) {
                current = next
            } else {
                return null
            }
        }

        // 'current' is now 0000000000000000; its direct children are the profile ID folders
        val candidates = mutableListOf<DocumentFile>()
        current.listFiles().forEach { child ->
            if (child.isDirectory) {
                val name = child.name ?: return@forEach
                if (profileRegex.matches(name) && name != "00000000000000000000000000000000") {
                    candidates.add(child)
                }
            }
        }
        if (candidates.isEmpty()) return null
        if (candidates.size == 1) return candidates[0].name

        // Multiple non-zero profiles — pick the one whose subtree was most
        // recently touched (mirrors Argosy's SwitchSaveHandler.findActiveProfileFolder).
        val scored = candidates.mapNotNull { c ->
            val name = c.name ?: return@mapNotNull null
            name to newestMtimeUnder(c)
        }
        return pickBestProfileByMtime(scored)
    }

    private fun newestMtimeUnder(dir: DocumentFile): Long {
        var newest = dir.lastModified()
        for (child in dir.listFiles()) {
            val m = if (child.isDirectory) newestMtimeUnder(child) else child.lastModified()
            if (m > newest) newest = m
        }
        return newest
    }

    fun getOrCreateDirectory(parent: DocumentFile, name: String): DocumentFile {
        synchronized(safLock) {
            android.util.Log.d("VaultSync", "📁 SAF: getOrCreateDirectory '$name' in '${parent.name ?: parent.uri}'")
            val existing = findFileStrict(parent, name)
            if (existing != null) {
                if (existing.isDirectory) {
                    android.util.Log.d("VaultSync", "📁 SAF: Found existing directory '$name'")
                    return existing
                } else {
                    android.util.Log.w("VaultSync", "📁 SAF: Found FILE where DIRECTORY '$name' expected! Deleting file...")
                    existing.delete()
                }
            }
            
            android.util.Log.i("VaultSync", "📁 SAF: Creating directory '$name'...")
            val created = parent.createDirectory(name) ?: throw Exception("CreateDirectory failed for '$name'")
            
            // SAF Cache duplicate check
            if (created.name != null && created.name != name) {
                android.util.Log.w("VaultSync", "⚠️ SAF: Created duplicate '${created.name}' instead of '$name'. Fixing...")
                created.delete()
                return findFileStrict(parent, name) ?: throw Exception("Fallback resolve failed for $name after duplicate creation")
            }

            android.util.Log.d("VaultSync", "📁 SAF: Successfully created directory '$name'")
            val parentUriStr = parent.uri.toString()
            val existingMap = directoryContentCache[parentUriStr]?.toMutableMap() ?: mutableMapOf()
            existingMap[name] = created
            directoryContentCache[parentUriStr] = existingMap
            return created
        }
    }

    fun getOrCreateFile(parent: DocumentFile, name: String, mime: String): DocumentFile {
        synchronized(safLock) {
            android.util.Log.d("VaultSync", "📄 SAF: getOrCreateFile '$name' in '${parent.name ?: parent.uri}'")
            val existing = findFileStrict(parent, name)
            if (existing != null) {
                if (existing.isFile) {
                    android.util.Log.d("VaultSync", "📄 SAF: Found existing file '$name'")
                    return existing
                } else {
                    android.util.Log.w("VaultSync", "📄 SAF: Found DIRECTORY where FILE '$name' expected! Deleting directory...")
                    existing.delete()
                }
            }
            
            android.util.Log.i("VaultSync", "📄 SAF: Creating file '$name' ($mime)...")
            val created = parent.createFile(mime, name) ?: throw Exception("CreateFile failed for '$name'")

            // SAF Cache duplicate check
            if (created.name != null && created.name != name) {
                android.util.Log.w("VaultSync", "⚠️ SAF: Created duplicate '${created.name}' instead of '$name'. Fixing...")
                created.delete()
                return findFileStrict(parent, name) ?: throw Exception("Fallback resolve failed for file $name after duplicate creation")
            }

            android.util.Log.d("VaultSync", "📄 SAF: Successfully created file '$name'")
            val parentUriStr = parent.uri.toString()
            val existingMap = directoryContentCache[parentUriStr]?.toMutableMap() ?: mutableMapOf()
            existingMap[name] = created
            directoryContentCache[parentUriStr] = existingMap
            return created
        }
    }

    /**
     * Returns true if [relPath]/[fileName] should be included in the
     * sync manifest for [sid] (lowercased system ID).
     *
     * [relPath]  — path relative to the scan root, e.g. "GC/EUR/GALE01.gci"
     * [fileName] — bare filename, e.g. "GALE01.gci"
     */
    private fun shouldSyncFile(sid: String, relPath: String, fileName: String): Boolean {
        if (fileName.startsWith(".")) return false
        val lowerRel = relPath.lowercase()
        
        // 1. Switch / Eden Stricter Filtering
        if (sid == "switch" || sid == "eden") {
            // Since effectivePath might already be 'save/', we can't strictly require 'nand/user/save' in relPath.
            // We just ensure it's an actual game save by looking for the Title ID prefix (0100).
            return lowerRel.contains("0100") 
        }

        // 2. 3DS (Azahar / Citra) Stricter Filtering
        // We only want actual title data, not extdata or system apps.
        if (sid == "3ds" || sid == "citra" || sid == "azahar") {
            // Must be in a game title folder
            if (!lowerRel.contains("title/00040000")) return false
            // Exclude everything except the actual save file (usually 'data' or similar)
            // But 3DS is complex, so we'll at least block known junk extensions
            val junkExtensions = setOf("tik", "tmd", "app", "metadata", "icon")
            val ext = fileName.substringAfterLast('.', "").lowercase()
            if (junkExtensions.contains(ext)) return false
            return true
        }

        if (sid == "psp" || sid == "ppsspp") {
            return lowerRel.contains("savedata/") || lowerRel.contains("ppsspp_state/") || !lowerRel.contains("/")
        }
        if (sid == "wii") {
            return lowerRel.contains("title/0001000")
        }

        val ext = fileName.substringAfterLast('.', "").lowercase()
        return ext.isNotEmpty() && SAVE_EXTENSIONS.contains(ext)
    }

    fun scanSafRecursive(
        uri: Uri, 
        systemId: String, 
        ignoredFoldersList: List<String>, 
        allowedExtensions: Set<String>,
        combinedIgnores: Set<String>
    ): JSONArray {
        android.util.Log.d("VaultSync", "🔍 SCAN: Starting SAF Recursive Scan for $systemId at $uri")
        val results = JSONArray()
        val sid = systemId.lowercase()
        val isSwitch = sid == "switch" || sid == "eden"
        
        val ignoreSet = ignoredFoldersList.map { it.lowercase() }.toHashSet()
        val combinedIgnoreSet = combinedIgnores.map { it.lowercase() }.toHashSet()

        val uriStr = uri.toString().lowercase()
        // Files inside Android/data/ are app-private — MediaStore can't index them,
        // so the SAF cursor's LAST_MODIFIED is unreliable. Only pay the Os.fstat()
        // IPC cost for these paths; everywhere else the cursor value is trustworthy.
        val needsAccurateMtime = uriStr.contains("android%2fdata") || uriStr.contains("android/data")

        val treeUri = getTreeUri(uri)
        val startDocId = getDocIdSafely(uri)
        // Collect (resultIndex, docUri) pairs for deferred parallel fstat
        val pendingFstats = if (needsAccurateMtime) mutableListOf<Pair<Int, Uri>>() else null

        fun walkSaf(currentDocId: String, currentRelPath: String, depth: Int) {
            if (depth > MAX_SCAN_DEPTH) return
            
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, currentDocId)
            context.contentResolver.query(
                childrenUri, 
                arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID, 
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME, 
                    DocumentsContract.Document.COLUMN_MIME_TYPE, 
                    DocumentsContract.Document.COLUMN_SIZE, 
                    DocumentsContract.Document.COLUMN_LAST_MODIFIED
                ), 
                null, null, null
            )?.use { cursor ->
                val currentLevelMap = mutableMapOf<String, DocumentFile>()
                val parentUriStr = DocumentsContract.buildDocumentUriUsingTree(treeUri, currentDocId).toString()

                while (cursor.moveToNext()) {
                    val id = cursor.getString(0)
                    val name = cursor.getString(1) ?: "unknown"
                    val mime = cursor.getString(2)
                    val relPath = if (currentRelPath.isEmpty()) name else "$currentRelPath/$name"

                    if (combinedIgnoreSet.contains(name.lowercase()) || ignoreSet.contains(relPath.lowercase())) continue

                    if (isSwitch) {
                        if (!relPath.contains("0100", ignoreCase = true) && 
                            !relPath.startsWith("nand", ignoreCase = true) && 
                            !relPath.startsWith("user", ignoreCase = true) &&
                            !relPath.startsWith("save", ignoreCase = true) &&
                            !relPath.startsWith("0000", ignoreCase = true)) continue
                    }

                    val isDir = mime == DocumentsContract.Document.MIME_TYPE_DIR
                    val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, id)
                    
                    // Add to index for O(1) subsequent lookups
                    val df = if (isDir) DocumentFile.fromTreeUri(context, docUri) else DocumentFile.fromSingleUri(context, docUri)
                    if (df != null) currentLevelMap[name] = df

                    if (isDir) {
                        android.util.Log.v("VaultSync", "  [DIR] $relPath")
                        results.put(JSONObject().apply {
                            put("name", name)
                            put("relPath", relPath)
                            put("isDirectory", true)
                            put("uri", docUri.toString())
                        })
                        walkSaf(id, relPath, depth + 1)
                    } else {
                        val sync = shouldSyncFile(sid, relPath, name)
                        if (sync) android.util.Log.v("VaultSync", "  [FILE] $relPath (MATCH)")
                        if (shouldSyncFile(sid, relPath, name)) {
                            var fSize = cursor.getLong(3)
                            var fLast = cursor.getLong(4)

                            if (fSize <= 0) {
                                val df = currentLevelMap[name]
                                fSize = df?.length() ?: 0
                                fLast = df?.lastModified() ?: 0
                            }

                            // Record index for deferred parallel fstat (if needed)
                            pendingFstats?.add(Pair(results.length(), docUri))

                            val probedMetadata = JSONObject()
                            try {
                                if (name == ".nx_save_meta.bin") {
                                    headerScanner.parseJksvMeta(context.contentResolver.openInputStream(docUri)!!)?.let {
                                        probedMetadata.put("titleId", it)
                                    }
                                } else if (name.endsWith(".gci", ignoreCase = true)) {
                                    headerScanner.parseGciHeader(context.contentResolver.openInputStream(docUri)!!)?.let {
                                        probedMetadata.put("gameId", it.gameId)
                                        probedMetadata.put("makerCode", it.makerCode)
                                        probedMetadata.put("region", it.region)
                                    }
                                } else if (name == "PARAM.SFO") {
                                    headerScanner.parseParamSfo(context.contentResolver.openInputStream(docUri)!!)?.let {
                                        it["DISC_ID"]?.let { id -> probedMetadata.put("gameId", id) }
                                        it["TITLE"]?.let { title -> probedMetadata.put("title", title) }
                                    }
                                }
                            } catch (_: Exception) {}

                            results.put(JSONObject().apply {
                                put("name", name)
                                put("relPath", relPath)
                                put("isDirectory", false)
                                put("size", fSize)
                                put("lastModified", fLast)
                                put("uri", docUri.toString())
                                if (probedMetadata.length() > 0) {
                                    put("probedMetadata", probedMetadata)
                                }
                            })
                        }
                    }
                }
                directoryContentCache[parentUriStr] = currentLevelMap
            }
        }
        walkSaf(startDocId, "", 0)

        // Batch-fstat in parallel for Android/data/ files where SAF cursor
        // LAST_MODIFIED is unreliable. Uses Os.fstat() on file descriptors
        // to get kernel mtime. Parallelized to reduce IPC wall-clock time.
        if (pendingFstats != null && pendingFstats.isNotEmpty()) {
            val pool = Executors.newFixedThreadPool(min(pendingFstats.size, 8))
            val futures = pendingFstats.map { (idx, docUri) ->
                pool.submit(Callable<Pair<Int, Long>?> {
                    try {
                        context.contentResolver.openFileDescriptor(docUri, "r")?.use { pfd ->
                            val stat = Os.fstat(pfd.fileDescriptor)
                            if (stat.st_mtime > 0L) Pair(idx, stat.st_mtime * 1000L) else null
                        }
                    } catch (_: Exception) { null }
                })
            }
            for (future in futures) {
                val pair = future.get() ?: continue
                results.getJSONObject(pair.first).put("lastModified", pair.second)
            }
            pool.shutdown()
        }

        return results
    }

    fun scanShizukuRecursive(
        service: IShizukuService,
        cleanBase: String, 
        systemId: String, 
        ignoredFoldersList: List<String>, 
        allowedExtensions: Set<String>, 
        combinedIgnores: Set<String>
    ): JSONArray {
        val results = JSONArray()
        val sid = systemId.lowercase()
        val isSwitch = sid == "switch" || sid == "eden"
        
        val ignoreSet = ignoredFoldersList.map { it.lowercase() }.toHashSet()
        val combinedIgnoreSet = combinedIgnores.map { it.lowercase() }.toHashSet()
        val alreadyInZone = isSwitch && cleanBase.lowercase().contains("nand/user/save")

        fun walkShizuku(currentPath: String, currentRelPath: String, depth: Int) {
            if (depth > MAX_SCAN_DEPTH) return
            val files = JSONArray(service.listFileInfo(currentPath))
            for (i in 0 until files.length()) {
                val f = files.getJSONObject(i)
                val name = f.getString("name")
                val relPath = if (currentRelPath.isEmpty()) name else "$currentRelPath/$name"
                
                if (combinedIgnoreSet.contains(name.lowercase()) || ignoreSet.contains(relPath.lowercase())) continue

                if (isSwitch && !alreadyInZone) {
                    val inSavePath = relPath.contains("nand/user/save", ignoreCase = true)
                    if (!inSavePath && 
                        !relPath.startsWith("nand", ignoreCase = true) && 
                        !relPath.equals("nand", ignoreCase = true)) continue
                }
                
                val fullPath = if (currentPath.endsWith("/")) "$currentPath$name" else "$currentPath/$name"
                if (f.getBoolean("isDirectory")) {
                    results.put(JSONObject().apply {
                        put("name", name)
                        put("relPath", relPath)
                        put("isDirectory", true)
                        put("uri", "shizuku://$fullPath")
                    })
                    walkShizuku(fullPath, relPath, depth + 1)
                } else {
                    if (shouldSyncFile(sid, relPath, name)) {
                        val probedMetadata = JSONObject()
                        try {
                            if (name == ".nx_save_meta.bin" || name.endsWith(".gci", ignoreCase = true) || name == "PARAM.SFO") {
                                service.openFile(fullPath, "r")?.use { pfd ->
                                    java.io.FileInputStream(pfd.fileDescriptor).use { stream ->
                                        if (name == ".nx_save_meta.bin") {
                                            headerScanner.parseJksvMeta(stream)?.let { probedMetadata.put("titleId", it) }
                                        } else if (name.endsWith(".gci", ignoreCase = true)) {
                                            headerScanner.parseGciHeader(stream)?.let {
                                                probedMetadata.put("gameId", it.gameId)
                                                probedMetadata.put("makerCode", it.makerCode)
                                                probedMetadata.put("region", it.region)
                                            }
                                        } else if (name == "PARAM.SFO") {
                                            headerScanner.parseParamSfo(stream)?.let {
                                                it["DISC_ID"]?.let { id -> probedMetadata.put("gameId", id) }
                                                it["TITLE"]?.let { title -> probedMetadata.put("title", title) }
                                            }
                                        }
                                    }
                                }
                            }
                        } catch (_: Exception) {}

                        results.put(JSONObject().apply {
                            put("name", name)
                            put("relPath", relPath)
                            put("isDirectory", false)
                            put("size", f.getLong("size"))
                            put("lastModified", f.getLong("lastModified"))
                            put("uri", "shizuku://$fullPath")
                            if (probedMetadata.length() > 0) {
                                put("probedMetadata", probedMetadata)
                            }
                        })
                    }
                }
            }
        }
        walkShizuku(cleanBase, "", 0)
        return results
    }

    fun scanLocalRecursive(
        path: String, 
        systemId: String, 
        ignoredFoldersList: List<String>, 
        allowedExtensions: Set<String>, 
        combinedIgnores: Set<String>
    ): JSONArray {
        android.util.Log.d("VaultSync", "🔍 SCAN: Starting Local Recursive Scan for $systemId at $path")
        val results = JSONArray()
        val sid = systemId.lowercase()
        val isSwitch = sid == "switch" || sid == "eden"
        
        val ignoreSet = ignoredFoldersList.map { it.lowercase() }.toHashSet()
        val combinedIgnoreSet = combinedIgnores.map { it.lowercase() }.toHashSet()
        val alreadyInZone = isSwitch && path.lowercase().contains("nand/user/save")

        fun walkLocal(dir: File, currentRelPath: String) {
            dir.listFiles()?.forEach { file ->
                val relPath = if (currentRelPath.isEmpty()) file.name else "$currentRelPath/${file.name}"
                if (combinedIgnoreSet.contains(file.name.lowercase()) || ignoreSet.contains(relPath.lowercase())) return@forEach
                
                if (isSwitch && !alreadyInZone) {
                    val inSavePath = relPath.contains("nand/user/save", ignoreCase = true)
                    if (!inSavePath && 
                        !relPath.startsWith("nand", ignoreCase = true) && 
                        !relPath.equals("nand", ignoreCase = true)) return@forEach
                }

                if (file.isDirectory) {
                    results.put(JSONObject().apply {
                        put("name", file.name)
                        put("relPath", relPath)
                        put("isDirectory", true)
                        put("uri", file.absolutePath)
                    })
                    walkLocal(file, relPath)
                } else {
                    if (shouldSyncFile(sid, relPath, file.name)) {
                        val probedMetadata = JSONObject()
                        try {
                            if (file.name == ".nx_save_meta.bin") {
                                headerScanner.parseJksvMeta(file.absolutePath)?.let {
                                    probedMetadata.put("titleId", it)
                                }
                            } else if (file.name.endsWith(".gci", ignoreCase = true)) {
                                headerScanner.parseGciHeader(file.absolutePath)?.let {
                                    probedMetadata.put("gameId", it.gameId)
                                    probedMetadata.put("makerCode", it.makerCode)
                                    probedMetadata.put("region", it.region)
                                }
                            } else if (file.name == "PARAM.SFO") {
                                headerScanner.parseParamSfo(file.absolutePath)?.let {
                                    it["DISC_ID"]?.let { id -> probedMetadata.put("gameId", id) }
                                    it["TITLE"]?.let { title -> probedMetadata.put("title", title) }
                                }
                            }
                        } catch (_: Exception) {}

                        results.put(JSONObject().apply {
                            put("name", file.name)
                            put("relPath", relPath)
                            put("isDirectory", false)
                            put("size", file.length())
                            put("lastModified", file.lastModified())
                            put("uri", file.absolutePath)
                            if (probedMetadata.length() > 0) {
                                put("probedMetadata", probedMetadata)
                            }
                        })
                    }
                }
            }
        }
        walkLocal(File(path), "")
        return results
    }

    fun listSafDirectory(uri: Uri): JSONArray {
        val results = JSONArray()
        val rootDoc = DocumentFile.fromTreeUri(context, uri) ?: return results
        rootDoc.listFiles().forEach { file ->
            results.put(JSONObject().apply {
                put("name", file.name ?: "unknown")
                put("uri", file.uri.toString())
                put("isDirectory", file.isDirectory)
            })
        }
        return results
    }

    fun listLibraryNative(
        uri: Uri,
        shizukuService: IShizukuService?
    ): JSONArray {
        val results = JSONArray()
        val uriStr = uri.toString()

        try {
            when {
                uriStr.startsWith("shizuku://") -> {
                    val svc = shizukuService ?: return results
                    val cleanPath = uriStr.replace("shizuku://", "")
                    val files = JSONArray(svc.listFileInfo(cleanPath))
                    for (i in 0 until files.length()) {
                        val f = files.getJSONObject(i)
                        results.put(JSONObject().apply {
                            put("name", f.getString("name"))
                            put("isDirectory", f.getBoolean("isDirectory"))
                            put("uri", "shizuku://${if (cleanPath.endsWith("/")) cleanPath else "$cleanPath/"}${f.getString("name")}")
                        })
                    }
                }
                uriStr.startsWith("content://") -> {
                    android.util.Log.d("VaultSync", "listLibraryNative: using SAF for $uriStr")
                    val rootDoc = DocumentFile.fromTreeUri(context, uri)
                    if (rootDoc == null) {
                        android.util.Log.w("VaultSync", "listLibraryNative: fromTreeUri returned null")
                        return results
                    }
                    val files = rootDoc.listFiles()
                    android.util.Log.d("VaultSync", "listLibraryNative: found ${files.size} files in SAF root")
                    files.forEach { file ->
                        results.put(JSONObject().apply {
                            put("name", file.name ?: "unknown")
                            put("isDirectory", file.isDirectory)
                            put("uri", file.uri.toString())
                        })
                    }
                }
                else -> {
                    val dir = File(uriStr)
                    dir.listFiles()?.forEach { file ->
                        results.put(JSONObject().apply {
                            put("name", file.name)
                            put("isDirectory", file.isDirectory)
                            put("uri", file.absolutePath)
                        })
                    }
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("VaultSync", "listLibraryNative failed for $uri: ${e.message}")
        }

        return results
    }

    fun checkSafExtensionsRecursive(rootUri: Uri, currentDocId: String, extensions: List<String>, depth: Int): Boolean {
        android.util.Log.d("VaultSync", "🔍 ROM_SCAN: Checking depth=$depth docId=$currentDocId extensions=$extensions")
        if (depth > MAX_EXTENSION_SCAN_DEPTH) return false
        val treeUri = try {
            val treeId = DocumentsContract.getTreeDocumentId(rootUri)
            DocumentsContract.buildTreeDocumentUri(rootUri.authority, treeId)
        } catch (e: Exception) {
            rootUri
        }
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, currentDocId)
        context.contentResolver.query(
            childrenUri, 
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID, 
                DocumentsContract.Document.COLUMN_DISPLAY_NAME, 
                DocumentsContract.Document.COLUMN_MIME_TYPE
            ), 
            null, null, null
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getString(0)
                val name = cursor.getString(1)?.lowercase() ?: continue
                val mime = cursor.getString(2)
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    if (checkSafExtensionsRecursive(rootUri, id, extensions, depth + 1)) return true
                } else if (extensions.any { name.endsWith(".$it") }) {
                    return true
                }
            }
        }
        return false
    }
}
