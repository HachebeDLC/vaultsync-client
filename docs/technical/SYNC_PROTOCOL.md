# Sync Protocol & Delta-Sync Algorithm

VaultSync implements a custom delta-sync protocol to minimize bandwidth, significantly reducing transfer times for large emulator save files (e.g., memory cards and NAND folders).

## 1. Variable Block Sizes

The engine dynamically selects a block size based on the total file size to balance granularity with metadata overhead:

- **Small Files (< 10MB)**: Uses **256KB** blocks.
- **Large Files (≥ 10MB)**: Uses **1MB** blocks.

#### Kotlin Implementation: `CryptoEngine.kt`
The block size logic is central to the synchronization process:

```kotlin
// Example from local_plugins/vaultsync_launcher/android/src/main/kotlin/com/vaultsync/launcher/CryptoEngine.kt
companion object {
    const val SMALL_BLOCK_SIZE = 256 * 1024 // 256KB
    const val LARGE_BLOCK_SIZE = 1024 * 1024 // 1MB
    const val BLOCK_THRESHOLD = 10 * 1024 * 1024 // 10MB threshold

    fun getBlockSize(fileSize: Long): Int {
        return if (fileSize >= BLOCK_THRESHOLD) LARGE_BLOCK_SIZE else SMALL_BLOCK_SIZE
    }
}
```

## 2. Sync Lifecycle

### Stage 1: Metadata Check
The Dart `SyncRepository` queries the server for the file list of a specific system (e.g., `prefix=ps2`).
- Compare local and remote `lastModified` and `size`.
- If identical, the file is skipped (if no force-sync is requested).

### Stage 2: Block-Level Delta Identification
If a file has changed:
1. The **native engine** calculates SHA-256 hashes for every 1MB (or 256KB) block.
2. The list of hashes is sent to `/api/v1/blocks/check`.
3. The server responds with the indices of the "dirty" blocks.

### Stage 3: Sequential Transfer
- **Upload**: The `UploadManager` only sends the blocks identified as "dirty" to `/api/v1/upload`.
- **Download**: The `DownloadManager` requests only the missing blocks from `/api/v1/blocks/download`.

## 3. In-Place Patching

VaultSync uses `RandomAccessFile` and `FileChannel` to patch the existing local file directly, avoiding large-scale data copying.

#### Sequential Download Patching (Kotlin)
This approach minimizes I/O overhead by only writing the blocks that have changed:

```kotlin
// Example from local_plugins/vaultsync_launcher/android/src/main/kotlin/com/vaultsync/launcher/DownloadManager.kt
private fun processDownloadStream(inputStream: InputStream, output: FileChannel, secretKey: SecretKeySpec?, patchIndices: List<Int>?, fileSize: Long) {
    val plainBlockSize = CryptoEngine.getBlockSize(fileSize)
    // ... setup and decryption logic ...

    while (ringBuffer.remaining() >= expectedBlockSize) {
        ringBuffer.get(block, 0, expectedBlockSize)
        val decryptedLength = cryptoEngine.decryptBlock(block, expectedBlockSize, secretKey, decryptedBuffer)

        // Find the correct offset for the patched block
        val blockIndex = if (patchIndices != null) patchIndices[currentIdx].toLong() else currentIdx.toLong()
        val offset = blockIndex * plainBlockSize

        // Use seek and write to patch the specific file region
        output.position(offset)
        output.write(ByteBuffer.wrap(decryptedBuffer, 0, decryptedLength))
        currentIdx++
    }
}
```

## 4. Real-time Events (SSE)

VaultSync uses Server-Sent Events (SSE) for near-instant synchronization:
1. Device A uploads a new save.
2. The server sends an SSE payload to all other connected devices for that user.
3. Device B receives the event and automatically queues a download for the updated file.
