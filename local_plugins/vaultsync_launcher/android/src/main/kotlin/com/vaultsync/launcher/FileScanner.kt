package com.vaultsync.launcher

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap

class FileScanner(private val context: Context) {
    companion object {
        const val MAX_EXTENSION_SCAN_DEPTH = 3
        const val MAX_SCAN_DEPTH = 15
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

    private fun getDocIdSafely(uri: Uri): String {
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
        
        // Performance: Use child mapping cache to eliminate linear listFiles()
        val cached = directoryContentCache[parentUriStr]?.get(name)
        if (cached != null) return cached

        // Direct query fallback for non-cached folders
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(parent.uri, getDocIdSafely(parent.uri))
        context.contentResolver.query(
            childrenUri,
            arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_MIME_TYPE),
            "${DocumentsContract.Document.COLUMN_DISPLAY_NAME} = ?",
            arrayOf(name),
            null
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val docId = cursor.getString(0)
                val mime = cursor.getString(1)
                val fileUri = DocumentsContract.buildDocumentUriUsingTree(parent.uri, docId)
                val found = if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    DocumentFile.fromTreeUri(context, fileUri)
                } else {
                    DocumentFile.fromSingleUri(context, fileUri)
                }
                if (found != null) {
                    val existingMap = directoryContentCache[parentUriStr]?.toMutableMap() ?: mutableMapOf()
                    existingMap[name] = found
                    directoryContentCache[parentUriStr] = existingMap
                    return found
                }
            }
        }
        return null
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
        return current.uri
    }

    fun getOrCreateDirectory(parent: DocumentFile, name: String): DocumentFile {
        synchronized(safLock) {
            val existing = findFileStrict(parent, name)
            if (existing != null && existing.isDirectory) return existing
            val created = parent.createDirectory(name) ?: throw Exception("CreateDirectory failed for '$name'")
            
            val parentUriStr = parent.uri.toString()
            val existingMap = directoryContentCache[parentUriStr]?.toMutableMap() ?: mutableMapOf()
            existingMap[name] = created
            directoryContentCache[parentUriStr] = existingMap
            return created
        }
    }

    fun getOrCreateFile(parent: DocumentFile, name: String, mime: String): DocumentFile {
        synchronized(safLock) {
            val existing = findFileStrict(parent, name)
            if (existing != null && existing.isFile) return existing
            val created = parent.createFile(mime, name) ?: throw Exception("CreateFile failed for '$name'")

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
        val results = JSONArray()
        val sid = systemId.lowercase()
        val isSwitch = sid == "switch" || sid == "eden"
        val syncEverything = sid in setOf("switch", "eden", "ps2", "psx", "ps1", "duckstation", "aethersx2", "nethersx2", "pcsx2", "psp", "ppsspp", "dolphin", "gc", "wii", "3ds", "citra", "azahar")
        
        val ignoreSet = ignoredFoldersList.map { it.lowercase() }.toHashSet()
        val combinedIgnoreSet = combinedIgnores.map { it.lowercase() }.toHashSet()

        val uriStr = uri.toString().lowercase()
        val alreadyInZone = isSwitch && (uriStr.contains("nand%2fuser%2fsave") || uriStr.contains("nand/user/save"))

        val treeUri = getTreeUri(uri)
        val startDocId = getDocIdSafely(uri)

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

                    if (isSwitch && !alreadyInZone) {
                        val inSavePath = relPath.contains("nand/user/save")
                        if (!inSavePath && !relPath.startsWith("nand") && relPath != "nand") continue
                    }

                    val isDir = mime == DocumentsContract.Document.MIME_TYPE_DIR
                    val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, id)
                    
                    // Add to index for O(1) subsequent lookups
                    currentLevelMap[name] = if (isDir) DocumentFile.fromTreeUri(context, docUri)!! else DocumentFile.fromSingleUri(context, docUri)!!

                    if (isDir) {
                        results.put(JSONObject().apply {
                            put("name", name)
                            put("relPath", relPath)
                            put("isDirectory", true)
                            put("uri", docUri.toString())
                        })
                        walkSaf(id, relPath, depth + 1)
                    } else {
                        var fSize = cursor.getLong(3)
                        var fLast = cursor.getLong(4)
                        
                        if (fSize <= 0) {
                            val df = currentLevelMap[name]
                            fSize = df?.length() ?: 0
                            fLast = df?.lastModified() ?: 0
                        }

                        val shouldSync = if (isSwitch) {
                            relPath.contains("nand/user/save") || alreadyInZone || syncEverything
                        } else {
                            syncEverything || allowedExtensions.contains(name.split(".").last().lowercase())
                        }

                        if (shouldSync) {
                            results.put(JSONObject().apply {
                                put("name", name)
                                put("relPath", relPath)
                                put("isDirectory", false)
                                put("size", fSize)
                                put("lastModified", fLast)
                                put("uri", docUri.toString())
                            })
                        }
                    }
                }
                directoryContentCache[parentUriStr] = currentLevelMap
            }
        }
        walkSaf(startDocId, "", 0)
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
        val syncEverything = sid in setOf("switch", "eden", "ps2", "psx", "ps1", "duckstation", "aethersx2", "nethersx2", "pcsx2", "psp", "ppsspp")
        
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
                    val inSavePath = relPath.contains("nand/user/save")
                    if (!inSavePath && !relPath.startsWith("nand") && relPath != "nand") continue
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
                    val shouldSync = if (isSwitch) {
                        relPath.contains("nand/user/save") || alreadyInZone || syncEverything
                    } else {
                        syncEverything || allowedExtensions.contains(name.split(".").last().lowercase())
                    }

                    if (shouldSync) {
                        results.put(JSONObject().apply {
                            put("name", name)
                            put("relPath", relPath)
                            put("isDirectory", false)
                            put("size", f.getLong("size"))
                            put("lastModified", f.getLong("lastModified"))
                            put("uri", "shizuku://$fullPath")
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
        val results = JSONArray()
        val sid = systemId.lowercase()
        val isSwitch = sid == "switch" || sid == "eden"
        val syncEverything = sid in setOf("switch", "eden", "ps2", "psx", "ps1", "duckstation", "aethersx2", "nethersx2", "pcsx2", "psp", "ppsspp")
        
        val ignoreSet = ignoredFoldersList.map { it.lowercase() }.toHashSet()
        val combinedIgnoreSet = combinedIgnores.map { it.lowercase() }.toHashSet()
        val alreadyInZone = isSwitch && path.lowercase().contains("nand/user/save")

        fun walkLocal(dir: File, currentRelPath: String) {
            dir.listFiles()?.forEach { file ->
                val relPath = if (currentRelPath.isEmpty()) file.name else "$currentRelPath/${file.name}"
                if (combinedIgnoreSet.contains(file.name.lowercase()) || ignoreSet.contains(relPath.lowercase())) return@forEach
                
                if (isSwitch && !alreadyInZone) {
                    val inSavePath = relPath.contains("nand/user/save")
                    if (!inSavePath && !relPath.startsWith("nand") && relPath != "nand") return@forEach
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
                    val shouldSync = if (isSwitch) {
                        relPath.contains("nand/user/save") || alreadyInZone || syncEverything
                    } else {
                        syncEverything || allowedExtensions.contains(file.name.split(".").last().lowercase())
                    }

                    if (shouldSync) {
                        results.put(JSONObject().apply {
                            put("name", file.name)
                            put("relPath", relPath)
                            put("isDirectory", false)
                            put("size", file.length())
                            put("lastModified", file.lastModified())
                            put("uri", file.absolutePath)
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

    fun checkSafExtensionsRecursive(rootUri: Uri, currentDocId: String, extensions: List<String>, depth: Int): Boolean {
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
