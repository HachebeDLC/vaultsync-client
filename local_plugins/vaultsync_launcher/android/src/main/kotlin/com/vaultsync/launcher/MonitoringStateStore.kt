package com.vaultsync.launcher

import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.util.Properties

/**
 * File-backed persistence for "sync on game exit" monitoring state, safe to
 * read and write from multiple OS processes of the same app (the main
 * process and `:monitor` — see AndroidManifest.xml).
 *
 * Why not plain SharedPreferences: Android caches a `SharedPreferencesImpl`
 * instance — and its fully-parsed in-memory map — per process, the first
 * time a given prefs file is opened in that process. That cache is
 * process-local and is never invalidated when a *different* process changes
 * the underlying XML file. (`Context.MODE_MULTI_PROCESS` claims to reload on
 * external changes via an mtime check, but it has been deprecated since API
 * 23 and Android's own docs call it "not reliable, especially in cases of
 * high(er) frequency disk access" — not something to build a correctness
 * guarantee on.) Since this state is written by the main process (Dart
 * settings: the enabled flag, the monitored package list) and read every
 * ~15s by the separate `:monitor` process, a stale in-memory cache there
 * would mean toggling monitoring off — or changing the monitored package
 * list — from the main process would never be observed by `:monitor`.
 *
 * This class does no in-memory caching of its own instead: every [read]
 * opens the file fresh from disk (plain `java.io.File` I/O has no such
 * process-level cache), and every write is a full read-modify-write under
 * an exclusive OS-level file lock, followed by a temp-file-then-rename, so
 * a concurrent reader in the other process never observes a torn write and
 * a concurrent writer never loses an update. This is the "small file"
 * option the design calls out, chosen over a ContentProvider because the
 * data is tiny (one flag, a handful of package names, two more small
 * fields), read/written infrequently (on a settings change, on a sync
 * start/stop, or every ~15s), and a ContentProvider would add a lot of
 * ceremony (a UriMatcher, insert/query/update plumbing, its own manifest
 * entry) for no real benefit at this scale.
 *
 * Free of Android imports so it is unit-testable with plain JUnit — see
 * MonitoringStateStoreTest, which uses two separate instances pointed at
 * the same file to simulate the cross-process read/write pattern.
 */
class MonitoringStateStore(private val storeFile: File) {

    data class State(
        val enabled: Boolean = false,
        val packages: List<String> = emptyList(),
        val checkpointMs: Long? = null,
        val syncActive: Boolean = false
    )

    /**
     * Reads the current state fresh from disk. Never caches — safe to call
     * without locking because [writeAtomically] never leaves a partially
     * written file for a concurrent reader to observe.
     */
    fun read(): State {
        if (!storeFile.exists()) return State()
        val props = Properties()
        try {
            FileInputStream(storeFile).use { props.load(it) }
        } catch (e: Exception) {
            return State()
        }
        val packagesRaw = props.getProperty(KEY_PACKAGES, "")
        return State(
            enabled = props.getProperty(KEY_ENABLED, "false").toBoolean(),
            packages = if (packagesRaw.isEmpty()) emptyList() else packagesRaw.split(PACKAGE_DELIMITER),
            checkpointMs = props.getProperty(KEY_CHECKPOINT_MS)?.toLongOrNull(),
            syncActive = props.getProperty(KEY_SYNC_ACTIVE, "false").toBoolean()
        )
    }

    fun writeEnabled(enabled: Boolean) = update { it.copy(enabled = enabled) }

    fun writePackages(packages: List<String>) = update { it.copy(packages = packages) }

    fun writeCheckpointMs(value: Long) = update { it.copy(checkpointMs = value) }

    fun writeSyncActive(active: Boolean) = update { it.copy(syncActive = active) }

    /**
     * Writes [state] only if the store file does not exist yet, under the
     * same lock as [update], so a one-time import from older storage can
     * never overwrite a value either process has already written.
     * Returns whether it wrote.
     */
    fun importIfAbsent(state: State): Boolean {
        storeFile.parentFile?.mkdirs()
        val lockFile = File(storeFile.parentFile, "${storeFile.name}.lock")
        RandomAccessFile(lockFile, "rw").use { raf ->
            val lock = raf.channel.lock()
            try {
                if (storeFile.exists()) return false
                writeAtomically(state)
                return true
            } finally {
                lock.release()
            }
        }
    }

    /**
     * Read-modify-write under an exclusive OS-level file lock, so a
     * concurrent writer in the other process can't clobber this update (or
     * vice versa). The lock is taken on a separate `.lock` file rather than
     * [storeFile] itself so that [read] never has to contend for it.
     */
    private fun update(mutate: (State) -> State) {
        storeFile.parentFile?.mkdirs()
        val lockFile = File(storeFile.parentFile, "${storeFile.name}.lock")
        RandomAccessFile(lockFile, "rw").use { raf ->
            val lock = raf.channel.lock()
            try {
                val next = mutate(read())
                writeAtomically(next)
            } finally {
                lock.release()
            }
        }
    }

    private fun writeAtomically(state: State) {
        val props = Properties()
        props.setProperty(KEY_ENABLED, state.enabled.toString())
        props.setProperty(KEY_PACKAGES, state.packages.joinToString(PACKAGE_DELIMITER))
        state.checkpointMs?.let { props.setProperty(KEY_CHECKPOINT_MS, it.toString()) }
        props.setProperty(KEY_SYNC_ACTIVE, state.syncActive.toString())

        val tempFile = File(storeFile.parentFile, "${storeFile.name}.tmp")
        FileOutputStream(tempFile).use { props.store(it, null) }
        if (!tempFile.renameTo(storeFile)) {
            // Some filesystems refuse to rename over an existing file.
            storeFile.delete()
            if (!tempFile.renameTo(storeFile)) {
                tempFile.copyTo(storeFile, overwrite = true)
                tempFile.delete()
            }
        }
    }

    companion object {
        private const val KEY_ENABLED = "enabled"
        private const val KEY_PACKAGES = "packages"
        private const val KEY_CHECKPOINT_MS = "checkpointMs"
        private const val KEY_SYNC_ACTIVE = "syncActive"
        private const val PACKAGE_DELIMITER = ","
    }
}
