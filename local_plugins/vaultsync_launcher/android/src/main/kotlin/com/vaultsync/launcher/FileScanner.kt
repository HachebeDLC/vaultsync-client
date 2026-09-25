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

/**
 * One row pulled from a SAF children cursor: (documentId, displayName,
 * size, lastModified). Plain top-level data class (not nested in
 * [FileScanner]'s companion object — a class nested there is only reachable
 * as `FileScanner.Companion.SafChildRow`, not the `FileScanner.SafChildRow`
 * shorthand that works for companion functions/properties) so the by-name
 * row selection DownloadManager performs when reporting the post-download
 * canonical "uri" (see `DownloadManager.handleDownloadFile`'s SAF branch)
 * can be unit-tested without a real ContentResolver / DocumentsContract —
 * those Android framework classes throw ("not mocked") in plain JVM unit
 * tests and this module has no Robolectric setup.
 */
data class SafChildRow(
    val documentId: String,
    val displayName: String,
    val size: Long,
    val lastModified: Long
)

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
            "dsx",
            // PS2 Export format
            "psu"
            // NOTE: `.bak` is intentionally NOT in this set. RetroArch rotates
            // the previous save/state to .bak on every write; those are
            // local-only backups and historically polluted cloud storage.
            // `shouldSyncFile` also rejects .bak explicitly as defense in depth.
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

        /**
         * Returns true if [relPath]/[fileName] should be included in the
         * sync manifest for [sid] (lowercased system ID).
         *
         * [relPath]  — path relative to the scan root, e.g. "GC/EUR/GALE01.gci"
         * [fileName] — bare filename, e.g. "GALE01.gci"
         *
         * @param saveExtensions Per-system allowlist. When non-empty, replaces
         *                       the global [SAVE_EXTENSIONS] set for the final
         *                       extension check. Prefix-based system filters
         *                       (PSP `savedata/`, Wii `title/0001000`, etc.)
         *                       still apply regardless.
         *
         * Pure helper (no instance state) so the filter rules can be unit-tested
         * without a Context / SAF, mirroring [pickBestProfileByMtime].
         */
        /** True when any directory component of [relPath] is hidden. The trailing
         *  component is the file itself and is checked separately.
         *  Kept in parity with DartFileScanner._hasHiddenSegment. */
        internal fun hasHiddenSegment(relPath: String): Boolean {
            val parts = relPath.replace('\\', '/').split('/')
            for (i in 0 until parts.size - 1) {
                if (parts[i].startsWith(".")) return true
            }
            return false
        }

        internal fun shouldSyncFile(
            sid: String,
            relPath: String,
            fileName: String,
            saveExtensions: Set<String> = SAVE_EXTENSIONS
        ): Boolean {
            if (fileName.startsWith(".")) return false
            // RetroArch's automatic save-rotation backups never belong in cloud
            // storage. Reject before per-system extension lookup so a system JSON
            // with "bak" in its allowlist can't accidentally re-enable them.
            if (fileName.lowercase().endsWith(".bak")) return false
            // VaultSync's own partial-transfer files. Without this they were
            // scanned as saves and uploaded — one abandoned .vstmp reached the
            // server at 79 MB.
            if (fileName.lowercase().endsWith(".vstmp")) return false
            // Hidden *directories* anywhere in the path. The fileName check above
            // only catches hidden files, so everything inside Syncthing's
            // `.stversions/` trash passed with an ordinary name and got synced.
            if (hasHiddenSegment(relPath)) return false
            val lowerRel = relPath.lowercase()

            // 1. Switch / Eden: sync everything found in the save zone.
            // The recursive walk already constrains traversal to the nand/user/save
            // subtree (see the isSwitch zone guard in the scan loops), so every file
            // reaching this point is a genuine save. We must NOT additionally require
            // the Title ID prefix "0100" in the path: Ryujinx-style and older Yuzu
            // layouts key saves by save-data ID, not title ID, so the title ID never
            // appears in the path — that gate rejected every file while directories
            // (which skip shouldSyncFile) were still added, yielding "N directories,
            // 0 files". Matches SYNC_EVERYTHING_SIDS and the Dart desktop scanner.
            if (sid == "switch" || sid == "eden") {
                return true
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

            if (sid == "ps2" || sid == "aethersx2" || sid == "nethersx2" || sid == "pcsx2") {
                if (fileName == "_pcsx2_index" || fileName == "_pcsx2_superblock") return true
                if (lowerRel.contains(".ps2/")) {
                    // Inside a folder card
                    val ext = fileName.substringAfterLast('.', "").lowercase()
                    // Whitelist known PS2 folder card files and bin/psu
                    val allowedExtensions = setOf("bin", "psu", "sys", "ico")
                    if (allowedExtensions.contains(ext)) return true

                    // If it matches the directory name, it's likely the main save file
                    val parts = relPath.split("/")
                    if (parts.size >= 2) {
                        val folderName = parts[parts.size - 2]
                        if (fileName == folderName) return true
                    }
                }
            }

            val ext = normaliseSaveExtension(fileName.substringAfterLast('.', "").lowercase())
            return ext.isNotEmpty() && saveExtensions.contains(ext)
        }

        private val STATE_SLOT_RE = Regex("^state\\d+$")

        /** Collapses RetroArch numbered savestate slots onto `state`.
         *
         * Manual savestates are written as `<rom>.state1`, `.state2`, … while
         * slot 0 is plain `.state`. Only `state` and `auto` appear in the
         * per-system save_extensions, so every manual slot was silently
         * skipped. Keep in sync with DartFileScanner.normaliseSaveExtension. */
        fun normaliseSaveExtension(ext: String): String =
            if (STATE_SLOT_RE.matches(ext)) "state" else ext

        /**
         * Resolves the (size, lastModified) pair to record for a SAF-scanned file
         * under Android/data, given the SAF cursor's values and the result of the
         * `Os.fstat()` performed to work around unreliable SAF cursor metadata
         * there (see `scanSafRecursive`'s batched fstat pass).
         *
         * Size is taken from the same fstat as mtime so both fields come from
         * one consistent source. (The 0-byte scans that prompted this turned out
         * to be genuinely empty files in a stray copy of the save tree, not bad
         * cursor metadata.)
         * fstat's value wins whenever fstat produced one; the cursor value is
         * only the fallback when fstat failed outright (null) or, for mtime
         * only, reported a non-positive value (the existing "unreliable"
         * signal already handled by the caller before this function sees it).
         */
        fun resolveScannedSizeAndMtime(
            cursorSize: Long,
            cursorLastModified: Long,
            fstatMtime: Long?,
            fstatSize: Long?
        ): Pair<Long, Long> {
            val size = fstatSize ?: cursorSize
            val lastModified = fstatMtime ?: cursorLastModified
            return Pair(size, lastModified)
        }

        /**
         * Picks the row whose [SafChildRow.displayName] equals [targetName],
         * mirroring the linear cursor scan DownloadManager performs right
         * after a SAF download to find the docId of the file it just wrote.
         * Returns the first match in cursor order, or null if none matches.
         */
        fun selectMatchingChild(rows: List<SafChildRow>, targetName: String): SafChildRow? =
            rows.firstOrNull { it.displayName == targetName }
    }

    private val safLock = Any()
    private val safDirectoryCache = ConcurrentHashMap<String, DocumentFile>()
    // parentUri -> Map<FileName, DocumentFile>
    private val directoryContentCache = ConcurrentHashMap<String, Map<String, DocumentFile>>()

    fun clearCache() {
        safDirectoryCache.clear()
        directoryContentCache.clear()
    }

    // Package-visible (not private) so DownloadManager can build the exact
    // same tree-URI shape when reporting the post-download canonical "uri" —
    // see DownloadManager.handleDownloadFile's SAF branch.
    fun getTreeUri(uri: Uri): Uri {
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
                    throw Exception("Refusing to replace file with SAF directory '$name'")
                }
            }
            
            android.util.Log.i("VaultSync", "📁 SAF: Creating directory '$name'...")
            // createDirectory returns null when the folder already exists on disk
            // but the DocumentsProvider index does not list it — the same
            // divergence that makes SAF report files the filesystem doesn't have.
            // Re-resolving here turns a hard failure into a hit: downloads into
            // AetherSX2's pre-existing 'memcards' folder were failing this way.
            val created = parent.createDirectory(name)
                ?: findFileStrict(parent, name)?.takeIf { it.isDirectory }
                ?: throw Exception("CreateDirectory failed for '$name' and it could not be resolved afterwards")
            
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
                    throw Exception("Refusing to replace SAF directory with file '$name'")
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
                        val sync = shouldSyncFile(sid, relPath, name, allowedExtensions)
                        if (sync) android.util.Log.v("VaultSync", "  [FILE] $relPath (MATCH)")
                        if (sync) {
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
        // to get kernel mtime AND size. Parallelized to reduce IPC wall-clock time.
        // Size is read from the same stat as mtime, so both come from one
        // consistent source (the 0-byte scans that prompted this were genuinely
        // empty files in a stray copy of the save tree, not bad metadata). Since
        // we already pay for the fd open + Os.fstat() to fix mtime, read st_size
        // from the same stat struct at no extra IPC cost rather than opening a
        // second fd. Cursor values remain the fallback when fstat fails/throws.
        if (pendingFstats != null && pendingFstats.isNotEmpty()) {
            val pool = Executors.newFixedThreadPool(min(pendingFstats.size, 8))
            val futures = pendingFstats.map { (idx, docUri) ->
                pool.submit(Callable<Triple<Int, Long?, Long?>?> {
                    try {
                        context.contentResolver.openFileDescriptor(docUri, "r")?.use { pfd ->
                            val stat = Os.fstat(pfd.fileDescriptor)
                            val mtime = if (stat.st_mtime > 0L) stat.st_mtime * 1000L else null
                            Triple(idx, mtime, stat.st_size)
                        }
                    } catch (_: Exception) { null }
                })
            }
            for (future in futures) {
                val (idx, mtime, size) = future.get() ?: continue
                val obj = results.getJSONObject(idx)
                val (resolvedSize, resolvedMtime) = resolveScannedSizeAndMtime(
                    cursorSize = obj.getLong("size"),
                    cursorLastModified = obj.getLong("lastModified"),
                    fstatMtime = mtime,
                    fstatSize = size,
                )
                obj.put("size", resolvedSize)
                obj.put("lastModified", resolvedMtime)
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
                    if (shouldSyncFile(sid, relPath, name, allowedExtensions)) {
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
                    if (shouldSyncFile(sid, relPath, file.name, allowedExtensions)) {
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

    /**
     * Returns true if [uri] (a SAF folder) contains a file whose name ends with
     * one of [extensions], searching up to [MAX_EXTENSION_SCAN_DEPTH] deep.
     *
     * Uses the `DocumentFile` API rather than a raw
     * `DocumentsContract.buildChildDocumentsUriUsingTree` + ContentResolver
     * query: on Android 16 / HyperOS the raw query fails (returns null or
     * throws) even though the caller holds a valid tree grant, which made every
     * folder look empty and the library scan report "No systems detected".
     * `DocumentFile.listFiles()` is the same call `listLibraryNative` uses and
     * is proven to work on the affected devices.
     */
    fun checkSafExtensionsRecursive(uri: Uri, extensions: List<String>, depth: Int): Boolean {
        if (depth > MAX_EXTENSION_SCAN_DEPTH) return false

        val dir = try {
            DocumentFile.fromTreeUri(context, uri)
        } catch (e: Exception) {
            android.util.Log.e("VaultSync", "🔍 ROM_SCAN: fromTreeUri failed for $uri: ${e.message}")
            null
        } ?: return false

        val lowerExts = extensions.map { it.lowercase() }
        val subDirs = ArrayList<DocumentFile>()

        // Check files first so a top-level match (the common case, e.g.
        // ROMs/gba/*.gba) short-circuits before descending into subfolders.
        for (child in dir.listFiles()) {
            if (child.isDirectory) {
                subDirs.add(child)
            } else {
                val name = (child.name ?: "").lowercase()
                if (lowerExts.any { name.endsWith(".$it") }) return true
            }
        }

        for (sub in subDirs) {
            if (checkSafExtensionsRecursive(sub.uri, extensions, depth + 1)) return true
        }
        return false
    }
}
