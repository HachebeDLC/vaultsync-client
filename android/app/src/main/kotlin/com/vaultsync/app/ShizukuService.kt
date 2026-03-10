package com.vaultsync.app

import android.os.IBinder
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import kotlin.system.exitProcess

class ShizukuService : IShizukuService.Stub() {

    override fun listFiles(path: String): List<String> {
        val dir = File(path)
        if (!dir.exists() || !dir.isDirectory) return emptyList()
        return dir.list()?.toList() ?: emptyList()
    }

    override fun readFile(path: String, offset: Long, length: Int): ByteArray {
        val file = File(path)
        if (!file.exists()) return ByteArray(0)
        
        FileInputStream(file).use { input ->
            input.skip(offset)
            val buffer = ByteArray(length)
            val read = input.read(buffer)
            return if (read == -1) ByteArray(0)
            else if (read == length) buffer
            else buffer.sliceArray(0 until read)
        }
    }

    override fun writeFile(path: String, data: ByteArray, offset: Long) {
        val file = File(path)
        if (!file.parentFile.exists()) file.parentFile.mkdirs()
        
        val mode = if (offset == 0L) "rw" else "rw" // Standard access
        // We use RandomAccessFile for patching at offset
        java.io.RandomAccessFile(file, "rw").use { raf ->
            raf.seek(offset)
            raf.write(data)
        }
    }

    override fun destroy() {
        // No manual exit needed here if using standard binder lifecycle
    }
}
