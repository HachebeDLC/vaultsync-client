package com.vaultsync.app

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
        /**
         * Maximum recursion depth for extension scanning to prevent ANRs on large directories.
         */
        const val MAX_EXTENSION_SCAN_DEPTH = 3
        
        /**
         * Maximum recursion depth for full library scanning.
         */
        const val MAX_SCAN_DEPTH = 15
    }

    private val safLock = Any()
    private val safDirectoryCache = ConcurrentHashMap<String, DocumentFile>()

    fun clearCache() {
        safDirectoryCache.clear()
    }

    fun findFileStrict(parent: DocumentFile, name: String): DocumentFile? {
        val cacheKey = "${parent.uri}/$name"
        if (safDirectoryCache.containsKey(cacheKey)) return safDirectoryCache[cacheKey]

        val docId = DocumentsContract.getDocumentId(parent.uri)
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(parent.uri, docId)
        
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
                if (cursor.getString(1) == name) {
                    val id = cursor.getString(0)
                    val mime = cursor.getString(2)
                    val itemUri = DocumentsContract.buildDocumentUriUsingTree(parent.uri, id)
                    val found = if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        DocumentFile.fromTreeUri(context, itemUri)
                    } else {
                        DocumentFile.fromSingleUri(context, itemUri)
                    }
                    if (found != null) {
                        safDirectoryCache[cacheKey] = found
                        return found
                    }
                }
            }
        }
        return null
    }

    fun getOrCreateDirectory(parent: DocumentFile, name: String): DocumentFile {
        synchronized(safLock) {
            val existing = findFileStrict(parent, name)
            if (existing != null && existing.isDirectory) return existing
            
            val created = parent.createDirectory(name) 
                ?: throw Exception("CreateDirectory failed for '$name'")
            
            safDirectoryCache["${parent.uri}/$name"] = created
            return created
        }
    }

    fun getOrCreateFile(parent: DocumentFile, name: String, mime: String): DocumentFile {
        synchronized(safLock) {
            val existing = findFileStrict(parent, name)
            if (existing != null && existing.isFile) return existing
            
            return parent.createFile(mime, name) 
                ?: throw Exception("CreateFile failed for '$name'")
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
        val syncEverything = sid in setOf("switch", "ps2", "psx", "ps1", "duckstation", "aethersx2", "nethersx2", "pcsx2")
        
        val startDocId = try { 
            DocumentsContract.getTreeDocumentId(uri) 
        } catch (e: Exception) { 
            null 
        }

        if (startDocId != null) {
            fun walkSaf(currentDocId: String, currentRelPath: String, depth: Int) {
                if (depth > MAX_SCAN_DEPTH) return
                
                val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(uri, currentDocId)
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
                    while (cursor.moveToNext()) {
                        val id = cursor.getString(0)
                        val name = cursor.getString(1) ?: "unknown"
                        val mime = cursor.getString(2)
                        val relPath = if (currentRelPath.isEmpty()) name else "$currentRelPath/$name"

                        if (isIgnored(name, relPath, combinedIgnores, ignoredFoldersList)) continue

                        // Switch/Eden Optimization: Only descend into 'nand' or its subfolders
                        if (isSwitch && !relPath.startsWith("nand") && relPath != "nand") continue

                        if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                            results.put(JSONObject().apply {
                                put("name", name)
                                put("relPath", relPath)
                                put("isDirectory", true)
                                put("uri", DocumentsContract.buildDocumentUriUsingTree(uri, id).toString())
                            })
                            walkSaf(id, relPath, depth + 1)
                        } else {
                            var fSize = cursor.getLong(3)
                            var fLast = cursor.getLong(4)
                            val itemUri = DocumentsContract.buildDocumentUriUsingTree(uri, id)
                            
                            if (fSize <= 0) {
                                val df = DocumentFile.fromSingleUri(context, itemUri)
                                fSize = df?.length() ?: 0
                                fLast = df?.lastModified() ?: 0
                            }

                            // Switch specific: only sync files inside the actual save path
                            val shouldSync = if (isSwitch) {
                                relPath.contains("nand/user/save")
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
                                    put("uri", itemUri.toString())
                                })
                            }
                        }
                    }
                }
            }
            walkSaf(startDocId, "", 0)
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
        val syncEverything = sid in setOf("switch", "ps2", "psx", "ps1", "duckstation", "aethersx2", "nethersx2", "pcsx2")

        fun walkShizuku(currentPath: String, currentRelPath: String, depth: Int) {
            if (depth > MAX_SCAN_DEPTH) return
            val files = JSONArray(service.listFileInfo(currentPath))
            for (i in 0 until files.length()) {
                val f = files.getJSONObject(i)
                val name = f.getString("name")
                val relPath = if (currentRelPath.isEmpty()) name else "$currentRelPath/$name"
                
                if (combinedIgnores.contains(name.lowercase()) || ignoredFoldersList.any { it.equals(relPath, true) }) continue

                // Switch Optimization
                if (isSwitch && !relPath.startsWith("nand") && relPath != "nand") continue
                
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
                        relPath.contains("nand/user/save")
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
        val syncEverything = sid in setOf("switch", "ps2", "psx", "ps1", "duckstation", "aethersx2", "nethersx2", "pcsx2")

        fun walkLocal(dir: File, currentRelPath: String) {
            dir.listFiles()?.forEach { file ->
                val relPath = if (currentRelPath.isEmpty()) file.name else "$currentRelPath/${file.name}"
                if (combinedIgnores.contains(file.name.lowercase()) || ignoredFoldersList.any { it.equals(relPath, true) }) return@forEach

                // Switch Optimization
                if (isSwitch && !relPath.startsWith("nand") && relPath != "nand") return@forEach
                
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
                        relPath.contains("nand/user/save")
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
        val treeId = try { DocumentsContract.getTreeDocumentId(uri) } catch(e: Exception) { DocumentsContract.getDocumentId(uri) }
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(uri, treeId)
        
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
                val name = cursor.getString(1)
                val mime = cursor.getString(2)
                val isDir = mime == DocumentsContract.Document.MIME_TYPE_DIR
                val itemUri = DocumentsContract.buildDocumentUriUsingTree(uri, id)
                results.put(JSONObject().apply {
                    put("name", name)
                    put("uri", itemUri.toString())
                    put("isDirectory", isDir)
                })
            }
        }
        return results
    }

    fun checkSafExtensionsRecursive(rootUri: Uri, currentDocId: String, extensions: List<String>, depth: Int): Boolean {
        if (depth > MAX_EXTENSION_SCAN_DEPTH) return false
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(rootUri, currentDocId)
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
                val name = cursor.getString(1).lowercase()
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

    private fun isIgnored(name: String, relPath: String, combinedIgnores: Set<String>, ignoredFoldersList: List<String>): Boolean {
        return combinedIgnores.contains(name.lowercase()) || 
               ignoredFoldersList.any { i -> 
                   relPath.lowercase() == i.lowercase() || 
                   relPath.lowercase().endsWith("/${i.lowercase()}") 
               }
    }
}
