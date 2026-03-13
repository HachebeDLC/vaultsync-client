package com.vaultsync.app

import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileInputStream
import java.io.RandomAccessFile
import java.security.MessageDigest
import org.json.JSONArray
import org.json.JSONObject

class ShizukuService : IShizukuService.Stub() {

    override fun listFiles(path: String): List<String> {
        val dir = File(path)
        if (!dir.exists() || !dir.isDirectory) return emptyList()
        return dir.list()?.toList() ?: emptyList()
    }

    override fun listFileInfo(path: String): String {
        val dir = File(path)
        val results = JSONArray()
        if (!dir.exists() || !dir.isDirectory) return results.toString()
        
        dir.listFiles()?.forEach { file ->
            val obj = JSONObject()
            obj.put("name", file.name)
            obj.put("size", file.length())
            obj.put("lastModified", file.lastModified())
            obj.put("isDirectory", file.isDirectory)
            results.put(obj)
        }
        return results.toString()
    }

    override fun readFile(path: String, offset: Long, length: Int): ByteArray {
        val file = File(path)
        if (!file.exists()) return ByteArray(0)
        FileInputStream(file).use { input ->
            if (offset > 0) input.skip(offset)
            val buffer = ByteArray(length)
            val read = input.read(buffer)
            return if (read == -1) ByteArray(0) else if (read == length) buffer else buffer.sliceArray(0 until read)
        }
    }

    override fun writeFile(path: String, data: ByteArray, offset: Long) {
        val file = File(path)
        val parent = file.parentFile
        if (parent != null && !parent.exists()) parent.mkdirs()
        RandomAccessFile(file, "rw").use { raf -> raf.seek(offset); raf.write(data) }
    }

    override fun setLastModified(path: String, time: Long): Boolean {
        val file = File(path); return if (file.exists()) file.setLastModified(time) else false
    }

    override fun renameFile(oldPath: String, newPath: String): Boolean {
        val oldFile = File(oldPath); val newFile = File(newPath)
        if (newFile.exists()) newFile.delete()
        return oldFile.renameTo(newFile)
    }

    override fun deleteFile(path: String): Boolean {
        val file = File(path); return if (file.exists()) file.delete() else false
    }

    override fun getFileSize(path: String): Long {
        val file = File(path); return if (file.exists()) file.length() else -1L
    }

    override fun getLastModified(path: String): Long {
        val file = File(path); return if (file.exists()) file.lastModified() else 0L
    }

    override fun calculateHash(path: String): String {
        val file = File(path)
        if (!file.exists()) return ""
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(65536)
            var read: Int
            while (input.read(buffer).also { read = it } != -1) { digest.update(buffer, 0, read) }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    override fun calculateBlockHashes(path: String, blockSize: Int): List<String> {
        val file = File(path)
        if (!file.exists()) return emptyList()
        val results = mutableListOf<String>()
        FileInputStream(file).use { input ->
            val buffer = ByteArray(blockSize)
            var read: Int
            while (input.read(buffer).also { read = it } != -1) {
                val digest = MessageDigest.getInstance("SHA-256")
                digest.update(buffer, 0, read)
                results.add(digest.digest().joinToString("") { "%02x".format(it) })
            }
        }
        return results
    }

    override fun openFile(path: String, mode: String): ParcelFileDescriptor? {
        val file = File(path)
        if (mode.contains("w") && file.parentFile != null && !file.parentFile.exists()) { file.parentFile.mkdirs() }
        val pfdMode = when (mode) {
            "r" -> ParcelFileDescriptor.MODE_READ_ONLY
            "w" -> ParcelFileDescriptor.MODE_WRITE_ONLY or ParcelFileDescriptor.MODE_CREATE
            "rw" -> ParcelFileDescriptor.MODE_READ_WRITE or ParcelFileDescriptor.MODE_CREATE
            else -> ParcelFileDescriptor.MODE_READ_ONLY
        }
        return try { ParcelFileDescriptor.open(file, pfdMode) } catch (e: Exception) { null }
    }

    override fun destroy() { /* Standard Binder lifecycle */ }
}
